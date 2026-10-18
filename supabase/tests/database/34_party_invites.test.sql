-- Phase 40: inviting followers, invite links, and removing a guest
-- (20261014133500).
--
-- What has to hold:
--
--   A. Shape: the new tables are RLS-on with no client grants; no column
--      stores a raw token; the client may insert only (party_id, guest_id)
--      into invitations.
--   B. Inviting followers: host-only, the picker lists followers in the right
--      direction minus block-paired ones, and invite_to_party drops exactly
--      who create_party_with_invites drops -- plus the host.
--   C. Invite links: host-only and private-only; a stranger who redeems one
--      gains an invitation and therefore the party; every refusal is the SAME
--      message; max uses, regenerate, disable, cancelled and ended all refuse;
--      the per-user rate limit holds.
--   D. Removing a guest: invitation, rsvp, counters and history move together;
--      the removed person loses the party, its chat AND its realtime topic; a
--      still-active link cannot bring them back; a direct invite can; export
--      and erasure carry the record.
--
-- Personas: host 1111, invitee 2222, friend_not_invited 3333, stranger 4444,
-- second_host 6666; crowd 0c0c...01-04.
begin;
set search_path to public, extensions;
select plan(73);


-- ===========================================================================
-- Fixtures (as postgres)
-- ===========================================================================
--   X  ffff...0001  private, host 1111, in 2 days
--   Y  ffff...0002  public,  host 1111, in 2 days
--   Z  ffff...0003  private, host 1111, CANCELLED
--   W  ffff...0004  private, host 1111, ENDED
--   V  ffff...0005  private, host 1111, in 2 days (cancelled mid-test)
insert into public.parties (id, host_id, title, location, starts_at, ends_at, is_private, status) values
  ('ffffffff-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Invite X',
   st_point(23.73, 37.97)::geography, now() + interval '2 days', null, true, 'published'),
  ('ffffffff-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Invite Y',
   st_point(23.73, 37.97)::geography, now() + interval '2 days', null, false, 'published'),
  ('ffffffff-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111', 'Invite Z',
   st_point(23.73, 37.97)::geography, now() + interval '2 days', null, true, 'cancelled'),
  ('ffffffff-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111', 'Invite W',
   st_point(23.73, 37.97)::geography, now() - interval '2 days', now() - interval '1 day', true, 'published'),
  ('ffffffff-0000-0000-0000-000000000005', '11111111-1111-1111-1111-111111111111', 'Invite V',
   st_point(23.73, 37.97)::geography, now() + interval '2 days', null, true, 'published');

-- Followers of the host: c1, c2, c3. c4 follows nobody and only accepts
-- invites from people they follow. The host has blocked c3.
delete from public.follows
where followee_id = '11111111-1111-1111-1111-111111111111'
   or follower_id = '11111111-1111-1111-1111-111111111111';
insert into public.follows (follower_id, followee_id) values
  ('0c0c0c0c-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111'),
  ('0c0c0c0c-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111'),
  ('0c0c0c0c-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111'),
  -- The wrong direction: the host follows c4. That does not make c4 a follower.
  ('11111111-1111-1111-1111-111111111111', '0c0c0c0c-0000-0000-0000-000000000004');
update public.profiles set invite_policy = 'following' where id = '0c0c0c0c-0000-0000-0000-000000000004';
insert into public.blocks (blocker_id, blocked_id)
values ('11111111-1111-1111-1111-111111111111', '0c0c0c0c-0000-0000-0000-000000000003');

-- c2 is already invited to X.
insert into public.invitations (party_id, guest_id)
values ('ffffffff-0000-0000-0000-000000000001', '0c0c0c0c-0000-0000-0000-000000000002');

create temp table tokens (name text primary key, token text) on commit drop;
grant all on tokens to authenticated, anon;


-- ===========================================================================
-- A. Shape
-- ===========================================================================
select ok(
  (select relrowsecurity from pg_class where oid = 'public.party_invite_links'::regclass)
  and (select relrowsecurity from pg_class where oid = 'public.party_guest_removals'::regclass),
  'both new tables have RLS on'
);

