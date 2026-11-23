// POST /functions/v1/assistant 의 본체. HTTP·Supabase·Anthropic SDK를 모르는 순수 모듈이고,
// 바깥 세계(DB, 모델, 시계)는 deps로 받는다. index.ts는 deps를 실제 것으로 채워 이 함수를 부르기만 한다.
import { AssistantError, runProposal } from './core/run.mjs';
import { DEFAULT_MODEL } from './core/propose.mjs';
import { withPlanningMinutes } from './core/estimate.mjs';
import { adjustProposal, availability } from './core/availability.mjs';
import { ms } from './core/time.mjs';
import { blockToCore, todoToCore } from './convert.mjs';
import { FnError, fromDbError } from './errors.mjs';

export const KINDS = ['capture', 'plan_day', 'reschedule', 'availability', 'adjust'];
// adjust: 모델을 부르지 않고, 사용자의 답으로 저장된 제안을 고쳐 새 제안으로 저장한다(한도에 넣지 않는다).
//   요청: {kind: 'adjust', proposal_id, estimates: [{todo_ref, minutes}], fits: [{todo_ref, option}], busy}
//   응답 이벤트: proposal (보통 제안과 같은 모양 + replaces, estimate_updates, rejected). 원래 제안은 그대로 두고 만료된다.
// availability: 모델을 부르지 않고 가용 시간만 계산해 돌려준다(한도에 넣지 않는다).
//   응답 이벤트: availability {today: {free_minutes, largest_minutes, slots}, fit_checks: []}
const MAX_TEXT = 4000;
const MAX_PASTED = 20000;
const MAX_BUSY = 200;
const TZ = 'Asia/Seoul';

/** 요청 본문을 검사해 core 입력의 클라이언트 몫(kind, text, pasted, busy, session)으로 바꾼다. */
export function parseRequest(body, serverNow) {
  if (!body || typeof body !== 'object') throw new FnError('invalid_input');
  const { kind, text = '', pasted = null, busy = [], session = null } = body;
  if (!KINDS.includes(kind)) throw new FnError('invalid_input', 400, 'kind');
  if (body.tz != null && body.tz !== TZ) throw new FnError('invalid_input', 400, 'tz'); // core는 한국 시간만 다룬다
  if (typeof text !== 'string' || text.length > MAX_TEXT) throw new FnError('invalid_input', 400, 'text');
  if (pasted != null && (typeof pasted !== 'string' || pasted.length > MAX_PASTED)) throw new FnError('invalid_input', 400, 'pasted');
  if (kind === 'capture' && !text.trim() && !(pasted && pasted.trim())) throw new FnError('invalid_input', 400, 'empty');
  if (!Array.isArray(busy) || busy.length > MAX_BUSY) throw new FnError('invalid_input', 400, 'busy');
  const cleanBusy = busy.map(b => {
    const s = ms(b?.start), e = ms(b?.end);
    if (s == null || e == null || e <= s) throw new FnError('invalid_input', 400, 'busy');
    return { start: b.start, end: b.end };
  });
  let cleanSession = null;
  if (session != null) {
    if (typeof session !== 'object') throw new FnError('invalid_input', 400, 'session');
    cleanSession = {
      todo_id: session.todo_id ?? null,
      outcome: session.outcome ?? null,
      note: typeof session.note === 'string' ? session.note.slice(0, 200) : null,
    };
  }
  let adjust = null;
  if (kind === 'adjust') {
    const { proposal_id, estimates = [], fits = [] } = body;
    const ref = r => typeof r === 'string' && r.length <= 64;
    if (typeof proposal_id !== 'string' || !/^[0-9a-f-]{36}$/i.test(proposal_id)) throw new FnError('invalid_input', 400, 'proposal_id');
    if (!Array.isArray(estimates) || !Array.isArray(fits) || estimates.length + fits.length === 0 || estimates.length + fits.length > 40) throw new FnError('invalid_input', 400, 'adjust');
    if (!estimates.every(e => ref(e?.todo_ref) && Number.isInteger(e.minutes))) throw new FnError('invalid_input', 400, 'estimates');
    if (!fits.every(f => ref(f?.todo_ref) && ['partial_today', 'move_later', 'place_today'].includes(f.option))) throw new FnError('invalid_input', 400, 'fits');
    adjust = { proposal_id, estimates: estimates.map(e => ({ todo_ref: e.todo_ref, minutes: e.minutes })), fits: fits.map(f => ({ todo_ref: f.todo_ref, option: f.option })) };
  }
  // 기준 시각은 서버가 정한다. 요청의 now는 읽지 않는다(과거 시각으로 규칙 검사를 피하는 것을 막는다).
  const now = new Date(serverNow).toISOString();
  return { kind, text, pasted: pasted || null, busy: cleanBusy, session: cleanSession, now, adjust };
}

