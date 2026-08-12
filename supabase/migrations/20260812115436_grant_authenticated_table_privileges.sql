-- 20260709120643_RLS.sql enabled RLS and added policies for
-- profiles/parties/invitations, but never granted the underlying table
-- privileges to anon/authenticated. RLS only filters rows on top of a
-- grant that already permits the statement; without the grant, every
-- query is rejected before a policy is even evaluated. This migration
-- adds exactly the privileges the existing policies already declare —
-- no new visibility logic, just the privilege layer the policies assume.

-- profiles: "Profiles are viewable by everyone" (select, no role limit),
-- "Users can update own profile" (update, to authenticated).
grant select on public.profiles to anon, authenticated;
grant update on public.profiles to authenticated;

-- parties: "...viewable based on privacy and invitations" (select, no
-- role limit), "Users can create parties" / "Hosts can update own
-- parties" / "Hosts can delete own parties" (to authenticated).
grant select on public.parties to anon, authenticated;
grant insert, update, delete on public.parties to authenticated;

-- invitations: "Hosts can view guest lists..." (select, to authenticated),
-- "Hosts can invite guests" (insert, to authenticated).
grant select, insert on public.invitations to authenticated;
