-- 흐름 E: 서버 함수(assistant, import-extract, notify, delete-account)가 관리자 키로 부르는 내부 함수.
-- 전부 service_role 전용이다. 앱(authenticated)은 이 함수를 부를 수 없다(계약 2절: 내부용은 권한을 주지 않는다).
-- Supabase는 public 스키마의 새 함수에 anon/authenticated 실행 권한을 기본으로 주므로 명시적으로 걷어 낸다.

-- 알림 발송 중복 방지용: 집어 간 시각. 5분이 지나도 발송 표시가 없으면 다시 집힌다.
alter table notification_outbox add column if not exists claimed_at timestamptz;
-- 보내지 않고 끝낸 건(차단, 10분 안 중복). 중복 판정은 실제로 보낸 건만 기준으로 삼는다.
alter table notification_outbox add column if not exists skipped boolean not null default false;

-- ── 비서 호출 기록과 하루 한도 ──
-- 한도는 한국 시간 하루(자정~자정), 같은 kind끼리 센다. 실패한 호출도 센다(모델 비용이 이미 났을 수 있다).
-- 같은 사용자의 동시 호출이 한도를 넘지 않도록 사용자별 잠금을 건다.
create or replace function assistant_run_begin(p_user uuid, p_kind text, p_daily_limit int)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_day_start timestamptz := date_trunc('day', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
  v_used int;
  v_id uuid;
begin
  if p_user is null or p_kind is null or p_kind !~ '^[a-z_]{1,32}$' or p_daily_limit is null or p_daily_limit < 0 then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('assistant_run:' || p_user::text, 0));
  select count(*) into v_used from assistant_runs
   where user_id = p_user and kind = p_kind and created_at >= v_day_start;
  if v_used >= p_daily_limit then
    raise exception using errcode = 'P0001', message = 'quota_exceeded';
  end if;
  insert into assistant_runs (user_id, kind, ok) values (p_user, p_kind, false) returning id into v_id;
  return v_id;
end $$;

create or replace function assistant_run_finish(
  p_run uuid, p_model text, p_input_tokens int, p_output_tokens int, p_latency_ms int, p_ok boolean)
returns void language sql security definer set search_path = public as $$
  update assistant_runs
     set model = p_model, input_tokens = p_input_tokens, output_tokens = p_output_tokens,
         latency_ms = p_latency_ms, ok = coalesce(p_ok, false)
   where id = p_run;
$$;

-- 할 일의 분야를 알기 위한 이어가는 일 → 분야 표. 예상 시간 보정 배수를 분야별로 적용하는 데 쓴다.
create or replace function assistant_thread_categories(p_user uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(id::text, primary_category::text), '{}'::jsonb)
    from threads where user_id = p_user;
$$;

-- ── 제안 저장 ──
-- input에는 kind와 now만 남긴다(대화 원문은 저장하지 않는다). proposal은 모델 제안(규칙 검사를 통과한 것).
create or replace function assistant_proposal_save(p_user uuid, p_kind text, p_input jsonb, p_proposal jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if p_user is null or p_kind not in ('capture', 'plan_day', 'reschedule')
     or jsonb_typeof(p_proposal) is distinct from 'object'
     or jsonb_typeof(p_proposal->'todos') is distinct from 'array'
     or jsonb_typeof(p_proposal->'blocks') is distinct from 'array' then
    raise exception using errcode = 'P0001', message = 'invalid_input';
  end if;
  insert into assistant_proposals (user_id, kind, input, proposal)
  values (p_user, p_kind, jsonb_build_object('kind', p_kind, 'now', p_input->'now'), p_proposal)
  returning id into v_id;
  return v_id;
end $$;

-- ── 계정 삭제: 사진 경로 ──
-- 사용자를 지우면 sessions 행이 같이 사라지므로 먼저 경로를 읽어 저장소에서 지운다.
create or replace function delete_account_photo_paths(p_user uuid)
returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct p), '{}') from (
    select photo_path as p from sessions where user_id = p_user and photo_path is not null
    union all
    select photo_thumb_path from sessions where user_id = p_user and photo_thumb_path is not null
  ) x;
$$;

