\ir 00_helpers.sql
-- 한도 초과: 예약 작업, 종료 확인, 누적 반영, 정정 표시
select tt_b.mk_user('가') as ua \gset
select tt_b.mk_user('나') as ub \gset
select set_config('t.ua', :'ua', false), set_config('t.ub', :'ub', false) \gset

-- 분야별 한도: study 4, coding 4, exercise 3, project 4, venture_research_intern 10, parttime 10
do $$
begin
  perform tt_b.assert(b_limit_seconds('study') = 4*3600 and b_limit_seconds('coding') = 4*3600 and b_limit_seconds('exercise') = 3*3600
    and b_limit_seconds('project') = 4*3600 and b_limit_seconds('venture_research_intern') = 10*3600
    and b_limit_seconds('parttime') = 10*3600, '분야별 한도');
end $$;

select test_login(:'ua');
select start_session(gen_random_uuid(), 'study') ->> 'id' as s1 \gset
reset role;

-- 한도 안이면 예약 작업이 건드리지 않는다
select sweep_stale_sessions();
select tt_b.backdate(:'s1', interval '3 hours 50 minutes');
select sweep_stale_sessions() as n1 \gset
select (:n1 = 0) as ok1 \gset
do $$ begin perform tt_b.assert(
  (select status from sessions where user_id = current_setting('t.ua')::uuid and status <> 'ended' limit 1) = 'live', '3시간 50분은 아직 live'); end $$;

-- 한도를 넘기면 needs_confirmation
select tt_b.backdate(:'s1', interval '20 minutes');
select sweep_stale_sessions() as n2 \gset
do $$
declare ua uuid := current_setting('t.ua')::uuid;
begin
  perform tt_b.assert((select status from sessions where user_id = ua) = 'needs_confirmation', '한도 초과 → needs_confirmation');
  perform tt_b.assert((select count(*) from daily_stats where user_id = ua) = 0, '확인 전에는 누적에 들어가지 않는다');
  perform tt_b.assert((select count(*) from session_events where session_id = (select id from sessions where user_id = ua) and type = 'needs_confirmation') = 1, '이벤트');
end $$;
select (:n2 >= 1) as ok2 \gset
-- 두 번째 실행은 아무것도 안 바꾼다
select sweep_stale_sessions() as n3 \gset

select test_login(:'ua');
do $$
declare
  ua uuid := current_setting('t.ua')::uuid;
  s jsonb := (list_my_sessions(null, 1))->'items'->0;
  sid uuid := (s->>'id')::uuid;
  st timestamptz := (s->>'started_at')::timestamptz;
begin
  perform tt_b.assert(get_my_live_session()->>'status' = 'needs_confirmation', '종료 확인 대기 세션도 get_my_live_session 이 돌려준다');
  perform tt_b.expect_err(format('select start_session(%L, ''coding'')', gen_random_uuid()), 'session_already_active');
  perform tt_b.assert(s->>'status' = 'needs_confirmation' and s->>'ended_at' is null, '목록에는 보인다');
  perform tt_b.assert(s->>'duration_seconds' is null, '확인 대기 세션의 duration_seconds 는 null');
  -- 확인 전에 또 시작할 수 있다(진행 중이 아니므로)
  perform tt_b.expect_err(format('select end_session(%L, ''done'')', sid), 'session_not_active');
  perform tt_b.expect_err(format('select pause_session(%L)', sid), 'session_not_active');
  -- confirm_end 검사: 시작 이전·같음, 미래, 한도 이후, null
  perform tt_b.expect_err(format('select confirm_end(%L, %L)', sid, st), 'invalid_input');
  perform tt_b.expect_err(format('select confirm_end(%L, %L)', sid, st - interval '1 hour'), 'invalid_input');
  perform tt_b.expect_err(format('select confirm_end(%L, %L)', sid, now() + interval '1 minute'), 'invalid_input');
  perform tt_b.expect_err(format('select confirm_end(%L, %L)', sid, st + interval '4 hours 1 minute'), 'invalid_input');
  perform tt_b.expect_err(format('select confirm_end(%L, null)', sid), 'invalid_input');
  -- 다른 사람은 확인할 수 없다
  perform set_config('t.sid', sid::text, false);
end $$;
select test_login(:'ub');
select tt_b.expect_err(format('select confirm_end(%L, now() - interval ''1 hour'')', current_setting('t.sid')), 'not_found');
select test_login(:'ua');
-- 정상 확인: 시작 3시간 뒤로 정정
select confirm_end(current_setting('t.sid')::uuid, (select (list_my_sessions(null, 1)->'items'->0->>'started_at')::timestamptz + interval '3 hours')) as c \gset
do $$
declare
  ua uuid := current_setting('t.ua')::uuid;
  sid uuid := current_setting('t.sid')::uuid;
  s jsonb := (list_my_sessions(null, 1))->'items'->0;
