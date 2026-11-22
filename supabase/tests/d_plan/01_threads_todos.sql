-- 이어가는 일·할 일 생성/수정/삭제, patch 검증
select d_reset();
do $$
declare
  a uuid := '11111111-1111-1111-1111-111111111111';
  th jsonb; th2 jsonb; td jsonb; r jsonb; n int;
begin
  perform test_login(a);

  -- 이어가는 일
  th := create_thread('  개인 앱 개발 ', 'coding', '앱 만드는 중', null);
  assert th->>'title' = '개인 앱 개발', '제목은 앞뒤 공백 제거';
  assert th->>'default_visibility' = 'private', '기본 공개 범위 private';
  assert th->>'archived_at' is null;
  perform d_expect($q$select create_thread(null, 'coding', null, null)$q$, 'invalid_input');
  perform d_expect($q$select create_thread('', 'coding', null, null)$q$, 'invalid_input');
  perform d_expect($q$select create_thread('x', null, null, null)$q$, 'invalid_input');
  perform d_expect($q$select create_thread('x', 'coding', null, 'school')$q$, 'visibility_not_available');

  r := update_thread((th->>'id')::uuid, '{"title":"앱 개발","share_title":null,"default_visibility":"friends"}');
  assert r->>'title' = '앱 개발' and r->>'share_title' is null and r->>'default_visibility' = 'friends';
  r := update_thread((th->>'id')::uuid, '{"primary_category":"study"}');
  assert r->>'primary_category' = 'study';
  perform d_expect(format($q$select update_thread(%L, '{"user_id":"x"}')$q$, th->>'id'), 'invalid_input');
  perform d_expect(format($q$select update_thread(%L, '{"title":"a","zzz":1}')$q$, th->>'id'), 'invalid_input');
  perform d_expect(format($q$select update_thread(%L, '{}')$q$, th->>'id'), 'invalid_input');
  perform d_expect(format($q$select update_thread(%L, '[]')$q$, th->>'id'), 'invalid_input');
  perform d_expect(format($q$select update_thread(%L, '{"title":""}')$q$, th->>'id'), 'invalid_input');
  perform d_expect(format($q$select update_thread(%L, '{"primary_category":"nope"}')$q$, th->>'id'), 'invalid_input');
  perform d_expect(format($q$select update_thread(%L, '{"title":5}')$q$, th->>'id'), 'invalid_input');
  perform d_expect(format($q$select update_thread(%L, '{"default_visibility":"department"}')$q$, th->>'id'), 'visibility_not_available');
  perform d_expect($q$select update_thread(gen_random_uuid(), '{"title":"a"}')$q$, 'not_found');

  th2 := create_thread('DB 과제', 'study', null, 'private');
  assert jsonb_array_length(list_threads()) = 2;
  perform archive_thread((th2->>'id')::uuid);
  assert jsonb_array_length(list_threads()) = 1, '보관한 일은 목록에서 빠짐';
  perform archive_thread((th2->>'id')::uuid); -- 두 번 해도 오류 없음
  perform d_expect($q$select archive_thread(gen_random_uuid())$q$, 'not_found');

  -- 할 일 생성
  td := create_todo(' 과제 1번 ', (th->>'id')::uuid, '2030-01-02T14:59:00Z', true, 60);
  assert td->>'title' = '과제 1번' and td->>'status' = 'open' and td->>'source' = 'manual';
  assert (td->>'due_has_time')::boolean and (td->>'estimate_min')::int = 60;
  assert td->>'due_at' = '2030-01-02T14:59:00.000000Z', '시각은 UTC ISO: ' || (td->>'due_at');
  assert td->>'thread_id' = th->>'id';
  assert td->>'completed_at' is null and td->>'completion_source' is null;
  -- 마감이 없으면 due_has_time 은 false 로 정리
  r := create_todo('빈 마감', null, null, true, null);
  assert not (r->>'due_has_time')::boolean;
  perform d_expect($q$select create_todo(null, null, null, null, null)$q$, 'invalid_input');
  perform d_expect($q$select create_todo('', null, null, null, null)$q$, 'invalid_input');
  perform d_expect($q$select create_todo('x', null, null, null, 0)$q$, 'invalid_input');
  perform d_expect($q$select create_todo('x', null, null, null, 1441)$q$, 'invalid_input');
  perform d_expect($q$select create_todo('x', gen_random_uuid(), null, null, null)$q$, 'not_found');

  -- 수정
  r := update_todo((td->>'id')::uuid, '{"title":"과제 2번","estimate_min":90,"due_at":"2030-01-03T00:00:00Z","due_has_time":false}');
  assert r->>'title' = '과제 2번' and (r->>'estimate_min')::int = 90 and not (r->>'due_has_time')::boolean;
  r := update_todo((td->>'id')::uuid, '{"due_at":null,"estimate_min":null,"thread_id":null}');
  assert r->>'due_at' is null and r->>'estimate_min' is null and r->>'thread_id' is null;
  r := update_todo((td->>'id')::uuid, jsonb_build_object('thread_id', th->>'id'));
  assert r->>'thread_id' = th->>'id';
  perform d_expect(format($q$select update_todo(%L, '{"status":"done"}')$q$, td->>'id'), 'invalid_input');
  perform d_expect(format($q$select update_todo(%L, '{"user_id":"%s"}')$q$, td->>'id', a), 'invalid_input');
  perform d_expect(format($q$select update_todo(%L, '{"title":"a","completion_source":"imported"}')$q$, td->>'id'), 'invalid_input');
  perform d_expect(format($q$select update_todo(%L, '{}')$q$, td->>'id'), 'invalid_input');
  perform d_expect(format($q$select update_todo(%L, '{"estimate_min":0}')$q$, td->>'id'), 'invalid_input');
  perform d_expect(format($q$select update_todo(%L, '{"estimate_min":"abc"}')$q$, td->>'id'), 'invalid_input');
  perform d_expect(format($q$select update_todo(%L, '{"due_at":"내일"}')$q$, td->>'id'), 'invalid_input');
  perform d_expect(format($q$select update_todo(%L, '{"title":null}')$q$, td->>'id'), 'invalid_input');
  perform d_expect(format($q$select update_todo(%L, '{"thread_id":"%s"}')$q$, td->>'id', gen_random_uuid()), 'not_found');
  perform d_expect($q$select update_todo(gen_random_uuid(), '{"title":"a"}')$q$, 'not_found');

  -- 상태
  r := set_todo_status((td->>'id')::uuid, 'in_progress');
  assert r->>'status' = 'in_progress' and r->>'completed_at' is null;
  r := set_todo_status((td->>'id')::uuid, 'done');
  assert r->>'status' = 'done' and r->>'completion_source' = 'user_action' and r->>'completed_at' is not null;
  r := set_todo_status((td->>'id')::uuid, 'open');
  assert r->>'status' = 'open' and r->>'completed_at' is null and r->>'completion_source' is null, '되돌리면 완료 흔적 제거';
  r := set_todo_status((td->>'id')::uuid, 'dropped');
  assert r->>'status' = 'dropped';
  perform d_expect(format($q$select set_todo_status(%L, null)$q$, td->>'id'), 'invalid_input');
  perform d_expect($q$select set_todo_status(gen_random_uuid(), 'done')$q$, 'not_found');

  -- 삭제
  perform delete_todo((td->>'id')::uuid);
  execute 'reset role';
  select count(*) into n from todos where id = (td->>'id')::uuid;
  assert n = 0, '삭제됨';
  perform test_login(a);
  perform d_expect($q$select delete_todo(gen_random_uuid())$q$, 'not_found');
  execute 'reset role';
end $$;
