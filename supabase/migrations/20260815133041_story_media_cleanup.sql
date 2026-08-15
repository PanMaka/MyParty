-- Phase 5, part 3: the expiry job -- and the half of it that usually gets
-- forgotten.
--
-- Hiding an expired row is easy and it is not the job. The bytes are the thing
-- that costs money, and a "cleanup" that only flips a column leaves every clip
-- anyone ever posted sitting in the bucket forever, silently, with a monthly
-- bill that only ever grows and no row anywhere admitting it. So the deletion
-- is built as something CHECKABLE: every object scheduled for removal gets a
-- story_media_purges row, the HTTP response is read back, and
-- stories.media_deleted_at is set only on a response that actually confirms the
-- object is gone. Anything unconfirmed stays on the queue and is retried.
--
-- THE OTHER TRAP, and the reason this file talks HTTP at all:
--
--     delete from storage.objects  DOES NOT DELETE THE OBJECT.
--
-- storage.objects is Storage's METADATA table. The bytes live in S3 (or, in a
-- local stack, on the storage container's filesystem), and only the Storage API
-- knows how to remove both. Deleting the row from SQL orphans the file --
-- unreferenced, uncleanable, and now invisible to the very table you would have
-- had to enumerate to find it again. It is a strictly worse outcome than doing
-- nothing at all, and it looks like it worked. Hence pg_net and a real DELETE
-- request against /storage/v1/object/story-media.


create extension if not exists pg_cron;

-- pg_net is already installed on this stack (and on hosted Supabase); named
-- here so a fresh database gets it before the functions below reference it.
create extension if not exists pg_net with schema extensions;


-- ============================================================
-- story_media_purges -- the audit trail that makes deletion checkable.
--
-- Without this table "we deleted the object" is an assumption. With it, the
-- question "is anything still owed to the bucket?" is a query:
--
--   select * from public.story_media_purges where completed_at is null;
--
-- media_path is COPIED rather than joined back to stories, deliberately: the
-- purge has to survive the story row disappearing (Phase 9 account erasure
-- hard-deletes rows, and the cascade would take a join-only queue with it,
-- leaking exactly the objects a GDPR erasure most needs gone). The FK is
-- `on delete set null` for the same reason -- the queue outlives its subject.
--
-- No RLS policies, and none are needed: RLS is enabled and no role but the
-- table owner has any grant, so this is invisible to every client role. It is
-- operator telemetry, not user data.
-- ============================================================
create table public.story_media_purges (
  id bigint generated always as identity primary key,
  story_id uuid references public.stories(id) on delete set null,
  media_path text not null,
  request_id bigint,
  attempts int default 0 not null,
  status_code int,
  last_error text,
  created_at timestamp with time zone default now() not null,
  requested_at timestamp with time zone,
  completed_at timestamp with time zone
);

alter table public.story_media_purges enable row level security;

-- The working set: everything still owed. Partial, so the sweep stays
-- proportional to the backlog and not to every object ever deleted.
create index story_media_purges_open_idx
  on public.story_media_purges (created_at)
  where completed_at is null;


-- ============================================================
-- story_cleanup_config -- where the service credentials come from.
--
-- Vault, not a hardcoded key and not a GUC. The job has to call the Storage API
-- as service_role (the bucket has no policies, so nothing less can delete from
-- it), which means a secret has to live somewhere the database can read it, and
-- vault.decrypted_secrets is the one place Supabase encrypts at rest.
--
-- It RAISES when unset rather than returning null and skipping the work. A
-- hosted project where nobody ran the two insert statements below must fail
-- loudly on the first cron tick -- the failure mode this whole file exists to
-- prevent is precisely "storage quietly keeps growing and nothing complains".
--
-- Local values are seeded in seed.sql, which never runs against a hosted
-- project. To configure a real one, once:
--
--   select vault.create_secret('https://<ref>.supabase.co/storage/v1', 'storage_api_url');
--   select vault.create_secret('<service_role key>', 'story_cleanup_service_key');
-- ============================================================
create or replace function public.story_cleanup_config()
returns table (storage_url text, service_key text)
language plpgsql
security definer
set search_path = ''
stable
as $$
begin
  select
    max(s.decrypted_secret) filter (where s.name = 'storage_api_url'),
    max(s.decrypted_secret) filter (where s.name = 'story_cleanup_service_key')
  into storage_url, service_key
  from vault.decrypted_secrets s
  where s.name in ('storage_api_url', 'story_cleanup_service_key');

  if storage_url is null or service_key is null then
    raise exception
      'story cleanup is not configured: vault needs secrets storage_api_url and story_cleanup_service_key'
      using errcode = 'P0002';
  end if;

  return next;
