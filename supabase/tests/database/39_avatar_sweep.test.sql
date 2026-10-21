-- Phase 44: the hourly avatar sweep (20261021094728), the safety net under
-- "Remove photo" and avatar replacement.
--
-- What has to hold: stale = avatars bucket, older than ten minutes, no
-- profile's avatar_path -- so the current avatar, an upload still in flight
-- and another bucket's object are all left alone, while a removed or replaced
-- avatar and a folder with no profile are collected. Neither function is a
-- client's. The bytes leaving the disk are a script's to check (gotcha 7: the
-- DELETE only dispatches after COMMIT, and this file rolls back).
begin;
set search_path to public, extensions;
select plan(8);

-- Fixtures (as postgres). The host has a current avatar; everything else is
-- metadata rows only, which is all the stale query reads.
update public.profiles set avatar_path = '11111111-1111-1111-1111-111111111111/current.jpg'
where id = '11111111-1111-1111-1111-111111111111';

insert into storage.objects (bucket_id, name, owner, created_at) values
  ('avatars', '11111111-1111-1111-1111-111111111111/current.jpg',
   '11111111-1111-1111-1111-111111111111', now() - interval '2 days'),
  -- what "Remove photo" or a replacement leaves when the client's delete fails
  ('avatars', '11111111-1111-1111-1111-111111111111/removed.jpg',
   '11111111-1111-1111-1111-111111111111', now() - interval '1 day'),
  -- uploaded a moment ago; avatar_path is written second
  ('avatars', '11111111-1111-1111-1111-111111111111/in-flight.jpg',
   '11111111-1111-1111-1111-111111111111', now() - interval '1 minute'),
  -- a folder whose profile does not exist
  ('avatars', 'ffffffff-ffff-ffff-ffff-ffffffffffff/orphan.jpg',
   null, now() - interval '1 hour'),
  -- someone else's bucket: not ours to judge
  ('party-covers', 'eeeeeeee-0000-0000-0000-000000000001/not-an-avatar',
   '11111111-1111-1111-1111-111111111111', now() - interval '1 day');

select set_eq(
  $$ select n from public.stale_avatar_objects() n
     where n like '11111111-%' or n like 'ffffffff-%' or n like 'eeeeeeee-%' $$,
  $$ values ('11111111-1111-1111-1111-111111111111/removed.jpg'),
            ('ffffffff-ffff-ffff-ffff-ffffffffffff/orphan.jpg') $$,
  'stale = the removed avatar and the orphan folder -- not the current avatar, not the in-flight upload, not another bucket');

select is(
  (select count(*)::int from public.stale_avatar_objects(1)), 1,
  'the limit is honoured, so one run sends one bounded request');

-- Removing the avatar makes the current object stale too, which is the point.
update public.profiles set avatar_path = null
where id = '11111111-1111-1111-1111-111111111111';
select ok(
  '11111111-1111-1111-1111-111111111111/current.jpg' in (select public.stale_avatar_objects()),
  'once avatar_path is nulled, the formerly current avatar is collectable');

select ok(
  public.sweep_avatars() >= 3,
  'the sweep asks Storage to delete them (dispatched after COMMIT; the bytes are a script''s to check)');

select is(
  (select schedule from cron.job where jobname = 'avatar-sweep'),
  '47 * * * *', 'avatar-sweep is scheduled hourly, off party-cover-sweep''s minute');
select is(
  (select command from cron.job where jobname = 'avatar-sweep'),
  ' select public.sweep_avatars() ', 'and runs sweep_avatars');

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host
select throws_ok($$ select * from public.stale_avatar_objects() $$, '42501', null,
  'NEGATIVE: the all-users stale list is not a client function');
select throws_ok($$ select public.sweep_avatars() $$, '42501', null,
  'NEGATIVE: nor is the sweep');

select * from finish();
rollback;
