import test from 'node:test';
import assert from 'node:assert/strict';
import { FnError, errorResponse, fromDbError, sseErrorResponse } from '../errors.mjs';

test('스트림이 아닌 함수의 실패: 상태 코드와 {code} 본문', async () => {
  const r = errorResponse(new FnError('quota_exceeded', 429));
  assert.equal(r.status, 429);
  assert.deepEqual(await r.json(), { code: 'quota_exceeded' });
  assert.equal(errorResponse(new Error('x')).status, 500);
});

test('assistant의 시작 전 오류(인증 등)는 HTTP 200 이벤트 스트림의 error 이벤트', async () => {
  const r = sseErrorResponse('not_authenticated');
  assert.equal(r.status, 200);
  assert.match(r.headers.get('content-type'), /text\/event-stream/);
  assert.equal(await r.text(), 'event: error\ndata: {"code":"not_authenticated"}\n\n');
});

test('DB가 낸 계약 코드는 그대로, 그 밖은 assistant_unavailable', () => {
  assert.equal(fromDbError(new Error('quota_exceeded')).code, 'quota_exceeded');
  assert.equal(fromDbError(new Error('connection reset by peer')).code, 'assistant_unavailable');
});
