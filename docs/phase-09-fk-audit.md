# Phase 9 — FK audit and deletion semantics

**Status: decision memo. No migration written. Awaiting sign-off on §3 and §6.**

Scope: every foreign key in `public`, classified `cascade` / `set null` /
`anonymise`, plus what happens to storage objects and `auth.users`. Written
against the schema as of `20260818175437`.

---

## 1. The headline finding

There are **36 FK constraints** in `public`. **23 of them point at
`public.profiles(id)`**, and of those **18 are `on delete cascade`**. The
remaining five are the `hidden_by` moderation columns, already `on delete set
null`.

`profiles.id` itself is `references auth.users on delete cascade`.

So the chain that exists today is:

```
delete from auth.users
  -> profiles                      (cascade)
     -> parties (as host)          (cascade)
        -> invitations, rsvps, party_posts, messages,
           party_reads, stories, sent_notifications,
           notification_jobs       (cascade, keyed on party_id)
           -> post_likes, post_comments, story_views (cascade)
     -> every row above again, keyed on the user
```

**Deleting one user today erases every message every other user ever wrote in
any party that user hosted.** That is not a Phase 9 design; it is what the
schema does right now if anyone runs a delete from the Supabase dashboard. It
is the single most important thing in this audit, and it argues for the
tombstone in §2 on blast-radius grounds alone, before GDPR enters the picture.

## 2. The mechanism: why a tombstone profile and not a null author

Your requirement — a deleted user's messages read as *Διαγραμμένος χρήστης*
rather than vanishing — has three possible implementations. Only one of them
is cheap.

### Option A — retained tombstone `profiles` row  ← recommended

Hard-delete `auth.users`; **keep** the `profiles` row, scrubbed: `deleted_at`
set, `username` replaced with a non-reusable opaque handle, consent flags
false, counters zeroed. Every `author_id` in the schema keeps pointing at a
real, still-selectable row. The client renders any profile with `deleted_at is
not null` as *Διαγραμμένος χρήστης*.

- Zero RLS policy changes. `is_blocked(uid, author_id)` still works, every
  `not null` constraint holds, every unique constraint holds.
- Zero RPC changes. **This is the decisive argument:** `get_feed`,
  `get_messages`, `get_party_chats`, `get_post_comments`, `get_party_stories`
  and `get_parties_near_user` all reach the author or host through an `inner
  join public.profiles`. They are invoker-rights, so a missing *or
  RLS-invisible* profile row silently drops the message from the result. Under
  Options B and C those six joins each need rewriting to `left join` plus a
  null-safe display path.
- Preserves per-user distinctness: two deleted users in the same thread stay
  two different speakers.
- **Cost, and it is a real one:** the `profiles.id -> auth.users` FK must be
  dropped, because a row cannot outlive the row it references and `id` is the
  primary key, so `on delete set null` is not available. We lose the database
  guarantee that every profile has an auth user. Mitigation in §6.4.

### Option B — nullable `author_id`, `on delete set null`

Rejected. Requires making `author_id` nullable on four tables, rewriting the
six inner joins above, and — worst — patching the `is_blocked` term in every
authored-content policy, because `is_blocked(uid, null)` returns false and the
`not is_blocked(...)` guard silently changes meaning. That is CLAUDE.md gotcha
#2's blast radius, spent on a cosmetic label. It also loses per-user
distinctness: every deleted user collapses to the same `null`.

### Option C — one shared "deleted user" sentinel profile

Rejected. Collides with `invitations (party_id, guest_id)`, `post_likes
(post_id, user_id)`, `follows (follower_id, followee_id)` and `story_views
(story_id, user_id)` the moment two deleted users touched the same object, and
merges distinct speakers into one.

## 3. Table-by-table recommendation

`KEEP` = row survives, user reference re-points at the tombstone.
`DELETE` = row is removed at hard-delete.
`PURGE NOW` = row is removed at **soft**-delete, i.e. immediately, not after
30 days.

