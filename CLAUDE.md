# MyParty — working rules

## Project shape

Flutter client (`myparty/`) + Supabase (Postgres 17/PostGIS, Auth, Storage,
Realtime, Edge Functions). Full design/rationale: `docs/backend-plan.md`.
Session-by-session task scripts: `docs/MyParty-ClaudeCode-Prompts.md`.

**Real today:** `profiles`/`parties`/`invitations`/`rsvps`/`follows`/`blocks`/
`party_posts`/`post_likes`/`post_comments`/`reports` tables with RLS;
`get_parties_near_user` RPC (tier/zoom-filtered map query), called live from
`MapScreen`; `create_party_with_invites`; `get_feed` and `get_post_comments`
(both keyset-paginated, both invoker-rights so RLS does the filtering);
`hide_post`/`hide_comment`; the `can_access_party`, `is_blocked`,
`can_moderate_post` and `can_moderate_comment` helpers; `handle_new_user`
(every `auth.users` insert gets a `profiles` row) + `check_username_available`
and the onboarding/consent columns; `AuthService` (email signup/signin/signout
via `supabase_flutter`); `PartyRepository`, `SocialRepository` and
`FeedRepository` (all widget-level Supabase calls go through these — a widget
reaching for `Supabase.instance` directly is a bug, and also unbuildable
under `flutter test`).

The social graph is **follows-only and asymmetric** — there is no
`friendships` table and no `are_friends` helper, deliberately. See
`docs/backend-plan.md` 3.1, which was reversed on purpose; don't reintroduce
one without an explicit product decision. A follow grants **no** private-party
visibility; that comes from `invitations` alone.

**Mock today, ships real in later phases:** everything left in
`lib/state/mp_store.dart` (hype, interested, invited, map-visibility) and the
const lists in `lib/models/` (`mpParties`, `mpStory`, `mpSeedTaratsaChat`) —
`ChatScreen`, `StoryViewerScreen`, `PartyCard` and `PartyDetailSheet` still
read from these instead of Supabase. Note `mpParties` keys are strings like
`'taratsa'`, not uuids, which is why the report action is wired into
`MapPinSheet` (a real `parties` row) and not `PartyDetailSheet`.

**Cross-phase gotchas worth remembering:**

1. The `profiles` SELECT policy is no longer `using (true)` — it is
   block-filtered. Any function that reads `public.profiles` to answer a
   *global* question (uniqueness, counts, existence) must be
   `security definer`, or it will silently return the caller's filtered view
   as if it were the whole table. That is exactly how
   `check_username_available` started reporting taken usernames as free
   (`20260814104618`).
2. `can_access_party` answers about the party's **host** only. Any table
   holding authored content (`party_posts`, `post_comments`, and the coming
   `stories`/`messages`) needs its own `is_blocked` term on the **author** —
   a blocked user can have posted on a public party hosted by someone else.
3. **A soft-delete cannot be a client UPDATE.** On UPDATE, Postgres applies
   the SELECT policy to the *new* row whenever the statement needs read
   access, so setting `hidden_at` on a table whose SELECT policy says
   `hidden_at is null` always fails with "new row violates row-level
   security policy". Use a `security definer` RPC (`hide_post`,
   `hide_comment`) and leave the table with no UPDATE grant at all.
4. Table privileges are checked whether or not a `where` clause could ever
   be true. An RPC that merely *mentions* a table the caller lacks SELECT on
   errors out instead of returning zero rows — which is why `get_feed` has
   `execute` revoked from `anon` rather than relying on its
   `auth.uid() is not null` guard.

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
