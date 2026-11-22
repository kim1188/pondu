// 가짜 Anthropic 클라이언트. 실제 API는 부르지 않는다(키가 없다).
// messages.stream / beta.messages.stream 이 SDK의 MessageStream처럼 .on('text', fn)과 .finalMessage()를 준다.
// responses: 호출 순서대로 돌려줄 답. 문자열이면 그 JSON 글, 객체면 {text, chunks, stop_reason, usage, delayMs}.
export function fakeClient(responses) {
  const calls = [];
  let i = 0;
  const make = (kind, params, reqOpts) => {
    calls.push({ kind, params, reqOpts });
    const r = responses[Math.min(i++, responses.length - 1)];
    const spec = typeof r === 'string' ? { text: r } : r;
    const listeners = [];
    return {
      on(ev, fn) { if (ev === 'text') listeners.push(fn); return this; },
      async finalMessage() {
        if (spec.hang) {
          await new Promise((_, rej) => {
            const sig = reqOpts?.signal;
            if (sig?.aborted) rej(new Error('aborted'));
            sig?.addEventListener('abort', () => rej(new Error('aborted')));
          });
        }
        if (spec.throws) throw new Error(spec.throws);
        const chunks = spec.chunks ?? [spec.text];
        for (const c of chunks) for (const l of listeners) l(c);
        return {
          model: spec.model ?? params.model,
          stop_reason: spec.stop_reason ?? 'end_turn',
          usage: spec.usage ?? { input_tokens: 100, output_tokens: 50 },
          content: [{ type: 'text', text: chunks.join('') }],
        };
      },
    };
  };
  return {
    calls,
    messages: { stream: (p, o) => make('messages', p, o), create: async (p, o) => {
      calls.push({ kind: 'create', params: p, reqOpts: o });
      const r = responses[Math.min(i++, responses.length - 1)];
      const spec = typeof r === 'string' ? { text: r } : r;
      if (spec.throws) throw new Error(spec.throws);
      return { model: p.model, stop_reason: spec.stop_reason ?? 'end_turn', usage: spec.usage ?? { input_tokens: 10, output_tokens: 5 },
        content: [{ type: 'text', text: spec.text }] };
    } },
    beta: { messages: { stream: (p, o) => make('beta', p, o) } },
  };
}

/** 한 글자씩 쪼갠 조각(스트리밍 경계 시험용). */
export const chars = s => [...s];
