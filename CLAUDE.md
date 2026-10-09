# MyParty — working rules

## Project shape

Flutter client (`myparty/`) + Supabase (Postgres 17/PostGIS, Auth, Storage,
Realtime, Edge Functions). Full design/rationale: `docs/backend-plan.md`.
Session-by-session task scripts: `docs/MyParty-ClaudeCode-Prompts.md`.

**Real today:** `profiles`/`parties`/`invitations`/`rsvps`/`follows`/`blocks`/
`party_posts`/`post_likes`/`post_comments`/`reports`/`messages`/`party_reads`/
`stories`/`story_views`/`user_devices`/`sent_notifications`/
`notification_jobs`/`user_birthdates`/`direct_threads`/`direct_messages`/
`direct_reads` tables with RLS;
the **13+ age gate** — `before_user_created_age_gate`, a Supabase Auth
`before_user_created` hook (not a trigger: raw `auth.users` inserts in seed and
tests must keep working), with the DOB stored owner-read-only in
`user_birthdates` because `profiles` is readable by everyone;
`get_parties_near_user` RPC
(tier/zoom-filtered map query, `p_limit` defaulting to 200 and clamped to
[1, 500], `authenticated`-only since `20260821175831`, and time-windowed by
`p_window` since `20260823091942`), called live from
`MapScreen` through `PartyRepository.fetchPartiesNearUser`;
`party_time_window` and `party_end_grace` (the map's Όλα/Τώρα/Αργότερα απόψε/
Το ΣΚ chips, filtered server-side — see `docs/phase-15-map-time-filters.md`;
the grace now applies to every window and to the list, gotcha 21);
`create_party_with_invites`; `get_my_parties` (MY PARTIES, finished parties
excluded by gotcha 21's shared predicate); `get_feed`, `get_post_comments`, `get_messages`,
`get_party_chats` and `get_party_stories`/`get_story_rails` (all
keyset-paginated or time-bounded, all invoker-rights so RLS does the
filtering); `hide_post`/`hide_comment`/`hide_message`/`hide_story`; the
`can_access_party`, `can_chat_in_party`, `is_blocked`, `can_moderate_post`,
`can_moderate_comment`, `can_moderate_message`, `can_moderate_story`,
`has_location_consent`, `can_user_access_party`, `wants_nearby_notifications`,
`in_quiet_hours` and `quiet_hours_end_at` helpers; the **event-driven
proximity notification engine** (publish trigger + device-movement trigger →
`enqueue_nearby_party_notifications` → `notification_jobs`, with the hourly
`nearby-notification-sweep` cron as a safety net only); realtime group chat
over **broadcast from database** (trigger on
`messages` → topic `party:{uuid}`, authorized by RLS on `realtime.messages`);
the story upload handshake (`story_upload_target` → `story-media` edge
function → signed PUT → `confirm_story_upload`) and the `pg_cron`
`story-cleanup` job that hides expired stories **and** deletes their objects
over pg_net; the `pg_cron` `location-retention` job (`purge_stale_locations`
+ `purge_old_sent_notifications`); `handle_new_user` (every `auth.users`
insert gets a `profiles` row) + `check_username_available` and the
onboarding/consent columns; the **delivery half** of the notification
pipeline (`claim_notification_jobs`/`complete_notification_job`/
`fail_notification_job`/`delete_device_by_push_token`, the
`notification-worker` edge function calling FCM HTTP v1, the statement-level
insert trigger and the every-minute `notification-worker-tick` cron that both
POST to it over pg_net) and `upsert_user_device`, the client's only door into
`user_devices`;
`map_visibility`/`invite_policy` on `profiles` with `accepts_invite_from`,
enforced in the `invitations` INSERT policy and inside `get_parties_near_user`
respectively, plus `get_profile_stats`; the **account lifecycle** —
`profiles.deleted_at`/`erased_at`, `request_account_deletion` /
`cancel_account_deletion`, the `account_erasures` queue with
`claim_accounts_for_erasure`/`complete_account_erasure`/`fail_account_erasure`,
the daily `account-erasure-sweep` cron, the `account-eraser` and
`account-export` edge functions and `export_account_data`;
**server-side write rate limits on all five client-writable content paths** —
messages (20/10s per user+party), stories (10/h), posts (30/h), comments
(100/h) and invitations (500 per party, 1000/h per host, statement-level);
`AuthService` (email signup/signin/signout via `supabase_flutter`);
`PartyRepository`, `SocialRepository`, `FeedRepository`, `ChatRepository`,
`StoryRepository`, `DeviceRepository`, `ProfileRepository` and
`AccountRepository` (all
widget-level Supabase calls go
through these — a widget reaching for `Supabase.instance` directly is a bug,
and also unbuildable under `flutter test`); `PushService`, `LocationReporter`
and the `Notifications` app-scoped wiring; `showLocationConsentSheet`,
`NotificationSettingsScreen` and `AccountDeletionScreen`.

**Group chat belongs to private parties only** (Phase 16c). `can_chat_in_party`
is now `can_access_party AND party_is_private`. The participation disjunction
(host/invited/rsvp'd) was **deleted, not lost**: it existed solely to stop a
public party's chat being world-writable, and on a private party it is a
tautology — `can_access_party` already means host-or-invited there, and an
`rsvps` row can only exist where `can_access_party` passed, so "rsvp'd" implies
"invited". **A revert must restore that clause in the same migration**, or
public chat comes back writable by the entire user base. Existing public-party
messages were hidden with `hidden_reason` naming the migration rather than left
to fall out of the policy silently — a moderator asking "what was taken down"
has to find them. Guarded at all three client entry points; `MessagesScreen`
needs none because `get_party_chats` already filters on the helper.

**Direct messages are their own three tables, not a `type` on `messages`**
(Phase 33, `20261009095551`). There is no conversation table in group chat to
put a type on, because the party IS the conversation. Making `messages.party_id`
nullable would turn every chat policy, the topic policy, the rate limit and the
export into two-armed ORs around a helper whose revert warning is already
load-bearing. So DMs reuse the *shapes* and the client's chat UI, and share no
rows. Five things worth knowing:

- **One thread per pair, by construction.** `direct_threads` stores
  `(user_low, user_high)` with `check (user_low < user_high)` and a unique key,
  so A→B and B→A are the same row and a thread with yourself is
  unrepresentable. The client has no write grant at all:
  `get_or_create_direct_thread` is the only door, and it does
  `on conflict do nothing` then re-reads, so two simultaneous taps return one
  id. A thread with `last_message_at is null` (opened, never written in) is not
  listed.
- **`dm_policy` (everyone / following / nobody, default everyone)** points the
  same way as `invite_policy`: 'following' means people *I* follow (gotcha 14,
  asserted both ways). It gates new threads, and `can_send_direct_message`
  re-asks it on **every send until the peer has written in the thread**. With
  that arm, 'nobody' stops strangers without silencing conversations you are in.
  Without it, a thread opened while you were 'everyone' would stay a standing
  licence to message you.
- **A block overrides everything, in existing threads too.** No new thread, no
  send in either direction, the peer's lines leave the SELECT policy (gotcha 2's
  author term: in a two-person thread the peer IS the other author), the
  `dm:{uuid}` topic refuses the join (`can_view_direct_thread`), and the list
  drops the thread. Every refusal from `get_or_create_direct_thread` is the same
  `'cannot message this user'`, 42501, whether the cause is self, unknown,
  deleted, blocked or policy. Do not make them distinguishable, or the RPC
  becomes a block oracle.
- **Realtime is a second SELECT policy on `realtime.messages`**, beside the party
  one. Each topic parser accepts only its own prefix, so neither policy can
  admit the other's channel (asserted). Still no INSERT policy.
- **Hiding is author-only.** A DM has no host, and a recipient hiding the
  sender's line would delete it from the sender's history too. Erasure keeps the
  lines under the tombstone and deletes `direct_reads`; the export carries the
  DMs the user wrote and their `dm_policy`.

No push for DMs yet. If it comes, gotcha 11 applies: the DM helpers are bound to
`auth.uid()` and would need per-user variants before a fan-out could call them.

**Party posts are HOST-ONLY, and the rule lives in the INSERT policy** —
`is_party_host` in the `party_posts` INSERT policy, with **no** matching
`author_id = host_id` filter on the read side. Two places expressing one rule
drift; the policy is what makes it true, a read filter would only make it look
true while non-host rows accumulated. Three consequences worth knowing:

- **`get_feed` becomes a host broadcast.** It shows posts from every accessible
  party by any author; with host-only writing it can only ever show host posts.
  `post_likes`/`post_comments` are untouched, so guests still react and reply —
  the feed keeps its conversation and loses guest authorship. Reversing is one
  migration and the read side needs no change either way.
- **`can_moderate_post`'s two arms now name the same person on every row.** A
  post's author is always the party's host, so host-arm and author-arm cannot
  be told apart by a test. Both stay in the helper: unlike the chat clause this
  one is not costless to remove, and there is no second statement of the rule
  for it to drift against.
- **Gotcha 2 no longer bites `party_posts`.** The author-side `is_blocked` term
  was there because a blocked user could post on a third party's public party;
  now the author IS the host, so `can_access_party`'s host block already covers
  every case. The term stays — it is one widening away from mattering again —
  but `05_feed_posts_and_reports.test.sql` can no longer demonstrate it failing
  on its own, and says so. Gotcha 2 is still live for `post_comments`,
  `messages` and `stories`, whose authors are still anybody.

**Post media got the handshake it never had.** `media_path` is derived by a
before-insert trigger from `{party_id}/{post_id}.{ext}` and carries **no insert
grant** — closing an edge where the client could write a storage key while the
`post-media` bucket has no INSERT policy for any role, making every media post
a dangling reference by construction. The flow mirrors stories exactly: insert
with `media_type` → `post_upload_target` → signed PUT via the **`post-media`
edge function** → `confirm_post_upload`, which checks `storage.objects` for the
bytes before making the row visible. A media post is invisible until confirmed,
to its author included, which is what makes an abandoned handshake safe.

**The `post-media` edge function has ONE route, and the asymmetry is
deliberate.** Unlike `story-media`, whose bucket ships zero policies in either
direction, `post-media` HAS a select policy following party visibility — so
reads are signed client-side under RLS (`FeedRepository.signedPostMediaUrls`,
same shape as `PartyRepository.signedCoverUrls`) and only the upload side needs
the service key. Adding a view route would mean holding the service key while
re-deciding a question the storage policy already answers correctly.

**Stories are hidden for launch and ship in a later update.** `FeedScreen.
_storiesEnabled = false` hides the two UI doors — the header's "+ Story" button
and the rail — **and nothing else**. Every table, RPC, policy, the upload
handshake, `StoryRepository`, `StoryViewerScreen`, `showStoryPickerSheet` and
`07_stories.test.sql` are untouched and still exercised. The **`story-cleanup`
pg_cron job must keep running** (`*/5`, verified active): it hides expired rows
and deletes their objects over pg_net, so stopping it would let the
`story-media` bucket accumulate files nothing will ever collect. Two widget
tests are `skip:`ped verbatim rather than rewritten — they are the coverage that
returns when the flag flips — and a third asserts the hidden state.

**`mpParties` is RETIRED** (Phase 18, `20260826094842`). The ALL PARTIES tab
runs on `get_parties_list`, and the three things the const map was blocking all
landed with it: `PartyDetailSheet`'s group-chat button and its story tiles now
open the real `ChatScreen`/`StoryViewerScreen`, because the sheet finally has a
uuid to hand them. It was one job, not three, exactly as recorded.

**Sorting is what forced it.** "Most interested first" applied to an
already-fetched page means "most interested among whatever we happened to
load", so the sort had to be the server's, and a server sort needs a server
list. Two sorts, as a `party_sort` **enum** so an unknown value is a type error
at the PostgREST boundary rather than a silent fallback to the default.

**Ordering by a hidden counter is a side channel, and the fix is grouping.**
`20260825090051` returns NULL for both counters on a private row so no client
can render the number; ordering by that number hands most of it back. A private
party ranked between two public rows whose counts ARE transmitted is
**bracketed, not blurred** — between 40 and 30 means it is in [30, 40], and the
interval tightens as the list gets denser. It is also observable over time: a
private row climbing the list reports rsvp *events*, which is more than the
magnitude that was withheld. So:

- Private parties are a **group pinned above** the public ranking, ordered
  among themselves by `starts_at`. Not excluded — a party you were invited to
  must not vanish because you changed the sort; sorting is not a filter. Above
  rather than below, because an invitation outranks a stranger's headcount.
- **This is the same call `MpDropGeometry.private()` already made** for pin
  size: fixed, at the ceiling, so nothing can be read off it. Ordering is that
  leak in one dimension.
- The group is ordered by `starts_at` and **not `going_count`**, which is NULLed
  for the same rows — ranking by it would trade a leak of interest for a leak
  of guest-list size.
- The `case when p.is_private then null` in `sort_rank` is what makes this "the
  value is never read" rather than "the leak is small". The group key alone
  already stops a private row being compared with a public one, but without the
  case the counter would still order private rows *among themselves* by a value
  none of them transmits.
- **The other sort needs none of it.** `'soonest'` ranks on `starts_at`, which
  is public for private parties, so they interleave freely there — asserted in
  `25_parties_list_and_sort.test.sql`, because "private is always grouped" is
  exactly the over-generalisation a later edit makes.

That test file's headline assertions are the **negative** ones: the two private
fixtures carry counts whose order *disagrees* with their `starts_at` order, so
"ordered by count" and "ordered by starts_at" predict opposite results. Against
agreeing numbers every assertion in it passes on the leaking implementation.

Keyset over one ascending 4-tuple — `(sort_group, sort_rank, starts_at,
party_id)` — for **both** sorts, with descending keys negated (`interested_count
desc` is `-interested_count asc`, which is why `sort_rank` is a bigint). One row
comparison paginates either sort and there is no second cursor shape to keep in
step. The cursor columns are returned so the client echoes back the last row it
drew, and `sort_rank` is 0 on every private row, so a cursor pointing at a
private party carries no count either.

**`hype` died with the map, and what replaced it is the thing it was a picture
of.** `MpStore._hype`, `HypeBar` and the bump button are deleted — a percentage
seeded at 64 and 41 for two hardcoded keys, decremented by a timer, with no hype
column in the schema and no phase that adds one. The card now shows the real
counter labelled by tense: "N interested" before a party starts, "N here now"
once it has. Same call `credibility_score` already got. Three `MpParty` fields
went with no replacement because no column answers them — `hostSub`, `dist` and
`posters`; distance is still shown on `MapPinSheet`, which is a spatial query
and therefore knows it. `MpStore` is now only `flashCopied`; **RSVP writes are
real** (`PartyRepository.setRsvp`, with the un-RSVP as the DELETE it always
described itself as being).

Two things about the list worth knowing: it filters out finished parties with
**the same predicate as the map** (gotcha 21, shared since `20261008150440` —
before that the map pinned zombies the list correctly hid, which read as an
empty list), and the sort control lives **outside** the scroll view, so an
empty or failed list still offers the way back to "soonest".

**A private party holds no attendance, and that is enforced in three places
because one would not hold.** Decided Phase 16b.

- **The write policy.** `rsvps` INSERT and UPDATE both call
  `rsvp_status_allowed(party_id, status)`, which is false for `'interested'`
  on a private party, so no private row carries an interested *status*.
  This used to imply that `interested_count` on a private row could never be
  non-zero; **Phase 17 retired that** (see below) and the read RPCs are now the
  only thing protecting the number.
  The term is in the UPDATE's **`with check`**, not its `using`: `using` sees
  the OLD row, so spelled there it would test the status being replaced and
  wave through exactly the write it forbids (`going` → `interested`).
- **The read RPCs.** `get_parties_near_user` and `search_parties` both return
  **NULL**, not 0, for `going_count`/`interested_count` on a private row. Zero
  is a legible, wrong answer indistinguishable from a real empty party; NULL is
  "not answered for this row", and it forces `int?` on the client so a surface
  that forgets fails to compile rather than rendering a confident 0. Both RPCs,
  because `MapPinSheet` is fed by either one — fixing one would leave the
  identical widget printing the number when reached from search.
- **The client.** No count, no hype bar, no "N people posting" on a private
  party, and one action ("Coming") instead of two.

`party_is_private` is `security definer` for gotcha 1's reason: privacy is a
property of the PARTY, not of the viewer, so answered through the caller's
filtered view of `public.parties` an invisible row reads as *not private* and
the write is permitted. Unlike `can_user_access_party` (gotcha 11) there is no
per-user variant to parameterise.

**The ceiling, so nobody mistakes this for more:** an RLS policy binds callers
that go through RLS. A future `security definer` RPC inserting rsvps bypasses
all three policies and must call `rsvp_status_allowed` itself. Nothing writes
`rsvps` server-side today — `create_party_with_invites` writes `invitations` —
so the policy is currently the complete enforcement surface. If that changes,
the rule moves to a `before insert or update` row trigger.

**`rsvp_status` has exactly two values and un-RSVPing is a `DELETE`.** There is
deliberately no `'declined'`: "not going" is the absence of a row, which the
DELETE policy and the counter trigger's DELETE branch have supported since the
table was created. A third value would record an absence the absent row already
records, and would widen `my_rsvp_status` on three read RPCs to do it.
`22_private_party_counts_and_rsvp.test.sql` asserts the enum stays at two, so
adding one is a red test rather than a silent widening.

`my_rsvp_status` is deliberately **still transmitted** for private parties: it
is a property of the CALLER, not of the party, so suppressing it would break
the button label while protecting nothing — the viewer already knows their own
answer. `parties.going_count` is likewise untouched and still maintained; the
host has a guest list. (`party_tier` does **not** read it, contrary to what
this said before Phase 17 — `party_tier` is a plain column set by the host in
`create_party_with_invites` and only ever read back as a zoom filter. Nothing
in the schema derives a number from either counter.)

**`interested_count` INCLUDES everyone going — it is a superset, not a
sibling.** Phase 17 (`20260826093437`). Going implies interested: a party with
30 going and 0 interested was reporting zero interest in a full room. The
change is entirely in `sync_party_rsvp_counters` plus a backfill
(`interested_count += going_count`); `going_count` is untouched in meaning and
value, and `rsvp_status` is untouched — a row is still exactly one of the two,
and anything reading `r.status` is unaffected, `get_profile_stats` included
(it counts `rsvps` rows, not these columns).

Three things about it that look wrong without the argument:

- **A status flip moves `going_count` alone.** Not "both counters move" —
  interested membership does not change in *either* direction, because the
  person was already counted before the flip and still is after it. The
  UPDATE branch therefore touches one column. A partial revert that increments
  both on insert but still decrements interested on the flip passes every
  insert assertion and drifts the counter down on every commit;
  `24_going_implies_interested.test.sql` asserts both directions separately
  for that reason.
- **Private parties are included, and that retired an invariant on purpose.**
  A private party with one going now has `interested_count = 1`, where
  20260825090050 previously made 0 the only reachable value. Nothing transmits
  it — 20260825090051 nulls **both** counters on a private row and is
  untouched — so the suppression that actually protects the number is intact.
  The alternative, incrementing interested only on public parties, buys the
  invariant back for a `parties.is_private` lookup on every rsvp write and a
  rule with two shapes. `22_private` asserts the new value directly so nobody
  "restores" the old one.
- **The backfill is a blind delta, not a recount.** A recount from `rsvps`
  would be self-healing, which is worse here: it would paper over any
  pre-existing drift at the one moment that drift is worth finding. The
  migration ends with a `going_count > interested_count` check that fails the
  apply.

**Nothing sums the two, and nothing may start.** Surveyed at Phase 17: all five
readers (`get_parties_near_user`, `search_parties`, `get_hosted_parties`,
`get_party_chats`, `export_account_data`) pass the columns through untouched,
and no Dart surface adds them. Two client consequences were accepted rather
than fixed: the **map pin grows before a party starts**, since
`MpDropGeometry.forPin` sizes on `attendeeCountAt` which is `interested_count`
pre-live (saturates at 100, so only parties under that move), and
**`MapPinSheet` prints both side by side**, which now shows overlapping sets —
"12 here now" beside "46 interested" means 46 of whom 12 arrived, not 58. The
doc comments on both were corrected; the UI was not.

**Party links are pointers, not keys** (Phase 25). `https://mypartycorp.com/p/<id>`
carries the party id and nothing else; opening it calls `get_party`, which is
SECURITY INVOKER, so a private party opens only for its host and invitees and
returns the *same* zero rows as an id that never existed — the client says
"not available" for every refusal, and a failed fetch too, so a link cannot be
used to probe which ids exist. A private party is shared **without its title**
(`partyShareText`). An invite-link capability ("anyone with the link joins")
was explicitly declined; if it ever comes it is a separate hashed, revocable
token, never the id.

**`detectSessionInUri` is OFF and must stay off** (`main.dart`). When on,
supabase_flutter feeds every incoming link to gotrue's `getSessionFromUrl`,
which saves ANY real user's `access_token`/`refresh_token` found in it as the
session — PKCE flow or not. With party links opening the app that is one tap
from login CSRF: a link built from the attacker's own tokens swaps the victim
into the attacker's account. Measured on the emulator: a party link carrying
host@myparty.local's real tokens opened the party and the auth server logged
zero `/user` calls. If an email/OAuth callback is ever added, re-enable it only
through `detectSessionInUriPredicate` scoped to that one path. Same review:
`allowBackup`/`dataExtractionRules` keep the refresh token in `shared_prefs`
out of cloud backup and device-to-device transfer.

**Red means private; `AppColors.destructive` means destructive.** Private moved
pink → `AppColors.private` (#F23557) across the map bubble, `PrivacyBadge` and
every card accent, so one colour means private app-wide. It is a *separate
token* from the #E5484D that account deletion uses — a private party is
exclusive, not dangerous. Red **joins** the dashed outline rather than replacing
it: red-vs-purple is exactly the pair red-green colour blindness collapses, so
the dash has to carry the distinction on its own for those readers. The private
bubble draws a **lock**, not a number — that label was the last place a private
party's attendance was still on screen, since the radius has been fixed since
the map rework but the label printed the count regardless.

Story visibility uses the **wide** `can_access_party`, not
`can_chat_in_party` — deliberately the opposite call from chat. A story is
read-only content attached to a party, so anyone who may look at the party may
watch its reel; chat is writable, which is why it narrows to participants.
Posting a story is gated by the same wide helper plus a 10/hour per-user rate
limit.

`user_devices.last_location` is the one column in the schema with a
**retention clock**, and three separate mechanisms keep it honest — none of
them optional, all asserted in `08_proximity_and_retention.test.sql`:

- The RLS `with check` refuses a location unless `has_location_consent`, on
  **INSERT and UPDATE both**. The gate is on the location, not the row: a
  device may register a push token with no consent and no location, since
  `push_consent` is a separate act.
- `round_location` (~100m, 3dp) runs in a **`before insert or update`
  trigger**, not only in whatever RPC the client calls. The precise fix
  never reaches the heap, the WAL, or a backup.
- `purge_stale_locations` nulls it past 24h on a `*/10` cron, and a trigger
  on `profiles.location_consent` going true→false clears it immediately.
  Both null the column and keep the row — retention is not unsubscribing
  someone from push.

There is deliberately **no location history table**, and the test asserts
over `pg_attribute` that `parties.location` and `user_devices.last_location`
are the only two geography columns in `public`, so adding one fails CI.
`sent_notifications` is engine-internal: RLS on, zero policies, zero client
grants, dedupe by the `(user_id, party_id, kind)` unique constraint.

`can_chat_in_party` is **narrower than** `can_access_party` and composes it.
`can_access_party` is true for any signed-in user on a public party; chat
additionally requires participation (host, invited, or RSVP'd), or every
public party's chat would be writable by the whole user base. Don't
"simplify" chat back onto `can_access_party` — see `docs/backend-plan.md` §6.

The social graph is **follows-only and asymmetric** — there is no
`friendships` table and no `are_friends` helper, deliberately. See
`docs/backend-plan.md` 3.1, which was reversed on purpose; don't reintroduce
one without an explicit product decision. A follow grants **no** private-party
visibility; that comes from `invitations` alone.

**Mock today, ships real in later phases:** nothing on the parties tab —
Phase 18 retired the last of it. `MpStore` holds only `flashCopied`, a
1.8-second "copied" flash on the host wizard's invite link. `PartyCard` and
`PartyDetailSheet` read real `parties` rows, so both of the sheet's former
placeholders (group chat, story tiles) open the real screens; the one
affordance still on `comingSoon` is **Directions**, and for a reason `mpParties`
was never responsible for — `get_parties_list` is not a spatial query, so the
row carries no coordinates. Real chat entry points are now `MessagesScreen`,
the host wizard's done screen, **and both
private-party doors on the parties tab**, and `MapPinSheet`'s header icon on
**private** pins only. A public pin still has none — its viewer is exactly the
passer-by `can_chat_in_party` excludes — while a private pin is visible only to
its host and invitees, who are exactly who that helper admits.

**A MY PARTIES row opens `MapPinSheet`** — the sheet a pin and a search hit
open, not a third one (`20261008152601`). `get_my_parties` carries the full
pin payload and is the third function in `20_party_search`'s column-parity
assertion, so a column the sheet renders cannot go missing from one door. The
row's old direct-to-chat tap is gone; on a private party the sheet's header
icon is that door now. Counters are NULL on a private row there too — the
sheet decides whether to print them from the NULL.

Phase 7 is complete end to end, and `scripts/verify_notification_delivery.sh`
measures it: 1s from `insert into parties` to a delivered push, one
notification from three racing enqueue paths, quiet hours deferred.

Phase 8 retired the first thing from `mp_store.dart`: `mapVisible` /
`toggleMapVisible` are **deleted, not migrated**. The real setting is
`profiles.map_visibility`, it has three tiers rather than two, and it is read
by `get_parties_near_user` — a mirror of it in memory could only ever disagree
with the server. **`credibility_score` ships no score in v1 — decided, not
pending.** The column and its `protect_credibility_score` trigger stay, written
by nothing and read by nothing; the client plumbing (`Profile.credibilityScore`,
the `SocialRepository` selects) was removed, because a field that is `0` for
every user on a model the profile screen renders is an invitation to display it.
Do not invent a formula, and do not derive one from tenure/volume — that is the
option `docs/backend-plan.md` 8.3 explicitly rejected. The only honest input is
host-confirmed reliability, which is a mechanism and its own phase.

**Phase 9 made profiles rows undeletable, on purpose.** Account deletion is a
soft delete (`deleted_at`) with a 30-day grace period, then a **tombstone**:
`auth.users` is hard-deleted, the `profiles` row survives with its username
scrubbed to an opaque `deleted_<uuid>` handle. Seven cascades into `profiles`
became `no action` and the `profiles.id -> auth.users` FK was dropped, because
a primary key cannot be `on delete set null` and the tombstone has to outlive
the auth user. Full reasoning and the table-by-table classification:
`docs/phase-09-fk-audit.md`; retention policy: `docs/backend-plan.md` 9.4.

Three things there are load-bearing and look wrong without the argument:

- **The tombstone profile MUST stay visible to the `profiles` SELECT policy.**
  Adding `and deleted_at is null` there is the obvious privacy fix and it is
  the one change that must never happen: `get_feed`, `get_messages`,
  `get_party_chats`, `get_post_comments`, `get_party_stories` and
  `get_parties_near_user` all reach the author through an **inner join** on
  `public.profiles` under invoker rights, so a profile made invisible by policy
  does not render as "Διαγραμμένος χρήστης" — it drops the message out of the
  thread, permanently. Discovery is suppressed where the discovery question is
  asked (`accepts_invite_from`, `wants_nearby_notifications`, and a client-side
  filter in `SocialRepository.searchProfiles`, which since Phase 14A is the
  `search_profiles` RPC and enforces `deleted_at` server-side rather than
  leaving it to the client).
- **`blocks` must not cascade, in either direction.** `is_blocked` is
  symmetric, so deleting the edge un-hides content the *surviving* user
  deliberately hid: B blocks A, A deletes their account, and A's retained
  messages reappear in B's chat. It is the one FK where cascading harms
  somebody who is still here.
- **`user_devices` is purged at T+0, not T+30d**, along with
  `notification_jobs` and `sent_notifications`. The grace period is for
  recovering an account, not a licence to keep processing someone's location
  for another month — same GDPR Art. 7(3) immediacy argument that made
  `claim_notification_jobs` re-ask the consent gates.

**FCM is wired conditionally and that is deliberate.** Gradle applies
`com.google.gms.google-services` only when `myparty/android/app/google-services.json`
exists, and `PushService` degrades to `PushAvailability.notConfigured`, so
`flutter build apk --debug` succeeds with no Firebase project. Don't "fix" this
by applying the plugin unconditionally: an Android handset with no Play
Services can never obtain a token either, so graceful degradation is the
correct *runtime* behaviour and the build-time conditional is just the same
fact expressed earlier. To switch it on: `flutterfire configure`, then set the
`FCM_SERVICE_ACCOUNT` secret on the edge function.

The **delivery worker holds the service key and therefore decides nothing** —
the same split as `story-media`. It never issues an UPDATE against
`notification_jobs`; it has three verbs (claim/complete/fail) and the queue's
state machine keeps one owner. The rule that protects is the 5-attempt cap:
a retry budget kept in worker memory resets on every redeploy and runs
independently in every concurrent invocation, which is not a budget at all.

**The claim re-asks the consent gates, and that is not redundant with the
enqueue-time check.** Quiet hours mean a decision taken at 02:14 is delivered
at 08:00; consent withdrawn in between has to take effect immediately (GDPR
Art. 7(3)), not "for jobs enqueued from now on". `claim_notification_jobs`
re-calls `wants_nearby_notifications` and re-checks the party is still
published and public, marking anything that fails **`cancelled`** — a status
added in 7c precisely so `failed` keeps meaning "we tried and could not".
A healthy system correctly declining a thousand jobs must not read as a
thousand delivery faults.

**The insert trigger and the every-minute cron are not the same mechanism
twice**, unlike 7b's sweep. Neither covers the other: the trigger fires within
milliseconds of an enqueue, which is what makes the 60s target reachable at
all; the cron is the *only* path for a deferred or retried job, because a
quiet-hours job due at 08:00 gets no insert event at 08:00. The trigger is
**statement-level** (one fan-out is a single INSERT of hundreds of rows) and
swallows its own errors on purpose — publishing a party must not fail because
vault has no worker secret.

**Consent ordering is enforced as a type, not a convention.**
`LocationReporter.requestConsent` takes a required `explanationAccepted`, so
the OS dialog is unreachable without having shown `showLocationConsentSheet`
first. The system prompt cannot say that what is stored is a ~100m cell, held
24h, visible to nobody and erased on toggle-off; the sheet says all four and
the widget test asserts each string. `location_consent` is written true only
when the explanation was accepted **and** the OS granted. And the revocation
path — a resume-time re-check that writes `location_consent = false` when the
permission has gone — is the *mechanism*, not bookkeeping: 7a's trigger on
that column erases every stored cell immediately, whereas merely stopping the
position stream would leave the last one on disk and matchable for 24 hours.

The notification engine is **event-driven, and the hourly sweep must stay a
safety net**. Two triggers do the real work — party publish fans out from that
one party, a device landing in a new ~100m cell fans in to that one user — and
both funnel into `enqueue_nearby_party_notifications`, which is the single
place the rules live. Don't add a second enqueue path; the movement trigger
deliberately calls the same function with `p_only_user_id` set rather than
writing its own. Three asymmetries in there are load-bearing and look like
inconsistencies if you don't know why:

- **Quiet hours claim the dedupe row; the daily cap does not.** Quiet hours
  defer an already-decided job to the end of the window, so the slot is spent.
  A cap is "not today" — burning the slot would make tomorrow's sweep skip it
  permanently.
- **`not is_private` on the party is not redundant with
  `can_user_access_party`.** The helper answers "may this user see it", which
  is true for an invitee of a private party. The guard asks something
  narrower: may we push it at them unprompted. A proximity ping would put a
  private party on a lock screen.
- **The debounce stores no location.** `old.last_location is distinct from
  new.last_location` already means "moved ~100m", because 7a rounds before
  storing and only restamps on a real cell change. `last_evaluated_at` is only
  the flip-flop floor. Adding a `last_evaluated_location` would double the
  location data under retention and break the two-geography-column assertion.

**Phase 10 hardened the schema and found one thing it did not fix.** The
default ACL is swept project-wide and cannot come back (gotcha 9); the eight
invoker read RPCs pin their `search_path`; seven indexes were added, all of
them for Phase 9's erasure and export engines rather than for a screen; and the
Supabase linter's rules now live as pgTAP assertions in `13_hardening.test.sql`
instead of on a dashboard pointed at a project stuck on Phase 1's schema.

The thing it did not fix is the headline: **`get_parties_near_user` costs ~1s
at 10k parties and ~99% of that is the `parties` row policy**, which also
defeats the GiST index (gotcha 19). The measurement, the plans and the proposed
policy rewrite are in `docs/phase-10-hardening-audit.md`. Do not drop
`parties_location` because an advisor calls it unused.

**Phase 12 applied that rewrite** (`20260821185216`): `is_blocked`,
`is_private` and `host_id` are hoisted out of `can_user_access_party` into the
`parties` SELECT policy, so a public party short-circuits with no function
call. 5km p50 **995ms → 199ms**. The helper is deliberately untouched — eight
policies across five tables call it — so party visibility now lives in **two**
places, and `17_parties_policy.test.sql` is what makes that safe: 65
assertions, including a both-directions equivalence proof over every persona
and every fixture party, so drift is a red test rather than a silent
divergence. Do not delete that file, and do not edit one copy without the
other. **The rewrite did not reach the GiST index and could never have** —
see gotcha 19 and `docs/phase-12-policy-rewrite-result.md`. Search (Phase 13)
is therefore still blocked.

**Cross-phase gotchas worth remembering:**

1. The `profiles` SELECT policy is no longer `using (true)` — it is
   block-filtered. Any function that reads `public.profiles` to answer a
   *global* question (uniqueness, counts, existence) must be
   `security definer`, or it will silently return the caller's filtered view
   as if it were the whole table. That is exactly how
   `check_username_available` started reporting taken usernames as free
   (`20260814104618`).
2. `can_access_party` answers about the party's **host** only. Any table
   holding authored content (`party_posts`, `post_comments`, `messages`,
   `stories`) needs its own `is_blocked` term on the **author** — a blocked
   user can have posted on a public party hosted by someone else.
3. **A soft-delete cannot be a client UPDATE.** On UPDATE, Postgres applies
   the SELECT policy to the *new* row whenever the statement needs read
   access, so setting `hidden_at` on a table whose SELECT policy says
   `hidden_at is null` always fails with "new row violates row-level
   security policy". Use a `security definer` RPC (`hide_post`,
   `hide_comment`, `hide_message`, `hide_story`) and leave the table with no
   UPDATE grant at all. A table with *no* `hidden_at` in its SELECT policy —
   like `party_reads` — is unaffected and can take a plain client upsert.
4. Table privileges are checked whether or not a `where` clause could ever
   be true. An RPC that merely *mentions* a table the caller lacks SELECT on
   errors out instead of returning zero rows — which is why `get_feed`,
   `get_messages`, `get_party_chats`, `get_party_stories` and
   `get_story_rails` all have `execute` revoked from `anon` rather than
   relying on their `auth.uid() is not null` guard.
5. **Realtime authorization is a separate policy on a separate table.** Chat
   delivery is broadcast-from-database, so who may *read a message row*
   (policy on `public.messages`) and who may *join the topic it is broadcast
   to* (policy on `realtime.messages`) are enforced independently. Both call
   `can_chat_in_party` so they cannot drift, and both are asserted separately
   in `06_group_chat.test.sql` — the first passing tells you nothing about
   the second. `realtime.messages` ships an INSERT grant to `authenticated`,
   so the *absence* of an INSERT policy on it is what stops clients forging
   broadcasts; don't add one.
6. **`insert … returning` is a READ.** RETURNING goes through the table's
   SELECT policy, so on a table whose policy hides the row you just wrote —
   `stories` hides anything with `media_uploaded_at is null` — the insert
   appears to fail. That is why creating a story is a bare insert and the
   media path comes back from the `story_upload_target` definer RPC, and why
   `StoryRepository.createStory` does not call `.select()`.
7. **`delete from storage.objects` does not delete the object.** That table
   is Storage's *metadata*; the bytes live in S3 (or the storage container's
   disk locally) and only the Storage API removes both. Deleting the row
   orphans the file — unreferenced, uncleanable, and now invisible to the one
   table you would have enumerated to find it. `purge_story_media` therefore
   sends a real `DELETE /storage/v1/object/story-media` over pg_net and only
   marks `media_deleted_at` once `reconcile_story_media_purges` has read the
   response back. `scripts/verify_story_lifecycle.sh` asserts the file is gone
   from disk, not just the row — pgTAP structurally cannot, because pg_net
   only dispatches after COMMIT and every test file rolls back.
8. **RLS filters rows; it cannot protect a column.** Keeping a column
   *derived* — `user_devices.last_location_at`, the clock the 24h retention
   sweep reads — takes a column-scoped grant, `grant update (push_token,
   platform, last_location)`, so the privilege to write it simply is not
   held. A row policy cannot express "not this column", and if the client
   could restamp `last_location_at` it could opt itself out of retention
   entirely. Same reasoning as `stories.media_path`.
9. **Every table in `public` is created holding privileges nobody granted.**
   Supabase's default ACL hands `anon` and `authenticated` TRUNCATE,
   REFERENCES, TRIGGER and MAINTAIN on each new table. None is a data
   privilege, so RLS is not bypassed — but **RLS does not mediate
   TRUNCATE**, so an RLS-perfect table is still one `anon` could empty if
   anything ever routed to it. `revoke all on <table> from anon,
   authenticated;` *before* the intended grants (`20260816083807`). Phase 10
   swept the other fifteen tables, the three sequences (`UPDATE` on a
   sequence is what `setval()` checks) and — the part that matters more than
   the fifteen — the **default privileges themselves**, so table twenty
   inherits nothing (`20260819092958`). `13_hardening.test.sql` asserts all
   three, so a regression is a red test rather than an audit finding.
   `spatial_ref_sys` is the one exception and cannot be fixed from a
   migration: supabase_admin owns it, `postgres` is not a member, and both
   the `revoke` and the `enable row level security` fail with 42501.
10. **A column-valued radius cannot drive a GiST index scan.** PostGIS turns
    `st_dwithin(geom, point, <const>)` into `geom && _st_expand(point,
    <const>)`, which the index can answer — but when the radius comes from
    the row being scanned there is no constant to expand by, and the planner
    demotes the whole predicate to a filter and seq-scans. So the proximity
    engine writes every spatial predicate **twice**: `st_dwithin(…, 5000)` to
    bound the box and make it indexable, plus `st_dwithin(…,
    pr.notify_radius_meters)` for the real answer. Deleting either breaks
    something different — the constant is the index, the column is the rule
    — and the 5000 literal is only sound because of the `CHECK` cap on
    `profiles.notify_radius_meters`, so the two move together.
    `scripts/explain_proximity.sh` prints both plans plus the seq-scanning
    control at ~20k devices; pgTAP cannot assert this, which is why the
    control query exists.
11. **A helper named for `auth.uid()` is unusable from a trigger.**
    `can_access_party(party_id)` silently answers about the *caller*, so
    calling it from an engine that fans out to other people returns the
    wrong user's visibility. The fix is to parameterise rather than copy:
    `can_user_access_party(user_id, party_id)` holds the body and
    `can_access_party` delegates to it bound to `auth.uid()`. Any future
    "does X apply to this other user" needs the same treatment — the
    tempting alternative, inlining the rule, puts a second copy of party
    visibility in the code path with the widest blast radius in the schema.
12. **A PostgREST upsert cannot satisfy asymmetric column grants.**
    PostgREST puts *every* key of the request body into the `ON CONFLICT DO
    UPDATE SET` list. `user_devices` grants `insert (id, user_id,
    push_token, platform, last_location)` but only `update (push_token,
    platform, last_location)` — deliberately, so `user_id` is settable once
    and the derived columns never (gotcha #8) — so a body carrying
    `user_id`, which the insert path *requires*, writes a column the update
    path has no privilege on. It succeeds on the first run and fails with
    42501 on every one after, which is the worst possible shape for a bug.
    In plain SQL the two lists are checked separately, so the fix is a
    function: `upsert_user_device`, `security invoker` so RLS and the
    consent `with check` stay the authority. Any future table with
    column-scoped write grants needs the same treatment.
13. **`revoke execute … from public` also revokes it from `service_role`.**
    Postgres grants EXECUTE on a new function to PUBLIC by default, and
    that is where `service_role`'s privilege comes from — there is no
    separate grant to survive the revoke. Everywhere before 7c that was
    invisible, because nothing outside the database called those functions.
    The moment an edge function does, the revoke has to be followed by an
    explicit `grant execute … to service_role`, or every RPC returns 42501
    on a function the developer can plainly see exists.
14. **The two privacy tiers point in opposite directions along the follow
    edge, and it type-checks either way.** `map_visibility = 'followers'`
    means people who follow ME (`follows.followee_id = me`);
    `invite_policy = 'following'` means people I follow
    (`follows.follower_id = me`). Swapping them compiles, passes analysis,
    and produces a working feature that is wrong: "anyone who follows me may
    invite me" is a spam vector, since following is unilateral and needs no
    consent. Both directions are asserted separately in
    `11_profile_privacy_and_stats.test.sql` for exactly that reason — one
    passing tells you nothing about the other.
15. **plpgsql resolves column names at RUNTIME, so a migration can apply
    cleanly and still be wrong.** `supabase db reset` only parses a function
    body; it does not check that `parties.start_time` exists (it is
    `starts_at`). Both Phase 9 migrations applied green and
    `request_account_deletion` would have cancelled nothing, silently, the
    first time a real user tapped delete. The only thing that catches this is
    a test that actually CALLS the function — which is why every RPC added
    from here on needs at least one `lives_ok`, even a trivial one. A green
    `db reset` is not evidence that a function works.
16. **An OUT parameter shadows a column name in `on conflict (col)`.** That
    clause is the one place in plpgsql where the name cannot be
    schema-qualified to disambiguate, so a function returning
    `table (user_id uuid, ...)` that also upserts into a table keyed on
    `user_id` fails at runtime with 42702. Target the constraint instead:
    `on conflict on constraint <pkey_name> do nothing`.
17. **A control query in an RLS test is filtered by the RLS it is
    controlling for.** Asserting "a stranger counts fewer than the owner"
    against `(select count(*) from public.parties where host_id = …)`
    evaluated AFTER `tests.authenticate_as(stranger)` compares two numbers
    that shrink in lockstep — it passed against a leak-free function and
    would have passed against a leaking one too. The control has to be
    captured while still authenticated as the owner (a temp table works) or
    it is not a control. Any assertion of the form "viewer A sees less than
    viewer B" has this failure mode.

18. **A BEFORE ROW trigger DOES see the rows its own statement inserted
    earlier**, which is the opposite of what READ COMMITTED suggests and the
    reason every per-row rate limit here is sound. A query inside a volatile
    plpgsql function takes a fresh snapshot whose `curcid` is the current
    command id, so rows with `cmin` equal to it are visible. Measured, not
    reasoned: one `insert into stories select … from generate_series(1,15)`
    is refused at row 11, and 25 messages in one statement at 21. Without
    that property a PostgREST array insert — `POST /rest/v1/party_posts`
    with 50 objects is ONE statement — would walk past posts, comments,
    messages and stories alike, and all four would still pass their
    one-row-at-a-time tests. Asserted in `13_hardening.test.sql`. The
    invitations limit is statement-level anyway, but for **cost**:
    `create_party_with_invites` writes the guest list as a single
    `insert … select`, so a row trigger would run 500 counting queries to
    answer a question with one answer.

19. **An RLS policy is a security barrier, and a non-leakproof predicate
    cannot be pushed past it — which is how a policy deletes an index.**
    `get_parties_near_user` under RLS seq-scans all 10k parties and calls
    `can_access_party` on every one, because `st_dwithin` is not leakproof
    and therefore may not be evaluated ahead of the policy; the GiST index
    on `parties.location` never gets an index condition to work with.
    Measured at 10k parties: **995ms p50 with RLS, 2ms with the policies
    off** — 99.7% of p95. It gets *worse zoomed in*, because the wide-zoom
    tiers have a cheap non-leaky `party_tier` filter that runs first and the
    5km branch has none.

    **Phase 12 applied the proposed hoist and it did NOT reach the index.**
    `20260821185216` moved `is_blocked`/`is_private`/`host_id` out of the
    helper into the policy: 5km p50 **995ms → 199ms**, a real 5×, and still
    `Seq Scan on parties` with `st_dwithin` in the Filter. The diagnosis above
    conflated two consequences of one cause. Policy *cost* and index
    *reachability* are separate, and only the first is fixable by a rewrite:

    - Promotion past a security barrier depends on the leakproofness of the
      **user qual**, not the policy's. `st_dwithin`, `_st_expand` and
      `geography_overlaps` (the `&&` operator) are all `proleakproof = f`, so
      the spatial predicate can never sort ahead of an RLS qual — and an index
      condition is by definition evaluated first.
    - Measured four ways by `scripts/explain_policy_pushdown.sh`: the shipped
      hoist seq-scans (203ms); `using (not is_private)` — one leakproof column
      reference, the cheapest policy that still filters anything — **also**
      leaves `st_dwithin` as a Filter (10.9ms); only `using (true)`, which the
      planner folds away entirely, and RLS-off reach `parties_location`
      (3.3ms / 2ms). `pg_stat_get_xact_numscans` confirms the index is touched
      exactly twice across the four plans.

    So `parties_location` still reads as an unused index in the advisor and
    still must not be dropped — but the reason is now the **notification
    engine**, which is SECURITY DEFINER and reaches it today, not a map query
    that might one day. Getting the map there needs the spatial scan out of
    RLS, or a leakproof indexable pre-filter — `float8gt`/`float8lt` on plain
    lat/lon columns are leakproof where `geography_overlaps` is not, so a
    bounding box on those CAN sort ahead of the policy — not another policy.
    Full result, plans and options: `docs/phase-12-policy-rewrite-result.md`.

    Two process traps from that phase, both worth more than the finding:
    `docs/phase-12-parties-policy-rewrite.md` §7.3 pointed the structural
    acceptance criterion at `scripts/explain_proximity.sh`, which EXPLAINs as
    `postgres` and therefore bypasses RLS — it printed the required
    `Index Cond` line **before** the migration too, and would have certified a
    no-op as a success. Anything claiming to measure an RLS effect has to run
    through `tests.authenticate_as`. And the same brief's predicted anon
    failure mode (`NOT IN` collapsing to NULL) does not reproduce at all:
    `NULL not in (<empty set>)` is TRUE, and the `blocks` SELECT policy is
    `blocker_id = auth.uid()`, so anon reads no block rows whatever the
    spelling. The inlined hoist is broken for a *different* viewer and a worse
    reason — that same policy hides "the host blocked me", half of a symmetric
    relation, so it leaks silently rather than erroring.

20. **A `language sql` set-returning function is inlined only if it is not
    SECURITY DEFINER, not VOLATILE, and has no SET clause.** All eight read
    RPCs are VOLATILE by default, so none has ever been inlined —
    `explain select * from get_parties_near_user(…)` prints one line,
    `Function Scan`, while the identical body declared STABLE prints a
    37-line plan. That is why `20260819095452` could pin `search_path` on
    all eight for free: it forecloses inlining, and there was none to lose.
    Worth re-pricing if gotcha 19's fix ever lands.

21. **A party with a null `ends_at` used to be on the map forever. Closed
    2026-10-08 (`20261008150440`), and the cost was accepted, not avoided.**
    `ends_at` is nullable with no default and the host wizard does not require
    it, so for most parties "it already happened" is a guess. The map,
    `get_parties_list` and `get_party` now share ONE predicate, spelled
    identically in all three bodies:

    ```
    p.status = 'published'
    and (p.ends_at is null or p.ends_at > now())
    and (p.ends_at is not null
         or p.starts_at > (select now() - public.party_end_grace()))
    ```

    which is exactly `not party_is_past(starts_at, ends_at)` — asserted row by
    row in `21_map_time_windows.test.sql`, alongside a map-vs-list parity
    assertion. **MY PARTIES** carries it too, through `get_my_parties`
    (`20261008151908`), which replaced three PostgREST selects and a Dart
    `ends_at == null || ends_at > now` filter — that filter was the old map
    rule copied client-side, and kept a no-end-time party forever after the
    map dropped it. Do not reintroduce an "is it over" check in Dart: the
    grace cannot be expressed through PostgREST without the client computing
    the cutoff itself, which is a second copy of the number. It cannot just *call* `party_is_past` (gotchas 20, 22).

    **What triggered it:** ALL PARTIES showed nothing while the map was full of
    pins. The list had always applied the grace; the map's Όλα had not, so on a
    DB seeded weeks earlier the map was entirely zombies and the list was
    correctly empty. "A pin with no card" was the symptom of two rules.

    **The cost, chosen knowingly:** an all-nighter with no stated end drops off
    the map six hours after it starts, while it is happening. That is the
    asymmetry Phase 15 refused to take on the base filter, and
    `docs/backlog.md` §2 recommended against adopting the 6h number wholesale.
    The trade was: a map that silently fills with parties that are over,
    versus a host who wants a long party on the map having to say when it
    ends. The honest path — an explicit `ends_at` — is untouched by the grace,
    and since this change the list keeps a multi-day party with a stated end
    too (it used to drop it at +6h while the map kept it). **The real fix is
    still to require `ends_at` at creation**; that would make the grace dead
    code on all three surfaces.

    Still true: **anything that writes a past party must set `ends_at`**, which
    is why every past party in `seed.sql` carries one. Seed's *future*
    parties carry none, so a local DB older than their start + 6h now shows an
    empty map and list — `supabase db reset` refreshes it.

22. **Leakproofness decides which of your filters run before the policy, and
    it is the single fact that prices every new predicate on `parties`.**
    Gotcha 19 is the special case; this is the rule. A non-leakproof operator
    may not be evaluated ahead of an RLS qual, so it lands *behind*
    `can_access_party` and filters rows that have already paid for it. A
    leakproof one runs first and shrinks the input.

    **Measured, not read off the catalog** — `pg_proc.proleakproof` says only
    what the planner is *allowed* to do. `scripts/explain_qual_pushdown.sh`
    prints what it did, at 10k parties, one predicate at a time:

    | predicate | leakproof | exec | buffers | printed `Filter:` order |
    |---|---|---|---|---|
    | *(policy only, baseline)* | — | 954ms | 62018 | policy |
    | `starts_at > <const>` | **yes** | **4.1ms** | **433** | **time, then policy** |
    | `title like '%zzzzzz%'` | no | 890ms | 61799 | policy, then like |
    | `st_dwithin(…, 1)` | no | 947ms | 61872 | policy, then dwithin |

    Three independent signals agree, and each alone would be weak: the printed
    `Filter:` order is the execution order; the time; and `shared hit`, which
    is the direct proxy for how many times `can_access_party` ran (~6 buffers
    per call — 62018/6 ≈ the 10k rows). The `like` matches **fewer** rows than
    the time predicate and costs 216× more. End to end on the map query body,
    adding a 6-hour window took **1483ms → 42ms**.

    **`enum_eq` is not leakproof and `texteq` is**, which is the mechanical
    reason gotcha 19's tier asymmetry exists: `party_tier` is `text`, so the
    wide-zoom tier filter sorts *ahead* of the policy, while
    `status = 'published'` is an enum comparison and sorts behind it — visible
    in Part 2's filter order, where `status` prints after `can_access_party`.
    Do not assume a cheap-looking equality pre-filters; check the type.

    Two consequences, both load-bearing for the map rework:

    - **Time filtering is free, and better than free. Phase 15 shipped it.**
      The Τώρα / Αργότερα / Το ΣΚ chips push `starts_at` bounds into
      `get_parties_near_user` and they cut the row count *before*
      `can_access_party` is called — the same mechanism that makes the 500km
      tier (leakproof `party_tier` filter first) faster than the 5km tier.
      `scripts/explain_map_time_windows.sh` measures the shipped body: at 5km
      with a tonight window, **210ms with neither pre-filter, 12.0ms with the
      bbox alone, 2.1ms with both** — the spatial and time pre-filters compose
      rather than one shadowing the other.

      **Two shapes of the same predicate are ~20× apart, and the slow one is
      what anyone writes first.** `coalesce(ends_at, starts_at + grace) >
      now()` puts a Var under `timestamptz_pl_interval`, which is not
      leakproof, so the whole term sinks behind the barrier;
      `starts_at > now() - grace` leaves `timestamptz_gt(Var, Const)` and is
      promoted. Same rows (170), 120.7ms vs 6.2ms. `party_is_past()` is doubly
      unusable — not leakproof *and* it carries a SET clause, so it can never
      be inlined (gotcha 20). Hence `party_end_grace()`: the **number** has one
      definition while the two call sites use the two shapes leakproofness
      forces on them. **When a new predicate has a constant and a column on
      opposite sides, check which side the leaky operator ends up on.**

      A bound coming from a `stable` plpgsql function still lands as an
      InitPlan constant and is still promoted — measured, because the failure
      mode (it silently becomes a correlated expression) has no symptom other
      than the old timing.
    - **Search must wait for the policy rewrite.** An `ilike` on
      `parties.title` or `parties.area` has exactly `st_dwithin`'s failure
      mode: it sits behind the barrier, seq-scans, and cannot reach an index —
      so adding `pg_trgm` or a `tsvector` column first would buy nothing, and
      measuring the search against a 995ms floor would teach the wrong lesson
      about it. **§5 of `docs/phase-10-hardening-audit.md` goes before search,
      not after.** Sequencing decided 2026-08-21.

23. **A grant is only the whole grant if the defaults grant nothing, and
    Supabase's image decides that, not us.** The `postgres` image runs
    `alter default privileges in schema public grant all on tables/functions/
    sequences to anon, authenticated`. The image this schema was written
    against did not apply it to our tables (`20260812115436` exists only to
    grant `authenticated` access to `profiles`/`parties`); `17.11.0.002`, pulled
    2026-10, does, and a fresh `db reset` handed anon full DML on 16 of 22
    tables plus EXECUTE on every RPC. 26 pgTAP assertions went red, some on
    their own birth commit. RLS still filtered rows, but the layer beneath it
    (column-scoped writes, "no UPDATE grant at all", anon refused `get_feed`)
    was gone. `20261004234903` closes the defaults, revokes everything anon/
    authenticated hold in `public` and re-grants an allow-list captured from a
    reset with the defaults off. **`27_explicit_grants.test.sql` holds that
    allow-list and fails on any grant it does not name, in either direction,**
    so a new `grant` in a migration needs its row there too. Note that
    `revoke … on table` also drops that table's column grants, so anything
    revoking at table level has to re-issue them.

**Known gaps live in `docs/backlog.md`**, including what is deliberately not a
gap. Sweep it when a phase ends; an item that turns out to be a decision moves
to its §3 rather than being deleted.

## Migration naming

`YYYYMMDDHHMMSS_snake_case_description.sql` in `supabase/migrations/`.
Generate the timestamp with `supabase migration new <name>` — never
hand-write one, ordering across branches depends on it.

## Non-negotiable engineering rules

1. **RLS on every table**, enabled in the same migration that creates it.
2. **`(select auth.uid())`**, never bare `auth.uid()`, in policies.
3. **`set search_path = ''`** on every `security definer` function, with
   fully schema-qualified refs (`public.profiles`) inside it.
4. **No duplicated visibility logic** — one helper per rule
   (`can_access_party`, `is_blocked`, …), every policy/RPC
   that needs it calls the helper, never reimplements it.
5. **Keyset pagination, never offset** — `where (created_at, id) < (?, ?)`
   with a matching composite index, for any unbounded list.
6. **Denormalized counters via trigger** (`going_count`, `like_count`, …) —
   never `count(*)` at read time.
7. Migrations are append-only once merged — new file, never edit a merged
   one. Storage writes for visibility-gated buckets go through signed URLs
   only, never direct client writes. UGC deletes are soft
   (`hidden_at`/`hidden_by`/`hidden_reason`); hard delete is reserved for
   account/GDPR erasure. Rate limits are enforced server-side.

## Commands

```
supabase start              # local stack (Postgres :54322, Studio :54323)
supabase db reset            # drop + reapply all migrations + seed.sql
supabase migration new NAME  # new timestamped migration file
supabase test db             # run pgTAP suite (supabase/tests/)
supabase functions serve     # edge functions (story-media); no name argument

# End-to-end story lifecycle, incl. proof the storage object is really gone.
# Needs the stack up and `supabase functions serve` running in another shell.
bash scripts/verify_story_lifecycle.sh

# Query plans for both proximity spatial queries, at ~20k devices / 5k
# parties generated in a transaction that rolls back. Prints the seq-scanning
# control alongside, which is the argument for the two-term st_dwithin.
bash scripts/explain_proximity.sh [N_USERS] [N_PARTIES]

# Phase 7c's target, measured: party -> delivered push in under 60s, no
# duplicates, quiet hours deferred, dead tokens cleaned up. Needs the stack up
# and nothing else — it starts scripts/fcm_stub.py (a stand-in for Google) and
# `functions serve` itself, and stops both on exit. pgTAP cannot cover any of
# this: pg_net only dispatches after COMMIT and every test file rolls back.
bash scripts/verify_notification_delivery.sh

# Phase 9's irreversible half, measured: soft delete -> 30 days -> the account
# is gone, the bytes are gone from the storage container's DISK, and the
# conversation is not. pgTAP cannot reach any of this — storage objects are not
# in Postgres (gotcha #7), the auth delete is a GoTrue admin call, and the
# story-media purge only dispatches after COMMIT while every test file rolls
# back. DESTRUCTIVE: permanently erases seed persona friend_not_invited; run
# `supabase db reset` afterwards. Starts `functions serve` itself.
bash scripts/verify_account_erasure.sh

# Phase 8: is get_profile_stats an aggregate or does it need counter columns?
# Generates 20k users / 200k rsvps in a rolled-back transaction and prints
# each count against its seq-scan control, plus the end-to-end RPC timing
# under RLS. Answer as measured: aggregate — >90% of the 2ms is policy
# evaluation, which a counter column would not touch.
bash scripts/explain_profile_stats.sh [N_USERS] [N_PARTIES] [RSVPS_PER_USER]

# Phase 10: what does the map query cost at 10k parties / 50k rsvps, and what
# breaks first? Measures get_parties_near_user p50/p95 per zoom tier as an
# authenticated viewer, in four variants -- as shipped, search_path pinned,
# STABLE (inlinable), and an RLS-bypassed control. The answer is the control:
# the row policy costs ~99% of p95 and defeats the GiST index entirely.
# Rolled back; the seeded fixtures are untouched.
bash scripts/loadtest_map_query.sh [N_PARTIES] [N_RSVPS] [N_USERS] [ITERATIONS]

# Phase 15: do the time chips actually pre-filter, and do they compose with the
# spatial one? Prints (1) whether a bound from party_time_window() reaches the
# plan as an InitPlan constant ahead of the policy, (2) the two spellings of the
# grace period against a control that all three return the same rows, and (3)
# the map body with neither / box only / window only / both. Rolled back.
bash scripts/explain_map_time_windows.sh [N_PARTIES]

# Phase 25: a party cover end to end over HTTP -- create, party-cover edge
# function, signed PUT, confirm_party_cover, a guest reading it back -- plus the
# refusals (non-host, second upload, non-image). Needs the stack up; starts
# `functions serve` itself and deletes its two throwaway private parties.
bash scripts/verify_party_cover.sh

# Host posts WITH their bytes, so HostPostStrip on MY PARTIES has something to
# draw. Not in seed.sql, and it cannot be: seed.sql cannot put a file in a
# bucket (gotcha #7), and 20260825095311 keeps a media post invisible until
# confirm_post_upload has checked storage.objects for the bytes -- so a seeded
# row alone just makes the strip 404 and collapse the tile. Runs the real
# handshake (insert as the host under RLS, PUT, confirm) rather than writing
# media_uploaded_at directly, and re-counts as the VIEWER at the end. Six posts
# on the three parties host@myparty.local has rsvps rows on. Idempotent; needs
# the stack up and Pillow. Re-run after every `supabase db reset`.
bash scripts/seed_post_media.sh

cd myparty
flutter pub get
flutter test                 # Flutter/Dart tests
flutter run
```

## How we work

- One phase = one session = one branch = one PR. Don't mix phases in a
  session — context fills and RLS review quality drops fast.
- Start each phase in plan mode; read the plan it produces, correct it,
  then let it write.
- Migrations are append-only once pushed to a shared branch — a change
  means a new migration, not an edit.
- Every new table ships with pgTAP tests in the same PR, including at
  least one negative assertion (who should NOT see/write this row).
- `/clear` between phases; `/compact` if a single phase runs long.

## Git workflow

- Never commit directly to `main`.
- At the START of every task, before writing any code, create and check out
  a new branch: `git checkout main && git pull && git checkout -b phase/NN-short-name`
  (e.g. `phase/02-party-lifecycle`, `phase/07a-proximity-schema`).
- If the current branch is already a `phase/*` branch for THIS task, stay on it.
- If the current branch is `main` or an unrelated branch, stop and create the
  new one first.
- Commit after every green test run, not once at the end.
- Migrations are append-only once pushed to hosted: never edit an applied
  migration file, always add a new one.
- When the phase is done: push and open a PR with a summary of the migrations
  added and what shrank in `mp_store.dart`.
