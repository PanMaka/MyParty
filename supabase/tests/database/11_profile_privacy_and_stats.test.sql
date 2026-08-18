-- Phase 8: the two privacy columns, and the three counters.
--
-- The thing being proved here is narrow and specific: that map_visibility and
-- invite_policy are enforced by the DATABASE. Both columns exist to back a
-- switch on a settings screen, and a switch the server does not read is
-- privacy theatre -- the app would look identical whether the rule worked or
-- not, which is precisely why it needs assertions rather than a manual check.
--
-- So almost everything below is negative: a party that must NOT come back from
-- the map RPC, an invitation that must NOT insert. The positive assertions are
-- mostly controls, there to prove the negatives failed for the intended reason
-- and not because the query broke outright.
--
-- Personas (seed.sql): host 1111, invitee 2222, friend_not_invited 3333,
-- stranger 4444, blocked_user 5555, second_host 6666. Seeded parties used:
--   aaaa...0001  private, hosted by 1111, invitee 2222 + second_host 6666 invited
--   aaaa...0002  public,  hosted by 1111  ("Syntagma Afterparty")
-- No follows, rsvps or stories are seeded, so every count here starts at zero
-- and the edges are built inside this transaction.
begin;
set search_path to public, extensions;
select plan(31);

-- Stands in for the Storage API, exactly as in 07_stories.test.sql: a story is
-- invisible until its bytes exist, so counting one requires a confirmed
-- upload. Redefined here because 07 creates it inside its own transaction and
-- rolls back.
create or replace function tests.fake_upload(p_story_id uuid)
returns void
language plpgsql
security definer
as $$
declare
  v_path text;
begin
  select media_path into v_path from public.stories where id = p_story_id;
  insert into storage.objects (bucket_id, name, metadata)
  values ('story-media', v_path, '{"size": 1024, "mimetype": "image/jpeg"}'::jsonb)
  on conflict do nothing;
end;
$$;


