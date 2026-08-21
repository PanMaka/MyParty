-- Phase 12: the rewritten `parties` SELECT policy.
--
-- This file is load-bearing in a way most test files are not. The migration it
-- guards (20260821185216) hoists three terms out of `can_user_access_party`
-- into the policy itself, so party visibility is now written in TWO places --
-- a deliberate exception to CLAUDE.md rule #4, taken because the hoist is what
-- lets the planner reach `parties_location` (995ms -> single-digit ms at 5km
-- zoom). The exception is only acceptable because section 1 below turns drift
-- between the two copies into a red test instead of a silent divergence.
--
-- If you are here because you added a term to `can_user_access_party` and this
-- file went red: that is the file working. Add the term to the policy too, or
-- decide it belongs only in the helper and narrow the equivalence set on
-- purpose.
--
-- Personas (seed.sql): host 1111, invitee 2222, friend_not_invited 3333,
-- stranger 4444, blocked_user 5555, second_host 6666.
--
-- Seeded parties with stable ids, which is the whole fixture set this file
-- reasons about by name:
--   aaaa...0001  private, host 1111, invited: 2222 + 6666
--   aaaa...0002  public,  host 1111
--   aaaa...0013  private, host 6666, invited: 1111
--   aaaa...0019  private, host 1111, invited: 6666
--   aaaa...0021  public,  host 5555
--   aaaa...0022  private, host 5555, invited: 1111
-- No blocks are seeded; they are created inside this transaction.
begin;
set search_path to public, extensions;
select plan(65);


