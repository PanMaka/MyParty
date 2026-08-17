-- Phase 7b: the event-driven notification engine.
--
-- 7a proved that a location cannot be stored without consent, cannot be stored
-- precisely, and stops existing after 24h. This file proves the thing built on
-- top of it decides correctly WHO gets told about WHAT -- and, mostly, who does
-- not. Roughly two thirds of the assertions below are negative, because a
-- proximity notification is the one output of this system that reaches a person
-- who never asked a question: nobody opened a screen, nobody pulled to refresh.
-- The failure mode is not a wrong answer on a page, it is a phone buzzing on a
-- table with something it should not have said.
--
-- What is proved here:
--
--   1. THE OUTBOX IS CLOSED. notification_jobs is engine-internal -- RLS on,
--      no policies, no grants, and no TRUNCATE either. A pending job is
--      "this user is within 500m of this party", which is a location
--      disclosure with the coordinate filed off.
--   2. BOTH DIRECTIONS FIRE. Publishing a party notifies nearby users; moving
--      a device notifies it about nearby parties. Neither is the sweep.
--   3. THE PER-USER RADIUS IS THE REAL ANSWER. A party 2km away, well inside
--      the 5km constant that makes the GiST index usable, must NOT notify a
--      user whose preference is 500m. This is the assertion that fails if
--      someone ever "simplifies" the two-term spatial predicate down to the
--      indexable half.
--   4. THE GATES HOLD. Private parties, blocks, the host themselves, withheld
--      push consent, the nearby preference, a device with no location.
--   5. QUIET HOURS DEFER, THEY DO NOT DROP -- and they still claim the dedupe
--      row, whereas the daily cap deliberately does NOT, so a capped
--      notification survives for tomorrow.
--   6. DEBOUNCE. A second move inside the floor does not re-evaluate.
--   7. THE SWEEP IS A NET, NOT A DRAGNET. It re-enqueues what was lost and
--      ignores what is not its business.
--
-- Personas (seed.sql): host 1111, invitee 2222, friend_not_invited 3333,
-- stranger 4444, blocked_user 5555, second_host 6666.
--
-- Every persona used here is parked at a location more than 5km from every
-- other one -- Syntagma, Elefsina, Kifisia, Glyfada. That is not decoration:
-- 5000m is the engine's hard radius cap, so separating the personas by more
-- than that makes each section's party incapable of reaching another section's
-- user, and every count below can be read as a local fact.
--
-- seed.sql's 22 parties are all cancelled in setup for the same reason. They
-- cluster around Syntagma and would otherwise fan out to every device this file
-- registers, turning each assertion into arithmetic about the fixtures.
begin;
set search_path to public, extensions;
select plan(46);


-- Owner-level session. Needed for the same two things as in 08 -- backdating
-- derived columns, and reading/writing engine-internal tables -- plus, here,
-- suppressing triggers to simulate the events the safety net exists to catch.
create or replace function tests.become_owner()
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('role', 'postgres', true);
end;
$$;


-- ============================================================
-- Setup: an empty map, four consenting users, four distant cities.
-- ============================================================

-- Cancelling rather than deleting: parties has dependents, and the engine's
-- own filter is `status = 'published'`, so this exercises the real predicate.
-- Going to 'cancelled' fires no trigger -- parties_notify_on_publish requires
-- new.status = 'published'.
update public.parties set status = 'cancelled';

update public.profiles
set location_consent = true,
    push_consent     = true,
    notify_nearby    = true,
    notification_tz  = 'UTC'
where id in (
  '22222222-2222-2222-2222-222222222222',  -- invitee   -> quiet hours
  '33333333-3333-3333-3333-333333333333',  -- friend    -> daily cap
  '44444444-4444-4444-4444-444444444444',  -- stranger  -> fan-out
  '66666666-6666-6666-6666-666666666666'   -- 2nd host  -> fan-in / debounce
);

