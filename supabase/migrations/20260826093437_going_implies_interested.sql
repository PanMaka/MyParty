-- interested_count now INCLUDES everyone who chose going.
--
-- The two columns were siblings: an rsvp landed in exactly one of them, and an
-- interested -> going transition MOVED the person across. They are now nested.
-- interested_count is "how many people said anything at all"; going_count is
-- "how many of those committed", a strict subset of it.
--
-- WHY, in one line: going implies interested. Somebody who is coming is, by
-- construction, interested, and a party with 30 going and 0 interested was
-- reporting zero interest in a full room.
--
-- WHAT THIS IS NOT. going_count is untouched in both meaning and value, and
-- rsvp_status is untouched -- a row is still exactly one of 'going' or
-- 'interested', and nothing that reads r.status changes. get_profile_stats
-- counts rsvps rows rather than these columns and is unaffected for that
-- reason. The nesting exists only in the denormalized counters.
--
-- THE READ SIDE NEEDS NO MIGRATION. All five readers -- get_parties_near_user,
-- search_parties, get_hosted_parties, get_party_chats and export_account_data
-- -- pass the columns through untouched. Nothing in the schema adds them
-- together, and nothing derives a third number from them: party_tier is a
-- plain column set by the host at creation, not a function of attendance.
--
-- PRIVATE PARTIES ARE INCLUDED, and that retires an invariant on purpose.
-- 20260825090050 makes 'interested' an illegal status on a private party, and
-- the consequence was recorded as "the interested counter on a private row can
-- never be non-zero". After this migration a private party with one going has
-- interested_count = 1. Nothing transmits it -- 20260825090051 nulls BOTH
-- counters on a private row in both read RPCs, and that is untouched here --
-- so the suppression that actually protects the number is unaffected. What is
-- gone is the incidental second guarantee. The alternative, incrementing
-- interested only on public parties, buys that guarantee back at the price of
-- reading parties.is_private on every rsvp event and making "going implies
-- interested" a rule with two shapes; the rule is simpler than the invariant
-- it costs. Decided 2026-08-26.


-- ===========================================================================
-- PART 1 -- the trigger.
-- ===========================================================================
-- Same shape as before: one UPDATE per row event, deltas rather than
-- recounts, and the `is distinct from` guard on UPDATE so a write that does
-- not touch status is a no-op for the counters.
--
-- The only change is what interested_count's delta is. It was
-- `(status = 'interested')::int`; it is now 1 for every row, because every
-- rsvp of either status is now counted there.
--
-- Which makes the UPDATE branch's interested term ZERO, and that is the whole
-- point of the change rather than an oversight: a status flip in either
-- direction adds a row to no set and removes it from none, since the person
-- was already counted as interested before the flip and still is after it.
-- The term is written out as `+ 0` nowhere -- it is simply absent from the
-- UPDATE branch, which now touches going_count alone.
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
      -- Every rsvp counted as interested, so every delete decrements it,
      -- whichever status the departing row held.
      interested_count = interested_count - 1
    where id = OLD.party_id;
    return null;
  end if;

  if TG_OP = 'INSERT' then
    update public.parties set
      going_count = going_count + (NEW.status = 'going')::int,
      interested_count = interested_count + 1
    where id = NEW.party_id;
    return null;
  end if;

  -- TG_OP = 'UPDATE'
  --
  -- going_count only. interested_count does not move on a status change in
  -- EITHER direction: interested -> going must not decrement it (the person is
  -- still interested, and decrementing is exactly the old behaviour this
  -- migration removes), and going -> interested must not increment it (they
  -- were already counted). A membership that does not change has no delta.
  if NEW.status is distinct from OLD.status then
    update public.parties set
      going_count = going_count
        + (NEW.status = 'going')::int - (OLD.status = 'going')::int
    where id = NEW.party_id;
  end if;
  return null;
end;
$$;

comment on function public.sync_party_rsvp_counters() is
  'Denormalized rsvp counters. interested_count counts EVERY rsvp; going_count '
  'counts the going subset of them, so going_count <= interested_count always. '
  'A status flip moves going_count only -- interested membership is unchanged '
  'by it in either direction.';

-- The trigger itself is unchanged (after insert or update or delete, for each
-- row) and is not redefined: `create or replace function` reaches it, and
-- dropping and recreating a trigger to change a function body would be a
-- window during which counters silently stop being maintained.


-- ===========================================================================
-- PART 2 -- the backfill.
-- ===========================================================================
-- Every existing going rsvp was counted in going_count and NOT in
-- interested_count. Adding going_count to interested_count is exactly the set
-- of rows the old trigger excluded, so the arithmetic is a straight sum.
--
-- This is deliberately NOT a recount from public.rsvps. A recount would be
-- self-healing, which sounds better and is worse here: it would silently paper
-- over any pre-existing drift between the counters and the rows, and the one
-- moment that drift is worth discovering is a migration that touches these
-- columns. A blind delta preserves it, and the assertion below reports it.
update public.parties
set interested_count = interested_count + going_count
where going_count <> 0;

-- Proof the backfill landed somewhere legal. going_count is a subset of
-- interested_count from here on, so going_count > interested_count on any row
-- means the invariant was violated at write time or the backfill ran twice --
-- both of which are worth failing the migration over rather than shipping.
--
-- Migrations are append-only (CLAUDE.md #7), so re-running this file is not a
-- supported operation; this catches the case where it happened anyway.
do $$
declare
  v_bad int;
begin
  select count(*) into v_bad
  from public.parties
  where going_count > interested_count;

  if v_bad > 0 then
    raise exception
      'backfill left % parties with going_count > interested_count', v_bad;
  end if;
end;
$$;

comment on column public.parties.interested_count is
  'Every rsvp on this party, of either status -- going included. Superset of '
  'going_count. NULL over the wire on a private row (20260825090051).';

comment on column public.parties.going_count is
  'The rsvps on this party with status = going. Strict subset of '
  'interested_count. NULL over the wire on a private row (20260825090051).';
