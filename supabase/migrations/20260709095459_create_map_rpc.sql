-- Get the viewport of the map on user's phone
create or replace function public.get_parties_near_user(
  map_center_lon double precision,
  map_center_lat double precision,
  radius_meters double precision
)

-- Return this list
returns table (
  party_id uuid,
  title text,
  description text,
  start_time timestamp with time zone,
  is_private boolean,
  is_sponsored boolean,
  party_tier text,
  host_id uuid,
  host_username text,
  lat double precision,
  lon double precision,
  distance_meters double precision
)

-- Function to calculate how zoomed-in/out the user's map is and what parties to preview on each case
language sql
as $$
  select
    p.id as party_id,
    p.title,
    p.description,
    p.start_time,
    p.is_private,
    p.is_sponsored,
    p.party_tier,
    p.host_id,
    pr.username as host_username,

    -- Grab party location
    st_y(p.location::geometry) as lat,
    st_x(p.location::geometry) as lon,

    -- Distance from current user's map view
    st_distance(p.location, st_point(map_center_lon, map_center_lat)::geography) as distance_meters

  from public.parties p
  join public.profiles pr on p.host_id = pr.id
  where

    -- PostGIS proximity check
    st_dwithin(p.location, st_point(map_center_lon, map_center_lat)::geography, radius_meters)
    
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