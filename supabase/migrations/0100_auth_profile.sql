-- 흐름 A: 가입 도메인 제한, 프로필, 학과, 기기 토큰, 프로필 검색
-- 접근 규칙: 앱은 테이블을 직접 읽거나 쓰지 않는다(0001 의 기본 거부를 그대로 둔다). 모든 접근은 아래 함수로만.

-- ── 인덱스 ──
-- 프로필 검색(같은 학교 안에서 아이디/이름 앞부분 일치)
create index if not exists profiles_handle_prefix_idx on profiles (school_id, lower(handle) text_pattern_ops);
create index if not exists profiles_name_prefix_idx on profiles (school_id, lower(display_name) text_pattern_ops);
-- 기기 토큰은 같은 토큰을 다른 계정에서 지울 때 토큰으로 찾는다
create index if not exists device_tokens_token_idx on device_tokens (token);

-- ── 가입 도메인 제한 ──

-- 메일 주소 → 학교. 학교가 없으면 null. 소문자로 바꾼 뒤 도메인이 정확히 일치할 때만 찾는다.
-- 주소는 "@"가 정확히 하나이고 공백이 없는 형태여야 한다(korea.ac.kr@evil.com, a@evil.com@korea.ac.kr 거절).
create or replace function public.email_school_id(p_email text)
returns uuid language sql stable security definer set search_path = public as $$
  select s.id
  from schools s
  where p_email ~ '^[^@[:space:]]+@[^@[:space:]]+$'
    and exists (
      select 1 from unnest(s.email_domains) d
      where lower(d) = lower(substring(p_email from '@([^@]+)$'))
    )
  order by s.created_at, s.id
  limit 1
$$;

-- auth.users 삽입·메일 수정 트리거(인증 서비스의 훅을 쓸 수 없을 때의 대안이자 이중 방어)
create or replace function public.enforce_signup_domain()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.email is not distinct from old.email then
    return new;
  end if;
  if public.email_school_id(new.email) is null then
    raise exception using errcode = 'P0001', message = 'email_domain_not_allowed',
      hint = '고려대학교 메일(@korea.ac.kr)만 가입할 수 있어요.';
  end if;
  return new;
end $$;

-- Supabase 인증 서비스의 "사용자 생성 전(before user created)" 훅.
-- 대시보드/config.toml 에서 public.hook_before_user_created 를 지정한다.
create or replace function public.hook_before_user_created(event jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if public.email_school_id(event #>> '{user,email}') is null then
    return jsonb_build_object('error', jsonb_build_object(
      'http_code', 400,
      'message', '고려대학교 메일(@korea.ac.kr)만 가입할 수 있어요.'));
  end if;
  return '{}'::jsonb;
end $$;

do $$
begin
  -- 일반 Postgres 테스트 DB에서는 auth.users 가 흉내 테이블이다. 실제 Supabase 에도 있다.
  if to_regclass('auth.users') is not null then
    drop trigger if exists enforce_signup_domain on auth.users;
    create trigger enforce_signup_domain
      before insert or update of email on auth.users
      for each row execute function public.enforce_signup_domain();
  end if;
end $$;

-- ── 내부 도우미 ──

-- 현재 로그인 사용자의 학교(메일 도메인으로 정한다). 로그인하지 않았으면 not_authenticated.
create or replace function public.my_school_id()
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_school uuid;
begin
  if v_uid is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;
  select public.email_school_id(u.email) into v_school from auth.users u where u.id = v_uid;
  if v_school is null then
    raise exception using errcode = 'P0001', message = 'email_domain_not_allowed';
  end if;
  return v_school;
end $$;

-- ProfileCard {id, handle, display_name, avatar_path, department_name}. 다른 흐름이 쓴다. 없는 사용자는 null.
create or replace function public.profile_card(p_user uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', p.id, 'handle', p.handle, 'display_name', p.display_name,
    'avatar_path', p.avatar_path, 'department_name', d.name)
  from profiles p left join departments d on d.id = p.department_id
  where p.id = p_user
$$;

create or replace function public.profile_json(p_user uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', p.id, 'handle', p.handle, 'display_name', p.display_name,
    'avatar_path', p.avatar_path, 'department_name', d.name,
    'school_id', p.school_id, 'department_id', p.department_id)
  from profiles p left join departments d on d.id = p.department_id
  where p.id = p_user
$$;

-- ── 공개 함수 ──

create or replace function public.get_my_profile()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception using errcode = 'P0001', message = 'not_authenticated'; end if;
  return public.profile_json(v_uid);   -- 없으면 null
end $$;

create or replace function public.is_handle_available(p_handle text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); h text;
begin
  if v_uid is null then raise exception using errcode = 'P0001', message = 'not_authenticated'; end if;
  h := lower(p_handle);
  if h is null or h !~ '^[a-z0-9_]{3,20}$' then return false; end if;
  return not exists (select 1 from profiles where lower(handle) = h and id <> v_uid);
end $$;

create or replace function public.upsert_my_profile(p_handle text, p_display_name text, p_department_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_school uuid; h text; n text;
begin
  if v_uid is null then raise exception using errcode = 'P0001', message = 'not_authenticated'; end if;
  v_school := public.my_school_id();                  -- 학교는 입력받지 않고 메일 도메인으로 정한다

  h := lower(p_handle);
  if h is null or h !~ '^[a-z0-9_]{3,20}$' then
    raise exception using errcode = 'P0001', message = 'handle_invalid';
  end if;
  n := regexp_replace(coalesce(p_display_name, ''), '^\s+|\s+$', '', 'g');
  if char_length(n) < 1 or char_length(n) > 20 then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  if p_department_id is not null
     and not exists (select 1 from departments where id = p_department_id and school_id = v_school) then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  if exists (select 1 from profiles where lower(handle) = h and id <> v_uid) then
    raise exception using errcode = 'P0001', message = 'handle_taken';
  end if;

  begin
    insert into profiles (id, school_id, handle, display_name, department_id)
    values (v_uid, v_school, h, n, p_department_id)
    on conflict (id) do update
      set handle = excluded.handle, display_name = excluded.display_name,
          department_id = excluded.department_id, updated_at = now();
  exception when unique_violation then          -- 동시에 같은 아이디를 잡은 경우
    raise exception using errcode = 'P0001', message = 'handle_taken';
  end;
  return public.profile_json(v_uid);
end $$;

create or replace function public.list_departments()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_school uuid;
begin
  v_school := public.my_school_id();
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name) order by d.name)
    from departments d where d.school_id = v_school), '[]'::jsonb);
