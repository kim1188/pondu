// POST /functions/v1/import-extract — 본체는 _shared/import-extract.mjs.
import Anthropic from 'npm:@anthropic-ai/sdk@^1.12.0';
import { errorResponse, jsonResponse } from '../_shared/errors.mjs';
import { handleImportExtract } from '../_shared/import-extract.mjs';
import { makeDb } from '../_shared/supabase-db.mjs';
import { adminClient, env, num, requireUser } from '../_shared/serve.ts';

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  try {
    const admin = adminClient();
    const userId = await requireUser(req, admin);
    let body: unknown;
    try { body = await req.json(); } catch { body = null; }
    const client = new Anthropic({ apiKey: env('ANTHROPIC_API_KEY'), maxRetries: 0 });
    const out = await handleImportExtract({
      body, userId,
      deps: {
        db: makeDb(admin), client, now: () => Date.now(),
        config: { model: Deno.env.get('ASSISTANT_MODEL') || undefined, dailyLimit: num('IMPORT_DAILY_LIMIT', 30), timeoutMs: num('ASSISTANT_TIMEOUT_MS', 20000) },
      },
    });
    return jsonResponse(out);
  } catch (e) {
    return errorResponse(e);
  }
});
