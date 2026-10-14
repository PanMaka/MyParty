-- Phase 40: inviting people from the host dashboard, invite links for private
-- parties, and removing a guest.
--
--   1. invite_to_party / get_invitable_followers -- invite followers after the
--      party exists, with the same filtering create_party_with_invites has.
--   2. party_invite_links + redeem_party_invite -- a hashed, revocable token
--      that grants an INVITATION to whoever opens it signed in. Never the
--      party id: a /p/<id> link only opens a party for people who may already
--      see it (Phase 25), and that stays true.
--   3. party_guest_removals + remove_party_guest -- a host takes someone off
--      the guest list (invitation and rsvp), and a still-active link cannot
--      bring them back. Only a direct invite from the host can.
--   4. get_party_invitees -- the "Invited" list. get_party_guests lists rsvps
--      only, so someone who joined through a leaked link and never tapped
--      Coming -- exactly who a host most needs to remove -- was invisible.


-- ===========================================================================
-- 1. Tables
-- ===========================================================================

-- One active link per party. Only the SHA-256 of the token is stored: a read
-- of this table (a backup, a leaked dump, an operator's query) yields nothing
-- that opens a party. The raw token exists in exactly two places -- the return
-- value of create_party_invite_link, and the host device that kept it.
create table public.party_invite_links (
  id uuid primary key default gen_random_uuid(),
  party_id uuid not null references public.parties(id) on delete cascade,
  token_hash bytea not null unique,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  max_uses integer check (max_uses is null or max_uses between 1 and 500),
  use_count integer not null default 0 check (use_count >= 0)
);

alter table public.party_invite_links enable row level security;
revoke all on public.party_invite_links from anon, authenticated;

create unique index party_invite_links_one_active
  on public.party_invite_links (party_id) where revoked_at is null;
create index party_invite_links_party_created
  on public.party_invite_links (party_id, created_at);

comment on table public.party_invite_links is
  'Invite links for private parties. token_hash is sha256 of the token; the '
  'token itself is never stored. One active (revoked_at is null) link per '
  'party. No client grants: every read and write is a host-only function, '
  'and redeem_party_invite is the only door for guests.';

-- Which link an invitation came through, if any. Null for a direct invite.
-- `on delete set null` so a link row could be pruned without touching the
-- guest list. Erasure and export already handle invitations, so this adds no
-- new personal-data path.
alter table public.invitations
  add column via_link_id uuid references public.party_invite_links(id) on delete set null;

-- The host removed this person from this party. The minimum that can enforce
-- "a still-active link cannot bring them back": the pair and when. No reason,
-- no actor (it is always the party's host).
--
--  * Erasure deletes the removed person's rows (below), like their invitations
--    and rsvps -- an erased account cannot redeem anything anyway.
--  * Export carries them as party ids and dates: it is data held about the
--    subject, and they already know (the party disappeared for them).
--  * The party's own deletion takes its rows with it.
--  * A direct invite from the host lifts it (clear_party_guest_removals),
--    which is the one way back the host chose.
create table public.party_guest_removals (
  party_id uuid not null references public.parties(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  removed_at timestamptz not null default now(),
  primary key (party_id, user_id)
);

alter table public.party_guest_removals enable row level security;
revoke all on public.party_guest_removals from anon, authenticated;

create index party_guest_removals_user on public.party_guest_removals (user_id);

comment on table public.party_guest_removals is
  'Guests a host removed. Blocks re-entry through an invite link; a direct '
  'invite from the host lifts it. No client grants. Deleted on erasure, '
  'exported to the removed person.';


-- ===========================================================================
-- 2. invitations: the client may insert two columns, never via_link_id.
--
-- The INSERT grant was table-wide, so after the column above a host's
-- PostgREST insert could stamp any of their own invitations as "came through
-- a link" -- harmless to anyone else, but it would make the host's own
-- guest-list label and the link-join rate limit lie. Column-scoped like
-- direct_messages. create_party_with_invites and invite_to_party are invoker
-- and write exactly (party_id, guest_id); redeem_party_invite is definer.
-- ===========================================================================
revoke insert on public.invitations from authenticated;
grant insert (party_id, guest_id) on public.invitations to authenticated;

create index invitations_party_created_guest
  on public.invitations (party_id, created_at desc, guest_id desc);
create index invitations_link_joins_by_guest
  on public.invitations (guest_id, created_at) where via_link_id is not null;
-- Covers the via_link_id foreign key (13_hardening's unindexed-FK lint): a
-- link row's deletion sets these to null.
create index invitations_via_link_id on public.invitations (via_link_id);


-- ===========================================================================
-- 3. Rate limit on link joins: 20 per user per hour.
--
-- Per USER, because the thing being protected is the party network from one
-- account collecting invitations from a pile of leaked links. Per party and
-- per host, link joins already count toward the existing invitation limits
-- (500 per party, 1000 per host per hour, 20260819093446), so a leaked link
-- cannot fill a party past what a host could.
--
-- Failed redemptions are not counted, deliberately. A token is 256 random
-- bits; there is nothing to guess, so there is no brute force to slow down,
-- and recording failures would mean writing a row per bad attempt.
--
-- BEFORE ROW, so gotcha 18 applies: a multi-row insert sees its own rows.
-- ===========================================================================
create or replace function public.enforce_link_join_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_recent int;
begin
  select count(*) into v_recent
  from public.invitations i
  where i.guest_id = NEW.guest_id
    and i.via_link_id is not null
    and i.created_at > now() - interval '1 hour';

  if v_recent >= 20 then
    raise exception 'invite link rate limit exceeded: 20 per hour'
      using errcode = '42501';
  end if;

  return NEW;
end;
$$;

revoke execute on function public.enforce_link_join_rate_limit() from public;

create trigger invitations_link_join_rate_limit
before insert on public.invitations
for each row when (NEW.via_link_id is not null)
execute function public.enforce_link_join_rate_limit();


-- ===========================================================================
-- 4. Inviting followers.
-- ===========================================================================

-- Lifts removals for people the host has just invited directly. Definer
-- because party_guest_removals has no client grants; host-only on its own
-- account rather than trusting its caller.
create or replace function public.clear_party_guest_removals(p_party_id uuid, p_user_ids uuid[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_party_host(p_party_id) then
    raise exception 'not the host of party %', p_party_id using errcode = '42501';
  end if;

  delete from public.party_guest_removals
  where party_id = p_party_id and user_id = any(p_user_ids);
end;
$$;

-- INVOKER: the "Hosts can invite guests" INSERT policy stays the authority, and
-- the statement-level invitation limits fire. The filter is
-- create_party_with_invites' own (blocks, invite_policy), plus the host -- the
-- policy would let a host invite themselves -- so a list with one ineligible
-- person in it invites everyone else instead of failing whole.
--
-- Works on public parties too (decided Phase 40): there the invitation is a
-- "you're invited" on the guest's MY PARTIES and the party's sheet, and it
-- puts the party on their map whatever the host's map_visibility.
--
-- Returns how many invitations were written, which can be fewer than asked.
create or replace function public.invite_to_party(p_party_id uuid, p_invitee_ids uuid[])
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_new uuid[];
begin
  if not public.is_party_host(p_party_id) or not exists (
    select 1 from public.parties p
    where p.id = p_party_id
      and p.status = 'published'
      and not public.party_is_past(p.starts_at, p.ends_at)
  ) then
    raise exception 'cannot invite to party %', p_party_id using errcode = '42501';
  end if;

  with written as (
    insert into public.invitations (party_id, guest_id)
    select p_party_id, invitee_id
    from unnest(coalesce(p_invitee_ids, '{}')) as invitee_id
    where invitee_id <> v_uid
      and not public.is_blocked(v_uid, invitee_id)
      and public.accepts_invite_from(invitee_id, v_uid)
    on conflict (party_id, guest_id) do nothing
    returning guest_id
  )
  select array_agg(guest_id) into v_new from written;

  if v_new is not null then
    perform public.clear_party_guest_removals(p_party_id, v_new);
  end if;

  return coalesce(cardinality(v_new), 0);
end;
$$;

-- The host's followers (followee_id = host -- gotcha 14's direction), with
-- whether each is already invited or has answered, so the picker can lock
-- them. INVOKER: the follows and profiles SELECT policies already hide
-- block-paired accounts from the host, so nothing here decides that.
--
-- Searched by substring of the username, case-insensitively, and
-- keyset-paginated alphabetically. Bounded by one host's followers, so no
-- trigram index.
create or replace function public.get_invitable_followers(
  p_party_id uuid,
  p_query text default null,
  p_cursor_username text default null,
  p_cursor_id uuid default null,
  p_limit integer default 50
)
returns table (
  user_id uuid,
  username text,
  avatar_path text,
  already_invited boolean,
  rsvp_status public.rsvp_status
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_query text := nullif(lower(btrim(coalesce(p_query, ''))), '');
begin
  if not public.is_party_host(p_party_id) then
    raise exception 'not the host of party %', p_party_id using errcode = '42501';
  end if;

  return query
  select
    pr.id,
    pr.username,
    pr.avatar_path,
    exists (
      select 1 from public.invitations i
      where i.party_id = p_party_id and i.guest_id = pr.id
    ),
    (select r.status from public.rsvps r where r.party_id = p_party_id and r.user_id = pr.id)
  from public.follows f
  join public.profiles pr on pr.id = f.follower_id
  where f.followee_id = (select auth.uid())
    and pr.deleted_at is null
    and (v_query is null or strpos(lower(pr.username), v_query) > 0)
    and (
      p_cursor_username is null
      or (pr.username, pr.id) > (p_cursor_username, p_cursor_id)
    )
  order by pr.username, pr.id
  limit greatest(1, least(coalesce(p_limit, 50), 100));
end;
$$;

-- The "Invited" tab: every invitation on the party, newest first, with the
-- invitee's answer and whether they came through a link. INVOKER for the same
-- reason as get_party_guests: the invitations policy already hides
-- block-paired guests from the host.
create or replace function public.get_party_invitees(
  p_party_id uuid,
  p_cursor_created_at timestamptz default null,
  p_cursor_user_id uuid default null,
  p_limit integer default 50
)
returns table (
  user_id uuid,
  username text,
  avatar_path text,
  rsvp_status public.rsvp_status,
  via_link boolean,
  created_at timestamptz
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if not public.is_party_host(p_party_id) then
    raise exception 'not the host of party %', p_party_id using errcode = '42501';
  end if;

  return query
  select
    i.guest_id,
    pr.username,
    pr.avatar_path,
    r.status,
    i.via_link_id is not null,
    i.created_at
  from public.invitations i
  join public.profiles pr on pr.id = i.guest_id
  left join public.rsvps r on r.party_id = i.party_id and r.user_id = i.guest_id
  where i.party_id = p_party_id
    and (
      p_cursor_created_at is null
      or (i.created_at, i.guest_id) < (p_cursor_created_at, p_cursor_user_id)
    )
  order by i.created_at desc, i.guest_id desc
  limit greatest(1, least(coalesce(p_limit, 50), 100));
end;
$$;


-- ===========================================================================
-- 5. Invite links.
-- ===========================================================================

-- The token: 32 random bytes, base64url without padding (43 characters).
-- Kept as one function so the shape the redeem path checks and the shape
-- this produces cannot drift.
create or replace function public.party_invite_token_hash(p_token text)
returns bytea
language sql
immutable
set search_path = ''
as $$
  select extensions.digest(convert_to(p_token, 'UTF8'), 'sha256');
$$;

revoke execute on function public.party_invite_token_hash(text) from public;

-- Creates the party's link, revoking any previous one in the same statement
-- -- "regenerate" is this function called again. PRIVATE parties only: a
-- public party's /p/<id> link already opens it for everyone, and an
-- invitation to a public party is the follower picker's job.
--
-- Creation is limited to 20 per party per hour: regenerating is free for a
-- host, but a loop doing it would only grow this table.
create or replace function public.create_party_invite_link(
  p_party_id uuid,
  p_max_uses integer default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token text;
begin
  if not public.is_party_host(p_party_id) or not exists (
    select 1 from public.parties p
    where p.id = p_party_id
      and p.is_private
      and p.status = 'published'
      and not public.party_is_past(p.starts_at, p.ends_at)
  ) then
    raise exception 'cannot create an invite link for party %', p_party_id
      using errcode = '42501';
  end if;

  if p_max_uses is not null and p_max_uses not between 1 and 500 then
    raise exception 'max uses must be between 1 and 500' using errcode = '22023';
  end if;

  if (
    select count(*) from public.party_invite_links l
    where l.party_id = p_party_id and l.created_at > now() - interval '1 hour'
  ) >= 20 then
    raise exception 'invite link rate limit exceeded: 20 per hour'
      using errcode = '42501';
  end if;

  update public.party_invite_links
  set revoked_at = now()
  where party_id = p_party_id and revoked_at is null;

  v_token := translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');

  insert into public.party_invite_links (party_id, token_hash, max_uses)
  values (p_party_id, public.party_invite_token_hash(v_token), p_max_uses);

  return v_token;
end;
$$;

create or replace function public.disable_party_invite_link(p_party_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_party_host(p_party_id) then
    raise exception 'not the host of party %', p_party_id using errcode = '42501';
  end if;

  update public.party_invite_links
  set revoked_at = now()
  where party_id = p_party_id and revoked_at is null;
end;
$$;

-- The active link's state, never its token. Zero rows = no active link.
create or replace function public.get_party_invite_link(p_party_id uuid)
returns table (created_at timestamptz, max_uses integer, use_count integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_party_host(p_party_id) then
    raise exception 'not the host of party %', p_party_id using errcode = '42501';
  end if;

  return query
  select l.created_at, l.max_uses, l.use_count
  from public.party_invite_links l
  where l.party_id = p_party_id and l.revoked_at is null;
end;
$$;

-- Opening a link, signed in. Returns the party id; the client then opens it
-- through get_party like any other link, under the viewer's own session.
--
-- EVERY refusal is the same 42501 'invite link not valid': no such token,
-- revoked, used up, cancelled, ended, you are the host, you are block-paired
-- with the host, your account is being deleted, or the host removed you.
-- Telling them apart would make this a block oracle (the get_or_create_direct_thread
-- rule) and would tell a stranger holding a dead link that the party exists.
-- The rate limit is the one different message, and it says nothing about the
-- party.
--
-- The joiner's own invite_policy is NOT consulted (decided Phase 40, D6): it
-- governs who may invite you, and opening a link is your own act.
--
-- Already invited (directly, or through this link before): returns the party
-- without spending a use.
create or replace function public.redeem_party_invite(p_token text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_link public.party_invite_links;
  v_party public.parties;
begin
  if v_uid is null or p_token is null or p_token !~ '^[A-Za-z0-9_-]{43}$' then
    raise exception 'invite link not valid' using errcode = '42501';
  end if;

  select l.* into v_link
  from public.party_invite_links l
  where l.token_hash = public.party_invite_token_hash(p_token)
    and l.revoked_at is null
  for update;

  if not found then
    raise exception 'invite link not valid' using errcode = '42501';
  end if;

  select p.* into v_party from public.parties p where p.id = v_link.party_id;

  if v_party.status <> 'published'
     or public.party_is_past(v_party.starts_at, v_party.ends_at)
     or v_party.host_id = v_uid
     or public.is_blocked(v_party.host_id, v_uid)
     or exists (
       select 1 from public.profiles pr
       where pr.id = v_uid and pr.deleted_at is not null
     )
     or exists (
       select 1 from public.party_guest_removals g
       where g.party_id = v_party.id and g.user_id = v_uid
     )
  then
    raise exception 'invite link not valid' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.invitations i
    where i.party_id = v_party.id and i.guest_id = v_uid
  ) then
    return v_party.id;
  end if;

  if v_link.max_uses is not null and v_link.use_count >= v_link.max_uses then
    raise exception 'invite link not valid' using errcode = '42501';
  end if;

  insert into public.invitations (party_id, guest_id, via_link_id)
  values (v_party.id, v_uid, v_link.id);

  update public.party_invite_links
  set use_count = use_count + 1
  where id = v_link.id;

  return v_party.id;
end;
$$;


-- ===========================================================================
-- 6. Removing a guest.
--
-- Deletes their rsvp (through the counter trigger, so going/interested,
-- rsvp_count_events and the party_host topic all move exactly as on an
-- un-RSVP), their invitation, and their read marker, and records the removal.
--
-- On a PRIVATE party that is the whole of their access: can_access_party is
-- host-or-invited there, so the party, its chat and its party:{uuid} topic all
-- close with the invitation (asserted in 34_party_invites.test.sql).
-- Content they already wrote (messages, stories) stays, like any departed
-- guest's.
--
-- On a PUBLIC party the party stays visible -- it is public -- and they may
-- RSVP again. The removal still stops a link and clears the invitation. A
-- host who wants them gone from a public party entirely has blocking.
-- ===========================================================================
create or replace function public.remove_party_guest(p_party_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_party_host(p_party_id) then
    raise exception 'not the host of party %', p_party_id using errcode = '42501';
  end if;
  if p_user_id is null or p_user_id = (select auth.uid()) then
    raise exception 'the host cannot be removed from their own party' using errcode = '22023';
  end if;

  delete from public.rsvps where party_id = p_party_id and user_id = p_user_id;
  delete from public.invitations where party_id = p_party_id and guest_id = p_user_id;
  delete from public.party_reads where party_id = p_party_id and user_id = p_user_id;

  insert into public.party_guest_removals (party_id, user_id)
  values (p_party_id, p_user_id)
  on conflict on constraint party_guest_removals_pkey do update set removed_at = now();
end;
$$;


-- ===========================================================================
-- 7. Erasure and export, recreated in full from 20261009095552 (append-only).
-- Diffs marked NEW.
-- ===========================================================================
create or replace function public.complete_account_erasure(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_handle text;
begin
  if not exists (
    select 1 from public.profiles
    where id = p_user_id and deleted_at is not null and erased_at is null
  ) then
    -- Not an error: a retry after a partial failure lands here, and so does a
    -- user who cancelled between the claim and now. Both should stop quietly.
    return;
  end if;

  -- Refuse to erase an account whose grace period has not expired. The eraser
  -- cannot reach this state through the claim, but this function is a
  -- service_role entry point and the 30 days is the promise the whole feature
  -- rests on -- it should be impossible to shorten by calling the API directly.
  if exists (
    select 1 from public.profiles
    where id = p_user_id
      and deleted_at > now() - public.account_erasure_grace()
  ) then
    raise exception 'grace period has not expired for %', p_user_id
      using errcode = 'P0001';
  end if;

  -- ---- Story media: queue the objects BEFORE the rows that name them. ----
  -- story_media_purges.story_id is `on delete set null` precisely so the queue
  -- outlives its subject (20260815133041).
  insert into public.story_media_purges (story_id, media_path)
  select s.id, s.media_path
  from public.stories s
  where s.author_id = p_user_id
    and s.media_uploaded_at is not null
    and s.media_deleted_at is null;

  -- ---- DELETE, per the audit's §3. ----
  delete from public.story_views    where user_id   = p_user_id;
  delete from public.stories        where author_id = p_user_id;
  delete from public.post_likes     where user_id   = p_user_id;
  delete from public.rsvps          where user_id   = p_user_id;
  delete from public.invitations    where guest_id  = p_user_id;
  delete from public.party_guest_removals where user_id = p_user_id;  -- NEW
  delete from public.follows        where follower_id = p_user_id or followee_id = p_user_id;
  delete from public.party_reads    where user_id   = p_user_id;
  delete from public.direct_reads   where user_id   = p_user_id;
  delete from public.user_birthdates where user_id  = p_user_id;

  -- Re-run of the PURGE NOW set from request_account_deletion. Not redundant:
  -- a device or job could have been created between the soft delete and now by
  -- a client holding a still-valid JWT, and this is the last chance to catch it.
  delete from public.user_devices       where user_id = p_user_id;
  delete from public.notification_jobs  where user_id = p_user_id;
  delete from public.sent_notifications where user_id = p_user_id;

  -- ---- RETAIN, with the media stripped. ----
  update public.party_posts
  set media_path = null
  where author_id = p_user_id
    and media_path is not null
    and body is not null;

  update public.party_posts
  set hidden_at     = coalesce(hidden_at, now()),
      hidden_reason = coalesce(hidden_reason, 'account erased')
  where author_id = p_user_id
    and media_path is not null
    and body is null;

  -- ---- The tombstone. ----
  v_handle := 'deleted_' || replace(p_user_id::text, '-', '');

  update public.profiles
  set username           = v_handle,
      -- New in this migration. A self-description and an avatar are as
      -- identifying as the handle they sit next to; scrubbing one and keeping
      -- the other two produces a tombstone that still names a person.
      bio                = null,
      avatar_path        = null,
      erased_at          = now(),
      location_consent   = false,
      push_consent       = false,
      analytics_consent  = false,
      follower_count     = 0,
      following_count    = 0,
      onboarding_completed_at = null
  where id = p_user_id;

  update public.account_erasures
  set completed_at = now(),
      last_error   = null
  where user_id = p_user_id;
end;
$$;

revoke execute on function public.complete_account_erasure(uuid) from public, anon, authenticated;
grant  execute on function public.complete_account_erasure(uuid) to service_role;

comment on function public.complete_account_erasure(uuid) is
  'The database half of erasure: deletes the audit''s DELETE set (now including party_guest_removals), strips post media, and rewrites the profiles row into an anonymous tombstone. Direct messages are retained, like party messages. Idempotent. Called only after storage objects are confirmed gone.';

create or replace function public.export_account_data()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_out jsonb;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select jsonb_build_object(
    -- A header, so a file that outlives the conversation about it still says
    -- what it is and when it was true.
    'export_format_version', 1,
    'exported_at', now(),
    'user_id', v_uid,

    'profile', (
      -- Column list spelled out rather than to_jsonb(pr): credibility_score
      -- must not appear. Phase 8 decided it ships no score, and a zero in an
      -- export file is a number a person will ask about.
      select to_jsonb(p)
      from (
        select
          pr.id, pr.username, pr.created_at,
          pr.bio, pr.avatar_path,
          pr.onboarding_completed_at,
          pr.location_consent, pr.push_consent, pr.analytics_consent,
          pr.map_visibility, pr.invite_policy, pr.dm_policy,
          pr.notify_nearby, pr.notify_radius_meters,
          pr.quiet_hours_start, pr.quiet_hours_end,
          pr.follower_count, pr.following_count,
          pr.deleted_at
        from public.profiles pr
        where pr.id = v_uid
      ) p
    ),

    -- Hosted parties. location is emitted as lon/lat rather than the PostGIS
    -- binary, because an export the subject cannot read is not an export.
    'parties', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pa.id,
        'title', pa.title,
        'description', pa.description,
        'area', pa.area,
        'cover_path', pa.cover_path,
        'longitude', public.st_x(pa.location::public.geometry),
        'latitude', public.st_y(pa.location::public.geometry),
        'starts_at', pa.starts_at,
        'ends_at', pa.ends_at,
        'status', pa.status,
        'is_private', pa.is_private,
        'party_tier', pa.party_tier,
        'max_capacity', pa.max_capacity,
        'going_count', pa.going_count,
        'interested_count', pa.interested_count,
        'created_at', pa.created_at
      ) order by pa.created_at)
      from public.parties pa
      where pa.host_id = v_uid
    ), '[]'::jsonb),

    'rsvps', coalesce((
      select jsonb_agg(jsonb_build_object(
        'party_id', r.party_id,
        'party_title', pa.title,
        'status', r.status,
        'created_at', r.created_at
      ) order by r.created_at)
      from public.rsvps r
      join public.parties pa on pa.id = r.party_id
      where r.user_id = v_uid
    ), '[]'::jsonb),

    -- NEW. Parties whose host removed the subject from the guest list: data
    -- held about them, and nothing they do not already know -- the party
    -- disappeared for them. Party ids and dates only, no title: a private
    -- party they can no longer see should not have its name re-delivered here.
    'party_removals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'party_id', g.party_id,
        'removed_at', g.removed_at
      ) order by g.removed_at)
      from public.party_guest_removals g
      where g.user_id = v_uid
    ), '[]'::jsonb),

    'posts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pp.id,
        'party_id', pp.party_id,
        'body', pp.body,
        'media_path', pp.media_path,
        'like_count', pp.like_count,
        'comment_count', pp.comment_count,
        'created_at', pp.created_at,
        -- If a moderator hid it, the subject is entitled to know that it
        -- happened and why. Who did it is not theirs.
        'hidden_at', pp.hidden_at,
        'hidden_reason', pp.hidden_reason
      ) order by pp.created_at)
      from public.party_posts pp
      where pp.author_id = v_uid
    ), '[]'::jsonb),

    -- Not in the Phase 9 brief's list of five, added deliberately: a comment
    -- is text the user wrote, and an export that returns their posts but not
    -- their comments is an incomplete Art. 20 response.
    'comments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pc.id,
        'post_id', pc.post_id,
        'body', pc.body,
        'created_at', pc.created_at,
        'hidden_at', pc.hidden_at,
        'hidden_reason', pc.hidden_reason
      ) order by pc.created_at)
      from public.post_comments pc
      where pc.author_id = v_uid
    ), '[]'::jsonb),

    'messages', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id,
        'party_id', m.party_id,
        'party_title', pa.title,
        'body', m.body,
        'created_at', m.created_at,
        'hidden_at', m.hidden_at,
        'hidden_reason', m.hidden_reason
      ) order by m.created_at)
      from public.messages m
      join public.parties pa on pa.id = m.party_id
      where m.author_id = v_uid
    ), '[]'::jsonb),

    -- thread_id and the other member's id, as ids only -- the same reasoning
    -- as the follows block: who someone talks to is also a fact about the
    -- person on the other end.
    'direct_messages', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', dm.id,
        'thread_id', dm.thread_id,
        'recipient_id', case when t.user_low = v_uid then t.user_high else t.user_low end,
        'body', dm.body,
        'created_at', dm.created_at,
        'hidden_at', dm.hidden_at,
        'hidden_reason', dm.hidden_reason
      ) order by dm.created_at)
      from public.direct_messages dm
      join public.direct_threads t on t.id = dm.thread_id
      where dm.author_id = v_uid
    ), '[]'::jsonb),

    -- Not content, but it is unambiguously data held about the subject, and
    -- it is the part a privacy-minded person is most likely to be asking
    -- about. Emitted as ids and timestamps only: who someone follows is also
    -- a fact about the person on the other end.
    'follows', jsonb_build_object(
      'following', coalesce((
        select jsonb_agg(jsonb_build_object('user_id', f.followee_id, 'created_at', f.created_at)
               order by f.created_at)
        from public.follows f where f.follower_id = v_uid
      ), '[]'::jsonb),
      'followers', coalesce((
        select jsonb_agg(jsonb_build_object('user_id', f.follower_id, 'created_at', f.created_at)
               order by f.created_at)
        from public.follows f where f.followee_id = v_uid
      ), '[]'::jsonb)
    ),

    -- Provided by the subject at sign-up (Art. 20). Null for accounts that
    -- predate the age gate.
    'date_of_birth', (
      select b.date_of_birth from public.user_birthdates b where b.user_id = v_uid
    )

    -- Deliberately absent: user_devices. Its only interesting column is
    -- last_location, which by the time anyone reads this is either null (24h
    -- retention) or a ~100m cell -- and putting a location history into a
    -- downloadable file is the one thing 7.2 spent a whole phase preventing.
    -- The current cell is shown live in the app instead.
  ) into v_out;

  return v_out;
