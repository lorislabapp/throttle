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

if otool -L "$binary" | grep -q '/usr/lib/libsqlite3'; then
    echo "refusing package: helper links system SQLite" >&2
    exit 66
fi
otool -L "$binary" | grep -q '@rpath/SQLCipher.framework'

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
    find . -type f ! -name SHA256SUMS -print0 \
        | sort -z \
        | xargs -0 shasum -a 256 > SHA256SUMS
)

mkdir -p "$(dirname "$destination")"
mv "$staging" "$destination"
trap - EXIT HUP INT TERM
rmdir "$staging_parent"
echo "PACKAGED: $destination"
