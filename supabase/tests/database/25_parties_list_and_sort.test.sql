-- Phase 18: get_parties_list -- the ALL PARTIES browse list, sorted on the
-- server, and the side channel that sorting one of these columns opens.
--
-- The headline assertions in this file are the NEGATIVE ones in section 4. A
-- naive implementation -- `order by interested_count desc nulls first` --
-- produces a list that looks completely correct, puts private parties at the
-- top by accident (desc defaults to nulls first), passes any test that only
-- checks the public ordering, and silently reveals each private party's count
-- to within the gap between its neighbours. The tests that catch it are the
-- ones where the count order and the starts_at order DISAGREE.
--
-- Fixtures used from seed.sql:
--   PRIVATE_EARLY 'aaaaaaaa-...0001' Rooftop Pregame,  now + 2 days,  host's
--   PRIVATE_LATE  'aaaaaaaa-...0013' Ambelokipi Loft,  now + 13 days, host is
--                                                      invited
--   PUBLIC        'aaaaaaaa-...0002' Syntagma Afterparty, now + 2 days
begin;
set search_path to public, extensions;
select plan(21);

-- ===========================================================================
-- 0. Fixtures
-- ===========================================================================
-- Inserted as postgres, before authenticating: this is fixture setup, not an
-- assertion about the rsvps write policy (22_private covers that). The counter
-- trigger is SECURITY DEFINER and fires either way, which is the only part
-- that matters here.
--
-- THE POINT OF THESE NUMBERS: the two private parties are given counts whose
-- order DISAGREES with their starts_at order. PRIVATE_LATE gets three rsvps
-- and starts later; PRIVATE_EARLY gets one and starts sooner. So "ordered by
-- count desc" and "ordered by starts_at asc" predict opposite results, and
-- section 4 can tell which one the function actually did. With agreeing
-- numbers the test would pass against the leaking implementation.
--
-- Only 'going' is legal on a private party (20260825090050), and since
-- 20260826093437 a going rsvp increments interested_count too -- which is what
-- makes it possible to give a private party a non-zero interested_count at all.
insert into public.rsvps (party_id, user_id, status) values
  ('aaaaaaaa-0000-0000-0000-000000000013', '22222222-2222-2222-2222-222222222222', 'going'),
  ('aaaaaaaa-0000-0000-0000-000000000013', '44444444-4444-4444-4444-444444444444', 'going'),
  ('aaaaaaaa-0000-0000-0000-000000000013', '0c0c0c0c-0000-0000-0000-000000000001', 'going'),
  ('aaaaaaaa-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'going');

-- A LIVE public party: started an hour ago, ends in three. Nothing in seed.sql
-- is live (every party there is in the future), so the 'soonest' sort's first
-- group would otherwise be empty and untested.
insert into public.parties (id, host_id, title, description, location, starts_at, ends_at, is_private, is_sponsored, party_tier, area)
values ('eeeeeeee-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
        'Live Right Now', 'Started an hour ago.', st_point(23.7348, 37.9755)::geography,
        now() - interval '1 hour', now() + interval '3 hours', false, false, 'standard', 'Σύνταγμα');

-- Two parties that are OVER, one of each shape. The second is the gotcha 21
-- zombie -- a finished party with no end time, which the map pinned forever
-- until 20261008150440 and this list never did.
insert into public.parties (id, host_id, title, description, location, starts_at, ends_at, is_private, is_sponsored, party_tier, area)
values
  ('eeeeeeee-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'Finished With End Time', 'Over.', st_point(23.7348, 37.9755)::geography,
   now() - interval '30 days', now() - interval '30 days' + interval '5 hours', false, false, 'standard', 'Σύνταγμα'),
  ('eeeeeeee-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   'Finished No End Time', 'Over, and says so nowhere.', st_point(23.7348, 37.9755)::geography,
   now() - interval '30 days', null, false, false, 'standard', 'Σύνταγμα');

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

-- ===========================================================================
-- 1. It runs at all
-- ===========================================================================
-- gotcha 15: plpgsql and sql function bodies resolve column names at RUNTIME,
-- so `supabase db reset` applying cleanly is not evidence that either sort
-- works. Every new RPC needs at least one lives_ok.
select lives_ok(
  $$ select * from public.get_parties_list('soonest') $$,
  'get_parties_list runs on the soonest sort'
);

select lives_ok(
  $$ select * from public.get_parties_list('interested') $$,
  'get_parties_list runs on the interested sort'
);

-- An unknown sort is a TYPE error, raised by Postgres at the boundary, rather
-- than a runtime branch or a silent fallback to the default. That is the whole
-- reason party_sort is an enum.
select throws_ok(
  $$ select * from public.get_parties_list('popular'::public.party_sort) $$,
  '22P02',
  null,
  'an unknown sort value is refused by the enum, not silently defaulted'
);

-- ===========================================================================
-- 2. 'soonest': live first, then upcoming ascending
-- ===========================================================================
select is(
  (select party_id from public.get_parties_list('soonest', 50) limit 1),
  'eeeeeeee-0000-0000-0000-000000000001'::uuid,
  'the live party leads the soonest sort'
);

select is(
  (select sort_group from public.get_parties_list('soonest', 50)
   where party_id = 'eeeeeeee-0000-0000-0000-000000000001'),
  0,
  'and it is in group 0, not merely first by accident of its start time'
);

-- Everything after the live group is in start order. Compared against the same
-- rows sorted independently rather than against a hand-written list, so the
-- assertion does not have to be rewritten every time seed.sql gains a party.
select results_eq(
  $$ select party_id from public.get_parties_list('soonest', 50)
     where sort_group = 1 $$,
  $$ select party_id from public.get_parties_list('soonest', 50)
     where sort_group = 1 order by starts_at asc, party_id asc $$,
  'the upcoming group is ordered by starts_at ascending'
);

-- Private parties INTERLEAVE here, and that is deliberate: this sort ranks on
-- starts_at, which is transmitted for private rows anyway, so their position
-- reveals nothing that is not already on the detail sheet. Pinning them in
-- both sorts would be cargo-culting section 4's fix somewhere it does not
-- apply. Asserted rather than left implicit, because "private is always
-- grouped" is exactly the over-generalisation a later edit would make.
select isnt(
  (select min(sort_group) from public.get_parties_list('soonest', 50) where is_private),
  0,
  'private parties are NOT pinned into their own group on the soonest sort'
);

select ok(
  (select count(*) from (
     select is_private, lead(is_private) over (order by sort_group, sort_rank, starts_at, party_id) as nxt
     from public.get_parties_list('soonest', 50)
   ) x where is_private is distinct from nxt) > 1,
  'and they are genuinely interleaved with public ones, not clustered'
);

-- ===========================================================================
-- 3. 'interested': the public ranking
-- ===========================================================================
select results_eq(
  $$ select party_id from public.get_parties_list('interested', 50)
     where sort_group = 1 $$,
  $$ select party_id from public.get_parties_list('interested', 50)
     where sort_group = 1 order by interested_count desc, starts_at asc, party_id asc $$,
  'public rows are ordered by interested_count descending, ties broken by starts_at'
);

-- ===========================================================================
-- 4. THE SIDE CHANNEL. Private parties are a group, not a rank.
-- ===========================================================================
-- Every private row the caller can see is in group 0, ahead of every public
-- row. Position therefore carries no information about the count.
select is_empty(
  $$ select party_id from public.get_parties_list('interested', 50)
     where is_private and sort_group <> 0 $$,
  'every visible private party is in group 0 on the interested sort'
);

select is_empty(
  $$ select party_id from public.get_parties_list('interested', 50)
     where not is_private and sort_group = 0 $$,
  'and no public party is in that group -- the boundary is privacy, nothing else'
);

-- THE assertion. PRIVATE_LATE has three rsvps and starts in 13 days;
-- PRIVATE_EARLY has one and starts in 2. Ordering the group by the hidden
-- count puts LATE first; ordering it by starts_at puts EARLY first. This is
-- the only test in the file that can tell those two implementations apart.
select is(
  (select party_id from public.get_parties_list('interested', 50)
   where is_private limit 1),
  'aaaaaaaa-0000-0000-0000-000000000001'::uuid,
  'the private group is ordered by starts_at -- the party with FEWER rsvps leads because it starts sooner'
);

select results_eq(
  $$ select party_id from public.get_parties_list('interested', 50)
     where sort_group = 0 $$,
  $$ select party_id from public.get_parties_list('interested', 50)
     where sort_group = 0 order by starts_at asc, party_id asc $$,
  'the whole private group follows starts_at, not the counter'
);

-- The counter is not merely outranked, it is NOT CONSULTED. sort_rank is the
-- ordering value the function actually computed, so a 0 on every private row
-- is direct evidence that no count entered the comparison -- and it is also
-- what makes the returned cursor safe to hand back, since a cursor pointing at
-- a private party carries no count either.
select is_empty(
  $$ select party_id from public.get_parties_list('interested', 50)
     where is_private and sort_rank <> 0 $$,
  'sort_rank is 0 on every private row -- the hidden value never enters the sort key'
);

-- And the count itself is still absent from the payload, as on the other two
-- read RPCs. A third surface transmitting it would undo 20260825090051.
select is_empty(
  $$ select party_id from public.get_parties_list('interested', 50)
     where is_private and (interested_count is not null or going_count is not null) $$,
  'both counters are still NULL for private rows in this payload'
);

-- ...while my_rsvp_status is not, for the usual reason: it is a property of
-- the caller, who already knows it.
select is(
  (select my_rsvp_status from public.get_parties_list('interested', 50)
   where party_id = 'aaaaaaaa-0000-0000-0000-000000000013'),
  'going'::public.rsvp_status,
  'the caller''s own rsvp status is still transmitted for a private party'
);

-- ===========================================================================
-- 5. Past parties
-- ===========================================================================
select is_empty(
  $$ select party_id from public.get_parties_list('soonest', 100)
     where party_id in ('eeeeeeee-0000-0000-0000-000000000002',
                        'eeeeeeee-0000-0000-0000-000000000003') $$,
  'finished parties are absent, including the null-ends_at one -- the map drops it too since 20261008150440'
);

-- ===========================================================================
-- 6. Keyset pagination
-- ===========================================================================
-- Two pages of 4 must equal one page of 8, in the same order. An off-by-one in
-- the row comparison shows here as a duplicate or a hole, and nowhere else.
select results_eq(
  $$ with p1 as (select * from public.get_parties_list('interested', 4)),
          last1 as (select * from p1 order by sort_group desc, sort_rank desc, starts_at desc, party_id desc limit 1),
          p2 as (select l.* from last1 c,
                 lateral public.get_parties_list('interested', 4, c.sort_group, c.sort_rank, c.starts_at, c.party_id) l)
     select party_id from p1 union all select party_id from p2 $$,
  $$ select party_id from public.get_parties_list('interested', 8) $$,
  'two keyset pages of 4 are exactly one page of 8, same rows in the same order'
);

-- The same, across the group boundary on the sort where the boundary exists.
-- A cursor that carried the count would break here first, because page 2
-- starts inside the public ranking with a rank from a private row.
select results_eq(
  $$ with p1 as (select * from public.get_parties_list('soonest', 5)),
          last1 as (select * from p1 order by sort_group desc, sort_rank desc, starts_at desc, party_id desc limit 1),
          p2 as (select l.* from last1 c,
                 lateral public.get_parties_list('soonest', 5, c.sort_group, c.sort_rank, c.starts_at, c.party_id) l)
     select party_id from p1 union all select party_id from p2 $$,
  $$ select party_id from public.get_parties_list('soonest', 10) $$,
  'and the same holds on the soonest sort, across the live/upcoming boundary'
);

-- ===========================================================================
-- 7. RLS is still the only visibility authority
-- ===========================================================================
-- The grouping above puts private parties FIRST, which is exactly the position
-- that would make a leak maximally visible if the function ever returned one
-- the caller may not see. It is SECURITY INVOKER and re-implements nothing, so
-- this should hold for free -- which is why it is worth asserting.
select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select is_empty(
  $$ select party_id from public.get_parties_list('interested', 100)
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'a stranger does not get the private party at all, let alone at the top'
);

-- gotcha 4: the function mentions rsvps and invitations, on neither of which
-- anon holds SELECT, so an anon call errors on the mention rather than
-- returning an empty list. The execute grant is revoked for that reason.
select tests.clear_authentication();

select throws_ok(
  $$ select * from public.get_parties_list('soonest') $$,
  '42501',
  null,
  'anon cannot execute get_parties_list at all'
);

select * from finish();
rollback;
