-- THE load-bearing half of Phase 3: a block is worthless if it only governs
-- the tables Phase 3 adds. Every policy that already shipped in Phases 0
-- and 2 was audited one by one; this file rewrites the five that leaked and
-- the one helper that everything else inherits from.
--
-- Audited and deliberately LEFT ALONE:
--   profiles UPDATE, parties INSERT/UPDATE/DELETE
--     -- all self-only (auth.uid() = id / host_id). A block cannot reach a
--     row you own, so there is nothing to filter.
--   rsvps DELETE
--     -- must stay unconditional. If you block a host you were going to,
--     adding a block check here would trap you as an attendee forever.
--   rsvps INSERT/UPDATE, storage "Party cover images follow party
--   visibility", storage "Post media follows party visibility"
--     -- these route through can_access_party (directly, or via a subquery
--     on public.parties that re-evaluates the parties SELECT policy), so
--     patching the helper below covers all four for free. That inheritance
--     is the whole point of CLAUDE.md #4.
--   storage avatars SELECT/INSERT/UPDATE/DELETE
--     -- the three write policies are self-only. The read policy is not
--     worth changing: 20260812124217 creates the avatars bucket with
--     public = true, so it is served over the public CDN path without
--     evaluating RLS at all. An is_blocked check there would look like
--     privacy while changing nothing. Hiding avatars from a blocked user
--     requires moving the bucket to private + signed URLs, which is a
--     Phase 8 change, not a policy edit.


-- ============================================================
-- 1. profiles SELECT -- "we don't appear in each other's search".
-- Was `using (true)`.
-- ============================================================
drop policy "Profiles are viewable by everyone" on public.profiles;

create policy "Profiles are viewable by everyone except blocked pairs"
on public.profiles for select
using ( not public.is_blocked((select auth.uid()), id) );


-- ============================================================
-- 2. can_access_party -- "I don't see their parties on the map".
--
-- The policy text on public.parties is NOT touched: it already reads
-- `using (public.can_access_party(id))`, so the block lands in one place
-- and every current and future caller inherits it -- rsvps INSERT/UPDATE,
-- both storage party-media policies, and the Phase 4-6 feed/stories/chat
-- policies that the plan says will reuse this same helper.
--
-- Still security definer with a pinned search_path, so the RLS recursion
-- that 20260812121153 fixed does not come back: this function must not
-- re-enter the policies on parties/invitations, and adding a call to
-- is_blocked (also security definer, reading only public.blocks) keeps
-- that property.
--
-- The host check is symmetric via is_blocked, so it covers both "I blocked
-- the host" and "the host blocked me" in a single term.
-- ============================================================
create or replace function public.can_access_party(p_party_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1
    from public.parties p
    where p.id = p_party_id
    and not public.is_blocked((select auth.uid()), p.host_id)
    and (
      not p.is_private
      or p.host_id = (select auth.uid())
      or exists (
        select 1
        from public.invitations i
        where i.party_id = p.id
        and i.guest_id = (select auth.uid())
      )
    )
  );
$$;


-- ============================================================
-- 3. invitations SELECT -- both arms leaked.
--
-- Host arm: a host must not keep reading the guest-list row of someone
-- they now have a block with.
-- Guest arm: the old `or guest_id = (select auth.uid())` was unconditional,
-- so an invitation from a host I blocked stayed visible to me. It now
-- defers to can_access_party, which already encodes "not blocked with the
-- host, and either the party is public or I hold an invitation" -- and for
-- this row the invitation trivially exists, so the only thing it actually
-- adds here is the block check. Reusing the helper beats re-deriving the
-- host relationship inline (CLAUDE.md #4).
-- ============================================================
drop policy "Hosts can view guest lists for their parties" on public.invitations;

create policy "Hosts can view guest lists for their parties"
on public.invitations for select to authenticated
using (
  (
    exists (
      select 1 from public.parties
      where parties.id = invitations.party_id
      and parties.host_id = (select auth.uid())
    )
    and not public.is_blocked((select auth.uid()), invitations.guest_id)
  )
  or (
    invitations.guest_id = (select auth.uid())
    and public.can_access_party(invitations.party_id)
  )
);


-- ============================================================
-- 4. invitations INSERT -- "they can't invite me", literally.
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
);


-- ============================================================
-- 5. rsvps SELECT -- the host arm reads another user's row, so it needs
-- the block check. The `user_id = (select auth.uid())` arm stays
-- unfiltered, deliberately: it is what lets someone who blocked a host
-- still see -- and therefore delete -- the rsvp they made earlier.
-- ============================================================
drop policy "Rsvps are viewable by the host or the rsvper" on public.rsvps;

create policy "Rsvps are viewable by the host or the rsvper"
on public.rsvps for select to authenticated
using (
  rsvps.user_id = (select auth.uid())
  or (
    exists (
      select 1 from public.parties
      where parties.id = rsvps.party_id
      and parties.host_id = (select auth.uid())
    )
    and not public.is_blocked((select auth.uid()), rsvps.user_id)
  )
);