-- UTC everywhere so the quiet-hours arithmetic below cannot be knocked off by
-- a DST transition in Europe/Athens on the day the suite happens to run.

insert into public.user_devices (id, user_id, push_token, platform, last_location) values
  ('eeeeeeee-0000-0000-0000-000000000004',
   '44444444-4444-4444-4444-444444444444', 'tok-stranger', 'ios',
   st_point(23.7351, 37.9758)::geography),   -- Syntagma
  ('eeeeeeee-0000-0000-0000-000000000002',
   '22222222-2222-2222-2222-222222222222', 'tok-invitee', 'ios',
   st_point(23.5400, 38.0400)::geography),   -- Elefsina, ~18km W
  ('eeeeeeee-0000-0000-0000-000000000003',
   '33333333-3333-3333-3333-333333333333', 'tok-friend', 'android',
   st_point(23.8103, 38.0742)::geography);   -- Kifisia, ~13km NE

-- second_host gets no device yet: the fan-in section needs a party to already
-- exist before the device appears, or the publish trigger would do the work
-- the movement trigger is supposed to be proving.


-- ============================================================
-- 1. The outbox is closed.
-- ============================================================

select is(
  (select relrowsecurity from pg_class where oid = 'public.notification_jobs'::regclass),
  true,
  'RLS is enabled on notification_jobs'
);

select is(
  (select bool_or(has_table_privilege(r, 'public.notification_jobs', p))
   from unnest(array['anon', 'authenticated']) r,
        unnest(array['select', 'insert', 'update', 'delete']) p),
  false,
  'neither client role holds any data privilege on notification_jobs'
);

-- The privileges nobody granted. Supabase's default ACL hands anon and
-- authenticated TRUNCATE, REFERENCES, TRIGGER and MAINTAIN on every new table
-- in public, and RLS mediates none of them -- an RLS-perfect queue that anon
-- can empty is not a protected queue.
select is(
  (select bool_or(has_table_privilege(r, 'public.notification_jobs', p))
   from unnest(array['anon', 'authenticated']) r,
        unnest(array['truncate', 'references', 'trigger']) p),
  false,
  'and cannot TRUNCATE, reference or trigger it either -- the default ACL is revoked'
);

-- 7a asserted this too. It is repeated here because THIS is the phase that
-- would have broken it: the obvious way to write a movement debounce is to
-- store the point the user was last evaluated at, and that would be a third
-- geography column under no retention rule at all. The debounce reuses the
-- ~100m cell instead, and this is what keeps that decision from being quietly
-- reversed.
select is(
  (select array_agg(c.relname || '.' || a.attname order by c.relname, a.attname)
   from pg_attribute a
   join pg_class c on c.oid = a.attrelid
   join pg_namespace n on n.oid = c.relnamespace
   join pg_type t on t.oid = a.atttypid
   where n.nspname = 'public'
   and c.relkind = 'r'
   and a.attnum > 0
   and not a.attisdropped
   and t.typname = 'geography'),
  array['parties.location', 'user_devices.last_location'],
  'still exactly two geography columns -- the debounce did not add a third'
);

select is(
  (select schedule || ' active=' || active::text
   from cron.job where jobname = 'nearby-notification-sweep'),
  '0 * * * * active=true',
  'the safety-net sweep is scheduled hourly and active'
);


-- ============================================================
-- 2. Fan out: a party is published, nearby users are enqueued.
-- ============================================================
insert into public.parties (id, host_id, title, location, starts_at, is_private, status) values
  ('cccccccc-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111',
   'Syntagma Popup', st_point(23.7352, 37.9759)::geography,
   now() + interval '5 hours', false, 'published');

select is(
  (select count(*)::int from public.notification_jobs
   where party_id = 'cccccccc-0000-0000-0000-000000000001'),
  1,
  'publishing a public party enqueues a job for the one user standing next to it'
);

