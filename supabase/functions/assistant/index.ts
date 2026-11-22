// POST /functions/v1/assistant — 이벤트 스트림(SSE). 본체는 _shared/assistant.mjs.
import Anthropic from 'npm:@anthropic-ai/sdk@^1.12.0';
import { handleAssistant } from '../_shared/assistant.mjs';
import { errorResponse, sse } from '../_shared/errors.mjs';
import { makeDb } from '../_shared/supabase-db.mjs';
import { adminClient, env, num, requireUser } from '../_shared/serve.ts';

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  try {
    const admin = adminClient();
    const userId = await requireUser(req, admin);
    let body: unknown;
    try { body = await req.json(); } catch { body = null; }
    // 제한 시간은 우리가 직접 걸므로 SDK의 재시도는 끈다.
    const client = new Anthropic({ apiKey: env('ANTHROPIC_API_KEY'), maxRetries: 0 });
    const deps = {
      db: makeDb(admin), client, now: () => Date.now(),
      config: {
        model: Deno.env.get('ASSISTANT_MODEL') || undefined,
        dailyLimit: num('ASSISTANT_DAILY_LIMIT', 30),
        timeoutMs: num('ASSISTANT_TIMEOUT_MS', 20000),
        effort: Deno.env.get('ASSISTANT_EFFORT') || undefined,
      },
    };
    const enc = new TextEncoder();
    const stream = new ReadableStream({
      async start(controller) {
        const emit = (event: string, data: unknown) => controller.enqueue(enc.encode(sse(event, data)));
        try { await handleAssistant({ body, userId, deps, emit }); } finally { controller.close(); }
      },
    });
    return new Response(stream, { headers: { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' } });
  } catch (e) {
    return errorResponse(e);
  }
});
