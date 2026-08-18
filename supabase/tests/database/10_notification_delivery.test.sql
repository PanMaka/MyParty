-- Phase 7c: delivery.
--
-- 09 proved the engine decides correctly WHO gets told about WHAT. This file
-- proves the thing that drains its output cannot undo any of that -- and that
-- the queue's state machine survives a worker behaving badly, because the
-- worker is the one component here that runs outside the database, holds the
-- service key, and can be redeployed mid-flight.
--
-- The bias is toward what happens when things go wrong, because the happy path
-- of "a job was claimed and marked sent" is the one case that is obvious from
-- reading the code. What is not obvious:
--
--   1. THE GATES ARE RE-ASKED AT DELIVERY TIME. Quiet hours mean a decision
--      taken at 02:14 is delivered at 08:00. Consent withdrawn in between has
--      to take effect immediately (GDPR Art. 7(3)), which means the enqueue-time
--      check is not enough and the claim has to ask again. This is the section
--      that fails if someone ever "optimises" that re-check away as redundant.
--   2. 'cancelled' IS NOT 'failed'. A job we correctly decline is a different
--      fact from one we could not deliver, and an operator reading the queue
--      must be able to tell them apart.
--   3. THE ATTEMPT CAP IS ON THE ROW. A worker asking for a sixth retry is
--      told no. This is the assertion that matters if the retry budget is ever
--      moved into the worker, where redeploys and concurrent invocations each
--      get their own copy of it.
--   4. STRANDED CLAIMS COME BACK. A job left in 'sending' by a dead worker is
--      reclaimed, because nothing else in the schema ever looks at 'sending'.
--   5. EXPIRY BEATS DELIVERY. A job whose party has started is never claimed,
--      whatever its schedule says.
--   6. THE WORKER'S DOOR IS SHUT TO CLIENTS. Every RPC added by 7c is
--      unreachable from anon and authenticated, and upsert_user_device -- the
--      one that is not -- still cannot smuggle a location past 7a's consent
--      gate, because it runs as the caller and the policy is untouched.
--
-- Personas (seed.sql): host 1111, invitee 2222, friend_not_invited 3333,
-- stranger 4444, blocked_user 5555, second_host 6666.
--
-- As in 09, seed.sql's 22 parties are cancelled in setup: they cluster around
-- Syntagma and would otherwise fan out to every device registered here, turning
-- each assertion into arithmetic about the fixtures.
begin;
set search_path to public, extensions;
select plan(38);


-- Owner-level session: notification_jobs, sent_notifications and user_devices
-- are all closed to every client role, and several assertions below have to
-- backdate updated_at, which no grant permits.
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

-- Every assertion about claiming needs a job in a known state, and going
-- through the real engine each time would couple this file to 7b's fan-out
-- rules, which 09 already covers. This writes one job directly.
create or replace function tests.enqueue(
  p_user_id  uuid,
  p_party_id uuid,
  p_when     timestamptz default now(),
  p_expires  timestamptz default now() + interval '5 hours'
)
returns void
language sql
as $$
  insert into public.notification_jobs
    (user_id, party_id, kind, scheduled_for, expires_at)
  values (p_user_id, p_party_id, 'nearby_party', p_when, p_expires);
$$;


-- Runs a claim and throws the batch away. Several assertions below are about
-- what the claim DID to the queue rather than what it returned, and when the
-- correct answer is "it returned nothing" a construct that reads the result set
-- has no row to read and reports NULL instead of the status it was checking.
create or replace function tests.drain()
returns void
language plpgsql
as $$
begin
  perform public.claim_notification_jobs(100);
end;
$$;


-- ============================================================
-- Setup.
-- ============================================================
update public.parties set status = 'cancelled';

-- Start from an empty queue and an empty device table rather than assuming a
-- fresh `supabase db reset`. Every count below is then a local fact, and the
-- file survives being run against a database somebody has been poking at.
delete from public.notification_jobs;
delete from public.sent_notifications;
delete from public.user_devices;

