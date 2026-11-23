#!/usr/bin/env python3
"""G1 smoke loop driver: one reactive contract on Lasna, callbacks to Unichain Sepolia and
Ethereum Sepolia. Resumable; every number in the output is read from chain or from the
Reactive MCP by this script, never typed by hand.

  python3 script/smoke/g1.py selectors   # clean-room ABI vs deployed system contract / proxies
  python3 script/smoke/g1.py deploy      # pings + receivers on 1301/11155111, RC on Lasna, funding
  python3 script/smoke/g1.py ping [n]    # emit one Ping on each origin (nonce n, default 1)
  python3 script/smoke/g1.py collect     # gather Reacted/Smoke logs, MCP traces -> audits/smoke-g1.json

Reads DEPLOYER_PK, UNICHAIN_SEPOLIA_RPC_URL, ETH_SEPOLIA_RPC_URL from .env (never printed).
State: output/g1-state.json (gitignored).
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# Profiles: "base" asks gasLimit 400,000; "hi" asks 1,000,000 (two points separate a fixed proxy
# overhead from a proportional one). Select with G1_PROFILE=hi.
PROFILE = __import__("os").environ.get("G1_PROFILE", "base")
SUFFIX = "" if PROFILE == "base" else f"-{PROFILE}"
STATE = ROOT / "output" / f"g1-state{SUFFIX}.json"
OUT = ROOT / "audits" / f"smoke-g1{SUFFIX}.json"
sys.path.insert(0, str(ROOT / "script" / "rnk"))
import rmcp  # noqa: E402

LASNA = {"id": 5318007, "rpc": "https://lasna-rpc.rnk.dev/", "explorer": "https://lasna.reactscan.net"}
SYSTEM = "0x8888888888888888888888888888888888888888"
GAS_LIMIT = {"base": 400_000, "hi": 1_000_000}[PROFILE]
RC_FUND = "5ether"       # lREACT into the system contract's reserves for the RC
RECV_FUND = "0.005ether"  # native ETH into each proxy's reserves for the receiver


def env():
    e = {}
    for line in (ROOT / ".env").read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            e[k.strip()] = v.strip().strip('"').strip("'")
    return e


E = env()
CHAINS = {
    "A": {"id": 1301, "rpc": E["UNICHAIN_SEPOLIA_RPC_URL"], "proxy": "0x775c9B990ADe401060B78D0e98684eEf8d2466C1",
          "logrpc": "https://sepolia.unichain.org", "explorer": "https://sepolia.uniscan.xyz"},
    "B": {"id": 11155111, "rpc": E["ETH_SEPOLIA_RPC_URL"], "proxy": "0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4",
          "logrpc": "https://ethereum-sepolia-rpc.publicnode.com", "explorer": "https://sepolia.etherscan.io"},
}
PK = E["DEPLOYER_PK"]


def sh(args):
    # The key travels in the environment (ETH_PRIVATE_KEY), never on the command line.
    r = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, env={**os.environ, "ETH_PRIVATE_KEY": PK})
    if r.returncode != 0:
        shown = [a if a != PK else "<pk>" for a in args]
        raise SystemExit(f"command failed: {' '.join(shown)}\n{r.stderr.replace(PK, '<pk>')[-2000:]}")
    return r.stdout.strip()


def cast(*a):
    return sh(["cast", *a])


def load():
    return json.loads(STATE.read_text()) if STATE.exists() else {}


def save(s):
    STATE.parent.mkdir(exist_ok=True)
    STATE.write_text(json.dumps(s, indent=1))


def deployer():
    return sh(["cast", "wallet", "address"])  # key from ETH_PRIVATE_KEY; local derivation only


CTOR = {
    "SmokePing": None,
    "SmokeReceiver": "constructor(address,address)",
    "SmokeRC": "constructor(uint256,address,address,uint256,address,address,uint64)",
}


def create(rpc, contract, args, value=None):
    art = json.loads((ROOT / "out" / "SmokeContracts.sol" / f"{contract}.json").read_text())
    code = art["bytecode"]["object"]
    if CTOR[contract]:
        code += cast("abi-encode", CTOR[contract], *map(str, args))[2:]
    cmd = ["cast", "send", "--rpc-url", rpc, "--json"]
    if value:
        cmd += ["--value", value]
    cmd += ["--create", code]
    r = json.loads(sh(cmd))
    assert r["status"] in ("0x1", 1), r
    return {"address": r["contractAddress"], "tx": r["transactionHash"]}


def send(rpc, to, sig, *args, value=None):
    cmd = ["cast", "send", to, sig, *map(str, args), "--rpc-url", rpc, "--json"]
    if value:
        cmd += ["--value", value]
    r = json.loads(sh(cmd))
    assert r["status"] in ("0x1", 1), r
    return r["transactionHash"]


def block_ts(rpc, n):
    return int(cast("block", str(n), "--field", "timestamp", "--rpc-url", rpc))


# ---------------------------------------------------------------- selectors
SYS_SIGS = [
    "subscribe(uint256,address,uint256,uint256,uint256,uint256)",
    "unsubscribe(uint256,address,uint256,uint256,uint256,uint256)",
    "requestCallbackV_1_0((uint256,address,uint64,bytes))",
    "depositTo(address)", "debt(address)", "reserves(address)",
    # selectors the system contract calls on an RC:
    "react((uint256,address,uint256,uint256,uint256,uint256,bytes,uint256,uint256,uint256,uint256,uint256))",
    "pay(uint256)",
]
PROXY_SIGS = ["depositTo(address)", "debt(address)", "reserves(address)", "pay(uint256)"]
IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"


def has_selector(code, sel):
    """A selector appears as PUSH4 (63<sel>) in a dispatcher, or as PUSH32 left-aligned
    (7f<sel> + 56 zeros) where the code builds a call to another contract."""
    h = sel[2:].lower()
    return ("63" + h) in code or ("7f" + h + "0" * 56) in code


def selftest():
    sel = "0xc290d691"
    cases = {"0x6080" + "63c290d691" + "14": True,            # PUSH4 (dispatcher)
             "0x6080" + "7fc290d691" + "0" * 56 + "60": True,  # PUSH32 (outgoing call)
             "0x6080" + "63deadbeef" + "14": False,            # another selector
             "0x6080" + "7fc290d691" + "0" * 55 + "1": False}  # not left-aligned
    bad = [c for c, want in cases.items() if has_selector(c, sel) != want]
    print("g1 selftest", "OK" if not bad else f"FAIL {bad}")
    return not bad


def impl_code(addr, rpc):
    impl = "0x" + cast("storage", addr, IMPL_SLOT, "--rpc-url", rpc)[-40:]
    return impl, cast("code", impl, "--rpc-url", rpc).lower()


def selectors():
    res = {}
    targets = [("lasna_system", SYSTEM, LASNA["rpc"], SYS_SIGS)] + [
        (f"proxy_{c['id']}", c["proxy"], c["rpc"], PROXY_SIGS) for c in CHAINS.values()]
    for name, addr, rpc, sigs in targets:
        impl, code = impl_code(addr, rpc)
        rows = []
        for s in sigs:
            sel = cast("sig", s)
            rows.append({"sig": s, "selector": sel, "in_impl_bytecode": has_selector(code, sel)})
        res[name] = {"proxy": addr, "implementation": impl, "checks": rows,
                     "all_found": all(r["in_impl_bytecode"] for r in rows)}
    s = load()
    s["selectors"] = res
    save(s)
    print(json.dumps({k: v["all_found"] for k, v in res.items()}))
    for k, v in res.items():
        for r in v["checks"]:
            if not r["in_impl_bytecode"]:
                print("  MISSING", k, r["sig"], r["selector"])


# ---------------------------------------------------------------- deploy
def deploy():
    s = load()
    me = deployer()
    if "rc" not in s:
        nonce = int(cast("nonce", me, "--rpc-url", LASNA["rpc"]))
        rc_pred = cast("compute-address", me, "--nonce", str(nonce)).split()[-1]
        s["rc_predicted"], s["rc_nonce"] = rc_pred, nonce
    save(s)
    for k, c in CHAINS.items():
        d = s.setdefault(k, {})
        if "ping" not in d:
            d["ping"] = create(c["rpc"], "SmokePing", [])
            save(s)
        if "recv" not in d:
            d["recv"] = create(c["rpc"], "SmokeReceiver", [c["proxy"], s["rc_predicted"]])
            save(s)
        print(k, "ping", d["ping"]["address"], "recv", d["recv"]["address"])
    if "rc" not in s:
        if int(cast("nonce", me, "--rpc-url", LASNA["rpc"])) != s["rc_nonce"]:
            raise SystemExit("Lasna nonce moved; the receivers point at a stale RC prediction")
        a, b = s["A"], s["B"]
        s["rc"] = create(LASNA["rpc"], "SmokeRC", [
            CHAINS["A"]["id"], a["ping"]["address"], a["recv"]["address"],
            CHAINS["B"]["id"], b["ping"]["address"], b["recv"]["address"], GAS_LIMIT])
        assert s["rc"]["address"].lower() == s["rc_predicted"].lower(), "RC address mismatch"
        save(s)
    print("rc", s["rc"]["address"])
    if "rc_fund" not in s:
        s["rc_fund"] = send(LASNA["rpc"], SYSTEM, "depositTo(address)", s["rc"]["address"], value=RC_FUND)
        save(s)
    for k, c in CHAINS.items():
        if "fund" not in s[k]:
            s[k]["fund"] = send(c["rpc"], c["proxy"], "depositTo(address)", s[k]["recv"]["address"], value=RECV_FUND)
            save(s)
    print("funded")


# ---------------------------------------------------------------- ping
def ping(nonce):
    s = load()
    for k, c in CHAINS.items():
        tx = send(c["rpc"], s[k]["ping"]["address"], "ping(uint256)", nonce)
        s.setdefault("pings", []).append({"chain": c["id"], "nonce": nonce, "tx": tx, "sent_at": int(time.time())})
        save(s)
        print(k, "ping", nonce, tx)


# ---------------------------------------------------------------- collect
def logs(rpc, addr, sig, from_block, chunk=900):
    """eth_getLogs in chunks: keyed RPC tiers cap the range (10 blocks on one provider), so
    log reads use the chains' public RPCs (`logrpc`), capped at 1,000 blocks."""
    head = int(cast("block-number", "--rpc-url", rpc)) - 5  # load-balanced RPCs disagree on the head
    res, b = [], from_block
    while b <= head:
        e = min(b + chunk - 1, head)
        out = cast("logs", "--from-block", str(b), "--to-block", str(e), "--address", addr, sig,
                   "--rpc-url", rpc, "--json")
        res += json.loads(out) if out else []
        b = e + 1
    return res


