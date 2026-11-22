-- 크루를 골라서 공개하기: 세션이 크루 하나에 묶이고, 그 크루의 구성원에게만 crew 공개로 보인다.
do $$
declare sc uuid := c_t_school();
  u uuid := c_t_user('u', sc);       -- 크루 둘(g1, g2)에 속함
  m1 uuid := c_t_user('m1', sc);     -- g1만
  m2 uuid := c_t_user('m2', sc);     -- g2만
  fr uuid := c_t_user('fr', sc);     -- u의 친구(크루 없음)
  o uuid := c_t_user('o', sc);       -- 남의 크루 g3 운영자
  g1 uuid; g2 uuid; g3 uuid; s1 uuid; s2 uuid; s_fr uuid; sess jsonb; card jsonb; page jsonb; th jsonb;
begin
  perform c_t_friends(u, fr);
  perform test_login(u);  g1 := (create_crew('크루1') ->> 'id')::uuid;  g2 := (create_crew('크루2') ->> 'id')::uuid;
  perform test_login(o);  g3 := (create_crew('남의크루') ->> 'id')::uuid;
  reset role;
  insert into group_members (group_id, user_id) values (g1, m1), (g2, m2);

  -- 크루 둘에 속한 u가 g1을 골라 시작: group_id가 g1
  perform test_login(u);
  sess := start_session(gen_random_uuid(), 'study', 'no_photo', 'crew', null, null, null, null, '공부', null, null, g1);
  s1 := (sess ->> 'id')::uuid;
  assert (sess ->> 'group_id')::uuid = g1, 'Session.group_id';
  perform end_session(s1, 'done', null);
  -- 구성원이 아닌 크루(g3), 없는 크루로는 시작할 수 없다
  perform c_t_err(format('select start_session(%L, ''study'', ''no_photo'', ''crew'', null, null, null, null, null, null, null, %L)', gen_random_uuid(), g3), 'not_found');
  perform c_t_err(format('select start_session(%L, ''study'', ''no_photo'', ''crew'', null, null, null, null, null, null, null, %L)', gen_random_uuid(), gen_random_uuid()), 'not_found');
  -- 크루가 둘인데 고르지 않으면 invalid_input
  perform c_t_err(format('select start_session(%L, ''study'', ''no_photo'', ''crew'')', gen_random_uuid()), 'invalid_input');
  -- 크루가 아닌 공개 범위에서는 group_id를 null로(크루를 줘도)
  sess := start_session(gen_random_uuid(), 'study', 'no_photo', 'friends', null, null, null, null, null, null, null, g2);
  assert sess -> 'group_id' = 'null'::jsonb, 'friends 공개는 group_id null';
  s_fr := (sess ->> 'id')::uuid;
  perform end_session(s_fr, 'done', null);
  sess := start_session(gen_random_uuid(), 'coding', 'no_photo', 'crew', null, null, null, null, '코딩', null, null, g2);
  s2 := (sess ->> 'id')::uuid;
  perform end_session(s2, 'done', null);

  -- 피드: u 본인. 크루 피드는 그 크루로 묶인 세션만
  assert s1 = any (c_t_ids(get_feed(null, 50, g1))) and not (s2 = any (c_t_ids(get_feed(null, 50, g1)))), 'g1 피드는 s1만';
  assert s2 = any (c_t_ids(get_feed(null, 50, g2))) and not (s1 = any (c_t_ids(get_feed(null, 50, g2)))), 'g2 피드는 s2만';
  assert not (s_fr = any (c_t_ids(get_feed(null, 50, g1)))), 'friends 세션은 크루 피드에 안 나옴';
  card := (select i from jsonb_array_elements(get_feed(null, 50, g1) -> 'items') i where (i ->> 'session_id')::uuid = s1);
  assert (card ->> 'group_id')::uuid = g1 and card ->> 'group_name' = '크루1', 'FeedCard group_id/group_name';

  -- g1에만 속한 m1: 볼 수 있고, 피드(기본·g1)에 나온다. g2 피드는 못 연다
  reset role;
  assert can_view_session(m1, s1), 'm1은 g1 세션을 봄';
  assert not can_view_session(m1, s2), 'm1은 g2 세션을 못 봄';
  assert can_view_session(m2, s2) and not can_view_session(m2, s1), 'm2는 g2 세션만 봄';
  assert not can_view_session(m1, s_fr), 'friends 세션은 친구만';
  perform test_login(m1);
  page := get_feed(null, 50, null);
  assert s1 = any (c_t_ids(page)) and not (s2 = any (c_t_ids(page))), 'm1 기본 피드: s1만';
  assert s1 = any (c_t_ids(get_feed(null, 50, g1)));
  perform c_t_err(format('select get_feed(null, 10, %L)', g2), 'forbidden');
  card := (select i from jsonb_array_elements(page -> 'items') i where (i ->> 'session_id')::uuid = s1);
  assert (card ->> 'group_id')::uuid = g1 and card ->> 'group_name' = '크루1';
  perform c_t_err(format('select add_comment(%L, %L)', s2, 'hi'), 'not_found');
  perform c_t_err(format('select set_reaction(%L, %L)', s2, 'fire'), 'not_found');
  perform add_comment(s1, '좋아요');
  perform test_login(m2);
  assert not (s1 = any (c_t_ids(get_feed(null, 50, null)))) and s2 = any (c_t_ids(get_feed(null, 50, null))), 'm2 기본 피드: s2만';

  -- 친구는 크루 구성원이 아니어도 crew 세션을 보지만 크루 이름은 모른다
  perform test_login(fr);
  page := get_feed(null, 50, null);
  assert s1 = any (c_t_ids(page)) and s2 = any (c_t_ids(page)), '친구는 둘 다 봄';
  card := (select i from jsonb_array_elements(page -> 'items') i where (i ->> 'session_id')::uuid = s1);
  assert card -> 'group_id' = 'null'::jsonb and card -> 'group_name' = 'null'::jsonb, '구성원이 아니면 크루 id·이름이 안 보임';

  -- 크루에서 나가면 그 크루로 묶인 세션은 크루원에게 안 보인다(친구는 계속)
  perform test_login(m1);  perform leave_crew(g1);
  reset role;
  assert not can_view_session(m1, s1), '나간 뒤에는 못 봄';
  assert can_view_session(fr, s1), '친구는 계속 봄';

  -- 공유 범위 수정: 크루 바꾸기, crew가 아니면 null, 다시 crew로 올릴 때 규칙
  perform test_login(u);
  sess := update_session_share(s1, 'crew', '공부', null, g2);
  assert (sess ->> 'group_id')::uuid = g2, 'group_id 바꾸기';
  sess := update_session_share(s1, null, '공부', null, null);
  assert (sess ->> 'group_id')::uuid = g2, 'p_group_id를 안 주면 지금 크루 유지';
  perform c_t_err(format('select update_session_share(%L, ''crew'', null, null, %L)', s1, g3), 'not_found');
  sess := update_session_share(s1, 'friends', '공부', null, null);
  assert sess -> 'group_id' = 'null'::jsonb, 'crew가 아니면 null';
  perform c_t_err(format('select update_session_share(%L, ''crew'', null, null, null)', s1), 'invalid_input');   -- 크루 둘, 기본값 없음
  sess := update_session_share(s1, 'crew', null, null, g1);
  assert (sess ->> 'group_id')::uuid = g1;

  -- 이어가는 일의 기본 크루: p_group_id가 없으면 그것을 쓴다
  th := create_thread('기본크루 일', 'study', null, 'crew', g2);
  assert (th ->> 'default_group_id')::uuid = g2, 'Thread.default_group_id';
  sess := start_session(gen_random_uuid(), 'study', 'no_photo', null, (th ->> 'id')::uuid);
  assert sess ->> 'visibility' = 'crew' and (sess ->> 'group_id')::uuid = g2, '이어가는 일의 기본 크루';
  perform end_session((sess ->> 'id')::uuid, 'done', null);
  sess := start_session(gen_random_uuid(), 'study', 'no_photo', 'crew', (th ->> 'id')::uuid, null, null, null, null, null, null, g1);
  assert (sess ->> 'group_id')::uuid = g1, '명시한 크루가 기본값보다 우선';
  perform end_session((sess ->> 'id')::uuid, 'done', null);

  -- 크루가 정확히 하나인 사람은 고르지 않아도 그 크루
  perform test_login(m2);
  sess := start_session(gen_random_uuid(), 'study', 'no_photo', 'crew');
  assert (sess ->> 'group_id')::uuid = g2, '크루가 하나면 자동';
  perform end_session((sess ->> 'id')::uuid, 'done', null);
  -- 크루가 없는 사람이 crew로 시작하면 invalid_input
  reset role;
  perform test_login(c_t_user('lone', sc));
  perform c_t_err(format('select start_session(%L, ''study'', ''no_photo'', ''crew'')', gen_random_uuid()), 'invalid_input');
  reset role;
