-- ============================================================
-- Test personas
--
-- Fixed, readable UUIDs so migrations/tests/docs can reference these
-- by constant instead of looking them up. Each needs a matching
-- auth.users row (profiles.id is a bare FK to auth.users) before the
-- profiles insert.
-- ============================================================

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111', 'authenticated', 'authenticated', 'host@myparty.local', crypt('password123', gen_salt('bf')), current_timestamp, '{"provider":"email","providers":["email"]}', '{}', current_timestamp, current_timestamp),
  ('00000000-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222', 'authenticated', 'authenticated', 'invitee@myparty.local', crypt('password123', gen_salt('bf')), current_timestamp, '{"provider":"email","providers":["email"]}', '{}', current_timestamp, current_timestamp),
  ('00000000-0000-0000-0000-000000000000', '33333333-3333-3333-3333-333333333333', 'authenticated', 'authenticated', 'friend_not_invited@myparty.local', crypt('password123', gen_salt('bf')), current_timestamp, '{"provider":"email","providers":["email"]}', '{}', current_timestamp, current_timestamp),
  ('00000000-0000-0000-0000-000000000000', '44444444-4444-4444-4444-444444444444', 'authenticated', 'authenticated', 'stranger@myparty.local', crypt('password123', gen_salt('bf')), current_timestamp, '{"provider":"email","providers":["email"]}', '{}', current_timestamp, current_timestamp),
  ('00000000-0000-0000-0000-000000000000', '55555555-5555-5555-5555-555555555555', 'authenticated', 'authenticated', 'blocked_user@myparty.local', crypt('password123', gen_salt('bf')), current_timestamp, '{"provider":"email","providers":["email"]}', '{}', current_timestamp, current_timestamp),
  ('00000000-0000-0000-0000-000000000000', '66666666-6666-6666-6666-666666666666', 'authenticated', 'authenticated', 'second_host@myparty.local', crypt('password123', gen_salt('bf')), current_timestamp, '{"provider":"email","providers":["email"]}', '{}', current_timestamp, current_timestamp);

-- The auth.users insert above already fired handle_new_user() (Phase 1,
-- 20260813084353_profile_on_signup.sql) and created a placeholder profile
-- row for each persona. Upsert over those rows with the real seeded
-- identity instead of a plain insert, and mark onboarding complete since
-- these personas have real chosen usernames, not placeholders.
insert into public.profiles (id, username, credibility_score, onboarding_completed_at) values
  ('11111111-1111-1111-1111-111111111111', 'host', 8, now()),
  ('22222222-2222-2222-2222-222222222222', 'invitee', 5, now()),
  ('33333333-3333-3333-3333-333333333333', 'friend_not_invited', 5, now()),
  ('44444444-4444-4444-4444-444444444444', 'stranger', 3, now()),
  ('55555555-5555-5555-5555-555555555555', 'blocked_user', 1, now()),
  ('66666666-6666-6666-6666-666666666666', 'second_host', 7, now())
on conflict (id) do update set
  username = excluded.username,
  credibility_score = excluded.credibility_score,
  onboarding_completed_at = excluded.onboarding_completed_at;

-- ============================================================
-- Parties
--
-- Real coordinates around Athens and Megara (~33km apart, covers the
-- "10km+" spread) with a 3-party cluster in central Athens under
-- 500m apart. party_tier/is_sponsored are deliberately distributed
-- across standard/large/mega so all three zoom branches of
-- get_parties_near_user are exercised:
--   radius <= 15km   -> every tier
--   radius <= 100km  -> large/mega only
--   radius > 100km   -> mega, or sponsored, only
--
-- Two parties get fixed ids because the pgTAP smoke test references
-- them directly: PARTY_PRIVATE (host's, invitee + second_host
-- invited, stranger is not) and PARTY_PUBLIC (a plain public party).
-- ============================================================