select is(
  (select user_id from public.notification_jobs
   where party_id = 'cccccccc-0000-0000-0000-000000000001'),
  '44444444-4444-4444-4444-444444444444'::uuid,
  'and it is the nearby user, not one of the three parked 13km away'
);

select ok(
  (select scheduled_for <= now() + interval '1 second'
   from public.notification_jobs
   where party_id = 'cccccccc-0000-0000-0000-000000000001'),
  'outside quiet hours the job is deliverable immediately'
);

-- A deferred job for a party that already started is worse than no job at all,
-- so every job carries the deadline that makes dropping it possible.
select is(
  (select j.expires_at = p.starts_at
   from public.notification_jobs j
   join public.parties p on p.id = j.party_id
   where j.party_id = 'cccccccc-0000-0000-0000-000000000001'),
  true,
  'the job expires when the party starts'
);

select is(
  (select count(*)::int from public.sent_notifications
   where party_id = 'cccccccc-0000-0000-0000-000000000001'
   and kind = 'nearby_party'),
  1,
  'and the dedupe claim was written alongside it'
);

-- The publish trigger, the movement trigger and the hourly sweep all race for
-- this row by design. 23505 on the unique constraint is how the losers find out.
select is(
  public.enqueue_nearby_party_notifications('cccccccc-0000-0000-0000-000000000001'),
  0,
  're-running the enqueue adds nothing -- dedupe is the constraint, not a check'
);


-- ============================================================
-- 3. The per-user radius is the answer; the 5km constant is only plumbing.
--
-- This party is ~2km from the stranger: comfortably inside the constant
-- st_dwithin term that makes the GiST index usable, and four times outside
-- their 500m preference. If the exact term were ever dropped as redundant,
-- this is the assertion that would catch it -- and the symptom in production
-- would be every user silently receiving a 5km radius.
-- ============================================================
insert into public.parties (id, host_id, title, location, starts_at, is_private, status) values
  ('cccccccc-0000-0000-0000-000000000002',
   '11111111-1111-1111-1111-111111111111',
   'Two Kilometres Away', st_point(23.7581, 37.9758)::geography,
   now() + interval '5 hours', false, 'published');

select is(
  (select count(*)::int from public.notification_jobs
   where party_id = 'cccccccc-0000-0000-0000-000000000002'),
  0,
  'a party 2km away does not reach a user whose radius is 500m, though it is inside the 5km index term'
);

-- The same party, once the user asks for a wider radius. Without this the
-- assertion above would also pass on an engine that notifies nobody at all.
update public.profiles set notify_radius_meters = 5000
where id = '44444444-4444-4444-4444-444444444444';

select is(
  public.enqueue_nearby_party_notifications('cccccccc-0000-0000-0000-000000000002'),
  1,
  'and does reach them once they widen their radius -- the filter is the preference, not a dead branch'
);

update public.profiles set notify_radius_meters = 500
where id = '44444444-4444-4444-4444-444444444444';


-- ============================================================
-- 4. The gates.
-- ============================================================

-- A proximity ping about a private party would tell a lock screen -- and
-- anyone glancing at it -- that its owner is standing near a party whose whole
-- design is that it is not discoverable.
insert into public.parties (id, host_id, title, location, starts_at, is_private, status) values
  ('cccccccc-0000-0000-0000-000000000003',
   '11111111-1111-1111-1111-111111111111',
   'Private Next Door', st_point(23.7352, 37.9759)::geography,
   now() + interval '5 hours', true, 'published');

select is(
  (select count(*)::int from public.notification_jobs
   where party_id = 'cccccccc-0000-0000-0000-000000000003'),
  0,
  'a private party notifies nobody, however close they are standing'
);

-- The host is not a passer-by who needs to be told where their own party is.
insert into public.parties (id, host_id, title, location, starts_at, is_private, status) values
  ('cccccccc-0000-0000-0000-000000000004',
   '44444444-4444-4444-4444-444444444444',
   'My Own Party', st_point(23.7352, 37.9759)::geography,
   now() + interval '5 hours', false, 'published');

