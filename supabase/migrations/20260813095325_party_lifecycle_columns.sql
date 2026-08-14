-- Party lifecycle: rename the original start_time to starts_at (clearer
-- pairing with the new ends_at), and add the columns Phase 2 needs to
-- publish/cancel parties and to stop computing attendance with count(*).

alter table public.parties rename column start_time to starts_at;

alter table public.parties add column ends_at timestamp with time zone;

create type public.party_status as enum ('draft', 'published', 'cancelled');

-- Default 'published' so every existing (pre-lifecycle) party row stays
-- visible under the new get_parties_near_user status filter.
alter table public.parties
  add column status public.party_status not null default 'published';

alter table public.parties add column going_count int not null default 0;
alter table public.parties add column interested_count int not null default 0;
