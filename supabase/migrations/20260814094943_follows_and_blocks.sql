-- Phase 3 social graph, Instagram-shaped: `follows` is asymmetric and is the
-- ENTIRE graph. There is deliberately no `friendships` table and no
-- are_friends() helper -- this reverses docs/backend-plan.md 3.1, which
-- argued for both; see the rewritten 3.1 in this same PR. Following someone
-- grants no private-party visibility whatsoever: that still comes only from
-- public.invitations.

create table public.follows (
  follower_id uuid references public.profiles(id) on delete cascade not null,
  followee_id uuid references public.profiles(id) on delete cascade not null,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  primary key (follower_id, followee_id),
  constraint follows_no_self_follow check (follower_id <> followee_id)
);

-- Follower/following lists are unbounded, so they page by keyset (CLAUDE.md
-- #5). There's no surrogate id to break ties on, so the composite tiebreaker
-- is the other half of the primary key: `where (created_at, follower_id) <
-- (?, ?)` walks these indexes in order.
create index follows_followee_created_idx
  on public.follows (followee_id, created_at desc, follower_id desc);
create index follows_follower_created_idx
  on public.follows (follower_id, created_at desc, followee_id desc);

-- Blocks are stored directionally (who pressed the button) but read
-- symmetrically -- see public.is_blocked below.
create table public.blocks (
  blocker_id uuid references public.profiles(id) on delete cascade not null,
  blocked_id uuid references public.profiles(id) on delete cascade not null,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  primary key (blocker_id, blocked_id),
  constraint blocks_no_self_block check (blocker_id <> blocked_id)
);

-- The primary key already serves lookups by blocker; is_blocked also probes
-- the reverse direction.
create index blocks_blocked_id_idx on public.blocks (blocked_id);

-- Denormalized follow counters (CLAUDE.md #6), never count(*) at read time.
alter table public.profiles add column follower_count int not null default 0;
alter table public.profiles add column following_count int not null default 0;


-- ============================================================
-- is_blocked: THE helper (CLAUDE.md #4). Every policy that needs a block
-- check calls this and never reimplements it.
--
-- Symmetric on purpose: one call answers both "I don't want to see them"
-- and "they don't get to see me", which is what makes a single check in
-- each policy enough.
--
-- security definer is required, not stylistic: the blocks SELECT policy
-- exposes a row only to its blocker, but policies on profiles/parties/
-- invitations/rsvps must evaluate pairs the current user does NOT own
-- (e.g. "is this party's host blocked with me" is fine, but a follower
-- list asks about pairs of two other people). Running as owner bypasses
-- blocks' RLS so the answer is always correct, while the function returns
-- only a boolean -- it never leaks who blocked whom.
--
-- Null-safe: an anonymous session has auth.uid() = null, and null must mean
-- "no block", otherwise every anon read of a public party would fail.
-- ============================================================
create or replace function public.is_blocked(p_a uuid, p_b uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select p_a is not null
     and p_b is not null
     and exists (
       select 1
       from public.blocks b
       where (b.blocker_id = p_a and b.blocked_id = p_b)
          or (b.blocker_id = p_b and b.blocked_id = p_a)
     );
$$;


-- ============================================================
-- Follow counters, same shape as public.sync_party_rsvp_counters
-- (20260813095451): security definer so the UPDATE runs as the table owner
-- and bypasses profiles' RLS -- a follow changes the OTHER user's
-- follower_count, which "Users can update own profile" would otherwise
-- reject. One UPDATE per affected row, no count(*).
-- ============================================================
create or replace function public.sync_profile_follow_counters()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if TG_OP = 'INSERT' then
    update public.profiles set following_count = following_count + 1
      where id = NEW.follower_id;
    update public.profiles set follower_count = follower_count + 1
      where id = NEW.followee_id;
    return null;
  end if;

  -- TG_OP = 'DELETE'
  update public.profiles set following_count = following_count - 1
    where id = OLD.follower_id;
  update public.profiles set follower_count = follower_count - 1
    where id = OLD.followee_id;
  return null;
end;
$$;

create trigger follows_sync_counters
after insert or delete on public.follows
for each row execute function public.sync_profile_follow_counters();


-- ============================================================
-- Blocking severs the relationship in both directions, per the product
-- rule: blocking makes them unfollow you, and the follows INSERT policy
-- below stops them following again until you unblock.
--
-- Deliberately does NOT touch invitations or rsvps: the block-aware
-- policies in the next migration already make those invisible, and
-- deleting an rsvp row here would silently decrement a host's going_count
-- for a party that still exists.
-- ============================================================
create or replace function public.purge_follows_on_block()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.follows
  where (follower_id = NEW.blocker_id and followee_id = NEW.blocked_id)
     or (follower_id = NEW.blocked_id and followee_id = NEW.blocker_id);
  return null;
end;
$$;

create trigger blocks_purge_follows
after insert on public.blocks
for each row execute function public.purge_follows_on_block();


-- ============================================================
-- follower_count/following_count are system-maintained, exactly like
-- credibility_score -- and "Users can update own profile" would happily let
-- someone PATCH their own follower_count to 1000000, since RLS gates which
-- ROW you may update, never which COLUMN. The existing
-- protect_credibility_score trigger already solved this for one column;
-- generalize it rather than adding a second trigger with the same job
-- (CLAUDE.md #4).
--
-- Also pins search_path, which the original (20260709120643) omitted.
--
-- The guard switches from auth.role() to current_user, and that is load
-- bearing rather than cosmetic. auth.role() reads the JWT claim, which is
-- still 'authenticated' inside a security definer function -- so guarding on
-- it would make this trigger overwrite sync_profile_follow_counters' own
-- increments and pin every counter at 0. current_user is the actual
-- executing role: 'authenticated' for a PostgREST write, but the function
-- owner for a security definer trigger, which is exactly the distinction
-- needed. Naming anon/authenticated explicitly (rather than "not the owner")
-- also keeps service_role able to write these columns, which the original
-- auth.role() check allowed and backfill/admin jobs will need.
-- ============================================================
create or replace function public.protect_credibility_score()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user in ('anon', 'authenticated') then
    new.credibility_score = old.credibility_score;
    new.follower_count = old.follower_count;
    new.following_count = old.following_count;
  end if;

  return new;
end;
$$;


-- ============================================================
-- RLS
-- ============================================================
alter table public.follows enable row level security;
alter table public.blocks enable row level security;

-- Follow edges and counts are public (Instagram-style public accounts).
-- Both endpoints are checked, not just one: a block deletes the edge
-- BETWEEN the two, but I could still meet someone I blocked inside a third
-- user's follower list, and "we don't appear in each other's search" has to
-- hold there too.
create policy "Follows are viewable by everyone except blocked pairs"
on public.follows for select
using (
  not public.is_blocked((select auth.uid()), follower_id)
  and not public.is_blocked((select auth.uid()), followee_id)
);

-- The second half of the block rule: you cannot follow someone you have a
-- block with, in either direction, until it is lifted.
create policy "Users can follow others they are not blocked with"
on public.follows for insert to authenticated
with check (
  follower_id = (select auth.uid())
  and not public.is_blocked((select auth.uid()), followee_id)
);

-- Unconditional on purpose: unfollowing must keep working while blocked,
-- otherwise a block strands the edge forever. Same reasoning as the rsvps
-- DELETE policy.
create policy "Users can unfollow"
on public.follows for delete to authenticated
using ( follower_id = (select auth.uid()) );

-- No UPDATE policy: a follow edge has nothing mutable.

-- Only the blocker can see, create or lift their own blocks. The blocked
-- user must never be able to enumerate who blocked them -- that is the one
-- fact a block is supposed to hide.
create policy "Users can view their own blocks"
on public.blocks for select to authenticated
using ( blocker_id = (select auth.uid()) );

create policy "Users can block others"
on public.blocks for insert to authenticated
with check ( blocker_id = (select auth.uid()) );

create policy "Users can unblock"
on public.blocks for delete to authenticated
using ( blocker_id = (select auth.uid()) );

-- No UPDATE policy: unblock + re-block, never mutate.


-- ============================================================
-- Grants. RLS only filters rows on top of a grant that already permits the
-- statement -- 20260812115436 and 20260813100309 both exist purely because
-- this step was forgotten. Exactly the privileges the policies above
-- declare, nothing more: no update on either table, since neither has an
-- UPDATE policy.
-- ============================================================
grant select on public.follows to anon, authenticated;
grant insert, delete on public.follows to authenticated;

grant select, insert, delete on public.blocks to authenticated;
