# Phase 14 brief — text search, in two shippable pieces

**Status:** scoped, not started.

**Two PRs, in this order.** Piece A (people) depends on nothing and ships
alone. Piece B (parties) reuses A's normalizer and nothing else.

**Goal:** search by typing text, over everything the viewer is allowed to see,
with no spatial bound, no `SECURITY DEFINER`, and no new visibility rule.

This is the phase that Phase 12's brief said was blocked and Phase 13's said was
still blocked. Both were right at the time and both were reasoning about
`ilike`. The unblock is that `ilike` is not the only way to match text.

---

## 1. Why this is possible now

`scripts/explain_qual_pushdown.sh`, 10k parties, viewer = stranger. Measured,
not read off the catalog:

| | predicate | order | buffers | exec |
|---|---|---|---|---|
| A | *(policy only, baseline)* | — | 40,760 | 190.0 ms |
| C | `title LIKE '%x%'` | policy first | 40,591 | 211.9 ms |
| F | `title ILIKE '%x%'` | policy first | 40,591 | 189.0 ms |
| G | `title LIKE 'x%'` **+ `text_pattern_ops` index** | policy first | 40,595 | 180.2 ms |
| E | `title >= 'x' AND title < 'y'` | **predicate first** | 466 | 1.1 ms |
| I | E, with the index present | predicate first, *no index* | 466 | 1.3 ms |
| **J** | `title ~>=~ 'x' AND title ~<~ 'y'` **+ index** | **INDEX COND** | **13** | **0.035 ms** |
| H | `title = 'x'` + index *(control)* | INDEX COND | 2 | 0.019 ms |

Catalog agrees: `text_ge`/`text_gt`/`text_le`/`text_lt` **and**
`text_pattern_ge`/`text_pattern_lt` are all `proleakproof = t`. `textlike` and
`texticlike` are `f`.

### The two traps in front of it

Both are measured above, and both look like the thing that works.

**`LIKE 'x%'` is NOT rewritten into a range across the barrier (G).** The
planner forms that range as an *index qual*, and `textlike` is non-leakproof, so
it can never be promoted past the policy. A `text_pattern_ops` index is as
unreachable for `LIKE 'x%'` as `parties_location` is for `st_dwithin`. **The
range has to be written out by hand.**

**The operator class has to match (I vs J).** `>=` and `<` are the default
`text_ops` family. They are leakproof and they *are* promoted — but they cannot
use a `text_pattern_ops` index, so they still seq-scan (466 buffers vs 13). Only
`~>=~` and `~<~` both promote **and** reach the index.

A corollary that decides the architecture: **PostgREST cannot express `~>=~`.**
Its `.gte()` emits `>=`, which is variant I — promoted but index-less. Search
must therefore be an RPC. That is a forcing function, not a limitation.

---

## 2. The shared normalizer — `public.search_normalize(text) -> text`

One function, both pieces. Output is `[a-z0-9]` and nothing else.

lowercase → strip Greek diacritics (`ά έ ή ί ό ύ ώ ϊ ϋ ΐ ΰ`) → final sigma
`ς` → `σ` → **transliterate Greek to canonical Latin** → drop every remaining
character outside `[a-z0-9]`.

### Latin, not Greek — and the third reason is the load-bearing one

1. It is the only way `taratsa` and `ταράτσα` land in the same space, which is
   the whole point of transliteration.
2. It removes an entire class of normalization mismatch between what is stored
   and what is typed.
3. **`text_pattern_ops` compares bytes.** With an ASCII-only column, byte order
   *is* character order, so the range `[p, succ(p))` is provably the set of
   strings starting with `p`. `succ(p)` becomes "increment the last byte", which
   never carries because `z` is `0x7A`. With multibyte Greek in the column,
   neither of those is obvious — and getting `succ` wrong is silently dropped
   results, the same failure shape as Phase 13's 298-vs-299.

### `translate()`, never `unaccent()`

