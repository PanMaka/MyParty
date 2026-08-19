#!/usr/bin/env bash
# Phase 10 deliverable: what does get_parties_near_user actually cost at
# realistic volume, and what breaks first?
#
# `supabase db reset` leaves 23 parties and 0 rsvps. Every plan over 23 rows is
# a seq scan and every timing is noise, so the seeded database cannot answer a
# question about latency any more than it could answer Phase 7b's question
# about index usage. This script generates 10k parties and 50k rsvps -- the
# numbers the phase prompt names -- and measures.
#
# Everything happens in ONE psql session inside a transaction that ends in
# ROLLBACK. Nothing commits and the pgTAP fixtures are untouched.
#
# TWO THINGS THIS EXISTS TO ANSWER
#
# 1. p50/p95 per zoom tier, and which node dominates. The tier `case` in the
#    RPC has three branches (<=15km, <=100km, else) and they are three
#    different queries wearing one name -- the first is a small box over every
#    tier, the last is the whole country over mega/sponsored only. Measuring
#    one of them tells you nothing about the other two.
#
# 2. Whether pinning the function's search_path costs anything. The Supabase
#    linter's one live security warning against this schema is
#    `function_search_path_mutable`, and the fix has a price: a `language sql`
#    function with a SET clause is no longer eligible for inlining, so the
#    planner loses the ability to fold the RPC into its caller. This runs the
#    identical function both ways -- as shipped, then after
#    `alter function ... set search_path` -- in the same transaction, against
#    the same rows, with the same cache warm. If the two columns match, the
#    lint fix is free and gets applied. That decision is made by this script,
#    not by preference.
#
# Usage:
#   supabase start
#   supabase db reset
#   bash scripts/loadtest_map_query.sh [N_PARTIES] [N_RSVPS] [N_USERS] [ITERATIONS]

set -euo pipefail

DB_CONTAINER="supabase_db_MyParty"
N_PARTIES="${1:-10000}"
N_RSVPS="${2:-50000}"
N_USERS="${3:-5000}"
ITERATIONS="${4:-50}"

# RSVPs are generated per party rather than as random pairs. A random pair
# collides with the (party_id, user_id) primary key often enough that
# `on conflict do nothing` silently ate more than half the rows on the first
# run -- 5000 requested, 2022 written. Spreading a fixed number over each party
# with a stride that cannot repeat inside one party gives the count that was
# asked for, and a realistic shape besides: parties have guests, guests are not
# uniformly sprayed across the whole user base.
RSVPS_PER_PARTY=$(( (N_RSVPS + N_PARTIES - 1) / N_PARTIES ))

# Syntagma, the centre of seed.sql's Athens cluster -- the same point
# explain_proximity.sh asks about, so the two scripts are comparable.
LON="23.7351"
LAT="37.9758"

if ! docker exec "$DB_CONTAINER" true 2>/dev/null; then
  echo "error: $DB_CONTAINER is not running. Run 'supabase start' first." >&2
  exit 1
fi

echo "Generating $N_USERS users, $N_PARTIES parties, $N_RSVPS rsvps (rolled back at the end)..."
echo "Timing $ITERATIONS iterations per tier per variant."
echo ""

docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -v n_users="$N_USERS" -v n_parties="$N_PARTIES" -v n_rsvps="$N_RSVPS" \
  -v iters="$ITERATIONS" -v rsvps_per="$RSVPS_PER_PARTY"   -v lon="$LON" -v lat="$LAT" <<'SQL'
\set QUIET on
\timing off
begin;

-- ------------------------------------------------------------------
-- Synthetic population, scattered over roughly Attica (~0.5 deg box).
--
-- session_replication_role = replica for the bulk load: it suppresses
-- handle_new_user, the rsvp counter triggers, the party-publish notification
-- fan-out and this phase's new rate limits, none of which are under
-- measurement and all of which would dominate the load. Reset before anything
-- is timed.
-- ------------------------------------------------------------------
set local session_replication_role = replica;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at,
                        confirmation_token, recovery_token,
                        email_change_token_new, email_change)
select '00000000-0000-0000-0000-000000000000',
       gen_random_uuid(), 'authenticated', 'authenticated',
       'load' || g || '@myparty.local', '',
       now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(),
       '', '', '', ''
from generate_series(1, :n_users) g;

create temp table load_users on commit drop as
select id, row_number() over (order by id) as n
from auth.users where email like 'load%@myparty.local';

create index on load_users (n);

-- The map_visibility spread is the point of this table, not decoration.
-- get_parties_near_user settles most rows on `pr.map_visibility = 'public'`
-- before any subquery runs, so a population that is 100% public would never
-- exercise the two arms that cost anything -- the follows lookup and the
-- invitation/rsvp override. 80/15/5 is a guess at the shape of a real user
-- base, and it is the shape the p95 is measured against.
insert into public.profiles (id, username, map_visibility)
select u.id,
       'load_' || replace(u.id::text, '-', ''),
       (case when u.n % 20 = 0 then 'private'
             when u.n % 20 < 4 then 'followers'
             else 'public' end)::public.map_visibility
