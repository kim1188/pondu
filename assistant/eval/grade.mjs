// 채점기. 모델 판단 없이 코드로만 채점한다.
// 지표(모두 0 또는 1):
//   pass             rules_ok 와 expect_ok 가 모두 1
//   rules_ok         규칙 검사(core/validate.mjs) 위반 없음
//   expect_ok        사례별 기대를 모두 만족
//   no_invented_due  사용자가 말하지 않은 기한을 만들지 않음
//   no_false_done    사용자가 끝냈다고 하지 않은 일을 완료 처리하지 않음
import { localDate, localHM, ms, overlaps } from '../core/time.mjs';
import { resolveRef, validate } from '../core/validate.mjs';

const has = (title, kws) => kws.some(k => String(title).toLowerCase().includes(String(k).toLowerCase()));

/** 기대에 적힌 대상("t1" 또는 키워드 배열)에 해당하는 todo_ref 목록 */
function refsFor(target, proposal) {
  if (typeof target === 'string') return [target];
  return proposal.todos.map((t, i) => (has(t.title, target) ? `new:${i}` : null)).filter(Boolean);
}
const blocksFor = (target, proposal) => {
  const refs = new Set(refsFor(target, proposal));
  return proposal.blocks.filter(b => refs.has(b.todo_ref));
};
const name = target => (typeof target === 'string' ? target : target.join('/'));

export const METRICS = ['pass', 'rules_ok', 'expect_ok', 'no_invented_due', 'no_false_done'];
export const ZERO_GRADE = Object.fromEntries(METRICS.map(m => [m, 0]));

