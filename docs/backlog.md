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
added 1.25-1.29.

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
deleting what nothing points at. Same shape as 1.1, and now the same gap:
there is no "no cover" choice in the edit form.

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
  MapTiler is a processor here; name it. (The map tiles are CARTO's, which
  receive the tile coordinates of whatever map area is on screen: list CARTO
  too.)

*Why it is still open:* it is a legal document, not code; someone has to write
and own it. The text above is a checklist of what the schema actually does, not
the policy.

### 1.32 First and last name are missing from the account export

`AuthService.saveNames` writes `first_name`/`last_name` into the auth user
metadata (the username screen). `export_account_data` reads only `public`
tables, so the export has neither, which makes it an incomplete Art. 20
response. They are erased with the auth user, so erasure is not affected.

*Fix:* either move the names into an owner-read-only table, as Phase 41 did for
gender, or read `auth.users.raw_user_meta_data` inside the export (it is
definer, so it can).

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

Address search uses MapTiler's Geocoding API while the map tiles are CARTO's
`dark_all`. MapTiler's Terms of Service (read 2026-10-20) do not address this
either way: §4 restricts reselling/redistribution and commercial derivative
works, §6.1–6.4 cover attribution on *displayed MapTiler maps* (not shown here),
and §6.5 asks for attribution "as part of the database" when search results are
stored (done: the comment on `parties.address`). The wizard shows "Address
search is provided by MapTiler. © OpenStreetMap contributors" under the field.

*To do:* get MapTiler's written confirmation that their geocoding may be used
with a third-party (CARTO) basemap on the plan we are on, and whether storing
the chosen address permanently is within it. If not, the options are MapTiler
tiles (a tile switch was considered and declined in Phase 42) or another
geocoder.

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
- **`spatial_ref_sys` has RLS off.** Cannot be fixed from a migration —
  `supabase_admin` owns it. Allowlisted by name in `13_hardening.test.sql`.
