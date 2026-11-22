-- 통합 관문 G2: 임시 대역 없이 다섯 흐름의 실제 함수끼리 한 줄로 이어 본다.
-- 가입 → 프로필 → 친구 → 이어가는 일·할 일·예정 시간 → 세션 시작 → 피드 → 같이 하기
-- → 미완료 종료 → 비서 제안 저장·적용 → 오늘 조회
do $$
declare
  sc uuid; u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); u3 uuid := gen_random_uuid();
  tag text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
  th jsonb; td jsonb; bl jsonb; s1 jsonb; s2 jsonb; feed jsonb; pid uuid; res jsonb; today jsonb; card jsonb;
  tomorrow text := to_char((now() at time zone 'Asia/Seoul')::date + 1, 'YYYY-MM-DD');
  n int; m text;
begin
  select id into sc from schools where 'korea.ac.kr' = any (email_domains) limit 1;
  if sc is null then
    insert into schools (name, email_domains) values ('고려대학교', '{korea.ac.kr}') returning id into sc;
  end if;
  -- A: 가입 도메인 제한이 실제로 걸려 있다
  begin
    insert into auth.users (id, email) values (gen_random_uuid(), tag || '@gmail.com');
    raise exception '다른 도메인 가입이 허용됨';
  exception when others then
    get stacked diagnostics m = message_text;
    assert m = 'email_domain_not_allowed', '도메인 거절 코드: ' || m;
  end;
  insert into auth.users (id, email) values (u1, 'e2e1' || tag || '@korea.ac.kr'), (u2, 'e2e2' || tag || '@korea.ac.kr'), (u3, 'e2e3' || tag || '@korea.ac.kr');

  perform test_login(u1); perform upsert_my_profile('e1_' || tag, '가온', null);
  perform test_login(u2); perform upsert_my_profile('e2_' || tag, '나래', null);
  perform test_login(u3); perform upsert_my_profile('e3_' || tag, '다솜', null);

  -- C: 친구
  perform test_login(u1); perform send_friend_request(u2);
  perform test_login(u2); perform respond_friend_request(u1, true);

  -- D: 계획
  perform test_login(u1);
  th := create_thread('SECRET 개인 제목', 'study', 'DB 과제', 'friends');
  td := create_todo('SECRET 할 일', (th ->> 'id')::uuid, null, false, 60);
  bl := create_plan_block((td ->> 'id')::uuid, (th ->> 'id')::uuid, now() + interval '1 minute', now() + interval '61 minutes', false);

  -- B: 세션 시작(공개 범위는 이어가는 일의 기본값을 따라야 한다)
  s1 := start_session(p_client_id => gen_random_uuid(), p_primary_category => 'study',
                      p_thread_id => (th ->> 'id')::uuid, p_todo_id => (td ->> 'id')::uuid,
                      p_plan_block_id => (bl ->> 'id')::uuid, p_visibility => 'friends');
  assert s1 ->> 'status' = 'live';
  assert (get_my_live_session() ->> 'id') = s1 ->> 'id';
  today := get_today(null, null);
  assert (today -> 'live_session' ->> 'id') = s1 ->> 'id', 'D의 get_today가 B의 실제 session_json으로 진행 중 세션을 준다';

  -- C: 친구 피드에 보이고 개인 제목·할 일은 새지 않는다
  perform test_login(u2);
  feed := get_feed(null, 20, null);
  select i into card from jsonb_array_elements(feed -> 'items') i where i ->> 'session_id' = s1 ->> 'id';
  assert card is not null, '친구 피드에 세션이 보여야 함';
  assert card -> 'author' ->> 'display_name' = '가온', 'A의 실제 profile_card';
  assert feed::text not like '%SECRET%', '피드에 개인 제목이나 할 일이 샘';

  -- B+C: 같이 하기. 친구는 되고 남은 안 된다
  s2 := start_session(p_client_id => gen_random_uuid(), p_primary_category => 'study',
                      p_visibility => 'friends', p_joined_session_id => (s1 ->> 'id')::uuid);
  assert s2 ->> 'joined_session_id' = s1 ->> 'id';
  reset role;
  select count(*) into n from notification_outbox where user_id = u1 and kind = 'joined';
  assert n = 1, format('같이 하기 알림 %s건', n);
  perform test_login(u3);
  assert not exists (select 1 from jsonb_array_elements(get_feed(null, 20, null) -> 'items') i where i ->> 'session_id' = s1 ->> 'id'), '남의 피드에 보임';
  begin
    perform start_session(p_client_id => gen_random_uuid(), p_primary_category => 'study', p_joined_session_id => (s1 ->> 'id')::uuid);
    raise exception '남이 같이 하기에 성공함';
  exception when others then
    get stacked diagnostics m = message_text;
    assert m = 'join_not_allowed', '같이 하기 거절 코드: ' || m;
  end;
  -- 남의 할 일을 내 세션에 연결할 수 없다
  begin
    perform start_session(p_client_id => gen_random_uuid(), p_primary_category => 'study', p_todo_id => (td ->> 'id')::uuid);
    raise exception '남의 할 일 연결에 성공함';
  exception when others then
    get stacked diagnostics m = message_text;
    assert m in ('not_found', 'forbidden'), '남의 할 일 연결 거절 코드: ' || m;
  end;

  -- B: 미완료 종료. 할 일은 완료되지 않는다
  perform test_login(u1);
  s1 := end_session((s1 ->> 'id')::uuid, 'more', '풀이 방향은 잡음');
  assert s1 ->> 'status' = 'ended';
  reset role;
  assert (select status from todos where id = (td ->> 'id')::uuid) = 'in_progress', '세션 종료가 할 일을 완료 처리하면 안 됨';

  -- E → D: 서버 함수가 저장한 제안을 사용자가 적용한다
  pid := assistant_proposal_save(u1, 'reschedule', jsonb_build_object('kind', 'reschedule'),
    jsonb_build_object(
      'message', '내일 오전에 이어서 잡았어요.', 'todos', '[]'::jsonb, 'done_todo_ids', '[]'::jsonb,
      'unscheduled', '[]'::jsonb, 'questions', '[]'::jsonb,
      'blocks', jsonb_build_array(jsonb_build_object('todo_ref', td ->> 'id',
        'start', tomorrow || 'T10:00:00+09:00', 'end', tomorrow || 'T11:00:00+09:00'))));
  -- 저장만으로는 계획이 바뀌지 않는다
  assert (select count(*) from plan_blocks where user_id = u1 and origin = 'assistant') = 0;
  -- 남은 이 제안을 적용할 수 없다
  perform test_login(u2);
  begin
    perform apply_proposal(pid, null, null, false);
    raise exception '남의 제안 적용에 성공함';
  exception when others then
    get stacked diagnostics m = message_text;
    assert m = 'proposal_not_found', '남의 제안 거절 코드: ' || m;
  end;
  perform test_login(u1);
  res := apply_proposal(pid, null, null, false);
  assert jsonb_array_length(res -> 'blocks') = 1 and res -> 'blocks' -> 0 ->> 'origin' = 'assistant';
  begin
    perform apply_proposal(pid, null, null, false);
    raise exception '같은 제안을 두 번 적용함';
  exception when others then
    get stacked diagnostics m = message_text;
    assert m = 'proposal_already_applied', '재적용 거절 코드: ' || m;
  end;
  today := get_today(null, null);
  assert today -> 'live_session' = 'null'::jsonb;
  assert exists (select 1 from jsonb_array_elements(today -> 'todos') t where t ->> 'id' = td ->> 'id'), '진행 중인 할 일이 오늘 화면에 남아 있어야 함';
  reset role;
end $$;
