#!/bin/sh
set -eu

swift build -c debug --product research-vault-agent-hook
product_directory="$(swift build -c debug --show-bin-path)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/research-vault-agent-hook.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/inbox"

request="$fixture/request.json"
printf '%s\n' '{"hook_event_name":"SubagentStop","session_id":"smoke-session","agent_id":"child","parent_agent_id":"parent","project_key":"throttle","occurred_at_ms":1787832500000}' > "$request"

first="$fixture/first.json"
second="$fixture/second.json"
errors="$fixture/stderr.log"
"$product_directory/research-vault-agent-hook" --inbox "$fixture/inbox" < "$request" > "$first" 2> "$errors"
"$product_directory/research-vault-agent-hook" --inbox "$fixture/inbox" < "$request" > "$second" 2>> "$errors"

test ! -s "$errors"
test "$(find "$fixture/inbox" -type f -name '*.research-receipt.json' | wc -l | tr -d ' ')" = "1"
jq -e '.status == "candidate_written" and (.receiptID | length) == 36' "$first" >/dev/null
jq -e '.status == "already_present" and (.receiptID | length) == 36' "$second" >/dev/null
test "$(jq -r .receiptID "$first")" = "$(jq -r .receiptID "$second")"

jq -cn '{status:"pass",scenario:"agent-hook-restart-idempotence"}'