-- ── 알림 발송 ──
-- 24시간이 지난 알림은 보내지 않는다. 집어 간 건은 발송 표시가 없어도 5분 동안 다시 집히지 않는다.
-- 보내지 않고 발송 처리(skipped)하는 경우:
--  · 행위자(payload.user_id, 없으면 actor_id)와 받는 사람 사이에 차단 관계가 있을 때(어느 방향이든)
--  · 같은 (받는 사람, 행위자, 종류, 대상=payload.session_id)의 알림을 10분 안에 이미 보냈거나 같은 묶음에서 먼저 집었을 때
-- actor_name은 행위자의 표시 이름(없으면 null).
create or replace function notification_outbox_claim(p_limit int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  with cand as (
    select o.id, o.user_id, o.kind, o.payload,
           actor.id as actor_id, o.payload->>'session_id' as target
      from notification_outbox o
      cross join lateral (
        select case when coalesce(o.payload->>'user_id', o.payload->>'actor_id') ~ '^[0-9a-f-]{36}$'
                    then coalesce(o.payload->>'user_id', o.payload->>'actor_id')::uuid end as id
      ) actor
     where o.sent_at is null
       and o.created_at > now() - interval '24 hours'
       and (o.claimed_at is null or o.claimed_at < now() - interval '5 minutes')
     order by o.id
     limit greatest(1, least(coalesce(p_limit, 100), 500))
     for update of o skip locked
  ), picked as (
    select c.id,
           ( exists (select 1 from blocks b
                      where (b.blocker_id = c.user_id and b.blocked_id = c.actor_id)
                         or (b.blocker_id = c.actor_id and b.blocked_id = c.user_id))
             or exists (select 1 from notification_outbox d
                         where d.id <> c.id and d.sent_at > now() - interval '10 minutes' and not d.skipped
                           and d.user_id = c.user_id and d.kind = c.kind
                           and d.payload->>'session_id' is not distinct from c.target
                           and coalesce(d.payload->>'user_id', d.payload->>'actor_id') is not distinct from coalesce(c.payload->>'user_id', c.payload->>'actor_id'))
             or row_number() over (partition by c.user_id, c.kind, c.target, c.actor_id order by c.id) > 1
           ) as skip
      from cand c
  ), upd as (
    update notification_outbox o
       set claimed_at = now(), sent_at = case when picked.skip then now() end, skipped = picked.skip
      from picked where o.id = picked.id
    returning o.id, o.user_id, o.kind, o.payload, picked.skip
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', u.id, 'user_id', u.user_id, 'kind', u.kind, 'payload', u.payload,
      'actor_name', (select display_name from profiles
                      where id = case when coalesce(u.payload->>'user_id', u.payload->>'actor_id') ~ '^[0-9a-f-]{36}$'
                                      then coalesce(u.payload->>'user_id', u.payload->>'actor_id')::uuid end),
      'tokens', coalesce((select jsonb_agg(token order by created_at) from device_tokens d where d.user_id = u.user_id), '[]'::jsonb)
    ) order by u.id), '[]'::jsonb)
    into v from upd u where not u.skip;
  return v;
end $$;

create or replace function notification_outbox_mark_sent(p_ids bigint[])
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update notification_outbox set sent_at = now() where id = any(p_ids) and sent_at is null;
  get diagnostics n = row_count;
  return n;
end $$;

-- 푸시를 받을 수 없다고 확인된 토큰을 지운다.
create or replace function device_tokens_remove(p_tokens text[])
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from device_tokens where token = any(p_tokens);
  get diagnostics n = row_count;
  return n;
end $$;

-- ── 계정 삭제: 크루 정리 ──
-- 사용자가 운영자(owner_id)인 크루는, 다른 활동 중 구성원이 있으면 가장 오래된 구성원에게 넘기고 없으면 지운다
-- (groups.owner_id는 사용자 삭제 때 크루를 같이 지우므로 먼저 해야 한다). 돌려주는 값은 넘긴 크루 수와 지운 크루 수.
create or replace function delete_account_cleanup_crews(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g record; v_next uuid; v_moved int := 0; v_deleted int := 0;
begin
  for g in select id from groups where owner_id = p_user for update loop
    select user_id into v_next from group_members
     where group_id = g.id and status = 'active' and user_id <> p_user
     order by joined_at, user_id limit 1;
    if v_next is null then
      delete from groups where id = g.id;
      v_deleted := v_deleted + 1;
    else
      update groups set owner_id = v_next where id = g.id;
      update group_members set role = 'owner' where group_id = g.id and user_id = v_next;
      v_moved := v_moved + 1;
    end if;
  end loop;
  return jsonb_build_object('transferred', v_moved, 'deleted', v_deleted);
end $$;

-- ── 권한: service_role 전용 ──
do $$
declare f text;
begin
  foreach f in array array[
    'assistant_run_begin(uuid,text,int)',
    'assistant_run_finish(uuid,text,int,int,int,boolean)',
    'assistant_thread_categories(uuid)',
    'assistant_proposal_save(uuid,text,jsonb,jsonb)',
    'delete_account_photo_paths(uuid)',
    'delete_account_cleanup_crews(uuid)',
    'notification_outbox_claim(int)',
    'notification_outbox_mark_sent(bigint[])',
    'device_tokens_remove(text[])'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