update public.profiles
set location_consent = true,
    push_consent     = true,
    notify_nearby    = true,
    notification_tz  = 'UTC';

-- One published party for the jobs below to reference. Deliberately placed far
-- from every device this file registers, so nothing here is enqueued by the
-- publish trigger and every job is one the test wrote on purpose.
insert into public.parties (id, host_id, title, location, starts_at, is_private, status)
values ('dddddddd-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111',
        'Delivery Fixture', st_point(25.1300, 35.3400)::geography,  -- Heraklion
        now() + interval '5 hours', false, 'published');

insert into public.user_devices (user_id, push_token, platform) values
  ('44444444-4444-4444-4444-444444444444', 'tok-stranger-phone',  'ios'),
  ('44444444-4444-4444-4444-444444444444', 'tok-stranger-tablet', 'android'),
  ('22222222-2222-2222-2222-222222222222', 'tok-invitee-phone',   'android');
-- No location on any of them: this file is about delivery, and a device with a
-- location would drag the movement trigger into every insert.


-- ============================================================
-- 1. The claim, and what it hands the worker.
-- ============================================================
select lives_ok(
  $$ select tests.enqueue('44444444-4444-4444-4444-444444444444',
                          'dddddddd-0000-0000-0000-000000000001') $$,
  'a job can be enqueued for the stranger'
);

select is(
  (select count(*)::int from public.claim_notification_jobs(10)),
  1,
  'claiming returns the one due job'
);

select is(
  (select status from public.notification_jobs
   where user_id = '44444444-4444-4444-4444-444444444444'),
  'sending',
  'and the claim moved it to sending, so a second worker cannot take it'
);

-- attempts is incremented AT CLAIM, not at failure. A worker that dies before
-- it can report anything has still consumed one, which is what makes a job that
-- reliably kills the worker terminate on its own instead of looping forever.
select is(
  (select attempts from public.notification_jobs
   where user_id = '44444444-4444-4444-4444-444444444444'),
  1,
  'and it charged an attempt at claim time, not at failure time'
);

select is(
  (select count(*)::int from public.claim_notification_jobs(10)),
  0,
  'a second claim finds nothing -- SKIP LOCKED and the status change agree'
);

-- One job, both of that user's devices. A job is per USER; the fan-out to their
-- phone and their tablet is a delivery detail, which is exactly why
-- sent_notifications dedupes on (user, party, kind) rather than per device.
select is(
  (select jsonb_array_length(devices)
   from public.notification_jobs j
   join lateral (
     select coalesce(jsonb_agg(jsonb_build_object('push_token', d.push_token)), '[]'::jsonb) as devices
     from public.user_devices d where d.user_id = j.user_id
   ) dev on true
   where j.user_id = '44444444-4444-4444-4444-444444444444'),
  2,
  'and the user really does have two devices for that one job to fan out to'
);

select lives_ok(
  $$ select public.complete_notification_job(
       (select id from public.notification_jobs
        where user_id = '44444444-4444-4444-4444-444444444444')) $$,
  'the worker can complete it'
);

select is(
  (select status from public.notification_jobs
   where user_id = '44444444-4444-4444-4444-444444444444'),
  'sent',
  'which lands it in sent'
);


-- ============================================================
-- 2. Schedule and expiry -- the two reasons a pending job is not due.
-- ============================================================
delete from public.notification_jobs;

select tests.enqueue('44444444-4444-4444-4444-444444444444',
                     'dddddddd-0000-0000-0000-000000000001',
                     now() + interval '3 hours');

select is(
  (select count(*)::int from public.claim_notification_jobs(10)),
  0,
  'a job scheduled for later is not claimed -- this is what makes quiet hours defer rather than drop'
);

select is(
  (select status from public.notification_jobs limit 1),
  'pending',
  'and it is left pending, not cancelled, so it still delivers when its time comes'
);

delete from public.notification_jobs;

