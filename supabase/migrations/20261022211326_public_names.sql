-- Phase 49: first and last name become public to signed-in users, and
-- optional.
--
-- Reverses Phase 44's "owner-read-only" (20261021094725). Names now show
-- under the username on a profile, the way Instagram does it. Recorded in
-- docs/backlog.md §3.
--
-- THE NAMES STAY IN user_names, AND A SECOND READ POLICY EXPOSES THEM. Moving
-- them onto profiles was the alternative and loses on two counts, both of them
-- conditions on the ROW, which a column grant cannot express:
--
--   * A pending-deletion account shows no name, but keeps it through the grace
--     period so a restore brings it back. On profiles that needs a view or a
--     second, nulled copy.
--   * An existing user's name stays hidden until they have seen the notice
--     (below). Same problem.
--
-- On user_names both are terms in a row policy. The policy's `exists` reads
-- public.profiles under the CALLER's privileges, so the profiles row policy
-- (the block filter, both directions) applies to it: a profile you cannot see
-- has a name you cannot see. That reuses the one block rule rather than
-- restating it (CLAUDE.md rule 4). is_discoverable (Phase 45) is false for a
-- pending or erased account. Erasure already deletes the row.
--
-- THE NOTICE. Every existing user was told "Only you can see your name". So
-- shown_at is null for every row that exists today, and a null shown_at keeps
-- the name owner-only, exactly as before. The client shows a one-time notice
-- ("Your name is now shown on your profile...") with OK, which calls
-- acknowledge_name_shown(), and Remove my name, which calls
-- set_my_names(null, null). An account whose owner never opens the app again
-- never has its name published. From now on, set_my_names stamps shown_at
-- itself: onboarding and Edit profile both say the name is shown, so saving
-- there is informed.
--
-- NAMES ARE OPTIONAL. set_my_names(null, null) deletes the row, like
-- set_my_gender(null). complete_onboarding accepts no names. Half a name is
-- still refused: a row holds both or there is no row.
--
-- Columns, after this migration:
--   public       user_id, first_name, last_name (shown rows only, by policy)
--   owner-only   shown_at, through get_my_names()
--   server-only  updated_at


-- ===========================================================================
-- 1. shown_at, and the grants.
--
-- No default: a row written before this migration, or by a fixture as
-- postgres, is unacknowledged until something says otherwise.
--
-- The grant becomes a column list (Phase 45 rules). shown_at must not be in
-- it: a stranger reading it would learn when someone acknowledged the notice.
-- The owner reads it through get_my_names().
-- ===========================================================================
alter table public.user_names add column shown_at timestamptz;

comment on column public.user_names.shown_at is
  'When the name became visible to other signed-in users: the owner '
  'acknowledged the Phase 49 notice, or saved the name under copy that says '
  'it is shown. Null = owner-only. Not client-readable; get_my_names().';

revoke select on public.user_names from authenticated;
grant select (user_id, first_name, last_name) on public.user_names to authenticated;


-- ===========================================================================
-- 2. The second read policy. The owner's own policy is untouched; the two are
-- OR'd, so the owner still reads an unshown or pending name.
-- ===========================================================================
create policy "user_names: signed-in users read shown names"
  on public.user_names
  for select
  to authenticated
  using (
    shown_at is not null
    and exists (
      select 1 from public.profiles p
      where p.id = user_names.user_id
        and p.is_discoverable
    )
  );

comment on table public.user_names is
  'First and last name, optional. Readable by signed-in users once shown_at is '
  'set, through the profiles row policy (blocks) and only while the account '
  'is discoverable. Written by complete_onboarding and set_my_names; '
  'exported; deleted on erasure.';


