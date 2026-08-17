-- Phase 7c, part 1: the SQL half of delivery.
--
-- 7b stops at notification_jobs. This file is everything the delivery worker
-- needs in order to drain that queue WITHOUT holding a single delivery rule,
-- plus the one RPC the Flutter client uses to register a device.
--
-- The division of labour is the point, and it is the same one story-media draws
-- (20260812124217 / functions/story-media): the process holding the service key
-- decides nothing. The worker knows how to speak HTTP to Google and how to back
-- off when Google is unhappy. It does not know who may be notified, when a job
-- is too old to send, how many times to retry, or what "already sent" means.
-- All of that is here, in one place, where the rest of the engine can see it.
--
-- Concretely, the worker never issues an UPDATE against notification_jobs. It
-- calls claim / complete / fail, and the queue's state machine has exactly one
-- owner. A worker that could write the table directly would be a second author
-- of the retry policy, and the first thing to drift would be the attempt cap --
-- the one rule whose failure mode is an infinite loop against a paid API.
--
--
-- WHY THERE IS BOTH A TRIGGER AND A CRON, WHEN 7b WAS EMPHATIC THAT THE CRON
-- IS ONLY A SAFETY NET
--
-- Because here they are not the same mechanism twice. 7b's sweep re-runs a
-- decision the triggers should already have made; these two dispatch DIFFERENT
-- populations and neither can cover the other:
--
--   the insert trigger  -- a job was just created. Fires within milliseconds,
--                          which is what makes the phase target ("under 60s")
--                          achievable at all; a minute-granularity cron alone
--                          would spend most of that budget waiting.
--   the cron            -- a job whose scheduled_for has ARRIVED. A quiet-hours
--                          deferral written at 02:14 and deliverable at 08:00
--                          has no insert event at 08:00. Nothing else in the
--                          system will ever wake for it.
--
-- So the cron is not a net under the trigger, it is the only delivery path for
-- every deferred job. Both are needed and neither is redundant.