-- ============================================================
-- 0. Fixtures
--
-- Two blocks, in OPPOSITE directions, because `is_blocked` is symmetric and a
-- test that only ever blocks one way cannot tell a symmetric rule from a
-- one-directional one (gotcha 14's lesson, applied to blocks):
--   5555 blocked 4444  -- the host blocked the viewer
--   4444 blocked 6666  -- the viewer blocked the host
-- ============================================================

insert into public.blocks (blocker_id, blocked_id) values
  ('55555555-5555-5555-5555-555555555555', '44444444-4444-4444-4444-444444444444'),
  ('44444444-4444-4444-4444-444444444444', '66666666-6666-6666-6666-666666666666');

-- Two draft parties, for section 3. The seed has none, and `status` is exactly
-- the kind of column a "tidy" rewrite might be tempted to filter on.
--
-- TWO, one per privacy flag, because the interesting assertion is not "a draft
-- is hidden" -- it is that `status` plays NO part in the decision either way.
-- A private draft is invisible to a stranger because it is private; a PUBLIC
-- draft is visible to a stranger, and that second fact is the one that fails
-- the moment somebody adds `and status = 'published'` to the policy.
insert into public.parties (id, host_id, title, description, location, starts_at, is_private, status)
values
  ('aaaaaaaa-0000-0000-0000-0000000000d1',
   '11111111-1111-1111-1111-111111111111',
   'Unannounced Warehouse',
   'Private draft: only the host should see this, because it is PRIVATE.',
   st_point(23.7349, 37.9756)::geography, now() + interval '20 days', true, 'draft'),
  ('aaaaaaaa-0000-0000-0000-0000000000d2',
   '11111111-1111-1111-1111-111111111111',
   'Unannounced Open Air',
   'Public draft: everyone should see this, because status is not a visibility term.',
   st_point(23.7347, 37.9754)::geography, now() + interval '20 days', false, 'draft');


-- ============================================================
-- 1. The equivalence assertion (section 5.1 of the brief)
--
-- For every party in the database and every viewer, assert that the set of
-- rows the POLICY admits is exactly the set `can_user_access_party` admits.
-- Both directions, separately -- one containment passing tells you nothing
-- about the other, and a policy that admits nothing would satisfy the first
-- one trivially.
--
-- Two implementation notes that are not incidental:
--
--   * The expected set is captured HERE, as `postgres`, BEFORE any
--     `tests.authenticate_as`. That is gotcha 17: a control query written
--     against `public.parties` after authenticating is filtered by the very
--     policy it is controlling for, so it shrinks in lockstep with the thing
--     under test and would pass against a policy that leaks or one that hides
--     everything. `postgres` owns the table and RLS is not forced, so this
--     select really does see all rows.
--
--   * The helper is called as `postgres` with an explicit user id rather than
--     as the viewer with `auth.uid()`. Not a shortcut -- `authenticated` has
--     no EXECUTE on `can_user_access_party` (its proacl is
--     {postgres=X/postgres}; gotcha 13's revoke), so the brief's sketch of
--     this assertion cannot run as written. It is exactly equivalent: the
--     function is SECURITY DEFINER, so its body runs as the owner either way,
--     and the only input is the uuid passed in.
-- ============================================================

create temp table expected_visibility as
select
  p.id,
  p.title,
  v.viewer,
  public.can_user_access_party(v.viewer, p.id) as helper_admits
from public.parties p
cross join (values
  ('11111111-1111-1111-1111-111111111111'::uuid),  -- host
  ('22222222-2222-2222-2222-222222222222'::uuid),  -- invitee
  ('33333333-3333-3333-3333-333333333333'::uuid),  -- friend_not_invited
  ('44444444-4444-4444-4444-444444444444'::uuid),  -- stranger
  ('55555555-5555-5555-5555-555555555555'::uuid),  -- blocked_user
  ('66666666-6666-6666-6666-666666666666'::uuid),  -- second_host
  (null::uuid)                                     -- anon
) as v(viewer);

grant select on expected_visibility to authenticated, anon;

-- A guard on the guard: if the fixture set were empty or the helper answered
-- uniformly, every containment assertion below would pass vacuously.
select isnt_empty(
  $$ select 1 from expected_visibility where helper_admits $$,
  'fixture sanity: the helper admits at least one row'
);
select isnt_empty(
  $$ select 1 from expected_visibility where not helper_admits $$,
  'fixture sanity: the helper refuses at least one row -- the matrix is not vacuous'
);

-- ---------- host ----------
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');

select is_empty(
  $$ select p.id from public.parties p
     join expected_visibility e
       on e.id = p.id and e.viewer = '11111111-1111-1111-1111-111111111111'
     where not e.helper_admits $$,
  'host: every row the policy admits, the helper admits too'
);
select is_empty(
  $$ select e.id from expected_visibility e
     where e.viewer = '11111111-1111-1111-1111-111111111111'
       and e.helper_admits
       and not exists (select 1 from public.parties p where p.id = e.id) $$,
  'host: every row the helper admits, the policy admits too'
);

-- ---------- invitee ----------
select tests.authenticate_as('22222222-2222-2222-2222-222222222222');

select is_empty(
  $$ select p.id from public.parties p
     join expected_visibility e
       on e.id = p.id and e.viewer = '22222222-2222-2222-2222-222222222222'
     where not e.helper_admits $$,
  'invitee: every row the policy admits, the helper admits too'
);
select is_empty(
  $$ select e.id from expected_visibility e
     where e.viewer = '22222222-2222-2222-2222-222222222222'
       and e.helper_admits
       and not exists (select 1 from public.parties p where p.id = e.id) $$,
  'invitee: every row the helper admits, the policy admits too'
);

-- ---------- friend_not_invited ----------
select tests.authenticate_as('33333333-3333-3333-3333-333333333333');

select is_empty(
  $$ select p.id from public.parties p
     join expected_visibility e
       on e.id = p.id and e.viewer = '33333333-3333-3333-3333-333333333333'
     where not e.helper_admits $$,
  'friend_not_invited: every row the policy admits, the helper admits too'
);
select is_empty(
  $$ select e.id from expected_visibility e
     where e.viewer = '33333333-3333-3333-3333-333333333333'
       and e.helper_admits
       and not exists (select 1 from public.parties p where p.id = e.id) $$,
  'friend_not_invited: every row the helper admits, the policy admits too'
);

-- ---------- stranger (blocked BY 5555, and blocker OF 6666) ----------
select tests.authenticate_as('44444444-4444-4444-4444-444444444444');

select is_empty(
  $$ select p.id from public.parties p
     join expected_visibility e
       on e.id = p.id and e.viewer = '44444444-4444-4444-4444-444444444444'
     where not e.helper_admits $$,
  'stranger: every row the policy admits, the helper admits too'
);
select is_empty(
  $$ select e.id from expected_visibility e
     where e.viewer = '44444444-4444-4444-4444-444444444444'
       and e.helper_admits
       and not exists (select 1 from public.parties p where p.id = e.id) $$,
  'stranger: every row the helper admits, the policy admits too'
);

-- ---------- blocked_user ----------
select tests.authenticate_as('55555555-5555-5555-5555-555555555555');

select is_empty(
  $$ select p.id from public.parties p
     join expected_visibility e
       on e.id = p.id and e.viewer = '55555555-5555-5555-5555-555555555555'
     where not e.helper_admits $$,
  'blocked_user: every row the policy admits, the helper admits too'
);
select is_empty(
  $$ select e.id from expected_visibility e
     where e.viewer = '55555555-5555-5555-5555-555555555555'
       and e.helper_admits
       and not exists (select 1 from public.parties p where p.id = e.id) $$,
  'blocked_user: every row the helper admits, the policy admits too'
);

-- ---------- second_host ----------
select tests.authenticate_as('66666666-6666-6666-6666-666666666666');

select is_empty(
  $$ select p.id from public.parties p
     join expected_visibility e
       on e.id = p.id and e.viewer = '66666666-6666-6666-6666-666666666666'
     where not e.helper_admits $$,
  'second_host: every row the policy admits, the helper admits too'
);
select is_empty(
  $$ select e.id from expected_visibility e
     where e.viewer = '66666666-6666-6666-6666-666666666666'
       and e.helper_admits
       and not exists (select 1 from public.parties p where p.id = e.id) $$,
  'second_host: every row the helper admits, the policy admits too'
);

-- ---------- anon ----------
-- The row that carries the most risk in the whole file. See section 2.
select tests.clear_authentication();

select is_empty(
  $$ select p.id from public.parties p
     join expected_visibility e on e.id = p.id and e.viewer is null
     where not e.helper_admits $$,
  'anon: every row the policy admits, the helper admits too'
);
select is_empty(
  $$ select e.id from expected_visibility e
     where e.viewer is null
       and e.helper_admits
       and not exists (select 1 from public.parties p where p.id = e.id) $$,
  'anon: every row the helper admits, the policy admits too'
);


-- ============================================================
-- 2. The visibility matrix (section 5.2)
--
-- The equivalence above proves the two copies agree. It does NOT prove they
-- agree on the right answer -- both could be wrong together, and a rewrite
-- that dropped a term from the helper as well as the policy would sail
-- through section 1. So the matrix pins the actual answers, by name, per cell.
-- ============================================================

-- ---------- viewer: the party's host ----------
-- Every cell is ✓, including a private party they host but hold no invitation
-- row for: `host_id = (select auth.uid())` short-circuits before the probe.
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');

select isnt_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'host sees their own public party'
);
select isnt_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'host sees their own private party -- via host_id, with no invitation row of their own'
);
select is_empty(
  $$ select 1 from public.invitations
     where party_id = 'aaaaaaaa-0000-0000-0000-000000000001'
       and guest_id = '11111111-1111-1111-1111-111111111111' $$,
  'control: the host really has no invitation to their own private party'
);
select isnt_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000013' $$,
  'host sees a private party they were invited to by someone else'
);
select isnt_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000022' $$,
  'host sees blocked_user''s private party they are invited to -- no block between them'
);

