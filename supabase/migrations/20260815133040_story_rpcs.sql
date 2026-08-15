-- Phase 5, part 2: the two read RPCs.
--
-- Both are deliberately NOT security definer, the same design get_feed
-- (20260814112531) and get_messages (20260815095450) run on. Invoker rights
-- means `from public.stories` evaluates that table's SELECT policy for the
-- calling user -- already can_access_party + is_blocked(author) + not hidden +
-- confirmed + unexpired -- so neither function restates a single term of it and
-- neither can drift from it when it changes (CLAUDE.md #4). Every WHERE clause
-- below is a NARROWING and is structurally incapable of widening access.
--
-- Neither returns anything you could fetch bytes with. media_path names an
-- object in a bucket with zero storage policies, so it is a key the story-media
-- edge function trades for a short-lived signed URL after re-checking
-- visibility -- not a URL. Handing the path to a client that cannot see the
-- story would be harmless anyway; handing it to one that can saves a round trip.


-- ============================================================
-- get_party_stories -- one party's live stories, oldest first.
--
-- OLDEST first, which is the opposite of get_messages and get_feed, and not an
-- oversight: a story reel plays forward through the night. The keyset therefore
-- runs the other way too -- `(created_at, id) > cursor` with `order by
-- created_at, id` -- and stories_party_live_idx serves it in either direction,
-- since a btree scans backwards at the same cost.
--
-- The join to public.profiles is doing more than fetching a username: that
-- table has been block-filtered since 20260814094945, so an inner join drops a
-- blocked author's stories independently of the is_blocked term already in the
-- stories SELECT policy. Two mechanisms, same answer -- the same belt-and-
-- braces get_feed and get_messages have.
--
-- `viewed` is a left join rather than an exists() so the row is fetched in the
-- same index lookup that answers it. story_views' SELECT policy limits it to
-- the caller's own rows, so this cannot leak whether anyone ELSE has watched.
-- ============================================================
create function public.get_party_stories(
  p_party_id uuid,
  p_after_created_at timestamp with time zone default null,
  p_after_id uuid default null,
  p_limit int default 30
)

returns table (
  id uuid,
  party_id uuid,
  author_id uuid,
  author_username text,
  media_path text,
  content_type text,
  created_at timestamp with time zone,
  expires_at timestamp with time zone,
  view_count int,
  viewed boolean
)

language sql
stable
as $$
  select
    s.id,
    s.party_id,
    s.author_id,
    pr.username as author_username,
    s.media_path,
    s.content_type,
    s.created_at,
    s.expires_at,
    s.view_count,
    v.story_id is not null as viewed

  from public.stories s
  join public.profiles pr on pr.id = s.author_id
  left join public.story_views v
    on v.story_id = s.id and v.user_id = (select auth.uid())

  where s.party_id = p_party_id

    -- Keyset cursor, never an offset (CLAUDE.md #5). Both halves travel
    -- together; a caller that passes only the timestamp gets "strictly after
    -- that instant", because the zero uuid is the minimum of the type and no
    -- real row can sort below it at the same timestamp. Ties are not a corner
    -- case -- a burst of uploads from one table at midnight shares a
    -- timestamp -- which is why id is in the key.
    and (
      p_after_created_at is null
      or (s.created_at, s.id)
         > (p_after_created_at, coalesce(p_after_id, '00000000-0000-0000-0000-000000000000'::uuid))
    )

  order by s.created_at, s.id
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;


-- ============================================================
-- get_story_rails -- the feed's story row: one entry per party that has
-- something live right now.
--
-- The CTE is a straight aggregate over public.stories through the caller's own
-- RLS, so the set of parties this can name is exactly the set whose stories the
-- caller may watch. There is no join to public.parties driving the query --
-- that direction would call can_access_party once per visible party, which on a
-- platform full of public parties is most of the table, to discover that almost
-- none of them have a story. Starting from the stories side means the scan is
-- proportional to what was posted in the last 24 hours.
--
-- The counts here are read-time aggregates, which CLAUDE.md #6 forbids. The
-- rule bends rather than breaks, the same way get_party_chats' unread count
-- does, and for a structurally similar reason: `has_unseen` is per-viewer, so
-- there is no row it could be denormalized onto -- a counter on parties would
-- need one column per user. What makes it safe is that the input set is BOUNDED
-- BY TIME, not by history: only unexpired stories are visible at all, so this
-- aggregates at most 24 hours of uploads no matter how long the platform has
-- been running, riding stories_party_live_idx. That is the property #6 exists
-- to protect -- cost independent of how old the table is.
--
-- cover_story_id is the newest frame, which is what the rail tile renders. It
-- is returned as an id, not a path, for the same reason as above: the client
-- trades ids for signed URLs at the edge function, and one code path for that
-- is better than two.
-- ============================================================
create function public.get_story_rails()

returns table (
  party_id uuid,
  party_title text,
  party_is_private boolean,
  story_count int,
  latest_at timestamp with time zone,
  cover_story_id uuid,
  cover_media_path text,
  has_unseen boolean
)

language sql
stable
as $$
  with live as (
    select
      s.id,
      s.party_id,
      s.media_path,
      s.created_at,
      -- Not exists(): story_views is already left-joined for the aggregate
      -- below, and its SELECT policy confines it to the caller's own rows, so
      -- this reads "have I seen it" and can never read "has anyone".
      v.story_id is not null as viewed,
      row_number() over (partition by s.party_id order by s.created_at desc, s.id desc) as recency
    from public.stories s
    left join public.story_views v
      on v.story_id = s.id and v.user_id = (select auth.uid())
  )

  select
    p.id as party_id,
    p.title as party_title,
    p.is_private as party_is_private,
    count(*)::int as story_count,
    max(l.created_at) as latest_at,
    -- The window above already ranked them, so the cover falls out of the same
    -- pass rather than a second scan for the newest row. array_agg[1] rather
    -- than max(): there is no max(uuid) aggregate in Postgres 17, and picking
    -- the two cover columns off the same ordered aggregate keeps them from
    -- ever describing different rows.
    (array_agg(l.id order by l.recency))[1] as cover_story_id,
    (array_agg(l.media_path order by l.recency))[1] as cover_media_path,
    bool_or(not l.viewed) as has_unseen

  from live l
  -- Inner join: a party row the caller cannot SELECT drops its rail entirely.
  -- Unreachable in practice -- the stories policy already required
  -- can_access_party, which is strictly stronger -- but it means a future
  -- change to party visibility cannot leave a rail behind advertising a party
  -- the viewer can no longer open.
  join public.parties p on p.id = l.party_id

  group by p.id, p.title, p.is_private
  order by bool_or(not l.viewed) desc, max(l.created_at) desc;
$$;


-- ============================================================
-- Grants (CLAUDE.md gotcha #4).
--
-- Both functions MENTION public.stories, and table privileges are checked
-- whether or not a WHERE clause could ever be true -- so an anon caller would
-- hit "permission denied for table stories" from inside the function body
-- rather than getting an empty list. Revoking execute makes the refusal happen
-- at the door, with an error that names the function the caller actually
-- called instead of advertising the query's internals.
-- ============================================================
revoke execute on function public.get_party_stories(uuid, timestamp with time zone, uuid, int) from anon;
revoke execute on function public.get_story_rails() from anon;
