-- Phase 48: get_follow_suggestions, the suggest_account opt-out and the
-- dismissals (20261022153236).
--
--   A. Ranking: mutuals, then follows_you, then popular, each in its order.
--   B. Every exclusion, each with the lift that brings the account back.
--   C. Mutual names: a block-paired or pending mutual is neither named nor
--      counted.
--   D. Access: no user argument, the caller's own answer, signed out refused.
--   E. Paging.
--   F. Dismissals: dismiss, undo, owner-only, no direct writes.
--   G. The setting: owner-written, owner-read, enforced on other callers.
--   H. Export and erasure.
--
-- The fixtures are fresh accounts (e48e...), so the seeded graph only reaches
-- the popular tail. Where an order is asserted, the uuids and usernames are
-- chosen so that uuid order and alphabetical order both DISAGREE with the
-- expected order: against agreeing fixtures, a ranking that ignored its keys
-- would pass.
--
--   V   001  the viewer
--   A   002  p48_zed, followed by V, follower_count 300
--   B   003  p48_amy, followed by V, follower_count 200
--   C   004  followed by V
--   Mb  005  followed by V through a planted edge, block-paired with V
--   Mp  006  followed by V, pending deletion
--   Q   007  followed only by Mb
--   Y   0f1  A follows; follows V; follower_count 50
--   Z   0f8  C follows; follower_count 500
--   X   0f9  A and B follow (and Mb, Mp)
--   W   0e1  follows V, two days ago
--   W2  0e2  follows V, one day ago
--   P2  0d1  popular, 800000
--   P   0d2  popular, 900000
--   E*  020-027  each followed by A, each excluded for one reason
--   D   030  the erasure subject
begin;
set search_path to public, extensions;
select plan(64);


-- ===========================================================================
-- Fixtures (as postgres)
-- ===========================================================================
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select '00000000-0000-0000-0000-000000000000', ('e48e0000-0000-0000-0000-000000000' || v.s)::uuid,
       'authenticated', 'authenticated', 'p48_' || v.s || '@myparty.local',
       crypt('password123', gen_salt('bf')), current_timestamp,
       '{"provider":"email","providers":["email"]}', '{}'::jsonb, current_timestamp, current_timestamp
from unnest(array['001','002','003','004','005','006','007','0f1','0f8','0f9','0e1','0e2',
                  '0d1','0d2','020','021','022','023','024','025','026','027','030']) v(s);

update public.profiles
set username = case id
      when 'e48e0000-0000-0000-0000-000000000002' then 'p48_zed'
      when 'e48e0000-0000-0000-0000-000000000003' then 'p48_amy'
      else 'p48_' || right(id::text, 3)
    end,
    onboarding_completed_at = now()
where id::text like 'e48e0000-%';

-- Edges. A block purges follows between its pair, so V -> Mb is planted
-- after the block below.
insert into public.follows (follower_id, followee_id, created_at)
select ('e48e0000-0000-0000-0000-000000000' || e.a)::uuid,
       ('e48e0000-0000-0000-0000-000000000' || e.b)::uuid,
       now() - e.age
from (values
  ('001','002', interval '0'), ('001','003', interval '0'), ('001','004', interval '0'),
  ('001','006', interval '0'), ('001','020', interval '0'),
  ('002','0f1', interval '0'), ('002','0f9', interval '0'), ('003','0f9', interval '0'),
  ('004','0f8', interval '0'), ('006','0f9', interval '0'),
  ('003','001', interval '0'),                          -- B follows V: V is a FoF of itself
  ('0f1','001', interval '3 days'),
  ('0e1','001', interval '2 days'), ('0e2','001', interval '1 day'),
  ('002','020', interval '0'), ('002','021', interval '0'), ('002','022', interval '0'),
  ('002','023', interval '0'), ('002','024', interval '0'), ('002','025', interval '0'),
  ('002','026', interval '0'), ('002','027', interval '0')
) e(a, b, age);

