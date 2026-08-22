-- Phase 13: the leakproof spatial pre-filter on the map query.
--
-- The whole file exists for ONE property, and section 2 is it:
--
--     THE BOUNDING BOX MUST BE A PROVABLE SUPERSET OF THE CIRCLE.
--
-- A box that is not is not a slow query, it is silent data loss -- a party
-- stops existing on the map for everyone, with no error anywhere. This is not
-- hypothetical. During Phase 12's measurement a box computed as
-- 5000 / 111320 = 0.0449 deg of latitude returned 298 rows where the
-- unfiltered query returned 299: st_dwithin on GEOGRAPHY measures on the WGS84
-- spheroid, where a degree of latitude at 38N is ~110996m, so 5000m is
-- 0.04501 deg. The box was 0.00011 deg short and clipped a real party.
--
-- Section 2 asserts the property AND asserts that the naive box violates it,
-- so the assertion cannot quietly become vacuous. A test that only checked the
-- good box would still pass if somebody later replaced the derivation with a
-- constant that happened to work at one latitude.
--
-- Coverage is chosen to make the failure reachable: parties are placed at the
-- four cardinal extremes of the circle at radius -1m and radius +1m, across
-- three latitudes (0.5N, 38N, 60N) and all three real zoom tiers. A single
-- Athens centre would NOT have caught the original bug -- the clipped party has
-- to sit within metres of the box edge, and the error scales with latitude.
--
-- Personas (seed.sql): host 1111, invitee 2222, friend_not_invited 3333,
-- stranger 4444, blocked_user 5555, second_host 6666.
begin;
set search_path to public, extensions;
select plan(31);


-- ============================================================
-- 1. public.map_search_box -- the single definition of the box
--
-- The RPC and section 2's assertion both call this function, so the test
-- cannot certify a box the query does not actually use.
-- ============================================================

-- st_setsrid, because map_search_box returns 4326 (it comes back through a
-- geography cast) and a bare st_point is SRID 0.
select isnt_empty(
  $$ select 1 where st_contains(
       public.map_search_box(23.7351, 37.9758, 5000),
       st_setsrid(st_point(23.7351, 37.9758), 4326)) $$,
  'the box contains its own centre'
);

select ok(
  st_area(public.map_search_box(23.7351, 37.9758, 50000)) >
  st_area(public.map_search_box(23.7351, 37.9758, 5000)),
  'the box grows with the radius'
);

-- The latitude dependence that makes a hardcoded constant wrong. At 60N a
-- degree of longitude is roughly half the ground distance it is at the
-- equator, so the same 5km needs a much wider box in degrees.
select ok(
  (st_xmax(public.map_search_box(23.0, 60.0, 5000)) - 23.0) >
  (st_xmax(public.map_search_box(23.0, 38.0, 5000)) - 23.0) * 1.5,
  'the box is markedly wider in longitude at 60N than at 38N -- degrees per metre is not a constant'
);


-- ============================================================
-- 2. THE SUPERSET INVARIANT
--
-- Fixture: for every (centre, radius) and each of the four cardinal
-- directions, one party at radius - 1m (inside the circle) and one at
-- radius + 1m (outside it). st_project is geodesic, the same spheroid
-- st_dwithin measures on, so "1m inside" really is inside.
--
-- These are the only positions where the property can fail. A party in the
-- middle of the circle is inside any plausible box; a party far outside is
-- outside any of them. The bug lives in the last metre.
-- ============================================================

create temp table probe as
select
  row_number() over (order by c.lat, r.radius, a.az_deg, k.kind) as n,
  c.name as centre_name, c.lon as centre_lon, c.lat as centre_lat,
  r.radius, a.az_deg, k.kind,
  st_project(
    st_point(c.lon, c.lat)::geography,
    case when k.kind = 'inside' then r.radius - 1 else r.radius + 1 end,
    radians(a.az_deg)
  )::geography as loc
from (values ('equator', 23.0, 0.5),
             ('athens',  23.7351, 37.9758),
             ('north',   23.0, 60.0)) c(name, lon, lat)
cross join (values (5000.0), (50000.0), (500000.0)) r(radius)
cross join (values (0), (90), (180), (270)) a(az_deg)
cross join (values ('inside'), ('outside')) k(kind);

