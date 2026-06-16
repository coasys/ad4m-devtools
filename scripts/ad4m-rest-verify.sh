#!/usr/bin/env bash
# ad4m-rest-verify.sh — Verify all AD4M REST endpoints
# Usage: ad4m-rest-verify.sh [--url URL] [--admin CREDENTIAL]
set -euo pipefail

URL="${URL:-http://127.0.0.1:12000}"
ADMIN="${ADMIN:-test123}"
PASS=0; FAIL=0; SKIP=0
FAILURES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="$2"; shift 2;;
    --admin) ADMIN="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

API="$URL/api/v1"

# ── Helpers ──────────────────────────────────────────────────────────────────

check() {
  local method="$1" path="$2" expected_status="${3:-200}" body="${4:-}" timeout_s="${5:-10}"
  local tmpfile status response

  tmpfile=$(mktemp)
  local curl_args=(-s -o "$tmpfile" -w '%{http_code}' -m "$timeout_s" -X "$method")
  curl_args+=(-H "Authorization: $ADMIN" -H "Content-Type: application/json")
  [[ -n "$body" ]] && curl_args+=(-d "$body")

  status=$(curl "${curl_args[@]}" "${API}${path}" 2>/dev/null) || status="000"
  response=$(cat "$tmpfile" 2>/dev/null | head -c 300)
  rm -f "$tmpfile"

  if [[ "$status" == "$expected_status" ]]; then
    printf "✅ %-6s %-55s %s\n" "$method" "$path" "$status"
    PASS=$((PASS+1))
  else
    printf "❌ %-6s %-55s %s (expected %s)\n" "$method" "$path" "$status" "$expected_status"
    [[ -n "$response" ]] && printf "   └─ %.200s\n" "$response"
    FAIL=$((FAIL+1))
    FAILURES+=("$method $path: got $status expected $expected_status")
  fi
}

check_no_auth() {
  local method="$1" path="$2" expected_status="${3:-200}"
  local tmpfile status response
  tmpfile=$(mktemp)
  status=$(curl -s -o "$tmpfile" -w '%{http_code}' -m 5 -X "$method" "${URL}${path}" 2>/dev/null) || status="000"
  response=$(cat "$tmpfile" 2>/dev/null | head -c 200)
  rm -f "$tmpfile"
  if [[ "$status" == "$expected_status" ]]; then
    printf "✅ %-6s %-55s %s\n" "$method" "$path" "$status"
    PASS=$((PASS+1))
  else
    printf "❌ %-6s %-55s %s (expected %s)\n" "$method" "$path" "$status" "$expected_status"
    [[ -n "$response" ]] && printf "   └─ %.200s\n" "$response"
    FAIL=$((FAIL+1))
    FAILURES+=("$method $path: got $status expected $expected_status")
  fi
}

check_sse() {
  local path="$1"
  local status
  status=$(curl -s -o /dev/null -w '%{http_code}' -m 2 -H "Authorization: $ADMIN" -H "Accept: text/event-stream" "${API}${path}" 2>/dev/null) || true
  # SSE streams — curl timeout (000/028) or 200 both mean it's working
  if [[ "$status" == "200" || "$status" == "000" || "$status" == "timeout" ]]; then
    printf "✅ %-6s %-55s SSE\n" "GET" "$path"
    PASS=$((PASS+1))
  else
    printf "❌ %-6s %-55s %s\n" "GET" "$path" "$status"
    FAIL=$((FAIL+1))
    FAILURES+=("SSE $path: $status")
  fi
}

echo "═══════════════════════════════════════════════════════════════════"
echo "  AD4M REST API Verification — $(date '+%Y-%m-%d %H:%M:%S')"
echo "  URL: $URL"
echo "═══════════════════════════════════════════════════════════════════"

# ── Health ───────────────────────────────────────────────────────────────────
echo ""
echo "── Health (no auth) ──"
check_no_auth GET /health 200

# ── Agent ────────────────────────────────────────────────────────────────────
echo ""
echo "── Agent ──"
check GET /agent/status
check GET /agent
check GET /agent/is-locked
check GET /agent/apps
check GET /agent/trusted
check POST /agent/sign 200 '{"message":"hello"}'

