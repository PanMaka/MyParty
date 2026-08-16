-- Phase 7a: user_devices, sent_notifications, and the three GDPR properties
-- docs/backend-plan.md 7.2 calls the highest compliance risk in the project.
--
-- Every other test file in this suite asks "can the wrong person read this
-- row". That question is here too (a stranger must not see another user's
-- location, and the file proves it four ways), but it is not the interesting
-- half. Location data fails differently: the harm is in the row EXISTING, so
-- three of the assertions below are about data that must never be written, and
-- three more are about data that must stop existing on a clock.
--
-- What is proved here, in the order the risk runs:
--
--   1. NO CONSENT, NO LOCATION. The refusal is the RLS WITH CHECK, not client
--      politeness -- asserted on INSERT and separately on UPDATE, because a
--      row inserted location-free while consent is false and then updated with
--      a location is the same violation through a different door.
--   2. THE PRECISE COORDINATE NEVER LANDS. Asserted by reading back what is on
--      disk and finding it rounded -- an assertion that the raw value is
--      absent, not that a function was called.
--   3. NO ONE ELSE READS IT. Select, spatial select, update and delete all
--      return nothing for a stranger, against a positive control so none of
--      those zeroes can be vacuous.
--   4. THE 24h JOB REALLY CLEARS THE COLUMN. The sweep is called for real
--      against a backdated row, and a 23-hour-old row in the same table is
--      asserted to SURVIVE -- a purge that clears everything would pass a
--      one-sided test and quietly break the feature.
--   5. WITHDRAWAL CLEARS WHAT CONSENT BOUGHT, without deleting the push token.
--   6. NO HISTORY TABLE. Asserted structurally over the catalog, because rule
--      3 is not about today's schema -- it is about the migration someone
--      writes in Phase 8 that seems harmless.
--
-- Personas (seed.sql): host 1111, invitee 2222, stranger 4444.
-- Parties: aaaa...0002 public (host's).
--
-- Seeded profiles have location_consent = false (opt-in default, Phase 1), so
-- the no-consent case needs no setup -- it is the state every real user starts
-- in, which is why it is tested first.
begin;
set search_path to public, extensions;
select plan(40);


-- Owner-level session, for the structural assertions and for the two things no
-- client role may do: backdate a derived timestamp, and write
-- sent_notifications. Mirrors tests.authenticate_as/clear_authentication from
-- seed.sql, which only ever move between authenticated and anon.
create or replace function tests.become_owner()
returns void
language plpgsql
as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('role', 'postgres', true);
end;
$$;


-- ============================================================
-- Structure: the guarantees that are properties of the schema itself.
-- ============================================================

select is(
  (select relrowsecurity from pg_class where oid = 'public.user_devices'::regclass),
  true,
  'RLS is enabled on user_devices'
);

select is(
  (select relrowsecurity from pg_class where oid = 'public.sent_notifications'::regclass),
  true,
  'RLS is enabled on sent_notifications'
);

-- Deliverable: a GiST index on BOTH geography columns. Matched on access
-- method and column rather than on index name, so a future rename still
-- passes and a drop still fails.
select is(
  (select count(*)::int
   from pg_index i
   join pg_class c on c.oid = i.indexrelid
   join pg_am am on am.oid = c.relam
   where i.indrelid = 'public.user_devices'::regclass
   and am.amname = 'gist'
   and (select attname from pg_attribute
        where attrelid = i.indrelid and attnum = i.indkey[0]) = 'last_location'),
  1,
  'user_devices.last_location has a GiST index -- 7b fans out from a party over this'
);

-- Phase 0 created this one (20260708114539). Asserted here rather than assumed
-- because without it the spatial queries stay CORRECT and merely become
-- sequential scans, which is a failure with no symptom until the table is big.
select is(
  (select count(*)::int
   from pg_index i
   join pg_class c on c.oid = i.indexrelid
   join pg_am am on am.oid = c.relam
   where i.indrelid = 'public.parties'::regclass
   and am.amname = 'gist'
   and (select attname from pg_attribute
        where attrelid = i.indrelid and attnum = i.indkey[0]) = 'location'),
  1,
  'parties.location still has its GiST index from Phase 0'
);

-- Rule 3, enforced against the catalog instead of against intent: "last value
-- only, never a history table". This is the assertion that fails on the day
-- someone adds device_location_history, and it is deliberately written as an
-- exhaustive list rather than a "does table X exist" check -- the table that
-- breaks this rule will not be called what we guessed.
select is(
  (select array_agg(c.relname || '.' || a.attname order by c.relname, a.attname)
   from pg_attribute a
   join pg_class c on c.oid = a.attrelid
   join pg_namespace n on n.oid = c.relnamespace
   join pg_type t on t.oid = a.atttypid
   where n.nspname = 'public'
   and c.relkind = 'r'
   and a.attnum > 0
   and not a.attisdropped
   and t.typname = 'geography'),
  array['parties.location', 'user_devices.last_location'],
  'exactly two geography columns exist -- adding a location history table breaks this on purpose'
);

-- has_table_privilege reports true if ANY column carries the privilege, so
-- this covers the column-scoped write grants as well as the table-level ones.
select is(
  (select bool_or(has_table_privilege('anon', 'public.user_devices', p))
   from unnest(array['select', 'insert', 'update', 'delete']) p),
  false,
  'anon holds no data privilege on user_devices'
);

select is(
  (select bool_or(has_table_privilege('authenticated', 'public.sent_notifications', p))
   from unnest(array['select', 'insert', 'update', 'delete']) p),
  false,
  'sent_notifications is engine-internal -- authenticated cannot even SELECT it'
);

-- The non-data privileges, asserted separately because they are the ones that
-- arrive without anyone granting them. Supabase's default ACL for schema public
-- hands anon and authenticated TRUNCATE, REFERENCES, TRIGGER and MAINTAIN on
-- every new table -- and RLS mediates none of those. An RLS-perfect table that
-- anon can still TRUNCATE is not a protected table, so the migration revokes
-- them and this is what keeps them revoked.
select is(
  (select bool_or(has_table_privilege(r, t, p))
   from unnest(array['anon', 'authenticated']) r,
        unnest(array['public.user_devices', 'public.sent_notifications']) t,
        unnest(array['truncate', 'references', 'trigger']) p),
  false,
  'and neither role can TRUNCATE, reference or trigger either table -- the default ACL is revoked'
);

-- The 24h promise is only as good as this row. */10 rather than hourly so the
-- worst-case retention is 24h10m and not 25h -- see the migration header.
select is(
  (select schedule || ' active=' || active::text from cron.job where jobname = 'location-retention'),
  '*/10 * * * * active=true',
  'the location-retention job is scheduled every 10 minutes and active'
);


-- ============================================================
-- 1. No consent, no stored location.
--
-- host starts with location_consent = false, straight from seed.sql. Nothing
-- is set up for this section, which is the point: this is the default state of
-- every account on the platform.
-- ============================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select throws_ok(
  $$ insert into public.user_devices (id, user_id, push_token, platform, last_location) values
     ('dddddddd-0000-0000-0000-000000000001',
      '11111111-1111-1111-1111-111111111111',
      'token-host-phone', 'ios',
      st_point(23.734812345, 37.975612345)::geography) $$,
  '42501',
  null,
  'no location_consent means the location cannot be stored at all -- refused by the policy'
);

-- The carve-out, and it is a carve-out with a reason: registering for PUSH is
-- a separate consent (profiles.push_consent). A device that wants "you were
-- invited" notifications and no proximity feature must be able to exist. What
-- 7.2 forbids is the LOCATION without consent, which is what the row above
-- was refused for and this row is not.
select lives_ok(
  $$ insert into public.user_devices (id, user_id, push_token, platform) values
     ('dddddddd-0000-0000-0000-000000000000',
      '11111111-1111-1111-1111-111111111111',
      'token-host-tablet', 'android') $$,
  'a device may register for push with no location and no location consent'
);

-- The second door. Insert-only enforcement would leave this open: same row,
-- same absent consent, arriving one statement later.
select throws_ok(
  $$ update public.user_devices
     set last_location = st_point(23.7348, 37.9756)::geography
     where id = 'dddddddd-0000-0000-0000-000000000000' $$,
  '42501',
  null,
  'and it cannot be smuggled in by UPDATE afterwards either'
);


-- ============================================================
-- 2. With consent: the coordinate is rounded BEFORE it is stored.
--
-- The assertions read the column back and find the precise value absent. That
-- is the only form of this test worth writing -- "round_location returns a
-- rounded point" would pass on a schema where nothing ever calls it.
-- ============================================================
update public.profiles
set location_consent = true
where id = '11111111-1111-1111-1111-111111111111';

insert into public.user_devices (id, user_id, push_token, platform, last_location) values
  ('dddddddd-0000-0000-0000-000000000001',
   '11111111-1111-1111-1111-111111111111',
   'token-host-phone', 'ios',
   st_point(23.734812345, 37.975612345)::geography);

select is(
  (select st_x(last_location::geometry)::numeric
   from public.user_devices where id = 'dddddddd-0000-0000-0000-000000000001'),
  23.735::numeric,
  'longitude is stored rounded to 3dp -- the 6 digits of precision sent are gone'
);

select is(
  (select st_y(last_location::geometry)::numeric
   from public.user_devices where id = 'dddddddd-0000-0000-0000-000000000001'),
  37.976::numeric,
  'latitude is stored rounded to 3dp'
);

-- Both sides cast through geography so they share SRID 4326 -- st_point alone
-- returns SRID 0 and st_equals refuses to compare mixed SRIDs.
select is(
  (select st_equals(last_location::geometry,
                    st_point(23.734812345, 37.975612345)::geography::geometry)
   from public.user_devices where id = 'dddddddd-0000-0000-0000-000000000001'),
  false,
  'the exact point that was sent is not what is on disk'
);

-- ~100m is the requirement; this asserts the rounding is a real ~100m cell and
-- not, say, a decimal place out in either direction. 3dp at Athens is ~46m of
-- displacement worst case here, and could never exceed ~90m anywhere.
select ok(
  (select st_distance(last_location, st_point(23.734812345, 37.975612345)::geography) < 100
   from public.user_devices where id = 'dddddddd-0000-0000-0000-000000000001'),
  'the stored cell is within ~100m of the real position -- coarse, still useful at a 500m radius'
);

select ok(
  (select last_location_at > now() - interval '1 minute'
   from public.user_devices where id = 'dddddddd-0000-0000-0000-000000000001'),
  'last_location_at is stamped by the trigger when a location arrives'
);

-- Derived means derived. If a client could write last_location_at it could
-- restamp its own row forever and opt itself out of the 24h retention, which
-- is the single most valuable thing an attacker could do to this table.
select throws_ok(
  $$ update public.user_devices set last_location_at = now() + interval '10 years'
     where id = 'dddddddd-0000-0000-0000-000000000001' $$,
  '42501',
  null,
  'last_location_at is not client-writable -- no column grant, so retention cannot be dodged'
);

select throws_ok(
  $$ insert into public.user_devices (user_id, push_token, platform, last_location_at) values
     ('11111111-1111-1111-1111-111111111111', 'token-forged', 'ios', now() + interval '10 years') $$,
  '42501',
  null,
  'nor settable on insert'
);

-- A second device for the same user, used by the retention section below to
-- prove the sweep clears the stale row and only the stale row.
insert into public.user_devices (id, user_id, push_token, platform, last_location) values
  ('dddddddd-0000-0000-0000-000000000002',
   '11111111-1111-1111-1111-111111111111',
   'token-host-laptop', 'web',
   st_point(23.7602, 37.9891)::geography);


-- ============================================================
-- 3. Nobody reads another user's location, ever.
--
-- The positive control comes first, so the four zeroes below mean "the policy
-- filtered them" and not "the rows were never there".
-- ============================================================
select is(
  (select count(*)::int from public.user_devices
   where user_id = '11111111-1111-1111-1111-111111111111'),
  3,
  'positive control: host sees all three of their own devices'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select is(
  (select count(*)::int from public.user_devices
   where user_id = '11111111-1111-1111-1111-111111111111'),
  0,
  'a stranger selecting another user''s device rows gets nothing'
);

-- The same question asked the way the feature would ask it. A policy that
-- filtered the row list but left a spatial predicate answerable would still
-- leak the location by bisection -- "is anyone within 50m of here" repeated.
select is(
  (select count(*)::int from public.user_devices
   where st_dwithin(last_location, st_point(23.7348, 37.9756)::geography, 5000)),
  0,
  'and cannot probe for it spatially either -- no oracle, not just no rows'
);

with attempted as (
  update public.user_devices set platform = 'web'
  where user_id = '11111111-1111-1111-1111-111111111111'
  returning 1
)
select is(
  (select count(*)::int from attempted),
  0,
  'a stranger''s UPDATE against another user''s devices matches nothing'
);

with attempted as (
  delete from public.user_devices
  where user_id = '11111111-1111-1111-1111-111111111111'
  returning 1
)
select is(
  (select count(*)::int from attempted),
  0,
  'and neither does their DELETE'
);

select throws_ok(
  $$ insert into public.user_devices (user_id, push_token, platform) values
     ('11111111-1111-1111-1111-111111111111', 'token-planted', 'ios') $$,
  '42501',
  null,
  'nor can a stranger plant a device row owned by someone else'
);

select tests.clear_authentication();

select throws_ok(
  $$ select 1 from public.user_devices $$,
  '42501',
  null,
  'anon has no grant on user_devices at all -- an honest 42501, not an empty result'
);


-- ============================================================
-- sent_notifications: closed to clients, and idempotent by constraint.
-- ============================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select throws_ok(
  $$ select 1 from public.sent_notifications $$,
  '42501',
  null,
  'a user cannot read the notification ledger -- it is also a record of who was near what'
);

select throws_ok(
  $$ insert into public.sent_notifications (user_id, party_id, kind) values
     ('11111111-1111-1111-1111-111111111111',
      'aaaaaaaa-0000-0000-0000-000000000002', 'nearby_party') $$,
  '42501',
  null,
  'and cannot write it -- only 7b''s definer functions enqueue'
);

select tests.become_owner();

insert into public.sent_notifications (user_id, party_id, kind) values
  ('11111111-1111-1111-1111-111111111111',
   'aaaaaaaa-0000-0000-0000-000000000002', 'nearby_party');

-- 7.1's dedupe rule, as a constraint rather than a read-then-write check: the
-- publish trigger, the movement trigger and the hourly safety-net sweep all
-- race for this row, and 23505 is how the loser learns it already sent.
select throws_ok(
  $$ insert into public.sent_notifications (user_id, party_id, kind) values
     ('11111111-1111-1111-1111-111111111111',
      'aaaaaaaa-0000-0000-0000-000000000002', 'nearby_party') $$,
  '23505',
  null,
  'the same (user, party, kind) cannot be enqueued twice -- dedupe is the constraint'
);


-- ============================================================
-- 4. The 24h job actually clears the column.
--
-- Backdated as owner, because last_location_at carries no client grant --
-- which is itself asserted above. The BEFORE trigger leaves the supplied value
-- alone when the location has not changed, which is what makes this possible
-- for the owner and impossible for everyone else.
-- ============================================================
update public.user_devices
set last_location_at = now() - interval '25 hours'
where id = 'dddddddd-0000-0000-0000-000000000001';

update public.user_devices
set last_location_at = now() - interval '23 hours'
where id = 'dddddddd-0000-0000-0000-000000000002';

select is(
  public.purge_stale_locations(),
  1,
  'the sweep clears exactly one row -- the one past 24h'
);

select ok(
  (select last_location is null from public.user_devices
   where id = 'dddddddd-0000-0000-0000-000000000001'),
  'the 25h-old location is gone from the column'
);

-- Nulled in lockstep by the trigger, not by the sweep -- one place decides
-- what a cleared location looks like. A location with no timestamp would be a
-- location that is never older than 24h, which the check constraint also
-- forbids.
select ok(
  (select last_location_at is null from public.user_devices
   where id = 'dddddddd-0000-0000-0000-000000000001'),
  'and its timestamp with it'
);

-- Retention nulls a column; it does not unsubscribe anyone. Deleting the row
-- would look like a delivery bug three phases later.
select is(
  (select push_token from public.user_devices
   where id = 'dddddddd-0000-0000-0000-000000000001'),
  'token-host-phone',
  'the device row and its push token survive -- only the location expired'
);

-- The other half of the test, and the half a one-sided assertion misses: a
-- sweep with a broken predicate that cleared everything would pass every
-- assertion above.
select ok(
  (select last_location is not null from public.user_devices
   where id = 'dddddddd-0000-0000-0000-000000000002'),
  'the 23h-old location is untouched -- the sweep is bounded, not indiscriminate'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select throws_ok(
  $$ select public.purge_stale_locations() $$,
  '42501',
  null,
  'retention is not client-callable'
);

select throws_ok(
  $$ select public.run_location_retention() $$,
  '42501',
  null,
  'and neither is the job wrapper'
);


-- ============================================================
-- 5. Withdrawing consent clears what consent bought.
--
-- GDPR Art. 7(3): withdrawal has to remove the data already held, not merely
-- stop collection. Waiting for the 24h sweep would leave the user looking at
-- an off toggle while 7b's proximity queries can still match them.
-- ============================================================
update public.user_devices
set last_location = st_point(23.7348, 37.9756)::geography
where id = 'dddddddd-0000-0000-0000-000000000001';

update public.profiles
set location_consent = false
where id = '11111111-1111-1111-1111-111111111111';

select is(
  (select count(*)::int from public.user_devices
   where user_id = '11111111-1111-1111-1111-111111111111'
   and last_location is not null),
  0,
  'withdrawing location consent clears every stored location immediately'
);

select is(
  (select count(*)::int from public.user_devices
   where user_id = '11111111-1111-1111-1111-111111111111'),
  3,
  'without deleting a single device -- location consent is not push consent'
);


-- ============================================================
-- 6. sent_notifications 90-day retention (7.2, "retention elsewhere").
-- ============================================================
select tests.become_owner();

insert into public.sent_notifications (user_id, party_id, kind, sent_at) values
  ('22222222-2222-2222-2222-222222222222',
   'aaaaaaaa-0000-0000-0000-000000000002', 'nearby_party',
   now() - interval '91 days'),
  ('44444444-4444-4444-4444-444444444444',
   'aaaaaaaa-0000-0000-0000-000000000002', 'nearby_party',
   now() - interval '89 days');

select is(
  public.purge_old_sent_notifications(),
  1,
  'the 90-day sweep deletes the 91-day-old row'
);

select is(
  (select count(*)::int from public.sent_notifications
   where user_id = '44444444-4444-4444-4444-444444444444'),
  1,
  'and keeps the 89-day-old one -- bounded here too'
);


select * from finish();
rollback;
