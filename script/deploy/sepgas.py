#!/usr/bin/env python3
"""The 11155111 gas twins (spec §5.6 method (a), §9.1 T-SEPGAS-*, §9.3 A-SEPGAS63), recorded by script into
`audits/gas-need.json` under "sepolia_twins" (R-04).

For each callback kind:
  1. `forge test` (SEPGAS_DUMP=1, test/SepGasTwin.t.sol) builds the T-GAS worst-case state at chain id 11155111 with
     the LIVE deterministic addresses (the Hub is 0x5887… with the deployed runtime) on a timeline that ends just
     above Sepolia's head, and dumps every account the callback touches (code, balance, the pre-call value of each
     accessed slot);
  2. `eth_simulateV1` on Sepolia replays the callback with those accounts as state overrides (Glamsterdam pricing),
     from the proxy address (its code overridden by a forwarder that calls the Hub with exactly the entry gas a
     delivery at a chosen gasLimit brings: 63/64 · (gasLimit − F)), the Hub's own code left as deployed (checked
     equal to the dumped code);
  3. runs: at the §5.6 formula gasLimit (the success event), 1% under (DEFERRED for exit and plan, else a failure),
     the positive control (the formula at the forge NEED: a failure; for exit and plan through the forge-NEED Hub
     runtime: RELAY_FAILED or no success), and for A-SEPGAS63 the exit at the pre-check threshold − 1 (DEFERRED).

  python3 script/deploy/sepgas.py [kind ...]      (default: all five)
Needs ETH_SEPOLIA_RPC_URL (an endpoint with eth_simulateV1; never printed).
"""
import json, os, subprocess, sys, hashlib, datetime as dt

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gasneed import code_needs, gas_limit, F, RESERVE  # noqa: E402
from prov import stamp  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
KINDS = ['rcConduct', 'rcVault', 'rcBudget', 'rcExit', 'rcAllocate']
TEST = {'rcConduct': 'conduct', 'rcVault': 'vault', 'rcBudget': 'budget', 'rcExit': 'exit', 'rcAllocate': 'plan'}
VM = '0x7109709ecfa91a80626ff3989d68f67f5b1dd12d'
FROM = '0x07F30b8e65938aBC2F728878e8AFc51FfEdB8213'
BT = 12  # the TEST tier's block time in the local timeline
MARGIN = 60  # the simulated block lands this many blocks above head
T_APPLIED = '0xce93009ccd5ff6e5058f9aacacf4db6e4bdf49a9fbab795441ddeebee88b1615'
T_BUDGET = '0xf8a6aac26004de219a651c93a920566d656f9282511a6369c7298dc84c2d8823'
T_NOTE = '0x9f0625eae4d628e3bcc8083dac0036f15eb2c98996c115367665517f717810a7'
T_STALE = '0xefb60aea3ab96907066bbced4f58785ff7b8c28be82924866fc6839082f32530'
T_BOUND = '0x4a93a23c2057d5ed35e9b920e7650109f5cfb0417a8dfea5c7a960a04cc02af4'
OUTCOME = {1: 'DONE', 2: 'EARLY/SKIPPED', 3: 'STALE', 4: 'FAILED', 5: 'DEFERRED', 6: 'RELAY_FAILED'}


def rpc(method, params):
    """JSON-RPC through `curl --http1.1` (TRAPS s2: HTTP/2 to the keyed endpoint hangs; urllib's TLS fails there)."""
    body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params})
    r = subprocess.run(['curl', '-s', '--http1.1', '-m', '180', '-X', 'POST', '-H', 'content-type: application/json',
                        '--data-binary', '@-', os.environ['ETH_SEPOLIA_RPC_URL']], input=body, capture_output=True, text=True)
    try:
        j = json.loads(r.stdout)
    except ValueError:
        raise SystemExit(f'sepgas: {method}: no JSON ({r.stdout[:200]!r} {r.stderr[:200]!r})')
    if 'error' in j:
        raise SystemExit(f'sepgas: {method}: {j["error"]}')
    return j['result']


def head():
    b = rpc('eth_getBlockByNumber', ['latest', False])
    return int(b['number'], 16), int(b['timestamp'], 16)


def dump(kind, start_block=None, start_time=None):
    env = {**os.environ, 'SEPGAS_DUMP': '1'}
    if start_block is not None:
        env.update(TS_START_BLOCK=str(start_block), TS_START_TIME=str(start_time))
    r = subprocess.run(['forge', 'test', '--match-contract', 'SepGasTwinDump', '--match-test', f'SEPGAS_DUMP__{TEST[kind]}'],
                       cwd=ROOT, capture_output=True, text=True, env=env)
    if r.returncode != 0 or '[PASS]' not in r.stdout:
        raise SystemExit(f'sepgas: dump {kind} failed:\n{r.stdout[-1500:]}{r.stderr[-800:]}')
    return json.load(open(os.path.join(ROOT, 'output', f'sepgas-{kind}.json')))