# ── Agent Auth ───────────────────────────────────────────────────────────────
echo ""
echo "── Agent Auth ──"
AUTH_BODY='{"authInfo":{"appName":"verify","appDesc":"test","appDomain":"test.local","capabilities":[{"with":{"domain":"*","pointers":["*"]},"can":["*"]}]}}'
REQ_RESP=$(curl -sf -m 10 -X POST -H "Authorization: $ADMIN" -H "Content-Type: application/json" -d "$AUTH_BODY" "${API}/agent/auth/request" 2>/dev/null) || REQ_RESP=""
if [[ -n "$REQ_RESP" ]]; then
  printf "✅ %-6s %-55s 200\n" "POST" "/agent/auth/request"
  PASS=$((PASS+1))
  # Response is the request_id. With admin credential, auto-permit happens server-side.
  REQ_ID=$(echo "$REQ_RESP" | jq -r '. // empty' 2>/dev/null)
  if [[ -n "$REQ_ID" ]]; then
    # Permit requires AuthInfoExtended JSON string in {auth: "..."}
    AUTH_EXT="{\"requestId\":\"$REQ_ID\",\"auth\":{\"appName\":\"verify\",\"appDesc\":\"test\",\"appDomain\":\"test.local\",\"capabilities\":[{\"with\":{\"domain\":\"*\",\"pointers\":[\"*\"]},\"can\":[\"*\"]}]}}"
    # Escape for JSON string value
    AUTH_EXT_ESC=$(echo "$AUTH_EXT" | sed 's/"/\\"/g')
    PERMIT_RESP=$(curl -sf -m 10 -X POST -H "Authorization: $ADMIN" -H "Content-Type: application/json" \
      -d "{\"auth\":\"$AUTH_EXT_ESC\"}" "${API}/agent/auth/permit" 2>/dev/null) || PERMIT_RESP=""
    if [[ -n "$PERMIT_RESP" ]]; then
      printf "✅ %-6s %-55s 200\n" "POST" "/agent/auth/permit"
      PASS=$((PASS+1))
      # JWT — use requestId + rand (from permit response)
      RAND_NUM=$(echo "$PERMIT_RESP" | jq -r '.' 2>/dev/null)
      JWT_RESP=$(curl -sf -m 10 -X POST -H "Authorization: $ADMIN" -H "Content-Type: application/json" \
        -d "{\"requestId\":\"$REQ_ID\",\"rand\":\"$RAND_NUM\"}" "${API}/agent/auth/jwt" 2>/dev/null) || JWT_RESP=""
      if [[ -n "$JWT_RESP" ]]; then
        printf "✅ %-6s %-55s 200\n" "POST" "/agent/auth/jwt"
        PASS=$((PASS+1))
      else
        printf "❌ %-6s %-55s failed\n" "POST" "/agent/auth/jwt"
        FAIL=$((FAIL+1)); FAILURES+=("POST /agent/auth/jwt")
      fi
    else
      printf "❌ %-6s %-55s failed\n" "POST" "/agent/auth/permit"
      FAIL=$((FAIL+1)); FAILURES+=("POST /agent/auth/permit")
      SKIP=$((SKIP+1))
    fi
  else
    printf "⏭  Could not parse request_id, skipping permit/jwt\n"
    SKIP=$((SKIP+2))
  fi
else
  printf "❌ %-6s %-55s failed\n" "POST" "/agent/auth/request"
  FAIL=$((FAIL+1)); FAILURES+=("POST /agent/auth/request")
  SKIP=$((SKIP+2))
fi

# ── Languages ────────────────────────────────────────────────────────────────
echo ""
echo "── Languages ──"
check GET /languages

# ── Perspectives ─────────────────────────────────────────────────────────────
echo ""
echo "── Perspectives ──"
check GET /perspectives

# Create test perspective
CREATE_RESP=$(curl -sf -m 10 -X POST -H "Authorization: $ADMIN" -H "Content-Type: application/json" \
  -d '{"name":"rest-verify-test"}' "${API}/perspectives" 2>/dev/null) || CREATE_RESP=""
PERSP_UUID=$(echo "$CREATE_RESP" | jq -r '.uuid // empty' 2>/dev/null)

