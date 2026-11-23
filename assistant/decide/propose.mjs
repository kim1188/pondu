// 결정 모델 경로의 진입점. core 의 propose 와 같은 모양으로 돌려줘서 같은 채점기로 잴 수 있다.
import { validate } from '../core/validate.mjs';
import { run } from './loop.mjs';
import { scheduleMachine, toProposal } from './schedule.mjs';

/**
 * @param {object} input  core 와 같은 요청 하나(plan_day 또는 reschedule)
 * @param {{decider: import('./loop.mjs').Decider, model?: string}} opts
 */
export async function proposeByDeciding(input, { decider, model }) {
  const machine = scheduleMachine(input);
  const result = await run(machine, decider);
  const proposal = result.ended === 'done' ? toProposal(input, result.state) : null;
  return {
    proposal,
    // 선택지가 전부 규칙을 지키므로 여기는 항상 비어 있어야 한다. 비어 있지 않으면 선택지를 만드는 코드의 버그다.
    violations: proposal ? validate(input, proposal) : [],
    model: result.model ?? model ?? null,
    usage: result.usage,
    stop_reason: result.ended === 'done' ? 'end_turn' : result.ended,
    trace: result.trace,
    system: '(결정 모델 경로: 시스템 프롬프트 없음. 단계별 보기와 질문은 아래 기록에 있다)',
    userMessage: JSON.stringify(result.trace.map(t => ({ step: t.step, view: t.view, questions: t.questions })), null, 1),
    rawText: JSON.stringify({ answers: result.trace.map(t => t.answers), proposal }, null, 1),
  };
}
