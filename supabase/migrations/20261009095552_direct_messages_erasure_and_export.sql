-- Phase 33, part 2: direct messages join the account lifecycle.
--
-- Both functions are recreated in full (append-only); the diffs from
-- 20261003143423 are marked NEW.
--
--   * complete_account_erasure deletes the user's direct_reads. Their
--     direct_messages are RETAINED under the tombstone, exactly like
--     messages: the other member's conversation is theirs too, and a thread
--     with one side missing is the failure Phase 9 exists to prevent. The
--     thread row stays for the same reason (its FKs are `no action`).
--   * export_account_data adds the DMs the user wrote, and dm_policy in the
--     profile block. Messages written TO the user are not theirs to export,
--     the same line the party-chat section draws.

-- ============================================================
-- complete_account_erasure
-- ============================================================
create or replace function public.complete_account_erasure(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
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
  delete from public.follows        where follower_id = p_user_id or followee_id = p_user_id;
  delete from public.party_reads    where user_id   = p_user_id;
  delete from public.direct_reads   where user_id   = p_user_id;  -- NEW
  delete from public.user_birthdates where user_id  = p_user_id;

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

  -- ---- The tombstone. ----
  v_handle := 'deleted_' || replace(p_user_id::text, '-', '');

  update public.profiles
  set username           = v_handle,
      -- New in this migration. A self-description and an avatar are as
      -- identifying as the handle they sit next to; scrubbing one and keeping
      -- the other two produces a tombstone that still names a person.
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
$$;

revoke execute on function public.complete_account_erasure(uuid) from public, anon, authenticated;
grant  execute on function public.complete_account_erasure(uuid) to service_role;

comment on function public.complete_account_erasure(uuid) is
  'The database half of erasure: deletes the audit''s DELETE set (now including direct_reads), strips post media, and rewrites the profiles row into an anonymous tombstone. Direct messages are retained, like party messages. Idempotent. Called only after storage objects are confirmed gone.';

-- ============================================================
-- export_account_data
-- ============================================================
create or replace function public.export_account_data()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_out jsonb;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select jsonb_build_object(
    -- A header, so a file that outlives the conversation about it still says
    -- what it is and when it was true.
    'export_format_version', 1,
    'exported_at', now(),
    'user_id', v_uid,

    'profile', (
      -- Column list spelled out rather than to_jsonb(pr): credibility_score
      -- must not appear. Phase 8 decided it ships no score, and a zero in an
      -- export file is a number a person will ask about.
      select to_jsonb(p)
      from (
        select
          pr.id, pr.username, pr.created_at,
          pr.bio, pr.avatar_path,
          pr.onboarding_completed_at,
          pr.location_consent, pr.push_consent, pr.analytics_consent,
          pr.map_visibility, pr.invite_policy, pr.dm_policy,  -- NEW: dm_policy
          pr.notify_nearby, pr.notify_radius_meters,
          pr.quiet_hours_start, pr.quiet_hours_end,
          pr.follower_count, pr.following_count,
          pr.deleted_at
        from public.profiles pr
        where pr.id = v_uid
      ) p
    ),

    -- Hosted parties. location is emitted as lon/lat rather than the PostGIS
    -- binary, because an export the subject cannot read is not an export.
    'parties', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pa.id,
        'title', pa.title,
        'description', pa.description,
        'area', pa.area,
        'cover_path', pa.cover_path,
        'longitude', public.st_x(pa.location::public.geometry),
        'latitude', public.st_y(pa.location::public.geometry),
        'starts_at', pa.starts_at,
        'ends_at', pa.ends_at,
        'status', pa.status,
        'is_private', pa.is_private,
        'party_tier', pa.party_tier,
        'max_capacity', pa.max_capacity,
        'going_count', pa.going_count,
        'interested_count', pa.interested_count,
        'created_at', pa.created_at
      ) order by pa.created_at)
      from public.parties pa
      where pa.host_id = v_uid
    ), '[]'::jsonb),

    'rsvps', coalesce((
      select jsonb_agg(jsonb_build_object(
        'party_id', r.party_id,
        'party_title', pa.title,
        'status', r.status,
        'created_at', r.created_at
      ) order by r.created_at)
      from public.rsvps r
      join public.parties pa on pa.id = r.party_id
      where r.user_id = v_uid
    ), '[]'::jsonb),

    'posts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pp.id,
        'party_id', pp.party_id,
        'body', pp.body,
        'media_path', pp.media_path,
        'like_count', pp.like_count,
        'comment_count', pp.comment_count,
        'created_at', pp.created_at,
        -- If a moderator hid it, the subject is entitled to know that it
        -- happened and why. Who did it is not theirs.
        'hidden_at', pp.hidden_at,
        'hidden_reason', pp.hidden_reason
      ) order by pp.created_at)
      from public.party_posts pp
      where pp.author_id = v_uid
    ), '[]'::jsonb),

    -- Not in the Phase 9 brief's list of five, added deliberately: a comment
    -- is text the user wrote, and an export that returns their posts but not
    -- their comments is an incomplete Art. 20 response.
    'comments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pc.id,
        'post_id', pc.post_id,
        'body', pc.body,
        'created_at', pc.created_at,
        'hidden_at', pc.hidden_at,
        'hidden_reason', pc.hidden_reason
      ) order by pc.created_at)
      from public.post_comments pc
      where pc.author_id = v_uid
    ), '[]'::jsonb),

    'messages', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id,
        'party_id', m.party_id,
        'party_title', pa.title,
        'body', m.body,
        'created_at', m.created_at,
        'hidden_at', m.hidden_at,
        'hidden_reason', m.hidden_reason
      ) order by m.created_at)
      from public.messages m
      join public.parties pa on pa.id = m.party_id
      where m.author_id = v_uid
    ), '[]'::jsonb),

    -- NEW. thread_id and the other member's id, as ids only -- the same
    -- reasoning as the follows block: who someone talks to is also a fact
    -- about the person on the other end.
    'direct_messages', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', dm.id,
        'thread_id', dm.thread_id,
        'recipient_id', case when t.user_low = v_uid then t.user_high else t.user_low end,
        'body', dm.body,
        'created_at', dm.created_at,
        'hidden_at', dm.hidden_at,
        'hidden_reason', dm.hidden_reason
      ) order by dm.created_at)
      from public.direct_messages dm
      join public.direct_threads t on t.id = dm.thread_id
      where dm.author_id = v_uid
    ), '[]'::jsonb),

    -- Not content, but it is unambiguously data held about the subject, and
    -- it is the part a privacy-minded person is most likely to be asking
    -- about. Emitted as ids and timestamps only: who someone follows is also
    -- a fact about the person on the other end.
    'follows', jsonb_build_object(
      'following', coalesce((
        select jsonb_agg(jsonb_build_object('user_id', f.followee_id, 'created_at', f.created_at)
               order by f.created_at)
        from public.follows f where f.follower_id = v_uid
      ), '[]'::jsonb),
      'followers', coalesce((
        select jsonb_agg(jsonb_build_object('user_id', f.follower_id, 'created_at', f.created_at)
               order by f.created_at)
        from public.follows f where f.followee_id = v_uid
      ), '[]'::jsonb)
    ),

    -- Provided by the subject at sign-up (Art. 20). Null for accounts that
    -- predate the age gate.
    'date_of_birth', (
      select b.date_of_birth from public.user_birthdates b where b.user_id = v_uid
    )

    -- Deliberately absent: user_devices. Its only interesting column is
    -- last_location, which by the time anyone reads this is either null (24h
    -- retention) or a ~100m cell -- and putting a location history into a
    -- downloadable file is the one thing 7.2 spent a whole phase preventing.
    -- The current cell is shown live in the app instead.
  ) into v_out;

  return v_out;
end;
$$;

revoke execute on function public.export_account_data() from public, anon;
grant  execute on function public.export_account_data() to authenticated;
-- The account-export edge function calls this with the CALLER's JWT, not the
-- service key, so this grant to authenticated is the one that matters. The
-- service_role grant exists only so an operator can answer a subject access
-- request by hand.
grant  execute on function public.export_account_data() to service_role;


comment on function public.export_account_data() is
  'GDPR Art. 20 export for the CALLING user only -- takes no user id. Includes bio, avatar_path, dm_policy, each hosted party''s area and cover_path, and the direct messages the user wrote. Definer so the caller''s own messages survive can_chat_in_party filtering in parties they have since left, and their DMs survive a block.';
