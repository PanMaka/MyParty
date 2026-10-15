-- Phase 39: editing and cancelling a party, replacing its cover -- and closing
-- the table-wide UPDATE that made all three possible in the wrong way.
--
-- Until now `authenticated` held a table-wide UPDATE and DELETE on parties,
-- gated only by "Hosts can update own parties" / "Hosts can delete own
-- parties" (20260709120643). RLS gates rows, never columns (gotcha 8), so a
-- host could PATCH their own row's going_count, interested_count, cover_path,
-- party_tier, is_sponsored, status or host_id. Nothing in the app ever did --
-- the client has never written to parties outside create_party_with_invites --
-- which is why it survived; the host dashboard's Edit button would have been
-- the first caller, and the obvious implementation was a PATCH.
--
-- 20261005224544 says "parties carries no UPDATE grant on this column for
-- clients" in confirm_party_cover's comment. That was not true when written.
-- It is true from this migration on.
--
-- Who relied on the grants, surveyed before revoking (2026-10-14):
--   * the Flutter client: no UPDATE or DELETE on parties anywhere in lib/.
--   * edge functions: none touch parties.
--   * every server-side writer is SECURITY DEFINER and unaffected:
--     sync_party_rsvp_counters, confirm_party_cover, request_account_deletion.
--   * scripts/ (verify_notification_delivery.sh, verify_party_cover.sh) run as
--     postgres through docker exec, so they do not use the client grants.
--   * pgTAP: 14_profile_and_party_media and 17_parties_policy updated parties
--     AS THE HOST to exercise the CHECK constraints and the policy's new-row
--     read. Those assertions move to postgres / to update_party in this PR.
-- So nothing outside the tests relied on them.


