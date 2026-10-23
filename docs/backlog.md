# Backlog — known gaps, so they are not rediscovered as bugs

Things that are **not done**, deliberately or by omission, and would otherwise
be found by a user before they are found by us.

**The rule for this file:** one line of *why it is still open*, not a
description of the feature. A backlog entry that only says what is missing gets
re-litigated every time somebody reads it; one that says why it was left tells
you whether the reason still holds.

Delete an entry when it ships. If an entry turns out to be a decision rather
than a gap, move it to §3 instead of deleting it.

Last swept: 2026-08-22, after Phase 14B. Phase 39 updated 1.12 and 1.17 and
added 1.21-1.24 (2026-10-14). Phase 40 shipped 1.24 (invite_to_party) and
added 1.25-1.29. Phase 44 shipped 1.1 (Remove photo) and 1.32 (names in the
export), raised 1.38 to high priority, and added 1.39 (2026-10-21). Phase 45
shipped 1.38, moved its fix decision to §3, and added 1.40-1.41 for Phase 46
(2026-10-21).
Phase 47 added 1.42-1.45, with 1.44 the auth-email release checklist.
Phase 46 shipped 1.40 and 1.41, moved the avatars and PostGIS decisions to §3,
and added 1.44 F (re-run the erasures a pre-existing bug failed) (2026-10-22).
Phase 49 made names public, recorded that in §3 and added 1.50 (name search)
and 1.51 (firebase_core and Built-in Kotlin) (2026-10-23).

---

## 1. Open gaps

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

### 1.3 Cover images do not render on the map pin itself

`MapPinSheet` now signs and draws the cover (`PartyRepository.signedCoverUrl`),
as do the parties tab, its detail sheet and the profile's party list. The pin
on the map still draws a placeholder.

*Why it is still open:* the pin thumbnail is a harder call than the sheet was —
a signed URL per visible pin is up to 200 round trips, so it needs batching or a
decision to stay a placeholder.

*What it costs to leave:* nothing is fetched and discarded any more; the pin is
just plainer than the sheet it opens. Since Phase 25 hosts can actually upload
covers, so this is now visible rather than theoretical.

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

**Closed on the map 2026-10-08 (`20261008150440`)** by adopting the 6h grace
on the map's default view and sharing one predicate with `get_parties_list`
and `get_party` — the option §2 below argued against, taken knowingly because
the zombie pins had made ALL PARTIES look broken. What remains open is the
real fix §2 recommends: **require `ends_at` at party creation** (option 3),
which retires the grace on every surface and stops live all-nighters with no
stated end vanishing at +6h.

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

### 1.9 The 13+ age gate is not enabled on the hosted project

`before_user_created_age_gate` (`20261003143423_date_of_birth.sql`) only refuses
sign-ups when the Auth **`before_user_created` hook** points at it. Local has it
in `supabase/config.toml`; hosted needs it set in the dashboard (Authentication →
Hooks) or via `supabase config push`. Like 1.8, no migration can do it.

*Why it is still open:* a dashboard setting, applied when this ships to hosted.

*What it costs to leave:* the hosted project accepts any sign-up, including
under-13s and accounts with no date of birth; the app's own check is the only
thing stopping them, and it is skippable by calling `/auth/v1/signup` directly.

### 1.10 GDPR Art. 8: 13–14 year-olds in Greece and consent-based processing

The minimum age is 13 (decided 2026-10-03). Greece sets the age of digital
consent at **15** (Law 4624/2019, Art. 21). Location and push processing here is
**consent-based** (`location_consent`, `push_consent`), and under Art. 8 a
13–14-year-old's consent to an information society service is only valid with
parental authorisation.

*Why it is still open:* a legal/product decision, not a code one — raise the
minimum to 15, add a parental-consent flow, or keep consent-based features off
for under-15s (the DOB is now stored, so the last is implementable).

*What it costs to leave:* location and push consent given by Greek users aged
13–14 may not be valid consent.

### 1.12 A party's cover can be replaced but never removed

Phase 39 (`20261014113214`) added replacement: a fresh `{party_id}/{uuid}` key
per upload, `confirm_party_cover_replacement`, and `party-cover/cleanup`
deleting what nothing points at. The avatar had the same gap until Phase 44
gave it "Remove photo" (null the column, delete the object, `avatar-sweep` as
the net); covers still have no "no cover" choice in the edit form.

*Why it is still open:* removal is one more branch of the edit form's cover
choice, and it lands naturally with the preset covers (1.21), which need the
same "cover_path goes null, cleanup runs" path.

*What it costs to leave:* a host who wants no picture has to pick another one.

### 1.13 Party links open the app only for builds signed with a listed key

`mypartycorp.com` is live on Cloudflare and serves `hosting/`'s
`assetlinks.json` and fallback page byte-for-byte. Google's Digital Asset Links
API answers `linked: true` for `com.example.myparty` with the one debug key the
file lists, and on that emulator `pm get-app-links` reads `verified` and an
ordinary tap on a party link opens the app (checked 2026-10-06).

*Why it is still open:* the file lists ONE developer's debug-key fingerprint,
so every other build — teammates' debug builds, a shared test build, the Play
signing key — needs its SHA-256 added (command in `hosting/README.md`). And the
app id is still Flutter's placeholder `com.example.myparty`, which Play rejects;
changing it means changing the file too. `www.mypartycorp.com` has no DNS
record, which is fine — the app and the manifest use the apex only.

*What it costs to leave:* on any phone whose build is not listed, a tapped link
falls back to the static page instead of the app. Separately, links only work
end to end against the local stack until the hosted Supabase project is caught
up — a friend's phone cannot reach `10.0.2.2`.

### 1.14 `09_notification_engine` #35 fails intermittently

"and exactly one job comes back, not one per sweep tick": after the test wipes
`notification_jobs` and `sent_notifications` for party `…0001`, the sweep
sometimes re-enqueues nothing for it (have 0, want 1). Seen 2026-10-04/05 at
roughly 1 in 5 full-suite runs before 00:00 UTC and about 1 in 15 after, on
`main` before and after Phase 20 alike. It has never failed with the file run
alone (16/16).

