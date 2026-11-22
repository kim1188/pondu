-- 알림 집기: 한 번 집으면 다시 집히지 않고, 오래된 건은 건너뛰며, 발송 표시와 토큰 정리가 동작한다.
do $$
declare
  s uuid := gen_random_uuid(); a uuid := gen_random_uuid(); b uuid := gen_random_uuid();
  r jsonb; ids bigint[]; n int;
begin
  insert into schools (id, name, email_domains) values (s, '테스트대', '{korea.ac.kr}');
  insert into auth.users (id, email) values (a, a::text || '@korea.ac.kr'), (b, b::text || '@korea.ac.kr');
  insert into profiles (id, school_id, handle, display_name) values (a, s, 'e_a_' || substr(a::text, 1, 8), '가은'), (b, s, 'e_b_' || substr(b::text, 1, 8), 'B');
  insert into device_tokens (user_id, token) values (a, 'tok-a1'), (a, 'tok-a2');

  insert into notification_outbox (user_id, kind, payload) values
    (a, 'reaction', jsonb_build_object('user_id', b::text, 'session_id', gen_random_uuid()::text)),
    (b, 'friend_request', jsonb_build_object('user_id', a::text));
  insert into notification_outbox (user_id, kind, payload, created_at) values (a, 'comment', '{}', now() - interval '25 hours');

  r := notification_outbox_claim(10);
  assert jsonb_array_length(r) = 2, format('집은 수 %s (25시간 지난 건은 빠져야 함)', jsonb_array_length(r));
  assert r->0->>'actor_name' = 'B' and jsonb_array_length(r->0->'tokens') = 2, format('첫 건: %s', r->0);
  assert r->1->>'actor_name' = '가은' and jsonb_array_length(r->1->'tokens') = 0, format('둘째 건: %s', r->1);

  -- 곧바로 다시 집으면 비어 있다(다른 호출이 이미 집었다).
  assert notification_outbox_claim(10) = '[]'::jsonb, '같은 건을 두 번 집음';

  -- 집은 뒤 5분이 지나도 발송 표시가 없으면 다시 집힌다.
  update notification_outbox set claimed_at = now() - interval '6 minutes' where kind = 'reaction';
  r := notification_outbox_claim(10);
  assert jsonb_array_length(r) = 1 and r->0->>'kind' = 'reaction', format('재집기: %s', r);

  select array_agg(id) into ids from notification_outbox where kind in ('reaction', 'friend_request');
  assert notification_outbox_mark_sent(ids) = 2, '발송 표시 수가 틀림';
  assert notification_outbox_mark_sent(ids) = 0, '이미 보낸 건을 또 표시함';
  update notification_outbox set claimed_at = null;
  assert notification_outbox_claim(10) = '[]'::jsonb, '보낸 건이 다시 집힘';

  assert device_tokens_remove(array['tok-a1', 'nope']) = 1, '토큰 삭제 수가 틀림';
  select count(*) into n from device_tokens where user_id = a;
  assert n = 1, '토큰이 남아 있어야 함';

  -- 차단: 어느 방향이든 차단 관계면 집는 순간 보내지 않고 발송 처리한다.
  insert into blocks (blocker_id, blocked_id) values (b, a);
  insert into notification_outbox (user_id, kind, payload) values (a, 'reaction', jsonb_build_object('user_id', b::text));  -- a가 받음, 행위자 b는 a를 차단
  insert into notification_outbox (user_id, kind, payload) values (b, 'comment', jsonb_build_object('user_id', a::text));   -- b가 받음, 행위자 a는 b에게 차단당함
  r := notification_outbox_claim(10);
  assert r = '[]'::jsonb, format('차단 관계 알림이 나감: %s', r);
  select count(*) into n from notification_outbox where sent_at is not null and created_at > now() - interval '1 minute'
     and kind in ('reaction','comment') and claimed_at is not null;
  assert n >= 2, format('차단 알림이 발송 처리되지 않음: %s', n);

  -- 중복: 같은 (받는 사람, 행위자, 종류, 대상)은 10분에 한 번만 보낸다.
  delete from blocks;
  declare sid text := gen_random_uuid()::text; begin
    insert into notification_outbox (user_id, kind, payload) values
      (a, 'reaction', jsonb_build_object('user_id', b::text, 'session_id', sid)),
      (a, 'reaction', jsonb_build_object('user_id', b::text, 'session_id', sid)),                       -- 같은 묶음의 중복
      (a, 'reaction', jsonb_build_object('user_id', b::text, 'session_id', gen_random_uuid()::text));   -- 대상이 다르면 별개
    r := notification_outbox_claim(10);
    assert jsonb_array_length(r) = 2, format('같은 묶음 중복 처리: %s', r);
    perform notification_outbox_mark_sent(array(select (e->>'id')::bigint from jsonb_array_elements(r) e));
    -- 보낸 직후 같은 알림이 또 생기면 보내지 않는다.
    insert into notification_outbox (user_id, kind, payload) values (a, 'reaction', jsonb_build_object('user_id', b::text, 'session_id', sid));
    assert notification_outbox_claim(10) = '[]'::jsonb, '10분 안 중복이 나감';
    -- 10분이 지나면 다시 보낸다.
    update notification_outbox set sent_at = now() - interval '11 minutes' where sent_at is not null and not skipped
       and payload->>'session_id' = sid;
    insert into notification_outbox (user_id, kind, payload) values (a, 'reaction', jsonb_build_object('user_id', b::text, 'session_id', sid));
    assert jsonb_array_length(notification_outbox_claim(10)) = 1, '10분이 지났는데 막힘';
  end;
end $$;
