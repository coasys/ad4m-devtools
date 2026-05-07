#!/usr/bin/env python3
"""Minimal WebSocket RPC client for AD4M executor.

Usage:
    ad4m-ws-rpc.py --url ws://127.0.0.1:12000/api/v1/ws --token TOKEN OPERATION [JSON_PARAMS]

Examples:
    ad4m-ws-rpc.py --url ws://127.0.0.1:12000/api/v1/ws --token test123 agent.status
    ad4m-ws-rpc.py --url ws://127.0.0.1:12000/api/v1/ws --token test123 agent.generate '{"passphrase":"test"}'
    ad4m-ws-rpc.py --url ws://127.0.0.1:12000/api/v1/ws --token test123 user.create '{"email":"a@b.com","password":"pw"}'

Output: JSON result on success, exits 0. On error, prints error JSON, exits 1.
"""

import asyncio
import json
import sys
import uuid

try:
    import websockets
except ImportError:
    print("Error: 'websockets' package required. Install with: pip3 install websockets", file=sys.stderr)
    sys.exit(2)


async def rpc_call(url: str, token: str, operation: str, params: dict) -> dict:
    ws_url = f"{url}?token={token}" if "?" not in url else f"{url}&token={token}"
    async with websockets.connect(ws_url) as ws:
        req_id = str(uuid.uuid4())
        msg = json.dumps({"id": req_id, "type": operation, "params": params})
        await ws.send(msg)
        resp_raw = await asyncio.wait_for(ws.recv(), timeout=30)
        return json.loads(resp_raw)


def main():
    args = sys.argv[1:]
    url = "ws://127.0.0.1:12000/api/v1/ws"
    token = ""
    
    # Parse named args
    while args and args[0].startswith("--"):
        if args[0] == "--url" and len(args) >= 2:
            url = args[1]
            args = args[2:]
        elif args[0] == "--token" and len(args) >= 2:
            token = args[1]
            args = args[2:]
        else:
            print(f"Unknown option: {args[0]}", file=sys.stderr)
            sys.exit(2)
    
    if not args:
        print("Usage: ad4m-ws-rpc.py [--url URL] [--token TOKEN] OPERATION [JSON_PARAMS]", file=sys.stderr)
        sys.exit(2)
    
    operation = args[0]
    params = json.loads(args[1]) if len(args) > 1 else {}
    
    resp = asyncio.run(rpc_call(url, token, operation, params))
    
    if "error" in resp and resp["error"] is not None:
        print(json.dumps(resp["error"]))
        sys.exit(1)
    
    result = resp.get("result", resp)
    print(json.dumps(result))
    sys.exit(0)


if __name__ == "__main__":
    main()
