-- Phase 42: a party's address, a real location, and the fields a host may not
-- set (20261020103856).
--
-- What has to hold:
--
--   A. Shape: parties.address is one line of at most 200 characters, '' is
--      not a value, and a party's location is a real point -- in range, and
--      not (0, 0), the coordinate a defaulted double turns into.
--   B. create_party_with_invites stores address and area apart from the
--      description, refuses every key a host may not set (sponsorship, tier,
--      status, counters, cover) with 42501, and refuses a missing or invalid
--      location with 22023. What it leaves out takes the server defaults.
--   C. The same columns are refused on a DIRECT insert -- the RPC is invoker,
--      so its allow-list alone would leave PostgREST open. With a control that
--      an allowed insert still works, so the refusals are not "no INSERT".
--   D. update_party writes the address; NULL and '' clear it.
--   E. A private party's address reaches its host and invitees through every
--      read RPC, and nobody else through any of them or the table. A public
--      party's address is as public as the party.
--   F. Every read RPC carries the column; the address is not searchable; the
--      export carries it.
begin;
select plan(52);

-- Fixtures, as postgres: an address on the seeded private party (host 1111,
-- invitees 2222 and 6666) and on the seeded public one.
update public.parties set address = 'Ερμού 10, ταράτσα, 3ος όροφος'
where id = 'aaaaaaaa-0000-0000-0000-000000000001';
update public.parties set address = 'Πλατεία Συντάγματος 1'
where id = 'aaaaaaaa-0000-0000-0000-000000000002';


-- ===========================================================================
-- A. Shape
-- ===========================================================================
select has_column('public', 'parties', 'address', 'parties.address exists');

select throws_ok(
  $$ update public.parties set address = repeat('α', 201)
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  '23514', null, 'an address is capped at 200 characters');

select throws_ok(
  $$ update public.parties set address = E'Ερμού 10\nταράτσα'
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  '23514', null, 'an address is one line');

select throws_ok(
  $$ update public.parties set address = '   '
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  '23514', null, 'a blank address is not a second spelling of "none"');

select lives_ok(
  $$ update public.parties set address = repeat('α', 200)
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'control: 200 characters is allowed');
update public.parties set address = 'Πλατεία Συντάγματος 1'
where id = 'aaaaaaaa-0000-0000-0000-000000000002';

select throws_ok(
  $$ update public.parties set location = st_point(0, 0)::geography
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  '23514', null, 'a party cannot sit at (0, 0) -- the silent default this phase removes');


-- ===========================================================================
-- B. create_party_with_invites
-- ===========================================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

create temp table made (id uuid) on commit drop;
grant all on made to authenticated;

select lives_ok(
  $$ insert into made select public.create_party_with_invites(
       jsonb_build_object(
         'title', 'Address Party',
         'description', 'Bring snacks.',
         'area', '  Ψυρρή ',
         'address', ' Αισχύλου 12, rooftop ',
         'lat', 37.9781, 'lon', 23.7234,
         'starts_at', (now() + interval '1 day')::text),
       '{}'::uuid[]) $$,
  'a host creates a party with an address and an area');

select results_eq(
  $$ select p.address, p.area, p.description,
            round(st_y(p.location::geometry)::numeric, 4), round(st_x(p.location::geometry)::numeric, 4)
     from public.parties p join made m on m.id = p.id $$,
  $$ values ('Αισχύλου 12, rooftop'::text, 'Ψυρρή'::text, 'Bring snacks.'::text, 37.9781::numeric, 23.7234::numeric) $$,
  'address and area are stored trimmed and APART from the description, at the pin');

select results_eq(
  $$ select p.is_sponsored, p.party_tier, p.status::text, p.going_count, p.interested_count, p.cover_path
     from public.parties p join made m on m.id = p.id $$,
  $$ values (false, 'standard'::text, 'published'::text, 0, 0, null::text) $$,
  'everything the host may not set takes the server default');

select is(
  (select public.create_party_with_invites(
     jsonb_build_object('title', 'Blank address', 'address', '', 'area', '   ',
                        'lat', 37.97, 'lon', 23.72, 'starts_at', (now() + interval '1 day')::text),
     '{}'::uuid[]) is not null),
  true,
  'an empty address and a blank area are accepted');
select results_eq(
  $$ select address, area from public.parties where title = 'Blank address' $$,
  $$ values (null::text, null::text) $$,
  'and stored as NULL, not as a second spelling of "none"');

select throws_ok(
  $$ select public.create_party_with_invites(
       jsonb_build_object('title', 'Sponsored?', 'is_sponsored', true,
                          'lat', 37.97, 'lon', 23.72, 'starts_at', (now() + interval '1 day')::text)) $$,
  '42501', 'party field is_sponsored cannot be set by the host',
  'a host cannot create a sponsored party');

