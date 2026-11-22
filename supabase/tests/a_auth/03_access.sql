-- M0 5.1 테스트 7~9: 테이블 직접 접근 차단, 비로그인 차단, 다른 사용자가 보는 필드
\ir 00_helpers.sql
delete from auth.users where email ilike 'a\_t\_%';
insert into auth.users (id, email) values
  ('a0000000-0000-4000-8000-00000000000a', 'a_t_a@korea.ac.kr'),
  ('a0000000-0000-4000-8000-00000000000b', 'a_t_b@korea.ac.kr'),
  ('a0000000-0000-4000-8000-00000000000d', 'a_t_d@korea.ac.kr');
-- 관리자 권한으로 프로필 행을 직접 넣는다
insert into profiles (id, school_id, handle, display_name, department_id) values
  ('a0000000-0000-4000-8000-00000000000a', '00000000-0000-4000-8000-000000000001', 'alice', '앨리스',
   (select id from departments where name = '경영학과')),
  ('a0000000-0000-4000-8000-00000000000b', '00000000-0000-4000-8000-000000000001', 'bob_1', '밥', null);

do $$
declare
  ua uuid := 'a0000000-0000-4000-8000-00000000000a';
  ub uuid := 'a0000000-0000-4000-8000-00000000000b';
  ud uuid := 'a0000000-0000-4000-8000-00000000000d';
  t text; p jsonb; c jsonb; n int;
begin
  -- 7. B 는 profiles 에 직접 insert/update/delete 불가 (A 의 행도, 자기 행도)
  perform test_login(ub);
  perform public.a_expect_denied(format($q$insert into public.profiles (id, school_id, handle, display_name) values (%L, '00000000-0000-4000-8000-000000000001', 'hack', 'x')$q$, gen_random_uuid()));
  perform public.a_expect_denied(format($q$insert into public.profiles (id, school_id, handle, display_name) values (%L, '00000000-0000-4000-8000-000000000001', 'hack2', 'x')$q$, ud));
  perform public.a_expect_denied(format($q$update public.profiles set display_name = 'hacked' where id = %L$q$, ua));
  perform public.a_expect_denied(format($q$update public.profiles set display_name = 'mine' where id = %L$q$, ub));
  perform public.a_expect_denied(format($q$update public.profiles set school_id = school_id where id = %L$q$, ub));
  perform public.a_expect_denied(format($q$delete from public.profiles where id = %L$q$, ua));
  perform public.a_expect_denied(format($q$delete from public.profiles where id = %L$q$, ub));
  -- 같은 이유로 schools, departments, device_tokens 도 쓰기 불가
  perform public.a_expect_denied($q$insert into public.schools (name, email_domains) values ('가짜대', array['evil.com'])$q$);
  perform public.a_expect_denied($q$update public.schools set email_domains = array['evil.com']$q$);
  perform public.a_expect_denied($q$delete from public.schools$q$);
  perform public.a_expect_denied($q$insert into public.departments (school_id, name) values ('00000000-0000-4000-8000-000000000001', '가짜과')$q$);
  perform public.a_expect_denied($q$delete from public.departments$q$);
  perform public.a_expect_denied(format($q$insert into public.device_tokens (user_id, token) values (%L, 'x')$q$, ub));
  -- 9. 직접 읽기는 열 하나도 허용되지 않는다(필드 노출은 함수로만)
  foreach t in array array['handle','display_name','department_id','avatar_path','id','school_id','created_at','updated_at'] loop
    perform public.a_expect_denied(format('select %I from public.profiles', t));
  end loop;
  perform public.a_expect_denied('select * from public.profiles');
  perform public.a_expect_denied('select * from public.schools');
  perform public.a_expect_denied('select * from public.departments');
  perform public.a_expect_denied('select * from public.device_tokens');
  perform public.a_expect_denied('select email from auth.users');
  reset role;

  -- 쓰기가 실제로 아무것도 바꾸지 않았다
  assert (select display_name from profiles where id = ua) = '앨리스';
  assert (select count(*) from profiles) = 2 and (select count(*) from schools where name = '가짜대') = 0;

  -- 9. B 가 A 의 프로필을 볼 수 있는 경로는 search_profiles 뿐이고, 허용된 필드만 나온다
  perform test_login(ub);
  c := public.search_profiles('alice', 10);
  assert jsonb_array_length(c) = 1, format('검색 결과 %s', c);
  assert (select array_agg(k order by k) from jsonb_object_keys(c->0) k)
       = array['avatar_path','department_name','display_name','handle','id'], format('노출 필드 %s', c->0);
  assert c->0->>'handle' = 'alice' and c->0->>'department_name' = '경영학과';
  assert not (c->0 ? 'school_id') and not (c->0 ? 'department_id') and not (c->0 ? 'email');
  -- 프로필 없는 사용자 D 는 남의 프로필을 읽지 못한다(get_my_profile 은 본인 것만)
  reset role;
  perform test_login(ud);
  assert public.get_my_profile() is null;
  perform public.a_expect_err($q$select public.search_profiles('alice', 10)$q$, 'profile_required');
  reset role;
  -- get_my_profile 은 로그인한 본인 것만 돌려준다
  perform test_login(ub);
  p := public.get_my_profile();
  assert p->>'id' = ub::text and p->>'handle' = 'bob_1';
  reset role;

  -- 8. 로그인하지 않은 요청은 읽을 수 없다(테이블도, 함수도)
  perform test_anon();
  perform public.a_expect_denied('select * from public.profiles');
  perform public.a_expect_denied('select * from public.departments');
  perform public.a_expect_denied('select * from public.schools');
  perform public.a_expect_denied('select public.get_my_profile()');
  perform public.a_expect_denied('select public.list_departments()');
  perform public.a_expect_denied($q$select public.search_profiles('a', 5)$q$);
  perform public.a_expect_denied($q$select public.is_handle_available('abc')$q$);
  perform public.a_expect_denied($q$select public.upsert_my_profile('abc','x',null)$q$);
  perform public.a_expect_denied($q$select public.register_device_token('t')$q$);
  reset role;

  -- 내부 함수 profile_card 는 앱이 직접 부를 수 없다
  perform test_login(ub);
  perform public.a_expect_denied(format($q$select public.profile_card(%L)$q$, ua));
  reset role;
  -- 관리자(다른 흐름의 security definer 함수가 쓰는 경로)는 부를 수 있다
  c := public.profile_card(ua);
  assert (select array_agg(k order by k) from jsonb_object_keys(c) k)
       = array['avatar_path','department_name','display_name','handle','id'], format('ProfileCard %s', c);
  assert c->>'department_name' = '경영학과';
  assert public.profile_card(ub)->>'department_name' is null and public.profile_card(ub) ? 'department_name';
  assert public.profile_card(gen_random_uuid()) is null, '없는 사용자는 null';
  assert public.profile_card(null) is null;
end $$;