end $$;

-- 같은 학교, 아이디 앞부분 또는 이름 앞부분 일치(대소문자 무시), 본인과 차단 관계(어느 방향이든) 제외.
create or replace function public.search_profiles(p_query text, p_limit int)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_school uuid; q text; v_limit int; r jsonb;
begin
  if v_uid is null then raise exception using errcode = 'P0001', message = 'not_authenticated'; end if;
  select school_id into v_school from profiles where id = v_uid;
  if v_school is null then raise exception using errcode = 'P0001', message = 'profile_required'; end if;

  q := lower(regexp_replace(coalesce(p_query, ''), '^\s+|\s+$', '', 'g'));
  if q = '' then return '[]'::jsonb; end if;
  q := replace(replace(replace(q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  v_limit := least(greatest(coalesce(p_limit, 20), 1), 50);

  select coalesce(jsonb_agg(c.card order by c.h, c.id), '[]'::jsonb) into r
  from (
    select p.id, lower(p.handle) as h,
           jsonb_build_object('id', p.id, 'handle', p.handle, 'display_name', p.display_name,
                              'avatar_path', p.avatar_path, 'department_name', d.name) as card
    from profiles p
    left join departments d on d.id = p.department_id
    where p.school_id = v_school
      and p.id <> v_uid
      and (lower(p.handle) like q escape '\' or lower(p.display_name) like q escape '\')
      and not exists (
        select 1 from blocks b
        where (b.blocker_id = v_uid and b.blocked_id = p.id)
           or (b.blocker_id = p.id and b.blocked_id = v_uid))
    order by lower(p.handle), p.id
    limit v_limit
  ) c;
  return r;
end $$;

create or replace function public.register_device_token(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); t text;
begin
  if v_uid is null then raise exception using errcode = 'P0001', message = 'not_authenticated'; end if;
  t := regexp_replace(coalesce(p_token, ''), '^\s+|\s+$', '', 'g');
  if t = '' or char_length(t) > 512 then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  if not exists (select 1 from profiles where id = v_uid) then
    raise exception using errcode = 'P0001', message = 'profile_required';
  end if;
  -- 같은 기기에서 계정을 바꿔 로그인하면 이전 계정으로 알림이 가지 않게 한다
  delete from device_tokens where token = t and user_id <> v_uid;
  insert into device_tokens (user_id, token) values (v_uid, t) on conflict do nothing;
  return null;
end $$;

-- ── 실행 권한 ──
-- 기본으로 열려 있는 실행 권한을 모두 거두고, 앱이 부르는 함수에만 authenticated 를 준다.
do $$
declare f text;
begin
  foreach f in array array[
    'email_school_id(text)', 'enforce_signup_domain()', 'hook_before_user_created(jsonb)',
    'my_school_id()', 'profile_card(uuid)', 'profile_json(uuid)',
    'get_my_profile()', 'is_handle_available(text)', 'upsert_my_profile(text, text, uuid)',
    'list_departments()', 'search_profiles(text, int)', 'register_device_token(text)'
  ] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array[
    'get_my_profile()', 'is_handle_available(text)', 'upsert_my_profile(text, text, uuid)',
    'list_departments()', 'search_profiles(text, int)', 'register_device_token(text)'
  ] loop
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  -- 인증 서비스가 훅을 부른다(Supabase 에만 있는 역할)
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
  end if;
end $$;