end;
$$;

revoke execute on function public.story_cleanup_config() from public, anon, authenticated;


-- ============================================================
-- expire_stories -- the hide half.
--
-- A security definer RPC, never an UPDATE policy, for the reason CLAUDE.md
-- gotcha #3 spells out: on UPDATE Postgres applies the SELECT policy to the NEW
-- row, that policy says `hidden_at is null`, and so a soft-delete that has to
-- pass RLS is structurally impossible. It is also what lets stories carry no
-- UPDATE grant at all.
--
-- hidden_by stays NULL here -- there is no user behind an expiry -- which is
-- exactly why stories_hidden_consistent permits a null hidden_by on a hidden
-- row.
--
-- TWO populations get hidden, and the second is the one that is easy to miss:
--
--   'expired'    the 24h ran out. Note this is bookkeeping, not enforcement:
--                the SELECT policy already compares expires_at to now(), so a
--                story is invisible the instant it expires whether or not this
--                job ever runs. What hiding does is make the row eligible for
--                the purge below.
--
--   'abandoned'  a row that reserved a path and never confirmed an upload. If
--                the PUT actually landed and the client died before calling
--                confirm_story_upload, the bytes are in the bucket with
--                nothing publishing them -- an orphan in every sense except
--                that this row still names it. Hiding it after an hour is what
--                hands that object to the purge. Skip this branch and the
--                bucket accumulates one object per crashed upload, forever.
-- ============================================================
create or replace function public.expire_stories()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hidden int;
begin
  with expired as (
    update public.stories
    set hidden_at = now(),
        hidden_reason = case
          when media_uploaded_at is null then 'abandoned'
          else 'expired'
        end
    where hidden_at is null
    and (
      expires_at <= now()
      or (media_uploaded_at is null and created_at < now() - interval '1 hour')
    )
    returning 1
  )
  select count(*) into v_hidden from expired;

  return v_hidden;
end;
$$;

revoke execute on function public.expire_stories() from public, anon, authenticated;


-- ============================================================
-- purge_story_media -- the delete half.
--
-- One request per tick, carrying up to 100 paths: the Storage API's object
-- delete takes a {"prefixes": [...]} array, so batching is free and 100 keeps
-- any single failure's blast radius small enough to retry cheaply.
--
-- pg_net is asynchronous by design -- http_delete queues the request and
-- returns an id, and the background worker only sends it AFTER THIS
-- TRANSACTION COMMITS. That is not a limitation to work around, it is the
-- correct shape for a cron job: the sweep never blocks on a slow bucket, and a
-- request that was queued but not yet answered is plainly distinguishable from
-- one that succeeded, because media_deleted_at is set by the reconcile step
-- below and nowhere else.
--
-- The rows selected are hidden AND uploaded AND not yet deleted -- so a live
-- story can never be in here, whatever hid it. That is enforced by
-- stories_deleted_implies_hidden as well, one layer down.
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
  v_paths text[];
  v_request_id bigint;
  v_count int;
begin
  -- Take the batch first: no config, no wasted work, and the exception from
  -- story_cleanup_config surfaces on the cron log with nothing half-done.
  with batch as (
    select s.id, s.media_path
    from public.stories s
    where s.hidden_at is not null
    and s.media_uploaded_at is not null
    and s.media_deleted_at is null
    -- Rows already queued and awaiting an answer are skipped, so a slow
    -- response cannot cause the next tick to delete the same object twice.
    and not exists (
      select 1 from public.story_media_purges q
      where q.story_id = s.id and q.completed_at is null
    )
    order by s.hidden_at
    limit 100
  )
  select array_agg(batch.id), array_agg(batch.media_path), count(*)::int
  into v_ids, v_paths, v_count
  from batch;

  if v_count is null or v_count = 0 then
    return 0;
  end if;

  select * into v_cfg from public.story_cleanup_config();

  -- Queue the request BEFORE the ledger rows exist? No -- the other way round
  -- would leave a request in flight that nothing is tracking if this
  -- transaction then fails. Both happen in one transaction, and pg_net does
  -- not send until it commits, so there is no window where an object is
  -- deleted with no row admitting it.
  select net.http_delete(
    url := v_cfg.storage_url || '/object/story-media',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_cfg.service_key,
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object('prefixes', to_jsonb(v_paths)),
    timeout_milliseconds := 20000
  ) into v_request_id;

  -- Keyed on the ids the batch actually selected, not on the paths, so this
  -- rides the primary key and cannot pick up a row that merely happens to
  -- share a path.
  insert into public.story_media_purges (story_id, media_path, request_id, attempts, requested_at)
  select s.id, s.media_path, v_request_id, 1, now()
  from public.stories s
  where s.id = any(v_ids);

  return v_count;
