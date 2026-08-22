# Phase 13 brief — a leakproof spatial pre-filter for the map query

**Status:** scoped, not started. **Blocked on `phase/11-map-rework` merging to
`main`**; cut the branch after that, not before — see §7.

**Goal, in one sentence:** cut the number of rows that reach the `parties` row
policy, by adding a bounding-box predicate the planner is *allowed* to evaluate
before it — without changing who can see which party, and without moving any
visibility rule.

Measured target: **205 ms → 9.3 ms** at 10k parties, 5km zoom, with the policy
untouched. Reproducible today as variant E of
`scripts/explain_policy_pushdown.sh`.

This is route 2 of §5 of
[`phase-12-policy-rewrite-result.md`](phase-12-policy-rewrite-result.md). Read
that section and the banner on
[`phase-12-parties-policy-rewrite.md`](phase-12-parties-policy-rewrite.md)
first — this brief assumes both, and the second one exists mainly to stop this
phase repeating Phase 12's reasoning error.

---

## 1. Why this works when the policy rewrite did not

Phase 12 established the mechanism and got it the wrong way round the first
time. Stated correctly:

> An RLS qual is a security barrier. A **user** qual may be evaluated ahead of
> it — which is what becoming an `Index Cond` requires — **only if that user
> qual is leakproof.** This depends on the user qual, never on the policy's
> cost and never on the policy's own leakproofness.

`st_dwithin`, `_st_expand` and `geography_overlaps` are all
`proleakproof = f`, which is why no policy rewrite could ever reach
`parties_location` and why Phase 12's hoist bought 5× and no index.

`float8ge` and `float8le` **are** leakproof. So a predicate written as
`lat between <const> and <const>` sorts *ahead* of the policy, reaches a plain
btree, and shrinks the input before `is_blocked` is called even once. Same
mechanism the Τώρα / Αργότερα / Το ΣΚ time chips use, applied spatially; the
two compose.

Measured, variant E, 10k parties, **shipped policy completely untouched**:

| | scan on `parties` | rows into the policy | buffers | exec |
|---|---|---|---|---|
| spatial predicate only | Seq Scan | 10,022 | 28,868 | 205.0 ms |
| **+ leakproof bounding box** | **Index Scan on `parties_lat_lon_idx`** | **430** | **1,646** | **9.3 ms** |

Same 264 rows out of both. Buffers is the honest metric: 28,868 → 1,646 is
`is_blocked` running ~430 times instead of ~10,000.

**What this does not do.** It reaches a *new btree*, not `parties_location`.
The GiST index remains unreachable under RLS and that is fine — it is reached
today by the notification engine, which is `SECURITY DEFINER`. Do not set an
acceptance criterion mentioning `parties_location`; Phase 12 did and it was
unachievable. **The criterion here is rows-into-the-policy, not which index.**

---

## 2. What changes

1. Two generated columns on `parties`:

   ```sql
   alter table public.parties
     add column lat double precision generated always as (st_y(location::geometry)) stored,
     add column lon double precision generated always as (st_x(location::geometry)) stored;
   ```

   `GENERATED ALWAYS … STORED`, not a trigger and not plain columns: they
   cannot drift from `location`, cannot be written by anyone, and need no
   backfill logic beyond the `alter`. `location` stays the source of truth and
   the only thing any spatial predicate is *answered* by.

2. A btree index on `(lat, lon)`.

3. `get_parties_near_user` gains the bounding-box terms, derived per §3.

Nothing else. **No policy changes, no helper changes, no new visibility logic
anywhere.** That is the entire point of choosing this route over the
`SECURITY DEFINER` RPC — see §9 of the Phase 12 brief for why that was
rejected, and do not reopen it here without a measurement.

### Does this break the two-geography-column assertion?

