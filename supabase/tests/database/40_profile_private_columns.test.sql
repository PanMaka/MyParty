-- Proves 20261021121734_profile_private_columns.sql: the private columns of
-- public.profiles reach their owner (through get_my_settings) and the definer
-- engines, and nobody else -- not another user, not a signed-out caller, not
-- through any RPC and not through a realtime payload. And every public view
-- of a profile still works.
--
-- How "not through any RPC" is made concrete rather than sampled:
--
--   * By NAME, over the catalog: no function a client role can execute has an
--     output column named after a private column, except get_my_settings.
--     `created_at` is the one exception to the name rule: eight read RPCs
--     return the created_at of a post, message, rsvp or invite, which is not
--     the account's.
--   * By VALUE, end to end: every user except the caller gets settings no real
--     row would hold (time zone Pacific/Chatham, quiet hours 03:17:29-07:43:11,
--     an account created_at of 1987-06-05), then every read RPC the client
--     calls is run AS THE CALLER and the text of each row it returns is
--     searched for them. This is what catches a private value leaving under a
--     different column name, which the catalog check cannot see. The same scan
--     runs over every realtime payload written in the transaction.
--
-- The booleans (consents, notify_nearby) cannot be found by value; the grant
-- assertions in section 1 and the per-column refusals in section 2 cover them.
--
-- Personas (seed.sql): host 1111, invitee 2222 (follows host, invited to
-- ...0001), friend_not_invited 3333, stranger 4444, blocked_user 5555,
-- second_host 6666. Parties: aaaa...0001 private (host 1111, invitee 2222),
-- aaaa...0002 public (host 1111).
begin;
set search_path to public, extensions;
select plan(114);

create temp table private_cols (c text primary key) on commit drop;
insert into private_cols values
  ('onboarding_completed_at'), ('deleted_at'), ('erased_at'), ('created_at'),
  ('credibility_score'), ('location_consent'), ('push_consent'),
  ('analytics_consent'), ('notify_nearby'), ('notify_radius_meters'),
  ('notify_daily_cap'), ('quiet_hours_start'), ('quiet_hours_end'),
  ('notification_tz'), ('map_visibility'), ('invite_policy'), ('dm_policy');
grant select on private_cols to authenticated, anon;

create temp table public_cols (c text primary key) on commit drop;
insert into public_cols values
  ('id'), ('username'), ('bio'), ('avatar_path'), ('follower_count'),
  ('following_count'), ('username_search'), ('is_discoverable');


-- ============================================================
-- 1. The grants, read from the catalog as postgres.
-- ============================================================
select is(
  array(select a.attname::text from pg_attribute a
        where a.attrelid = 'public.profiles'::regclass and a.attnum > 0 and not a.attisdropped
          and a.attname::text not in (select c from private_cols union all select c from public_cols)
        order by 1),
  '{}'::text[],
  'every column of profiles is classified public or private here -- a new column has to be decided, not inherited');

select ok(
  not has_any_column_privilege('anon', 'public.profiles', 'select'),
  'anon can read no column of profiles at all');

select is(
  array(select c from private_cols
        where has_column_privilege('authenticated', 'public.profiles', c, 'select')
        order by 1),
  '{}'::text[],
  'authenticated holds SELECT on no private column');

select is(
  array(select c from public_cols
        where not has_column_privilege('authenticated', 'public.profiles', c, 'select')
        order by 1),
  '{}'::text[],
  'CONTROL: and on every public column -- the check above is not empty because nothing is granted');

select is_empty(
  $$ select 1 from pg_publication_tables where schemaname = 'public' and tablename = 'profiles' $$,
  'profiles is in no publication, so no postgres_changes stream can carry a row of it');

select is(
  array(select distinct p.oid::regprocedure::text
        from pg_proc p, unnest(p.proargnames, p.proargmodes) as a(n, m)
        where p.pronamespace = 'public'::regnamespace
          and m in ('o', 't', 'b')
          and n in (select c from private_cols where c <> 'created_at')
          and (has_function_privilege('anon', p.oid, 'execute')
               or has_function_privilege('authenticated', p.oid, 'execute'))
        order by 1),
  array['get_my_settings()'],
  'no function a client can call returns a private column by name, except get_my_settings');

