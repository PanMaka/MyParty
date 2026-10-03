#!/usr/bin/env bash
# Phase 15: do the time chips actually pre-filter, and do they compose with the
# spatial pre-filter or shadow it?
#
# scripts/explain_qual_pushdown.sh already established the general claim
# (gotcha 22) against a bare `starts_at > <const>`. This script asks the three
# questions that one cannot, all of them specific to what Phase 15 shipped:
#
#   1. Does a bound coming out of a plpgsql STABLE function -- party_time_window
#      -- still land as an InitPlan constant and still sort ahead of the RLS
#      policy? A literal in the SQL text obviously does. A function call is the
#      thing that could quietly become a correlated expression, at which point
#      the predicate stops being `timestamptz op const`, stops being leakproof,
#      and sinks behind the barrier with no symptom other than the old timing.
#      This is the exact failure 20260821201309 warned about for the bbox
#      bounds, one dimension over.
#
#   2. Are the two spellings of the grace period really ~100x apart? The
#      migration refuses `coalesce(ends_at, starts_at + grace) > now()` on the
#      grounds that timestamptz_pl_interval is not leakproof. That is a claim
#      about the planner, and pg_proc.proleakproof only says what it is ALLOWED
#      to do. Part 2 prints what it did.
#
#   3. Do the spatial and time pre-filters MULTIPLY or does one shadow the
#      other? Both are leakproof and both sort ahead of the policy, so the
#      expectation is that they compose -- but at 5km the bbox already cuts
#      10k rows to a few hundred, and a second filter on a few hundred rows
#      cannot save what is no longer being spent. Part 3 measures all four
#      combinations rather than assuming.
#
# Everything runs in ONE psql session inside a transaction that ends in
# ROLLBACK. Nothing commits and the pgTAP fixtures are untouched.
#
# Read the `Filter:` line of each plan -- the printed order is the execution
# order -- and `Buffers: shared hit`, which is the direct proxy for how many
# times the policy's functions ran (~6 buffers per can_access_party call).
#
# Usage:
#   supabase start
#   bash scripts/explain_map_time_windows.sh [N_PARTIES]

set -euo pipefail

DB_CONTAINER="supabase_db_MyParty"
N_PARTIES="${1:-10000}"

VIEWER='44444444-4444-4444-4444-444444444444'
HOST='11111111-1111-1111-1111-111111111111'
LON=23.7232
LAT=37.9748

docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -X -q \
  -v n_parties="$N_PARTIES" -v viewer="'$VIEWER'" -v host="'$HOST'" \
  -v lon="$LON" -v lat="$LAT" <<'SQL'
\set ON_ERROR_STOP on

begin;

-- replica suppresses the party-publish notification trigger, which is per-row
-- on published public parties and would run thousands of proximity fan-outs to
-- set up a question about a WHERE clause. Same idiom as loadtest_map_query.sh.
set local session_replication_role = replica;

-- Parallelism off, or the same query is timed against a different number of
-- workers run to run and none of the comparisons mean anything.
set local max_parallel_workers_per_gather = 0;

-- starts_at spread over 300 hours so a 6-hour window is ~2% of rows: a
-- realistic chip selectivity, not a rigged one-row match. HALF the rows get a
-- null ends_at, which is roughly the real ratio (81%) and is what makes the
-- grace-period comparison in Part 2 meaningful -- with no nulls both spellings
-- would filter nothing and cost the same.
insert into public.parties (host_id, title, location, starts_at, ends_at,
                            is_private, is_sponsored, party_tier, status)
select :host,
       'Load Party ' || g,
       st_setsrid(st_makepoint(:lon + (random() - 0.5) * 0.5,
                               :lat + (random() - 0.5) * 0.5), 4326)::geography,
       now() + (g % 300) * interval '1 hour' - interval '150 hours',
       case when g % 2 = 0
            then now() + (g % 300) * interval '1 hour' - interval '144 hours'
            else null end,
       (g % 7 = 0), (g % 11 = 0),
       (case when g % 10 = 0 then 'mega' when g % 5 = 0 then 'large' else 'standard' end),
       'published'
from generate_series(1, :n_parties) g;

set local session_replication_role = origin;
analyze public.parties;

select tests.authenticate_as(:viewer);

