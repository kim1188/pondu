-- 제안 저장: input에는 kind와 now만 남고 대화 원문은 남지 않는다.
do $$
declare
  s uuid := gen_random_uuid(); a uuid := gen_random_uuid(); pid uuid; i jsonb; t uuid := gen_random_uuid();
begin
  insert into schools (id, name, email_domains) values (s, '테스트대', '{korea.ac.kr}');
  insert into auth.users (id, email) values (a, a::text || '@korea.ac.kr');
  insert into profiles (id, school_id, handle, display_name) values (a, s, 'e_a_' || substr(a::text, 1, 8), 'A');
  insert into threads (id, user_id, title, primary_category) values (t, a, '선형대수', 'study');

  pid := assistant_proposal_save(a, 'capture',
    '{"kind":"capture","now":"2026-11-23T00:00:00Z","text":"비밀 대화 내용","pasted":"붙여 넣은 글"}'::jsonb,
    '{"todos":[{"title":"x"}],"blocks":[],"done_todo_ids":[],"unscheduled":[],"questions":[],"message":"m"}'::jsonb);
  select input into i from assistant_proposals where id = pid;
  assert i = '{"kind":"capture","now":"2026-11-23T00:00:00Z"}'::jsonb, format('input에 원문이 남음: %s', i);
  assert (select applied_at is null and user_id = a from assistant_proposals where id = pid), '저장 상태가 이상함';

  begin
    perform assistant_proposal_save(a, 'chat', '{}'::jsonb, '{"todos":[],"blocks":[]}'::jsonb);
    raise exception '잘못된 kind가 통과함';
  exception when others then assert sqlerrm = 'invalid_input', sqlerrm; end;
  begin
    perform assistant_proposal_save(a, 'capture', '{}'::jsonb, '{"todos":"no"}'::jsonb);
    raise exception '잘못된 proposal이 통과함';
  exception when others then assert sqlerrm = 'invalid_input', sqlerrm; end;

  assert assistant_thread_categories(a) = jsonb_build_object(t::text, 'study'), '이어가는 일 분야 표가 틀림';
end $$;