/**
 * assistant_context 결과 + 요청 → core 입력. 목록·배수는 서버 값만 쓴다(클라이언트가 보낸 목록은 믿지 않는다).
 * 할 일은 core 형식({due_date, due_time, estimate_min_calibrated, category})이면 그대로 쓰고,
 * 서버 Todo 형식({due_at, due_has_time})이면 변환한다. 보정된 예상 시간이 있으면 estimate_min 자리에 넣고
 * 원래 값과 배수는 calibration으로 돌려준다(앱이 안내에 쓴다).
 * @returns {{input: object, calibration: {todo_id: string, original_min: number, calibrated_min: number, factor: number}[]}}
 */
export function buildCoreInput(req, ctx, threadCategories = {}) {
  const factors = ctx?.estimate_factors ?? {};
  const calibration = [];
  const todos = (ctx?.todos ?? []).map(t => {
    const category = t.category ?? threadCategories[t.thread_id] ?? null;
    const core = 'due_date' in t
      ? { id: t.id, title: t.title, due_date: t.due_date ?? null, due_time: t.due_time ?? null, estimate_min: t.estimate_min ?? null, status: t.status, category }
      : todoToCore(t, { category });
    const cal = t.estimate_min_calibrated;
    if (cal != null && core.estimate_min != null) {
      if (cal !== core.estimate_min) {
        calibration.push({ todo_id: core.id, original_min: core.estimate_min, calibrated_min: cal, factor: Math.round((cal / core.estimate_min) * 100) / 100 });
        core.estimate_min = cal;
      }
      return core; // 서버가 보정한 값이므로 여기서 또 곱하지 않는다
    }
    // 서버가 보정 값을 주지 않았으면 분야별 배수로 planning_min을 붙인다(대비책).
    return withPlanningMinutes([core], factors)[0];
  });
  const blocks = (ctx?.blocks ?? [])
    .filter(b => !b.status || b.status === 'planned' || b.status === 'started')
    .map(b => 'start' in b ? { id: b.id, todo_ref: b.todo_ref ?? b.todo_id ?? null, start: b.start, end: b.end, locked: !!b.locked } : blockToCore(b));
  return {
    input: {
      kind: req.kind, now: req.now, text: req.text, pasted: req.pasted,
      todos, busy: req.busy, blocks, session: req.session,
      prefs: { day_start: '08:00', day_end: '23:00' },
    },
    calibration,
  };
}

/**
 * @param {object} p
 * @param {any} p.body           요청 본문(검사 전이라 어떤 값이든 올 수 있다)
 * @param {string} p.userId
 * @param {{
 *   db: {runBegin: Function, runFinish: Function, context: Function, threadCategories: Function, saveProposal: Function},
 *   client: object, now: () => number,
 *   config: {model?: string, dailyLimit: number, timeoutMs: number, effort?: string}
 * }} p.deps
 * @param {(event: string, data: object) => void} p.emit  이벤트를 흘려보낸다
 */