-- ===========================================================================
-- 1. The revoke.
--
-- UPDATE and DELETE both. DELETE is a hard delete, which rule 7 reserves for
-- erasure; cancelling is the soft equivalent and gets its own function below.
-- The two policies go too: with no grant behind them they can admit nothing,
-- and a policy that reads as "hosts can update" while hosts cannot is exactly
-- the kind of comment-that-lies this migration started from.
--
-- parties carries no column grants, so the table-level revoke drops nothing
-- that would need re-issuing (gotcha 23's note).
-- ===========================================================================
revoke update, delete on public.parties from authenticated;

drop policy "Hosts can update own parties" on public.parties;
drop policy "Hosts can delete own parties" on public.parties;


-- ===========================================================================
-- 2. update_party -- the only way to edit a party.
--
-- Definer, because the client now has no UPDATE privilege at all, and that is
-- what makes the allow-list below the whole surface: title, description,
-- area, starts_at, ends_at, location. Not privacy -- public -> private would
-- leave 'interested' rows on a private party, which rsvp_status_allowed exists
-- to prevent, and private -> public would publish a guest list's party to
-- the map. Not the counters, tier, sponsorship, status or host.
--
-- Full replacement, not a patch: the edit form always holds every field, so
-- NULL means NULL (no end time, no description, no area) and there is no
-- "null means unchanged" ambiguity for the client to get wrong.
--
-- Refused on a cancelled party: cancel is one-way, and an edit is how a
-- cancelled party would quietly start looking alive again.
--
-- Guests are not told about an edit. There is no push for it; that is in
-- docs/backlog.md with the cancellation push.
-- ===========================================================================
create or replace function public.update_party(
  p_party_id uuid,
  p_title text,
  p_description text,
  p_area text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_lat double precision,
  p_lon double precision
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_party_host(p_party_id) or not exists (
    select 1 from public.parties p
    where p.id = p_party_id and p.status = 'published'
  ) then
    raise exception 'cannot edit party %', p_party_id using errcode = '42501';
  end if;

  if nullif(btrim(coalesce(p_title, '')), '') is null then
    raise exception 'a party needs a title' using errcode = '22023';
  end if;
  if p_starts_at is null then
    raise exception 'a party needs a start time' using errcode = '22023';
  end if;
  if p_ends_at is not null and p_ends_at <= p_starts_at then
    raise exception 'a party has to end after it starts' using errcode = '22023';
  end if;
  if p_lat is null or p_lon is null
     or p_lat not between -90 and 90 or p_lon not between -180 and 180 then
    raise exception 'a party needs a valid location' using errcode = '22023';
  end if;

  -- area's one-short-line CHECK (20260820095801) still applies; '' becomes
  -- NULL here because the CHECK rejects the empty string on purpose.
  update public.parties
  set title = btrim(p_title),
      description = nullif(btrim(coalesce(p_description, '')), ''),
      area = nullif(btrim(coalesce(p_area, '')), ''),
      starts_at = p_starts_at,
      ends_at = p_ends_at,
      location = public.st_point(p_lon, p_lat)::public.geography
  where id = p_party_id;
end;
$$;

comment on function public.update_party(uuid, text, text, text, timestamptz, timestamptz, double precision, double precision) is
  'The only way to edit a party: host-only, published only, and only title, '
  'description, area, times and location. Full replacement -- NULL means NULL.';


-- ===========================================================================
-- 3. cancel_party -- one-way.
--
-- status = 'cancelled' is already understood everywhere that matters: the map,
-- ALL PARTIES, get_party, MY PARTIES, the chat list and the hosted list all
-- filter on status = 'published', the cover target refuses it, and
-- claim_notification_jobs re-checks it and cancels any pending nearby push.
--
-- One-way because the way back, 'published', is what parties_notify_on_publish
-- fires on: un-cancelling would announce the party to everyone nearby a
-- second time. A host who changes their mind makes a new party.
--
-- Guests are NOT notified -- no cancellation push exists yet (backlog).
-- ===========================================================================
create or replace function public.cancel_party(p_party_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_party_host(p_party_id) then
    raise exception 'cannot cancel party %', p_party_id using errcode = '42501';
  end if;

  update public.parties
  set status = 'cancelled'
  where id = p_party_id
    and status = 'published';

  if not found then
    raise exception 'party % is not published', p_party_id using errcode = '42501';
  end if;
end;
$$;

comment on function public.cancel_party(uuid) is
  'Host-only, one-way: published -> cancelled. Refuses anything else.';


-- ===========================================================================
-- 4. Replacing a cover.
--
-- 20261005224544's handshake is one-shot by design: the key is the fixed
-- {party_id}/cover and the edge function signs with upsert: false, so a
-- replayed token cannot swap a picture under guests who have already seen it.
-- Replacing keeps both properties by never overwriting anything -- each
-- replacement goes to a FRESH key, {party_id}/{uuid}, ProfileRepository.
-- replaceAvatar's shape. A new key is also a new signed URL, so no client is
-- left holding a cached old picture under the new cover's URL.
--
--   party_cover_replace_target -> signed PUT -> confirm_party_cover_replacement
--                              -> party-cover/cleanup (edge)
--
-- The old object is deleted by the edge function, not here: deleting a row from
-- storage.objects orphans the bytes (gotcha 7), and only the Storage API
-- removes both. party_cover_stale_objects decides WHICH objects; the edge
-- function, holding the service key, only executes the list it is handed.
--
-- Designed so the preset covers in docs/backlog.md slot in without a second
-- cleanup path: a preset is a cover that is not an object in the party's
-- folder, so choosing one will clear cover_path, and the SAME cleanup call
-- then removes the uploaded object it replaced. The client's edit flow treats
-- "keep / upload / preset" as one choice for the same reason.
-- ===========================================================================
create or replace function public.party_cover_replace_target(p_party_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
volatile
as $$
begin
  if not public.is_party_host(p_party_id) or not exists (
    select 1 from public.parties p
    where p.id = p_party_id and p.status = 'published'
  ) then
    raise exception 'cannot replace the cover of party %', p_party_id
      using errcode = '42501';
  end if;

  return p_party_id::text || '/' || gen_random_uuid()::text;
end;
$$;

-- The client names the path here, because a random key cannot be recomputed
-- -- so it is checked as tightly as the target minted it: this party's folder,
-- exactly one uuid, nothing else. The parties_cover_path_own_folder CHECK is
-- the second lock on the same door.
create or replace function public.confirm_party_cover_replacement(
  p_party_id uuid,
  p_path text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_party_host(p_party_id) or not exists (
    select 1 from public.parties p
    where p.id = p_party_id and p.status = 'published'
  ) then
    raise exception 'cannot replace the cover of party %', p_party_id
      using errcode = '42501';
  end if;

  if p_path is null or p_path !~ (
    '^' || p_party_id::text
    || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  ) then
    raise exception 'not a cover path for party %', p_party_id using errcode = '22023';
  end if;

  if not exists (
    select 1 from storage.objects o
    where o.bucket_id = 'party-covers'
    and o.name = p_path
  ) then
    raise exception 'no cover uploaded for party %', p_party_id
      using errcode = 'P0002';
  end if;

  update public.parties
  set cover_path = p_path
  where id = p_party_id;

  return p_path;
end;
$$;

-- Every object in the party's folder that is not its current cover and is
-- more than ten minutes old: the cover just replaced, plus any upload that
-- was abandoned before its confirm. The age floor keeps an upload in flight on
-- the host's other device out of the list -- a signed URL lives 120s, so ten
-- minutes is a wide margin. The price is that a cover replaced twice inside
-- ten minutes leaves the middle one until the next cleanup, which is the next
-- replacement or the next preset choice.
--
-- Works on a cancelled party too: cleaning up is never the thing to refuse.
create or replace function public.party_cover_stale_objects(p_party_id uuid)
returns setof text
language plpgsql
security definer
set search_path = ''
stable
as $$
begin
  if not public.is_party_host(p_party_id) then
    raise exception 'not the host of party %', p_party_id using errcode = '42501';
  end if;

  return query
  select o.name
  from storage.objects o
  join public.parties p on p.id = p_party_id
  where o.bucket_id = 'party-covers'
    and starts_with(o.name, p_party_id::text || '/')
    and o.name is distinct from p.cover_path
    and o.created_at < now() - interval '10 minutes';
end;
$$;

comment on function public.party_cover_replace_target(uuid) is
  'A fresh storage key for a replacement cover, for the host of a published '
  'party. Never the current key: replacements do not overwrite.';
comment on function public.confirm_party_cover_replacement(uuid, text) is
  'Points cover_path at an uploaded replacement after checking the key shape '
  'and storage.objects for the bytes.';
comment on function public.party_cover_stale_objects(uuid) is
  'Objects in a party''s cover folder that nothing points at any more. The '
  'party-cover edge function deletes exactly these through the Storage API.';


-- ===========================================================================
-- Grants. Each authenticated row is in 27_explicit_grants.test.sql. service_role
-- gets the two the edge function calls, per gotcha 13 and the party-cover
-- precedent, so a service-key call fails on the rule rather than a privilege.
-- ===========================================================================
revoke execute on function public.update_party(uuid, text, text, text, timestamptz, timestamptz, double precision, double precision) from public;
revoke execute on function public.cancel_party(uuid) from public;
revoke execute on function public.party_cover_replace_target(uuid) from public;
revoke execute on function public.confirm_party_cover_replacement(uuid, text) from public;
revoke execute on function public.party_cover_stale_objects(uuid) from public;

grant execute on function public.update_party(uuid, text, text, text, timestamptz, timestamptz, double precision, double precision) to authenticated;
grant execute on function public.cancel_party(uuid) to authenticated;
grant execute on function public.party_cover_replace_target(uuid) to authenticated;
grant execute on function public.confirm_party_cover_replacement(uuid, text) to authenticated;
grant execute on function public.party_cover_stale_objects(uuid) to authenticated;

grant execute on function public.party_cover_replace_target(uuid) to service_role;
grant execute on function public.party_cover_stale_objects(uuid) to service_role;
