#!/usr/bin/env python3
"""Minimal client for the public Reactive MCP server (https://mcp.rnk.dev/mcp).

Usage:
  python3 script/rnk/rmcp.py tools                      # list tool names
  python3 script/rnk/rmcp.py call <tool> '<json args>'  # call a tool, print its structured result as JSON

Standard library only. The server speaks MCP streamable HTTP; replies may arrive as
JSON or as one SSE `data:` frame. No credentials are sent.
"""
import json
import sys
import urllib.request

URL = "https://mcp.rnk.dev/mcp"
HEADERS = {"content-type": "application/json", "accept": "application/json, text/event-stream",
           "user-agent": "reagent-rmcp/0.1"}


def rpc(method, params=None, timeout=90):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}).encode()
    req = urllib.request.Request(URL, data=body, headers=HEADERS, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read().decode()
    for line in raw.splitlines():
        if line.startswith("data:"):
            raw = line[5:].strip()
            break
    msg = json.loads(raw)
    if "error" in msg:
        raise SystemExit(f"rpc error: {msg['error']}")
    return msg["result"]


def call(tool, args):
    res = rpc("tools/call", {"name": tool, "arguments": args})
    if "structuredContent" in res:
        return res["structuredContent"]
    texts = [c.get("text", "") for c in res.get("content", [])]
    try:
        return json.loads("".join(texts))
    except ValueError:
        return {"text": "".join(texts)}


def main(argv):
    if len(argv) >= 2 and argv[1] == "tools":
        for t in rpc("tools/list")["tools"]:
            print(t["name"])
        return 0
    if len(argv) >= 3 and argv[1] == "call":
        args = json.loads(argv[3]) if len(argv) > 3 else {}
        print(json.dumps(call(argv[2], args), indent=1))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
