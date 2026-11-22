-- 흐름 C social: 친구, 크루, 피드, 반응, 한마디, 차단, 신고, can_view_session
-- 앱은 아래 공개 함수로만 접근한다. 내부 함수는 authenticated에 실행 권한을 주지 않는다.
-- 다른 흐름의 함수(profile_card)는 plpgsql 안에서만 부른다.

-- ── 인덱스 ──
-- 피드: 작성자별로 최근 공유 세션을 index만으로 훑는다.
create index if not exists sessions_feed_idx
  on sessions (user_id, started_at desc, id desc)
  where visibility in ('friends', 'crew') and status <> 'needs_confirmation';
create index if not exists reports_session_idx on reports (session_id);
create index if not exists reactions_user_idx on reactions (user_id);
create index if not exists comments_user_idx on comments (user_id);
create index if not exists groups_owner_idx on groups (owner_id);

-- ── 내부 도우미 ──
create or replace function social_uid() returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v uuid := auth.uid();
begin
  if v is null then
    raise exception using errcode = 'P0001', message = 'not_authenticated';
  end if;
  return v;
end $$;

create or replace function social_err(p_code text) returns void
language plpgsql immutable set search_path = public as $$
begin
  raise exception using errcode = 'P0001', message = p_code;
end $$;

-- 프로필이 있어야 하는 동작에서 학교를 돌려준다.
create or replace function social_school(p_user uuid) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  select school_id into v from profiles where id = p_user;
  if v is null then perform social_err('profile_required'); end if;
  return v;
end $$;

