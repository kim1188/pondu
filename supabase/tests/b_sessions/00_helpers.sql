-- 흐름 B 테스트 공용 도우미. 다른 테스트 파일이 \ir 로 불러 쓴다. 이 파일 자체는 아무것도 검사하지 않는다.
create schema if not exists tt_b;
grant usage on schema tt_b to public;

-- 학교 1개와 프로필이 있는 사용자를 만든다.
create or replace function tt_b.mk_user(p_name text) returns uuid language plpgsql as $$
declare
  v uuid := gen_random_uuid();
  sch uuid;
  h text := substr(md5(random()::text || clock_timestamp()::text), 1, 8);
begin
  select id into sch from schools order by created_at limit 1;
  if sch is null then
    insert into schools (name, email_domains) values ('테스트대', '{korea.ac.kr}') returning id into sch;
  end if;
  insert into auth.users (id, email) values (v, p_name || h || '@korea.ac.kr');
  insert into profiles (id, school_id, handle, display_name) values (v, sch, 'u_' || h, p_name);
  return v;
end $$;

create or replace function tt_b.assert(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'ASSERT FAILED: %', p_msg; end if;
end $$;

-- p_sql 이 정확히 p_code 오류로 실패해야 한다. 호출한 역할 그대로 실행한다.
create or replace function tt_b.expect_err(p_sql text, p_code text) returns void language plpgsql as $$
declare
  ok boolean := false;
begin
  begin
    execute p_sql;
    ok := true;
  exception when others then
    if sqlerrm <> p_code then
      raise exception 'expected error %, got % for: %', p_code, sqlerrm, p_sql;
    end if;
  end;
  if ok then raise exception 'expected error % but it succeeded: %', p_code, p_sql; end if;
end $$;

-- 권한 오류(permission denied 등)로 실패해야 한다.
create or replace function tt_b.expect_denied(p_sql text) returns void language plpgsql as $$
declare
  ok boolean := false;
begin
  begin
    execute p_sql;
    ok := true;
  exception when insufficient_privilege or others then
    if sqlstate not in ('42501') and sqlerrm not like '%row-level security%' then
      raise exception 'expected permission error, got % (%) for: %', sqlerrm, sqlstate, p_sql;
    end if;
  end;
  if ok then raise exception 'expected permission error but it succeeded: %', p_sql; end if;
end $$;

-- 관리자 권한으로 세션의 시각을 과거로 민다(한도·자정 테스트용). 변경 방지 트리거를 잠깐 끈다.
create or replace function tt_b.backdate(p_session uuid, p_by interval) returns void language plpgsql as $$
begin
  alter table sessions disable trigger b_sessions_guard;
  update sessions set started_at = started_at - p_by,
                      paused_at = paused_at - p_by,
                      ended_at = ended_at - p_by
   where id = p_session;
  alter table sessions enable trigger b_sessions_guard;
end $$;

-- 흐름 C 의 can_view_session 이 아직 없으면 같은 계약의 임시 판을 둔다(본인 또는 친구 + 비공개 아님).
do $$
begin
  if to_regprocedure('public.can_view_session(uuid,uuid)') is null then
    execute $f$
      create function public.can_view_session(p_viewer uuid, p_session_id uuid) returns boolean
      language plpgsql stable security definer set search_path = public as $b$
      declare s sessions;
      begin
        select * into s from sessions where id = p_session_id;
        if not found then return false; end if;
        if s.user_id = p_viewer then return true; end if;
        if s.status = 'needs_confirmation' or s.visibility = 'private' then return false; end if;
        return exists (select 1 from friendships f where f.status = 'accepted'
                       and f.user_a = least(s.user_id, p_viewer) and f.user_b = greatest(s.user_id, p_viewer));
      end $b$
    $f$;
  end if;
end $$;

create or replace function tt_b.befriend(p_a uuid, p_b uuid) returns void language plpgsql as $$
begin
  insert into friendships (user_a, user_b, status, requested_by)
  values (least(p_a, p_b), greatest(p_a, p_b), 'accepted', p_a)
  on conflict do nothing;
end $$;
