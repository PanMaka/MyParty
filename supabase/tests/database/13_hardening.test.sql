-- Phase 10: hardening.
--
-- Three groups that look unrelated and are not:
--
--   A. The Supabase linter's rules, re-expressed as assertions. The hosted
--      advisor cannot see this schema -- the linked project is still on
--      Phase 1's -- and even if it could, a dashboard nobody opens is not a
--      control. These run on every `supabase test db`.
--   B. The parties <-> invitations cross-table RLS, verified rather than read.
--   C. The three write rate limits this phase added, plus the property the
--      other two depend on.
begin;
set search_path to public, extensions;
select plan(39);


-- ============================================================
-- A. THE LINT, AS ASSERTIONS
--
-- Each of these is a rule about EVERY object of its kind, not about the
-- objects this phase happened to touch. That is the whole point: they are
-- written so that the next table, function or foreign key added to this schema
-- has to satisfy them or turn CI red.
--
-- public.spatial_ref_sys is excluded by name from the first two. It belongs to
-- PostGIS, is owned by supabase_admin, and `postgres` -- the role migrations
-- run as -- can neither enable RLS on it nor revoke its grants (42501 both
-- ways; pg_auth_members has no edge from postgres to supabase_admin). The
-- reasoning is in 20260819092958 and docs/phase-10-hardening-audit.md. It is
-- named here rather than filtered by owner so that deleting the exception is a
-- deliberate act, not a side effect of a cleverer query.
-- ============================================================

select is_empty(
  $$ select c.relname
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r'
     and not c.relrowsecurity
     and c.relname <> 'spatial_ref_sys' $$,
  'LINT rls_disabled_in_public: every table in public has RLS enabled'
);

select is_empty(
  $$ select c.relname || ' -> ' || pg_get_userbyid(a.grantee) || ': ' || a.privilege_type
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
     cross join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
     where n.nspname = 'public' and c.relkind = 'r'
     and pg_get_userbyid(a.grantee) in ('anon', 'authenticated')
     and a.privilege_type in ('TRUNCATE', 'REFERENCES', 'TRIGGER', 'MAINTAIN')
     and c.relname <> 'spatial_ref_sys' $$,
  'no table in public grants TRUNCATE/REFERENCES/TRIGGER/MAINTAIN to anon or authenticated'
);

-- The sweep is a snapshot; this is the part that keeps it true. Without it,
-- table number twenty arrives carrying the default ACL and the assertion above
-- starts failing on a table nobody did anything wrong to.
select is_empty(
  $$ select d.defaclobjtype::text || ': ' || pg_get_userbyid(a.grantee) || ' ' || a.privilege_type
     from pg_default_acl d
     cross join lateral aclexplode(d.defaclacl) a
     where d.defaclnamespace = 'public'::regnamespace
     and pg_get_userbyid(d.defaclrole) = 'postgres'
     and pg_get_userbyid(a.grantee) in ('anon', 'authenticated') $$,
  'default privileges in public no longer grant anything to anon or authenticated'
);

-- Sequences are a separate ACL from their table. UPDATE on a sequence is what
-- setval() checks, and rewinding notification_jobs_id_seq would hand out
-- primary keys that already exist.
select is_empty(
  $$ select c.relname || ' -> ' || pg_get_userbyid(a.grantee)
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
     cross join lateral aclexplode(coalesce(c.relacl, acldefault('S', c.relowner))) a
     where n.nspname = 'public' and c.relkind = 'S'
     and pg_get_userbyid(a.grantee) in ('anon', 'authenticated') $$,
  'no sequence in public is writable by anon or authenticated'
);

select is_empty(
  $$ select p.proname
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
     and not exists (
       select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e'
     )
     and (p.proconfig is null
          or not exists (
            select 1 from unnest(p.proconfig) cfg where cfg like 'search_path=%'
          )) $$,
  'LINT function_search_path_mutable: every function in public pins its search_path'
);

