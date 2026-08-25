// post-media -- the only door INTO the post-media bucket.
//
// One route, not two, and the asymmetry is the whole design note.
//
// The post-media bucket (20260812124217) has a SELECT policy: "Post media
// follows party visibility", an exists() against public.parties that re-runs
// the parties SELECT policy for the querying role. So READING is already
// solved without a service key -- any client can call createSignedUrl itself
// and RLS decides whether it gets one. That is what PartyRepository does for
// party-covers, and post media resolves the same way.
//
// WRITING has no such policy, deliberately: "uploads go through signed URLs
// only, never a direct client write". There is no INSERT policy on the bucket
// for any role, so a signed upload URL can only be minted by something holding
// the service key. That is this function, and that is all it does.
//
// Contrast story-media, which needs BOTH routes because its bucket ships zero
// policies in either direction. Adding a view route here would mean holding the
// service key while re-deciding a question the storage policy already answers
// correctly -- a second implementation of party visibility, in the process with
// the most authority. See CLAUDE.md #4.
//
// WHAT THIS FUNCTION DOES NOT CONTAIN: any notion of who may post to a party.
// Not one line. It asks Postgres with the CALLER'S OWN JWT via
// public.post_upload_target(id) -- a security definer RPC that answers only for
// the author of an unconfirmed, unhidden media post -- and signs only the path
// Postgres hands back. It never accepts a path from the client: signing a
// client-supplied path would let any authenticated user aim an upload at any
// object in the bucket.

import { createClient } from 'jsr:@supabase/supabase-js@2';

// Two minutes: long enough for a phone on a bad connection to push a photo,
// short enough that a leaked URL is worthless by the time it leaks. Same
// number story-media uses, for the same reason.
const UPLOAD_URL_TTL_SECONDS = 120;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return json({ error: 'method not allowed' }, 405);
  }

  // verify_jwt = true means the gateway already rejected anything without a
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
  // POST /post-media/upload-url  { post_id }
  //
  // The row already exists -- the client inserted it, under RLS, and the
  // before-insert trigger both derived its media_path and charged it against
  // the 30/hour limit. So by the time we get here the expensive questions
  // ("does this person HOST this party?", "have they posted too much?") are
  // already answered, in SQL, and this is only asking where the bytes go.
  // ----------------------------------------------------------------
  if (route === 'upload-url') {
    const postId = payload.post_id;
    if (typeof postId !== 'string') {
      return json({ error: 'post_id is required' }, 400);
    }

    const { data: path, error } = await asUser.rpc('post_upload_target', {
      p_post_id: postId,
    });

    // 42501 from the RPC: not the author, no media declared, or the post is
    // already confirmed or hidden. Reported as 403 with the RPC's own message
    // rather than a bespoke one -- there is exactly one authority on this and
    // it is not this file.
    if (error || !path) {
      return json({ error: error?.message ?? 'no pending upload for that post' }, 403);
    }

    const { data, error: signError } = await asService.storage
      .from('post-media')
      .createSignedUploadUrl(path, { upsert: false });

    // upsert: false is load bearing. post_upload_target already refuses to
    // answer twice for the same post, so this is the second lock on the same
    // door: even a replayed token cannot overwrite media people have already
    // seen with something else.
    if (signError || !data) {
      return json({ error: signError?.message ?? 'could not sign upload' }, 500);
    }

    return json({
      post_id: postId,
      path: data.path,
      token: data.token,
      expires_in: UPLOAD_URL_TTL_SECONDS,
    });
  }

  return json({ error: 'unknown route' }, 404);
});
