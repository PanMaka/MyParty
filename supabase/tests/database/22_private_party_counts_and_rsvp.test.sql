-- Phase 16b: a private party holds only 'going' RSVPs, and reports no
-- attendance to anybody through either read RPC.
--
-- Two independent rules that together make "a private party shows no counts"
-- true at the source rather than by client convention:
--   1. 20260825090050 -- the rsvps write policies refuse 'interested' on a
--      private party, so the interested counter can never be non-zero there.
--   2. 20260825090051 -- get_parties_near_user and search_parties return NULL
--      for both counters on a private row, so the figure is not transmitted.
--
-- Each is asserted on its own, and each is asserted NEGATIVELY (who cannot
-- write / what is not returned), because both are only interesting in the
-- refusal case.
--
-- PARTY_PRIVATE 'aaaaaaaa-...0001' "Rooftop Pregame", host = host,
--   invitee + second_host invited.
-- PARTY_PUBLIC  'aaaaaaaa-...0002' "Syntagma Afterparty", host = host.
begin;
set search_path to public, extensions;
select plan(21);

-- ===========================================================================
-- The enum still has exactly two values.
-- ===========================================================================
-- Not decoration. The obvious way to implement "un-tap" is a third enum value
-- ('declined'), and that choice is what this whole file assumes was NOT made:
-- un-RSVPing is `delete from rsvps`, which the DELETE policy and the counter
-- trigger's DELETE branch have supported since 20260813095416/51. A third
-- value would also silently widen my_rsvp_status on three read RPCs. If
-- somebody adds one, this fails first and they read the reasoning.
select set_eq(
  $$ select unnest(enum_range(null::public.rsvp_status))::text $$,
  $$ values ('interested'), ('going') $$,
  'rsvp_status has exactly two values -- un-rsvping is a DELETE, not a third state'
);

-- ===========================================================================
-- The helpers
-- ===========================================================================
select is(
  public.party_is_private('aaaaaaaa-0000-0000-0000-000000000001'),
  true,
  'party_is_private is true for the private party'
);

select is(
  public.party_is_private('aaaaaaaa-0000-0000-0000-000000000002'),
  false,
  'party_is_private is false for the public party'
);

-- Gotcha 1: this asks a question about the PARTY, not about the viewer, so it
-- must be SECURITY DEFINER or a caller who cannot see the row gets "not
-- private" and is then permitted to write an interested row to it.
select is(
  (select prosecdef from pg_proc where oid = 'public.party_is_private(uuid)'::regprocedure),
  true,
  'party_is_private is SECURITY DEFINER -- privacy is a property of the party, not of the viewer'
);

select is(
  (select proconfig from pg_proc where oid = 'public.party_is_private(uuid)'::regprocedure),
  array['search_path=""'],
  'party_is_private pins an empty search_path (CLAUDE.md #3)'
);

select is(
  (select proconfig from pg_proc where oid = 'public.rsvp_status_allowed(uuid, public.rsvp_status)'::regprocedure),
  array['search_path=""'],
  'rsvp_status_allowed pins an empty search_path'
);

select is(
  public.rsvp_status_allowed('aaaaaaaa-0000-0000-0000-000000000001', 'interested'),
  false,
  'rsvp_status_allowed refuses interested on a private party'
);

select is(
  public.rsvp_status_allowed('aaaaaaaa-0000-0000-0000-000000000001', 'going'),
  true,
  'rsvp_status_allowed permits going on a private party'
);

select is(
  public.rsvp_status_allowed('aaaaaaaa-0000-0000-0000-000000000002', 'interested'),
  true,
  'rsvp_status_allowed permits interested on a public party'
);

-- ===========================================================================
-- The write policy, as the invited guest
-- ===========================================================================
select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

-- THE headline negative. This guest passes can_access_party -- they are
-- invited -- so the ONLY thing refusing this row is the new status term.
select throws_ok(
  $$ insert into public.rsvps (party_id, user_id, status) values
     ('aaaaaaaa-0000-0000-0000-000000000001',
      '22222222-2222-2222-2222-222222222222', 'interested') $$,
  '42501',
  null,
  'an INVITED guest still cannot write an interested rsvp to a private party'
);

