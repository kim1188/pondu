-- import_todos: 중복 건너뛰기, imported 완료, 세션 미생성
select d_reset();
do $$
declare
  a uuid := '11111111-1111-1111-1111-111111111111';
  b uuid := '22222222-2222-2222-2222-222222222222';
  r jsonb; n int; t jsonb;
begin
  perform test_login(a);
  r := import_todos('calendar', '[
    {"title":"운영체제 중간고사","due_at":"2030-04-10T01:00:00Z","due_has_time":true,"estimate_min":120,"source_ref":"ev-1","done":false},
    {"title":"과제 제출","due_at":null,"due_has_time":false,"estimate_min":null,"source_ref":"ev-2","done":true},
    {"title":"참조 없는 항목","source_ref":null}
  ]');
  assert jsonb_array_length(r->'created') = 3 and (r->>'skipped')::int = 0;
  t := r->'created'->0;
  assert t->>'source' = 'calendar' and t->>'source_ref' = 'ev-1' and (t->>'due_has_time')::boolean and t->>'status' = 'open';
  t := r->'created'->1;
  assert t->>'status' = 'done' and t->>'completion_source' = 'imported' and t->>'completed_at' is not null;

  -- 같은 항목을 다시 가져와도 중복이 생기지 않는다(참조 없는 것은 매번 새로 생김)
  r := import_todos('calendar', '[
    {"title":"운영체제 중간고사","source_ref":"ev-1"},
    {"title":"새 일정","source_ref":"ev-3"},
    {"title":"과제 제출","source_ref":"ev-2","done":true}
  ]');
  assert jsonb_array_length(r->'created') = 1 and (r->>'skipped')::int = 2, r::text;
  -- 한 번의 호출 안에서의 중복도 건너뜀
  r := import_todos('text', '[{"title":"x","source_ref":"h1"},{"title":"x","source_ref":"h1"}]');
  assert jsonb_array_length(r->'created') = 1 and (r->>'skipped')::int = 1;
  -- 출처가 다르면 같은 source_ref 도 별개
  r := import_todos('text', '[{"title":"x","source_ref":"ev-1"}]');
  assert jsonb_array_length(r->'created') = 1;

  -- 빈 목록
  r := import_todos('text', '[]');
  assert jsonb_array_length(r->'created') = 0 and (r->>'skipped')::int = 0;

  -- 세션은 만들어지지 않는다
  execute 'reset role';
  select count(*) into n from sessions where user_id = a;
  assert n = 0, '가져오기는 세션을 만들지 않는다';

  -- 다른 사용자는 같은 (source, source_ref)로도 자기 것을 만든다(남의 것에 막히지 않음)
  perform test_login(b);
  r := import_todos('calendar', '[{"title":"B의 일정","source_ref":"ev-1"}]');
  assert jsonb_array_length(r->'created') = 1 and (r->>'skipped')::int = 0;
  perform test_login(a);
  select count(*) into n from jsonb_array_elements(get_today(current_date, 'Asia/Seoul')->'todos') e where e->>'title' = 'B의 일정';
  assert n = 0, 'A 는 B 의 가져온 항목을 보지 못함';

  -- 잘못된 입력
  perform d_expect($q$select import_todos('', '[]')$q$, 'invalid_input');
  perform d_expect($q$select import_todos(null, '[]')$q$, 'invalid_input');
  perform d_expect($q$select import_todos('x', null)$q$, 'invalid_input');
  perform d_expect($q$select import_todos('x', '{"a":1}')$q$, 'invalid_input');
  perform d_expect($q$select import_todos('x', '[{"due_at":null}]')$q$, 'invalid_input');
  perform d_expect($q$select import_todos('x', '[{"title":""}]')$q$, 'invalid_input');
  perform d_expect($q$select import_todos('x', '[{"title":"a","due_at":"내일"}]')$q$, 'invalid_input');
  perform d_expect($q$select import_todos('x', '[{"title":"a","estimate_min":0}]')$q$, 'invalid_input');
  perform d_expect($q$select import_todos('x', '[1]')$q$, 'invalid_input');
  -- 오류가 나면 그 호출에서 만든 것은 모두 취소
  begin
    perform import_todos('atomic', '[{"title":"ok","source_ref":"z1"},{"title":""}]');
  exception when sqlstate 'P0001' then null;
  end;
  select count(*) into n from jsonb_array_elements(import_todos('atomic', '[{"title":"ok","source_ref":"z1"}]')->'created');
  assert n = 1, '실패한 호출은 흔적을 남기지 않음';
  execute 'reset role';
end $$;
