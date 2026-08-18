#!/usr/bin/env bash
# Phase 8 deliverable: is get_profile_stats fast enough to be an aggregate, or
# does it need denormalized counter columns?
#
# The phase prompt says "measure it -- if it's slow on seeded data, propose
# counter columns instead and tell me the tradeoff". Seeded data cannot answer
# that question: `supabase db reset` leaves 23 parties, 0 rsvps and 0 stories,
# and at that size every plan is a seq scan over zero pages and every timing is
# noise. Counting three empty tables is fast for reasons that say nothing about
# whether counting a real one would be. So this script generates the scale the
# question is actually about.
#
# Everything happens in ONE psql session inside a transaction that ends in
# ROLLBACK. The synthetic users, parties, rsvps and stories never commit, and
# nothing here touches the seeded fixtures the pgTAP suite depends on.
#
# WHAT THIS EXISTS TO SHOW
#
# public.rsvps is keyed (party_id, user_id) and, before this phase, indexed only
# on party_id. Every access pattern in Phases 0-7 asked "who is coming to THIS
# party", which that serves. get_profile_stats asks the mirror question -- "how
# many parties is THIS user going to" -- and a leading-column mismatch means no
# index can answer it: counting one person's RSVPs reads every RSVP in the
# system. public.parties had no index on host_id at all.
#
# So each of the three counts is printed twice: once as it will really run, and
# once with index scans disabled, which is exactly what the query did before
# 20260818175437 added rsvps_user_status_idx and parties_host_id_idx. The gap
# between those two numbers is the argument.
#
# Usage:
#   supabase start
#   supabase db reset
#   bash scripts/explain_profile_stats.sh [N_USERS] [N_PARTIES] [RSVPS_PER_USER]

set -euo pipefail

DB_CONTAINER="supabase_db_MyParty"
N_USERS="${1:-20000}"
N_PARTIES="${2:-5000}"
RSVPS_PER_USER="${3:-10}"

if ! docker exec "$DB_CONTAINER" true 2>/dev/null; then
  echo "error: $DB_CONTAINER is not running. Run 'supabase start' first." >&2
  exit 1
fi

echo "Generating $N_USERS users, $N_PARTIES parties, ~$((N_USERS * RSVPS_PER_USER)) rsvps (rolled back at the end)..."

docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -v n_users="$N_USERS" -v n_parties="$N_PARTIES" -v rsvps_per="$RSVPS_PER_USER" <<'SQL'
\set QUIET on
\timing off
begin;

-- ------------------------------------------------------------------
-- Synthetic population. auth.users first: profiles.id is a bare FK to it.
--
-- session_replication_role = replica for the bulk load, the same lever
-- explain_proximity.sh uses. Here it suppresses handle_new_user (so the
-- profiles rows are created explicitly below) and, more importantly, the
-- rsvp/story counter triggers, which would otherwise dominate the runtime
-- of a 200k-row insert and measure trigger throughput rather than the plans.
-- ------------------------------------------------------------------
set local session_replication_role = replica;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at,
                        confirmation_token, recovery_token,
                        email_change_token_new, email_change)
select '00000000-0000-0000-0000-000000000000',
       gen_random_uuid(), 'authenticated', 'authenticated',
       'stats' || g || '@myparty.local', '',
       now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(),
       '', '', '', ''
from generate_series(1, :n_users) g;

create temp table stats_users on commit drop as
select id, row_number() over (order by id) as rn
from auth.users where email like 'stats%@myparty.local';

insert into public.profiles (id, username)
select u.id, 'stats_' || replace(u.id::text, '-', '')
from stats_users u;

-- Parties spread over the first 500 users, so "parties hosted by one user" is
-- a realistic slice rather than one user owning everything. A quarter are
-- private: that is the slice a stranger's invoker-rights count must NOT see,
-- and it keeps the RLS-filtered plan honest.
insert into public.parties (host_id, title, location, starts_at, is_private, status)
select (select id from stats_users where rn = 1 + (g % 500)),
       'Stats Party ' || g,
       st_setsrid(st_makepoint(23.7351 + (random() - 0.5) * 0.5,
                               37.9758 + (random() - 0.5) * 0.5), 4326)::geography,
       -- Spread across the current year and the previous one, so the
       -- date_trunc('year', now()) predicate in get_profile_stats actually
       -- discards rows. Measured against a table where the filter is always
       -- true, the plan would understate the work.
       date_trunc('year', now()) - interval '6 months' + (g % 500) * interval '1 day',
       (g % 4 = 0),
       'published'
from generate_series(1, :n_parties) g;

create temp table stats_parties on commit drop as
select id, row_number() over (order by id) as rn from public.parties
where title like 'Stats Party %';

-- The big table, and the reason this script exists. Every user RSVPs to
-- rsvps_per parties; roughly half are 'going'.
insert into public.rsvps (party_id, user_id, status)
select p.id, u.id,
       case when (u.rn + g) % 2 = 0 then 'going' else 'interested' end::public.rsvp_status
