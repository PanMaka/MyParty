-- Phase 41: the gender mix on the host dashboard (20261019193257).
--
-- What has to hold:
--
--   A. Shape: user_genders is owner-read-only with no client write grant; the
--      two new definers pin their search_path; nobody client-side can call
--      the parser.
--   B. Sign-up: handle_new_user copies exactly the three valid answers and
--      stores nothing for "prefer not to say" or garbage; any later write to
--      the auth row strips the metadata copy, and the table does not follow it.
--   C. set_my_gender: sets, changes, clears (no row), own row only, anon out.
--   D. The counts per group, against hand-countable fixtures: Going, the
--      Interested superset, a private party's Coming, "no row" as unspecified.
--   E. The minimum of three, per group and separately for each group.
--   F. Host-only: a guest who is going, an invitee, a stranger and anon are
--      refused with 42501.
--   G. A block-paired guest is counted, as in the follower split, while the
--      guest list hides them.
--   H. Export carries gender; erasure deletes it.
--
-- Personas: host 1111, invitee 2222 (no gender row), stranger 4444; crowd c4
-- (blocked by the host below). Fresh sign-ups e41e...01-08 go through
-- handle_new_user for real.
begin;
set search_path to public, extensions;
select plan(44);


-- ===========================================================================
-- Fixtures (as postgres)
-- ===========================================================================
-- Fresh sign-ups, one per shape of answer the register form (or a client
-- that is not ours) can send.
--   01 male (with a date of birth)
--   02 male    03 female    04 non_binary
--   05 prefer_not_to_say    06 'Male' (wrong case)    07 a JSON number
--   08 no gender key at all
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select '00000000-0000-0000-0000-000000000000', v.id::uuid, 'authenticated', 'authenticated',
       v.email, crypt('password123', gen_salt('bf')), current_timestamp,
       '{"provider":"email","providers":["email"]}', v.meta::jsonb, current_timestamp, current_timestamp
from (values
  ('e41e0000-0000-0000-0000-000000000001', 'g_m1@myparty.local', '{"gender":"male","date_of_birth":"2000-05-01"}'),
  ('e41e0000-0000-0000-0000-000000000002', 'g_m2@myparty.local', '{"gender":"male"}'),
  ('e41e0000-0000-0000-0000-000000000003', 'g_f1@myparty.local', '{"gender":"female"}'),
  ('e41e0000-0000-0000-0000-000000000004', 'g_n1@myparty.local', '{"gender":"non_binary"}'),
  ('e41e0000-0000-0000-0000-000000000005', 'g_p1@myparty.local', '{"gender":"prefer_not_to_say"}'),
  ('e41e0000-0000-0000-0000-000000000006', 'g_x1@myparty.local', '{"gender":"Male"}'),
  ('e41e0000-0000-0000-0000-000000000007', 'g_x2@myparty.local', '{"gender":7}'),
  ('e41e0000-0000-0000-0000-000000000008', 'g_x3@myparty.local', '{}')
) v(id, email, meta);

-- c4 has an answer, and the host blocks c4.
insert into public.user_genders (user_id, gender) values
  ('0c0c0c0c-0000-0000-0000-000000000004', 'female');
insert into public.blocks (blocker_id, blocked_id) values
  ('11111111-1111-1111-1111-111111111111', '0c0c0c0c-0000-0000-0000-000000000004');

--   G  d4100000...0001  public,  host 1111
--   H  d4100000...0002  private, host 1111
--   S  d4100000...0003  public,  host 1111, small
insert into public.parties (id, host_id, title, location, starts_at, is_private) values
  ('d4100000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111',
   'Mix Public', st_point(23.73, 37.97)::geography, now() + interval '2 days', false),
  ('d4100000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111',
   'Mix Private', st_point(23.73, 37.97)::geography, now() + interval '2 days', true),
  ('d4100000-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111',
   'Mix Small', st_point(23.73, 37.97)::geography, now() + interval '2 days', false);

-- G, going (5):      m1 male, f1 female, n1 non_binary, p1 none, c4 female (blocked)
-- G, interested-only: m2 male, x1 none, invitee none
--   => going      male 1, female 2, non_binary 1, unspecified 1   (5)
--   => interested male 2, female 2, non_binary 1, unspecified 3   (8)
insert into public.rsvps (party_id, user_id, status) values
  ('d4100000-0000-0000-0000-000000000001', 'e41e0000-0000-0000-0000-000000000001', 'going'),
  ('d4100000-0000-0000-0000-000000000001', 'e41e0000-0000-0000-0000-000000000003', 'going'),
  ('d4100000-0000-0000-0000-000000000001', 'e41e0000-0000-0000-0000-000000000004', 'going'),
  ('d4100000-0000-0000-0000-000000000001', 'e41e0000-0000-0000-0000-000000000005', 'going'),
  ('d4100000-0000-0000-0000-000000000001', '0c0c0c0c-0000-0000-0000-000000000004', 'going'),
  ('d4100000-0000-0000-0000-000000000001', 'e41e0000-0000-0000-0000-000000000002', 'interested'),
  ('d4100000-0000-0000-0000-000000000001', 'e41e0000-0000-0000-0000-000000000006', 'interested'),
  ('d4100000-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222', 'interested');

