-- Phase 48: "People you may know" on the owner's Profile tab.
--
-- One read, get_follow_suggestions(), ranks three tiers server-side:
--
--   1. mutuals      accounts followed by people I follow, most mutuals first
--   2. follows_you  accounts that follow me and I do not follow back, newest first
--   3. popular      the fallback: discoverable accounts by follower_count
--
-- Each account appears once, in its best tier. Party attendance is never an
-- input: "people who went to the parties you went to" would tell you who went
-- to which party, which no other surface does (rsvps are host-and-self only).
-- Everything here is read off the follow graph, which the follows SELECT policy
-- already shows to every signed-in user, minus block-paired edges.
--
-- WHY DEFINER. Every candidate is filtered on suggest_account, which is an
-- owner-only column (Phase 45 rules), so the caller cannot read it. Definer
-- runs past RLS, which means every rule the policies would have applied is
-- applied here instead, by name:
--   * blocks, through is_blocked(auth.uid(), x) -- the caller is one side, so
--     the Phase 46 caller-only rule answers truthfully (it is not
--     blocked_between, which no client role may execute);
--   * is_discoverable, the public bit search and the invite picker use;
--   * onboarding_completed_at, so a placeholder username is never suggested.
-- And it takes no user id: it answers for auth.uid() and nobody else, the
-- same shape as get_my_settings. With a viewer argument it would read another
-- user's follow graph through their own eyes, which is harmless today (the
-- graph is public) but is exactly the per-user variant gotcha 11 keeps away
-- from clients.
--
-- What it returns is public already: id, username, avatar_path, and usernames
-- of mutuals, each of which the caller could read off a follower list. It
-- returns no private column. It READS two (suggest_account and
-- onboarding_completed_at), so it is on 40_profile_private_columns' reviewed
-- list.
--
-- The opt-out hides an account from all three tiers, "Follows you" included
-- (decided). That leaves one weak inference: someone who follows you and is
-- never suggested has opted out, been dismissed by you, or is pending deletion.
-- It is the same order of bit is_discoverable already reveals; accepted.
-- The caller's OWN opt-out does not change what they see (decided).


-- ===========================================================================
-- 1. The setting: "Suggest my account to others".
--
-- Owner-only, like the three privacy tiers: written through the Phase 44
-- UPDATE allow-list (a PATCH with return=minimal), read back only through
-- get_my_settings(). 40_profile_private_columns classifies it private.
-- ===========================================================================
alter table public.profiles
  add column suggest_account boolean not null default true;

comment on column public.profiles.suggest_account is
  'Whether get_follow_suggestions may suggest this account to other users. '
  'Owner-only (Phase 48); does not affect what the owner is suggested.';

grant update (suggest_account) on public.profiles to authenticated;


-- ===========================================================================
-- 2. Dismissals.
--
-- (user_id, dismissed_id): "user_id pressed X on dismissed_id's card". The
-- client holds SELECT on its own rows and no write grant at all: the two
-- functions below are the only doors, so "you can only undo your own" is true
-- by construction rather than by a policy that could be widened.
--
-- FKs without cascade, per the Phase 9 audit: profiles rows are never deleted,
-- and erasure deletes these rows itself (both sides, section 5).
-- No limit on the number of rows (decided): one small row each, gone on
-- erasure.
-- ===========================================================================
create table public.follow_suggestion_dismissals (
  user_id      uuid not null references public.profiles(id),
  dismissed_id uuid not null references public.profiles(id),
  created_at   timestamptz not null default now(),
  constraint follow_suggestion_dismissals_pkey primary key (user_id, dismissed_id),
  constraint follow_suggestion_dismissals_not_self check (user_id <> dismissed_id)
);

-- Erasure deletes by dismissed_id too; the primary key only serves user_id.
create index follow_suggestion_dismissals_dismissed_idx
  on public.follow_suggestion_dismissals (dismissed_id);

