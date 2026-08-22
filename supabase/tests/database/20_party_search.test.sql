-- Phase 14, piece B: party search over title and area.
--
-- Same three levels and two controls as 19_profile_search.test.sql, because the
-- regression is the same: rewriting the prefix range as LIKE/ILIKE, or
-- "simplifying" `~>=~` to `>=`. Both return CORRECT ROWS and both silently stop
-- using the index.
--
-- Two things are new here and both earned their place by failing first:
--
--   * The doubled-letter collapse added to search_normalize() in this
--     migration shipped as a SILENT NO-OP the first time -- the `\1`
--     backreference was eaten by an escaping layer, so the regex became
--     `(.)<SOH>+` and matched nothing. Nothing errored. Every existing
--     assertion still passed, because none of them tested a doubled letter.
--     Section 1 tests it directly.
--   * Tokens live in a side table maintained by a TRIGGER, not a generated
--     column, so unlike piece A they genuinely can drift. Section 8 recomputes
--     the entire table and compares.
--
-- Personas (seed.sql): host 1111, invitee 2222, friend_not_invited 3333,
-- stranger 4444, blocked_user 5555, second_host 6666.
begin;
set search_path to public, extensions;
select plan(51);


-- ============================================================
-- 1. What this migration ADDED to search_normalize
--
-- The two gaps that real seeded Greek areas exposed, and the no-op that hid
-- between them.
-- ============================================================

select is(public.search_normalize('aaa'), 'a',
  'THE NO-OP GUARD: a run of repeated characters collapses. This is the '
  'assertion that would have caught the \1 backreference being eaten -- the '
  'regex became a no-op, nothing errored, and every other test still passed');

select is(public.search_normalize('Ψυρρή'), public.search_normalize('Psiri'),
  'Ψυρρή = Psiri -- doubled rho vs single r, both real spellings of one place');
select is(public.search_normalize('Εξάρχεια'), public.search_normalize('Exarcheia'),
  'Εξάρχεια = Exarcheia -- Latin ei folds like Greek ει already did');

-- The pairs piece A shipped with must still hold: this migration changed a
-- MERGED function, and these are what say it did not break what was there.
select is(public.search_normalize('ΣΥΝΤΑΓΜΑ'), public.search_normalize('syntagma'),
  'and the piece A pairs still hold -- ντ inside a word is still n+t');
select is(public.search_normalize('Νύχτα'), public.search_normalize('nyxta'),
  'Νύχτα = nyxta still');
select is(public.search_normalize('Ταράτσα!! 2026'), 'taratsa2026',
  'digits still survive and punctuation still does not');

-- A limitation recorded as a fact rather than chased. `Piraeus` is an English
-- exonym, not a transliteration of Πειραιάς, and no character mapping bridges
-- one. If this ever starts passing, somebody has added an alias table and the
-- rest of this file needs re-reading.
select isnt(public.search_normalize('Πειραιάς'), public.search_normalize('Piraeus'),
  'KNOWN LIMITATION: Πειραιάς does not match Piraeus -- that is an exonym, not '
  'greeklish, and transliteration cannot reach it');


-- ============================================================
-- 2. Tokenization -- the reason parties need a side table at all
-- ============================================================

select ok(
  'warehouse' = any (public.search_tokens('Psiri Warehouse Rave')),
  'a title is findable by its SECOND word -- the whole point of tokenizing'
);
select ok(
  'psiri' = any (public.search_tokens('Psiri Warehouse Rave')),
  'and by its first'
);
select is(
  public.search_tokens('  ,,,  '), array[]::text[],
  'punctuation-only input yields no tokens rather than one empty one'
);
select is(
  public.search_tokens(null), array[]::text[],
  'and null yields none rather than erroring'
);
select ok(
  public.search_normalize('Κουκάκι') = any (public.search_tokens('Ταράτσα στο Κουκάκι')),
  'Greek is split on the same expression -- [:alnum:] matches it'
);


