// 가용 시간 계산. 모델이 아니라 코드가 한다.
// "오늘 얼마나 비어 있나", "이 일이 다 들어갈 자리가 있나"는 계산으로 정확히 답할 수 있는 질문이다.
// 다 들어가지 않는 일을 어떻게 할지(일부만 잡기, 내일로 넘기기, 건너뛰기)는 비서가 정하지 않는다.
// 계산한 가용 시간을 보여 주고 사용자가 고르게 한다.
import { at, dueMs, localDate, localHM, ms } from './time.mjs';

const MIN = 60000;
const ceilTo = (t, minutes) => Math.ceil(t / (minutes * MIN)) * minutes * MIN;
export const DEFAULT_ESTIMATE_MIN = 30; // 예상 시간을 모를 때 잡는 길이
export const MIN_BLOCK_MIN = 10;
export const MAX_BLOCK_MIN = 240;

/** 할 일을 계획할 때 쓰는 길이(분): 보정된 예상 → 예상 → 기본값. 한 블록의 상·하한으로 자른다. */
export const planningMinutes = todo =>
  Math.min(MAX_BLOCK_MIN, Math.max(MIN_BLOCK_MIN, todo?.planning_min ?? todo?.estimate_min ?? DEFAULT_ESTIMATE_MIN));

/** [s,e] 구간 목록에서 막힌 구간들을 뺀다. */
function subtract(intervals, blocked) {
  let out = intervals;
  for (const b of blocked) {
    out = out.flatMap(([s, e]) => (b.e <= s || b.s >= e ? [[s, e]] : [[s, Math.min(e, b.s)], [Math.max(s, b.e), e]].filter(([x, y]) => y > x)));
  }
  return out;
}

/**
 * 지금부터 days 일 동안의 빈 구간 [시작ms, 끝ms] 목록.
 * 활동 시간대 안, 지금 이후이고, 고정 일정·잠긴 계획·이미 놓은 블록(placed: {s,e})을 뺀 것.
 */
export function freeIntervals(input, placed = [], days = 1) {
  const now = ms(input.now);
  const prefs = { day_start: '08:00', day_end: '23:00', ...(input.prefs ?? {}) };
  const today0 = ms(at(localDate(now), '00:00'));
  const windows = [];
  for (let d = 0; d < days; d++) {
    const date = localDate(today0 + d * 86400000);
    const s = Math.max(ms(at(date, prefs.day_start)), ceilTo(now, 5));
    const e = ms(at(date, prefs.day_end));
    if (e > s) windows.push([s, e]);
  }
  const blocked = [
    ...(input.busy ?? []).map(b => ({ s: ms(b.start), e: ms(b.end) })),
    ...(input.blocks ?? []).filter(b => b.locked).map(b => ({ s: ms(b.start), e: ms(b.end) })),
    ...placed.map(b => ({ s: b.s, e: b.e })),
  ];
  return subtract(windows, blocked);
}

const minutesOf = intervals => intervals.reduce((a, [s, e]) => a + Math.floor((e - s) / MIN), 0);
const largestOf = intervals => intervals.reduce((a, [s, e]) => Math.max(a, Math.floor((e - s) / MIN)), 0);
const show = ([s, e]) => ({ start: at(localDate(s), localHM(s)), end: at(localDate(e), localHM(e)), minutes: Math.floor((e - s) / MIN) });

/**
 * 제안을 적용한 뒤의 가용 시간과, 배치하지 못한 일마다의 "들어갈 자리" 점검.
 * @param {object} input     core 입력
 * @param {object} proposal  제안(blocks, unscheduled 를 본다)
 * @returns {{today: {free_minutes: number, largest_minutes: number, slots: object[]},
 *            fit_checks: {todo_ref: string, needed_minutes: number, largest_today_minutes: number,
 *                         largest_before_due_minutes: number|null, fits_within_days: number|null,
 *                         options: string[], partial_slot: object|null, full_slot: object|null}[]}}
 */
export function availability(input, proposal = { blocks: [], unscheduled: [] }) {
  const placed = (proposal.blocks ?? []).map(b => ({ s: ms(b.start), e: ms(b.end) })).filter(b => b.s != null && b.e != null);
  const today = freeIntervals(input, placed, 1);
  const todos = [...(input.todos ?? []), ...(proposal.todos ?? []).map((t, i) => ({ ...t, id: `new:${i}` }))];
  const fit_checks = [];
  for (const u of proposal.unscheduled ?? []) {
    const todo = todos.find(t => t.id === u.todo_ref);
    if (!todo) continue;
    const needed = planningMinutes(todo);
    const due = dueMs(todo);
    const clip = list => (due == null ? list : list.map(([s, e]) => [s, Math.min(e, due)]).filter(([s, e]) => e > s));
    const largestToday = largestOf(clip(today));
    // 며칠 안에 다 들어갈 자리가 생기는가(오늘=1, 내일까지=2 …). 마감 전이어야 한다.
    let fitsWithin = null;
    for (let d = 1; d <= 7 && fitsWithin == null; d++) if (largestOf(clip(freeIntervals(input, placed, d))) >= needed) fitsWithin = d;
    // 화면에 보여 줄 실제 자리: 오늘 들어가는 만큼(일부)과, 다 들어가는 가장 이른 자리.
    const todayBest = clip(today).reduce((m, x) => (!m || x[1] - x[0] > m[1] - m[0] ? x : m), null);
    const firstFull = clip(freeIntervals(input, placed, 7)).find(([s, e]) => Math.floor((e - s) / MIN) >= needed) ?? null;
    const options = [];
    if (largestToday >= MIN_BLOCK_MIN && largestToday < needed) options.push('partial_today'); // 오늘 들어가는 만큼만
    if (fitsWithin != null && fitsWithin > 1) options.push('move_later');                      // 다 들어가는 날로
    if (fitsWithin === 1) options.push('place_today');                                         // 사실은 오늘 자리가 있다
    options.push('skip');
    fit_checks.push({
      todo_ref: u.todo_ref, needed_minutes: needed, largest_today_minutes: largestToday,
      largest_before_due_minutes: due == null ? null : largestOf(clip(freeIntervals(input, placed, 7))),
      fits_within_days: fitsWithin, options,
      partial_slot: options.includes('partial_today') ? show([todayBest[0], Math.min(todayBest[1], todayBest[0] + MAX_BLOCK_MIN * MIN)]) : null,
      full_slot: firstFull ? show([firstFull[0], firstFull[0] + needed * MIN]) : null,
    });
  }
  return { today: { free_minutes: minutesOf(today), largest_minutes: largestOf(today), slots: today.map(show) }, fit_checks };
}

