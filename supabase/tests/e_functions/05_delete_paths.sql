-- 계정 삭제: 사진 경로(원본·썸네일)를 모아 주고, 사용자를 지우면 관련 행이 같이 사라진다.
do $$
declare
  s uuid := gen_random_uuid(); a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); p text[]; n int;
begin
  insert into schools (id, name, email_domains) values (s, '테스트대', '{test.ac.kr}');
  insert into auth.users (id, email) values (a, a::text || '@test.ac.kr'), (b, b::text || '@test.ac.kr');
  insert into profiles (id, school_id, handle, display_name) values (a, s, 'a_' || substr(a::text, 1, 8), 'A'), (b, s, 'b_' || substr(b::text, 1, 8), 'B');
  insert into sessions (user_id, client_id, primary_category, status, photo_path, photo_thumb_path) values
    (a, gen_random_uuid(), 'study', 'ended', a::text || '/s1/full.heic', a::text || '/s1/thumb.heic'),
    (a, gen_random_uuid(), 'coding', 'ended', null, null),
    (b, gen_random_uuid(), 'study', 'ended', b::text || '/s2/full.heic', b::text || '/s2/thumb.heic');

  p := delete_account_photo_paths(a);
  assert p = array[a::text || '/s1/full.heic', a::text || '/s1/thumb.heic'], format('경로: %s', p);
  assert delete_account_photo_paths(gen_random_uuid()) = '{}', '없는 사용자는 빈 배열이어야 함';

  delete from auth.users where id = a;  -- profiles는 on delete cascade
  select count(*) into n from sessions where user_id = a;
  assert n = 0, '세션이 남아 있음';
  select count(*) into n from sessions where user_id = b;
  assert n = 1, '다른 사용자 세션이 지워짐';
end $$;

-- 크루 정리: 운영자가 나가면 가장 오래된 구성원에게 넘기고, 구성원이 없으면 지운다.
do $$
declare
  s uuid := gen_random_uuid(); o uuid := gen_random_uuid(); m1 uuid := gen_random_uuid(); m2 uuid := gen_random_uuid();
  g1 uuid := gen_random_uuid(); g2 uuid := gen_random_uuid(); r jsonb;
begin
  insert into schools (id, name, email_domains) values (s, '테스트대', '{test.ac.kr}');
  insert into auth.users (id, email) values (o, o::text || '@test.ac.kr'), (m1, m1::text || '@test.ac.kr'), (m2, m2::text || '@test.ac.kr');
  insert into profiles (id, school_id, handle, display_name) values
    (o, s, 'o_' || substr(o::text, 1, 8), 'O'), (m1, s, 'm_' || substr(m1::text, 1, 8), 'M1'), (m2, s, 'n_' || substr(m2::text, 1, 8), 'M2');
  insert into groups (id, school_id, name, owner_id, invite_code) values (g1, s, '스터디', o, 'code-' || g1::text), (g2, s, '혼자', o, 'code-' || g2::text);
  insert into group_members (group_id, user_id, role, joined_at) values
    (g1, o, 'owner', now() - interval '3 days'), (g1, m2, 'member', now() - interval '1 day'), (g1, m1, 'member', now() - interval '2 days'),
    (g2, o, 'owner', now());

  r := delete_account_cleanup_crews(o);
  assert r = '{"transferred":1,"deleted":1}'::jsonb, format('결과: %s', r);
  assert (select owner_id from groups where id = g1) = m1, '가장 오래된 구성원에게 넘어가야 함';
  assert (select role from group_members where group_id = g1 and user_id = m1) = 'owner', '새 운영자의 역할이 owner여야 함';
  assert not exists (select 1 from groups where id = g2), '구성원이 없는 크루는 지워져야 함';

  delete from auth.users where id = o;
  assert exists (select 1 from groups where id = g1), '넘긴 크루가 사용자 삭제와 함께 사라짐';
end $$;
