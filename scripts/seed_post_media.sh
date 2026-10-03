#!/usr/bin/env bash
# Seed host posts WITH THEIR BYTES, so the MY PARTIES tab's HostPostStrip has
# something to draw.
#
# WHY THIS IS A SCRIPT AND NOT seed.sql. Two independent reasons, and either
# alone would be enough:
#
#   1. seed.sql cannot put a file in a bucket. The bytes live in the storage
#      container, not in Postgres (gotcha #7), and only the Storage API writes
#      them. seed.sql could insert the ROW, and the strip would then sign a URL
#      for an object that does not exist, get a 404, and collapse the tile --
#      landing exactly where we started, with an extra row to explain it. This
#      is the same rule seed.sql already states for avatar_path: seed the
#      object first, then the path.
#   2. 20260825095311 makes a media post INVISIBLE until confirm_post_upload
#      has checked storage.objects for the bytes. There is no ordering inside
#      one SQL file that satisfies that, because the thing being checked for is
#      not in the database.
#
# So it runs the real handshake -- insert as the host under RLS, PUT the bytes,
# confirm -- rather than writing media_uploaded_at directly. That costs nothing
# and means this script fails loudly if the host-only INSERT policy or the
# confirmation ever break, instead of seeding rows around them.
#
# IDEMPOTENT. Fixed post ids, deleted and re-created on every run, so it is
# safe to re-run and safe to run twice after one `supabase db reset`.
#
# Usage:
#   supabase start
#   supabase db reset
#   bash scripts/seed_post_media.sh
#
# Then sign in as host@myparty.local / password123 and open Parties -> MY PARTIES.

set -euo pipefail

DB_CONTAINER="supabase_db_MyParty"
API_URL="${API_URL:-http://127.0.0.1:54321}"
PYTHON_BIN="${PYTHON_BIN:-python}"

# The fixed local demo service key -- the same one `supabase status` prints on
# every machine. Not a secret.
SERVICE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU"

# The viewer these posts are FOR. Every party below is one this persona has an
# rsvps row on, which is what puts it on the MY PARTIES tab -- posts on any
# other party would be seeded into a screen nobody can reach.
VIEWER="11111111-1111-1111-1111-111111111111"

SECOND_HOST="66666666-6666-6666-6666-666666666666"
MARIA="0c0c0c0c-0000-0000-0000-000000000002"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

sql() { docker exec "$DB_CONTAINER" psql -U postgres -d postgres -tAc "$1" | tr -d '\r'; }
sqlq() { docker exec "$DB_CONTAINER" psql -U postgres -d postgres -q -v ON_ERROR_STOP=1 -c "$1" >/dev/null; }

# Run one statement AS a given user, through RLS, the way the app would.
# Mirrors tests.authenticate_as: the role plus the jwt claim auth.uid() reads.
as_user() {
  local uid="$1" stmt="$2"
  docker exec "$DB_CONTAINER" psql -U postgres -d postgres -q -v ON_ERROR_STOP=1 -c "
    begin;
    select set_config('request.jwt.claims', '{\"sub\":\"$uid\",\"role\":\"authenticated\"}', true);
    set local role authenticated;
    $stmt;
    commit;" >/dev/null
}

# ============================================================
step "0. preflight"
# ============================================================
docker inspect "$DB_CONTAINER" >/dev/null 2>&1 || fail "the local stack is not running (supabase start)"

[ "$(sql "select count(*) from information_schema.columns
          where table_schema='public' and table_name='party_posts'
          and column_name='media_uploaded_at'")" = "1" ] \
  || fail "20260825095311 is not applied (supabase db reset)"

[ "$(sql "select count(*) from public.rsvps where user_id = '$VIEWER'")" -gt 0 ] \
  || fail "seed personas are missing -- run supabase db reset"

command -v "$PYTHON_BIN" >/dev/null || fail "$PYTHON_BIN not found (set PYTHON_BIN)"
"$PYTHON_BIN" -c "import PIL" 2>/dev/null || fail "Pillow not installed (pip install Pillow)"
pass "stack up, handshake migration applied, personas present"