-- ---------- viewer: invitee ----------
select tests.authenticate_as('22222222-2222-2222-2222-222222222222');

select isnt_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'invitee sees a public party'
);
select isnt_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'invitee sees the private party they were invited to'
);
select is_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000013' $$,
  'invitee cannot see a private party they were not invited to'
);
select is_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000019' $$,
  'invitee cannot see another private party they were not invited to'
);

-- ---------- viewer: stranger, with blocks in both directions ----------
select tests.authenticate_as('44444444-4444-4444-4444-444444444444');

select isnt_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'stranger sees a public party from an unblocked host'
);
select is_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'stranger cannot see a private party they were not invited to'
);
-- Direction A: the HOST blocked the viewer (5555 -> 4444).
select is_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000021' $$,
  'stranger cannot see a PUBLIC party whose host blocked them -- the block beats not is_private'
);
select is_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000022' $$,
  'stranger cannot see a private party whose host blocked them'
);
-- Direction B: the VIEWER blocked the host (4444 -> 6666). Asserted
-- separately, because is_blocked is symmetric and a one-directional bug
-- passes direction A while failing this.
select is_empty(
  $$ select 1 from public.parties p
     where p.host_id = '66666666-6666-6666-6666-666666666666'
       and not p.is_private $$,
  'stranger cannot see ANY public party hosted by someone THEY blocked'
);
select isnt_empty(
  $$ select 1 from public.parties p
     where p.host_id = '11111111-1111-1111-1111-111111111111'
       and not p.is_private $$,
  'control: the stranger still sees public parties from hosts neither side blocked'
);

