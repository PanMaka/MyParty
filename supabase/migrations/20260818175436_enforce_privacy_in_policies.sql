-- Phase 8, part 2: where the two columns actually bite.
--
-- The point of this file is that neither column is ever checked by the client.
-- invite_policy lives in the invitations INSERT policy; map_visibility lives
-- inside get_parties_near_user. A widget may read them to draw the right
-- switch, and a widget reading them is decorative -- deleting every check in
-- the Flutter app changes nothing about what the database will hand out.


-- ============================================================
-- 1. invitations INSERT -- "they can't invite me", the other half.
--
-- 20260814094945 made this policy say "I can't invite someone I have a block
-- with". invite_policy adds the softer version of the same sentence, chosen by
-- the guest rather than forced by a block: "I only accept invitations from
-- people I follow".
--
-- Everything else about the policy is unchanged. Restated in full rather than
-- patched because a policy has no ALTER that can add a conjunct, and because
-- the whole expression is the thing worth reading in one piece.
-- ============================================================
drop policy "Hosts can invite guests" on public.invitations;

create policy "Hosts can invite guests"
on public.invitations for insert to authenticated
with check (
  exists (
    select 1 from public.parties
    where parties.id = invitations.party_id
    and parties.host_id = (select auth.uid())
  )
  and not public.is_blocked((select auth.uid()), invitations.guest_id)
  and public.accepts_invite_from(invitations.guest_id, (select auth.uid()))
);


