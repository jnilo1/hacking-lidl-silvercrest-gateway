#!/usr/bin/env python3
"""
map-ha-devices.py — map Home Assistant Matter devices to Thread ext_macs

The CSV files emitted by `thread-range-test sample` identify each child by its
Thread ext_mac (the 64-bit IEEE address). For Matter sensors, that
ext_mac is randomly chosen at every commissioning, so it carries no
information that lets a human recognise the device. This script queries
Home Assistant's WebSocket API to produce a mapping

    HA-friendly label  ↔  Matter node_id  ↔  Thread ext_mac

so range-test CSVs can be joined with sensor names readable in your
dashboards.

Output: a CSV on stdout with columns

    label,node_id,ext_mac,available

`label` is HA's user-facing friendly name (typically the model name
followed by the user's chosen 4-digit suffix from the Matter
commissioning code). `node_id` is the matter-server internal node id.
`ext_mac` is the lower-case 16-hex IEEE address as it appears in
`ot-ctl neighbor table`. `available` is HA's reachability flag.

Requires: Python 3.10+, `websockets` (pip install websockets), a
long-lived HA access token, and HA reachable over HTTP.

Usage:
    HA_URL=homeassistant.local:8123 HA_TOKEN=<bearer> python3 map-ha-devices.py

Or:
    python3 map-ha-devices.py --url homeassistant.local:8123 --token "$TOK"

The token can be obtained from: HA → Profile → Security →
Long-Lived Access Tokens → Create Token. Read access is sufficient.
"""

import argparse
import asyncio
import json
import os
import re
import sys

try:
    import websockets
except ImportError:
    sys.exit(
        "missing dependency: websockets\n"
        "install with: python3 -m pip install websockets\n"
        "or use a venv: python3 -m venv /tmp/v && /tmp/v/bin/pip install websockets"
    )


def parse_args():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--url", default=os.environ.get("HA_URL"),
                   help="HA host:port (e.g. homeassistant.local:8123). Or env HA_URL.")
    p.add_argument("--token", default=os.environ.get("HA_TOKEN"),
                   help="HA long-lived access token. Or env HA_TOKEN.")
    p.add_argument("--ssl", action="store_true",
                   help="Use wss:// instead of ws:// (HTTPS HA setups).")
    args = p.parse_args()
    if not args.url or not args.token:
        sys.exit("--url and --token (or HA_URL / HA_TOKEN env) are required")
    return args


async def call(ws, msgid, payload):
    payload["id"] = msgid
    await ws.send(json.dumps(payload))
    while True:
        m = json.loads(await ws.recv())
        if m.get("id") == msgid:
            return m


async def main_async(args):
    scheme = "wss" if args.ssl else "ws"
    uri = f"{scheme}://{args.url}/api/websocket"
    msgid = 0

    async with websockets.connect(uri, max_size=20_000_000) as ws:
        # auth handshake
        await ws.recv()  # auth_required
        await ws.send(json.dumps({"type": "auth", "access_token": args.token}))
        ack = json.loads(await ws.recv())
        if ack.get("type") != "auth_ok":
            sys.exit(f"HA auth failed: {ack}")

        async def rpc(t, **kw):
            nonlocal msgid
            msgid += 1
            return await call(ws, msgid, {"type": t, **kw})

        # device + entity registries, plus state for friendly_name
        devs = (await rpc("config/device_registry/list")).get("result", [])
        ents = (await rpc("config/entity_registry/list")).get("result", [])
        states = (await rpc("get_states")).get("result", [])

        state_by_eid = {s["entity_id"]: s for s in states}
        # Build device_id -> friendly label by scanning entities
        dev_label = {}
        for ent in ents:
            did = ent.get("device_id")
            if not did:
                continue
            fn = (state_by_eid.get(ent["entity_id"], {}).get("attributes", {}) or {}).get("friendly_name", "")
            if not fn:
                continue
            # Strip trailing entity-specific suffix (e.g. "TIMMERFLOTTE 0545 Battery"
            # -> "TIMMERFLOTTE 0545"). We keep the first two whitespace-separated
            # tokens, which is correct for IKEA Matter device naming.
            parts = fn.split()
            if len(parts) >= 2:
                label = f"{parts[0]} {parts[1]}"
            else:
                label = parts[0]
            dev_label.setdefault(did, label)

        matter_devs = [d for d in devs
                       if any(idf[0] == "matter"
                              for idf in (d.get("identifiers") or []))]

        rows = []
        for d in matter_devs:
            did = d["id"]
            label = dev_label.get(did, d.get("name") or "unknown")
            r = await rpc("matter/node_diagnostics", device_id=did)
            if not r.get("success"):
                rows.append({"label": label, "node_id": "?", "ext_mac": "?",
                             "available": "?", "error": r.get("error", {}).get("message", "")})
                continue
            res = r["result"]
            mac_colon = res.get("mac_address", "")
            ext_mac = mac_colon.replace(":", "").lower()
            rows.append({
                "label": label,
                "node_id": res.get("node_id", "?"),
                "ext_mac": ext_mac,
                "available": str(res.get("available", "?")).lower(),
            })

        # Print CSV (sorted by node_id when numeric)
        def key(r):
            try:
                return (0, int(r["node_id"]))
            except (TypeError, ValueError):
                return (1, str(r["node_id"]))
        rows.sort(key=key)

        print("label,node_id,ext_mac,available")
        for r in rows:
            print(f'{r["label"]},{r["node_id"]},{r["ext_mac"]},{r["available"]}')


def main():
    args = parse_args()
    asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
