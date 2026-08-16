# MyParty — working rules

## Project shape

Flutter client (`myparty/`) + Supabase (Postgres 17/PostGIS, Auth, Storage,
Realtime, Edge Functions). Full design/rationale: `docs/backend-plan.md`.
Session-by-session task scripts: `docs/MyParty-ClaudeCode-Prompts.md`.

**Real today:** `profiles`/`parties`/`invitations`/`rsvps`/`follows`/`blocks`/
`party_posts`/`post_likes`/`post_comments`/`reports`/`messages`/`party_reads`/
`stories`/`story_views`/`user_devices`/`sent_notifications` tables with RLS;
`get_parties_near_user` RPC
(tier/zoom-filtered map query), called live from `MapScreen`;
`create_party_with_invites`; `get_feed`, `get_post_comments`, `get_messages`,
`get_party_chats` and `get_party_stories`/`get_story_rails` (all
keyset-paginated or time-bounded, all invoker-rights so RLS does the
filtering); `hide_post`/`hide_comment`/`hide_message`/`hide_story`; the
`can_access_party`, `can_chat_in_party`, `is_blocked`, `can_moderate_post`,
`can_moderate_comment`, `can_moderate_message`, `can_moderate_story` and
`has_location_consent` helpers; realtime group chat over **broadcast from
database** (trigger on
`messages` → topic `party:{uuid}`, authorized by RLS on `realtime.messages`);
the story upload handshake (`story_upload_target` → `story-media` edge
function → signed PUT → `confirm_story_upload`) and the `pg_cron`
`story-cleanup` job that hides expired stories **and** deletes their objects
over pg_net; the `pg_cron` `location-retention` job (`purge_stale_locations`
+ `purge_old_sent_notifications`); `handle_new_user` (every `auth.users`
insert gets a `profiles` row) + `check_username_available` and the
onboarding/consent columns;
`AuthService` (email signup/signin/signout via `supabase_flutter`);
`PartyRepository`, `SocialRepository`, `FeedRepository`, `ChatRepository` and
`StoryRepository` (all widget-level Supabase calls go through these — a widget
reaching for `Supabase.instance` directly is a bug, and also unbuildable under
`flutter test`).

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
`lib/state/mp_store.dart` (hype, interested, invited, map-visibility) and the
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

Phase 7a is **schema only** — nothing in Flutter touches `user_devices` yet
and there is no `DeviceRepository`. Token capture, the location-permission
pre-prompt and the upsert are 7c; the notification triggers and the
proximity queries are 7b. `mp_store.dart` is unchanged by this phase.

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
   authenticated;` *before* the intended grants (`20260816083807`). Only
   `user_devices` and `sent_notifications` have it today; the project-wide
   sweep is a Phase 10 item.

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
