-- Phase 44: profile writes that mean something go through functions.
--
-- `authenticated` held UPDATE on the whole of public.profiles. The owner-only
-- row policy decided WHICH row, and protect_credibility_score silently put
-- back the counters and the deletion stamps -- but nothing guarded `username`
-- (no format rule at all on the server: the client's "3 characters" was the
-- only check, and a rename to `deleted_<32 hex>` impersonated a tombstone in
-- user_link.dart), the three consents, `onboarding_completed_at` (stamped from
-- the CLIENT's clock) or `created_at` (a forgeable "member since").
--
--   1. UPDATE narrows to a column allow-list: exactly the eleven columns the
--      client writes through PostgREST today, audited at Phase 44. Everything
--      else is written by a definer function or by nothing.
--   2. Consents: set_location_consent / set_push_consent, with the moment
--      consent was given recorded in user_consents (owner-read-only).
--   3. Usernames: one format rule, a 30-day cooldown on changes, and a 14-day
--      reservation of the name given up. complete_onboarding sets the first
--      one (and the names, 20261021094725) without starting the cooldown;
--      change_username does every change after that.
--
-- What was checked before revoking (Phase 44 audit): the client writes
-- username + onboarding_completed_at in ProfileRepository.completeOnboarding
-- and the two consents in DeviceRepository; every server writer of these
-- columns is security definer, so the narrower grant does not reach them; no
-- edge function or script PATCHes profiles. analytics_consent has no writer
-- anywhere and gets no setter -- one can come with the feature.


-- ===========================================================================
-- 1. The grant.
--
-- revoke-then-grant because a table-wide privilege cannot have one column
-- taken out of it. protect_credibility_score stays as a second layer: the
-- client can no longer name those columns, but a future grant could.
--
-- SELECT stays table-wide. 14_profile_and_party_media's guard is about a
-- column-scoped SELECT breaking bio's inherited block filter, and is narrowed
-- to SELECT ACLs in the same commit.
-- ===========================================================================
revoke update on public.profiles from authenticated;

grant update (
  bio,
  avatar_path,
  map_visibility,
  invite_policy,
  dm_policy,
  notify_nearby,
  notify_radius_meters,
  notify_daily_cap,
  notification_tz,
  quiet_hours_start,
  quiet_hours_end
) on public.profiles to authenticated;


-- ===========================================================================
-- 2. Consents.
--
-- *_consent_at is the moment consent was last GIVEN, and it is KEPT when
-- consent is withdrawn. GDPR Art. 7(1) asks the controller to be able to show
-- that consent existed for processing that happened; clearing the stamp on
-- withdrawal would erase exactly that record for the period it covers. The
-- boolean on profiles says whether it holds now. A repeated "true" while
-- already true keeps the original moment (PushService re-asserts it), so the
-- stamp means "given at", not "last re-confirmed at".
--
-- Not on profiles: that table is readable by every caller, anon included, and
-- when someone turned location on is not a stranger's business. The booleans
-- themselves are readable there today; that predates this phase
-- (docs/backlog.md 1.38).
--
-- NULL = unknown for consent given before this migration. Not backfilled with
-- a guess: a made-up date is worse evidence than none.
-- ===========================================================================
create table public.user_consents (
  user_id             uuid primary key references public.profiles (id) on delete cascade,
  location_consent_at timestamptz,
  push_consent_at     timestamptz
);

alter table public.user_consents enable row level security;

create policy "user_consents: owner reads own"
  on public.user_consents
  for select
  to authenticated
  using (user_id = (select auth.uid()));

revoke all on public.user_consents from anon, authenticated;
grant select on public.user_consents to authenticated;

comment on table public.user_consents is
  'When location / push consent was last given. Kept on withdrawal (Art. 7(1)); '
  'the current state is the boolean on profiles. Written only by the consent '
  'setters; exported; deleted on erasure.';

-- Refuses GRANTING consent on an account scheduled for deletion:
-- request_account_deletion turns every consent off and purges devices at T+0,
-- and a client holding a still-valid JWT could otherwise turn location back on
-- for the rest of the grace period. Withdrawing is always accepted.
create function public.set_location_consent(p_granted boolean)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_was boolean;
  v_deleted timestamptz;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if p_granted is null then
    raise exception 'consent must be true or false' using errcode = '22023';
  end if;

  select p.location_consent, p.deleted_at into v_was, v_deleted
  from public.profiles p where p.id = v_uid
  for update;

  if not found then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if p_granted and v_deleted is not null then
    raise exception 'account is scheduled for deletion' using errcode = '42501';
  end if;

  -- The AFTER trigger on location_consent (true -> not true) clears every
  -- stored cell, exactly as it did for the client's PATCH.
  update public.profiles set location_consent = p_granted where id = v_uid;

  if p_granted and v_was is not true then
    insert into public.user_consents (user_id, location_consent_at)
    values (v_uid, now())
    on conflict on constraint user_consents_pkey
    do update set location_consent_at = excluded.location_consent_at;
  end if;
end;
$$;

create function public.set_push_consent(p_granted boolean)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_was boolean;
  v_deleted timestamptz;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if p_granted is null then
    raise exception 'consent must be true or false' using errcode = '22023';
  end if;

  select p.push_consent, p.deleted_at into v_was, v_deleted
  from public.profiles p where p.id = v_uid
  for update;

  if not found then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if p_granted and v_deleted is not null then
    raise exception 'account is scheduled for deletion' using errcode = '42501';
  end if;

  update public.profiles set push_consent = p_granted where id = v_uid;

  if p_granted and v_was is not true then
    insert into public.user_consents (user_id, push_consent_at)
    values (v_uid, now())
    on conflict on constraint user_consents_pkey
    do update set push_consent_at = excluded.push_consent_at;
  end if;
end;
$$;

revoke execute on function public.set_location_consent(boolean) from public, anon;
grant  execute on function public.set_location_consent(boolean) to authenticated;
revoke execute on function public.set_push_consent(boolean) from public, anon;
grant  execute on function public.set_push_consent(boolean) to authenticated;

comment on function public.set_location_consent(boolean) is
  'The client''s only write to profiles.location_consent. Stamps '
  'user_consents.location_consent_at on false->true; refuses true while the '
  'account is scheduled for deletion.';
comment on function public.set_push_consent(boolean) is
  'The client''s only write to profiles.push_consent. Stamps '
  'user_consents.push_consent_at on false->true; refuses true while the '
  'account is scheduled for deletion.';


-- ===========================================================================
-- 3. Usernames: the rule and the two numbers.
--
-- 3-30 of [A-Za-z0-9_.], no leading or trailing dot, no two dots in a row,
-- and not starting with `deleted_` (any case). The length cap alone already
-- puts the tombstone handle (`deleted_` + 32 hex = 40) out of reach; the
-- prefix refusal is there so a short `deleted_x` cannot look like one either.
--
-- Enforced inside the write functions, NOT as a CHECK: sign-up placeholders
-- (cleaned name + `_` + 32 hex, up to 53) and tombstones legitimately fail it,
-- and so may a name chosen before this rule existed. Those keep their name;
-- the rule applies to the next one they choose.
-- ===========================================================================
create function public.username_is_valid(p_username text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_username is not null
     and p_username ~ '^[A-Za-z0-9_.]{3,30}$'
     and p_username !~ '^\.'
     and p_username !~ '\.$'
     and p_username !~ '\.\.'
     and lower(p_username) not like 'deleted\_%';
$$;

create function public.username_change_cooldown()
returns interval
language sql
immutable
set search_path = ''
as $$ select interval '30 days' $$;

create function public.username_reservation_period()
returns interval
language sql
immutable
set search_path = ''
as $$ select interval '14 days' $$;

-- The client asks username_is_valid through the functions that enforce it,
-- and reads the cooldown back as a date (username_next_change_at), so none of
-- the three is granted to a client role: the Dart copy of the format rule is
-- the one second copy, and it is for the keyboard, not the decision.
revoke execute on function public.username_is_valid(text) from public, anon, authenticated;
revoke execute on function public.username_change_cooldown() from public, anon, authenticated;
revoke execute on function public.username_reservation_period() from public, anon, authenticated;


-- ===========================================================================
-- 4. The change record, which is also the reservation.
--
-- One row per user: the name they gave up and when. That is enough for both
-- rules because the cooldown (30d) outlasts the reservation (14d): by the time
-- a user may change again, the previous reservation has already lapsed, so
-- nobody ever holds two.
--
-- No client grant at all. The client needs one fact from it -- when the next
-- change is allowed -- and gets it from username_next_change_at; the old name
-- is in the export.
-- ===========================================================================
create table public.username_changes (
  user_id           uuid primary key references public.profiles (id) on delete cascade,
  previous_username text not null,
  changed_at        timestamptz not null default now()
);

alter table public.username_changes enable row level security;
revoke all on public.username_changes from anon, authenticated;

create index username_changes_previous_lower_idx
  on public.username_changes (lower(previous_username));

comment on table public.username_changes is
  'Last username change per user. changed_at drives the 30-day cooldown; '
  'previous_username is reserved for 14 days after it. No client access: '
  'read through username_next_change_at, exported, deleted on erasure.';

-- "Is this name unavailable to p_user": held by ANY profile (the caller's own
-- included -- a case-only change is handled by the caller), or reserved by
-- someone else. One definition for check_username_available,
-- complete_onboarding and change_username (rule 4).
create function public.username_unavailable(p_username text, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
           select 1 from public.profiles pr
           where lower(pr.username) = lower(p_username)
         )
      or exists (
           select 1 from public.username_changes c
           where lower(c.previous_username) = lower(p_username)
             and c.changed_at > now() - public.username_reservation_period()
             and c.user_id is distinct from p_user
         );
$$;

revoke execute on function public.username_unavailable(text, uuid) from public, anon, authenticated;

-- Serialises every claim on one name, so a reservation and a claim cannot
-- interleave: change_username(A: x -> y) and complete_onboarding(B: x) both
-- take the lock on 'x', and whichever comes second re-reads after the first
-- commits (READ COMMITTED takes a fresh snapshot per statement).
create function public.lock_username(p_username text)
returns void
language sql
volatile
set search_path = ''
as $$
  select pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('username:' || lower(p_username), 0));
$$;

revoke execute on function public.lock_username(text) from public, anon, authenticated;


-- ===========================================================================
-- 5. check_username_available learns about reservations.
--
-- Otherwise the screen says "available" for a name the write then refuses.
-- The answer is still a boolean: a reserved name reads as taken, the same as
-- a held one, so the check cannot be used to learn that someone just renamed.
-- Same signature, so its ACL (PUBLIC, unchanged since 20260814104618) stays.
-- ===========================================================================
create or replace function public.check_username_available(p_username text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not public.username_unavailable(p_username, (select auth.uid()));
$$;


-- ===========================================================================
-- 6. complete_onboarding: the first username, the names, the stamp.
--
-- Replaces the client's PATCH of username + onboarding_completed_at and its
-- separate auth.updateUser for the names. One transaction, so the old "names
-- first, because anything after completeOnboarding might never run" ordering
-- hazard is gone. The stamp is the server's clock.
--
-- Does NOT start the cooldown: the placeholder was never chosen, so a user can
-- fix a regretted sign-up name straight away, once. Nor does it reserve the
-- placeholder, which carries the user's uuid and cannot be wanted by anyone.
-- ===========================================================================
create function public.complete_onboarding(
  p_username   text,
  p_first_name text,
  p_last_name  text
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_done timestamptz;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select p.onboarding_completed_at into v_done
  from public.profiles p where p.id = v_uid
  for update;

  if not found then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if v_done is not null then
    raise exception 'onboarding already complete' using errcode = '42501';
  end if;

  if not public.username_is_valid(p_username) then
    raise exception 'invalid username' using errcode = '22023';
  end if;

  -- Validates and writes both names, raising 22023 on either.
  perform public.set_my_names(p_first_name, p_last_name);

  perform public.lock_username(p_username);
  if public.username_unavailable(p_username, v_uid) then
    raise exception 'username taken' using errcode = '23505';
  end if;

  begin
    update public.profiles
    set username = p_username,
        onboarding_completed_at = now()
    where id = v_uid;
  exception when unique_violation then
    raise exception 'username taken' using errcode = '23505';
  end;
end;
$$;

revoke execute on function public.complete_onboarding(text, text, text) from public, anon;
grant  execute on function public.complete_onboarding(text, text, text) to authenticated;

comment on function public.complete_onboarding(text, text, text) is
  'Sets the first chosen username, the first and last name, and '
  'onboarding_completed_at, once. Errors: 22023 invalid username/name, 23505 '
  'taken (held or reserved), 42501 already onboarded.';


-- ===========================================================================
-- 7. change_username.
--
-- The cooldown is the rate limit (decided Phase 44): one success per 30 days,
-- and a refused attempt writes nothing, so there is nothing for a counting
-- limit to count.
--
-- A case-only change (maria -> Maria) is allowed and costs the cooldown; its
-- "reservation" of the old spelling is harmless, since the unique index on
-- lower(username) already keeps everyone else off it. The exact same name is
-- refused rather than silently burning 30 days.
--
-- Error codes, so the client can say which: 22023 invalid / unchanged,
-- 23505 taken, 42501 cooldown (DETAIL carries the next allowed time) /
-- not onboarded / scheduled for deletion.
-- ===========================================================================
create function public.change_username(p_username text)
returns timestamptz
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_old     text;
  v_done    timestamptz;
  v_deleted timestamptz;
  v_last    timestamptz;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  -- The row lock also serialises two concurrent changes by the same user, so
  -- the cooldown cannot be raced.
  select p.username, p.onboarding_completed_at, p.deleted_at
  into v_old, v_done, v_deleted
  from public.profiles p where p.id = v_uid
  for update;

  if not found then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if v_done is null then
    raise exception 'onboarding not complete' using errcode = '42501';
  end if;
  if v_deleted is not null then
    raise exception 'account is scheduled for deletion' using errcode = '42501';
  end if;

  if not public.username_is_valid(p_username) then
    raise exception 'invalid username' using errcode = '22023';
  end if;
  if p_username = v_old then
    raise exception 'username unchanged' using errcode = '22023';
  end if;

  select c.changed_at into v_last
  from public.username_changes c where c.user_id = v_uid;

  if v_last is not null and v_last > now() - public.username_change_cooldown() then
    raise exception 'username change cooldown'
      using errcode = '42501',
            detail  = (v_last + public.username_change_cooldown())::text;
  end if;

  if lower(p_username) <> lower(v_old) then
    -- Both names, in a fixed order, so two users swapping names cannot
    -- deadlock each other.
    perform public.lock_username(n)
    from unnest(array[p_username, v_old]) n
    order by pg_catalog.hashtextextended('username:' || lower(n), 0);

    if public.username_unavailable(p_username, v_uid) then
      raise exception 'username taken' using errcode = '23505';
    end if;
  end if;

  begin
    update public.profiles set username = p_username where id = v_uid;
  exception when unique_violation then
    raise exception 'username taken' using errcode = '23505';
  end;

  insert into public.username_changes (user_id, previous_username, changed_at)
  values (v_uid, v_old, now())
  on conflict on constraint username_changes_pkey
  do update set previous_username = excluded.previous_username,
                changed_at        = excluded.changed_at;

  return now() + public.username_change_cooldown();
end;
$$;

revoke execute on function public.change_username(text) from public, anon;
grant  execute on function public.change_username(text) to authenticated;

comment on function public.change_username(text) is
  'Changes the caller''s username: format rule, 30-day cooldown, old name '
  'reserved 14 days. Returns when the next change is allowed.';

-- When the caller may next change their username; NULL = now (never changed,
-- or the cooldown has run out). The one door to username_changes for the
-- client, so the 30 days has one definition.
create function public.username_next_change_at()
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select nullif(
    greatest(c.changed_at + public.username_change_cooldown(), now()),
    now())
  from public.username_changes c
  where c.user_id = (select auth.uid());
$$;

revoke execute on function public.username_next_change_at() from public, anon;
grant  execute on function public.username_next_change_at() to authenticated;
