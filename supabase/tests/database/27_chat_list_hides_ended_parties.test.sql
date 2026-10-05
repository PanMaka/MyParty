-- 20261005112432: the Messages list drops a chat 24 hours after its party
-- ENDS, and that is the list only -- access to the chat is untouched.
--
-- Four private parties hosted by `host`, with `invitee` invited to each:
--   RECENT   ended 12 hours ago        -> still listed (inside the day)
--   STALE    ended 30 hours ago        -> gone from the list
--   NO_END   started 30 days ago, no ends_at -> still listed (gotcha 21: the
--            map pins it and MY PARTIES lists it, so the chat must match)
--   FUTURE   starts tomorrow           -> listed
-- and the negative half: a stranger sees none of them, ended or not.
begin;
set search_path to public, extensions;
select plan(10);

insert into public.parties (id, host_id, title, description, location, starts_at, ends_at, is_private, is_sponsored, party_tier, area)
values
  ('cccccccc-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'Recent', 'Ended 12h ago.', st_point(23.7348, 37.9755)::geography,
   now() - interval '18 hours', now() - interval '12 hours', true, false, 'standard', 'Σύνταγμα'),
  ('cccccccc-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'Stale', 'Ended 30h ago.', st_point(23.7348, 37.9755)::geography,
   now() - interval '36 hours', now() - interval '30 hours', true, false, 'standard', 'Σύνταγμα'),
  ('cccccccc-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   'No End', 'Started a month ago, no end time.', st_point(23.7348, 37.9755)::geography,
   now() - interval '30 days', null, true, false, 'standard', 'Σύνταγμα'),
  ('cccccccc-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111',
   'Future', 'Tomorrow.', st_point(23.7348, 37.9755)::geography,
   now() + interval '1 day', now() + interval '1 day 5 hours', true, false, 'standard', 'Σύνταγμα');

insert into public.invitations (party_id, guest_id)
select id, '22222222-2222-2222-2222-222222222222'
from public.parties where id::text like 'cccccccc-%';

-- ---------------------------------------------------------------------------
-- The host's list
-- ---------------------------------------------------------------------------
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

-- gotcha 15: a body that applies cleanly is not one that runs.
select lives_ok($$ select * from public.get_party_chats() $$, 'get_party_chats runs');

select ok(exists(select 1 from public.get_party_chats() where party_id = 'cccccccc-0000-0000-0000-000000000001'),
  'a chat whose party ended 12h ago is still listed');
select ok(not exists(select 1 from public.get_party_chats() where party_id = 'cccccccc-0000-0000-0000-000000000002'),
  'a chat whose party ended 30h ago is NOT listed');
select ok(exists(select 1 from public.get_party_chats() where party_id = 'cccccccc-0000-0000-0000-000000000003'),
  'a chat whose party has no ends_at is kept, matching the map and MY PARTIES');
select ok(exists(select 1 from public.get_party_chats() where party_id = 'cccccccc-0000-0000-0000-000000000004'),
  'an upcoming party''s chat is listed');

-- The list hides; access does not move. If this ever goes false, the change
-- leaked out of get_party_chats into the access rule.
select ok(public.can_chat_in_party('cccccccc-0000-0000-0000-000000000002'),
  'the host may still chat in the hidden party -- only the list dropped it');

-- ---------------------------------------------------------------------------
-- The invitee: same rule from the other door into the chat
-- ---------------------------------------------------------------------------
select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

select ok(exists(select 1 from public.get_party_chats() where party_id = 'cccccccc-0000-0000-0000-000000000001'),
  'the invitee sees the recently ended chat');
select ok(not exists(select 1 from public.get_party_chats() where party_id = 'cccccccc-0000-0000-0000-000000000002'),
  'the invitee does not see the stale chat either');

-- ---------------------------------------------------------------------------
-- Negative: not invited, not hosting -> nothing, in any tense
-- ---------------------------------------------------------------------------
select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select is((select count(*)::int from public.get_party_chats() where party_id::text like 'cccccccc-%'), 0,
  'a stranger sees none of the four chats');

-- A stranger who RSVPs to nothing still cannot reach one by rsvp: only
-- 'going' is legal on a private party and the insert needs can_access_party.
select throws_ok(
  $$ insert into public.rsvps (party_id, user_id, status)
     values ('cccccccc-0000-0000-0000-000000000004', '44444444-4444-4444-4444-444444444444', 'going') $$,
  '42501', null,
  'a stranger cannot rsvp their way into a private party''s chat');

select * from finish();
rollback;
