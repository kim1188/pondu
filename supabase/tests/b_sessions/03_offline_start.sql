\ir 00_helpers.sql
-- 오프라인 시작: 과거 12시간 이내만, offline_started_at 기록, created_at 은 서버 시각
select tt_b.mk_user('가') as ua \gset
select set_config('t.ua', :'ua', false) \gset
select test_login(:'ua');
do $$
declare
  s jsonb;
  off timestamptz := now() - interval '2 hours';
begin
  -- 12시간 초과, 미래는 거절
  perform tt_b.expect_err(format('select start_session(%L, ''study'', ''no_photo'', ''private'', null, null, null, null, null, null, %L)',
    gen_random_uuid(), now() - interval '12 hours 1 minute'), 'invalid_input');
  perform tt_b.expect_err(format('select start_session(%L, ''study'', ''no_photo'', ''private'', null, null, null, null, null, null, %L)',
    gen_random_uuid(), now() + interval '1 hour'), 'invalid_input');
  perform tt_b.assert((get_my_live_session()) is null, '거절되면 세션 없음');

  s := start_session(gen_random_uuid(), 'study', 'no_photo', 'private', null, null, null, null, null, null, off);
  perform tt_b.assert((s->>'started_at')::timestamptz = off, 'started_at 은 오프라인 시각');
  perform tt_b.assert((s->>'offline_started_at')::timestamptz = off, 'offline_started_at 기록');
  perform tt_b.assert((s->>'duration_seconds')::int between 2*3600 and 2*3600 + 5, '진행 시간은 그 시각부터');
  perform set_config('t.sid', s->>'id', false);
end $$;
reset role;
do $$
declare r sessions;
begin
  select * into r from sessions where id = current_setting('t.sid')::uuid;
  perform tt_b.assert(r.created_at > now() - interval '1 minute', 'created_at 은 서버 시각 그대로');
  perform tt_b.assert(r.started_at < now() - interval '1 hour 59 minutes', 'started_at 은 과거');
  perform tt_b.assert((select payload->>'offline' from session_events where session_id = r.id and type = 'start') = 'true', '시작 이벤트에 오프라인 표시');
end $$;

-- 일반 시작은 offline_started_at 이 비어 있다
select test_login(:'ua');
select end_session(current_setting('t.sid')::uuid, 'done') ->> 'ended_at' as e \gset
select start_session(gen_random_uuid(), 'coding') ->> 'offline_started_at' is null as ok \gset
do $$ begin perform tt_b.assert((get_my_live_session()->>'offline_started_at') is null, '일반 시작'); end $$;
select end_session((get_my_live_session()->>'id')::uuid, 'done');

-- 이미 기록된 내 세션과 겹치는 오프라인 시작은 거절(시간을 두 번 쓰는 길을 막는다)
do $$
begin
  perform tt_b.expect_err(format('select start_session(%L, ''study'', ''no_photo'', ''private'', null, null, null, null, null, null, %L)',
    gen_random_uuid(), now() - interval '90 minutes'), 'invalid_input');
end $$;
-- 기기 시계가 아주 조금 앞서면 지금으로 맞춘다
select start_session(gen_random_uuid(), 'coding', 'no_photo', 'private', null, null, null, null, null, null, now() + interval '20 seconds') ->> 'started_at' as st \gset
do $$ begin perform tt_b.assert((get_my_live_session()->>'started_at')::timestamptz <= now(), '미래 시각은 지금으로 맞춘다'); end $$;
reset role;
