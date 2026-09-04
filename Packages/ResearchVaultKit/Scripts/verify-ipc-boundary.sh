#!/bin/sh
set -eu

package_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$package_root"

for source_root in Sources/ResearchVaultIPCModel; do
    if rg -n \
        'import ResearchVault(SQLCipher|Gateway|Keychain|Ingestion|Store|MCP)' \
        "$source_root"; then
        echo "IPC model imports a privileged Research Vault module" >&2
        exit 1
    fi
done

if rg -n \
    'func (import|backup|restore)|database(URL|Path)|masterKey' \
    Sources/ResearchVaultIPCModel; then
    echo "IPC request surface contains an owner capability or grant" >&2
    exit 1
fi

if rg -n \
    'import ResearchVault(SQLCipher|Gateway|Keychain|Ingestion|Store|MCP)' \
    /Users/kevinnadjarian/GitHub/CheatCode/CheatCodeSpikes/Package.swift \
    /Users/kevinnadjarian/GitHub/CheatCode/CheatCodeSpikes/Sources 2>/dev/null; then
    echo "CheatCode directly imports a privileged Research Vault module" >&2
    exit 1
fi

echo '{"status":"pass","scenario":"ipc-boundary-no-privileged-client-dependency"}'
