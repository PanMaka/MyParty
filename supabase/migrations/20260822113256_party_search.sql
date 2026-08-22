-- Phase 14, piece B: party search over title and area.
--
-- Same mechanism as piece A (20260822110924) and the same two traps -- read
-- that header first. In one line: `ilike` and `like` are not leakproof, so they
-- can never be evaluated ahead of a row policy and can never reach an index;
-- `text_pattern_ge`/`text_pattern_lt` are, so a hand-written `~>=~` / `~<~`
-- range over a normalized column can.
--
-- What differs here is the shape. A username is one word, so piece A got a
-- scalar generated column. A title is not -- "Psiri Warehouse Rave" has to be
-- findable by `warehouse`, not only by `psiri` -- so this needs one row per
-- token, which a generated column cannot express. Hence a side table and a
-- trigger, and hence the staleness assertion in 20_party_search.test.sql is
-- doing more work here than it was in piece A.
--
-- NOTHING about visibility is reinvented. The token table's policy is a call to
-- can_access_party, which is the canonical rule (rule #4). The prefix range is
-- leakproof and sorts ahead of it, so the helper runs only on tokens that
-- already matched -- the same arrangement as Phase 13's bounding box.


-- ---------------------------------------------------------------------------
-- 0. A correction to search_normalize(), which piece B's real data exposed.
--
-- It is HERE, in this file, rather than in a migration of its own, because it
-- has to run BEFORE the token backfill at the end of section 4 -- otherwise
-- every token is built with the old rules and is stale the moment it is
-- written. Timestamps order migrations, so a later file could not have done it.
--
-- Two gaps, both found by running piece A's normalizer over the seeded Greek
-- areas rather than over invented examples:
--
--   Ψυρρή     -> psirri   but  Psiri     -> psiri     (doubled consonants)
--   Εξάρχεια  -> exarxeia but  Exarcheia -> exarxeia  vs Greek ει -> i
--
-- Both are the same shape: the Greek side already folds these and the Latin
-- side did not, so the two scripts did not meet. `Ψυρρή` and `Psiri` are the
-- same neighbourhood and both are in seed.sql -- a user typing either has to
-- find both, which is the entire reason transliteration is here.
--
-- Two additions, applied to BOTH scripts so they stay symmetric:
--   * Latin ei/oi -> i, matching what Greek ει/οι already did.
--   * runs of a repeated character collapse to one, so ρρ/rr, λλ/ll and
--     doubled vowels stop mattering. Greeklish is wildly inconsistent about
--     doubles and this removes the whole class.
--
-- Measured over 18 Greek/Latin pairs drawn from seed.sql: 17 match. The one
-- that does not is Πειραιάς / Piraeus, and it never will -- that is an English
-- EXONYM, not a transliteration, and no character mapping bridges it. Recorded
-- as a limitation rather than chased.
--
-- THE TRAP THIS DEMONSTRATES: `profiles.username_search` is GENERATED, and a
-- generated column is NOT recomputed when the function body changes. Postgres
-- does not warn. The ALTER below forces the rewrite, and
-- 19_profile_search.test.sql would have gone red without it -- which is what
-- that assertion is for.
create or replace function public.search_normalize(p_input text)
returns text
language sql
immutable
set search_path = ''
as $$
  with s0 as (select lower(coalesce(p_input, '')) as v),
       s1 as (select translate(v, 'άέήίόύώϊϋΐΰ', 'αεηιουωιυιυ') as v from s0),
       s2 as (select translate(v, 'ς', 'σ') as v from s1),
       s3 as (select regexp_replace(regexp_replace(regexp_replace(v,
                '\mμπ', 'b', 'g'), '\mντ', 'd', 'g'), '\mγκ', 'g', 'g') as v from s2),
       s4 as (select replace(replace(replace(replace(replace(replace(replace(v,
                'ου', 'ou'), 'ει', 'i'), 'οι', 'i'), 'γγ', 'g'),
                'τσ', 'ts'), 'τζ', 'tz'), 'αυ', 'av') as v from s3),
       s5 as (select replace(replace(replace(replace(v,
                'ευ', 'ev'), 'θ', 'th'), 'ψ', 'ps'), 'χ', 'x') as v from s4),
       s6 as (select translate(v,
                'αβγδεζηικλμνοπρστυφωξ',
                'avgdeziiklmnoprstifox') as v from s5),
       s7 as (select translate(replace(replace(v, 'ch', 'x'), 'ck', 'k'), 'y', 'i') as v from s6),
       -- NEW: the Latin twins of the Greek vowel digraphs folded in s4
       s8 as (select replace(replace(v, 'ei', 'i'), 'oi', 'i') as v from s7),
       -- NEW: collapse any run of a repeated character
       s9 as (select regexp_replace(v, '(.)\1+', '\1', 'g') as v from s8)
  select regexp_replace(v, '[^a-z0-9]', '', 'g') from s9;
$$;

-- Forces the rewrite of every existing username_search. Without this the
-- column keeps values computed by the OLD body, silently, forever.
alter table public.profiles
  alter column username_search
  set expression as (public.search_normalize(username));


-- ---------------------------------------------------------------------------
-- 1. Tokenization.
--
-- Split FIRST, normalize second. search_normalize() strips every separator, so
-- normalizing a whole title would collapse it to one long key and
-- "Psiri Warehouse Rave" would only ever be findable as `psiriwarehouserave`.
--
-- [:alnum:] matches Greek letters in this database (checked, not assumed), so
-- one split expression handles both scripts.
create function public.search_tokens(p_input text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select coalesce(array_agg(distinct s.t order by s.t), array[]::text[])
  from (
    select public.search_normalize(w) as t
    from unnest(regexp_split_to_array(coalesce(p_input, ''), '[^[:alnum:]]+')) as w
  ) s
  where s.t <> '';
$$;

comment on function public.search_tokens(text) is
  'Splits free text into normalized search tokens. Splits BEFORE normalizing, '
  'because search_normalize() removes separators -- normalizing first would '
  'yield one key per title instead of one per word. Shared by the '
  'party_search_tokens trigger and by nothing else yet.';


-- ---------------------------------------------------------------------------
-- 2. Past vs upcoming -- ONE definition, deliberately not applied to the map.
--
-- gotcha 21: `ends_at` is nullable and the host wizard does not require it, so
-- a finished party with no stated end is indistinguishable from a running one.
-- That is why the map still shows such a party forever, and why fixing it there
-- needs a product decision nobody has made.
--
-- Search needs the same distinction for a different purpose, and the cost of
-- being wrong is categorically lower:
--
--   The map asks "should this pin exist?" -- wrong one way leaves a dead party
--   on screen, wrong the other REMOVES A LIVE ONE. That asymmetry is the whole
--   reason gotcha 21 is still open.
--
--   Search asks "which group?" -- BOTH groups are shown, so being wrong moves a
--   row one section down. Cosmetic.
--
-- So the heuristic is affordable here and is not affordable there. It lives in
-- ONE function anyway, so that when the map does adopt it the two agree by
-- construction rather than by two people picking the same number.
--
-- UNTIL THEN SEARCH AND THE MAP VISIBLY DISAGREE about a null-ends_at party
-- that started days ago: search files it under past, the map still pins it.
-- That is expected, not a bug. It is a sequencing state -- one definition, one
-- surface has adopted it -- and the map's decision is now cheaper because the
-- number exists and has a name.
--
-- p_now is a parameter so the tests can assert both sides of the boundary
-- without sleeping, the same reason MapPartyPin.liveAt takes a clock instead of
-- reading one.
create function public.party_is_past(
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_now timestamptz default now()
)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- 6 hours, and it ONLY ever applies to a party with no stated end. Every
  -- past party in seed.sql sets ends_at, so the fixtures exercise the honest
  -- path and the null path has to be seeded on purpose.
  select coalesce(p_ends_at, p_starts_at + interval '6 hours') <= p_now;
$$;

comment on function public.party_is_past(timestamptz, timestamptz, timestamptz) is
  'The single definition of "this party is over". Search uses it to GROUP '
  'results; the map does not use it at all yet and still shows a null-ends_at '
  'party forever (gotcha 21). That disagreement is deliberate and temporary -- '
  'the map filtering on this is a product decision, and when it is made this '
  'is the function it should call rather than a second interval.';


-- ---------------------------------------------------------------------------
-- 3. The token table.
--
-- gotcha 9: revoke the default ACL before granting anything. Phase 10 swept
-- pg_default_acl so a new table should inherit nothing, but the revoke is the
-- assertion that does not depend on that having held.
create table public.party_search_tokens (
  party_id uuid not null references public.parties (id) on delete cascade,
  token text not null,
  primary key (party_id, token)
);

revoke all on public.party_search_tokens from anon, authenticated;
grant select on public.party_search_tokens to authenticated;

alter table public.party_search_tokens enable row level security;

-- A call to the canonical helper, not a copy of it. Tokens spell out the titles
-- of private parties, so this table needs exactly the visibility the party has.
create policy "Search tokens follow the party they describe"
on public.party_search_tokens
for select
using (public.can_access_party(party_id));

-- The index the prefix range reaches. text_pattern_ops, NOT the default:
-- `>=`/`<` are the text_ops family and cannot use this, which is measured as
-- control 2b in 19_profile_search.test.sql and repeated here.
--
-- The primary key already covers party_id, so this only needs token.
create index party_search_tokens_token_idx
  on public.party_search_tokens (token text_pattern_ops);

comment on table public.party_search_tokens is
  'One row per (party, normalized word) from title and area. Derived data, '
  'trigger-maintained -- never write it by hand. Its RLS policy calls '
  'can_access_party so private titles are not readable through it; the prefix '
  'range is leakproof and sorts ahead of that, so the helper only ever runs on '
  'tokens that already matched.';


-- ---------------------------------------------------------------------------
-- 4. Keeping it in step.
--
-- A trigger rather than a generated column because one party makes many rows.
-- That means it CAN drift, which a generated column cannot -- so
-- 20_party_search.test.sql recomputes the whole table and compares, and that
-- assertion is the thing that makes this shape safe.
create function public.sync_party_search_tokens()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.party_search_tokens where party_id = new.id;

  insert into public.party_search_tokens (party_id, token)
  select new.id, t
  from unnest(
    public.search_tokens(new.title) || public.search_tokens(coalesce(new.area, ''))
  ) as t
  on conflict on constraint party_search_tokens_pkey do nothing;

  return new;
end;
$$;

-- SECURITY DEFINER because the table grants `authenticated` SELECT only -- a
-- host inserting their own party must not need write privileges on derived
-- data. It decides nothing: it reads two columns of the row being written and
-- writes their tokens, with no branch on who the caller is.

create trigger parties_sync_search_tokens
after insert or update of title, area on public.parties
for each row
execute function public.sync_party_search_tokens();

-- Backfill. `update ... set title = title` would fire the trigger, but doing it
-- directly is clearer and does not rewrite every row's xmin.
insert into public.party_search_tokens (party_id, token)
select p.id, t
from public.parties p,
     unnest(public.search_tokens(p.title) || public.search_tokens(coalesce(p.area, ''))) as t
on conflict on constraint party_search_tokens_pkey do nothing;


-- ---------------------------------------------------------------------------
-- 5. The RPC.
--
-- SECURITY INVOKER, so both the token policy and the `parties` policy apply.
-- The definer alternative is faster and was rejected in §9 of
-- docs/phase-12-parties-policy-rewrite.md -- and search is the worst possible
-- feature to put behind one, because the caller supplies the predicate and
-- reads the answer back, which turns any WHERE-clause bug into an enumerable
-- directory.
--
-- DECISION: `map_visibility` does NOT filter search, and this is the line
-- somebody will "fix" later, so it is written down here as well as in the
-- brief. `profiles.map_visibility` answers "do I want to be a pin on the map",
-- NOT "do I want to be unfindable". A party the viewer is allowed to see must
-- be findable by name, or they are invited somewhere they cannot locate. If a
-- separate "hide me from search" control is ever wanted it gets its OWN column.
--
-- DECISION: `status` -- published only. Drafts are out.
--
-- WHAT THIS COSTS, measured at 10k parties as an authenticated viewer through
-- RLS, because the shape of the curve matters more than either number:
--
--   query        matches   exec      buffers
--   zeppelin           1    2.1ms        485
--   taratsa        ~3333    295ms     37,906
--
-- Cost is O(matches x policy), NOT O(table). That is what reaching the index
-- buys and it is the right shape -- but it means a BROAD prefix is slow, and
-- broad prefixes are exactly what a type-ahead sends after two characters.
-- Every candidate pays the parties policy and the profiles policy before the
-- ORDER BY can pick the top 20, and no index can order a set that RLS has not
-- filtered yet.
--
-- Shipped this way ON PURPOSE rather than capped. The obvious fix -- LIMIT the
-- `hits` CTE so the worst case is bounded -- turns "the 20 soonest matching
-- parties you can see" into "20 of the first N candidates, whichever those
-- happen to be", and for a viewer whose visible parties all sort late that
-- silently returns fewer results than exist. Losing results quietly is the
-- failure mode this whole phase has been avoiding, so the slow tail is the
-- better trade until somebody decides otherwise with the numbers in hand.
--
-- For comparison, the `ilike` this replaces is ~200ms at the same size AND
-- cannot match Greek from a Latin query at all, which is the actual feature.
create function public.search_parties(
  p_query text,
  p_limit integer default 20
)
returns table (
  party_id uuid,
  title text,
  area text,
  starts_at timestamptz,
  ends_at timestamptz,
  is_private boolean,
  cover_path text,
  host_id uuid,
  host_username text,
  lat double precision,
  lon double precision,
  going_count integer,
  interested_count integer,
  is_past boolean
)
language sql
stable
set search_path to 'public', 'extensions'
as $$
  with q as (
    select public.search_normalize(p_query) as key
  ),
  hits as (
    -- Driven from the TOKEN index, not from parties: this is the step that
    -- turns the whole table into a few rows before any policy runs. Both terms
    -- are leakproof, so they sort ahead of the token table's
    -- can_access_party() policy.
    --
    -- The range MUST stay `~>=~` / `~<~`. `like q.key || '%'` returns the same
    -- rows and never reaches the index (textlike is non-leakproof, so the
    -- planner may not promote it past the policy and the index qual is never
    -- formed). `>=` / `<` also return the same rows, are leakproof, are
    -- promoted -- and still cannot use this index, because text_ops and
    -- text_pattern_ops are different operator families. Asserted three ways in
    -- 20_party_search.test.sql.
    select distinct t.party_id
    from public.party_search_tokens t, q
    where q.key <> ''
      and t.token ~>=~ q.key
      and t.token ~<~ public.search_prefix_upper(q.key)
  )
  select
    p.id as party_id,
    p.title,
    p.area,
    p.starts_at,
    p.ends_at,
    p.is_private,
    p.cover_path,
    p.host_id,
    pr.username as host_username,
    -- lat/lon so a search hit converts straight into a MapPartyPin and opens
    -- the SAME sheet the map opens. From `location`, like the map RPC does --
    -- never from bbox_lat/bbox_lon, which are index support only (Phase 13).
    st_y(p.location::geometry) as lat,
    st_x(p.location::geometry) as lon,
    p.going_count,
    p.interested_count,
    public.party_is_past(p.starts_at, p.ends_at) as is_past
  from hits h
  join public.parties p on p.id = h.party_id
  join public.profiles pr on pr.id = p.host_id
  where p.status = 'published'
  -- Upcoming first, soonest first; then past, most recent first. "Find that
  -- party from May" is a real use, which is why past rows are returned at all.
  order by
    public.party_is_past(p.starts_at, p.ends_at) asc,
    case when public.party_is_past(p.starts_at, p.ends_at) then null else p.starts_at end asc nulls last,
    case when public.party_is_past(p.starts_at, p.ends_at) then p.starts_at else null end desc nulls last
  limit greatest(least(p_limit, 50), 1);
$$;

comment on function public.search_parties(text, integer) is
  'Prefix search over party titles and areas, unbounded by location. '
  'SECURITY INVOKER so the parties and party_search_tokens policies both '
  'apply. map_visibility deliberately does NOT filter this -- it answers "do I '
  'want to be a pin", not "do I want to be unfindable". Past parties are '
  'returned in a second group, using party_is_past(); the map does not filter '
  'on that yet and the two therefore disagree about a null-ends_at party, '
  'which is expected. The range MUST stay ~>=~ / ~<~.';

revoke execute on function public.search_parties(text, integer) from public;
grant execute on function public.search_parties(text, integer) to authenticated;
