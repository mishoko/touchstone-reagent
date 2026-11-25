# Touchstone Reagent

**Exit on conduct, not on price.**

Reagent puts standing orders on a vault curator's *conduct* next to your vault shares. If the curator
breaks your rules on one chain, your new allocations to that curator stop on every chain. Your capital then
leaves the breached vault, in kind, to you only, once the curator's forfeited pay has finished dripping into
the vault.

It runs on [Touchstone](https://github.com/mishoko/touchstone), a Uniswap v4 hook vault where the curator pays
for its own execution shortfall. When a Touchstone curator abandons its range, Touchstone records a breach,
takes back the curator's unvested pay and burns it from the vault over a drip, which lifts every remaining
share. Touchstone keeps that record per vault and per chain. Reagent adds the record no single chain can hold:
**the curator's conduct across all its vaults on all chains**, kept by one reactive contract on Reactive
Network and pushed back to each chain.

> Your agent (AI or script) reasons, the contracts enforce and Reactive reacts, so the agent can sleep while
> the rules keep running.

### What is new here

A *conduct covenant* is a standing order on how a curator behaves. A single chain can't run one, and a
reactive contract can, because it has:

- memory: the RC keeps each curator's record (breaches, gone vaults, actions) and each depositor's holdings
  and rules in its own storage, so a decision uses that whole history and not only the last event;
- reach: one RC watches two chains and writes to both, so a breach on Unichain changes what is allowed on
  Ethereum Sepolia a few seconds later, with nobody in between;
- patience: it holds an exit until the forfeit drip is over, wakes Cron only while that work is pending, and
  drops it when the work is done.

Touchstone (the vault) is a pinned dependency and is not modified. Everything under `src/`, `test/` and
`script/` in this repo is Reagent.

To watch it, open [`frontend/index.html`](frontend/index.html) in a browser: it replays the recorded runs as an
animation and links every step to its transaction. There is also a short narrated walkthrough video.

---

## A breach, second by second

Alice holds Touchstone shares in two vaults run by the same curator, X: `X_A` on Unichain Sepolia and `X_B` on
Ethereum Sepolia. Her rule: *one breach by X anywhere, and I stop adding to X everywhere* (`k = 1`). Her agent
may add to X within her caps. Then X abandons its range on Unichain.

These are the timestamps of the recorded live run (25 Nov 2026, UTC; we induced the breach, see
[Limits](#limits-and-next-steps)):

```
14:31:24  Sepolia   Alice's agent makes its last allocation into X_B (ok). Then the agent is stopped.
          ...       38 minutes of silence from the agent.
15:09:56  Unichain  X_A's hook records the breach on chain (BreachLatched).
                    -> On Unichain, Alice's Covenant refuses any new allocation to X from this block.
15:09:56  Lasna     ReagentRC reacts: curator X now has 1 breach; snapshot seq 50 sent to both Hubs.
15:10:00  Sepolia   ReagentHub applies it (Applied). Alice is paused for X on Sepolia too.       (+4 s)
15:10:24  Sepolia   The agent wakes up and tries to allocate into X_B -> reverts HubPaused.
~15:11    Unichain  processBreach() (an open call): Touchstone settles the breach (forfeit 0 on this run).
          ...       The RC holds Alice's exit on Cron ticks until its estimated drip end.
16:11:01  Unichain  rcExit lands: Alice's X_A position leaves, in kind, to her address only. (+61 min)
                    36.257242 mUSDC + 0.012030 mWETH, exactly the amounts in the Covenant's note.
```

Alice's agent was offline through the breach and the pause. The pause on Sepolia came from a log on Unichain.

---

## How it fits together

```
   Unichain Sepolia (1301)            Reactive Lasna (5318007)            Ethereum Sepolia (11155111)
 ┌──────────────────────────┐      ┌─────────────────────────────┐      ┌──────────────────────────┐
 │ Touchstone vault X_A     │      │ ReagentRC                   │      │ Touchstone vault X_B     │
 │  + hook  ── logs ────────┼─────►│   react(LogRecord)          │◄─────┼──── logs ──  + hook      │
 │   BreachLatched, Action, │      │   ├─ RcExt  (delegatecall)  │      │   BreachLatched, Action, │
 │   EpochRecorded, ...     │      │   │   STATE intake, exits,  │      │   EpochRecorded, ...     │
 │                          │      │   │   Cron tick             │      │                          │
 │ Covenant (Alice) ──note──┼─────►│   └─ RcB6   (delegatecall)  │◄─────┼──note── Covenant (Alice) │
 │   ▲ rcExit / rcAllocate  │      │       cross-chain budget    │      │  rcExit / rcAllocate ▲   │
 │   │                      │      │                             │      │                      │   │
 │ ReagentHub ◄─ callback ──┼──────┤   requestCallback  ─────────┼──────┼─ callback ─► ReagentHub│
 │  conduct mirror,         │proxy │   (one RC, two origins,     │proxy │  conduct mirror,         │
 │  budgets, vault binding  │      │    two destinations)        │      │  budgets, vault binding  │
 └──────────────────────────┘      └─────────────────────────────┘      └──────────────────────────┘
     Alice / her agent ──► Covenant.allocate / agentAllocate  (guarded on every chain, every call)
```

| Contract | Where | What it does |
|---|---|---|
| `Covenant` | each origin chain, same address on both | Holds one depositor's vault shares. Runs the local guard inside every allocate. Tokens leave only to the owner or into a vault on the same chain. |
| `ReagentHub` | each origin chain, same address on both | The only callback recipient. Immutable, ownerless, holds no tokens. Keeps the curator conduct mirror, the per-chain budgets and the vault-to-curator bindings. |
| `CovenantFactory` | each origin chain | Deploys Covenants (CREATE2, salt = owner) and, in its constructor, the Hub. |
| `ReagentRC` + `RcExt` + `RcB6` | Lasna | One reactive contract split in three modules on one storage layout (`RcExt` and `RcB6` are reachable only by internal `delegatecall` inside a reaction). Keeps the cross-chain record and schedules exits. |

### The loop: observe, remember, evaluate, react

```
  OBSERVE                 REMEMBER                      EVALUATE                       REACT
  vault + hook logs  ──►  per curator: breaches,   ──►  per depositor: k reached?  ──►  rcConduct → both Hubs (pause)
  on two chains           gone vaults, actions,         exit armed? drip over?          rcExit    → Covenant (exit)
  Covenant notes          per depositor: holdings,      budget split still within       rcBudget  → Hub (B6 move)
                          rules, budget split           the cap?                        rcAllocate→ Covenant (plan)
                          (persistent RC storage)                                       Cron: only while work waits
```

### The rules a depositor can set

| Rule | Checked where | Effect |
|---|---|---|
| **B7 record**: X's breaches across all its vaults and chains ≥ `k` | Reactive record, plus the local hook on the breach chain | pause X on both chains; arm a patient exit from each vault breached since you entered |
| **B3 gone**: one of X's vaults exited or retired | Reactive record, plus local | pause X; patient exit from that vault |
| **B4 bond floor**: X's bond fell below a share of what it was | local only | refuse the allocation |
| **B6 concentration**: your total exposure to X across chains ≤ your cap | local check against a per-chain budget; the RC moves budgets, lowering before raising | refuse the allocation |
| **B2 contagion** (opt-in) | Reactive | also exit X's vaults on the other chain |

The rules a chain can check itself run inside `allocate`, with no message needed. Cross-chain rules apply once
Reactive delivers.

### Who may do what

```
 owner (you)  : allocate, leave (always), setRules, setAgent, setAllowed, setPlan, unpause
 agent key    : tighten (stricter only), agentAllocate (allowlisted vault, within caps), flush
 Hub (via RC) : rcExit, rcAllocate        -- after auth they never revert; every outcome is a note
 nobody       : send your tokens anywhere but to you or into a vault on the same chain
```

The agent key can only tighten. A tighten can pause a curator (and so arm an exit), but it can never loosen a
rule, raise a budget, or move the drip-end earlier. `leave()` works whenever Touchstone's own `withdraw` would,
whatever Reactive does.

### Why the exit waits for the drip

When Touchstone forfeits a breaching curator's unvested pay, it burns those shares over a drip window. Every
holder who stays until the end of the drip gets that value. A depositor who runs at the moment of the breach
gives it up. Reagent's exit is *patient*: it is scheduled no earlier than the drip end, and the Covenant
re-checks the drip on delivery, so no key can move it earlier. The `T-DRIP` test measures this on a full
Touchstone deployment: patient minus immediate equals the holder's share of the burned forfeit.

---

## What was proven live

All runs used the deployed contracts below and were recorded by script (`script/live/loops.py`) into
[`audits/loops.json`](audits/loops.json), read back from receipts and logs. Full origin → Lasna → destination
hashes for each are in [VERIFY.md](VERIFY.md).

| Run | What happened | Key tx |
|---|---|---|
| **L-PAUSE** | A breach recorded on Unichain paused the curator for the depositor on Ethereum Sepolia **4 s** later (paused false the block before, true at it). | [breach](https://sepolia.uniscan.xyz/tx/0xb6a8f0fde442f421ff07b08fe4dfa614ec4271f507843c54ecc90b5f7835f26d) → [reaction](https://lasna.reactscan.net/tx/0x5c554e647479ec1eaa39db517d79753ed1c981a2095b0c5017d92fe4de52396a) → [Applied](https://sepolia.etherscan.io/tx/0x7d405efb660322915707c12f4252754c86b42d78a747933e983824ea1085ac63) |
| **L-OFFLINE** | The agent was stopped before the breach; when it woke, its next allocation was refused `HubPaused` on chain. | [last ok](https://sepolia.etherscan.io/tx/0xe9b2d863f55901bd4c86fb15b7d2ddaae1066f7c56ba8d1086580b848c0e84f8), [refused](https://sepolia.etherscan.io/tx/0x5d72faf74634b15fcf1f9cfcef5e947530292ec58399a668aed3580e3c97d42f) |
| **L-EXIT** (exit leg) | 61 min after the breach was recorded, the patient exit landed: exactly the noted tokens, in kind, to the owner, no other recipient. | [ExitDone](https://sepolia.uniscan.xyz/tx/0x3f7bcb43675ff4a8806f82067d2c9658f66b871899fbe4d21213c9bde27c1e71) |
| **L-PLAN** | A standing plan deposited **2 s** after `EpochRecorded` on two epochs; after the breach the RC withheld the plan while paused. | [epoch 19098](https://sepolia.uniscan.xyz/tx/0xc62444d0970717404e6a47ef476c2bfc74265a48780c89f995ec1bbb9f45d8d9), [19099](https://sepolia.uniscan.xyz/tx/0x90287a7fba325e5d73a0dfbcba58c11f040aec868877b976a38cf26a585dfc33) |
| **L-DYN** | Three vaults deployed by registered bundlers were subscribed from inside `react()` and bound on their Hub (4 s, 4 s, 12 s), with no redeploy and no operator step. | [X_A bound](https://sepolia.uniscan.xyz/tx/0xcdbfad08d30d32627b2002accb22774e7a1cd6e13a429b16acce23efc9821088) |
| **L-CRON** | Cron subscribed in the reaction to a retired vault, ran 35 ticks, and unsubscribed right after that exit was done. Subscription count back to baseline. | [subscribe](https://lasna.reactscan.net/tx/0xf2874ed77f0457a4925e2ac1a7725e25834aee8a0ec2807b16e02502e864d968), [unsubscribe](https://lasna.reactscan.net/tx/0x6cd808c5be8686157cc26cfd0499ebe137d889ff4915d930be34b1b70bf2ae51) |
| **L-SPOOF** | A third-party reactive contract sent a callback to our Hub: rejected `NotRc`, no Hub log, the record unchanged. | [rejected](https://sepolia.uniscan.xyz/tx/0x2c4b1abca71cfe3a62b0c4b00ff6a1f4c821430eeec4e9583a029f4da3b2c97f) |
| **L-PAY** | A Hub funded only by a plain transfer paid for its first callback; debt 0, on both chains. | [1301](https://sepolia.uniscan.xyz/tx/0xcdbfad08d30d32627b2002accb22774e7a1cd6e13a429b16acce23efc9821088), [11155111](https://sepolia.etherscan.io/tx/0x6195de50baf14362b6280177f04bda142ad3de99a1416b71e60b078fdd3f1ca7) |

**Conduct loops** (a curator `Action` on one chain → the RC → `Applied` on each Hub), end to end:

| Path | Delivered | Median | p95 | Max |
|---|---|---|---|---|
| Unichain → Unichain (AA) | 39 / 39 | 2 s | 3 s | 3 s |
| Unichain → Sepolia (AB) | 39 / 39 | 9 s | 21 s | 24 s |
| Sepolia → Unichain (BA) | 26 / 26 | 3 s | 4 s | 4 s |
| Sepolia → Sepolia (BB) | 26 / 26 | 12 s | 36 s | 60 s |

Latency is destination block time minus origin block time, both read by RPC. Sepolia destinations have a
one-block (about 12 s) floor.

---

## How deeply it is tested

```
  362 forge tests passing (0 failing)        ~296 test functions
  ├─ unit + integration   on a real Touchstone deployment from the pinned dependency's own factory
  ├─ R layer              the RC driven by exact LogRecords, against a stand-in system contract that
  │                       burns the measured Lasna cost of every subscribe and callback request
  ├─ attack cells         30 attack cells; each asserts "the attack loses" AND has a positive
  │                       control that shows the same attack wins once the defence is removed
  │                       (the exit sandwich's control is a price-based exit instead)
  ├─ invariants           11 (I-OWN, I-AUTH, I-IDEM, I-LEAVE, I-TIGHT, I-SHARES x3, I-MONO, I-STALE, I-ETH)
  │                       fuzzed at 64 runs x 64 calls in every suite run; a deeper
  │                       256 x 128 profile is in foundry.toml
  └─ mutation             148 curated mutants: 141 killed, 7 equivalent  (100% of killable killed)
                          every mutant names the test that must kill it; tagged // [MU-xxx] in src/
  tooling selftests       loops.py 145 cells; the evidence collector itself is mutation-tested
```

A few of the attacks that lose: spoofed callbacks (wrong proxy, wrong RC, wrong first word); a stale or forged
exit against a healthy vault; replays; an agent trying to loosen rules; a cross-chain budget clawback race; a
sandwich around the patient exit (the attacker ends at or below zero; the control, a price-based exit, loses
more than 1% to the same sandwich); a sandwich around an agent deposit (refused `PriceTolerance`, and the plan
deposit is skipped).

---

## Deployed addresses

<!-- ADDR:BEGIN (script/site/addresses.py) -->
| Contract | Network | Address | Deployed in |
|---|---|---|---|
| `ReagentRC`, the reactive contract | Reactive Lasna | [`0xFbcDba49a040Ca5965377F73bB327F2F2B7DC4c9`](https://lasna.reactscan.net/address/0xFbcDba49a040Ca5965377F73bB327F2F2B7DC4c9) | [deploy](https://lasna.reactscan.net/tx/0x82936be31ffa48445be2f40de9f12d4e931f521931d4983b5650cef80ccba58b) |
| `RcExt` (reached by delegatecall) | Reactive Lasna | [`0xA9B408A944337A1BbcE77c6823FaD226DE4c228d`](https://lasna.reactscan.net/address/0xA9B408A944337A1BbcE77c6823FaD226DE4c228d) | [deploy](https://lasna.reactscan.net/tx/0xafb7507277dc35ac2fa446c24d44d3efe445a33b3e77747472a1a21501dac1b4) |
| `RcB6` (reached by delegatecall) | Reactive Lasna | [`0xdb671DB6Df964F18D58D23d8324aE1FAaE43EF9E`](https://lasna.reactscan.net/address/0xdb671DB6Df964F18D58D23d8324aE1FAaE43EF9E) | [deploy](https://lasna.reactscan.net/tx/0xc00227f107660ba0cbe3659eb63a689691be4a7dba9851740fe14acfbe3b8ff3) |
| `ReagentHub`, the callback receiver | both origin chains (CREATE2, one address) | [`0xb41433C9585d230A2607f253E1EA844923e07a91`](https://sepolia.uniscan.xyz/address/0xb41433C9585d230A2607f253E1EA844923e07a91) · [on Etherscan](https://sepolia.etherscan.io/address/0xb41433C9585d230A2607f253E1EA844923e07a91) | [Unichain Sepolia deploy](https://sepolia.uniscan.xyz/tx/0x8e9abdf0e7c377e51e21b0d26ecae2b0cfda1aab19f74ef41ca0ef2b0b898ba0) · [Ethereum Sepolia deploy](https://sepolia.etherscan.io/tx/0x26b89b2c1a9907b0048621469a8599848917efa2a4061f269687fd6f5c77e13b) |
| `CovenantFactory` | both origin chains (CREATE2, one address) | [`0xA3fE3C3756Fc204DF54A221A45405e82B19d481f`](https://sepolia.uniscan.xyz/address/0xA3fE3C3756Fc204DF54A221A45405e82B19d481f) · [on Etherscan](https://sepolia.etherscan.io/address/0xA3fE3C3756Fc204DF54A221A45405e82B19d481f) | [Unichain Sepolia deploy](https://sepolia.uniscan.xyz/tx/0x8e9abdf0e7c377e51e21b0d26ecae2b0cfda1aab19f74ef41ca0ef2b0b898ba0) · [Ethereum Sepolia deploy](https://sepolia.etherscan.io/tx/0x26b89b2c1a9907b0048621469a8599848917efa2a4061f269687fd6f5c77e13b) |
| `Covenant` code | both origin chains (CREATE2, one address) | [`0xDEb3E647AC0f9f972D5Ba6A45aCb5Bd572541731`](https://sepolia.uniscan.xyz/address/0xDEb3E647AC0f9f972D5Ba6A45aCb5Bd572541731) · [on Etherscan](https://sepolia.etherscan.io/address/0xDEb3E647AC0f9f972D5Ba6A45aCb5Bd572541731) | [Unichain Sepolia deploy](https://sepolia.uniscan.xyz/tx/0xb4d93c83a0e3486c3c51d6b0113245354886a64537bef20f13ceca70ce162623) · [Ethereum Sepolia deploy](https://sepolia.etherscan.io/tx/0x33e1b911542f266c4f2a34e68a619a171c16635375e2a66642453ceda434a131) |
| `CovenantExt` code | both origin chains (CREATE2, one address) | [`0x39Da1F404B98fe0390A4d4E648C0bC8E030Aa061`](https://sepolia.uniscan.xyz/address/0x39Da1F404B98fe0390A4d4E648C0bC8E030Aa061) · [on Etherscan](https://sepolia.etherscan.io/address/0x39Da1F404B98fe0390A4d4E648C0bC8E030Aa061) | [Unichain Sepolia deploy](https://sepolia.uniscan.xyz/tx/0xa3d0325b253bfa20e1f71a06b56651d822e8ed081840736137eb4b19d4173244) · [Ethereum Sepolia deploy](https://sepolia.etherscan.io/tx/0x8b7f977fa6f287737dd5883c33f0f28a27e49e98f766f319e826467bcfe4dc88) |
| Reactive callback proxy (theirs) | Unichain Sepolia | [`0x775c9B990ADe401060B78D0e98684eEf8d2466C1`](https://sepolia.uniscan.xyz/address/0x775c9B990ADe401060B78D0e98684eEf8d2466C1) | — |
| Reactive callback proxy (theirs) | Ethereum Sepolia | [`0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4`](https://sepolia.etherscan.io/address/0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4) | — |
| Touchstone vault `X_A` (curator 1) | Unichain Sepolia | [`0x308A85113ae15d4b184Dfd0b70eb397850F3Fa59`](https://sepolia.uniscan.xyz/address/0x308A85113ae15d4b184Dfd0b70eb397850F3Fa59) | [deploy](https://sepolia.uniscan.xyz/tx/0x383a1ebf172c5dab9bdc2fbc2f50850bd3bda28e409c1a898e2de87eccdb2818) |
| Touchstone vault `Y_A` (curator 2) | Unichain Sepolia | [`0x50aD0a9eF6c8F87b4e926fE1AB3Ae2285CDDE362`](https://sepolia.uniscan.xyz/address/0x50aD0a9eF6c8F87b4e926fE1AB3Ae2285CDDE362) | [deploy](https://sepolia.uniscan.xyz/tx/0x560934ed8ae1844012bc23939002ea61361f9bed33535fb4d85a7d8f30fd4649) |
| Touchstone vault `X_B` (curator 1) | Ethereum Sepolia | [`0x67fF755e233c3F550303c658aB8C55953f231a46`](https://sepolia.etherscan.io/address/0x67fF755e233c3F550303c658aB8C55953f231a46) | [deploy](https://sepolia.etherscan.io/tx/0x6bb6248ae51c29a34de3babd0e17f71171695fa4a20f4a1ceb590d379860cb49) |
| The demo depositor's `Covenant` | both origin chains | [`0xB02b6081546c23CA2191D3Ce0647b64f5Ef4D15f`](https://sepolia.uniscan.xyz/address/0xB02b6081546c23CA2191D3Ce0647b64f5Ef4D15f) | — |
| The demo agent key | Ethereum Sepolia | [`0xACCb871E94bC1d728A5f969928fB8680C3523492`](https://sepolia.etherscan.io/address/0xACCb871E94bC1d728A5f969928fB8680C3523492) | — |
<!-- ADDR:END -->

This table is written by `script/site/addresses.py` from `audits/deployments-{1301,11155111,5318007}.json`
and `audits/loops.json`, which hold every deployment transaction with its block and gas.

---

## Quickstart

```bash
git clone --recursive https://github.com/mishoko/touchstone-reagent && cd touchstone-reagent

forge test                                              # the full suite (solc 0.8.26, cancun, via_ir)
FOUNDRY_PROFILE=invariant forge test --match-path "test/invariant/*"   # the deeper 256 x 128 profile
python3 script/mutate.py --audit                        # every [MU-xx] tag has a mutant and vice versa
python3 script/mutate.py -j 1 MU-001                    # run one mutant against its named killer

python3 script/live/loops.py --selftest                 # the evidence collector's own cells
python3 script/agent/agent.py --selftest                # the reference agent, offline
```

The live drivers (`script/live/drive.py`) and the reference agent (`script/agent/`, see its README) need RPC
URLs and keys in `.env`; they dry-run every send before sending.

---

<details>
<summary><b>Limits and next steps</b></summary>

- Testnet only, with mock tokens. The demo is single-actor: we play the curator, the depositor and the RC
  owner, and we induce the breaches by moving a thin mock reference pool.
- The live exit's forfeit was 0. The live patient exit ran exactly, in kind, to the owner, but on that run the
  curator had no unvested pay to forfeit, so nothing dripped. The `T-DRIP` test (a local test on a real
  Touchstone deployment) shows the value a patient exit keeps from the burned forfeit.
- Cross-chain rules wait for delivery. During a Reactive lag, an allocation on the other chain can still go
  through. That misses a protection but loses no funds: a late or lost message never loosens a limit and
  never sends funds anywhere but to you.
- Events need vault activity. An idle vault emits nothing; in the demo we drive the activity.
- The RC owner registers curator identity: a bundler must be registered before it deploys.
- EOA owners only. Covenant creation is allowlisted on the demo (the admin controls the list, never funds or
  rules). Exposure is valued at cost.
- The conduct-loop latencies above come from one day's batches. The cross-chain budget moves (B6) are covered
  by tests and the R layer and have no live latency series.
- Lasna posts no delivery records today; latency is read from destination logs.
- Comment tags in `src/` (`PA-`, `PB-`, `r12 D12-03` and similar) point to our private design and review notes.
  The deployed source is kept byte-for-byte, so the tags stay; the mechanism is described here and in VERIFY.md.

</details>

See also [SECURITY.md](SECURITY.md) (invariants, trust roots, known limits) and [CREDITS.md](CREDITS.md).