select is(
  (select count(*)::int from public.notification_jobs
   where party_id = 'cccccccc-0000-0000-0000-000000000004'),
  0,
  'a host is not notified that they are near their own party'
);

-- can_user_access_party carries the block rule, so the engine never restates
-- it. This is the assertion that the inheritance actually happened.
insert into public.blocks (blocker_id, blocked_id) values
  ('44444444-4444-4444-4444-444444444444', '11111111-1111-1111-1111-111111111111');

insert into public.parties (id, host_id, title, location, starts_at, is_private, status) values
  ('cccccccc-0000-0000-0000-000000000005',
   '11111111-1111-1111-1111-111111111111',
   'Blocked Host Party', st_point(23.7352, 37.9759)::geography,
   now() + interval '5 hours', false, 'published');

select is(
  (select count(*)::int from public.notification_jobs
   where party_id = 'cccccccc-0000-0000-0000-000000000005'),
  0,
  'a block hides the party from the engine, not merely from the map'
);

delete from public.blocks;

-- push_consent is a consent state; notify_nearby is a product setting. The
-- engine must honour both, and must not read either as the other.
update public.profiles set push_consent = false
where id = '44444444-4444-4444-4444-444444444444';

insert into public.parties (id, host_id, title, location, starts_at, is_private, status) values
  ('cccccccc-0000-0000-0000-000000000006',
   '11111111-1111-1111-1111-111111111111',
   'No Push Consent', st_point(23.7352, 37.9759)::geography,
   now() + interval '5 hours', false, 'published');

select is(
  (select count(*)::int from public.notification_jobs
   where party_id = 'cccccccc-0000-0000-0000-000000000006'),
  0,
  'without push_consent nothing is enqueued'
);

update public.profiles set push_consent = true, notify_nearby = false
where id = '44444444-4444-4444-4444-444444444444';

insert into public.parties (id, host_id, title, location, starts_at, is_private, status) values
  ('cccccccc-0000-0000-0000-000000000007',
   '11111111-1111-1111-1111-111111111111',
   'Nearby Turned Off', st_point(23.7352, 37.9759)::geography,
   now() + interval '5 hours', false, 'published');

select is(
  (select count(*)::int from public.notification_jobs
   where party_id = 'cccccccc-0000-0000-0000-000000000007'),
  0,
  'and turning the nearby preference off suppresses it too, consent notwithstanding'
);

update public.profiles set notify_nearby = true
where id = '44444444-4444-4444-4444-444444444444';

-- A device registered for push with no location at all -- 7a's carve-out --
-- must be invisible to a proximity query rather than matching at null.
insert into public.user_devices (user_id, push_token, platform) values
  ('55555555-5555-5555-5555-555555555555', 'tok-blocked-nolocation', 'ios');

update public.profiles set push_consent = true, notify_nearby = true
where id = '55555555-5555-5555-5555-555555555555';

insert into public.parties (id, host_id, title, location, starts_at, is_private, status) values
  ('cccccccc-0000-0000-0000-000000000008',
   '11111111-1111-1111-1111-111111111111',
   'Locationless Device Test', st_point(23.7352, 37.9759)::geography,
   now() + interval '5 hours', false, 'published');

select is(
  (select count(*)::int from public.notification_jobs
   where party_id = 'cccccccc-0000-0000-0000-000000000008'
   and user_id = '55555555-5555-5555-5555-555555555555'),
  0,
  'a device with a push token and no location is not a proximity match'
);


