-- Phase 5: stories, story_views, and the expiry/purge pipeline.
--
-- Four things get asserted here that nothing else in the suite covers, and the
-- first three are the ones a story-shaped table gets wrong:
--
--   1. A story is invisible unless its BYTES EXIST. media_uploaded_at is null
--      between "row created" and "upload confirmed", and a row in that state
--      must be invisible to everyone, its own author included -- otherwise the
--      first thing every viewer sees is a broken frame.
--   2. Expiry is enforced by the SELECT POLICY, not by the cron job. A story
--      dies exactly 24h after it was posted whether or not pg_cron ever runs
--      again. The job only collects storage.
--   3. The rate limit counts HIDDEN rows. Hiding is the response to abuse, so
--      a limit that a takedown refunds hands the budget back to the abuser.
--   4. Every hidden row's object gets queued for deletion. pg_net only
--      dispatches after COMMIT and this file ends in a rollback, so what is
--      provable here is that the request and the ledger row are created --
--      scripts/verify_story_lifecycle.sh proves the bytes actually leave the
--      bucket, which no pgTAP file can.
--
-- Personas (seed.sql): host 1111, invitee 2222, friend_not_invited 3333,
-- stranger 4444, blocked_user 5555, second_host 6666.
-- Parties: aaaa…0001 private (host's, invitee + second_host invited),
-- aaaa…0002 public (host's), aaaa…0021 public (blocked_user's).
--
-- Every row is created inside this transaction, following Phases 3, 4 and 6, so
-- the path, rate-limit and counter triggers all get exercised for real.
begin;
set search_path to public, extensions;
select plan(52);

-- seed.sql seeds no stories, so anything in these tables is debris committed by
-- a previous local run of scripts/verify_story_lifecycle.sh. The cleanup
-- assertions at the end of this file count rows globally -- that is the honest
-- way to ask "did the sweep leave anything behind?" -- so the debris has to go
-- first. Rolled back with everything else; on CI both tables are already empty.
delete from public.story_media_purges;
delete from public.stories;

-- Confirming an upload normally checks storage.objects, which no test can
-- write to from SQL without the Storage API. This stands in for the API call:
-- it inserts the metadata row the real upload would have produced, so
-- public.confirm_story_upload does its check against a bucket that genuinely
-- contains the object. `owner` is left null -- these objects have no client
-- owner; the bucket has no policies and only service_role ever writes to it.
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
-- Creation: the path is derived, not supplied.
-- ============================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

insert into public.stories (id, party_id, author_id, content_type) values
  ('ffffffff-0000-0000-0000-000000000001',
   'aaaaaaaa-0000-0000-0000-000000000002',
   '11111111-1111-1111-1111-111111111111',
   'image/jpeg');

-- Read back through the definer RPC and not from the table, because the row is
-- already invisible to its own author at this point -- see (1) below. That the
-- assertion has to be written this way is itself the invariant holding.
select is(
  (select public.story_upload_target('ffffffff-0000-0000-0000-000000000001')),
  'aaaaaaaa-0000-0000-0000-000000000002/ffffffff-0000-0000-0000-000000000001.jpg',
  'media_path is derived as {party_id}/{story_id}.{ext} by the trigger'
);

select throws_ok(
  $$ insert into public.stories (party_id, author_id, content_type, media_path) values
     ('aaaaaaaa-0000-0000-0000-000000000002',
      '11111111-1111-1111-1111-111111111111',
      'image/jpeg',
      'aaaaaaaa-0000-0000-0000-000000000001/hand-picked.jpg') $$,
  '42501',
  null,
  'a client cannot supply media_path -- no insert grant on the column'
);

select throws_ok(
  $$ insert into public.stories (party_id, author_id, content_type, expires_at) values
     ('aaaaaaaa-0000-0000-0000-000000000002',
      '11111111-1111-1111-1111-111111111111',
      'image/jpeg',
      now() + interval '30 days') $$,
  '42501',
  null,
  'nor expires_at -- a story that never dies is not a client decision'
);

select throws_ok(
  $$ insert into public.stories (party_id, author_id, content_type, media_uploaded_at) values
     ('aaaaaaaa-0000-0000-0000-000000000002',
      '11111111-1111-1111-1111-111111111111',
      'image/jpeg',
      now()) $$,
  '42501',
  null,
  'nor media_uploaded_at -- publishing a story with no bytes behind it'
);

select throws_ok(
  $$ update public.stories set hidden_at = now()
     where id = 'ffffffff-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'stories has no UPDATE grant at all -- soft delete goes through hide_story'
);


-- ============================================================
-- (1) Unconfirmed means invisible, to everyone, including the author.
-- ============================================================
select is_empty(
  $$ select 1 from public.stories where id = 'ffffffff-0000-0000-0000-000000000001' $$,
  'an unconfirmed story is invisible even to its own author'
);

select throws_ok(
  $$ select public.confirm_story_upload('ffffffff-0000-0000-0000-000000000001') $$,
  'P0002',
  null,
  'confirm refuses while the object is not actually in the bucket'
);

select tests.fake_upload('ffffffff-0000-0000-0000-000000000001');
select lives_ok(
  $$ select public.confirm_story_upload('ffffffff-0000-0000-0000-000000000001') $$,
  'confirm succeeds once the object exists'
);

select isnt_empty(
  $$ select 1 from public.stories where id = 'ffffffff-0000-0000-0000-000000000001' $$,
  'and the story becomes visible'
);

select throws_ok(
  $$ select public.story_upload_target('ffffffff-0000-0000-0000-000000000001') $$,
  '42501',
  null,
  'an upload URL is one-shot: no second signature for a confirmed story'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select throws_ok(
  $$ select public.story_upload_target('ffffffff-0000-0000-0000-000000000001') $$,
  '42501',
  null,
  'and a stranger never gets one for someone else''s story'
);


-- ============================================================
-- Visibility inherits from can_access_party -- WIDE, unlike chat.
-- ============================================================
select isnt_empty(
  $$ select 1 from public.stories where id = 'ffffffff-0000-0000-0000-000000000001' $$,
  'a stranger CAN see a story on a public party -- stories are read-only, so they use the wide helper, not can_chat_in_party'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

insert into public.stories (id, party_id, author_id, content_type) values
  ('ffffffff-0000-0000-0000-000000000002',
   'aaaaaaaa-0000-0000-0000-000000000001',  -- private party
   '11111111-1111-1111-1111-111111111111',
   'image/jpeg');
select tests.fake_upload('ffffffff-0000-0000-0000-000000000002');
select public.confirm_story_upload('ffffffff-0000-0000-0000-000000000002');

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee
select isnt_empty(
  $$ select 1 from public.stories where id = 'ffffffff-0000-0000-0000-000000000002' $$,
  'an invitee sees a story on the private party they were invited to'
);

select tests.authenticate_as('33333333-3333-3333-3333-333333333333'); -- friend, not invited
select is_empty(
  $$ select 1 from public.stories where id = 'ffffffff-0000-0000-0000-000000000002' $$,
  'a non-invitee sees nothing on a private party -- a follow grants no visibility'
);

select is_empty(
  $$ select 1 from public.get_party_stories('aaaaaaaa-0000-0000-0000-000000000001') $$,
  'and the RPC agrees, because it has no filter of its own -- invoker rights, RLS decides'
);

select is_empty(
  $$ select 1 from public.get_story_rails()
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'nor does the rail advertise that the private party has stories at all'
);

select throws_ok(
  $$ select public.story_upload_target('ffffffff-0000-0000-0000-000000000002') $$,
  '42501',
  null,
  'and a non-invitee cannot get an upload URL for it either'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger
select throws_ok(
  $$ insert into public.stories (party_id, author_id, content_type) values
     ('aaaaaaaa-0000-0000-0000-000000000001',
      '44444444-4444-4444-4444-444444444444',
      'image/jpeg') $$,
  '42501',
  null,
  'posting to a party you cannot see is refused by the insert policy'
);

select throws_ok(
  $$ insert into public.stories (party_id, author_id, content_type) values
     ('aaaaaaaa-0000-0000-0000-000000000002',
      '11111111-1111-1111-1111-111111111111',
      'image/jpeg') $$,
  '42501',
  null,
  'and you cannot post one under somebody else''s name'
);


-- ============================================================
-- The author block -- can_access_party only covers the HOST (gotcha #2).
-- blocked_user hosts aaaa…0021, so their story on their OWN public party is
-- the case the helper alone would catch. This is the other one: a blocked
-- author posting on a party hosted by someone else.
-- ============================================================
select tests.authenticate_as('55555555-5555-5555-5555-555555555555'); -- blocked_user

insert into public.stories (id, party_id, author_id, content_type) values
  ('ffffffff-0000-0000-0000-000000000003',
   'aaaaaaaa-0000-0000-0000-000000000002',  -- host's public party
   '55555555-5555-5555-5555-555555555555',
   'image/jpeg');
select tests.fake_upload('ffffffff-0000-0000-0000-000000000003');
select public.confirm_story_upload('ffffffff-0000-0000-0000-000000000003');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger
select isnt_empty(
  $$ select 1 from public.stories where id = 'ffffffff-0000-0000-0000-000000000003' $$,
  'before any block, everyone sees that story'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host
insert into public.blocks (blocker_id, blocked_id) values
  ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555');

select is_empty(
  $$ select 1 from public.stories where id = 'ffffffff-0000-0000-0000-000000000003' $$,
  'after the block, the blocked author''s story is gone for the blocker -- on a party they host themselves'
);

select is_empty(
  $$ select 1 from public.get_party_stories('aaaaaaaa-0000-0000-0000-000000000002')
     where author_id = '55555555-5555-5555-5555-555555555555' $$,
  'and it is gone from the RPC, which also inner-joins the block-filtered profiles table'
);

select tests.authenticate_as('55555555-5555-5555-5555-555555555555'); -- blocked_user
select is_empty(
  $$ select 1 from public.stories where party_id = 'aaaaaaaa-0000-0000-0000-000000000002'
     and author_id = '11111111-1111-1111-1111-111111111111' $$,
  'and the block cuts both ways -- the blocked user loses the blocker''s stories too'
);


-- ============================================================
-- (2) Expiry is a SELECT policy term, not a cron outcome.
-- ============================================================
-- Written as postgres, and `reset role` rather than `set role postgres`: once
-- the session has switched to anon/authenticated it cannot switch INTO another
-- role, only back out to the session user. No client role has an UPDATE grant
-- here anyway, which is the point of the table. created_at moves with
-- expires_at because stories_expires_after_creation refuses an expiry that
-- predates the row -- "posted 25 hours ago, died an hour ago" is a state that
-- can actually happen.
select tests.clear_authentication();
reset role;

update public.stories
set created_at = now() - interval '25 hours',
    expires_at = now() - interval '1 hour'
where id = 'ffffffff-0000-0000-0000-000000000001';

select is(
  (select hidden_at is null from public.stories
   where id = 'ffffffff-0000-0000-0000-000000000001'),
  true,
  'the expired story is still not hidden -- invisible and hidden are different states'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is_empty(
  $$ select 1 from public.stories where id = 'ffffffff-0000-0000-0000-000000000001' $$,
  'and yet it is invisible the moment it expires -- no cron run involved'
);

select is_empty(
  $$ select 1 from public.story_views where story_id = 'ffffffff-0000-0000-0000-000000000001' $$,
  'no views recorded against it'
);

select throws_ok(
  $$ insert into public.story_views (story_id, user_id) values
     ('ffffffff-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111') $$,
  '42501',
  null,
  'and you cannot record a view of an expired story -- the policy''s exists() runs under your own RLS'
);


-- ============================================================
-- view_count is a trigger, never a count(*) at read time (CLAUDE.md #6).
-- ============================================================
select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

insert into public.story_views (story_id, user_id) values
  ('ffffffff-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222');

select is(
  (select view_count from public.stories where id = 'ffffffff-0000-0000-0000-000000000002'),
  1,
  'recording a view bumps the denormalized counter'
);

select is(
  (select viewed from public.get_party_stories('aaaaaaaa-0000-0000-0000-000000000001')
   where id = 'ffffffff-0000-0000-0000-000000000002'),
  true,
  'and the viewer sees it marked as watched'
);

select tests.authenticate_as('66666666-6666-6666-6666-666666666666'); -- second_host, also invited
select is(
  (select viewed from public.get_party_stories('aaaaaaaa-0000-0000-0000-000000000001')
   where id = 'ffffffff-0000-0000-0000-000000000002'),
  false,
  'another invitee has not watched it -- viewed is per-caller, from their own story_views rows'
);

select is_empty(
  $$ select 1 from public.story_views
     where user_id = '22222222-2222-2222-2222-222222222222' $$,
  'and nobody can read anyone else''s view history -- the author gets the count, not a roster'
);


-- ============================================================
-- (3) The rate limit, including the hidden-rows-still-count property.
-- ============================================================
select tests.authenticate_as('66666666-6666-6666-6666-666666666666'); -- second_host, clean slate

do $$
begin
  for i in 1..9 loop
    insert into public.stories (party_id, author_id, content_type) values
      ('aaaaaaaa-0000-0000-0000-000000000002',
       '66666666-6666-6666-6666-666666666666',
       'image/jpeg');
  end loop;
end;
$$;

select lives_ok(
  $$ insert into public.stories (id, party_id, author_id, content_type) values
     ('ffffffff-0000-0000-0000-000000000010',
      'aaaaaaaa-0000-0000-0000-000000000002',
      '66666666-6666-6666-6666-666666666666',
      'image/jpeg') $$,
  'the 10th story in an hour is fine'
);

select throws_ok(
  $$ insert into public.stories (party_id, author_id, content_type) values
     ('aaaaaaaa-0000-0000-0000-000000000002',
      '66666666-6666-6666-6666-666666666666',
      'image/jpeg') $$,
  '42501',
  null,
  'the 11th is refused -- 10 per user per hour, server-side'
);

select public.hide_story('ffffffff-0000-0000-0000-000000000010', 'test takedown');

select throws_ok(
  $$ insert into public.stories (party_id, author_id, content_type) values
     ('aaaaaaaa-0000-0000-0000-000000000002',
      '66666666-6666-6666-6666-666666666666',
      'image/jpeg') $$,
  '42501',
  null,
  'and hiding one does NOT refund the budget -- a takedown must not hand quota back to the abuser'
);

select throws_ok(
  $$ insert into public.stories (party_id, author_id, content_type) values
     ('aaaaaaaa-0000-0000-0000-000000000013',
      '66666666-6666-6666-6666-666666666666',
      'image/jpeg') $$,
  '42501',
  null,
  'the limit is per USER, not per party -- unlike chat, the resource being protected is storage'
);


-- ============================================================
-- Moderation: author or host, one-way.
-- ============================================================
select tests.authenticate_as('55555555-5555-5555-5555-555555555555'); -- blocked_user

select throws_ok(
  $$ select public.hide_story('ffffffff-0000-0000-0000-000000000002') $$,
  '42501',
  null,
  'a stranger cannot hide someone else''s story'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host of that party
select lives_ok(
  $$ select public.hide_story('ffffffff-0000-0000-0000-000000000002', 'off-topic') $$,
  'the party host can take a guest''s story down'
);

select is_empty(
  $$ select 1 from public.stories where id = 'ffffffff-0000-0000-0000-000000000002' $$,
  'hidden means hidden -- to every client role, the author included'
);


-- ============================================================
-- (4) The cleanup pipeline.
-- ============================================================
select tests.clear_authentication();
reset role;

select is(
  (select count(*)::int from public.stories
   where id = 'ffffffff-0000-0000-0000-000000000001' and hidden_at is null),
  1,
  'the expired story is still unhidden before the job runs'
);

select is(
  (select public.expire_stories() >= 1),
  true,
  'expire_stories() hides it'
);

select is(
  (select hidden_reason from public.stories where id = 'ffffffff-0000-0000-0000-000000000001'),
  'expired',
  'with reason "expired", and hidden_by null -- there is no user behind an expiry'
);

-- The 9 unconfirmed rows the rate-limit loop created are exactly the abandoned
-- case: a path reserved, no bytes confirmed. Aged past the hour so the sweep
-- can see them.
update public.stories
set created_at = now() - interval '2 hours',
    expires_at = now() - interval '1 hour'
where media_uploaded_at is null and hidden_at is null;

select is(
  (select public.expire_stories() >= 9),
  true,
  'and it also collects abandoned uploads -- rows that reserved a path and never confirmed'
);

select is(
  (select count(*)::int from public.stories
   where hidden_reason = 'abandoned' and media_uploaded_at is null),
  9,
  'those are marked "abandoned", not "expired" -- different failure, different label'
);

select is(
  (select public.purge_story_media()),
  2,
  'purge_story_media() queues exactly the hidden rows whose bytes are still in the bucket -- abandoned rows with no object are not requested'
);

select is(
  (select count(*)::int from public.story_media_purges where completed_at is null),
  2,
  'and each one gets an open ledger row, so "is anything still owed to the bucket?" is a query'
);

select isnt_empty(
  $$ select 1 from public.story_media_purges q
     join net.http_request_queue r on r.id = q.request_id
     where r.method = 'DELETE'
     and r.url like '%/object/story-media' $$,
  'carrying a real DELETE to the Storage API -- pg_net dispatches it on commit, which is why the bytes are proved gone in scripts/verify_story_lifecycle.sh instead of here'
);

select is(
  (select count(*)::int from public.stories where media_deleted_at is not null),
  0,
  'and NOTHING is marked deleted yet -- only reconcile_story_media_purges(), reading the HTTP response back, may claim that'
);

select is(
  (select public.purge_story_media()),
  0,
  'a second sweep re-requests nothing while the first is still in flight'
);


-- ============================================================
-- Anonymous sessions. There is no signed-out audience for a story.
-- ============================================================
select tests.clear_authentication();

select throws_ok(
  $$ select 1 from public.stories $$,
  '42501',
  null,
  'anon has no select grant on stories at all'
);

select throws_ok(
  $$ select 1 from public.get_party_stories('aaaaaaaa-0000-0000-0000-000000000002') $$,
  '42501',
  null,
  'anon cannot execute get_party_stories'
);

select throws_ok(
  $$ select 1 from public.get_story_rails() $$,
  '42501',
  null,
  'anon cannot execute get_story_rails'
);

select throws_ok(
  $$ select public.run_story_cleanup() $$,
  '42501',
  null,
  'and the cleanup is not client-callable -- it holds the service key'
);

select * from finish();
rollback;