alter table public.follow_suggestion_dismissals enable row level security;

create policy "Users can view their own dismissals"
on public.follow_suggestion_dismissals for select to authenticated
using ( user_id = (select auth.uid()) );

revoke all on public.follow_suggestion_dismissals from anon, authenticated;
grant select on public.follow_suggestion_dismissals to authenticated;

comment on table public.follow_suggestion_dismissals is
  'Accounts the user dismissed from "People you may know". Owner-read-only; '
  'written only by dismiss_follow_suggestion / undismiss_follow_suggestion. '
  'Exported; deleted on erasure (both sides).';


-- ---------------------------------------------------------------------------
-- dismiss: silent on an unknown id or a repeat, so its answer says nothing
-- about which ids exist. Refuses only self, which the caller already knows.
-- ---------------------------------------------------------------------------
create function public.dismiss_follow_suggestion(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if p_user_id is null or p_user_id = v_uid then
    raise exception 'cannot dismiss this account' using errcode = '22023';
  end if;

  insert into public.follow_suggestion_dismissals (user_id, dismissed_id)
  select v_uid, pr.id
  from public.profiles pr
  where pr.id = p_user_id
  on conflict on constraint follow_suggestion_dismissals_pkey do nothing;
end;
$$;

-- ---------------------------------------------------------------------------
-- undismiss: the snackbar's Undo. Deletes the CALLER's row for that account,
-- and can name no other user_id. A no-op when there is nothing to undo.
-- ---------------------------------------------------------------------------
create function public.undismiss_follow_suggestion(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  delete from public.follow_suggestion_dismissals d
  where d.user_id = v_uid
    and d.dismissed_id = p_user_id;
end;
$$;

revoke execute on function public.dismiss_follow_suggestion(uuid) from public, anon;
grant  execute on function public.dismiss_follow_suggestion(uuid) to authenticated;
revoke execute on function public.undismiss_follow_suggestion(uuid) from public, anon;
grant  execute on function public.undismiss_follow_suggestion(uuid) to authenticated;

comment on function public.dismiss_follow_suggestion(uuid) is
  'Stop suggesting this account to the caller. Silent on unknown ids and repeats.';
comment on function public.undismiss_follow_suggestion(uuid) is
  'Undo the caller''s own dismissal of this account. Cannot touch another user''s rows.';


-- ===========================================================================
-- 3. get_follow_suggestions
--
-- Keyset over one ascending triple, (sort_tier, sort_rank, user_id), the same
-- shape as get_parties_list: descending keys are negated so a single row
-- comparison pages every tier, and the cursor columns are returned for the
-- client to echo back.
--
--   tier 1  sort_rank = -(mutual_count << 32 | follower_count)
--           most mutuals first, then the more-followed account. Both are
--           non-negative int4, so the packed value fits a bigint exactly; the
--           tie-break is what stops "followed by 1" (the common case) coming
--           out in uuid order.
--   tier 2  sort_rank = -epoch milliseconds of their follow: newest first.
--   tier 3  sort_rank = -follower_count.
--
-- The ranking is recomputed on every page, so a page boundary can move if the
-- graph changes between calls. Keyset still never repeats a row it has already
-- passed for a given position; an account that changes tier between pages can
-- be skipped or seen twice, and the client dedupes by user_id.
--
-- MUTUALS are people I follow who are discoverable and not block-paired with
-- me. A block deletes follow edges both ways and the follows INSERT policy
-- refuses a new one, so the block term never fires through the app; it is
-- here because "never show a mutual who is block-paired with me" must not
-- depend on a trigger in another file. The count and the names come from that
-- same filtered set, so the label can never say "and 2 others" about people
-- it is not allowed to name.
--
-- BLOCKS are decided by is_blocked, called once per account that shares a
-- blocks row with me (block_peers: two index probes, usually zero rows), and
-- then applied as an anti-join. The probes only ENUMERATE whom to ask; the
-- helper still answers, so the rule has one copy. The obvious spellings were
-- measured and lost (scripts/explain_follow_suggestions.sh, 20k users):
-- is_blocked per candidate put the call on a seq scan of profiles, 19.4k calls
-- and 614ms; per mutual it is ~37us a call, ~18ms for someone following 500.
-- The enumeration is sound because is_blocked is true only where a blocks row
-- joins the pair (blocked_between). If that ever widens beyond the blocks
-- table, block_peers has to widen with it.
--
-- POPULAR is bounded to the 200 most-followed eligible accounts. It is a
-- fallback, not a directory: search is the directory.
-- ===========================================================================
create function public.get_follow_suggestions(
  p_cursor_tier smallint default null,
  p_cursor_rank bigint default null,
  p_cursor_id uuid default null,
  p_limit integer default 20
)
returns table (
  user_id          uuid,
  username         text,
  avatar_path      text,
  reason           text,
  follows_you      boolean,
  mutual_count     integer,
  mutual_usernames text[],
  sort_tier        smallint,
  sort_rank        bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  return query
  with block_peers as materialized (
    select x.id
    from (
      select b.blocked_id as id from public.blocks b where b.blocker_id = v_uid
      union
      select b.blocker_id from public.blocks b where b.blocked_id = v_uid
    ) x
    where public.is_blocked(v_uid, x.id)
  ),
  mutuals as materialized (
    select pr.id, pr.username, pr.follower_count
    from public.follows f
    join public.profiles pr on pr.id = f.followee_id
    where f.follower_id = v_uid
      and pr.is_discoverable
      and not exists (select 1 from block_peers bp where bp.id = pr.id)
  ),
  fof as (
    select f2.followee_id as candidate_id, count(*)::int as n
    from mutuals m
    join public.follows f2 on f2.follower_id = m.id
    group by f2.followee_id
  ),
  follows_me as (
    select f.follower_id as candidate_id, f.created_at
    from public.follows f
    where f.followee_id = v_uid
  ),
  -- The cheap half of eligibility runs here too, BEFORE the limit, or a user
  -- who already follows most of the top 200 would get an empty fallback.
  popular as (
    select pr.id as candidate_id
    from public.profiles pr
    where pr.is_discoverable
      and pr.suggest_account
      and pr.onboarding_completed_at is not null
      and pr.follower_count > 0
      and pr.id <> v_uid
      and not exists (
        select 1 from public.follows f
        where f.follower_id = v_uid and f.followee_id = pr.id
      )
      and not exists (
        select 1 from public.follow_suggestion_dismissals d
        where d.user_id = v_uid and d.dismissed_id = pr.id
      )
    order by pr.follower_count desc, pr.id
    limit 200
  ),
  candidates as (
    select fo.candidate_id from fof fo
    union
    select fm.candidate_id from follows_me fm
    union
    select po.candidate_id from popular po
  ),
  ranked as (
    select
      pr.id,
      pr.username,
      pr.avatar_path,
      fo.n,
      fm.candidate_id is not null as follows_me,
      case
        when fo.n is not null then 1
        when fm.candidate_id is not null then 2
        else 3
      end::smallint as tier,
      case
        when fo.n is not null then -((fo.n::bigint << 32) | pr.follower_count::bigint)
        when fm.candidate_id is not null then -(extract(epoch from fm.created_at) * 1000)::bigint
        else -pr.follower_count::bigint
      end as rnk
    from candidates c
    join public.profiles pr on pr.id = c.candidate_id
    left join fof fo on fo.candidate_id = c.candidate_id
    left join follows_me fm on fm.candidate_id = c.candidate_id
    where pr.id <> v_uid
      and pr.is_discoverable
      and pr.suggest_account
      and pr.onboarding_completed_at is not null
      and not exists (
        select 1 from public.follows f
        where f.follower_id = v_uid and f.followee_id = pr.id
      )
      and not exists (
        select 1 from public.follow_suggestion_dismissals d
        where d.user_id = v_uid and d.dismissed_id = pr.id
      )
      and not exists (select 1 from block_peers bp where bp.id = pr.id)
  ),
  page as (
    select r.*
    from ranked r
    where p_cursor_tier is null
       or (r.tier, r.rnk, r.id) > (p_cursor_tier, p_cursor_rank, p_cursor_id)
    order by r.tier, r.rnk, r.id
    limit greatest(1, least(coalesce(p_limit, 20), 50))
  )
  select
    pg.id,
    pg.username,
    pg.avatar_path,
    case pg.tier when 1 then 'mutuals' when 2 then 'follows_you' else 'popular' end,
    pg.follows_me,
    coalesce(pg.n, 0),
    -- Names for the page's rows only: choosing two per candidate inside fof
    -- meant sorting every two-hop row by username (197k rows, spilled to disk,
    -- ~40ms for the worst viewer). From the same filtered `mutuals`, so a name
    -- is never someone the count left out. Each mutual must be ONE probe of
    -- follows_pkey (mutual, candidate). As a join, or as a plain EXISTS (which
    -- the planner pulls up into the same semi-join), it hashed the candidate's
    -- whole follower list instead -- thousands of rows per page row for a
    -- popular account, 2.2-2.5ms x 20 measured. `offset 0` keeps the EXISTS a
    -- correlated probe.
    case when pg.tier = 1 then array(
      select m.username
      from mutuals m
      where exists (
        select 1 from public.follows f
        where f.follower_id = m.id and f.followee_id = pg.id
        offset 0
      )
      order by m.follower_count desc, m.username
      limit 2
    ) else '{}'::text[] end,
    pg.tier,
    pg.rnk
  from page pg
  order by pg.tier, pg.rnk, pg.id;
end;
$$;

revoke execute on function public.get_follow_suggestions(smallint, bigint, uuid, integer) from public, anon;
grant  execute on function public.get_follow_suggestions(smallint, bigint, uuid, integer) to authenticated;

comment on function public.get_follow_suggestions(smallint, bigint, uuid, integer) is
  '"People you may know" for the CALLER only (no user id). Tiers: mutuals, '
  'follows_you, popular. Excludes self, followed, block-paired, '
  'non-discoverable, not onboarded, opted out (suggest_account) and dismissed '
  'accounts. Mutual names never include a block-paired or non-discoverable '
  'account. Keyset over (sort_tier, sort_rank, user_id). Phase 48.';


-- ===========================================================================
-- 4. get_my_settings gains suggest_account.
--
-- A RETURNS TABLE change is a drop, not a replace. Body otherwise as
-- 20261021121734.
-- ===========================================================================
drop function public.get_my_settings();

create function public.get_my_settings()
returns table (
  onboarding_completed_at timestamptz,
  deleted_at              timestamptz,
  location_consent        boolean,
  push_consent            boolean,
  analytics_consent       boolean,
  notify_nearby           boolean,
  notify_radius_meters    integer,
  notify_daily_cap        integer,
  quiet_hours_start       time,
  quiet_hours_end         time,
  notification_tz         text,
  map_visibility          public.map_visibility,
  invite_policy           public.invite_policy,
  dm_policy               public.dm_policy,
  suggest_account         boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    pr.onboarding_completed_at,
    pr.deleted_at,
    pr.location_consent,
    pr.push_consent,
    pr.analytics_consent,
    pr.notify_nearby,
    pr.notify_radius_meters,
    pr.notify_daily_cap,
    pr.quiet_hours_start,
    pr.quiet_hours_end,
    pr.notification_tz,
    pr.map_visibility,
    pr.invite_policy,
    pr.dm_policy,
    pr.suggest_account
  from public.profiles pr
  where pr.id = (select auth.uid());
$$;

revoke execute on function public.get_my_settings() from public, anon;
grant  execute on function public.get_my_settings() to authenticated;

comment on function public.get_my_settings() is
  'The caller''s own owner-only profiles columns: consents, notification '
  'settings, quiet hours, time zone, privacy tiers, suggest_account, '
  'onboarding and deletion state. The client''s only read of them since Phase 45.';


-- ===========================================================================
-- 5. Export and erasure.
--
-- The export carries suggest_account and the dismissals (ids and dates, like
-- follows: who you dismissed is also a fact about them). Erasure deletes the
-- dismissals on BOTH sides: the erased user's own, and other people's rows
-- naming a tombstone that can never be suggested again. Both bodies otherwise
-- as live before this migration.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.export_account_data()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := (select auth.uid());
  v_out jsonb;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select jsonb_build_object(
    -- A header, so a file that outlives the conversation about it still says
    -- what it is and when it was true.
    'export_format_version', 1,
    'exported_at', now(),
    'user_id', v_uid,

    'profile', (
      -- Column list spelled out rather than to_jsonb(pr): credibility_score
      -- must not appear. Phase 8 decided it ships no score, and a zero in an
      -- export file is a number a person will ask about.
      select to_jsonb(p)
      from (
        select
          pr.id, pr.username, pr.created_at,
          pr.bio, pr.avatar_path,
          pr.onboarding_completed_at,
          pr.location_consent, pr.push_consent, pr.analytics_consent,
          pr.map_visibility, pr.invite_policy, pr.dm_policy,
          pr.suggest_account,
          pr.notify_nearby, pr.notify_radius_meters,
          pr.quiet_hours_start, pr.quiet_hours_end,
          pr.follower_count, pr.following_count,
          pr.deleted_at
        from public.profiles pr
        where pr.id = v_uid
      ) p
    ),

    -- Hosted parties. location is emitted as lon/lat rather than the PostGIS
    -- binary, because an export the subject cannot read is not an export.
    'parties', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pa.id,
        'title', pa.title,
        'description', pa.description,
        'area', pa.area,
        'address', pa.address,
        'cover_path', pa.cover_path,
        'longitude', public.st_x(pa.location::public.geometry),
        'latitude', public.st_y(pa.location::public.geometry),
        'starts_at', pa.starts_at,
        'ends_at', pa.ends_at,
        'status', pa.status,
        'is_private', pa.is_private,
        'party_tier', pa.party_tier,
        'max_capacity', pa.max_capacity,
        'going_count', pa.going_count,
        'interested_count', pa.interested_count,
        'created_at', pa.created_at
      ) order by pa.created_at)
      from public.parties pa
      where pa.host_id = v_uid
    ), '[]'::jsonb),

    'rsvps', coalesce((
      select jsonb_agg(jsonb_build_object(
        'party_id', r.party_id,
        'party_title', pa.title,
        'status', r.status,
        'created_at', r.created_at
      ) order by r.created_at)
      from public.rsvps r
      join public.parties pa on pa.id = r.party_id
      where r.user_id = v_uid
    ), '[]'::jsonb),

    -- Parties whose host removed the subject from the guest list: data held
    -- about them, and nothing they do not already know -- the party
    -- disappeared for them. Party ids and dates only, no title: a private
    -- party they can no longer see should not have its name re-delivered here.
    'party_removals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'party_id', g.party_id,
        'removed_at', g.removed_at
      ) order by g.removed_at)
      from public.party_guest_removals g
      where g.user_id = v_uid
    ), '[]'::jsonb),

    'posts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pp.id,
        'party_id', pp.party_id,
        'body', pp.body,
        'media_path', pp.media_path,
        'like_count', pp.like_count,
        'comment_count', pp.comment_count,
        'created_at', pp.created_at,
        -- If a moderator hid it, the subject is entitled to know that it
        -- happened and why. Who did it is not theirs.
        'hidden_at', pp.hidden_at,
        'hidden_reason', pp.hidden_reason
      ) order by pp.created_at)
      from public.party_posts pp
      where pp.author_id = v_uid
    ), '[]'::jsonb),

    -- Not in the Phase 9 brief's list of five, added deliberately: a comment
    -- is text the user wrote, and an export that returns their posts but not
    -- their comments is an incomplete Art. 20 response.
    'comments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', pc.id,
        'post_id', pc.post_id,
        'body', pc.body,
        'created_at', pc.created_at,
        'hidden_at', pc.hidden_at,
        'hidden_reason', pc.hidden_reason
      ) order by pc.created_at)
      from public.post_comments pc
      where pc.author_id = v_uid
    ), '[]'::jsonb),

    'messages', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id,
        'party_id', m.party_id,
        'party_title', pa.title,
        'body', m.body,
        'created_at', m.created_at,
        'hidden_at', m.hidden_at,
        'hidden_reason', m.hidden_reason
      ) order by m.created_at)
      from public.messages m
      join public.parties pa on pa.id = m.party_id
      where m.author_id = v_uid
    ), '[]'::jsonb),

    -- thread_id and the other member's id, as ids only -- the same reasoning
    -- as the follows block: who someone talks to is also a fact about the
    -- person on the other end.
    'direct_messages', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', dm.id,
        'thread_id', dm.thread_id,
        'recipient_id', case when t.user_low = v_uid then t.user_high else t.user_low end,
        'body', dm.body,
        'created_at', dm.created_at,
        'hidden_at', dm.hidden_at,
        'hidden_reason', dm.hidden_reason
      ) order by dm.created_at)
      from public.direct_messages dm
      join public.direct_threads t on t.id = dm.thread_id
      where dm.author_id = v_uid
    ), '[]'::jsonb),

    -- Not content, but it is unambiguously data held about the subject, and
    -- it is the part a privacy-minded person is most likely to be asking
    -- about. Emitted as ids and timestamps only: who someone follows is also
    -- a fact about the person on the other end.
    'follows', jsonb_build_object(
      'following', coalesce((
        select jsonb_agg(jsonb_build_object('user_id', f.followee_id, 'created_at', f.created_at)
               order by f.created_at)
        from public.follows f where f.follower_id = v_uid
      ), '[]'::jsonb),
      'followers', coalesce((
        select jsonb_agg(jsonb_build_object('user_id', f.follower_id, 'created_at', f.created_at)
               order by f.created_at)
        from public.follows f where f.followee_id = v_uid
      ), '[]'::jsonb)
    ),

    -- Provided by the subject at sign-up (Art. 20). Null for accounts that
    -- predate the age gate.
    'date_of_birth', (
      select b.date_of_birth from public.user_birthdates b where b.user_id = v_uid
    ),

    -- NEW. Provided by the subject. Null = not specified, which includes
    -- "prefer not to say" (stored as no row).
    'gender', (
      select g.gender from public.user_genders g where g.user_id = v_uid
    ),

    -- NEW (Phase 44, backlog 1.32). Owner-only, given by the subject.
    'first_name', (
      select n.first_name from public.user_names n where n.user_id = v_uid
    ),
    'last_name', (
      select n.last_name from public.user_names n where n.user_id = v_uid
    ),

    -- NEW. Null if the username was never changed after onboarding.
    'username_change', (
      select jsonb_build_object(
        'previous_username', c.previous_username,
        'changed_at', c.changed_at
      )
      from public.username_changes c where c.user_id = v_uid
    ),

    -- NEW. When consent was last given; the current state is in `profile`.
    -- Null where it was given before Phase 44 recorded the moment.
    'consents', (
      select jsonb_build_object(
        'location_consent_at', uc.location_consent_at,
        'push_consent_at', uc.push_consent_at
      )
      from public.user_consents uc where uc.user_id = v_uid
    ),

    -- NEW (Phase 48). Accounts the subject dismissed from "People you may
    -- know", as ids and dates for the same reason as follows.
    'follow_suggestion_dismissals', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', d.dismissed_id, 'created_at', d.created_at)
             order by d.created_at)
      from public.follow_suggestion_dismissals d where d.user_id = v_uid
    ), '[]'::jsonb)

    -- Deliberately absent: user_devices. Its only interesting column is
    -- last_location, which by the time anyone reads this is either null (24h
    -- retention) or a ~100m cell -- and putting a location history into a
    -- downloadable file is the one thing 7.2 spent a whole phase preventing.
    -- The current cell is shown live in the app instead.
  ) into v_out;

  return v_out;
