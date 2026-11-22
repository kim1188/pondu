-- 예상 시간 보정(estimate_stats)과 assistant_context
select d_reset();
do $$
declare
  a uuid := '11111111-1111-1111-1111-111111111111';
  th jsonb; todo jsonb; i int; r jsonb; ids uuid[] := '{}'; k numeric; ctx jsonb;
  -- 실제/예상 비율 5개: 1.0, 1.0, 2.0, 2.0, 3.0 → 중앙값 2.0
  ratios numeric[] := array[1.0, 1.0, 2.0, 2.0, 3.0];
  t0 timestamptz := now() - interval '10 days';
begin
  perform test_login(a);
  th := create_thread('공부', 'study', null, null);

  -- 헬퍼: 예상 60분 할 일 + 세션 1개(ratio × 60분)를 만들고 완료한다. 한 번에 하나씩 단계별로 확인한다.
  for i in 1 .. 4 loop
    todo := create_todo('과제 ' || i, (th->>'id')::uuid, null, null, 60);
    execute 'reset role';
    insert into sessions (user_id, client_id, primary_category, status, started_at, ended_at, todo_id, thread_id)
    values (a, gen_random_uuid(), 'study', 'ended', t0 + i * interval '1 hour',
            t0 + i * interval '1 hour' + (ratios[i] * 3600 || ' seconds')::interval, (todo->>'id')::uuid, (th->>'id')::uuid);
    perform test_login(a);
    perform set_todo_status((todo->>'id')::uuid, 'done');
  end loop;
  -- 표본 4개: 아직 보정 없음
  r := get_today(null, null);
  assert r->'estimate_factors' = '{}'::jsonb, '표본 4개면 배수 없음: ' || (r->'estimate_factors')::text;

  -- 5번째: 경계. 이제 생긴다
  todo := create_todo('과제 5', (th->>'id')::uuid, null, null, 60);
  execute 'reset role';
  insert into sessions (user_id, client_id, primary_category, status, started_at, ended_at, todo_id)
  values (a, gen_random_uuid(), 'study', 'ended', t0 + interval '9 hours', t0 + interval '12 hours', (todo->>'id')::uuid);
  perform test_login(a);
  perform set_todo_status((todo->>'id')::uuid, 'done');
  r := get_today(null, null);
  assert (r->'estimate_factors'->>'study')::numeric = 2.0, '중앙값 2.0: ' || (r->'estimate_factors')::text;
  execute 'reset role';
  assert (select sample_count from estimate_stats where user_id = a and primary_category = 'study') = 5;
  perform test_login(a);

  -- 일시정지 시간은 실제 시간에서 뺀다: 120분 세션 중 60분 정지 → 60분 → 비율 1.0
  todo := create_todo('정지 포함', (th->>'id')::uuid, null, null, 60);
  execute 'reset role';
  insert into sessions (user_id, client_id, primary_category, status, started_at, ended_at, paused_seconds, todo_id)
  values (a, gen_random_uuid(), 'study', 'ended', t0 + interval '20 hours', t0 + interval '22 hours', 3600, (todo->>'id')::uuid);
  perform test_login(a);
  perform set_todo_status((todo->>'id')::uuid, 'done');
  -- 비율 1.0,1.0,1.0,2.0,2.0,3.0 → 중앙값 (1.0+2.0)/2 = 1.5
  r := get_today(null, null);
  assert (r->'estimate_factors'->>'study')::numeric = 1.5, '짝수 개 중앙값: ' || (r->'estimate_factors')::text;

  -- 보정에 안 쓰이는 것: 필요한 조건(예상 시간, 끝난 세션)이 없는 완료, needs_confirmation 세션
  todo := create_todo('예상 없음', (th->>'id')::uuid, null, null, null);
  execute 'reset role';
  insert into sessions (user_id, client_id, primary_category, status, started_at, ended_at, todo_id)
  values (a, gen_random_uuid(), 'study', 'ended', t0 + interval '30 hours', t0 + interval '35 hours', (todo->>'id')::uuid);
  perform test_login(a);
  perform set_todo_status((todo->>'id')::uuid, 'done');
  todo := create_todo('세션 없음', (th->>'id')::uuid, null, null, 30);
  perform set_todo_status((todo->>'id')::uuid, 'done');
  todo := create_todo('확인 필요 세션', (th->>'id')::uuid, null, null, 30);
  execute 'reset role';
  insert into sessions (user_id, client_id, primary_category, status, started_at, ended_at, todo_id)
  values (a, gen_random_uuid(), 'study', 'needs_confirmation', t0 + interval '40 hours', t0 + interval '50 hours', (todo->>'id')::uuid);
  perform test_login(a);
  perform set_todo_status((todo->>'id')::uuid, 'done');
  r := get_today(null, null);
  assert (r->'estimate_factors'->>'study')::numeric = 1.5, '조건 미달은 표본에서 제외: ' || (r->'estimate_factors')::text;
  execute 'reset role';
  assert (select sample_count from estimate_stats where user_id = a and primary_category = 'study') = 6;
  perform test_login(a);

  -- 모의: 같은 분야 비율이 모두 높으면 3.0 으로 자른다(coding)
  th := create_thread('개발', 'coding', null, null);
  for i in 1 .. 5 loop
    todo := create_todo('빌드 ' || i, (th->>'id')::uuid, null, null, 10);
    execute 'reset role';
    insert into sessions (user_id, client_id, primary_category, status, started_at, ended_at, todo_id)
    values (a, gen_random_uuid(), 'coding', 'ended', t0 + (i * 2) * interval '1 hour', t0 + (i * 2) * interval '1 hour' + interval '100 minutes', (todo->>'id')::uuid);
    perform test_login(a);
    perform set_todo_status((todo->>'id')::uuid, 'done');
  end loop;
  r := get_today(null, null);
  assert (r->'estimate_factors'->>'coding')::numeric = 3.0, '위쪽은 3.0 으로 자름: ' || (r->'estimate_factors')::text;
  assert (r->'estimate_factors'->>'study')::numeric = 1.5, '분야별로 따로';

  -- 모의: 모두 아주 빨리 끝내면 0.5 로 자른다(exercise)
  th := create_thread('운동', 'exercise', null, null);
  for i in 1 .. 5 loop
    todo := create_todo('러닝 ' || i, (th->>'id')::uuid, null, null, 120);
    execute 'reset role';
    insert into sessions (user_id, client_id, primary_category, status, started_at, ended_at, todo_id)
    values (a, gen_random_uuid(), 'exercise', 'ended', t0 + (i * 3) * interval '1 hour', t0 + (i * 3) * interval '1 hour' + interval '12 minutes', (todo->>'id')::uuid);
    perform test_login(a);
    perform set_todo_status((todo->>'id')::uuid, 'done');
  end loop;
  r := get_today(null, null);
  assert (r->'estimate_factors'->>'exercise')::numeric = 0.5, '아래쪽은 0.5 로 자름: ' || (r->'estimate_factors')::text;

