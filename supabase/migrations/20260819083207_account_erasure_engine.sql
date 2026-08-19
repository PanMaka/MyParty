-- Phase 9, part 2: the erasure engine -- what happens 30 days later.
--
-- Same split as story-media and notification-worker: the process holding the
-- service key decides nothing. It has three verbs -- claim / complete / fail --
-- and the rules about who may be erased, what gets deleted and what becomes a
-- tombstone live here, in the database, where RLS and a transaction can hold
-- them. An eraser that could invent policy would be the single most dangerous
-- process in the system, because it is the one whose mistakes are not
-- recoverable.
--
-- What the edge function does that SQL cannot: delete storage objects (gotcha
-- #7 -- the bytes are not in Postgres) and delete the auth.users row (a GoTrue
-- admin call). Everything else is below.
--
-- Ordering, and why storage comes before the rows: the claim hands back the
-- object paths, the function deletes the bytes, and only then does complete
-- delete the rows that named them. Deleting the rows first and failing on
-- storage would leave objects nothing can ever enumerate again -- unreferenced,
-- uncleanable, invisible. Failing in the other order just means a retry.


-- ============================================================
-- 1. account_erasures -- the queue.
--
-- Engine-internal, exactly like sent_notifications: RLS on, zero policies,
-- zero client grants, and the default ACL revoked first (gotcha #9 -- every
-- new table in public is created holding TRUNCATE from anon, and RLS does not
-- mediate TRUNCATE).
--
-- Why a table rather than deriving everything from profiles.deleted_at: the
-- derivable part is who is due. What is not derivable is who is IN FLIGHT and
-- how many times we have tried, and putting either on profiles would mean two
-- more columns that every profile SELECT in the app carries around forever to
-- serve a process that touches 0.01% of rows.
--
-- The row is created by the claim, not by request_account_deletion. One less
-- invariant to keep in sync, and it means a deletion requested before this
-- migration existed is still picked up.
-- ============================================================
create table public.account_erasures (
  user_id      uuid primary key references public.profiles(id) on delete no action,
  claimed_at   timestamptz,
  attempts     int not null default 0,
  last_error   text,
  completed_at timestamptz,
  created_at   timestamptz not null default now()
);

alter table public.account_erasures enable row level security;

revoke all on public.account_erasures from anon, authenticated;

comment on table public.account_erasures is
  'Engine-internal erasure queue. No policies and no client grants by design -- this is operator telemetry about a process, not user data.';

-- The sweep asks one question: who is claimable. Partial so the index stays
-- the size of the backlog rather than the size of the user base.
create index account_erasures_claimable_idx
  on public.account_erasures (claimed_at)
  where completed_at is null;


-- ============================================================
-- 2. The grace period, in one place.
--
-- 30 days, and it is a function rather than a literal because it is asserted
-- by the test suite and read by the claim, and those two must not be able to
-- drift. Changing the retention promise should be one edit.
-- ============================================================
create or replace function public.account_erasure_grace()
returns interval
language sql
immutable
set search_path = ''
as $$ select interval '30 days' $$;

comment on function public.account_erasure_grace() is
  'The soft-delete grace period. Single source of truth for the 30 days in docs/backend-plan.md Phase 9 and the retention table.';