-- ============================================================
-- 3. party_is_past -- ONE definition, and the disagreement with the map is
-- deliberate
-- ============================================================

select is(
  public.party_is_past('2026-05-01 20:00+00', '2026-05-02 04:00+00', '2026-05-02 03:00+00'),
  false,
  'a party with a stated end is not past before it');
select is(
  public.party_is_past('2026-05-01 20:00+00', '2026-05-02 04:00+00', '2026-05-02 05:00+00'),
  true,
  'and is past after it -- both sides of the boundary, assertable because '
  'p_now is a parameter rather than a call to now()');

-- The null-ends_at case, which is the only one the grace period touches.
select is(
  public.party_is_past('2026-05-01 20:00+00', null, '2026-05-02 01:00+00'),
  false,
  'with no stated end, a party is still running inside the 6h grace');
select is(
  public.party_is_past('2026-05-01 20:00+00', null, '2026-05-02 03:00+00'),
  true,
  'and past outside it');

-- The documented sequencing state. If somebody makes the map filter on this,
-- they have taken a product decision and this assertion is where they find out
-- it was one.
select is_empty(
  $$ select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'get_parties_near_user'
       and p.prosrc like '%party_is_past%' $$,
  'the MAP does not use party_is_past -- search and the map therefore disagree '
  'about a null-ends_at party, which is expected (gotcha 21) and not a bug'
);


-- ============================================================
-- 4. Fixtures
-- ============================================================

reset role;

-- A past party with NO stated end, which the seed does not contain: every past
-- party there sets ends_at, so the grace-period branch is otherwise untested.
insert into public.parties (id, host_id, title, area, location, starts_at, ends_at, is_private, status)
values ('eeeeeeee-0000-0000-0000-000000000001',
        '11111111-1111-1111-1111-111111111111',
        'Ξεχασμένο Ρετιρέ', 'Κουκάκι',
        st_point(23.7349, 37.9756)::geography,
        now() - interval '20 days', null, false, 'published');

-- A draft, to prove status filters.
insert into public.parties (id, host_id, title, area, location, starts_at, ends_at, is_private, status)
values ('eeeeeeee-0000-0000-0000-000000000002',
        '11111111-1111-1111-1111-111111111111',
        'Ανακοίνωση Σύντομα', 'Κουκάκι',
        st_point(23.7349, 37.9756)::geography,
        now() + interval '20 days', now() + interval '20 days 6 hours', false, 'draft');

-- A private party of second_host, with a distinctive word.
insert into public.parties (id, host_id, title, area, location, starts_at, ends_at, is_private, status)
values ('eeeeeeee-0000-0000-0000-000000000003',
        '66666666-6666-6666-6666-666666666666',
        'Μυστικό Zeppelin Loft', 'Γκάζι',
        st_point(23.7107, 37.9779)::geography,
        now() + interval '5 days', now() + interval '5 days 6 hours', true, 'published');
insert into public.invitations (party_id, guest_id)
values ('eeeeeeee-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222');


-- ============================================================
-- 5. Behaviour, including all three product decisions
-- ============================================================

select tests.authenticate_as('44444444-4444-4444-4444-444444444444'); -- stranger

select isnt_empty(
  $$ select 1 from public.search_parties('warehouse') $$,
  'a party is found by a word that is not the first in its title'
);

select isnt_empty(
  $$ select 1 from public.search_parties('psirri') $$,
  'greeklish finds a party whose AREA is written in Greek'
);

select is_empty(
  $$ select 1 from public.search_parties('arehouse') $$,
  'a mid-word substring is NOT found -- prefix only, deliberately'
);

select is_empty(
  $$ select 1 from public.search_parties('') $$,
  'an empty query returns nothing rather than everything'
);