end;
$function$

;

comment on function public.export_account_data() is
  'GDPR Art. 20 export for the CALLING user only -- takes no user id. Includes bio, avatar_path, dm_policy, each hosted party''s area, address and cover_path, the direct messages the user wrote, the parties whose host removed them (ids and dates), their gender, first and last name, their last username change, when location/push consent was given, suggest_account and their follow-suggestion dismissals. Definer so the caller''s own messages survive can_chat_in_party filtering in parties they have since left, and their DMs survive a block.';


CREATE OR REPLACE FUNCTION public.complete_account_erasure(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  -- outlives its subject (20260815133041).
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
  delete from public.party_guest_removals where user_id = p_user_id;
  delete from public.follows        where follower_id = p_user_id or followee_id = p_user_id;
  delete from public.party_reads    where user_id   = p_user_id;
  delete from public.direct_reads   where user_id   = p_user_id;
  delete from public.user_birthdates where user_id  = p_user_id;
  -- NEW. Kept through the grace period like the date of birth, so a cancelled
  -- deletion leaves the account whole.
  delete from public.user_genders   where user_id   = p_user_id;
  -- NEW (Phase 44). Same grace-period reasoning as the two above.
  delete from public.user_names       where user_id = p_user_id;
  delete from public.username_changes where user_id = p_user_id;
  delete from public.user_consents    where user_id = p_user_id;
  -- NEW (Phase 48). Both sides: theirs, and other people's naming them.
  delete from public.follow_suggestion_dismissals
  where user_id = p_user_id or dismissed_id = p_user_id;

  -- Re-run of the PURGE NOW set from request_account_deletion. Not redundant:
  -- a device or job could have been created between the soft delete and now by
  -- a client holding a still-valid JWT, and this is the last chance to catch it.
  delete from public.user_devices       where user_id = p_user_id;
  delete from public.notification_jobs  where user_id = p_user_id;
  delete from public.sent_notifications where user_id = p_user_id;

  -- ---- RETAIN, with the media stripped. ----
  update public.party_posts
  set media_path = null,
      media_type = null,
      media_uploaded_at = null
  where author_id = p_user_id
    and media_path is not null
    and body is not null;

  update public.party_posts
  set hidden_at     = coalesce(hidden_at, now()),
      hidden_reason = coalesce(hidden_reason, 'account erased')
  where author_id = p_user_id
    and media_path is not null
    and body is null;

  -- NEW (20261020105039). A party's address is often the host's home, so it
  -- goes with them. The party itself stays -- guests' messages and posts hang
  -- off it -- and its pin, title, area and description are untouched; an
  -- address typed into a description before Phase 42 is NOT caught here
  -- (docs/backlog.md 1.33).
  update public.parties
  set address = null
  where host_id = p_user_id
    and address is not null;

  -- ---- The tombstone. ----
  v_handle := 'deleted_' || replace(p_user_id::text, '-', '');

  update public.profiles
  set username           = v_handle,
      -- A self-description and an avatar are as identifying as the handle
      -- they sit next to; scrubbing one and keeping the other two produces a
      -- tombstone that still names a person.
      bio                = null,
      avatar_path        = null,
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
$function$;

