-- Phase 46, part C: a private party's counters leave the table for clients.
--
-- 20260825090051 made every attendee RPC return NULL for going_count and
-- interested_count on a private row, so no surface renders the number. Two
-- doors were still open, both found by the Phase 46 audit:
--
--   * the table itself: authenticated held SELECT on every parties column, so
--     an invitee could ask PostgREST for ?select=going_count,interested_count
--     on the private party they were invited to and get the guest-list size the
--     RPCs withhold;
--   * get_party_chats returned the raw p.going_count to every member of a
--     private party's chat, and group chat exists only on private parties
--     (Phase 16c), so that column was never anything BUT a private count.
--
-- The fix is the Phase 45 shape: SELECT on parties becomes a column list
-- without the two counters, and two generated columns, public_going_count and
-- public_interested_count, carry the value only where it was ever public --
-- NULL when is_private. They are STORED, so the counter trigger's writes keep
-- them current and nothing reads them at a different moment from the counter.
--
-- The invoker readers switch to them. Each already spelled the same rule as
-- `case when p.is_private then null else p.going_count end`; the column is
-- that expression, written once. get_party_chats now returns NULL there, the
-- host included, like every attendee RPC (33_party_host_dashboard).
--
-- The host keeps the real numbers through two definer doors:
-- get_party_host_stats (unchanged) and get_my_hosted_parties, which becomes
-- definer here because it was invoker and read the raw columns. It answers
-- only for host_id = auth.uid(), so RLS had nothing left to decide. The
-- engines that read the counters (sync_party_rsvp_counters, export) are
-- definer already.
--
-- A new parties column is now unreadable to clients until a migration grants
-- it, as on profiles. Do not re-grant SELECT table-wide.


alter table public.parties
  add column public_going_count integer
    generated always as (case when is_private then null else going_count end) stored,
  add column public_interested_count integer
    generated always as (case when is_private then null else interested_count end) stored;

comment on column public.parties.public_going_count is
  'going_count, or NULL on a private party. What clients read (Phase 46); the '
  'raw counter is not granted to them.';
comment on column public.parties.public_interested_count is
  'interested_count, or NULL on a private party. What clients read (Phase 46); '
  'the raw counter is not granted to them.';

revoke select on public.parties from authenticated;
grant select (
  id, host_id, title, description, location, starts_at, created_at,
  is_private, is_sponsored, party_tier, max_capacity, ends_at, status,
  cover_path, area, bbox_lat, bbox_lon, address,
  public_going_count, public_interested_count
) on public.parties to authenticated;


CREATE OR REPLACE FUNCTION public.get_my_parties()
 RETURNS TABLE(party_id uuid, title text, description text, starts_at timestamp with time zone, ends_at timestamp with time zone, area text, address text, cover_path text, is_private boolean, host_id uuid, host_username text, lat double precision, lon double precision, going_count integer, interested_count integer, my_rsvp_status rsvp_status, is_host boolean, is_invited boolean)
 LANGUAGE sql
 SET search_path TO 'public', 'extensions'
AS $function$
  with mine as (
    select r.party_id, r.status, false as is_host, false as is_invited
      from public.rsvps r
     where r.user_id = (select auth.uid())
    union all
    select p.id, null, true, false
      from public.parties p
     where p.host_id = (select auth.uid())
    union all
    select i.party_id, null, false, true
      from public.invitations i
     where i.guest_id = (select auth.uid())
  )
  select
    p.id as party_id,
    p.title,
    p.description,
    p.starts_at,
    p.ends_at,
    p.area,
    p.address,
    p.cover_path,
    p.is_private,
    p.host_id,
    pr.username as host_username,
    st_y(p.location::geometry) as lat,
    st_x(p.location::geometry) as lon,
    -- NULL for a private party, at the source -- see the header.
    p.public_going_count as going_count,
    p.public_interested_count as interested_count,
    -- At most one rsvps row per (party, user) -- it is the primary key.
    (array_agg(m.status) filter (where m.status is not null))[1] as my_rsvp_status,
    bool_or(m.is_host) as is_host,
    bool_or(m.is_invited) as is_invited
  from mine m
  join public.parties p on p.id = m.party_id
  -- Inner, like the map and search: a tombstoned host still has a profiles
  -- row (CLAUDE.md, Phase 9), so this drops nothing.
  join public.profiles pr on pr.id = p.host_id
  -- NOT OVER. The shared predicate, identical to get_parties_near_user,
  -- get_parties_list and get_party (20261008150440, gotcha 21).
  where p.status = 'published'
    and (p.ends_at is null or p.ends_at > now())
    and (
      p.ends_at is not null
      or p.starts_at > (select now() - public.party_end_grace())
    )
  group by p.id, pr.username
  order by p.starts_at, p.id
  limit 200;
