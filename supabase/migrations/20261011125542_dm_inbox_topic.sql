-- Phase 34b: a per-user inbox topic, so the Direct list learns about a thread
-- it is not already holding a topic for.
--
-- Phase 34a keeps the Direct tab live over the dm:{uuid} topics of the threads
-- it lists. That cannot cover the one case that matters most: somebody writing
-- to you for the first time, in a thread that did not exist when your list
-- loaded. There is no topic you could already be holding for it.
--
-- inbox:{user_uuid} is that topic. It carries a SIGNAL, never content:
--
--   * the payload is {thread_id} and nothing else -- no body, no author, no
--     username. The client refetches get_direct_chats, so the SELECT policy on
--     direct_messages stays the only thing that decides what a member reads,
--     blocks and hidden lines included. A payload with the body in it would be
--     a second, unpoliced read path.
--   * one row per member per event, so at most two. DMs fan out to exactly the
--     two people in the thread, which is what makes a per-user topic cheap
--     here. Group chat stays on party:{uuid}: the same trick there would write
--     one row per guest for every message.
--
-- Same two-halves rule as 20260815095448 and 20261009095551: the trigger builds
-- the topic with inbox_topic, the policy parses it back with
-- inbox_user_id_from_topic, and the full-uuid regex keeps the parse total, so
-- a malformed topic is NULL and NULL = auth.uid() is never true. Fail-closed.

create or replace function public.inbox_topic(p_user_id uuid)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'inbox:' || p_user_id::text;
$$;

create or replace function public.inbox_user_id_from_topic(p_topic text)
returns uuid
language sql
immutable
set search_path = ''
as $$
  select nullif(
    substring(
      p_topic
      from '^inbox:([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$'
    ),
    ''
  )::uuid;
$$;

-- Both members are told, the author included: the author's OTHER devices have
-- a Direct list too, and the device that sent already moved its own row.
--
-- The peer is skipped while a block stands between them. Today that changes
-- nothing on insert -- can_send_direct_message refuses a blocked send, so no
-- row is ever written -- but a hide is still allowed (hiding is author-only and
-- not block-gated), and telling the blocker "something happened in the thread
-- with the person you blocked" is a signal about someone they chose to stop
-- hearing from. The list would drop the thread on refetch anyway.
create or replace function public.notify_direct_inbox()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
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
    if v_member <> NEW.author_id and public.is_blocked(NEW.author_id, v_member) then
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
$$;

create trigger direct_messages_notify_inbox_insert
after insert on public.direct_messages
for each row execute function public.notify_direct_inbox();

create trigger direct_messages_notify_inbox_hide
after update of hidden_at on public.direct_messages
for each row execute function public.notify_direct_inbox();

-- The third SELECT policy on realtime.messages, beside the party and dm ones.
-- Permissive policies OR, so this must admit nothing but the caller's own
-- inbox: each parser accepts only its own prefix, so a party: or dm: topic is
-- NULL here and an inbox: topic is NULL to theirs (asserted both ways in
-- 32_dm_inbox_topic.test.sql).
--
-- Still no INSERT policy on realtime.messages: the trigger is the only writer,
-- so nobody can push a fake "you have a message" into another user's inbox.
create policy "Users can join their own inbox topic"
on realtime.messages for select to authenticated
using (
  extension = 'broadcast'
  and public.inbox_user_id_from_topic(realtime.topic()) = (select auth.uid())
);