/**
 * 사용자의 답으로 제안을 고친다. 모델을 부르지 않는다.
 *   estimates: [{todo_ref, minutes}]  "얼마나 걸려요?"에 대한 답. estimate_asks 에 있는 일만 받는다.
 *                                     블록 길이를 답한 만큼으로 바꾸고, 그만큼 들어갈 자리가 없으면 못 넣은 일로 돌린다.
 *   fits:      [{todo_ref, option}]   다 들어가지 않는 일을 어떻게 할지. option 은 fit_checks 의 options 중
 *                                     partial_today | move_later | place_today (건너뛰기는 앱에서 끝난다).
 * 건너뛰거나 2분 동안 답이 없으면 앱은 아무것도 보내지 않는다. 30분으로 잡힌 그대로 남는다.
 * @returns {{input: object, proposal: object, estimate_updates: {todo_id: string, minutes: number}[],
 *            rejected: {todo_ref: string, reason: string}[]}}
 *   input 은 답한 예상 시간을 반영한 사본이다. estimate_updates 는 이미 있는 할 일의 예상 시간(앱이 적용할 때 저장한다).
 */
export function adjustProposal(input, proposal, { estimates = [], fits = [] } = {}) {
  const inp = { ...input, todos: (input.todos ?? []).map(t => ({ ...t })) };
  const p = {
    ...proposal,
    todos: (proposal.todos ?? []).map(t => ({ ...t })),
    blocks: (proposal.blocks ?? []).map(b => ({ ...b })),
    unscheduled: (proposal.unscheduled ?? []).map(u => ({ ...u })),
    estimate_asks: [...(proposal.estimate_asks ?? [])],
  };
  const estimate_updates = [], rejected = [];
  const span = b => ({ s: ms(b.start), e: ms(b.end) });

  for (const { todo_ref: ref, minutes } of estimates) {
    if (!p.estimate_asks.includes(ref)) { rejected.push({ todo_ref: ref, reason: 'not_asked' }); continue; }
    if (!Number.isInteger(minutes) || minutes < MIN_BLOCK_MIN || minutes > MAX_BLOCK_MIN) { rejected.push({ todo_ref: ref, reason: 'minutes' }); continue; }
    p.estimate_asks = p.estimate_asks.filter(r => r !== ref);
    let todo;
    if (ref.startsWith('new:')) { todo = p.todos[+ref.slice(4)]; if (todo) todo.estimate_min = minutes; }
    else {
      todo = inp.todos.find(t => t.id === ref);
      if (todo) { todo.estimate_min = minutes; todo.planning_min = minutes; estimate_updates.push({ todo_id: ref, minutes }); }
    }
    const i = p.blocks.findIndex(b => b.todo_ref === ref);
    if (i < 0 || !todo) continue;
    const cur = span(p.blocks[i]);
    const end = cur.s + minutes * MIN;
    let ok = end <= cur.e; // 줄이는 것은 언제나 된다
    if (!ok) {
      // 늘어나는 부분 [지금 끝, 새 끝]이 통째로 비어 있어야 한다(같은 날 활동 시간 안, 마감 전).
      const others = p.blocks.filter((_, k) => k !== i).map(span);
      const due = dueMs(todo);
      ok = (due == null || end <= due) && freeIntervals(inp, others, 8).some(([s, e]) => s <= cur.e && end <= e);
    }
    if (ok) p.blocks[i].end = at(localDate(end), localHM(end));
    else {
      p.blocks.splice(i, 1);
      p.unscheduled.push({ todo_ref: ref, reason: `${minutes}분이 들어갈 자리가 그 시간에 없음` });
    }
  }

  for (const { todo_ref: ref, option } of fits) {
    const check = availability(inp, p).fit_checks.find(f => f.todo_ref === ref);
    const slot = !check || !check.options.includes(option) ? null
      : option === 'partial_today' ? check.partial_slot
      : option === 'move_later' || option === 'place_today' ? check.full_slot : null;
    if (!slot) { rejected.push({ todo_ref: ref, reason: 'option' }); continue; }
    p.blocks.push({ todo_ref: ref, start: slot.start, end: slot.end });
    p.unscheduled = p.unscheduled.filter(u => u.todo_ref !== ref);
  }
  return { input: inp, proposal: p, estimate_updates, rejected };
}
