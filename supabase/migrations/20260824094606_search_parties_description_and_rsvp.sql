-- search_parties returns `description` and `my_rsvp_status`.
--
-- WHY. Tapping a map pin and tapping a search hit open the SAME sheet --
-- `showMapPinSheet`, called from both `map_screen.dart` and
-- `search_screen.dart` -- and that sheet now renders the full party: cover,
-- time, area, host, description, counts. Both of those columns were in
-- `get_parties_near_user` and not here, so the shared sheet had two data
-- sources that disagreed about what it could draw. A party reached from a
-- search hit would have rendered a blank description and an action button that
-- could not know the viewer had already RSVP'd -- the same party looking like
-- a different party depending on which screen you came from.
--
-- The alternative was to render only the intersection of the two payloads,
-- which would have meant no description anywhere. Filling the gap in the
-- narrower payload is the version that keeps "the map and search open the same
-- thing" literally true rather than approximately true.
--
-- A separate migration rather than an edit to 20260822150239, which is already
-- merged: `supabase db reset` rebuilds from scratch so an edit looks fine
-- locally, while every database that already ran the original keeps the old
-- function forever and the new columns simply never appear.
--
-- WHY DROP AND NOT `create or replace`. Adding output columns to a
-- `returns table (...)` changes the function's return type, and Postgres
-- refuses:
--
--   ERROR:  cannot change return type of existing function
--   HINT:   Use DROP FUNCTION search_parties(text,integer) first.
--
-- DROP takes the grants with it, so they are re-stated at the bottom. Losing
-- them silently would leave the RPC executable by nobody and the search screen
-- failing with 42501 -- gotcha 13's shape.
--
-- WHY `my_rsvp_status` IS SAFE TO MENTION HERE. Gotcha 4: table privileges are
-- checked whether or not a where-clause could ever be true, so an RPC that so
-- much as names a table the caller cannot SELECT errors out instead of
-- returning nothing. `authenticated` holds SELECT on public.rsvps
-- (20260813100309) and execute on this function is granted to `authenticated`
-- only, so there is no caller who can reach the reference without the
-- privilege. The rsvps SELECT policy then narrows the subquery to the caller's
-- own row, which is exactly what the column means -- the same construction
-- get_parties_near_user uses.

drop function public.search_parties(text, integer);

create function public.search_parties(
  p_query text,
  p_limit integer default 20
)
returns table (
  party_id uuid,
  title text,
  description text,
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
  my_rsvp_status rsvp_status,
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
    -- Added here so the shared sheet has the same body text whichever screen
    -- opened it. Unfiltered and untruncated, exactly as the map RPC returns
    -- it: the sheet decides how much to show.
    p.description,
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
    -- The viewer's own RSVP, not the party's. going_count/interested_count are
    -- properties of the party; this is a property of who is asking, which is
    -- why it is a correlated subquery and not a join -- a join would multiply
    -- rows for a party with many RSVPs.
    (
      select r.status from public.rsvps r
      where r.party_id = p.id and r.user_id = (select auth.uid())
    ) as my_rsvp_status,
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
  'which is expected. Carries description and my_rsvp_status so a hit opens '
  'the same fully-populated MapPinSheet a map pin does. '
  'The range MUST stay ~>=~ / ~<~.';

revoke execute on function public.search_parties(text, integer) from public;
grant execute on function public.search_parties(text, integer) to authenticated;
