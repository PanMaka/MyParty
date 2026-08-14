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

State today: `profiles`, `parties`, `invitations` exist with RLS and a single
RPC, `get_parties_near_user`, that the map screen calls live. Everything else
in the Flutter app — rsvps/interest, likes, chat, stories, the follow list
and follow state, map-visibility toggle — is in-memory mock state in
`lib/state/mp_store.dart` or hardcoded const lists in `lib/models/`. Each
phase below replaces one slice of that mock state with a real table + RLS
policy + RPC and deletes the corresponding mock code.

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
   that needs that rule calls the helper. Phase 4 formalizes
   `can_access_party`; Phase 3's block check retrofits into every policy
   that existed before it, not just new ones.
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
  delete only for account/GDPR erasure (Phase 9).
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

## Phase 5 — Stories

`stories` (`party_id`, `author_id`, `media_path`, `expires_at`) +
`story_views`, visibility via `can_access_party`. Signed-URL upload into the
`story-media` bucket from Phase 0 — client never writes to the bucket
directly. `pg_cron` cleanup that both hides expired rows and deletes the
underlying storage objects (the object deletion is the part that gets
forgotten and then storage cost never stops growing). Server-side rate
limit: N stories/user/hour. Flutter: replace the const `mpStory` list and
`StoryViewerScreen`'s static frames.

## Phase 6 — Group chat

Built before Phase 5 (cheaper, no Storage dependency). `messages` table,
RLS gated on `can_access_party` from Phase 4 — do not reimplement the
visibility check. Realtime via **broadcast from database**, not
`postgres_changes`: `postgres_changes` re-evaluates RLS per subscriber per
event, which is the wrong scaling shape for a group chat channel — a
trigger on `messages` broadcasts to topic `party:{party_id}`, with RLS on
`realtime.messages` authorizing the topic instead. `last_read_at` per
`(user, party)` for unread counts. Keyset pagination on message history.
Flutter: replace `ChatScreen`'s local `_messages` list with the live
subscription, with reconnect + optimistic send. Verification bar: a
non-invitee must receive nothing — not the message, not even the broadcast
event.

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

Deliverables split across three sessions:

**7a Schema & retention** — `user_devices`, `sent_notifications`, GiST
indexes on both geography columns (verify `parties.location` already has
one from Phase 0's base schema), owner-only RLS on `user_devices`, the
retention rules above, pgTAP proving no-consent-no-row, cross-user-select
denied, and the 24h job actually clearing the column.

**7b Notification engine** — the two triggers + safety-net sweep from 7.1,
dedupe, quiet hours, per-user daily cap, per-user radius preference. Query
plans for both spatial queries must be shown, confirming GiST index usage.

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
matching index. Re-verify the parties↔invitations cross-table RLS under
pgTAP rather than manual reading. Rate limiting on all write paths (posts,
stories, messages, invites). Load test `get_parties_near_user` at 10k
parties / 50k rsvps (not the ~20 seeded), report p50/p95, identify what
breaks first.
