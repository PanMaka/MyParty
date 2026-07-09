-- Enable security for the tables (will be adjusted as time goes on)
alter table public.profiles enable row level security;
alter table public.parties enable row level security;
alter table public.invitations enable row level security;

-- Everyone can view the profiles of others
create policy "Profiles are viewable by everyone" 
on public.profiles for select 
using ( true );

-- Users can only edit their own profilr
create policy "Users can update own profile" 
on public.profiles for update 
to authenticated 
using ( (select auth.uid()) = id )
with check ( (select auth.uid()) = id );



-- Policy on who can see which parties on the map
create policy "Parties are viewable based on privacy and invitations"
on public.parties for select
using (
  -- The party is visible if the party is public
  not is_private
  or (select auth.uid()) = host_id  -- or if the user is the actual host of the party
  or exists (                       -- or if the user was specifically invited
    select 1 
    from public.invitations
    where invitations.party_id = public.parties.id 
    and invitations.guest_id = (select auth.uid())
  )
);

-- Only the host can view and manage the guest list
create policy "Hosts can view guest lists for their parties"
on public.invitations for select to authenticated
using (
  exists (
    select 1 from public.parties
    where parties.id = invitations.party_id
    and parties.host_id = (select auth.uid())
  )
  or guest_id = (select auth.uid())
);

-- Only hosts can invite guests to their parties
create policy "Hosts can invite guests"
on public.invitations for insert to authenticated
with check (
  exists (
    select 1 from public.parties
    where parties.id = invitations.party_id
    and parties.host_id = (select auth.uid())
  )
);

-- Every authenticated user can create a party, but only for himself
create policy "Users can create parties" 
on public.parties for insert 
to authenticated 
with check ( (select auth.uid()) = host_id );

-- Hosts can edit their own parties
create policy "Hosts can update own parties" 
on public.parties for update 
to authenticated 
using ( (select auth.uid()) = host_id )
with check ( (select auth.uid()) = host_id );

-- Hosts can delete their own parties
create policy "Hosts can delete own parties" 
on public.parties for delete 
to authenticated 
using ( (select auth.uid()) = host_id );


-- Function to ensure on update that the credibility score cannot be tweeked by the user
create or replace function public.protect_credibility_score()
returns trigger as $$
begin
  if auth.role() = 'authenticated' then
    new.credibility_score = old.credibility_score;
  end if;
  
  return new;
end;
$$ language plpgsql;

-- Trigger for the credibility score
create trigger enforce_credibility_security
before update on public.profiles
for each row
execute function public.protect_credibility_score();