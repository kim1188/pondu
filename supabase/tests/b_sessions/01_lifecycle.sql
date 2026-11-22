\ir 00_helpers.sql
-- 상태 전이, 같은 client_id 재호출, 동시 세션 거절, 일시 정지 시간 계산, 연결된 예정 시간·할 일 처리
select tt.mk_user('가') as ua \gset
select tt.mk_user('나') as ub \gset
select set_config('t.ua', :'ua', false), set_config('t.ub', :'ub', false) \gset

-- 연결 대상(관리자 권한으로 준비)
insert into threads (id, user_id, title, primary_category) values ('11111111-0000-0000-0000-000000000001', :'ua', '이어가는 일', 'study');
insert into todos (id, user_id, thread_id, title) values ('22222222-0000-0000-0000-000000000001', :'ua', '11111111-0000-0000-0000-000000000001', '할 일');
insert into plan_blocks (id, user_id, todo_id, start_at, end_at)
  values ('33333333-0000-0000-0000-000000000001', :'ua', '22222222-0000-0000-0000-000000000001', now(), now() + interval '1 hour');

select test_login(:'ua');

do $$
declare
  ua uuid := current_setting('t.ua')::uuid;
  cid uuid := gen_random_uuid();
  s jsonb; s2 jsonb; sid uuid;