end $$;

-- 서로 다른 크루로 묶인 세션은 그 크루의 구성원만 본다(둘 다 구성원인 크루만 인정)
do $$
declare sc uuid := c_t_school(); a uuid := c_t_user('a', sc); b uuid := c_t_user('b', sc);
  ga uuid := gen_random_uuid(); gb uuid := gen_random_uuid(); sa uuid;
begin
  insert into groups (id, school_id, name, owner_id, invite_code) values
    (ga, sc, 'ga', a, 'C8A' || replace(ga::text, '-', '')), (gb, sc, 'gb', b, 'C8B' || replace(gb::text, '-', ''));
  insert into group_members (group_id, user_id, role) values (ga, a, 'owner'), (gb, b, 'owner'), (gb, a, 'member');
  sa := c_t_session(a, 'crew', 'ended', now() - interval '1 hour', 'x', null, null, ga);
  assert not can_view_session(b, sa), 'b는 ga 구성원이 아니라 못 봄(gb에는 같이 있어도)';
  update sessions set group_id = gb where id = sa;
  assert can_view_session(b, sa), 'gb로 묶으면 봄';
  delete from groups where id = gb;
  assert (select group_id from sessions where id = sa) is null, 'on delete set null';
  assert not can_view_session(b, sa), '크루가 사라지면 크루원에게는 안 보임';