-- ============================================================
-- 5. Quiet hours defer. They do not drop, and they still claim.
--
-- The window is computed around the current instant in UTC so the test is
-- valid at any hour. It deliberately straddles now: one hour behind, two
-- ahead. When that arithmetic wraps past midnight it becomes a wrapping
-- window, which is the branch worth exercising anyway.
-- ============================================================
update public.profiles
set quiet_hours_start = (now() at time zone 'UTC')::time - interval '1 hour',
    quiet_hours_end   = (now() at time zone 'UTC')::time + interval '2 hours'
where id = '22222222-2222-2222-2222-222222222222';

select ok(
  public.in_quiet_hours('22222222-2222-2222-2222-222222222222', now()),
  'the user is inside their quiet window'
);

select ok(
  not public.in_quiet_hours('22222222-2222-2222-2222-222222222222',
                            now() + interval '3 hours'),
  'and outside it three hours later -- the window has an end, including when it wraps midnight'
);

select ok(
  not public.in_quiet_hours('44444444-4444-4444-4444-444444444444', now()),
  'a user with no quiet hours set is never in them'
);

insert into public.parties (id, host_id, title, location, starts_at, is_private, status) values
  ('cccccccc-0000-0000-0000-000000000009',
   '11111111-1111-1111-1111-111111111111',
   'Elefsina Late One', st_point(23.5401, 38.0401)::geography,
   now() + interval '8 hours', false, 'published');

select is(
  (select count(*)::int from public.notification_jobs
   where party_id = 'cccccccc-0000-0000-0000-000000000009'),
  1,
  'a quiet-hours user still gets a job -- deferred, not dropped'
);

select ok(
  (select scheduled_for between now() + interval '110 minutes'
                            and now() + interval '130 minutes'
   from public.notification_jobs
   where party_id = 'cccccccc-0000-0000-0000-000000000009'),
  'and it is scheduled for the end of their window, roughly two hours out'
);

-- The asymmetry with the daily cap, asserted rather than described: quiet
-- hours claim the slot because the job already exists.
select is(
  (select count(*)::int from public.sent_notifications
   where party_id = 'cccccccc-0000-0000-0000-000000000009'),
  1,
  'the dedupe row IS claimed during quiet hours -- the decision was made, only delivery moved'
);


-- ============================================================
-- 6. The daily cap, and the slot it deliberately does not burn.
-- ============================================================
update public.profiles set notify_daily_cap = 1
where id = '33333333-3333-3333-3333-333333333333';

insert into public.parties (id, host_id, title, location, starts_at, is_private, status) values
  ('cccccccc-0000-0000-0000-000000000010',
   '11111111-1111-1111-1111-111111111111',
   'Kifisia One', st_point(23.8104, 38.0743)::geography,
   now() + interval '5 hours', false, 'published');

insert into public.parties (id, host_id, title, location, starts_at, is_private, status) values
  ('cccccccc-0000-0000-0000-000000000011',
   '11111111-1111-1111-1111-111111111111',
   'Kifisia Two', st_point(23.8104, 38.0743)::geography,
   now() + interval '6 hours', false, 'published');

select is(
  (select count(*)::int from public.notification_jobs
   where user_id = '33333333-3333-3333-3333-333333333333'),
  1,
  'a cap of one means the second nearby party of the day is not enqueued'
);

-- The whole point of checking the cap BEFORE the claim. A capped notification
-- is "not today", not "never" -- burning the dedupe slot would make tomorrow's
-- sweep skip it forever.
select is(
  (select count(*)::int from public.sent_notifications
   where user_id = '33333333-3333-3333-3333-333333333333'),
  1,
  'and the suppressed one burned no dedupe slot -- it can still be delivered tomorrow'
);

select is(
  (select count(*)::int from public.sent_notifications
   where user_id = '33333333-3333-3333-3333-333333333333'
   and party_id = 'cccccccc-0000-0000-0000-000000000011'),
  0,
  'specifically, the capped party has no claim against that user'
);