insert into public.rsvps (party_id, user_id, status) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'going');

select isnt_empty(
  $$ select 1 from public.rsvps
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'
     and user_id = '22222222-2222-2222-2222-222222222222'
     and status = 'going' $$,
  'the same guest can write a going rsvp to the same private party'
);

-- The UPDATE path, which is a genuinely separate hole: the status rule lives
-- in the WITH CHECK, not the USING, so it tests the NEW row. Spelled in USING
-- it would test the row being replaced -- 'going' -- and wave this through.
select throws_ok(
  $$ update public.rsvps set status = 'interested'
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'
     and user_id = '22222222-2222-2222-2222-222222222222' $$,
  '42501',
  null,
  'a going rsvp on a private party cannot be UPDATED to interested'
);

-- Un-RSVPing: the row goes away, and the counter follows it back down. This
-- is the whole of "what happens on un-tap".
delete from public.rsvps
where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'
and user_id = '22222222-2222-2222-2222-222222222222';

select is(
  (select going_count from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  0,
  'deleting the rsvp is the un-rsvp, and going_count follows it back to 0'
);

-- ===========================================================================
-- A public party still takes both, and still switches between them
-- ===========================================================================
insert into public.rsvps (party_id, user_id, status) values
  ('aaaaaaaa-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'interested');

select is(
  (select interested_count from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000002'),
  1,
  'a public party still accepts interested'
);

update public.rsvps set status = 'going'
where party_id = 'aaaaaaaa-0000-0000-0000-000000000002'
and user_id = '22222222-2222-2222-2222-222222222222';

select results_eq(
  $$ select interested_count, going_count from public.parties
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  $$ values (0, 1) $$,
  'a public party switches interested -> going in place, both counters moving'
);

-- ===========================================================================
-- What the read RPCs transmit
-- ===========================================================================
-- The private party, seen by somebody who is invited to it and can therefore
-- see the row at all. Both counters NULL.
select results_eq(
  $$ select going_count, interested_count
     from public.get_parties_near_user(23.7348, 37.9755, 500)
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  $$ values (null::integer, null::integer) $$,
  'get_parties_near_user transmits NULL for BOTH counters on a private party'
);

-- ...while my_rsvp_status is untouched. It is a property of the CALLER, not of
-- the party, so suppressing it would break the button label on the sheet while
-- protecting nothing -- the viewer already knows their own answer.
insert into public.rsvps (party_id, user_id, status) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'going');

select results_eq(
  $$ select my_rsvp_status, is_invited
     from public.get_parties_near_user(23.7348, 37.9755, 500)
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  $$ values ('going'::public.rsvp_status, true) $$,
  'the caller''s OWN rsvp status is still reported on a private party'
);

-- The public party in the same viewport still reports real numbers, which is
-- what makes the assertion above a difference rather than a blanket null.
select results_eq(
  $$ select going_count, interested_count
     from public.get_parties_near_user(23.7351, 37.9758, 500)
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  $$ values (1, 0) $$,
  'get_parties_near_user still transmits real counters on a public party'
);

-- search_parties is the OTHER door into the same MapPinSheet (20260822150239,
-- 20260824094606). Fixing only the map RPC would leave the identical widget
-- rendering the number when it was reached from search.
select results_eq(
  $$ select going_count, interested_count from public.search_parties('rooftop')
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  $$ values (null::integer, null::integer) $$,
  'search_parties transmits NULL for both counters on a private party too'
);

select results_eq(
  $$ select going_count, interested_count from public.search_parties('syntagma')
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  $$ values (1, 0) $$,
  'search_parties still transmits real counters on a public party'
);

-- The columns themselves are untouched: the HOST still has a guest list, and
-- party_tier still reads them. Suppression is at the transmission boundary,
-- not in the data.
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is(
  (select going_count from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  1,
  'parties.going_count is still maintained on a private party -- the host has a guest list'
);

select tests.clear_authentication();

select * from finish();
rollback;
