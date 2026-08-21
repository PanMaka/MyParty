-- Phase 11, part 1: the four columns the profile and party cards have been
-- rendering placeholders for.
--
-- Three of the four exist because a BUCKET has existed since 20260812124217
-- with no column pointing into it. `Profile.placeholderColors` and
-- `PartySummary.placeholderColors` are both documented in the client as
-- stand-ins to be removed "in the migration that adds the column, not before".
-- This is that migration.
--
-- What is deliberately NOT here: display_name, school, department, or any
-- second profile text field. The header is @username plus ONE line, and the
-- constraint below enforces the "one line" half of that literally -- see
-- section 1. A schema that offers three text fields gets a header with three
-- text fields, whatever the design said.
--
-- Also not here: an `address` column on parties. `area` is a neighbourhood
-- LABEL ("Κουκάκι", "Ψυρρή"), which is a different thing from a street
-- address, and the difference is privacy rather than precision. Phase 7 spent
-- a whole phase making sure the only stored location is a ~100m cell under a
-- 24h clock; a free-text street address on a public party row would route
-- around that with no clock and no consent gate at all. `parties.location` is
-- and stays the only place a party's real position lives.


-- ============================================================
-- 1. profiles.bio -- ONE line, capped at 160 characters.
--
-- 160 rather than 140/280/500, and the number is the design decision rather
-- than a guess at "enough":
--
--   * The rendered target is a single line under @username at body size. On
--     the narrowest phone this project supports that is roughly two visual
--     lines before it starts pushing the follow button down the card, and 160
--     is about where that lands. A 500-char cap would not be "generous", it
--     would be a promise the header cannot keep -- the screen would have to
--     ellipsize, and a field that is always truncated is a field whose real
--     cap is enforced in the wrong layer.
--   * It is comfortably more than the example line
--     ("Κουκάκι · ταράτσες και techno" is 29) so nobody hits it writing the
--     thing it is for, and comfortably less than a paragraph.
--
-- char_length, not octet_length. Every persona line this feature exists for is
-- Greek, which is 2 bytes per character in UTF-8, and a byte cap would give
-- Greek users half the field -- the exact bug that makes a length limit read
-- as hostile in one language and invisible in another.
--
-- Four conditions, not one, because each rules out a different dishonest
-- value:
--
--   * The cap stops a paragraph.
--   * `btrim(bio) <> ''` stops the empty string and the whitespace-only
--     string. This one is load-bearing rather than tidy: a text input that
--     round-trips '' into the column produces a profile that is neither "has
--     a bio" nor "has no bio", and every renderer downstream then needs its
--     own `.trim().isEmpty` check to avoid drawing an empty line under the
--     username. NULL means "no bio" and it is the only thing that does.
--   * No newline, no carriage return. The header shows one line; a bio
--     containing \n is a bio that renders differently from how it was typed on
--     every surface that does not happen to clip it. Making it a constraint
--     means the client can render `bio` directly instead of every call site
--     remembering to collapse whitespace. This is the "one line" in the brief,
--     expressed as a type rather than as a comment.
--
-- No UPDATE trigger, and deliberately not added to protect_credibility_score:
-- this is the user's own text about themselves, the same shape as
-- map_visibility, and the table-wide `grant update on public.profiles to
-- authenticated` (20260812115436) is what makes it writable. That trigger is
-- for SYSTEM-maintained columns only.
-- ============================================================
alter table public.profiles
  add column bio text
    constraint profiles_bio_one_short_line check (
      bio is null
      or (
        char_length(bio) <= 160
        and btrim(bio) <> ''
        and position(E'\n' in bio) = 0
        and position(E'\r' in bio) = 0
      )
    );

comment on column public.profiles.bio is
  'ONE short line rendered under @username, max 160 characters, no newlines. NULL means no bio -- the empty string is rejected by profiles_bio_one_short_line so that "unset" has exactly one representation.';


