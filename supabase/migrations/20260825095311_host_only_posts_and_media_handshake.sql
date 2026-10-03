-- Party posts become HOST-ONLY, and post media gets the upload handshake it
-- never had.
--
-- Two changes that only make sense together: tightening who may post is what
-- makes "the host's photos of this party" a thing the schema can express, and
-- the handshake is what lets a host attach a photo at all. Until now the
-- client could write `media_path` but had no way to upload the object it
-- named -- see part 3.


-- ===========================================================================
-- PART 1 -- only the host writes.
-- ===========================================================================
-- The rule lives in the INSERT policy, not in a read filter. A read-side
-- `author_id = host_id` would be a second statement of the same rule, and two
-- places that express one rule drift: the policy is what makes it TRUE, and a
-- filter would only make it LOOK true while non-host rows accumulated behind
-- it. The SELECT policy is therefore deliberately NOT touched here.
--
-- WHAT THIS COSTS, STATED PLAINLY: get_feed shows posts from every party the
-- viewer can access, from any author. With this policy in place it can only
-- ever show host posts, so the Phase 4 feed stops being a place attendees post
-- and becomes a host broadcast. post_likes and post_comments are untouched --
-- guests still react and reply -- so the feed keeps its conversation, it just
-- loses guest authorship. Reversing this is one migration; the read side needs
-- no change either way, which is the point of keeping the rule in one place.

create or replace function public.is_party_host(p_party_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.parties p
    where p.id = p_party_id
    and p.host_id = (select auth.uid())
  );
$$;

-- SECURITY DEFINER for gotcha 1's reason, the same one party_is_private
-- carries: this asks about the PARTY. Answered through the caller's filtered
-- view of public.parties, a row the caller cannot see returns no rows and
-- reads as "you are not the host" -- which for THIS helper fails closed and is
-- therefore harmless today. It is definer anyway so the pair cannot diverge,
-- and so that a future caller which needs the other polarity is not silently
-- given the filtered answer.
comment on function public.is_party_host(uuid) is
  'True when the caller hosts the party. Definer because it asks about the '
  'party, not the viewer -- see party_is_private.';

revoke execute on function public.is_party_host(uuid) from public;
grant execute on function public.is_party_host(uuid) to authenticated;

drop policy "Users can post to parties they can access" on public.party_posts;

