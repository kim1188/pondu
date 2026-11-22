import test from 'node:test';
import assert from 'node:assert/strict';
import { buildPush, handleNotify, makeProviderToken } from '../notify.mjs';

async function testKey() {
  const kp = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const der = new Uint8Array(await crypto.subtle.exportKey('pkcs8', kp.privateKey));
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der)).match(/.{1,64}/g).join('\n')}\n-----END PRIVATE KEY-----`;
  return { pem, publicKey: kp.publicKey };
}
const unb64 = s => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0));

test('공급자 토큰: ES256 JWT, 서명이 공개키로 검증된다', async () => {
  const { pem, publicKey } = await testKey();
  const jwt = await makeProviderToken({ pem, keyId: 'KEY1234567', teamId: 'TEAM123456', nowSec: 1700000000 });
  const [h, b, s] = jwt.split('.');
  assert.deepEqual(JSON.parse(new TextDecoder().decode(unb64(h))), { alg: 'ES256', kid: 'KEY1234567' });
  assert.deepEqual(JSON.parse(new TextDecoder().decode(unb64(b))), { iss: 'TEAM123456', iat: 1700000000 });
  assert.equal(unb64(s).length, 64);
  assert.ok(await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, publicKey, unb64(s), new TextEncoder().encode(`${h}.${b}`)));
});

test('알림 문구: 이름만 쓰고 한마디 본문·세션 제목은 싣지 않는다', () => {
  const p = buildPush({ kind: 'comment', actor_name: '가은', payload: { user_id: 'x', session_id: 's1', comment_id: 'c1', body: '비밀 한마디', share_title: '비밀 제목' } });
  assert.equal(p.aps.alert.body, '가은님이 한마디를 남겼어요');
  assert.equal(p.session_id, 's1');
  assert.equal(JSON.stringify(p).includes('비밀'), false);
  assert.equal(buildPush({ kind: 'reaction', payload: {} }).aps.alert.body, '누군가님이 응원을 보냈어요');
  assert.equal(buildPush({ kind: 'unknown_kind', payload: {} }), null);
});

async function setup(rows, responder) {
  const { pem } = await testKey();
  const log = { sent: [], marked: [], removed: [], fetches: [] };
  const deps = {
    now: () => 1700000000000,
    db: { claim: async () => rows, markSent: async ids => log.marked.push(...ids), removeTokens: async t => log.removed.push(...t) },
    fetch: async (url, init) => { log.fetches.push({ url, init }); return responder(url.split('/').pop()); },
    config: { pem, keyId: 'K', teamId: 'T', bundleId: 'kr.example.app', production: false },
  };
  return { deps, log };
}
const res = (status, reason) => ({ status, json: async () => ({ reason }) });
const row = (id, tokens, kind = 'reaction') => ({ id, user_id: 'u', kind, payload: {}, actor_name: 'B', tokens });

test('발송: 토큰마다 보내고 성공한 건에 발송 표시, 요청 모양이 APNs 규격', async () => {
  const { deps, log } = await setup([row(1, ['tokA', 'tokB'])], () => res(200));
  const stats = await handleNotify({ deps });
  assert.deepEqual(stats, { claimed: 1, sent: 1, dead_tokens: 0, retry: 0 });
  assert.deepEqual(log.marked, [1]);
  const f = log.fetches[0];
  assert.equal(f.url, 'https://api.sandbox.push.apple.com/3/device/tokA');
  assert.equal(f.init.headers['apns-topic'], 'kr.example.app');
  assert.equal(f.init.headers['apns-push-type'], 'alert');
  assert.match(f.init.headers.authorization, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  assert.equal(JSON.parse(f.init.body).aps.alert.body, 'B님이 응원을 보냈어요');
});

test('쓸 수 없는 토큰(410, BadDeviceToken)은 지우고, 그 건은 끝난 것으로 본다', async () => {
  const { deps, log } = await setup([row(1, ['dead1']), row(2, ['dead2']), row(3, ['ok'])],
    t => t === 'dead1' ? res(410, 'Unregistered') : t === 'dead2' ? res(400, 'BadDeviceToken') : res(200));
  const stats = await handleNotify({ deps });
  assert.deepEqual(log.removed.sort(), ['dead1', 'dead2']);
  assert.deepEqual(log.marked, [1, 2, 3]);
  assert.equal(stats.dead_tokens, 2);
  assert.equal(stats.sent, 1);
});

test('일시 오류(429, 5xx, 네트워크)는 토큰을 지우지 않고 발송 표시도 하지 않는다', async () => {
  const { deps, log } = await setup([row(1, ['a']), row(2, ['b']), row(3, ['c'])],
    t => { if (t === 'c') throw new Error('network'); return t === 'a' ? res(429, 'TooManyRequests') : res(503, 'ServiceUnavailable'); });
  const stats = await handleNotify({ deps });
  assert.deepEqual(log.removed, []);
  assert.deepEqual(log.marked, []);
  assert.equal(stats.retry, 3);
});

test('한 토큰이라도 성공하면 그 건은 끝, 토큰이 없거나 모르는 종류는 보내지 않고 끝', async () => {
  const { deps, log } = await setup([row(1, ['bad', 'good']), row(2, []), row(3, ['x'], 'mystery')], t => t === 'bad' ? res(410) : res(200));
  const stats = await handleNotify({ deps });
  assert.deepEqual(log.marked, [1, 2, 3]);
  assert.deepEqual(log.removed, ['bad']);
  assert.equal(log.fetches.length, 2);
  assert.equal(stats.sent, 1);
});

test('집은 것이 없으면 아무것도 보내지 않는다(키도 읽지 않는다)', async () => {
  const { deps, log } = await setup([], () => res(200));
  deps.config.pem = 'not a key';
  assert.deepEqual(await handleNotify({ deps }), { claimed: 0, sent: 0, dead_tokens: 0, retry: 0 });
  assert.equal(log.fetches.length, 0);
});

test('production 설정이면 운영 호스트로 보낸다', async () => {
  const { deps, log } = await setup([row(1, ['t'])], () => res(200));
  deps.config.production = true;
  await handleNotify({ deps });
  assert.match(log.fetches[0].url, /^https:\/\/api\.push\.apple\.com\//);
});
