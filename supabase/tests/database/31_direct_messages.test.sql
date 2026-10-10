-- Phase 33: direct messages.
--
-- What has to hold, in the order it is asserted:
--
--   A. dm_policy exists, has three values, defaults to 'everyone'.
--   B. One thread per pair, whichever side opens it, and no client path into
--      direct_threads but get_or_create_direct_thread.
--   C. Only the two members read, write, or mark read. A third user gets
--      nothing -- the row (layer 1) AND the dm:{uuid} topic (layer 2), which
--      are separate policies on separate tables, as in 06_group_chat.
--   D. dm_policy: everyone / following (in the RIGHT direction, gotcha 14) /
--      nobody -- for new threads, and re-asked on every send until the peer
--      has written in the thread.
--   E. A block overrides 'everyone': no new thread, no send in an existing
--      one, the peer's lines leave history, the topic refuses, the list drops
--      the thread -- and the refusal reads exactly like a policy refusal.
--   F. List, unread, keyset paging, hide, rate limits.
--   G. Lifecycle: deleted peers cannot be messaged, erasure keeps the lines
--      and drops the read state, export carries them.
--
-- Plus the two functions the client needed (20261010095848,
-- 20261010100148): mark_direct_thread_read in F, get_my_blocked_accounts in
-- E -- the latter's headline is the negative, that the BLOCKED side learns
-- nothing from it.
--
-- Personas (seed.sql): host 1111, invitee 2222, friend_not_invited 3333,
-- stranger 4444, blocked_user 5555, second_host 6666. Seeded follows that
-- matter here: host follows 2222/3333/6666; stranger has no edges at all.
-- Everything else is built inside this transaction.
begin;
set search_path to public, extensions;
select plan(86);

-- Thread ids come back from the RPC, so they are parked here. Created as
-- postgres and granted out, so every persona can read the names back.
create temp table dm_ids (name text primary key, id uuid);
grant all on dm_ids to authenticated, anon;


-- ============================================================
-- A. dm_policy
-- ============================================================
select is(
  (select enum_range(null::public.dm_policy)::text[]),
  array['everyone', 'following', 'nobody'],
  'dm_policy has exactly three values'
);

select is(
  (select dm_policy::text from public.profiles where id = '44444444-4444-4444-4444-444444444444'),
  'everyone',
  'dm_policy defaults to everyone'
);


-- ============================================================
-- B. One thread per pair
-- ============================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select lives_ok(
  $$ insert into dm_ids values
       ('t1', public.get_or_create_direct_thread('22222222-2222-2222-2222-222222222222')) $$,
  'get_or_create_direct_thread opens a thread with a user whose dm_policy is everyone'
);

select is(
  public.get_or_create_direct_thread('22222222-2222-2222-2222-222222222222'),
  (select id from dm_ids where name = 't1'),
  'opening it again returns the same thread'
);

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

select is(
  public.get_or_create_direct_thread('11111111-1111-1111-1111-111111111111'),
  (select id from dm_ids where name = 't1'),
  'the OTHER member opening it gets the same thread too -- A->B and B->A are one key'
);

reset role;
select is(
  (select count(*)::int from public.direct_threads
   where user_low = '11111111-1111-1111-1111-111111111111'
     and user_high = '22222222-2222-2222-2222-222222222222'),
  1,
  'exactly one row exists for the pair'
);

select throws_ok(
  $$ insert into public.direct_threads (user_low, user_high, created_by) values
       ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111',
        '22222222-2222-2222-2222-222222222222') $$,
  '23514',
  null,
  'an unordered pair is unrepresentable, even for postgres -- the check is what makes the key canonical'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select throws_ok(
  $$ select public.get_or_create_direct_thread('11111111-1111-1111-1111-111111111111') $$,
  '42501',
  'cannot message this user',
  'a thread with yourself is refused'
);

select throws_ok(
  $$ select public.get_or_create_direct_thread('99999999-0000-0000-0000-000000000000') $$,
  '42501',
  'cannot message this user',
  'an unknown user id is refused with the same text'
);

