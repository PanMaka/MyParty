-- Proves the handle_new_user() trigger from
-- 20260813084353_profile_on_signup.sql: every auth.users row gets a
-- matching public.profiles row, email and OAuth-shaped signups both
-- work, and check_username_available() is case-insensitive.
begin;
set search_path to public, extensions;
select plan(6);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '00000000-0000-0000-0000-000000000000', '77777777-7777-7777-7777-777777777777', 'authenticated', 'authenticated',
  'fresh_email_signup@myparty.local', crypt('password123', gen_salt('bf')), current_timestamp,
  '{"provider":"email","providers":["email"]}', '{}', current_timestamp, current_timestamp
);

select isnt_empty(
  $$ select 1 from public.profiles where id = '77777777-7777-7777-7777-777777777777' and username is not null $$,
  'email signup produces a profile row with a non-null username'
);

select is(
  (select onboarding_completed_at from public.profiles where id = '77777777-7777-7777-7777-777777777777'),
  null,
  'fresh signup has onboarding_completed_at = null'
);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '00000000-0000-0000-0000-000000000000', '88888888-8888-8888-8888-888888888888', 'authenticated', 'authenticated',
  'oauth_signup@myparty.local', crypt('password123', gen_salt('bf')), current_timestamp,
  '{"provider":"google","providers":["google"]}', '{"full_name":"Jane Doe"}', current_timestamp, current_timestamp
);

select matches(
  (select username from public.profiles where id = '88888888-8888-8888-8888-888888888888'),
  '^jane_doe_',
  'OAuth signup derives its username prefix from raw_user_meta_data.full_name'
);

select is(
  (select count(*)::int from auth.users u left join public.profiles p on p.id = u.id where p.id is null),
  0,
  'no auth.users row exists without a matching profiles row'
);

select is(
  public.check_username_available('HOST'),
  false,
  'check_username_available is case-insensitive against the seeded "host" username'
);

select is(
  public.check_username_available('totally_new_name'),
  true,
  'check_username_available returns true for an unused username'
);

select * from finish();
rollback;
