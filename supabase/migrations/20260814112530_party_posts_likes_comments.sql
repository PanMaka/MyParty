-- Phase 4, part 1: the UGC tables. Visibility is NOT re-derived here --
-- party_posts defers to public.can_access_party (extracted in 20260812121153,
-- block-aware since 20260814094945), and post_likes/post_comments defer to
-- party_posts by way of an exists() subquery that re-evaluates its SELECT
-- policy for the querying role. One implementation of "who may see this
-- party", three tables inheriting it (CLAUDE.md #4).
--
-- can_access_party only knows about the party's HOST, so every table here
-- adds its own is_blocked check on the AUTHOR: a blocked user can have
-- posted on a public party hosted by a third party, and that post has to
-- disappear too.
--
-- Soft-delete columns land on all three tables, and "hidden" means hidden
-- everywhere: the row leaves every SELECT policy AND stops counting toward
-- the denormalized counters (see the triggers below). A hidden_* column that
-- only removed the row from the UI while like_count kept counting it would
-- be a lie the moderator never sees.


-- ============================================================
-- party_posts
-- ============================================================
create table public.party_posts (
  id uuid default gen_random_uuid() primary key,
  party_id uuid references public.parties(id) on delete cascade not null,
  author_id uuid references public.profiles(id) on delete cascade not null,
  body text,
  -- {party_id}/... in the private post-media bucket (20260812124217).
  -- Uploads are signed-URL only, so this column records a path the client
  -- never wrote to directly.
  media_path text,
  like_count int not null default 0,
  comment_count int not null default 0,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  hidden_at timestamp with time zone,
  hidden_by uuid references public.profiles(id) on delete set null,
  hidden_reason text,
  constraint party_posts_not_empty check (body is not null or media_path is not null),
  -- hidden_by may be null (a system/service_role hide), but it can never be
  -- set on a row that is not actually hidden.
  constraint party_posts_hidden_consistent check (hidden_by is null or hidden_at is not null)
);

-- Both indexes are partial on `hidden_at is null` because every read path
-- excludes hidden rows, and both carry the (created_at desc, id desc)
-- keyset in the order get_feed scans it -- CLAUDE.md #5. The feed orders
-- globally; the per-party index serves a single party's post list and lets
-- the planner merge-append when the feed's party set is small.
create index party_posts_created_idx
  on public.party_posts (created_at desc, id desc)
  where hidden_at is null;

create index party_posts_party_created_idx
  on public.party_posts (party_id, created_at desc, id desc)
  where hidden_at is null;


-- ============================================================
-- post_likes
--
-- No surrogate id: (post_id, user_id) is the natural key and doubles as the
-- "have I liked this" index. The primary key also serves lookups by post;
-- post_likes_user_idx serves the reverse ("posts I liked").
-- ============================================================
create table public.post_likes (
  post_id uuid references public.party_posts(id) on delete cascade not null,
  user_id uuid references public.profiles(id) on delete cascade not null,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  hidden_at timestamp with time zone,
  hidden_by uuid references public.profiles(id) on delete set null,
  hidden_reason text,
  primary key (post_id, user_id),
  constraint post_likes_hidden_consistent check (hidden_by is null or hidden_at is not null)
);

create index post_likes_user_idx on public.post_likes (user_id);


-- ============================================================
-- post_comments
-- ============================================================
create table public.post_comments (
  id uuid default gen_random_uuid() primary key,
  post_id uuid references public.party_posts(id) on delete cascade not null,
  author_id uuid references public.profiles(id) on delete cascade not null,
  body text not null,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  hidden_at timestamp with time zone,
  hidden_by uuid references public.profiles(id) on delete set null,
  hidden_reason text,
  constraint post_comments_body_not_blank check (length(btrim(body)) > 0),
  constraint post_comments_hidden_consistent check (hidden_by is null or hidden_at is not null)
);

create index post_comments_post_created_idx
  on public.post_comments (post_id, created_at desc, id desc)
  where hidden_at is null;


