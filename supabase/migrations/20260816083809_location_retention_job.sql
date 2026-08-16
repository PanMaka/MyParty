-- Phase 7a, part 2: the retention job. docs/backend-plan.md 7.2, rule 4.
--
-- Part 1 made it impossible to store a location without consent and impossible
-- to store a precise one. This file is the third property, and it is the one
-- that cannot be a constraint: a location that was lawful to collect stops
-- being lawful to keep. Nothing about the row changes -- only the clock -- so
-- the only mechanism available is something that wakes up and deletes.
--
-- Which means the retention promise is exactly as good as this job's uptime,
-- and unlike Phase 5's storage sweep that is NOT a cost problem, it is the
-- compliance problem. 20260815133041 could say "a cron outage costs bucket
-- bytes, never a story that outstays its 24 hours", because the SELECT policy
-- enforced story expiry independently. There is no equivalent here. A policy
-- can hide a stale location from a reader; it cannot make the bytes stop
-- existing, and "we hold your location for 24 hours" is a claim about the
-- bytes. If this job stops, the promise is broken silently and nothing in the
-- database notices.
--
-- Hence: no unnecessary steps, no dependency on Vault or pg_net or the network,
-- and a cadence with headroom (below). This job must be the least likely thing
-- in the schema to fail.


create extension if not exists pg_cron;


-- ============================================================
-- purge_stale_locations -- rule 4.
--
-- Nulls the column; never deletes the row. The device's push token and its
-- registration are not what expired -- only the location is -- and deleting the
-- row would unsubscribe the user from notifications as a side effect of a
-- privacy rule, which is both wrong and the sort of bug that reads as a
-- delivery outage rather than as this function.
--
-- last_location_at is left to the BEFORE trigger, which nulls it in lockstep
-- (part 1) and so keeps user_devices_location_timestamped satisfied. Setting it
-- here too would work and would also be the kind of duplicated invariant
-- CLAUDE.md #4 exists to prevent -- one place decides what a cleared location
-- looks like.
--
-- `where last_location is not null` first: it is the partial index's predicate,
-- so the scan is over devices that still hold a location rather than over every
-- device ever registered. Rows already cleared are skipped, not re-cleared, so
-- a tick with nothing to do costs an index probe.
--
-- Returns the count so a cron run has an observable result. `select
-- jobname, status, return_message from cron.job_run_details` is the only way an
-- operator finds out this job is alive, and a job that always returns void
-- makes "ran successfully, cleared nothing, for six weeks" indistinguishable
-- from working.
-- ============================================================
create or replace function public.purge_stale_locations()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cleared int;
begin
  with cleared as (
    update public.user_devices
    set last_location = null
    where last_location is not null
    and last_location_at < now() - interval '24 hours'
    returning 1
  )
  select count(*) into v_cleared from cleared;

  return v_cleared;
end;
$$;

revoke execute on function public.purge_stale_locations() from public, anon, authenticated;

comment on function public.purge_stale_locations() is
  'Nulls user_devices.last_location older than 24h. GDPR retention, docs/backend-plan.md 7.2 rule 4.';


-- ============================================================
-- purge_old_sent_notifications -- 7.2's "elsewhere" retention.
--
-- 90 days, hard delete. This ledger has no soft-delete and is exempt from
-- CLAUDE.md #7's "UGC deletes are soft" rule for the reason that rule exists:
-- soft delete protects content a user authored and a moderator hid, so that
-- there is something to appeal to. Nobody authored these rows and nobody will
-- ever appeal one. A hidden_at column here would mean retaining the very thing
-- the retention rule is about.
--
-- Batched at 10k. The first run against a mature table would otherwise be one
-- transaction over months of rows, holding locks and bloating WAL on a
-- schedule nobody is watching; the sweep runs often enough that a backlog
-- drains within a few ticks.
-- ============================================================
create or replace function public.purge_old_sent_notifications()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deleted int;
begin
  with doomed as (
    select id from public.sent_notifications
    where sent_at < now() - interval '90 days'
    limit 10000
  ),
  gone as (
    delete from public.sent_notifications s
    using doomed
    where s.id = doomed.id
    returning 1
  )
  select count(*) into v_deleted from gone;

  return v_deleted;
end;
$$;

revoke execute on function public.purge_old_sent_notifications() from public, anon, authenticated;


-- ============================================================
-- run_location_retention -- what cron calls.
--
-- Both sweeps in one job rather than two schedules: they are the same promise
-- ("we do not keep this") at two different horizons, and an operator checking
-- whether retention is running should have one row to look at, not two that can
-- disagree.
--
-- Ordering is deliberate even though the two are independent. Locations are the
-- 24-hour promise and the sensitive one; notifications are 90 days and a log.
-- If a tick is going to fail partway -- statement timeout, lock contention on a
-- busy table -- the half that must have run is the half that runs first.
-- ============================================================
create or replace function public.run_location_retention()
returns table (locations_cleared int, notifications_deleted int)
language plpgsql
security definer
set search_path = ''
as $$
begin
  locations_cleared := public.purge_stale_locations();
  notifications_deleted := public.purge_old_sent_notifications();
  return next;
end;
$$;

revoke execute on function public.run_location_retention() from public, anon, authenticated;


-- ============================================================
-- The schedule.
--
-- Every 10 minutes, and the cadence is a compliance parameter here rather than
-- the cost knob it was for story cleanup (20260815133041, */5, purely about
-- bucket bytes).
--
-- A sweep interval of N means the true worst-case retention is 24h + N, because
-- a row that ages past 24h one second after a tick waits for the next one. At
-- hourly that is 25 hours -- a documented 24-hour retention period that is
-- measurably not 24 hours, which is the kind of detail that turns a good-faith
-- policy into an inaccurate privacy notice. At */10 the overshoot is ten
-- minutes, comfortably inside any reasonable reading of the commitment, and the
-- cost is one index probe against a partial index per tick when there is
-- nothing to do.
--
-- unschedule-then-schedule so the migration is idempotent against a database
-- that already has the job: cron.job is not part of the migration history, so
-- it survives things migrations do not, and `create ... if not exists` has no
-- analogue -- same reasoning as the story-cleanup schedule.
-- ============================================================
select cron.unschedule('location-retention')
where exists (select 1 from cron.job where jobname = 'location-retention');

select cron.schedule(
  'location-retention',
  '*/10 * * * *',
  $cron$ select public.run_location_retention() $cron$
);
