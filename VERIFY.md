# Verify it yourself

Every live claim in the README is a chain of transactions you can open in an explorer or replay with `cast`.
Each one was recorded by script into [`audits/loops.json`](audits/loops.json), read back from receipts and
logs, never typed by hand. This page lists the hashes leg by leg and the commands that check them.

A loop has three legs:

```
 ORIGIN (1301 or 11155111)        REACTIVE (Lasna 5318007)             DESTINATION (1301 or 11155111)
 a vault/hook/Covenant log  ───►  ReagentRC's react(LogRecord) tx ───►  callback through the chain's proxy
                                  + callback request log                 into ReagentHub (or a Covenant)
```

To tie the origin leg to the Reactive leg: the Lasna reaction is a transaction sent to Reactive's system
contract `0x8888…8888`, which calls the RC's `react(LogRecord)`. The record carries the origin chain id, the
emitter, `topic0`, the origin tx hash and the log index. For an RC reaction the first word is the RC address.

To tie the Reactive leg to the destination: the reaction's receipt holds a callback request log (from
`0x8888…8888`, topic0 `0xef94dbc6…b133`) naming the destination chain, the Hub and the payload (for a conduct
update: `rcConduct`, curator id, counts, `seq`). That chain's callback proxy sends the destination tx, which
emits the matching event (`Applied(id, seq)`, `VaultBound`, or a Covenant `Note`). Lasna does not post
delivery records today, so you check the delivery on the destination chain.

## Setup

```bash
export U=https://sepolia.unichain.org                      # Unichain Sepolia, 1301
export S=https://ethereum-sepolia-rpc.publicnode.com       # Ethereum Sepolia, 11155111
export L=https://lasna-rpc.rnk.dev/                        # Reactive Lasna, 5318007

export RC=0xFbcDba49a040Ca5965377F73bB327F2F2B7DC4c9       # ReagentRC (Lasna)
export HUB=0xb41433C9585d230A2607f253E1EA844923e07a91      # ReagentHub (same address on 1301 and 11155111)
export COV=0xB02b6081546c23CA2191D3Ce0647b64f5Ef4D15f      # the demo Covenant (same address on both chains)
export OWNER=0x07F30b8e65938aBC2F728878e8AFc51FfEdB8213
export AGENT=0xACCb871E94bC1d728A5f969928fB8680C3523492
```

Explorers: Unichain Sepolia `https://sepolia.uniscan.xyz/tx/<hash>`, Ethereum Sepolia
`https://sepolia.etherscan.io/tx/<hash>`, Lasna `https://lasna.reactscan.net/tx/<hash>`.

Reads pinned to an old block (`--block N`) need an RPC that serves historical state; use an archive endpoint
if the public one refuses.

---

## 1. L-PAUSE: a breach on Unichain pauses the curator on Sepolia (4 s)