begin
  perform tt_b.assert(s->>'status' = 'ended' and (s->>'end_corrected')::boolean, '확인 후 ended + end_corrected');
  perform tt_b.assert((s->>'duration_seconds')::int = 3*3600, '확인한 종료 시각 기준 시간: ' || (s->>'duration_seconds'));
  perform tt_b.assert(get_my_live_session() is null, '확인이 끝나면 진행 중 세션 없음');
  perform tt_b.expect_err(format('select confirm_end(%L, now() - interval ''1 hour'')', sid), 'session_not_active');
end $$;
reset role;
do $$
declare ua uuid := current_setting('t.ua')::uuid;
begin
  perform tt_b.assert((select sum(seconds) from daily_stats where user_id = ua) = 3*3600, '확인 후 누적에 반영: ' || (select sum(seconds) from daily_stats where user_id = ua));
  perform tt_b.assert((select sum(session_count) from daily_stats where user_id = ua) = 1, '세션 수 1');
  perform tt_b.assert((select array_agg(type order by id) from session_events where session_id = current_setting('t.sid')::uuid)
                    = array['start', 'needs_confirmation', 'confirm_end'], '원래 이벤트가 남는다');
end $$;

-- 종료를 한도 뒤에 누르면(예약 작업보다 빨리) 바로 누적되지 않고 종료 확인으로 간다
select test_login(:'ub');
select start_session(gen_random_uuid(), 'exercise') ->> 'id' as s2 \gset
reset role;
select tt_b.backdate(:'s2', interval '3 hours 10 minutes');
select test_login(:'ub');
select end_session(:'s2', 'done', '운동 끝') as e \gset
do $$
declare s jsonb := (list_my_sessions(null, 1))->'items'->0;
begin
  perform tt_b.assert(s->>'status' = 'needs_confirmation' and s->>'outcome' = 'done' and s->>'progress_note' = '운동 끝', '한도 뒤 종료는 확인 대기로, 입력은 보존');
  -- 같은 end_session 재시도는 현재 세션을 그대로 돌려준다
  perform tt_b.assert(end_session((s->>'id')::uuid, 'done', '운동 끝') = s, '재시도');
  perform tt_b.expect_err(format('select start_session(%L, ''coding'')', gen_random_uuid()), 'session_already_active');
  -- 한도는 시작부터의 경과 시간: 시작+3시간(운동 한도) 이후로는 확인할 수 없다
  perform tt_b.expect_err(format('select confirm_end(%L, %L)', s->>'id', (s->>'started_at')::timestamptz + interval '3 hours 1 minute'), 'invalid_input');
end $$;
reset role;
do $$ begin perform tt_b.assert((select count(*) from daily_stats where user_id = current_setting('t.ub')::uuid) = 0, '누적 없음'); end $$;
select test_login(:'ub');
select confirm_end(:'s2', (select (e->>'started_at')::timestamptz + interval '2 hours 59 minutes' from jsonb_array_elements(list_my_sessions(null, 50)->'items') e where e->>'id' = :'s2')) ->> 'status' as st2 \gset
select (:'st2' = 'ended') as ok_confirm \gset
reset role;
-- 정지 중인 세션도 한도를 넘길 수 있고, 한도를 넘긴 정지는 선택한 종료 시각까지 정지로 본다
select test_login(:'ub');
select start_session(gen_random_uuid(), 'study') ->> 'id' as s3 \gset
select pause_session(:'s3');
reset role;
-- 4시간 5분 동안 활동하다가 정지한 것처럼: started_at 을 4h5m 전으로, paused_at 은 지금 직전
update sessions set paused_at = now() - interval '1 minute' where id = :'s3';
alter table sessions disable trigger b_sessions_guard;
update sessions set started_at = now() - interval '4 hours 6 minutes' where id = :'s3';
alter table sessions enable trigger b_sessions_guard;
select sweep_stale_sessions() as n4 \gset
select (:n4 = 1) as sweep_paused \gset
select test_login(:'ub');
select set_config('t.s3', :'s3', false) \gset
select confirm_end(:'s3', now() - interval '30 minutes') as c3 \gset
do $$
declare s jsonb := (select e from jsonb_array_elements(list_my_sessions(null, 50)->'items') e
                    where e->>'id' = current_setting('t.s3'));
begin
  perform tt_b.assert(s->>'status' = 'ended', '정지 중 한도 초과도 확인 가능');
  perform tt_b.assert((s->>'duration_seconds')::int between 3*3600 + 35*60 and 3*3600 + 37*60, 'duration 약 3시간 36분: ' || (s->>'duration_seconds'));
end $$;
reset role;
