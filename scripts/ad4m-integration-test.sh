#!/usr/bin/env bash
# ad4m-integration-test.sh — Run executor integration tests locally.
#
# Lifecycle: kill stale executor → init fresh data → start executor →
#            generate agent → run WS-RPC test suite → tear down.
#
# This mirrors CI's pattern (tests/js/ + tests/integration.bats):
#   CI builds the binary, starts a fresh executor on an isolated port,
#   generates an agent, runs mocha tests, then tears down.
# This script does the same with a lightweight Python WS-RPC test suite
# that exercises the core RPC endpoints without requiring the full
# JS test infrastructure (pnpm install, language builds, etc.).
#
# Prerequisites:
#   - Built ad4m-executor binary at <ad4m-repo>/target/release/ad4m-executor
#   - Python 3.9+ with 'websockets' package (pip3 install websockets)
#
# Usage:
#   ad4m-integration-test.sh --ad4m /path/to/ad4m [--port 4000]
#
# To run the full CI JS integration tests locally instead:
#   cd ad4m/tests/js && pnpm install && pnpm run test-model
# (requires built binary + bootstrap languages — see tests/js/README)

set -euo pipefail

# --- defaults ---
AD4M_DIR=""
PORT=4000
DATA_PATH="/tmp/ad4m-integration-test"
EXECUTOR_PID=""
ADMIN_CREDENTIAL="test123"
PASSPHRASE="secret"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- colours ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
  cat <<EOF
Usage: $(basename "$0") --ad4m <ad4m-repo-path> [options]

Options:
  --ad4m DIR        Path to the ad4m repository (required)
  --port PORT       Executor port (default: 4000)
  --data-path DIR   Temp data directory (default: /tmp/ad4m-integration-test)
  --admin CRED      Admin credential (default: test123)
  --help            Show this help
EOF
  exit 0
}

# --- arg parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ad4m)     AD4M_DIR="$2"; shift 2 ;;
    --port)     PORT="$2"; shift 2 ;;
    --data-path) DATA_PATH="$2"; shift 2 ;;
    --admin)    ADMIN_CREDENTIAL="$2"; shift 2 ;;
    --help)     usage ;;
    *)          echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "$AD4M_DIR" ]]; then
  echo -e "${RED}Error: --ad4m is required${NC}" >&2
  usage
fi

AD4M_DIR="$(cd "$AD4M_DIR" && pwd)"
BINARY="$AD4M_DIR/target/release/ad4m-executor"

if [[ ! -x "$BINARY" ]]; then
  echo -e "${RED}Error: ad4m-executor binary not found at $BINARY${NC}" >&2
  echo "Build it first: cd $AD4M_DIR && cargo build --release -p ad4m" >&2
  exit 1
fi

# Check Python websockets
if ! python3 -c "import websockets" 2>/dev/null; then
  echo -e "${RED}Error: Python 'websockets' package required${NC}" >&2
  echo "Install with: pip3 install websockets" >&2
  exit 1
fi

# --- cleanup function ---
cleanup() {
  if [[ -n "$EXECUTOR_PID" ]]; then
    echo -e "\n${YELLOW}Stopping executor (PID $EXECUTOR_PID)...${NC}"
    kill -TERM "$EXECUTOR_PID" 2>/dev/null || true
    for i in $(seq 1 10); do
      kill -0 "$EXECUTOR_PID" 2>/dev/null || break
      sleep 1
    done
    kill -9 "$EXECUTOR_PID" 2>/dev/null || true
  fi
  # Port-based fallback (matches CI's teardown_file in integration.bats)
  for pid in $(lsof -ti:"$PORT" 2>/dev/null || true); do
    cmd="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
    case "$cmd" in *ad4m*) kill -9 "$pid" 2>/dev/null || true ;; esac
  done
}
trap cleanup EXIT

# --- Step 1: Kill stale executor on our port ---
echo -e "${YELLOW}[1/5] Cleaning up stale processes on port $PORT...${NC}"
for pid in $(lsof -ti:"$PORT" 2>/dev/null || true); do
  cmd="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
  case "$cmd" in *ad4m*) kill -9 "$pid" 2>/dev/null || true; echo "  Killed stale PID $pid" ;; esac
done
sleep 1

# --- Step 2: Init fresh data ---
echo -e "${YELLOW}[2/5] Initializing fresh data directory ($DATA_PATH)...${NC}"
rm -rf "$DATA_PATH"
"$BINARY" init --data-path "$DATA_PATH" 2>&1 | grep -v "^$" | sed 's/^/  /'

# --- Step 3: Start executor ---
echo -e "${YELLOW}[3/5] Starting executor on port $PORT...${NC}"
"$BINARY" run \
  --admin-credential "$ADMIN_CREDENTIAL" \
  --app-data-path "$DATA_PATH" \
  --port "$PORT" \
  > "$DATA_PATH/executor.log" 2>&1 &
EXECUTOR_PID=$!
echo "  PID: $EXECUTOR_PID"

# Wait for health endpoint
for i in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    echo -e "  ${GREEN}Healthy after ${i}s${NC}"
    break
  fi
  if ! kill -0 "$EXECUTOR_PID" 2>/dev/null; then
    echo -e "  ${RED}Executor died. Log tail:${NC}"
    tail -20 "$DATA_PATH/executor.log" | sed 's/^/    /'
    exit 1
  fi
  sleep 1
done
if ! curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  echo -e "  ${RED}Executor failed to start within 60s${NC}"
  tail -20 "$DATA_PATH/executor.log" | sed 's/^/    /'
  exit 1
fi

# --- Step 4: Generate agent ---
echo -e "${YELLOW}[4/5] Generating agent...${NC}"
# First WS call after executor start sometimes hangs (Holochain bootstrap),
# so we do a throwaway status check with a short timeout, then the real generate.
python3 -c "
import asyncio, json, uuid, websockets
async def main():
    try:
        async with websockets.connect('ws://127.0.0.1:$PORT/api/v1/ws?token=$ADMIN_CREDENTIAL') as ws:
            await ws.send(json.dumps({'id': str(uuid.uuid4()), 'type': 'agent.status', 'params': {}}))
            await asyncio.wait_for(ws.recv(), timeout=5)
    except:
        pass
asyncio.run(main())
" 2>/dev/null || true

# Actual agent.generate
python3 -c "
import asyncio, json, uuid, websockets
async def main():
    async with websockets.connect('ws://127.0.0.1:$PORT/api/v1/ws?token=$ADMIN_CREDENTIAL') as ws:
        await ws.send(json.dumps({'id': str(uuid.uuid4()), 'type': 'agent.generate', 'params': {'passphrase': '$PASSPHRASE'}}))
        r = json.loads(await asyncio.wait_for(ws.recv(), timeout=60))
        if r.get('error'):
            print('  FAILED:', r['error']); exit(1)
        print('  Agent DID:', r['result'].get('did','<unknown>')[:40] + '...')
asyncio.run(main())
"
echo -e "  ${GREEN}Agent ready${NC}"

# --- Step 5: Run test suite ---
echo -e "${YELLOW}[5/5] Running integration tests...${NC}"
echo ""
python3 -u "$SCRIPT_DIR/ad4m-integration-test.py" --port "$PORT" --token "$ADMIN_CREDENTIAL"
TEST_EXIT=$?

echo ""
if [[ $TEST_EXIT -eq 0 ]]; then
  echo -e "${GREEN}✓ All integration tests passed${NC}"
else
  echo -e "${RED}✗ Some integration tests failed${NC}"
  echo "  Executor log: $DATA_PATH/executor.log"
fi

exit $TEST_EXIT
