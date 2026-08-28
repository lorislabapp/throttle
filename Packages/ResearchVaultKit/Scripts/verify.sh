#!/bin/sh
set -eu

verify_debug() {
    swift build -c debug --build-tests
    product_directory="$(swift build -c debug --show-bin-path)"

    # SQLCipher.swift 4.18.0 is an official dynamic XCFramework. SwiftPM 6.4
    # places it beside the XCTest bundles but does not stage it in the rpath
    # PackageFrameworks directory. Stage the already checksum-verified artifact
    # without modifying its binary or signature.
    mkdir -p "$product_directory/PackageFrameworks"
    ditto \
        "$product_directory/SQLCipher.framework" \
        "$product_directory/PackageFrameworks/SQLCipher.framework"

    swift test -c debug --skip-build
}

verify_release() {
    # Xcode 27 beta's default `swiftbuild` currently races explicit Swift module
    # discovery for release test targets. The native SwiftPM backend produces one
    # correctly embedded XCTest runner and is retained as an explicit evidence
    # workaround until that upstream failure is fixed.
    swift build -c release --build-tests --build-system native
    swift test -c release --skip-build --build-system native
}

verify_debug
Scripts/verify-ipc-boundary.sh
Scripts/verify-crash-recovery.sh debug

research_vault_deepsearsh_root="${RESEARCH_VAULT_DEEPSEARSH_ROOT:-/Users/kevinnadjarian/GitHub/DeepSearsh}"
if [ -r "$research_vault_deepsearsh_root/catalog.jsonl" ]; then
    swift run research-vault-benchmark "$research_vault_deepsearsh_root"
    RESEARCH_VAULT_DEEPSEARSH_ROOT="$research_vault_deepsearsh_root" \
        Scripts/verify-mcp-process.sh
else
    echo "LIVE BENCHMARK SKIPPED: unreadable DeepSearsh catalog at $research_vault_deepsearsh_root"
fi

verify_release
swift build -c release --product research-vault-xpc-service --build-system native
Scripts/verify-crash-recovery.sh release

release_product_directory="$(swift build -c release --show-bin-path --build-system native)"
set +e
"$release_product_directory/research-vault-mcp" \
    --ephemeral-testing-key --database > /dev/null 2>&1
release_testing_flag_status=$?
set -e
if [ "$release_testing_flag_status" -ne 1 ]; then
    echo "Release MCP unexpectedly accepted the Debug-only testing flag" >&2
    exit 1
fi
echo '{"status":"pass","scenario":"release-rejects-testing-key"}'

set +e
"$release_product_directory/research-vault-mcp" > /dev/null 2>&1
release_direct_stdio_status=$?
set -e
if [ "$release_direct_stdio_status" -ne 1 ]; then
    echo "Release MCP unexpectedly enabled unauthenticated direct stdio" >&2
    exit 1
fi
echo '{"status":"pass","scenario":"release-rejects-direct-stdio"}'
