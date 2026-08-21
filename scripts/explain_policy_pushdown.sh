#!/usr/bin/env bash
# Phase 12: can ANY RLS policy on `parties` let the 5km map query reach the
# GiST index on `parties.location`?
#
# WHY THIS SCRIPT EXISTS
#
# docs/phase-12-parties-policy-rewrite.md §7 sets a structural acceptance
# criterion for the policy rewrite: the 5km plan must show
#
#   ->  Bitmap Index Scan on parties_location
#         Index Cond: (location && _st_expand(<point>, 5000))
#
# The rewrite made the policy ~5x cheaper per row (995ms -> 199ms p50 at 10k
# parties) and did NOT produce that plan. A faster seq scan is not the fix, so
# the question is whether the criterion is reachable at all by making the
# policy cheaper -- or whether it is foreclosed by something the policy cannot
# influence.
#
# THE FINDING
#
# It is foreclosed, and the cause is leakproofness of the OPERATORS, not the
# cost of the policy. An RLS qual is a security barrier: a user qual may only
# be promoted below it -- which is what becoming an Index Cond requires -- if
# the qual is leakproof. Every operator the spatial predicate is built from is
# not:
#
#   st_dwithin(geography, geography, float8, bool)  proleakproof = f
#   _st_expand(geography, float8)                   proleakproof = f
#   geography_overlaps(geography, geography)   -- the && operator --  f
#
# So `st_dwithin` can never be evaluated ahead of an RLS qual, and an index
# condition is by definition evaluated first. This holds no matter how cheap
# or how leakproof the POLICY is, which is what variants B and C below prove:
# a policy that is nothing but a leakproof column reference, and a policy that
# is the literal `true`, both still seq-scan.
#
# That is the argument for keeping `parties_location`, and it is a different
# argument from the one in the Phase 10 audit. The index is not unreachable
# because the policy is expensive; it is unreachable because RLS is on at all.
# Only the RLS-bypassed control reaches it -- which is exactly the plan the
# index was built for, and exactly the plan the app cannot have while the
# visibility rule lives in a row policy.
#
# Everything runs in ONE psql session inside a transaction that ends in
# ROLLBACK: the synthetic parties never commit, the real policy is restored,
# and the seeded fixtures the pgTAP suite depends on are untouched.
#
# Usage:
#   supabase start && supabase db reset
#   bash scripts/explain_policy_pushdown.sh [N_PARTIES] [N_USERS]

set -euo pipefail

DB_CONTAINER="supabase_db_MyParty"
N_PARTIES="${1:-10000}"
N_USERS="${2:-5000}"

# Syntagma, the same point loadtest_map_query.sh and explain_proximity.sh ask
# about, so all three scripts' plans are directly comparable.
LON="23.7351"
LAT="37.9758"

if ! docker exec "$DB_CONTAINER" true 2>/dev/null; then
  echo "error: $DB_CONTAINER is not running. Run 'supabase start' first." >&2
  exit 1
fi

echo "Generating $N_USERS users and $N_PARTIES parties (rolled back at the end)..."
echo ""

docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres \
  -v ON_ERROR_STOP=1 \
  -v lon="$LON" -v lat="$LAT" \
  -v n_parties="$N_PARTIES" -v n_users="$N_USERS" <<'SQL'
begin;

-- Triggers off for the bulk load, exactly as loadtest_map_query.sh does it:
-- handle_new_user and the proximity fan-out would otherwise dominate the
-- generation time and have nothing to do with what is being measured.
set local session_replication_role = replica;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        confirmation_token, recovery_token,
                        email_change_token_new, email_change)
select '00000000-0000-0000-0000-000000000000',
       gen_random_uuid(), 'authenticated', 'authenticated',
       'push' || g || '@myparty.local', crypt('x', gen_salt('bf')),
       now(), now(), now(), '', '', '', ''
from generate_series(1, :n_users) g;

create temp table push_users on commit drop as
select id, row_number() over (order by id) as n
from auth.users where email like 'push%@myparty.local';
create index on push_users (n);

insert into public.profiles (id, username, map_visibility)
select u.id, 'push_' || replace(u.id::text, '-', ''),
       (case when u.n % 20 = 0 then 'private'
             when u.n % 20 < 4 then 'followers'
             else 'public' end)::public.map_visibility
