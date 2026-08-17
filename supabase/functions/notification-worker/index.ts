// notification-worker -- the process that drains notification_jobs and is
// trusted with no decisions whatsoever.
//
// Everything this file knows how to do is transport: mint a Google OAuth
// token, POST to FCM, read back what went wrong, and translate that into one of
// four outcomes. It does not know who may be notified, whether a job is too old
// to send, how many times to retry before giving up, or what "already sent"
// means. Those live in 20260817083542, and this function reaches them through
// exactly three RPCs -- claim / complete / fail -- and never through an UPDATE
// of its own.
//
// That is the same split as story-media (functions/story-media/index.ts): the
// process holding the service_role key is the one that must be incapable of
// inventing policy, because it is the one place a mistake cannot be caught by
// RLS. The specific rule worth protecting here is the attempt cap. A retry
// budget kept in worker memory is a budget that resets on every redeploy and
// runs independently in every concurrent invocation -- which is not a budget at
// all, and the thing it fails to bound is spend against a paid API.
//
// WHAT NEVER APPEARS IN THIS FILE'S OUTPUT: a coordinate, and a whole push
// token. The logs are structured and shipped somewhere central by definition,
// and a push token is a durable handle to one person's device. Tokens are
// logged as their last six characters, which is enough to correlate two lines
// about the same device and not enough to address it.

import { createClient, type SupabaseClient } from 'jsr:@supabase/supabase-js@2';

// How many jobs one claim takes. The queue is drained in a loop, so this bounds
// memory and the blast radius of a single failed round trip, not throughput.
const BATCH_SIZE = 100;

// How many jobs are in flight against FCM at once. Deliberately modest: the
// per-job cost is one HTTPS round trip, and the thing that actually limits
// throughput is FCM's own rate limiting, which responds to being pushed harder
// by returning 429s that cost a retry each.
const CONCURRENCY = 10;

// One invocation's wall-clock budget. Past this the worker stops claiming and
// hands back whatever it has not started, rather than being killed mid-batch
// and leaving rows in 'sending' for the five-minute reclaim to notice. The
// cron fires again a minute later, so stopping early is free.
const DEADLINE_MS = 25_000;

// In-invocation retries for a transport error that looks transient. Small on
// purpose -- this is for the 503 that clears in 200ms. Anything more persistent
// belongs on the queue, where the wait costs no compute.
const TRANSPORT_RETRIES = 3;

// Cross-invocation backoff, indexed by the job's attempt count. The row's
// 5-attempt cap (fail_notification_job) is what ends the series; this only
// decides the spacing, so the last entry is a ceiling rather than a terminator.
const RETRY_BACKOFF = ['1 minute', '5 minutes', '15 minutes', '1 hour'];

const FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';

// Both endpoints are overridable, and this is configuration rather than a test
// seam bolted on: scripts/verify_notification_delivery.sh points them at a
// local stub so the delivery path -- RS256 assertion, token exchange, send,
// error classification, token deletion -- can be exercised end to end without a
// Firebase project, and without the alternative, which is asserting that the
// code "would" work. Unset, they are Google's, so production reads exactly as
// if these constants were literals.
const GOOGLE_TOKEN_URL = Deno.env.get('GOOGLE_TOKEN_URL') ?? 'https://oauth2.googleapis.com/token';
const FCM_BASE_URL = Deno.env.get('FCM_BASE_URL') ?? 'https://fcm.googleapis.com';

// ----------------------------------------------------------------
// Structured logging.
//
// One JSON object per line, because these are read by a log aggregator far more
// often than by a person, and a human tailing them can still pipe through jq.
// run_id ties every line of one invocation together, which is the only way to
// tell "the queue is slow" from "one job is being retried in a loop" when the
// insert trigger and the cron are both firing.
// ----------------------------------------------------------------
type LogFields = Record<string, unknown>;

