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
