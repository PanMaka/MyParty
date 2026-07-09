-- Insert dummy user in authentication
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '00000000-0000-0000-0000-000000000000',
  '11111111-2222-3333-4444-555555555555',
  'authenticated',
  'authenticated',
  'test@myparty.local',
  crypt('password123', gen_salt('bf')),
  current_timestamp,
  '{"provider":"email","providers":["email"]}',
  '{}',
  current_timestamp,
  current_timestamp
);

-- Insert it into profiles
insert into public.profiles (id, username, credibility_score)
values ('11111111-2222-3333-4444-555555555555', 'dev_host', 5);

-- Have it host two parties
insert into public.parties (host_id, title, description, location, start_time)
values 
  (
    '11111111-2222-3333-4444-555555555555', 
    'First Dummy Party', 
    'Testing the Docker environment.', 
    st_point(23.7668, 37.9685)::geography, 
    now() + interval '2 days'
  ), (
    '11111111-2222-3333-4444-555555555555', 
    'Second Dummy Party', 
    'Testing the Docker environment.', 
    st_point(24.7670, 38.9685)::geography, 
    now() + interval '3 days'
  );