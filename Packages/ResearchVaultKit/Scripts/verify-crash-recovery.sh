#!/bin/sh
set -eu

configuration="${1:-debug}"
case "$configuration" in
    debug|release) ;;
    *) echo "configuration must be debug or release" >&2; exit 2 ;;
esac

swift build -c "$configuration" --product research-vault-crash-probe
product_directory="$(swift build -c "$configuration" --show-bin-path)"
mkdir -p "$product_directory/PackageFrameworks"
ditto \
    "$product_directory/SQLCipher.framework" \
    "$product_directory/PackageFrameworks/SQLCipher.framework"

probe="$product_directory/research-vault-crash-probe"
probe_directory="$(mktemp -d "${TMPDIR:-/tmp}/research-vault-crash.XXXXXX")"
trap 'rm -rf "$probe_directory"' EXIT HUP INT TERM

assert_crash_exit() {
    mode="$1"
    database="$2"
    set +e
    "$probe" "$mode" "$database"
    status="$?"
    set -e
    if [ "$status" -ne 86 ]; then
        echo "unexpected crash-probe exit: $status" >&2
        exit 1
    fi
}

write_database="$probe_directory/write.ccsql"
"$probe" prepare-write "$write_database"
assert_crash_exit crash-write "$write_database"
"$probe" verify-write "$write_database"

migration_database="$probe_directory/migration.ccsql"
"$probe" prepare-migration "$migration_database"
assert_crash_exit crash-migration "$migration_database"
"$probe" verify-migration "$migration_database"