select ok(
  (select p.prosecdef and p.pronargs = 0 and p.proconfig = array['search_path=""']
   from pg_proc p where p.oid = 'public.get_my_settings()'::regprocedure),
  'get_my_settings is security definer, pins search_path, and takes no user argument');


-- ============================================================
-- 2. Direct reads: refused per column, for another user and signed out.
-- ============================================================
select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select throws_ok(
  format('select %I from public.profiles where id = %L', c, '11111111-1111-1111-1111-111111111111'),
  '42501', null,
  format('another user cannot read profiles.%s', c))
from private_cols order by c;

select throws_ok(
  $$ select * from public.profiles $$,
  '42501', null,
  'select * is refused -- it names the private columns too');

select throws_ok(
  $$ select id from public.profiles where notification_tz = 'Europe/Athens' $$,
  '42501', null,
  'filtering on a private column is refused as well, so a WHERE clause is no oracle (PostgREST ?col=eq. filters included)');

select isnt_empty(
  $$ select id, username, bio, avatar_path, follower_count, following_count
     from public.profiles where id = '11111111-1111-1111-1111-111111111111' $$,
  'the public columns still read for another user -- ProfileRepository.fetchProfile''s exact select');

select isnt_empty(
  $$ select p.id, p.username, p.follower_count, p.following_count
     from public.follows f join public.profiles p on p.id = f.follower_id
     where f.followee_id = '11111111-1111-1111-1111-111111111111' $$,
  'and the follower-list embed''s columns (SocialRepository.fetchFollowers)');

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select throws_ok(
  $$ select notification_tz from public.profiles where id = '11111111-1111-1111-1111-111111111111' $$,
  '42501', null,
  'not even the OWNER reads a private column off the table -- a grant names a role, not a row; get_my_settings is the door');

select tests.clear_authentication(); -- anon

select throws_ok(
  format('select %I from public.profiles where id = %L', c, '11111111-1111-1111-1111-111111111111'),
  '42501', null,
  format('signed out, profiles.%s is refused', c))
from private_cols order by c;

select throws_ok(
  $$ select username from public.profiles $$,
  '42501', null,
  'signed out, not even a username is readable -- nothing signed out reads a profile');

select throws_ok(
  $$ select * from public.get_my_settings() $$,
  '42501', null,
  'anon cannot execute get_my_settings');

select throws_ok(
  $$ select public.host_on_my_map('11111111-1111-1111-1111-111111111111') $$,
  '42501', null,
  'anon cannot execute host_on_my_map');

select throws_ok(
  $$ select is_discoverable from public.profiles $$,
  '42501', null,
  'nor is_discoverable');

select throws_ok(
  $$ select * from public.get_post_comments('00000000-0000-0000-0000-000000000000') $$,
  '42501', null,
  'anon cannot execute get_post_comments any more (it held PUBLIC''s default EXECUTE)');

select throws_ok(
  $$ select * from public.get_party_stories('aaaaaaaa-0000-0000-0000-000000000002') $$,
  '42501', null,
  'nor get_party_stories');


-- ============================================================
-- 3. The owner's door.
-- ============================================================
reset role;

-- Captured as postgres, before anyone authenticates (gotcha 17).
create temp table stranger_expected on commit drop as
select onboarding_completed_at, deleted_at, location_consent, push_consent,
       analytics_consent, notify_nearby, notify_radius_meters, notify_daily_cap,
       quiet_hours_start, quiet_hours_end, notification_tz, map_visibility,
       invite_policy, dm_policy
from public.profiles where id = '44444444-4444-4444-4444-444444444444';
grant select on stranger_expected to authenticated;

