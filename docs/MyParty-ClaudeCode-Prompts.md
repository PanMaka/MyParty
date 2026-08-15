# MyParty — Claude Code Prompts (phase by phase)

## Πριν ξεκινήσεις

1. Βάλε το plan στο repo: `docs/backend-plan.md`. Όλα τα prompts παρακάτω το αναφέρουν.
2. Τρέξε πρώτα το **Prompt 00** (bootstrap). Δημιουργεί το `CLAUDE.md`, που είναι το πιο σημαντικό αρχείο για vibe coding — φορτώνεται αυτόματα σε κάθε session και σου γλιτώνει το να ξαναεξηγείς τους κανόνες.
3. **Μία φάση = ένα session = ένα branch = ένα PR.** Μη βάζεις δύο φάσεις στο ίδιο session· το context γεμίζει και η ποιότητα πέφτει απότομα.
4. Ξεκίνα κάθε φάση σε **plan mode** (`Shift+Tab` δύο φορές). Διάβασε το plan που βγάζει, διόρθωσέ το, μετά άσ' το να γράψει.
5. `/clear` μεταξύ φάσεων. `/compact` αν μια φάση τραβήξει πολύ.

---

## Prompt 00 — Bootstrap (τρέξε το μία φορά)

```
Read docs/backend-plan.md, then explore the repo: supabase/migrations/,
supabase/config.toml, lib/ (especially mp_store.dart, the model files,
AuthService, MapScreen, HostWizardScreen, ChatScreen, StoryViewerScreen).

Then write a CLAUDE.md at the repo root that captures the working rules
for this project so future sessions don't need re-explaining. It must include:

1. Project shape: Flutter client + Supabase (Postgres/PostGIS/Auth/Storage/
   Realtime/Edge Functions). Which parts are real vs mock today.
2. Migration naming convention, inferred from the existing files.
3. The non-negotiable engineering rules from docs/backend-plan.md section
   "Κανόνες μηχανικής" — RLS on every table, `(select auth.uid())` pattern,
   `set search_path = ''` on every security definer function, no duplicated
   visibility logic (use helpers), keyset pagination never offset,
   denormalized counters via trigger.
4. Commands: how to reset the local DB, run migrations, run tests.
5. A short "how we work" section: one phase per branch, migrations are
   append-only once pushed, every new table ships with pgTAP tests.

Keep it under 100 lines. Dense, no filler. Do not write any migrations yet.
```

Μετά: διάβασέ το, διόρθωσε ό,τι κατάλαβε λάθος,Μην το κανεις  commit απλα πες ,ου τισ εντολες να το κανω εγω commit.

---

## Phase 0 — Foundations

```
Task: Phase 0 (Foundations) from docs/backend-plan.md.

Read docs/backend-plan.md Phase 0 and the existing supabase/ directory first.

Deliverables:
1. supabase/seed.sql with:
   - 6 profiles matching the test personas: host, invitee,
     friend_not_invited, stranger, blocked_user, second_host.
     Use fixed, readable UUIDs so tests can reference them by constant.
   - ~20 parties with real coordinates around Athens and Megara at varied
     distances (some within 500m of each other, some 10km+ apart), a mix of
     public/private/sponsored, a mix of party_tier values, so the tier-based
     zoom filtering in get_parties_near_user is actually exercised.
   - invitations wiring invitee to the private parties.
2. Storage buckets + policies, as a migration: avatars (public read,
   owner write), party-covers, post-media, story-media (signed URLs only).
   party-covers and post-media read access must follow the same visibility
   rule as the party they belong to.
3. A pgTAP harness under supabase/tests/:
   - a helper to impersonate a user (set request.jwt.claims / auth.uid)
   - one smoke test proving the harness works against the EXISTING policies
     on profiles, parties, invitations — both a positive and a negative
     assertion (stranger must NOT see a private party).
4. A CI workflow (.github/workflows/) that runs supabase db reset,
   applies migrations, and runs the pgTAP suite on every PR.

Constraints:
- Do not modify any existing migration file. New files only.
- Do not touch Flutter code in this phase.

When done: run the full reset + test cycle yourself and show me the output.
Then tell me exactly what I need to fill into .env and where to get it.
```

