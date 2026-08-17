-- Phase 7b, part 1: the per-user knobs the notification engine reads.
--
-- docs/backend-plan.md 7.1 asks for three of these -- quiet hours, a per-user
-- daily cap, a per-user radius -- and they all live on public.profiles rather
-- than in a notification_preferences table of their own. That is the same shape
-- as location_consent / push_consent (20260813084353): one row per user that
-- already exists for every account, already has an owner-only UPDATE policy,
-- and is already read by everything that needs to know about a person. A
-- separate table would buy a join on the hottest path in the engine and nothing
-- else.
--
-- `grant update on public.profiles to authenticated` (20260812115436) is
-- table-wide and therefore already covers columns added later, so these are
-- client-writable the moment they exist -- which is correct, they are the
-- user's own preferences. What keeps them honest is CHECK constraints, not
-- grants: the radius cap in particular is load-bearing for the query plan (see
-- part 3), so it is enforced by the database rather than trusted from the
-- client.
--
-- The one column here that is not a preference is notification_tz, and it is
-- the reason this file exists separately from the engine. Quiet hours and a
-- "daily" cap are both LOCAL CALENDAR concepts. Stored in UTC they are not
-- merely imprecise, they are wrong for most of the year in most of the world --
-- a 23:00-08:00 quiet window means nothing without knowing whose 23:00.


-- ============================================================
-- The preference columns.
--
-- notify_nearby is a separate flag from push_consent on purpose, and it is the
-- same distinction 7a drew between push consent and location consent: consent
-- is a legal state, a preference is a product setting. Someone who agreed to
-- push but does not want proximity notifications should be able to say so
-- without withdrawing consent -- and, more importantly, the engine must not be
-- able to read "turned off the nearby feature" as "withdrew consent" or vice
-- versa. Two questions, two columns.
--
-- notify_radius_meters: 500m default because that is the target 7c is written
-- against ("a new party within 500m produces a notification in under 60s").
-- The 100m floor is the resolution limit -- 7a rounds every stored location to
-- a ~100m cell, so a radius below that would be asking a question the data
-- cannot answer.
--
-- The 5000m ceiling is NOT a product opinion, it is a query-planner
-- dependency. Part 3's spatial queries carry a constant st_dwithin term of
-- 5000 so that PostGIS can bound the GiST search box; a per-user radius alone
-- gets no index scan at all. That constant is only correct while no user can
-- exceed it, so the CHECK is what makes the plan sound. Raising the cap means
-- editing the constant in the same commit -- both are noted in part 3's header.
--
-- notify_daily_cap 0 is meaningful and allowed: it is "never send me a
-- proximity notification", reachable without touching consent.
-- ============================================================
alter table public.profiles
  add column notify_nearby        boolean not null default true,
  add column notify_radius_meters int     not null default 500,
  add column notify_daily_cap     int     not null default 5,
  add column quiet_hours_start    time,
  add column quiet_hours_end      time,
  add column notification_tz      text    not null default 'Europe/Athens';

alter table public.profiles
  add constraint profiles_notify_radius_check
    check (notify_radius_meters between 100 and 5000),

  add constraint profiles_notify_daily_cap_check
    check (notify_daily_cap between 0 and 50),

  -- Half a quiet window is not a quiet window, and the engine's wrap-around
  -- arithmetic below would have to invent a meaning for it. Both or neither.
  add constraint profiles_quiet_hours_paired
    check ((quiet_hours_start is null) = (quiet_hours_end is null)),

  -- start = end is ambiguous between "zero-length" and "all day", and the two
  -- readings differ by 24 hours of suppressed notifications. Refused rather
  -- than guessed. (The paired constraint above means start is null implies end
  -- is null, so the null branch here covers the no-quiet-hours case.)
  add constraint profiles_quiet_hours_distinct
    check (quiet_hours_start is null or quiet_hours_start <> quiet_hours_end);

comment on column public.profiles.notify_nearby is
  'Product preference for proximity pushes. Distinct from push_consent, which is a consent state.';
comment on column public.profiles.notify_radius_meters is
  'Per-user proximity radius. The 5000 ceiling is depended on by the constant st_dwithin term in the engine''s spatial queries -- raising it means editing that constant.';
comment on column public.profiles.notification_tz is
  'IANA zone that quiet hours and the daily cap are evaluated in. Validated by trigger against pg_timezone_names.';


-- ============================================================
-- notification_tz has to be a real zone, and this cannot be a CHECK.
--
-- pg_timezone_names is a view over the installed tzdata; it is not immutable
-- (a zone can appear or change meaning when tzdata is updated), so Postgres
-- refuses it inside a CHECK constraint. A trigger is the remaining mechanism.
--
-- Validating at all matters more than it looks. An invalid zone does not fail
-- when it is written -- it fails later, inside `p_at at time zone v_tz`, which
-- is called from in_quiet_hours, which is called from the enqueue path, which
-- is called from an AFTER trigger on party publish. A bad string in one user's
-- profile would surface as "creating a party throws 22023", with nothing in the
-- error pointing at a different user's settings row. Failing at the write puts
-- the error where the mistake is.
--
-- NOT security definer: it reads only a catalog view every role may read and
-- writes nothing, so there is no privilege to elevate (CLAUDE.md #3 applies to
-- definer functions). search_path is still pinned, and pg_timezone_names is
-- fully qualified accordingly.
-- ============================================================
create or replace function public.validate_notification_tz()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1 from pg_catalog.pg_timezone_names t
    where t.name = new.notification_tz
  ) then
    raise exception 'invalid notification_tz: %', new.notification_tz
      using errcode = '22023';
  end if;

  return new;
