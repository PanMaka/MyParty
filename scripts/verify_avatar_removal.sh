#!/usr/bin/env bash
# Phase 44: removing an avatar, end to end, as a real user over HTTP, down to
# the storage container's DISK.
#
#   1. upload an avatar the way the app does (direct PUT into the owner's
#      folder, then PATCH avatar_path) and find its bytes on disk;
#   2. "Remove photo": PATCH avatar_path = null, then the owner's own DELETE
#      through the Storage API -- the row AND the bytes are gone;
#   3. the safety net: an avatar whose delete never happened (the app died, the
#      request failed) is collected by sweep_avatars, while the current avatar
#      is spared;
#   4. the grant: a direct PATCH of username or a consent is refused over
#      PostgREST, and the consent setter is the way in.
#
# pgTAP covers the SQL half (37-39); it cannot reach this one -- the bytes live
# in Storage, not Postgres (gotcha #7), and pg_net only dispatches after COMMIT.
#
# Needs the stack up and nothing else. Acts as host@myparty.local, and puts
# their avatar_path and push consent back as they were on exit.

set -euo pipefail

DB_CONTAINER="supabase_db_MyParty"
STORAGE_CONTAINER="supabase_storage_MyParty"
API_URL="${API_URL:-http://127.0.0.1:54321}"

# The fixed local demo key `supabase status` prints on every machine. Not a
# secret.
ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
PASSWORD="password123"
HOST_ID="11111111-1111-1111-1111-111111111111"

WORKDIR="$(mktemp -d)"
UPLOADED=()

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
sql() { docker exec "$DB_CONTAINER" psql -U postgres -d postgres -tAc "$1" | tr -d '\r'; }
jget() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" <<<"$1" | head -1; }

ORIGINAL_AVATAR=$(sql "select coalesce(avatar_path, '') from public.profiles where id = '$HOST_ID'")
ORIGINAL_PUSH=$(sql "select push_consent from public.profiles where id = '$HOST_ID'")

cleanup() {
  for name in "${UPLOADED[@]}"; do
    curl -s -o /dev/null -X DELETE "$API_URL/storage/v1/object/avatars" \
      -H "apikey: $ANON_KEY" -H "Authorization: Bearer ${HOST_JWT:-}" \
      -H "Content-Type: application/json" -d "{\"prefixes\":[\"$name\"]}" || true
  done
  if [ -n "$ORIGINAL_AVATAR" ]; then
    sql "update public.profiles set avatar_path = '$ORIGINAL_AVATAR' where id = '$HOST_ID'" >/dev/null || true
  else
    sql "update public.profiles set avatar_path = null where id = '$HOST_ID'" >/dev/null || true
  fi
  sql "update public.profiles set push_consent = '${ORIGINAL_PUSH:-f}'::boolean where id = '$HOST_ID';
       delete from public.user_consents where user_id = '$HOST_ID' and not exists (
         select 1 from public.profiles where id = '$HOST_ID' and (push_consent or location_consent));" >/dev/null || true
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

# upload NAME -> the app's direct PUT into the owner's folder; prints the code
upload() {
  curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/storage/v1/object/avatars/$1" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $HOST_JWT" \
    -H "Content-Type: image/jpeg" --data-binary "@$WORKDIR/avatar.jpg"
}

# patch JSON -> PATCH the host's own profiles row; prints the code
patch() {
  curl -s -o /dev/null -w '%{http_code}' -X PATCH "$API_URL/rest/v1/profiles?id=eq.$HOST_ID" \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $HOST_JWT" \
    -H "Content-Type: application/json" -d "$1"
}

on_disk() {
  docker exec "$STORAGE_CONTAINER" sh -c "find /mnt -path '*$1*' -type f 2>/dev/null" | tr -d '\r' | head -1
}

disk_has() {
  docker exec "$STORAGE_CONTAINER" sh -c "test -f '$1' && echo yes || echo no" | tr -d '\r'
}

rows() { sql "select count(*) from storage.objects where bucket_id = 'avatars' and name = '$1'"; }

# Any bytes will do: the avatars bucket restricts no MIME type, and nothing
# here renders the image.
head -c 2048 /dev/urandom >"$WORKDIR/avatar.jpg"

HOST_JWT=$(signin host@myparty.local)

# ============================================================
step "1. an avatar, uploaded the way the app does"
# ============================================================
FIRST="$HOST_ID/verify-$(date +%s)-first.jpg"
code=$(upload "$FIRST"); [ "$code" = 200 ] || fail "upload: $code"
UPLOADED+=("$FIRST")
code=$(patch "{\"avatar_path\":\"$FIRST\"}"); [ "$code" = 204 ] || fail "PATCH avatar_path: $code"
FIRST_DISK=$(on_disk "$FIRST")
[ -n "$FIRST_DISK" ] || fail "could not find the avatar on the storage container's disk"
pass "uploaded, referenced, and on disk at $FIRST_DISK"

# ============================================================
step "2. Remove photo: the column, then the owner's own Storage API delete"
# ============================================================
code=$(patch '{"avatar_path":null}'); [ "$code" = 204 ] || fail "PATCH avatar_path = null: $code"
code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$API_URL/storage/v1/object/avatars" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $HOST_JWT" \
  -H "Content-Type: application/json" -d "{\"prefixes\":[\"$FIRST\"]}")
