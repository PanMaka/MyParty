-- Phase 16c: only a host posts, and a media post is invisible until its bytes
-- are really in the bucket.
--
-- The two rules are independent and both are only interesting in the refusal
-- case, so both are asserted negatively as well as positively.
--
-- PARTY_PRIVATE 'aaaaaaaa-…0001' and PARTY_PUBLIC 'aaaaaaaa-…0002', both
-- hosted by host. Party 'aaaaaaaa-…0013' is hosted by second_host, with host
-- invited to it -- which makes it the one fixture where a user can SEE a party
-- and still not post to it for a reason other than visibility.
begin;
set search_path to public, extensions;
select plan(23);

-- ===========================================================================
-- The helper
-- ===========================================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is(
  public.is_party_host('aaaaaaaa-0000-0000-0000-000000000002'),
  true,
  'is_party_host is true for the party you host'
);

select is(
  public.is_party_host('aaaaaaaa-0000-0000-0000-000000000013'),
  false,
  'and false for a party you were merely invited to'
);

select is(
  (select prosecdef from pg_proc where oid = 'public.is_party_host(uuid)'::regprocedure),
  true,
  'is_party_host is SECURITY DEFINER -- it asks about the party, not the viewer'
);

select is(
  (select proconfig from pg_proc where oid = 'public.is_party_host(uuid)'::regprocedure),
  array['search_path=""'],
  'is_party_host pins an empty search_path (CLAUDE.md #3)'
);

-- ===========================================================================
-- Host-only posting
-- ===========================================================================
select lives_ok(
  $$ insert into public.party_posts (id, party_id, author_id, body) values
     ('bbbbbbbb-0000-0000-0000-0000000000a1',
      'aaaaaaaa-0000-0000-0000-000000000002',
      '11111111-1111-1111-1111-111111111111',
      'the host posting on their own party') $$,
  'the host can post to their own party'
);

