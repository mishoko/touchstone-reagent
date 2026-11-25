#!/usr/bin/env python3
"""Writes the README's "Deployed addresses" table from audits/ (never typed by hand).

Every address links to its explorer, and every row links the transaction that deployed it, read from
audits/deployments-{1301,11155111,5318007}.json and, for the vaults, from the L-DYN rows of audits/loops.json.
  python3 script/site/addresses.py           # rewrite the block between the ADDR markers in README.md
  python3 script/site/addresses.py --check   # exit 1 if the block is stale
"""
import json, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
README = os.path.join(ROOT, "README.md")
BEGIN, END = "<!-- ADDR:BEGIN (script/site/addresses.py) -->", "<!-- ADDR:END -->"
EX = {"1301": "https://sepolia.uniscan.xyz", "11155111": "https://sepolia.etherscan.io",
      "5318007": "https://lasna.reactscan.net"}
NAME = {"1301": "Unichain Sepolia", "11155111": "Ethereum Sepolia", "5318007": "Reactive Lasna"}


def cs(x):
    return subprocess.run(["cast", "to-check-sum-address", x], capture_output=True, text=True, check=True).stdout.strip()


def addr(c, x):
    x = cs(x)
    return f"[`{x}`]({EX[c]}/address/{x})"


def tx(c, h, label="deploy"):
    return f"[{label}]({EX[c]}/tx/{h})"


def find_create(steps, address):
    """The tx that created `address` in any recorded step (the code contracts were reused from an earlier deploy)."""
    for v in steps.values():
        for t in v.get("txs") or []:
            if (t.get("address") or "").lower() == address.lower():
                return t["tx"]
    return None


def table():
    D = {c: json.load(open(os.path.join(ROOT, "audits", f"deployments-{c}.json")))["steps"] for c in EX}
    loops = json.load(open(os.path.join(ROOT, "audits", "loops.json")))["loops"]
    rows = []
    for key, name in (("rc", "`ReagentRC`, the reactive contract"), ("rcext", "`RcExt` (reached by delegatecall)"),
                      ("rcb6", "`RcB6` (reached by delegatecall)")):
        s = D["5318007"][key]
        rows.append((name, NAME["5318007"], addr("5318007", s["address"]), tx("5318007", s["tx"])))
    for key, name in (("hub", "`ReagentHub`, the callback receiver"), ("factory", "`CovenantFactory`"),
                      ("impl", "`Covenant` code"), ("ext", "`CovenantExt` code")):
        x = D["1301"]["reagent"]["reads"]["addresses"][key]
        cells = []
        for c in ("1301", "11155111"):
            h = find_create(D[c], x) or D[c]["reagent"]["txs"][0]["tx"]  # Hub: created by the factory's constructor
            cells.append(tx(c, h, NAME[c] + " deploy"))
        assert x.lower() == D["11155111"]["reagent"]["reads"]["addresses"][key].lower(), key
        rows.append((name, "both origin chains (CREATE2, one address)",
                     f"{addr('1301', x)} · [on Etherscan]({EX['11155111']}/address/{cs(x)})", " · ".join(cells)))
    for c in ("1301", "11155111"):
        p = D[c]["reagent"]["reads"]["ReagentHub.PROXY()"]
        rows.append(("Reactive callback proxy (theirs)", NAME[c], addr(c, p), "—"))
    for l in loops:
        if l.get("id") == "L-DYN":
            c = str(l["chain"])
            v = l["step"].split("_")[-1]
            rows.append((f"Touchstone vault `{v[0]}_{v[1]}` (curator {l['curator']})", NAME[c], addr(c, l["vault"]),
                         tx(c, l["originTx"])))
    hero = next(l for l in loops if l.get("id") == "L-PAUSE")
    rows.append(("The demo depositor's `Covenant`", "both origin chains", addr("1301", hero["covenant"]), "—"))
    rows.append(("The demo agent key", "Ethereum Sepolia", addr("11155111", hero["agent"]), "—"))
    out = ["| Contract | Network | Address | Deployed in |", "|---|---|---|---|"]
    out += [f"| {a} | {b} | {c} | {d} |" for a, b, c, d in rows]
    return "\n".join(out)


def main():
    text = open(README).read()
    i, j = text.index(BEGIN), text.index(END)
    new = text[: i + len(BEGIN)] + "\n" + table() + "\n" + text[j:]
    if "--check" in sys.argv:
        ok = new == text
        print("addresses.py --check:", "ok" if ok else "STALE")
        sys.exit(0 if ok else 1)
    open(README, "w").write(new)
    print("addresses.py: README table written")


if __name__ == "__main__":
    main()