| Table | Column | Today | Recommend | Why |
|---|---|---|---|---|
| `profiles` | `id -> auth.users` | cascade | **drop FK** | The tombstone must outlive the auth user (§2, §6.4). |
| `parties` | `host_id` | cascade | **KEEP** (+ cancel future) | Cascading here deletes every other user's messages and posts in that party. Past parties are a shared record and §7 keeps them indefinitely; parties that have not started yet get `status = 'cancelled'` so nobody shows up to a hostless event. |
| `messages` | `author_id` | cascade | **KEEP** | Your requirement. Thread continuity. Body retained — see decision §6.1. |
| `party_posts` | `author_id` | cascade | **KEEP** | Same argument as messages: a post carries a comment thread and a like count belonging to other people. Media handled in §4. |
| `post_comments` | `author_id` | cascade | **KEEP** | A comment thread with holes in it is the exact failure you flagged for chat. |
| `post_likes` | `user_id` | cascade | **DELETE** | Not content — an interaction signal with no reader. Deleting fires `post_likes_sync_count`, so `like_count` stays honest. |
| `stories` | `author_id` | cascade | **DELETE** | Ephemeral by construction: 24h TTL, already has a purge path. Nothing is preserved by keeping one. Media via `story_media_purges` (§4). |
| `story_views` | `user_id` | cascade | **DELETE** | Private viewing analytics about the deleted user. Fires `story_views_sync_count`. |
| `rsvps` | `user_id` | cascade | **DELETE** | Attendance is the user's own data, and v1 has no check-in record to preserve. Fires `rsvps_sync_counters`; note this decrements `going_count` on other people's past parties (§6.2). |
| `invitations` | `guest_id` | cascade | **DELETE** | A guest-list entry for someone who no longer exists. |
| `follows` | `follower_id`, `followee_id` | cascade ×2 | **DELETE both** | The graph edge is meaningless once one end is gone. Fires `follows_sync_counters`, so the surviving side's `follower_count` / `following_count` stay correct. |
| `blocks` | `blocker_id`, `blocked_id` | cascade ×2 | **KEEP both** | The one place cascade actively harms a *surviving* user. `is_blocked` is symmetric (`20260814094943:75-76`), so dropping either direction un-hides retained content the other party deliberately hid — B blocks A, A deletes, A's old messages reappear in B's chat. Retained as a pseudonymous edge to a tombstone. |
| `party_reads` | `user_id` | cascade | **DELETE** | Private read cursors, no other reader. |
| `reports` | `reporter_id` | cascade | **KEEP** | Moderation evidence. Cascade makes "report, then delete account" an erasure vector against the queue. GDPR Art. 17(3)(e) (legal claims) covers the retention, and the tombstone makes it pseudonymous. See §6.3. |
| `reports` | `target_id` (deleted user as target) | no FK | **KEEP** | Polymorphic by design; nothing dangles that the table does not already tolerate. |
| `user_devices` | `user_id` | cascade | **PURGE NOW** | Holds `last_location`, the highest-risk column in the schema, and a live push token. Both must die at soft-delete, not 30 days later. |
| `notification_jobs` | `user_id` | cascade | **PURGE NOW** | Pending jobs must not deliver to an account being deleted. |
| `sent_notifications` | `user_id` | cascade | **PURGE NOW** | Engine-internal ledger, no appeal path, already on a 90d clock. |
| `*.hidden_by` (×5) | — | set null | **leave as is** | Correct already. With the tombstone these resolve to the tombstone rather than firing `set null`, which is strictly better: the moderation audit trail survives, and the existing `hidden_by is null or hidden_at is not null` checks hold either way. |
| all `-> parties(id)` FKs (8) | — | cascade | **leave as is** | Correct. They cascade off *party* deletion, and we are no longer deleting parties. |
| `post_likes.post_id`, `post_comments.post_id`, `story_views.story_id` | — | cascade | **leave as is** | Correct. Object-scoped, not user-scoped. |
| `story_media_purges.story_id` | — | set null | **leave as is** | Correct and load-bearing: the purge queue must outlive the story it is purging. |

**Net change to FK definitions: eight constraints.** Drop `profiles.id ->
auth.users`; move `parties.host_id`, `messages.author_id`,
`party_posts.author_id`, `post_comments.author_id`, `reports.reporter_id` and
both `blocks` columns from `cascade` to `no action` — they are never deleted
now, and leaving a cascade in place is leaving a loaded gun for whoever next
runs a delete by hand. Everything marked DELETE keeps its existing cascade and
needs no migration at all: the erase function deletes the profile's dependents
explicitly, in order, before tombstoning.

## 4. Storage objects

Not FK-governed; the erase function has to do these by hand.

