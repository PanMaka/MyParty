-- Phase 37: get_parties_list and get_party return lat/lon, so the party
-- detail sheet's Directions button has somewhere to send the viewer.
--
-- Bodies are otherwise unchanged from 20261008150440. The two columns are
-- APPENDED to the row type, so nothing reading the existing columns moves.
--
-- WHY THIS EXPOSES NOTHING NEW. Both functions are SECURITY INVOKER, so a row
-- reaches the caller only through the parties SELECT policy -- the same
-- authority under which `search_parties` has returned lat/lon since
-- 20260822150239, and under which `parties.location` itself is readable (the
-- table-level SELECT grant covers it). A private party's position therefore
-- goes to its host and invitees and nobody else, exactly as on the map and in
-- search.
--
-- `map_visibility` deliberately does NOT gate these coordinates, for the
-- reason recorded in 20260822113256 (Phase 14): it answers "do I want to be a
-- pin on the map", not "do I want my party unlocatable". A party you may see
-- but cannot find is the invited-somewhere-you-cannot-locate failure that
-- decision exists to prevent. If "hide my party's position" is ever wanted it
-- gets its own column; do not overload map_visibility.
--
-- Read from `location`, the only place a party's real position lives (see
-- 20260820095801 on why there is no `address` column). No rounding: it is
-- the host's own venue pin, published to the guests so they can get there,
-- which is the opposite of user_devices.last_location's retention clock.
--
-- WHY DROP AND NOT `create or replace`: adding OUT columns changes the return
-- type, which Postgres refuses to replace in place. DROP takes the ACL and the
-- comment with it, so both are restated below (gotcha 13 / 23) and
-- 27_explicit_grants asserts the result.

drop function public.get_parties_list(public.party_sort, integer, integer, bigint, timestamp with time zone, uuid);
drop function public.get_party(uuid);


-- ===========================================================================
-- 1. get_parties_list
-- ===========================================================================
create function public.get_parties_list(
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
  sort_rank bigint,
  lat double precision,
  lon double precision
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
    -- NOT OVER. The shared predicate, identical to the map's (gotcha 21).
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
    r.sort_rank,
    st_y(r.location::geometry) as lat,
    st_x(r.location::geometry) as lon
  from (
    select r.*, p.going_count, p.interested_count, p.location
    from ranked r join public.parties p on p.id = r.id
  ) r
  where
    p_cursor_id is null
    or (r.sort_group, r.sort_rank, r.starts_at, r.id)
       > (p_cursor_group, p_cursor_rank, p_cursor_starts_at, p_cursor_id)
  order by r.sort_group, r.sort_rank, r.starts_at, r.id
  limit greatest(least(p_limit, 100), 1);
$$;

comment on function public.get_parties_list(public.party_sort, integer, integer, bigint, timestamp with time zone, uuid) is
  'The ALL PARTIES browse list. SECURITY INVOKER, so the parties SELECT policy '
  'is the only visibility authority. Private parties are a GROUP pinned above '
  'the interested ranking and ordered by starts_at within it -- ordering them '
  'by interested_count would bracket the value 20260825090051 returns NULL to '
  'hide. Keyset over (sort_group, sort_rank, starts_at, party_id), all '
  'ascending, with descending keys negated; the cursor columns are returned so '
  'the client echoes them back. lat/lon are the party location, for '
  'directions; map_visibility does not gate them (20261013153808).';

revoke execute on function public.get_parties_list(public.party_sort, integer, integer, bigint, timestamp with time zone, uuid) from public;
grant execute on function public.get_parties_list(public.party_sort, integer, integer, bigint, timestamp with time zone, uuid) to authenticated;


-- ===========================================================================
-- 2. get_party -- the same row shape as the list, as before.
-- ===========================================================================
create function public.get_party(p_party_id uuid)
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
  sort_rank bigint,
  lat double precision,
  lon double precision
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
    0::bigint as sort_rank,
    st_y(p.location::geometry) as lat,
    st_x(p.location::geometry) as lon
  from public.parties p
  join public.profiles pr on pr.id = p.host_id
  where p.id = p_party_id
    -- NOT OVER. The shared predicate (gotcha 21).
    and p.status = 'published'
    and (p.ends_at is null or p.ends_at > now())
    and (
      p.ends_at is not null
      or p.starts_at > (select now() - public.party_end_grace())
    );
$$;

comment on function public.get_party(uuid) is
  'One party by id, for a party link. SECURITY INVOKER: the parties SELECT '
  'policy decides, and a party the caller may not see returns zero rows, '
  'indistinguishable from one that does not exist. Same row shape as '
  'get_parties_list, counters NULL on private rows.';

-- Gotcha 4: the bodies mention rsvps and invitations, which anon holds no
-- SELECT on, so anon is refused at EXECUTE rather than left to error inside.
revoke execute on function public.get_party(uuid) from public;
grant execute on function public.get_party(uuid) to authenticated;
