-- Date of birth at sign-up, with a 13+ minimum enforced by the database.
--
-- Why a separate table and not a column on profiles: profiles is readable by
-- every signed-in user and by anon (20260812115436), so a column there would
-- publish everyone's birthday. user_birthdates is owner-read-only and has no
-- client write grant at all -- a user can never set or change their own DOB,
-- which is what keeps the gate from being walked around after sign-up.
--
-- Why an Auth hook and not handle_new_user: seed.sql and several pgTAP files
-- create users with a raw `insert into auth.users`, which would all start
-- failing if the trigger refused a missing DOB. `before_user_created` runs
-- only on GoTrue sign-ups, before the auth.users row exists, and its error
-- message reaches the client verbatim. Enabled in supabase/config.toml; the
-- hosted project needs it switched on in the dashboard (docs/backlog.md 1.9).
--
-- The gate is sign-up only: accounts that predate it have no row and are
-- grandfathered.

-- ============================================================
-- 1. user_birthdates
-- ============================================================
create table public.user_birthdates (
  -- profiles, not auth.users: Phase 9 dropped that FK so a tombstone can
  -- outlive the auth user. Cascade, like every per-user table erasure deletes;
  -- complete_account_erasure also deletes it explicitly.
  user_id       uuid primary key references public.profiles (id) on delete cascade,
  date_of_birth date not null,
  created_at    timestamptz not null default now()
);

alter table public.user_birthdates enable row level security;

create policy "user_birthdates: owner reads own"
  on public.user_birthdates
  for select
  to authenticated
  using (user_id = (select auth.uid()));

-- Gotcha 9: strip the default ACL first, then grant only what is meant.
-- No insert/update/delete for anyone but the definer functions below.
revoke all on public.user_birthdates from anon, authenticated;
grant select on public.user_birthdates to authenticated;

comment on table public.user_birthdates is
  'Date of birth captured at sign-up. Owner-read-only; written only by handle_new_user from the sign-up metadata the age-gate hook has already validated.';

-- ============================================================
-- 2. parse_date_of_birth: the one place a DOB string becomes a date.
-- Strict YYYY-MM-DD; anything else, including impossible dates like
-- 2010-02-30, is null rather than an exception. Shared by the hook and
-- handle_new_user so the two can never disagree about what parses.
-- ============================================================
create function public.parse_date_of_birth(p_value text)
returns date
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_value is null or p_value !~ '^\d{4}-\d{2}-\d{2}$' then
    return null;
  end if;
  return p_value::date;
exception
  when invalid_datetime_format or datetime_field_overflow then
    return null;
end;
$$;

revoke execute on function public.parse_date_of_birth(text) from public, anon, authenticated;
grant  execute on function public.parse_date_of_birth(text) to supabase_auth_admin;

-- ============================================================
-- 3. The age gate (Auth hook: before_user_created).
-- Invoker: runs as supabase_auth_admin and touches no table. Returns {} to
-- allow, or {"error": {...}} to refuse with that message.
-- current_date is the database's (UTC); a sign-up within hours of a 13th
-- birthday can land a day either side of the client's local check.
-- ============================================================
create function public.before_user_created_age_gate(event jsonb)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_dob date := public.parse_date_of_birth(
    event -> 'user' -> 'user_metadata' ->> 'date_of_birth'
  );
begin
  if v_dob is null then
    return jsonb_build_object('error', jsonb_build_object(
      'http_code', 400,
      'message', 'Please enter your date of birth.'));
  end if;

  if v_dob > current_date or v_dob < date '1900-01-01' then
    return jsonb_build_object('error', jsonb_build_object(
      'http_code', 400,
      'message', 'Please enter a valid date of birth.'));
  end if;

  if v_dob > (current_date - interval '13 years')::date then
    return jsonb_build_object('error', jsonb_build_object(
      'http_code', 400,
      'message', 'The Date Of Birth is not on par with the guidelines. You need to be 13+ to own a MyParty Account.'));
  end if;

  return '{}'::jsonb;
end;
$$;

grant usage on schema public to supabase_auth_admin;
revoke execute on function public.before_user_created_age_gate(jsonb) from public, anon, authenticated;
grant  execute on function public.before_user_created_age_gate(jsonb) to supabase_auth_admin;

comment on function public.before_user_created_age_gate(jsonb) is
  'Auth before_user_created hook: refuses a sign-up without a valid date of birth or under 13. Sign-up only -- raw inserts into auth.users (seed, tests) bypass it by design.';

-- ============================================================
-- 4. handle_new_user: also store the DOB.
-- Same body as 20260813084353 plus the user_birthdates insert. The hook has
-- already refused a bad DOB on a real sign-up; a raw insert without one (seed,
-- tests) simply gets no row.
-- ============================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dob date := public.parse_date_of_birth(new.raw_user_meta_data ->> 'date_of_birth');
begin
  insert into public.profiles (id, username)
  values (
    new.id,
    public.placeholder_username(new.id, new.raw_user_meta_data, new.email)
  )
  on conflict (id) do nothing;

  if v_dob is not null then
    -- Gotcha 16 does not bite here (no OUT params), but the constraint form is
    -- used anyway so this stays correct if the signature ever changes.
    insert into public.user_birthdates (user_id, date_of_birth)
    values (new.id, v_dob)
    on conflict on constraint user_birthdates_pkey do nothing;
  end if;

  return new;
end;
$$;

-- ============================================================
-- 5. complete_account_erasure: user_birthdates joins the DELETE set.
-- Kept through the 30-day grace period (not purged at T+0), so a cancelled
-- deletion leaves the account whole. Recreated in full (append-only); the only
-- change from 20260820095801 is the one delete line.
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

-- gotcha #13: `create or replace` preserves the existing ACL, so the revoke and
-- grant from 20260819083207 still stand. Restated anyway -- a function whose
-- only caller authenticates as service_role should carry its own grant next to
-- its body, not two migrations away.
revoke execute on function public.complete_account_erasure(uuid) from public, anon, authenticated;
grant  execute on function public.complete_account_erasure(uuid) to service_role;


comment on function public.complete_account_erasure(uuid) is
  'The database half of erasure: deletes the audit''s DELETE set, strips post media, and rewrites the profiles row into an anonymous tombstone -- handle, bio and avatar all scrubbed, date of birth deleted. Idempotent. Called only after storage objects are confirmed gone.';

-- ============================================================
-- 6. export_account_data: adds date_of_birth.
-- Recreated in full (append-only); the only change from 20260820095801 is the
-- 'date_of_birth' key.
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
          pr.map_visibility, pr.invite_policy,
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
  'GDPR Art. 20 export for the CALLING user only -- takes no user id. Includes bio, avatar_path, and each hosted party''s area and cover_path. Definer so the caller''s own messages survive can_chat_in_party filtering in parties they have since left.';