from load_users u;

-- Tier mix matters as much as the count: the 50km and 500km branches of the
-- RPC filter on party_tier, so a population of all-standard parties would make
-- the two zoomed-out tiers return nothing and look free.
insert into public.parties (host_id, title, location, starts_at, ends_at,
                            is_private, is_sponsored, party_tier, status)
select (select id from load_users where n = 1 + (g % :n_users)),
       'Load Party ' || g,
       st_setsrid(st_makepoint(:lon + (random() - 0.5) * 0.5,
                               :lat + (random() - 0.5) * 0.5), 4326)::geography,
       now() + (g % 300) * interval '1 hour',
       now() + (g % 300) * interval '1 hour' + interval '6 hours',
       (g % 7 = 0),
       (g % 11 = 0),
       (case when g % 10 = 0 then 'mega'
             when g % 5 = 0 then 'large'
             else 'standard' end),
       'published'
from generate_series(1, :n_parties) g;

create temp table load_parties on commit drop as
select id, row_number() over (order by id) as n
from public.parties where title like 'Load Party %';

create index on load_parties (n);

-- The rsvps. :rsvps_per guests per party, picked by a stride that cannot
-- repeat within one party, so the primary key never collides and the requested
-- total is the written total. The real count is printed below regardless --
-- an assumed row count is how the first draft of this script reported half the
-- data it thought it had.
insert into public.rsvps (party_id, user_id, status)
select p.id, u.id,
       (case when k % 4 = 0 then 'interested' else 'going' end)::public.rsvp_status
from load_parties p
cross join generate_series(0, :rsvps_per - 1) k
join load_users u on u.n = 1 + ((p.n * 37 + k * 101) % :n_users)
on conflict (party_id, user_id) do nothing;

-- The viewer: user 1. Everything below is measured through this person's eyes,
-- so they need a realistic amount of each thing the RPC's OR arms look up. A
-- viewer with zero follows and zero invitations measures the cheap path only.
create temp table load_viewer on commit drop as
select id from load_users where n = 1;

insert into public.follows (follower_id, followee_id)
select (select id from load_viewer), u.id
from load_users u
where u.n between 2 and 201
on conflict do nothing;

insert into public.invitations (party_id, guest_id)
select p.id, (select id from load_viewer)
from load_parties p
where p.n % 97 = 0
on conflict do nothing;

insert into public.rsvps (party_id, user_id, status)
select p.id, (select id from load_viewer), 'going'
from load_parties p
where p.n % 89 = 0
on conflict (party_id, user_id) do nothing;

set local session_replication_role = origin;

analyze public.parties;
analyze public.profiles;
analyze public.rsvps;
analyze public.invitations;
analyze public.follows;

\set QUIET off

\echo ''
\echo '=== Population these numbers were measured against ========================='
select
  (select count(*) from public.parties)     as parties,
  (select count(*) from public.rsvps)       as rsvps,
  (select count(*) from public.profiles)    as profiles,
  (select count(*) from public.follows)     as follows,
  (select count(*) from public.invitations) as invitations;

select map_visibility, count(*)
from public.profiles group by 1 order by 2 desc;

\set QUIET on


-- ------------------------------------------------------------------
-- The harness.
--
-- A FOR loop over the result set, not `select count(*) from ...`. That is not
-- fussiness: count(*) references none of the output columns, so the planner is
-- free to drop the two correlated subqueries in the select list
-- (my_rsvp_status, is_invited) and never evaluate them. Those subqueries are
-- among the things under measurement. A row-by-row loop touches every column,
-- which is what PostgREST does when it serialises the response.
-- ------------------------------------------------------------------
create temp table load_results (
  variant text,
  radius double precision,
  ms double precision,
  rows_returned int
) on commit drop;

grant select, insert, delete on load_results to authenticated;

create or replace function pg_temp.bench(p_fn text, p_variant text,
                                         p_radius double precision, p_iters int)
returns void
language plpgsql
as $$
declare
  i int;
  t0 timestamptz;
  n int;
  rec record;
begin
  for i in 1..p_iters loop
    n := 0;
    t0 := clock_timestamp();
    for rec in execute format('select * from %s(23.7351, 37.9758, $1)', p_fn)
               using p_radius
    loop
      n := n + 1;
    end loop;
    insert into load_results
    values (p_variant, p_radius,
            extract(epoch from clock_timestamp() - t0) * 1000, n);
  end loop;
end;
$$;


