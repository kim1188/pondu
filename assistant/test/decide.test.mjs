// 결정 모델 경로(decide/) 시험. 모델을 부르지 않는다.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { fakeDecider, openaiDecisions } from '../decide/deciders.mjs';
import { run } from '../decide/loop.mjs';
import { proposeByDeciding } from '../decide/propose.mjs';
import { scheduleMachine } from '../decide/schedule.mjs';
import { CASES } from '../eval/cases.mjs';
import { grade } from '../eval/grade.mjs';

const SCHEDULING = CASES.filter(c => c.input.kind !== 'capture');

test('어떤 선택을 해도 규칙 위반이 나오지 않는다(첫 자리, 마지막 자리, 무작위)', async () => {
  let seed = 7;
  const rand = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
  const strategies = {
    first: cs => (cs.find(c => c.value !== 'skip') ?? cs[0]).value,
    last: cs => (cs.filter(c => c.value !== 'skip').at(-1) ?? cs[0]).value,
    random: cs => cs[Math.floor(rand() * cs.length)].value,
  };
  for (const [name, pick] of Object.entries(strategies)) {
    for (const c of SCHEDULING) {
      for (const p of [0, 1]) { // 끝냈다는 질문에 전부 거짓 / 전부 참
        const r = await proposeByDeciding(c.input, { decider: fakeDecider({ pick, bool: () => p }) });
        assert.ok(r.proposal, `${c.id}: 제안이 없음`);
        assert.deepEqual(r.violations, [], `${c.id} (${name}, done=${p}): ${JSON.stringify(r.violations)}`);
      }
    }
  }
});

test('가장 이른 자리만 고르는 결정기로도 대부분의 배치 사례를 통과한다', async () => {
  const failed = [];
  for (const c of SCHEDULING) {
    const r = await proposeByDeciding(c.input, { decider: fakeDecider() });
    const g = grade(c, r.proposal);
    if (!g.grade.pass) failed.push(`${c.id}: ${g.explanation.pass}`);
  }
  // 사용자의 말을 읽어야 풀리는 사례(시간대 바람, 하나만, 끝냈다는 말, 새 할 일)는 가짜 결정기로 못 푼다.
  console.log(`가짜 결정기 통과 ${SCHEDULING.length - failed.length}/${SCHEDULING.length}\n  ` + failed.join('\n  '));
  assert.ok(failed.length <= 10, failed.join('\n'));
});

test('끝냈다는 답이 확률 0.8 이상일 때만 완료로 표시하고 그 일에는 시간을 잡지 않는다', async () => {
  const c = CASES.find(x => x.id === 'r08');
  const sure = await proposeByDeciding(c.input, { decider: fakeDecider({ bool: id => (id === 'done:t1' ? 0.95 : 0.01) }) });
  assert.deepEqual(sure.proposal.done_todo_ids, ['t1']);
  assert.ok(!sure.proposal.blocks.some(b => b.todo_ref === 't1'));
  assert.equal(grade(c, sure.proposal).grade.pass, 1);
  const unsure = await proposeByDeciding(c.input, { decider: fakeDecider({ bool: () => 0.7 }) });
  assert.deepEqual(unsure.proposal.done_todo_ids, []);
});

test('오늘은 여기까지로 끝낸 일은 오늘 자리가 선택지에 없다', async () => {
  const c = CASES.find(x => x.id === 'r10');
  const m = scheduleMachine(c.input);
  const q = m.questions(m.initial());
  assert.ok(q.slot.choices.length > 1);
  assert.ok(q.slot.choices.every(ch => !ch.description.startsWith('오늘')), JSON.stringify(q.slot.choices));
});

test('허용하지 않은 선택이나 빠진 답은 그 단계에서 멈춘다', async () => {
  const m = scheduleMachine(CASES.find(x => x.id === 'r02').input); // 사용자 말이 없어 바로 자리 고르기부터 시작한다
  await assert.rejects(run(m, async () => ({ answers: { slot: { type: 'choice', choice: 'nope' } } })), /허용하지 않은 선택/);
  await assert.rejects(run(m, async () => ({ answers: {} })), /답하지 않음/);
});

test('모든 질문은 선택지가 2개 이상이다(자리가 없는 일은 묻지 않고 넘긴다)', async () => {
  let asked = 0;
  for (const c of SCHEDULING) {
    const r = await proposeByDeciding(c.input, { decider: async req => {
      for (const q of Object.values(req.questions)) if (q.type === 'choice') { asked++; assert.ok(q.choices.length >= 2, `${c.id}: 선택지 ${q.choices.length}개`); }
      return fakeDecider()(req);
    } });
    assert.ok(r.proposal, c.id);
  }
  assert.ok(asked > 20);
  // 시간이 모자란 사례: 못 넣은 일은 모델에 묻지 않고도 unscheduled 에 들어간다
  const p07 = await proposeByDeciding(CASES.find(x => x.id === 'p07').input, { decider: fakeDecider() });
  assert.ok(p07.proposal.unscheduled.length >= 1);
  // 할 일이 없으면 모델을 부르지 않는다
  const p06 = await proposeByDeciding(CASES.find(x => x.id === 'p06').input, { decider: async () => { throw new Error('부르면 안 됨'); } });
  assert.equal(p06.usage.requests, 0);
});

test('capture 는 이 도메인이 다루지 않는다', () => {
  assert.throws(() => scheduleMachine(CASES.find(x => x.id === 'c01').input), /다루지 않음/);
});

test('Decisions API 요청 모양과 응답 읽기', async () => {
  let sent;
  const decider = openaiDecisions({ apiKey: 'k', fetchImpl: async (url, init) => {
    sent = { url, body: JSON.parse(init.body), auth: init.headers.authorization };
    return new Response(JSON.stringify({
      answers: [{ type: 'predicate', name: 'done:t1', probability: 0.9 },
                { type: 'choice', name: 'slot', choice: 'skip', confidence: 0.6, probabilities: [{ value: 'skip', probability: 0.6 }, { value: 'slot0', probability: 0.4 }] }],
      usage: { input_tokens: 321 } }), { status: 200 });
  } });
  const r = await decider({ view: { a: 1 }, questions: {
    'done:t1': { type: 'bool', instructions: 'x' },
    slot: { type: 'choice', instructions: 'y', choices: [{ value: 'slot0', description: 'd' }, { value: 'skip' }] } } });
  assert.equal(sent.url, 'https://api.openai.com/v1/decisions');
  assert.equal(sent.auth, 'Bearer k');
  assert.equal(sent.body.model, 'gpt-6-luna');
  assert.equal(sent.body.input, '{"a":1}');
  assert.deepEqual(sent.body.questions.map(q => q.type), ['predicate', 'choice']);
  assert.equal(r.answers['done:t1'].probability, 0.9);
  assert.equal(r.answers.slot.choice, 'skip');
  assert.equal(r.answers.slot.probabilities.slot0, 0.4);
  assert.equal(r.usage.input_tokens, 321);
});
