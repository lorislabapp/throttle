#!/bin/sh
set -eu

deepsearsh_root="${RESEARCH_VAULT_DEEPSEARSH_ROOT:-/Users/kevinnadjarian/GitHub/DeepSearsh}"
test -r "$deepsearsh_root/catalog.jsonl"

swift build -c debug --product research-vault-mcp
product_directory="$(swift build -c debug --show-bin-path)"
mkdir -p "$product_directory/PackageFrameworks"
ditto "$product_directory/SQLCipher.framework" \
    "$product_directory/PackageFrameworks/SQLCipher.framework"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/research-vault-mcp-process.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/inbox"

requests="$fixture/requests.jsonl"
responses="$fixture/responses.jsonl"
errors="$fixture/stderr.log"
printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    '{"jsonrpc":"2.0","id":3,"method":"server/discover"}' \
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"research_vault_health","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}' \
    '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"research_vault_search","arguments":{"query":"Research Vault CheatCode","limit":3}}}' \
    '{"jsonrpc":"2.0","id":6,"method":"resources/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}' \
    > "$requests"

"$product_directory/research-vault-mcp" \
    --ephemeral-testing-key \
    --database "$fixture/vault.ccsql" \
    --inbox "$fixture/inbox" \
    --deepsearsh "$deepsearsh_root" \
    --project throttle \
    < "$requests" > "$responses" 2> "$errors"

test "$(wc -l < "$responses" | tr -d ' ')" = "6"
test ! -s "$errors"
jq -e 'select(.id == 1) | .result.serverInfo.name == "research-vault"' "$responses" >/dev/null
jq -e 'select(.id == 2) | [.result.tools[].name] == ["research_vault_search", "research_vault_health", "research_vault_submit_receipt", "research_vault_why", "research_vault_what_changed"]' "$responses" >/dev/null
jq -e 'select(.id == 3) | .result.supportedVersions == ["2026-07-28", "2024-11-05"] and .result.capabilities.resources.listChanged == false' "$responses" >/dev/null
jq -er 'select(.id == 4) | .result.content[0].text | fromjson | .documentCount >= 41 and .chunkCount >= 460' "$responses" >/dev/null
jq -er 'select(.id == 5) | .result.content[0].text | fromjson | .items[0].citation.title == "Throttle Research Vault × CheatCode — dossier de décision FULL SOTA" and .items[0].citation.schemaVersion == 2 and (.items[0].citation.excerptSHA256 | length) == 64' "$responses" >/dev/null
jq -e 'select(.id == 6) | (.result.resources | type) == "array"' "$responses" >/dev/null

document_count="$(jq -er 'select(.id == 4) | .result.content[0].text | fromjson | .documentCount' "$responses")"
chunk_count="$(jq -er 'select(.id == 4) | .result.content[0].text | fromjson | .chunkCount' "$responses")"
jq -cn \
    --argjson documents "$document_count" \
    --argjson chunks "$chunk_count" \
    '{status:"pass",scenario:"mcp-process",documents:$documents,chunks:$chunks}'
