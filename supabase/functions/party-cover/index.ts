// party-cover -- the only door INTO the party-covers bucket.
//
// A copy of post-media's shape, for the same reasons, and read that file first:
// the bucket has a SELECT policy following party visibility, so reads are
// signed client-side under RLS (PartyRepository.signedCoverUrls) and only the
// upload side needs the service key. Two routes: upload-url (first cover, or a
// replacement with replace: true) and cleanup (delete what a replacement left
// behind).
//
// WHAT THIS FUNCTION DOES NOT CONTAIN: any notion of who may set a cover. It
// asks Postgres with the CALLER'S OWN JWT via
// public.party_cover_upload_target(id) -- which answers only for the host of a
// party that has no cover yet -- and signs only the path Postgres hands back.
// It never accepts a path from the client.

import { createClient } from 'jsr:@supabase/supabase-js@2';

// Same two minutes as post-media and story-media.
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

  // Forwarded, never parsed -- identity is auth.uid() in Postgres.
  const authorization = req.headers.get('Authorization');
  if (!authorization) {
    return json({ error: 'missing authorization header' }, 401);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

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
  // POST /party-cover/upload-url  { party_id, replace?: boolean }
  //
  // replace: false (the default) is the one-shot first cover at
  // {party_id}/cover. replace: true asks for a FRESH key from
  // party_cover_replace_target -- a replacement never overwrites, so
  // upsert: false holds for both.
  // ----------------------------------------------------------------
  if (route === 'upload-url') {
    const partyId = payload.party_id;
    if (typeof partyId !== 'string') {
      return json({ error: 'party_id is required' }, 400);
    }
    const replace = payload.replace === true;

    const { data: path, error } = await asUser.rpc(
      replace ? 'party_cover_replace_target' : 'party_cover_upload_target',
      { p_party_id: partyId },
    );

    // 42501: not the host, the party is cancelled, or (first cover only) it
    // already has one.
    if (error || !path) {
      return json({ error: error?.message ?? 'no pending cover for that party' }, 403);
    }

    // upsert: false -- the second lock on the one-shot door, as in post-media.
    const { data, error: signError } = await asService.storage
      .from('party-covers')
      .createSignedUploadUrl(path, { upsert: false });

    if (signError || !data) {
      return json({ error: signError?.message ?? 'could not sign upload' }, 500);
    }

    return json({
      party_id: partyId,
      path: data.path,
      token: data.token,
      expires_in: UPLOAD_URL_TTL_SECONDS,
    });
  }

  // ----------------------------------------------------------------
  // POST /party-cover/cleanup  { party_id }
  //
  // After a replacement is confirmed: delete the objects nothing points at
  // any more. WHICH objects is party_cover_stale_objects' answer, asked with
  // the caller's JWT (host-only); this route only executes that list, through
  // the Storage API so the bytes go with the row (gotcha 7).
  // ----------------------------------------------------------------
  if (route === 'cleanup') {
    const partyId = payload.party_id;
    if (typeof partyId !== 'string') {
      return json({ error: 'party_id is required' }, 400);
    }

    const { data: stale, error } = await asUser.rpc('party_cover_stale_objects', {
      p_party_id: partyId,
    });
    if (error) {
      return json({ error: error.message }, 403);
    }

    const names = (stale ?? []) as string[];
    if (names.length === 0) {
      return json({ removed: 0 });
    }

    const { error: removeError } = await asService.storage
      .from('party-covers')
      .remove(names);
    if (removeError) {
      return json({ error: removeError.message }, 500);
    }

    return json({ removed: names.length });
  }

  return json({ error: 'unknown route' }, 404);
});
