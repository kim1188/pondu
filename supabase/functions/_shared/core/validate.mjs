// 규칙 검사. 모델이 만든 제안을 저장하기 전에 코드로 확인한다.
// 여기서 걸린 제안은 저장되지 않는다. 시험 세트의 rules_ok 지표도 이 함수를 쓴다.
import { DATE_RE, HM_RE, dueMs, localDate, localHM, ms, overlaps } from './time.mjs';

const MIN_BLOCK_MIN = 10;
const MAX_BLOCK_MIN = 240;
const HORIZON_DAYS = 7;

/** todo_ref를 실제 할 일로 바꾼다. 못 찾으면 null. */
export function resolveRef(ref, input, proposal) {
  const m = /^new:(\d+)$/.exec(String(ref));
  if (m) return proposal.todos[+m[1]] ? { ...proposal.todos[+m[1]], isNew: true } : null;
  return (input.todos ?? []).find(t => t.id === ref) ?? null;
}

/**
 * @returns {{rule: string, detail: string}[]} 위반 목록. 비어 있으면 통과.
 */
export function validate(input, proposal) {
  const v = [];
  // loc: 위반이 가리키는 위치({todo|block|unscheduled|done_id}). 서버가 걸린 블록만 빼는 데 쓴다.
  let loc = null;
  const add = (rule, detail) => v.push(loc ? { rule, detail, ...loc } : { rule, detail });
  const now = ms(input.now);
  const today = localDate(now);
  const prefs = { day_start: '08:00', day_end: '23:00', ...(input.prefs ?? {}) };
  const openIds = new Set((input.todos ?? []).filter(t => t.status !== 'done').map(t => t.id));

  for (const [i, t] of proposal.todos.entries()) {
    loc = { todo: i };
    if (!String(t.title ?? '').trim()) add('todo_title', `todos[${i}] 제목이 비어 있음`);
    if (t.due_date != null && !DATE_RE.test(t.due_date)) add('due_format', `todos[${i}].due_date=${t.due_date}`);
    if (t.due_time != null && !HM_RE.test(t.due_time)) add('due_format', `todos[${i}].due_time=${t.due_time}`);
    if (t.due_time != null && t.due_date == null) add('due_format', `todos[${i}] 날짜 없이 시각만 있음`);
    if (t.estimate_min != null && !(t.estimate_min > 0 && t.estimate_min <= 24 * 60)) add('estimate_range', `todos[${i}].estimate_min=${t.estimate_min}`);
  }

  for (const id of proposal.done_todo_ids) {
    loc = { done_id: id };
    if (!openIds.has(id)) add('done_unknown', `완료 처리 대상 ${id} 가 열린 할 일이 아님`);
  }
  for (const [i, u] of proposal.unscheduled.entries()) {
    loc = { unscheduled: i };
    if (!resolveRef(u.todo_ref, input, proposal)) add('ref_unknown', `unscheduled 의 ${u.todo_ref}`);
  }

  loc = null;
  if (input.kind === 'capture' && proposal.blocks.length) {
    add('capture_no_blocks', 'capture 요청인데 예정 시간을 만들었음');
  }

  const locked = (input.blocks ?? []).filter(b => b.locked).map(b => ({ id: b.id, s: ms(b.start), e: ms(b.end) }));
  const busy = (input.busy ?? []).map(b => ({ s: ms(b.start), e: ms(b.end) }));
  const placed = [];

  for (const [i, b] of proposal.blocks.entries()) {
    const s = ms(b.start), e = ms(b.end);
    loc = { block: i };
    const tag = `blocks[${i}] ${b.todo_ref}`;
    if (s == null || e == null) { add('block_time', `${tag} 시각을 읽을 수 없음`); continue; }
    const minutes = (e - s) / 60000;
    if (!(minutes >= MIN_BLOCK_MIN && minutes <= MAX_BLOCK_MIN)) add('block_length', `${tag} 길이 ${minutes}분`);
    if (s < now) add('block_past', `${tag} 현재 시각보다 이전에 시작`);
    if (s - now > HORIZON_DAYS * 86400000) add('block_horizon', `${tag} ${HORIZON_DAYS}일보다 뒤`);
    if (input.kind === 'plan_day' && localDate(s) !== today) add('plan_day_today', `${tag} 오늘이 아닌 날짜`);
    if (localDate(s) !== localDate(e - 1) || localHM(s) < prefs.day_start || localHM(e - 1) >= prefs.day_end) {
      add('day_window', `${tag} 활동 시간대(${prefs.day_start}~${prefs.day_end}) 밖`);
    }
    for (const z of busy) if (overlaps(s, e, z.s, z.e)) { add('busy_overlap', `${tag} 고정 일정과 겹침`); break; }
    for (const z of locked) if (overlaps(s, e, z.s, z.e)) { add('locked_overlap', `${tag} 잠근 계획 ${z.id} 과 겹침`); break; }
    for (const z of placed) if (overlaps(s, e, z.s, z.e)) { add('block_overlap', `${tag} 다른 제안 블록과 겹침`); break; }
    placed.push({ s, e });

    const todo = resolveRef(b.todo_ref, input, proposal);
    if (!todo) { add('ref_unknown', `${tag} 가리키는 할 일이 없음`); continue; }
    if (!todo.isNew && todo.status === 'done') add('ref_done', `${tag} 이미 끝난 할 일`);
    if (proposal.done_todo_ids.includes(b.todo_ref)) add('ref_done', `${tag} 이번에 완료 처리한 할 일`);
    const due = dueMs(todo);
    if (due != null && e > due) add('after_due', `${tag} 마감 이후에 끝남`);
  }
  return v;
}