# ============================================================
step "1. draw the photos"
# ============================================================
# Generated rather than checked in: a few hundred KB of binary in git to make a
# thumbnail strip non-empty is a bad trade, and these need to be visibly
# DIFFERENT from each other so a strip that renders the same tile six times is
# obvious. They are real JPEGs -- decodable, ~900x900 -- not stock photography,
# and they look like what they are.
"$PYTHON_BIN" - "$WORKDIR" <<'PY'
import sys, random
from PIL import Image, ImageDraw, ImageFont

out = sys.argv[1]

# (filename, label, two hex stops). The stops are the app's own palette --
# purple #7B2FF7, private red #F23557, bg #0B0A10 -- so the strip looks like it
# belongs to this app rather than to a placeholder service.
PHOTOS = [
    ("loft-1.jpg",    "LOFT",    "#2B1055", "#7B2FF7"),
    ("loft-2.jpg",    "DECKS",   "#7B2FF7", "#F23557"),
    ("loft-3.jpg",    "03:40",   "#0B0A10", "#2B1055"),
    ("rooftop-1.jpg", "SUNSET",  "#F23557", "#FFB86B"),
    ("rooftop-2.jpg", "DUB",     "#1B3B5A", "#7B2FF7"),
    ("terrace-1.jpg", "TERRACE", "#FFB86B", "#2B1055"),
]

def hex2rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))

