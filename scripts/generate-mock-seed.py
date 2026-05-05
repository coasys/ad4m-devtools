#!/usr/bin/env python3
"""
generate-mock-seed.py — Generate a Flux-compatible mock perspective seed.

Creates a JSON perspective snapshot with valid SHACL schema definitions and
sample data (community, channels, messages) that works with the current
AD4M/Flux model definitions out of the box.

Usage:
  generate-mock-seed.py [options]

Options:
  --name NAME         Community name (default: "Test Community")
  --channels N        Number of channels (default: 2)
  --messages N        Messages per channel (default: 5)
  --output FILE       Output file (default: stdout)
  --pretty            Pretty-print JSON (default when writing to file)
  -h, --help          Show this help

Examples:
  generate-mock-seed.py --output seed.json
  generate-mock-seed.py --name "Dev Community" --channels 3 --messages 10
  generate-mock-seed.py | python3 ad4m-perspective-tool.py --rest import -
"""

import argparse
import json
import random
import string
import sys
import uuid
from datetime import datetime, timedelta, timezone

# ── Predicate constants (must match flux/packages/constants) ──────────────

# Core AD4M predicates
SELF = "ad4m://self"
HAS_SUBJECT_CLASS = "ad4m://has_subject_class"
HAS_SHACL = "ad4m://has_shacl"
SHACL_SHAPE_URI = "ad4m://shacl_shape_uri"
SDNA = "ad4m://sdna"
SHAPE = "ad4m://shape"
CONSTRUCTOR = "ad4m://constructor"
DESTRUCTOR = "ad4m://destructor"
SETTER = "ad4m://setter"
WRITABLE = "ad4m://writable"
RESOLVE_LANG = "ad4m://resolveLanguage"

# RDF / SHACL predicates
RDF_TYPE = "rdf://type"
RDF_NAME = "rdf://name"
RDF_DESC = "rdf://description"
SH_NODE_SHAPE = "sh://NodeShape"
SH_PROPERTY_SHAPE = "sh://PropertyShape"
SH_PROPERTY = "sh://property"
SH_PATH = "sh://path"
SH_DATATYPE = "sh://datatype"
SH_MIN_COUNT = "sh://minCount"
SH_MAX_COUNT = "sh://maxCount"
SH_NODE_KIND = "sh://nodeKind"
XSD_STRING = "xsd://string"
XSD_BOOLEAN = "xsd://boolean"
XSD_INT = "literal:1^^xsd:integer"

# Flux predicates
ENTRY_TYPE = "flux://entry_type"
CHANNEL = "flux://has_channel"
CHANNEL_NAME = "flux://has_channel_name"
CHANNEL_DESC = "flux://has_channel_description"
CHANNEL_IS_CONV = "flux://channel_is_conversation"
CHANNEL_IS_PINNED = "flux://channel_is_pinned"
BODY = "flux://body"
AD4M_HAS_CHILD = "ad4m://has_child"
RDF_ICON = "rdf://icon"
RDF_PKG = "rdf://pkg"

# Entry type values (must match flux/packages/types EntryType enum)
ET_COMMUNITY = "flux://has_community"
ET_CHANNEL = "flux://has_channel"
ET_MESSAGE = "flux://has_message"
ET_APP = "flux://has_app"

# ── Fake DID for authoring links ──────────────────────────────────────────

MOCK_DID = "did:key:z6MkdevtoolsMockSeedGenerator0000000000000000"


def _id():
    """Generate a short random ID for use in link targets."""
    return "".join(random.choices(string.ascii_lowercase, k=5))


def _ts(base, offset_minutes=0):
    """ISO timestamp string."""
    dt = base + timedelta(minutes=offset_minutes)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.000Z")


def _link(source, predicate, target, timestamp):
    """Create a single link entry."""
    return {
        "author": MOCK_DID,
        "timestamp": timestamp,
        "data": {
            "source": source,
            "predicate": predicate,
            "target": target,
        },
        "proof": {"signature": "", "key": ""},
        "status": "shared",
    }


# ── SHACL schema generation ──────────────────────────────────────────────


