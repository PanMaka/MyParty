-- Phase 7b, part 2: notification_jobs -- the outbox 7c drains.
--
-- 7a already shipped sent_notifications, and the obvious question is why this
-- is not that table. They answer different questions, and quiet hours is
-- exactly the case that separates them:
--
--   sent_notifications  -- "has this user already been told about this party?"
--                          A CLAIM. Written once, never updated, unique on
--                          (user, party, kind). It is what makes the publish
--                          trigger, the movement trigger and the hourly sweep
--                          converge on one notification instead of three.
--
--   notification_jobs   -- "what does the delivery worker still owe?"
--                          A WORK ITEM. Has a schedule, an expiry, a status, a
--                          retry count, and a lifetime that ends when it is
--                          delivered or aged out.
--
-- A quiet-hours deferral claims at 02:14 and delivers at 08:00. Merged into one
-- table, sent_at would have to mean both instants at once, and every consumer
-- would have to know which one it was looking at. Keeping the claim immutable
-- is also what lets it be the dedupe constraint: a row that gets UPDATEd
-- through delivery states is a row whose unique constraint no longer means
-- "already decided".
--
-- Deliberately NOT a geography column in sight. A job references a party; it
-- does not copy the party's point or the device's. That is not an accident of
-- this table's design -- 08_proximity_and_retention.test.sql asserts over
-- pg_attribute that public holds exactly two geography columns, and any queue
-- that cached a coordinate "for convenience" would fail that test on purpose.


-- ============================================================
-- The table.
--
-- kind carries the same CHECK vocabulary as sent_notifications rather than a
-- narrower one, even though 7b only ever writes 'nearby_party'. The two tables
-- are keyed on the same triple and a job's kind has to round-trip against its
-- claim; a queue that could not express a kind the ledger can would be a
-- constraint mismatch waiting for whoever implements party_starting_soon.
--
-- scheduled_for defaults to now(), so the ordinary path -- not in quiet hours,
-- deliver immediately -- needs no special case in the enqueue statement.
--
-- expires_at is what makes deferral safe. A notification held until 08:00 for a
-- party that started at 23:30 is worse than no notification: it is a push about
-- something already over, and the user cannot tell it was deferred rather than
-- simply late. The engine sets this to the party's starts_at, so a stale job is
-- dropped by the worker instead of delivered.
--
-- attempts / last_error belong to 7c's retry loop and are unused here. They are
-- created now because adding columns to a queue that already has rows in it is
-- strictly worse than creating them empty, and because their absence would push
-- 7c toward retrying in memory, where a redeploy loses the count.
-- ============================================================
create table public.notification_jobs (
  id            bigint generated always as identity primary key,
  user_id       uuid references public.profiles(id) on delete cascade not null,
  party_id      uuid references public.parties(id)  on delete cascade not null,

  kind          text not null,
  scheduled_for timestamp with time zone default now() not null,
  expires_at    timestamp with time zone not null,

  status        text not null default 'pending',
  attempts      int  not null default 0,
  last_error    text,

  created_at    timestamp with time zone default now() not null,
  updated_at    timestamp with time zone default now() not null,

  constraint notification_jobs_kind_check
    check (kind in ('nearby_party', 'party_starting_soon')),

  constraint notification_jobs_status_check
    check (status in ('pending', 'sending', 'sent', 'failed', 'expired'))
);

alter table public.notification_jobs enable row level security;


-- ============================================================
-- Closed to clients, exactly like sent_notifications.
--
-- RLS enabled with NO policies and NO grants -- the shape story_media_purges
-- (20260815133041) and sent_notifications (20260816083807) already use for
-- engine bookkeeping. Reachable only by the table owner and by security definer
-- functions.
--
-- It is worth being explicit about why "let users read their own jobs" is not
-- offered, since it sounds harmless and every other user-scoped table here has
-- such a policy. A pending job says "this user is currently within 500m of this
-- party". That is a location disclosure with the coordinate filed off, and 7a
-- went to some trouble to make sure no client role can read a location. Adding
-- a SELECT policy here would reintroduce, by inference, the thing that table's
-- owner-only RLS exists to prevent.
--
-- The revoke first removes privileges nobody granted: Supabase's default ACL
-- hands anon and authenticated TRUNCATE, REFERENCES, TRIGGER and MAINTAIN on
-- every new table in public (CLAUDE.md gotcha #9). None is a data privilege, so
-- RLS is not bypassed -- but RLS does not mediate TRUNCATE, and an RLS-perfect
-- queue that anon can empty is not a protected queue. Nothing is granted back.
-- ============================================================
revoke all on public.notification_jobs from anon, authenticated;


-- The worker's hot path: "what is due right now". Partial on status so the
-- index stays proportional to outstanding work rather than to every
-- notification ever queued -- same reasoning as user_devices' partial GiST and
-- story_media_purges_open_idx.
create index notification_jobs_due_idx
  on public.notification_jobs (scheduled_for)
  where status = 'pending';

-- The daily cap's correlated subquery runs once per candidate user inside the
-- fan-out, which is the single most-executed lookup in the engine. Without this
-- it is a seq scan of the whole queue per candidate.
create index notification_jobs_user_created_idx
  on public.notification_jobs (user_id, created_at);

-- The sweep's cleanup pass. Partial for the same reason as the due index: the
-- rows worth deleting are a shrinking minority of a growing table.
create index notification_jobs_finished_idx
  on public.notification_jobs (updated_at)
  where status in ('sent', 'failed', 'expired');


-- ============================================================
-- updated_at is derived.
--
-- 7c moves jobs through pending -> sending -> sent/failed, and the cleanup pass
-- deletes on updated_at. If that column could drift from the last real status
-- change -- by being forgotten in an UPDATE rather than by being forged, since
-- no client role can write this table at all -- finished jobs would either be
-- purged early or never. A trigger means every writer stamps it, including the
-- ones written three phases from now.
-- ============================================================
create or replace function public.touch_notification_job()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger notification_jobs_touch
  before update on public.notification_jobs
  for each row execute function public.touch_notification_job();


comment on table public.notification_jobs is
  'Delivery outbox drained by 7c. Engine-internal: RLS on, no policies, no client grants. Distinct from sent_notifications, which is the immutable dedupe claim.';
comment on column public.notification_jobs.scheduled_for is
  'Earliest delivery instant. Set to quiet_hours_end_at() when the user was in a quiet window at enqueue time.';
comment on column public.notification_jobs.expires_at is
  'Party start. A deferred job past this is dropped, not delivered -- a push about a party that already started is worse than silence.';
