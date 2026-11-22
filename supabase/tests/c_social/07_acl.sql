-- 접근 권한: 앱은 테이블을 못 읽고, 공개 함수만 쓰고, 내부 함수는 못 부른다. 로그인 없이는 아무것도 안 된다.
do $$
declare sc uuid := c_t_school(); a uuid := c_t_user('a', sc); b uuid := c_t_user('b', sc); n int; f text; r record;
  pub text[] := array['send_friend_request','respond_friend_request','remove_friend','block_user','unblock_user',
    'list_friends','list_friend_requests','create_crew','join_crew','leave_crew','remove_crew_member','list_my_crews',
    'list_crew_members','rotate_invite_code','get_feed','get_thread_history','set_reaction','add_comment','list_comments','delete_comment',
    'report_session'];
begin
  -- 모든 공개 함수: security definer, search_path 고정, authenticated만 실행, anon·public 불가
  foreach f in array pub loop
    select * into r from pg_proc where proname = f and pronamespace = 'public'::regnamespace;
    assert found, format('함수 없음: %s', f);
    assert r.prosecdef, format('%s: security definer 아님', f);
    assert r.proconfig is not null and exists (select 1 from unnest(r.proconfig) c where c like 'search_path=%'), format('%s: search_path 없음', f);
    assert has_function_privilege('authenticated', r.oid, 'execute'), format('%s: authenticated 실행 불가', f);
    assert not has_function_privilege('anon', r.oid, 'execute'), format('%s: anon 실행 가능', f);
    assert not has_function_privilege('public', r.oid, 'execute'), format('%s: public 실행 가능', f);
  end loop;
  -- 내부 함수는 authenticated에도 막혀 있다
  for r in select p.oid, p.proname from pg_proc p where pronamespace = 'public'::regnamespace
           and (p.proname = 'can_view_session' or p.proname like 'social\_%') loop
    assert not has_function_privilege('authenticated', r.oid, 'execute'), format('%s: 내부 함수가 열려 있음', r.proname);
    assert not has_function_privilege('anon', r.oid, 'execute'), format('%s: 내부 함수가 anon에 열림', r.proname);
  end loop;

  -- 테이블 직접 접근 금지
  perform test_login(a);
  foreach f in array array['friendships','groups','group_members','reactions','comments','blocks','reports','notification_outbox','sessions'] loop
    begin
      execute format('select 1 from public.%I limit 1', f);
      raise exception '%: 직접 읽기가 허용됨', f;
    exception when insufficient_privilege then null;
    end;
    begin
      execute format('delete from public.%I', f);
      raise exception '%: 직접 삭제가 허용됨', f;
    exception when insufficient_privilege then null;
    end;
  end loop;
  reset role;

  -- 비로그인(anon)은 함수 자체를 못 부른다
  perform test_anon();
  begin perform list_friends(); raise exception 'anon이 list_friends 실행'; exception when insufficient_privilege then null; end;
  begin perform get_feed(null, 10, null); raise exception 'anon이 get_feed 실행'; exception when insufficient_privilege then null; end;
  reset role;

  -- 로그인 토큰이 비어 있으면 모든 공개 함수가 not_authenticated
  perform set_config('request.jwt.claim.sub', '', false); set role authenticated;
  perform c_t_err('select list_friends()', 'not_authenticated');
  perform c_t_err('select list_friend_requests()', 'not_authenticated');
  perform c_t_err('select list_my_crews()', 'not_authenticated');
  perform c_t_err('select get_feed(null, 10, null)', 'not_authenticated');
  perform c_t_err(format('select get_thread_history(%L, 10)', gen_random_uuid()), 'not_authenticated');
  perform c_t_err(format('select send_friend_request(%L)', a), 'not_authenticated');
  perform c_t_err(format('select respond_friend_request(%L, true)', a), 'not_authenticated');
  perform c_t_err(format('select remove_friend(%L)', a), 'not_authenticated');
  perform c_t_err(format('select block_user(%L)', a), 'not_authenticated');
  perform c_t_err(format('select unblock_user(%L)', a), 'not_authenticated');
  perform c_t_err($q$select create_crew('x')$q$, 'not_authenticated');
  perform c_t_err($q$select join_crew('x')$q$, 'not_authenticated');
  perform c_t_err(format('select leave_crew(%L)', gen_random_uuid()), 'not_authenticated');
  perform c_t_err(format('select remove_crew_member(%L, %L)', gen_random_uuid(), a), 'not_authenticated');
  perform c_t_err(format('select list_crew_members(%L)', gen_random_uuid()), 'not_authenticated');
  perform c_t_err(format('select set_reaction(%L, %L)', gen_random_uuid(), 'fire'), 'not_authenticated');
  perform c_t_err(format('select add_comment(%L, %L)', gen_random_uuid(), 'x'), 'not_authenticated');
  perform c_t_err(format('select list_comments(%L)', gen_random_uuid()), 'not_authenticated');
  perform c_t_err(format('select delete_comment(%L)', gen_random_uuid()), 'not_authenticated');
  perform c_t_err(format('select report_session(%L, %L)', gen_random_uuid(), 'x'), 'not_authenticated');
  reset role;

  -- 낯선 사람이 남의 크루·세션·한마디를 읽거나 바꿔 보기(다른 파일에서 다룬 것의 요약 점검)
  declare g uuid := gen_random_uuid(); s uuid; cid uuid := gen_random_uuid();
  begin
    insert into groups (id, school_id, name, owner_id, invite_code) values (g, sc, 'g', a, 'C7' || replace(g::text, '-', ''));
    insert into group_members (group_id, user_id, role) values (g, a, 'owner');
    s := c_t_session(a, 'crew');
    insert into comments (id, session_id, user_id, body) values (cid, s, a, '내 한마디');
    perform test_login(b);
    perform c_t_err(format('select list_crew_members(%L)', g), 'forbidden');
    perform c_t_err(format('select remove_crew_member(%L, %L)', g, a), 'forbidden');
    perform c_t_err(format('select leave_crew(%L)', g), 'not_found');
    perform c_t_err(format('select get_feed(null, 10, %L)', g), 'forbidden');
    perform c_t_err(format('select list_comments(%L)', s), 'not_found');
    perform c_t_err(format('select delete_comment(%L)', cid), 'not_found');
    perform c_t_err(format('select get_thread_history(%L, 10)', s), 'not_found');
    perform c_t_err(format('select report_session(%L, %L)', s, 'x'), 'not_found');
    assert get_feed(null, 10, null) = '{"items": [], "next_cursor": null}'::jsonb, '남의 세션이 피드에 나옴';
    reset role;
    assert (select count(*) from group_members where group_id = g) = 1 and exists (select 1 from comments where id = cid), '남이 바꾼 것이 있음';
  end;
end $$;