-- ============================================================
-- 7. Fan in: the device moves, the parties come to it.
--
-- The party is created BEFORE second_host has any device, so the publish
-- trigger matches nobody and anything that appears below was produced by the
-- movement trigger and nothing else.
-- ============================================================
insert into public.parties (id, host_id, title, location, starts_at, is_private, status) values
  ('cccccccc-0000-0000-0000-000000000012',
   '11111111-1111-1111-1111-111111111111',
   'Glyfada Beach Set', st_point(23.7534, 37.8654)::geography,
   now() + interval '5 hours', false, 'published');

select is(
  (select count(*)::int from public.notification_jobs
   where party_id = 'cccccccc-0000-0000-0000-000000000012'),
  0,
  'control: nobody is near the Glyfada party yet, so publishing it enqueued nothing'
);

insert into public.user_devices (id, user_id, push_token, platform, last_location) values
  ('eeeeeeee-0000-0000-0000-000000000006',
   '66666666-6666-6666-6666-666666666666', 'tok-secondhost', 'ios',
   st_point(23.7535, 37.8655)::geography);

select is(
  (select count(*)::int from public.notification_jobs
   where party_id = 'cccccccc-0000-0000-0000-000000000012'
   and user_id = '66666666-6666-6666-6666-666666666666'),
  1,
  'a device arriving next to an existing party is notified by the movement trigger'
);

select ok(
  (select last_evaluated_at is not null from public.user_devices
   where id = 'eeeeeeee-0000-0000-0000-000000000006'),
  'and the evaluation is stamped, so the debounce has something to measure from'
);


-- ============================================================
-- 8. Debounce: a second move inside the floor does not re-evaluate.
--
-- A second Glyfada party is created with triggers suppressed, so it exists but
-- was never fanned out. If the movement trigger re-evaluated on the next ping,
-- this party would be found. It must not be -- and then, once the floor has
-- passed, it must be.
-- ============================================================
set local session_replication_role = replica;
insert into public.parties (id, host_id, title, location, starts_at, is_private, status) values
  ('cccccccc-0000-0000-0000-000000000013',
   '11111111-1111-1111-1111-111111111111',
   'Glyfada Second Set', st_point(23.7536, 37.8656)::geography,
   now() + interval '7 hours', false, 'published');
set local session_replication_role = origin;

-- A real move: 7a rounds to ~100m, and this lands in a different cell, so the
-- trigger's WHEN clause matches and only the time floor can stop it.
update public.user_devices
set last_location = st_point(23.7554, 37.8674)::geography
where id = 'eeeeeeee-0000-0000-0000-000000000006';

select is(
  (select count(*)::int from public.notification_jobs
   where party_id = 'cccccccc-0000-0000-0000-000000000013'),
  0,
  'moving again within the debounce floor does not re-run the spatial query'
);

-- Backdate past the floor. last_evaluated_at carries no client grant, which is
-- asserted below -- this works only because the session is the owner.
update public.user_devices
set last_evaluated_at = now() - interval '11 minutes'
where id = 'eeeeeeee-0000-0000-0000-000000000006';

update public.user_devices
set last_location = st_point(23.7535, 37.8655)::geography
where id = 'eeeeeeee-0000-0000-0000-000000000006';

select is(
  (select count(*)::int from public.notification_jobs
   where party_id = 'cccccccc-0000-0000-0000-000000000013'),
  1,
  'and once the floor has passed the same move does re-evaluate -- debounced, not disabled'
);


-- ============================================================
-- 9. The safety net.
-- ============================================================

-- Simulate a trigger that never fired: wipe the ledger and the queue for one
-- party and let the sweep find it. This is exactly the state a crashed
-- transaction or a disabled trigger would leave behind.
delete from public.notification_jobs
where party_id = 'cccccccc-0000-0000-0000-000000000001';
delete from public.sent_notifications
where party_id = 'cccccccc-0000-0000-0000-000000000001';

select ok(
  (select jobs_enqueued from public.sweep_missed_nearby_notifications()) >= 1,
  'the sweep re-enqueues a notification whose trigger never fired'
);

