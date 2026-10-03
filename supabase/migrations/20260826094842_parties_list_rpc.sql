-- get_parties_list: the ALL PARTIES tab, on real rows, sorted server-side.
--
-- The tab rendered the const `mpParties` map -- six hardcoded parties with
-- string ids -- sorted client-side by a hardcoded integer. This is the RPC
-- that retires it, and it exists now because sorting forced it: "most
-- interested first" applied to an already-fetched page means "most interested
-- among whatever we happened to load", which is not the feature.
--
-- Two sorts, as a `party_sort` ENUM rather than text. An unknown value is then
-- a type error at the PostgREST boundary, raised by Postgres with the legal
-- values in the message, instead of a runtime check inside the function or --
-- worse -- a silent fallback to the default sort. Same reason rsvp_status and
-- party_status are enums.


-- ===========================================================================
-- PART 1 -- SORTING BY A COUNTER IS A SIDE CHANNEL, AND THIS IS THE FIX.
-- ===========================================================================
-- 20260825090051 returns NULL rather than 0 for going_count/interested_count
-- on a private row, so no client can render the number. Ordering by that same
-- number would hand most of it straight back: a private party ranked between
-- two public rows whose counts ARE transmitted is bracketed, not blurred --
-- P between 40 and 30 means P is in [30, 40], and the interval tightens toward
-- exact as the list gets denser. It is also observable over time: a private
-- row climbing the list reports rsvp EVENTS, which is strictly more than the
-- magnitude 20260825090051 withheld.
--
-- So private parties are a GROUP, pinned above the public ranking, ordered
-- among themselves by starts_at. Three decisions in that, each with an
-- alternative that looks reasonable and is worse:
--
--   * NOT excluded from the sort. A party you were personally invited to must
--     not vanish because you changed how the list is ordered -- sorting is not
--     a filter, and the invitee is exactly the person the privacy rule is for.
--
--   * ABOVE, not below. An invitation is a stronger relevance signal than a
--     stranger's headcount, so burying invitations under the popular public
--     rows is the wrong product. It is also the call this codebase already
--     made once for the same leak in another dimension: MpDropGeometry
--     .private() pins the private map bubble to the CEILING of the public size
--     scale, precisely so no observer can read "this is a quiet one" off its
--     silhouette. Ordering is that leak in one dimension; same answer.
--
--   * Ordered by starts_at INSIDE the group, not by going_count. Both counters
--     are NULLed for private rows, so ranking the group by going_count would
--     trade a leak of interest for a leak of guest-list size. starts_at is
--     already transmitted for private parties -- the detail sheet prints it --
--     so it reveals nothing not already on screen.
--
-- The `case when p.is_private then null` in sort_rank below is what enforces
-- the third point. The group key alone already stops a private row being
-- compared against a public one, so without the case the counter would still
-- order private rows AMONG THEMSELVES by a value none of them transmits. The
-- case means the hidden number is not consulted at all, which is the property
-- worth having: not "the leak is small", but "the value is never read".
--
-- THE OTHER SORT NEEDS NONE OF THIS. 'soonest' ranks on starts_at, which is
-- public for private parties, so they interleave freely there. Pinning them in
-- both sorts would be cargo-culting this fix into a place it does not apply,
-- and it would make that sort worse for no gain.
create type public.party_sort as enum ('soonest', 'interested');

comment on type public.party_sort is
  'Ordering for get_parties_list. An enum so an unknown sort is a type error '
  'at the API boundary rather than a silent fallback.';


