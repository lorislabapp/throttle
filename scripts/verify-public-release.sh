#!/usr/bin/env bash
# Verify a published Throttle release the way a Sparkle client sees it.
# Compares what lorislab.fr serves against the staged files byte-for-byte:
#   - DMG: full downloads through a plain AND a cache-busted request; both lengths and
#     SHA-256 hashes must match the staged (notarized) DMG. The two requests differ on
#     purpose: on 2026-08-21 the origin had the file while the edge kept serving a cached 404.
#   - appcast: identical bytes, and the top item is the new build.
#   - page: advertises the new DMG.
# Usage: scripts/verify-public-release.sh <stage-dir>
set -Eeuo pipefail
STAGE="${1:?usage: $0 <stage-dir>}"
SITE="${THROTTLE_VERIFY_SITE:-https://lorislab.fr/throttle}"
DMG=$(ls "$STAGE"/throttle/Throttle-*.dmg)
NAME=$(basename "$DMG")
WANT_LEN=$(stat -f%z "$DMG")
WANT_SHA=$(shasum -a 256 "$DMG" | cut -c1-64)
BUILD=$(grep -m1 -oE '<sparkle:version>[0-9]+' "$STAGE/throttle/appcast.xml" | tr -dc '0-9')
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail() { echo "✘ $*" >&2; exit 1; }
# Every fetch retries and names itself on failure: a transient edge hiccup must read as
# "could not fetch X", never as a silent exit under set -e.
get() { curl -fsS --retry 3 --retry-all-errors --retry-delay 2 "$@" || fail "could not fetch: ${*: -1}"; }

for url in "$SITE/$NAME" "$SITE/$NAME?cb=$(date +%s)"; do
    code=$(get -o "$TMP/dl.dmg" -w '%{http_code}' "$url")
    [ "$code" = "200" ] || fail "$url → HTTP $code"
    len=$(stat -f%z "$TMP/dl.dmg")
    [ "$len" = "$WANT_LEN" ] || fail "$url → length $len, expected $WANT_LEN"
    got_sha=$(shasum -a 256 "$TMP/dl.dmg" | cut -c1-64)
    [ "$got_sha" = "$WANT_SHA" ] || fail "$url → SHA-256 $got_sha != staged $WANT_SHA"
    echo "→ DMG bytes identical from $url: sha256 $WANT_SHA"
done
echo "→ DMG served: HTTP 200, $WANT_LEN bytes, matching SHA-256 (plain and cache-busted)"

get -o "$TMP/appcast.xml" "$SITE/appcast.xml?cb=$(date +%s)"
cmp -s "$TMP/appcast.xml" "$STAGE/throttle/appcast.xml" || fail "public appcast differs from the staged one"
TOP=$(grep -m1 -oE '<sparkle:version>[0-9]+' "$TMP/appcast.xml" | tr -dc '0-9')
[ "$TOP" = "$BUILD" ] || fail "appcast top item is build $TOP, expected $BUILD"
get -o "$TMP/appcast-edge.xml" "$SITE/appcast.xml"   # to a file: grep -m1 on a pipe would SIGPIPE curl
cmp -s "$TMP/appcast-edge.xml" "$STAGE/throttle/appcast.xml" || fail "edge-cached appcast differs from staged bytes"
EDGE=$(grep -m1 -oE '<sparkle:version>[0-9]+' "$TMP/appcast-edge.xml" | tr -dc '0-9')
[ "$EDGE" = "$BUILD" ] || fail "edge-cached appcast still serves build $EDGE — purge the cache"
echo "→ appcast identical; top item build $BUILD (fresh and edge-cached)"

for url in "$SITE/" "$SITE/?cb=$(date +%s)"; do
    get -o "$TMP/index.html" "$url"
    grep -q "href=\"$NAME\"" "$TMP/index.html" || fail "$url does not link $NAME"
done
echo "→ product page links $NAME (plain and cache-busted)"
echo "✔ $NAME (build $BUILD) is live and byte-verified from $SITE"
