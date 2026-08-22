-- Phase 13: a leakproof spatial pre-filter for the map query.
--
-- Full reasoning: docs/phase-13-leakproof-spatial-prefilter.md. The short
-- version, because the mechanism is unintuitive and Phase 12 got it backwards
-- once already:
--
-- An RLS policy is a security barrier. A *user* qual may be evaluated ahead of
-- it -- which is what becoming an Index Cond requires -- only if THAT USER QUAL
-- is leakproof. It has nothing to do with how cheap the policy is, and nothing
-- to do with whether the policy itself is leakproof. Phase 12 made the policy
-- 5x cheaper (995ms -> 199ms) and the plan stayed a seq scan, because
-- st_dwithin, _st_expand and geography_overlaps are all proleakproof = f and so
-- can never sort ahead of the policy.
--
-- float8ge and float8le ARE leakproof. So `bbox_lat between <const> and
-- <const>` runs BEFORE the policy, reaches a plain btree, and shrinks the input
-- before is_blocked() is called even once. Measured at 10k parties, with the
-- policy completely untouched: 205ms -> 9.3ms, and 10,022 rows reaching the
-- policy -> 430.
--
-- This is the same mechanism the Τώρα / Αργότερα / Το ΣΚ time chips use
-- (gotcha 22), applied spatially. The two compose.
--
-- NOTHING about visibility changes here. No policy, no helper, no grant. That
-- is the entire reason this route was chosen over a SECURITY DEFINER read RPC
-- that measures ~100x better -- see §9 of
-- docs/phase-12-parties-policy-rewrite.md before you reopen that.


-- ---------------------------------------------------------------------------
-- 1. The box.
--
-- ONE definition, called by both the RPC and the pgTAP superset assertion, so
-- the test cannot drift from the thing it certifies.
--
-- The bounds are DERIVED from PostGIS and never computed from a
-- degrees-per-metre constant. That is not fastidiousness: a first attempt
-- during Phase 12's measurement used 5000/111320 = 0.0449 deg of latitude and
-- returned 298 rows where the unfiltered query returned 299. st_dwithin on
-- GEOGRAPHY measures on the WGS84 spheroid, where a degree of latitude at 38N
-- is ~110996m, so 5000m is 0.04501 deg -- the box was 0.00011 deg short and it
-- clipped a real party off the map, silently, with no error anywhere. The
-- error scales with latitude and only bites parties within metres of the box
-- edge, which is the hardest possible shape to notice.
--
-- HOW THE BOUNDS ARE DERIVED, and why not with st_buffer.
--
-- The first implementation used the envelope of a geodesic st_buffer padded by
-- a fixed 0.001 deg. 18_map_spatial_prefilter.test.sql rejected it: at the
-- 500km tier it EXCLUDED parties the circle admits, at all three test
-- latitudes. st_buffer on geography transforms to a planar "best SRID",
-- buffers there and transforms back, so at that radius it carries a projection
-- error and a polygon-approximation error, and a flat ~111m pad covers
-- neither. It was a superset at 5km and not at 500km -- the worst way to be
-- wrong, because it is correct everywhere anyone happened to look first.
--
-- So the bounds are closed form, and every rounding goes the conservative way:
--
--   delta   = radius / 6335439    the angular radius. 6335439m is the SMALLEST
--                                 radius of curvature anywhere on WGS84
--                                 (meridional, at the equator); using the
--                                 smallest makes delta the largest, widening
--                                 the box.
--   lat +/- delta                 on a sphere these are the exact extremes,
--                                 and delta is over-estimated, so they sit
--                                 outside the true ones.
--   lon_delta = asin(sin(delta) / cos(lat_worst))
--                                 the standard bound, evaluated at the WIDEST
--                                 latitude the box reaches rather than at the
--                                 centre -- cos is smaller there, so lon_delta
--                                 comes out larger.
--
-- st_expand then adds a flat pad on top. A circle reaching a pole has no
-- meaningful longitude bound and one wider than a quarter of the globe breaks
-- the asin; both degrade to the full longitude range rather than to a wrong
-- answer. Neither is reachable from the map, whose widest tier is 500km.

create function public.map_search_box(
  p_lon double precision,
  p_lat double precision,
  p_radius_meters double precision
)
returns public.geometry
language sql
stable
set search_path = ''
as $$
  with a as (
    select p_radius_meters / 6335439.0 as delta_rad
  ),
  b as (
    select a.delta_rad,
           p_lat - degrees(a.delta_rad) as lat_min,
           p_lat + degrees(a.delta_rad) as lat_max
    from a
  ),
  c as (
    -- The widest latitude the box reaches, clamped off the pole so cos()
    -- cannot reach zero.
    select b.*, least(89.9, greatest(abs(b.lat_min), abs(b.lat_max))) as lat_worst
    from b
  ),
  d as (
    select c.*,
           case
             when c.delta_rad >= pi() / 2 then 180.0
             when c.lat_worst >= 89.0 then 180.0
             else degrees(asin(least(1.0, sin(c.delta_rad) / cos(radians(c.lat_worst)))))
           end as lon_delta
    from c
  )
  select public.st_expand(
           public.st_makeenvelope(
             greatest(p_lon - d.lon_delta, -180.0),
             greatest(d.lat_min, -90.0),
             least(p_lon + d.lon_delta, 180.0),
             least(d.lat_max, 90.0),
             4326
           ),
           0.001
         )
  from d;
$$;

