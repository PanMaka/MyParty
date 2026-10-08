-- get_my_parties: MY PARTIES on the server, with the shared "is it over" rule.
--
-- The headline is section 2: a null-ends_at party past the grace is GONE from
-- MY PARTIES, as it is from the map and ALL PARTIES (20261008150440). Before
-- 20261008151908 the list decided "over" in Dart and kept it forever.
--
-- Personas (seed.sql): host 1111, invitee 2222, stranger 4444,
-- second_host 6666. Fixtures are all hosted by second_host, so host 1111's
-- seed parties never mix with them; every assertion filters to the
-- 'dddddddd-' ids.
begin;
set search_path to public, extensions;
select plan(16);

select is(
  (select prosecdef from pg_proc where oid = 'public.get_my_parties()'::regprocedure),
  false,
  'get_my_parties is SECURITY INVOKER -- the parties policy is the only authority'
);

select is(
  (select proconfig from pg_proc where oid = 'public.get_my_parties()'::regprocedure),
  array['search_path=public, extensions'],
  'get_my_parties pins its search_path'
);

-- ===========================================================================
-- 0. Fixtures, as postgres. The invitee is tied to each one somehow.
-- ===========================================================================
insert into public.parties (id, host_id, title, area, location, starts_at, ends_at, is_private, status)
values
  -- Live, no stated end, inside the grace.
  ('dddddddd-0000-0000-0000-000000000001', '66666666-6666-6666-6666-666666666666',
   'Live No End', 'Σύνταγμα', st_point(23.7349, 37.9756)::geography,
   now() - interval '1 hour', null, false, 'published'),
  -- THE ZOMBIE: no stated end, twenty days old.
  ('dddddddd-0000-0000-0000-000000000002', '66666666-6666-6666-6666-666666666666',
   'Zombie No End', 'Σύνταγμα', st_point(23.7349, 37.9756)::geography,
   now() - interval '20 days', null, false, 'published'),
  -- Multi-day with a stated end: started two days ago, ends tomorrow.
  ('dddddddd-0000-0000-0000-000000000003', '66666666-6666-6666-6666-666666666666',
   'Multi Day', 'Σύνταγμα', st_point(23.7349, 37.9756)::geography,
   now() - interval '2 days', now() + interval '1 day', false, 'published'),
  -- Over, with a stated end.
  ('dddddddd-0000-0000-0000-000000000004', '66666666-6666-6666-6666-666666666666',
   'Finished', 'Σύνταγμα', st_point(23.7349, 37.9756)::geography,
   now() - interval '5 hours', now() - interval '1 hour', false, 'published'),
  -- Future and private: the invitee is invited AND going.
  ('dddddddd-0000-0000-0000-000000000005', '66666666-6666-6666-6666-666666666666',
   'Private Future', 'Σύνταγμα', st_point(23.7349, 37.9756)::geography,
   now() + interval '1 day', null, true, 'published'),
  -- Cancelled: not something you are part of any more.
  ('dddddddd-0000-0000-0000-000000000006', '66666666-6666-6666-6666-666666666666',
   'Cancelled', 'Σύνταγμα', st_point(23.7349, 37.9756)::geography,
   now() + interval '1 day', null, false, 'cancelled');

insert into public.invitations (party_id, guest_id) values
  ('dddddddd-0000-0000-0000-000000000005', '22222222-2222-2222-2222-222222222222');

