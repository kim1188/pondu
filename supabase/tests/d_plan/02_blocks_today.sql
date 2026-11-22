-- 예정 시간 생성/수정/삭제, get_today 구성
select d_reset();
do $$
declare
  a uuid := '11111111-1111-1111-1111-111111111111';
  th jsonb; td jsonb; td2 jsonb; tdone jsonb; blk jsonb; r jsonb; x jsonb;
  v_day date := '2030-03-05';
  s0 timestamptz := '2030-03-05 00:00:00+09';
begin
  perform test_login(a);
  th := create_thread('앱', 'coding', null, null);
  td := create_todo('로그인 수정', (th->>'id')::uuid, null, null, 30);

  -- 블록 생성: 할 일에서 이어가는 일을 물려받음
  blk := create_plan_block((td->>'id')::uuid, null, s0 + interval '15 hours', s0 + interval '16 hours', null);
  assert blk->>'thread_id' = th->>'id' and not (blk->>'locked')::boolean and blk->>'origin' = 'user' and blk->>'status' = 'planned';
  assert blk->>'start_at' = '2030-03-05T06:00:00.000000Z', blk->>'start_at';
  perform d_expect($q$select create_plan_block(null, null, now(), now(), false)$q$, 'invalid_input');
  perform d_expect($q$select create_plan_block(null, null, now() + interval '1 hour', now(), false)$q$, 'invalid_input');
  perform d_expect($q$select create_plan_block(null, null, null, now(), false)$q$, 'invalid_input');
  perform d_expect($q$select create_plan_block(gen_random_uuid(), null, now(), now() + interval '1 hour', false)$q$, 'not_found');
  perform d_expect($q$select create_plan_block(null, gen_random_uuid(), now(), now() + interval '1 hour', false)$q$, 'not_found');

  -- 수정
  r := update_plan_block((blk->>'id')::uuid, '{"locked":true,"end_at":"2030-03-05T17:00:00+09:00"}');
  assert (r->>'locked')::boolean and r->>'end_at' = '2030-03-05T08:00:00.000000Z', r->>'end_at';
  perform d_expect(format($q$select update_plan_block(%L, '{"user_id":"x"}')$q$, blk->>'id'), 'invalid_input');
  perform d_expect(format($q$select update_plan_block(%L, '{"origin":"user"}')$q$, blk->>'id'), 'invalid_input');
  perform d_expect(format($q$select update_plan_block(%L, '{"status":"started"}')$q$, blk->>'id'), 'invalid_input');
  perform d_expect(format($q$select update_plan_block(%L, '{"end_at":"2030-03-04T00:00:00Z"}')$q$, blk->>'id'), 'invalid_input');
  perform d_expect(format($q$select update_plan_block(%L, '{"locked":"yes"}')$q$, blk->>'id'), 'invalid_input');
  perform d_expect($q$select update_plan_block(gen_random_uuid(), '{"locked":true}')$q$, 'not_found');

  -- get_today 구성
  td2 := create_todo('내일 할 일', null, '2030-03-06T00:00:00Z', false, null);
  tdone := create_todo('오늘 끝낸 일', null, null, null, null);
  perform set_todo_status((tdone->>'id')::uuid, 'done');
  -- 사용자 A 의 다른 날 블록과 취소된 블록
  perform create_plan_block((td2->>'id')::uuid, null, s0 + interval '3 days', s0 + interval '3 days 1 hour', false);
  x := create_plan_block((td->>'id')::uuid, null, s0 + interval '17 hours', s0 + interval '18 hours', false);
  perform update_plan_block((x->>'id')::uuid, '{"status":"cancelled"}');
  -- 자정을 걸치는 블록(전날 23:30~다음 날 00:30)은 그날과 겹침
  perform create_plan_block(null, null, s0 - interval '30 minutes', s0 + interval '30 minutes', false);
  -- 오래전에 끝낸 일
  execute 'reset role';
  insert into todos (user_id, title, status, completed_at, completion_source)
  values (a, '지난주에 끝낸 일', 'done', now() - interval '40 days', 'user_action');
  perform test_login(a);

  -- 끝낸 일은 지금 시각 기준 '그날'(p_day 가 오늘일 때)에만 나온다
  r := get_today((now() at time zone 'Asia/Seoul')::date, 'Asia/Seoul');
  assert jsonb_array_length(r->'todos') = 3, 'open 2 + 오늘 끝낸 1: ' || jsonb_array_length(r->'todos');
  assert exists (select 1 from jsonb_array_elements(r->'todos') e where e->>'title' = '오늘 끝낸 일');
  assert not exists (select 1 from jsonb_array_elements(r->'todos') e where e->>'title' = '지난주에 끝낸 일');
  assert jsonb_typeof(r->'estimate_factors') = 'object' and r->'estimate_factors' = '{}'::jsonb;
  assert r->'live_session' = 'null'::jsonb, 'live 없음';
  assert jsonb_array_length(r->'threads') = 1;

  r := get_today(v_day, 'Asia/Seoul');
  assert jsonb_array_length(r->'blocks') = 2, '그날과 겹치는 것(취소·다른 날 제외, 자정 걸친 것 포함): ' || jsonb_array_length(r->'blocks');
  assert not exists (select 1 from jsonb_array_elements(r->'blocks') e where e->>'status' = 'cancelled');
  -- 열린 일은 날짜와 상관없이 전부, 끝낸 일은 그 날짜가 아니면 빠짐
  assert jsonb_array_length(r->'todos') = 2, '그날이 아니면 끝낸 일 제외: ' || jsonb_array_length(r->'todos');
  r := get_today(v_day + 3, 'Asia/Seoul');
  assert jsonb_array_length(r->'blocks') = 1;
  r := get_today(v_day - 10, 'Asia/Seoul');
  assert jsonb_array_length(r->'blocks') = 0;

  -- 진행 중 세션
  execute 'reset role';
  insert into sessions (user_id, client_id, primary_category, status, todo_id)
  values (a, gen_random_uuid(), 'coding', 'live', (td->>'id')::uuid);
  perform test_login(a);
  r := get_today(v_day, 'Asia/Seoul');
  assert r->'live_session'->>'status' = 'live' and r->'live_session'->>'todo_id' = td->>'id';

  -- 잘못된 시간대
  perform d_expect($q$select get_today('2030-03-05', 'Mars/Olympus')$q$, 'invalid_input');
  -- 기본값
  r := get_today(null, null);
  assert r ? 'todos';

  -- 삭제
  perform delete_plan_block((blk->>'id')::uuid);
  perform d_expect(format($q$select delete_plan_block(%L)$q$, blk->>'id'), 'not_found');
  -- 할 일을 지우면 그 일의 예정 시간도 함께 사라진다
  x := create_plan_block((td2->>'id')::uuid, null, s0 + interval '9 hours', s0 + interval '10 hours', false);
  perform delete_todo((td2->>'id')::uuid);
  perform d_expect(format($q$select delete_plan_block(%L)$q$, x->>'id'), 'not_found');
  execute 'reset role';
end $$;
