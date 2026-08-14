-- Denormalized going_count/interested_count on parties, maintained here
-- instead of count(*) at read time (CLAUDE.md #6). One UPDATE per row
-- event: party_id is part of rsvps' primary key, so NEW/OLD always refer
-- to the same party row on an update, meaning a single delta update is
-- both correct and cheaper than decrementing-then-incrementing. The
-- `is distinct from` guard means an update that doesn't touch status is a
-- no-op for the counters, so it can't double-count.

create or replace function public.sync_party_rsvp_counters()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if TG_OP = 'DELETE' then
    update public.parties set
      going_count = going_count - (OLD.status = 'going')::int,
      interested_count = interested_count - (OLD.status = 'interested')::int
    where id = OLD.party_id;
    return null;
  end if;

  if TG_OP = 'INSERT' then
    update public.parties set
      going_count = going_count + (NEW.status = 'going')::int,
      interested_count = interested_count + (NEW.status = 'interested')::int
    where id = NEW.party_id;
    return null;
  end if;

  -- TG_OP = 'UPDATE'
  if NEW.status is distinct from OLD.status then
    update public.parties set
      going_count = going_count
        + (NEW.status = 'going')::int - (OLD.status = 'going')::int,
      interested_count = interested_count
        + (NEW.status = 'interested')::int - (OLD.status = 'interested')::int
    where id = NEW.party_id;
  end if;
  return null;
end;
$$;

create trigger rsvps_sync_counters
after insert or update or delete on public.rsvps
for each row execute function public.sync_party_rsvp_counters();
