# Phase 12 brief — rewriting the `parties` SELECT policy

**Status:** scoped, not started. Sequenced **before** map search, on the
leakproofness finding recorded as CLAUDE.md gotcha 22.

**Goal, in one sentence:** make the `parties` SELECT policy cheap enough on
public rows that the planner can reach `parties_location`, without changing who
can see which party.

This continues §5 of [`phase-10-hardening-audit.md`](phase-10-hardening-audit.md),
which measured the problem and proposed the fix but deliberately did not apply
it. Read that section first; this brief assumes it.

---

## 1. Why it is now blocking, and not just slow

Measured at 10k parties / 50k rsvps by `scripts/loadtest_map_query.sh`:

| zoom | as shipped | RLS-bypassed control |
|---|---|---|
| 5km | **995 ms p50** | 2 ms |
| 50km | 230 ms p50 | — |
| 500km | 208 ms p50 | — |

~99% of p95 is the row policy, and it gets **worse as you zoom in**, which is
where the users are. The 500km tier has a cheap non-leakproof-free pre-filter
(`party_tier = 'mega' or is_sponsored`) that runs first; the 5km branch of the
`case` is a literal `true`, so all 10k rows go through `can_access_party`.

What makes it blocking rather than merely slow is what comes next. From gotcha
22, read off `pg_proc` on this database:

| predicate | `proleakproof` | runs |
|---|---|---|
| `timestamptz_gt` / `_lt` / `_ge` | **true** | before the policy |
| `st_dwithin` | false | after |
| `textlike` / `texticlike` (`like`/`ilike`) | false | after |

So the **time filter chips can ship today** — they push a leakproof predicate
that shrinks the input to the policy, exactly like the 500km tier filter does.
**Search cannot.** An `ilike` on `title`/`area` has `st_dwithin`'s failure mode
precisely: it lands behind the barrier, seq-scans, and cannot reach an index.
Adding `pg_trgm` or a `tsvector` column before this rewrite would buy nothing
measurable, and worse, would be measured against a 995ms floor — which teaches
the wrong lesson about the index.

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
2. `bash scripts/explain_proximity.sh` — the acceptance criterion is
   structural, not a timing: the 5km plan must show

   ```
   ->  Bitmap Index Scan on parties_location
         Index Cond: (location && _st_expand(<point>, 5000))
   ```

   If the plan still says `Seq Scan on parties` with `can_access_party(id)` in
   the filter, the hoist did not achieve its purpose however much the wall
   clock improved.
3. **Re-price gotcha 20.** All eight read RPCs are VOLATILE and therefore have
   never been inlined; `20260819095452` pinned `search_path` on them for free
   because there was no inlining to lose. That calculation was made *while the
   policy dominated the cost*. Once it does not, `STABLE` + inlining is worth
   measuring again — the audit priced the STABLE variant at 983ms vs 995ms,
   which is noise today and might not be after.
4. Only then: `pg_trgm`, an index on `title`/`area`, and the search RPC. That
   is Phase 13, and it is now unblocked rather than sandbagged.

---

## 8. Out of scope

- **`can_user_access_party`'s body.** §2.
- **The `ends_at` map lifecycle question** (gotcha 21). Still a product
  decision; do not fold a `starts_at` guess into this migration.
- **Anything about `anon`'s table grants.** The unauthenticated map is a
  separate question with a separate answer; `20260821175831` documents it.
- **Search itself.** This brief exists to unblock it, not to contain it.
