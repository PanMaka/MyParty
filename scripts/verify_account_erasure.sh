#!/usr/bin/env bash
# Phase 9 end-to-end proof: soft delete -> 30 days -> THE ACCOUNT IS GONE,
# THE BYTES ARE GONE, AND THE CONVERSATION IS NOT.
#
# supabase/tests/database/12_account_lifecycle.test.sql covers the SQL half --
# 49 assertions over the FK graph, the grace period and the tombstone. It
# structurally cannot cover the two most dangerous steps in the whole phase:
#
#   1. Storage objects. gotcha #7 -- the bytes live in the storage container,
#      not in Postgres, and only the Storage API removes both. pgTAP can prove
#      a row was deleted and nothing at all about a file.
#   2. The auth.users delete, which is a GoTrue admin call over HTTP.
#
# and it cannot cover the story-media path at all, because that goes out over
# pg_net, which only dispatches after COMMIT while every pgTAP file ends in a
# rollback.
#
# So this script is the only thing standing between "the erasure logic is
# correct" and "the erasure actually erased anything". It asserts the file is
# gone from the storage container's DISK, not merely absent from
# storage.objects -- same argument as verify_story_lifecycle.sh, and the same
# silent failure it exists to rule out.
#
# It also asserts the opposite direction, which is just as easy to break and
# much harder to notice: the erased user's MESSAGE is still in the thread, and
# still attributed. An erasure that took the conversation with it would pass
# every "is it gone" check in this file.
#
# DESTRUCTIVE. It permanently erases seed persona friend_not_invited (3333).
# Run `supabase db reset` afterwards to get them back.
#
# Usage:
#   supabase start
#   supabase db reset
#   bash scripts/verify_account_erasure.sh
#
# It starts `supabase functions serve` itself and stops it on the way out.

set -euo pipefail

DB_CONTAINER="supabase_db_MyParty"
STORAGE_CONTAINER="supabase_storage_MyParty"
API_URL="${API_URL:-http://127.0.0.1:54321}"

# Overridable because the CLI is not on PATH on every machine.
SUPABASE_BIN="${SUPABASE_BIN:-supabase}"

# The fixed local demo keys, the same ones `supabase status` prints on every
# machine and seed.sql puts in vault. Not secrets.
ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
SERVICE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU"

# seed.sql personas. 3333 is the one this script destroys -- chosen because no
# other verify script depends on them and they host nothing.
DOOMED_ID="33333333-3333-3333-3333-333333333333"
DOOMED_EMAIL="friend_not_invited@myparty.local"
HOST_ID="11111111-1111-1111-1111-111111111111"
PASSWORD="password123"
PUBLIC_PARTY="aaaaaaaa-0000-0000-0000-000000000002"

WORKDIR="$(mktemp -d)"
SERVE_PID=""

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

