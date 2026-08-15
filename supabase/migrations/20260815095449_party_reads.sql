-- Phase 6, part 3: read state.
--
-- One row per (user, party) holding the watermark the unread count in
-- public.get_party_chats measures against.
--
-- This is the one table in the phase that a client may UPDATE, and it is
-- allowed to be because it has no soft-delete columns. CLAUDE.md gotcha #3 --
-- the reason hide_post/hide_comment/hide_message all had to become definer
-- RPCs -- is specifically about a SELECT policy that filters on hidden_at
-- being re-applied to the NEW row. The policy here is `user_id = auth.uid()`,
-- which the new row satisfies just as well as the old one, so a plain upsert
-- works and an RPC would be ceremony.

create table public.party_reads (
  party_id uuid references public.parties(id) on delete cascade not null,
  user_id uuid references public.profiles(id) on delete cascade not null,
  last_read_at timestamp with time zone default timezone('utc'::text, now()) not null,
  primary key (party_id, user_id)
);

-- No index beyond the primary key. Every access is by the full key or by
-- (party_id, user_id) prefix from get_party_chats' lateral join, and the pk
-- serves both.


-- ============================================================
-- The watermark is monotonic and never in the future, enforced here rather
-- than trusted from the client.
--
-- Both halves matter and they fail differently. A future-dated last_read_at
-- would zero the unread badge permanently -- every message ever sent would
-- arrive already "read", and the user would simply stop being told about
-- their chats. A backwards-moving one is milder but still wrong: two devices
-- on the same account race, the slower one posts a stale timestamp, and
-- unread counts flap between them.
--
-- greatest(OLD, NEW) makes the write idempotent and order-independent, so
-- the two devices converge on the newer value no matter which lands last;
-- least(..., now()) caps it at the server clock, so the client's opinion of
-- what time it is never enters the calculation.
-- ============================================================
create or replace function public.clamp_last_read_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  NEW.last_read_at := least(NEW.last_read_at, now());

  if TG_OP = 'UPDATE' then
    NEW.last_read_at := greatest(NEW.last_read_at, OLD.last_read_at);
  end if;

  return NEW;
end;
$$;

create trigger party_reads_clamp
before insert or update on public.party_reads
for each row execute function public.clamp_last_read_at();


-- ============================================================
-- RLS -- owner only, in every direction.
--
-- No party visibility check on purpose. This row records what its owner has
-- looked at, not what they may look at; gating it on can_chat_in_party would
-- mean losing your own read state the moment a host flipped a party private,
-- and then getting a fresh unread badge for a chat you can no longer open.
-- The visibility rule belongs on the messages the count is computed FROM,
-- and that is exactly where it is.
--
-- There is no DELETE policy: read state is not something a client needs to
-- remove, and the cascade from parties/profiles handles the cases that
-- actually retire a row.
-- ============================================================
alter table public.party_reads enable row level security;

create policy "Users can read their own read state"
on public.party_reads for select to authenticated
using ( user_id = (select auth.uid()) );

create policy "Users can create their own read state"
on public.party_reads for insert to authenticated
with check ( user_id = (select auth.uid()) );

-- Both USING and WITH CHECK. USING alone would let a user move someone
-- else's watermark by targeting their row; WITH CHECK alone would let them
-- reassign their own row to another user_id.
create policy "Users can move their own read state"
on public.party_reads for update to authenticated
using ( user_id = (select auth.uid()) )
with check ( user_id = (select auth.uid()) );


-- ============================================================
-- Grants. UPDATE is column-level and names only last_read_at, so the
-- composite key cannot be rewritten after insert -- the WITH CHECK above
-- would catch a user_id change anyway, but party_id has no policy term
-- covering it and this is what stops a row being moved between parties.
-- ============================================================
grant select on public.party_reads to authenticated;
grant insert (party_id, user_id, last_read_at) on public.party_reads to authenticated;
grant update (last_read_at) on public.party_reads to authenticated;
