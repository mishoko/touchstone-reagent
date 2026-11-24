#!/usr/bin/env python3
"""Gate G2 on Ethereum Sepolia (spec §8, OQ-14, D1-09), recorded by script into `audits/g2.json` (R-04).

  placement   the TEST vault's placement holds across >= GRIDS grids at 13.2 s blocks against a 12 s grid: an open
              `refreshRef` about every half grid; after each, the hook's `obs()` (outBlocks, refFresh, breachSeq,
              pendingBreaches, emptyRange) and the vault's mode (slot 19) are read. PASS iff no breach latched, mode
              NORMAL, the range never empty, and >= GRIDS `RefRefreshed` anchors were written.
  gas         the witness roll under Glamsterdam pricing: once the vault's epoch is stale (an epoch boundary passed
              with no entry), `poke` is sent with gas limits rising from below the 400k guard; the first that passes
              the guard is the starve case. PASS iff that poke's `WitnessRolled` has lw > 0 (a failed roll, lw = 0,
              would reopen Touchstone's F-048(b) class on this chain: disclosed, PA-13 to the owner).

  control     the next epoch roll with ample gas (6M): lw > 0 shows the gas leg's lw = 0 was a gas failure.
  verdict     recomputes `verdict` from the recorded legs (no transaction).

  python3 script/deploy/g2.py placement|gas|control|verdict|all
Needs DEPLOYER_PK and ETH_SEPOLIA_RPC_URL in the environment (never printed, never on argv: cast reads the key from
ETH_PRIVATE_KEY). The vault and hook are read from the `Deployed` event of the `deployAndPlace` tx recorded in
`audits/deployments-11155111.json` (tools review m-5), and the RPC's chain id is checked first.
"""
import json, os, subprocess, sys, time, datetime as dt

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CHAIN = 11155111
DEPLOYED = '0xd3718c34c2f5d26df60faa54c8035a99d8fc11a4d3437ec8c46bfcf64aaa2ee2'
VAULT = HOOK = None
GRID, GRID_SEC, EPOCH, GRIDS = 20, 240, 120, 4
REFRESHED = '0x4a37b4c567e40e0368ff814076fe9ba967e81ccd884fe34c51083c5a35d877d2'
LATCHED = '0x829ba179a839c310d7073c7e340910e1a491fd6eb6c22836dc89137bf4d5a346'
WITNESS = '0x71721d2a29841087334cfe0e51c123d3b0b1bc3f6ef135c1b1f9c01e9e056ca2'
OBS = 'obs()((int24,int24,int24,uint40,bool,uint8,bool,bool,uint64,uint64,uint64,uint32,uint32,uint40,uint64,uint32,uint32))'


def rpc():
    return os.environ['ETH_SEPOLIA_RPC_URL']


def cast(*a):
    return subprocess.run(['cast', *a, '--rpc-url', rpc()], capture_output=True, text=True)


def init():
    """Chain-id check (TRAPS) and the G2 vault/hook from the recorded deployAndPlace receipt."""
    global VAULT, HOOK
    cid = cast('chain-id').stdout.strip()
    if cid != str(CHAIN):
        raise SystemExit(f'g2: ETH_SEPOLIA_RPC_URL is chain {cid!r}, not {CHAIN}')
    d = json.load(open(os.path.join(ROOT, 'audits', 'deployments-11155111.json')))
    tx = [t for t in d['steps']['touchstone']['txs'] if t.get('label') == 'deployAndPlace' and t.get('status') == 'ok']
    if len(tx) != 1:
        raise SystemExit('g2: no single recorded deployAndPlace tx')
    rc = json.loads(cast('receipt', tx[0]['tx'], '--json').stdout)
    logs = [l for l in rc['logs'] if l['topics'][0] == DEPLOYED]
    if len(logs) != 1:
        raise SystemExit('g2: the deployAndPlace receipt has no single Deployed event')
    w = logs[0]['data'][2:]
    VAULT, HOOK = '0x' + w[24:64], '0x' + w[64 * 2 + 24:64 * 3]


def me():
    return subprocess.run(['cast', 'wallet', 'address'], capture_output=True, text=True,
                          env={**os.environ, 'ETH_PRIVATE_KEY': os.environ['DEPLOYER_PK']}).stdout.strip()


def send(to, sig, gas=None):
    args = ['send', to, sig, '--json']
    if gas:
        args += ['--gas-limit', str(gas)]
    r = subprocess.run(['cast', *args, '--rpc-url', rpc()], capture_output=True, text=True,
                       env={**os.environ, 'ETH_PRIVATE_KEY': os.environ['DEPLOYER_PK']})
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {'error': (r.stderr or r.stdout).strip().splitlines()[-1][:200] if (r.stderr or r.stdout) else 'no output'}


