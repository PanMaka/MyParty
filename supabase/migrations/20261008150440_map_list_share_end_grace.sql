-- One rule for "this party is over", on the map, the ALL PARTIES list and a
-- party link alike. Closes gotcha 21 on the map.
--
-- THE SYMPTOM. ALL PARTIES showed nothing while the map was full of pins. Both
-- were doing what they said: the map's base filter was
-- `ends_at is null or ends_at > now()`, so a party with no stated end stayed
-- pinned FOREVER (gotcha 21), while get_parties_list additionally required
-- `starts_at > now() - party_end_grace()` and dropped it six hours in. On a
-- database seeded weeks ago -- where every seed party is a null-ends_at party
-- that started weeks ago -- the map was all zombies and the list was correctly
-- empty. The list was never the broken one.
--
-- THE DECISION (2026-10-08). The map adopts the grace period on its DEFAULT
-- view, not only inside the Τώρα chip. Phase 15 left this open because on the
-- base filter "being wrong removes a live party" -- an all-nighter with no
-- stated end drops off the map six hours in. That cost is now accepted: a host
-- who wants a longer party on the map says when it ends, and the honest path
-- (an explicit ends_at) is untouched by the grace. The alternative was a map
-- that slowly fills with parties that are over, silently and cumulatively.
--
-- THE SHARED PREDICATE, now spelled identically in all three RPCs:
--
--     p.status = 'published'
--     and (p.ends_at is null or p.ends_at > now())
--     and (p.ends_at is not null
--          or p.starts_at > (select now() - public.party_end_grace()))
--
-- which is exactly `not party_is_past(starts_at, ends_at)` -- asserted row by
-- row in 21_map_time_windows -- spelled so every term stays leakproof and ahead
-- of the RLS barrier (gotcha 22). It cannot simply CALL party_is_past: that
-- puts the grace on the row side and carries a SET clause (gotchas 20, 22).
--
-- THE LIST AND get_party CHANGE TOO, in the other direction. They required
-- `starts_at > now() - grace` UNCONDITIONALLY, so a party with a stated end
-- still in the future -- a festival, an all-dayer -- vanished from the list six
-- hours after it started while the map kept it, which is the same "pin with no
-- card" complaint from the opposite side. The grace now applies only where
-- there is no stated end, on all three surfaces. Still leakproof: the new arm
-- is a NullTest, the same shape the Τώρα clause has used since 20260823091942.
--
-- The duplication across three bodies is forced, not chosen: a helper
-- function here would be a non-leakproof call behind the barrier (the ~200x of
-- gotcha 22). party_end_grace() keeps the NUMBER in one place, and
-- 21_map_time_windows asserts the three bodies agree with party_is_past.