end;
$$;

create trigger profiles_validate_notification_tz
  before insert or update of notification_tz on public.profiles
  for each row execute function public.validate_notification_tz();


-- ============================================================
-- in_quiet_hours -- the predicate, in one place (CLAUDE.md #4).
--
-- security definer for CLAUDE.md gotcha #1. The profiles SELECT policy is
-- block-filtered, and this function is asked about OTHER users -- the engine
-- calls it for every candidate it is about to notify, from a trigger fired by
-- somebody else entirely. Under invoker rights the profile row would simply not
-- be visible and the function would return false, i.e. "no quiet hours", which
-- is the failure direction that wakes people up at 3am.
--
-- The wrap-around branch is the whole reason this is a function rather than an
-- inline predicate. A quiet window is overwhelmingly likely to cross midnight
-- (23:00-08:00 is the obvious default), and for those `local between start and
-- end` is not merely wrong, it is inverted -- it matches exactly the nine hours
-- the user wanted silence and none of the fifteen they did not.
--
-- A missing profile row returns false rather than true: no row means no stated
-- preference, and the engine's other gates (push_consent, notify_nearby, both
-- NOT NULL DEFAULT on a table where every account has a row) are what actually
-- decide whether anything is sent. Failing to "quiet hours" here would silently
-- defer every notification for a user whose profile is mid-creation.
-- ============================================================
create or replace function public.in_quiet_hours(p_user_id uuid, p_at timestamptz)
returns boolean
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  v_start time;
  v_end   time;
  v_tz    text;
  v_local time;
begin
  select p.quiet_hours_start, p.quiet_hours_end, p.notification_tz
    into v_start, v_end, v_tz
  from public.profiles p
  where p.id = p_user_id;

  if v_start is null or v_end is null then
    return false;
  end if;

  -- timestamptz at time zone <zone> yields the local wall clock as a plain
  -- timestamp, which is the only frame in which a `time` bound means anything.
  v_local := (p_at at time zone v_tz)::time;

  if v_start < v_end then
    -- Same-day window, e.g. 13:00-15:00.
    return v_local >= v_start and v_local < v_end;
  else
    -- Wraps midnight, e.g. 23:00-08:00.
    return v_local >= v_start or v_local < v_end;
  end if;
end;
$$;

revoke execute on function public.in_quiet_hours(uuid, timestamptz)
  from public, anon, authenticated;

comment on function public.in_quiet_hours(uuid, timestamptz) is
  'True if the instant falls inside the user''s local quiet window. Handles windows that cross midnight.';


-- ============================================================
-- quiet_hours_end_at -- when the deferred job becomes deliverable.
--
-- docs/backend-plan.md 7.1 does not say what to do during quiet hours, and the
-- three options are not equivalent. Dropping the notification loses it. Writing
-- no dedupe row and letting the hourly sweep re-find it works, but promotes the
-- safety net to the primary delivery path for every overnight party, which 7.1
-- explicitly forbids. So: claim the dedupe row immediately and schedule the JOB
-- for the end of the window. The engine's decision is made once, at the moment
-- the event happened; only delivery moves.
--
-- Returns p_at unchanged when the user is not in quiet hours, so the caller can
-- use it unconditionally without first asking in_quiet_hours -- though the
-- engine does ask, because the CASE reads more honestly at the call site than a
-- function that silently means two things.
--
-- The asymmetry with the daily cap is deliberate and documented in part 3: a
-- capped user gets NO dedupe row, because the cap is a "not today" and the slot
-- must survive for tomorrow. A quiet-hours user gets one, because the job is
-- already scheduled and a second claim would be a duplicate.
-- ============================================================
create or replace function public.quiet_hours_end_at(p_user_id uuid, p_at timestamptz)
returns timestamptz
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  v_start      time;
  v_end        time;
  v_tz         text;
  v_local      timestamp;
  v_local_time time;
  v_target     timestamp;
begin
  select p.quiet_hours_start, p.quiet_hours_end, p.notification_tz
    into v_start, v_end, v_tz
  from public.profiles p
  where p.id = p_user_id;

  if v_start is null or v_end is null then
    return p_at;
  end if;

  v_local      := p_at at time zone v_tz;
  v_local_time := v_local::time;

  if v_start < v_end then
    if not (v_local_time >= v_start and v_local_time < v_end) then
      return p_at;
    end if;
    v_target := date_trunc('day', v_local) + v_end;
  else
    if not (v_local_time >= v_start or v_local_time < v_end) then
      return p_at;
    end if;

    if v_local_time >= v_start then
      -- Evening side of a midnight-crossing window: the window closes tomorrow.
      v_target := date_trunc('day', v_local) + interval '1 day' + v_end;
    else
      -- Small hours: still the same local day the window closes on.
      v_target := date_trunc('day', v_local) + v_end;
    end if;
  end if;

  -- timestamp at time zone <zone> is the inverse of the conversion above: it
  -- reads the plain timestamp AS local wall clock and returns the instant.
  return v_target at time zone v_tz;
end;
$$;

revoke execute on function public.quiet_hours_end_at(uuid, timestamptz)
  from public, anon, authenticated;

comment on function public.quiet_hours_end_at(uuid, timestamptz) is
  'The instant the user''s current quiet window closes, or p_at if they are not in one. Used as notification_jobs.scheduled_for.';
