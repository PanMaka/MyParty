# Phase 15 — the map's time chips, filtered server-side

**Status: shipped.** Migration `20260823091942_map_time_windows.sql`, pgTAP
`21_map_time_windows.test.sql` (42 assertions), measurement
`scripts/explain_map_time_windows.sh`.

---

## 1. What was actually there

`_MapFilter` in `map_screen.dart` had three states, defaulted to `live`, and
was read at exactly one place — line 270, to decide whether to paint the pill
purple. **No query had ever seen it.** The map opened with "Τώρα" highlighted
over a completely unfiltered set of pins, which was harmless only because the
filter did not work; the moment it did, that default would have hidden most of
the map on open.

So the phase is two halves: a window parameter on `get_parties_near_user`, and
a fourth chip (Όλα) that becomes the default.

---

## 2. The four windows

Every window is a **half-open `[lower, upper)` range over `starts_at`**, and
always bounded — `'all'` returns `(-infinity, infinity)` rather than nulls, so
the RPC applies two unconditional comparisons instead of branching. A null
bound would need `or bound is null` in the `WHERE`, which is an extra per-row
term on the hottest query in the schema for no gain.

| chip | window | plus |
|---|---|---|
| **Όλα** (default) | `[-infinity, infinity)` | — |
| **Τώρα** | `[-infinity, now)` | and not over — see §3 |
| **Αργότερα απόψε** | `[now, next local 04:00)` | — |
| **Το ΣΚ** | `[greatest(now, Fri 18:00 local), Mon 04:00 local)` | — |

### Tonight ends at 04:00, not midnight

At 23:30 a midnight boundary makes the chip cover thirty minutes and excludes a
party starting at 00:30 — the single most common start time in this domain.
04:00 also fixes the harder case: at 02:00, "tonight" is the two hours left of
the night in progress, not the twenty-six hours to tomorrow morning. That is
implemented as an **anchor day**: a night belongs to the day it started on
until 04:00 local, so at 02:00 on Saturday the anchor is Friday.

**Known consequence, accepted.** Because the lower bound is `now` rather than
"this evening", tapping Αργότερα απόψε at 11:00 in the morning includes a 16:00
afternoon party. Clamping the lower bound to 18:00 local (mirroring the weekend
rule) would fix that and was not done: "Αργότερα" reads as *later*, from now,
and the daytime case is the rare one. If it ever grates, the change is one
`greatest()` in `party_time_window` and a test.

### The weekend is Friday 18:00 → Monday 04:00, and always the current one

`isodow` of the anchor day decides: Fri/Sat/Sun means the weekend is in
progress, so walk back to its Friday and let the lower bound clamp to `now`;
Mon–Thu means the coming Friday. The Monday 04:00 end is the same night
boundary `tonight` uses, which is what keeps a Sunday-night party running to
02:00 inside the weekend instead of dropping it into the following week.

Checked at every corner in `21_map_time_windows.test.sql` §3: Monday 02:00
local still returns Monday 04:00 (two hours of weekend left); Monday 05:00
rolls forward to the next Friday.

**Αργότερα ⊂ Το ΣΚ on a Friday or Saturday night.** That is correct, not a bug
— the chips are four viewpoints, not a partition.

---

## 3. Nulls, and why `party_is_past`'s grace transfers

**Only Τώρα looks backwards.** Αργότερα and Το ΣΚ are forward-only windows on
`starts_at`: everything they can match starts in the future, so it cannot have
ended and `ends_at` never enters their predicates. gotcha 21's null-`ends_at`
majority — 81% of parties carry no end time — is therefore reduced to exactly
one window's decision instead of four.

Τώρα's decision: a party with no stated end drops out once it is older than
`party_end_grace()` — the same six hours search groups by.

### Why that is safe here, specifically

Phase 14 was careful to say the grace was calibrated for **grouping**, not
filtering, and that is right. It transfers because of the *shape* of the
argument rather than the number:

- Search's argument was "both groups are shown, so being wrong moves a row one
  section down". The map's is one level up: **the other chip is one tap away.**
  A barbecue from last Tuesday drops out of Τώρα and is still on Όλα.