-- ---------- viewer: anon ----------
-- `is_blocked` returns false when either argument is null, so
-- `not is_blocked(null, host_id)` is TRUE and an anonymous caller keeps seeing
-- every public party -- including ones hosted by users who are in a block
-- relationship with somebody else. That is current behaviour and must not
-- change.
--
-- The brief predicted the failure mode here would be a hoist spelled
--   host_id not in (select blocked_id from public.blocks
--                   where blocker_id = (select auth.uid()))
-- collapsing anon's result set via NULL-in-list. That was ASSERTED rather than
-- reasoned about, and the assertion says it does not reproduce -- for two
-- independent reasons, both measured against this database:
--
--   1. `NULL not in (<empty set>)` is TRUE, not NULL. For anon,
--      `blocker_id = (select auth.uid())` matches nothing, so the list is
--      empty and NOT IN is well-defined. NULL-in-list needs a NULL *inside*
--      a non-empty list, or a NULL on the left of a non-empty one.
--   2. Even a spelling that puts `auth.uid()` on the left cannot bite, because
--      the `blocks` SELECT policy is `blocker_id = (select auth.uid())` -- anon
--      can read no block rows at all, so any inlined subquery on `blocks` is
--      empty for anon whatever its shape.
--
-- The inlined hoist IS broken, just not here and not for that reason: it fails
-- for the STRANGER, and section 1's equivalence assertion catches it on the
-- first run. The `blocks` policy only exposes rows where the viewer is the
-- BLOCKER, so an inlined probe cannot see "the host blocked me" -- exactly half
-- of a symmetric relation. That is the second reason `is_blocked` must stay
-- SECURITY DEFINER, alongside the 42P17 one, and it is the sharper of the two
-- because it produces a silent visibility LEAK rather than a loud error.
--
-- The assertions below stay regardless, and they are not decorative: verified
-- by gating the policy on `(select auth.uid()) is not null`, which fires seven
-- of them including the equivalence direction and the degenerate-set guard.
select tests.clear_authentication();

select isnt_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'anon sees a public party'
);
select isnt_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000021' $$,
  'anon sees a public party whose host blocked SOMEBODY ELSE -- blocks are irrelevant to anon'
);
select isnt_empty(
  $$ select 1 from public.parties p
     where p.host_id = '66666666-6666-6666-6666-666666666666'
       and not p.is_private $$,
  'anon sees public parties hosted by a user somebody else blocked'
);
-- The blunt form of the same guard: not "anon sees this row" but "anon sees
-- roughly what it should". A NULL-in-list hoist returns zero rows here while
-- every single-row assertion above could in principle be satisfied by an
-- unrelated bug.
select is(
  (select count(*)::int from public.parties),
  (select count(*)::int from expected_visibility where viewer is null and helper_admits),
  'anon sees exactly as many parties as the helper admits -- not zero'
);
select cmp_ok(
  (select count(*)::int from public.parties), '>', 10,
  'anon''s visible set is a real number of public parties, not a degenerate one'
);
select is_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'anon cannot see a private party'
);
select is_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000022' $$,
  'anon cannot see a private party whose host has blocks against them'
);


-- ============================================================
-- 3. Statuses the policy does not filter (section 5.3)
--
-- The policy says nothing about `status` and must continue not to.
-- `get_my_hosted_parties` filters status explicitly BECAUSE the policy does
-- not; a policy that started filtering drafts would make that RPC's filter
-- redundant and silently change what a host sees of their own parties.
-- ============================================================

select tests.authenticate_as('11111111-1111-1111-1111-111111111111');

select isnt_empty(
  $$ select 1 from public.parties
     where id = 'aaaaaaaa-0000-0000-0000-0000000000d1' and status = 'draft' $$,
  'a host sees their own private DRAFT party -- the policy does not filter status'
);
select isnt_empty(
  $$ select 1 from public.parties
     where id = 'aaaaaaaa-0000-0000-0000-0000000000d2' and status = 'draft' $$,
  'a host sees their own public draft too'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444');
select is_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-0000000000d1' $$,
  'a stranger cannot see the PRIVATE draft -- for privacy reasons, not status ones'
);
-- The sharp one. A stranger seeing an unpublished party looks alarming and is
-- correct: `status` is not a visibility term, and `get_my_hosted_parties`
-- filters it explicitly BECAUSE the policy does not. Adding
-- `and status = 'published'` here would make that RPC's filter redundant and
-- silently change what every other status-aware caller sees.
select isnt_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-0000000000d2' $$,
  'a stranger DOES see a PUBLIC draft -- status plays no part in the policy, in either direction'
);

