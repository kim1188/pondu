// notify 의 본체: notification_outbox 의 미발송 건을 APNs 로 보낸다.
// 알림 문구에는 상대 이름만 쓰고 한마디 본문·세션 제목 같은 내용은 넣지 않는다(잠금 화면에 보이므로).
// 푸시를 받을 수 없는 토큰(앱 삭제 등)은 device_tokens 에서 지운다.

const b64url = bytes => btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const utf8 = s => new TextEncoder().encode(s);

/** APNs 공급자 토큰(JWT, ES256). pem은 .p8 파일 내용. */
export async function makeProviderToken({ pem, keyId, teamId, nowSec }) {
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '')), c => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const head = b64url(utf8(JSON.stringify({ alg: 'ES256', kid: keyId })));
  const body = b64url(utf8(JSON.stringify({ iss: teamId, iat: nowSec })));
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, utf8(`${head}.${body}`)); // r||s 64바이트
  return `${head}.${body}.${b64url(sig)}`;
}

const TEXT = {
  reaction: n => `${n}님이 응원을 보냈어요`,
  comment: n => `${n}님이 한마디를 남겼어요`,
  friend_request: n => `${n}님이 친구 요청을 보냈어요`,
  friend_accepted: n => `${n}님과 친구가 됐어요`,
  joined: n => `${n}님이 같이 하기에 참여했어요`,
};

export function buildPush(row) {
  const f = TEXT[row.kind];
  if (!f) return null;
  const name = row.actor_name || '누군가';
  const data = { kind: row.kind };
  if (row.payload?.session_id) data.session_id = row.payload.session_id;
  return { aps: { alert: { title: '알림', body: f(name) }, sound: 'default' }, ...data };
}

// 토큰 자체가 쓸 수 없음을 뜻하는 응답. 이 경우에만 토큰을 지운다.
const DEAD = new Set(['BadDeviceToken', 'Unregistered', 'DeviceTokenNotForTopic']);

/** @returns {'ok'|'dead'|'retry'} */
export async function sendOne({ fetch: f, host, bundleId, jwt, token, push }) {
  let res;
  try {
    res = await f(`https://${host}/3/device/${token}`, {
      method: 'POST',
      headers: { authorization: `bearer ${jwt}`, 'apns-topic': bundleId, 'apns-push-type': 'alert', 'content-type': 'application/json' },
      body: JSON.stringify(push),
    });
  } catch { return 'retry'; }
  if (res.status === 200) return 'ok';
  let reason = '';
  try { reason = (await res.json())?.reason ?? ''; } catch { /* 본문 없음 */ }
  if (res.status === 410 || DEAD.has(reason)) return 'dead';
  return 'retry';
}

/**
 * @param {{deps: {db: {claim: Function, markSent: Function, removeTokens: Function},
 *   fetch: Function, now: () => number,
 *   config: {pem: string, keyId: string, teamId: string, bundleId: string, production: boolean, batch?: number}}}} p
 * @returns {Promise<{claimed: number, sent: number, dead_tokens: number, retry: number}>}
 */
export async function handleNotify({ deps }) {
  const { db, config } = deps;
  const rows = await db.claim(config.batch ?? 100);
  const stats = { claimed: rows.length, sent: 0, dead_tokens: 0, retry: 0 };
  if (!rows.length) return stats;
  const jwt = await makeProviderToken({ pem: config.pem, keyId: config.keyId, teamId: config.teamId, nowSec: Math.floor(deps.now() / 1000) });
  const host = config.production ? 'api.push.apple.com' : 'api.sandbox.push.apple.com';

  const done = [];
  const dead = new Set();
  for (const row of rows) {
    const push = buildPush(row);
    const tokens = row.tokens ?? [];
    if (!push || !tokens.length) { done.push(row.id); continue; } // 보낼 곳이 없으면 끝난 것으로 본다
    let anyOk = false, anyRetry = false;
    for (const token of tokens) {
      const r = await sendOne({ fetch: deps.fetch, host, bundleId: config.bundleId, jwt, token, push });
      if (r === 'ok') anyOk = true;
      else if (r === 'dead') dead.add(token);
      else anyRetry = true;
    }
    if (anyOk) stats.sent++;
    if (anyOk || !anyRetry) done.push(row.id);
    else stats.retry++; // claimed_at 이 지나면 다시 집힌다
  }
  if (done.length) await db.markSent(done);
  if (dead.size) await db.removeTokens([...dead]);
  stats.dead_tokens = dead.size;
  return stats;
}
