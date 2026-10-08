-- Phase 15: the map's time chips, filtered server-side.
--
-- Three properties this file exists to protect, in descending order of how
-- expensive they are to get wrong:
--
-- 1. THE DEFAULT MAP AGREES WITH THE LIST ABOUT WHAT IS OVER. p_window
--    defaults to 'all', and 'all' is an unbounded range -- but since
--    20261008150440 the grace period applies on every window, not only Τώρα,
--    so a null-ends_at party from twenty days ago is GONE from the default map
--    (gotcha 21, closed on purpose). Section 5 asserts that, asserts that a
--    multi-day party with a stated end survives it, and asserts the map and
--    get_parties_list return the same fixtures -- a pin with no card, or a
--    card with no pin, is the bug that decision was taken to end.
--
-- 2. THE TWO SPELLINGS OF THE GRACE PERIOD CANNOT DRIFT. party_is_past() puts
--    the interval on the row side; the map query MUST put it on the constant
--    side, because timestamptz_pl_interval is not leakproof and a Var
--    underneath it drags the whole term behind the RLS barrier (gotcha 22,
--    ~20x measured). Section 1 asserts the two forms are algebraically identical on
--    both sides of the boundary, so "one definition" survives being spelled
--    two ways.
--
-- 3. THE LOCAL CALENDAR IS ACTUALLY LOCAL. Section 3 pins every boundary at a
--    fixed p_now rather than at whatever time the suite happens to run --
--    including the DST case, which is the one a UTC-offset implementation
--    passes everywhere except twice a year.
--
-- Section 5's fixtures for the forward windows are placed at the MIDPOINT OF
-- THE COMPUTED WINDOW, never at `now() + interval 'n hours'`. A fixture two
-- hours out is inside "tonight" at 22:00 and outside it at 03:00, so the
-- obvious spelling produces a suite that goes red depending on the hour it is
-- run at, roughly once a night.
--
-- Personas (seed.sql): host 1111, invitee 2222, friend_not_invited 3333,
-- stranger 4444, blocked_user 5555, second_host 6666.
begin;
set search_path to public, extensions;
select plan(45);


-- ============================================================
-- 1. party_end_grace -- one number, two shapes
-- ============================================================

select is(
  public.party_end_grace(),
  interval '6 hours',
  'the grace period is 6 hours -- the same number search groups by'
);

-- IMMUTABLE and no SET clause are not stylistic. They are what lets a call to
-- this fold to a Const, which is what keeps `starts_at > now() - grace` free of
-- a Var under a leaky function. If either changes, the map's Τώρα predicate
-- silently sinks behind the RLS policy and nothing fails except the timing.
select is(
  (select p.provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'party_end_grace'),
  'i'::"char",
  'party_end_grace is IMMUTABLE, so a call to it folds to a constant'
);

-- THE LOAD-BEARING HALF, and it is at the CALL SITE rather than here. The
-- marking above is not what keeps the predicate ahead of the policy -- wrapping
-- the expression in a scalar subquery is, because that makes it an InitPlan
-- evaluated once and leaves timestamptz_gt(Var, Param) per row. Unwrap it and
-- the rows are identical and the query is slow, which is the failure mode this
-- whole file is shaped around.
select isnt_empty(
  $$ select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'get_parties_near_user'
       and regexp_replace(p.prosrc, '--[^
]*', '', 'g')
           like '%(select now() - public.party_end_grace())%' $$,
  'the map wraps the grace in a scalar subquery, so it is an InitPlan constant '
  'rather than a per-row expression'
);

select isnt_empty(
  $$ select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'party_is_past'
       and p.prosrc like '%party_end_grace%' $$,
  'party_is_past reads the grace from the helper rather than restating 6 hours'
);