-- ============================================================
-- 'cancelled' -- a fifth outcome, because 'failed' has to keep its meaning.
--
-- Three things can be true by the time a job comes up for delivery that were
-- not true when it was enqueued: the user withdrew push consent or turned the
-- feature off, the party was cancelled, or the party went private. In none of
-- those cases did anything go wrong. We decided not to send.
--
-- Folding that into 'failed' would be cheaper by one CHECK constraint and wrong
-- in the way that costs an on-call hour: the operator metric that matters is
-- "how much of the queue is failing to deliver", and a healthy system that
-- correctly declines a thousand jobs would read as a thousand delivery faults.
-- 'expired' already exists for the same reason -- 7b did not fold aged-out jobs
-- into 'failed' either.
--
-- Dropping and recreating the CHECK is not an edit to 20260817073508; that file
-- is untouched and stays untouched (CLAUDE.md #7). This is a new migration that
-- widens the constraint, which is the append-only way to change one.
-- ============================================================
alter table public.notification_jobs
  drop constraint notification_jobs_status_check;

alter table public.notification_jobs
  add constraint notification_jobs_status_check
    check (status in ('pending', 'sending', 'sent', 'failed', 'expired', 'cancelled'));

-- 7b's cleanup pass deletes finished work on updated_at, and its partial index
-- enumerates which statuses count as finished. 'cancelled' is finished, so
-- without this the cancelled rows would sit in the queue forever and the
-- sweep's delete would seq-scan past them on every tick.
drop index if exists public.notification_jobs_finished_idx;

create index notification_jobs_finished_idx
  on public.notification_jobs (updated_at)
  where status in ('sent', 'failed', 'expired', 'cancelled');


-- ============================================================
-- notification_worker_config -- where the worker's URL and key come from.
--
-- Vault, exactly like story_cleanup_config (20260815133041). The database has
-- to call an edge function as service_role, so a secret must live somewhere the
-- database can read and something encrypts at rest; vault.decrypted_secrets is
-- that place on Supabase.
--
-- It RAISES when unset rather than returning null, and the two callers below
-- treat that differently on purpose -- see each of them. Local values are
-- seeded in seed.sql. To configure a hosted project, once:
--
--   select vault.create_secret('https://<ref>.supabase.co/functions/v1/notification-worker',
--                              'notification_worker_url');
--   select vault.create_secret('<service_role key>', 'notification_worker_service_key');
-- ============================================================
create or replace function public.notification_worker_config()
returns table (worker_url text, service_key text)
language plpgsql
security definer
set search_path = ''
stable
as $$
begin
  select
    max(s.decrypted_secret) filter (where s.name = 'notification_worker_url'),
    max(s.decrypted_secret) filter (where s.name = 'notification_worker_service_key')
  into worker_url, service_key
  from vault.decrypted_secrets s
  where s.name in ('notification_worker_url', 'notification_worker_service_key');

  if worker_url is null or service_key is null then
    raise exception
      'notification delivery is not configured: vault needs secrets notification_worker_url and notification_worker_service_key'
      using errcode = 'P0002';
  end if;

  return next;
end;
$$;

revoke execute on function public.notification_worker_config()
  from public, anon, authenticated;


-- ============================================================
-- claim_notification_jobs -- the worker's ONLY read, and its four-step
-- housekeeping pass.
--
-- One round trip returns everything needed to send: the job, the party's title
-- and start, and the user's device tokens. The worker never queries again.
-- That is not micro-optimisation -- it is what keeps the worker incapable of
-- asking a question the queue did not answer, and therefore incapable of
-- inventing a rule.
--
-- The four steps run in order and the first three are the interesting ones:
--
--   1. RECLAIM. A job left in 'sending' is a worker that died mid-flight --
--      a redeploy, an OOM, a timeout. Without this it is stranded forever,
--      because nothing else ever looks at 'sending'. Five minutes is well past
--      the worst honest round trip to FCM and well under the hour it would take
--      the 7b sweep to notice nothing was moving.
--
--   2. EXPIRE. 7b sets expires_at to the party's start and its hourly sweep
--      marks stale jobs. But THIS runs every minute, so in practice this is
--      what actually enforces expires_at, and the sweep is the backstop. A
--      deferred 08:00 push about a party that started at 23:30 is worse than
--      silence -- the user cannot tell a late notification from a wrong one.
--
--   3. CANCEL, and this is the compliance-relevant one. Quiet hours mean a
--      decision made at 02:14 is delivered at 08:00, and consent withdrawn in
--      between must take effect immediately (GDPR Art. 7(3)) -- not "for jobs
--      enqueued from now on". The same applies to a party cancelled or made
--      private after the fan-out. So the gates are re-asked at DELIVERY time,
--      not only at enqueue time.
--
--      It re-asks by calling wants_nearby_notifications, 7b's helper, rather
--      than reading push_consent and notify_nearby here (CLAUDE.md #4). The day
--      a third condition joins that helper, this path gets it for free -- and
--      this is the path where missing it means pushing to someone who said no.
--
--   4. CLAIM. `for update skip locked` so two overlapping invocations -- and
--      they WILL overlap, since the insert trigger and the cron are
--      independent -- take disjoint batches instead of blocking or
--      double-sending. attempts is incremented here, at claim, not at failure:
--      a worker that crashes after claiming has still consumed an attempt,
--      which is what stops a job that reliably kills the worker from being
--      retried forever.
--
-- security definer because notification_jobs, sent_notifications and
-- user_devices are all closed to every client role, and because it reads push
-- tokens and another user's preferences. Execute is granted to service_role
-- ONLY -- see the grant block at the foot of this file for why that has to be
-- spelled out rather than left to the default.
-- ============================================================
create or replace function public.claim_notification_jobs(p_limit int default 100)
returns table (
  job_id          bigint,
  user_id         uuid,
  party_id        uuid,
  kind            text,
  attempts        int,
  party_title     text,
  party_starts_at timestamptz,
  devices         jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- 1. Stranded claims come back.
  update public.notification_jobs j
  set status = 'pending'
  where j.status = 'sending'
    and j.updated_at < now() - interval '5 minutes';

  -- 2. Too late to be worth sending.
  update public.notification_jobs j
  set status = 'expired'
  where j.status = 'pending'
    and j.expires_at <= now();

  -- 3. Still deliverable, but no longer wanted. Only jobs that are actually due
  -- are evaluated -- a job scheduled for 08:00 is re-checked at 08:00, which is
  -- the whole point of doing this at delivery time.
  update public.notification_jobs j
  set status     = 'cancelled',
      last_error = case
        when not public.wants_nearby_notifications(j.user_id)
          then 'cancelled: push consent or nearby preference withdrawn after enqueue'
        else 'cancelled: party is no longer published and public'
      end
  where j.status = 'pending'
    and j.scheduled_for <= now()
    and (
      not public.wants_nearby_notifications(j.user_id)
      or not exists (
        select 1
        from public.parties p
        where p.id = j.party_id
          and p.status = 'published'
          and not p.is_private
      )
    );

  -- 4. Take a batch.
  return query
  with due as (
    select j.id
    from public.notification_jobs j
    where j.status = 'pending'
      and j.scheduled_for <= now()
      and j.expires_at > now()
    order by j.scheduled_for
    limit p_limit
    -- Rides notification_jobs_due_idx (partial on status = 'pending').
    for update skip locked
  ),
  claimed as (
    update public.notification_jobs j
    set status   = 'sending',
        attempts = j.attempts + 1
    from due
    where j.id = due.id
    returning j.id, j.user_id, j.party_id, j.kind, j.attempts
  )
  select
    c.id,
    c.user_id,
    c.party_id,
    c.kind,
    c.attempts,
    p.title,
    p.starts_at,
    -- Every token this user has, in one array. A job is per USER; the fan-out
    -- to their phone and their tablet is a delivery detail, which is why
    -- sent_notifications dedupes on (user, party, kind) and not per device.
    --
    -- Empty array rather than null when the user has no registered device, so
    -- the worker's branch is `devices.length === 0` and never a null check. It
    -- is a real state: push consent can be granted before a token exists.
    coalesce(
      (
        select jsonb_agg(
                 jsonb_build_object('push_token', d.push_token, 'platform', d.platform)
                 order by d.created_at
               )
        from public.user_devices d
        where d.user_id = c.user_id
      ),
      '[]'::jsonb
    )
  from claimed c
  join public.parties p on p.id = c.party_id;
end;
$$;

revoke execute on function public.claim_notification_jobs(int)
  from public, anon, authenticated;

comment on function public.claim_notification_jobs(int) is
  'The delivery worker''s single read. Reclaims stranded jobs, expires stale ones, cancels ones no longer wanted, then claims a batch with SKIP LOCKED.';


-- ============================================================
-- complete_notification_job -- delivered to at least one device.
--
-- last_error is cleared, not left behind. A job that failed twice and then
-- succeeded is a success, and a 'sent' row still carrying the text of an
-- earlier transport error is a row that will be misread by whoever greps for it
-- at 3am.
-- ============================================================
create or replace function public.complete_notification_job(p_job_id bigint)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.notification_jobs j
  set status     = 'sent',
      last_error = null
  where j.id = p_job_id
    and j.status = 'sending';
$$;

revoke execute on function public.complete_notification_job(bigint)
  from public, anon, authenticated;


-- ============================================================
-- fail_notification_job -- and THE ATTEMPT CAP, which lives here and nowhere
-- else.
--
-- p_retry_in null      -> terminal. The worker saw something it knows will not
--                         get better: a token FCM rejected, a malformed
--                         payload, a party that vanished.
-- p_retry_in set       -> back to 'pending', deliverable again after that
--                         interval. The worker chooses the backoff curve; it
--                         does not get to choose whether the curve ever ends.
--
-- The cap is the reason this is a function rather than an UPDATE the worker
-- could issue itself. A retry budget enforced in the worker is enforced in a
-- process that gets redeployed, runs several copies at once, and holds no
-- memory between invocations -- so "give up after five" would silently become
-- "give up after five, per invocation, forever". Here it is a property of the
-- row, and the row outlives every worker.
--
-- Five, and the interaction with claim_notification_jobs is deliberate:
-- attempts is incremented at CLAIM, so a job whose worker dies mid-send still
-- burns one. That is what makes a poison job -- one that reliably kills the
-- process before any code path can report a failure -- terminate on its own.
--
-- Returns the resulting status so the worker can log what actually happened
-- rather than what it asked for. A worker that requested a retry and was told
-- 'failed' has just hit the cap, and that is worth a log line at a different
-- level.
-- ============================================================
create or replace function public.fail_notification_job(
  p_job_id   bigint,
  p_error    text,
  p_retry_in interval default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_max_attempts constant int := 5;
  v_attempts     int;
  v_status       text;
begin
  select j.attempts into v_attempts
  from public.notification_jobs j
  where j.id = p_job_id;

  if not found then
    return null;
  end if;

  if p_retry_in is null or v_attempts >= v_max_attempts then
    v_status := 'failed';
  else
    v_status := 'pending';
  end if;

  update public.notification_jobs j
  set status        = v_status,
      -- Left alone on the terminal branch: a failed job's scheduled_for is the
      -- last instant we tried, which is more useful than a future time nothing
      -- will ever act on.
      scheduled_for = case when v_status = 'pending'
                          then now() + p_retry_in
                          else j.scheduled_for
                     end,
      -- Truncated because this is written from a remote API's error body and
      -- there is no bound on what that contains. A queue row is not a log.
      last_error    = left(p_error, 500)
  where j.id = p_job_id;

  return v_status;
end;
$$;

revoke execute on function public.fail_notification_job(bigint, text, interval)
  from public, anon, authenticated;

comment on function public.fail_notification_job(bigint, text, interval) is
  'Terminal failure, or a scheduled retry. The 5-attempt cap is enforced here so no worker can loop a job forever.';


-- ============================================================
-- delete_device_by_push_token -- the FCM "UNREGISTERED" path.
--
-- When Google says a token is dead -- the app was uninstalled, the user cleared
-- data, the token was refreshed and this one superseded -- the row must go.
-- Keeping it costs a wasted API call on every future job for that user, and
-- worse, it is a row in the one table that also holds a location.
--
-- No user_id argument, deliberately. The worker knows the token it just sent to
-- and nothing else; requiring it to also assert whose token it was would be
-- asking it to hold state it has no reason to hold, and push_token is globally
-- unique (20260816083807) so the token alone identifies the row exactly.
--
-- Returns the count so "we deleted a device" is observable in the worker's log
-- rather than assumed. Zero is normal and not an error: two jobs for the same
-- dead token in one batch means the second delete finds nothing.
-- ============================================================
create or replace function public.delete_device_by_push_token(p_push_token text)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deleted int;
begin
  delete from public.user_devices d
  where d.push_token = p_push_token;

  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke execute on function public.delete_device_by_push_token(text)
  from public, anon, authenticated;


-- ============================================================
-- upsert_user_device -- the client's only door into user_devices.
--
-- WHY THIS EXISTS AT ALL, given the table already has INSERT and UPDATE
-- policies the client could use through PostgREST:
--
-- 7a's column grants are deliberately asymmetric --
--     insert (id, user_id, push_token, platform, last_location)
--     update (push_token, platform, last_location)
-- because user_id must be settable once and never again, and the derived
-- columns must never be settable at all (CLAUDE.md gotcha #8).
--
-- PostgREST's upsert puts EVERY key of the request body into the ON CONFLICT
-- DO UPDATE SET list. So a body carrying user_id -- which the insert path
-- requires -- is a body that tries to write user_id on the update path, where
-- the privilege is deliberately absent. The upsert fails with 42501 for a
-- device that already exists, which is the common case, on its second run. The
-- two grants simply cannot be expressed as one PostgREST call.
--
-- In SQL they can, because the INSERT column list and the DO UPDATE SET list
-- are separate things checked separately. Hence one statement, in a function.
--
-- SECURITY INVOKER, and that is the whole design. This runs as the caller, so
-- every policy on user_devices still applies -- owner-only, and the consent
-- WITH CHECK on both INSERT and UPDATE. The function is a shape adapter for the
-- grants, not an authority, and nothing in it restates a rule the policies
-- already hold. A definer version would have been shorter and would have made
-- this file the second place location consent is decided.
--
-- The consent check below is not a restatement either -- it CALLS
-- has_location_consent, the same helper the policy calls (CLAUDE.md #4). It is
-- here only so the two ways this can fail are distinguishable: without it, both
-- "you have not consented to location" and "this token belongs to another
-- account" surface as a bare 42501 and the client cannot tell the user which
-- one happened. The policy remains the enforcement; this is the error message.
-- ============================================================
create or replace function public.upsert_user_device(
  p_push_token text,
  p_platform   text,
  p_lat        double precision default null,
  p_lng        double precision default null
)
returns uuid
language plpgsql
security invoker
set search_path = public, extensions
as $$
declare
  v_user_id  uuid := (select auth.uid());
  v_location geography;
  v_id       uuid;
begin
  if v_user_id is null then
    raise exception 'not signed in'
      using errcode = '42501';
  end if;

  if p_lat is not null and p_lng is not null then
    -- makepoint is (x, y) = (longitude, latitude). Getting this backwards
    -- produces a valid point in the wrong hemisphere rather than an error,
    -- which is why it is worth a comment every time it appears.
    v_location := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  end if;

  if v_location is not null and not public.has_location_consent(v_user_id) then
    raise exception 'location consent is required before a location can be stored'
      using errcode = 'P0001',
            hint = 'set profiles.location_consent, or register the device without a location';
  end if;

  begin
    insert into public.user_devices as d (user_id, push_token, platform, last_location)
    values (v_user_id, p_push_token, p_platform, v_location)
    on conflict (push_token) do update
      set platform = excluded.platform,
          -- coalesce, not a straight assignment: a token-refresh upsert carries
          -- no location and must not therefore erase the one already held. The
          -- ways a location legitimately goes away are consent withdrawal and
          -- the 24h retention sweep, both of which own that decision.
          last_location = coalesce(excluded.last_location, d.last_location)
    returning d.id into v_id;
  exception
    when insufficient_privilege or unique_violation then
      -- The conflicting row belongs to somebody else. push_token is globally
      -- unique on purpose (20260816083807) and the RLS is deliberately NOT
      -- widened to let one user overwrite another's row -- that is what stops a
      -- shared or resold phone from delivering the previous owner's
      -- notifications. The documented fix is for the client to delete its
      -- device row on sign-out, which the delete policy exists for.
      raise exception 'this push token is registered to a different account'
        using errcode = '23505',
              detail = sqlerrm,
              hint = 'sign out on the other account, or wait for FCM to rotate the token';
  end;

  return v_id;
end;
$$;

revoke execute on function public.upsert_user_device(text, text, double precision, double precision)
  from public, anon;
grant execute on function public.upsert_user_device(text, text, double precision, double precision)
  to authenticated;

comment on function public.upsert_user_device(text, text, double precision, double precision) is
  'Client device registration. security INVOKER so the RLS consent gate still decides -- this only reconciles 7a''s asymmetric column grants, which no single PostgREST upsert can satisfy.';


-- ============================================================
-- post_to_notification_worker -- one HTTP call, two very different callers.
--
-- pg_net is asynchronous: http_post queues the request and the background
-- worker sends it only AFTER THIS TRANSACTION COMMITS. That is exactly the
-- shape wanted here. The trigger below fires inside the transaction that
-- created the party; if the request went out synchronously, publishing a party
-- would block on an edge function's cold start, and a slow worker would look
-- like a slow app.
--
-- The body carries a reason, which is not decoration -- it is the only way to
-- tell, from the worker's structured logs, whether deliveries are being driven
-- by the trigger (healthy) or by the cron (the trigger is broken and nobody
-- noticed, because the cron makes the symptom "slow" rather than "missing").
-- ============================================================
create or replace function public.post_to_notification_worker(p_reason text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cfg        record;
  v_request_id bigint;
begin
  select * into v_cfg from public.notification_worker_config();

  select net.http_post(
    url := v_cfg.worker_url,
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_cfg.service_key,
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object('reason', p_reason),
    timeout_milliseconds := 30000
  ) into v_request_id;

  return v_request_id;
end;
$$;

revoke execute on function public.post_to_notification_worker(text)
  from public, anon, authenticated;


-- ============================================================
-- Trigger: a job was enqueued, wake the worker.
--
-- FOR EACH STATEMENT, not for each row. 7b's fan-out inserts every job for one
-- party in a single INSERT ... SELECT, so a row-level trigger on a party in a
-- dense neighbourhood would queue hundreds of identical HTTP requests to wake a
-- worker that is already awake and whose first act is to claim the whole batch.
-- One statement, one wake.
--
-- THE EXCEPTION HANDLER IS LOAD-BEARING AND IS NOT DEFENSIVE PROGRAMMING.
-- This trigger runs inside the transaction that inserted the jobs, which is the
-- transaction that published the party. notification_worker_config() raises
-- when vault is unconfigured, and pg_net can fail for its own reasons. Without
-- this handler, a project that has not yet had its secrets set -- a fresh
-- clone, a preview branch, a hosted environment mid-setup -- would fail to
-- CREATE PARTIES, with an error naming a notification secret. The feature
-- degrading to "no push" is correct; the feature taking party creation down
-- with it is not.
--
-- raise warning, so it is loud in the log and invisible to the user. The
-- minute-by-minute cron below will surface the same misconfiguration as a
-- proper, unswallowed failure on a job that has nothing else riding on it.
-- ============================================================
create or replace function public.wake_notification_worker()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    perform public.post_to_notification_worker('job_enqueued');
  exception
    when others then
      raise warning 'could not wake the notification worker: % (%)', sqlerrm, sqlstate;
  end;

  return null;
end;
$$;

create trigger notification_jobs_wake_worker
  after insert on public.notification_jobs
  for each statement
  execute function public.wake_notification_worker();


-- ============================================================
-- The tick. Every minute, and unlike 7b's sweep this one is not a safety net.
--
-- Two populations reach the worker only through here:
--
--   - Deferred jobs. A quiet-hours job written at 02:14 for 08:00 gets no
--     insert event at 08:00. Nothing else in the schema wakes for it.
--   - Retries. fail_notification_job pushes scheduled_for into the future;
--     that is an UPDATE, and the trigger above is on INSERT.
--
-- So the cadence is a real latency floor for both, which is why it is every
-- minute and not hourly. It is also the honest failure surface for a
-- misconfigured vault: the trigger swallows that error to protect party
-- creation, this does not, and a cron job failing every minute is a signal
-- somebody eventually sees.
--
-- unschedule-then-schedule for idempotency: cron.job is not part of the
-- migration history, so it survives things migrations do not, and there is no
-- `create ... if not exists` analogue. Same pattern as story-cleanup,
-- location-retention and nearby-notification-sweep.
-- ============================================================
select cron.unschedule('notification-worker-tick')
where exists (select 1 from cron.job where jobname = 'notification-worker-tick');

select cron.schedule(
  'notification-worker-tick',
  '* * * * *',
  $cron$ select public.post_to_notification_worker('cron_tick') $cron$
);


-- ============================================================
-- Grants, and the one that has to be spelled out.
--
-- Postgres grants EXECUTE on a new function to PUBLIC by default. Every
-- `revoke execute ... from public` above therefore removes it from service_role
-- too, since that is where service_role's privilege came from -- there was
-- never a service_role-specific grant to keep. Elsewhere in this schema that is
-- exactly right and nothing notices, because nothing outside the database calls
-- those functions.
--
-- Here it would break the entire phase silently: the edge function authenticates
-- as service_role and would get 42501 on every RPC, which PostgREST reports as
-- a permission error on a function the developer can plainly see exists.
-- ============================================================
grant execute on function public.claim_notification_jobs(int)                        to service_role;
grant execute on function public.complete_notification_job(bigint)                   to service_role;
grant execute on function public.fail_notification_job(bigint, text, interval)       to service_role;
grant execute on function public.delete_device_by_push_token(text)                   to service_role;
