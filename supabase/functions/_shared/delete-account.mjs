// POST /functions/v1/delete-account 의 본체. 사진을 먼저 지우고 사용자를 지운다.
// 순서: 운영자였던 크루 정리(넘기기·지우기) → 사진 삭제 → 사용자 삭제. 사용자를 지우면 sessions 행과 운영 중인 크루가
// 같이 사라지므로 앞의 두 일을 먼저 한다. 전부 다시 불러도 안전하다(이미 한 일은 건너뛴다).
// 사진 삭제가 일부 실패하면 사용자를 지우지 않고 오류로 끝낸다(다시 부르면 이어서 지운다).
import { FnError, fromDbError } from './errors.mjs';

export const BUCKET = 'session-photos';
const CHUNK = 100;

/**
 * @param {{userId: string, deps: {db: {photoPaths: Function, cleanupCrews: Function}, storage: {remove: Function, listAll: Function}, auth: {deleteUser: Function}}}} p
 *   storage.remove(bucket, paths) → 실패 시 throw. storage.listAll(bucket, prefix) → prefix 아래 모든 파일 경로(재귀). auth.deleteUser(userId) → 실패 시 throw.
 */
export async function handleDeleteAccount({ userId, deps }) {
  try { await deps.db.cleanupCrews(userId); } catch (e) { throw fromDbError(e); }
  let paths;
  try { paths = await deps.db.photoPaths(userId); } catch (e) { throw fromDbError(e); }
  // 기록에 없는 파일도 남기지 않도록 저장소의 본인 폴더 전체를 같이 모은다.
  let stored = [];
  try { stored = await deps.storage.listAll(BUCKET, `${userId}/`); } catch { throw new FnError('assistant_unavailable', 503, 'photo list failed'); }
  // 본인 폴더 밖의 경로는 지우지 않는다(데이터 오염 방어).
  const own = [...new Set([...paths, ...stored])].filter(p => typeof p === 'string' && p.startsWith(`${userId}/`));
  for (let i = 0; i < own.length; i += CHUNK) {
    try { await deps.storage.remove(BUCKET, own.slice(i, i + CHUNK)); } catch { throw new FnError('assistant_unavailable', 503, 'photo delete failed'); }
  }
  try { await deps.auth.deleteUser(userId); } catch { throw new FnError('assistant_unavailable', 503, 'user delete failed'); }
  return { ok: true };
}
