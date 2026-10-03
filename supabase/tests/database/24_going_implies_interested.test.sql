-- Phase 17: interested_count is a SUPERSET of going_count, not its sibling.
--
-- 20260826093437 changed one thing -- what interested_count counts -- and the
-- surface area of that one thing is the whole of this file:
--
--   * a going rsvp increments BOTH counters
--   * interested -> going decrements neither, and increments going_count
--   * going -> interested decrements going_count and leaves interested_count
--   * a delete leaves BOTH sets, whichever status the row held
--   * going_count <= interested_count, always, as a standing invariant
--
-- The transition assertions are the point of the file. The two insert cases
-- are easy to get right and easy to test; the transitions are where the old
-- trigger did its work (it MOVED a person between columns) and where a partial
-- revert would land. A trigger that increments both on insert but still
-- decrements interested on the flip passes every insert assertion here and
-- produces a counter that drifts down every time somebody commits.
--
-- PARTY_PUBLIC  'aaaaaaaa-...0002' "Syntagma Afterparty", host = host.
-- PARTY_PRIVATE 'aaaaaaaa-...0001' "Rooftop Pregame", invitee + second_host
--   invited. Private parties refuse the 'interested' STATUS (20260825090050)
--   but are fully included in the counter rule -- see 22_private, which
--   asserts that directly.
begin;
set search_path to public, extensions;
select plan(15);

-- ===========================================================================
-- Baseline
-- ===========================================================================
-- seed.sql deliberately puts no rsvps on 0001 or 0002 (03_rsvps asserts exact
-- values on both), so both counters start at 0 and every number below is a
-- delta from a known zero rather than from whatever the fixtures happened to
-- leave behind.
select results_eq(
  $$ select going_count, interested_count from public.parties
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  $$ values (0, 0) $$,
  'the public fixture party starts with both counters at 0'
);

-- ===========================================================================
-- 1. A going rsvp increments BOTH
-- ===========================================================================
select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

insert into public.rsvps (party_id, user_id, status) values
  ('aaaaaaaa-0000-0000-0000-000000000002', '44444444-4444-4444-4444-444444444444', 'going');

select results_eq(
  $$ select going_count, interested_count from public.parties
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  $$ values (1, 1) $$,
  'a GOING rsvp increments both counters -- going implies interested'
);

-- ===========================================================================
-- 2. An interested rsvp increments interested_count only
-- ===========================================================================
-- The other direction of the same rule, and the half that has not changed. It
-- is here because "both counters move together" is a plausible misreading of
-- the change, and it is wrong: the nesting is one-way.
select tests.authenticate_as('55555555-5555-5555-5555-555555555555'); -- blocked_user

insert into public.rsvps (party_id, user_id, status) values
  ('aaaaaaaa-0000-0000-0000-000000000002', '55555555-5555-5555-5555-555555555555', 'interested');

select results_eq(
  $$ select going_count, interested_count from public.parties
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  $$ values (1, 2) $$,
  'an INTERESTED rsvp increments interested_count only -- the nesting is one-way'
);

-- ===========================================================================
-- 3. interested -> going: going_count up, interested_count UNCHANGED
-- ===========================================================================
-- The assertion the whole migration exists for. Under the old trigger this
-- read (2, 1): the person was moved across, and a party whose entire guest
-- list committed reported zero interest.
update public.rsvps set status = 'going'
where party_id = 'aaaaaaaa-0000-0000-0000-000000000002'
and user_id = '55555555-5555-5555-5555-555555555555';

select results_eq(
  $$ select going_count, interested_count from public.parties
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  $$ values (2, 2) $$,
  'interested -> going increments going_count and does NOT decrement interested_count'
);

