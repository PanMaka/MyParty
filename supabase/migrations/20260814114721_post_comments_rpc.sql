-- Reading a post's comments needs an RPC for the same reason the feed did:
-- CLAUDE.md #5 requires keyset pagination on any unbounded list, and a
-- keyset is a row-value comparison -- `(created_at, id) < (?, ?)` -- which
-- PostgREST's query grammar cannot express. Left to the client, the comment
-- list would have ended up on either offset paging or a plain `lt` on
-- created_at that silently drops rows whenever two comments share a
-- timestamp. So the keyset lives here, next to the index that serves it
-- (post_comments_post_created_idx).
--
-- Invoker rights, like get_feed: the post_comments SELECT policy already
-- says "not hidden, author not blocked, and the post itself is visible to
-- you", and the last of those transitively re-runs party_posts' policy and
-- so can_access_party. Nothing to restate here (CLAUDE.md #4). The join to
-- public.profiles is block-filtered too, which is a second, independent
-- reason a blocked author's comment cannot come back from this.

create function public.get_post_comments(
  p_post_id uuid,
  p_before_created_at timestamp with time zone default null,
  p_before_id uuid default null,
  p_limit int default 30
)

returns table (
  id uuid,
  post_id uuid,
  author_id uuid,
  author_username text,
  body text,
  created_at timestamp with time zone
)

language sql
stable
as $$
  select
    c.id,
    c.post_id,
    c.author_id,
    pr.username as author_username,
    c.body,
    c.created_at
  from public.post_comments c
  join public.profiles pr on pr.id = c.author_id
  where
    c.post_id = p_post_id
    and (
      p_before_created_at is null
      or (c.created_at, c.id)
         < (p_before_created_at, coalesce(p_before_id, '00000000-0000-0000-0000-000000000000'::uuid))
    )
  order by c.created_at desc, c.id desc
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

-- Unlike get_feed this one is fine for anon -- it touches only tables anon
-- already has SELECT on, and a public party's comments are as public as the
-- party. The default PUBLIC execute grant is therefore left alone.
