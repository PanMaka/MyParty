-- Phase 14, piece A: profile search.
--
-- The regression this file exists to survive is somebody rewriting the prefix
-- range as LIKE or ILIKE, or "simplifying" `~>=~` to `>=`. Both read as
-- tidying, both return CORRECT ROWS, and both silently stop using the index --
-- 0.035ms becomes 189ms at 10k rows, with nothing to see in the diff.
--
-- No single check catches that, so there are three levels and two controls:
--
--   Level 1  structural tripwire on the function source
--   Level 2  the mechanism, via pg_stat_get_xact_numscans on the index
--   Level 3  the range really is a prefix match, both directions
--   Control 1  a deliberately-wrong succ() MUST fail level 3
--   Control 2  neither LIKE nor the naive text_ops range reaches the index
--
-- Control 2 is the one that would have been missed. `>=` and `<` are leakproof
-- and ARE promoted past the policy, so they pass level 1 (not LIKE) and level 3
-- (the range is correct) while costing 466 buffers instead of 13. Only the
-- index-scan counter tells them apart.
--
-- Personas (seed.sql): host 1111, invitee 2222, friend_not_invited 3333,
-- stranger 4444, blocked_user 5555, second_host 6666.
begin;
set search_path to public, extensions;
select plan(46);


-- ============================================================
-- 1. The normalizer -- the Greek/greeklish pairs it claims to fold together
--
-- Every pair below must collapse to ONE key, or a user typing Latin cannot
-- find a party named in Greek, which is the entire reason transliteration is
-- here. These are the cases the migration header claims to cover; if a mapping
-- is retuned, this is the list that says what broke.
-- ============================================================

select is(public.search_normalize('Ταράτσα'), public.search_normalize('taratsa'),
  'Ταράτσα = taratsa');
select is(public.search_normalize('Τέχνο'), public.search_normalize('techno'),
  'Τέχνο = techno -- via χ->x and the Latin ch->x fold');
select is(public.search_normalize('Νύχτα'), public.search_normalize('nyxta'),
  'Νύχτα = nyxta -- via υ->i and Latin y->i');
select is(public.search_normalize('Θησείο'), public.search_normalize('thisio'),
  'Θησείο = thisio -- via θ->th and ει->i');
select is(public.search_normalize('Ψυρρή'), public.search_normalize('psirri'),
  'Ψυρρή = psirri');
select is(public.search_normalize('Εξάρχεια'), public.search_normalize('exarxia'),
  'Εξάρχεια = exarxia');
select is(public.search_normalize('Μπίρα'), public.search_normalize('bira'),
  'Μπίρα = bira -- μπ is a digraph at the START of a word');
select is(public.search_normalize('Γκάζι'), public.search_normalize('gazi'),
  'Γκάζι = gazi');

-- The case the first draft got wrong, and it is in the seed data. Inside a
-- word, ντ is two letters in different syllables (συν-ταγμα), not the digraph
-- that starts μπίρα. Getting this wrong turns Σύνταγμα into `sidagma`.
select is(public.search_normalize('ΣΥΝΤΑΓΜΑ'), public.search_normalize('syntagma'),
  'ΣΥΝΤΑΓΜΑ = syntagma -- ντ INSIDE a word is n+t, not d');
select is(public.search_normalize('Ολυμπία'), public.search_normalize('olympia'),
  'Ολυμπία = olympia -- and μπ inside a word is m+p, not b');

select is(public.search_normalize('Ταράτσα!! 2026'), 'taratsa2026',
  'digits survive, punctuation and spaces do not');