insert into public.parties (id, host_id, title, description, location, start_time, is_private, is_sponsored, party_tier) values
  -- Central Athens cluster (Syntagma), all within ~50m of each other
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Rooftop Pregame', 'Invite-only pregame before we head out.', st_point(23.7348, 37.9755)::geography, now() + interval '2 days', true, false, 'standard'),
  ('aaaaaaaa-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Syntagma Afterparty', 'Open afterparty, everyone welcome.', st_point(23.7351, 37.9758)::geography, now() + interval '2 days', false, false, 'standard'),
  (gen_random_uuid(), '66666666-6666-6666-6666-666666666666', 'Constitution Square Meetup', 'Casual meetup before the square gets busy.', st_point(23.7353, 37.9752)::geography, now() + interval '3 days', false, false, 'standard'),

  -- Rest of Athens, scattered a few km apart
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Kolonaki Rooftop', 'Cocktails with a view.', st_point(23.7444, 37.9779)::geography, now() + interval '4 days', false, false, 'standard'),
  (gen_random_uuid(), '66666666-6666-6666-6666-666666666666', 'Psiri Warehouse Rave', 'Underground techno night.', st_point(23.7263, 37.9789)::geography, now() + interval '5 days', false, false, 'large'),
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Exarcheia House Party', 'Small gathering, invite-only.', st_point(23.7333, 37.9885)::geography, now() + interval '6 days', true, false, 'standard'),
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Pangrati Garden Party', 'BYOB backyard hangout.', st_point(23.7477, 37.9679)::geography, now() + interval '7 days', false, false, 'standard'),
  (gen_random_uuid(), '66666666-6666-6666-6666-666666666666', 'Nea Smyrni Block Party', 'Whole street is invited.', st_point(23.7147, 37.9463)::geography, now() + interval '8 days', false, false, 'large'),
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Kifisia Estate Bash', 'Sponsored mega event, DJ lineup TBA.', st_point(23.8103, 38.0742)::geography, now() + interval '9 days', false, true, 'mega'),
  (gen_random_uuid(), '66666666-6666-6666-6666-666666666666', 'Marousi Rooftop', 'Sunset drinks.', st_point(23.8069, 38.0567)::geography, now() + interval '10 days', false, false, 'standard'),
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Piraeus Port Party', 'Boat party at the marina.', st_point(23.6461, 37.9475)::geography, now() + interval '11 days', false, false, 'large'),
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Glyfada Beach Party', 'Sponsored beachfront festival.', st_point(23.7534, 37.8654)::geography, now() + interval '12 days', false, true, 'mega'),
  ('aaaaaaaa-0000-0000-0000-000000000013', '66666666-6666-6666-6666-666666666666', 'Ambelokipi Loft', 'Small invite-only loft party.', st_point(23.7602, 37.9891)::geography, now() + interval '13 days', true, false, 'standard'),
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Petralona Garage Gig', 'Live band in the garage.', st_point(23.7093, 37.9686)::geography, now() + interval '14 days', false, false, 'standard'),
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Gazi Warehouse', 'Private warehouse party.', st_point(23.7107, 37.9779)::geography, now() + interval '6 days', true, false, 'large'),
  (gen_random_uuid(), '66666666-6666-6666-6666-666666666666', 'Monastiraki Terrace', 'Terrace drinks near the flea market.', st_point(23.7256, 37.9765)::geography, now() + interval '3 days', false, false, 'standard'),
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Voula Seaside Party', 'Mega seaside event.', st_point(23.7823, 37.8425)::geography, now() + interval '15 days', false, false, 'mega'),

  -- Megara (~33km from Athens center)
  (gen_random_uuid(), '66666666-6666-6666-6666-666666666666', 'Megara Town Square Fiesta', 'Local festival in the square.', st_point(23.3419, 37.9985)::geography, now() + interval '9 days', false, false, 'standard'),
  ('aaaaaaaa-0000-0000-0000-000000000019', '11111111-1111-1111-1111-111111111111', 'Megara Port Bonfire', 'Small invite-only bonfire by the port.', st_point(23.3378, 37.9928)::geography, now() + interval '10 days', true, false, 'standard'),
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Megara Hilltop Mega Rave', 'Sponsored mega rave on the hilltop.', st_point(23.3465, 38.0050)::geography, now() + interval '11 days', false, true, 'mega');

-- ============================================================
-- Invitations
--
-- invitee and second_host are wired into a handful of private
-- parties; friend_not_invited, stranger and blocked_user
-- deliberately get none, so "not invited" is directly testable.
-- ============================================================

insert into public.invitations (party_id, guest_id) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222'), -- invitee -> Rooftop Pregame (PARTY_PRIVATE)
  ('aaaaaaaa-0000-0000-0000-000000000001', '66666666-6666-6666-6666-666666666666'), -- second_host -> Rooftop Pregame (PARTY_PRIVATE)
  ('aaaaaaaa-0000-0000-0000-000000000013', '11111111-1111-1111-1111-111111111111'), -- host -> Ambelokipi Loft
  ('aaaaaaaa-0000-0000-0000-000000000019', '66666666-6666-6666-6666-666666666666'); -- second_host -> Megara Port Bonfire

-- ============================================================
-- Test harness helpers
--
-- These live in seed.sql (not a migration, not a file under
-- supabase/tests/) because seed.sql only ever runs against
-- local/CI databases via `supabase db reset`, never against a
-- hosted project. `supabase test db` also runs each file under
-- supabase/tests/ as its own independent pg_prove/TAP process, so a
-- function defined in one test file isn't reliably visible from
-- another — defining it here guarantees it exists before any test
-- file runs.
-- ============================================================

create extension if not exists pgtap with schema extensions;

create schema if not exists tests;

-- authenticate_as()/clear_authentication() switch the session role away
-- from postgres, so the role calling them needs USAGE on this schema to
-- call them again afterwards (function EXECUTE is already PUBLIC by
-- default). Fine to grant broadly: this schema only ever exists in
-- ephemeral local/CI databases, never a hosted project.
grant usage on schema tests to public;

-- Impersonate a user the way PostgREST does: set the JWT claims that
-- auth.uid()/auth.role() read, and switch role so `to authenticated`
-- policies apply.
create or replace function tests.authenticate_as(p_user_id uuid)
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_user_id::text, 'role', 'authenticated')::text,
    true);
  perform set_config('request.jwt.claim.sub', p_user_id::text, true);
  perform set_config('role', 'authenticated', true);
end;
$$;

-- Drop back to an anonymous, unauthenticated session.
create or replace function tests.clear_authentication()
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('role', 'anon', true);
end;
$$;
