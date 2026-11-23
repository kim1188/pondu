-- CONTRACT-ADDENDUM의 보정 2를 이미 배포된 DB에 순서대로 적용한다.
-- 0001/0200/0300/0400은 운영에 처음 적용된 내용과 일치하게 유지한다.
set local lock_timeout = '3s';

alter table public.threads
  add column if not exists default_group_id uuid constraint threads_default_group_fkey references public.groups on delete set null;
alter table public.sessions
  add column if not exists group_id uuid constraint sessions_group_fkey references public.groups on delete set null;
create index if not exists sessions_group_idx on public.sessions (group_id, started_at desc) where group_id is not null;

create table if not exists public.friend_request_rejections (
  requester_id uuid not null references public.profiles on delete cascade,
  target_id uuid not null references public.profiles on delete cascade,
  rejected_at timestamptz not null default now(),
  primary key (requester_id, target_id)
);
create index if not exists friend_request_rejections_target_idx on public.friend_request_rejections (target_id);
alter table public.friend_request_rejections enable row level security;
revoke all on public.friend_request_rejections from public, anon, authenticated;

-- 기본값이 있는 새 인자와 이전 인자 목록이 함께 있으면 쿼리가 모호해진다.
-- 기존 호출은 새 인자의 null 기본값으로 계속 동작한다.
drop function if exists public.start_session(uuid, category, capture_mode, visibility, uuid, uuid, uuid, text[], text, uuid, timestamptz);
drop function if exists public.update_session_share(uuid, visibility, text, text);
drop function if exists public.create_thread(text, category, text, visibility);

-- 크루 공개 및 친구 요청
-- Supabase의 pgcrypto는 extensions에, 일반 Postgres에서는 public에 있다.
alter function public.create_crew(text) set search_path to public, extensions;