-- THE headline negative, and the reason it is on party 0013 rather than a
-- party this user cannot see: host is INVITED here, so can_access_party is
-- true and the only term refusing the write is is_party_host. On an
-- inaccessible party the insert would fail either way and prove nothing.
select throws_ok(
  $$ insert into public.party_posts (party_id, author_id, body) values
     ('aaaaaaaa-0000-0000-0000-000000000013',
      '11111111-1111-1111-1111-111111111111',
      'posting on a party I was invited to') $$,
  '42501',
  null,
  'an INVITED guest cannot post -- can_access_party passes and is_party_host refuses'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select ok(
  public.can_access_party('aaaaaaaa-0000-0000-0000-000000000002'),
  'a stranger can still access a public party'
);

select throws_ok(
  $$ insert into public.party_posts (party_id, author_id, body) values
     ('aaaaaaaa-0000-0000-0000-000000000002',
      '44444444-4444-4444-4444-444444444444',
      'a guest posting on a public party') $$,
  '42501',
  null,
  'but cannot post to it'
);

-- Guests keep the rest of the wall. Only AUTHORSHIP narrowed; the
-- conversation around a post did not.
select lives_ok(
  $$ insert into public.post_likes (post_id, user_id) values
     ('bbbbbbbb-0000-0000-0000-0000000000a1',
      '44444444-4444-4444-4444-444444444444') $$,
  'a guest can still like a host post'
);

select lives_ok(
  $$ insert into public.post_comments (id, post_id, author_id, body) values
     ('cccccccc-0000-0000-0000-0000000000a1',
      'bbbbbbbb-0000-0000-0000-0000000000a1',
      '44444444-4444-4444-4444-444444444444',
      'still allowed to reply') $$,
  'and still comment on it -- only authorship narrowed, not the conversation'
);

-- ===========================================================================
-- media_path is not client-writable
-- ===========================================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

-- The sharp edge this closes: the grant used to include media_path, while the
-- post-media bucket has no INSERT policy at all -- so a client could name a
-- storage key it could not possibly fill. Every media post was a dangling
-- reference by construction.
select throws_ok(
  $$ insert into public.party_posts (party_id, author_id, body, media_path) values
     ('aaaaaaaa-0000-0000-0000-000000000002',
      '11111111-1111-1111-1111-111111111111',
      'aiming at a path of my choosing',
      'aaaaaaaa-0000-0000-0000-000000000099/forged.jpg') $$,
  '42501',
  null,
  'a client cannot write media_path -- the column carries no insert grant'
);

insert into public.party_posts (id, party_id, author_id, body, media_type) values
  ('bbbbbbbb-0000-0000-0000-0000000000a2',
   'aaaaaaaa-0000-0000-0000-000000000002',
   '11111111-1111-1111-1111-111111111111',
   'a photo of the venue',
   'image/jpeg');

-- Derived, deterministic, and inside the party's own folder -- which is what
-- makes it impossible to aim an upload at another party.
--
-- Read as the OWNER, with RLS out of the way. Through the SELECT policy this
-- would come back NULL for the honest reason asserted four tests down: the row
-- is a pending upload and therefore invisible, to its author included. Reading
-- it here separates "the trigger computed the path" from "the policy shows the
-- row", which are two different claims this file makes separately.
reset role;

select is(
  (select media_path from public.party_posts
   where id = 'bbbbbbbb-0000-0000-0000-0000000000a2'),
  'aaaaaaaa-0000-0000-0000-000000000002/bbbbbbbb-0000-0000-0000-0000000000a2.jpg',
  'media_path is derived by the trigger as {party_id}/{post_id}.{ext}'
);

select is(
  (select media_path from public.party_posts
   where id = 'bbbbbbbb-0000-0000-0000-0000000000a1'),
  null,
  'a text-only post gets no path at all'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

-- ===========================================================================
-- A media post is invisible until confirmed
-- ===========================================================================
-- Asserted as the AUTHOR, deliberately. A pending post is hidden from
-- everyone including the person who created it, which is exactly what makes
-- an abandoned handshake safe: the client that died leaves a row nobody can
-- see rather than a broken frame on every phone in the party.
select is_empty(
  $$ select 1 from public.party_posts
     where id = 'bbbbbbbb-0000-0000-0000-0000000000a2' $$,
  'a media post with no confirmed upload is invisible, even to its author'
);

select isnt_empty(
  $$ select 1 from public.party_posts
     where id = 'bbbbbbbb-0000-0000-0000-0000000000a1' $$,
  'while the text-only post beside it is visible -- the gate is media, not posting'
);

select is(
  public.post_upload_target('bbbbbbbb-0000-0000-0000-0000000000a2'),
  'aaaaaaaa-0000-0000-0000-000000000002/bbbbbbbb-0000-0000-0000-0000000000a2.jpg',
  'post_upload_target hands the author the path its bytes are expected at'
);

-- Definer, so it can answer about a row the SELECT policy is currently hiding
-- -- which is every pending post, by construction.
select is(
  (select prosecdef from pg_proc where oid = 'public.post_upload_target(uuid)'::regprocedure),
  true,
  'post_upload_target is SECURITY DEFINER -- the row it reads is hidden by policy'
);

select throws_ok(
  $$ select public.post_upload_target('bbbbbbbb-0000-0000-0000-0000000000a1') $$,
  '42501',
  null,
  'a text-only post has no upload target'
);

-- The client's word is not evidence. Skipping the PUT and calling confirm
-- would otherwise publish a post that renders as a broken frame everywhere,
-- and an unfixable one -- post_upload_target refuses to re-sign a confirmed
-- row.
select throws_ok(
  $$ select public.confirm_post_upload('bbbbbbbb-0000-0000-0000-0000000000a2') $$,
  'P0002',
  null,
  'confirm refuses while the object is not actually in the bucket'
);

select is_empty(
  $$ select 1 from public.party_posts
     where id = 'bbbbbbbb-0000-0000-0000-0000000000a2' $$,
  'and the post is still invisible after the refused confirm'
);

-- Put the bytes where the row says they are, as the owner: storage.objects has
-- RLS on and post-media has no policy any client role can write through, which
-- is the whole reason the real upload goes via a signed URL.
reset role;
insert into storage.objects (bucket_id, name, owner)
values ('post-media',
        'aaaaaaaa-0000-0000-0000-000000000002/bbbbbbbb-0000-0000-0000-0000000000a2.jpg',
        '11111111-1111-1111-1111-111111111111');

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select lives_ok(
  $$ select public.confirm_post_upload('bbbbbbbb-0000-0000-0000-0000000000a2') $$,
  'confirm succeeds once the object really exists'
);

select isnt_empty(
  $$ select 1 from public.party_posts
     where id = 'bbbbbbbb-0000-0000-0000-0000000000a2' $$,
  'and the media post becomes visible at that moment, and only then'
);

-- One-shot. A second signature would let the media under a post swap after
-- people had already seen it.
select throws_ok(
  $$ select public.post_upload_target('bbbbbbbb-0000-0000-0000-0000000000a2') $$,
  '42501',
  null,
  'the upload target is one-shot -- a confirmed post cannot be re-signed'
);

select tests.clear_authentication();

select * from finish();
rollback;
