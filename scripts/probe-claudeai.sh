#!/usr/bin/env bash
#
# Probe claude.ai's private API for endpoints that return usage data.
#
# This script is safe to run locally:
#   - The sessionKey cookie is read from your environment, never echoed.
#   - Response bodies are truncated to 800 chars in the printed report.
#   - Anything that looks like a UUID, email, name, or token is redacted.
#
# Usage:
#   1. Open https://claude.ai in your browser, log in.
#   2. DevTools → Application → Cookies → claude.ai → copy the value of `sessionKey`.
#   3. Run:
#        SESSION_KEY="<paste here>" bash scripts/probe-claudeai.sh > probe-report.txt
#   4. Send probe-report.txt back. Do NOT paste your sessionKey into chat.
#
set -euo pipefail

if [[ -z "${SESSION_KEY:-}" ]]; then
  echo "ERROR: SESSION_KEY env var not set." >&2
  echo "Usage: SESSION_KEY=<cookie> bash scripts/probe-claudeai.sh > probe-report.txt" >&2
  exit 1
fi

UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Redact UUIDs, JWTs, emails, plausible names, long hex strings.
redact() {
  sed -E \
    -e 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<UUID>/g' \
    -e 's/eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/<JWT>/g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<EMAIL>/g' \
    -e 's/"full_name"[[:space:]]*:[[:space:]]*"[^"]*"/"full_name":"<REDACTED>"/g' \
    -e 's/"display_name"[[:space:]]*:[[:space:]]*"[^"]*"/"display_name":"<REDACTED>"/g' \
    -e 's/"name"[[:space:]]*:[[:space:]]*"[A-Za-z][^"]{0,80}"/"name":"<REDACTED>"/g' \
    -e 's/[0-9a-f]{40,}/<HEXBLOB>/g'
}

probe() {
  local label="$1"
  local url="$2"
  local headers_file="$TMPDIR/headers"
  local body_file="$TMPDIR/body"

  echo "================================================================"
  echo "PROBE: $label"
  echo "URL:   $url"

  local status
  status=$(curl -sS -o "$body_file" -D "$headers_file" \
    -w "%{http_code}" \
    -H "Cookie: sessionKey=${SESSION_KEY}" \
    -H "Accept: application/json" \
    -H "User-Agent: $UA" \
    -H "anthropic-client-platform: web_claude_ai" \
    "$url" || echo "000")

  local content_type
  content_type=$(grep -i '^content-type:' "$headers_file" | head -1 | tr -d '\r' || echo "")
  local content_length
  content_length=$(wc -c < "$body_file" | tr -d ' ')

  echo "Status:        $status"
  echo "Content-Type:  $content_type"
  echo "Body bytes:    $content_length"

  echo "Body (first 800 bytes, redacted):"
  echo "----"
  head -c 800 "$body_file" | redact
  echo ""
  echo "----"
  echo ""
}

echo "claude.ai endpoint probe — $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo "Cookie length: ${#SESSION_KEY}"
echo ""

# Step 1: discover the user's org id (every other call needs it).
probe "account_get" "https://claude.ai/api/account"
probe "auth_current_account" "https://claude.ai/api/auth/current_account"
probe "organizations_list" "https://claude.ai/api/organizations"
probe "bootstrap" "https://claude.ai/api/bootstrap"

echo ""
echo "================================================================"
echo "If one of the above returned an org_id, paste it as ORG_ID env var"
echo "and re-run with the org-scoped probe block uncommented below, OR"
echo "send this report back so I can extract the org_id and craft round 2."
echo "================================================================"

# Step 2 (best-effort with auto-extracted org id from organizations list):
ORG_ID=""
if [[ -z "${ORG_ID_OVERRIDE:-}" ]]; then
  ORG_ID=$(curl -sS \
    -H "Cookie: sessionKey=${SESSION_KEY}" \
    -H "Accept: application/json" \
    -H "User-Agent: $UA" \
    "https://claude.ai/api/organizations" 2>/dev/null \
    | python3 -c "
import json,sys
try:
    data = json.load(sys.stdin)
    if isinstance(data, list) and data:
        print(data[0].get('uuid') or data[0].get('id') or '')
    elif isinstance(data, dict):
        print(data.get('uuid') or data.get('id') or '')
except Exception:
    pass
" 2>/dev/null || echo "")
else
  ORG_ID="$ORG_ID_OVERRIDE"
fi

if [[ -n "$ORG_ID" ]]; then
  echo ""
  echo "Detected ORG_ID (will be redacted in report)."
  echo ""

  probe "org_root"          "https://claude.ai/api/organizations/${ORG_ID}"
  probe "org_usage"         "https://claude.ai/api/organizations/${ORG_ID}/usage"
  probe "org_usage_data"    "https://claude.ai/api/organizations/${ORG_ID}/usage_data"
  probe "org_limits"        "https://claude.ai/api/organizations/${ORG_ID}/limits"
  probe "org_quota"         "https://claude.ai/api/organizations/${ORG_ID}/quota"
  probe "org_billing"       "https://claude.ai/api/organizations/${ORG_ID}/billing"
  probe "org_subscription"  "https://claude.ai/api/organizations/${ORG_ID}/subscription"
  probe "org_capabilities"  "https://claude.ai/api/organizations/${ORG_ID}/capabilities"
  probe "org_settings"      "https://claude.ai/api/organizations/${ORG_ID}/settings"
  probe "org_rate_limits"   "https://claude.ai/api/organizations/${ORG_ID}/rate_limits"
  probe "org_rate_limit_status" "https://claude.ai/api/organizations/${ORG_ID}/rate_limit_status"

  # Some plans expose usage under /api/users/...
  probe "user_usage"        "https://claude.ai/api/user/usage"
  probe "user_limits"       "https://claude.ai/api/user/limits"
  probe "users_me_usage"    "https://claude.ai/api/users/me/usage"
fi

echo ""
echo "Done. Send probe-report.txt back."