end $$;

-- 세션 주인이 자기 카드에 달린 남의 한마디를 지울 수 없다
do $$
declare sc uuid := c_t_school(); own uuid := c_t_user('own', sc); fr uuid := c_t_user('fr', sc); s uuid; c jsonb;
begin
  perform c_t_friends(own, fr);
  s := c_t_session(own, 'friends');
  perform test_login(fr);
  c := add_comment(s, '친구의 한마디');
  perform test_login(own);
  perform c_t_err(format('select delete_comment(%L)', c ->> 'id'), 'forbidden');
  reset role;
  assert exists (select 1 from comments where id = (c ->> 'id')::uuid), '주인이 지우려 해도 남아 있음';
  perform test_login(fr);
  perform delete_comment((c ->> 'id')::uuid);
  reset role;
  assert not exists (select 1 from comments where id = (c ->> 'id')::uuid), '쓴 사람은 지움';
end $$;

-- 초대 코드 바꾸기
do $$
declare sc uuid := c_t_school(); o uuid := c_t_user('o', sc); m uuid := c_t_user('m', sc); x uuid := c_t_user('x', sc);
  late uuid := c_t_user('late', sc); gid uuid; old text; new_ jsonb; r jsonb; outsider uuid := c_t_user('out', c_t_school());
begin
  perform test_login(o);
  r := create_crew('코드'); gid := (r ->> 'id')::uuid; old := r ->> 'invite_code';
  perform test_login(m); perform join_crew(old);
  -- 운영자가 아니면 forbidden(구성원, 비구성원, 없는 크루)
  perform c_t_err(format('select rotate_invite_code(%L)', gid), 'forbidden');
  perform test_login(x);
  perform c_t_err(format('select rotate_invite_code(%L)', gid), 'forbidden');
  perform c_t_err(format('select rotate_invite_code(%L)', gen_random_uuid()), 'forbidden');
  perform c_t_err('select rotate_invite_code(null)', 'invalid_input');
  -- 운영자
  perform test_login(o);
  new_ := rotate_invite_code(gid);
  assert new_ ->> 'invite_code' <> old and char_length(new_ ->> 'invite_code') >= 8, '새 코드';
  assert (new_ ->> 'id')::uuid = gid and new_ ->> 'role' = 'owner' and (new_ ->> 'member_count')::int = 2, 'Crew 모양';
  assert (list_my_crews() -> 0 ->> 'invite_code') = new_ ->> 'invite_code', '목록에도 새 코드';
  -- 예전 코드는 즉시 무효, 새 코드는 유효
  perform test_login(late);
  perform c_t_err(format('select join_crew(%L)', old), 'invite_invalid');
  assert (join_crew(new_ ->> 'invite_code') ->> 'member_count')::int = 3, '새 코드로 입장';
  perform test_login(m);
  assert list_my_crews() -> 0 ->> 'id' = gid::text, '이미 있는 구성원은 그대로';
  perform test_login(outsider);
  perform c_t_err(format('select rotate_invite_code(%L)', gid), 'forbidden');
  reset role;