-- ------------------------------------------------------------------
-- The third variant, built from the catalog rather than copy-pasted.
--
-- pg_get_function_arguments/pg_get_function_result/prosrc reconstruct the
-- shipped function exactly, changing one word: STABLE instead of the default
-- VOLATILE. No duplicated body means this cannot drift away from the real one.
--
-- Why that word is the whole experiment. A `language sql` set-returning
-- function is folded into its caller -- inlined -- only if it is not
-- SECURITY DEFINER, has no SET clause, and is NOT VOLATILE. get_parties_near_user
-- is volatile (nobody declared otherwise, and volatile is the default), so it
-- has never been inlined a single time in this project's history. Measured:
-- `explain select * from get_parties_near_user(...)` prints one line, "Function
-- Scan"; the same body declared STABLE prints a 37-line plan with the GiST
-- index scan and every subplan visible.
--
-- That reframes the search_path question the phase set out to answer. The
-- concern was that pinning search_path would cost inlining -- but there is no
-- inlining to lose. What pinning actually costs is the OPTION of gaining it,
-- and this variant prices that option.
-- ------------------------------------------------------------------
do $$
declare r record;
begin
  select pg_get_function_arguments(p.oid) as args,
         pg_get_function_result(p.oid)    as res,
         p.prosrc                         as src
  into r
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_parties_near_user';

  execute format(
    'create function public.map_query_stable(%s) returns %s language sql stable as %L',
    r.args, r.res, r.src);
end $$;


-- Measured as the viewer, through RLS. Running this as postgres would skip
-- every policy on parties and profiles and measure a query the app never
-- issues -- Phase 8 found policy evaluation was >90% of the cost of
-- get_profile_stats, so leaving RLS out is not a small simplification.
select tests.authenticate_as((select id from load_viewer));

-- Warm-up, discarded: the first call of each shape pays for plan caching and
-- cold shared_buffers, and reporting that as p50 is reporting a cache miss.
select pg_temp.bench('public.get_parties_near_user', 'warmup', 5000, 3);
select pg_temp.bench('public.get_parties_near_user', 'warmup', 50000, 3);
select pg_temp.bench('public.get_parties_near_user', 'warmup', 500000, 3);
select pg_temp.bench('public.map_query_stable', 'warmup', 5000, 3);
delete from load_results where variant = 'warmup';

-- ------------------------------------------------------------------
-- Two interleaved rounds, not three blocks back to back.
--
-- The first draft ran shipped-then-pinned and reported an 18ms penalty for
-- pinning at 5km. That number was drift, not signal: the second variant always
-- runs later in a transaction that has been accumulating work. Alternating and
-- pooling both rounds makes any drift land on all three variants equally.
--
-- `alter function ... set/reset search_path` toggles the middle variant without
-- touching a character of the body, so the only difference between rounds is
-- the property under test.
-- ------------------------------------------------------------------
\set QUIET on

-- ROUND 1
select pg_temp.bench('public.get_parties_near_user', 'A: as shipped (volatile)', 5000, :iters);
select pg_temp.bench('public.get_parties_near_user', 'A: as shipped (volatile)', 50000, :iters);
select pg_temp.bench('public.get_parties_near_user', 'A: as shipped (volatile)', 500000, :iters);

reset role;
alter function public.get_parties_near_user(double precision, double precision, double precision)
  set search_path = public, extensions;
select tests.authenticate_as((select id from load_viewer));

select pg_temp.bench('public.get_parties_near_user', 'B: search_path pinned', 5000, :iters);
select pg_temp.bench('public.get_parties_near_user', 'B: search_path pinned', 50000, :iters);
select pg_temp.bench('public.get_parties_near_user', 'B: search_path pinned', 500000, :iters);

reset role;
alter function public.get_parties_near_user(double precision, double precision, double precision)
  reset search_path;
select tests.authenticate_as((select id from load_viewer));

select pg_temp.bench('public.map_query_stable', 'C: stable (inlined)', 5000, :iters);
select pg_temp.bench('public.map_query_stable', 'C: stable (inlined)', 50000, :iters);
select pg_temp.bench('public.map_query_stable', 'C: stable (inlined)', 500000, :iters);

-- The control. Same query, same rows, run as postgres so the row policies on
-- parties and profiles do not apply. NOT a shippable configuration and not an
-- option being weighed -- it is the floor, the way explain_proximity.sh's
-- seq-scanning control is a ceiling. The gap between C and D is the price of
-- RLS on this query, and it is the number the whole report turns on.
reset role;
select pg_temp.bench('public.map_query_stable', 'D: RLS bypassed (control)', 5000, :iters);
select pg_temp.bench('public.map_query_stable', 'D: RLS bypassed (control)', 50000, :iters);
select pg_temp.bench('public.map_query_stable', 'D: RLS bypassed (control)', 500000, :iters);
select tests.authenticate_as((select id from load_viewer));