**Checkpoint:** μη προχωρήσεις αν το `supabase db reset` + tests δεν είναι πράσινα.

---

## Phase 1 — Identity & environment

```
Task: Phase 1 (Identity) from docs/backend-plan.md.

This fixes the blocking issue in section 2 of the plan: signup does not
create a profile row, so get_parties_near_user silently excludes that
user's parties.

Read docs/backend-plan.md sections 2 and Phase 1, plus lib/'s AuthService
and AuthGate, before writing anything.

Deliverables:
1. Migration ..._profile_on_signup.sql:
   - handle_new_user() trigger on auth.users, security definer,
     set search_path = ''
   - placeholder username derived from the uuid so it is GUARANTEED unique
     (never an email prefix or a numbered pattern that can collide with the
     unique constraint) — if this trigger raises, signup fails with an
     opaque 500
   - must handle OAuth signups too: coalesce over raw_user_meta_data
     full_name / name / email prefix
   - on conflict (id) do nothing as a safety net
2. Backfill: create profiles for any existing auth.users without one.
3. profiles.onboarding_completed_at column, so the client knows when to show
   the "choose a username" step without string-matching the placeholder.
4. Consent flag columns on profiles (location, push, analytics) — they are
   created now and used in Phase 7.
5. check_username_available(text) RPC + a case-insensitive unique index on
   username.
6. Flutter: an optional post-signup "choose your username" screen, gated on
   onboarding_completed_at being null. Wire it into the AuthGate flow.
7. pgTAP: assert no auth.users row can exist without a matching profile.

Verification I want to see before you say you're done:
- signup via email produces a profile row
- signup via OAuth produces a profile row (simulate the raw_user_meta_data
  shape if you can't do a real OAuth round trip)
- the new user's own parties appear in get_parties_near_user
```

---

## Phase 2 — Party lifecycle

Χώρισέ το σε δύο sessions — είναι η μεγαλύτερη φάση.

### 2a — Schema

```
Task: Phase 2 (Party lifecycle), database half. From docs/backend-plan.md.

Read Phase 2 in the plan carefully — especially 2.1, the invitations vs
rsvps split. Getting that boundary wrong is the main risk here.

Deliverables:
1. rsvps table exactly as specified in the plan (composite PK, enum status).
2. RLS on rsvps enforcing the rule from 2.1: on a PUBLIC party anyone may
   insert their own rsvp; on a PRIVATE party an rsvp requires an existing
   invitation. Enforced in the policy, not in the client.
3. Party lifecycle columns: status enum, starts_at, ends_at, going_count,
   interested_count.
4. Trigger on rsvps maintaining going_count / interested_count. Handle
   insert, update (status change), and delete. Do NOT compute these with
   count() at read time.
5. Update get_parties_near_user to filter
   status = 'published' and (ends_at is null or ends_at > now()),
   and to additionally return my_rsvp_status, going_count, is_invited.
   Keep the existing tier-based zoom filtering exactly as it is.
6. create_party_with_invites(p_party jsonb, p_invitee_ids uuid[]) RPC,
   security invoker, inserting the party and its invitations in ONE
   transaction.
7. pgTAP for all of the above, including the negative case: a stranger
   cannot rsvp to a private party.

Before writing: tell me how you plan to handle the counter trigger for the
update case (interested -> going), and wait for my go-ahead.
```

### 2b — Client

