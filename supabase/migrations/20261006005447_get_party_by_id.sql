-- get_party: one party by id, for a party link (https://mypartycorp.com/p/<id>).
--
-- A link carries only the id, and the id is NOT a capability. Party ids are
-- random uuids, but this function does not rely on that: it is SECURITY
-- INVOKER, so the parties SELECT policy decides visibility exactly as it does
-- for every other read, and a private party you are not invited to returns
-- zero rows -- the same zero rows as an id that never existed, a cancelled
-- party or one that has ended. The client says "not available" for all four,
-- so a link reveals nothing about a party you may not see, not even that it
-- exists. Holding a link to a private party gets you nothing an invitation
-- does not already give you; that was a product decision (Phase 25), and an
-- invite-link capability would be a separate, token-based mechanism.
--
-- Row shape: identical to get_parties_list, so the client parses it with
-- PartyListItem.fromRow and opens the same PartyDetailSheet the parties tab
-- does. sort_group/sort_rank are meaningless for a single row and are 0.
--
-- What is deliberately repeated from get_parties_list, and pinned by
-- 29_get_party.test.sql so a drift is a red test:
--   * NULL counters on a private row (20260825090051). This is the fourth
--     surface that transmits them; any one of the four sending the number
--     would undo the other three.
--   * status = 'published' and the leakproof not-finished pair (gotcha 22).
--     A link to a party that has ended answers like one that never existed;
--     the list makes the same call for the same reason.

create or replace function public.get_party(p_party_id uuid)
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
  select
    p.id as party_id,
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
    case when p.is_private then null else p.going_count end as going_count,
    case when p.is_private then null else p.interested_count end as interested_count,
    (
      select rs.status from public.rsvps rs
      where rs.party_id = p.id and rs.user_id = (select auth.uid())
    ) as my_rsvp_status,
    exists (
      select 1 from public.invitations i
      where i.party_id = p.id and i.guest_id = (select auth.uid())
    ) as is_invited,
    0 as sort_group,
    0::bigint as sort_rank
  from public.parties p
  join public.profiles pr on pr.id = p.host_id
  where p.id = p_party_id
    and p.status = 'published'
    and (p.ends_at is null or p.ends_at > now())
    and p.starts_at > now() - public.party_end_grace();
$$;

comment on function public.get_party(uuid) is
  'One party by id, for a party link. SECURITY INVOKER: the parties SELECT '
  'policy decides, and a party the caller may not see returns zero rows, '
  'indistinguishable from one that does not exist. Same row shape as '
  'get_parties_list, counters NULL on private rows.';

-- Gotcha 4, as for get_parties_list: the body mentions rsvps and invitations,
-- which anon holds no SELECT on, so anon is refused at EXECUTE rather than
-- left to error inside.
revoke execute on function public.get_party(uuid) from public;
grant execute on function public.get_party(uuid) to authenticated;
