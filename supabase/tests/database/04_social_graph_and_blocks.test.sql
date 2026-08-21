-- Phase 3: the follow graph, blocks, and -- the part that actually matters --
-- a blocked persona asserted against every policy that existed before this
-- phase, not just the two tables it adds. Policies from Phases 0 and 2 are
-- re-tested here under a block; Phase 1 (identity) was never implemented, so
-- there are no Phase 1 policies to cover.
--
-- Personas (seed.sql): host 1111, invitee 2222, friend_not_invited 3333,
-- stranger 4444, blocked_user 5555, second_host 6666.
-- blocked_user hosts 'aaaa…0021' (public) and 'aaaa…0022' (private, host
-- invited), both in the Syntagma cluster.
begin;
set search_path to public, extensions;
select plan(29);

-- ============================================================
-- follows: the graph itself
-- ============================================================

-- Captured BEFORE the first edge is created, and before any persona switch.
--
-- The host's follower_count used to be asserted as a literal 1, which was only
-- ever correct because seed.sql seeded no follows at all. It now seeds a graph
-- (the profile screen renders these counters, and 0/0 is unreadable), so the
-- thing this file actually tests -- "the trigger moves the counter by exactly
-- one" -- has to be expressed as a delta or it is testing the seed instead.
--
-- Read as postgres rather than as one of the personas: the profiles SELECT
-- policy is block-filtered, and a baseline captured through a filter that the
-- assertions later change is not a baseline (gotcha #17).
create temp table phase3_baseline as
select
  (select follower_count from public.profiles
   where id = '11111111-1111-1111-1111-111111111111') as host_followers;

-- Owned by postgres, because that is who captured it -- and read later while
-- the session role is `authenticated`, which holds no privilege on it. (Test
-- 11's equivalent needs no grant only because it is created AS authenticated,
-- which is exactly the filtered read this one is avoiding.)
grant select on phase3_baseline to public;

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

insert into public.follows (follower_id, followee_id) values
  ('44444444-4444-4444-4444-444444444444', '11111111-1111-1111-1111-111111111111');

select isnt_empty(
  $$ select 1 from public.follows
     where follower_id = '44444444-4444-4444-4444-444444444444'
     and followee_id = '11111111-1111-1111-1111-111111111111' $$,
  'a user can follow someone without reciprocity (asymmetric graph)'
);

select is(
  (select following_count from public.profiles where id = '44444444-4444-4444-4444-444444444444'),
  1,
  'following_count ticks up on the follower'
);

select is(
  (select follower_count from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  (select host_followers + 1 from phase3_baseline),
  'follower_count ticks up on the followee'
);

select throws_ok(
  $$ insert into public.follows (follower_id, followee_id) values
     ('44444444-4444-4444-4444-444444444444', '44444444-4444-4444-4444-444444444444') $$,
  '23514',
  null,
  'a user cannot follow themselves (check constraint)'
);

select throws_ok(
  $$ insert into public.follows (follower_id, followee_id) values
     ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222') $$,
  '42501',
  null,
  'a user cannot create a follow edge on someone else''s behalf'
);

-- Follow counts and edges are public: a third party can read them.
select tests.authenticate_as('66666666-6666-6666-6666-666666666666'); -- second_host

select isnt_empty(
  $$ select 1 from public.follows
     where follower_id = '44444444-4444-4444-4444-444444444444'
     and followee_id = '11111111-1111-1111-1111-111111111111' $$,
  'follow edges between two other users are publicly readable'
);

-- Blocked users must not be able to write their own credibility/follow
-- counters through the profiles UPDATE policy, which gates rows, not columns.
select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

update public.profiles
set follower_count = 9999, credibility_score = 9999
where id = '44444444-4444-4444-4444-444444444444';

select is(
  (select follower_count from public.profiles where id = '44444444-4444-4444-4444-444444444444'),
  0,
  'a user cannot inflate their own follower_count via the profiles UPDATE policy'
);

-- ============================================================
-- blocks: creation, secrecy, and the follow purge
-- ============================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

-- host follows blocked_user and blocked_user follows host, so the purge has
-- an edge to delete in each direction.
insert into public.follows (follower_id, followee_id) values
  ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555');

select tests.authenticate_as('55555555-5555-5555-5555-555555555555'); -- blocked_user

insert into public.follows (follower_id, followee_id) values
  ('55555555-5555-5555-5555-555555555555', '11111111-1111-1111-1111-111111111111');

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

insert into public.blocks (blocker_id, blocked_id) values
  ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555');

select is_empty(
  $$ select 1 from public.follows
     where (follower_id = '11111111-1111-1111-1111-111111111111' and followee_id = '55555555-5555-5555-5555-555555555555')
        or (follower_id = '55555555-5555-5555-5555-555555555555' and followee_id = '11111111-1111-1111-1111-111111111111') $$,
  'blocking deletes the follow edges in BOTH directions'
);

-- baseline + 1, not baseline + 2: the host arrived here with stranger's follow
-- AND blocked_user's, and the block just purged one of them. The seeded
-- followers are untouched, which is the other half of what this asserts --
-- the purge is pair-scoped, not "drop everyone".
select is(
  (select follower_count from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  (select host_followers + 1 from phase3_baseline),
  'the purge cascades into the counter trigger (host keeps stranger''s follow and the seeded ones, loses blocked_user''s)'
);

select throws_ok(
  $$ insert into public.blocks (blocker_id, blocked_id) values
     ('55555555-5555-5555-5555-555555555555', '22222222-2222-2222-2222-222222222222') $$,
  '42501',
  null,
  'a user cannot create a block on someone else''s behalf'
);

select tests.authenticate_as('55555555-5555-5555-5555-555555555555'); -- blocked_user

select is_empty(
  $$ select 1 from public.blocks
     where blocked_id = '55555555-5555-5555-5555-555555555555' $$,
  'the blocked user cannot see that they have been blocked'
);

select throws_ok(
  $$ insert into public.follows (follower_id, followee_id) values
     ('55555555-5555-5555-5555-555555555555', '11111111-1111-1111-1111-111111111111') $$,
  '42501',
  null,
  'the blocked user cannot follow the blocker again while the block stands'
);

-- ============================================================
-- profiles: is_blocked is symmetric -- both sides disappear
-- ============================================================
select is_empty(
  $$ select 1 from public.profiles where id = '11111111-1111-1111-1111-111111111111' $$,
  'the blocked user cannot see the blocker''s profile (search, reverse direction)'
);

-- Cross-phase regression guard (20260814104618): hiding the profile row must
-- NOT make the blocker's username look claimable. profiles_username_lower_idx
-- is global, so a "yes" here would be a lie the user only discovers when the
-- claim fails on a constraint violation.
select is(
  public.check_username_available('host'),
  false,
  'a taken username still reads as taken to someone blocked by its owner'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is_empty(
  $$ select 1 from public.profiles where id = '55555555-5555-5555-5555-555555555555' $$,
  'the blocker cannot see the blocked user''s profile (search, forward direction)'
);

-- ============================================================
-- parties (Phase 0 policy, via can_access_party) -- both directions
-- ============================================================
select is_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000021' $$,
  'the blocker cannot see the blocked user''s PUBLIC party (block beats not is_private)'
);

select is_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000022' $$,
  'the blocker cannot see the blocked user''s private party they were invited to'
);

select is_empty(
  $$ select 1 from public.get_parties_near_user(23.7348, 37.9755, 500)
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000021' $$,
  'the blocked user''s party is gone from the map RPC'
);

select tests.authenticate_as('55555555-5555-5555-5555-555555555555'); -- blocked_user

select is_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'the blocked user cannot see the blocker''s public party either (symmetry)'
);

-- ============================================================
-- invitations (Phase 0 policies) -- "they can't invite me"
-- ============================================================
select throws_ok(
  $$ insert into public.invitations (party_id, guest_id) values
     ('aaaaaaaa-0000-0000-0000-000000000021', '11111111-1111-1111-1111-111111111111') $$,
  '42501',
  null,
  'the blocked user cannot invite the blocker to their own party'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is_empty(
  $$ select 1 from public.invitations
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000022'
     and guest_id = '11111111-1111-1111-1111-111111111111' $$,
  'the blocker cannot see the pre-existing invitation from the blocked host'
);

-- ============================================================
-- rsvps (Phase 2 policies)
-- ============================================================
select throws_ok(
  $$ insert into public.rsvps (party_id, user_id, status) values
     ('aaaaaaaa-0000-0000-0000-000000000021', '11111111-1111-1111-1111-111111111111', 'going') $$,
  '42501',
  null,
  'the blocker cannot rsvp to the blocked user''s party (inherited via can_access_party)'
);

-- second_host rsvps to host's public party, then blocks host. The rsvp row
-- must vanish for the host but stay deletable by its owner.
select tests.authenticate_as('66666666-6666-6666-6666-666666666666'); -- second_host

insert into public.rsvps (party_id, user_id, status) values
  ('aaaaaaaa-0000-0000-0000-000000000002', '66666666-6666-6666-6666-666666666666', 'going');

insert into public.blocks (blocker_id, blocked_id) values
  ('66666666-6666-6666-6666-666666666666', '11111111-1111-1111-1111-111111111111');

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is_empty(
  $$ select 1 from public.rsvps
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000002'
     and user_id = '66666666-6666-6666-6666-666666666666' $$,
  'a host cannot see the rsvp row of a user they now have a block with'
);

select tests.authenticate_as('66666666-6666-6666-6666-666666666666'); -- second_host

select isnt_empty(
  $$ select 1 from public.rsvps
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000002'
     and user_id = '66666666-6666-6666-6666-666666666666' $$,
  'the blocking user can still SEE their own pre-existing rsvp'
);

delete from public.rsvps
where party_id = 'aaaaaaaa-0000-0000-0000-000000000002'
and user_id = '66666666-6666-6666-6666-666666666666';

select is_empty(
  $$ select 1 from public.rsvps
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000002'
     and user_id = '66666666-6666-6666-6666-666666666666' $$,
  'the blocking user can still WITHDRAW it -- a block must not trap you as an attendee'
);

-- ============================================================
-- create_party_with_invites silently skips blocked invitees
-- ============================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select isnt(
  (select public.create_party_with_invites(
    jsonb_build_object(
      'title', 'Phase 3 Invite Filter Party',
      'description', 'invitee is fine, blocked_user must be skipped',
      'lat', 37.9755,
      'lon', 23.7348,
      'starts_at', (now() + interval '1 day')::text,
      'is_private', true
    ),
    array['22222222-2222-2222-2222-222222222222',
          '55555555-5555-5555-5555-555555555555']::uuid[]
  )),
  null,
  'create_party_with_invites succeeds even though one invitee is blocked'
);

select results_eq(
  $$ select i.guest_id from public.invitations i
     join public.parties p on p.id = i.party_id
     where p.title = 'Phase 3 Invite Filter Party' $$,
  $$ values ('22222222-2222-2222-2222-222222222222'::uuid) $$,
  'only the non-blocked invitee got an invitation row'
);

-- ============================================================
-- Regressions: blocks must not over-reach
-- ============================================================
select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger, unblocked

select isnt_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000021' $$,
  'an unblocked stranger still sees the same party the blocker cannot'
);

select tests.clear_authentication();

select isnt_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'an anonymous session still sees public parties -- is_blocked(null, x) is false, not true'
);

select * from finish();
rollback;