def _property_shape(
    shape_uri,
    prop_uri,
    path,
    *,
    datatype=XSD_STRING,
    writable=True,
    min_count=None,
    max_count=None,
    setter_action=None,
    resolve_language=None,
    ts="",
):
    """Generate SHACL PropertyShape links for a model property."""
    links = []
    a = lambda s, p, t: links.append(_link(s, p, t, ts))

    # Shape → property
    a(shape_uri, SH_PROPERTY, prop_uri)

    # PropertyShape type
    a(prop_uri, RDF_TYPE, SH_PROPERTY_SHAPE)

    # Path
    a(prop_uri, SH_PATH, path)

    # Datatype
    a(prop_uri, SH_DATATYPE, datatype)

    # Cardinality
    if min_count is not None:
        a(prop_uri, SH_MIN_COUNT, f"literal:{min_count}^^xsd:integer")
    if max_count is not None:
        a(prop_uri, SH_MAX_COUNT, f"literal:{max_count}^^xsd:integer")

    # Writable
    a(prop_uri, WRITABLE, f"literal:boolean:{'true' if writable else 'false'}")

    # Setter
    if setter_action:
        a(prop_uri, SETTER, f"literal:string:{json.dumps(setter_action)}")

    # Resolve language
    if resolve_language:
        a(prop_uri, RESOLVE_LANG, f"literal:string:{resolve_language}")

    return links


def _model_schema(name, shape_prefix, properties, constructor_actions, destructor_actions, ts):
    """Generate full SHACL schema for a model type."""
    links = []
    a = lambda s, p, t: links.append(_link(s, p, t, ts))

    shape_uri = f"{shape_prefix}{name}Shape"
    class_uri = f"{shape_prefix}{name}"

    # Register subject class
    a(SELF, HAS_SUBJECT_CLASS, f"literal:string:{name}")
    a(SELF, HAS_SHACL, f"literal:string:shacl://{name}")
    a(f"literal:string:shacl://{name}", SHACL_SHAPE_URI, shape_uri)
    a(f"literal:string:{name}", SDNA, "literal:string:")

    # Class type
    a(class_uri, RDF_TYPE, "ad4m://SubjectClass")
    a(class_uri, SHAPE, shape_uri)

    # NodeShape
    a(shape_uri, RDF_TYPE, SH_NODE_SHAPE)

    # Constructor / destructor
    if constructor_actions:
        a(shape_uri, CONSTRUCTOR, f"literal:string:{json.dumps(constructor_actions)}")
    if destructor_actions:
        a(shape_uri, DESTRUCTOR, f"literal:string:{json.dumps(destructor_actions)}")

    # Properties
    for prop in properties:
        prop_uri = f"{shape_prefix}{name}.{prop['name']}"
        links.extend(
            _property_shape(
                shape_uri,
                prop_uri,
                prop["path"],
                datatype=prop.get("datatype", XSD_STRING),
                writable=prop.get("writable", True),
                min_count=prop.get("min_count"),
                max_count=prop.get("max_count"),
                setter_action=prop.get("setter"),
                resolve_language=prop.get("resolve_language"),
                ts=ts,
            )
        )

    return links


