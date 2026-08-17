# MyParty — Backend Plan

Master design doc. `docs/MyParty-ClaudeCode-Prompts.md` runs sessions against
this file phase by phase — it does not restate the "why", only the "build
this now". When plan and reality disagree, fix the plan in its own PR before
building on top of it.

## 1. Επισκόπηση (Overview)

Flutter client + Supabase (Postgres 17 / PostGIS / Auth / Storage / Realtime /
Edge Functions). Local dev via Supabase CLI (`supabase/config.toml`).

Product shape: a map-first party app. Public parties are discoverable near a
user; private parties are invite-only and invisible to everyone else,
including on the map. Hosts create parties, invite the people they follow,
run a group chat and a story per party. Social graph (follows/blocks) gates
visibility everywhere.

State today: `profiles`, `parties`, `invitations`, `rsvps`, `follows`,
`blocks`, `party_posts`, `post_likes`, `post_comments` and `reports` exist
with RLS, alongside `get_parties_near_user`, `create_party_with_invites`,
`get_feed` and `get_post_comments`. What is still mock in the Flutter app —
hype, interest, invited, map-visibility in `lib/state/mp_store.dart`, and
the const `mpParties`/`mpStory`/`mpSeedTaratsaChat` lists in `lib/models/` —
feeds `ChatScreen`, `StoryViewerScreen`, `PartyCard` and
`PartyDetailSheet`. Each phase below replaces one slice of that mock state
with a real table + RLS policy + RPC and deletes the corresponding mock
code.

## 2. Ταυτότητα & Environment (Identity)

`AuthService` (`lib/services/auth_service.dart`) wraps
`supabase.auth.signUp/signInWithPassword/signOut` directly — no profile row
is ever created. `profiles.id` is a bare FK to `auth.users` with no default
and no trigger, so a fresh signup has an `auth.users` row and nothing in
`profiles`. Two consequences:

- `parties.host_id references public.profiles(id)` — a brand-new user cannot
  even host a party until a profile row exists, they'd hit an FK violation.
- `get_parties_near_user` inner-joins `parties` to `profiles` for
  `host_username` — any party whose host lacks a profile row silently
  disappears from every map query, no error, just missing pins.

Phase 1 fixes this with a `handle_new_user()` trigger on `auth.users` insert.
It must cover both email and OAuth signup (OAuth doesn't give you a chosen
username up front — coalesce over `raw_user_meta_data`), and the placeholder
username must be derived from the uuid, never from email or a numbered
sequence, because `profiles.username` is unique and collisions must be
structurally impossible, not just unlikely.

## 3. Κανόνες μηχανικής (Engineering rules — non-negotiable)

1. **RLS on every table**, enabled in the same migration that creates the
   table. No table ships "temporarily open."
2. **`(select auth.uid())`**, never bare `auth.uid()`, in every policy —
   the subquery lets Postgres cache it once per statement instead of
   re-evaluating per row.
3. **`set search_path = ''`** on every `security definer` function, with
   fully schema-qualified references (`public.profiles`, not `profiles`)
   inside it. Unqualified search_path on a definer function is a privilege-
   escalation vector.
4. **No duplicated visibility logic.** One helper per visibility rule
   (`can_access_party`, `is_blocked`, …), every policy and RPC
   that needs that rule calls the helper. `can_access_party` was extracted
   ahead of schedule in `20260812121153` (RLS recursion forced it) and made
   block-aware in `20260814094945`; Phase 3's block check retrofits into
   every policy that existed before it, not just new ones.

   Its signature is `can_access_party(p_party_id)` — caller-implicit, not
   the `(p_party_id, p_user_id)` this document originally specified. Nothing
   in Phases 4–6 asks about a user other than the caller, and a public
   two-arg `security definer` form would let anyone probe a private party's
   guest list. If Phase 7's background enqueue needs to ask on behalf of
   another user, it adds the two-arg form with the one-arg redefined as a
   thin wrapper (still one implementation) and `execute` revoked from
   `authenticated`.
5. **Keyset pagination, never offset** — `where (created_at, id) < (?, ?)
   order by created_at desc, id desc limit N`, with a matching composite
   index. Applies to feed, chat history, any list that grows unbounded.
