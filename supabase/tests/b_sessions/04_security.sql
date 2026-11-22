\ir 00_helpers.sql
-- 남의 세션 조작 거절, 테이블·내부 함수 직접 접근 거절, 클라이언트가 시각을 조작할 수 있는 경로가 없는지
select tt_b.mk_user('가') as ua \gset
select tt_b.mk_user('나') as ub \gset
select set_config('t.ua', :'ua', false), set_config('t.ub', :'ub', false) \gset

select test_login(:'ua');
select start_session(gen_random_uuid(), 'study', 'in_app_photo', 'friends') ->> 'id' as sa \gset
select set_config('t.sa', :'sa', false) \gset

-- 나(ub)가 가(ua)의 세션을 건드려 본다
select test_login(:'ub');
do $$
declare sa text := current_setting('t.sa');
begin
  perform tt_b.expect_err(format('select pause_session(%L)', sa), 'not_found');
  perform tt_b.expect_err(format('select resume_session(%L)', sa), 'not_found');
  perform tt_b.expect_err(format('select end_session(%L, ''done'')', sa), 'not_found');
  perform tt_b.expect_err(format('select confirm_end(%L, now() - interval ''1 minute'')', sa), 'not_found');
  perform tt_b.expect_err(format('select attach_session_photo(%L, %L, null)', sa, current_setting('t.ua') || '/' || sa || '/full.heic'), 'not_found');
  perform tt_b.expect_err(format('select update_session_share(%L, ''private'', ''x'', ''y'')', sa), 'not_found');
  perform tt_b.expect_err(format('select start_session(%L, ''study'', ''no_photo'', ''private'', %L)', gen_random_uuid(), gen_random_uuid()), 'not_found');
  -- 내 목록과 진행 중 조회에 남의 것이 섞이지 않는다
  perform tt_b.assert((get_my_live_session()) is null, '남의 진행 중 세션은 내 것이 아니다');
  perform tt_b.assert(jsonb_array_length(list_my_sessions(null, 50)->'items') = 0, '남의 세션은 내 목록에 없다');
  perform tt_b.assert(jsonb_array_length(get_record_summary(current_date - 1, current_date + 1, 'Asia/Seoul')->'days') = 0, '남의 기록은 내 요약에 없다');
  -- 남의 할 일·이어가는 일·예정 시간을 내 세션에 연결할 수 없다
  perform tt_b.expect_err(format('select start_session(%L, ''study'', ''no_photo'', ''private'', null, %L)', gen_random_uuid(), gen_random_uuid()), 'not_found');
end $$;
-- 남의 이어가는 일/할 일 연결 시도
reset role;
insert into threads (id, user_id, title, primary_category) values ('11111111-0000-0000-0000-0000000000aa', :'ua', '가의 일', 'study');
insert into todos (id, user_id, title) values ('22222222-0000-0000-0000-0000000000aa', :'ua', '가의 할 일');
insert into plan_blocks (id, user_id, start_at, end_at) values ('33333333-0000-0000-0000-0000000000aa', :'ua', now(), now() + interval '1 hour');
select test_login(:'ub');
select tt_b.expect_err(format('select start_session(%L, ''study'', ''no_photo'', ''private'', %L)', gen_random_uuid(), '11111111-0000-0000-0000-0000000000aa'), 'not_found');
select tt_b.expect_err(format('select start_session(%L, ''study'', ''no_photo'', ''private'', null, %L)', gen_random_uuid(), '22222222-0000-0000-0000-0000000000aa'), 'not_found');
select tt_b.expect_err(format('select start_session(%L, ''study'', ''no_photo'', ''private'', null, null, %L)', gen_random_uuid(), '33333333-0000-0000-0000-0000000000aa'), 'not_found');

-- 가의 세션은 아무 일도 없었다
select test_login(:'ua');
do $$
declare s jsonb := get_my_live_session();
begin
  perform tt_b.assert(s->>'status' = 'live' and s->>'visibility' = 'friends' and s->>'photo_path' is null and s->>'share_title' is null, '남의 조작이 반영되지 않았다');
end $$;

-- 같은 client_id 를 다른 사용자가 써도 서로 영향이 없다(client_id 는 사용자별)
select start_session(gen_random_uuid(), 'coding') is not null as dummy where false;
select test_login(:'ub');
select set_config('t.cid', gen_random_uuid()::text, false) \gset
select start_session(current_setting('t.cid')::uuid, 'coding') ->> 'user_id' as u \gset
select (:'u' = :'ub') as ok \gset
select end_session((get_my_live_session()->>'id')::uuid, 'stop');

