-- Party chat unread badges never cleared: ChatRepository.markRead has been
-- refused with 403 on every call since Phase 6 (docs/backlog.md 1.16, now
-- closed).
--
-- It upserted party_reads through PostgREST (`?on_conflict=party_id,user_id`,
-- `resolution=merge-duplicates`). PostgREST SETs every body key in
-- `ON CONFLICT DO UPDATE`, party_reads grants UPDATE on last_read_at alone,
-- and Postgres checks UPDATE privilege on the SET list at plan time -- so the
-- statement is refused before it knows whether a conflict exists, on the
-- first call as much as the hundredth. ChatScreen fired it unawaited and
-- swallowed the error, so the only symptom was the badge.
--
-- Same fix as mark_direct_thread_read (20261010095848): plain SQL whose SET
-- list names last_read_at only, which is exactly what the column grant
-- covers. SECURITY INVOKER, so the party_reads policies (owner only) and the
-- clamp trigger (never in the future, never backwards) stay the authority.
-- The grants are untouched -- user_id and party_id remain write-once.
create or replace function public.mark_party_read(p_party_id uuid)
returns void
language sql
security invoker
set search_path = ''
as $$
  insert into public.party_reads (party_id, user_id, last_read_at)
  values (p_party_id, (select auth.uid()), now())
  on conflict on constraint party_reads_pkey
  do update set last_read_at = excluded.last_read_at;
$$;

revoke execute on function public.mark_party_read(uuid) from public;
grant execute on function public.mark_party_read(uuid) to authenticated;
