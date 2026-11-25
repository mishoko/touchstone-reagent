# Reference agent

`agent.py` is a reference for the Covenant's `agent` key: your agent (AI or script). The key has two powers, both
enforced by the Covenant and not by this script:

- `tighten(Rulebook)`: each field may only become stricter (CovenantExt `_looser`); an id may be removed, never added.
- `agentAllocate(vault, shares, max0, max1)`: into an allowlisted vault, within B6 and the per-epoch agent cap, priced
  against `tryRef`. The Covenant chooses no recipient; the shares stay in the Covenant.

The Reactive contract enforces the depositor's rules whether or not the agent is running. When the agent wakes after a
breach on the other chain, its allocation is refused by the Hub's mirror (`HubPaused`).

## Use

```
export RC_KEYSTORE_DIR=...   # holds the keystore `agent`
export RC_KEYSTORE_PW=...    # its password file
export ETH_SEPOLIA_RPC_URL=... UNICHAIN_SEPOLIA_RPC_URL=...

python3 script/agent/agent.py run --policy script/agent/policy.json [--once] [--dry] [--prove-refusal]
python3 script/agent/agent.py tighten --policy script/agent/policy.json [--dry]
python3 script/agent/agent.py --selftest
```

- `run`: on each tick, for each policy entry, makes an eth_call dry run of `agentAllocate` (max0/max1 = the Covenant's
  token balances) pinned to one block. A passing dry run is sent. A revert is decoded against CovenantBase's errors
  (`HubPaused`, `RecordPaused`, `Pending`, `AgentCap`, `OverBudget`, `PriceTolerance`, ...) and logged, and nothing is
  sent. `--prove-refusal` also sends one refused allocation per (chain, vault) per run, so the refusal exists as an
  on-chain reverted transaction. SIGINT/SIGTERM stop it after the action in flight, printing `agent stopped <time>`.
- `tighten`: applies the policy's `tighten` block (null by default, so nothing is applied) only if it is stricter than
  the Covenant's current `rules()`. Otherwise it is refused before any send. The block looks like this:
  `{"chain": "11155111", "covenant": "0x...", "rulebook": {"k": 1, "b3": true, "b4FloorBps": 0, "maxShareBps": 6000,
  "budget": "...", "b2": false, "b5MaxBurnBps": 0, "agentCapPerEpoch": "...", "ids": [2, 1, 0, 0]}}`.

## Guards

- It refuses to start if the keystore address is not the Covenant's `agent()` on that chain, or if it is the owner.
- Before every send it makes an eth_call dry run, sets an explicit gas limit of max(1.5 x estimate, 2M on 1301 / 4M on
  11155111), logs the hash as `pending` before waiting for the receipt, then logs the outcome.
- Keyed RPC URLs are redacted from every message and log line. The key is never printed.
- Log: `output/agent/agent-<chain>.jsonl`, one JSON line per action (ts, chain, block, action, tx, status, error).

## Limits

- This is a policy runner, not a strategy: it allocates a fixed `sharesPerTick` every tick and lets the Covenant refuse.
- A refusal is decoded only from the revert data `cast` prints; an unknown selector is logged as such and never sent
  as a proving refusal.
- The `tighten` pre-check mirrors the Covenant's rule so that it can refuse before any send. The Covenant's own check
  still decides on chain.

## Tests

`--selftest` runs offline (every chain call and send replaced): wrong keystore and owner key refused; a `HubPaused` dry
run logged and not sent; `--prove-refusal` sends exactly once per (chain, vault) at the floor gas limit; a passing dry
run sent at max(1.5 x estimate, floor); looser tightens (k, maxShareBps off, an added id, b3, budget, a permutation,
b5) refused before any send, and a stricter one sent; keyed RPC URLs redacted. Each refusal has a passing control.
