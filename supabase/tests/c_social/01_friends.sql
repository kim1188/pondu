-- 친구 요청 흐름과 알림 적재
do $$
declare sc uuid := c_t_school(); a uuid := c_t_user('a', sc); b uuid := c_t_user('b', sc); c uuid := c_t_user('c', sc);
  r jsonb; n int;
begin
  -- 자기 자신, 없는 사람
  perform test_login(a);
  perform c_t_err(format('select send_friend_request(%L)', a), 'invalid_input');
  perform c_t_err(format('select send_friend_request(%L)', gen_random_uuid()), 'not_found');

  -- 요청
  perform send_friend_request(b);
  perform send_friend_request(b);  -- 다시 보내도 그대로
  r := list_friend_requests();
  assert jsonb_array_length(r -> 'outgoing') = 1 and jsonb_array_length(r -> 'incoming') = 0, '보낸 요청 1';
  assert (r -> 'outgoing' -> 0 ->> 'id')::uuid = b, '보낸 요청 대상';
  assert list_friends() = '[]'::jsonb, '아직 친구 아님';

  -- 받는 쪽, 제3자
  perform test_login(b);
  r := list_friend_requests();
  assert (r -> 'incoming' -> 0 ->> 'id')::uuid = a, '받은 요청';
  assert jsonb_array_length(r -> 'outgoing') = 0;
  perform test_login(c);
  r := list_friend_requests();
  assert r = '{"incoming": [], "outgoing": []}'::jsonb, '제3자는 남의 요청이 안 보임';
  -- 제3자가 남의 요청에 응답/수락 시도, 요청한 쪽이 스스로 수락 시도
  perform c_t_err(format('select respond_friend_request(%L, true)', a), 'request_not_found');
  perform test_login(a);
  perform c_t_err(format('select respond_friend_request(%L, true)', b), 'request_not_found');

  -- 알림
  reset role;
  select count(*) into n from notification_outbox where user_id = b and kind = 'friend_request'
     and (payload ->> 'user_id')::uuid = a;
  assert n = 1, format('friend_request 알림 %s개', n);

  -- 수락
  perform test_login(b);
  perform respond_friend_request(a, true);
  assert (select count(*) from jsonb_array_elements(list_friends())) = 1, '친구 1';
  perform test_login(a);
  assert (list_friends() -> 0 ->> 'id')::uuid = b, '양쪽 친구';
  perform c_t_err(format('select send_friend_request(%L)', b), 'already_friends');
  reset role;
  select count(*) into n from notification_outbox where user_id = a and kind = 'friend_accepted';
  assert n = 1, 'friend_accepted 알림';
  -- 이미 친구인 요청에 응답
  perform test_login(b);
  perform c_t_err(format('select respond_friend_request(%L, true)', a), 'request_not_found');

  -- 삭제
  perform remove_friend(a);
  assert list_friends() = '[]'::jsonb;
  perform test_login(a);
  assert list_friends() = '[]'::jsonb, '삭제는 양쪽';

  -- 거절
  perform send_friend_request(c);
  perform test_login(c);
  perform respond_friend_request(a, false);
  assert list_friends() = '[]'::jsonb;
  assert list_friend_requests() = '{"incoming": [], "outgoing": []}'::jsonb, '거절하면 요청이 사라짐';

  -- 서로 요청하면 수락으로 본다
  perform send_friend_request(a);
  perform test_login(a);
  perform send_friend_request(c);
  assert (select count(*) from jsonb_array_elements(list_friends())) = 1, '맞요청은 친구';

  -- 보낸 요청 취소
  perform test_login(b);
  perform send_friend_request(c);
  perform remove_friend(c);
  assert list_friend_requests() = '{"incoming": [], "outgoing": []}'::jsonb, '요청 취소';
  -- 남이 보낸 요청은 제3자가 지울 수 없다
  perform send_friend_request(c);
  perform test_login(a);
  perform remove_friend(b);   -- a는 b와 아무 관계 없음. 영향 없어야 한다
  perform test_login(c);
  assert jsonb_array_length(list_friend_requests() -> 'incoming') = 1, '남의 remove_friend는 영향 없음';

  -- 로그인 없이
  reset role;
  perform set_config('request.jwt.claim.sub', '', false);
  set role authenticated;
  perform c_t_err('select list_friends()', 'not_authenticated');
  perform c_t_err(format('select send_friend_request(%L)', a), 'not_authenticated');
  reset role;
end $$;
