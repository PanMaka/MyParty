#!/usr/bin/env bash
# Phase 45: the private columns of profiles, over HTTP, the way the app and an
# attacker would actually reach them.
#
# pgTAP (40_profile_private_columns) proves the grants. What it cannot see is
# the statement PostgREST builds: a PATCH is an UPDATE inside a CTE, and with
# `Prefer: return=representation` it RETURNs the row, which is a READ of every
# returned column. So the claim "settings writes still work with SELECT
# narrowed" is only true if PostgREST's return=minimal statement reads nothing
# but `id`. Measured here, not assumed:
#
#   1. the owner PATCHes their settings with return=minimal (DeviceRepository.
#      updatePrefs, ProfileRepository.updatePrivacy) and reads them back
#      through get_my_settings;
#   2. return=representation is refused, which is why the client must never
#      chain .select() onto those writes;
#   3. another user is refused every private column, select=*, and a filter on
#      a private column, while the public select and the follower-list embed
#      still answer;
#   4. signed out, profiles and get_my_settings are refused outright.
#
# Needs the stack up and nothing else. Acts as host@myparty.local and
# stranger@myparty.local, and puts the host's settings back on exit.

set -euo pipefail

DB_CONTAINER="supabase_db_MyParty"
API_URL="${API_URL:-http://127.0.0.1:54321}"

# The fixed local demo key `supabase status` prints on every machine. Not a
# secret.
ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
PASSWORD="password123"
HOST_ID="11111111-1111-1111-1111-111111111111"

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
sql() { docker exec "$DB_CONTAINER" psql -U postgres -d postgres -tAc "$1" | tr -d '\r'; }
jget() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" <<<"$1" | head -1; }

ORIGINAL=$(sql "select notify_daily_cap || ',' || notification_tz || ',' || dm_policy from public.profiles where id = '$HOST_ID'")
IFS=',' read -r ORIG_CAP ORIG_TZ ORIG_DM <<<"$ORIGINAL"

cleanup() {
  sql "update public.profiles
       set notify_daily_cap = ${ORIG_CAP:-3}, notification_tz = '${ORIG_TZ:-Europe/Athens}',
           dm_policy = '${ORIG_DM:-everyone}'
       where id = '$HOST_ID'" >/dev/null || true
  rm -f "${WORK_BODY:-}" "${WORK_CODE:-}"
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

WORK_BODY="$(mktemp)"
WORK_CODE="$(mktemp)"

# req METHOD PATH JWT [BODY] [PREFER] -> prints the response body; `code`
# prints its HTTP status. An empty JWT means signed out (the apikey alone).
req() {
  local auth=()
  [ -n "$3" ] && auth=(-H "Authorization: Bearer $3")
  curl -s -o "$WORK_BODY" -w '%{http_code}' -X "$1" "$API_URL$2" \
    -H "apikey: $ANON_KEY" "${auth[@]}" \
    -H "Content-Type: application/json" -H "Prefer: ${5:-return=minimal}" \
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

HOST_JWT=$(signin host@myparty.local)
STRANGER_JWT=$(signin stranger@myparty.local)


step "1. The owner writes settings with return=minimal and reads them back"
BODY=$(req PATCH "/rest/v1/profiles?id=eq.$HOST_ID" "$HOST_JWT" \
  '{"notify_daily_cap": 4, "notification_tz": "Pacific/Chatham", "dm_policy": "following"}')
[ "$(code)" = "204" ] || fail "settings PATCH returned $(code): $BODY"
pass "PATCH of notify_daily_cap, notification_tz, dm_policy returns 204"

[ "$(sql "select notify_daily_cap || ',' || notification_tz || ',' || dm_policy from public.profiles where id = '$HOST_ID'")" = "4,Pacific/Chatham,following" ] \
  || fail "the PATCH did not land"
pass "and the row holds the new values"

BODY=$(req POST "/rest/v1/rpc/get_my_settings" "$HOST_JWT" '{}' 'return=representation')
[ "$(code)" = "200" ] || fail "get_my_settings returned $(code): $BODY"
grep -q '"notification_tz":"Pacific/Chatham"' <<<"$BODY" && grep -q '"notify_daily_cap":4' <<<"$BODY" \
  || fail "get_my_settings did not return the written values: $BODY"
pass "get_my_settings returns them to the owner"


step "2. RETURNING a private column is a read, and refused"
BODY=$(req PATCH "/rest/v1/profiles?id=eq.$HOST_ID" "$HOST_JWT" '{"notify_daily_cap": 5}' 'return=representation')
refused "PATCH with return=representation (what .update().select() sends)"
[ "$(sql "select notify_daily_cap from public.profiles where id = '$HOST_ID'")" = "4" ] \
  || fail "the refused PATCH still wrote"
pass "and the refused statement wrote nothing"

BODY=$(req GET "/rest/v1/profiles?select=notification_tz&id=eq.$HOST_ID" "$HOST_JWT")
refused "the owner reading their own private column off the table"


step "3. Another user"
for col in notification_tz quiet_hours_start location_consent push_consent \
           map_visibility dm_policy deleted_at onboarding_completed_at created_at; do
  BODY=$(req GET "/rest/v1/profiles?select=$col&id=eq.$HOST_ID" "$STRANGER_JWT")
  refused "stranger reading $col"
done

BODY=$(req GET "/rest/v1/profiles?select=*&id=eq.$HOST_ID" "$STRANGER_JWT")
refused "stranger with select=*"

BODY=$(req GET "/rest/v1/profiles?select=id&notification_tz=eq.Pacific%2FChatham" "$STRANGER_JWT")
refused "stranger filtering on a private column (no WHERE oracle)"

BODY=$(req GET "/rest/v1/profiles?select=id,username,bio,avatar_path,follower_count,following_count&id=eq.$HOST_ID" "$STRANGER_JWT")
[ "$(code)" = "200" ] && grep -q '"username":"host"' <<<"$BODY" \
  || fail "the public select (fetchProfile) failed: $(code) $BODY"
pass "the public select still answers (ProfileRepository.fetchProfile)"

BODY=$(req GET "/rest/v1/follows?select=profiles!follows_follower_id_fkey(id,username,follower_count,following_count)&followee_id=eq.$HOST_ID" "$STRANGER_JWT")
[ "$(code)" = "200" ] && grep -q '"username"' <<<"$BODY" \
  || fail "the follower-list embed failed: $(code) $BODY"
pass "the follower-list embed still answers (SocialRepository.fetchFollowers)"

BODY=$(req POST "/rest/v1/rpc/get_my_settings" "$STRANGER_JWT" '{}' 'return=representation')
[ "$(code)" = "200" ] && ! grep -q 'Pacific/Chatham' <<<"$BODY" \
  || fail "get_my_settings as the stranger: $(code) $BODY"
pass "get_my_settings as the stranger returns the stranger's own row, not the host's"


step "4. Signed out"
BODY=$(req GET "/rest/v1/profiles?select=username&id=eq.$HOST_ID" "")
refused "anon reading even a username"

BODY=$(req POST "/rest/v1/rpc/get_my_settings" "" '{}' 'return=representation')
refused "anon calling get_my_settings"

printf '\n\033[32mAll checks passed.\033[0m\n'
