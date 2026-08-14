-- First real party-creation path (HostWizardScreen is still mock-only).
-- security invoker: host_id is always the caller (never taken from
-- p_party, so a caller can't spoof another host), and both inserts still
-- go through the existing "Users can create parties" / "Hosts can invite
-- guests" RLS policies instead of opening a new privilege path. A single
-- top-level function call executes as one statement, so a failure on
-- either insert rolls back both.
--
-- The parties insert deliberately does NOT use `returning ... into`: the
-- parties SELECT policy is `can_access_party(id)`, and that function runs
-- its own `select ... from public.parties` internally. RETURNING re-checks
-- the new row against the table's SELECT policy using the snapshot from
-- the start of this command, so can_access_party's self-query can't see
-- the row it's being asked about yet and always reports it as
-- inaccessible -- Postgres then raises "new row violates row-level
-- security policy", even though the insert itself is fine. Generating the
-- id ourselves and inserting it explicitly sidesteps this entirely.

create function public.create_party_with_invites(
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
    select v_party_id, invitee_id from unnest(p_invitee_ids) as invitee_id
    on conflict (party_id, guest_id) do nothing;
  end if;

  return v_party_id;
end;
$$;
