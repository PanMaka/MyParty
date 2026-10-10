-- Phase 33, part 4: the list of people you have blocked, with their names.
--
-- Phase 33 ships a Block button, and with dm_policy defaulting to 'everyone'
-- a block is the main remedy. A remedy needs an undo, and there was no way to
-- reach one:
--
--   * The profiles SELECT policy hides a blocked pair from EACH OTHER
--     (is_blocked is symmetric), so the moment you block someone their profile
--     stops loading, search_profiles stops returning them, and their DM thread
--     leaves get_direct_chats.
--   * SocialRepository.fetchBlocked embeds `profiles!blocks_blocked_id_fkey`,
--     and that embed goes through the same policy -- so it has returned zero
--     rows for every block ever made. It had no caller, which is why nobody
--     noticed.
--
-- So this is a definer read (gotcha 1: it reads profiles rows the caller's
-- policy hides), and it leaks nothing: it returns only rows from blocks where
-- blocker_id = the caller -- people the caller chose to block, which the
-- blocks SELECT policy already shows them by id. What is added is the
-- username, so the list is readable. It never answers "who blocked me".
create or replace function public.get_my_blocked_accounts()
returns table (
  user_id uuid,
  username text,
  avatar_path text,
  blocked_at timestamptz
)
language sql
security definer
set search_path = ''
stable
as $$
  select b.blocked_id, pr.username, pr.avatar_path, b.created_at
  from public.blocks b
  join public.profiles pr on pr.id = b.blocked_id
  where b.blocker_id = (select auth.uid())
  order by b.created_at desc, b.blocked_id desc
  -- Bounded, like the follow lists. Nobody pages through 500 blocks; if
  -- somebody ever does, the blocks PK (blocker_id, blocked_id) plus
  -- created_at is the keyset to add.
  limit 500;
$$;

revoke execute on function public.get_my_blocked_accounts() from public;
grant execute on function public.get_my_blocked_accounts() to authenticated;
