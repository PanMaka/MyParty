-- get_parties_near_user: the four columns the map pin has been drawing
-- placeholders for, and a bound on the result set.
--
-- ONE change to the function, not several. Everything the audit found broken
-- on the map is downstream of the payload being narrower than the pin, so the
-- payload is the fix and the client follows it.
--
--
-- WHY DROP + RECREATE
--
-- The output column list changes, and Postgres rejects a `create or replace`
-- that changes it (42P13). Same dance as 20260813095529, which added
-- going_count/my_rsvp_status/is_invited for the same reason -- and the same
-- consequence: DROP takes the function's ACL and its `search_path` setting
-- with it, so both have to be restated below or they are silently lost.
-- 20260819095452 pinned `search_path` with a bare ALTER, which leaves no trace
-- in the create statement; a drop+recreate that forgets it reverts a hardening
-- migration without touching its file.
--
-- The 3-argument signature is what gets dropped. p_limit arrives WITH A
-- DEFAULT, so every existing 3-arg call site -- the pgTAP suites in 03, 04, 11
-- and 12, and scripts/loadtest_map_query.sh -- keeps compiling unchanged.
-- Note that the new function is therefore a different signature: any future
-- drop must name (double precision, double precision, double precision, int).
--
--
-- 1. THE FOUR COLUMNS
--
-- interested_count -- the pin renders "N ενδ." (interested) when the party is
--   not live and "N μέσα" (inside) when it is, so it needs BOTH counters. It
--   has had going_count in the payload since 20260813095529 and read neither,
--   because the client was looking for an `attendee_count` that has never
--   existed. Trigger-maintained by sync_party_rsvp_counters (20260813095451),
--   so this is a column read, not a count(*) at read time (CLAUDE.md #6).
--
-- ends_at -- the map's own where-clause has filtered on it since
--   20260813095529 and never returned it, so the client could not tell a party
--   that has started from one that has not. "Live" is (starts_at <= now and
--   (ends_at is null or ends_at > now)), and starts_at was already here: this
--   column is the missing half of a predicate the client can now evaluate
--   itself.
--
--   NOT emitted as a server-side `is_live` boolean, deliberately. A boolean
--   computed here is true at the instant of the query and stays true in the
--   widget for as long as the pin is on screen -- and this screen holds its
--   pins across a 500ms-debounced pan, so a party that starts between two
--   fetches would render as not-live until the user moved the map. Shipping
--   the timestamps lets the client re-evaluate on every rebuild. It also keeps
--   this migration to the payload: an is_live column is a rule, and a rule
--   would want to live in a helper (CLAUDE.md #4) that nothing else calls yet.
--
--   This does NOT address gotcha 21 -- a party with a null ends_at is still on
--   the map forever, because the fix for that is a product decision about
--   party lifecycle and not a column. It does mean the client can now SEE the
--   null, which is the prerequisite for ever handling it.
--
-- area, cover_path -- the pin draws a 34x34 DiagonalStripePlaceholder where a
--   cover image goes, and MapPinSheet has no neighbourhood line, because
--   neither column reached them. Both were added in 20260820095801 and are
--   already in get_my_hosted_parties' payload (20260821081326); this is the
--   map catching up to the profile.
--
--   cover_path is a STORAGE KEY, not a URL, and stays one. `party-covers` is
--   a private bucket, so a pin needs a signed URL and the signing belongs in
--   the repository layer, exactly as ProfileRepository.avatarUrl does it for
--   avatars. A function that returned a URL here would be a second place that
--   knows how a bucket is reached.
--
-- Nothing about visibility changes. Every one of the four rides the same
-- `parties` row the caller was already allowed to see -- the SELECT policy
-- (can_access_party), the host's map_visibility gate and the tier filter are
-- copied through verbatim below. This migration widens what a permitted row
-- says, never which rows are permitted.
--
--
-- 2. THE LIMIT
--
-- The function has never had one. Zoomed to a dense city centre it returns
-- every published party in the viewport, all of it decoded into Dart objects
-- and handed to a MarkerLayer that will draw one 112px pill per row on top of
-- the others -- so the cost is paid three times (server, transport, layout)
-- for pins nobody can distinguish. 200 is well above what is legible on a
-- phone screen and well below what hurts.
--
-- The cap is only sound BECAUSE of the ORDER BY it follows, which is
-- unchanged: sponsored first, then nearest. Truncation therefore drops the
-- farthest pins from the centre of the viewport, which is the one truncation a
-- map can absorb without lying -- and it is stable under a re-fetch, since
-- both keys are functions of the row and the map centre rather than of
-- insertion order. `limit` in a `language sql` function applies to the whole
-- result, after the ORDER BY, not per-scan.
--
-- Deliberately NOT keyset pagination (CLAUDE.md #5). Keyset is for a list a
-- user scrolls to the end of; nobody pages through a map. The viewport IS the
-- cursor, and the client already re-queries on every pan. What the cap does
-- need is for the client to be able to tell "200 because that is all there is"
-- from "200 because the map is saturated" -- that is a UI affordance (a "zoom
-- in to see more" hint) built from `rows.length == limit`, and it is the map
-- rework's job, not this migration's.
--
-- Capped rather than free: `least(p_limit, 500)` so a hand-rolled call cannot
-- ask for the unbounded behaviour this migration exists to remove, and
-- `greatest(..., 1)` so a zero or negative cannot produce an empty map that
-- looks like "no parties nearby".
--
--
-- 3. WHAT IS NOT CHANGED, AND WHY IT LOOKS LIKE IT SHOULD BE
--
-- The ~995ms p50 at 10k parties is untouched. It is not in this function --
-- it is the `parties` row policy being a security barrier that a non-leakproof
-- st_dwithin cannot be pushed past, which costs the GiST index (gotcha 19,
-- docs/phase-10-hardening-audit.md section 5). The LIMIT above does not help
-- it either: the seq-scan and the ~10k can_access_party calls happen BEFORE
-- the sort, so a limit trims what is returned, not what is read. Fixing it
-- means rewriting the policy, which is the widest blast radius in the schema
-- and its own migration with its own test run.
--
-- The EXECUTE grant is also untouched -- see the note at the bottom.
-- ============================================================

drop function if exists public.get_parties_near_user(double precision, double precision, double precision);

create function public.get_parties_near_user(
  map_center_lon double precision,
  map_center_lat double precision,
  radius_meters double precision,
  p_limit int default 200
)

returns table (
  party_id uuid,
  title text,
  description text,
  starts_at timestamp with time zone,
  ends_at timestamp with time zone,
  area text,
  cover_path text,
  is_private boolean,
  is_sponsored boolean,
  party_tier text,
  host_id uuid,
  host_username text,
  lat double precision,
  lon double precision,
  distance_meters double precision,
  going_count int,
  interested_count int,
  my_rsvp_status public.rsvp_status,
  is_invited boolean
)

language sql
set search_path = public, extensions
as $$
  select
    p.id as party_id,
    p.title,
    p.description,
    p.starts_at,
    p.ends_at,
    p.area,
    p.cover_path,
    p.is_private,
    p.is_sponsored,
    p.party_tier,
    p.host_id,
    pr.username as host_username,

    -- Grab party location
    st_y(p.location::geometry) as lat,
    st_x(p.location::geometry) as lon,

    -- Distance from current user's map view
    st_distance(p.location, st_point(map_center_lon, map_center_lat)::geography) as distance_meters,

    p.going_count,
    p.interested_count,

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

    -- Only surface parties that are live and haven't ended
    p.status = 'published'
    and (p.ends_at is null or p.ends_at > now())

    -- PostGIS proximity check
    and st_dwithin(p.location, st_point(map_center_lon, map_center_lat)::geography, radius_meters)

    -- The host's map_visibility, plus the party-specific override. Ordered
    -- cheapest-first: the enum compare settles the overwhelming majority of
    -- rows ('public' is the default) before any subquery is considered.
    and (
      pr.map_visibility = 'public'

      -- Your own parties are always on your own map, at every tier.
      or p.host_id = (select auth.uid())

      -- 'followers' = people who follow the HOST. Note the direction: the
      -- viewer is the follower, the host is the followee.
      or (
        pr.map_visibility = 'followers'
        and exists (
          select 1 from public.follows f
          where f.follower_id = (select auth.uid())
            and f.followee_id = p.host_id
        )
      )

      -- The override. Both arms are a deliberate act tying this viewer to THIS
      -- party, which outranks the host's blanket setting -- including at
      -- 'private'.
      or exists (
        select 1 from public.invitations i
        where i.party_id = p.id and i.guest_id = (select auth.uid())
      )
      or exists (
        select 1 from public.rsvps r
        where r.party_id = p.id and r.user_id = (select auth.uid())
      )
    )

    -- Filter which parties to show
    and case
        -- If the viewport is small (Zoomed in)
        when radius_meters <= 15000
        then true

        -- If the viewport is medium (Zoomed out to a region)
        when radius_meters <= 100000
        then p.party_tier in ('large', 'mega')

        -- If the viewport is large (Zoomed out to the globe)
        else
        p.party_tier = 'mega' or p.is_sponsored = true
    end
  order by p.is_sponsored desc, distance_meters asc
  limit greatest(least(p_limit, 500), 1);
$$;


-- ============================================================
-- GRANTS AFTER THE DROP
--
-- The function had NO grant or revoke anywhere in the migration history: it
-- has always run on the default `execute ... to public` that Postgres issues
-- on every new function, which is why `anon` can call it. DROP removed that
-- default from the old signature and CREATE re-issued it on the new one, so
-- the reachable set is byte-for-byte what it was before this migration -- not
-- because nothing was restated, but because the default happens to restate
-- itself.
--
-- That is stated explicitly rather than left implicit BECAUSE the status quo
-- is an open question and not a decision: whether an unauthenticated map is
-- intended has not been answered, and the answer is a `revoke execute ... from
-- public` (plus the gotcha #13 `grant ... to service_role` that must follow
-- it) in a migration of its own. Deciding it here, inside a payload change,
-- would bury a product decision in a refactor.
--
-- If the answer turns out to be "authenticated only", note that the revoke is
-- the SECOND half of the fix and not the whole of it -- `anon` also holds
-- `select on public.parties` (20260812115436), so a client can read pins
-- straight off PostgREST without this function at all. The RPC is the
-- convenient door, not the only one.
-- ============================================================

comment on function public.get_parties_near_user(double precision, double precision, double precision, int) is
  'The map query: published, unfinished parties within radius_meters of the viewport centre, tier-filtered by zoom, gated by the host''s map_visibility with a per-party override for invitees/attendees. Ordered sponsored-then-nearest and capped at p_limit (default 200, hard max 500) -- truncation drops the farthest pins. Emits starts_at AND ends_at rather than an is_live flag so the client can re-evaluate liveness as time passes; cover_path is a storage key into the private party-covers bucket, never a URL.';