-- ROUND 2, same variants, opposite end of the transaction.
select pg_temp.bench('public.map_query_stable', 'C: stable (inlined)', 5000, :iters);
select pg_temp.bench('public.map_query_stable', 'C: stable (inlined)', 50000, :iters);
select pg_temp.bench('public.map_query_stable', 'C: stable (inlined)', 500000, :iters);

reset role;
select pg_temp.bench('public.map_query_stable', 'D: RLS bypassed (control)', 5000, :iters);
select pg_temp.bench('public.map_query_stable', 'D: RLS bypassed (control)', 50000, :iters);
select pg_temp.bench('public.map_query_stable', 'D: RLS bypassed (control)', 500000, :iters);
select tests.authenticate_as((select id from load_viewer));

reset role;
alter function public.get_parties_near_user(double precision, double precision, double precision)
  set search_path = public, extensions;
select tests.authenticate_as((select id from load_viewer));

select pg_temp.bench('public.get_parties_near_user', 'B: search_path pinned', 5000, :iters);
select pg_temp.bench('public.get_parties_near_user', 'B: search_path pinned', 50000, :iters);
select pg_temp.bench('public.get_parties_near_user', 'B: search_path pinned', 500000, :iters);

reset role;
alter function public.get_parties_near_user(double precision, double precision, double precision)
  reset search_path;
select tests.authenticate_as((select id from load_viewer));

select pg_temp.bench('public.get_parties_near_user', 'A: as shipped (volatile)', 5000, :iters);
select pg_temp.bench('public.get_parties_near_user', 'A: as shipped (volatile)', 50000, :iters);
select pg_temp.bench('public.get_parties_near_user', 'A: as shipped (volatile)', 500000, :iters);

\set QUIET off

\echo ''
\echo '=== RESULTS: latency per zoom tier, per variant ============================'
\echo '5km = every tier, small box. 50km = large+mega. 500km = mega+sponsored.'
\echo ''
select
  (radius / 1000)::int || 'km' as zoom,
  variant,
  max(rows_returned) as rows,
  round(percentile_cont(0.5)  within group (order by ms)::numeric, 2) as p50_ms,
  round(percentile_cont(0.95) within group (order by ms)::numeric, 2) as p95_ms,
  round(max(ms)::numeric, 2) as max_ms,
  count(*) as samples
from load_results
group by 1, 2, radius
order by radius, variant;

\echo ''
\echo '=== The two questions, answered ============================================'
\echo 'pinning_p95 : cost of `set search_path` (A -> B). It buys the lint fix.'
\echo 'inlining_p95: what marking the function STABLE would buy (A -> C).'
\echo 'Negative = faster.'
\echo ''
with p as (
  select radius,
    percentile_cont(0.95) within group (order by ms) filter (where variant like 'A:%') as a,
    percentile_cont(0.95) within group (order by ms) filter (where variant like 'B:%') as b,
    percentile_cont(0.95) within group (order by ms) filter (where variant like 'C:%') as c,
    percentile_cont(0.95) within group (order by ms) filter (where variant like 'D:%') as d
  from load_results group by radius
)
select (radius / 1000)::int || 'km' as zoom,
       round((b - a)::numeric, 2) as pinning_p95_delta_ms,
       round((c - a)::numeric, 2) as inlining_p95_delta_ms,
       round((a - d)::numeric, 2) as rls_cost_p95_ms,
       round((100.0 * (a - d) / nullif(a, 0))::numeric, 1) as rls_pct_of_p95
from p order by radius;

\echo ''
\echo '=== The plan, and what breaks first ========================================'
\echo 'EXPLAIN of the shipped function prints one line -- "Function Scan" -- because'
\echo 'a volatile SQL function is opaque to the planner. The STABLE clone has the'
\echo 'identical body, so this IS the shipped plan, only visible. Read as the'
\echo 'viewer, so the RLS policies on parties and profiles are in it.'
\echo ''
explain (analyze, buffers, costs off)
  select * from public.map_query_stable(:lon, :lat, 5000);

\echo ''
\echo '--- the widest zoom. Also a seq scan, but the tier filter is cheap and runs'
\echo '--- first, so can_access_party is asked about far fewer rows:'
explain (analyze, buffers, costs off)
  select * from public.map_query_stable(:lon, :lat, 500000);

\echo ''
\echo '=== CONTROL: the same 5km query with the row policies off =================='
\echo 'This is the plan the GiST index was built for. It is here to show what the'
\echo 'policy costs, not to suggest turning it off.'
reset role;
explain (analyze, buffers, costs off)
  select * from public.map_query_stable(:lon, :lat, 5000);

rollback;
SQL

echo ""
echo "Rolled back. The database is exactly as db reset left it."