-- An account still on the username screen (20261010102726). Without this, a
-- stranger's empty thread would hold a NO ACTION reference to the profile and
-- make that account's abandon_signup fail with 23503 -- permanently, for a
-- reason it cannot see.
reset role;
insert into public.profiles (id, username) values
  ('99999999-0000-0000-0000-00000000aaaa', 'half_signed_up');
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select throws_ok(
  $$ select public.get_or_create_direct_thread('99999999-0000-0000-0000-00000000aaaa') $$,
  '42501',
  'cannot message this user',
  'an account that has not finished onboarding cannot be messaged -- same refusal text'
);

select throws_ok(
  $$ insert into public.direct_threads (user_low, user_high, created_by) values
       ('11111111-1111-1111-1111-111111111111', '44444444-4444-4444-4444-444444444444',
        '11111111-1111-1111-1111-111111111111') $$,
  '42501',
  null,
  'a client cannot insert into direct_threads -- the RPC is the only door'
);

select tests.clear_authentication();

select throws_ok(
  $$ select public.get_or_create_direct_thread('22222222-2222-2222-2222-222222222222') $$,
  '42501',
  null,
  'anon cannot open a thread'
);

select throws_ok(
  $$ select * from public.get_direct_chats() $$,
  '42501',
  null,
  'anon cannot list threads'
);

select throws_ok(
  $$ select public.mark_direct_thread_read('aaaaaaaa-0000-0000-0000-000000000001') $$,
  '42501',
  null,
  'anon cannot mark a thread read'
);

select throws_ok(
  $$ select * from public.get_my_blocked_accounts() $$,
  '42501',
  null,
  'anon cannot list blocks'
);


-- ============================================================
-- C. Membership: layer 1 (rows) and layer 2 (topic)
-- ============================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select lives_ok(
  $$ insert into public.direct_messages (id, thread_id, author_id, body) values
       ('eeeeeeee-0000-0000-0000-000000000001', (select id from dm_ids where name = 't1'),
        '11111111-1111-1111-1111-111111111111', 'hey, coming saturday?') $$,
  'a member can send in their thread'
);

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

select is(
  (select body from public.get_direct_messages((select id from dm_ids where name = 't1'))),
  'hey, coming saturday?',
  'the other member reads it through get_direct_messages'
);

select lives_ok(
  $$ insert into public.direct_messages (id, thread_id, author_id, body) values
       ('eeeeeeee-0000-0000-0000-000000000002', (select id from dm_ids where name = 't1'),
        '22222222-2222-2222-2222-222222222222', 'yes!') $$,
  'and replies'
);

select throws_ok(
  $$ insert into public.direct_messages (thread_id, author_id, body) values
       ((select id from dm_ids where name = 't1'), '11111111-1111-1111-1111-111111111111', 'forged') $$,
  '42501',
  null,
  'a member cannot write a line under the other member''s name'
);

select throws_ok(
  $$ insert into public.direct_messages (thread_id, author_id, body, created_at) values
       ((select id from dm_ids where name = 't1'), '22222222-2222-2222-2222-222222222222', 'x', now() + interval '1 year') $$,
  '42501',
  null,
  'created_at is not client-writable -- the column grant, not a policy'
);

select throws_ok(
  $$ update public.direct_messages set body = 'edited'
     where id = 'eeeeeeee-0000-0000-0000-000000000002' $$,
  '42501',
  null,
  'a sent DM cannot be edited -- no UPDATE grant'
);

select set_config('realtime.topic', 'dm:' || (select id from dm_ids where name = 't1'), true);

select isnt_empty(
  $$ select 1 from realtime.messages
     where topic = 'dm:' || (select id from dm_ids where name = 't1') and event = 'new_message' $$,
  'LAYER 2: the insert trigger broadcast to dm:{thread_id}, and a member may join that topic'
);