-- ===========================================================================
-- PART 2 -- the function.
-- ===========================================================================
-- SECURITY INVOKER (the default, stated by omission like the other seven read
-- RPCs) so the parties SELECT policy is the only authority on visibility.
-- Nothing here re-implements it.
--
-- KEYSET, NEVER OFFSET (CLAUDE.md #5). Both sorts are normalised to ONE
-- ascending 4-tuple -- (sort_group, sort_rank, starts_at, party_id) -- so a
-- single row-value comparison paginates either of them and there is no second
-- cursor shape to keep in step. Descending keys are negated rather than
-- special-cased: `interested_count desc` is `-interested_count asc`, which is
-- why sort_rank is a bigint and not an int.
--
-- The cursor columns are RETURNED, so the client echoes back the last row it
-- drew rather than reconstructing the key. That also makes the cursor itself
-- safe to hand around: sort_rank is 0 on every private row (see the case
-- above), so a cursor pointing at a private party carries no count either.
create or replace function public.get_parties_list(
  p_sort public.party_sort default 'soonest',
  p_limit integer default 30,
  p_cursor_group integer default null,
  p_cursor_rank bigint default null,
  p_cursor_starts_at timestamp with time zone default null,
  p_cursor_id uuid default null
)
returns table (
  party_id uuid,
  title text,
  description text,
  starts_at timestamp with time zone,
  ends_at timestamp with time zone,
  area text,
  cover_path text,
  is_private boolean,
  is_sponsored boolean,
  party_tier text,
  host_id uuid,
  host_username text,
  is_live boolean,
  going_count integer,
  interested_count integer,
  my_rsvp_status public.rsvp_status,
  is_invited boolean,
  sort_group integer,
  sort_rank bigint
)
language sql
set search_path to 'public', 'extensions'
as $$
  with ranked as (
    select
      p.id,
      p.title,
      p.description,
      p.starts_at,
      p.ends_at,
      p.area,
      p.cover_path,
      p.is_private,
      p.is_sponsored,
      p.party_tier,
      p.host_id,
      pr.username as host_username,
      (p.starts_at <= now()) as is_live,

      -- The group key. 0 sorts first in both sorts, and what lands in 0
      -- differs by sort on purpose: live parties lead 'soonest', private
      -- parties lead 'interested'.
      case
        when p_sort = 'soonest' then (case when p.starts_at <= now() then 0 else 1 end)
        else (case when p.is_private then 0 else 1 end)
      end as sort_group,

      -- The rank key, normalised ascending. 0 for every row in 'soonest'
      -- (starts_at is the real secondary there) and for every PRIVATE row in
      -- 'interested' -- see Part 1: the counter is not consulted for those.
      case
        when p_sort = 'interested' and not p.is_private
          then (-p.interested_count)::bigint
        else 0::bigint
      end as sort_rank

    from public.parties p
    join public.profiles pr on pr.id = p.host_id
    where p.status = 'published'
      -- Leakproof shapes, both of them, and that is the whole performance
      -- story for this function (gotcha 22). `timestamptz_gt(Var, Const)` is
      -- promoted ahead of the parties row policy and shrinks the input before
      -- can_access_party is called on anything; `party_is_past()` would do the
      -- opposite -- it is neither leakproof nor inlinable (gotcha 20), so it
      -- would sink behind the barrier and filter rows that had already paid.
      -- Same pair of predicates, ~200x apart.
      and (p.ends_at is null or p.ends_at > now())
      -- Drops the null-ends_at parties that gotcha 21 leaves on the map
      -- forever. This is a NEW surface choosing for itself, not a change to
      -- the map's default -- 21_map_time_windows still asserts the map shows
      -- them, and that decision stays open. A browse list headed "ALL PARTIES"
      -- and sorted by soonest cannot lead with a party that ended in June.
      and p.starts_at > now() - public.party_end_grace()
  )
  select
    r.id as party_id,
    r.title,
    r.description,
    r.starts_at,
    r.ends_at,
    r.area,
    r.cover_path,
    r.is_private,
    r.is_sponsored,
    r.party_tier,
    r.host_id,
    r.host_username,
    r.is_live,

    -- NULL for a private party, at the source -- identical to
    -- get_parties_near_user and search_parties. A third surface transmitting
    -- the number would undo both of them.
    case when r.is_private then null else r.going_count end as going_count,
    case when r.is_private then null else r.interested_count end as interested_count,

    -- A property of the CALLER, not of the party, so it is transmitted for
    -- private rows too (20260825090051's reasoning): the viewer already knows
    -- their own answer, and suppressing it would only break the button label.
    (
      select rs.status from public.rsvps rs
      where rs.party_id = r.id and rs.user_id = (select auth.uid())
    ) as my_rsvp_status,

    exists (
      select 1 from public.invitations i
      where i.party_id = r.id and i.guest_id = (select auth.uid())
    ) as is_invited,

    r.sort_group,
    r.sort_rank

  from (
    select r.*, p.going_count, p.interested_count
    from ranked r join public.parties p on p.id = r.id
  ) r
  where
    -- One row comparison for both sorts. `p_cursor_id is null` is the first
    -- page; every key is non-null by construction on a real row, so there is
    -- no NULL-propagation case to guard.
    p_cursor_id is null
    or (r.sort_group, r.sort_rank, r.starts_at, r.id)
       > (p_cursor_group, p_cursor_rank, p_cursor_starts_at, p_cursor_id)
  order by r.sort_group, r.sort_rank, r.starts_at, r.id
  limit greatest(least(p_limit, 100), 1);
$$;

comment on function public.get_parties_list(public.party_sort, integer, integer, bigint, timestamp with time zone, uuid) is
  'The ALL PARTIES browse list. SECURITY INVOKER, so the parties SELECT policy '
  'is the only visibility authority. Private parties are a GROUP pinned above '
  'the interested ranking and ordered by starts_at within it -- ordering them '
  'by interested_count would bracket the value 20260825090051 returns NULL to '
  'hide. Keyset over (sort_group, sort_rank, starts_at, party_id), all '
  'ascending, with descending keys negated; the cursor columns are returned so '
  'the client echoes them back.';

-- Gotcha 4: the function mentions public.rsvps and public.invitations, and a
-- table privilege is checked whether or not a where-clause could ever be true.
-- anon holds SELECT on neither, so an anon call errors on the mention rather
-- than returning zero rows -- revoke rather than rely on the RLS result.
revoke execute on function public.get_parties_list(public.party_sort, integer, integer, bigint, timestamp with time zone, uuid) from public;
grant execute on function public.get_parties_list(public.party_sort, integer, integer, bigint, timestamp with time zone, uuid) to authenticated;
