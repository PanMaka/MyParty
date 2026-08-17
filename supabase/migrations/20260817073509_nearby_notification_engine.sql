-- Phase 7b, part 3: the notification engine itself.
--
-- docs/backend-plan.md 7.1 is emphatic about the shape: EVENT-DRIVEN, not a
-- scheduled cross-join. A periodic user_devices x parties spatial join is
-- O(users x parties) per run and does zero useful work on almost every tick.
-- So there are exactly two spatial queries here, each triggered by the event
-- that could have changed the answer, and each fanning out from ONE row:
--
--   party published  -> which users are near THIS party?   (fan out)
--   device moved     -> which parties are near THIS user?  (fan in)
--
-- and one hourly sweep that exists only to catch what the triggers missed.
--
--
-- THE QUERY-PLAN FINDING THAT SHAPES EVERY SPATIAL QUERY BELOW
--
-- A per-user radius cannot drive a GiST index scan on its own. When the radius
-- comes from the row being spatially scanned, PostGIS has no constant to expand
-- the search box by, and the planner demotes the whole predicate to a filter:
--
--   Hash Join
--     Join Filter: st_dwithin(p.location, '...'::geography, pr.<radius>, true)
--     ->  Seq Scan on parties p                    <-- index not used at all
--
-- Adding a CONSTANT term alongside it restores the index scan, because the
-- constant is enough to bound the box:
--
--   ->  Index Scan using parties_location on parties p
--         Index Cond: (location && _st_expand('...'::geography, '5000'))
--
-- So every spatial predicate here is written TWICE on purpose:
--
--   st_dwithin(<geom>, <point>, 5000)                  -- indexable, bounds the box
--   and st_dwithin(<geom>, <point>, pr.notify_radius_meters)  -- exact answer
--
-- This is not belt-and-braces, and the second term is not redundant: the first
-- is a superset filter that only makes the index usable, the second is the
-- actual rule. Deleting either one breaks something different -- drop the
-- constant and you lose the index, drop the exact term and every user silently
-- gets a 5km radius.
--
-- The literal 5000 is the CHECK constraint on profiles.notify_radius_meters
-- (part 1), and it is correct ONLY while that constraint holds. Raising the cap
-- without editing these constants would silently truncate every wide-radius
-- user's reach to 5km. scripts/explain_proximity.sh prints both plans at
-- realistic volume, plus the seq-scanning naive variant, so the difference is
-- observable rather than asserted.