insert into public.blocks (blocker_id, blocked_id) values
  ('e48e0000-0000-0000-0000-000000000001', 'e48e0000-0000-0000-0000-000000000005'),  -- V blocks Mb
  ('e48e0000-0000-0000-0000-000000000001', 'e48e0000-0000-0000-0000-000000000021'),  -- V blocks E_block
  ('e48e0000-0000-0000-0000-000000000022', 'e48e0000-0000-0000-0000-000000000001');  -- E_blockrev blocks V

insert into public.follows (follower_id, followee_id) values
  ('e48e0000-0000-0000-0000-000000000001', 'e48e0000-0000-0000-0000-000000000005'),  -- planted V -> Mb
  ('e48e0000-0000-0000-0000-000000000005', 'e48e0000-0000-0000-0000-0000000000f9'),  -- Mb -> X
  ('e48e0000-0000-0000-0000-000000000005', 'e48e0000-0000-0000-0000-000000000007');  -- Mb -> Q

update public.profiles set deleted_at = now()
where id in ('e48e0000-0000-0000-0000-000000000006', 'e48e0000-0000-0000-0000-000000000023');
update public.profiles set deleted_at = now() - interval '40 days', erased_at = now()
where id = 'e48e0000-0000-0000-0000-000000000024';
update public.profiles set suggest_account = false where id = 'e48e0000-0000-0000-0000-000000000025';
update public.profiles set onboarding_completed_at = null where id = 'e48e0000-0000-0000-0000-000000000027';
insert into public.follow_suggestion_dismissals (user_id, dismissed_id)
values ('e48e0000-0000-0000-0000-000000000001', 'e48e0000-0000-0000-0000-000000000026');  -- V dismissed E_dismissed

-- Counters, set last so the edges above do not move them.
update public.profiles p set follower_count = v.n
from (values
  ('e48e0000-0000-0000-0000-000000000002'::uuid, 300), ('e48e0000-0000-0000-0000-000000000003'::uuid, 200),
  ('e48e0000-0000-0000-0000-0000000000f1'::uuid, 50),  ('e48e0000-0000-0000-0000-0000000000f8'::uuid, 500),
  ('e48e0000-0000-0000-0000-0000000000f9'::uuid, 10),
  ('e48e0000-0000-0000-0000-0000000000d1'::uuid, 800000), ('e48e0000-0000-0000-0000-0000000000d2'::uuid, 900000)
) v(id, n)
where p.id = v.id;

-- Short names for the assertions.
create temp table u (k text primary key, id uuid) on commit drop;
insert into u values
  ('V','e48e0000-0000-0000-0000-000000000001'), ('A','e48e0000-0000-0000-0000-000000000002'),
  ('B','e48e0000-0000-0000-0000-000000000003'), ('Mb','e48e0000-0000-0000-0000-000000000005'),
  ('Mp','e48e0000-0000-0000-0000-000000000006'), ('Q','e48e0000-0000-0000-0000-000000000007'),
  ('Y','e48e0000-0000-0000-0000-0000000000f1'), ('Z','e48e0000-0000-0000-0000-0000000000f8'),
  ('X','e48e0000-0000-0000-0000-0000000000f9'), ('W','e48e0000-0000-0000-0000-0000000000e1'),
  ('W2','e48e0000-0000-0000-0000-0000000000e2'), ('P2','e48e0000-0000-0000-0000-0000000000d1'),
  ('P','e48e0000-0000-0000-0000-0000000000d2'),
  ('E_follow','e48e0000-0000-0000-0000-000000000020'), ('E_block','e48e0000-0000-0000-0000-000000000021'),
  ('E_blockrev','e48e0000-0000-0000-0000-000000000022'), ('E_pending','e48e0000-0000-0000-0000-000000000023'),
  ('E_erased','e48e0000-0000-0000-0000-000000000024'), ('E_optout','e48e0000-0000-0000-0000-000000000025'),
  ('E_dismissed','e48e0000-0000-0000-0000-000000000026'), ('E_noonboard','e48e0000-0000-0000-0000-000000000027'),
  ('D','e48e0000-0000-0000-0000-000000000030');
grant select on u to authenticated, anon;

-- The full list for the current caller, as fixture names (seed accounts as '-').
create function pg_temp.names() returns text[] language sql as $$
  select array(
    select coalesce((select u.k from u where u.id = s.user_id), '-')
    from public.get_follow_suggestions(null, null, null, 50) s
  );