insert into public.rsvps (party_id, user_id, status) values
  ('dddddddd-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'interested'),
  ('dddddddd-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'going'),
  ('dddddddd-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222', 'going'),
  ('dddddddd-0000-0000-0000-000000000004', '22222222-2222-2222-2222-222222222222', 'going'),
  ('dddddddd-0000-0000-0000-000000000005', '22222222-2222-2222-2222-222222222222', 'going'),
  ('dddddddd-0000-0000-0000-000000000006', '22222222-2222-2222-2222-222222222222', 'going');

-- ===========================================================================
-- 1. It runs, and lists what is not over
-- ===========================================================================
select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

select lives_ok(
  $$ select * from public.get_my_parties() $$,
  'get_my_parties runs (gotcha 15: a green reset does not prove a body works)'
);

select results_eq(
  $$ select party_id from public.get_my_parties()
     where party_id::text like 'dddddddd-%' order by party_id $$,
  $$ values ('dddddddd-0000-0000-0000-000000000001'::uuid),
            ('dddddddd-0000-0000-0000-000000000003'::uuid),
            ('dddddddd-0000-0000-0000-000000000005'::uuid) $$,
  'MY PARTIES lists the live, the multi-day and the upcoming party -- and '
  'nothing that is over or cancelled'
);

-- ===========================================================================
-- 2. THE HEADLINE: the shared rule, not the old Dart one
-- ===========================================================================
select is_empty(
  $$ select 1 from public.get_my_parties()
     where party_id = 'dddddddd-0000-0000-0000-000000000002' $$,
  'a null-ends_at party from 20 days ago is NOT in MY PARTIES -- the grace '
  'applies here as on the map (gotcha 21)'
);

select isnt_empty(
  $$ select 1 from public.get_my_parties()
     where party_id = 'dddddddd-0000-0000-0000-000000000003' $$,
  'a multi-day party with a stated end in the future IS -- the grace never '
  'applies where ends_at is set'
);

select is_empty(
  $$ select 1 from public.get_my_parties()
     where party_id = 'dddddddd-0000-0000-0000-000000000004' $$,
  'a party whose stated end has passed is not'
);

-- Three spellings, one definition: every fixture the caller is tied to is
-- listed exactly when party_is_past says it is not over.
select results_eq(
  $$ select party_id from public.get_my_parties()
     where party_id::text like 'dddddddd-%' order by party_id $$,
  $$ select id from public.parties
     where id::text like 'dddddddd-%' and status = 'published'
       and not public.party_is_past(starts_at, ends_at) order by id $$,
  'MY PARTIES agrees with party_is_past row by row'
);

-- ===========================================================================
-- 3. One row per party, flags merged
-- ===========================================================================
select is(
  (select count(*)::int from public.get_my_parties()
    where party_id = 'dddddddd-0000-0000-0000-000000000005'),
  1,
  'a party the caller is both invited to and going to is ONE row, not two'
);

select is(
  (select row(my_rsvp_status, is_invited, is_host)::text from public.get_my_parties()
    where party_id = 'dddddddd-0000-0000-0000-000000000005'),
  row('going'::public.rsvp_status, true, false)::text,
  'and that row carries both the rsvp status and the invitation'
);

select is(
  (select my_rsvp_status from public.get_my_parties()
    where party_id = 'dddddddd-0000-0000-0000-000000000001'),
  'interested'::public.rsvp_status,
  'the caller''s own status comes through as recorded'
);

-- ===========================================================================
-- 4. Who must NOT see these rows
-- ===========================================================================
select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select is_empty(
  $$ select 1 from public.get_my_parties() where party_id::text like 'dddddddd-%' $$,
  'a stranger tied to none of them sees none of them -- another user''s rsvps '
  'and invitations are not the caller''s parties'
);

select tests.authenticate_as('66666666-6666-6666-6666-666666666666'); -- second_host

select results_eq(
  $$ select party_id from public.get_my_parties()
     where party_id::text like 'dddddddd-%' order by party_id $$,
  $$ values ('dddddddd-0000-0000-0000-000000000001'::uuid),
            ('dddddddd-0000-0000-0000-000000000003'::uuid),
            ('dddddddd-0000-0000-0000-000000000005'::uuid) $$,
  'the host sees their own parties through the host arm, by the same rule'
);

select is(
  (select bool_and(is_host and my_rsvp_status is null) from public.get_my_parties()
    where party_id::text like 'dddddddd-%'),
  true,
  'flagged as host, with no rsvp of their own -- the invitee''s rsvp is not theirs'
);

-- ===========================================================================
-- 5. Privileges
-- ===========================================================================
select tests.clear_authentication();
set local role anon;

select throws_ok(
  $$ select * from public.get_my_parties() $$,
  '42501',
  null,
  'anon cannot execute get_my_parties'
);

reset role;

select is(
  (select count(*)::int from public.get_my_parties()),
  0,
  'with no auth.uid() the list is empty rather than everyone''s'
);

select * from finish();
rollback;
