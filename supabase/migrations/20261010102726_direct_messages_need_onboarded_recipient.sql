-- Phase 33, part 6: nobody can be messaged before they have finished signing up.
--
-- abandon_signup (20261010021913) lets an account that has NOT finished
-- onboarding undo itself with a hard delete of its profiles row, and relies on
-- every authored-content FK into profiles being NO ACTION so that an account
-- which somehow wrote something fails the delete instead of losing it. The DM
-- tables joined that set: direct_threads.user_low/user_high/created_by,
-- direct_messages.author_id and direct_reads.user_id all reference profiles
-- with NO ACTION.
--
-- The half that needed closing is the one the abandoning user does not
-- control. accepts_dm_from checked only that the recipient exists and is not
-- pending deletion, so ANOTHER user could open a thread with an account still
-- on the username screen -- and that thread's row alone would make the new
-- account's back arrow fail with 23503, permanently, for a reason it cannot
-- see or fix.
--
-- So the recipient must have finished onboarding. It is also simply right on
-- its own: a half-created account has a placeholder username and has agreed
-- to nothing yet. Nothing changes for the SENDER -- the existing gates are
-- about whom you may message, and a not-onboarded account has no UI path to
-- the Message button anyway.
--
-- Recreated in full (append-only); the only change from 20261009095551 is the
-- onboarding_completed_at line.
create or replace function public.accepts_dm_from(p_recipient_id uuid, p_sender_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
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
  'True if the recipient has finished onboarding, has not requested deletion, and their dm_policy admits this sender. Does not consider blocks -- callers compose is_blocked.';
