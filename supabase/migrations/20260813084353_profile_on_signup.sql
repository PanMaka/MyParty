-- Phase 1 (Identity): profiles.id has no default and no trigger, so a
-- fresh auth.users signup has nothing in public.profiles. Two concrete
-- breakages follow: parties.host_id references public.profiles(id), so a
-- brand-new user can't even host a party (FK violation), and
-- get_parties_near_user inner-joins parties to profiles for
-- host_username, so any party whose host lacks a profile silently
-- disappears from every map query. This migration adds a trigger that
-- guarantees every auth.users row gets a matching profiles row, plus the
-- onboarding/consent columns and username-lookup RPC that depend on it.

-- Builds a placeholder username. The uuid suffix (not the prefix) is what
-- makes collisions structurally impossible -- two different users can
-- never produce the same suffix -- which is why this is safe even though
-- it also folds in OAuth-provided name/email for readability.
create or replace function public.placeholder_username(
  p_id uuid,
  p_meta jsonb,
  p_email text
)
returns text
language sql
immutable
set search_path = ''
as $$
  select
    left(
      regexp_replace(
        lower(
          coalesce(
            nullif(trim(p_meta ->> 'full_name'), ''),
            nullif(trim(p_meta ->> 'name'), ''),
            nullif(trim(split_part(coalesce(p_email, ''), '@', 1)), ''),
            'user'
          )
        ),
        '[^a-z0-9]+', '_', 'g'
      ),
      20
    ) || '_' || replace(p_id::text, '-', '');
$$;

-- security definer + set search_path = '' per CLAUDE.md rule 3: every
-- definer function must be immune to a hijacked search_path, and every
-- reference inside it is fully schema-qualified.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, username)
  values (
    new.id,
    public.placeholder_username(new.id, new.raw_user_meta_data, new.email)
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Backfill: any auth.users row that predates this trigger. Reuses the
-- exact same placeholder_username() the trigger uses, so backfilled users
-- get identically-shaped placeholders to new signups.
insert into public.profiles (id, username)
select u.id, public.placeholder_username(u.id, u.raw_user_meta_data, u.email)
from auth.users u
where not exists (
  select 1 from public.profiles p where p.id = u.id
)
on conflict (id) do nothing;

-- Onboarding: null until the user picks a real username, so the client
-- can gate the "choose a username" step on this instead of string-
-- matching the placeholder shape.
alter table public.profiles add column onboarding_completed_at timestamptz;

-- Consent flags (Phase 7.2): created now, enforced in policy later.
-- Default false -- opt-in, not opt-out, per GDPR.
alter table public.profiles add column location_consent boolean not null default false;
alter table public.profiles add column push_consent boolean not null default false;
alter table public.profiles add column analytics_consent boolean not null default false;

-- Case-insensitive username uniqueness: the original schema's plain
-- `unique` constraint on username is case-sensitive and would let "Bob"
-- and "bob" coexist. Drop it and replace with a case-insensitive index.
alter table public.profiles drop constraint if exists profiles_username_key;
create unique index profiles_username_lower_idx on public.profiles (lower(username));

-- Lets the client check availability before attempting to claim a
-- username. profiles is already publicly readable, so this needs no
-- elevated privileges.
create or replace function public.check_username_available(p_username text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select not exists (
    select 1 from public.profiles where lower(username) = lower(p_username)
  );
$$;
