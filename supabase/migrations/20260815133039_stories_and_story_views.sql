-- Phase 5, part 1: stories, story_views, and the upload handshake.
--
-- Visibility is inherited, not restated: public.can_access_party
-- (20260812121153, block-aware since 20260814094945) answers "may I look at
-- this party", and a story is visible to exactly the people the party is --
-- CLAUDE.md #4. Note this is the WIDE helper, deliberately: unlike chat
-- (20260815095446, which narrows to participants because a writable room the
-- whole user base can post in is a spam surface), a story is read-only content
-- attached to a party, so a passer-by who may see the party may see its
-- stories. Posting one is separately gated by the same helper, which means the
-- author has to be able to see the party -- not merely be signed in.
--
-- can_access_party only knows about the party's HOST, so stories carries its
-- own is_blocked check on the AUTHOR, the same way party_posts (20260814112530)
-- and messages (20260815095446) do. A blocked user can have posted a story on a
-- public party hosted by a third party, and it has to disappear too.
--
-- THE INVARIANT THIS FILE EXISTS TO PROTECT: every object in the story-media
-- bucket has exactly one row here, and every row names exactly one object.
-- The bucket (20260812124217) has zero storage policies, so the client cannot
-- write to it, cannot read from it, and -- most importantly for what part 3
-- does -- cannot put an object there that no row points at. The rows are the
-- ledger the purge enumerates; an object the ledger does not know about is an
-- object nobody will ever delete.


-- ============================================================
-- stories
--
-- Four timestamps, and they are not interchangeable:
--
--   created_at        the row appeared
--   expires_at        server-set, created_at + 24h. Not client-settable (no
--                     insert grant), or a story could be posted pre-expired
--                     to dodge moderation, or set to never expire.
--   media_uploaded_at the bytes actually landed, confirmed against
--                     storage.objects. NULL means "reserved, nothing there
--                     yet" and the row is invisible to everyone.
--   media_deleted_at  the object is gone from the bucket. Set only by part 3,
--                     and only on a confirmed HTTP response.
--
-- media_path is NOT NULL but carries no insert grant: the before-insert
-- trigger below computes it. A client that cannot name the path cannot aim an
-- upload at another party's folder, and the deterministic {party}/{id}.{ext}
-- shape is what lets the purge reconstruct what to delete from the row alone.
-- ============================================================
create table public.stories (
  id uuid default gen_random_uuid() primary key,
  party_id uuid references public.parties(id) on delete cascade not null,
  author_id uuid references public.profiles(id) on delete cascade not null,
  media_path text not null,
  content_type text not null,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  -- now(), not the timezone('utc', now()) the other timestamps in this schema
  -- use. That idiom returns a NAIVE timestamp which is then re-interpreted in
  -- the session's TimeZone on the way into a timestamptz column -- harmless
  -- for created_at, where every row shifts identically and only the ordering
  -- is ever read, but not for a column the SELECT policy compares against
  -- now(). A session running in a non-UTC timezone would otherwise get
  -- stories that die hours early or late.
  expires_at timestamp with time zone default (now() + interval '24 hours') not null,
  media_uploaded_at timestamp with time zone,
  media_deleted_at timestamp with time zone,
  view_count int default 0 not null,
  hidden_at timestamp with time zone,
  hidden_by uuid references public.profiles(id) on delete set null,
  hidden_reason text,
  -- The bucket accepts what this list allows and nothing else: the extension
  -- in media_path is derived from this column, so an unknown type would have
  -- no path to derive. Kept as a check rather than a lookup table because it
  -- changes about once a year and a join per insert is not worth it.
  constraint stories_content_type check (
    content_type in ('image/jpeg', 'image/png', 'image/webp', 'video/mp4')
  ),
  constraint stories_expires_after_creation check (expires_at > created_at),
  -- hidden_by may be null (the cron job hides expired rows with no user
  -- behind it), but it can never be set on a row that is not hidden.
  constraint stories_hidden_consistent check (hidden_by is null or hidden_at is not null),
  -- An object cannot be deleted before it was ever confirmed present, and a
  -- live story cannot have had its bytes purged. Part 3 only ever purges rows
  -- it has already hidden, and this is the constraint that says so out loud.
  constraint stories_deleted_implies_uploaded check (
    media_deleted_at is null or media_uploaded_at is not null
  ),
  constraint stories_deleted_implies_hidden check (
    media_deleted_at is null or hidden_at is not null
  )
);

-- The read path: rails and the viewer both scan one party's live stories in
-- (created_at desc, id desc), which is also the keyset public.get_party_stories
-- pages on -- CLAUDE.md #5. `expires_at > now()` deliberately does NOT appear
-- in the predicate: now() is not immutable, so it cannot live in a partial
-- index at all. It stays a runtime term, and the index still does the work
-- because the 24h window means the live set is a short prefix of this order.
create index stories_party_live_idx
  on public.stories (party_id, created_at desc, id desc)
  where hidden_at is null and media_uploaded_at is not null;

