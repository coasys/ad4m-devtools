#!/usr/bin/env bash
# ad4m-flux-launch.sh - Launch AD4M executor + Flux for local testing
#
# Starts the executor in multi-user mode, initialises the agent, creates
# a test user, optionally seeds a perspective snapshot, and serves Flux.
#
# Usage:
#   ad4m-flux-launch.sh [options]
#
# Options:
#   --executor PATH        Path to ad4m-executor binary (auto-detected from --ad4m)
#   --ad4m DIR             AD4M repo root (for finding executor binary)
#   --flux DIR             Flux repo root (serves app/dist via vite preview)
#   --dev                  Run Flux in dev mode (vite dev with HMR + full sourcemaps)
#   --data-path DIR        Executor data path (default: /tmp/ad4m-devtools)
#   --port PORT             Executor port (default: 12000)
#   --credential CRED      Admin credential (default: test123)
#   --passphrase PASS      Agent passphrase (default: test)
#   --seed FILE            JSON snapshot file to import as a perspective
#   --seed-name NAME       Override perspective name when seeding
#   --flux-port PORT       Flux preview port (default: 3030)
#   --user EMAIL           Test user email (default: dev@test.com)
#   --password PASS        Test user password (default: test123)
#   --no-multi-user        Disable multi-user mode
#   --generate-seed        Generate mock Flux seed data (community + channels + messages)
#   --channels N           Number of channels for --generate-seed (default: 2)
#   --messages N           Messages per channel for --generate-seed (default: 5)
#   --no-seed              Skip perspective seeding even if --seed is set
#   --no-flux              Don't serve Flux
#   --no-tmux              Run executor in background instead of tmux
#   --fresh                Delete data path before starting (fresh state)
#   --headless-auth        Auto-run browser-auth script after launch
#   --help                 Show this help
#
# Examples:
#   ad4m-flux-launch.sh --ad4m ./ad4m --flux ./flux --generate-seed --fresh
#   ad4m-flux-launch.sh --ad4m ./ad4m --flux ./flux --seed snapshot.json --fresh
#   ad4m-flux-launch.sh --executor ./ad4m/target/release/ad4m-executor --flux ./flux
#   ad4m-flux-launch.sh --fresh --no-flux

set -euo pipefail

log() { echo -e "\033[1;36m→ $1\033[0m"; }
err() { echo -e "\033[1;31m✗ $1\033[0m" >&2; exit 1; }
ok()  { echo -e "\033[1;32m✓ $1\033[0m"; }
warn() { echo -e "\033[1;33m⚠ $1\033[0m" >&2; }

# --- Defaults ---
DEFAULT_AD4M="./ad4m"
DEFAULT_FLUX="./flux"

EXECUTOR_BIN=""
AD4M_DIR=""
FLUX_DIR=""

# Auto-detect workspace repos
[[ -d "$DEFAULT_AD4M" ]] && AD4M_DIR="$DEFAULT_AD4M"
[[ -d "$DEFAULT_FLUX/app" ]] && FLUX_DIR="$DEFAULT_FLUX"
DATA_PATH="/tmp/ad4m-devtools"
PORT=12000
CREDENTIAL="test123"
PASSPHRASE="test"
SEED_FILE=""
SEED_NAME=""
GENERATE_SEED=false
SEED_CHANNELS=""
SEED_MESSAGES=""
FLUX_PORT=3030
MULTI_USER=true
DO_SEED=true
DO_FLUX=true
USE_TMUX=true
FRESH=false
HEADLESS_AUTH=false
FLUX_DEV_MODE=false
TEST_USER_EMAIL="dev@test.com"
TEST_USER_PASSWORD="test123"