const log = (level: 'debug' | 'info' | 'warn' | 'error', event: string, fields: LogFields = {}) => {
  console.log(JSON.stringify({ ts: new Date().toISOString(), level, event, ...fields }));
};

// A push token identifies a device forever. Six characters is enough to tell
// two devices apart across log lines and useless to anyone who finds the log.
const tokenTag = (token: string) => `…${token.slice(-6)}`;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });

// ----------------------------------------------------------------
// Google OAuth for FCM HTTP v1.
//
// The legacy FCM API took a static server key in a header; v1 takes a
// short-lived OAuth2 access token, which means signing a JWT assertion with the
// service account's private key and exchanging it. WebCrypto does RS256, so
// this needs no dependency -- and one fewer third-party package in the process
// holding the service_role key is worth the thirty lines.
//
// The access token is cached in module scope. Edge runtimes keep an instance
// warm across invocations, so a busy worker mints one token an hour instead of
// one per minute; a cold start simply mints its own.
// ----------------------------------------------------------------
interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

let cachedToken: { value: string; expiresAt: number } | null = null;

// The IN-FLIGHT mint, not just the finished one. Caching only the result leaves
// a hole exactly the width of one token exchange: on a cold isolate all
// CONCURRENCY jobs check the empty cache in the same tick and each mints its
// own, which is a self-inflicted burst of RSA signing and OAuth round trips at
// the least convenient moment. Parking the promise means the first caller mints
// and the rest await that same one.
let mintInFlight: Promise<string> | null = null;

const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

const pemToPkcs8 = (pem: string): Uint8Array => {
  // Service-account JSON stores the key with literal \n escapes when it has
  // been round-tripped through an environment variable, which is exactly how it
  // arrives here. Normalising both forms costs one replace and avoids a failure
  // whose only symptom is "invalid key format" at the first send.
  const body = pem
    .replace(/\\n/g, '\n')
    .replace(/-----[A-Z ]+-----/g, '')
    .replace(/\s+/g, '');
  const raw = atob(body);
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
};

const mintAccessToken = (sa: ServiceAccount): Promise<string> => {
  const now = Math.floor(Date.now() / 1000);
  // Refreshed a minute early, so a token that is valid when checked is still
  // valid when FCM sees it.
  if (cachedToken && cachedToken.expiresAt > now + 60) return Promise.resolve(cachedToken.value);

  // Cleared in both directions: a failed mint must not be awaited forever by
  // the next caller, and a successful one is already in cachedToken.
  mintInFlight ??= doMintAccessToken(sa).finally(() => {
    mintInFlight = null;
  });

  return mintInFlight;
};

const doMintAccessToken = async (sa: ServiceAccount): Promise<string> => {
  const now = Math.floor(Date.now() / 1000);

  const header = b64url(new TextEncoder().encode(JSON.stringify({ alg: 'RS256', typ: 'JWT' })));
  const claims = b64url(
    new TextEncoder().encode(
      JSON.stringify({
        iss: sa.client_email,
        scope: FCM_SCOPE,
        aud: GOOGLE_TOKEN_URL,
        iat: now,
        exp: now + 3600,
      }),
    ),
  );

  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToPkcs8(sa.private_key),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );

  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    key,
    new TextEncoder().encode(`${header}.${claims}`),
  );

  const assertion = `${header}.${claims}.${b64url(new Uint8Array(signature))}`;

  const response = await fetch(GOOGLE_TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    }),
  });

  if (!response.ok) {
    throw new Error(`google oauth ${response.status}: ${await response.text()}`);
  }

  const body = await response.json();
  cachedToken = { value: body.access_token, expiresAt: now + (body.expires_in ?? 3600) };
  return cachedToken.value;
};

