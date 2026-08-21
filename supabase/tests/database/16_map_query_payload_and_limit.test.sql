-- get_parties_near_user: the four columns added to the payload, and the cap.
--
-- The existing coverage of this function is spread across 03 (lifecycle
-- filter, rsvp columns), 04 (blocks) and 11 (map_visibility), and all of it
-- asks WHICH ROWS come back. Nothing asked what a row SAYS, which is how the
-- client spent three phases reading `attendee_count` -- a column the RPC has
-- never emitted -- and drawing a hardcoded 0 on every pin. A payload is an
-- interface; this file is the part of it the map depends on.
--
-- gotcha #15: a green `supabase db reset` only means the body PARSED. Every
-- assertion here CALLS the function.
--
-- Built on `stranger` (4444), who hosts nothing in seed.sql, so every count
-- below is a count of rows this file created.
begin;
set search_path to public, extensions;
select plan(11);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

-- One fully-populated party. The literals are far-future so the lifecycle
-- filter (`ends_at > now()`) keeps it on the map for as long as this test file
-- exists, and cover_path satisfies parties_cover_path_own_folder, which
-- requires the party's own id as the first path segment.
insert into public.parties (id, host_id, title, location, starts_at, ends_at, area, cover_path, is_private, status)
values (
  'dddddddd-1111-0000-0000-000000000001',
  '44444444-4444-4444-4444-444444444444',
  'Πλήρες πάρτι',
  st_point(23.7348, 37.9755)::geography,
  '2030-06-01 18:00:00+00',
  '2030-06-02 02:00:00+00',
  'Κουκάκι',
  'dddddddd-1111-0000-0000-000000000001/cover.jpg',
  false,
  'published'
);

