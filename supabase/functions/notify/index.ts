// notify — 예약 호출(pg_cron/pg_net 또는 스케줄러). 본체는 _shared/notify.mjs.
// 로그인 토큰이 아니라 NOTIFY_SECRET 헤더로 호출자를 확인한다.
import { errorResponse, FnError, jsonResponse } from '../_shared/errors.mjs';
import { handleNotify } from '../_shared/notify.mjs';
import { makeDb } from '../_shared/supabase-db.mjs';
import { adminClient, env, num } from '../_shared/serve.ts';

const sameSecret = (a: string, b: string) => {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let d = 0;
  for (let i = 0; i < x.length; i++) d |= x[i] ^ y[i];
  return d === 0;
};

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  try {
    if (!sameSecret(req.headers.get('x-notify-secret') ?? '', env('NOTIFY_SECRET'))) throw new FnError('forbidden', 403);
    const stats = await handleNotify({
      deps: {
        db: makeDb(adminClient()), fetch, now: () => Date.now(),
        config: {
          pem: env('APNS_KEY_P8'), keyId: env('APNS_KEY_ID'), teamId: env('APNS_TEAM_ID'), bundleId: env('APNS_BUNDLE_ID'),
          production: env('APNS_ENV', 'sandbox') === 'production', batch: num('NOTIFY_BATCH', 100),
        },
      },
    });
    return jsonResponse(stats);
  } catch (e) {
    return errorResponse(e);
  }
});