- **The base filter is untouched.** `status = 'published' and (ends_at is null
  or ends_at > now())` is exactly what it was. Όλα is the default. **This phase
  cannot remove a pin from anyone's default map**, which is precisely the
  asymmetry gotcha 21 says is unacceptable — being wrong there *removes a live
  party*, and being wrong here costs a tap.

**gotcha 21 is therefore still open.** The map still pins a null-`ends_at`
party forever in its default view. `21_map_time_windows.test.sql` asserts that
directly, so closing it stays a decision somebody takes rather than a side
effect somebody causes.

---

## 4. The trap: one definition, two spellings

The obvious implementation is the slow one, and it is slow for a reason no
amount of reading the code reveals.

`contain_leaked_vars` rejects a node when it holds a leaky function call **and
there is a Var underneath it**. Measured on the running stack:

```
timestamptz_ge/gt/le/lt     leakproof = t
timestamptz_pl_interval     leakproof = f
party_is_past               leakproof = f, proconfig = {search_path=""}
```

So `coalesce(ends_at, starts_at + interval '6 hours') > now()` puts a Var under
`timestamptz_pl_interval` and sinks behind the RLS barrier. Moving the interval
to the constant side — `starts_at > now() - grace` — leaves
`timestamptz_gt(Var, Const)` and is promoted ahead of the policy. And
`party_is_past()` is doubly unusable: not leakproof, *and* it carries a SET
clause so it can never be inlined (gotcha 20).

`scripts/explain_map_time_windows.sh` Part 2, at 10k parties, **all three
variants returning the same 170 rows**:

| spelling | exec | buffers | filter order |
|---|---|---|---|
| constant side (shipped) | **6.2 ms** | **1014** | **grace, then policy** |
| row side (`coalesce`) | 120.7 ms | 20576 | policy, then coalesce |
| `party_is_past()` | 109.2 ms | 20576 | policy, then helper |

~20×, for an algebraically identical predicate.

**`party_end_grace()` is how "one definition" survives that.** The *number*
lives once; the two call sites use the two different shapes leakproofness
forces on them, and `21_map_time_windows.test.sql` asserts they flip at the
same instant so they cannot drift into two policies.

`20_party_search.test.sql`'s tripwire — "the MAP does not use `party_is_past`"
— did its job: it turned red, which is where the product decision got taken
rather than absorbed. It is now two assertions describing the partial adoption.

---

## 5. Where the local boundary is computed

**In Postgres, on a naive local clock, in the zone named by `p_tz`
(default `Europe/Athens`).**

1. The rules are one definition. If the client passed two instants, "the
   weekend is Fri→Mon" would live in Dart and any later surface would get a
   second copy.
2. The arithmetic must run on `timestamp` (naive local) and convert back with
   `AT TIME ZONE` at the very end. Adding `interval '3 days'` to a `timestamptz`
   across a DST change moves the **wall clock** by an hour; adding it to a naive
   local timestamp does not. **Greece's transitions land at 04:00 local, which
   is exactly this phase's night boundary.** Asserted: a weekend spanning
   2026-10-25 ends at `2026-10-26 02:00Z` = Monday 04:00 EET. Timestamptz
   arithmetic yields `01:00Z` = 03:00 local.
3. A client passing a UTC offset structurally cannot get (2) right. Postgres
   carries the IANA database; `DateTime.now().timeZoneName` in Dart gives
   `"EEST"` — an abbreviation, not a zone.

**The client sends nothing in v1.** Adding a Flutter timezone plugin was scope
creep; the parameter is the seam.

**Deliberately not defaulted to `profiles.notification_tz`.** That column is
documented as the zone *quiet hours* are evaluated in. Coupling them would make
changing your push schedule silently change what "tonight" means on your map —
two questions, two columns, the same split `20260817073507` drew between consent
and preference.

---

## 6. The plans — measured, not assumed

The claim gotcha 22 makes is that time predicates are leakproof and evaluate
before `can_access_party`. Two things needed measuring that the existing
`explain_qual_pushdown.sh` could not answer, because it predates both
pre-filters.

