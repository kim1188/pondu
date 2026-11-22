-- 전체 테이블 정의. 모든 작업 흐름이 이 스키마를 기준으로 한다.
-- 이 파일에는 테이블·타입·인덱스만 둔다. 함수와 접근 규칙은 흐름별 마이그레이션에 둔다.
-- 모든 테이블은 접근 규칙을 켠 채(기본 거부) 시작한다. 앱은 테이블을 직접 쓰지 않고 함수만 부른다.

create extension if not exists pgcrypto;

create type category as enum ('study', 'coding', 'exercise', 'project', 'venture_research_intern', 'parttime');
create type session_status as enum ('live', 'paused', 'ended', 'needs_confirmation');
create type session_outcome as enum ('done', 'more', 'stop');
create type capture_mode as enum ('in_app_photo', 'no_photo');
create type visibility as enum ('private', 'friends', 'crew', 'department', 'school');
create type todo_status as enum ('open', 'in_progress', 'done', 'dropped');
create type completion_source as enum ('user_action', 'user_statement', 'imported');
create type block_status as enum ('planned', 'started', 'missed', 'moved', 'cancelled');
create type block_origin as enum ('user', 'assistant');
create type friendship_status as enum ('pending', 'accepted');
create type group_kind as enum ('crew', 'department');
create type member_role as enum ('owner', 'member');
create type member_status as enum ('active', 'removed');
create type report_status as enum ('open', 'reviewed', 'dismissed');

-- ── 흐름 A: 학교, 프로필 ──
create table schools (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email_domains text[] not null,
  created_at timestamptz not null default now()
);

create table departments (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools,
  name text not null,
  unique (school_id, name)
);

create table profiles (
  id uuid primary key references auth.users on delete cascade,
  school_id uuid not null references schools,
  handle text not null check (handle ~ '^[a-z0-9_]{3,20}$'),
  display_name text not null check (char_length(display_name) between 1 and 20),
  department_id uuid references departments,
  avatar_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index profiles_handle_key on profiles (lower(handle));
create index profiles_school_idx on profiles (school_id);

create table device_tokens (
  user_id uuid not null references profiles on delete cascade,
  token text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, token)
);

-- ── 흐름 D: 이어가는 일, 할 일, 예정 시간 ──
create table threads (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles on delete cascade,
  title text not null check (char_length(title) between 1 and 60),
  share_title text check (char_length(share_title) <= 60),
  primary_category category not null,
  default_visibility visibility not null default 'private',
  default_group_id uuid,
  archived_at timestamptz,
  created_at timestamptz not null default now()
);
create index threads_user_idx on threads (user_id) where archived_at is null;

create table todos (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles on delete cascade,
  thread_id uuid references threads on delete set null,
  title text not null check (char_length(title) between 1 and 200),
  due_at timestamptz,
  due_has_time boolean not null default false,
  estimate_min int check (estimate_min between 1 and 1440),
  status todo_status not null default 'open',
  completed_at timestamptz,
  completion_source completion_source,
  source text not null default 'manual',
  source_ref text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index todos_user_status_due_idx on todos (user_id, status, due_at);
create unique index todos_source_key on todos (user_id, source, source_ref) where source_ref is not null;

create table plan_blocks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles on delete cascade,
  todo_id uuid references todos on delete cascade,
  thread_id uuid references threads on delete set null,
  start_at timestamptz not null,
  end_at timestamptz not null,
  locked boolean not null default false,
  origin block_origin not null default 'user',
  status block_status not null default 'planned',
  created_at timestamptz not null default now(),
  check (end_at > start_at)
);
create index plan_blocks_user_start_idx on plan_blocks (user_id, start_at);

create table estimate_stats (
  user_id uuid not null references profiles on delete cascade,
  primary_category category not null,
  factor numeric(4, 2) not null check (factor between 0.5 and 3.0),
  sample_count int not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, primary_category)
);

-- ── 흐름 B: 세션 ──
create table sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles on delete cascade,
  client_id uuid not null,
  thread_id uuid references threads on delete set null,
  todo_id uuid references todos on delete set null,
  plan_block_id uuid references plan_blocks on delete set null,
  joined_session_id uuid references sessions on delete set null,
  primary_category category not null,
  tags text[] not null default '{}',
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  paused_at timestamptz,
  paused_seconds int not null default 0,
  status session_status not null default 'live',
  outcome session_outcome,
  capture_mode capture_mode not null default 'no_photo',
  photo_path text,
  photo_thumb_path text,
  share_title text check (char_length(share_title) <= 60),
  progress_note text check (char_length(progress_note) <= 200),
  visibility visibility not null default 'private',
  group_id uuid,
  end_corrected boolean not null default false,
  offline_started_at timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, client_id)
);
create index sessions_user_started_idx on sessions (user_id, started_at desc);
create unique index sessions_one_active_key on sessions (user_id) where status in ('live', 'paused');
create index sessions_shared_started_idx on sessions (started_at desc) where visibility <> 'private';
create index sessions_thread_idx on sessions (thread_id, started_at desc) where thread_id is not null;

