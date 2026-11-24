#!/usr/bin/env python3
"""The ReagentRC deploy on Lasna (spec §3.2, §9.2 R-DEPLOY; F-007), recorded by script into
`audits/deployments-5318007.json` (R-04).

  python3 script/deploy/rc.py check      the pre-flight: RC deployer nonce 0 and funded, the reserved address free,
                                         both live Hubs' RC() = the reserved address and their needs() equal to the
                                         RC's NEED constants and to audits/gas-need.json (D5-05, D6-03)
  python3 script/deploy/rc.py ext        deploy RcExt from the owner key (any nonce), recorded
  python3 script/deploy/rc.py rc         simulate the RC creation from the RC deployer at nonce 0 (eth_call --create:
                                         the exact runtime), send it with 1.5 x the estimate, assert status 1, the
                                         address, code = the simulated runtime, OWNER(), EXT(); recorded
  python3 script/deploy/rc.py register   addHub and addFactory on both chains, fund the RC's reserves; recorded

Keys: DEPLOYER_PK (owner), RC_DEPLOYER_PK (its ONLY transaction is the RC creation); never printed, never on argv
(cast reads ETH_PRIVATE_KEY from the environment).
"""
import json, os, re, subprocess, sys, hashlib, datetime as dt

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from prov import stamp  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LASNA = 'https://lasna-rpc.rnk.dev/'
RESERVED = '0xFbcDba49a040Ca5965377F73bB327F2F2B7DC4c9'
RC_DEPLOYER = '0x67941b1eA81913B45a6eE1d9B2e1aFfa98b2aea1'
SYSTEM = '0x8888888888888888888888888888888888888888'
OUT = os.path.join(ROOT, 'audits', 'deployments-5318007.json')
RC_FUND = '5ether'  # the provisional floor (spec §6: RC >= 5 lREACT)


def cast(*a, key=None, rpc=LASNA):
    env = dict(os.environ)
    if key:
        env['ETH_PRIVATE_KEY'] = os.environ[key]
    r = subprocess.run(['cast', *a, '--rpc-url', rpc], capture_output=True, text=True, env=env)
    if r.returncode != 0:
        raise SystemExit(f'rc: cast {a[0]} failed: {(r.stderr or r.stdout).strip()[-300:]}')
    return r.stdout.strip()


def load():
    return json.load(open(OUT)) if os.path.exists(OUT) else {'chainId': 5318007, 'generated_by': 'script/deploy/rc.py', 'steps': {}}


def save(doc):
    open(OUT, 'w').write(json.dumps(doc, indent=1) + '\n')


def art(name):
    a = json.load(open(os.path.join(ROOT, 'out', f'{name}.sol', f'{name}.json')))
    return a['bytecode']['object'], a['deployedBytecode']['object']


def owner():
    return subprocess.run(['cast', 'wallet', 'address'], capture_output=True, text=True,
                          env={**os.environ, 'ETH_PRIVATE_KEY': os.environ['DEPLOYER_PK']}).stdout.strip()


def rc_needs():
    """The RC's NEED constants for exit and plan (NEED_EXIT_<chain>, NEED_PLAN_<chain> in src/ReagentRC.sol or
    src/RcBase.sol)."""
    src = ''.join(open(os.path.join(ROOT, 'src', f)).read() for f in ('ReagentRC.sol', 'RcBase.sol')
                  if os.path.exists(os.path.join(ROOT, 'src', f)))
    out = {}
    for k in ('EXIT', 'PLAN'):
        for ch in ('1301', '11155111'):
            m = re.search(rf'NEED_{k}_{ch}\s*=\s*([\d_]+)', src)
            if not m:
                raise SystemExit(f'rc: no NEED_{k}_{ch} in the RC source')
            out[(k, ch)] = int(m[1].replace('_', ''))
    return out


def check():
    errs = []
    n = int(cast('nonce', RC_DEPLOYER))
    if n != 0:
        errs.append(f'RC deployer nonce {n} != 0: the reserved address is lost (F-007)')
    bal = int(cast('balance', RC_DEPLOYER))
    if bal < 10**18:
        errs.append(f'RC deployer balance {bal} < 1 lREACT')
    if cast('code', RESERVED) not in ('0x', ''):
        errs.append('code already at the reserved address')
    if cast('compute-address', RC_DEPLOYER, '--nonce', '0').split()[-1].lower() != RESERVED.lower():
        errs.append('CREATE(RC deployer, 0) is not the reserved address')
    needs = rc_needs()
    gn = json.load(open(os.path.join(ROOT, 'audits', 'gas-need.json')))
    for ch, rpc_env in (('1301', 'UNICHAIN_SEPOLIA_RPC_URL'), ('11155111', 'ETH_SEPOLIA_RPC_URL')):
        rpc = os.environ[rpc_env]
        if cast('chain-id', rpc=rpc) != ch:
            errs.append(f'{rpc_env} is not chain {ch}')
            continue
        d = json.load(open(os.path.join(ROOT, 'audits', f'deployments-{ch}.json')))
        hub = d['steps']['reagent']['reads']['CovenantFactory.HUB()']
        if cast('call', hub, 'RC()(address)', rpc=rpc).lower() != RESERVED.lower():
            errs.append(f'{ch}: Hub {hub} RC() != the reserved address')
        e, p = [int(x.split()[0]) for x in cast('call', hub, 'needs()(uint256,uint256)', rpc=rpc).splitlines()]
        if (e, p) != (needs[('EXIT', ch)], needs[('PLAN', ch)]):
            errs.append(f'{ch}: Hub needs() {(e, p)} != the RC NEEDs {(needs[("EXIT", ch)], needs[("PLAN", ch)])} (D6-03)')
        rows = gn['kinds']
        if (rows['rcExit']['chains'][ch]['need'], rows['rcAllocate']['chains'][ch]['need']) != (e, p):
            errs.append(f'{ch}: audits/gas-need.json NEEDs differ from the live Hub (D5-05)')
    for x in errs:
        print('rc check:', x)
    print('rc check', 'OK' if not errs else 'FAIL')
    return not errs


