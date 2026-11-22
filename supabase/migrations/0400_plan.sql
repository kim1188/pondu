-- 흐름 D: 이어가는 일, 할 일, 예정 시간, 오늘 조회, 제안 적용, 예상 시간 보정.
-- 앱은 테이블을 직접 읽거나 쓰지 않고 아래 함수만 부른다.
-- 다른 흐름의 함수(session_json)는 plpgsql 안에서만 부른다(실행 시점에 찾음).

-- ── 인덱스 ──
create index if not exists plan_todos_done_idx on todos (user_id, completed_at) where status = 'done';
create index if not exists plan_todos_thread_idx on todos (thread_id) where thread_id is not null;
create index if not exists plan_blocks_todo_idx on plan_blocks (todo_id) where todo_id is not null;
create index if not exists plan_sessions_todo_idx on sessions (todo_id) where todo_id is not null;

-- ── 내부 도우미 (권한 없음) ──
create or replace function plan_fail(p_code text) returns void
language plpgsql set search_path = public as $$
begin
  raise exception using errcode = 'P0001', message = p_code;
end $$;

create or replace function plan_uid() returns uuid
language plpgsql stable set search_path = public as $$
declare v uuid := auth.uid();
begin
  if v is null then perform plan_fail('not_authenticated'); end if;
  return v;
end $$;