-- Spelled out separately, because results_eq on a pair reports "the row
-- differs" and a reader chasing a red build should not have to work out which
-- half moved. This is the exact number the old trigger got wrong.
select is(
  (select interested_count from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000002'),
  2,
  'interested_count specifically did not move on the interested -> going flip'
);

-- ===========================================================================
-- 4. going -> interested: going_count down, interested_count UNCHANGED
-- ===========================================================================
-- The mirror, and not covered by case 3. A trigger that special-cased only the
-- interested -> going direction -- the one the product cares about -- would
-- pass case 3 and double-count here, because the person would be added to
-- interested a second time on the way back.
update public.rsvps set status = 'interested'
where party_id = 'aaaaaaaa-0000-0000-0000-000000000002'
and user_id = '55555555-5555-5555-5555-555555555555';

select results_eq(
  $$ select going_count, interested_count from public.parties
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  $$ values (1, 2) $$,
  'going -> interested decrements going_count and leaves interested_count alone'
);

select is(
  (select interested_count from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000002'),
  2,
  'interested_count did not double-count on the way back either'
);

-- A full round trip returns to where it started. Belt and braces over the two
-- assertions above: any per-transition error that happens to be symmetric
-- would cancel in one direction and show up here.
update public.rsvps set status = 'going'
where party_id = 'aaaaaaaa-0000-0000-0000-000000000002'
and user_id = '55555555-5555-5555-5555-555555555555';

select results_eq(
  $$ select going_count, interested_count from public.parties
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  $$ values (2, 2) $$,
  'a full interested -> going -> interested -> going round trip is idempotent'
);

-- ===========================================================================
-- 5. Deleting decrements both, from either status
-- ===========================================================================
-- Un-RSVPing is a DELETE (22_private asserts there is no third enum value), so
-- the delete branch is the only path out of either set and it has to handle
-- both statuses. Two deletes, one from each, because the branch reads
-- OLD.status for going_count and ignores it for interested_count -- a bug in
-- either half shows on exactly one of these.

-- 5a. Deleting a GOING row.
select tests.authenticate_as('55555555-5555-5555-5555-555555555555');

delete from public.rsvps
where party_id = 'aaaaaaaa-0000-0000-0000-000000000002'
and user_id = '55555555-5555-5555-5555-555555555555';

select results_eq(
  $$ select going_count, interested_count from public.parties
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  $$ values (1, 1) $$,
  'deleting a GOING rsvp decrements both counters'
);

-- 5b. Deleting an INTERESTED row. Set one up first -- everything left on this
-- party is going.
select tests.authenticate_as('33333333-3333-3333-3333-333333333333'); -- friend_not_invited

insert into public.rsvps (party_id, user_id, status) values
  ('aaaaaaaa-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333333', 'interested');

select results_eq(
  $$ select going_count, interested_count from public.parties
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  $$ values (1, 2) $$,
  'the interested row for the delete case is in place'
);

delete from public.rsvps
where party_id = 'aaaaaaaa-0000-0000-0000-000000000002'
and user_id = '33333333-3333-3333-3333-333333333333';

select results_eq(
  $$ select going_count, interested_count from public.parties
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  $$ values (1, 1) $$,
  'deleting an INTERESTED rsvp decrements interested_count and leaves going_count'
);

-- And back to empty, closing the loop on the last remaining row.
select tests.authenticate_as('44444444-4444-4444-4444-444444444444');

delete from public.rsvps
where party_id = 'aaaaaaaa-0000-0000-0000-000000000002'
and user_id = '44444444-4444-4444-4444-444444444444';

select results_eq(
  $$ select going_count, interested_count from public.parties
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  $$ values (0, 0) $$,
  'the last delete returns both counters to 0 -- no residue from six transitions'
);

-- ===========================================================================
-- 6. The standing invariant, over every party in the database
-- ===========================================================================
-- going_count is a subset of interested_count, so going_count >
-- interested_count is unreachable no matter what sequence of writes got us
-- here. Asserted over the whole table rather than the fixture rows: this
-- catches a bad backfill on rows nothing else in the suite touches, and it is
-- the assertion that fails if somebody reverts the trigger without reverting
-- the backfill.
--
-- As postgres rather than through a persona: this is a question about the
-- TABLE, and asked through a filtered view of public.parties it would only
-- report on rows the caller can see (gotcha 1, gotcha 17).
--
-- NOT tests.clear_authentication() -- that drops to `anon`, which holds SELECT
-- on neither public.parties nor public.rsvps, and gotcha 4 means the query
-- errors on the mention rather than returning zero rows. Resetting the role
-- outright is what actually gets the unfiltered view these three assertions
-- are asking for.
select set_config('request.jwt.claims', '', true);
reset role;

select is_empty(
  $$ select id from public.parties where going_count > interested_count $$,
  'no party anywhere has going_count > interested_count'
);

-- The seeded rows specifically. seed.sql gives 'aaaa...0031' three going and
-- one interested; before the backfill that was interested_count = 1, and the
-- migration adds going_count to it.
select is(
  (select interested_count from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000031'),
  (select count(*)::int from public.rsvps where party_id = 'aaaaaaaa-0000-0000-0000-000000000031'),
  'the backfill left interested_count equal to the actual rsvp count on a seeded party'
);

select is(
  (select going_count from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000031'),
  (select count(*)::int from public.rsvps
   where party_id = 'aaaaaaaa-0000-0000-0000-000000000031' and status = 'going'),
  'and going_count still equals the going subset of them'
);

select * from finish();
rollback;