-- THE ANTI-DRIFT ASSERTION. party_is_past(s, null, n) is `s + grace <= n`.
-- The map keeps the party when `s > n - grace`, i.e. exactly when it is not
-- past. Asserted at one second either side of the boundary and on it, so an
-- off-by-one in either spelling is caught rather than averaged over.
select is(
  (select bool_and(public.party_is_past(s, null, n) = not (s > n - public.party_end_grace()))
     from (values
       ('2026-05-01 20:00:00+00'::timestamptz, '2026-05-02 01:59:59+00'::timestamptz),
       ('2026-05-01 20:00:00+00', '2026-05-02 02:00:00+00'),
       ('2026-05-01 20:00:00+00', '2026-05-02 02:00:01+00')
     ) v(s, n)),
  true,
  'the row-side and constant-side spellings of the grace agree on both sides '
  'of the boundary -- one definition, two shapes forced by leakproofness'
);


-- ============================================================
-- 2. party_time_window -- the unbounded windows
-- ============================================================

select is(
  lower(public.party_time_window('all', 'Europe/Athens', '2026-08-20 20:00+00')),
  '-infinity'::timestamptz,
  'Όλα is unbounded below -- literally infinite, not a null the RPC would '
  'have to test for on every row'
);
select is(
  upper(public.party_time_window('all', 'Europe/Athens', '2026-08-20 20:00+00')),
  'infinity'::timestamptz,
  'and unbounded above'
);

select is(
  lower(public.party_time_window(null, 'Europe/Athens', '2026-08-20 20:00+00')),
  '-infinity'::timestamptz,
  'a null window is read as "no window" rather than rejected -- PostgREST '
  'sends one for an omitted key'
);

select is(
  upper(public.party_time_window('now', 'Europe/Athens', '2026-08-20 20:00+00')),
  '2026-08-20 20:00+00'::timestamptz,
  'Τώρα ends at the instant of the call: a party must already have started'
);
select is(
  lower(public.party_time_window('now', 'Europe/Athens', '2026-08-20 20:00+00')),
  '-infinity'::timestamptz,
  'and is unbounded below -- how far back it reaches is the ends_at question, '
  'which lives in the RPC because it spans two columns'
);


-- ============================================================
-- 3. party_time_window -- the local calendar
--
-- Athens is UTC+3 in summer (EEST) and UTC+2 in winter (EET). Every expected
-- value below is written in UTC, so the conversion is part of the assertion
-- rather than hidden by it.
-- ============================================================

-- Thursday 23:00 local. "Tonight" runs to Friday 04:00 local = 01:00 UTC.
select is(
  upper(public.party_time_window('tonight', 'Europe/Athens', '2026-08-20 20:00+00')),
  '2026-08-21 01:00+00'::timestamptz,
  'Αργότερα απόψε ends at the next local 04:00, not at midnight'
);
select is(
  lower(public.party_time_window('tonight', 'Europe/Athens', '2026-08-20 20:00+00')),
  '2026-08-20 20:00+00'::timestamptz,
  'and starts now -- it is "later tonight", not "this evening"'
);

-- THE NIGHT BOUNDARY. 02:00 on Sunday belongs to Saturday night, so "tonight"
-- is the two hours left of it. A calendar-date implementation returns 26 hours
-- here and is wrong in the most confusing possible way -- it works all evening
-- and breaks after midnight.
select is(
  upper(public.party_time_window('tonight', 'Europe/Athens', '2026-08-22 23:00+00')),
  '2026-08-23 01:00+00'::timestamptz,
  'at 02:00 local, "tonight" means the night in progress -- 2 hours, not 26'
);

-- Wednesday: the weekend has not started.
select is(
  lower(public.party_time_window('weekend', 'Europe/Athens', '2026-08-19 09:00+00')),
  '2026-08-21 15:00+00'::timestamptz,
  'on a Wednesday, Το ΣΚ starts at the coming Friday 18:00 local'
);
select is(
  upper(public.party_time_window('weekend', 'Europe/Athens', '2026-08-19 09:00+00')),
  '2026-08-24 01:00+00'::timestamptz,
  'and ends at Monday 04:00 local -- the same night boundary tonight uses, so '
  'a Sunday party running to 02:00 stays inside the weekend'
);