-- Stricter than the linter, and it is CLAUDE.md rule 3: a definer function
-- resolves names with the OWNER's privileges, so a hijacked name there is a
-- privilege escalation rather than a confusion. Those get the empty path and
-- fully-qualified references, not merely a pinned one.
select is_empty(
  $$ select p.proname
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f' and p.prosecdef
     and not exists (
       select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e'
     )
     and not coalesce(p.proconfig, '{}') @> array['search_path=""'] $$,
  'every SECURITY DEFINER function in public has search_path = '''' (rule 3)'
);

-- LINT unindexed_foreign_keys. "Covering" means an index whose LEADING columns
-- are the FK's columns -- a leading-column mismatch is exactly why Phase 8's
-- rsvps(party_id) could not answer a question about one user.
--
-- The exception list is the audit's other half. Every entry is a foreign key
-- whose parent row is never deleted, so the scan the index would serve cannot
-- happen; see 20260819093230 for the per-entry reasoning.
select is_empty(
  $$ with fk as (
       select c.conrelid, c.conname,
              (select array_agg(a.attname order by k.ord)
               from unnest(c.conkey) with ordinality k(attnum, ord)
               join pg_attribute a
                 on a.attrelid = c.conrelid and a.attnum = k.attnum) as cols
       from pg_constraint c
       join pg_class t on t.oid = c.conrelid
       join pg_namespace n on n.oid = t.relnamespace
       where c.contype = 'f' and n.nspname = 'public'
     )
     select fk.conname from fk
     where fk.conname not in (
       'messages_hidden_by_fkey',
       'party_posts_hidden_by_fkey',
       'post_comments_hidden_by_fkey',
       'post_likes_hidden_by_fkey',
       'stories_hidden_by_fkey',
       'story_media_purges_story_id_fkey'
     )
     and not exists (
       select 1 from pg_index i
       where i.indrelid = fk.conrelid
       and (select array_agg(a.attname order by k.ord)
            from unnest(i.indkey[0:array_length(fk.cols, 1) - 1])
                 with ordinality k(attnum, ord)
            join pg_attribute a
              on a.attrelid = i.indrelid and a.attnum = k.attnum) = fk.cols
     ) $$,
  'LINT unindexed_foreign_keys: every foreign key outside the documented exceptions has a covering index'
);

-- The seven this phase added, named individually. The rule above would pass if
-- someone dropped one and added it to the exception list; these will not.
select has_index('public', 'invitations',        'invitations_guest_id_idx',        'invitations(guest_id) -- complete_account_erasure');
select has_index('public', 'party_reads',        'party_reads_user_id_idx',         'party_reads(user_id) -- complete_account_erasure');
select has_index('public', 'notification_jobs',  'notification_jobs_party_id_idx',  'notification_jobs(party_id) -- the parties DELETE cascade');
select has_index('public', 'sent_notifications', 'sent_notifications_party_id_idx', 'sent_notifications(party_id) -- the parties DELETE cascade');
select has_index('public', 'party_posts',        'party_posts_author_created_idx',  'party_posts(author_id, created_at) -- export_account_data');
select has_index('public', 'post_comments',      'post_comments_author_created_idx','post_comments(author_id, created_at) -- export_account_data');
select has_index('public', 'messages',           'messages_author_created_idx',     'messages(author_id, created_at) -- export_account_data');


-- ============================================================
-- B. parties <-> invitations, CROSS-TABLE RLS
--
-- The two tables' policies reference each other: `parties` is visible via
-- can_access_party(), which reads `invitations`; `invitations` is visible to
-- the party's host, which reads `parties`. That mutual reference is what
-- 20260812121153 had to break the recursion in, and it has never been checked
-- by anything but reading.
--
-- The seeded fixture has two invitations on the private party, so
-- 01_harness_smoke's "a guest cannot see a co-guest's row" assertion does have
-- something to fail on. What it does not have is scale: at two rows every plan
-- is a seq scan, and "the policy holds" at two rows is not the same claim as
-- "the policy holds" at two hundred, where the planner reaches for an index and
-- the filter it is applied through changes shape. This adds a third named guest
-- and two hundred anonymous ones for that reason.
--
-- PARTY_PRIVATE = aaaaaaaa-0000-0000-0000-000000000001, hosted by host(1111),
-- invitee(2222) invited. PARTY_PUBLIC = ...0002, same host.
-- ============================================================

-- A co-guest, and a crowd. profiles.id has had no FK to auth.users since
-- Phase 9 (the tombstone has to outlive the auth user), so a bare profiles row
-- is a legitimate participant here and costs nothing to make.
insert into public.profiles (id, username)
values ('99999999-9999-9999-9999-999999999901', 'guest_b');

insert into public.profiles (id, username)
select ('99999999-9999-9999-9999-' || lpad((900000 + g)::text, 12, '0'))::uuid,
       'crowd_' || g
from generate_series(1, 200) g;

insert into public.invitations (party_id, guest_id)
values ('aaaaaaaa-0000-0000-0000-000000000001', '99999999-9999-9999-9999-999999999901');

insert into public.invitations (party_id, guest_id)
select 'aaaaaaaa-0000-0000-0000-000000000001',
       ('99999999-9999-9999-9999-' || lpad((900000 + g)::text, 12, '0'))::uuid
from generate_series(1, 200) g;


-- The control, captured while still authenticated AS THE HOST -- CLAUDE.md
-- gotcha #17. A control query evaluated after switching to the stranger is
-- filtered by the very policy it is controlling for: both numbers shrink
-- together, and the assertion passes against a leaking policy just as happily
-- as against a sound one.
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');

create temp table rls_control as
select count(*) as host_visible_invitations
from public.invitations
where party_id = 'aaaaaaaa-0000-0000-0000-000000000001';

select is(
  (select host_visible_invitations from rls_control)::int,
  203,
  'CONTROL: the host sees all 203 invitations on their own private party'
);

select isnt_empty(
  $$ select 1 from public.parties
     where id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'host can see their own private party'
);


select tests.authenticate_as('22222222-2222-2222-2222-222222222222'); -- invitee

select is(
  (select count(*)::int from public.invitations
   where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  1,
  'a guest sees exactly ONE invitation row on that party -- their own -- while the host sees 203'
);

select is_empty(
  $$ select 1 from public.invitations
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'
     and guest_id <> (select auth.uid()) $$,
  'a guest cannot see a co-guest''s invitation row (now that a co-guest exists)'
);

select isnt_empty(
  $$ select 1 from public.parties
     where id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'the invitation is what makes the private party visible to the guest'
);

select ok(
  public.can_access_party('aaaaaaaa-0000-0000-0000-000000000001'),
  'can_access_party agrees with the parties policy for an invited guest'
);


select tests.authenticate_as('99999999-9999-9999-9999-999999999901'); -- guest_b

select is(
  (select count(*)::int from public.invitations
   where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  1,
  'the co-guest sees exactly one row too -- the policy is per-guest, not per-party'
);


select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select is(
  (select count(*)::int from public.invitations
   where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  0,
  'a stranger sees ZERO of the 203 invitations (compare the control: 203)'
);

select is_empty(
  $$ select 1 from public.parties
     where id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'a stranger cannot see the private party at 203 invitations any more than at 2'
);

select ok(
  not public.can_access_party('aaaaaaaa-0000-0000-0000-000000000001'),
  'can_access_party agrees with the parties policy for a stranger'
);

-- The recursion guard from 20260812121153. If the two policies ever call back
-- into each other, this is where it shows up -- as a 42P17 stack error, not as
-- a wrong row count, which is why it needs its own lives_ok rather than being
-- implied by the counts above.
select lives_ok(
  $$ select count(*) from public.parties $$,
  'selecting from parties does not recurse through the invitations policy'
);

select lives_ok(
  $$ select count(*) from public.invitations $$,
  'selecting from invitations does not recurse through the parties policy'
);

-- The write direction. A stranger's INSERT is refused by the WITH CHECK, which
-- surfaces as 42501 rather than as a silently dropped row.
select throws_ok(
  $$ insert into public.invitations (party_id, guest_id)
     values ('aaaaaaaa-0000-0000-0000-000000000001',
             '44444444-4444-4444-4444-444444444444') $$,
  '42501',
  null,
  'a non-host cannot invite anyone to somebody else''s party'
);

select tests.clear_authentication();

-- Stronger than "sees no rows": anon holds no SELECT grant on invitations at
-- all, so the read is refused before any policy is consulted. CLAUDE.md gotcha
-- #4 -- table privileges are checked whether or not a WHERE clause could ever
-- be true, which is why an RPC that merely mentions a table the caller cannot
-- read errors instead of returning nothing.
select throws_ok(
  $$ select count(*) from public.invitations $$,
  '42501',
  null,
  'an unauthenticated session cannot read invitations at all -- the grant refuses before the policy is reached'
);


-- ============================================================
-- C. THE RATE LIMITS
--
-- Every one of these calls the trigger for real. A migration that applies
-- cleanly is not evidence that a function runs -- CLAUDE.md gotcha #15, which
-- this project learned from a Phase 9 function that referenced a column name
-- that does not exist and still installed green.
-- ============================================================

-- --- posts: 30 per author per hour ---
select tests.authenticate_as('22222222-2222-2222-2222-222222222222');

select lives_ok(
  $$ insert into public.party_posts (party_id, author_id, body)
     select 'aaaaaaaa-0000-0000-0000-000000000002',
            '22222222-2222-2222-2222-222222222222', 'post ' || g
     from generate_series(1, 30) g $$,
  'posts: 30 in an hour is allowed'
);

select throws_ok(
  $$ insert into public.party_posts (party_id, author_id, body)
     values ('aaaaaaaa-0000-0000-0000-000000000002',
             '22222222-2222-2222-2222-222222222222', 'one too many') $$,
  '42501',
  'post rate limit exceeded: 30 per hour',
  'posts: the 31st in an hour is refused'
);

-- The property the whole design rests on, asserted rather than assumed: a
-- BEFORE ROW trigger sees the rows its own statement inserted earlier. If that
-- were false, every per-row limit in this schema -- posts, comments, messages,
-- stories -- would be bypassable with a single PostgREST array insert, and all
-- four would still pass their one-row-at-a-time tests.
select tests.authenticate_as('44444444-4444-4444-4444-444444444444');

select throws_ok(
  $$ insert into public.party_posts (party_id, author_id, body)
     select 'aaaaaaaa-0000-0000-0000-000000000002',
            '44444444-4444-4444-4444-444444444444', 'bulk ' || g
     from generate_series(1, 31) g $$,
  '42501',
  'post rate limit exceeded: 30 per hour',
  'posts: 31 in ONE statement is refused -- a bulk insert is not a way around the limit'
);

-- Same property, on the limit that shipped in Phase 5 without a test for it.
select throws_ok(
  $$ insert into public.stories (party_id, author_id, content_type)
     select 'aaaaaaaa-0000-0000-0000-000000000002',
            '44444444-4444-4444-4444-444444444444', 'image/jpeg'
     from generate_series(1, 11) g $$,
  '42501',
  'story rate limit exceeded: 10 per hour',
  'stories: the Phase 5 limit holds against a bulk insert too'
);

-- --- comments: 100 per author per hour ---
-- `reset role`, not clear_authentication(): the latter switches to `anon`,
-- which holds no INSERT grant on anything. These rows are fixture, not
-- behaviour under test.
reset role;

insert into public.party_posts (id, party_id, author_id, body)
values ('bbbbbbbb-0000-0000-0000-000000000001',
        'aaaaaaaa-0000-0000-0000-000000000002',
        '11111111-1111-1111-1111-111111111111',
        'a post to comment on');

select tests.authenticate_as('33333333-3333-3333-3333-333333333333');

select lives_ok(
  $$ insert into public.post_comments (post_id, author_id, body)
     select 'bbbbbbbb-0000-0000-0000-000000000001',
            '33333333-3333-3333-3333-333333333333', 'comment ' || g
     from generate_series(1, 100) g $$,
  'comments: 100 in an hour is allowed'
);

select throws_ok(
  $$ insert into public.post_comments (post_id, author_id, body)
     values ('bbbbbbbb-0000-0000-0000-000000000001',
             '33333333-3333-3333-3333-333333333333', 'one too many') $$,
  '42501',
  'comment rate limit exceeded: 100 per hour',
  'comments: the 101st in an hour is refused'
);


-- --- invites: 500 per party, 1000 per host per hour ---
--
-- A fresh host, because the 202 invitations group B added all count against
-- host(1111)'s hourly budget, and a rate limit test whose baseline moves when
-- an unrelated test above it changes is a test that will fail for the wrong
-- reason one day.
reset role;

insert into public.profiles (id, username)
values ('88888888-8888-8888-8888-888888888801', 'rl_host');

insert into public.profiles (id, username)
select ('88888888-8888-8888-8888-' || lpad((800000 + g)::text, 12, '0'))::uuid,
       'rl_guest_' || g
from generate_series(1, 501) g;

create temp table rl_guests as
select ('88888888-8888-8888-8888-' || lpad((800000 + g)::text, 12, '0'))::uuid as id,
       g as n
from generate_series(1, 501) g;

-- Created as postgres, read from inside create_party_with_invites while
-- impersonating rl_host. A temp table is owned by whoever made it and inherits
-- no grants from anywhere.
grant select on rl_guests to authenticated;

select tests.authenticate_as('88888888-8888-8888-8888-888888888801');

-- 500 guests on one party: the largest legitimate event, allowed.
select lives_ok(
  $$ select public.create_party_with_invites(
       jsonb_build_object('title', 'Big One', 'lon', 23.7351, 'lat', 37.9758,
                          'starts_at', (now() + interval '1 day')::text),
       (select array_agg(id) from rl_guests where n <= 500)) $$,
  'invites: a 500-guest list in one bulk statement is allowed'
);

-- 501 on a different party: over the per-party cap. This is the assertion a
-- per-ROW trigger would have to get right too, but the statement-level one
-- answers it with a single count instead of 501.
select throws_ok(
  $$ select public.create_party_with_invites(
       jsonb_build_object('title', 'Too Big', 'lon', 23.7351, 'lat', 37.9758,
                          'starts_at', (now() + interval '1 day')::text),
       (select array_agg(id) from rl_guests)) $$,
  '42501',
  null,
  'invites: 501 guests on one party is refused -- and refused as ONE statement, not row 501'
);

-- The same 500 people, a second party: 1000 for the hour, still allowed. This
-- is the case a per-party cap alone would wave through forever.
select lives_ok(
  $$ select public.create_party_with_invites(
       jsonb_build_object('title', 'Big Two', 'lon', 23.7351, 'lat', 37.9758,
                          'starts_at', (now() + interval '1 day')::text),
       (select array_agg(id) from rl_guests where n <= 500)) $$,
  'invites: a second 500-guest party in the same hour is allowed -- 1000 is the cap, not 500'
);

select throws_ok(
  $$ select public.create_party_with_invites(
       jsonb_build_object('title', 'Big Three', 'lon', 23.7351, 'lat', 37.9758,
                          'starts_at', (now() + interval '1 day')::text),
       (select array_agg(id) from rl_guests where n <= 1)) $$,
  '42501',
  null,
  'invites: the 1001st invitation in an hour is refused however few parties it is spread over'
);

-- The rate limit is about volume; accepts_invite_from is about consent. Both
-- apply and neither substitutes -- a host well under both caps still cannot
-- invite someone whose invite_policy excludes them.
reset role;

update public.profiles set invite_policy = 'following'
where id = (select id from rl_guests where n = 1);

select tests.authenticate_as('88888888-8888-8888-8888-888888888801');

select throws_ok(
  $$ insert into public.invitations (party_id, guest_id)
     select p.id, (select id from rl_guests where n = 1)
     from public.parties p
     where p.host_id = '88888888-8888-8888-8888-888888888801'
     and p.title = 'Big One' $$,
  '42501',
  null,
  'a volume limit is not a consent gate: invite_policy still refuses, well under both caps'
);


select * from finish();
rollback;