-- ============================================================
-- 1. The columns default to permissive, which is what makes this migration
-- safe on an existing table. Every Phase 0-7 assertion still passes because
-- 'public'/'anyone' ARE the old unconditional rules.
-- ============================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is(
  (select map_visibility::text from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'public',
  'map_visibility defaults to public -- existing rows keep todays behaviour'
);

select is(
  (select invite_policy::text from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'anyone',
  'invite_policy defaults to anyone'
);

-- These are preferences, not system-maintained columns, so unlike
-- credibility_score/follower_count the owner must be able to write them.
update public.profiles set map_visibility = 'followers'
where id = '11111111-1111-1111-1111-111111111111';

select is(
  (select map_visibility::text from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'followers',
  'a user can set their own map_visibility -- protect_credibility_score does not freeze it'
);

-- The profiles UPDATE policy is owner-only, so this matches no row rather than
-- raising: silently changing nothing is the correct RLS outcome.
update public.profiles set map_visibility = 'private'
where id = '22222222-2222-2222-2222-222222222222';

select is(
  (select map_visibility::text from public.profiles where id = '22222222-2222-2222-2222-222222222222'),
  'public',
  'but not somebody elses -- the owner-only UPDATE policy still holds'
);


-- ============================================================
-- 2. map_visibility inside get_parties_near_user.
--
-- host 1111 is now at 'followers'. Radius 15000 keeps the tier filter at
-- `true` so nothing below is confused with the zoom rules from Phase 2.
-- ============================================================
select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger, follows nobody

-- THE ASSERTION THIS PHASE WAS ASKED FOR.
select is_empty(
  $$ select 1 from public.get_parties_near_user(23.7351, 37.9758, 15000)
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'map_visibility = followers hides the hosts party from a stranger who does not follow them'
);

-- The control that proves the filter is targeted. If the map RPC had simply
-- broken, this would be empty too.
select isnt_empty(
  $$ select 1 from public.get_parties_near_user(23.7351, 37.9758, 15000)
     where host_id = '66666666-6666-6666-6666-666666666666' $$,
  'while a different hosts parties are unaffected -- the gate is per-host, not global'
);

select tests.authenticate_as('33333333-3333-3333-3333-333333333333'); -- friend_not_invited

insert into public.follows (follower_id, followee_id) values
  ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111');

select isnt_empty(
  $$ select 1 from public.get_parties_near_user(23.7351, 37.9758, 15000)
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'but a follower sees it -- note the direction: viewer follows host, not the reverse'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select isnt_empty(
  $$ select 1 from public.get_parties_near_user(23.7351, 37.9758, 15000)
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'and the host always sees their own party, at every tier'
);

-- Tighten to 'private': not even the follower qualifies now.
update public.profiles set map_visibility = 'private'
where id = '11111111-1111-1111-1111-111111111111';

select tests.authenticate_as('33333333-3333-3333-3333-333333333333'); -- follower

select is_empty(
  $$ select 1 from public.get_parties_near_user(23.7351, 37.9758, 15000)
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'private hides it from a follower too -- the tiers are ordered, not alternatives'
);


-- ============================================================
-- 3. The party-specific override, and its limits.
--
-- An invitation or an RSVP is a deliberate act aimed at ONE party, and it
-- outranks the host's blanket setting. The limit matters as much as the rule:
-- the override must be scoped to that party, never to the host.
-- ============================================================
select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee, invited to ...0001

select isnt_empty(
  $$ select 1 from public.get_parties_near_user(23.7351, 37.9758, 15000)
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'an invitation overrides map_visibility = private -- a host cannot un-invite by toggling a setting'
);

select is_empty(
  $$ select 1 from public.get_parties_near_user(23.7351, 37.9758, 15000)
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'but only for THAT party -- the same viewer still cannot see the hosts other parties'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

-- can_access_party is about is_private/invitations and knows nothing about
-- map_visibility, so a public party is still RSVP-able while its host is
-- hidden from the map. That is the whole point of the override.
insert into public.rsvps (party_id, user_id, status) values
  ('aaaaaaaa-0000-0000-0000-000000000002', '44444444-4444-4444-4444-444444444444', 'going');

select isnt_empty(
  $$ select 1 from public.get_parties_near_user(23.7351, 37.9758, 15000)
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'an existing RSVP overrides it too -- a pin must not detach from a party you already joined'
);

select is_empty(
  $$ select 1 from public.get_parties_near_user(23.7351, 37.9758, 15000)
     where host_id = '11111111-1111-1111-1111-111111111111'
       and party_id <> 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'and every other party of that host stays hidden -- the override is party-scoped, not host-scoped'
);


-- ============================================================
-- 4. invite_policy in the invitations INSERT policy.
--
-- Direction check: 'following' means people the GUEST follows. It is the
-- mirror of map_visibility's 'followers', and swapping them is the easiest
-- possible bug here -- assertions on both directions are what catch it.
-- ============================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host
update public.profiles set map_visibility = 'public'
where id = '11111111-1111-1111-1111-111111111111';

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger, follows nobody
update public.profiles set invite_policy = 'following'
where id = '44444444-4444-4444-4444-444444444444';

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is(
  public.accepts_invite_from('44444444-4444-4444-4444-444444444444', '11111111-1111-1111-1111-111111111111'),
  false,
  'accepts_invite_from is false when the guest follows nobody and requires following'
);

select throws_ok(
  $$ insert into public.invitations (party_id, guest_id) values
     ('aaaaaaaa-0000-0000-0000-000000000002', '44444444-4444-4444-4444-444444444444') $$,
  '42501',
  null,
  'so the host cannot add them to a guest list -- enforced by RLS, not the client'
);

-- 3333 already follows 1111, from section 2. Same host, same statement shape,
-- opposite outcome: the follow edge is the only difference.
select tests.authenticate_as('33333333-3333-3333-3333-333333333333');
update public.profiles set invite_policy = 'following'
where id = '33333333-3333-3333-3333-333333333333';

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is(
  public.accepts_invite_from('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111'),
  true,
  'but true once the guest follows the inviter'
);

insert into public.invitations (party_id, guest_id) values
  ('aaaaaaaa-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333333');

select isnt_empty(
  $$ select 1 from public.invitations
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000002'
     and guest_id = '33333333-3333-3333-3333-333333333333' $$,
  'and the same insert now succeeds'
);

-- Direction proof: 3333 follows 1111, so 1111 may invite 3333 (asserted just
-- above). The reverse edge does not exist, so 1111 -- who requires nothing --
-- is irrelevant here; what matters is that 3333 may NOT invite someone whose
-- policy they do not satisfy. 4444 requires 'following' and follows nobody.
select is(
  public.accepts_invite_from('44444444-4444-4444-4444-444444444444', '33333333-3333-3333-3333-333333333333'),
  false,
  'the rule reads the GUESTS follow list, not the inviters -- swapping the arguments changes the answer'
);

select is(
  public.accepts_invite_from('22222222-2222-2222-2222-222222222222', '44444444-4444-4444-4444-444444444444'),
  true,
  'a guest on anyone accepts an invite from a total stranger -- the default is permissive'
);

-- A guest id with no profiles row refuses. For an invitation that is the safe
-- failure direction, and it is the opposite of the choice in_quiet_hours makes
-- for a missing row -- see the header of 20260818175435.
select is(
  public.accepts_invite_from('99999999-9999-9999-9999-999999999999', '11111111-1111-1111-1111-111111111111'),
  false,
  'and an unknown guest refuses rather than defaulting open'
);


-- ============================================================
-- 5. create_party_with_invites skips a refusing guest instead of failing.
--
-- The RPC inserts every invitee in one statement, so without this filter a
-- single refusing guest would abort the whole call -- handing the host a 42501
-- they cannot act on, and disclosing that specific person's setting. Same
-- reasoning as the block filter in 20260814094946.
-- ============================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select lives_ok(
  $$ select public.create_party_with_invites(
       '{"title":"Phase 8 Fixture","lon":23.7351,"lat":37.9758,"starts_at":"2027-01-01T20:00:00Z"}'::jsonb,
       array['44444444-4444-4444-4444-444444444444',
             '22222222-2222-2222-2222-222222222222']::uuid[]
     ) $$,
  'creating a party with a refusing guest in the list still succeeds'
);

select isnt_empty(
  $$ select 1 from public.invitations i
     join public.parties p on p.id = i.party_id
     where p.title = 'Phase 8 Fixture'
     and i.guest_id = '22222222-2222-2222-2222-222222222222' $$,
  'the accepting guest is invited'
);

select is_empty(
  $$ select 1 from public.invitations i
     join public.parties p on p.id = i.party_id
     where p.title = 'Phase 8 Fixture'
     and i.guest_id = '44444444-4444-4444-4444-444444444444' $$,
  'and the refusing one is silently absent -- no error, no disclosure'
);


-- ============================================================
-- 6. get_profile_stats.
--
-- Invoker rights, so every count is "how many of these may YOU see". The two
-- assertions that matter are the ones where the viewer changes and the number
-- does too -- that is the difference between RLS doing the work and the
-- function having a hand-written visibility rule inside it.
-- ============================================================
select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

insert into public.rsvps (party_id, user_id, status) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'going');

insert into public.stories (id, party_id, author_id, content_type) values
  ('eeeeeeee-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000002',
   '22222222-2222-2222-2222-222222222222',
   'image/jpeg');
select tests.fake_upload('eeeeeeee-0000-0000-0000-000000000001');
select public.confirm_story_upload('eeeeeeee-0000-0000-0000-000000000001');

-- Compared against a control computed with the same year predicate rather than
-- a hardcoded 1, so the assertion stays correct if this ever runs across a
-- new-year boundary.
select is(
  (select parties_attended from public.get_profile_stats('22222222-2222-2222-2222-222222222222')),
  (select count(*)::int from public.rsvps r
   join public.parties p on p.id = r.party_id
   where r.user_id = '22222222-2222-2222-2222-222222222222'
     and r.status = 'going'
     and p.starts_at >= date_trunc('year', now())),
  'parties_attended counts this years going RSVPs for the owner'
);

select is(
  (select stories_posted from public.get_profile_stats('22222222-2222-2222-2222-222222222222')),
  1,
  'stories_posted counts a confirmed story'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

-- Not a limitation being papered over -- it is the rsvps SELECT policy
-- (user_id = auth.uid() OR I host it) showing through, which is why the client
-- renders this tile in the self view only. "Who sees which parties I go to" is
-- a setting that does not exist yet, and this function does not invent it.
select is(
  (select parties_attended from public.get_profile_stats('22222222-2222-2222-2222-222222222222')),
  0,
  'but a stranger sees zero attended -- owner-only by construction, via the rsvps policy'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is(
  (select parties_hosted from public.get_profile_stats('11111111-1111-1111-1111-111111111111')),
  (select count(*)::int from public.parties
   where host_id = '11111111-1111-1111-1111-111111111111' and status = 'published'),
  'the owner sees all of their own published parties'
);

-- Stashed WHILE STILL AUTHENTICATED AS THE HOST, and that detail is the whole
-- reason this temp table exists. A `count(*) from public.parties` evaluated
-- after the persona switch is itself filtered by the same RLS being tested, so
-- it would shrink in lockstep with the number under test and the comparison
-- below would read equal no matter how badly the function leaked.
create temp table phase8_owner_count as
select parties_hosted as n
from public.get_profile_stats('11111111-1111-1111-1111-111111111111');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

-- The load-bearing one: the same argument, a different caller, a smaller
-- number. If this ever equalled the owner's count, invoker rights had been
-- swapped for definer and the private parties would be leaking as a count.
select cmp_ok(
  (select parties_hosted from public.get_profile_stats('11111111-1111-1111-1111-111111111111')),
  '<',
  (select n from phase8_owner_count),
  'a stranger counts fewer -- the hosts private parties are filtered by RLS, not by the function'
);

select is(
  (select parties_hosted from public.get_profile_stats('11111111-1111-1111-1111-111111111111')),
  (select count(*)::int from public.parties
   where host_id = '11111111-1111-1111-1111-111111111111'
     and status = 'published' and is_private = false),
  'and exactly the public ones'
);


-- ============================================================
-- 7. The door.
--
-- CLAUDE.md gotcha #4: the function mentions rsvps and stories, which anon has
-- no SELECT on, so an anonymous call would raise "permission denied for table
-- rsvps" rather than returning zeros. Gotcha #13 is the other half -- the
-- revoke that closes it also takes service_role's privilege, since the default
-- PUBLIC grant is where that came from.
-- ============================================================
select tests.clear_authentication();

select is(
  has_function_privilege('anon', 'public.get_profile_stats(uuid)', 'execute'),
  false,
  'anon cannot call get_profile_stats -- there is no such thing as an anonymous profile view'
);

select is(
  (select bool_and(has_function_privilege(r, 'public.get_profile_stats(uuid)', 'execute'))
   from unnest(array['authenticated', 'service_role']) r),
  true,
  'but authenticated and service_role can -- the explicit grant survived the revoke'
);


select * from finish();
rollback;
