# Phase 12 brief — rewriting the `parties` SELECT policy

**Status: EXECUTED, with its central premise disproved.** The rewrite shipped as
`20260821185216` and is a real 5× (5km p50 995 ms → 199 ms). It did **not**
reach `parties_location`, and no policy rewrite ever could. Results, plans and
the routes that do work:
[`phase-12-policy-rewrite-result.md`](phase-12-policy-rewrite-result.md).

> ### Read this before you act on anything below
>
> **The goal stated in this brief was unachievable, and the reasoning that
> produced it was wrong in a specific, reusable way. Do not repeat it.**
>
> The brief's premise — restated from §5 of
> [`phase-10-hardening-audit.md`](phase-10-hardening-audit.md) — was that the
> policy is expensive, that its expense is what defeats the GiST index, and
> that therefore making it cheap would restore the index. The first clause is
> true. The second does not follow from it, and the third is false.
>
> **Cost and index-reachability are two separate consequences of the same
> barrier, and only the first is fixable by a rewrite.** Whether a user qual
> may be evaluated *ahead* of an RLS qual — which is what becoming an
> `Index Cond` requires — depends on the leakproofness of **the user qual**,
> never on the policy's cost and never on the policy's own leakproofness. The
> spatial predicate is built entirely from operators that are not leakproof:
>
> | function | `proleakproof` |
> |---|---|
> | `st_dwithin(geography, geography, float8, bool)` | **f** |
> | `_st_expand(geography, float8)` | **f** |
> | `geography_overlaps(geography, geography)` — the `&&` operator | **f** |
>
> So `st_dwithin` can never sort ahead of *any* RLS qual on `parties`.
> Measured four ways by `scripts/explain_policy_pushdown.sh`: the shipped hoist
> seq-scans (203 ms); `using (not is_private)` — one leakproof column
> reference, the cheapest policy that still filters anything — **also** leaves
> `st_dwithin` as a Filter (10.9 ms); only `using (true)`, which the planner
> folds away so that no barrier remains, and RLS-off reach the index (3.3 ms /
> 2 ms). If policy cost were the obstacle, variant B would have reached it.
>
> **What this brief still gets right,** and what makes it worth keeping rather
> than deleting: §3 (the 42P17 recursion and the rule that keeps it shut), §4
> (the term-by-term equivalence), §5 (the pgTAP matrix), and §6 (blast radius).
> Those are about correctness and they held up — §5.1's equivalence assertion
> caught a real defect on its first run. Only the *performance justification* in
> §1 and §2 is wrong.

**Goal, as originally stated (and unachievable — see above):** make the
`parties` SELECT policy cheap enough on public rows that the planner can reach
`parties_location`, without changing who can see which party.

**Goal, as it should have been stated:** make the `parties` SELECT policy cheap
enough that a 10k-party map query is not dominated by it, without changing who
can see which party. That is achievable and was achieved.

This continues §5 of [`phase-10-hardening-audit.md`](phase-10-hardening-audit.md),
which measured the problem and proposed the fix but deliberately did not apply
it. Read that section first — **and read the correction at the top of it**;
this brief inherited its error.

---

## 1. Why it is now blocking, and not just slow

> **Corrected after execution.** The numbers in this section are right and the
> conclusion drawn from them is not. The policy dominating the cost does not
> imply that cheapening the policy restores the index — see the banner at the
> top. The rewrite took 5km p50 to **199 ms** and the plan is still
> `Seq Scan on parties`.

Measured at 10k parties / 50k rsvps by `scripts/loadtest_map_query.sh`:

| zoom | as shipped | after the rewrite | RLS-bypassed control |
|---|---|---|---|
| 5km | **995 ms p50** | **199 ms p50** | 2 ms |
| 50km | 230 ms p50 | 63 ms p50 | 9.8 ms |
| 500km | 208 ms p50 | 57 ms p50 | 8.4 ms |