What was ruled out, with diagnostics captured on a failing run: the recipient
(`4444…`, tz UTC) is inside its radius, `wants_nearby_notifications` and
`can_user_access_party` are true, the daily cap reads 2/5, the party is published,
public and 5h out, and the dedupe rows really are gone before the sweep runs.
So every input to `enqueue_nearby_party_notifications` says "enqueue". Not
concurrent test files either: `supabase test db` runs them one at a time.

*Why it is still open:* the remaining suspect is something outside the test's
transaction that can still act on the rows it reads (the every-minute
`notification-worker-tick` cron is the obvious candidate), and catching it needs
a failing run with `pg_stat_activity`/lock diagnostics, which nobody has had yet.

*What it costs to leave:* a red CI run now and then that a rerun clears, which
trains people to rerun red runs. That is the real cost.

### 1.15 Party chat delivers a blocked author's lines live

Found 2026-10-09 while planning Phase 33. The `realtime.messages` policy on
`party:{uuid}` authorizes the TOPIC (`can_chat_in_party`), not each event, and
`broadcast_message` writes one row per message for every subscriber. So if B
has blocked A and both are on the same private party, A's new lines still
arrive on B's open chat over the socket, with the username the definer trigger
resolved. History is correct: the `messages` SELECT policy's author
`is_blocked` term drops A's lines from `get_messages` and the reconnect gap-fill.
Only the live stream leaks, and only until the screen is reopened.

*Why it is still open:* deliberately kept out of Phase 33, so the DM branch
does not also touch group-chat behaviour. The fix is client-side, because
realtime authorizes subscribers and not individual events: `ChatScreen` drops
`new_message` events whose `author_id` is blocked with the viewer. That needs
the viewer's block set, both directions, which nothing on the client loads yet.
A server-side fix would mean per-viewer topics, which gives up the
one-write-per-message property the broadcast design exists for.

*What it costs to leave:* a user who blocked someone in a shared private party
still sees that person's new lines while the chat is open. DMs do not have this
gap: a block refuses the send itself, so no event is ever written
(`31_direct_messages.test.sql`, section E).

The Messages list does **not** widen this. Since Phase 34 it holds the same
`party:{uuid}` topics, but it never renders a payload: any traffic triggers a
refetch of `get_party_chats`, which goes through the SELECT policy.

### 1.17 Other people's follows, RSVPs and invitations arrive on focus or resume

A new follower moves your FOLLOWERS tile, an RSVP on your party moves its
counters, and an invitation adds a row to MY PARTIES, but only when the tab is
next shown after 30s, or the app comes back after 30s away (`LiveRefresh`). None
of the three has a topic **outside the host dashboard**: since Phase 39 an RSVP
on your party signals `party_host:{uuid}` (`20261014113213`), which only the
open dashboard holds. The MY PARTIES row and the map pin for that same party
still update on focus or resume.

*Why it is still open:* each would be one more signal on a per-user topic,
fanning out to exactly one recipient (the followee, the host, the invitee), so
it would be cheap. It was left out to keep Phase 34's backend change to the one
case focus/resume handles badly: a conversation that goes on while you watch.
The `inbox:{uuid}` topic from 34b (`20261011125542`) is where they would go,
as new event names beside `dm_activity`, each carrying an id and nothing
else.
Nothing here polls, and nothing should start to.

### 1.18 The Parties chat list watches 25 conversations

`ChatListWatcher` holds the `party:{uuid}` topics of the first 25 rows, newest
first. A chat further down updates on focus or resume, not live. The Direct tab
has no such cap: it holds the one `inbox:{uuid}` topic (34b).

*Why it is still open:* the realtime server limits channels per connection, and
an open `ChatScreen` and the map's future needs share that budget. 25 was a
guess, not a measurement. Measure the actual limit on the hosted project before
raising it.

### 1.19 Three pieces of the live-data plumbing have no automated test

`subscribeChatTopic`'s channel sharing (one channel per topic, a holder count,
the replayed status), `subscribeInboxTopic`, and `MainScreen`'s wiring of
`visibleTab`/`appResumes` are exercised by nothing in `flutter test`. The inbox
policy and trigger are covered in pgTAP (`32_dm_inbox_topic`); the client's
join of that topic over a real socket is not. Everything that consumes them is
tested by setting `visibleTab`/`appResumes` directly or by faking `subscribe`.

*Why it is still open:* the first needs a `SupabaseClient`, and constructing one
under `flutter test` starts a realtime socket and timers. The second builds its
four screens with real repositories, since `MainScreen` takes no injection.
Both are a refactor (a realtime seam, injectable tabs) larger than the code they
would cover. Check them by hand on a device: open a party chat from the map,
switch to Messages, and have a second account post in it; then have a third
account send you a first DM while the Direct tab is open.

### 1.20 A profile edit does not reach lists that are already loaded

A new avatar or username shows on your own profile at once (`ProfileEditScreen`
reloads it), but rows that already rendered it, such as the peer side of a DM
list on someone else's phone, keep the old one until their next refetch.

*Why it is still open:* there is no `ProfileChanged` event, because none of the
viewer's own lists render the viewer's avatar. The people who would see it are
other users, and they get it on their next focus or resume.

### 1.21 Preset cover photos

Hosts can only upload their own cover. The intended feature is a set of stock
party photos a host picks instead of uploading, in the create wizard and in
the dashboard's Edit.

*Why it is still open:* it needs the photos themselves, somewhere public to
serve them from, and a way for a party to point at one —
`parties_cover_path_own_folder` only admits keys in the party's own folder, so
a preset is either a new column (`cover_preset`) or a widened CHECK. Phase 39
built the cover replacement so a preset slots in without a second cleanup
path: choosing one clears `cover_path`, and the same `party-cover/cleanup`
call removes the uploaded object it replaced.