6. **Denormalized counters via trigger**, never `count(*)` at read time —
   `going_count`, `interested_count`, `like_count`, `comment_count` are all
   columns maintained by an `after insert/update/delete` trigger on the
   table being counted.

Additional rules that fall out of the phases below, kept here so they don't
get re-litigated per phase:

- **Migrations are additive only** once a branch merges to main — never edit
  a merged migration file, write a new one.
- **Storage is never written to directly by the client** for anything
  visibility-gated (`party-covers`, `post-media`, `story-media`) — signed
  URLs only, so bucket access follows the same rule as the row it belongs to.
- **Soft-delete for UGC** (`hidden_at`/`hidden_by`/`hidden_reason`), hard
  delete only for account/GDPR erasure (Phase 9). **The write is a
  `security definer` RPC, never an UPDATE policy** — Phase 4 found out why
  and Phases 5/6 will hit the same wall: on UPDATE, Postgres applies the
  SELECT policy to the *new* row whenever the statement needs read access,
  so with `hidden_at is null` in that policy a client-side soft-delete
  always produces a row the client may no longer read and is rejected with
  "new row violates row-level security policy". No WITH CHECK expression
  fixes that. Doing the write in a definer function (`hide_post`,
  `hide_comment`) keeps "hidden means hidden, to every client role" as a
  flat invariant instead of a predicate with a moderator-shaped hole in it,
  and leaves the UGC tables with **no UPDATE grant on any column at all**.
- **Rate limits are enforced server-side**, never trusted from the client.

## 4. Migration naming convention

`YYYYMMDDHHMMSS_snake_case_description.sql`, inferred from the four existing
files (e.g. `20260709120643_RLS.sql`). Timestamp prefix from
`date +%Y%m%d%H%M%S` at creation time (or `supabase migration new <name>`,
which generates it automatically) — never hand-pick a timestamp, it's what
keeps ordering unambiguous across branches.

---

## Phase 0 — Foundations

Seed data (6 fixed-UUID personas, ~20 geo-varied parties around Athens/
Megara exercising the tier/zoom filter in `get_parties_near_user`), storage
buckets (`avatars` public-read, `party-covers`/`post-media` following party
visibility, `story-media` signed-URL-only), a pgTAP harness with a user-
impersonation helper, and CI running `supabase db reset` + pgTAP on every PR.
No Flutter changes. No existing migration is modified — new files only.

## Phase 1 — Identity & environment

See section 2 above for the bug this fixes. Deliverables: the
`handle_new_user()` trigger (security definer, `set search_path = ''`,
`on conflict (id) do nothing`), a backfill for existing `auth.users` rows,
`profiles.onboarding_completed_at` + consent flag columns (location, push,
analytics — created now, wired up in Phase 7), `check_username_available`
RPC + case-insensitive unique index, and a Flutter "choose your username"
step gated on `onboarding_completed_at is null`.

## Phase 2 — Party lifecycle

### 2.1 Invitations vs RSVPs

These are two different relations and Phase 2's main risk is collapsing
them. `invitations` (Phase 0) is host-controlled: it answers "is this
private party even visible to this person." `rsvps` is guest-controlled: it
answers "is this person going." An invitation does not imply an RSVP, and
an RSVP is meaningless on a private party without an invitation first — the
RLS on `rsvps` insert must enforce that: public party → anyone may insert
their own rsvp; private party → insert requires an existing row in
`invitations` for that (party, guest). Enforced in the policy, not the
client.

Deliverables: `rsvps` (composite PK `(party_id, user_id)`, enum status
`interested|going`), the RLS rule above, party lifecycle columns (`status`
enum, `starts_at`, `ends_at`, `going_count`, `interested_count`), a trigger
maintaining the two counters (insert/update-status-change/delete — the
interested→going transition is the one to get right),
`get_parties_near_user` updated to filter on `status = 'published'` and
non-expired, and to return `my_rsvp_status`/`going_count`/`is_invited`
without touching the existing tier/zoom filtering, and
`create_party_with_invites(p_party jsonb, p_invitee_ids uuid[])` as one
transaction, security invoker.

