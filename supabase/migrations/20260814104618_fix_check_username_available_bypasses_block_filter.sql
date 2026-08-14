-- Cross-phase bug: neither Phase 1 nor Phase 3 is wrong on its own, but
-- together they make check_username_available lie.
--
-- Phase 1 (20260813084353) defined it as a plain `stable` function that
-- reads public.profiles, which was correct while the profiles SELECT policy
-- was `using (true)`. Phase 3 (20260814094945) narrowed that policy to
-- `not is_blocked(...)`. The function is security invoker, so it now runs
-- under the caller's RLS and cannot see the rows of anyone the caller has a
-- block with -- and reports their username as free.
--
-- The failure is concrete: profiles_username_lower_idx is a GLOBAL unique
-- index, so the client is told "available", the user picks it, and the
-- claim then dies on a constraint violation they cannot understand or work
-- around. Username uniqueness is a global fact about the system, not a
-- visibility-gated one, so this must not be filtered by RLS at all.
--
-- security definer is the fix rather than a policy change: relaxing the
-- profiles policy to expose blocked users' rows would undo the entire point
-- of Phase 3. This function leaks strictly less than that -- it answers one
-- boolean about one caller-supplied string and never returns a row, an id or
-- a profile. Note this does mean a caller can confirm that a specific
-- username exists even if its owner blocked them; that is unavoidable given
-- a global unique index, and is the same answer the signup form would have
-- to give anyway.
--
-- search_path was already pinned in the original definition; kept, per
-- CLAUDE.md rule 3, now that it actually is a definer function.

create or replace function public.check_username_available(p_username text)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select not exists (
    select 1 from public.profiles where lower(username) = lower(p_username)
  );
$$;
