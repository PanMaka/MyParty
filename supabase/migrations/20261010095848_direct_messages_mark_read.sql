-- Phase 33, part 3: marking a direct thread read goes through a function.
--
-- Gotcha 12, measured rather than predicted. direct_reads grants
-- `insert (thread_id, user_id, last_read_at)` but `update (last_read_at)`
-- only, so the composite key cannot be rewritten after insert. A PostgREST
-- upsert (`POST ... ?on_conflict=thread_id,user_id` with
-- `Prefer: resolution=merge-duplicates`) puts EVERY body key in the
-- `ON CONFLICT DO UPDATE SET` list, and Postgres checks UPDATE privilege on
-- that list at plan time -- so it is refused on the FIRST call, not just the
-- second. party_reads has the identical grants and the identical client call,
-- and the same request against it returns 403 today (docs/backlog.md 1.16).
--
-- In plain SQL the SET list names last_read_at alone, which is exactly the
-- column the update grant covers. SECURITY INVOKER, so the direct_reads
-- policies (owner-only, member-only insert) and the clamp trigger stay the
-- authority; the function adds no rule of its own.
create or replace function public.mark_direct_thread_read(p_thread_id uuid)
returns void
language sql
security invoker
set search_path = ''
as $$
  insert into public.direct_reads (thread_id, user_id, last_read_at)
  values (p_thread_id, (select auth.uid()), now())
  on conflict on constraint direct_reads_pkey
  do update set last_read_at = excluded.last_read_at;
$$;

revoke execute on function public.mark_direct_thread_read(uuid) from public;
grant execute on function public.mark_direct_thread_read(uuid) to authenticated;