Flutter half: `HostWizardScreen._next()` calls the RPC instead of
navigating to a no-op done screen; Events "ΔΙΚΑ ΜΟΥ" tab reads `rsvps`
instead of `MpStore._interested`; introduce `lib/data/party_repository.dart`
as the first repository — every later phase reuses this shape instead of
calling Supabase from widgets directly.

## Phase 3 — Social graph & blocks

### 3.1 Follows only — why there is no `friendships` table

**This section was reversed during the Phase 3 session and the schema
follows the decision below, not the original argument. Do not "restore" a
`friendships` table in a later phase without an explicit decision to change
product direction.**

The original plan called for `follows` *and* `friendships` as
non-interchangeable tables: asymmetric following for venue/host accounts,
plus a symmetric mutual friendship that granted private-party visibility.
That was rejected in favour of an **Instagram-shaped graph**: `follows` is
one-directional, asymmetric, needs no reciprocity, and is the entire social
graph. There is no `friendships` table, no request/accept flow, and no
`are_friends()` helper.

What this buys: one table instead of two, no accept-state machine, no
ambiguity about whether a mutual follow "is" a friendship. What it costs:
there is no mutual-only visibility tier, so any feature that wants one has
to define it in follow terms and say so explicitly.

The load-bearing consequence: **a follow grants no private-party visibility
whatsoever.** Private-party access comes from `invitations` and nothing
else. Following someone means you see their public activity and they appear
in your invite picker when *you* host — it never means you can see their
private parties. This is stricter than the original friendship rule and is
what keeps the privacy model unchanged from Phase 0.

Deliverables: `follows`, `blocks` + `is_blocked(a, b)` (symmetric — one call
answers both directions). Denormalized `follower_count`/`following_count` on
`profiles` via trigger. Blocking deletes the follow edges both ways and the
`follows` INSERT policy prevents re-following until the block is lifted.

The critical part: retrofit `is_blocked` into every existing policy on
`parties`, `invitations`, and `profiles` — not just new tables — so a block
means the blocked party's parties disappear from the blocker's map, they
can't be invited, and neither shows up in the other's search. List every
existing policy and mark which ones change before editing any of them.

Flutter half: replace the const `mpFriends` list and the host wizard's
static friend picker with real queries; replace `MpStore.toggleFollow`.

## Phase 4 — Feed, reactions & reports

`can_access_party(p_party_id)` already exists (`20260812121153`, with the
block check added in Phase 3) — this phase does not create it, it **widens
it to `can_access_party(p_party_id, p_user_id)`**, because a feed RPC
evaluates visibility for a given user rather than always `auth.uid()`.

Do this first, before adding anything new, and mind the trap: adding a
second parameter creates an *overload*, it does not replace the existing
function. The `parties` SELECT policy would keep calling the one-argument
version, leaving the block logic living in two places — a violation of rule
4, which is the very rule this phase invokes. The one-argument version must
become a thin wrapper that delegates to the two-argument one, so there stays
exactly one implementation. Phases 5 and 6 reuse the same helper.

Deliverables: `party_posts`, `post_likes`, `post_comments` (denormalized
`like_count`/`comment_count` via trigger, soft-delete columns on all
three), a feed RPC (posts from parties hosted by people the user follows,
plus parties they attended or were invited to — you follow *users*, not
parties — gated by `can_access_party`, keyset pagination on
`(created_at, id)`), `reports` table (no admin UI needed yet — soft-delete
via SQL is enough for v1). Flutter: replace the hardcoded `_KapsimoCard` and
`MpStore._likes`; add a report action to every UGC surface.
**Done.** Step one of this phase — extract `can_access_party` and refactor
the `parties` SELECT policy onto it — turned out to be already done:
`20260812121153` extracted it (RLS recursion between the `parties` and
`invitations` policies forced the issue in Phase 2) and `20260814094945`
folded the block check into it. The policy has read `using
(can_access_party(id))` ever since, so there was nothing to refactor. See
rule 4 in §3 for why the signature stayed one-arg.

