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
Scripts/verify-reasoning-oracle.sh
Scripts/verify-reasoning-supply-chain.sh
Scripts/verify-ipc-boundary.sh
Scripts/verify-crash-recovery.sh debug
Scripts/verify-agent-hook.sh

# The retrieval gate is the headline claim of this package, so an unrunnable
# benchmark is a verification failure, not a note. Skipping it silently while
# still exiting 0 meant a green verify.sh could report nothing about retrieval
# at all — the same silent-degradation failure the vault is supposed to prevent.
# Set RESEARCH_VAULT_ALLOW_BENCHMARK_SKIP=1 to opt out deliberately (a machine
# with no corpus checkout); the skip is then loud and still recorded.
research_vault_deepsearsh_root="${RESEARCH_VAULT_DEEPSEARSH_ROOT:-/Users/kevinnadjarian/GitHub/DeepSearsh}"
# A frozen corpus manifest (private, outside the repository) binds the benchmark
# to a reviewed corpus; drift is refused with a named report instead of a bare
# hash. Human questions, when present, are the only basis for a quality claim.
research_vault_manifest="${RESEARCH_VAULT_CORPUS_MANIFEST:-$HOME/Library/Application Support/Throttle/research-vault/golden-set.manifest.json}"
research_vault_human_queries="${RESEARCH_VAULT_HUMAN_QUERIES:-$HOME/Library/Application Support/Throttle/research-vault/golden-set.human-queries.json}"
benchmark_arguments=()
if [ -r "$research_vault_manifest" ]; then
    benchmark_arguments+=(--manifest "$research_vault_manifest")
fi
if [ -r "$research_vault_human_queries" ]; then
    benchmark_arguments+=(--human-queries "$research_vault_human_queries")
fi
if [ -r "$research_vault_deepsearsh_root/catalog.jsonl" ]; then
    swift run research-vault-benchmark "$research_vault_deepsearsh_root" "${benchmark_arguments[@]}"
    RESEARCH_VAULT_DEEPSEARSH_ROOT="$research_vault_deepsearsh_root" \
        Scripts/verify-mcp-process.sh
elif [ "${RESEARCH_VAULT_ALLOW_BENCHMARK_SKIP:-0}" = "1" ]; then
    echo '{"status":"skipped","scenario":"live-benchmark","reason":"opted out via RESEARCH_VAULT_ALLOW_BENCHMARK_SKIP"}'
    echo "WARNING: retrieval gate NOT verified in this run." >&2
else
    echo "LIVE BENCHMARK UNRUNNABLE: unreadable DeepSearsh catalog at $research_vault_deepsearsh_root" >&2
    echo "The retrieval gate cannot be verified, so this run cannot pass." >&2
    echo "Set RESEARCH_VAULT_DEEPSEARSH_ROOT, or RESEARCH_VAULT_ALLOW_BENCHMARK_SKIP=1 to opt out." >&2
    exit 1
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