```
Task: Phase 2, Flutter half.

1. HostWizardScreen._next() on the final step: call create_party_with_invites
   instead of navigating to a "done" screen with no persistence. Handle
   loading and error states properly — this is the first real write path in
   the app, so whatever pattern you establish here I will reuse everywhere.
2. Events screen "ΔΙΚΑ ΜΟΥ" tab: read from rsvps instead of
   MpStore._interested.
3. Delete the mock state you replaced from mp_store.dart. Do not leave dead
   code behind.
4. Introduce a repository layer (e.g. lib/data/party_repository.dart) rather
   than calling Supabase directly from widgets — every later phase will
   follow this same shape.

Show me a diff summary of what shrank in mp_store.dart.
```

---

## Phase 3 — Social graph & blocks

```
Task: Phase 3 (Social graph & blocks) from docs/backend-plan.md.

Deliverables:
1. follows table only — asymmetric, Instagram-style, no reciprocity. There
   is deliberately NO friendships table and no are_friends helper; read 3.1
   for why, including the note that 3.1 was reversed on purpose.
2. Denormalized follower_count / following_count on profiles via trigger.
3. blocks table + is_blocked(a, b) helper, symmetric in both directions.
   Blocking must delete the follow edges both ways and prevent re-following
   until the block is lifted.
4. THE CRITICAL PART: retrofit is_blocked into the EXISTING policies on
   parties, invitations and profiles — not just the new tables. A block must
   mean: I don't see their parties on the map, they can't invite me, we
   don't appear in each other's search. Go through every existing policy one
   by one and tell me which ones you changed and why.
5. RLS: follow edges and follow counts public, with blocked pairs filtered
   out of both. Blocks readable only by the blocker — the blocked user must
   never be able to enumerate who blocked them.
6. Flutter: replace the const mpFriends list and the host wizard's static
   friend picker with real queries (the picker lists who you follow, and
   must finally pass real uuids to create_party_with_invites — it has been
   sending an empty array). Replace MpStore.toggleFollow.
7. pgTAP with a blocked persona asserted against EVERY policy that exists at
   this point, including the ones from Phases 0, 1 and 2. Phase 1 ships in
   the same batch as this phase, so check its helpers too — anything that
   reads public.profiles without security definer now runs under the
   narrowed, block-filtered SELECT policy and may quietly return the wrong
   answer.

Start by listing every existing RLS policy in the repo and marking which
ones need the block check. Show me that list before you edit anything.
```

---

## Phase 4 — Feed, reactions & reports — DONE

Step 1 below turned out to be a no-op: `can_access_party` had already been
extracted in `20260812121153` and the `parties` policy already read
`using (can_access_party(id))`. The signature stayed one-arg — see rule 4 in
`docs/backend-plan.md` §3.

Shipped as `20260814112530` (tables + counters + `hide_post`/`hide_comment`),
`20260814112531` (`get_feed`), `20260814112532` (`reports`),
`20260814114721` (`get_post_comments`), and 33 pgTAP assertions in
`05_feed_posts_and_reports.test.sql`.

