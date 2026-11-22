// POST /functions/v1/assistant 의 본체. HTTP·Supabase·Anthropic SDK를 모르는 순수 모듈이고,
// 바깥 세계(DB, 모델, 시계)는 deps로 받는다. index.ts는 deps를 실제 것으로 채워 이 함수를 부르기만 한다.
import { AssistantError, runProposal } from './core/run.mjs';
import { DEFAULT_MODEL } from './core/propose.mjs';
import { withPlanningMinutes } from './core/estimate.mjs';
import { ms } from './core/time.mjs';
import { blockToCore, coreTodoToServer, todoToCore } from './convert.mjs';
import { FnError, fromDbError } from './errors.mjs';

export const KINDS = ['capture', 'plan_day', 'reschedule'];
const MAX_TEXT = 4000;
const MAX_PASTED = 20000;
const MAX_BUSY = 200;
const CLOCK_SKEW_MS = 10 * 60 * 1000;

/** 요청 본문을 검사해 core 입력의 클라이언트 몫(kind, text, pasted, busy, session)으로 바꾼다. */
export function parseRequest(body, serverNow) {
  if (!body || typeof body !== 'object') throw new FnError('invalid_input');
  const { kind, text = '', pasted = null, busy = [], session = null } = body;
  if (!KINDS.includes(kind)) throw new FnError('invalid_input', 400, 'kind');
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
  // 시각은 서버가 정한다. 클라이언트의 now는 서버 시각과 10분 안으로 맞을 때만 쓴다.
  const cn = ms(body.now);
  const now = cn != null && Math.abs(cn - serverNow) <= CLOCK_SKEW_MS ? new Date(cn).toISOString() : new Date(serverNow).toISOString();
  return { kind, text, pasted: pasted || null, busy: cleanBusy, session: cleanSession, now };
}

/**
 * assistant_context 결과 + 요청 → core 입력. 목록·배수는 서버 값만 쓴다(클라이언트가 보낸 목록은 믿지 않는다).
 */
export function buildCoreInput(req, ctx, threadCategories = {}) {
  const factors = ctx?.estimate_factors ?? {};
  const todos = withPlanningMinutes((ctx?.todos ?? []).map(t => todoToCore(t, { category: t.category ?? threadCategories[t.thread_id] ?? null })), factors);
  const blocks = (ctx?.blocks ?? [])
    .filter(b => b.status === 'planned' || b.status === 'started')
    .map(blockToCore);
  return {
    kind: req.kind, now: req.now, text: req.text, pasted: req.pasted,
    todos, busy: req.busy, blocks, session: req.session,
    prefs: { day_start: '08:00', day_end: '23:00' },
  };
}

/** 모델이 낸 제안을 앱과 저장소가 같이 쓰는 모양으로 만든다. 할 일 후보에 due_at·due_has_time을 덧붙인다. */
export function toStoredProposal(kind, proposal) {
  return {
    kind,
    ...proposal,
    todos: proposal.todos.map(t => ({ ...t, ...coreTodoToServer(t) })),
  };
}

/**
 * @param {object} p
 * @param {object} p.body        요청 본문
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
    try { runId = await db.runBegin(userId, req.kind, config.dailyLimit); } catch (e) { throw fromDbError(e); }

    let ctx;
    try { ctx = await db.context(userId, req.now); } catch (e) { throw fromDbError(e); }
    let cats = {};
    try { cats = await db.threadCategories(userId); } catch (e) { throw fromDbError(e); }
    const input = buildCoreInput(req, ctx, cats);

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

    const stored = toStoredProposal(req.kind, result.proposal);
    let proposalId;
    try { proposalId = await db.saveProposal(userId, req.kind, { kind: req.kind, now: req.now }, stored); } catch (e) { throw fromDbError(e); }
    ok = true;
    emit('proposal', { proposal_id: proposalId, proposal: stored, dropped: result.dropped });
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
