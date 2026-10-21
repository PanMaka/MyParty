-- Phase 45: the private columns of public.profiles stop being readable by
-- anyone but their owner (docs/backlog.md 1.38).
--
-- `anon` and `authenticated` held a table-wide SELECT on profiles, filtered
-- only by blocks. The same row carries the consents, the nearby-notification
-- settings, quiet hours, the notification time zone, the three privacy tiers,
-- onboarding and deletion state. Any caller, signed in or not, could read
-- whether a given user shares their location, when they sleep and which time
-- zone they are in. Quiet hours plus a time zone is a daily routine, and
-- "location on" marks who the proximity engine can reach.
--
-- THE FIX IS A COLUMN-SCOPED SELECT, which reverses what 1.38 recorded (move
-- the settings to an owner-read-only table). That decision rested on
-- 14_profile_and_party_media's guard, "a column-scoped SELECT breaks bio's
-- inherited block filter". It does not: the block filter is a ROW policy and
-- applies to every column whatever the grants say. A column grant can only
-- make a column less visible, never route around the row filter. What the
-- guard really protects against -- bio quietly getting a visibility of its
-- own -- is caught just as well by asserting the exact public column list,
-- which is what the guard now does. The table move would have bought the same
-- privacy for a rewrite of the proximity engine's hot path, three triggers and
-- ~40 test fixtures. Reasoning recorded in docs/backlog.md §3.
--
-- What the audit found reads profiles (Phase 45, before this migration):
--   * The client reads OTHER users' id, username, bio, avatar_path and the two
--     follow counters, nothing else, and never `select('*')`. Its own-row reads
--     of the private columns move to get_my_settings() below.
--   * Every server engine that decides something from a setting is security
--     definer (wants_nearby_notifications, in_quiet_hours, accepts_dm_from,
--     accepts_invite_from, has_location_consent, claim_notification_jobs, the
--     export and the erasure) and runs as the table owner, so it is untouched.
--   * Three INVOKER RPCs read another user's private column under the caller's
--     privileges and are rewritten here onto definer helpers:
--     get_parties_near_user (the host's map_visibility), search_profiles and
--     get_invitable_followers (deleted_at / erased_at).
--   * Signed out, nothing needs profiles at all: the /p and /i pages run no
--     script, and every app read is authenticated. anon loses the table.
--   * profiles is in no realtime publication, and the broadcast payloads carry
--     ids and usernames only (asserted in 40_profile_private_columns).
--
-- Column classification:
--   public      id, username, bio, avatar_path, follower_count,
--               following_count -- what a profile, a follower list or a chat
--               line shows. username_search too: a normalised copy of the
--               public username, read by search_profiles' leakproof prefix
--               range under the caller's privileges (it is what reaches the
--               index ahead of the row policy).
--   owner-only  the consents, notify_*, quiet hours, notification_tz, the three
--               privacy tiers, onboarding_completed_at, deleted_at -- through
--               get_my_settings().
--   server-only credibility_score (written and read by nothing), erased_at,
--               created_at (the export carries it).
--
-- Writes are unchanged: the Phase 44 UPDATE allow-list stays, and a PostgREST
-- PATCH with return=minimal reads only `id`, which stays granted.
-- scripts/verify_profile_privacy.sh measures that over HTTP.


-- ===========================================================================
-- 1. Where the map reads the host's tier.
--
-- Bound to auth.uid(), with NO viewer parameter, on purpose. Called directly
-- it answers "would this host's parties be on MY map", which the map itself
-- answers the next time they host. A viewer parameter would let anyone ask on
-- behalf of one of the host's followers (the follow graph is readable) and so
-- tell 'followers' from 'nobody' without following them -- exactly what the
-- column grant below stops. If a fan-out ever needs this for another user,
-- gotcha 11 applies: a parameterised variant held back from the client.
--
-- Only the host's SETTING moves in here. The arms that are about the party --
-- the host themself, an invitation, an rsvp -- stay in the RPC.
-- ===========================================================================
create function public.host_on_my_map(p_host_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles pr
    where pr.id = p_host_id
      and (
        pr.map_visibility = 'public'
        -- 'followers' = people who follow the HOST (gotcha 14).
        or (
          pr.map_visibility = 'followers'
          and exists (
            select 1 from public.follows f
            where f.follower_id = (select auth.uid())
              and f.followee_id = p_host_id
          )
        )
      )
  );
$$;

revoke execute on function public.host_on_my_map(uuid) from public, anon;
grant  execute on function public.host_on_my_map(uuid) to authenticated;

comment on function public.host_on_my_map(uuid) is
  'Whether the host''s map_visibility admits the CALLER: public, or followers '
  'and the caller follows the host. The map''s only read of another user''s '
  'tier (Phase 45). Bound to auth.uid() so it cannot be asked about anyone else.';


-- ===========================================================================
-- 2. Where search and the invite picker read deletion state.
--
-- The DATE in deleted_at is owner-only. Whether an account is discoverable is
-- not: search has dropped pending and erased accounts by design since Phase 14,
-- so a caller who knows a username already learns it by searching. This
-- answers that same question and nothing more.
-- ===========================================================================
create function public.profile_is_discoverable(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles pr
    where pr.id = p_user_id
      and pr.deleted_at is null
      and pr.erased_at is null
  );