select is(
  (select payload->>'author_username' from realtime.messages
   where payload->>'id' = 'eeeeeeee-0000-0000-0000-000000000001'),
  'host',
  'the DM broadcast payload carries the author username'
);

select throws_ok(
  $$ insert into realtime.messages (topic, extension, event, private, payload)
     values ('dm:' || (select id from dm_ids where name = 't1'), 'broadcast', 'new_message', true,
             '{"body":"forged"}'::jsonb) $$,
  '42501',
  null,
  'even a member cannot broadcast into a dm topic directly -- the trigger is the only writer'
);

select tests.authenticate_as('33333333-3333-3333-3333-333333333333'); -- a third user

select is_empty(
  $$ select 1 from public.direct_threads where id = (select id from dm_ids where name = 't1') $$,
  'a third user cannot see the thread row'
);

select is_empty(
  $$ select 1 from public.direct_messages where thread_id = (select id from dm_ids where name = 't1') $$,
  'LAYER 1: a third user cannot read the messages'
);

select is_empty(
  $$ select 1 from public.get_direct_messages((select id from dm_ids where name = 't1')) $$,
  'nor through get_direct_messages'
);

select throws_ok(
  $$ insert into public.direct_messages (thread_id, author_id, body) values
       ((select id from dm_ids where name = 't1'), '33333333-3333-3333-3333-333333333333', 'can I join') $$,
  '42501',
  null,
  'a third user cannot post into the thread'
);

select throws_ok(
  $$ insert into public.direct_reads (thread_id, user_id) values
       ((select id from dm_ids where name = 't1'), '33333333-3333-3333-3333-333333333333') $$,
  '42501',
  null,
  'a third user cannot create read state on a thread they are not in'
);

select set_config('realtime.topic', 'dm:' || (select id from dm_ids where name = 't1'), true);

select is_empty(
  $$ select 1 from realtime.messages
     where topic = 'dm:' || (select id from dm_ids where name = 't1') $$,
  'LAYER 2: a third user cannot join the dm topic -- not even the event reaches them'
);

select set_config('realtime.topic', 'dm:not-a-uuid', true);
select is_empty($$ select 1 from realtime.messages $$, 'a malformed dm topic denies rather than errors');

select is(
  public.direct_thread_id_from_topic(public.direct_thread_topic('aaaaaaaa-0000-0000-0000-000000000001')),
  'aaaaaaaa-0000-0000-0000-000000000001'::uuid,
  'the dm topic builder and parser agree'
);

select is(
  public.party_id_from_topic('dm:aaaaaaaa-0000-0000-0000-000000000001'),
  null,
  'a dm topic does not parse as a party topic -- the two realtime policies cannot admit each other''s channels'
);


-- ============================================================
-- D. dm_policy: following and nobody
--
-- stranger (4444) is the recipient throughout: no seeded edges, so every
-- follow below is one this test made.
-- ============================================================
select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger
update public.profiles set dm_policy = 'following' where id = '44444444-4444-4444-4444-444444444444';

select tests.authenticate_as('33333333-3333-3333-3333-333333333333');

select throws_ok(
  $$ select public.get_or_create_direct_thread('44444444-4444-4444-4444-444444444444') $$,
  '42501',
  'cannot message this user',
  'following: someone the recipient does not follow cannot start a thread'
);

-- gotcha 14: the edge that DOESN'T count. 2222 follows the stranger; the
-- stranger does not follow back.
select tests.authenticate_as('22222222-2222-2222-2222-222222222222');
insert into public.follows (follower_id, followee_id)
values ('22222222-2222-2222-2222-222222222222', '44444444-4444-4444-4444-444444444444');