def font(size):
    for name in ("segoeuib.ttf", "arialbd.ttf", "DejaVuSans-Bold.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()

S = 900
for name, label, c0, c1 in PHOTOS:
    a, b = hex2rgb(c0), hex2rgb(c1)
    img = Image.new("RGB", (S, S))
    px = img.load()
    # Diagonal gradient, so no two tiles read as flat colour swatches.
    for y in range(S):
        for x in range(S):
            t = (x + y) / (2 * S - 2)
            px[x, y] = tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

    d = ImageDraw.Draw(img, "RGBA")
    # A few soft blobs -- enough structure that JPEG compression has something
    # to do and a 46px thumbnail does not look like a CSS gradient.
    rnd = random.Random(name)
    for _ in range(14):
        r = rnd.randint(40, 190)
        cx, cy = rnd.randint(0, S), rnd.randint(0, S)
        d.ellipse([cx - r, cy - r, cx + r, cy + r],
                  fill=(255, 255, 255, rnd.randint(6, 26)))

    f = font(96)
    bbox = d.textbbox((0, 0), label, font=f)
    d.text(((S - (bbox[2] - bbox[0])) / 2, (S - (bbox[3] - bbox[1])) / 2 - 30),
           label, font=f, fill=(255, 255, 255, 235))

    img.save("%s/%s" % (out, name), "JPEG", quality=86, optimize=True)
PY
pass "6 jpegs drawn"

# ============================================================
step "2. seed the posts, through the real handshake"
# ============================================================
# post_id | party_id | author key (must be the party's HOST) | file | body
#
# Bodies carry no apostrophes, deliberately: they are interpolated into a
# single-quoted SQL literal below and dollar-quoting does not survive the trip
# through the double-quoted shell string that carries the statement.
read -r -d '' POSTS <<'ROWS' || true
bbbbbbbb-0000-0000-0000-000000000001|aaaaaaaa-0000-0000-0000-000000000013|SECOND_HOST|loft-1.jpg|Doors from 22:00. Fifth floor, the lift is broken again.
bbbbbbbb-0000-0000-0000-000000000002|aaaaaaaa-0000-0000-0000-000000000013|SECOND_HOST|loft-2.jpg|Decks are set up. Bring records if you want a turn.
bbbbbbbb-0000-0000-0000-000000000003|aaaaaaaa-0000-0000-0000-000000000013|SECOND_HOST|loft-3.jpg|Last one ran to 04:00. Pace yourselves.
bbbbbbbb-0000-0000-0000-000000000004|aaaaaaaa-0000-0000-0000-000000000041|SECOND_HOST|rooftop-1.jpg|Sunset was worth the climb.
bbbbbbbb-0000-0000-0000-000000000005|aaaaaaaa-0000-0000-0000-000000000041|SECOND_HOST|rooftop-2.jpg|Dub until the neighbours asked nicely.
bbbbbbbb-0000-0000-0000-000000000006|aaaaaaaa-0000-0000-0000-000000000042|MARIA|terrace-1.jpg|Terrace over the flea market. Same time next month.
ROWS

# Clean first, so a re-run replaces rather than accumulates. The storage
# objects go too -- an orphaned object is invisible to the one table you would
# enumerate to find it (gotcha #7), and these paths are about to be rewritten.
while IFS='|' read -r post_id party_id _author _file _body; do
  [ -z "$post_id" ] && continue
  curl -s -o /dev/null -X DELETE \
    "$API_URL/storage/v1/object/post-media/$party_id/$post_id.jpg" \
    -H "Authorization: Bearer $SERVICE_KEY"
  sqlq "delete from public.party_posts where id = '$post_id'"
done <<< "$POSTS"
pass "previous run cleared"

count=0
while IFS='|' read -r post_id party_id author file body; do
  [ -z "$post_id" ] && continue
  case "$author" in
    SECOND_HOST) uid="$SECOND_HOST" ;;
    MARIA)       uid="$MARIA" ;;
    *)           fail "unknown author key $author" ;;
  esac

  # a. Insert as the host, under RLS. media_type only -- the before-insert
  #    trigger derives media_path, which carries no insert grant.
  as_user "$uid" "insert into public.party_posts (id, party_id, author_id, body, media_type)
                  values ('$post_id', '$party_id', '$uid', '$body', 'image/jpeg')" \
    || fail "insert refused for $post_id -- is $uid the host of $party_id?"

  # b. The path the row expects its bytes at. Read back rather than rebuilt
  #    here, so this script cannot drift from set_post_media_path().
  path=$(sql "select media_path from public.party_posts where id = '$post_id'")
  [ -n "$path" ] || fail "no media_path derived for $post_id"

  # c. The bytes. Service key, because post-media has no INSERT policy for any
  #    client role -- uploads are signed-URL only, and this is the same door
  #    the post-media edge function opens.
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "$API_URL/storage/v1/object/post-media/$path" \
    -H "Authorization: Bearer $SERVICE_KEY" \
    -H "Content-Type: image/jpeg" \
    --data-binary "@$WORKDIR/$file")
  [ "$code" = "200" ] || fail "upload of $path returned $code"

  # d. Confirm, as the author. This is what makes the row visible, and it
  #    re-checks storage.objects rather than taking our word for the PUT.
  as_user "$uid" "select public.confirm_post_upload('$post_id')" \
    || fail "confirm_post_upload refused $post_id"

  count=$((count + 1))
  pass "$path"
done <<< "$POSTS"

# ============================================================
step "3. check the viewer can actually see them"
# ============================================================
# The point of the whole exercise. A post that exists but is invisible to the
# persona whose tab it was seeded for has achieved nothing, and every step
# above would still have printed ok.
#
# The grep is not decoration: psql echoes BEGIN/SET/COMMIT around the count, so
# capturing the whole output gives a string with the answer buried in it that
# can never equal $count -- a check that only ever fails.
visible=$(docker exec "$DB_CONTAINER" psql -U postgres -d postgres -tAc "
  begin;
  select set_config('request.jwt.claims', '{\"sub\":\"$VIEWER\",\"role\":\"authenticated\"}', true);
  set local role authenticated;
  select count(*) from public.party_posts
  where party_id in (select party_id from public.rsvps where user_id = '$VIEWER');
  commit;" | tr -d '\r' | grep -E '^[0-9]+$' | tail -1)

[ "$visible" = "$count" ] \
  || fail "seeded $count posts but the viewer sees $visible -- RLS is hiding them"
pass "host@myparty.local sees all $count, across 3 parties on MY PARTIES"

printf '\n\033[1mDone.\033[0m Sign in as host@myparty.local / password123, open Parties -> MY PARTIES.\n'
