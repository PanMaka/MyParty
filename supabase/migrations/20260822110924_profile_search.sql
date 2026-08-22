-- Phase 14, piece A: profile search.
--
-- Full reasoning: docs/phase-14-text-search.md. The mechanism in one paragraph,
-- because it is unintuitive and two previous phases recorded search as
-- impossible while reasoning about the wrong operator:
--
-- An RLS policy is a security barrier, and a user qual may only be evaluated
-- ahead of it -- which is what reaching an index requires -- if THAT USER QUAL
-- is leakproof. `texticlike` (ILIKE) and `textlike` (LIKE) are not, so they can
-- never sort ahead of a policy and never reach an index. But `text_pattern_ge`
-- and `text_pattern_lt` ARE leakproof. So a hand-written range over a
-- normalized column reaches a text_pattern_ops btree ahead of the policy.
-- Measured at 10k rows: ILIKE 189ms / 40591 buffers, the range 0.035ms / 13.
--
-- TWO TRAPS, both measured in scripts/explain_qual_pushdown.sh, and both look
-- like the thing that works:
--
--   * `LIKE 'x%'` is NOT rewritten into that range across the barrier. The
--     planner forms the range as an index qual, and textlike is non-leakproof,
--     so it can never be promoted. The index is as unreachable for LIKE as
--     parties_location is for st_dwithin. The range must be written by hand.
--   * The operator class has to MATCH. `>=` and `<` are the default text_ops
--     family: leakproof, promoted, and still unable to use a text_pattern_ops
--     index -- 466 buffers instead of 13. Only `~>=~` and `~<~` do both.
--
-- A corollary decides the architecture: PostgREST cannot emit `~>=~` (its
-- `.gte()` is `>=`, the slow one), so search HAS to be an RPC. That is a
-- forcing function, not a limitation -- it is also the only way the range and
-- the normalizer stay in one place. A client that built the range itself would
-- have to reimplement the transliteration table, and two implementations of
-- that are a guarantee of divergence.


