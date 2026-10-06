-- Phase 25: get_party, the read behind a party link.
--
-- The link carries only an id, and an id must not be a capability: every
-- refusal here returns the SAME zero rows as an id that never existed, so a
-- link reveals nothing about a party the caller may not see.
--
-- PARTY_PRIVATE 'aaaaaaaa-…0001' (host's, invitee invited, stranger not),
-- PARTY_PUBLIC 'aaaaaaaa-…0002' (host's), 'aaaaaaaa-…0021' (public, hosted by
-- blocked_user).
begin;
set search_path to public, extensions;
select plan(16);

select is(
  (select prosecdef from pg_proc where oid = 'public.get_party(uuid)'::regprocedure),
  false,
  'get_party is SECURITY INVOKER -- the parties policy is the only authority'
);

select is(
  (select proconfig from pg_proc where oid = 'public.get_party(uuid)'::regprocedure),
  array['search_path=public, extensions'],
  'get_party pins its search_path'
);

-- ===========================================================================
-- Who sees the private party through its link
-- ===========================================================================
select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

select is(
  (select count(*)::int from public.get_party('aaaaaaaa-0000-0000-0000-000000000001')),
  1,
  'an invitee opens the private party from its link'
);

select is(
  (select is_invited from public.get_party('aaaaaaaa-0000-0000-0000-000000000001')),
  true,
  'and is told they are invited'
);

select is(
  (select row(going_count, interested_count)::text
   from public.get_party('aaaaaaaa-0000-0000-0000-000000000001')),
  '(,)',
  'and the private party''s counters are NULL, as on every other surface'
);

-- THE headline negative: a stranger holding the private party's link.
select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select is_empty(
  $$ select * from public.get_party('aaaaaaaa-0000-0000-0000-000000000001') $$,
  'a stranger holding a private party''s link gets nothing'
);

select is_empty(
  $$ select * from public.get_party('00000000-0000-0000-0000-00000000dead') $$,
  'the same nothing as an id that never existed -- existence is not revealed'
);

select is(
  (select count(*)::int from public.get_party('aaaaaaaa-0000-0000-0000-000000000002')),
  1,
  'a stranger opens a public party from its link'
);

select isnt(
  (select going_count from public.get_party('aaaaaaaa-0000-0000-0000-000000000002')),
  null,
  'and a public party''s counters are transmitted'
);

select is(
  (select is_invited from public.get_party('aaaaaaaa-0000-0000-0000-000000000002')),
  false,
  'without claiming an invitation'
);

-- ===========================================================================
-- Blocks, cancellation, the end
-- ===========================================================================
reset role;
insert into public.blocks (blocker_id, blocked_id)
values ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555');
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is_empty(
  $$ select * from public.get_party('aaaaaaaa-0000-0000-0000-000000000021') $$,
  'a link to a public party hosted by someone you blocked opens nothing'
);

reset role;
update public.parties set status = 'cancelled' where id = 'aaaaaaaa-0000-0000-0000-000000000002';
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is_empty(
  $$ select * from public.get_party('aaaaaaaa-0000-0000-0000-000000000002') $$,
  'a cancelled party is not available, even to its host'
);

reset role;
update public.parties
set starts_at = now() - interval '3 hours', ends_at = now() - interval '1 hour'
where id = 'aaaaaaaa-0000-0000-0000-000000000001';
select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

select is_empty(
  $$ select * from public.get_party('aaaaaaaa-0000-0000-0000-000000000001') $$,
  'a party that has ended is not available'
);

reset role;
update public.parties
set starts_at = now() - interval '7 hours', ends_at = null
where id = 'aaaaaaaa-0000-0000-0000-000000000001';
select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

select is_empty(
  $$ select * from public.get_party('aaaaaaaa-0000-0000-0000-000000000001') $$,
  'nor is one with no end time that started longer ago than party_end_grace (gotcha 21)'
);

-- ===========================================================================
-- Privileges
-- ===========================================================================
select tests.clear_authentication();
set local role anon;

select throws_ok(
  $$ select * from public.get_party('aaaaaaaa-0000-0000-0000-000000000002') $$,
  '42501',
  null,
  'anon cannot execute get_party'
);

reset role;

select lives_ok(
  $$ select * from public.get_party('aaaaaaaa-0000-0000-0000-000000000013') $$,
  'get_party runs (gotcha 15: a green reset does not prove a body works)'
);

select * from finish();
rollback;
