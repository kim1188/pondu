// 비서의 진입점. 서버 함수(assistant)와 시험 세트가 같은 코드를 부른다.
// Anthropic 클라이언트는 주입할 수 있다(시험·서버 테스트는 가짜 클라이언트를 넣는다).
// 이 파일은 SDK를 직접 가져오지 않는다. Deno(서버 함수)와 node 모두에서 같은 파일이 돌게 하려는 것이다.
import { SYSTEM_PROMPT, buildUserMessage } from './prompt.mjs';
import { PROPOSAL_SCHEMA } from './schema.mjs';
import { validate } from './validate.mjs';

export const DEFAULT_MODEL = 'claude-opus-5-5';

// 구조화 출력 형식. 스키마는 SDK의 json-schema 변환이 건드릴 것이 없는 모양이다(additionalProperties:false, 지원되지 않는 제약 없음).
export const OUTPUT_FORMAT = { type: 'json_schema', schema: PROPOSAL_SCHEMA };

let defaultClient;
async function getDefaultClient() {
  if (!defaultClient) {
    const { default: Anthropic } = await import('@anthropic-ai/sdk');
    defaultClient = new Anthropic();
  }
  return defaultClient;
}

/** 모델이 쓴 JSON 글을 제안으로 읽는다. 형식이 어긋나면 null. */
export function parseProposal(text) {
  let o;
  try { o = JSON.parse(text); } catch { return null; }
  if (!o || typeof o !== 'object') return null;
  for (const k of ['todos', 'blocks', 'done_todo_ids', 'unscheduled', 'questions']) if (!Array.isArray(o[k])) return null;
  if (typeof o.message !== 'string') return null;
  return o;
}

/**
 * 모델을 한 번 부른다(스트리밍). 규칙 위반 재요청과 블록 제외는 run.mjs가 한다.
 * @param {object} input  요청 하나(kind, now, text, todos, busy, blocks, prefs, pasted, session)
 * @param {{client?: object, model?: string, effort?: string, fallbacks?: boolean,
 *   onText?: (delta: string) => void, signal?: AbortSignal,
 *   retryFrom?: {rawText: string, feedback: string}}} [opts]
 *   fallbacks: 모델이 답을 거절했을 때 서버가 다른 모델로 다시 시도하게 한다(기본 켬).
 *   시험에서는 어떤 모델이 답했는지가 섞이면 안 되므로 끈다.
 *   retryFrom: 이전 답과 위반 안내. 있으면 [요청, 이전 답, 안내] 순으로 다시 묻는다.
 */
export async function attempt(input, opts = {}) {
  const client = opts.client ?? await getDefaultClient();
  const model = opts.model ?? DEFAULT_MODEL;
  const system = SYSTEM_PROMPT;
  const userMessage = buildUserMessage(input);
  const messages = [{ role: 'user', content: userMessage }];
  if (opts.retryFrom) {
    messages.push({ role: 'assistant', content: opts.retryFrom.rawText });
    messages.push({ role: 'user', content: opts.retryFrom.feedback });
  }
  const params = {
    model,
    max_tokens: 16000,
    system,
    messages,
    output_config: { effort: opts.effort ?? 'low', format: OUTPUT_FORMAT },
  };
  // Haiku 계열은 서버 측 대체 모델을 지원하지 않는다.
  const useFallbacks = (opts.fallbacks ?? true) && !model.startsWith('claude-haiku');
  const reqOpts = opts.signal ? { signal: opts.signal } : undefined;
  const stream = useFallbacks
    ? client.beta.messages.stream({ ...params, betas: ['server-side-fallback-2026-07-01'], fallbacks: 'default' }, reqOpts)
    : client.messages.stream(params, reqOpts);
  if (opts.onText) stream.on('text', delta => opts.onText(delta));
  const response = await stream.finalMessage();

  const rawText = response.content.filter(b => b.type === 'text').map(b => b.text).join('');
  const proposal = response.stop_reason === 'end_turn' ? parseProposal(rawText) : null;
  return {
    proposal,
    violations: proposal ? validate(input, proposal) : [],
    model: response.model,
    usage: response.usage,
    stop_reason: response.stop_reason,
    system,
    userMessage,
    rawText,
  };
}

/** 시험 세트용 진입점: 모델을 한 번 부르고 규칙 위반을 있는 그대로 돌려준다(재요청·제외 없음). */
export const propose = attempt;
