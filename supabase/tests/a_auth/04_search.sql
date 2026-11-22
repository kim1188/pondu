-- search_profiles: 같은 학교, 아이디 앞부분/이름 일치, 본인·차단(양방향) 제외, 다른 학교 제외
\ir 00_helpers.sql
delete from auth.users where email ilike 'a\_t\_%';
insert into schools (id, name, email_domains) values ('00000000-0000-4000-8000-0000000000f1', '다른학교', array['other.ac.kr']) on conflict do nothing;
insert into auth.users (id, email)
select ('a0000000-0000-4000-8000-0000000001' || lpad(i::text, 2, '0'))::uuid, 'a_t_s' || i || '@korea.ac.kr' from generate_series(1, 8) i;
-- 다른 학교 사용자는 트리거를 잠시 끄고 만든다(시험용)
alter table auth.users disable trigger user;
insert into auth.users (id, email) values ('a0000000-0000-4000-8000-000000000199', 'a_t_other@other.ac.kr');
alter table auth.users enable trigger user;

insert into profiles (id, school_id, handle, display_name) values
  ('a0000000-0000-4000-8000-000000000101', '00000000-0000-4000-8000-000000000001', 'kim_me',     '김나'),
  ('a0000000-0000-4000-8000-000000000102', '00000000-0000-4000-8000-000000000001', 'kim_friend', '김친구'),
  ('a0000000-0000-4000-8000-000000000103', '00000000-0000-4000-8000-000000000001', 'kim_blocked','김차단'),
  ('a0000000-0000-4000-8000-000000000104', '00000000-0000-4000-8000-000000000001', 'kim_blocker','김차단자'),
  ('a0000000-0000-4000-8000-000000000105', '00000000-0000-4000-8000-000000000001', 'lee_x',      '이름만김'),
  ('a0000000-0000-4000-8000-000000000106', '00000000-0000-4000-8000-000000000001', 'park_x',     '박'),
  ('a0000000-0000-4000-8000-000000000107', '00000000-0000-4000-8000-000000000001', 'a_b',        '밑줄'),
  ('a0000000-0000-4000-8000-000000000108', '00000000-0000-4000-8000-000000000001', 'axb',        '엑스'),
  ('a0000000-0000-4000-8000-000000000199', '00000000-0000-4000-8000-0000000000f1', 'kim_other',  '김다른학교');
-- 103 은 내가(101) 차단, 104 는 나를 차단
insert into blocks (blocker_id, blocked_id) values
  ('a0000000-0000-4000-8000-000000000101', 'a0000000-0000-4000-8000-000000000103'),
  ('a0000000-0000-4000-8000-000000000104', 'a0000000-0000-4000-8000-000000000101');

do $$
declare
  me uuid := 'a0000000-0000-4000-8000-000000000101';
  r jsonb; hs text[]; i int;