select ok(
  not has_table_privilege('authenticated', 'public.party_invite_links', 'select')
  and not has_table_privilege('authenticated', 'public.party_invite_links', 'insert')
  and not has_table_privilege('authenticated', 'public.party_guest_removals', 'select')
  and not has_table_privilege('authenticated', 'public.party_guest_removals', 'insert')
  and not has_table_privilege('anon', 'public.party_invite_links', 'select'),
  'no client role holds any privilege on either table -- the functions are the only door'
);

select is_empty(
  $$ select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'party_invite_links'
       and column_name ~ 'token' and column_name <> 'token_hash' $$,
  'no column stores a raw token -- only its sha256'
);

select ok(
  has_column_privilege('authenticated', 'public.invitations', 'party_id', 'insert')
  and has_column_privilege('authenticated', 'public.invitations', 'guest_id', 'insert')
  and not has_column_privilege('authenticated', 'public.invitations', 'via_link_id', 'insert'),
  'a client may insert party_id and guest_id into invitations, never via_link_id'
);

select is(
  (select array_agg(p.proname::text order by p.proname) from pg_proc p
   where p.pronamespace = 'public'::regnamespace and not p.prosecdef
     and p.proname in ('invite_to_party', 'get_invitable_followers', 'get_party_invitees')),
  array['get_invitable_followers', 'get_party_invitees', 'invite_to_party'],
  'the follower picker, the invitee list and invite_to_party are INVOKER -- the existing policies decide'
);


-- ===========================================================================
-- B. Inviting followers
-- ===========================================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select results_eq(
  $$ select user_id, already_invited from public.get_invitable_followers('ffffffff-0000-0000-0000-000000000001')
     order by user_id $$,
  $$ values ('0c0c0c0c-0000-0000-0000-000000000001'::uuid, false),
            ('0c0c0c0c-0000-0000-0000-000000000002'::uuid, true) $$,
  'the picker lists the host''s followers -- not c3 (blocked), not c4 (followed BY the host, gotcha 14) -- and marks c2 as already invited'
);

select results_eq(
  $$ select user_id from public.get_invitable_followers('ffffffff-0000-0000-0000-000000000001', 'IKOS') $$,
  $$ values ('0c0c0c0c-0000-0000-0000-000000000001'::uuid) $$,
  'search is a case-insensitive substring of the username'
);

select results_eq(
  $$ select user_id from public.get_invitable_followers('ffffffff-0000-0000-0000-000000000001', null, null, null, 1) $$,
  $$ select user_id from public.get_invitable_followers('ffffffff-0000-0000-0000-000000000001') order by username, user_id limit 1 $$,
  'alphabetical, first page of one'
);

select is(
  public.invite_to_party('ffffffff-0000-0000-0000-000000000001', array[
    '0c0c0c0c-0000-0000-0000-000000000001',   -- invitable
    '0c0c0c0c-0000-0000-0000-000000000002',   -- already invited
    '0c0c0c0c-0000-0000-0000-000000000003',   -- blocked
    '0c0c0c0c-0000-0000-0000-000000000004',   -- invite_policy = following, does not follow the host
    '11111111-1111-1111-1111-111111111111'    -- the host
  ]::uuid[]),
  1,
  'invite_to_party writes only the one eligible invitation and skips the rest without failing'
);

select throws_ok(
  $$ select public.invite_to_party('ffffffff-0000-0000-0000-000000000003', array['0c0c0c0c-0000-0000-0000-000000000004']::uuid[]) $$,
  '42501', null, 'no invitations to a cancelled party');
select throws_ok(
  $$ select public.invite_to_party('ffffffff-0000-0000-0000-000000000004', array['0c0c0c0c-0000-0000-0000-000000000004']::uuid[]) $$,
  '42501', null, 'nor to one that has ended');

select throws_ok(
  $$ insert into public.invitations (party_id, guest_id, via_link_id)
     values ('ffffffff-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', gen_random_uuid()) $$,
  '42501', null,
  'a host cannot forge via_link_id through a direct insert'
);

-- A public party: the invitation is the "you're invited".
select is(
  public.invite_to_party('ffffffff-0000-0000-0000-000000000002', array['0c0c0c0c-0000-0000-0000-000000000001']::uuid[]),
  1,
  'the host invites a follower to a PUBLIC party'
);

