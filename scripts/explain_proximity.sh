#!/usr/bin/env bash
# Phase 7b deliverable: the query plans for both spatial queries, with proof
# that the GiST indexes are actually being used.
#
# ############################################################################
# # THIS IS NOT AN ACCEPTANCE CHECK FOR ANY RLS CHANGE. DO NOT USE IT AS ONE. #
# ############################################################################
#
# Every EXPLAIN below runs as `postgres`, so row security is bypassed
# entirely. That is CORRECT for what this script measures -- the proximity
# notification engine is SECURITY DEFINER (enqueue_nearby_party_notifications,
# prosecdef = t) and genuinely runs with no policy in its path, so measuring it
# through RLS would measure a query the engine never issues. Do not "fix" this
# by authenticating; that would be the same error in reverse.
#
# The trap is what follows from it. Query 2 prints
#
#   Index Scan using parties_location on parties p
#     Index Cond: ((location && _st_expand(<point>, 5000)) AND (... 500))
#
# and prints it IDENTICALLY whatever the `parties` SELECT policy says --
# including when that policy has just been rewritten, and including when the
# rewrite achieved nothing. Phase 12's brief named this script as the
# structural acceptance criterion for a policy rewrite (§7.3); following that
# would have certified a no-op as a success, because the line it demanded was
# already there before the migration.
#
# The rule: anything claiming to measure an RLS effect must run through
# tests.authenticate_as. scripts/loadtest_map_query.sh and
# scripts/explain_policy_pushdown.sh both do. This one deliberately does not.
#
# Why this is a script and not a pgTAP assertion.
#
# `supabase db reset` leaves 22 parties and zero devices. At that size a
# sequential scan IS the right plan, and any EXPLAIN printed from the seeded
# database would show one -- telling you nothing about whether the index works,
# only that the table is small. Index usage is a claim about behaviour at scale,
# so this script generates scale.
#
# Everything happens in ONE psql session inside a transaction that ends in
# ROLLBACK. The synthetic users, devices and parties never commit, and nothing
# here touches the seeded fixtures the pgTAP suite depends on.
#
# THE FINDING THIS EXISTS TO SHOW
#
# A per-user radius column cannot drive a GiST index scan on its own. The
# CONTROL query below is the same question as query 1 with only the
# `pr.notify_radius_meters` term -- and the planner demotes the spatial
# predicate to a filter and seq-scans. Queries 1 and 2 add a constant 5000m
# term (the CHECK-enforced cap on profiles.notify_radius_meters) purely so
# PostGIS has a constant to expand the search box by. That is why every spatial
# predicate in 20260817073509_nearby_notification_engine.sql is written twice,
# and why neither term may be "simplified" away.
#
# Usage:
#   supabase start
#   supabase db reset
#   bash scripts/explain_proximity.sh [N_USERS] [N_PARTIES]

set -euo pipefail

DB_CONTAINER="supabase_db_MyParty"
N_USERS="${1:-20000}"
N_PARTIES="${2:-5000}"

# Syntagma, the centre of seed.sql's Athens cluster. Both queries are asked
# about this point so the two plans are directly comparable.
LON="23.7351"
LAT="37.9758"

if ! docker exec "$DB_CONTAINER" true 2>/dev/null; then
  echo "error: $DB_CONTAINER is not running. Run 'supabase start' first." >&2
  exit 1
fi

echo "Generating $N_USERS users/devices and $N_PARTIES parties (rolled back at the end)..."

docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -v n_users="$N_USERS" -v n_parties="$N_PARTIES" -v lon="$LON" -v lat="$LAT" <<'SQL'
\set QUIET on
\timing off
begin;

-- ------------------------------------------------------------------
-- Synthetic population, scattered over roughly Attica (~0.5 deg box,
-- ~50km across). auth.users first: profiles.id is a bare FK to it and
-- handle_new_user (20260813084353) creates the profiles row.
--
-- The movement trigger fires on every device insert, which is itself a
-- useful smoke test at this volume -- but it would dominate the runtime
-- and pollute notification_jobs before the plans are taken. Disabled for
-- the load, re-enabled before the EXPLAINs. (session_replication_role is
-- the standard bulk-load lever; it is reset inside the same transaction.)
-- ------------------------------------------------------------------
set local session_replication_role = replica;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at,
                        confirmation_token, recovery_token,
                        email_change_token_new, email_change)
select '00000000-0000-0000-0000-000000000000',
       gen_random_uuid(), 'authenticated', 'authenticated',
       'bench' || g || '@myparty.local', '',
       now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(),
       '', '', '', ''
from generate_series(1, :n_users) g;

-- session_replication_role = replica also suppressed handle_new_user, so
-- the profiles rows have to be created here rather than by the trigger.
create temp table bench_users on commit drop as
select id, 'bench_' || replace(id::text, '-', '') as username
from auth.users where email like 'bench%@myparty.local';

insert into public.profiles (id, username, location_consent, push_consent,
                             notify_nearby, notify_radius_meters)
select b.id,
       b.username,
       true, true, true,
       -- A spread of radii, all inside the 100..5000 CHECK. The spread is the
       -- point: one value would let the planner treat the column as constant.
       100 + (abs(hashtext(b.id::text)) % 4900)
from bench_users b;

