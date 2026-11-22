// Supabase(관리자 키)로 05 마이그레이션의 내부 함수를 부르는 얇은 어댑터. 로직은 없고 이름과 인자만 맞춘다.
// supabase-js 클라이언트(admin)를 받는다. 전부 service_role 전용 함수다.

async function call(admin, fn, args) {
  const { data, error } = await admin.rpc(fn, args);
  if (error) throw Object.assign(new Error(error.message), { code: error.code });
  return data;
}

export const makeDb = admin => ({
  runBegin: (userId, kind, limit) => call(admin, 'assistant_run_begin', { p_user: userId, p_kind: kind, p_daily_limit: limit }),
  runFinish: (runId, r) => call(admin, 'assistant_run_finish', {
    p_run: runId, p_model: r.model, p_input_tokens: r.input_tokens, p_output_tokens: r.output_tokens, p_latency_ms: r.latency_ms, p_ok: r.ok,
  }),
  context: (userId, now) => call(admin, 'assistant_context', { p_user: userId, p_now: now }),
  threadCategories: userId => call(admin, 'assistant_thread_categories', { p_user: userId }),
  saveProposal: (userId, kind, input, proposal) => call(admin, 'assistant_proposal_save', { p_user: userId, p_kind: kind, p_input: input, p_proposal: proposal }),
  photoPaths: userId => call(admin, 'delete_account_photo_paths', { p_user: userId }),
  claim: limit => call(admin, 'notification_outbox_claim', { p_limit: limit }),
  markSent: ids => call(admin, 'notification_outbox_mark_sent', { p_ids: ids }),
  removeTokens: tokens => call(admin, 'device_tokens_remove', { p_tokens: tokens }),
});
