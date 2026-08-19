// account-eraser -- the process that finishes what request_account_deletion
// started, and is trusted with no decisions whatsoever.
//
// Same split as notification-worker and story-media: this file holds the
// service key, so it must be incapable of inventing policy. It has three RPCs
// -- claim / complete / fail -- and never an UPDATE of its own. It does not
// know what the grace period is, which tables are deleted versus tombstoned,
// or how many times to retry. All of that is 20260819083207, and every rule
// there is re-asserted inside complete_account_erasure, so calling this
// endpoint directly with a service key still cannot erase somebody whose 30
// days have not elapsed.
//
// It exists at all because two things in erasure are not reachable from SQL:
//
//   1. Storage objects. gotcha #7 -- `delete from storage.objects` deletes the
//      METADATA and orphans the bytes. Only the Storage API removes both.
//   2. The auth.users row, which needs a GoTrue admin call.
//
// ORDER IS LOAD-BEARING: bytes, then rows, then the auth user. Deleting the
// rows first and then failing on storage would leave objects that nothing can
// ever enumerate again, because the rows naming them are what the enumeration
// reads. Failing in the order used here just means the next run retries.
//
// WHAT NEVER APPEARS IN THIS FILE'S OUTPUT: a username, an email, a body, a
// coordinate, or a whole user id. Logs are shipped somewhere central by
// definition, and a log line saying which person was erased on which day
// outlives the data the erasure was supposed to remove. User ids are logged as
// their first eight characters -- enough to correlate two lines about one run,
// not enough to be a durable handle to a person.

import { createClient, type SupabaseClient } from 'jsr:@supabase/supabase-js@2';

// How many accounts one invocation takes. Small on purpose: each one is a
// handful of storage round trips plus an admin call, and there is no deadline
// pressure -- the subject asked 30 days ago. The cron runs daily and a backlog
// drains over a few days without anyone noticing.
const BATCH_SIZE = 20;

// One invocation's wall-clock budget, well inside the platform's limit. Past
// this the run stops claiming; anything unclaimed is picked up tomorrow, and
// anything claimed-but-unfinished is reclaimed by the one-hour stale-claim
// rule in claim_accounts_for_erasure.
const DEADLINE_MS = 50_000;

type LogFields = Record<string, unknown>;

const log = (level: 'info' | 'warn' | 'error', event: string, fields: LogFields = {}) => {
  console.log(JSON.stringify({ ts: new Date().toISOString(), level, event, ...fields }));
};

// Eight characters is enough to tie two lines of one run together and useless
// to anyone who finds the log six months later.
const userTag = (id: string) => id.slice(0, 8);

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });

type Claim = {
  user_id: string;
  avatar_prefix: string;
  post_paths: string[];
};

// ----------------------------------------------------------------
// Storage.
//
// remove() is the Storage API, not a delete against storage.objects, and that
// distinction is the entire reason this function exists rather than the whole
// erasure being a single SQL transaction.
// ----------------------------------------------------------------

// The avatars bucket is {user_id}/..., so this is the one prefix that means
// "this person's files". Everything else in the schema is keyed by party.
const deleteAvatars = async (
  db: SupabaseClient,
  prefix: string,
  runId: string,
): Promise<number> => {
  const { data: listed, error: listError } = await db.storage.from('avatars').list(prefix);

  if (listError) throw new Error(`avatars list failed: ${listError.message}`);
  if (!listed || listed.length === 0) return 0;

  const paths = listed.map((f) => `${prefix}/${f.name}`);
  const { error: removeError } = await db.storage.from('avatars').remove(paths);

  if (removeError) throw new Error(`avatars remove failed: ${removeError.message}`);

  log('info', 'avatars.deleted', { run_id: runId, count: paths.length });
  return paths.length;
};

// post-media is keyed by party, so there is no prefix to sweep and the paths
// come from the claim. A path that is already gone is not an error: Storage
// answers a missing key without complaint, and a retry after a partial run
// must not be able to wedge the queue.
const deletePostMedia = async (
  db: SupabaseClient,
  paths: string[],
  runId: string,
): Promise<number> => {
  if (paths.length === 0) return 0;

  const { error } = await db.storage.from('post-media').remove(paths);
  if (error) throw new Error(`post-media remove failed: ${error.message}`);

  log('info', 'post_media.deleted', { run_id: runId, count: paths.length });
  return paths.length;
};

