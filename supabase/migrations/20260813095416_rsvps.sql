-- Guest-controlled RSVPs, distinct from host-controlled invitations
-- (see docs/backend-plan.md 2.1): an invitation says a private party is
-- visible to this person, an rsvp says they're going/interested. Reuses
-- public.can_access_party (CLAUDE.md #4: one helper per visibility rule)
-- so the "private party requires an existing invitation" check isn't
-- reimplemented here — can_access_party already evaluates to exactly
-- that for a private party (host or invited), and to true for any
-- public party.

create type public.rsvp_status as enum ('interested', 'going');

create table public.rsvps (
  party_id uuid references public.parties(id) on delete cascade not null,
  user_id uuid references public.profiles(id) on delete cascade not null,
  status public.rsvp_status not null,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  primary key (party_id, user_id)
);

create index rsvps_party_id_idx on public.rsvps (party_id);

alter table public.rsvps enable row level security;

create policy "Rsvps are viewable by the host or the rsvper"
on public.rsvps for select to authenticated
using (
  user_id = (select auth.uid())
  or exists (
    select 1 from public.parties
    where parties.id = rsvps.party_id
    and parties.host_id = (select auth.uid())
  )
);

create policy "Users can rsvp to parties they can access"
on public.rsvps for insert to authenticated
with check (
  user_id = (select auth.uid())
  and public.can_access_party(party_id)
);

create policy "Users can update their own rsvp"
on public.rsvps for update to authenticated
using ( user_id = (select auth.uid()) )
with check (
  user_id = (select auth.uid())
  and public.can_access_party(party_id)
);

create policy "Users can delete their own rsvp"
on public.rsvps for delete to authenticated
using ( user_id = (select auth.uid()) );