Shipped: `party_posts`, `post_likes`, `post_comments` (denormalized
`like_count`/`comment_count` via trigger, soft-delete columns on all three,
and hidden rows leave the counters as well as the SELECT policies —
`20260814112530`); `get_feed`, keyset on `(created_at, id)` against a
matching partial index (`20260814112531`); `reports` with a
one-report-per-target unique index doing the rate limiting
(`20260814112532`); `get_post_comments`, keyset for the same reason the feed
is (`20260814114721`). Flutter: `FeedRepository`, `FeedScreen` now paging
`get_feed`, `FeedPostCard` replacing `_KapsimoCard`, a comments sheet, and a
shared `showReportSheet` wired into posts, comments, map-pin parties and
real profiles.

Three things worth carrying forward:

- **`get_feed` is invoker-rights, deliberately.** That is what makes "gated
  by `can_access_party`" true rather than restated — the `party_posts`
  SELECT policy does the filtering. Its WHERE clause only *narrows* (which
  of the parties I can already see do I care about) and can never widen.
- **`can_access_party` only knows the party's HOST.** Every UGC table needs
  its own `is_blocked` check on the AUTHOR too: a blocked user can have
  posted on a public party hosted by a third party. Phases 5 and 6 must
  repeat this, not assume the helper covers it.
- **`execute` is revoked from `anon` on `get_feed`.** Table privileges are
  checked whether or not a WHERE clause could be true, so an anonymous
  caller otherwise gets "permission denied for table rsvps" — a confusing
  error that also advertises the query's internals.

One product note: the party card's like pill was removed rather than
re-pointed. Likes belong to a post (`post_likes`); there is no
`parties.like_count` in the schema and no phase that adds one, so it was a
counter that could only ever stay mock.

## Phase 5 — Stories

Built after Phase 6. **Shipped.**

`stories` (`party_id`, `author_id`, `media_path`, `expires_at`) +
`story_views`, visibility via `can_access_party` — plus its own `is_blocked`
check on `author_id`, which the helper does not cover (see Phase 4). The
`pg_cron` cleanup below hides rows, so it needs the definer-RPC soft-delete
shape from Phase 4, not an UPDATE policy. Signed-URL upload into the
`story-media` bucket from Phase 0 — client never writes to the bucket
directly. `pg_cron` cleanup that both hides expired rows and deletes the
underlying storage objects (the object deletion is the part that gets
forgotten and then storage cost never stops growing). Server-side rate
limit: N stories/user/hour, shipped as **10**, with a **24h** TTL. Flutter:
replace the const `mpStory` list and `StoryViewerScreen`'s static frames.

Six decisions made during implementation that this section did not anticipate:

1. **Stories use the WIDE `can_access_party`, not `can_chat_in_party`.** This
   is the mirror image of the §6 correction and it is worth stating so the two
   do not get "harmonised" later. Chat narrowed to participants because a
   writable room open to the whole user base is a spam surface. A story is
   read-only content attached to a party, so the passer-by who may look at the
   party may watch its reel. Posting is gated by the same wide helper — you
   must at least be able to *see* the party — plus the rate limit.

2. **Expiry is enforced by the SELECT policy (`expires_at > now()`), not by
   the cron job.** The job's only responsibility is collecting storage. A
   pg_cron outage must cost bucket bytes, never a story that outstays its 24
   hours, and a design where the sweep is what makes a story disappear gets
   that backwards.

3. **The row exists before the object does, and every object has a row.** The
   upload is a four-step handshake — insert (RLS + rate limit + trigger-derived
   `media_path`), `story_upload_target` → signed URL, PUT, then
   `confirm_story_upload`, which checks `storage.objects` before making the row
   visible. That ordering is what makes the purge complete by construction: an
   object with no row would be invisible to the cleanup and paid for forever.
   A crash mid-handshake leaves a row that never became visible, which the
   same job collects as `abandoned` after an hour.

4. **`insert … returning` cannot work here** — RETURNING is a read and goes
   through the SELECT policy, which hides unconfirmed rows. Hence the definer
   `story_upload_target` rather than returning `media_path` from the insert.
   Recorded as gotcha #6 in CLAUDE.md.

5. **`delete from storage.objects` does not delete the object** — it is the
   metadata table, and deleting the row orphans the file where nothing can
   ever enumerate it again. The purge sends a real
   `DELETE /storage/v1/object/story-media` over pg_net with a service key from
   Vault, records the request in `story_media_purges`, and sets
   `media_deleted_at` only after reading the HTTP response back. Gotcha #7.

