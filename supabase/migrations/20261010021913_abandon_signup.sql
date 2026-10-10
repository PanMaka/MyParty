-- abandon_signup: the back arrow on the username screen undoes the sign-up.
--
-- Create Account makes the account at once (auth.users, then handle_new_user's
-- profiles and user_birthdates rows), and the username is picked on the next
-- screen. Going back from there used to sign out and leave that account
-- behind: a placeholder username, onboarding never finished, and an email that
-- now refuses a second registration with "already an account". The user had
-- no way to tell it existed. This removes it, so the refilled register form
-- can be submitted again with anything changed.
--
-- Only an account that has NOT finished onboarding, and only the caller's own.
-- Past onboarding, leaving goes through request_account_deletion and its
-- 30-day grace; this is not a shortcut around that.
--
-- A hard delete, which the engineering rules reserve for account erasure: this
-- is one, for an account that never got as far as being used. It does not
-- tombstone the profile the way complete_account_erasure does, because the
-- tombstone exists to keep authored content attached to "Διαγραμμένος
-- χρήστης", and the FKs below make sure there is none:
--
--   * parties, party_posts, post_comments, messages, reports, blocks and
--     account_erasures reference profiles with NO ACTION. A not-onboarded
--     account that wrote any of them anyway (the API does not check
--     onboarding) makes the profiles delete fail with 23503 and the whole
--     call roll back. Content is never silently lost to this function.
--   * user_birthdates, user_devices, notification_jobs, sent_notifications,
--     follows, invitations, rsvps, post_likes, party_reads, stories and
--     story_views CASCADE, which is what an undo wants.
--
-- auth.users is deleted from SQL rather than through GoTrue's admin API (which
-- account-eraser uses) because nothing here needs the service key: the
-- definer owner holds DELETE on auth.users, and its sessions, refresh tokens
-- and identities cascade from it. Storage is not touched: an account that
-- cannot own a party or a post owns no objects in party-covers or post-media,
-- and a story needs a party it can access, whose bytes the story-cleanup cron
-- collects regardless.
create function public.abandon_signup()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'abandon_signup: not signed in' using errcode = '42501';
  end if;

  -- Locked so a concurrent completeOnboarding cannot land between the check
  -- and the delete.
  perform 1
  from public.profiles p
  where p.id = v_uid
    and p.onboarding_completed_at is null
    and p.deleted_at is null
  for update;

  if not found then
    raise exception 'abandon_signup: sign-up is already complete'
      using errcode = '55000';
  end if;

  delete from public.profiles where id = v_uid;
  delete from auth.users where id = v_uid;
end;
$$;

revoke execute on function public.abandon_signup() from public, anon;
grant execute on function public.abandon_signup() to authenticated;
