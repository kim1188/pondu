-- apply_proposal: 일부 적용, 재적용 거절, reschedule 대체, new:N 연결, user_statement 완료, 겹침·소유 검증
select d_reset();
do $$
declare
  a uuid := '11111111-1111-1111-1111-111111111111';
  b uuid := '22222222-2222-2222-2222-222222222222';
  p uuid; r jsonb; t1 jsonb; t2 jsonb; tb jsonb; lk jsonb; old1 jsonb; old2 jsonb; n int; x jsonb;
  d text := to_char((now() at time zone 'Asia/Seoul')::date + 2, 'YYYY-MM-DD');
  e0 timestamptz;
begin
  perform test_login(a);
  t1 := create_todo('기존 일 1', null, null, null, 60);
  t2 := create_todo('기존 일 2', null, null, null, null);
  perform test_login(b);
  tb := create_todo('B 의 일', null, null, null, null);
  perform test_login(a);

  -- 제안 저장(비서 서버 함수의 일을 관리자 권한으로 흉내)
  execute 'reset role';
  insert into assistant_proposals (user_id, kind, input, proposal) values (a, 'capture', '{"kind":"capture"}',
    jsonb_build_object(
      'todos', jsonb_build_array(
        jsonb_build_object('title', '새 일 0', 'due_date', d, 'due_time', '18:30', 'estimate_min', 45, 'category', 'study'),
        jsonb_build_object('title', '새 일 1', 'due_date', d, 'due_time', null, 'estimate_min', null, 'category', null),
        jsonb_build_object('title', '새 일 2', 'due_date', null, 'due_time', null, 'estimate_min', null, 'category', null)),
      'blocks', jsonb_build_array(
        jsonb_build_object('todo_ref', 'new:0', 'start', d || 'T10:00:00+09:00', 'end', d || 'T11:00:00+09:00'),
        jsonb_build_object('todo_ref', t1->>'id', 'start', d || 'T13:00:00+09:00', 'end', d || 'T14:00:00+09:00'),
        jsonb_build_object('todo_ref', 'new:1', 'start', d || 'T15:00:00+09:00', 'end', d || 'T16:00:00+09:00')),
      'done_todo_ids', jsonb_build_array(t2->>'id'), 'unscheduled', '[]'::jsonb, 'questions', '[]'::jsonb, 'message', 'x'))
  returning id into p;
  perform test_login(a);

  -- 일부만 적용: 새 일 0, 2 와 블록 0, 1. 완료 처리는 하지 않음
  r := apply_proposal(p, array[0, 2], array[0, 1], false);
  assert jsonb_array_length(r->'todos') = 2 and jsonb_array_length(r->'blocks') = 2, r::text;
  -- 날짜+시각(한국 시간) 변환: d 18:30 KST == d 09:30 UTC
  assert r->'todos'->0->>'title' = '새 일 0' and r->'todos'->0->>'due_at' = d || 'T09:30:00.000000Z', r->'todos'->0->>'due_at';
  assert (r->'todos'->0->>'due_has_time')::boolean and (r->'todos'->0->>'estimate_min')::int = 45;
  assert r->'todos'->0->>'source' = 'assistant' and r->'todos'->0->>'status' = 'open';
  assert r->'todos'->1->>'due_at' is null and not (r->'todos'->1->>'due_has_time')::boolean;
  -- new:0 은 방금 만든 할 일에, 기존 id 는 그대로 연결, 만든 블록은 origin = assistant
  assert r->'blocks'->0->>'todo_id' = r->'todos'->0->>'id', 'new:N 연결';
  assert r->'blocks'->1->>'todo_id' = t1->>'id';
  assert r->'blocks'->0->>'origin' = 'assistant' and not (r->'blocks'->0->>'locked')::boolean;
  assert r->'blocks'->0->>'start_at' = d || 'T01:00:00.000000Z', r->'blocks'->0->>'start_at';
  -- 완료는 적용 안 함
  execute 'reset role';
  assert (select status from todos where id = (t2->>'id')::uuid) = 'open', 'p_apply_done=false 면 완료 처리 안 함';
  perform test_login(a);
  execute 'reset role';
  assert (select count(*) from todos where title = '새 일 1') = 0, '고르지 않은 할 일은 만들지 않음';
  perform test_login(a);

  -- 재적용 거절
  perform d_expect(format($q$select apply_proposal(%L, null, null, true)$q$, p), 'proposal_already_applied');
  execute 'reset role';
  assert (select count(*) from todos where title = '새 일 0') = 1;
  perform test_login(a);
  -- 없는 제안
  perform d_expect($q$select apply_proposal(gen_random_uuid(), null, null, true)$q$, 'proposal_not_found');

  -- 전부 적용 + 사용자 진술 완료
  execute 'reset role';
  insert into assistant_proposals (user_id, kind, input, proposal) values (a, 'capture', '{"kind":"capture"}',
    jsonb_build_object('todos', '[]'::jsonb, 'blocks', '[]'::jsonb, 'done_todo_ids', jsonb_build_array(t2->>'id'),
      'unscheduled', '[]'::jsonb, 'questions', '[]'::jsonb, 'message', 'x')) returning id into p;
  perform test_login(a);
  r := apply_proposal(p, null, null, true);
  assert jsonb_array_length(r->'todos') = 1 and r->'todos'->0->>'status' = 'done'
     and r->'todos'->0->>'completion_source' = 'user_statement' and r->'todos'->0->>'completed_at' is not null, r::text;
  execute 'reset role';
  assert (select completion_source from todos where id = (t2->>'id')::uuid) = 'user_statement';
  perform test_login(a);

  -- 인덱스 범위·형식
  execute 'reset role';
  insert into assistant_proposals (user_id, kind, input, proposal) values (a, 'capture', '{}',
    '{"todos":[{"title":"가","due_date":null,"due_time":null,"estimate_min":null,"category":null}],"blocks":[],"done_todo_ids":[]}') returning id into p;
  perform test_login(a);
  perform d_expect(format($q$select apply_proposal(%L, array[5], null, false)$q$, p), 'invalid_input');
  perform d_expect(format($q$select apply_proposal(%L, array[-1], null, false)$q$, p), 'invalid_input');
  perform d_expect(format($q$select apply_proposal(%L, null, array[0], false)$q$, p), 'invalid_input');
  -- 오류가 나도 제안은 적용되지 않은 채 남는다
  execute 'reset role';
  assert (select applied_at from assistant_proposals where id = p) is null;
  perform test_login(a);
  r := apply_proposal(p, array[]::int[], array[]::int[], false);
  assert jsonb_array_length(r->'todos') = 0 and jsonb_array_length(r->'blocks') = 0;
  execute 'reset role';
  assert (select applied_at from assistant_proposals where id = p) is not null, '아무것도 안 골라도 적용됨으로 표시';
  perform test_login(a);

  -- 겹침: 잠긴 블록과 겹치면 거절
  lk := create_plan_block(null, null, (d || 'T09:00:00+09:00')::timestamptz, (d || 'T10:30:00+09:00')::timestamptz, true);
  execute 'reset role';
  insert into assistant_proposals (user_id, kind, input, proposal) values (a, 'plan_day', '{}',
    jsonb_build_object('todos', '[]'::jsonb, 'done_todo_ids', '[]'::jsonb,
      'blocks', jsonb_build_array(jsonb_build_object('todo_ref', t1->>'id', 'start', d || 'T10:00:00+09:00', 'end', d || 'T11:00:00+09:00'))))
  returning id into p;
  perform test_login(a);
  perform d_expect(format($q$select apply_proposal(%L, null, null, false)$q$, p), 'invalid_input');
  execute 'reset role';
  assert (select count(*) from plan_blocks where user_id = a and origin = 'assistant') = 2, '거절된 적용은 아무것도 남기지 않음';
  perform test_login(a);

  -- 겹침: 제안의 블록끼리 겹치면 거절
  execute 'reset role';
  insert into assistant_proposals (user_id, kind, input, proposal) values (a, 'plan_day', '{}',
    jsonb_build_object('todos', '[]'::jsonb, 'done_todo_ids', '[]'::jsonb,
      'blocks', jsonb_build_array(
        jsonb_build_object('todo_ref', t1->>'id', 'start', d || 'T14:00:00+09:00', 'end', d || 'T15:00:00+09:00'),
        jsonb_build_object('todo_ref', t1->>'id', 'start', d || 'T14:30:00+09:00', 'end', d || 'T15:30:00+09:00'))))
  returning id into p;
  perform test_login(a);
  perform d_expect(format($q$select apply_proposal(%L, null, null, false)$q$, p), 'invalid_input');
  -- 겹치는 한쪽만 고르면 적용 가능
  r := apply_proposal(p, null, array[1], false);
  assert jsonb_array_length(r->'blocks') = 1;
  -- 맞닿는 것(끝 = 시작)은 겹침이 아님
  execute 'reset role';
  insert into assistant_proposals (user_id, kind, input, proposal) values (a, 'plan_day', '{}',
    jsonb_build_object('todos', '[]'::jsonb, 'done_todo_ids', '[]'::jsonb,
      'blocks', jsonb_build_array(
        jsonb_build_object('todo_ref', t1->>'id', 'start', d || 'T16:00:00+09:00', 'end', d || 'T17:00:00+09:00'),
        jsonb_build_object('todo_ref', t1->>'id', 'start', d || 'T17:00:00+09:00', 'end', d || 'T18:00:00+09:00'))))
  returning id into p;
  perform test_login(a);
  r := apply_proposal(p, null, null, false);
  assert jsonb_array_length(r->'blocks') = 2;

  -- 남의 할 일을 가리키는 제안은 거절(제안 자체는 본인 것)
  execute 'reset role';
  insert into assistant_proposals (user_id, kind, input, proposal) values (a, 'plan_day', '{}',
    jsonb_build_object('todos', '[]'::jsonb, 'done_todo_ids', jsonb_build_array(tb->>'id'),
      'blocks', jsonb_build_array(jsonb_build_object('todo_ref', tb->>'id', 'start', d || 'T20:00:00+09:00', 'end', d || 'T21:00:00+09:00'))))
  returning id into p;
  perform test_login(a);
  perform d_expect(format($q$select apply_proposal(%L, null, null, true)$q$, p), 'not_found');
  -- 블록을 빼고 완료만 적용해도 남의 할 일은 완료되지 않는다
  r := apply_proposal(p, null, array[]::int[], true);
  assert jsonb_array_length(r->'todos') = 0;
  execute 'reset role';
  assert (select status from todos where id = (tb->>'id')::uuid) = 'open', '남의 할 일은 완료 처리되지 않음';
  perform test_login(a);

  -- 이미 끝난 할 일에 블록을 잡는 제안은 거절, 형식이 이상한 todo_ref 도 거절
  execute 'reset role';
  insert into assistant_proposals (user_id, kind, input, proposal) values (a, 'plan_day', '{}',
    jsonb_build_object('todos', '[]'::jsonb, 'done_todo_ids', '[]'::jsonb,
      'blocks', jsonb_build_array(jsonb_build_object('todo_ref', t2->>'id', 'start', d || 'T20:00:00+09:00', 'end', d || 'T21:00:00+09:00'))))
  returning id into p;
  perform test_login(a);
  perform d_expect(format($q$select apply_proposal(%L, null, null, false)$q$, p), 'invalid_input');
  execute 'reset role';
  insert into assistant_proposals (user_id, kind, input, proposal) values (a, 'plan_day', '{}',
    jsonb_build_object('todos', '[]'::jsonb, 'done_todo_ids', '[]'::jsonb,
      'blocks', jsonb_build_array(jsonb_build_object('todo_ref', 'new:7', 'start', d || 'T20:00:00+09:00', 'end', d || 'T21:00:00+09:00'))))
  returning id into p;
  perform test_login(a);
  perform d_expect(format($q$select apply_proposal(%L, null, null, false)$q$, p), 'invalid_input');
  -- new:N 을 가리키는데 그 할 일을 고르지 않았으면 거절
  execute 'reset role';
  insert into assistant_proposals (user_id, kind, input, proposal) values (a, 'plan_day', '{}',
    jsonb_build_object('todos', jsonb_build_array(jsonb_build_object('title', '가', 'due_date', null, 'due_time', null, 'estimate_min', null, 'category', null)),
      'done_todo_ids', '[]'::jsonb,
      'blocks', jsonb_build_array(jsonb_build_object('todo_ref', 'new:0', 'start', d || 'T20:00:00+09:00', 'end', d || 'T21:00:00+09:00'))))
  returning id into p;
  perform test_login(a);
  perform d_expect(format($q$select apply_proposal(%L, array[]::int[], null, false)$q$, p), 'invalid_input');
  r := apply_proposal(p, null, null, false);
  assert r->'blocks'->0->>'todo_id' = r->'todos'->0->>'id';

  -- reschedule: 잠기지 않은 앞으로의 planned 블록은 moved, 잠긴 것·지난 것은 그대로
  execute 'reset role';
  delete from plan_blocks where user_id = a;
  delete from assistant_proposals where user_id = a;
  insert into plan_blocks (user_id, todo_id, start_at, end_at, locked, status) values
    (a, (t1->>'id')::uuid, now() + interval '1 day', now() + interval '1 day 1 hour', false, 'planned'),
    (a, (t1->>'id')::uuid, now() + interval '2 days', now() + interval '2 days 1 hour', false, 'planned'),
    (a, (t1->>'id')::uuid, now() + interval '3 days', now() + interval '3 days 1 hour', true, 'planned'),
    (a, (t1->>'id')::uuid, now() - interval '3 hours', now() - interval '2 hours', false, 'planned'),
    (a, (t1->>'id')::uuid, now() + interval '4 days', now() + interval '4 days 1 hour', false, 'cancelled');
  e0 := date_trunc('hour', now()) + interval '5 days';
  insert into assistant_proposals (user_id, kind, input, proposal) values (a, 'reschedule', '{}',
    jsonb_build_object('todos', '[]'::jsonb, 'done_todo_ids', '[]'::jsonb,
      'blocks', jsonb_build_array(jsonb_build_object('todo_ref', t1->>'id',
         'start', to_char(e0 at time zone 'Asia/Seoul', 'YYYY-MM-DD"T"HH24:MI:SS') || '+09:00',
         'end', to_char((e0 + interval '1 hour') at time zone 'Asia/Seoul', 'YYYY-MM-DD"T"HH24:MI:SS') || '+09:00'))))
  returning id into p;
  perform test_login(a);
  r := apply_proposal(p, null, array[0], false);
  assert jsonb_array_length(r->'blocks') = 1;
  execute 'reset role';
  assert (select count(*) from plan_blocks where user_id = a and status = 'moved') = 2, '앞으로의 잠기지 않은 planned 두 개가 moved';
  assert (select count(*) from plan_blocks where user_id = a and locked and status = 'planned') = 1, '잠긴 블록 유지';
  assert (select count(*) from plan_blocks where user_id = a and status = 'planned' and start_at < now()) = 1, '지난 블록 유지';
  assert (select count(*) from plan_blocks where user_id = a and status = 'planned' and origin = 'assistant') = 1;
  assert (select count(*) from plan_blocks where user_id = a and status = 'cancelled') = 1, '취소된 블록은 건드리지 않음';

  -- reschedule 인데 블록을 하나도 안 고르면 기존 계획을 옮기지 않는다
  insert into assistant_proposals (user_id, kind, input, proposal) values (a, 'reschedule', '{}',
    jsonb_build_object('todos', '[]'::jsonb, 'done_todo_ids', '[]'::jsonb, 'blocks', '[]'::jsonb)) returning id into p;
  perform test_login(a);
  perform apply_proposal(p, null, array[]::int[], false);
  execute 'reset role';
  assert (select count(*) from plan_blocks where user_id = a and status = 'moved') = 2;

  -- 잠긴 블록과 겹치는 reschedule 제안은 거절
  insert into assistant_proposals (user_id, kind, input, proposal) values (a, 'reschedule', '{}',
    jsonb_build_object('todos', '[]'::jsonb, 'done_todo_ids', '[]'::jsonb,
      'blocks', jsonb_build_array(jsonb_build_object('todo_ref', t1->>'id',
         'start', to_char((now() + interval '3 days 10 minutes') at time zone 'Asia/Seoul', 'YYYY-MM-DD"T"HH24:MI:SS') || '+09:00',
         'end', to_char((now() + interval '3 days 50 minutes') at time zone 'Asia/Seoul', 'YYYY-MM-DD"T"HH24:MI:SS') || '+09:00'))))
  returning id into p;
  perform test_login(a);
  perform d_expect(format($q$select apply_proposal(%L, null, array[0], false)$q$, p), 'invalid_input');
  execute 'reset role';
end $$;