-- ============================================================
-- 2. profiles.avatar_path and parties.cover_path -- storage paths, never URLs.
--
-- A path, because a URL is a rendering decision with an expiry on it. `avatars`
-- is a public bucket and `party-covers` is not (20260812124217), so the two
-- are read completely differently -- one is a public URL built client-side, the
-- other needs a signed URL with a lifetime. Storing a URL would freeze that
-- choice into the row, and a signed one would be a stored credential that goes
-- stale in an hour. The column stores the key; the client asks Storage what to
-- do with it.
--
-- ---- The guard, which is the whole point of this section. ----
--
-- The bucket policies check the FOLDER: `Users can upload their own avatar`
-- requires `auth.uid()::text = (storage.foldername(name))[1]`, so a client
-- cannot put BYTES anywhere but its own folder. That says nothing about what
-- this column may CONTAIN. `profiles` carries a table-wide UPDATE grant and an
-- owner-only row policy, and RLS gates rows, not columns (gotcha #8) -- so
-- without a check, any user could PATCH their own row to
-- avatar_path = '<someone-else>/avatar.jpg' and wear another person's face.
-- The object is public-read, so nothing downstream would refuse to serve it.
-- Two mechanisms, two questions: the policy answers "may you write there", the
-- constraint answers "may you point there".
--
-- A CHECK constraint rather than a trigger. It compares against `id`, which is
-- in the same row, so there is nothing to look up -- and a check cannot be
-- skipped by a definer function that forgot about it, which a trigger guard on
-- a table with sixteen writers eventually is.
--
-- `starts_with` rather than LIKE: LIKE would treat the pattern as a pattern,
-- and while a uuid contains no `%` or `_`, a guard whose correctness depends
-- on the shape of the value it is guarding is one refactor from being wrong.
--
-- The `..` clause is not paranoia about S3. Object keys are literal there, so
-- `<uid>/../victim/a.jpg` names nothing. It is about the HTTP path: the key is
-- interpolated into `/storage/v1/object/public/avatars/<path>`, and normalizing
-- `..` out of a URL path before routing is standard behaviour for proxies and
-- for some HTTP clients. A key that starts with the right folder and resolves
-- to another one defeats the prefix check exactly where it is doing its job.
--
-- Both are nullable with no default and no backfill: every existing row means
-- "no image", which is what the client's placeholder gradients already draw.
-- ============================================================
alter table public.profiles
  add column avatar_path text
    constraint profiles_avatar_path_own_folder check (
      avatar_path is null
      or (
        starts_with(avatar_path, id::text || '/')
        and char_length(avatar_path) <= 512
        and position('..' in avatar_path) = 0
      )
    );

comment on column public.profiles.avatar_path is
  'Key into the public `avatars` bucket, never a URL. Constrained to this user''s own {user_id}/ folder: the bucket policy governs where bytes may be WRITTEN, this constraint governs where the column may POINT, and only the second stops someone wearing another user''s face.';

alter table public.parties
  add column cover_path text
    constraint parties_cover_path_own_folder check (
      cover_path is null
      or (
        starts_with(cover_path, id::text || '/')
        and char_length(cover_path) <= 512
        and position('..' in cover_path) = 0
      )
    );

comment on column public.parties.cover_path is
  'Key into the private `party-covers` bucket, never a URL -- reads need a signed URL. Constrained to this party''s own {party_id}/ folder, mirroring profiles.avatar_path. NOT scrubbed by complete_account_erasure, unlike profiles.avatar_path: a party outlives its host and the cover depicts a venue, not a person -- see section 5 of 20260820095801.';


-- ============================================================
-- 3. parties.area -- the neighbourhood line.
--
-- Free text rather than an enum or a lookup table, and that is a considered
-- choice rather than the lazy one. Athens neighbourhoods have no canonical
-- list, no stable spelling ("Ψυρρή"/"Ψυρή"), and the boundaries people use
-- socially are not the administrative ones -- an enum would need an `alter
-- type` for every party in a suburb nobody thought of, and a lookup table
-- would need somebody to maintain it. It is a label the host writes, and it is
-- shown as a label.
--
-- Capped and non-blank on the same reasoning as bio: it is one line on a card,
-- and '' must not be a second way of spelling "unknown". 80 rather than 160
-- because this one is a place name, not a sentence.
--
-- NOT derived from `location`. Reverse geocoding a point into a neighbourhood
-- would mean shipping the point to a geocoder, and `parties.location` for a
-- private party is exactly the value this schema is most careful with.
-- ============================================================
alter table public.parties
  add column area text
    constraint parties_area_one_short_line check (
      area is null
      or (
        char_length(area) <= 80
        and btrim(area) <> ''
        and position(E'\n' in area) = 0
        and position(E'\r' in area) = 0
      )
    );

comment on column public.parties.area is
  'Neighbourhood label written by the host ("Κουκάκι"), max 80 chars, one line. NULL means the host did not say. Never derived from parties.location -- reverse geocoding would send a private party''s coordinates to a third party.';


-- ============================================================
-- 4. The profiles SELECT policy: NO CHANGE, and that is the correct outcome.
--
-- The brief asks for bio and avatar_path to follow the same block-filtered
-- visibility as the rest of the row. They already do, and rewriting the policy
-- to mention them would make it WORSE, not better.
--
--   "Profiles are viewable by everyone except blocked pairs"  (20260814094945)
--   on public.profiles for select
--   using ( not public.is_blocked((select auth.uid()), id) );
--
-- RLS is row-scoped: a policy either yields the row or it does not, and it has
-- no way to yield some columns of it (gotcha #8 -- the same fact that forces
-- `user_devices` to use column-scoped GRANTS instead). So a column added to
-- this table inherits the block filter the moment it exists, with no policy
-- edit, and there is no formulation of a SELECT policy that could give bio a
-- different visibility from username.
--
-- The two things that COULD have broken that inheritance are grants, and both
-- are already right:
--   * `grant select on public.profiles to anon, authenticated` (20260812115436)
--     is table-wide, not a column list, so it covers columns added later. A
--     column-scoped SELECT grant would have needed extending here.
--   * `grant update on public.profiles to authenticated` is likewise
--     table-wide, which is what makes bio and avatar_path client-writable at
--     all -- with the constraints above as the guard, since the grant cannot
--     express one.
--
-- Asserted rather than asserted-by-comment: 14_profile_and_party_media.test.sql
-- proves a blocked viewer reads no bio, and proves both grants are table-wide.
-- ============================================================


-- ============================================================
-- 5. complete_account_erasure: scrub bio and avatar_path with the username.
--
-- Both are personal data in the plainest sense -- a self-description and a
-- photograph of a face -- and the tombstone's entire justification is that
-- what survives is a referential anchor, not a person. A tombstone that still
-- says "Κουκάκι · ταράτσες και techno" under a `deleted_<uuid>` handle is not
-- anonymous; it is a scrubbed name attached to an unscrubbed description, and
-- the description is often the more identifying half.
--
-- NULL rather than a placeholder string, for the same reason section 1 rejects
-- '': the client renders "no bio" for null and would render an invented string
-- as though the user had written it.
--
-- avatar_path is nulled here, and the ORDER matters. The eraser deletes the
-- `{user_id}/` prefix from the avatars bucket BEFORE calling this function --
-- the prefix it needs is already returned by claim_accounts_for_erasure as
-- `avatar_prefix`, which is why that OUT parameter has existed since
-- 20260819083207 with nothing pointing into the bucket yet. So by the time
-- this runs the object is gone and this clears a dangling pointer, exactly
-- like the party_posts.media_path update below it. No new work for the eraser,
-- no second path to the bucket (gotcha #7).
--
-- parties.cover_path is deliberately NOT scrubbed. A hosted party SURVIVES
-- erasure (docs/phase-09-fk-audit.md §3: parties.host_id is `no action`
-- precisely so a party's chat outlives its host), and the cover is a
-- photograph of a venue attached to that party, not of the person. Nulling it
-- would blank the header of an event other people are still in the middle of
-- attending, and the eraser deletes by the `{user_id}/` prefix -- which
-- `party-covers` does not use, being keyed by party. Same reasoning that keeps
-- the retained post's body.
--
-- Recreated in full rather than patched, because a merged migration is
-- append-only (CLAUDE.md #7) and `create or replace function` needs the whole
-- body. The only difference from 20260819083207 is the two lines in the
-- tombstone UPDATE.
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
  'The database half of erasure: deletes the audit''s DELETE set, strips post media, and rewrites the profiles row into an anonymous tombstone -- handle, bio and avatar all scrubbed. Idempotent. Called only after storage objects are confirmed gone.';


-- ============================================================
-- 6. export_account_data: bio, avatar_path, and the two party columns.
--
-- Art. 20 reaches "personal data concerning him or her which he or she has
-- provided to a controller", and all four of these columns are literally that
-- -- the user typed them. bio and area go in as text. The two paths go in as
-- paths, matching how party_posts.media_path is already exported: a key is
-- what the system holds, and a signed URL minted at export time would expire
-- before most people opened the file.
--
-- Recreated in full for the same append-only reason as section 5. The only
-- differences are two lines in the `profile` column list and two in `parties`.
-- credibility_score stays out, for the reason the original comment gives.
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