select is(public.search_normalize(null), '',
  'null normalizes to the empty string rather than null -- the RPC tests key <> ''''');

-- Final sigma, which only shows up at the end of a word and is the one
-- normalization nobody notices is missing until a search fails.
select is(public.search_normalize('Νύχτες'), public.search_normalize('Νύχτεσ'),
  'final sigma folds to sigma');


-- ============================================================
-- 2. LEVEL 1 -- structural tripwire
--
-- Cheap, catches the obvious rewrite, and proves nothing about the plan. It is
-- here because it names the mistake in the failure message, which the other
-- two levels cannot do.
-- ============================================================

-- COMMENTS ARE STRIPPED FIRST. The function body explains, in a comment, why
-- `like` and `>=` are the wrong operators -- and a naive '%like%' check fires
-- on that explanation instead of on a live reference. Same trap as the
-- '%bbox%' guard in 18_map_spatial_prefilter.
create temp view search_profiles_code as
select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') as src
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'search_profiles';

select isnt_empty(
  $$ select 1 from search_profiles_code
     where src like '%~>=~%' and src like '%~<~%' $$,
  'LEVEL 1: search_profiles still uses the pattern operators ~>=~ / ~<~'
);

select is_empty(
  $$ select 1 from search_profiles_code
     where src ~* '\milike\M' or src like '%~~*%' or src ~* '\mlike\M' $$,
  'LEVEL 1: and contains no LIKE or ILIKE -- neither can reach the index'
);


-- ============================================================
-- 3. Behaviour: what search actually returns
-- ============================================================

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select results_eq(
  $$ select username from public.search_profiles('host') $$,
  $$ values ('host'::text) $$,
  'an exact username is found'
);

select results_eq(
  $$ select username from public.search_profiles('nik') $$,
  $$ values ('nikos_p'::text) $$,
  'a prefix of a username is found'
);

select is_empty(
  $$ select username from public.search_profiles('ikos') $$,
  'a MID-WORD substring is NOT found -- prefix only, deliberately, and this is '
  'the reach that searchProfiles had and this does not'
);

select is_empty(
  $$ select 1 from public.search_profiles('') $$,
  'an empty query returns nothing rather than the whole table'
);
select is_empty(
  $$ select 1 from public.search_profiles('   ') $$,
  'and so does a query that normalizes to nothing'
);

select is_empty(
  $$ select 1 from public.search_profiles('stranger') $$,
  'the caller never finds themselves'
);


-- ============================================================
-- 4. Tombstones -- the profiles policy does not filter deleted_at, so the RPC
-- must, and it is not belt-and-braces
-- ============================================================

reset role;
update public.profiles
set deleted_at = now() - interval '31 days'
where id = '33333333-3333-3333-3333-333333333333';
select lives_ok(
  $$ select public.complete_account_erasure('33333333-3333-3333-3333-333333333333') $$,
  'erase friend_not_invited, so the tombstone below is a real one'
);

select tests.authenticate_as('44444444-4444-4444-4444-444444444444');

select is_empty(
  $$ select 1 from public.search_profiles('friend') $$,
  'an erased user is not findable by their ORIGINAL handle'
);

-- The reason the deleted_at filter is load-bearing rather than tidy: the scrub
-- renames every tombstone to deleted_<uuid>, so without it one query returns
-- the entire graveyard.
select is_empty(
  $$ select 1 from public.search_profiles('deleted') $$,
  'nor does searching `deleted` return the graveyard'
);

reset role;
select is_empty(
  $$ select 1 from public.profiles
     where id = '33333333-3333-3333-3333-333333333333'
       and username_search like '%friend%' $$,
  'THE GENERATED-COLUMN CLAIM: the scrub regenerated username_search, so the '
  'original handle is not left behind in a searchable column'
);

select isnt_empty(
  $$ select 1 from public.profiles where id = '33333333-3333-3333-3333-333333333333' $$,
  'control: the tombstone row itself still exists -- it must, or threads lose messages'
);


-- ============================================================
-- 5. Blocks -- still the row policy's job, not the RPC's
-- ============================================================

reset role;
insert into public.blocks (blocker_id, blocked_id)
values ('66666666-6666-6666-6666-666666666666', '44444444-4444-4444-4444-444444444444');

select tests.authenticate_as('44444444-4444-4444-4444-444444444444');
select is_empty(
  $$ select 1 from public.search_profiles('second') $$,
  'a user who blocked the caller is not in their search results -- via the row '
  'policy, with no block logic in the RPC'
);

select tests.authenticate_as('22222222-2222-2222-2222-222222222222');
select isnt_empty(
  $$ select 1 from public.search_profiles('second') $$,
  'control: and is still findable by somebody they did not block'
);


-- ============================================================
-- 6. LEVEL 3 -- the range really is a prefix match
--
-- The analogue of Phase 13's superset invariant. `[p, succ(p))` must equal
-- `{x : x starts with p}` EXACTLY. Too low and matching rows vanish with no
-- error at all.
--
-- The corpus is built to reach the boundary: usernames around 'z' (the largest
-- byte search_normalize can emit), digits, and single characters. A corpus of
-- ordinary names would never exercise succ() at its edge.
-- ============================================================

reset role;
insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        confirmation_token, recovery_token,
                        email_change_token_new, email_change)
select '00000000-0000-0000-0000-000000000000',
       ('cccccccc-0000-0000-0000-' || lpad(g::text, 12, '0'))::uuid,
       'authenticated', 'authenticated',
       'sc' || g || '@myparty.local', crypt('x', gen_salt('bf')),
       now(), now(), now(), '', '', '', ''
from generate_series(1, 12) g;

insert into public.profiles (id, username, onboarding_completed_at)
select ('cccccccc-0000-0000-0000-' || lpad(g::text, 12, '0'))::uuid, u, now()
from (values (1,'z'),(2,'zz'),(3,'zzz'),(4,'zza'),(5,'az'),(6,'azz'),
             (7,'a'),(8,'ab'),(9,'9a'),(10,'a9z'),(11,'zebra'),(12,'zzebra'))
     as v(g, u)
on conflict (id) do update set username = excluded.username;

create temp table probe_prefix (p text);
insert into probe_prefix values
  ('a'), ('z'), ('zz'), ('zzz'), ('az'), ('ab'), ('9'), ('9a'),
  ('a9z'), ('zebra'), ('zzebra'), ('b'), ('zzzz');

-- Direction 1: the range admits nothing the prefix does not.
select is_empty(
  $$ select pp.p, pr.username
     from probe_prefix pp
     join public.profiles pr
       on pr.username_search ~>=~ pp.p
      and pr.username_search ~<~ public.search_prefix_upper(pp.p)
     where pr.username_search not like pp.p || '%' $$,
  'LEVEL 3a: the range admits nothing that is not a prefix match'
);

-- Direction 2: and drops nothing the prefix admits. THIS is the one that goes
-- wrong silently.
select is_empty(
  $$ select pp.p, pr.username
     from probe_prefix pp
     join public.profiles pr
       on pr.username_search like pp.p || '%'
     where not (pr.username_search ~>=~ pp.p
                and pr.username_search ~<~ public.search_prefix_upper(pp.p)) $$,
  'LEVEL 3b: and drops nothing that IS a prefix match'
);

select isnt_empty(
  $$ select 1 from probe_prefix pp join public.profiles pr
     on pr.username_search like pp.p || '%' $$,
  'control: the corpus actually matches something, so 3a/3b are not vacuous'
);

-- ---------- CONTROL 1: a deliberately wrong succ() must FAIL level 3 ----------
--
-- Not `p` unchanged, which would be too easy to spot: this is the bug somebody
-- would really write -- refusing to increment past 'z' because chr(123) "looks
-- wrong". It is correct for every prefix that does not end in z, which is most
-- of them, and silently wrong for the rest.
select isnt_empty(
  $$ select pp.p, pr.username
     from probe_prefix pp
     join public.profiles pr
       on pr.username_search like pp.p || '%'
     where not (
       pr.username_search ~>=~ pp.p
       and pr.username_search ~<~ (case
             when right(pp.p, 1) = 'z' then pp.p
             else left(pp.p, length(pp.p) - 1) || chr(ascii(right(pp.p, 1)) + 1)
           end)
     ) $$,
  'CONTROL 1: a succ() that refuses to increment past z DOES drop rows -- '
  'so LEVEL 3b is not passing by accident'
);


-- ============================================================
-- 7. LEVEL 2 and CONTROL 2 -- the mechanism
--
-- pg_stat_get_xact_numscans is transaction-local, which is the only reason a
-- plan fact is reachable from pgTAP at all (it is the same counter
-- explain_policy_pushdown.sh uses).
--
-- enable_seqscan = off so this discriminates at fixture size. That does not
-- weaken it: the question is whether the index is REACHABLE, not whether the
-- planner prefers it, and LIKE still seq-scans with seqscan disabled because it
-- has no other option.
-- ============================================================

reset role;
analyze public.profiles;
set local enable_seqscan = off;
select tests.authenticate_as('44444444-4444-4444-4444-444444444444');

create temp table scan_marks (label text, n bigint);

insert into scan_marks values ('start',
  pg_stat_get_xact_numscans('public.profiles_username_search_idx'::regclass));

select count(*) from public.search_profiles('zeb');
insert into scan_marks values ('after_rpc',
  pg_stat_get_xact_numscans('public.profiles_username_search_idx'::regclass));

select cmp_ok(
  (select n from scan_marks where label = 'after_rpc'),
  '>',
  (select n from scan_marks where label = 'start'),
  'LEVEL 2: calling search_profiles actually SCANS profiles_username_search_idx'
);

-- ---------- CONTROL 2a: LIKE does not reach the index ----------
select count(*) from public.profiles pr where pr.username_search like 'zeb%';
insert into scan_marks values ('after_like',
  pg_stat_get_xact_numscans('public.profiles_username_search_idx'::regclass));

select is(
  (select n from scan_marks where label = 'after_like'),
  (select n from scan_marks where label = 'after_rpc'),
  'CONTROL 2a: `LIKE ''zeb%''` does NOT scan the index -- textlike is '
  'non-leakproof, so the planner may not promote it past the row policy and '
  'the index qual is never formed'
);

-- ---------- CONTROL 2b: the naive text_ops range does not either ----------
--
-- The trap this exists for: `>=` and `<` ARE leakproof and ARE promoted past
-- the policy, so this returns correct rows and passes every other check in this
-- file. It just quietly costs 466 buffers instead of 13, because text_ops and
-- text_pattern_ops are different operator families and the index only serves
-- the second.
select count(*) from public.profiles pr
where pr.username_search >= 'zeb' and pr.username_search < 'zec';
insert into scan_marks values ('after_naive',
  pg_stat_get_xact_numscans('public.profiles_username_search_idx'::regclass));

select is(
  (select n from scan_marks where label = 'after_naive'),
  (select n from scan_marks where label = 'after_like'),
  'CONTROL 2b: the naive `>= / <` range does NOT scan the index either -- '
  'right answers, wrong operator class, no index'
);

set local enable_seqscan = on;


-- ============================================================
-- 8. Staleness -- the generated column agrees with the function TODAY
--
-- A GENERATED column is not recomputed when the function BODY changes, and
-- Postgres does not warn. This is the assertion that turns "somebody retuned
-- the greeklish map and half the table is stale" into a red test.
-- ============================================================

reset role;
select is_empty(
  $$ select id, username from public.profiles
     where username_search is distinct from public.search_normalize(username) $$,
  'every row''s username_search matches search_normalize(username) as it is '
  'defined right now'
);

select is(
  (select is_generated from information_schema.columns
   where table_schema = 'public' and table_name = 'profiles'
     and column_name = 'username_search'),
  'ALWAYS',
  'username_search is GENERATED ALWAYS -- not a trigger, not a plain column'
);

select throws_ok(
  $$ update public.profiles set username_search = 'forged'
     where id = '11111111-1111-1111-1111-111111111111' $$,
  '428C9',
  null,
  'and cannot be written, at any privilege level'
);

update public.profiles set username = 'Ταράτσα'
where id = '11111111-1111-1111-1111-111111111111';
select is(
  (select username_search from public.profiles
   where id = '11111111-1111-1111-1111-111111111111'),
  'taratsa',
  'renaming a user recomputes the search key -- including through '
  'transliteration'
);


-- ============================================================
-- 9. The index, the operators, and the grants
-- ============================================================

select has_index('public', 'profiles', 'profiles_username_search_idx',
  'the index the range reaches exists');

-- The operator class is the whole difference between control 2b and level 2.
select is(
  (select opcname from pg_opclass oc
   join pg_index i on i.indclass[0] = oc.oid
   where i.indexrelid = 'public.profiles_username_search_idx'::regclass),
  'text_pattern_ops',
  'and it is text_pattern_ops -- the default text_ops would serve `>=` and not '
  '`~>=~`, which is the reverse of what is needed'
);

-- If a Postgres upgrade ever changes this, the entire design is invalid and it
-- should arrive as a red test rather than as a slow app.
select is(
  (select bool_and(proleakproof) from pg_proc
   where proname in ('text_pattern_ge', 'text_pattern_lt')),
  true,
  'text_pattern_ge and text_pattern_lt are still LEAKPROOF -- the property the '
  'whole phase rests on'
);
select is(
  (select bool_or(proleakproof) from pg_proc
   where proname in ('texticlike', 'textlike')),
  false,
  'control: LIKE and ILIKE are still NOT leakproof, so the contrast is real'
);

select is(
  (select prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'search_profiles'),
  false,
  'search_profiles is SECURITY INVOKER -- a definer people-search is an '
  'enumeration oracle, and the row policy is what applies the block filter'
);

select is_empty(
  $$ select 1 from information_schema.role_routine_grants
     where routine_schema = 'public' and routine_name = 'search_profiles'
       and grantee = 'anon' $$,
  'anon holds no EXECUTE -- the self-exclusion term reads auth.uid()'
);
select isnt_empty(
  $$ select 1 from information_schema.role_routine_grants
     where routine_schema = 'public' and routine_name = 'search_profiles'
       and grantee = 'authenticated' $$,
  'control: authenticated does'
);

select * from finish();
rollback;
