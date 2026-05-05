#!/usr/bin/env python3
"""
ad4m-perspective-tool — Import and export AD4M perspectives as JSON snapshots.

Usage:
  Export:  ad4m-perspective-tool export <uuid> [--output <file>] [--url <gql_url>] [--auth <credential>]
  Import:  ad4m-perspective-tool import <file> [--name <name>] [--url <gql_url>] [--auth <credential>]

Examples:
  ad4m-perspective-tool export fdc3f69d-... --output snapshot.json
  ad4m-perspective-tool import snapshot.json --name "Test Community"
  ad4m-perspective-tool import snapshot.json --url http://localhost:12000/graphql --auth test123
"""

import argparse
import json
import sys
import time
import urllib.request

DEFAULT_URL = "http://127.0.0.1:12000/graphql"
DEFAULT_AUTH = "test123"
BATCH_SIZE = 500


def gql(url, auth, query, variables=None):
    body = json.dumps({"query": query, "variables": variables or {}}).encode()
    req = urllib.request.Request(url, body, {
        "Content-Type": "application/json",
        "authorization": auth,
    })
    resp = urllib.request.urlopen(req)
    data = json.loads(resp.read())
    if data.get("errors"):
        raise Exception(f"GraphQL error: {json.dumps(data['errors'], indent=2)}")
    return data["data"]


def rest_request(base_url, auth, method, path, body=None):
    """Make a REST API request. Returns parsed JSON."""
    url = f"{base_url}{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data, {
        "Content-Type": "application/json",
        "authorization": auth,
    })
    req.method = method
    resp = urllib.request.urlopen(req)
    raw = resp.read()
    if not raw:
        return None
    return json.loads(raw)


def cmd_export(args):
    uuid = args.uuid

    # Get perspective metadata
    meta = gql(args.url, args.auth, """
        query($uuid: String!) {
            perspective(uuid: $uuid) {
                uuid name sharedUrl state
                neighbourhood {
                    author
                    data {
                        linkLanguage
                        meta {
                            links {
                                author timestamp
                                data { source predicate target }
                                proof { valid signature key }
                            }
                        }
                    }
                }
            }
        }
    """, {"uuid": uuid})

    perspective = meta.get("perspective")
    if not perspective:
        print(f"Error: Perspective {uuid} not found", file=sys.stderr)
        sys.exit(1)

    # Get all links via snapshot
    snap = gql(args.url, args.auth, """
        query($uuid: String!) {
            perspectiveSnapshot(uuid: $uuid) {
                links {
                    author timestamp
                    data { source predicate target }
                    proof { signature key }
                    status
                }
            }
        }
    """, {"uuid": uuid})

    links = snap.get("perspectiveSnapshot", {}).get("links", [])

    export = {
        "uuid": perspective["uuid"],
        "name": perspective["name"],
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


def cmd_import_rest(args, name, links):
    """Import a perspective using REST API instead of GraphQL."""
    base_url = args.url

    # Create perspective: POST /perspectives
    result = rest_request(base_url, args.auth, "POST", "/perspectives", {"name": name})
    uuid = result["uuid"]

    print(f"\033[32mCreated perspective: {uuid}\033[0m", file=sys.stderr)
    print(f"Name: {name}", file=sys.stderr)
    print(f"Links to import: {len(links)}", file=sys.stderr)

    # Bulk add links in batches: POST /perspectives/:uuid/links/bulk
    total = len(links)
    start = time.time()

    for i in range(0, total, BATCH_SIZE):
        batch = links[i:i + BATCH_SIZE]
        link_inputs = []
        for l in batch:
            d = l.get("data", l)
            link_inputs.append({
                "source": d["source"],
                "predicate": d.get("predicate", ""),
                "target": d["target"],
            })

        rest_request(base_url, args.auth, "POST",
                     f"/perspectives/{uuid}/links/bulk",
                     {"links": link_inputs})

        done = min(i + BATCH_SIZE, total)
        elapsed = time.time() - start
        rate = done / elapsed if elapsed > 0 else 0
        print(f"\r  Added {done}/{total} links ({rate:.0f} links/s)", end="", file=sys.stderr)

    elapsed = time.time() - start
    print(file=sys.stderr)
    print(f"\n\033[32m✅ Imported {total} links in {elapsed:.1f}s (REST)\033[0m", file=sys.stderr)
    print(f"Perspective UUID: {uuid}", file=sys.stderr)

    # Print UUID to stdout for scripting
    print(uuid)


def cmd_import(args):
    with open(args.file) as f:
        snap = json.load(f)

    name = args.name or snap.get("name") or "Imported Perspective"
    links = snap.get("links", [])

    if args.rest:
        return cmd_import_rest(args, name, links)

    # Create perspective
    result = gql(args.url, args.auth,
        'mutation($n:String!){perspectiveAdd(name:$n){uuid name}}',
        {"n": name})
    uuid = result["perspectiveAdd"]["uuid"]

    print(f"\033[32mCreated perspective: {uuid}\033[0m", file=sys.stderr)
    print(f"Name: {name}", file=sys.stderr)
    print(f"Links to import: {len(links)}", file=sys.stderr)

    # Bulk add links in batches
    total = len(links)
    start = time.time()

    for i in range(0, total, BATCH_SIZE):
        batch = links[i:i + BATCH_SIZE]
        link_inputs = []
        for l in batch:
            d = l.get("data", l)  # Support both {data: {source,target}} and flat {source,target}
            link_inputs.append({
                "source": d["source"],
                "predicate": d.get("predicate", ""),
                "target": d["target"],
            })

        gql(args.url, args.auth, '''
            mutation($uuid:String!, $links:[LinkInput!]!) {
                perspectiveAddLinks(uuid:$uuid, links:$links) {
                    author timestamp data { source predicate target }
                }
            }
        ''', {"uuid": uuid, "links": link_inputs})

        done = min(i + BATCH_SIZE, total)
        elapsed = time.time() - start
        rate = done / elapsed if elapsed > 0 else 0
        print(f"\r  Added {done}/{total} links ({rate:.0f} links/s)", end="", file=sys.stderr)

    elapsed = time.time() - start
    print(file=sys.stderr)
    print(f"\n\033[32m✅ Imported {total} links in {elapsed:.1f}s\033[0m", file=sys.stderr)
    print(f"Perspective UUID: {uuid}", file=sys.stderr)

    # Print UUID to stdout for scripting
    print(uuid)


def main():
    parser = argparse.ArgumentParser(
        description="Import and export AD4M perspectives as JSON snapshots")
    parser.add_argument("--url", default=DEFAULT_URL,
                       help=f"GraphQL endpoint or REST base URL (default: {DEFAULT_URL})")
    parser.add_argument("--auth", default=DEFAULT_AUTH,
                       help="Admin credential or JWT")
    parser.add_argument("--rest", action="store_true",
                       help="Use REST API instead of GraphQL")

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
