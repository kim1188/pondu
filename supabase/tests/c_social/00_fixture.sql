-- 흐름 C 테스트 공용 도우미. 다른 파일이 쓴다(파일 이름 순서로 먼저 돈다).
-- profile_card는 흐름 A가 만든다. 아직 없으면 같은 모양으로 임시로 만든다.
do $$
begin
  if to_regprocedure('public.profile_card(uuid)') is null then
    execute $f$
      create function public.profile_card(p_user uuid) returns jsonb language plpgsql stable
      security definer set search_path = public as $b$
      begin
        return (select jsonb_build_object('id', p.id, 'handle', p.handle, 'display_name', p.display_name,
                  'avatar_path', p.avatar_path, 'department_name', d.name)
                from profiles p left join departments d on d.id = p.department_id where p.id = p_user);
      end $b$
    $f$;
  end if;
end $$;

create or replace function c_t_school(p_name text default 'c_t_school') returns uuid language plpgsql as $$
declare s uuid;
begin
  insert into schools (name, email_domains) values (p_name || gen_random_uuid(), array['x.test']) returning id into s;
  return s;
end $$;

create or replace function c_t_user(p_handle text, p_school uuid) returns uuid language plpgsql as $$
declare u uuid := gen_random_uuid();
begin
  insert into auth.users (id, email) values (u, u || '@x.test');
  insert into profiles (id, school_id, handle, display_name)
  values (u, p_school, left(p_handle || '_' || substr(u::text, 1, 6), 20), p_handle);
  return u;
end $$;

-- 세션 직접 삽입(관리자 권한에서). 흐름 B 함수에 기대지 않는다.
create or replace function c_t_session(p_user uuid, p_vis visibility, p_status session_status default 'ended',
  p_started timestamptz default now() - interval '1 hour', p_title text default null,
  p_thread uuid default null, p_joined uuid default null) returns uuid language plpgsql as $$
declare s uuid;
begin
  insert into sessions (user_id, client_id, primary_category, started_at, ended_at, status, visibility,
                        share_title, thread_id, joined_session_id, paused_at)
  values (p_user, gen_random_uuid(), 'study', p_started,
          case when p_status in ('ended', 'needs_confirmation') then p_started + interval '30 minutes' end,
          p_status, p_vis, p_title, p_thread, p_joined,
          case when p_status = 'paused' then p_started + interval '10 minutes' end)
  returning id into s;
  return s;
end $$;

create or replace function c_t_friends(a uuid, b uuid) returns void language sql as $$
  insert into friendships (user_a, user_b, status, requested_by)
  values (least(a, b), greatest(a, b), 'accepted', a)
$$;

-- 현재 역할로 문장을 실행해 P0001 오류 코드가 기대와 같은지 본다.
create or replace function c_t_err(p_sql text, p_code text) returns void language plpgsql as $$
declare m text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics m = message_text;
    if m <> p_code then raise exception '기대 오류 % 인데 실제 %: %', p_code, m, p_sql; end if;
    return;
  end;
  raise exception '오류 % 가 나야 하는데 성공함: %', p_code, p_sql;
end $$;

create or replace function c_t_ids(p_page jsonb) returns uuid[] language sql immutable as $$
  select coalesce(array_agg((i ->> 'session_id')::uuid order by ord), '{}')
  from jsonb_array_elements(p_page -> 'items') with ordinality t(i, ord)
$$;
