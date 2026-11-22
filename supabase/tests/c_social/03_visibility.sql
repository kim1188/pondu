-- 공개 범위별 가시성 표: 보는 사람(본인/친구/크루원/친구이면서 크루원/남/다른 크루의 사람) × 공개 범위 × 상태
-- can_view_session(내부)과 get_feed가 같은 결론을 내는지도 본다.
do $$
declare sc uuid := c_t_school();
  own uuid := c_t_user('own', sc); fr uuid := c_t_user('fr', sc); cm uuid := c_t_user('cm', sc);
  both_ uuid := c_t_user('both', sc); st uuid := c_t_user('st', sc); oc uuid := c_t_user('oc', sc);
  g1 uuid := gen_random_uuid(); g2 uuid := gen_random_uuid();
  v text; stt text; sid uuid; viewer uuid; who text; expected boolean; got boolean; in_feed boolean; n int;
  tbl jsonb := '{
   "private": {"own":true, "fr":false, "cm":false, "both":false, "st":false, "oc":false},
   "friends": {"own":true, "fr":true,  "cm":false, "both":true,  "st":false, "oc":false},
   "crew":    {"own":true, "fr":true,  "cm":true,  "both":true,  "st":false, "oc":false},
   "department": {"own":true, "fr":false, "cm":false, "both":false, "st":false, "oc":false},
   "school":     {"own":true, "fr":false, "cm":false, "both":false, "st":false, "oc":false}}';
  users jsonb;
begin
  users := jsonb_build_object('own', own, 'fr', fr, 'cm', cm, 'both', both_, 'st', st, 'oc', oc);
  perform c_t_friends(own, fr); perform c_t_friends(own, both_);
  insert into groups (id, school_id, name, owner_id, invite_code) values
    (g1, sc, 'g1', own, 'C3G1' || replace(g1::text, '-', '')),
    (g2, sc, 'g2', oc, 'C3G2' || replace(g2::text, '-', ''));
  insert into group_members (group_id, user_id, role) values (g1, own, 'owner'), (g1, cm, 'member'), (g1, both_, 'member'),
    (g2, oc, 'owner'), (g2, st, 'member');

  foreach stt in array array['live', 'paused', 'ended'] loop
    foreach v in array array['private', 'friends', 'crew', 'department', 'school'] loop
      update sessions set status = 'ended', ended_at = now() where user_id = own and status in ('live', 'paused');
      sid := c_t_session(own, v::visibility, stt::session_status);
      for who in select jsonb_object_keys(users) loop
        viewer := (users ->> who)::uuid;
        expected := (tbl -> v ->> who)::boolean;
        got := can_view_session(viewer, sid);
        assert got = expected, format('can_view_session %s %s/%s: 기대 %s 실제 %s', who, v, stt, expected, got);
        -- 피드에 나오는지도 같아야 한다(department/school과 private은 피드에 안 나옴, 본인 것은 private만 빼고 나옴)
        perform test_login(viewer);
        in_feed := sid = any (c_t_ids(get_feed(null, 50, null)));
        reset role;
        assert in_feed = (expected and v in ('friends', 'crew')),
          format('피드 %s %s/%s: 기대 %s 실제 %s', who, v, stt, expected and v in ('friends', 'crew'), in_feed);
      end loop;
    end loop;
  end loop;

  -- 종료 확인 필요: 본인만
  foreach v in array array['friends', 'crew'] loop
    sid := c_t_session(own, v::visibility, 'needs_confirmation');
    for who in select jsonb_object_keys(users) loop
      assert can_view_session((users ->> who)::uuid, sid) = (who = 'own'), format('needs_confirmation %s %s', who, v);
      perform test_login((users ->> who)::uuid);
      in_feed := sid = any (c_t_ids(get_feed(null, 50, null)));
      reset role;
      assert not in_feed, format('needs_confirmation이 피드에 나옴 (%s)', who);
    end loop;
  end loop;

  -- 없는 세션, 로그인 사용자의 직접 호출은 막힘(내부 함수)
  assert not can_view_session(own, gen_random_uuid());
  perform test_login(own);
  begin
    perform can_view_session(own, sid);
    raise exception 'authenticated가 can_view_session을 직접 부를 수 있음';
  exception when insufficient_privilege then null;
  end;
  reset role;
end $$;