def obs():
    out = cast('call', HOOK, OBS).stdout.strip()
    f = [x.strip() for x in out.strip('()').split(',')]
    keys = ['med9', 'tickSpot', 'refTick', 'refCachedAt', 'refFresh', 'resetStreak', 'gapSinceVerify', 'emptyRange',
            'tauV', 'tauB', 'outBlocks', 'breachSeq', 'pendingBreaches', 'lastPendingBlock', 'tauVAtLastPending',
            'gridIndex', 'epoch']
    return {k: f[i].split(' ')[0] for i, k in enumerate(keys)}


def slot(n):
    return int(cast('call', VAULT, 'extsload(bytes32)(bytes32)', '0x%064x' % n).stdout.strip(), 16)


def block():
    return int(cast('block-number').stdout.strip())


def save(key, val):
    p = os.path.join(ROOT, 'audits', 'g2.json')
    doc = json.load(open(p)) if os.path.exists(p) else {'generated_by': 'script/deploy/g2.py', 'chainId': 11155111,
                                                        'vault': VAULT, 'hook': HOOK}
    doc[key] = val
    open(p, 'w').write(json.dumps(doc, indent=1) + '\n')


def placement_pass(rows, anchors, latched):
    # every row NORMAL, never an empty range, no latch and no pending breach (tools review m-5)
    return (latched == 0 and anchors >= GRIDS and bool(rows) and all(
        x['mode'] == 0 and x['emptyRange'] == 'false' and x['breachSeq'] == '0' and x['pendingBreaches'] == '0'
        for x in rows))


def placement():
    rows, anchors, latched = [], 0, 0
    t_end = time.time() + GRIDS * GRID_SEC + 60
    while time.time() < t_end:
        r = send(HOOK, 'refreshRef()')
        o = obs()
        mode = (slot(19) >> 32) & 0xff
        logs = r.get('logs', []) if isinstance(r, dict) else []
        a = sum(1 for l in logs if l['topics'][0] == REFRESHED)
        b = sum(1 for l in logs if l['topics'][0] == LATCHED)
        anchors += a
        latched += b
        rows.append({'utc': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'), 'tx': r.get('transactionHash'),
                     'block': int(r['blockNumber'], 16) if r.get('blockNumber') else None, 'status': r.get('status'),
                     'anchor': a, 'outBlocks': o['outBlocks'], 'refFresh': o['refFresh'], 'emptyRange': o['emptyRange'],
                     'breachSeq': o['breachSeq'], 'pendingBreaches': o['pendingBreaches'], 'gridIndex': o['gridIndex'],
                     'mode': mode, 'error': r.get('error')})
        print(rows[-1], flush=True)
        time.sleep(GRID_SEC / 2)
    ok = placement_pass(rows, anchors, latched)
    save('placement', {'grids': GRIDS, 'anchors': anchors, 'latched': latched, 'pass': ok, 'rows': rows})
    print('placement', 'PASS' if ok else 'FAIL', 'anchors', anchors, 'latched', latched)
    return ok


def gas():
    # wait for an epoch boundary with no vault entry since: the next poke rolls epoch and witness
    ve = (slot(8) >> 40) & 0xffffffff
    while block() // EPOCH <= ve:
        print('waiting for the epoch boundary: block', block(), 'vault epoch', ve, flush=True)
        time.sleep(60)
    # the minimum gas limit at which `poke` succeeds, by eth_call at the head (same pricing and state)
    def ok_at(g):
        r = subprocess.run(['cast', 'call', VAULT, 'poke()', '--from', me(),
                            '--gas-limit', str(g), '--rpc-url', rpc()], capture_output=True, text=True)
        return r.returncode == 0
    lo, hi = 100_000, 6_000_000
    if not ok_at(hi):
        save('gas_leg', {'pass': False, 'note': 'poke fails even at 6M by eth_call'})
        return False
    while hi - lo > 2_000:
        mid = (lo + hi) // 2
        if ok_at(mid):
            hi = mid
        else:
            lo = mid
    tries = [{'eth_call_min_gasLimit': hi}]
    for lim in (hi, hi + 4_000, hi + 20_000):
        r = send(VAULT, 'poke()', gas=lim)
        st = r.get('status')
        tries.append({'gasLimit': lim, 'status': st, 'tx': r.get('transactionHash'),
                      'gasUsed': int(r['gasUsed'], 16) if r.get('gasUsed') else None, 'error': r.get('error')})
        print(tries[-1], flush=True)
        if st == '0x1':
            lw = None
            for l in r.get('logs', []):
                if l['topics'][0] == WITNESS:
                    d = l['data'][2:]
                    lw = int(d[64 * 3:64 * 4], 16)
            ok = lw is not None and lw > 0
            save('gas_leg', {'pass': ok, 'witness_lw': lw, 'tries': tries,
                             'note': 'the first poke at the minimum passing gas limit is the starve case; lw = 0 would be a recorded failed roll'})
            print('gas leg', 'PASS' if ok else 'FAIL', 'lw', lw)
            return ok
    save('gas_leg', {'pass': False, 'tries': tries, 'note': 'no poke passed at the three limits tried'})
    return False