def forwarder():
    a = json.load(open(os.path.join(ROOT, 'out', 'SepGasTwin.t.sol', 'GasForwarder.json')))
    return a['deployedBytecode']['object']


def enc(target, g, payload):
    p = bytes.fromhex(payload[2:])
    w = lambda x: x.to_bytes(32, 'big')
    pad = p + b'\0' * ((32 - len(p) % 32) % 32)
    return '0x' + (w(int(target, 16)) + w(g) + w(0x60) + w(len(p)) + pad).hex()


def overrides(d, hub_code=None):
    o = {}
    for a, acc in d['accounts'].items():
        al = a.lower()
        if al in (VM, d['proxy'].lower()):
            continue
        e = {'balance': hex(int(acc['balance'])), 'state': {s: v for s, v in zip(acc['slots'], acc['values'])}}
        if al == d['hub'].lower():
            if hub_code:
                e['code'] = hub_code  # the positive control's runtime; otherwise the deployed code stays
        else:
            e['code'] = acc['code']
        o[al] = e
    o[d['proxy'].lower()] = {'code': forwarder()}
    return o


def simulate(d, g, hub_code=None):
    call = {'from': FROM, 'to': d['proxy'], 'data': enc(d['hub'], g, d['data']), 'gas': hex(g + 600_000)}
    blk = {'number': hex(d['blockNumber']), 'time': hex(d['timestamp']), 'gasLimit': hex(200_000_000)}
    res = rpc('eth_simulateV1', [{'blockStateCalls': [{'blockOverrides': blk, 'stateOverrides': overrides(d, hub_code),
                                                       'calls': [call]}], 'validation': False}, 'latest'])
    c = res[-1]['calls'][0]
    return classify(d, c.get('logs', [])), int(c['gasUsed'], 16)


def classify(d, logs):
    hub = d['hub'].lower()
    mine = [l for l in logs if l['address'].lower() == hub]
    t0 = [l['topics'][0] for l in mine]
    k = d['kind']
    if k == 'rcConduct':
        return 'APPLIED' if T_APPLIED in t0 else 'FAILED'
    if k == 'rcVault':
        return 'BOUND' if T_BOUND in t0 else 'FAILED'
    if k == 'rcBudget':
        notes = [l for l in mine if l['topics'][0] == T_NOTE and int(l['topics'][3], 16) == 1]
        if T_BUDGET in t0 and notes:
            return 'ANSWERED'
        return 'STALE6' if T_BUDGET in t0 and T_STALE in t0 else 'FAILED'
    kind_note = 2 if k == 'rcExit' else 3
    notes = [l for l in mine if l['topics'][0] == T_NOTE and int(l['topics'][3], 16) == kind_note]
    if not notes:
        return 'NO_NOTE'
    data = bytes.fromhex(notes[-1]['data'][2:])
    inner = data[64:]  # abi bytes: offset, length, then the note payload
    word = lambda i: int.from_bytes(inner[32 * i:32 * i + 32], 'big')
    o = word(1) if k == 'rcExit' else word(2)
    return OUTCOME.get(o, f'OUTCOME_{o}')


def search(d, ok, hub_code=None, lo=30_000, hi=8_000_000):
    """The minimum entry gas (within 1,000) at which the callback succeeds, by eth_simulateV1 (method (a))."""
    out, _ = simulate(d, hi, hub_code)
    if not ok(out):
        raise SystemExit(f'sepgas: {d["kind"]} fails even at {hi} ({out})')
    while hi - lo > 1_000:
        mid = (lo + hi) // 2
        if ok(simulate(d, mid, hub_code)[0]):
            hi = mid
        else:
            lo = mid
    return hi


