-- Smoke test for the pgTAP harness itself: proves
-- tests.authenticate_as()/tests.clear_authentication() (defined in
-- seed.sql) correctly drive the EXISTING RLS policies on
-- profiles/parties/invitations. No new policies are added by this
-- migration set — this only proves the harness against what's
-- already there.
begin;
set search_path to public, extensions;
select plan(6);

-- PARTY_PRIVATE ('aaaaaaaa-0000-0000-0000-000000000001', "Rooftop
-- Pregame"): hosted by host, invitee + second_host invited.

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select isnt_empty(
  $$ select 1 from public.profiles where id = '11111111-1111-1111-1111-111111111111' $$,
  'stranger can view the host''s profile (profiles are public)'
);

select isnt_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'stranger can view a public party'
);

select is_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'stranger cannot view a private party they are not invited to'
);

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

select isnt_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'invited guest can view the private party they were invited to'
);

select is_empty(
  $$ select 1 from public.invitations
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'
     and guest_id <> (select auth.uid()) $$,
  'invitee cannot see another guest''s invitation row for a party they do not host'
);

select tests.clear_authentication();

select is_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'unauthenticated session cannot view a private party'
);

select * from finish();
rollback;
