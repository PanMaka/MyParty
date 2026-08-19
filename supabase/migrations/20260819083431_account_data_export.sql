-- Phase 9, part 3: data export (GDPR Art. 20, portability).
--
-- The JSON is assembled here rather than in the edge function, and that is the
-- same call every other phase made: the function that holds a key should not
-- be the thing that decides what data means. Here it is also just correct --
-- six correlated result sets assembled in one snapshot is a query, and doing
-- it in TypeScript would be six round trips that can disagree with each other
-- because a message arrived between the third and the fourth.
--
-- security definer, but it reads ONLY auth.uid(). It takes no user id at all,
-- so there is no argument to get wrong and no way to aim it at somebody else.
-- Definer rather than invoker for one specific reason: an export must contain
-- the user's own messages even in a party whose chat they can no longer read
-- (they left, the party ended, the host blocked them). Under invoker rights
-- can_chat_in_party would filter their own words out of their own export.
--
-- What is deliberately NOT in here: anything about other people. A group chat
-- export contains the caller's messages, not the conversation -- the other
-- half is somebody else's personal data and Art. 20 does not reach it.


create or replace function public.export_account_data()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
          pr.onboarding_completed_at,
          pr.location_consent, pr.push_consent, pr.analytics_consent,
          pr.map_visibility, pr.invite_policy,
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
    )

    -- Deliberately absent: user_devices. Its only interesting column is
    -- last_location, which by the time anyone reads this is either null (24h
    -- retention) or a ~100m cell -- and putting a location history into a
    -- downloadable file is the one thing 7.2 spent a whole phase preventing.
    -- The current cell is shown live in the app instead.
  ) into v_out;

  return v_out;
end;
$$;

revoke execute on function public.export_account_data() from public, anon;
grant  execute on function public.export_account_data() to authenticated;
-- The account-export edge function calls this with the CALLER's JWT, not the
-- service key, so this grant to authenticated is the one that matters. The
-- service_role grant exists only so an operator can answer a subject access
-- request by hand.
grant  execute on function public.export_account_data() to service_role;

comment on function public.export_account_data() is
  'GDPR Art. 20 export for the CALLING user only -- takes no user id. Definer so the caller''s own messages survive can_chat_in_party filtering in parties they have since left.';