// ----------------------------------------------------------------
// Sending, and the classification that is the only judgement this file makes.
//
// Four outcomes, and the distinction that matters most is token_invalid vs
// retryable. Retrying a dead token is a request that will never succeed, made
// once a minute, forever, against a rate-limited API -- and it keeps a row
// alive in the one table that also holds a location.
// ----------------------------------------------------------------
type Outcome = 'delivered' | 'token_invalid' | 'retryable' | 'permanent';

interface SendResult {
  outcome: Outcome;
  detail: string;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const classify = (status: number, body: string): Outcome => {
  // The app was uninstalled, or the token was superseded by a refresh. This is
  // the canonical dead-token answer and the row must go.
  if (status === 404) return 'token_invalid';

  // The token belongs to a different Firebase project. Terminal for this token
  // and, if it happens in bulk, a misconfiguration worth seeing in the logs.
  if (status === 403) return 'token_invalid';

  if (status === 400) {
    // 400 covers both "your payload is malformed" and "that is not a token".
    // Only the second one justifies deleting somebody's device row, so this
    // reads the error detail rather than assuming. Guessing wrong in this
    // direction silently unsubscribes users whenever a payload bug ships.
    const looksLikeToken = /registration.token|not a valid FCM|INVALID_ARGUMENT.*token/i.test(body);
    return looksLikeToken ? 'token_invalid' : 'permanent';
  }

  // Our OAuth token expired mid-batch. Retryable: the next attempt mints a
  // fresh one, because the 401 clears the cache below.
  if (status === 401) return 'retryable';

  if (status === 429 || status >= 500) return 'retryable';

  return 'permanent';
};

const sendToDevice = async (
  sa: ServiceAccount,
  token: string,
  job: Job,
): Promise<SendResult> => {
  const url = `${FCM_BASE_URL}/v1/projects/${sa.project_id}/messages:send`;

  // No coordinate, no radius, no distance. The push says a party is near you;
  // it does not say where you are, and a lock screen is a public surface.
  const message = {
    message: {
      token,
      notification: {
        title: 'Πάρτι κοντά σου',
        body: job.party_title,
      },
      data: {
        kind: job.kind,
        party_id: job.party_id,
        job_id: String(job.job_id),
      },
      android: { priority: 'HIGH', notification: { channel_id: 'nearby_parties' } },
      apns: { payload: { aps: { sound: 'default' } } },
    },
  };

  let lastDetail = '';

  for (let attempt = 1; attempt <= TRANSPORT_RETRIES; attempt++) {
    let accessToken: string;
    try {
      accessToken = await mintAccessToken(sa);
    } catch (err) {
      // No token means no send for anything in this batch, not just this
      // device. Retryable so the queue holds the work rather than burning it.
      return { outcome: 'retryable', detail: `oauth: ${err}` };
    }

    const response = await fetch(url, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(message),
    });

    if (response.ok) return { outcome: 'delivered', detail: `${response.status}` };

    const body = await response.text();
    lastDetail = `${response.status}: ${body.slice(0, 300)}`;
    const outcome = classify(response.status, body);

    if (response.status === 401) cachedToken = null;

    if (outcome !== 'retryable' || attempt === TRANSPORT_RETRIES) {
      return { outcome, detail: lastDetail };
    }

    // Exponential with jitter. The jitter matters more than the curve: without
    // it, a fan-out of several hundred jobs that all hit one 503 retries in
    // lockstep and hits it again together.
    const backoff = 250 * 2 ** (attempt - 1);
    await sleep(backoff + Math.random() * backoff);
  }

  return { outcome: 'retryable', detail: lastDetail };
};

// ----------------------------------------------------------------
// One job.
//
// A job is per USER, and a user may have several devices, so this is a fan-out
// whose parts can disagree: a phone that takes the push and a stale tablet
// token that FCM rejects. The job succeeds if ANY device took it -- the person
// has been told, which is what sent_notifications claimed on their behalf.
// ----------------------------------------------------------------
interface Job {
  job_id: number;
  user_id: string;
  party_id: string;
  kind: string;
  attempts: number;
  party_title: string;
  party_starts_at: string;
  devices: { push_token: string; platform: string }[];
}

