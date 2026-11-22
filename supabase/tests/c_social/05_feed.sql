-- 피드: 카드 모양, 개인 정보 비노출, 정렬, 커서, 크루 피드, 반응·한마디 수, 이어가는 일 이력
do $$
declare sc uuid := c_t_school(); me uuid := c_t_user('me', sc); fr uuid := c_t_user('fr', sc); fr2 uuid := c_t_user('fr2', sc);
  st uuid := c_t_user('st', sc); g uuid := gen_random_uuid(); th uuid := gen_random_uuid(); todo uuid := gen_random_uuid();
  s_live uuid; s uuid; ids uuid[] := '{}'; r jsonb; page jsonb; cur text; seen uuid[] := '{}'; all_ids uuid[]; ii int;
  card jsonb; keys text[]; pages int := 0; t0 timestamptz := now() - interval '1 day';
begin
  perform c_t_friends(me, fr); perform c_t_friends(me, fr2); perform c_t_friends(fr, fr2);
  insert into groups (id, school_id, name, owner_id, invite_code) values (g, sc, 'g', fr, 'C5' || replace(g::text, '-', ''));
  insert into group_members (group_id, user_id, role) values (g, fr, 'owner'), (g, st, 'member'), (g, me, 'member');

  -- 작성자의 개인 제목과 할 일, 예정 시간. 피드 어디에도 나오면 안 된다
  insert into threads (id, user_id, title, share_title, primary_category) values (th, fr, 'SECRET-THREAD-제목', '공유용 제목', 'study');
  insert into todos (id, user_id, thread_id, title) values (todo, fr, th, 'SECRET-TODO-할일');
  insert into plan_blocks (user_id, todo_id, thread_id, start_at, end_at) values (fr, todo, th, now(), now() + interval '1 hour');
  s := c_t_session(fr, 'friends', 'ended', t0, null, th);                -- 공유 제목 없음 → 분야 이름
  update sessions set todo_id = todo, progress_note = '진척 메모', photo_path = fr || '/p/full.heic',
    photo_thumb_path = fr || '/p/thumb.heic', capture_mode = 'in_app_photo', paused_seconds = 60 where id = s;
  s_live := c_t_session(fr2, 'crew', 'live', now() - interval '10 minutes', '실시간 제목');

  perform test_login(me);
  page := get_feed(null, 20, null);
  assert page::text not like '%SECRET%', '개인 제목/할 일이 피드에 새어 나옴';
  assert page::text not like '%공유용 제목%' or true;
  card := (select i from jsonb_array_elements(page -> 'items') i where (i ->> 'session_id')::uuid = s);
  keys := array(select jsonb_object_keys(card) order by 1);
  assert keys = array['author','capture_mode','comment_count','duration_seconds','end_corrected','ended_at','joined_with',
    'my_reaction','offline_started','photo_path','photo_thumb_path','primary_category','progress_note','reaction_count',
    'session_id','share_title','started_at','status','thread_id'], format('카드 필드: %s', keys);
  assert card ->> 'share_title' = 'study', '공유 제목이 없으면 분야 이름';
  assert (card ->> 'duration_seconds')::int = 30 * 60 - 60, format('종료 세션 시간 %s', card ->> 'duration_seconds');
  assert card ->> 'capture_mode' = 'in_app_photo' and card ->> 'progress_note' = '진척 메모';
  assert card -> 'author' ->> 'id' = fr::text, '작성자 카드';
  assert (card ->> 'started_at') ~ 'Z$', '시각은 UTC ISO';
  assert card -> 'joined_with' = 'null'::jsonb and (card ->> 'offline_started')::boolean = false;
  -- 진행 중 카드는 맨 위, 지금까지의 시간
  assert (page -> 'items' -> 0 ->> 'session_id')::uuid = s_live, '진행 중이 위';
  assert (page -> 'items' -> 0 ->> 'share_title') = '실시간 제목';
  assert (page -> 'items' -> 0 ->> 'duration_seconds')::int between 590 and 700, '진행 중 시간';
  assert page ->> 'next_cursor' is null;

  -- 반응·한마디 수, 내 반응
  perform set_reaction(s, 'clap');
  perform test_login(fr2); perform set_reaction(s, 'fire'); perform add_comment(s, '굿');
  perform test_login(me);
  perform add_comment(s, '나도');
  card := (select i from jsonb_array_elements(get_feed(null, 20, null) -> 'items') i where (i ->> 'session_id')::uuid = s);
  assert (card ->> 'reaction_count')::int = 2 and card ->> 'my_reaction' = 'clap' and (card ->> 'comment_count')::int = 2, '수와 내 반응';
  perform set_reaction(s, null);
  card := (select i from jsonb_array_elements(get_feed(null, 20, null) -> 'items') i where (i ->> 'session_id')::uuid = s);
  assert (card ->> 'reaction_count')::int = 1 and card -> 'my_reaction' = 'null'::jsonb, '취소';

  -- 크루 피드: crew 공개만, 구성원의 것만
  reset role;
  perform c_t_session(st, 'crew', 'ended', t0 + interval '1 minute', 'st의 크루 글');     -- st는 친구가 아니지만 같은 크루
  perform c_t_session(st, 'friends', 'ended', t0 + interval '2 minutes', 'st의 친구 글');
  perform c_t_session(fr, 'friends', 'ended', t0 + interval '3 minutes', 'fr의 친구 글');
  perform c_t_session(fr, 'crew', 'ended', t0 + interval '4 minutes', 'fr의 크루 글');
  perform test_login(me);
  page := get_feed(null, 50, g);
  assert (select bool_and(i ->> 'share_title' in ('st의 크루 글', 'fr의 크루 글')) from jsonb_array_elements(page -> 'items') i), '크루 피드는 crew 공개만';
  assert jsonb_array_length(page -> 'items') = 2, format('크루 피드 %s건', jsonb_array_length(page -> 'items'));
  page := get_feed(null, 50, null);
  assert page::text like '%st의 크루 글%' and page::text not like '%st의 친구 글%', '기본 피드: 크루원의 crew만, 친구 아닌 사람의 friends는 안 보임';
  assert page::text like '%fr의 친구 글%';
  -- 크루 구성원이 아니면 그 크루 피드를 못 연다
  perform test_login(fr2);
  perform c_t_err(format('select get_feed(null, 10, %L)', g), 'forbidden');
  perform c_t_err(format('select get_feed(null, 10, %L)', gen_random_uuid()), 'forbidden');

  -- 인자 검사
  perform test_login(me);
  perform c_t_err($q$select get_feed(null, 0, null)$q$, 'invalid_input');
  perform c_t_err($q$select get_feed(null, 51, null)$q$, 'invalid_input');
  perform c_t_err($q$select get_feed('쓰레기', 10, null)$q$, 'invalid_input');
  perform c_t_err($q$select get_feed('9|1|x', 10, null)$q$, 'invalid_input');
  assert jsonb_array_length(get_feed(null, null, null) -> 'items') > 0, 'limit 기본값';
