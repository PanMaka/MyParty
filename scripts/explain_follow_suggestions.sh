#!/usr/bin/env bash
# Phase 48: what does get_follow_suggestions cost at realistic scale, and which
# indexes does it need?
#
# Seeded data cannot answer that (ten accounts, ~30 edges), so this generates a
# population in ONE transaction that ends in ROLLBACK, the same way
# explain_profile_stats.sh does. Nothing commits; the seeded fixtures the pgTAP
# suite depends on are untouched.
#
# THE GRAPH is skewed, because a uniform one flatters friends-of-friends:
#   * who gets followed: followee rank ~ N * random()^3, so a few hundred
#     accounts hold most of the follower edges (the Popular tier's subject);
#   * how many each user follows: 90% follow 10-50, 9% 50-300, 1% 300-2000.
#     The 1% matters: friends-of-friends fans out through the accounts I
#     follow, and an account following 2000 people contributes 2000 rows.
#
# FIVE VIEWERS, each a fresh account with an exact following count:
#   v0      follows nobody             -> all Popular
#   v5      follows 5  (skewed pick)
#   v50     follows 50 (skewed pick)
#   v500    follows 500 (skewed pick)
#   vworst  follows the 200 accounts with the MOST followings, the worst case
#           for the two-hop fan-out
#
# Each viewer is timed as `authenticated` with its own JWT claims, page 1 and
# page 3 (the walk to page 3 is not timed), p50/p95 over ITERATIONS calls. The
# function is SECURITY DEFINER, so RLS is not what is being measured here --
# the body is. Then the same again with a candidate index for the Popular tier,
# created inside the transaction, so the delta is the argument for keeping it
# or not.
#
# RESULT (2026-10-22, 20k users, ~1.02M follows, 30 iterations, page 1):
#
#   viewer   following  two-hop rows   p50     p95
#   v0           0            0        9.9ms  13.0ms
#   v5           5          259       10.3ms  11.3ms
#   v50         50        1,648       12.7ms  14.6ms
#   v500       500       20,937       38.5ms  42.7ms
#   vworst     200      204,369      117.0ms 129.0ms
#
# Page 3 is within noise of page 1: keyset re-ranks on every call, so a deeper
# page costs the same. Three shapes of the body were measured and rejected on
# the way there (each is recorded where it lives in the migration):
#   * is_blocked per candidate: on a seq scan of profiles, 614ms for v0;
#   * mutual names chosen inside the aggregate: a 197k-row sort to disk;
#   * names as a join or plain EXISTS: hashed each candidate's follower list,
#     +30ms on page 1 for v5.
# The Popular partial index bought nothing measurable at this size (the v0
# floor is two ~4ms passes over profiles), and an index on follower_count would
# cost a HOT update on every follow, so it is NOT shipped (docs/backlog.md).
#
# Usage:
#   supabase start
#   supabase db reset
#   bash scripts/explain_follow_suggestions.sh [N_USERS] [ITERATIONS]

set -euo pipefail

DB_CONTAINER="supabase_db_MyParty"
N_USERS="${1:-20000}"
ITERATIONS="${2:-30}"

if ! docker exec "$DB_CONTAINER" true 2>/dev/null; then
  echo "error: $DB_CONTAINER is not running. Run 'supabase start' first." >&2
  exit 1
fi

echo "Generating $N_USERS users and a skewed follow graph (rolled back at the end)..."

docker exec -i "$DB_CONTAINER" psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
  -v n_users="$N_USERS" -v iters="$ITERATIONS" <<'SQL'
\set QUIET on
\timing off
begin;

-- Triggers off for the bulk load (handle_new_user, the follow counters): the
-- counters are computed once below instead of 1M times.
set local session_replication_role = replica;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at,
                        confirmation_token, recovery_token,
                        email_change_token_new, email_change)
select '00000000-0000-0000-0000-000000000000',
       gen_random_uuid(), 'authenticated', 'authenticated',
       'sugg' || g || '@myparty.local', '',
       now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(),
       '', '', '', ''
from generate_series(1, :n_users + 5) g;

create temp table sugg_users on commit drop as
select id, row_number() over (order by id) as rn
from auth.users where email like 'sugg%@myparty.local';

