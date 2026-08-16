-- Phase 7a, part 1: user_devices, sent_notifications, and the privacy
-- machinery that has to exist BEFORE either of them holds a single row.
--
-- docs/backend-plan.md 7.2 calls location the highest compliance risk in the
-- project, and the reason is that every other table here holds data the user
-- deliberately authored -- a party, a post, a message. A background location
-- ping is the opposite: it is collected while the phone is in a pocket, from
-- someone who is not looking at the app and will never see what was stored.
-- Nothing about that data can rely on the user noticing a mistake.
--
-- So the four rules from 7.2 are built as MECHANISM, not documentation:
--
--   1. No location without consent    -- the RLS WITH CHECK refuses the write.
--   2. Rounded to ~100m before store  -- a BEFORE trigger rewrites NEW, so the
--                                        precise value never reaches the heap.
--   3. Last value only, no history    -- one nullable column, no history table,
--                                        and no audit trail to leak instead.
--   4. Nulled after 24h               -- part 2 (…_location_retention_job).
--
-- Rule 2 is a trigger and not merely an RPC on purpose. An RPC is the path the
-- client takes; a trigger is the path EVERY writer takes, including the next
-- migration, a psql session, and whatever 7b/7c end up adding. "Raw coordinates
-- never touch disk" is only true if it is impossible, not if it is polite.
--
-- What this file deliberately does NOT do: nothing here sends anything. The
-- triggers, dedupe and quiet hours are 7b, delivery is 7c. This is the schema
-- and the retention floor they will both sit on.


-- ============================================================
-- round_location -- rule 2's arithmetic, in one place (CLAUDE.md #4).
--
-- Three decimal places of WGS-84. 0.001 degrees of latitude is ~111m
-- everywhere; 0.001 degrees of longitude is 111m x cos(lat), so ~87m at
-- Athens' 38degN and tighter further from the equator. That lands the grid cell
-- at "about 100m" from the north side, which is the resolution 7.2 asks for
-- and comfortably coarser than a building.
--
-- ~100m is not an arbitrary round number: proximity notifications are pitched
-- at a 500m radius (7c), so a 100m cell is an order of magnitude finer than the
-- question being asked and there is no accuracy left to buy. Storing more would
-- be collecting precision the feature has no use for, which is the exact thing
-- data minimisation prohibits.
--
-- NOT security definer -- it reads nothing and touches no table, so there is no
-- privilege to elevate and CLAUDE.md #3 does not apply. It does still pin a
-- search_path, because it resolves PostGIS operators and the extension's schema
-- differs between a stack where postgis landed in public and one where it
-- landed in extensions; naming both means this file does not have to guess.
-- Immutable, so the planner may fold it and an expression index over it would
-- be legal later.
-- ============================================================
create or replace function public.round_location(p_location geography)
returns geography
language sql
immutable
set search_path = public, extensions
as $$
  select case
    when p_location is null then null
    else st_setsrid(
           st_makepoint(
             round(st_x(p_location::geometry)::numeric, 3)::double precision,
             round(st_y(p_location::geometry)::numeric, 3)::double precision
           ),
           4326
         )::geography
  end;
$$;

comment on function public.round_location(geography) is
  'Rounds a WGS-84 point to 3 decimal places (~100m). GDPR data minimisation, docs/backend-plan.md 7.2.';


