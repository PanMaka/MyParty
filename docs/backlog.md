# Backlog — known gaps, so they are not rediscovered as bugs

Things that are **not done**, deliberately or by omission, and would otherwise
be found by a user before they are found by us.

**The rule for this file:** one line of *why it is still open*, not a
description of the feature. A backlog entry that only says what is missing gets
re-litigated every time somebody reads it; one that says why it was left tells
you whether the reason still holds.

Delete an entry when it ships. If an entry turns out to be a decision rather
than a gap, move it to §3 instead of deleting it.

Last swept: 2026-08-22, after Phase 14B.

---

## 1. Open gaps

### 1.1 An avatar can be replaced but never removed

`ProfileEditScreen` holds `_pendingAvatar`, and its own comment is explicit:
`null` means *"not changing the avatar"*, which is a different thing from
*"no avatar"* — **"this screen offers no way to express the second,
deliberately."**

*Why it is still open:* the deliberate part was scope, not design. Removal needs
a third state in the picker and a `ProfileRepository` path that deletes the
storage object rather than replacing it — and deleting a storage object is
gotcha 7 territory (`delete from storage.objects` does not delete the bytes),
so it is a real piece of work rather than a null assignment.

*What it costs to leave:* a user who uploads the wrong photo cannot undo it,
only overwrite it. That is a support request, not a crash.

### 1.2 The map's time-filter chips are decorative

`Τώρα` / `Αργότερα απόψε` / `Το ΣΚ` set `_filter` in `MapScreen` and **nothing
reads it**. Tapping them re-renders the pill and changes no query.

*Why it is still open:* it was UI-first, and the query work landed later.

*What it costs to leave:* it is the most visible "this app is a mock" tell on
the main screen, and it is leaving a large measured win unclaimed. Gotcha 22
measured a time window on the map query body at **1483ms → 42ms** — a leakproof
`starts_at` predicate sorts *ahead* of the row policy, exactly like Phase 13's
bounding box, and the two compose. This is the cheapest performance work
outstanding and it is also a bug report waiting to happen.

### 1.3 Cover images do not render on the map

`MapPartyPin` carries `coverPath` and `hasCover`, and `PartyRepository.
signedCoverUrls` exists and is used — but only by `ProfileScreen`. `MapPinSheet`
still draws a `DiagonalStripePlaceholder`, and so does the pin itself.

*Why it is still open:* covers went in for the profile's party list and were not
carried across; the map pin sheet predates them.

*What it costs to leave:* the payload is fetched and discarded on the busiest
screen. Note the pin thumbnail is a harder call than the sheet — a signed URL
per visible pin is up to 200 round trips, so the sheet is the cheap half and the
pin needs batching or a decision to stay a placeholder.

### 1.4 `fetchMyRsvps` is bounded at 200 with no pagination

It reads `rsvps` with an embedded `parties!inner(...)`, `order`s by
`created_at`, and `.limit(200)`.

> **Discrepancy worth resolving.** This was raised as *"`fetchAttendedParties`
> sorts in Dart with a limit of 50"*. That does not match the tree:
> `fetchAttendedParties` was **deleted** — `PartyRepository` says so in the
> `fetchMyHostedParties` doc comment, along with why (PostgREST's `order` on an
> embedded resource sorts *within* the embed, not the top-level rows). What
> remains is `fetchMyRsvps`, which is bounded at **200**, not 50, and does not
> sort in Dart. Either the memory is of the deleted method, or there is a third
> call site nobody has found. **Worth one look before anyone acts on this
> entry.**

*Why it is still open:* it feeds a personal list rather than an unbounded feed,
and 200 was judged enough.