def run_kind(kind, needs, ref):
    need = needs[kind]['11155111']
    forge_need = needs[kind]['1301']
    L = gas_limit('11155111', need)
    entry = (L - F['11155111']) * 63 // 64
    h, ht = head()
    delta_b = ref['blockNumber'] - 100_000
    delta_t = ref['timestamp'] - 100_000 * BT
    d = dump(kind, h + MARGIN - delta_b, ht + MARGIN * BT - delta_t)
    live = rpc('eth_getCode', [d['hub'], 'latest'])
    dumped = d['accounts'].get(d['hub']) or d['accounts'].get(d['hub'].lower())
    if live.lower() != dumped['code'].lower():
        raise SystemExit('sepgas: the dumped Hub code differs from the deployed runtime')
    want = {'rcConduct': 'APPLIED', 'rcVault': 'BOUND', 'rcBudget': 'ANSWERED', 'rcExit': 'DONE', 'rcAllocate': 'DONE'}[kind]
    row = {'need': need, 'gasLimit': L, 'entry': entry, 'block': d['blockNumber'],
           'hubCodeSha': hashlib.sha256(bytes.fromhex(live[2:])).hexdigest()[:16]}
    out, used = simulate(d, entry)
    row['formula'] = {'outcome': out, 'gasUsed': used, 'pass': out == want}
    # method (a): the minimum on Sepolia pricing; NEED >= 1.3 x it; 1,000 under it fails
    if kind in ('rcExit', 'rcAllocate'):
        np_ = d['npCode']  # the Hub without its pre-check: everything above RESERVE reaches the Covenant
        m = search(d, lambda o: o == want, np_)
        # the Hub forwards gasleft - RESERVE after a prologue >= 0, so the Covenant's need is at most m + step - RESERVE
        # (s3 rc r5 D5-04: the earlier (m - RESERVE)*63/64 was a LOWER bound); both rules: NEED >= 1.3 x that bound,
        # and the pre-check threshold NEED*64/63 + RESERVE >= 1.3 m
        cov = m + 1_000 - RESERVE
        thr = need * 64 // 63 + RESERVE
        out, _ = simulate(d, m - 1_000, np_)
        row['measured'] = {'hubEntryMin': m, 'covenantNeedUpper': cov, 'threshold': thr, 'under1000': out,
                           'pass': need * 10 >= cov * 13 and thr * 10 >= m * 13 and out != want}
        g = (need * 64 // 63 + RESERVE) * 99 // 100
        out, used = simulate(d, g)
        row['minus1'] = {'entry': g, 'outcome': out, 'gasUsed': used, 'pass': out == 'DEFERRED'}
        gpc = (gas_limit('11155111', forge_need) - F['11155111']) * 63 // 64
        out, used = simulate(d, gpc, d['pcCode'])
        row['pc'] = {'what': 'the forge-NEED Hub runtime at the forge-NEED formula limit', 'entry': gpc, 'outcome': out,
                     'gasUsed': used, 'pass': out not in (want, 'DEFERRED')}
        if kind == 'rcExit':
            g = need * 64 // 63 + RESERVE - 1
            out, used = simulate(d, g)
            row['a_sepgas63'] = {'entry': g, 'outcome': out, 'pass': out == 'DEFERRED'}
    else:
        m = search(d, lambda o: o == want)
        out, _ = simulate(d, m - 1_000)
        row['measured'] = {'entryMin': m, 'under1000': out, 'pass': need * 10 >= m * 13 and out != want}
        gpc = (gas_limit('11155111', forge_need) - F['11155111']) * 63 // 64
        out, used = simulate(d, gpc)
        # informational only: the PC for conduct, vault and budget is 'measured.under1000' (s3 erratum, spec §5.6;
        # the forge NEED of rcBudget already exceeds the Sepolia minimum, so this leg cannot fail there)
        row['pc_forge_need'] = {'what': 'the formula at the forge NEED (informational)', 'entry': gpc, 'outcome': out, 'gasUsed': used}
    row['pass'] = verdict(row)
    return row


def verdict(row):
    """A kind passes iff every specified leg passed (legs with a 'pass' key; informational legs have none)."""
    return all(v['pass'] for v in row.values() if isinstance(v, dict) and 'pass' in v)


def repass():
    """Recomputes the recorded verdicts from the recorded outcomes (no new run): the s3 erratum moved the PC of
    conduct, vault and budget to the 1,000-under-the-minimum run."""
    p = os.path.join(ROOT, 'audits', 'gas-need.json')
    doc = json.load(open(p))
    tw = doc['sepolia_twins']
    for k in ('rcConduct', 'rcVault', 'rcBudget'):
        if k in tw and 'pc' in tw[k]:
            pc = tw[k].pop('pc')
            pc.pop('pass', None)
            pc['what'] = pc['what'] + ' (informational)'
            tw[k]['pc_forge_need'] = pc
    for k in KINDS:
        if k in tw:
            tw[k]['pass'] = verdict(tw[k])
    tw['repassed_by'] = 'script/deploy/sepgas.py repass'
    json.dump(doc, open(p, 'w'), indent=1)
    return all(tw[k]['pass'] for k in KINDS if k in tw)


def main(argv):
    if argv and argv[0] == 'repass':
        ok = repass()
        print('repass', 'PASS' if ok else 'FAIL')
        return 0 if ok else 1
    kinds = [k for k in argv if k in KINDS] or KINDS
    cid = rpc('eth_chainId', [])
    if int(cid, 16) != 11155111:
        raise SystemExit(f'sepgas: ETH_SEPOLIA_RPC_URL is chain {cid}')
    needs = code_needs()
    p = os.path.join(ROOT, 'audits', 'gas-need.json')
    doc = json.load(open(p))
    tw = doc.setdefault('sepolia_twins', {})
    tw.update({'generated_by': 'script/deploy/sepgas.py', 'method': (__doc__ or '').split('\n\n')[1].strip(), **stamp(),
               'generated_at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')})
    ok = True
    for k in kinds:
        ref = dump(k)  # the default timeline: its length fixes the aligned start
        row = run_kind(k, needs, ref)
        tw[k] = row
        ok &= row['pass']
        print(k, 'PASS' if row['pass'] else 'FAIL', json.dumps({x: v for x, v in row.items() if x != 'hubCodeSha'}), flush=True)
        json.dump(doc, open(p, 'w'), indent=1)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