def deploy_ext():
    doc = load()
    if 'rcext' in doc['steps']:
        raise SystemExit('rc: RcExt already recorded')
    code, _ = art('RcExt')
    r = json.loads(cast('send', '--json', '--create', code, key='DEPLOYER_PK'))
    assert r['status'] in ('0x1', 1), r
    addr = r['contractAddress']
    doc['steps']['rcext'] = {**stamp(), 'recorded_at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'),
                             'from': owner(), 'tx': r['transactionHash'], 'address': addr,
                             'codeSha': hashlib.sha256(bytes.fromhex(cast('code', addr)[2:])).hexdigest()}
    save(doc)
    print('RcExt', addr)


def deploy_rc():
    if not check():
        raise SystemExit('rc: pre-flight failed; nothing sent')
    doc = load()
    ext = doc['steps']['rcext']['address']
    me = owner()
    code, _ = art('ReagentRC')
    initcode = code + cast('abi-encode', 'f(address,address)', me, ext)[2:]
    # the exact runtime the creation returns, simulated from the RC deployer at nonce 0
    runtime = cast('call', '--from', RC_DEPLOYER, '--create', initcode)
    est = int(cast('estimate', '--from', RC_DEPLOYER, '--create', initcode))
    r = json.loads(cast('send', '--json', '--gas-limit', str(est * 3 // 2), '--create', initcode, key='RC_DEPLOYER_PK'))
    ok = r['status'] in ('0x1', 1)
    rec = {**stamp(), 'recorded_at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'),
           'from': RC_DEPLOYER, 'tx': r['transactionHash'], 'status': 'ok' if ok else 'FAILED', 'estimate': est,
           'gasUsed': int(r['gasUsed'], 16), 'address': r.get('contractAddress')}
    doc['steps']['rc'] = rec
    save(doc)
    assert ok, 'the RC creation failed: nonce 0 is spent (F-007): owner action'
    assert r['contractAddress'].lower() == RESERVED.lower(), 'RC landed off the reserved address'
    live = cast('code', RESERVED)
    assert live.lower() == runtime.lower(), 'the live runtime differs from the simulated one'
    assert cast('call', RESERVED, 'OWNER()(address)').lower() == me.lower()
    assert cast('call', RESERVED, 'EXT()(address)').lower() == ext.lower()
    rec.update(runtimeSha=hashlib.sha256(bytes.fromhex(live[2:])).hexdigest(), owner=me, ext=ext, asserted=True)
    save(doc)
    print('ReagentRC', RESERVED, 'asserted')


def register():
    doc = load()
    txs = []
    for ch in ('1301', '11155111'):
        d = json.load(open(os.path.join(ROOT, 'audits', f'deployments-{ch}.json')))
        hub = d['steps']['reagent']['reads']['CovenantFactory.HUB()']
        ts = [t['address'] for t in d['steps']['touchstone']['txs'] if t.get('label') == 'TouchstoneFactory'
              or t.get('contract') == 'TouchstoneFactory']
        if len(ts) != 1:
            raise SystemExit(f'rc: no single TouchstoneFactory recorded for {ch}')
        for sig, args in (('addHub(uint256,address)', [ch, hub]), ('addFactory(uint256,address)', [ch, ts[0]])):
            r = json.loads(cast('send', '--json', RESERVED, sig, *args, key='DEPLOYER_PK'))
            assert r['status'] in ('0x1', 1), r
            txs.append({'call': sig, 'args': args, 'tx': r['transactionHash']})
    r = json.loads(cast('send', '--json', '--value', RC_FUND, SYSTEM, 'depositTo(address)', RESERVED, key='DEPLOYER_PK'))
    assert r['status'] in ('0x1', 1), r
    txs.append({'call': 'depositTo(address)', 'value': RC_FUND, 'tx': r['transactionHash']})
    doc['steps']['register'] = {**stamp(), 'recorded_at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'), 'txs': txs}
    save(doc)
    print('registered', len(txs), 'txs')


if __name__ == '__main__':
    what = sys.argv[1] if len(sys.argv) > 1 else 'check'
    {'check': lambda: sys.exit(0 if check() else 1), 'ext': deploy_ext, 'rc': deploy_rc, 'register': register}[what]()