-- DECISION: status. Drafts are out.
select is_empty(
  $$ select 1 from public.search_parties('anakinosi') $$,
  'a DRAFT party is never returned'
);
select isnt_empty(
  $$ select 1 from public.parties where id = 'eeeeeeee-0000-0000-0000-000000000002' $$,
  'control: the stranger can still SEE that draft through the row policy, so '
  'the exclusion above is the RPC filtering status and not RLS hiding it'
);

-- DECISION: map_visibility does NOT filter search. This is the line somebody
-- will "fix" later.
reset role;
update public.profiles set map_visibility = 'private'
where id = '11111111-1111-1111-1111-111111111111';
select tests.authenticate_as('44444444-4444-4444-4444-444444444444');

select isnt_empty(
  $$ select 1 from public.search_parties('xexasmeno') $$,
  'THE DECISION: a party whose host set map_visibility = private is STILL '
  'findable by name. That column answers "do I want to be a pin", not "do I '
  'want to be unfindable" -- being invited somewhere you cannot locate is the '
  'failure this prevents'
);
reset role;
update public.profiles set map_visibility = 'public'
where id = '11111111-1111-1111-1111-111111111111';

-- DECISION: past parties are returned, in a second group.
select tests.authenticate_as('44444444-4444-4444-4444-444444444444');
select is(
  (select is_past from public.search_parties('xexasmeno')),
  true,
  'a past party with NO stated end is grouped as past, via the grace period'
);
select is_empty(
  $$ with r as (select is_past, row_number() over () as n from public.search_parties('rooftop'))
     select 1 from r a join r b on a.n < b.n
     where a.is_past and not b.is_past $$,
  'and every upcoming result sorts before every past one'
);
select isnt_empty(
  $$ select 1 from public.search_parties('rooftop') where not is_past $$,
  'control: that query really does return both groups'
);
select isnt_empty(
  $$ select 1 from public.search_parties('rooftop') where is_past $$,
  'control: both groups, second half'
);

-- Privacy is the row policies' job, not the RPC's.
select is_empty(
  $$ select 1 from public.search_parties('zeppelin') $$,
  'a stranger cannot find a private party by name'
);
select tests.authenticate_as('22222222-2222-2222-2222-222222222222');
select isnt_empty(
  $$ select 1 from public.search_parties('zeppelin') $$,
  'but an invitee can -- otherwise you are invited somewhere you cannot find'
);


-- ============================================================
-- 6. LEVEL 1 -- structural tripwire, comments stripped first
--
-- The body explains why LIKE is wrong, so a naive '%like%' check fires on the
-- explanation. Same trap as the '%bbox%' guard in 18 and the same fix as 19.
-- ============================================================

reset role;
create temp view search_parties_code as
select regexp_replace(p.prosrc, '--[^' || chr(10) || ']*', '', 'g') as src
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'search_parties';

select isnt_empty(
  $$ select 1 from search_parties_code where src like '%~>=~%' and src like '%~<~%' $$,
  'LEVEL 1: search_parties still uses ~>=~ / ~<~'
);
select is_empty(
  $$ select 1 from search_parties_code
     where src ~* '\milike\M' or src like '%~~*%' or src ~* '\mlike\M' $$,
  'LEVEL 1: and contains no LIKE or ILIKE'
);


-- ============================================================
-- 7. LEVEL 3 -- the range really is a prefix match, plus CONTROL 1
--
-- Corpus built around 'z', where succ() is at its edge. Ordinary party names
-- never reach it.
-- ============================================================

insert into public.parties (id, host_id, title, area, location, starts_at, ends_at, status)
select ('eeeeeeee-0000-0000-0000-1' || lpad(g::text, 11, '0'))::uuid,
       '11111111-1111-1111-1111-111111111111',
       t, null,
       st_point(23.7349, 37.9756)::geography,
       now() + interval '3 days', now() + interval '3 days 6 hours', 'published'
from (values (1,'z'),(2,'zz'),(3,'zzz'),(4,'zza'),(5,'az'),(6,'azz'),
             (7,'a'),(8,'ab'),(9,'zebra'),(10,'zzebra'),(11,'a9z'),(12,'9a'))
     as v(g, t);

