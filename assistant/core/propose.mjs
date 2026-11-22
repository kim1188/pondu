// 비서의 진입점. 서버 함수(assistant)와 시험 세트가 같은 함수를 부른다.
import Anthropic from '@anthropic-ai/sdk';
import { jsonSchemaOutputFormat } from '@anthropic-ai/sdk/helpers/json-schema';
import { SYSTEM_PROMPT, buildUserMessage } from './prompt.mjs';
import { PROPOSAL_SCHEMA } from './schema.mjs';
import { validate } from './validate.mjs';

export const DEFAULT_MODEL = 'claude-opus-5-5';

let client;

/**
 * @param {object} input  요청 하나(kind, now, text, todos, busy, blocks, prefs, pasted, session)
 * @param {{model?: string, effort?: string, fallbacks?: boolean}} [opts]
 *   fallbacks: 모델이 답을 거절했을 때 서버가 다른 모델로 다시 시도하게 한다(기본 켬).
 *   시험에서는 어떤 모델이 답했는지가 섞이면 안 되므로 끈다.
 */
export async function propose(input, opts = {}) {
  client ??= new Anthropic();
  const model = opts.model ?? DEFAULT_MODEL;
  const system = SYSTEM_PROMPT;
  const userMessage = buildUserMessage(input);
  const params = {
    model,
    max_tokens: 16000,
    system,
    messages: [{ role: 'user', content: userMessage }],
    output_config: {
      effort: opts.effort ?? 'low',
      format: jsonSchemaOutputFormat(PROPOSAL_SCHEMA),
    },
  };
  // Haiku 계열은 서버 측 대체 모델을 지원하지 않는다.
  const useFallbacks = (opts.fallbacks ?? true) && !model.startsWith('claude-haiku');
  const response = useFallbacks
    ? await client.beta.messages.parse({ ...params, betas: ['server-side-fallback-2026-07-01'], fallbacks: 'default' })
    : await client.messages.parse(params);

  const usable = response.stop_reason === 'end_turn' && response.parsed_output != null;
  const proposal = usable ? response.parsed_output : null;
  return {
    proposal,
    violations: proposal ? validate(input, proposal) : [],
    model: response.model,
    usage: response.usage,
    stop_reason: response.stop_reason,
    system,
    userMessage,
    rawText: response.content.filter(b => b.type === 'text').map(b => b.text).join(''),
  };
}