$function$;



CREATE OR REPLACE FUNCTION public.get_parties_list(p_sort party_sort DEFAULT 'soonest'::party_sort, p_limit integer DEFAULT 30, p_cursor_group integer DEFAULT NULL::integer, p_cursor_rank bigint DEFAULT NULL::bigint, p_cursor_starts_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_cursor_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(party_id uuid, title text, description text, starts_at timestamp with time zone, ends_at timestamp with time zone, area text, address text, cover_path text, is_private boolean, is_sponsored boolean, party_tier text, host_id uuid, host_username text, is_live boolean, going_count integer, interested_count integer, my_rsvp_status rsvp_status, is_invited boolean, sort_group integer, sort_rank bigint, lat double precision, lon double precision)
 LANGUAGE sql
 SET search_path TO 'public', 'extensions'
AS $function$
  with ranked as (
    select
      p.id,
      p.title,
      p.description,
      p.starts_at,
      p.ends_at,
      p.area,
      p.address,
      p.cover_path,
      p.is_private,
      p.is_sponsored,
      p.party_tier,
      p.host_id,
      pr.username as host_username,
      (p.starts_at <= now()) as is_live,

      -- Live parties lead 'soonest', private parties lead 'interested'.
      case
        when p_sort = 'soonest' then (case when p.starts_at <= now() then 0 else 1 end)
        else (case when p.is_private then 0 else 1 end)
      end as sort_group,

      -- The counter is never consulted for a private row (20260826094842 Part 1).
      case
        when p_sort = 'interested' and not p.is_private
          then (-p.public_interested_count)::bigint
        else 0::bigint
      end as sort_rank

    from public.parties p
    join public.profiles pr on pr.id = p.host_id
    -- NOT OVER. The shared predicate, identical to the map's (gotcha 21).
    where p.status = 'published'
      and (p.ends_at is null or p.ends_at > now())
      and (
        p.ends_at is not null
        or p.starts_at > (select now() - public.party_end_grace())
      )
  )
  select
    r.id as party_id,
    r.title,
    r.description,
    r.starts_at,
    r.ends_at,
    r.area,
    r.address,
    r.cover_path,
    r.is_private,
    r.is_sponsored,
    r.party_tier,
    r.host_id,
    r.host_username,
    r.is_live,
    r.public_going_count as going_count,
    r.public_interested_count as interested_count,
    (
      select rs.status from public.rsvps rs
      where rs.party_id = r.id and rs.user_id = (select auth.uid())
    ) as my_rsvp_status,
    exists (
      select 1 from public.invitations i
      where i.party_id = r.id and i.guest_id = (select auth.uid())
    ) as is_invited,
    r.sort_group,
    r.sort_rank,
    st_y(r.location::geometry) as lat,
    st_x(r.location::geometry) as lon
  from (
    select r.*, p.public_going_count, p.public_interested_count, p.location
    from ranked r join public.parties p on p.id = r.id
  ) r
  where
    p_cursor_id is null
    or (r.sort_group, r.sort_rank, r.starts_at, r.id)
       > (p_cursor_group, p_cursor_rank, p_cursor_starts_at, p_cursor_id)
  order by r.sort_group, r.sort_rank, r.starts_at, r.id
  limit greatest(least(p_limit, 100), 1);
$function$;



CREATE OR REPLACE FUNCTION public.get_parties_near_user(map_center_lon double precision, map_center_lat double precision, radius_meters double precision, p_limit integer DEFAULT 200, p_window text DEFAULT 'all'::text, p_tz text DEFAULT 'Europe/Athens'::text)
 RETURNS TABLE(party_id uuid, title text, description text, starts_at timestamp with time zone, ends_at timestamp with time zone, area text, address text, cover_path text, is_private boolean, is_sponsored boolean, party_tier text, host_id uuid, host_username text, lat double precision, lon double precision, distance_meters double precision, going_count integer, interested_count integer, my_rsvp_status rsvp_status, is_invited boolean)
 LANGUAGE sql
 SET search_path TO 'public', 'extensions'
AS $function$
  select
    p.id as party_id,
    p.title,
    p.description,
    p.starts_at,
    p.ends_at,
    p.area,
    p.address,
    p.cover_path,
    p.is_private,
    p.is_sponsored,
    p.party_tier,
    p.host_id,
    pr.username as host_username,

    -- From `location`, not bbox_lat/bbox_lon: those exist to narrow, not to
    -- answer.
    st_y(p.location::geometry) as lat,
    st_x(p.location::geometry) as lon,

    st_distance(p.location, st_point(map_center_lon, map_center_lat)::geography) as distance_meters,

    -- NULL for a private party, at the source (20260825090051).
    p.public_going_count as going_count,
    p.public_interested_count as interested_count,

    (
      select r.status from public.rsvps r
      where r.party_id = p.id and r.user_id = (select auth.uid())
    ) as my_rsvp_status,

    exists (
      select 1 from public.invitations i
      where i.party_id = p.id and i.guest_id = (select auth.uid())
    ) as is_invited

  from public.parties p
  join public.profiles pr on p.host_id = pr.id
  where

    -- THE SPATIAL PRE-FILTER (20260821201309): leakproof float8 comparisons
    -- against InitPlan constants, evaluated ahead of the row policy.
    p.bbox_lat >= (select st_ymin(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))
    and p.bbox_lat <= (select st_ymax(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))
    and p.bbox_lon >= (select st_xmin(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))
    and p.bbox_lon <= (select st_xmax(public.map_search_box(map_center_lon, map_center_lat, radius_meters)))

    -- THE TIME PRE-FILTER (20260823091942). The bounds MUST stay scalar
    -- subqueries -- one evaluation, an InitPlan constant, not one per row.
    and p.starts_at >= (select lower(public.party_time_window(p_window, p_tz)))
    and p.starts_at <  (select upper(public.party_time_window(p_window, p_tz)))

    -- NOT OVER. The shared predicate -- see the header. Until this migration
    -- the grace arm applied only under Τώρα and the default map pinned a
    -- null-ends_at party forever (gotcha 21); it now applies on every window.
    --
    -- DO NOT rewrite the last term as coalesce(p.ends_at, p.starts_at + grace)
    -- > now(). Algebraically identical, ~20x slower measured: a Var under
    -- timestamptz_pl_interval is not leakproof and drags the term behind the
    -- RLS barrier. Same trap for party_is_past().
    and p.status = 'published'
    and (p.ends_at is null or p.ends_at > now())
    and (
      p.ends_at is not null
      or p.starts_at > (select now() - public.party_end_grace())
    )

    -- The box above is a SUPERSET of this circle; this is what decides.
    and st_dwithin(p.location, st_point(map_center_lon, map_center_lat)::geography, radius_meters)

    -- The host's map_visibility, plus the party-specific override. The tier
    -- is owner-only since Phase 45, so it is read through host_on_my_map.
    and (
      p.host_id = (select auth.uid())
      or public.host_on_my_map(p.host_id)
      or exists (
        select 1 from public.invitations i
        where i.party_id = p.id and i.guest_id = (select auth.uid())
      )
      or exists (
        select 1 from public.rsvps r
        where r.party_id = p.id and r.user_id = (select auth.uid())
      )
    )

    -- Zoom tier. Independent of the window: both narrow.
    and case
        when radius_meters <= 15000 then true
        when radius_meters <= 100000 then p.party_tier in ('large', 'mega')
        else p.party_tier = 'mega' or p.is_sponsored = true
    end
  order by p.is_sponsored desc, distance_meters asc
  limit greatest(least(p_limit, 500), 1);
$function$;



CREATE OR REPLACE FUNCTION public.get_party(p_party_id uuid)
 RETURNS TABLE(party_id uuid, title text, description text, starts_at timestamp with time zone, ends_at timestamp with time zone, area text, address text, cover_path text, is_private boolean, is_sponsored boolean, party_tier text, host_id uuid, host_username text, is_live boolean, going_count integer, interested_count integer, my_rsvp_status rsvp_status, is_invited boolean, sort_group integer, sort_rank bigint, lat double precision, lon double precision)
 LANGUAGE sql
 SET search_path TO 'public', 'extensions'
AS $function$
  select
    p.id as party_id,
    p.title,
    p.description,
    p.starts_at,
    p.ends_at,
    p.area,
    p.address,
    p.cover_path,
    p.is_private,
    p.is_sponsored,
    p.party_tier,
    p.host_id,
    pr.username as host_username,
    (p.starts_at <= now()) as is_live,
    p.public_going_count as going_count,
    p.public_interested_count as interested_count,
    (
      select rs.status from public.rsvps rs
      where rs.party_id = p.id and rs.user_id = (select auth.uid())
    ) as my_rsvp_status,
    exists (
      select 1 from public.invitations i
      where i.party_id = p.id and i.guest_id = (select auth.uid())
    ) as is_invited,
    0 as sort_group,
    0::bigint as sort_rank,
    st_y(p.location::geometry) as lat,
    st_x(p.location::geometry) as lon
  from public.parties p
  join public.profiles pr on pr.id = p.host_id
  where p.id = p_party_id
    -- NOT OVER. The shared predicate (gotcha 21).
    and p.status = 'published'
    and (p.ends_at is null or p.ends_at > now())
    and (
      p.ends_at is not null
      or p.starts_at > (select now() - public.party_end_grace())
    );
$function$;



CREATE OR REPLACE FUNCTION public.search_parties(p_query text, p_limit integer DEFAULT 20)
 RETURNS TABLE(party_id uuid, title text, description text, area text, address text, starts_at timestamp with time zone, ends_at timestamp with time zone, is_private boolean, cover_path text, host_id uuid, host_username text, lat double precision, lon double precision, going_count integer, interested_count integer, my_rsvp_status rsvp_status, is_past boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
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
    p.address,
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
    -- NULL for a private party, at the source.
    --
    -- The client no longer displays either number for a private row on any
    -- surface, so transmitting them would leave attendance data sitting in a
    -- JSON payload that nothing reads -- one debug build, one `print(row)`, or
    -- one future widget away from being visible. A value that is not sent
    -- cannot leak; a client convention not to render it is one edit from
    -- lapsing, and the edit looks harmless.
    --
    -- Costs nothing in the plan: this is the TARGET list, evaluated on rows
    -- that already survived the WHERE clause. Gotcha 22 is about predicates,
    -- and no predicate changed here -- verified by the unchanged timings in
    -- scripts/explain_map_time_windows.sh.
    p.public_going_count as going_count,
    p.public_interested_count as interested_count,
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
$function$;



CREATE OR REPLACE FUNCTION public.get_party_chats()
 RETURNS TABLE(party_id uuid, party_title text, party_is_private boolean, party_starts_at timestamp with time zone, going_count integer, last_message_body text, last_message_author_username text, last_message_at timestamp with time zone, unread_count integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'extensions'
AS $function$
  with candidate as (
    select p.id from public.parties p where p.host_id = (select auth.uid())
    union
    select i.party_id from public.invitations i where i.guest_id = (select auth.uid())
    union
    select r.party_id from public.rsvps r where r.user_id = (select auth.uid())
  )

  select
    p.id as party_id,
    p.title as party_title,
    p.is_private as party_is_private,
    p.starts_at as party_starts_at,
    p.public_going_count,
    last_msg.body as last_message_body,
    last_msg.author_username as last_message_author_username,
    last_msg.created_at as last_message_at,
    coalesce(unread.n, 0)::int as unread_count

  -- Invoker rights: this join is what applies the parties SELECT policy,
  -- i.e. can_access_party, to the candidate set.
  from candidate c
  join public.parties p on p.id = c.id

  left join lateral (
    select m.body, m.created_at, pr.username as author_username
    from public.messages m
    join public.profiles pr on pr.id = m.author_id
    where m.party_id = p.id
    order by m.created_at desc, m.id desc
    limit 1
  ) last_msg on true

  left join public.party_reads rd
    on rd.party_id = p.id and rd.user_id = (select auth.uid())

  left join lateral (
    select count(*) as n
    from (
      select 1
      from public.messages m
      where m.party_id = p.id
      -- No read state yet means everything is unread, so the watermark
      -- floors at -infinity rather than at now(): a chat you have never
      -- opened should arrive with a badge on it, not silently caught up.
      and m.created_at > coalesce(rd.last_read_at, '-infinity'::timestamp with time zone)
      limit 100
    ) capped
  ) unread on true

  where
    -- Defence in depth behind the revoke, and the same guard get_feed
    -- carries: a session with no uid has no participation set to build a
    -- chat list from, so every arm of the CTE is empty anyway.
    (select auth.uid()) is not null

    and public.can_chat_in_party(p.id)

    -- A cancelled party's chat is not a place to keep talking.
    and p.status <> 'cancelled'

    -- NEW: a day of after-party, then off the list.
    and (p.ends_at is null or p.ends_at > now() - interval '24 hours')

  -- Busiest conversation first; a chat with no messages yet sorts by when
  -- the party is happening, so a freshly created party is reachable instead
  -- of stranded at the bottom of the list.
  order by
    last_msg.created_at desc nulls last,
    p.starts_at asc;
$function$;



CREATE OR REPLACE FUNCTION public.get_my_hosted_parties(p_limit integer DEFAULT 100)
 RETURNS TABLE(id uuid, title text, starts_at timestamp with time zone, is_private boolean, going_count integer, interested_count integer, max_capacity integer, cover_path text, area text, is_upcoming boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;

