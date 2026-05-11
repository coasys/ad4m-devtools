#!/usr/bin/env python3
"""
ad4m-perspective-tool — Import and export AD4M perspectives as JSON snapshots.

All operations use WebSocket RPC (ws://host:port/api/v1/ws).

Usage:
  Export:  ad4m-perspective-tool export <uuid> [--output <file>] [--url <ws_url>] [--auth <credential>]
  Import:  ad4m-perspective-tool import <file> [--name <name>] [--url <ws_url>] [--auth <credential>]

Examples:
  ad4m-perspective-tool export fdc3f69d-... --output snapshot.json
  ad4m-perspective-tool import snapshot.json --name "Test Community"
  ad4m-perspective-tool import snapshot.json --url ws://127.0.0.1:12000/api/v1/ws --auth test123
"""

import argparse
import asyncio
import json
import sys
import time
import uuid as uuid_mod

try:
    import websockets
except ImportError:
    print("Error: 'websockets' package required. Install: pip3 install websockets", file=sys.stderr)
    sys.exit(2)

DEFAULT_URL = "ws://127.0.0.1:12000/api/v1/ws"
DEFAULT_AUTH = "test123"
BATCH_SIZE = 500


async def ws_rpc(url, auth, operation, params=None):
    """Make a single WebSocket RPC call."""
    ws_url = f"{url}?token={auth}" if "?" not in url else f"{url}&token={auth}"
    async with websockets.connect(ws_url) as ws:
        req_id = str(uuid_mod.uuid4())
        msg = {"id": req_id, "type": operation, "params": params or {}}
        await ws.send(json.dumps(msg))
        resp = json.loads(await asyncio.wait_for(ws.recv(), timeout=30))
        if "error" in resp and resp["error"] is not None:
            raise RuntimeError(f"WS RPC error ({operation}): {resp['error']}")
        return resp.get("result", resp)


async def ws_rpc_multi(url, auth, calls):
    """Send multiple RPC calls over a single WebSocket connection.

    calls: list of (operation, params) tuples
    Returns list of results in the same order.
    """
    ws_url = f"{url}?token={auth}" if "?" not in url else f"{url}&token={auth}"
    async with websockets.connect(ws_url, max_size=50 * 1024 * 1024) as ws:
        results = []
        for operation, params in calls:
            req_id = str(uuid_mod.uuid4())
            msg = {"id": req_id, "type": operation, "params": params or {}}
            await ws.send(json.dumps(msg))
            resp = json.loads(await asyncio.wait_for(ws.recv(), timeout=120))
            if "error" in resp and resp["error"] is not None:
                raise RuntimeError(f"WS RPC error ({operation}): {resp['error']}")
            results.append(resp.get("result", resp))
        return results


def cmd_export(args):
    uuid = args.uuid

    # Get perspective metadata
    perspective = asyncio.run(ws_rpc(args.url, args.auth, "perspective.get", {"uuid": uuid}))
    if not perspective:
        print(f"Error: Perspective {uuid} not found", file=sys.stderr)
        sys.exit(1)

    # Get all links via snapshot
    snapshot = asyncio.run(ws_rpc(args.url, args.auth, "perspective.snapshot", {"uuid": uuid}))
    links = snapshot.get("links", []) if isinstance(snapshot, dict) else snapshot

    export = {
        "uuid": perspective.get("uuid", uuid),
        "name": perspective.get("name", ""),
        "sharedUrl": perspective.get("sharedUrl"),
        "state": perspective.get("state"),
        "neighbourhood": perspective.get("neighbourhood"),
        "links": links,
    }

    json_str = json.dumps(export, indent=2)

    if args.output:
        with open(args.output, "w") as f:
            f.write(json_str)
        print(f"\033[32mExported perspective {uuid} to {args.output}\033[0m", file=sys.stderr)
        print(f"Links: {len(links)}", file=sys.stderr)
    else:
        print(json_str)