-- Saturday 23:00 local: the weekend is in progress. The lower bound clamps to
-- now, so the chip means THIS weekend and never the next one.
select is(
  lower(public.party_time_window('weekend', 'Europe/Athens', '2026-08-22 20:00+00')),
  '2026-08-22 20:00+00'::timestamptz,
  'when today IS the weekend, Το ΣΚ starts now rather than last Friday'
);
select is(
  upper(public.party_time_window('weekend', 'Europe/Athens', '2026-08-22 20:00+00')),
  '2026-08-24 01:00+00'::timestamptz,
  'and still ends this Monday -- not six days out at the next weekend'
);

-- Monday 02:00 local is still Sunday night.
select is(
  upper(public.party_time_window('weekend', 'Europe/Athens', '2026-08-23 23:00+00')),
  '2026-08-24 01:00+00'::timestamptz,
  'Monday 02:00 local is still inside the weekend -- two hours of it left'
);

-- Monday 05:00 local has rolled over.
select is(
  lower(public.party_time_window('weekend', 'Europe/Athens', '2026-08-24 02:00+00')),
  '2026-08-28 15:00+00'::timestamptz,
  'Monday 05:00 local rolls Το ΣΚ forward to the coming Friday'
);

-- THE DST ASSERTION. Greece falls back at 04:00 EEST on 2026-10-25, which is
-- inside this weekend and ON the night boundary. Monday 04:00 is 04:00 EET =
-- 02:00 UTC. Doing the arithmetic on the timestamptz instead of on the naive
-- local clock yields 01:00 UTC -- 03:00 local -- and the bug appears twice a
-- year, in the middle of the night, on the busiest weekend window.
select is(
  upper(public.party_time_window('weekend', 'Europe/Athens', '2026-10-23 09:00+00')),
  '2026-10-26 02:00+00'::timestamptz,
  'a weekend spanning the autumn DST change still ends at 04:00 LOCAL on '
  'Monday, not at the same UTC instant it would have before the change'
);

-- The zone is a parameter and is actually used.
select isnt(
  upper(public.party_time_window('tonight', 'UTC', '2026-08-20 20:00+00')),
  upper(public.party_time_window('tonight', 'Europe/Athens', '2026-08-20 20:00+00')),
  'p_tz is honoured -- the same instant gives a different boundary in a '
  'different zone'
);

-- An unknown window fails loudly. Coercing a typo to 'all' would render a full
-- map under a highlighted chip, which reads as a broken filter with nothing
-- anywhere to say so.
select throws_ok(
  $$ select public.party_time_window('tomorrow', 'Europe/Athens', now()) $$,
  '22023',
  'unknown party time window: tomorrow',
  'an unrecognised window raises rather than silently returning everything'
);


-- ============================================================
-- 4. Fixtures
--
-- The forward-window parties are placed at the midpoint of the window the
-- function actually computes, so this file does not depend on the hour it runs
-- at. See the header.
-- ============================================================

reset role;

-- Τώρα, with no stated end: started an hour ago, inside the grace.
insert into public.parties (id, host_id, title, area, location, starts_at, ends_at, is_private, status)
values ('ffffffff-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111',
        'Τώρα Χωρίς Λήξη', 'Σύνταγμα',
        st_point(23.7349, 37.9756)::geography,
        now() - interval '1 hour', null, false, 'published');

-- Τώρα, with a stated end: the honest path, unaffected by the grace.
insert into public.parties (id, host_id, title, area, location, starts_at, ends_at, is_private, status)
values ('ffffffff-0000-0000-0000-000000000002',
        '11111111-1111-1111-1111-111111111111',
        'Τώρα Με Λήξη', 'Σύνταγμα',
        st_point(23.7349, 37.9756)::geography,
        now() - interval '1 hour', now() + interval '2 hours', false, 'published');