$$;

revoke execute on function public.profile_is_discoverable(uuid) from public, anon;
grant  execute on function public.profile_is_discoverable(uuid) to authenticated;

comment on function public.profile_is_discoverable(uuid) is
  'False for an account scheduled for deletion or erased. What search and the '
  'invite picker filter on, without reading deleted_at under the caller''s '
  'privileges (Phase 45).';


-- ===========================================================================
-- 3. The three invoker RPCs, each with only those terms changed.
-- ===========================================================================
create or replace function public.get_parties_near_user(
  map_center_lon double precision,
  map_center_lat double precision,
  radius_meters double precision,
  p_limit integer default 200,
  p_window text default 'all'::text,
  p_tz text default 'Europe/Athens'::text
)
returns table(
  party_id uuid, title text, description text,
  starts_at timestamp with time zone, ends_at timestamp with time zone,
  area text, address text, cover_path text,
  is_private boolean, is_sponsored boolean, party_tier text,
  host_id uuid, host_username text,
  lat double precision, lon double precision, distance_meters double precision,
  going_count integer, interested_count integer,
  my_rsvp_status public.rsvp_status, is_invited boolean
)
language sql
set search_path to 'public', 'extensions'
as $function$
  select
    p.id as party_id,
    p.title,
    p.description,
    p.starts_at,
    p.ends_at,
    p.area,
    p.address,
    p.cover_path,
    p.is_private,
    p.is_sponsored,
    p.party_tier,
    p.host_id,
    pr.username as host_username,

    -- From `location`, not bbox_lat/bbox_lon: those exist to narrow, not to
    -- answer.
    st_y(p.location::geometry) as lat,
    st_x(p.location::geometry) as lon,

    st_distance(p.location, st_point(map_center_lon, map_center_lat)::geography) as distance_meters,

    -- NULL for a private party, at the source (20260825090051).
    case when p.is_private then null else p.going_count end as going_count,
    case when p.is_private then null else p.interested_count end as interested_count,

    (
      select r.status from public.rsvps r
      where r.party_id = p.id and r.user_id = (select auth.uid())
    ) as my_rsvp_status,

    exists (
      select 1 from public.invitations i
      where i.party_id = p.id and i.guest_id = (select auth.uid())
    ) as is_invited

  from public.parties p
  join public.profiles pr on p.host_id = pr.id
  where

    -- THE SPATIAL PRE-FILTER (20260821201309): leakproof float8 comparisons
    -- against InitPlan constants, evaluated ahead of the row policy.
    p.bbox_lat >= (select st_ymin(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))
    and p.bbox_lat <= (select st_ymax(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))
    and p.bbox_lon >= (select st_xmin(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))
    and p.bbox_lon <= (select st_xmax(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))

    -- THE TIME PRE-FILTER (20260823091942). The bounds MUST stay scalar
    -- subqueries -- one evaluation, an InitPlan constant, not one per row.
    and p.starts_at >= (select lower(public.party_time_window(p_window, p_tz)))
    and p.starts_at <  (select upper(public.party_time_window(p_window, p_tz)))

    -- NOT OVER. The shared predicate -- see the header. Until this migration
    -- the grace arm applied only under Τώρα and the default map pinned a
    -- null-ends_at party forever (gotcha 21); it now applies on every window.
    --
    -- DO NOT rewrite the last term as coalesce(p.ends_at, p.starts_at + grace)
    -- > now(). Algebraically identical, ~20x slower measured: a Var under
    -- timestamptz_pl_interval is not leakproof and drags the term behind the
    -- RLS barrier. Same trap for party_is_past().
    and p.status = 'published'
    and (p.ends_at is null or p.ends_at > now())
    and (
      p.ends_at is not null
      or p.starts_at > (select now() - public.party_end_grace())
    )

    -- The box above is a SUPERSET of this circle; this is what decides.
    and st_dwithin(p.location, st_point(map_center_lon, map_center_lat)::geography, radius_meters)

    -- The host's map_visibility, plus the party-specific override. The tier
    -- is owner-only since Phase 45, so it is read through host_on_my_map.
    and (
      p.host_id = (select auth.uid())
      or public.host_on_my_map(p.host_id)
      or exists (
        select 1 from public.invitations i
        where i.party_id = p.id and i.guest_id = (select auth.uid())
      )
      or exists (
        select 1 from public.rsvps r
        where r.party_id = p.id and r.user_id = (select auth.uid())
      )
    )

    -- Zoom tier. Independent of the window: both narrow.
    and case
        when radius_meters <= 15000 then true
        when radius_meters <= 100000 then p.party_tier in ('large', 'mega')
        else p.party_tier = 'mega' or p.is_sponsored = true
    end
  order by p.is_sponsored desc, distance_meters asc
  limit greatest(least(p_limit, 500), 1);
$function$;


