// POST /functions/v1/delete-account 의 본체. 사진을 먼저 지우고 사용자를 지운다.
// 사용자를 지우면 sessions 행이 같이 사라져 사진 경로를 잃으므로, 경로를 먼저 읽는다.
// 사진 삭제가 일부 실패하면 사용자를 지우지 않고 오류로 끝낸다(다시 부르면 이어서 지운다).
import { FnError, fromDbError } from './errors.mjs';

export const BUCKET = 'session-photos';
const CHUNK = 100;

/**
 * @param {{userId: string, deps: {db: {photoPaths: Function}, storage: {remove: Function}, auth: {deleteUser: Function}}}} p
 *   storage.remove(bucket, paths) → 실패 시 throw. auth.deleteUser(userId) → 실패 시 throw.
 */
export async function handleDeleteAccount({ userId, deps }) {
  let paths;
  try { paths = await deps.db.photoPaths(userId); } catch (e) { throw fromDbError(e); }
  // 본인 폴더 밖의 경로는 지우지 않는다(데이터 오염 방어).
  const own = [...new Set(paths)].filter(p => typeof p === 'string' && p.startsWith(`${userId}/`));
  for (let i = 0; i < own.length; i += CHUNK) {
    try { await deps.storage.remove(BUCKET, own.slice(i, i + CHUNK)); } catch { throw new FnError('assistant_unavailable', 503, 'photo delete failed'); }
  }
  try { await deps.auth.deleteUser(userId); } catch { throw new FnError('assistant_unavailable', 503, 'user delete failed'); }
  return { ok: true };
}
