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
  ('00000000-0000-0000-0000-000000000000', '66666666-6666-6666-6666-666666666666', 'authenticated', 'authenticated', 'second_host@myparty.local', crypt('password123', gen_salt('bf')), current_timestamp, '{"provider":"email","providers":["email"]}', '{}', current_timestamp, current_timestamp),

  -- Crowd. Four accounts with no test role at all, added so the follow graph
  -- below can produce counters that look like a real profile rather than a 1
  -- or a 2. They are deliberately NOT in the 1111-6666 range: every
  -- repeated-digit uuid a reader would reach for is already spoken for --
  -- 7777 and 8888 are test 02's fresh-signup users and 9999 is test 09's --
  -- and more importantly, a crowd account must not be mistakable for a
  -- persona that some assertion depends on. If you need a user with a role,
  -- add a persona; if you need a warm body, add one of these.
  ('00000000-0000-0000-0000-000000000000', '0c0c0c0c-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'nikos@myparty.local', crypt('password123', gen_salt('bf')), current_timestamp, '{"provider":"email","providers":["email"]}', '{}', current_timestamp, current_timestamp),
  ('00000000-0000-0000-0000-000000000000', '0c0c0c0c-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'maria@myparty.local', crypt('password123', gen_salt('bf')), current_timestamp, '{"provider":"email","providers":["email"]}', '{}', current_timestamp, current_timestamp),
  ('00000000-0000-0000-0000-000000000000', '0c0c0c0c-0000-0000-0000-000000000003', 'authenticated', 'authenticated', 'dimitris@myparty.local', crypt('password123', gen_salt('bf')), current_timestamp, '{"provider":"email","providers":["email"]}', '{}', current_timestamp, current_timestamp),
  ('00000000-0000-0000-0000-000000000000', '0c0c0c0c-0000-0000-0000-000000000004', 'authenticated', 'authenticated', 'elena@myparty.local', crypt('password123', gen_salt('bf')), current_timestamp, '{"provider":"email","providers":["email"]}', '{}', current_timestamp, current_timestamp);

-- Without this, NONE of the personas above can actually sign in.
--
-- GoTrue scans these four columns into Go strings, which cannot hold NULL:
-- a password grant fails with
--   Scan error on column index 3, name "confirmation_token":
--   converting NULL to string is unsupported
-- surfacing to the client as a generic 500 "Database error querying schema"
-- that says nothing about the real cause. The other token columns on
-- auth.users default to '' already; these four have no default, so inserting
-- without naming them leaves NULL behind.
--
-- It never showed up before because every earlier phase was verified through
-- pgTAP, which impersonates users with tests.authenticate_as() and never
-- goes near GoTrue. The moment you sign in from the app -- which Phase 6's
-- two-device chat test is the first thing to require -- it blocks everything.
update auth.users set
  confirmation_token = '',
  recovery_token = '',
  email_change_token_new = '',
  email_change = ''
where confirmation_token is null
   or recovery_token is null
   or email_change_token_new is null
   or email_change is null;

-- The auth.users insert above already fired handle_new_user() (Phase 1,
-- 20260813084353_profile_on_signup.sql) and created a placeholder profile
-- row for each persona. Upsert over those rows with the real seeded
-- identity instead of a plain insert, and mark onboarding complete since
-- these personas have real chosen usernames, not placeholders.
--
-- Every persona gets a bio, because the profile header renders @username plus
-- exactly one line and a null there is the empty-shell case we are seeding our
-- way out of. Each is a real single line under the 160-character cap from
-- 20260820095801 -- none of them is close to it, which is the point of the
-- cap: the field is for a line, not a paragraph.
--
-- avatar_path and cover_path stay NULL everywhere in this file, deliberately.
-- A path is only worth storing when bytes exist behind it: seeding
-- '1111…/avatar.jpg' with nothing in the bucket would render as a broken image
-- on every card, which is strictly worse than the placeholder gradient the
-- models already draw for null. Seed the object first, then the path.
insert into public.profiles (id, username, bio, credibility_score, onboarding_completed_at) values
  ('11111111-1111-1111-1111-111111111111', 'host', 'Διοργανώνω ταράτσες στο Κουκάκι. Πάντα υπάρχει χώρος για έναν ακόμα.', 8, now()),
  ('22222222-2222-2222-2222-222222222222', 'invitee', 'Λέω ναι σε σχεδόν όλα. Ψυρρή, συνήθως αργά.', 5, now()),
  ('33333333-3333-3333-3333-333333333333', 'friend_not_invited', 'Εξάρχεια · βινύλια, καφές, και περπάτημα μέχρι το πρωί.', 5, now()),
  ('44444444-4444-4444-4444-444444444444', 'stranger', 'Καινούριος στην Αθήνα. Ψάχνω πού παίζει καλή μουσική.', 3, now()),
  ('55555555-5555-5555-5555-555555555555', 'blocked_user', 'Πάρτι στο κέντρο, σχεδόν κάθε Σάββατο.', 1, now()),
  ('66666666-6666-6666-6666-666666666666', 'second_host', 'Warehouse nights στο Γκάζι και στην Ψυρρή.', 7, now()),
  ('0c0c0c0c-0000-0000-0000-000000000001', 'nikos_p', 'Πετράλωνα. Πάντα με την κιθάρα στο αμάξι.', 4, now()),
  ('0c0c0c0c-0000-0000-0000-000000000002', 'maria_k', 'Χορεύω μέχρι να κλείσει. Μοναστηράκι, Γκάζι, οπουδήποτε.', 6, now()),
  ('0c0c0c0c-0000-0000-0000-000000000003', 'dimitris_t', 'Παγκράτι · μαγειρεύω για είκοσι άτομα χωρίς λόγο.', 5, now()),
  ('0c0c0c0c-0000-0000-0000-000000000004', 'elena_v', 'Φωτογραφίζω πάρτι. Στείλε μου πού παίζει κάτι.', 5, now())
on conflict (id) do update set
  username = excluded.username,
  bio = excluded.bio,
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

insert into public.parties (id, host_id, title, description, location, starts_at, is_private, is_sponsored, party_tier, area) values
  -- Central Athens cluster (Syntagma), all within ~50m of each other
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'Rooftop Pregame', 'Invite-only pregame before we head out.', st_point(23.7348, 37.9755)::geography, now() + interval '2 days', true, false, 'standard', 'Σύνταγμα'),
  ('aaaaaaaa-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111', 'Syntagma Afterparty', 'Open afterparty, everyone welcome.', st_point(23.7351, 37.9758)::geography, now() + interval '2 days', false, false, 'standard', 'Σύνταγμα'),
  (gen_random_uuid(), '66666666-6666-6666-6666-666666666666', 'Constitution Square Meetup', 'Casual meetup before the square gets busy.', st_point(23.7353, 37.9752)::geography, now() + interval '3 days', false, false, 'standard', 'Σύνταγμα'),

  -- Rest of Athens, scattered a few km apart
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Kolonaki Rooftop', 'Cocktails with a view.', st_point(23.7444, 37.9779)::geography, now() + interval '4 days', false, false, 'standard', 'Κολωνάκι'),
  (gen_random_uuid(), '66666666-6666-6666-6666-666666666666', 'Psiri Warehouse Rave', 'Underground techno night.', st_point(23.7263, 37.9789)::geography, now() + interval '5 days', false, false, 'large', 'Ψυρρή'),
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Exarcheia House Party', 'Small gathering, invite-only.', st_point(23.7333, 37.9885)::geography, now() + interval '6 days', true, false, 'standard', 'Εξάρχεια'),
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Pangrati Garden Party', 'BYOB backyard hangout.', st_point(23.7477, 37.9679)::geography, now() + interval '7 days', false, false, 'standard', 'Παγκράτι'),
  (gen_random_uuid(), '66666666-6666-6666-6666-666666666666', 'Nea Smyrni Block Party', 'Whole street is invited.', st_point(23.7147, 37.9463)::geography, now() + interval '8 days', false, false, 'large', 'Νέα Σμύρνη'),
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Kifisia Estate Bash', 'Sponsored mega event, DJ lineup TBA.', st_point(23.8103, 38.0742)::geography, now() + interval '9 days', false, true, 'mega', 'Κηφισιά'),
  (gen_random_uuid(), '66666666-6666-6666-6666-666666666666', 'Marousi Rooftop', 'Sunset drinks.', st_point(23.8069, 38.0567)::geography, now() + interval '10 days', false, false, 'standard', 'Μαρούσι'),
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Piraeus Port Party', 'Boat party at the marina.', st_point(23.6461, 37.9475)::geography, now() + interval '11 days', false, false, 'large', 'Πειραιάς'),
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Glyfada Beach Party', 'Sponsored beachfront festival.', st_point(23.7534, 37.8654)::geography, now() + interval '12 days', false, true, 'mega', 'Γλυφάδα'),
  ('aaaaaaaa-0000-0000-0000-000000000013', '66666666-6666-6666-6666-666666666666', 'Ambelokipi Loft', 'Small invite-only loft party.', st_point(23.7602, 37.9891)::geography, now() + interval '13 days', true, false, 'standard', 'Αμπελόκηποι'),
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Petralona Garage Gig', 'Live band in the garage.', st_point(23.7093, 37.9686)::geography, now() + interval '14 days', false, false, 'standard', 'Πετράλωνα'),
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Gazi Warehouse', 'Private warehouse party.', st_point(23.7107, 37.9779)::geography, now() + interval '6 days', true, false, 'large', 'Γκάζι'),
  (gen_random_uuid(), '66666666-6666-6666-6666-666666666666', 'Monastiraki Terrace', 'Terrace drinks near the flea market.', st_point(23.7256, 37.9765)::geography, now() + interval '3 days', false, false, 'standard', 'Μοναστηράκι'),
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Voula Seaside Party', 'Mega seaside event.', st_point(23.7823, 37.8425)::geography, now() + interval '15 days', false, false, 'mega', 'Βούλα'),

  -- Megara (~33km from Athens center)
  (gen_random_uuid(), '66666666-6666-6666-6666-666666666666', 'Megara Town Square Fiesta', 'Local festival in the square.', st_point(23.3419, 37.9985)::geography, now() + interval '9 days', false, false, 'standard', 'Μέγαρα'),
  ('aaaaaaaa-0000-0000-0000-000000000019', '11111111-1111-1111-1111-111111111111', 'Megara Port Bonfire', 'Small invite-only bonfire by the port.', st_point(23.3378, 37.9928)::geography, now() + interval '10 days', true, false, 'standard', 'Μέγαρα'),
  (gen_random_uuid(), '11111111-1111-1111-1111-111111111111', 'Megara Hilltop Mega Rave', 'Sponsored mega rave on the hilltop.', st_point(23.3465, 38.0050)::geography, now() + interval '11 days', false, true, 'mega', 'Μέγαρα'),

  -- blocked_user's two parties, both in the Syntagma cluster so the Phase 3
  -- block tests can assert against get_parties_near_user's proximity filter
  -- as well as the plain SELECT policy. One public, one private, so a block
  -- is provably stronger than the privacy flag on its own: the public one
  -- must disappear for a blocked viewer even though `not is_private` would
  -- otherwise let anyone see it.
  ('aaaaaaaa-0000-0000-0000-000000000021', '55555555-5555-5555-5555-555555555555', 'Blocked User Open Night', 'Public party hosted by blocked_user.', st_point(23.7350, 37.9756)::geography, now() + interval '2 days', false, false, 'standard', 'Σύνταγμα'),
  ('aaaaaaaa-0000-0000-0000-000000000022', '55555555-5555-5555-5555-555555555555', 'Blocked User Private Loft', 'Private party hosted by blocked_user, host is invited.', st_point(23.7352, 37.9757)::geography, now() + interval '3 days', true, false, 'standard', 'Σύνταγμα');

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
  ('aaaaaaaa-0000-0000-0000-000000000019', '66666666-6666-6666-6666-666666666666'), -- second_host -> Megara Port Bonfire
  ('aaaaaaaa-0000-0000-0000-000000000022', '11111111-1111-1111-1111-111111111111'); -- host -> Blocked User Private Loft

-- ============================================================
-- The host's past, and the parties they merely attend
--
-- Every party above starts in the FUTURE, which left two of the profile
-- screen's three sections permanently empty: "past parties they hosted" and
-- "parties they attended". A profile that can only ever show upcoming events
-- is an empty shell for anyone not currently throwing something.
--
-- ends_at is set on every row here and that is load-bearing, not decoration.
-- get_parties_near_user filters on `ends_at is null or ends_at > now()` -- it
-- does NOT look at starts_at -- so a past party with a null ends_at stays on
-- the map forever, and the seed would quietly grow a pile of finished parties
-- that users can still see pins for. A party that happened has an end time.
--
-- Fixed ids rather than gen_random_uuid(), unlike most of the block above,
-- because the rsvps below have to name them. That is also why the host's
-- attendance is seeded onto NEW parties instead of the existing fixed-id ones:
-- 03_rsvps.test.sql asserts exact interested_count/going_count values on
-- 'aaaa...0001' and 'aaaa...0002' (1, then 0 after a delete), so a seeded rsvp
-- on either of those turns a passing counter test into a failing one.
-- ============================================================

insert into public.parties (id, host_id, title, description, location, starts_at, ends_at, is_private, is_sponsored, party_tier, area) values
  -- Hosted by the host, already over. Public and private both, so the profile's
  -- "past parties" strip shows the same privacy mix the upcoming one does.
  ('aaaaaaaa-0000-0000-0000-000000000031', '11111111-1111-1111-1111-111111111111', 'Καλοκαιρινό Ρετιρέ', 'Ταράτσα, τέλος Αυγούστου.', st_point(23.7261, 37.9662)::geography, now() - interval '14 days', now() - interval '14 days' + interval '7 hours', false, false, 'standard', 'Κουκάκι'),
  ('aaaaaaaa-0000-0000-0000-000000000032', '11111111-1111-1111-1111-111111111111', 'Ιδιωτικό Πάρτι Γενεθλίων', 'Μικρή παρέα, μόνο με πρόσκληση.', st_point(23.7285, 37.9640)::geography, now() - interval '31 days', now() - interval '31 days' + interval '6 hours', true, false, 'standard', 'Κουκάκι'),
  ('aaaaaaaa-0000-0000-0000-000000000033', '11111111-1111-1111-1111-111111111111', 'Γκάζι Warehouse Opening', 'Το πρώτο της σεζόν.', st_point(23.7107, 37.9779)::geography, now() - interval '58 days', now() - interval '58 days' + interval '9 hours', false, false, 'large', 'Γκάζι'),

  -- Hosted by OTHER people, and attended by the host -- the third section.
  -- Without these, "parties attended" can only ever be empty for the host,
  -- because every party in this file was theirs.
  ('aaaaaaaa-0000-0000-0000-000000000041', '66666666-6666-6666-6666-666666666666', 'Ψυρρή Rooftop Session', 'Ηλιοβασίλεμα και dub.', st_point(23.7263, 37.9789)::geography, now() - interval '21 days', now() - interval '21 days' + interval '6 hours', false, false, 'standard', 'Ψυρρή'),
  ('aaaaaaaa-0000-0000-0000-000000000042', '0c0c0c0c-0000-0000-0000-000000000002', 'Μοναστηράκι Terrace Night', 'Ποτά στην ταράτσα πάνω από το παζάρι.', st_point(23.7256, 37.9765)::geography, now() - interval '45 days', now() - interval '45 days' + interval '5 hours', false, false, 'standard', 'Μοναστηράκι');

-- The host's attendance. 'going' rather than 'interested', because
-- fetchAttendedParties reads going RSVPs on parties that have already started
-- -- an interested row would seed a section that still renders empty.
--
-- The third row is UPCOMING and invitation-backed: 'aaaa...0013' is
-- second_host's Ambelokipi Loft, which the invitations block above already
-- invites the host to. It gives the host a party they are going to but do not
-- host, which is what EventsScreen shows and what the two past rows cannot.
insert into public.rsvps (party_id, user_id, status) values
  ('aaaaaaaa-0000-0000-0000-000000000041', '11111111-1111-1111-1111-111111111111', 'going'),
  ('aaaaaaaa-0000-0000-0000-000000000042', '11111111-1111-1111-1111-111111111111', 'going'),
  ('aaaaaaaa-0000-0000-0000-000000000013', '11111111-1111-1111-1111-111111111111', 'going'),
  -- A few other people on the host's own past parties, so the going_count on
  -- those cards is not 0 next to a guest list. None of these touch
  -- 'aaaa...0001' or 'aaaa...0002' -- see the note above about 03_rsvps.
  ('aaaaaaaa-0000-0000-0000-000000000031', '22222222-2222-2222-2222-222222222222', 'going'),
  ('aaaaaaaa-0000-0000-0000-000000000031', '66666666-6666-6666-6666-666666666666', 'going'),
  ('aaaaaaaa-0000-0000-0000-000000000031', '0c0c0c0c-0000-0000-0000-000000000001', 'going'),
  ('aaaaaaaa-0000-0000-0000-000000000031', '0c0c0c0c-0000-0000-0000-000000000003', 'interested'),
  ('aaaaaaaa-0000-0000-0000-000000000033', '0c0c0c0c-0000-0000-0000-000000000002', 'going'),
  ('aaaaaaaa-0000-0000-0000-000000000033', '0c0c0c0c-0000-0000-0000-000000000004', 'going');

-- The private past party needs its guest list, or the host is alone in it.
insert into public.invitations (party_id, guest_id) values
  ('aaaaaaaa-0000-0000-0000-000000000032', '22222222-2222-2222-2222-222222222222'),
  ('aaaaaaaa-0000-0000-0000-000000000032', '0c0c0c0c-0000-0000-0000-000000000003');


-- ============================================================
-- The follow graph
--
-- This block reverses an earlier decision, so the reasoning it replaces is
-- worth stating: seed.sql used to seed NO follows at all, on the grounds that
-- building every edge inside the Phase 3 test transaction exercised the
-- counter and purge triggers for real. That argument still holds and those
-- tests still build their own edges -- what changed is that follower_count and
-- following_count are now RENDERED, and a profile screen whose counters are
-- always 0/0 cannot be looked at.
--
-- FOUR edges must never be seeded here, because a test creates each of them
-- itself and a seeded copy is a duplicate-key error, not a nicer number:
--
--   4444 -> 1111   04_social_graph (and again in 05_feed)
--   1111 -> 5555   04_social_graph, for the block purge
--   5555 -> 1111   04_social_graph, the other half of the same purge
--   3333 -> 1111   06_group_chat, 11_profile_privacy, 12_account_lifecycle
--
-- And `stranger` (4444) appears in NO edge in either direction, which is a
-- stronger rule than the four above. Their whole semantic role is the user
-- connected to nobody: 04_social_graph asserts follower_count = 0 and
-- following_count = 1 on them as absolute numbers, the second only after
-- creating the one edge itself. Seeding anything into or out of 4444 does not
-- just break those two assertions, it deletes the persona.
--
-- blocked_user (5555) does get followers, just never from or to the host --
-- their role is "the one the host blocks", and the block purge is asserted
-- pair-scoped, so edges to anyone else are untouched by it.
-- ============================================================
insert into public.follows (follower_id, followee_id) values
  -- Followers of the host.
  ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111'),
  ('66666666-6666-6666-6666-666666666666', '11111111-1111-1111-1111-111111111111'),
  ('0c0c0c0c-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111'),
  ('0c0c0c0c-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111'),
  ('0c0c0c0c-0000-0000-0000-000000000003', '11111111-1111-1111-1111-111111111111'),
  ('0c0c0c0c-0000-0000-0000-000000000004', '11111111-1111-1111-1111-111111111111'),

  -- Who the host follows back. Not everyone, on purpose: the graph is
  -- asymmetric and a seed where every edge is reciprocated would hide that.
  ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222'),
  ('11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333'),
  ('11111111-1111-1111-1111-111111111111', '66666666-6666-6666-6666-666666666666'),
  ('11111111-1111-1111-1111-111111111111', '0c0c0c0c-0000-0000-0000-000000000001'),
  ('11111111-1111-1111-1111-111111111111', '0c0c0c0c-0000-0000-0000-000000000002'),

  -- The rest of the graph, so every persona except stranger has non-zero
  -- counters and a follower list with something in it.
  ('66666666-6666-6666-6666-666666666666', '22222222-2222-2222-2222-222222222222'),
  ('0c0c0c0c-0000-0000-0000-000000000001', '22222222-2222-2222-2222-222222222222'),
  ('0c0c0c0c-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222'),
  ('22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333'),
  ('22222222-2222-2222-2222-222222222222', '66666666-6666-6666-6666-666666666666'),
  ('22222222-2222-2222-2222-222222222222', '0c0c0c0c-0000-0000-0000-000000000003'),
  ('0c0c0c0c-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333'),
  ('33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222'),
  ('33333333-3333-3333-3333-333333333333', '66666666-6666-6666-6666-666666666666'),
  ('33333333-3333-3333-3333-333333333333', '0c0c0c0c-0000-0000-0000-000000000002'),
  ('0c0c0c0c-0000-0000-0000-000000000003', '66666666-6666-6666-6666-666666666666'),
  ('0c0c0c0c-0000-0000-0000-000000000004', '66666666-6666-6666-6666-666666666666'),
  ('66666666-6666-6666-6666-666666666666', '33333333-3333-3333-3333-333333333333'),
  ('66666666-6666-6666-6666-666666666666', '0c0c0c0c-0000-0000-0000-000000000001'),
  ('0c0c0c0c-0000-0000-0000-000000000001', '0c0c0c0c-0000-0000-0000-000000000004'),

  -- blocked_user, connected to the crowd only. Never to or from the host:
  -- 04_social_graph builds both of those edges itself to test the purge.
  ('0c0c0c0c-0000-0000-0000-000000000001', '55555555-5555-5555-5555-555555555555'),
  ('0c0c0c0c-0000-0000-0000-000000000002', '55555555-5555-5555-5555-555555555555'),
  ('55555555-5555-5555-5555-555555555555', '0c0c0c0c-0000-0000-0000-000000000003');

-- Note: no rows are seeded into public.blocks. Every block is created inside
-- the Phase 3 test transaction instead, so the follow-purge trigger is
-- exercised for real and no earlier suite starts life with content hidden.

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


-- ============================================================
-- Story cleanup credentials (Phase 5, 20260815133041)
--
-- public.purge_story_media() calls the Storage API to delete the objects
-- behind expired stories, and it needs a service_role key plus the API's base
-- URL to do it. Those live in Vault, and this seeds the LOCAL values so
-- `supabase db reset` produces a stack where the whole expiry path -- hide,
-- delete, confirm -- actually runs end to end, which is what
-- scripts/verify_story_lifecycle.sh exercises.
--
-- Safe to commit: both values below are the fixed demo credentials every
-- local Supabase stack ships with, and seed.sql only ever runs against
-- local/CI databases via `supabase db reset`, never a hosted project. A
-- hosted project gets its own secrets inserted once by hand -- see the header
-- of the cleanup migration.
--
-- `kong:8000` rather than 127.0.0.1:54321: this request is made by pg_net
-- from inside the database container, where the API gateway answers on its
-- docker network alias.
-- ============================================================
delete from vault.secrets where name in ('storage_api_url', 'story_cleanup_service_key');

select vault.create_secret(
  'http://kong:8000/storage/v1',
  'storage_api_url',
  'Base URL of the Storage API, used by public.purge_story_media()'
);

select vault.create_secret(
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU',
  'story_cleanup_service_key',
  'Local demo service_role key, used by public.purge_story_media()'
);


-- ============================================================
-- Notification worker credentials (Phase 7c, 20260817083542)
--
-- Same arrangement, same reasoning, same demo key: the insert trigger on
-- notification_jobs and the every-minute cron both POST to the delivery edge
-- function over pg_net, and both need a URL and a service_role bearer token.
--
-- `kong:8000/functions/v1/notification-worker` for the same docker-network
-- reason as above -- and note this only resolves while `supabase functions
-- serve` is running. When it is not, the trigger's exception handler logs a
-- warning and party creation proceeds, which is the behaviour that handler
-- exists for; the cron logs a real failure every minute, which is the honest
-- signal that delivery is down.
-- ============================================================
delete from vault.secrets
where name in ('notification_worker_url', 'notification_worker_service_key');

select vault.create_secret(
  'http://kong:8000/functions/v1/notification-worker',
  'notification_worker_url',
  'Delivery worker endpoint, used by public.post_to_notification_worker()'
);

select vault.create_secret(
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU',
  'notification_worker_service_key',
  'Local demo service_role key, used by public.post_to_notification_worker()'
);


-- ============================================================
-- Account eraser credentials (Phase 9, 20260819083207)
--
-- Same arrangement and same demo key as the two blocks above: the daily
-- account-erasure-sweep cron POSTs to the erasure edge function over pg_net,
-- and needs a URL and a service_role bearer token to do it.
--
-- `kong:8000/functions/v1/account-eraser` for the same docker-network reason,
-- and it likewise only resolves while `supabase functions serve` is running.
-- When it is not, the cron logs a real failure once a day -- which is the
-- honest signal that erasure is down, and unlike the story and notification
-- jobs there is no exception handler softening it, because nothing else is
-- waiting on this transaction.
-- ============================================================
delete from vault.secrets
where name in ('account_eraser_url', 'account_eraser_service_key');

select vault.create_secret(
  'http://kong:8000/functions/v1/account-eraser',
  'account_eraser_url',
  'Erasure worker endpoint, used by public.post_to_account_eraser()'
);

select vault.create_secret(
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU',
  'account_eraser_service_key',
  'Local demo service_role key, used by public.post_to_account_eraser()'
);
