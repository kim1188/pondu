// POST /functions/v1/delete-account — 본체는 _shared/delete-account.mjs.
import { handleDeleteAccount } from '../_shared/delete-account.mjs';
import { errorResponse, jsonResponse } from '../_shared/errors.mjs';
import { makeDb } from '../_shared/supabase-db.mjs';
import { adminClient, requireUser } from '../_shared/serve.ts';

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  try {
    const admin = adminClient();
    const userId = await requireUser(req, admin);
    const out = await handleDeleteAccount({
      userId,
      deps: {
        db: makeDb(admin),
        storage: {
          remove: async (bucket: string, paths: string[]) => {
            const { error } = await admin.storage.from(bucket).remove(paths);
            if (error) throw error;
          },
        },
        auth: {
          deleteUser: async (id: string) => {
            const { error } = await admin.auth.admin.deleteUser(id);
            if (error) throw error;
          },
        },
      },
    });
    return jsonResponse(out);
  } catch (e) {
    return errorResponse(e);
  }
});