*What it costs to leave:* a heavy user silently stops seeing their oldest RSVPs,
with no "load more" to explain it. This is the same shape as the failure the
search phase refused — a bound that quietly returns a subset — and it should be
either keyset-paginated (rule #5) or given a visible cap.

### 1.5 The "Διαχείριση" pill was removed and left no trace

*Not verifiable from the repository.* `grep` across `myparty/lib`, `docs/` and
`CLAUDE.md` finds no occurrence of the string, so there is nothing to say about
what it did, where it lived, or what replaced it.

*Why it is still open:* recorded here because it was raised, not because it
could be confirmed. **Needs a sentence from whoever removed it** — what it
controlled and whether the capability is reachable some other way — otherwise
this entry cannot be actioned or closed.

### 1.6 gotcha 21 — `ends_at` on the map

Open since Phase 2. Search now has a definition (`public.party_is_past()`); the
map still shows a party with a null `ends_at` forever. Costed in §2 below —
short version: the *definition* is now free to adopt, the *number* is not.

### 1.7 `mp_store.dart` still backs three surfaces

`hype`, `interested` and the const `mpParties` list. `PartyCard` and
`PartyDetailSheet` read from it rather than Supabase, which is why that sheet's
"Group chat" button and its story tiles are placeholders — it has string keys
like `'taratsa'`, not uuids, so it has nothing to hand `ChatScreen` or
`StoryViewerScreen`.

*Why it is still open:* each surface needs its own phase; Phase 8 and Phase 11
took two pieces out already.

*What it costs to leave:* two real features look broken on a screen that
otherwise looks finished.

### 1.8 `auth_leaked_password_protection` is off

From the Phase 10 audit: an Auth **dashboard toggle**, not schema. No migration
can set it.

*Why it is still open:* it is a click, and it is not ours to make.

*What it costs to leave:* known-breached passwords are accepted at signup. Worth
doing before launch.

---

## 2. Costed: should the map adopt `party_is_past()`?

Raised 2026-08-22. **Measured, not estimated** — at 10k parties, authenticated,
through RLS, against the Phase 13 map query:

| variant | pins returned | exec |
|---|---|---|
| A — as shipped (`ends_at is null or ends_at > now()`) | 9,007 | 54.4 ms |
| B — `+ not party_is_past(...)` as it stands | 4,995 | 56.7 ms |
| C — the same rule written inline | 4,995 | 43.4 ms |

**The performance cost is not the problem.** B is ~4% slower than A; C is
*faster*, because it returns fewer rows. The function is `STABLE` with a `SET`
clause, so per gotcha 20 it can never be inlined and costs a real call per row —
about 13 ms over 10k rows, visible as the B/C gap. Dropping the `SET` clause
would recover it. Neither B nor C sorts ahead of the row policy, so neither
pre-filters; that is unchanged from today.

**The cost is semantic, and it is large.**

- **81% of parties have no `ends_at`** (22 of 27 seeded). The grace period would
  govern the majority of the map, not an edge case.
- In the measured set, **4,012 of 9,007 pins disappear** — 45%.
- **The 6-hour number was calibrated for the wrong job.** It was chosen for
  *grouping* in search, where being wrong moves a row one section down. Using it
  to *filter* the map makes being wrong destructive: an all-nighter that starts
  at 22:00 vanishes from the map at 04:00, while it is happening and while
  people are still trying to find it. That is precisely the failure gotcha 21
  says must not be guessed at, and sharing the *definition* does not make the
  *threshold* transferable.

**So: adopting it wholesale is cheap to run and wrong to do.** Three ways
forward, in increasing order of actually solving it:

1. Give `party_is_past` an explicit grace parameter with different defaults per
   surface — one definition, two calibrations, and the asymmetry becomes
   visible instead of implied. Cheap.
2. Same, but pick the map's number from data (how long do parties with a stated
   `ends_at` actually run?) rather than from intuition. That measurement does
   not exist yet.
3. **Require `ends_at` at party creation.** Then the grace never applies, both
   surfaces agree trivially, and gotcha 21 closes rather than moves. A migration
   plus a host-wizard field, and the only option that ends the problem.

Recommendation: **3**, with **1** as the interim if the map needs to stop
showing dead pins before the wizard changes. Do not take B or C as written.

---

## 3. NOT backlog — decisions that look like gaps

Here so they are not "fixed" by somebody reading §1 and pattern-matching.

- **`credibility_score` ships no score.** Decided, not pending. The column and
  its trigger stay, written and read by nothing. Do not invent a formula.
- **FCM is wired conditionally.** A handset with no Play Services can never get
  a token, so graceful degradation is correct *runtime* behaviour and the
  build-time conditional is the same fact expressed earlier.
- **`search_parties` is uncapped.** Deliberate: see
  `phase-14-text-search.md` §5b. Bounding it in SQL means silently returning a
  subset. The 3-character minimum in `SearchScreen` is the agreed answer.
- **Search is prefix, not infix.** `εχν` will not find `Τεχνο`. Accepted.
- **`Πειραιάς` does not match `Piraeus`.** An English exonym, not greeklish; no
  character mapping reaches it. Asserted as a known state.
- **`map_visibility` does not filter search.** It answers "do I want to be a
  pin", not "do I want to be unfindable". A separate control would get its own
  column.
- **`parties_location` reads as an unused index.** It is reached by the
  notification engine, which is `SECURITY DEFINER`. Do not drop it.
- **`spatial_ref_sys` has RLS off.** Cannot be fixed from a migration —
  `supabase_admin` owns it. Allowlisted by name in `13_hardening.test.sql`.
