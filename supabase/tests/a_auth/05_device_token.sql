-- register_device_token
\ir 00_helpers.sql
delete from auth.users where email ilike 'a\_t\_%';
insert into auth.users (id, email) values
  ('a0000000-0000-4000-8000-00000000000a', 'a_t_a@korea.ac.kr'),
  ('a0000000-0000-4000-8000-00000000000b', 'a_t_b@korea.ac.kr'),
  ('a0000000-0000-4000-8000-00000000000d', 'a_t_d@korea.ac.kr');
insert into profiles (id, school_id, handle, display_name) values
  ('a0000000-0000-4000-8000-00000000000a', '00000000-0000-4000-8000-000000000001', 'alice', '앨리스'),
  ('a0000000-0000-4000-8000-00000000000b', '00000000-0000-4000-8000-000000000001', 'bob_1', '밥');

do $$
declare
  ua uuid := 'a0000000-0000-4000-8000-00000000000a';
  ub uuid := 'a0000000-0000-4000-8000-00000000000b';
  ud uuid := 'a0000000-0000-4000-8000-00000000000d';
  r jsonb;
begin
  perform test_login(ua);
  assert public.register_device_token('tok-a1') is null, '반환은 null';
  perform public.register_device_token('tok-a1');          -- 중복 등록은 무시
  perform public.register_device_token('  tok-a2  ');      -- 공백 제거
  reset role;
  assert (select count(*) from device_tokens where user_id = ua) = 2;
  assert exists (select 1 from device_tokens where user_id = ua and token = 'tok-a2');

  -- 입력 검사
  perform test_login(ua);
  perform public.a_expect_err($q$select public.register_device_token('')$q$, 'invalid_input');
  perform public.a_expect_err($q$select public.register_device_token('   ')$q$, 'invalid_input');
  perform public.a_expect_err($q$select public.register_device_token(null)$q$, 'invalid_input');
  perform public.a_expect_err(format('select public.register_device_token(%L)', repeat('x', 513)), 'invalid_input');
  reset role;

  -- 다른 사용자: 내 토큰 행을 지우거나 바꿀 수 없다. 같은 기기를 다른 계정이 등록하면 이전 계정 행은 사라진다
  perform test_login(ub);
  perform public.register_device_token('tok-a1');
  reset role;
  assert (select count(*) from device_tokens where token = 'tok-a1') = 1, '같은 토큰이 두 계정에 남음';
  assert exists (select 1 from device_tokens where user_id = ub and token = 'tok-a1');
  assert exists (select 1 from device_tokens where user_id = ua and token = 'tok-a2'), '다른 토큰은 그대로';

  -- 프로필이 없는 사용자는 등록 불가
  perform test_login(ud);
  perform public.a_expect_err($q$select public.register_device_token('tok-d')$q$, 'profile_required');
  reset role;
  assert (select count(*) from device_tokens where user_id = ud) = 0;

  -- 직접 읽기·쓰기 불가
  perform test_login(ua);
  perform public.a_expect_denied('select * from public.device_tokens');
  perform public.a_expect_denied(format($q$delete from public.device_tokens where user_id = %L$q$, ub));
  reset role;
  -- 계정을 지우면 토큰도 같이 지워진다
  delete from auth.users where id = ua;
  assert (select count(*) from device_tokens where user_id = ua) = 0;
end $$;
