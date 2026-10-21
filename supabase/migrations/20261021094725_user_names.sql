-- Phase 44: first and last name move out of the auth metadata into a table.
--
-- Until now the username screen wrote `first_name`/`last_name` into the auth
-- user_metadata through auth.updateUser (AuthService.saveNames) and nothing
-- read them back: not the export (backlog 1.32, an incomplete Art. 20
-- response), not the app, and no constraint said what a name may be. This
-- migration makes a table the only copy, on the user_genders pattern:
--
--   1. user_names -- owner-read-only, because profiles is readable by everyone
--      and a legal name is not something a stranger should get from a handle.
--   2. person_name_is_valid / set_my_names -- the one rule and the client's
--      only write door. complete_onboarding (next migration) is the other.
--   3. The names already given are copied once, then stripped from the
--      metadata. The apply FAILS if any account holds a name the copy cannot
--      take, because the strip would otherwise delete it.
--
-- No ongoing strip trigger, unlike gender: GoTrue never writes these keys on
-- its own, and with saveNames deleted from the client nothing else does.
-- Gender needed one because sign-up itself carries the answer and GoTrue writes
-- the metadata back after handle_new_user. Export and erasure are in
-- 20261021094727.


-- ===========================================================================
-- 1. The rule.
--
-- Trimmed, 1-50 characters, no control characters (which covers newlines and
-- the NUL that bio's CHECK refuses). Deliberately nothing about letters:
-- names are not ASCII, and "what is a valid name" has no answer that does not
-- refuse a real person somewhere. The caller trims; this answers about the
-- value as it would be stored.
-- ===========================================================================
create function public.person_name_is_valid(p_name text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_name is not null
     and p_name = btrim(p_name)
     and char_length(p_name) between 1 and 50
     and p_name !~ '[[:cntrl:]]';
$$;

revoke execute on function public.person_name_is_valid(text) from public, anon, authenticated;


-- ===========================================================================
-- 2. The table.
-- ===========================================================================
create table public.user_names (
  -- profiles, not auth.users: the tombstone outlives the auth user (Phase 9),
  -- and complete_account_erasure deletes this row explicitly.
  user_id    uuid primary key references public.profiles (id) on delete cascade,
  first_name text not null check (public.person_name_is_valid(first_name)),
  last_name  text not null check (public.person_name_is_valid(last_name)),
  updated_at timestamptz not null default now()
);

alter table public.user_names enable row level security;

create policy "user_names: owner reads own"
  on public.user_names
  for select
  to authenticated
  using (user_id = (select auth.uid()));

-- Gotcha 9 / 23: strip, then grant only the read. Writes go through
-- set_my_names and complete_onboarding, so there is no column grant for a
-- PostgREST upsert to trip over (gotcha 12).
revoke all on public.user_names from anon, authenticated;
grant select on public.user_names to authenticated;

comment on table public.user_names is
  'First and last name. Owner-read-only: shown to nobody else. Written by '
  'complete_onboarding and set_my_names; exported; deleted on erasure.';


-- ===========================================================================
-- 3. The write door.
--
-- Both names, every time: the onboarding screen has always required both, so
-- a half-row is not a state the app can produce and the table does not hold
-- one. Trimmed here so a trailing space is not a refusal.
-- ===========================================================================
create function public.set_my_names(p_first_name text, p_last_name text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_first text := btrim(p_first_name);
  v_last  text := btrim(p_last_name);
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  if not public.person_name_is_valid(v_first) or not public.person_name_is_valid(v_last) then
    raise exception 'invalid name' using errcode = '22023';
  end if;

  insert into public.user_names (user_id, first_name, last_name)
  values (v_uid, v_first, v_last)
  on conflict on constraint user_names_pkey
  do update set first_name = excluded.first_name,
                last_name  = excluded.last_name,
                updated_at = now();
end;
$$;

revoke execute on function public.set_my_names(text, text) from public, anon;
grant  execute on function public.set_my_names(text, text) to authenticated;

comment on function public.set_my_names(text, text) is
  'Sets the caller''s own first and last name (both required, trimmed, 1-50 '
  'characters). The client''s write door to user_names after onboarding.';


-- ===========================================================================
-- 4. The names already given: copy once, then strip.
--
-- The copy takes a pair where both values are valid once trimmed. The strip
-- removes the keys from every account. Between the two sits a check: an
-- account whose metadata holds a name the copy did NOT take (one half missing,
-- over 50 characters, a control character) fails the apply, because the strip
-- would destroy the only copy. That is a decision for a person, not a
-- migration -- the Phase 17 backfill check is the precedent.
-- ===========================================================================
insert into public.user_names (user_id, first_name, last_name)
select u.id,
       btrim(u.raw_user_meta_data ->> 'first_name'),
       btrim(u.raw_user_meta_data ->> 'last_name')
from auth.users u
join public.profiles p on p.id = u.id
where public.person_name_is_valid(btrim(u.raw_user_meta_data ->> 'first_name'))
  and public.person_name_is_valid(btrim(u.raw_user_meta_data ->> 'last_name'))
on conflict on constraint user_names_pkey do nothing;

do $$
declare
  v_lost integer;
begin
  select count(*) into v_lost
  from auth.users u
  where (u.raw_user_meta_data ? 'first_name' or u.raw_user_meta_data ? 'last_name')
    and nullif(btrim(coalesce(u.raw_user_meta_data ->> 'first_name', '')
                     || coalesce(u.raw_user_meta_data ->> 'last_name', '')), '') is not null
    and not exists (select 1 from public.user_names n where n.user_id = u.id);

  if v_lost > 0 then
    raise exception '% account(s) hold a first/last name the copy cannot take; stripping would lose it', v_lost
      using errcode = 'P0001',
            hint = 'Inspect auth.users.raw_user_meta_data for first_name/last_name with no user_names row.';
  end if;
end;
$$;

update auth.users
set raw_user_meta_data = raw_user_meta_data - 'first_name' - 'last_name'
where raw_user_meta_data ? 'first_name' or raw_user_meta_data ? 'last_name';
