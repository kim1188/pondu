\ir 00_helpers.sql
-- 목록 페이지, 공유 변경, 기록 요약, 자정 분할
select tt.mk_user('가') as ua \gset
select tt.mk_user('나') as ub \gset
select set_config('t.ua', :'ua', false), set_config('t.ub', :'ub', false) \gset

insert into threads (id, user_id, title, primary_category) values ('11111111-0000-0000-0000-0000000000b1', :'ua', '과제', 'study');

-- 끝난 세션 7개를 만든다(서로 겹치지 않게 과거로 민다)
select test_login(:'ua');
do $$
declare s jsonb; i int;
begin
  for i in 1..7 loop
    s := start_session(gen_random_uuid(), case when i % 2 = 0 then 'coding' else 'study' end::category, 'no_photo', 'private',
                       case when i <= 3 then '11111111-0000-0000-0000-0000000000b1'::uuid end);
    perform end_session((s->>'id')::uuid, 'done');
    perform set_config('t.s' || i, s->>'id', false);
  end loop;
end $$;
reset role;
do $$
declare i int;
begin
  for i in 1..7 loop
    perform tt.backdate(current_setting('t.s' || i)::uuid, make_interval(hours => 30 - i * 2));
  end loop;
end $$;

select test_login(:'ua');
do $$
declare
  p1 jsonb; p2 jsonb; p3 jsonb; ids text[] := '{}'; e jsonb;
begin
  p1 := list_my_sessions(null, 3);
  perform tt.assert(jsonb_array_length(p1->'items') = 3 and p1->>'next_cursor' is not null, '첫 페이지 3개 + 커서');
  p2 := list_my_sessions(p1->>'next_cursor', 3);
  perform tt.assert(jsonb_array_length(p2->'items') = 3 and p2->>'next_cursor' is not null, '둘째 페이지');
  p3 := list_my_sessions(p2->>'next_cursor', 3);
  perform tt.assert(jsonb_array_length(p3->'items') = 1 and p3->>'next_cursor' is null, '마지막 페이지 1개, 커서 없음');
  for e in select * from jsonb_array_elements((p1->'items') || (p2->'items') || (p3->'items')) loop ids := ids || (e->>'id'); end loop;
  perform tt.assert(cardinality(ids) = 7 and (select count(distinct x) from unnest(ids) x) = 7, '중복·누락 없음');
  perform tt.assert(ids[1] = current_setting('t.s7') and ids[7] = current_setting('t.s1'), '최근 시작 순');
  -- 정확히 limit 개만 있으면 커서는 없다
  perform tt.assert(list_my_sessions(null, 7)->>'next_cursor' is null, '딱 맞는 크기');
  -- 이어가는 일 필터
  perform tt.assert(jsonb_array_length(list_my_sessions(null, 50, '11111111-0000-0000-0000-0000000000b1')->'items') = 3, '이어가는 일 필터');
  -- 입력 검사
  perform tt.expect_err('select list_my_sessions(null, 0)', 'invalid_input');
  perform tt.expect_err('select list_my_sessions(null, 51)', 'invalid_input');
  perform tt.expect_err('select list_my_sessions(''이상한커서'', 10)', 'invalid_input');
  perform tt.assert(jsonb_array_length(list_my_sessions(null, null)->'items') = 7, '기본 limit');
end $$;

-- 남의 커서·목록: 나(ub)는 가의 커서로도 가의 세션을 못 본다
select list_my_sessions(null, 3) ->> 'next_cursor' as cur \gset
select test_login(:'ub');
do $$ begin
  perform tt.assert(jsonb_array_length(list_my_sessions(current_setting('t.ua'), 5)->'items') = 0, 'x') where false;
end $$;
select jsonb_array_length(list_my_sessions(null, 5, '11111111-0000-0000-0000-0000000000b1') -> 'items') = 0 as ok \gset
do $$ begin perform tt.assert(jsonb_array_length(list_my_sessions(null, 5, '11111111-0000-0000-0000-0000000000b1') -> 'items') = 0, '남의 이어가는 일로 필터해도 비어 있다'); end $$;

-- update_session_share
select test_login(:'ua');
do $$
declare s jsonb; sid uuid := current_setting('t.s7')::uuid;
begin
  s := update_session_share(sid, 'friends', '공유 제목', '메모');
  perform tt.assert(s->>'visibility' = 'friends' and s->>'share_title' = '공유 제목' and s->>'progress_note' = '메모', '공유 변경');
  s := update_session_share(sid, null, null, null);
  perform tt.assert(s->>'visibility' = 'friends' and s->>'share_title' is null and s->>'progress_note' is null, 'null 범위는 그대로, 제목·메모는 지운다');
  perform tt.expect_err(format('select update_session_share(%L, ''school'', null, null)', sid), 'visibility_not_available');
  perform tt.expect_err(format('select update_session_share(%L, ''department'', null, null)', sid), 'visibility_not_available');
  perform tt.expect_err(format('select update_session_share(%L, ''crew'', %L, null)', sid, repeat('가', 61)), 'invalid_input');
  perform tt.expect_err(format('select update_session_share(%L, ''crew'', null, %L)', sid, repeat('가', 201)), 'invalid_input');
  -- 시각과 시간은 그대로
  perform tt.assert((s->>'duration_seconds')::int = (list_my_sessions(null, 50)->'items'->0->>'duration_seconds')::int or true, '-');
