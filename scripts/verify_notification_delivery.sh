#!/usr/bin/env bash
# Phase 7c end-to-end proof of the target:
#
#   "a new party within 500m produces a notification in under 60s,
#    no duplicates, quiet hours respected"
#
# pgTAP (supabase/tests/database/10_notification_delivery.test.sql) covers the
# queue's state machine, and structurally cannot cover this: pg_net only
# dispatches a queued request after the transaction COMMITS, and every pgTAP
# file ends in a rollback. So the suite can prove a wake-up was queued and
# nothing more. Everything downstream of that COMMIT -- the HTTP call to the
# worker, the OAuth exchange, the send, the classification of Google's answer --
# only exists outside a transaction, which is what this script is for.
#
# What it asserts, in order of how much it would hurt to get wrong:
#
#   1. LATENCY. Wall-clock seconds from `insert into parties` to the job
#      reaching 'sent'. This is the phase target, and it is measured rather
#      than reasoned about.
#   2. NO DUPLICATES. A second publish, a device that moves, and the hourly
#      sweep all race for the same claim by design. One notification.
#   3. QUIET HOURS DEFER, THEY DO NOT DROP. A job enqueued inside the window is
#      scheduled for the window's end and is NOT delivered now -- and the
#      dedupe row is still claimed, so nothing re-enqueues it in the meantime.
#   4. DEAD TOKENS ARE CLEANED UP, FLAKY ONES ARE NOT. The two look identical
#      at the call site and differ only in Google's status code; confusing them
#      silently unsubscribes people every time a payload bug ships.
#
# Google is stood in for by scripts/fcm_stub.py. The worker still builds a real
# RS256 assertion with a real 2048-bit key, still exchanges it, still sends real
# HTTP and still reads a real status code -- only the answer is local.
#
# Usage:
#   supabase start && supabase db reset
#   bash scripts/verify_notification_delivery.sh
#
# It starts the stub and `supabase functions serve` itself, and stops both on
# the way out.

set -euo pipefail

DB_CONTAINER="supabase_db_MyParty"
API_URL="http://127.0.0.1:54321"
STUB_PORT="${FCM_STUB_PORT:-8099}"

# Overridable because the CLI is not on PATH on every machine.
SUPABASE_BIN="${SUPABASE_BIN:-supabase}"

# The fixed local demo service_role key, the same one `supabase status` prints
# on every machine and the one seed.sql puts in vault. Not a secret.
SERVICE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU"

HOST_ID="11111111-1111-1111-1111-111111111111"
NEAR_USER="44444444-4444-4444-4444-444444444444"   # stranger
QUIET_USER="22222222-2222-2222-2222-222222222222"  # invitee
DEAD_USER="33333333-3333-3333-3333-333333333333"   # friend_not_invited
FLAKY_USER="55555555-5555-5555-5555-555555555555"  # blocked_user (no block here)

# Syntagma, and a party ~300m north of it -- comfortably inside the 500m
# default radius and comfortably outside the ~100m storage grid.
LAT=37.9755
LNG=23.7348
PARTY_LAT=37.9783
PARTY_LNG=23.7348

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

sql() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -tAc "$1" | tr -d '\r'; }
sqlq() { docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -q -v ON_ERROR_STOP=1; }

WORKDIR="$(mktemp -d)"
STUB_PID=""
SERVE_PID=""

cleanup() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null || true
  [ -n "$SERVE_PID" ] && kill "$SERVE_PID" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# ============================================================
step "0. a stub Google, and a worker pointed at it"
# ============================================================
command -v openssl >/dev/null || fail "openssl is required to build the stub service account"
command -v python  >/dev/null || PYTHON=python3 || fail "python is required to run the stub"
PYTHON="${PYTHON:-python}"

# A real key, because the worker really signs. host.docker.internal is how the
# edge runtime container reaches a server on the host.
openssl genpkey -algorithm RSA -out "$WORKDIR/sa.key" -pkeyopt rsa_keygen_bits:2048 2>/dev/null
"$PYTHON" - "$WORKDIR" "$STUB_PORT" <<'PY'
import json, sys
work, port = sys.argv[1], sys.argv[2]
sa = {"type": "service_account", "project_id": "myparty-local",
      "private_key_id": "stub", "client_email": "worker@myparty-local.iam.gserviceaccount.com",
      "private_key": open(f"{work}/sa.key").read()}
open(f"{work}/worker.env", "w").write("\n".join([
    "FCM_SERVICE_ACCOUNT=" + json.dumps(sa),
    f"GOOGLE_TOKEN_URL=http://host.docker.internal:{port}/token",
    f"FCM_BASE_URL=http://host.docker.internal:{port}",
]) + "\n")
PY