create or replace function social_in_crew(p_user uuid, p_group uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_group is not null and exists (
    select 1
    from group_members m
    join groups g on g.id = m.group_id and g.kind = 'crew'
    where m.group_id = p_group and m.user_id = p_user and m.status = 'active'
  )
$$;

create or replace function can_view_session(p_viewer uuid, p_session_id uuid) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare s sessions%rowtype; friend boolean;
begin
  select * into s from sessions where id = p_session_id;
  if not found then return false; end if;
  if s.user_id = p_viewer then return true; end if;
  if s.status = 'needs_confirmation' then return false; end if;
  if s.visibility not in ('friends', 'crew') then return false; end if;
  if social_is_blocked(p_viewer, s.user_id) then return false; end if;
  if exists (select 1 from reports where reporter_id = p_viewer and session_id = s.id) then
    return false;
  end if;
  friend := social_are_friends(p_viewer, s.user_id);
  if s.visibility = 'friends' then return friend; end if;
  return friend or (social_in_crew(p_viewer, s.group_id) and social_in_crew(s.user_id, s.group_id));
end $$;

create or replace function send_friend_request(p_user_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := social_uid(); f friendships%rowtype;
begin
  perform social_school(me);
  if p_user_id is null or p_user_id = me then perform social_err('invalid_input'); end if;
  if not exists (select 1 from profiles where id = p_user_id) then perform social_err('not_found'); end if;
  -- 내가 차단한 상대에게만 blocked. 상대가 나를 차단했으면 드러나지 않게 아무 일 없이 성공한다.
  if exists (select 1 from blocks where blocker_id = me and blocked_id = p_user_id) then
    perform social_err('blocked');
  end if;
  if exists (select 1 from blocks where blocker_id = p_user_id and blocked_id = me) then
    return null;
  end if;

  select * into f from friendships
   where user_a = least(me, p_user_id) and user_b = greatest(me, p_user_id);
  if found then
    if f.status = 'accepted' then perform social_err('already_friends'); end if;
    if f.requested_by = me then return null; end if;      -- 이미 보냄: 그대로 둔다
    -- 상대가 먼저 보냈으면 곧 수락으로 본다
    update friendships set status = 'accepted' where user_a = f.user_a and user_b = f.user_b;
    delete from friend_request_rejections where requester_id in (me, p_user_id) and target_id in (me, p_user_id);
    perform social_notify(p_user_id, 'friend_accepted', jsonb_build_object('user_id', me));
    return null;
  end if;

  -- 거절당한 지 7일이 안 지났으면 다시 보낼 수 없다.
  if exists (select 1 from friend_request_rejections
              where requester_id = me and target_id = p_user_id
                and rejected_at > now() - interval '7 days') then
    perform social_err('rate_limited');
  end if;

  insert into friendships (user_a, user_b, status, requested_by)
  values (least(me, p_user_id), greatest(me, p_user_id), 'pending', me);
  perform social_notify(p_user_id, 'friend_request', jsonb_build_object('user_id', me));
  return null;
end $$;

create or replace function respond_friend_request(p_user_id uuid, p_accept boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := social_uid(); n int;
begin
  if p_user_id is null or p_accept is null then perform social_err('invalid_input'); end if;
  if social_is_blocked(me, p_user_id) then perform social_err('request_not_found'); end if;
  if p_accept then
    update friendships set status = 'accepted'
     where user_a = least(me, p_user_id) and user_b = greatest(me, p_user_id)
       and status = 'pending' and requested_by = p_user_id;
    get diagnostics n = row_count;
    if n = 0 then perform social_err('request_not_found'); end if;
    delete from friend_request_rejections where requester_id in (me, p_user_id) and target_id in (me, p_user_id);
    perform social_notify(p_user_id, 'friend_accepted', jsonb_build_object('user_id', me));
  else
    delete from friendships
     where user_a = least(me, p_user_id) and user_b = greatest(me, p_user_id)
       and status = 'pending' and requested_by = p_user_id;
    get diagnostics n = row_count;
    if n = 0 then perform social_err('request_not_found'); end if;
    insert into friend_request_rejections (requester_id, target_id) values (p_user_id, me)
    on conflict (requester_id, target_id) do update set rejected_at = now();
  end if;
  return null;
end $$;

create or replace function rotate_invite_code(p_group_id uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare me uuid := social_uid(); code text;
begin
  if p_group_id is null then perform social_err('invalid_input'); end if;
  if not exists (select 1 from group_members
                  where group_id = p_group_id and user_id = me and status = 'active' and role = 'owner') then
    perform social_err('forbidden');
  end if;
  perform 1 from groups where id = p_group_id for update;
  loop
    code := upper(encode(gen_random_bytes(8), 'hex'));
    begin
      update groups set invite_code = code where id = p_group_id;
      exit;
    exception when unique_violation then null;
    end;
  end loop;
  return social_crew_json(p_group_id, me);
end $$;

create or replace function social_feed_cards(p_viewer uuid, p_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  return (
  with rx as (
    select r.session_id, count(*) as cnt, max(r.kind) filter (where r.user_id = p_viewer) as mine
    from reactions r
    where r.session_id = any (p_ids)
      and not exists (select 1 from blocks b
                       where (b.blocker_id = p_viewer and b.blocked_id = r.user_id)
                          or (b.blocker_id = r.user_id and b.blocked_id = p_viewer))
    group by r.session_id
  ), cm as (
    select c.session_id, count(*) as cnt
    from comments c
    where c.session_id = any (p_ids)
      and not exists (select 1 from blocks b
                       where (b.blocker_id = p_viewer and b.blocked_id = c.user_id)
                          or (b.blocker_id = c.user_id and b.blocked_id = p_viewer))
    group by c.session_id
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'session_id', s.id,
      'author', profile_card(s.user_id),
      'thread_id', s.thread_id,
      'group_id', gr.gid,
      'group_name', gr.gname,
      'share_title', s.share_title,
      'primary_category', s.primary_category,
      'started_at', social_iso(s.started_at),
      'ended_at', social_iso(s.ended_at),
      'status', s.status,
      'duration_seconds', greatest(0, (extract(epoch from (
          case when s.ended_at is not null then s.ended_at
               when s.paused_at is not null then s.paused_at
               else now() end - s.started_at))::bigint - s.paused_seconds)),
      'progress_note', s.progress_note,
      'photo_path', s.photo_path,
      'photo_thumb_path', s.photo_thumb_path,
      'capture_mode', s.capture_mode,
      'end_corrected', s.end_corrected,
      'offline_started', s.offline_started_at is not null,
      'joined_with', case when s.joined_session_id is not null
                           and can_view_session(p_viewer, s.joined_session_id)
                          then (select profile_card(js.user_id) from sessions js where js.id = s.joined_session_id)
                          else null end,
      'reaction_count', coalesce(rx.cnt, 0),
      'my_reaction', rx.mine,
      'comment_count', coalesce(cm.cnt, 0)
    ) order by o.ord), '[]'::jsonb)
  from unnest(p_ids) with ordinality as o(id, ord)
  join sessions s on s.id = o.id
  left join rx on rx.session_id = s.id
  left join cm on cm.session_id = s.id
  -- 크루 이름은 그 크루의 구성원에게만 보인다(친구에게는 드러나지 않는다)
  left join lateral (
    select g.id as gid, g.name as gname from groups g
    where g.id = s.group_id and s.visibility = 'crew' and social_in_crew(p_viewer, g.id)
  ) gr on true
  );
end $$;

create or replace function get_feed(p_cursor text, p_limit int, p_group_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := social_uid();
  lim int := coalesce(p_limit, 20);
  c_rank int; c_ts timestamptz; c_id uuid;
  grp boolean := p_group_id is not null;
  mine uuid[];
  ids uuid[]; page uuid[]; nxt text; last_s sessions%rowtype;
begin
  if lim < 1 or lim > 50 then perform social_err('invalid_input'); end if;
  if p_cursor is not null then
    begin
      c_rank := split_part(p_cursor, '|', 1)::int;
      c_ts := timestamptz 'epoch' + (split_part(p_cursor, '|', 2)::bigint) * interval '1 microsecond';
      c_id := split_part(p_cursor, '|', 3)::uuid;
      if c_rank not in (0, 1) then raise exception 'bad'; end if;
    exception when others then
      perform social_err('invalid_input');
    end;
  end if;
  if grp and not exists (select 1 from group_members
                          where group_id = p_group_id and user_id = me and status = 'active') then
    perform social_err('forbidden');
  end if;

  select coalesce(array_agg(m.group_id), '{}') into mine
    from group_members m join groups g on g.id = m.group_id and g.kind = 'crew'
   where m.user_id = me and m.status = 'active';

  with authors as (
    select uid, bool_or(is_friend) as is_friend
    from (
      select case when f.user_a = me then f.user_b else f.user_a end as uid, true as is_friend
        from friendships f
       where not grp and f.status = 'accepted' and (f.user_a = me or f.user_b = me)
      union all
      select me, true where not grp
      union all
      select m2.user_id, false
        from group_members m1
        join groups g on g.id = m1.group_id and g.kind = 'crew'
        join group_members m2 on m2.group_id = m1.group_id and m2.status = 'active'
       where not grp and m1.user_id = me and m1.status = 'active'
      union all
      select m.user_id, false
        from group_members m
       where grp and m.group_id = p_group_id and m.status = 'active'
    ) a
    where a.uid = me or not exists (
      select 1 from blocks b
       where (b.blocker_id = me and b.blocked_id = a.uid) or (b.blocker_id = a.uid and b.blocked_id = me))
    group by uid
  ), live_part as (
    select s.id, 0 as rk, s.started_at
    from authors a
    cross join lateral (
      select s.id, s.started_at from sessions s
      where s.user_id = a.uid
        and s.visibility in ('friends', 'crew') and s.status <> 'needs_confirmation'
        and s.status in ('live', 'paused')
        and case when grp then s.visibility = 'crew' and s.group_id = p_group_id
                 else (s.visibility = 'friends' and a.is_friend)
                   or (s.visibility = 'crew'
                       and (a.is_friend or (s.group_id = any (mine) and social_in_crew(s.user_id, s.group_id))))
            end
        and (c_rank is null or c_rank = 0) and (c_ts is null or (s.started_at, s.id) < (c_ts, c_id))
        and not exists (select 1 from reports r where r.reporter_id = me and r.session_id = s.id)
      order by s.started_at desc, s.id desc
      limit lim + 1
    ) s
  ), ended_part as (
    select s.id, 1 as rk, s.started_at
    from authors a
    cross join lateral (
      select s.id, s.started_at from sessions s
      where s.user_id = a.uid
        and s.visibility in ('friends', 'crew') and s.status <> 'needs_confirmation'
        and s.status = 'ended'
        and case when grp then s.visibility = 'crew' and s.group_id = p_group_id
                 else (s.visibility = 'friends' and a.is_friend)
                   or (s.visibility = 'crew'
                       and (a.is_friend or (s.group_id = any (mine) and social_in_crew(s.user_id, s.group_id))))
            end
        and (c_rank is null or c_rank = 0 or (s.started_at, s.id) < (c_ts, c_id))
        and not exists (select 1 from reports r where r.reporter_id = me and r.session_id = s.id)
      order by s.started_at desc, s.id desc
      limit lim + 1
    ) s
  )
  select coalesce(array_agg(x.id order by x.rk, x.started_at desc, x.id desc), '{}') into ids
  from (
    select * from (select * from live_part union all select * from ended_part) u
    order by u.rk, u.started_at desc, u.id desc
    limit lim + 1
  ) x;

  if coalesce(array_length(ids, 1), 0) > lim then
    page := ids[1:lim];
    select * into last_s from sessions where id = page[lim];
    nxt := (case when last_s.status in ('live', 'paused') then 0 else 1 end)::text || '|'
        || (extract(epoch from last_s.started_at) * 1000000)::bigint::text || '|' || last_s.id::text;
  else
    page := ids;
  end if;
  return jsonb_build_object('items', social_feed_cards(me, page), 'next_cursor', nxt);
end $$;

create or replace function get_thread_history(p_session_id uuid, p_limit int) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := social_uid(); lim int := coalesce(p_limit, 20);
  s sessions%rowtype; ids uuid[];
begin
  if lim < 1 or lim > 50 then perform social_err('invalid_input'); end if;
  if not can_view_session(me, p_session_id) then perform social_err('not_found'); end if;
  select * into s from sessions where id = p_session_id;
  if s.thread_id is null then return '[]'::jsonb; end if;
  select coalesce(array_agg(x.id order by x.started_at desc, x.id desc), '{}') into ids
  from (
    select t.id, t.started_at from sessions t
    where t.user_id = s.user_id and t.thread_id = s.thread_id and t.id <> s.id
      and (me = s.user_id or can_view_session(me, t.id))
    order by t.started_at desc, t.id desc
    limit lim
  ) x;
  return social_feed_cards(me, ids);
end $$;

-- 세션 시작 및 공유 범위
create or replace function session_json(p_session sessions) returns jsonb language plpgsql stable as $$
declare
  v_dur int;
begin
  if p_session.status = 'ended' then
    v_dur := greatest(0, floor(extract(epoch from p_session.ended_at - p_session.started_at))::int - p_session.paused_seconds);
  elsif p_session.status = 'needs_confirmation' then
    v_dur := null;
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
    'group_id', p_session.group_id,
    'end_corrected', p_session.end_corrected,
    'offline_started_at', b_iso(p_session.offline_started_at));
end $$;

create or replace function b_resolve_group(p_user uuid, p_vis visibility, p_group uuid, p_thread uuid, p_current uuid default null)
returns uuid language plpgsql stable set search_path = public as $$
declare
  v_g uuid;
  v_n int;
begin
  if p_vis is distinct from 'crew' then return null; end if;
  if p_group is not null then
    if not exists (select 1 from group_members m join groups g on g.id = m.group_id and g.kind = 'crew'
                    where m.group_id = p_group and m.user_id = p_user and m.status = 'active') then
      raise exception using errcode = 'P0001', message = 'not_found';
    end if;
    return p_group;
  end if;
  for v_g in
    select c from (select p_current as c, 1 as o
                   union all
                   select default_group_id, 2 from threads where id = p_thread and user_id = p_user) x
    where c is not null order by o
  loop
    if exists (select 1 from group_members m join groups g on g.id = m.group_id and g.kind = 'crew'
                where m.group_id = v_g and m.user_id = p_user and m.status = 'active') then
      return v_g;
    end if;
  end loop;
  select count(*), min(m.group_id::text)::uuid into v_n, v_g
    from group_members m join groups g on g.id = m.group_id and g.kind = 'crew'
   where m.user_id = p_user and m.status = 'active';
  if v_n = 1 then return v_g; end if;
  raise exception using errcode = 'P0001', message = 'invalid_input';
end $$;

create or replace function start_session(
  p_client_id uuid,
  p_primary_category category,
  p_capture_mode capture_mode default null,
  p_visibility visibility default null,
  p_thread_id uuid default null,
  p_todo_id uuid default null,
  p_plan_block_id uuid default null,
  p_tags text[] default null,
  p_share_title text default null,
  p_joined_session_id uuid default null,
  p_offline_started_at timestamptz default null,
  p_group_id uuid default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_group uuid;
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
  v_thread_vis visibility;
  v_vis visibility;
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
  if p_visibility in ('department', 'school') then
    raise exception using errcode = 'P0001', message = 'visibility_not_available';
  end if;
  if p_capture_mode is null then p_capture_mode := 'no_photo'; end if;
  if v_title is not null and char_length(v_title) > 60 then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  if cardinality(v_tags) > 10 or exists (select 1 from unnest(v_tags) t where t is null or char_length(t) > 30) then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;

  if exists (select 1 from sessions where user_id = v_uid and status in ('live', 'paused', 'needs_confirmation')) then
    raise exception using errcode = 'P0001', message = 'session_already_active';
  end if;

  -- 연결 대상은 모두 내 것이어야 한다(남의 것이든 없든 not_found). 비어 있는 쪽은 연결된 쪽에서 채운다.
  if v_block is not null then
    select todo_id, coalesce(v_thread, thread_id) into v_tmp, v_thread
      from plan_blocks where id = v_block and user_id = v_uid;
    if not found then raise exception using errcode = 'P0001', message = 'not_found'; end if;
    v_todo := coalesce(v_todo, v_tmp);
  end if;
  if v_todo is not null then
    select coalesce(v_thread, thread_id) into v_thread from todos where id = v_todo and user_id = v_uid;
    if not found then raise exception using errcode = 'P0001', message = 'not_found'; end if;
  end if;
  if v_thread is not null then
    select default_visibility into v_thread_vis from threads where id = v_thread and user_id = v_uid;
    if not found then raise exception using errcode = 'P0001', message = 'not_found'; end if;
  end if;
  -- 공개 범위를 안 주면 이어가는 일의 기본값, 없으면 private
  v_vis := coalesce(p_visibility, v_thread_vis, 'private');
  if v_vis in ('department', 'school') then
    raise exception using errcode = 'P0001', message = 'visibility_not_available';
  end if;
  v_group := b_resolve_group(v_uid, v_vis, p_group_id, v_thread);

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
                          visibility, group_id, offline_started_at, created_at)
    values (v_uid, p_client_id, v_thread, v_todo, v_block, p_joined_session_id,
            p_primary_category, v_tags, v_started, 'live', p_capture_mode, v_title,
            v_vis, v_group, v_offline, v_now)
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

  perform b_start_links(v_row);
  perform b_log_event(v_row.id, 'start', jsonb_build_object(
    'received_at', b_iso(v_now), 'offline', v_offline is not null, 'joined_session_id', p_joined_session_id));
  if p_joined_session_id is not null then
    insert into notification_outbox (user_id, kind, payload)
    values (v_joined.user_id, 'joined',
            jsonb_build_object('session_id', v_row.id, 'user_id', v_uid));
  end if;
  return session_json(v_row);
end $$;

create or replace function update_session_share(
  p_session_id uuid, p_visibility visibility default null, p_share_title text default null, p_progress_note text default null,
  p_group_id uuid default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v sessions;
  v_title text := nullif(btrim(p_share_title), '');
  v_note text := nullif(btrim(p_progress_note), '');
  v_vis visibility;
begin
  if auth.uid() is null then raise exception using errcode = 'P0001', message = 'not_authenticated'; end if;
  if (v_title is not null and char_length(v_title) > 60) or (v_note is not null and char_length(v_note) > 200) then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  v := b_my_session_locked(p_session_id);
  if p_visibility in ('department', 'school') then
    raise exception using errcode = 'P0001', message = 'visibility_not_available';
  end if;
  v_vis := coalesce(p_visibility, v.visibility);
  update sessions
     set visibility = v_vis, share_title = v_title, progress_note = v_note,
         group_id = b_resolve_group(v.user_id, v_vis, p_group_id, v.thread_id, v.group_id)
   where id = v.id returning * into v;
  perform b_log_event(v.id, 'share_update', jsonb_build_object('visibility', v.visibility));
  return session_json(v);
end $$;

-- 이어가는 일, 가져오기와 제안 적용
create or replace function plan_thread_json(p_t threads) returns jsonb
language sql immutable set search_path = public as $$
  select jsonb_build_object('id', p_t.id, 'title', p_t.title, 'share_title', p_t.share_title,
    'primary_category', p_t.primary_category, 'default_visibility', p_t.default_visibility,
    'default_group_id', p_t.default_group_id, 'archived_at', plan_ts(p_t.archived_at))
$$;

create or replace function plan_own_crew(p_user uuid, p_group uuid) returns void
language plpgsql set search_path = public as $$
begin
  if p_group is not null and not exists (
       select 1 from group_members m join groups g on g.id = m.group_id and g.kind = 'crew'
        where m.group_id = p_group and m.user_id = p_user and m.status = 'active') then
    perform plan_fail('not_found');
  end if;
end $$;

create or replace function create_thread(p_title text, p_primary_category category, p_share_title text, p_default_visibility visibility,
  p_default_group_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := plan_uid(); v_row threads; v_vis visibility := coalesce(p_default_visibility, 'private');
begin
  if p_title is null or p_primary_category is null then perform plan_fail('invalid_input'); end if;
  if v_vis in ('department', 'school') then perform plan_fail('visibility_not_available'); end if;
  perform plan_own_crew(v_uid, p_default_group_id);
  insert into threads (user_id, title, share_title, primary_category, default_visibility, default_group_id)
  values (v_uid, btrim(p_title), nullif(btrim(p_share_title), ''), p_primary_category, v_vis, p_default_group_id)
  returning * into v_row;
  return plan_thread_json(v_row);
exception when check_violation or string_data_right_truncation then
  perform plan_fail('invalid_input'); return null;
end $$;

create or replace function update_thread(p_thread_id uuid, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := plan_uid(); v_row threads;
begin
  select * into v_row from threads where id = p_thread_id and user_id = v_uid for update;
  if not found then perform plan_fail('not_found'); end if;
  perform plan_check_patch(p_patch, array['title', 'share_title', 'primary_category', 'default_visibility', 'default_group_id']);
  if p_patch ? 'title' then
    if jsonb_typeof(p_patch->'title') <> 'string' then perform plan_fail('invalid_input'); end if;
    v_row.title := btrim(p_patch->>'title');
  end if;
  if p_patch ? 'share_title' then
    if jsonb_typeof(p_patch->'share_title') not in ('string', 'null') then perform plan_fail('invalid_input'); end if;
    v_row.share_title := nullif(btrim(p_patch->>'share_title'), '');
  end if;
  if p_patch ? 'primary_category' then
    if jsonb_typeof(p_patch->'primary_category') <> 'string' then perform plan_fail('invalid_input'); end if;
    v_row.primary_category := (p_patch->>'primary_category')::category;
  end if;
  if p_patch ? 'default_visibility' then
    if jsonb_typeof(p_patch->'default_visibility') <> 'string' then perform plan_fail('invalid_input'); end if;
    v_row.default_visibility := (p_patch->>'default_visibility')::visibility;
    if v_row.default_visibility in ('department', 'school') then perform plan_fail('visibility_not_available'); end if;
  end if;
  if p_patch ? 'default_group_id' then
    if jsonb_typeof(p_patch->'default_group_id') not in ('string', 'null') then perform plan_fail('invalid_input'); end if;
    v_row.default_group_id := (p_patch->>'default_group_id')::uuid;
    perform plan_own_crew(v_uid, v_row.default_group_id);
  end if;
  update threads set title = v_row.title, share_title = v_row.share_title,
         primary_category = v_row.primary_category, default_visibility = v_row.default_visibility,
         default_group_id = v_row.default_group_id
   where id = v_row.id returning * into v_row;
  return plan_thread_json(v_row);
exception when check_violation or invalid_text_representation or string_data_right_truncation then
  perform plan_fail('invalid_input'); return null;
end $$;

create or replace function import_todos(p_source text, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := plan_uid(); v_item jsonb; v_row todos; v_created jsonb := '[]'::jsonb;
  v_n int := 0; v_done boolean; v_ref text; v_title text; v_due_at timestamptz; v_has_time boolean; v_dd text; v_dt text;
begin
  if p_source is null or btrim(p_source) = '' or char_length(p_source) > 40
     or p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 200 then
    perform plan_fail('invalid_input');
  end if;
  for v_item in select * from jsonb_array_elements(p_items) loop
    if jsonb_typeof(v_item) <> 'object' or jsonb_typeof(v_item->'title') is distinct from 'string' then
      perform plan_fail('invalid_input');
    end if;
    v_n := v_n + 1;
    v_title := btrim(v_item->>'title');
    v_ref := nullif(v_item->>'source_ref', '');
    v_done := coalesce((v_item->>'done')::boolean, false);
    -- 기한은 due_at(시각 값) 또는 due_date(+due_time, 한국 시간) 중 하나로만 준다.
    v_dd := nullif(v_item->>'due_date', ''); v_dt := nullif(v_item->>'due_time', '');
    if coalesce(jsonb_typeof(v_item->'due_date'), 'null') not in ('string', 'null')
       or coalesce(jsonb_typeof(v_item->'due_time'), 'null') not in ('string', 'null')
       or ((v_dd is not null or v_dt is not null) and v_item->>'due_at' is not null) then
      perform plan_fail('invalid_input');
    end if;
    if v_dd is not null or v_dt is not null then
      select f.due_at, f.has_time into v_due_at, v_has_time from plan_due_from_kst(v_dd, v_dt) f;
    else
      v_due_at := (v_item->>'due_at')::timestamptz;
      v_has_time := v_due_at is not null and coalesce((v_item->>'due_has_time')::boolean, false);
    end if;
    v_row := null;
    insert into todos (user_id, title, due_at, due_has_time, estimate_min, status, completed_at,
                       completion_source, source, source_ref)
    values (v_uid, v_title, v_due_at, v_has_time,
            (v_item->>'estimate_min')::int,
            case when v_done then 'done'::todo_status else 'open'::todo_status end,
            case when v_done then now() end,
            case when v_done then 'imported'::completion_source end,
            btrim(p_source), v_ref)
    on conflict (user_id, source, source_ref) where source_ref is not null do nothing
    returning * into v_row;
    if v_row.id is not null then v_created := v_created || jsonb_build_array(plan_todo_json(v_row)); end if;
  end loop;
  return jsonb_build_object('created', v_created, 'skipped', v_n - jsonb_array_length(v_created));
exception when check_violation or invalid_text_representation or datetime_field_overflow
  or invalid_datetime_format or numeric_value_out_of_range or string_data_right_truncation then
  perform plan_fail('invalid_input'); return null;
end $$;

create or replace function apply_proposal(p_proposal_id uuid, p_todo_indexes int[], p_block_indexes int[], p_apply_done boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := plan_uid(); v_prop assistant_proposals; v_todos jsonb; v_blocks jsonb; v_done jsonb;
  v_nt int; v_nb int; v_ti int[]; v_bi int[]; i int; v_item jsonb; v_map jsonb := '{}'::jsonb;
  v_due record; v_trow todos; v_out_todos jsonb := '[]'::jsonb; v_out_blocks jsonb := '[]'::jsonb;
  v_ref text; v_tid uuid; v_s timestamptz; v_e timestamptz; v_st todo_status; v_thread uuid;
  b_todo uuid[] := '{}'; b_s timestamptz[] := '{}'; b_e timestamptz[] := '{}'; b_thread uuid[] := '{}';
  j int; v_brow plan_blocks; v_id text; v_est int;
begin
  select * into v_prop from assistant_proposals where id = p_proposal_id and user_id = v_uid for update;
  if not found then perform plan_fail('proposal_not_found'); end if;
  if v_prop.applied_at is not null then perform plan_fail('proposal_already_applied'); end if;
  -- 만든 지 24시간이 지난 제안은 없는 것과 같다.
  if v_prop.created_at < now() - interval '24 hours' then perform plan_fail('proposal_not_found'); end if;

  v_todos := coalesce(v_prop.proposal->'todos', '[]'::jsonb);
  v_blocks := coalesce(v_prop.proposal->'blocks', '[]'::jsonb);
  v_done := coalesce(v_prop.proposal->'done_todo_ids', '[]'::jsonb);
  if jsonb_typeof(v_todos) <> 'array' or jsonb_typeof(v_blocks) <> 'array' or jsonb_typeof(v_done) <> 'array' then
    perform plan_fail('invalid_input');
  end if;
  v_nt := jsonb_array_length(v_todos); v_nb := jsonb_array_length(v_blocks);

  if p_todo_indexes is null then
    v_ti := coalesce((select array_agg(g) from generate_series(0, v_nt - 1) g), '{}');
  else
    select coalesce(array_agg(distinct x order by x), '{}') into v_ti from unnest(p_todo_indexes) x;
    if exists (select 1 from unnest(v_ti) x where x is null or x < 0 or x >= v_nt) or array_position(p_todo_indexes, null) is not null then
      perform plan_fail('invalid_input');
    end if;
  end if;
  if p_block_indexes is null then
    v_bi := coalesce((select array_agg(g) from generate_series(0, v_nb - 1) g), '{}');
  else
    select coalesce(array_agg(distinct x order by x), '{}') into v_bi from unnest(p_block_indexes) x;
    if exists (select 1 from unnest(v_bi) x where x is null or x < 0 or x >= v_nb) or array_position(p_block_indexes, null) is not null then
      perform plan_fail('invalid_input');
    end if;
  end if;

  -- 재배치는 전부 적용하거나 적용하지 않는다. 일부만 고르면 고르지 않은 기존 계획이 사라진다.
  -- p_block_indexes 가 null 이면 전부를 뜻한다(계약 3절 D).
  if v_prop.kind = 'reschedule' and coalesce(array_length(v_bi, 1), 0) <> v_nb then
    perform plan_fail('invalid_input');
  end if;

  -- 1) 새 할 일 만들기
  foreach i in array v_ti loop
    v_item := v_todos->i;
    if jsonb_typeof(v_item) <> 'object' or jsonb_typeof(v_item->'title') is distinct from 'string'
       or btrim(v_item->>'title') = '' then
      perform plan_fail('invalid_input');
    end if;
    select * into v_due from plan_due_from_kst(nullif(v_item->>'due_date', ''), nullif(v_item->>'due_time', ''));
    v_est := case when jsonb_typeof(v_item->'estimate_min') = 'number' then (v_item->>'estimate_min')::int end;
    insert into todos (user_id, title, due_at, due_has_time, estimate_min, source)
    values (v_uid, btrim(v_item->>'title'), v_due.due_at, v_due.has_time, v_est, 'assistant')
    returning * into v_trow;
    v_map := v_map || jsonb_build_object(i::text, v_trow.id);
    v_out_todos := v_out_todos || jsonb_build_array(plan_todo_json(v_trow));
  end loop;

  -- 2) 예정 시간 확인(본인 소유, 겹침)
  foreach i in array v_bi loop
    v_item := v_blocks->i;
    if jsonb_typeof(v_item) <> 'object' then perform plan_fail('invalid_input'); end if;
    v_ref := v_item->>'todo_ref';
    if v_ref is null then perform plan_fail('invalid_input'); end if;
    if v_ref ~ '^new:\d+$' then
      v_tid := (v_map->>(substr(v_ref, 5)::int)::text)::uuid;
      if v_tid is null then perform plan_fail('invalid_input'); end if;
      select thread_id into v_thread from todos where id = v_tid;
    elsif v_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      select id, status, thread_id into v_tid, v_st, v_thread from todos where id = v_ref::uuid and user_id = v_uid;
      if not found then perform plan_fail('not_found'); end if;
      if v_st in ('done', 'dropped') then perform plan_fail('invalid_input'); end if;
    else
      perform plan_fail('invalid_input');
    end if;
    v_s := (v_item->>'start')::timestamptz; v_e := (v_item->>'end')::timestamptz;
    if v_s is null or v_e is null or v_e <= v_s then perform plan_fail('invalid_input'); end if;
    if exists (select 1 from plan_blocks pb where pb.user_id = v_uid and pb.locked
                  and pb.status not in ('cancelled', 'moved') and pb.start_at < v_e and pb.end_at > v_s) then
      perform plan_fail('invalid_input');
    end if;
    for j in 1 .. coalesce(array_length(b_s, 1), 0) loop
      if b_s[j] < v_e and v_s < b_e[j] then perform plan_fail('invalid_input'); end if;
    end loop;
    b_todo := b_todo || v_tid; b_s := b_s || v_s; b_e := b_e || v_e; b_thread := b_thread || v_thread;
  end loop;

  -- 3) reschedule: 잠기지 않은 앞으로의 planned 블록을 moved 로 바꾸고 제안의 블록을 넣는다
  if v_prop.kind = 'reschedule' and coalesce(array_length(b_s, 1), 0) > 0 then
    update plan_blocks set status = 'moved'
     where user_id = v_uid and not locked and status = 'planned' and start_at > now();
  end if;
  for j in 1 .. coalesce(array_length(b_s, 1), 0) loop
    insert into plan_blocks (user_id, todo_id, thread_id, start_at, end_at, locked, origin)
    values (v_uid, b_todo[j], b_thread[j], b_s[j], b_e[j], false, 'assistant')
    returning * into v_brow;
    v_out_blocks := v_out_blocks || jsonb_build_array(plan_block_json(v_brow));
  end loop;

  -- 4) 사용자 진술로 완료 처리(없거나 남의 것이거나 이미 끝난 것은 건너뛴다)
  if coalesce(p_apply_done, false) then
    for v_id in select jsonb_array_elements_text(v_done) loop
      continue when v_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
      update todos set status = 'done', completed_at = now(), completion_source = 'user_statement', updated_at = now()
       where id = v_id::uuid and user_id = v_uid and status in ('open', 'in_progress')
       returning * into v_trow;
      if found then
        perform plan_after_todo_change(v_uid, v_trow.id);
        v_out_todos := v_out_todos || jsonb_build_array(plan_todo_json(v_trow));
      end if;
    end loop;
  end if;

  update assistant_proposals set applied_at = now() where id = v_prop.id;
  return jsonb_build_object('todos', v_out_todos, 'blocks', v_out_blocks);
exception when check_violation or invalid_text_representation or datetime_field_overflow
  or invalid_datetime_format or numeric_value_out_of_range or string_data_right_truncation then
  perform plan_fail('invalid_input'); return null;
end $$;

drop function if exists public.social_share_crew(uuid, uuid);

revoke all on function public.social_in_crew(uuid, uuid),
  public.b_resolve_group(uuid, visibility, uuid, uuid, uuid),
  public.plan_own_crew(uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.rotate_invite_code(uuid),
  public.start_session(uuid, category, capture_mode, visibility, uuid, uuid, uuid, text[], text, uuid, timestamptz, uuid),
  public.update_session_share(uuid, visibility, text, text, uuid),
  public.create_thread(text, category, text, visibility, uuid)
  from public, anon;
grant execute on function public.rotate_invite_code(uuid),
  public.start_session(uuid, category, capture_mode, visibility, uuid, uuid, uuid, text[], text, uuid, timestamptz, uuid),
  public.update_session_share(uuid, visibility, text, text, uuid),
  public.create_thread(text, category, text, visibility, uuid)
  to authenticated;

notify pgrst, 'reload schema';
