-- Phase 11: bio, avatar_path, cover_path, area.
--
-- Four nullable columns is a small migration, and almost nothing here is about
-- the columns existing. It is about three things that are invisible until they
-- fail:
--
--   1. The two path columns are guarded by CHECK constraints, because the
--      bucket policy cannot guard them. `Users can upload their own avatar`
--      controls where BYTES may be written; nothing in it controls what the
--      column may POINT AT, and `profiles` carries a table-wide UPDATE grant
--      with an owner-only row policy -- RLS gates rows, never columns
--      (CLAUDE.md gotcha #8). So a client PATCHing its own row to somebody
--      else's avatar path is a legal write of a legal row, and only a
--      constraint stops it. There are TWO distinct ways past the guard and
--      they are asserted separately (section 3): the wrong uuid, and the right
--      uuid followed by `..`. One passing tells you nothing about the other.
--
--   2. bio and avatar_path inherit the block filter from the `profiles` SELECT
--      policy, and they inherit it because the SELECT GRANT is table-wide.
--      That is the fragile part -- not the policy, which cannot express a
--      column, but the grant, which can. Section 5 asserts no column of
--      `profiles` carries a column-scoped ACL at all, so a future migration
--      that "tightens" the grant into a column list turns this red instead of
--      quietly giving bio a visibility rule of its own.
--
--   3. complete_account_erasure scrubs bio and avatar_path, and deliberately
--      does NOT scrub parties.cover_path. Both halves are asserted (section 8),
--      because both are decisions -- a tombstone keeping its self-description
--      is a scrubbed name attached to an unscrubbed person, and a hosted party
--      losing its cover blanks the header of an event other people are still
--      attending.
--
-- Personas (seed.sql): host 1111, invitee 2222, friend_not_invited 3333,
-- stranger 4444, blocked_user 5555, second_host 6666. Seeded parties used:
--   aaaa...0001  private, hosted by 1111
--   aaaa...0002  public,  hosted by 1111 ("Syntagma Afterparty")
-- No follows or blocks are seeded; the one block below is built here.
begin;
set search_path to public, extensions;
select plan(35);


-- ============================================================
-- 1. profiles.bio -- ONE line, 160 characters.
--
-- Written as the host, authenticated, not as postgres. The attack surface is a
-- PostgREST PATCH from a signed-in client, so the assertions have to run under
-- the same policy and grant that a client would.
-- ============================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select lives_ok(
  $$ update public.profiles set bio = 'Κουκάκι · ταράτσες και techno'
     where id = '11111111-1111-1111-1111-111111111111' $$,
  'a user can write their own bio -- the table-wide UPDATE grant reaches a column added later');

select throws_ok(
  $$ update public.profiles set bio = repeat('a', 161)
     where id = '11111111-1111-1111-1111-111111111111' $$,
  '23514',
  null,
  'bio is capped at 160 characters');

-- The cap is char_length, not octet_length, and this is the assertion that
-- proves it: 160 Greek characters is 320 bytes in UTF-8. Under a byte cap
-- every persona this feature exists for would get half the field, which is the
-- exact bug that makes a length limit read as hostile in one language and
-- invisible in another.
select lives_ok(
  $$ update public.profiles set bio = repeat('α', 160)
     where id = '11111111-1111-1111-1111-111111111111' $$,
  '160 GREEK characters fit -- the cap counts characters, not the 320 bytes they occupy');

select throws_ok(
  $$ update public.profiles set bio = ''
     where id = '11111111-1111-1111-1111-111111111111' $$,
  '23514',
  null,
  'the empty string is refused -- NULL is the only way to spell "no bio", so no renderer needs its own isEmpty check');

select throws_ok(
  $$ update public.profiles set bio = '   '
     where id = '11111111-1111-1111-1111-111111111111' $$,
  '23514',
  null,
  'whitespace-only is refused too -- otherwise the empty-string rule is one space away from being bypassed');

select throws_ok(
  $$ update public.profiles set bio = E'first line\nsecond line'
     where id = '11111111-1111-1111-1111-111111111111' $$,
  '23514',
  null,
  'a newline is refused -- "ONE line under @username" is enforced as a type, not left to every call site to collapse');


-- ============================================================
-- 2. parties.area -- the neighbourhood label, same shape as bio.
-- ============================================================
select lives_ok(
  $$ update public.parties set area = 'Κουκάκι'
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'a host can label their party with a neighbourhood');

select throws_ok(
  $$ update public.parties set area = ''
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  '23514',
  null,
  'area rejects the empty string -- NULL means "the host did not say" and nothing else does');

select throws_ok(
  $$ update public.parties set area = repeat('a', 81)
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  '23514',
  null,
  'area is capped at 80 -- it is a place name, not a sentence');


-- ============================================================
-- 3. avatar_path: THE negative case, and there are two of them.
--
-- Both writes below are writes the RLS policy permits: the host is updating
-- the host's own row. Neither is stopped by the storage policy either, because
-- no storage write is happening -- this is a column taking a string. If both
-- of these succeeded, the profile screen would render another user's face from
-- a public bucket and nothing anywhere would have been violated.
-- ============================================================
select lives_ok(
  $$ update public.profiles
     set avatar_path = '11111111-1111-1111-1111-111111111111/avatar.jpg'
     where id = '11111111-1111-1111-1111-111111111111' $$,
  'a user can point avatar_path at their OWN folder');

-- BYPASS A: name somebody else's folder outright.
select throws_ok(
  $$ update public.profiles
     set avatar_path = '22222222-2222-2222-2222-222222222222/avatar.jpg'
     where id = '11111111-1111-1111-1111-111111111111' $$,
  '23514',
  null,
  'THE NEGATIVE CASE: a user cannot set avatar_path to another user''s folder -- the bucket policy guards bytes, this constraint guards the pointer');

-- BYPASS B: start with the RIGHT folder and climb out of it. This is a
-- different bypass from A and it defeats a prefix check specifically -- the
-- string passes starts_with and still names another user. Object keys are
-- literal in S3, so this resolves to nothing there; the risk is the HTTP path
-- it gets interpolated into (/storage/v1/object/public/avatars/<path>), where
-- normalizing `..` before routing is standard proxy behaviour.
select throws_ok(
  $$ update public.profiles
     set avatar_path = '11111111-1111-1111-1111-111111111111/../22222222-2222-2222-2222-222222222222/avatar.jpg'
     where id = '11111111-1111-1111-1111-111111111111' $$,
  '23514',
  null,
  'THE SECOND NEGATIVE CASE: `..` is refused even from the correct folder -- a path that passes the prefix check and still escapes it');

-- CONTROL for the assertion above. Without this, a reader cannot tell whether
-- bypass B was refused by the `..` clause or by the prefix clause -- and if it
-- were the prefix clause, the `..` clause would be dead code that the test
-- appears to cover. This proves the string really does start with the owner's
-- own uuid, so the only thing left to have refused it is the traversal check.
select ok(
  starts_with(
    '11111111-1111-1111-1111-111111111111/../22222222-2222-2222-2222-222222222222/avatar.jpg',
    '11111111-1111-1111-1111-111111111111' || '/'
  ),
  'CONTROL: the traversal path DOES satisfy the prefix check -- so the assertion above proves the `..` clause fires, not the prefix one');

select throws_ok(
  $$ update public.profiles set avatar_path = 'avatar.jpg'
     where id = '11111111-1111-1111-1111-111111111111' $$,
  '23514',
  null,
  'a bare filename with no folder is refused -- the bucket root is nobody''s folder');

select lives_ok(
  $$ update public.profiles set avatar_path = null
     where id = '11111111-1111-1111-1111-111111111111' $$,
  'avatar_path can be cleared back to null -- "no image" stays expressible');

-- Put it back; sections 6 and 8 read it.
update public.profiles
set avatar_path = '11111111-1111-1111-1111-111111111111/avatar.jpg',
    bio = 'Κουκάκι · ταράτσες και techno'
where id = '11111111-1111-1111-1111-111111111111';


-- ============================================================
-- 4. cover_path: keyed by PARTY, which is the mistake worth pinning.
--
-- `party-covers` is {party_id}/..., not {user_id}/... -- the opposite of
-- `avatars`. A host reaching for "my folder" is the natural error and it
-- produces a path that looks entirely plausible.
-- ============================================================
select throws_ok(
  $$ update public.parties
     set cover_path = '11111111-1111-1111-1111-111111111111/cover.jpg'
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  '23514',
  null,
  'a host cannot key a cover by their OWN id -- party-covers is {party_id}/, and the host''s uuid is a valid-looking wrong answer');

select lives_ok(
  $$ update public.parties
     set cover_path = 'aaaaaaaa-0000-0000-0000-000000000002/cover.jpg'
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  'the party''s own folder is accepted');

select throws_ok(
  $$ update public.parties
     set cover_path = 'aaaaaaaa-0000-0000-0000-000000000002/../aaaaaaaa-0000-0000-0000-000000000001/cover.jpg'
     where id = 'aaaaaaaa-0000-0000-0000-000000000002' $$,
  '23514',
  null,
  'and `..` is refused on cover_path too -- a public party must not be able to name a PRIVATE party''s cover');


-- ============================================================
-- 5. The grant, which is what makes bio's block filter inherited.
--
-- The SELECT policy on `profiles` is `not is_blocked(auth.uid(), id)` and it is
-- row-scoped -- there is no formulation of it that could give bio a different
-- visibility from username, which is exactly why the migration changed nothing
-- there. What CAN break the inheritance is the grant: a column-scoped SELECT
-- grant would let a future migration hand out `username` without `bio`, and the
-- policy would be none the wiser.
--
-- So this section asserts the shape of the grant rather than its effect, and
-- pairs each assertion with a control on `user_devices` -- the one table that
-- deliberately DOES carry column-scoped grants (gotcha #8/#12). Without those
-- controls, both assertions below would pass just as happily against a query
-- that was broken and finding nothing.
--
-- Run as postgres: these read catalogs, not data, and the current role must not
-- be able to change the answer.
-- ============================================================
select tests.clear_authentication();
set local role postgres;

select is_empty(
  $$ select a.attname
     from pg_attribute a
     where a.attrelid = 'public.profiles'::regclass
       and a.attnum > 0
       and not a.attisdropped
       and a.attacl is not null $$,
  'THE REGRESSION GUARD: no column of public.profiles carries a column-scoped ACL -- a migration that narrows the table-wide grant to a column list breaks bio''s inherited block filter, and must fail here first');

select isnt_empty(
  $$ select a.attname
     from pg_attribute a
     where a.attrelid = 'public.user_devices'::regclass
       and a.attnum > 0
       and not a.attisdropped
       and a.attacl is not null $$,
  'CONTROL: the identical query DOES find column ACLs on user_devices -- so the assertion above is empty because profiles has none, not because the query is broken');

select ok(
  has_table_privilege('anon', 'public.profiles', 'select')
  and has_table_privilege('authenticated', 'public.profiles', 'select'),
  'SELECT on profiles is granted table-wide, so columns added later are readable without touching 20260812115436');

select ok(
  has_table_privilege('authenticated', 'public.profiles', 'update'),
  'UPDATE on profiles is granted table-wide, which is what makes bio and avatar_path client-writable -- the CHECK constraints are the guard, since a grant cannot express one');

select ok(
  not has_table_privilege('authenticated', 'public.user_devices', 'update'),
  'CONTROL: has_table_privilege returns FALSE on user_devices, whose UPDATE is column-scoped -- proving the two assertions above would go red if profiles were ever narrowed the same way');


-- ============================================================
-- 6. export_account_data carries all four (GDPR Art. 20).
--
-- The user typed every one of them. The two paths are exported AS PATHS,
-- matching party_posts.media_path: a signed URL minted at export time expires
-- long before most people open the file.
--
-- Also, per gotcha #15, this is the only thing that proves the rewritten
-- function body actually runs -- `db reset` parsed it and would have parsed a
-- misspelled column name just as happily.
-- ============================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select is(
  (select public.export_account_data() -> 'profile' ->> 'bio'),
  'Κουκάκι · ταράτσες και techno',
  'the export contains the user''s bio');

select is(
  (select public.export_account_data() -> 'profile' ->> 'avatar_path'),
  '11111111-1111-1111-1111-111111111111/avatar.jpg',
  'the export contains avatar_path, as a path rather than a URL that would expire before the file is opened');

select is(
  (select pa ->> 'area'
   from jsonb_array_elements(public.export_account_data() -> 'parties') pa
   where pa ->> 'id' = 'aaaaaaaa-0000-0000-0000-000000000002'),
  'Κουκάκι',
  'the export contains each hosted party''s area');

select is(
  (select pa ->> 'cover_path'
   from jsonb_array_elements(public.export_account_data() -> 'parties') pa
   where pa ->> 'id' = 'aaaaaaaa-0000-0000-0000-000000000002'),
  'aaaaaaaa-0000-0000-0000-000000000002/cover.jpg',
  'and each hosted party''s cover_path');


-- ============================================================
-- 7. bio and avatar_path follow the block filter, with no policy change.
--
-- The row either comes back or it does not. That is the whole mechanism, and
-- the third assertion is what makes the second one mean something: the bio is
-- still THERE, it is the policy hiding it. Without that control, "the stranger
-- reads no bio" would pass equally against a migration that had accidentally
-- deleted the value.
-- ============================================================
select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select is(
  (select bio from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'Κουκάκι · ταράτσες και techno',
  'CONTROL: before any block, a third party reads the host''s bio');

insert into public.blocks (blocker_id, blocked_id)
values ('44444444-4444-4444-4444-444444444444', '11111111-1111-1111-1111-111111111111');

select is_empty(
  $$ select bio, avatar_path from public.profiles
     where id = '11111111-1111-1111-1111-111111111111' $$,
  'after the block the whole row is gone, so bio and avatar_path are gone with it -- inherited from the row policy, with no column named anywhere');

select tests.clear_authentication();
set local role postgres;

select is(
  (select bio from public.profiles where id = '11111111-1111-1111-1111-111111111111'),
  'Κουκάκι · ταράτσες και techno',
  'CONTROL: the bio is still stored -- the assertion above is a policy filtering a row, not data that went missing');


-- ============================================================
-- 8. complete_account_erasure: bio and avatar_path scrubbed, cover_path kept.
--
-- friend_not_invited (3333) is the persona verify_account_erasure.sh also uses.
-- Given a bio, an avatar and a party of their own, then run past the grace
-- period and erased.
-- ============================================================
update public.profiles
set bio         = 'Εξάρχεια · πάντα αργά',
    avatar_path = '33333333-3333-3333-3333-333333333333/me.jpg',
    deleted_at  = now() - interval '31 days'
where id = '33333333-3333-3333-3333-333333333333';

insert into public.parties (id, host_id, title, location, starts_at, area, cover_path)
values ('cccccccc-0000-0000-0000-000000000009',
        '33333333-3333-3333-3333-333333333333',
        'Exarcheia Roof',
        st_point(23.7333, 37.9885)::geography,
        now() + interval '3 days',
        'Εξάρχεια',
        'cccccccc-0000-0000-0000-000000000009/cover.jpg');

select lives_ok(
  $$ select public.complete_account_erasure('33333333-3333-3333-3333-333333333333') $$,
  'complete_account_erasure runs -- the rewritten body executes, which a green db reset does not prove (gotcha #15)');

select is(
  (select bio from public.profiles where id = '33333333-3333-3333-3333-333333333333'),
  null,
  'the tombstone''s bio is scrubbed to NULL -- a self-description under an opaque handle is still a description of a person');

select is(
  (select avatar_path from public.profiles where id = '33333333-3333-3333-3333-333333333333'),
  null,
  'and avatar_path is scrubbed -- the eraser has already deleted the {user_id}/ prefix from the bucket, so this clears a pointer at nothing');

select isnt(
  (select username from public.profiles where id = '33333333-3333-3333-3333-333333333333'),
  'friend_not_invited',
  'CONTROL: the handle is scrubbed too, so the two assertions above are the erasure running rather than the row never having had a bio');

select is(
  (select cover_path from public.parties where id = 'cccccccc-0000-0000-0000-000000000009'),
  'cccccccc-0000-0000-0000-000000000009/cover.jpg',
  'the party''s cover SURVIVES, deliberately: a party outlives its host (parties.host_id is `no action`) and the cover depicts a venue, not a person -- blanking it would break the header of an event other people are still attending');

select * from finish();
rollback;