-- THE GOTCHA 21 FIXTURE. Started twenty days ago, no stated end. Past the
-- grace, so it is over -- on the default map as well as in Τώρα.
insert into public.parties (id, host_id, title, area, location, starts_at, ends_at, is_private, status)
values ('ffffffff-0000-0000-0000-000000000003',
        '11111111-1111-1111-1111-111111111111',
        'Ξεχασμένο Χωρίς Λήξη', 'Σύνταγμα',
        st_point(23.7349, 37.9756)::geography,
        now() - interval '20 days', null, false, 'published');

-- Multi-day, with a stated end: started two days ago, ends tomorrow. The
-- grace is for parties that do NOT say when they end, so this one is on the
-- map and in the list. get_parties_list used to drop it six hours in.
insert into public.parties (id, host_id, title, area, location, starts_at, ends_at, is_private, status)
values ('ffffffff-0000-0000-0000-000000000008',
        '11111111-1111-1111-1111-111111111111',
        'Τριήμερο Φεστιβάλ', 'Σύνταγμα',
        st_point(23.7349, 37.9756)::geography,
        now() - interval '2 days', now() + interval '1 day', false, 'published');

-- Inside "tonight", by construction.
insert into public.parties (id, host_id, title, area, location, starts_at, ends_at, is_private, status)
select 'ffffffff-0000-0000-0000-000000000004',
       '11111111-1111-1111-1111-111111111111',
       'Απόψε Αργότερα', 'Σύνταγμα',
       st_point(23.7349, 37.9756)::geography,
       lower(w) + (upper(w) - lower(w)) / 2, null, false, 'published'
from (select public.party_time_window('tonight') w) t;

-- Inside "the weekend", by construction.
insert into public.parties (id, host_id, title, area, location, starts_at, ends_at, is_private, status)
select 'ffffffff-0000-0000-0000-000000000005',
       '11111111-1111-1111-1111-111111111111',
       'Το Σαββατοκύριακο', 'Σύνταγμα',
       st_point(23.7349, 37.9756)::geography,
       lower(w) + (upper(w) - lower(w)) / 2, null, false, 'published'
from (select public.party_time_window('weekend') w) t;

-- Private, hosted by second_host, inside tonight. A window must never widen
-- visibility.
insert into public.parties (id, host_id, title, area, location, starts_at, ends_at, is_private, status)
select 'ffffffff-0000-0000-0000-000000000006',
       '66666666-6666-6666-6666-666666666666',
       'Μυστικό Απόψε', 'Σύνταγμα',
       st_point(23.7349, 37.9756)::geography,
       lower(w) + (upper(w) - lower(w)) / 2, null, true, 'published'
from (select public.party_time_window('tonight') w) t;

-- Genuinely over, with a stated end. The base filter already excludes it; the
-- assertion is that adding a window did not accidentally resurrect it.
insert into public.parties (id, host_id, title, area, location, starts_at, ends_at, is_private, status)
values ('ffffffff-0000-0000-0000-000000000007',
        '11111111-1111-1111-1111-111111111111',
        'Τελείωσε', 'Σύνταγμα',
        st_point(23.7349, 37.9756)::geography,
        now() - interval '3 hours', now() - interval '30 minutes', false, 'published');


-- ============================================================
-- 5. The RPC
-- ============================================================

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

-- THE HEADLINE. gotcha 21 is closed on the default map (20261008150440).
select is_empty(
  $$ select 1 from public.get_parties_near_user(23.7348, 37.9755, 500)
     where party_id = 'ffffffff-0000-0000-0000-000000000003' $$,
  'a null-ends_at party from 20 days ago is NOT on the default map -- the '
  'grace applies on every window, not only Τώρα (gotcha 21, closed)'
);

select isnt_empty(
  $$ select 1 from public.get_parties_near_user(23.7348, 37.9755, 500)
     where party_id = 'ffffffff-0000-0000-0000-000000000008' $$,
  'a multi-day party with a stated end in the future IS on the default map '
  '-- the grace never applies where ends_at is set'
);