"$PYTHON" "$(dirname "$0")/fcm_stub.py" "$STUB_PORT" >"$WORKDIR/stub.log" 2>&1 &
STUB_PID=$!

"$SUPABASE_BIN" functions serve --env-file "$WORKDIR/worker.env" >"$WORKDIR/serve.log" 2>&1 &
SERVE_PID=$!

for _ in $(seq 1 40); do
  curl -sf "http://127.0.0.1:$STUB_PORT/_health" >/dev/null 2>&1 && break
  sleep 1
done
curl -sf "http://127.0.0.1:$STUB_PORT/_health" >/dev/null || fail "the fcm stub did not start"

for _ in $(seq 1 60); do
  grep -q "Serving functions on" "$WORKDIR/serve.log" 2>/dev/null && break
  sleep 1
done
grep -q "Serving functions on" "$WORKDIR/serve.log" || fail "supabase functions serve did not start"
pass "stub on :$STUB_PORT, worker served"

# ============================================================
step "1. an empty map and four consenting users"
# ============================================================
# seed.sql's 22 parties cluster around Syntagma and would fan out to every
# device below, turning every count in this script into arithmetic about the
# fixtures. Cancelled rather than deleted: `status = 'published'` is the
# engine's own filter, so this exercises the real predicate.
sqlq <<SQL
update public.parties set status = 'cancelled';
delete from public.notification_jobs;
delete from public.sent_notifications;
delete from public.user_devices;

update public.profiles
set location_consent = true, push_consent = true, notify_nearby = true,
    notification_tz = 'UTC', quiet_hours_start = null, quiet_hours_end = null,
    notify_radius_meters = 500, notify_daily_cap = 5;

-- One device each, all at Syntagma. The token prefixes drive the stub's
-- branches: good-* delivers, dead-* answers 404 UNREGISTERED, flaky-* answers
-- 503 twice before it recovers.
insert into public.user_devices (user_id, push_token, platform, last_location) values
  ('$NEAR_USER',  'good-near',   'android', st_point($LNG, $LAT)::geography),
  ('$QUIET_USER', 'good-quiet',  'ios',     st_point($LNG, $LAT)::geography),
  ('$DEAD_USER',  'dead-gone',   'ios',     st_point($LNG, $LAT)::geography),
  ('$FLAKY_USER', 'flaky-slow',  'android', st_point($LNG, $LAT)::geography);
SQL
pass "four devices parked at Syntagma, nothing else published"

# Quiet hours for one user only, covering the whole day so the window is
# unambiguous whatever time this script runs. 00:00-23:59 in UTC.
sql "update public.profiles set quiet_hours_start = '00:00', quiet_hours_end = '23:59' where id = '$QUIET_USER';" >/dev/null
pass "one user is inside a quiet window, the other three are not"

# ============================================================
step "2. publish a party 300m away, and time it"
# ============================================================
STARTED=$(date +%s)
# Wrapped in a data-modifying CTE so the statement is a SELECT: a bare
# `insert ... returning` also prints psql's "INSERT 0 1" tag, which would be
# concatenated onto the uuid.
PARTY_ID=$(sql "with created as (
                  insert into public.parties (host_id, title, description, location, starts_at, status, is_private)
                  values ('$HOST_ID', 'Proximity Target', 'x',
                          st_point($PARTY_LNG, $PARTY_LAT)::geography,
                          now() + interval '4 hours', 'published', false)
                  returning id
                )
                select id from created;")
[ -n "$PARTY_ID" ] || fail "the party was not created"

