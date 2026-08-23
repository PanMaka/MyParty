-- Phase 14B follow-up: search_parties returns lat/lon.
--
-- A separate migration rather than an edit to 20260822113256, which is already
-- merged. Editing an applied migration is the one thing the append-only rule
-- exists to stop: `supabase db reset` rebuilds from scratch so the change looks
-- fine locally, while every database that already ran the original keeps the
-- old function forever and the new columns simply never appear.
--
-- WHY DROP AND NOT `create or replace`. Adding output columns to a
-- `returns table (...)` changes the function's return type, and Postgres
-- refuses:
--
--   ERROR:  cannot change return type of existing function
--   DETAIL: Row type defined by OUT parameters is different.
--   HINT:   Use DROP FUNCTION search_parties(text,integer) first.
--
-- DROP takes the grants with it, so they are re-stated below. Losing them
-- silently would leave the RPC executable by nobody and the search screen
-- failing with 42501 -- the same shape as gotcha 13.
--
-- WHY lat/lon AT ALL: it lets a search result become a MapPartyPin, so tapping
-- one opens the same MapPinSheet a pin does, with the same report action and
-- the same live attendee count. A separate search-result type would have been a
-- second thing to keep in step with this payload for no gain.

drop function public.search_parties(text, integer);

create function public.search_parties(
  p_query text,
  p_limit integer default 20
)
returns table (
  party_id uuid,
  title text,
  area text,
  starts_at timestamptz,
  ends_at timestamptz,
  is_private boolean,
  cover_path text,
  host_id uuid,
  host_username text,
  lat double precision,
  lon double precision,
  going_count integer,
  interested_count integer,
  is_past boolean
)
language sql
stable
set search_path to 'public', 'extensions'
as $$
  with q as (
    select public.search_normalize(p_query) as key
  ),
  hits as (
    -- Driven from the TOKEN index, not from parties: this is the step that
    -- turns the whole table into a few rows before any policy runs. Both terms
    -- are leakproof, so they sort ahead of the token table's
    -- can_access_party() policy.
    --
    -- The range MUST stay `~>=~` / `~<~`. `like q.key || '%'` returns the same
    -- rows and never reaches the index (textlike is non-leakproof, so the
    -- planner may not promote it past the policy and the index qual is never
    -- formed). `>=` / `<` also return the same rows, are leakproof, are
    -- promoted -- and still cannot use this index, because text_ops and
    -- text_pattern_ops are different operator families. Asserted three ways in
    -- 20_party_search.test.sql.
    select distinct t.party_id
    from public.party_search_tokens t, q
    where q.key <> ''
      and t.token ~>=~ q.key
      and t.token ~<~ public.search_prefix_upper(q.key)
  )
  select
    p.id as party_id,
    p.title,
    p.area,
    p.starts_at,
    p.ends_at,
    p.is_private,
    p.cover_path,
    p.host_id,
    pr.username as host_username,
    -- Added by 20260822150239 so a search hit converts straight into a
    -- MapPartyPin and opens the SAME sheet the map opens. Read from
    -- `location`, exactly as the map RPC does -- NEVER from bbox_lat/bbox_lon,
    -- which are index support only and must not answer a question (Phase 13).
    st_y(p.location::geometry) as lat,
    st_x(p.location::geometry) as lon,
    p.going_count,
    p.interested_count,
    public.party_is_past(p.starts_at, p.ends_at) as is_past
  from hits h
  join public.parties p on p.id = h.party_id
  join public.profiles pr on pr.id = p.host_id
  where p.status = 'published'
  -- Upcoming first, soonest first; then past, most recent first. "Find that
  -- party from May" is a real use, which is why past rows are returned at all.
  order by
    public.party_is_past(p.starts_at, p.ends_at) asc,
    case when public.party_is_past(p.starts_at, p.ends_at) then null else p.starts_at end asc nulls last,
    case when public.party_is_past(p.starts_at, p.ends_at) then p.starts_at else null end desc nulls last
  limit greatest(least(p_limit, 50), 1);
$$;

comment on function public.search_parties(text, integer) is
  'Prefix search over party titles and areas, unbounded by location. '
  'SECURITY INVOKER so the parties and party_search_tokens policies both '
  'apply. map_visibility deliberately does NOT filter this -- it answers "do I '
  'want to be a pin", not "do I want to be unfindable". Past parties are '
  'returned in a second group, using party_is_past(); the map does not filter '
  'on that yet and the two therefore disagree about a null-ends_at party, '
  'which is expected. The range MUST stay ~>=~ / ~<~.';

revoke execute on function public.search_parties(text, integer) from public;
grant execute on function public.search_parties(text, integer) to authenticated;
