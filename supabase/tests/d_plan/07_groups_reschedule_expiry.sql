-- 이어가는 일의 기본 크루, import_todos의 due_date/due_time, reschedule 일부 적용 거절, 만료된 제안.
-- 사용자는 이 파일 안에서 무작위 id로 만든다.
do $$
declare
  sc uuid := gen_random_uuid(); a uuid := gen_random_uuid(); b uuid := gen_random_uuid();
  g_a uuid := gen_random_uuid(); g_b uuid := gen_random_uuid();
  th jsonb; r jsonb; p uuid; t1 jsonb; d text := to_char((now() at time zone 'Asia/Seoul')::date + 3, 'YYYY-MM-DD');
  mk text;
begin
  insert into schools (id, name, email_domains) values (sc, 'D7테스트대', '{korea.ac.kr}');
  insert into auth.users (id, email) values (a, a || '@korea.ac.kr'), (b, b || '@korea.ac.kr');
  insert into profiles (id, school_id, handle, display_name) values
    (a, sc, 'd7a_' || substr(a::text, 1, 8), 'A'), (b, sc, 'd7b_' || substr(b::text, 1, 8), 'B');
  insert into groups (id, school_id, name, owner_id, invite_code) values
    (g_a, sc, 'ga', a, 'D7A' || replace(g_a::text, '-', '')), (g_b, sc, 'gb', b, 'D7B' || replace(g_b::text, '-', ''));
  insert into group_members (group_id, user_id, role) values (g_a, a, 'owner'), (g_b, b, 'owner');

  -- ── 이어가는 일의 기본 크루 ──
  perform test_login(a);
  th := create_thread('크루 일', 'study', null, 'crew', g_a);
  assert (th ->> 'default_group_id')::uuid = g_a, 'create_thread가 default_group_id를 받음';
  assert create_thread('그냥 일', 'study', null, 'private') -> 'default_group_id' = 'null'::jsonb, '기본은 null';
  perform d_expect(format($q$select create_thread('x', 'study', null, 'crew', %L)$q$, g_b), 'not_found');      -- 남의 크루
  perform d_expect(format($q$select create_thread('x', 'study', null, 'crew', %L)$q$, gen_random_uuid()), 'not_found');
  r := update_thread((th ->> 'id')::uuid, '{"default_group_id":null}');
  assert r -> 'default_group_id' = 'null'::jsonb, 'patch로 지움';
  r := update_thread((th ->> 'id')::uuid, format('{"default_group_id":"%s"}', g_a)::jsonb);
  assert (r ->> 'default_group_id')::uuid = g_a, 'patch로 바꿈';
  perform d_expect(format($q$select update_thread(%L, '{"default_group_id":"%s"}')$q$, th ->> 'id', g_b), 'not_found');
  perform d_expect(format($q$select update_thread(%L, '{"default_group_id":123}')$q$, th ->> 'id'), 'invalid_input');
  assert (select (x ->> 'default_group_id')::uuid from jsonb_array_elements(list_threads()) x where x ->> 'id' = th ->> 'id') = g_a, 'list_threads에도 있음';
  -- 다른 사람은 내 이어가는 일을 못 고친다
  perform test_login(b);
  perform d_expect(format($q$select update_thread(%L, '{"default_group_id":"%s"}')$q$, th ->> 'id', g_b), 'not_found');

  -- ── import_todos: due_date + due_time (한국 시간) ──
  perform test_login(a);
  r := import_todos('text', jsonb_build_array(
    jsonb_build_object('title', '시각 있음', 'due_date', d, 'due_time', '18:30', 'source_ref', 'k1'),
    jsonb_build_object('title', '시각 없음', 'due_date', d, 'due_time', null, 'source_ref', 'k2'),
    jsonb_build_object('title', '기한 없음', 'due_date', null, 'due_time', null, 'source_ref', 'k3'),
    jsonb_build_object('title', 'due_at 방식', 'due_at', d || 'T01:00:00Z', 'due_has_time', true, 'source_ref', 'k4')));
  assert jsonb_array_length(r -> 'created') = 4, r::text;
  assert r -> 'created' -> 0 ->> 'due_at' = d || 'T09:30:00.000000Z' and (r -> 'created' -> 0 ->> 'due_has_time')::boolean, 'd 18:30 KST = 09:30 UTC';
  assert r -> 'created' -> 1 ->> 'due_at' = d || 'T14:59:00.000000Z' and not (r -> 'created' -> 1 ->> 'due_has_time')::boolean, '시각 없으면 23:59 KST, has_time=false';
  assert r -> 'created' -> 2 -> 'due_at' = 'null'::jsonb and not (r -> 'created' -> 2 ->> 'due_has_time')::boolean, '기한 없음';
  assert r -> 'created' -> 3 ->> 'due_at' = d || 'T01:00:00.000000Z' and (r -> 'created' -> 3 ->> 'due_has_time')::boolean, 'due_at 방식도 받음';
  perform d_expect($q$select import_todos('text', '[{"title":"x","due_date":"2030-13-45"}]')$q$, 'invalid_input');
  perform d_expect($q$select import_todos('text', '[{"title":"x","due_date":"2030-04-10","due_time":"25:00"}]')$q$, 'invalid_input');
  perform d_expect($q$select import_todos('text', '[{"title":"x","due_date":null,"due_time":"10:00"}]')$q$, 'invalid_input');
  perform d_expect($q$select import_todos('text', '[{"title":"x","due_date":"2030-04-10","due_at":"2030-04-10T00:00:00Z"}]')$q$, 'invalid_input');
  perform d_expect($q$select import_todos('text', '[{"title":"x","due_date":20300410}]')$q$, 'invalid_input');

  -- ── reschedule 은 블록을 일부만 고를 수 없다 ──
  reset role;
  t1 := (select plan_todo_json(t) from todos t where t.user_id = a and t.source_ref = 'k1');
  insert into plan_blocks (user_id, todo_id, start_at, end_at, status) values
    (a, (t1 ->> 'id')::uuid, now() + interval '1 day', now() + interval '1 day 1 hour', 'planned');
  insert into assistant_proposals (user_id, kind, input, proposal) values (a, 'reschedule', '{}', jsonb_build_object(
    'todos', '[]'::jsonb, 'done_todo_ids', '[]'::jsonb,
    'blocks', jsonb_build_array(
      jsonb_build_object('todo_ref', t1 ->> 'id', 'start', d || 'T10:00:00+09:00', 'end', d || 'T11:00:00+09:00'),
      jsonb_build_object('todo_ref', t1 ->> 'id', 'start', d || 'T13:00:00+09:00', 'end', d || 'T14:00:00+09:00')))) returning id into p;
  perform test_login(a);
  perform d_expect(format($q$select apply_proposal(%L, null, array[0], false)$q$, p), 'invalid_input');   -- 일부
  perform d_expect(format($q$select apply_proposal(%L, null, array[]::int[], false)$q$, p), 'invalid_input');
  perform d_expect(format($q$select apply_proposal(%L, null, array[0, 0], false)$q$, p), 'invalid_input');
  reset role;
  assert (select applied_at is null from assistant_proposals where id = p), '거절되면 제안은 소비되지 않음';
  assert (select count(*) from plan_blocks where user_id = a and status = 'moved') = 0, '기존 계획이 사라지지 않음';
  assert (select count(*) from plan_blocks where user_id = a and origin = 'assistant') = 0;
  perform test_login(a);
  r := apply_proposal(p, null, array[1, 0], false);                                                         -- 전부(순서 무관)
  assert jsonb_array_length(r -> 'blocks') = 2, '전부 적용';
  reset role;
  assert (select count(*) from plan_blocks where user_id = a and status = 'moved') = 1, '기존 블록은 moved';

  -- reschedule 이 아닌 제안(capture)은 일부만 골라도 된다
  insert into assistant_proposals (user_id, kind, input, proposal) values (a, 'capture', '{}', jsonb_build_object(
    'todos', '[]'::jsonb, 'done_todo_ids', '[]'::jsonb,
    'blocks', jsonb_build_array(
      jsonb_build_object('todo_ref', t1 ->> 'id', 'start', d || 'T16:00:00+09:00', 'end', d || 'T17:00:00+09:00'),
      jsonb_build_object('todo_ref', t1 ->> 'id', 'start', d || 'T18:00:00+09:00', 'end', d || 'T19:00:00+09:00')))) returning id into p;
  perform test_login(a);
  r := apply_proposal(p, null, array[1], false);
  assert jsonb_array_length(r -> 'blocks') = 1, 'capture는 일부 적용 가능';

  -- ── 24시간이 지난 제안은 proposal_not_found ──
  reset role;
  insert into assistant_proposals (user_id, kind, input, proposal, created_at) values (a, 'capture', '{}', jsonb_build_object(
    'todos', jsonb_build_array(jsonb_build_object('title', '만료될 일')), 'blocks', '[]'::jsonb, 'done_todo_ids', '[]'::jsonb),
    now() - interval '24 hours 1 minute') returning id into p;
  perform test_login(a);
  perform d_expect(format($q$select apply_proposal(%L, null, null, false)$q$, p), 'proposal_not_found');
  reset role;
  assert (select applied_at is null from assistant_proposals where id = p), '만료된 제안은 적용되지 않음';
  assert not exists (select 1 from todos where user_id = a and title = '만료될 일');
  -- 23시간 59분 된 제안은 적용된다
  update assistant_proposals set created_at = now() - interval '23 hours 59 minutes' where id = p;
  perform test_login(a);
  r := apply_proposal(p, null, null, false);
  assert jsonb_array_length(r -> 'todos') = 1, '24시간 이내는 적용됨';
  reset role;
end $$;
