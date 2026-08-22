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
#   bash scripts/explain_qual_pushdown.sh [N_PARTIES] [N_PROFILES]

set -euo pipefail

DB_CONTAINER="supabase_db_MyParty"
N_PARTIES="${1:-10000}"
N_PROFILES="${2:-20000}"

# A seeded persona rather than a generated one: this script asks about qual
# ordering, not about scale in the users table.
VIEWER='44444444-4444-4444-4444-444444444444'
HOST='11111111-1111-1111-1111-111111111111'
LON=23.7232
LAT=37.9748

docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -X -q \
  -v n_parties="$N_PARTIES" -v n_profiles="$N_PROFILES" -v viewer="'$VIEWER'" -v host="'$HOST'" \
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
\echo '### E. TEXT RANGE: text_ge + text_lt. THE OPTION-2 QUESTION.'
\echo '### Written as an explicit range, not as LIKE ''x%'': without a'
\echo '### text_pattern_ops index the planner leaves LIKE as textlike and'
\echo '### never forms the range, so LIKE would measure the wrong operator.'
explain (analyze, buffers, costs off, timing off)
select count(*) from public.parties p
where p.title >= 'zzzzzz' and p.title < 'zzzzz{';

\echo ''
\echo '### F. NOT LEAKPROOF (expected): ILIKE, the operator search would use.'
explain (analyze, buffers, costs off, timing off)
select count(*) from public.parties p where p.title ilike '%zzzzzz%';

\echo ''
\echo '### G. The real option-2 SHAPE: a text_pattern_ops btree + prefix LIKE.'
\echo '### If E sorts ahead of the policy this should become an Index Cond;'
\echo '### if E sorts behind it, the index is unreachable for the same reason'
\echo '### parties_location is (gotcha 19) and option 2 does not exist.'
reset role;
create index parties_title_prefix_idx on public.parties (title text_pattern_ops);
analyze public.parties;
select tests.authenticate_as(:viewer);
explain (analyze, buffers, costs off, timing off)
select count(*) from public.parties p where p.title like 'zzzzzz%';

\echo ''
\echo '### I. THE DECISIVE ONE: the explicit range, WITH the index present.'
\echo '### E proved the range is promoted past the policy; G proved LIKE is'
\echo '### not rewritten into that range across the barrier. I asks the only'
\echo '### remaining question -- whether the promoted range reaches the index.'
explain (analyze, buffers, costs off, timing off)
select count(*) from public.parties p
where p.title >= 'zzzzzz' and p.title < 'zzzzz{';

\echo ''
\echo '### J. THE COMPLETE OPTION-2 SHAPE: the PATTERN operators (~>=~, ~<~)'
\echo '### against the text_pattern_ops index. I used >= and <, which are the'
\echo '### default text_ops family and so cannot use that index however'
\echo '### leakproof they are -- the operator class has to match.'
explain (analyze, buffers, costs off, timing off)
select count(*) from public.parties p
where p.title ~>=~ 'zzzzzz' and p.title ~<~ 'zzzzz{';

\echo ''
\echo '### H. CONTROL: texteq, known leakproof (gotcha 22). If this does NOT'
\echo '### sort ahead of the policy the fixture is wrong, not the finding.'
explain (analyze, buffers, costs off, timing off)
select count(*) from public.parties p where p.title = 'zzzzzz';

\echo ''
\echo '### The catalog, for comparison. It says what the planner is ALLOWED'
\echo '### to do; the plans above say what it did.'
select p.proname, p.proleakproof as leakproof,
       pg_get_function_identity_arguments(p.oid) as args
from pg_proc p
where p.proname in ('texteq','textlike','texticlike','text_lt','text_le',
                    'text_ge','text_gt','text_pattern_lt','text_pattern_ge',
                    'enum_eq','float8ge','st_dwithin')
order by p.proleakproof desc, p.proname;

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

\echo ''
\echo '==================================================================='
\echo 'PART 3 -- PEOPLE search, which is a different question entirely.'
\echo 'The profiles SELECT policy is a single is_blocked() call against the'
\echo 'row in hand -- no can_access_party, no parties re-fetch, no'
\echo 'invitations probe. So the per-row price of being behind the barrier'
\echo 'is much lower here, and an ILIKE that can never be promoted may still'
\echo 'be affordable. That is what these three measure.'
\echo '==================================================================='

reset role;
set local session_replication_role = replica;
insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        confirmation_token, recovery_token,
                        email_change_token_new, email_change)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(),
       'authenticated', 'authenticated',
       'qp' || g || '@myparty.local', crypt('x', gen_salt('bf')),
       now(), now(), now(), '', '', '', ''
from generate_series(1, :n_profiles) g;

insert into public.profiles (id, username, onboarding_completed_at)
select u.id,
       'qp_' || replace(u.id::text, '-', ''),
       now()
from auth.users u
where u.email like 'qp%@myparty.local'
on conflict (id) do update set username = excluded.username;

set local session_replication_role = origin;
analyze public.profiles;
select tests.authenticate_as(:viewer);

\echo ''
\echo '### P1. POLICY ONLY (baseline) -- what one is_blocked() per row costs'
explain (analyze, buffers, costs off, timing off)
select count(*) from public.profiles pr;

\echo ''
\echo '### P2. ILIKE on username -- the search users would actually type.'
\echo '### Expect it BEHIND the policy. The question is not whether it is'
\echo '### promoted (it will not be) but whether the total is acceptable.'
explain (analyze, buffers, costs off, timing off)
select count(*) from public.profiles pr where pr.username ilike '%zzzzzz%';

\echo ''
\echo '### P3. Prefix range on username, for the same reason as E above.'
explain (analyze, buffers, costs off, timing off)
select count(*) from public.profiles pr
where pr.username >= 'zzzzzz' and pr.username < 'zzzzz{';

\echo ''
\echo '### P4. The profiles SELECT policy, printed. If this ever grows past'
\echo '### one is_blocked() call the numbers above stop being representative.'
select pg_get_expr(polqual, polrelid) as profiles_select_policy
from pg_policy
where polrelid = 'public.profiles'::regclass and polcmd = 'r';

rollback;
SQL

echo
echo "Read the Filter: line of each plan -- the printed order is the execution"
echo "order. Leakproof terms sort ahead of the policy; the rest sort behind it."