select tests.authenticate_as('0c0c0c0c-0000-0000-0000-000000000001'); -- c1
select ok(
  exists (select 1 from public.parties where id = 'ffffffff-0000-0000-0000-000000000001'),
  'c1 can now see private party X'
);
select is(
  (select is_invited from public.get_party('ffffffff-0000-0000-0000-000000000002')),
  true,
  'and the public party Y reads as invited for them'
);
select ok(
  exists (select 1 from public.get_my_parties() where party_id = 'ffffffff-0000-0000-0000-000000000002' and is_invited),
  'and it is in their MY PARTIES'
);

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee, not the host
select throws_ok(
  $$ select public.invite_to_party('ffffffff-0000-0000-0000-000000000001', array['33333333-3333-3333-3333-333333333333']::uuid[]) $$,
  '42501', null, 'a non-host cannot invite');
select throws_ok(
  $$ select * from public.get_invitable_followers('ffffffff-0000-0000-0000-000000000001') $$,
  '42501', null, 'nor list the host''s followers');
select throws_ok(
  $$ select * from public.get_party_invitees('ffffffff-0000-0000-0000-000000000001') $$,
  '42501', null, 'nor the invitee list');

select tests.clear_authentication();
select throws_ok(
  $$ select public.invite_to_party('ffffffff-0000-0000-0000-000000000001', array['33333333-3333-3333-3333-333333333333']::uuid[]) $$,
  '42501', null, 'signed out: refused');


-- ===========================================================================
-- C. Invite links
-- ===========================================================================
select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger
select throws_ok(
  $$ select public.create_party_invite_link('ffffffff-0000-0000-0000-000000000001') $$,
  '42501', null, 'a non-host cannot create a link');

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host
select throws_ok(
  $$ select public.create_party_invite_link('ffffffff-0000-0000-0000-000000000002') $$,
  '42501', null, 'no link for a PUBLIC party -- its /p/ link already opens it');
select throws_ok(
  $$ select public.create_party_invite_link('ffffffff-0000-0000-0000-000000000003') $$,
  '42501', null, 'no link for a cancelled party');
select throws_ok(
  $$ select public.create_party_invite_link('ffffffff-0000-0000-0000-000000000004') $$,
  '42501', null, 'no link for an ended party');
select throws_ok(
  $$ select public.create_party_invite_link('ffffffff-0000-0000-0000-000000000001', 0) $$,
  '22023', null, 'max uses must be positive');

insert into tokens values ('x1', public.create_party_invite_link('ffffffff-0000-0000-0000-000000000001', 2));

select matches((select token from tokens where name = 'x1'), '^[A-Za-z0-9_-]{43}$',
  'the token is 43 url-safe characters (256 random bits)');

select results_eq(
  $$ select max_uses, use_count from public.get_party_invite_link('ffffffff-0000-0000-0000-000000000001') $$,
  $$ values (2, 0) $$,
  'the host reads the link''s state'
);
select is_empty(
  $$ select 1 from information_schema.routines r
     join information_schema.parameters pa on pa.specific_name = r.specific_name
     where r.routine_name = 'get_party_invite_link' and pa.parameter_mode = 'OUT' and pa.parameter_name ~ 'token' $$,
  'and never its token'
);

reset role;
select is(
  (select count(*)::int from public.party_invite_links
   where token_hash = public.party_invite_token_hash((select token from tokens where name = 'x1'))),
  1,
  'what is stored is the sha256 of the token'
);

