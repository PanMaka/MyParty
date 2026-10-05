-- The Messages list drops a party's chat 24 hours after the party ENDS.
--
-- Before this, get_party_chats kept every chat forever ("ended and published
-- both stay: the conversation after a party is half of what the chat is
-- for"). Product decision 2026-10-05: keep the after-party conversation, but
-- only for a day — after that a finished party's chat is clutter in a list
-- whose job is "where are my people right now".
--
-- WHAT THIS DOES NOT CHANGE:
--
--  * Who may chat. can_chat_in_party is untouched (host or invitee, private
--    parties only, 20260825094044), and so are the messages policies, the
--    realtime.messages policy and get_messages. This is the LIST hiding a row,
--    not access being revoked: the history is still there, still readable by
--    the same people, and nothing is deleted or hidden_at-stamped.
--  * A party with NO ends_at. It is kept, the same way the map pins it and MY
--    PARTIES lists it (gotcha 21, still an open decision). Inventing an end
--    here — starts_at + party_end_grace(), say — would make the chat vanish
--    while the party is still on the map and still in MY PARTIES, which is
--    exactly the mismatch between tabs this change exists to remove.
--
-- The 24 hours is a literal with one call site. If a second place ever needs
-- the same number, give it a function the way party_end_grace() was.
--
-- The rest of the body is 20260815095450's, with the search path
-- 20260819095452 pinned. CREATE OR REPLACE keeps the existing grants
-- (execute to authenticated, revoked from public/anon — gotcha 4).

create or replace function public.get_party_chats()
returns table (
  party_id uuid,
  party_title text,
  party_is_private boolean,
  party_starts_at timestamptz,
  going_count int,
  last_message_body text,
  last_message_author_username text,
  last_message_at timestamptz,
  unread_count int
)
language sql
stable
set search_path = public, extensions
as $$
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
    p.going_count,
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
$$;
