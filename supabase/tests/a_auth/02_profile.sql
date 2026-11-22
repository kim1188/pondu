-- M0 5.1 테스트 4~6 + 프로필 함수 전반
\ir 00_helpers.sql
delete from auth.users where email ilike 'a\_t\_%';
insert into auth.users (id, email) values
  ('a0000000-0000-4000-8000-00000000000a', 'a_t_a@korea.ac.kr'),
  ('a0000000-0000-4000-8000-00000000000b', 'A_T_B@Korea.AC.kr'),
  ('a0000000-0000-4000-8000-00000000000c', 'a_t_c@korea.ac.kr');

do $$
declare
  ua uuid := 'a0000000-0000-4000-8000-00000000000a';
  ub uuid := 'a0000000-0000-4000-8000-00000000000b';
  uc uuid := 'a0000000-0000-4000-8000-00000000000c';
  korea uuid := '00000000-0000-4000-8000-000000000001';
  dept uuid; p jsonb; h text; deps jsonb;
begin
  select id into dept from departments where school_id = korea and name = '경영학과';
  assert dept is not null, '시드 학과 없음';

  -- 프로필 전에는 null
  perform test_login(ua);
  assert public.get_my_profile() is null, '프로필 전 get_my_profile 은 null';
  assert public.is_handle_available('alice') = true;

  -- 4. 만들기, school_id 는 서버가 정한다
  p := public.upsert_my_profile('alice', '앨리스', dept);
  assert (p->>'school_id')::uuid = korea, 'school_id 가 고려대가 아님';
  assert p->>'id' = ua::text and p->>'handle' = 'alice' and p->>'display_name' = '앨리스';
  assert p->>'department_name' = '경영학과' and (p->>'department_id')::uuid = dept;
  assert (select array_agg(k order by k) from jsonb_object_keys(p) k)
       = array['avatar_path','department_id','department_name','display_name','handle','id','school_id'],
       format('Profile 키 %s', p);
  assert public.get_my_profile() = p, 'get_my_profile 불일치';
  assert public.is_handle_available('alice') = true, '내 아이디는 사용 가능으로 본다';

  -- 수정(같은 사용자, 학과 비움)
  p := public.upsert_my_profile('alice', '앨리스2', null);
  assert p->>'display_name' = '앨리스2' and p->>'department_id' is null and p->>'department_name' is null;
  -- 아이디 바꾸기
  p := public.upsert_my_profile('alice_2', '앨리스2', dept);
  assert p->>'handle' = 'alice_2';
  p := public.upsert_my_profile('alice', '앨리스2', dept);
  -- 대문자로 보내면 소문자로 저장된다
  p := public.upsert_my_profile('ALICE', '앨리스', dept);
  assert p->>'handle' = 'alice', '대문자 입력은 소문자로 저장';
  p := public.upsert_my_profile('alice', '  앨리스  ', null);
  assert p->>'display_name' = '앨리스', '이름은 앞뒤 공백 제거';
  reset role;
  assert (select count(*) from profiles where id = ua) = 1, '행이 중복됨';

  -- 5. 다른 사용자가 같은 아이디(대소문자만 달라도) 거절
  perform test_login(ub);
  assert public.is_handle_available('alice') = false;
  assert public.is_handle_available('ALICE') = false;
  assert public.is_handle_available('Alice') = false;
  perform public.a_expect_err($q$select public.upsert_my_profile('alice', 'B', null)$q$, 'handle_taken');
  perform public.a_expect_err($q$select public.upsert_my_profile('Alice', 'B', null)$q$, 'handle_taken');
  perform public.a_expect_err($q$select public.upsert_my_profile('ALICE', 'B', null)$q$, 'handle_taken');
  assert public.get_my_profile() is null, '거절된 뒤에도 프로필이 없어야 함';
  p := public.upsert_my_profile('bob_1', '밥', null);
  assert p->>'handle' = 'bob_1';
  assert public.is_handle_available('bob_2') = true;
  reset role;

  -- 6. 형식 위반
  perform test_login(uc);
  foreach h in array array['ab', '한글아이디', 'has space', repeat('a', 21), '', 'a-b', 'a.b', 'abc!', E'abc\n', ' abc'] loop
    assert public.is_handle_available(h) = false, format('is_handle_available(%L) 가 true', h);
    perform public.a_expect_err(format('select public.upsert_my_profile(%L, %L, null)', h, 'C'), 'handle_invalid');
  end loop;
  assert public.is_handle_available(null) = false;
  assert public.is_handle_available(repeat('a', 20)) = true, '20자는 허용';
  assert public.is_handle_available('abc') = true, '3자는 허용';
  perform public.a_expect_err($q$select public.upsert_my_profile(null, 'C', null)$q$, 'handle_invalid');
  -- 이름 규칙 (테스트용 클러스터가 SQL_ASCII 라 글자 수 경계는 ASCII 로 확인한다)
  perform public.a_expect_err($q$select public.upsert_my_profile('carol', '', null)$q$, 'invalid_input');
  perform public.a_expect_err($q$select public.upsert_my_profile('carol', '   ', null)$q$, 'invalid_input');
  perform public.a_expect_err($q$select public.upsert_my_profile('carol', null, null)$q$, 'invalid_input');
  perform public.a_expect_err(format('select public.upsert_my_profile(''carol'', %L, null)', repeat('x', 21)), 'invalid_input');
  p := public.upsert_my_profile('carol', repeat('x', 20), null);   -- 20자는 허용
  -- 없는 학과, 다른 학교 학과
  perform public.a_expect_err($q$select public.upsert_my_profile('carol', 'C', gen_random_uuid())$q$, 'invalid_input');
  reset role;
  insert into schools (id, name, email_domains) values ('00000000-0000-4000-8000-0000000000f1', '다른학교', array['other.ac.kr']) on conflict do nothing;
  insert into departments (id, school_id, name) values ('00000000-0000-4000-8000-0000000000f2', '00000000-0000-4000-8000-0000000000f1', '다른학과') on conflict do nothing;
  perform test_login(uc);
  perform public.a_expect_err($q$select public.upsert_my_profile('carol', 'C', '00000000-0000-4000-8000-0000000000f2')$q$, 'invalid_input');

  -- list_departments: 본인 학교 것만, 이름순
  deps := public.list_departments();
  assert jsonb_typeof(deps) = 'array' and jsonb_array_length(deps) >= 20, '학과 목록이 비었음';
  assert not exists (select 1 from jsonb_array_elements(deps) d where d->>'name' = '다른학과'), '다른 학교 학과가 보임';
  assert (select array_agg(d->>'name') from jsonb_array_elements(deps) d) = (select array_agg(d->>'name' order by d->>'name') from jsonb_array_elements(deps) d), '학과는 이름순';
  assert (select array_agg(k order by k) from jsonb_object_keys(deps->0) k) = array['id','name'];
  reset role;