update public.profiles
set notification_tz = 'Pacific/Chatham',
    quiet_hours_start = '03:17:29', quiet_hours_end = '07:43:11',
    notify_radius_meters = 4321, notify_daily_cap = 7,
    location_consent = true, push_consent = true,
    map_visibility = 'followers', invite_policy = 'following', dm_policy = 'following'
where id = '11111111-1111-1111-1111-111111111111';

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is(
  (select row(notification_tz, quiet_hours_start, quiet_hours_end, notify_radius_meters,
              notify_daily_cap, location_consent, push_consent,
              map_visibility::text, invite_policy::text, dm_policy::text)::text
   from public.get_my_settings()),
  row('Pacific/Chatham', '03:17:29'::time, '07:43:11'::time, 4321, 7, true, true,
      'followers', 'following', 'following')::text,
  'the owner reads every one of their settings through get_my_settings');

select is((select count(*)::int from public.get_my_settings()), 1,
  'exactly one row: the caller''s');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select results_eq(
  $$ select * from public.get_my_settings() $$,
  $$ select * from stranger_expected $$,
  'called by somebody else it returns THEIR settings, never the host''s -- there is no argument to point it elsewhere');

-- Writes are unchanged: the Phase 44 UPDATE list, and only `id` read in WHERE.
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select lives_ok(
  $$ update public.profiles
     set notify_nearby = false, notify_radius_meters = 1500, notify_daily_cap = 3,
         quiet_hours_start = '23:00', quiet_hours_end = '08:00',
         notification_tz = 'Pacific/Chatham',
         map_visibility = 'followers', invite_policy = 'following', dm_policy = 'following'
     where id = '11111111-1111-1111-1111-111111111111' $$,
  'the owner still writes every settings column directly (DeviceRepository.updatePrefs, ProfileRepository.updatePrivacy)');

select is(
  (select row(notify_nearby, notify_radius_meters, notify_daily_cap, quiet_hours_start)::text
   from public.get_my_settings()),
  row(false, 1500, 3, '23:00'::time)::text,
  'and reads the write back through get_my_settings');

select throws_ok(
  $$ update public.profiles set bio = 'x'
     where id = '11111111-1111-1111-1111-111111111111'
     returning notification_tz $$,
  '42501', null,
  'RETURNING a private column is a read, and refused -- which is why the client never chains .select() on these writes');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

update public.profiles set notification_tz = 'Asia/Tokyo'
where id = '11111111-1111-1111-1111-111111111111';

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host
select is((select notification_tz from public.get_my_settings()), 'Pacific/Chatham',
  'another user''s UPDATE of the host''s settings changes nothing -- the owner-only policy still holds');

-- Put the host's quiet hours back to the planted pair for section 5's scan.
reset role;
update public.profiles
set quiet_hours_start = '03:17:29', quiet_hours_end = '07:43:11', notify_nearby = true
where id = '11111111-1111-1111-1111-111111111111';


-- ============================================================
-- 4. The two invoker RPCs rewritten onto definer helpers.
-- ============================================================

-- map_visibility: host 1111 is at 'followers'. invitee 2222 follows them
-- (seed); stranger 4444 does not.
select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select is(public.host_on_my_map('11111111-1111-1111-1111-111111111111'), false,
  'host_on_my_map: a non-follower is not admitted by a followers-only host');

select is_empty(
  $$ select 1 from public.get_parties_near_user(23.7351, 37.9758, 15000)
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'so the map still hides a followers-only host''s public party from a stranger');

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee, a follower

select is(public.host_on_my_map('11111111-1111-1111-1111-111111111111'), true,
  'host_on_my_map: a follower is admitted');

select isnt_empty(
  $$ select 1 from public.get_parties_near_user(23.7351, 37.9758, 15000)
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'and the map still shows that party to a follower -- the tier is enforced, not just hidden');

-- deleted_at: friend_not_invited 3333 is scheduled for deletion and follows the host.
reset role;
update public.profiles set deleted_at = now() - interval '1 day'
where id = '33333333-3333-3333-3333-333333333333';
insert into public.follows (follower_id, followee_id)
values ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111')
on conflict do nothing;

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select is(
  (select array_agg(is_discoverable order by username) from public.profiles
   where id in ('33333333-3333-3333-3333-333333333333', '66666666-6666-6666-6666-666666666666')),
  array[false, true],
  'is_discoverable reads false for the pending account and true for a live one -- the bit, not the date');

