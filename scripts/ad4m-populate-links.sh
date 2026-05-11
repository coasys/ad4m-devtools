#!/usr/bin/env bash
# ad4m-populate-links.sh — Populate a running executor with Flux-compliant mock data.
#
# Generates SHACL-compliant Community/Channel/Message links and imports them
# into a new perspective on a running AD4M executor, authenticated as the
# test user so the community appears in Flux.
#
# Usage:
#   ad4m-populate-links.sh [options]
#
# Options:
#   --channels N       Number of channels (default: 2)
#   --messages N       Messages per channel (default: 10)
#   --name NAME        Community name (default: "Test Community")
#   --port PORT        Executor port (default: 12000)
#   --auth CRED        Admin credential (default: test123)
#   --email EMAIL      Test user email (default: dev@test.com)
#   --password PASS    Test user password (default: test123)
#   --no-schema        Skip SHACL schema (use if perspective already has schema)
#   --help             Show this help
#
# Examples:
#   ad4m-populate-links.sh
#   ad4m-populate-links.sh --channels 5 --messages 50
#   ad4m-populate-links.sh --channels 1 --messages 1000 --name "Load Test"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo -e "\033[1;36m→ $1\033[0m"; }
err() { echo -e "\033[1;31m✗ $1\033[0m" >&2; exit 1; }
ok()  { echo -e "\033[1;32m✓ $1\033[0m"; }

# --- Defaults ---
CHANNELS=2
MESSAGES=10
NAME="Test Community"
PORT=12000
AUTH="test123"
EMAIL="dev@test.com"
PASSWORD="test123"
INCLUDE_SCHEMA=true

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --channels)   CHANNELS="$2"; shift 2;;
        --messages)   MESSAGES="$2"; shift 2;;
        --name)       NAME="$2"; shift 2;;
        --port)       PORT="$2"; shift 2;;
        --auth)       AUTH="$2"; shift 2;;
        --email)      EMAIL="$2"; shift 2;;
        --password)   PASSWORD="$2"; shift 2;;
        --no-schema)  INCLUDE_SCHEMA=false; shift;;
        --help|-h)
            sed -n '2,/^$/s/^# \?//p' "$0"
            exit 0;;
        *) err "Unknown option: $1";;
    esac
done

WS_URL="ws://127.0.0.1:${PORT}/api/v1/ws"
WS_RPC="$SCRIPT_DIR/ad4m-ws-rpc.py"

# --- Validate ---
[[ -f "$SCRIPT_DIR/generate-mock-seed.py" ]] || err "generate-mock-seed.py not found in $SCRIPT_DIR"
[[ -f "$SCRIPT_DIR/ad4m-perspective-tool.py" ]] || err "ad4m-perspective-tool.py not found in $SCRIPT_DIR"
[[ -f "$WS_RPC" ]] || err "ad4m-ws-rpc.py not found in $SCRIPT_DIR"
command -v python3 >/dev/null || err "python3 not found"

# Check executor is running
if ! curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    err "Executor not reachable on port $PORT — is it running?"
fi

# --- Login as test user ---
log "Logging in as $EMAIL..."
USER_JWT=$(python3 "$WS_RPC" --url "$WS_URL" --token "$AUTH" \
    "user.login" "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" 2>/dev/null \
    | python3 -c "import sys,json; r=json.load(sys.stdin); print(r if isinstance(r,str) else '')" 2>/dev/null) || USER_JWT=""
USER_JWT=$(echo "$USER_JWT" | sed 's/^"//;s/"$//')
[[ -n "$USER_JWT" ]] || err "Login failed for $EMAIL — is the user created? Run ad4m-flux-launch.sh first."
ok "Authenticated (JWT ${#USER_JWT} chars)"

# --- Calculate link count ---
# Schema: ~142 links (fixed), Data: community(3) + channels*(6 + apps*6 + messages*3)
SCHEMA_COUNT=0
$INCLUDE_SCHEMA && SCHEMA_COUNT=142
DATA_COUNT=$((3 + CHANNELS * (6 + 6 + MESSAGES * 3)))
TOTAL=$((SCHEMA_COUNT + DATA_COUNT))

log "Generating $TOTAL links ($CHANNELS channels × $MESSAGES messages)..."

# --- Generate and import ---
TMPFILE=$(mktemp /tmp/ad4m-populate-XXXXXX.json)
trap 'rm -f "$TMPFILE"' EXIT

if $INCLUDE_SCHEMA; then
    python3 "$SCRIPT_DIR/generate-mock-seed.py" \
        --name "$NAME" \
        --channels "$CHANNELS" \
        --messages "$MESSAGES" \
        --output "$TMPFILE"
else
    # Generate data-only seed (no schema links)
    python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR')
from datetime import datetime, timezone
import json, uuid
import importlib.util

spec = importlib.util.spec_from_file_location('seed', '$SCRIPT_DIR/generate-mock-seed.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

base_ts = datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc)
links = mod.generate_data('$NAME', $CHANNELS, $MESSAGES, base_ts)
seed = {'uuid': str(uuid.uuid4()), 'name': '$NAME', 'sharedUrl': None, 'state': None, 'neighbourhood': None, 'links': links}
with open('$TMPFILE', 'w') as f:
    json.dump(seed, f, indent=2)
print(f'Generated {len(links)} data links (no schema)', file=sys.stderr)
"
fi

log "Importing into executor as $EMAIL..."
PERSPECTIVE_UUID=$(python3 "$SCRIPT_DIR/ad4m-perspective-tool.py" \
    --url "$WS_URL" --auth "$USER_JWT" \
    import "$TMPFILE" --name "$NAME")

echo ""
ok "Done! Perspective: $PERSPECTIVE_UUID"
ok "Links: $TOTAL ($CHANNELS channels × $MESSAGES messages/channel)"