### 1.22 Guests are not told when a party is cancelled or edited

`cancel_party` and `update_party` (Phase 39) change the party and notify
nobody. A cancelled party just disappears from the map, the lists and its link;
a moved start time shows only on the next fetch.

*Why it is still open:* it is a new notification kind with its own fan-out
(every rsvp'd guest and, for a private party, every invitee), and gotcha 11
applies: the delivery path would need per-user variants of whatever visibility
helper it calls. The queue (`notification_jobs`) and worker already exist.

*What it costs to leave:* a guest can turn up to a cancelled party.

### 1.23 "Here now" is going_count, not a check-in

The attendee sheets and cards say "N here now" once a party has started, and
the number is `going_count`, i.e. who said they would come. Nobody checks in,
so it counts no-shows and misses walk-ins. The host dashboard no longer shows
it: its "Here now" tile was removed in Phase 40, so this gap is about the
attendee surfaces only.

*Why it is still open:* a check-in is a new table, a new consent question (it
is a location fact about a person at a time) and a host-side flow. Until then
the label is honest about tense, not about presence.

### 1.25 Nobody is told they were invited

Phase 40's `invite_to_party` and invite links write an `invitations` row. The
party shows up in the guest's MY PARTIES, with an "Invited by @host" badge on
its card and sheet, but nothing tells the guest it is there.

*Why it is still open:* there is no in-app notification inbox, and push is
proximity-only. A "you were invited" push is a new notification kind for the
existing queue and worker, with the same gotcha 11 caveat as 1.22.

### 1.26 A link opened while signed out survives only while the app is running

A party or invite link opened before sign-in waits in `PartyLinks.pending`,
which lives in memory. It opens once the user has signed in, unless the app
is killed first (an email-confirmation round trip, for example). Then it is
gone and has to be tapped again.

*Why it is still open:* persisting it means writing a party id or an invite
token to device storage before the user has an account. Once the user has an
account it is cheap, but nobody has decided it is worth doing.

### 1.27 iOS has no universal links, for `/p` or `/i`

On iPhone, a party link or an invite link always opens the browser, which
shows the static fallback page. Android claims both paths through its verified
intent filter.

*Why it is still open:* there is no Apple Team ID yet, and universal links need
one. Three pieces are needed:

- `ios/Runner/Runner.entitlements` with
  `com.apple.developer.associated-domains = ["applinks:mypartycorp.com"]`, wired
  in as `CODE_SIGN_ENTITLEMENTS` for the Runner target.
- `hosting/mypartycorp.com/.well-known/apple-app-site-association`: JSON with
  `applinks.details[].appIDs = ["<TEAMID>.<bundle id>"]` and
  `components` for `/p/*` and `/i`. Invite links carry their token in the
  fragment, so the `/i` component matches on path only. Serve it with
  `Content-Type: application/json`, no redirect, no `.json` extension.
- The Team ID and a real bundle id (see 1.28) to put in both.

`app_links` already handles universal links on iOS, so no Dart changes.

### 1.28 The app id is still Flutter's placeholder: must fix before launch

Android `applicationId` and `namespace` are `com.example.myparty`
(`android/app/build.gradle.kts`), and so is the iOS
`PRODUCT_BUNDLE_IDENTIFIER`. Google Play rejects `com.example.*` packages.

*Why it is still open:* changing it is cheap in code and expensive everywhere
else, so it should be done once, deliberately:

- **`assetlinks.json`** names the package. Change both together, and redeploy
  the file before shipping the build, or party and invite links stop opening
  the app.
- **Existing installs.** To Android a new applicationId is a different app.
  Installed copies don't update; they sit beside the new one, keeping their
  own sign-in and local storage. That includes invite-link tokens the host
  saved on the device (`InviteLinkStore`), so a host would have to make a new
  link. Before any public release this only affects test phones.
- **Firebase.** If push is configured, `google-services.json` is tied to the
  package name and needs a new Android app in the Firebase project.
- **Kotlin package.** `namespace` and the `MainActivity` package directory
  should move with it.
- iOS: the bundle id goes into the Apple app record and 1.27's
  `apple-app-site-association`.

### 1.29 Invite links (`/i#token`) not yet tested on a device

Phase 40's device test (2026-10-18) passed everything else, including removal
cutting off a guest's already-open chat: the removed guest's open chat did not
receive the next message, so no channel fix was needed. The invite-link steps
were not run. Still to test on a device with two accounts (host A, guest B):

- **Link join:** A creates a link on a private party B is not invited to; B taps
  it, the party opens, and A's Invited tab shows B as VIA LINK.
- **Signed-out join:** B signs out, taps the link, signs in, and the party opens.
- **Re-join refused after removal:** A removes B; B's tap on the still-active
  link shows "This invite link doesn't work any more".
- **New-device regeneration:** on a reinstall or second phone the sheet says the
  link was made on another device; a new link works and the old one is refused.
- **Turning the link off:** the link is refused afterwards.
- **Blocked refusal:** with a block between A and B, B gets the same sentence.
- **The `/i` page without the app:** a browser shows the static page and no
  token anywhere on it.

*Why it is still open:* the `/i` fallback page (`hosting/mypartycorp.com/i/`,
plus the `/i` rule in `_redirects`) is not deployed to Cloudflare yet, and the
last step needs it. pgTAP (`34_party_invites`) and an HTTP smoke run against
the local stack cover the server side; nothing has exercised the Android intent
filter or the signed-out hand-off on a real phone.

### 1.30 There is no privacy policy: must fix before launch

There is no privacy policy or terms of service anywhere: not in the app, not
under `hosting/mypartycorp.com/`, and none outside this repo. Google Play
requires a privacy policy URL in the store listing (and a matching Data safety
form) before an app that collects personal data can be published, and the app
should link to the same page from Settings.

It has to cover, at least:

- **Gender:** self-reported at sign-up, changeable or clearable ("Prefer not to
  say") in Settings, stored owner-read-only in `user_genders`.
- **The gender mix hosts see** (Phase 41): a host sees exact counts of their
  guests by gender, per Going / Interested / Coming group, for groups of three
  or more. Say plainly what the app says on the register screen and in
  Settings: a host who also sees the guest list may be able to work out an
  individual's answer, and "Prefer not to say" keeps you out of the counts.
- **Date of birth:** collected for the 13+ gate, owner-read-only, never shown
  (see also 1.10 on Art. 8).
- **Location:** a ~100m cell, held 24h, used only for nearby-party
  notifications, erased when consent is turned off; no location history.
- **Messages:** party chat and direct messages, who can read them, and that
  they are retained (under a tombstone) after the author's account is erased.
- **Account deletion and export:** the 30-day grace period, what is deleted and
  what is retained, and the in-app export.
- **MapTiler (address search)** (Phase 42): while a host creates or edits a
  party, what they type in the address field and where they put the pin are
  sent from their device to MapTiler's Geocoding API, private parties included.
  The chosen address is stored on the party (`parties.address`), visible to
  whoever can see the party, and cleared when the host's account is erased.
  MapTiler is a processor here; name it. (The map tiles are OpenFreeMap's
  since Phase 47 — CARTO's before — and OpenFreeMap receives the tile
  coordinates of whatever map area is on screen, plus the device's IP: list
  OpenFreeMap too.)

*Why it is still open:* it is a legal document, not code; someone has to write
and own it. The text above is a checklist of what the schema actually does, not
the policy.

### 1.33 Descriptions written before Phase 42 may contain an address

Until Phase 42 the host wizard joined the typed address onto the front of
`parties.description` with a blank line. Phase 42 gave the address its own
column, and erasure now clears `parties.address` on every party the user
hosted (`20261020105039`), because an address is often the host's home. The old
descriptions were left as they are: there is no reliable way to tell an address
paragraph from a description paragraph after the fact, so an erased host's
pre-Phase-42 parties can still carry their address in the description.

*Decide:* whether erasure should also clear (or redact) the description of
parties created before Phase 42, e.g. every hosted party with `created_at`
before the migration and a non-null description, accepting that it also removes
descriptions that never held an address. Or do a one-off cleanup now. Until
then the export and erasure behave as documented, minus this.

### 1.34 Confirm with MapTiler: geocoding on a non-MapTiler map — before launch

Address search uses MapTiler's Geocoding API while the map tiles are
OpenFreeMap's (CARTO's `dark_all` until Phase 47; the question is the same). MapTiler's Terms of Service (read 2026-10-20) do not address this
either way: §4 restricts reselling/redistribution and commercial derivative
works, §6.1–6.4 cover attribution on *displayed MapTiler maps* (not shown here),
and §6.5 asks for attribution "as part of the database" when search results are
stored (done: the comment on `parties.address`). The wizard shows "Address
search is provided by MapTiler. © OpenStreetMap contributors" under the field.

*To do:* get MapTiler's written confirmation that their geocoding may be used
with a third-party (OpenFreeMap) basemap on the plan we are on, and whether storing
the chosen address permanently is within it. If not, the options are MapTiler
tiles (a tile switch was considered and declined in Phase 42) or another
geocoder.

### 1.35 "Who sees which parties I go to" has no setting

Settings carried this row as "Coming soon" from the design prototype until
Phase 43 removed it. There is no column behind it: today the `rsvps` SELECT
policy alone decides who sees where someone is going, and `get_profile_stats`
answers from that same policy rather than inventing a second rule.

*Why it is still open:* it is an RLS phase, not a settings row. It needs a
`profiles` column, a tier in the `rsvps` SELECT policy (with gotcha 14's
direction question answered on purpose), `get_profile_stats` and every
attendee list re-checked against it, and pgTAP both ways.

*What it costs to leave:* nothing is promised any more. A user who wants to
hide their RSVPs can't, and the private-party note in Settings is the only
statement of who sees what.

### 1.36 `support@mypartycorp.com` has to exist before launch

Settings → Contact support (Phase 43) opens a mailto to `supportEmail`
(`lib/utils/app_info.dart`). Nothing in this repo can check that the mailbox
exists or that anyone reads it.

*To do:* create it (or change the constant), and route it to whoever answers
users. App Store and Play both expect a working support contact.

### 1.37 An erased account shows as `deleted_…`, not "Deleted user"

`complete_account_erasure` scrubs the username to an opaque
`deleted_<uuid hex>` handle, and the client prints it as it would any other
username: on chat and DM lines, comments, post headers, the Direct list and
anywhere else a name appears. `isErasedHandle` (`lib/ui/widgets/user_link.dart`)
already recognises the handle, but only to stop the name opening a profile.

*Fix:* render "Deleted user" wherever `isErasedHandle` is true, ideally in one
place (a shared display-name helper used by `UserLink` and every surface that
prints `@username`), with no avatar link. The handle itself stays as it is on
the server: it is what keeps the tombstone row unique and visible to the
`profiles` policy. When this ships, change the deletion screen's fact
("under an anonymous name instead of your username") to say "Deleted user",
and its assertion in `test/account_test.dart` with it.

*What it costs to leave:* a string like `deleted_3f2a…` in a chat reads as a
bug, though it reveals nothing about who wrote it.

### 1.39 Hosted deployment: phases 39-46 go out together, with an app update

The hosted project is behind local. Phases 39-44 have to be deployed together
**and with an app update**: since Phase 44 (`20261021094726`) the client can no
longer PATCH `username`, `onboarding_completed_at` or the consents, so an
older build cannot complete onboarding or change a consent against this
schema, and its `saveNames` writes names nobody reads. Ship the migrations and
the store build in the same window, and expect sign-ups on old builds to fail
until users update.

Phase 45 (`20261021121734`) makes the break total rather than partial: an older
build reads its own settings off `profiles` in `ProfileGate`, which the
narrowed SELECT refuses, so it cannot get past sign-in at all. Same window,
same app update.

Phase 46 (`20261021205851`-`…211609`) adds two more breaks for an older
build. Another host's profile loses its past-parties strip, because
`fetchHostedParties` selected the raw counters, which clients may no longer
read. And the party chat list shows a "0" member badge, because
`get_party_chats` now sends NULL. Same window, same app update. After applying,
do 1.44 F.

**Before applying, run both checks against the hosted database.**

1. *Names the copy cannot take.* `20261021094725` copies first/last name out of
   the auth metadata and then strips it, and **fails the apply** if any account
   holds a name the copy would lose. Anything this returns has to be decided
   (fixed by hand, or accepted as lost) before deploying:

   ```sql
   select u.id,
          u.raw_user_meta_data ->> 'first_name' as first_name,
          u.raw_user_meta_data ->> 'last_name'  as last_name
   from auth.users u
   where (u.raw_user_meta_data ? 'first_name' or u.raw_user_meta_data ? 'last_name')
     and nullif(btrim(coalesce(u.raw_user_meta_data ->> 'first_name', '')
                      || coalesce(u.raw_user_meta_data ->> 'last_name', '')), '') is not null
     and not (
       coalesce(btrim(u.raw_user_meta_data ->> 'first_name'), '') <> ''
       and char_length(btrim(u.raw_user_meta_data ->> 'first_name')) <= 50
       and btrim(u.raw_user_meta_data ->> 'first_name') !~ '[[:cntrl:]]'
       and coalesce(btrim(u.raw_user_meta_data ->> 'last_name'), '') <> ''
       and char_length(btrim(u.raw_user_meta_data ->> 'last_name')) <= 50
       and btrim(u.raw_user_meta_data ->> 'last_name') !~ '[[:cntrl:]]'
     );
   ```

   Zero rows means the migration applies. The rule it mirrors is
   `person_name_is_valid`: both halves present, trimmed, 1-50 characters, no
   control characters.

2. *Usernames below the new rule.* Not a blocker: these accounts keep their
   name, the edit screen tells them it does not meet the rule, and the rule
   binds only the next name they choose. The count says how many will see that
   notice (placeholders and tombstones excluded):

   ```sql
   select count(*) from public.profiles
   where onboarding_completed_at is not null and erased_at is null
     and not (username ~ '^[A-Za-z0-9_.]{3,30}$'
              and username !~ '^\.|\.$|\.\.'
              and lower(username) not like 'deleted\_%');
   ```

After applying, the vault secrets that `story-cleanup` and `party-cover-sweep`
use must exist on hosted too, or `avatar-sweep` fails every hour (P0002 from
`story_cleanup_config`).

*Why it is still open:* deploying is a release decision, and the hosted project
has not been brought forward since well before Phase 39.

### 1.42 Before launch: the hosted project must require the current password (step C.6 of 1.44)

Change password (Phase 47) sends `current_password` with the update, but GoTrue
only checks it when `update_password_require_current_password` is on, and the
CLI's `config.toml` (2.114) has no key for it. Measured locally: with the
setting off, a wrong current password was accepted and the password changed.
The app checks the current password itself first (a throwaway sign-in), so the
screen behaves correctly either way, but that check runs only on a client that
wants it to. A stolen session alone could change the password through
`PUT /auth/v1/user` until the setting is on.

*To do:* turn it on for the hosted project. Read the auth config first
(`GET https://api.supabase.com/v1/projects/{ref}/config/auth`) and confirm the
field name, expected to be `security_update_password_require_current_password`,
then `PATCH` it to `true`, or use the dashboard toggle if it exists there. Then
check that `PUT /auth/v1/user` with a wrong `current_password` answers 400
`current_password_invalid`.

### 1.43 A device signed out remotely keeps its push row

A password change ends every other session of the account (measured, Phase 47).
Those devices are signed out on their next refresh, but nothing deletes their
`user_devices` rows: `AuthService.signOut` does that only on the device that
taps Sign out, before its session goes. So the delivery worker keeps pushing
this user's notifications to a phone that is no longer signed in, until FCM
rotates the token. The same is already true of any session that ends without
Sign out (refresh-token revocation, an expired session).

*Why it is still open:* the fix is server-side and has a choice in it: delete
`user_devices` rows whose owner has no live session (a sweep over
`auth.sessions`), or tie each row to the session that registered it.

### 1.44 RELEASE CHECKLIST — auth emails (Phase 47): everything on the hosted side

Phase 47 built sign-up confirmation, Forgot password and Change email against
the local mail catcher. None of it works on the hosted project until every step
below is done, in this order. Ship it in the same window as 1.39: an older app
build cannot confirm a sign-up (it has no code screen), so once confirmation is
on, sign-ups on old builds are stuck at "Email not confirmed".

**A. Resend (the email provider), EU region**

1. Create the Resend account. Add the domain `mypartycorp.com` and choose the
   **EU** region (users are in Greece; GDPR).
2. Create an API key with **sending access only**, restricted to that domain.
   It is the SMTP password in C.1; store it nowhere else.

**B. Cloudflare DNS for `mypartycorp.com`**

Copy the exact values from Resend's domain page; the typical set is:

1. `MX` on `send` → Resend's feedback host, priority 10.
2. `TXT` on `send` → Resend's SPF value (`v=spf1 include:… ~all`).
3. `TXT` on `resend._domainkey` → the DKIM public key.
4. `TXT` on `_dmarc` → `v=DMARC1; p=none; rua=mailto:<an address someone reads>`.
   Tighten to `p=quarantine` after a few weeks of clean reports.

These are DNS-only records (Cloudflare cannot proxy them). If `support@` is set
up with Cloudflare Email Routing (1.36), it lives on the apex while sending uses
`send.`, so the SPF records do not collide. Wait until Resend shows the domain
as verified.

**C. Supabase dashboard (hosted project)**

1. *Authentication → Emails → SMTP settings:* enable custom SMTP. Host
   `smtp.resend.com`, port `465`, user `resend`, password = the API key from A.2,
   sender `no-reply@mypartycorp.com`, sender name `MyParty`.
2. *Authentication → Rate limits:* raise "emails sent per hour" from the
   built-in limit (about 30 is enough to start).
3. *Authentication → URL configuration:* Site URL `https://mypartycorp.com`.
   Redirect allow-list: exactly `https://mypartycorp.com/auth/reset` and
   `https://mypartycorp.com/auth/email-change`. No wildcards.
4. *Authentication → Providers → Email:*
   - **Confirm email: ON.** This is not optional. GoTrue enforces the double
     confirmation of an email change only when sign-up confirmation is on
     (measured locally: with it off, either inbox alone completed the change).
     Existing users are already confirmed and are unaffected.
   - **Secure email change: ON** (both addresses confirm).
   - **Secure password change: OFF** (it emails a nonce before every change;
     the current password is asked instead, see C.6).
   - **Email OTP length: 8.** **Email OTP expiry: 3600** seconds.
5. *Authentication → Email templates:* paste the five files from
   `supabase/templates/`, with the subjects from `supabase/config.toml`:
   - Confirm signup ← `confirmation.html`
   - Reset password ← `recovery.html`
   - Change email address ← `email_change.html`
   - Security notification "password changed" ← `password_changed_notification.html` (turn it on)
   - Security notification "email changed" ← `email_changed_notification.html` (turn it on)
6. **Backlog 1.42:** turn on "require current password when updating". Read
   the auth config first (`GET /v1/projects/{ref}/config/auth`) and confirm the
   field name, expected to be `security_update_password_require_current_password`.

**D. Hosting**

1. Deploy `hosting/` to Cloudflare Pages: the new `auth/reset/index.html`,
   `auth/email-change/index.html` and the two `_redirects` lines.
2. Check `https://mypartycorp.com/auth/reset` and `/auth/email-change` answer
   200 with the static pages, and that `/.well-known/assetlinks.json` still
   verifies (README §1).

**E. After deploying, on a real phone with the release build**

1. **Does "require current password" block a reset?** It could not be measured
   locally (the CLI cannot turn it on). Request a reset, enter the code, set a
   new password. If the last step fails with `current_password_required`, the
   reset has to set the password through a different call; do not turn C.6 off
   to make it pass.
2. **Is the double confirmation enforced?** Request an email change and enter
   only the NEW address's code. The email must NOT change, and the app must say
   to confirm the other one. If it changes, C.4 "Confirm email" is not on.
3. With a wrong current password, Change password must answer under the
   current-password field, from the server (1.42).
4. Sign-up: the 8-digit code arrives, from `no-reply@mypartycorp.com`, and
   SPF/DKIM/DMARC pass (the received headers, or a mail-tester style check).
5. A reset link tapped on the phone that asked opens the app at "Choose a new
   password"; the same link tapped elsewhere shows the static page.

**F. Account erasures the post-media bug failed (Phase 46, `20261021211609`)**

Not an email step, but it is a hosted-side step that must follow a deploy, so
it lives here. Before `20261021211609`, `complete_account_erasure` nulled only
`media_path` on a captioned media post, which violates the Phase 23 checks, so
the erasure of any account with such a post rolled back on every daily sweep.
`fail_account_erasure` keeps the error; after 5 attempts
`claim_accounts_for_erasure` never claims the row again. Those accounts are
past their 30-day grace and still hold an auth user and personal data: an
Art. 17 erasure that did not happen.

After `20261021211609` is applied to hosted:

1. Find them (SQL editor, as postgres):

   ```sql
   select e.user_id, e.attempts, e.claimed_at, e.created_at, p.deleted_at,
          e.attempts >= 5 as gave_up, e.last_error
   from public.account_erasures e
   join public.profiles p on p.id = e.user_id
   where e.completed_at is null
     and (e.last_error like '%party_posts_media_path_implies_type%'
          or e.last_error like '%party_posts_uploaded_implies_path%')
   order by e.created_at;
   ```

   Rows with `gave_up = false` will finish on the next sweep by themselves; the
   rest need step 2. Keep the result: it is the record of which erasures ran
   late, and by how long (`now() - deleted_at - 30 days`).
2. Re-queue them. Resetting `attempts` and `claimed_at` is all the claim looks
   at; `last_error` stays until the next attempt overwrites it.

   ```sql
   update public.account_erasures
   set attempts = 0, claimed_at = null
   where completed_at is null
     and (last_error like '%party_posts_media_path_implies_type%'
          or last_error like '%party_posts_uploaded_implies_path%');
   ```
3. Run the eraser now rather than at 03:30:
   `select public.post_to_account_eraser('manual_rerun');`
4. Re-run the query in step 1. It must return no rows, and each user from step
   1 must have `completed_at` set and `profiles.erased_at` stamped. A row that
   is still there with a different `last_error` is a different fault: read it
   before re-queuing again.

### 1.45 A second sign-up for an unconfirmed email keeps the first password

Measured (Phase 47): signing up again for an address that never confirmed sends
a new code but does not change the password. Someone who registered with the
wrong password, or with somebody else's address that the real owner later
signs up with, confirms the code and is signed in, but the password that works
afterwards is the FIRST one. Forgot password recovers it, since the inbox is
proven by then.

*Why it is still open:* the fix is GoTrue's, or a server-side cleanup of
never-confirmed accounts older than a day (they also hold a `profiles` row,
created at sign-up).

### 1.46 "Rising" instead of "Popular" for the suggestions fallback

Phase 48 ranks the fallback tier by `follower_count`, which favours accounts
that are already big. A fairer ranking is most NEW followers in the last 30
days: it still reads only the public follow graph (never party attendance),
and it gives new accounts a way in. Decided as a later improvement.

*Why it is still open:* it needs an index on `follows (created_at)` and an
aggregate over 30 days of follows on every call, or a periodically refreshed
table. Price it with `scripts/explain_follow_suggestions.sh` first.

### 1.47 Follow suggestions: the two costs that grow with the user base

Measured at 20k users (`scripts/explain_follow_suggestions.sh`): 10-13ms for
typical viewers, 38ms for someone following 500, 117ms p50 for the worst case
(following the 200 heaviest followers, ~200k two-hop rows).

- **The worst case grows with the graph.** Mutual counts are exact, so every
  two-hop edge is counted on every page. If it becomes a problem, cap each
  mutual's contribution or cache the ranking per user, and say so in the label
  logic (an approximate count cannot say "and 2 others").
- **The floor grows with `profiles`.** v0's ~10ms is two passes over profiles
  (Popular's top 200, and the candidate join). A partial index on
  `(follower_count desc, id)` bought nothing at 20k and would cost a HOT update
  on every follow, since each follow rewrites `follower_count`. Revisit around
  100k accounts, measuring the follow write path as well as the read.

### 1.48 The basemap: OpenFreeMap has no SLA, and the plugin is a beta (Phase 47)

The map draws OpenFreeMap's vector tiles through `vector_map_tiles`
**9.0.0-beta.13**, pinned exactly in `pubspec.yaml`: no stable release supports
flutter_map 8 (8.0.0 needs ^7; 10.x betas need latlong2 0.9). Two things follow.

- **OpenFreeMap is a free, donation-run service with no uptime guarantee.** An
  outage leaves every map on its plain background with working pins, search and
  filters, retrying with backoff — not broken, but no streets. The way out is
  to host OpenMapTiles-schema tiles ourselves (a Protomaps/OpenMapTiles
  planet on Cloudflare R2 or similar) and change the source `url` in
  `assets/map/myparty-dark.json`; the style is unchanged as long as the schema
  is. Decide before the user count makes an outage expensive.
- **The beta line has been fixing memory leaks in the raster mode we use**
  (beta.12) and then a blank-tile regression those fixes caused (beta.13). Any
  bump of the pin needs the low-RAM Android run repeated: a long pan/zoom
  session and an offline cold start, watching memory, not just "it draws".
  If raster mode ever proves too heavy, the next step is native `maplibre_gl`
  with the same style, which is a bigger change (markers move off flutter_map).

### 1.49 The basemap's labels are Greek where OSM's `name` is

`assets/map/myparty-dark.json` labels streets and places with
`coalesce(name, name_en)`, i.e. as signposted, which matches the Greek
addresses MapTiler returns. International students may want Latin script;
`name:latin` exists in the tiles. A product call, one expression to change.

### 1.50 Idea: find people by first and last name

Since Phase 49 names are public to signed-in users, but `search_profiles`
still matches only `username_search`. Left out on purpose, not forgotten: name
search is a separate decision about discoverability (looking up a person by a
legal name is a stronger thing than seeing one on a profile you already
opened). It must honour the same row filter as the name itself (shown,
`is_discoverable`, not block-paired), and it needs its own index and measurement
because `user_names` is not on search's leakproof prefix path (gotcha 22).

### 1.51 `firebase_core` still applies the Kotlin Gradle Plugin itself

Every Android build warns: "Your app uses the following plugins that apply
Kotlin Gradle Plugin (KGP): firebase_core. Future versions of Flutter will fail
to build". Flutter now provides Kotlin itself ("Built-in Kotlin";
docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin), and a
plugin that still applies KGP will become a hard build error.

Still open because no release fixes it yet (checked 2026-10-23): we are on
`firebase_core` 4.15.1, the last 4.x, and the changelogs of 5.0.0 and 5.1.0 say
nothing about Built-in Kotlin. 5.0.0 is a breaking upgrade anyway (Firebase
Android BoM 35 with **minSdk 24**, Apple SDK 13, `firebase_messaging` 17), so
taking it now would cost a major bump and probably keep the warning.

**When to act:** when a `firebase_core` release says it supports Built-in
Kotlin, or when a Flutter upgrade turns the warning into an error, whichever
comes first. Upgrade `firebase_core` and `firebase_messaging` together, as
their own change. Check minSdk 24 against the devices we support, and re-run
`scripts/verify_notification_delivery.sh` and a real push on a handset.
`PushService`'s graceful degradation and the conditional
`google-services` plugin (CLAUDE.md, "FCM is wired conditionally") are
unaffected.

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

- **First and last names are public to signed-in users (Phase 49, 2026-10-23),
  reversing Phase 44's owner-read-only.** Names show under the username on a
  profile. They stay in `user_names`, exposed by a SECOND row policy rather
  than moved onto `profiles`, because the two conditions are about the row, and
  a grant names a role, never a row: a pending account shows no name but keeps
  it for a restore, and an existing user's name stays hidden until they have
  seen the notice. The policy's `exists` reads `profiles` as the caller, so the
  block filter applies to names without a second copy of it.
  - **Existing users opt in by seeing a notice, not by a date.** They were told
    "Only you can see your name". `shown_at` is null for every pre-Phase 49 row
    and keeps the name owner-only until the owner taps OK
    (`acknowledge_name_shown`) or saves the name under the new copy. The notice
    also offers Remove my name. An account whose owner never comes back never
    has its name published. A switch-over date would have published names of
    people who were never told.
  - **Names are optional, everywhere.** `set_my_names(null, null)` deletes the
    row, like `set_my_gender(null)`, and onboarding accepts none. Both or
    neither: half a name is still refused. Once Remove my name existed for
    existing users, requiring a name at sign-up would have made opting out a
    privilege of joining early.
  - `shown_at` is not granted to clients (it would date when someone saw the
    notice); the owner reads it through `get_my_names()`.

- **Sign-up email confirmation is ON, and turning it off breaks Change email.**
  Decided in Phase 47 (2026-10-21). GoTrue skips the second confirmation of an
  email change whenever sign-up autoconfirms (measured: with confirmation off,
  either inbox alone completed the change, in both orders and by link or code).
  With it off, a stolen session plus an inbox the attacker owns takes the
  account. The cost is one 8-digit code at sign-up.
- **`detectSessionInUri` stays off, even for the auth links.** Restricting it to
  `/auth/*` would not help: a forged sign-in link would simply use that path.
  `lib/utils/auth_link.dart` parses the two links itself and never reads a
  token: a reset link is a PKCE code that only the phone that asked can redeem
  (measured: `bad_code_verifier` elsewhere), and an email-change link only
  prompts a re-read. The 8-digit code is the main path for every flow.

- **The private columns of `profiles` are hidden by a column-scoped SELECT, not
  moved to their own table.** Decided in Phase 45 (2026-10-21), reversing what
  1.38 recorded. The table move rested on `14_profile_and_party_media`'s guard,
  "a column-scoped SELECT breaks bio's inherited block filter". It does not:
  the block filter is a ROW policy and applies to every column whatever the
  grants say, and a column grant can only make a column less visible. What the
  guard was really protecting against, bio quietly getting a visibility of its
  own, is caught as well by pinning the exact public column list, which the
  guard now does. The move would have bought the same privacy for a rewrite of
  the proximity engine's hot path (including gotcha 10's radius coupling),
  three triggers and about 40 test fixtures. A grant names a role and never a
  row, so the owner reads their own settings through `get_my_settings()`
  (definer). Writes did not change: a PostgREST PATCH with return=minimal reads
  only `id` (`scripts/verify_profile_privacy.sh`).
  - **`map_visibility` stays private, read through `host_on_my_map`.** That is
    one definer call per surviving map candidate. Measured at 10k parties,
    interleaved against the old body: +9% / +9% / +11% p50 at 5 / 50 / 500 km,
    p95 within noise. The fallback, making the tier public, was agreed in
    advance in case of a >20% regression; it was not needed.
  - **`is_discoverable` is a public generated column** (`deleted_at is null and
    erased_at is null`). The bit is public by design, since search has always
    dropped those accounts; the date stays private. It is a column and not a
    helper because `search_profiles` evaluates every prefix match: a helper
    took a two-letter search at 20k users from 93ms to 165ms p50, and the
    column is back at parity.

