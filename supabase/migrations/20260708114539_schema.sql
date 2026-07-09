-- Enable PostGIS extension to handle the geographical math
create extension if not exists postgis;

-- Each user's profile (linked through supabase's built-in auth.users)
create table public.profiles (
  id uuid references auth.users on delete cascade primary key,
  username text unique not null,
  credibility_score int default 0,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null
);

-- Table that will hold all the parties
create table public.parties (
  id uuid default gen_random_uuid() primary key,
  host_id uuid references public.profiles(id) on delete cascade not null,
  title text not null,
  description text,
  
  -- PostGIS geography (POINT is used because each party will be a single point on the map and 4326 is the standard WGS 84, the same every GPS uses)
  location geography(POINT, 4326) not null,
  
  start_time timestamp with time zone not null,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null
);

-- Use GiST to locate the overlapping "bounding-boxes" to search for parties in
create index parties_location on public.parties using gist (location);