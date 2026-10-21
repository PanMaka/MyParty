-- Phase 44: the safety net under avatar removal and replacement.
--
-- Phase 44 adds "Remove photo" (backlog 1.1). Like replacement, it is a
-- client sequence: null profiles.avatar_path, then delete the object through
-- the Storage API, which the avatars bucket's owner-folder DELETE policy
-- allows. The second step is best-effort by nature -- the app can die between
-- the two, or the request can fail -- and an avatar is in the one PUBLIC
-- bucket, so an orphan is not merely wasted bytes: it is a photo the user
-- removed that is still served to anyone holding its URL. Replacement has had
-- the same gap since Phase 11, and the account eraser's prefix listing only
-- reaches the folders of erased accounts.
--
-- So: party-cover-sweep's shape, for avatars. Hourly, through the Storage API
-- over pg_net (gotcha 7: a row delete would orphan the bytes), with
-- storage.objects as the only record -- a successful DELETE removes the row,
-- a failed one leaves it for the next run. Same vault secrets via
-- story_cleanup_config(), offset to :47 so the two sweeps do not share a
-- minute.


-- Stale = in the avatars bucket, older than ten minutes, and no profile's
-- avatar_path. Ten minutes is the in-flight margin: replaceAvatar uploads
-- first and writes avatar_path second, so a fresh object is legitimately
-- unreferenced for the length of one round trip. "No profile's", not "not its
-- own folder's owner's", so a folder whose profile is gone is also caught.
--
-- Not granted to any client role: it lists every user's stale objects.
create function public.stale_avatar_objects(p_limit integer default 1000)
returns setof text
language sql
stable
security definer
set search_path = ''
as $$
  select o.name
  from storage.objects o
  where o.bucket_id = 'avatars'
    and o.created_at < now() - interval '10 minutes'
    and not exists (
      select 1 from public.profiles p where p.avatar_path = o.name
    )
  order by o.created_at
  limit greatest(1, least(coalesce(p_limit, 1000), 1000));
$$;

revoke execute on function public.stale_avatar_objects(integer) from public, anon, authenticated;

create function public.sweep_avatars()
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
  from public.stale_avatar_objects(100) n;

  if v_names is null then
    return 0;
  end if;

  select * into v_cfg from public.story_cleanup_config();

  perform net.http_delete(
    url := v_cfg.storage_url || '/object/avatars',
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

revoke execute on function public.sweep_avatars() from public, anon, authenticated;

comment on function public.stale_avatar_objects(integer) is
  'avatars objects no profile points at, older than 10 minutes.';
comment on function public.sweep_avatars() is
  'Hourly: deletes stale avatars objects through the Storage API over pg_net. '
  'The safety net under the client''s best-effort delete on remove/replace.';

select cron.unschedule('avatar-sweep')
where exists (select 1 from cron.job where jobname = 'avatar-sweep');

select cron.schedule(
  'avatar-sweep',
  '47 * * * *',
  $cron$ select public.sweep_avatars() $cron$
);
