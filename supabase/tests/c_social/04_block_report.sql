-- 차단(양방향), 신고, 종료 확인 필요 숨김
do $$
declare sc uuid := c_t_school(); a uuid := c_t_user('a', sc); b uuid := c_t_user('b', sc); c uuid := c_t_user('c', sc);
  g uuid := gen_random_uuid(); sa uuid; sb uuid; sc_ uuid; cm uuid; r jsonb; n int;
begin
  perform c_t_friends(a, b); perform c_t_friends(a, c); perform c_t_friends(b, c);
  insert into groups (id, school_id, name, owner_id, invite_code) values (g, sc, 'g', a, 'C4' || replace(g::text, '-', ''));
  insert into group_members (group_id, user_id, role) values (g, a, 'owner'), (g, b, 'member'), (g, c, 'member');
  sa := c_t_session(a, 'crew'); sb := c_t_session(b, 'crew'); sc_ := c_t_session(c, 'crew');
  -- b가 a의 세션에 반응·한마디를 남겨 둔다
  insert into reactions (session_id, user_id, kind) values (sa, b, 'fire'), (sa, c, 'clap');
  insert into comments (session_id, user_id, body) values (sa, b, '화이팅'), (sa, c, '나도');

  -- 차단 전: 서로 보임
  perform test_login(a);
  assert sb = any (c_t_ids(get_feed(null, 50, null))), '차단 전에는 보임';
  r := get_feed(null, 50, null);
  assert (select (i ->> 'reaction_count')::int from jsonb_array_elements(r -> 'items') i where (i ->> 'session_id')::uuid = sa) = 2;

  -- a가 b를 차단
  perform block_user(b);
  perform c_t_err(format('select block_user(%L)', a), 'invalid_input');
  assert list_friends() = jsonb_build_array(profile_card(c)), '차단하면 친구 해제';
  assert not (sb = any (c_t_ids(get_feed(null, 50, null)))), 'a 피드에서 b가 사라짐';
  assert not (sb = any (c_t_ids(get_feed(null, 50, g)))), '크루 피드에서도';
  r := get_feed(null, 50, null);
  assert (select (i ->> 'reaction_count')::int from jsonb_array_elements(r -> 'items') i where (i ->> 'session_id')::uuid = sa) = 1, '차단한 사람의 반응은 세지 않음';
  assert (select (i ->> 'comment_count')::int from jsonb_array_elements(r -> 'items') i where (i ->> 'session_id')::uuid = sa) = 1, '한마디도';
  assert jsonb_array_length(list_comments(sa)) = 1, '목록에서도 빠짐';
  assert (select count(*) from jsonb_array_elements(list_crew_members(g))) = 2, '크루 구성원 목록에서 빠짐';
  perform c_t_err(format('select add_comment(%L, %L)', sb, 'hi'), 'not_found');
  perform c_t_err(format('select set_reaction(%L, %L)', sb, 'fire'), 'not_found');
  perform c_t_err(format('select send_friend_request(%L)', b), 'blocked');

  -- 반대 방향: 차단당한 b도 a를 못 본다
  perform test_login(b);
  assert not (sa = any (c_t_ids(get_feed(null, 50, null)))), 'b 피드에서 a가 사라짐(양방향)';
  assert not (sa = any (c_t_ids(get_feed(null, 50, g))));
  assert sc_ = any (c_t_ids(get_feed(null, 50, null))), '다른 사람은 그대로 보임';
  perform c_t_err(format('select list_comments(%L)', sa), 'not_found');
  perform c_t_err(format('select add_comment(%L, %L)', sa, 'hi'), 'not_found');
  perform c_t_err(format('select send_friend_request(%L)', a), 'blocked');
  assert (select count(*) from jsonb_array_elements(list_crew_members(g))) = 2, '크루 목록에서 a가 빠짐';
  assert list_friends() = jsonb_build_array(profile_card(c));
  -- c의 세션에 달린 a 흔적도 b에게는 안 보임
  reset role;
  insert into comments (session_id, user_id, body) values (sc_, a, 'a의 말');
  perform test_login(b);
  assert jsonb_array_length(list_comments(sc_)) = 0, 'c 세션의 a 한마디가 b에게 안 보임';
  reset role;
  assert not can_view_session(b, sa) and not can_view_session(a, sb), '내부 함수도 양방향';
  -- 차단을 걸었어도 본인 것은 보임
  assert can_view_session(a, sa);

  -- 차단 해제: 다시 보이지만 친구는 아님
  perform test_login(a);
  perform unblock_user(b);
  assert list_friends() = jsonb_build_array(profile_card(c)), '해제해도 친구는 복구되지 않음';
  assert sb = any (c_t_ids(get_feed(null, 50, g))), '해제 후 크루로는 다시 보임';

  -- 신고: 신고한 사람에게만 숨겨진다
  perform test_login(c);
  assert sa = any (c_t_ids(get_feed(null, 50, null)));
  perform c_t_err(format('select report_session(%L, %L)', sc_, '내 것'), 'invalid_input');
  perform c_t_err(format('select report_session(%L, %L)', sa, ''), 'invalid_input');
  perform c_t_err(format('select report_session(%L, %L)', gen_random_uuid(), 'x'), 'not_found');
  perform report_session(sa, '부적절');
  perform report_session(sa, '부적절');       -- 다시 해도 오류 없음
  assert not (sa = any (c_t_ids(get_feed(null, 50, null)))), '신고한 세션은 신고자 피드에서 사라짐';
  perform c_t_err(format('select list_comments(%L)', sa), 'not_found');
  reset role;
  assert not can_view_session(c, sa), '신고자에게 can_view_session 거짓';
  assert (select count(*) from reports where reporter_id = c and session_id = sa) = 1, '신고 한 건';
  assert can_view_session(a, sa) and can_view_session(b, sa), '다른 사람에게는 그대로';
  -- 신고하지 않은 b는 계속 본다
  perform test_login(b);
  assert sa = any (c_t_ids(get_feed(null, 50, null)));
  -- 볼 수 없는 세션은 신고도 못 한다(존재를 알리지 않음)
  reset role;
  declare priv uuid := c_t_session(a, 'private');
  begin
    perform test_login(b);
    perform c_t_err(format('select report_session(%L, %L)', priv, 'x'), 'not_found');
    reset role;
  end;
end $$;
