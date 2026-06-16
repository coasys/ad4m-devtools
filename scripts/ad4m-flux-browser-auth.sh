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
CHROME_LOG_FILE="/tmp/ad4m-chrome-launch.log"
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
        --chrome-log-file) CHROME_LOG_FILE="$2"; shift 2;;
        --connect-version) CONNECT_VERSION="$2"; shift 2;;
        --flux-dir) FLUX_DIR="$2"; shift 2;;
        --no-launch) DO_LAUNCH=false; shift;;
        --skip-create-user) SKIP_CREATE_USER=true; shift;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'; exit 0;;
        *) err "Unknown option: $1";;
    esac
done

API_PORT=$(echo "$EXECUTOR_URL" | grep -oE '[0-9]+$')
WS_URL="ws://127.0.0.1:${API_PORT}/api/v1/ws"
HEALTH_URL="$EXECUTOR_URL/health"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_RPC="$SCRIPT_DIR/ad4m-ws-rpc.py"

# --- Check executor is ready ---
if ! curl -sf "$HEALTH_URL" >/dev/null 2>&1; then
    err "Executor not ready (health check failed at $HEALTH_URL)"
fi

# Connection URL for ad4m-connect localStorage injection (HTTP base — ad4m-connect derives WS internally)
CONNECT_URL="$EXECUTOR_URL"
ok "Executor running (WebSocket RPC)"

# --- Step 2: Verify Flux ---
log "Checking Flux..."
curl -sf "$FLUX_URL" >/dev/null || err "Flux not responding at $FLUX_URL"
ok "Flux serving"

# --- Step 3: Create test user ---
if ! $SKIP_CREATE_USER; then
    log "Ensuring test user exists: $EMAIL"
    python3 "$WS_RPC" --url "$WS_URL" --token "$ADMIN_CREDENTIAL" \
        "user.create" "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" >/dev/null 2>&1 || true
    ok "User ready"
fi

# --- Step 4: Get user JWT ---
log "Logging in as $EMAIL..."
USER_JWT=$(python3 "$WS_RPC" --url "$WS_URL" --token "$ADMIN_CREDENTIAL" \
    "user.login" "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" 2>/dev/null \
    | python3 -c "import sys,json; r=json.load(sys.stdin); print(r if isinstance(r,str) else '')" 2>/dev/null) || USER_JWT=""
USER_JWT=$(echo "$USER_JWT" | sed 's/^"//;s/"$//')
[[ -n "$USER_JWT" ]] || err "Login failed for $EMAIL"
ok "JWT obtained (${#USER_JWT} chars)"

