-- Phase 15: the map's time chips, filtered server-side.
--
-- Όλα (default) / Τώρα / Αργότερα απόψε / Το ΣΚ. Until now `_filter` in
-- map_screen.dart coloured a pill and nothing read it; no query has ever seen
-- it. This migration is the query half.
--
-- Full reasoning: docs/phase-15-map-time-filters.md. Four things in here are
-- load-bearing and look arbitrary without the argument:
--
--
-- 1. THE DEFAULT WINDOW CHANGES NOTHING, DELIBERATELY.
--
-- `p_window` defaults to 'all', which is an unbounded range, so every existing
-- caller -- including the ~20 positional get_parties_near_user(lon, lat, r)
-- calls across tests 03/04/11/12/16/17/18 -- keeps its exact current result.
-- The base filter `status = 'published' and (ends_at is null or ends_at >
-- now())` is UNTOUCHED. **This migration cannot remove a pin from anyone's
-- default map.** gotcha 21 stays open, and stays exactly as open as it was.
--
--
-- 2. ONLY Τώρα LOOKS BACKWARDS, so nulls are one chip's problem, not four.
--
-- Αργότερα and Το ΣΚ are forward-only windows on `starts_at`: everything they
-- can match starts in the future, so it cannot have ended and `ends_at` never
-- enters their predicates. gotcha 21's null-ends_at majority (81% of parties
-- carry no end time) is therefore reduced to exactly one window's decision.
--
-- Τώρα's decision: a party with no stated end drops out of Τώρα once it is
-- older than `party_end_grace()`. Same 6 hours search groups by, and it
-- transfers for the same *shape* of reason rather than the same reason.
-- Search's argument (docs/phase-14-text-search.md §4) was "both groups are
-- shown, so being wrong moves a row one section down". The map's is one level
-- up: **the other chip is one tap away**. A barbecue from last Tuesday drops
-- out of Τώρα and is still on Όλα. Being wrong costs a tap, not a party --
-- which is precisely what gotcha 21 says is NOT true of the base filter, and
-- exactly why the base filter is not touched here.
--
--
-- 3. THE GRACE CANNOT BE SPELLED THE OBVIOUS WAY, AND CANNOT CALL
--    party_is_past(). This is gotcha 22, and it costs ~100x.
--
-- Measured on the running stack, not inferred from the catalog alone:
--
--     timestamptz_ge/gt/le/lt     leakproof = t
--     timestamptz_pl_interval     leakproof = f
--     party_is_past               leakproof = f, proconfig = {search_path=""}
--
-- contain_leaked_vars rejects a node when it holds a leaky function call AND
-- there is a Var underneath it. So:
--
--     coalesce(ends_at, starts_at + interval '6 hours') > now()   -- LEAKY
--                       ^^^^^^^^^ Var under timestamptz_pl_interval
--
-- sinks behind the RLS barrier and is evaluated only on rows that have already
-- paid for can_access_party. Moving the interval to the constant side leaves
-- timestamptz_gt(Var, Const), which is promoted ahead of the policy:
--
--     starts_at > now() - party_end_grace()                        -- PROMOTED
--
-- The two are algebraically identical and ~100x apart. party_is_past() is
-- unusable here for the same reason plus a second one: it carries a SET clause,
-- so it can never be inlined (gotcha 20) and stays a real non-leakproof call.
--
-- Hence party_end_grace(): the NUMBER keeps one definition while the two call
-- sites use the two different shapes leakproofness forces on them. Note the
-- map's call site wraps it in a scalar subquery -- that, rather than the
-- function's IMMUTABLE marking, is what makes it a once-evaluated constant.
-- 21_map_time_windows.test.sql asserts they flip at the same instant, so the
-- two spellings cannot drift into two policies.
--
--
-- 4. THE LOCAL CALENDAR IS COMPUTED HERE, IN POSTGRES, ON A NAIVE LOCAL CLOCK.
--
-- "Tonight" and "the weekend" are local-calendar concepts -- the same argument
-- 20260817073507 made for notification_tz, and the same frame in_quiet_hours
-- evaluates in. Two consequences:
--
--   - The arithmetic runs on `timestamp` (naive local wall clock) and converts
--     back with AT TIME ZONE at the very end. Adding `interval '3 days'` to a
--     timestamptz across a DST change moves the WALL CLOCK by an hour; adding
--     it to a naive local timestamp does not. Greece's transitions land at
--     04:00 local, which is exactly this file's night boundary, so this is not
--     hypothetical.
--   - A client passing a UTC offset structurally cannot get that right.
--     Postgres carries the IANA database; Dart, without a plugin, does not
--     even know the zone NAME (DateTime.timeZoneName gives "EEST").
--
-- p_tz is therefore a parameter with a 'Europe/Athens' default, and the client
-- sends nothing in v1. It is deliberately NOT defaulted to
-- profiles.notification_tz: that column is documented as the zone QUIET HOURS
-- are evaluated in, and coupling them would make changing your push schedule
-- silently change what "tonight" means on your map. Two questions, two columns
-- -- the same split 20260817073507 drew between consent and preference.