def generate_schema(ts):
    """Generate SHACL schema links for Community, Channel, and Message."""
    links = []

    # ── Community ──
    links.extend(
        _model_schema(
            "Community",
            "flux://",
            [
                {
                    "name": "type",
                    "path": ENTRY_TYPE,
                    "writable": False,
                    "min_count": 1,
                    "max_count": 1,
                },
                {
                    "name": "name",
                    "path": RDF_NAME,
                    "writable": True,
                    "max_count": 1,
                    "resolve_language": "literal",
                    "setter": [
                        {
                            "action": "setSingleTarget",
                            "source": "this",
                            "predicate": RDF_NAME,
                            "target": "value",
                        }
                    ],
                },
                {
                    "name": "description",
                    "path": RDF_DESC,
                    "writable": True,
                    "max_count": 1,
                    "resolve_language": "literal",
                },
            ],
            constructor_actions=[
                {
                    "action": "addLink",
                    "source": "this",
                    "predicate": ENTRY_TYPE,
                    "target": ET_COMMUNITY,
                }
            ],
            destructor_actions=[
                {
                    "action": "removeLink",
                    "source": "this",
                    "predicate": ENTRY_TYPE,
                    "target": "*",
                }
            ],
            ts=ts,
        )
    )

    # ── Channel ──
    links.extend(
        _model_schema(
            "Channel",
            "flux://",
            [
                {
                    "name": "type",
                    "path": ENTRY_TYPE,
                    "writable": False,
                    "min_count": 1,
                    "max_count": 1,
                },
                {
                    "name": "name",
                    "path": CHANNEL_NAME,
                    "writable": True,
                    "max_count": 1,
                    "resolve_language": "literal",
                    "setter": [
                        {
                            "action": "setSingleTarget",
                            "source": "this",
                            "predicate": CHANNEL_NAME,
                            "target": "value",
                        }
                    ],
                },
                {
                    "name": "description",
                    "path": CHANNEL_DESC,
                    "writable": True,
                    "max_count": 1,
                    "resolve_language": "literal",
                },
                {
                    "name": "isConversation",
                    "path": CHANNEL_IS_CONV,
                    "datatype": XSD_BOOLEAN,
                    "writable": True,
                    "max_count": 1,
                },
                {
                    "name": "isPinned",
                    "path": CHANNEL_IS_PINNED,
                    "datatype": XSD_BOOLEAN,
                    "writable": True,
                    "max_count": 1,
                },
            ],
            constructor_actions=[
                {
                    "action": "addLink",
                    "source": "this",
                    "predicate": ENTRY_TYPE,
                    "target": ET_CHANNEL,
                }
            ],
            destructor_actions=[
                {
                    "action": "removeLink",
                    "source": "this",
                    "predicate": ENTRY_TYPE,
                    "target": "*",
                }
            ],
            ts=ts,
        )
    )

    # ── Message ──
    links.extend(
        _model_schema(
            "Message",
            "flux://",
            [
                {
                    "name": "type",
                    "path": ENTRY_TYPE,
                    "writable": False,
                    "min_count": 1,
                    "max_count": 1,
                },
                {
                    "name": "body",
                    "path": BODY,
                    "writable": True,
                    "max_count": 1,
                    "resolve_language": "literal",
                    "setter": [
                        {
                            "action": "setSingleTarget",
                            "source": "this",
                            "predicate": BODY,
                            "target": "value",
                        }
                    ],
                },
            ],
            constructor_actions=[
                {
                    "action": "addLink",
                    "source": "this",
                    "predicate": ENTRY_TYPE,
                    "target": ET_MESSAGE,
                }
            ],
            destructor_actions=[
                {
                    "action": "removeLink",
                    "source": "this",
                    "predicate": ENTRY_TYPE,
                    "target": "*",
                }
            ],
            ts=ts,
        )
    )

    # ── App (view/plugin) ──
    links.extend(
        _model_schema(
            "App",
            "flux://",
            [
                {
                    "name": "type",
                    "path": ENTRY_TYPE,
                    "writable": False,
                    "min_count": 1,
                    "max_count": 1,
                },
                {
                    "name": "name",
                    "path": RDF_NAME,
                    "writable": True,
                    "max_count": 1,
                    "resolve_language": "literal",
                },
                {
                    "name": "description",
                    "path": RDF_DESC,
                    "writable": True,
                    "max_count": 1,
                    "resolve_language": "literal",
                },
                {
                    "name": "icon",
                    "path": RDF_ICON,
                    "writable": True,
                    "max_count": 1,
                    "resolve_language": "literal",
                },
                {
                    "name": "pkg",
                    "path": RDF_PKG,
                    "writable": True,
                    "max_count": 1,
                    "resolve_language": "literal",
                },
            ],
            constructor_actions=[
                {
                    "action": "addLink",
                    "source": "this",
                    "predicate": ENTRY_TYPE,
                    "target": ET_APP,
                }
            ],
            destructor_actions=[
                {
                    "action": "removeLink",
                    "source": "this",
                    "predicate": ENTRY_TYPE,
                    "target": "*",
                }
            ],
            ts=ts,
        )
    )

    return links


# ── Sample data generation ────────────────────────────────────────────────

SAMPLE_MESSAGES = [
    "Hey everyone, welcome to the community!",
    "Thanks for setting this up. Excited to get started.",
    "Has anyone tried the new SPARQL query features?",
    "The SHACL validation is working really well now.",
    "Just pushed a fix for the model query direction issue.",
    "Can we schedule a sync for next week?",
    "I've been testing the transcription model, works great.",
    "The cursor-based pagination is much faster than offset.",
    "Anyone else seeing issues with the link language?",
    "Deployed the latest build, everything looks good.",
    "Working on the holograph selective sync implementation.",
    "The named graph support is really powerful for isolation.",
    "Just finished the dead code cleanup pass.",
    "ZCAP delegation is working end-to-end now.",
    "Can we discuss the reifier migration plan?",
]