-- Party start already passed. 7b's hourly sweep also marks these, but the
-- worker runs every minute, so in practice this is what enforces expires_at.
select tests.enqueue('44444444-4444-4444-4444-444444444444',
                     'dddddddd-0000-0000-0000-000000000001',
                     now() - interval '1 hour',
                     now() - interval '1 minute');

select is(
  (select count(*)::int from public.claim_notification_jobs(10)),
  0,
  'a job past its expiry is never handed to the worker'
);

select is(
  (select status from public.notification_jobs limit 1),
  'expired',
  'it is marked expired -- a push about a party that already started is worse than silence'
);


-- ============================================================
-- 3. The gates are re-asked at DELIVERY time. The heart of this file.
--
-- Quiet hours make the gap between decision and delivery hours wide, and a
-- withdrawal inside that gap has to be honoured. Checking only at enqueue would
-- pass 09's suite and still push at somebody who had turned it off overnight.
-- ============================================================
delete from public.notification_jobs;

select tests.enqueue('22222222-2222-2222-2222-222222222222',
                     'dddddddd-0000-0000-0000-000000000001');

update public.profiles
set push_consent = false
where id = '22222222-2222-2222-2222-222222222222';

select is(
  (select count(*)::int from public.claim_notification_jobs(10)),
  0,
  'push consent withdrawn AFTER the job was enqueued stops it at the claim'
);

select is(
  (select status from public.notification_jobs limit 1),
  'cancelled',
  'and it is cancelled, not failed -- we declined to send, nothing went wrong'
);

select alike(
  (select last_error from public.notification_jobs limit 1),
  '%consent%',
  'with a last_error saying which gate closed'
);

update public.profiles set push_consent = true
where id = '22222222-2222-2222-2222-222222222222';
delete from public.notification_jobs;

-- The product preference, which is a different column and a different question
-- from consent (7b, 20260817073507) -- but the engine wants their conjunction,
-- and wants_nearby_notifications is where that lives.
select tests.enqueue('22222222-2222-2222-2222-222222222222',
                     'dddddddd-0000-0000-0000-000000000001');

update public.profiles set notify_nearby = false
where id = '22222222-2222-2222-2222-222222222222';

select tests.drain();

select is(
  (select status from public.notification_jobs limit 1),
  'cancelled',
  'turning the nearby preference off after enqueue cancels it too'
);

update public.profiles set notify_nearby = true
where id = '22222222-2222-2222-2222-222222222222';
delete from public.notification_jobs;

-- The party side of the same idea. A party cancelled or made private after the
-- fan-out must not still be pushed at people.
select tests.enqueue('44444444-4444-4444-4444-444444444444',
                     'dddddddd-0000-0000-0000-000000000001');

update public.parties set status = 'cancelled'
where id = 'dddddddd-0000-0000-0000-000000000001';

select tests.drain();

select is(
  (select status from public.notification_jobs limit 1),
  'cancelled',
  'a party cancelled after the fan-out is not delivered'
);

update public.parties set is_private = true, status = 'published'
where id = 'dddddddd-0000-0000-0000-000000000001';
delete from public.notification_jobs;

select tests.enqueue('44444444-4444-4444-4444-444444444444',
                     'dddddddd-0000-0000-0000-000000000001');

select tests.drain();

select is(
  (select status from public.notification_jobs limit 1),
  'cancelled',
  'and a party that has since gone private is not put on anyone''s lock screen'
);

update public.parties set is_private = false
where id = 'dddddddd-0000-0000-0000-000000000001';


-- ============================================================
-- 4. Retry, backoff and the cap.
-- ============================================================
delete from public.notification_jobs;

select tests.enqueue('44444444-4444-4444-4444-444444444444',
                     'dddddddd-0000-0000-0000-000000000001');
select tests.drain();

select is(
  public.fail_notification_job(
    (select id from public.notification_jobs limit 1),
    '503 from FCM', interval '5 minutes'),
  'pending',
  'a retryable failure returns the job to pending'
);

