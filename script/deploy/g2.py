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

  python3 script/deploy/g2.py placement|gas|all
Needs DEPLOYER_PK and ETH_SEPOLIA_RPC_URL in the environment (never printed).
"""
import json, os, subprocess, sys, time, datetime as dt

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VAULT = '0xc599571D2643FeE6Fe92AFDb2b19cB7BcB00E6c5'
HOOK = '0x1eF5a7D438DAebcc0fc263c9C2873A76040AA0A0'
GRID, GRID_SEC, EPOCH, GRIDS = 20, 240, 120, 4
REFRESHED = '0x4a37b4c567e40e0368ff814076fe9ba967e81ccd884fe34c51083c5a35d877d2'
LATCHED = '0x829ba179a839c310d7073c7e340910e1a491fd6eb6c22836dc89137bf4d5a346'
WITNESS = '0x71721d2a29841087334cfe0e51c123d3b0b1bc3f6ef135c1b1f9c01e9e056ca2'
OBS = 'obs()((int24,int24,int24,uint40,bool,uint8,bool,bool,uint64,uint64,uint64,uint32,uint32,uint40,uint64,uint32,uint32))'


def rpc():
    return os.environ['ETH_SEPOLIA_RPC_URL']


def cast(*a):
    return subprocess.run(['cast', *a, '--rpc-url', rpc()], capture_output=True, text=True)


def send(to, sig, gas=None):
    args = ['send', to, sig, '--private-key', os.environ['DEPLOYER_PK'], '--json']
    if gas:
        args += ['--gas-limit', str(gas)]
    r = cast(*args)
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
    ok = (latched == 0 and anchors >= GRIDS and all(x['mode'] == 0 and x['emptyRange'] == 'false' and x['breachSeq'] == '0' for x in rows))
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
        r = subprocess.run(['cast', 'call', VAULT, 'poke()', '--from', '0x07F30b8e65938aBC2F728878e8AFc51FfEdB8213',
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
    save('gas_leg', {'pass': False, 'tries': tries, 'note': 'no poke passed below 3M gas'})
    return False


if __name__ == '__main__':
    what = sys.argv[1] if len(sys.argv) > 1 else 'all'
    res = True
    if what in ('placement', 'all'):
        res &= placement()
    if what in ('gas', 'all'):
        res &= gas()
    sys.exit(0 if res else 1)
