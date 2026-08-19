// account-export -- GDPR Art. 20, handed back as a file.
//
// The opposite of account-eraser in the one way that matters: this function
// never holds the service key. It forwards the CALLER's Authorization header
// into PostgREST, so the identity doing the reading is the person asking, and
// export_account_data resolves auth.uid() from that token. There is no user id
// parameter anywhere in this path -- not in the URL, not in the body, not in
// the RPC -- so there is nothing to tamper with and no IDOR to get wrong.
//
// Same shape as story-media's view path (functions/story-media/index.ts).
//
// Why an edge function at all, when the client could call the RPC directly:
// the deliverable is a FILE. This sets Content-Disposition so a browser or a
// webview saves it with a sensible name instead of rendering 200KB of JSON
// into a text view, and it is the seam where a future async export -- write to
// storage, email a signed link -- lands without the client changing.

import { createClient } from 'jsr:@supabase/supabase-js@2';

type LogFields = Record<string, unknown>;

const log = (level: 'info' | 'warn' | 'error', event: string, fields: LogFields = {}) => {
  console.log(JSON.stringify({ ts: new Date().toISOString(), level, event, ...fields }));
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });

Deno.serve(async (req) => {
  const runId = crypto.randomUUID().slice(0, 8);

  if (req.method !== 'POST' && req.method !== 'GET') {
    return json({ error: 'method not allowed' }, 405);
  }

  const url = Deno.env.get('SUPABASE_URL')!;
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;

  const authorization = req.headers.get('Authorization') ?? '';
  if (!authorization.startsWith('Bearer ')) {
    return json({ error: 'unauthorized' }, 401);
  }

  // The anon key plus the caller's token. NOT the service key: with it, a bug
  // in this file becomes "any signed-in user can export any other user", and
  // there is nothing this function needs that the caller's own rights cannot
  // reach -- export_account_data is definer precisely so it can see the
  // caller's own messages in parties they have left.
  const db = createClient(url, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  });

  const { data, error } = await db.rpc('export_account_data');

  if (error) {
    // 42501 is the function's own "not authenticated" -- a syntactically valid
    // but expired or anonymous token. Anything else is a real fault.
    const status = error.code === '42501' ? 401 : 500;
    log(status === 401 ? 'warn' : 'error', 'export.failed', {
      run_id: runId,
      code: error.code,
      // The message can name a column but never a value.
      error: error.message,
    });
    return json({ error: status === 401 ? 'unauthorized' : 'export failed' }, status);
  }

  const body = JSON.stringify(data, null, 2);

  // Size is logged, contents never. "How big was the export" is the only
  // question an operator has that this file can answer without becoming a copy
  // of the data it just handed out.
  log('info', 'export.completed', { run_id: runId, bytes: body.length });

  const stamp = new Date().toISOString().slice(0, 10);

  return new Response(body, {
    status: 200,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Content-Disposition': `attachment; filename="myparty-export-${stamp}.json"`,
      // This body is one person's entire account. It must not sit in a shared
      // cache, a CDN, or a webview's disk cache.
      'Cache-Control': 'no-store, private',
    },
  });
});