def generate_data(community_name, num_channels, num_messages, base_ts):
    """Generate sample data links."""
    links = []
    ts = _ts(base_ts)
    minute = 1

    # ── Community instance ──
    community_id = f"literal:string:{_id()}"
    links.append(_link(community_id, ENTRY_TYPE, ET_COMMUNITY, ts))
    links.append(_link(community_id, RDF_NAME, f"literal:string:{community_name}", ts))
    links.append(
        _link(
            community_id,
            RDF_DESC,
            "literal:string:A test community for development",
            ts,
        )
    )

    channel_names = ["general", "random", "dev", "design", "feedback", "announcements"]

    for ch_idx in range(num_channels):
        minute += 1
        ch_ts = _ts(base_ts, minute)
        ch_name = channel_names[ch_idx % len(channel_names)]
        channel_id = f"literal:string:{_id()}"

        # Channel instance
        links.append(_link(channel_id, ENTRY_TYPE, ET_CHANNEL, ch_ts))
        links.append(
            _link(channel_id, CHANNEL_NAME, f"literal:string:{ch_name}", ch_ts)
        )
        links.append(
            _link(
                channel_id,
                CHANNEL_DESC,
                f"literal:string:The {ch_name} channel",
                ch_ts,
            )
        )
        links.append(
            _link(channel_id, CHANNEL_IS_CONV, "literal:boolean:false", ch_ts)
        )
        links.append(
            _link(channel_id, CHANNEL_IS_PINNED, "literal:boolean:false", ch_ts)
        )

        # Community → Channel
        links.append(_link(community_id, CHANNEL, channel_id, ch_ts))

        # Chat view App for this channel
        app_id = f"literal:string:{_id()}"
        links.append(_link(app_id, ENTRY_TYPE, ET_APP, ch_ts))
        links.append(_link(app_id, RDF_NAME, "literal:string:Chat", ch_ts))
        links.append(
            _link(app_id, RDF_DESC, "literal:string:Real time messaging", ch_ts)
        )
        links.append(_link(app_id, RDF_ICON, "literal:string:chat", ch_ts))
        links.append(
            _link(
                app_id,
                RDF_PKG,
                "literal:string:@coasys/flux-chat-view",
                ch_ts,
            )
        )
        # Channel → App (view)
        links.append(_link(channel_id, AD4M_HAS_CHILD, app_id, ch_ts))

        # Messages in channel
        for msg_idx in range(num_messages):
            minute += 1
            msg_ts = _ts(base_ts, minute)
            msg_id = f"literal:string:{_id()}"
            msg_text = SAMPLE_MESSAGES[
                (ch_idx * num_messages + msg_idx) % len(SAMPLE_MESSAGES)
            ]

            links.append(_link(msg_id, ENTRY_TYPE, ET_MESSAGE, msg_ts))
            links.append(
                _link(msg_id, BODY, f"literal:string:{msg_text}", msg_ts)
            )

            # Channel → Message (ad4m://has_child is the default @HasMany predicate)
            links.append(_link(channel_id, AD4M_HAS_CHILD, msg_id, msg_ts))

    return links


def main():
    parser = argparse.ArgumentParser(
        description="Generate a Flux-compatible mock perspective seed"
    )
    parser.add_argument(
        "--name", default="Test Community", help="Community name (default: Test Community)"
    )
    parser.add_argument(
        "--channels",
        type=int,
        default=2,
        help="Number of channels (default: 2)",
    )
    parser.add_argument(
        "--messages",
        type=int,
        default=5,
        help="Messages per channel (default: 5)",
    )
    parser.add_argument(
        "--output", "-o", help="Output file (default: stdout)"
    )
    parser.add_argument(
        "--pretty", action="store_true", help="Pretty-print JSON"
    )
    args = parser.parse_args()

    base_ts = datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc)
    ts = _ts(base_ts)

    # Build perspective
    schema_links = generate_schema(ts)
    data_links = generate_data(
        args.name, args.channels, args.messages, base_ts
    )
    all_links = schema_links + data_links

    seed = {
        "uuid": str(uuid.uuid4()),
        "name": args.name,
        "sharedUrl": None,
        "state": None,
        "neighbourhood": None,
        "links": all_links,
    }

    indent = 2 if (args.pretty or args.output) else None
    json_str = json.dumps(seed, indent=indent)

    if args.output:
        with open(args.output, "w") as f:
            f.write(json_str)
            f.write("\n")
        print(
            f"Generated seed: {args.name} ({len(schema_links)} schema + {len(data_links)} data = {len(all_links)} links)",
            file=sys.stderr,
        )
        print(f"Written to: {args.output}", file=sys.stderr)
    else:
        print(json_str)


if __name__ == "__main__":
    main()
