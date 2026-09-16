#!/bin/sh
set -eu

for boundary_tool in grep find sh dirname; do
    if ! command -v "$boundary_tool" >/dev/null 2>&1; then
        printf 'IPC boundary prerequisite missing: %s\n' "$boundary_tool" >&2
        exit 2
    fi
done

package_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$package_root"
client_root=${RESEARCH_VAULT_CLIENT_ROOT-/Users/kevinnadjarian/GitHub/CheatCode/CheatCodeSpikes}

if [ ! -d Sources/ResearchVaultIPCModel ]; then
    printf 'IPC model source directory is missing\n' >&2
    exit 2
fi
if [ -z "$client_root" ] || [ ! -f "$client_root/Package.swift" ] || [ ! -d "$client_root/Sources" ]; then
    printf 'Client Package.swift or Sources is missing; set RESEARCH_VAULT_CLIENT_ROOT to the client package\n' >&2
    exit 2
fi

# POSIX find -exec ... + propagates a nonzero invocation as a find failure.
# Each file is checked separately: grep 1 alone means absence; tool/read errors
# must never become a successful scan. Do not echo potentially sensitive lines.
check_boundary() {
    boundary_message=$1
    boundary_pattern=$2
    shift 2
    if find "$@" \( -type f -o -type l \) -exec sh -c '
        message=$1
        pattern=$2
        shift 2
        for source_file do
            if [ -L "$source_file" ]; then
                printf "IPC boundary cannot verify a symbolic link: %s\n" "$source_file" >&2
                exit 2
            fi
            if grep -E "$pattern" "$source_file" >/dev/null; then
                printf "%s: %s\n" "$message" "$source_file" >&2
                exit 1
            else
                grep_status=$?
                if [ "$grep_status" -ne 1 ]; then
                    printf "IPC boundary grep failed (status %s): %s\n" "$grep_status" "$source_file" >&2
                    exit 2
                fi
            fi
        done
    ' boundary-scan "$boundary_message" "$boundary_pattern" {} +; then
        :
    else
        printf 'IPC boundary scan did not complete successfully\n' >&2
        exit 1
    fi
}

privileged_import='import[[:space:]]+ResearchVault(SQLCipher|Gateway|Keychain|Ingestion|Store|MCP)'
check_boundary 'IPC model imports a privileged Research Vault module' "$privileged_import" \
    "$package_root/Sources/ResearchVaultIPCModel"
check_boundary 'IPC request surface contains an owner capability or grant' \
    'func[[:space:]]+(import|backup|restore)|database(URL|Path)|masterKey' \
    "$package_root/Sources/ResearchVaultIPCModel"
check_boundary 'Client directly imports a privileged Research Vault module' "$privileged_import" \
    "$client_root/Package.swift" "$client_root/Sources"

# The standalone contract package must stay free of every product module, not
# only the privileged ones, and must expose no owner capability or grant.
contract_root="$package_root/../ThrottleVaultContract/Sources/ThrottleVaultContract"
if [ ! -d "$contract_root" ]; then
    printf 'Vault contract source directory is missing\n' >&2
    exit 2
fi
check_boundary 'Vault contract imports a product module' \
    'import[[:space:]]+(ResearchVault|ThrottleShared|ThrottlePeer|ThrottleMCP|ThrottleMirror)' \
    "$contract_root"
check_boundary 'Vault contract surface contains an owner capability or grant' \
    'func[[:space:]]+(import|backup|restore)|database(URL|Path)|masterKey' \
    "$contract_root"

# The standalone client package speaks the contract over NSXPC. It may import
# nothing from the product and must never carry a grant, key or database path.
client_package_root="$package_root/../ThrottleVaultClient/Sources/ThrottleVaultClient"
if [ ! -d "$client_package_root" ]; then
    printf 'Vault client source directory is missing\n' >&2
    exit 2
fi
check_boundary 'Vault client imports a product module' \
    'import[[:space:]]+(ResearchVault|ThrottleShared|ThrottlePeer|ThrottleMCP|ThrottleMirror)' \
    "$client_package_root"
check_boundary 'Vault client carries a grant, key or database path' \
    'VaultAuthorization|EndpointPolicy|database(URL|Path)|masterKey|SecItem(Add|Copy|Update|Delete)' \
    "$client_package_root"

echo '{"status":"pass","scenario":"ipc-boundary-no-privileged-client-dependency"}'
