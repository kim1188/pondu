-- 이 폴더 테스트가 함께 쓰는 도우미. 다른 흐름 테스트와 이름이 겹치지 않게 a_ 접두사.
\ir ../../seed/01_school_korea.sql
create or replace function public.a_expect_err(p_sql text, p_msg text) returns void
language plpgsql as $$
begin
  execute p_sql;
  raise exception '오류가 나야 하는데 통과함: %', p_sql;
exception
  when sqlstate 'P0001' then
    if sqlerrm <> p_msg then raise exception '오류 메시지 불일치: 기대 %, 실제 % (%)', p_msg, sqlerrm, p_sql; end if;
end $$;
-- 권한 오류(insufficient_privilege)가 나야 하는 문장
create or replace function public.a_expect_denied(p_sql text) returns void
language plpgsql as $$
begin
  execute p_sql;
  raise exception '권한 오류가 나야 하는데 통과함: %', p_sql;
exception when insufficient_privilege then null;
end $$;
grant execute on function public.a_expect_err(text, text), public.a_expect_denied(text) to public;
