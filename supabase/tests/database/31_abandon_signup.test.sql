-- abandon_signup (20261010021913): going back from the username screen removes
-- the account Create Account just made -- and nothing else, for nobody else.
--
-- Headline negatives: an ONBOARDED account cannot use it (section 2), an
-- account that already wrote content cannot use it and keeps everything
-- (section 3), and anon cannot call it at all (section 4).
--
-- Personas (seed.sql): host 1111 (onboarded), second_host 6666.
begin;
set search_path to public, extensions;
select plan(15);

select is(
  (select prosecdef from pg_proc where oid = 'public.abandon_signup()'::regprocedure),
  true,
  'abandon_signup is SECURITY DEFINER -- profiles has no DELETE policy'
);

select is(
  (select proconfig from pg_proc where oid = 'public.abandon_signup()'::regprocedure),
  array['search_path=""'],
  'abandon_signup pins an empty search_path'
);

-- ---------------------------------------------------------------- fixtures
-- F: fresh sign-up, the case the function exists for.
-- W: fresh sign-up that has already hosted a party through the API.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000000', 'abad0000-0000-0000-0000-00000000000f', 'authenticated', 'authenticated',
   'abandon_f@myparty.local', crypt('password123', gen_salt('bf')), current_timestamp,
   '{"provider":"email","providers":["email"]}', '{"date_of_birth":"2000-05-01"}', current_timestamp, current_timestamp),
  ('00000000-0000-0000-0000-000000000000', 'abad0000-0000-0000-0000-00000000000a', 'authenticated', 'authenticated',
   'abandon_w@myparty.local', crypt('password123', gen_salt('bf')), current_timestamp,
   '{"provider":"email","providers":["email"]}', '{"date_of_birth":"2000-05-01"}', current_timestamp, current_timestamp);

insert into public.parties (id, host_id, title, area, location, starts_at, ends_at, is_private, status)
values ('abad0000-0000-0000-0000-0000000000aa', 'abad0000-0000-0000-0000-00000000000a',
        'Written Before Onboarding', 'Σύνταγμα', st_point(23.7349, 37.9756)::geography,
        now() + interval '1 day', null, false, 'published');

-- A follow F made, and one made of F, both of which an undo should take along.
insert into public.follows (follower_id, followee_id) values
  ('abad0000-0000-0000-0000-00000000000f', '11111111-1111-1111-1111-111111111111'),
  ('11111111-1111-1111-1111-111111111111', 'abad0000-0000-0000-0000-00000000000f');

select is(
  (select count(*)::int from public.user_birthdates where user_id = 'abad0000-0000-0000-0000-00000000000f'),
  1,
  'precondition: handle_new_user stored the fresh account''s date of birth'
);

-- ===========================================================================
-- 1. A fresh account removes itself, everywhere.
-- ===========================================================================
select tests.authenticate_as('abad0000-0000-0000-0000-00000000000f');
select lives_ok($$ select public.abandon_signup() $$, 'a fresh, not-onboarded account can undo its sign-up');
reset role;

select is((select count(*)::int from auth.users where id = 'abad0000-0000-0000-0000-00000000000f'), 0,
  'its auth.users row is gone, so the email can register again');
select is((select count(*)::int from public.profiles where id = 'abad0000-0000-0000-0000-00000000000f'), 0,
  'its profile is gone -- no placeholder-username row left behind');
select is((select count(*)::int from public.user_birthdates where user_id = 'abad0000-0000-0000-0000-00000000000f'), 0,
  'its date of birth is gone');
select is((select count(*)::int from public.follows
           where 'abad0000-0000-0000-0000-00000000000f' in (follower_id, followee_id)), 0,
  'its follows, in both directions, are gone');
select is((select count(*)::int from public.profiles where id = '11111111-1111-1111-1111-111111111111'), 1,
  'the account it followed is untouched');

-- ===========================================================================
-- 2. An onboarded account cannot: leaving is request_account_deletion.
-- ===========================================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');
select throws_ok($$ select public.abandon_signup() $$, '55000', null,
  'an onboarded account is refused');
reset role;
select is((select count(*)::int from auth.users where id = '11111111-1111-1111-1111-111111111111'), 1,
  '...and still exists');

-- ===========================================================================
-- 3. A not-onboarded account that already wrote content keeps everything.
-- ===========================================================================
select tests.authenticate_as('abad0000-0000-0000-0000-00000000000a');
select throws_ok($$ select public.abandon_signup() $$, '23503', null,
  'an account that hosts a party is refused by the NO ACTION foreign key');
reset role;
select is((select count(*)::int from auth.users where id = 'abad0000-0000-0000-0000-00000000000a'), 1,
  '...its auth user survives');
select is((select count(*)::int from public.parties where id = 'abad0000-0000-0000-0000-0000000000aa'), 1,
  '...and so does its party: nothing is half-deleted');

-- ===========================================================================
-- 4. anon holds no EXECUTE.
-- ===========================================================================
select tests.clear_authentication();
set local role anon;
select throws_ok($$ select public.abandon_signup() $$, '42501', null,
  'anon cannot call abandon_signup');
reset role;

select * from finish();
rollback;