end;
$$;

revoke execute on function public.purge_story_media() from public, anon, authenticated;


-- ============================================================
-- reconcile_story_media_purges -- did it actually work?
--
-- This is the function that makes the difference between "we sent a delete" and
-- "the object is gone". pg_net parks responses in net._http_response; this
-- reads them back and only then writes stories.media_deleted_at.
--
-- Status handling, and why 404/400 count as success: Storage answers 200 with
-- the list of removed objects on a normal delete, and 400/404 when the key is
-- not there. "Not there" is the desired end state -- an object deleted by an
-- earlier partially-applied tick, or one whose PUT never landed, is not an
-- error and must not be retried forever. Anything else (401 from a rotated
-- key, 5xx from a bucket outage) leaves completed_at null so the next tick
-- picks the story up again.
--
-- Responses pg_net has not written yet are simply not joined and stay open --
-- one tick's latency, not a lost object. pg_net garbage-collects
-- net._http_response after a few hours; a purge row whose response has aged out
-- without ever being seen also stays open and is retried, which is the safe
-- direction to fail in.
-- ============================================================
create or replace function public.reconcile_story_media_purges()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_done int;
begin
  with answered as (
    select
      q.id,
      q.story_id,
      r.status_code,
      r.error_msg,
      coalesce(r.status_code in (200, 204, 400, 404), false) as gone
    from public.story_media_purges q
    join net._http_response r on r.id = q.request_id
    where q.completed_at is null
  ),

  settled as (
    update public.story_media_purges q
    set status_code = a.status_code,
        last_error = case when a.gone then null else coalesce(a.error_msg, 'storage returned ' || coalesce(a.status_code::text, 'no status')) end,
        completed_at = case when a.gone then now() else null end
    from answered a
    where q.id = a.id
    returning q.story_id, a.gone
  ),

  -- The only place in the schema that sets media_deleted_at. It means "the
  -- Storage API has confirmed this object is not in the bucket", and nothing
  -- weaker is allowed to claim that.
  cleared as (
    update public.stories s
    set media_deleted_at = now()
    from settled
    where s.id = settled.story_id
    and settled.gone
    and s.media_deleted_at is null
    returning 1
  )

  select count(*) into v_done from cleared;

  return v_done;
end;
$$;

revoke execute on function public.reconcile_story_media_purges() from public, anon, authenticated;


-- ============================================================
-- run_story_cleanup -- what the cron actually calls.
--
-- Order matters, and the seam between the second and third step is
-- deliberate: purge_story_media only QUEUES the delete (pg_net sends after
-- commit), so the reconcile in the same call answers for the PREVIOUS tick's
-- requests, not this one's. At a 5-minute cadence that means an object is
-- hidden immediately, deleted within seconds, and confirmed within five
-- minutes -- and the confirmation is what the operator can audit.
-- ============================================================
create or replace function public.run_story_cleanup()
returns table (hidden int, purged int, confirmed int)
language plpgsql
security definer
set search_path = ''
as $$
begin
  hidden := public.expire_stories();
  purged := public.purge_story_media();
  confirmed := public.reconcile_story_media_purges();
  return next;
end;
$$;

revoke execute on function public.run_story_cleanup() from public, anon, authenticated;


-- ============================================================
-- The schedule.
--
-- Every 5 minutes. The cadence is a storage-cost knob and nothing else -- the
-- SELECT policy on stories is what makes an expired story stop being visible,
-- at the instant it expires, whether or not this job ever runs again. A cron
-- outage costs bucket bytes, never a story that outstays its 24 hours.
--
-- unschedule-then-schedule so the migration is idempotent against a database
-- that already has the job (a re-run of `supabase db reset` on a stack where
-- cron.job survived, or a hosted project restored from backup). cron.job is not
-- part of the migration history, so `create ... if not exists` has no analogue
-- here.
-- ============================================================
select cron.unschedule('story-cleanup')
where exists (select 1 from cron.job where jobname = 'story-cleanup');

select cron.schedule(
  'story-cleanup',
  '*/5 * * * *',
  $cron$ select public.run_story_cleanup() $cron$
);