# Note: the Flux profile is created through the actual signup UI later (Step F),
# by filling the username field and clicking "Create user". Driving Flux's own
# createProfile() guarantees the profile links match exactly what Flux expects —
# unlike a hand-rolled WS-RPC link, which Flux did not recognise (it stayed on
# the signup page). If a profile already exists, Flux skips signup and Step F
# is a no-op.

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
    # Note: minifiers may rename the key param (e.g. key→key2), so use \w+ not [a-z]
    m = re.search(r'localStorage\.setItem\(`\$\{(\w+\$?\d*)\}/\$\{\w+\}`', bundle)
    if not m:
        sys.exit(1)

    var_escaped = re.escape(m.group(1))
    # Find: VAR = "version-string" (may have spaces around = in non-fully-minified builds)
    m = re.search(var_escaped + r'\s*=\s*"([^"]+)"', bundle)
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
        ok "Browser already on CDP port $CDP_PORT"
    else
        log "Launching Chromium..."
        # Prefer Chromium; fall back to Google Chrome if Chromium isn't installed.
        # Note: snap chromium works with the default /tmp profile (its private mount
        # namespace + --use-fake-ui-for-media-stream cover the camera/mic prompt).
        CHROME_BIN=""
        if [[ -d "/Applications/Chromium.app" ]]; then
            CHROME_BIN="/Applications/Chromium.app/Contents/MacOS/Chromium"
        elif command -v chromium &>/dev/null; then
            CHROME_BIN="$(command -v chromium)"
        elif command -v chromium-browser &>/dev/null; then
            CHROME_BIN="$(command -v chromium-browser)"
        elif [[ -d "/Applications/Google Chrome.app" ]]; then
            CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        elif command -v google-chrome &>/dev/null; then
            CHROME_BIN="google-chrome"
        fi
        [[ -n "$CHROME_BIN" ]] || err "Chromium (or Chrome) not found"

        prepare_profile_permissions() {
            local profile_dir="$1"
            mkdir -p "$profile_dir/Default"
            local prefs_file="$profile_dir/Default/Preferences"
            if [[ ! -f "$prefs_file" ]]; then
                cat > "$prefs_file" <<'PREFS'
{}
PREFS
            fi

            # Grant camera/microphone for localhost + 127.0.0.1 origins.
            # Keep real devices (no fake media device flag).
            python3 - <<PYEOF
import json
prefs_path = "$prefs_file"
try:
    with open(prefs_path, "r", encoding="utf-8") as f:
        prefs = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    prefs = {}

profile = prefs.setdefault("profile", {})
defaults = profile.setdefault("default_content_setting_values", {})
defaults["media_stream_mic"] = 1
defaults["media_stream_camera"] = 1

cs = profile.setdefault("content_settings", {})
exceptions = cs.setdefault("exceptions", {})
mic = exceptions.setdefault("media_stream_mic", {})
cam = exceptions.setdefault("media_stream_camera", {})

patterns = [
    "https://localhost,*",
    "https://127.0.0.1,*",
    "http://localhost,*",
    "http://127.0.0.1,*",
]
for p in patterns:
    mic[p] = {"setting": 1}
    cam[p] = {"setting": 1}

with open(prefs_path, "w", encoding="utf-8") as f:
    json.dump(prefs, f)
PYEOF
        }

        launch_chrome() {
            local profile_dir="$1"
            prepare_profile_permissions "$profile_dir"
            # Detach the browser into its own session so it survives this script
            # exiting (success OR failure) and the VSCode task tearing down its
            # process group. setsid (Linux) starts a new session; nohup is the
            # macOS fallback. disown removes it from the shell's job table so no
            # SIGHUP is sent on exit. Result: the window stays open no matter what.
            local detach=()
            if command -v setsid >/dev/null 2>&1; then
                detach=(setsid)
            elif command -v nohup >/dev/null 2>&1; then
                detach=(nohup)
            fi
            "${detach[@]}" "$CHROME_BIN" \
                --remote-debugging-port="$CDP_PORT" \
                --user-data-dir="$profile_dir" \
                --no-first-run \
                --no-default-browser-check \
                --remote-allow-origins='*' \
                --use-fake-ui-for-media-stream \
                "about:blank" </dev/null >>"$CHROME_LOG_FILE" 2>&1 &
            disown 2>/dev/null || true
        }

        : > "$CHROME_LOG_FILE"
        launch_chrome "$CHROME_PROFILE"

        for i in $(seq 1 15); do
            curl -sf "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1 && break
            sleep 1
        done
        if ! curl -sf "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1; then
            warn "Chromium launch failed with profile $CHROME_PROFILE, retrying with fresh profile"
            CHROME_PROFILE="${CHROME_PROFILE}-fresh-${CDP_PORT}"
            rm -rf "$CHROME_PROFILE"
            launch_chrome "$CHROME_PROFILE"
            for i in $(seq 1 15); do
                curl -sf "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1 && break
                sleep 1
            done
        fi
        curl -sf "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1 || err "Chromium didn't start (see $CHROME_LOG_FILE)"
        ok "Chromium launched"
    fi
else
    curl -sf "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1 || err "No CDP on port $CDP_PORT"
    ok "Browser CDP on port $CDP_PORT"
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

python3 - "$CDP_PORT" "$FLUX_URL" "$CONNECT_URL" "$USER_JWT" "$CONNECT_VERSION" "$API_PORT" "$EMAIL" << 'PYEOF'
import asyncio, json, sys, time, urllib.request
import websockets

