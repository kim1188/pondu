import test from 'node:test';
import assert from 'node:assert/strict';
import { dropViolations } from '../core/drop.mjs';
import { AssistantError, runProposal } from '../core/run.mjs';
import { validate } from '../core/validate.mjs';
import { at } from '../core/time.mjs';
import { chars, fakeClient } from './fake-client.mjs';

const NOW = '2026-11-23T09:00:00+09:00';
const input = (extra = {}) => ({
  kind: 'plan_day', now: NOW, text: '오늘 계획 잡아 줘', pasted: null, prefs: { day_start: '08:00', day_end: '23:00' },
  todos: [{ id: 't1', title: 'DB 과제', due_date: null, due_time: null, estimate_min: 60, status: 'open' },
          { id: 't2', title: '운동', due_date: null, due_time: null, estimate_min: 30, status: 'open' }],
  busy: [{ start: at('2026-11-23', '13:00'), end: at('2026-11-23', '14:00') }], blocks: [], session: null, ...extra,
});
const P = (p = {}) => ({ message: '배치했어요.', todos: [], blocks: [], done_todo_ids: [], unscheduled: [], questions: [], ...p });
const B = (ref, s, e) => ({ todo_ref: ref, start: at('2026-11-23', s), end: at('2026-11-23', e) });
const j = o => JSON.stringify(o);

const GOOD = P({ blocks: [B('t1', '10:00', '11:00'), B('t2', '15:00', '15:30')] });
const BAD_ONE = P({ blocks: [B('t1', '10:00', '11:00'), B('t2', '13:30', '14:00')] }); // t2가 고정 일정과 겹침

test('위반이 없으면 한 번만 부른다', async () => {
  const c = fakeClient([j(GOOD)]);
  const r = await runProposal(input(), { client: c });
  assert.equal(c.calls.length, 1);
  assert.equal(r.retried, false);
  assert.deepEqual(r.dropped, []);
  assert.equal(r.proposal.blocks.length, 2);
});

test('위반이 있으면 이전 답과 위반 안내를 붙여 한 번 다시 요청한다', async () => {
  const c = fakeClient([j(BAD_ONE), j(GOOD)]);
  const r = await runProposal(input(), { client: c });
  assert.equal(c.calls.length, 2);
  assert.equal(r.retried, true);
  assert.deepEqual(r.dropped, []);
  assert.equal(r.proposal.blocks.length, 2);
  const m = c.calls[1].params.messages;
  assert.deepEqual(m.map(x => x.role), ['user', 'assistant', 'user']);
  assert.equal(m[1].content, j(BAD_ONE));
  assert.match(m[2].content, /busy_overlap/);
  assert.equal(r.usage.input_tokens, 200); // 두 번 합산
});

test('재요청에서도 걸린 블록은 그 블록만 빼고 dropped에 담는다', async () => {
  const c = fakeClient([j(BAD_ONE), j(BAD_ONE)]);
  const r = await runProposal(input(), { client: c });
  assert.equal(c.calls.length, 2, '재요청은 한 번뿐');
  assert.equal(r.proposal.blocks.length, 1);
  assert.equal(r.proposal.blocks[0].todo_ref, 't1');
  assert.equal(r.dropped.length, 1);
  assert.equal(r.dropped[0].rule, 'busy_overlap');
  assert.deepEqual(validate(input(), r.proposal), [], '남은 제안은 규칙을 통과한다');
});

test('재요청이 실패하면 첫 답에서 걸린 블록만 빼고 간다', async () => {
  const c = fakeClient([j(BAD_ONE), { throws: 'overloaded' }]);
  const r = await runProposal(input(), { client: c });
  assert.equal(r.proposal.blocks.length, 1);
  assert.equal(r.dropped.length, 1);
});

test('재요청이 거절·잘림이면 첫 답을 쓴다', async () => {
  const c = fakeClient([j(BAD_ONE), { text: '', stop_reason: 'refusal' }]);
  const r = await runProposal(input(), { client: c });
  assert.equal(r.proposal.blocks.length, 1);
});

test('블록끼리 겹치면 뒤의 것만 빼고, 할 일 쪽 위반은 건드리지 않는다', () => {
  const p = P({ blocks: [B('t1', '10:00', '11:00'), B('t2', '10:30', '11:00'), B('t2', '16:00', '16:30')] });
  const { proposal, dropped, remaining } = dropViolations(input(), p);
  assert.equal(proposal.blocks.length, 2);
  assert.deepEqual(proposal.blocks.map(b => b.start.slice(11, 16)), ['10:00', '16:00']);
  assert.equal(dropped.length, 1);
  assert.equal(remaining.length, 0);
});

