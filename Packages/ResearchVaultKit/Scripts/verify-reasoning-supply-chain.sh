#!/bin/sh
set -eu

for supply_tool in grep find dirname; do
    if ! command -v "$supply_tool" >/dev/null 2>&1; then
        printf 'Supply-chain prerequisite missing: %s\n' "$supply_tool" >&2
        exit 2
    fi
done

package_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
for graph_file in "$package_root/Package.swift" "$package_root/Package.resolved"; do
    if [ ! -f "$graph_file" ]; then
        printf 'Package graph input missing: %s\n' "$graph_file" >&2
        exit 2
    fi
    if grep -Ei 'lemmalog|grahambrooks' "$graph_file" >/dev/null; then
        echo "Lemmalog unexpectedly appears in the Swift package graph" >&2
        exit 1
    else
        grep_status=$?
        if [ "$grep_status" -ne 1 ]; then
            printf 'Package graph grep failed (status %s): %s\n' "$grep_status" "$graph_file" >&2
            exit 2
        fi
    fi
done

bundle_path=${RESEARCH_VAULT_APP_BUNDLE:-}
bundle_inspected=false
if [ -n "$bundle_path" ]; then
    if [ ! -d "$bundle_path" ]; then
        printf 'Application bundle directory missing: %s\n' "$bundle_path" >&2
        exit 2
    fi
    # find does not descend into a command-line symlink by default. Resolve the
    # requested bundle first so an alias cannot masquerade as an empty scan.
    bundle_path=$(CDPATH= cd -- "$bundle_path" && pwd -P)
    if bundle_matches=$(find "$bundle_path" -iname '*lemmalog*' -print); then
        :
    else
        printf 'Application bundle traversal failed\n' >&2
        exit 2
    fi
    if [ -n "$bundle_matches" ]; then
        echo "Lemmalog unexpectedly appears in the application bundle" >&2
        exit 1
    fi
    bundle_inspected=true
fi

printf '{"status":"pass","scenario":"reasoning-oracle-absent-from-runtime-graph","package_graph_verified":true,"bundle_filename_scan_performed":%s}\n' \
    "$bundle_inspected"
