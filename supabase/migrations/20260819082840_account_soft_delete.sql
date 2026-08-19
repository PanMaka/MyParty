-- Phase 9, part 1: soft delete, and the eight foreign keys that stop cascading.
--
-- Read docs/phase-09-fk-audit.md before changing anything here. The short
-- version of why this migration exists at all:
--
--   23 of the schema's 36 foreign keys point at public.profiles(id), 18 of
--   them `on delete cascade`, and profiles.id cascades from auth.users. So
--   `delete from auth.users` today walks profiles -> parties (as host) ->
--   invitations, rsvps, party_posts, messages, party_reads, stories -> post
--   likes, comments, story_views. Deleting ONE user erases every message
--   every OTHER user ever wrote in any party that user hosted.
--
-- That is the schema as it stands, not a hypothetical: it is what the Supabase
-- dashboard's delete-user button does. This file makes the destructive part
-- structurally impossible before part 2 gives anyone a button that triggers it.
--
-- The mechanism is a TOMBSTONE PROFILE: the auth.users row is hard-deleted,
-- the profiles row survives, scrubbed. Authored content keeps pointing at a
-- real, still-selectable row, so nothing has to be nullable and no policy has
-- to change. The alternative -- nullable author_id with `on delete set null`
-- -- was rejected because get_feed, get_messages, get_party_chats,
-- get_post_comments, get_party_stories and get_parties_near_user all reach the
-- author through an INNER JOIN on public.profiles under invoker rights: a
-- profile row that is missing, or merely invisible under RLS, silently drops
-- the message from the result. Six RPCs and every is_blocked term in every
-- authored-content policy would have to move, to render one label.


