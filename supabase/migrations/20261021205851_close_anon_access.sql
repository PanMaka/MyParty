-- Phase 46, part A: a signed-out caller reaches nothing in public.
--
-- Two holes, measured on a fresh reset before this migration:
--
--   * anon held SELECT on five tables: parties, follows, party_posts,
--     post_comments and post_likes. RLS still filtered the rows (a public
--     party, its posts and its likes, and the whole follow graph), but nothing
--     signed out needs any of them: the app signs in before its first query,
--     the hosting pages fetch nothing, and every edge function verifies a JWT.
--   * 66 of the 172 functions we own were executable by anon, 35 callable and
--     31 trigger functions. Not one was granted to anon by a migration: all
--     came from Postgres's own default, EXECUTE to PUBLIC on every new
--     function, which 20261004234903 left alone (27_explicit_grants scoped it
--     out). is_blocked(a, b) was among them, an answer to "has anyone blocked
--     anyone" for any pair; part B narrows that for signed-in callers too.
--
-- So: anon loses the five tables and every function we own loses PUBLIC.
--
-- The PUBLIC default itself stays. Postgres cannot revoke it for one schema
-- (per-schema default privileges only ADD to the global ones), and revoking it
-- globally strips EXECUTE from every function postgres creates anywhere:
-- pgTAP's tests.* helpers, and any extension a later migration installs. So
-- 41_anon_access asserts instead that no function we own in public is
-- executable by PUBLIC: function 173 fails CI until its migration revokes
-- PUBLIC and grants what it needs, the way 27_explicit_grants treats a table.
--
-- Then authenticated gets back exactly what reaches it as authenticated:
--
--   * the client's RPCs (and story_upload_target, which story-media calls
--     with the user's own token);
--   * every function a policy calls, because a policy expression runs as the
--     querying role -- the table, storage and realtime.messages policies;
--   * every function an INVOKER caller reaches with the caller's privileges:
--     the search RPCs, the map and invite RPCs, the user_devices trigger and
--     the profiles.username_search generated column.
--
-- What it does not get back is only ever called from definer bodies, which run
-- as postgres: the can_moderate_* helpers,
-- direct_thread_peer, placeholder_username, account_erasure_grace and
-- search_tokens. Trigger functions need no grant to fire (notify_party_host_rsvp
-- has had none since 20261014113213).
--
-- service_role needs nothing back: every RPC an edge function calls with the
-- service key already holds an explicit grant (gotcha 13), and service_role
-- bypasses RLS, so no policy helper runs as it.
--
-- Out of reach and recorded in backlog §3: PostGIS's own functions and the
-- geography_columns/geometry_columns views belong to supabase_admin, like
-- spatial_ref_sys (gotcha 9), so a migration cannot revoke them.


-- ------------------------------------------------------------------ tables
revoke select on public.parties, public.follows, public.party_posts,
  public.post_comments, public.post_likes from anon;


-- ------------------------------------------------------------------ functions
do $$
declare
  f regprocedure;
begin
  for f in
    select p.oid::regprocedure
    from pg_catalog.pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proowner = 'postgres'::regrole
      and not exists (select 1 from pg_catalog.pg_depend d
                      where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke execute on function %s from public', f);
  end loop;
end;
$$;

-- The client's RPCs.
grant execute on function
  public.check_username_available(text),
  public.create_party_with_invites(jsonb, uuid[]),
  public.hide_post(uuid, text),
  public.hide_comment(uuid, text),
  public.hide_message(uuid, text),
  public.hide_story(uuid, text),
  public.story_upload_target(uuid),
  public.confirm_story_upload(uuid),
  public.get_story_rails()
to authenticated;

-- Called by policies, which run as the querying role.
grant execute on function
  public.can_access_party(uuid),
  public.is_blocked(uuid, uuid),
  public.can_chat_in_party(uuid),
  public.is_direct_thread_member(uuid),
  public.can_view_direct_thread(uuid),
  public.can_send_direct_message(uuid),
  public.party_id_from_topic(text),
  public.direct_thread_id_from_topic(text),
  public.inbox_user_id_from_topic(text),
  public.party_id_from_host_topic(text)
to authenticated;

-- The topic builders, the parsers' inverses. Pure string functions of a uuid;
-- granted so the pgTAP round-trips run as the user who joins the topic.
grant execute on function
  public.party_topic(uuid),
  public.direct_thread_topic(uuid),
  public.inbox_topic(uuid),
  public.party_host_topic(uuid)
to authenticated;

-- Reached by invoker callers with the caller's privileges.
grant execute on function
  public.round_location(public.geography),
  public.search_normalize(text),
  public.search_prefix_upper(text),
  public.party_is_past(timestamptz, timestamptz, timestamptz)
to authenticated;
