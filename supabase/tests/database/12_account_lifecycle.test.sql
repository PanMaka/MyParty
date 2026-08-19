-- Phase 9: account deletion, erasure, and the FK graph that makes it safe.
--
-- Most of this file is structural. The behaviour it protects -- "a deleted
-- user's messages stay in the thread" -- is one assertion; the reason it needs
-- a whole test file is that the behaviour is produced by EIGHT foreign key
-- definitions, and a single `on delete cascade` reintroduced by a well-meaning
-- migration would silently restore the old semantics. Nothing in the app would
-- look different until somebody actually deleted an account, at which point a
-- party's entire chat history would be gone with no way to get it back.
--
-- So the FK actions are asserted directly against pg_constraint, the same way
-- 08 asserts over pg_attribute that there are exactly two geography columns.
-- A schema fact that only reveals itself during an irreversible operation has
-- to be checked by CI, because it cannot be checked in review.
--
-- Personas (seed.sql): host 1111, invitee 2222, friend_not_invited 3333,
-- stranger 4444, blocked_user 5555, second_host 6666. Seeded parties used:
--   aaaa...0001  private, hosted by 1111, invitee 2222 invited
--   aaaa...0002  public,  hosted by 1111 ("Syntagma Afterparty")
begin;
set search_path to public, extensions;
select plan(49);


-- ============================================================
-- 1. The FK graph. Structural, and the most valuable thing in this file.
-- ============================================================

-- A helper rather than 8 copies of the same correlated subquery. confdeltype
-- is a single char: 'c' cascade, 'a' no action, 'n' set null, 'r' restrict.
create or replace function tests.fk_delete_action(p_table text, p_column text)
returns text
language sql
stable
as $$
  select case c.confdeltype
           when 'c' then 'cascade'
           when 'a' then 'no action'
           when 'n' then 'set null'
           when 'r' then 'restrict'
           else c.confdeltype::text
         end
  from pg_constraint c
  join pg_class t on t.oid = c.conrelid
  join pg_attribute a on a.attrelid = c.conrelid and a.attnum = c.conkey[1]
  where c.contype = 'f'
    and t.relname = p_table
    and a.attname = p_column
    and t.relnamespace = 'public'::regnamespace
    and array_length(c.conkey, 1) = 1;
$$;

-- The seven that must NOT cascade. Each one has a different reason and a
-- different blast radius; see docs/phase-09-fk-audit.md §3.
select is(tests.fk_delete_action('parties', 'host_id'), 'no action',
  'parties.host_id must not cascade -- it is what turns one account deletion into a party''s worth of other people''s messages');

select is(tests.fk_delete_action('messages', 'author_id'), 'no action',
  'messages.author_id must not cascade -- the deleted user''s messages stay in the thread');

select is(tests.fk_delete_action('party_posts', 'author_id'), 'no action',
  'party_posts.author_id must not cascade -- the post owns a comment thread belonging to other people');

select is(tests.fk_delete_action('post_comments', 'author_id'), 'no action',
  'post_comments.author_id must not cascade -- a thread with holes is the failure this phase exists to prevent');

select is(tests.fk_delete_action('reports', 'reporter_id'), 'no action',
  'reports.reporter_id must not cascade -- otherwise "report, then delete your account" erases the evidence');

select is(tests.fk_delete_action('blocks', 'blocker_id'), 'no action',
  'blocks.blocker_id must not cascade -- is_blocked is symmetric, so dropping the edge un-hides retained content');

select is(tests.fk_delete_action('blocks', 'blocked_id'), 'no action',
  'blocks.blocked_id must not cascade -- same reason, opposite direction');

-- The ones that must STILL cascade. Asserted because "make deletion safe" is
-- exactly the kind of instruction that gets over-applied: turning these into
-- no action would make erasure fail on its first delete instead.
select is(tests.fk_delete_action('rsvps', 'user_id'), 'cascade',
  'rsvps.user_id still cascades -- attendance is the user''s own data and is deleted at erasure');

select is(tests.fk_delete_action('story_views', 'story_id'), 'cascade',
  'story_views.story_id still cascades -- object-scoped, not user-scoped');

