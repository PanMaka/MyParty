-- Phase 25: a party's cover goes in through the same handshake as post media,
-- and only its host can start it.
--
-- PARTY_PRIVATE 'aaaaaaaa-…0001' and PARTY_PUBLIC 'aaaaaaaa-…0002' are hosted
-- by host. Party 'aaaaaaaa-…0013' is hosted by second_host with host INVITED,
-- which makes it the fixture where host can see a party and still must not
-- set its cover -- refusing on an invisible party would prove nothing about
-- the host rule.
begin;
set search_path to public, extensions;
select plan(17);

-- ===========================================================================
-- Shape: both definer, both pinned (CLAUDE.md #3)
-- ===========================================================================
select is(
  (select prosecdef from pg_proc where oid = 'public.party_cover_upload_target(uuid)'::regprocedure),
  true,
  'party_cover_upload_target is SECURITY DEFINER'
);

select is(
  (select prosecdef from pg_proc where oid = 'public.confirm_party_cover(uuid)'::regprocedure),
  true,
  'confirm_party_cover is SECURITY DEFINER -- it reads storage.objects'
);

select is(
  (select array_agg(c order by c) from pg_proc, unnest(proconfig) c
   where oid in ('public.party_cover_upload_target(uuid)'::regprocedure,
                 'public.confirm_party_cover(uuid)'::regprocedure)),
  array['search_path=""', 'search_path=""'],
  'both pin an empty search_path'
);

-- ===========================================================================
-- Who gets a path
-- ===========================================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is(
  public.party_cover_upload_target('aaaaaaaa-0000-0000-0000-000000000001'),
  'aaaaaaaa-0000-0000-0000-000000000001/cover',
  'the host is handed the path inside the party''s own folder'
);

-- THE headline negative: host can SEE party 0013 (invited), so the only term
-- refusing this is the host check.
select throws_ok(
  $$ select public.party_cover_upload_target('aaaaaaaa-0000-0000-0000-000000000013') $$,
  '42501',
  null,
  'an invited guest who can see the party still cannot set its cover'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select throws_ok(
  $$ select public.party_cover_upload_target('aaaaaaaa-0000-0000-0000-000000000002') $$,
  '42501',
  null,
  'nor can a stranger on a public party'
);

-- ===========================================================================
-- Confirmation does not take the client's word
-- ===========================================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select throws_ok(
  $$ select public.confirm_party_cover('aaaaaaaa-0000-0000-0000-000000000001') $$,
  'P0002',
  null,
  'confirm refuses when no object was uploaded'
);

select is(
  (select cover_path from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  null,
  'and leaves cover_path unset'
);

-- The bytes, put where the path says, as the owner: the bucket has no INSERT
-- policy any client role could use, which is why the real upload is signed.
reset role;
insert into storage.objects (bucket_id, name, owner)
values ('party-covers', 'aaaaaaaa-0000-0000-0000-000000000001/cover',
        '11111111-1111-1111-1111-111111111111');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select throws_ok(
  $$ select public.confirm_party_cover('aaaaaaaa-0000-0000-0000-000000000001') $$,
  '42501',
  null,
  'bytes being present does not let a non-host confirm them'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is(
  public.confirm_party_cover('aaaaaaaa-0000-0000-0000-000000000001'),
  'aaaaaaaa-0000-0000-0000-000000000001/cover',
  'confirm succeeds once the object really exists'
);

select is(
  (select cover_path from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  'aaaaaaaa-0000-0000-0000-000000000001/cover',
  'and cover_path now points at it'
);

-- One-shot: a second signature would let the picture swap under guests who
-- have already seen it.
select throws_ok(
  $$ select public.party_cover_upload_target('aaaaaaaa-0000-0000-0000-000000000001') $$,
  '42501',
  null,
  'a party that has a cover is not handed a second upload path'
);

-- ===========================================================================
-- A cancelled party gets nothing
-- ===========================================================================
reset role;
update public.parties set status = 'cancelled'
where id = 'aaaaaaaa-0000-0000-0000-000000000002';
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select throws_ok(
  $$ select public.party_cover_upload_target('aaaaaaaa-0000-0000-0000-000000000002') $$,
  '42501',
  null,
  'a cancelled party cannot be given a cover'
);

-- ===========================================================================
-- Privileges
-- ===========================================================================
select tests.clear_authentication();
set local role anon;

select throws_ok(
  $$ select public.party_cover_upload_target('aaaaaaaa-0000-0000-0000-000000000001') $$,
  '42501',
  null,
  'anon cannot execute the target'
);

select throws_ok(
  $$ select public.confirm_party_cover('aaaaaaaa-0000-0000-0000-000000000001') $$,
  '42501',
  null,
  'anon cannot execute the confirmation'
);

reset role;

-- ===========================================================================
-- The bucket's limits
-- ===========================================================================
select is(
  (select file_size_limit from storage.buckets where id = 'party-covers'),
  5242880::bigint,
  'party-covers refuses objects over 5MB'
);

select is(
  (select allowed_mime_types from storage.buckets where id = 'party-covers'),
  array['image/jpeg', 'image/png'],
  'party-covers accepts JPEG and PNG only -- the two formats the picker emits'
);

select * from finish();
rollback;