-- ============================================================
-- has_location_consent -- rule 1's predicate, in one place (CLAUDE.md #4).
--
-- security definer for CLAUDE.md gotcha #1. The profiles SELECT policy is
-- block-filtered, so any function reading public.profiles to answer a question
-- that is NOT about the caller's own visible world has to run as owner or it
-- silently gets the caller's filtered view instead of the truth. Today every
-- call site asks about the caller's own row, where the filter cannot bite --
-- but this is a consent check, and the failure mode of getting it wrong is
-- "stores a location the user refused", so it does not get to depend on the
-- call site staying that way.
--
-- coalesce to false, not null: a missing profile row must read as NO consent.
-- Three-valued logic inside an RLS WITH CHECK already fails closed, but a
-- helper whose answer to "may I keep this person's location" can be NULL is one
-- refactor away from being read as true somewhere.
-- ============================================================
create or replace function public.has_location_consent(p_user_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select coalesce(
    (select p.location_consent from public.profiles p where p.id = p_user_id),
    false
  );
$$;

revoke execute on function public.has_location_consent(uuid) from public;
grant execute on function public.has_location_consent(uuid) to authenticated;

comment on function public.has_location_consent(uuid) is
  'True only if the profile exists and location_consent is set. Called from the user_devices WITH CHECK.';


-- ============================================================
-- user_devices
--
-- One row per device INSTALL, not per user: a user with a phone and a tablet
-- gets two rows, each with its own push token and its own last known cell.
--
-- push_token is globally unique, not unique per user. A token identifies a
-- device install to FCM/APNs, so two rows carrying the same token are two
-- notifications arriving on one phone -- the duplicate 7.1's dedupe cannot
-- catch, because it dedupes on (user, party, kind) and both sends are for
-- different users. The constraint is what makes that unrepresentable.
--
-- The consequence, which 7c has to handle rather than work around: when user B
-- signs in on a phone that user A used, B's upsert conflicts with a row B
-- cannot see (owner-only RLS below), and ON CONFLICT DO UPDATE fails instead of
-- stealing it. That is the correct failure. The fix is for the client to DELETE
-- its device row on sign-out -- which is why the delete policy exists -- and
-- never to widen the RLS so one user may overwrite another's row.
--
-- last_location is NULLABLE and that is load-bearing in three separate ways:
--   - a device may register for push with no location consent at all;
--   - withdrawing consent nulls it (trigger below) without losing the token;
--   - the 24h retention job nulls it (part 2) without losing the token.
-- A NOT NULL column here would have forced all three of those to delete the
-- row, i.e. to silently unsubscribe the user from push as the price of
-- location privacy.
--
-- last_location_at is what "older than 24h" is measured from, and it is
-- DERIVED -- the trigger sets it, and no client role holds a grant on the
-- column. If it were client-writable, a device could pin its own location past
-- retention by restamping it, which is the one thing rule 4 exists to prevent.
--
-- There is deliberately no location history table, here or anywhere: 7.2 rule
-- 3. A "device_location_history" would be a movement profile, which is special
-- category data under GDPR the moment it reveals where someone sleeps -- and a
-- 24h retention rule on the live column means nothing if every value it ever
-- held is preserved next door.
-- ============================================================
create table public.user_devices (
  id uuid default gen_random_uuid() primary key,
  user_id uuid references public.profiles(id) on delete cascade not null,

  push_token text not null unique,
  platform text not null,

  last_location geography(POINT, 4326),
  last_location_at timestamp with time zone,

  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,

  constraint user_devices_platform_check
    check (platform in ('ios', 'android', 'web')),

  -- The two columns move together or the retention job has nothing to measure.
  -- A location with no timestamp is a location that is never older than 24h.
  constraint user_devices_location_timestamped
    check ((last_location is null) = (last_location_at is null))
);

alter table public.user_devices enable row level security;

comment on table public.user_devices is
  'Push tokens and last known ~100m location cell. Location is consent-gated, rounded before storage, and nulled after 24h -- docs/backend-plan.md 7.2.';
comment on column public.user_devices.last_location is
  'Rounded to ~100m by enforce_location_privacy before it is written. Never stores a raw fix.';
comment on column public.user_devices.last_location_at is
  'Derived, never client-written. The clock the 24h retention job reads.';


-- The GiST index 7b's party-publish fan-out rides: "who is within 500m of this
-- one party" is a single st_dwithin against this index, which is what keeps the
-- design event-driven instead of the O(users x parties) cross-join 7.1 rejects.
--
-- Partial, because the null population is not small -- every device whose
-- location was just cleared by retention, plus every user who never consented,
-- lives in it permanently, and none of them can ever match a proximity query.
-- Indexing them would be paying storage and vacuum cost for rows that are
-- unreachable by construction.
create index user_devices_last_location_gist
  on public.user_devices using gist (last_location)
  where last_location is not null;

-- The retention sweep's working set, same partial-index reasoning as
-- story_media_purges_open_idx (20260815133041): the sweep stays proportional to
-- the rows that still hold a location, not to every device ever registered.
create index user_devices_stale_location_idx
  on public.user_devices (last_location_at)
  where last_location is not null;

-- "My devices" -- the client's own list, and 7c's fan-out from a user to their
-- tokens once a job has been matched.
create index user_devices_user_id_idx on public.user_devices (user_id);


-- ============================================================
-- parties.location GiST -- deliverable: verify Phase 0's index exists.
--
-- It does: `create index parties_location on public.parties using gist
-- (location)` in 20260708114539_schema.sql. This block asserts that rather than
-- assuming it, and creates one only if it has gone missing, because the check
-- is cheap and the failure it guards is expensive and silent: without a GiST
-- index the spatial queries still return correct answers, by sequential scan,
-- and the only symptom is a notification pipeline that gets slower as the
-- product succeeds.
--
-- It matches on the INDEX METHOD AND COLUMN, not on the name. An index renamed
-- by some future migration still counts; an index that was dropped does not.
-- Idempotent, so a re-run creates nothing.
-- ============================================================
do $$
begin
  if not exists (
    select 1
    from pg_index i
    join pg_class c on c.oid = i.indexrelid
    join pg_am am on am.oid = c.relam
    where i.indrelid = 'public.parties'::regclass
    and am.amname = 'gist'
    and (
      select attname from pg_attribute
      where attrelid = i.indrelid and attnum = i.indkey[0]
    ) = 'location'
  ) then
    raise notice 'parties.location had no GiST index; creating parties_location_gist';
    create index parties_location_gist on public.parties using gist (location);
  end if;
end;
$$;


-- ============================================================
-- enforce_location_privacy -- rule 2, on the only path there is.
--
-- BEFORE INSERT OR UPDATE, so the rounding happens to NEW while the tuple is
-- still a value in memory. What reaches the heap, the WAL, the replicas and
-- every backup taken from them is the rounded point; the precise fix exists
-- only for the lifetime of the statement. That is the difference between "we
-- round it" and "we do not hold it", and only the second one survives a subject
-- access request.
--
-- (The one place a raw coordinate still appears is the statement text itself,
-- if a stack is running log_statement = 'all'. Nothing in SQL can fix that --
-- 7c's client should also round before sending, as defence in depth, and this
-- trigger is what makes it safe that it might not.)
--
-- last_location_at is restamped only when the point actually CHANGES. A device
-- re-reporting the identical cell does not refresh its 24h clock, so a phone
-- sitting still gets cleared on schedule and simply re-registers on its next
-- ping. That errs toward holding the data for less time than the rule allows,
-- which is the only direction worth erring in here.
--
-- The else-branch leaves NEW.last_location_at as supplied rather than forcing
-- it back to OLD -- that is what lets an owner-level backdate (the retention
-- test) work at all. It is not a hole: no client role has a grant on the
-- column, so "as supplied" can only ever mean "supplied by the table owner".
-- ============================================================
create or replace function public.enforce_location_privacy()
returns trigger
language plpgsql
set search_path = public, extensions
as $$
begin
  new.updated_at := now();

  if new.last_location is null then
    -- Keeps user_devices_location_timestamped satisfied without the caller
    -- having to know the constraint exists. Every path that drops a location --
    -- consent withdrawal, the 24h sweep, a client clearing it -- lands here.
    new.last_location_at := null;
    return new;
  end if;

  new.last_location := public.round_location(new.last_location);

  if tg_op = 'INSERT' or old.last_location is distinct from new.last_location then
    new.last_location_at := now();
  end if;

  return new;
end;
$$;

create trigger user_devices_enforce_location_privacy
  before insert or update on public.user_devices
  for each row execute function public.enforce_location_privacy();


-- ============================================================
-- Consent withdrawal clears what consent bought.
--
-- Untoggling "share my location" has to remove the location already held, not
-- merely stop collecting new ones -- GDPR Art. 7(3) withdrawal, and the plain
-- reading of the switch. Waiting for the 24h job would leave the user staring
-- at an off toggle while the last cell is still on disk and still matchable by
-- 7b's proximity queries.
--
-- The token and the row survive: withdrawing location consent is not
-- withdrawing push consent, and conflating them would silently unsubscribe
-- people from notifications they did agree to.
--
-- security definer because the writer of profiles.location_consent is not
-- always the owner of the device rows -- a support or admin path flipping the
-- flag on someone's behalf must still clear their locations, and under invoker
-- rights the UPDATE would match zero rows and report success.
-- ============================================================
create or replace function public.clear_locations_on_consent_withdrawal()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.user_devices
  set last_location = null
  where user_id = new.id
  and last_location is not null;

  return new;
end;
$$;

create trigger profiles_consent_withdrawal_clears_locations
  after update of location_consent on public.profiles
  for each row
  when (old.location_consent is true and new.location_consent is not true)
  execute function public.clear_locations_on_consent_withdrawal();


-- ============================================================
-- RLS: owner only, every verb. Nobody reads another user's location, ever.
--
-- There is no "followers can see me nearby" tier and no host exception. The
-- entire proximity feature is served by 7b's security definer functions, which
-- run as owner and hand out a notification rather than a coordinate -- so the
-- product never needs one user to be able to SELECT another's location, and
-- therefore no policy here should ever be widened to allow it. If a future
-- feature seems to need it, it needs a definer function, not a policy.
--
-- `(select auth.uid())` throughout, never bare auth.uid() -- CLAUDE.md #2.
--
-- The consent term is repeated in both WITH CHECKs on purpose. Putting it only
-- on INSERT would let a client insert a row with no location while consent is
-- false, then UPDATE a location into it -- the same row, the same absence of
-- consent, through the door nobody checked.
--
-- Why `last_location is null or has_location_consent(...)` rather than a flat
-- consent requirement: registering for PUSH is a separate act with separate
-- consent (profiles.push_consent), and a device that only ever wants
-- "so-and-so invited you" notifications must be able to exist without ever
-- offering a coordinate. What 7.2 forbids is storing the LOCATION without
-- consent, and that is exactly what this refuses -- on insert and on update,
-- for a fresh row or an existing one.
-- ============================================================
create policy "Users can see only their own devices"
  on public.user_devices for select
  to authenticated
  using (user_id = (select auth.uid()));

create policy "Users can register their own devices, with location consent"
  on public.user_devices for insert
  to authenticated
  with check (
    user_id = (select auth.uid())
    and (
      last_location is null
      or public.has_location_consent((select auth.uid()))
    )
  );

create policy "Users can update their own devices, with location consent"
  on public.user_devices for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and (
      last_location is null
      or public.has_location_consent((select auth.uid()))
    )
  );