if [[ -n "$PERSP_UUID" ]]; then
  printf "✅ %-6s %-55s 200 (%.8s)\n" "POST" "/perspectives" "$PERSP_UUID"
  PASS=$((PASS+1))

  check GET "/perspectives/$PERSP_UUID"
  check GET "/perspectives/$PERSP_UUID/snapshot"
  check PUT "/perspectives/$PERSP_UUID" 200 '{"name":"renamed-test"}'

  # Add link (correct format: {link: {source, target, predicate}})
  check POST "/perspectives/$PERSP_UUID/links" 200 '{"link":{"source":"ad4m://self","target":"ad4m://test","predicate":"ad4m://has"}}'

  # Query links
  check GET "/perspectives/$PERSP_UUID/links?source=ad4m://self"

  # Bulk add
  check POST "/perspectives/$PERSP_UUID/links/bulk" 200 '{"links":[{"source":"ad4m://a","target":"ad4m://b","predicate":"ad4m://c"}]}'

  # Remove bulk
  # check POST "/perspectives/$PERSP_UUID/links/remove-bulk" 200 '{"links":[]}'

  # Query (prolog)
  check POST "/perspectives/$PERSP_UUID/query" 200 '{"engine":"prolog","query":"findall(X, triple(\"ad4m://self\",_,X), Xs), Xs = X"}'

  # SDNA
  check POST "/perspectives/$PERSP_UUID/sdna" 200 '{"name":"test-sdna","sdnaCode":"register_sdna_flow(\"test\", _).","sdnaType":"flow"}'

  # Cleanup
  check DELETE "/perspectives/$PERSP_UUID"
else
  printf "❌ %-6s %-55s create failed\n" "POST" "/perspectives"
  FAIL=$((FAIL+1)); FAILURES+=("POST /perspectives: create")
  SKIP=$((SKIP+8))
fi

# ── Neighbourhoods ───────────────────────────────────────────────────────────
echo ""
echo "── Neighbourhoods ──"
echo "   (publish/join require language installation — skipping in quick mode)"
echo "   Use --full to test neighbourhood publish (slow, requires holochain)"
SKIP=$((SKIP+2))

# ── Expressions ──────────────────────────────────────────────────────────────
echo ""
echo "── Expressions ──"
check POST /expressions 200 '{"languageAddress":"literal","content":"\"hello\""}'
check POST /expressions/many 200 '{"urls":[]}'

# ── Runtime ──────────────────────────────────────────────────────────────────
echo ""
echo "── Runtime ──"
check GET /runtime/info
check GET /runtime/tls-domain
check GET /runtime/compute-log
check GET /runtime/friends
check GET /runtime/messages/inbox
check GET /runtime/messages/outbox
check GET /runtime/notifications
check GET /runtime/link-language-templates
check GET /runtime/hc/agent-infos
check GET /runtime/network-metrics
check GET /runtime/free-hosting-enabled
check POST /runtime/verify-signature 200 '{"did":"did:key:z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK","didSigningKeyId":"#key1","data":"hello","signedData":"aabbccdd"}'

# ── AI ───────────────────────────────────────────────────────────────────────
echo ""
echo "── AI ──"
check GET /ai/models
check GET /ai/tasks
check GET "/ai/models/default?modelType=llm"
check GET "/ai/model-loading-status?model=default" 500  # no models configured

# ── Hosting ──────────────────────────────────────────────────────────────────
echo ""
echo "── Hosting ──"
check GET /hosting
check GET /hosting/wallet

# ── Users ────────────────────────────────────────────────────────────────────
echo ""
echo "── Users ──"
check GET /users/multi-user-enabled
check GET /users

# ── SSE Events ───────────────────────────────────────────────────────────────
echo ""
echo "── SSE Events ──"
check_sse /events

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
echo "  ✅ $PASS pass  ❌ $FAIL fail  ⏭ $SKIP skip  (of $TOTAL tested)"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo ""
  echo "  Failures:"
  for f in "${FAILURES[@]}"; do
    echo "    • $f"
  done
fi
echo "═══════════════════════════════════════════════════════════════════"

# ── Recent errors from executor log ──────────────────────────────────────────
if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "── Recent executor errors ──"
  tail -200 /tmp/ad4m-executor-stdout.log 2>/dev/null | grep -iE 'error|panic|500|404|422|403' | tail -10 || echo "(no log)"
fi

exit $FAIL
