-- create_party_with_invites has to survive the new invitations INSERT
-- policy. That policy now rejects an invite to anyone the host has a block
-- with, and because the RPC inserts every invitee in a single statement,
-- one blocked id would abort the whole call with 42501 -- taking the party
-- creation down with it (the function is one statement at top level, so
-- both inserts roll back).
--
-- That failure mode is wrong twice over: the host gets an error they cannot
-- act on or fix, and the error itself leaks that someone in the list
-- blocked them -- the exact fact a block exists to hide. Filtering the ids
-- out first makes creation succeed silently, which is what blocking is
-- supposed to feel like from the blocked-by side.
--
-- The RLS policy stays the real boundary: this filter is a courtesy for
-- the bulk path, and a direct insert into public.invitations is still
-- rejected. on conflict is kept for the ordinary duplicate-id case.
--
-- Everything else about the function is unchanged from 20260813095609 --
-- still security invoker, host_id still forced to the caller, id still
-- generated locally to dodge the RETURNING-vs-SELECT-policy problem
-- documented there.

create or replace function public.create_party_with_invites(
  p_party jsonb,
  p_invitee_ids uuid[] default '{}'
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_party_id uuid := gen_random_uuid();
begin
  insert into public.parties (
    id, host_id, title, description, location, starts_at, ends_at,
    is_private, is_sponsored, party_tier, max_capacity, status
  ) values (
    v_party_id,
    (select auth.uid()),
    p_party->>'title',
    p_party->>'description',
    public.st_point((p_party->>'lon')::double precision, (p_party->>'lat')::double precision)::public.geography,
    (p_party->>'starts_at')::timestamptz,
    nullif(p_party->>'ends_at', '')::timestamptz,
    coalesce((p_party->>'is_private')::boolean, false),
    coalesce((p_party->>'is_sponsored')::boolean, false),
    coalesce(p_party->>'party_tier', 'standard'),
    nullif(p_party->>'max_capacity', '')::int,
    coalesce(p_party->>'status', 'published')::public.party_status
  );

  if array_length(p_invitee_ids, 1) is not null then
    insert into public.invitations (party_id, guest_id)
    select v_party_id, invitee_id
    from unnest(p_invitee_ids) as invitee_id
    where not public.is_blocked((select auth.uid()), invitee_id)
    on conflict (party_id, guest_id) do nothing;
  end if;

  return v_party_id;
end;
$$;