-- Sign-out and "forget this device" both land here. Without it, the only way to
-- stop a stale token would be to wait for FCM to reject it (7c), which means a
-- signed-out phone keeps buzzing in the meantime.
create policy "Users can delete their own devices"
  on public.user_devices for delete
  to authenticated
  using (user_id = (select auth.uid()));


-- Grants are column-scoped on write, which is the layer RLS cannot express:
-- a policy filters rows, it cannot say "not this column". last_location_at,
-- created_at and updated_at are derived, and the only way to keep them derived
-- against a client that can write arbitrary JSON is to withhold the privilege.
--
-- Nothing to anon. An unauthenticated caller has no device and no location, and
-- every policy above is `to authenticated`, so a grant here would only produce
-- confusing empty results instead of the honest 42501 -- CLAUDE.md gotcha #4.
--
-- The `revoke all` first is not belt-and-braces, it removes privileges this
-- table is created holding. Supabase ships a default ACL (`alter default
-- privileges in schema public ... for role postgres`) that hands anon,
-- authenticated and service_role TRUNCATE, REFERENCES, TRIGGER and MAINTAIN on
-- every new table in public -- no data access, so RLS is not bypassed and
-- nothing here is readable, but TRUNCATE is not a data privilege and RLS does
-- not filter it. Left alone, `anon` could empty this table. PostgREST exposes
-- no route to TRUNCATE, so it is unreachable in practice, which is exactly why
-- it is worth removing explicitly rather than relying on the absence of a route.
--
-- This is a project-wide default and every table created before this phase
-- still carries it; fixing those is a hardening pass (Phase 10), not something
-- to bury in a proximity migration. These two tables get it now because they
-- are the two most privacy-sensitive in the schema.
revoke all on public.user_devices from anon, authenticated;

