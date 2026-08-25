-- Private parties stop transmitting their attendance counts.
--
-- Both read RPCs return NULL for going_count/interested_count when the row is
-- private. This is the SERVER half of "a private party shows no counts
-- anywhere"; the client half (no number in the pin, no counts in the sheet, no
-- hype bar on the card) lands in the same PR.
--
-- WHY AT THE SOURCE RATHER THAN BY CLIENT CONVENTION. The private pin has had
-- a fixed radius since the map rework -- MpDropGeometry.private() is taken
-- before the count is read, deliberately, so size carries no attendance
-- signal. But the pin still PRINTED the count as its label, and MapPinSheet
-- still rendered "N interested / N going" for private rows, so the number was
-- on screen regardless of the geometry. Even with both fixed, a payload that
-- carries the figure is one debug build or one future widget away from
-- showing it again. Not sending it is the only version of this rule that
-- cannot regress silently.
--
-- WHY NULL AND NOT 0. Zero is a legible, wrong answer -- "nobody is going" --
-- and it is indistinguishable from a real empty party. NULL is the honest
-- encoding of "this question is not answered for this row", and it forces the
-- client to have a branch for it: `int?` rather than `int`, so a surface that
-- forgets fails at the type level instead of rendering a confident 0.
--
-- SCOPE. Both RPCs, because MapPinSheet is fed by either one (20260822150239
-- and 20260824094606 exist precisely so a search hit opens the same sheet a
-- pin does) -- fixing one would leave the other rendering the number in the
-- identical widget. `parties.going_count`/`interested_count` themselves are
-- untouched and the counters trigger still maintains them: the HOST sees their
-- own guest list, and the columns still drive party_tier, which sizes nothing
-- for a private party but does decide zoom-tier visibility.

