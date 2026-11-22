// Deno 진입점들이 같이 쓰는 얇은 바깥 껍데기: 관리자 클라이언트, 로그인 확인, 환경 변수.
// 로직은 두지 않는다. (이 파일은 Deno 에서만 실행된다.)
import { createClient } from 'npm:@supabase/supabase-js@2';
import { FnError } from './errors.mjs';

export const env = (k: string, d?: string): string => {
  const v = Deno.env.get(k) ?? d;
  if (v === undefined) throw new FnError('assistant_unavailable', 503, `missing env ${k}`);
  return v;
};

export const adminClient = () =>
  createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } });

/** Authorization: Bearer <로그인 토큰> 을 확인해 사용자 id 를 돌려준다. */
export async function requireUser(req: Request, admin: ReturnType<typeof adminClient>): Promise<string> {
  const m = /^Bearer (.+)$/i.exec(req.headers.get('authorization') ?? '');
  if (!m) throw new FnError('not_authenticated', 401);
  const { data, error } = await admin.auth.getUser(m[1]);
  if (error || !data?.user) throw new FnError('not_authenticated', 401);
  return data.user.id;
}

export const num = (k: string, d: number): number => {
  const n = Number(Deno.env.get(k));
  return Number.isFinite(n) && n > 0 ? n : d;
};
