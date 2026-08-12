-- Buckets: avatars is public-read; the rest are visibility-gated and
-- never written to directly by the client (signed URLs only, issued
-- server-side in a later phase).
insert into storage.buckets (id, name, public) values
  ('avatars', 'avatars', true),
  ('party-covers', 'party-covers', false),
  ('post-media', 'post-media', false),
  ('story-media', 'story-media', false);

-- avatars: {user_id}/... path convention, public read, owner-only write.
create policy "Avatar images are publicly accessible"
on storage.objects for select
using ( bucket_id = 'avatars' );

create policy "Users can upload their own avatar"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'avatars'
  and (select auth.uid())::text = (storage.foldername(name))[1]
);

create policy "Users can update their own avatar"
on storage.objects for update
to authenticated
using (
  bucket_id = 'avatars'
  and (select auth.uid())::text = (storage.foldername(name))[1]
)
with check (
  bucket_id = 'avatars'
  and (select auth.uid())::text = (storage.foldername(name))[1]
);

create policy "Users can delete their own avatar"
on storage.objects for delete
to authenticated
using (
  bucket_id = 'avatars'
  and (select auth.uid())::text = (storage.foldername(name))[1]
);

-- party-covers, post-media: {party_id}/... path convention. Read
-- access follows the party's own visibility instead of reimplementing
-- it — the exists() subquery re-runs the "Parties are viewable based
-- on privacy and invitations" policy for the querying role, so a
-- private party's cover/post media is exactly as visible as the party
-- row itself. No insert/update/delete policy: uploads go through
-- signed URLs only, never a direct client write.
create policy "Party cover images follow party visibility"
on storage.objects for select
using (
  bucket_id = 'party-covers'
  and exists (
    select 1 from public.parties
    where parties.id = (storage.foldername(name))[1]::uuid
  )
);

create policy "Post media follows party visibility"
on storage.objects for select
using (
  bucket_id = 'post-media'
  and exists (
    select 1 from public.parties
    where parties.id = (storage.foldername(name))[1]::uuid
  )
);

-- story-media: intentionally no policies at all. storage.objects has
-- RLS enabled by default, so zero permissive policies means zero
-- client access either way — both reads and writes go through
-- service-role-issued signed URLs only.