interface JobTally {
  delivered: number;
  tokensDeleted: number;
  retryable: number;
  permanent: number;
}

const processJob = async (
  db: SupabaseClient,
  sa: ServiceAccount,
  job: Job,
  runId: string,
  tally: JobTally,
): Promise<void> => {
  const started = Date.now();
  const base = { run_id: runId, job_id: job.job_id, user_id: job.user_id, party_id: job.party_id, attempt: job.attempts };

  // A real state, not an anomaly: push_consent can be granted, and a job
  // enqueued, before the client has ever obtained a token -- or after the last
  // device was deleted for having a dead one. Terminal, because no amount of
  // retrying will conjure a device.
  if (job.devices.length === 0) {
    log('warn', 'job.no_devices', base);
    await db.rpc('fail_notification_job', {
      p_job_id: job.job_id,
      p_error: 'no registered devices for this user',
    });
    tally.permanent++;
    return;
  }

  let delivered = 0;
  let retryable = 0;
  let lastError = '';

  for (const device of job.devices) {
    const result = await sendToDevice(sa, device.push_token, job);
    const deviceFields = { ...base, token: tokenTag(device.push_token), platform: device.platform };

    if (result.outcome === 'delivered') {
      delivered++;
      log('info', 'device.delivered', deviceFields);
      continue;
    }

    lastError = result.detail;

    if (result.outcome === 'token_invalid') {
      // Delete first, count second: the RPC returns how many rows went, so a
      // token already removed by a concurrent job logs 0 rather than claiming
      // a deletion that did not happen.
      const { data: deleted, error } = await db.rpc('delete_device_by_push_token', {
        p_push_token: device.push_token,
      });
      if (error) {
        log('error', 'device.delete_failed', { ...deviceFields, detail: error.message });
      } else {
        tally.tokensDeleted += deleted ?? 0;
        log('info', 'device.token_invalid', { ...deviceFields, deleted, detail: result.detail });
      }
      continue;
    }

    if (result.outcome === 'retryable') retryable++;
    log('warn', `device.${result.outcome}`, { ...deviceFields, detail: result.detail });
  }

  const latency_ms = Date.now() - started;

  if (delivered > 0) {
    await db.rpc('complete_notification_job', { p_job_id: job.job_id });
    tally.delivered++;
    log('info', 'job.sent', { ...base, devices: job.devices.length, delivered, latency_ms });
    return;
  }

  if (retryable > 0) {
    // attempts is already incremented by the claim, so attempt 1 is the first
    // delivery try and indexes the first backoff.
    const retryIn = RETRY_BACKOFF[Math.min(job.attempts - 1, RETRY_BACKOFF.length - 1)];
    const { data: status } = await db.rpc('fail_notification_job', {
      p_job_id: job.job_id,
      p_error: lastError,
      p_retry_in: retryIn,
    });
    tally.retryable++;
    // 'failed' back from a call that asked for a retry means the row's attempt
    // cap just ended the series. Logged at a different level because it is the
    // last thing that will ever happen to this job.
    log(status === 'failed' ? 'error' : 'warn', 'job.retry', {
      ...base, retry_in: retryIn, resulting_status: status, detail: lastError, latency_ms,
    });
    return;
  }

  await db.rpc('fail_notification_job', { p_job_id: job.job_id, p_error: lastError });
  tally.permanent++;
  log('error', 'job.failed', { ...base, detail: lastError, latency_ms });
};

// Bounded parallelism without a dependency: CONCURRENCY workers pulling from
// one shared cursor. Promise.all over the whole batch would open a hundred
// sockets to FCM at once and be answered in 429s.
const runPool = async <T>(items: T[], limit: number, fn: (item: T) => Promise<void>) => {
  let cursor = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (cursor < items.length) {
      const item = items[cursor++];
      await fn(item);
    }
  });
  await Promise.all(workers);
};