-- ---------------------------------------------------------------------------
-- 1. The grace period, as a foldable constant.
--
-- IMMUTABLE and nullary so a call to it carries NO Var. That is the property
-- that matters, and it is weaker than it first looks: what actually keeps the
-- map's Τώρα predicate ahead of the RLS policy is that the call site wraps it
-- in a scalar subquery, `(select now() - public.party_end_grace())`, which the
-- planner turns into an InitPlan evaluated once. The per-row operator is then
-- timestamptz_gt(Var, Param) and leakproof regardless of what this function is
-- marked. 21_map_time_windows.test.sql asserts the SUBQUERY at the call site,
-- not just the marking here, because the subquery is the load-bearing half.
--
-- search_path is pinned even though the body references nothing: 13_hardening's
-- LINT function_search_path_mutable is a rule about EVERY function in public,
-- and an exception argued from a performance property that turns out not to
-- depend on it is exactly the kind of hole that rule exists to prevent. The SET
-- clause forecloses inlining (gotcha 20) and costs nothing here.
create function public.party_end_grace()
returns interval
language sql
immutable
parallel safe
set search_path = ''
as $$ select interval '6 hours' $$;

comment on function public.party_end_grace() is
  'How long a party with no stated ends_at is still considered to be running. '
  'ONE definition, two call sites with different shapes: party_is_past() puts '
  'it on the row side (coalesce(ends_at, starts_at + grace)), the map query '
  'puts it on the constant side (starts_at > now() - grace), because only the '
  'second is leakproof and therefore promoted ahead of the parties RLS policy '
  '(gotcha 22). Both are asserted to flip at the same instant.';

revoke execute on function public.party_end_grace() from public;
grant execute on function public.party_end_grace() to authenticated;


-- party_is_past re-stated against the helper, so the 6 hours exists once.
-- Body is otherwise identical to 20260822113256.
create or replace function public.party_is_past(
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_now timestamptz default now()
)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(p_ends_at, p_starts_at + public.party_end_grace()) <= p_now;
$$;


-- ---------------------------------------------------------------------------
-- 2. The window boundaries.
--
-- ONE place, so the map -- and any later surface that grows a "tonight" filter
-- -- cannot each invent their own Friday.
--
-- Every window is HALF-OPEN [lower, upper) over `starts_at`, and always
-- bounded: 'all' returns (-infinity, infinity) rather than nulls, so the RPC
-- applies two unconditional comparisons instead of branching. Unbounded ends
-- are literally infinite rather than "no clause", because a null bound would
-- need `or bound is null` in the WHERE -- an extra per-row term on the hottest
-- query in the schema, for no gain.
--
-- p_now is a parameter for the same reason party_is_past's is, and the same
-- reason MapPartyPin.liveAt takes a clock: both sides of every boundary become
-- assertable without sleeping, and the pgTAP suite stops depending on the
-- wall-clock time it happens to run at.
--
-- plpgsql rather than SQL because of the RAISE. An unknown window must fail
-- loudly -- silently coercing a typo to 'all' would show a full map under a
-- highlighted chip, which reads as "the filter is broken" with nothing
-- anywhere to say so. 22023 matches validate_notification_tz's choice for the
-- same class of mistake.
create function public.party_time_window(
  p_window text,
  p_tz     text        default 'Europe/Athens',
  p_now    timestamptz default now()
)
returns tstzrange
language plpgsql
stable
set search_path = ''
as $$
declare
  v_local  timestamp;   -- the naive local wall clock
  v_anchor date;        -- the calendar day whose NIGHT this instant belongs to
  v_fri    date;
  v_lower  timestamptz;
  v_upper  timestamptz;