`unaccent` is **not installed here, and is `STABLE` even where it is** — it
depends on a dictionary file, so it cannot appear in a generated column or an
index without lying about volatility. `lower`, `translate`, `replace` and
`regexp_replace` are all `provolatile = i` (measured). Greek diacritics are a
small closed set, so `translate()` is both honest and sufficient.

### Greeklish is a mapping table, and it will be tuned

Digraphs need `replace()` chains, not `translate()`: `θ`→`th`, `ψ`→`ps`,
`ξ`→`x`, `ου`→`ou`, `μπ`→`b`, `ντ`→`d`, `γκ`→`gk`. Several are genuinely
ambiguous — `χ` is `ch` or `h`, `β` is `v` or `b`, and people type `8` for `θ`
and `3` for `ξ`. Pick one canonical direction, write the ambiguities down in the
function's comment, and expect to revisit it.

**The trap that follows from "it will be tuned":** a `GENERATED ALWAYS` column
does **not** recompute when the function *body* changes, and Postgres does not
warn. PG 17 has `ALTER TABLE … ALTER COLUMN … SET EXPRESSION AS (…)` to force
the rewrite, but the actual protection is the staleness assertion in §5 — which
also covers the trigger-maintained case in piece B.

---

## 3. Piece A — profile search

### What is searched

`username` only. **`profiles` has no display name column**; that is the whole
searchable identity surface.

### The column

`profiles.username_search text GENERATED ALWAYS AS (public.search_normalize(username)) STORED`,
plus a `text_pattern_ops` btree on it.

The existing `profiles_username_lower_idx` is `unique btree (lower(username))` —
default `text_ops` — so it cannot serve this and must not be confused for it.

**Generated, not a trigger, and the reason is erasure.**
`complete_account_erasure` scrubs `username` to `deleted_<uuid>`. A generated
column is recomputed by that very UPDATE, so the old handle is gone with no
extra step. A side table would retain it until somebody remembered to purge it
in the erasure engine — one more place to forget, in the one path where
forgetting is not allowed.

### No `_`-tokenization in v1

Whole-username prefix. This loses `invited` → `friend_not_invited`; real
usernames are one word and that fixture is a test persona. Splitting on `_` is a
strict upgrade later and **does not change the RPC** — only what it ranges over.

### This is a REPLACEMENT, and it is a regression in one axis

`SocialRepository.searchProfiles` already exists and does
`.ilike('username', '%$q%')`. Today's behaviour is **infix**; prefix is
narrower. That was accepted deliberately, but it is a change to a shipped
feature, not a new capability, and it should be called out in the PR.

The new RPC must preserve what that method does today: `deleted_at is null`,
and excluding the caller's own row.

### Tombstones

The `profiles` SELECT policy is `NOT is_blocked((select auth.uid()), id)` and
**must not** gain a `deleted_at` term — CLAUDE.md's inner-join argument stands.
So the RPC filters it, and three things follow:

- Today the filter is a PostgREST argument supplied by the client, which
  CLAUDE.md already flags as UX rather than enforcement. Inside an RPC it
  becomes enforcement.
- It is not belt-and-braces: the scrub makes `username_search` read
  `deleteduuid…`, so **a search for `deleted` would return every tombstone.**
- Check `erased_at` alongside `deleted_at` rather than assuming one implies the
  other.

**The RPC stays `SECURITY INVOKER`.** People search behind a definer function is
the oracle argument at its worst — the attacker supplies the predicate and reads
the answer back.

---

## 4. Piece B — party search

### What is searched

`title` and `area`. `title` is multi-word, so tokenization is unavoidable:
`party_search_tokens (party_id uuid, token text)`, `on delete cascade`,
trigger-maintained on `insert or update of title, area`, with a
`text_pattern_ops` btree on `token`.

Trigger rather than generated because one party produces many rows, which a
generated column cannot express. The staleness assertion in §5 is therefore
doing more work here than in piece A and is not optional.

### RLS on the token table

