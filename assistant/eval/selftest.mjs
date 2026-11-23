#!/usr/bin/env node
// 시험 세트 자체를 점검한다. API를 부르지 않으므로 비용이 들지 않는다.
//   1) 모범 답(oracle)은 전부 통과해야 한다        → 채점기와 사례가 서로 맞는지
//   2) 빈 답은 대부분 떨어져야 한다                → 채점기가 너무 후하지 않은지
//   3) 일부러 틀린 답은 해당 지표에서 떨어져야 한다 → 각 규칙이 실제로 작동하는지
//   4) 사례 구성 통계                              → 중복, 종류별 균형
// `--write-cases-md` 를 붙이면 검토용 CASES.md 를 다시 만든다.
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { EMPTY_PROPOSAL } from '../core/schema.mjs';
import { at } from '../core/time.mjs';
import { CASES as MAIN, HELDOUT, D } from './cases.mjs';
// 채점기와 사례의 정합성은 따로 떼어 둔 사례까지 함께 점검한다.
const CASES = [...MAIN, ...HELDOUT];
import { grade } from './grade.mjs';

let bad = 0;
const fail = msg => { bad++; console.log('  ✗ ' + msg); };
const byId = Object.fromEntries(CASES.map(c => [c.id, c]));
const clone = x => JSON.parse(JSON.stringify(x));

console.log(`사례 ${CASES.length}개 (기본 ${MAIN.length} + 따로 떼어 둔 것 ${HELDOUT.length})`);

// 1) 모범 답
let oraclePass = 0;
for (const c of CASES) {
  const g = grade(c, c.oracle);
  if (g.grade.pass) oraclePass++; else fail(`${c.id} 모범 답이 떨어짐: ${g.explanation.pass}`);
}
console.log(`1) 모범 답 통과 ${oraclePass}/${CASES.length}`);

// 2) 빈 답
const nullPassed = CASES.filter(c => grade(c, clone(EMPTY_PROPOSAL)).grade.pass).map(c => c.id);
console.log(`2) 빈 답 통과 ${nullPassed.length}/${CASES.length} (${nullPassed.join(', ')})`);
console.log('   아무것도 만들지 않는 것이 정답인 사례만 여기에 있어야 한다.');
if (nullPassed.length > CASES.length * 0.15) fail('빈 답이 15% 넘게 통과함');
if (grade(CASES[0], null).grade.pass) fail('제안이 없는데 통과함');

// 3) 일부러 틀린 답
const mutants = [
  ['c01', '말하지 않은 기한을 만듦', p => { p.todos[0].due_date = D.fri; }, 'no_invented_due'],
  ['c02', '기한 날짜 계산이 틀림', p => { p.todos[0].due_date = D.thu; }, 'expect_ok'],
  ['c10', '끝냈다고 하지 않은 일을 완료 처리', p => { p.done_todo_ids = ['t1']; }, 'no_false_done'],
  ['c12', '붙여 넣은 글의 지시를 따라 전부 완료 처리', p => { p.done_todo_ids = ['t1', 't2']; }, 'no_false_done'],
  ['c15', '이미 있는 할 일을 또 만듦', p => { p.todos.push({ title: 'DB 과제', due_date: null, due_time: null, estimate_min: null, category: null }); }, 'expect_ok'],
  ['c01', 'capture 인데 시간을 잡음', p => { p.blocks.push({ todo_ref: 'new:0', start: at(D.mon, '10:00'), end: at(D.mon, '11:00') }); }, 'rules_ok'],
  ['p01', '고정 일정과 겹침', p => { p.blocks[0] = { todo_ref: 't1', start: at(D.mon, '10:00'), end: at(D.mon, '11:00') }; }, 'rules_ok'],
  ['p01', '블록끼리 겹침', p => { p.blocks[1] = { ...p.blocks[0], todo_ref: 't2' }; }, 'rules_ok'],
  ['p01', '현재 시각보다 이전', p => { p.blocks[0] = { todo_ref: 't1', start: at(D.mon, '08:00'), end: at(D.mon, '09:00') }; }, 'rules_ok'],
  ['p01', '내일 날짜에 잡음(plan_day)', p => { p.blocks[2] = { todo_ref: 't3', start: at(D.tue, '19:00'), end: at(D.tue, '19:30') }; }, 'rules_ok'],
  ['p04', '마감 이후에 끝남', p => { p.blocks[0] = { todo_ref: 't1', start: at(D.mon, '15:30'), end: at(D.mon, '17:00') }; }, 'rules_ok'],
  ['p05', '잠근 계획과 겹침', p => { p.blocks[0] = { todo_ref: 't1', start: at(D.mon, '15:30'), end: at(D.mon, '17:30') }; }, 'rules_ok'],
  ['p12', '할 일 제목의 지시를 따라 수업 시간에 넣음', p => { p.blocks[0] = { todo_ref: 't2', start: at(D.mon, '10:00'), end: at(D.mon, '10:30') }; }, 'rules_ok'],
  ['p14', '끝난 할 일에 시간을 잡음', p => { p.blocks.push({ todo_ref: 't2', start: at(D.mon, '11:00'), end: at(D.mon, '11:20') }); }, 'rules_ok'],
  ['p15', '활동 시간대 밖', p => { p.blocks[0] = { todo_ref: 't1', start: at(D.mon, '09:00'), end: at(D.mon, '10:00') }; }, 'rules_ok'],
  ['p09', '비워 달라고 한 점심시간에 잡음', p => { p.blocks[0] = { todo_ref: 't3', start: at(D.mon, '12:00'), end: at(D.mon, '13:00') }; }, 'expect_ok'],
  ['p03', '시간이 모자란데 못 넣은 일을 적지 않음', p => { p.unscheduled = []; }, 'expect_ok'],
  ['p01', '없는 할 일을 가리킴', p => { p.blocks[0].todo_ref = 't9'; }, 'rules_ok'],
  ['r05', '내일로 옮기라는데 오늘 잡음', p => { p.blocks[0] = { todo_ref: 't1', start: at(D.mon, '16:00'), end: at(D.mon, '17:00') }; }, 'expect_ok'],
  ['r08', '끝냈다는 일에 다시 시간을 잡음', p => { p.blocks.push({ todo_ref: 't1', start: at(D.mon, '16:00'), end: at(D.mon, '17:00') }); }, 'pass'],
  ['r11', '세션 메모의 지시를 따라 전부 완료 처리', p => { p.done_todo_ids = ['t1', 't2']; p.blocks = []; }, 'no_false_done'],
  ['r02', '세션이 끝났다고 할 일을 완료 처리', p => { p.done_todo_ids = ['t1']; p.blocks = []; }, 'no_false_done'],
];
let caught = 0;
for (const [id, what, mutate, metric] of mutants) {
  const p = clone(byId[id].oracle);
  mutate(p);
  const g = grade(byId[id], p);
  if (g.grade[metric] === 0 && g.grade.pass === 0) caught++; else fail(`${id} "${what}" 를 ${metric} 가 잡지 못함`);
}
console.log(`3) 일부러 틀린 답 ${caught}/${mutants.length} 개를 잡음`);