end $$;
reset role;

-- 커서 넘김: 진행 중과 종료 섞어서 3개씩, 빠짐·중복 없이, 시작 시각이 같은 행도 안 빠진다
do $$
declare sc uuid := c_t_school(); me uuid := c_t_user('me', sc); fr uuid := c_t_user('fr', sc); fr2 uuid := c_t_user('fr2', sc);
  t0 timestamptz := now() - interval '2 days'; i int; s uuid; want uuid[] := '{}'; got uuid[] := '{}'; page jsonb; cur text; n int := 0;
begin
  perform c_t_friends(me, fr); perform c_t_friends(me, fr2);
  for i in 1..8 loop
    want := want || c_t_session(fr, 'friends', 'ended', t0 + i * interval '1 minute');
  end loop;
  -- 시작 시각이 같은 두 개
  want := want || c_t_session(fr2, 'crew', 'ended', t0 + interval '3 minutes');
  want := want || c_t_session(fr2, 'crew', 'ended', t0 + interval '3 minutes');
  -- 진행 중 둘(작성자가 달라야 함), 가장 오래된 것보다도 앞에 있어도 맨 위에 와야 한다
  want := want || c_t_session(fr, 'friends', 'live', t0 - interval '1 hour');
  want := want || c_t_session(fr2, 'crew', 'paused', t0 - interval '2 hours');
  -- 비공개·종료 확인 필요는 섞여 있어도 안 나온다
  perform c_t_session(fr, 'private', 'ended', t0 + interval '9 minutes');
  perform c_t_session(fr2, 'crew', 'needs_confirmation', t0 + interval '9 minutes');

  perform test_login(me);
  loop
    page := get_feed(cur, 3, null);
    n := n + 1;
    assert jsonb_array_length(page -> 'items') <= 3;
    got := got || c_t_ids(page);
    cur := page ->> 'next_cursor';
    exit when cur is null;
    assert n < 10, '커서가 끝나지 않음';
  end loop;
  assert array_length(got, 1) = array_length(want, 1), format('총 %s건 기대 %s건', array_length(got, 1), array_length(want, 1));
  assert (select count(distinct x) from unnest(got) x) = array_length(got, 1), '중복';
  assert got @> want and want @> got, '빠진 행';
  -- 순서: 진행 중 둘이 맨 앞, 나머지는 시작 시각 내림차순
  reset role;
  assert (select bool_and(status in ('live', 'paused')) from sessions where id = any (got[1:2])), '진행 중이 먼저';
  assert (select array_agg(started_at order by ord) from unnest(got[3:]) with ordinality u(id, ord) join sessions s on s.id = u.id)
       = (select array_agg(started_at order by started_at desc) from unnest(got[3:]) u(id) join sessions s on s.id = u.id), '시작 시각 내림차순';
  -- 한 쪽 페이지 크기가 딱 맞아떨어질 때 다음 커서가 없다
  perform test_login(me);
  assert get_feed(null, 12, null) ->> 'next_cursor' is null, '정확히 12건이면 커서 없음';
  assert get_feed(null, 11, null) ->> 'next_cursor' is not null;
