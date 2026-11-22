-- 반응, 한마디, 알림 적재, 남의 한마디 삭제 거절
do $$
declare sc uuid := c_t_school(); own uuid := c_t_user('own', sc); fr uuid := c_t_user('fr', sc); st uuid := c_t_user('st', sc);
  pub uuid; prv uuid; c1 jsonb; c2 jsonb; n int; r jsonb;
begin
  perform c_t_friends(own, fr);
  pub := c_t_session(own, 'friends'); prv := c_t_session(own, 'private', 'ended', now() - interval '3 hours');

  -- 반응
  perform test_login(fr);
  perform c_t_err(format('select set_reaction(%L, %L)', pub, 'love'), 'invalid_input');
  perform set_reaction(pub, 'cheer');
  perform set_reaction(pub, 'cheer');          -- 같은 반응을 다시: 알림은 한 번만
  perform set_reaction(pub, 'fire');           -- 바꾸면 한 번 더
  reset role;
  assert (select count(*) from reactions where session_id = pub) = 1, '사용자당 반응 하나';
  assert (select kind from reactions where session_id = pub and user_id = fr) = 'fire';
  select count(*) into n from notification_outbox where user_id = own and kind = 'reaction' and (payload ->> 'session_id')::uuid = pub;
  assert n = 2, format('reaction 알림 %s건', n);
  -- 남(볼 수 없는 사람)은 반응도 못 함. 존재 자체를 알리지 않는다
  perform test_login(st);
  perform c_t_err(format('select set_reaction(%L, %L)', pub, 'fire'), 'not_found');
  perform c_t_err(format('select set_reaction(%L, %L)', prv, 'fire'), 'not_found');
  perform c_t_err(format('select set_reaction(%L, %L)', gen_random_uuid(), 'fire'), 'not_found');
  -- 친구도 비공개엔 못 함
  perform test_login(fr);
  perform c_t_err(format('select set_reaction(%L, %L)', prv, 'fire'), 'not_found');
  -- 남이 내 반응을 지울 수는 없다(취소는 자기 것만)
  perform test_login(st);
  perform c_t_err(format('select set_reaction(%L, null)', pub), 'not_found');
  reset role;
  assert (select count(*) from reactions where session_id = pub) = 1, '남의 취소 시도는 영향 없음';
  perform test_login(fr);
  perform set_reaction(pub, null);
  reset role;
  assert (select count(*) from reactions where session_id = pub) = 0, '자기 반응 취소';

  -- 한마디
  perform test_login(fr);
  perform c_t_err(format('select add_comment(%L, %L)', pub, ''), 'invalid_input');
  perform c_t_err(format('select add_comment(%L, %L)', pub, '   '), 'invalid_input');
  perform c_t_err(format('select add_comment(%L, %L)', pub, repeat('가', 201)), 'invalid_input');
  c1 := add_comment(pub, ' 좋아요 ');
  assert c1 ->> 'body' = '좋아요' and c1 -> 'author' ->> 'id' = fr::text and (c1 ->> 'created_at') ~ 'Z$', '한마디 모양';
  perform c_t_err(format('select add_comment(%L, %L)', prv, 'x'), 'not_found');
  reset role;
  select count(*) into n from notification_outbox where user_id = own and kind = 'comment' and (payload ->> 'comment_id')::uuid = (c1 ->> 'id')::uuid;
  assert n = 1, 'comment 알림';
  -- 주인이 자기 세션에 단 한마디는 알림 없음
  perform test_login(own);
  c2 := add_comment(pub, '고마워');
  reset role;
  select count(*) into n from notification_outbox where user_id = own and kind = 'comment';
  assert n = 1, '자기 세션 한마디는 알림 없음';
  select count(*) into n from notification_outbox where user_id = fr and kind in ('comment', 'reaction');
  assert n = 0, '남에게 알림이 새지 않음';

  -- 목록: 볼 수 있는 사람만, 오래된 순
  perform test_login(fr);
  r := list_comments(pub);
  assert jsonb_array_length(r) = 2 and r -> 0 ->> 'body' = '좋아요', '한마디 목록';
  perform test_login(st);
  perform c_t_err(format('select list_comments(%L)', pub), 'not_found');
  perform c_t_err(format('select add_comment(%L, %L)', pub, '침입'), 'not_found');

  -- 삭제: 남의 한마디는 못 지운다(작성자 본인만)
  perform c_t_err(format('select delete_comment(%L)', c1 ->> 'id'), 'not_found');   -- 볼 수 없는 세션이면 존재를 모른다
  perform test_login(fr);
  perform c_t_err(format('select delete_comment(%L)', c2 ->> 'id'), 'forbidden');   -- 볼 수 있어도 남의 것
  perform c_t_err(format('select delete_comment(%L)', gen_random_uuid()), 'not_found');
  reset role;
  assert (select count(*) from comments where session_id = pub) = 2, '남의 한마디 삭제 시도는 영향 없음';
  perform test_login(own);
  perform c_t_err(format('select delete_comment(%L)', c1 ->> 'id'), 'forbidden');   -- 세션 주인도 남의 한마디는 못 지움(차단으로 해결)
  perform delete_comment((c2 ->> 'id')::uuid);
  perform test_login(fr);
  perform delete_comment((c1 ->> 'id')::uuid);
  assert list_comments(pub) = '[]'::jsonb, '자기 한마디 삭제';

  -- 친구가 아니게 되면 이후엔 못 달고 못 본다(이전 한마디는 남는다)
  perform add_comment(pub, '또');
  perform test_login(own);
  perform remove_friend(fr);
  perform test_login(fr);
  perform c_t_err(format('select add_comment(%L, %L)', pub, '못 달아'), 'not_found');
  perform c_t_err(format('select list_comments(%L)', pub), 'not_found');
  reset role;
  assert (select count(*) from comments where session_id = pub) = 1;
end $$;