-- ============================================================
-- Denormalized counters (CLAUDE.md #6), same shape as
-- public.sync_party_rsvp_counters (20260813095451): security definer so the
-- UPDATE runs as the table owner and bypasses party_posts' RLS -- a like
-- changes SOMEONE ELSE'S post row, which no policy here would ever permit.
--
-- A row counts iff it is not hidden, so the UPDATE branch fires only when a
-- soft-delete flips that. The `is distinct from` guard on the boolean (not
-- on hidden_at itself) means re-hiding an already-hidden row is a no-op
-- rather than a double decrement.
-- ============================================================
create or replace function public.sync_post_like_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if TG_OP = 'INSERT' then
    if NEW.hidden_at is null then
      update public.party_posts set like_count = like_count + 1 where id = NEW.post_id;
    end if;
    return null;
  end if;

  if TG_OP = 'DELETE' then
    if OLD.hidden_at is null then
      update public.party_posts set like_count = like_count - 1 where id = OLD.post_id;
    end if;
    return null;
  end if;

  -- TG_OP = 'UPDATE'
  if (NEW.hidden_at is null) is distinct from (OLD.hidden_at is null) then
    update public.party_posts set
      like_count = like_count
        + (NEW.hidden_at is null)::int - (OLD.hidden_at is null)::int
    where id = NEW.post_id;
  end if;
  return null;
end;
$$;

create trigger post_likes_sync_count
after insert or update or delete on public.post_likes
for each row execute function public.sync_post_like_count();


create or replace function public.sync_post_comment_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if TG_OP = 'INSERT' then
    if NEW.hidden_at is null then
      update public.party_posts set comment_count = comment_count + 1 where id = NEW.post_id;
    end if;
    return null;
  end if;

  if TG_OP = 'DELETE' then
    if OLD.hidden_at is null then
      update public.party_posts set comment_count = comment_count - 1 where id = OLD.post_id;
    end if;
    return null;
  end if;

  -- TG_OP = 'UPDATE'
  if (NEW.hidden_at is null) is distinct from (OLD.hidden_at is null) then
    update public.party_posts set
      comment_count = comment_count
        + (NEW.hidden_at is null)::int - (OLD.hidden_at is null)::int
    where id = NEW.post_id;
  end if;
  return null;
end;
$$;

create trigger post_comments_sync_count
after insert or update or delete on public.post_comments
for each row execute function public.sync_post_comment_count();


-- ============================================================
-- Soft delete.
--
-- This is an RPC and not an UPDATE policy, and the reason is a property of
-- Postgres RLS that is worth writing down because it will come up again in
-- Phases 5 and 6: on UPDATE, the SELECT policy is applied to the NEW row,
-- not just the old one, whenever the statement needs read access (any WHERE
-- clause does). The SELECT policies above say `hidden_at is null`. So a
-- soft-delete performed as a client UPDATE always produces a new row the
-- client may no longer read, and Postgres rejects it with "new row violates
-- row-level security policy" -- no WITH CHECK expression can rescue that.
--
-- The two ways out are (a) carve an exception into the SELECT policy so a
-- moderator can still read hidden rows, or (b) do the write in a security
-- definer function. (b) is chosen: it keeps "hidden means hidden, to every
-- client role, with no exceptions" as a flat invariant instead of a
-- predicate with a hole in it, and it lets the rules that a policy pair
-- would have had to encode across USING/WITH CHECK -- you may only hide,
-- never un-hide; hidden_by is always you -- be stated once, in order, as
-- code. It also means party_posts and post_comments need NO update grant at
-- all, so there is no column left for a client to write after insert.
--
-- can_moderate_post / can_moderate_comment are THE "who may take this down"
-- rules (CLAUDE.md #4), kept separate from the functions that act on them so
-- a future admin surface can ask the question without performing the write.
-- Both are security definer for the same reason is_blocked is: they read
-- rows the caller may not SELECT, and return only a boolean.
-- ============================================================
create or replace function public.can_moderate_post(p_post_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1
    from public.party_posts pp
    join public.parties p on p.id = pp.party_id
    where pp.id = p_post_id
    and (
      pp.author_id = (select auth.uid())
      or p.host_id = (select auth.uid())
    )
  );
$$;

-- A comment can be taken down by whoever wrote it, or by anyone who could
-- take down the post it hangs off -- the post's author and the party's host.
create or replace function public.can_moderate_comment(p_comment_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1
    from public.post_comments c
    where c.id = p_comment_id
    and (
      c.author_id = (select auth.uid())
      or public.can_moderate_post(c.post_id)
    )
  );
$$;

-- `and hidden_at is null` in both statements is what makes hiding one-way:
-- a second call cannot overwrite the original hidden_by/hidden_reason, so a
-- post author cannot paper over a host's take-down by re-hiding it under
-- their own name. Un-hiding has no client path at all -- there is no update
-- grant on these tables -- and stays a service_role operation.
--
-- Authorization is checked before the hidden_at filter, deliberately: an
-- unauthorized caller gets the same 42501 whether or not the row is already
-- down, so this cannot be used to probe what exists.
create or replace function public.hide_post(p_post_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.can_moderate_post(p_post_id) then
    raise exception 'not authorized to hide post %', p_post_id
      using errcode = '42501';
  end if;

  update public.party_posts
  set hidden_at = now(),
      hidden_by = (select auth.uid()),
      hidden_reason = p_reason
  where id = p_post_id
  and hidden_at is null;
end;
$$;

create or replace function public.hide_comment(p_comment_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.can_moderate_comment(p_comment_id) then
    raise exception 'not authorized to hide comment %', p_comment_id
      using errcode = '42501';
  end if;

  update public.post_comments
  set hidden_at = now(),
      hidden_by = (select auth.uid()),
      hidden_reason = p_reason
  where id = p_comment_id
  and hidden_at is null;
end;
$$;


-- ============================================================
-- RLS
-- ============================================================
alter table public.party_posts enable row level security;
alter table public.post_likes enable row level security;
alter table public.post_comments enable row level security;

-- Hidden posts are invisible to every client role, their author included.
-- Triage happens over service_role, which bypasses RLS entirely.
create policy "Posts are viewable by anyone who can access the party"
on public.party_posts for select
using (
  hidden_at is null
  and public.can_access_party(party_id)
  and not public.is_blocked((select auth.uid()), author_id)
);

create policy "Users can post to parties they can access"
on public.party_posts for insert to authenticated
with check (
  author_id = (select auth.uid())
  and hidden_at is null
  and public.can_access_party(party_id)
);

-- No UPDATE policy and no DELETE policy on party_posts. Nothing here is
-- editable after insert this phase, and taking a post down goes through
-- public.hide_post (CLAUDE.md #7: UGC deletes are soft; hard delete is
-- reserved for Phase 9 account/GDPR erasure).

-- Likes and comments inherit party visibility through this exists() rather
-- than calling can_access_party again: the subquery re-runs party_posts'
-- own SELECT policy for the querying role, so it also picks up the hidden
-- and blocked-author checks for free. Same inheritance trick the storage
-- policies in 20260812124217 use on public.parties.
create policy "Likes are viewable on visible posts"
on public.post_likes for select
using (
  hidden_at is null
  and exists (select 1 from public.party_posts pp where pp.id = post_id)
);

create policy "Users can like posts they can see"
on public.post_likes for insert to authenticated
with check (
  user_id = (select auth.uid())
  and hidden_at is null
  and exists (select 1 from public.party_posts pp where pp.id = post_id)
);

-- Unconditional on purpose, exactly like the rsvps and follows DELETE
-- policies: unliking is not a content deletion, and gating it would strand
-- the like forever the moment the post's party stopped being accessible.
create policy "Users can unlike"
on public.post_likes for delete to authenticated
using ( user_id = (select auth.uid()) );

-- No UPDATE policy on post_likes: a like has no field a user may change,
-- and hiding one is a service_role action.

create policy "Comments are viewable on visible posts"
on public.post_comments for select
using (
  hidden_at is null
  and not public.is_blocked((select auth.uid()), author_id)
  and exists (select 1 from public.party_posts pp where pp.id = post_id)
);

create policy "Users can comment on posts they can see"
on public.post_comments for insert to authenticated
with check (
  author_id = (select auth.uid())
  and hidden_at is null
  and exists (select 1 from public.party_posts pp where pp.id = post_id)
);

-- Same as party_posts: no UPDATE or DELETE policy. Taking a comment down
-- goes through public.hide_comment.


-- ============================================================
-- Grants. RLS filters rows on top of a grant that already permits the
-- statement -- 20260812115436 and 20260813100309 exist purely because this
-- step was forgotten twice.
--
-- The INSERT grants are COLUMN-level, which is the point. RLS gates which
-- ROW you may touch, never which COLUMN, and public.profiles already needed
-- a whole trigger (protect_credibility_score) to stop a user PATCHing their
-- own follower_count through a legitimate row-level policy. That trigger
-- exists because profiles genuinely needs a table-wide UPDATE grant for
-- username and consent flags. These three tables need no such thing, so
-- Postgres' own column privileges can state the rule directly instead of a
-- trigger restating it.
--
-- What the grants therefore make impossible, with no policy or trigger
-- involved: seeding like_count/comment_count at insert time, back- or
-- future-dating created_at to pin a post to the top of every feed, and
-- writing hidden_* by hand instead of going through hide_post/hide_comment.
-- `id` is grantable because client-generated uuids are how optimistic
-- inserts stay idempotent.
--
-- No UPDATE grant anywhere below, on any column: after insert these rows are
-- immutable to every client role.
-- ============================================================
grant select on public.party_posts to anon, authenticated;
grant insert (id, party_id, author_id, body, media_path) on public.party_posts to authenticated;

grant select on public.post_likes to anon, authenticated;
grant insert (post_id, user_id) on public.post_likes to authenticated;
grant delete on public.post_likes to authenticated;

grant select on public.post_comments to anon, authenticated;
grant insert (id, post_id, author_id, body) on public.post_comments to authenticated;