select is_empty(
  $$ select 1 from public.search_profiles('friend_not') $$,
  'search_profiles still drops an account scheduled for deletion');

select isnt_empty(
  $$ select 1 from public.search_profiles('second_h') $$,
  'CONTROL: and still finds a live one');

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is_empty(
  $$ select 1 from public.get_invitable_followers('aaaaaaaa-0000-0000-0000-000000000001')
     where user_id = '33333333-3333-3333-3333-333333333333' $$,
  'get_invitable_followers still drops a follower scheduled for deletion');

select isnt_empty(
  $$ select 1 from public.get_invitable_followers('aaaaaaaa-0000-0000-0000-000000000002')
     where user_id = '22222222-2222-2222-2222-222222222222' $$,
  'CONTROL: and still lists a live follower');

select tests.authenticate_as('33333333-3333-3333-3333-333333333333');
select isnt((select deleted_at from public.get_my_settings()), null,
  'the account scheduled for deletion reads its own deleted_at (PendingDeletionScreen)');


-- ============================================================
-- 5. By value: no read RPC and no broadcast carries a private value.
--
-- Everyone but the caller gets the planted settings. The content the RPCs
-- return is made here as postgres, because seed.sql has no posts, comments,
-- messages or DMs.
-- ============================================================
reset role;

update public.profiles
set notification_tz = 'Pacific/Chatham',
    quiet_hours_start = '03:17:29', quiet_hours_end = '07:43:11',
    created_at = '1987-06-05 04:03:02+00'
where id <> '22222222-2222-2222-2222-222222222222';

insert into public.party_posts (id, party_id, author_id, body) values
  ('45450000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
   '11111111-1111-1111-1111-111111111111', 'see you there');
insert into public.post_comments (post_id, author_id, body) values
  ('45450000-0000-0000-0000-000000000001', '0c0c0c0c-0000-0000-0000-000000000001', 'coming!');
insert into public.messages (party_id, author_id, body) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'door code 1234');
insert into public.direct_threads (id, user_low, user_high, created_by) values
  ('45450000-0000-0000-0000-0000000000d1', '11111111-1111-1111-1111-111111111111',
   '22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111');
insert into public.direct_messages (thread_id, author_id, body) values
  ('45450000-0000-0000-0000-0000000000d1', '11111111-1111-1111-1111-111111111111', 'hey');
