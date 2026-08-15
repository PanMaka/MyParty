-- Phase 6: group chat, broadcast-from-database delivery, and read state.
--
-- The phase was specified around one negative assertion: a non-invitee must
-- receive NOTHING -- not the message, not even the broadcast event. Those are
-- two different leaks with two different causes, so they are asserted in two
-- separate layers here and neither one substitutes for the other:
--
--   Layer 1, the ROW      -- public.messages SELECT/INSERT policy. A failure
--                            here leaks history to anyone who asks for it.
--   Layer 2, the EVENT    -- the RLS policy on realtime.messages, which is
--                            what decides whether a client may JOIN the
--                            party:{uuid} topic at all. A failure here leaks
--                            every future message live, and Layer 1 passing
--                            says nothing about it -- they are enforced by
--                            different policies on different tables.
--
-- Layer 2 is testable because realtime.send sets `realtime.topic` with SET
-- LOCAL and the policy reads it back through realtime.topic(). Setting that
-- GUC by hand is exactly what Realtime does when authorizing a subscribe, so
-- `set_config('realtime.topic', ...)` + select is a faithful stand-in for a
-- channel join.
--
-- Personas (seed.sql): host 1111, invitee 2222, friend_not_invited 3333,
-- stranger 4444, blocked_user 5555, second_host 6666.
-- Parties: aaaa…0001 private (host's, invitee + second_host invited),
-- aaaa…0002 public (host's), aaaa…0021 public (blocked_user's).
--
-- Every row is created inside this transaction, following Phases 3 and 4, so
-- the broadcast, rate-limit and clamp triggers all get exercised for real and
-- the earlier suites keep seeing exactly the fixture they were written
-- against.
begin;
set search_path to public, extensions;
select plan(48);

-- ============================================================
-- Membership on a PRIVATE party. This half is inherited from
-- can_access_party and behaves the way party_posts does.
-- ============================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

insert into public.messages (id, party_id, author_id, body) values
  ('dddddddd-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111',
   'door code is 4471');

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

select isnt_empty(
  $$ select 1 from public.messages
     where id = 'dddddddd-0000-0000-0000-000000000001' $$,
  'an invitee sees a message in the private party they were invited to'
);

insert into public.messages (id, party_id, author_id, body) values
  ('dddddddd-0000-0000-0000-000000000002',
   'aaaaaaaa-0000-0000-0000-000000000001',
   '22222222-2222-2222-2222-222222222222',
   'on my way');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

-- LAYER 1 of the verification bar.
select is_empty(
  $$ select 1 from public.messages
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'LAYER 1: a non-invitee reads NOTHING from a private party chat'
);

select throws_ok(
  $$ insert into public.messages (party_id, author_id, body) values
     ('aaaaaaaa-0000-0000-0000-000000000001',
      '44444444-4444-4444-4444-444444444444',
      'let me in') $$,
  '42501',
  null,
  'a non-invitee cannot post into a private party chat'
);

-- created_at is not in the INSERT grant, so a message cannot be back- or
-- future-dated to sort itself out of the keyset window.
select throws_ok(
  $$ insert into public.messages (party_id, author_id, body, created_at) values
     ('aaaaaaaa-0000-0000-0000-000000000001',
      '44444444-4444-4444-4444-444444444444',
      'pinned',
      now() + interval '10 years') $$,
  '42501',
  null,
  'a client cannot set created_at on a message (column-level insert grant)'
);


-- ============================================================
-- Membership on a PUBLIC party -- the half can_access_party gets WRONG for
-- chat, and the reason can_chat_in_party exists. can_access_party is true
-- here for every signed-in user on the platform; chat additionally demands
-- actual participation.
-- ============================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

insert into public.messages (id, party_id, author_id, body) values
  ('dddddddd-0000-0000-0000-000000000010',
   'aaaaaaaa-0000-0000-0000-000000000002',
   '11111111-1111-1111-1111-111111111111',
   'public party chat opener');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select ok(
  public.can_access_party('aaaaaaaa-0000-0000-0000-000000000002'),
  'a stranger CAN access a public party -- can_access_party is true here'
);

select ok(
  not public.can_chat_in_party('aaaaaaaa-0000-0000-0000-000000000002'),
  'but they cannot CHAT in it without participating -- can_chat_in_party is narrower'
);

select is_empty(
  $$ select 1 from public.messages
     where id = 'dddddddd-0000-0000-0000-000000000010' $$,
  'so a public party chat is not readable by a passer-by'
);

select throws_ok(
  $$ insert into public.messages (party_id, author_id, body) values
     ('aaaaaaaa-0000-0000-0000-000000000002',
      '44444444-4444-4444-4444-444444444444',
      'drive-by') $$,
  '42501',
  null,
  'and a passer-by cannot post into it either'
);

-- An rsvp is participation. 'interested' counts as well as 'going', the same
-- call get_feed makes.
insert into public.rsvps (party_id, user_id, status) values
  ('aaaaaaaa-0000-0000-0000-000000000002', '44444444-4444-4444-4444-444444444444', 'interested');

select ok(
  public.can_chat_in_party('aaaaaaaa-0000-0000-0000-000000000002'),
  'rsvping to a public party joins its chat (an ''interested'' rsvp counts)'
);

select isnt_empty(
  $$ select 1 from public.messages
     where id = 'dddddddd-0000-0000-0000-000000000010' $$,
  'and the history opens up -- the rule does not over-reach'
);

insert into public.messages (id, party_id, author_id, body) values
  ('dddddddd-0000-0000-0000-000000000011',
   'aaaaaaaa-0000-0000-0000-000000000002',
   '44444444-4444-4444-4444-444444444444',
   'hello from a stranger');

-- A follow is NOT participation. The social graph is follows-only and
-- asymmetric, and it grants no private visibility anywhere else either.
select tests.authenticate_as('33333333-3333-3333-3333-333333333333'); -- friend_not_invited

insert into public.follows (follower_id, followee_id) values
  ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111');

select ok(
  not public.can_chat_in_party('aaaaaaaa-0000-0000-0000-000000000002'),
  'following the host does not put you in their party chat'
);


-- ============================================================
-- LAYER 2: the broadcast event itself.
--
-- Setting realtime.topic is what Realtime does when authorizing a channel
-- join, so these four assertions are the closest a SQL test gets to "did the
-- subscribe succeed". A zero result is not a filtered message -- it is a
-- refused topic, which means no event on that topic is ever routed to that
-- socket.
-- ============================================================
select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee
select set_config('realtime.topic', 'party:aaaaaaaa-0000-0000-0000-000000000001', true);

select isnt_empty(
  $$ select 1 from realtime.messages
     where topic = 'party:aaaaaaaa-0000-0000-0000-000000000001'
     and event = 'new_message' $$,
  'the insert trigger broadcast to party:{party_id}, and an invitee may join that topic'
);

select is(
  (select payload->>'author_username' from realtime.messages
   where payload->>'id' = 'dddddddd-0000-0000-0000-000000000001'),
  'host',
  'the broadcast payload carries the author username resolved by the definer trigger'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger
select set_config('realtime.topic', 'party:aaaaaaaa-0000-0000-0000-000000000001', true);

-- THE assertion the phase exists for.
select is_empty(
  $$ select 1 from realtime.messages
     where topic = 'party:aaaaaaaa-0000-0000-0000-000000000001' $$,
  'LAYER 2: a non-invitee cannot join the private party topic -- not even the broadcast event reaches them'
);

-- realtime.messages ships an INSERT grant for `authenticated`, so the only
-- thing stopping a client writing straight into a topic is the deliberate
-- absence of an INSERT policy. If this ever passes, a participant can put a
-- line in front of the whole party that never passed through public.messages
-- -- no rate limit, nothing to report, nothing hide_message could take down.
select set_config('realtime.topic', 'party:aaaaaaaa-0000-0000-0000-000000000002', true);

select throws_ok(
  $$ insert into realtime.messages (topic, extension, event, private, payload)
     values ('party:aaaaaaaa-0000-0000-0000-000000000002', 'broadcast', 'new_message', true,
             '{"body":"forged"}'::jsonb) $$,
  '42501',
  null,
  'nobody can broadcast into a topic directly -- the trigger is the only writer'
);

-- The topic parser has to fail CLOSED. A looser regex would let a
-- non-castable string reach ::uuid, which raises inside the policy instead of
-- denying -- an error is not a denial.
select set_config('realtime.topic', 'party:not-a-uuid', true);

select is_empty(
  $$ select 1 from realtime.messages $$,
  'a malformed topic denies rather than errors'
);

select is(
  public.party_id_from_topic('party:not-a-uuid'),
  null,
  'party_id_from_topic returns null for a topic that is not a party topic'
);

select is(
  public.party_id_from_topic(public.party_topic('aaaaaaaa-0000-0000-0000-000000000001')),
  'aaaaaaaa-0000-0000-0000-000000000001'::uuid,
  'the topic builder and the topic parser agree -- trigger and policy cannot drift'
);


-- ============================================================
-- Keyset pagination.
--
-- Every row in this transaction shares one created_at (now() is the
-- transaction clock), which makes this the strongest form of the test: the id
-- half of the composite key is the ONLY thing producing a total order, so a
-- keyset that got it wrong would duplicate or drop a row here.
-- Visible to the invitee in party 0001, id desc: …0004, …0003, …0002, …0001.
-- ============================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

insert into public.messages (id, party_id, author_id, body) values
  ('dddddddd-0000-0000-0000-000000000003',
   'aaaaaaaa-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111',
   'page filler one'),
  ('dddddddd-0000-0000-0000-000000000004',
   'aaaaaaaa-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111',
   'page filler two');

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

select results_eq(
  $$ select id from public.get_messages('aaaaaaaa-0000-0000-0000-000000000001', null, null, 2) $$,
  $$ values ('dddddddd-0000-0000-0000-000000000004'::uuid),
            ('dddddddd-0000-0000-0000-000000000003'::uuid) $$,
  'history page 1 returns the newest N in (created_at desc, id desc) order'
);

select results_eq(
  $$ select id from public.get_messages(
       'aaaaaaaa-0000-0000-0000-000000000001',
       (select created_at from public.messages where id = 'dddddddd-0000-0000-0000-000000000003'),
       'dddddddd-0000-0000-0000-000000000003'::uuid,
       2) $$,
  $$ values ('dddddddd-0000-0000-0000-000000000002'::uuid),
            ('dddddddd-0000-0000-0000-000000000001'::uuid) $$,
  'history page 2 resumes from the cursor with no overlap and no gap'
);

select is_empty(
  $$ select 1 from public.get_messages('aaaaaaaa-0000-0000-0000-000000000001')
     where id = 'dddddddd-0000-0000-0000-000000000010' $$,
  'get_messages is scoped to one party -- it does not bleed another party''s chat in'
);


-- ============================================================
-- Read state and unread counts.
-- ============================================================
select is(
  (select unread_count from public.get_party_chats()
   where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  4,
  'with no read state at all, every message in the chat is unread'
);

-- The clamp: a client cannot future-date its way to a permanently silent
-- badge.
insert into public.party_reads (party_id, user_id, last_read_at) values
  ('aaaaaaaa-0000-0000-0000-000000000001',
   '22222222-2222-2222-2222-222222222222',
   now() + interval '10 years');

select ok(
  (select last_read_at from public.party_reads
   where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'
   and user_id = '22222222-2222-2222-2222-222222222222') <= now(),
  'a future-dated last_read_at is clamped to the server clock, not trusted'
);

select is(
  (select unread_count from public.get_party_chats()
   where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  0,
  'marking the chat read zeroes its unread count'
);

-- Monotonic: a slow second device posting a stale watermark must not
-- resurrect a badge the fast one already cleared.
update public.party_reads
set last_read_at = now() - interval '1 day'
where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'
and user_id = '22222222-2222-2222-2222-222222222222';

select is(
  (select unread_count from public.get_party_chats()
   where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  0,
  'last_read_at never moves backwards -- a stale write from a second device is ignored'
);

select throws_ok(
  $$ insert into public.party_reads (party_id, user_id, last_read_at) values
     ('aaaaaaaa-0000-0000-0000-000000000001',
      '11111111-1111-1111-1111-111111111111',
      now()) $$,
  '42501',
  null,
  'a user cannot write someone else''s read state'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is_empty(
  $$ select 1 from public.party_reads
     where user_id = '22222222-2222-2222-2222-222222222222' $$,
  'and cannot read it either -- read state is owner-only'
);


-- ============================================================
-- Immutability and moderation.
-- ============================================================
select throws_ok(
  $$ update public.messages set body = 'edited after the fact'
     where id = 'dddddddd-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'a sent message is immutable -- there is no update grant on messages'
);

-- can_moderate_message's host arm: a host can clear their own party's chat.
select public.hide_message('dddddddd-0000-0000-0000-000000000011', 'off topic');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select is_empty(
  $$ select 1 from public.messages
     where id = 'dddddddd-0000-0000-0000-000000000011' $$,
  'a party host can hide a message someone else sent in their party'
);

select throws_ok(
  $$ update public.messages set hidden_at = null
     where id = 'dddddddd-0000-0000-0000-000000000011' $$,
  '42501',
  null,
  'and the author cannot un-hide it -- there is no update grant at all'
);

select throws_ok(
  $$ select public.hide_message('dddddddd-0000-0000-0000-000000000010') $$,
  '42501',
  null,
  'someone who is neither the author nor the party host cannot hide a message'
);

select isnt_empty(
  $$ select 1 from public.messages
     where id = 'dddddddd-0000-0000-0000-000000000010' $$,
  'and the message they tried to hide is still standing'
);

-- Hidden means hidden everywhere, including in the derived numbers -- the
-- Phase 4 lesson about a counter that keeps counting a moderated row.
select is(
  (select unread_count from public.get_party_chats()
   where party_id = 'aaaaaaaa-0000-0000-0000-000000000002'),
  1,
  'a hidden message does not count toward the unread badge'
);

select is(
  (select last_message_body from public.get_party_chats()
   where party_id = 'aaaaaaaa-0000-0000-0000-000000000002'),
  'public party chat opener',
  'nor does it linger as the chat list preview'
);

-- Author arm of can_moderate_message.
select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

select public.hide_message('dddddddd-0000-0000-0000-000000000002', 'said too much');

select is_empty(
  $$ select 1 from public.messages
     where id = 'dddddddd-0000-0000-0000-000000000002' $$,
  'an author can retract their own message, and it vanishes even for them'
);


-- ============================================================
-- Blocks. can_access_party covers the HOST only, so the author-side check is
-- the one it cannot make for us -- and both directions are exercised here.
-- ============================================================
select tests.authenticate_as('55555555-5555-5555-5555-555555555555'); -- blocked_user

insert into public.rsvps (party_id, user_id, status) values
  ('aaaaaaaa-0000-0000-0000-000000000002', '55555555-5555-5555-5555-555555555555', 'going');

insert into public.messages (id, party_id, author_id, body) values
  ('dddddddd-0000-0000-0000-000000000012',
   'aaaaaaaa-0000-0000-0000-000000000002',
   '55555555-5555-5555-5555-555555555555',
   'from the soon to be blocked user'),
  -- …and a message in a party blocked_user HOSTS, so the host-side term gets
  -- its own row rather than sharing one.
  ('dddddddd-0000-0000-0000-000000000020',
   'aaaaaaaa-0000-0000-0000-000000000021',
   '55555555-5555-5555-5555-555555555555',
   'hosted by blocked_user');

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

insert into public.rsvps (party_id, user_id, status) values
  ('aaaaaaaa-0000-0000-0000-000000000021', '11111111-1111-1111-1111-111111111111', 'interested');

select isnt_empty(
  $$ select 1 from public.messages
     where id = 'dddddddd-0000-0000-0000-000000000012' $$,
  'before any block, host sees blocked_user''s message in a chat they share'
);

select isnt_empty(
  $$ select 1 from public.messages
     where id = 'dddddddd-0000-0000-0000-000000000020' $$,
  'and can chat in the party blocked_user hosts'
);

insert into public.blocks (blocker_id, blocked_id) values
  ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555');

-- The author-side term. This is the one can_access_party cannot make: the
-- party is hosted by the host themselves, so party visibility is untouched --
-- only the AUTHOR is blocked.
select is_empty(
  $$ select 1 from public.messages
     where id = 'dddddddd-0000-0000-0000-000000000012' $$,
  'after the block, a blocked user''s messages disappear from a chat they share'
);

-- The host-side term, inherited from can_access_party for free.
select is_empty(
  $$ select 1 from public.messages
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000021' $$,
  'and the whole chat of a party hosted by a blocked user disappears'
);

select is_empty(
  $$ select 1 from public.get_party_chats()
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000021' $$,
  'that party stops being listed as a chat at all'
);

-- Layer 2 has to honour the block too, or the history goes away while the
-- live feed keeps arriving.
select set_config('realtime.topic', 'party:aaaaaaaa-0000-0000-0000-000000000021', true);

select is_empty(
  $$ select 1 from realtime.messages
     where topic = 'party:aaaaaaaa-0000-0000-0000-000000000021' $$,
  'and the block reaches the broadcast topic as well, not just the history'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select isnt_empty(
  $$ select 1 from public.messages
     where id = 'dddddddd-0000-0000-0000-000000000012' $$,
  'a third party with no block still sees that message (the block does not over-reach)'
);


-- ============================================================
-- Server-side rate limit (CLAUDE.md #7). second_host is invited to party
-- 0001 and has said nothing yet, so the window starts clean here.
-- ============================================================
select tests.authenticate_as('66666666-6666-6666-6666-666666666666'); -- second_host

insert into public.messages (party_id, author_id, body)
select 'aaaaaaaa-0000-0000-0000-000000000001',
       '66666666-6666-6666-6666-666666666666',
       'flood ' || g
from generate_series(1, 20) g;

select throws_ok(
  $$ insert into public.messages (party_id, author_id, body) values
     ('aaaaaaaa-0000-0000-0000-000000000001',
      '66666666-6666-6666-6666-666666666666',
      'one too many') $$,
  '42501',
  null,
  'the rate limit trips server-side, not in the client'
);

-- Scoped per (user, party): a busy chat must not throttle a quiet one.
select ok(
  public.can_chat_in_party('aaaaaaaa-0000-0000-0000-000000000013'),
  'second_host is a participant in a second party'
);

select lives_ok(
  $$ insert into public.messages (party_id, author_id, body) values
     ('aaaaaaaa-0000-0000-0000-000000000013',
      '66666666-6666-6666-6666-666666666666',
      'still able to talk elsewhere') $$,
  'and the rate limit is per (user, party) -- one flooded chat does not gag the others'
);


-- ============================================================
-- Anonymous sessions. There is no such thing as anonymous chat, and the
-- grants say so rather than a policy silently returning nothing.
-- ============================================================
select tests.clear_authentication();

select throws_ok(
  $$ select 1 from public.messages $$,
  '42501',
  null,
  'anon has no select grant on messages at all'
);

select throws_ok(
  $$ select 1 from public.get_messages('aaaaaaaa-0000-0000-0000-000000000002') $$,
  '42501',
  null,
  'anon cannot execute get_messages'
);

select throws_ok(
  $$ select 1 from public.get_party_chats() $$,
  '42501',
  null,
  'anon cannot execute get_party_chats'
);

select * from finish();
rollback;