-- MAP AND LIST AGREE. The fixtures all sit inside the 500m circle at the
-- 15km-and-under tier, so the only thing that can separate the two sets is the
-- "is it over" rule -- which is the rule this asserts is shared. Private
-- fixture 6 is absent from both for the stranger.
select results_eq(
  $$ select party_id from public.get_parties_near_user(23.7348, 37.9755, 500)
     where party_id::text like 'ffffffff-%' order by party_id $$,
  $$ select party_id from public.get_parties_list('soonest', 100)
     where party_id::text like 'ffffffff-%' order by party_id $$,
  'the default map and ALL PARTIES return the same fixtures -- no pin '
  'without a card, no card without a pin'
);

-- And both agree with party_is_past, the row-side definition, row by row.
select results_eq(
  $$ select party_id from public.get_parties_near_user(23.7348, 37.9755, 500)
     where party_id::text like 'ffffffff-%' order by party_id $$,
  $$ select id from public.parties
     where id::text like 'ffffffff-%' and not is_private
       and not public.party_is_past(starts_at, ends_at) order by id $$,
  'the default map shows exactly the public fixtures party_is_past says are '
  'not over -- three spellings, one definition'
);

select is_empty(
  $$ select 1 from public.get_parties_near_user(23.7348, 37.9755, 500, 200, 'now')
     where party_id = 'ffffffff-0000-0000-0000-000000000003' $$,
  'but it is NOT in Τώρα -- past the grace, so it stopped being "now"'
);

select isnt_empty(
  $$ select 1 from public.get_parties_near_user(23.7348, 37.9755, 500, 200, 'now')
     where party_id = 'ffffffff-0000-0000-0000-000000000001' $$,
  'a null-ends_at party that started an hour ago IS in Τώρα -- inside the grace'
);

select isnt_empty(
  $$ select 1 from public.get_parties_near_user(23.7348, 37.9755, 500, 200, 'now')
     where party_id = 'ffffffff-0000-0000-0000-000000000002' $$,
  'and so is one with a stated end that has not arrived -- the honest path is '
  'not disturbed by the grace'
);

select is_empty(
  $$ select 1 from public.get_parties_near_user(23.7348, 37.9755, 500, 200, 'now')
     where party_id = 'ffffffff-0000-0000-0000-000000000007' $$,
  'a party with a stated end in the past is in no window at all'
);

select is_empty(
  $$ select 1 from public.get_parties_near_user(23.7348, 37.9755, 500, 200, 'now')
     where party_id = 'ffffffff-0000-0000-0000-000000000004' $$,
  'a party that has not started yet is not in Τώρα'
);

-- The forward windows.
select isnt_empty(
  $$ select 1 from public.get_parties_near_user(23.7348, 37.9755, 500, 200, 'tonight')
     where party_id = 'ffffffff-0000-0000-0000-000000000004' $$,
  'a party inside the tonight window is in Αργότερα απόψε'
);

select is_empty(
  $$ select 1 from public.get_parties_near_user(23.7348, 37.9755, 500, 200, 'tonight')
     where party_id = 'ffffffff-0000-0000-0000-000000000001' $$,
  'a party already under way is NOT in Αργότερα απόψε -- that is Τώρα''s job'
);

select is_empty(
  $$ select 1 from public.get_parties_near_user(23.7348, 37.9755, 500, 200, 'tonight')
     where party_id = 'ffffffff-0000-0000-0000-000000000003' $$,
  'and neither is the 20-day-old null-ends_at party -- the forward windows '
  'never touch ends_at, so the null case cannot reach them'
);

select isnt_empty(
  $$ select 1 from public.get_parties_near_user(23.7348, 37.9755, 500, 200, 'weekend')
     where party_id = 'ffffffff-0000-0000-0000-000000000005' $$,
  'a party inside the weekend window is in Το ΣΚ'
);

