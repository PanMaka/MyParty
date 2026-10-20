-- Phase 41: the gender mix of a party's guests, on the host dashboard.
--
-- Until now the register screen sent `gender` into the auth user_metadata and
-- nothing read it: no table, no constraint, writable to any string by the
-- owner through auth.updateUser, and carried in every access token. This
-- migration makes a table the only copy:
--
--   1. public.gender + user_genders -- owner-read-only, like user_birthdates,
--      because profiles is readable by everyone.
--   2. parse_gender / set_my_gender -- the one parser and the client's only
--      write door.
--   3. handle_new_user copies the sign-up answer in, and a BEFORE UPDATE
--      trigger on auth.users keeps it out of the metadata from then on;
--      existing answers are copied once, then stripped.
--   4. get_party_host_stats gains the per-group gender counts, NULL below
--      three guests.
--   5. Export carries it; erasure deletes it.
--
-- "Prefer not to say" is NO ROW, not a NULL column. Choosing it leaves nothing
-- about you stored, and "not specified" has one representation rather than
-- two (no row for accounts that predate the field, NULL for the ones that
-- chose not to say) that every reader would have to treat as the same thing.
--
-- What the host sees, stated honestly (the register screen and settings say
-- the same): exact counts, refreshed on every rsvp change. A host who also
-- has the guest list can sometimes work out one person's answer -- a group of
-- three that is all one gender, or the count that moved when a named guest
-- joined. The minimum of three stops the trivial case of a one- or two-person
-- group; it is not anonymity, and nothing here claims it is. The answer to
-- "I don't want to be counted" is "prefer not to say".
--
-- Deliberately NOT done: a signal to the host when a guest changes their
-- answer. party_host:{uuid} fires on rsvps only. A broadcast on the change
-- would tell the host "someone just changed", which is exactly the
-- one-person difference above; the mix catches up on the next refetch.


-- ===========================================================================
-- 1. The table.
-- ===========================================================================
create type public.gender as enum ('male', 'female', 'non_binary');

create table public.user_genders (
  -- profiles, not auth.users, for the same reason as user_birthdates: the
  -- tombstone outlives the auth user (Phase 9). complete_account_erasure also
  -- deletes the row explicitly.
  user_id    uuid primary key references public.profiles (id) on delete cascade,
  gender     public.gender not null,
  updated_at timestamptz not null default now()
);

alter table public.user_genders enable row level security;

create policy "user_genders: owner reads own"
  on public.user_genders
  for select
  to authenticated
  using (user_id = (select auth.uid()));

-- Gotcha 9 / 23: strip, then grant only the read. Every write goes through
-- set_my_gender or handle_new_user, so there is no column grant for a
-- PostgREST upsert to trip over (gotcha 12).
revoke all on public.user_genders from anon, authenticated;
grant select on public.user_genders to authenticated;

comment on table public.user_genders is
  'Self-reported gender. Owner-read-only. No row = not specified, which is also '
  'what "prefer not to say" stores. Written by handle_new_user at sign-up and by '
  'set_my_gender; read in aggregate only, by get_party_host_stats.';


-- ===========================================================================
-- 2. The parser and the write door.
-- ===========================================================================

-- The one place a string becomes a gender. Anything that is not exactly one of
-- the three values -- 'prefer_not_to_say', a typo, a value a future client
-- invents, a JSON number -- is NULL, which every caller treats as "store
-- nothing". Shared by handle_new_user and the backfill so they cannot disagree.
create function public.parse_gender(p_value text)
returns public.gender
language sql
immutable
set search_path = ''
as $$
  select case
    when p_value in ('male', 'female', 'non_binary') then p_value::public.gender
  end;
$$;

revoke execute on function public.parse_gender(text) from public, anon, authenticated;

-- NULL clears (prefer not to say); a value sets it. Definer because the client
-- holds no write grant; it can only ever touch the caller's own row.
create function public.set_my_gender(p_gender public.gender)
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

  if p_gender is null then
    delete from public.user_genders where user_id = v_uid;
    return;
  end if;

  insert into public.user_genders (user_id, gender)
  values (v_uid, p_gender)
  on conflict on constraint user_genders_pkey
  do update set gender = excluded.gender, updated_at = now();
end;
$$;

revoke execute on function public.set_my_gender(public.gender) from public, anon;
grant  execute on function public.set_my_gender(public.gender) to authenticated;

comment on function public.set_my_gender(public.gender) is
  'Sets the caller''s own gender; NULL deletes the row ("prefer not to say"). '
  'The client''s only write to user_genders.';