-- ============================================================
-- last_evaluated_at -- the movement debounce, at the cost of one timestamp.
--
-- 7.1 asks for re-evaluation only past some movement threshold. The threshold
-- is already in the schema and did not need a second geography column: 7a's
-- enforce_location_privacy rounds every incoming fix to a ~100m cell and only
-- restamps last_location_at when the CELL actually changes. So
-- `old.last_location is distinct from new.last_location` already means "moved
-- far enough to land in a different ~100m cell", and the trigger WHEN clauses
-- below use exactly that.
--
-- Storing a separate last_evaluated_location and measuring st_distance against
-- it would match 7.1's wording more literally and cost considerably more: a
-- second location column falls under the same 24h retention, the same consent
-- withdrawal trigger and the same column grants, and it would break
-- 08_proximity_and_retention.test.sql's pg_attribute assertion that public
-- holds exactly two geography columns. Doubling the location data retained in
-- order to more precisely decide whether to run a query is the wrong trade in
-- the one part of this schema where data minimisation is the point.
--
-- What the cell change alone does not handle is a user pacing a cell boundary,
-- who would re-trigger on every ping. That is what this column is for: a
-- 10-minute floor. The cost of hitting it is a query, not a notification --
-- dedupe already makes repeat evaluations harmless -- so the floor is about CPU
-- and nothing else.
--
-- Derived, like last_location_at and for the same reason (CLAUDE.md gotcha #8):
-- no column grant is added for it, so no client role can write it. A device
-- that could backdate its own last_evaluated_at could force re-evaluation on
-- every ping.
-- ============================================================
alter table public.user_devices add column last_evaluated_at timestamp with time zone;

comment on column public.user_devices.last_evaluated_at is
  'Derived, never client-written. Debounce floor for the movement trigger -- see 20260817073509.';


-- ============================================================
-- can_user_access_party -- can_access_party, minus the assumption that the
-- person being asked about is the caller.
--
-- can_access_party(p_party_id) answers about (select auth.uid()). That is
-- correct for every RLS policy, which is what it was written for, and useless
-- here: the engine asks "may THIS OTHER USER see this party" from inside a
-- trigger fired by a completely different person -- often by the host, whose
-- own access says nothing about the audience's.
--
-- Restating the visibility rule in the engine would violate CLAUDE.md #4 and,
-- worse, would put a second copy of the private-party rule in the one place
-- that fans out to thousands of users at once. So the body moves down into a
-- parameterised function and can_access_party becomes a one-line delegation.
-- One implementation, two entry points, and the signature every existing policy
-- binds to is unchanged.
--
-- This is a pure refactor of 20260814094945's definition -- the auth.uid()
-- references become p_user_id and nothing else changes. can_access_party is
-- used by the parties, rsvps, party_posts, stories and invitations policies, so
-- any semantic drift here would be a visibility change across half the schema.
--
-- is_blocked already returns false when either argument is null, so an anon
-- caller (auth.uid() null) behaves exactly as before.
-- ============================================================
create or replace function public.can_user_access_party(p_user_id uuid, p_party_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1
    from public.parties p
    where p.id = p_party_id
    and not public.is_blocked(p_user_id, p.host_id)
    and (
      not p.is_private
      or p.host_id = p_user_id
      or exists (
        select 1
        from public.invitations i
        where i.party_id = p.id
        and i.guest_id = p_user_id
      )
    )
  );
$$;

-- Not granted to clients: it is reached only through can_access_party (which is
-- security definer and therefore runs this as the owner) and through the engine
-- functions below. Handing clients a way to ask about a third party's access
-- would be a new capability, and nothing needs it.
revoke execute on function public.can_user_access_party(uuid, uuid)
  from public, anon, authenticated;

create or replace function public.can_access_party(p_party_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select public.can_user_access_party((select auth.uid()), p_party_id);
$$;

comment on function public.can_user_access_party(uuid, uuid) is
  'Party visibility for an arbitrary user. can_access_party is this, bound to auth.uid(). One rule, two entry points -- CLAUDE.md #4.';


-- ============================================================
-- wants_nearby_notifications -- the preference gate, in one place.
--
-- Two columns, one question, and it is asked from three call sites (the fan-out
-- statement, and both movement-trigger early exits). Inlining it would be the
-- kind of duplicated predicate that drifts: the day someone adds a third
-- condition, two of the three sites get it.
--
-- push_consent and notify_nearby are deliberately separate inputs -- one is a
-- consent state, one is a product setting (part 1) -- but every consumer in
-- this engine wants their conjunction, so the conjunction is what gets a name.
--
-- Note what is NOT here: location consent. A user who withdrew it has had every
-- last_location nulled by 7a's withdrawal trigger, so `last_location is not
-- null` in the fan-out already excludes them. Re-checking the consent flag would
-- be a second copy of a rule 7a enforces structurally.
--
-- security definer for CLAUDE.md gotcha #1: profiles' SELECT policy is
-- block-filtered and this is asked about other users.
-- ============================================================
create or replace function public.wants_nearby_notifications(p_user_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select coalesce(
    (select p.push_consent and p.notify_nearby
     from public.profiles p where p.id = p_user_id),
    false
  );
$$;

revoke execute on function public.wants_nearby_notifications(uuid)
  from public, anon, authenticated;


-- ============================================================
-- enqueue_nearby_party_notifications -- the single place a notification is
-- decided on, for BOTH directions.
--
-- The two triggers find different candidate sets, but the RULES about who
-- actually gets notified -- consent, preference, radius, blocks, private
-- parties, the daily cap, quiet hours, dedupe -- must not exist twice. So the
-- movement trigger does not enqueue anything itself: it finds nearby party ids
-- and calls this, narrowed to one user via p_only_user_id. Fan-out and fan-in
-- converge on one statement.
--
-- p_only_user_id null  -> every nearby user   (party published)
-- p_only_user_id set   -> just that user      (device moved)
--
-- With it set the candidate scan is an index lookup on user_devices_user_id_idx
-- rather than a spatial scan, so the fan-in path does not pay for a fan-out it
-- would immediately discard.
--
-- Returns the number of JOBS created, which is also the number of new dedupe
-- claims -- the sweep sums it, and a return value of 0 is the normal, healthy
-- answer for a party everyone nearby has already heard about.
-- ============================================================
create or replace function public.enqueue_nearby_party_notifications(
  p_party_id     uuid,
  p_only_user_id uuid default null
)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location   public.geography;
  v_host_id    uuid;
  v_starts_at  timestamptz;
  v_enqueued   int;
begin
  -- The guard, and the reason it is a guard rather than a WHERE term: these are
  -- properties of the PARTY, so one lookup settles them for the whole fan-out
  -- instead of being re-evaluated against every candidate user.
  --
  -- `not is_private` is the interesting one, and it is NOT redundant with
  -- can_user_access_party below. That helper answers "may this user see this
  -- party", which is true for an invitee of a private party. This asks
  -- something narrower: may we push it at someone unprompted. A proximity ping
  -- about a private party would tell an invitee's lock screen -- and anyone
  -- glancing at it -- that they are standing near a party whose whole design is
  -- that it is not discoverable. Invitees already got an invitation; they do
  -- not need to be found by GPS.
  select p.location, p.host_id, p.starts_at
    into v_location, v_host_id, v_starts_at
  from public.parties p
  where p.id = p_party_id
    and p.status = 'published'
    and not p.is_private
    and p.starts_at > now();

  if not found then
    return 0;
  end if;

  with candidates as (
    -- SPATIAL QUERY 1 of 2: fan out from one party to nearby users.
    -- Rides user_devices_last_location_gist (partial, `where last_location is
    -- not null`, from 20260816083807). See the header for why the radius is
    -- expressed as two terms.
    select distinct d.user_id
    from public.user_devices d
    join public.profiles pr on pr.id = d.user_id
    where d.last_location is not null
      and (p_only_user_id is null or d.user_id = p_only_user_id)

      and public.st_dwithin(d.last_location, v_location, 5000)
      and public.st_dwithin(d.last_location, v_location, pr.notify_radius_meters)

      and public.wants_nearby_notifications(pr.id)

      -- Hosts do not get told they are near their own party.
      and pr.id <> v_host_id

      -- Blocks and private-party visibility, inherited rather than restated.
      and public.can_user_access_party(pr.id, p_party_id)

      -- Per-user daily cap, counted over the user's OWN local day -- a "daily"
      -- limit measured in UTC would reset mid-evening for most of the world.
      and (
        select count(*)
        from public.notification_jobs j
        where j.user_id = pr.id
          and j.created_at >= date_trunc('day', now() at time zone pr.notification_tz)
                              at time zone pr.notification_tz
      ) < pr.notify_daily_cap
  ),
  claimed as (
    -- Dedupe is the constraint, not a preceding `not exists` check. The publish
    -- trigger, the movement trigger and the hourly sweep all race for this row
    -- by design, and a read-then-write would have a window between the read and
    -- the write that all three could pass through. `on conflict do nothing
    -- ... returning` closes it: only genuinely new claims come back, so exactly
    -- one job is created no matter how many callers arrive at once.
    insert into public.sent_notifications (user_id, party_id, kind)
    select c.user_id, p_party_id, 'nearby_party'
    from candidates c
    on conflict on constraint sent_notifications_once_per_user_party_kind
      do nothing
    returning user_id
  )
  insert into public.notification_jobs
    (user_id, party_id, kind, scheduled_for, expires_at)
  select
    c.user_id,
    p_party_id,
    'nearby_party',
    -- Quiet hours DEFER, they do not suppress. The decision was made now; only
    -- delivery moves to the end of the user's window.
    case
      when public.in_quiet_hours(c.user_id, now())
        then public.quiet_hours_end_at(c.user_id, now())
      else now()
    end,
    -- ...and a deferred job for a party that has already started is dropped by
    -- the worker rather than delivered. A 08:00 push about a party that ended
    -- at 02:00 is worse than silence.
    v_starts_at
  from claimed c;

  get diagnostics v_enqueued = row_count;
  return v_enqueued;
end;
$$;

revoke execute on function public.enqueue_nearby_party_notifications(uuid, uuid)
  from public, anon, authenticated;

comment on function public.enqueue_nearby_party_notifications(uuid, uuid) is
  'Claims dedupe rows and enqueues jobs for users near a party. p_only_user_id narrows it to the fan-in direction. The one place notification rules live.';


-- ============================================================
-- Trigger 1: a party is published.
--
-- Two triggers share one function because TG_OP is not available in a WHEN
-- clause and OLD does not exist on INSERT -- so "published on insert" and
-- "transitioned to published" cannot be one condition. Both are real: most
-- parties are created already published (create_party_with_invites defaults to
-- it), but the draft -> published path exists in the enum and must not be the
-- one that silently notifies nobody.
--
-- `old.status is distinct from 'published'` rather than `old.status = 'draft'`:
-- the transition that matters is INTO published from anything else, including a
-- cancelled party being reinstated. Re-saving an already-published party fires
-- nothing, which is what keeps an edit from re-notifying the neighbourhood --
-- and dedupe would catch it anyway, which is the point of having both.
--
-- AFTER, so the row is committed-visible to the fan-out's own reads.
-- ============================================================
create or replace function public.notify_on_party_publish()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.enqueue_nearby_party_notifications(new.id);
  return null;
end;
$$;

create trigger parties_notify_on_insert
  after insert on public.parties
  for each row
  when (new.status = 'published' and not new.is_private)
  execute function public.notify_on_party_publish();

create trigger parties_notify_on_publish
  after update of status on public.parties
  for each row
  when (
    new.status = 'published'
    and old.status is distinct from 'published'
    and not new.is_private
  )
  execute function public.notify_on_party_publish();


-- ============================================================
-- Trigger 2: a device moved to a new ~100m cell.
--
-- Same two-trigger split, same reason. The WHEN clauses carry the distance half
-- of the debounce (the cell changed); the function carries the time half.
--
-- The self-UPDATE at the end is safe against recursion, and specifically
-- because of how `update of last_location` is defined: that clause fires when
-- the column appears in the statement's SET list, and this update sets only
-- last_evaluated_at. The BEFORE trigger from 7a does fire again -- it stamps
-- updated_at and re-rounds an already-rounded point, both idempotent -- and it
-- does NOT restamp last_location_at, because the location did not change. The
-- 24h retention clock is therefore untouched by evaluation, which matters: a
-- device being evaluated must not thereby extend how long its location is kept.
-- ============================================================
create or replace function public.notify_on_device_move()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_radius int;
  v_party  record;
begin
  -- Time half of the debounce. A user pacing a cell boundary flips
  -- last_location back and forth and would otherwise re-run the spatial query
  -- on every ping; dedupe makes that harmless but not free.
  if new.last_evaluated_at is not null
     and new.last_evaluated_at > now() - interval '10 minutes' then
    return null;
  end if;

  -- Cheapest gate first, and it is the shared helper rather than an inline
  -- copy of the same two columns.
  if not public.wants_nearby_notifications(new.user_id) then
    return null;
  end if;

  select pr.notify_radius_meters into v_radius
  from public.profiles pr
  where pr.id = new.user_id;

  -- SPATIAL QUERY 2 of 2: fan in from one user to nearby parties.
  -- Rides parties_location (GiST, from 20260708114539). Two-term radius for the
  -- same reason as query 1 -- v_radius is a plpgsql variable, so the planner
  -- sees a parameter rather than a constant and the bounded box still comes
  -- from the literal.
  for v_party in
    select p.id
    from public.parties p
    where p.status = 'published'
      and not p.is_private
      and p.starts_at > now()
      and public.st_dwithin(p.location, new.last_location, 5000)
      and public.st_dwithin(p.location, new.last_location, v_radius)
  loop
    -- Narrowed to this user: the rules live in one place, and the fan-out this
    -- would otherwise do for every other nearby user is not repeated here.
    perform public.enqueue_nearby_party_notifications(v_party.id, new.user_id);
  end loop;

  update public.user_devices
  set last_evaluated_at = now()
  where id = new.id;

  return null;
end;
$$;

create trigger user_devices_notify_on_insert
  after insert on public.user_devices
  for each row
  when (new.last_location is not null)
  execute function public.notify_on_device_move();

create trigger user_devices_notify_on_move
  after update of last_location on public.user_devices
  for each row
  when (
    new.last_location is not null
    and old.last_location is distinct from new.last_location
  )
  execute function public.notify_on_device_move();


-- ============================================================
-- The safety net -- and it must stay a safety net.
--
-- 7.1 is explicit that the hourly sweep "must not be the primary mechanism",
-- which is a statement about COST as much as about design. What stops this
-- becoming the O(users x parties) cross-join the phase was written to avoid is
-- that it never joins the two tables: it iterates a bounded set of parties and
-- calls the same per-party fan-out the publish trigger calls, each one a single
-- indexed spatial query.
--
-- The party set is bounded three ways -- published, public, and starting inside
-- the next 7 days -- and served by a partial index. The device side is bounded
-- for free by 7a's retention: a location older than 24h has already been nulled,
-- so the partial GiST only ever contains devices seen in the last day.
--
-- Almost every call returns 0, because the dedupe ledger already holds the
-- claim. That is what a healthy safety net looks like, and it is why the return
-- value is worth having: jobs_enqueued climbing steadily means the triggers are
-- not firing, which is a real incident with no other symptom.
--
-- The cleanup pass lives here rather than in run_location_retention (7a)
-- because that job is the GDPR one, and its header is explicit that it must be
-- the least likely thing in the schema to fail. Queue housekeeping is not
-- worth adding to its blast radius.
-- ============================================================
create index parties_upcoming_public_idx
  on public.parties (starts_at)
  where status = 'published' and not is_private;

create or replace function public.sweep_missed_nearby_notifications()
returns table (parties_scanned int, jobs_enqueued int, jobs_expired int, jobs_purged int)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_party    record;
  v_scanned  int := 0;
  v_enqueued int := 0;
  v_expired  int := 0;
  v_purged   int := 0;
begin
  for v_party in
    select p.id
    from public.parties p
    where p.status = 'published'
      and not p.is_private
      and p.starts_at > now()
      and p.starts_at < now() + interval '7 days'
  loop
    v_scanned  := v_scanned + 1;
    v_enqueued := v_enqueued + public.enqueue_nearby_party_notifications(v_party.id);
  end loop;

  -- A job whose party has started is never delivered. Marked rather than
  -- deleted so the purge below is the only thing that removes rows, and so an
  -- operator can see how much was aged out rather than merely how little was
  -- sent.
  update public.notification_jobs
  set status = 'expired'
  where status = 'pending'
    and expires_at <= now();

  get diagnostics v_expired = row_count;

  -- Finished work, kept a week for debugging "why did I get this" and then
  -- dropped. The dedupe ledger is the durable record (90 days, 7a); this table
  -- is a work queue and should not grow like a log.
  delete from public.notification_jobs
  where status in ('sent', 'failed', 'expired')
    and updated_at < now() - interval '7 days';

  get diagnostics v_purged = row_count;

  parties_scanned := v_scanned;
  jobs_enqueued   := v_enqueued;
  jobs_expired    := v_expired;
  jobs_purged     := v_purged;
  return next;
end;
$$;

revoke execute on function public.sweep_missed_nearby_notifications()
  from public, anon, authenticated;

comment on function public.sweep_missed_nearby_notifications() is
  'Hourly safety net for the two triggers, plus queue housekeeping. Never the primary path -- docs/backend-plan.md 7.1.';


-- ============================================================
-- The schedule. Hourly, exactly as 7.1 specifies.
--
-- Unlike location-retention (*/10, where the interval IS the compliance
-- promise), the cadence here is not load-bearing: every notification this job
-- would produce should already have been produced by a trigger seconds after
-- the event. An hour of latency applies only to notifications that were going
-- to be lost entirely.
--
-- unschedule-then-schedule for idempotency against a database that already has
-- the job -- cron.job is not part of the migration history, so it survives
-- things migrations do not, and there is no `create ... if not exists`
-- analogue. Same pattern as story-cleanup (20260815133041) and
-- location-retention (20260816083809).
-- ============================================================
select cron.unschedule('nearby-notification-sweep')
where exists (select 1 from cron.job where jobname = 'nearby-notification-sweep');

select cron.schedule(
  'nearby-notification-sweep',
  '0 * * * *',
  $cron$ select public.sweep_missed_nearby_notifications() $cron$
);
