-- Phase 11: the profile's party sections become one list, in two groups.
--
-- Replaces two client-side queries with one server-side answer:
--
--   * ΩΣ ΔΙΟΡΓΑΝΩΤΡΙΑ -- `fetchHostedParties(window: upcoming)`
--   * ΤΟ ΙΣΤΟΡΙΚΟ ΜΟΥ -- `fetchAttendedParties()`, which is deleted with this
--     change. It read `rsvps` with an embedded `parties!inner(...)` and then
--     sorted in Dart, because PostgREST's `order` on an embedded resource
--     sorts WITHIN the embed rather than the top-level rows. That workaround
--     is gone rather than generalised.
--
-- Both groups here are about HOSTING. The list no longer answers "where have
-- you been", only "what have you thrown", which is why it touches `parties`
-- and never `rsvps`.
--
--
-- WHY THIS IS A FUNCTION AND NOT TWO `.eq()` CALLS
--
-- The two groups need opposite sort directions -- upcoming soonest-first so
-- the next thing you host is at the top, past most-recent-first so the thing
-- you just threw is. PostgREST cannot express that in one request, so the
-- client would have to make two round trips or sort one of them in Dart.
--
-- The stronger reason is that `is_upcoming` is computed from `now()`, and
-- there are two clocks. If the client partitioned on `DateTime.now()`, a party
-- starting within the round trip could be fetched as upcoming and rendered as
-- past, or the reverse -- a phone with a skewed clock would disagree with the
-- server permanently. Here one clock decides both the ORDER and the GROUP, in
-- the same statement, so they cannot disagree with each other either.
--
-- `starts_at` and not `ends_at`, matching every other list in the app. The
-- nullable-`ends_at` question (CLAUDE.md gotcha 21) is a real open decision
-- about when a party is over, and this function deliberately does not settle
-- it by accident: "starts in the future" is a fact about a column that is NOT
-- NULL, whereas "has ended" is not currently answerable for a party whose host
-- never set an end time.
--
--
-- WHY IT TAKES NO USER ID
--
-- `p_limit` and nothing else. A `p_user_id` parameter would be a function that
-- is only correct when the caller passes their own uuid -- it would type-check,
-- run, and return perfectly plausible rows for anybody else. That is CLAUDE.md
-- gotcha 11 in mirror image, and the fix is the same one: make the wrong
-- question unrepresentable rather than documented.
--
-- The profile screen keeps a separate, narrower section for OTHER users'
-- parties (`fetchHostedParties(publicOnly: true)`), which asks something this
-- cannot: "public parties they hosted". `can_access_party` is true of a private
-- party you hold an invitation to, so a viewer-facing list has to filter on
-- `is_private` as well -- the same distinction the proximity engine draws
-- between "may they see it" and "may we surface it at them".
--
--
-- SECURITY INVOKER, like every other read RPC here.
--
-- The `parties` SELECT policy (`can_access_party`) therefore runs inside it. On
-- this query the policy is trivially satisfied -- you can always see a party you
-- host -- but leaving it invoker keeps party visibility in exactly one place
-- (CLAUDE.md #4), and means the day this function grows a second source it does
-- not silently become the one query in the schema that bypasses it.
--
-- `search_path` pinned to `public, extensions`, matching the eight read RPCs
-- pinned in `20260819095452` and for the reasons argued at length there.
-- Inlining is not lost by it here for a different reason than that migration
-- gives: the ORDER BY is the point of this function, and an inlined body would
-- have its ordering discarded by the caller anyway.
create or replace function public.get_my_hosted_parties(p_limit int default 100)
returns table (
  id uuid,
  title text,
  starts_at timestamptz,
  is_private boolean,
  going_count int,
  interested_count int,
  max_capacity int,
  cover_path text,
  area text,
  is_upcoming boolean
)
language sql
stable
set search_path = public, extensions
as $$
  select
    p.id,
    p.title,
    p.starts_at,
    p.is_private,
    p.going_count,
    p.interested_count,
    p.max_capacity,
    p.cover_path,
    p.area,
    (p.starts_at >= now()) as is_upcoming
  from public.parties p
  where p.host_id = (select auth.uid())
    -- Drafts are not something you are hosting yet and cancellations are not
    -- something you are hosting any more; `fetchHostedParties` drew the same
    -- line. A host CAN see their own drafts through the policy, which is
    -- exactly why this has to say so explicitly.
    and p.status = 'published'
  order by
    -- Upcoming first as a block, then each block in the direction that puts
    -- the most relevant row at its top: the next party you host, and the last
    -- one you did.
    (p.starts_at >= now()) desc,
    case when p.starts_at >= now() then p.starts_at end asc,
    p.starts_at desc
  limit p_limit;
$$;

-- Bounded rather than keyset-paginated, like `fetchMyRsvps` and
-- `fetchFollowing`: this is a personal list with a natural ceiling, not a feed.
-- The cap matters to the CLIENT for an honest reason -- the section heading
-- prints a count, and that count is the number of rows rendered, so it must
-- never be a total the query then truncates.
comment on function public.get_my_hosted_parties(int) is
  'The profile screen''s party list: parties the CALLER hosts, published only, upcoming block first (soonest first) then past (most recent first), with is_upcoming computed from the same now() that ordered them. Takes no user id on purpose -- it is only ever answerable about auth.uid().';

-- CLAUDE.md gotcha #4: table privileges are checked whether or not a WHERE
-- clause could ever match, so an anon caller would get "permission denied for
-- table parties" rather than an empty list. Making the function
-- authenticated-only turns that into the honest answer -- and this one is
-- doubly pointless for anon, whose auth.uid() is null.
--
-- The explicit service_role grant is gotcha #13: service_role's EXECUTE comes
-- from the default PUBLIC grant and nothing else, so the revoke would silently
-- take it away too.
revoke execute on function public.get_my_hosted_parties(int) from public;
grant execute on function public.get_my_hosted_parties(int) to authenticated, service_role;