-- ===========================================================================
-- 3. Sign-up, and the answers given before this migration.
--
-- handle_new_user recreated in full from 20261003143423; the gender block is
-- new. The register form still sends the answer in the sign-up metadata,
-- because that is the only thing GoTrue hands this trigger.
--
-- It is NOT stripped from the metadata here, and that was measured, not
-- assumed: GoTrue adds sub/email/email_verified to user_metadata after its
-- insert and writes the whole object back, so an `update auth.users` in this
-- trigger is silently undone on every real sign-up (it only "worked" for raw
-- inserts, which is all pgTAP can make). The strip lives in a BEFORE UPDATE
-- trigger instead (strip_gender_from_auth_metadata, below), which catches that
-- very write-back.
-- ===========================================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dob date := public.parse_date_of_birth(new.raw_user_meta_data ->> 'date_of_birth');
  v_gender public.gender := public.parse_gender(new.raw_user_meta_data ->> 'gender');
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

  if v_gender is not null then
    insert into public.user_genders (user_id, gender)
    values (new.id, v_gender)
    on conflict on constraint user_genders_pkey do nothing;
  end if;

  return new;
end;
$$;

-- The answers users gave between 3ad905a (2026-10-10) and now. Copied as they
-- chose them; 'prefer_not_to_say' and anything invalid store nothing. Only
-- where a profile exists (the FK), which is every account but a tombstone's
-- already-deleted auth user. Then stripped, valid or not: for these accounts
-- the copy in the table is the only one.
insert into public.user_genders (user_id, gender)
select u.id, public.parse_gender(u.raw_user_meta_data ->> 'gender')
from auth.users u
join public.profiles p on p.id = u.id
where public.parse_gender(u.raw_user_meta_data ->> 'gender') is not null
on conflict on constraint user_genders_pkey do nothing;

-- The strip, on every write to auth.users from now on. BEFORE UPDATE edits
-- NEW in place, so there is no second statement for GoTrue to overwrite, and
-- it fires on each of the writes the metadata can come back through:
--   * GoTrue's own write-back during sign-up (the one that undid a strip in
--     handle_new_user), so the copy does not outlive the sign-up request;
--   * every sign-in (last_sign_in_at), which covers an account whose sign-up
--     predates this trigger or never reached onboarding;
--   * auth.updateUser, so a client cannot park an answer there either.
-- The INSERT is untouched on purpose: handle_new_user has to read the value.
-- It strips and does nothing else -- user_genders does not follow the
-- metadata, or an updateUser({gender}) would be a second write door.
create function public.strip_gender_from_auth_metadata()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.raw_user_meta_data := new.raw_user_meta_data - 'gender';
  return new;
end;
$$;

revoke execute on function public.strip_gender_from_auth_metadata() from public, anon, authenticated;

create trigger strip_gender_from_auth_metadata
  before update on auth.users
  for each row
  when (new.raw_user_meta_data ? 'gender')
  execute function public.strip_gender_from_auth_metadata();

-- Fires the trigger above for every account that still holds a copy.
update auth.users
set raw_user_meta_data = raw_user_meta_data - 'gender'
where raw_user_meta_data ? 'gender';


-- ===========================================================================
-- 4. get_party_host_stats: the gender mix per group.
--
-- Dropped and recreated because the return shape grows (create or replace
-- cannot change OUT columns); the body is 20261014113213's plus the gender
-- counts. Groups are the follower split's: Going = status 'going', Interested
-- = every rsvp (the superset, 20260826093437). A private party's "Coming" is
-- the going group.
--
-- Same scan as the follower split, so block-paired guests are counted here
-- exactly as they are there -- and, like there, they can make the total exceed
-- what get_party_guests lists. `follows` and `user_genders` are both keyed so
-- that each joins at most one row per rsvp; the counts cannot double.
--
-- The minimum is applied HERE, not in the client: below three rsvps a group's
-- four counts are NULL, so no client -- including one with a bug in it -- can
-- render them. NULL rather than 0 for the CLAUDE.md private-counter reason: 0
-- is a legible, wrong answer. The group's size is still the headline counter.
-- ===========================================================================
drop function public.get_party_host_stats(uuid);

