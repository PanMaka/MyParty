-- get_my_parties: MY PARTIES, with the shared "is it over" rule applied on the
-- server.
--
-- MY PARTIES was three plain PostgREST selects (rsvps, parties by host,
-- invitations) merged in Dart, and "is it over" was decided in Dart too:
-- `ends_at == null || ends_at > now`. That was the map's rule until
-- 20261008150440 gave the map, ALL PARTIES and get_party one predicate with the
-- six-hour grace -- after which MY PARTIES was the one surface still listing a
-- null-ends_at party forever, under HAPPENING NOW, weeks after it ended.
--
-- Copying the grace into Dart would be a second definition of a number that
-- has exactly one (party_end_grace), and PostgREST cannot express
-- `starts_at > now() - grace` without the client computing that timestamp
-- itself. So the merge moves to the server, where the predicate already lives.
--
-- SECURITY INVOKER: the parties SELECT policy still decides visibility, exactly
-- as it did for the three selects this replaces, so nothing here re-implements
-- it. The three sources are the same three, driven from the CALLER's own rows
-- (each lookup has an index: parties_host_id_idx, rsvps_user_status_idx,
-- invitations_guest_id_idx), so the policy runs only on parties that are
-- already the caller's -- never a scan of public.parties.
--
-- COUNTERS ARE PASSED THROUGH, including on private rows, unchanged from the
-- selects this replaces. Everyone in this list is the host, an invitee or an
-- RSVP'd participant -- the same people get_party_chats already transmits
-- going_count to. The UI renders no count on a private row (_rsvpRow's guard);
-- ChatScreen's member count uses going_count.
--
-- Bounded, not keyset-paginated: a personal list, not a feed (as before). With
-- finished parties gone the set is small; the bound is a ceiling, not a page.

create or replace function public.get_my_parties()
returns table (
  party_id uuid,
  title text,
  starts_at timestamp with time zone,
  ends_at timestamp with time zone,
  is_private boolean,
  going_count integer,
  interested_count integer,
  my_rsvp_status public.rsvp_status,
  is_host boolean,
  is_invited boolean
)
language sql
set search_path to 'public', 'extensions'
as $$
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
    p.starts_at,
    p.ends_at,
    p.is_private,
    p.going_count,
    p.interested_count,
    -- At most one rsvps row per (party, user) -- it is the primary key -- so
    -- this picks THE status, not one of several.
    (array_agg(m.status) filter (where m.status is not null))[1] as my_rsvp_status,
    bool_or(m.is_host) as is_host,
    bool_or(m.is_invited) as is_invited
  from mine m
  join public.parties p on p.id = m.party_id
  -- NOT OVER. The shared predicate, identical to get_parties_near_user,
  -- get_parties_list and get_party (20261008150440, gotcha 21).
  -- `published` also drops drafts and cancellations, as the selects did.
  where p.status = 'published'
    and (p.ends_at is null or p.ends_at > now())
    and (
      p.ends_at is not null
      or p.starts_at > (select now() - public.party_end_grace())
    )
  group by p.id
  order by p.starts_at, p.id
  limit 200;
$$;

comment on function public.get_my_parties() is
  'MY PARTIES: parties the caller RSVP''d to, hosts, or is invited to, one row '
  'per party with the flags merged, finished parties excluded by the same '
  'predicate as the map and ALL PARTIES. SECURITY INVOKER.';

-- Gotcha 4: the body mentions rsvps and invitations, which anon holds no
-- SELECT on, so anon is refused at EXECUTE rather than left to error inside.
revoke execute on function public.get_my_parties() from public;
grant execute on function public.get_my_parties() to authenticated;
