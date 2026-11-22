\ir 00_helpers.sql
-- 같이 하기: can_view_session 으로 확인하고, 진행 중이 아니면 거절
select tt_b.mk_user('가') as ua \gset
select tt_b.mk_user('나') as ub \gset
select tt_b.mk_user('다') as uc \gset
select set_config('t.ua', :'ua', false), set_config('t.ub', :'ub', false), set_config('t.uc', :'uc', false) \gset
select tt_b.befriend(:'ua', :'ub');

select test_login(:'ua');
select start_session(gen_random_uuid(), 'study', 'no_photo', 'friends') ->> 'id' as sa \gset
select set_config('t.sa', :'sa', false) \gset

-- 친구 아님(다) → 거절
select test_login(:'uc');
select tt_b.expect_err(format('select start_session(%L, ''study'', ''no_photo'', ''private'', null, null, null, null, null, %L)', gen_random_uuid(), :'sa'), 'join_not_allowed');
select tt_b.expect_err(format('select start_session(%L, ''study'', ''no_photo'', ''private'', null, null, null, null, null, %L)', gen_random_uuid(), gen_random_uuid()), 'join_not_allowed');
do $$ begin perform tt_b.assert(get_my_live_session() is null, '거절되면 세션이 생기지 않는다'); end $$;

-- 친구(나) → 허용, 상대 세션에는 영향 없음, 알림 한 건
select test_login(:'ub');
select start_session(gen_random_uuid(), 'coding', 'no_photo', 'friends', null, null, null, null, null, :'sa') ->> 'joined_session_id' as j \gset
select (:'j' = :'sa') as ok \gset
do $$ begin perform tt_b.assert(get_my_live_session()->>'joined_session_id' = current_setting('t.sa'), '연결됨'); end $$;
select end_session((get_my_live_session()->>'id')::uuid, 'done');
reset role;
do $$
declare ua uuid := current_setting('t.ua')::uuid;
begin
  perform tt_b.assert((select count(*) from notification_outbox where user_id = ua and kind = 'joined') = 1, 'joined 알림');
  perform tt_b.assert((select status from sessions where id = current_setting('t.sa')::uuid) = 'live', '상대 세션은 그대로');
end $$;

-- 자기 자신의 세션, 끝난 세션은 거절
select test_login(:'ua');
select pause_session(:'sa');
select resume_session(:'sa');
select tt_b.expect_err(format('select start_session(%L, ''study'', ''no_photo'', ''private'', null, null, null, null, null, %L)', gen_random_uuid(), :'sa'), 'session_already_active');
select end_session(:'sa', 'done');
select test_login(:'ub');
select tt_b.expect_err(format('select start_session(%L, ''study'', ''no_photo'', ''private'', null, null, null, null, null, %L)', gen_random_uuid(), :'sa'), 'join_not_allowed');
-- 비공개 세션은 친구라도 거절
select test_login(:'ua');
select start_session(gen_random_uuid(), 'study', 'no_photo', 'private') ->> 'id' as sp \gset
select test_login(:'ub');
select tt_b.expect_err(format('select start_session(%L, ''study'', ''no_photo'', ''private'', null, null, null, null, null, %L)', gen_random_uuid(), :'sp'), 'join_not_allowed');
-- 자기 세션에 합류는 불가
select test_login(:'ua');
select end_session(:'sp', 'done');
select start_session(gen_random_uuid(), 'study', 'no_photo', 'friends') ->> 'id' as sq \gset
select end_session(:'sq', 'done');
select start_session(gen_random_uuid(), 'study', 'no_photo', 'friends') ->> 'id' as sr \gset
select tt_b.expect_err(format('select start_session(%L, ''study'', ''no_photo'', ''private'', null, null, null, null, null, %L)', gen_random_uuid(), :'sr'), 'session_already_active');
reset role;

-- 놓친 예정 시간: 끝 시각이 지난 planned 블록은 sweep 이 missed 로, 세션이 연결된 블록은 그대로
select tt_b.mk_user('라') as ud \gset
insert into plan_blocks (id, user_id, start_at, end_at) values
  ('33333333-0000-0000-0000-0000000000c1', :'ud', now() - interval '3 hours', now() - interval '2 hours'),
  ('33333333-0000-0000-0000-0000000000c2', :'ud', now() - interval '3 hours', now() - interval '2 hours'),
  ('33333333-0000-0000-0000-0000000000c3', :'ud', now() + interval '1 hour', now() + interval '2 hours');
select test_login(:'ud');
select start_session(gen_random_uuid(), 'study', 'no_photo', 'private', null, null, '33333333-0000-0000-0000-0000000000c2') ->> 'id' as sd \gset
reset role;
select sweep_stale_sessions();
do $$ begin
  perform tt_b.assert((select status from plan_blocks where id = '33333333-0000-0000-0000-0000000000c1') = 'missed', '지난 planned → missed');
  perform tt_b.assert((select status from plan_blocks where id = '33333333-0000-0000-0000-0000000000c2') = 'started', '세션을 시작하면 블록은 started(missed 로 바뀌지 않는다)');
  perform tt_b.assert((select status from plan_blocks where id = '33333333-0000-0000-0000-0000000000c3') = 'planned', '앞으로의 블록은 그대로');
end $$;
select test_login(:'ud');
select end_session(:'sd', 'done');
reset role;
do $$ begin perform tt_b.assert((select status from plan_blocks where id = '33333333-0000-0000-0000-0000000000c2') = 'started', '종료 후에도 started'); end $$;
-- joined 알림 payload
do $$ begin perform tt_b.assert((select payload ? 'session_id' and payload ? 'user_id' from notification_outbox where kind = 'joined' and user_id = current_setting('t.ua')::uuid limit 1), 'joined payload'); end $$;