RLS is still 98.9% of 5km p95 after the rewrite, and the 5km tier is still the
slowest — §7.1's stated target was not hit, because the remaining cost is
`is_blocked` running once per row and no hoist can remove it: `blocks` is not a
column of `parties`.

~99% of p95 is the row policy, and it gets **worse as you zoom in**, which is
where the users are. The 500km tier has a cheap *leakproof* pre-filter
(`party_tier = 'mega' or is_sponsored`) that therefore runs first; the 5km
branch of the `case` is a literal `true`, so all 10k rows go through
`can_access_party`.

What makes it blocking rather than merely slow is what comes next. From gotcha
22 — and **measured** by `scripts/explain_qual_pushdown.sh`, not inferred from
`pg_proc`, which says only what the planner is permitted to do:

| predicate | leakproof | exec | buffers | printed `Filter:` order |
|---|---|---|---|---|
| *(policy only, baseline)* | — | 954ms | 62018 | policy |
| `starts_at > <const>` | **yes** | **4.1ms** | **433** | **time, then policy** |
| `title like '%zzzzzz%'` | no | 890ms | 61799 | policy, then like |
| `st_dwithin(…, 1)` | no | 947ms | 61872 | policy, then dwithin |

The `like` matches *fewer* rows than the time predicate and costs 216× more.
`shared hit` is the honest metric here: `can_access_party` is `SECURITY
DEFINER` and issues its own queries, ~6 buffers a call, so 62018 ≈ one call per
row and 433 ≈ 31 calls. End to end on the map query body, adding a 6-hour
window took **1483ms → 42ms**.

**Two findings from that run that change how you read §5 of the audit.**

- `enum_eq` is **not** leakproof; `texteq` is. `party_tier` is `text` and
  `status` is an enum, which is the mechanical reason the wide-zoom tiers are
  fast and the 5km tier is not — the tier filter sorts ahead of the policy and
  `status = 'published'` sorts behind it. The audit inferred that asymmetry
  from timings; this names the cause. Do not assume a cheap-looking equality
  pre-filters — check the type.
- The selective time predicate did **not** use the `parties (starts_at)` index
  from `20260817073509`; it is still a seq scan, just with the cheap term
  first. The 216× is qual ordering alone. Do not treat "it will use the index"
  as part of the argument for the chips — it does not need to.

So the **time filter chips can ship today** — they push a leakproof predicate
that shrinks the input to the policy, exactly like the 500km tier filter does.
**Search cannot.** An `ilike` on `title`/`area` has `st_dwithin`'s failure mode
precisely: it lands behind the barrier, seq-scans, and cannot reach an index.
Adding `pg_trgm` or a `tsvector` column before this rewrite would buy nothing
measurable, and worse, would be measured against a 995ms floor — which teaches
the wrong lesson about the index.

> **Corrected.** This paragraph is the one part of §1 that survives intact, and
> it is worth more than the rest: the leakproof-predicate-first mechanism it
> describes is real, and it turned out to be the *whole* answer rather than a
> side note. Applied spatially — a `float8` bounding box on generated `lat`/
> `lon` columns, since `float8ge`/`float8le` are leakproof where
> `geography_overlaps` is not — it takes the same query from **228 ms to
> 8.8 ms** under the shipped policy, cutting 10k rows to 408 *before*
> `is_blocked` is called even once (29088 → 1416 buffers). That is the route
> §7 should have pointed at.
>
> The claim about search is unchanged and still correct, with one amendment:
> the floor it would be measured against is now 199 ms rather than 995 ms, and
> the rewrite did not remove it. Search is still blocked.

---

## 2. What changes

One migration. One policy. Nothing else.

```sql
-- today
create policy "Parties are viewable based on privacy and invitations"
on public.parties for select
using ( public.can_access_party(id) );

-- proposed
create policy "Parties are viewable based on privacy and invitations"
on public.parties for select
using (
  not public.is_blocked((select auth.uid()), host_id)
  and (
    not is_private
    or host_id = (select auth.uid())
    or public.can_access_party(id)
  )
);
```