// ----------------------------------------------------------------
Deno.serve(async (req) => {
  const runId = crypto.randomUUID().slice(0, 8);
  const startedAt = Date.now();

  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405);

  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

  // verify_jwt = true means the gateway has already rejected anything without a
  // valid token -- but "a valid token" includes every signed-in user's, and
  // this endpoint drains a queue whose rows are location disclosures. So the
  // header must be the service key itself, which only the database (via
  // pg_net, reading vault) and an operator ever hold.
  const authorization = req.headers.get('Authorization') ?? '';
  if (authorization !== `Bearer ${serviceKey}`) {
    log('warn', 'request.rejected', { run_id: runId });
    return json({ error: 'forbidden' }, 403);
  }

  const reason = await req.json().then((b) => b?.reason ?? 'unknown').catch(() => 'unknown');

  // Checked BEFORE claiming anything. A worker that claims a batch and only
  // then discovers it cannot send has burned an attempt on every job in it --
  // five unconfigured minutes would be enough to fail the whole queue
  // permanently. Nothing is claimed, so nothing is lost.
  const rawServiceAccount = Deno.env.get('FCM_SERVICE_ACCOUNT');
  if (!rawServiceAccount) {
    log('error', 'run.unconfigured', { run_id: runId, reason });
    return json({ error: 'FCM_SERVICE_ACCOUNT is not set' }, 503);
  }

  let sa: ServiceAccount;
  try {
    sa = JSON.parse(rawServiceAccount);
    if (!sa.project_id || !sa.client_email || !sa.private_key) throw new Error('missing fields');
  } catch (err) {
    log('error', 'run.bad_service_account', { run_id: runId, detail: String(err) });
    return json({ error: 'FCM_SERVICE_ACCOUNT is not valid service-account JSON' }, 503);
  }

  const db = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey, {
    auth: { persistSession: false },
  });

  const tally: JobTally = { delivered: 0, tokensDeleted: 0, retryable: 0, permanent: 0 };
  let claimed = 0;
  let batches = 0;
  let hitDeadline = false;

  log('info', 'run.start', { run_id: runId, reason });

  // Drains in a loop rather than one batch per wake: a party published in a
  // dense neighbourhood enqueues far more than BATCH_SIZE, and the phase target
  // is 60 seconds for that party, not for the first hundred people near it.
  while (Date.now() - startedAt < DEADLINE_MS) {
    const { data, error } = await db.rpc('claim_notification_jobs', { p_limit: BATCH_SIZE });

    if (error) {
      log('error', 'claim.failed', { run_id: runId, detail: error.message });
      return json({ run_id: runId, error: error.message }, 500);
    }

    const jobs = (data ?? []) as Job[];
    if (jobs.length === 0) break;

    batches++;
    claimed += jobs.length;
    await runPool(jobs, CONCURRENCY, (job) => processJob(db, sa, job, runId, tally));

    // A short batch means the queue is drained; claiming again would only cost
    // a round trip to be told so.
    if (jobs.length < BATCH_SIZE) break;
  }

  if (Date.now() - startedAt >= DEADLINE_MS) hitDeadline = true;

  const summary = {
    run_id: runId,
    reason,
    batches,
    claimed,
    sent: tally.delivered,
    retried: tally.retryable,
    failed: tally.permanent,
    devices_deleted: tally.tokensDeleted,
    hit_deadline: hitDeadline,
    duration_ms: Date.now() - startedAt,
  };

  // The one line worth alerting on. claimed climbing while sent stays flat is a
  // delivery outage; reason = 'cron_tick' with a healthy claimed count on every
  // run means the insert trigger has stopped firing and the cron has been
  // quietly covering for it -- a failure whose only symptom is latency.
  log('info', 'run.finish', summary);

  return json(summary);
});
