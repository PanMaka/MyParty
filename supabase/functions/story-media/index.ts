// story-media -- the only door into the story-media bucket.
//
// The bucket (20260812124217) ships with ZERO storage policies, on purpose:
// storage.objects has RLS enabled, so no permissive policy means no client role
// can read a byte or write one, in either direction. Every upload and every
// view therefore has to come through here, where the service_role key lives,
// and leaves as a short-lived signed URL.
//
// WHAT THIS FUNCTION DOES NOT CONTAIN: any notion of who may see or post a
// story. Not one line of it. Both routes ask Postgres, with the CALLER'S OWN
// JWT, and sign only what Postgres hands back:
//
//   upload  -> public.story_upload_target(id), a security definer RPC that
//              answers only for the author of an unconfirmed, unexpired,
//              unhidden story, and raises otherwise.
//   view    -> a plain select through the caller's JWT, so the RLS policy on
//              public.stories (can_access_party + is_blocked + not hidden +
//              confirmed + unexpired) is what decides which ids survive.
//
// That is the whole design. A copy of the visibility rule here would be a
// second implementation to keep in step with the first (CLAUDE.md #4), and it
// would be the copy holding the service key -- the worst possible place for it
// to drift. In particular note that /view-urls takes story IDS and never paths:
// signing a path the client supplied would hand any authenticated user a
// readable URL for any object in the bucket.

import { createClient } from 'jsr:@supabase/supabase-js@2';

// Uploads get 2 minutes: long enough for a phone on a bad connection to push a
// clip, short enough that a leaked URL is worthless by the time it leaks.
const UPLOAD_URL_TTL_SECONDS = 120;

// Views get 60 seconds. The URL is fetched immediately by an <Image>, and a
// short life means a signed URL that escapes into a log or a screenshot expires
// before it can be shared -- which matters because the RLS check that produced
// it cannot be re-run once the URL exists.
const VIEW_URL_TTL_SECONDS = 60;

// One request should not be able to ask for the whole bucket's worth of
// signatures. A story reel is dozens of frames, never hundreds.
const MAX_VIEW_IDS = 100;

