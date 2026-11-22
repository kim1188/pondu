-- 흐름 B: 세션 상태 전이, 누적 집계, 종료 확인, 사진 저장소 규칙.
-- 시각은 모두 서버(now())가 정한다. 클라이언트 시각을 받는 곳은 start_session(p_offline_started_at)과
-- confirm_end(p_ended_at) 둘뿐이고, 둘 다 범위를 검사한다.

-- ── 인덱스 ──
-- list_my_sessions 의 키셋 페이지(started_at, id)와 이어가는 일별 필터.
create index if not exists sessions_user_started_id_idx on sessions (user_id, started_at desc, id desc);
create index if not exists sessions_user_thread_started_idx on sessions (user_id, thread_id, started_at desc, id desc)
  where thread_id is not null;
-- 예약 작업이 보는 진행 중 세션.
create index if not exists plan_blocks_planned_end_idx on plan_blocks (end_at) where status = 'planned';
create index if not exists sessions_active_idx on sessions (status) where status in ('live', 'paused');

-- ── 변경 방지 트리거 ──
-- 함수 밖의 경로(관리자 실수 포함)로도 시작 시각과 주인을 못 바꾸고, 끝난 세션의 시간을 못 고친다.
create or replace function b_sessions_guard() returns trigger language plpgsql as $$
begin
  if new.user_id is distinct from old.user_id
     or new.client_id is distinct from old.client_id
     or new.started_at is distinct from old.started_at
     or new.created_at is distinct from old.created_at
     or new.offline_started_at is distinct from old.offline_started_at then
    raise exception using errcode = 'P0001', message = 'forbidden';
  end if;
  if old.status = 'ended' and (
       new.status is distinct from old.status
       or new.ended_at is distinct from old.ended_at
       or new.paused_seconds is distinct from old.paused_seconds
       or new.paused_at is distinct from old.paused_at
       or new.outcome is distinct from old.outcome
       or new.primary_category is distinct from old.primary_category) then
    raise exception using errcode = 'P0001', message = 'forbidden';
  end if;
  return new;
end $$;
drop trigger if exists b_sessions_guard on sessions;
create trigger b_sessions_guard before update on sessions for each row execute function b_sessions_guard();

