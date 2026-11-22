-- 남의 데이터 읽기·바꾸기 시도, 로그인 없이 호출, 직접 접근, 내부 함수 호출
select d_reset();
do $$
declare
  a uuid := '11111111-1111-1111-1111-111111111111';
  b uuid := '22222222-2222-2222-2222-222222222222';
  th jsonb; td jsonb; blk jsonb; p uuid; r jsonb; n int; tb jsonb; thb jsonb;
  s0 timestamptz := '2030-06-05 00:00:00+09';
begin
  -- A 의 자료
  perform test_login(a);
  th := create_thread('A 의 일', 'study', '공유 제목', 'friends');
  td := create_todo('A 의 비밀 할 일', (th->>'id')::uuid, null, null, 30);
  blk := create_plan_block((td->>'id')::uuid, null, s0 + interval '10 hours', s0 + interval '11 hours', false);
  execute 'reset role';
  insert into sessions (user_id, client_id, primary_category, status, todo_id)
  values (a, gen_random_uuid(), 'study', 'live', (td->>'id')::uuid);
  insert into assistant_proposals (user_id, kind, input, proposal) values (a, 'capture', '{}',
    '{"todos":[{"title":"A 의 제안","due_date":null,"due_time":null,"estimate_min":null,"category":null}],"blocks":[],"done_todo_ids":[]}')
  returning id into p;
  insert into estimate_stats (user_id, primary_category, factor, sample_count) values (a, 'study', 2.0, 5);

  -- B 로 로그인해서 A 의 것을 읽거나 바꿔 본다
  perform test_login(b);
  perform d_expect(format($q$select update_thread(%L, '{"title":"해킹"}')$q$, th->>'id'), 'not_found');
  perform d_expect(format($q$select archive_thread(%L)$q$, th->>'id'), 'not_found');
  perform d_expect(format($q$select update_todo(%L, '{"title":"해킹"}')$q$, td->>'id'), 'not_found');
  perform d_expect(format($q$select set_todo_status(%L, 'done')$q$, td->>'id'), 'not_found');
  perform d_expect(format($q$select delete_todo(%L)$q$, td->>'id'), 'not_found');
  perform d_expect(format($q$select create_todo('내 것인 척', %L, null, null, null)$q$, th->>'id'), 'not_found');
  perform d_expect(format($q$select create_plan_block(%L, null, now(), now() + interval '1 hour', false)$q$, td->>'id'), 'not_found');
  perform d_expect(format($q$select create_plan_block(null, %L, now(), now() + interval '1 hour', false)$q$, th->>'id'), 'not_found');
  perform d_expect(format($q$select update_plan_block(%L, '{"locked":true}')$q$, blk->>'id'), 'not_found');
  perform d_expect(format($q$select delete_plan_block(%L)$q$, blk->>'id'), 'not_found');
  perform d_expect(format($q$select apply_proposal(%L, null, null, true)$q$, p), 'proposal_not_found');

  -- B 가 본인 할 일을 A 의 이어가는 일에 붙이려는 시도
  tb := create_todo('B 의 일', null, null, null, null);
  perform d_expect(format($q$select update_todo(%L, '{"thread_id":"%s"}')$q$, tb->>'id', th->>'id'), 'not_found');

  -- 조회에 A 의 것이 섞이지 않는다
  assert list_threads() = '[]'::jsonb, 'B 의 이어가는 일 목록에 A 것 없음';
  r := get_today(null, null);
  assert jsonb_array_length(r->'todos') = 1 and r->'todos'->0->>'title' = 'B 의 일';
  assert jsonb_array_length(r->'threads') = 0 and r->'estimate_factors' = '{}'::jsonb and r->'live_session' = 'null'::jsonb;
  r := get_today('2030-06-05', 'Asia/Seoul');
  assert jsonb_array_length(r->'blocks') = 0, 'B 의 오늘에 A 의 예정 시간 없음';
  -- 같은 (source, source_ref) 로 가져와도 A 의 것에 영향 없음
  perform import_todos('manual', '[{"title":"x","source_ref":"r"}]');

  -- 직접 접근 불가
  perform d_expect('select * from todos', 'privilege');
  perform d_expect('select * from threads', 'privilege');
  perform d_expect('select * from plan_blocks', 'privilege');
  perform d_expect('select * from estimate_stats', 'privilege');
  perform d_expect('select * from assistant_proposals', 'privilege');
  perform d_expect($q$update todos set title = 'x'$q$, 'privilege');
  perform d_expect($q$delete from plan_blocks$q$, 'privilege');
  -- 내부 함수는 호출할 수 없다
  perform d_expect($q$select assistant_context('11111111-1111-1111-1111-111111111111', now())$q$, 'privilege');
  perform d_expect($q$select plan_recompute_estimate('11111111-1111-1111-1111-111111111111', 'study')$q$, 'privilege');
  perform d_expect($q$select plan_after_todo_change('11111111-1111-1111-1111-111111111111', gen_random_uuid())$q$, 'privilege');
  perform d_expect($q$select plan_fail('not_found')$q$, 'privilege');

  -- A 의 자료는 그대로이고, 제안도 적용되지 않았다
  execute 'reset role';
  assert (select title from todos where id = (td->>'id')::uuid) = 'A 의 비밀 할 일';
  assert (select status from todos where id = (td->>'id')::uuid) = 'open';
  assert (select title from threads where id = (th->>'id')::uuid) = 'A 의 일' and (select archived_at from threads where id = (th->>'id')::uuid) is null;
  assert (select locked from plan_blocks where id = (blk->>'id')::uuid) = false;
  assert (select applied_at from assistant_proposals where id = p) is null;
  assert (select count(*) from todos where title in ('A 의 제안', '내 것인 척')) = 0;

  -- 로그인 없음 / 익명
  perform set_config('request.jwt.claim.sub', '', false);
  execute 'set role authenticated';
  perform d_expect($q$select list_threads()$q$, 'not_authenticated');
  perform d_expect($q$select create_thread('x', 'study', null, null)$q$, 'not_authenticated');
  perform d_expect($q$select update_thread(gen_random_uuid(), '{"title":"a"}')$q$, 'not_authenticated');
  perform d_expect($q$select archive_thread(gen_random_uuid())$q$, 'not_authenticated');
  perform d_expect($q$select create_todo('x', null, null, null, null)$q$, 'not_authenticated');
  perform d_expect($q$select update_todo(gen_random_uuid(), '{"title":"a"}')$q$, 'not_authenticated');
  perform d_expect($q$select set_todo_status(gen_random_uuid(), 'done')$q$, 'not_authenticated');
  perform d_expect($q$select delete_todo(gen_random_uuid())$q$, 'not_authenticated');
  perform d_expect($q$select import_todos('x', '[]')$q$, 'not_authenticated');
  perform d_expect($q$select create_plan_block(null, null, now(), now() + interval '1 hour', false)$q$, 'not_authenticated');
  perform d_expect($q$select update_plan_block(gen_random_uuid(), '{"locked":true}')$q$, 'not_authenticated');
  perform d_expect($q$select delete_plan_block(gen_random_uuid())$q$, 'not_authenticated');
  perform d_expect($q$select get_today(null, null)$q$, 'not_authenticated');
  perform d_expect($q$select apply_proposal(gen_random_uuid(), null, null, false)$q$, 'not_authenticated');
  execute 'reset role';
  perform test_anon();
  perform d_expect($q$select get_today(null, null)$q$, 'privilege');
  perform d_expect($q$select list_threads()$q$, 'privilege');
  perform d_expect($q$select apply_proposal(gen_random_uuid(), null, null, false)$q$, 'privilege');
  execute 'reset role';
end $$;
