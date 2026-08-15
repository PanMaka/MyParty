#!/usr/bin/env bash
# Phase 5 end-to-end proof: upload -> view -> expire -> THE OBJECT IS GONE.
#
# pgTAP (supabase/tests/database/07_stories.test.sql) covers the SQL half, but
# it structurally cannot cover this one: pg_net only dispatches a queued request
# after the transaction COMMITS, and every pgTAP file ends in a rollback. So the
# test suite can prove a delete was queued and nothing more. This script is what
# proves the bytes actually left the bucket.
#
# It asserts BOTH halves of that, because they fail independently:
#
#   1. no row in storage.objects  -- Storage's metadata says the object is gone
#   2. no file under /mnt         -- and the storage container's disk agrees
#
# Assertion 2 is the one that matters. `delete from storage.objects` would pass
# assertion 1 on its own while leaving the file on disk forever, which is
# exactly the silent failure this phase was specified to rule out.
#
# Usage:
#   supabase start
#   supabase db reset
#   supabase functions serve          # in another terminal
#   bash scripts/verify_story_lifecycle.sh

set -euo pipefail

API_URL="http://127.0.0.1:54321"
DB_CONTAINER="supabase_db_MyParty"
STORAGE_CONTAINER="supabase_storage_MyParty"

# Fixed local demo keys -- the same ones `supabase status` prints on every
# machine. Not secrets, and hardcoding them keeps this script runnable without
# parsing CLI output.
ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"

# seed.sql personas / parties.
HOST_EMAIL="host@myparty.local"
HOST_ID="11111111-1111-1111-1111-111111111111"
STRANGER_EMAIL="stranger@myparty.local"
PASSWORD="password123"
PUBLIC_PARTY="aaaaaaaa-0000-0000-0000-000000000002"
PRIVATE_PARTY="aaaaaaaa-0000-0000-0000-000000000001"

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Field extraction without jq (not installed on the Windows dev box). Values
# here are uuids, urls and base64 tokens -- no embedded quotes to worry about.
jget() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" <<<"$1" | head -1; }

sql() { docker exec "$DB_CONTAINER" psql -U postgres -d postgres -tAc "$1" | tr -d '\r'; }

signin() {
  local email="$1"
  local body
  body=$(curl -s -X POST "$API_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$PASSWORD\"}")
  local token
  token=$(jget "$body" access_token)
  [ -n "$token" ] || fail "could not sign in as $email: $body"
  echo "$token"
}

# ============================================================
step "0. sign in (GoTrue, the same path the app takes)"
# ============================================================
HOST_JWT=$(signin "$HOST_EMAIL")
STRANGER_JWT=$(signin "$STRANGER_EMAIL")
pass "signed in as host and stranger"

# ============================================================
step "1. the client cannot touch the bucket directly"
# ============================================================
# The whole upload flow below exists because of this: story-media has zero
# storage policies, so an authenticated user writing to it head-on gets nothing.
direct=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "$API_URL/storage/v1/object/story-media/$PUBLIC_PARTY/hand-rolled.jpg" \
  -H "Authorization: Bearer $HOST_JWT" -H "apikey: $ANON_KEY" \
  -H "Content-Type: image/jpeg" --data-binary "not a real jpeg")
[ "$direct" = "400" ] || [ "$direct" = "403" ] || fail "direct bucket write was not refused (got $direct)"
pass "direct PUT into story-media refused ($direct)"

# ============================================================
step "2. create the row (RLS + trigger-derived path + rate limit)"
# ============================================================
STORY_ID=$(sql "select gen_random_uuid()")
create=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/rest/v1/stories" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $HOST_JWT" \
  -H "Content-Type: application/json" -H "Prefer: return=minimal" \
  -d "{\"id\":\"$STORY_ID\",\"party_id\":\"$PUBLIC_PARTY\",\"author_id\":\"$HOST_ID\",\"content_type\":\"image/jpeg\"}")
[ "$create" = "201" ] || fail "story insert failed ($create)"

MEDIA_PATH=$(sql "select media_path from public.stories where id = '$STORY_ID'")
[ "$MEDIA_PATH" = "$PUBLIC_PARTY/$STORY_ID.jpg" ] \
  || fail "media_path was not derived as {party}/{id}.jpg (got '$MEDIA_PATH')"
pass "row created, path derived server-side: $MEDIA_PATH"