-- ===========================================================================
-- 3. set_my_names: both, or neither.
--
-- Blank counts as absent, so the client can send what the fields hold.
-- Neither deletes the row. Exactly one is 22023, as before.
-- ===========================================================================
create or replace function public.set_my_names(p_first_name text, p_last_name text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_first text := nullif(btrim(p_first_name), '');
  v_last  text := nullif(btrim(p_last_name), '');
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  if v_first is null and v_last is null then
    delete from public.user_names where user_id = v_uid;
    return;
  end if;

  if not public.person_name_is_valid(v_first) or not public.person_name_is_valid(v_last) then
    raise exception 'invalid name' using errcode = '22023';
  end if;

  insert into public.user_names (user_id, first_name, last_name, shown_at)
  values (v_uid, v_first, v_last, now())
  on conflict on constraint user_names_pkey
  do update set first_name = excluded.first_name,
                last_name  = excluded.last_name,
                updated_at = now(),
                shown_at   = coalesce(public.user_names.shown_at, now());
end;
$$;

comment on function public.set_my_names(text, text) is
  'Sets the caller''s own first and last name (both, trimmed, 1-50 '
  'characters), or deletes them when both are null or blank. Stamps shown_at: '
  'the client copy says names are shown. Half a name is 22023.';


-- ===========================================================================
-- 4. complete_onboarding: names optional. Body as in 20261021094726, except
-- the names block, which set_my_names now handles in full (neither = no row).
-- ===========================================================================
create or replace function public.complete_onboarding(
  p_username   text,
  p_first_name text,
  p_last_name  text
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_done timestamptz;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select p.onboarding_completed_at into v_done
  from public.profiles p where p.id = v_uid
  for update;

  if not found then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if v_done is not null then
    raise exception 'onboarding already complete' using errcode = '42501';
  end if;

  if not public.username_is_valid(p_username) then
    raise exception 'invalid username' using errcode = '22023';
  end if;

  -- Both names, or neither (no row); half a name raises 22023.
  perform public.set_my_names(p_first_name, p_last_name);

  perform public.lock_username(p_username);
  if public.username_unavailable(p_username, v_uid) then
    raise exception 'username taken' using errcode = '23505';
  end if;

  begin
    update public.profiles
    set username = p_username,
        onboarding_completed_at = now()
    where id = v_uid;
  exception when unique_violation then
    raise exception 'username taken' using errcode = '23505';
  end;
end;
$$;

comment on function public.complete_onboarding(text, text, text) is
  'Sets the first chosen username, the first and last name if given (both or '
  'neither), and onboarding_completed_at, once. Errors: 22023 invalid '
  'username/name, 23505 taken (held or reserved), 42501 already onboarded.';


-- ===========================================================================
-- 5. The owner's door, and the notice.
-- ===========================================================================
create function public.get_my_names()
returns table (first_name text, last_name text, shown boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select n.first_name, n.last_name, n.shown_at is not null
  from public.user_names n
  where n.user_id = (select auth.uid());
$$;

revoke execute on function public.get_my_names() from public, anon;
grant  execute on function public.get_my_names() to authenticated;

comment on function public.get_my_names() is
  'The caller''s own names and whether they are shown to others. No row = no '
  'name. shown = false means the Phase 49 notice is still owed.';


-- Idempotent, and a no-op without a row: tapping OK twice, or after Remove my
-- name in another session, is not an error.
create function public.acknowledge_name_shown()
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  update public.user_names
  set shown_at = coalesce(shown_at, now())
  where user_id = v_uid;
end;
$$;

revoke execute on function public.acknowledge_name_shown() from public, anon;
grant  execute on function public.acknowledge_name_shown() to authenticated;

comment on function public.acknowledge_name_shown() is
  'The caller saw the Phase 49 notice and chose OK: their name becomes visible '
  'to signed-in users. Idempotent; a no-op without a name.';


-- ===========================================================================
-- 6. Export: adds name_shown_at, when the name became visible to others.
-- Body otherwise as live after 20261022153236.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.export_account_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
          pr.map_visibility, pr.invite_policy, pr.dm_policy,
          pr.suggest_account,
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
        'address', pa.address,
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

    -- Parties whose host removed the subject from the guest list: data held
    -- about them, and nothing they do not already know -- the party
    -- disappeared for them. Party ids and dates only, no title: a private
    -- party they can no longer see should not have its name re-delivered here.
    'party_removals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'party_id', g.party_id,
        'removed_at', g.removed_at
      ) order by g.removed_at)
      from public.party_guest_removals g
      where g.user_id = v_uid
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

    -- thread_id and the other member's id, as ids only -- the same reasoning
    -- as the follows block: who someone talks to is also a fact about the
    -- person on the other end.
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
    ),

    -- NEW. Provided by the subject. Null = not specified, which includes
    -- "prefer not to say" (stored as no row).
    'gender', (
      select g.gender from public.user_genders g where g.user_id = v_uid
    ),

    -- Phase 44 (backlog 1.32). Given by the subject; public since Phase 49.
    'first_name', (
      select n.first_name from public.user_names n where n.user_id = v_uid
    ),
    'last_name', (
      select n.last_name from public.user_names n where n.user_id = v_uid
    ),
    -- NEW (Phase 49). When the name became visible to other signed-in users;
    -- null if it never has (no name, or the notice not yet acknowledged).
    'name_shown_at', (
      select n.shown_at from public.user_names n where n.user_id = v_uid
    ),

    -- NEW. Null if the username was never changed after onboarding.
    'username_change', (
      select jsonb_build_object(
        'previous_username', c.previous_username,
        'changed_at', c.changed_at
      )
      from public.username_changes c where c.user_id = v_uid
    ),

    -- NEW. When consent was last given; the current state is in `profile`.
    -- Null where it was given before Phase 44 recorded the moment.
    'consents', (
      select jsonb_build_object(
        'location_consent_at', uc.location_consent_at,
        'push_consent_at', uc.push_consent_at
      )
      from public.user_consents uc where uc.user_id = v_uid
    ),

    -- NEW (Phase 48). Accounts the subject dismissed from "People you may
    -- know", as ids and dates for the same reason as follows.
    'follow_suggestion_dismissals', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', d.dismissed_id, 'created_at', d.created_at)
             order by d.created_at)
      from public.follow_suggestion_dismissals d where d.user_id = v_uid
    ), '[]'::jsonb)

    -- Deliberately absent: user_devices. Its only interesting column is
    -- last_location, which by the time anyone reads this is either null (24h
    -- retention) or a ~100m cell -- and putting a location history into a
    -- downloadable file is the one thing 7.2 spent a whole phase preventing.
    -- The current cell is shown live in the app instead.
  ) into v_out;

  return v_out;
end;
$function$

;

comment on function public.export_account_data() is
  'GDPR Art. 20 export for the CALLING user only -- takes no user id. Includes bio, avatar_path, dm_policy, each hosted party''s area, address and cover_path, the direct messages the user wrote, the parties whose host removed them (ids and dates), their gender, first and last name and when the name became visible (name_shown_at), their last username change, when location/push consent was given, suggest_account and their follow-suggestion dismissals. Definer so the caller''s own messages survive can_chat_in_party filtering in parties they have since left, and their DMs survive a block.';