end $$;

-- 친구 요청이 거절되면 7일 동안 다시 보낼 수 없다
do $$
declare sc uuid := c_t_school(); a uuid := c_t_user('a', sc); b uuid := c_t_user('b', sc); c uuid := c_t_user('c', sc);
  n int;
begin
  perform test_login(a);  perform send_friend_request(b);
  perform test_login(b);  perform respond_friend_request(a, false);
  perform test_login(a);
  perform c_t_err(format('select send_friend_request(%L)', b), 'rate_limited');
  assert list_friend_requests() = '{"incoming": [], "outgoing": []}'::jsonb, '다시 보낸 요청이 남지 않음';
  -- 6일 23시간이 지나도 아직
  reset role;
  update friend_request_rejections set rejected_at = now() - interval '6 days 23 hours' where requester_id = a and target_id = b;
  perform test_login(a);
  perform c_t_err(format('select send_friend_request(%L)', b), 'rate_limited');
  -- 7일이 지나면 가능
  reset role;
  update friend_request_rejections set rejected_at = now() - interval '7 days 1 minute' where requester_id = a and target_id = b;
  perform test_login(a);  perform send_friend_request(b);
  assert jsonb_array_length(list_friend_requests() -> 'outgoing') = 1, '7일 뒤에는 요청 가능';
  -- 다시 거절하면 기록이 갱신되어 또 7일
  perform test_login(b);  perform respond_friend_request(a, false);
  perform test_login(a);
  perform c_t_err(format('select send_friend_request(%L)', b), 'rate_limited');
  -- 다른 사람에게는 영향 없음, 거절한 쪽이 먼저 보내는 것도 막지 않음
  perform send_friend_request(c);
  perform test_login(b);  perform send_friend_request(a);
  perform test_login(a);
  assert jsonb_array_length(list_friend_requests() -> 'incoming') = 1, 'b의 요청은 막히지 않음';
  perform respond_friend_request(b, true);
  assert (select count(*) from jsonb_array_elements(list_friends())) = 1, '수락하면 친구';
  reset role;
  assert not exists (select 1 from friend_request_rejections where requester_id = a and target_id = b), '친구가 되면 기록 삭제';

  -- 차단: 내가 차단한 상대에게는 blocked, 나를 차단한 상대에게는 조용히 성공(아무 일도 없음)
  perform test_login(c);  perform block_user(a);
  perform test_login(a);
  assert send_friend_request(c) is null, '차단당한 쪽은 성공으로 보임';
  perform test_login(c);
  perform c_t_err(format('select send_friend_request(%L)', a), 'blocked');
  reset role;
  select count(*) into n from friendships where user_a in (a, c) and user_b in (a, c);
  assert n = 0, '차단 관계에는 요청 행이 없음';
  -- 접근 규칙: 거절 기록 표는 앱이 직접 못 읽는다
  perform test_login(a);
  begin
    perform 1 from friend_request_rejections limit 1;
    raise exception '거절 기록을 직접 읽음';
  exception when insufficient_privilege then null; end;
  reset role;
end $$;
