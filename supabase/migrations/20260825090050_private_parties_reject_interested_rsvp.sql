-- A private party accepts only 'going'. Enforced in the rsvps policies, not
-- in the client.
--
-- WHY THIS IS A POLICY AND NOT A CHECK CONSTRAINT. The rule spans two tables:
-- the status is on `rsvps`, the privacy is on `parties`. A CHECK constraint
-- cannot reference another table, so the choice is a policy or a row trigger.
-- The policy is the right one *for the threat being closed*: the concern is a
-- hand-rolled PostgREST call from a modified client, and every such call goes
-- through RLS by construction. See the ceiling note at the bottom.
--
-- WHY A DEFINER HELPER RATHER THAN AN INLINE `exists`. Gotcha 1: "is this
-- party private" is a question about the PARTY, not about the caller, so it
-- must not be answered through the caller's filtered view of `public.parties`.
-- Inlined, the sub-select would be evaluated under the parties SELECT policy,
-- and a row the caller cannot see returns *no rows* -- which reads as
-- "not private" and silently permits the very write this migration forbids.
-- The INSERT policy's existing `can_access_party` term makes that unreachable
-- today, but it is unreachable by accident of ordering, not by construction,
-- and this is exactly the shape of gotcha 1's original bug.
--
-- The helper is deliberately narrow and takes no user: privacy is not
-- viewer-dependent, so unlike `can_user_access_party` (gotcha 11) there is no
-- per-user variant to parameterise.

create or replace function public.party_is_private(p_party_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select p.is_private from public.parties p where p.id = p_party_id),
    -- A party that does not exist cannot be RSVP'd to at all -- the FK
    -- rejects it -- so this arm is unreachable. `true` rather than `false`
    -- because if it ever does become reachable, refusing is the safe answer.
    true
  );
$$;

comment on function public.party_is_private(uuid) is
  'True when the party is private. SECURITY DEFINER because privacy is a '
  'property of the party, not of the viewer: answered through the caller''s '
  'filtered view of public.parties, an invisible row would read as public.';

revoke execute on function public.party_is_private(uuid) from public;
grant execute on function public.party_is_private(uuid) to authenticated;

-- The rule itself, in one place (CLAUDE.md #4). Both write policies call this
-- rather than repeating the disjunction, so INSERT and UPDATE cannot drift.
create or replace function public.rsvp_status_allowed(
  p_party_id uuid,
  p_status public.rsvp_status
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_status = 'going' or not public.party_is_private(p_party_id);
$$;

comment on function public.rsvp_status_allowed(uuid, public.rsvp_status) is
  'A private party accepts only ''going'' -- there is no interested count on '
  'a private party on any surface, so an interested row would be attendance '
  'data the product has promised not to hold.';

revoke execute on function public.rsvp_status_allowed(uuid, public.rsvp_status) from public;
grant execute on function public.rsvp_status_allowed(uuid, public.rsvp_status) to authenticated;

-- Re-create both write policies with the new term. Dropping and re-creating
-- rather than editing 20260813095416: migrations are append-only (CLAUDE.md
-- #7), and `create policy` has no `or replace`.
--
-- The `can_access_party` term is UNCHANGED and still carries the visibility
-- rule. This migration adds a second, orthogonal question -- not "may you
-- RSVP to this" but "may this party hold that answer".

drop policy "Users can rsvp to parties they can access" on public.rsvps;

create policy "Users can rsvp to parties they can access"
on public.rsvps for insert to authenticated
with check (
  user_id = (select auth.uid())
  and public.can_access_party(party_id)
  and public.rsvp_status_allowed(party_id, status)
);

-- UPDATE needs it too, and needs it in the WITH CHECK rather than the USING.
-- USING sees the OLD row and answers "may you touch this"; WITH CHECK sees
-- the NEW one and answers "may the result exist". Putting the status rule in
-- USING would test the status being replaced, which permits exactly the write
-- being forbidden: an existing 'going' row updated to 'interested' passes a
-- USING check on the old value.
drop policy "Users can update their own rsvp" on public.rsvps;

create policy "Users can update their own rsvp"
on public.rsvps for update to authenticated
using ( user_id = (select auth.uid()) )
with check (
  user_id = (select auth.uid())
  and public.can_access_party(party_id)
  and public.rsvp_status_allowed(party_id, status)
);

-- DELETE is deliberately untouched. Un-RSVPing is `delete from rsvps`, not a
-- third enum value: see the header of the counters trigger (20260813095451),
-- whose DELETE branch already decrements, and note that `rsvp_status` has
-- exactly two values. Adding 'declined' would put a third state into
-- `my_rsvp_status` on three read RPCs to record an absence the absent row
-- already records.
--
-- THE CEILING, stated so nobody mistakes this for more than it is: an RLS
-- policy binds callers that go through RLS. A future SECURITY DEFINER RPC
-- that inserts rsvps would bypass all three of these policies, and must call
-- `rsvp_status_allowed` itself. Nothing writes rsvps server-side today --
-- `create_party_with_invites` writes `invitations`, not `rsvps` -- so the
-- policy is currently the complete enforcement surface. If that stops being
-- true, this rule moves to a `before insert or update` row trigger, which is
-- the only placement no caller can route around.