def _witness_lw(r):
    for l in r.get('logs', []):
        if l['topics'][0] == WITNESS:
            return int(l['data'][2:][64 * 3:64 * 4], 16)
    return None


def control():
    """The next epoch's roll with ample gas: lw > 0 means the gas leg's lw = 0 was a gas failure, not a funding one."""
    ve = (slot(8) >> 40) & 0xffffffff
    while block() // EPOCH <= ve:
        print('waiting for the epoch boundary: block', block(), 'vault epoch', ve, flush=True)
        time.sleep(60)
    r = send(VAULT, 'poke()', gas=6_000_000)
    lw = _witness_lw(r)
    save('gas_leg_control', {'gasLimit': 6_000_000, 'tx': r.get('transactionHash'), 'status': r.get('status'),
                             'gasUsed': int(r['gasUsed'], 16) if r.get('gasUsed') else None, 'witness_lw': lw,
                             'note': 'the next epoch roll with ample gas: lw > 0 means the starve-case lw = 0 was a gas failure'})
    return lw is not None and lw > 0


def verdict_of(doc):
    """The G2 verdict, computed from the recorded legs only (tools review m-5)."""
    pl = doc.get('placement') or {}
    p_ok = placement_pass(pl.get('rows') or [], pl.get('anchors', 0), pl.get('latched', 1))
    g = doc.get('gas_leg') or {}
    c = doc.get('gas_leg_control') or {}
    c_ok = c.get('status') == '0x1' and (c.get('witness_lw') or 0) > 0
    if g.get('pass'):
        gas_v = 'PASS'
    elif g.get('witness_lw') == 0 and c_ok:
        gas_v = 'FAIL (confirmed by control)'
    else:
        gas_v = 'FAIL (unconfirmed: no passing control)'
    return {'placement': 'PASS' if p_ok else 'FAIL', 'gas_leg': gas_v, 'computed_by': 'script/deploy/g2.py verdict'}


def verdict():
    p = os.path.join(ROOT, 'audits', 'g2.json')
    doc = json.load(open(p))
    v = verdict_of(doc)
    save('verdict', v)
    print('verdict', v)
    return v['placement'] == 'PASS' and v['gas_leg'] == 'PASS'


def selftest():
    row = {'mode': 0, 'emptyRange': 'false', 'breachSeq': '0', 'pendingBreaches': '0'}
    ok = placement_pass([row] * 3, GRIDS, 0) and not placement_pass([row, dict(row, pendingBreaches='1')], GRIDS, 0) \
        and not placement_pass([], GRIDS, 0) and not placement_pass([row], GRIDS - 1, 0)
    good = {'placement': {'rows': [row], 'anchors': GRIDS, 'latched': 0}}
    ok &= verdict_of(dict(good, gas_leg={'pass': True}))['gas_leg'] == 'PASS'
    ok &= verdict_of(dict(good, gas_leg={'pass': False, 'witness_lw': 0},
                          gas_leg_control={'status': '0x1', 'witness_lw': 1000}))['gas_leg'] == 'FAIL (confirmed by control)'
    ok &= verdict_of(dict(good, gas_leg={'pass': False, 'witness_lw': 0},
                          gas_leg_control={'status': '0x1', 'witness_lw': 0}))['gas_leg'].startswith('FAIL (unconfirmed')
    print('g2 selftest', 'OK' if ok else 'FAIL')
    return ok


if __name__ == '__main__':
    what = sys.argv[1] if len(sys.argv) > 1 else 'all'
    if what == 'selftest':
        sys.exit(0 if selftest() else 1)
    init()
    res = True
    if what in ('placement', 'all'):
        res &= placement()
    if what in ('gas', 'all'):
        res &= gas()
    if what in ('control', 'all'):
        res &= control()
    if what in ('verdict', 'all'):
        res &= verdict()
    sys.exit(0 if res else 1)