-- ============================================================
-- 2. create_party_with_invites -- the bulk path needs the same courtesy
-- filter the block check got in 20260814094946, for exactly the same reason.
--
-- The RPC inserts every invitee in ONE statement, so a single guest whose
-- invite_policy refuses would abort the whole call with 42501 and take the
-- party creation down with it (the function is one statement at top level;
-- both inserts roll back). The host gets an error they cannot act on, and the
-- error itself discloses that a specific person has restricted who may invite
-- them -- which is the fact the setting exists to keep quiet.
--
-- Filtering the ids out first makes creation succeed with a shorter guest
-- list, which is what the setting should feel like from the outside: nothing
-- happened. The RLS policy above remains the real boundary -- a direct insert
-- into public.invitations is still rejected -- and this is only the bulk-path
-- courtesy.
--
-- Unchanged from 20260814094946 otherwise: still security invoker, host_id
-- still forced to the caller, id still generated locally to dodge the
-- RETURNING-vs-SELECT-policy problem.
-- ============================================================
create or replace function public.create_party_with_invites(
  p_party jsonb,
  p_invitee_ids uuid[] default '{}'
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_party_id uuid := gen_random_uuid();
begin
  insert into public.parties (
    id, host_id, title, description, location, starts_at, ends_at,
    is_private, is_sponsored, party_tier, max_capacity, status
  ) values (
    v_party_id,
    (select auth.uid()),
    p_party->>'title',
    p_party->>'description',
    public.st_point((p_party->>'lon')::double precision, (p_party->>'lat')::double precision)::public.geography,
    (p_party->>'starts_at')::timestamptz,
    nullif(p_party->>'ends_at', '')::timestamptz,
    coalesce((p_party->>'is_private')::boolean, false),
    coalesce((p_party->>'is_sponsored')::boolean, false),
    coalesce(p_party->>'party_tier', 'standard'),
    nullif(p_party->>'max_capacity', '')::int,
    coalesce(p_party->>'status', 'published')::public.party_status
  );

  if array_length(p_invitee_ids, 1) is not null then
    insert into public.invitations (party_id, guest_id)
    select v_party_id, invitee_id
    from unnest(p_invitee_ids) as invitee_id
    where not public.is_blocked((select auth.uid()), invitee_id)
      and public.accepts_invite_from(invitee_id, (select auth.uid()))
    on conflict (party_id, guest_id) do nothing;
  end if;

  return v_party_id;
end;
$$;


-- ============================================================
-- 3. get_parties_near_user -- map_visibility.
--
-- WHAT THIS FUNCTION RETURNS IS PARTIES, NOT USERS, and that decides the
-- semantics: there is no "people on the map" surface, so the only thing a
-- host's map_visibility can gate is whether their parties appear as pins. The
-- pin carries host_id and host_username, so hiding the pin is the same act as
-- hiding the host.
--
-- The gate has an escape hatch, and it is the interesting half. A
-- party-specific relationship -- you host it, you hold an invitation, you
-- already RSVP'd -- overrides the tier. An invitation is a deliberate act by
-- the host aimed at ONE person; map_visibility is a blanket preference.
-- Without the override, a host flipping to 'private' would make their own
-- party unfindable for the people they had just invited to it, and an existing
-- RSVP would silently detach from its pin. The specific act wins over the
-- general setting.
--
-- Still security INVOKER, and that is load bearing. The function already
-- inner-joins public.profiles for host_username, and that table has been
-- block-filtered since 20260814094945 -- so a blocked host's parties already
-- vanish from the map through the join, and map_visibility now rides the exact
-- same row. The follows probe works for the same reason: the follows SELECT
-- policy exposes the viewer's own edges. A definer rewrite would have to
-- restate both rules inline and drift from them (CLAUDE.md #4).
--
-- Written INLINE rather than as a helper, which looks like a violation of
-- CLAUDE.md #4 and is not: there is exactly one call site, so there is no
-- second copy to keep in sync, and the alternative -- a per-row function call
-- on the hottest spatial query in the schema -- would defeat the set-based
-- filter this is. If a second consumer ever appears, THAT is the moment to
-- extract it, the same way can_user_access_party was extracted in 7b.
--
-- DELIBERATELY NOT APPLIED to the proximity notification engine
-- (20260817073509). That engine asks a question about the RECIPIENT -- may we
-- push this at them -- and map_visibility is a statement about the HOST. A
-- host who does not want strangers browsing their pin has said nothing about
-- whether people nearby may be told the party exists; conflating the two would
-- silently gut the notification engine for every private-ish host. The
-- engine's own guard for that question is `not p.is_private`, and it stays the
-- only one.
--
-- Output columns are identical to 20260813095529, so `create or replace` is
-- legal here and keeps the existing grants.
-- ============================================================
create or replace function public.get_parties_near_user(
  map_center_lon double precision,
  map_center_lat double precision,
  radius_meters double precision
)

returns table (
  party_id uuid,
  title text,
  description text,
  starts_at timestamp with time zone,
  is_private boolean,
  is_sponsored boolean,
  party_tier text,
  host_id uuid,
  host_username text,
  lat double precision,
  lon double precision,
  distance_meters double precision,
  going_count int,
  my_rsvp_status public.rsvp_status,
  is_invited boolean
)

language sql
as $$
  select
    p.id as party_id,
    p.title,
    p.description,
    p.starts_at,
    p.is_private,
    p.is_sponsored,
    p.party_tier,
    p.host_id,
    pr.username as host_username,

    -- Grab party location
    st_y(p.location::geometry) as lat,
    st_x(p.location::geometry) as lon,

    -- Distance from current user's map view
    st_distance(p.location, st_point(map_center_lon, map_center_lat)::geography) as distance_meters,

    p.going_count,

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

    -- Only surface parties that are live and haven't ended
    p.status = 'published'
    and (p.ends_at is null or p.ends_at > now())

    -- PostGIS proximity check
    and st_dwithin(p.location, st_point(map_center_lon, map_center_lat)::geography, radius_meters)

    -- The host's map_visibility, plus the party-specific override. Ordered
    -- cheapest-first: the enum compare settles the overwhelming majority of
    -- rows ('public' is the default) before any subquery is considered.
    and (
      pr.map_visibility = 'public'

      -- Your own parties are always on your own map, at every tier.
      or p.host_id = (select auth.uid())

      -- 'followers' = people who follow the HOST. Note the direction: the
      -- viewer is the follower, the host is the followee.
      or (
        pr.map_visibility = 'followers'
        and exists (
          select 1 from public.follows f
          where f.follower_id = (select auth.uid())
            and f.followee_id = p.host_id
        )
      )

      -- The override. Both arms are a deliberate act tying this viewer to THIS
      -- party, which outranks the host's blanket setting -- including at
      -- 'private'.
      or exists (
        select 1 from public.invitations i
        where i.party_id = p.id and i.guest_id = (select auth.uid())
      )
      or exists (
        select 1 from public.rsvps r
        where r.party_id = p.id and r.user_id = (select auth.uid())
      )
    )

    -- Filter which parties to show
    and case
        -- If the viewport is small (Zoomed in)
        when radius_meters <= 15000
        then true

        -- If the viewport is medium (Zoomed out to a region)
        when radius_meters <= 100000
        then p.party_tier in ('large', 'mega')

        -- If the viewport is large (Zoomed out to the globe)
        else
        p.party_tier = 'mega' or p.is_sponsored = true
    end
  order by p.is_sponsored desc, distance_meters asc;
$$;
