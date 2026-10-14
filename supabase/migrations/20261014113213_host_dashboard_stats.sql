-- Phase 39: the host dashboard's server half.
--
-- A host opening their own party gets a dashboard instead of the attendee
-- sheet: headline counters, RSVPs over time, followers vs. non-followers among
-- the guests, and the guest list. Four things are added here:
--
--   1. rsvp_count_events -- the history the over-time chart needs. rsvps has
--      only created_at, a status flip touches no timestamp, and an un-RSVP is
--      a DELETE that leaves nothing behind, so "how many were going on Tuesday"
--      was not answerable from anything the schema kept.
--   2. get_party_host_stats / get_party_rsvp_timeline -- aggregates, host-only.
--   3. get_party_guests -- the guest list, keyset-paginated, host-only.
--   4. party_host:{uuid} -- a realtime topic that tells the host's dashboard
--      "an rsvp on this party changed" so it can refetch.
--
-- Every one of the four answers to is_party_host and to nothing else. A guest
-- who can see the party does not get its stats; a private party's counters,
-- which every attendee-facing RPC NULLs (20260825090051), are returned here
-- because the only caller is the person who already has the guest list.


-- ===========================================================================
-- 1. The history.
--
-- Deltas, not snapshots, and NO user_id. The chart needs "how did the two
-- counters move, and when", which is exactly what sync_party_rsvp_counters
-- computes on every rsvp event -- so that function writes the row, in the
-- same statement as the counter update it describes. Two triggers would be
-- two copies of the delta arithmetic, and the chart and the headline number
-- could then disagree.
--
-- No user_id is the privacy decision. A row naming the user would be a second,
-- permanent record of every RSVP a person ever made and withdrew -- one the
-- rsvps table itself deliberately does not keep (un-RSVP is a DELETE, see
-- CLAUDE.md "rsvp_status has exactly two values") -- and it would need an
-- erasure path and an export entry. A delta with no identity needs neither:
-- when complete_account_erasure deletes a user's rsvps, the trigger writes the
-- matching -1s, which is exactly what the counters do too.
--
-- RLS on, zero policies, zero client grants: same arrangement as
-- sent_notifications. The only reader is get_party_rsvp_timeline, a definer.
-- ===========================================================================
create table public.rsvp_count_events (
  id bigint generated always as identity primary key,
  party_id uuid not null references public.parties(id) on delete cascade,
  occurred_at timestamptz not null default now(),
  going_delta smallint not null,
  interested_delta smallint not null,
  constraint rsvp_count_events_moves_something
    check (going_delta <> 0 or interested_delta <> 0)
);

alter table public.rsvp_count_events enable row level security;

-- Gotcha 9 / 23: nothing for the client roles, explicitly.
revoke all on public.rsvp_count_events from anon, authenticated;

create index rsvp_count_events_party_time
  on public.rsvp_count_events (party_id, occurred_at);

comment on table public.rsvp_count_events is
  'Append-only deltas of parties.going_count/interested_count, one row per rsvp '
  'event that moved them. No user_id, on purpose: the over-time chart needs '
  'the counters'' history, not anybody''s. Written only by '
  'sync_party_rsvp_counters; read only by get_party_rsvp_timeline.';


