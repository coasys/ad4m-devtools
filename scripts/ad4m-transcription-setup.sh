#!/usr/bin/env bash
# ad4m-transcription-setup.sh — Register and pre-download a Whisper model
#
# Registers a transcription model in the executor and optionally pre-downloads
# the weights by opening (then immediately closing) a transcription stream.
#
# Prerequisites: executor must be running with an initialised agent and a
# logged-in user (i.e. run ad4m-flux-launch.sh first).
#
# Usage:
#   ad4m-transcription-setup.sh [options]
#
# Options:
#   --model NAME       Whisper model variant (default: whisper_small)
#   --port PORT        Executor port (default: 12000)
#   --credential CRED  Admin credential (default: test123)
#   --data-path DIR    Executor data dir, for reading cached JWT (default: /tmp/ad4m-devtools)
#   --no-preload       Skip pre-downloading the model weights
#   --help             Show this help
#
# Available models (smallest → largest):
#   whisper_tiny_quantized          ~40 MB   (fastest, lowest quality)
#   whisper_tiny / whisper_tiny_en  ~75 MB
#   whisper_base / whisper_base_en  ~150 MB
#   whisper_small / whisper_small_en ~500 MB  (good balance — default)
#   whisper_medium / whisper_medium_en ~1.5 GB
#   whisper_distil_large_v3         ~800 MB  (large quality, medium size)
#   whisper_large_v3_turbo_quantized ~800 MB
#   whisper_large / whisper_large_v2 ~3 GB
#
# Examples:
#   ad4m-transcription-setup.sh
#   ad4m-transcription-setup.sh --model whisper_tiny_quantized
#   ad4m-transcription-setup.sh --model whisper_distil_large_v3 --no-preload

set -euo pipefail

log() { echo -e "\033[1;36m→ $1\033[0m"; }
err() { echo -e "\033[1;31m✗ $1\033[0m" >&2; exit 1; }
ok()  { echo -e "\033[1;32m✓ $1\033[0m"; }
warn() { echo -e "\033[1;33m⚠ $1\033[0m" >&2; }