export async function handleAssistant({ body, userId, deps, emit }) {
  const { db, client, config } = deps;
  const started = deps.now();
  let runId = null;
  let usage = null;
  let model = null;
  let ok = false;
  try {
    const req = parseRequest(body, started);
    if (req.kind === 'availability') {
      let ctx0;
      try { ctx0 = await db.context(userId, req.now); } catch (e) { throw fromDbError(e); }
      const { input: input0 } = buildCoreInput({ ...req, kind: 'plan_day' }, ctx0, {});
      emit('availability', availability(input0));
      return;
    }
    if (req.kind === 'adjust') {
      let saved, ctx0;
      try { saved = await db.proposalGet(userId, req.adjust.proposal_id); } catch (e) { throw fromDbError(e); }
      if (!saved) throw new FnError('proposal_not_found', 404);
      try { ctx0 = await db.context(userId, req.now); } catch (e) { throw fromDbError(e); }
      let cats0 = {};
      if ((ctx0?.todos ?? []).some(t => !('category' in t))) {
        try { cats0 = await db.threadCategories(userId); } catch (e) { throw fromDbError(e); }
      }
      const built = buildCoreInput({ ...req, kind: saved.kind }, ctx0, cats0);
      const adj = adjustProposal(built.input, saved.proposal, req.adjust);
      let newId;
      try { newId = await db.saveProposal(userId, saved.kind, { kind: saved.kind, now: req.now }, adj.proposal); } catch (e) { throw fromDbError(e); }
      emit('proposal', {
        proposal_id: newId, proposal: adj.proposal, dropped: [], calibration: built.calibration,
        expires_at: new Date(deps.now() + 24 * 3600 * 1000).toISOString(),
        availability: saved.kind === 'capture' ? null : availability(adj.input, adj.proposal),
        replaces: req.adjust.proposal_id, estimate_updates: adj.estimate_updates, rejected: adj.rejected,
      });
      return;
    }
    try { runId = await db.runBegin(userId, req.kind, config.dailyLimit); } catch (e) { throw fromDbError(e); }

    let ctx;
    try { ctx = await db.context(userId, req.now); } catch (e) { throw fromDbError(e); }
    let cats = {};
    if ((ctx?.todos ?? []).some(t => !('category' in t))) {
      try { cats = await db.threadCategories(userId); } catch (e) { throw fromDbError(e); }
    }
    const { input, calibration } = buildCoreInput(req, ctx, cats);

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), config.timeoutMs);
    let result;
    try {
      result = await runProposal(input, {
        client, model: config.model ?? DEFAULT_MODEL, effort: config.effort, signal: controller.signal,
        onMessageDelta: text => emit('message_delta', { text }),
      });
    } catch (e) {
      if (e instanceof AssistantError) throw new FnError(e.code, 503, e.message);
      throw new FnError('assistant_unavailable', 503, controller.signal.aborted ? 'timeout' : 'model error');
    } finally { clearTimeout(timer); }
    usage = result.usage; model = result.model;

    // 저장하는 제안은 assistant/core/schema.mjs 모양 그대로다(규칙 검사에서 뺀 블록은 이미 빠져 있다).
    const stored = result.proposal;
    let proposalId;
    try { proposalId = await db.saveProposal(userId, req.kind, { kind: req.kind, now: req.now }, stored); } catch (e) { throw fromDbError(e); }
    ok = true;
    // 제안은 만든 지 24시간이 지나면 적용할 수 없다(D가 막는다). 앱이 안내에 쓰도록 만료 시각을 같이 준다.
    const expires_at = new Date(deps.now() + 24 * 3600 * 1000).toISOString();
    // 가용 시간과, 못 넣은 일마다의 "들어갈 자리" 점검은 코드가 계산해 붙인다. 일부만 잡을지는 사용자가 고른다.
    const avail = req.kind === 'capture' ? null : availability(input, stored);
    emit('proposal', { proposal_id: proposalId, proposal: stored, dropped: result.dropped, calibration, expires_at, availability: avail });
  } catch (e) {
    const code = e instanceof FnError ? e.code : 'assistant_unavailable';
    emit('error', { code });
  } finally {
    if (runId) {
      try {
        await db.runFinish(runId, { model, input_tokens: usage?.input_tokens ?? null, output_tokens: usage?.output_tokens ?? null,
          latency_ms: deps.now() - started, ok });
      } catch { /* 기록 실패가 응답을 막지 않는다 */ }
    }
  }
}
