#!/usr/bin/env bash
# Phase 46: what a signed-out caller, a third party and an invitee can reach,
# over HTTP, the way the app and an attacker would actually reach it.
#
# pgTAP (41_anon_access) proves the grants and policies. What it cannot see is
# the two servers in front of them: PostgREST turning a missing grant into a
# refusal, and the Storage API, whose list, sign and public routes each take
# their own path to storage.objects (the public route skips RLS entirely).
# Measured here:
#
#   1. signed out, the five formerly anon-readable tables, profiles and a
#      sample of the formerly PUBLIC functions are refused;
#   2. is_blocked tells a third party nothing about a real block, and still
#      tells a member of the pair;
#   3. an invitee is refused a private party's raw counters, reads NULL from
#      the public columns and from get_party_chats, while a public party's
#      public column still carries the number;
#   4. signed out, the avatars bucket cannot be listed and party-covers and
#      post-media cannot be signed, while a signed-in viewer can do both and a
#      known avatar URL still loads signed out (Option 1).
#
# Needs the stack up and nothing else. Acts as host@, invitee@ and
# stranger@myparty.local; plants one block and three probe objects, and
# removes all of them on exit.

set -euo pipefail

DB_CONTAINER="supabase_db_MyParty"
API_URL="${API_URL:-http://127.0.0.1:54321}"

# The fixed local demo keys `supabase status` prints on every machine. Not
# secrets.
ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
SERVICE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU"
PASSWORD="password123"
HOST_ID="11111111-1111-1111-1111-111111111111"
STRANGER_ID="44444444-4444-4444-4444-444444444444"
BLOCKED_ID="55555555-5555-5555-5555-555555555555"
PRIVATE_PARTY="aaaaaaaa-0000-0000-0000-000000000001"
PUBLIC_PARTY="aaaaaaaa-0000-0000-0000-000000000002"

AVATAR_PROBE="$HOST_ID/zz-anon-probe.png"
COVER_PROBE="$PUBLIC_PARTY/zz-anon-probe.png"
POST_PROBE="$PUBLIC_PARTY/zz-anon-probe.png"

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
sql() { docker exec "$DB_CONTAINER" psql -U postgres -d postgres -tAc "$1" | tr -d '\r'; }
jget() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" <<<"$1" | head -1; }

WORK_BODY="$(mktemp)"
WORK_CODE="$(mktemp)"
PNG="$(mktemp)"
# A 1x1 transparent PNG.
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==' | base64 -d >"$PNG"