select is(tests.fk_delete_action('story_media_purges', 'story_id'), 'set null',
  'story_media_purges.story_id stays set null -- the purge queue must outlive the story it is purging');

-- The FK that must be GONE. A tombstone profile cannot reference an auth.users
-- row that no longer exists, and a primary key cannot be set null.
select is(
  (select count(*)::int
   from pg_constraint c
   join pg_class t on t.oid = c.conrelid
   where c.contype = 'f' and t.relname = 'profiles'
     and t.relnamespace = 'public'::regnamespace
     and c.confrelid = 'auth.users'::regclass),
  0,
  'profiles.id -> auth.users is dropped -- the tombstone has to outlive the auth user');

-- What replaces the guarantee that FK was providing. A tombstone is an orphan
-- on purpose, so the check is scoped to live accounts rather than weakened.
select is(
  (select count(*)::int
   from public.profiles p
   where p.deleted_at is null
     and not exists (select 1 from auth.users u where u.id = p.id)),
  0,
  'every LIVE profile still has an auth.users row -- the orphan check that replaces the dropped FK');


-- ============================================================
-- 2. request_account_deletion -- what happens at T+0.
-- ============================================================

-- A device with a location, so the purge has something to purge. Written as
-- the user, through the consent gate, exactly as the client would.
update public.profiles set location_consent = true, push_consent = true
where id = '33333333-3333-3333-3333-333333333333';

select tests.authenticate_as('33333333-3333-3333-3333-333333333333');

select lives_ok(
  $$ select public.upsert_user_device('tok_phase9_a', 'android', 37.9755, 23.7348) $$,
  'control: the user can register a device with a location before deleting');

-- A future party, which must be cancelled, and a past one, which must not.
insert into public.parties (id, host_id, title, location, starts_at, status)
values
  ('cccccccc-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333',
   'Future Party', st_point(23.7348, 37.9755)::geography, now() + interval '3 days', 'published'),
  ('cccccccc-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333333',
   'Past Party', st_point(23.7348, 37.9755)::geography, now() - interval '10 days', 'published');

select isnt(
  (select public.request_account_deletion()), null,
  'request_account_deletion returns the deletion timestamp');

select isnt(
  (select deleted_at from public.profiles where id = '33333333-3333-3333-3333-333333333333'),
  null,
  'deleted_at is set');

select is(
  (select erased_at from public.profiles where id = '33333333-3333-3333-3333-333333333333'),
  null,
  'erased_at is NOT set -- 30 days of grace, not immediate erasure');

-- The PURGE NOW set. This is the GDPR-load-bearing half: the grace period is
-- for recovering an account, not a licence to keep processing location for
-- another month.
select is(
  (select count(*)::int from public.user_devices where user_id = '33333333-3333-3333-3333-333333333333'),
  0,
  'user_devices is purged IMMEDIATELY -- last_location does not wait out the grace period');

select is(
  (select location_consent from public.profiles where id = '33333333-3333-3333-3333-333333333333'),
  false,
  'location_consent is withdrawn, which also fires 7a''s erasure trigger');

select is(
  (select status::text from public.parties where id = 'cccccccc-0000-0000-0000-000000000001'),
  'cancelled',
  'a party that has not started is cancelled -- nobody turns up to a hostless event');

select is(
  (select status::text from public.parties where id = 'cccccccc-0000-0000-0000-000000000002'),
  'published',
  'a party that already happened is NOT touched -- ended parties are retained indefinitely');

-- Idempotence: the second tap must not restart the clock. Failing the other
-- way -- extending the grace period every time a nervous user reopens the
-- screen -- would be a deletion that never happens.
select is(
  (select public.request_account_deletion()),
  (select deleted_at from public.profiles where id = '33333333-3333-3333-3333-333333333333'),
  'calling it twice returns the ORIGINAL timestamp and does not restart the 30 days');