end $$;

-- uid 가 없는 요청은 모든 함수에서 not_authenticated (실행 권한은 있는 역할로)
do $t$
declare f text;
begin
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('request.jwt.claim.role', 'authenticated', false);
  set role authenticated;
  foreach f in array array[
    'select public.get_my_profile()', 'select public.is_handle_available(''abc'')',
    'select public.upsert_my_profile(''abc'',''x'',null)', 'select public.list_departments()',
    'select public.search_profiles(''a'', 10)', 'select public.register_device_token(''t'')'
  ] loop
    perform public.a_expect_err(f, 'not_authenticated');
  end loop;
  reset role;
end $t$;
-- 메일 도메인 없는 사용자(예: 훅 우회로 만들어진 행)는 프로필을 만들 수 없다
do $$
declare ux uuid := 'a0000000-0000-4000-8000-0000000000e1';
begin
  alter table auth.users disable trigger user;  -- 시험용으로만 트리거 해제
  insert into auth.users (id, email) values (ux, 'a_t_x@evil.com');
  alter table auth.users enable trigger user;
  perform test_login(ux);
  perform public.a_expect_err($q$select public.upsert_my_profile('evil', 'E', null)$q$, 'email_domain_not_allowed');
  reset role;
  delete from auth.users where id = ux;
end $$;
