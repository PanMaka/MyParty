-- Phase 6, part 4: the two read RPCs.
--
-- Both are deliberately NOT security definer, the same design get_feed
-- (20260814112531) and get_parties_near_user run on. Invoker rights means
-- `from public.messages` evaluates that table's SELECT policy for the calling
-- user -- which is already can_chat_in_party + is_blocked(author) + not
-- hidden -- so neither function restates a single term of it and neither can
-- drift from it when it changes (CLAUDE.md #4). Every WHERE clause below is a
-- NARROWING and is structurally incapable of widening access.


-- ============================================================
-- get_messages -- one page of history, newest first.
--
-- Keyset, never offset (CLAUDE.md #5). messages_party_created_idx is
-- (party_id, created_at desc, id desc) where hidden_at is null, which is the
-- exact order this scans, so the LIMIT stops the scan rather than sorting the
-- party's whole history to throw most of it away.
--
-- The join to public.profiles is doing more than fetching a username: that
-- table has been block-filtered since 20260814094945, so an inner join drops
-- a blocked author's messages independently of the is_blocked term already in
-- the messages SELECT policy. Two mechanisms, same answer -- the same
-- belt-and-braces get_feed has.
-- ============================================================
create function public.get_messages(
  p_party_id uuid,
  p_before_created_at timestamp with time zone default null,
  p_before_id uuid default null,
  p_limit int default 30
)

returns table (
  id uuid,
  party_id uuid,
  author_id uuid,
  author_username text,
  body text,
  created_at timestamp with time zone
)

language sql
stable
as $$
  select
    m.id,
    m.party_id,
    m.author_id,
    pr.username as author_username,
    m.body,
    m.created_at

  from public.messages m
  join public.profiles pr on pr.id = m.author_id

  where m.party_id = p_party_id

    -- Keyset cursor. Both halves travel together; a caller that passes only
    -- the timestamp gets "strictly before that instant", because the zero
    -- uuid is the minimum of the type and no real row can sort below it at
    -- the same timestamp. Ties on created_at are not a corner case in a
    -- group chat -- several people hitting send in the same instant is the
    -- normal busy-party pattern -- which is exactly why id is in the key.
    and (
      p_before_created_at is null
      or (m.created_at, m.id)
         < (p_before_created_at, coalesce(p_before_id, '00000000-0000-0000-0000-000000000000'::uuid))
    )

  order by m.created_at desc, m.id desc
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;


-- ============================================================
-- get_party_chats -- the chat list, with unread counts.
--
-- The CTE is a PERFORMANCE pre-filter, not the access rule. Driving straight
-- off public.parties would call can_chat_in_party once per party the user can
-- see, which on a platform full of public parties is most of the table; the
-- union instead starts from three indexed lookups keyed on the user. The
-- authoritative decision is still the single can_chat_in_party call in the
-- WHERE clause.
--
-- Worth being precise about the failure direction, since the CTE does restate
-- the participation disjunction: because can_chat_in_party ANDs participation
-- with can_access_party, the CTE can only ever be a SUPERSET of the answer,
-- and the helper removes the excess. If the helper's notion of participation
-- ever WIDENS (say followers of the host gain chat access), this CTE goes
-- stale and a chat stops being listed. That is a missing row, never a leaked
-- one -- and the messages policy would still refuse the leak even then.
--
-- Unread count is the one read-time count in this schema, and CLAUDE.md #6
-- forbids those. The rule bends here rather than breaks: unread is inherently
-- per-viewer, so there is no row it could be denormalized onto -- a counter
-- on parties would need one column per user. It is BOUNDED instead: the count
-- runs over a `limit 100` subquery riding messages_party_created_idx, so it
-- reads at most 100 index entries per chat no matter how far behind the user
-- is, and the client renders 100 as "99+". That keeps the cost independent of
-- backlog size, which is the property #6 actually exists to protect.
--
-- Hidden and blocked-author messages are excluded from both the count and the
-- preview for free, because the subqueries go through the messages SELECT
-- policy. A moderated line must not leave a phantom +1 on the badge.
-- ============================================================
create function public.get_party_chats()

returns table (
  party_id uuid,
  party_title text,
  party_is_private boolean,
  party_starts_at timestamp with time zone,
  going_count int,
  last_message_body text,
  last_message_author_username text,
  last_message_at timestamp with time zone,
  unread_count int
)

language sql
stable
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
    -- Defence in depth behind the revoke below, and the same guard get_feed
    -- carries: a session with no uid has no participation set to build a
    -- chat list from, so every arm of the CTE is empty anyway. Stated
    -- explicitly so the function stays correct if it is ever granted more
    -- broadly or called from service_role with no JWT.
    (select auth.uid()) is not null

    and public.can_chat_in_party(p.id)

    -- A cancelled party's chat is not a place to keep talking. Ended and
    -- published both stay: the conversation after a party is half of what
    -- the chat is for.
    and p.status <> 'cancelled'

  -- Busiest conversation first; a chat with no messages yet sorts by when
  -- the party is happening, so a freshly created party is reachable instead
  -- of stranded at the bottom of the list.
  order by
    last_msg.created_at desc nulls last,
    p.starts_at asc;
$$;


-- ============================================================
-- Functions are executable by PUBLIC by default and that default is wrong
-- for both of these. Table privileges are checked when a statement runs
-- regardless of whether its WHERE clause could ever be true (CLAUDE.md
-- gotcha #4), so an anonymous caller would hit "permission denied for table
-- messages" -- a confusing error that also advertises the query's internals.
-- Making the functions authenticated-only turns that into the honest answer:
-- there is no anonymous chat.
-- ============================================================
revoke execute on function public.get_messages(uuid, timestamp with time zone, uuid, int) from public;
grant execute on function public.get_messages(uuid, timestamp with time zone, uuid, int)
  to authenticated, service_role;

revoke execute on function public.get_party_chats() from public;
grant execute on function public.get_party_chats()
  to authenticated, service_role;
