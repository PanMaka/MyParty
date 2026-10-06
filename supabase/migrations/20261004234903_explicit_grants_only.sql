-- Phase 20: anon and authenticated hold exactly the grants a migration names.
--
-- What broke. Supabase's postgres image runs
--   alter default privileges in schema public grant all on
--     tables / functions / sequences to anon, authenticated, service_role
-- while it initialises, and the image the CLI pulls today (17.11.0.002)
-- applies that to every table our migrations create. The image this schema
-- was written against evidently did not: 20260812115436 exists only to grant
-- authenticated SELECT/UPDATE on profiles and parties, which no project would
-- write if the default already handed out ALL. Every migration since wrote
-- `grant select …` / `grant insert (cols) …` on the assumption that the grant
-- it names is the whole grant.
--
-- On the current image it is not. A fresh `supabase db reset` left anon with
-- SELECT/INSERT/UPDATE/DELETE on 16 of 22 tables and EXECUTE on every RPC,
-- and 26 pgTAP assertions went red -- including ones that had not changed
-- since the day they passed (06_group_chat's "anon has no select grant on
-- messages" fails on its own commit, 7a3f025, against this image). The six
-- tables that stayed clean are the ones whose migration happened to start
-- with `revoke all … from anon, authenticated` (gotcha 9's habit).
--
-- RLS was never bypassed: a grant only lets a statement reach the policy.
-- What was lost is the layer underneath it -- column-scoped writes
-- (gotchas 8 and 12: last_location_at, media_path, like_count), "no UPDATE
-- grant at all" as the reason soft deletes go through hide_* RPCs (gotcha 3),
-- and anon being refused get_feed/get_messages outright (gotcha 4).
--
-- The fix does not depend on which image runs it:
--
--   1. Close the defaults, so table N+1 starts with nothing.
--   2. Revoke everything anon/authenticated hold on every non-extension
--      table, view, sequence and function in public.
--   3. Re-grant the allow-list. It was not written by hand: it is the ACL
--      that the migrations up to 20261003143423 produce on a database whose
--      defaults grant nothing, captured from exactly such a reset -- a state
--      the whole pgTAP suite passes against. 27_explicit_grants.test.sql
--      asserts the result row for row.
--
-- Hosted gets the same migration and converges to the same ACL whatever its
-- image did, which is the point of writing the end state rather than a diff.
--
-- Notes on the mechanics:
--   * `revoke … on table` also revokes that table's COLUMN privileges, so the
--     column-scoped grants are re-issued below along with everything else.
--   * PUBLIC is left alone. A function's EXECUTE-to-PUBLIC is Postgres's own
--     default, not Supabase's, and every migration that needed it gone already
--     revoked it explicitly (gotcha 13); 13_hardening covers those.
--   * service_role is left alone, for the reason 20260819092958 gives.
--   * Extension members (PostGIS's views and functions, spatial_ref_sys) are
--     skipped: they are not ours to re-grant, and gotcha 9 already records
--     that spatial_ref_sys cannot be touched from a migration.

-- ============================================================
-- 1. Defaults: nothing for anon/authenticated on anything created from here.
-- ============================================================
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;

-- ============================================================
-- 2. Strip what the defaults already handed out.
-- ============================================================
do $$
declare
  r record;
begin
  for r in
    select c.oid::regclass as rel, c.relkind
    from pg_catalog.pg_class c
    where c.relnamespace = 'public'::regnamespace
      and c.relkind in ('r', 'p', 'v', 'm', 'S')
      and not exists (
        select 1 from pg_catalog.pg_depend d
        where d.classid = 'pg_catalog.pg_class'::regclass
          and d.objid = c.oid and d.deptype = 'e')
  loop
    if r.relkind = 'S' then
      execute format('revoke all on sequence %s from anon, authenticated', r.rel);
    else
      execute format('revoke all on table %s from anon, authenticated', r.rel);
    end if;
  end loop;

  for r in
    select p.oid::regprocedure as fn
    from pg_catalog.pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and not exists (
        select 1 from pg_catalog.pg_depend d
        where d.classid = 'pg_catalog.pg_proc'::regclass
          and d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke all on function %s from anon, authenticated', r.fn);
  end loop;
end
$$;

-- ============================================================
-- 3. The allow-list. Adding a grant from here on means a new migration AND a
--    new row in 27_explicit_grants.test.sql -- that test fails on any grant
--    it does not list, which is how this cannot silently widen again.
-- ============================================================

-- Tables
grant delete, insert, select on public.blocks to authenticated;
grant select on public.follows to anon;
grant delete, insert, select on public.follows to authenticated;
grant insert, select on public.invitations to authenticated;
grant select on public.messages to authenticated;
grant select on public.parties to anon;
grant delete, insert, select, update on public.parties to authenticated;
grant select on public.party_posts to anon;
grant select on public.party_posts to authenticated;
grant select on public.party_reads to authenticated;
grant select on public.party_search_tokens to authenticated;
grant select on public.post_comments to anon;
grant select on public.post_comments to authenticated;
grant select on public.post_likes to anon;
grant delete, select on public.post_likes to authenticated;
grant select on public.profiles to anon;
grant select, update on public.profiles to authenticated;
grant select on public.reports to authenticated;
grant delete, insert, select, update on public.rsvps to authenticated;
grant select on public.stories to authenticated;
grant insert, select on public.story_views to authenticated;
grant select on public.user_birthdates to authenticated;
grant delete, select on public.user_devices to authenticated;

-- Column-scoped writes (gotchas 8 and 12)
grant insert (author_id, body, id, party_id) on public.messages to authenticated;
grant insert (author_id, body, id, media_type, party_id) on public.party_posts to authenticated;
grant insert (last_read_at, party_id, user_id) on public.party_reads to authenticated;
grant update (last_read_at) on public.party_reads to authenticated;
grant insert (author_id, body, id, post_id) on public.post_comments to authenticated;
grant insert (post_id, user_id) on public.post_likes to authenticated;
grant insert (id, reason, reporter_id, target_id, target_type) on public.reports to authenticated;
grant insert (author_id, content_type, id, party_id) on public.stories to authenticated;
grant insert (id, last_location, platform, push_token, user_id) on public.user_devices to authenticated;
grant update (last_location, platform, push_token) on public.user_devices to authenticated;

-- RPCs
grant execute on function public.cancel_account_deletion() to authenticated;
grant execute on function public.confirm_post_upload(uuid) to authenticated;
grant execute on function public.export_account_data() to authenticated;
grant execute on function public.get_feed(timestamp with time zone,uuid,integer) to authenticated;
grant execute on function public.get_messages(uuid,timestamp with time zone,uuid,integer) to authenticated;
grant execute on function public.get_my_hosted_parties(integer) to authenticated;
grant execute on function public.get_parties_list(party_sort,integer,integer,bigint,timestamp with time zone,uuid) to authenticated;
grant execute on function public.get_parties_near_user(double precision,double precision,double precision,integer,text,text) to authenticated;
grant execute on function public.get_party_chats() to authenticated;
grant execute on function public.get_profile_stats(uuid) to authenticated;
grant execute on function public.has_location_consent(uuid) to authenticated;
grant execute on function public.is_party_host(uuid) to authenticated;
grant execute on function public.map_search_box(double precision,double precision,double precision) to authenticated;
grant execute on function public.party_end_grace() to authenticated;
grant execute on function public.party_is_private(uuid) to authenticated;
grant execute on function public.party_time_window(text,text,timestamp with time zone) to authenticated;
grant execute on function public.post_upload_target(uuid) to authenticated;
grant execute on function public.request_account_deletion() to authenticated;
grant execute on function public.rsvp_status_allowed(uuid,rsvp_status) to authenticated;
grant execute on function public.search_parties(text,integer) to authenticated;
grant execute on function public.search_profiles(text,integer) to authenticated;
grant execute on function public.upsert_user_device(text,text,double precision,double precision) to authenticated;