\echo ''
\echo '==================================================================='
\echo 'PART 1 -- does a bound from party_time_window() reach the plan as a'
\echo 'constant, and does it sort ahead of the policy?'
\echo '==================================================================='
\echo ''
\echo '### 1A. BASELINE -- the policy alone, no time bound.'
explain (analyze, buffers, costs off, timing off)
select count(*) from public.parties p;

\echo ''
\echo '### 1B. A LITERAL bound. The control: this is known to be promoted.'
explain (analyze, buffers, costs off, timing off)
select count(*) from public.parties p
where p.starts_at >= now() and p.starts_at < now() + interval '6 hours';

\echo ''
\echo '### 1C. THE SHIPPED SHAPE -- bounds from party_time_window() in scalar'
\echo '### subqueries. Look for "InitPlan" and for starts_at printing BEFORE'
\echo '### is_blocked/can_access_party in the Filter. If this matches 1A''s'
\echo '### buffer count instead of 1B''s, the function became a correlated'
\echo '### expression and the whole phase is a no-op with no other symptom.'
explain (analyze, buffers, costs off, timing off)
select count(*) from public.parties p
where p.starts_at >= (select lower(public.party_time_window('tonight', 'Europe/Athens')))
  and p.starts_at <  (select upper(public.party_time_window('tonight', 'Europe/Athens')));

\echo ''
\echo '==================================================================='
\echo 'PART 2 -- the two spellings of the grace period.'
\echo 'Identical rows. The migration claims ~100x. This is the measurement.'
\echo '==================================================================='
\echo ''
\echo '### 2A. CONSTANT SIDE (shipped): starts_at > now() - grace.'
\echo '### timestamptz_gt(Var, Const) -- leakproof, promoted.'
\echo '###'
\echo '### The base filter (ends_at is null or ends_at > now()) is part of this'
\echo '### variant and not incidental to it: the shipped predicate is the AND of'
\echo '### the two, and only the pair is equivalent to not party_is_past(). With'
\echo '### a stated end the base filter decides; with a null end it is vacuous'
\echo '### and the grace decides. Dropping it here made 2D read 2282 vs 170 --'
\echo '### the control doing its job on the measurement rather than the code.'
explain (analyze, buffers, costs off, timing off)
select count(*) from public.parties p
where p.starts_at <= now()
  and (p.ends_at is null or p.ends_at > now())
  and (p.ends_at is not null or p.starts_at > (select now() - public.party_end_grace()));

\echo ''
\echo '### 2B. ROW SIDE (refused): coalesce(ends_at, starts_at + grace) > now().'
\echo '### A Var under timestamptz_pl_interval, which is not leakproof.'
explain (analyze, buffers, costs off, timing off)
select count(*) from public.parties p
where p.starts_at <= now()
  and coalesce(p.ends_at, p.starts_at + public.party_end_grace()) > now();

\echo ''
\echo '### 2C. THE HELPER CALL (refused): party_is_past(). Same trap plus a'
\echo '### second one -- it carries a SET clause and can never be inlined.'
explain (analyze, buffers, costs off, timing off)
select count(*) from public.parties p
where p.starts_at <= now()
  and not public.party_is_past(p.starts_at, p.ends_at);

\echo ''
\echo '### 2D. THE CONTROL. All three must return the SAME COUNT, or the'
\echo '### comparison above is between three different questions.'
select
  (select count(*) from public.parties p
    where p.starts_at <= now()
      and (p.ends_at is null or p.ends_at > now())
      and (p.ends_at is not null or p.starts_at > now() - public.party_end_grace())) as constant_side,
  (select count(*) from public.parties p
    where p.starts_at <= now()
      and coalesce(p.ends_at, p.starts_at + public.party_end_grace()) > now()) as row_side,
  (select count(*) from public.parties p
    where p.starts_at <= now()
      and not public.party_is_past(p.starts_at, p.ends_at)) as helper;

\echo ''
\echo '==================================================================='
\echo 'PART 3 -- the map query body: do the spatial and time pre-filters'
\echo 'compose, or does one shadow the other?'
\echo ''
\echo 'Inlined rather than called: a language sql VOLATILE set-returning'
\echo 'function is never inlined, so `explain select * from'
\echo 'get_parties_near_user(...)` prints one line, Function Scan (gotcha 20).'
\echo '==================================================================='