// supabase-js hands back an absolute signed URL; everything after the origin is
// what callers actually need. Tolerates a version that returns a relative one
// already, and never returns something a client would join incorrectly.
const toRelative = (signedUrl: string | null): string | null => {
  if (!signedUrl) return null;
  const marker = signedUrl.indexOf('/storage/v1/');
  if (marker >= 0) return signedUrl.slice(marker);
  return signedUrl.startsWith('/') ? `/storage/v1${signedUrl}` : `/storage/v1/${signedUrl}`;
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return json({ error: 'method not allowed' }, 405);
  }

  // verify_jwt = true means the gateway has already rejected anything without a
  // valid token, so this header is present and genuine. It is forwarded, not
  // parsed: the user's identity is established by Postgres reading auth.uid()
  // off the same token, never by anything this function decodes.
  const authorization = req.headers.get('Authorization');
  if (!authorization) {
    return json({ error: 'missing authorization header' }, 401);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

  // Two clients, and keeping them apart is the point. asUser can do exactly
  // what the person holding the phone can do; asService can do anything to the
  // bucket and is never handed a decision to make.
  const asUser = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });
  const asService = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false },
  });

  const route = new URL(req.url).pathname.split('/').filter(Boolean).pop();

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: 'expected a json body' }, 400);
  }

  // ----------------------------------------------------------------
  // POST /story-media/upload-url  { story_id }
  //
  // The row already exists -- the client inserted it, under RLS, and the
  // before-insert trigger both derived its media_path and charged it against
  // the 10/hour limit. So by the time we get here the expensive questions
  // ("may this person post to this party?", "have they posted too much?") are
  // already answered, in SQL, and this is only asking where the bytes go.
  // ----------------------------------------------------------------
  if (route === 'upload-url') {
    const storyId = payload.story_id;
    if (typeof storyId !== 'string') {
      return json({ error: 'story_id is required' }, 400);
    }

    const { data: path, error } = await asUser.rpc('story_upload_target', {
      p_story_id: storyId,
    });

    // 42501 from the RPC: not the author, or the story is already confirmed,
    // hidden or expired. Reported as 403 with the RPC's own message rather
    // than a bespoke one -- there is exactly one authority on this and it is
    // not this file.
    if (error || !path) {
      return json({ error: error?.message ?? 'no pending upload for that story' }, 403);
    }

    const { data, error: signError } = await asService.storage
      .from('story-media')
      .createSignedUploadUrl(path, { upsert: false });

    // upsert: false is load bearing. story_upload_target already refuses to
    // answer twice for the same story, so this is the second lock on the same
    // door: even a replayed token cannot overwrite media that people have
    // already seen with something else.
    if (signError || !data) {
      return json({ error: signError?.message ?? 'could not sign upload' }, 500);
    }

    return json({
      story_id: storyId,
      path: data.path,
      token: data.token,
      expires_in: UPLOAD_URL_TTL_SECONDS,
    });
  }

  // ----------------------------------------------------------------
  // POST /story-media/view-urls  { story_ids: [...] }
  //
  // ids in, urls out. The select below runs as the user, so RLS silently drops
  // every id they may not see -- an expired story, a blocked author's, a
  // private party they were never invited to. The response therefore contains
  // a url for a subset of what was asked for, and the client renders what it
  // got; asking about a story you cannot see is not an error worth
  // distinguishing from one that has expired, and telling the two apart would
  // itself leak existence.
  // ----------------------------------------------------------------
  if (route === 'view-urls') {
    const ids = payload.story_ids;
    if (!Array.isArray(ids) || ids.some((id) => typeof id !== 'string')) {
      return json({ error: 'story_ids must be an array of uuids' }, 400);
    }
    if (ids.length === 0) return json({ urls: {} });
    if (ids.length > MAX_VIEW_IDS) {
      return json({ error: `at most ${MAX_VIEW_IDS} story_ids per request` }, 400);
    }

    const { data: rows, error } = await asUser
      .from('stories')
      .select('id, media_path')
      .in('id', ids);

    if (error) return json({ error: error.message }, 403);
    if (!rows || rows.length === 0) return json({ urls: {} });

    const { data: signed, error: signError } = await asService.storage
      .from('story-media')
      .createSignedUrls(rows.map((r) => r.media_path), VIEW_URL_TTL_SECONDS);

    if (signError || !signed) {
      return json({ error: signError?.message ?? 'could not sign urls' }, 500);
    }

    // Keyed by story id, not by path: the client knows stories by id and has
    // no business reasoning about bucket layout.
    //
    // And returned PROJECT-RELATIVE ("/storage/v1/object/sign/…"), not as the
    // absolute URL supabase-js builds. That URL is built from SUPABASE_URL as
    // seen from inside the edge runtime, which locally is the container's view
    // of the gateway -- http://kong:8000 -- a hostname that resolves on the
    // docker network and nowhere else. A phone handed that URL cannot load a
    // single frame. Returning the path lets each client join it to the origin
    // it already talks to, which is correct locally and on hosted alike.
    const byPath = new Map(signed.map((s) => [s.path, toRelative(s.signedUrl)]));
    const urls: Record<string, string> = {};
    for (const row of rows) {
      const url = byPath.get(row.media_path);
      // A missing signature means the object is gone while the row still says
      // it is live -- the purge (20260815133041) racing a viewer, or a
      // confirmed upload whose bytes were removed out of band. Skipped rather
      // than returned as a broken url: the viewer drops the frame.
      if (url) urls[row.id] = url;
    }

    return json({ urls, expires_in: VIEW_URL_TTL_SECONDS });
  }

  return json({ error: 'unknown route' }, 404);
});