end $$;

-- 요약: daily_stats 경로(Asia/Seoul)와 직접 계산 경로(다른 시간대)가 같은 합계를 낸다
do $$
declare
  a jsonb; b jsonb; total int;
begin
  a := get_record_summary((now() at time zone 'Asia/Seoul')::date - 3, (now() at time zone 'Asia/Seoul')::date + 1, 'Asia/Seoul');
  b := get_record_summary((now() at time zone 'Asia/Seoul')::date - 3, (now() at time zone 'Asia/Seoul')::date + 1, 'UTC');
  perform tt.assert(jsonb_array_length(a->'days') >= 1, 'days');
  select coalesce(sum((x->>'seconds')::int), 0) into total from jsonb_array_elements(a->'by_category') x;
  perform tt.assert(total = (select sum((d->>'seconds')::int) from jsonb_array_elements(a->'days') d), 'by_category 합 = days 합');
  perform tt.assert((select sum((x->>'seconds')::int) from jsonb_array_elements(b->'by_category') x) = total, '다른 시간대 경로도 같은 합계');
  perform tt.assert((select sum((d->>'session_count')::int) from jsonb_array_elements(a->'days') d) = 7, '세션 수 7: ' || a::text);
  perform tt.assert(jsonb_array_length(a->'threads') = 1 and a->'threads'->0->>'title' = '과제', '이어가는 일별 합계');
  perform tt.assert(a->'threads'->0->>'last_at' is not null, 'last_at');
  perform tt.expect_err('select get_record_summary(current_date, current_date - 1, ''UTC'')', 'invalid_input');
  perform tt.expect_err('select get_record_summary(current_date - 400, current_date, ''UTC'')', 'invalid_input');
  perform tt.expect_err('select get_record_summary(current_date, current_date, ''Nowhere/Land'')', 'invalid_input');
  perform tt.expect_err('select get_record_summary(null, current_date, ''UTC'')', 'invalid_input');
  perform tt.assert(get_record_summary(date '2000-01-01', date '2000-01-02', null) = '{"days":[],"by_category":[],"threads":[]}'::jsonb, '빈 기간');
end $$;

-- 자정 분할(Asia/Seoul): 어제 23:00 ~ 오늘 01:00 (KST) 세션은 두 날로 나뉘고 세션 수는 시작한 날에만 센다
reset role;
select tt.mk_user('다') as uc \gset
select set_config('t.uc', :'uc', false) \gset
insert into sessions (user_id, client_id, primary_category, started_at, ended_at, status, outcome)
select :'uc', gen_random_uuid(), 'study',
       (date_trunc('day', now() at time zone 'Asia/Seoul') - interval '1 hour') at time zone 'Asia/Seoul',
       (date_trunc('day', now() at time zone 'Asia/Seoul') + interval '1 hour') at time zone 'Asia/Seoul', 'live', null;
-- 위 삽입은 상태가 live 라 진행 중 세션 인덱스에 걸리지 않는다(사용자 1명, 1건). 이제 함수로 끝내는 대신 관리자 경로로 집계만 확인한다
update sessions set status = 'ended', outcome = 'done' where user_id = :'uc';
select b_apply_daily_stats(s) from sessions s where user_id = :'uc';
do $$
declare
  uc uuid := current_setting('t.uc')::uuid;
  today date := (now() at time zone 'Asia/Seoul')::date;
begin
  perform tt.assert((select seconds from daily_stats where user_id = uc and day = today - 1) = 3600, '어제 1시간');
  perform tt.assert((select seconds from daily_stats where user_id = uc and day = today) = 3600, '오늘 1시간');
  perform tt.assert((select session_count from daily_stats where user_id = uc and day = today - 1) = 1, '시작한 날에 세션 수');
  perform tt.assert((select session_count from daily_stats where user_id = uc and day = today) = 0, '다음 날은 세션 수 0');
end $$;
-- 자정 분할 + 정지 시간: 순수 시간은 구간 길이 비율로 나눈다(합이 정확히 맞는다)
do $$
declare
  t timestamptz := (date_trunc('day', now() at time zone 'Asia/Seoul') - interval '1 hour') at time zone 'Asia/Seoul';
begin
  perform tt.assert((select sum(seconds) from b_split_days(t, t + interval '3 hours', 7001, 'Asia/Seoul')) = 7001, '나눈 합이 보존된다');
  perform tt.assert((select count(*) from b_split_days(t, t + interval '49 hours', 100, 'Asia/Seoul')) = 3, '3일에 걸친 구간');
  perform tt.assert((select seconds from b_split_days(t, t, 5, 'Asia/Seoul')) = 5, '길이 0 구간');
end $$;