select ok(
  (select scheduled_for > now() + interval '4 minutes' from public.notification_jobs limit 1),
  'and pushes scheduled_for out by the backoff the worker asked for'
);

select is(
  (select count(*)::int from public.claim_notification_jobs(10)),
  0,
  'so it is not immediately re-claimed -- the backoff is real, not advisory'
);

select is(
  public.fail_notification_job(
    (select id from public.notification_jobs limit 1),
    'malformed payload'),
  'failed',
  'a terminal failure -- no retry interval -- goes straight to failed'
);

-- The cap. Five attempts, enforced on the row, because a worker-side budget
-- resets on every redeploy and runs independently in each concurrent
-- invocation, which is not a budget.
update public.notification_jobs
set status = 'sending', attempts = 5;

select is(
  public.fail_notification_job(
    (select id from public.notification_jobs limit 1),
    'still 503', interval '1 minute'),
  'failed',
  'the sixth attempt is refused a retry however politely the worker asks'
);

select is(
  (select status from public.notification_jobs limit 1),
  'failed',
  'and the row agrees -- the cap is not merely a return value'
);


-- ============================================================
-- 5. A worker that died mid-flight.
--
-- Nothing else in the schema ever looks at 'sending'. Without the reclaim these
-- rows are stranded silently and forever: still owed, never delivered, and
-- invisible to every other query in the engine.
-- ============================================================
delete from public.notification_jobs;

select tests.enqueue('44444444-4444-4444-4444-444444444444',
                     'dddddddd-0000-0000-0000-000000000001');
select tests.drain();