-- 테이블과 내부 함수는 로그인한 사용자가 직접 못 쓴다
select tt_b.expect_denied('select * from sessions');
select tt_b.expect_denied('select * from session_events');
select tt_b.expect_denied('select * from daily_stats');
select tt_b.expect_denied(format('insert into sessions (user_id, client_id, primary_category) values (%L, %L, ''study'')', :'ub', gen_random_uuid()));
select tt_b.expect_denied(format('update sessions set started_at = now() - interval ''5 hours'' where user_id = %L', :'ub'));
select tt_b.expect_denied(format('update sessions set ended_at = now() where user_id = %L', :'ub'));
select tt_b.expect_denied('delete from sessions');
select tt_b.expect_denied(format('insert into daily_stats (user_id, day, primary_category, seconds) values (%L, current_date, ''study'', 99999)', :'ub'));
select tt_b.expect_denied(format('insert into session_events (session_id, type) values (%L, ''x'')', :'sa'));
select tt_b.expect_denied('select sweep_stale_sessions()');
select tt_b.expect_denied('select session_json(s) from sessions s');
select tt_b.expect_denied('select b_apply_daily_stats(s) from sessions s');
select tt_b.expect_denied('select b_start_links(s) from sessions s');
select tt_b.expect_denied('select b_log_event(gen_random_uuid(), ''x'')');
select tt_b.expect_denied('select b_my_session_locked(gen_random_uuid())');
select tt_b.expect_denied('select b_split_days(now(), now(), 1, ''UTC'')');
select tt_b.expect_denied('select b_net_seconds(s) from sessions s');

-- 로그인 안 한 요청(anon)은 모든 함수를 못 쓴다
select test_anon();
select tt_b.expect_denied(format('select pause_session(%L)', :'sa'));
select tt_b.expect_denied('select get_my_live_session()');
select tt_b.expect_denied('select list_my_sessions(null, 10)');
select tt_b.expect_denied('select get_record_summary(current_date, current_date, ''UTC'')');
select tt_b.expect_denied('select * from sessions');
reset role;

-- 로그인은 했지만 uid 가 없는 요청(토큰 없음)은 not_authenticated
select set_config('request.jwt.claim.sub', '', false), set_config('request.jwt.claim.role', 'authenticated', false) \gset
set role authenticated;
select tt_b.expect_err('select get_my_live_session()', 'not_authenticated');
select tt_b.expect_err(format('select start_session(%L, ''study'')', gen_random_uuid()), 'not_authenticated');
select tt_b.expect_err(format('select end_session(%L, ''done'')', gen_random_uuid()), 'not_authenticated');
select tt_b.expect_err('select list_my_sessions(null, 10)', 'not_authenticated');
select tt_b.expect_err('select get_record_summary(current_date, current_date, ''UTC'')', 'not_authenticated');
reset role;

-- 시각을 바꿀 수 있는 경로 점검: 관리자도 변경 방지 트리거를 거친다
do $$
declare
  sa uuid := current_setting('t.sa')::uuid;
begin
  perform tt_b.expect_err(format('update sessions set started_at = started_at - interval ''3 hours'' where id = %L', sa), 'forbidden');
  perform tt_b.expect_err(format('update sessions set user_id = %L where id = %L', current_setting('t.ub'), sa), 'forbidden');
  perform tt_b.expect_err(format('update sessions set created_at = created_at - interval ''1 day'' where id = %L', sa), 'forbidden');
  perform tt_b.expect_err(format('update sessions set offline_started_at = now() where id = %L', sa), 'forbidden');
  perform tt_b.expect_err(format('update sessions set client_id = gen_random_uuid() where id = %L', sa), 'forbidden');
end $$;
-- 끝난 세션은 시간·상태를 못 바꾼다
select test_login(:'ua');
select end_session(:'sa', 'done') as e \gset
reset role;
do $$
declare sa uuid := current_setting('t.sa')::uuid;
begin
  perform tt_b.expect_err(format('update sessions set ended_at = ended_at + interval ''2 hours'' where id = %L', sa), 'forbidden');
  perform tt_b.expect_err(format('update sessions set paused_seconds = 99999 where id = %L', sa), 'forbidden');
  perform tt_b.expect_err(format('update sessions set status = ''live'' where id = %L', sa), 'forbidden');
  perform tt_b.expect_err(format('update sessions set outcome = ''stop'' where id = %L', sa), 'forbidden');
  -- 공유 필드는 허용(함수가 쓴다)
  update sessions set progress_note = '허용' where id = sa;
end $$;

-- 시각 인자를 받는 공개 함수는 둘뿐이다
do $$
declare r record;
begin
  for r in
    select p.proname, pg_get_function_arguments(p.oid) args from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and has_function_privilege('authenticated', p.oid, 'execute')
      and p.proname in ('start_session','pause_session','resume_session','end_session','confirm_end','attach_session_photo',
                        'update_session_share','get_my_live_session','list_my_sessions','get_record_summary')
      and pg_get_function_arguments(p.oid) ~* 'timestamp|interval'
  loop
    perform tt_b.assert(r.proname in ('start_session', 'confirm_end'), '시각 인자를 받는 함수: ' || r.proname);
  end loop;
  -- 공개 함수는 모두 security definer + search_path 고정
  perform tt_b.assert((select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace
      and p.proname in ('start_session','pause_session','resume_session','end_session','confirm_end','attach_session_photo',
                        'update_session_share','get_my_live_session','list_my_sessions','get_record_summary','sweep_stale_sessions')
      and (not p.prosecdef or p.proconfig is null or not ('search_path=public' = any(p.proconfig)))) = 0, 'security definer + search_path');
end $$;