create or replace function public.search_profiles(p_query text, p_limit integer default 20)
returns table(id uuid, username text, follower_count integer, following_count integer)
language sql
stable
set search_path to 'public', 'extensions'
as $function$
  with q as (
    select public.search_normalize(p_query) as key
  )
  select
    pr.id,
    pr.username,
    pr.follower_count,
    pr.following_count
  from public.profiles pr, q
  where q.key <> ''

    -- THE PREFIX RANGE. Written out by hand with the PATTERN operators: see
    -- the migration header for why `like q.key || '%'` and `>= / <` both fail
    -- to reach the index. Both terms are leakproof, so they are evaluated
    -- BEFORE the row policy and everything below runs on what survives.
    and pr.username_search ~>=~ q.key
    and pr.username_search ~<~ public.search_prefix_upper(q.key)

    -- The profiles SELECT policy deliberately does NOT filter deleted_at --
    -- the tombstone has to stay visible to it or the inner joins in get_feed,
    -- get_messages and friends drop whole rows. So search filters it here, and
    -- it is not belt-and-braces: the erasure scrub makes username_search read
    -- `deleteduuid...`, so a search for `deleted` would otherwise return every
    -- tombstone in the system. Through a definer helper since Phase 45: the
    -- caller can no longer read deleted_at.
    and public.profile_is_discoverable(pr.id)

    -- What searchProfiles did with .neq('id', uid).
    and pr.id <> (select auth.uid())

  order by pr.follower_count desc, pr.username asc
  limit greatest(least(p_limit, 50), 1);
$function$;


create or replace function public.get_invitable_followers(
  p_party_id uuid,
  p_query text default null::text,
  p_cursor_username text default null::text,
  p_cursor_id uuid default null::uuid,
  p_limit integer default 50
)
returns table(user_id uuid, username text, avatar_path text, already_invited boolean, rsvp_status public.rsvp_status)
language plpgsql
stable
set search_path to ''
as $function$
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
    and public.profile_is_discoverable(pr.id)
    and (v_query is null or strpos(lower(pr.username), v_query) > 0)
    and (
      p_cursor_username is null
      or (pr.username, pr.id) > (p_cursor_username, p_cursor_id)
    )
  order by pr.username, pr.id
  limit greatest(1, least(coalesce(p_limit, 50), 100));
end;
$function$;


-- ===========================================================================
-- 4. The owner's door to their own settings.
--
-- Definer because `authenticated` no longer holds SELECT on these columns --
-- a grant names a role, never a row, so it cannot say "your own". No user
-- argument: it reads auth.uid()'s row and nobody else's. Zero rows signed out.
-- ===========================================================================
create function public.get_my_settings()
returns table (
  onboarding_completed_at timestamptz,
  deleted_at              timestamptz,
  location_consent        boolean,
  push_consent            boolean,
  analytics_consent       boolean,
  notify_nearby           boolean,
  notify_radius_meters    integer,
  notify_daily_cap        integer,
  quiet_hours_start       time,
  quiet_hours_end         time,
  notification_tz         text,
  map_visibility          public.map_visibility,
  invite_policy           public.invite_policy,
  dm_policy               public.dm_policy
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    pr.onboarding_completed_at,
    pr.deleted_at,
    pr.location_consent,
    pr.push_consent,
    pr.analytics_consent,
    pr.notify_nearby,
    pr.notify_radius_meters,
    pr.notify_daily_cap,
    pr.quiet_hours_start,
    pr.quiet_hours_end,
    pr.notification_tz,
    pr.map_visibility,
    pr.invite_policy,
    pr.dm_policy
  from public.profiles pr
  where pr.id = (select auth.uid());
$$;

revoke execute on function public.get_my_settings() from public, anon;
grant  execute on function public.get_my_settings() to authenticated;

comment on function public.get_my_settings() is
  'The caller''s own owner-only profiles columns: consents, notification '
  'settings, quiet hours, time zone, privacy tiers, onboarding and deletion '
  'state. The client''s only read of them since Phase 45.';


-- ===========================================================================
-- 5. The grant.
--
-- Revoking SELECT at table level also drops any column SELECT, and leaves the
-- Phase 44 column UPDATE list alone (asserted). anon gets nothing back.
-- ===========================================================================
revoke select on public.profiles from anon, authenticated;

grant select (
  id,
  username,
  bio,
  avatar_path,
  follower_count,
  following_count,
  username_search
) on public.profiles to authenticated;


-- ===========================================================================
-- 6. The two read RPCs anon could still call.
--
-- Both inner-join profiles under invoker rights and held PUBLIC's default
-- EXECUTE, so a signed-out caller reached them. With anon off profiles they
-- would fail on the table privilege instead of being refused (gotcha 4), so
-- they are refused at the door like get_feed.
-- ===========================================================================
revoke execute on function public.get_post_comments(uuid, timestamptz, uuid, integer) from public, anon;
grant  execute on function public.get_post_comments(uuid, timestamptz, uuid, integer) to authenticated;

revoke execute on function public.get_party_stories(uuid, timestamptz, uuid, integer) from public, anon;
grant  execute on function public.get_party_stories(uuid, timestamptz, uuid, integer) to authenticated;
