-- Phase 8, part 1: the two privacy columns the profile screen has been
-- pretending to have, plus the helper that makes one of them enforceable.
--
-- Both columns are preferences about OTHER people's access to me, and both are
-- expressed in follow terms because that is the entire social graph
-- (20260814094943 removed the friendship concept deliberately;
-- docs/backend-plan.md 3.1). They point in OPPOSITE directions along that same
-- edge, and getting them backwards is the single easiest mistake in this phase:
--
--   map_visibility  'followers'  -> people who follow ME     (follows.followee_id = me)
--   invite_policy   'following'  -> people I follow          (follows.follower_id = me)
--
-- That asymmetry is not an oversight. "Who may watch where I am" is answered by
-- my audience; "who may put something in my invitations list" is answered by
-- who I have chosen to pay attention to. A symmetric rule would either let
-- anyone who follows me invite me -- which is the spam vector, following is
-- unilateral -- or hide my parties from everyone I have not followed back.
--
-- Enums rather than text + CHECK: the tier set is closed, and both are read
-- inside a policy and a hot spatial query where an enum compares as an int.
-- Adding a tier later is `alter type ... add value`, which is exactly the
-- ceremony a privacy tier deserves.


-- ============================================================
-- The columns.
--
-- Both default to the PERMISSIVE value, and that is what keeps this migration
-- backwards compatible: every existing row, every seeded persona and every
-- pgTAP assertion from Phases 0-7 keeps the behaviour it had, because 'public'
-- and 'anyone' are precisely today's unconditional rules.
--
-- `grant update on public.profiles to authenticated` (20260812115436) is
-- table-wide, so these are client-writable the moment they exist. That is
-- correct here -- they are the user's own preferences, the same shape as the
-- notification columns in 20260817073507 -- and it is why they are deliberately
-- NOT added to protect_credibility_score (20260814094943). That trigger exists
-- for SYSTEM-maintained columns (credibility_score, follower_count,
-- following_count); freezing a preference the user is supposed to set would
-- make the toggle silently do nothing, which is the failure mode this whole
-- phase exists to prevent.
-- ============================================================
create type public.map_visibility as enum ('public', 'followers', 'private');
create type public.invite_policy  as enum ('anyone', 'following');

alter table public.profiles
  add column map_visibility public.map_visibility not null default 'public',
  add column invite_policy  public.invite_policy  not null default 'anyone';

comment on column public.profiles.map_visibility is
  'Who sees this user''s hosted parties as map pins. ''followers'' means people who follow THEM (follows.followee_id = this user). Enforced inside get_parties_near_user, never client-side.';
comment on column public.profiles.invite_policy is
  'Who may add this user to a guest list. ''following'' means people THEY follow (follows.follower_id = this user) -- the opposite direction from map_visibility. Enforced in the invitations INSERT policy.';


-- ============================================================
-- accepts_invite_from -- THE invite_policy rule, in one place (CLAUDE.md #4).
--
-- Argument order is (guest, inviter) and not the other way round, because the
-- policy belongs to the guest: invite_policy answers "who may invite ME". The
-- inviter is the subject being judged, so it goes second, the same way
-- is_blocked's symmetry makes its order irrelevant and this one's does not.
--
-- security definer is required, not stylistic -- CLAUDE.md gotcha #1. This
-- reads ANOTHER user's public.profiles row to answer a global question, and the
-- profiles SELECT policy has been block-filtered since 20260814094945. Under
-- invoker rights a host whose guest had blocked them would read no row at all,
-- and the function would answer "no such preference" rather than "refused" --
-- the failure direction that lets an invite through. It returns only a boolean,
-- so it leaks neither the setting nor the follow edge.
--
-- The exists() wrapper is doing real work: a guest with no profiles row yields
-- false, i.e. REFUSE. For an invitation that is the safe direction. (Contrast
-- in_quiet_hours (20260817073507), where a missing row returns false meaning
-- "no quiet hours" -- there the safe direction is the other way, because
-- failing closed would silently defer every notification for a user whose
-- profile is mid-creation.)
--
-- No revoke/grant ceremony: this is a POLICY helper, evaluated as the caller
-- inside a with-check, exactly like is_blocked and can_access_party. The
-- default PUBLIC execute grant is what makes that work. The functions that get
-- their execute revoked are the engine-internal ones (in_quiet_hours,
-- quiet_hours_end_at) which no client role should ever call directly.
-- ============================================================
create or replace function public.accepts_invite_from(p_guest_id uuid, p_inviter_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1
    from public.profiles pr
    where pr.id = p_guest_id
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
  'True if the guest''s invite_policy permits an invitation from this inviter. Definer because it reads another user''s block-filtered profiles row.';