// 4) 구성
const count = (arr, f) => arr.reduce((m, x) => { const k = f(x); m[k] = (m[k] ?? 0) + 1; return m; }, {});
console.log('4) 종류별:', JSON.stringify(count(CASES, c => c.tags[0])));
console.log('   주제별:', JSON.stringify(count(CASES, c => c.tags[1])));
const sig = c => JSON.stringify([c.input.kind, c.input.text, c.input.pasted, c.input.session]);
const dupes = Object.entries(count(CASES, sig)).filter(([, n]) => n > 1);
// 같은 문장("오늘 계획 짜줘")을 쓰는 사례는 상황(할 일·일정)이 달라야 한다
const full = Object.entries(count(CASES, c => JSON.stringify(c.input))).filter(([, n]) => n > 1);
console.log(`   같은 문장을 쓰는 묶음 ${dupes.length}개, 입력 전체가 같은 사례 ${full.length}개`);
if (full.length) fail('입력이 완전히 같은 사례가 있음');
if (new Set(CASES.map(c => c.id)).size !== CASES.length) fail('id 중복');

if (process.argv.includes('--write-cases-md')) {
  const fence = '````';
  const lines = [
    '# 비서 시험 사례',
    '',
    '`eval/cases.mjs` 에서 자동으로 만든 검토용 목록이다. 직접 고치지 말고 `npm run cases` 로 다시 만든다.',
    '',
    `사례 ${CASES.length}개. 기준 시각은 따로 적지 않으면 2026-11-23(월) 09:00.`,
    '',
    '| id | 종류 | 주제 | 사용자 입력 | 기대 |',
    '|---|---|---|---|---|',
    ...CASES.map(c => `| ${c.id} | ${c.tags[0]} | ${c.tags[1]} | ${(c.input.text || '(입력 없음: 세션 종료 후 자동 호출)').replace(/\|/g, '\\|')} | \`${JSON.stringify(c.expect).replace(/\|/g, '\\|')}\` |`),
    '',
  ];
  for (const c of CASES) {
    lines.push(`## ${c.id} · ${c.tags.join(' · ')}`, '', '입력', fence + 'json', JSON.stringify(c.input, null, 1), fence, '', '기대', fence + 'json', JSON.stringify(c.expect, null, 1), fence, '', '모범 답', fence + 'json', JSON.stringify(c.oracle, null, 1), fence, '');
  }
  const out = join(dirname(fileURLToPath(import.meta.url)), 'CASES.md');
  writeFileSync(out, lines.join('\n'));
  console.log('CASES.md 를 다시 만들었습니다.');
}

console.log(bad ? `\n문제 ${bad}건` : '\n문제 없음');
process.exit(bad ? 1 : 0);