end $$;

do $$
declare
  a uuid := '11111111-1111-1111-1111-111111111111';
  tid uuid; r jsonb; ctx jsonb; th uuid; todo jsonb; n int;
begin
  perform test_login(a);
  -- exercise 할 일 하나를 다시 열면 표본 4개 → 배수 제거
  execute 'reset role';
  select t.id into tid from todos t join sessions s on s.todo_id = t.id
   where t.user_id = a and s.primary_category = 'exercise' limit 1;
  perform test_login(a);
  perform set_todo_status(tid, 'open');
  r := get_today(null, null);
  assert not (r->'estimate_factors' ? 'exercise'), '표본이 5개 아래로 떨어지면 배수 제거';
  assert r->'estimate_factors' ? 'coding';
  -- 다시 완료하면 돌아온다
  perform set_todo_status(tid, 'done');
  assert (get_today(null, null)->'estimate_factors'->>'exercise')::numeric = 0.5;
  -- 할 일을 지워도 다시 계산한다
  perform delete_todo(tid);
  assert not (get_today(null, null)->'estimate_factors' ? 'exercise');

  -- 예상 시간이 바뀐 완료 할 일도 반영(coding: 10분 예상 → 100분 예상으로 고치면 비율 1.0)
  execute 'reset role';
  select t.id into tid from todos t join sessions s on s.todo_id = t.id
   where t.user_id = a and s.primary_category = 'coding' limit 1;
  perform test_login(a);
  perform update_todo(tid, '{"estimate_min":100}');
  -- 비율 10,10,10,10,1.0 → 중앙값 10 → 3.0 그대로(자름). 표본 5개 유지
  assert (get_today(null, null)->'estimate_factors'->>'coding')::numeric = 3.0;

  -- assistant_context: 서비스 키로만 호출 가능, 모양 확인
  perform d_expect($q$select assistant_context('11111111-1111-1111-1111-111111111111', now())$q$, 'privilege');
  execute 'reset role';
  execute 'set role service_role';
  ctx := assistant_context(a, now());
  assert ctx ? 'todos' and ctx ? 'blocks' and ctx ? 'estimate_factors', ctx::text;
  assert ctx->'estimate_factors' ? 'study';
  execute 'reset role';
  -- 열린 할 일은 한국 시간 due_date/due_time 으로 변환되고 보정 분(estimate_min_calibrated)이 붙는다
  insert into threads (id, user_id, title, primary_category) values ('d1000000-0000-0000-0000-0000000000a1', a, '보정확인', 'study');
  insert into todos (id, user_id, thread_id, title, due_at, due_has_time, estimate_min)
  values ('d1000000-0000-0000-0000-0000000000b1', a, 'd1000000-0000-0000-0000-0000000000a1', '시각 있음', '2030-05-01T05:30:00Z', true, 40),
         ('d1000000-0000-0000-0000-0000000000b2', a, null, '날짜만', '2030-05-01T14:59:00Z', false, null);
  insert into plan_blocks (user_id, todo_id, start_at, end_at, locked)
  values (a, 'd1000000-0000-0000-0000-0000000000b1', now() + interval '1 day', now() + interval '1 day 1 hour', true),
         (a, 'd1000000-0000-0000-0000-0000000000b1', now() - interval '5 days', now() - interval '5 days' + interval '1 hour', false);
  execute 'set role service_role';
  ctx := assistant_context(a, now());
  assert (select e->>'due_date' || ' ' || coalesce(e->>'due_time', '-') from jsonb_array_elements(ctx->'todos') e where e->>'title' = '시각 있음') = '2030-05-01 14:30';
  assert (select e->>'due_date' || ' ' || coalesce(e->>'due_time', '-') from jsonb_array_elements(ctx->'todos') e where e->>'title' = '날짜만') = '2030-05-01 -';
  assert (select (e->>'estimate_min_calibrated')::int from jsonb_array_elements(ctx->'todos') e where e->>'title' = '시각 있음') = 60, '40분 × 1.5';
  assert jsonb_array_length(ctx->'blocks') = 1, '지난 블록 제외';
  assert (ctx->'blocks'->0->>'locked')::boolean and ctx->'blocks'->0->>'start' like '%+09:00';
  execute 'reset role';
end $$;
