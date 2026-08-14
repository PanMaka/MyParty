-- Phase 4: posts, likes, comments, the feed RPC and reports.
--
-- The two assertions the phase was specified around are "a post on a private
-- party is invisible to a non-invitee" and "a blocked user's posts never
-- appear in the feed" -- both are here, each asserted twice (through the
-- plain SELECT policy and through public.get_feed), because they fail in
-- different ways: the first would be a leak in can_access_party inheritance,
-- the second a leak in the author-side is_blocked check that
-- can_access_party does NOT cover.
--
-- Personas (seed.sql): host 1111, invitee 2222, friend_not_invited 3333,
-- stranger 4444, blocked_user 5555, second_host 6666.
-- Parties: aaaa…0001 private (host's, invitee + second_host invited),
-- aaaa…0002 public (host's).
--
-- Every row created here is created inside this transaction rather than in
-- seed.sql, following the precedent set by Phase 3: the counter and
-- soft-delete triggers get exercised for real, and the earlier suites keep
-- seeing exactly the fixture they were written against.
begin;
set search_path to public, extensions;
select plan(31);

-- ============================================================
-- Posting, and party visibility inherited from can_access_party
-- ============================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

insert into public.party_posts (id, party_id, author_id, body) values
  ('bbbbbbbb-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111',
   'Post on the PRIVATE party'),
  ('bbbbbbbb-0000-0000-0000-000000000002',
   'aaaaaaaa-0000-0000-0000-000000000002',
   '11111111-1111-1111-1111-111111111111',
   'Post on the PUBLIC party');

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

select isnt_empty(
  $$ select 1 from public.party_posts
     where id = 'bbbbbbbb-0000-0000-0000-000000000001' $$,
  'an invitee sees a post on the private party they were invited to'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select is_empty(
  $$ select 1 from public.party_posts
     where id = 'bbbbbbbb-0000-0000-0000-000000000001' $$,
  'a post on a private party is invisible to a non-invitee'
);

select isnt_empty(
  $$ select 1 from public.party_posts
     where id = 'bbbbbbbb-0000-0000-0000-000000000002' $$,
  'the same stranger still sees a post on a PUBLIC party (the rule does not over-reach)'
);

select throws_ok(
  $$ insert into public.party_posts (party_id, author_id, body) values
     ('aaaaaaaa-0000-0000-0000-000000000001',
      '44444444-4444-4444-4444-444444444444',
      'trying to post to a party I cannot see') $$,
  '42501',
  null,
  'a non-invitee cannot post to a private party'
);

-- created_at is not in the INSERT grant, so a future-dated post -- which
-- would pin itself to the top of every feed forever -- is refused by
-- Postgres before any policy runs.
select throws_ok(
  $$ insert into public.party_posts (party_id, author_id, body, created_at) values
     ('aaaaaaaa-0000-0000-0000-000000000002',
      '44444444-4444-4444-4444-444444444444',
      'pinned to the top of the feed',
      now() + interval '10 years') $$,
  '42501',
  null,
  'a client cannot set created_at on a post (column-level insert grant)'
);

-- ============================================================
-- Counters
-- ============================================================
select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

insert into public.post_likes (post_id, user_id) values
  ('bbbbbbbb-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222');

insert into public.post_comments (id, post_id, author_id, body) values
  ('cccccccc-0000-0000-0000-000000000001',
   'bbbbbbbb-0000-0000-0000-000000000001',
   '22222222-2222-2222-2222-222222222222',
   'first');

select is(
  (select like_count from public.party_posts where id = 'bbbbbbbb-0000-0000-0000-000000000001'),
  1,
  'liking a post ticks like_count up via the trigger'
);

select is(
  (select comment_count from public.party_posts where id = 'bbbbbbbb-0000-0000-0000-000000000001'),
  1,
  'commenting ticks comment_count up via the trigger'
);

select throws_ok(
  $$ update public.party_posts set like_count = 9999
     where id = 'bbbbbbbb-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'a user cannot write like_count directly (column-level update grant)'
);

delete from public.post_likes
where post_id = 'bbbbbbbb-0000-0000-0000-000000000001'
and user_id = '22222222-2222-2222-2222-222222222222';

select is(
  (select like_count from public.party_posts where id = 'bbbbbbbb-0000-0000-0000-000000000001'),
  0,
  'unliking ticks like_count back down'
);

-- ============================================================
-- Soft delete. "Hidden" has to mean hidden everywhere: out of the SELECT
-- policy AND out of the counter, or a moderator hides a comment and the
-- post still advertises it.
-- ============================================================
select public.hide_comment('cccccccc-0000-0000-0000-000000000001', 'author removed it');

select is(
  (select comment_count from public.party_posts where id = 'bbbbbbbb-0000-0000-0000-000000000001'),
  0,
  'hiding a comment decrements comment_count, it does not just hide it from the UI'
);

select is_empty(
  $$ select 1 from public.post_comments
     where id = 'cccccccc-0000-0000-0000-000000000001' $$,
  'a hidden comment is invisible even to its own author'
);

-- Un-hiding has no client path at all. These two are the reason the
-- soft-delete had to become an RPC: with no UPDATE grant on either table,
-- the privilege check fires before RLS ever filters a row, so there is no
-- edit channel left to defend with a policy.
select throws_ok(
  $$ update public.post_comments set hidden_at = null, hidden_by = null
     where id = 'cccccccc-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'a client cannot un-hide a comment -- there is no update grant on post_comments'
);

select throws_ok(
  $$ update public.party_posts set body = 'edited after the fact'
     where id = 'bbbbbbbb-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'a post is immutable after insert -- there is no update grant on party_posts'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select throws_ok(
  $$ select public.hide_comment('cccccccc-0000-0000-0000-000000000001') $$,
  '42501',
  null,
  'someone who neither wrote the comment nor moderates its post cannot hide it'
);

-- can_moderate_post's host arm: a host can clear their own party's wall
-- without waiting on manual triage.
select tests.authenticate_as('66666666-6666-6666-6666-666666666666'); -- second_host

insert into public.party_posts (id, party_id, author_id, body) values
  ('bbbbbbbb-0000-0000-0000-000000000003',
   'aaaaaaaa-0000-0000-0000-000000000002',
   '66666666-6666-6666-6666-666666666666',
   'Someone else post on the host public party');

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select public.hide_post('bbbbbbbb-0000-0000-0000-000000000003', 'off topic');

select tests.authenticate_as('66666666-6666-6666-6666-666666666666'); -- second_host

select is_empty(
  $$ select 1 from public.party_posts
     where id = 'bbbbbbbb-0000-0000-0000-000000000003' $$,
  'a party host can hide a post someone else made on their party'
);

-- The negative half of the same rule.
select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select throws_ok(
  $$ select public.hide_post('bbbbbbbb-0000-0000-0000-000000000002') $$,
  '42501',
  null,
  'a user who is neither the post author nor the party host cannot hide a post'
);

select isnt_empty(
  $$ select 1 from public.party_posts
     where id = 'bbbbbbbb-0000-0000-0000-000000000002' $$,
  'and the post they tried to hide is still standing'
);

-- ============================================================
-- get_feed
-- ============================================================
insert into public.follows (follower_id, followee_id) values
  ('44444444-4444-4444-4444-444444444444', '11111111-1111-1111-1111-111111111111');

select isnt_empty(
  $$ select 1 from public.get_feed()
     where post_id = 'bbbbbbbb-0000-0000-0000-000000000002' $$,
  'the feed carries a post from a party hosted by someone I follow'
);

select is_empty(
  $$ select 1 from public.get_feed()
     where post_id = 'bbbbbbbb-0000-0000-0000-000000000001' $$,
  'following the host does NOT surface their private party post to a non-invitee'
);

-- Keyset paging. Every row in this transaction shares one created_at (now()
-- is the transaction clock), which makes this the strongest version of the
-- test: the id half of the composite key is the ONLY thing producing a total
-- order, so a keyset that got it wrong would duplicate or drop a row here.
-- Visible to stranger on the public party, id desc: …0005, …0004, …0002.
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

insert into public.party_posts (id, party_id, author_id, body) values
  ('bbbbbbbb-0000-0000-0000-000000000004',
   'aaaaaaaa-0000-0000-0000-000000000002',
   '11111111-1111-1111-1111-111111111111',
   'page filler one'),
  ('bbbbbbbb-0000-0000-0000-000000000005',
   'aaaaaaaa-0000-0000-0000-000000000002',
   '11111111-1111-1111-1111-111111111111',
   'page filler two');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select results_eq(
  $$ select post_id from public.get_feed(null, null, 2) $$,
  $$ values ('bbbbbbbb-0000-0000-0000-000000000005'::uuid),
            ('bbbbbbbb-0000-0000-0000-000000000004'::uuid) $$,
  'feed page 1 returns the newest N in (created_at desc, id desc) order'
);

select results_eq(
  $$ select post_id from public.get_feed(
       (select created_at from public.party_posts where id = 'bbbbbbbb-0000-0000-0000-000000000004'),
       'bbbbbbbb-0000-0000-0000-000000000004'::uuid,
       2) $$,
  $$ values ('bbbbbbbb-0000-0000-0000-000000000002'::uuid) $$,
  'feed page 2 resumes from the cursor with no overlap and no gap'
);

-- ============================================================
-- Blocked authors. can_access_party only knows about the party HOST, so
-- this is the check it cannot make for us: blocked_user posts on a third
-- party's public party, and the block still has to erase it.
-- ============================================================
select tests.authenticate_as('55555555-5555-5555-5555-555555555555'); -- blocked_user

insert into public.party_posts (id, party_id, author_id, body) values
  ('bbbbbbbb-0000-0000-0000-000000000006',
   'aaaaaaaa-0000-0000-0000-000000000002',
   '55555555-5555-5555-5555-555555555555',
   'Post by the soon to be blocked user');

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

insert into public.blocks (blocker_id, blocked_id) values
  ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555');

select is_empty(
  $$ select 1 from public.get_feed()
     where post_id = 'bbbbbbbb-0000-0000-0000-000000000006' $$,
  'a blocked user''s post never appears in the feed'
);

select is_empty(
  $$ select 1 from public.party_posts
     where id = 'bbbbbbbb-0000-0000-0000-000000000006' $$,
  'and it is gone from a plain select too, not just from the RPC'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select isnt_empty(
  $$ select 1 from public.get_feed()
     where post_id = 'bbbbbbbb-0000-0000-0000-000000000006' $$,
  'a third party with no block still sees that post (the block does not over-reach)'
);

-- ============================================================
-- reports
-- ============================================================
insert into public.reports (reporter_id, target_type, target_id, reason) values
  ('44444444-4444-4444-4444-444444444444', 'post',
   'bbbbbbbb-0000-0000-0000-000000000002', 'spam');

select isnt_empty(
  $$ select 1 from public.reports
     where reporter_id = '44444444-4444-4444-4444-444444444444' $$,
  'a reporter can read back the report they filed'
);

select throws_ok(
  $$ insert into public.reports (reporter_id, target_type, target_id, reason) values
     ('44444444-4444-4444-4444-444444444444', 'post',
      'bbbbbbbb-0000-0000-0000-000000000002', 'spam again') $$,
  '23505',
  null,
  'the same target cannot be reported twice by the same user (server-side rate limit)'
);

select throws_ok(
  $$ insert into public.reports (reporter_id, target_type, target_id, reason) values
     ('11111111-1111-1111-1111-111111111111', 'post',
      'bbbbbbbb-0000-0000-0000-000000000004', 'framing the host') $$,
  '42501',
  null,
  'a user cannot file a report in someone else''s name'
);

select throws_ok(
  $$ insert into public.reports (reporter_id, target_type, target_id, reason) values
     ('44444444-4444-4444-4444-444444444444', 'profile',
      '44444444-4444-4444-4444-444444444444', 'reporting myself') $$,
  '23514',
  null,
  'a user cannot report their own profile (check constraint)'
);

select throws_ok(
  $$ insert into public.reports (reporter_id, target_type, target_id, reason, status) values
     ('44444444-4444-4444-4444-444444444444', 'party',
      'aaaaaaaa-0000-0000-0000-000000000002', 'already handled', 'dismissed') $$,
  '42501',
  null,
  'a reporter cannot set status on insert (column-level grant keeps triage server-side)'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is_empty(
  $$ select 1 from public.reports
     where reporter_id = '44444444-4444-4444-4444-444444444444' $$,
  'nobody can read another user''s reports -- least of all the reported party'
);

-- ============================================================
-- Anonymous sessions
-- ============================================================
select tests.clear_authentication();

select throws_ok(
  $$ select 1 from public.get_feed() $$,
  '42501',
  null,
  'there is no anonymous feed -- anon cannot execute get_feed at all'
);

select * from finish();
rollback;