No. `08_proximity_and_retention.test.sql` asserts over `pg_attribute` that
`parties.location` and `user_devices.last_location` are the only two
**geography** columns in `public`. `lat`/`lon` are `double precision`. Check the
assertion still passes anyway rather than assuming — it is there to stop a
location-history table appearing, and two float columns holding coordinates are
close enough to that shape to be worth a deliberate look. They are defensible
because they are generated, non-writable, and derived from a column already
under the retention story — but `user_devices` must **not** get the same
treatment, because that is exactly the retention clock (gotcha 8), and a
generated column would sidestep `round_location`.

---

## 3. The superset requirement — the hard part, and non-negotiable

**The bounding box must be a provable superset of the `st_dwithin` circle. A
box that is not is a silent data-loss bug, not a slow query.**

This is not hypothetical. It happened during Phase 12's measurement:

> A first attempt computed the half-width as `5000 / 111320 = 0.0449°` of
> latitude. The query returned **298** rows where the unfiltered query returned
> **299**. `st_dwithin` on `geography` measures on the WGS84 spheroid, where a
> degree of latitude at 38°N is ~110,996 m — so 5000 m is 0.04501°, the box was
> 0.00011° too short, and it clipped a real party off the map. No error, no
> warning; a party simply stopped existing for everyone at that zoom.

The failure mode is the worst shape available: it scales with distance from the
equator, it only bites parties within metres of the box edge, and it looks like
a correct optimisation in every test that does not compare counts.

### The rules

1. **Derive the bounds from PostGIS. Never type a degrees-per-metre constant.**
   The known-good form is the envelope of a geodesic buffer, padded:

   ```sql
   st_expand(
     st_envelope(st_buffer(st_point(p_lon, p_lat)::geography, p_radius)::geometry),
     0.001)
   ```

   `st_buffer` on `geography` is geodesic, so its envelope is the circle's true
   lon/lat extent. The `st_expand` pad absorbs the buffer polygon's
   approximation of a circle — `st_buffer` returns a polygon, and there is no
   guarantee its vertices land exactly on the circle's cardinal extremes.

2. **Compute them once, not per row.** They must land as InitPlan constants, or
   the per-row predicate stops being `float8 op const` and stops being
   indexable. Scalar subqueries achieve this; a lateral join may not.

3. **`st_dwithin` stays in the query.** The box is a pre-filter and never the
   answer. Deleting the `st_dwithin` term because "the box already did it"
   turns a square into the wrong answer — this is the same class of mistake as
   deleting either half of the two-term `st_dwithin` in the proximity engine
   (gotcha 10), and worth a comment saying so at the call site.

4. **Pad generously.** Over-padding costs a few extra rows through the filter,
   which is a rounding error against 10,000. Under-padding drops parties.
   The asymmetry is total; there is no reason to tune this tight.

### The assertion, and it ships in the same PR as the feature

Not added later. Not a manual check. In `18_map_spatial_prefilter.test.sql`:

```sql
-- For each of several centres and radii, the boxed query and the unboxed
-- query must return IDENTICAL id sets -- not equal counts, identical sets.
select is_empty(
  $$ select id from <boxed query>
     except
     select id from <unboxed query> $$,
  'the box admits nothing the circle does not'
);
select is_empty(
  $$ select id from <unboxed query>
     except
     select id from <boxed query> $$,
  'and drops nothing the circle admits -- the 298-vs-299 assertion'
);
```

Both directions, separately, for the reason §5.1 of the Phase 12 brief gives:
one containment passing tells you nothing about the other, and a box that
admits everything satisfies the first trivially.

**Coverage that actually exercises the failure.** A single centre at Syntagma
would not have caught the 0.0449° bug — the clipped party has to be near the
box edge. The fixture needs:

- **Parties placed deliberately at the boundary**, at the four cardinal extremes
  of the circle, at radius − 1 m and radius + 1 m. The inner ones must survive
  the box; the outer ones must be excluded by `st_dwithin` and their exclusion
  must come from the circle, not the box.
