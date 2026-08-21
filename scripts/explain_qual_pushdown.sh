#!/usr/bin/env bash
# Which predicates run BEFORE the `parties` row policy, and which run after.
#
# CLAUDE.md gotcha 22 is a claim about qual ordering, and the catalog
# (`pg_proc.proleakproof`) only says what the planner is ALLOWED to do. This
# script measures what it actually did. It exists because pgTAP structurally
# cannot: an assertion about a query PLAN is not an assertion about a result,
# and the difference only appears at a volume no fixture carries.
#
# Everything happens in ONE psql session inside a transaction that ends in
# ROLLBACK. Nothing commits and the pgTAP fixtures are untouched.
#
#
# WHAT IT MEASURES
#
# Part 1 -- four variants of `select count(*) from public.parties`, each with
# one extra predicate that matches almost nothing. If a predicate is evaluated
# BEFORE the policy, it collapses the number of can_access_party calls and the
# query gets dramatically cheaper. If it is evaluated after, the policy still
# runs on every row and the predicate is free but useless. Three independent
# signals agree in the output, and any one of them alone would be weak:
#
#   1. the order of terms printed in `Filter:` (execution order),
#   2. Execution Time,
#   3. `Buffers: shared hit` -- the direct proxy for how many times
#      can_access_party ran, since it is a SECURITY DEFINER function that
#      issues its own queries. ~6 buffers per call.
#
# Part 2 -- the real question behind it: what does adding a time window to the
# map query cost, since the Τώρα / Αργότερα απόψε / Το ΣΚ chips are exactly
# that. Runs the RPC's body inline rather than the RPC, because a `language
# sql` VOLATILE set-returning function is never inlined and `explain select *
# from get_parties_near_user(...)` prints one line, `Function Scan` (gotcha 20).
#
#
# WHAT IT FOUND, 2026-08-21, at 10k parties
#
#   variant                          exec       buffers    filter order
#   A  policy only (baseline)        954 ms      62018     policy
#   B  starts_at > <const>           4.1 ms        433     TIME, then policy
#   C  title like '%zzzzzz%'         890 ms      61799     policy, then like
#   D  st_dwithin(..., 1m)           947 ms      61872     policy, then dwithin
#
#   RPC body at 5km, no window     1483 ms      64617
#   RPC body + "tonight" window      42 ms       1736      35x, and the time
#                                                          terms print first
#
# B and C match ~the same number of rows (31 and 0). The 216x between them is
# entirely qual ordering.
#
# The bonus finding is in the Part 2 filter order: `status = 'published'`
# prints AFTER can_access_party, because `enum_eq` is not leakproof, while
# `party_tier in (...)` is `texteq` and IS. That is the mechanical reason the
# 500km tier costs 208ms and the 5km tier 995ms -- the wide tiers have a
# leakproof pre-filter and the 5km branch of the `case` is a literal `true`.
# The audit inferred that from the timings; this prints the cause.
#
# Usage:
#   supabase start
#   bash scripts/explain_qual_pushdown.sh [N_PARTIES]

set -euo pipefail

DB_CONTAINER="supabase_db_MyParty"
N_PARTIES="${1:-10000}"

# A seeded persona rather than a generated one: this script asks about qual
# ordering, not about scale in the users table.
VIEWER='44444444-4444-4444-4444-444444444444'
HOST='11111111-1111-1111-1111-111111111111'
LON=23.7232
LAT=37.9748

docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -X -q \
  -v n_parties="$N_PARTIES" -v viewer="'$VIEWER'" -v host="'$HOST'" \
  -v lon="$LON" -v lat="$LAT" <<'SQL'
\set ON_ERROR_STOP on

begin;

-- session_replication_role = replica for the bulk load: it suppresses the
-- party-publish notification trigger, which is per-row on published public
-- parties and would run thousands of proximity fan-outs to set up a question
-- about a WHERE clause. Same idiom as loadtest_map_query.sh.
set local session_replication_role = replica;

-- Parallelism off, or the same query is timed against a different number of
-- workers run to run and none of the comparisons below mean anything.
set local max_parallel_workers_per_gather = 0;

insert into public.parties (host_id, title, location, starts_at, ends_at,
                            is_private, is_sponsored, party_tier, status)
select :host,
       'Load Party ' || g,
       st_setsrid(st_makepoint(:lon + (random() - 0.5) * 0.5,
                               :lat + (random() - 0.5) * 0.5), 4326)::geography,
       -- starts_at spread over 300 hours, so a 6-hour window is ~2% of rows
       -- and the far end of the range is ~0.3%. Both are realistic chip
       -- selectivities; neither is a rigged 1-row match.
       now() + (g % 300) * interval '1 hour',
       now() + (g % 300) * interval '1 hour' + interval '6 hours',
       (g % 7 = 0), (g % 11 = 0),
       (case when g % 10 = 0 then 'mega' when g % 5 = 0 then 'large' else 'standard' end),
       'published'
from generate_series(1, :n_parties) g;

set local session_replication_role = origin;
analyze public.parties;

select tests.authenticate_as(:viewer);

\echo ''
\echo '==================================================================='
\echo 'PART 1 -- one predicate at a time, against the bare table'
\echo '==================================================================='
\echo ''
\echo '### A. POLICY ONLY (baseline)'
explain (analyze, buffers, costs off, timing off)
select count(*) from public.parties p;

\echo ''
\echo '### B. LEAKPROOF: timestamptz comparison'
explain (analyze, buffers, costs off, timing off)
select count(*) from public.parties p where p.starts_at > now() + interval '298 hours';

\echo ''
\echo '### C. NOT LEAKPROOF: LIKE. Matches fewer rows than B and costs 200x more.'
explain (analyze, buffers, costs off, timing off)
select count(*) from public.parties p where p.title like '%zzzzzz%';

\echo ''
\echo '### D. NOT LEAKPROOF: st_dwithin. This is gotcha 19 in one query.'
explain (analyze, buffers, costs off, timing off)
select count(*) from public.parties p
where st_dwithin(p.location, st_point(:lon, :lat)::geography, 1);

\echo ''
\echo '==================================================================='
\echo 'PART 2 -- the map query body, with and without a time window.'
\echo 'Inlined rather than called: the RPC prints one Function Scan line.'
\echo '==================================================================='
\echo ''
\echo '### AS SHIPPED -- 5km, no time window'
explain (analyze, buffers, costs off, timing off)
select p.id, p.going_count
from public.parties p join public.profiles pr on p.host_id = pr.id
where p.status = 'published' and (p.ends_at is null or p.ends_at > now())
  and st_dwithin(p.location, st_point(:lon, :lat)::geography, 5000)
  and (pr.map_visibility = 'public' or p.host_id = (select auth.uid()));

\echo ''
\echo '### + "tonight" WINDOW -- what the Αργότερα απόψε chip would add'
explain (analyze, buffers, costs off, timing off)
select p.id, p.going_count
from public.parties p join public.profiles pr on p.host_id = pr.id
where p.status = 'published' and (p.ends_at is null or p.ends_at > now())
  and p.starts_at >= now() and p.starts_at < now() + interval '6 hours'
  and st_dwithin(p.location, st_point(:lon, :lat)::geography, 5000)
  and (pr.map_visibility = 'public' or p.host_id = (select auth.uid()));

rollback;
SQL

echo
echo "Read the Filter: line of each plan -- the printed order is the execution"
echo "order. Leakproof terms sort ahead of the policy; the rest sort behind it."