$$;
create function pg_temp.row_of(p_k text) returns record language sql as $$
  select (s.reason, s.follows_you, s.mutual_count, s.mutual_usernames)
  from public.get_follow_suggestions(null, null, null, 50) s
  where s.user_id = (select id from u where k = p_k);
$$;
create function pg_temp.suggested(p_k text) returns boolean language sql as $$
  select exists (
    select 1 from public.get_follow_suggestions(null, null, null, 50) s
    where s.user_id = (select id from u where k = p_k));
$$;
grant execute on function pg_temp.names(), pg_temp.row_of(text), pg_temp.suggested(text) to authenticated;


-- ===========================================================================
-- A. Ranking.
-- ===========================================================================
select tests.authenticate_as('e48e0000-0000-0000-0000-000000000001'); -- V

select is(
  (pg_temp.names())[1:7],
  array['X', 'Z', 'Y', 'W2', 'W', 'P', 'P2'],
  'mutuals by count then follower_count, then follows_you newest first, then popular by follower_count');

select is(
  (select array[reason, follows_you::text, mutual_count::text, mutual_usernames::text]
   from public.get_follow_suggestions(null, null, null, 50) where user_id = (select id from u where k = 'X')),
  array['mutuals', 'false', '2', '{p48_zed,p48_amy}'],
  'X: two mutuals, named most-followed first (zed before amy, not alphabetical)');

select is(
  (select array[reason, follows_you::text, mutual_count::text, mutual_usernames::text]
   from public.get_follow_suggestions(null, null, null, 50) where user_id = (select id from u where k = 'Y')),
  array['mutuals', 'true', '1', '{p48_zed}'],
  'Y follows V AND has a mutual: tier 1, with follows_you set for the label');

select is(
  (select array[reason, follows_you::text, mutual_count::text, mutual_usernames::text]
   from public.get_follow_suggestions(null, null, null, 50) where user_id = (select id from u where k = 'W')),
  array['follows_you', 'true', '0', '{}'],
  'W: follows V, no mutuals -- "Follows you"');

select is(
  (select array[reason, follows_you::text, mutual_count::text, mutual_usernames::text]
   from public.get_follow_suggestions(null, null, null, 50) where user_id = (select id from u where k = 'P')),
  array['popular', 'false', '0', '{}'],
  'P: no connection -- "Popular"');

select is(
  (select array_agg(distinct sort_tier order by sort_tier) from public.get_follow_suggestions(null, null, null, 50)),
  array[1, 2, 3]::smallint[],
  'all three tiers are present for this viewer');

select is(
  (select count(*) from public.get_follow_suggestions(null, null, null, 50) s
   where s.sort_tier = 1 and s.reason <> 'mutuals'
      or s.sort_tier = 2 and s.reason <> 'follows_you'
      or s.sort_tier = 3 and s.reason <> 'popular'),
  0::bigint,
  'reason and sort_tier always agree');

select is(
  (select count(*) - count(distinct user_id) from public.get_follow_suggestions(null, null, null, 50)),
  0::bigint,
  'each account appears once, in its best tier');


-- ===========================================================================
-- B. Exclusions, each with its lift.
-- ===========================================================================
select ok(not pg_temp.suggested('V'),           'never myself (B follows me, so I am a friend of a friend)');
select ok(not pg_temp.suggested('A'),           'never someone I follow');
select ok(not pg_temp.suggested('E_follow'),    'never someone I follow, even with a mutual');
select ok(not pg_temp.suggested('E_block'),     'never someone I blocked');
select ok(not pg_temp.suggested('E_blockrev'),  'never someone who blocked me');
select ok(not pg_temp.suggested('E_pending'),   'never an account pending deletion');
select ok(not pg_temp.suggested('E_erased'),    'never an erased account');
select ok(not pg_temp.suggested('E_optout'),    'never an account that opted out');
select ok(not pg_temp.suggested('E_noonboard'), 'never an account that has not finished onboarding');
select ok(not pg_temp.suggested('E_dismissed'), 'never an account I dismissed (its lift is section F''s undo)');
select ok(not pg_temp.suggested('Mb'),          'never the block-paired mutual itself');