export function grade(c, proposal) {
  if (!proposal) {
    return { grade: { ...ZERO_GRADE }, explanation: { pass: '제안이 없음(거절했거나 형식에 맞지 않음)' } };
  }
  const { input, expect: x } = c;
  const fails = [];
  const dueFails = [];
  const doneFails = [];
  const violations = validate(input, proposal);

  // 새 할 일의 개수와 제목
  if (x.todos) {
    const n = proposal.todos.length;
    if (n < x.todos[0] || n > x.todos[1]) fails.push(`새 할 일 ${n}개 (기대 ${x.todos[0]}~${x.todos[1]})`);
  }
  for (const kws of x.titles ?? []) {
    if (!proposal.todos.some(t => has(t.title, kws))) fails.push(`제목에 ${kws.join('/')} 가 있는 할 일이 없음`);
  }
  for (const kws of x.forbid_titles ?? []) {
    if (proposal.todos.some(t => has(t.title, kws))) fails.push(`만들면 안 되는 할 일(${kws.join('/')})을 만듦`);
  }

  // 기한: 기대에 적히지 않은 할 일의 기한은 null 이어야 한다
  for (const t of proposal.todos) {
    const rule = (x.due ?? []).find(d => has(t.title, d.match));
    const allowed = rule ? rule.dates : (x.due_allowed ?? [null]);
    if (!allowed.includes(t.due_date ?? null)) {
      const msg = `"${t.title}" 기한 ${t.due_date} (허용: ${allowed.map(String).join(', ')})`;
      // 허용 목록이 null 뿐이면 말하지 않은 기한을 지어낸 것, 아니면 날짜 계산이 틀린 것
      if (allowed.every(d => d === null)) dueFails.push(msg); else fails.push(msg);
    }
    if (rule?.times && !rule.times.includes(t.due_time ?? null)) fails.push(`"${t.title}" 기한 시각 ${t.due_time}`);
  }
  if (x.est_total != null) {
    const sum = proposal.todos.reduce((a, t) => a + (t.estimate_min ?? 0), 0);
    if (sum !== x.est_total) fails.push(`예상 시간 합 ${sum}분 (기대 ${x.est_total}분)`);
  }

  // 완료 처리: 기대에 없는 완료는 거짓 완료
  const wantDone = new Set(x.done ?? []);
  for (const id of proposal.done_todo_ids) if (!wantDone.has(id)) doneFails.push(`${id} 를 완료 처리함`);
  for (const id of wantDone) if (!proposal.done_todo_ids.includes(id)) fails.push(`${id} 를 완료 처리하지 않음`);

  if (x.questions_min != null && proposal.questions.length < x.questions_min) fails.push('되묻는 질문이 없음');
  if (x.blocks) {
    const n = proposal.blocks.length;
    if (n < x.blocks[0] || n > x.blocks[1]) fails.push(`블록 ${n}개 (기대 ${x.blocks[0]}~${x.blocks[1]})`);
  }
  if (x.unscheduled_min != null && proposal.unscheduled.length < x.unscheduled_min) fails.push('못 넣은 일을 unscheduled 에 적지 않음');

  for (const target of x.scheduled ?? []) {
    if (!blocksFor(target, proposal).length) fails.push(`${name(target)} 에 시간이 잡히지 않음`);
  }
  for (const target of x.not_scheduled ?? []) {
    if (blocksFor(target, proposal).length) fails.push(`${name(target)} 에 시간이 잡힘`);
  }
  for (const target of x.resolved ?? []) {
    const refs = new Set(refsFor(target, proposal));
    const listed = proposal.unscheduled.some(u => refs.has(u.todo_ref));
    if (!blocksFor(target, proposal).length && !listed) fails.push(`${name(target)} 가 배치도 unscheduled 도 아님`);
  }
  for (const [id, minutes] of Object.entries(x.min_minutes ?? {})) {
    const got = blocksFor(id, proposal).reduce((a, b) => a + (ms(b.end) - ms(b.start)) / 60000, 0);
    if (!(got >= minutes)) fails.push(`${id} 배치 ${got}분 (기대 ${minutes}분 이상)`);
  }
  for (const [id, hm] of Object.entries(x.start_after ?? {})) {
    for (const b of blocksFor(id, proposal)) if (localHM(ms(b.start)) < hm) fails.push(`${id} 가 ${hm} 이전에 시작`);
  }
  for (const [id, date] of Object.entries(x.on_date ?? {})) {
    for (const b of blocksFor(id, proposal)) if (localDate(ms(b.start)) !== date) fails.push(`${id} 가 ${date} 가 아닌 날에 잡힘`);
  }
  const today = localDate(ms(input.now));
  for (const id of x.not_today ?? []) {
    if (blocksFor(id, proposal).some(b => localDate(ms(b.start)) === today)) fails.push(`${id} 가 오늘 다시 잡힘`);
  }
  for (const [id, hm] of Object.entries(x.start_before ?? {})) {
    for (const b of blocksFor(id, proposal)) if (localHM(ms(b.start)) >= hm) fails.push(`${id} 가 ${hm} 이후에 시작`);
  }
  if (x.scheduled_todos) {
    const n = new Set(proposal.blocks.map(b => b.todo_ref)).size;
    if (n < x.scheduled_todos[0] || n > x.scheduled_todos[1]) fails.push(`시간이 잡힌 할 일 ${n}개 (기대 ${x.scheduled_todos[0]}~${x.scheduled_todos[1]})`);
  }
  if (x.no_blocks_on && proposal.blocks.some(b => localDate(ms(b.start)) === x.no_blocks_on)) fails.push(`${x.no_blocks_on} 에 블록이 있음`);
  for (const w of x.avoid ?? []) {
    if (proposal.blocks.some(b => overlaps(ms(b.start), ms(b.end), ms(w.start), ms(w.end)))) fails.push('사용자가 비워 달라고 한 시간과 겹침');
  }
  // 정책(모든 사례 공통): 한 가지 일은 예상 시간만큼 통째로 잡고, 예상 시간이 없는 일은 30분으로 잡고 묻는다.
  for (const ref of new Set(proposal.blocks.map(b => b.todo_ref))) {
    const t = resolveRef(ref, input, proposal);
    if (!t) continue;
    const total = blocksFor(ref, proposal).reduce((a, b) => a + (ms(b.end) - ms(b.start)) / 60000, 0);
    const est = t.planning_min ?? t.estimate_min ?? null;
    if (est == null) {
      if (!(proposal.estimate_asks ?? []).includes(ref)) fails.push(`${ref} 예상 시간이 없는데 estimate_asks 에 넣지 않음`);
      if (total !== 30) fails.push(`${ref} 예상 시간이 없는 일을 ${total}분으로 잡음 (기대 30분)`);
    } else if (total < Math.min(est, 240)) {
      fails.push(`${ref} 를 일부만 잡음 (${total}/${est}분)`);
    }
  }
  // 가리키는 대상이 없는 참조는 규칙 검사에서도 잡히지만 설명에 남긴다
  for (const b of proposal.blocks) if (!resolveRef(b.todo_ref, input, proposal)) fails.push(`알 수 없는 참조 ${b.todo_ref}`);

  const rules_ok = violations.length === 0 ? 1 : 0;
  const no_invented_due = dueFails.length === 0 ? 1 : 0;
  const no_false_done = doneFails.length === 0 ? 1 : 0;
  const expect_ok = fails.length === 0 && no_invented_due && no_false_done ? 1 : 0;
  const pass = rules_ok && expect_ok ? 1 : 0;
  const join = a => a.join(' / ');
  const explanation = {};
  const all = [...violations.map(v => `[규칙:${v.rule}] ${v.detail}`), ...dueFails, ...doneFails, ...fails];
  if (all.length) explanation.pass = join(all);
  if (violations.length) explanation.rules_ok = join(violations.map(v => `${v.rule}: ${v.detail}`));
  if (dueFails.length) explanation.no_invented_due = join(dueFails);
  if (doneFails.length) explanation.no_false_done = join(doneFails);
  return { grade: { pass, rules_ok, expect_ok, no_invented_due, no_false_done }, explanation };
}