-- H: m1 and f1 invited and coming -- two, under the minimum. n1 joins later.
insert into public.invitations (party_id, guest_id) values
  ('d4100000-0000-0000-0000-000000000002', 'e41e0000-0000-0000-0000-000000000001'),
  ('d4100000-0000-0000-0000-000000000002', 'e41e0000-0000-0000-0000-000000000003'),
  ('d4100000-0000-0000-0000-000000000002', 'e41e0000-0000-0000-0000-000000000004');
insert into public.rsvps (party_id, user_id, status) values
  ('d4100000-0000-0000-0000-000000000002', 'e41e0000-0000-0000-0000-000000000001', 'going'),
  ('d4100000-0000-0000-0000-000000000002', 'e41e0000-0000-0000-0000-000000000003', 'going');

-- S: 2 going (m1, m2) + 1 interested-only (f1). Going is under the minimum,
-- interested (3) is not.
insert into public.rsvps (party_id, user_id, status) values
  ('d4100000-0000-0000-0000-000000000003', 'e41e0000-0000-0000-0000-000000000001', 'going'),
  ('d4100000-0000-0000-0000-000000000003', 'e41e0000-0000-0000-0000-000000000002', 'going'),
  ('d4100000-0000-0000-0000-000000000003', 'e41e0000-0000-0000-0000-000000000003', 'interested');


-- ===========================================================================
-- A. Shape
-- ===========================================================================
select is(
  (select relrowsecurity from pg_class where oid = 'public.user_genders'::regclass),
  true,
  'user_genders has RLS on');

select is(
  (select array_agg(p.proname::text order by p.proname) from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prosecdef
     and p.proname in ('set_my_gender', 'get_party_host_stats')
     and 'search_path=""' = any(p.proconfig)),
  array['get_party_host_stats', 'set_my_gender'],
  'set_my_gender and the recreated get_party_host_stats are definers with an empty search_path');

select ok(
  not has_function_privilege('authenticated', 'public.parse_gender(text)', 'execute')
  and not has_function_privilege('anon', 'public.parse_gender(text)', 'execute'),
  'no client role can call parse_gender');

select is(
  (select array_agg(e.enumlabel::text order by e.enumsortorder) from pg_enum e
   where e.enumtypid = 'public.gender'::regtype),
  array['male', 'female', 'non_binary'],
  'public.gender holds exactly the three answers -- "prefer not to say" is no row, not a value');


-- ===========================================================================
-- B. Sign-up
-- ===========================================================================
select results_eq(
  $$ select user_id::text, gender::text from public.user_genders
     where user_id::text like 'e41e0000-%' order by user_id $$,
  $$ values ('e41e0000-0000-0000-0000-000000000001', 'male'),
            ('e41e0000-0000-0000-0000-000000000002', 'male'),
            ('e41e0000-0000-0000-0000-000000000003', 'female'),
            ('e41e0000-0000-0000-0000-000000000004', 'non_binary') $$,
  'handle_new_user copies the three valid answers, and stores nothing for prefer_not_to_say, a wrong case, a number or no key');

-- The metadata copy. The INSERT keeps it (handle_new_user has to read it);
-- the next write to the row -- GoTrue's sign-up write-back, a sign-in, an
-- updateUser -- removes it. The HTTP side of this, which pgTAP cannot reach,
-- was measured against GoTrue itself (see the migration).
select ok(
  (select raw_user_meta_data ? 'gender' from auth.users
   where id = 'e41e0000-0000-0000-0000-000000000001'),
  'CONTROL: the insert leaves the sign-up answer where handle_new_user reads it');

update auth.users set last_sign_in_at = now()
where id = 'e41e0000-0000-0000-0000-000000000001';

select ok(
  (select not (raw_user_meta_data ? 'gender')
          and raw_user_meta_data ->> 'date_of_birth' = '2000-05-01'
   from auth.users where id = 'e41e0000-0000-0000-0000-000000000001'),
  'any later write to the auth row (here a sign-in''s last_sign_in_at) strips gender, and only gender');