\echo ''
\echo '### 3A. NEITHER pre-filter -- the pre-Phase-13, pre-Phase-15 shape.'
explain (analyze, buffers, costs off, timing off)
select p.id, p.going_count
from public.parties p join public.profiles pr on p.host_id = pr.id
where p.status = 'published' and (p.ends_at is null or p.ends_at > now())
  and st_dwithin(p.location, st_point(:lon, :lat)::geography, 5000)
  and (pr.map_visibility = 'public' or p.host_id = (select auth.uid()));

\echo ''
\echo '### 3B. SPATIAL only -- as shipped by Phase 13, window = all.'
explain (analyze, buffers, costs off, timing off)
select p.id, p.going_count
from public.parties p join public.profiles pr on p.host_id = pr.id
where p.bbox_lat >= (select st_ymin(public.map_search_box(:lon, :lat, 5000)))
  and p.bbox_lat <= (select st_ymax(public.map_search_box(:lon, :lat, 5000)))
  and p.bbox_lon >= (select st_xmin(public.map_search_box(:lon, :lat, 5000)))
  and p.bbox_lon <= (select st_xmax(public.map_search_box(:lon, :lat, 5000)))
  and p.status = 'published' and (p.ends_at is null or p.ends_at > now())
  and st_dwithin(p.location, st_point(:lon, :lat)::geography, 5000)
  and (pr.map_visibility = 'public' or p.host_id = (select auth.uid()));

\echo ''
\echo '### 3C. TIME only -- the tonight window, no bbox.'
explain (analyze, buffers, costs off, timing off)
select p.id, p.going_count
from public.parties p join public.profiles pr on p.host_id = pr.id
where p.starts_at >= (select lower(public.party_time_window('tonight', 'Europe/Athens')))
  and p.starts_at <  (select upper(public.party_time_window('tonight', 'Europe/Athens')))
  and p.status = 'published' and (p.ends_at is null or p.ends_at > now())
  and st_dwithin(p.location, st_point(:lon, :lat)::geography, 5000)
  and (pr.map_visibility = 'public' or p.host_id = (select auth.uid()));

\echo ''
\echo '### 3D. BOTH -- what Phase 15 actually ships when a chip is tapped.'
explain (analyze, buffers, costs off, timing off)
select p.id, p.going_count
from public.parties p join public.profiles pr on p.host_id = pr.id
where p.bbox_lat >= (select st_ymin(public.map_search_box(:lon, :lat, 5000)))
  and p.bbox_lat <= (select st_ymax(public.map_search_box(:lon, :lat, 5000)))
  and p.bbox_lon >= (select st_xmin(public.map_search_box(:lon, :lat, 5000)))
  and p.bbox_lon <= (select st_xmax(public.map_search_box(:lon, :lat, 5000)))
  and p.starts_at >= (select lower(public.party_time_window('tonight', 'Europe/Athens')))
  and p.starts_at <  (select upper(public.party_time_window('tonight', 'Europe/Athens')))
  and p.status = 'published' and (p.ends_at is null or p.ends_at > now())
  and st_dwithin(p.location, st_point(:lon, :lat)::geography, 5000)
  and (pr.map_visibility = 'public' or p.host_id = (select auth.uid()));

\echo ''
\echo '### 3E. THE CATALOG, for comparison. It says what the planner is'
\echo '### ALLOWED to do; the plans above say what it did.'
select p.proname, p.proleakproof as leakproof
from pg_proc p
where p.proname in ('timestamptz_ge','timestamptz_lt','timestamptz_gt',
                    'timestamptz_pl_interval','timestamptz_mi_interval',
                    'float8ge','enum_eq','st_dwithin','party_is_past',
                    'party_end_grace','party_time_window')
order by p.proleakproof desc, p.proname;

rollback;
SQL

echo
echo "Part 1: 1C must match 1B, not 1A. If it matches 1A the bound stopped"
echo "being an InitPlan constant and the chips buy nothing."
echo "Part 2: 2A vs 2B/2C is the cost of the obvious spelling. 2D proves all"
echo "three answer the same question."
echo "Part 3: 3D should beat both 3B and 3C -- the two pre-filters compose."