-- ===========================================================================
-- 2. The counter trigger, now also writing the history.
--
-- The arithmetic is 20260826093437's, unchanged: insert +1 interested (+1 going
-- if going), delete the reverse, a status flip moves going alone. Each branch
-- records the delta it just applied, and only `if found` -- i.e. only when the
-- parties row still exists. That guard is not cosmetic: when a party is
-- hard-deleted, its rsvps go by cascade and fire this trigger for a party that
-- is already gone, and an event row pointing at it would fail the foreign key
-- at the end of the statement, turning every party delete into an error.
-- ===========================================================================
create or replace function public.sync_party_rsvp_counters()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_going smallint;
begin
  if TG_OP = 'DELETE' then
    v_going := -((OLD.status = 'going')::int);
    update public.parties set
      going_count = going_count + v_going,
      -- Every rsvp counted as interested, so every delete decrements it,
      -- whichever status the departing row held.
      interested_count = interested_count - 1
    where id = OLD.party_id;
    if found then
      insert into public.rsvp_count_events (party_id, going_delta, interested_delta)
      values (OLD.party_id, v_going, -1);
    end if;
    return null;
  end if;

  if TG_OP = 'INSERT' then
    v_going := (NEW.status = 'going')::int;
    update public.parties set
      going_count = going_count + v_going,
      interested_count = interested_count + 1
    where id = NEW.party_id;
    if found then
      insert into public.rsvp_count_events (party_id, going_delta, interested_delta)
      values (NEW.party_id, v_going, 1);
    end if;
    return null;
  end if;

  -- TG_OP = 'UPDATE'
  --
  -- going_count only. interested_count does not move on a status change in
  -- EITHER direction (20260826093437), so the event's interested_delta is 0.
  if NEW.status is distinct from OLD.status then
    v_going := (NEW.status = 'going')::int - (OLD.status = 'going')::int;
    update public.parties set
      going_count = going_count + v_going
    where id = NEW.party_id;
    if found then
      insert into public.rsvp_count_events (party_id, going_delta, interested_delta)
      values (NEW.party_id, v_going, 0);
    end if;
  end if;
  return null;
end;
$$;

comment on function public.sync_party_rsvp_counters() is
  'Denormalized rsvp counters. interested_count counts EVERY rsvp; going_count '
  'counts the going subset of them, so going_count <= interested_count always. '
  'A status flip moves going_count only. Every delta applied is also appended '
  'to rsvp_count_events, so the counters and their history cannot disagree.';


-- ---------------------------------------------------------------------------
-- The backfill, and what it cannot know.
--
-- One +1 event per existing rsvp, at its created_at, with its CURRENT status.
-- That is approximate in two ways and nothing can make it exact: a row that
-- flipped interested -> going is drawn as going from the moment it was first
-- created, and an rsvp that was withdrawn before today left no row to backfill
-- from. From this migration on the history is exact.
--
-- Then the same kind of check 20260826093437 ended with: per party, the summed
-- deltas must equal the counters. A blind backfill plus a check, not a recount,
-- for that file's reason -- drift between rsvps and the counters is worth
-- failing the migration over, not papering over.
-- ---------------------------------------------------------------------------
insert into public.rsvp_count_events (party_id, occurred_at, going_delta, interested_delta)
select r.party_id, r.created_at, (r.status = 'going')::int, 1
from public.rsvps r;

do $$
declare
  v_bad int;
begin
  select count(*) into v_bad
  from public.parties p
  left join (
    select e.party_id, sum(e.going_delta) as g, sum(e.interested_delta) as i
    from public.rsvp_count_events e
    group by e.party_id
  ) s on s.party_id = p.id
  where coalesce(s.g, 0) <> p.going_count
     or coalesce(s.i, 0) <> p.interested_count;

  if v_bad > 0 then
    raise exception
      'rsvp_count_events backfill disagrees with the counters on % parties', v_bad;
  end if;
end;
$$;


