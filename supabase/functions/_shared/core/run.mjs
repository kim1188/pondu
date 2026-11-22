// 서버가 쓰는 전체 흐름: 호출 → (규칙 위반이면) 한 번 재요청 → 그래도 걸린 블록은 빼기.
// message는 첫 호출에서만 흘려보낸다. 재요청이 일어나면 최종 message가 다를 수 있으니 proposal.message를 따른다.
import { dropViolations } from './drop.mjs';
import { attempt } from './propose.mjs';
import { MessageExtractor } from './stream-message.mjs';

export class AssistantError extends Error {
  constructor(code, detail) { super(detail ?? code); this.code = code; }
}

export function feedbackFor(violations) {
  const lines = violations.map(v => `- ${v.rule}: ${v.detail}`).join('\n');
  return `방금 제안이 아래 규칙을 어겼습니다. 같은 형식으로 고쳐서 다시 답하세요. 사용자가 말하지 않은 내용을 새로 만들지 말고, 걸린 부분만 고치세요.\n${lines}`;
}

/**
 * @param {object} input core 입력
 * @param {{client?: object, model?: string, effort?: string, fallbacks?: boolean, signal?: AbortSignal,
 *   onMessageDelta?: (text: string) => void}} opts
 * @returns {Promise<{proposal: object, dropped: object[], retried: boolean, model: string, usage: {input_tokens: number, output_tokens: number}}>}
 */
export async function runProposal(input, opts = {}) {
  const extractor = new MessageExtractor();
  const onText = opts.onMessageDelta
    ? d => { const t = extractor.push(d); if (t) opts.onMessageDelta(t); }
    : undefined;
  const base = { client: opts.client, model: opts.model, effort: opts.effort, fallbacks: opts.fallbacks, signal: opts.signal };

  const usage = { input_tokens: 0, output_tokens: 0 };
  const addUsage = r => {
    usage.input_tokens += r.usage?.input_tokens ?? 0;
    usage.output_tokens += r.usage?.output_tokens ?? 0;
  };

  const first = await attempt(input, { ...base, onText });
  addUsage(first);
  if (!first.proposal) throw new AssistantError('assistant_unavailable', `no usable answer (${first.stop_reason})`);

  let chosen = first;
  let retried = false;
  if (first.violations.length) {
    retried = true;
    try {
      const second = await attempt(input, { ...base, retryFrom: { rawText: first.rawText, feedback: feedbackFor(first.violations) } });
      addUsage(second);
      if (second.proposal) chosen = second;
    } catch (e) {
      if (opts.signal?.aborted) throw e;
      // 재요청이 실패하면 첫 답에서 걸린 부분만 빼고 간다.
    }
  }

  const { proposal, dropped, remaining } = dropViolations(input, chosen.proposal);
  if (remaining.length) {
    throw new AssistantError('assistant_unavailable', `unfixable: ${remaining.map(v => v.rule).join(',')}`);
  }
  return { proposal, dropped, retried, model: chosen.model, usage };
}