begin
  -- 'all' and null are the same request: no time bound at all. null is
  -- accepted rather than rejected because PostgREST will happily send one for
  -- an omitted key, and "no window" is the honest reading of it.
  if p_window is null or p_window = 'all' then
    return tstzrange('-infinity', 'infinity', '[)');
  end if;

  -- Τώρα. The only window that looks backwards, and so the only one that needs
  -- an opinion about ends_at -- which lives in the RPC rather than here,
  -- because it is a predicate over two columns and not a range over one.
  if p_window = 'now' then
    return tstzrange('-infinity', p_now, '[)');
  end if;

  v_local := p_now at time zone p_tz;

  -- THE NIGHT BOUNDARY. A night belongs to the day it started on until 04:00
  -- local, so at 02:00 on Saturday the anchor is Friday. Everything below is
  -- expressed against this rather than against the calendar date, which is why
  -- "tonight" at 02:00 means the three hours left of the night in progress and
  -- not the twenty-seven hours to tomorrow morning.
  --
  -- 04:00 rather than midnight is a product decision (docs/phase-15 §2): at
  -- 23:30 a midnight boundary makes the chip cover thirty minutes and excludes
  -- a party starting at 00:30, which is the single most common start time in
  -- this domain.
  v_anchor := (v_local - interval '4 hours')::date;

  if p_window = 'tonight' then
    -- The next instant whose local clock reads 04:00: 04:00 on the day after
    -- the anchor. Built on the naive local timestamp and converted at the very
    -- end -- see header §4.
    v_upper := ((v_anchor + 1)::timestamp + interval '4 hours') at time zone p_tz;
    return tstzrange(p_now, v_upper, '[)');
  end if;

  if p_window = 'weekend' then
    -- isodow: Mon=1 .. Fri=5, Sat=6, Sun=7.
    if extract(isodow from v_anchor)::int >= 5 then
      -- The weekend is IN PROGRESS. Walk back to its Friday; the lower bound
      -- clamps to now() below, so Το ΣΚ on a Saturday means this Saturday and
      -- never next weekend.
      v_fri := v_anchor - (extract(isodow from v_anchor)::int - 5);
    else
      -- Mon-Thu: the coming Friday.
      v_fri := v_anchor + (5 - extract(isodow from v_anchor)::int);
    end if;

    -- Friday 18:00 -> Monday 04:00. The 04:00 end is the same night boundary
    -- `tonight` uses, which is what keeps a Sunday-night party running to 02:00
    -- inside the weekend instead of dropping it into the following week.
    v_lower := greatest(p_now, (v_fri::timestamp + interval '18 hours') at time zone p_tz);
    v_upper := ((v_fri + 3)::timestamp + interval '4 hours') at time zone p_tz;
    return tstzrange(v_lower, v_upper, '[)');
  end if;

  raise exception 'unknown party time window: %', p_window
    using errcode = '22023';
end;
$$;

comment on function public.party_time_window(text, text, timestamptz) is
  'The [lower, upper) range over starts_at that one map time chip means, in '
  'the caller''s local calendar. ONE definition of "tonight" (now -> the next '
  'local 04:00) and "the weekend" (Fri 18:00 -> Mon 04:00, clamped to now so '
  'it always means the weekend in progress). The arithmetic runs on the naive '
  'local clock and converts back at the end, so a DST change inside the window '
  'moves the UTC instant rather than the wall clock.';