create temp table probe_prefix (p text);
insert into probe_prefix values
  ('a'), ('z'), ('zz'), ('zzz'), ('az'), ('ab'), ('9'), ('9a'),
  ('a9z'), ('zebra'), ('zzebra'), ('b'), ('zzzz');

select is_empty(
  $$ select pp.p, t.token
     from probe_prefix pp
     join public.party_search_tokens t
       on t.token ~>=~ pp.p and t.token ~<~ public.search_prefix_upper(pp.p)
     where t.token not like pp.p || '%' $$,
  'LEVEL 3a: the range admits nothing that is not a prefix match'
);

select is_empty(
  $$ select pp.p, t.token
     from probe_prefix pp
     join public.party_search_tokens t on t.token like pp.p || '%'
     where not (t.token ~>=~ pp.p and t.token ~<~ public.search_prefix_upper(pp.p)) $$,
  'LEVEL 3b: and drops nothing that IS one -- the direction that fails silently'
);

select isnt_empty(
  $$ select 1 from probe_prefix pp join public.party_search_tokens t
     on t.token like pp.p || '%' $$,
  'control: the corpus matches something, so 3a/3b are not vacuous'
);

select isnt_empty(
  $$ select pp.p, t.token
     from probe_prefix pp
     join public.party_search_tokens t on t.token like pp.p || '%'
     where not (
       t.token ~>=~ pp.p
       and t.token ~<~ (case
             when right(pp.p, 1) = 'z' then pp.p
             else left(pp.p, length(pp.p) - 1) || chr(ascii(right(pp.p, 1)) + 1)
           end)
     ) $$,
  'CONTROL 1: a succ() that refuses to increment past z DOES drop rows, so '
  'LEVEL 3b is not passing by accident'
);


-- ============================================================
-- 8. LEVEL 2 and CONTROL 2 -- the mechanism
-- ============================================================

analyze public.party_search_tokens;
set local enable_seqscan = off;
select tests.authenticate_as('44444444-4444-4444-4444-444444444444');

create temp table scan_marks (label text, n bigint);
insert into scan_marks values ('start',
  pg_stat_get_xact_numscans('public.party_search_tokens_token_idx'::regclass));

select count(*) from public.search_parties('zeb');
insert into scan_marks values ('after_rpc',
  pg_stat_get_xact_numscans('public.party_search_tokens_token_idx'::regclass));

select cmp_ok(
  (select n from scan_marks where label = 'after_rpc'), '>',
  (select n from scan_marks where label = 'start'),
  'LEVEL 2: search_parties actually SCANS party_search_tokens_token_idx'
);

select count(*) from public.party_search_tokens t where t.token like 'zeb%';
insert into scan_marks values ('after_like',
  pg_stat_get_xact_numscans('public.party_search_tokens_token_idx'::regclass));
select is(
  (select n from scan_marks where label = 'after_like'),
  (select n from scan_marks where label = 'after_rpc'),
  'CONTROL 2a: `LIKE ''zeb%''` does NOT scan the index -- textlike is '
  'non-leakproof, so it never sorts ahead of the policy and no index qual forms'
);

select count(*) from public.party_search_tokens t
where t.token >= 'zeb' and t.token < 'zec';
insert into scan_marks values ('after_naive',
  pg_stat_get_xact_numscans('public.party_search_tokens_token_idx'::regclass));
select is(
  (select n from scan_marks where label = 'after_naive'),
  (select n from scan_marks where label = 'after_like'),
  'CONTROL 2b: the naive `>= / <` range does NOT scan it either -- right '
  'answers, leakproof, promoted, and the wrong operator class'
);

set local enable_seqscan = on;


-- ============================================================
-- 9. The tokens stay in step -- the assertion that makes a TRIGGER acceptable
--
-- Piece A used a generated column, which cannot drift. This can, so it is
-- checked rather than trusted.
-- ============================================================