create or replace function public.get_parties_near_user(
  map_center_lon double precision,
  map_center_lat double precision,
  radius_meters double precision,
  p_limit integer default 200,
  p_window text default 'all',
  p_tz text default 'Europe/Athens'
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

    -- NULL for a private party, at the source.
    --
    -- The client no longer displays either number for a private row on any
    -- surface, so transmitting them would leave attendance data sitting in a
    -- JSON payload that nothing reads -- one debug build, one `print(row)`, or
    -- one future widget away from being visible. A value that is not sent
    -- cannot leak; a client convention not to render it is one edit from
    -- lapsing, and the edit looks harmless.
    --
    -- Costs nothing in the plan: this is the TARGET list, evaluated on rows
    -- that already survived the WHERE clause. Gotcha 22 is about predicates,
    -- and no predicate changed here -- verified by the unchanged timings in
    -- scripts/explain_map_time_windows.sh.
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

    -- THE SPATIAL PRE-FILTER (20260821201309). Four leakproof float8
    -- comparisons against InitPlan constants, so they are evaluated BEFORE the
    -- row policy and cut the input to it.
    p.bbox_lat >= (select st_ymin(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))
    and p.bbox_lat <= (select st_ymax(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))
    and p.bbox_lon >= (select st_xmin(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))
    and p.bbox_lon <= (select st_xmax(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))

    -- THE TIME PRE-FILTER. The same mechanism as the box, one dimension over:
    -- timestamptz_ge and timestamptz_lt are leakproof, and the bounds are
    -- scalar subqueries and therefore InitPlan constants, so these two terms
    -- also sort ahead of the policy.
    --
    -- That a bound coming out of a plpgsql STABLE function still reaches the
    -- plan as a constant is the one thing here that could not be assumed, and
    -- scripts/explain_map_time_windows.sh part 1 is the measurement: the plan
    -- prints `starts_at >= (InitPlan 1).col1` BEFORE is_blocked, and the scan
    -- drops from 40518 shared hits to 2409. Whole map body at 5km, tonight
    -- window: 210ms with neither pre-filter, 12.0ms with the box alone, 2.1ms
    -- with both. The two compose -- the box gets an Index Cond, the window
    -- filters what survives it, and neither shadows the other.
    --
    -- The bounds MUST stay scalar subqueries. As bare expressions they would
    -- still be correct and still leakproof, but the subquery is what guarantees
    -- one evaluation rather than one per row -- the same reason the four bbox
    -- bounds above are spelled this way, and the failure has no symptom other
    -- than the old timing.
    and p.starts_at >= (select lower(public.party_time_window(p_window, p_tz)))
    and p.starts_at <  (select upper(public.party_time_window(p_window, p_tz)))

    -- Only surface parties that are live and haven't ended.
    --
    -- UNCHANGED, deliberately: this is gotcha 21 and it stays open. A
    -- null-ends_at party is still on the default map forever. The window above
    -- narrows Τώρα; it does not touch what Όλα shows.
    and p.status = 'published'
    and (p.ends_at is null or p.ends_at > now())

    -- Τώρα ONLY: a party with no stated end stops being "now" once it is older
    -- than the grace period.
    --
    -- The first arm holds no Var, so for every other window this whole OR is
    -- constant-true and costs one text compare. For 'now' the remaining arms
    -- are a NullTest and timestamptz_gt(Var, Const), both leakproof, so the
    -- term sorts ahead of the policy with the rest of the time filter.
    --
    -- DO NOT rewrite this as coalesce(p.ends_at, p.starts_at + grace) > now().
    -- It is algebraically identical, it is what anyone would write first, and it
    -- is ~20x slower measured (6.2ms vs 120.7ms at 10k parties, same 170 rows):
    -- timestamptz_pl_interval is not leakproof and the Var underneath it drags
    -- the term behind the RLS barrier. Same trap for party_is_past(), which is
    -- additionally uninlinable. See header §3.
    and (
      coalesce(p_window, 'all') <> 'now'
      or p.ends_at is not null
      or p.starts_at > (select now() - public.party_end_grace())
    )

    -- PostGIS proximity check. The box above is a SUPERSET of this circle, so
    -- this is what actually decides -- see 20260821201309.
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

    -- Filter which parties to show. Independent of the window: zoom and time
    -- are two separate questions and both narrow.
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

comment on function public.get_parties_near_user(
  double precision, double precision, double precision, integer, text, text) is
  'Map query. going_count/interested_count are NULL for private rows -- a '
  'private party displays no attendance on any surface, so the figure is not '
  'transmitted rather than merely not rendered. Unchanged otherwise: the '
  'leakproof bbox + time pre-filters still sort ahead of the row policy.';

create or replace function public.search_parties(
  p_query text,
  p_limit integer default 20
)
returns table (
  party_id uuid,
  title text,
  description text,
  area text,
  starts_at timestamptz,
  ends_at timestamptz,
  is_private boolean,
  cover_path text,
  host_id uuid,
  host_username text,
  lat double precision,
  lon double precision,
  going_count integer,
  interested_count integer,
  my_rsvp_status rsvp_status,
  is_past boolean
)
language sql
stable
set search_path to 'public', 'extensions'
as $$
  with q as (
    select public.search_normalize(p_query) as key
  ),
  hits as (
    -- Driven from the TOKEN index, not from parties: this is the step that
    -- turns the whole table into a few rows before any policy runs. Both terms
    -- are leakproof, so they sort ahead of the token table's
    -- can_access_party() policy.
    --
    -- The range MUST stay `~>=~` / `~<~`. `like q.key || '%'` returns the same
    -- rows and never reaches the index (textlike is non-leakproof, so the
    -- planner may not promote it past the policy and the index qual is never
    -- formed). `>=` / `<` also return the same rows, are leakproof, are
    -- promoted -- and still cannot use this index, because text_ops and
    -- text_pattern_ops are different operator families. Asserted three ways in
    -- 20_party_search.test.sql.
    select distinct t.party_id
    from public.party_search_tokens t, q
    where q.key <> ''
      and t.token ~>=~ q.key
      and t.token ~<~ public.search_prefix_upper(q.key)
  )
  select
    p.id as party_id,
    p.title,
    -- Added here so the shared sheet has the same body text whichever screen
    -- opened it. Unfiltered and untruncated, exactly as the map RPC returns
    -- it: the sheet decides how much to show.
    p.description,
    p.area,
    p.starts_at,
    p.ends_at,
    p.is_private,
    p.cover_path,
    p.host_id,
    pr.username as host_username,
    -- Added by 20260822150239 so a search hit converts straight into a
    -- MapPartyPin and opens the SAME sheet the map opens. Read from
    -- `location`, exactly as the map RPC does -- NEVER from bbox_lat/bbox_lon,
    -- which are index support only and must not answer a question (Phase 13).
    st_y(p.location::geometry) as lat,
    st_x(p.location::geometry) as lon,
    -- NULL for a private party, at the source.
    --
    -- The client no longer displays either number for a private row on any
    -- surface, so transmitting them would leave attendance data sitting in a
    -- JSON payload that nothing reads -- one debug build, one `print(row)`, or
    -- one future widget away from being visible. A value that is not sent
    -- cannot leak; a client convention not to render it is one edit from
    -- lapsing, and the edit looks harmless.
    --
    -- Costs nothing in the plan: this is the TARGET list, evaluated on rows
    -- that already survived the WHERE clause. Gotcha 22 is about predicates,
    -- and no predicate changed here -- verified by the unchanged timings in
    -- scripts/explain_map_time_windows.sh.
    case when p.is_private then null else p.going_count end as going_count,
    case when p.is_private then null else p.interested_count end as interested_count,
    -- The viewer's own RSVP, not the party's. going_count/interested_count are
    -- properties of the party; this is a property of who is asking, which is
    -- why it is a correlated subquery and not a join -- a join would multiply
    -- rows for a party with many RSVPs.
    (
      select r.status from public.rsvps r
      where r.party_id = p.id and r.user_id = (select auth.uid())
    ) as my_rsvp_status,
    public.party_is_past(p.starts_at, p.ends_at) as is_past
  from hits h
  join public.parties p on p.id = h.party_id
  join public.profiles pr on pr.id = p.host_id
  where p.status = 'published'
  -- Upcoming first, soonest first; then past, most recent first. "Find that
  -- party from May" is a real use, which is why past rows are returned at all.
  order by
    public.party_is_past(p.starts_at, p.ends_at) asc,
    case when public.party_is_past(p.starts_at, p.ends_at) then null else p.starts_at end asc nulls last,
    case when public.party_is_past(p.starts_at, p.ends_at) then p.starts_at else null end desc nulls last
  limit greatest(least(p_limit, 50), 1);
$$;

comment on function public.search_parties(text, integer) is
  'Prefix search over party titles and areas, unbounded by location. '
  'SECURITY INVOKER so the parties and party_search_tokens policies both '
  'apply. map_visibility deliberately does NOT filter this -- it answers "do I '
  'want to be a pin", not "do I want to be unfindable". Past parties are '
  'returned in a second group, using party_is_past(); the map does not filter '
  'on that yet and the two therefore disagree about a null-ends_at party, '
  'which is expected. Carries description and my_rsvp_status so a hit opens '
  'the same fully-populated MapPinSheet a map pin does. going_count and '
  'interested_count are NULL for private rows, matching get_parties_near_user. '
  'The range MUST stay ~>=~ / ~<~.';