-- ============================================================
-- 3. claim_accounts_for_erasure -- the eraser's only read.
--
-- Returns everything the function needs to do its two jobs and nothing else:
-- the user id (for the GoTrue admin delete) and the storage paths (for the
-- object deletes). No content, no email, no location -- the eraser never sees
-- what it is erasing, which is the same discipline that keeps a coordinate out
-- of notification-worker's logs.
--
-- The 5-attempt cap is the rule this function protects, and it lives here for
-- the reason 7c spelled out: a retry budget kept in worker memory resets on
-- every redeploy and runs independently in every concurrent invocation, which
-- is not a budget. An account that has failed erasure five times stops being
-- claimed and stays visible in the queue with its last_error, because the
-- correct response to "we cannot erase this person" is an operator looking at
-- it, not an infinite retry against a paid API.
--
-- claimed_at doubles as the in-flight lock and the reclaim clock: a claim
-- older than an hour is a function that died mid-run and is retried.
-- ============================================================
create or replace function public.claim_accounts_for_erasure(p_limit int default 20)
returns table (
  user_id       uuid,
  avatar_prefix text,
  post_paths    text[]
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Enrol anyone whose grace period has expired. `on conflict do nothing`
  -- because an account already in the queue -- claimed, failed, whatever --
  -- must not have its attempt count reset by the next sweep.
  insert into public.account_erasures (user_id)
  select p.id
  from public.profiles p
  where p.deleted_at is not null
    and p.erased_at is null
    and p.deleted_at < now() - public.account_erasure_grace()
  on conflict (user_id) do nothing;

  return query
  with claimable as (
    select e.user_id
    from public.account_erasures e
    where e.completed_at is null
      and e.attempts < 5
      and (e.claimed_at is null or e.claimed_at < now() - interval '1 hour')
    order by e.created_at
    limit p_limit
    for update skip locked
  ),
  claimed as (
    update public.account_erasures e
    set claimed_at = now(),
        attempts   = e.attempts + 1
    from claimable c
    where e.user_id = c.user_id
    returning e.user_id
  )
  select
    c.user_id,
    -- The avatars bucket is {user_id}/..., so the eraser can delete it by
    -- prefix without this function enumerating storage.objects.
    c.user_id::text as avatar_prefix,
    -- post-media is keyed by PARTY, not by user, so there is no prefix that
    -- means "this person's media" and the paths have to be named one by one.
    -- That is the whole reason the claim returns paths at all rather than the
    -- eraser deriving them.
    --
    -- Story media is deliberately NOT here. It goes through
    -- story_media_purges (section 4 enrols it, section 6 dispatches it),
    -- because that ledger is the only thing in the system that can prove an
    -- object left the bucket. Returning story paths here as well would have
    -- the eraser and the purge job both sending DELETEs for the same path,
    -- with only one of them writing the row that records the outcome.
    coalesce(
      (select array_agg(pp.media_path)
       from public.party_posts pp
       where pp.author_id = c.user_id
         and pp.media_path is not null),
      '{}'::text[]
    ) as post_paths
  from claimed c;
end;
$$;

revoke execute on function public.claim_accounts_for_erasure(int) from public, anon, authenticated;
-- gotcha #13: the revoke above took service_role's privilege with it, since
-- PUBLIC is where it came from. The eraser authenticates as service_role and
-- would get 42501 on a function it can plainly see exists.
grant execute on function public.claim_accounts_for_erasure(int) to service_role;


-- ============================================================
-- 4. complete_account_erasure -- the whole database side, in one transaction.
--
-- Called only after the eraser has confirmed the storage objects are gone. It
-- is idempotent: every statement is a delete or a guarded update, so a retry
-- after a crash between here and the auth delete is safe.
--
-- The classification below is docs/phase-09-fk-audit.md §3 executed. Anything
-- that is not deleted here is deliberately retained -- read the audit before
-- adding a table to this list, because "the user's rows" and "rows that would
-- break somebody else's screen" overlap more than they look like they do.
-- ============================================================
create or replace function public.complete_account_erasure(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_handle text;
begin
  if not exists (
    select 1 from public.profiles
    where id = p_user_id and deleted_at is not null and erased_at is null
  ) then
    -- Not an error: a retry after a partial failure lands here, and so does a
    -- user who cancelled between the claim and now. Both should stop quietly.
    return;
  end if;

  -- Refuse to erase an account whose grace period has not expired. The eraser
  -- cannot reach this state through the claim, but this function is a
  -- service_role entry point and the 30 days is the promise the whole feature
  -- rests on -- it should be impossible to shorten by calling the API directly.
  if exists (
    select 1 from public.profiles
    where id = p_user_id
      and deleted_at > now() - public.account_erasure_grace()
  ) then
    raise exception 'grace period has not expired for %', p_user_id
      using errcode = 'P0001';
  end if;

  -- ---- Story media: queue the objects BEFORE the rows that name them. ----
  -- story_media_purges.story_id is `on delete set null` precisely so the queue
  -- outlives its subject (20260815133041). These rows are enrolled with
  -- requested_at null, which is what section 5 teaches purge_story_media to
  -- pick up -- rather than this function dispatching its own HTTP delete and
  -- becoming a second path to the same bucket (gotcha #7 exists because that
  -- kind of duplication is how objects get orphaned).
  insert into public.story_media_purges (story_id, media_path)
  select s.id, s.media_path
  from public.stories s
  where s.author_id = p_user_id
    and s.media_uploaded_at is not null
    and s.media_deleted_at is null;

  -- ---- DELETE, per the audit's §3. ----
  delete from public.story_views    where user_id   = p_user_id;
  delete from public.stories        where author_id = p_user_id;
  delete from public.post_likes     where user_id   = p_user_id;
  delete from public.rsvps          where user_id   = p_user_id;
  delete from public.invitations    where guest_id  = p_user_id;
  delete from public.follows        where follower_id = p_user_id or followee_id = p_user_id;
  delete from public.party_reads    where user_id   = p_user_id;

  -- Re-run of the PURGE NOW set from request_account_deletion. Not redundant:
  -- a device or job could have been created between the soft delete and now by
  -- a client holding a still-valid JWT, and this is the last chance to catch it.
  delete from public.user_devices       where user_id = p_user_id;
  delete from public.notification_jobs  where user_id = p_user_id;
  delete from public.sent_notifications where user_id = p_user_id;

  -- ---- RETAIN, with the media stripped. ----
  -- The post survives so its comment thread and like count survive; the
  -- photograph does not. The eraser has already deleted the object by the time
  -- this runs, so this only clears the pointer.
  update public.party_posts
  set media_path = null
  where author_id = p_user_id
    and media_path is not null
    -- party_posts_not_empty requires a body OR a path, so only a post with a
    -- body can give up its path. The media-only case is handled below.
    and body is not null;

  -- A media-only post cannot survive its media, and cannot have its path
  -- nulled either -- party_posts_not_empty would reject the row, and the
  -- alternative (inventing a body) would be this function writing content.
  -- So it is hidden instead: hidden posts are excluded by every read path's
  -- `hidden_at is null`, the dangling path names an object the eraser has
  -- already deleted, and the comment thread underneath stays intact because
  -- those comments belong to other people.
  update public.party_posts
  set hidden_at     = coalesce(hidden_at, now()),
      hidden_reason = coalesce(hidden_reason, 'account erased')
  where author_id = p_user_id
    and media_path is not null
    and body is null;

  -- ---- The tombstone. ----
  -- An opaque handle derived from the uuid: deterministic, so a retry produces
  -- the same value, and unique by construction, so the second person to delete
  -- their account cannot fail on profiles_username_lower_idx. Deliberately not
  -- the literal 'Διαγραμμένος χρήστης' -- that string is a display concern and
  -- would collide on the second erasure.
  v_handle := 'deleted_' || replace(p_user_id::text, '-', '');

  update public.profiles
  set username           = v_handle,
      erased_at          = now(),
      location_consent   = false,
      push_consent       = false,
      analytics_consent  = false,
      follower_count     = 0,
      following_count    = 0,
      onboarding_completed_at = null
  where id = p_user_id;

  update public.account_erasures
  set completed_at = now(),
      last_error   = null
  where user_id = p_user_id;
end;
$$;

revoke execute on function public.complete_account_erasure(uuid) from public, anon, authenticated;
grant execute on function public.complete_account_erasure(uuid) to service_role;

comment on function public.complete_account_erasure(uuid) is
  'The database half of erasure: deletes the audit''s DELETE set, strips post media, and rewrites the profiles row into an anonymous tombstone. Idempotent. Called only after storage objects are confirmed gone.';


-- ============================================================
-- 5. fail_account_erasure.
--
-- Clears the claim so the row is retried, and records why. It does NOT
-- decrement attempts -- the whole value of the cap is that failures accumulate
-- across invocations.
-- ============================================================
create or replace function public.fail_account_erasure(p_user_id uuid, p_error text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.account_erasures
  set claimed_at = null,
      last_error = left(coalesce(p_error, 'unknown'), 500)
  where user_id = p_user_id and completed_at is null;
$$;

revoke execute on function public.fail_account_erasure(uuid, text) from public, anon, authenticated;
grant execute on function public.fail_account_erasure(uuid, text) to service_role;


-- ============================================================
-- 6. Teach purge_story_media about undispatched queue rows.
--
-- Section 4 enrols story media into story_media_purges and then deletes the
-- stories rows, so those objects are no longer reachable from the batch this
-- function used to build -- it selected from `stories`, and the story is gone.
--
-- The fix is a union inside the ONE dispatcher rather than a second one in the
-- erasure path. Two functions sending DELETEs at the same bucket is exactly
-- the shape that produces an orphan: they would race on the same path, and
-- only one of them would be writing the ledger row that proves the object went
-- away.
--
-- Everything else about this function is unchanged from 20260815133041 --
-- same batch size, same single http_delete, same "queue the ledger row in the
-- same transaction so pg_net cannot send something nothing is tracking".
-- ============================================================
create or replace function public.purge_story_media()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cfg record;
  v_ids uuid[];
  v_queue_ids bigint[];
  v_paths text[];
  v_request_id bigint;
  v_count int;
begin
  with batch as (
    -- (a) The original source: a hidden, uploaded, not-yet-deleted story with
    -- nothing already in flight for it.
    select s.id as story_id, null::bigint as queue_id, s.media_path
    from public.stories s
    where s.hidden_at is not null
      and s.media_uploaded_at is not null
      and s.media_deleted_at is null
      and not exists (
        select 1 from public.story_media_purges q
        where q.story_id = s.id and q.completed_at is null
      )

    union all

    -- (b) Phase 9: a ledger row enrolled by complete_account_erasure and never
    -- dispatched. Its story row has been deleted, so story_id is null and (a)
    -- can no longer see it -- media_path is the only handle left, which is why
    -- that column has always been NOT NULL on this table.
    select null::uuid, q.id, q.media_path
    from public.story_media_purges q
    where q.requested_at is null
      and q.completed_at is null

    limit 100
  )
  select
    array_remove(array_agg(batch.story_id), null),
    array_remove(array_agg(batch.queue_id), null),
    array_agg(batch.media_path),
    count(*)::int
  into v_ids, v_queue_ids, v_paths, v_count
  from batch;

  if v_count is null or v_count = 0 then
    return 0;
  end if;

  select * into v_cfg from public.story_cleanup_config();

  select net.http_delete(
    url := v_cfg.storage_url || '/object/story-media',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_cfg.service_key,
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object('prefixes', to_jsonb(v_paths)),
    timeout_milliseconds := 20000
  ) into v_request_id;

  -- Source (a): a new ledger row per story, as before.
  insert into public.story_media_purges (story_id, media_path, request_id, attempts, requested_at)
  select s.id, s.media_path, v_request_id, 1, now()
  from public.stories s
  where s.id = any(v_ids);

  -- Source (b): the ledger row already exists; stamp the dispatch onto it.
  update public.story_media_purges q
  set request_id   = v_request_id,
      attempts     = q.attempts + 1,
      requested_at = now()
  where q.id = any(v_queue_ids);

  return v_count;
end;
$$;

revoke execute on function public.purge_story_media() from public, anon, authenticated;


-- ============================================================
-- 7. Waking the eraser: vault config + pg_net, same as 7c.
--
-- Set up once per environment:
--   select vault.create_secret('https://<ref>.supabase.co/functions/v1/account-eraser',
--                              'account_eraser_url');
--   select vault.create_secret('<service_role key>', 'account_eraser_service_key');
--
-- Unlike the notification worker there is no insert trigger and no
-- every-minute tick, and the asymmetry is the point: nothing about erasure is
-- latency-sensitive. The subject asked for it 30 days ago. A daily cron is the
-- whole mechanism, and a job that runs 24 hours late is invisible against a
-- 30-day promise -- whereas a delivery job running 60 seconds late is the
-- feature failing.
-- ============================================================
create or replace function public.account_eraser_config()
returns table (eraser_url text, service_key text)
language plpgsql
security definer
set search_path = ''
stable
as $$
begin
  select
    max(s.decrypted_secret) filter (where s.name = 'account_eraser_url'),
    max(s.decrypted_secret) filter (where s.name = 'account_eraser_service_key')
  into eraser_url, service_key
  from vault.decrypted_secrets s
  where s.name in ('account_eraser_url', 'account_eraser_service_key');

  if eraser_url is null or service_key is null then
    raise exception
      'account erasure is not configured: vault needs secrets account_eraser_url and account_eraser_service_key'
      using errcode = 'P0002';
  end if;

  return next;
end;
$$;

revoke execute on function public.account_eraser_config() from public, anon, authenticated;


create or replace function public.post_to_account_eraser(p_reason text)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cfg record;
  v_request_id bigint;
begin
  select * into v_cfg from public.account_eraser_config();

  select net.http_post(
    url := v_cfg.eraser_url,
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_cfg.service_key,
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object('reason', p_reason),
    timeout_milliseconds := 30000
  ) into v_request_id;

  return v_request_id;
end;
$$;

revoke execute on function public.post_to_account_eraser(text) from public, anon, authenticated;


-- unschedule-then-schedule for idempotency: cron.job is not part of the
-- migration history. Same pattern as story-cleanup, location-retention,
-- nearby-notification-sweep and notification-worker-tick.
select cron.unschedule('account-erasure-sweep')
where exists (select 1 from cron.job where jobname = 'account-erasure-sweep');

-- 03:30 UTC daily. Off-peak, and deliberately not aligned with the other four
-- jobs' minute boundaries so the storage API is not being hit by the story
-- cleanup and the eraser in the same second.
select cron.schedule(
  'account-erasure-sweep',
  '30 3 * * *',
  $cron$ select public.post_to_account_eraser('cron_daily') $cron$
);