reset role;

-- Recompute the whole table and compare, both directions.
select is_empty(
  $$ select p.id
     from public.parties p
     cross join lateral unnest(
       public.search_tokens(p.title) || public.search_tokens(coalesce(p.area, ''))
     ) as expected(tok)
     where not exists (
       select 1 from public.party_search_tokens t
       where t.party_id = p.id and t.token = expected.tok
     ) $$,
  'every token the tokenizer produces today is in the table'
);
select is_empty(
  $$ select t.party_id, t.token
     from public.party_search_tokens t
     join public.parties p on p.id = t.party_id
     where t.token <> all (
       public.search_tokens(p.title) || public.search_tokens(coalesce(p.area, ''))
     ) $$,
  'and the table holds no token the tokenizer would not produce -- this is the '
  'direction that catches a rename leaving the OLD words behind'
);

-- The rename case directly, because it is the one a trigger gets wrong.
update public.parties set title = 'Καινούριο Όνομα'
where id = 'eeeeeeee-0000-0000-0000-000000000001';
select is_empty(
  $$ select 1 from public.party_search_tokens
     where party_id = 'eeeeeeee-0000-0000-0000-000000000001'
       and token = 'xexasmeno' $$,
  'renaming a party removes the tokens of its OLD title'
);
select isnt_empty(
  $$ select 1 from public.party_search_tokens
     where party_id = 'eeeeeeee-0000-0000-0000-000000000001'
       and token = public.search_normalize('Καινούριο') $$,
  'and adds the tokens of the new one'
);

delete from public.parties where id = 'eeeeeeee-0000-0000-0000-000000000001';
select is_empty(
  $$ select 1 from public.party_search_tokens
     where party_id = 'eeeeeeee-0000-0000-0000-000000000001' $$,
  'deleting a party cascades its tokens away'
);


-- ============================================================
-- 10. The table, the index, and the grants
-- ============================================================

select is(
  (select opcname from pg_opclass oc
   join pg_index i on i.indclass[0] = oc.oid
   where i.indexrelid = 'public.party_search_tokens_token_idx'::regclass),
  'text_pattern_ops',
  'the token index is text_pattern_ops -- the default would serve `>=` and not '
  '`~>=~`, which is the reverse of what is needed'
);

select is(
  (select relrowsecurity from pg_class where oid = 'public.party_search_tokens'::regclass),
  true,
  'RLS is on -- tokens spell out the titles of private parties'
);

select isnt_empty(
  $$ select 1 from pg_policy
     where polrelid = 'public.party_search_tokens'::regclass
       and pg_get_expr(polqual, polrelid) like '%can_access_party%' $$,
  'and its policy CALLS can_access_party rather than restating party visibility'
);

-- gotcha 9: the default ACL hands anon TRUNCATE on every new table.
select is_empty(
  $$ select privilege_type from information_schema.role_table_grants
     where table_schema = 'public' and table_name = 'party_search_tokens'
       and grantee = 'anon' $$,
  'anon holds no privilege at all on the token table, not even the default '
  'TRUNCATE that RLS does not mediate'
);
-- string_agg rather than results_eq: comparing information_schema's
-- collatable domains row by row asks Postgres to pick a collation it cannot.
select is(
  (select string_agg(privilege_type, ',' order by privilege_type)
   from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'party_search_tokens'
     and grantee = 'authenticated'),
  'SELECT',
  'and authenticated holds SELECT and nothing else -- the trigger writes it'
);

select is(
  (select prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'search_parties'),
  false,
  'search_parties is SECURITY INVOKER -- a definer search is an enumeration '
  'oracle, and the row policies are what apply visibility'
);

select is_empty(
  $$ select 1 from information_schema.role_routine_grants
     where routine_schema = 'public' and routine_name = 'search_parties'
       and grantee = 'anon' $$,
  'anon holds no EXECUTE on search_parties'
);

select * from finish();
rollback;