| Leg | Chain | Tx | Block | Time (UTC) |
|---|---|---|---|---|
| Breach recorded by `X_A`'s hook | 1301 | [`0xb6a8f0fd…f26d`](https://sepolia.uniscan.xyz/tx/0xb6a8f0fde442f421ff07b08fe4dfa614ec4271f507843c54ecc90b5f7835f26d) | 68766968 | 15:09:56 |
| RC reaction (curator 1, seq 50) | Lasna | [`0x5c554e64…396a`](https://lasna.reactscan.net/tx/0x5c554e647479ec1eaa39db517d79753ed1c981a2095b0c5017d92fe4de52396a) | | 15:09:56 |
| `Applied` on the Sepolia Hub | 11155111 | [`0x7d405efb…ac63`](https://sepolia.etherscan.io/tx/0x7d405efb660322915707c12f4252754c86b42d78a747933e983824ea1085ac63) | 12210319 | 15:10:00 |

```bash
# origin: the log comes from X_A's hook
cast receipt 0xb6a8f0fde442f421ff07b08fe4dfa614ec4271f507843c54ecc90b5f7835f26d --rpc-url $U | grep 0x377e71f9

# reactive: the system's call to react(); the input names the RC, chain 1301, the hook and the origin tx
cast tx 0x5c554e647479ec1eaa39db517d79753ed1c981a2095b0c5017d92fe4de52396a --rpc-url $L

# destination: paused flips exactly at the delivery block
cast call $HUB "paused(address,uint32)(bool)" $COV 1 --block 12210318 --rpc-url $S   # false
cast call $HUB "paused(address,uint32)(bool)" $COV 1 --block 12210319 --rpc-url $S   # true
cast call $HUB "conduct(uint32)(uint32,uint32,uint32,uint64)" 1 --rpc-url $S        # breaches 1 or more, seq 50 or later
```

## 2. L-OFFLINE: the agent sleeps through the breach, wakes, and is refused

| Step | Tx | Nonce | Time (UTC) | Status |
|---|---|---|---|---|
| Agent's last allocation (before the breach) | [`0xe9b2d863…84f8`](https://sepolia.etherscan.io/tx/0xe9b2d863f55901bd4c86fb15b7d2ddaae1066f7c56ba8d1086580b848c0e84f8) | 6 | 14:31:24 | success |
| (agent stopped; breach and pause as in §1) | | | | |
| Agent's next allocation into `X_B` | [`0x5d72faf7…d42f`](https://sepolia.etherscan.io/tx/0x5d72faf74634b15fcf1f9cfcef5e947530292ec58399a668aed3580e3c97d42f) | 7 | 15:10:24 | reverted `HubPaused` |

```bash
cast tx 0x5d72faf74634b15fcf1f9cfcef5e947530292ec58399a668aed3580e3c97d42f --rpc-url $S   # from $AGENT, nonce 7
cast sig "HubPaused()"                                                                   # 0x67be7162
# replay the same call at the block before it landed to read the revert reason
cast call $COV $(cast tx 0x5d72faf74634b15fcf1f9cfcef5e947530292ec58399a668aed3580e3c97d42f input --rpc-url $S) \
  --from $AGENT --block 12210320 --rpc-url $S                                            # reverts 0x67be7162
```

Nonces 6 → 7 show the agent sent nothing in between.

## 3. L-CON: one conduct loop per path

A curator `Action` (a range re-placement) on one chain → the RC → `Applied(1, seq)` on each Hub.

| Path | Origin | Lasna reaction | Destination `Applied` | End to end |
|---|---|---|---|---|
| AA (1301 → 1301) | [`0x7f13ffdb…4c77`](https://sepolia.uniscan.xyz/tx/0x7f13ffdb6745c3512598c27fea989fd7e49dac1158a1268685ba8c9891cd4c77) | [`0xbb068e24…d8bd5`](https://lasna.reactscan.net/tx/0xbb068e24153ccdac9df89bf09bd61ef752823c8e00d9598c3657f540806d8bd5) | [`0x190adeb6…7c10`](https://sepolia.uniscan.xyz/tx/0x190adeb63586ec5920a1b7f2dc887ed0e79913a0e06c827a5126ddc53a217c10) | 3 s |
| AB (1301 → 11155111) | same origin | same reaction | [`0xbb55d2f7…b4a3`](https://sepolia.etherscan.io/tx/0xbb55d2f7e964e060d798157c30122c5bd2a2e32b233a9288e76127fbaefbb4a3) | 9 s |
| BA (11155111 → 1301) | [`0x953a5b59…08d2`](https://sepolia.etherscan.io/tx/0x953a5b59182db90cd455316114790ded87c7e4943fb9970a1e1fe97ab3f908d2) | [`0x4ff20c42…1c23`](https://lasna.reactscan.net/tx/0x4ff20c42b7a5d5f57c4d7276097b4c5ef06083c1b591dcdfa653eeb054d11c23) | [`0xbc815272…27a2`](https://sepolia.uniscan.xyz/tx/0xbc815272241b511e021d53ca47c17114be403f8412fc548856cb6eff624b27a2) | 2 s |
| BB (11155111 → 11155111) | same origin | same reaction | [`0x48fbfaeb…34ae8`](https://sepolia.etherscan.io/tx/0x48fbfaeb78bbed0ee0166247c3d0326004d85a06bb9f33f0f77dca2a69a34ae8) | 60 s (this path's max) |

One reaction feeds both chains: its receipt holds two callback requests, one per Hub, with the same `seq`
(3 for the AA/AB row, 26 for BA/BB). All 130 loops (39 + 39 + 26 + 26) are in `audits/loops.json` with
their three hashes; the per-path statistics are under `stats`.

```bash
cast receipt 0xbb068e24153ccdac9df89bf09bd61ef752823c8e00d9598c3657f540806d8bd5 --rpc-url $L   # two callback requests
cast receipt 0x190adeb63586ec5920a1b7f2dc887ed0e79913a0e06c827a5126ddc53a217c10 --rpc-url $U   # Applied(1, 3) from $HUB
python3 -c "import json;[print(l['id'],l['originTx'],l['lasnaTx'],l['destTx'],l['latency_s']) for l in json.load(open('audits/loops.json'))['loops'] if l['id'].startswith('L-CON')]"
```

## 4. L-DYN: a new vault is subscribed from inside `react()`

The RC owner registers a curator's bundler first. When that bundler deploys a vault, the RC sees `Deployed`,
subscribes to the new vault's events and binds it on that chain's Hub, with no redeploy and no operator step.

| Vault | `addBundler` (Lasna) | Vault deploy (origin) | `VaultBound` on the Hub | Latency |
|---|---|---|---|---|
| `X_A`, curator 1 | [`0xd246c16e…e8d8`](https://lasna.reactscan.net/tx/0xd246c16eb59a130b0ff5d935f7403f001e13ebf7d619855a00908878c393e8d8) | [`0x383a1ebf…2818`](https://sepolia.uniscan.xyz/tx/0x383a1ebf172c5dab9bdc2fbc2f50850bd3bda28e409c1a898e2de87eccdb2818) | [`0xcdbfad08…1088`](https://sepolia.uniscan.xyz/tx/0xcdbfad08d30d32627b2002accb22774e7a1cd6e13a429b16acce23efc9821088) | 4 s |
| `Y_A`, curator 2 | [`0x5e962d2c…e46b`](https://lasna.reactscan.net/tx/0x5e962d2ca02fe949ee9b669c34012a7e471c23d1520b100af4389c129c8fe46b) | [`0x560934ed…4649`](https://sepolia.uniscan.xyz/tx/0x560934ed8ae1844012bc23939002ea61361f9bed33535fb4d85a7d8f30fd4649) | [`0xf070ffd8…68ba`](https://sepolia.uniscan.xyz/tx/0xf070ffd832a1a467ac9ff6fe187b312823cbbb812e5f03646237cf110ff868ba) | 4 s |
| `X_B`, curator 1 | [`0x593774fa…b4ff`](https://lasna.reactscan.net/tx/0x593774fa2c885671b330fe8dc347fc94f13b84eb9e6ecd443aee77ac2745b4ff) | [`0x6bb6248a…cb49`](https://sepolia.etherscan.io/tx/0x6bb6248ae51c29a34de3babd0e17f71171695fa4a20f4a1ceb590d379860cb49) | [`0x56a544f0…9cfe`](https://sepolia.etherscan.io/tx/0x56a544f0feed436d37a77a996c41b83dc360eb4c9f2c2573d9d92ce122769cfe) | 12 s |

```bash
cast call $HUB "vaultId(address)(uint32)" 0x308a85113ae15d4b184dfd0b70eb397850f3fa59 --rpc-url $U   # 1
cast call $HUB "vaultId(address)(uint32)" 0x67ff755e233c3f550303c658ab8c55953f231a46 --rpc-url $S   # 1
```

## 5. L-EXIT: the patient exit lands, in kind, to the owner only

| Leg | Chain | Tx | Block |
|---|---|---|---|
| Breach recorded on `X_A` (the same breach as §1) | 1301 | [`0xb6a8f0fd…f26d`](https://sepolia.uniscan.xyz/tx/0xb6a8f0fde442f421ff07b08fe4dfa614ec4271f507843c54ecc90b5f7835f26d) | 68766968 |
| `processBreach()` (open call) | 1301 | [`0xaf139a0f…a3f6`](https://sepolia.uniscan.xyz/tx/0xaf139a0ff3573afa6bcd1215e88a51dc1c97afb3f1f6dd38c213c0f84605a3f6) | 68767059 |
| `rcExit` delivered, `ExitDone` | 1301 | [`0x3f7bcb43…1e71`](https://sepolia.uniscan.xyz/tx/0x3f7bcb43675ff4a8806f82067d2c9658f66b871899fbe4d21213c9bde27c1e71) | 68770633 |

The exit landed 3,665 s (61 min) after the breach was recorded, sent by the callback proxy. The Covenant's note says
36,257,242 mUSDC units (6 dp) and 12,030,473,297,643,707 mWETH wei; the receipt's token transfers move exactly
those amounts to the owner and to no one else.

```bash
cast receipt 0x3f7bcb43675ff4a8806f82067d2c9658f66b871899fbe4d21213c9bde27c1e71 --rpc-url $U
#  Transfer logs: mUSDC 0x1afe15c3…9e64 and mWETH 0x88c16a89…e64d, recipient $OWNER only
```

On this run the curator had no unvested pay at the breach, so the forfeit was 0. The RC still held the exit
until its own drip-end estimate (the 61 minutes), and the Covenant found no drip left when it arrived. A full exit with a drip, answered `ExitEarly` while the drip ran and `ExitDone` after it, is the
L-CRON run below. The value a patient exit keeps from a burned forfeit is measured by the `T-DRIP` test (§8).

## 6. L-CRON: Cron only while work waits, around a full patient exit

Curator 2 retired `Y_A` (rule B3, "gone"). The RC subscribed to Cron in that reaction, answered the exit on
Cron ticks until it was done, then unsubscribed.

| Leg | Chain | Tx |
|---|---|---|
| `Y_A` retired | 1301 | [`0x6f03d328…b5`](https://sepolia.uniscan.xyz/tx/0x6f03d328c826a6d3c86421dfdebd0502e549c7ca1e88affbc2d264338204f3b5) |
| RC reaction, Cron subscribed | Lasna | [`0xf2874ed7…d968`](https://lasna.reactscan.net/tx/0xf2874ed77f0457a4925e2ac1a7725e25834aee8a0ec2807b16e02502e864d968) |
| `ExitEarly`: 3,517 drip blocks left | 1301 | [`0xf46f75e9…b155`](https://sepolia.uniscan.xyz/tx/0xf46f75e98c1a4bf1cc1a3e3ccd5036b6937cdece8b6e045541289f6959e1b155) |
| `ExitDone`: 60,878,428 mUSDC units + 20,199,999,917,942,709 mWETH wei to the owner | 1301 | [`0x163b0d59…6c39`](https://sepolia.uniscan.xyz/tx/0x163b0d5958cecf7de59f60c87938843dd9e0254e479db51da918cc1abdec6c39) |
| Cron unsubscribed, inside a Cron reaction | Lasna | [`0x6cd808c5…ae51`](https://lasna.reactscan.net/tx/0x6cd808c5be8686157cc26cfd0499ebe137d889ff4915d930be34b1b70bf2ae51) |

35 Cron ticks in one subscribe/unsubscribe interval, the unsubscribe right after `ExitDone`. Every other
subscription change in that window came from a non-Cron reaction (listed in the record's `otherChanges`).

## 7. L-SPOOF: a callback from someone else's reactive contract is rejected

We deployed a third-party reactive contract on Lasna ([`SpoofRC`](script/live/SpoofRC.sol),
`0xdDe7E4F51fA544dd3F23e60E8c258fA6868ebcfE`) that asks for one `rcConduct` to our 1301 Hub, naming curator 99.

| Leg | Chain | Tx |
|---|---|---|
| Trigger: a 1-unit mUSDC transfer | 1301 | [`0xf2ec6917…4177`](https://sepolia.uniscan.xyz/tx/0xf2ec6917530102faa68d76b83a123ca80462225322b1f95b899c8c9cc6054177) |
| SpoofRC reaction | Lasna | [`0xe67a52d1…4baf`](https://lasna.reactscan.net/tx/0xe67a52d1f9afdbf164f57964b7281d277b4f7009b285e847b29b60505ee64baf) |
| Delivery to the Hub: the Hub frame reverts `NotRc` | 1301 | [`0x2c4b1abc…c97f`](https://sepolia.uniscan.xyz/tx/0x2c4b1abca71cfe3a62b0c4b00ff6a1f4c821430eeec4e9583a029f4da3b2c97f) |

The network writes the requesting contract's address into the payload's first argument, so the Hub sees the
SpoofRC, not ours, and refuses. The proxy's tx succeeds (it catches the revert), the Hub emits nothing, and
curator 99's record stays zero. The proxy still billed the Hub 145,558,050,000 wei for the attempt (a known
limit: a third party can make a Hub pay for rejected callbacks).

```bash
cast sig "NotRc()"                                                                 # 0x1cac49a3
cast run 0x2c4b1abca71cfe3a62b0c4b00ff6a1f4c821430eeec4e9583a029f4da3b2c97f --rpc-url $U   # Hub frame: NotRc
cast call $HUB "conduct(uint32)(uint32,uint32,uint32,uint64)" 99 --rpc-url $U       # 0 0 0 0
```

## Also recorded

- **L-PLAN**: `EpochRecorded` [`0x88618e3d…b715`](https://sepolia.uniscan.xyz/tx/0x88618e3ddc155ff93f4ce227d4b9222f011378298cd0228ee349a17fe991b715)
  → Lasna [`0x4e1b3f06…f9e8`](https://lasna.reactscan.net/tx/0x4e1b3f06904e839052f5585a8403345fb3d8a3852579ea18fb9e98eb447cf9e8)
  → plan DONE [`0xc62444d0…d8d9`](https://sepolia.uniscan.xyz/tx/0xc62444d0970717404e6a47ef476c2bfc74265a48780c89f995ec1bbb9f45d8d9) (2 s).
  After the breach: `EpochRecorded` [`0x5904e526…331b`](https://sepolia.uniscan.xyz/tx/0x5904e526ff15cafecd70f6e53488c7c8a4479527cca16a846dd1153d834b331b)
  → Lasna [`0x104dbcf8…5a32`](https://lasna.reactscan.net/tx/0x104dbcf8124bc202dd37687d36da670071d299b825a2279755753197e17c5a32):
  the reaction ran and requested no plan callback (withheld while paused).
- **L-PAY**: a Hub with zero reserves and only a plain balance paid its first callback, debt 0:
  [1301](https://sepolia.uniscan.xyz/tx/0xcdbfad08d30d32627b2002accb22774e7a1cd6e13a429b16acce23efc9821088),
  [11155111](https://sepolia.etherscan.io/tx/0x6195de50baf14362b6280177f04bda142ad3de99a1416b71e60b078fdd3f1ca7).

## Trace any loop with the Reactive MCP

`script/rnk/rmcp.py` is a small standard-library client for Reactive's public MCP server. It follows an origin
tx through filter match, reaction and callback request:

```bash
python3 script/rnk/rmcp.py call trace_origin_event \
  '{"originChainId":1301,"txHash":"0xb6a8f0fde442f421ff07b08fe4dfa614ec4271f507843c54ecc90b5f7835f26d","rc":"0xFbcDba49a040Ca5965377F73bB327F2F2B7DC4c9"}'
python3 script/rnk/rmcp.py call get_rc_health '{"rc":"0xFbcDba49a040Ca5965377F73bB327F2F2B7DC4c9"}'
```

The trace stops at the callback request (`CALLBACK_NOT_POSTED`) because Lasna does not post delivery records;
check the delivery on the destination as above.

---

## 8. Reproduce the tests

```bash
git clone --recursive https://github.com/mishoko/touchstone-reagent && cd touchstone-reagent

forge test                                                    # 362 pass, 0 fail, 1 skipped
FOUNDRY_PROFILE=invariant forge test --match-path "test/invariant/*"    # 11 invariants with the deeper 256 x 128 profile

forge test --match-test "test_T_DRIP"            # patient vs immediate exit: the burned forfeit's value
forge test --match-test "test_A_"                # every attack cell and its positive control
forge test --match-contract "^Rc"               # the R layer: the RC fed exact LogRecords
forge test --match-test "test_R_DEPLOY"          # the deployed RC's runtime and the Hubs' needs, pinned

python3 script/mutate.py --audit                 # every // [MU-xx] tag in src/ has a mutant, and back
python3 script/mutate.py -j 1                    # the full curated campaign (148 mutants; long; one job only)
```

Tool selftests (offline, no keys):

```bash
python3 script/live/loops.py --selftest          # the evidence collector: 145 cells
python3 script/live/toolmut.py                   # mutants of the collector; each must be killed by a cell
python3 script/live/drive.py --selftest
python3 script/agent/agent.py --selftest         # the reference agent
python3 script/deploy/rc.py --selftest
```

Re-collect the live evidence from chain (needs `UNICHAIN_SEPOLIA_RPC_URL` and `ETH_SEPOLIA_RPC_URL`):

```bash
python3 script/live/loops.py lcon    # rebuilds the L-CON rows from the recorded origins
python3 script/live/loops.py ldyn
python3 script/live/loops.py lpay
```
