-- Phase 10, item 2: the index audit.
--
-- The rule as stated is "every FK used in a join needs an index; every policy
-- with a subquery needs the matching index". Applied literally to this schema
-- that produces 36 foreign keys and a shrug, because most of them are already
-- covered by a primary key or a unique constraint that happens to lead with
-- the right column. The question worth asking is narrower: which foreign key
-- has a real query behind it that no index can answer.
--
-- Two workloads answer it, and neither is a screen:
--
--   1. `complete_account_erasure` (20260819083207). It is the only code path
--      in the schema that filters EVERY child table by one user id, and it
--      runs from a cron under the service key -- so when it seq-scans, there
--      is no user waiting on it and nothing in the app gets slower. It would
--      simply cost more every month, silently, forever. Of its ten deletes,
--      eight land on an index today. Two do not: invitations.guest_id and
--      party_reads.user_id.
--
--   2. `export_account_data` (20260819083431). Same shape, opposite verb:
--      `where author_id = v_uid order by created_at` against party_posts,
--      post_comments and messages. messages is the table with the highest row
--      count in this schema by a wide margin, and a GDPR subject-access
--      request currently reads all of it.
--
-- And one cascade that a user can trigger by hand, which is the only entry
-- here that is a latency problem rather than a cost problem: `parties` carries
-- a client-facing DELETE policy ("Hosts can delete own parties"), and both
-- notification_jobs.party_id and sent_notifications.party_id cascade off it
-- unindexed. Deleting one party scans both queue tables end to end while the
-- host waits.
--
-- What is NOT added here, and why, is at the bottom -- an audit that only says
-- what it added is half an audit.


-- ============================================================
-- 1. The erasure engine's two seq scans.
--
-- Plain single-column: both are equality filters with no ordering and no
-- second predicate. No partial clause either -- erasure deletes every row the
-- user has, hidden or not.
-- ============================================================
create index invitations_guest_id_idx
  on public.invitations (guest_id);

create index party_reads_user_id_idx
  on public.party_reads (user_id);


-- ============================================================
-- 2. The party-delete cascade.
--
-- notification_jobs already has (user_id, created_at) and a pair of partial
-- status indexes; sent_notifications has (user_id, party_id, kind) unique and
-- (sent_at). Both lead with user_id or a timestamp, and the cascade asks about
-- party_id, so neither can serve it -- the leading-column mismatch that
-- Phase 8 hit on rsvps.
-- ============================================================
create index notification_jobs_party_id_idx
  on public.notification_jobs (party_id);

create index sent_notifications_party_id_idx
  on public.sent_notifications (party_id);


-- ============================================================
-- 3. The export's three author scans.
--
-- Composite (author_id, created_at) rather than bare (author_id): the export
-- reads `where author_id = ? order by created_at`, so the second column turns
-- a sort into an ordered walk. ASCENDING, unlike every other created_at index
-- in this schema -- the feed indexes are `created_at desc, id desc` because
-- they serve keyset pagination newest-first (CLAUDE.md #5), and the export
-- reads a life oldest-first. A btree can be walked backwards at the same cost,
-- so the direction is a readability choice about which query the index is FOR,
-- not a performance one.
--
-- No `where hidden_at is null` predicate, deliberately, and it is the same
-- argument as the story rate-limit index: the export exists to hand the
-- subject everything held about them, and a row a moderator hid is still a row
-- held about them -- it ships with hidden_at and hidden_reason attached. A
-- partial index would silently drop exactly the rows most worth exporting.
--
-- These three do not shadow the existing feed indexes: party_posts and
-- post_comments are read party-first and post-first everywhere else, messages
-- party-first. author_id leads nothing today.
-- ============================================================
create index party_posts_author_created_idx
  on public.party_posts (author_id, created_at);

create index post_comments_author_created_idx
  on public.post_comments (author_id, created_at);

create index messages_author_created_idx
  on public.messages (author_id, created_at);


-- ============================================================
-- 4. Deliberately NOT indexed. Allowlisted by name in
--    supabase/tests/database/13_hardening.test.sql, so removing one of these
--    exceptions is a decision somebody makes on purpose.
--
--  * party_posts.hidden_by, post_comments.hidden_by, post_likes.hidden_by,
--    messages.hidden_by, stories.hidden_by -- `on delete set null` to
--    profiles. Two reasons, either sufficient: the column is null on
--    essentially every row (it is written only by a moderation action), and
--    since Phase 9 the parent is a tombstone that is never deleted, so the
--    cascade these would serve cannot fire at all. An index whose only job is
--    a DELETE that the schema forbids is pure write amplification on five
--    insert paths.
--
--  * story_media_purges.story_id -- `on delete set null` to stories, and
--    stories are hidden, never deleted (CLAUDE.md: UGC deletes are soft). The
--    queue is read by `created_at where completed_at is null` and by request
--    id; nothing looks a purge up by its story.
--
--  * account_erasures.user_id -- covered: it IS the primary key.
--
--  * invitations.party_id, rsvps.party_id/user_id, post_likes.post_id/user_id,
--    story_views.story_id/user_id, follows both sides, blocks both sides,
--    parties.host_id, stories.party_id/author_id, user_devices.user_id,
--    notification_jobs.user_id, sent_notifications.user_id, and the rest --
--    already covered by a primary key, unique constraint or index whose
--    leading columns match. The audit's job was to find the gaps, and this
--    line is the part that was already fine.
-- ============================================================