-- ===========================================================================
-- 1. get_parties_near_user -- body otherwise unchanged from 20260825090051.
-- ===========================================================================
create or replace function public.get_parties_near_user(
  map_center_lon double precision,
  map_center_lat double precision,
  radius_meters double precision,
  p_limit integer default 200,
  p_window text default 'all',
  p_tz text default 'Europe/Athens'
)
returns table (
  party_id uuid,
  title text,
  description text,
  starts_at timestamp with time zone,
  ends_at timestamp with time zone,
  area text,
  cover_path text,
  is_private boolean,
  is_sponsored boolean,
  party_tier text,
  host_id uuid,
  host_username text,
  lat double precision,
  lon double precision,
  distance_meters double precision,
  going_count integer,
  interested_count integer,
  my_rsvp_status public.rsvp_status,
  is_invited boolean
)
language sql
set search_path to 'public', 'extensions'
as $$
  select
    p.id as party_id,
    p.title,
    p.description,
    p.starts_at,
    p.ends_at,
    p.area,
    p.cover_path,
    p.is_private,
    p.is_sponsored,
    p.party_tier,
    p.host_id,
    pr.username as host_username,

    -- From `location`, not bbox_lat/bbox_lon: those exist to narrow, not to
    -- answer.
    st_y(p.location::geometry) as lat,
    st_x(p.location::geometry) as lon,

    st_distance(p.location, st_point(map_center_lon, map_center_lat)::geography) as distance_meters,

    -- NULL for a private party, at the source (20260825090051).
    case when p.is_private then null else p.going_count end as going_count,
    case when p.is_private then null else p.interested_count end as interested_count,

    (
      select r.status from public.rsvps r
      where r.party_id = p.id and r.user_id = (select auth.uid())
    ) as my_rsvp_status,

    exists (
      select 1 from public.invitations i
      where i.party_id = p.id and i.guest_id = (select auth.uid())
    ) as is_invited

  from public.parties p
  join public.profiles pr on p.host_id = pr.id
  where

    -- THE SPATIAL PRE-FILTER (20260821201309): leakproof float8 comparisons
    -- against InitPlan constants, evaluated ahead of the row policy.
    p.bbox_lat >= (select st_ymin(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))
    and p.bbox_lat <= (select st_ymax(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))
    and p.bbox_lon >= (select st_xmin(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))
    and p.bbox_lon <= (select st_xmax(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))

    -- THE TIME PRE-FILTER (20260823091942). The bounds MUST stay scalar
    -- subqueries -- one evaluation, an InitPlan constant, not one per row.
    and p.starts_at >= (select lower(public.party_time_window(p_window, p_tz)))
    and p.starts_at <  (select upper(public.party_time_window(p_window, p_tz)))

    -- NOT OVER. The shared predicate -- see the header. Until this migration
    -- the grace arm applied only under Τώρα and the default map pinned a
    -- null-ends_at party forever (gotcha 21); it now applies on every window.
    --
    -- DO NOT rewrite the last term as coalesce(p.ends_at, p.starts_at + grace)
    -- > now(). Algebraically identical, ~20x slower measured: a Var under
    -- timestamptz_pl_interval is not leakproof and drags the term behind the
    -- RLS barrier. Same trap for party_is_past().
    and p.status = 'published'
    and (p.ends_at is null or p.ends_at > now())
    and (
      p.ends_at is not null
      or p.starts_at > (select now() - public.party_end_grace())
    )

    -- The box above is a SUPERSET of this circle; this is what decides.
    and st_dwithin(p.location, st_point(map_center_lon, map_center_lat)::geography, radius_meters)

    -- The host's map_visibility, plus the party-specific override.
    and (
      pr.map_visibility = 'public'
      or p.host_id = (select auth.uid())
      -- 'followers' = people who follow the HOST (gotcha 14).
      or (
        pr.map_visibility = 'followers'
        and exists (
          select 1 from public.follows f
          where f.follower_id = (select auth.uid())
            and f.followee_id = p.host_id
        )
      )
      or exists (
        select 1 from public.invitations i
        where i.party_id = p.id and i.guest_id = (select auth.uid())
      )
      or exists (
        select 1 from public.rsvps r
        where r.party_id = p.id and r.user_id = (select auth.uid())
      )
    )

    -- Zoom tier. Independent of the window: both narrow.
    and case
        when radius_meters <= 15000 then true
        when radius_meters <= 100000 then p.party_tier in ('large', 'mega')
        else p.party_tier = 'mega' or p.is_sponsored = true
    end
  order by p.is_sponsored desc, distance_meters asc
  limit greatest(least(p_limit, 500), 1);
$$;


