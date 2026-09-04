#!/bin/sh
set -eu

package_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
oracle_root=${LEMMALOG_ORACLE_ROOT:-/private/tmp/throttle-lemmalog-research-20260829}
expected_commit=7d6f1541130aba53949a2da90cc3e134cb0aac01
program_count=${REASONING_ORACLE_PROGRAMS:-10000}

test -d "$oracle_root/.git"
test "$(git -C "$oracle_root" rev-parse HEAD)" = "$expected_commit"
test -f "$oracle_root/LICENSE"
test "$(shasum -a 256 "$oracle_root/LICENSE" | awk '{print $1}')" = \
    212da0f1b3ebea42880b338390b99defc8a12a0ac45d0acf6a228280b2cc8652
test "$(shasum -a 256 "$package_root/Tests/Fixtures/LemmalogOracle/throttle-oracle.rs" | awk '{print $1}')" = \
    c840ce9102024b33c657e963b651411f4c2b4c8c36e5b15029519df4660c2901

cp "$package_root/Tests/Fixtures/LemmalogOracle/throttle-oracle.rs" \
    "$oracle_root/src/bin/throttle-oracle.rs"

output_root=$(mktemp -d /private/tmp/research-vault-oracle.XXXXXX)
trap 'rm -rf "$output_root"' EXIT HUP INT TERM

(cd "$oracle_root" && cargo run --quiet --bin throttle-oracle -- "$program_count") \
    > "$output_root/lemmalog.txt"
(cd "$package_root" && \
    SWIFTPM_MODULECACHE_OVERRIDE="$output_root/swift-module-cache" \
    CLANG_MODULE_CACHE_PATH="$output_root/clang-module-cache" \
    swift run --quiet -c release --scratch-path "$output_root/swift-build" \
        research-vault-reasoning-differential "$program_count") \
    > "$output_root/swift.txt"

if ! cmp "$output_root/lemmalog.txt" "$output_root/swift.txt"; then
    diff -u "$output_root/lemmalog.txt" "$output_root/swift.txt" | sed -n '1,80p' || true
    exit 1
fi
printf '{"status":"pass","scenario":"reasoning-differential","programs":%s,"lemmalog_commit":"%s"}\n' \
    "$program_count" "$expected_commit"
