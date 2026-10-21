-- Phase 46: a signed-out caller reaches nothing, is_blocked is not an oracle,
-- a private party's counters reach no client, and storage reads need a
-- signed-in caller. Migrations 20261021205851, …205853, …205854, …205856.
--
-- Seed fixtures used:
--   aaaa...0001  private, host 1111, invited: 2222 + 6666
--   aaaa...0002  public,  host 1111
--   4444 stranger, 5555 blocked_user; no blocks are seeded.
begin;
set search_path to public, extensions;
select plan(27);

-- As in 08/09/10: back to postgres for fixture writes and owner-side controls.
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
-- A. anon holds nothing in public
-- ============================================================
-- Every table, view, column and sequence privilege anon holds in public.
-- spatial_ref_sys, geography_columns and geometry_columns belong to
-- supabase_admin (PostGIS), and a migration cannot revoke them (backlog §3).
select is_empty(
  $$ select c.relname, g.privilege_type
     from pg_catalog.pg_class c cross join lateral aclexplode(c.relacl) g
     where c.relnamespace = 'public'::regnamespace
       and g.grantee = 'anon'::regrole
       and c.relname not in ('spatial_ref_sys', 'geography_columns', 'geometry_columns')
     union all
     select c.relname || '.' || a.attname, g.privilege_type
     from pg_catalog.pg_class c
     join pg_catalog.pg_attribute a on a.attrelid = c.oid and a.attnum > 0
     cross join lateral aclexplode(a.attacl) g
     where c.relnamespace = 'public'::regnamespace and g.grantee = 'anon'::regrole $$,
  'anon holds no table, view, column or sequence privilege in public'
);

-- The rule that keeps it so. Postgres grants EXECUTE to PUBLIC on every new
-- function and that default cannot be revoked for one schema, so a new
-- function in public fails here until its migration revokes PUBLIC.
select is_empty(
  $$ select p.oid::regprocedure
     from pg_catalog.pg_proc p
     cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) g
     where p.pronamespace = 'public'::regnamespace
       and p.proowner = 'postgres'::regrole
       and g.grantee = 0
       and not exists (select 1 from pg_catalog.pg_depend d
                       where d.objid = p.oid and d.deptype = 'e') $$,
  'no function we own in public is executable by PUBLIC'
);

select is_empty(
  $$ select p.oid::regprocedure
     from pg_catalog.pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and p.proowner = 'postgres'::regrole
       and has_function_privilege('anon', p.oid, 'execute') $$,
  'anon can execute no function we own in public'
);

select tests.clear_authentication();

select throws_ok($$ select 1 from public.parties $$, '42501', null,
  'anon cannot read parties');
select throws_ok($$ select 1 from public.follows $$, '42501', null,
  'anon cannot read the follow graph');
select throws_ok($$ select 1 from public.party_posts $$, '42501', null,
  'anon cannot read posts');
select throws_ok($$ select 1 from public.post_comments $$, '42501', null,
  'anon cannot read comments');
select throws_ok($$ select 1 from public.post_likes $$, '42501', null,
  'anon cannot read likes');
select throws_ok($$ select public.check_username_available('someone') $$, '42501', null,
  'anon cannot probe usernames');

-- ============================================================
-- B. is_blocked answers only for a pair that includes the caller
-- ============================================================
select tests.become_owner();
insert into public.blocks (blocker_id, blocked_id)
values ('44444444-4444-4444-4444-444444444444', '55555555-5555-5555-5555-555555555555');

select ok(
  public.blocked_between('44444444-4444-4444-4444-444444444444', '55555555-5555-5555-5555-555555555555'),
  'control: the engine sees the block'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- a third party
select is(
  public.is_blocked('44444444-4444-4444-4444-444444444444', '55555555-5555-5555-5555-555555555555'),
  false,
  'a third party asking about a blocked pair learns nothing'
);
select is(
  public.is_blocked('55555555-5555-5555-5555-555555555555', '44444444-4444-4444-4444-444444444444'),
  false,
  'in either argument order'
);
select throws_ok(
  $$ select public.blocked_between('44444444-4444-4444-4444-444444444444',
                                   '55555555-5555-5555-5555-555555555555') $$,
  '42501', null,
  'and cannot reach the engine function instead'
);

select tests.authenticate_as('55555555-5555-5555-5555-555555555555'); -- the blocked one
select is(
  public.is_blocked('55555555-5555-5555-5555-555555555555', '44444444-4444-4444-4444-444444444444'),
  true,
  'a member of the pair still gets the answer, in either direction of the block'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- the blocker
select is(
  public.is_blocked('44444444-4444-4444-4444-444444444444', '55555555-5555-5555-5555-555555555555'),
  true,
  'and so does the blocker'
);
-- The policy still applies the block: the blocker cannot see the profile.
select is_empty(
  $$ select 1 from public.profiles where id = '55555555-5555-5555-5555-555555555555' $$,
  'the profiles policy still hides a blocked pair from each other'
);

-- ============================================================
-- C. A private party's counters reach no client
-- ============================================================
-- Plant a number no real party has, so a leak is visible by value.
select tests.become_owner();
update public.parties set going_count = 7777, interested_count = 7777
where id = 'aaaaaaaa-0000-0000-0000-000000000001';

select results_eq(
  $$ select public_going_count, public_interested_count from public.parties
     where id in ('aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002')
     order by id $$,
  $$ select case when is_private then null else going_count end,
            case when is_private then null else interested_count end
     from public.parties
     where id in ('aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002')
     order by id $$,
  'the public columns are the counters on a public party and NULL on a private one'
);

select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

select throws_ok(
  $$ select going_count from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  '42501', null,
  'an invitee cannot read the raw going_count off the table'
);
select throws_ok(
  $$ select interested_count from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  '42501', null,
  'nor interested_count'
);
select is(
  (select public_going_count from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  null,
  'the public column the invitee CAN read is NULL on the private party'
);

-- get_party_chats was the second door: chat exists only on private parties.
select isnt_empty(
  $$ select 1 from public.get_party_chats() where party_id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'fixture sanity: the invitee has the private party in their chat list'
);
select is(
  (select going_count from public.get_party_chats() where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  null,
  'get_party_chats no longer returns the private party''s going_count to a member'
);

select is_empty(
  $$ select 1 from public.get_party('aaaaaaaa-0000-0000-0000-000000000001')
       where 7777 in (going_count, interested_count)
     union all
     select 1 from public.get_my_parties() where 7777 in (going_count, interested_count)
     union all
     select 1 from public.get_parties_list('interested', 100) where 7777 in (going_count, interested_count)
     union all
     select 1 from public.get_party_chats() where going_count = 7777 $$,
  'the planted number appears in no attendee read'
);

select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host
select is(
  (select going_count from public.get_party_chats() where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  null,
  'the chat list is an attendee surface: NULL for the host too'
);
select is(
  (select going_count from public.get_my_hosted_parties() where id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  7777,
  'the host still reads their own private party''s real count through get_my_hosted_parties'
);

-- ============================================================
-- D. Storage reads need a signed-in caller
-- ============================================================
select tests.become_owner();
select is_empty(
  $$ select policyname from pg_policies
     where schemaname = 'storage' and tablename = 'objects'
       and ('anon' = any(roles) or 'public' = any(roles)) $$,
  'no storage.objects policy applies to anon'
);
select ok(
  (select public from storage.buckets where id = 'avatars'),
  'the avatars bucket stays public, so a known avatar URL still loads signed out (Option 1)'
);

select * from finish();
rollback;
