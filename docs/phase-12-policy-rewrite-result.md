# Phase 12 result — the hoist shipped, the acceptance criterion did not

**Status:** migration applied, 495 pgTAP assertions green. The §7.3 structural
acceptance criterion is **not met, and is not reachable by any policy
rewrite.** That is the headline; the 5× speedup is the footnote.

Companion to [`phase-12-parties-policy-rewrite.md`](phase-12-parties-policy-rewrite.md),
which scoped the work. Read that first. This file records what happened when it
was executed, including the two places the brief was wrong.

> **Branch base.** This phase was cut from `main`, but the brief it executes
> was written on the unmerged `phase/11-map-rework` branch and assumes it. Three
> things it names live only there: the brief file itself, CLAUDE.md gotchas 21
> and 22, and `scripts/explain_qual_pushdown.sh` (whose re-run is §7 step 2, and
> which therefore could not be done here). The migration and the test file have
> no dependency on any of it — `17` is the number the brief asks for and leaves
> room for phase 11's `14`–`16` — but **merge `phase/11-map-rework` first**, or
> the test-file numbering gaps and these cross-references stay dangling.

---

## 1. What shipped

`20260821185216_rewrite_parties_select_policy.sql`, exactly the policy §2
proposed:

```sql
using (
  not public.is_blocked((select auth.uid()), host_id)
  and (
    not is_private
    or host_id = (select auth.uid())
    or public.can_access_party(id)
  )
)
```

`can_user_access_party` is untouched. `17_parties_policy.test.sql` (65
assertions) holds the two copies together, per §2's condition for shipping the
hoist at all.

**Measured**, `scripts/loadtest_map_query.sh`, 10k parties / 50k rsvps — the
same fixture as the Phase 10 audit, so these are comparable to it:

| zoom | before (audit) | after | RLS-bypassed control |
|---|---|---|---|
| 5km | 995 ms p50 | **199 ms p50** (218 p95) | 2.0 ms |
| 50km | 230 ms p50 | 63 ms p50 | 9.8 ms |
| 500km | 208 ms p50 | 57 ms p50 | 8.4 ms |

A real 5× at the tier where the users are. But RLS is still **98.9%** of 5km
p95, and **the 5km tier is still the slowest** — which was §7.1's stated
target, and it was not hit.

---

## 2. The acceptance criterion, and why it cannot be met this way

§7.3 requires the 5km plan to show:

```
->  Bitmap Index Scan on parties_location
      Index Cond: (location && _st_expand(<point>, 5000))
```

It does not. After the hoist the plan is still:

```
->  Seq Scan on parties p
      Filter: ((NOT is_blocked(...)) AND ((NOT is_private) OR (host_id = ...)
               OR can_access_party(id)) AND ... st_dwithin(location, ..., 5000))
      Rows Removed by Filter: 9750
```

A faster seq scan, which is exactly what the criterion exists to reject.

### The measurement that settles it

`scripts/explain_policy_pushdown.sh` runs the identical 5km query at 10k
parties under four policy shapes in one rolled-back transaction:

| variant | policy | scan on `parties` | `st_dwithin` lands as | exec |
|---|---|---|---|---|
| **A** | the hoist, as shipped | Seq Scan | Filter | 202.9 ms |
| **B** | `using (not is_private)` — one leakproof column ref | Index Scan on `parties_upcoming_public_idx` | **Filter** | 10.9 ms |
| **C** | `using (true)` | **Bitmap Index Scan on `parties_location`** | **Index Cond** | 3.3 ms |
| **D** | RLS off (control) | **Bitmap Index Scan on `parties_location`** | **Index Cond** | ~2 ms |

Counted independently of the plan text: `pg_stat_get_xact_numscans` reports
`parties_location` scanned **exactly 2 times** across all four EXPLAINs — C and
D. A and B never touch it.

**Variant B is the whole argument.** It is the cheapest policy that still
filters anything, and every operator in it is leakproof. If policy *cost* were
the obstacle, the index would appear there. It does not. It only appears in C,
where the qual is the constant `true` and the planner folds it away entirely —
i.e. where there is effectively no security barrier left.