# A story with no bytes yet is invisible to everyone, its own author included.
unconfirmed=$(sql "select tests.authenticate_as('$HOST_ID'); select count(*) from public.get_party_stories('$PUBLIC_PARTY') where id = '$STORY_ID';" | tail -1)
[ "$unconfirmed" = "0" ] || fail "an unconfirmed story was visible"
pass "unconfirmed story is invisible even to its author"

# ============================================================
step "3. signed upload URL (the only way in)"
# ============================================================
sign=$(curl -s -X POST "$API_URL/functions/v1/story-media/upload-url" \
  -H "Authorization: Bearer $HOST_JWT" -H "Content-Type: application/json" \
  -d "{\"story_id\":\"$STORY_ID\"}")
TOKEN=$(jget "$sign" token)
[ -n "$TOKEN" ] || fail "no upload token returned: $sign"
pass "edge function issued a one-shot upload token"

# Someone else's story: the definer RPC refuses, so nothing gets signed.
stranger_sign=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "$API_URL/functions/v1/story-media/upload-url" \
  -H "Authorization: Bearer $STRANGER_JWT" -H "Content-Type: application/json" \
  -d "{\"story_id\":\"$STORY_ID\"}")
[ "$stranger_sign" = "403" ] || fail "a stranger got an upload URL for someone else's story ($stranger_sign)"
pass "a stranger cannot get an upload URL for another user's story"

# ============================================================
step "4. upload the bytes"
# ============================================================
FIXTURE=$(mktemp); trap 'rm -f "$FIXTURE"' EXIT
# A 1x1 JPEG, base64'd, so the script carries no binary fixture file.
base64 -d > "$FIXTURE" <<'JPEG'
/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a
HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAA
AAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==
JPEG

upload=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
  "$API_URL/storage/v1/object/upload/sign/story-media/$MEDIA_PATH?token=$TOKEN" \
  -H "Content-Type: image/jpeg" --data-binary "@$FIXTURE")
[ "$upload" = "200" ] || fail "upload to the signed URL failed ($upload)"
pass "bytes uploaded through the signed URL"