-- ---------------------------------------------------------------------------
-- 1. The normalizer. ONE function, shared with piece B (party search).
--
-- Output is [a-z0-9] and nothing else -- lowercase, no accents, no final
-- sigma, Greek transliterated to canonical Latin, every separator dropped.
--
-- LATIN, NOT GREEK, and the third reason is the load-bearing one:
--   1. it is the only way `taratsa` and `ταράτσα` land in the same space;
--   2. it removes a class of mismatch between what is stored and what is typed;
--   3. text_pattern_ops compares BYTES. With an ASCII-only column, byte order
--      IS character order, so the range [p, succ(p)) is provably the set of
--      strings starting with p, and succ() is "increment the last byte" which
--      never carries because 'z' is 0x7A. With multibyte Greek in the column
--      neither of those is obvious, and a wrong succ() is silently missing
--      results -- the same failure shape as Phase 13's bounding box.
--
-- translate()/replace()/regexp_replace()/lower() are all provolatile = i, so
-- this is honestly IMMUTABLE and usable in a generated column. `unaccent()` is
-- NOT: it is STABLE because it depends on a dictionary file, and it is not
-- installed here anyway. Do not reach for it.
--
-- THE AMBIGUITIES, written down because they are real and this map will be
-- tuned. Greeklish has no standard:
--   * χ -> x, and ξ -> x too. Collapsing both matches the common `nyxta`
--     spelling; `ch` on the Latin side is folded to x for the same reason, so
--     `techno` and `Τέχνο` meet at `texno`.
--   * υ -> i and Latin y -> i, so `nyxta`/`Νύχτα`/`nixta` all meet.
--   * ει/οι -> i, since they sound like one.
--   * μπ/ντ/γκ -> b/d/g ONLY at the start of a word. Inside one they are two
--     letters in different syllables: Σύνταγμα is `sintagma`, not `sidagma`.
--     That case is in the seed data and the first draft got it wrong.
--   * αυ -> av, ευ -> ev. Both are also written af/ef depending on what
--     follows; one direction had to be picked.
--
-- NOT covered, on purpose: infix search (`εχν` will not find `Τεχνο`) and the
-- 8-for-θ / 3-for-ξ numeric greeklish.
--
-- THE STALENESS TRAP: a GENERATED column does NOT recompute when this
-- function's BODY changes, and Postgres does not warn. PG 17 has
-- `ALTER TABLE ... ALTER COLUMN ... SET EXPRESSION AS (...)` to force the
-- rewrite. The actual protection is the assertion in 19_profile_search.test.sql
-- that recomputes this for every row and compares.
create function public.search_normalize(p_input text)
returns text
language sql
immutable
set search_path = ''
as $$
  with s0 as (select lower(coalesce(p_input, '')) as v),
       -- accents, dialytika, and both accented-dialytika forms
       s1 as (select translate(v, 'άέήίόύώϊϋΐΰ', 'αεηιουωιυιυ') as v from s0),
       -- final sigma
       s2 as (select translate(v, 'ς', 'σ') as v from s1),
       -- word-initial digraphs only; see the note above about Σύνταγμα
       s3 as (select regexp_replace(regexp_replace(regexp_replace(v,
                '\mμπ', 'b', 'g'), '\mντ', 'd', 'g'), '\mγκ', 'g', 'g') as v from s2),
       -- vowel digraphs that sound like one vowel, plus the affricates
       s4 as (select replace(replace(replace(replace(replace(replace(replace(v,
                'ου', 'ou'), 'ει', 'i'), 'οι', 'i'), 'γγ', 'g'),
                'τσ', 'ts'), 'τζ', 'tz'), 'αυ', 'av') as v from s3),
       -- the Greek letters whose Latin form is more than one character
       s5 as (select replace(replace(replace(replace(v,
                'ευ', 'ev'), 'θ', 'th'), 'ψ', 'ps'), 'χ', 'x') as v from s4),
       -- the 1:1 remainder
       s6 as (select translate(v,
                'αβγδεζηικλμνοπρστυφωξ',
                'avgdeziiklmnoprstifox') as v from s5),
       -- Latin-side folding, so greeklish typed in Latin meets the Greek form
       s7 as (select translate(replace(replace(v, 'ch', 'x'), 'ck', 'k'), 'y', 'i') as v from s6)
  select regexp_replace(v, '[^a-z0-9]', '', 'g') from s7;
$$;

comment on function public.search_normalize(text) is
  'Folds text to a [a-z0-9] search key: lowercase, no accents, no final sigma, '
  'Greek transliterated to canonical Latin. Shared by profile and party '
  'search, and by BOTH the stored column and the query -- a client that '
  'normalized on its own would have to reimplement the transliteration table. '
  'IMMUTABLE so it can back a generated column; note that changing this body '
  'does NOT recompute existing generated values (use ALTER COLUMN ... SET '
  'EXPRESSION), which is why 19_profile_search.test.sql recomputes and compares '
  'every row.';