- **Party addresses ARE geocoded, through MapTiler, from the host's device.**
  Reversed on purpose in Phase 42 (2026-10-20); it was §1.11. Until then the
  schema refused both an address column and any geocoding, because a geocoder
  is a third party and a private party's location is the most protected value
  here, and the price was a pin that landed wherever the host's phone was. Now
  the host searches an address or moves the pin, the pin is reverse-geocoded
  into an editable address and an area, and `parties.location` is still the pin
  and only the pin. What MapTiler receives is what the host types and where the
  host puts the pin, about the host's own party; it never sees a guest. The
  address has its own column (`parties.address`), the row's visibility, and is
  cleared on erasure. Disclosure: 1.30. Terms: 1.34. Do not "restore" the old
  rule by stripping the geocoder without a product decision.

- **The sign-up response's token carries the gender answer for up to an
  hour.** The register form has to send it in the sign-up metadata, the only
  thing GoTrue hands `handle_new_user`. GoTrue's own write-back during sign-up
  is an UPDATE, and `strip_gender_from_auth_metadata` (BEFORE UPDATE on
  `auth.users`) removes the key there, so nothing server-side keeps it past the
  sign-up request: measured over HTTP on 2026-10-19 through sign-up,
  onboarding, sign-in and refresh, and for a sign-up that never onboards. But
  the access token in that same response was built from GoTrue's in-memory
  copy, so it, and the session the app persists, hold the answer until the
  first refresh (`jwt_expiry` 3600). It is the owner's own answer in the
  owner's own token. Getting rid of it would mean not sending it at sign-up,
  i.e. a second call after sign-up that can fail on its own.

