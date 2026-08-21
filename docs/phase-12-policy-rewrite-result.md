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

## 5. The three routes, measured

**Recommendation: route 2.** It is the only one that leaves the privacy story
where it is, and it gets 96% of route 1's benefit.

### Route 3 — mark the PostGIS operators `LEAKPROOF`: **ruled out, not a judgement call**

```
postgres=> alter function public.st_dwithin(geography,geography,double precision,boolean) leakproof;
ERROR:  must be owner of function public.st_dwithin
```

`ALTER FUNCTION … LEAKPROOF` is superuser-only, `st_dwithin` is owned by
`supabase_admin`, and `postgres` is not a member of it — locally *or* hosted.
This is the same shape as gotcha 9's `spatial_ref_sys` exception: not something
a migration can do. Which is just as well, because it was also the one option
with a real security cost — `LEAKPROOF` asserts a function cannot reveal its
arguments through error messages, and its arguments here are rows the caller is
not allowed to see.

### Route 2 — a leakproof, indexable pre-filter: **9.3 ms, measured**

Variant E of `scripts/explain_policy_pushdown.sh`, at 10k parties, **with the
shipped policy completely untouched**:

| | scan on `parties` | rows into the policy | buffers | exec |
|---|---|---|---|---|
| shipped policy, spatial predicate only | Seq Scan | 10,022 | 28,868 | 205.0 ms |
| **+ leakproof bounding box** | **Index Scan on `parties_lat_lon_idx`** | **430** | **1,646** | **9.3 ms** |

Same 264 rows out of both. `lat`/`lon` are `GENERATED ALWAYS … STORED` columns
off `location`, so they cannot drift from it and need no trigger; the box bounds
are scalar subqueries, so they are computed once as InitPlans and the per-row
predicate stays a plain `float8` comparison against a constant — leakproof,
therefore promoted ahead of the policy, therefore indexable. Buffers is the
honest metric: 28,868 → 1,646 is `is_blocked` being called ~430 times instead of
~10,000.

This is the same mechanism as the time-filter chips, applied spatially, and the
two compose.

> **The sharp edge, and it drew blood.** The box must be a *provable superset*
> of the circle. The first attempt used `5000 / 111320 = 0.0449°` of latitude
> and returned **298** rows where the unfiltered query returned **299** —
> `st_dwithin` on `geography` measures on the WGS84 spheroid, where a degree of
> latitude at 38°N is ~110,996 m, so 5000 m is 0.04501° and the box silently
> clipped a real party off the map. A correctness bug wearing a speedup
> costume. Derive the bounds from PostGIS (`st_envelope` of a geodesic
> `st_buffer`, padded) rather than typing degrees, and keep the equal-count
> assertion — it is what caught this.

Note what route 2 does **not** do: it reaches a new btree, not
`parties_location`. The GiST index stays unreachable under RLS, so §7.3's
literal criterion is unmet here too. The criterion was the wrong target; the
row count reaching the policy is the right one.

### Route 1 — take the scan out of RLS: ~2 ms, and the whole privacy story moves

Make `get_parties_near_user` `SECURITY DEFINER` and filter visibility explicitly
in its body. Variant D is that plan: ~2 ms.

**The objection is not "one more copy of the rule."** That framing undersells
it badly: this project already decided once that a second copy is acceptable
when a test pins it — that is §2 of the brief and it stands. If duplication
were the whole problem, the answer would obviously be "write another
equivalence test and take the 100×."

**Reason 1 — it is two rules, not one, and the second is invisible unless you
read the plan.** The map query joins `profiles`, and the `profiles` row policy
is contributing a term to that join today:

```
->  Index Scan using profiles_pkey on profiles pr
      Filter: ((NOT is_blocked((InitPlan 96).col1, id)) AND ((map_visibility = 'public') OR ...))
```

The `map_visibility` half is the RPC's own; `NOT is_blocked(auth.uid(), id)` is
**the policy's**. `SECURITY DEFINER` switches off row security for *every* table
the function touches, so the RPC must reimplement the `parties` visibility rule
**and** the `profiles` block filter. Anyone scoping this from the §2 diff will
plan for one and ship one — and the one that gets forgotten is a block filter,
which fails open, silently, in favour of the person who was blocked.

**Reason 2 — the `parties` policy is a backstop with nothing under it once you
leave.** It is not just this query's filter: it is the last line for every read
path against that table — PostgREST reads, the seven other policies in §6 that
reach `parties` underneath, and every query nobody has written yet. Today a bug
in `get_parties_near_user`'s `where` clause is *caught* by the policy; the RPC
can be wrong and the data still does not leak. A definer RPC is exactly as
correct as its own `where` clause.

So the trade is **~7 ms against the defence-in-depth on the widest-blast-radius
table in the schema**, and at 9.3 ms versus 2 ms it is not close. Reopen it with
a measurement showing 9 ms is insufficient — never with the 100× headline. The
same argument, at length and placed where someone chasing that headline will hit
it, is §9 of
[`phase-12-parties-policy-rewrite.md`](phase-12-parties-policy-rewrite.md).

If it is ever taken, the equivalence-assertion pattern in
`17_parties_policy.test.sql` is the thing that makes it survivable, and it is
now a pattern to copy rather than an argument to have.

### Sequencing

Route 2 first — it is additive, reversible, changes no visibility rule, and is
measured. Scoped as
[`phase-13-leakproof-spatial-prefilter.md`](phase-13-leakproof-spatial-prefilter.md),
with the superset assertion as a shipping requirement rather than a follow-up. Re-measure route 1 only if 9 ms is not enough, at which point the
question is worth asking with real numbers instead of a 100× headline.

**Search (Phase 13) is still blocked, and for the unchanged reason.** An
`ilike` on `title`/`area` has `st_dwithin`'s exact failure mode — non-leakproof,
therefore behind the barrier, therefore unable to reach a `pg_trgm` index. The
hoist lowered the floor it would be measured against from 995 ms to 199 ms but
removed nothing structural. Route 2 is the unblock, and note it does not unblock
search *by itself*: a bounding box shrinks the input to a search predicate, but
a text search with no spatial bound is still a seq scan. Search needs either its
own leakproof pre-filter or route 1.