begin
  perform test_login(me);

  r := public.search_profiles('kim', 20);
  hs := (select array_agg(x->>'handle' order by x->>'handle') from jsonb_array_elements(r) x);
  assert hs = array['kim_friend'], format('kim 검색: %s', hs);   -- 본인, 차단 양방향, 다른 학교 제외

  -- 이름 일치(이름 앞부분), 대소문자 무시, 앞뒤 공백 무시
  hs := (select array_agg(x->>'handle') from jsonb_array_elements(public.search_profiles('이름만', 20)) x);
  assert hs = array['lee_x'], format('이름 검색: %s', hs);
  hs := (select array_agg(x->>'handle') from jsonb_array_elements(public.search_profiles('  PARK_X  ', 20)) x);
  assert hs = array['park_x'], format('대소문자/공백: %s', hs);
  -- 아이디 "앞부분"만: 중간 일치는 안 나온다
  assert jsonb_array_length(public.search_profiles('friend', 20)) = 0, '중간 일치가 나옴';
  -- 이름이 같은 다른 학교 사람은 안 나온다
  assert jsonb_array_length(public.search_profiles('kim_other', 20)) = 0, '다른 학교 사용자가 나옴';
  assert jsonb_array_length(public.search_profiles('김다른', 20)) = 0, '다른 학교 사용자가 이름으로 나옴';
  -- 차단 상대는 정확한 아이디로도 안 나온다
  assert jsonb_array_length(public.search_profiles('kim_blocked', 20)) = 0, '내가 차단한 사용자가 나옴';
  assert jsonb_array_length(public.search_profiles('kim_blocker', 20)) = 0, '나를 차단한 사용자가 나옴';
  assert jsonb_array_length(public.search_profiles('김차단', 20)) = 0, '차단 사용자가 이름으로 나옴';
  -- 본인은 안 나온다
  assert jsonb_array_length(public.search_profiles('kim_me', 20)) = 0, '본인이 나옴';
  -- LIKE 특수문자는 글자 그대로: '_' 가 한 글자 와일드카드가 아니다, '%' 는 전체 일치가 아니다
  hs := (select array_agg(x->>'handle') from jsonb_array_elements(public.search_profiles('a_', 20)) x);
  assert hs = array['a_b'], format('a_ 검색: %s', hs);
  assert jsonb_array_length(public.search_profiles('%', 20)) = 0, '% 가 와일드카드로 동작';
  assert not exists (select 1 from jsonb_array_elements(public.search_profiles('_', 20)) x where x->>'handle' not like '\_%'), '_ 가 한 글자 와일드카드로 동작';
  -- 빈 검색어, null 은 빈 배열
  assert public.search_profiles('', 20) = '[]'::jsonb and public.search_profiles('   ', 20) = '[]'::jsonb and public.search_profiles(null, 20) = '[]'::jsonb;
  -- 결과 모양은 ProfileCard
  r := public.search_profiles('kim_f', 5);
  assert (select array_agg(k order by k) from jsonb_object_keys(r->0) k)
       = array['avatar_path','department_name','display_name','handle','id'];
  -- p_limit: 1~50 으로 보정, null 은 기본값
  reset role;
  insert into auth.users (id, email) select ('a0000000-0000-4000-8000-0000000002' || lpad(i::text, 2, '0'))::uuid, 'a_t_m' || i || '@korea.ac.kr' from generate_series(1, 60) i;
  insert into profiles (id, school_id, handle, display_name)
    select ('a0000000-0000-4000-8000-0000000002' || lpad(i::text, 2, '0'))::uuid, '00000000-0000-4000-8000-000000000001', 'many_' || lpad(i::text, 2, '0'), '다수' || i from generate_series(1, 60) i;
  perform test_login(me);
  assert jsonb_array_length(public.search_profiles('many_', 3)) = 3;
  assert jsonb_array_length(public.search_profiles('many_', 0)) = 1, 'limit 0 은 1로 보정';
  assert jsonb_array_length(public.search_profiles('many_', -5)) = 1;
  assert jsonb_array_length(public.search_profiles('many_', 500)) = 50, 'limit 500 은 50으로 보정';
  assert jsonb_array_length(public.search_profiles('many_', null)) = 20, 'limit null 은 20';
  assert public.search_profiles('many_', 2)->0->>'handle' = 'many_01', '아이디순';
  reset role;

  -- 차단을 풀면 다시 나온다(차단 상태를 매번 직접 읽는다)
  delete from blocks where blocked_id = me;
  perform test_login(me);
  assert jsonb_array_length(public.search_profiles('kim_blocker', 20)) = 1, '차단 해제 후에도 안 나옴';
  reset role;

  -- 다른 학교 사용자 시점: 고려대 사람이 안 보이고 자기 학교만 보인다
  perform test_login('a0000000-0000-4000-8000-000000000199');
  assert public.search_profiles('kim', 20) = '[]'::jsonb, '다른 학교 사용자에게 고려대 사람이 보임';
  reset role;
end $$;
