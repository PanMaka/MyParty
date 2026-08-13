-- Phase 2a: rsvps RLS (2.1's public-vs-private rule, enforced via
-- public.can_access_party, not reimplemented here), the going/interested
-- counter trigger, create_party_with_invites, and the lifecycle filter +
-- new columns on get_parties_near_user.
begin;
set search_path to public, extensions;
select plan(13);

-- PARTY_PUBLIC ('aaaaaaaa-0000-0000-0000-000000000002', "Syntagma
-- Afterparty"): public, hosted by host.
-- PARTY_PRIVATE ('aaaaaaaa-0000-0000-0000-000000000001', "Rooftop
-- Pregame"): private, hosted by host, invitee + second_host invited.

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

insert into public.rsvps (party_id, user_id, status) values
  ('aaaaaaaa-0000-0000-0000-000000000002', '44444444-4444-4444-4444-444444444444', 'interested');

select isnt_empty(
  $$ select 1 from public.rsvps
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000002'
     and user_id = '44444444-4444-4444-4444-444444444444' $$,
  'stranger can rsvp to a public party'
);

select is(
  (select interested_count from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000002'),
  1,
  'interested_count on the public party ticks up by 1 after insert'
);

select throws_ok(
  $$ insert into public.rsvps (party_id, user_id, status) values
     ('aaaaaaaa-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444', 'interested') $$,
  '42501',
  null,
  'stranger cannot rsvp to a private party they are not invited to'
);

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

insert into public.rsvps (party_id, user_id, status) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'interested');

select isnt_empty(
  $$ select 1 from public.rsvps
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'
     and user_id = '22222222-2222-2222-2222-222222222222' $$,
  'invited guest can rsvp to the private party they were invited to'
);

select is(
  (select interested_count from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  1,
  'interested_count on the private party ticks up by 1 after the invitee''s insert'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

update public.rsvps set status = 'going'
where party_id = 'aaaaaaaa-0000-0000-0000-000000000002'
and user_id = '44444444-4444-4444-4444-444444444444';

select is(
  (select going_count from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000002'),
  1,
  'going_count on the public party ticks up by 1 on an interested->going update'
);

select is(
  (select interested_count from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000002'),
  0,
  'interested_count on the public party ticks back down on the same update'
);

delete from public.rsvps
where party_id = 'aaaaaaaa-0000-0000-0000-000000000002'
and user_id = '44444444-4444-4444-4444-444444444444';

select is(
  (select going_count from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000002'),
  0,
  'going_count on the public party ticks back down after the rsvp is deleted'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select isnt(
  (select public.create_party_with_invites(
    jsonb_build_object(
      'title', 'Test RPC Party',
      'description', 'created by pgTAP',
      'lat', 37.9755,
      'lon', 23.7348,
      'starts_at', (now() + interval '1 day')::text
    ),
    array['22222222-2222-2222-2222-222222222222']::uuid[]
  )),
  null,
  'create_party_with_invites returns the new party id'
);

select is(
  (select host_id from public.parties where title = 'Test RPC Party'),
  '11111111-1111-1111-1111-111111111111'::uuid,
  'create_party_with_invites always sets host_id to the caller'
);

select isnt_empty(
  $$ select 1 from public.invitations i
     join public.parties p on p.id = i.party_id
     where p.title = 'Test RPC Party'
     and i.guest_id = '22222222-2222-2222-2222-222222222222' $$,
  'create_party_with_invites inserts the party and its invitations in one call'
);

select public.create_party_with_invites(
  jsonb_build_object(
    'title', 'Cancelled RPC Party',
    'description', 'should not appear on the map',
    'lat', 37.9755,
    'lon', 23.7348,
    'starts_at', (now() + interval '1 day')::text,
    'status', 'cancelled'
  ),
  '{}'::uuid[]
);

select is_empty(
  $$ select 1 from public.get_parties_near_user(23.7348, 37.9755, 500)
     where title = 'Cancelled RPC Party' $$,
  'get_parties_near_user excludes parties whose status is not published'
);

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

select results_eq(
  $$ select going_count, my_rsvp_status, is_invited
     from public.get_parties_near_user(23.7348, 37.9755, 500)
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  $$ values (0, 'interested'::public.rsvp_status, true) $$,
  'get_parties_near_user reports the caller''s own rsvp status, going_count and invited flag'
);

select tests.clear_authentication();

select * from finish();
rollback;
