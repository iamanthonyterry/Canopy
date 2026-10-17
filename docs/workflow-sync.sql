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