-- Lifts, as postgres, each reverted before the next.
reset role;
delete from public.blocks where blocked_id = (select id from u where k = 'E_block');
select tests.authenticate_as('e48e0000-0000-0000-0000-000000000001');
select ok(pg_temp.suggested('E_block'), 'CONTROL: unblocked, E_block is suggested');

reset role;
delete from public.blocks where blocker_id = (select id from u where k = 'E_blockrev');
select tests.authenticate_as('e48e0000-0000-0000-0000-000000000001');
select ok(pg_temp.suggested('E_blockrev'), 'CONTROL: unblocked, E_blockrev is suggested');

reset role;
update public.profiles set deleted_at = null where id = (select id from u where k = 'E_pending');
select tests.authenticate_as('e48e0000-0000-0000-0000-000000000001');
select ok(pg_temp.suggested('E_pending'), 'CONTROL: deletion cancelled, E_pending is suggested');

reset role;
update public.profiles set suggest_account = true where id = (select id from u where k = 'E_optout');
select tests.authenticate_as('e48e0000-0000-0000-0000-000000000001');
select ok(pg_temp.suggested('E_optout'), 'CONTROL: opted back in, E_optout is suggested');

reset role;
update public.profiles set onboarding_completed_at = now() where id = (select id from u where k = 'E_noonboard');
select tests.authenticate_as('e48e0000-0000-0000-0000-000000000001');
select ok(pg_temp.suggested('E_noonboard'), 'CONTROL: onboarded, E_noonboard is suggested');

-- Restore the exclusions for the rest of the file.
reset role;
insert into public.blocks (blocker_id, blocked_id) values
  ((select id from u where k = 'V'), (select id from u where k = 'E_block')),
  ((select id from u where k = 'E_blockrev'), (select id from u where k = 'V'));
update public.profiles set deleted_at = now() where id = (select id from u where k = 'E_pending');
update public.profiles set suggest_account = false where id = (select id from u where k = 'E_optout');
update public.profiles set onboarding_completed_at = null where id = (select id from u where k = 'E_noonboard');
-- The block purged A's edges to them; put them back so the lifts above still
-- mean something if this file is extended.
insert into public.follows (follower_id, followee_id) values
  ((select id from u where k = 'A'), (select id from u where k = 'E_block')),
  ((select id from u where k = 'A'), (select id from u where k = 'E_blockrev'))
on conflict do nothing;


-- ===========================================================================
-- C. Mutual names.
-- ===========================================================================
select tests.authenticate_as('e48e0000-0000-0000-0000-000000000001');

select is(
  (select mutual_count from public.get_follow_suggestions(null, null, null, 50) where user_id = (select id from u where k = 'X')),
  2,
  'X''s count leaves out the block-paired mutual (Mb) and the pending one (Mp)');

select ok(
  not exists (select 1 from public.get_follow_suggestions(null, null, null, 50) s
              where 'p48_005' = any(s.mutual_usernames) or 'p48_006' = any(s.mutual_usernames)),
  'no label anywhere names the block-paired or the pending mutual');

select is(
  (select reason from public.get_follow_suggestions(null, null, null, 50) where user_id = (select id from u where k = 'Q')),
  'popular',
  'Q, reachable only through the block-paired mutual, is not a mutuals suggestion');

-- CONTROL: the planted edge is really there, so the filter is what hides it.
reset role;
select ok(
  exists (select 1 from public.follows where follower_id = (select id from u where k = 'V')
                                         and followee_id = (select id from u where k = 'Mb')),
  'CONTROL: V -> Mb exists; only the block term keeps Mb out of X''s label');
update public.profiles set deleted_at = null where id = (select id from u where k = 'Mp');
select tests.authenticate_as('e48e0000-0000-0000-0000-000000000001');
select is(
  (select mutual_count from public.get_follow_suggestions(null, null, null, 50) where user_id = (select id from u where k = 'X')),
  3,
  'CONTROL: with Mp restored, X counts 3 mutuals');
