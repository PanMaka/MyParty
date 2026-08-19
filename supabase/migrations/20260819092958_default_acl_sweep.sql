-- Phase 10, item: revoke the default ACL project-wide (backend-plan.md 10).
--
-- Supabase ships `alter default privileges in schema public grant all on
-- tables to anon, authenticated, service_role`. "All" on a table is eight
-- privileges, and the four that are not data privileges -- TRUNCATE,
-- REFERENCES, TRIGGER, MAINTAIN -- are handed out unconditionally to every
-- table the moment it is created. Nothing in Phases 1-9 asked for them.
--
-- Why this is hardening and not an incident:
--
--   * None of the four reads or writes a row, so no RLS policy is bypassed
--     and nothing becomes readable that was not already.
--   * PostgREST exposes no route to any of them. There is no HTTP verb that
--     issues TRUNCATE, and CREATE TRIGGER / ALTER TABLE ... ADD FOREIGN KEY
--     are DDL, which PostgREST does not emit at all.
--
-- Why it is still worth a migration:
--
--   * RLS does not mediate TRUNCATE. A table with perfect policies is still
--     one `truncate` away from empty for anybody holding the privilege, and
--     the privilege is the only thing standing there. If a future phase ever
--     routes raw SQL through an authenticated connection -- a SQL console, an
--     admin tool, a `security invoker` function that interpolates -- the blast
--     radius of a mistake is the whole schema rather than one table.
--   * REFERENCES lets a role point a foreign key at your table, which pins
--     rows against deletion. That one is reachable by anybody who can run DDL
--     as `authenticated`.
--
-- 7a already did this for user_devices, sent_notifications and
-- notification_jobs (20260816083807). This finishes the job for the fifteen
-- tables created before it, and -- the part that matters more than the
-- fifteen -- stops the default privileges from re-granting on table sixteen.
--
-- Targeted revokes, not `revoke all` + re-grant. Several of these tables carry
-- COLUMN-scoped grants that exist for load-bearing reasons (profiles UPDATE,
-- stories INSERT, messages INSERT, user_devices' split insert/update lists --
-- CLAUDE.md gotchas #8 and #12). `revoke all on table` does not touch column
-- privileges, but re-granting by hand after a blanket revoke is exactly how
-- one of those asymmetries gets flattened by accident. Naming the four
-- privileges cannot.


-- ============================================================
-- 1. The tables that already exist.
--
-- Every table in public except spatial_ref_sys, which belongs to PostGIS and
-- is dealt with at the bottom. The three 7a already swept are listed anyway:
-- revoking a privilege a role does not hold is a no-op, and a list that is
-- "every table" is one a future reader can verify by eye against \dt.
-- ============================================================
revoke truncate, references, trigger, maintain
  on table
    public.account_erasures,
    public.blocks,
    public.follows,
    public.invitations,
    public.messages,
    public.notification_jobs,
    public.parties,
    public.party_posts,
    public.party_reads,
    public.post_comments,
    public.post_likes,
    public.profiles,
    public.reports,
    public.rsvps,
    public.sent_notifications,
    public.stories,
    public.story_media_purges,
    public.story_views,
    public.user_devices
  from anon, authenticated;


-- ============================================================
-- 2. The sequences.
--
-- The default privileges grant `usage, select, update` on sequences too, and
-- UPDATE on a sequence is what setval() checks. Rewinding
-- notification_jobs_id_seq would hand out primary keys that already exist.
--
-- Not currently reachable: setval lives in pg_catalog, and PostgREST only
-- exposes functions in the schemas listed in config.toml. That is an argument
-- about today's routing, not about the privilege, which is the thing this
-- migration is here to remove. USAGE stays revoked-by-omission for the same
-- reason it was never needed: all three sequences are driven by identity
-- columns on tables the client cannot insert into.
-- ============================================================
revoke usage, select, update
  on sequence
    public.notification_jobs_id_seq,
    public.sent_notifications_id_seq,
    public.story_media_purges_id_seq
  from anon, authenticated;


-- ============================================================
-- 3. The generator.
--
-- Without this the sweep above is a snapshot: table sixteen arrives with the
-- default ACL and the audit is stale the day it is written. `alter default
-- privileges` is matched on (grantor, schema, object type), and the grant we
-- are undoing was issued by supabase_admin -- but this statement runs as
-- `postgres`, so it can only alter postgres's own defaults. That is enough:
-- pg_default_acl already carries a postgres/public/tables entry (Supabase
-- creates one), and the effective default for a table created by `postgres`
-- is postgres's entry, not supabase_admin's. Every table in this schema is
-- created by migrations running as postgres.
--
-- service_role is deliberately left alone in all three statements. It holds
-- the service key, bypasses RLS by design, and is the identity the erasure and
-- notification workers run as -- TRUNCATE is not a boundary for a role that
-- can already DELETE every row. Revoking it there would buy nothing and would
-- eventually break a worker.
-- ============================================================
alter default privileges in schema public
  revoke truncate, references, trigger, maintain on tables from anon, authenticated;

alter default privileges in schema public
  revoke usage, select, update on sequences from anon, authenticated;


-- ============================================================
-- 4. public.spatial_ref_sys -- NOT fixed here, deliberately.
--
-- The Supabase linter reports it as an ERROR (`rls_disabled_in_public`): the
-- table sits in an API-exposed schema with RLS off and, unlike ours, it
-- carries real data privileges -- anon holds INSERT, UPDATE and DELETE on it
-- straight from PostGIS's own grants. That is genuinely reachable over
-- PostgREST.
--
-- It cannot be fixed from a migration. The table is owned by supabase_admin,
-- its grants were issued by supabase_admin, and `postgres` is neither a
-- member of that role nor a superuser (checked: pg_auth_members has no edge).
-- Both `alter table public.spatial_ref_sys enable row level security` and
-- `revoke ... from anon` fail with 42501 as the migration role. Attempting
-- them here would make every `supabase db reset` fail.
--
-- The root cause is that PostGIS is installed in `public` rather than
-- `extensions` (linter: `extension_in_public`). Moving it is not a hardening
-- change: `alter extension postgis set schema extensions` rewrites the
-- resolution of every geography column, index operator class and st_* call in
-- the schema, and this one has two geography columns, two GiST indexes and a
-- proximity engine whose query plans are asserted by script. That is its own
-- decision, with its own migration and its own re-measurement.
--
-- What is actually at stake: spatial_ref_sys is a lookup table of coordinate
-- system definitions. Corrupting it breaks st_transform for SRIDs we do not
-- use -- everything here is 4326, whose row is also re-inserted by any PostGIS
-- upgrade. The exposure is bloat and vandalism, not data disclosure.
--
-- Documented in docs/phase-10-hardening-audit.md and allowlisted by name in
-- supabase/tests/database/13_hardening.test.sql, so the exception is one
-- someone has to delete on purpose.
-- ============================================================