insert into public.rsvps (party_id, user_id, status) values
  ('aaaaaaaa-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'going')
on conflict (party_id, user_id) do update set status = excluded.status;
insert into public.blocks (blocker_id, blocked_id) values
  ('22222222-2222-2222-2222-222222222222', '55555555-5555-5555-5555-555555555555')
on conflict do nothing;

-- Runs p_sql as the CURRENT role: what the caller would receive.
create function pg_temp.scan(p_sql text, out n bigint, out leaked bigint)
language plpgsql as $$
begin
  execute format(
    'select count(*), count(*) filter (where t::text ~ %L) from (%s) t',
    'Pacific/Chatham|03:17:29|07:43:11|1987-06-05', p_sql)
  into n, leaked;
end;
$$;
grant execute on function pg_temp.scan(text) to authenticated;

create temp table rpc_calls (name text, sql text, has_rows boolean) on commit drop;
insert into rpc_calls values
  ('get_parties_near_user', $$ select * from public.get_parties_near_user(23.7351, 37.9758, 15000) $$, true),
  ('get_parties_list',      $$ select * from public.get_parties_list() $$, true),
  ('get_party',             $$ select * from public.get_party('aaaaaaaa-0000-0000-0000-000000000002') $$, true),
  ('search_parties',        $$ select * from public.search_parties('syntagma') $$, true),
  ('search_profiles',       $$ select * from public.search_profiles('host') $$, true),
  ('get_my_parties',        $$ select * from public.get_my_parties() $$, true),
  ('get_feed',              $$ select * from public.get_feed() $$, true),
  ('get_post_comments',     $$ select * from public.get_post_comments('45450000-0000-0000-0000-000000000001') $$, true),
  ('get_party_chats',       $$ select * from public.get_party_chats() $$, true),
  ('get_messages',          $$ select * from public.get_messages('aaaaaaaa-0000-0000-0000-000000000001') $$, true),
  ('get_direct_chats',      $$ select * from public.get_direct_chats() $$, true),
  ('get_direct_messages',   $$ select * from public.get_direct_messages('45450000-0000-0000-0000-0000000000d1') $$, true),
  ('get_my_blocked_accounts', $$ select * from public.get_my_blocked_accounts() $$, true),
  ('get_profile_stats',     $$ select * from public.get_profile_stats('11111111-1111-1111-1111-111111111111') $$, true),
  ('get_party_stories',     $$ select * from public.get_party_stories('aaaaaaaa-0000-0000-0000-000000000002') $$, false),
  ('get_story_rails',       $$ select * from public.get_story_rails() $$, false),
  ('get_my_settings',       $$ select * from public.get_my_settings() $$, true),
  ('export_account_data',   $$ select public.export_account_data() $$, true);
grant select on rpc_calls to authenticated;

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee, unplanted

select is(s.leaked, 0::bigint, format('%s returns no other user''s private value', c.name))
from rpc_calls c, lateral pg_temp.scan(c.sql) s order by c.name;

select ok(s.n > 0, format('CONTROL: %s returned rows, so the scan above saw something', c.name))
from rpc_calls c, lateral pg_temp.scan(c.sql) s where c.has_rows order by c.name;

-- The host-only RPCs list GUESTS, so the guests get the planted values too
-- and the host is the caller.
reset role;
update public.profiles
set notification_tz = 'Pacific/Chatham',
    quiet_hours_start = '03:17:29', quiet_hours_end = '07:43:11',
    created_at = '1987-06-05 04:03:02+00'
where id = '22222222-2222-2222-2222-222222222222';

delete from rpc_calls;
insert into rpc_calls values
  ('get_party_guests',        $$ select * from public.get_party_guests('aaaaaaaa-0000-0000-0000-000000000002') $$, true),
  ('get_party_invitees',      $$ select * from public.get_party_invitees('aaaaaaaa-0000-0000-0000-000000000001') $$, true),
  ('get_invitable_followers', $$ select * from public.get_invitable_followers('aaaaaaaa-0000-0000-0000-000000000002') $$, true),
  ('get_party_host_stats',    $$ select * from public.get_party_host_stats('aaaaaaaa-0000-0000-0000-000000000002') $$, true);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is(s.leaked, 0::bigint, format('%s (host-only) returns no guest''s private value', c.name))
from rpc_calls c, lateral pg_temp.scan(c.sql) s order by c.name;

select ok(s.n > 0, format('CONTROL: %s returned rows', c.name))
from rpc_calls c, lateral pg_temp.scan(c.sql) s where c.has_rows order by c.name;

-- Realtime, read as postgres so the topic policies are not what is filtering.
-- The inserts above fired the party, dm, inbox and party_host broadcasts.
reset role;

select is(
  array(select distinct split_part(topic, ':', 1) from realtime.messages order by 1),
  array['dm', 'inbox', 'party', 'party_host'],
  'CONTROL: all four broadcast kinds fired in this transaction');

select is(
  (select count(*) from realtime.messages
   where payload::text ~ 'Pacific/Chatham|03:17:29|07:43:11|1987-06-05'),
  0::bigint,
  'no realtime payload carries a private value');

select is_empty(
  $$ select 1 from realtime.messages m, jsonb_object_keys(m.payload) k
     where k in (select c from private_cols where c <> 'created_at') $$,
  'and no realtime payload has a key named after a private column');

select * from finish();
rollback;