update auth.users
set raw_user_meta_data = raw_user_meta_data || '{"gender":"female"}'
where id = 'e41e0000-0000-0000-0000-000000000001';

select ok(
  (select not (raw_user_meta_data ? 'gender') from auth.users
   where id = 'e41e0000-0000-0000-0000-000000000001'),
  'an updateUser that writes gender into the metadata is stripped too');

select is(
  (select gender::text from public.user_genders
   where user_id = 'e41e0000-0000-0000-0000-000000000001'),
  'male',
  'and the table does not follow the metadata -- set_my_gender stays the only write door');

select is_empty(
  $$ select 1 from auth.users
     where raw_user_meta_data ? 'gender' and last_sign_in_at is not null $$,
  'no account that has signed in still holds a metadata copy');


-- ===========================================================================
-- C. set_my_gender and the table's doors
-- ===========================================================================
select tests.authenticate_as('e41e0000-0000-0000-0000-000000000008'); -- x3, no row

select lives_ok(
  $$ select public.set_my_gender('non_binary') $$,
  'a user can set their gender');
select is(
  (select gender::text from public.user_genders),
  'non_binary',
  'and reads it back -- the only row they can see is their own');
select lives_ok(
  $$ select public.set_my_gender('female') $$,
  'and change it');
select is(
  (select gender::text from public.user_genders where user_id = 'e41e0000-0000-0000-0000-000000000008'),
  'female',
  'the change replaces the answer');
select lives_ok(
  $$ select public.set_my_gender(null) $$,
  'and switch to prefer not to say');
select is_empty(
  $$ select 1 from public.user_genders where user_id = 'e41e0000-0000-0000-0000-000000000008' $$,
  'prefer not to say leaves no row');

select is_empty(
  $$ select 1 from public.user_genders where user_id = 'e41e0000-0000-0000-0000-000000000001' $$,
  'another user''s answer is invisible');
select throws_ok(
  $$ insert into public.user_genders (user_id, gender)
     values ('e41e0000-0000-0000-0000-000000000008', 'male') $$,
  '42501', null,
  'no direct insert -- set_my_gender is the only write door');
select throws_ok(
  $$ update public.user_genders set gender = 'male' $$,
  '42501', null,
  'no direct update');
select throws_ok(
  $$ delete from public.user_genders $$,
  '42501', null,
  'no direct delete');

select tests.clear_authentication(); -- anon
select throws_ok(
  $$ select public.set_my_gender('male') $$,
  '42501', null,
  'signed out: cannot set a gender');
select throws_ok(
  $$ select 1 from public.user_genders $$,
  '42501', null,
  'signed out: cannot read the table at all');
reset role;


-- ===========================================================================
-- D. The counts
-- ===========================================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select results_eq(
  $$ select going_male, going_female, going_non_binary, going_unspecified
     from public.get_party_host_stats('d4100000-0000-0000-0000-000000000001') $$,
  $$ values (1, 2, 1, 1) $$,
  'G going: 1 male, 2 female, 1 non-binary, 1 not specified (prefer not to say)');

select results_eq(
  $$ select interested_male, interested_female, interested_non_binary, interested_unspecified
     from public.get_party_host_stats('d4100000-0000-0000-0000-000000000001') $$,
  $$ values (2, 2, 1, 3) $$,
  'G interested is the superset: the going five plus m2, x1 (invalid at sign-up) and invitee (no row)');

select is(
  (select going_male + going_female + going_non_binary + going_unspecified
   from public.get_party_host_stats('d4100000-0000-0000-0000-000000000001')),
  (select going_count from public.get_party_host_stats('d4100000-0000-0000-0000-000000000001')),
  'the four going counts sum to the going counter');

select is(
  (select interested_male + interested_female + interested_non_binary + interested_unspecified
   from public.get_party_host_stats('d4100000-0000-0000-0000-000000000001')),
  (select interested_count from public.get_party_host_stats('d4100000-0000-0000-0000-000000000001')),
  'the four interested counts sum to the interested counter');


-- ===========================================================================
-- E. The minimum of three
-- ===========================================================================
select results_eq(
  $$ select going_count, going_male, going_female, going_non_binary, going_unspecified
     from public.get_party_host_stats('d4100000-0000-0000-0000-000000000002') $$,
  $$ values (2, null::int, null::int, null::int, null::int) $$,
  'H (private) with two coming: the size is answered, the mix is NULL');

reset role;
insert into public.rsvps (party_id, user_id, status) values
  ('d4100000-0000-0000-0000-000000000002', 'e41e0000-0000-0000-0000-000000000004', 'going');
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');

