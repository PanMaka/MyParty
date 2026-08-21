# MyParty — working rules

## Project shape

Flutter client (`myparty/`) + Supabase (Postgres 17/PostGIS, Auth, Storage,
Realtime, Edge Functions). Full design/rationale: `docs/backend-plan.md`.
Session-by-session task scripts: `docs/MyParty-ClaudeCode-Prompts.md`.

**Real today:** `profiles`/`parties`/`invitations`/`rsvps`/`follows`/`blocks`/
`party_posts`/`post_likes`/`post_comments`/`reports`/`messages`/`party_reads`/
`stories`/`story_views`/`user_devices`/`sent_notifications`/
`notification_jobs` tables with RLS;
`get_parties_near_user` RPC
(tier/zoom-filtered map query, `p_limit` defaulting to 200 and clamped to
[1, 500], `authenticated`-only since `20260821175831`), called live from
`MapScreen` through `PartyRepository.fetchPartiesNearUser`;
`create_party_with_invites`; `get_feed`, `get_post_comments`, `get_messages`,
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

**Mock today, ships real in later phases:** everything left in
`lib/state/mp_store.dart` (hype, interested, invited) and the
const `mpParties` list in `lib/models/` — `PartyCard` and `PartyDetailSheet`
still read from it instead of Supabase. Note `mpParties` keys are strings like
`'taratsa'`, not uuids, which is why the report action is wired into
`MapPinSheet` (a real `parties` row) and not `PartyDetailSheet`, and why
*both* of `PartyDetailSheet`'s "Group chat" button and its story tiles are
placeholders while `ChatScreen` and `StoryViewerScreen` are real — it has no
uuid to hand either of them. Real chat entry points are `MessagesScreen`,
`EventsScreen`'s RSVP rows and the host wizard's done screen; `MapPinSheet`
deliberately has none, since a map-pin viewer is exactly the passer-by
`can_chat_in_party` excludes. Real story entry points are the feed's story
rail and its "+ Story" picker.

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
  filter in `SocialRepository.searchProfiles` that is UX, not enforcement).
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
    5km branch has none. So `parties_location` reads as an unused index in
    the advisor and is not: the fix is to make the query able to reach it,
    not to drop it. Numbers, plans and the proposed policy rewrite (hoist
    `is_private`/`host_id` out of the helper into the policy, so a public
    party short-circuits without a function call) are in
    `docs/phase-10-hardening-audit.md` §5. **Not applied** — it is the
    policy with the widest blast radius in the schema.

20. **A `language sql` set-returning function is inlined only if it is not
    SECURITY DEFINER, not VOLATILE, and has no SET clause.** All eight read
    RPCs are VOLATILE by default, so none has ever been inlined —
    `explain select * from get_parties_near_user(…)` prints one line,
    `Function Scan`, while the identical body declared STABLE prints a
    37-line plan. That is why `20260819095452` could pin `search_path` on
    all eight for free: it forecloses inlining, and there was none to lose.
    Worth re-pricing if gotcha 19's fix ever lands.

21. **`get_parties_near_user` filters on `ends_at` and never on `starts_at`,
    so a party with a null `ends_at` is on the map forever.** The predicate is
    `p.status = 'published' and (p.ends_at is null or p.ends_at > now())`.
    `ends_at` is nullable with no default and the host wizard does not require
    it, so "a party that already happened" is not a state the map query can
    currently recognise — a finished party with no end time keeps its pin, and
    keeps it at full tier weight, indefinitely.
    **Open decision, deliberately not fixed.** The obvious repair — `or
    (p.ends_at is null and p.starts_at > now() - interval 'N hours')` — needs
    a number nobody has chosen, and it is the wrong kind of guess: an
    all-nighter and a Sunday afternoon barbecue disagree about N by a factor
    of six, and picking wrong either drops live parties off the map or leaves
    dead ones on it. The honest fixes are to make `ends_at` required at
    creation, or to add an explicit lifecycle transition to `party_status`
    (there is already a `cancelled` value and no `ended` one) — both are
    product decisions with a migration behind them, not a where-clause tweak.
    Until then: **anything that writes a past party must set `ends_at`**, which
    is why every past party in `seed.sql` carries one and says so in a comment.
    The failure is silent and cumulative — nothing errors, the map just slowly
    fills with parties that are over.

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

    - **Time filtering is free, and better than free.** The Τώρα / Αργότερα /
      Το ΣΚ chips can push `starts_at`/`ends_at` predicates into
      `get_parties_near_user` and they will cut the row count *before*
      `can_access_party` is called on each row — measured at 35× on the map
      query body, and the same mechanism that makes the 500km tier (208ms,
      leakproof `party_tier` filter first) six times faster than the 5km tier
      (995ms, no pre-filter at all).
    - **Search must wait for the policy rewrite.** An `ilike` on
      `parties.title` or `parties.area` has exactly `st_dwithin`'s failure
      mode: it sits behind the barrier, seq-scans, and cannot reach an index —
      so adding `pg_trgm` or a `tsvector` column first would buy nothing, and
      measuring the search against a 995ms floor would teach the wrong lesson
      about it. **§5 of `docs/phase-10-hardening-audit.md` goes before search,
      not after.** Sequencing decided 2026-08-21.

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