-- The rate limit counts one author's last hour. Covers hidden rows too -- see
-- enforce_story_rate_limit for why that matters -- so no partial predicate.
create index stories_author_created_idx
  on public.stories (author_id, created_at desc);

-- public.expire_stories() (part 3) sweeps this every 5 minutes; a partial
-- index on rows that are still up keeps that scan proportional to what is
-- live, not to everything ever posted.
create index stories_expiry_idx
  on public.stories (expires_at)
  where hidden_at is null;

-- public.purge_story_media() (part 3) sweeps THIS one: hidden rows whose bytes
-- are still sitting in the bucket. It drains to near-empty on every tick,
-- which is the property that keeps storage cost bounded.
create index stories_purge_idx
  on public.stories (hidden_at)
  where media_deleted_at is null and media_uploaded_at is not null;


-- ============================================================
-- story_views
--
-- Composite PK rather than a surrogate id + unique constraint: the pair IS the
-- identity, and the client upserts blindly on every frame it renders, so
-- `on conflict do nothing` needs something to conflict on.
-- ============================================================
create table public.story_views (
  story_id uuid references public.stories(id) on delete cascade not null,
  user_id uuid references public.profiles(id) on delete cascade not null,
  viewed_at timestamp with time zone default timezone('utc'::text, now()) not null,
  primary key (story_id, user_id)
);

-- "Which of this party's stories have I already seen" -- the unseen ring in
-- the feed rail. The PK indexes (story_id, user_id); this is the other
-- direction, keyed on the viewer.
create index story_views_user_idx on public.story_views (user_id, story_id);


-- ============================================================
-- media_path is derived, never supplied.
--
-- {party_id}/{story_id}.{ext} matches the {party_id}/... convention
-- party-covers and post-media already use (20260812124217), and it makes the
-- path a pure function of the row: part 3 can reconstruct exactly what to
-- delete without having stored anything extra, and a bucket listing can be
-- reconciled against the table by inspection.
--
-- The trigger OVERWRITES rather than defaults, so it holds even if a future
-- migration grants insert on the column by accident. Assigning in a BEFORE
-- trigger satisfies the NOT NULL, which is checked after triggers run.
-- ============================================================
create or replace function public.set_story_media_path()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  NEW.media_path := NEW.party_id::text || '/' || NEW.id::text || '.' ||
    case NEW.content_type
      when 'image/jpeg' then 'jpg'
      when 'image/png'  then 'png'
      when 'image/webp' then 'webp'
      when 'video/mp4'  then 'mp4'
    end;

  -- Unreachable while stories_content_type holds. Here so that widening that
  -- check without widening this case list fails loudly at insert time instead
  -- of quietly writing a path ending in '.' that nothing can ever serve.
  if NEW.media_path is null or NEW.media_path like '%.' then
    raise exception 'no media extension defined for content type %', NEW.content_type;
  end if;

  return NEW;
end;
$$;

create trigger stories_set_media_path
before insert on public.stories
for each row execute function public.set_story_media_path();


