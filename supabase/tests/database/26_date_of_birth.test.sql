-- Proves 20261003143423_date_of_birth.sql: the before_user_created age gate
-- refuses under-13s with the exact message the app shows, handle_new_user
-- stores the DOB from sign-up metadata, user_birthdates is readable by its
-- owner and nobody else and writable by no client, and the row is exported
-- and erased with the account.
--
-- The hook is called directly: it is invoked by GoTrue, so a raw insert into
-- auth.users (as below) never runs it. scripts-level proof that GoTrue really
-- calls it is the curl check in the PR description.
begin;
set search_path to public, extensions;
select plan(23);

-- ---------------------------------------------------------------- fixtures
-- A: valid DOB. B: no DOB (a pre-gate account, or a seed/test insert).
-- C: an impossible date, which must not be stored.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000000', 'd0b00000-0000-0000-0000-00000000000a', 'authenticated', 'authenticated',
   'dob_a@myparty.local', crypt('password123', gen_salt('bf')), current_timestamp,
   '{"provider":"email","providers":["email"]}', '{"date_of_birth":"2000-05-01"}', current_timestamp, current_timestamp),
  ('00000000-0000-0000-0000-000000000000', 'd0b00000-0000-0000-0000-00000000000b', 'authenticated', 'authenticated',
   'dob_b@myparty.local', crypt('password123', gen_salt('bf')), current_timestamp,
   '{"provider":"email","providers":["email"]}', '{}', current_timestamp, current_timestamp),
  ('00000000-0000-0000-0000-000000000000', 'd0b00000-0000-0000-0000-00000000000c', 'authenticated', 'authenticated',
   'dob_c@myparty.local', crypt('password123', gen_salt('bf')), current_timestamp,
   '{"provider":"email","providers":["email"]}', '{"date_of_birth":"2010-02-30"}', current_timestamp, current_timestamp);

create function pg_temp.gate(p_dob text) returns jsonb language sql as $$
  select public.before_user_created_age_gate(
    case when p_dob is null then '{"user":{"user_metadata":{}}}'::jsonb
         else jsonb_build_object('user', jsonb_build_object('user_metadata',
                jsonb_build_object('date_of_birth', p_dob))) end)
$$;

-- ---------------------------------------------------------------- the hook
select is(pg_temp.gate(null) -> 'error' ->> 'message',
  'Please enter your date of birth.',
  'hook: a sign-up with no date of birth is refused');

select is(pg_temp.gate('2010-02-30') -> 'error' ->> 'message',
  'Please enter your date of birth.',
  'hook: an impossible date does not parse, and is refused like a missing one');

select is(pg_temp.gate(to_char(current_date + 1, 'YYYY-MM-DD')) -> 'error' ->> 'message',
  'Please enter a valid date of birth.',
  'hook: a date of birth in the future is refused');

select is(pg_temp.gate(to_char((current_date - interval '13 years')::date + 1, 'YYYY-MM-DD')) -> 'error' ->> 'message',
  'The Date Of Birth is not on par with the guidelines. You need to be 13+ to own a MyParty Account.',
  'hook: 13th birthday tomorrow is refused, with the exact message the app shows');

select is(pg_temp.gate(to_char((current_date - interval '13 years')::date + 1, 'YYYY-MM-DD')) -> 'error' ->> 'http_code',
  '400',
  'hook: an under-13 refusal is a 400, not a server error');

select is(pg_temp.gate(to_char((current_date - interval '13 years')::date, 'YYYY-MM-DD')),
  '{}'::jsonb,
  'hook: 13th birthday today is allowed');

select is(pg_temp.gate('1990-07-15'),
  '{}'::jsonb,
  'hook: an adult is allowed');

-- Checked through the catalog: the test runner (postgres) may not SET ROLE
-- to supabase_auth_admin.
select ok(
  has_function_privilege('supabase_auth_admin', 'public.before_user_created_age_gate(jsonb)', 'execute')
  and has_function_privilege('supabase_auth_admin', 'public.parse_date_of_birth(text)', 'execute'),
  'hook: supabase_auth_admin, the role GoTrue calls it as, may execute it and its parser');

select tests.authenticate_as('d0b00000-0000-0000-0000-00000000000a');
select throws_ok(
  $$ select public.before_user_created_age_gate('{}') $$,
  '42501', null,
  'hook: a signed-in client may not call the gate');
reset role;

-- ---------------------------------------------------------- handle_new_user
select is(
  (select date_of_birth from public.user_birthdates where user_id = 'd0b00000-0000-0000-0000-00000000000a'),
  date '2000-05-01',
  'handle_new_user stores the date of birth from the sign-up metadata');

select is_empty(
  $$ select 1 from public.user_birthdates where user_id = 'd0b00000-0000-0000-0000-00000000000b' $$,
  'no date of birth in the metadata -> no row');

select isnt_empty(
  $$ select 1 from public.profiles where id = 'd0b00000-0000-0000-0000-00000000000b' $$,
  'no date of birth -> the profile is still created (seed and test inserts keep working)');

select is_empty(
  $$ select 1 from public.user_birthdates where user_id = 'd0b00000-0000-0000-0000-00000000000c' $$,
  'an impossible date in the metadata is not stored');

-- --------------------------------------------------------------------- RLS
select tests.authenticate_as('d0b00000-0000-0000-0000-00000000000a');
select is((select count(*) from public.user_birthdates)::int, 1,
  'owner sees their own date of birth');

select tests.authenticate_as('d0b00000-0000-0000-0000-00000000000b');
select is((select count(*) from public.user_birthdates where user_id = 'd0b00000-0000-0000-0000-00000000000a')::int, 0,
  'another signed-in user cannot see it');

select throws_ok(
  $$ insert into public.user_birthdates (user_id, date_of_birth) values ('d0b00000-0000-0000-0000-00000000000b', '1990-01-01') $$,
  '42501', null,
  'a client cannot give itself a date of birth (no insert privilege)');

select tests.authenticate_as('d0b00000-0000-0000-0000-00000000000a');
select throws_ok(
  $$ update public.user_birthdates set date_of_birth = '1980-01-01' $$,
  '42501', null,
  'the owner cannot change their date of birth (no update privilege)');

select throws_ok(
  $$ delete from public.user_birthdates $$,
  '42501', null,
  'the owner cannot delete it either (no delete privilege)');

select tests.clear_authentication();
select throws_ok(
  $$ select 1 from public.user_birthdates $$,
  '42501', null,
  'anon cannot read the table at all');
reset role;

-- ------------------------------------------------------------------ export
select tests.authenticate_as('d0b00000-0000-0000-0000-00000000000a');
select is(public.export_account_data() ->> 'date_of_birth', '2000-05-01',
  'export includes the caller''s date of birth');

select tests.authenticate_as('d0b00000-0000-0000-0000-00000000000b');
select ok(public.export_account_data() ? 'date_of_birth'
          and public.export_account_data() -> 'date_of_birth' = 'null'::jsonb,
  'export carries the key as null for an account with no date of birth');
reset role;

-- ----------------------------------------------------------------- erasure
update public.profiles
set deleted_at = now() - interval '31 days'
where id = 'd0b00000-0000-0000-0000-00000000000a';

select lives_ok(
  $$ select public.complete_account_erasure('d0b00000-0000-0000-0000-00000000000a') $$,
  'complete_account_erasure runs for an account with a date of birth');

select is_empty(
  $$ select 1 from public.user_birthdates where user_id = 'd0b00000-0000-0000-0000-00000000000a' $$,
  'erasure deletes the date of birth');

select * from finish();
rollback;