```
Task: Phase 4 (Feed, reactions & reports) from docs/backend-plan.md.

Deliverables:
1. First, WIDEN the existing can_access_party. It already exists as
   can_access_party(p_party_id) from 20260812121153 and already carries the
   Phase 3 block check — do NOT write it from scratch. It needs a second
   parameter, can_access_party(p_party_id, p_user_id), because the feed RPC
   evaluates visibility for a given user rather than always auth.uid().

   The trap: a second parameter creates an OVERLOAD, it does not replace the
   old function. The parties SELECT policy will keep calling the 1-arg
   version and you end up with the block logic in two places — exactly the
   rule 4 violation this step exists to prevent. Make the 1-arg version a
   thin wrapper delegating to the 2-arg one. One implementation, one place
   to change. Phases 5 and 6 reuse the same helper.
2. party_posts, post_likes, post_comments. Denormalized like_count and
   comment_count via trigger. Soft-delete columns (hidden_at, hidden_by,
   hidden_reason) on all three.
3. Feed RPC: posts from parties hosted by people the user FOLLOWS, plus
   parties they attended or were invited to. You follow users, not parties —
   the join goes through follows.followee_id = parties.host_id. Gated by
   can_access_party. KEYSET pagination on (created_at, id) with the matching
   composite index. Do not use offset.
1. First, extract can_access_party(p_party_id) as a helper and REFACTOR the
   existing parties RLS policy to use it. Do this before adding anything new
   — the feed must not reimplement the visibility rule, and Phases 5 and 6
   will reuse the same helper. One implementation, one place to change.
2. party_posts, post_likes, post_comments. Denormalized like_count and
   comment_count via trigger. Soft-delete columns (hidden_at, hidden_by,
   hidden_reason) on all three — and hiding a row must take it out of the
   counter too, not just out of the SELECT policy.
3. Feed RPC: posts from parties the user follows, attended, or was invited
   to — gated by can_access_party. KEYSET pagination on (created_at, id)
   with the matching composite index. Do not use offset.
4. reports table: reporter_id, target_type, target_id, reason, status,
   created_at. No admin UI needed — the table plus the ability to soft-delete
   via SQL is enough for now.
5. Flutter: replace the hardcoded _KapsimoCard and MpStore._likes. Add a
   report action to every UGC surface.
6. pgTAP: a post on a private party is invisible to a non-invitee; a blocked
   user's posts never appear in the feed.

Note: can_access_party only checks the party's HOST. Every UGC table needs
its own is_blocked check on the AUTHOR as well.

Do step 1 first and show me the refactor before continuing.
```

---

## Phase 6 — Group chat

> Ναι, το 6 πριν το 5. Το chat είναι φθηνότερο και δεν χρειάζεται Storage.

```
Task: Phase 6 (Group chat) from docs/backend-plan.md.

Deliverables:
1. messages table per the plan, RLS gated on can_access_party (the existing
   helper — do not reimplement the logic). It checks only the party's HOST,
   so messages also needs its own is_blocked term on the message author, the
   way party_posts does.
2. Realtime via BROADCAST FROM DATABASE, not postgres_changes. Read the
   Phase 6 section for why: postgres_changes evaluates RLS per subscriber
   per event, which is the wrong scaling shape for group chat. Implement a
   trigger on messages that broadcasts to topic party:{party_id}, with RLS
   on realtime.messages authorizing the topic.
3. Read state: last_read_at per (user, party), for unread counts.
4. Keyset pagination on message history.
5. Flutter: replace the local _messages list in ChatScreen with the live
   subscription. Handle reconnect and optimistic send.
6. pgTAP + a manual test plan for me to run on two devices.

Verification: a non-invitee must receive NOTHING — not the message, not even
the broadcast event. Show me how you verified that.
```

**Shipped. One deliberate departure from the prompt above:** deliverable 1
said to gate `messages` on `can_access_party`. It is gated on a new
`can_chat_in_party` that *composes* that helper and narrows it, because
`can_access_party` is true for every signed-in user on a public party — which
would have made each public party's chat writable by the whole user base.
Chat also requires host / invited / RSVP'd. See `docs/backend-plan.md` §6.

Verification landed as two layers in `supabase/tests/database/06_group_chat.test.sql`
(the message row, and the broadcast topic join, enforced by different
policies on different tables) plus the two-device delivery pass in
`docs/phase-06-manual-test.md`.

---

## Phase 5 — Stories

```
Task: Phase 5 (Stories) from docs/backend-plan.md.

Deliverables:
1. stories (party_id, author_id, media_path, expires_at) + story_views.
   Visibility via can_access_party, plus its own is_blocked check on
   author_id — the helper only covers the party's host.
2. Signed-URL upload flow into the story-media bucket created in Phase 0.
   The client must never write to the bucket directly.
3. pg_cron cleanup that BOTH hides expired rows AND deletes the underlying
   storage objects. The second half is routinely forgotten and then you pay
   storage forever — I want to see the object deletion explicitly. The hide
   half is a security definer RPC, not an UPDATE policy — see the
   soft-delete rule in backend-plan.md §3 for why a client-side one cannot
   work.
4. Rate limit: N stories per user per hour, enforced server-side.
5. Flutter: replace the const mpStory list and StoryViewerScreen's static
   frames.

Verification: upload, view, wait for expiry (or fake the clock), and prove
the storage object is actually gone — not just the row.
```

