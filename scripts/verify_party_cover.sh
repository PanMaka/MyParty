#!/usr/bin/env bash
# Phase 25: a party cover, end to end, as real users over HTTP.
#
#   create_party_with_invites -> party-cover/upload-url -> signed PUT
#     -> confirm_party_cover -> a guest reads it through a signed URL
#
# plus the refusals that make it safe: a non-host gets no upload URL, a
# confirmed party gets no second one, and the bucket turns away anything that
# is not a JPEG. pgTAP covers the SQL half (28_party_cover_upload.test.sql) but
# cannot reach this one -- the bytes live in Storage, not Postgres (gotcha #7).
#
# Needs the stack up. Starts `supabase functions serve` itself and stops it on
# exit. Creates two PRIVATE throwaway parties (private, so the publish trigger
# fans out no notifications) and deletes them and their objects at the end.

set -euo pipefail

DB_CONTAINER="supabase_db_MyParty"
API_URL="${API_URL:-http://127.0.0.1:54321}"
SUPABASE_BIN="${SUPABASE_BIN:-supabase}"

# The fixed local demo keys `supabase status` prints on every machine. Not
# secrets.
ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
SERVICE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU"
PASSWORD="password123"
INVITEE_ID="22222222-2222-2222-2222-222222222222"

WORKDIR="$(mktemp -d)"
SERVE_PID=""
PARTY_IDS=()

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
sql() { docker exec "$DB_CONTAINER" psql -U postgres -d postgres -tAc "$1" | tr -d '\r'; }
jget() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" <<<"$1" | head -1; }