-- ============================================================
-- 3. The markers are not client-writable.
--
-- profiles carries a table-wide UPDATE grant and RLS cannot protect a column
-- (gotcha #8), so without the trigger a client could backdate deleted_at and
-- have itself erased tonight, or set erased_at on a live account.
-- ============================================================
update public.profiles
set deleted_at = now() - interval '90 days'
where id = '33333333-3333-3333-3333-333333333333';

select ok(
  (select deleted_at from public.profiles where id = '33333333-3333-3333-3333-333333333333')
    > now() - interval '1 day',
  'a client cannot backdate deleted_at to skip the grace period -- the trigger freezes it');

update public.profiles set erased_at = now()
where id = '33333333-3333-3333-3333-333333333333';

select is(
  (select erased_at from public.profiles where id = '33333333-3333-3333-3333-333333333333'),
  null,
  'a client cannot set erased_at on its own live account');


-- ============================================================
-- 4. Discovery suppression, and the one place it must NOT be.
-- ============================================================

-- The map needs no filter of its own: request_account_deletion cancelled the
-- only parties it would have shown. This asserts the OUTCOME rather than the
-- mechanism, so the day someone changes how cancellation works, this fails.
select is(
  (select count(*)::int
   from public.get_parties_near_user(23.7348, 37.9755, 5000) g
   where g.party_id = 'cccccccc-0000-0000-0000-000000000001'),
  0,
  'a deleted user''s upcoming party is off the map');

-- The profile row itself must STAY selectable. This is the assertion most
-- likely to be "fixed" by a future reviewer who adds `deleted_at is null` to
-- the profiles SELECT policy -- which would drop every message by that author
-- out of get_messages, because that RPC inner-joins profiles under invoker
-- rights. The label is a client concern; the row is load-bearing.
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');

select is(
  (select count(*)::int from public.profiles where id = '33333333-3333-3333-3333-333333333333'),
  1,
  'a deleted user''s profile row is STILL VISIBLE to other users -- hiding it would delete their messages from every thread');

select is(
  public.accepts_invite_from('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111'),
  false,
  'nobody can invite an account that is on its way out');

-- Asserted as postgres, not as a signed-in user: wants_nearby_notifications is
-- revoked from authenticated (20260817073509), because it answers a question
-- about OTHER people's push preferences. The engine calls it, clients never do.
select tests.clear_authentication();
set local role postgres;

select is(
  public.wants_nearby_notifications('33333333-3333-3333-3333-333333333333'),
  false,
  'a deleted account stops being a notification target immediately');


-- ============================================================
-- 5. Erasure: the claim respects the grace period.
-- ============================================================

select is(
  (select count(*)::int from public.claim_accounts_for_erasure(10)),
  0,
  'an account inside its grace period is NOT claimable');

select throws_ok(
  $$ select public.complete_account_erasure('33333333-3333-3333-3333-333333333333') $$,
  'P0001',
  null,
  'complete_account_erasure refuses to erase inside the grace period even when called directly with a service key');

-- Age the request past 30 days. Done as postgres, which is the only role the
-- section-3 trigger lets through -- which is itself the point of section 3.
update public.profiles
set deleted_at = now() - interval '31 days'
where id = '33333333-3333-3333-3333-333333333333';

select is(
  (select count(*)::int from public.claim_accounts_for_erasure(10)),
  1,
  'past the grace period the account is claimed exactly once');

select is(
  (select count(*)::int from public.claim_accounts_for_erasure(10)),
  0,
  'a second claim returns nothing -- claimed_at is the in-flight lock, so two concurrent erasers cannot both take one account');


-- ============================================================
-- 6. Erasure: content survives, and it survives ATTRIBUTED.
--
-- The whole point of the phase, in five assertions.
-- ============================================================

-- Give the doomed user something to leave behind: an rsvp (deleted), a message
-- in someone else's party (retained), and a follow edge (deleted).
insert into public.rsvps (party_id, user_id, status)
values ('aaaaaaaa-0000-0000-0000-000000000002', '33333333-3333-3333-3333-333333333333', 'going');

insert into public.messages (id, party_id, author_id, body)
values ('dddddddd-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
        '33333333-3333-3333-3333-333333333333', 'see you all there');

insert into public.follows (follower_id, followee_id)
values ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111');

-- Captured BEFORE erasure, in a temp table. Reading it afterwards would be
-- reading a number the erasure itself changed -- gotcha #15's failure mode.
create temp table control_counts as
select
  (select follower_count from public.profiles where id = '11111111-1111-1111-1111-111111111111') as host_followers,
  (select going_count from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000002') as going;

select lives_ok(
  $$ select public.complete_account_erasure('33333333-3333-3333-3333-333333333333') $$,
  'complete_account_erasure runs once the grace period has expired');

select is(
  (select count(*)::int from public.messages where id = 'dddddddd-0000-0000-0000-000000000001'),
  1,
  'THE POINT OF THIS PHASE: the erased user''s message is still in the thread');

select is(
  (select author_id from public.messages where id = 'dddddddd-0000-0000-0000-000000000001'),
  '33333333-3333-3333-3333-333333333333'::uuid,
  'and it is still attributed -- author_id points at the tombstone, not at null');

select is(
  (select count(*)::int from public.profiles
   where id = '33333333-3333-3333-3333-333333333333' and erased_at is not null),
  1,
  'the profiles row survives as a tombstone');

select isnt(
  (select username from public.profiles where id = '33333333-3333-3333-3333-333333333333'),
  'friend_not_invited',
  'the username is scrubbed to an opaque handle -- no human will ever type it into search');

select is(
  (select count(*)::int from public.rsvps where user_id = '33333333-3333-3333-3333-333333333333'),
  0,
  'the rsvp is deleted -- attendance is the user''s own data');

select is(
  (select follower_count from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  (select host_followers - 1 from control_counts),
  'the follow edge is deleted AND the surviving user''s counter is corrected by the trigger');

select is(
  (select going_count from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000002'),
  (select going - 1 from control_counts),
  'going_count is decremented on a party the erased user had rsvp''d to (audit §6.2, accepted)');


-- ============================================================
-- 7. Idempotence and the queue's state machine.
-- ============================================================
select lives_ok(
  $$ select public.complete_account_erasure('33333333-3333-3333-3333-333333333333') $$,
  'complete_account_erasure is idempotent -- a retry after a crash between the DB write and the auth delete is safe');

select is(
  (select count(*)::int from public.account_erasures
   where user_id = '33333333-3333-3333-3333-333333333333' and completed_at is not null),
  1,
  'the queue row is completed');

select is(
  (select count(*)::int from public.claim_accounts_for_erasure(10)),
  0,
  'a completed account is never claimed again');


-- ============================================================
-- 8. The queue is invisible to clients.
--
-- gotcha #9: every table in public is created holding TRUNCATE from anon, and
-- RLS does not mediate TRUNCATE -- so an RLS-perfect table is still one anon
-- could empty. The migration revokes it; this proves the revoke happened.
-- ============================================================
select ok(
  not has_table_privilege('anon', 'public.account_erasures', 'SELECT'),
  'anon cannot read the erasure queue');

select ok(
  not has_table_privilege('authenticated', 'public.account_erasures', 'TRUNCATE'),
  'authenticated cannot TRUNCATE the erasure queue -- the default ACL is revoked');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.account_erasures'::regclass),
  'RLS is enabled on account_erasures');


-- ============================================================
-- 9. Export.
-- ============================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');

select is(
  (select public.export_account_data() -> 'user_id') #>> '{}',
  '11111111-1111-1111-1111-111111111111',
  'export_account_data exports the CALLER -- it takes no user id, so there is nothing to aim elsewhere');

select ok(
  (select public.export_account_data() ? 'parties'
      and public.export_account_data() ? 'rsvps'
      and public.export_account_data() ? 'posts'
      and public.export_account_data() ? 'messages'
      and public.export_account_data() ? 'comments'),
  'the export carries every section the brief asked for, plus comments');

select ok(
  not (select public.export_account_data() -> 'profile' ? 'credibility_score'),
  'the export does NOT contain credibility_score -- Phase 8 ships no score, and a zero in a file is a number someone asks about');

select ok(
  not (select public.export_account_data() ? 'user_devices'),
  'the export does NOT contain a location -- an exportable location history is the one thing 7.2 spent a phase preventing');


select * from finish();
rollback;