reset role;
update public.profiles set deleted_at = now() where id = (select id from u where k = 'Mp');


-- ===========================================================================
-- D. Access.
-- ===========================================================================
select is(
  pg_get_function_identity_arguments('public.get_follow_suggestions(smallint, bigint, uuid, integer)'::regprocedure),
  'p_cursor_tier smallint, p_cursor_rank bigint, p_cursor_id uuid, p_limit integer',
  'no user argument: the only uuid is the paging cursor');

select tests.authenticate_as('e48e0000-0000-0000-0000-000000000002'); -- A
select ok(pg_temp.suggested('V'), 'the same call as A answers A''s question: V, via Y');
select ok(not pg_temp.suggested('Y'), 'and not V''s: A already follows Y');

-- A cursor naming someone else's position is just a position.
select lives_ok(
  $$ select * from public.get_follow_suggestions(1::smallint, 0::bigint, 'e48e0000-0000-0000-0000-000000000001'::uuid, 20) $$,
  'an arbitrary cursor is harmless');

select tests.clear_authentication();
select throws_ok(
  $$ select * from public.get_follow_suggestions() $$,
  '42501', null, 'signed out: refused');
select throws_ok(
  $$ select public.dismiss_follow_suggestion('e48e0000-0000-0000-0000-0000000000f9') $$,
  '42501', null, 'signed out: dismiss refused');
select throws_ok(
  $$ select public.undismiss_follow_suggestion('e48e0000-0000-0000-0000-0000000000f9') $$,
  '42501', null, 'signed out: undo refused');

reset role;
select ok(
  not has_function_privilege('anon', 'public.get_follow_suggestions(smallint, bigint, uuid, integer)', 'execute'),
  'anon holds no EXECUTE on get_follow_suggestions');


-- ===========================================================================
-- E. Paging.
-- ===========================================================================
create function pg_temp.walk(p_size int) returns setof uuid language plpgsql as $$
declare
  t smallint; r bigint; i uuid; rec record; n int;
begin
  loop
    n := 0;
    for rec in select * from public.get_follow_suggestions(t, r, i, p_size) loop
      n := n + 1;
      t := rec.sort_tier; r := rec.sort_rank; i := rec.user_id;
      return next rec.user_id;
    end loop;
    exit when n < p_size;
  end loop;
end;
$$;
grant execute on function pg_temp.walk(int) to authenticated;

select tests.authenticate_as('e48e0000-0000-0000-0000-000000000001');

select is(
  array(select pg_temp.walk(2)),
  array(select user_id from public.get_follow_suggestions(null, null, null, 50)),
  'walking pages of 2 yields exactly the single-page list, in order, nothing skipped or repeated');

select cmp_ok(
  (select count(*) from public.get_follow_suggestions(null, null, null, 50)), '>', 2::bigint,
  'CONTROL: the list is longer than a page, so the walk crossed page boundaries');

select is((select count(*) from public.get_follow_suggestions(null, null, null, 0)), 1::bigint,
  'p_limit below 1 is clamped to 1');
select is((select count(*) from public.get_follow_suggestions(null, null, null, 1000)) <= 50, true,
  'p_limit above 50 is clamped to 50');


-- ===========================================================================
-- F. Dismissals.
-- ===========================================================================
select lives_ok($$ select public.dismiss_follow_suggestion('e48e0000-0000-0000-0000-0000000000f9') $$,
  'V dismisses X');
select ok(not pg_temp.suggested('X'), 'and X is no longer suggested');
select lives_ok($$ select public.dismiss_follow_suggestion('e48e0000-0000-0000-0000-0000000000f9') $$,
  'dismissing twice is a no-op');
select lives_ok($$ select public.dismiss_follow_suggestion('e48e0000-0000-0000-0000-00000000dead') $$,
  'an unknown id is a silent no-op');
select throws_ok($$ select public.dismiss_follow_suggestion('e48e0000-0000-0000-0000-000000000001') $$,
  '22023', 'cannot dismiss this account', 'dismissing yourself is refused');
