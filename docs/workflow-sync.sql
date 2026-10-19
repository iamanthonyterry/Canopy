-- Canopy: workflows that follow your sign-in, and runs you can watch from any signed-in computer.
-- Apply once to the church's Supabase project (SQL editor, or `supabase db push`). Safe to re-run.

-- 1. Workflows, one row per workflow per signed-in person ------------------------------------------
-- `definition` is the workflow's JSON as Canopy saves it, kept as text so it round-trips exactly.
-- A deleted workflow keeps its row with `deleted_at` set, so other computers learn to remove it too.
create table if not exists public.canopy_workflows (
  user_id     uuid        not null references auth.users (id) on delete cascade,
  id          uuid        not null,
  name        text        not null,
  definition  text        not null,
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  primary key (user_id, id)
);

create index if not exists canopy_workflows_user_updated on public.canopy_workflows (user_id, updated_at);

alter table public.canopy_workflows enable row level security;

drop policy if exists "canopy workflows: own rows" on public.canopy_workflows;
create policy "canopy workflows: own rows" on public.canopy_workflows
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- The server stamps every change, so computers with different clocks still agree on what's newer.
create or replace function public.canopy_touch_updated_at() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists canopy_workflows_touch on public.canopy_workflows;
create trigger canopy_workflows_touch
  before insert or update on public.canopy_workflows
  for each row execute function public.canopy_touch_updated_at();

-- 2. Run progress: which computer a run is on, and when it last reported ----------------------------
alter table public.workflow_runs add column if not exists device_id  text;
alter table public.workflow_runs add column if not exists updated_at timestamptz not null default now();

drop trigger if exists workflow_runs_touch on public.workflow_runs;
create trigger workflow_runs_touch
  before update on public.workflow_runs
  for each row execute function public.canopy_touch_updated_at();

create index if not exists workflow_runs_user_finished on public.workflow_runs (user_id, finished_at);

-- Canopy reads back the signed-in person's own runs. (Permissive policies add up, so this
-- doesn't narrow whatever the website already allows.)
drop policy if exists "canopy runs: read own" on public.workflow_runs;
create policy "canopy runs: read own" on public.workflow_runs
  for select to authenticated
  using (user_id = auth.uid());

-- 3. Computers, and running a workflow on another one -----------------------------------------------
-- Each signed-in computer keeps one row here (its name, the workflows it has, whether it accepts runs
-- from your other computers, and when it was last seen). A "run this there" request is a row in
-- canopy_commands that the target computer picks up, claims and starts.
create table if not exists public.canopy_computers (
  user_id        uuid        not null references auth.users (id) on delete cascade,
  device_id      text        not null,
  name           text        not null,
  accepts_remote boolean     not null default false,
  workflows      jsonb       not null default '[]'::jsonb,
  last_seen      timestamptz not null default now(),
  primary key (user_id, device_id)
);

alter table public.canopy_computers enable row level security;
drop policy if exists "canopy computers: own rows" on public.canopy_computers;
create policy "canopy computers: own rows" on public.canopy_computers
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create or replace function public.canopy_touch_last_seen() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.last_seen = now();
  return new;
end;
$$;

drop trigger if exists canopy_computers_touch on public.canopy_computers;
create trigger canopy_computers_touch
  before insert or update on public.canopy_computers
  for each row execute function public.canopy_touch_last_seen();

create table if not exists public.canopy_commands (
  id               uuid        primary key default gen_random_uuid(),
  user_id          uuid        not null references auth.users (id) on delete cascade,
  from_device_id   text        not null,
  target_device_id text        not null,
  workflow_id      uuid        not null,
  workflow_name    text        not null,
  status           text        not null default 'pending',   -- pending, started, refused
  detail           text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create index if not exists canopy_commands_target on public.canopy_commands (user_id, target_device_id, status);

alter table public.canopy_commands enable row level security;
drop policy if exists "canopy commands: own rows" on public.canopy_commands;
create policy "canopy commands: own rows" on public.canopy_commands
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop trigger if exists canopy_commands_touch on public.canopy_commands;
create trigger canopy_commands_touch
  before update on public.canopy_commands
  for each row execute function public.canopy_touch_updated_at();
