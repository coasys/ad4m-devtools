#!/usr/bin/env bash
# ad4m-flux-browser-auth.sh — Open Flux in Chrome and authenticate
#
# Launches Chrome with CDP, injects auth credentials directly into
# localStorage (bypassing the ad4m-connect UI flow), creates a Flux
# profile, and leaves Chrome open at #/home with the community visible.
#
# Prerequisites:
#   - AD4M executor running (use ad4m-flux-launch.sh)
#   - Flux served locally (use ad4m-flux-launch.sh --flux DIR)
#   - python3 with 'websockets' package (pip3 install websockets)
#   - Google Chrome installed
#
# Usage:
#   ad4m-flux-browser-auth.sh [options]
#
# Options:
#   --executor-url URL       Executor URL (default: http://127.0.0.1:12000)
#   --flux-url URL           Flux URL (default: http://localhost:3030)
#   --email EMAIL            User email (default: dev@test.com)
#   --password PASS          User password (default: test123)
#   --admin-credential CRED  Admin credential (default: test123)
#   --chrome-port PORT       CDP port (default: 9222)
#   --chrome-profile DIR     Chrome user data dir (default: /tmp/chrome-ad4m-dev)
#   --connect-version VER    ad4m-connect version prefix (auto-detected from Flux)
#   --flux-dir DIR           Flux repo dir (for auto-detecting connect version)
#   --no-launch              Don't launch Chrome (attach to existing CDP)
#   --skip-create-user       Don't create the user (assume exists)
#   --help                   Show this help
#
# Examples:
#   ad4m-flux-browser-auth.sh
#   ad4m-flux-browser-auth.sh --email alice@test.com --password secret
#   ad4m-flux-browser-auth.sh --no-launch --chrome-port 18800

set -euo pipefail

log() { echo -e "\033[1;36m→ $1\033[0m"; }
err() { echo -e "\033[1;31m✗ $1\033[0m" >&2; exit 1; }
ok()  { echo -e "\033[1;32m✓ $1\033[0m"; }
warn() { echo -e "\033[1;33m⚠ $1\033[0m" >&2; }

EXECUTOR_URL="http://127.0.0.1:12000"
FLUX_URL="http://localhost:3030"
EMAIL="dev@test.com"
PASSWORD="test123"
ADMIN_CREDENTIAL="test123"
CDP_PORT=9222
CHROME_PROFILE="/tmp/chrome-ad4m-dev"
CONNECT_VERSION=""
FLUX_DIR=""
[[ -d "./flux/app" ]] && FLUX_DIR="./flux"
DO_LAUNCH=true
SKIP_CREATE_USER=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --executor-url) EXECUTOR_URL="$2"; shift 2;;
        --flux-url) FLUX_URL="$2"; shift 2;;
        --email) EMAIL="$2"; shift 2;;
        --password) PASSWORD="$2"; shift 2;;
        --admin-credential) ADMIN_CREDENTIAL="$2"; shift 2;;
        --chrome-port) CDP_PORT="$2"; shift 2;;
        --chrome-profile) CHROME_PROFILE="$2"; shift 2;;
        --connect-version) CONNECT_VERSION="$2"; shift 2;;
        --flux-dir) FLUX_DIR="$2"; shift 2;;
        --no-launch) DO_LAUNCH=false; shift;;
        --skip-create-user) SKIP_CREATE_USER=true; shift;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'; exit 0;;
        *) err "Unknown option: $1";;
    esac
done

API_PORT=$(echo "$EXECUTOR_URL" | grep -oE '[0-9]+$')
REST_BASE="$EXECUTOR_URL/api/v1"
GQL_URL="$EXECUTOR_URL/graphql"

# --- Auto-detect API mode (REST preferred, GQL fallback) ---
USE_REST=false
if curl -sf "$REST_BASE/agent/status" -H "authorization: $ADMIN_CREDENTIAL" 2>/dev/null | grep -q '"isInitialized"'; then
    USE_REST=true
elif curl -sf -X POST "$GQL_URL" -H "Content-Type: application/json" -H "authorization: $ADMIN_CREDENTIAL" \
     -d '{"query":"{ agentStatus { isInitialized } }"}' 2>/dev/null | grep -q '"isInitialized"'; then
    USE_REST=false
else
    err "Executor not ready (tried REST and GraphQL)"
fi

# Connection URL for ad4m-connect localStorage injection
if $USE_REST; then
    # REST: ad4m-connect uses HTTP URL
    CONNECT_URL="$EXECUTOR_URL"
    ok "Executor running (REST)"
