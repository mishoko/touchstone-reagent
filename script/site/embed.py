#!/usr/bin/env python3
"""Embed the page's facts into frontend/index.html (stdlib only).

Reads audits/loops.json, audits/mutants.json, audits/deployments-{1301,11155111,5318007}.json,
the forge test summary (--tests, `forge test --json` output), the reference agent's run log
(--agent-log) and the spec's attack-cell and invariant tables, then rewrites the block between
<!-- DATA:BEGIN --> and <!-- DATA:END --> as <script id="reagent-data" type="application/json">.
It also copies frontend/tokens.css into the page between /* TOKENS:BEGIN */ and /* TOKENS:END */.

  python3 script/site/embed.py            # rewrite the page
  python3 script/site/embed.py --check    # exit 1 if the data block or the tokens are stale

Without a tests file (a fresh clone: output/ is not public) the test counts already embedded
in the page are kept, and the script says so.
"""
import argparse
import datetime as dt
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PAGE = os.path.join(ROOT, "frontend", "index.html")
TOKENS = os.path.join(ROOT, "frontend", "tokens.css")
SPEC = os.path.join(ROOT, "internal", "REAGENT-SPEC.md")
D_BEGIN, D_END = "<!-- DATA:BEGIN -->", "<!-- DATA:END -->"
T_BEGIN, T_END = "/* TOKENS:BEGIN */", "/* TOKENS:END */"

EXPLORERS = {
    "1301": "https://sepolia.uniscan.xyz/",
    "11155111": "https://sepolia.etherscan.io/",
    "5318007": "https://lasna.reactscan.net/",
}
CHAINS = {"A": 1301, "B": 11155111}
LASNA = 5318007

# ---------------------------------------------------------------- keccak-256 (EIP-55 checksums)
_RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
       0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
       0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
       0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
       0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
       0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56],
        [27, 20, 39, 8, 14]]
_M = (1 << 64) - 1


def _rol(v, n):
    return ((v << n) | (v >> (64 - n))) & _M if n else v