cleanup() {
  [ -n "$SERVE_PID" ] && kill "$SERVE_PID" 2>/dev/null || true
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

sql() { docker exec "$DB_CONTAINER" psql -U postgres -d postgres -tAc "$1" | tr -d '\r'; }

jget() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" <<<"$1" | head -1; }

# Does a file with this basename exist anywhere under the storage container's
# data directory? Basename rather than full path because Storage's on-disk
# layout is its own business -- what matters is that no file by that name
# survives anywhere.
on_disk() {
  docker exec "$STORAGE_CONTAINER" sh -c "find /mnt -name '$1' 2>/dev/null" | tr -d '\r' | head -1
}

upload() {
  local bucket="$1" path="$2"
  printf 'not really a jpeg' > "$WORKDIR/blob.bin"
  curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/storage/v1/object/$bucket/$path" \
    -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: image/jpeg" \
    --data-binary "@$WORKDIR/blob.bin"
}

# ============================================================
step "0. preflight"
# ============================================================
docker inspect "$DB_CONTAINER" >/dev/null 2>&1 || fail "the local stack is not running (supabase start)"

[ "$(sql "select count(*) from information_schema.columns where table_schema='public' and table_name='profiles' and column_name='erased_at'")" = "1" ] \
  || fail "Phase 9 migrations are not applied (supabase db reset)"

[ "$(sql "select count(*) from auth.users where id = '$DOOMED_ID'")" = "1" ] \
  || fail "seed persona $DOOMED_EMAIL is missing -- run supabase db reset"
pass "stack up, phase 9 applied, persona present"

"$SUPABASE_BIN" functions serve >"$WORKDIR/serve.log" 2>&1 &
SERVE_PID=$!
for _ in $(seq 1 60); do
  grep -q "Serving functions on" "$WORKDIR/serve.log" 2>/dev/null && break
  sleep 1
done
grep -q "Serving functions on" "$WORKDIR/serve.log" || fail "supabase functions serve did not start"
pass "functions served"

# ============================================================
step "1. give the doomed account something to lose"
# ============================================================
AVATAR_FILE="face.jpg"
POST_FILE="post_$(date +%s).jpg"
STORY_ID=$(sql "select gen_random_uuid()")
POST_ID=$(sql "select gen_random_uuid()")
MESSAGE_ID=$(sql "select gen_random_uuid()")

[ "$(upload avatars "$DOOMED_ID/$AVATAR_FILE")" = "200" ] || fail "avatar upload failed"
[ "$(upload post-media "$PUBLIC_PARTY/$POST_FILE")" = "200" ] || fail "post media upload failed"
[ "$(upload story-media "$PUBLIC_PARTY/$STORY_ID.jpg")" = "200" ] || fail "story media upload failed"

sql "insert into public.party_posts (id, party_id, author_id, body, media_path)
     values ('$POST_ID', '$PUBLIC_PARTY', '$DOOMED_ID', 'my post', '$PUBLIC_PARTY/$POST_FILE')" >/dev/null

sql "insert into public.stories (id, party_id, author_id, media_path, content_type, media_uploaded_at)
     values ('$STORY_ID', '$PUBLIC_PARTY', '$DOOMED_ID', '$PUBLIC_PARTY/$STORY_ID.jpg', 'image/jpeg', now())" >/dev/null

sql "insert into public.messages (id, party_id, author_id, body)
     values ('$MESSAGE_ID', '$PUBLIC_PARTY', '$DOOMED_ID', 'see you all there')" >/dev/null

[ -n "$(on_disk "$AVATAR_FILE")" ] || fail "control: the avatar should be on disk before we start"
[ -n "$(on_disk "$POST_FILE")" ]   || fail "control: the post media should be on disk before we start"
[ -n "$(on_disk "$STORY_ID.jpg")" ] || fail "control: the story media should be on disk before we start"
pass "avatar, post media, story media on disk; post, story and message in the database"

# ============================================================
step "2. the user asks to be deleted (the real client path)"
# ============================================================
AUTH_BODY=$(curl -s -X POST "$API_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$DOOMED_EMAIL\",\"password\":\"$PASSWORD\"}")
JWT=$(jget "$AUTH_BODY" access_token)
[ -n "$JWT" ] || fail "could not sign in as $DOOMED_EMAIL: $AUTH_BODY"

curl -s -o /dev/null -X POST "$API_URL/rest/v1/rpc/request_account_deletion" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" -d '{}'

[ "$(sql "select count(*) from public.profiles where id='$DOOMED_ID' and deleted_at is not null")" = "1" ] \
  || fail "deleted_at was not set"
[ "$(sql "select count(*) from public.user_devices where user_id='$DOOMED_ID'")" = "0" ] \
  || fail "user_devices should be purged at T+0, not at T+30d"
pass "soft deleted through PostgREST; devices purged immediately"

# The account is NOT erasable yet. This is the assertion that proves the grace
# period is a real gate rather than a comment.
[ "$(sql "select count(*) from public.claim_accounts_for_erasure(10)")" = "0" ] \
  || fail "an account inside its grace period must not be claimable"
pass "inside the grace period, nothing is claimable"

# ============================================================
step "3. 30 days pass"
# ============================================================
# As postgres, because the trigger from 20260819082840 §7 deliberately stops
# every client role from doing exactly this.
sql "update public.profiles set deleted_at = now() - interval '31 days' where id='$DOOMED_ID'" >/dev/null
pass "deleted_at backdated past the grace period"

# ============================================================
step "4. the eraser runs"
# ============================================================
ERASE_BODY=$(curl -s -X POST "$API_URL/functions/v1/account-eraser" \
  -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" \
  -d '{"reason":"verify_script"}')

grep -q '"erased":1' <<<"$ERASE_BODY" || fail "the eraser did not report one erasure: $ERASE_BODY"
pass "account-eraser reported one erasure"

# A run with nothing to do must be a clean no-op, not a failure. The cron fires
# daily against an empty queue on almost every day of the system's life.
IDLE_BODY=$(curl -s -X POST "$API_URL/functions/v1/account-eraser" \
  -H "Authorization: Bearer $SERVICE_KEY" -H "Content-Type: application/json" \
  -d '{"reason":"verify_script_idle"}')
grep -q '"erased":0' <<<"$IDLE_BODY" || fail "a second run should erase nothing: $IDLE_BODY"
pass "a second run is a clean no-op"

# ============================================================
step "5. the account is gone"
# ============================================================
[ "$(sql "select count(*) from auth.users where id='$DOOMED_ID'")" = "0" ] \
  || fail "the auth.users row survived -- the person can still sign in"
pass "auth.users row deleted (the actual erasure)"

[ "$(sql "select count(*) from public.profiles where id='$DOOMED_ID' and erased_at is not null")" = "1" ] \
  || fail "the tombstone profile is missing"
pass "profiles row survives as a tombstone"

TOMBSTONE_NAME=$(sql "select username from public.profiles where id='$DOOMED_ID'")
case "$TOMBSTONE_NAME" in
  deleted_*) pass "username scrubbed to an opaque handle ($TOMBSTONE_NAME)" ;;
  *) fail "username was not scrubbed: $TOMBSTONE_NAME" ;;