-- round_location and last_location_at are applied inline, because
-- session_replication_role = replica also suppressed the BEFORE trigger
-- that normally does both. That is not cosmetic: user_devices_location_
-- timestamped rejects a location with no timestamp outright, and an
-- UNROUNDED population would give the partial GiST index a different key
-- distribution than production ever has.
insert into public.user_devices (user_id, push_token, platform,
                                 last_location, last_location_at)
select b.id, 'bench-' || b.id, 'ios',
       public.round_location(
         st_setsrid(st_makepoint(:lon + (random() - 0.5) * 0.5,
                                 :lat + (random() - 0.5) * 0.5), 4326)::geography),
       now()
from bench_users b;

insert into public.parties (host_id, title, location, starts_at, is_private, status)
select (select id from bench_users limit 1),
       'Bench Party ' || g,
       st_setsrid(st_makepoint(:lon + (random() - 0.5) * 0.5,
                               :lat + (random() - 0.5) * 0.5), 4326)::geography,
       now() + (g % 200) * interval '1 hour', false, 'published'
from generate_series(1, :n_parties) g;

-- A backlog of already-delivered jobs, so the daily-cap correlated subquery
-- is planned against a table that has rows in it. Against an empty
-- notification_jobs the planner picks a seq scan (correctly -- zero pages
-- beats an index probe) and the plan says nothing about how the cap behaves
-- once the product is live.
insert into public.notification_jobs (user_id, party_id, kind, expires_at,
                                      status, created_at)
select b.id,
       (select id from public.parties where status = 'published' limit 1),
       'nearby_party',
       now() + interval '1 day',
       'sent',
       now() - (abs(hashtext(b.id::text)) % 72) * interval '1 hour'
from bench_users b
cross join generate_series(1, 3);

set local session_replication_role = origin;

analyze public.notification_jobs;
analyze public.user_devices;
analyze public.parties;
analyze public.profiles;
analyze public.notification_jobs;

\set QUIET off

\echo ''
\echo '=== Row counts these plans were produced against ==========================='
select
  (select count(*) from public.user_devices where last_location is not null)
    as devices_with_location,
  (select count(*) from public.parties where status = 'published' and not is_private)
    as public_parties;

\echo ''
\echo '=== QUERY 1: party published -> which users are near THIS party? ==========='
\echo '--- expect: Index Scan using user_devices_last_location_gist'
explain (analyze, buffers, costs off, timing off)
select distinct d.user_id
from public.user_devices d
join public.profiles pr on pr.id = d.user_id
where d.last_location is not null
  and public.st_dwithin(d.last_location, st_point(:lon, :lat)::geography, 5000)
  and public.st_dwithin(d.last_location, st_point(:lon, :lat)::geography, pr.notify_radius_meters)
  and public.wants_nearby_notifications(pr.id);

\echo ''
\echo '=== QUERY 2: device moved -> which parties are near THIS user? ============='
\echo '--- expect: Index Scan using parties_location'
explain (analyze, buffers, costs off, timing off)
select p.id
from public.parties p
where p.status = 'published'
  and not p.is_private
  and p.starts_at > now()
  and public.st_dwithin(p.location, st_point(:lon, :lat)::geography, 5000)
  and public.st_dwithin(p.location, st_point(:lon, :lat)::geography, 500);

\echo ''
\echo '=== CONTROL: query 1 with ONLY the per-user radius (no constant term) ======'
\echo '--- expect: Seq Scan -- spatial predicate demoted to a filter.'
\echo '--- This is what the engine would do if the 5000m term were simplified away.'
explain (analyze, buffers, costs off, timing off)
select distinct d.user_id
from public.user_devices d
join public.profiles pr on pr.id = d.user_id
where d.last_location is not null
  and public.st_dwithin(d.last_location, st_point(:lon, :lat)::geography, pr.notify_radius_meters)
  and public.wants_nearby_notifications(pr.id);

\echo ''
\echo '=== END TO END: the enqueue candidate set, daily cap subquery and all ======'
explain (analyze, buffers, costs off, timing off)
with candidates as (
  select distinct d.user_id
  from public.user_devices d
  join public.profiles pr on pr.id = d.user_id
  where d.last_location is not null
    and public.st_dwithin(d.last_location, st_point(:lon, :lat)::geography, 5000)
    and public.st_dwithin(d.last_location, st_point(:lon, :lat)::geography, pr.notify_radius_meters)
    and public.wants_nearby_notifications(pr.id)
    and (
      select count(*) from public.notification_jobs j
      where j.user_id = pr.id
        and j.created_at >= date_trunc('day', now() at time zone pr.notification_tz)
                            at time zone pr.notification_tz
    ) < pr.notify_daily_cap
)
select count(*) from candidates;

\echo ''
\echo '=== Index usage, counted independently of the plan text ===================='
\echo '--- pg_stat_get_xact_numscans is transaction-local, so these are scans made'
\echo '--- by the EXPLAINs above and nothing else. pg_stat_user_indexes would NOT'
\echo '--- work here: its counters are not visible until the transaction ends, and'
\echo '--- this one rolls back.'
select relname as index_name,
       pg_stat_get_xact_numscans(oid) as scans_this_transaction
from pg_class
where relname in ('user_devices_last_location_gist', 'parties_location')
order by relname;

rollback;

\echo ''
\echo 'Rolled back -- no synthetic rows were committed.'
SQL