-- ============================================================
-- 1. The two markers.
--
-- deleted_at  -- soft deleted, RECOVERABLE. The account still belongs to a
--                person who can sign back in and take it back.
-- erased_at   -- tombstoned, GONE. The auth.users row no longer exists and
--                nothing here can bring the person back.
--
-- Two columns rather than one status enum because they answer questions asked
-- by different readers at different times, and the ordering between them is an
-- invariant worth having the database check. The client shows
-- "Διαγραμμένος χρήστης" on erased_at, never on deleted_at: during the grace
-- period the account is still that person's, and re-labelling their messages
-- the moment they tap delete would break the thread twice -- once on delete
-- and once again on restore.
--
-- Note the disclosure this makes, since RLS cannot hide a column (gotcha #8):
-- anyone who can already see a profiles row can see that its owner has a
-- deletion pending. Accepted rather than solved with a side table, because the
-- grace period suppresses that profile from every discovery surface anyway, so
-- reading the column requires already knowing the id.
-- ============================================================
alter table public.profiles
  add column deleted_at timestamptz,
  add column erased_at  timestamptz;

-- Erasure without a preceding deletion request is not a state this system can
-- reach; if it ever does, something skipped the grace period.
alter table public.profiles
  add constraint profiles_erased_implies_deleted
  check (erased_at is null or deleted_at is not null);

-- Partial, because the only query that scans by these is the erasure sweep
-- asking "who is past grace and not yet erased", and that set is empty almost
-- always.
create index profiles_pending_erasure_idx
  on public.profiles (deleted_at)
  where deleted_at is not null and erased_at is null;

comment on column public.profiles.deleted_at is
  'Soft delete. Non-null means the account is scheduled for erasure and hidden from discovery, but is still recoverable by signing in. See docs/phase-09-fk-audit.md.';
comment on column public.profiles.erased_at is
  'Tombstone. Non-null means auth.users is gone and this row is an anonymised placeholder that exists only so authored content keeps a valid author.';


-- ============================================================
-- 2. profiles.id -> auth.users: the FK has to go.
--
-- A row cannot outlive the row it references, and `id` is the primary key, so
-- `on delete set null` is not available -- there is no third option here. This
-- is the one real cost of the tombstone design and it is called out in
-- docs/phase-09-fk-audit.md §6.4.
--
-- What is lost: the database guarantee that every profile has an auth user.
-- What replaces it: an assertion in 12_account_lifecycle.test.sql that every
-- profile with `deleted_at is null` has a matching auth.users row, so a
-- genuine orphan -- the failure this FK was actually protecting against --
-- still fails CI. A tombstone is an orphan on purpose and is excluded by that
-- predicate rather than by weakening the check.
--
-- handle_new_user still creates the row on signup; nothing about the happy
-- path changes.
-- ============================================================
alter table public.profiles
  drop constraint profiles_id_fkey;


-- ============================================================
-- 3. The seven cascades that become `no action`.
--
-- Every FK below points at profiles(id) and today says `on delete cascade`.
-- Each one is re-created identically except for the action. This is not
-- ceremony: after this migration nothing ever deletes a profiles row, so a
-- cascade here is not a behaviour, it is a loaded gun aimed at whoever next
-- runs a delete by hand against a database at 2am. `no action` makes that
-- delete fail loudly instead of quietly taking a party's entire chat history
-- with it.
--
-- Everything NOT in this list keeps its cascade deliberately -- see the DELETE
-- column of the audit's §3 table. rsvps, invitations, follows, post_likes,
-- stories, story_views, party_reads, user_devices, notification_jobs and
-- sent_notifications are all removed by the erasure function explicitly, and
-- their cascade is the correct action for the object-scoped deletes that
-- remain (deleting a post really should take its likes).
-- ============================================================

-- parties.host_id -- the widest blast radius in the schema. Cascading here is
-- what turns one account deletion into a party's worth of other people's
-- messages. Past parties are a shared record and are retained indefinitely
-- (retention policy, docs/backend-plan.md 7.2); future ones are cancelled at
-- soft-delete time by request_account_deletion below.
alter table public.parties drop constraint parties_host_id_fkey;
alter table public.parties add constraint parties_host_id_fkey
  foreign key (host_id) references public.profiles(id) on delete no action;

-- messages.author_id -- the case that started this audit. A deleted user's
-- messages stay in the thread, attributed to the tombstone.
alter table public.messages drop constraint messages_author_id_fkey;
alter table public.messages add constraint messages_author_id_fkey
  foreign key (author_id) references public.profiles(id) on delete no action;

-- party_posts.author_id -- same argument as messages, plus a post owns a
-- comment thread and a like count that belong to other people.
alter table public.party_posts drop constraint party_posts_author_id_fkey;
alter table public.party_posts add constraint party_posts_author_id_fkey
  foreign key (author_id) references public.profiles(id) on delete no action;

-- post_comments.author_id -- a comment thread with holes in it is exactly the
-- failure the tombstone exists to prevent.
alter table public.post_comments drop constraint post_comments_author_id_fkey;
alter table public.post_comments add constraint post_comments_author_id_fkey
  foreign key (author_id) references public.profiles(id) on delete no action;

-- reports.reporter_id -- moderation evidence. Cascading makes "report someone,
-- then delete your account" an erasure vector against the moderation queue.
-- Retention is covered by GDPR Art. 17(3)(e) (legal claims) and the tombstone
-- makes the retained reporter pseudonymous.
alter table public.reports drop constraint reports_reporter_id_fkey;
alter table public.reports add constraint reports_reporter_id_fkey
  foreign key (reporter_id) references public.profiles(id) on delete no action;

-- blocks, BOTH directions -- the one place a cascade actively harms a user who
-- is still here. is_blocked is symmetric (20260814094943), so removing the
-- edge in either direction un-hides content the surviving party deliberately
-- hid: B blocks A, A deletes their account, and A's retained messages
-- reappear in B's chat. The edge is kept as a pseudonymous link to a tombstone.
alter table public.blocks drop constraint blocks_blocker_id_fkey;
alter table public.blocks add constraint blocks_blocker_id_fkey
  foreign key (blocker_id) references public.profiles(id) on delete no action;

alter table public.blocks drop constraint blocks_blocked_id_fkey;
alter table public.blocks add constraint blocks_blocked_id_fkey
  foreign key (blocked_id) references public.profiles(id) on delete no action;


-- ============================================================
-- 4. request_account_deletion -- the in-app entry point's one call.
--
-- Everything here happens at T+0, not at T+30d, and the split is the whole
-- point of the function. The grace period exists so a person can change their
-- mind about their ACCOUNT; it is not a licence to keep processing their data
-- for another month. So:
--
--   * user_devices, notification_jobs and sent_notifications are purged NOW.
--     user_devices holds last_location -- the highest-risk column in the
--     schema -- and a live push token. Both must stop existing when the user
--     says stop, which is the same GDPR Art. 7(3) immediacy argument that made
--     claim_notification_jobs re-ask the consent gates (7c).
--   * consent flags go false, for the same reason and so that the withdrawal
--     trigger from 7a fires on location_consent true->false.
--   * parties that have not started are cancelled, so nobody turns up to an
--     event with no host. Parties that already happened are untouched.
--
-- and NOTHING authored is touched. Content stays visible and attributed for 30
-- days: the account is recoverable, and breaking a conversation now so it can
-- un-break on restore is worse than leaving it alone.
--
-- It takes no user id: it acts on auth.uid() and cannot be aimed at anyone
-- else. Deleting someone else's account is not a privilege this system grants
-- to any client role.
--
-- security DEFINER, for two independent reasons and neither is convenience:
--
--   1. notification_jobs and sent_notifications are engine-internal -- RLS on,
--      zero policies, zero client grants. Table privileges are checked whether
--      or not a where clause could match (gotcha #4), so an invoker-rights
--      function that so much as names them errors with 42501 for every caller.
--   2. deleted_at is frozen against client roles by the trigger in section 7,
--      and that guard keys on current_user, which security invoker does not
--      change. A definer function runs as the owner and is therefore the only
--      thing that can write the column -- which is the entire point of
--      freezing it.
-- ============================================================
create or replace function public.request_account_deletion()
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_now timestamptz := now();
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  -- Idempotent: tapping delete twice returns the original date rather than
  -- silently restarting the 30-day clock, which would be the wrong direction
  -- to fail in.
  select p.deleted_at into v_now
  from public.profiles p
  where p.id = v_uid and p.deleted_at is not null;

  if found then
    return v_now;
  end if;

  v_now := now();

  update public.profiles
  set deleted_at       = v_now,
      location_consent = false,
      push_consent     = false,
      analytics_consent = false
  where id = v_uid;

  -- Stop processing immediately. These three are engine-internal and hold no
  -- content anyone could appeal; see the audit's PURGE NOW rows.
  delete from public.user_devices        where user_id = v_uid;
  delete from public.notification_jobs   where user_id = v_uid;
  delete from public.sent_notifications  where user_id = v_uid;

  -- Future parties only. `status = 'published'` and a start in the future is
  -- exactly the set get_parties_near_user shows on the map, which is why part
  -- 1 needs no change to that RPC: cancelling here is what removes them.
  update public.parties
  set status = 'cancelled'
  where host_id = v_uid
    and status = 'published'
    and start_time > v_now;

  return v_now;
end;
$$;

revoke execute on function public.request_account_deletion() from public, anon;
grant  execute on function public.request_account_deletion() to authenticated;

comment on function public.request_account_deletion() is
  'Soft-deletes the CALLING user. Purges devices/jobs/notifications and cancels future parties immediately; authored content is untouched until erasure at T+30d. Returns the deletion timestamp.';


-- ============================================================
-- 5. cancel_account_deletion -- the way back.
--
-- Deliberately does NOT un-cancel parties. Guests were told the event was
-- cancelled; un-cancelling would put an event back on their map that they have
-- already mentally dropped, and the host can simply publish again. Consent
-- flags are not restored either -- consent is granted, never inferred, and the
-- user re-grants through the same sheets as any new user.
--
-- Refuses to resurrect a tombstone. Once erased_at is set the auth.users row
-- is gone, so there is nobody to authenticate as this id anyway; the explicit
-- guard is here so the failure reads as a rule rather than as a missing row.
-- ============================================================
create or replace function public.cancel_account_deletion()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  if exists (select 1 from public.profiles where id = v_uid and erased_at is not null) then
    raise exception 'account has already been erased' using errcode = 'P0002';
  end if;

  update public.profiles
  set deleted_at = null
  where id = v_uid and deleted_at is not null;
end;
$$;

revoke execute on function public.cancel_account_deletion() from public, anon;
grant  execute on function public.cancel_account_deletion() to authenticated;

comment on function public.cancel_account_deletion() is
  'Clears the calling user''s soft delete. Does not restore cancelled parties or consent flags -- both are re-granted deliberately, never inferred.';


-- ============================================================
-- 6. Discovery suppression -- and where it deliberately does NOT go.
--
-- THE POLICY IS NOT TOUCHED. Adding `and deleted_at is null` to the profiles
-- SELECT policy is the obvious move and it is the one thing that must never
-- happen: the six RPCs listed at the top of this file reach their author
-- through an inner join under invoker rights, so an RLS-invisible profile does
-- not render as "deleted user", it deletes the message from the result. For
-- tombstones that would be permanent.
--
-- So suppression goes where the discovery question is actually asked -- the
-- same shape as gotcha #15, where a control query had to move to where the
-- question was posed rather than where the answer was read.
--
--   * The map -- get_parties_near_user -- needs NO change. It filters
--     `status = 'published'`, and request_account_deletion cancels exactly the
--     parties it would have shown. Asserted in 12_account_lifecycle.test.sql
--     rather than duplicated as a predicate here (CLAUDE.md #4).
--   * Username search is a client-side ilike on profiles, not an RPC, so its
--     filter lives in SocialRepository.searchProfiles and is UX, not
--     enforcement. That is honest rather than lazy: a soft-deleted account is
--     still a real recoverable account, and an ERASED one has had its username
--     replaced with an opaque handle no human will ever type, so the tombstone
--     is unfindable by construction.
--   * The two below are enforcement and belong in the database.
-- ============================================================

-- Nobody invites an account on its way out. Without this a deleted user keeps
-- receiving invitations for 30 days and, if they never come back, forever --
-- the tombstone would still satisfy `invite_policy = 'anyone'`.
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
  'True if the guest''s invite_policy permits an invitation from this inviter, and the guest has not requested deletion. Definer because it reads another user''s block-filtered profiles row.';

-- Belt and braces on push. request_account_deletion already deleted every
-- user_devices row, so the fan-out has no token to aim at -- but this gate is
-- re-asked at CLAIM time (7c), minutes or hours after the decision, and the
-- rule that a withdrawn account stops receiving pushes immediately should not
-- depend on a delete having landed in a different table.
create or replace function public.wants_nearby_notifications(p_user_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select coalesce(
    (select p.push_consent and p.notify_nearby and p.deleted_at is null
     from public.profiles p where p.id = p_user_id),
    false
  );
$$;

comment on function public.wants_nearby_notifications(uuid) is
  'push_consent AND notify_nearby AND not pending deletion. One question, asked from the fan-out statement, both movement-trigger early exits, and the 7c claim.';


-- ============================================================
-- 7. Freeze the two markers against client roles.
--
-- 20260812115436 granted UPDATE on public.profiles to authenticated
-- table-wide, and RLS filters rows, not columns (gotcha #8). So without this
-- a client can PATCH deleted_at and erased_at directly: null out its own
-- deletion without going through cancel_account_deletion (harmless), backdate
-- deleted_at so the sweep erases it tonight instead of in 30 days (skips the
-- grace period the whole design rests on), or set erased_at on a live account
-- (makes a real user render as "Διαγραμμένος χρήστης" forever, with an
-- auth.users row still behind it).
--
-- The column-scoped-grant fix used for user_devices is not available here:
-- profiles has one table-wide grant that a dozen columns across five phases
-- depend on, and narrowing it now would be a breaking change to every one of
-- them. The schema already owns a mechanism for exactly this -- the trigger
-- that freezes credibility_score -- so this generalizes that rather than
-- adding a second trigger with the same job (CLAUDE.md #4, and the same call
-- 20260814094943 made when follower_count needed it).
--
-- current_user, not auth.role(), for the reason 20260814094943 spelled out:
-- the JWT claim still reads 'authenticated' inside a definer function, so
-- guarding on it would freeze the column against the two RPCs above as well
-- and leave nothing able to write it.
-- ============================================================
create or replace function public.protect_credibility_score()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('anon', 'authenticated') then
    new.credibility_score = old.credibility_score;
    new.follower_count    = old.follower_count;
    new.following_count   = old.following_count;
    -- Phase 9. Written only by request_account_deletion,
    -- cancel_account_deletion and complete_account_erasure, all definer.
    new.deleted_at        = old.deleted_at;
    new.erased_at         = old.erased_at;
  end if;

  return new;
end;
$$;

comment on function public.protect_credibility_score() is
  'Freezes every system-maintained column on profiles against anon/authenticated: credibility_score, both follow counters, and the Phase 9 deletion markers. Keeps its original name because the trigger that calls it is referenced by 20260709120643.';