esac

[ "$(sql "select count(*) from public.account_erasures where user_id='$DOOMED_ID' and completed_at is not null")" = "1" ] \
  || fail "the queue row was not completed"
pass "erasure queue row completed"

# ============================================================
step "6. the bytes are gone -- from DISK, not just from storage.objects"
# ============================================================
# Assertion pairs, because they fail independently and only the second one
# rules out the silent failure: deleting the storage.objects row alone would
# pass every metadata check while leaving the file on disk forever.
[ "$(sql "select count(*) from storage.objects where bucket_id='avatars' and name like '$DOOMED_ID/%'")" = "0" ] \
  || fail "the avatar row is still in storage.objects"
[ -z "$(on_disk "$AVATAR_FILE")" ] || fail "THE AVATAR IS STILL ON DISK -- a face, on a public bucket, after erasure"
pass "avatar gone from storage.objects AND from disk"

[ -z "$(on_disk "$POST_FILE")" ] || fail "the post media is still on disk"
pass "post media gone from disk"

[ "$(sql "select count(*) from public.party_posts where id='$POST_ID' and media_path is null")" = "1" ] \
  || fail "party_posts.media_path should be nulled, with the post itself retained"
pass "the post survives with its media stripped"

# ============================================================
step "7. story media goes through the ONE purge path"
# ============================================================
[ "$(sql "select count(*) from public.stories where id='$STORY_ID'")" = "0" ] \
  || fail "the story row should be deleted"
[ "$(sql "select count(*) from public.story_media_purges where media_path='$PUBLIC_PARTY/$STORY_ID.jpg'")" = "1" ] \
  || fail "the story media was not enrolled into story_media_purges"
pass "story deleted, its media enrolled in the purge ledger (story_id set null)"

# This is the seam pgTAP cannot reach at all: purge_story_media queues an
# http_delete that pg_net only sends after COMMIT, and reconcile reads the
# response back on a later tick.
sql "select public.purge_story_media()" >/dev/null
for _ in $(seq 1 30); do
  sleep 1
  sql "select public.reconcile_story_media_purges()" >/dev/null
  [ "$(sql "select count(*) from public.story_media_purges where media_path='$PUBLIC_PARTY/$STORY_ID.jpg' and completed_at is not null")" = "1" ] && break
done

[ "$(sql "select count(*) from public.story_media_purges where media_path='$PUBLIC_PARTY/$STORY_ID.jpg' and completed_at is not null")" = "1" ] \
  || fail "the purge never completed -- pg_net or the Storage API did not answer"
[ -z "$(on_disk "$STORY_ID.jpg")" ] || fail "THE STORY MEDIA IS STILL ON DISK"
pass "story media confirmed gone from disk by the existing purge path"

# ============================================================
step "8. and the conversation is NOT gone"
# ============================================================
# The direction that is just as easy to break and much harder to notice. An
# erasure that took the thread with it would have passed every assertion above.
[ "$(sql "select count(*) from public.messages where id='$MESSAGE_ID'")" = "1" ] \
  || fail "THE MESSAGE VANISHED -- this is the failure the whole phase exists to prevent"
pass "the erased user's message is still in the thread"

[ "$(sql "select author_id from public.messages where id='$MESSAGE_ID'")" = "$DOOMED_ID" ] \
  || fail "the message lost its author -- it should point at the tombstone"
pass "and still attributed, to the tombstone the client renders as Διαγραμμένος χρήστης"

# The join every content RPC depends on. If the tombstone were invisible or
# absent, this returns zero rows and the message disappears from the app while
# still existing in the table -- the exact failure the audit rejected the
# nullable-author_id design over.
[ "$(sql "select count(*) from public.messages m join public.profiles p on p.id = m.author_id where m.id='$MESSAGE_ID'")" = "1" ] \
  || fail "the message no longer joins to a profile -- get_messages would drop it"
pass "the inner join every content RPC relies on still resolves"

# ============================================================
step "9. the cron's own path is configured"
# ============================================================
# Everything above invoked the eraser over HTTP directly. This checks the
# mechanism that actually fires in production: pg_net, reading vault.
REQ_ID=$(sql "select public.post_to_account_eraser('verify_script')" 2>&1) || \
  fail "post_to_account_eraser failed -- vault is missing account_eraser_url / account_eraser_service_key: $REQ_ID"
[ -n "$REQ_ID" ] || fail "post_to_account_eraser returned no request id"
pass "post_to_account_eraser dispatched over pg_net (request $REQ_ID)"

printf '\n\033[32mAll assertions passed.\033[0m The account is erased, the bytes are gone,\n'
printf 'and the conversation survived. Run `supabase db reset` to restore the persona.\n\n'