-- ---------------------------------------------------------------------------
-- 2. The upper bound of a prefix range.
--
-- Its own function so the tests can hit it directly, because this is the piece
-- that fails silently. `[p, succ(p))` must be EXACTLY the set of strings
-- starting with p: too low and matching rows vanish with no error, which is
-- Phase 13's 298-vs-299 in a different costume.
--
-- Safe because search_normalize guarantees [a-z0-9]: the maximum byte is 'z'
-- (0x7A), so incrementing the last byte can never carry and never produces an
-- invalid UTF-8 sequence. It would NOT be safe on unnormalized input, which is
-- why this takes an already-normalized prefix and the RPC never calls it with
-- anything else.
create function public.search_prefix_upper(p_prefix text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_prefix is null or p_prefix = '' then null
    else left(p_prefix, length(p_prefix) - 1)
         || chr(ascii(right(p_prefix, 1)) + 1)
  end;
$$;

comment on function public.search_prefix_upper(text) is
  'Exclusive upper bound for a prefix range over a search_normalize()d column. '
  'Only sound for [a-z0-9] input. A wrong bound drops matching rows silently -- '
  'asserted in both directions, with a deliberately-wrong control, in '
  '19_profile_search.test.sql.';


-- ---------------------------------------------------------------------------
-- 3. The column and the index.
--
-- GENERATED, not a trigger, and the reason is erasure rather than tidiness:
-- complete_account_erasure scrubs `username` to an opaque deleted_<uuid>
-- handle, and a generated column is recomputed by that very UPDATE. A side
-- table would keep the original handle until somebody remembered to purge it
-- in the erasure engine -- one more place to forget, in the one path where
-- forgetting is not allowed. Asserted in 19_profile_search.test.sql.
--
-- No _-tokenization in v1: real usernames are one word. `friend_not_invited`
-- is a test persona. Splitting on _ is a strict upgrade later and does not
-- change the RPC, only what it ranges over.
alter table public.profiles
  add column username_search text
    generated always as (public.search_normalize(username)) stored;

comment on column public.profiles.username_search is
  'Normalized search key for username. Index support only -- never display it '
  'and never treat it as the username. Regenerated automatically when username '
  'is scrubbed by complete_account_erasure.';

-- text_pattern_ops, NOT the default. The existing profiles_username_lower_idx
-- is `unique btree (lower(username))` in the default text_ops family and
-- cannot serve `~>=~` -- do not mistake one for the other.
create index profiles_username_search_idx
  on public.profiles (username_search text_pattern_ops);


-- ---------------------------------------------------------------------------
-- 4. The RPC.
--
-- SECURITY INVOKER, deliberately and permanently. The `profiles` row policy
-- (`not is_blocked(...)`) must keep applying, and people search behind a
-- definer function is the oracle argument at its worst: the caller supplies the
-- predicate and reads the answer back, so a bug in a WHERE clause becomes an
-- enumerable directory. See §9 of docs/phase-12-parties-policy-rewrite.md.
--
-- This REPLACES SocialRepository.searchProfiles, which did
-- `.ilike('username', '%q%')`. That was infix; this is prefix. The narrowing is
-- deliberate (see the brief) but it IS a regression in reach, not just a new
-- feature with limits.
create function public.search_profiles(
  p_query text,
  p_limit integer default 20
)
returns table (
  id uuid,
  username text,
  follower_count integer,
  following_count integer
)
language sql
stable
set search_path to 'public', 'extensions'
as $$
  with q as (
    select public.search_normalize(p_query) as key
  )
  select
    pr.id,
    pr.username,
    pr.follower_count,
    pr.following_count
  from public.profiles pr, q
  where q.key <> ''

    -- THE PREFIX RANGE. Written out by hand with the PATTERN operators: see
    -- the migration header for why `like q.key || '%'` and `>= / <` both fail
    -- to reach the index. Both terms are leakproof, so they are evaluated
    -- BEFORE the row policy and everything below runs on what survives.
    and pr.username_search ~>=~ q.key
    and pr.username_search ~<~ public.search_prefix_upper(q.key)

    -- The profiles SELECT policy deliberately does NOT filter deleted_at --
    -- the tombstone has to stay visible to it or the inner joins in get_feed,
    -- get_messages and friends drop whole rows. So search filters it here, and
    -- it is not belt-and-braces: the erasure scrub makes username_search read
    -- `deleteduuid...`, so a search for `deleted` would otherwise return every
    -- tombstone in the system.
    and pr.deleted_at is null
    and pr.erased_at is null

    -- What searchProfiles did with .neq('id', uid).
    and pr.id <> (select auth.uid())

  order by pr.follower_count desc, pr.username asc
  limit greatest(least(p_limit, 50), 1);
$$;

comment on function public.search_profiles(text, integer) is
  'Prefix search over usernames. SECURITY INVOKER on purpose -- the profiles '
  'row policy is the block filter, and a definer version would be an '
  'enumeration oracle. The range MUST stay `~>=~` / `~<~`: LIKE and `>=` both '
  'return correct rows and both silently stop using '
  'profiles_username_search_idx. Asserted three ways in '
  '19_profile_search.test.sql.';

revoke execute on function public.search_profiles(text, integer) from public;
grant execute on function public.search_profiles(text, integer) to authenticated;

-- Anon keeps no grant, matching 20260821175831's treatment of the map RPC: the
-- self-exclusion term reads auth.uid(), so for an unauthenticated caller this
-- would silently mean something different rather than fail.