storage_delete() {  # bucket path, with the service key
  curl -s -o /dev/null -X DELETE "$API_URL/storage/v1/object/$1" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: application/json" -d "{\"prefixes\":[\"$2\"]}" || true
}

cleanup() {
  sql "delete from public.blocks where blocker_id = '$STRANGER_ID' and blocked_id = '$BLOCKED_ID'" >/dev/null || true
  storage_delete avatars "$AVATAR_PROBE"
  storage_delete party-covers "$COVER_PROBE"
  storage_delete post-media "$POST_PROBE"
  rm -f "$WORK_BODY" "$WORK_CODE" "$PNG"
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

# req METHOD PATH JWT [BODY] -> prints the response body; `code` prints its
# HTTP status. An empty JWT means signed out (the apikey alone).
req() {
  local auth=()
  [ -n "$3" ] && auth=(-H "Authorization: Bearer $3")
  curl -s -o "$WORK_BODY" -w '%{http_code}' -X "$1" "$API_URL$2" \
    -H "apikey: $ANON_KEY" "${auth[@]}" \
    -H "Content-Type: application/json" \
    ${4:+-d "$4"} >"$WORK_CODE"
  cat "$WORK_BODY"
}
code() { cat "$WORK_CODE"; }

refused() {  # refused LABEL -- the last request must be a 401/403 carrying 42501
  local c; c=$(code)
  if { [ "$c" = "401" ] || [ "$c" = "403" ]; } && grep -q '42501' <<<"$BODY"; then
    pass "$1 ($c, 42501)"
  else
    fail "$1 -- expected 401/403 with 42501, got $c: $BODY"
  fi
}

upload() {  # bucket path -- as the service key, which bypasses storage RLS
  local c
  c=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/storage/v1/object/$1/$2" \
    -H "apikey: $SERVICE_KEY" -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: image/png" -H "x-upsert: true" --data-binary "@$PNG")
  [ "$c" = "200" ] || fail "probe upload to $1/$2 returned $c"
}

HOST_JWT=$(signin host@myparty.local)
INVITEE_JWT=$(signin invitee@myparty.local)
STRANGER_JWT=$(signin stranger@myparty.local)


step "1. Signed out, the database answers nothing"
for t in parties follows party_posts post_comments post_likes profiles; do
  BODY=$(req GET "/rest/v1/$t?select=*&limit=1" "")
  refused "GET /$t"
done

rpc_refused() {  # name json-args
  BODY=$(req POST "/rest/v1/rpc/$1" "" "$2")
  refused "rpc/$1"
}
rpc_refused check_username_available '{"p_username":"host"}'
rpc_refused is_blocked "{\"p_a\":\"$STRANGER_ID\",\"p_b\":\"$BLOCKED_ID\"}"
rpc_refused can_access_party "{\"p_party_id\":\"$PUBLIC_PARTY\"}"
rpc_refused get_story_rails '{}'
rpc_refused search_normalize '{"p_input":"x"}'
rpc_refused party_topic "{\"p_party_id\":\"$PUBLIC_PARTY\"}"
rpc_refused get_parties_list '{}'
rpc_refused get_party "{\"p_party_id\":\"$PUBLIC_PARTY\"}"

[ "$(sql "select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace
          and p.proowner = 'postgres'::regrole and has_function_privilege('anon', p.oid, 'execute')")" = "0" ] \
  || fail "anon can still execute a function we own"
pass "and anon can execute none of the functions we own (catalog)"


step "2. is_blocked is no oracle"
sql "insert into public.blocks (blocker_id, blocked_id) values ('$STRANGER_ID', '$BLOCKED_ID')
     on conflict do nothing" >/dev/null

BODY=$(req POST "/rest/v1/rpc/is_blocked" "$HOST_JWT" "{\"p_a\":\"$STRANGER_ID\",\"p_b\":\"$BLOCKED_ID\"}")
[ "$(code)" = "200" ] && [ "$BODY" = "false" ] || fail "a third party got $(code): $BODY"
pass "a third party asking about a real block gets false"

BODY=$(req POST "/rest/v1/rpc/blocked_between" "$HOST_JWT" "{\"p_a\":\"$STRANGER_ID\",\"p_b\":\"$BLOCKED_ID\"}")
refused "and cannot call blocked_between instead"

BODY=$(req POST "/rest/v1/rpc/is_blocked" "$STRANGER_JWT" "{\"p_a\":\"$STRANGER_ID\",\"p_b\":\"$BLOCKED_ID\"}")
[ "$(code)" = "200" ] && [ "$BODY" = "true" ] || fail "the blocker got $(code): $BODY"
pass "the blocker still gets true"


step "3. A private party's counters reach no client"
BODY=$(req GET "/rest/v1/parties?select=going_count&id=eq.$PRIVATE_PARTY" "$INVITEE_JWT")
refused "an invitee selecting going_count"
BODY=$(req GET "/rest/v1/parties?select=interested_count&id=eq.$PRIVATE_PARTY" "$INVITEE_JWT")
refused "an invitee selecting interested_count"
BODY=$(req GET "/rest/v1/parties?select=*&id=eq.$PRIVATE_PARTY" "$INVITEE_JWT")
refused "an invitee selecting *"
BODY=$(req GET "/rest/v1/parties?select=id&going_count=gt.0" "$INVITEE_JWT")
refused "a filter on going_count"

BODY=$(req GET "/rest/v1/parties?select=public_going_count,public_interested_count&id=eq.$PRIVATE_PARTY" "$INVITEE_JWT")
[ "$(code)" = "200" ] && grep -q '"public_going_count":null' <<<"$BODY" \
  && grep -q '"public_interested_count":null' <<<"$BODY" || fail "public columns on the private party: $(code) $BODY"
pass "the public columns read NULL on the private party"

BODY=$(req POST "/rest/v1/rpc/get_party_chats" "$INVITEE_JWT" '{}')
[ "$(code)" = "200" ] || fail "get_party_chats returned $(code): $BODY"
grep -q "\"party_id\":\"$PRIVATE_PARTY\"" <<<"$BODY" || fail "the private party is not in the invitee's chat list: $BODY"
if grep -o "{[^}]*\"party_id\":\"$PRIVATE_PARTY\"[^}]*}" <<<"$BODY" | grep -q '"going_count":null'; then
  pass "get_party_chats returns going_count NULL for it"
else
  fail "get_party_chats still carries a count: $BODY"
fi

# A public party that has guests, so the comparison is not 0 = 0.
COUNTED=$(sql "select id || ',' || going_count from public.parties
               where not is_private and going_count > 0 and host_id <> '$BLOCKED_ID'
               order by going_count desc limit 1")
[ -n "$COUNTED" ] || fail "fixture: no public party in seed has a going rsvp"
IFS=',' read -r COUNTED_ID RAW <<<"$COUNTED"
BODY=$(req GET "/rest/v1/parties?select=public_going_count&id=eq.$COUNTED_ID" "$STRANGER_JWT")
grep -q "\"public_going_count\":$RAW[,}]" <<<"$BODY" || fail "the public party's count: $BODY (raw $RAW)"
pass "a public party's public_going_count is its real count ($RAW)"


step "4. Storage reads need a signed-in caller"
upload avatars "$AVATAR_PROBE"
upload party-covers "$COVER_PROBE"
upload post-media "$POST_PROBE"

LIST="{\"prefix\":\"$HOST_ID\",\"limit\":100}"
BODY=$(req POST "/storage/v1/object/list/avatars" "" "$LIST")
grep -q 'zz-anon-probe' <<<"$BODY" && fail "signed out, the avatars listing shows the probe: $BODY"
pass "signed out, listing avatars shows nothing ($(code))"
BODY=$(req POST "/storage/v1/object/list/avatars" "$STRANGER_JWT" "$LIST")
grep -q 'zz-anon-probe' <<<"$BODY" || fail "signed in, the listing should show the probe: $(code) $BODY"
pass "signed in, it does"

c=$(curl -s -o /dev/null -w '%{http_code}' "$API_URL/storage/v1/object/public/avatars/$AVATAR_PROBE")
[ "$c" = "200" ] || fail "the public avatar URL returned $c"
pass "the public avatar URL still loads signed out (200)"

for b in party-covers post-media; do
  probe="$COVER_PROBE"; [ "$b" = post-media ] && probe="$POST_PROBE"
  BODY=$(req POST "/storage/v1/object/sign/$b/$probe" "" '{"expiresIn":60}')
  { [ "$(code)" != "200" ] && ! grep -q 'signedURL' <<<"$BODY"; } || fail "signed out, $b signed a URL: $BODY"
  pass "signed out, $b will not sign a URL ($(code))"
  BODY=$(req POST "/storage/v1/object/sign/$b/$probe" "$STRANGER_JWT" '{"expiresIn":60}')
  grep -q 'signedURL' <<<"$BODY" || fail "signed in, $b should sign the public party's object: $(code) $BODY"
  pass "signed in, it does for a public party"
done

printf '\n\033[32mAll anon access checks passed.\033[0m\n'
