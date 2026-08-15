-- Phase 4, part 2: the feed.
--
-- Deliberately NOT security definer. That is the whole design: running with
-- invoker rights means `from public.party_posts` evaluates the SELECT policy
-- from 20260814112530 for the calling user, which is already
-- can_access_party + is_blocked(author) + not hidden. A definer function
-- would have to restate all three inline and would drift from them the first
-- time one changes (CLAUDE.md #4). public.get_parties_near_user relies on the
-- same property.
--
-- So the WHERE clause below is purely a NARROWING -- "which of the parties I
-- can already see do I actually care about" -- and can never widen access.
-- Even the joins are load bearing in that direction: public.profiles is
-- block-filtered since 20260814094945, so the inner join on the author's
-- profile independently drops a blocked author's posts.
--
-- Pagination is keyset, never offset (CLAUDE.md #5). party_posts_created_idx
-- is (created_at desc, id desc) where hidden_at is null -- the exact order
-- this scans, so the LIMIT stops the scan instead of sorting the world.

create function public.get_feed(
  p_before_created_at timestamp with time zone default null,
  p_before_id uuid default null,
  p_limit int default 20
)

returns table (
  post_id uuid,
  party_id uuid,
  party_title text,
  party_is_private boolean,
  author_id uuid,
  author_username text,
  body text,
  media_path text,
  like_count int,
  comment_count int,
  liked_by_me boolean,
  created_at timestamp with time zone
)

language sql
stable
as $$
  select
    pp.id as post_id,
    pp.party_id,
    p.title as party_title,
    p.is_private as party_is_private,
    pp.author_id,
    pr.username as author_username,
    pp.body,
    pp.media_path,
    pp.like_count,
    pp.comment_count,

    exists (
      select 1 from public.post_likes pl
      where pl.post_id = pp.id and pl.user_id = (select auth.uid())
    ) as liked_by_me,

    pp.created_at

  from public.party_posts pp
  join public.parties p on p.id = pp.party_id
  join public.profiles pr on pr.id = pp.author_id

  where
    -- Defence in depth behind the revoke below: a session with no uid has no
    -- follow/rsvp/invite set to build a feed from, and every arm of the next
    -- clause would be false anyway. Stated explicitly so the function is
    -- still correct if it is ever granted more broadly, or called from
    -- service_role with no JWT.
    (select auth.uid()) is not null

    -- Hosting, following, attending, invited. "Attending" counts an
    -- 'interested' rsvp as well as a 'going' one on purpose -- the feed
    -- carries both the run-up to a party and its aftermath, and someone who
    -- marked interest wants the run-up.
    and (
      p.host_id = (select auth.uid())

      or exists (
        select 1 from public.follows f
        where f.follower_id = (select auth.uid())
        and f.followee_id = p.host_id
      )

      or exists (
        select 1 from public.rsvps r
        where r.party_id = pp.party_id
        and r.user_id = (select auth.uid())
      )

      or exists (
        select 1 from public.invitations i
        where i.party_id = pp.party_id
        and i.guest_id = (select auth.uid())
      )
    )

    -- Keyset cursor. Both halves travel together; a caller that passes only
    -- the timestamp gets "strictly before that instant", because the zero
    -- uuid is the minimum of the type and no real row can sort below it at
    -- the same timestamp. Ties on created_at are common (several posts can
    -- share a transaction clock), which is exactly why id is in the key.
    and (
      p_before_created_at is null
      or (pp.created_at, pp.id)
         < (p_before_created_at, coalesce(p_before_id, '00000000-0000-0000-0000-000000000000'::uuid))
    )

  order by pp.created_at desc, pp.id desc
  limit least(greatest(coalesce(p_limit, 20), 1), 50);
$$;

-- Functions are executable by PUBLIC by default, and that default is wrong
-- here. Table privileges are checked when a statement runs regardless of
-- whether its WHERE clause could ever be true, so an anonymous caller hits
-- "permission denied for table rsvps" -- a confusing error that also
-- advertises the query's internals. Making the function itself
-- authenticated-only turns that into the honest answer: there is no such
-- thing as an anonymous feed.
revoke execute on function public.get_feed(timestamp with time zone, uuid, int) from public;
grant execute on function public.get_feed(timestamp with time zone, uuid, int)
  to authenticated, service_role;