create or replace function social_iso(p timestamptz) returns text
language sql stable set search_path = public as $$
  select case when p is null then null
    else to_char(p at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') end
$$;

create or replace function social_is_blocked(p_a uuid, p_b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from blocks
    where (blocker_id = p_a and blocked_id = p_b) or (blocker_id = p_b and blocked_id = p_a)
  )
$$;

create or replace function social_are_friends(p_a uuid, p_b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from friendships
    where user_a = least(p_a, p_b) and user_b = greatest(p_a, p_b) and status = 'accepted'
  )
$$;

-- 사용자가 그 크루의 활동 중인 구성원인가.
create or replace function social_in_crew(p_user uuid, p_group uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_group is not null and exists (
    select 1
    from group_members m
    join groups g on g.id = m.group_id and g.kind = 'crew'
    where m.group_id = p_group and m.user_id = p_user and m.status = 'active'
  )
$$;

create or replace function social_notify(p_user uuid, p_kind text, p_payload jsonb) returns void
language sql security definer set search_path = public as $$
  insert into notification_outbox (user_id, kind, payload) values (p_user, p_kind, p_payload)
$$;

-- ── can_view_session (내부) ──
-- 본인 것이면 항상. 그 외에는 종료 확인 필요가 아니고, 공개 범위가 friends/crew이고,
-- 차단 관계가 아니고, 내가 신고하지 않았고, 관계가 맞을 때만.
-- crew 공개: 작성자와 친구이거나, 보는 사람과 작성자가 둘 다 그 세션의 group_id 크루의 활동 중인 구성원.
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

-- ── 친구 ──
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

-- 친구 삭제, 보낸 요청 취소를 겸한다. 없으면 아무 일도 없다.
create or replace function remove_friend(p_user_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := social_uid();
begin
  if p_user_id is null then perform social_err('invalid_input'); end if;
  delete from friendships
   where user_a = least(me, p_user_id) and user_b = greatest(me, p_user_id)
     and (status = 'accepted' or requested_by = me);
  return null;
end $$;

create or replace function block_user(p_user_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := social_uid();
begin
  perform social_school(me);
  if p_user_id is null or p_user_id = me then perform social_err('invalid_input'); end if;
  if not exists (select 1 from profiles where id = p_user_id) then perform social_err('not_found'); end if;
  insert into blocks (blocker_id, blocked_id) values (me, p_user_id) on conflict do nothing;
  delete from friendships
   where user_a = least(me, p_user_id) and user_b = greatest(me, p_user_id);
  return null;
end $$;

create or replace function unblock_user(p_user_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := social_uid();
begin
  if p_user_id is null then perform social_err('invalid_input'); end if;
  delete from blocks where blocker_id = me and blocked_id = p_user_id;
  return null;
end $$;

create or replace function list_friends() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := social_uid();
begin
  return coalesce((
    select jsonb_agg(profile_card(f.uid) order by p.display_name, f.uid)
    from (
      select case when user_a = me then user_b else user_a end as uid
      from friendships
      where status = 'accepted' and (user_a = me or user_b = me)
    ) f
    join profiles p on p.id = f.uid
    where not social_is_blocked(me, f.uid)
  ), '[]'::jsonb);
end $$;

create or replace function list_friend_requests() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := social_uid();
begin
  return jsonb_build_object(
    'incoming', coalesce((
      select jsonb_agg(profile_card(f.uid) order by f.created_at desc, f.uid)
      from (
        select case when user_a = me then user_b else user_a end as uid, created_at
        from friendships
        where status = 'pending' and requested_by <> me and (user_a = me or user_b = me)
      ) f
      where not social_is_blocked(me, f.uid)
    ), '[]'::jsonb),
    'outgoing', coalesce((
      select jsonb_agg(profile_card(f.uid) order by f.created_at desc, f.uid)
      from (
        select case when user_a = me then user_b else user_a end as uid, created_at
        from friendships
        where status = 'pending' and requested_by = me and (user_a = me or user_b = me)
      ) f
      where not social_is_blocked(me, f.uid)
    ), '[]'::jsonb)
  );
end $$;

-- ── 크루 ──
create or replace function social_crew_json(p_group uuid, p_user uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', g.id, 'name', g.name, 'invite_code', g.invite_code,
    'member_count', (select count(*) from group_members m where m.group_id = g.id and m.status = 'active'),
    'role', gm.role)
  from groups g
  join group_members gm on gm.group_id = g.id and gm.user_id = p_user and gm.status = 'active'
  where g.id = p_group
$$;

create or replace function create_crew(p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := social_uid(); school uuid; nm text := btrim(coalesce(p_name, '')); gid uuid; code text;
begin
  school := social_school(me);
  if char_length(nm) < 1 or char_length(nm) > 30 then perform social_err('invalid_input'); end if;
  loop
    code := upper(encode(gen_random_bytes(8), 'hex'));      -- 16자
    begin
      insert into groups (school_id, kind, name, owner_id, invite_code)
      values (school, 'crew', nm, me, code) returning id into gid;
      exit;
    exception when unique_violation then null;
    end;
  end loop;
  insert into group_members (group_id, user_id, role, status) values (gid, me, 'owner', 'active');
  return social_crew_json(gid, me);
end $$;

create or replace function join_crew(p_invite_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := social_uid(); school uuid; g groups%rowtype; m group_members%rowtype; n int;
begin
  school := social_school(me);
  select * into g from groups where invite_code = upper(btrim(coalesce(p_invite_code, ''))) and kind = 'crew';
  if not found or g.school_id <> school then perform social_err('invite_invalid'); end if;
  perform 1 from groups where id = g.id for update;           -- 정원 검사를 직렬화
  select * into m from group_members where group_id = g.id and user_id = me;
  if found and m.status = 'active' then return social_crew_json(g.id, me); end if;
  if found and m.status = 'removed' then perform social_err('forbidden'); end if;
  select count(*) into n from group_members where group_id = g.id and status = 'active';
  if n >= 50 then perform social_err('crew_full'); end if;
  insert into group_members (group_id, user_id, role, status) values (g.id, me, 'member', 'active');
  return social_crew_json(g.id, me);
end $$;

-- 운영자만. 새 코드로 바꾸고 예전 코드는 곧바로 쓸 수 없다.
create or replace function rotate_invite_code(p_group_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
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

create or replace function leave_crew(p_group_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := social_uid(); m group_members%rowtype; heir uuid;
begin
  perform 1 from groups where id = p_group_id for update;
  select * into m from group_members where group_id = p_group_id and user_id = me and status = 'active';
  if not found then perform social_err('not_found'); end if;
  delete from group_members where group_id = p_group_id and user_id = me;
  if m.role = 'owner' then
    select user_id into heir from group_members
     where group_id = p_group_id and status = 'active' order by joined_at, user_id limit 1;
    if heir is null then
      delete from groups where id = p_group_id;
    else
      update group_members set role = 'owner' where group_id = p_group_id and user_id = heir;
      update groups set owner_id = heir where id = p_group_id;
    end if;
  end if;
  return null;
end $$;

create or replace function remove_crew_member(p_group_id uuid, p_user_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := social_uid();
begin
  if not exists (select 1 from group_members
                  where group_id = p_group_id and user_id = me and status = 'active' and role = 'owner') then
    perform social_err('forbidden');
  end if;
  if p_user_id is null or p_user_id = me then perform social_err('invalid_input'); end if;
  update group_members set status = 'removed'
   where group_id = p_group_id and user_id = p_user_id and status = 'active';
  if not found then perform social_err('not_found'); end if;
  return null;
end $$;

create or replace function list_my_crews() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := social_uid();
begin
  return coalesce((
    select jsonb_agg(social_crew_json(gm.group_id, me) order by gm.joined_at, gm.group_id)
    from group_members gm join groups g on g.id = gm.group_id and g.kind = 'crew'
    where gm.user_id = me and gm.status = 'active'
  ), '[]'::jsonb);
end $$;

create or replace function list_crew_members(p_group_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := social_uid();
begin
  if not exists (select 1 from group_members where group_id = p_group_id and user_id = me and status = 'active') then
    perform social_err('forbidden');
  end if;
  return coalesce((
    select jsonb_agg(profile_card(gm.user_id) || jsonb_build_object('role', gm.role)
                     order by (gm.role = 'owner') desc, gm.joined_at, gm.user_id)
    from group_members gm
    where gm.group_id = p_group_id and gm.status = 'active'
      and (gm.user_id = me or not social_is_blocked(me, gm.user_id))
  ), '[]'::jsonb);
end $$;

-- ── 피드 카드 ──
-- p_ids 순서를 그대로 지키며, 반응·한마디 수는 한 번에 모아 센다(행마다 질의하지 않는다).
-- 개인 제목, 할 일, 예정 시간은 읽지 않는다. 호출하는 쪽이 이미 볼 권한을 거른 id만 넘긴다.
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

-- 커서: "순위|시작시각(마이크로초)|id". 순위 0은 진행 중, 1은 그 외.
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

-- 같은 작성자의 같은 이어가는 일 중 내가 볼 수 있는 것(기준 세션은 뺀다). 최근 시작 순.
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

-- ── 반응, 한마디 ──
create or replace function set_reaction(p_session_id uuid, p_kind text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := social_uid(); owner uuid; old text;
begin
  perform social_school(me);
  if p_kind is not null and p_kind not in ('cheer', 'fire', 'clap') then perform social_err('invalid_input'); end if;
  if not can_view_session(me, p_session_id) then perform social_err('not_found'); end if;
  select user_id into owner from sessions where id = p_session_id;
  if p_kind is null then
    delete from reactions where session_id = p_session_id and user_id = me;
    return null;
  end if;
  select kind into old from reactions where session_id = p_session_id and user_id = me;
  insert into reactions (session_id, user_id, kind) values (p_session_id, me, p_kind)
  on conflict (session_id, user_id) do update set kind = excluded.kind, created_at = now();
  if owner <> me and old is distinct from p_kind then
    perform social_notify(owner, 'reaction',
      jsonb_build_object('session_id', p_session_id, 'user_id', me, 'reaction', p_kind));
  end if;
  return null;
end $$;

create or replace function social_comment_json(p_comment comments) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  return jsonb_build_object('id', p_comment.id, 'author', profile_card(p_comment.user_id),
                            'body', p_comment.body, 'created_at', social_iso(p_comment.created_at));
end $$;

create or replace function add_comment(p_session_id uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := social_uid(); b text := btrim(coalesce(p_body, '')); c comments%rowtype; owner uuid;
begin
  perform social_school(me);
  if char_length(b) < 1 or char_length(b) > 200 then perform social_err('invalid_input'); end if;
  if not can_view_session(me, p_session_id) then perform social_err('not_found'); end if;
  insert into comments (session_id, user_id, body) values (p_session_id, me, b) returning * into c;
  select user_id into owner from sessions where id = p_session_id;
  if owner <> me then
    perform social_notify(owner, 'comment',
      jsonb_build_object('session_id', p_session_id, 'comment_id', c.id, 'user_id', me));
  end if;
  return social_comment_json(c);
end $$;

create or replace function list_comments(p_session_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := social_uid();
begin
  if not can_view_session(me, p_session_id) then perform social_err('not_found'); end if;
  return coalesce((
    select jsonb_agg(social_comment_json(c) order by c.created_at, c.id)
    from comments c
    where c.session_id = p_session_id
      and (c.user_id = me or not social_is_blocked(me, c.user_id))
  ), '[]'::jsonb);
end $$;

-- 자기 한마디만 지운다.
create or replace function delete_comment(p_comment_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := social_uid(); c comments%rowtype;
begin
  select * into c from comments where id = p_comment_id;
  if not found then perform social_err('not_found'); end if;
  if c.user_id <> me then
    -- 볼 수 없는 세션의 한마디는 존재 자체를 알리지 않는다
    if not can_view_session(me, c.session_id) then perform social_err('not_found'); end if;
    perform social_err('forbidden');
  end if;
  delete from comments where id = p_comment_id;
  return null;
end $$;

-- ── 신고 ──
create or replace function report_session(p_session_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := social_uid(); rs text := btrim(coalesce(p_reason, '')); owner uuid;
begin
  perform social_school(me);
  if char_length(rs) < 1 or char_length(rs) > 500 then perform social_err('invalid_input'); end if;
  if exists (select 1 from reports where reporter_id = me and session_id = p_session_id) then
    return null;                                               -- 이미 신고함
  end if;
  if not can_view_session(me, p_session_id) then perform social_err('not_found'); end if;
  select user_id into owner from sessions where id = p_session_id;
  if owner = me then perform social_err('invalid_input'); end if;
  insert into reports (reporter_id, session_id, reason) values (me, p_session_id, rs)
  on conflict do nothing;
  return null;
end $$;

-- ── 실행 권한 ──
-- 모두 기본 공개 실행을 거두고, 공개 함수만 authenticated에 준다. 내부 함수는 아무에게도 주지 않는다.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig, p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and (p.proname in ('can_view_session', 'get_feed', 'get_thread_history', 'send_friend_request',
            'respond_friend_request', 'remove_friend', 'block_user', 'unblock_user', 'list_friends',
            'list_friend_requests', 'create_crew', 'join_crew', 'leave_crew', 'remove_crew_member',
            'list_my_crews', 'list_crew_members', 'set_reaction', 'add_comment', 'list_comments',
            'delete_comment', 'report_session', 'rotate_invite_code')
           or p.proname like 'social\_%')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    if r.proname in ('get_feed', 'get_thread_history', 'send_friend_request', 'respond_friend_request',
         'remove_friend', 'block_user', 'unblock_user', 'list_friends', 'list_friend_requests',
         'create_crew', 'join_crew', 'rotate_invite_code', 'leave_crew', 'remove_crew_member', 'list_my_crews',
         'list_crew_members', 'set_reaction', 'add_comment', 'list_comments', 'delete_comment',
         'report_session') then
      execute format('grant execute on function %s to authenticated', r.sig);
    end if;
  end loop;
end $$;
