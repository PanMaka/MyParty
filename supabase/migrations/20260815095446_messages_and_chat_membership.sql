-- Phase 6, part 1: the messages table and the membership rule behind it.
--
-- Visibility is not re-derived here. public.can_chat_in_party COMPOSES
-- public.can_access_party (20260812121153, block-aware since 20260814094945)
-- rather than restating any part of it, so every fix to party visibility
-- keeps reaching chat for free -- CLAUDE.md #4, the same inheritance
-- party_posts relies on.
--
-- can_access_party only knows about the party's HOST, so messages carries its
-- own is_blocked check on the AUTHOR, exactly the way party_posts does
-- (20260814112530). A blocked user can have spoken in the chat of a public
-- party hosted by a third party, and those lines have to disappear too.


-- ============================================================
-- can_chat_in_party -- who is IN the conversation.
--
-- This is deliberately NARROWER than can_access_party, and the difference
-- only shows on public parties. can_access_party answers "may I look at
-- this party", and for a public party that is true for every signed-in
-- user on the platform. Reading is a fine thing to hand out that broadly;
-- a writable group chat is not. Applied as-is, every public party's chat
-- would be a room the entire user base can post in, which is a spam surface
-- with no moderation story behind it.
--
-- So chat additionally requires actual participation: you host it, you were
-- invited to it, or you have RSVP'd to it. Either rsvp status counts --
-- 'interested' as well as 'going' -- for the same reason public.get_feed
-- (20260814112531) counts both: the chat carries the run-up to a party, and
-- someone who marked interest wants the run-up.
--
-- Note what is NOT restated below: privacy, the invitation check for private
-- parties, and both directions of the host block all stay inside
-- can_access_party. The `and` here can only ever remove people. It is
-- structurally incapable of widening access, which is what makes it safe to
-- read as "can_access_party, minus the drive-by public audience".
--
-- security definer + pinned search_path for the same reason can_access_party
-- is: it reads invitations and rsvps rows the caller may not SELECT, and
-- returns only a boolean. It must not re-enter RLS on those tables or the
-- recursion 20260812121153 fixed comes straight back.
-- ============================================================
create or replace function public.can_chat_in_party(p_party_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select public.can_access_party(p_party_id)
  and exists (
    select 1
    from public.parties p
    where p.id = p_party_id
    and (
      p.host_id = (select auth.uid())

      or exists (
        select 1 from public.invitations i
        where i.party_id = p.id
        and i.guest_id = (select auth.uid())
      )

      or exists (
        select 1 from public.rsvps r
        where r.party_id = p.id
        and r.user_id = (select auth.uid())
      )
    )
  );
$$;


-- ============================================================
-- messages
--
-- Same soft-delete triple and same "hidden means hidden" invariant as
-- party_posts: a hidden row leaves every SELECT policy, for every client
-- role, its own author included. There is no counter to keep in step here,
-- which is the one way this table is simpler than party_posts.
--
-- body is `not null` -- unlike party_posts.body, which may be null when a
-- post is media-only. A message with no text and no attachment is not a
-- thing, and the length bound is a cheap guard against someone using the
-- chat as a blob store.
-- ============================================================
create table public.messages (
  id uuid default gen_random_uuid() primary key,
  party_id uuid references public.parties(id) on delete cascade not null,
  author_id uuid references public.profiles(id) on delete cascade not null,
  body text not null,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  hidden_at timestamp with time zone,
  hidden_by uuid references public.profiles(id) on delete set null,
  hidden_reason text,
  constraint messages_body_not_blank check (length(btrim(body)) > 0),
  constraint messages_body_length check (length(body) <= 2000),
  -- hidden_by may be null (a system/service_role hide), but it can never be
  -- set on a row that is not actually hidden.
  constraint messages_hidden_consistent check (hidden_by is null or hidden_at is not null)
);

-- Partial on `hidden_at is null` because every read path excludes hidden
-- rows, and carrying the (created_at desc, id desc) keyset in the order
-- public.get_messages scans it -- CLAUDE.md #5. Chat history is only ever
-- read one party at a time, so unlike party_posts there is no second global
-- index: party_id leads, and there is no query that wants it otherwise.
create index messages_party_created_idx
  on public.messages (party_id, created_at desc, id desc)
  where hidden_at is null;


-- ============================================================
-- Server-side rate limit (CLAUDE.md #7).
--
-- A before-insert trigger rather than a policy, because a policy can only
-- answer yes/no about the row in front of it and this rule is about the
-- rows AROUND it. security definer so the count sees the user's own recent
-- messages even in a party whose visibility has since changed underneath
-- them -- a rate limit that a block or a privacy flip can reset is not a
-- rate limit.
--
-- Scoped per (user, party), not per user: talking in two parties at once is
-- normal, and a global cap would let one busy chat throttle another.
-- 20 in 10 seconds is well above human typing speed and well below what a
-- script needs to be worth writing.
-- ============================================================
create or replace function public.enforce_message_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_recent int;
begin
  select count(*) into v_recent
  from public.messages m
  where m.author_id = NEW.author_id
  and m.party_id = NEW.party_id
  and m.created_at > now() - interval '10 seconds';

  if v_recent >= 20 then
    raise exception 'message rate limit exceeded for party %', NEW.party_id
      using errcode = '42501';
  end if;

  return NEW;
end;
$$;

create trigger messages_rate_limit
before insert on public.messages
for each row execute function public.enforce_message_rate_limit();


-- ============================================================
-- Soft delete, in the shape 20260814112530 established and explained: an
-- RPC, never a client UPDATE.
--
-- The reason is worth restating because this is the third table it applies
-- to: on UPDATE, Postgres applies the SELECT policy to the NEW row whenever
-- the statement needs read access, and the SELECT policy below says
-- `hidden_at is null`. So a client-side soft-delete always produces a row
-- the client may no longer read, and Postgres rejects it with "new row
-- violates row-level security policy". No WITH CHECK expression rescues
-- that. The definer function is the way out, and it lets messages carry no
-- UPDATE grant at all -- so there is no column left for a client to write
-- after insert, and a sent message cannot be silently edited.
-- ============================================================
create or replace function public.can_moderate_message(p_message_id uuid)
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select exists (
    select 1
    from public.messages m
    join public.parties p on p.id = m.party_id
    where m.id = p_message_id
    and (
      m.author_id = (select auth.uid())
      or p.host_id = (select auth.uid())
    )
  );
$$;

-- `and hidden_at is null` is what makes hiding one-way: a second call
-- cannot overwrite the original hidden_by/hidden_reason, so an author
-- cannot paper over a host's take-down by re-hiding it under their own
-- name. Authorization is checked before the hidden_at filter, deliberately:
-- an unauthorized caller gets the same 42501 whether or not the row is
-- already down, so this cannot be used to probe what exists.
create or replace function public.hide_message(p_message_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.can_moderate_message(p_message_id) then
    raise exception 'not authorized to hide message %', p_message_id
      using errcode = '42501';
  end if;

  update public.messages
  set hidden_at = now(),
      hidden_by = (select auth.uid()),
      hidden_reason = p_reason
  where id = p_message_id
  and hidden_at is null;
end;
$$;


-- ============================================================
-- RLS
-- ============================================================
alter table public.messages enable row level security;

create policy "Messages are viewable by party participants"
on public.messages for select
using (
  hidden_at is null
  and public.can_chat_in_party(party_id)
  and not public.is_blocked((select auth.uid()), author_id)
);

create policy "Participants can post to a party chat"
on public.messages for insert to authenticated
with check (
  author_id = (select auth.uid())
  and hidden_at is null
  and public.can_chat_in_party(party_id)
);

-- No UPDATE policy and no DELETE policy. A sent message is immutable;
-- taking one down goes through public.hide_message (CLAUDE.md #7: UGC
-- deletes are soft, hard delete is reserved for Phase 9 account/GDPR
-- erasure).


-- ============================================================
-- Grants.
--
-- SELECT goes to `authenticated` only, NOT to anon -- unlike party_posts,
-- which anon may read because a public party's wall is public. There is no
-- such thing as an anonymous chat participant, and the grant is the honest
-- place to say so. It also avoids the failure mode CLAUDE.md gotcha #4
-- describes: table privileges are checked whether or not a WHERE clause
-- could ever be true, so an anon caller reaching public.get_messages hits a
-- clean "permission denied" instead of a policy that silently returns zero
-- rows.
--
-- The INSERT grant is column-level, which is the point: RLS gates which ROW
-- you may touch, never which COLUMN. What it makes impossible with no policy
-- or trigger involved -- back- or future-dating created_at to sort a message
-- to the top or bottom of history, and writing hidden_* by hand instead of
-- going through hide_message. `id` is grantable because client-generated
-- uuids are how the optimistic send in ChatScreen stays idempotent: the
-- client renders the row under the id it will be stored with, so the
-- broadcast echo of its own message is recognisable and does not duplicate.
--
-- No UPDATE grant, on any column.
-- ============================================================
grant select on public.messages to authenticated;
grant insert (id, party_id, author_id, body) on public.messages to authenticated;
