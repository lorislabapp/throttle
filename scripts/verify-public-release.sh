#!/usr/bin/env bash
# Verify a published Throttle release the way a Sparkle client sees it.
# Compares what lorislab.fr serves against the staged files byte-for-byte:
#   - DMG: HTTP 200 + exact length through a plain AND a cache-busted request, then a full
#     download whose SHA-256 must match the staged (notarized) DMG. The two requests differ on
#     purpose: on 2026-08-21 the origin had the file while the edge kept serving a cached 404.
#   - appcast: identical bytes, and the top item is the new build.
#   - page: advertises the new DMG.
# Usage: scripts/verify-public-release.sh <stage-dir>
set -Eeuo pipefail
STAGE="${1:?usage: $0 <stage-dir>}"
SITE="https://lorislab.fr/throttle"
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
    read -r code len < <(get -I "$url" | tr -d '\r' | awk 'toupper($1)~/^HTTP/{c=$2} tolower($1)=="content-length:"{l=$2} END{print c, l}')
    [ "$code" = "200" ] || fail "$url → HTTP $code"
    [ "$len" = "$WANT_LEN" ] || fail "$url → length $len, expected $WANT_LEN"
done
echo "→ DMG served: HTTP 200, $WANT_LEN bytes (plain and cache-busted)"

get -o "$TMP/dl.dmg" "$SITE/$NAME"
GOT_SHA=$(shasum -a 256 "$TMP/dl.dmg" | cut -c1-64)
[ "$GOT_SHA" = "$WANT_SHA" ] || fail "downloaded SHA-256 $GOT_SHA != staged $WANT_SHA"
echo "→ DMG bytes identical: sha256 $WANT_SHA"

get -o "$TMP/appcast.xml" "$SITE/appcast.xml?cb=$(date +%s)"
cmp -s "$TMP/appcast.xml" "$STAGE/throttle/appcast.xml" || fail "public appcast differs from the staged one"
TOP=$(grep -m1 -oE '<sparkle:version>[0-9]+' "$TMP/appcast.xml" | tr -dc '0-9')
[ "$TOP" = "$BUILD" ] || fail "appcast top item is build $TOP, expected $BUILD"
get -o "$TMP/appcast-edge.xml" "$SITE/appcast.xml"   # to a file: grep -m1 on a pipe would SIGPIPE curl
EDGE=$(grep -m1 -oE '<sparkle:version>[0-9]+' "$TMP/appcast-edge.xml" | tr -dc '0-9')
[ "$EDGE" = "$BUILD" ] || fail "edge-cached appcast still serves build $EDGE — purge the cache"
echo "→ appcast identical; top item build $BUILD (fresh and edge-cached)"

get -o "$TMP/index.html" "$SITE/?cb=$(date +%s)"
grep -q "href=\"$NAME\"" "$TMP/index.html" || fail "product page does not link $NAME"
echo "→ product page links $NAME"
echo "✔ $NAME (build $BUILD) is live and byte-verified"