[ "$code" = 200 ] || fail "owner DELETE: $code"
[ "$(sql "select avatar_path is null from public.profiles where id = '$HOST_ID'")" = t ] || fail "avatar_path is not null"
[ "$(rows "$FIRST")" = 0 ] || fail "the object row is still in storage.objects"
[ "$(disk_has "$FIRST_DISK")" = no ] || fail "THE REMOVED AVATAR IS STILL ON DISK at $FIRST_DISK"
pass "avatar_path is null, and the object is gone from storage.objects AND the disk"

# ============================================================
step "3. the hourly sweep collects a removal whose delete never happened"
# ============================================================
CURRENT="$HOST_ID/verify-$(date +%s)-current.jpg"
ORPHAN="$HOST_ID/verify-$(date +%s)-orphan.jpg"
for name in "$CURRENT" "$ORPHAN"; do
  code=$(upload "$name"); [ "$code" = 200 ] || fail "upload $name: $code"
  UPLOADED+=("$name")
done
code=$(patch "{\"avatar_path\":\"$CURRENT\"}"); [ "$code" = 204 ] || fail "PATCH avatar_path: $code"
ORPHAN_DISK=$(on_disk "$ORPHAN")
[ -n "$ORPHAN_DISK" ] || fail "could not find the orphan on disk"
# Both past the 10-minute in-flight margin, so only the reference decides.
sql "update storage.objects set created_at = now() - interval '1 hour'
     where bucket_id = 'avatars' and name in ('$CURRENT', '$ORPHAN')" >/dev/null

# What the cron job runs. pg_net dispatches after this statement commits.
swept=$(sql "select public.sweep_avatars()")
[ "$swept" -ge 1 ] || fail "the sweep found nothing to delete"
for _ in $(seq 1 20); do
  [ "$(rows "$ORPHAN")" = 0 ] && break
  sleep 1
done
[ "$(rows "$ORPHAN")" = 0 ] || fail "the sweep did not remove the orphan from storage.objects"
[ "$(disk_has "$ORPHAN_DISK")" = no ] || fail "THE ORPHAN IS STILL ON DISK at $ORPHAN_DISK"
[ "$(rows "$CURRENT")" = 1 ] || fail "the sweep deleted the CURRENT avatar"
pass "sweep_avatars removes the orphan from storage.objects and the disk, and spares the current avatar"

# ============================================================
step "4. the grant, over PostgREST"
# ============================================================
code=$(patch '{"username":"renamed_by_patch"}')
[ "$code" = 401 ] || [ "$code" = 403 ] || fail "a direct PATCH of username answered $code"
code=$(patch '{"push_consent":true}')
[ "$code" = 401 ] || [ "$code" = 403 ] || fail "a direct PATCH of push_consent answered $code"
[ "$(sql "select username from public.profiles where id = '$HOST_ID'")" = host ] || fail "the username changed"
pass "a direct PATCH of username or a consent is refused ($code)"

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/rest/v1/rpc/set_push_consent" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $HOST_JWT" \
  -H "Content-Type: application/json" -d '{"p_granted":true}')
[ "$code" = 204 ] || [ "$code" = 200 ] || fail "set_push_consent: $code"
[ "$(sql "select push_consent from public.profiles where id = '$HOST_ID'")" = t ] || fail "push_consent did not change"
pass "set_push_consent is the way in"

printf '\n\033[32mAll avatar removal checks passed.\033[0m\n'