- **Widgets never publish a `DataChange`; repositories do, after the server
  answered.** The screen the tap happened on is optimistic and rolls back on
  its own. Every other screen hears only confirmed writes, so a rollback is
  never something two screens have to undo. A widget publishing is how the
  party detail sheet ended up offering answers that went nowhere.
- **A hidden tab does not refetch on an event, it marks itself stale.** Four
  tabs refetching on every write is four round trips for one screen of pixels.
  `LiveRefresh` refetches the moment the tab is shown.
- **ALL PARTIES does not nudge its counters on your own RSVP.** On the
  interested sort they are the sort key, and a locally nudged row would
  disagree with the server's order and break the keyset cursor. The button is
  instant; the number moves on the next load.
- **The chat lists refetch on topic traffic instead of rendering the payload.**
  Unread counts stay the server's, and a blocked author's line is filtered by
  the SELECT policy rather than trusted from a broadcast (see §1.15).
- **No polling, anywhere.** Topics where they already exist, then focus and
  resume. If something needs to be more live than that, the answer is a signal
  on a per-user topic (§1.17), not a timer.

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
- **Avatar URLs stay public; only listing the bucket needs a sign-in.**
  Decided in Phase 46 (2026-10-21), Option 1. The `avatars` bucket is public,
  so `/storage/v1/object/public/avatars/<user>/<file>` serves a known path to
  anyone, which is how the app draws avatars and how a shared link could show
  one. What closed is enumeration: the SELECT policy is `to authenticated`, so
  signed out nobody can list which users have a photo. A signed-in user still
  can; making avatars private would mean signed URLs on every avatar the app
  draws, for a photo the user chose to show everyone who opens their profile.
- **PostGIS's own functions and `geography_columns`/`geometry_columns` stay
  executable/readable by anon.** Phase 46 revoked PUBLIC from every function we
  own, and these are not ours: `supabase_admin` owns them, as it owns
  `spatial_ref_sys`, so a migration cannot revoke them. They hold no user data
  (the two views list geometry columns, i.e. the schema). `41_anon_access`
  leaves them out: the functions by owner, the views by name.
- **`spatial_ref_sys` has RLS off.** Cannot be fixed from a migration —
  `supabase_admin` owns it. Allowlisted by name in `13_hardening.test.sql`.
