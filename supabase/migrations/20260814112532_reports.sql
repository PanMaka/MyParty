-- Phase 4, part 3: reports.
--
-- No admin UI this phase, by decision (docs/backend-plan.md Phase 4): the
-- table plus service_role SQL is enough for v1, because the take-down half
-- already exists -- 20260814112530's UPDATE policies let an author or a
-- party host hide a post/comment without any triage at all, and service_role
-- can hide anything.
--
-- target_id is polymorphic, so it carries no foreign key. That is the one
-- real cost of a single reports table over four per-target ones, and it is
-- the right trade here: triage wants one queue, and a dangling target_id
-- after a cascade delete is harmless in a moderation log.

create type public.report_target_type as enum ('post', 'comment', 'party', 'profile');

create type public.report_status as enum ('open', 'reviewing', 'actioned', 'dismissed');

create table public.reports (
  id uuid default gen_random_uuid() primary key,
  reporter_id uuid references public.profiles(id) on delete cascade not null,
  target_type public.report_target_type not null,
  target_id uuid not null,
  reason text not null,
  status public.report_status not null default 'open',
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  constraint reports_reason_not_blank check (length(btrim(reason)) > 0),
  constraint reports_no_self_report check (
    not (target_type = 'profile' and target_id = reporter_id)
  )
);

-- One report per user per target, enforced in the database rather than the
-- client (CLAUDE.md: rate limits are server-side). Re-reporting the same
-- post is how a queue gets flooded, and a unique violation is a cheaper
-- answer than a counter.
create unique index reports_one_per_target_idx
  on public.reports (reporter_id, target_type, target_id);

-- The triage queue: oldest open reports first, keyset-ready on
-- (created_at, id) for when it grows past one screen.
create index reports_queue_idx
  on public.reports (status, created_at desc, id desc);

alter table public.reports enable row level security;

-- A reporter can see what they filed -- enough for the client to render
-- "reported" instead of offering the action again -- and nothing else. There
-- is no policy that exposes another user's reports, and none that exposes
-- who reported YOU: that is the one fact this table must not leak.
create policy "Users can view the reports they filed"
on public.reports for select to authenticated
using ( reporter_id = (select auth.uid()) );

create policy "Users can file reports"
on public.reports for insert to authenticated
with check (
  reporter_id = (select auth.uid())
  and status = 'open'
);

-- No UPDATE or DELETE policy: a report is an append-only record. Triage
-- (moving status to reviewing/actioned/dismissed) runs over service_role,
-- which bypasses RLS.


-- Column-level insert grant for the same reason as party_posts: it removes
-- the need for a policy or trigger to defend `status` and `created_at`,
-- since the client simply cannot supply them. The `status = 'open'` check
-- above stays as a second line anyway -- policies should not silently depend
-- on a grant to be correct.
grant select on public.reports to authenticated;
grant insert (id, reporter_id, target_type, target_id, reason) on public.reports to authenticated;