-- ── 내부 도우미 ──
create or replace function b_iso(p_ts timestamptz) returns text language sql immutable as $$
  select case when p_ts is null then null
         else to_char(p_ts at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') end
$$;

-- 분야별 한도(초)
create or replace function b_limit_seconds(p_category category) returns int language sql immutable as $$
  select (case p_category
    when 'study' then 4 when 'coding' then 4 when 'exercise' then 3 when 'project' then 4
    when 'venture_research_intern' then 10 when 'parttime' then 10 end) * 3600
$$;

-- 지금(또는 p_at)까지의 순수 활동 시간(초). 일시 정지 중이면 정지한 시점까지.
create or replace function b_net_seconds(p_session sessions, p_at timestamptz default now())
returns int language sql stable as $$
  select greatest(0, floor(extract(epoch from
    (case when p_session.status = 'ended' then p_session.ended_at
          when p_session.status = 'paused' then p_session.paused_at
          else p_at end) - p_session.started_at))::int - p_session.paused_seconds)
$$;

create or replace function session_json(p_session sessions) returns jsonb language plpgsql stable as $$
declare
  v_dur int;
begin
  if p_session.status = 'ended' then
    v_dur := greatest(0, floor(extract(epoch from p_session.ended_at - p_session.started_at))::int - p_session.paused_seconds);
  elsif p_session.status = 'needs_confirmation' then
    v_dur := least(b_net_seconds(p_session), b_limit_seconds(p_session.primary_category));
  else
    v_dur := b_net_seconds(p_session);
  end if;
  return jsonb_build_object(
    'id', p_session.id,
    'user_id', p_session.user_id,
    'thread_id', p_session.thread_id,
    'todo_id', p_session.todo_id,
    'plan_block_id', p_session.plan_block_id,
    'joined_session_id', p_session.joined_session_id,
    'primary_category', p_session.primary_category,
    'tags', to_jsonb(p_session.tags),
    'started_at', b_iso(p_session.started_at),
    'ended_at', b_iso(p_session.ended_at),
    'paused_at', b_iso(p_session.paused_at),
    'paused_seconds', p_session.paused_seconds,
    'duration_seconds', v_dur,
    'status', p_session.status,
    'outcome', p_session.outcome,
    'capture_mode', p_session.capture_mode,
    'photo_path', p_session.photo_path,
    'photo_thumb_path', p_session.photo_thumb_path,
    'share_title', p_session.share_title,
    'progress_note', p_session.progress_note,
    'visibility', p_session.visibility,
    'end_corrected', p_session.end_corrected,
    'offline_started_at', b_iso(p_session.offline_started_at));
end $$;

-- 시작~끝 구간을 p_tz 기준 날짜별로 나눠 순수 시간(p_net초)을 구간 길이 비율로 배분한다.
create or replace function b_split_days(p_start timestamptz, p_end timestamptz, p_net int, p_tz text)
returns table (day date, seconds int) language plpgsql stable as $$
begin
  if p_end <= p_start then
    return query select (p_start at time zone p_tz)::date, p_net;
    return;
  end if;
  return query
  with d as (
    select g::date as day,
           greatest(p_start, g::timestamp at time zone p_tz) as s,
           least(p_end, (g::date + 1)::timestamp at time zone p_tz) as e
    from generate_series((p_start at time zone p_tz)::date, (p_end at time zone p_tz)::date, interval '1 day') g
  ), w as (
    select d.day, extract(epoch from d.e - d.s) as ov from d where d.e > d.s
  ), c as (
    select w.day, sum(w.ov) over (order by w.day) as cum, sum(w.ov) over () as tot from w
  )
  select c.day,
         (round(p_net * c.cum / c.tot) - coalesce(round(p_net * lag(c.cum) over (order by c.day) / c.tot), 0))::int
  from c order by c.day;
end $$;

-- 끝난 세션을 daily_stats에 더한다(Asia/Seoul 날짜). 세션 수는 시작한 날에만 센다.
create or replace function b_apply_daily_stats(p_session sessions) returns void language plpgsql as $$
declare
  v_start_day date := (p_session.started_at at time zone 'Asia/Seoul')::date;
  v_net int := greatest(0, floor(extract(epoch from p_session.ended_at - p_session.started_at))::int - p_session.paused_seconds);
begin
  insert into daily_stats (user_id, day, primary_category, seconds, session_count)
  select p_session.user_id, s.day, p_session.primary_category, s.seconds, case when s.day = v_start_day then 1 else 0 end
  from b_split_days(p_session.started_at, p_session.ended_at, v_net, 'Asia/Seoul') s
  on conflict (user_id, day, primary_category)
  do update set seconds = daily_stats.seconds + excluded.seconds,
                session_count = daily_stats.session_count + excluded.session_count;
end $$;

-- 세션이 끝났을 때 연결된 예정 시간과 할 일을 정리한다(할 일 완료는 건드리지 않는다).
create or replace function b_finish_links(p_session sessions) returns void language plpgsql as $$
begin
  if p_session.plan_block_id is not null then
    update plan_blocks set status = 'started'
    where id = p_session.plan_block_id and user_id = p_session.user_id and status in ('planned', 'missed');
  end if;
  if p_session.todo_id is not null then
    update todos set status = 'in_progress', updated_at = now()
    where id = p_session.todo_id and user_id = p_session.user_id and status = 'open';
  end if;
end $$;

create or replace function b_log_event(p_session uuid, p_type text, p_payload jsonb default '{}') returns void
language sql as $$
  insert into session_events (session_id, type, payload) values (p_session, p_type, p_payload)
$$;

-- 내 세션을 잠그고 가져온다. 남의 세션과 없는 세션은 구분하지 않는다.
create or replace function b_my_session_locked(p_session_id uuid) returns sessions language plpgsql as $$
declare
  v sessions;
begin
  select * into v from sessions where id = p_session_id and user_id = auth.uid() for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'not_found';
  end if;
  return v;
end $$;

-- ── 공개 함수 ──
create or replace function start_session(
  p_client_id uuid,
  p_primary_category category,
  p_capture_mode capture_mode default 'no_photo',
  p_visibility visibility default 'private',
  p_thread_id uuid default null,
  p_todo_id uuid default null,
  p_plan_block_id uuid default null,
  p_tags text[] default null,
  p_share_title text default null,
  p_joined_session_id uuid default null,
  p_offline_started_at timestamptz default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := now();
  v_existing sessions;
  v_row sessions;
  v_started timestamptz := v_now;
  v_offline timestamptz;
  v_thread uuid := p_thread_id;
  v_todo uuid := p_todo_id;
  v_block uuid := p_plan_block_id;
  v_tags text[] := coalesce(p_tags, '{}');
  v_title text := nullif(btrim(p_share_title), '');
  v_joined sessions;
  v_constraint text;
  v_tmp uuid;
  v_owner uuid;
begin
  if v_uid is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;
  if p_client_id is null or p_primary_category is null then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;

  -- 같은 client_id 로 다시 부르면 기존 세션을 그대로 돌려준다.
  select * into v_existing from sessions where user_id = v_uid and client_id = p_client_id;
  if found then
    return session_json(v_existing);
  end if;

  if not exists (select 1 from profiles where id = v_uid) then
    raise exception using errcode = 'P0001', message = 'profile_required';
  end if;
  if p_visibility is null then p_visibility := 'private'; end if;
  if p_capture_mode is null then p_capture_mode := 'no_photo'; end if;
  if p_visibility in ('department', 'school') then
    raise exception using errcode = 'P0001', message = 'visibility_not_available';
  end if;
  if v_title is not null and char_length(v_title) > 60 then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  if cardinality(v_tags) > 10 or exists (select 1 from unnest(v_tags) t where t is null or char_length(t) > 30) then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;

  if exists (select 1 from sessions where user_id = v_uid and status in ('live', 'paused')) then
    raise exception using errcode = 'P0001', message = 'session_already_active';
  end if;

  -- 연결 대상은 모두 내 것이어야 한다(남의 것이면 forbidden, 없으면 not_found). 비어 있는 쪽은 연결된 쪽에서 채운다.
  if v_block is not null then
    select user_id, todo_id, coalesce(v_thread, thread_id) into v_owner, v_tmp, v_thread
      from plan_blocks where id = v_block;
    if not found then raise exception using errcode = 'P0001', message = 'not_found'; end if;
    if v_owner <> v_uid then raise exception using errcode = 'P0001', message = 'forbidden'; end if;
    v_todo := coalesce(v_todo, v_tmp);
  end if;
  if v_todo is not null then
    select user_id, coalesce(v_thread, thread_id) into v_owner, v_thread from todos where id = v_todo;
    if not found then raise exception using errcode = 'P0001', message = 'not_found'; end if;
    if v_owner <> v_uid then raise exception using errcode = 'P0001', message = 'forbidden'; end if;
  end if;
  if v_thread is not null then
    select user_id into v_owner from threads where id = v_thread;
    if not found then raise exception using errcode = 'P0001', message = 'not_found'; end if;
    if v_owner <> v_uid then raise exception using errcode = 'P0001', message = 'forbidden'; end if;
  end if;

  -- 같이 하기: 상대 세션이 진행 중이고 내가 볼 수 있어야 한다.
  if p_joined_session_id is not null then
    select * into v_joined from sessions where id = p_joined_session_id;
    if not found or v_joined.user_id = v_uid or v_joined.status not in ('live', 'paused')
       or not coalesce(can_view_session(v_uid, p_joined_session_id), false) then
      raise exception using errcode = 'P0001', message = 'join_not_allowed';
    end if;
  end if;

  -- 오프라인 시작: 과거 12시간 이내만. 이미 기록된 내 세션과 겹치면 안 된다.
  if p_offline_started_at is not null then
    v_offline := p_offline_started_at;
    if v_offline > v_now then
      if v_offline > v_now + interval '1 minute' then
        raise exception using errcode = 'P0001', message = 'invalid_input';
      end if;
      v_offline := v_now; -- 기기 시계의 작은 오차
    end if;
    if v_offline < v_now - interval '12 hours' then
      raise exception using errcode = 'P0001', message = 'invalid_input';
    end if;
    if exists (select 1 from sessions
               where user_id = v_uid and status in ('ended', 'needs_confirmation')
                 and coalesce(ended_at, v_now) > v_offline) then
      raise exception using errcode = 'P0001', message = 'invalid_input';
    end if;
    v_started := v_offline;
  end if;

  begin
    insert into sessions (user_id, client_id, thread_id, todo_id, plan_block_id, joined_session_id,
                          primary_category, tags, started_at, status, capture_mode, share_title,
                          visibility, offline_started_at, created_at)
    values (v_uid, p_client_id, v_thread, v_todo, v_block, p_joined_session_id,
            p_primary_category, v_tags, v_started, 'live', p_capture_mode, v_title,
            p_visibility, v_offline, v_now)
    returning * into v_row;
  exception when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'sessions_one_active_key' then
      raise exception using errcode = 'P0001', message = 'session_already_active';
    end if;
    select * into v_existing from sessions where user_id = v_uid and client_id = p_client_id;
    if found then return session_json(v_existing); end if;
    raise;
  end;

  perform b_log_event(v_row.id, 'start', jsonb_build_object(
    'received_at', b_iso(v_now), 'offline', v_offline is not null, 'joined_session_id', p_joined_session_id));
  if p_joined_session_id is not null then
    insert into notification_outbox (user_id, kind, payload)
    values (v_joined.user_id, 'joined',
            jsonb_build_object('session_id', v_row.id, 'user_id', v_uid));
  end if;
  return session_json(v_row);
end $$;

create or replace function pause_session(p_session_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v sessions;
begin
  if auth.uid() is null then raise exception using errcode = 'P0001', message = 'not_authenticated'; end if;
  v := b_my_session_locked(p_session_id);
  if v.status = 'paused' then return session_json(v); end if; -- 재시도
  if v.status <> 'live' then
    raise exception using errcode = 'P0001', message = 'session_not_active';
  end if;
  update sessions set status = 'paused', paused_at = now() where id = v.id returning * into v;
  perform b_log_event(v.id, 'pause');
  return session_json(v);
end $$;

create or replace function resume_session(p_session_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v sessions;
begin
  if auth.uid() is null then raise exception using errcode = 'P0001', message = 'not_authenticated'; end if;
  v := b_my_session_locked(p_session_id);
  if v.status = 'live' then return session_json(v); end if; -- 재시도
  if v.status <> 'paused' then
    raise exception using errcode = 'P0001', message = 'session_not_active';
  end if;
  update sessions
     set status = 'live',
         paused_seconds = paused_seconds + greatest(0, floor(extract(epoch from now() - paused_at))::int),
         paused_at = null
   where id = v.id returning * into v;
  perform b_log_event(v.id, 'resume');
  return session_json(v);
end $$;

-- 종료. 한도를 넘긴 채 예약 작업보다 먼저 종료를 눌러도 누적에 바로 들어가지 않고 종료 확인으로 간다.
create or replace function end_session(p_session_id uuid, p_outcome session_outcome, p_progress_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v sessions;
  v_now timestamptz := now();
  v_pause int := 0;
  v_note text := nullif(btrim(p_progress_note), '');
begin
  if auth.uid() is null then raise exception using errcode = 'P0001', message = 'not_authenticated'; end if;
  if p_outcome is null or (v_note is not null and char_length(v_note) > 200) then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  v := b_my_session_locked(p_session_id);
  -- 응답을 못 받고 다시 부른 경우: 이미 끝났으면(또는 종료 요청이 확인 대기로 갔으면) 현재 상태를 그대로 돌려준다.
  if v.status = 'ended' or (v.status = 'needs_confirmation' and v.outcome is not null) then
    return session_json(v);
  end if;
  if v.status not in ('live', 'paused') then
    raise exception using errcode = 'P0001', message = 'session_not_active';
  end if;

  if b_net_seconds(v, v_now) > b_limit_seconds(v.primary_category) then
    update sessions set status = 'needs_confirmation', outcome = p_outcome, progress_note = v_note
     where id = v.id returning * into v;
    perform b_log_event(v.id, 'needs_confirmation', jsonb_build_object(
      'reason', 'limit_at_end', 'requested_at', b_iso(v_now),
      'net_seconds', b_net_seconds(v, v_now), 'limit_seconds', b_limit_seconds(v.primary_category)));
    return session_json(v);
  end if;

  if v.status = 'paused' then
    v_pause := greatest(0, floor(extract(epoch from v_now - v.paused_at))::int);
  end if;
  update sessions
     set status = 'ended', ended_at = v_now, paused_seconds = paused_seconds + v_pause, paused_at = null,
         outcome = p_outcome, progress_note = v_note
   where id = v.id returning * into v;
  perform b_apply_daily_stats(v);
  perform b_finish_links(v);
  perform b_log_event(v.id, 'end', jsonb_build_object('outcome', p_outcome));
  return session_json(v);
end $$;

-- 종료 확인: 사용자가 종료 시각을 정한다. 시작 이후, 지금 이전, 한도 이내여야 한다.
create or replace function confirm_end(p_session_id uuid, p_ended_at timestamptz) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v sessions;
  v_now timestamptz := now();
  v_pause int;
  v_net int;
begin
  if auth.uid() is null then raise exception using errcode = 'P0001', message = 'not_authenticated'; end if;
  if p_ended_at is null then raise exception using errcode = 'P0001', message = 'invalid_input'; end if;
  v := b_my_session_locked(p_session_id);
  if v.status <> 'needs_confirmation' then
    raise exception using errcode = 'P0001', message = 'session_not_active';
  end if;
  if p_ended_at <= v.started_at or p_ended_at > v_now then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  -- 정지 중에 한도 초과로 넘어온 세션은 정지가 선택한 종료 시각까지 이어진 것으로 본다.
  v_pause := v.paused_seconds;
  if v.paused_at is not null and p_ended_at > v.paused_at then
    v_pause := v_pause + floor(extract(epoch from p_ended_at - v.paused_at))::int;
  end if;
  v_net := floor(extract(epoch from p_ended_at - v.started_at))::int - v_pause;
  if v_net > b_limit_seconds(v.primary_category) then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;

  update sessions
     set status = 'ended', ended_at = p_ended_at, paused_seconds = v_pause, paused_at = null, end_corrected = true
   where id = v.id returning * into v;
  perform b_apply_daily_stats(v);
  perform b_finish_links(v);
  perform b_log_event(v.id, 'confirm_end', jsonb_build_object(
    'ended_at', b_iso(p_ended_at), 'confirmed_at', b_iso(v_now)));
  return session_json(v);
end $$;

-- 사진 경로는 규칙대로만. 끝난 지 10분이 지난 세션에는 붙일 수 없다.
create or replace function attach_session_photo(p_session_id uuid, p_photo_path text, p_thumb_path text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v sessions;
  v_base text;
begin
  if auth.uid() is null then raise exception using errcode = 'P0001', message = 'not_authenticated'; end if;
  v := b_my_session_locked(p_session_id);
  v_base := v.user_id::text || '/' || v.id::text || '/';
  if p_photo_path is distinct from v_base || 'full.heic'
     or (p_thumb_path is not null and p_thumb_path <> v_base || 'thumb.heic')
     or v.capture_mode <> 'in_app_photo' then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  if v.status = 'ended' and v.ended_at < now() - interval '10 minutes' then
    raise exception using errcode = 'P0001', message = 'session_not_active';
  end if;
  update sessions set photo_path = p_photo_path, photo_thumb_path = coalesce(p_thumb_path, photo_thumb_path)
   where id = v.id returning * into v;
  perform b_log_event(v.id, 'photo');
  return session_json(v);
end $$;

-- 공개 범위, 공유용 제목, 진척 메모만 바꾼다. 제목과 메모는 넘긴 값으로 바뀐다(null이면 지운다). 범위가 null이면 그대로.
create or replace function update_session_share(
  p_session_id uuid, p_visibility visibility default null, p_share_title text default null, p_progress_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v sessions;
  v_title text := nullif(btrim(p_share_title), '');
  v_note text := nullif(btrim(p_progress_note), '');
begin
  if auth.uid() is null then raise exception using errcode = 'P0001', message = 'not_authenticated'; end if;
  if (v_title is not null and char_length(v_title) > 60) or (v_note is not null and char_length(v_note) > 200) then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  v := b_my_session_locked(p_session_id);
  if p_visibility in ('department', 'school') then
    raise exception using errcode = 'P0001', message = 'visibility_not_available';
  end if;
  update sessions
     set visibility = coalesce(p_visibility, visibility), share_title = v_title, progress_note = v_note
   where id = v.id returning * into v;
  perform b_log_event(v.id, 'share_update', jsonb_build_object('visibility', v.visibility));
  return session_json(v);
end $$;

create or replace function get_my_live_session() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v sessions;
begin
  if auth.uid() is null then raise exception using errcode = 'P0001', message = 'not_authenticated'; end if;
  select * into v from sessions where user_id = auth.uid() and status in ('live', 'paused');
  if not found then return null; end if;
  return session_json(v);
end $$;

create or replace function list_my_sessions(p_cursor text default null, p_limit int default 20, p_thread_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_limit int := coalesce(p_limit, 20);
  v_ts timestamptz;
  v_id uuid;
  v_parts text[];
  v_items jsonb := '[]'::jsonb;
  v_next text := null;
  v_n int := 0;
  r sessions;
  v_ts_last text;
begin
  if v_uid is null then raise exception using errcode = 'P0001', message = 'not_authenticated'; end if;
  if v_limit < 1 or v_limit > 50 then raise exception using errcode = 'P0001', message = 'invalid_input'; end if;
  if p_cursor is not null then
    begin
      v_parts := string_to_array(convert_from(decode(p_cursor, 'base64'), 'UTF8'), '|');
      v_ts := v_parts[1]::timestamptz;
      v_id := v_parts[2]::uuid;
    exception when others then
      raise exception using errcode = 'P0001', message = 'invalid_input';
    end;
    if v_ts is null or v_id is null then raise exception using errcode = 'P0001', message = 'invalid_input'; end if;
  end if;

  for r in
    select * from sessions
    where user_id = v_uid
      and (p_thread_id is null or thread_id = p_thread_id)
      and (v_ts is null or (started_at, id) < (v_ts, v_id))
    order by started_at desc, id desc
    limit v_limit + 1
  loop
    v_n := v_n + 1;
    if v_n > v_limit then
      -- 다음 페이지가 있다: 커서는 이 페이지의 마지막 항목 기준
      v_next := replace(encode(convert_to(v_ts_last, 'UTF8'), 'base64'), E'\n', '');
      exit;
    end if;
    v_items := v_items || session_json(r);
    v_ts_last := b_iso(r.started_at) || '|' || r.id::text;
  end loop;
  return jsonb_build_object('items', v_items, 'next_cursor', v_next);
end $$;

-- 기록 탭 한 화면. 날짜는 Asia/Seoul 기준(daily_stats). 다른 시간대는 invalid_input.
create or replace function get_record_summary(p_from date, p_to date, p_tz text default 'Asia/Seoul')
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_tz text := coalesce(p_tz, 'Asia/Seoul');
  v_days jsonb;
  v_cats jsonb;
  v_threads jsonb;
begin
  if v_uid is null then raise exception using errcode = 'P0001', message = 'not_authenticated'; end if;
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 366 then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  if v_tz <> 'Asia/Seoul' then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;

  with src as materialized (
    select ds.day, ds.primary_category as category, ds.seconds, ds.session_count as cnt
    from daily_stats ds
    where ds.user_id = v_uid and ds.day between p_from and p_to
  )
  select
    (select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'seconds', d.sec, 'session_count', d.cnt,
              'by_category', d.cats) order by d.day), '[]'::jsonb)
     from (select day, sum(seconds)::int sec, sum(cnt)::int cnt,
                  jsonb_agg(jsonb_build_object('category', category, 'seconds', seconds) order by seconds desc) cats
           from src group by day) d),
    (select coalesce(jsonb_agg(jsonb_build_object('category', c.category, 'seconds', c.sec) order by c.sec desc), '[]'::jsonb)
     from (select category, sum(seconds)::int sec from src group by category) c)
  into v_days, v_cats;

  select coalesce(jsonb_agg(jsonb_build_object('thread_id', t.thread_id, 'title', t.title, 'seconds', t.sec,
           'last_at', b_iso(t.last_at)) order by t.sec desc), '[]'::jsonb) into v_threads
  from (select s.thread_id, th.title,
               sum(greatest(0, floor(extract(epoch from s.ended_at - s.started_at))::int - s.paused_seconds))::int sec,
               max(s.ended_at) last_at
        from sessions s join threads th on th.id = s.thread_id and th.user_id = s.user_id
        where s.user_id = v_uid and s.status = 'ended' and s.thread_id is not null
          and s.started_at >= (p_from::timestamp at time zone v_tz)
          and s.started_at < ((p_to + 1)::timestamp at time zone v_tz)
        group by s.thread_id, th.title
        order by sec desc limit 50) t;

  return jsonb_build_object('days', v_days, 'by_category', v_cats, 'threads', v_threads);
end $$;

-- 예약 작업: 한도를 넘긴 진행 중 세션을 종료 확인 대기로 바꾼다. 바뀐 행 수를 돌려준다.
create or replace function sweep_stale_sessions() returns int
language plpgsql security definer set search_path = public as $$
declare
  v_n int;
  v_m int;
begin
  with hit as (
    update sessions s set status = 'needs_confirmation'
    where s.status in ('live', 'paused') and b_net_seconds(s) > b_limit_seconds(s.primary_category)
    returning s.id, b_net_seconds(s) as net, b_limit_seconds(s.primary_category) as lim
  ), ev as (
    insert into session_events (session_id, type, payload)
    select id, 'needs_confirmation', jsonb_build_object('reason', 'limit_sweep', 'net_seconds', net, 'limit_seconds', lim)
    from hit returning 1
  )
  select count(*) into v_n from hit;

  -- 끝 시각이 지났는데 시작하지 않은 예정 시간은 놓친 것으로 본다(세션이 연결된 블록은 제외).
  with miss as (
    update plan_blocks b set status = 'missed'
    where b.status = 'planned' and b.end_at < now()
      and not exists (select 1 from sessions s where s.plan_block_id = b.id)
    returning 1
  )
  select count(*) into v_m from miss;
  return v_n + v_m;
end $$;

-- ── 실행 권한 ──
do $$
declare
  r record;
begin
  for r in select p.oid::regprocedure as sig, p.proname from pg_proc p
           where p.pronamespace = 'public'::regnamespace
             and p.proname in ('b_sessions_guard', 'b_iso', 'b_limit_seconds', 'b_net_seconds', 'session_json', 'b_split_days',
                               'b_apply_daily_stats', 'b_finish_links', 'b_log_event', 'b_my_session_locked',
                               'sweep_stale_sessions') loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
  end loop;
  for r in select p.oid::regprocedure as sig from pg_proc p
           where p.pronamespace = 'public'::regnamespace
             and p.proname in ('start_session', 'pause_session', 'resume_session', 'end_session', 'confirm_end',
                               'attach_session_photo', 'update_session_share', 'get_my_live_session',
                               'list_my_sessions', 'get_record_summary') loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end $$;

-- ── 사진 저장소(Supabase 에만 있다. storage 가 없으면 건너뛴다) ──
-- 경로: {user_id}/{session_id}/full.heic, thumb.heic
create or replace function b_photo_parts(p_name text) returns text[] language sql immutable as $$
  select regexp_match(p_name, '^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/(full|thumb)\.heic$')
$$;

-- 올리기: 내 폴더, 내 세션, 정해진 파일 이름만.
create or replace function b_can_upload_photo(p_name text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  v text[] := b_photo_parts(p_name);
begin
  if auth.uid() is null or v is null or v[1] <> auth.uid()::text then return false; end if;
  return exists (select 1 from sessions where id = v[2]::uuid and user_id = auth.uid());
end $$;

-- 읽기: 내 것이거나, 그 세션의 주인 폴더이면서 can_view_session 이 참일 때.
create or replace function b_can_read_photo(p_name text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  v text[] := b_photo_parts(p_name);
begin
  if auth.uid() is null or v is null then return false; end if;
  if v[1] = auth.uid()::text then return true; end if;
  if not exists (select 1 from sessions where id = v[2]::uuid and user_id = v[1]::uuid) then return false; end if;
  return coalesce(can_view_session(auth.uid(), v[2]::uuid), false);
end $$;

revoke all on function b_photo_parts(text) from public, anon;
revoke all on function b_can_upload_photo(text), b_can_read_photo(text) from public, anon;
grant execute on function b_photo_parts(text), b_can_upload_photo(text), b_can_read_photo(text) to authenticated;

do $$
begin
  if to_regclass('storage.buckets') is null or to_regclass('storage.objects') is null then
    raise notice 'storage 스키마가 없어 사진 저장소 규칙을 건너뜁니다';
    return;
  end if;

  insert into storage.buckets (id, name, public) values ('session-photos', 'session-photos', false)
  on conflict (id) do update set public = false;
  if exists (select 1 from information_schema.columns
             where table_schema = 'storage' and table_name = 'buckets' and column_name = 'file_size_limit') then
    execute 'update storage.buckets set file_size_limit = 10485760 where id = ''session-photos''';
  end if;

  drop policy if exists session_photos_insert on storage.objects;
  drop policy if exists session_photos_select on storage.objects;
  drop policy if exists session_photos_delete on storage.objects;
  create policy session_photos_insert on storage.objects for insert to authenticated
    with check (bucket_id = 'session-photos' and public.b_can_upload_photo(name));
  create policy session_photos_select on storage.objects for select to authenticated
    using (bucket_id = 'session-photos' and public.b_can_read_photo(name));
  create policy session_photos_delete on storage.objects for delete to authenticated
    using (bucket_id = 'session-photos' and split_part(name, '/', 1) = auth.uid()::text);
end $$;

-- ── 예약 등록(pg_cron 이 있을 때만, 10분마다) ──
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron')
     and exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    begin
      create extension pg_cron;
    exception when others then
      raise notice 'pg_cron 을 켤 수 없습니다: %', sqlerrm;
    end;
  end if;
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    execute $q$select cron.schedule('sweep-stale-sessions', '*/10 * * * *', 'select public.sweep_stale_sessions()')$q$;
  else
    raise notice 'pg_cron 이 없어 예약 등록을 건너뜁니다';
  end if;
exception when others then
  raise notice '예약 등록 실패: %', sqlerrm;
end $$;