select is(
  (select count(*)::int from public.notification_jobs
   where party_id = 'cccccccc-0000-0000-0000-000000000001'),
  1,
  'and exactly one job comes back, not one per sweep tick'
);

-- Bounded, not indiscriminate: the sweep only looks a week ahead. Created with
-- triggers suppressed so that a job appearing could only have come from the
-- sweep.
set local session_replication_role = replica;
insert into public.parties (id, host_id, title, location, starts_at, is_private, status) values
  ('cccccccc-0000-0000-0000-000000000014',
   '11111111-1111-1111-1111-111111111111',
   'A Month Away', st_point(23.7352, 37.9759)::geography,
   now() + interval '30 days', false, 'published');
set local session_replication_role = origin;

select is(
  (select count(*)::int from public.notification_jobs
   where party_id = 'cccccccc-0000-0000-0000-000000000014'),
  0,
  'control: the month-away party was created with triggers suppressed, so nothing is queued yet'
);

select ok(
  (select jobs_enqueued from public.sweep_missed_nearby_notifications()) = 0,
  'and the sweep does not reach for it either -- it looks one week ahead, not forever'
);

-- A job whose party has already started is never delivered.
insert into public.notification_jobs (user_id, party_id, kind, expires_at, status) values
  ('44444444-4444-4444-4444-444444444444',
   'cccccccc-0000-0000-0000-000000000014',
   'nearby_party', now() - interval '1 hour', 'pending');

select ok(
  (select jobs_expired from public.sweep_missed_nearby_notifications()) >= 1,
  'the sweep expires a pending job whose party has already started'
);

select is(
  (select status from public.notification_jobs
   where party_id = 'cccccccc-0000-0000-0000-000000000014'
   and user_id = '44444444-4444-4444-4444-444444444444'),
  'expired',
  'and marks it rather than deleting it, so the count is observable'
);


-- ============================================================
-- 10. Preference columns refuse nonsense, and derived columns stay derived.
-- ============================================================

select throws_ok(
  $$ update public.profiles set notification_tz = 'Mars/Olympus'
     where id = '44444444-4444-4444-4444-444444444444' $$,
  '22023',
  null,
  'an invalid timezone is refused at the write, not three days later inside a publish trigger'
);

select throws_ok(
  $$ update public.profiles set notify_radius_meters = 50000
     where id = '44444444-4444-4444-4444-444444444444' $$,
  '23514',
  null,
  'a radius above the cap is refused -- the engine''s indexable 5000m constant depends on this'
);

select throws_ok(
  $$ update public.profiles set quiet_hours_start = '23:00'
     where id = '44444444-4444-4444-4444-444444444444' $$,
  '23514',
  null,
  'half a quiet window is not a quiet window'
);


-- ============================================================
-- 11. From a client session: the queue is not there.
-- ============================================================
select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select throws_ok(
  $$ select 1 from public.notification_jobs $$,
  '42501',
  null,
  'a user cannot read the outbox -- a pending job is a location disclosure with the coordinate removed'
);

-- Derived, exactly like last_location_at (7a). A device that could backdate
-- its own last_evaluated_at could force a re-evaluation on every single ping.
select throws_ok(
  $$ update public.user_devices set last_evaluated_at = now() - interval '1 day'
     where id = 'eeeeeeee-0000-0000-0000-000000000004' $$,
  '42501',
  null,
  'last_evaluated_at is not client-writable -- the debounce cannot be dodged'
);

select throws_ok(
  $$ select public.enqueue_nearby_party_notifications(
       'cccccccc-0000-0000-0000-000000000001') $$,
  '42501',
  null,
  'and the enqueue function is not client-callable'
);

select throws_ok(
  $$ select public.sweep_missed_nearby_notifications() $$,
  '42501',
  null,
  'nor is the sweep'
);


select * from finish();
rollback;