### Does a bound from a plpgsql STABLE function still reach the plan as a constant?

A literal obviously does. A function call is the thing that could quietly become
a correlated expression — at which point the predicate stops being `timestamptz
op const`, stops being leakproof, and sinks behind the barrier **with no symptom
other than the old timing**. Same failure `20260821201309` warns about for the
bbox bounds.

It does. Part 1 prints `Filter: ((starts_at >= (InitPlan 1).col1) AND (starts_at
< (InitPlan 2).col1) AND (NOT is_blocked(...)) AND (... can_access_party(id)))`
— time terms first — and the scan drops **40518 → 2409 shared hits**.

### Do the spatial and time pre-filters compose, or does one shadow the other?

Both are leakproof and both sort ahead of the policy, but at 5km the box already
cuts 10k rows to a few hundred, and a second filter cannot save what is no
longer being spent. Part 3, map query body at 5km with the tonight window:

| | exec | plan |
|---|---|---|
| neither pre-filter | 210.6 ms | seq scan |
| box only (Phase 13, = Όλα today) | 12.0 ms | `Index Cond` on `parties_bbox_idx` |
| window only | 14.4 ms | seq scan, time terms first |
| **both (what a chip tap ships)** | **2.1 ms** | Index Cond **+** time filter ahead of the policy |

They compose: **100× against the pre-Phase-13 shape, and 5.8× better than
today's default view.** The box gets the index, the window filters what survives
it, and neither shadows the other.

### Reproducing the earlier figure

`explain_qual_pushdown.sh`'s header recorded `1483 ms → 42 ms` for exactly this
question on 2026-08-21. Re-running it unchanged today gives **208 ms → 6.4 ms**:
the *ratio* reproduces (35× → 33×) and the absolute floor fell ~7× because the
header predates `20260821185216`, the Phase-12 policy hoist. That header has
been corrected in place rather than left as a second, contradictory table.

---

## 7. Two things this phase got wrong first

Both were caught by controls rather than by review, which is the argument for
writing the controls.

**A `DROP` + `CREATE` reset the RPC's ACL.** Adding defaulted parameters makes a
new function rather than replacing one, so the old 4-arg version had to be
dropped — and a dropped function's grants do not survive. The recreated function
came back holding Postgres's default `EXECUTE TO PUBLIC`
(`proacl = {=X/postgres,...}`), silently undoing `20260821175831`, and
`revoke ... from anon` would **not** have fixed it because anon's privilege then
comes from PUBLIC rather than from a grant to anon. The revoke has to be from
PUBLIC, followed by the gotcha-13 grant back to `service_role`.
`16_map_query_payload_and_limit.test.sql` is what caught it. **Any future
signature change on any granted function has this trap.**

**The first measurement compared three different questions.** Part 2's
constant-side variant omitted the base `ends_at` filter that the real RPC ANDs
with the grace, so the control printed `2282 | 170 | 170`. Only the *pair* of
terms is equivalent to `not party_is_past()`: with a stated end the base filter
decides, with a null end it is vacuous and the grace decides. Without the
control the phase would have shipped a plausible number that was measuring the
wrong predicate.

A third, smaller one: `party_end_grace()` was written without a pinned
`search_path`, on the theory that the SET clause would foreclose constant
folding. `13_hardening.test.sql`'s project-wide lint caught it, and the theory
turned out to be wrong — what makes the constant is the **scalar subquery at the
call site**, not the function's marking. The test now asserts the subquery,
which is the half that actually load-bears.

---

## 8. Out of scope

- **Closing gotcha 21.** §3. Still a product decision: make `ends_at` required
  at creation, or add an `ended` value to `party_status`.
- **A client-supplied IANA zone.** §5 — needs a Flutter plugin.
- **Clamping Αργότερα's lower bound to 18:00.** §2, recorded as a known
  consequence.
- **Multi-select chips.** Exactly one active at a time, which is what the
  single `p_window` parameter encodes. Two windows at once would be a
  `tstzmultirange` and a different UI.
