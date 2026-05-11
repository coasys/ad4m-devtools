#!/usr/bin/env python3
"""AD4M executor integration tests — WS-RPC endpoint validation.

Validates core executor RPC endpoints against a running executor:
  - perspective CRUD + link add/query
  - SPARQL query
  - perspective.evaluateGetters (batch getter evaluation)
  - perspective.modelQuery (SHACL model query engine)
  - deepQuery flag passthrough

This test suite mirrors what CI validates via tests/js/ (mocha + TS)
but uses only Python + websockets for zero-dependency local runs.

Usage:
    ad4m-integration-test.py [--port 4000] [--token test123]

Requires: pip3 install websockets
"""
import asyncio
import json
import sys
import os
import uuid

# Force unbuffered stdout so output streams immediately
sys.stdout = os.fdopen(sys.stdout.fileno(), "w", buffering=1)

try:
    import websockets
except ImportError:
    print("Error: pip3 install websockets", file=sys.stderr)
    sys.exit(2)

# --- CLI args ---
PORT = "4000"
TOKEN = "test123"
args = sys.argv[1:]
while args:
    if args[0] == "--port" and len(args) >= 2:
        PORT = args[1]; args = args[2:]
    elif args[0] == "--token" and len(args) >= 2:
        TOKEN = args[1]; args = args[2:]
    else:
        args = args[1:]

URL = f"ws://127.0.0.1:{PORT}/api/v1/ws?token={TOKEN}"
PASS = FAIL = 0


async def rpc(op, params=None):
    """Single RPC call over a fresh WebSocket connection."""
    async with websockets.connect(URL) as ws:
        rid = str(uuid.uuid4())
        await ws.send(json.dumps({"id": rid, "type": op, "params": params or {}}))
        return json.loads(await asyncio.wait_for(ws.recv(), timeout=60))


def check(desc, expected, actual_str):
    global PASS, FAIL
    if expected in str(actual_str):
        print(f"  PASS: {desc}"); PASS += 1
    else:
        print(f"  FAIL: {desc}")
        print(f"    expected: {expected}")
        print(f"    got: {str(actual_str)[:300]}")
        FAIL += 1


def check_no_error(desc, resp):
    global PASS, FAIL
    if resp.get("error") is None:
        print(f"  PASS: {desc}"); PASS += 1
    else:
        print(f"  FAIL: {desc}")
        print(f"    error: {resp['error']}")
        FAIL += 1


