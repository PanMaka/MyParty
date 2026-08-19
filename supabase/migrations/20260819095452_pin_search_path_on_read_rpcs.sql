-- Phase 10, item 1: the one Supabase linter finding that is still true of
-- today's schema.
--
-- `function_search_path_mutable` on the eight `language sql` read RPCs. Every
-- security definer function in this project already carries `set search_path
-- = ''` (CLAUDE.md rule 3); these eight are security INVOKER and were never
-- given one, so they resolve `parties`, `st_dwithin`, `geography` and the rest
-- against whatever search_path the caller happens to be sitting in.
--
-- How bad is it, honestly: not very. Hijacking a name requires creating an
-- object in a schema that comes earlier in the caller's path, and neither
-- `anon` nor `authenticated` holds CREATE on any schema in this database --
-- only USAGE on `public` and `extensions` (checked: nspacl). PostgREST also
-- sets a fixed search_path per request. So this is defence in depth against a
-- future where one of those two facts changes, not a hole standing open today.
-- It is still worth closing, because "no role can currently create a schema"
-- is a much more fragile invariant than "this function pins its own names".
--
--
-- WHY `public, extensions` AND NOT `''`
--
-- Rule 3 says `''` plus fully-qualified references, and that rule is about
-- SECURITY DEFINER functions, where an unqualified name resolves with the
-- owner's privileges and a hijack is a privilege escalation. These are
-- invoker: a hijacked name would run as the caller, with the caller's rights,
-- so the exposure is confusion, not escalation.
--
-- `''` would mean rewriting eight function bodies to qualify every reference
-- -- including the PostGIS operators and casts in get_parties_near_user, whose
-- geography type lives in `public` because PostGIS is installed there. That is
-- a lot of retyping of load-bearing SQL for no additional protection over
-- pinning, and the retyping is where a bug would come from. `round_location`,
-- `enforce_location_privacy` and `upsert_user_device` already use exactly this
-- pinned form, so it is not a new pattern here.
--
-- ALTER rather than CREATE OR REPLACE for the same reason: this migration
-- changes one property and cannot accidentally change a query.
--
--
-- WHAT IT COSTS, MEASURED
--
-- A `language sql` set-returning function is inlined into its caller only if
-- it is not SECURITY DEFINER, is not VOLATILE, and has no SET clause. Adding a
-- SET clause therefore forecloses inlining -- which sounds expensive until you
-- check whether these functions were ever inlined. They were not: all eight
-- are VOLATILE (nobody declared otherwise, and VOLATILE is the default), so
-- the planner has treated every one of them as an opaque Function Scan since
-- the day it was written.
--
-- scripts/loadtest_map_query.sh prices all three states of
-- get_parties_near_user at 10k parties / 50k rsvps, as an authenticated
-- viewer, 100 samples each:
--
--     zoom    as shipped   search_path pinned   STABLE + inlined
--     5km      995 ms p50        992 ms              983 ms
--     50km     230 ms p50        229 ms              227 ms
--     500km    208 ms p50        209 ms              206 ms
--
-- The p95 deltas are +9.8ms, -13.7ms and +9.1ms -- they do not even agree on a
-- sign. Pinning is free, and so is the inlining it forecloses, because at this
-- query's real cost neither is measurable. See the audit doc for what IS
-- measurable, which is none of this.
-- ============================================================

alter function public.get_parties_near_user(double precision, double precision, double precision)
  set search_path = public, extensions;

alter function public.get_feed(timestamptz, uuid, integer)
  set search_path = public, extensions;

alter function public.get_messages(uuid, timestamptz, uuid, integer)
  set search_path = public, extensions;

alter function public.get_party_chats()
  set search_path = public, extensions;

alter function public.get_party_stories(uuid, timestamptz, uuid, integer)
  set search_path = public, extensions;

alter function public.get_post_comments(uuid, timestamptz, uuid, integer)
  set search_path = public, extensions;

alter function public.get_profile_stats(uuid)
  set search_path = public, extensions;

alter function public.get_story_rails()
  set search_path = public, extensions;
