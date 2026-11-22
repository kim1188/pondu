-- 하루 한도: 같은 kind만 세고, 한국 시간 하루 단위이며, 사용자끼리 섞이지 않는다.
do $$
declare
  s uuid := gen_random_uuid(); a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); r uuid; n int;
begin
  insert into schools (id, name, email_domains) values (s, '테스트대', '{test.ac.kr}');
  insert into auth.users (id, email) values (a, a::text || '@test.ac.kr'), (b, b::text || '@test.ac.kr');
  insert into profiles (id, school_id, handle, display_name) values (a, s, 'a_' || substr(a::text, 1, 8), 'A'), (b, s, 'b_' || substr(b::text, 1, 8), 'B');

  -- 어제(한국 시간) 기록은 세지 않는다.
  insert into assistant_runs (user_id, kind, ok, created_at)
    values (a, 'capture', true, (date_trunc('day', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul') - interval '1 minute');

  r := assistant_run_begin(a, 'capture', 2);
  perform assistant_run_begin(a, 'capture', 2);
  begin
    perform assistant_run_begin(a, 'capture', 2);
    raise exception '한도를 넘었는데 통과함';
  exception when others then
    assert sqlerrm = 'quota_exceeded', format('기대: quota_exceeded, 실제: %s', sqlerrm);
  end;

  -- 다른 kind, 다른 사용자는 영향이 없다.
  perform assistant_run_begin(a, 'import_extract', 2);
  perform assistant_run_begin(b, 'capture', 2);

  -- 한도 0이면 첫 호출부터 막는다.
  begin
    perform assistant_run_begin(b, 'plan_day', 0);
    raise exception '한도 0인데 통과함';
  exception when others then
    assert sqlerrm = 'quota_exceeded', sqlerrm;
  end;

  -- 잘못된 인자
  begin
    perform assistant_run_begin(a, 'Bad Kind!', 5);
    raise exception '잘못된 kind가 통과함';
  exception when others then
    assert sqlerrm = 'invalid_input', sqlerrm;
  end;

  -- 마무리 기록
  perform assistant_run_finish(r, 'claude-opus-5-5', 100, 50, 1234, true);
  select count(*) into n from assistant_runs where id = r and ok and model = 'claude-opus-5-5'
     and input_tokens = 100 and output_tokens = 50 and latency_ms = 1234;
  assert n = 1, '마무리 기록이 반영되지 않음';
  -- 시작만 하고 끝내지 못한 호출은 ok=false로 남는다.
  select count(*) into n from assistant_runs where user_id = a and kind = 'capture' and not ok and created_at > now() - interval '1 minute';
  assert n = 1, format('미완료 기록 수 %s', n);
end $$;
