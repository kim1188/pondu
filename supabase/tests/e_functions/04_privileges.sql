-- 앱(authenticated, anon)은 내부 함수를 부를 수 없고, service_role은 부를 수 있다.
do $$
declare
  u uuid := gen_random_uuid(); f text; n int;
begin
  foreach f in array array[
    'assistant_run_begin(uuid,text,int)', 'assistant_run_finish(uuid,text,int,int,int,boolean)',
    'assistant_thread_categories(uuid)', 'assistant_proposal_save(uuid,text,jsonb,jsonb)',
    'delete_account_photo_paths(uuid)', 'notification_outbox_claim(int)',
    'notification_outbox_mark_sent(bigint[])', 'device_tokens_remove(text[])'
  ] loop
    assert not has_function_privilege('authenticated', f, 'execute'), format('authenticated가 %s 를 실행할 수 있음', f);
    assert not has_function_privilege('anon', f, 'execute'), format('anon이 %s 를 실행할 수 있음', f);
    assert has_function_privilege('service_role', f, 'execute'), format('service_role이 %s 를 실행할 수 없음', f);
  end loop;

  perform test_login(u);
  begin
    perform assistant_run_begin(u, 'capture', 5);
    raise exception '로그인한 사용자가 내부 함수를 호출함';
  exception when insufficient_privilege then null; end;
  reset role;
end $$;
