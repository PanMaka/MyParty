-- Phase 11: get_my_hosted_parties, the profile's single party list.
--
-- The function makes four claims and each one is a separate way to be wrong,
-- so each gets its own assertion:
--
--   1. HOSTED ONLY. Not "hosted or attended". The list used to be two sections
--      and the second read `rsvps`; a merged version of it would have been
--      untruthful on anybody else's profile, because the rsvps SELECT policy
--      is `user_id = auth.uid() OR I host the party`. The list is now about
--      hosting alone, and the negative below is what holds it there.
--   2. AUTH.UID() ONLY. It takes no user id, so this is really a claim that
--      two different callers get two different lists.
--   3. THE ORDER. Upcoming block first (soonest first), then past (most recent
--      first). It is the reason this is a function at all -- PostgREST cannot
--      express two sort directions in one request.
--   4. is_upcoming AGREES WITH THE ORDER, because one now() produced both.
--
-- Built on `stranger` (4444), who hosts nothing in seed.sql. The host persona
-- (1111) has nineteen seeded parties, two of which start at exactly
-- `now() + 2 days` -- asserting a total ordering against a tie would be
-- asserting something Postgres does not promise.
--
-- gotcha #15: a green `supabase db reset` only means the body PARSED. Every
-- assertion here CALLS the function.
begin;
set search_path to public, extensions;
select plan(15);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

-- Four parties this caller hosts, with distinct start times so there is a
-- total order to assert, plus the two lifecycle states that must not appear.
insert into public.parties (id, host_id, title, location, starts_at, is_private, status)
values
  ('dddddddd-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444',
   'Αύριο', st_point(23.7348, 37.9755)::geography, now() + interval '1 day', false, 'published'),
  ('dddddddd-0000-0000-0000-000000000002', '44444444-4444-4444-4444-444444444444',
   'Σε μια βδομάδα', st_point(23.7348, 37.9755)::geography, now() + interval '7 days', true, 'published'),
  ('dddddddd-0000-0000-0000-000000000003', '44444444-4444-4444-4444-444444444444',
   'Χθες', st_point(23.7348, 37.9755)::geography, now() - interval '1 day', false, 'published'),
  ('dddddddd-0000-0000-0000-000000000004', '44444444-4444-4444-4444-444444444444',
   'Πέρσι', st_point(23.7348, 37.9755)::geography, now() - interval '300 days', false, 'published'),
  -- A draft is not something you are hosting yet; a cancellation is not
  -- something you are hosting any more. Both are visible to their own host
  -- through the parties SELECT policy, which is exactly why the function has
  -- to say `status = 'published'` out loud.
  ('dddddddd-0000-0000-0000-000000000005', '44444444-4444-4444-4444-444444444444',
   'Προσχέδιο', st_point(23.7348, 37.9755)::geography, now() + interval '2 days', false, 'draft'),
  ('dddddddd-0000-0000-0000-000000000006', '44444444-4444-4444-4444-444444444444',
   'Ακυρώθηκε', st_point(23.7348, 37.9755)::geography, now() + interval '3 days', false, 'cancelled');

-- The caller is GOING to two parties they do not host: one past, one upcoming.
-- These are the rows the deleted ΤΟ ΙΣΤΟΡΙΚΟ ΜΟΥ section used to render, and
-- they are the whole point of assertion 1.
insert into public.rsvps (party_id, user_id, status) values
  ('aaaaaaaa-0000-0000-0000-000000000041', '44444444-4444-4444-4444-444444444444', 'going'),
  ('aaaaaaaa-0000-0000-0000-000000000002', '44444444-4444-4444-4444-444444444444', 'going');


-- ============================================================
-- 0. It runs at all. gotcha #15 -- the cheapest assertion in the file and the
-- one that would have caught two Phase 9 migrations that applied green.
-- ============================================================
select lives_ok(
  $$ select * from public.get_my_hosted_parties() $$,
  'get_my_hosted_parties() executes'
);


-- ============================================================
-- 1. Hosted only. The negative is the claim; the positive next to it proves
-- the negative did not pass because the query returned nothing at all.
-- ============================================================
select is(
  (select count(*)::int from public.get_my_hosted_parties()),
  4,
  'returns the four published parties this caller HOSTS'
);