else
    # GraphQL: ad4m-connect uses WebSocket URL
    CONNECT_URL="ws://127.0.0.1:${API_PORT}/graphql"
    ok "Executor running (GraphQL)"
fi

# --- Step 2: Verify Flux ---
log "Checking Flux..."
curl -sf "$FLUX_URL" >/dev/null || err "Flux not responding at $FLUX_URL"
ok "Flux serving"

# --- Step 3: Create test user ---
if ! $SKIP_CREATE_USER; then
    log "Ensuring test user exists: $EMAIL"
    if $USE_REST; then
        curl -sf -X POST "$REST_BASE/users" \
            -H "Content-Type: application/json" \
            -H "authorization: $ADMIN_CREDENTIAL" \
            -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" >/dev/null 2>&1
    else
        curl -sf -X POST "$GQL_URL" \
            -H "Content-Type: application/json" \
            -H "authorization: $ADMIN_CREDENTIAL" \
            -d "{\"query\":\"mutation { runtimeCreateUser(email: \\\"$EMAIL\\\", password: \\\"$PASSWORD\\\") { success } }\"}" >/dev/null 2>&1
    fi
    ok "User ready"
fi

# --- Step 4: Get user JWT ---
log "Logging in as $EMAIL..."
if $USE_REST; then
    USER_JWT=$(curl -sf -X POST "$REST_BASE/users/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin))" 2>/dev/null) || USER_JWT=""
else
    USER_JWT=$(curl -sf -X POST "$GQL_URL" \
        -H "Content-Type: application/json" \
        -d "{\"query\":\"mutation { runtimeLoginUser(email: \\\"$EMAIL\\\", password: \\\"$PASSWORD\\\") }\"}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['runtimeLoginUser'])" 2>/dev/null) || USER_JWT=""
fi
[[ -n "$USER_JWT" ]] || err "Login failed for $EMAIL"
ok "JWT obtained (${#USER_JWT} chars)"