alter table probe add column party_id uuid;
update probe set party_id = ('bbbbbbbb-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid;

-- ends_at is set on every one of these, per gotcha 21: a party with a null
-- ends_at is on the map forever.
insert into public.parties (id, host_id, title, location, starts_at, ends_at, status)
select p.party_id,
       '11111111-1111-1111-1111-111111111111',
       'Probe ' || p.n || ' ' || p.centre_name || ' ' || p.radius || 'm ' || p.az_deg || ' ' || p.kind,
       p.loc,
       now() + interval '1 day',
       now() + interval '1 day 6 hours',
       'published'
from probe p;

-- Sanity on the fixture itself. Without these three, the invariant below could
-- pass because nothing was inside the circle, or because nothing was outside
-- it, or because no parties were created at all.
select is(
  (select count(*)::int from probe),
  72,
  'fixture: 3 centres x 3 radii x 4 cardinal directions x 2 sides = 72 probes'
);

select is(
  (select count(*)::int from probe p join public.parties pa on pa.id = p.party_id
   where st_dwithin(pa.location, st_point(p.centre_lon, p.centre_lat)::geography, p.radius)),
  36,
  'fixture: every `inside` probe really is inside its circle, and no `outside` one is'
);

select is(
  (select count(*)::int from probe p join public.parties pa on pa.id = p.party_id
   where not st_dwithin(pa.location, st_point(p.centre_lon, p.centre_lat)::geography, p.radius)),
  36,
  'fixture: every `outside` probe really is outside its circle'
);

-- ---------- the assertion this whole phase rests on ----------
select is_empty(
  $$ select p.n, p.centre_name, p.radius, p.az_deg
     from probe p
     join public.parties pa on pa.id = p.party_id
     where st_dwithin(pa.location, st_point(p.centre_lon, p.centre_lat)::geography, p.radius)
       and not (
         pa.bbox_lat between st_ymin(public.map_search_box(p.centre_lon, p.centre_lat, p.radius))
                         and st_ymax(public.map_search_box(p.centre_lon, p.centre_lat, p.radius))
         and pa.bbox_lon between st_xmin(public.map_search_box(p.centre_lon, p.centre_lat, p.radius))
                             and st_xmax(public.map_search_box(p.centre_lon, p.centre_lat, p.radius))
       ) $$,
  'THE INVARIANT: the box never excludes a party the circle admits'
);

-- ---------- and the proof that assertion has teeth ----------
-- The naive box, exactly as it was written the first time. If this ever stops
-- finding violations, either the fixture stopped reaching the box edge or
-- somebody "simplified" the derivation -- and the assertion above would then be
-- passing for no reason.
select isnt_empty(
  $$ select p.n, p.centre_name, p.radius, p.az_deg
     from probe p
     join public.parties pa on pa.id = p.party_id
     where st_dwithin(pa.location, st_point(p.centre_lon, p.centre_lat)::geography, p.radius)
       and not (
         pa.bbox_lat between p.centre_lat - p.radius / 111320.0
                         and p.centre_lat + p.radius / 111320.0
         and pa.bbox_lon between p.centre_lon - p.radius / (111320.0 * cos(radians(p.centre_lat)))
                             and p.centre_lon + p.radius / (111320.0 * cos(radians(p.centre_lat)))
       ) $$,
  'control: the naive degrees-per-metre box DOES drop parties -- the 298-vs-299 bug, reproduced, so the invariant above is not vacuous'
);

-- The box is a SUPERSET, not the circle. If it were exactly the circle the
-- invariant would hold trivially and st_dwithin would be redundant -- which is
-- the reading that leads somebody to delete it.
select isnt_empty(
  $$ select p.n from probe p
     join public.parties pa on pa.id = p.party_id
     where not st_dwithin(pa.location, st_point(p.centre_lon, p.centre_lat)::geography, p.radius)
       and pa.bbox_lat between st_ymin(public.map_search_box(p.centre_lon, p.centre_lat, p.radius))
                           and st_ymax(public.map_search_box(p.centre_lon, p.centre_lat, p.radius))
       and pa.bbox_lon between st_xmin(public.map_search_box(p.centre_lon, p.centre_lat, p.radius))
                           and st_xmax(public.map_search_box(p.centre_lon, p.centre_lat, p.radius)) $$,
  'the box is a STRICT superset: it admits parties the circle rejects, which is why st_dwithin must stay'
);


-- ============================================================
-- 3. End to end: the RPC with the box returns exactly what it returned without
--
-- The reference function is built by removing the box terms from the SHIPPED
-- function's own prosrc, so it cannot drift from it the way a hand-copied body
-- would. The DO block raises if the substitution matches nothing or leaves a
-- bbox reference behind -- otherwise a regex that silently stopped matching
-- would make every comparison below a comparison of the RPC with itself.
-- ============================================================

do $$
declare r record; v_src text;
begin
  select pg_get_function_arguments(p.oid) as args,
         pg_get_function_result(p.oid)    as res,
         p.prosrc                         as src
  into r
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'get_parties_near_user';

  v_src := regexp_replace(
    r.src,
    'p\.bbox_(lat|lon) [<>]= \(select st_[a-z]+\(public\.map_search_box\(map_center_lon, map_center_lat, radius_meters\)\)\)',
    'true', 'g');

  if v_src = r.src then
    raise exception
      'the bbox substitution matched nothing: the reference would be identical to the RPC and every comparison in section 3 would be vacuous';
  end if;
  -- `p.bbox_`, not `bbox`: the RPC body mentions bbox_lat/bbox_lon in a comment
  -- explaining that lat/lon come from `location` and not from them, and a bare
  -- '%bbox%' check fires on that comment instead of on a live reference.
  if v_src like '%p.bbox\_%' then
    raise exception 'the bbox substitution left a live bbox reference behind';
  end if;

  execute format(
    'create function public.map_query_unboxed(%s) returns %s language sql '
    'set search_path to ''public'', ''extensions'' as %L',
    r.args, r.res, v_src);
end $$;

select lives_ok(
  $$ select count(*) from public.map_query_unboxed(23.7351, 37.9758, 5000) $$,
  'the unboxed reference function is callable (gotcha 15: a function that applied is not a function that runs)'
);

-- Three viewers with materially different visibility, at all three tiers.
-- Both directions each: a boxed query that returned nothing would satisfy
-- "admits nothing extra" trivially.
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');

select is_empty(
  $$ select party_id from public.get_parties_near_user(23.7351, 37.9758, 5000)
     except
     select party_id from public.map_query_unboxed(23.7351, 37.9758, 5000) $$,
  'host 5km: the box admits nothing the unboxed query does not'
);
select is_empty(
  $$ select party_id from public.map_query_unboxed(23.7351, 37.9758, 5000)
     except
     select party_id from public.get_parties_near_user(23.7351, 37.9758, 5000) $$,
  'host 5km: and drops nothing it returned -- the 298-vs-299 assertion, end to end'
);
select isnt_empty(
  $$ select party_id from public.get_parties_near_user(23.7351, 37.9758, 5000) $$,
  'control: the host actually sees parties at 5km, so the two above are not comparing empty sets'
);

select is_empty(
  $$ select party_id from public.map_query_unboxed(23.7351, 37.9758, 50000)
     except
     select party_id from public.get_parties_near_user(23.7351, 37.9758, 50000) $$,
  'host 50km: the box drops nothing'
);
select is_empty(
  $$ select party_id from public.map_query_unboxed(23.7351, 37.9758, 500000)
     except
     select party_id from public.get_parties_near_user(23.7351, 37.9758, 500000) $$,
  'host 500km: the box drops nothing'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444');
select is_empty(
  $$ select party_id from public.map_query_unboxed(23.7351, 37.9758, 5000)
     except
     select party_id from public.get_parties_near_user(23.7351, 37.9758, 5000) $$,
  'stranger 5km: the box drops nothing'
);
select is_empty(
  $$ select party_id from public.get_parties_near_user(23.7351, 37.9758, 5000)
     except
     select party_id from public.map_query_unboxed(23.7351, 37.9758, 5000) $$,
  'stranger 5km: and admits nothing extra'
);

select tests.authenticate_as('22222222-2222-2222-2222-222222222222');
select is_empty(
  $$ select party_id from public.map_query_unboxed(23.7351, 37.9758, 5000)
     except
     select party_id from public.get_parties_near_user(23.7351, 37.9758, 5000) $$,
  'invitee 5km: the box drops nothing -- including the private party they were invited to'
);

-- And at a high latitude, where the naive box fails worst. The probe parties
-- at 60N are hosted by 1111 whose map_visibility is public, so they are
-- genuinely returnable.
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');
select is_empty(
  $$ select party_id from public.map_query_unboxed(23.0, 60.0, 5000)
     except
     select party_id from public.get_parties_near_user(23.0, 60.0, 5000) $$,
  'host at 60N: the box drops nothing where degrees-per-metre is furthest from the Athens value'
);
select isnt_empty(
  $$ select party_id from public.get_parties_near_user(23.0, 60.0, 5000) $$,
  'control: there really are probe parties at 60N to drop'
);

select tests.clear_authentication();


-- ============================================================
-- 4. The generated columns
--
-- The point of GENERATED ALWAYS is that `location` cannot get out of step with
-- what the index is built on. Assert that rather than trusting the keyword.
-- ============================================================

-- Back to the owning role: section 3 ended anonymous, and these assertions are
-- about the column definition rather than about who may read a row.
reset role;

select is(
  (select is_generated from information_schema.columns
   where table_schema = 'public' and table_name = 'parties' and column_name = 'bbox_lat'),
  'ALWAYS',
  'bbox_lat is GENERATED ALWAYS -- not a trigger, not a plain column'
);
select is(
  (select is_generated from information_schema.columns
   where table_schema = 'public' and table_name = 'parties' and column_name = 'bbox_lon'),
  'ALWAYS',
  'bbox_lon is GENERATED ALWAYS'
);

select is_empty(
  $$ select id from public.parties
     where bbox_lat is distinct from st_y(location::geometry)
        or bbox_lon is distinct from st_x(location::geometry) $$,
  'every row''s bbox columns agree with its location, across the whole table'
);

select throws_ok(
  $$ insert into public.parties (host_id, title, location, starts_at, ends_at, bbox_lat)
     values ('11111111-1111-1111-1111-111111111111', 'Forged',
             st_point(23.7, 37.9)::geography, now() + interval '1 day',
             now() + interval '1 day 6 hours', 0) $$,
  '428C9',
  null,
  'a generated column cannot be written on insert, at any privilege level'
);

select throws_ok(
  $$ update public.parties set bbox_lat = 0
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  '428C9',
  null,
  'nor on update -- which is what makes the index trustworthy'
);

-- Moving a party moves its box columns with it. This is the drift a trigger
-- implementation would eventually get wrong.
update public.parties
set location = st_point(24.0, 38.5)::geography
where id = 'aaaaaaaa-0000-0000-0000-000000000002';

select is(
  (select round(bbox_lat::numeric, 6) from public.parties
   where id = 'aaaaaaaa-0000-0000-0000-000000000002'),
  38.500000::numeric,
  'moving a party recomputes its bbox columns'
);


-- ============================================================
-- 5. The mechanism has something to reach, and nothing about visibility moved
--
-- The acceptance criterion for this phase is rows-into-the-policy, measured by
-- scripts/explain_policy_pushdown.sh -- pgTAP cannot see a query plan. What it
-- CAN do is assert the index exists and that this migration touched no
-- visibility rule, which is the claim that makes the phase safe.
-- ============================================================

select has_index('public', 'parties', 'parties_bbox_idx',
  'the btree the leakproof predicate reaches exists');

select is(
  (select pg_get_expr(polqual, polrelid) from pg_policy
   where polrelid = 'public.parties'::regclass and polcmd = 'r'),
  '((NOT is_blocked(( SELECT auth.uid() AS uid), host_id)) AND ((NOT is_private) OR (host_id = ( SELECT auth.uid() AS uid)) OR can_access_party(id)))',
  'the parties SELECT policy is byte-for-byte what Phase 12 left -- this phase changed no visibility rule'
);

select is(
  (select prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'can_user_access_party'),
  true,
  'can_user_access_party is untouched and still SECURITY DEFINER'
);

-- The pre-filter must never become the answer. If st_dwithin ever leaves the
-- RPC body, the search area silently becomes a square with corners ~40% further
-- out than the radius.
select isnt_empty(
  $$ select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'get_parties_near_user'
       and p.prosrc like '%st_dwithin%' $$,
  'st_dwithin is still in the RPC -- the box narrows, it does not decide'
);

select isnt_empty(
  $$ select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'get_parties_near_user'
       and p.prosrc like '%map_search_box%' $$,
  'and the box is still there -- so the assertion above is not passing because the pre-filter was reverted'
);

select * from finish();
rollback;
