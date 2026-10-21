-- Phase 45, part 2: the three definer helpers that read a private setting
-- answer only about the CALLER.
--
-- 20261021121734 made the settings owner-only on the table, and
-- 40_profile_private_columns proved no read RPC returns them. What it did not
-- cover is the boolean helpers. Each is security definer, reads a private
-- column for an id it is GIVEN, and is executable by clients -- because RLS
-- policies call them, and a policy expression runs as the querying role:
--
--   has_location_consent(user)        authenticated  -> anyone's location_consent
--   accepts_dm_from(recipient, sender) PUBLIC, so anon too -> anyone's dm_policy:
--       pass a sender the recipient follows (the follow graph is readable)
--       and 'following' answers true where 'nobody' answers false
--   accepts_invite_from(guest, inviter) PUBLIC, so anon too -> invite_policy,
--       the same way
--
-- Every call site passes auth.uid() as the "me" argument (audited: the
-- user_devices WITH CHECK, upsert_user_device, the invitations INSERT policy,
-- create_party_with_invites, invite_to_party, the direct_threads policy and
-- get_or_create_direct_thread). So each now answers false unless that
-- argument IS the caller. What is left is "does X accept a DM / an invite from
-- ME", which the caller learns anyway by trying, and which the refusals were
-- deliberately left indistinguishable for (one message, 42501).
--
-- No engine calls these for another user. If one ever needs to, gotcha 11
-- applies: a parameterised variant held back from the client roles, not a
-- weaker guard here.
--
-- Bodies otherwise as in 20260816083807, 20261010102726 and 20260819082840.


create or replace function public.has_location_consent(p_user_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select p_user_id = (select auth.uid())
     and coalesce(
       (select p.location_consent from public.profiles p where p.id = p_user_id),
       false
     );
$$;

comment on function public.has_location_consent(uuid) is
  'True only if p_user_id is the caller, the profile exists and location_consent '
  'is set. Called from the user_devices WITH CHECK and upsert_user_device. '
  'Answers about the caller only (Phase 45): location_consent is owner-only.';


create or replace function public.accepts_dm_from(p_recipient_id uuid, p_sender_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select p_sender_id = (select auth.uid())
     and exists (
       select 1
       from public.profiles pr
       where pr.id = p_recipient_id
         and pr.deleted_at is null
         and pr.onboarding_completed_at is not null
         and (
           pr.dm_policy = 'everyone'
           or (
             pr.dm_policy = 'following'
             and exists (
               select 1
               from public.follows f
               where f.follower_id = p_recipient_id
                 and f.followee_id = p_sender_id
             )
           )
         )
     );
$$;

comment on function public.accepts_dm_from(uuid, uuid) is
  'True if the sender is the caller, the recipient has finished onboarding, has '
  'not requested deletion, and their dm_policy admits the caller. Does not '
  'consider blocks -- callers compose is_blocked. Caller-only since Phase 45.';


create or replace function public.accepts_invite_from(p_guest_id uuid, p_inviter_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select p_inviter_id = (select auth.uid())
     and exists (
       select 1
       from public.profiles pr
       where pr.id = p_guest_id
         and pr.deleted_at is null
         and (
           pr.invite_policy = 'anyone'
           or exists (
             select 1
             from public.follows f
             where f.follower_id = p_guest_id
               and f.followee_id = p_inviter_id
           )
         )
     );
$$;

comment on function public.accepts_invite_from(uuid, uuid) is
  'True if the inviter is the caller, and the guest''s invite_policy permits an '
  'invitation from them and the guest has not requested deletion. '
  'Caller-only since Phase 45.';


-- The two that still held PUBLIC's default. authenticated keeps EXECUTE: the
-- invitations and direct_threads policies call them as the querying role.
revoke execute on function public.accepts_dm_from(uuid, uuid) from public, anon;
grant  execute on function public.accepts_dm_from(uuid, uuid) to authenticated;

revoke execute on function public.accepts_invite_from(uuid, uuid) from public, anon;
grant  execute on function public.accepts_invite_from(uuid, uuid) to authenticated;