-- "The worker has been gone six minutes" is expressed by backdating updated_at
-- -- and that column cannot simply be UPDATEd, because notification_jobs_touch
-- rewrites it to now() on every write. That is the column being derived exactly
-- as intended (CLAUDE.md gotcha #8), so the trigger has to be suppressed to
-- stage the scenario. Only the table owner can do this, which is the other half
-- of the guarantee: no client role can forge a reclaim.
alter table public.notification_jobs disable trigger notification_jobs_touch;
update public.notification_jobs
set updated_at = now() - interval '6 minutes';
alter table public.notification_jobs enable trigger notification_jobs_touch;

select is(
  (select count(*)::int from public.claim_notification_jobs(10)),
  1,
  'a job stranded in sending is reclaimed and handed out again'
);

select is(
  (select attempts from public.notification_jobs limit 1),
  2,
  'and the reclaim charges a second attempt, so a poison job still terminates'
);

-- A worker that is merely slow must NOT have its job stolen -- that is a
-- duplicate notification, which is the one outcome the whole dedupe ledger
-- exists to prevent.
alter table public.notification_jobs disable trigger notification_jobs_touch;
update public.notification_jobs
set status = 'sending', updated_at = now() - interval '1 minute';
alter table public.notification_jobs enable trigger notification_jobs_touch;

select is(
  (select count(*)::int from public.claim_notification_jobs(10)),
  0,
  'but a job claimed one minute ago is left alone -- a slow worker is not a dead one'
);


-- ============================================================
-- 6. The doors.
-- ============================================================
select is(
  (select bool_or(has_function_privilege(r, f, 'execute'))
   from unnest(array['anon', 'authenticated']) r,
        unnest(array[
          'public.claim_notification_jobs(int)',
          'public.complete_notification_job(bigint)',
          'public.fail_notification_job(bigint, text, interval)',
          'public.delete_device_by_push_token(text)',
          'public.post_to_notification_worker(text)',
          'public.notification_worker_config()'
        ]) f),
  false,
  'no client role can claim, complete, fail, delete a device, or read the worker credentials'
);

-- The counterpart: the worker must actually be able to call them. Every
-- `revoke ... from public` above also removes service_role's privilege, since
-- that is where it came from -- so the grants have to be explicit, and their
-- absence would be a silent 42501 on every RPC.
select is(
  (select bool_and(has_function_privilege('service_role', f, 'execute'))
   from unnest(array[
          'public.claim_notification_jobs(int)',
          'public.complete_notification_job(bigint)',
          'public.fail_notification_job(bigint, text, interval)',
          'public.delete_device_by_push_token(text)'
        ]) f),
  true,
  'but service_role can call all four -- the explicit grants survived the revokes'
);

select is(
  (select schedule || ' active=' || active::text
   from cron.job where jobname = 'notification-worker-tick'),
  '* * * * * active=true',
  'the tick runs every minute -- deferred and retried jobs have no other path'
);

-- The trigger must be STATEMENT level. 7b's fan-out inserts every job for one
-- party in a single INSERT ... SELECT, so a row-level trigger would queue one
-- HTTP wake-up per notified user -- hundreds of requests to wake a worker whose
-- first act is to claim the whole batch.
select is(
  (select action_orientation from information_schema.triggers
   where event_object_table = 'notification_jobs'
   and trigger_name = 'notification_jobs_wake_worker'
   limit 1),
  'STATEMENT',
  'the wake trigger fires once per statement, not once per notified user'
);


-- ============================================================
-- 7. upsert_user_device -- the one new function clients CAN call.
--
-- It exists because 7a's column grants are asymmetric and no single PostgREST
-- upsert can satisfy both. It is security INVOKER, so it changes nothing about
-- who may store what: the consent gate is still the RLS policy's.
-- ============================================================
select is(
  (select prosecdef from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'upsert_user_device'),
  false,
  'upsert_user_device is security INVOKER -- it adapts the grants, it is not an authority'
);

select tests.authenticate_as('33333333-3333-3333-3333-333333333333');

-- friend_not_invited has location_consent true from setup; take it away and the
-- location must be refused while the plain registration still works.
select tests.become_owner();
update public.profiles set location_consent = false
where id = '33333333-3333-3333-3333-333333333333';
select tests.authenticate_as('33333333-3333-3333-3333-333333333333');

select lives_ok(
  $$ select public.upsert_user_device('tok-friend-phone', 'android') $$,
  'a device with no location registers fine without location consent -- push consent is a separate act'
);

select throws_ok(
  $$ select public.upsert_user_device('tok-friend-phone', 'android', 37.9755, 23.7348) $$,
  'P0001',
  'location consent is required before a location can be stored',
  'but attaching a location without consent is refused, with a message the client can act on'
);

select is(
  (select last_location from public.user_devices where push_token = 'tok-friend-phone'),
  null,
  'and nothing was stored -- the refusal is not merely a warning'
);

-- Consent granted, and the ~100m rounding still happens on the way in. The
-- client rounds too, as defence in depth, but the trigger is what makes the
-- guarantee true for every writer (7a).
select tests.become_owner();
update public.profiles set location_consent = true
where id = '33333333-3333-3333-3333-333333333333';
select tests.authenticate_as('33333333-3333-3333-3333-333333333333');

select lives_ok(
  $$ select public.upsert_user_device('tok-friend-phone', 'android', 37.97551234, 23.73489876) $$,
  'with consent, the same call succeeds'
);

select is(
  (select st_astext(last_location::geometry) from public.user_devices
   where push_token = 'tok-friend-phone'),
  'POINT(23.735 37.976)',
  'and the precise fix never reached the heap -- three decimal places, ~100m'
);

-- The cross-user conflict. push_token is globally unique on purpose, and the
-- RLS is deliberately not widened to let one user overwrite another's row --
-- that is what stops a resold phone from delivering the previous owner's
-- notifications. It must fail, and it must fail distinguishably.
select throws_ok(
  $$ select public.upsert_user_device('tok-stranger-phone', 'android') $$,
  '23505',
  'this push token is registered to a different account',
  'and a token belonging to another account is refused rather than stolen'
);

select tests.clear_authentication();

select * from finish();
rollback;
