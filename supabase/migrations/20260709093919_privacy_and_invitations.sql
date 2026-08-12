-- Add columns on the parties table
alter table public.parties add column is_private boolean default false not null;
alter table public.parties add column is_sponsored boolean default false not null;
alter table public.parties add column party_tier text default 'standard' not null;
alter table public.parties add column max_capacity int;

-- Create a guest list of invitations for parties
create table public.invitations (
  id uuid default gen_random_uuid() primary key,
  party_id uuid references public.parties(id) on delete cascade not null,
  guest_id uuid references public.profiles(id) on delete cascade not null,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  
  -- Each pair of party, guest id needs to be unique
  unique (party_id, guest_id)
);