-- A SECOND user's RSVP, not the caller's. interested_count is a property of
-- the party; my_rsvp_status is a property of the viewer. A counter wired to
-- the wrong one of those would pass a test where the same person did both.
select tests.authenticate_as('33333333-3333-3333-3333-333333333333'); -- friend_not_invited
insert into public.rsvps (party_id, user_id, status)
values ('dddddddd-1111-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'interested');
select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger, back


-- ============================================================
-- 1. The four columns.
--
-- p_limit is passed explicitly on every payload query below, because the cap
-- is applied BEFORE the outer where-clause: a default of 200 with the 501
-- parties section 3 inserts would silently truncate the row under test out of
-- the result and fail for a reason that has nothing to do with the payload.
-- ============================================================
select results_eq(
  $$ select ends_at, area, cover_path, interested_count, going_count
     from public.get_parties_near_user(23.7348, 37.9755, 500, 500)
     where party_id = 'dddddddd-1111-0000-0000-000000000001' $$,
  $$ values ('2030-06-02 02:00:00+00'::timestamptz, 'Κουκάκι',
             'dddddddd-1111-0000-0000-000000000001/cover.jpg', 1, 0) $$,
  'the payload carries ends_at, area, cover_path and interested_count'
);

-- The two counters are separate numbers and the client picks between them by
-- tense, so a payload that reported one for both would draw a plausible pin
-- with the wrong number on it.
select results_eq(
  $$ select interested_count, going_count, my_rsvp_status
     from public.get_parties_near_user(23.7348, 37.9755, 500, 500)
     where party_id = 'dddddddd-1111-0000-0000-000000000001' $$,
  $$ values (1, 0, null::public.rsvp_status) $$,
  'interested_count counts ANOTHER users rsvp -- it is the partys number, not the viewers'
);

-- Tied to the trigger rather than to the literal 1 above: flipping the same
-- rsvp to 'going' must move the number from one column to the other, which is
-- the only thing that proves the map is reading sync_party_rsvp_counters and
-- not a coincidence.
select tests.authenticate_as('33333333-3333-3333-3333-333333333333');
update public.rsvps set status = 'going'
where party_id = 'dddddddd-1111-0000-0000-000000000001'
  and user_id = '33333333-3333-3333-3333-333333333333';
select tests.authenticate_as('44444444-4444-4444-4444-444444444444');

select results_eq(
  $$ select interested_count, going_count
     from public.get_parties_near_user(23.7348, 37.9755, 500, 500)
     where party_id = 'dddddddd-1111-0000-0000-000000000001' $$,
  $$ values (0, 1) $$,
  'both counters track the rsvp counter trigger, not a snapshot'
);


-- ============================================================
-- 2. A null ends_at is a row, not an error.
--
-- ends_at is nullable and the host wizard does not require it, so this is the
-- shape of a real party and the client has to be handed the null rather than a
-- substitute. It is also the party that never leaves the map (gotcha 21) --
-- the map query cannot recognise "already happened" without an end time, and
-- the point of returning the column is that the client can now at least SEE
-- that it does not know.
-- ============================================================
insert into public.parties (id, host_id, title, location, starts_at, is_private, status)
values (
  'dddddddd-1111-0000-0000-000000000002',
  '44444444-4444-4444-4444-444444444444',
  'Χωρίς τέλος',
  st_point(23.7348, 37.9755)::geography,
  '2030-06-01 18:00:00+00',
  false,
  'published'
);

select results_eq(
  $$ select ends_at, area, cover_path
     from public.get_parties_near_user(23.7348, 37.9755, 500, 500)
     where party_id = 'dddddddd-1111-0000-0000-000000000002' $$,
  $$ values (null::timestamptz, null::text, null::text) $$,
  'an unstated end, neighbourhood and cover come back as nulls rather than substitutes'
);


-- ============================================================
-- 3. The cap.
--
-- 501 parties at one point, private and hosted by the caller. Private for
-- cost, not for meaning: the parties_notify_on_insert trigger fires per row on
-- every published PUBLIC party, so a public bulk insert would run 501
-- proximity fan-outs to assert something about a LIMIT clause. The caller
-- hosts them, so `p.host_id = auth.uid()` satisfies both can_access_party and
-- the map_visibility gate -- all 501 are on this caller's map.
-- ============================================================
insert into public.parties (host_id, title, location, starts_at, ends_at, is_private, status)
select
  '44444444-4444-4444-4444-444444444444',
  'Πλήθος ' || i,
  st_point(23.7348, 37.9755)::geography,
  '2030-06-01 18:00:00+00',
  '2030-06-02 02:00:00+00',
  true,
  'published'
from generate_series(1, 501) as i;

select is(
  (select count(*) from public.get_parties_near_user(23.7348, 37.9755, 500)),
  200::bigint,
  'the default p_limit is 200 -- the three-argument call still resolves, and is now bounded'
);

select is(
  (select count(*) from public.get_parties_near_user(23.7348, 37.9755, 500, 5)),
  5::bigint,
  'an explicit p_limit is honoured'
);

-- The ceiling. Without it a caller could ask for the unbounded behaviour the
-- limit exists to remove, which is the same thing as not having a limit.
select is(
  (select count(*) from public.get_parties_near_user(23.7348, 37.9755, 500, 100000)),
  500::bigint,
  'p_limit is capped at 500 however much is asked for'
);

-- The floor, and it is the more interesting half: an empty map is a perfectly
-- plausible screen, so a zero that produced one would look like "no parties
-- nearby" rather than like a bad argument.
select is(
  (select count(*) from public.get_parties_near_user(23.7348, 37.9755, 500, 0)),
  1::bigint,
  'p_limit = 0 clamps to one row rather than rendering an empty map'
);

select is(
  (select count(*) from public.get_parties_near_user(23.7348, 37.9755, 500, -20)),
  1::bigint,
  'and so does a negative'
);

select tests.clear_authentication();


-- ============================================================
-- 4. Who may call it.
--
-- The same pair as get_profile_stats in 11, and for the same two gotchas. #4:
-- the function mentions `rsvps` and `invitations` for my_rsvp_status and
-- is_invited, and anon holds SELECT on neither, so an anonymous call raised
-- "permission denied for table rsvps" rather than returning pins -- the
-- EXECUTE grant it held was never usable. #13: the revoke that removes it also
-- removes service_role's, because the default PUBLIC grant is where that came
-- from.
--
-- What this does NOT assert, because it is not true: that the map is closed to
-- anonymous clients. `anon` still reads every public party off
-- `public.parties` directly -- see 20260821175831. This is an assertion about
-- one door, not about the building.
-- ============================================================
select is(
  has_function_privilege('anon', 'public.get_parties_near_user(double precision, double precision, double precision, int)', 'execute'),
  false,
  'anon cannot call the map RPC -- the grant it used to hold could only ever return 42501'
);

select is(
  (select bool_and(has_function_privilege(r, 'public.get_parties_near_user(double precision, double precision, double precision, int)', 'execute'))
   from unnest(array['authenticated', 'service_role']) r),
  true,
  'but authenticated and service_role can -- the explicit grant survived the revoke'
);

select * from finish();
rollback;
