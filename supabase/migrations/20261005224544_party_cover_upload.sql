-- Party covers get the upload handshake post media got in 20260825095311.
--
-- parties.cover_path has existed since 20260820095801 and every read surface
-- already signs it (PartyRepository.signedCoverUrls), but nothing has ever
-- WRITTEN it: the party-covers bucket ships a SELECT policy and, deliberately,
-- no INSERT policy for any role (20260812124217 -- "uploads go through signed
-- URLs only"). So a cover needs something holding the service key to mint an
-- upload URL, and something to decide when the column may point at the bytes.
-- Same split as post-media: the party-cover edge function signs, these two
-- functions decide.
--
--   create_party_with_invites -> party_cover_upload_target -> signed PUT
--                             -> confirm_party_cover
--
-- The cover is uploaded AFTER the party exists, because the path is
-- {party_id}/... and the id is minted by create_party_with_invites. A failed
-- upload therefore leaves a party with no cover, which is exactly the state
-- every party is in today -- the client says so and moves on.


-- ============================================================
-- 1. The path. One per party, derived here, never accepted from the client.
--
-- {party_id}/cover, with no extension. The picker re-encodes to JPEG unless
-- the image has an alpha channel, in which case it stays PNG
-- (image_picker_android's ImageResizer: saveAsPNG = bitmap.hasAlpha()) --
-- and phone screenshots, i.e. photographed flyers, usually do. So the format
-- is not knowable up front, and Storage records each object's real
-- content-type anyway; an extension would only be a second claim about the
-- format that could disagree with the first. A fixed name is what makes the
-- handshake one-shot: once confirmed,
-- cover_path is not null and this refuses to answer again, and the edge
-- function signs with upsert: false, so even a replayed token cannot swap the
-- picture under guests who have already seen it. Changing a cover later is a
-- separate feature with its own replace-and-clean-up ordering (see
-- ProfileRepository.replaceAvatar) and is not attempted here.
--
-- Host-only through is_party_host rather than an inline host_id comparison --
-- one helper per rule.
-- ============================================================
create or replace function public.party_cover_upload_target(p_party_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
stable
as $$
begin
  if not public.is_party_host(p_party_id) or exists (
    select 1 from public.parties p
    where p.id = p_party_id
    and (p.cover_path is not null or p.status = 'cancelled')
  ) then
    raise exception 'no pending cover for party %', p_party_id
      using errcode = '42501';
  end if;

  return p_party_id::text || '/cover';
end;
$$;


-- ============================================================
-- 2. The confirmation. Does not take the client's word that the PUT happened.
--
-- Checks storage.objects for the exact key before pointing cover_path at it,
-- for the reason confirm_post_upload does: a column pointing at bytes that
-- never arrived renders as a broken image on every card, and because the
-- target refuses to re-sign a party that already has a cover, it would be an
-- unfixable one. Definer for two reasons: storage.objects is RLS-on and
-- party-covers has no policy a client could read an unconfirmed object
-- through, and parties carries no UPDATE grant on this column for clients.
--
-- The parties_cover_path_own_folder CHECK still applies to this UPDATE, so
-- even a bug in the path expression above cannot point a party at another
-- party's folder.
-- ============================================================
create or replace function public.confirm_party_cover(p_party_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_path text := public.party_cover_upload_target(p_party_id);
begin
  if not exists (
    select 1 from storage.objects o
    where o.bucket_id = 'party-covers'
    and o.name = v_path
  ) then
    raise exception 'no cover uploaded for party %', p_party_id
      using errcode = 'P0002';
  end if;

  update public.parties
  set cover_path = v_path
  where id = p_party_id;

  return v_path;
end;
$$;

comment on function public.party_cover_upload_target(uuid) is
  'The storage key a party''s cover is uploaded to, for its host, while it has '
  'no cover yet. Definer: the client never names the path.';

comment on function public.confirm_party_cover(uuid) is
  'Points parties.cover_path at the uploaded cover, and only after checking '
  'storage.objects for the bytes. One-shot: a party with a cover is refused.';

revoke execute on function public.party_cover_upload_target(uuid) from public;
revoke execute on function public.confirm_party_cover(uuid) from public;
grant execute on function public.party_cover_upload_target(uuid) to authenticated;
grant execute on function public.confirm_party_cover(uuid) to authenticated;
-- Gotcha 13: the edge function calls the target with the caller's JWT, but the
-- revoke above also took service_role's privilege, and the post-media
-- precedent grants it back so a service-key call fails on the rule, not on a
-- missing privilege.
grant execute on function public.party_cover_upload_target(uuid) to service_role;


-- ============================================================
-- 3. The bucket's limits, set now because this is the first time anything can
-- write to it.
--
-- A signed upload URL lets the holder choose the body and its content type, so
-- without these a two-minute URL is an invitation to store a 500MB file or an
-- HTML page in a bucket whose objects are served back to every guest. JPEG and
-- PNG are the two formats the picker can hand over (see section 1). A cover
-- renders as a card header and the client resizes to 1600px, so a JPEG lands
-- well under 1MB; 5MB is headroom for the PNG case rather than a target.
-- ============================================================
update storage.buckets
set file_size_limit = 5 * 1024 * 1024,
    allowed_mime_types = array['image/jpeg', 'image/png']
where id = 'party-covers';