| Bucket | Path | Action |
|---|---|---|
| `avatars` | `{user_id}/...`, public bucket | **Delete the whole prefix.** A face, publicly served over the CDN, with no DB column referencing it today — nothing else will ever find it. |
| `story-media` | `{party_id}/{story_id}.{ext}` | Enqueue into `story_media_purges` and let `purge_story_media` do it. Do **not** add a second deletion path: gotcha #7 (deleting the `storage.objects` row orphans the bytes) is already encoded in exactly one place and should stay that way. |
| `post-media` | `{party_id}/...` | Delete the objects for posts authored by the deleted user and null `media_path`, but keep the post row — the body and its comment thread survive. Post media is photographs of people. |
| `party-covers` | `{party_id}/...` | **Keep** for retained parties — see §6.5. |

`auth.users` is hard-deleted last; `auth.identities`, sessions and refresh
tokens cascade from it inside the auth schema.

## 5. What happens when, exactly

**At soft-delete (T+0), in one transaction:** set `profiles.deleted_at`; purge
`user_devices`, `notification_jobs`, `sent_notifications`; cancel parties
hosted by the user that have not started; drop the user out of every
*discovery* surface. Content stays visible and attributed — the account is
recoverable for 30 days, and un-breaking a thread you just broke is worse than
leaving it intact.

**Recovery (T+0 .. T+30d):** signing in clears `deleted_at`. Devices and push
re-register naturally. Cancelled parties are **not** un-cancelled — guests
were already told.

**At hard-delete (T+30d, `pg_cron` -> edge function holding the service key):**
delete the DELETE-classified rows in FK order, purge storage per §4, scrub the
`profiles` row into a tombstone, delete `auth.users`.

**The tombstone profile must stay visible to the `profiles` SELECT policy.**
This is the one thing that will look wrong to a future reviewer and must not be
"fixed": adding `and deleted_at is null` to that policy re-breaks every thread
through the inner joins in §2, permanently. Discovery is suppressed in the
*discovery* paths — profile search, `get_parties_near_user`,
`accepts_invite_from` — not in the policy that content rendering depends on.
Same shape as gotcha #15: the filter has to go where the question is asked.

## 6. Decisions I need from you

1. **Message and post bodies: retain verbatim, or redact?** Recommend
   **retain**. Anonymising the author is what makes the thread readable;
   blanking the text leaves the same holes you asked to avoid. The residual
   risk is a user who typed their phone number into a chat, which redaction
   only partly addresses anyway.
2. **`going_count` on past parties.** Deleting rsvps decrements it, so a host
   sees last month's party quietly lose an attendee. Recommend accepting it —
   the alternative is retaining an attendance record for someone who asked to
   be erased.
3. **`reports.reporter_id`: retain (recommended) or cascade?** Retaining keeps
   the moderation queue honest; cascading is more privacy-maximal but makes
   account deletion an evidence-destruction path.
4. **Dropping the `profiles.id -> auth.users` FK.** Recommend replacing the
   lost guarantee with a pgTAP assertion that every profile with `deleted_at
   is null` has a matching `auth.users` row, so a genuine orphan still fails
   CI.
5. **Party covers on retained parties.** Recommend keeping them — a cover is
   about the event, not the host. Say the word and they go with the avatars.
6. **The tombstone username.** Recommend an opaque non-reusable handle
   (`deleted_<short hash>`) rather than the literal Greek string, so the
   case-insensitive unique index cannot collide and the display string stays a
   client concern. The second user to delete their account must not fail
   because the first one took the username.

## 7. Retention policy

| Data | Retention | Mechanism |
|---|---|---|
| `user_devices.last_location` | **24h**, and immediately on consent withdrawal | `purge_stale_locations` on a `*/10` cron plus the `location_consent` true->false trigger (`20260816083809`). Rounded to ~100m before it ever reaches disk. No history table, ever. |
| `sent_notifications` | **90 days**, hard delete | `purge_old_sent_notifications`, batched at 10k, same cron job. |
| Ended parties and their posts, messages, comments | **Indefinite** | Deliberate. A party is a shared record; the host's identity is anonymised on account deletion, the event is not erased. |
| Stories and their media | **24h** | `story-cleanup` cron; the bytes go via `purge_story_media` over pg_net. |
| Soft-deleted accounts | **30 days**, then hard delete | Phase 9. |
| Moderation reports | **Indefinite** | Art. 17(3)(e); reporter pseudonymised on their own deletion. |
