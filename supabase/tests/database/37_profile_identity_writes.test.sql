-- Phase 44: profile writes through functions (20261021094726) and their
-- export and erasure (20261021094727).
--
-- What has to hold:
--
--   A. The grant: username, the three consents, onboarding_completed_at and
--      created_at refuse a direct UPDATE; the eleven listed columns still take
--      one.
--   B. Consents: the setters write the boolean, stamp *_consent_at on
--      false -> true only, KEEP the stamp on withdrawal, refuse granting during
--      a pending deletion but always accept withdrawing; user_consents is
--      owner-read-only.
--   C. The username rule, as a list both ways.
--   D. complete_onboarding: runs once, validates, writes the names, stamps the
--      server clock, and does NOT start the cooldown.
--   E. change_username: cooldown, reservation (blocks others for 14 days,
--      including through check_username_available and complete_onboarding,
--      then lapses), case-insensitive collisions, case-only change, unchanged
--      refused, pending deletion refused; username_changes has no client door.
--   F. Export carries the change and the consent times; erasure deletes the
--      rows and releases the reservation.
--
-- Personas: host 1111, friend_not_invited 3333, stranger 4444. Fresh sign-ups
-- e44e...01 (the subject of D-F) and e44e...02 go through handle_new_user, so
-- they start with a placeholder and no onboarding.
begin;
set search_path to public, extensions;
select plan(64);


-- ===========================================================================
-- Fixtures (as postgres)
-- ===========================================================================
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select '00000000-0000-0000-0000-000000000000', v.id::uuid, 'authenticated', 'authenticated',
       v.email, crypt('password123', gen_salt('bf')), current_timestamp,
       '{"provider":"email","providers":["email"]}', '{}'::jsonb, current_timestamp, current_timestamp
from (values
  ('e44e0000-0000-0000-0000-000000000001', 'p44_a@myparty.local'),
  ('e44e0000-0000-0000-0000-000000000002', 'p44_b@myparty.local')
) v(id, email);


-- ===========================================================================
-- A. The grant.
-- ===========================================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select throws_ok(
  $$ update public.profiles set username = 'renamed' where id = '11111111-1111-1111-1111-111111111111' $$,
  '42501', null, 'username refuses a direct UPDATE');
select throws_ok(
  $$ update public.profiles set location_consent = true where id = '11111111-1111-1111-1111-111111111111' $$,
  '42501', null, 'location_consent refuses a direct UPDATE');
select throws_ok(
  $$ update public.profiles set push_consent = true where id = '11111111-1111-1111-1111-111111111111' $$,
  '42501', null, 'push_consent refuses a direct UPDATE');
select throws_ok(
  $$ update public.profiles set analytics_consent = true where id = '11111111-1111-1111-1111-111111111111' $$,
  '42501', null, 'analytics_consent refuses a direct UPDATE');
select throws_ok(
  $$ update public.profiles set onboarding_completed_at = now() where id = '11111111-1111-1111-1111-111111111111' $$,
  '42501', null, 'onboarding_completed_at refuses a direct UPDATE');
select throws_ok(
  $$ update public.profiles set created_at = '2020-01-01' where id = '11111111-1111-1111-1111-111111111111' $$,
  '42501', null, 'created_at refuses a direct UPDATE -- "member since" is not forgeable');

select lives_ok(
  $$ update public.profiles
     set bio = 'still writable', map_visibility = 'public', invite_policy = 'anyone',
         dm_policy = 'everyone', notify_nearby = true, notify_radius_meters = 1000,
         notify_daily_cap = 3, notification_tz = 'Europe/Athens',
         quiet_hours_start = '23:00', quiet_hours_end = '08:00'
     where id = '11111111-1111-1111-1111-111111111111' $$,
  'every column the client PATCHes today still takes a direct UPDATE (avatar_path: 14_profile_and_party_media)');
