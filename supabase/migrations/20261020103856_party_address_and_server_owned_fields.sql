-- Phase 42: a party's street address, geocoding, and the fields a host may not
-- set.
--
-- ===========================================================================
-- 0. The decision this reverses.
--
-- 20260820095801 declined an `address` column on parties, and the
-- `parties.area` comment declined deriving anything from `location`, both for
-- the same reason: turning an address into a point (or a point into a name)
-- means sending it to a geocoder, and a private party's location is the value
-- this schema is most careful with. docs/backlog.md 1.11 kept the consequence
-- open: a typed address never placed the pin, so a host who skipped the map
-- picker got a party pinned wherever their phone was.
--
-- Reversed on purpose, 2026-10-20 (backlog §3): the host wizard now geocodes
-- through MapTiler, from the HOST's device, about the HOST's own party. What
-- MapTiler receives is what the host types and where the host puts the pin.
-- Nothing here sends anything anywhere -- the database stores the result.
--
-- What did NOT change: `parties.location` is still the only place a party's
-- position lives, and it is still the pin's. The address is a label the host
-- can edit ("rooftop, 3rd floor"), never the source of the point.
-- ===========================================================================


-- ===========================================================================
-- 1. parties.address -- the readable address, apart from the description.
--
-- Until now the wizard folded the typed address into `description` with a
-- blank line, which is why the edit form could never split it back out. Rows
-- written that way stay as they are: there is no reliable way to tell an
-- address paragraph from a description paragraph after the fact.
--
-- One line, like `area`, and for the same reason: it is a fact row on the
-- sheet, not a paragraph. 200 rather than area's 80, because a real street
-- address plus "rooftop, 3rd floor" runs well past 80 in Greek.
--
-- Visibility is the row's. RLS is row-scoped, so the parties SELECT policy
-- already hides a private party's address from everyone it hides the party
-- from; the read RPCs below are invoker-rights (or host-guarded), so they add
-- no path around it. Asserted in 36_party_address.test.sql.
--
-- Not in party_search_tokens: search stays on title and area. A street
-- address is not what anyone types to find a party, and indexing it would
-- make "who is partying on my street" a query.
--
-- Erasure: kept with the party, exactly like `description` and `area` -- the
-- erasure engine does not touch hosted parties (docs/phase-09-fk-audit.md).
-- Export: carried, below.
-- ===========================================================================
alter table public.parties
  add column address text
    constraint parties_address_one_line check (
      address is null
      or (
        char_length(address) <= 200
        and btrim(address) <> ''
        and position(E'\n' in address) = 0
        and position(E'\r' in address) = 0
      )
    );

comment on column public.parties.address is
  'Readable address written or accepted by the host, max 200 chars, one line. A label: parties.location is the position. NULL means none given. Same visibility as the row. Values from geocoding: © MapTiler © OpenStreetMap contributors (MapTiler terms §6.5, attribution on stored search results).';

comment on column public.parties.area is
  'Neighbourhood label ("Κουκάκι"), max 80 chars, one line. NULL means none. Since 20261020103856 the host wizard may pre-fill it from MapTiler reverse geocoding of the pin, from the host''s device; the host can edit or clear it.';


-- ===========================================================================
-- 2. A party's location has to be a real point.
--
-- `location` was already NOT NULL, but nothing checked the numbers, and
-- create_party_with_invites took whatever lat/lon arrived. A CHECK rather than
-- only an RPC test, because the client also holds a (column-scoped, section 3)
-- INSERT on parties and could skip the RPC.
--
-- (0, 0) is refused too. "Null Island" is what a missing coordinate becomes
-- when something defaults a double to zero, which is exactly the silent
-- default this phase exists to remove, and no party is in the Gulf of Guinea.
-- NaN fails the range terms on its own: NaN sorts above every number.
-- ===========================================================================
alter table public.parties
  add constraint parties_location_valid check (
    public.st_y(location::public.geometry) between -90 and 90
    and public.st_x(location::public.geometry) between -180 and 180
    and not (
      public.st_x(location::public.geometry) = 0
      and public.st_y(location::public.geometry) = 0
    )
  );


