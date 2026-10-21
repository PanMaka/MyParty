-- Phase 34b: the inbox:{user_uuid} topic (20261011125542).
--
-- What has to hold:
--
--   A. A DM line puts one dm_activity row on each member's inbox, carrying
--      the thread id and NOTHING else -- the client refetches through RLS.
--   B. Only you may join your inbox. Another user, anon, a malformed topic:
--      nothing. This is the fail-closed half, and the reason the file exists.
--   C. The three realtime policies cannot admit each other's channels: each
--      parser accepts only its own prefix.
--   D. Nobody can write into an inbox directly; the trigger is the only writer.
--   E. A hide is news too, but not to a member who has a block with the
--      author.
--
-- Personas (seed.sql): host 1111, invitee 2222, stranger 4444. dm_policy
-- defaults to 'everyone', so host may open a thread with invitee.
begin;
set search_path to public, extensions;
select plan(23);

create temp table inbox_ids (name text primary key, id uuid);
grant all on inbox_ids to authenticated, anon;

-- Counts every dm_activity row on an inbox as postgres, so the policy under
-- test is not also the thing doing the counting (gotcha 17).
create function pg_temp.inbox_rows(p_user uuid) returns bigint
language sql security definer set search_path = '' as $$
  select count(*) from realtime.messages
  where topic = public.inbox_topic(p_user) and event = 'dm_activity';
$$;
grant execute on function pg_temp.inbox_rows(uuid) to authenticated, anon;


-- ============================================================
-- A. A line reaches both inboxes, as a signal
-- ============================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

insert into inbox_ids
select 't', public.get_or_create_direct_thread('22222222-2222-2222-2222-222222222222');

select lives_ok(
  $$ insert into public.direct_messages (id, thread_id, author_id, body) values
       ('fafafafa-0000-0000-0000-000000000001', (select id from inbox_ids where name = 't'),
        '11111111-1111-1111-1111-111111111111', 'first line'),
       ('fafafafa-0000-0000-0000-000000000002', (select id from inbox_ids where name = 't'),
        '11111111-1111-1111-1111-111111111111', 'second line') $$,
  'a member writes two lines into a new thread'
);

select is(pg_temp.inbox_rows('22222222-2222-2222-2222-222222222222'), 2::bigint,
  'the peer''s inbox gets one dm_activity per line -- including the FIRST line of a thread they hold no topic for');

select is(pg_temp.inbox_rows('11111111-1111-1111-1111-111111111111'), 2::bigint,
  'the author''s own inbox gets them too, for their other devices');

select is(pg_temp.inbox_rows('44444444-4444-4444-4444-444444444444'), 0::bigint,
  'nobody outside the thread is signalled');

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee
select set_config('realtime.topic', 'inbox:22222222-2222-2222-2222-222222222222', true);

select isnt_empty(
  $$ select 1 from realtime.messages
     where topic = 'inbox:22222222-2222-2222-2222-222222222222' and event = 'dm_activity' $$,
  'the peer may join their own inbox and sees the signal'
);