6. **The proof is a script, not pgTAP.** pg_net dispatches only after COMMIT
   and every pgTAP file ends in a rollback, so the suite can prove the DELETE
   was queued and no more. `scripts/verify_story_lifecycle.sh` runs the real
   path end to end and asserts both the `storage.objects` row and the file on
   the storage container's disk are gone — the second assertion being the one
   that distinguishes a working purge from a convincing-looking one.

## Phase 6 — Group chat

Built before Phase 5 (cheaper, no Storage dependency). **Shipped.**

`messages` table, gated on a new `can_chat_in_party` helper that **composes**
`can_access_party` rather than reimplementing it — and deliberately narrows
it. This is a correction to what this section originally said ("RLS gated on
the existing `can_access_party` helper"), made during implementation:
`can_access_party` is true for *any* signed-in user on a public party,
because reading is a fine thing to hand out that broadly. A writable group
chat is not. Applied as-is it would have made every public party's chat a
room the entire user base can post in, with no moderation story behind it.
So chat additionally requires participation — host, invited, or RSVP'd
(either status; an `interested` RSVP counts, the same call `get_feed` makes).
The composition means privacy, the invitation check and both directions of
the host block all still live in `can_access_party` alone; the extra `and`
can only ever remove people.

`can_access_party` still says nothing about the message *author*, so
`messages` carries its own `is_blocked` term on `author_id` the way
`party_posts` does.

Realtime via **broadcast from database**, not `postgres_changes`:
`postgres_changes` re-evaluates RLS per subscriber per event, which is the
wrong scaling shape for a group chat channel — a trigger on `messages`
broadcasts to topic `party:{party_id}`, with RLS on `realtime.messages`
authorizing the topic instead, once at subscribe time. That policy calls the
same `can_chat_in_party`, so "who may join the channel" and "who may read the
history" cannot drift apart. `realtime.messages` gets **no INSERT policy**,
deliberately: the trigger is the only writer, so a participant cannot forge a
broadcast that skips the rate limit and leaves nothing for `hide_message` to
take down. A second trigger broadcasts `message_hidden` on soft-delete, or a
moderated line keeps rendering on every phone already in the chat.

`party_reads.last_read_at` per `(user, party)` for unread counts, clamped by
trigger to be monotonic and never future-dated. Unread is the one read-time
count in the schema — it cannot be denormalized because it is per-viewer — so
it is bounded instead, counted over a `limit 100` subquery and rendered
`99+`. Keyset pagination on message history.

Flutter: `ChatScreen`'s local `_messages` list replaced by the live
subscription, with reconnect gap-fill (broadcast has no replay, so
reconnecting means refetching what was missed, not resuming) and optimistic
send under a client-generated uuid. `MessagesScreen` became the real chat
list. Verification bar, asserted in `06_group_chat.test.sql` at both layers:
a non-invitee must receive nothing — not the message row, and not the
broadcast event, because the topic join itself is refused. Two-device
delivery plan in `docs/phase-06-manual-test.md`.

## Phase 7 — Proximity & push

### 7.1 Event-driven notification design

The design is event-driven, not a scheduled cross-join. A periodic
`user_devices × parties` spatial join is O(users × parties) per run even
when nothing changed — it does not scale and most runs do zero useful work.
Instead: a trigger on party publish finds users near that one party (single
GiST-indexed spatial query) and enqueues jobs; a trigger on user location
update finds parties near that one user, debounced to re-evaluate only past
some movement threshold. A periodic hourly sweep exists only as a safety
net for anything missed by the two triggers — it is never the primary
mechanism. Every enqueue dedupes against `sent_notifications` on
`(user, party, kind)`.

### 7.2 GDPR retention

Highest compliance risk in the project. Rules, all enforced in policy/
functions, not just documented:

- Insert into `user_devices.last_location` only when
  `profiles.location_consent = true` — enforced in the RLS policy itself.
- Coordinates are rounded to ~100m **before** storing, via a function
  applied in the upsert path — raw precise coordinates never touch disk.
- Last value only. No location history table, ever.
- `pg_cron` job nulls `last_location` older than 24h.
- Retention elsewhere: `sent_notifications` 90 days, ended parties kept
  indefinitely (documented fully in Phase 9).

Four refinements settled while building 7a, all shipped in
`20260816083807` / `20260816083809`:

- **The consent gate is on the location, not on the row.** A device may
  register a push token with `location_consent = false` and no
  `last_location` — push consent (`profiles.push_consent`) is a separate
  act, and conflating them would make "notify me when someone invites me"
  unavailable to anyone who declines background location. The policy reads
  `last_location is null or has_location_consent(...)`, and it is repeated
  in the UPDATE `with check` as well as the INSERT one: a row inserted
  location-free while consent is false and then updated with a location is
  the same violation through a door nobody checked.
- **Rounding is a `before insert or update` trigger, not just the RPC.**
  An RPC is the path the client takes; a trigger is the path every writer
  takes, including later migrations and psql. "Raw coordinates never touch
  disk" is only true if it is impossible.
- **Withdrawing consent clears what consent bought.** A trigger on
  `profiles.location_consent` true→false nulls every stored location for
  that user immediately (GDPR Art. 7(3)); waiting for the 24h sweep would
  leave an off toggle next to a live coordinate that 7b's proximity queries
  can still match. The device row and its push token survive — withdrawing
  location consent is not unsubscribing from push.
- **The sweep runs `*/10`, not hourly.** Worst-case retention is 24h + the
  sweep interval, so an hourly job makes a documented 24-hour retention
  period measurably 25 hours. This is the one cron in the schema with no
  independent enforcement behind it: Phase 5's expiry is backstopped by the
  `stories` SELECT policy, but no policy can make bytes stop existing, so
  the retention promise is exactly as good as this job's uptime.

Deliverables split across three sessions:

**7a Schema & retention** — `user_devices`, `sent_notifications`, GiST
indexes on both geography columns (verify `parties.location` already has
one from Phase 0's base schema), owner-only RLS on `user_devices`, the
retention rules above, pgTAP proving no-consent-no-row, cross-user-select
denied, and the 24h job actually clearing the column.

**7b Notification engine** — shipped in `20260817073507` /
`20260817073508` / `20260817073509`. The two triggers + hourly safety-net
sweep from 7.1, dedupe, quiet hours, per-user daily cap, per-user radius
preference; `notification_jobs` as the outbox 7c drains. Five things were
settled while building it:

- **A per-user radius cannot drive a GiST index scan.** When the radius
  comes from the row being spatially scanned, PostGIS has no constant to
  expand the search box by and the planner demotes the whole predicate to
  a join filter — `Seq Scan`, at 86ms/61k buffers against 6ms/7k for the
  fixed form. So every spatial predicate in the engine is written twice:
  a constant `st_dwithin(…, 5000)` that is indexable and bounds the box,
  plus the exact `st_dwithin(…, pr.notify_radius_meters)` that is the
  real rule. Neither may be "simplified" away — dropping the constant
  loses the index, dropping the exact term silently gives everyone a 5km
  radius. The 5000 literal is the `CHECK` cap on
  `profiles.notify_radius_meters`, so raising the cap means editing both
  in the same commit. `scripts/explain_proximity.sh` prints both plans at
  ~20k devices / 5k parties plus the seq-scanning control.
- **`can_access_party` answers about the caller, which the engine is not.**
  Its body moved into `can_user_access_party(p_user_id, p_party_id)` and
  the original became a one-line delegation bound to `auth.uid()`. One
  implementation, two entry points — the alternative was a second copy of
  the private-party rule in the code path that fans out to thousands of
  users at once. All 227 pre-existing tests passed unchanged, which is
  the only check that matters for a refactor under half the schema's
  policies.
- **Quiet hours defer; they do not suppress.** The dedupe row is claimed
  immediately and the *job* is scheduled for the window's end, so the
  sweep stays a pure safety net instead of becoming the primary path for
  every overnight party. Jobs carry `expires_at = starts_at`, because an
  08:00 push about a party that ended at 02:00 is worse than silence.
- **The daily cap deliberately does NOT claim the dedupe row**, unlike
  quiet hours. A capped notification is "not today", not "never", so the
  slot has to survive for tomorrow's sweep. The cap is also soft — read
  before the claim — because making it hard would need a per-user lock on
  the hot path of every publish.
- **The movement debounce needed no second geography column.** 7a already
  rounds to a ~100m cell and only restamps when the cell changes, so
  `old.last_location is distinct from new.last_location` *is* "moved
  ~100m"; a `last_evaluated_at` floor handles boundary flip-flop. Storing
  a `last_evaluated_location` would have doubled the location data under
  retention and broken the "exactly two geography columns" assertion — a
  bad trade in the one place where data minimisation is the point.

**7c Delivery & client** — Edge Function (TypeScript) consuming the job
queue via FCM HTTP v1 with backoff retry, deleting the device row on an
invalid-token response, structured logging. Flutter: capture FCM/APNs
token, request background location permission, upsert `user_devices`, an
in-app explanation of what's collected and why shown **before** the OS
permission prompt (compliance requirement, not UX polish), and graceful
handling of denied/revoked permission. Target: a new party within 500m
produces a notification in under 60s, no duplicates, quiet hours respected.

## Phase 8 — Profile wiring

`profiles.map_visibility` and `profiles.invite_policy`, enforced in
policies — `invite_policy` inside the `invitations` insert policy,
`map_visibility` inside `get_parties_near_user` — never only checked
client-side, a UI toggle with no server enforcement is privacy theatre.

Both tiers must be expressed in follow terms, since 3.1 removed the
friendship concept: `map_visibility` as public / followers / private, and
`invite_policy` as anyone / only people I follow. The exact tier names are
a decision for this phase — Phase 3 only removed the dead `friends`
vocabulary, it did not settle what replaces it.
Wire the "ΙΔΙΩΤΙΚΟΤΗΤΑ" toggles to these columns, replacing
`MpStore.mapVisible`. Stats tiles become an aggregate RPC over
`rsvps`/`parties`/`stories` — measure it against seeded data; if slow,
counter columns are the fallback, propose the tradeoff rather than assuming
it.

`credibility_score` already has a `protect_credibility_score` trigger
(nothing may write it except the system) but nothing defines what *should*
write it — no formula is decided yet. This phase lists the option space
(host reliability, RSVP follow-through, report history, …) with tradeoffs;
a v1 formula is a decision for that session, not something to invent here.

## Phase 9 — Compliance

Soft-delete (`profiles.deleted_at`, 30-day grace) then hard delete via Edge
Function (auth user + storage objects + cascades). In-app deletion entry
point (App Store requirement wherever accounts can be created). Data export
Edge Function (JSON: profile, parties, rsvps, posts, messages). Before
writing any migration: audit every FK and classify cascade / set-null /
anonymize per table — group-chat messages from a deleted user should very
likely read as "Διαγραμμένος χρήστης" rather than vanish and break the
thread, but this needs an explicit table-by-table decision, not an assumed
default. Retention to document: locations 24h (from 7.2), sent_notifications
90d, ended parties indefinite.

## Phase 10 — Hardening

Run `get_advisors` (Supabase MCP) for security/performance lint and fix
everything actionable, listing anything deliberately left with why. Index
audit: every FK used in a join, every policy with a subquery, needs a
matching index.

**Revoke the default ACL project-wide.** Supabase ships
`alter default privileges in schema public` granting `anon`,
`authenticated` and `service_role` TRUNCATE, REFERENCES, TRIGGER and
MAINTAIN on every table created in `public`. None of those is a data
privilege, so nothing is readable and no RLS policy is bypassed — but RLS
does not mediate TRUNCATE, so on paper `anon` can empty any table in the
schema. PostgREST exposes no route to it, which is why this is hardening
and not an incident. 7a revoked it on `user_devices` and
`sent_notifications` (`20260816083807`); every table created before that
still carries it, and the fix is one migration plus an
`alter default privileges ... revoke` so new tables stop inheriting it. Re-verify the parties↔invitations cross-table RLS under
pgTAP rather than manual reading. Rate limiting on all write paths (posts,
stories, messages, invites). Load test `get_parties_near_user` at 10k
parties / 50k rsvps (not the ~20 seeded), report p50/p95, identify what
breaks first.
