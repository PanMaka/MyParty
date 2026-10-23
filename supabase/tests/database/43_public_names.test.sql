-- Phase 49: names are public to signed-in users, and optional
-- (20261022211326).
--
-- What has to hold:
--
--   A. A signed-in stranger reads a SHOWN name. Nobody but the owner reads an
--      unshown one. shown_at and updated_at are refused to every client, and
--      anon reads nothing.
--   B. A block hides the name in both directions, through the profiles row
--      policy rather than a copy of the rule. The profile-plus-name read the
--      client makes (a left join, as PostgREST's embed) keeps the profile
--      and drops only the name.
--   C. acknowledge_name_shown publishes the name, is idempotent, and is a
--      no-op without one.
--   D. set_my_names clears with both null or blank, still refuses half a name,
--      and stamps shown_at, including on a row that was unshown.
--   E. complete_onboarding accepts no names.
--   F. Pending deletion hides the name and a restore brings it back. Erasure
--      leaves none. The export carries name_shown_at.
--
-- Personas (seed.sql): host 1111, invitee 2222, friend_not_invited 3333,
-- stranger 4444, blocked_user 5555, second_host 6666. The names below are this
-- file's own fixtures, written as postgres; seed's names are overwritten.
begin;
set search_path to public, extensions;
select plan(42);


-- ===========================================================================
-- Fixtures (as postgres)
-- ===========================================================================
insert into public.user_names (user_id, first_name, last_name, shown_at) values
  ('11111111-1111-1111-1111-111111111111', 'Host',    'Shown',    now()),
  ('22222222-2222-2222-2222-222222222222', 'Invitee', 'Shown',    now()),
  ('33333333-3333-3333-3333-333333333333', 'Friend',  'Shown',    now()),
  ('55555555-5555-5555-5555-555555555555', 'Blocked', 'Shown',    now()),
  ('66666666-6666-6666-6666-666666666666', 'Second',  'Unshown',  null)
on conflict on constraint user_names_pkey
do update set first_name = excluded.first_name,
              last_name  = excluded.last_name,
              shown_at   = excluded.shown_at;

delete from public.user_names where user_id = '44444444-4444-4444-4444-444444444444';

-- The host blocks blocked_user. is_blocked is symmetric, so each side's
-- profile is hidden from the other.
insert into public.blocks (blocker_id, blocked_id)
values ('11111111-1111-1111-1111-111111111111', '55555555-5555-5555-5555-555555555555');

-- Fresh, un-onboarded sign-ups for E.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select '00000000-0000-0000-0000-000000000000', v.id::uuid, 'authenticated', 'authenticated',
       v.email, crypt('password123', gen_salt('bf')), current_timestamp,
       '{"provider":"email","providers":["email"]}', '{}'::jsonb, current_timestamp, current_timestamp
from (values
  ('e49e0000-0000-0000-0000-000000000001', 'p49_a@myparty.local'),
  ('e49e0000-0000-0000-0000-000000000002', 'p49_b@myparty.local'),
  ('e49e0000-0000-0000-0000-000000000003', 'p49_c@myparty.local')
) v(id, email);

-- The name a caller sees for a user, through the same shape as the client's
-- profiles?select=...,user_names(first_name,last_name): the profile row, with
-- the name or null. Null overall when the profile itself is hidden.
create function pg_temp.name_seen(p_user_id uuid) returns text
language sql as $$
  select coalesce(n.first_name || ' ' || n.last_name, '<no name>')
  from public.profiles p
  left join public.user_names n on n.user_id = p.id
  where p.id = p_user_id;
$$;
grant execute on function pg_temp.name_seen(uuid) to authenticated, anon;


-- ===========================================================================
-- A. Who reads a name.
-- ===========================================================================
select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select is(pg_temp.name_seen('22222222-2222-2222-2222-222222222222'), 'Invitee Shown',
  'a signed-in stranger reads a shown name');
select is(pg_temp.name_seen('66666666-6666-6666-6666-666666666666'), '<no name>',
  'NEGATIVE: an unshown name reaches nobody else, and the profile is still there');
select is_empty(
  $$ select 1 from public.user_names where user_id = '66666666-6666-6666-6666-666666666666' $$,
  'NEGATIVE: not by a direct read either');
select throws_ok($$ select shown_at from public.user_names $$, '42501', null,
  'NEGATIVE: shown_at is not readable by another user');
select throws_ok($$ select updated_at from public.user_names $$, '42501', null,
  'NEGATIVE: nor updated_at');
select throws_ok($$ select * from public.user_names $$, '42501', null,
  'NEGATIVE: so select * is refused, not silently narrowed');

select tests.authenticate_as('66666666-6666-6666-6666-666666666666'); -- second_host, unshown
select is(
  (select first_name || ' ' || last_name from public.user_names where user_id = '66666666-6666-6666-6666-666666666666'),
  'Second Unshown', 'the owner still reads their own unshown name');
select is(
  (select row(first_name, last_name, shown)::text from public.get_my_names()),
  '(Second,Unshown,f)', 'get_my_names reports it as not shown: the notice is owed');
select throws_ok($$ select shown_at from public.user_names $$, '42501', null,
  'NEGATIVE: not even the owner reads shown_at off the table; get_my_names is the door');

select tests.clear_authentication(); -- anon
select throws_ok($$ select first_name from public.user_names $$, '42501', null,
  'NEGATIVE: signed out reads no name');
select throws_ok($$ select * from public.get_my_names() $$, '42501', null,
  'NEGATIVE: and cannot call get_my_names');
select throws_ok($$ select public.acknowledge_name_shown() $$, '42501', null,
  'NEGATIVE: or acknowledge_name_shown');


-- ===========================================================================
-- B. Blocks, both directions.
-- ===========================================================================
select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger
select is(pg_temp.name_seen('55555555-5555-5555-5555-555555555555'), 'Blocked Shown',
  'CONTROL: a third party reads blocked_user''s name');

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host, the blocker
select is_empty(
  $$ select 1 from public.user_names where user_id = '55555555-5555-5555-5555-555555555555' $$,
  'NEGATIVE: the blocker reads nothing of the blocked account''s name');

select tests.authenticate_as('55555555-5555-5555-5555-555555555555'); -- blocked_user
select is_empty(
  $$ select 1 from public.user_names where user_id = '11111111-1111-1111-1111-111111111111' $$,
  'NEGATIVE: nor the blocked account of the blocker''s');
select is(
  (select first_name from public.user_names where user_id = '55555555-5555-5555-5555-555555555555'),
  'Blocked', 'while still reading their own');


-- ===========================================================================
-- C. acknowledge_name_shown.
-- ===========================================================================
select tests.authenticate_as('66666666-6666-6666-6666-666666666666');
select lives_ok($$ select public.acknowledge_name_shown() $$, 'acknowledge_name_shown runs');
select is((select shown from public.get_my_names()), true, 'and the name is now shown');
select lives_ok($$ select public.acknowledge_name_shown() $$, 'a second call is not an error');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger, no name
select is(pg_temp.name_seen('66666666-6666-6666-6666-666666666666'), 'Second Unshown',
  'a stranger now reads it');
select lives_ok($$ select public.acknowledge_name_shown() $$, 'acknowledging without a name is a no-op');
select is_empty($$ select * from public.get_my_names() $$, 'and creates no row');


-- ===========================================================================
-- D. set_my_names: clearing, half names, stamping.
-- ===========================================================================
select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee
select lives_ok($$ select public.set_my_names(null, null) $$, 'set_my_names(null, null) runs');
select is_empty($$ select * from public.get_my_names() $$, 'and deletes the row');

select throws_ok($$ select public.set_my_names('Ana', null) $$, '22023', 'invalid name',
  'NEGATIVE: half a name is still refused');
select throws_ok($$ select public.set_my_names('  ', 'Pap') $$, '22023', 'invalid name',
  'NEGATIVE: a blank half too');

select public.set_my_names('Ana', 'Pap');
select is((select row(first_name, last_name, shown)::text from public.get_my_names()), '(Ana,Pap,t)',
  'a new name is shown at once: the copy on both screens says so');
select lives_ok($$ select public.set_my_names('', '   ') $$, 'two blanks clear as well');
select is_empty($$ select * from public.get_my_names() $$, 'and leave no row');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444');
select is(pg_temp.name_seen('22222222-2222-2222-2222-222222222222'), '<no name>',
  'a cleared name is gone for everyone else');

-- An unshown row saved from Edit profile becomes shown.
reset role;
update public.user_names set shown_at = null where user_id = '11111111-1111-1111-1111-111111111111';
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');
select public.set_my_names('Host', 'Edited');
select is((select shown from public.get_my_names()), true,
  'saving names on an unshown row shows them');


-- ===========================================================================
-- E. Onboarding without names.
-- ===========================================================================
select tests.authenticate_as('e49e0000-0000-0000-0000-000000000001');
select lives_ok($$ select public.complete_onboarding('p49.none', null, null) $$,
  'complete_onboarding runs with no names');
select is_empty($$ select * from public.get_my_names() $$, 'and writes no row');
select isnt((select onboarding_completed_at from public.get_my_settings()), null::timestamptz,
  'but completes onboarding');

select tests.authenticate_as('e49e0000-0000-0000-0000-000000000002');
select throws_ok($$ select public.complete_onboarding('p49.half', 'Ana', null) $$, '22023', 'invalid name',
  'NEGATIVE: half a name at onboarding is refused');
select lives_ok($$ select public.complete_onboarding('p49.blank', ' ', '') $$,
  'blank fields count as no name');

select tests.authenticate_as('e49e0000-0000-0000-0000-000000000003');
select public.complete_onboarding('p49.named', 'Νίκη', 'Ρήγα');
select is((select row(first_name, last_name, shown)::text from public.get_my_names()), '(Νίκη,Ρήγα,t)',
  'a name given at onboarding is shown from the start');


-- ===========================================================================
-- F. Pending deletion, restore, erasure, export.
-- ===========================================================================
select tests.authenticate_as('33333333-3333-3333-3333-333333333333'); -- friend_not_invited
select lives_ok($$ select public.request_account_deletion() $$, 'request_account_deletion runs');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444');
select is_empty(
  $$ select 1 from public.user_names where user_id = '33333333-3333-3333-3333-333333333333' $$,
  'NEGATIVE: a pending account''s name is hidden');

select tests.authenticate_as('33333333-3333-3333-3333-333333333333');
select public.cancel_account_deletion();
select tests.authenticate_as('44444444-4444-4444-4444-444444444444');
select is(pg_temp.name_seen('33333333-3333-3333-3333-333333333333'), 'Friend Shown',
  'restoring brings it back: it was kept through the grace period');

reset role;
update public.profiles set deleted_at = now() - interval '31 days'
where id = '33333333-3333-3333-3333-333333333333';
select public.complete_account_erasure('33333333-3333-3333-3333-333333333333');
select tests.authenticate_as('44444444-4444-4444-4444-444444444444');
select is(pg_temp.name_seen('33333333-3333-3333-3333-333333333333'), '<no name>',
  'an erased account''s tombstone profile shows no name');

select tests.authenticate_as('11111111-1111-1111-1111-111111111111');
select isnt(public.export_account_data() ->> 'name_shown_at', null, 'the export carries name_shown_at');

select * from finish();
rollback;