insert into public.profiles (id, username, onboarding_completed_at)
select u.id, 'sugg_' || u.rn, now()
from sugg_users u;

-- The last five rows are the viewers; the population is the rest.
create temp table sugg_viewers on commit drop as
select id, (array['v0','v5','v50','v500','vworst'])[rn - :n_users] as label
from sugg_users where rn > :n_users;

create temp table sugg_pop on commit drop as
select id, rn from sugg_users where rn <= :n_users;
create index on sugg_pop (rn);

-- ~2% opted out and ~1% pending deletion, so those filters do real work.
update public.profiles p set suggest_account = false
from sugg_pop s where s.id = p.id and s.rn % 50 = 0;
update public.profiles p set deleted_at = now()
from sugg_pop s where s.id = p.id and s.rn % 100 = 7;

-- Following counts, then skewed followees. Duplicates and self-edges dropped.
--
-- The target row number is materialised FIRST and joined second. Joining on
-- the random() expression directly makes it a join qual no index or hash can
-- serve, and the planner falls back to a nested loop over every pair -- a
-- generation that ran past ten minutes at 20k users.
create temp table sugg_edges on commit drop as
select s.id as src,
       1 + floor(:n_users * power(random() + g * 0, 3))::int as trn,
       now() - random() * interval '365 days' as created_at
from sugg_pop s
cross join lateral (
  -- `+ 0 * s.rn` makes the lateral correlated. Without it Postgres evaluates
  -- the subquery ONCE and every user follows the same number of accounts --
  -- which is what the first run of this script did (everyone followed 33).
  select case
           when random() + 0 * s.rn < 0.90 then 10 + floor(random() * 41)::int
           when random() < 0.90 then 50 + floor(random() * 251)::int
           else 300 + floor(random() * 1701)::int
         end as k
) kk
cross join lateral generate_series(1, kk.k) g;

insert into public.follows (follower_id, followee_id, created_at)
select distinct on (e.src, t.id) e.src, t.id, e.created_at
from sugg_edges e
join sugg_pop t on t.rn = e.trn
where t.id <> e.src;

-- Viewers. v5/v50/v500 pick with the same skew; vworst takes the 200 heaviest
-- followers.
insert into public.follows (follower_id, followee_id)
select distinct v.id, t.id
from sugg_viewers v
cross join lateral generate_series(1, case v.label when 'v5' then 5 when 'v50' then 50 when 'v500' then 500 else 0 end * 2) g
join sugg_pop t on t.rn = 1 + floor(:n_users * power(random() + g * 0, 3))::int
on conflict do nothing;

-- Trim the skewed picks to the exact count (the *2 above covers duplicates).
delete from public.follows f
using (
  select f2.follower_id, f2.followee_id,
         row_number() over (partition by f2.follower_id order by f2.followee_id) as n,
         v.label
  from public.follows f2 join sugg_viewers v on v.id = f2.follower_id
) x
where f.follower_id = x.follower_id and f.followee_id = x.followee_id
  and x.n > case x.label when 'v5' then 5 when 'v50' then 50 when 'v500' then 500 else 0 end;

insert into public.follows (follower_id, followee_id)
select v.id, h.follower_id
from sugg_viewers v,
     (select follower_id from public.follows f join sugg_pop p on p.id = f.follower_id
      group by follower_id order by count(*) desc limit 200) h
where v.label = 'vworst';

-- A few followers for each viewer, so the follows_you tier is not empty.
insert into public.follows (follower_id, followee_id)
select p.id, v.id
from sugg_viewers v join sugg_pop p on p.rn % 997 = 1
on conflict do nothing;

-- Counters, once.
update public.profiles p set
  follower_count  = coalesce((select count(*) from public.follows f where f.followee_id = p.id), 0),
  following_count = coalesce((select count(*) from public.follows f where f.follower_id = p.id), 0)
where p.id in (select id from sugg_users);

set local session_replication_role = origin;

analyze public.profiles;
analyze public.follows;

grant select on sugg_viewers to authenticated;

