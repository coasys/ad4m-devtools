#!/usr/bin/env bash
# ad4m-we-launch.sh - Launch AD4M executor + WE for local testing
#
# Starts the executor in multi-user mode, initialises the agent, creates
# a test user, builds/serves WE web app, and optionally runs headless auth.
#
# Usage:
#   ad4m-we-launch.sh [options]
#
# Options:
#   --executor PATH        Path to ad4m-executor binary (auto-detected from --ad4m)
#   --ad4m DIR             AD4M repo root (for finding executor binary)
#   --we DIR               WE repo root (default: ./we)
#   --data-path DIR        Executor data path (default: /tmp/ad4m-devtools)
#   --gql-port PORT        GraphQL port (default: 12000)
#   --credential CRED      Admin credential (default: test123)
#   --passphrase PASS      Agent passphrase (default: test)
#   --we-port PORT         WE preview port (default: 3000)
#   --user EMAIL           Test user email (default: dev@test.com)
#   --password PASS        Test user password (default: test123)
#   --no-multi-user        Disable multi-user mode
#   --no-we                Don't serve WE
#   --no-tmux              Run executor in background instead of tmux
#   --fresh                Delete data path before starting (fresh state)
#   --headless-auth        Auto-run browser-auth script after launch
#   --dev                  Run WE in dev mode (vite dev) instead of build+preview
#   --help                 Show this help
#
# Examples:
#   ad4m-we-launch.sh --ad4m ./ad4m --we ./we --fresh
#   ad4m-we-launch.sh --ad4m ./ad4m --we ./we --fresh --headless-auth
#   ad4m-we-launch.sh --ad4m ./ad4m --we ./we --dev

set -euo pipefail

log() { echo -e "\033[1;36m→ $1\033[0m"; }
err() { echo -e "\033[1;31m✗ $1\033[0m" >&2; exit 1; }
ok()  { echo -e "\033[1;32m✓ $1\033[0m"; }
warn() { echo -e "\033[1;33m⚠ $1\033[0m" >&2; }

# --- Defaults ---
DEFAULT_AD4M="./ad4m"
DEFAULT_WE="./we"

EXECUTOR_BIN=""
AD4M_DIR=""
WE_DIR=""

[[ -d "$DEFAULT_AD4M" ]] && AD4M_DIR="$DEFAULT_AD4M"
[[ -d "$DEFAULT_WE/apps/we-web" ]] && WE_DIR="$DEFAULT_WE"
DATA_PATH="/tmp/ad4m-devtools"
GQL_PORT=12000
CREDENTIAL="test123"
PASSPHRASE="test"
WE_PORT=3000
MULTI_USER=true
DO_WE=true
USE_TMUX=true
FRESH=false
HEADLESS_AUTH=false
DEV_MODE=false
TEST_USER_EMAIL="dev@test.com"
TEST_USER_PASSWORD="test123"

