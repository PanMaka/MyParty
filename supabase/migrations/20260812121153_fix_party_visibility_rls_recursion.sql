-- 20260709120643_RLS.sql's "parties" select policy queries
-- public.invitations, and the "invitations" select policy queries
-- public.parties right back — Postgres detects this as infinite
-- recursion on any select against either table. Fix per this project's
-- house rule (CLAUDE.md #4: one helper per visibility rule, every
-- policy/RPC calls it, never reimplements it): a security definer
-- helper computes party access directly (bypassing RLS, since it runs
-- as the tables' owner) so the policy no longer re-enters RLS on the
-- other table.

create or replace function public.can_access_party(p_party_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1
    from public.parties p
    where p.id = p_party_id
    and (
      not p.is_private
      or p.host_id = (select auth.uid())
      or exists (
        select 1
        from public.invitations i
        where i.party_id = p.id
        and i.guest_id = (select auth.uid())
      )
    )
  );
$$;

drop policy "Parties are viewable based on privacy and invitations" on public.parties;

create policy "Parties are viewable based on privacy and invitations"
on public.parties for select
using ( public.can_access_party(id) );