- **Several latitudes.** The error is a function of latitude, and Athens alone
  hides it. Include a high-latitude centre (say 60°N) and one near the equator;
  the degrees-per-metre ratio for longitude varies by a factor of two across
  that range.
- **Several radii**, including the map's real 5 km / 50 km / 500 km tiers, since
  a constant that is right at one radius can be wrong at another.
- **The antimeridian and the poles are out of scope** — see §6 — but assert the
  RPC's behaviour there is unchanged rather than silently different.

A property-style loop over `generate_series` of centres and radii is worth more
here than any number of hand-picked cases, and is cheap: the whole thing is one
`except` in each direction.

---

## 4. What must NOT change

- **The `parties` SELECT policy.** Untouched. If this phase finds itself
  editing a policy, it has gone wrong — the entire value of this route over the
  definer RPC is that no visibility rule moves.
- **`can_user_access_party`.** Same, and `17_parties_policy.test.sql` will say
  so loudly if it does.
- **`location` as the source of truth.** `lat`/`lon` are derived, generated, and
  used only to *narrow*. No query should ever answer a distance question from
  them.
- **`user_devices`.** No generated coordinate columns there, ever — gotcha 8.

---

## 5. Re-measurement — what "done" looks like

1. `bash scripts/explain_policy_pushdown.sh` — variant E is the prototype of
   this phase, so after implementation the real RPC should match it. **The
   criterion is structural but it is not about an index name:** the 5km plan,
   *read as an authenticated viewer*, must show the box as an `Index Cond` and
   the policy terms as a `Filter` **above** it, with `rows` into the filter in
   the hundreds rather than the thousands.
2. `bash scripts/loadtest_map_query.sh` — same 10k/50k fixture as Phase 10 and
   12, so the numbers stay comparable. Target: **5km stops being the slowest
   tier**, which Phase 12 aimed at and missed.
3. **Never `scripts/explain_proximity.sh`.** It EXPLAINs as `postgres` and
   bypasses RLS; it carries a banner saying so. It cannot fail an RLS change and
   will happily certify a no-op.
4. `supabase test db` in full, not just the new file. `parties` gains two
   columns, and the `insert … returning` path (Phase 12 §5.4) touches them.

---

## 6. Out of scope

- **The antimeridian and polar cases.** A bounding box in lon/lat is wrong
  across ±180° and degenerate at the poles. MyParty is an Athens app and
  `get_parties_near_user` is called with a viewport centre; the honest move is
  to *assert* the current behaviour rather than fix a case that does not exist
  yet. If it ever does, the fix is two boxes OR'd together, not a wider one.
- **Search.** This phase shrinks the input to a spatial query. A text search
  with no spatial bound is still a seq scan behind the barrier, so `pg_trgm` is
  still blocked afterwards and needs either its own leakproof pre-filter or the
  route this project rejected. Do not let "Phase 13 unblocked search" enter the
  record — Phase 12 made exactly that claim and it was wrong.
- **The `SECURITY DEFINER` read RPC.** Rejected, with reasons, in §9 of the
  Phase 12 brief. Reopen it with a measurement showing 9 ms is insufficient,
  not with the 100× headline.
- **The `ends_at` map lifecycle question** (gotcha 21). Still a product
  decision.

---

## 7. Sequencing

Cut the branch from `main` **after `phase/11-map-rework` has merged**, not
before. At the time of writing it has not, and neither has
`phase/12-parties-policy-rewrite`. Both matter here:

- Phase 12 supplies the policy this phase measures against and
  `scripts/explain_policy_pushdown.sh`, whose variant E is this phase's
  prototype.
- Phase 11 supplies test files `14`–`16`, so `18_map_spatial_prefilter.test.sql`
  lands without a numbering gap, and the map RPC payload this phase's RPC change
  builds on.

Branching earlier means reimplementing variant E from scratch and renumbering
the test file later.