-- ===========================================================================
-- 3. The fields a host may not set: a column-scoped INSERT.
--
-- `authenticated` held INSERT on the whole table, so the client could write
-- is_sponsored, party_tier and status -- through create_party_with_invites,
-- which copied them out of its jsonb, and directly through PostgREST, which
-- the RPC fixed alone would leave open. The same grant also let it insert
-- going_count / interested_count (the counters the trigger owns), cover_path
-- (the key confirm_party_cover is supposed to be the only writer of) and the
-- bbox columns. So: the RPC's allow-list below AND this grant, which is what
-- makes the allow-list the whole surface (gotcha 8: a row policy cannot say
-- "not this column").
--
-- Everything not named takes its column default: is_sponsored false,
-- party_tier 'standard', status 'published', counters 0. Same list update_party
-- allows, plus host_id (pinned to the caller by the INSERT policy),
-- is_private (fixed at creation), id and max_capacity.
--
-- Revoking at table level drops nothing else here: parties has no other
-- column grants (gotcha 23's note).
-- ===========================================================================
revoke insert on public.parties from authenticated;

grant insert (
  id, host_id, title, description, area, address, location,
  starts_at, ends_at, is_private, max_capacity
) on public.parties to authenticated;


-- ===========================================================================
-- 4. create_party_with_invites -- an allow-list, a real location, the address.
--
-- Every key of p_party must be one a host may set; anything else is refused
-- with 42501 rather than ignored. Ignoring would leave a caller believing it
-- had made a sponsored party, and would let the next edit that "just adds a
-- column to the insert" silently re-open the hole. Refusing makes the list
-- the contract.
--
-- lat/lon are checked here as well as by the CHECK, so the client gets one
-- legible error (the one update_party already raises) instead of a constraint
-- name. There is no fallback position: the wizard sends the pin or nothing.
--
-- Same signature, so `create or replace` keeps its ACL and callers.
-- ===========================================================================
create or replace function public.create_party_with_invites(
  p_party jsonb,
  p_invitee_ids uuid[] default '{}'
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_party_id uuid := gen_random_uuid();
  v_key text;
  v_lat double precision;
  v_lon double precision;
begin
  for v_key in select jsonb_object_keys(coalesce(p_party, '{}'::jsonb)) loop
    if v_key not in (
      'title', 'description', 'area', 'address', 'lat', 'lon',
      'starts_at', 'ends_at', 'is_private', 'max_capacity'
    ) then
      raise exception 'party field % cannot be set by the host', v_key
        using errcode = '42501';
    end if;
  end loop;

  v_lat := nullif(p_party->>'lat', '')::double precision;
  v_lon := nullif(p_party->>'lon', '')::double precision;
  if v_lat is null or v_lon is null
     or v_lat not between -90 and 90 or v_lon not between -180 and 180
     or (v_lat = 0 and v_lon = 0) then
    raise exception 'a party needs a valid location' using errcode = '22023';
  end if;

  insert into public.parties (
    id, host_id, title, description, area, address, location,
    starts_at, ends_at, is_private, max_capacity
  ) values (
    v_party_id,
    (select auth.uid()),
    p_party->>'title',
    nullif(btrim(coalesce(p_party->>'description', '')), ''),
    -- '' becomes NULL: both one-line CHECKs refuse the empty string on purpose.
    nullif(btrim(coalesce(p_party->>'area', '')), ''),
    nullif(btrim(coalesce(p_party->>'address', '')), ''),
    public.st_point(v_lon, v_lat)::public.geography,
    (p_party->>'starts_at')::timestamptz,
    nullif(p_party->>'ends_at', '')::timestamptz,
    coalesce((p_party->>'is_private')::boolean, false),
    nullif(p_party->>'max_capacity', '')::int
  );

  if array_length(p_invitee_ids, 1) is not null then
    insert into public.invitations (party_id, guest_id)
    select v_party_id, invitee_id
    from unnest(p_invitee_ids) as invitee_id
    where not public.is_blocked((select auth.uid()), invitee_id)
      and public.accepts_invite_from(invitee_id, (select auth.uid()))
    on conflict (party_id, guest_id) do nothing;
  end if;

  return v_party_id;
end;
$$;

comment on function public.create_party_with_invites(jsonb, uuid[]) is
  'Creates a party as the caller and invites p_invitee_ids (blocked and refusing guests skipped). '
  'p_party keys: title, description, area, address, lat, lon, starts_at, ends_at, is_private, max_capacity -- '
  'any other key is refused (42501); sponsorship, tier and status are server defaults. lat/lon required and valid (22023).';


-- ===========================================================================
-- 5. update_party -- gains p_address.
--
-- A new parameter is a new signature, so drop and recreate, and re-grant
-- (27_explicit_grants carries the new identity). No default on p_address:
-- this is a full replacement where NULL means NULL, so a default would let an
-- old client that does not send it wipe the address on every save. Without
-- one, an old client's save fails loudly instead.
-- ===========================================================================
drop function public.update_party(uuid, text, text, text, timestamptz, timestamptz, double precision, double precision);

create function public.update_party(
  p_party_id uuid,
  p_title text,
  p_description text,
  p_area text,
  p_address text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_lat double precision,
  p_lon double precision
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_party_host(p_party_id) or not exists (
    select 1 from public.parties p
    where p.id = p_party_id and p.status = 'published'
  ) then
    raise exception 'cannot edit party %', p_party_id using errcode = '42501';
  end if;

  if nullif(btrim(coalesce(p_title, '')), '') is null then
    raise exception 'a party needs a title' using errcode = '22023';
  end if;
  if p_starts_at is null then
    raise exception 'a party needs a start time' using errcode = '22023';
  end if;
  if p_ends_at is not null and p_ends_at <= p_starts_at then
    raise exception 'a party has to end after it starts' using errcode = '22023';
  end if;
  if p_lat is null or p_lon is null
     or p_lat not between -90 and 90 or p_lon not between -180 and 180
     or (p_lat = 0 and p_lon = 0) then
    raise exception 'a party needs a valid location' using errcode = '22023';
  end if;

  -- The one-line CHECKs on area and address still apply; '' becomes NULL
  -- here because both reject the empty string on purpose.
  update public.parties
  set title = btrim(p_title),
      description = nullif(btrim(coalesce(p_description, '')), ''),
      area = nullif(btrim(coalesce(p_area, '')), ''),
      address = nullif(btrim(coalesce(p_address, '')), ''),
      starts_at = p_starts_at,
      ends_at = p_ends_at,
      location = public.st_point(p_lon, p_lat)::public.geography
  where id = p_party_id;
end;
$$;

comment on function public.update_party(uuid, text, text, text, text, timestamptz, timestamptz, double precision, double precision) is
  'The only way to edit a party: host-only, published only, and only title, '
  'description, area, address, times and location. Full replacement -- NULL means NULL.';

revoke execute on function public.update_party(uuid, text, text, text, text, timestamptz, timestamptz, double precision, double precision) from public;
grant execute on function public.update_party(uuid, text, text, text, text, timestamptz, timestamptz, double precision, double precision) to authenticated;


-- ===========================================================================
-- 6. The read RPCs carry `address`.
--
-- Every surface that renders a party sheet, plus the host's dashboard. Each
-- is recreated from its current definition with ONE change, `address` after
-- `area` in the result and the select list, because adding an OUT column
-- needs a drop. Grants and comments are re-issued exactly as they were.
--
-- No new path to the column: get_party, get_parties_list,
-- get_parties_near_user, search_parties and get_my_parties are SECURITY
-- INVOKER, so the parties policy decides which rows reach them;
-- get_party_host_stats is definer and raises 42501 for anyone but the host.
-- ===========================================================================

-- --- get_party ---
drop function public.get_party(uuid);

CREATE OR REPLACE FUNCTION public.get_party(p_party_id uuid)
 RETURNS TABLE(party_id uuid, title text, description text, starts_at timestamp with time zone, ends_at timestamp with time zone, area text, address text, cover_path text, is_private boolean, is_sponsored boolean, party_tier text, host_id uuid, host_username text, is_live boolean, going_count integer, interested_count integer, my_rsvp_status rsvp_status, is_invited boolean, sort_group integer, sort_rank bigint, lat double precision, lon double precision)
 LANGUAGE sql
 SET search_path TO 'public', 'extensions'
AS $function$
  select
    p.id as party_id,
    p.title,
    p.description,
    p.starts_at,
    p.ends_at,
    p.area,
    p.address,
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
$function$

;

comment on function public.get_party(uuid) is 'One party by id, for a party link. SECURITY INVOKER: the parties SELECT policy decides, and a party the caller may not see returns zero rows, indistinguishable from one that does not exist. Same row shape as get_parties_list, counters NULL on private rows.';
revoke execute on function public.get_party(uuid) from public;
grant execute on function public.get_party(uuid) to authenticated;

-- --- get_parties_list ---
drop function public.get_parties_list(party_sort,integer,integer,bigint,timestamp with time zone,uuid);

CREATE OR REPLACE FUNCTION public.get_parties_list(p_sort party_sort DEFAULT 'soonest'::party_sort, p_limit integer DEFAULT 30, p_cursor_group integer DEFAULT NULL::integer, p_cursor_rank bigint DEFAULT NULL::bigint, p_cursor_starts_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_cursor_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(party_id uuid, title text, description text, starts_at timestamp with time zone, ends_at timestamp with time zone, area text, address text, cover_path text, is_private boolean, is_sponsored boolean, party_tier text, host_id uuid, host_username text, is_live boolean, going_count integer, interested_count integer, my_rsvp_status rsvp_status, is_invited boolean, sort_group integer, sort_rank bigint, lat double precision, lon double precision)
 LANGUAGE sql
 SET search_path TO 'public', 'extensions'
AS $function$
  with ranked as (
    select
      p.id,
      p.title,
      p.description,
      p.starts_at,
      p.ends_at,
      p.area,
      p.address,
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
    r.address,
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
$function$

;

comment on function public.get_parties_list(party_sort,integer,integer,bigint,timestamp with time zone,uuid) is 'The ALL PARTIES browse list. SECURITY INVOKER, so the parties SELECT policy is the only visibility authority. Private parties are a GROUP pinned above the interested ranking and ordered by starts_at within it -- ordering them by interested_count would bracket the value 20260825090051 returns NULL to hide. Keyset over (sort_group, sort_rank, starts_at, party_id), all ascending, with descending keys negated; the cursor columns are returned so the client echoes them back. lat/lon are the party location, for directions; map_visibility does not gate them (20261013153808).';
revoke execute on function public.get_parties_list(party_sort,integer,integer,bigint,timestamp with time zone,uuid) from public;
grant execute on function public.get_parties_list(party_sort,integer,integer,bigint,timestamp with time zone,uuid) to authenticated;

-- --- get_parties_near_user ---
drop function public.get_parties_near_user(double precision,double precision,double precision,integer,text,text);

CREATE OR REPLACE FUNCTION public.get_parties_near_user(map_center_lon double precision, map_center_lat double precision, radius_meters double precision, p_limit integer DEFAULT 200, p_window text DEFAULT 'all'::text, p_tz text DEFAULT 'Europe/Athens'::text)
 RETURNS TABLE(party_id uuid, title text, description text, starts_at timestamp with time zone, ends_at timestamp with time zone, area text, address text, cover_path text, is_private boolean, is_sponsored boolean, party_tier text, host_id uuid, host_username text, lat double precision, lon double precision, distance_meters double precision, going_count integer, interested_count integer, my_rsvp_status rsvp_status, is_invited boolean)
 LANGUAGE sql
 SET search_path TO 'public', 'extensions'
AS $function$
  select
    p.id as party_id,
    p.title,
    p.description,
    p.starts_at,
    p.ends_at,
    p.area,
    p.address,
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
$function$

;

comment on function public.get_parties_near_user(double precision,double precision,double precision,integer,text,text) is 'Map query. going_count/interested_count are NULL for private rows -- a private party displays no attendance on any surface, so the figure is not transmitted rather than merely not rendered. Unchanged otherwise: the leakproof bbox + time pre-filters still sort ahead of the row policy.';
revoke execute on function public.get_parties_near_user(double precision,double precision,double precision,integer,text,text) from public;
grant execute on function public.get_parties_near_user(double precision,double precision,double precision,integer,text,text) to authenticated, service_role;

-- --- search_parties ---
drop function public.search_parties(text,integer);

CREATE OR REPLACE FUNCTION public.search_parties(p_query text, p_limit integer DEFAULT 20)
 RETURNS TABLE(party_id uuid, title text, description text, area text, address text, starts_at timestamp with time zone, ends_at timestamp with time zone, is_private boolean, cover_path text, host_id uuid, host_username text, lat double precision, lon double precision, going_count integer, interested_count integer, my_rsvp_status rsvp_status, is_past boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
  with q as (
    select public.search_normalize(p_query) as key
  ),
  hits as (
    -- Driven from the TOKEN index, not from parties: this is the step that
    -- turns the whole table into a few rows before any policy runs. Both terms
    -- are leakproof, so they sort ahead of the token table's
    -- can_access_party() policy.
    --
    -- The range MUST stay `~>=~` / `~<~`. `like q.key || '%'` returns the same
    -- rows and never reaches the index (textlike is non-leakproof, so the
    -- planner may not promote it past the policy and the index qual is never
    -- formed). `>=` / `<` also return the same rows, are leakproof, are
    -- promoted -- and still cannot use this index, because text_ops and
    -- text_pattern_ops are different operator families. Asserted three ways in
    -- 20_party_search.test.sql.
    select distinct t.party_id
    from public.party_search_tokens t, q
    where q.key <> ''
      and t.token ~>=~ q.key
      and t.token ~<~ public.search_prefix_upper(q.key)
  )
  select
    p.id as party_id,
    p.title,
    -- Added here so the shared sheet has the same body text whichever screen
    -- opened it. Unfiltered and untruncated, exactly as the map RPC returns
    -- it: the sheet decides how much to show.
    p.description,
    p.area,
    p.address,
    p.starts_at,
    p.ends_at,
    p.is_private,
    p.cover_path,
    p.host_id,
    pr.username as host_username,
    -- Added by 20260822150239 so a search hit converts straight into a
    -- MapPartyPin and opens the SAME sheet the map opens. Read from
    -- `location`, exactly as the map RPC does -- NEVER from bbox_lat/bbox_lon,
    -- which are index support only and must not answer a question (Phase 13).
    st_y(p.location::geometry) as lat,
    st_x(p.location::geometry) as lon,
    -- NULL for a private party, at the source.
    --
    -- The client no longer displays either number for a private row on any
    -- surface, so transmitting them would leave attendance data sitting in a
    -- JSON payload that nothing reads -- one debug build, one `print(row)`, or
    -- one future widget away from being visible. A value that is not sent
    -- cannot leak; a client convention not to render it is one edit from
    -- lapsing, and the edit looks harmless.
    --
    -- Costs nothing in the plan: this is the TARGET list, evaluated on rows
    -- that already survived the WHERE clause. Gotcha 22 is about predicates,
    -- and no predicate changed here -- verified by the unchanged timings in
    -- scripts/explain_map_time_windows.sh.
    case when p.is_private then null else p.going_count end as going_count,
    case when p.is_private then null else p.interested_count end as interested_count,
    -- The viewer's own RSVP, not the party's. going_count/interested_count are
    -- properties of the party; this is a property of who is asking, which is
    -- why it is a correlated subquery and not a join -- a join would multiply
    -- rows for a party with many RSVPs.
    (
      select r.status from public.rsvps r
      where r.party_id = p.id and r.user_id = (select auth.uid())
    ) as my_rsvp_status,
    public.party_is_past(p.starts_at, p.ends_at) as is_past
  from hits h
  join public.parties p on p.id = h.party_id
  join public.profiles pr on pr.id = p.host_id
  where p.status = 'published'
  -- Upcoming first, soonest first; then past, most recent first. "Find that
  -- party from May" is a real use, which is why past rows are returned at all.
  order by
    public.party_is_past(p.starts_at, p.ends_at) asc,
    case when public.party_is_past(p.starts_at, p.ends_at) then null else p.starts_at end asc nulls last,
    case when public.party_is_past(p.starts_at, p.ends_at) then p.starts_at else null end desc nulls last
  limit greatest(least(p_limit, 50), 1);
$function$

;

comment on function public.search_parties(text,integer) is 'Prefix search over party titles and areas, unbounded by location. SECURITY INVOKER so the parties and party_search_tokens policies both apply. map_visibility deliberately does NOT filter this -- it answers "do I want to be a pin", not "do I want to be unfindable". Past parties are returned in a second group, using party_is_past(); the map does not filter on that yet and the two therefore disagree about a null-ends_at party, which is expected. Carries description and my_rsvp_status so a hit opens the same fully-populated MapPinSheet a map pin does. going_count and interested_count are NULL for private rows, matching get_parties_near_user. The range MUST stay ~>=~ / ~<~.';
revoke execute on function public.search_parties(text,integer) from public;
grant execute on function public.search_parties(text,integer) to authenticated;

-- --- get_my_parties ---
drop function public.get_my_parties();

CREATE OR REPLACE FUNCTION public.get_my_parties()
 RETURNS TABLE(party_id uuid, title text, description text, starts_at timestamp with time zone, ends_at timestamp with time zone, area text, address text, cover_path text, is_private boolean, host_id uuid, host_username text, lat double precision, lon double precision, going_count integer, interested_count integer, my_rsvp_status rsvp_status, is_host boolean, is_invited boolean)
 LANGUAGE sql
 SET search_path TO 'public', 'extensions'
AS $function$
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
    p.address,
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
$function$

;

comment on function public.get_my_parties() is 'MY PARTIES: parties the caller RSVP''d to, hosts, or is invited to, one row per party with the flags merged, finished parties excluded by the same predicate as the map and ALL PARTIES. Carries the MapPinSheet payload; counters NULL on private rows. SECURITY INVOKER.';
revoke execute on function public.get_my_parties() from public;
grant execute on function public.get_my_parties() to authenticated;

-- --- get_party_host_stats ---
drop function public.get_party_host_stats(uuid);

CREATE OR REPLACE FUNCTION public.get_party_host_stats(p_party_id uuid)
 RETURNS TABLE(party_id uuid, title text, description text, area text, address text, starts_at timestamp with time zone, ends_at timestamp with time zone, cover_path text, is_private boolean, status party_status, lat double precision, lon double precision, is_live boolean, is_over boolean, going_count integer, interested_count integer, going_followers integer, going_non_followers integer, interested_followers integer, interested_non_followers integer, going_male integer, going_female integer, going_non_binary integer, going_unspecified integer, interested_male integer, interested_female integer, interested_non_binary integer, interested_unspecified integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  -- The smallest group whose gender mix is shown. Below it, NULLs.
  c_min_group constant integer := 3;
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
    p.address,
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
    coalesce(s.interested_non_followers, 0)::int,
    case when s.going_total >= c_min_group then s.going_male::int end,
    case when s.going_total >= c_min_group then s.going_female::int end,
    case when s.going_total >= c_min_group then s.going_non_binary::int end,
    case when s.going_total >= c_min_group then s.going_unspecified::int end,
    case when s.interested_total >= c_min_group then s.interested_male::int end,
    case when s.interested_total >= c_min_group then s.interested_female::int end,
    case when s.interested_total >= c_min_group then s.interested_non_binary::int end,
    case when s.interested_total >= c_min_group then s.interested_unspecified::int end
  from public.parties p
  left join lateral (
    select
      count(*) filter (where r.status = 'going' and f.follower_id is not null) as going_followers,
      count(*) filter (where r.status = 'going' and f.follower_id is null) as going_non_followers,
      -- interested is the superset (20260826093437): every rsvp, going included.
      count(*) filter (where f.follower_id is not null) as interested_followers,
      count(*) filter (where f.follower_id is null) as interested_non_followers,

      -- The threshold is measured on the same rows the four counts split, so
      -- the four always sum to a total that passed it.
      count(*) filter (where r.status = 'going') as going_total,
      count(*) filter (where r.status = 'going' and g.gender = 'male') as going_male,
      count(*) filter (where r.status = 'going' and g.gender = 'female') as going_female,
      count(*) filter (where r.status = 'going' and g.gender = 'non_binary') as going_non_binary,
      count(*) filter (where r.status = 'going' and g.gender is null) as going_unspecified,
      count(*) as interested_total,
      count(*) filter (where g.gender = 'male') as interested_male,
      count(*) filter (where g.gender = 'female') as interested_female,
      count(*) filter (where g.gender = 'non_binary') as interested_non_binary,
      count(*) filter (where g.gender is null) as interested_unspecified
    from public.rsvps r
    left join public.follows f
      on f.follower_id = r.user_id
     and f.followee_id = p.host_id
    left join public.user_genders g
      on g.user_id = r.user_id
    where r.party_id = p.id
  ) s on true
  where p.id = p_party_id;
end;
$function$

;

comment on function public.get_party_host_stats(uuid) is 'Host dashboard header and aggregates for one party. Host-only (42501 for anyone else). Returns private-party counters, unlike every attendee RPC. Followers = people who follow the host. Gender mix per group as counts only, NULL for a group under 3 rsvps. No per-user data.';
revoke execute on function public.get_party_host_stats(uuid) from public;
grant execute on function public.get_party_host_stats(uuid) to authenticated;


-- ===========================================================================
-- 7. export_account_data -- each hosted party's address.
--
-- Recreated from its current definition with one line added. Returns jsonb,
-- so `create or replace` keeps its signature and ACL.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.export_account_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := (select auth.uid());
  v_out jsonb;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select jsonb_build_object(
    -- A header, so a file that outlives the conversation about it still says
    -- what it is and when it was true.
    'export_format_version', 1,
    'exported_at', now(),
    'user_id', v_uid,

    'profile', (
      -- Column list spelled out rather than to_jsonb(pr): credibility_score
      -- must not appear. Phase 8 decided it ships no score, and a zero in an
      -- export file is a number a person will ask about.
      select to_jsonb(p)
      from (
        select
          pr.id, pr.username, pr.created_at,
          pr.bio, pr.avatar_path,
          pr.onboarding_completed_at,
          pr.location_consent, pr.push_consent, pr.analytics_consent,
          pr.map_visibility, pr.invite_policy, pr.dm_policy,
          pr.notify_nearby, pr.notify_radius_meters,
          pr.quiet_hours_start, pr.quiet_hours_end,
          pr.follower_count, pr.following_count,
          pr.deleted_at
        from public.profiles pr
        where pr.id = v_uid
      ) p
    ),

    -- Hosted parties. location is emitted as lon/lat rather than the PostGIS
    -- binary, because an export the subject cannot read is not an export.
    'parties', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pa.id,
        'title', pa.title,
        'description', pa.description,
        'area', pa.area,
        'address', pa.address,
        'cover_path', pa.cover_path,
        'longitude', public.st_x(pa.location::public.geometry),
        'latitude', public.st_y(pa.location::public.geometry),
        'starts_at', pa.starts_at,
        'ends_at', pa.ends_at,
        'status', pa.status,
        'is_private', pa.is_private,
        'party_tier', pa.party_tier,
        'max_capacity', pa.max_capacity,
        'going_count', pa.going_count,
        'interested_count', pa.interested_count,
        'created_at', pa.created_at
      ) order by pa.created_at)
      from public.parties pa
      where pa.host_id = v_uid
    ), '[]'::jsonb),

    'rsvps', coalesce((
      select jsonb_agg(jsonb_build_object(
        'party_id', r.party_id,
        'party_title', pa.title,
        'status', r.status,
        'created_at', r.created_at
      ) order by r.created_at)
      from public.rsvps r
      join public.parties pa on pa.id = r.party_id
      where r.user_id = v_uid
    ), '[]'::jsonb),

    -- Parties whose host removed the subject from the guest list: data held
    -- about them, and nothing they do not already know -- the party
    -- disappeared for them. Party ids and dates only, no title: a private
    -- party they can no longer see should not have its name re-delivered here.
    'party_removals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'party_id', g.party_id,
        'removed_at', g.removed_at
      ) order by g.removed_at)
      from public.party_guest_removals g
      where g.user_id = v_uid
    ), '[]'::jsonb),

    'posts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pp.id,
        'party_id', pp.party_id,
        'body', pp.body,
        'media_path', pp.media_path,
        'like_count', pp.like_count,
        'comment_count', pp.comment_count,
        'created_at', pp.created_at,
        -- If a moderator hid it, the subject is entitled to know that it
        -- happened and why. Who did it is not theirs.
        'hidden_at', pp.hidden_at,
        'hidden_reason', pp.hidden_reason
      ) order by pp.created_at)
      from public.party_posts pp
      where pp.author_id = v_uid
    ), '[]'::jsonb),

    -- Not in the Phase 9 brief's list of five, added deliberately: a comment
    -- is text the user wrote, and an export that returns their posts but not
    -- their comments is an incomplete Art. 20 response.
    'comments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pc.id,
        'post_id', pc.post_id,
        'body', pc.body,
        'created_at', pc.created_at,
        'hidden_at', pc.hidden_at,
        'hidden_reason', pc.hidden_reason
      ) order by pc.created_at)
      from public.post_comments pc
      where pc.author_id = v_uid
    ), '[]'::jsonb),

    'messages', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id,
        'party_id', m.party_id,
        'party_title', pa.title,
        'body', m.body,
        'created_at', m.created_at,
        'hidden_at', m.hidden_at,
        'hidden_reason', m.hidden_reason
      ) order by m.created_at)
      from public.messages m
      join public.parties pa on pa.id = m.party_id
      where m.author_id = v_uid
    ), '[]'::jsonb),

    -- thread_id and the other member's id, as ids only -- the same reasoning
    -- as the follows block: who someone talks to is also a fact about the
    -- person on the other end.
    'direct_messages', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', dm.id,
        'thread_id', dm.thread_id,
        'recipient_id', case when t.user_low = v_uid then t.user_high else t.user_low end,
        'body', dm.body,
        'created_at', dm.created_at,
        'hidden_at', dm.hidden_at,
        'hidden_reason', dm.hidden_reason
      ) order by dm.created_at)
      from public.direct_messages dm
      join public.direct_threads t on t.id = dm.thread_id
      where dm.author_id = v_uid
    ), '[]'::jsonb),

    -- Not content, but it is unambiguously data held about the subject, and
    -- it is the part a privacy-minded person is most likely to be asking
    -- about. Emitted as ids and timestamps only: who someone follows is also
    -- a fact about the person on the other end.
    'follows', jsonb_build_object(
      'following', coalesce((
        select jsonb_agg(jsonb_build_object('user_id', f.followee_id, 'created_at', f.created_at)
               order by f.created_at)
        from public.follows f where f.follower_id = v_uid
      ), '[]'::jsonb),
      'followers', coalesce((
        select jsonb_agg(jsonb_build_object('user_id', f.follower_id, 'created_at', f.created_at)
               order by f.created_at)
        from public.follows f where f.followee_id = v_uid
      ), '[]'::jsonb)
    ),

    -- Provided by the subject at sign-up (Art. 20). Null for accounts that
    -- predate the age gate.
    'date_of_birth', (
      select b.date_of_birth from public.user_birthdates b where b.user_id = v_uid
    ),

    -- NEW. Provided by the subject. Null = not specified, which includes
    -- "prefer not to say" (stored as no row).
    'gender', (
      select g.gender from public.user_genders g where g.user_id = v_uid
    )

    -- Deliberately absent: user_devices. Its only interesting column is
    -- last_location, which by the time anyone reads this is either null (24h
    -- retention) or a ~100m cell -- and putting a location history into a
    -- downloadable file is the one thing 7.2 spent a whole phase preventing.
    -- The current cell is shown live in the app instead.
  ) into v_out;

  return v_out;
end;
$function$

;

comment on function public.export_account_data() is
  'GDPR Art. 20 export for the CALLING user only -- takes no user id. Includes bio, avatar_path, dm_policy, each hosted party''s area, address and cover_path, the direct messages the user wrote, the parties whose host removed them (ids and dates), and their gender. Definer so the caller''s own messages survive can_chat_in_party filtering in parties they have since left, and their DMs survive a block.';
