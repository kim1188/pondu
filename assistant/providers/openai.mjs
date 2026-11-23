// OpenAI 채팅 모델로 같은 제안을 받는 경로. 시험 세트에서 모델 비교용으로만 쓴다(서버 함수는 쓰지 않는다).
// 프롬프트, 출력 형식, 규칙 검사는 core의 것을 그대로 쓴다. 달라지는 것은 API 호출 모양뿐이다.
//
// 주의: 이 파일은 실제 OpenAI 서버에 한 번도 호출해 보지 못한 채 쓰였다. 요청 모양은 Responses API의
// 구조화 출력(text.format = json_schema, strict)을 따른다. 첫 실행에서 400이 나면 오류 문구를 보고 고친다.
import { SYSTEM_PROMPT, buildUserMessage } from '../core/prompt.mjs';
import { parseProposal } from '../core/propose.mjs';
import { PROPOSAL_SCHEMA } from '../core/schema.mjs';
import { validate } from '../core/validate.mjs';

let defaultClient;
export async function getOpenAI() {
  if (!defaultClient) {
    const { default: OpenAI } = await import('openai');
    defaultClient = new OpenAI(); // OPENAI_API_KEY 를 환경에서 읽는다
  }
  return defaultClient;
}

/**
 * @param {object} input  core와 같은 요청 하나
 * @param {{client?: object, model: string, effort?: string}} opts
 *   effort: 추론 강도. 주면 reasoning.effort 로 보낸다. 추론을 지원하지 않는 모델은 거절할 수 있으니 기본은 보내지 않는다.
 */
export async function proposeOpenAI(input, opts) {
  const client = opts.client ?? await getOpenAI();
  const system = SYSTEM_PROMPT;
  const userMessage = buildUserMessage(input);
  const params = {
    model: opts.model,
    instructions: system,
    input: userMessage,
    text: { format: { type: 'json_schema', name: 'proposal', strict: true, schema: PROPOSAL_SCHEMA } },
    max_output_tokens: 16000,
  };
  if (opts.effort) params.reasoning = { effort: opts.effort };
  const response = await client.responses.create(params);

  const rawText = response.output_text ?? '';
  const refused = (response.output ?? []).some(o => (o.content ?? []).some(c => c.type === 'refusal'));
  const complete = response.status === 'completed';
  const proposal = complete && !refused ? parseProposal(rawText) : null;
  const u = response.usage ?? {};
  return {
    proposal,
    violations: proposal ? validate(input, proposal) : [],
    model: response.model,
    // 실행기는 Anthropic 모양의 usage(input_tokens, output_tokens)를 읽는다. OpenAI도 같은 이름을 쓴다.
    usage: { input_tokens: u.input_tokens ?? 0, output_tokens: u.output_tokens ?? 0,
             cache_read_input_tokens: u.input_tokens_details?.cached_tokens ?? 0 },
    stop_reason: refused ? 'refusal' : complete ? 'end_turn'
      : (response.incomplete_details?.reason === 'max_output_tokens' ? 'max_tokens' : `incomplete:${response.incomplete_details?.reason ?? response.status}`),
    system,
    userMessage,
    rawText,
  };
}