-- The default really is 'all', not merely similar to it.
select results_eq(
  $$ select party_id from public.get_parties_near_user(23.7348, 37.9755, 500)
     order by party_id $$,
  $$ select party_id from public.get_parties_near_user(23.7348, 37.9755, 500, 200, 'all')
     order by party_id $$,
  'the three-argument call and an explicit ''all'' return the same set -- the '
  'default really is ''all'', not merely similar to it'
);

-- A WINDOW NARROWS. IT NEVER WIDENS.
select is_empty(
  $$ select 1 from public.get_parties_near_user(23.7348, 37.9755, 500, 200, 'tonight')
     where party_id = 'ffffffff-0000-0000-0000-000000000006' $$,
  'second_host''s PRIVATE party stays invisible to a stranger inside a window '
  '-- the time filter composes with visibility, it does not replace it'
);

-- ZOOM AND TIME ARE INDEPENDENT, AND BOTH NARROW.
select isnt_empty(
  $$ select 1 from public.get_parties_near_user(23.7348, 37.9755, 500, 200, 'tonight')
     where party_id = 'ffffffff-0000-0000-0000-000000000004' $$,
  'the standard-tier tonight party is visible zoomed in'
);
select is_empty(
  $$ select 1 from public.get_parties_near_user(23.7348, 37.9755, 500000, 200, 'tonight')
     where party_id = 'ffffffff-0000-0000-0000-000000000004' $$,
  'and gone at the 500km tier, which admits only mega/sponsored -- the tier '
  'case still applies with a window set'
);

select throws_ok(
  $$ select 1 from public.get_parties_near_user(23.7348, 37.9755, 500, 200, 'tomorrow') $$,
  '22023',
  'unknown party time window: tomorrow',
  'an unrecognised window fails at the RPC too, rather than falling back to all'
);


-- ============================================================
-- 6. Structural tripwires
--
-- The mechanism these protect is invisible in a result set: every assertion
-- above passes just as happily against a query that is 20x slower, because
-- the leaky spelling returns exactly the same rows.
-- ============================================================

reset role;

select isnt_empty(
  $$ select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'get_parties_near_user'
       and p.prosrc like '%party_time_window%' $$,
  'the map query calls party_time_window -- the windows are not a second copy '
  'of the calendar rules inlined into the RPC'
);

select isnt_empty(
  $$ select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'get_parties_near_user'
       and p.prosrc like '%party_end_grace%' $$,
  'and reads the grace from the shared helper rather than restating 6 hours'
);

-- THE LEAKY SPELLING. `starts_at + interval` puts a Var under
-- timestamptz_pl_interval, which is not leakproof, which drags the term behind
-- the RLS barrier and costs ~20x for an identical result. It is what anyone
-- would write first.
--
-- Matched against the body with `--` comments STRIPPED. The comment beside
-- that predicate spells the leaky form out in full precisely so the next
-- person does not rediscover it, and a naive prosrc LIKE would fail on the
-- warning rather than on the mistake.
select is_empty(
  $$ select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'get_parties_near_user'
       and regexp_replace(p.prosrc, '--[^
]*', '', 'g') like '%starts_at +%' $$,
  'the grace is on the CONSTANT side (now() - grace), never on the row side '
  '(starts_at + grace) -- identical rows, ~20x apart (gotcha 22)'
);

select is_empty(
  $$ select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'get_parties_near_user'
       and regexp_replace(p.prosrc, '--[^
]*', '', 'g') like '%party_is_past%' $$,
  'and the map still does not CALL party_is_past -- it carries a SET clause, so '
  'it can never be inlined and stays a non-leakproof call behind the barrier'
);

-- The old four-argument function is gone rather than overloaded. Two functions
-- differing only in defaulted parameters make the four-argument call ambiguous,
-- and PostgREST resolves by name.
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'get_parties_near_user'),
  1,
  'there is exactly ONE get_parties_near_user -- the 4-arg version was dropped, '
  'not left behind as an ambiguous overload'
);


select * from finish();
rollback;