-- A stranger redeems it.
select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger
select is_empty(
  $$ select 1 from public.parties where id = 'ffffffff-0000-0000-0000-000000000001' $$,
  'CONTROL: before the link, the stranger cannot see X'
);
select is(
  public.redeem_party_invite((select token from tokens where name = 'x1')),
  'ffffffff-0000-0000-0000-000000000001'::uuid,
  'redeeming returns the party'
);
select ok(
  exists (select 1 from public.parties where id = 'ffffffff-0000-0000-0000-000000000001'),
  'and the stranger can now see the private party'
);
select is(
  public.redeem_party_invite((select token from tokens where name = 'x1')),
  'ffffffff-0000-0000-0000-000000000001'::uuid,
  'redeeming again is harmless'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host
select results_eq(
  $$ select use_count from public.get_party_invite_link('ffffffff-0000-0000-0000-000000000001') $$,
  $$ values (1) $$,
  'the second redemption spent no use'
);
select results_eq(
  $$ select via_link from public.get_party_invitees('ffffffff-0000-0000-0000-000000000001')
     where user_id = '44444444-4444-4444-4444-444444444444' $$,
  $$ values (true) $$,
  'the host''s invitee list says the stranger came through the link'
);

-- Every refusal is one message.
select throws_ok(
  format('select public.redeem_party_invite(%L)', (select token from tokens where name = 'x1')),
  '42501', 'invite link not valid', 'the host cannot redeem their own link');

select tests.authenticate_as('0c0c0c0c-0000-0000-0000-000000000003'); -- blocked by the host
select throws_ok(
  format('select public.redeem_party_invite(%L)', (select token from tokens where name = 'x1')),
  '42501', 'invite link not valid', 'a block-paired user is refused -- with the same message, so this is no block oracle');

select throws_ok(
  $$ select public.redeem_party_invite('not-a-token') $$,
  '42501', 'invite link not valid', 'a malformed token: same message');
select throws_ok(
  $$ select public.redeem_party_invite(repeat('A', 43)) $$,
  '42501', 'invite link not valid', 'a well-formed token that matches nothing: same message');

-- c4's invite_policy is 'following' and they do not follow the host: a direct
-- invite was refused above, but a link is their own act (D6).
select tests.authenticate_as('0c0c0c0c-0000-0000-0000-000000000004');
select is(
  public.redeem_party_invite((select token from tokens where name = 'x1')),
  'ffffffff-0000-0000-0000-000000000001'::uuid,
  'the joiner''s own invite_policy does not apply to a link they opened'
);

-- That was use 2 of 2.
select tests.authenticate_as('33333333-3333-3333-3333-333333333333');
select throws_ok(
  format('select public.redeem_party_invite(%L)', (select token from tokens where name = 'x1')),
  '42501', 'invite link not valid', 'a used-up link: same message');

select tests.clear_authentication();
select throws_ok(
  format('select public.redeem_party_invite(%L)', (select token from tokens where name = 'x1')),
  '42501', null, 'signed out: refused');

-- Regenerate, then disable.
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');
insert into tokens values ('x2', public.create_party_invite_link('ffffffff-0000-0000-0000-000000000001'));

select tests.authenticate_as('33333333-3333-3333-3333-333333333333');
select throws_ok(
  format('select public.redeem_party_invite(%L)', (select token from tokens where name = 'x1')),
  '42501', 'invite link not valid', 'after regenerating, the OLD link is dead');
select is(
  public.redeem_party_invite((select token from tokens where name = 'x2')),
  'ffffffff-0000-0000-0000-000000000001'::uuid,
  'and the new one works'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111');
select lives_ok($$ select public.disable_party_invite_link('ffffffff-0000-0000-0000-000000000001') $$,
  'the host disables the link');
select is_empty($$ select * from public.get_party_invite_link('ffffffff-0000-0000-0000-000000000001') $$,
  'and there is no active link');

select tests.authenticate_as('66666666-6666-6666-6666-666666666666');
select throws_ok(
  format('select public.redeem_party_invite(%L)', (select token from tokens where name = 'x2')),
  '42501', 'invite link not valid', 'a disabled link: same message');

-- Cancelled and ended parties refuse a link that was valid when made.
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');
insert into tokens values ('v', public.create_party_invite_link('ffffffff-0000-0000-0000-000000000005'));
reset role;
update public.parties set status = 'cancelled' where id = 'ffffffff-0000-0000-0000-000000000005';
select tests.authenticate_as('66666666-6666-6666-6666-666666666666');
select throws_ok(
  format('select public.redeem_party_invite(%L)', (select token from tokens where name = 'v')),
  '42501', 'invite link not valid', 'a cancelled party refuses its link');
reset role;
update public.parties set status = 'published', starts_at = now() - interval '2 days', ends_at = now() - interval '1 day'
where id = 'ffffffff-0000-0000-0000-000000000005';
select tests.authenticate_as('66666666-6666-6666-6666-666666666666');
select throws_ok(
  format('select public.redeem_party_invite(%L)', (select token from tokens where name = 'v')),
  '42501', 'invite link not valid', 'an ended party refuses its link');
reset role;
update public.parties set starts_at = now() + interval '2 days', ends_at = null
where id = 'ffffffff-0000-0000-0000-000000000005';

-- The per-user rate limit: 20 link joins in an hour, then refused.
insert into public.party_invite_links (id, party_id, token_hash)
select ('abababab-0000-0000-0000-' || lpad(g::text, 12, '0'))::uuid, p.id, extensions.gen_random_bytes(32)
from generate_series(1, 20) g
cross join lateral (
  -- Parties second_host is not already invited to, and not V, which the
  -- assertion below redeems.
  select pa.id from public.parties pa
  where pa.host_id <> '66666666-6666-6666-6666-666666666666'
    and pa.id <> 'ffffffff-0000-0000-0000-000000000005'
    and not exists (
      select 1 from public.invitations i
      where i.party_id = pa.id and i.guest_id = '66666666-6666-6666-6666-666666666666'
    )
  order by pa.id offset g - 1 limit 1
) p;
insert into public.invitations (party_id, guest_id, via_link_id)
select l.party_id, '66666666-6666-6666-6666-666666666666', l.id
from public.party_invite_links l where l.id::text like 'abababab-%'
on conflict (party_id, guest_id) do nothing;

select is(
  (select count(*)::int from public.invitations
   where guest_id = '66666666-6666-6666-6666-666666666666' and via_link_id is not null),
  20,
  'CONTROL: second_host has 20 link joins this hour'
);

select tests.authenticate_as('66666666-6666-6666-6666-666666666666');
select throws_ok(
  format('select public.redeem_party_invite(%L)', (select token from tokens where name = 'v')),
  '42501', 'invite link rate limit exceeded: 20 per hour',
  'the 21st link join in an hour is refused, with a message about the rate and nothing about the party'
);


-- ===========================================================================
-- D. Removing a guest
-- ===========================================================================
-- The stranger joined X through the link above; they now say Coming and the
-- host writes in the chat, which broadcasts on party:X.
select tests.authenticate_as('44444444-4444-4444-4444-444444444444');
insert into public.rsvps (party_id, user_id, status)
values ('ffffffff-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444', 'going');

select tests.authenticate_as('11111111-1111-1111-1111-111111111111');
insert into public.messages (party_id, author_id, body)
values ('ffffffff-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'welcome');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444');
select set_config('realtime.topic', 'party:ffffffff-0000-0000-0000-000000000001', true);
select isnt_empty(
  $$ select 1 from realtime.messages where topic = 'party:ffffffff-0000-0000-0000-000000000001' $$,
  'CONTROL: before removal, the link guest can join the party''s chat topic'
);
select isnt_empty(
  $$ select 1 from public.messages where party_id = 'ffffffff-0000-0000-0000-000000000001' $$,
  'CONTROL: and read its messages'
);

reset role;
create temp table before_removal on commit drop as
select going_count, interested_count, (select count(*) from public.rsvp_count_events
  where party_id = 'ffffffff-0000-0000-0000-000000000001') as events
from public.parties where id = 'ffffffff-0000-0000-0000-000000000001';

select tests.authenticate_as('22222222-2222-2222-2222-222222222222');
select throws_ok(
  $$ select public.remove_party_guest('ffffffff-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444') $$,
  '42501', null, 'a non-host cannot remove anyone');

select tests.authenticate_as('11111111-1111-1111-1111-111111111111');
select throws_ok(
  $$ select public.remove_party_guest('ffffffff-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111') $$,
  '22023', null, 'the host cannot remove themselves');

select lives_ok(
  $$ select public.remove_party_guest('ffffffff-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444') $$,
  'the host removes the link guest');

reset role;
select is_empty(
  $$ select 1 from public.invitations where party_id = 'ffffffff-0000-0000-0000-000000000001'
       and guest_id = '44444444-4444-4444-4444-444444444444'
     union all
     select 1 from public.rsvps where party_id = 'ffffffff-0000-0000-0000-000000000001'
       and user_id = '44444444-4444-4444-4444-444444444444' $$,
  'their invitation and their rsvp are gone'
);
select results_eq(
  $$ select going_count, interested_count from public.parties where id = 'ffffffff-0000-0000-0000-000000000001' $$,
  $$ select going_count - 1, interested_count - 1 from before_removal $$,
  'the counters moved through the trigger, exactly as an un-RSVP'
);
select results_eq(
  $$ select going_delta::int, interested_delta::int from public.rsvp_count_events
     where party_id = 'ffffffff-0000-0000-0000-000000000001' order by id desc limit 1 $$,
  $$ values (-1, -1) $$,
  'and the history recorded it'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444');
select is_empty(
  $$ select 1 from public.parties where id = 'ffffffff-0000-0000-0000-000000000001' $$,
  'the removed guest can no longer see the private party'
);
select is_empty(
  $$ select 1 from public.messages where party_id = 'ffffffff-0000-0000-0000-000000000001' $$,
  'nor read its chat'
);
select set_config('realtime.topic', 'party:ffffffff-0000-0000-0000-000000000001', true);
select is_empty(
  $$ select 1 from realtime.messages where topic = 'party:ffffffff-0000-0000-0000-000000000001' $$,
  'nor join its realtime topic'
);
select throws_ok(
  $$ insert into public.messages (party_id, author_id, body)
     values ('ffffffff-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444', 'still here?') $$,
  '42501', null,
  'nor write in it'
);

-- The link is live again; a removed person still cannot use it.
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');
insert into tokens values ('x3', public.create_party_invite_link('ffffffff-0000-0000-0000-000000000001'));
select tests.authenticate_as('44444444-4444-4444-4444-444444444444');
select throws_ok(
  format('select public.redeem_party_invite(%L)', (select token from tokens where name = 'x3')),
  '42501', 'invite link not valid', 'a removed guest cannot come back through a still-active link');

-- Only a direct invite from the host lifts it.
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');
select is(
  public.invite_to_party('ffffffff-0000-0000-0000-000000000001', array['44444444-4444-4444-4444-444444444444']::uuid[]),
  1,
  'the host invites them back directly'
);
reset role;
select is_empty(
  $$ select 1 from public.party_guest_removals where party_id = 'ffffffff-0000-0000-0000-000000000001'
       and user_id = '44444444-4444-4444-4444-444444444444' $$,
  'which clears the removal'
);
select tests.authenticate_as('44444444-4444-4444-4444-444444444444');
select ok(
  exists (select 1 from public.parties where id = 'ffffffff-0000-0000-0000-000000000001'),
  'and they can see the party again'
);

-- A public party: removal clears the invitation; the party stays public.
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');
select lives_ok(
  $$ select public.remove_party_guest('ffffffff-0000-0000-0000-000000000002', '0c0c0c0c-0000-0000-0000-000000000001') $$,
  'the host removes an invitee from a public party');
select tests.authenticate_as('0c0c0c0c-0000-0000-0000-000000000001');
select is(
  (select is_invited from public.get_party('ffffffff-0000-0000-0000-000000000002')),
  false,
  'they are no longer invited, though a public party stays visible to them'
);

-- Export and erasure.
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');
select public.remove_party_guest('ffffffff-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333');
select tests.authenticate_as('33333333-3333-3333-3333-333333333333');
select is(
  (select jsonb_path_query_array(public.export_account_data(), '$.party_removals[*].party_id')),
  '["ffffffff-0000-0000-0000-000000000001"]'::jsonb,
  'the removed person''s export lists the removal, as a party id'
);
select is_empty(
  $$ select 1 from jsonb_array_elements(public.export_account_data() -> 'party_removals') e
     where e ? 'title' or e ? 'party_title' $$,
  'and not the party''s title'
);

reset role;
update public.profiles set deleted_at = now() - interval '31 days' where id = '33333333-3333-3333-3333-333333333333';
select lives_ok(
  $$ select public.complete_account_erasure('33333333-3333-3333-3333-333333333333') $$,
  'the removed person''s account is erased');
select is_empty(
  $$ select 1 from public.party_guest_removals where user_id = '33333333-3333-3333-3333-333333333333' $$,
  'and erasure deleted their removal records'
);

select * from finish();
rollback;