---

## Phase 7 — Proximity & push

Η βαρύτερη φάση. Χώρισέ τη σε τρία sessions.

### 7a — Schema & retention

```
Task: Phase 7 (Proximity & push), schema half. From docs/backend-plan.md.

Deliverables:
1. user_devices and sent_notifications tables per the plan.
2. GiST indexes on BOTH geography columns (user_devices.last_location and
   parties.location — verify the latter exists, add it if not).
3. RLS on user_devices: owner only, read and write. Nobody reads another
   user's location, ever.
4. GDPR retention per section 7.2, this is the highest compliance risk in
   the project:
   - insert only when location_consent = true (enforce in the policy)
   - round coordinates to ~100m BEFORE storing — write this as a function
     and apply it in the upsert path
   - last value only, never a history table
   - pg_cron job nulling last_location older than 24h
5. pgTAP proving: no consent means no stored location; another user cannot
   select my device row; the 24h job actually clears the column.
```

### 7b — Notification engine

```
Task: Phase 7, notification engine.

Read section 7.1 first. The design is EVENT-DRIVEN, not a scheduled
cross-join — a periodic user_devices × parties join is O(users × parties)
per run even when nothing changed.

Deliverables:
1. Trigger on party publish: find users near THAT ONE party (single spatial
   query, GiST index) and enqueue notification jobs.
2. On user location update: find parties near THAT ONE user. Debounced —
   only re-evaluate if they moved more than X metres since last evaluation.
3. Periodic sweep as a SAFETY NET ONLY (hourly, for anything missed). It
   must not be the primary mechanism.
4. Dedupe against sent_notifications — never a second notification for the
   same (user, party, kind).
5. Quiet hours, per-user daily cap, per-user radius preference.

Show me the query plans for both spatial queries and confirm the GiST
indexes are actually being used.
```

### 7c — Delivery & client

```
Task: Phase 7, delivery and client.

1. Edge Function (TypeScript) consuming the job queue, calling FCM HTTP v1.
   Retry with backoff. On invalid-token response, delete the device row.
   Structured logging throughout.
2. Flutter: capture FCM/APNs token, request background location permission,
   upsert into user_devices.
3. In-app explanation of what location data is collected and why, shown
   BEFORE the OS permission prompt. This is a compliance requirement, not
   a UX nicety.
4. Handle the permission-denied and permission-revoked paths gracefully.

Target: new party within 500m produces a notification in under 60s, no
duplicates, quiet hours respected.
```

---

## Phase 8 — Profile wiring

```
Task: Phase 8 (Profile screen backing) from docs/backend-plan.md.

1. profiles.map_visibility and profiles.invite_policy columns.
2. ENFORCE THEM IN POLICIES, not in the client: invite_policy in the
   invitations insert policy, map_visibility inside get_parties_near_user.
   A toggle checked only in the UI is privacy theatre.
3. Wire the "ΙΔΙΩΤΙΚΟΤΗΤΑ" toggles to these columns, replacing
   MpStore.mapVisible.
4. Stats tiles (πάρτι / διοργάνωσε / stories): an aggregate RPC over rsvps,
   parties, stories, replacing the hardcoded strings. Measure it — if it's
   slow on seeded data, propose counter columns instead and tell me the
   tradeoff.
5. credibility_score: there's a protect_credibility_score trigger but
   nothing defines what WRITES the value. Do not invent a formula. Instead,
   list the options with their tradeoffs and tell me what a v1 could look
   like. I'll decide.

pgTAP: a user with map_visibility = 'followers' does not appear in the map
RPC for a stranger who does not follow them.
```