# ============================================================
step "5. confirm (checks storage.objects, not the client's word)"
# ============================================================
confirm=$(curl -s -X POST "$API_URL/rest/v1/rpc/confirm_story_upload" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $HOST_JWT" \
  -H "Content-Type: application/json" -d "{\"p_story_id\":\"$STORY_ID\"}")
[ -z "$confirm" ] || fail "confirm_story_upload errored: $confirm"

visible=$(sql "select tests.authenticate_as('$HOST_ID'); select count(*) from public.get_party_stories('$PUBLIC_PARTY') where id = '$STORY_ID';" | tail -1)
[ "$visible" = "1" ] || fail "confirmed story is still not visible"
pass "confirmed story is live"

# The object really is in the bucket at this point -- established here so that
# "it is gone" at the end means something.
DISK_PATH=$(docker exec "$STORAGE_CONTAINER" sh -c "find /mnt -name '$STORY_ID.jpg' 2>/dev/null" | tr -d '\r' | head -1)
[ -n "$DISK_PATH" ] || fail "no file on the storage container's disk after upload"
pass "file present on disk: $DISK_PATH"

# ============================================================
step "6. view it back through a signed URL"
# ============================================================
view=$(curl -s -X POST "$API_URL/functions/v1/story-media/view-urls" \
  -H "Authorization: Bearer $HOST_JWT" -H "Content-Type: application/json" \
  -d "{\"story_ids\":[\"$STORY_ID\"]}")
SIGNED_PATH=$(jget "$view" "$STORY_ID")
[ -n "$SIGNED_PATH" ] || fail "no signed view URL returned: $view"
# Project-relative by design -- see toRelative() in the edge function. The
# absolute URL supabase-js builds names the gateway as the edge runtime sees it
# (http://kong:8000), which no phone can resolve.
case "$SIGNED_PATH" in /storage/v1/*) ;; *) fail "signed URL was not project-relative: $SIGNED_PATH" ;; esac

fetched=$(curl -s -o /dev/null -w '%{http_code}' "$API_URL$SIGNED_PATH")
[ "$fetched" = "200" ] || fail "signed view URL did not serve the object ($fetched)"
pass "media fetched back through the signed URL"

# Record a view; the counter is a trigger, never a count(*) at read time.
curl -s -o /dev/null -X POST "$API_URL/rest/v1/story_views" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $HOST_JWT" \
  -H "Content-Type: application/json" -H "Prefer: return=minimal" \
  -d "{\"story_id\":\"$STORY_ID\",\"user_id\":\"$HOST_ID\"}"
views=$(sql "select view_count from public.stories where id = '$STORY_ID'")
[ "$views" = "1" ] || fail "view_count did not move (got '$views')"
pass "view recorded, view_count = 1"

# A story on a PRIVATE party the stranger was never invited to must not be
# signable. Same edge function, same route, no url out.
priv_story=$(sql "select gen_random_uuid()")
sql "insert into public.stories (id, party_id, author_id, content_type, media_uploaded_at)
     values ('$priv_story', '$PRIVATE_PARTY', '$HOST_ID', 'image/jpeg', now())" >/dev/null
priv_view=$(curl -s -X POST "$API_URL/functions/v1/story-media/view-urls" \
  -H "Authorization: Bearer $STRANGER_JWT" -H "Content-Type: application/json" \
  -d "{\"story_ids\":[\"$priv_story\"]}")
grep -q "$priv_story" <<<"$priv_view" && fail "stranger got a signed URL for a private party's story: $priv_view"
pass "no signed URL for a private party's story the caller cannot see"

# ============================================================
step "7. fake the clock"
# ============================================================
# created_at moves with it: stories_expires_after_creation would reject an
# expiry that predates the row, and "posted 25 hours ago, died an hour ago" is
# the state the cron will actually meet -- so this simulates an old story rather
# than an impossible one. Done as postgres, because no client role has an UPDATE
# grant on stories at all; that is the point of the table.
sql "update public.stories
     set created_at = now() - interval '25 hours',
         expires_at = now() - interval '1 hour'
     where id = '$STORY_ID'" >/dev/null

expired_visible=$(sql "select tests.authenticate_as('$HOST_ID'); select count(*) from public.get_party_stories('$PUBLIC_PARTY') where id = '$STORY_ID';" | tail -1)
[ "$expired_visible" = "0" ] || fail "an expired story was still visible"
# This is the important ordering property: expiry is enforced by the SELECT
# policy at read time, so it does not wait for -- and cannot be delayed by --
# the cron job below.
pass "expired story is invisible immediately, before any cleanup runs"

# ============================================================
step "8. run the cleanup (what cron calls every 5 minutes)"
# ============================================================
first=$(sql "select hidden || '/' || purged || '/' || confirmed from public.run_story_cleanup()")
pass "tick 1 (hidden/purged/confirmed): $first"
[ "${first%%/*}" -ge 1 ] || fail "the expired story was not hidden"

hidden_reason=$(sql "select hidden_reason from public.stories where id = '$STORY_ID'")
[ "$hidden_reason" = "expired" ] || fail "hidden_reason was '$hidden_reason', expected 'expired'"

# pg_net dispatches after commit, so the DELETE is in flight now. Tick 2 reads
# the response back and is the only thing that may set media_deleted_at.
deadline=$((SECONDS + 60))
while [ $SECONDS -lt $deadline ]; do
  second=$(sql "select hidden || '/' || purged || '/' || confirmed from public.run_story_cleanup()")
  deleted=$(sql "select media_deleted_at is not null from public.stories where id = '$STORY_ID'")
  [ "$deleted" = "t" ] && break
  sleep 3
done
[ "$deleted" = "t" ] || fail "purge never confirmed: $(sql "select status_code, last_error from public.story_media_purges where story_id = '$STORY_ID'")"
pass "tick 2 (hidden/purged/confirmed): ${second:-n/a} -- purge confirmed against the HTTP response"

# ============================================================
step "9. THE ACTUAL PROOF: the object is gone, not just the row"
# ============================================================
meta=$(sql "select count(*) from storage.objects where bucket_id = 'story-media' and name = '$MEDIA_PATH'")
[ "$meta" = "0" ] || fail "storage.objects still has a row for $MEDIA_PATH"
pass "storage.objects row gone"

still_there=$(docker exec "$STORAGE_CONTAINER" sh -c "test -f '$DISK_PATH' && echo yes || echo no" | tr -d '\r')
[ "$still_there" = "no" ] || fail "THE FILE IS STILL ON DISK at $DISK_PATH -- the metadata was deleted but the bytes were not"
pass "file gone from the storage container's disk: $DISK_PATH"

audit=$(sql "select status_code from public.story_media_purges where story_id = '$STORY_ID'")
pass "purge ledger closed with storage status $audit"

open_debt=$(sql "select count(*) from public.story_media_purges where completed_at is null")
pass "outstanding purges: $open_debt"

printf '\n\033[32mAll story lifecycle assertions passed.\033[0m\n'