while [[ $# -gt 0 ]]; do
    case $1 in
        --executor) [[ $# -ge 2 ]] || err "--executor requires a path"; EXECUTOR_BIN="$2"; shift 2;;
        --ad4m) [[ $# -ge 2 ]] || err "--ad4m requires a directory"; AD4M_DIR="$2"; shift 2;;
        --we) [[ $# -ge 2 ]] || err "--we requires a directory"; WE_DIR="$2"; shift 2;;
        --data-path) [[ $# -ge 2 ]] || err "--data-path requires a directory"; DATA_PATH="$2"; shift 2;;
        --gql-port) [[ $# -ge 2 ]] || err "--gql-port requires a port"; GQL_PORT="$2"; shift 2;;
        --credential) [[ $# -ge 2 ]] || err "--credential requires a value"; CREDENTIAL="$2"; shift 2;;
        --passphrase) [[ $# -ge 2 ]] || err "--passphrase requires a value"; PASSPHRASE="$2"; shift 2;;
        --we-port) [[ $# -ge 2 ]] || err "--we-port requires a port"; WE_PORT="$2"; shift 2;;
        --user) [[ $# -ge 2 ]] || err "--user requires an email"; TEST_USER_EMAIL="$2"; shift 2;;
        --password) [[ $# -ge 2 ]] || err "--password requires a value"; TEST_USER_PASSWORD="$2"; shift 2;;
        --no-multi-user) MULTI_USER=false; shift;;
        --no-we) DO_WE=false; shift;;
        --no-tmux) USE_TMUX=false; shift;;
        --fresh) FRESH=true; shift;;
        --headless-auth) HEADLESS_AUTH=true; shift;;
        --dev) DEV_MODE=true; shift;;
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

GQL_URL="http://127.0.0.1:${GQL_PORT}/graphql"
REST_URL="http://127.0.0.1:${GQL_PORT}/api/v1"

# --- Helper: GraphQL query ---
gql() {
    curl -sf -X POST "$GQL_URL" \
        -H "Content-Type: application/json" \
        -H "authorization: ${1}" \
        -d "$2" 2>&1
}

# --- Helper: REST GET ---
rest_get() {
    curl -sf -X GET "${REST_URL}${2}" \
        -H "Content-Type: application/json" \
        -H "authorization: ${1}" 2>&1
}

# --- Helper: REST POST ---
rest_post() {
    curl -sf -X POST "${REST_URL}${2}" \
        -H "Content-Type: application/json" \
        -H "authorization: ${1}" \
        -d "${3:-{}}" 2>&1
}

# --- Helper: Wait for API and detect REST vs GraphQL ---
USE_REST=false
wait_for_api() {
    local elapsed=0
    while [[ $elapsed -lt 30 ]]; do
        if curl -sf "${REST_URL}/agent/status" \
            -H "authorization: $CREDENTIAL" >/dev/null 2>&1; then
            USE_REST=true
            return 0
        fi
        if curl -sf "$GQL_URL" \
            -H "Content-Type: application/json" \
            -H "authorization: $CREDENTIAL" \
            -d '{"query":"{ agentStatus { isInitialized } }"}' >/dev/null 2>&1; then
            USE_REST=false
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

# ==========================================================================
# 1. Kill any running executor / WE
# ==========================================================================
log "Stopping running processes..."
pkill -9 -f ad4m-executor 2>/dev/null || true
lsof -ti:"$WE_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
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
    --gql-port "$GQL_PORT"
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
# 5. Wait for API (auto-detect REST vs GraphQL)
# ==========================================================================
log "Waiting for API..."
if ! wait_for_api; then
    err "API did not come up within 30s. Check logs: /tmp/ad4m-executor.log"
fi
if $USE_REST; then
    ok "REST API ready on port $GQL_PORT"
else
    warn "REST not available — falling back to GraphQL on port $GQL_PORT"
fi

# ==========================================================================
# 6. Initialise agent
# ==========================================================================
if $USE_REST; then
    AGENT_STATUS=$(rest_get "$CREDENTIAL" "/agent/status")
    IS_INIT=$(echo "$AGENT_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('isInitialized', False))" 2>/dev/null) || IS_INIT="False"
    IS_UNLOCKED=$(echo "$AGENT_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('isUnlocked', False))" 2>/dev/null) || IS_UNLOCKED="False"

    if [[ "$IS_INIT" != "True" ]]; then
        log "Generating agent..."
        AGENT_RESULT=$(rest_post "$CREDENTIAL" "/agent/generate" "{\"passphrase\":\"$PASSPHRASE\"}")
        DID=$(echo "$AGENT_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('did','unknown'))" 2>/dev/null) || DID="unknown"
        ok "Agent generated: $DID"
    elif [[ "$IS_UNLOCKED" != "True" ]]; then
        log "Unlocking agent..."
        rest_post "$CREDENTIAL" "/agent/unlock" "{\"passphrase\":\"$PASSPHRASE\",\"holochain\":true}" >/dev/null
        ok "Agent unlocked"
    else
        ok "Agent already initialised and unlocked"
    fi
else
    AGENT_STATUS=$(gql "$CREDENTIAL" '{"query":"{ agentStatus { isInitialized isUnlocked } }"}')
    IS_INIT=$(echo "$AGENT_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['agentStatus']['isInitialized'])" 2>/dev/null) || IS_INIT="False"
    IS_UNLOCKED=$(echo "$AGENT_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['agentStatus']['isUnlocked'])" 2>/dev/null) || IS_UNLOCKED="False"

    if [[ "$IS_INIT" != "True" ]]; then
        log "Generating agent..."
        AGENT_RESULT=$(gql "$CREDENTIAL" "{\"query\":\"mutation { agentGenerate(passphrase: \\\"$PASSPHRASE\\\") { did isInitialized isUnlocked } }\"}")
        DID=$(echo "$AGENT_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['agentGenerate']['did'])" 2>/dev/null) || DID="unknown"
        ok "Agent generated: $DID"
    elif [[ "$IS_UNLOCKED" != "True" ]]; then
        log "Unlocking agent..."
        gql "$CREDENTIAL" "{\"query\":\"mutation { agentUnlock(passphrase: \\\"$PASSPHRASE\\\", holochain: true) { did isUnlocked } }\"}" >/dev/null
        ok "Agent unlocked"
    else
        ok "Agent already initialised and unlocked"
    fi
fi

# ==========================================================================
# 7. Create test user + get JWT (multi-user mode)
# ==========================================================================
USER_JWT=""
USER_DID=""
if $MULTI_USER && [[ -n "$TEST_USER_EMAIL" ]]; then
  if $USE_REST; then
    log "Creating test user: $TEST_USER_EMAIL (REST)"
    CREATE_RESULT=$(rest_post "$CREDENTIAL" "/users" "{\"email\":\"$TEST_USER_EMAIL\",\"password\":\"$TEST_USER_PASSWORD\"}") || CREATE_RESULT=""
    CREATE_SUCCESS=$(echo "$CREATE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null) || CREATE_SUCCESS="False"
    CREATE_ERROR=$(echo "$CREATE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error',''))" 2>/dev/null) || CREATE_ERROR=""

    if [[ "$CREATE_SUCCESS" == "True" ]]; then
        ok "Test user created"
    else
        warn "User creation: $CREATE_ERROR (may already exist)"
    fi

    rest_post "$CREDENTIAL" "/users/free-access" "{\"email\":\"$TEST_USER_EMAIL\",\"enabled\":true}" >/dev/null 2>&1
    ok "Free access enabled for $TEST_USER_EMAIL"

    log "Logging in as $TEST_USER_EMAIL..."
    LOGIN_RESULT=$(curl -sf -X POST "${REST_URL}/users/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$TEST_USER_EMAIL\",\"password\":\"$TEST_USER_PASSWORD\"}") || LOGIN_RESULT=""
    USER_JWT=$(echo "$LOGIN_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin))" 2>/dev/null) || USER_JWT="$LOGIN_RESULT"
    USER_JWT=$(echo "$USER_JWT" | sed 's/^"//;s/"$//')

    if [[ -n "$USER_JWT" && "$USER_JWT" != "null" && "$USER_JWT" != "" ]]; then
        ok "Login successful (JWT ${#USER_JWT} chars)"
        echo "$USER_JWT" > "$DATA_PATH/.user-jwt"
        echo "$TEST_USER_EMAIL" > "$DATA_PATH/.user-email"

        DID_RESULT=$(rest_get "$USER_JWT" "/agent")
        USER_DID=$(echo "$DID_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('did',''))" 2>/dev/null) || USER_DID=""
        [[ -n "$USER_DID" && "$USER_DID" != "null" ]] && ok "User DID: $USER_DID"
    else
        warn "Login failed: $LOGIN_RESULT"
    fi
  else
    log "Creating test user: $TEST_USER_EMAIL"
    CREATE_RESULT=$(gql "$CREDENTIAL" "{\"query\":\"mutation { runtimeCreateUser(email: \\\"$TEST_USER_EMAIL\\\", password: \\\"$TEST_USER_PASSWORD\\\") { did success error } }\"}")
    CREATE_SUCCESS=$(echo "$CREATE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['runtimeCreateUser']['success'])" 2>/dev/null) || CREATE_SUCCESS="False"
    CREATE_ERROR=$(echo "$CREATE_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['runtimeCreateUser'].get('error',''))" 2>/dev/null) || CREATE_ERROR=""

    if [[ "$CREATE_SUCCESS" == "True" ]]; then
        ok "Test user created"
    else
        warn "User creation: $CREATE_ERROR (may already exist)"
    fi

    log "Logging in as $TEST_USER_EMAIL..."
    LOGIN_RESULT=$(curl -sf -X POST "$GQL_URL" \
        -H "Content-Type: application/json" \
        -d "{\"query\":\"mutation { runtimeLoginUser(email: \\\"$TEST_USER_EMAIL\\\", password: \\\"$TEST_USER_PASSWORD\\\") }\"}")
    USER_JWT=$(echo "$LOGIN_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['runtimeLoginUser'])" 2>/dev/null) || USER_JWT=""

    if [[ -n "$USER_JWT" && "$USER_JWT" != "null" ]]; then
        ok "Login successful (JWT ${#USER_JWT} chars)"
        echo "$USER_JWT" > "$DATA_PATH/.user-jwt"
        echo "$TEST_USER_EMAIL" > "$DATA_PATH/.user-email"

        DID_RESULT=$(gql "$USER_JWT" '{"query":"{ agent { did } }"}')
        USER_DID=$(echo "$DID_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['agent']['did'])" 2>/dev/null) || USER_DID=""
        [[ -n "$USER_DID" && "$USER_DID" != "null" ]] && ok "User DID: $USER_DID"
    else
        warn "Login failed: $LOGIN_RESULT"
    fi
  fi
fi

# ==========================================================================
# 8. Serve WE
# ==========================================================================
if $DO_WE && [[ -n "$WE_DIR" ]]; then
    WE_DIR="$(cd "$WE_DIR" && pwd)"

    # Ensure WE packages are built (pnpm setup-workspace)
    if [[ ! -d "$WE_DIR/packages/models/dist" ]] || [[ ! -d "$WE_DIR/packages/utils/dist" ]]; then
        log "Running WE workspace setup (first time or missing builds)..."
        (cd "$WE_DIR" && pnpm setup-workspace) || err "WE setup-workspace failed"
        ok "WE workspace setup complete"
    fi

    if $DEV_MODE; then
        # Dev mode: run vite dev server
        if $USE_TMUX; then
            tmux kill-session -t we 2>/dev/null || true
            log "Starting WE dev server in tmux session 'we'..."
            tmux new-session -d -s we "cd $WE_DIR && pnpm --filter @we/app-web dev -- --port $WE_PORT 2>&1"
            sleep 5
            ok "WE dev server on http://localhost:$WE_PORT - tmux attach -t we"
        else
            log "Starting WE dev server in background..."
            cd "$WE_DIR"
            pnpm --filter @we/app-web dev -- --port "$WE_PORT" > /tmp/we-serve.log 2>&1 &
            WE_PID=$!
            sleep 5
            ok "WE dev server on http://localhost:$WE_PORT (PID $WE_PID)"
        fi
    else
        # Build + preview mode
        [[ -f "$WE_DIR/apps/we-web/dist/index.html" ]] || {
            log "Building WE web app..."
            (cd "$WE_DIR" && pnpm build:web) || err "WE build failed"
            ok "WE built"
        }

        if $USE_TMUX; then
            tmux kill-session -t we 2>/dev/null || true
            log "Starting WE in tmux session 'we'..."
            tmux new-session -d -s we "cd $WE_DIR/apps/we-web && npx vite preview --port $WE_PORT 2>&1"
            sleep 3
            ok "WE serving on http://localhost:$WE_PORT - tmux attach -t we"
        else
            log "Starting WE in background..."
            cd "$WE_DIR/apps/we-web"
            npx vite preview --port "$WE_PORT" > /tmp/we-serve.log 2>&1 &
            WE_PID=$!
            sleep 3
            ok "WE serving on http://localhost:$WE_PORT (PID $WE_PID)"
        fi
    fi
fi

# ==========================================================================
# Summary
# ==========================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AD4M + WE - Ready"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
if $USE_REST; then
    echo "  API:        ${REST_URL} (REST)"
else
    echo "  API:        http://127.0.0.1:$GQL_PORT/graphql (GraphQL fallback)"
fi
echo "  Credential: $CREDENTIAL"
$MULTI_USER && echo "  Multi-user: enabled"
if $USE_TMUX; then
    echo "  Logs:       tmux attach -t ad4m"
else
    echo "  Logs:       /tmp/ad4m-executor.log"
fi
if $DO_WE && [[ -n "$WE_DIR" ]]; then
    echo "  WE:         http://localhost:$WE_PORT"
fi
echo ""
echo "  Test User:  $TEST_USER_EMAIL / $TEST_USER_PASSWORD"
[[ -n "$USER_DID" ]] && echo "  DID:        $USER_DID"
echo ""
if ! $HEADLESS_AUTH; then
    echo "  Next step:  ad4m-connect-auth.sh --flux-url http://localhost:$WE_PORT --admin-credential $CREDENTIAL"
fi
echo ""

# ==========================================================================
# 9. Headless browser auth (if requested)
# ==========================================================================
if $HEADLESS_AUTH; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    AUTH_SCRIPT="$SCRIPT_DIR/ad4m-connect-auth.sh"
    [[ -x "$AUTH_SCRIPT" ]] || err "Auth script not found: $AUTH_SCRIPT"

    AUTH_ARGS=(
        --executor-url "http://127.0.0.1:${GQL_PORT}"
        --flux-url "http://localhost:${WE_PORT}"
        --admin-credential "$CREDENTIAL"
        --executor-log /tmp/ad4m-executor.log
    )

    log "Running ad4m-connect auth (UCAN capability flow)..."
    "$AUTH_SCRIPT" "${AUTH_ARGS[@]}"
fi
