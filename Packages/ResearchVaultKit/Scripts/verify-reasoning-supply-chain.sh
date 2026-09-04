#!/bin/sh
set -eu

package_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if grep -Eiq 'lemmalog|grahambrooks' \
    "$package_root/Package.swift" "$package_root/Package.resolved"; then
    echo "Lemmalog unexpectedly appears in the Swift package graph" >&2
    exit 1
fi

bundle_path=${RESEARCH_VAULT_APP_BUNDLE:-}
if [ -n "$bundle_path" ]; then
    test -d "$bundle_path"
    if find "$bundle_path" -iname '*lemmalog*' -print -quit | grep -q .; then
        echo "Lemmalog unexpectedly appears in the application bundle" >&2
        exit 1
    fi
fi

printf '{"status":"pass","scenario":"reasoning-oracle-absent-from-runtime-graph"}\n'
