import test from 'node:test';
import assert from 'node:assert/strict';
import { BUCKET, handleDeleteAccount } from '../delete-account.mjs';

const U = '11111111-1111-1111-1111-111111111111';
function setup({ paths = [], removeFails = false, deleteFails = false } = {}) {
  const order = [];
  return {
    order,
    deps: {
      db: { photoPaths: async () => { order.push('paths'); return paths; } },
      storage: { remove: async (bucket, p) => { order.push(['remove', bucket, p]); if (removeFails) throw new Error('x'); } },
      auth: { deleteUser: async id => { order.push(['deleteUser', id]); if (deleteFails) throw new Error('x'); } },
    },
  };
}

test('사진을 먼저 지우고 그다음 사용자를 지운다', async () => {
  const { deps, order } = setup({ paths: [`${U}/s1/full.heic`, `${U}/s1/thumb.heic`, `${U}/s1/full.heic`] });
  assert.deepEqual(await handleDeleteAccount({ userId: U, deps }), { ok: true });
  assert.deepEqual(order, ['paths', ['remove', BUCKET, [`${U}/s1/full.heic`, `${U}/s1/thumb.heic`]], ['deleteUser', U]]);
});

test('본인 폴더 밖 경로는 지우지 않는다', async () => {
  const { deps, order } = setup({ paths: [`${U}/a/full.heic`, '22222222-2222-2222-2222-222222222222/b/full.heic', '../x'] });
  await handleDeleteAccount({ userId: U, deps });
  assert.deepEqual(order[1][2], [`${U}/a/full.heic`]);
});

test('사진이 없으면 저장소를 부르지 않고 사용자만 지운다', async () => {
  const { deps, order } = setup();
  await handleDeleteAccount({ userId: U, deps });
  assert.deepEqual(order, ['paths', ['deleteUser', U]]);
});

test('사진 삭제가 실패하면 사용자를 지우지 않는다(다시 부르면 이어서 지운다)', async () => {
  const { deps, order } = setup({ paths: [`${U}/s/full.heic`], removeFails: true });
  await assert.rejects(handleDeleteAccount({ userId: U, deps }), e => e.code === 'assistant_unavailable');
  assert.ok(!order.some(o => o[0] === 'deleteUser'));
});

test('사용자 삭제가 실패하면 오류', async () => {
  const { deps } = setup({ deleteFails: true });
  await assert.rejects(handleDeleteAccount({ userId: U, deps }), e => e.code === 'assistant_unavailable');
});

test('100개 넘는 사진은 나눠서 지운다', async () => {
  const paths = Array.from({ length: 250 }, (_, i) => `${U}/s${i}/full.heic`);
  const { deps, order } = setup({ paths });
  await handleDeleteAccount({ userId: U, deps });
  assert.deepEqual(order.filter(o => o[0] === 'remove').map(o => o[2].length), [100, 100, 50]);
});
