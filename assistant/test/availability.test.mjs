// 가용 시간 계산(core/availability.mjs). 모델 없이 코드만으로 답한다.
import test from 'node:test';
import assert from 'node:assert/strict';
import { adjustProposal, availability, freeIntervals, planningMinutes, DEFAULT_ESTIMATE_MIN } from '../core/availability.mjs';

const base = {
  now: '2026-11-23T19:00:00+09:00',
  prefs: { day_start: '08:00', day_end: '23:00' },
  busy: [{ start: '2026-11-23T19:00:00+09:00', end: '2026-11-23T21:00:00+09:00' }],
  blocks: [],
  todos: [
    { id: 't1', title: '과제', estimate_min: 180, due_date: '2026-11-25' },
    { id: 't2', title: '복습', estimate_min: 120 },
    { id: 't3', title: '메일', estimate_min: null },
  ],
};

test('예상 시간이 없으면 30분으로 계획한다', () => {
  assert.equal(DEFAULT_ESTIMATE_MIN, 30);
  assert.equal(planningMinutes({ estimate_min: null }), 30);
  assert.equal(planningMinutes({ estimate_min: 50, planning_min: 70 }), 70);
  assert.equal(planningMinutes({ estimate_min: 600 }), 240);
});

test('오늘 빈 시간: 지금 이후, 고정 일정을 뺀 것', () => {
  const free = freeIntervals(base);
  assert.equal(free.length, 1);
  const a = availability(base);
  assert.deepEqual(a.today, { free_minutes: 120, largest_minutes: 120,
    slots: [{ start: '2026-11-23T21:00:00+09:00', end: '2026-11-23T23:00:00+09:00', minutes: 120 }] });
  assert.deepEqual(a.fit_checks, []);
});

test('다 들어가지 않는 일: 오늘 들어가는 만큼과 선택지를 알려 준다', () => {
  const a = availability(base, { blocks: [], unscheduled: [{ todo_ref: 't1', reason: '' }] });
  assert.deepEqual(a.fit_checks, [{ todo_ref: 't1', needed_minutes: 180, largest_today_minutes: 120,
    largest_before_due_minutes: 900, fits_within_days: 2, options: ['partial_today', 'move_later', 'skip'],
    partial_slot: { start: '2026-11-23T21:00:00+09:00', end: '2026-11-23T23:00:00+09:00', minutes: 120 },
    full_slot: { start: '2026-11-24T08:00:00+09:00', end: '2026-11-24T11:00:00+09:00', minutes: 180 } }]);
});

test('제안이 잡은 블록은 빈 시간에서 뺀다', () => {
  const proposal = {
    blocks: [{ todo_ref: 't2', start: '2026-11-23T21:00:00+09:00', end: '2026-11-23T23:00:00+09:00' }],
    unscheduled: [{ todo_ref: 't1', reason: '' }, { todo_ref: 't3', reason: '' }],
  };
  const a = availability(base, proposal);
  assert.equal(a.today.free_minutes, 0);
  assert.deepEqual(a.fit_checks.map(f => [f.todo_ref, f.needed_minutes, f.largest_today_minutes, f.options]), [
    ['t1', 180, 0, ['move_later', 'skip']],
    ['t3', 30, 0, ['move_later', 'skip']],
  ]);
});

test('사실은 오늘 자리가 있는 일은 place_today 를 낸다', () => {
  const a = availability(base, { blocks: [], unscheduled: [{ todo_ref: 't2', reason: '' }] });
  assert.deepEqual(a.fit_checks[0].options, ['place_today', 'skip']);
});

const asked = {
  todos: [{ title: '영어 단어', due_date: null, due_time: null, estimate_min: null, category: null }],
  blocks: [
    { todo_ref: 't3', start: '2026-11-23T21:00:00+09:00', end: '2026-11-23T21:30:00+09:00' },
    { todo_ref: 'new:0', start: '2026-11-23T21:30:00+09:00', end: '2026-11-23T22:00:00+09:00' },
  ],
  done_todo_ids: [], unscheduled: [{ todo_ref: 't1', reason: '' }], estimate_asks: ['t3', 'new:0'], questions: [], message: 'm',
};

test('답한 예상 시간: 줄이면 블록이 짧아지고, 새 할 일은 예상 시간이 채워진다', () => {
  const r = adjustProposal(base, asked, { estimates: [{ todo_ref: 't3', minutes: 15 }, { todo_ref: 'new:0', minutes: 60 }] });
  assert.equal(r.proposal.blocks[0].end, '2026-11-23T21:15:00+09:00');
  assert.equal(r.proposal.blocks[1].end, '2026-11-23T22:30:00+09:00');
  assert.equal(r.proposal.todos[0].estimate_min, 60);
  assert.deepEqual(r.proposal.estimate_asks, []);
  assert.deepEqual(r.estimate_updates, [{ todo_id: 't3', minutes: 15 }]);
  assert.deepEqual(r.rejected, []);
  assert.equal(asked.blocks[0].end, '2026-11-23T21:30:00+09:00', '원래 제안은 바꾸지 않는다');
});

test('답한 예상 시간: 늘릴 자리가 없으면 못 넣은 일로 돌리고 가용 시간 점검이 붙는다', () => {
  // t3 를 60분으로 늘리면 바로 뒤의 new:0 과 겹친다.
  const r = adjustProposal(base, asked, { estimates: [{ todo_ref: 't3', minutes: 60 }] });
  assert.deepEqual(r.proposal.blocks.map(b => b.todo_ref), ['new:0']);
  assert.equal(r.proposal.unscheduled.at(-1).todo_ref, 't3');
  const check = availability(r.input, r.proposal).fit_checks.find(f => f.todo_ref === 't3');
  assert.equal(check.needed_minutes, 60);
  assert.deepEqual(check.options, ['place_today', 'skip']); // 22:00~23:00 에 들어간다
});

test('묻지 않은 일이나 범위 밖의 값은 받지 않는다', () => {
  const r = adjustProposal(base, asked, { estimates: [{ todo_ref: 't2', minutes: 30 }, { todo_ref: 't3', minutes: 5 }] });
  assert.deepEqual(r.rejected, [{ todo_ref: 't2', reason: 'not_asked' }, { todo_ref: 't3', reason: 'minutes' }]);
  assert.deepEqual(r.proposal.blocks, asked.blocks);
});

test('다 들어가지 않는 일: 고른 선택지대로 자리를 잡는다', () => {
  const part = adjustProposal(base, { ...asked, blocks: [], estimate_asks: [] }, { fits: [{ todo_ref: 't1', option: 'partial_today' }] });
  assert.deepEqual(part.proposal.blocks, [{ todo_ref: 't1', start: '2026-11-23T21:00:00+09:00', end: '2026-11-23T23:00:00+09:00' }]);
  assert.deepEqual(part.proposal.unscheduled, []);
  const later = adjustProposal(base, asked, { fits: [{ todo_ref: 't1', option: 'move_later' }] });
  assert.deepEqual(later.proposal.blocks.at(-1), { todo_ref: 't1', start: '2026-11-24T08:00:00+09:00', end: '2026-11-24T11:00:00+09:00' });
  // 고를 수 없는 선택지는 받지 않는다(t1 은 오늘 다 들어가지 않으므로 place_today 가 없다).
  const bad = adjustProposal(base, asked, { fits: [{ todo_ref: 't1', option: 'place_today' }] });
  assert.deepEqual(bad.rejected, [{ todo_ref: 't1', reason: 'option' }]);
  assert.equal(bad.proposal.blocks.length, 2);
});