begin
  assert (select get_my_live_session()) is null, '처음에는 진행 중 세션이 없다';

  s := start_session(cid, 'study', 'no_photo', 'friends', null, '22222222-0000-0000-0000-000000000001',
                     '33333333-0000-0000-0000-000000000001', array['알고리즘'], '  공유 제목  ');
  sid := (s->>'id')::uuid;
  perform tt.assert(s->>'status' = 'live', 'start → live');
  perform tt.assert(s->>'user_id' = ua::text, '주인');
  perform tt.assert(s->>'visibility' = 'friends', 'visibility');
  perform tt.assert(s->>'share_title' = '공유 제목', 'share_title 공백 제거');
  perform tt.assert(s->>'thread_id' = '11111111-0000-0000-0000-000000000001', '할 일의 이어가는 일을 따라간다');
  perform tt.assert(s->'tags' = '["알고리즘"]'::jsonb, 'tags');
  perform tt.assert(s->>'ended_at' is null and s->>'offline_started_at' is null, '끝 시각 없음');
  perform tt.assert(s->>'started_at' ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$', '시각은 ISO 8601 UTC');
  perform tt.assert((s->>'duration_seconds')::int >= 0, 'duration');

  -- 같은 client_id 재호출: 같은 세션, 새 행 없음
  s2 := start_session(cid, 'coding');
  perform tt.assert(s2->>'id' = s->>'id', '같은 client_id 는 기존 세션');
  perform tt.assert(s2->>'primary_category' = 'study', '기존 세션을 그대로(인자 무시)');

  -- 동시 세션 거절
  perform tt.expect_err(format('select start_session(%L, ''coding'')', gen_random_uuid()), 'session_already_active');

  -- get_my_live_session
  perform tt.assert((get_my_live_session())->>'id' = s->>'id', 'live 조회');

  -- 잘못된 전이
  perform tt.expect_err(format('select resume_session(%L)', sid), 'session_not_active');
  s := pause_session(sid);
  perform tt.assert(s->>'status' = 'paused' and s->>'paused_at' is not null, 'pause');
  perform tt.assert((get_my_live_session())->>'status' = 'paused', '정지 중에도 진행 중 세션이다');
  perform tt.expect_err(format('select pause_session(%L)', sid), 'session_not_active');
  perform tt.expect_err(format('select start_session(%L, ''coding'')', gen_random_uuid()), 'session_already_active');
  s := resume_session(sid);
  perform tt.assert(s->>'status' = 'live' and s->>'paused_at' is null, 'resume');

  -- 종료
  perform tt.expect_err(format('select end_session(%L, null)', sid), 'invalid_input');
  perform tt.expect_err(format('select end_session(%L, ''done'', %L)', sid, repeat('가', 201)), 'invalid_input');
  s := end_session(sid, 'more', '여기까지');
  perform tt.assert(s->>'status' = 'ended' and s->>'ended_at' is not null, 'end');
  perform tt.assert(s->>'outcome' = 'more' and s->>'progress_note' = '여기까지', 'outcome, note');
  perform tt.expect_err(format('select end_session(%L, ''done'')', sid), 'session_not_active');
  perform tt.expect_err(format('select pause_session(%L)', sid), 'session_not_active');
  perform tt.expect_err(format('select resume_session(%L)', sid), 'session_not_active');
  perform tt.expect_err(format('select confirm_end(%L, now())', sid), 'session_not_active');
  perform tt.assert((get_my_live_session()) is null, '끝나면 진행 중 세션 없음');

  -- 끝난 뒤에도 같은 client_id 는 그 세션을 돌려준다(새 세션을 만들지 않는다)
  s2 := start_session(cid, 'coding');
  perform tt.assert(s2->>'id' = sid::text and s2->>'status' = 'ended', '끝난 뒤 재호출도 같은 세션');

  -- 세션이 끝나면 예정 시간은 started, 열린 할 일은 in_progress(완료는 건드리지 않는다)
  reset role;
  perform tt.assert((select status from plan_blocks where id = '33333333-0000-0000-0000-000000000001') = 'started', '예정 시간 started');
  perform tt.assert((select status from todos where id = '22222222-0000-0000-0000-000000000001') = 'in_progress', '할 일 in_progress');
  perform tt.assert((select completed_at from todos where id = '22222222-0000-0000-0000-000000000001') is null, '할 일은 완료되지 않았다');
  -- 모든 전이는 session_events 에 남는다
  perform tt.assert((select array_agg(type order by id) from session_events where session_id = sid)
                    = array['start', 'pause', 'resume', 'end'], 'session_events 순서: ' || (select array_agg(type order by id)::text from session_events where session_id = sid));
end $$;

-- 일시 정지 시간 계산: 시작 → 1초 → 정지 → 2초 → 재개 → 1초 → 종료. 활동 시간은 정지 시간을 뺀다.
select test_login(:'ua');
select start_session(gen_random_uuid(), 'coding') ->> 'id' as sid \gset
select pg_sleep(1);
select pause_session(:'sid');
select pg_sleep(2);
select resume_session(:'sid');
select pg_sleep(1);
do $$
declare s jsonb := get_my_live_session();
begin
  perform tt.assert((s->>'paused_seconds')::int between 2 and 3, '정지 시간 약 2초: ' || (s->>'paused_seconds'));
  perform tt.assert((s->>'duration_seconds')::int between 1 and 3, '진행 중 duration 은 정지 시간을 뺀다: ' || (s->>'duration_seconds'));
end $$;
-- 정지한 채로 종료하면 정지 시간이 종료 시각까지 쌓인다
select pause_session(:'sid');
select pg_sleep(2);
select end_session(:'sid', 'stop') as ended \gset
do $$
declare
  s jsonb := (select list_my_sessions(null, 1)->'items'->0);
  wall numeric := extract(epoch from (s->>'ended_at')::timestamptz - (s->>'started_at')::timestamptz);
begin
  perform tt.assert((s->>'paused_seconds')::int between 4 and 6, '정지 시간 합 약 4~5초: ' || (s->>'paused_seconds'));
  perform tt.assert(abs((s->>'duration_seconds')::int - (wall - (s->>'paused_seconds')::int)) <= 1, '끝난 duration = 끝 - 시작 - 정지');
  perform tt.assert((s->>'duration_seconds')::int between 1 and 3, 'duration 약 2초: ' || (s->>'duration_seconds'));
  perform tt.assert(s->>'paused_at' is null, '끝나면 paused_at 비움');
end $$;

-- daily_stats: 종료 때 한 번 반영(Asia/Seoul 날짜)
reset role;
do $$
declare ua uuid := current_setting('t.ua')::uuid;
begin
  perform tt.assert((select sum(session_count) from daily_stats where user_id = ua) = 2, '끝난 세션 2개 집계');
  perform tt.assert((select count(*) from daily_stats where user_id = ua and day = (now() at time zone 'Asia/Seoul')::date) between 1 and 2, '오늘(KST)');
end $$;

-- 입력 검사
select test_login(:'ua');
do $$
declare ua uuid := current_setting('t.ua')::uuid;
begin
  perform tt.expect_err(format('select start_session(%L, ''study'', ''no_photo'', ''department'')', gen_random_uuid()), 'visibility_not_available');
  perform tt.expect_err(format('select start_session(%L, ''study'', ''no_photo'', ''school'')', gen_random_uuid()), 'visibility_not_available');
  perform tt.expect_err(format('select start_session(%L, null)', gen_random_uuid()), 'invalid_input');
  perform tt.expect_err(format('select start_session(%L, ''study'', ''no_photo'', ''private'', null, null, null, null, %L)', gen_random_uuid(), repeat('a', 61)), 'invalid_input');
  perform tt.expect_err(format('select start_session(%L, ''study'', ''no_photo'', ''private'', %L)', gen_random_uuid(), gen_random_uuid()), 'not_found');
  -- 실패한 시작은 세션을 남기지 않는다
  perform tt.assert((get_my_live_session()) is null, '실패한 시작은 흔적이 없다');
end $$;
select test_anon();
select tt.expect_err(format('select start_session(%L, ''study'')', gen_random_uuid()), 'permission denied for function start_session');
reset role;