-- ===========================================================================
-- 2. get_parties_list -- body otherwise unchanged from 20260826094842.
-- ===========================================================================
create or replace function public.get_parties_list(
  p_sort public.party_sort default 'soonest',
  p_limit integer default 30,
  p_cursor_group integer default null,
  p_cursor_rank bigint default null,
  p_cursor_starts_at timestamp with time zone default null,
  p_cursor_id uuid default null
)
returns table (
  party_id uuid,
  title text,
  description text,
  starts_at timestamp with time zone,
  ends_at timestamp with time zone,
  area text,
  cover_path text,
  is_private boolean,
  is_sponsored boolean,
  party_tier text,
  host_id uuid,
  host_username text,
  is_live boolean,
  going_count integer,
  interested_count integer,
  my_rsvp_status public.rsvp_status,
  is_invited boolean,
  sort_group integer,
  sort_rank bigint
)
language sql
set search_path to 'public', 'extensions'
as $$
  with ranked as (
    select
      p.id,
      p.title,
      p.description,
      p.starts_at,
      p.ends_at,
      p.area,
      p.cover_path,
      p.is_private,
      p.is_sponsored,
      p.party_tier,
      p.host_id,
      pr.username as host_username,
      (p.starts_at <= now()) as is_live,

      -- Live parties lead 'soonest', private parties lead 'interested'.
      case
        when p_sort = 'soonest' then (case when p.starts_at <= now() then 0 else 1 end)
        else (case when p.is_private then 0 else 1 end)
      end as sort_group,

      -- The counter is never consulted for a private row (20260826094842 Part 1).
      case
        when p_sort = 'interested' and not p.is_private
          then (-p.interested_count)::bigint
        else 0::bigint
      end as sort_rank

    from public.parties p
    join public.profiles pr on pr.id = p.host_id
    -- NOT OVER. The shared predicate, identical to the map's -- see the header.
    where p.status = 'published'
      and (p.ends_at is null or p.ends_at > now())
      and (
        p.ends_at is not null
        or p.starts_at > (select now() - public.party_end_grace())
      )
  )
  select
    r.id as party_id,
    r.title,
    r.description,
    r.starts_at,
    r.ends_at,
    r.area,
    r.cover_path,
    r.is_private,
    r.is_sponsored,
    r.party_tier,
    r.host_id,
    r.host_username,
    r.is_live,
    case when r.is_private then null else r.going_count end as going_count,
    case when r.is_private then null else r.interested_count end as interested_count,
    (
      select rs.status from public.rsvps rs
      where rs.party_id = r.id and rs.user_id = (select auth.uid())
    ) as my_rsvp_status,
    exists (
      select 1 from public.invitations i
      where i.party_id = r.id and i.guest_id = (select auth.uid())
    ) as is_invited,
    r.sort_group,
    r.sort_rank
  from (
    select r.*, p.going_count, p.interested_count
    from ranked r join public.parties p on p.id = r.id
  ) r
  where
    p_cursor_id is null
    or (r.sort_group, r.sort_rank, r.starts_at, r.id)
       > (p_cursor_group, p_cursor_rank, p_cursor_starts_at, p_cursor_id)
  order by r.sort_group, r.sort_rank, r.starts_at, r.id
  limit greatest(least(p_limit, 100), 1);
$$;


-- ===========================================================================
-- 3. get_party -- body otherwise unchanged from 20261006005447. It promises
--    the list's "has ended" rule, so it moves with the list: a pin you can tap
--    must not be a link that says "not available".
-- ===========================================================================
create or replace function public.get_party(p_party_id uuid)
returns table (
  party_id uuid,
  title text,
  description text,
  starts_at timestamp with time zone,
  ends_at timestamp with time zone,
  area text,
  cover_path text,
  is_private boolean,
  is_sponsored boolean,
  party_tier text,
  host_id uuid,
  host_username text,
  is_live boolean,
  going_count integer,
  interested_count integer,
  my_rsvp_status public.rsvp_status,
  is_invited boolean,
  sort_group integer,
  sort_rank bigint
)
language sql
set search_path to 'public', 'extensions'
as $$
  select
    p.id as party_id,
    p.title,
    p.description,
    p.starts_at,
    p.ends_at,
    p.area,
    p.cover_path,
    p.is_private,
    p.is_sponsored,
    p.party_tier,
    p.host_id,
    pr.username as host_username,
    (p.starts_at <= now()) as is_live,
    case when p.is_private then null else p.going_count end as going_count,
    case when p.is_private then null else p.interested_count end as interested_count,
    (
      select rs.status from public.rsvps rs
      where rs.party_id = p.id and rs.user_id = (select auth.uid())
    ) as my_rsvp_status,
    exists (
      select 1 from public.invitations i
      where i.party_id = p.id and i.guest_id = (select auth.uid())
    ) as is_invited,
    0 as sort_group,
    0::bigint as sort_rank
  from public.parties p
  join public.profiles pr on pr.id = p.host_id
  where p.id = p_party_id
    -- NOT OVER. The shared predicate -- see the header.
    and p.status = 'published'
    and (p.ends_at is null or p.ends_at > now())
    and (
      p.ends_at is not null
      or p.starts_at > (select now() - public.party_end_grace())
    );
$$;

-- `create or replace` keeps each function's existing ACL (20261004234903), so
-- no grants are restated here; 27_explicit_grants asserts they survived.