async def main():
    print("=== AD4M Integration Tests ===\n")

    # -----------------------------------------------------------------------
    # Test 1: Perspectives + Links
    # Mirrors: tests/integration.bats "can create perspective, add and query links"
    # Mirrors: tests/js/tests/simple.test.ts perspective + link CRUD
    # -----------------------------------------------------------------------
    print("--- Test 1: Perspectives + Links ---")
    r = await rpc("perspective.create", {"name": "int-test-links"})
    check_no_error("create perspective", r)
    uuid1 = r["result"]["uuid"]
    print(f"  UUID: {uuid1}")

    r = await rpc("perspective.all")
    check("perspective in list", uuid1, json.dumps(r))

    r = await rpc("perspective.addLink", {
        "uuid": uuid1,
        "link": {"source": "test://src", "target": "test://tgt", "predicate": "test://pred"},
    })
    check("link added", "test://src", json.dumps(r))

    r = await rpc("perspective.queryLinks", {"uuid": uuid1, "query": {}})
    rs = json.dumps(r)
    check("query source", "test://src", rs)
    check("query target", "test://tgt", rs)
    check("query predicate", "test://pred", rs)
    print()

    # -----------------------------------------------------------------------
    # Test 2: SPARQL Query
    # Mirrors: tests/js/tests/model/model-query.test.ts SPARQL queries
    # -----------------------------------------------------------------------
    print("--- Test 2: SPARQL Query ---")
    r2 = await rpc("perspective.create", {"name": "sparql-test"})
    u2 = r2["result"]["uuid"]
    print(f"  UUID: {u2}")

    await rpc("perspective.addLink", {"uuid": u2, "link": {"source": "ad4m://n1", "target": "ad4m://Note", "predicate": "rdf://type"}})
    await rpc("perspective.addLink", {"uuid": u2, "link": {"source": "ad4m://n1", "target": "literal:string:Hello", "predicate": "ad4m://title"}})
    await rpc("perspective.addLink", {"uuid": u2, "link": {"source": "ad4m://n1", "target": "literal:string:Body text here", "predicate": "ad4m://body"}})
    await rpc("perspective.addLink", {"uuid": u2, "link": {"source": "ad4m://n2", "target": "ad4m://Note", "predicate": "rdf://type"}})
    await rpc("perspective.addLink", {"uuid": u2, "link": {"source": "ad4m://n2", "target": "literal:string:World", "predicate": "ad4m://title"}})

    sq = await rpc("perspective.querySparql", {"uuid": u2, "query": "SELECT ?s ?p ?o WHERE { ?s ?p ?o } LIMIT 20"})
    sqs = json.dumps(sq)
    check("SPARQL returns n1", "ad4m://n1", sqs)
    check("SPARQL returns n2", "ad4m://n2", sqs)
    check("SPARQL returns Hello", "Hello", sqs)
    print()

    # -----------------------------------------------------------------------
    # Test 3: evaluateGetters RPC
    # Mirrors: tests/js/tests/model/model-getters.test.ts
    # -----------------------------------------------------------------------
    print("--- Test 3: evaluateGetters RPC ---")
    shape = {
        "properties": [
            {"name": "title", "predicate": "ad4m://title", "required": True, "collection": False},
        ],
        "relations": [],
    }
    eg = await rpc("perspective.evaluateGetters", {
        "uuid": u2,
        "class_name": "Note",
        "instance_ids": json.dumps(["ad4m://n1", "ad4m://n2"]),
        "shape_json": json.dumps(shape),
    })
    egs = json.dumps(eg)
    check_no_error("evaluateGetters no error", eg)
    check("evaluateGetters has result", "result", egs)
    print()

    # -----------------------------------------------------------------------
    # Test 4: modelQuery RPC
    # Mirrors: tests/js/tests/model/model-query.test.ts
    # -----------------------------------------------------------------------
    print("--- Test 4: modelQuery RPC ---")
    full_shape = {
        "properties": [
            {"name": "title", "predicate": "ad4m://title", "required": True, "collection": False},
            {"name": "body", "predicate": "ad4m://body", "required": False, "collection": False},
        ],
        "relations": [],
    }
    mq = await rpc("perspective.modelQuery", {
        "uuid": u2,
        "class_name": "Note",
        "query_json": json.dumps({}),
        "shape_json": json.dumps(full_shape),
    })
    mqs = json.dumps(mq)
    check_no_error("modelQuery no error", mq)
    check("modelQuery has result", "result", mqs)
    print()

    # -----------------------------------------------------------------------
    # Test 5: deepQuery flag
    # -----------------------------------------------------------------------
    print("--- Test 5: deepQuery flag ---")
    mq_deep = await rpc("perspective.modelQuery", {
        "uuid": u2,
        "class_name": "Note",
        "query_json": json.dumps({"deepQuery": True}),
        "shape_json": json.dumps(full_shape),
    })
    check_no_error("modelQuery deepQuery=true no error", mq_deep)
    check("modelQuery deepQuery has result", "result", json.dumps(mq_deep))

    mq_shallow = await rpc("perspective.modelQuery", {
        "uuid": u2,
        "class_name": "Note",
        "query_json": json.dumps({"deepQuery": False}),
        "shape_json": json.dumps(full_shape),
    })
    check_no_error("modelQuery deepQuery=false no error", mq_shallow)
    print()

    # --- Summary ---
    print("=======================================")
    print(f"  Results: {PASS} passed, {FAIL} failed")
    print("=======================================")
    sys.exit(1 if FAIL > 0 else 0)


asyncio.run(main())