revoke execute on function public.party_time_window(text, text, timestamptz) from public;
grant execute on function public.party_time_window(text, text, timestamptz) to authenticated;


-- ---------------------------------------------------------------------------
-- 3. The map query.
--
-- DROP then CREATE, not `create or replace`: adding defaulted parameters makes
-- a NEW function rather than replacing the old one, and the two together would
-- leave get_parties_near_user(lon, lat, r, limit) ambiguous. PostgREST resolves
-- by named arguments and would fail rather than pick one.
--
-- Nothing else in the body changes. The bbox pre-filter, st_dwithin, the
-- visibility block and the tier `case` are all separate AND terms and compose
-- with the window unchanged -- the two pre-filters are independent and
-- multiply rather than shadow one another (measured in
-- scripts/explain_map_time_windows.sh).
drop function public.get_parties_near_user(
  double precision, double precision, double precision, integer);

create function public.get_parties_near_user(
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

    -- THE SPATIAL PRE-FILTER (20260821201309). Four leakproof float8
    -- comparisons against InitPlan constants, so they are evaluated BEFORE the
    -- row policy and cut the input to it.
    p.bbox_lat >= (select st_ymin(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))
    and p.bbox_lat <= (select st_ymax(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))
    and p.bbox_lon >= (select st_xmin(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))
    and p.bbox_lon <= (select st_xmax(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))

    -- THE TIME PRE-FILTER. The same mechanism, one dimension over:
    -- timestamptz_ge and timestamptz_lt are leakproof, the bounds are scalar
    -- subqueries and therefore InitPlan constants, so these two terms also sort
    -- ahead of the policy. Measured at 10k parties: the parties scan drops from
    -- 40338 shared hits to 1046 -- a ~39x collapse in can_access_party calls --
    -- and 208ms to 6.4ms.
    --
    -- The bounds MUST stay scalar subqueries. As bare expressions they would
    -- still be correct and still leakproof, but the subquery is what guarantees
    -- one evaluation rather than one per row -- the same reason the four bbox
    -- bounds above are spelled this way.
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
    -- It is algebraically identical, it is what anyone would write first, and
    -- it is ~100x slower: timestamptz_pl_interval is not leakproof and the Var
    -- underneath it drags the term behind the RLS barrier. Same trap for
    -- party_is_past(), which is additionally uninlinable. See header §3.
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

comment on function public.get_parties_near_user(double precision, double precision, double precision, integer, text, text) is
  'The map query. p_window is one of all/now/tonight/weekend and filters '
  'server-side -- never client-side over an already-fetched viewport, or '
  '"Τώρα" would mean "whatever happened to be in the last fetch". It defaults '
  'to ''all'', an unbounded range, which is byte-identical to the '
  'pre-Phase-15 behaviour.';

-- THE GRANTS HAVE TO BE RE-STATED IN FULL, and getting this wrong is the most
-- expensive mistake available in this file.
--
-- `create or replace` preserves a function's ACL; DROP + CREATE does not. The
-- new function is born holding Postgres's default `EXECUTE TO PUBLIC`, so
-- 20260821175831's revoke is undone by this migration unless it is repeated
-- here -- and `revoke ... from anon` alone does NOT undo it, because anon's
-- privilege would then come from the PUBLIC grant rather than from a grant to
-- anon. Measured on the reset database before this block was written:
-- proacl came back `{=X/postgres,postgres=X/postgres,authenticated=X/postgres}`,
-- where the leading `=X` is PUBLIC, i.e. anon could call the map RPC again.
--
-- The revoke must therefore be FROM PUBLIC, and gotcha 13 then applies:
-- service_role's EXECUTE comes from that same default PUBLIC grant and nothing
-- else, so it has to be granted back explicitly or it silently loses access.
-- 16_map_query_payload_and_limit.test.sql asserts both halves.
revoke execute on function public.get_parties_near_user(double precision, double precision, double precision, integer, text, text) from public;
grant execute on function public.get_parties_near_user(double precision, double precision, double precision, integer, text, text) to authenticated, service_role;
