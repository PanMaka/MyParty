-- Phase 10, item 4: rate limiting on the remaining write paths.
--
-- Messages (20 per 10s per user+party, 20260815095446) and stories (10/hour
-- per user, 20260815133039) already have one. This adds the three the phase
-- prompt names that did not: posts, comments and invites.
--
-- Same shape as the two that exist, and for the same reasons: a `before
-- insert` row trigger rather than a policy, because a policy can only answer
-- yes/no about the row in front of it and this rule is about the rows around
-- it; `security definer` so the count still sees the author's own recent rows
-- in a party whose visibility has changed underneath them, since a limit a
-- block or a privacy flip can reset is not a limit; errcode 42501 so
-- PostgREST returns 403 rather than 500; and hidden rows COUNT, because
-- hiding is the moderation response to abuse and a limit that a takedown
-- refunds hands the budget straight back to the abuser.
--
-- ---------------------------------------------------------------
-- One thing worth writing down, because it is counter-intuitive and someone
-- will eventually "fix" it in the wrong direction.
--
-- A BEFORE ROW trigger DOES see the rows inserted earlier in its own
-- statement. It looks like it should not -- under READ COMMITTED a statement
-- cannot see its own effects -- but a query inside a volatile plpgsql
-- function takes a fresh snapshot whose curcid is the current command id, and
-- rows with cmin equal to that cid are visible to it. Measured, not reasoned:
-- a single `insert into stories select ... from generate_series(1,15)` is
-- refused at row 11 by the existing trigger, and 25 messages in one statement
-- are refused at 21.
--
-- That property is what makes the existing per-row limits sound against a
-- PostgREST array insert -- POST /rest/v1/party_posts with a JSON body of 50
-- objects is ONE statement -- and it is asserted in 13_hardening.test.sql so
-- it cannot regress silently.
-- ---------------------------------------------------------------


-- ============================================================
-- 1. Posts: 30 per author per hour.
--
-- Scoped per USER globally, not per (user, party) -- the same call stories
-- made and the opposite of chat. Chat is conversation and being in two rooms
-- at once is normal; a post carries media_path and lands in get_feed, so the
-- resources being protected are storage and other people's feeds, both of
-- which are global to the account. Spreading 300 posts over 10 parties has to
-- count as 300.
--
-- 30/hour is one post every two minutes sustained for an hour. Nobody
-- attending a party does that; a script does it in four seconds.
-- ============================================================
create or replace function public.enforce_post_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_recent int;
begin
  select count(*) into v_recent
  from public.party_posts p
  where p.author_id = NEW.author_id
  and p.created_at > now() - interval '1 hour';

  if v_recent >= 30 then
    raise exception 'post rate limit exceeded: 30 per hour'
      using errcode = '42501';
  end if;

  return NEW;
end;
$$;

create trigger party_posts_rate_limit
before insert on public.party_posts
for each row execute function public.enforce_post_rate_limit();


-- ============================================================
-- 2. Comments: 100 per author per hour.
--
-- Also global per user, and that IS a departure from the chat rule even
-- though a comment thread is conversation. The difference is the abuse shape.
-- Chat spam is depth -- flooding one room, which the people in that room can
-- leave. Comment spam is breadth: the same line under fifty strangers' posts,
-- which is a notification each and a moderation queue item each. Capping per
-- (user, post) would price the thing we do not mind and leave the thing we do
-- unpriced.
--
-- Looser than posts by design. A comment is cheap to write, carries no media,
-- and a genuinely engaged user in an active party can leave a few dozen in an
-- evening.
-- ============================================================
create or replace function public.enforce_comment_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_recent int;
begin
  select count(*) into v_recent
  from public.post_comments c
  where c.author_id = NEW.author_id
  and c.created_at > now() - interval '1 hour';

  if v_recent >= 100 then
    raise exception 'comment rate limit exceeded: 100 per hour'
      using errcode = '42501';
  end if;

  return NEW;
end;
$$;

create trigger post_comments_rate_limit
before insert on public.post_comments
for each row execute function public.enforce_comment_rate_limit();


-- ============================================================
-- 3. Invites: 500 guests per party, 1000 per host per hour.
--
-- STATEMENT-level with a transition table, and it is the only one of the five
-- that is. Not for correctness -- the note at the top of this file says a row
-- trigger would count these fine -- but for cost. Bulk is the NORMAL path
-- here: create_party_with_invites (20260813095609) writes the whole guest
-- list as one `insert ... select from unnest(p_invitee_ids)`, so a per-row
-- trigger would run 500 counting queries to answer a question that has one
-- answer. Same reasoning as the statement-level fan-out trigger in
-- 20260817073509.
--
-- AFTER rather than BEFORE, which is what a transition table requires anyway,
-- and it simplifies the arithmetic: the rows are already in the table when
-- this runs, so the count is the post-insert total and the comparison is
-- against the cap directly rather than cap-minus-batch-size. Raising here
-- still rolls the statement back.
--
-- TWO caps, because they answer different questions:
--
--   * Per party (500) is a guest list size limit. It is the one a legitimate
--     host can actually reach, and the number is set where a real event tops
--     out rather than where abuse starts.
--   * Per host per hour (1000) is the rate limit proper. Without it, the
--     per-party cap costs an attacker one extra create_party_with_invites
--     call per 500 invites, which is not a limit.
--
-- Counted by HOST, not by auth.uid(): only a host can insert invitations (the
-- "Hosts can invite guests" policy proves the party's host_id equals the
-- caller), so the two are the same value on every client path -- but deriving
-- it from the data means the limit also holds on any future server-side path,
-- and it does not silently switch itself off when auth.uid() is null, which is
-- how seed.sql and the pgTAP fixtures insert.
--
-- Neither count needs a new index: the per-party one rides
-- invitations_party_id_guest_id_key, and the per-host one walks
-- parties_host_id_idx then that same unique index once per party.
--
-- What this deliberately does NOT do is limit who may be invited -- that is
-- accepts_invite_from and the invite_policy tiers (20260818175436), which is a
-- consent question, not a volume one. Both apply; neither substitutes.
-- ============================================================
create or replace function public.enforce_invite_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_party_id uuid;
  v_host_id uuid;
  v_count int;
begin
  for v_party_id in select distinct i.party_id from inserted i loop
    select count(*) into v_count
    from public.invitations x
    where x.party_id = v_party_id;

    if v_count > 500 then
      raise exception 'invite limit exceeded: % guests on one party, max 500', v_count
        using errcode = '42501';
    end if;
  end loop;

  for v_host_id in
    select distinct p.host_id
    from inserted i
    join public.parties p on p.id = i.party_id
  loop
    select count(*) into v_count
    from public.invitations x
    join public.parties p on p.id = x.party_id
    where p.host_id = v_host_id
    and x.created_at > now() - interval '1 hour';

    if v_count > 1000 then
      raise exception 'invite rate limit exceeded: % invites in an hour, max 1000', v_count
        using errcode = '42501';
    end if;
  end loop;

  return null;
end;
$$;

create trigger invitations_rate_limit
after insert on public.invitations
referencing new table as inserted
for each statement execute function public.enforce_invite_rate_limit();
