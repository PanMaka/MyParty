-- Phase 33: 1-on-1 direct messages.
--
-- Separate tables, not a `type` column on public.messages. Group chat has no
-- conversation table to put a type on: the PARTY is the conversation, and
-- membership is derived from can_access_party, not stored. Making
-- messages.party_id nullable would turn every policy, the realtime topic
-- policy, the rate limit, hide_message, get_party_chats and the export into
-- two-armed ORs -- and can_chat_in_party carries a "a revert must restore this
-- clause or public chat becomes world-writable" warning that is exactly the
-- kind of rule a shared table makes easier to break. So DMs get their own three
-- tables, built in the same shapes (keyset index, soft-hide triple, immutable
-- rows, column-scoped insert, broadcast from database), and the client shares
-- the chat UI instead of the schema sharing a table.
--
-- The rules, each stated once (CLAUDE.md #4):
--
--   accepts_dm_from(recipient, sender)  the recipient's dm_policy, nothing else
--   direct_thread_peer(thread)          the OTHER member, NULL if I am not one
--   is_direct_thread_member(thread)     membership -- read side
--   can_view_direct_thread(thread)      membership minus a block -- realtime
--   can_send_direct_message(thread)     the write rule, composing the above
--
-- A block overrides dm_policy everywhere: no new thread, no send, no topic
-- join, and the peer's messages leave the SELECT policy -- in threads that
-- existed before the block too. Every refusal reads the same ("cannot message
-- this user", 42501), so the caller cannot tell a block from a policy from a
-- deleted account.


-- ============================================================
-- 1. dm_policy -- who may START a conversation with me.
--
-- Same direction as invite_policy, NOT map_visibility (gotcha 14):
-- 'following' means people I follow (follows.follower_id = me). "Anyone who
-- follows me may DM me" would be the spam vector, since following is
-- unilateral.
--
-- Default 'everyone' is a product decision (2026-10-09), and it is why the
-- client ships a Block button in the same phase: with an open default, a block
-- is the remedy and it has to be reachable.
--
-- Client-writable through the existing table-wide `update` grant on profiles,
-- like invite_policy -- it is the user's own preference.
-- ============================================================
create type public.dm_policy as enum ('everyone', 'following', 'nobody');

alter table public.profiles
  add column dm_policy public.dm_policy not null default 'everyone';

comment on column public.profiles.dm_policy is
  'Who may start a direct-message thread with this user. ''following'' means people THEY follow (follows.follower_id = this user), the same direction as invite_policy. A block overrides it. Enforced in get_or_create_direct_thread and can_send_direct_message.';

-- Definer for gotcha 1: it reads ANOTHER user's block-filtered profiles row.
-- Under invoker rights a recipient who blocked the sender would read as "no
-- such row". Returns false for a missing or soft-deleted recipient, which is
-- the safe direction for a write gate. Deliberately says nothing about blocks:
-- that is is_blocked's question, composed in can_send_direct_message.
create or replace function public.accepts_dm_from(p_recipient_id uuid, p_sender_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1
    from public.profiles pr
    where pr.id = p_recipient_id
      and pr.deleted_at is null
      and (
        pr.dm_policy = 'everyone'
        or (
          pr.dm_policy = 'following'
          and exists (
            select 1
            from public.follows f
            where f.follower_id = p_recipient_id
              and f.followee_id = p_sender_id
          )
        )
      )
  );
$$;

comment on function public.accepts_dm_from(uuid, uuid) is
  'True if the recipient''s dm_policy admits this sender and the recipient has not requested deletion. Does not consider blocks -- callers compose is_blocked.';


-- ============================================================
-- 2. direct_threads -- one row per PAIR, forever.
--
-- Uniqueness is structural: the pair is stored ordered (user_low < user_high),
-- so A->B and B->A are the same key and the unique constraint admits one
-- thread. The check also makes a thread with yourself unrepresentable.
--
-- No client write grant at all. The only writer is get_or_create_direct_thread,
-- which is what lets the pair rule, dm_policy and the creation rate limit live
-- in one place instead of in an INSERT policy a client could probe.
--
-- FKs into profiles are `no action`, per Phase 9: profiles rows are never
-- deleted (they become tombstones), and the thread has to outlive an erased
-- member for the same reason messages.author_id does.
--
-- last_message_at is maintained by trigger (CLAUDE.md #6) and is the list's
-- keyset column. NULL means "opened but never written in", and such threads
-- are not listed -- tapping Message and backing out leaves nothing behind.
-- ============================================================
create table public.direct_threads (
  id uuid default gen_random_uuid() primary key,
  user_low uuid not null references public.profiles(id),
  user_high uuid not null references public.profiles(id),
  created_by uuid not null references public.profiles(id),
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  last_message_at timestamp with time zone,
  constraint direct_threads_ordered_pair check (user_low < user_high),
  constraint direct_threads_creator_is_member check (created_by in (user_low, user_high)),
  constraint direct_threads_pair_key unique (user_low, user_high)
);

-- The pair key covers user_low's FK. Each member's list is one index range,
-- keyset-ordered the way get_direct_chats reads it (CLAUDE.md #5).
create index direct_threads_low_activity_idx
  on public.direct_threads (user_low, last_message_at desc, id desc);
create index direct_threads_high_activity_idx
  on public.direct_threads (user_high, last_message_at desc, id desc);
-- The creation rate limit.
create index direct_threads_created_by_idx
  on public.direct_threads (created_by, created_at);


-- ============================================================
-- 3. direct_messages -- public.messages' shape, keyed on a thread.
-- ============================================================
create table public.direct_messages (
  id uuid default gen_random_uuid() primary key,
  thread_id uuid not null references public.direct_threads(id) on delete cascade,
  author_id uuid not null references public.profiles(id),
  body text not null,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  hidden_at timestamp with time zone,
  hidden_by uuid references public.profiles(id),
  hidden_reason text,
  constraint direct_messages_body_not_blank check (length(btrim(body)) > 0),
  constraint direct_messages_body_length check (length(body) <= 2000),
  constraint direct_messages_hidden_consistent check (hidden_by is null or hidden_at is not null)
);

create index direct_messages_thread_created_idx
  on public.direct_messages (thread_id, created_at desc, id desc)
  where hidden_at is null;

-- export_account_data and the "has the peer ever written here" probe in
-- can_send_direct_message. Not partial, for the export's sake -- same call as
-- messages_author_created_idx.
create index direct_messages_author_created_idx
  on public.direct_messages (author_id, created_at);


-- ============================================================
-- 4. direct_reads -- the unread watermark, party_reads' shape.
-- ============================================================
create table public.direct_reads (
  thread_id uuid not null references public.direct_threads(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  last_read_at timestamp with time zone default timezone('utc'::text, now()) not null,
  primary key (thread_id, user_id)
);

-- complete_account_erasure deletes by user.
create index direct_reads_user_id_idx on public.direct_reads (user_id);

-- Monotonic, never in the future. The function is party_reads' and generic
-- over last_read_at, so it is reused rather than copied.
create trigger direct_reads_clamp
before insert or update on public.direct_reads
for each row execute function public.clamp_last_read_at();


-- ============================================================
-- 5. The helpers.
--
-- All definer + empty search_path (rule 3): they read direct_threads,
-- direct_messages and profiles rows the caller may not SELECT, and return only
-- a boolean or the peer id the caller already knows.
--
-- Bound to auth.uid() on purpose. Nothing fans out over DMs (no push this
-- phase), so there is no engine that would need a per-user variant; if push
-- arrives, gotcha 11 applies and these get parameterised the way
-- can_user_access_party was.
-- ============================================================
create or replace function public.direct_thread_peer(p_thread_id uuid)
returns uuid
language sql
security definer
set search_path = ''
stable
as $$
  select case
           when t.user_low  = (select auth.uid()) then t.user_high
           when t.user_high = (select auth.uid()) then t.user_low
         end
  from public.direct_threads t
  where t.id = p_thread_id;
$$;

create or replace function public.is_direct_thread_member(p_thread_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select public.direct_thread_peer(p_thread_id) is not null;
$$;

-- The topic gate. Membership minus a block, so a block also refuses the
-- channel join for a thread that existed before it.
create or replace function public.can_view_direct_thread(p_thread_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select coalesce(
    (select not public.is_blocked((select auth.uid()), peer.id)
     from (select public.direct_thread_peer(p_thread_id) as id) peer
     where peer.id is not null),
    false
  );
$$;

-- THE write rule. A member may send when:
--   * neither has blocked the other -- overrides everything below;
--   * the peer has not requested deletion (a tombstone is not a recipient);
--   * and the peer either admits me under their dm_policy NOW, or has written
--     in this thread themselves.
--
-- The last arm is what makes dm_policy a gate on STRANGERS rather than on
-- conversations. Without it, switching to 'nobody' would silence every thread
-- you are actively in -- including replies to people YOU messaged first. With
-- it, 'nobody' still stops a thread the peer has never written in, which is
-- the case that matters: a thread opened (and so created) while your policy
-- was 'everyone' is not a standing licence to message you after you change it.
create or replace function public.can_send_direct_message(p_thread_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select coalesce(
    (select not public.is_blocked((select auth.uid()), peer.id)
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
$$;


-- ============================================================
-- 6. get_or_create_direct_thread -- the only door into direct_threads.
--
-- Concurrency: two members tapping Message at the same instant both reach the
-- insert; `on conflict do nothing` lets one win and the other falls through to
-- the re-read. Both get the same id.
--
-- An EXISTING thread opens for anyone not blocked, whatever dm_policy now
-- says: your own history is yours to read, and whether you may still WRITE is
-- can_send_direct_message's question, asked on the insert. A NEW thread needs
-- accepts_dm_from as well.
--
-- Every refusal raises the same text and errcode. Self, unknown id, deleted,
-- blocked either way, policy -- all indistinguishable, which is the same no-
-- oracle rule the profile screen already follows for blocks.
--
-- Rate limit: 30 new threads per hour per creator. Opening an existing thread
-- costs nothing. Counted here rather than in a trigger because this function
-- is the only writer.
-- ============================================================
create or replace function public.get_or_create_direct_thread(p_other_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
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
     or public.is_blocked(v_me, p_other_user_id) then
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
$$;


-- ============================================================
-- 7. Triggers: rate limit, activity stamp.
-- ============================================================

-- 20 per 10 seconds per (author, thread) -- the group-chat number. A BEFORE
-- ROW trigger sees its own statement's earlier rows (gotcha 18), so an array
-- insert cannot walk past it.
create or replace function public.enforce_direct_message_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_recent int;
begin
  select count(*) into v_recent
  from public.direct_messages m
  where m.author_id = NEW.author_id
    and m.thread_id = NEW.thread_id
    and m.created_at > now() - interval '10 seconds';

  if v_recent >= 20 then
    raise exception 'message rate limit exceeded for thread %', NEW.thread_id
      using errcode = '42501';
  end if;

  return NEW;
end;
$$;

create trigger direct_messages_rate_limit
before insert on public.direct_messages
for each row execute function public.enforce_direct_message_rate_limit();

-- greatest() so an out-of-order commit cannot move the list ordering
-- backwards. Hiding a message does not rewind it: the thread had activity
-- then, and recomputing on hide would need a scan for no visible gain.
create or replace function public.touch_direct_thread()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.direct_threads
  set last_message_at = greatest(coalesce(last_message_at, NEW.created_at), NEW.created_at)
  where id = NEW.thread_id;

  return null;
end;
$$;

create trigger direct_messages_touch_thread
after insert on public.direct_messages
for each row execute function public.touch_direct_thread();


-- ============================================================
-- 8. Soft delete. Author only -- a DM has no host. A recipient hiding a line
-- would delete it from the SENDER's history too, which is a moderation power
-- nobody in a two-person thread should hold over the other; block and report
-- are the recipient's tools. Same one-way, check-before-filter shape as
-- hide_message, and the same reason it is an RPC (gotcha 3).
-- ============================================================
create or replace function public.hide_direct_message(p_message_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.direct_messages m
    where m.id = p_message_id
      and m.author_id = (select auth.uid())
  ) then
    raise exception 'not authorized to hide message %', p_message_id
      using errcode = '42501';
  end if;

  update public.direct_messages
  set hidden_at = now(),
      hidden_by = (select auth.uid()),
      hidden_reason = p_reason
  where id = p_message_id
    and hidden_at is null;
end;
$$;


-- ============================================================
-- 9. Realtime: broadcast from database on dm:{uuid}.
--
-- Same mechanism and same two-halves rule as 20260815095448: the trigger
-- builds the topic with direct_thread_topic, the policy parses it back with
-- direct_thread_id_from_topic, and the full-uuid regex keeps the parse total
-- so a malformed topic fails closed instead of raising inside the policy.
--
-- Event names match the party channel ('new_message', 'message_hidden') so the
-- client's channel handling is shared; the payload carries thread_id where the
-- party one carries party_id.
-- ============================================================
create or replace function public.direct_thread_topic(p_thread_id uuid)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'dm:' || p_thread_id::text;
$$;

create or replace function public.direct_thread_id_from_topic(p_topic text)
returns uuid
language sql
immutable
set search_path = ''
as $$
  select nullif(
    substring(
      p_topic
      from '^dm:([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$'
    ),
    ''
  )::uuid;
$$;

create or replace function public.broadcast_direct_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_username text;
begin
  select p.username into v_username
  from public.profiles p
  where p.id = NEW.author_id;

  perform realtime.send(
    jsonb_build_object(
      'id', NEW.id,
      'thread_id', NEW.thread_id,
      'author_id', NEW.author_id,
      'author_username', v_username,
      'body', NEW.body,
      'created_at', NEW.created_at
    ),
    'new_message',
    public.direct_thread_topic(NEW.thread_id),
    true
  );

  return null;
end;
$$;

create trigger direct_messages_broadcast_insert
after insert on public.direct_messages
for each row execute function public.broadcast_direct_message();

create or replace function public.broadcast_direct_message_hidden()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (NEW.hidden_at is null) is distinct from (OLD.hidden_at is null)
     and NEW.hidden_at is not null then
    perform realtime.send(
      jsonb_build_object('id', NEW.id, 'thread_id', NEW.thread_id),
      'message_hidden',
      public.direct_thread_topic(NEW.thread_id),
      true
    );
  end if;

  return null;
end;
$$;

create trigger direct_messages_broadcast_hide
after update on public.direct_messages
for each row execute function public.broadcast_direct_message_hidden();

-- A SECOND select policy beside the party one; permissive policies OR. Each
-- parses only its own prefix, so a dm: topic is NULL to party_id_from_topic
-- and vice versa -- neither policy can admit the other's channel.
--
-- Still no INSERT policy on realtime.messages (see 20260815095448): the
-- trigger is the only writer, so a DM that never passed the rate limit or the
-- block check cannot be broadcast.
create policy "Direct thread members can join their thread topic"
on realtime.messages for select to authenticated
using (
  extension = 'broadcast'
  and public.can_view_direct_thread(public.direct_thread_id_from_topic(realtime.topic()))
);


-- ============================================================
-- 10. RLS.
-- ============================================================
alter table public.direct_threads enable row level security;
alter table public.direct_messages enable row level security;
alter table public.direct_reads enable row level security;

create policy "Members can see their direct threads"
on public.direct_threads for select to authenticated
using ( public.is_direct_thread_member(id) );
-- No INSERT/UPDATE/DELETE policy: get_or_create_direct_thread and the touch
-- trigger are the only writers.

-- The author block term is gotcha 2's, and in a two-person thread it is the
-- whole block story on the read side: the peer IS the only other author, so
-- a block hides their side of every thread, existing ones included. Your own
-- lines stay readable to you.
create policy "Members can read direct messages"
on public.direct_messages for select to authenticated
using (
  hidden_at is null
  and public.is_direct_thread_member(thread_id)
  and not public.is_blocked((select auth.uid()), author_id)
);

create policy "Members can send direct messages"
on public.direct_messages for insert to authenticated
with check (
  author_id = (select auth.uid())
  and hidden_at is null
  and public.can_send_direct_message(thread_id)
);
-- No UPDATE/DELETE policy: immutable; hide_direct_message is the take-down.

create policy "Users can read their own direct read state"
on public.direct_reads for select to authenticated
using ( user_id = (select auth.uid()) );

-- Unlike party_reads, membership is checked: party participation can change
-- under a read row, DM membership never does, so the check costs nothing and
-- keeps junk rows out.
create policy "Members can create their own direct read state"
on public.direct_reads for insert to authenticated
with check (
  user_id = (select auth.uid())
  and public.is_direct_thread_member(thread_id)
);

create policy "Users can move their own direct read state"
on public.direct_reads for update to authenticated
using ( user_id = (select auth.uid()) )
with check ( user_id = (select auth.uid()) );


-- ============================================================
-- 11. Read RPCs. Invoker rights, so the policies above do the filtering --
-- the same shape as get_messages / get_party_chats.
-- ============================================================
create or replace function public.get_direct_messages(
  p_thread_id uuid,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit int default 30
)
returns table (
  id uuid,
  thread_id uuid,
  author_id uuid,
  author_username text,
  body text,
  created_at timestamptz
)
language sql
stable
set search_path = public, extensions
as $$
  select m.id, m.thread_id, m.author_id, pr.username, m.body, m.created_at
  from public.direct_messages m
  join public.profiles pr on pr.id = m.author_id
  where m.thread_id = p_thread_id
    and (
      p_before_created_at is null
      or (m.created_at, m.id) < (p_before_created_at,
                                 coalesce(p_before_id, '00000000-0000-0000-0000-000000000000'::uuid))
    )
  order by m.created_at desc, m.id desc
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

-- The Direct tab. Unbounded per user, so keyset-paginated on the thread's
-- (last_message_at, id) -- returned as activity_at for the client to echo
-- back. activity_at can be later than last_message_at when the newest line
-- was hidden; the preview shows the newest VISIBLE line, the ordering does not
-- rewind (see touch_direct_thread).
--
-- Two index arms rather than `me in (user_low, user_high)`, which no single
-- index can answer.
--
-- The unread count leaves out your own messages (group chat's does not). The
-- count is capped at 100 like get_party_chats; the client shows "99+".
create or replace function public.get_direct_chats(
  p_before_activity_at timestamptz default null,
  p_before_id uuid default null,
  p_limit int default 30
)
returns table (
  thread_id uuid,
  peer_id uuid,
  peer_username text,
  peer_avatar_path text,
  last_message_body text,
  last_message_author_id uuid,
  last_message_at timestamptz,
  activity_at timestamptz,
  unread_count int
)
language sql
stable
set search_path = public, extensions
as $$
  with mine as (
    select t.id, t.user_low, t.user_high, t.last_message_at
    from public.direct_threads t
    where t.user_low = (select auth.uid()) and t.last_message_at is not null
    union all
    select t.id, t.user_low, t.user_high, t.last_message_at
    from public.direct_threads t
    where t.user_high = (select auth.uid()) and t.last_message_at is not null
  )
  select
    t.id as thread_id,
    peer.id as peer_id,
    peer.username as peer_username,
    peer.avatar_path as peer_avatar_path,
    lm.body as last_message_body,
    lm.author_id as last_message_author_id,
    lm.created_at as last_message_at,
    t.last_message_at as activity_at,
    coalesce(unread.n, 0)::int as unread_count
  from mine t
  -- Inner join under invoker rights: the profiles policy is block-filtered, so
  -- this already drops a blocked peer. The explicit is_blocked term below says
  -- it out loud rather than depending on another table's policy.
  join public.profiles peer
    on peer.id = case when t.user_low = (select auth.uid()) then t.user_high else t.user_low end
  left join lateral (
    select m.body, m.author_id, m.created_at
    from public.direct_messages m
    where m.thread_id = t.id
    order by m.created_at desc, m.id desc
    limit 1
  ) lm on true
  left join public.direct_reads rd
    on rd.thread_id = t.id and rd.user_id = (select auth.uid())
  left join lateral (
    select count(*) as n
    from (
      select 1
      from public.direct_messages m
      where m.thread_id = t.id
        and m.author_id <> (select auth.uid())
        and m.created_at > coalesce(rd.last_read_at, '-infinity'::timestamp with time zone)
      limit 100
    ) capped
  ) unread on true
  where (select auth.uid()) is not null
    and not public.is_blocked((select auth.uid()), peer.id)
    and (
      p_before_activity_at is null
      or (t.last_message_at, t.id) < (p_before_activity_at,
                                      coalesce(p_before_id, '00000000-0000-0000-0000-000000000000'::uuid))
    )
  order by t.last_message_at desc, t.id desc
  limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;


-- ============================================================
-- 12. Grants. Defaults are closed (20261004234903), the revoke is gotcha 9's
-- habit anyway. Every row here has a twin in 27_explicit_grants.test.sql.
-- ============================================================
revoke all on public.direct_threads  from anon, authenticated;
revoke all on public.direct_messages from anon, authenticated;
revoke all on public.direct_reads    from anon, authenticated;

grant select on public.direct_threads to authenticated;

-- id is grantable for the same reason as messages.id: the optimistic send
-- renders under the id it will be stored with, so the broadcast echo dedupes.
grant select on public.direct_messages to authenticated;
grant insert (id, thread_id, author_id, body) on public.direct_messages to authenticated;

grant select on public.direct_reads to authenticated;
grant insert (thread_id, user_id, last_read_at) on public.direct_reads to authenticated;
grant update (last_read_at) on public.direct_reads to authenticated;

-- The client-facing RPCs. Revoked from PUBLIC so anon is refused outright
-- (gotcha 4); service_role keeps nothing it does not need.
revoke execute on function public.get_or_create_direct_thread(uuid) from public;
revoke execute on function public.get_direct_messages(uuid, timestamptz, uuid, int) from public;
revoke execute on function public.get_direct_chats(timestamptz, uuid, int) from public;
revoke execute on function public.hide_direct_message(uuid, text) from public;

grant execute on function public.get_or_create_direct_thread(uuid) to authenticated;
grant execute on function public.get_direct_messages(uuid, timestamptz, uuid, int) to authenticated;
grant execute on function public.get_direct_chats(timestamptz, uuid, int) to authenticated;
grant execute on function public.hide_direct_message(uuid, text) to authenticated;

-- The policy helpers (accepts_dm_from, direct_thread_peer,
-- is_direct_thread_member, can_view_direct_thread, can_send_direct_message,
-- the topic pair) keep PUBLIC's default EXECUTE, like is_blocked and
-- can_chat_in_party: policies evaluate them as the caller.