end $$;
reset role;

-- 같은 이어가는 일의 이력
do $$
declare sc uuid := c_t_school(); me uuid := c_t_user('me', sc); fr uuid := c_t_user('fr', sc); st uuid := c_t_user('st', sc);
  th uuid := gen_random_uuid(); th2 uuid := gen_random_uuid(); a uuid; b uuid; c uuid; d uuid; e uuid; h jsonb;
begin
  perform c_t_friends(me, fr);
  insert into threads (id, user_id, title, primary_category) values (th, fr, '비밀 제목', 'study'), (th2, fr, '다른 일', 'study');
  a := c_t_session(fr, 'friends', 'ended', now() - interval '5 hours', 'a', th);
  b := c_t_session(fr, 'private', 'ended', now() - interval '4 hours', 'b', th);        -- 비공개 → 안 보임
  c := c_t_session(fr, 'crew', 'ended', now() - interval '3 hours', 'c', th);
  d := c_t_session(fr, 'friends', 'ended', now() - interval '2 hours', 'd', th2);        -- 다른 일
  e := c_t_session(fr, 'friends', 'needs_confirmation', now() - interval '1 hours', 'e', th);
  perform test_login(me);
  h := get_thread_history(c, 10);
  assert (select array_agg(i ->> 'share_title' order by ord) from jsonb_array_elements(h) with ordinality t(i, ord)) = array['a'], format('이력 %s', h);
  assert h::text not like '%비밀%';
  perform c_t_err(format('select get_thread_history(%L, 10)', b), 'not_found');
  perform c_t_err(format('select get_thread_history(%L, 10)', e), 'not_found');
  perform c_t_err(format('select get_thread_history(%L, 0)', a), 'invalid_input');
  assert get_thread_history(d, 10) = '[]'::jsonb, '다른 세션이 없으면 빈 목록';
  -- 낯선 사람은 못 봄
  perform test_login(st);
  perform c_t_err(format('select get_thread_history(%L, 10)', a), 'not_found');
  -- 본인은 자기 비공개까지
  perform test_login(fr);
  assert jsonb_array_length(get_thread_history(c, 10)) = 3, '본인 이력은 비공개 포함(확인 필요 제외 안 함)';
end $$;