select is(
  (select bio from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'still writable',
  'and the write landed');


-- ===========================================================================
-- B. Consents.
-- ===========================================================================
select lives_ok($$ select public.set_location_consent(true) $$, 'set_location_consent(true) runs');
select is(
  (select location_consent from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  true, 'it sets the boolean');
select isnt(
  (select location_consent_at from public.user_consents where user_id = '11111111-1111-1111-1111-111111111111'),
  null, 'and stamps location_consent_at');

reset role;
-- Backdate the stamp so "unchanged" cannot pass by being the same now().
update public.user_consents set location_consent_at = '2026-01-01 00:00+00'
where user_id = '11111111-1111-1111-1111-111111111111';
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');

select public.set_location_consent(true);
select is(
  (select location_consent_at from public.user_consents where user_id = '11111111-1111-1111-1111-111111111111'),
  '2026-01-01 00:00+00'::timestamptz,
  'a repeated true while already true keeps the moment consent was GIVEN');

select public.set_location_consent(false);
select is(
  (select location_consent from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  false, 'false withdraws');
select is(
  (select location_consent_at from public.user_consents where user_id = '11111111-1111-1111-1111-111111111111'),
  '2026-01-01 00:00+00'::timestamptz,
  'and KEEPS the stamp (Art. 7(1): the record that consent existed for what already happened)');

select public.set_location_consent(true);
select ok(
  (select location_consent_at from public.user_consents where user_id = '11111111-1111-1111-1111-111111111111')
    > now() - interval '1 minute',
  'giving it again after a withdrawal restamps');

select lives_ok($$ select public.set_push_consent(true) $$, 'set_push_consent(true) runs');
select isnt(
  (select push_consent_at from public.user_consents where user_id = '11111111-1111-1111-1111-111111111111'),
  null, 'and stamps push_consent_at');
select throws_ok($$ select public.set_push_consent(null) $$, '22023', null, 'NULL is not an answer');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger
select is_empty(
  $$ select 1 from public.user_consents where user_id = '11111111-1111-1111-1111-111111111111' $$,
  'NEGATIVE: a stranger reads nothing of the host''s consent times');

select tests.clear_authentication(); -- anon
select throws_ok($$ select 1 from public.user_consents $$, '42501', null, 'anon holds no grant on user_consents');
select throws_ok($$ select public.set_location_consent(true) $$, '42501', null, 'anon cannot call the setter');

-- A pending deletion: granting is refused, withdrawing is not.
select tests.authenticate_as('33333333-3333-3333-3333-333333333333'); -- friend_not_invited
select public.request_account_deletion();
select throws_ok($$ select public.set_location_consent(true) $$, '42501', 'account is scheduled for deletion',
  'location consent cannot be turned back on during the grace period');
select throws_ok($$ select public.set_push_consent(true) $$, '42501', 'account is scheduled for deletion',
  'nor push consent');
select lives_ok($$ select public.set_push_consent(false) $$, 'withdrawing is always accepted');


-- ===========================================================================
-- C. The rule.
-- ===========================================================================
reset role;
select is(
  (select array_agg(v order by v) from unnest(array[
     'abc', 'a.b', 'a_b', 'Maria.K', '___', 'a.b.c', 'x1234567890123456789012345678y'
   ]) v where not public.username_is_valid(v)),
  null,
  'valid: 3-30 of [A-Za-z0-9_.], dots inside and apart, mixed case');
select is(
  (select array_agg(v order by v) from unnest(array[
     'ab', '.abc', 'abc.', 'a..b', 'has space', 'ελληνικά', 'deleted_x', 'Deleted_bob',
     'x12345678901234567890123456789z', 'bad-dash', ''
   ]) v where public.username_is_valid(v)),
  null,
  'invalid: too short/long, leading/trailing/double dot, space, non-ASCII, dash, deleted_ in any case');
select ok(not public.username_is_valid(null), 'and NULL');


-- ===========================================================================
-- D. complete_onboarding (fresh sign-up 01).
-- ===========================================================================
select tests.authenticate_as('e44e0000-0000-0000-0000-000000000001');

select throws_ok($$ select public.change_username('early.bird') $$, '42501', 'onboarding not complete',
  'change_username is for after onboarding');
select throws_ok($$ select public.complete_onboarding('a..b', 'Ana', 'Pap') $$, '22023', 'invalid username',
  'the rule is enforced, not just defined');
select throws_ok($$ select public.complete_onboarding('ana.pap', '   ', 'Pap') $$, '22023', 'invalid name',
  'a blank first name is refused');
select throws_ok($$ select public.complete_onboarding('HOST', 'Ana', 'Pap') $$, '23505', 'username taken',
  'a held name is taken case-insensitively');

select lives_ok($$ select public.complete_onboarding('ana.pap', ' Ana ', 'Pap') $$, 'complete_onboarding runs');
select is(
  (select username from public.profiles where id = 'e44e0000-0000-0000-0000-000000000001'),
  'ana.pap', 'it sets the username');
select ok(
  (select onboarding_completed_at from public.profiles where id = 'e44e0000-0000-0000-0000-000000000001')
    > now() - interval '1 minute',
  'and stamps onboarding_completed_at from the server clock');
select is(
  (select first_name || '|' || last_name from public.user_names where user_id = 'e44e0000-0000-0000-0000-000000000001'),
  'Ana|Pap', 'and writes both names, trimmed');
select throws_ok($$ select public.complete_onboarding('ana.pap2', 'Ana', 'Pap') $$, '42501', 'onboarding already complete',
  'it runs once');
select is(public.username_next_change_at(), null::timestamptz,
  'onboarding does NOT start the cooldown: the first chosen name can be fixed straight away');


-- ===========================================================================
-- E. change_username.
-- ===========================================================================
-- Evaluated once in a CTE: BETWEEN expands to two comparisons and would call
-- change_username twice.
select ok(
  (with c(next_at) as materialized (select public.change_username('ana.p'))
   select next_at between now() + interval '30 days' - interval '1 minute'
                      and now() + interval '30 days' from c),
  'change_username runs and returns when the next change is allowed');
select is(
  (select username from public.profiles where id = 'e44e0000-0000-0000-0000-000000000001'),
  'ana.p', 'the name changed');
select ok(public.username_next_change_at() > now() + interval '29 days', 'username_next_change_at reports the cooldown');
select throws_ok($$ select public.change_username('ana.q') $$, '42501', 'username change cooldown',
  'a second change inside 30 days is refused');
select throws_ok($$ select public.change_username('ana.p') $$, '22023', 'username unchanged',
  'the same name is refused as unchanged, not as a cooldown hit');

-- The reservation, from everyone else's side.
select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger
select is(public.check_username_available('ana.pap'), false, 'the old name reads as taken to others');
select is(public.check_username_available('ANA.PAP'), false, 'case-insensitively');
select throws_ok($$ select public.change_username('Ana.Pap') $$, '23505', 'username taken',
  'and change_username refuses it');
select throws_ok($$ select 1 from public.username_changes $$, '42501', null,
  'NEGATIVE: username_changes has no client grant at all');

select tests.authenticate_as('e44e0000-0000-0000-0000-000000000002');
select throws_ok($$ select public.complete_onboarding('ana.pap', 'Bo', 'B') $$, '23505', 'username taken',
  'and so does complete_onboarding');

-- 15 days on: the reservation has lapsed, the cooldown has not.
reset role;
update public.username_changes set changed_at = now() - interval '15 days'
where user_id = 'e44e0000-0000-0000-0000-000000000001';

select tests.authenticate_as('e44e0000-0000-0000-0000-000000000001');
select throws_ok($$ select public.change_username('ana.q') $$, '42501', 'username change cooldown',
  'day 15: still inside the cooldown');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger
select is(public.check_username_available('ana.pap'), true, 'day 15: the old name is free again');
select lives_ok($$ select public.change_username('ana.pap') $$, 'and someone else can take it');
reset role;
select is(
  (select previous_username from public.username_changes where user_id = '44444444-4444-4444-4444-444444444444'),
  'stranger', 'which reserves THEIR old name in turn');

-- 31 days on: the cooldown has run out.
update public.username_changes set changed_at = now() - interval '31 days'
where user_id = 'e44e0000-0000-0000-0000-000000000001';
select tests.authenticate_as('e44e0000-0000-0000-0000-000000000001');
select is(public.username_next_change_at(), null::timestamptz, 'day 31: no cooldown reported');
select throws_ok($$ select public.change_username('Host') $$, '23505', 'username taken',
  'a name held by another account is taken, whatever the case');
select throws_ok($$ select public.change_username('x') $$, '22023', 'invalid username', 'the rule applies to changes too');
select lives_ok($$ select public.change_username('ANA.P') $$, 'day 31: a case-only change is allowed');
reset role;
select is(
  (select previous_username from public.username_changes where user_id = 'e44e0000-0000-0000-0000-000000000001'),
  'ana.p', 'and it is recorded, so it costs the cooldown');

select tests.authenticate_as('33333333-3333-3333-3333-333333333333'); -- pending deletion (B)
select throws_ok($$ select public.change_username('leaving.soon') $$, '42501', 'account is scheduled for deletion',
  'an account scheduled for deletion cannot rename');

-- A name chosen before the rule keeps working; the rule binds the NEXT one.
reset role;
update public.profiles set username = 'old..style' where id = '22222222-2222-2222-2222-222222222222';
select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee
select is(
  (select username from public.profiles where id = '22222222-2222-2222-2222-222222222222'),
  'old..style', 'a pre-rule name is not touched');
select lives_ok($$ select public.change_username('new.style') $$, 'and its owner can still change away from it');


-- ===========================================================================
-- F. Export and erasure.
-- ===========================================================================
select tests.authenticate_as('e44e0000-0000-0000-0000-000000000001');
select public.set_location_consent(true);
select is(
  public.export_account_data() -> 'username_change' ->> 'previous_username',
  'ana.p', 'the export carries the last username change');
select isnt(
  public.export_account_data() -> 'consents' ->> 'location_consent_at',
  null, 'and when location consent was given');

reset role;
update public.profiles set deleted_at = now() - interval '31 days'
where id = 'e44e0000-0000-0000-0000-000000000001';
select lives_ok(
  $$ select public.complete_account_erasure('e44e0000-0000-0000-0000-000000000001') $$,
  'complete_account_erasure runs for an account with all three rows');
select is(
  (select count(*)::int from public.username_changes where user_id = 'e44e0000-0000-0000-0000-000000000001')
  + (select count(*)::int from public.user_consents where user_id = 'e44e0000-0000-0000-0000-000000000001'),
  0, 'erasure deletes username_changes and user_consents');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444');
select is(public.check_username_available('ana.p'), true,
  'and the reservation goes with it: the tombstone is the account''s last name');

select * from finish();
rollback;