### Why

Promotion depends on the leakproofness of the **user qual**, not the policy's.
An RLS qual is a security barrier; a user qual may be evaluated ahead of it —
which is what becoming an `Index Cond` requires — only if that user qual is
leakproof. Every operator the spatial predicate is built from is not:

| function | `proleakproof` |
|---|---|
| `st_dwithin(geography, geography, float8, bool)` | **f** |
| `_st_expand(geography, float8)` | **f** |
| `geography_overlaps(geography, geography)` — the `&&` operator | **f** |

So `st_dwithin` can never sort ahead of an RLS qual on `parties`, and an index
condition is by definition evaluated first. **No rewrite of the policy can
change this**, because the policy is not the thing being tested for
leakproofness.

This corrects CLAUDE.md gotcha 19 and §5 of the Phase 10 audit. Both diagnosed
the problem as "the policy is expensive and therefore defeats the index". The
expense and the index are two separate consequences of the same barrier: the
hoist fixes the expense (5×) and cannot fix the index. `parties_location` is
still not an unused index — but the reason to keep it is now the notification
engine (§4), not a map query that might one day reach it.

---

## 3. §7.3 pointed at a script that cannot fail

The brief names `scripts/explain_proximity.sh` as where to check the criterion.
That script's Query 2 does print exactly the required line:

```
Index Scan using parties_location on parties p
  Index Cond: ((location && _st_expand(<point>, 5000)) AND (... 500))
```

…and printed it **before this change too**. It runs its EXPLAINs as `postgres`,
which bypasses row security entirely, so its plan is independent of the
`parties` policy by construction. Checking the acceptance criterion there would
have reported success for a migration that did nothing.

The criterion has to be measured **as an authenticated viewer, through RLS**,
which is what `loadtest_map_query.sh` and the new `explain_policy_pushdown.sh`
both do.

---

## 4. Blast radius: nothing else moved

- Full pgTAP suite: **495 assertions, all green** (430 pre-existing + 65 new).
- The seven other policies that call `can_user_access_party` are unaffected —
  the helper was not edited. Asserted directly in §7 of the new test file
  rather than left as a construction argument.
- `explain_proximity.sh`: both notification-engine plans unchanged, still
  reaching `user_devices_last_location_gist` and `parties_location`, and the
  seq-scanning control still seq-scans. The engine runs SECURITY DEFINER, so
  the policy was never in its path.

---

## 5. What would actually reach the index

Not proposals — the measured options, in rough order of blast radius.

1. **Take the spatial scan out of RLS.** Make `get_parties_near_user`
   `SECURITY DEFINER` and apply visibility explicitly in its body. Variant D
   is that plan: ~2 ms, a 100× on today. It moves the visibility rule into a
   third place, so it needs the same equivalence treatment
   `17_parties_policy.test.sql` gives the second one — which is now a pattern
   to copy rather than an argument to have.
2. **A leakproof, indexable pre-filter.** Gotcha 22 measured a `starts_at`
   window taking the map body 1483 ms → 42 ms purely by sorting ahead of the
   policy, and the Τώρα / Αργότερα / Το ΣΚ chips push exactly such a predicate.
   Plain `float8` lat/lon columns with a btree index would let a bounding box
   do the same thing spatially, since `float8gt`/`float8lt` are leakproof where
   `geography_overlaps` is not. Cheaper than option 1 and complementary to it.
3. **Mark the PostGIS operators `LEAKPROOF`.** One `alter function`, superuser
   only. It is a real security judgement, not a flag flip: leakproof asserts
   the function cannot reveal argument values through error messages, and the
   arguments here are rows the caller may not be allowed to see. Cheapest to
   type, hardest to justify.

**Search (Phase 13) is still blocked, and for the unchanged reason.** An
`ilike` on `title`/`area` has `st_dwithin`'s exact failure mode — non-leakproof,
therefore behind the barrier, therefore unable to reach a `pg_trgm` index. The
hoist lowered the floor it would be measured against from 995 ms to 199 ms but
did not remove it. Option 1 or 2 above is the real unblock.
