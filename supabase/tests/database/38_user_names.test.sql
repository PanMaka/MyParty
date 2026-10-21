-- Phase 44: first and last name in user_names (20261021094725), in the export
-- and erasure (20261021094727). Closes backlog 1.32.
--
-- What has to hold:
--
--   A. Shape: owner-read-only, no client write of any kind, the CHECK holds
--      even for a writer that bypasses set_my_names.
--   B. The rule: trimmed, 1-50, no control characters, and nothing about
--      alphabets.
--   C. set_my_names: sets, replaces, trims, refuses half a name, own row only,
--      anon out.
--   D. Export carries both names; erasure deletes the row.
--
-- The one-off copy from auth metadata cannot be re-run here (seed.sql runs
-- after the migration and plants no names); it was checked by hand against
-- planted accounts in a rolled-back transaction, including the apply failing
-- on half a name.
--
-- Personas: host 1111, stranger 4444, friend_not_invited 3333 (erased in D).
begin;
set search_path to public, extensions;
select plan(24);


-- ===========================================================================
-- A + C. Writes, and who reads them.
-- ===========================================================================
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'); -- host

select lives_ok($$ select public.set_my_names('  Γιώργος ', 'Παπαδόπουλος') $$, 'set_my_names runs');
select is(
  (select first_name || '|' || last_name from public.user_names where user_id = '11111111-1111-1111-1111-111111111111'),
  'Γιώργος|Παπαδόπουλος', 'the owner reads their names back, trimmed');

select public.set_my_names('George', 'Pap');
select is(
  (select first_name || '|' || last_name from public.user_names where user_id = '11111111-1111-1111-1111-111111111111'),
  'George|Pap', 'a second call replaces both');

select throws_ok($$ select public.set_my_names('George', '') $$, '22023', 'invalid name', 'half a name is refused');
select throws_ok($$ select public.set_my_names(null, 'Pap') $$, '22023', 'invalid name', 'NULL is refused');
select throws_ok($$ select public.set_my_names('   ', 'Pap') $$, '22023', 'invalid name', 'blank is refused');
select throws_ok($$ select public.set_my_names(repeat('a', 51), 'Pap') $$, '22023', 'invalid name', '51 characters is refused');
select throws_ok($$ select public.set_my_names(E'Geo\nrge', 'Pap') $$, '22023', 'invalid name', 'a newline is refused');
select is(
  (select first_name from public.user_names where user_id = '11111111-1111-1111-1111-111111111111'),
  'George', 'and a refused call changed nothing');

select throws_ok(
  $$ insert into public.user_names (user_id, first_name, last_name)
     values ('11111111-1111-1111-1111-111111111111', 'X', 'Y') $$,
  '42501', null, 'NEGATIVE: no direct INSERT');
select throws_ok(
  $$ update public.user_names set first_name = 'X' where user_id = '11111111-1111-1111-1111-111111111111' $$,
  '42501', null, 'NEGATIVE: no direct UPDATE');
select throws_ok(
  $$ delete from public.user_names where user_id = '11111111-1111-1111-1111-111111111111' $$,
  '42501', null, 'NEGATIVE: no direct DELETE');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger
select is_empty(
  $$ select 1 from public.user_names where user_id = '11111111-1111-1111-1111-111111111111' $$,
  'NEGATIVE: a stranger reads nothing of the host''s names');
select is(
  (select count(*)::int from public.user_names), 0,
  'and sees no row at all, having none of their own');

select tests.clear_authentication(); -- anon
select throws_ok($$ select 1 from public.user_names $$, '42501', null, 'anon holds no grant on user_names');
select throws_ok($$ select public.set_my_names('A', 'B') $$, '42501', null, 'anon cannot call set_my_names');


-- ===========================================================================
-- A + B. The rule, and the CHECK behind it.
-- ===========================================================================
reset role;
select is(
  (select array_agg(v order by v) from unnest(array[
     'Μαρία', 'O''Brien', 'Jean-Luc', 'José María', 'X', repeat('a', 50)
   ]) v where not public.person_name_is_valid(v)),
  null, 'valid: any alphabet, apostrophes, hyphens, inner spaces, 1 to 50');
select is(
  (select array_agg(v order by v) from unnest(array[
     '', ' Ana', 'Ana ', repeat('a', 51), E'A\tB'
   ]) v where public.person_name_is_valid(v)),
  null, 'invalid: empty, untrimmed, 51, a control character');
select throws_ok(
  $$ insert into public.user_names (user_id, first_name, last_name)
     values ('44444444-4444-4444-4444-444444444444', ' padded', 'Y') $$,
  '23514', null, 'the CHECK holds for a writer that bypasses set_my_names');


-- ===========================================================================
-- D. Export and erasure.
-- ===========================================================================
select tests.authenticate_as('33333333-3333-3333-3333-333333333333');
select public.set_my_names('Friend', 'Notinvited');
select is(public.export_account_data() ->> 'first_name', 'Friend', 'the export carries the first name');
select is(public.export_account_data() ->> 'last_name', 'Notinvited', 'and the last name');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444');
select ok(
  public.export_account_data() ? 'first_name'
  and public.export_account_data() -> 'first_name' = 'null'::jsonb,
  'an account with no names exports an explicit null, not a missing key');

reset role;
update public.profiles set deleted_at = now() - interval '31 days'
where id = '33333333-3333-3333-3333-333333333333';
select lives_ok(
  $$ select public.complete_account_erasure('33333333-3333-3333-3333-333333333333') $$,
  'complete_account_erasure runs for an account with names');
select is(
  (select count(*)::int from public.user_names where user_id = '33333333-3333-3333-3333-333333333333'),
  0, 'erasure deletes the names');

select * from finish();
rollback;
