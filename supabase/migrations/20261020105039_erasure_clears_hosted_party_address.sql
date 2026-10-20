-- Phase 42, follow-up: account erasure clears the address of every party the
-- user hosted.
--
-- 20261020103856 kept parties.address on erasure "like description and area".
-- Reconsidered at review: a party address is often the host's HOME, which is
-- personal data about the person being erased in a way a party title is not.
-- So it is nulled, alongside bio and avatar_path in the tombstone pass.
--
-- Only the address. The party row stays (guests' chat and posts belong to it),
-- and so does `location`: the pin is the party's, a guest-facing fact, and
-- clearing it is not possible anyway (NOT NULL, and a CHECK refuses (0, 0)).
-- Descriptions written before Phase 42 may still contain a typed address,
-- because the wizard used to fold it in; whether erasure should clear or
-- redact those is open, docs/backlog.md 1.33.
--
-- Recreated from the live definition with that one block added. Same
-- signature, so `create or replace` keeps its ACL (service_role only).

CREATE OR REPLACE FUNCTION public.complete_account_erasure(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_handle text;
begin
  if not exists (
    select 1 from public.profiles
    where id = p_user_id and deleted_at is not null and erased_at is null
  ) then
    -- Not an error: a retry after a partial failure lands here, and so does a
    -- user who cancelled between the claim and now. Both should stop quietly.
    return;
  end if;

  -- Refuse to erase an account whose grace period has not expired. The eraser
  -- cannot reach this state through the claim, but this function is a
  -- service_role entry point and the 30 days is the promise the whole feature
  -- rests on -- it should be impossible to shorten by calling the API directly.
  if exists (
    select 1 from public.profiles
    where id = p_user_id
      and deleted_at > now() - public.account_erasure_grace()
  ) then
    raise exception 'grace period has not expired for %', p_user_id
      using errcode = 'P0001';
  end if;

  -- ---- Story media: queue the objects BEFORE the rows that name them. ----
  -- story_media_purges.story_id is `on delete set null` precisely so the queue
  -- outlives its subject (20260815133041).
  insert into public.story_media_purges (story_id, media_path)
  select s.id, s.media_path
  from public.stories s
  where s.author_id = p_user_id
    and s.media_uploaded_at is not null
    and s.media_deleted_at is null;

  -- ---- DELETE, per the audit's §3. ----
  delete from public.story_views    where user_id   = p_user_id;
  delete from public.stories        where author_id = p_user_id;
  delete from public.post_likes     where user_id   = p_user_id;
  delete from public.rsvps          where user_id   = p_user_id;
  delete from public.invitations    where guest_id  = p_user_id;
  delete from public.party_guest_removals where user_id = p_user_id;
  delete from public.follows        where follower_id = p_user_id or followee_id = p_user_id;
  delete from public.party_reads    where user_id   = p_user_id;
  delete from public.direct_reads   where user_id   = p_user_id;
  delete from public.user_birthdates where user_id  = p_user_id;
  -- NEW. Kept through the grace period like the date of birth, so a cancelled
  -- deletion leaves the account whole.
  delete from public.user_genders   where user_id   = p_user_id;

  -- Re-run of the PURGE NOW set from request_account_deletion. Not redundant:
  -- a device or job could have been created between the soft delete and now by
  -- a client holding a still-valid JWT, and this is the last chance to catch it.
  delete from public.user_devices       where user_id = p_user_id;
  delete from public.notification_jobs  where user_id = p_user_id;
  delete from public.sent_notifications where user_id = p_user_id;

  -- ---- RETAIN, with the media stripped. ----
  update public.party_posts
  set media_path = null
  where author_id = p_user_id
    and media_path is not null
    and body is not null;

  update public.party_posts
  set hidden_at     = coalesce(hidden_at, now()),
      hidden_reason = coalesce(hidden_reason, 'account erased')
  where author_id = p_user_id
    and media_path is not null
    and body is null;

  -- NEW (20261020105039). A party's address is often the host's home, so it
  -- goes with them. The party itself stays -- guests' messages and posts hang
  -- off it -- and its pin, title, area and description are untouched; an
  -- address typed into a description before Phase 42 is NOT caught here
  -- (docs/backlog.md 1.33).
  update public.parties
  set address = null
  where host_id = p_user_id
    and address is not null;

  -- ---- The tombstone. ----
  v_handle := 'deleted_' || replace(p_user_id::text, '-', '');

  update public.profiles
  set username           = v_handle,
      -- A self-description and an avatar are as identifying as the handle
      -- they sit next to; scrubbing one and keeping the other two produces a
      -- tombstone that still names a person.
      bio                = null,
      avatar_path        = null,
      erased_at          = now(),
      location_consent   = false,
      push_consent       = false,
      analytics_consent  = false,
      follower_count     = 0,
      following_count    = 0,
      onboarding_completed_at = null
  where id = p_user_id;

  update public.account_erasures
  set completed_at = now(),
      last_error   = null
  where user_id = p_user_id;
end;
$function$

;