select is(
  array(select dismissed_id from public.follow_suggestion_dismissals order by 1),
  array['e48e0000-0000-0000-0000-000000000026'::uuid, 'e48e0000-0000-0000-0000-0000000000f9'::uuid],
  'V reads exactly its two rows (fixture + X): the repeat and the unknown id stored nothing');

select throws_ok(
  $$ insert into public.follow_suggestion_dismissals (user_id, dismissed_id)
     values ('e48e0000-0000-0000-0000-000000000001', 'e48e0000-0000-0000-0000-0000000000f8') $$,
  '42501', null, 'no direct INSERT');
select throws_ok(
  $$ delete from public.follow_suggestion_dismissals $$,
  '42501', null, 'no direct DELETE');

-- Another user: cannot see V's row, and cannot undo it.
select tests.authenticate_as('e48e0000-0000-0000-0000-000000000002'); -- A
select is_empty($$ select 1 from public.follow_suggestion_dismissals $$,
  'A cannot read V''s dismissal');
select lives_ok($$ select public.undismiss_follow_suggestion('e48e0000-0000-0000-0000-0000000000f9') $$,
  'A''s undo of the same account runs');
reset role;
select is(
  (select count(*) from public.follow_suggestion_dismissals
   where user_id = 'e48e0000-0000-0000-0000-000000000001'
     and dismissed_id = 'e48e0000-0000-0000-0000-0000000000f9'),
  1::bigint,
  'and leaves V''s dismissal in place: undo is only ever your own');

select tests.authenticate_as('e48e0000-0000-0000-0000-000000000001'); -- V
select lives_ok($$ select public.undismiss_follow_suggestion('e48e0000-0000-0000-0000-0000000000f9') $$,
  'V undoes its own dismissal');
select ok(pg_temp.suggested('X'), 'and X is suggested again');


-- ===========================================================================
-- G. The setting.
-- ===========================================================================
select is((select suggest_account from public.get_my_settings()), true,
  'get_my_settings returns suggest_account, default on');
select lives_ok(
  $$ update public.profiles set suggest_account = false where id = 'e48e0000-0000-0000-0000-000000000001' $$,
  'the owner turns it off through the UPDATE allow-list');
select is((select suggest_account from public.get_my_settings()), false, 'and reads it back');
select ok(pg_temp.suggested('X'), 'their own opt-out does not change what THEY see');

select tests.authenticate_as('e48e0000-0000-0000-0000-000000000002'); -- A
select ok(not pg_temp.suggested('V'), 'enforced on the server: V is no longer suggested to A');
select throws_ok(
  $$ select suggest_account from public.profiles where id = 'e48e0000-0000-0000-0000-000000000001' $$,
  '42501', null, 'and A cannot read V''s setting off the table');


-- ===========================================================================
-- H. Export and erasure.
-- ===========================================================================
select tests.authenticate_as('e48e0000-0000-0000-0000-000000000030'); -- D
select public.dismiss_follow_suggestion('e48e0000-0000-0000-0000-0000000000d2');
select tests.authenticate_as('e48e0000-0000-0000-0000-000000000001'); -- V
select public.dismiss_follow_suggestion('e48e0000-0000-0000-0000-000000000030');

select is(
  (select jsonb_path_query_array(public.export_account_data(), '$.follow_suggestion_dismissals[*].user_id')),
  '["e48e0000-0000-0000-0000-000000000026", "e48e0000-0000-0000-0000-000000000030"]'::jsonb,
  'the export lists the accounts the caller dismissed');
select is(
  public.export_account_data() -> 'profile' ->> 'suggest_account',
  'false',
  'and carries suggest_account');

reset role;
update public.profiles set deleted_at = now() - interval '31 days' where id = 'e48e0000-0000-0000-0000-000000000030';
select lives_ok(
  $$ select public.complete_account_erasure('e48e0000-0000-0000-0000-000000000030') $$,
  'erasure runs for an account with dismissals on both sides');
select is(
  (select count(*) from public.follow_suggestion_dismissals
   where user_id = 'e48e0000-0000-0000-0000-000000000030'
      or dismissed_id = 'e48e0000-0000-0000-0000-000000000030'),
  0::bigint,
  'erasure deletes the dismissals the account made and the ones naming it');

select * from finish();
rollback;
