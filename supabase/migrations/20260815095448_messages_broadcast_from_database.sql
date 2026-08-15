-- Phase 6, part 2: realtime delivery, via BROADCAST FROM DATABASE.
--
-- Not postgres_changes, and the reason is a scaling shape rather than a
-- preference. postgres_changes re-evaluates RLS once per subscriber per
-- event: a 200-person party chat pays 200 policy evaluations for every
-- message sent, and the check that decides whether a non-invitee sees the
-- line happens in the WAL fan-out path, per delivery, forever.
--
-- Broadcast from database inverts that. A trigger writes ONE row into
-- realtime.messages, and a single RLS policy on THAT table decides who may
-- join the party:{uuid} topic at all. Authorization happens once, at
-- subscribe time, and per-message cost drops to one insert regardless of how
-- many people are listening. The non-invitee is not filtered out of the
-- fan-out -- they never get to join the channel the fan-out goes to.
--
-- The two halves below have to agree on the topic string or the whole thing
-- silently delivers nothing, so neither of them writes it by hand: the
-- trigger builds it with public.party_topic and the policy parses it back
-- with public.party_id_from_topic. One format, stated once (CLAUDE.md #4).


-- ============================================================
-- Topic naming, both directions.
--
-- party_id_from_topic returns NULL for anything that is not a party topic,
-- and the regex spells out the full uuid layout rather than a loose
-- "36 characters of hex and dashes". That is what makes the parse total: a
-- looser pattern would let a topic like `party:xxxxxxxx-xxxx-...` through to
-- the ::uuid cast, which RAISES inside the policy instead of returning
-- false. A policy that errors is not a policy that denies -- it is an error
-- surfaced to a client that was merely wrong about what it asked for.
-- Matching the exact shape means everything that parses is castable, and
-- everything else lands on NULL and fails closed.
-- ============================================================
create or replace function public.party_topic(p_party_id uuid)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'party:' || p_party_id::text;
$$;

create or replace function public.party_id_from_topic(p_topic text)
returns uuid
language sql
immutable
set search_path = ''
as $$
  select nullif(
    substring(
      p_topic
      from '^party:([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$'
    ),
    ''
  )::uuid;
$$;


-- ============================================================
-- The trigger.
--
-- security definer with a pinned search_path, and it reads the author's
-- username out of public.profiles on purpose. That table's SELECT policy has
-- been block-filtered since 20260814094945, but the filter is PER VIEWER and
-- this row is written ONCE for every subscriber on the topic -- there is no
-- single viewer whose block state it could correctly reflect. Resolving the
-- username as the definer (CLAUDE.md gotcha #1: a definer is exactly what you
-- need when the question is global rather than per-caller) writes the
-- objective fact, and the per-viewer filtering stays where it belongs: on the
-- messages SELECT policy, which is what the history fetch and the reconnect
-- gap-fill both go through.
--
-- No exception handler here, deliberately -- realtime.send already wraps its
-- own insert in one and downgrades any failure to a WARNING. So a realtime
-- outage cannot roll back a chat message the user believes they sent, which
-- is the property that matters: durability of public.messages outranks
-- delivery of the event. Adding a second handler on top would only hide the
-- warning.
--
-- `private => true` is what routes the message through the RLS check below
-- rather than an open channel, and it matches the partial index realtime
-- ships on (extension = 'broadcast' and private is true).
-- ============================================================
create or replace function public.broadcast_message()
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
      'party_id', NEW.party_id,
      'author_id', NEW.author_id,
      'author_username', v_username,
      'body', NEW.body,
      'created_at', NEW.created_at
    ),
    'new_message',
    public.party_topic(NEW.party_id),
    true
  );

  return null;
end;
$$;

create trigger messages_broadcast_insert
after insert on public.messages
for each row execute function public.broadcast_message();


-- ============================================================
-- Moderation has to reach open clients too.
--
-- "Hidden means hidden everywhere" is the invariant 20260814112530 set for
-- party_posts, and it has a realtime-shaped hole in it here that it did not
-- have there: a host hides an abusive line, it leaves the SELECT policy
-- immediately, and every phone with the chat already open keeps rendering it
-- until someone happens to reopen the screen. The take-down has to be an
-- event, not just a state change.
--
-- The payload is the id and nothing else. It is a retraction, and re-sending
-- the body to every subscriber in order to say "stop showing this body"
-- would be a strange way to honour a moderation action.
--
-- Fires only on the transition into hidden -- `is distinct from` on the
-- boolean rather than on hidden_at itself, the same guard the Phase 4
-- counter triggers use, so a no-op re-hide does not re-broadcast.
-- ============================================================
create or replace function public.broadcast_message_hidden()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (NEW.hidden_at is null) is distinct from (OLD.hidden_at is null)
     and NEW.hidden_at is not null then
    perform realtime.send(
      jsonb_build_object('id', NEW.id, 'party_id', NEW.party_id),
      'message_hidden',
      public.party_topic(NEW.party_id),
      true
    );
  end if;

  return null;
end;
$$;

create trigger messages_broadcast_hide
after update on public.messages
for each row execute function public.broadcast_message_hidden();


-- ============================================================
-- RLS on realtime.messages -- the topic authorization.
--
-- This is the policy the phase's verification bar rests on. Realtime sets
-- `realtime.topic` for the channel being joined and then asks this table
-- whether the caller may read it; realtime.topic() is how the policy sees
-- which channel is being asked about. A false here is not a filtered
-- message, it is a refused channel join -- the non-invitee's subscribe
-- fails and no event on that topic is ever routed to their socket.
--
-- RLS is already enabled on this table by realtime, with no policies, so
-- everything is denied by default and this is purely additive. The
-- extension = 'broadcast' term keeps the policy from speaking for presence
-- or postgres_changes rows, which are a different mechanism with a
-- different authorization story.
--
-- can_chat_in_party is the SAME helper the messages SELECT policy uses, so
-- "who may join the channel" and "who may read the history" cannot drift
-- apart. That is the point of routing both through one function: a chat you
-- can subscribe to but not page back through, or vice versa, is a bug that
-- only shows up in production.
-- ============================================================
create policy "Party participants can join their party broadcast topic"
on realtime.messages for select to authenticated
using (
  extension = 'broadcast'
  and public.can_chat_in_party(public.party_id_from_topic(realtime.topic()))
);

-- No INSERT policy, and that omission is load bearing.
--
-- realtime.messages already carries an INSERT grant for `authenticated`
-- (realtime ships it), so the only thing standing between a client and
-- writing straight into a topic is the absence of a policy -- RLS denies by
-- default. It stays absent: if a participant could broadcast directly, they
-- could put a line in front of everyone in the party that never passed
-- through public.messages, and therefore never hit the rate limit, never
-- got a row anyone could report, and could not be taken down by
-- hide_message because there would be nothing to hide.
--
-- The trigger above is the only writer. This is exactly why the Flutter
-- client sends a message with an INSERT into public.messages and never with
-- channel.sendBroadcastMessage -- the write path and the delivery path are
-- deliberately not the same path.