# --- Step 4b: Ensure Flux profile exists ---
# Check if profile already has flux://profile links
if $USE_REST; then
    PROFILE_LINKS=$(curl -sf "$REST_BASE/agent" \
        -H "Authorization: $USER_JWT" \
        | python3 -c "
import sys,json
try:
    links = json.load(sys.stdin)['perspective']['links']
    flux = [l for l in links if l.get('data',{}).get('source','').startswith('flux://')]
    print(len(flux))
except: print('0')" 2>/dev/null)
else
    PROFILE_LINKS=$(curl -sf -X POST "$GQL_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: $USER_JWT" \
        -d '{"query":"{ agent { perspective { links { data { source } } } } }"}' \
        | python3 -c "
import sys,json
try:
    links = json.load(sys.stdin)['data']['agent']['perspective']['links']
    flux = [l for l in links if l['data']['source'].startswith('flux://')]
    print(len(flux))
except: print('0')" 2>/dev/null)
fi

if [[ "$PROFILE_LINKS" == "0" ]]; then
    if $USE_REST; then
        log "Creating Flux profile via REST..."
        PROFILE_RESULT=$(python3 << PROFILE_EOF
import json, urllib.request, sys

rest_base = "$REST_BASE"
jwt = "$USER_JWT"

def rest(method, path, body=None):
    url = rest_base + path
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, method=method,
        headers={"Content-Type": "application/json", "Authorization": jwt})
    with urllib.request.urlopen(req) as r:
        text = r.read().decode()
        return json.loads(text) if text else None

try:
    r = rest("POST", "/expressions", {"content": '"TestUser"', "languageAddress": "literal"})
    exp_url = r
    agent = rest("GET", "/agent")
    did = agent["did"]
    rest("PATCH", "/agent/profile", {
        "publicPerspective": {
            "links": [{
                "author": did,
                "timestamp": "2026-01-01T00:00:00Z",
                "data": {
                    "source": "flux://profile",
                    "predicate": "sioc://has_username",
                    "target": exp_url
                },
                "proof": {"key": "", "signature": ""}
            }]
        }
    })
    print("ok")
except Exception as e:
    print(f"fail: {e}", file=sys.stderr)
    sys.exit(1)
PROFILE_EOF
        )
    else
        log "Creating Flux profile via GraphQL..."
        PROFILE_RESULT=$(python3 << PROFILE_EOF
import json, urllib.request, sys

gql_url = "$GQL_URL"
jwt = "$USER_JWT"

def gql(query, variables=None):
    body = {"query": query}
    if variables:
        body["variables"] = variables
    req = urllib.request.Request(gql_url,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": jwt})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())

try:
    r = gql('mutation { expressionCreate(content: "\\\\"TestUser\\\\"", languageAddress: "literal") }')
    exp_url = r["data"]["expressionCreate"]
    r = gql('{ agent { did } }')
    did = r["data"]["agent"]["did"]
    query = '''mutation(\$perspective: PerspectiveInput!) {
        agentUpdatePublicPerspective(perspective: \$perspective) { did }
    }'''
    variables = {
        "perspective": {
            "links": [{
                "author": did,
                "timestamp": "2026-01-01T00:00:00Z",
                "data": {
                    "source": "flux://profile",
                    "predicate": "sioc://has_username",
                    "target": exp_url
                },
                "proof": {"key": "", "signature": ""}
            }]
        }
    }
    gql(query, variables)
    print("ok")
except Exception as e:
    print(f"fail: {e}", file=sys.stderr)
    sys.exit(1)
PROFILE_EOF
        )
    fi
    if [[ "$PROFILE_RESULT" == "ok" ]]; then
        ok "Flux profile created"
    else
        warn "Profile creation issue: $PROFILE_RESULT"
    fi
else
    ok "Flux profile already exists ($PROFILE_LINKS links)"
fi

# --- Step 5: Detect ad4m-connect version ---
if [[ -z "$CONNECT_VERSION" ]]; then
    # Best method: extract from the served Flux bundle by finding the variable
    # used in localStorage.setItem(`${VAR}/${e}`,t) — the ad4m-connect version prefix
    BUNDLE_VER=$(FLUX_DETECT_URL="$FLUX_URL" python3 << 'DETECT_VER_EOF'
import urllib.request, re, sys, os

flux_url = os.environ.get("FLUX_DETECT_URL", "http://localhost:3030")

try:
    with urllib.request.urlopen(flux_url, timeout=5) as r:
        html = r.read().decode()

    m = re.search(r'src="([^"]*assets/index-[^"]*\.js)"', html)
    if not m:
        sys.exit(1)

    js_path = m.group(1)
    js_url = flux_url.rstrip('/') + ('/' if not js_path.startswith('/') else '') + js_path

    with urllib.request.urlopen(js_url, timeout=15) as r:
        bundle = r.read().decode()

    # Find: localStorage.setItem(`${VAR}/${e}`,t) — extract VAR name
    m = re.search(r'localStorage\.setItem\(`\$\{(\w+\$?\d*)\}/\$\{[a-z]\}`', bundle)
    if not m:
        sys.exit(1)

    var_escaped = re.escape(m.group(1))
    # Find: VAR="version-string"
    m = re.search(var_escaped + r'="([^"]+)"', bundle)
    if not m:
        sys.exit(1)

    print(m.group(1))
except Exception:
    sys.exit(1)
DETECT_VER_EOF
    ) || true

    if [[ -n "$BUNDLE_VER" ]]; then
        CONNECT_VERSION="$BUNDLE_VER"
    else
        # Fallback: check node_modules package.json in common locations
        for dir in "$FLUX_DIR" ./flux ./we; do
            [[ -d "$dir" ]] || continue
            # Try common layouts: Flux (dir/app/node_modules), WE (dir/node_modules), or dir itself
            for sub in "$dir/app" "$dir" "$dir/apps/we-web"; do
                PKG="$sub/node_modules/@coasys/ad4m-connect/package.json"
                if [[ -f "$PKG" ]]; then
                    CONNECT_VERSION=$(python3 -c "import json; print(json.load(open('$PKG'))['version'])" 2>/dev/null) || true
                    [[ -n "$CONNECT_VERSION" ]] && break 2
                fi
            done
            # pnpm hoists to root .pnpm store — find it there
            if [[ -z "$CONNECT_VERSION" ]]; then
                PKG=$(find "$dir/node_modules/.pnpm" -path "*/@coasys/ad4m-connect/package.json" 2>/dev/null | head -1)
                if [[ -n "$PKG" ]]; then
                    CONNECT_VERSION=$(python3 -c "import json; print(json.load(open('$PKG'))['version'])" 2>/dev/null) || true
                    [[ -n "$CONNECT_VERSION" ]] && break
                fi
            fi
        done
    fi
fi
[[ -n "$CONNECT_VERSION" ]] || err "Cannot detect ad4m-connect version. Use --connect-version or --flux-dir"
ok "ad4m-connect version: $CONNECT_VERSION"

# --- Step 6: Check python3 websockets ---
python3 -c "import websockets" 2>/dev/null || err "Missing: pip3 install websockets"

# --- Step 7: Launch Chrome ---
if $DO_LAUNCH; then
    if curl -sf "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1; then
        ok "Chrome already on CDP port $CDP_PORT"
    else
        log "Launching Chrome..."
        CHROME_BIN=""
        if [[ -d "/Applications/Google Chrome.app" ]]; then
            CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        elif command -v google-chrome &>/dev/null; then
            CHROME_BIN="google-chrome"
        elif command -v chromium-browser &>/dev/null; then
            CHROME_BIN="chromium-browser"
        fi
        [[ -n "$CHROME_BIN" ]] || err "Chrome not found"

        "$CHROME_BIN" \
            --remote-debugging-port="$CDP_PORT" \
            --user-data-dir="$CHROME_PROFILE" \
            --no-first-run \
            --no-default-browser-check \
            --remote-allow-origins='*' \
            "about:blank" >/dev/null 2>&1 &

        for i in $(seq 1 15); do
            curl -sf "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1 && break
            sleep 1
        done
        curl -sf "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1 || err "Chrome didn't start"
        ok "Chrome launched"
    fi
else
    curl -sf "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1 || err "No CDP on port $CDP_PORT"
    ok "Chrome CDP on port $CDP_PORT"
fi

# --- Step 8: Ensure at least one tab exists ---
TAB_COUNT=$(curl -sf "http://127.0.0.1:$CDP_PORT/json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null) || TAB_COUNT=0
if [[ "$TAB_COUNT" -eq 0 ]]; then
    log "No tabs open — creating one..."
    BROWSER_WS=$(curl -sf "http://127.0.0.1:$CDP_PORT/json/version" | python3 -c "import sys,json; print(json.load(sys.stdin)['webSocketDebuggerUrl'])" 2>/dev/null) || BROWSER_WS=""
    if [[ -n "$BROWSER_WS" ]]; then
        python3 -c "
import asyncio, json, websockets
async def create():
    async with websockets.connect('$BROWSER_WS') as ws:
        await ws.send(json.dumps({'id':1,'method':'Target.createTarget','params':{'url':'about:blank'}}))
        await ws.recv()
asyncio.run(create())
" 2>/dev/null
        sleep 1
    else
        err "Cannot create tab — no browser WebSocket"
    fi
fi

# --- Step 9: Inject auth + create profile ---
log "Injecting auth and setting up Flux..."

python3 - "$CDP_PORT" "$FLUX_URL" "$CONNECT_URL" "$USER_JWT" "$CONNECT_VERSION" "$API_PORT" "$USE_REST" << 'PYEOF'
import asyncio, json, sys, time, urllib.request
import websockets

CDP_PORT       = sys.argv[1]
FLUX_URL       = sys.argv[2]
CONNECT_URL    = sys.argv[3]
USER_JWT       = sys.argv[4]
CONNECT_VER    = sys.argv[5]
API_PORT       = sys.argv[6]
USE_REST       = sys.argv[7] == "true"
CDP            = f"http://127.0.0.1:{CDP_PORT}"
T0             = time.monotonic()

def elapsed():
    return f"{time.monotonic() - T0:.1f}s"

def get_tabs():
    with urllib.request.urlopen(f"{CDP}/json") as r:
        return json.loads(r.read())

async def run():
    tabs = get_tabs()
    tab = None
    for t in tabs:
        if not t.get("url","").startswith("chrome-extension://") and t.get("type") == "page":
            tab = t; break
    if not tab and tabs:
        tab = tabs[-1]
    if not tab:
        print("ERROR: no tabs", file=sys.stderr); sys.exit(1)

    ws_url = tab.get("webSocketDebuggerUrl", "")
    if not ws_url:
        print("ERROR: no ws url", file=sys.stderr); sys.exit(1)

    mid = 0
    async with websockets.connect(ws_url, max_size=50_000_000) as ws:

        async def send(method, params=None):
            nonlocal mid; mid += 1
            my_id = mid
            cmd = {"id": my_id, "method": method}
            if params: cmd["params"] = params
            await ws.send(json.dumps(cmd))
            while True:
                r = json.loads(await asyncio.wait_for(ws.recv(), 30))
                if r.get("id") == my_id: return r

        async def js(expr):
            r = await send("Runtime.evaluate", {
                "expression": expr, "awaitPromise": True, "returnByValue": True
            })
            val = r.get("result",{}).get("result",{})
            return val.get("value") if "value" in val else None

        POLL_MS = 100

        async def poll(check_js, desc, timeout_s=15):
            deadline = time.monotonic() + timeout_s
            while time.monotonic() < deadline:
                v = await js(check_js)
                if v: return v
                await asyncio.sleep(POLL_MS / 1000)
            print(f"  TIMEOUT ({elapsed()}): {desc}", file=sys.stderr)
            return None

        # ── Step A: Navigate to Flux ──
        # Clear service worker + caches to ensure fresh JS is served
        await send("Storage.clearDataForOrigin", {
            "origin": FLUX_URL.rstrip('/'),
            "storageTypes": "service_workers,cache_storage"
        })

        # Enable console + network logging for diagnostics
        await send("Console.enable")
        await send("Runtime.enable")
        console_msgs = []

        async def drain_events():
            """Non-blocking drain of CDP events."""
            while True:
                try:
                    r = json.loads(await asyncio.wait_for(ws.recv(), 0.05))
                    if r.get("method") == "Runtime.consoleAPICalled":
                        args = r.get("params", {}).get("args", [])
                        msg = " ".join(str(a.get("value", a.get("description", ""))) for a in args)
                        if msg:
                            console_msgs.append(msg)
                    elif r.get("method") == "Runtime.exceptionThrown":
                        exc = r.get("params", {}).get("exceptionDetails", {})
                        txt = exc.get("text", "")
                        if exc.get("exception"):
                            txt += " " + str(exc["exception"].get("description", ""))
                        if txt:
                            console_msgs.append(f"[EXCEPTION] {txt}")
                except (asyncio.TimeoutError, Exception):
                    break
        print(f"  [{elapsed()}] Opening {FLUX_URL}...")
        await send("Page.navigate", {"url": FLUX_URL})

        # Wait for page to have a DOM
        await poll("""
            (function() {
                return document.readyState === 'complete' ? 'ready' : '';
            })()
        """, "page load", timeout_s=15)

        # ── Step B: Always inject fresh credentials ──
        # (Chrome profile may persist stale JWT from a previous executor run)
        print(f"  [{elapsed()}] Injecting auth credentials ({'REST' if USE_REST else 'GQL'})...")

        # First: clear ALL ad4m-related localStorage entries (stale keys from
        # other ad4m-connect versions would cause InvalidSignature errors)
        cleared = await js("""
            (function() {
                var removed = [];
                for (var i = localStorage.length - 1; i >= 0; i--) {
                    var k = localStorage.key(i);
                    if (k && k.includes('ad4m')) {
                        removed.push(k);
                        localStorage.removeItem(k);
                    }
                }
                return JSON.stringify(removed);
            })()
        """)
        print(f"  [{elapsed()}] Cleared stale keys: {cleared}")

        # Detect the actual ad4m-connect version from the bundled runtime
        # (may differ from the version in node_modules if build is cached)
        runtime_ver = await js("""
            (function() {
                var ac = document.querySelector('ad4m-connect');
                if (ac && ac.version) return ac.version;
                // Fallback: check what version keys exist in bundle by looking
                // for the ad4m-connect LitElement class
                return '';
            })()
        """) or ""

        versions_to_set = [CONNECT_VER]
        if runtime_ver and runtime_ver != CONNECT_VER:
            print(f"  [{elapsed()}] Runtime version differs: {runtime_ver} (detected from package: {CONNECT_VER})")
            versions_to_set.append(runtime_ver)

        if USE_REST:
            # REST mode: ad4m-connect uses HTTP URL + port
            for ver in versions_to_set:
                await js(f"""
                    (function() {{
                        localStorage.setItem('{ver}/ad4m-token', '{USER_JWT}');
                        localStorage.setItem('{ver}/ad4m-url', '{CONNECT_URL}');
                        localStorage.setItem('{ver}/ad4m-port', '{API_PORT}');
                        localStorage.setItem('{ver}/ad4m-last-host', JSON.stringify({{
                            id: 'injected-' + Date.now(),
                            url: '{CONNECT_URL}',
                            name: '127.0.0.1',
                            location: 'Custom URL'
                        }}));
                        return 'ok';
                    }})()
                """)
        else:
            # GQL mode: ad4m-connect uses WebSocket URL
            for ver in versions_to_set:
                await js(f"""
                    (function() {{
                        localStorage.setItem('{ver}/ad4m-token', '{USER_JWT}');
                        localStorage.setItem('{ver}/ad4m-url', '{CONNECT_URL}');
                        localStorage.setItem('{ver}/ad4m-last-host', JSON.stringify({{
                            id: 'injected-' + Date.now(),
                            url: '{CONNECT_URL}',
                            name: '127.0.0.1',
                            location: 'Custom URL'
                        }}));
                        return 'ok';
                    }})()
                """)
        print(f"  [{elapsed()}] Injected credentials for versions: {versions_to_set}")
        print(f"  [{elapsed()}] Credentials injected -- reloading...")

        # Reload to trigger ad4m-connect auto-reconnect
        await send("Page.navigate", {"url": FLUX_URL})
        await poll("""
            (function() {
                return document.readyState === 'complete' ? 'ready' : '';
            })()
        """, "reload", timeout_s=15)

        # Re-enable console capture after navigation
        await send("Console.enable")
        await send("Runtime.enable")
        console_msgs.clear()

        # Give app time to initialize before checking state
        await asyncio.sleep(3)
        await drain_events()

        # Check ad4m-connect element state directly
        ac_info = await js("""
            (async function() {
                var ac = document.querySelector('ad4m-connect');
                if (!ac) return JSON.stringify({error: 'no element'});
                var info = {
                    tagName: ac.tagName,
                    authState: ac.authState || null,
                    connectionState: ac.connectionState || null,
                    connected: ac.connected || null,
                    url: ac.url || null,
                    token: ac.token ? ac.token.substring(0, 30) + '...' : null,
                    port: ac.port || null,
                    client: !!ac.client,
                    shadowChildren: ac.shadowRoot ? ac.shadowRoot.children.length : 0,
                    shadowHTML: ac.shadowRoot ? ac.shadowRoot.innerHTML.substring(0, 300) : null,
                };
                return JSON.stringify(info);
            })()
        """)
        print(f"  [{elapsed()}] ad4m-connect state: {ac_info}")

        # Check if ad4m-connect wrote keys under a different version prefix
        # (if so, re-inject under the correct prefix)
        ls_versions = await js("""
            (function() {
                var vs = {};
                for (var i = 0; i < localStorage.length; i++) {
                    var k = localStorage.key(i);
                    if (k && k.includes('/ad4m-')) {
                        var ver = k.split('/ad4m-')[0];
                        vs[ver] = (vs[ver] || 0) + 1;
                    }
                }
                return JSON.stringify(vs);
            })()
        """) or "{}"
        detected_versions = json.loads(ls_versions)
        print(f"  [{elapsed()}] localStorage version prefixes: {detected_versions}")

        # If ad4m-connect wrote keys under a version we didn't inject for, re-inject
        our_versions = set(versions_to_set)
        other_versions = set(detected_versions.keys()) - our_versions
        if other_versions:
            print(f"  [{elapsed()}] Re-injecting credentials for runtime versions: {other_versions}")
            for ver in other_versions:
                if USE_REST:
                    await js(f"""
                        (function() {{
                            localStorage.setItem('{ver}/ad4m-token', '{USER_JWT}');
                            localStorage.setItem('{ver}/ad4m-url', '{CONNECT_URL}');
                            localStorage.setItem('{ver}/ad4m-port', '{API_PORT}');
                            localStorage.setItem('{ver}/ad4m-last-host', JSON.stringify({{
                                id: 'injected-' + Date.now(),
                                url: '{CONNECT_URL}',
                                name: '127.0.0.1',
                                location: 'Custom URL'
                            }}));
                            return 'ok';
                        }})()
                    """)
                else:
                    await js(f"""
                        (function() {{
                            localStorage.setItem('{ver}/ad4m-token', '{USER_JWT}');
                            localStorage.setItem('{ver}/ad4m-url', '{CONNECT_URL}');
                            localStorage.setItem('{ver}/ad4m-last-host', JSON.stringify({{
                                id: 'injected-' + Date.now(),
                                url: '{CONNECT_URL}',
                                name: '127.0.0.1',
                                location: 'Custom URL'
                            }}));
                            return 'ok';
                        }})()
                    """)
            # Reload again with correct credentials
            print(f"  [{elapsed()}] Reloading with corrected version...")
            await send("Page.navigate", {"url": FLUX_URL})
            await poll("""
                (function() { return document.readyState === 'complete' ? 'ready' : ''; })()
            """, "reload after version fix", timeout_s=15)
            await asyncio.sleep(5)
            await drain_events()

        # Quick diagnostic: can the browser reach the executor?
        http_url = f"http://127.0.0.1:{API_PORT}"
        fetch_check = await js(f"""
            (async function() {{
                try {{
                    var r = await fetch('{http_url}/graphql', {{
                        method: 'POST',
                        headers: {{'Content-Type': 'application/json'}},
                        body: JSON.stringify({{query: '{{ __typename }}' }})
                    }});
                    var d = await r.json();
                    return JSON.stringify({{ok: true, status: r.status, data: d}});
                }} catch(e) {{
                    return JSON.stringify({{error: e.message}});
                }}
            }})()
        """)
        print(f"  [{elapsed()}] Browser→Executor check: {fetch_check}")

        # ── Step D: Wait for ad4m-connect to initialize ──
        # Check the element's internal state, not just the URL hash
        print(f"  [{elapsed()}] Waiting for ad4m-connect to initialize...")

        ac_state = await poll("""
            (function() {
                var ac = document.querySelector('ad4m-connect');
                if (!ac || !ac.core) return '';
                // Check core connection state (currentView defaults to 'connection-options'
                // even on successful auth, so we must check core state instead)
                if (ac.core.authState === 'authenticated' && ac.core.connectionState === 'connected') {
                    return 'authenticated';
                }
                // Check internal LitElement properties for dashboard/logged-in views
                var view = ac.__currentView || ac.currentView || '';
                if (view && view !== 'connection-options') return view;
                // Fallback: check URL hash
                var h = document.location.hash;
                if (h && h.match(/^#\\/home/)) return 'at-home';
                if (h && h.match(/^#\\/communities/)) return 'at-home';
                if (h && h.match(/^#\\/signup/)) return 'at-signup';
                return '';
            })()
        """, "ad4m-connect init", timeout_s=20)
        print(f"  [{elapsed()}] ad4m-connect state: {ac_state}")

        # ── Step E: Dismiss any ad4m-connect modal and force auth completion ──
        if ac_state and ('authenticated' in ac_state or 'dashboard' in ac_state or 'logged-in' in ac_state):
            print(f"  [{elapsed()}] ad4m-connect connected -- dismissing modal + completing auth...")
            # Close modal and dispatch authstatechange so the
            # `await client` promise in app.ts resolves.
            await js("""
                (function() {
                    var ac = document.querySelector('ad4m-connect');
                    if (!ac) return;
                    ac.__modalOpen = false;
                    ac.modalOpen = false;
                    if (ac.core && ac.core.ad4mClient) {
                        ac.core.dispatchEvent(new CustomEvent('authstatechange', { detail: 'authenticated' }));
                    }
                })()
            """)

            # Wait for app to run setAdamClient → refreshMyProfile → getMyCommunities → initialized
            home = await poll("""
                (function() {
                    var h = document.location.hash;
                    return (h && (h.match(/^#\\/home/) || h.match(/^#\\/communities/))) ? h : '';
                })()
            """, "navigate to home after auth", timeout_s=30)
            if home:
                print(f"  [{elapsed()}] Navigated to: {home}")
            else:
                print(f"  [{elapsed()}] Hash: " + (await js("document.location.hash") or "empty"))

        elif ac_state == '':
            # Timed out waiting for ad4m-connect to initialize
            print(f"  ERROR: ad4m-connect did not connect within timeout", file=sys.stderr)
            print(f"  The JWT may be invalid or expired. Try re-running ad4m-flux-launch.sh", file=sys.stderr)
            sys.exit(1)

        # ── Step F: Handle signup page ──
        current_hash = await js("document.location.hash") or ""
        if current_hash.startswith('#/signup'):
            print(f"  [{elapsed()}] At signup -- reloading to pick up profile...")
            await send("Page.navigate", {"url": FLUX_URL})
            await poll("""
                (function() { return document.readyState === 'complete' ? 'ready' : ''; })()
            """, "reload", timeout_s=10)

            # Wait for ad4m-connect to reconnect
            ac_ready = await poll("""
                (function() {
                    var ac = document.querySelector('ad4m-connect');
                    if (!ac || !ac.core) return '';
                    if (ac.core.authState === 'authenticated' && ac.core.connectionState === 'connected') return 'authenticated';
                    var view = ac.__currentView || '';
                    return (view.includes('logged-in') || view.includes('dashboard')) ? view : '';
                })()
            """, "ad4m-connect reconnect", timeout_s=15)

            if ac_ready:
                print(f"  [{elapsed()}] ad4m-connect reconnected: {ac_ready}")
                # Dismiss modal + dispatch auth event
                await js("""
                    (function() {
                        var ac = document.querySelector('ad4m-connect');
                        if (!ac) return;
                        ac.__modalOpen = false;
                        ac.modalOpen = false;
                        if (ac.core && ac.core.ad4mClient) {
                            ac.core.dispatchEvent(new CustomEvent('authstatechange', { detail: 'authenticated' }));
                        }
                    })()
                """)

            home = await poll("""
                (function() {
                    var h = document.location.hash;
                    return (h && (h.match(/^#\\/home/) || h.match(/^#\\/communities/))) ? h : '';
                })()
            """, "navigate to home", timeout_s=30)

            if home:
                print(f"  [{elapsed()}] Navigated to: {home}")
            else:
                final_state = await js("""
                    (function() {
                        var ac = document.querySelector('ad4m-connect');
                        var app = document.querySelector('#app');
                        var vue = app && app.__vue_app__;
                        var pinia = vue && vue.config.globalProperties.$pinia;
                        var appStore = null;
                        if (pinia) pinia._s.forEach(function(s, k) { if (k === 'appStore') appStore = s; });
                        return JSON.stringify({
                            view: ac && (ac.__currentView || '') || 'none',
                            modal: ac && ac.__modalOpen,
                            coreClient: !!(ac && ac.core && ac.core.ad4mClient),
                            hash: document.location.hash,
                            initialized: appStore && appStore.initialized,
                        });
                    })()
                """) or "{}"
                print(f"  [{elapsed()}] Debug state: {final_state}")
                await drain_events()
                errs = [m for m in console_msgs if any(w in m.lower() for w in ['error', 'exception', 'fail', 'reject'])]
                if errs:
                    print(f"  [{elapsed()}] Console errors ({len(errs)}):")
                    for e in errs[:10]:
                        print(f"    {e[:200]}")

        # ── Step G: Final verification + auto-navigate to community ──
        # Dismiss credit modal one last time if needed
        await js("""
            (function() {
                var ac = document.querySelector('ad4m-connect');
                if (ac && ac.__modalOpen) { ac.__modalOpen = false; ac.modalOpen = false; }
            })()
        """)
        await asyncio.sleep(2)
        final_hash = await js("document.location.hash") or ""
        print(f"  [{elapsed()}] Final: {final_hash}")

        if final_hash and (final_hash.startswith('#/home') or '/communities' in final_hash):
            # Check that community is visible
            check = await js("""
                (async function() {
                    var app = document.querySelector('#app');
                    if (!app || !app.__vue_app__) return JSON.stringify({error: 'no vue'});
                    var pinia = app.__vue_app__.config.globalProperties.$pinia;
                    var appStore = null;
                    pinia._s.forEach(function(s, k) { if (k === 'appStore') appStore = s; });
                    if (!appStore) return JSON.stringify({error: 'no appStore'});
                    return JSON.stringify({
                        perspectives: appStore.ad4mClient ? (await appStore.ad4mClient.perspective.all()).length : 0,
                        communities: Object.keys(appStore.myCommunities || {}),
                        loaded: appStore.communitiesLoaded,
                    });
                })()
            """)
            if check:
                data = json.loads(check)
                comms = data.get('communities', [])
                print(f"  [{elapsed()}] Perspectives: {data.get('perspectives',0)}, Communities: {len(comms)}")

                # Auto-navigate to first community if at home
                if comms and 'home' in final_hash:
                    cid = comms[0]
                    # Strip protocol prefix for route — Vue Router uses clean UUIDs
                    route_id = cid.replace('neighbourhood://', '').replace('private://', '')
                    comm_url = f"{FLUX_URL}#/communities/{route_id}"
                    await send("Page.navigate", {"url": comm_url})
                    await asyncio.sleep(8)
                    nav_hash = await js("document.location.hash") or ""
                    print(f"  [{elapsed()}] Navigated to: {nav_hash}")
            print("  SUCCESS")
        else:
            print(f"  Page at: {final_hash} -- check browser")

asyncio.run(run())
PYEOF

RESULT=$?
if [[ $RESULT -eq 0 ]]; then
    ok "Flux authenticated and open"
else
    warn "Auth flow had issues — check output above"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Flux — Open in Browser"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Flux:       $FLUX_URL"
echo "  Executor:   $EXECUTOR_URL"
echo "  Email:      $EMAIL"
echo "  Password:   $PASSWORD"
echo ""
