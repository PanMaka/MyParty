-- Phase 39: the host dashboard (20261014113213) and editing, cancelling and
-- re-covering a party (20261014113214).
--
-- What has to hold:
--
--   A. Shape: the definers are definers with a pinned search_path; the guest
--      list is invoker, so the existing block rules decide who is listed.
--   B. Only the host gets anything. An invited guest who can SEE the party,
--      a stranger, and anon are all refused -- the guest is the headline case,
--      because refusing someone who cannot see the party proves nothing about
--      the host rule.
--   C. The numbers are right: counters (private ones included), the
--      follower split in the RIGHT direction (gotcha 14), the history the
--      trigger writes, and the timeline built from it.
--   D. The guest list: tabs, the follows_host flag, keyset paging, and a
--      block-paired guest hidden while the numbers still count them.
--   E. party_host:{uuid}: the host can join, nobody else can, the payload is
--      a signal, and the parsers cannot admit each other's channels.
--   F. Editing: direct UPDATE/DELETE are gone, update_party is host-only and
--      changes only what it lists.
--   G. Cancelling: host-only, one-way, and the party leaves get_party.
--   H. Replacing a cover: fresh keys, the path check, the bytes check, and the
--      stale-object list the edge function deletes.
--
-- Fixtures are built here rather than borrowed from seed.sql, so the expected
-- numbers are readable on this page. Personas: host 1111, invitee 2222,
-- stranger 4444, second_host 6666; crowd 0c0c...01-04.
begin;
set search_path to public, extensions;
select plan(85);