# --- Defaults ---
MODEL="whisper_small"
PORT=12000
CREDENTIAL="test123"
DATA_PATH="/tmp/ad4m-devtools"
PRELOAD=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --model) [[ $# -ge 2 ]] || err "--model requires a name"; MODEL="$2"; shift 2;;
        --port) [[ $# -ge 2 ]] || err "--port requires a port"; PORT="$2"; shift 2;;
        --credential) [[ $# -ge 2 ]] || err "--credential requires a value"; CREDENTIAL="$2"; shift 2;;
        --data-path) [[ $# -ge 2 ]] || err "--data-path requires a directory"; DATA_PATH="$2"; shift 2;;
        --no-preload) PRELOAD=false; shift;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'; exit 0;;
        *) err "Unknown option: $1";;
    esac
done

WS_URL="ws://127.0.0.1:${PORT}/api/v1/ws"
HEALTH_URL="http://127.0.0.1:${PORT}/health"
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_RPC="$TOOL_DIR/ad4m-ws-rpc.py"

# --- Helper: WebSocket RPC call ---
ws_rpc() {
    python3 "$WS_RPC" --url "$WS_URL" --token "${1}" "${2}" ${3:+"$3"}
}

# --- Validate model name ---
VALID_MODELS=(
    whisper_tiny whisper_tiny_en whisper_tiny_quantized whisper_tiny_en_quantized
    whisper_base whisper_base_en
    whisper_small whisper_small_en
    whisper_medium whisper_medium_en whisper_medium_en_quantized_distil
    whisper_distil_medium_en whisper_distil_large_v2 whisper_distil_large_v3
    whisper_distil_large_v3_quantized whisper_large_v3_turbo_quantized
    whisper_large whisper_large_v2
)

FOUND=false
for v in "${VALID_MODELS[@]}"; do
    [[ "$v" == "$MODEL" ]] && FOUND=true && break
done
$FOUND || err "Unknown model: $MODEL. Valid models: ${VALID_MODELS[*]}"

# --- Map variant to Flux-expected display name ---
# Flux aiStore.ts looks up models by name:
#   model.name === 'Whisper'               → main transcription model
#   model.name === 'Whisper tiny quantized' → fast/preview model
case "$MODEL" in
    whisper_tiny_quantized|whisper_tiny_en_quantized)
        DISPLAY_NAME="Whisper tiny quantized" ;;
    *)
        DISPLAY_NAME="Whisper" ;;
esac

# --- Check executor is running ---
log "Checking executor on port $PORT..."
if ! curl -sf "$HEALTH_URL" >/dev/null 2>&1; then
    err "Executor not responding on port $PORT. Start it first."
fi
ok "Executor is running"

# --- Get user JWT (needed for opening transcription stream) ---
USER_JWT=""
if [[ -f "$DATA_PATH/.user-jwt" ]]; then
    USER_JWT=$(cat "$DATA_PATH/.user-jwt")
    log "Using cached JWT from $DATA_PATH/.user-jwt"
fi
AUTH="${USER_JWT:-$CREDENTIAL}"

# ==========================================================================
# 1. Register transcription model (idempotent)
# ==========================================================================
log "Registering model: $MODEL (type: Transcription)..."

# Check if already registered
EXISTING=$(ws_rpc "$CREDENTIAL" "ai.getModels")
ALREADY_REGISTERED=$(echo "$EXISTING" | python3 -c "
import sys, json
try:
    models = json.load(sys.stdin)
    if not isinstance(models, list):
        models = models.get('models', [])
    found = any(m.get('local',{}).get('fileName') == '$MODEL' and m.get('modelType') == 'TRANSCRIPTION' for m in models)
    print(found)
except:
    print(False)
" 2>/dev/null) || ALREADY_REGISTERED="False"

if [[ "$ALREADY_REGISTERED" == "True" ]]; then
    ok "Model '$MODEL' already registered"
    MODEL_ID=$(echo "$EXISTING" | python3 -c "
import sys, json
models = json.load(sys.stdin)
if not isinstance(models, list):
    models = models.get('models', [])
for m in models:
    if m.get('local',{}).get('fileName') == '$MODEL' and m.get('modelType') == 'TRANSCRIPTION':
        print(m.get('id', '$MODEL'))
        break
" 2>/dev/null) || MODEL_ID="$MODEL"
else
    ADD_PARAMS=$(python3 -c "
import json
params = {
    'model': {
        'name': '$DISPLAY_NAME',
        'modelType': 'TRANSCRIPTION',
        'local': {'fileName': '$MODEL'}
    }
}
print(json.dumps(params))
")
    ADD_RESULT=$(ws_rpc "$CREDENTIAL" "ai.addModel" "$ADD_PARAMS")
    MODEL_ID=$(echo "$ADD_RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if isinstance(data, str):
    print(data)
elif isinstance(data, dict) and 'error' in data:
    print('ERROR: ' + str(data['error']), file=sys.stderr)
    sys.exit(1)
else:
    print(data)
" 2>/dev/null) || err "Failed to register model: $ADD_RESULT"

    ok "Model registered: $MODEL_ID"
fi

# ==========================================================================
# 2. Set host rate (required even if billing inactive, for safety)
# ==========================================================================
log "Setting host rate for $MODEL..."
RATE_PARAMS=$(python3 -c "
import json
params = {'ratesJson': json.dumps([{'description': '$MODEL', 'priceInHOT': 0.001}])}
print(json.dumps(params))
")
RATE_RESULT=$(ws_rpc "$CREDENTIAL" "runtime.setHostRates" "$RATE_PARAMS")
RATE_OK=$(echo "$RATE_RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data if isinstance(data, bool) else bool(data))
" 2>/dev/null) || RATE_OK="false"
if [[ "$RATE_OK" == "True" || "$RATE_OK" == "true" ]]; then
    ok "Host rate set for $MODEL"
else
    warn "Could not set host rate (non-fatal if free access is enabled): $RATE_RESULT"
fi

# ==========================================================================
# 3. Pre-download model weights (optional)
# ==========================================================================
if $PRELOAD; then
    log "Pre-downloading $MODEL weights (this may take a while on first run)..."

    if [[ -z "$USER_JWT" ]]; then
        warn "No user JWT found — trying admin credential for preload"
        AUTH="$CREDENTIAL"
    fi

    # Open a stream — this triggers the model download
    OPEN_PARAMS=$(python3 -c "
import json
print(json.dumps({'modelId': '$MODEL'}))
")
    OPEN_RESULT=$(ws_rpc "$AUTH" "ai.openTranscriptionStream" "$OPEN_PARAMS")
    STREAM_ID=$(echo "$OPEN_RESULT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if isinstance(data, str):
    print(data)
elif isinstance(data, dict) and 'error' in data:
    print('ERROR: ' + str(data['error']), file=sys.stderr)
    sys.exit(1)
else:
    print(data)
" 2>/dev/null)

    if [[ $? -ne 0 || -z "$STREAM_ID" || "$STREAM_ID" == "null" ]]; then
        warn "Could not open transcription stream for preload: $OPEN_RESULT"
        warn "Model will be downloaded on first use instead"
    else
        ok "Model loaded (stream $STREAM_ID)"

        # Close the stream immediately
        CLOSE_PARAMS=$(python3 -c "
import json
print(json.dumps({'streamId': '$STREAM_ID'}))
")
        ws_rpc "$AUTH" "ai.closeTranscriptionStream" "$CLOSE_PARAMS" >/dev/null 2>&1
        ok "Preload stream closed"
    fi
fi

# ==========================================================================
# Summary
# ==========================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Transcription Model Ready"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Model:    $MODEL"
echo "  Model ID: ${MODEL_ID:-$MODEL}"
echo "  Port:     $PORT"
echo "  Preload:  $PRELOAD"
echo ""
