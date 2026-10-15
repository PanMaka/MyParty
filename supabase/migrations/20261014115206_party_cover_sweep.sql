-- Phase 39: the safety net under party-cover/cleanup.
--
-- 20261014113214 made cover replacement leave the old object behind for the
-- party-cover edge function's `cleanup` route to delete, and the client calls
-- that route after every successful replacement. That is the primary path, and
-- it is best-effort by nature: the app can be killed between the confirm and
-- the cleanup call, a cover replaced twice inside the 10-minute floor leaves
-- the middle one, and an upload whose confirm never happened is referenced by
-- nothing at all. Without a second path each of those is a file nothing will
-- ever collect -- the same failure story-cleanup exists to prevent.
--
-- So: an hourly pg_cron job deleting every party-covers object no party points
-- at, through the Storage API over pg_net (gotcha 7 -- a row delete would
-- orphan the bytes).
--
-- Simpler than story-cleanup on purpose: no purge-tracking table and no
-- reconcile step. storage.objects is itself the record of what is still there.
-- A successful DELETE removes the row, and a failed one leaves it for the next
-- run to try again, so the job is idempotent with nothing of its own to keep
-- in step.
--
-- It reuses story-cleanup's two vault secrets through story_cleanup_config()
-- rather than adding a third: both jobs need exactly the storage URL and a
-- service key, and a second copy of the key is a second thing to rotate.


-- ===========================================================================
-- 1. One definition of "stale", for both callers.
--
-- party_cover_stale_objects (20261014113214) answered this for one party. The
-- sweep needs it for all of them, and two spellings of the rule would drift
-- (rule 4), so the body moves here and the host-facing function delegates to
-- it after its host check.
--
-- Stale = in the party-covers bucket, older than ten minutes, and not any
-- party's cover_path. "Not any party's", rather than "not its own folder's
-- party's", also catches the folder of a party that no longer exists. The
-- ten minutes is the in-flight margin from 20261014113214: a signed upload
-- URL lives 120s.
--
-- Not granted to any client role: it lists every party's stale objects.
-- ===========================================================================
create or replace function public.stale_party_cover_objects(
  p_party_id uuid default null,
  p_limit integer default 1000
)
returns setof text
language sql
stable
security definer
set search_path = ''
as $$
  select o.name
  from storage.objects o
  where o.bucket_id = 'party-covers'
    and (p_party_id is null or starts_with(o.name, p_party_id::text || '/'))
    and o.created_at < now() - interval '10 minutes'
    and not exists (
      select 1 from public.parties p where p.cover_path = o.name
    )
  order by o.created_at
  limit greatest(1, least(coalesce(p_limit, 1000), 1000));
$$;

revoke execute on function public.stale_party_cover_objects(uuid, integer) from public;

create or replace function public.party_cover_stale_objects(p_party_id uuid)
returns setof text
language plpgsql
security definer
set search_path = ''
stable
as $$
begin
  if not public.is_party_host(p_party_id) then
    raise exception 'not the host of party %', p_party_id using errcode = '42501';
  end if;

  return query select public.stale_party_cover_objects(p_party_id);
end;
$$;


-- ===========================================================================
-- 2. The sweep.
--
-- One DELETE request per run, for at most 100 objects, the same batch size
-- purge_story_media uses. A backlog bigger than that drains over a few hours,
-- which is fine for files nobody can see.
--
-- Raises P0002 (via story_cleanup_config) when vault is not configured, as
-- story-cleanup does -- the cron run logs the failure rather than reporting a
-- quiet zero.
-- ===========================================================================
create or replace function public.sweep_party_covers()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cfg record;
  v_names text[];
begin
  select array_agg(n) into v_names
  from public.stale_party_cover_objects(null, 100) n;

  if v_names is null then
    return 0;
  end if;

  select * into v_cfg from public.story_cleanup_config();

  perform net.http_delete(
    url := v_cfg.storage_url || '/object/party-covers',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_cfg.service_key,
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object('prefixes', to_jsonb(v_names)),
    timeout_milliseconds := 20000
  );

  return cardinality(v_names);
end;
$$;

revoke execute on function public.sweep_party_covers() from public;

comment on function public.stale_party_cover_objects(uuid, integer) is
  'party-covers objects no party points at, older than 10 minutes. The one '
  'definition behind party_cover_stale_objects and sweep_party_covers.';
comment on function public.sweep_party_covers() is
  'Hourly: deletes stale party-covers objects through the Storage API over '
  'pg_net. The safety net under the client''s party-cover/cleanup call.';

select cron.unschedule('party-cover-sweep')
where exists (select 1 from cron.job where jobname = 'party-cover-sweep');

select cron.schedule(
  'party-cover-sweep',
  '17 * * * *',
  $cron$ select public.sweep_party_covers() $cron$
);