select results_eq(
  $$ select going_male, going_female, going_non_binary, going_unspecified
     from public.get_party_host_stats('d4100000-0000-0000-0000-000000000002') $$,
  $$ values (1, 1, 1, 0) $$,
  'H with a third coming: the mix appears, a zero category included');

select results_eq(
  $$ select going_male, going_female, going_non_binary, going_unspecified
     from public.get_party_host_stats('d4100000-0000-0000-0000-000000000003') $$,
  $$ values (null::int, null::int, null::int, null::int) $$,
  'S going (2): NULL');

select results_eq(
  $$ select interested_male, interested_female, interested_non_binary, interested_unspecified
     from public.get_party_host_stats('d4100000-0000-0000-0000-000000000003') $$,
  $$ values (2, 1, 0, 0) $$,
  'S interested (3) on the same party: shown -- the minimum is per group, not per party');

-- A changed answer reaches the host on the next read. invitee had no row.
select tests.authenticate_as('22222222-2222-2222-2222-222222222222');
select public.set_my_gender('male');
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');
select results_eq(
  $$ select interested_male, interested_unspecified
     from public.get_party_host_stats('d4100000-0000-0000-0000-000000000001') $$,
  $$ values (3, 2) $$,
  'a guest setting their answer moves the mix on the next read: male 2 -> 3, unspecified 3 -> 2');


-- ===========================================================================
-- F. Host-only
-- ===========================================================================
select tests.authenticate_as('e41e0000-0000-0000-0000-000000000001'); -- m1: going on G, coming on H

select ok(
  exists (select 1 from public.parties where id = 'd4100000-0000-0000-0000-000000000002'),
  'CONTROL: m1 can see private party H -- so the refusals below are the host rule, not visibility');
select throws_ok(
  $$ select * from public.get_party_host_stats('d4100000-0000-0000-0000-000000000001') $$,
  '42501', null,
  'a guest who is going cannot read the mix');
select throws_ok(
  $$ select * from public.get_party_host_stats('d4100000-0000-0000-0000-000000000002') $$,
  '42501', null,
  'nor can an invitee of the private party');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger
select throws_ok(
  $$ select * from public.get_party_host_stats('d4100000-0000-0000-0000-000000000001') $$,
  '42501', null,
  'a stranger cannot read the mix');

select tests.clear_authentication(); -- anon
select throws_ok(
  $$ select * from public.get_party_host_stats('d4100000-0000-0000-0000-000000000001') $$,
  '42501', null,
  'signed out: no mix');
reset role;


-- ===========================================================================
-- G. Block-paired guests
-- ===========================================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is_empty(
  $$ select 1 from public.get_party_guests('d4100000-0000-0000-0000-000000000001')
     where user_id = '0c0c0c0c-0000-0000-0000-000000000004' $$,
  'CONTROL: the guest list hides c4, whom the host blocked');

select is(
  (select going_female from public.get_party_host_stats('d4100000-0000-0000-0000-000000000001')),
  2,
  'the mix still counts c4 (female), exactly as the follower split and the headline counters do');

select is(
  (select going_followers + going_non_followers
   from public.get_party_host_stats('d4100000-0000-0000-0000-000000000001')),
  (select going_male + going_female + going_non_binary + going_unspecified
   from public.get_party_host_stats('d4100000-0000-0000-0000-000000000001')),
  'the follower split and the gender mix count the same going guests');
reset role;


-- ===========================================================================
-- H. Export and erasure
-- ===========================================================================
select tests.authenticate_as('e41e0000-0000-0000-0000-000000000001');
select is(public.export_account_data() ->> 'gender', 'male',
  'export includes the caller''s gender');

select tests.authenticate_as('e41e0000-0000-0000-0000-000000000005');
select ok(public.export_account_data() ? 'gender'
          and public.export_account_data() -> 'gender' = 'null'::jsonb,
  'export carries the key as null for prefer not to say');
reset role;

update public.profiles
set deleted_at = now() - interval '31 days'
where id = 'e41e0000-0000-0000-0000-000000000001';

select lives_ok(
  $$ select public.complete_account_erasure('e41e0000-0000-0000-0000-000000000001') $$,
  'complete_account_erasure runs for an account with a gender');
select is_empty(
  $$ select 1 from public.user_genders where user_id = 'e41e0000-0000-0000-0000-000000000001' $$,
  'erasure deletes the gender');

-- The erased guest's rsvps went with them: G going loses its male guest.
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');
select results_eq(
  $$ select going_male, going_female, going_non_binary, going_unspecified
     from public.get_party_host_stats('d4100000-0000-0000-0000-000000000001') $$,
  $$ values (0, 2, 1, 1) $$,
  'after erasure the mix no longer counts them');
reset role;

select * from finish();
rollback;