cleanup() {
  for id in "${PARTY_IDS[@]}"; do
    curl -s -o /dev/null -X DELETE "$API_URL/storage/v1/object/party-covers" \
      -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" \
      -d "{\"prefixes\":[\"$id/cover\"]}" || true
    sql "delete from public.invitations where party_id = '$id';
         delete from public.parties where id = '$id';" >/dev/null || true
  done
  [ -n "$SERVE_PID" ] && kill "$SERVE_PID" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

signin() {
  local body token
  body=$(curl -s -X POST "$API_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$1\",\"password\":\"$PASSWORD\"}")
  token=$(jget "$body" access_token)
  [ -n "$token" ] || fail "could not sign in as $1: $body"
  echo "$token"
}

# rpc JWT NAME JSON -> prints body, sets $STATUS
rpc() {
  local out
  out=$(curl -s -w '\n%{http_code}' -X POST "$API_URL/rest/v1/rpc/$2" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $1" \
    -H "Content-Type: application/json" -d "$3")
  STATUS=$(tail -n1 <<<"$out"); BODY=$(sed '$d' <<<"$out")
}

# upload_url JWT PARTY_ID -> sets $STATUS and $BODY
upload_url() {
  local out
  out=$(curl -s -w '\n%{http_code}' -X POST "$API_URL/functions/v1/party-cover/upload-url" \
    -H "Authorization: Bearer $1" -H "Content-Type: application/json" \
    -d "{\"party_id\":\"$2\"}")
  STATUS=$(tail -n1 <<<"$out"); BODY=$(sed '$d' <<<"$out")
}

# put_signed PATH TOKEN FILE CONTENT_TYPE -> prints http status
put_signed() {
  curl -s -o "$WORKDIR/put.out" -w '%{http_code}' -X PUT \
    "$API_URL/storage/v1/object/upload/sign/party-covers/$1?token=$2" \
    -H "Content-Type: $4" --data-binary "@$3"
}

new_party() {
  rpc "$HOST_JWT" create_party_with_invites "{
    \"p_party\": {\"title\": \"cover check $1\", \"description\": \"verify_party_cover.sh\",
                  \"lat\": 37.97, \"lon\": 23.73, \"is_private\": true,
                  \"starts_at\": \"$(date -u -d '+2 days' +%Y-%m-%dT%H:%M:%SZ)\"},
    \"p_invitee_ids\": [\"$INVITEE_ID\"]}"
  [ "$STATUS" = 200 ] || fail "create_party_with_invites: $STATUS $BODY"
  tr -d '"' <<<"$BODY"
}

# A real 1x1 JPEG, so nothing downstream gets to complain about the bytes.
base64 -d >"$WORKDIR/cover.jpg" <<'B64'
/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////wgALCAABAAEBAREA/8QAFBABAAAAAAAAAAAAAAAAAAAAAP/aAAgBAQABPxA=
B64
printf '<html>not a cover</html>' >"$WORKDIR/page.html"
# And a real 1x1 PNG: the picker keeps images with an alpha channel as PNG.
base64 -d >"$WORKDIR/cover.png" <<'B64'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==
B64

# ============================================================
step "0. preflight"
# ============================================================
docker inspect "$DB_CONTAINER" >/dev/null 2>&1 || fail "the local stack is not running (supabase start)"
[ "$(sql "select count(*) from pg_proc where proname = 'confirm_party_cover'")" = 1 ] \
  || fail "20261005224544_party_cover_upload is not applied"
"$SUPABASE_BIN" functions serve >"$WORKDIR/serve.log" 2>&1 &
SERVE_PID=$!
for _ in $(seq 1 60); do
  grep -q "Serving functions on" "$WORKDIR/serve.log" 2>/dev/null && break
  sleep 1
done
grep -q "Serving functions on" "$WORKDIR/serve.log" || fail "supabase functions serve did not start"
HOST_JWT=$(signin host@myparty.local)
INVITEE_JWT=$(signin invitee@myparty.local)
pass "stack up, migration applied, functions served, host and invitee signed in"

# ============================================================
step "1. the host creates a party and gets an upload URL"
# ============================================================
PARTY=$(new_party one); PARTY_IDS+=("$PARTY")
pass "party $PARTY created"

upload_url "$INVITEE_JWT" "$PARTY"
[ "$STATUS" = 403 ] || fail "an invitee was handed an upload URL: $STATUS $BODY"
pass "the invitee -- who can see the party -- is refused (403)"

upload_url "$HOST_JWT" "$PARTY"
[ "$STATUS" = 200 ] || fail "upload-url for the host: $STATUS $BODY"
PATH_KEY=$(jget "$BODY" path); TOKEN=$(jget "$BODY" token)
[ "$PATH_KEY" = "$PARTY/cover" ] || fail "signed the wrong path: $PATH_KEY"
pass "the host gets a URL for $PATH_KEY"

# ============================================================
step "2. confirm refuses before the bytes exist, accepts after"
# ============================================================
rpc "$HOST_JWT" confirm_party_cover "{\"p_party_id\":\"$PARTY\"}"
[ "$STATUS" != 200 ] || fail "confirm succeeded with nothing uploaded"
pass "confirm before upload is refused ($STATUS)"

code=$(put_signed "$PATH_KEY" "$TOKEN" "$WORKDIR/cover.jpg" image/jpeg)
[ "$code" = 200 ] || fail "signed PUT: $code $(cat "$WORKDIR/put.out")"
pass "the JPEG is uploaded through the signed URL"

rpc "$HOST_JWT" confirm_party_cover "{\"p_party_id\":\"$PARTY\"}"
[ "$STATUS" = 200 ] || fail "confirm after upload: $STATUS $BODY"
[ "$(sql "select cover_path from public.parties where id = '$PARTY'")" = "$PARTY/cover" ] \
  || fail "cover_path was not set"
pass "confirm sets parties.cover_path"

upload_url "$HOST_JWT" "$PARTY"
[ "$STATUS" = 403 ] || fail "a confirmed party was handed a second upload URL: $STATUS"
pass "a second upload URL is refused -- the cover cannot be swapped under guests"

# ============================================================
step "3. a guest reads the cover the way the app does"
# ============================================================
out=$(curl -s -X POST "$API_URL/storage/v1/object/sign/party-covers/$PATH_KEY" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $INVITEE_JWT" \
  -H "Content-Type: application/json" -d '{"expiresIn":60}')
SIGNED=$(jget "$out" signedURL)
[ -n "$SIGNED" ] || fail "the invitee could not sign a read URL: $out"
curl -s -o "$WORKDIR/read.jpg" "$API_URL/storage/v1$SIGNED"
cmp -s "$WORKDIR/cover.jpg" "$WORKDIR/read.jpg" || fail "the bytes read back differ"
pass "the invitee signs a read URL under RLS and gets the same bytes back"

# ============================================================
step "4. the bucket refuses what is not an image"
# ============================================================
OTHER=$(new_party two); PARTY_IDS+=("$OTHER")
upload_url "$HOST_JWT" "$OTHER"
[ "$STATUS" = 200 ] || fail "upload-url for the second party: $STATUS $BODY"
OTHER_PATH=$(jget "$BODY" path); OTHER_TOKEN=$(jget "$BODY" token)
code=$(put_signed "$OTHER_PATH" "$OTHER_TOKEN" "$WORKDIR/page.html" text/html)
[ "$code" != 200 ] || fail "the bucket accepted an HTML page as a cover"
pass "an HTML upload is refused ($code: $(jget "$(cat "$WORKDIR/put.out")" message))"

# Same signed URL: the refused PUT wrote nothing, so it is still unused.
code=$(put_signed "$OTHER_PATH" "$OTHER_TOKEN" "$WORKDIR/cover.png" image/png)
[ "$code" = 200 ] || fail "the bucket refused a PNG: $code $(cat "$WORKDIR/put.out")"
rpc "$HOST_JWT" confirm_party_cover "{\"p_party_id\":\"$OTHER\"}"
[ "$STATUS" = 200 ] || fail "confirm after a PNG upload: $STATUS $BODY"
pass "a PNG -- what the picker hands over for a screenshot -- is accepted and confirmed"

printf '\n\033[32mAll party cover checks passed.\033[0m\n'
