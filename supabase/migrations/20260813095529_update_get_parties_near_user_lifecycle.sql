-- get_parties_near_user grows RSVP/lifecycle awareness. The return table
-- shape changes, so `create or replace` isn't enough (Postgres rejects a
-- replace that changes the output column list) — drop and recreate.
-- Tier/zoom filtering logic is untouched, per Phase 2's requirement.

drop function if exists public.get_parties_near_user(double precision, double precision, double precision);

create function public.get_parties_near_user(
  map_center_lon double precision,
  map_center_lat double precision,
  radius_meters double precision
)

returns table (
  party_id uuid,
  title text,
  description text,
  starts_at timestamp with time zone,
  is_private boolean,
  is_sponsored boolean,
  party_tier text,
  host_id uuid,
  host_username text,
  lat double precision,
  lon double precision,
  distance_meters double precision,
  going_count int,
  my_rsvp_status public.rsvp_status,
  is_invited boolean
)

language sql
as $$
  select
    p.id as party_id,
    p.title,
    p.description,
    p.starts_at,
    p.is_private,
    p.is_sponsored,
    p.party_tier,
    p.host_id,
    pr.username as host_username,

    -- Grab party location
    st_y(p.location::geometry) as lat,
    st_x(p.location::geometry) as lon,

    -- Distance from current user's map view
    st_distance(p.location, st_point(map_center_lon, map_center_lat)::geography) as distance_meters,

    p.going_count,

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

    -- Only surface parties that are live and haven't ended
    p.status = 'published'
    and (p.ends_at is null or p.ends_at > now())

    -- PostGIS proximity check
    and st_dwithin(p.location, st_point(map_center_lon, map_center_lat)::geography, radius_meters)

    -- Filter which parties to show
    and case
        -- If the viewport is small (Zoomed in)
        when radius_meters <= 15000
        then true

        -- If the viewport is medium (Zoomed out to a region)
        when radius_meters <= 100000
        then p.party_tier in ('large', 'mega')

        -- If the viewport is large (Zoomed out to the globe)
        else
        p.party_tier = 'mega' or p.is_sponsored = true
    end
  order by p.is_sponsored desc, distance_meters asc;
$$;