select throws_ok(
  $$ select public.create_party_with_invites(
       jsonb_build_object('title', 'Mega?', 'party_tier', 'mega',
                          'lat', 37.97, 'lon', 23.72, 'starts_at', (now() + interval '1 day')::text)) $$,
  '42501', 'party field party_tier cannot be set by the host',
  'a host cannot set the party tier');

select throws_ok(
  $$ select public.create_party_with_invites(
       jsonb_build_object('title', 'Draft?', 'status', 'draft',
                          'lat', 37.97, 'lon', 23.72, 'starts_at', (now() + interval '1 day')::text)) $$,
  '42501', 'party field status cannot be set by the host',
  'a host cannot set the status');

select throws_ok(
  $$ select public.create_party_with_invites(
       jsonb_build_object('title', 'Full?', 'going_count', 500,
                          'lat', 37.97, 'lon', 23.72, 'starts_at', (now() + interval '1 day')::text)) $$,
  '42501', 'party field going_count cannot be set by the host',
  'a host cannot seed the counters');

select throws_ok(
  $$ select public.create_party_with_invites(
       jsonb_build_object('title', 'Cover?', 'cover_path', 'someone/else.jpg',
                          'lat', 37.97, 'lon', 23.72, 'starts_at', (now() + interval '1 day')::text)) $$,
  '42501', 'party field cover_path cannot be set by the host',
  'a host cannot point cover_path at an object');

select is(
  (select count(*) from public.parties
   where title in ('Sponsored?', 'Mega?', 'Draft?', 'Full?', 'Cover?')),
  0::bigint,
  'and none of the refused calls left a party behind');

select throws_ok(
  $$ select public.create_party_with_invites(
       jsonb_build_object('title', 'Nowhere', 'starts_at', (now() + interval '1 day')::text)) $$,
  '22023', 'a party needs a valid location',
  'no pin, no party -- there is no fallback position');

select throws_ok(
  $$ select public.create_party_with_invites(
       jsonb_build_object('title', 'Half', 'lat', 37.97, 'starts_at', (now() + interval '1 day')::text)) $$,
  '22023', 'a party needs a valid location',
  'a latitude without a longitude is refused');

select throws_ok(
  $$ select public.create_party_with_invites(
       jsonb_build_object('title', 'Off planet', 'lat', 91, 'lon', 23.72,
                          'starts_at', (now() + interval '1 day')::text)) $$,
  '22023', 'a party needs a valid location',
  'a latitude off the planet is refused');

select throws_ok(
  $$ select public.create_party_with_invites(
       jsonb_build_object('title', 'Null Island', 'lat', 0, 'lon', 0,
                          'starts_at', (now() + interval '1 day')::text)) $$,
  '22023', 'a party needs a valid location',
  '(0, 0) is refused -- it is what a missing coordinate defaults to');

select throws_ok(
  $$ select public.create_party_with_invites(
       jsonb_build_object('title', 'NaN', 'lat', 'NaN', 'lon', 23.72,
                          'starts_at', (now() + interval '1 day')::text)) $$,
  '22023', 'a party needs a valid location',
  'NaN is refused');


-- ===========================================================================
-- C. The same rules on a direct insert
-- ===========================================================================
select throws_ok(
  $$ insert into public.parties (host_id, title, location, starts_at, is_sponsored)
     values ((select auth.uid()), 'Direct sponsored', st_point(23.72, 37.97)::geography, now() + interval '1 day', true) $$,
  '42501', null, 'a direct insert cannot set is_sponsored');

select throws_ok(
  $$ insert into public.parties (host_id, title, location, starts_at, party_tier)
     values ((select auth.uid()), 'Direct mega', st_point(23.72, 37.97)::geography, now() + interval '1 day', 'mega') $$,
  '42501', null, 'a direct insert cannot set party_tier');

select throws_ok(
  $$ insert into public.parties (host_id, title, location, starts_at, status)
     values ((select auth.uid()), 'Direct draft', st_point(23.72, 37.97)::geography, now() + interval '1 day', 'draft') $$,
  '42501', null, 'a direct insert cannot set status');

select throws_ok(
  $$ insert into public.parties (host_id, title, location, starts_at, interested_count)
     values ((select auth.uid()), 'Direct counted', st_point(23.72, 37.97)::geography, now() + interval '1 day', 900) $$,
  '42501', null, 'a direct insert cannot seed a counter');

select throws_ok(
  $$ insert into public.parties (host_id, title, location, starts_at, cover_path)
     values ((select auth.uid()), 'Direct cover', st_point(23.72, 37.97)::geography, now() + interval '1 day', 'x/y.jpg') $$,
  '42501', null, 'a direct insert cannot set cover_path');

select throws_ok(
  $$ insert into public.parties (host_id, title, location, starts_at)
     values ((select auth.uid()), 'Direct null island', st_point(0, 0)::geography, now() + interval '1 day') $$,
  '23514', null, 'a direct insert cannot put a party at (0, 0) either');