create table session_events (
  id bigint generated always as identity primary key,
  session_id uuid not null references sessions on delete cascade,
  type text not null,
  at timestamptz not null default now(),
  payload jsonb not null default '{}'
);
create index session_events_session_idx on session_events (session_id, at);

create table daily_stats (
  user_id uuid not null references profiles on delete cascade,
  day date not null,
  primary_category category not null,
  seconds int not null default 0,
  session_count int not null default 0,
  primary key (user_id, day, primary_category)
);

-- ── 흐름 C: 친구, 크루, 피드 ──
create table friendships (
  user_a uuid not null references profiles on delete cascade,
  user_b uuid not null references profiles on delete cascade,
  status friendship_status not null default 'pending',
  requested_by uuid not null references profiles on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_a, user_b),
  check (user_a < user_b)
);
create index friendships_b_idx on friendships (user_b, status);
create index friendships_a_idx on friendships (user_a, status);

create table groups (
  id uuid primary key default gen_random_uuid(),
  school_id uuid not null references schools,
  kind group_kind not null default 'crew',
  name text not null check (char_length(name) between 1 and 30),
  owner_id uuid not null references profiles on delete cascade,
  invite_code text not null unique,
  created_at timestamptz not null default now()
);

alter table threads add constraint threads_default_group_fkey
  foreign key (default_group_id) references groups on delete set null;
alter table sessions add constraint sessions_group_fkey
  foreign key (group_id) references groups on delete set null;
create index sessions_group_idx on sessions (group_id, started_at desc) where group_id is not null;

create table group_members (
  group_id uuid not null references groups on delete cascade,
  user_id uuid not null references profiles on delete cascade,
  role member_role not null default 'member',
  status member_status not null default 'active',
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index group_members_user_idx on group_members (user_id, status);

-- 거절당한 친구 요청 기록(7일 동안 같은 상대에게 다시 요청하지 못하게 한다). 요청한 사람 기준.
create table friend_request_rejections (
  requester_id uuid not null references profiles on delete cascade,
  target_id uuid not null references profiles on delete cascade,
  rejected_at timestamptz not null default now(),
  primary key (requester_id, target_id)
);
create index friend_request_rejections_target_idx on friend_request_rejections (target_id);

create table reactions (
  session_id uuid not null references sessions on delete cascade,
  user_id uuid not null references profiles on delete cascade,
  kind text not null check (kind in ('cheer', 'fire', 'clap')),
  created_at timestamptz not null default now(),
  primary key (session_id, user_id)
);

create table comments (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references sessions on delete cascade,
  user_id uuid not null references profiles on delete cascade,
  body text not null check (char_length(body) between 1 and 200),
  created_at timestamptz not null default now()
);
create index comments_session_idx on comments (session_id, created_at);

create table blocks (
  blocker_id uuid not null references profiles on delete cascade,
  blocked_id uuid not null references profiles on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id)
);
create index blocks_blocked_idx on blocks (blocked_id);

create table reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references profiles on delete cascade,
  session_id uuid not null references sessions on delete cascade,
  reason text not null check (char_length(reason) between 1 and 500),
  status report_status not null default 'open',
  created_at timestamptz not null default now(),
  unique (reporter_id, session_id)
);

-- ── 흐름 E: 비서, 알림 ──
create table assistant_runs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles on delete cascade,
  kind text not null,
  model text,
  input_tokens int,
  output_tokens int,
  latency_ms int,
  ok boolean not null,
  created_at timestamptz not null default now()
);
create index assistant_runs_user_day_idx on assistant_runs (user_id, created_at desc);

create table assistant_proposals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles on delete cascade,
  kind text not null,
  input jsonb not null,
  proposal jsonb not null,
  created_at timestamptz not null default now(),
  applied_at timestamptz
);
create index assistant_proposals_user_idx on assistant_proposals (user_id, created_at desc);

create table notification_outbox (
  id bigint generated always as identity primary key,
  user_id uuid not null references profiles on delete cascade,
  kind text not null,
  payload jsonb not null default '{}',
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create index notification_outbox_pending_idx on notification_outbox (id) where sent_at is null;

-- 기본 거부: 흐름별 마이그레이션이 필요한 만큼만 연다.
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;
