-- get_my_parties carries the MapPinSheet payload, so a MY PARTIES row opens the
-- same sheet as a map pin or a search hit.
--
-- MapPinSheet is already the ONE party sheet -- the map and search both build
-- a MapPartyPin from their row and hand it over, and 20_party_search asserts
-- both payloads carry every column the sheet renders. MY PARTIES is the third
-- caller, so its payload joins that parity rather than the sheet growing a
-- second constructor: lat/lon, area, description, cover_path, host_id and
-- host_username are added, and the parity assertion now names all three
-- functions.
--
-- COUNTERS ARE NOW NULL ON A PRIVATE ROW, like every other surface the sheet
-- is fed from (20260825090051). 20261008151908 passed them through, matching
-- the table selects it replaced; that was tolerable while MY PARTIES rendered
-- no count on a private row, but MapPinSheet decides whether to show the
-- counts row from the NULL itself (MapPartyPin.hasCounts) -- so a private row
-- carrying numbers would print attendance on a private party. Null at the
-- source, as everywhere else, rather than a client convention to blank it.
--
-- The return type changes, so this is a drop and create, not a replace; the
-- grants are restated for the same reason.

drop function public.get_my_parties();

create function public.get_my_parties()
returns table (
  party_id uuid,
  title text,
  description text,
  starts_at timestamp with time zone,
  ends_at timestamp with time zone,
  area text,
  cover_path text,
  is_private boolean,
  host_id uuid,
  host_username text,
  lat double precision,
  lon double precision,
  going_count integer,
  interested_count integer,
  my_rsvp_status public.rsvp_status,
  is_host boolean,
  is_invited boolean
)
language sql
set search_path to 'public', 'extensions'
as $$
  with mine as (
    select r.party_id, r.status, false as is_host, false as is_invited
      from public.rsvps r
     where r.user_id = (select auth.uid())
    union all
    select p.id, null, true, false
      from public.parties p
     where p.host_id = (select auth.uid())
    union all
    select i.party_id, null, false, true
      from public.invitations i
     where i.guest_id = (select auth.uid())
  )
  select
    p.id as party_id,
    p.title,
    p.description,
    p.starts_at,
    p.ends_at,
    p.area,
    p.cover_path,
    p.is_private,
    p.host_id,
    pr.username as host_username,
    st_y(p.location::geometry) as lat,
    st_x(p.location::geometry) as lon,
    -- NULL for a private party, at the source -- see the header.
    case when p.is_private then null else p.going_count end as going_count,
    case when p.is_private then null else p.interested_count end as interested_count,
    -- At most one rsvps row per (party, user) -- it is the primary key.
    (array_agg(m.status) filter (where m.status is not null))[1] as my_rsvp_status,
    bool_or(m.is_host) as is_host,
    bool_or(m.is_invited) as is_invited
  from mine m
  join public.parties p on p.id = m.party_id
  -- Inner, like the map and search: a tombstoned host still has a profiles
  -- row (CLAUDE.md, Phase 9), so this drops nothing.
  join public.profiles pr on pr.id = p.host_id
  -- NOT OVER. The shared predicate, identical to get_parties_near_user,
  -- get_parties_list and get_party (20261008150440, gotcha 21).
  where p.status = 'published'
    and (p.ends_at is null or p.ends_at > now())
    and (
      p.ends_at is not null
      or p.starts_at > (select now() - public.party_end_grace())
    )
  group by p.id, pr.username
  order by p.starts_at, p.id
  limit 200;
$$;

comment on function public.get_my_parties() is
  'MY PARTIES: parties the caller RSVP''d to, hosts, or is invited to, one row '
  'per party with the flags merged, finished parties excluded by the same '
  'predicate as the map and ALL PARTIES. Carries the MapPinSheet payload; '
  'counters NULL on private rows. SECURITY INVOKER.';

revoke execute on function public.get_my_parties() from public;
grant execute on function public.get_my_parties() to authenticated;