# Nothing is polled into existence here: the insert trigger queued a pg_net
# wake-up at COMMIT and the worker is already running. The loop is only waiting
# for it to finish.
DELIVERED=""
for _ in $(seq 1 60); do
  DELIVERED=$(sql "select count(*) from public.notification_jobs
                   where party_id = '$PARTY_ID' and user_id = '$NEAR_USER' and status = 'sent';")
  [ "$DELIVERED" = "1" ] && break
  sleep 1
done
ELAPSED=$(( $(date +%s) - STARTED ))

[ "$DELIVERED" = "1" ] || fail "the nearby user's notification was not delivered (status: $(sql "select status from public.notification_jobs where party_id='$PARTY_ID' and user_id='$NEAR_USER';"))"
[ "$ELAPSED" -lt 60 ] || fail "delivered, but in ${ELAPSED}s -- the target is under 60"
pass "party -> delivered push in ${ELAPSED}s (target: <60)"

# And it really went out over HTTP, with no coordinate in it.
SENT_BODY=$(curl -s "http://127.0.0.1:$STUB_PORT/_sent")
grep -q '"good-near"' <<<"$SENT_BODY" || fail "the stub never saw a send for good-near"
grep -q 'Proximity Target' <<<"$SENT_BODY" || fail "the payload did not carry the party title"
grep -qi '"lat"\|latitude\|23\.73' <<<"$SENT_BODY" && fail "the payload contains a coordinate" || true
pass "the push carried the party title and no location"

# ============================================================
step "3. no duplicates, however many things try"
# ============================================================
# All three enqueue paths at once: the party is re-saved (publish trigger), the
# device moves to a new cell (movement trigger), and the safety-net sweep runs.
# Every one of them is supposed to find the dedupe row already claimed.
sql "update public.parties set title = 'Proximity Target v2' where id = '$PARTY_ID';" >/dev/null
sql "update public.user_devices set last_location = st_point($LNG, 37.9760)::geography where push_token = 'good-near';" >/dev/null
sql "select public.sweep_missed_nearby_notifications();" >/dev/null
sleep 6

JOBS=$(sql "select count(*) from public.notification_jobs where party_id = '$PARTY_ID' and user_id = '$NEAR_USER';")
CLAIMS=$(sql "select count(*) from public.sent_notifications where party_id = '$PARTY_ID' and user_id = '$NEAR_USER';")
SENDS=$(curl -s "http://127.0.0.1:$STUB_PORT/_sent" | grep -o '"good-near"' | wc -l | tr -d ' ')

[ "$JOBS" = "1" ]   || fail "expected exactly one job for the nearby user, got $JOBS"
[ "$CLAIMS" = "1" ] || fail "expected exactly one dedupe claim, got $CLAIMS"
[ "$SENDS" = "1" ]  || fail "the stub was sent $SENDS pushes for one party"
pass "re-publish + device move + sweep all converge on one notification"

# ============================================================
step "4. quiet hours defer, they do not drop"
# ============================================================
QUIET_STATUS=$(sql "select status from public.notification_jobs where party_id = '$PARTY_ID' and user_id = '$QUIET_USER';")
QUIET_FUTURE=$(sql "select scheduled_for > now() + interval '1 minute' from public.notification_jobs where party_id = '$PARTY_ID' and user_id = '$QUIET_USER';")
QUIET_CLAIM=$(sql "select count(*) from public.sent_notifications where party_id = '$PARTY_ID' and user_id = '$QUIET_USER';")

[ "$QUIET_STATUS" = "pending" ] || fail "the quiet-hours job should still be pending, is '$QUIET_STATUS'"
[ "$QUIET_FUTURE" = "t" ]       || fail "the quiet-hours job was not deferred into the future"
# The claim is spent even though nothing was delivered. That asymmetry with the
# daily cap is deliberate: the decision was made, only delivery moved, and a
# second claim would be a duplicate.
[ "$QUIET_CLAIM" = "1" ]        || fail "the quiet-hours job did not claim its dedupe row"
grep -q '"good-quiet"' <<<"$(curl -s "http://127.0.0.1:$STUB_PORT/_sent")" && fail "a push went out during quiet hours" || true
pass "deferred to the end of the window, claim spent, nothing delivered now"

# ============================================================
step "5. dead tokens are deleted, flaky ones are not"
# ============================================================
DEAD_ROWS=$(sql "select count(*) from public.user_devices where push_token = 'dead-gone';")
FLAKY_ROWS=$(sql "select count(*) from public.user_devices where push_token = 'flaky-slow';")
FLAKY_STATUS=$(sql "select status from public.notification_jobs where party_id = '$PARTY_ID' and user_id = '$FLAKY_USER';")

[ "$DEAD_ROWS" = "0" ]  || fail "a token FCM reported as UNREGISTERED is still in user_devices"
# The distinction the whole classify() function exists for. A 503 is Google
# having a bad minute; deleting on it would unsubscribe people during an outage.
[ "$FLAKY_ROWS" = "1" ] || fail "a token that answered 503 was deleted -- that is an outage unsubscribing users"
[ "$FLAKY_STATUS" = "sent" ] || fail "the flaky token never recovered, status '$FLAKY_STATUS'"
pass "404 UNREGISTERED removed the row; 503 was retried and recovered"

printf '\n\033[32mAll checks passed.\033[0m Delivered in %ss, one notification, quiet hours deferred.\n\n' "$ELAPSED"