from push_users u;

insert into public.parties (host_id, title, location, starts_at, ends_at,
                            is_private, is_sponsored, party_tier, status)
select (select id from push_users where n = 1 + (g % :n_users)),
       'Push Party ' || g,
       st_setsrid(st_makepoint(:lon + (random() - 0.5) * 0.5,
                               :lat + (random() - 0.5) * 0.5), 4326)::geography,
       now() + (g % 300) * interval '1 hour',
       now() + (g % 300) * interval '1 hour' + interval '6 hours',
       (g % 7 = 0), (g % 11 = 0),
       (case when g % 10 = 0 then 'mega'
             when g % 5 = 0 then 'large'
             else 'standard' end),
       'published'
from generate_series(1, :n_parties) g;

set local session_replication_role = origin;
analyze public.parties;
analyze public.profiles;

create temp table push_viewer on commit drop as
select id from push_users where n = 1;

-- The shipped RPC body, reconstructed verbatim and declared STABLE so the
-- planner inlines it and EXPLAIN shows a real plan instead of one "Function
-- Scan" line. Same trick, and same justification, as loadtest_map_query.sh:
-- pg_get_function_arguments/prosrc means this cannot drift from the real one.
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

\echo ''
\echo '=== Leakproofness of every operator the spatial predicate is built from ==='
\echo '--- This is the whole finding. pg_proc.proleakproof says what the planner'
\echo '--- is PERMITTED to reorder; nothing here is permitted to cross a policy.'
select p.proname, p.proleakproof,
       pg_get_function_identity_arguments(p.oid) as args
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where (p.proname in ('st_dwithin', '_st_expand', 'geography_overlaps')
       and pg_get_function_identity_arguments(p.oid) like '%geog%')
   or p.proname in ('is_blocked', 'can_access_party')
order by p.proleakproof, p.proname;

\echo ''
\echo '=== A: the policy as this phase ships it =================================='
\echo '--- expect: Seq Scan. 5x cheaper per row than before the hoist, because'
\echo '--- most rows settle on `not is_private` with no function call -- but the'
\echo '--- spatial predicate is still stuck behind the barrier.'
select tests.authenticate_as((select id from push_viewer));
explain (analyze, buffers, costs off, timing off)
  select * from public.map_query_stable(:lon, :lat, 5000);

\echo ''
\echo '=== B: a policy that is ONE leakproof column reference ====================='
\echo '--- `using (not is_private)`. Nothing cheaper is expressible while still'
\echo '--- filtering anything, and every operator in it IS leakproof. If policy'
\echo '--- cost were the obstacle, the index would appear here.'
reset role;
alter policy "Parties are viewable based on privacy and invitations"
  on public.parties using (not is_private);
select tests.authenticate_as((select id from push_viewer));
explain (analyze, buffers, costs off, timing off)
  select * from public.map_query_stable(:lon, :lat, 5000);

\echo ''
\echo '=== C: a policy that is the literal `true` ================================='
\echo '--- Admits every row and evaluates nothing. Still a security barrier, and'
\echo '--- that is the only property that matters here.'
reset role;
alter policy "Parties are viewable based on privacy and invitations"
  on public.parties using (true);
select tests.authenticate_as((select id from push_viewer));
explain (analyze, buffers, costs off, timing off)
  select * from public.map_query_stable(:lon, :lat, 5000);

\echo ''
\echo '=== D: CONTROL -- the same query with RLS off ============================='
\echo '--- The plan the GiST index was built for, and the ONLY variant that'
\echo '--- reaches it. Read as postgres, which bypasses row security entirely.'
reset role;
explain (analyze, buffers, costs off, timing off)
  select * from public.map_query_stable(:lon, :lat, 5000);

\echo ''
\echo '=== Index scans, counted independently of the plan text ==================='
\echo '--- pg_stat_get_xact_numscans is transaction-local, so this counts only'
\echo '--- the four EXPLAINs above. Expect a small number: one scan, from D.'
select relname, pg_stat_get_xact_numscans(indexrelid) as scans_this_txn
from pg_stat_all_indexes
where indexrelname = 'parties_location';

rollback;
SQL

echo ""
echo "Rolled back. The real policy and the seeded fixtures are untouched."
