-- Phase 8, part 3: the three numbers on the profile screen, which until now
-- were the string literals '47', '5' and '312'.


-- ============================================================
-- The two indexes this phase surfaced, and they are not incidental.
--
-- public.rsvps' primary key is (party_id, user_id) and its only other index is
-- rsvps_party_id_idx. Every access pattern the schema had until today was "who
-- is coming to THIS party", which both of those serve. get_profile_stats asks
-- the mirror question -- "which parties is THIS user going to" -- and there is
-- no index that can answer it: a leading-column mismatch on the PK means a
-- sequential scan of every rsvp in the system to count one person's.
--
-- public.parties is worse in kind: it has no index on host_id at all. The
-- party_tier/location indexes are spatial and lifecycle, and the feed reaches
-- parties through party_posts. "Parties hosted by X" has never been asked
-- before this function.
--
-- status is included in the rsvps index rather than left as a filter because
-- the count is specifically of 'going', and a two-column index answers it from
-- the index alone. scripts/explain_profile_stats.sh measures both against the
-- seq-scan control -- the numbers, not the assertion, are what justify these.
--
-- public.stories needs nothing: stories_author_created_idx (20260815133039) is
-- already (author_id, created_at desc).
-- ============================================================
create index rsvps_user_status_idx on public.rsvps (user_id, status);
create index parties_host_id_idx   on public.parties (host_id);


-- ============================================================
-- get_profile_stats
--
-- security INVOKER, the same grain as get_feed (20260814112531), get_messages
-- and get_party_stories: RLS is the only authority on what counts, so the
-- three counts are automatically "how many of these may YOU see". A definer
-- version would have to hand-write a second copy of party visibility outside
-- the policies, which is exactly what CLAUDE.md #4 exists to stop.
--
-- The consequence is worth stating plainly, because it shapes the UI. The
-- rsvps SELECT policy (20260813095416) is `user_id = auth.uid() OR I host the
-- party`, so parties_attended is structurally ZERO for anyone but the owner.
-- That is not a bug to route around -- "who sees which parties I go to" is a
-- real setting that does not exist yet (it is the first, still-unwired row of
-- the profile screen's privacy card), and inventing an answer for it here
-- would be deciding a product question inside an aggregate. So the client
-- renders that tile in the self view only; the other two populate for
-- everyone, filtered to what the viewer may see.
--
-- parties_hosted and stories_posted need no explicit visibility term for the
-- same reason: the parties SELECT policy already yields public parties plus
-- ones the viewer is invited to, and the stories policy already applies
-- can_access_party plus is_blocked on the author. A stranger counting my
-- parties gets my public ones, and I get all of mine, from the same query.
--
-- "φέτος" is a calendar-year question, evaluated against date_trunc('year',
-- now()) in the server's zone rather than the user's notification_tz. The
-- boundary matters for a few hours once a year on a decorative counter, which
-- does not justify dragging the timezone column into an aggregate; noted here
-- so it reads as a decision rather than an oversight. There is no upper bound
-- -- a party you are going to tonight counts today, not in January.
--
-- Returns exactly one row, always: the three scalar subqueries produce 0 for a
-- user with nothing, and for a user id that does not exist at all. The client
-- never has to distinguish "no stats" from "zero stats".
-- ============================================================
create or replace function public.get_profile_stats(p_user_id uuid)
returns table (
  parties_attended int,
  parties_hosted int,
  stories_posted int
)
language sql
stable
as $$
  select
    (
      select count(*)::int
      from public.rsvps r
      join public.parties p on p.id = r.party_id
      where r.user_id = p_user_id
        and r.status = 'going'
        and p.starts_at >= date_trunc('year', now())
    ) as parties_attended,

    (
      select count(*)::int
      from public.parties p
      where p.host_id = p_user_id
        and p.status = 'published'
    ) as parties_hosted,

    (
      select count(*)::int
      from public.stories s
      where s.author_id = p_user_id
        and s.hidden_at is null
    ) as stories_posted;
$$;

-- CLAUDE.md gotcha #4: table privileges are checked whether or not a WHERE
-- clause could ever be true, and anon holds SELECT on neither public.rsvps nor
-- public.stories. An anonymous caller would get "permission denied for table
-- rsvps" -- an error that both confuses and advertises the query's internals --
-- rather than three zeros. Making the function itself authenticated-only turns
-- that into the honest answer.
--
-- The explicit service_role grant is gotcha #13, not belt-and-braces:
-- service_role's EXECUTE comes from the default PUBLIC grant and nothing else,
-- so `revoke ... from public` silently takes it away too.
revoke execute on function public.get_profile_stats(uuid) from public;
grant execute on function public.get_profile_stats(uuid) to authenticated, service_role;

comment on function public.get_profile_stats(uuid) is
  'Profile screen counters. Invoker rights, so each count is filtered to what the CALLER may see -- parties_attended is owner-only by construction, per the rsvps SELECT policy.';