select tests.clear_authentication();
select is_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-0000000000d1' $$,
  'anon cannot see the private draft'
);
select isnt_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-0000000000d2' $$,
  'anon sees the public draft -- confirming status is not a visibility term anywhere'
);


-- ============================================================
-- 4. The write paths that read (section 5.4)
--
-- A SELECT policy reaches further than reads:
--   gotcha 3: on UPDATE, Postgres applies the SELECT policy to the NEW row
--             whenever the statement needs read access.
--   gotcha 6: `insert ... returning` goes through the SELECT policy.
-- Both are how a "reads-only" policy change breaks writes.
-- ============================================================

select tests.authenticate_as('11111111-1111-1111-1111-111111111111');

select lives_ok(
  $$ update public.parties set title = 'Syntagma Afterparty (moved)'
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'a host can still update their own PUBLIC party'
);
select lives_ok(
  $$ update public.parties set title = 'Rooftop Pregame (moved)'
     where id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'a host can still update their own PRIVATE party -- host_id short-circuits the new row'
);
select is(
  (select title from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000001'),
  'Rooftop Pregame (moved)',
  'and the private update actually landed rather than matching zero rows'
);

-- gotcha 6: the RETURNING read, and the ONE place this rewrite is not a pure
-- equivalence. Measured on the old policy, not predicted:
--
--   insert into public.parties (...) values (...);              -- succeeded
--   insert into public.parties (...) values (...) returning id; -- 42501
--
-- `can_user_access_party` is STABLE, so it runs against the calling
-- statement's snapshot -- which does not contain the row that statement is
-- inserting. Its `exists (select 1 from public.parties p where p.id = ...)`
-- therefore found nothing and the RETURNING read was refused. (Note this is
-- the opposite of gotcha 18: that is about a VOLATILE function seeing its own
-- statement's rows. STABLE is exactly the case that does not.)
--
-- The brief's section 4 argues the hoist "cannot change an answer" because in
-- policy context the row always exists. That is true of the row being
-- filtered and not true of the helper's snapshot of it, which is why this
-- case moves: after the hoist, `host_id = (select auth.uid())` reads the new
-- row's own column with no re-fetch at all.
--
-- The change is a strict improvement and widens nothing -- `host_id =
-- auth.uid()` is the INSERT policy's own WITH CHECK condition, so any row that
-- can be inserted is a row its inserter may now read back. Asserted for both
-- privacy flags because the private one has no other way through: a host holds
-- no invitation to their own party.
select lives_ok(
  $$ insert into public.parties (host_id, title, location, starts_at, is_private)
     values ('11111111-1111-1111-1111-111111111111', 'Returning Public',
             st_point(23.7350, 37.9757)::geography, now() + interval '21 days', false)
     returning id $$,
  'insert ... returning works for a host''s public party'
);
select lives_ok(
  $$ insert into public.parties (host_id, title, location, starts_at, is_private)
     values ('11111111-1111-1111-1111-111111111111', 'Returning Private',
             st_point(23.7350, 37.9757)::geography, now() + interval '22 days', true)
     returning id $$,
  'insert ... returning works for a host''s PRIVATE party -- the hoisted host_id term is what keeps this cheap'
);
select isnt_empty(
  $$ select 1 from public.parties where title = 'Returning Private' $$,
  'control: the private insert produced a row the host can actually read back'
);


-- ============================================================
-- 5. The recursion canary (section 3)
--
-- 20260812121153 exists because `parties` and `invitations` policies were
-- mutually recursive and Postgres raised 42P17 on ANY select against EITHER
-- table. The other half of that cycle is still live today: the `invitations`
-- SELECT policy contains a plain, RLS-applied `exists (select 1 from
-- public.parties ...)`. One inline `exists` on `invitations` in the `parties`
-- policy re-closes it.
--
-- The canary is cheap and blunt: if the cycle were back, both selects below
-- would raise "infinite recursion detected in policy for relation", so a
-- plain `lives_ok` on each is a genuine detector rather than a formality.
-- ============================================================

select tests.authenticate_as('22222222-2222-2222-2222-222222222222');

select lives_ok(
  $$ select count(*) from public.invitations $$,
  'selecting from invitations does not recurse (42P17 canary, invitations side)'
);
select lives_ok(
  $$ select count(*) from public.parties $$,
  'selecting from parties does not recurse (42P17 canary, parties side)'
);
select lives_ok(
  $$ select count(*) from public.parties p
     join public.invitations i on i.party_id = p.id $$,
  'joining the two tables that used to recurse does not recurse either'
);

-- And the structural half: the policy expression itself must not mention any
-- table other than the row it filters. This is the assertion that fails when
-- somebody "simplifies" the helper call away -- before it ever gets a chance
-- to raise 42P17 at runtime, and regardless of whether a fixture happens to
-- exercise the fall-through branch.
select is_empty(
  $$ select 1 where pg_get_expr(
       (select polqual from pg_policy
        where polrelid = 'public.parties'::regclass and polcmd = 'r'),
       'public.parties'::regclass) ~* '\minvitations\M' $$,
  'the parties SELECT policy does not mention `invitations` -- the rule that keeps 42P17 shut'
);
select is_empty(
  $$ select 1 where pg_get_expr(
       (select polqual from pg_policy
        where polrelid = 'public.parties'::regclass and polcmd = 'r'),
       'public.parties'::regclass) ~* '\mblocks\M' $$,
  'nor `blocks` -- is_blocked must stay a SECURITY DEFINER call, not an inlined NOT IN'
);
select isnt_empty(
  $$ select 1 where pg_get_expr(
       (select polqual from pg_policy
        where polrelid = 'public.parties'::regclass and polcmd = 'r'),
       'public.parties'::regclass) ~* '\mis_blocked\M' $$,
  'control: it does still call is_blocked, so the assertion above is not passing by absence'
);
select isnt_empty(
  $$ select 1 where pg_get_expr(
       (select polqual from pg_policy
        where polrelid = 'public.parties'::regclass and polcmd = 'r'),
       'public.parties'::regclass) ~* '\mcan_access_party\M' $$,
  'control: and it still calls can_access_party for the private fall-through'
);


-- ============================================================
-- 6. The helper is untouched (section 2, "what must NOT change")
--
-- Eight policies across five tables call `can_user_access_party`. This file is
-- allowed to let the POLICY drift from the helper only in the direction of
-- being a fast path; the helper itself is the canonical rule and this
-- migration must not have edited it.
-- ============================================================

select is(
  (select prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'can_user_access_party'),
  true,
  'can_user_access_party is still SECURITY DEFINER -- the thing that breaks the cycle'
);
select is(
  (select prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'is_blocked'),
  true,
  'is_blocked is still SECURITY DEFINER -- which is why calling it from a policy is safe'
);
select matches(
  (select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'can_user_access_party'),
  'invitations',
  'can_user_access_party still owns the invitations probe -- the rule did not move, it was copied'
);

-- The eight call sites, counted rather than named: if a future change removes
-- the helper from a policy, this drops and somebody has to look at why.
select is(
  (select count(*)::int from pg_policy
   where pg_get_expr(polqual, polrelid) ~* '\mcan_access_party\M|\mcan_user_access_party\M'
      or pg_get_expr(polwithcheck, polrelid) ~* '\mcan_access_party\M|\mcan_user_access_party\M'),
  8,
  'the party-visibility helper is still reached from exactly 8 policies'
);


-- ============================================================
-- 7. Cross-table: the seven policies that were NOT rewritten
--
-- Section 6 of the brief says they are unaffected "by construction" because
-- the helper is untouched. Construction arguments are exactly the ones worth
-- one cheap assertion, since all seven read `public.parties` underneath.
-- ============================================================

select tests.authenticate_as('22222222-2222-2222-2222-222222222222');

select lives_ok(
  $$ select count(*) from public.rsvps $$,
  'rsvps still selectable (two policies call the helper)'
);
select lives_ok(
  $$ select count(*) from public.party_posts $$,
  'party_posts still selectable'
);
select lives_ok(
  $$ select count(*) from public.stories $$,
  'stories still selectable'
);
select isnt_empty(
  $$ select 1 from public.parties where id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  'and the invitee still sees the private party the other seven policies gate on'
);

select * from finish();
rollback;