// ----------------------------------------------------------------
// One account, end to end.
// ----------------------------------------------------------------
const eraseOne = async (db: SupabaseClient, claim: Claim, runId: string): Promise<void> => {
  const tag = userTag(claim.user_id);

  // 1. Bytes first. Story media is NOT here -- it goes through
  //    story_media_purges, whose ledger is the only thing in the system that
  //    can prove an object left the bucket. Two senders aimed at one path
  //    would race, and only one of them would be recording the outcome.
  await deleteAvatars(db, claim.avatar_prefix, runId);
  await deletePostMedia(db, claim.post_paths, runId);

  // 2. Rows, and the tombstone. One transaction, and it re-checks the grace
  //    period itself -- this function's claim cannot produce an ineligible
  //    account, but the rule is worth more than the call site.
  const { error: completeError } = await db.rpc('complete_account_erasure', {
    p_user_id: claim.user_id,
  });
  if (completeError) throw new Error(`complete_account_erasure: ${completeError.message}`);

  // 3. The auth user, last. Until this call the person can still sign in --
  //    which is the correct failure mode for a run that dies at step 2, since
  //    an account whose rows are gone but whose login works is visible and
  //    fixable, while the reverse is a login that authenticates into nothing.
  const { error: authError } = await db.auth.admin.deleteUser(claim.user_id);

  // Already gone is success. GoTrue answers 404 for an id it does not have,
  // and a retry of a run that died between the delete and the log must not
  // report a failure forever.
  if (authError && authError.status !== 404) {
    throw new Error(`auth delete failed: ${authError.message}`);
  }

  log('info', 'account.erased', { run_id: runId, user: tag });
};

// ----------------------------------------------------------------
Deno.serve(async (req) => {
  const runId = crypto.randomUUID().slice(0, 8);
  const startedAt = Date.now();

  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  const url = Deno.env.get('SUPABASE_URL')!;
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

  // verify_jwt = true means the gateway rejected anything unsigned -- but "a
  // valid token" includes every signed-in user's, and this endpoint
  // permanently destroys accounts. The header must be the service key itself,
  // which only the database (via pg_net reading vault) and an operator hold.
  const authorization = req.headers.get('Authorization') ?? '';
  if (authorization !== `Bearer ${serviceKey}`) {
    log('warn', 'request.rejected', { run_id: runId });
    return json({ error: 'forbidden' }, 403);
  }

  const reason = await req.json().then((b) => b?.reason ?? 'unknown').catch(() => 'unknown');

  const db = createClient(url, serviceKey, { auth: { persistSession: false } });

  let erased = 0;
  let failed = 0;

  log('info', 'run.started', { run_id: runId, reason });

  try {
    while (Date.now() - startedAt < DEADLINE_MS) {
      const { data, error } = await db.rpc('claim_accounts_for_erasure', {
        p_limit: BATCH_SIZE,
      });

      if (error) {
        log('error', 'claim.failed', { run_id: runId, error: error.message });
        return json({ error: 'claim failed' }, 500);
      }

      const claims = (data ?? []) as Claim[];
      if (claims.length === 0) break;

      // Sequential, not concurrent. Erasure is rare, unhurried, and each unit
      // is destructive -- there is nothing to gain from parallelism here and a
      // clean one-at-a-time failure boundary to lose.
      for (const claim of claims) {
        try {
          await eraseOne(db, claim, runId);
          erased++;
        } catch (e) {
          failed++;
          const message = e instanceof Error ? e.message : String(e);
          log('error', 'account.failed', {
            run_id: runId,
            user: userTag(claim.user_id),
            error: message,
          });
          // Hands the row back for retry and records why. After five attempts
          // the claim stops returning it and an operator sees last_error --
          // the correct response to "we cannot erase this person" is a human,
          // not an unbounded retry.
          await db.rpc('fail_account_erasure', {
            p_user_id: claim.user_id,
            p_error: message,
          });
        }
      }

      if (claims.length < BATCH_SIZE) break;
    }
  } catch (e) {
    log('error', 'run.crashed', {
      run_id: runId,
      error: e instanceof Error ? e.message : String(e),
    });
    return json({ error: 'run crashed', erased, failed }, 500);
  }

  log('info', 'run.finished', {
    run_id: runId,
    reason,
    erased,
    failed,
    ms: Date.now() - startedAt,
  });

  return json({ erased, failed });
});