create policy "Only the host can post to a party"
on public.party_posts for insert to authenticated
with check (
  author_id = (select auth.uid())
  and hidden_at is null
  -- can_access_party is now implied by is_party_host -- a host can always
  -- access their own party -- but it stays. It is the helper every other
  -- policy on this table composes (CLAUDE.md #4), and dropping it here would
  -- mean a future widening of who may post silently loses the visibility
  -- check along with the host check.
  and public.can_access_party(party_id)
  and public.is_party_host(party_id)
);


-- ===========================================================================
-- PART 2 -- media_path stops being client-writable.
-- ===========================================================================
-- THE SHARP EDGE THIS CLOSES. `grant insert (…, media_path)` let a client name
-- a storage key, while the post-media bucket has no INSERT policy at all
-- (20260812124217: "uploads go through signed URLs only"). So the client could
-- write a reference and could not possibly write the object -- every media
-- post was a dangling reference by construction, renderable as nothing but a
-- broken frame, and unfixable because nothing else could fill it either.
--
-- Same treatment stories got: the path is DERIVED by a before-insert trigger
-- from {party_id}/{id}.{ext}, and no role holds an insert grant on it. A
-- client that cannot name the path cannot aim an upload at another party's
-- folder, and the deterministic shape lets any future purge reconstruct the
-- key from the row alone.

alter table public.party_posts
  add column media_type text,
  add column media_uploaded_at timestamp with time zone;

-- The bucket accepts what this list allows and nothing else -- the extension
-- in media_path is derived from it, so an unknown type would have no path to
-- derive. Nullable, unlike stories.content_type: a post may be text-only,
-- which is the whole reason party_posts_not_empty exists.
alter table public.party_posts
  add constraint party_posts_media_type check (
    media_type is null
    or media_type in ('image/jpeg', 'image/png', 'image/webp', 'video/mp4')
  );

-- A path exists exactly when a type was declared. Without this the trigger's
-- contract is only a convention.
alter table public.party_posts
  add constraint party_posts_media_path_implies_type check (
    (media_path is null) = (media_type is null)
  );

-- Confirmation implies a path to have confirmed.
alter table public.party_posts
  add constraint party_posts_uploaded_implies_path check (
    media_uploaded_at is null or media_path is not null
  );

create or replace function public.set_post_media_path()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if NEW.media_type is null then
    -- A text-only post. Null rather than a placeholder key, so
    -- party_posts_not_empty still does its job.
    NEW.media_path := null;
    return NEW;
  end if;

  NEW.media_path := NEW.party_id::text || '/' || NEW.id::text || '.' ||
    case NEW.media_type
      when 'image/jpeg' then 'jpg'
      when 'image/png'  then 'png'
      when 'image/webp' then 'webp'
      when 'video/mp4'  then 'mp4'
    end;

  -- Unreachable while party_posts_media_type holds. Here so that widening
  -- that check without widening this case list fails loudly at insert time
  -- instead of quietly writing a path ending in '.' that nothing can serve.
  if NEW.media_path is null or NEW.media_path like '%.' then
    raise exception 'no media extension defined for media type %', NEW.media_type;
  end if;

  return NEW;
end;
$$;

create trigger party_posts_set_media_path
before insert on public.party_posts
for each row execute function public.set_post_media_path();

-- Any post that already carries a path predates the handshake and its bytes,
-- if any, are already in place. Backfilled so the SELECT policy below does not
-- retroactively hide it as "pending". A no-op on a database with no media
-- posts, which is every one of them today.
update public.party_posts
set media_uploaded_at = created_at
where media_path is not null and media_uploaded_at is null;

-- media_type replaces media_path in the grant. Revoke first: column grants
-- accumulate, so re-granting a narrower list does not withdraw the old one.
revoke insert on public.party_posts from authenticated;
grant insert (id, party_id, author_id, body, media_type)
  on public.party_posts to authenticated;

-- No UPDATE grant is added. media_uploaded_at is written only by the definer
-- RPC in part 3 -- gotcha 8: RLS filters rows, it cannot protect a column, so
-- the privilege simply is not held.


-- ===========================================================================
-- PART 3 -- the upload handshake.
-- ===========================================================================
-- Mirrors stories exactly (20260815133039): create the row, ask for the path,
-- PUT to a signed URL the edge function mints, confirm. The edge function
-- holds the service key and therefore decides nothing -- it re-asks the
-- database whether this caller has a pending upload for this post, and only
-- signs if the answer is yes.
--
-- A media post is INVISIBLE until confirmed. That is what makes the handshake
-- safe to abandon: a client that dies after the insert leaves a row nobody can
-- see rather than a broken frame on every phone that opens the feed.

drop policy "Posts are viewable by anyone who can access the party" on public.party_posts;

create policy "Posts are viewable by anyone who can access the party"
on public.party_posts for select
using (
  hidden_at is null
  -- A declared-but-unconfirmed upload is not a post yet. Text-only posts have
  -- no media_type and are unaffected, which is why this is not simply
  -- `media_uploaded_at is not null`.
  and (media_type is null or media_uploaded_at is not null)
  and public.can_access_party(party_id)
  and not public.is_blocked((select auth.uid()), author_id)
);

-- Every narrowing term below is deliberate, and they are the same four
-- story_upload_target uses:
--   author_id = auth.uid()      only the author uploads their own bytes
--   media_type is not null      a text-only post has nothing to upload
--   media_uploaded_at is null   an upload URL is one-shot; once confirmed, a
--                               second signature would let the media under a
--                               post swap after people have seen it
--   hidden_at is null           a moderated post does not get to be refilled
create or replace function public.post_upload_target(p_post_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  v_path text;
begin
  select pp.media_path into v_path
  from public.party_posts pp
  where pp.id = p_post_id
  and pp.author_id = (select auth.uid())
  and pp.media_type is not null
  and pp.media_uploaded_at is null
  and pp.hidden_at is null;

  if v_path is null then
    raise exception 'no pending upload for post %', p_post_id
      using errcode = '42501';
  end if;

  return v_path;
end;
$$;

-- Does NOT take the client's word that the upload happened: it checks
-- storage.objects for the exact path, so "visible" implies "the bytes are
-- really in the bucket". Without that a client could skip the PUT entirely and
-- publish a post that renders as a broken frame everywhere -- and, worse, an
-- unfixable one, since post_upload_target refuses to re-sign a confirmed row.
--
-- Reading storage.objects is the other half of why this is definer: that table
-- has RLS on and post-media has no policy any client role can read through.
create or replace function public.confirm_post_upload(p_post_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_path text;
begin
  select pp.media_path into v_path
  from public.party_posts pp
  where pp.id = p_post_id
  and pp.author_id = (select auth.uid())
  and pp.media_type is not null
  and pp.media_uploaded_at is null
  and pp.hidden_at is null;

  if v_path is null then
    raise exception 'no pending upload for post %', p_post_id
      using errcode = '42501';
  end if;

  if not exists (
    select 1 from storage.objects o
    where o.bucket_id = 'post-media'
    and o.name = v_path
  ) then
    raise exception 'no media uploaded for post %', p_post_id
      using errcode = 'P0002';
  end if;

  update public.party_posts
  set media_uploaded_at = now()
  where id = p_post_id;
end;
$$;

comment on function public.post_upload_target(uuid) is
  'The storage key a pending media post expects its bytes at. Definer: the '
  'client never names the path, which is what stops an upload being aimed at '
  'another party''s folder.';

comment on function public.confirm_post_upload(uuid) is
  'Makes a media post visible, and only after checking storage.objects for the '
  'bytes. The client''s word is not evidence -- skipping the PUT would publish '
  'an unfixable broken frame, since post_upload_target will not re-sign.';

revoke execute on function public.post_upload_target(uuid) from public;
revoke execute on function public.confirm_post_upload(uuid) from public;
grant execute on function public.post_upload_target(uuid) to authenticated;
grant execute on function public.confirm_post_upload(uuid) to authenticated;
-- The edge function calls post_upload_target with the service key, and gotcha
-- 13 applies: the revoke above took service_role's privilege with it, because
-- PUBLIC is where it came from.
grant execute on function public.post_upload_target(uuid) to service_role;