select throws_ok(
  $$ select public.get_or_create_direct_thread('44444444-4444-4444-4444-444444444444') $$,
  '42501',
  'cannot message this user',
  'following: FOLLOWING the recipient does not count -- it is who THEY follow (gotcha 14)'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444');
insert into public.follows (follower_id, followee_id)
values ('44444444-4444-4444-4444-444444444444', '33333333-3333-3333-3333-333333333333');

select tests.authenticate_as('33333333-3333-3333-3333-333333333333');

select lives_ok(
  $$ insert into dm_ids values
       ('t2', public.get_or_create_direct_thread('44444444-4444-4444-4444-444444444444')) $$,
  'following: someone the recipient follows can start a thread'
);

select lives_ok(
  $$ insert into public.direct_messages (thread_id, author_id, body) values
       ((select id from dm_ids where name = 't2'), '33333333-3333-3333-3333-333333333333', 'hi stranger') $$,
  'and send in it'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444');
delete from public.follows
where follower_id = '44444444-4444-4444-4444-444444444444'
  and followee_id = '33333333-3333-3333-3333-333333333333';

select tests.authenticate_as('33333333-3333-3333-3333-333333333333');

select throws_ok(
  $$ insert into public.direct_messages (thread_id, author_id, body) values
       ((select id from dm_ids where name = 't2'), '33333333-3333-3333-3333-333333333333', 'still there?') $$,
  '42501',
  null,
  'the policy is re-asked on SEND: once unfollowed, a thread the recipient never wrote in is closed'
);

select is(
  public.get_or_create_direct_thread('44444444-4444-4444-4444-444444444444'),
  (select id from dm_ids where name = 't2'),
  'the existing thread still OPENS -- your own history is yours to read'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444');

select lives_ok(
  $$ insert into public.direct_messages (thread_id, author_id, body) values
       ((select id from dm_ids where name = 't2'), '44444444-4444-4444-4444-444444444444', 'hi back') $$,
  'the recipient can reply -- the sender''s own policy is everyone'
);

update public.profiles set dm_policy = 'nobody' where id = '44444444-4444-4444-4444-444444444444';

select tests.authenticate_as('33333333-3333-3333-3333-333333333333');

select lives_ok(
  $$ insert into public.direct_messages (thread_id, author_id, body) values
       ((select id from dm_ids where name = 't2'), '33333333-3333-3333-3333-333333333333', 'great') $$,
  'nobody: a thread the recipient has written in stays open -- the policy gates strangers, not conversations'
);

select tests.authenticate_as('66666666-6666-6666-6666-666666666666');

select throws_ok(
  $$ select public.get_or_create_direct_thread('44444444-4444-4444-4444-444444444444') $$,
  '42501',
  'cannot message this user',
  'nobody: nobody can start a new thread'
);

select tests.authenticate_as('22222222-2222-2222-2222-222222222222');

select throws_ok(
  $$ select public.get_or_create_direct_thread('44444444-4444-4444-4444-444444444444') $$,
  '42501',
  'cannot message this user',
  'nobody: not even a follower'
);


-- ============================================================
-- E. A block overrides 'everyone'
-- ============================================================

-- On a thread that already exists and has history on both sides (t1).
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host
insert into public.blocks (blocker_id, blocked_id)
values ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222');

select ok(
  (select dm_policy = 'everyone' from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'CONTROL: the blocker''s dm_policy is still everyone'
);

select throws_ok(
  $$ insert into public.direct_messages (thread_id, author_id, body) values
       ((select id from dm_ids where name = 't1'), '11111111-1111-1111-1111-111111111111', 'after block') $$,
  '42501',
  null,
  'block: the blocker cannot send in the existing thread'
);

select is_empty(
  $$ select 1 from public.direct_messages
     where thread_id = (select id from dm_ids where name = 't1')
       and author_id = '22222222-2222-2222-2222-222222222222' $$,
  'block: the blocked user''s lines leave the blocker''s history'
);

select isnt_empty(
  $$ select 1 from public.direct_messages
     where thread_id = (select id from dm_ids where name = 't1')
       and author_id = '11111111-1111-1111-1111-111111111111' $$,
  'but the blocker''s own lines stay readable to them'
);

select is_empty(
  $$ select 1 from public.get_direct_chats() where thread_id = (select id from dm_ids where name = 't1') $$,
  'block: the thread drops out of the blocker''s list'
);

-- The undo has to be reachable. The profiles policy now hides the blocked
-- account from the blocker too -- asserted first, as the CONTROL that makes
-- the next assertion mean something (a definer read of a row the caller could
-- see anyway proves nothing).
select is_empty(
  $$ select 1 from public.profiles where id = '22222222-2222-2222-2222-222222222222' $$,
  'CONTROL: once blocked, the account is hidden from the blocker by the profiles policy'
);

select is(
  (select username from public.get_my_blocked_accounts()
   where user_id = '22222222-2222-2222-2222-222222222222'),
  'invitee',
  'get_my_blocked_accounts still names the account the caller blocked -- the only way back to Unblock'
);

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- the blocked side

select is_empty(
  $$ select 1 from public.get_my_blocked_accounts() $$,
  'the BLOCKED side learns nothing from it -- it lists blocks you made, never who blocked you'
);

select throws_ok(
  $$ insert into public.direct_messages (thread_id, author_id, body) values
       ((select id from dm_ids where name = 't1'), '22222222-2222-2222-2222-222222222222', 'hello?') $$,
  '42501',
  null,
  'block: the BLOCKED user cannot send either -- the block is symmetric'
);

select throws_ok(
  $$ select public.get_or_create_direct_thread('11111111-1111-1111-1111-111111111111') $$,
  '42501',
  'cannot message this user',
  'block: reopening the thread is refused with the same text a dm_policy refusal uses -- no block oracle'
);

select is_empty(
  $$ select 1 from public.direct_messages
     where thread_id = (select id from dm_ids where name = 't1')
       and author_id = '11111111-1111-1111-1111-111111111111' $$,
  'block: the blocker''s lines leave the blocked user''s history too'
);

select set_config('realtime.topic', 'dm:' || (select id from dm_ids where name = 't1'), true);

select is_empty(
  $$ select 1 from realtime.messages
     where topic = 'dm:' || (select id from dm_ids where name = 't1') $$,
  'block: the dm topic refuses the join for a thread that existed before the block'
);

-- A brand-new pair, both 'everyone', blocked before anyone wrote.
select tests.authenticate_as('66666666-6666-6666-6666-666666666666');
insert into public.blocks (blocker_id, blocked_id)
values ('66666666-6666-6666-6666-666666666666', '55555555-5555-5555-5555-555555555555');

select tests.authenticate_as('55555555-5555-5555-5555-555555555555');

select throws_ok(
  $$ select public.get_or_create_direct_thread('66666666-6666-6666-6666-666666666666') $$,
  '42501',
  'cannot message this user',
  'block overrides everyone: the blocked user cannot start a thread with the blocker'
);

select tests.authenticate_as('66666666-6666-6666-6666-666666666666');

select throws_ok(
  $$ select public.get_or_create_direct_thread('55555555-5555-5555-5555-555555555555') $$,
  '42501',
  'cannot message this user',
  'block overrides everyone: nor can the blocker start one with them'
);

-- Unblocking restores the thread. Asserted so nobody "fixes" the block by
-- hiding rows for good -- a block is a state, not a deletion.
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');
delete from public.blocks
where blocker_id = '11111111-1111-1111-1111-111111111111'
  and blocked_id = '22222222-2222-2222-2222-222222222222';

select lives_ok(
  $$ insert into public.direct_messages (id, thread_id, author_id, body) values
       ('eeeeeeee-0000-0000-0000-000000000003', (select id from dm_ids where name = 't1'),
        '11111111-1111-1111-1111-111111111111', 'sorry, unblocked') $$,
  'unblocking restores sending'
);


-- ============================================================
-- F. List, unread, paging, hide, rate limits
-- ============================================================

-- host opens a thread with second_host and writes nothing.
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');
insert into dm_ids values
  ('t3', public.get_or_create_direct_thread('66666666-6666-6666-6666-666666666666'));

select is_empty(
  $$ select 1 from public.get_direct_chats() where thread_id = (select id from dm_ids where name = 't3') $$,
  'a thread nobody has written in is not listed -- tapping Message and backing out leaves nothing'
);

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

select is(
  (select unread_count from public.get_direct_chats() where thread_id = (select id from dm_ids where name = 't1')),
  2,
  'unread counts the peer''s two lines and not my own reply'
);

select is(
  (select peer_username from public.get_direct_chats() where thread_id = (select id from dm_ids where name = 't1')),
  'host',
  'the list names the peer'
);

select lives_ok(
  $$ select public.mark_direct_thread_read((select id from dm_ids where name = 't1')) $$,
  'a member marks the thread read through mark_direct_thread_read'
);

-- The second call is the one a PostgREST upsert can never make: it reaches
-- ON CONFLICT DO UPDATE, and only last_read_at may be updated (gotcha 12).
select lives_ok(
  $$ select public.mark_direct_thread_read((select id from dm_ids where name = 't1')) $$,
  'and again -- the conflict path, which only touches last_read_at'
);

select is(
  (select unread_count from public.get_direct_chats() where thread_id = (select id from dm_ids where name = 't1')),
  0,
  'and the badge clears'
);

select tests.authenticate_as('33333333-3333-3333-3333-333333333333');

select throws_ok(
  $$ select public.mark_direct_thread_read((select id from dm_ids where name = 't1')) $$,
  '42501',
  null,
  'a non-member cannot create read state through the function either -- it is invoker, the policy decides'
);

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

-- Keyset. All three t1 lines share now(), so the id is the tiebreak.
select results_eq(
  $$ select id from public.get_direct_messages((select id from dm_ids where name = 't1'), null, null, 2) $$,
  $$ values ('eeeeeeee-0000-0000-0000-000000000003'::uuid), ('eeeeeeee-0000-0000-0000-000000000002'::uuid) $$,
  'get_direct_messages: newest first, limited'
);

select results_eq(
  $$ select id from public.get_direct_messages((select id from dm_ids where name = 't1'),
                                               now(), 'eeeeeeee-0000-0000-0000-000000000002', 2) $$,
  $$ values ('eeeeeeee-0000-0000-0000-000000000001'::uuid) $$,
  'get_direct_messages: the cursor continues strictly after the last row drawn'
);

-- Hiding: author only.
select throws_ok(
  $$ select public.hide_direct_message('eeeeeeee-0000-0000-0000-000000000001') $$,
  '42501',
  null,
  'the recipient cannot hide the sender''s line -- a DM has no host'
);

select lives_ok(
  $$ select public.hide_direct_message('eeeeeeee-0000-0000-0000-000000000002', 'typo') $$,
  'the author can hide their own line'
);

select is_empty(
  $$ select 1 from public.direct_messages where id = 'eeeeeeee-0000-0000-0000-000000000002' $$,
  'and it leaves the SELECT policy for its author'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111');

select is_empty(
  $$ select 1 from public.direct_messages where id = 'eeeeeeee-0000-0000-0000-000000000002' $$,
  'and for the other member'
);

-- List keyset: host now has t1 (and t3, empty, unlisted). Give them a
-- second listed thread, then page through one at a time.
insert into public.direct_messages (thread_id, author_id, body)
values ((select id from dm_ids where name = 't3'), '11111111-1111-1111-1111-111111111111', 'yo');

select is(
  (select count(*)::int from public.get_direct_chats(null, null, 1)),
  1,
  'get_direct_chats honours p_limit'
);

select is(
  (select count(*)::int from (
     select c2.thread_id
     from public.get_direct_chats(null, null, 1) c1
     cross join lateral public.get_direct_chats(c1.activity_at, c1.thread_id, 10) c2
   ) x),
  1,
  'get_direct_chats: the cursor yields the remaining thread and only it'
);

-- Message rate limit: 20 per 10s per thread, in one statement (gotcha 18).
select throws_like(
  $$ insert into public.direct_messages (thread_id, author_id, body)
     select (select id from dm_ids where name = 't3'), '11111111-1111-1111-1111-111111111111', 'spam ' || g
     from generate_series(1, 25) g $$,
  '%rate limit exceeded%',
  'the DM rate limit trips inside a single multi-row insert'
);

-- Thread-creation rate limit: 30 an hour.
reset role;
insert into public.profiles (id, username, onboarding_completed_at)
select ('99999999-9999-9999-9999-' || lpad((800000 + g)::text, 12, '0'))::uuid, 'dm_target_' || g, now()
from generate_series(1, 31) g;

select tests.authenticate_as('33333333-3333-3333-3333-333333333333');

-- t2 already counts as one of 3333's creations this hour.
select lives_ok(
  $$ select public.get_or_create_direct_thread(('99999999-9999-9999-9999-' || lpad((800000 + g)::text, 12, '0'))::uuid)
     from generate_series(1, 29) g $$,
  'thirty new threads in an hour are allowed'
);

select throws_like(
  $$ select public.get_or_create_direct_thread('99999999-9999-9999-9999-000000800030') $$,
  '%rate limit exceeded%',
  'the thirty-first is refused'
);

select lives_ok(
  $$ select public.get_or_create_direct_thread('99999999-9999-9999-9999-000000800001') $$,
  'reopening an existing thread is not rate limited'
);


-- ============================================================
-- G. Lifecycle
-- ============================================================
reset role;
select is(
  (select case c.confdeltype when 'a' then 'no action' else c.confdeltype::text end
   from pg_constraint c where c.conname = 'direct_messages_author_id_fkey'),
  'no action',
  'direct_messages.author_id must not cascade -- the other member''s conversation survives an erasure'
);

select is(
  (select case c.confdeltype when 'a' then 'no action' else c.confdeltype::text end
   from pg_constraint c where c.conname = 'direct_threads_user_low_fkey'),
  'no action',
  'direct_threads members must not cascade either'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111');

select ok(
  public.export_account_data() -> 'direct_messages' @> jsonb_build_array(jsonb_build_object('body', 'sorry, unblocked')),
  'export_account_data carries the DMs the caller wrote'
);

select is(
  public.export_account_data() -> 'profile' ->> 'dm_policy',
  'everyone',
  'and dm_policy in the profile block'
);

-- 4444 (dm_policy nobody, has written in t2) requests deletion.
select tests.authenticate_as('44444444-4444-4444-4444-444444444444');
insert into public.direct_reads (thread_id, user_id)
values ((select id from dm_ids where name = 't2'), '44444444-4444-4444-4444-444444444444');
select public.request_account_deletion();

select tests.authenticate_as('33333333-3333-3333-3333-333333333333');

select throws_ok(
  $$ insert into public.direct_messages (thread_id, author_id, body) values
       ((select id from dm_ids where name = 't2'), '33333333-3333-3333-3333-333333333333', 'you there?') $$,
  '42501',
  null,
  'a peer pending deletion is not a recipient, even in a thread they wrote in'
);

reset role;
update public.profiles set deleted_at = now() - interval '31 days'
where id = '44444444-4444-4444-4444-444444444444';

select lives_ok(
  $$ select public.complete_account_erasure('44444444-4444-4444-4444-444444444444') $$,
  'complete_account_erasure runs with DM rows present (gotcha 15)'
);

select is_empty(
  $$ select 1 from public.direct_reads where user_id = '44444444-4444-4444-4444-444444444444' $$,
  'erasure deletes the erased user''s read state'
);

select isnt_empty(
  $$ select 1 from public.direct_messages where author_id = '44444444-4444-4444-4444-444444444444' $$,
  'and keeps their lines, under the tombstone'
);

select tests.authenticate_as('33333333-3333-3333-3333-333333333333');

select is(
  (select author_username from public.get_direct_messages((select id from dm_ids where name = 't2'))
   where author_id = '44444444-4444-4444-4444-444444444444'),
  'deleted_44444444444444444444444444444444',
  'the surviving member still sees the conversation, attributed to the tombstone'
);

select * from finish();
rollback;