---

## Phase 9 — Compliance

```
Task: Phase 9 (Account lifecycle & compliance) from docs/backend-plan.md.

1. Soft-delete profiles.deleted_at, 30-day grace period, then hard delete via
   Edge Function (auth user + storage objects + cascades).
2. In-app deletion entry point — App Store requires it wherever accounts can
   be created.
3. Data export Edge Function producing JSON: profile, parties, rsvps, posts,
   messages.
4. Before implementing: audit every FK in the schema and tell me which ones
   should cascade, which should set null, and which need anonymisation.
   Specifically, a deleted user's group-chat messages should probably remain
   as "Διαγραμμένος χρήστης" rather than vanish and break the conversation
   flow. Give me the table-by-table recommendation and wait for my decision
   before writing migrations.
5. Document the retention policy: locations 24h, sent_notifications 90d,
   ended parties indefinite.
```

---

## Phase 10 — Hardening

```
Task: Phase 10 (Hardening) from docs/backend-plan.md.

1. Run get_advisors (Supabase MCP) for security and performance lint. Fix
   everything actionable; list anything you're deliberately leaving and why.
2. Index audit: every FK used in a join needs an index; every policy with a
   subquery needs the matching index. Show me the ones that were missing.
3. Re-check the parties ↔ invitations cross-table RLS under load, now that
   pgTAP can verify it rather than me reading code.
4. Rate limiting on writes: posts, stories, messages, invites.
5. Load test get_parties_near_user with realistic volume — generate 10k
   parties and 50k rsvps, not the 20 seeded ones. Report p50/p95 and tell me
   what breaks first.
```

---

## Prompts επαναχρησιμοποιήσιμα

### Πριν κάθε PR

```
Review the diff on this branch against docs/backend-plan.md and CLAUDE.md.
Check specifically:
- every new table has RLS enabled, with policies using (select auth.uid())
- every security definer function has set search_path = ''
- no visibility logic was duplicated instead of using the helpers
- every new table has pgTAP tests, including negative assertions
- no offset pagination anywhere
- the mock state this phase replaced was actually deleted from mp_store.dart

List violations only. Don't restate what's correct.
```

### Όταν κάτι δεν δουλεύει

```
[symptom]

Before proposing a fix: figure out whether this is an RLS problem, a query
problem, or a client-state problem. Query the DB directly as the affected
user (impersonate with the pgTAP helper) and show me what the database
actually returns. Don't guess from the Flutter side.
```

### Όταν αρχίζει να παίρνει πρωτοβουλίες που δεν θες

```
Stop. You're outside the scope of this phase. Re-read the phase section in
docs/backend-plan.md and list what you've done that isn't in it. Revert
anything I don't approve.
```

---

## Πρακτικοί κανόνες για vibe coding

- **Plan mode πάντα στην αρχή φάσης.** Το πρώτο plan είναι σχεδόν πάντα 80% σωστό — τα 20% που διορθώνεις εκεί σου γλιτώνουν μια ώρα ξεμπερδέματος μετά.
- **Commit μετά από κάθε πράσινο test run**, όχι στο τέλος της φάσης. Θέλεις σημείο επιστροφής.
- **Τα migrations είναι append-only μόλις φύγουν για hosted.** Αν χρειαστεί αλλαγή, νέο migration. Πες του το ρητά αν το ξεχάσει.
- **Μην το αφήσεις να γράψει δύο φάσεις μαζί** επειδή «είναι εύκολο». Το review γίνεται αδύνατο και τα RLS bugs περνάνε.
- **Το «δείξε μου πρώτα τη λίστα, μετά γράψε»** (Phases 3 και 9) είναι το πιο χρήσιμο pattern σε αυτό το project — σε RLS work το να δεις τι σκοπεύει να αγγίξει πριν το αγγίξει αξίζει τα 30 δευτερόλεπτα.