comment on function public.map_search_box(double precision, double precision, double precision) is
  'The lon/lat bounding box enclosing a geodesic circle, padded. Exists so a '
  'LEAKPROOF float8 comparison can pre-filter parties ahead of the RLS policy, '
  'which st_dwithin cannot do (see 20260821201309). MUST remain a provable '
  'superset of the circle it describes: it is a pre-filter and never the '
  'answer, and st_dwithin still does the real work. Asserted in both '
  'directions by 18_map_spatial_prefilter.test.sql -- do not tighten the pad '
  'or replace this with a degrees-per-metre constant.';

revoke execute on function public.map_search_box(double precision, double precision, double precision) from public;
grant execute on function public.map_search_box(double precision, double precision, double precision) to authenticated;


-- ---------------------------------------------------------------------------
-- 2. The columns the box is compared against.
--
-- GENERATED ALWAYS ... STORED, not a trigger and not plain columns: they cannot
-- drift from `location`, cannot be written by anyone at any privilege level,
-- and need no backfill beyond this statement.
--
-- Named bbox_* rather than lat/lon on purpose. get_parties_near_user already
-- emits output columns called `lat` and `lon`, and more importantly these are
-- index-support columns, not coordinates: nothing may ever answer a distance
-- question from them. The name is the reminder.
--
-- This does NOT breach the two-geography-column rule that
-- 08_proximity_and_retention.test.sql asserts over pg_attribute -- these are
-- double precision. It is still worth saying why they are defensible: they are
-- generated, unwritable, and derived from a column that is already public data
-- with no retention clock on it. `user_devices.last_location` must NEVER get
-- the same treatment: it IS the retention clock (gotcha 8), and a generated
-- column would sidestep round_location and put a precise fix back in the heap.
alter table public.parties
  add column bbox_lat double precision generated always as (public.st_y(location::public.geometry)) stored,
  add column bbox_lon double precision generated always as (public.st_x(location::public.geometry)) stored;

comment on column public.parties.bbox_lat is
  'Generated from location. Index support for the leakproof map pre-filter '
  'ONLY -- never use it to answer a distance question, that is st_dwithin''s '
  'job against `location`, which remains the source of truth.';
comment on column public.parties.bbox_lon is
  'Generated from location. See bbox_lat.';

create index parties_bbox_idx on public.parties (bbox_lat, bbox_lon);


-- ---------------------------------------------------------------------------
-- 3. The RPC, with the pre-filter added and nothing else changed.
--
-- The four bounds are scalar subqueries so they land as InitPlan constants,
-- evaluated once per query. That is load-bearing: if they became correlated
-- expressions the per-row predicate would stop being `float8 op const`, stop
-- being leakproof, and sink back behind the policy -- which is the entire
-- failure this migration exists to fix, reintroduced silently and with no
-- symptom other than the old timing.
--
-- st_dwithin STAYS. The box is a superset of the circle, so it admits corners
-- the circle does not; deleting st_dwithin because "the box already filtered"
-- turns the search area into a square. Same class of mistake as deleting
-- either half of the two-term st_dwithin in the proximity engine (gotcha 10):
-- one term is the index, the other is the answer.
--
-- The pre-filter is applied at every zoom tier rather than only the 5km one,
-- and that is a trade with a measured price rather than a free lunch. Boxed vs
-- unboxed on the same tree, 10k parties, p50 over 40 iterations:
--
--     5km    241.4ms -> 16.0ms     15x faster
--     50km    66.2ms -> 69.1ms      4.4% slower
--     500km   59.1ms -> 63.5ms      7.3% slower
--
-- At the wide tiers the box spans several degrees, so the planner correctly
-- declines the index -- but the predicate is still in the WHERE clause and
-- still costs a flat ~3-4ms (four InitPlans, then a float8 compare per row).
-- It is kept anyway: 225ms saved at the zoom users actually sit at, against
-- 3ms on the two rarest tiers, on queries already taking 60-70ms.
--
-- Gating it on `radius_meters <= 15000` would recover that 3ms and was
-- rejected: it puts a second, undocumented copy of the tier `case` below into
-- the same WHERE clause, where the two can drift apart silently. If the wide
-- tiers ever matter enough to revisit, move BOTH into one place rather than
-- adding a threshold here.
create or replace function public.get_parties_near_user(
  map_center_lon double precision,
  map_center_lat double precision,
  radius_meters double precision,
  p_limit integer default 200
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
  going_count integer,
  interested_count integer,
  my_rsvp_status rsvp_status,
  is_invited boolean
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
    p.cover_path,
    p.is_private,
    p.is_sponsored,
    p.party_tier,
    p.host_id,
    pr.username as host_username,

    -- Grab party location. Still from `location`, not from bbox_lat/bbox_lon:
    -- those exist to narrow, not to answer.
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

    -- THE PRE-FILTER. Four leakproof float8 comparisons against InitPlan
    -- constants, so they are evaluated BEFORE the row policy and cut the
    -- input to it. Everything below this point runs on the survivors.
    p.bbox_lat >= (select st_ymin(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))
    and p.bbox_lat <= (select st_ymax(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))
    and p.bbox_lon >= (select st_xmin(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))
    and p.bbox_lon <= (select st_xmax(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))

    -- Only surface parties that are live and haven't ended
    and p.status = 'published'
    and (p.ends_at is null or p.ends_at > now())

    -- PostGIS proximity check. The box above is a SUPERSET of this circle, so
    -- this is what actually decides -- see the migration header.
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
$function$;

-- `create or replace function` resets neither grants nor the anon revoke from
-- 20260821175831, but re-stating them costs nothing and makes this migration
-- readable on its own. anon stays revoked: the RPC's own guard means it could
-- only ever return 42501 for an unauthenticated caller.
revoke execute on function public.get_parties_near_user(double precision, double precision, double precision, integer) from anon;
grant execute on function public.get_parties_near_user(double precision, double precision, double precision, integer) to authenticated;