`using (public.can_access_party(party_id))`. Tokens reveal the titles of private
parties, so the table needs a policy — and it is a **call to the canonical
helper**, not a new rule (rule #4). The prefix range is leakproof and sorts
ahead of it, so the helper runs only on tokens that already matched. Same shape
as Phase 13: the barrier stays, the input to it shrinks.

### DECISION: `map_visibility` does NOT filter search

**Write this into the code as a comment, because the next reader will assume the
opposite.**

`profiles.map_visibility` answers *"do I want to be a pin on the map"*, not
*"do I want to be unfindable"*. A party the viewer is allowed to see must be
findable by name — otherwise you are invited somewhere you cannot locate.

Search visibility is therefore `can_access_party` and nothing else. If a
separate "hide me from search" control is ever wanted it gets **its own
column**; do not overload this one.

### DECISION: `status`

`published` only. Drafts are out.

### DECISION: `ends_at`, past parties, and gotcha 21

Past parties **are returned**, in a separate group below the upcoming ones —
"find that party from May" is a real use.

That needs a past/upcoming split, and gotcha 21 says the data cannot answer it:
`ends_at` is nullable, so a finished party with no end time is
indistinguishable from a running one.

**The fallback to `starts_at` is correct here, and it is correct here
specifically.** The map asks *"should this pin exist?"* — being wrong in one
direction leaves a dead party on screen, and in the other **removes a live one**.
That asymmetry is why gotcha 21 is still open. Search asks *"which group?"* —
**both groups are shown**, so being wrong moves a row one section down. The
consequence is cosmetic, and a heuristic that is unacceptable for the map is
acceptable here.

**One definition, one place:** `public.party_is_past(starts_at, ends_at)`,
`coalesce(ends_at, starts_at + <grace>) <= now()`. Search uses it to *group*.
The map may later use it to *filter*, when that product decision is made.

Until then search and the map **will visibly disagree** about a party with a
null `ends_at` that started days ago: search files it under past, the map still
pins it. That is real and should be expected rather than reported as a bug. It
is a sequencing state, not a divergence — there is one definition and one
surface has adopted it — and when the map adopts it they agree by construction.
The map's decision also gets cheaper: the number will already exist and have a
name, instead of being invented from nothing.

Note the grace period only ever applies to rows with a null `ends_at`. Every
past party in `seed.sql` sets one, so the fixtures exercise the honest path and
the null path must be seeded deliberately.

Ordering: upcoming ascending by `starts_at` (soonest first), past descending
(most recent first).

---

## 5. The tests — three levels and two controls

The mistake this has to survive is somebody rewriting the range as `LIKE` or
`ILIKE`, because that reads as a simplification and is measurably a 5000×
regression. No single level catches it.

### Level 1 — structural tripwire

Assert the RPC's `prosrc` contains `~>=~` and `~<~` and does **not** contain
`~~*` / `ilike` / `like`. Same technique as `18_map_spatial_prefilter`'s
"`st_dwithin` is still in the RPC". Cheap; catches the obvious; proves nothing
about mechanism.

### Level 2 — the mechanism, via the index scan counter

`pg_stat_get_xact_numscans` is **transaction-local**, so unlike most plan facts
it is reachable from pgTAP (it is the same counter
`explain_policy_pushdown.sh` uses). Read it, call the RPC, read it again, assert
it increased.

If the RPC is rewritten with `ILIKE` the index **cannot be used at all**, the
counter stays flat, and the test goes red.

Run it under `set local enable_seqscan = off` so it discriminates at fixture
size. That does not weaken the test: the question is whether the index is
*reachable*, not whether the planner prefers it, and `ILIKE` still seq-scans
with seqscan disabled.

### Level 3 — the range is actually a prefix match

The analogue of Phase 13's superset invariant. `[p, succ(p))` must equal
`{x : x starts with p}` **exactly**. A wrong `succ` is not slow, it is silently
missing results.

`except` in **both directions**, over a corpus with adversarial prefixes: ending
in `z`, single character, empty, digits only, the full string, and one that
would break if the column ever contained non-ASCII.

### The two controls, without which the above can go vacuous

**Control 1 — a deliberately wrong `succ` must fail level 3.** Compute the range
with the last character left unincremented and assert the invariant is
*violated*. If this ever stops failing, the corpus no longer reaches the
boundary and level 3 is passing for no reason. Directly modelled on "the naive
degrees-per-metre box DOES drop parties" in `18`.

**Control 2 — the naive range must drop rows.** Assert that a `text_ops` range
(`>=` / `<`, variant I) does **not** scan the `text_pattern_ops` index, and that
`LIKE 'x%'` does not either. This is what stops somebody "simplifying" `~>=~`
back to `>=` — which still returns correct rows, still passes levels 1 and 3,
and quietly costs 466 buffers instead of 13.

### Plus one catalog assertion

`text_pattern_ge` / `text_pattern_lt` are still `proleakproof = t`, in the style
of `13_hardening`. A Postgres upgrade that changed this would invalidate the
entire design, and that should arrive as a red test.

### And the staleness assertion, both pieces

Recompute `search_normalize()` for every row and compare against the stored
value. Catches a generated column left stale by a changed function body (piece
A) and a trigger that failed to fire (piece B). Same shape as `18`'s "every
row's bbox columns agree with its location".

Piece A additionally: erase an account, then assert **no** searchable artefact
still contains the original handle.

---

## 5b. The uncapped tail, and the agreed way it is handled

**Decided 2026-08-22. `search_parties` stays UNCAPPED. Do not "fix" it with a
`LIMIT` on the candidate set.**

Measured at 10k parties, authenticated, through RLS:

| query | matches | exec |
|---|---|---|
| `zeppelin` | 1 | 2.1 ms |
| `taratsa` | ~3,333 | 295 ms |

Cost is O(matches × policy), not O(table). That is the right shape — reaching
the index is what makes it depend on matches at all — but a *broad* prefix is
slow, because every candidate pays the `parties` and `profiles` policies before
`ORDER BY` can pick the top 20, and no index can order a set RLS has not
filtered yet.

**The database fix was rejected.** Putting a `LIMIT` on the `hits` CTE bounds
the worst case and turns *"the 20 soonest matching parties you can see"* into
*"20 of the first N candidates, whichever those happen to be"*. For a viewer
whose visible parties all sort late, that silently returns fewer results than
exist. **Quiet result loss is the exact failure this entire phase was built to
avoid** — it is the 298-vs-299 bounding box and the eaten `` backreference in
a third costume — and it does not become acceptable by arriving through the
performance door instead of the correctness one.

**The agreed fix is in the client, because the expensive query is not a useful
one.** `SearchScreen` sends nothing until **3 characters**, and debounces
**300 ms**. A two-letter prefix like `τα` matches a third of the corpus and
tells the user nothing; it is not a search worth running, so not running it
costs nothing. Three characters collapses the candidate set to the selective
end of the curve above.

This is a UX constraint standing in for a database one, which means it can be
bypassed by any other client. That is accepted: the failure mode of bypassing it
is a *slow* query, not a wrong one. The reverse — a fast query that quietly
drops results — is the one that had to be designed out, and it was.

---

## 6. Out of scope

- **Infix search.** `εχν` will not find `Τεχνο`. Accepted deliberately; nobody
  types word-middles. If it is ever wanted, that is `pg_trgm` behind the barrier
  or the public-only index table rejected in
  `phase-12-policy-rewrite-result.md` §5 — and the argument there is staleness,
  not performance.
- **`_`-tokenization of usernames** (piece A v1).
- **The map adopting `party_is_past`.** §4. Still a product decision; do not
  fold it into this phase.
- **A separate "hide me from search" control.** §4 — its own column if ever.
- **`SECURITY DEFINER` anything.** §9 of `phase-12-parties-policy-rewrite.md`.