def _f(a):
    for rc in _RC:
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ _rol(c[(x + 1) % 5], 1) for x in range(5)]
        a = [[a[x][y] ^ d[x] for y in range(5)] for x in range(5)]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                b[y][(2 * x + 3 * y) % 5] = _rol(a[x][y], _ROT[x][y])
        a = [[b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
        a[0][0] ^= rc
    return a


def keccak256(data: bytes) -> bytes:
    rate = 136
    msg = bytearray(data) + b"\x01"
    while len(msg) % rate:
        msg += b"\x00"
    msg[-1] |= 0x80
    a = [[0] * 5 for _ in range(5)]
    for off in range(0, len(msg), rate):
        blk = msg[off:off + rate]
        for i in range(rate // 8):
            x, y = i % 5, i // 5
            a[x][y] ^= int.from_bytes(blk[8 * i:8 * i + 8], "little")
        a = _f(a)
    out = b""
    for i in range(4):
        out += a[i % 5][i // 5].to_bytes(8, "little")
    return out


def cs(addr):
    """EIP-55 checksum of a 20-byte hex address."""
    if not addr:
        return addr
    h = addr.lower().replace("0x", "")
    assert re.fullmatch(r"[0-9a-f]{40}", h), addr
    k = keccak256(h.encode()).hex()
    return "0x" + "".join(c.upper() if c.isalpha() and int(k[i], 16) >= 8 else c for i, c in enumerate(h))


assert keccak256(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
assert cs("0xfb6916095ca1df60bb79ce92ce3ea74c37c5d359") == "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359"


# ---------------------------------------------------------------- helpers
def load(path):
    with open(os.path.join(ROOT, path)) as fh:
        return json.load(fh)


def iso_ts(s):
    return int(dt.datetime.fromisoformat(s).timestamp())


def clean(text, limit):
    """Spec cell text for the public page: drop review references, code ticks and bold marks."""
    t = re.sub(r"\s*\((?:[^()]*\b(?:r\d+|D\d+-\d+|m-\d+|PB-\d+|PA-\d+|s\d+|v1\.\d|LF-|OQ-|F-0)[^()]*)\)", "", text)
    t = re.sub(r"\s*\((?:s\d+ )?erratum[^)]*\)", "", t)
    # bare review tags outside parentheses (design and review references)
    t = re.sub(r"[,;]?\s*\b(?:s\d+(?: [\w-]+)?(?: r\d+)? )?(?:P[AB]-\d+|[A-Z]\d+-\d+)\b", "", t)
    t = re.sub(r"\(\s*\)", "", t)
    t = re.sub(r"\bPB-\d+\s+check", "the vault check", t)
    t = re.sub(r"\s*§\d+(\.\d+)*", "", t)
    t = t.replace("no PC can win", "no positive control can win")
    # page wording: "value" appears only as "in kind"; the spec's valuation terms become "worth"
    for a, b in (("fair value", "fair worth"), ("valued at", "measured at"), ("as value at", "as worth at"),
                 ("the written value", "the written number"), ("Neither value", "Neither number")):
        t = t.replace(a, b)
    t = t.replace("`", "").replace("**", "").replace("§4", "").strip(" ;")
    t = re.sub(r"\s+", " ", t)
    if len(t) > limit:
        cut = t[:limit].rsplit(" ", 1)[0].rstrip(",;:")
        t = cut + "…"
    return t


def spec_tables(old_data=None):
    """The attack and invariant rows come from the private spec; a public clone keeps the embedded rows."""
    if not os.path.exists(SPEC):
        if old_data and old_data.get("tests", {}).get("attackCells"):
            print("embed.py: no spec; keeping the embedded attack and invariant rows", file=sys.stderr)
            return old_data["tests"]["attackCells"], old_data["tests"]["invariants"]
        sys.exit("embed.py: no spec and no embedded attack rows")
    with open(SPEC) as fh:
        spec = fh.read()
    sec = spec.split("### 9.3", 1)[1].split("### 9.4", 1)[0]
    attacks = []
    for line in sec.splitlines():
        m = re.match(r"\|\s*(A-[A-Z0-9-]+)\s*\|(.*)\|(.*)\|\s*(\w+)\s*\|\s*$", line)
        if m:
            aid, atk, pc, kind = m.groups()
            if kind.strip() == "script":
                continue  # the 11155111 exit gas cell is run by script; it sits in Limits
            attacks.append([aid, clean(atk, 190), clean(pc, 150), kind.strip()])
    inv_ids = re.findall(r"^\|\s*(I-[A-Z0-9]+)\s*\|", spec.split("### 9.4", 1)[1].split("### 9.5", 1)[0], re.M)
    sec4 = spec.split("## 4. Invariants", 1)[1].split("## 5.", 1)[0]
    texts = {}
    for m in re.finditer(r"^- \*\*(I-[A-Z0-9]+)[^:]*:\*\*\s*(.+)$", sec4, re.M):
        texts[m.group(1)] = m.group(2)
    invs = []
    for i in inv_ids:
        body = texts.get(i, "")
        body = re.sub(r"^\([^)]*\)\s*", "", body)
        first = re.split(r"(?<=[.])\s", clean(body, 400), maxsplit=1)[0]
        if len(first) > 170:  # drop asides, then cut at a clause boundary
            first = re.sub(r"\s*\([^()]*\)", "", first)
            first = re.split(r";\s|, where |, in every ", first, maxsplit=1)[0].rstrip(".") + "."
        invs.append([i, clean(first, 220)])
    return attacks, invs


def agent_session(path, last_ok_ts, refused_ts):
    """The live agent session that ended before the breach, and the wake that proved the refusal."""
    if not path or not os.path.exists(path):
        return None
    rows = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    for r in rows:
        r["_t"] = iso_ts(r["ts"])
    starts = [r for r in rows if r["action"] == "start" and r.get("dry") is False and r["_t"] <= last_ok_ts]
    if not starts:
        return None
    start = starts[-1]
    stop = next(r for r in rows if r["action"] == "stop" and r["_t"] >= last_ok_ts)
    wake = next((r for r in rows if r["action"] == "start" and r["_t"] > stop["_t"]), None)
    wake_stop = next((r for r in rows if wake and r["action"] == "stop" and r["_t"] > wake["_t"]), None)
    allocs = [[r["_t"], r["tx"], r["block"]] for r in rows
              if r["action"] == "allocate" and r.get("status") == "ok" and r.get("tx")
              and start["_t"] <= r["_t"] <= stop["_t"]]
    return {
        "start": start["_t"], "stop": stop["_t"], "stopStatus": stop["status"],
        "wake": wake["_t"] if wake else None, "wakeStop": wake_stop["_t"] if wake_stop else None,
        "allocations": allocs, "chain": int(start["chain"]),
        "source": os.path.relpath(path, ROOT),
    }


def test_counts(path):
    if not path or not os.path.exists(path):
        return None
    with open(path) as fh:
        d = json.load(fh)
    c = {"passed": 0, "failed": 0, "skipped": 0, "suites": len(d), "invariantRuns": 0}
    for suite in d.values():
        for t in suite["test_results"].values():
            s = t["status"]
            c["passed" if s == "Success" else "skipped" if s == "Skipped" else "failed"] += 1
            if isinstance(t.get("kind"), dict) and "Invariant" in t["kind"]:
                c["invariantRuns"] += 1
    return c


# ---------------------------------------------------------------- the data
def build(tests_path, agent_path, old_data):
    L = load("audits/loops.json")
    M = load("audits/mutants.json")
    D = {c: load(f"audits/deployments-{c}.json") for c in ("1301", "11155111", "5318007")}
    loops, runs = L["loops"], L["runs"]

    def rows(i):
        return [r for r in loops if r.get("id") == i]

    p = rows("L-PAUSE")[0]
    off = rows("L-OFFLINE")[0]
    hero = {k: p[k] for k in ("originChain", "originTx", "originBlock", "originTs", "lasnaTx", "lasnaTs", "destChain",
                              "appliedTx", "appliedBlock", "appliedTs", "latency_s", "lastOkTx", "lastOkNonce",
                              "lastOkTs", "refusedTx", "refusedTs", "refusedBlock", "refusedNonce", "refusedSelector")}
    hero["covenant"], hero["agent"] = cs(p["covenant"]), cs(p["agent"])
    hero["pass"] = bool(p["verdict"]["pass"])
    hero["offlinePass"] = bool(off["verdict"]["pass"])
    hero["refusedError"] = "HubPaused" if p["verdict"].get("hubPaused") else None

    plan = []
    plan_verdict = None
    for r in rows("L-PLAN"):
        if "epoch" not in r:
            plan_verdict = r.get("verdict")
            continue
        plan.append({k: r.get(k) for k in ("epoch", "originTx", "originTs", "lasnaTx", "delivered", "withheld",
                                            "noteTx", "noteTs", "latency_s", "pausedAtOrigin")})

    e = rows("L-EXIT-partial")[0]
    ex = {k: e[k] for k in ("processTx", "processBlock", "doneTx", "doneBlock", "latency_s")}
    ex["noteA"], ex["noteB"] = str(e["noteA"]), str(e["noteB"])  # strings: 18-dp amounts exceed 2^53
    ex["owner"] = cs(e["owner"])
    ex["otherRecipients"] = len(e["otherRecipients"])
    ex["dripBlocks"] = e["dripBlocks"]
    ex["verdict"] = {k: bool(e["verdict"][k]) for k in ("done", "afterDrip", "toOwnerExactly", "noOtherRecipient")}

    con = {}
    for s in L["stats"]:
        pid = s["id"].split("-")[-1]
        con[pid] = {
            "from": CHAINS[pid[0]], "to": CHAINS[pid[1]],
            "attempted": s["attempted"], "delivered": s["delivered"], "median": s["median"], "p95": s["p95"],
            "max": s["max"], "date": s["batches"][0]["date"] if len(s["batches"]) == 1 else None,
            "batches": s["datedBatches"],
            "loops": [[r["seq"], r["originTs"], r["latency_s"], r["originTx"], r["lasnaTx"], r["destTx"],
                       r["originBlock"]]
                      for r in sorted(rows(s["id"]), key=lambda r: (r["originTs"], r["seq"]))],
        }

    def lk(label, chain, tx):
        return [label, chain, tx]

    live = []
    dyn = rows("L-DYN")
    live.append({"id": "L-DYN", "n": runs["L-DYN"]["n"],
                 "pass": all(r.get("destEvent") == "VaultBound" and r.get("destTx") for r in dyn),
                 "what": "A new vault deployed by a registered curator: the RC subscribed to it from inside a "
                         "reaction, and the Hub bound it to its curator",
                 "stat": {"latency": [r["latency_s"] for r in dyn]},
                 "links": [lk("deploy " + r["step"].split("_")[-1], r["chain"], r["originTx"]) for r in dyn]
                          + [lk("bound " + r["step"].split("_")[-1], r["chain"], r["destTx"]) for r in dyn]})
    pay = rows("L-PAY")[0]
    live.append({"id": "L-PAY", "n": runs["L-PAY"]["n"], "pass": bool(pay["pass"]),
                 "what": "A Hub holding only a plain balance paid for its first callback; debt stayed 0",
                 "links": [lk("fund", pay["chain"], pay["originTx"]), lk("callback", pay["chain"], pay["destTx"])]})
    sp = rows("L-SPOOF")[0]
    live.append({"id": "L-SPOOF", "n": runs["L-SPOOF"]["n"], "pass": bool(sp["pass"]),
                 "what": "A third-party reactive contract called the Hub: rejected NotRc, no state written",
                 "links": [lk("trigger", 1301, sp["originTx"]), lk("spoof reaction", LASNA, sp["lasnaTx"]),
                           lk("rejected", 1301, sp["destTx"])]})
    cr = rows("L-CRON")[0]
    live.append({"id": "L-CRON", "n": runs["L-CRON"]["n"], "pass": bool(cr["pass"]),
                 "what": "The RC subscribed to Cron only while an exit was pending, and unsubscribed from a "
                         "Cron reaction once it was done",
                 "links": [lk("subscribe", LASNA, cr["subscribeTx"]), lk("exit done", 1301, cr["exitDoneTx"]),
                           lk("unsubscribe", LASNA, cr["unsubscribeTx"])]})
    live.append({"id": "L-PAUSE", "n": runs["L-PAUSE"]["n"], "pass": hero["pass"],
                 "what": "A breach on Unichain Sepolia paused the curator on Ethereum Sepolia",
                 "links": [lk("breach", 1301, p["originTx"]), lk("reaction", LASNA, p["lasnaTx"]),
                           lk("paused", p["destChain"], p["appliedTx"])]})
    live.append({"id": "L-OFFLINE", "n": runs["L-OFFLINE"]["n"], "pass": hero["offlinePass"],
                 "what": "The agent was offline through the breach; its next allocation was refused",
                 "links": [lk("last ok", p["destChain"], p["lastOkTx"]), lk("refused", p["destChain"], p["refusedTx"])]})
    live.append({"id": "L-PLAN", "n": runs["L-PLAN"]["n"], "pass": bool(plan_verdict and plan_verdict.get("pass")),
                 "what": "Standing-plan deposits ran on the vault's epoch; after the breach the RC withheld the plan",
                 "links": [lk("plan " + str(r["epoch"]), 1301, r["noteTx"]) for r in plan if r["delivered"]]
                          + [lk("withheld " + str(r["epoch"]), LASNA, r["lasnaTx"]) for r in plan
                             if r["withheld"] and r["pausedAtOrigin"]]})

    muts = []
    for m in M["mutants"]:
        muts.append([m["id"], m["area"], os.path.basename(m["file"]) if m.get("file") else "",
                     m["status"], m.get("kill") if m.get("kill") != "pending" else "",
                     clean(m.get("desc", ""), 140), clean(m.get("reason", "") or "", 160)])

    r1301 = D["1301"]["steps"]["reagent"]["reads"]
    r111 = D["11155111"]["steps"]["reagent"]["reads"]
    vaults = {r["step"].split("_")[-1]: {"chain": r["chain"], "address": cs(r["vault"]), "curator": r["curator"]}
              for r in dyn}
    lasna = D["5318007"]["steps"]
    deploy = {
        "lasna": {"rc": cs(lasna["rc"]["address"]), "rcext": cs(lasna["rcext"]["address"]),
                  "rcb6": cs(lasna["rcb6"]["address"])},
        "hub": cs(r1301["addresses"]["hub"]), "factory": cs(r1301["addresses"]["factory"]),
        "sameOnBoth": (r1301["addresses"]["hub"] == r111["addresses"]["hub"]
                       and r1301["addresses"]["factory"] == r111["addresses"]["factory"]),
        "proxy": {"1301": cs(r1301["ReagentHub.PROXY()"]), "11155111": cs(r111["ReagentHub.PROXY()"])},
        "covenant": hero["covenant"], "owner": ex["owner"], "agent": hero["agent"],
        "vaults": vaults,
    }

    tc = test_counts(tests_path)
    if tc is None:
        if not old_data or "tests" not in old_data:
            sys.exit("embed.py: no --tests file and no test counts in the page")
        tc = {k: v for k, v in old_data["tests"].items() if k not in ("attackCells", "invariants")}
        print("embed.py: no tests file; keeping the embedded counts", tc, file=sys.stderr)
    attacks, invs = spec_tables(old_data)
    tc["attackCells"], tc["invariants"] = attacks, invs
    killed = sum(1 for m in muts if m[3] == "KILLED")
    tc["mutants"] = {"total": len(muts), "killed": killed, "equivalent": sum(1 for m in muts if m[3] == "EQUIVALENT")}

    ag = agent_session(agent_path, p["lastOkTs"], p["refusedTs"])
    if ag is None and old_data and old_data.get("agentLog"):
        ag = old_data["agentLog"]
        print("embed.py: no agent log; keeping the embedded agent times", file=sys.stderr)

    return {
        "hero": hero, "plan": plan, "exit": ex, "agentLog": ag, "con": con, "liveRows": live,
        "mutants": muts, "deploy": deploy, "tests": tc,
        "explorers": {k: v + "tx/" for k, v in EXPLORERS.items()},
        "explorersAddr": {k: v + "address/" for k, v in EXPLORERS.items()},
        "runDate": dt.datetime.fromtimestamp(p["originTs"], dt.timezone.utc).strftime("%Y-%m-%d"),
        "repo": "https://github.com/mishoko/touchstone-reagent",
    }


def render(data):
    blob = json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=False).replace("</", "<\\/")
    return f'{D_BEGIN}\n<script id="reagent-data" type="application/json">{blob}</script>\n{D_END}'


def splice(text, begin, end, inner):
    a, b = text.index(begin), text.index(end) + len(end)
    return text[:a] + inner + text[b:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--tests", default=os.path.join(ROOT, "output", "forge-tests.json"))
    ap.add_argument("--agent-log", default=os.path.join(ROOT, "audits", "agent-11155111.jsonl"))
    a = ap.parse_args()

    with open(PAGE) as fh:
        page = fh.read()
    old = None
    m = re.search(r'<script id="reagent-data" type="application/json">(.*?)</script>', page, re.S)
    if m:
        try:
            old = json.loads(m.group(1).replace("<\\/", "</"))
        except ValueError:
            old = None
    data = build(a.tests, a.agent_log, old)
    with open(TOKENS) as fh:
        tokens = fh.read().strip()
    new = splice(page, D_BEGIN, D_END, render(data))
    new = splice(new, T_BEGIN, T_END, f"{T_BEGIN}\n{tokens}\n{T_END}")

    size = len(render(data).encode())
    if a.check:
        if new != page:
            print("embed.py --check: STALE (data block or tokens differ; run script/site/embed.py)")
            sys.exit(1)
        print(f"embed.py --check: ok (data {size/1024:.1f} KB, page {len(page.encode())/1024:.1f} KB)")
        return
    if size > 120 * 1024:
        sys.exit(f"embed.py: data block {size} B exceeds 120 KB")
    with open(PAGE, "w") as fh:
        fh.write(new)
    print(f"embed.py: wrote {os.path.relpath(PAGE, ROOT)} (data {size/1024:.1f} KB, page {len(new.encode())/1024:.1f} KB)")


if __name__ == "__main__":
    main()