create function public.get_party_host_stats(p_party_id uuid)
returns table (
  party_id uuid,
  title text,
  description text,
  area text,
  starts_at timestamptz,
  ends_at timestamptz,
  cover_path text,
  is_private boolean,
  status public.party_status,
  lat double precision,
  lon double precision,
  is_live boolean,
  is_over boolean,
  going_count integer,
  interested_count integer,
  going_followers integer,
  going_non_followers integer,
  interested_followers integer,
  interested_non_followers integer,
  going_male integer,
  going_female integer,
  going_non_binary integer,
  going_unspecified integer,
  interested_male integer,
  interested_female integer,
  interested_non_binary integer,
  interested_unspecified integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  -- The smallest group whose gender mix is shown. Below it, NULLs.
  c_min_group constant integer := 3;
begin
  if not public.is_party_host(p_party_id) then
    raise exception 'not the host of party %', p_party_id using errcode = '42501';
  end if;

  return query
  select
    p.id,
    p.title,
    p.description,
    p.area,
    p.starts_at,
    p.ends_at,
    p.cover_path,
    p.is_private,
    p.status,
    public.st_y(p.location::public.geometry),
    public.st_x(p.location::public.geometry),
    p.status = 'published'
      and p.starts_at <= now()
      and not public.party_is_past(p.starts_at, p.ends_at),
    public.party_is_past(p.starts_at, p.ends_at),
    p.going_count,
    p.interested_count,
    coalesce(s.going_followers, 0)::int,
    coalesce(s.going_non_followers, 0)::int,
    coalesce(s.interested_followers, 0)::int,
    coalesce(s.interested_non_followers, 0)::int,
    case when s.going_total >= c_min_group then s.going_male::int end,
    case when s.going_total >= c_min_group then s.going_female::int end,
    case when s.going_total >= c_min_group then s.going_non_binary::int end,
    case when s.going_total >= c_min_group then s.going_unspecified::int end,
    case when s.interested_total >= c_min_group then s.interested_male::int end,
    case when s.interested_total >= c_min_group then s.interested_female::int end,
    case when s.interested_total >= c_min_group then s.interested_non_binary::int end,
    case when s.interested_total >= c_min_group then s.interested_unspecified::int end
  from public.parties p
  left join lateral (
    select
      count(*) filter (where r.status = 'going' and f.follower_id is not null) as going_followers,
      count(*) filter (where r.status = 'going' and f.follower_id is null) as going_non_followers,
      -- interested is the superset (20260826093437): every rsvp, going included.
      count(*) filter (where f.follower_id is not null) as interested_followers,
      count(*) filter (where f.follower_id is null) as interested_non_followers,

      -- The threshold is measured on the same rows the four counts split, so
      -- the four always sum to a total that passed it.
      count(*) filter (where r.status = 'going') as going_total,
      count(*) filter (where r.status = 'going' and g.gender = 'male') as going_male,
      count(*) filter (where r.status = 'going' and g.gender = 'female') as going_female,
      count(*) filter (where r.status = 'going' and g.gender = 'non_binary') as going_non_binary,
      count(*) filter (where r.status = 'going' and g.gender is null) as going_unspecified,
      count(*) as interested_total,
      count(*) filter (where g.gender = 'male') as interested_male,
      count(*) filter (where g.gender = 'female') as interested_female,
      count(*) filter (where g.gender = 'non_binary') as interested_non_binary,
      count(*) filter (where g.gender is null) as interested_unspecified
    from public.rsvps r
    left join public.follows f
      on f.follower_id = r.user_id
     and f.followee_id = p.host_id
    left join public.user_genders g
      on g.user_id = r.user_id
    where r.party_id = p.id
  ) s on true
  where p.id = p_party_id;
end;
$$;

revoke execute on function public.get_party_host_stats(uuid) from public;
grant  execute on function public.get_party_host_stats(uuid) to authenticated;

comment on function public.get_party_host_stats(uuid) is
  'Host dashboard header and aggregates for one party. Host-only (42501 for '
  'anyone else). Returns private-party counters, unlike every attendee RPC. '
  'Followers = people who follow the host. Gender mix per group as counts '
  'only, NULL for a group under 3 rsvps. No per-user data.';


-- ===========================================================================
-- 5. Erasure and export, recreated in full from 20261014133500 (append-only).
-- Diffs marked NEW.
-- ===========================================================================
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
$$;

revoke execute on function public.complete_account_erasure(uuid) from public, anon, authenticated;
grant  execute on function public.complete_account_erasure(uuid) to service_role;

comment on function public.complete_account_erasure(uuid) is
  'The database half of erasure: deletes the audit''s DELETE set (now including user_genders), strips post media, and rewrites the profiles row into an anonymous tombstone. Direct messages are retained, like party messages. Idempotent. Called only after storage objects are confirmed gone.';

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
          pr.map_visibility, pr.invite_policy, pr.dm_policy,
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
grant  execute on function public.export_account_data() to service_role;

comment on function public.export_account_data() is
  'GDPR Art. 20 export for the CALLING user only -- takes no user id. Includes bio, avatar_path, dm_policy, each hosted party''s area and cover_path, the direct messages the user wrote, the parties whose host removed them (ids and dates), and their gender. Definer so the caller''s own messages survive can_chat_in_party filtering in parties they have since left, and their DMs survive a block.';