create or replace function plan_ts(p_t timestamptz) returns text
language sql immutable set search_path = public as $$
  select case when p_t is null then null
    else to_char(p_t at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') end
$$;

create or replace function plan_kst(p_t timestamptz) returns text
language sql immutable set search_path = public as $$
  select case when p_t is null then null
    else to_char(p_t at time zone 'Asia/Seoul', 'YYYY-MM-DD"T"HH24:MI:SS') || '+09:00' end
$$;

create or replace function plan_thread_json(p_t threads) returns jsonb
language sql immutable set search_path = public as $$
  select jsonb_build_object('id', p_t.id, 'title', p_t.title, 'share_title', p_t.share_title,
    'primary_category', p_t.primary_category, 'default_visibility', p_t.default_visibility,
    'archived_at', plan_ts(p_t.archived_at))
$$;

create or replace function plan_todo_json(p_t todos) returns jsonb
language sql immutable set search_path = public as $$
  select jsonb_build_object('id', p_t.id, 'thread_id', p_t.thread_id, 'title', p_t.title,
    'due_at', plan_ts(p_t.due_at), 'due_has_time', p_t.due_has_time, 'estimate_min', p_t.estimate_min,
    'status', p_t.status, 'completed_at', plan_ts(p_t.completed_at),
    'completion_source', p_t.completion_source, 'source', p_t.source, 'source_ref', p_t.source_ref,
    'created_at', plan_ts(p_t.created_at))
$$;

create or replace function plan_block_json(p_b plan_blocks) returns jsonb
language sql immutable set search_path = public as $$
  select jsonb_build_object('id', p_b.id, 'todo_id', p_b.todo_id, 'thread_id', p_b.thread_id,
    'start_at', plan_ts(p_b.start_at), 'end_at', plan_ts(p_b.end_at), 'locked', p_b.locked,
    'origin', p_b.origin, 'status', p_b.status)
$$;

-- patch 는 비어 있지 않은 객체이고 허용된 키만 가져야 한다.
create or replace function plan_check_patch(p_patch jsonb, p_allowed text[]) returns void
language plpgsql set search_path = public as $$
declare k text;
begin
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' or p_patch = '{}'::jsonb then
    perform plan_fail('invalid_input');
  end if;
  for k in select jsonb_object_keys(p_patch) loop
    if not (k = any (p_allowed)) then perform plan_fail('invalid_input'); end if;
  end loop;
end $$;

-- 본인 소유 이어가는 일 확인. 남의 것이면 없는 것과 같게 not_found.
create or replace function plan_own_thread(p_user uuid, p_thread uuid) returns void
language plpgsql set search_path = public as $$
begin
  if p_thread is not null and not exists (select 1 from threads where id = p_thread and user_id = p_user) then
    perform plan_fail('not_found');
  end if;
end $$;

-- 할 일의 분야: 실제로 가장 오래 한 세션의 분야, 없으면 이어가는 일의 분야.
create or replace function plan_todo_category(p_todo uuid) returns category
language sql stable set search_path = public as $$
  select coalesce(
    (select s.primary_category from sessions s
      where s.todo_id = p_todo and s.status = 'ended' and s.ended_at is not null
      group by s.primary_category
      order by sum(extract(epoch from s.ended_at - s.started_at) - s.paused_seconds) desc limit 1),
    (select th.primary_category from todos t join threads th on th.id = t.thread_id where t.id = p_todo))
$$;

-- 예상 시간 보정 배수를 다시 계산한다. 표본 5개 미만이면 행을 두지 않는다.
create or replace function plan_recompute_estimate(p_user uuid, p_cat category) returns void
language plpgsql set search_path = public as $$
declare v_n int; v_med numeric;
begin
  with per as (
    select t.id, t.completed_at, t.estimate_min, s.primary_category as cat,
           sum(greatest(extract(epoch from s.ended_at - s.started_at) - s.paused_seconds, 0)) as sec
      from todos t
      join sessions s on s.todo_id = t.id and s.user_id = t.user_id
                     and s.status = 'ended' and s.ended_at is not null
     where t.user_id = p_user and t.status = 'done' and t.estimate_min is not null
     group by t.id, t.completed_at, t.estimate_min, s.primary_category
  ), dom as (
    select distinct on (id) id, completed_at, estimate_min, cat,
           sum(sec) over (partition by id) as tot
      from per order by id, sec desc
  ), recent as (
    select tot / (estimate_min * 60.0) as ratio
      from dom where cat = p_cat and tot > 0
     order by completed_at desc, id limit 20
  )
  select count(*), percentile_cont(0.5) within group (order by ratio) into v_n, v_med from recent;

  if v_n >= 5 then
    insert into estimate_stats (user_id, primary_category, factor, sample_count, updated_at)
    values (p_user, p_cat, least(3.0, greatest(0.5, round(v_med, 2))), v_n, now())
    on conflict (user_id, primary_category) do update
      set factor = excluded.factor, sample_count = excluded.sample_count, updated_at = now();
  else
    delete from estimate_stats where user_id = p_user and primary_category = p_cat;
  end if;
end $$;

create or replace function plan_after_todo_change(p_user uuid, p_todo uuid) returns void
language plpgsql set search_path = public as $$
declare v_cat category;
begin
  select s.primary_category into v_cat from sessions s
   where s.todo_id = p_todo and s.status = 'ended' and s.ended_at is not null
   group by s.primary_category
   order by sum(extract(epoch from s.ended_at - s.started_at) - s.paused_seconds) desc limit 1;
  if v_cat is not null then perform plan_recompute_estimate(p_user, v_cat); end if;
end $$;

-- 한국 시간 날짜(+시각)를 due_at 으로. 시각이 없으면 그날 23:59(한국 시간), due_has_time = false.
create or replace function plan_due_from_kst(p_date text, p_time text, out due_at timestamptz, out has_time boolean)
language plpgsql immutable set search_path = public as $$
begin
  if p_date is null then
    if p_time is not null then perform plan_fail('invalid_input'); end if;
    due_at := null; has_time := false; return;
  end if;
  if p_date !~ '^\d{4}-\d{2}-\d{2}$' or (p_time is not null and p_time !~ '^([01]\d|2[0-3]):[0-5]\d$') then
    perform plan_fail('invalid_input');
  end if;
  due_at := ((p_date || ' ' || coalesce(p_time, '23:59'))::timestamp) at time zone 'Asia/Seoul';
  has_time := p_time is not null;
exception when datetime_field_overflow or invalid_datetime_format then
  perform plan_fail('invalid_input');
end $$;

-- ── 이어가는 일 ──
create or replace function create_thread(p_title text, p_primary_category category, p_share_title text, p_default_visibility visibility)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := plan_uid(); v_row threads; v_vis visibility := coalesce(p_default_visibility, 'private');
begin
  if p_title is null or p_primary_category is null then perform plan_fail('invalid_input'); end if;
  if v_vis in ('department', 'school') then perform plan_fail('visibility_not_available'); end if;
  insert into threads (user_id, title, share_title, primary_category, default_visibility)
  values (v_uid, btrim(p_title), nullif(btrim(p_share_title), ''), p_primary_category, v_vis)
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
  perform plan_check_patch(p_patch, array['title', 'share_title', 'primary_category', 'default_visibility']);
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
  update threads set title = v_row.title, share_title = v_row.share_title,
         primary_category = v_row.primary_category, default_visibility = v_row.default_visibility
   where id = v_row.id returning * into v_row;
  return plan_thread_json(v_row);
exception when check_violation or invalid_text_representation or string_data_right_truncation then
  perform plan_fail('invalid_input'); return null;
end $$;

create or replace function archive_thread(p_thread_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := plan_uid();
begin
  update threads set archived_at = coalesce(archived_at, now()) where id = p_thread_id and user_id = v_uid;
  if not found then perform plan_fail('not_found'); end if;
  return null;
end $$;

create or replace function list_threads()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_uid uuid := plan_uid();
begin
  return coalesce((select jsonb_agg(plan_thread_json(t) order by t.created_at desc, t.id)
                     from threads t where t.user_id = v_uid and t.archived_at is null), '[]'::jsonb);
end $$;

-- ── 할 일 ──
create or replace function create_todo(p_title text, p_thread_id uuid, p_due_at timestamptz, p_due_has_time boolean, p_estimate_min int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := plan_uid(); v_row todos;
begin
  if p_title is null then perform plan_fail('invalid_input'); end if;
  perform plan_own_thread(v_uid, p_thread_id);
  insert into todos (user_id, thread_id, title, due_at, due_has_time, estimate_min)
  values (v_uid, p_thread_id, btrim(p_title), p_due_at, case when p_due_at is null then false else coalesce(p_due_has_time, false) end, p_estimate_min)
  returning * into v_row;
  return plan_todo_json(v_row);
exception when check_violation then
  perform plan_fail('invalid_input'); return null;
end $$;

create or replace function update_todo(p_todo_id uuid, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := plan_uid(); v_row todos;
begin
  select * into v_row from todos where id = p_todo_id and user_id = v_uid for update;
  if not found then perform plan_fail('not_found'); end if;
  perform plan_check_patch(p_patch, array['title', 'thread_id', 'due_at', 'due_has_time', 'estimate_min']);
  if p_patch ? 'title' then
    if jsonb_typeof(p_patch->'title') <> 'string' then perform plan_fail('invalid_input'); end if;
    v_row.title := btrim(p_patch->>'title');
  end if;
  if p_patch ? 'thread_id' then
    if jsonb_typeof(p_patch->'thread_id') not in ('string', 'null') then perform plan_fail('invalid_input'); end if;
    v_row.thread_id := (p_patch->>'thread_id')::uuid;
    perform plan_own_thread(v_uid, v_row.thread_id);
  end if;
  if p_patch ? 'due_at' then
    if jsonb_typeof(p_patch->'due_at') not in ('string', 'null') then perform plan_fail('invalid_input'); end if;
    v_row.due_at := (p_patch->>'due_at')::timestamptz;
    if v_row.due_at is null then v_row.due_has_time := false; end if;
  end if;
  if p_patch ? 'due_has_time' then
    if jsonb_typeof(p_patch->'due_has_time') <> 'boolean' then perform plan_fail('invalid_input'); end if;
    v_row.due_has_time := (p_patch->>'due_has_time')::boolean and v_row.due_at is not null;
  end if;
  if p_patch ? 'estimate_min' then
    if jsonb_typeof(p_patch->'estimate_min') not in ('number', 'null') then perform plan_fail('invalid_input'); end if;
    v_row.estimate_min := (p_patch->>'estimate_min')::int;
  end if;
  update todos set title = v_row.title, thread_id = v_row.thread_id, due_at = v_row.due_at,
         due_has_time = v_row.due_has_time, estimate_min = v_row.estimate_min, updated_at = now()
   where id = v_row.id returning * into v_row;
  if v_row.status = 'done' then perform plan_after_todo_change(v_uid, v_row.id); end if;
  return plan_todo_json(v_row);
exception when check_violation or invalid_text_representation or datetime_field_overflow
  or invalid_datetime_format or numeric_value_out_of_range or string_data_right_truncation then
  perform plan_fail('invalid_input'); return null;
end $$;

create or replace function set_todo_status(p_todo_id uuid, p_status todo_status)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := plan_uid(); v_row todos;
begin
  if p_status is null then perform plan_fail('invalid_input'); end if;
  select * into v_row from todos where id = p_todo_id and user_id = v_uid for update;
  if not found then perform plan_fail('not_found'); end if;
  if p_status = 'done' then
    if v_row.status <> 'done' then
      update todos set status = 'done', completed_at = now(), completion_source = 'user_action', updated_at = now()
       where id = v_row.id returning * into v_row;
    end if;
  else
    update todos set status = p_status, completed_at = null, completion_source = null, updated_at = now()
     where id = v_row.id returning * into v_row;
  end if;
  perform plan_after_todo_change(v_uid, v_row.id);
  return plan_todo_json(v_row);
end $$;

create or replace function delete_todo(p_todo_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := plan_uid(); v_cat category;
begin
  v_cat := plan_todo_category(p_todo_id);
  delete from todos where id = p_todo_id and user_id = v_uid;
  if not found then perform plan_fail('not_found'); end if;
  if v_cat is not null then perform plan_recompute_estimate(v_uid, v_cat); end if;
  return null;
end $$;

create or replace function import_todos(p_source text, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := plan_uid(); v_item jsonb; v_row todos; v_created jsonb := '[]'::jsonb;
  v_n int := 0; v_done boolean; v_ref text; v_title text;
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
    v_row := null;
    insert into todos (user_id, title, due_at, due_has_time, estimate_min, status, completed_at,
                       completion_source, source, source_ref)
    values (v_uid, v_title, (v_item->>'due_at')::timestamptz,
            case when v_item->>'due_at' is null then false else coalesce((v_item->>'due_has_time')::boolean, false) end,
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

-- ── 예정 시간 ──
create or replace function create_plan_block(p_todo_id uuid, p_thread_id uuid, p_start_at timestamptz, p_end_at timestamptz, p_locked boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := plan_uid(); v_row plan_blocks; v_thread uuid := p_thread_id;
begin
  if p_start_at is null or p_end_at is null or p_end_at <= p_start_at then perform plan_fail('invalid_input'); end if;
  if p_todo_id is not null then
    select thread_id into v_thread from todos where id = p_todo_id and user_id = v_uid;
    if not found then perform plan_fail('not_found'); end if;
    v_thread := coalesce(p_thread_id, v_thread);
  end if;
  perform plan_own_thread(v_uid, v_thread);
  insert into plan_blocks (user_id, todo_id, thread_id, start_at, end_at, locked, origin)
  values (v_uid, p_todo_id, v_thread, p_start_at, p_end_at, coalesce(p_locked, false), 'user')
  returning * into v_row;
  return plan_block_json(v_row);
end $$;

create or replace function update_plan_block(p_block_id uuid, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := plan_uid(); v_row plan_blocks;
begin
  select * into v_row from plan_blocks where id = p_block_id and user_id = v_uid for update;
  if not found then perform plan_fail('not_found'); end if;
  perform plan_check_patch(p_patch, array['start_at', 'end_at', 'locked', 'status']);
  if v_row.status in ('started', 'moved') then perform plan_fail('invalid_input'); end if;
  if p_patch ? 'start_at' then
    if jsonb_typeof(p_patch->'start_at') <> 'string' then perform plan_fail('invalid_input'); end if;
    v_row.start_at := (p_patch->>'start_at')::timestamptz;
  end if;
  if p_patch ? 'end_at' then
    if jsonb_typeof(p_patch->'end_at') <> 'string' then perform plan_fail('invalid_input'); end if;
    v_row.end_at := (p_patch->>'end_at')::timestamptz;
  end if;
  if p_patch ? 'locked' then
    if jsonb_typeof(p_patch->'locked') <> 'boolean' then perform plan_fail('invalid_input'); end if;
    v_row.locked := (p_patch->>'locked')::boolean;
  end if;
  if p_patch ? 'status' then
    if p_patch->>'status' not in ('planned', 'cancelled') then perform plan_fail('invalid_input'); end if;
    v_row.status := (p_patch->>'status')::block_status;
  end if;
  update plan_blocks set start_at = v_row.start_at, end_at = v_row.end_at, locked = v_row.locked, status = v_row.status
   where id = v_row.id returning * into v_row;
  return plan_block_json(v_row);
exception when check_violation or invalid_text_representation or datetime_field_overflow
  or invalid_datetime_format or numeric_value_out_of_range then
  perform plan_fail('invalid_input'); return null;
end $$;

create or replace function delete_plan_block(p_block_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := plan_uid();
begin
  delete from plan_blocks where id = p_block_id and user_id = v_uid;
  if not found then perform plan_fail('not_found'); end if;
  return null;
end $$;

-- ── 오늘 ──
create or replace function get_today(p_day date, p_tz text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := plan_uid(); v_tz text := coalesce(nullif(p_tz, ''), 'Asia/Seoul');
  v_day date; v_s timestamptz; v_e timestamptz;
  v_todos jsonb; v_blocks jsonb; v_threads jsonb; v_live jsonb; v_factors jsonb;
begin
  v_day := coalesce(p_day, (now() at time zone v_tz)::date);
  v_s := v_day::timestamp at time zone v_tz;
  v_e := (v_day + 1)::timestamp at time zone v_tz;

  select coalesce(jsonb_agg(plan_todo_json(t) order by t.due_at nulls last, t.created_at, t.id), '[]'::jsonb) into v_todos
    from todos t
   where t.user_id = v_uid
     and (t.status in ('open', 'in_progress') or (t.status = 'done' and t.completed_at >= v_s and t.completed_at < v_e));

  select coalesce(jsonb_agg(plan_block_json(b) order by b.start_at, b.id), '[]'::jsonb) into v_blocks
    from plan_blocks b
   where b.user_id = v_uid and b.start_at < v_e and b.end_at > v_s and b.status not in ('cancelled', 'moved');

  select coalesce(jsonb_agg(plan_thread_json(th) order by th.created_at desc, th.id), '[]'::jsonb) into v_threads
    from threads th
   where th.user_id = v_uid
     and (th.archived_at is null
          or exists (select 1 from todos t where t.thread_id = th.id and t.user_id = v_uid
                      and (t.status in ('open', 'in_progress') or (t.status = 'done' and t.completed_at >= v_s and t.completed_at < v_e)))
          or exists (select 1 from plan_blocks b where b.thread_id = th.id and b.user_id = v_uid
                      and b.start_at < v_e and b.end_at > v_s and b.status not in ('cancelled', 'moved')));

  select public.session_json(s) into v_live from sessions s
   where s.user_id = v_uid and s.status in ('live', 'paused') limit 1;

  select coalesce(jsonb_object_agg(primary_category::text, factor), '{}'::jsonb) into v_factors
    from estimate_stats where user_id = v_uid;

  return jsonb_build_object('todos', v_todos, 'blocks', v_blocks, 'threads', v_threads,
                            'live_session', v_live, 'estimate_factors', v_factors);
exception when invalid_parameter_value or datetime_field_overflow then
  perform plan_fail('invalid_input'); return null;
end $$;

-- ── 제안 적용 ──
-- 규칙: 제안의 due_date + due_time 은 한국 시간(Asia/Seoul). due_time 이 있으면 그 시각이 due_at, due_has_time = true.
-- due_time 이 없으면 그날 23:59(한국 시간)을 due_at 으로 하고 due_has_time = false. due_date 가 없으면 둘 다 null/false.
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

-- ── 비서 입력 (서버 함수가 서비스 키로 호출) ──
create or replace function assistant_context(p_user uuid, p_now timestamptz)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_todos jsonb; v_blocks jsonb; v_factors jsonb;
begin
  select coalesce(jsonb_object_agg(primary_category::text, factor), '{}'::jsonb) into v_factors
    from estimate_stats where user_id = p_user;

  select coalesce(jsonb_agg(x.j order by x.ord), '[]'::jsonb) into v_todos from (
    select jsonb_build_object(
             'id', t.id, 'title', t.title,
             'due_date', case when t.due_at is null then null else to_char(t.due_at at time zone 'Asia/Seoul', 'YYYY-MM-DD') end,
             'due_time', case when t.due_at is not null and t.due_has_time then to_char(t.due_at at time zone 'Asia/Seoul', 'HH24:MI') end,
             'estimate_min', t.estimate_min, 'status', t.status,
             'category', cat.c,
             'estimate_min_calibrated',
               case when t.estimate_min is not null and (v_factors ? cat.c::text)
                    then round(t.estimate_min * (v_factors->>(cat.c::text))::numeric)::int end) as j,
           row_number() over (order by t.due_at nulls last, t.created_at, t.id) as ord
      from todos t
      left join lateral (select plan_todo_category(t.id) as c) cat on true
     where t.user_id = p_user
       and (t.status in ('open', 'in_progress') or (t.status = 'done' and t.completed_at >= p_now - interval '2 days'))
     order by t.due_at nulls last, t.created_at, t.id
     limit 200) x;

  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'todo_id', b.todo_id,
           'start', plan_kst(b.start_at), 'end', plan_kst(b.end_at), 'locked', b.locked) order by b.start_at, b.id), '[]'::jsonb)
    into v_blocks
    from plan_blocks b
   where b.user_id = p_user and b.status = 'planned' and b.end_at > p_now and b.start_at < p_now + interval '14 days';

  return jsonb_build_object('todos', v_todos, 'blocks', v_blocks, 'estimate_factors', v_factors);
end $$;

-- ── 권한 ──
do $$
declare f text;
begin
  -- 모든 함수 기본 권한 제거(내부 도우미 포함)
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and (p.proname like 'plan\_%' escape '\'
              or p.proname in ('create_thread','update_thread','archive_thread','list_threads','create_todo','update_todo',
                'set_todo_status','delete_todo','import_todos','create_plan_block','update_plan_block','delete_plan_block',
                'get_today','apply_proposal','assistant_context'))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;

grant execute on function
  create_thread(text, category, text, visibility), update_thread(uuid, jsonb), archive_thread(uuid), list_threads(),
  create_todo(text, uuid, timestamptz, boolean, int), update_todo(uuid, jsonb), set_todo_status(uuid, todo_status),
  delete_todo(uuid), import_todos(text, jsonb),
  create_plan_block(uuid, uuid, timestamptz, timestamptz, boolean), update_plan_block(uuid, jsonb), delete_plan_block(uuid),
  get_today(date, text), apply_proposal(uuid, int[], int[], boolean)
  to authenticated;
grant execute on function assistant_context(uuid, timestamptz) to service_role;