-- realtime.send stamps an 'id' of its own onto every payload that lacks one
-- (a fresh gen_random_uuid(), the broadcast's id). That is the envelope, not
-- the message, so it is set aside here and then checked to be exactly that.
select is(
  (select array_agg(k order by k) from realtime.messages m, jsonb_object_keys(m.payload - 'id') k
   where m.topic = 'inbox:22222222-2222-2222-2222-222222222222' and m.event = 'dm_activity'
     and m.payload->>'thread_id' = (select id::text from inbox_ids where name = 't')
   group by m.id limit 1),
  array['thread_id'],
  'the payload is the thread id and nothing else -- no body, no author, no username'
);

select is_empty(
  $$ select 1 from realtime.messages m
     where m.topic = 'inbox:22222222-2222-2222-2222-222222222222'
       and m.payload->>'id' in ('fafafafa-0000-0000-0000-000000000001', 'fafafafa-0000-0000-0000-000000000002') $$,
  'the only id on the payload is the broadcast''s own, never the message''s'
);


-- ============================================================
-- B. Only you may join your inbox
-- ============================================================
select set_config('realtime.topic', 'inbox:11111111-1111-1111-1111-111111111111', true);
select is_empty(
  $$ select 1 from realtime.messages where topic = 'inbox:11111111-1111-1111-1111-111111111111' $$,
  'a member of the same thread still cannot join the OTHER member''s inbox'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger
select set_config('realtime.topic', 'inbox:22222222-2222-2222-2222-222222222222', true);
select is_empty(
  $$ select 1 from realtime.messages where topic = 'inbox:22222222-2222-2222-2222-222222222222' $$,
  'a stranger cannot join someone else''s inbox'
);

select set_config('realtime.topic', 'inbox:not-a-uuid', true);
select is_empty($$ select 1 from realtime.messages $$, 'a malformed inbox topic denies rather than errors');

select set_config('realtime.topic', 'inbox:44444444-4444-4444-4444-444444444444-extra', true);
select is_empty($$ select 1 from realtime.messages $$, 'a topic with trailing junk after the uuid denies');

select tests.clear_authentication();
select set_config('realtime.topic', 'inbox:22222222-2222-2222-2222-222222222222', true);
select is_empty(
  $$ select 1 from realtime.messages where topic = 'inbox:22222222-2222-2222-2222-222222222222' $$,
  'anon joins no inbox'
);


-- ============================================================
-- C. The parsers, and the three policies' prefixes
-- ============================================================
-- As a signed-in user: since Phase 46 anon executes none of them, and the
-- policies that call them run as authenticated.
select tests.authenticate_as('22222222-2222-2222-2222-222222222222');
select is(
  public.inbox_user_id_from_topic(public.inbox_topic('22222222-2222-2222-2222-222222222222')),
  '22222222-2222-2222-2222-222222222222'::uuid,
  'the inbox topic builder and parser agree'
);

select is(public.inbox_user_id_from_topic('inbox:not-a-uuid'), null, 'a malformed inbox topic parses to NULL');

select is(
  public.inbox_user_id_from_topic('dm:22222222-2222-2222-2222-222222222222'),
  null,
  'a dm topic is not an inbox -- the inbox policy cannot admit a thread channel'
);

select is(
  public.inbox_user_id_from_topic('party:22222222-2222-2222-2222-222222222222'),
  null,
  'a party topic is not an inbox -- the inbox policy cannot admit a party channel'
);

select is(
  public.direct_thread_id_from_topic('inbox:22222222-2222-2222-2222-222222222222'),
  null,
  'an inbox topic is not a dm thread -- the dm policy cannot admit an inbox'
);

select is(
  public.party_id_from_topic('inbox:22222222-2222-2222-2222-222222222222'),
  null,
  'an inbox topic is not a party -- the party policy cannot admit an inbox'
);


-- ============================================================
-- D. The trigger is the only writer
-- ============================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host
select throws_ok(
  $$ insert into realtime.messages (topic, extension, event, private, payload)
     values ('inbox:22222222-2222-2222-2222-222222222222', 'broadcast', 'dm_activity', true,
             '{"thread_id":"forged"}'::jsonb) $$,
  '42501',
  null,
  'nobody can push a fake signal into another user''s inbox'
);


-- ============================================================
-- E. Hides are news, except to a member with a block
-- ============================================================
select lives_ok(
  $$ select public.hide_direct_message('fafafafa-0000-0000-0000-000000000001', null) $$,
  'the author hides a line'
);

select is(pg_temp.inbox_rows('22222222-2222-2222-2222-222222222222'), 3::bigint,
  'the hide signals the peer -- their preview may have been that line');

-- The invitee blocks the host. Hiding stays author-only and is not
-- block-gated, so the host can still take a line down.
select tests.authenticate_as('22222222-2222-2222-2222-222222222222');
insert into public.blocks (blocker_id, blocked_id)
values ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111');

select tests.authenticate_as('11111111-1111-1111-1111-111111111111');
select public.hide_direct_message('fafafafa-0000-0000-0000-000000000002', null);

select is(pg_temp.inbox_rows('22222222-2222-2222-2222-222222222222'), 3::bigint,
  'a member who blocked the author is not signalled -- no news about someone they stopped hearing from');

select is(pg_temp.inbox_rows('11111111-1111-1111-1111-111111111111'), 4::bigint,
  'the author''s own inbox still is');

select * from finish();
rollback;