`is_blocked`, `is_private` and `host_id` are hoisted out of the helper into the
policy because **the policy already has that row in hand**. `can_user_access_party`
re-fetches the `parties` row it was handed the id of, purely to read two columns
the caller is already looking at. Hoisting them:

- removes a nested query per row,
- short-circuits every **public** party — most of them — with no function call
  at all,
- and leaves a cheap, row-local `boolean` chain where a `SECURITY DEFINER`
  function scan used to be.

> **Corrected: what this buys, and what it does not.**
>
> It buys **5×** — 995 ms → 199 ms p50 at 5km — and that is all it buys. It
> does **not** buy the index, and the framing above ("so the planner can reach
> `parties_location`") is the error this whole document exists to warn about.
> A cheaper barrier is still a barrier; `st_dwithin` is non-leakproof and stays
> behind it regardless.
>
> Note also where the remaining 199 ms lives, because it bounds any further
> hoisting: `is_blocked` is the **first** term and runs on every row, so the
> hoist traded two definer calls per row for one. It cannot be hoisted further
> — `blocks` is not a column of `parties`, which is exactly why it has to be a
> definer function (§3). The floor for this shape of policy is one definer call
> per row scanned, so the only way down is to **scan fewer rows**, not to make
> the policy cheaper. That is what the leakproof pre-filter in §1 does.

Note this brief hoists `host_id = auth.uid()` as well, which the audit's
sketch did not. It costs nothing and short-circuits a host's own private
parties too.

### What must NOT change

- **`can_user_access_party`'s body.** Eight policies across five tables call it
  (see §6). Editing the helper to "match" the new policy changes party
  visibility everywhere at once. The helper stays the canonical rule; the
  policy becomes a fast path *equivalent* to it.
- **The `invitations` SELECT policy.** See §3 — it is the other half of a
  recursion.
- **`parties_location`.** It reads as an unused index in the advisor and is
  not. The entire point of this work is to make the query able to reach it.

### The debt this creates, and how it is paid

After the hoist, party visibility is written in **two** places — a deliberate,
measured exception to CLAUDE.md rule #4, and the one thing about this change
that will look wrong to a future reader. The exception is only acceptable
because §5's pgTAP matrix makes drift a red test rather than a silent
divergence: the matrix asserts the policy and the helper agree on every
combination, so adding a term to `can_user_access_party` without adding it to
the policy fails CI. **Write the policy comment to say this, and point it at
the test file by name.** Without that test, do not ship the hoist.

---

## 3. The recursion — what it was, and exactly how to bring it back

This is the part to read twice. [`20260812121153`](../supabase/migrations/20260812121153_fix_party_visibility_rls_recursion.sql)
exists because the original policies were mutually recursive:

```
-- 20260709120643, parties SELECT
using ( not is_private
        or auth.uid() = host_id
        or exists (select 1 from public.invitations
                   where invitations.party_id = public.parties.id
                     and invitations.guest_id = auth.uid()) )

-- 20260709120643, invitations SELECT
using ( exists (select 1 from public.parties
                where parties.id = invitations.party_id
                  and parties.host_id = auth.uid())
        or guest_id = auth.uid() )
```

Selecting from `parties` evaluates the `parties` policy, whose subquery on
`invitations` evaluates the `invitations` policy, whose subquery on `parties`
evaluates the `parties` policy… Postgres detects the cycle and raises **42P17,
"infinite recursion detected in policy for relation"** — on *any* select
against either table.

`can_access_party` broke the cycle by being **`SECURITY DEFINER`**: it runs as
the tables' owner, so RLS does not apply to the queries inside it and there is
no re-entry. That, and not tidiness, is why the rule lives in a function.

**The trap this rewrite walks straight into.** After hoisting `is_private` and
`host_id` out, the only thing left inside the helper call is the invitations
probe — so the tempting next "simplification" is to inline it and delete the
function call entirely:

```sql
-- DO NOT. This is 42P17 again.
or exists (select 1 from public.invitations i
           where i.party_id = parties.id and i.guest_id = (select auth.uid()))
```

And it is not a historical risk. The other half of the cycle is still in place
today — the live `invitations` SELECT policy still reads:

```
EXISTS (SELECT 1 FROM parties
        WHERE parties.id = invitations.party_id
          AND parties.host_id = (SELECT auth.uid()))
```

as a plain, RLS-applied subquery. One inline `exists` on `invitations` in the
`parties` policy re-closes the loop.

**The rule to hold:** the `parties` SELECT policy may reference **its own row's
columns** and **`SECURITY DEFINER` helpers**, and nothing else. No subquery on
another table, ever. Both hoisted terms satisfy this — `is_private` and
`host_id` are columns of the row being filtered, and `is_blocked` is
`SECURITY DEFINER` (it reads `blocks`, which has policies of its own; calling
it from a policy is only safe *because* it is definer).

Add a `throws_ok`-style guard to the test file if you can construct one
cheaply; a plain `lives_ok` on `select count(*) from public.invitations` as an
authenticated user is a serviceable canary, since the recursion makes *both*
tables unselectable.

---

## 4. Equivalence, term by term

Current helper, as it actually stands in the database today:

```sql
can_user_access_party(p_user_id, p_party_id) =
  exists (
    select 1 from public.parties p
    where p.id = p_party_id
      and not public.is_blocked(p_user_id, p.host_id)
      and ( not p.is_private
            or p.host_id = p_user_id
            or exists (select 1 from public.invitations i
                       where i.party_id = p.id and i.guest_id = p_user_id) )
  );
```

and `can_access_party(id) = can_user_access_party(auth.uid(), id)`.

The proposed policy is the same conjunction in the same order, with the first
three terms evaluated against the row in hand instead of a re-fetched copy:

| case | today | proposed |
|---|---|---|
| blocked pair | helper: `not is_blocked` fails → false | policy: first term fails → false |
| public, not blocked | helper: `not is_private` → true | policy: `not is_private` → true, **no function call** |
| own private party | helper: `host_id = uid` → true | policy: `host_id = uid` → true, no function call |
| private, invited | helper: invitations probe → true | policy falls through to `can_access_party(id)`, which re-checks `not is_blocked` (true) then probes → true |
| private, uninvited | false | false |

The only behavioural difference is *how many times* `is_blocked` is evaluated
on the fall-through path (twice instead of once), on the rarest branch. It is
`STABLE`, so the planner may fold it anyway.

**The row-existence subtlety:** the helper's `exists (… where p.id = …)`
returns false for a party that does not exist. In policy context the row always
exists — it is the row being filtered — so the hoist cannot change an answer.
This matters if anyone later reuses the hoisted expression somewhere a row id
might be dangling; it is not a policy-context concern.

---

## 5. What the pgTAP matrix has to cover

New file, `17_parties_policy.test.sql`. Four groups.

### 5.1 The equivalence assertion (the one that makes the hoist safe)

For every party in the fixture set and every viewer persona, assert that **what
the policy admits equals what `can_user_access_party` says**. This is what
stops the two copies drifting, and it is worth more than any number of spot
checks.

```sql
-- as each viewer, after tests.authenticate_as(...)
select is_empty(
  $$ select p.id from public.parties p
     where public.can_user_access_party((select auth.uid()), p.id) is not true $$,
  'every row the policy admits, the helper also admits'
);
```

The converse — every row the helper admits, the policy admits — needs the full
party set captured **outside** the policy, which brings in:

> **gotcha 17.** A control query in an RLS test is filtered by the RLS it is
> controlling for. Capture the expected set into a temp table *before*
> `tests.authenticate_as`, or as a definer call, then compare. A control
> evaluated after authenticating shrinks in lockstep with the thing under test
> and would pass against a broken policy.

### 5.2 The visibility matrix

Viewers × parties, both directions asserted separately. Do not collapse these —
gotcha 14's lesson is that a symmetric-looking pair can be wrong in one
direction and pass in the other.

| viewer \ party | public | private, invited | private, uninvited | private, own | public, host blocked me | public, I blocked host |
|---|---|---|---|---|---|---|
| host | ✓ | ✓ | ✓ | ✓ | — | — |
| invitee | ✓ | ✓ | ✗ | — | ✗ | ✗ |
| stranger | ✓ | — | ✗ | — | ✗ | ✗ |
| **anon** (`auth.uid()` null) | ✓ | — | ✗ | — | ✓ | ✓ |

Two rows carry most of the risk:

- **`anon`.** `is_blocked` guards its nulls and returns false, so
  `not is_blocked(null, host_id)` is true and an anonymous caller keeps seeing
  public parties — which is current behaviour and must not change (see
  [`20260821175831`](../supabase/migrations/20260821175831_revoke_anon_execute_on_map_rpc.sql)
  for why anon reads `parties` at all). The failure mode to test for is a
  hoist written as `host_id not in (select blocked_id from public.blocks
  where blocker_id = (select auth.uid()))` — a NULL-in-list, which evaluates to
  NULL and drops **every** row for anonymous callers. Keep using the helper.
- **The blocked pair, both directions.** `is_blocked` is symmetric; assert
  blocker→blocked and blocked→blocker separately.

### 5.3 Statuses the policy does not filter

The policy says nothing about `status`, and must continue not to: a host can
see their own `draft` and `cancelled` parties through it, which
`get_my_hosted_parties` relies on being true (it filters `status` explicitly
*because* the policy does not — see `15_profile_party_list.test.sql`). Assert a
draft is visible to its host and to nobody else.

### 5.4 The write paths that read

Two gotchas make a SELECT policy change reach further than reads:

- **gotcha 3.** On UPDATE, Postgres applies the SELECT policy to the *new* row
  whenever the statement needs read access. `parties` carries an UPDATE grant
  with `using (auth.uid() = host_id)`; assert a host can still update their own
  party, public and private.
- **gotcha 6.** `insert … returning` is a read. `create_party_with_invites`
  dodges this by generating the id locally, but assert a plain host insert with
  `.select()` still returns its row — the hoisted `host_id = auth.uid()` term
  is what keeps that cheap.

---

## 6. Blast radius

`can_user_access_party` is reached from eight policies across five tables, plus
the RPCs:

```
invitations   :: Hosts can view guest lists for their parties
parties       :: Parties are viewable based on privacy and invitations   <- the only one changing
party_posts   :: Posts are viewable by anyone who can access the party
party_posts   :: Users can post to parties they can access
rsvps         :: Users can rsvp to parties they can access
rsvps         :: Users can update their own rsvp
stories       :: Party members can post stories
stories       :: Stories are viewable by anyone who can see the party
```

Only the `parties` policy is being rewritten, and the helper is untouched, so
the other seven are unaffected *by construction* — but they all read
`public.parties` somewhere underneath, so re-run the **full** suite (491 tests
at time of writing), not just the new file. The proximity notification engine
calls `can_user_access_party` directly and is likewise untouched.

---

## 7. Re-measurement — what "done" looks like

1. `bash scripts/loadtest_map_query.sh` — the same 10k/50k fixture as the
   audit, so the numbers are comparable. **Target: the 5km tier stops being
   the slowest.** The audit's control (policies off) is 2ms; anything in the
   low tens of ms is a win, and the shape matters more than the number.
2. `bash scripts/explain_qual_pushdown.sh` — re-run it after the rewrite. The
   baseline row (policy only, 954ms / 62018 buffers) is the number the hoist
   is aimed at, and the `like` row is the one that has to move before search
   is worth building: today it costs the same as the baseline because it runs
   behind the policy on every row.
3. ~~`bash scripts/explain_proximity.sh`~~ — **the acceptance criterion was
   structural, and it was pointed at a script that cannot fail it.** Corrected
   below; the criterion itself is unachievable and is retired.

   > **`explain_proximity.sh` IS NOT AN ACCEPTANCE CHECK FOR ANY RLS CHANGE.**
   >
   > It EXPLAINs as `postgres`, which bypasses row security entirely — and
   > correctly so, because the thing it measures, the proximity notification
   > engine, is `SECURITY DEFINER` and genuinely runs with no policy in its
   > path (`enqueue_nearby_party_notifications`, `prosecdef = t`). Making it
   > run as `authenticated` would be the same error in reverse: it would
   > measure a query the engine never issues.
   >
   > The consequence is that its Query 2 printed
   >
   > ```
   > Index Scan using parties_location on parties p
   >   Index Cond: ((location && _st_expand(<point>, 5000)) AND (... 500))
   > ```
   >
   > — the exact line this step demanded — **before the migration as well as
   > after**. Following step 3 as written would have certified a no-op as a
   > success. A warning to that effect is now at the top of the script itself.
   >
   > **The rule:** anything claiming to measure an RLS effect must run through
   > `tests.authenticate_as`. If a plan is EXPLAINed as `postgres`, the row
   > policies are not in it and the measurement is about a different query.
   > `loadtest_map_query.sh` and `explain_policy_pushdown.sh` both authenticate;
   > `explain_proximity.sh` deliberately does not.

   The structural criterion this step asked for — `Index Cond: (location &&
   _st_expand(<point>, 5000))` on `parties_location`, under RLS — **is not
   reachable by any policy** (see the banner at the top). `bash
   scripts/explain_policy_pushdown.sh` is the replacement: it EXPLAINs the 5km
   map body as an authenticated viewer under four policy shapes and counts
   `parties_location` scans with `pg_stat_get_xact_numscans`, independently of
   the plan text. Read its output as evidence for *why* the criterion is
   retired, not as a check that can pass.
4. **Re-price gotcha 20.** All eight read RPCs are VOLATILE and therefore have
   never been inlined; `20260819095452` pinned `search_path` on them for free
   because there was no inlining to lose. That calculation was made *while the
   policy dominated the cost*. Once it does not, `STABLE` + inlining is worth
   measuring again — the audit priced the STABLE variant at 983ms vs 995ms,
   which is noise today and might not be after.
5. Only then: `pg_trgm`, an index on `title`/`area`, and the search RPC. That
   is Phase 13, and it is now unblocked rather than sandbagged.

   > **Corrected: step 5 did not become available.** Search is blocked for the
   > unchanged reason — `ilike` is non-leakproof, lands behind the barrier, and
   > cannot reach a `pg_trgm` index no matter how cheap the policy is. The
   > rewrite lowered the floor it would be measured against from 995 ms to
   > 199 ms and removed nothing structural. What unblocks Phase 13 is getting
   > the scan out from behind the barrier: a leakproof indexable pre-filter
   > (§1's correction, measured at 228 ms → 8.8 ms) or a `SECURITY DEFINER`
   > read RPC. See §5 of
   > [`phase-12-policy-rewrite-result.md`](phase-12-policy-rewrite-result.md).

---

## 8. Out of scope

- **`can_user_access_party`'s body.** §2.
- **The `ends_at` map lifecycle question** (gotcha 21). Still a product
  decision; do not fold a `starts_at` guess into this migration.
- **Anything about `anon`'s table grants.** The unauthenticated map is a
  separate question with a separate answer; `20260821175831` documents it.
- **Search itself.** This brief exists to unblock it, not to contain it.
