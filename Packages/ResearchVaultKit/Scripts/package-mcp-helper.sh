#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: Scripts/package-mcp-helper.sh DESTINATION" >&2
    exit 64
fi

destination="$1"
if [ -e "$destination" ]; then
    echo "destination already exists: $destination" >&2
    exit 65
fi

swift build -c release --product research-vault-mcp
product_directory="$(swift build -c release --show-bin-path)"
binary="$product_directory/research-vault-mcp"
framework="$product_directory/SQLCipher.framework"
test -x "$binary"
test -d "$framework"

if ! command -v otool >/dev/null 2>&1; then
    echo "refusing package: otool is missing" >&2
    exit 66
fi
# Capture the complete output only after otool succeeds. A diagnostic tool can
# emit plausible partial output and still return an error.
if linked_libraries=$(otool -L "$binary"); then
    :
else
    echo "refusing package: otool could not inspect the helper" >&2
    exit 66
fi
case "$linked_libraries" in
    *'/usr/lib/libsqlite3'*)
        echo "refusing package: helper links system SQLite" >&2
        exit 66 ;;
esac
case "$linked_libraries" in
    *'@rpath/SQLCipher.framework'*) ;;
    *) echo "refusing package: SQLCipher linkage is missing" >&2; exit 66 ;;
esac

staging_parent="$(mktemp -d "${TMPDIR:-/tmp}/research-vault-mcp-package.XXXXXX")"
trap 'rm -rf "$staging_parent"' EXIT HUP INT TERM
staging="$staging_parent/research-vault-mcp"
mkdir -p "$staging"
ditto "$binary" "$staging/research-vault-mcp"
ditto "$framework" "$staging/SQLCipher.framework"
ditto THIRD_PARTY_NOTICES.md "$staging/THIRD_PARTY_NOTICES.md"
ditto README.md "$staging/README.md"

(
    cd "$staging"
    # Keep every stage's exit status: no partial traversal/sort can yield a
    # supposedly complete, green checksum manifest through a pipeline.
    find . -type f ! -name SHA256SUMS -print0 > "$staging_parent/files.unsorted"
    sort -z "$staging_parent/files.unsorted" > "$staging_parent/files.sorted"
    test -s "$staging_parent/files.sorted"
    xargs -0 shasum -a 256 < "$staging_parent/files.sorted" > SHA256SUMS
)
rm "$staging_parent/files.unsorted" "$staging_parent/files.sorted"

mkdir -p "$(dirname "$destination")"
mv "$staging" "$destination"
trap - EXIT HUP INT TERM
rmdir "$staging_parent"
echo "PACKAGED: $destination"