select is(
  (select count(*)::int from public.get_my_hosted_parties()
   where id in ('aaaaaaaa-0000-0000-0000-000000000041',
                'aaaaaaaa-0000-0000-0000-000000000002')),
  0,
  'a party the caller RSVPd going to is absent -- the list is about hosting, not attendance'
);

select is(
  (select count(*)::int from public.get_my_hosted_parties()
   where title in ('Προσχέδιο', 'Ακυρώθηκε')),
  0,
  'drafts and cancellations are excluded, though the host can see both rows'
);


-- ============================================================
-- 2. Bound to auth.uid(), which is the property that makes the missing
-- p_user_id parameter meaningful rather than merely absent.
-- ============================================================
select tests.authenticate_as('66666666-6666-6666-6666-666666666666'); -- second_host

select is(
  (select count(*)::int from public.get_my_hosted_parties()
   where id::text like 'dddddddd-%'),
  0,
  'a different caller gets none of the first callers parties'
);

select isnt(
  (select count(*)::int from public.get_my_hosted_parties()),
  0,
  'and does get their own -- the previous assertion is not an empty result'
);

-- anon holds no SELECT on public.parties, so without the revoke this would be
-- "permission denied for table parties" rather than an honest refusal
-- (CLAUDE.md gotcha #4).
select tests.clear_authentication();

select throws_ok(
  $$ select * from public.get_my_hosted_parties() $$,
  '42501',
  null,
  'anon cannot execute it'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444');


-- ============================================================
-- 3. The order, which is the reason this is a function.
--
-- row_number() over a function scan numbers rows in the order the function
-- produced them, which is precisely what is being asserted. Compared as one
-- array so a reordering fails on the shape rather than on four separate
-- assertions that could each pass in isolation.
-- ============================================================
select is(
  (select array_agg(title order by rn)
   from (select title, row_number() over () as rn
         from public.get_my_hosted_parties()) t),
  array['Αύριο', 'Σε μια βδομάδα', 'Χθες', 'Πέρσι'],
  'upcoming block first soonest-first, then past most-recent-first'
);

select is(
  (select title from public.get_my_hosted_parties() limit 1),
  'Αύριο',
  'the next party you are hosting is the first row'
);


-- ============================================================
-- 4. is_upcoming, and that it agrees with the ordering. Two clocks would let
-- these two disagree; there is one, in one statement.
-- ============================================================
select is(
  (select array_agg(is_upcoming order by rn)
   from (select is_upcoming, row_number() over () as rn
         from public.get_my_hosted_parties()) t),
  array[true, true, false, false],
  'is_upcoming partitions the same way the ordering blocks it'
);

select is(
  (select bool_and(is_upcoming = (starts_at >= now()))
   from public.get_my_hosted_parties()),
  true,
  'is_upcoming is not merely plausible -- it matches starts_at against now()'
);


-- ============================================================
-- 5. The columns the card renders. Nullable ones stay null rather than
-- arriving defaulted, because the card draws nothing for an absent area and a
-- placeholder for an absent cover -- both of which need the null to survive.
-- ============================================================
select is(
  (select is_private from public.get_my_hosted_parties() where title = 'Σε μια βδομάδα'),
  true,
  'is_private comes through for the privacy badge'
);

select is(
  (select area from public.get_my_hosted_parties() where title = 'Αύριο'),
  null,
  'an unset area arrives as null, not as an empty string'
);

select is(
  (select cover_path from public.get_my_hosted_parties() where title = 'Αύριο'),
  null,
  'an unset cover_path arrives as null, so the card knows to draw its placeholder'
);


-- ============================================================
-- 6. The limit is real. It matters to the CLIENT rather than to the database:
-- the section heading prints a count of what it RENDERED, so a silently
-- truncating query would print a number that disagrees with the cards.
-- ============================================================
select is(
  (select count(*)::int from public.get_my_hosted_parties(2)),
  2,
  'p_limit truncates, and takes the first rows of the order above'
);

select * from finish();
rollback;