from stats_users u
cross join generate_series(1, :rsvps_per) g
join stats_parties p on p.rn = 1 + ((u.rn * 7 + g * 13) % (select count(*) from stats_parties))
on conflict do nothing;

-- Stories, already confirmed. media_uploaded_at is set inline because the
-- normal path is the storage handshake, which no SQL-only script can drive --
-- and a story with null media_uploaded_at is invisible to the SELECT policy,
-- so an unconfirmed population would make every count zero.
insert into public.stories (party_id, author_id, media_path, content_type,
                            media_uploaded_at)
select p.id, u.id,
       'stats/' || gen_random_uuid() || '.jpg', 'image/jpeg', now()
from stats_users u
cross join generate_series(1, 3) g
join stats_parties p on p.rn = 1 + ((u.rn * 3 + g * 11) % (select count(*) from stats_parties));

set local session_replication_role = origin;

analyze public.profiles;
analyze public.parties;
analyze public.rsvps;
analyze public.stories;

-- The subject: user #1, who hosts a share of the parties and has RSVPs and
-- stories. Held in a temp table so every query below asks about the same
-- person.
create temp table stats_subject on commit drop as
select id from stats_users where rn = 1;

-- The end-to-end section switches to the authenticated role, which has no
-- privileges on a temp table created by postgres. Without this the RPC timing
-- dies on the argument expression rather than on anything being measured.
grant select on stats_subject to authenticated;

\set QUIET off

\echo ''
\echo '=== Scale these plans were produced against ================================'
select
  (select count(*) from public.profiles) as profiles,
  (select count(*) from public.parties)  as parties,
  (select count(*) from public.rsvps)    as rsvps,
  (select count(*) from public.stories)  as stories;

\echo ''
\echo '=== COUNT 1: parties_attended -- this years going RSVPs ===================='
\echo '--- expect: Index Scan / Bitmap Index Scan using rsvps_user_status_idx'
explain (analyze, buffers, costs off, timing off)
select count(*)::int
from public.rsvps r
join public.parties p on p.id = r.party_id
where r.user_id = (select id from stats_subject)
  and r.status = 'going'
  and p.starts_at >= date_trunc('year', now());

\echo ''
\echo '=== CONTROL 1: the same count with no usable index ========================='
\echo '--- expect: Seq Scan on rsvps -- this is what it did before 20260818175437.'
set local enable_indexscan = off;
set local enable_bitmapscan = off;
explain (analyze, buffers, costs off, timing off)
select count(*)::int
from public.rsvps r
join public.parties p on p.id = r.party_id
where r.user_id = (select id from stats_subject)
  and r.status = 'going'
  and p.starts_at >= date_trunc('year', now());
reset enable_indexscan;
reset enable_bitmapscan;

\echo ''
\echo '=== COUNT 2: parties_hosted ==============================================='
\echo '--- expect: Index Scan using parties_host_id_idx'
explain (analyze, buffers, costs off, timing off)
select count(*)::int
from public.parties p
where p.host_id = (select id from stats_subject)
  and p.status = 'published';

\echo ''
\echo '=== CONTROL 2: parties_hosted with no usable index ========================='
set local enable_indexscan = off;
set local enable_bitmapscan = off;
explain (analyze, buffers, costs off, timing off)
select count(*)::int
from public.parties p
where p.host_id = (select id from stats_subject)
  and p.status = 'published';
reset enable_indexscan;
reset enable_bitmapscan;

\echo ''
\echo '=== COUNT 3: stories_posted ==============================================='
\echo '--- expect: Index Scan using stories_author_created_idx (pre-existing)'
explain (analyze, buffers, costs off, timing off)
select count(*)::int
from public.stories s
where s.author_id = (select id from stats_subject)
  and s.hidden_at is null;

\echo ''
\echo '=== END TO END: the real RPC, as authenticated, with RLS applied ==========='
\echo '--- The plans above run as postgres and are therefore RLS-free. This is the'
\echo '--- number that matters: get_profile_stats is security invoker, so all three'
\echo '--- policies are evaluated inside it. Anything the aggregate saves is'
\echo '--- irrelevant if the policies dominate.'
\echo '---'
\echo '--- Do not read the RETURNED NUMBERS as smaller than the plans above and'
\echo '--- conclude something is wrong. The bulk load ran with triggers and RLS'
\echo '--- bypassed, so these synthetic users hold RSVPs on private parties they'
\echo '--- were never invited to -- rows a real user could not have created. The'
\echo '--- policies correctly drop them here. It is the TIMING that is being'
\echo '--- measured, not the counts.'
select set_config('request.jwt.claims',
                  json_build_object('sub', (select id from stats_subject),
                                    'role', 'authenticated')::text,
                  true);
set local role authenticated;

\timing on
select * from public.get_profile_stats((select id from stats_subject));
select * from public.get_profile_stats((select id from stats_subject));
select * from public.get_profile_stats((select id from stats_subject));
\timing off

reset role;

rollback;
SQL

echo ""
echo "Done. Nothing was committed."