-- ============================================================
-- Server-side rate limit: 10 stories per user per hour (CLAUDE.md #7).
--
-- A before-insert trigger, not a policy, for the reason the messages limit
-- (20260815095446) is one: a policy answers yes/no about the row in front of
-- it, and this rule is about the rows around it. security definer so the count
-- sees the author's own recent rows even in parties whose visibility has since
-- changed underneath them.
--
-- Scoped per USER, not per (user, party) -- the opposite of chat, on purpose.
-- Chat is conversation, and talking in two rooms at once is normal. Stories
-- are uploads: the resource being protected is storage and bandwidth, which is
-- global to the account, so spreading 200 clips across 20 parties has to count
-- as 200.
--
-- Hidden rows COUNT. Hiding is the moderation response to abuse, and a limit
-- that a takedown refunds would hand the budget straight back to the abuser --
-- post 10, get hidden, post 10 more.
-- ============================================================
create or replace function public.enforce_story_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_recent int;
begin
  select count(*) into v_recent
  from public.stories s
  where s.author_id = NEW.author_id
  and s.created_at > now() - interval '1 hour';

  if v_recent >= 10 then
    raise exception 'story rate limit exceeded: 10 per hour'
      using errcode = '42501';
  end if;

  return NEW;
end;
$$;

create trigger stories_rate_limit
before insert on public.stories
for each row execute function public.enforce_story_rate_limit();


-- ============================================================
-- view_count, denormalized via trigger (CLAUDE.md #6) -- same shape as
-- sync_post_like_count (20260814112530).
--
-- No delete branch that matters: story_views rows are only ever removed by the
-- cascade when the story itself goes, and decrementing a counter on a row
-- being deleted is wasted work. It is written anyway, guarded, because a
-- future "unsee" or a GDPR erasure of one user's view history would otherwise
-- silently leave the counter high.
-- ============================================================
create or replace function public.sync_story_view_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if TG_OP = 'INSERT' then
    update public.stories set view_count = view_count + 1 where id = NEW.story_id;
    return null;
  end if;

  -- TG_OP = 'DELETE'
  update public.stories set view_count = greatest(view_count - 1, 0) where id = OLD.story_id;
  return null;
end;
$$;

create trigger story_views_sync_count
after insert or delete on public.story_views
for each row execute function public.sync_story_view_count();


-- ============================================================
-- story_upload_target -- where do my bytes go?
--
-- Called by the story-media edge function WITH THE CALLER'S JWT, so auth.uid()
-- here is the end user, not the service role. The edge function holds the
-- service key and no authorization logic whatsoever: it asks this function
-- what path to sign, and if the answer is an exception it signs nothing. That
-- is the whole point of routing it through SQL -- the rule lives next to the
-- data, in the one place every other visibility rule in this schema lives.
--
-- security definer is FORCED here, and the reason is a trap worth naming: the
-- SELECT policy below hides rows with media_uploaded_at is null, which is
-- every row at this moment in the flow -- including the caller's own. An
-- invoker-rights function would find nothing and report "not your story" about
-- a story the caller just created. The same wall makes `insert ... returning
-- media_path` impossible, since RETURNING is a READ and goes through the same
-- policy; that is why creation is a bare insert and the path is fetched here.
--
-- Every narrowing term is deliberate:
--   author_id = auth.uid()      only the author uploads their own bytes
--   media_uploaded_at is null   an upload URL is one-shot; once confirmed, a
--                               second signature would let the media under a
--                               story swap after people have seen it
--   hidden_at is null           a moderated story does not get to be refilled
--   expires_at > now()          nor does a dead one
-- ============================================================
create or replace function public.story_upload_target(p_story_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  v_path text;
begin
  select s.media_path into v_path
  from public.stories s
  where s.id = p_story_id
  and s.author_id = (select auth.uid())
  and s.media_uploaded_at is null
  and s.hidden_at is null
  and s.expires_at > now();

  if v_path is null then
    raise exception 'no pending upload for story %', p_story_id
      using errcode = '42501';
  end if;

  return v_path;
end;
$$;


-- ============================================================
-- confirm_story_upload -- the row becomes visible here, and only here.
--
-- It does NOT take the client's word that the upload happened. It checks
-- storage.objects for the exact path, so "visible" implies "the bytes are
-- really in the bucket". Without that check a client could skip the PUT
-- entirely and publish a story that renders as a broken frame on every phone
-- that opens it -- and, worse, the frame would be unfixable, since
-- story_upload_target refuses to re-sign a confirmed row.
--
-- Reading storage.objects is the other half of why this is definer: that table
-- has RLS on and story-media has zero policies, so no client role can see a
-- single row in it.
-- ============================================================
create or replace function public.confirm_story_upload(p_story_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_path text;
begin
  select s.media_path into v_path
  from public.stories s
  where s.id = p_story_id
  and s.author_id = (select auth.uid())
  and s.media_uploaded_at is null
  and s.hidden_at is null
  and s.expires_at > now();

  if v_path is null then
    raise exception 'no pending upload for story %', p_story_id
      using errcode = '42501';
  end if;

  if not exists (
    select 1 from storage.objects o
    where o.bucket_id = 'story-media'
    and o.name = v_path
  ) then
    raise exception 'no media uploaded for story %', p_story_id
      using errcode = 'P0002';
  end if;

  update public.stories
  set media_uploaded_at = now()
  where id = p_story_id;
end;
$$;


-- ============================================================
-- Soft delete, in the shape 20260814112530 established: an RPC, never a client
-- UPDATE (CLAUDE.md gotcha #3). On UPDATE Postgres applies the SELECT policy
-- to the NEW row whenever the statement needs read access, and the policy
-- below says `hidden_at is null` -- so a client-side soft-delete always
-- produces a row the client may no longer read and is rejected. The definer
-- function is the way out, and it lets stories carry no UPDATE grant at all.
--
-- Author or host, matching can_moderate_message. The host is responsible for
-- what appears under their party's name, so they can take a guest's story down
-- without waiting on a report.
-- ============================================================
create or replace function public.can_moderate_story(p_story_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1
    from public.stories s
    join public.parties p on p.id = s.party_id
    where s.id = p_story_id
    and (
      s.author_id = (select auth.uid())
      or p.host_id = (select auth.uid())
    )
  );
$$;

-- `and hidden_at is null` makes hiding one-way: a second call cannot overwrite
-- the original hidden_by/hidden_reason, so an author cannot paper over a
-- host's take-down under their own name. Authorization is checked BEFORE the
-- hidden_at filter, deliberately -- an unauthorized caller gets the same 42501
-- whether or not the row is already down, so this cannot be used to probe what
-- exists.
--
-- Note what hiding does NOT do: delete the object. It makes the row eligible
-- for public.purge_story_media() (part 3), which is the single code path that
-- removes bytes from the bucket, no matter what put the row in this state --
-- moderation, expiry, or an abandoned upload. One deleter, one place to get it
-- right.
create or replace function public.hide_story(p_story_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.can_moderate_story(p_story_id) then
    raise exception 'not authorized to hide story %', p_story_id
      using errcode = '42501';
  end if;

  update public.stories
  set hidden_at = now(),
      hidden_by = (select auth.uid()),
      hidden_reason = p_reason
  where id = p_story_id
  and hidden_at is null;
end;
$$;


-- ============================================================
-- RLS
-- ============================================================
alter table public.stories enable row level security;
alter table public.story_views enable row level security;

-- The four narrowing terms, in the order they cost:
--   hidden_at is null            moderated or expired -- gone for everyone,
--                                author included, no moderator-shaped hole
--   media_uploaded_at is not null  reserved but empty -- nothing to render
--   expires_at > now()           the story is over. This is what makes expiry
--                                immediate at READ time rather than whenever
--                                the cron next runs: the job is a storage
--                                collector, not the thing that enforces the
--                                24h. A cron outage must never extend a
--                                story's life.
--   can_access_party + is_blocked  the actual visibility rule, inherited
create policy "Stories are viewable by anyone who can see the party"
on public.stories for select
using (
  hidden_at is null
  and media_uploaded_at is not null
  and expires_at > now()
  and public.can_access_party(party_id)
  and not public.is_blocked((select auth.uid()), author_id)
);

-- No `media_uploaded_at is null` term here even though it is always null at
-- insert: the column has no insert grant, so it cannot be anything else, and a
-- policy term that restates a grant is a second place to keep in step.
create policy "Party members can post stories"
on public.stories for insert to authenticated
with check (
  author_id = (select auth.uid())
  and hidden_at is null
  and public.can_access_party(party_id)
);

-- No UPDATE policy and no DELETE policy. Confirming an upload goes through
-- public.confirm_story_upload, taking one down goes through public.hide_story,
-- and the bytes go through the part 3 purge. Hard delete is reserved for
-- Phase 9 account/GDPR erasure (CLAUDE.md #7).

-- You may record a view of a story you can see -- and the `exists` here
-- evaluates public.stories under the CALLER's RLS, so "can see" means exactly
-- what the SELECT policy above says, with no second copy of it. Recording a
-- view of an expired, hidden, blocked or invisible story is therefore
-- impossible rather than merely discouraged, which keeps view_count honest.
create policy "Viewers can record their own view"
on public.story_views for insert to authenticated
with check (
  user_id = (select auth.uid())
  and exists (select 1 from public.stories s where s.id = story_id)
);

-- Your own views only. The author gets the aggregate view_count on the story
-- row and NOT a per-viewer list: a "seen by" roster on a party story is a
-- surveillance feature (it tells a host exactly who was awake and looking at
-- 04:00), and shipping it is a product decision, not a schema accident. If it
-- is ever wanted, it comes as a definer RPC scoped to the author with its own
-- pgTAP negative case -- not by widening this policy.
create policy "Viewers can see their own view history"
on public.story_views for select to authenticated
using (user_id = (select auth.uid()));


-- ============================================================
-- Grants.
--
-- Nothing to anon, on either table. A story is 24h of someone's night attached
-- to a party; there is no signed-out audience for it, and the grant is the
-- honest place to say so rather than a policy that silently returns zero rows
-- (CLAUDE.md gotcha #4 -- table privileges are checked whether or not a WHERE
-- clause could ever be true, so an anon caller gets a clean "permission
-- denied" here instead of a confusing empty list from the RPCs in part 2).
--
-- The INSERT grant is column-level, which is the point: RLS gates which ROW
-- you may touch, never which COLUMN. What it makes impossible with no policy
-- and no trigger involved -- choosing your own media_path (aiming an upload at
-- another party's folder), setting expires_at (a story that never dies, or one
-- born expired to dodge moderation), pre-setting media_uploaded_at (publishing
-- a story with no bytes behind it), inflating view_count, and writing hidden_*
-- by hand instead of going through hide_story.
--
-- `id` is grantable so the client can generate the uuid and hold onto it
-- across the four-step upload handshake, the same reason messages grants it.
--
-- No UPDATE grant, on any column, on either table.
-- ============================================================
grant select on public.stories to authenticated;
grant insert (id, party_id, author_id, content_type) on public.stories to authenticated;

grant select, insert on public.story_views to authenticated;