grant select, delete on public.user_devices to authenticated;
grant insert (id, user_id, push_token, platform, last_location) on public.user_devices to authenticated;
grant update (push_token, platform, last_location) on public.user_devices to authenticated;


-- ============================================================
-- sent_notifications -- the dedupe ledger from 7.1.
--
-- 7.1's rule is that every enqueue dedupes on (user, party, kind), and the
-- unique constraint below is that rule rather than a description of it: the
-- engine 7b builds inserts and lets a 23505 mean "already told them", so a
-- retry, a double trigger fire and the hourly safety-net sweep all converge on
-- one notification instead of racing to send three. Enforcing it with a `not
-- exists` check instead would be a read-then-write with a window in it, and the
-- safety-net sweep runs concurrently with the triggers by design.
--
-- 90-day retention (7.2), swept by part 2. It is kept that long because it is
-- the only record of what was sent -- "why did I get this at 3am" is
-- unanswerable without it -- and no longer, because past that point it is just
-- a log of who was near what.
--
-- RLS enabled with NO policies and NO grants, the same shape as
-- story_media_purges (20260815133041): invisible to anon and authenticated
-- alike, reachable only by the owner and by security definer functions. It is
-- engine bookkeeping. It is also, read the wrong way, a list of which users
-- were near which parties -- so it gets the tightest setting available rather
-- than a policy that lets people read "their own", which nothing needs.
-- ============================================================
create table public.sent_notifications (
  id bigint generated always as identity primary key,
  user_id uuid references public.profiles(id) on delete cascade not null,
  party_id uuid references public.parties(id) on delete cascade not null,
  kind text not null,
  sent_at timestamp with time zone default now() not null,

  constraint sent_notifications_kind_check
    check (kind in ('nearby_party', 'party_starting_soon')),

  -- 7.1's dedupe key. Named, because 7b catches this constraint by name.
  constraint sent_notifications_once_per_user_party_kind
    unique (user_id, party_id, kind)
);

alter table public.sent_notifications enable row level security;

-- Same Supabase default ACL as user_devices above: created holding TRUNCATE,
-- REFERENCES, TRIGGER and MAINTAIN for anon and authenticated. RLS with no
-- policies already denies every read and write, but "no policies" says nothing
-- about TRUNCATE, which RLS does not mediate at all. Nothing is granted back.
revoke all on public.sent_notifications from anon, authenticated;

-- The 90-day sweep's working set. No partial predicate is possible -- there is
-- no "already purged" state, rows are deleted -- so this is a plain btree that
-- the delete range-scans instead of seq-scanning the whole ledger.
create index sent_notifications_sent_at_idx on public.sent_notifications (sent_at);

comment on table public.sent_notifications is
  'Dedupe ledger for proximity pushes, keyed (user, party, kind) -- docs/backend-plan.md 7.1. 90-day retention. No client grants: engine-internal.';
