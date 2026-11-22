-- 흐름 D 테스트 공통 준비. 같은 임시 DB에서 이어서 도는 다른 파일이 쓰는 사용자와 도우미를 만든다.
-- 사용자 A = 11111111-…, B = 22222222-… (이름 대신 고정 uuid)
insert into schools (id, name, email_domains)
values ('d0000000-0000-0000-0000-000000000001', 'D테스트대', '{d.test}')
on conflict do nothing;
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'a@d.test'),
  ('22222222-2222-2222-2222-222222222222', 'b@d.test')
on conflict do nothing;
insert into profiles (id, school_id, handle, display_name) values
  ('11111111-1111-1111-1111-111111111111', 'd0000000-0000-0000-0000-000000000001', 'd_user_a', 'A'),
  ('22222222-2222-2222-2222-222222222222', 'd0000000-0000-0000-0000-000000000001', 'd_user_b', 'B')
on conflict do nothing;

-- 흐름 B 의 session_json 이 아직 없으면 시험용으로 임시 정의한다(실제 정의가 있으면 건드리지 않는다).
do $$ begin
  if to_regprocedure('public.session_json(public.sessions)') is null then
    execute $f$
      create function public.session_json(p_session public.sessions) returns jsonb
      language sql stable as $b$
        select jsonb_build_object('id', p_session.id, 'user_id', p_session.user_id, 'status', p_session.status,
                                  'todo_id', p_session.todo_id)
      $b$ $f$;
  end if;
end $$;

-- 현재 역할로 sql 을 실행해 P0001 오류(message = p_code)가 나는지 확인한다.
-- p_code 가 'privilege' 이면 실행 권한 없음(insufficient_privilege)을 기대한다.
create or replace function public.d_expect(p_sql text, p_code text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception 'd_expect: 오류가 나야 하는데 성공함: %', p_sql;
exception
  when insufficient_privilege then
    if p_code <> 'privilege' then raise exception 'd_expect: 권한 오류(기대 %): %', p_code, p_sql; end if;
  when sqlstate 'P0001' then
    if sqlerrm like 'd_expect:%' then raise; end if;
    if sqlerrm <> p_code then raise exception 'd_expect: 기대 %, 실제 %: %', p_code, sqlerrm, p_sql; end if;
end $$;
grant execute on function public.d_expect(text, text) to public;

-- 사용자 둘의 계획 데이터를 비운다.
create or replace function public.d_reset() returns void language plpgsql as $$
begin
  delete from sessions where user_id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');
  delete from assistant_proposals where user_id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');
  delete from plan_blocks where user_id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');
  delete from todos where user_id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');
  delete from threads where user_id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');
  delete from estimate_stats where user_id in ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');
end $$;