-- ===========================================================================
-- Fixtures (as postgres)
-- ===========================================================================
--   P  dddd...0001  public,  host 1111, starts in 2 days
--   Q  dddd...0002  private, host 1111, starts in 3 days
--   R  dddd...0003  public,  host 1111, hand-written hourly history
--   S  dddd...0004  public,  host 1111, ended in January, hand-written history
insert into public.parties (id, host_id, title, location, starts_at, ends_at, is_private) values
  ('dddddddd-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'Dashboard Public', st_point(23.73, 37.97)::geography, now() + interval '2 days', null, false),
  ('dddddddd-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'Dashboard Private', st_point(23.73, 37.97)::geography, now() + interval '3 days', null, true),
  ('dddddddd-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   'Dashboard Hourly', st_point(23.73, 37.97)::geography, now() + interval '1 day', null, false),
  ('dddddddd-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111',
   'Dashboard January', st_point(23.73, 37.97)::geography,
   '2026-01-01 20:00+00', '2026-01-06 04:00+00', false);

-- A controlled follow graph around the host: c1 and c2 follow the host; the
-- HOST follows c3 -- the wrong direction, which must not count as a follower.
delete from public.follows
where followee_id = '11111111-1111-1111-1111-111111111111'
   or follower_id = '11111111-1111-1111-1111-111111111111';
insert into public.follows (follower_id, followee_id) values
  ('0c0c0c0c-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111'),
  ('0c0c0c0c-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111'),
  ('11111111-1111-1111-1111-111111111111', '0c0c0c0c-0000-0000-0000-000000000003');

-- P: 3 going (c1, c3, invitee), 2 interested-only (c2, c4) -> interested 5.
insert into public.rsvps (party_id, user_id, status, created_at) values
  ('dddddddd-0000-0000-0000-000000000001', '0c0c0c0c-0000-0000-0000-000000000001', 'going',      now() - interval '5 minutes'),
  ('dddddddd-0000-0000-0000-000000000001', '0c0c0c0c-0000-0000-0000-000000000002', 'interested', now() - interval '4 minutes'),
  ('dddddddd-0000-0000-0000-000000000001', '0c0c0c0c-0000-0000-0000-000000000003', 'going',      now() - interval '3 minutes'),
  ('dddddddd-0000-0000-0000-000000000001', '0c0c0c0c-0000-0000-0000-000000000004', 'interested', now() - interval '2 minutes'),
  ('dddddddd-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'going',      now() - interval '1 minute');

-- Q: invitee is invited and coming.
insert into public.invitations (party_id, guest_id) values
  ('dddddddd-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222');
insert into public.rsvps (party_id, user_id, status) values
  ('dddddddd-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'going');

-- 0013 (second_host's, host 1111 invited): one rsvp, so its host topic HAS a
-- signal on it and "host 1111 cannot join it" is not trivially empty.
insert into public.rsvps (party_id, user_id, status) values
  ('aaaaaaaa-0000-0000-0000-000000000013', '0c0c0c0c-0000-0000-0000-000000000001', 'going');

-- R: an hourly history written directly. T0 is five hours ago, on the hour.
--   T0     +1 going, +1 interested
--   T0+2h  +1 interested
--   T0+3h  -1 going (a flip to interested)
create temp table t0 on commit drop as
select date_trunc('hour', now()) - interval '5 hours' as at;
grant select on t0 to authenticated;
insert into public.rsvp_count_events (party_id, occurred_at, going_delta, interested_delta)
select 'dddddddd-0000-0000-0000-000000000003', t0.at + d.off, d.g, d.i
from t0, (values (interval '0 hours', 1, 1), (interval '2 hours', 0, 1), (interval '3 hours', -1, 0)) d(off, g, i);

-- S: two rsvps on the night of 1 January, 21:30 and 23:30 UTC.
insert into public.rsvp_count_events (party_id, occurred_at, going_delta, interested_delta) values
  ('dddddddd-0000-0000-0000-000000000004', '2026-01-01 21:30+00', 1, 1),
  ('dddddddd-0000-0000-0000-000000000004', '2026-01-01 23:30+00', 1, 1);


-- ===========================================================================
-- A. Shape
-- ===========================================================================
select is(
  (select array_agg(p.proname::text order by p.proname) from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prosecdef
     and p.proname in ('get_party_host_stats', 'get_party_rsvp_timeline', 'update_party',
                       'cancel_party', 'party_cover_replace_target',
                       'confirm_party_cover_replacement', 'party_cover_stale_objects')
     and 'search_path=""' = any(p.proconfig)),
  array['cancel_party', 'confirm_party_cover_replacement', 'get_party_host_stats',
        'get_party_rsvp_timeline', 'party_cover_replace_target',
        'party_cover_stale_objects', 'update_party'],
  'the seven new definers are SECURITY DEFINER with an empty search_path (CLAUDE.md #3)'
);

select is(
  (select prosecdef from pg_proc
   where oid = 'public.get_party_guests(uuid,boolean,timestamptz,uuid,integer)'::regprocedure),
  false,
  'get_party_guests is INVOKER -- the rsvps and profiles policies decide who is listed'
);

select is(
  (select relrowsecurity from pg_class where oid = 'public.rsvp_count_events'::regclass),
  true,
  'rsvp_count_events has RLS on'
);

select is_empty(
  $$ select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'rsvp_count_events'
       and column_name = 'user_id' $$,
  'rsvp_count_events stores no user_id -- the chart needs the counters'' history, not anybody''s'
);


-- ===========================================================================
-- B. Only the host
-- ===========================================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select lives_ok(
  $$ select * from public.get_party_host_stats('dddddddd-0000-0000-0000-000000000001') $$,
  'the host can read their party''s stats');
select lives_ok(
  $$ select * from public.get_party_rsvp_timeline('dddddddd-0000-0000-0000-000000000001') $$,
  'the host can read its timeline');
select lives_ok(
  $$ select * from public.get_party_guests('dddddddd-0000-0000-0000-000000000001') $$,
  'the host can read its guest list');
select throws_ok(
  $$ select * from public.rsvp_count_events $$,
  '42501', null,
  'not even the host reads rsvp_count_events directly -- the timeline is the only door');

-- Host of 0013 is second_host; host 1111 is only INVITED there and can see it.
select throws_ok(
  $$ select * from public.get_party_host_stats('aaaaaaaa-0000-0000-0000-000000000013') $$,
  '42501', null,
  'being invited to someone else''s party does not make you its host');

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee, going on P

select ok(
  exists (select 1 from public.parties where id = 'dddddddd-0000-0000-0000-000000000001'),
  'CONTROL: the invitee can see party P -- so the refusals below are the host rule, not visibility');
select throws_ok(
  $$ select * from public.get_party_host_stats('dddddddd-0000-0000-0000-000000000001') $$,
  '42501', null, 'a guest who is going still cannot read the stats');
select throws_ok(
  $$ select * from public.get_party_rsvp_timeline('dddddddd-0000-0000-0000-000000000001') $$,
  '42501', null, 'nor the timeline');
select throws_ok(
  $$ select * from public.get_party_guests('dddddddd-0000-0000-0000-000000000001') $$,
  '42501', null, 'nor the guest list -- not even reduced to their own row');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select throws_ok(
  $$ select * from public.get_party_host_stats('dddddddd-0000-0000-0000-000000000001') $$,
  '42501', null, 'a stranger cannot read the stats');
select throws_ok(
  $$ select * from public.get_party_rsvp_timeline('dddddddd-0000-0000-0000-000000000001') $$,
  '42501', null, 'nor the timeline');
select throws_ok(
  $$ select * from public.get_party_guests('dddddddd-0000-0000-0000-000000000001') $$,
  '42501', null, 'nor the guest list');

select tests.clear_authentication(); -- anon

select throws_ok(
  $$ select * from public.get_party_host_stats('dddddddd-0000-0000-0000-000000000001') $$,
  '42501', null, 'signed out: no stats');
select throws_ok(
  $$ select * from public.get_party_rsvp_timeline('dddddddd-0000-0000-0000-000000000001') $$,
  '42501', null, 'signed out: no timeline');
select throws_ok(
  $$ select * from public.get_party_guests('dddddddd-0000-0000-0000-000000000001') $$,
  '42501', null, 'signed out: no guest list');


-- ===========================================================================
-- C. The numbers
-- ===========================================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select results_eq(
  $$ select going_count, interested_count,
            going_followers, going_non_followers,
            interested_followers, interested_non_followers
     from public.get_party_host_stats('dddddddd-0000-0000-0000-000000000001') $$,
  $$ values (3, 5, 1, 2, 2, 3) $$,
  'P: 3 going, 5 interested (the superset); followers c1 (going) and c2 (interested)'
);

-- Gotcha 14: the host follows c3, c3 is going. If the join ran the wrong way
-- round, c3 would be the going follower and c1 would not -- going_followers
-- would still be 1. So the direction is asserted on the interested side too,
-- where the wrong join gives 1 (c3) and the right one gives 2 (c1, c2).
select is(
  (select interested_followers from public.get_party_host_stats('dddddddd-0000-0000-0000-000000000001')),
  2,
  'THE DIRECTION: a follower is someone who follows the HOST -- the host following c3 does not make c3 one'
);

select results_eq(
  $$ select title, is_private, status::text, is_live, is_over
     from public.get_party_host_stats('dddddddd-0000-0000-0000-000000000001') $$,
  $$ values ('Dashboard Public'::text, false, 'published'::text, false, false) $$,
  'the header fields: title, privacy, status, and upcoming = neither live nor over'
);

select results_eq(
  $$ select going_count, interested_count
     from public.get_party_host_stats('dddddddd-0000-0000-0000-000000000002') $$,
  $$ values (1, 1) $$,
  'Q (private): the host gets the real counters -- 1 coming'
);

select is(
  (select going_count from public.get_party('dddddddd-0000-0000-0000-000000000002')),
  null,
  'CONTROL: get_party still NULLs them, for the host too -- the dashboard is the one place they are answered'
);

select is(
  (select is_over from public.get_party_host_stats('dddddddd-0000-0000-0000-000000000004')),
  true,
  'S, which ended in January, is over -- and its host still gets a dashboard, unlike get_party'
);

-- The history the trigger wrote for P, read as postgres.
reset role;

select results_eq(
  $$ select count(*)::int, sum(going_delta)::int, sum(interested_delta)::int
     from public.rsvp_count_events where party_id = 'dddddddd-0000-0000-0000-000000000001' $$,
  $$ values (5, 3, 5) $$,
  'five rsvps wrote five events, and they sum to the counters'
);

-- A flip and a withdrawal.
update public.rsvps set status = 'interested'
where party_id = 'dddddddd-0000-0000-0000-000000000001'
  and user_id = '0c0c0c0c-0000-0000-0000-000000000003';

select results_eq(
  $$ select going_delta::int, interested_delta::int from public.rsvp_count_events
     where party_id = 'dddddddd-0000-0000-0000-000000000001'
     order by id desc limit 1 $$,
  $$ values (-1, 0) $$,
  'a going -> interested flip records -1 going and 0 interested, exactly as the counter moved'
);

update public.rsvps set created_at = created_at
where party_id = 'dddddddd-0000-0000-0000-000000000001'
  and user_id = '0c0c0c0c-0000-0000-0000-000000000001';

select is(
  (select count(*)::int from public.rsvp_count_events
   where party_id = 'dddddddd-0000-0000-0000-000000000001'),
  6,
  'an UPDATE that does not change the status writes no event'
);

delete from public.rsvps
where party_id = 'dddddddd-0000-0000-0000-000000000001'
  and user_id = '22222222-2222-2222-2222-222222222222';

select results_eq(
  $$ select going_delta::int, interested_delta::int from public.rsvp_count_events
     where party_id = 'dddddddd-0000-0000-0000-000000000001'
     order by id desc limit 1 $$,
  $$ values (-1, -1) $$,
  'withdrawing a going rsvp records -1 going and -1 interested'
);

select results_eq(
  $$ select p.going_count, p.interested_count from public.parties p
     where p.id = 'dddddddd-0000-0000-0000-000000000001' $$,
  $$ select sum(going_delta)::int, sum(interested_delta)::int from public.rsvp_count_events
     where party_id = 'dddddddd-0000-0000-0000-000000000001' $$,
  'after the flip and the withdrawal, the history still sums to the counters'
);

-- Put the invitee back as going for the sections below (P: 2 going, 5 interested).
insert into public.rsvps (party_id, user_id, status, created_at) values
  ('dddddddd-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'going', now() - interval '1 minute');

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

-- Timeline on P: every event happened inside this transaction, so it is one
-- hourly bucket holding the current counters.
select results_eq(
  $$ select bucket::text, going, interested
     from public.get_party_rsvp_timeline('dddddddd-0000-0000-0000-000000000001') $$,
  $$ values ('hour'::text, 2, 5) $$,
  'P''s timeline: one hourly bucket, ending on the current counters'
);

-- R: T0..T0+5h, gaps filled, cumulative.
select results_eq(
  $$ select bucket_start - (select at from t0), going, interested
     from public.get_party_rsvp_timeline('dddddddd-0000-0000-0000-000000000003') $$,
  $$ values (interval '0 hours', 1, 1), (interval '1 hour', 1, 1), (interval '2 hours', 1, 2),
            (interval '3 hours', 0, 2), (interval '4 hours', 0, 2), (interval '5 hours', 0, 2) $$,
  'R''s timeline: cumulative per hour, empty hours carried flat, the flip drops going only'
);

-- S: span past 72h, so daily by default; runs to ends_at (6 January).
select results_eq(
  $$ select bucket_start, bucket::text, going, interested
     from public.get_party_rsvp_timeline('dddddddd-0000-0000-0000-000000000004')
     limit 2 $$,
  $$ values ('2026-01-01 00:00+00'::timestamptz, 'day'::text, 2, 2),
            ('2026-01-02 00:00+00'::timestamptz, 'day'::text, 2, 2) $$,
  'S''s timeline: daily by default for a span over 72h, both rsvps on 1 January in UTC'
);

select is(
  (select count(*)::int from public.get_party_rsvp_timeline('dddddddd-0000-0000-0000-000000000004')),
  6,
  'and it runs to the day the party ended, 1-6 January'
);

-- At UTC+2 the 23:30 rsvp is on 2 January.
select results_eq(
  $$ select bucket_start, going
     from public.get_party_rsvp_timeline('dddddddd-0000-0000-0000-000000000004', 'day', 120)
     limit 2 $$,
  $$ values ('2025-12-31 22:00+00'::timestamptz, 1),
            ('2026-01-01 22:00+00'::timestamptz, 2) $$,
  'days are the host''s days: at UTC+2 the 23:30 UTC rsvp falls on 2 January'
);

select is(
  (select count(*)::int from public.get_party_rsvp_timeline('dddddddd-0000-0000-0000-000000000004', 'hour')),
  (select (extract(epoch from date_trunc('hour', timestamptz '2026-01-06 04:00+00')
                            - date_trunc('hour', timestamptz '2026-01-01 21:30+00')) / 3600)::int + 1),
  'an explicit hourly bucket overrides the default'
);

reset role;
insert into public.parties (id, host_id, title, location, starts_at, is_private) values
  ('dddddddd-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111',
   'Dashboard Empty', st_point(23.73, 37.97)::geography, now() + interval '4 days', false);
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');

select is_empty(
  $$ select * from public.get_party_rsvp_timeline('dddddddd-0000-0000-0000-000000000005') $$,
  'a party with no rsvps has no timeline rows -- the client draws its empty state'
);


-- ===========================================================================
-- D. The guest list
-- ===========================================================================
select is(
  (select count(*)::int from public.get_party_guests('dddddddd-0000-0000-0000-000000000001', true)),
  2,
  'the Going tab lists the 2 going guests'
);

select is(
  (select count(*)::int from public.get_party_guests('dddddddd-0000-0000-0000-000000000001', false)),
  5,
  'the Interested tab lists all 5 -- going included, so it matches the headline'
);

select results_eq(
  $$ select user_id, follows_host from public.get_party_guests('dddddddd-0000-0000-0000-000000000001')
     where user_id in ('0c0c0c0c-0000-0000-0000-000000000001', '0c0c0c0c-0000-0000-0000-000000000003')
     order by user_id $$,
  $$ values ('0c0c0c0c-0000-0000-0000-000000000001'::uuid, true),
            ('0c0c0c0c-0000-0000-0000-000000000003'::uuid, false) $$,
  'follows_host: c1 follows the host; c3 is followed BY the host, which is not the same thing'
);

select results_eq(
  $$ select user_id from public.get_party_guests('dddddddd-0000-0000-0000-000000000001', false, null, null, 2) $$,
  $$ values ('22222222-2222-2222-2222-222222222222'::uuid), ('0c0c0c0c-0000-0000-0000-000000000004'::uuid) $$,
  'newest first, page of 2'
);

select results_eq(
  $$ select g.user_id from public.get_party_guests(
       'dddddddd-0000-0000-0000-000000000001', false,
       (select created_at from public.get_party_guests('dddddddd-0000-0000-0000-000000000001', false, null, null, 2) offset 1 limit 1),
       '0c0c0c0c-0000-0000-0000-000000000004', 2) g $$,
  $$ values ('0c0c0c0c-0000-0000-0000-000000000003'::uuid), ('0c0c0c0c-0000-0000-0000-000000000002'::uuid) $$,
  'the keyset cursor continues exactly where the first page stopped'
);

-- The host blocks c4. The list drops them; the numbers do not.
insert into public.blocks (blocker_id, blocked_id)
values ('11111111-1111-1111-1111-111111111111', '0c0c0c0c-0000-0000-0000-000000000004');

select is(
  (select count(*)::int from public.get_party_guests('dddddddd-0000-0000-0000-000000000001')),
  4,
  'a block-paired guest leaves the guest list'
);

select is(
  (select interested_count from public.get_party_host_stats('dddddddd-0000-0000-0000-000000000001')),
  5,
  'and is still counted -- the headline is a number, not a list of names'
);


-- ===========================================================================
-- E. party_host:{uuid}
-- ===========================================================================
-- The fixture writes above put rsvp_activity rows on P's host topic.
select set_config('realtime.topic', 'party_host:dddddddd-0000-0000-0000-000000000001', true);

select isnt_empty(
  $$ select 1 from realtime.messages
     where topic = 'party_host:dddddddd-0000-0000-0000-000000000001' and event = 'rsvp_activity' $$,
  'the host can join their party''s host topic and sees the signal'
);

select is(
  (select array_agg(distinct k order by k) from realtime.messages m, jsonb_object_keys(m.payload - 'id') k
   where m.topic = 'party_host:dddddddd-0000-0000-0000-000000000001' and m.event = 'rsvp_activity'),
  array['party_id'],
  'the payload is the party id and nothing else -- no user, no status'
);

select set_config('realtime.topic', 'party_host:aaaaaaaa-0000-0000-0000-000000000013', true);
select is_empty(
  $$ select 1 from realtime.messages where topic = 'party_host:aaaaaaaa-0000-0000-0000-000000000013' $$,
  'the host cannot join the host topic of a party they are only invited to'
);

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee
select set_config('realtime.topic', 'party_host:dddddddd-0000-0000-0000-000000000001', true);
select is_empty(
  $$ select 1 from realtime.messages where topic = 'party_host:dddddddd-0000-0000-0000-000000000001' $$,
  'a guest who is going cannot join the host topic'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger
select set_config('realtime.topic', 'party_host:dddddddd-0000-0000-0000-000000000001', true);
select is_empty(
  $$ select 1 from realtime.messages where topic = 'party_host:dddddddd-0000-0000-0000-000000000001' $$,
  'a stranger cannot join the host topic'
);

select tests.clear_authentication();
select set_config('realtime.topic', 'party_host:dddddddd-0000-0000-0000-000000000001', true);
select is_empty(
  $$ select 1 from realtime.messages where topic = 'party_host:dddddddd-0000-0000-0000-000000000001' $$,
  'signed out: no host topic'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host
select set_config('realtime.topic', 'party_host:not-a-uuid', true);
select is_empty($$ select 1 from realtime.messages $$, 'a malformed host topic denies rather than errors');

select set_config('realtime.topic', 'party_host:dddddddd-0000-0000-0000-000000000001-extra', true);
select is_empty($$ select 1 from realtime.messages $$, 'a host topic with trailing junk denies');

select is(
  public.party_id_from_host_topic(public.party_host_topic('dddddddd-0000-0000-0000-000000000001')),
  'dddddddd-0000-0000-0000-000000000001'::uuid,
  'the host topic builder and parser agree'
);
select is(
  public.party_id_from_topic('party_host:dddddddd-0000-0000-0000-000000000001'),
  null,
  'a host topic is not a party chat topic -- the chat policy cannot admit it'
);
select is(
  public.party_id_from_host_topic('party:dddddddd-0000-0000-0000-000000000001'),
  null,
  'a party chat topic is not a host topic -- this policy cannot admit a chat channel'
);
select is(
  public.party_id_from_host_topic('inbox:11111111-1111-1111-1111-111111111111'),
  null,
  'nor an inbox'
);

select throws_ok(
  $$ insert into realtime.messages (topic, extension, event, private, payload)
     values ('party_host:dddddddd-0000-0000-0000-000000000001', 'broadcast', 'rsvp_activity', true,
             '{"party_id":"forged"}'::jsonb) $$,
  '42501', null,
  'nobody can forge a host signal -- the trigger is the only writer'
);


-- ===========================================================================
-- F. Editing
-- ===========================================================================
select throws_ok(
  $$ update public.parties set going_count = 9999
     where id = 'dddddddd-0000-0000-0000-000000000001' $$,
  '42501', null,
  'THE HOLE THIS CLOSES: a host can no longer PATCH their own counters'
);
select throws_ok(
  $$ delete from public.parties where id = 'dddddddd-0000-0000-0000-000000000001' $$,
  '42501', null,
  'nor hard-delete their party -- cancelling is the soft equivalent'
);

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee
select throws_ok(
  $$ select public.update_party('dddddddd-0000-0000-0000-000000000001', 'Mine now', null, null,
       now() + interval '2 days', null, 37.97, 23.73) $$,
  '42501', null, 'a guest cannot edit the party');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger
select throws_ok(
  $$ select public.update_party('dddddddd-0000-0000-0000-000000000001', 'Mine now', null, null,
       now() + interval '2 days', null, 37.97, 23.73) $$,
  '42501', null, 'a stranger cannot edit the party');

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host
select throws_ok(
  $$ select public.update_party('dddddddd-0000-0000-0000-000000000001', '   ', null, null,
       now() + interval '2 days', null, 37.97, 23.73) $$,
  '22023', null, 'a blank title is refused');
select throws_ok(
  $$ select public.update_party('dddddddd-0000-0000-0000-000000000001', 'Edited', null, null,
       now() + interval '2 days', now() + interval '1 day', 37.97, 23.73) $$,
  '22023', null, 'an end before the start is refused');
select throws_ok(
  $$ select public.update_party('dddddddd-0000-0000-0000-000000000001', 'Edited', null, null,
       now() + interval '2 days', null, 91, 23.73) $$,
  '22023', null, 'a latitude off the planet is refused');

select lives_ok(
  $$ select public.update_party('dddddddd-0000-0000-0000-000000000001', '  Edited Title  ',
       'New description', 'Ψυρρή', now() + interval '5 days', now() + interval '5 days 6 hours',
       37.98, 23.72) $$,
  'the host edits their party');

select results_eq(
  $$ select title, description, area, going_count, interested_count, is_private,
            round(st_y(location::geometry)::numeric, 2)
     from public.get_party_host_stats('dddddddd-0000-0000-0000-000000000001')
     cross join lateral (select location from public.parties where id = 'dddddddd-0000-0000-0000-000000000001') l $$,
  $$ values ('Edited Title'::text, 'New description'::text, 'Ψυρρή'::text, 2, 5, false, 37.98::numeric) $$,
  'the edit landed (title trimmed, location moved), and the counters and privacy did not move'
);


-- ===========================================================================
-- G. Cancelling
-- ===========================================================================
select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee
select throws_ok(
  $$ select public.cancel_party('dddddddd-0000-0000-0000-000000000001') $$,
  '42501', null, 'a guest cannot cancel the party');

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host
select lives_ok(
  $$ select public.cancel_party('dddddddd-0000-0000-0000-000000000001') $$,
  'the host cancels their party');

select is_empty(
  $$ select 1 from public.get_party('dddddddd-0000-0000-0000-000000000001') $$,
  'a cancelled party is gone from get_party -- the link stops opening it'
);

select is(
  (select status::text from public.get_party_host_stats('dddddddd-0000-0000-0000-000000000001')),
  'cancelled',
  'but the host''s dashboard still opens, and says so'
);

select throws_ok(
  $$ select public.cancel_party('dddddddd-0000-0000-0000-000000000001') $$,
  '42501', null, 'cancelling twice is refused -- there is no state to go to');
select throws_ok(
  $$ select public.update_party('dddddddd-0000-0000-0000-000000000001', 'Back from the dead', null, null,
       now() + interval '2 days', null, 37.97, 23.73) $$,
  '42501', null, 'and a cancelled party cannot be edited back to life');


-- ===========================================================================
-- H. Replacing a cover (on R, which is still published)
-- ===========================================================================
select matches(
  public.party_cover_replace_target('dddddddd-0000-0000-0000-000000000003'),
  '^dddddddd-0000-0000-0000-000000000003/[0-9a-f-]{36}$',
  'the host gets a fresh key in the party''s own folder'
);
select isnt(
  public.party_cover_replace_target('dddddddd-0000-0000-0000-000000000003'),
  public.party_cover_replace_target('dddddddd-0000-0000-0000-000000000003'),
  'a different key every time -- a replacement never overwrites'
);
select throws_ok(
  $$ select public.party_cover_replace_target('dddddddd-0000-0000-0000-000000000001') $$,
  '42501', null, 'no replacement for a cancelled party');

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee
select throws_ok(
  $$ select public.party_cover_replace_target('dddddddd-0000-0000-0000-000000000003') $$,
  '42501', null, 'a guest cannot replace the cover');
select throws_ok(
  $$ select * from public.party_cover_stale_objects('dddddddd-0000-0000-0000-000000000003') $$,
  '42501', null, 'nor ask which objects are stale');

-- The old cover (an hour old), the new upload, and an abandoned upload from
-- a minute ago -- the last one standing in for an upload still in flight.
reset role;
update public.parties set cover_path = 'dddddddd-0000-0000-0000-000000000003/cover'
where id = 'dddddddd-0000-0000-0000-000000000003';
insert into storage.objects (bucket_id, name, owner, created_at) values
  ('party-covers', 'dddddddd-0000-0000-0000-000000000003/cover',
   '11111111-1111-1111-1111-111111111111', now() - interval '1 hour'),
  ('party-covers', 'dddddddd-0000-0000-0000-000000000003/0e0e0e0e-0000-4000-8000-000000000001',
   '11111111-1111-1111-1111-111111111111', now() - interval '1 hour'),
  ('party-covers', 'dddddddd-0000-0000-0000-000000000003/0e0e0e0e-0000-4000-8000-000000000002',
   '11111111-1111-1111-1111-111111111111', now() - interval '1 minute');
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select throws_ok(
  $$ select public.confirm_party_cover_replacement('dddddddd-0000-0000-0000-000000000003',
       'dddddddd-0000-0000-0000-000000000003/0e0e0e0e-0000-4000-8000-00000000ffff') $$,
  'P0002', null, 'confirming a key with no bytes behind it is refused');
select throws_ok(
  $$ select public.confirm_party_cover_replacement('dddddddd-0000-0000-0000-000000000003',
       'dddddddd-0000-0000-0000-000000000001/0e0e0e0e-0000-4000-8000-000000000001') $$,
  '22023', null, 'a key in ANOTHER party''s folder is refused before storage is consulted');
select throws_ok(
  $$ select public.confirm_party_cover_replacement('dddddddd-0000-0000-0000-000000000003',
       'dddddddd-0000-0000-0000-000000000003/../aaaaaaaa-0000-0000-0000-000000000001/cover') $$,
  '22023', null, 'and so is a traversal out of the right one');

select lives_ok(
  $$ select public.confirm_party_cover_replacement('dddddddd-0000-0000-0000-000000000003',
       'dddddddd-0000-0000-0000-000000000003/0e0e0e0e-0000-4000-8000-000000000001') $$,
  'the host confirms the uploaded replacement');

select is(
  (select cover_path from public.get_party_host_stats('dddddddd-0000-0000-0000-000000000003')),
  'dddddddd-0000-0000-0000-000000000003/0e0e0e0e-0000-4000-8000-000000000001',
  'cover_path now points at the replacement'
);

select results_eq(
  $$ select * from public.party_cover_stale_objects('dddddddd-0000-0000-0000-000000000003') $$,
  $$ values ('dddddddd-0000-0000-0000-000000000003/cover'::text) $$,
  'stale = the replaced cover only: not the current one, and not a fresh upload that may still be in flight'
);


-- ===========================================================================
-- The FOUND guard: a hard delete (erasure's privilege) still works with rsvps
-- on the party, whose cascade fires the counter trigger for a party that is
-- already gone.
-- ===========================================================================
reset role;
select lives_ok(
  $$ delete from public.parties where id = 'dddddddd-0000-0000-0000-000000000002' $$,
  'a party with rsvps can still be hard-deleted -- the trigger writes no event for a party mid-delete'
);
select is_empty(
  $$ select 1 from public.rsvp_count_events where party_id = 'dddddddd-0000-0000-0000-000000000002' $$,
  'and its history went with it'
);

select * from finish();
rollback;