-- p50/p95 of page p_page for one viewer, as authenticated. Earlier pages are
-- walked untimed so page 3 is measured with a real cursor.
create function pg_temp.bench(p_viewer uuid, p_page int, p_iters int)
returns table (p50_ms numeric, p95_ms numeric, rows_on_page int)
language plpgsql as $$
declare
  t smallint; r bigint; i uuid; rec record; n int;
  started timestamptz; samples numeric[] := '{}';
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_viewer, 'role', 'authenticated')::text, true);
  for it in 1 .. p_iters loop
    t := null; r := null; i := null;
    for pg in 1 .. p_page - 1 loop
      for rec in select * from public.get_follow_suggestions(t, r, i, 20) loop
        t := rec.sort_tier; r := rec.sort_rank; i := rec.user_id;
      end loop;
    end loop;
    started := clock_timestamp();
    select count(*) into n from public.get_follow_suggestions(t, r, i, 20);
    samples := samples || (extract(epoch from clock_timestamp() - started) * 1000)::numeric;
  end loop;
  return query
  select round(percentile_cont(0.5) within group (order by x)::numeric, 2),
         round(percentile_cont(0.95) within group (order by x)::numeric, 2),
         n
  from unnest(samples) x;
end;
$$;
grant execute on function pg_temp.bench(uuid, int, int) to authenticated;

\set QUIET off

\echo ''
\echo '=== Scale ==================================================================='
select
  (select count(*) from public.profiles) as profiles,
  (select count(*) from public.follows)  as follows,
  (select round(avg(following_count), 1) from public.profiles p join sugg_pop s on s.id = p.id) as avg_following,
  (select max(following_count) from public.profiles) as max_following,
  (select max(follower_count) from public.profiles) as max_followers;

\echo ''
\echo '=== Viewers: following count and two-hop fan-out (rows friends-of-friends aggregates)'
select v.label,
       (select count(*) from public.follows f where f.follower_id = v.id) as following,
       (select count(*) from public.follows f1 join public.follows f2 on f2.follower_id = f1.followee_id
        where f1.follower_id = v.id) as two_hop_rows
from sugg_viewers v order by v.label;

-- The plan of the REAL function, through auto_explain with nested statements:
-- a hand-copied body would drift from the migration. That is why this script
-- connects as supabase_admin -- LOAD 'auto_explain' needs a superuser locally.
-- The function is definer and still runs as its owner, so the plan is the one
-- a client call gets. Two viewers: v0 (Popular only) and vworst (the widest
-- two-hop fan-out).
load 'auto_explain';
set auto_explain.log_min_duration = 0;
set auto_explain.log_nested_statements = on;
set auto_explain.log_analyze = on;
set auto_explain.log_buffers = on;
set auto_explain.log_timing = on;
set auto_explain.log_level = notice;
set client_min_messages = notice;

\echo ''
\echo '=== PLAN: get_follow_suggestions for v0 and vworst ========================='
select set_config('request.jwt.claims',
                  json_build_object('sub', id, 'role', 'authenticated')::text, true)
from sugg_viewers where label = 'v0';
select count(*) from public.get_follow_suggestions();
select set_config('request.jwt.claims',
                  json_build_object('sub', id, 'role', 'authenticated')::text, true)
from sugg_viewers where label = 'vworst';
select count(*) from public.get_follow_suggestions();

set auto_explain.log_min_duration = -1;
set client_min_messages = warning;

set local role authenticated;

\echo ''
\echo '=== AS SHIPPED: p50/p95 ms, page 1 and page 3 (20 per page) ================'
select v.label, pg.page, b.*
from sugg_viewers v
cross join (values (1), (3)) pg(page)
cross join lateral pg_temp.bench(v.id, pg.page, :iters) b
order by v.label, pg.page;

reset role;

\echo ''
\echo '=== CANDIDATE: partial index for the Popular tier ==========================='
create index sugg_popular_candidate_idx on public.profiles (follower_count desc, id)
  where is_discoverable and suggest_account and onboarding_completed_at is not null;
analyze public.profiles;

set local role authenticated;
select v.label, pg.page, b.*
from sugg_viewers v
cross join (values (1), (3)) pg(page)
cross join lateral pg_temp.bench(v.id, pg.page, :iters) b
order by v.label, pg.page;
reset role;

rollback;
SQL

echo ""
echo "Done. Nothing was committed."
