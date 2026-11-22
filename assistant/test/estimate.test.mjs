import test from 'node:test';
import assert from 'node:assert/strict';
import { withPlanningMinutes } from '../core/estimate.mjs';

test('분야별 배수를 곱한 planning_min을 붙이고 estimate_min은 그대로 둔다', () => {
  const out = withPlanningMinutes(
    [{ id: 'a', estimate_min: 60, category: 'study' }, { id: 'b', estimate_min: 30, category: 'coding' }],
    { study: 1.5, coding: 0.8 });
  assert.equal(out[0].planning_min, 90);
  assert.equal(out[0].estimate_min, 60);
  assert.equal(out[1].planning_min, 24);
});

test('예상이 없거나 분야·배수를 모르면 건드리지 않는다', () => {
  const todos = [{ id: 'a', estimate_min: null, category: 'study' }, { id: 'b', estimate_min: 30, category: null }, { id: 'c', estimate_min: 30, category: 'exercise' }];
  assert.deepEqual(withPlanningMinutes(todos, { study: 2 }), todos);
  assert.deepEqual(withPlanningMinutes(todos, undefined), todos);
});

test('배수는 0.5~3.0으로 자르고 결과는 1~1440분', () => {
  const out = withPlanningMinutes([{ estimate_min: 1000, category: 'study' }, { estimate_min: 1, category: 'study' }], { study: 9 });
  assert.equal(out[0].planning_min, 1440);
  assert.equal(out[1].planning_min, 3);
  assert.equal(withPlanningMinutes([{ estimate_min: 10, category: 'study' }], { study: 0.1 })[0].planning_min, 5);
});