end;
$$;

revoke execute on function public.export_account_data() from public, anon;
grant  execute on function public.export_account_data() to authenticated;
grant  execute on function public.export_account_data() to service_role;

comment on function public.export_account_data() is
  'GDPR Art. 20 export for the CALLING user only -- takes no user id. Includes bio, avatar_path, dm_policy, each hosted party''s area and cover_path, the direct messages the user wrote, and the parties whose host removed them (ids and dates). Definer so the caller''s own messages survive can_chat_in_party filtering in parties they have since left, and their DMs survive a block.';


-- ===========================================================================
-- Grants. Default privileges are closed (20261004234903); each authenticated
-- row is in 27_explicit_grants.test.sql.
-- ===========================================================================
revoke execute on function public.clear_party_guest_removals(uuid, uuid[]) from public;
revoke execute on function public.invite_to_party(uuid, uuid[]) from public;
revoke execute on function public.get_invitable_followers(uuid, text, text, uuid, integer) from public;
revoke execute on function public.get_party_invitees(uuid, timestamptz, uuid, integer) from public;
revoke execute on function public.create_party_invite_link(uuid, integer) from public;
revoke execute on function public.disable_party_invite_link(uuid) from public;
revoke execute on function public.get_party_invite_link(uuid) from public;
revoke execute on function public.redeem_party_invite(text) from public;
revoke execute on function public.remove_party_guest(uuid, uuid) from public;

-- invite_to_party is INVOKER and calls this, so the caller needs it; it checks
-- the host itself.
grant execute on function public.clear_party_guest_removals(uuid, uuid[]) to authenticated;
grant execute on function public.invite_to_party(uuid, uuid[]) to authenticated;
grant execute on function public.get_invitable_followers(uuid, text, text, uuid, integer) to authenticated;
grant execute on function public.get_party_invitees(uuid, timestamptz, uuid, integer) to authenticated;
grant execute on function public.create_party_invite_link(uuid, integer) to authenticated;
grant execute on function public.disable_party_invite_link(uuid) to authenticated;
grant execute on function public.get_party_invite_link(uuid) to authenticated;
grant execute on function public.redeem_party_invite(text) to authenticated;
grant execute on function public.remove_party_guest(uuid, uuid) to authenticated;