CDP_PORT       = sys.argv[1]
FLUX_URL       = sys.argv[2]
CONNECT_URL    = sys.argv[3]
USER_JWT       = sys.argv[4]
CONNECT_VER    = sys.argv[5]
API_PORT       = sys.argv[6]
EMAIL          = sys.argv[7] if len(sys.argv) > 7 else "dev@test.com"
# Username for the Flux signup form (must be >= 3 chars per SignUp.vue validation)
USERNAME       = (EMAIL.split("@")[0] or "dev")
if len(USERNAME) < 3:
    USERNAME = (USERNAME + "dev")[:8]
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
        print(f"  [{elapsed()}] Injecting auth credentials...")

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

        # Inject token + URL + port + last-host for each version
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
                    var r = await fetch('{http_url}/health');
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

            # Wait for app to run setAdamClient → refreshMyProfile → getMyCommunities → initialized.
            # A user with no profile lands on #/signup — return on that too so we don't
            # burn the full timeout before Step F drives the signup form.
            home = await poll("""
                (function() {
                    var h = document.location.hash;
                    return (h && (h.match(/^#\\/home/) || h.match(/^#\\/communities/) || h.match(/^#\\/signup/))) ? h : '';
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

        # ── Step F: Handle signup page — fill the profile form and submit ──
        # A new agent has no Flux profile, so the router lands on #/signup
        # (SignUp.vue). Drive its form: type the username into <j-input> and
        # click the <j-button> "Create user". This runs Flux's own createProfile(),
        # which writes exactly the profile links Flux expects, then navigates home.
        current_hash = await js("document.location.hash") or ""
        if current_hash.startswith('#/signup'):
            print(f"  [{elapsed()}] At signup — filling profile form (username: {USERNAME})...")

            # Set the username. <j-input> is a custom element whose real <input>
            # lives in shadow DOM; Vue binds via @input reading e.target.value.
            # Drive the inner native input so the component's own handler fires
            # and Vue's reactive `username` updates (enabling the submit button).
            fill_expr = """
                (function() {
                    var inp = document.querySelector('j-input[label="Username"]')
                              || document.querySelector('j-input');
                    if (!inp) return '';
                    var v = __UNAME__;
                    var native = inp.shadowRoot && inp.shadowRoot.querySelector('input');
                    if (native) {
                        var setter = Object.getOwnPropertyDescriptor(
                            window.HTMLInputElement.prototype, 'value').set;
                        setter.call(native, v);
                        native.dispatchEvent(new Event('input', { bubbles: true }));
                        native.dispatchEvent(new Event('change', { bubbles: true }));
                    }
                    inp.value = v;
                    inp.dispatchEvent(new CustomEvent('input', { bubbles: true, composed: true }));
                    inp.dispatchEvent(new CustomEvent('blur', { bubbles: true, composed: true }));
                    return 'filled';
                })()
            """.replace('__UNAME__', json.dumps(USERNAME))
            filled = await poll(fill_expr, "fill username field", timeout_s=15)
            print(f"  [{elapsed()}] Username field: {filled or 'NOT FOUND'}")

            # Click "Create user" once the form considers it valid (button enabled).
            clicked = await poll("""
                (function() {
                    var btns = Array.prototype.slice.call(document.querySelectorAll('j-button'));
                    var btn = btns.filter(function(b) {
                        return /create user/i.test(b.textContent || '');
                    })[0] || document.querySelector('j-button[variant="primary"]');
                    if (!btn) return '';
                    if (btn.hasAttribute('disabled') || btn.disabled || btn.loading) return '';
                    btn.click();
                    return 'clicked';
                })()
            """, "click Create user button", timeout_s=15)
            print(f"  [{elapsed()}] Create user button: {clicked or 'NOT CLICKED (still disabled?)'}")

            # createProfile() resolves then routes to #/home (or a redirect).
            home = await poll("""
                (function() {
                    var h = document.location.hash;
                    return (h && (h.match(/^#\\/home/) || h.match(/^#\\/communities/))) ? h : '';
                })()
            """, "navigate to home after signup", timeout_s=30)

            if home:
                print(f"  [{elapsed()}] Profile created — navigated to: {home}")
            else:
                print(f"  [{elapsed()}] Still at: " + (await js("document.location.hash") or "empty"))
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
