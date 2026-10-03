-- Group chat belongs to private parties only. A public party has no chat.
--
-- ===========================================================================
-- WHY THE SECOND CLAUSE IS BEING DELETED, AND WHY THAT IS NOT A MISTAKE
-- ===========================================================================
-- The previous body was:
--
--     can_access_party(p)
--     AND (p.host_id = auth.uid() OR invited OR rsvp'd)
--
-- The second clause is gone. It was NOT lost in an edit, and it is not a
-- narrowing somebody forgot to carry over. It has become unreachable, and
-- leaving it in would be dead code that reads like a live rule.
--
-- 1. THAT CLAUSE EXISTED FOR PUBLIC PARTIES, AND ONLY FOR THEM.
--    `can_access_party` is true for EVERY signed-in user on a public party.
--    Applied to chat as-is, every public party's chat would be a room the
--    whole user base could post in -- a spam surface with no moderation story
--    (see the original header on 20260815095446 and docs/backend-plan.md §6).
--    The participation disjunction was the fix: reading is fine to hand out
--    that broadly, writing is not. With public parties having no chat at all,
--    the problem it solved no longer exists.
--
-- 2. ON A PRIVATE PARTY THE CLAUSE IS A TAUTOLOGY.
--    For a private party `can_access_party` already means host-or-invited.
--    And an rsvps row can only exist where `can_access_party` passed -- the
--    rsvps INSERT policy requires it (20260813095416) -- so on a private party
--    "rsvp'd" IMPLIES "invited or host". Every disjunct is therefore already
--    implied by the first term:
--
--        host_id = auth.uid()  -> can_access_party is true for the host
--        invited               -> can_access_party is true for an invitee
--        rsvp'd                -> the rsvp could only be written by someone
--                                 can_access_party already admitted
--
--    So `can_access_party(p) AND participation` collapses to
--    `can_access_party(p)` on exactly the rows that remain.
--
-- The two facts together are the whole argument: the clause only ever did
-- work on public parties, and public parties are leaving. What is left is
-- genuinely `can_access_party AND is_private`, and writing it that way is
-- honest rather than lossy.
--
-- WHAT THIS DOES NOT CHANGE. Privacy, the invitation requirement, and both
-- directions of the host block all still live inside `can_access_party` and
-- are still not restated here (CLAUDE.md #4). This function is still strictly
-- narrower than `can_access_party` -- the `and` can only remove people -- so
-- it remains structurally incapable of widening access. The difference is
-- that the narrowing is now "public parties have no chat" instead of "public
-- parties have a participants-only chat".
--
-- IF THIS IS EVER REVERSED, THE PARTICIPATION CLAUSE MUST COME BACK WITH IT.
-- Restoring public chat by deleting only the `party_is_private` term would
-- hand every public party's chat to the entire user base -- the exact failure
-- the deleted clause was written to prevent. That is why this comment records
-- the clause verbatim at the top.

create or replace function public.can_chat_in_party(p_party_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select public.can_access_party(p_party_id)
     and public.party_is_private(p_party_id);
$$;

comment on function public.can_chat_in_party(uuid) is
  'Who is IN the conversation. Private parties only since 20260825094044 -- a '
  'public party has no group chat. Still strictly narrower than '
  'can_access_party and still composes it, so every fix to party visibility '
  'keeps reaching chat. The participation disjunction (host/invited/rsvp''d) '
  'was deleted because it is unreachable, NOT because it stopped mattering: '
  'it existed to keep public chat from being world-writable, and on a private '
  'party it is implied by can_access_party. Restoring public chat means '
  'restoring that clause in the same migration.';


-- ===========================================================================
-- The messages already written in public parties.
-- ===========================================================================
-- Hidden with a reason, not silently orphaned and not deleted.
--
-- Doing nothing would leave them invisible anyway -- the messages SELECT
-- policy calls can_chat_in_party, so they drop out of every read path the
-- moment the function above is replaced. But invisible-by-side-effect and
-- hidden-on-purpose look identical to a client and completely different to a
-- moderator: `hidden_at is null` would still be true, so a moderator querying
-- "what was taken down and why" sees nothing, while the author sees their
-- messages vanish with no record that anything happened.
--
-- Deleting them is worse still. UGC deletes are soft here (CLAUDE.md #7);
-- hard delete is reserved for account/GDPR erasure. A product decision to
-- close public chat is not a reason to destroy what people wrote, and
-- export_account_data is SECURITY DEFINER precisely so an author can still
-- retrieve their own words after they stop being readable in-app.
--
-- hidden_by is NULL, which `messages_hidden_consistent` explicitly allows for
-- a system hide -- there is no moderator to name. hidden_reason carries the
-- migration id so the cause is traceable to this file rather than to a
-- person who never acted.
--
-- Idempotent by the `hidden_at is null` guard: a message already hidden by a
-- moderator keeps ITS reason. This must not overwrite a real moderation
-- record with a bookkeeping one.
update public.messages m
set hidden_at = now(),
    hidden_by = null,
    hidden_reason = 'public party chat closed (20260825094044)'
from public.parties p
where p.id = m.party_id
  and not p.is_private
  and m.hidden_at is null;