-- ===========================================================================
-- 3. get_party_host_stats -- the header and the headline numbers.
--
-- Definer, because rsvp counters on a private party and the rsvps of
-- block-paired guests are both outside what the host's own RLS view shows,
-- and these are counts, not identities. Consequence worth knowing: with a
-- block in place, the followers + non-followers totals here can exceed the
-- number of rows get_party_guests returns. That is the guest list hiding a
-- name, not the numbers being wrong; the headline counters already include
-- that person and always have.
--
-- Works on cancelled and finished parties, unlike get_party: a host looks at
-- their dashboard after the night is over, and after cancelling.
--
-- "Follower" means someone who follows the HOST: follows.follower_id = guest,
-- followee_id = host. Gotcha 14 is about exactly this direction being easy to
-- swap, so 33_party_host_dashboard.test.sql asserts it with a follow edge in
-- the other direction that must NOT count.
--
-- Counts from rsvps rather than the counter columns for the split, because the
-- split has no counter; the headline numbers are the columns. Bounded: one
-- party, through the (party_id, ...) indexes.
-- ===========================================================================
create or replace function public.get_party_host_stats(p_party_id uuid)
returns table (
  party_id uuid,
  title text,
  description text,
  area text,
  starts_at timestamptz,
  ends_at timestamptz,
  cover_path text,
  is_private boolean,
  status public.party_status,
  lat double precision,
  lon double precision,
  is_live boolean,
  is_over boolean,
  going_count integer,
  interested_count integer,
  going_followers integer,
  going_non_followers integer,
  interested_followers integer,
  interested_non_followers integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_party_host(p_party_id) then
    raise exception 'not the host of party %', p_party_id using errcode = '42501';
  end if;

  return query
  select
    p.id,
    p.title,
    p.description,
    p.area,
    p.starts_at,
    p.ends_at,
    p.cover_path,
    p.is_private,
    p.status,
    public.st_y(p.location::public.geometry),
    public.st_x(p.location::public.geometry),
    p.status = 'published'
      and p.starts_at <= now()
      and not public.party_is_past(p.starts_at, p.ends_at),
    public.party_is_past(p.starts_at, p.ends_at),
    p.going_count,
    p.interested_count,
    coalesce(s.going_followers, 0)::int,
    coalesce(s.going_non_followers, 0)::int,
    coalesce(s.interested_followers, 0)::int,
    coalesce(s.interested_non_followers, 0)::int
  from public.parties p
  left join lateral (
    select
      count(*) filter (where r.status = 'going' and f.follower_id is not null) as going_followers,
      count(*) filter (where r.status = 'going' and f.follower_id is null) as going_non_followers,
      -- interested is the superset (20260826093437): every rsvp, going included.
      count(*) filter (where f.follower_id is not null) as interested_followers,
      count(*) filter (where f.follower_id is null) as interested_non_followers
    from public.rsvps r
    left join public.follows f
      on f.follower_id = r.user_id
     and f.followee_id = p.host_id
    where r.party_id = p.id
  ) s on true
  where p.id = p_party_id;
end;
$$;

comment on function public.get_party_host_stats(uuid) is
  'Host dashboard header and aggregates for one party. Host-only (42501 for '
  'anyone else). Returns private-party counters, unlike every attendee RPC. '
  'Followers = people who follow the host. No per-user data.';


-- ===========================================================================
-- 4. get_party_rsvp_timeline -- the chart.
--
-- Cumulative going / interested at the end of each bucket, from the first
-- event to the end of the party (or now, if it is still running), with
-- empty buckets filled in so the line stays flat across a quiet day rather
-- than drawing a diagonal through it.
--
-- Bucket: hour or day, chosen by the client or, if null, by the span -- hourly
-- for anything under 72 hours. Capped at 336 hourly / 400 daily rows: past the
-- cap the series starts later, with the earlier events folded into the first
-- row's baseline, so the numbers stay right and only the x-axis is shorter.
--
-- Days are the host's days, not UTC's: p_utc_offset_minutes shifts the
-- bucket boundaries. An offset rather than a zone name because the client can
-- always report its offset and cannot portably report an IANA name; the cost
-- is that a series straddling a DST change has one boundary an hour off,
-- which a daily RSVP chart can absorb.
-- ===========================================================================
create type public.stats_bucket as enum ('hour', 'day');

create or replace function public.get_party_rsvp_timeline(
  p_party_id uuid,
  p_bucket public.stats_bucket default null,
  p_utc_offset_minutes integer default 0
)
returns table (
  bucket_start timestamptz,
  bucket public.stats_bucket,
  going integer,
  interested integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_offset interval := make_interval(
    mins => greatest(-840, least(840, coalesce(p_utc_offset_minutes, 0))));
  v_first timestamptz;
  v_last timestamptz;
  v_end timestamptz;
  v_bucket public.stats_bucket;
  v_unit text;
  v_step interval;
  v_cap integer;
  v_start timestamptz;
  v_stop timestamptz;
begin
  if not public.is_party_host(p_party_id) then
    raise exception 'not the host of party %', p_party_id using errcode = '42501';
  end if;

  select min(e.occurred_at), max(e.occurred_at) into v_first, v_last
  from public.rsvp_count_events e
  where e.party_id = p_party_id;

  -- No events: no rows. The client draws "No RSVPs yet".
  if v_first is null then
    return;
  end if;

  -- The series runs to the end of the party, or to now if that is sooner, and
  -- never stops short of the last event (a withdrawal after the night).
  select greatest(
           v_last,
           least(now(), coalesce(p.ends_at, p.starts_at + public.party_end_grace())))
  into v_end
  from public.parties p
  where p.id = p_party_id;

  v_bucket := coalesce(
    p_bucket,
    case when v_end - v_first <= interval '72 hours'
         then 'hour'::public.stats_bucket
         else 'day'::public.stats_bucket end);
  v_unit := v_bucket::text;
  -- '24 hours', not '1 day': with a fixed offset there is no DST to follow,
  -- and '1 day' on timestamptz would follow the session's time zone instead.
  v_step := case v_bucket when 'hour' then interval '1 hour' else interval '24 hours' end;
  v_cap := case v_bucket when 'hour' then 336 else 400 end;

  -- Truncation in the host's offset, independent of the session TimeZone.
  v_start := (date_trunc(v_unit, (v_first at time zone 'UTC') + v_offset) - v_offset) at time zone 'UTC';
  v_stop := (date_trunc(v_unit, (v_end at time zone 'UTC') + v_offset) - v_offset) at time zone 'UTC';
  if v_stop - v_start > v_step * (v_cap - 1) then
    v_start := v_stop - v_step * (v_cap - 1);
  end if;

  return query
  with per_bucket as (
    select
      (date_trunc(v_unit, (e.occurred_at at time zone 'UTC') + v_offset) - v_offset)
        at time zone 'UTC' as b,
      sum(e.going_delta) as g,
      sum(e.interested_delta) as i
    from public.rsvp_count_events e
    where e.party_id = p_party_id
    group by 1
  ),
  baseline as (
    select coalesce(sum(pb.g), 0) as g0, coalesce(sum(pb.i), 0) as i0
    from per_bucket pb
    where pb.b < v_start
  ),
  series as (
    select gs as b from generate_series(v_start, v_stop, v_step) gs
  )
  select
    s.b,
    v_bucket,
    (bl.g0 + sum(coalesce(pb.g, 0)) over w)::int,
    (bl.i0 + sum(coalesce(pb.i, 0)) over w)::int
  from series s
  left join per_bucket pb on pb.b = s.b
  cross join baseline bl
  window w as (order by s.b)
  order by s.b;
end;
$$;

comment on function public.get_party_rsvp_timeline(uuid, public.stats_bucket, integer) is
  'Cumulative going/interested per hour or day for one party, gaps filled. '
  'Host-only (42501). Exact from 20261014113213 on; earlier rsvps are '
  'backfilled at their created_at with their status as of that migration.';


-- ===========================================================================
-- 5. get_party_guests -- the guest list.
--
-- INVOKER, unlike the two above, so the existing rules decide who is listed:
-- the rsvps SELECT policy already gives a host every row of their own party
-- except block-paired guests, and the profiles inner join applies the same
-- block filter. Nothing new is decided here; the explicit host check only
-- turns "a guest calling this sees their own row" into a refusal, so the
-- function means one thing.
--
-- p_going_only = false is the Interested tab, and it lists EVERYONE, going
-- included -- interested_count is the superset, so a tab that left the going
-- guests out would never match the headline number above it (decided D3).
--
-- Newest first, keyset on (created_at, user_id) with the matching index below
-- (CLAUDE.md rule 5).
-- ===========================================================================
create index rsvps_party_created_user
  on public.rsvps (party_id, created_at desc, user_id desc);

create or replace function public.get_party_guests(
  p_party_id uuid,
  p_going_only boolean default false,
  p_cursor_created_at timestamptz default null,
  p_cursor_user_id uuid default null,
  p_limit integer default 50
)
returns table (
  user_id uuid,
  username text,
  avatar_path text,
  status public.rsvp_status,
  follows_host boolean,
  created_at timestamptz
)
language plpgsql
stable
set search_path = ''
as $$
begin
  if not public.is_party_host(p_party_id) then
    raise exception 'not the host of party %', p_party_id using errcode = '42501';
  end if;

  return query
  select
    r.user_id,
    pr.username,
    pr.avatar_path,
    r.status,
    exists (
      select 1 from public.follows f
      join public.parties p on p.id = r.party_id
      where f.follower_id = r.user_id and f.followee_id = p.host_id
    ),
    r.created_at
  from public.rsvps r
  join public.profiles pr on pr.id = r.user_id
  where r.party_id = p_party_id
    and (not coalesce(p_going_only, false) or r.status = 'going')
    and (
      p_cursor_created_at is null
      or (r.created_at, r.user_id) < (p_cursor_created_at, p_cursor_user_id)
    )
  order by r.created_at desc, r.user_id desc
  limit greatest(1, least(coalesce(p_limit, 50), 100));
end;
$$;

comment on function public.get_party_guests(uuid, boolean, timestamptz, uuid, integer) is
  'The host''s guest list for one party, newest first, keyset-paginated. '
  'Invoker: block-paired guests are hidden by the existing policies. '
  'p_going_only=false lists every rsvp (interested is the superset).';


-- ===========================================================================
-- 6. party_host:{uuid} -- "something changed, refetch".
--
-- The inbox topic's shape (20261011125542): a SIGNAL, never content. The
-- payload is {party_id} and nothing else -- no user, no status -- and the
-- dashboard refetches through the functions above, so they stay the only
-- thing deciding what the host reads.
--
-- Not skipped for a block-paired guest, unlike the inbox: the headline
-- counters already move for that guest and always have, so the signal says
-- nothing the refetch would not, and skipping it would only leave the
-- dashboard showing a stale number.
--
-- Fail-closed exactly like the other three: the builder and parser are one
-- pair, the full-uuid regex keeps the parse total, a malformed topic is NULL,
-- and is_party_host(NULL) is false. 'party_host:' does not match '^party:'
-- (the colon is part of each prefix), so neither the party policy nor this one
-- can admit the other's channel -- asserted both ways.
-- ===========================================================================
create or replace function public.party_host_topic(p_party_id uuid)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'party_host:' || p_party_id::text;
$$;

create or replace function public.party_id_from_host_topic(p_topic text)
returns uuid
language sql
immutable
set search_path = ''
as $$
  select nullif(
    substring(
      p_topic
      from '^party_host:([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$'
    ),
    ''
  )::uuid;
$$;

create or replace function public.notify_party_host_rsvp()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_party_id uuid;
begin
  if TG_OP = 'UPDATE' and NEW.status is not distinct from OLD.status then
    return null;
  end if;

  v_party_id := case when TG_OP = 'DELETE' then OLD.party_id else NEW.party_id end;

  perform realtime.send(
    jsonb_build_object('party_id', v_party_id),
    'rsvp_activity',
    public.party_host_topic(v_party_id),
    true
  );
  return null;
end;
$$;

create trigger rsvps_notify_party_host
after insert or delete or update of status on public.rsvps
for each row execute function public.notify_party_host_rsvp();

-- The fourth SELECT policy on realtime.messages. Still no INSERT policy: the
-- trigger is the only writer (gotcha 5).
create policy "Hosts can join their party's host topic"
on realtime.messages for select to authenticated
using (
  extension = 'broadcast'
  and public.is_party_host(public.party_id_from_host_topic(realtime.topic()))
);


-- ===========================================================================
-- Grants. Default privileges are closed (20261004234903), so these are the
-- whole surface; each has its row in 27_explicit_grants.test.sql.
-- ===========================================================================
revoke execute on function public.get_party_host_stats(uuid) from public;
revoke execute on function public.get_party_rsvp_timeline(uuid, public.stats_bucket, integer) from public;
revoke execute on function public.get_party_guests(uuid, boolean, timestamptz, uuid, integer) from public;
revoke execute on function public.notify_party_host_rsvp() from public;

grant execute on function public.get_party_host_stats(uuid) to authenticated;
grant execute on function public.get_party_rsvp_timeline(uuid, public.stats_bucket, integer) to authenticated;
grant execute on function public.get_party_guests(uuid, boolean, timestamptz, uuid, integer) to authenticated;
