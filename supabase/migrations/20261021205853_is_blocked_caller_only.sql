-- Phase 46, part B: is_blocked answers only for a pair that includes the
-- caller.
--
-- is_blocked(a, b) is security definer (it has to be: the blocks SELECT policy
-- shows a user only the blocks THEY made, gotcha 19) and was executable by
-- every client role, so any signed-in user -- and, until part A, anyone at all
-- -- could ask it about any two ids and learn whether either had blocked the
-- other. A block is private to the two people in it.
--
-- The rule moves to blocked_between(a, b), the same body, held back from the
-- client roles, and the engines that ask about OTHER users call that one
-- (gotcha 11's shape: parameterise, do not copy). is_blocked keeps its
-- signature, so none of the thirteen policies that call it change, and answers
-- false unless the caller is one of the two. Audited: every policy and both
-- invoker callers (create_party_with_invites, invite_to_party, get_direct_chats)
-- pass the caller as one argument, so for them nothing changes. What is left is
-- "have I blocked X, or X me", which the caller learns anyway: their own block
-- is in their blocks rows, and the other way round is exactly what the profile
-- and DM refusals already show as "not available".
--
-- The six definer callers below move to blocked_between. Two of them need it:
-- can_user_access_party is the notification engine's per-user visibility, and
-- notify_direct_inbox asks about the author and EACH member. The other four
-- pass the caller today; they move too, so no definer body depends on
-- auth.uid() being set for its block check to mean anything. Bodies otherwise
-- as live before this migration (pg_get_functiondef).
--
-- 17_parties_policy's equivalence proof is what shows the policy copy of
-- party visibility and can_user_access_party still agree.


create function public.blocked_between(p_a uuid, p_b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
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

revoke execute on function public.blocked_between(uuid, uuid) from public, anon, authenticated;

comment on function public.blocked_between(uuid, uuid) is
  'True if either user has blocked the other. Engine-only: no client role may '
  'execute it (Phase 46). Clients and policies use is_blocked, which answers '
  'only for a pair that includes the caller.';


create or replace function public.is_blocked(p_a uuid, p_b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select auth.uid()) in (p_a, p_b)
     and public.blocked_between(p_a, p_b);
$$;

comment on function public.is_blocked(uuid, uuid) is
  'True if the caller and the other user are block-paired, in either direction. '
  'False for any pair that does not include the caller (Phase 46), so it is not '
  'a block oracle. Engines asking about other users call blocked_between.';


CREATE OR REPLACE FUNCTION public.can_user_access_party(p_user_id uuid, p_party_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1
    from public.parties p
    where p.id = p_party_id
    and not public.blocked_between(p_user_id, p.host_id)
    and (
      not p.is_private
      or p.host_id = p_user_id
      or exists (
        select 1
        from public.invitations i
        where i.party_id = p.id
        and i.guest_id = p_user_id
      )
    )
  );
$function$;



CREATE OR REPLACE FUNCTION public.notify_direct_inbox()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_low uuid;
  v_high uuid;
  v_member uuid;
begin
  if TG_OP = 'UPDATE' then
    -- Only the hide transition is news; every other UPDATE is not.
    if not ((OLD.hidden_at is null) and (NEW.hidden_at is not null)) then
      return null;
    end if;
  end if;

  select t.user_low, t.user_high into v_low, v_high
  from public.direct_threads t
  where t.id = NEW.thread_id;

  foreach v_member in array array[v_low, v_high] loop
    if v_member is null then
      continue;
    end if;
    if v_member <> NEW.author_id and public.blocked_between(NEW.author_id, v_member) then
      continue;
    end if;

    perform realtime.send(
      jsonb_build_object('thread_id', NEW.thread_id),
      'dm_activity',
      public.inbox_topic(v_member),
      true
    );
  end loop;

  return null;
end;
$function$;



CREATE OR REPLACE FUNCTION public.can_send_direct_message(p_thread_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(
    (select not public.blocked_between((select auth.uid()), peer.id)
        and exists (
          select 1 from public.profiles pr
          where pr.id = peer.id and pr.deleted_at is null
        )
        and (
          public.accepts_dm_from(peer.id, (select auth.uid()))
          or exists (
            select 1 from public.direct_messages m
            where m.thread_id = p_thread_id
              and m.author_id = peer.id
          )
        )
     from (select public.direct_thread_peer(p_thread_id) as id) peer
     where peer.id is not null),
    false
  );
$function$;



CREATE OR REPLACE FUNCTION public.can_view_direct_thread(p_thread_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(
    (select not public.blocked_between((select auth.uid()), peer.id)
     from (select public.direct_thread_peer(p_thread_id) as id) peer
     where peer.id is not null),
    false
  );
$function$;



CREATE OR REPLACE FUNCTION public.get_or_create_direct_thread(p_other_user_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_me uuid := (select auth.uid());
  v_low uuid;
  v_high uuid;
  v_id uuid;
begin
  if v_me is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  if p_other_user_id is null
     or p_other_user_id = v_me
     or public.blocked_between(v_me, p_other_user_id) then
    raise exception 'cannot message this user' using errcode = '42501';
  end if;

  v_low  := least(v_me, p_other_user_id);
  v_high := greatest(v_me, p_other_user_id);

  select t.id into v_id
  from public.direct_threads t
  where t.user_low = v_low and t.user_high = v_high;

  if v_id is not null then
    return v_id;
  end if;

  if not public.accepts_dm_from(p_other_user_id, v_me) then
    raise exception 'cannot message this user' using errcode = '42501';
  end if;

  if (select count(*) from public.direct_threads t
      where t.created_by = v_me
        and t.created_at > now() - interval '1 hour') >= 30 then
    raise exception 'direct thread rate limit exceeded' using errcode = '42501';
  end if;

  insert into public.direct_threads (user_low, user_high, created_by)
  values (v_low, v_high, v_me)
  on conflict on constraint direct_threads_pair_key do nothing
  returning id into v_id;

  if v_id is null then
    select t.id into v_id
    from public.direct_threads t
    where t.user_low = v_low and t.user_high = v_high;
  end if;

  return v_id;
end;
$function$;



CREATE OR REPLACE FUNCTION public.redeem_party_invite(p_token text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := (select auth.uid());
  v_link public.party_invite_links;
  v_party public.parties;
begin
  if v_uid is null or p_token is null or p_token !~ '^[A-Za-z0-9_-]{43}$' then
    raise exception 'invite link not valid' using errcode = '42501';
  end if;

  select l.* into v_link
  from public.party_invite_links l
  where l.token_hash = public.party_invite_token_hash(p_token)
    and l.revoked_at is null
  for update;

  if not found then
    raise exception 'invite link not valid' using errcode = '42501';
  end if;

  select p.* into v_party from public.parties p where p.id = v_link.party_id;

  if v_party.status <> 'published'
     or public.party_is_past(v_party.starts_at, v_party.ends_at)
     or v_party.host_id = v_uid
     or public.blocked_between(v_party.host_id, v_uid)
     or exists (
       select 1 from public.profiles pr
       where pr.id = v_uid and pr.deleted_at is not null
     )
     or exists (
       select 1 from public.party_guest_removals g
       where g.party_id = v_party.id and g.user_id = v_uid
     )
  then
    raise exception 'invite link not valid' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.invitations i
    where i.party_id = v_party.id and i.guest_id = v_uid
  ) then
    return v_party.id;
  end if;

  if v_link.max_uses is not null and v_link.use_count >= v_link.max_uses then
    raise exception 'invite link not valid' using errcode = '42501';
  end if;

  insert into public.invitations (party_id, guest_id, via_link_id)
  values (v_party.id, v_uid, v_link.id);

  update public.party_invite_links
  set use_count = use_count + 1
  where id = v_link.id;

  return v_party.id;
end;
$function$;

