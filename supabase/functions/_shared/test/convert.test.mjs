import test from 'node:test';
import assert from 'node:assert/strict';
import { blockToCore, coreTodoToServer, todoToCore, toKst } from '../convert.mjs';

const todo = (extra = {}) => ({ id: 'a', title: 't', due_at: null, due_has_time: false, estimate_min: 45, status: 'open', ...extra });

test('시각 없는 마감: 한국 날짜만, due_time은 null', () => {
  const c = todoToCore(todo({ due_at: '2026-11-27T14:59:00Z', due_has_time: false }));
  assert.equal(c.due_date, '2026-11-27');
  assert.equal(c.due_time, null);
});

test('시각 있는 마감: UTC를 한국 시간으로 바꾼다(날짜 경계 포함)', () => {
  const c = todoToCore(todo({ due_at: '2026-11-23T15:30:00Z', due_has_time: true }));
  assert.equal(c.due_date, '2026-11-24'); // 한국은 다음 날 00:30
  assert.equal(c.due_time, '00:30');
});

test('마감이 없으면 둘 다 null, 나머지 필드는 그대로', () => {
  const c = todoToCore(todo(), { category: 'study' });
  assert.deepEqual(c, { id: 'a', title: 't', due_date: null, due_time: null, estimate_min: 45, status: 'open', category: 'study' });
});

test('core → 서버: 날짜만이면 그날 23:59(KST) 마감, due_has_time=false', () => {
  const s = coreTodoToServer({ title: 'x', due_date: '2026-11-27', due_time: null, estimate_min: null, category: 'coding' });
  assert.equal(s.due_at, '2026-11-27T14:59:00.000Z');
  assert.equal(s.due_has_time, false);
  assert.equal(s.category, 'coding');
});

test('core → 서버: 시각까지 있으면 그 시각, due_has_time=true', () => {
  const s = coreTodoToServer({ title: 'x', due_date: '2026-11-24', due_time: '00:30', estimate_min: 20, category: null });
  assert.equal(s.due_at, '2026-11-23T15:30:00.000Z');
  assert.equal(s.due_has_time, true);
  assert.equal(s.estimate_min, 20);
});

test('서버 ↔ core 왕복이 같은 마감을 돌려준다', () => {
  for (const [at, has] of [['2026-11-23T15:30:00Z', true], ['2026-11-27T14:59:00Z', false], ['2026-12-31T14:59:00Z', false], ['2027-01-01T00:00:00Z', true]]) {
    const core = todoToCore(todo({ due_at: at, due_has_time: has }));
    const back = coreTodoToServer({ ...core, category: null });
    assert.equal(back.due_has_time, has, at);
    if (has) assert.equal(back.due_at, new Date(at).toISOString(), at);
    else assert.equal(todoToCore(todo({ due_at: back.due_at, due_has_time: false })).due_date, core.due_date, at);
  }
});

test('형식이 틀린 날짜·시각은 마감 없음으로 취급', () => {
  assert.equal(coreTodoToServer({ title: 'x', due_date: '내일', due_time: '9시' }).due_at, null);
  assert.equal(coreTodoToServer({ title: 'x', due_date: '2026-11-24', due_time: '25:99' }).due_has_time, false);
});

test('블록 변환: UTC → +09:00, 잠금 여부 유지', () => {
  const b = blockToCore({ id: 'b1', todo_id: 't1', start_at: '2026-11-23T06:00:00Z', end_at: '2026-11-23T07:30:00Z', locked: true, status: 'planned' });
  assert.deepEqual(b, { id: 'b1', todo_ref: 't1', start: '2026-11-23T15:00:00+09:00', end: '2026-11-23T16:30:00+09:00', locked: true, status: 'planned' });
  assert.equal(toKst('garbage'), null);
});