test('capture 요청에 블록이 있으면 전부 뺀다', () => {
  const p = P({ blocks: [B('t1', '10:00', '11:00')] });
  const { proposal, dropped } = dropViolations(input({ kind: 'capture' }), p);
  assert.deepEqual(proposal.blocks, []);
  assert.equal(dropped[0].rule, 'capture_no_blocks');
});

test('없는 할 일을 완료 처리하거나 가리키는 항목은 빼낸다', () => {
  const p = P({ done_todo_ids: ['t1', 'zzz'], unscheduled: [{ todo_ref: 'nope', reason: 'x' }], blocks: [B('nope', '10:00', '11:00')] });
  const { proposal, dropped, remaining } = dropViolations(input(), p);
  assert.deepEqual(proposal.done_todo_ids, ['t1']);
  assert.deepEqual(proposal.unscheduled, []);
  assert.deepEqual(proposal.blocks, []);
  assert.equal(remaining.length, 0);
  assert.equal(dropped.length, 3);
});

test('블록으로 고칠 수 없는 위반(할 일 형식)이 남으면 assistant_unavailable', async () => {
  const bad = P({ todos: [{ title: 'x', due_date: '내일', due_time: null, estimate_min: null, category: null }] });
  const c = fakeClient([j(bad), j(bad)]);
  await assert.rejects(runProposal(input({ kind: 'capture' }), { client: c }), e => e instanceof AssistantError && e.code === 'assistant_unavailable');
});

test('거절·형식 오류·잘림이면 assistant_unavailable', async () => {
  for (const r of [{ text: '', stop_reason: 'refusal' }, { text: '{"todos":', stop_reason: 'max_tokens' }, { text: 'not json' }, { text: '{"todos":[]}' }]) {
    await assert.rejects(runProposal(input(), { client: fakeClient([r]) }), e => e.code === 'assistant_unavailable');
  }
});

test('message를 먼저 흘려보낸다(첫 호출에서만, 조각 단위로)', async () => {
  const c = fakeClient([{ chunks: chars(j(GOOD)) }]);
  const got = [];
  await runProposal(input(), { client: c, onMessageDelta: t => got.push(t) });
  assert.equal(got.join(''), GOOD.message);
  assert.ok(got.length > 1);

  const c2 = fakeClient([{ chunks: chars(j(BAD_ONE)) }, { chunks: chars(j(GOOD)) }]);
  const got2 = [];
  await runProposal(input(), { client: c2, onMessageDelta: t => got2.push(t) });
  assert.equal(got2.join(''), BAD_ONE.message, '재요청 답은 흘려보내지 않는다');
});

test('요청 모양: 구조화 출력, 대체 모델(beta) 사용, 끄면 일반 경로, haiku는 끈다', async () => {
  const c = fakeClient([j(GOOD)]);
  await runProposal(input(), { client: c, model: 'claude-opus-5-5' });
  assert.equal(c.calls[0].kind, 'beta');
  assert.equal(c.calls[0].params.fallbacks, 'default');
  assert.deepEqual(c.calls[0].params.betas, ['server-side-fallback-2026-07-01']);
  const f = c.calls[0].params.output_config.format;
  assert.equal(f.type, 'json_schema');
  assert.equal(f.schema.properties.message.type, 'string');
  assert.equal(Object.keys(f.schema.properties)[0], 'message', 'message가 맨 앞이어야 먼저 흘려보낼 수 있다');
  assert.equal(c.calls[0].params.model, 'claude-opus-5-5');
  assert.ok(!('temperature' in c.calls[0].params));

  const c2 = fakeClient([j(GOOD)]);
  await runProposal(input(), { client: c2, fallbacks: false });
  assert.equal(c2.calls[0].kind, 'messages');
  const c3 = fakeClient([j(GOOD)]);
  await runProposal(input(), { client: c3, model: 'claude-haiku-5-5' });
  assert.equal(c3.calls[0].kind, 'messages');
});

test('중단 신호가 요청에 전달된다', async () => {
  const ctl = new AbortController();
  const c = fakeClient([j(GOOD)]);
  await runProposal(input(), { client: c, signal: ctl.signal });
  assert.equal(c.calls[0].reqOpts.signal, ctl.signal);
});