def cmd_import(args):
    with open(args.file) as f:
        snap = json.load(f)

    name = args.name or snap.get("name") or "Imported Perspective"
    links = snap.get("links", [])

    # Create perspective
    result = asyncio.run(ws_rpc(args.url, args.auth, "perspective.create", {"name": name}))
    p_uuid = result["uuid"]

    print(f"\033[32mCreated perspective: {p_uuid}\033[0m", file=sys.stderr)
    print(f"Name: {name}", file=sys.stderr)
    print(f"Links to import: {len(links)}", file=sys.stderr)

    # Use deferred batch API: links queue in memory (no disk I/O, no Prolog,
    # no pubsub) until commitBatch persists everything at once.
    total = len(links)
    start = time.time()

    async def _batch_import():
        ws_url = f"{args.url}?token={args.auth}" if "?" not in args.url else f"{args.url}&token={args.auth}"
        async with websockets.connect(ws_url, max_size=50 * 1024 * 1024) as ws:
            async def rpc(op, params):
                req_id = str(uuid_mod.uuid4())
                await ws.send(json.dumps({"id": req_id, "type": op, "params": params}))
                resp = json.loads(await asyncio.wait_for(ws.recv(), timeout=120))
                if "error" in resp and resp["error"] is not None:
                    raise RuntimeError(f"WS RPC error ({op}): {resp['error']}")
                return resp.get("result", resp)

            # Start deferred batch
            batch_id = await rpc("perspective.createBatch", {"uuid": p_uuid})

            # Queue links in batches (all in memory, no I/O)
            for i in range(0, total, BATCH_SIZE):
                batch = links[i:i + BATCH_SIZE]
                link_inputs = [{
                    "source": (l.get("data") or l)["source"],
                    "predicate": (l.get("data") or l).get("predicate", ""),
                    "target": (l.get("data") or l)["target"],
                } for l in batch]

                await rpc("perspective.addLinks", {
                    "uuid": p_uuid,
                    "links": link_inputs,
                    "batchId": batch_id,
                })

                done = min(i + BATCH_SIZE, total)
                elapsed = time.time() - start
                rate = done / elapsed if elapsed > 0 else 0
                print(f"\r  Queued {done}/{total} links ({rate:.0f} links/s)", end="", file=sys.stderr)

            # Commit: single atomic persist + Prolog + pubsub
            print(f"\n  Committing...", end="", file=sys.stderr)
            await rpc("perspective.commitBatch", {
                "uuid": p_uuid,
                "batchId": batch_id,
            })

    asyncio.run(_batch_import())

    elapsed = time.time() - start
    print(file=sys.stderr)
    print(f"\033[32m✅ Imported {total} links in {elapsed:.1f}s\033[0m", file=sys.stderr)
    print(f"Perspective UUID: {p_uuid}", file=sys.stderr)

    # Print UUID to stdout for scripting
    print(p_uuid)


def main():
    parser = argparse.ArgumentParser(
        description="Import and export AD4M perspectives as JSON snapshots (WebSocket RPC)")
    parser.add_argument("--url", default=DEFAULT_URL,
                       help=f"WebSocket RPC endpoint (default: {DEFAULT_URL})")
    parser.add_argument("--auth", default=DEFAULT_AUTH,
                       help="Admin credential or JWT")
    # Legacy flags (ignored, WS is the only mode now)
    parser.add_argument("--ws", action="store_true", default=True,
                       help=argparse.SUPPRESS)
    parser.add_argument("--rest", action="store_true",
                       help=argparse.SUPPRESS)

    sub = parser.add_subparsers(dest="command", required=True)

    exp = sub.add_parser("export", help="Export a perspective to JSON")
    exp.add_argument("uuid", help="Perspective UUID")
    exp.add_argument("--output", "-o", help="Output file (stdout if omitted)")

    imp = sub.add_parser("import", help="Import a perspective from JSON")
    imp.add_argument("file", help="Path to JSON snapshot file")
    imp.add_argument("--name", "-n", help="Override perspective name")

    args = parser.parse_args()

    if args.command == "export":
        cmd_export(args)
    elif args.command == "import":
        cmd_import(args)


if __name__ == "__main__":
    main()