while [[ $# -gt 0 ]]; do
    case $1 in
        --executor) [[ $# -ge 2 ]] || err "--executor requires a path"; EXECUTOR_BIN="$2"; shift 2;;
        --ad4m) [[ $# -ge 2 ]] || err "--ad4m requires a directory"; AD4M_DIR="$2"; shift 2;;
        --flux) [[ $# -ge 2 ]] || err "--flux requires a directory"; FLUX_DIR="$2"; shift 2;;
        --data-path) [[ $# -ge 2 ]] || err "--data-path requires a directory"; DATA_PATH="$2"; shift 2;;
        --port) [[ $# -ge 2 ]] || err "--port requires a port"; PORT="$2"; shift 2;;
        --credential) [[ $# -ge 2 ]] || err "--credential requires a value"; CREDENTIAL="$2"; shift 2;;
        --passphrase) [[ $# -ge 2 ]] || err "--passphrase requires a value"; PASSPHRASE="$2"; shift 2;;
        --seed) [[ $# -ge 2 ]] || err "--seed requires a file path"; SEED_FILE="$2"; shift 2;;
        --seed-name) [[ $# -ge 2 ]] || err "--seed-name requires a name"; SEED_NAME="$2"; shift 2;;
        --generate-seed) GENERATE_SEED=true; shift;;
        --channels) [[ $# -ge 2 ]] || err "--channels requires a number"; SEED_CHANNELS="$2"; shift 2;;
        --messages) [[ $# -ge 2 ]] || err "--messages requires a number"; SEED_MESSAGES="$2"; shift 2;;
        --flux-port) [[ $# -ge 2 ]] || err "--flux-port requires a port"; FLUX_PORT="$2"; shift 2;;
        --user) [[ $# -ge 2 ]] || err "--user requires an email"; TEST_USER_EMAIL="$2"; shift 2;;
        --password) [[ $# -ge 2 ]] || err "--password requires a value"; TEST_USER_PASSWORD="$2"; shift 2;;
        --no-multi-user) MULTI_USER=false; shift;;
        --no-seed) DO_SEED=false; shift;;
        --no-flux) DO_FLUX=false; shift;;
        --no-tmux) USE_TMUX=false; shift;;
        --fresh) FRESH=true; shift;;
        --dev) FLUX_DEV_MODE=true; shift;;
        --headless-auth) HEADLESS_AUTH=true; shift;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'; exit 0;;
        *) err "Unknown option: $1";;
    esac
done

# --- Find executor binary ---
if [[ -z "$EXECUTOR_BIN" ]]; then
    if [[ -n "$AD4M_DIR" && -x "$AD4M_DIR/target/release/ad4m-executor" ]]; then
        EXECUTOR_BIN="$AD4M_DIR/target/release/ad4m-executor"
    elif [[ -x "$DEFAULT_AD4M/target/release/ad4m-executor" ]]; then
        EXECUTOR_BIN="$DEFAULT_AD4M/target/release/ad4m-executor"
    else
        err "Cannot find ad4m-executor. Pass --executor PATH or --ad4m DIR"
    fi
fi
[[ -x "$EXECUTOR_BIN" ]] || err "Executor not executable: $EXECUTOR_BIN"

WS_URL="ws://127.0.0.1:${PORT}/api/v1/ws"
HEALTH_URL="http://127.0.0.1:${PORT}/health"
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_RPC="$TOOL_DIR/ad4m-ws-rpc.py"

# --- Helper: WebSocket RPC call ---
# Usage: ws_rpc TOKEN OPERATION [JSON_PARAMS]
ws_rpc() {
    python3 "$WS_RPC" --url "$WS_URL" --token "${1}" "${2}" ${3:+"$3"}
}

# --- Helper: Wait for API (health endpoint) ---
wait_for_api() {
    local elapsed=0
    while [[ $elapsed -lt 30 ]]; do
        if curl -sf "$HEALTH_URL" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

# ==========================================================================
# 1. Kill any running executor / Flux preview
# ==========================================================================
log "Stopping running processes..."
pkill -9 -f ad4m-executor 2>/dev/null || true
pkill -f "vite.*preview.*${FLUX_PORT}" 2>/dev/null || true
pkill -f "vite.*--port.*${FLUX_PORT}" 2>/dev/null || true
lsof -ti:"$FLUX_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
sleep 2

# ==========================================================================
# 2. Fresh start if requested
# ==========================================================================
if $FRESH; then
    log "Removing data path: $DATA_PATH"
    rm -rf "$DATA_PATH"
fi

# ==========================================================================
# 3. Initialise data path
# ==========================================================================
log "Initialising AD4M data..."
"$EXECUTOR_BIN" init --data-path "$DATA_PATH" 2>&1 | grep -v '^$'

# ==========================================================================
# 4. Start executor
# ==========================================================================
EXEC_ARGS=(
    run
    --admin-credential "$CREDENTIAL"
    --app-data-path "$DATA_PATH"
    --port "$PORT"
)
$MULTI_USER && EXEC_ARGS+=(--enable-multi-user true)

EXEC_CMD="RUST_LOG=info $EXECUTOR_BIN ${EXEC_ARGS[*]}"

if $USE_TMUX; then
    command -v tmux &>/dev/null || err "tmux required (use --no-tmux to run in background)"
    tmux kill-session -t ad4m 2>/dev/null || true
    log "Starting executor in tmux session 'ad4m'..."
    tmux new-session -d -s ad4m "$EXEC_CMD 2>&1 | tee /tmp/ad4m-executor.log"
    ok "Executor running - tmux attach -t ad4m"
else
    log "Starting executor in background..."
    eval "$EXEC_CMD" > /tmp/ad4m-executor.log 2>&1 &
    EXEC_PID=$!
    ok "Executor running (PID $EXEC_PID) - logs: /tmp/ad4m-executor.log"
fi

# ==========================================================================
# 5. Wait for API
# ==========================================================================
log "Waiting for API..."
if ! wait_for_api; then
    err "API did not come up within 30s. Check logs: /tmp/ad4m-executor.log"
fi
ok "API ready on port $PORT (WebSocket RPC)"

# ==========================================================================
# 6. Initialise agent
# ==========================================================================
AGENT_STATUS=$(ws_rpc "$CREDENTIAL" "agent.status")
IS_INIT=$(echo "$AGENT_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('isInitialized', False))" 2>/dev/null) || IS_INIT="False"
IS_UNLOCKED=$(echo "$AGENT_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('isUnlocked', False))" 2>/dev/null) || IS_UNLOCKED="False"

if [[ "$IS_INIT" != "True" ]]; then
    log "Generating agent..."
    AGENT_RESULT=$(ws_rpc "$CREDENTIAL" "agent.generate" "{\"passphrase\":\"$PASSPHRASE\"}")
    DID=$(echo "$AGENT_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('did','unknown'))" 2>/dev/null) || DID="unknown"
    ok "Agent generated: $DID"
elif [[ "$IS_UNLOCKED" != "True" ]]; then
    log "Unlocking agent..."
    ws_rpc "$CREDENTIAL" "agent.unlock" "{\"passphrase\":\"$PASSPHRASE\"}" >/dev/null
    ok "Agent unlocked"
else
    ok "Agent already initialised and unlocked"
fi

# ==========================================================================
# 7. Create test user + get JWT (multi-user mode)
# ==========================================================================
USER_JWT=""
USER_DID=""
if $MULTI_USER && [[ -n "$TEST_USER_EMAIL" ]]; then
    log "Creating test user: $TEST_USER_EMAIL"
    CREATE_RESULT=$(ws_rpc "$CREDENTIAL" "user.create" "{\"email\":\"$TEST_USER_EMAIL\",\"password\":\"$TEST_USER_PASSWORD\"}") || CREATE_RESULT=""
    CREATE_SUCCESS=$(echo "$CREATE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null) || CREATE_SUCCESS="False"
    CREATE_ERROR=$(echo "$CREATE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',''))" 2>/dev/null) || CREATE_ERROR=""

    if [[ "$CREATE_SUCCESS" == "True" ]]; then
        ok "Test user created"
    else
        warn "User creation: $CREATE_ERROR (may already exist)"
    fi

    # Enable free access for test user (bypasses compute credit checks)
    ws_rpc "$CREDENTIAL" "user.freeAccess" "{\"email\":\"$TEST_USER_EMAIL\",\"enabled\":true}" >/dev/null 2>&1
    ok "Free access enabled for $TEST_USER_EMAIL"

    # Login to get JWT
    log "Logging in as $TEST_USER_EMAIL..."
    LOGIN_RESULT=$(ws_rpc "$CREDENTIAL" "user.login" "{\"email\":\"$TEST_USER_EMAIL\",\"password\":\"$TEST_USER_PASSWORD\"}") || LOGIN_RESULT=""
    # user.login returns a JSON string (the JWT)
    USER_JWT=$(echo "$LOGIN_RESULT" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r if isinstance(r,str) else '')" 2>/dev/null) || USER_JWT=""
    # Strip surrounding quotes if any
    USER_JWT=$(echo "$USER_JWT" | sed 's/^"//;s/"$//')

    if [[ -n "$USER_JWT" && "$USER_JWT" != "null" && "$USER_JWT" != "" ]]; then
        ok "Login successful (JWT ${#USER_JWT} chars)"
        echo "$USER_JWT" > "$DATA_PATH/.user-jwt"
        echo "$TEST_USER_EMAIL" > "$DATA_PATH/.user-email"

        # Get user's DID
        DID_RESULT=$(ws_rpc "$USER_JWT" "agent.get")
        USER_DID=$(echo "$DID_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('did',''))" 2>/dev/null) || USER_DID=""
        [[ -n "$USER_DID" && "$USER_DID" != "null" ]] && ok "User DID: $USER_DID"
    else
        warn "Login failed: $LOGIN_RESULT"
    fi
fi

# ==========================================================================
# 8. Generate mock seed if requested
# ==========================================================================
if $GENERATE_SEED && [[ -n "$SEED_FILE" ]]; then
    warn "--generate-seed ignored because --seed was also specified"
    GENERATE_SEED=false
fi
if $GENERATE_SEED; then
    TOOL_DIR="$(cd "$(dirname "$0")" && pwd)"
    MOCK_SEED="/tmp/ad4m-devtools-mock-seed.json"
    [[ -f "$TOOL_DIR/generate-mock-seed.py" ]] || err "generate-mock-seed.py not found in $TOOL_DIR"
    log "Generating mock seed data..."
    SEED_ARGS=(--output "$MOCK_SEED")
    [[ -n "$SEED_NAME" ]] && SEED_ARGS+=(--name "$SEED_NAME")
    [[ -n "$SEED_CHANNELS" ]] && SEED_ARGS+=(--channels "$SEED_CHANNELS")
    [[ -n "$SEED_MESSAGES" ]] && SEED_ARGS+=(--messages "$SEED_MESSAGES")
    python3 "$TOOL_DIR/generate-mock-seed.py" "${SEED_ARGS[@]}"
    SEED_FILE="$MOCK_SEED"
    ok "Mock seed generated: $MOCK_SEED"
fi

# ==========================================================================
# 9. Seed perspective (with user DID ownership)
#    Uses deferred batch API: createBatch → addLinks(batchId) → commitBatch
#    (single atomic persist, no per-link disk I/O or pubsub until commit)
# ==========================================================================
if $DO_SEED && [[ -n "$SEED_FILE" ]]; then
    [[ -f "$SEED_FILE" ]] || err "Seed file not found: $SEED_FILE"
    python3 -c "import json; json.load(open('$SEED_FILE'))" 2>/dev/null || err "Invalid JSON: $SEED_FILE"

    ALREADY_EXISTS=false

    # Skip idempotency check when --fresh (we just wiped all data)
    if ! $FRESH; then
        SEED_NAME_CHECK="${SEED_NAME}"
        [[ -z "$SEED_NAME_CHECK" ]] && SEED_NAME_CHECK=$(python3 -c "import json; print(json.load(open('$SEED_FILE')).get('name',''))" 2>/dev/null)

        if [[ -n "$SEED_NAME_CHECK" ]]; then
            CHECK_AUTH="${USER_JWT:-$CREDENTIAL}"
            EXISTS=$(ws_rpc "$CHECK_AUTH" "perspective.all" | python3 -c "
import sys, json
perspectives = json.load(sys.stdin)
if isinstance(perspectives, list):
    names = [p.get('name','') for p in perspectives]
    print('$SEED_NAME_CHECK' in names)
else:
    print(False)
" 2>/dev/null) || EXISTS="False"
            [[ "$EXISTS" == "True" ]] && ALREADY_EXISTS=true
        fi
    fi

    if $ALREADY_EXISTS; then
        ok "Perspective '$SEED_NAME_CHECK' already imported -- skipping"
    else
        SEED_AUTH="${USER_JWT:-$CREDENTIAL}"
        SEED_NAME_ARG=""
        [[ -n "$SEED_NAME" ]] && SEED_NAME_ARG="--name $SEED_NAME"

        [[ -f "$TOOL_DIR/ad4m-perspective-tool.py" ]] || err "ad4m-perspective-tool.py not found in $TOOL_DIR"
        log "Importing perspective from $SEED_FILE via WS RPC (as ${TEST_USER_EMAIL:-admin})..."
        SEED_UUID_NEW=$(python3 "$TOOL_DIR/ad4m-perspective-tool.py" \
            --url "$WS_URL" --auth "$SEED_AUTH" \
            import "$SEED_FILE" $SEED_NAME_ARG) || err "Perspective import failed"
        ok "Perspective imported: $SEED_UUID_NEW"
    fi
fi

# ==========================================================================
# 10. Serve Flux
# ==========================================================================
if $DO_FLUX && [[ -n "$FLUX_DIR" ]]; then
    FLUX_DIR="$(cd "$FLUX_DIR" && pwd)"

    if $FLUX_DEV_MODE; then
        # Dev mode: vite dev server with HMR + unbundled ES modules (full sourcemaps in stack traces)
        if $USE_TMUX; then
            tmux kill-session -t flux 2>/dev/null || true
            log "Starting Flux dev server in tmux session 'flux'..."
            tmux new-session -d -s flux "cd $FLUX_DIR/app && npx vite --port $FLUX_PORT 2>&1"
            sleep 5
            ok "Flux dev server on http://localhost:$FLUX_PORT - tmux attach -t flux"
        else
            log "Starting Flux dev server in background..."
            cd "$FLUX_DIR/app"
            npx vite --port "$FLUX_PORT" > /tmp/flux-serve.log 2>&1 &
            FLUX_PID=$!
            sleep 5
            ok "Flux dev server on http://localhost:$FLUX_PORT (PID $FLUX_PID)"
        fi
    else
        # Preview mode: serves pre-built app/dist
        [[ -f "$FLUX_DIR/app/dist/index.html" ]] || err "Flux not built - run ad4m-flux-rebuild.sh first"

        if $USE_TMUX; then
            tmux kill-session -t flux 2>/dev/null || true
            log "Starting Flux in tmux session 'flux'..."
            tmux new-session -d -s flux "cd $FLUX_DIR/app && npx vite preview --port $FLUX_PORT 2>&1"
            sleep 3
            ok "Flux serving on http://localhost:$FLUX_PORT - tmux attach -t flux"
        else
            log "Starting Flux in background..."
            cd "$FLUX_DIR/app"
            npx vite preview --port "$FLUX_PORT" > /tmp/flux-serve.log 2>&1 &
            FLUX_PID=$!
            sleep 3
            ok "Flux serving on http://localhost:$FLUX_PORT (PID $FLUX_PID)"
        fi
    fi
fi

# ==========================================================================
# Summary
# ==========================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AD4M + Flux - Ready"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  API:        ws://127.0.0.1:$PORT/api/v1/ws (WebSocket RPC)"
echo "  Credential: $CREDENTIAL"
$MULTI_USER && echo "  Multi-user: enabled"
if $USE_TMUX; then
    echo "  Logs:       tmux attach -t ad4m"
else
    echo "  Logs:       /tmp/ad4m-executor.log"
fi
if $DO_FLUX && [[ -n "$FLUX_DIR" ]]; then
    echo "  Flux:       http://localhost:$FLUX_PORT"
fi
if [[ -n "$SEED_FILE" ]] && $DO_SEED; then
    echo "  Seeded:     $SEED_FILE"
fi
echo ""
echo "  Test User:  $TEST_USER_EMAIL / $TEST_USER_PASSWORD"
[[ -n "$USER_DID" ]] && echo "  DID:        $USER_DID"
echo ""
if ! $HEADLESS_AUTH; then
    echo "  Next step:  ad4m-flux-browser-auth.sh"
fi
echo ""

# ==========================================================================
# 11. Headless browser auth (if requested)
# ==========================================================================
if $HEADLESS_AUTH; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    AUTH_SCRIPT="$SCRIPT_DIR/ad4m-flux-browser-auth.sh"
    [[ -x "$AUTH_SCRIPT" ]] || err "Browser auth script not found: $AUTH_SCRIPT"

    AUTH_ARGS=(
        --executor-url "http://127.0.0.1:${PORT}"
        --flux-url "http://localhost:${FLUX_PORT}"
        --email "$TEST_USER_EMAIL"
        --password "$TEST_USER_PASSWORD"
    )
    [[ -n "$FLUX_DIR" ]] && AUTH_ARGS+=(--flux-dir "$FLUX_DIR")

    log "Running headless browser auth..."
    "$AUTH_SCRIPT" "${AUTH_ARGS[@]}"
fi