select lives_ok(
  $$ insert into public.parties (host_id, title, address, area, location, starts_at, is_private)
     values ((select auth.uid()), 'Direct allowed', 'Μιαούλη 3', 'Ψυρρή',
             st_point(23.72, 37.97)::geography, now() + interval '1 day', false) $$,
  'control: a direct insert of the allowed columns still works');


-- ===========================================================================
-- D. update_party
-- ===========================================================================
select lives_ok(
  $$ select public.update_party(
       (select id from made), 'Address Party', 'Bring snacks.', 'Ψυρρή', '  Αισχύλου 14, 2ος όροφος ',
       now() + interval '1 day', null, 37.9782, 23.7235) $$,
  'the host changes the address');
select is(
  (select address from public.parties where id = (select id from made)),
  'Αισχύλου 14, 2ος όροφος',
  'and it lands trimmed');

select lives_ok(
  $$ select public.update_party(
       (select id from made), 'Address Party', 'Bring snacks.', 'Ψυρρή', '',
       now() + interval '1 day', null, 37.9782, 23.7235) $$,
  'the host clears the address');
select is(
  (select address from public.parties where id = (select id from made)),
  null,
  'and an empty address is stored as NULL');

select throws_ok(
  $$ select public.update_party(
       (select id from made), 'Address Party', null, null, null,
       now() + interval '1 day', null, 0, 0) $$,
  '22023', 'a party needs a valid location',
  'update_party refuses (0, 0) too');


-- ===========================================================================
-- E. Who sees a private party's address
-- ===========================================================================
select is(
  (select address from public.get_party_host_stats('aaaaaaaa-0000-0000-0000-000000000001')),
  'Ερμού 10, ταράτσα, 3ος όροφος',
  'the host sees it on the dashboard');

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

select is(
  (select address from public.get_party('aaaaaaaa-0000-0000-0000-000000000001')),
  'Ερμού 10, ταράτσα, 3ος όροφος',
  'an invitee sees it through get_party');
select is(
  (select address from public.get_parties_near_user(23.7348, 37.9755, 500)
   where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  'Ερμού 10, ταράτσα, 3ος όροφος',
  'through the map');
select is(
  (select address from public.get_parties_list() where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  'Ερμού 10, ταράτσα, 3ος όροφος',
  'through ALL PARTIES');
select is(
  (select address from public.get_my_parties() where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  'Ερμού 10, ταράτσα, 3ος όροφος',
  'through MY PARTIES');
select is(
  (select address from public.search_parties('Rooftop') where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  'Ερμού 10, ταράτσα, 3ος όροφος',
  'and through search');
select throws_ok(
  $$ select * from public.get_party_host_stats('aaaaaaaa-0000-0000-0000-000000000001') $$,
  '42501', null, 'but not through the host dashboard');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select is_empty(
  $$ select address from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'a stranger cannot read a private party''s address from the table');
select is_empty(
  $$ select 1 from public.get_party('aaaaaaaa-0000-0000-0000-000000000001') $$,
  'nor through get_party');
select is_empty(
  $$ select 1 from public.get_parties_near_user(23.7348, 37.9755, 500)
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'nor through the map');
select is_empty(
  $$ select 1 from public.get_parties_list() where party_id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'nor through ALL PARTIES');
select is_empty(
  $$ select 1 from public.search_parties('Rooftop') where party_id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'nor through search');
select throws_ok(
  $$ select * from public.get_party_host_stats('aaaaaaaa-0000-0000-0000-000000000001') $$,
  '42501', null, 'nor through the host dashboard');

select is(
  (select address from public.get_party('aaaaaaaa-0000-0000-0000-000000000002')),
  'Πλατεία Συντάγματος 1',
  'a PUBLIC party''s address is as public as the party');

select tests.clear_authentication();
set local role anon;
select is_empty(
  $$ select address from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'anon cannot read a private party''s address');
reset role;


-- ===========================================================================
-- F. Parity, search, export
-- ===========================================================================
select is_empty(
  $$ select f.name
     from (values ('get_party'), ('get_parties_list'), ('get_parties_near_user'),
                  ('search_parties'), ('get_my_parties'), ('get_party_host_stats')) f(name)
     where not exists (
       select 1 from pg_proc p
       where p.pronamespace = 'public'::regnamespace and p.proname = f.name
         and 'address' = any(p.proargnames)
     ) $$,
  'every read RPC that renders a party carries address');

select is_empty(
  $$ select 1 from public.party_search_tokens t
     where t.party_id = 'aaaaaaaa-0000-0000-0000-000000000002'
       and t.token like public.search_normalize('Πλατεία') || '%' $$,
  'the address is not tokenised -- search stays on title and area');

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host
select ok(
  exists (
    select 1 from jsonb_array_elements(public.export_account_data()->'parties') e
    where e->>'id' = 'aaaaaaaa-0000-0000-0000-000000000001'
      and e->>'address' = 'Ερμού 10, ταράτσα, 3ος όροφος'
  ),
  'the export carries each hosted party''s address');

select tests.clear_authentication();

select * from finish();
rollback;
