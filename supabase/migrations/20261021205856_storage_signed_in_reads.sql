-- Phase 46, part D: storage reads need a signed-in caller.
--
-- Three SELECT policies on storage.objects were written TO public, which in a
-- policy means every role, anon included:
--
--   * party-covers and post-media follow party visibility through an EXISTS on
--     public.parties. For anon that was the public-party arm of the parties
--     policy, so a signed-out caller could sign URLs for the cover and the post
--     media of any public party. Part A took parties away from anon, so the
--     EXISTS would now raise rather than filter; TO authenticated says what
--     was meant.
--   * avatars was `bucket_id = 'avatars'` for everyone, which let anyone LIST
--     the bucket: every user id that has ever set a photo.
--
-- Avatars, decided Phase 46 (Option 1, backlog §3): the bucket stays public, so
-- /storage/v1/object/public/avatars/<path> keeps serving a known path to
-- anyone, which is how the client shows avatars (ProfileRepository.avatarUrl)
-- and does not go through this policy. Listing and the authenticated download
-- routes need a signed-in caller. Owner writes are untouched; an upsert and a
-- remove still read the row through this policy as authenticated.


alter policy "Avatar images are publicly accessible" on storage.objects
  to authenticated;

alter policy "Party cover images follow party visibility" on storage.objects
  to authenticated;

alter policy "Post media follows party visibility" on storage.objects
  to authenticated;