def words(data):
    h = data[2:]
    return [int(h[i:i + 64], 16) for i in range(0, len(h), 64)]


def tx_info(rpc, h):
    tx = json.loads(cast("tx", h, "--rpc-url", rpc, "--json"))
    rc = json.loads(cast("receipt", h, "--rpc-url", rpc, "--json"))
    return {"from": tx["from"], "to": tx["to"], "txGasLimit": int(tx["gas"], 16), "gasUsed": int(rc["gasUsed"], 16),
            "block": int(rc["blockNumber"], 16), "status": rc["status"]}


def collect():
    s = load()
    rc = s["rc"]["address"]
    rc_block = int(json.loads(cast("receipt", s["rc"]["tx"], "--rpc-url", LASNA["rpc"], "--json"))["blockNumber"], 16)
    reacted = []
    for lg in logs(LASNA["rpc"], rc, "Reacted(uint256,uint256,uint256,uint256)", rc_block):
        w = words(lg["data"])
        reacted.append({"originChain": int(lg["topics"][1], 16), "nonce": int(lg["topics"][2], 16),
                        "originTx": "0x%064x" % w[0], "reactTs": w[1], "reactiveTx": lg["transactionHash"],
                        "lasnaBlock": int(lg["blockNumber"], 16)})
    callbacks = []
    for k, c in CHAINS.items():
        d = s[k]
        start = tx_info(c["rpc"], d["recv"]["tx"])["block"]
        for lg in logs(c["logrpc"], d["recv"]["address"],
                       "Smoke(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256)", start):
            w = words(lg["data"])
            info = tx_info(c["rpc"], lg["transactionHash"])
            callbacks.append({
                "destChain": c["id"], "originChain": int(lg["topics"][1], 16), "nonce": int(lg["topics"][2], 16),
                "gasAtEntry": w[0], "gasLimitAsked": w[1], "originBlock": w[2], "originTs": w[3],
                "originTx": "0x%064x" % w[4], "reactTs": w[5], "destTs": w[6],
                "destTx": lg["transactionHash"], "destTxFrom": info["from"], "destTxTo": info["to"],
                "destTxGasLimit": info["txGasLimit"], "destTxGasUsed": info["gasUsed"],
                "originToReactS": w[5] - w[3], "reactToDestS": w[6] - w[5], "originToDestS": w[6] - w[3],
                # proxy overhead implied by this reading: gasAtEntry = 63/64 * (gasLimit - F)
                "fixedOverheadF": w[1] - (w[0] * 64 + 62) // 63,
                "url": f"{c['explorer']}/tx/{lg['transactionHash']}"})
    traces = {}
    for p in s.get("pings", []):
        try:
            t = rmcp.call("trace_origin_event", {
                "originChainId": p["chain"], "txHash": p["tx"], "rc": rc,
                "functionSignature": "onSmoke(address,uint256,uint256,uint256,uint256,uint256,uint256,uint64)"})
            traces[p["tx"]] = {"verdict": t.get("verdict"), "confidence": t.get("confidence"),
                               "summary": t.get("summary"),
                               "stages": [(f.get("stage"), f.get("verdict")) for f in t.get("findings", [])]}
        except Exception as ex:  # MCP is evidence, not a gate
            traces[p["tx"]] = {"error": str(ex)[:300]}
    try:
        h = rmcp.call("get_rc_health", {"rc": rc})
        health = {"verdict": h.get("verdict"), "summary": h.get("summary")}
    except Exception as ex:
        health = {"error": str(ex)[:300]}
    src = "\n".join((ROOT / "script" / "smoke" / f).read_text() for f in ("SmokeBases.sol", "SmokeContracts.sol"))
    try:
        cs = rmcp.call("check_rc_source", {"source": src})
        source_check = {"verdict": cs.get("verdict"), "summary": cs.get("summary"),
                        "findings": [(f.get("stage"), f.get("verdict"), f.get("summary")) for f in cs.get("findings", [])]}
    except Exception as ex:
        source_check = {"error": str(ex)[:300]}
    paths = sorted({f"{x['originChain']}->{x['destChain']}" for x in callbacks})
    got = {(x["originTx"].lower(), x["destChain"]) for x in callbacks}
    missing = [(p["tx"], c["id"]) for p in s.get("pings", []) for c in CHAINS.values()
               if (p["tx"].lower(), c["id"]) not in got]
    out = {
        "gate": "G1",
        "generated_by": "script/smoke/g1.py collect",
        "generated_at": int(time.time()),
        "gasLimitRequested": GAS_LIMIT,
        "contracts": {"rc": {"chain": LASNA["id"], **s["rc"]},
                      **{f"ping_{c['id']}": s[k]["ping"] for k, c in CHAINS.items()},
                      **{f"receiver_{c['id']}": s[k]["recv"] for k, c in CHAINS.items()}},
        "funding": {"rc_depositTo": s.get("rc_fund"), **{f"receiver_{c['id']}": s[k].get("fund")
                                                         for k, c in CHAINS.items()}},
        "selectors": s.get("selectors"),
        "pings": s.get("pings", []),
        "reactions": reacted,
        "callbacks": callbacks,
        "paths_delivered": paths,
        "missing_callbacks": missing,
        "timestamps_note": "latencies are differences of block timestamps on different chains (±1 s skew; may read negative)",
        "mcp_trace_origin_event": traces,
        "mcp_rc_health": health,
        "mcp_check_rc_source": source_check,
    }
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(json.dumps(out, indent=1) + "\n")
    print(f"reactions {len(reacted)} callbacks {len(callbacks)} paths {paths} missing {missing}")
    for x in callbacks:
        print(f"  {x['originChain']}->{x['destChain']} n={x['nonce']} gasAtEntry={x['gasAtEntry']} "
              f"txGas={x['destTxGasLimit']} o->r={x['originToReactS']}s r->d={x['reactToDestS']}s")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "selftest":
        sys.exit(0 if selftest() else 1)
    elif cmd == "selectors":
        selectors()
    elif cmd == "deploy":
        deploy()
    elif cmd == "ping":
        ping(int(sys.argv[2]) if len(sys.argv) > 2 else 1)
    elif cmd == "collect":
        collect()
    else:
        print(__doc__)
