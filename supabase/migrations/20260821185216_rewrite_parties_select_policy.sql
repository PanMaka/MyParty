-- Phase 12: make the `parties` SELECT policy cheap on public rows, so the
-- planner can reach `parties_location`.
--
-- Full reasoning: docs/phase-12-parties-policy-rewrite.md, continuing §5 of
-- docs/phase-10-hardening-audit.md. The short version:
--
-- An RLS policy is a security barrier, and a non-leakproof predicate may not
-- be evaluated ahead of it. `st_dwithin` is not leakproof, so under the old
-- policy `get_parties_near_user` seq-scanned all 10k parties calling
-- `can_access_party` on every one, and the GiST index on `parties.location`
-- never got an index condition to work with -- 995ms p50 at 5km zoom against
-- a 2ms RLS-bypassed control, ~99% of p95. It got WORSE zoomed in, because
-- the wide-zoom tiers have a cheap leakproof `party_tier` text filter that
-- sorts ahead of the policy and the 5km branch has none.
--
-- The fix is not to make the policy faster; it is to make most rows never
-- reach the function at all. `can_user_access_party` re-fetches the `parties`
-- row it was handed the id of, purely to read two columns the policy is
-- already looking at. Hoisting them leaves a row-local boolean chain where a
-- SECURITY DEFINER function scan used to be, and short-circuits every public
-- party -- most of them -- with no function call whatsoever.
--
-- What is deliberately NOT changed here:
--
--   * `can_user_access_party`'s body. Eight policies across five tables call
--     it. Editing the helper to "match" this policy would change party
--     visibility everywhere at once. The helper stays the canonical rule and
--     this policy becomes a fast path *equivalent* to it.
--   * The `invitations` SELECT policy -- see the recursion note below.
--   * `parties_location`. It reads as an unused index in the advisor and is
--     not; the entire point of this migration is to make the query able to
--     reach it.

alter policy "Parties are viewable based on privacy and invitations"
on public.parties
using (
  -- Hoisted term 1. `is_blocked` is symmetric and guards its nulls, so an
  -- anonymous caller (auth.uid() is null) gets false here and keeps seeing
  -- public parties -- which is current behaviour and must not change.
  --
  -- This MUST stay a call to the helper. Written inline as
  -- `host_id not in (select blocked_id from public.blocks where blocker_id =
  -- (select auth.uid()))` it becomes a NULL-in-list for anonymous callers,
  -- evaluates to NULL rather than true, and silently drops EVERY row from the
  -- unauthenticated map. Asserted in 17_parties_policy.test.sql.
  not public.is_blocked((select auth.uid()), host_id)
  and (
    -- Hoisted terms 2 and 3: columns of the row being filtered, so they cost
    -- nothing and short-circuit the common cases before any function call.
    -- `host_id = uid` covers a host's own private parties, invitation row or
    -- not, which is why a host never needs the fall-through.
    not is_private
    or host_id = (select auth.uid())
    -- The only branch that still pays for a function call: a private party
    -- the viewer neither hosts nor is short-circuited by. The helper re-checks
    -- `not is_blocked` (already known true here) and then probes invitations.
    --
    -- This MUST stay a function call. Inlining the probe as
    -- `exists (select 1 from public.invitations i where i.party_id = id ...)`
    -- re-closes the 42P17 recursion that 20260812121153 exists to break: the
    -- `invitations` SELECT policy still contains a plain, RLS-applied
    -- subquery on `public.parties`, so a subquery on `invitations` here makes
    -- both tables unselectable. `can_access_party` is SECURITY DEFINER, which
    -- is what breaks the cycle -- that, and not tidiness, is why the rule
    -- lives in a function.
    --
    -- The rule to hold: this policy may reference its own row's columns and
    -- SECURITY DEFINER helpers, and NOTHING else. No subquery on another
    -- table, ever.
    or public.can_access_party(id)
  )
);

comment on policy "Parties are viewable based on privacy and invitations" on public.parties is
  'Party visibility is now written in TWO places: here, and in '
  'public.can_user_access_party() which eight policies across five tables '
  'still call. That is a deliberate, measured exception to the '
  '"no duplicated visibility logic" rule -- the hoist exists so that a public '
  'party short-circuits without a SECURITY DEFINER call, which is what lets '
  'the planner reach parties_location (see '
  'docs/phase-12-parties-policy-rewrite.md). '
  'The exception is only acceptable because '
  'supabase/tests/database/17_parties_policy.test.sql asserts, for every '
  'persona and every fixture party, that this policy and the helper admit '
  'exactly the same set of rows -- in BOTH directions. Adding a term to '
  'can_user_access_party without adding it here fails CI rather than '
  'silently diverging. Do not edit one copy without the other, and do not '
  'delete that test file.';
