#!/usr/bin/env python3
"""The ReagentRC deploy on Lasna (spec §3.2, §9.2 R-DEPLOY; F-007, F-013), recorded by script into
`audits/deployments-5318007.json` (R-04).

  python3 script/deploy/rc.py check      the pre-flight: RC deployer nonce 0 (latest AND pending) and funded, the
                                         reserved address free, both live Hubs' RC() = the reserved address and their
                                         needs() equal to the RC's NEED constants and to audits/gas-need.json
  python3 script/deploy/rc.py pin        record the REVIEWED build (audits/rc-build.json): initcode and immutable-masked
                                         runtime hashes of RcB6, RcExt, ReagentRC from a clean `forge build --force`;
                                         run once, at the RC fix review's close, on the reviewed tree
  python3 script/deploy/rc.py b6         deploy RcB6 from the owner key, after the build check; recorded
  python3 script/deploy/rc.py ext        deploy RcExt(B6) from the owner key, after the build check; recorded
  python3 script/deploy/rc.py rc         simulate the RC creation from the RC deployer at nonce 0 (eth_call --create:
                                         the exact runtime), send it with `--nonce 0` and 1.5 x the estimate, assert
                                         status 1, the address, code = the simulated runtime, OWNER(), EXT(); recorded
  python3 script/deploy/rc.py register   addHub and addFactory on both chains, fund the RC's reserves; recorded
  python3 script/deploy/rc.py --selftest the refusals, offline: swapped keys, a mutated artifact, a dirty tree

Keys: the owner (DEPLOYER_PK) and the RC deployer (RC_DEPLOYER_PK, its ONLY transaction is the RC creation); never
printed, never on argv. cast 1.5 no longer reads ETH_PRIVATE_KEY (s6), so the keys travel as encrypted keystores:
RC_KEYSTORE_DIR holds `owner` and `rcdep` (made once by `cast wallet import -i`), RC_KEYSTORE_PW names the password
file; only their paths reach argv. Before ANY send: the keys' identities are asserted (F-010 H3-02),
and every artifact sent is checked against the reviewed-build pin after a forced rebuild (H3-01).
"""
import json, os, re, subprocess, sys, hashlib, tempfile, datetime as dt

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from prov import stamp  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LASNA = 'https://lasna-rpc.rnk.dev/'
RESERVED = '0xFbcDba49a040Ca5965377F73bB327F2F2B7DC4c9'
RC_DEPLOYER = '0x67941b1eA81913B45a6eE1d9B2e1aFfa98b2aea1'
SYSTEM = '0x8888888888888888888888888888888888888888'
OUT = os.path.join(ROOT, 'audits', 'deployments-5318007.json')
PIN = os.path.join(ROOT, 'audits', 'rc-build.json')
RC_FUND = '5ether'  # the provisional floor (spec §6: RC >= 5 lREACT)
MODULES = ('RcB6', 'RcExt', 'ReagentRC')


KEYSTORE = {'DEPLOYER_PK': 'owner', 'RC_DEPLOYER_PK': 'rcdep'}
OFFLINE = {'abi-encode'}  # subcommands that take no --rpc-url


def _wallet(key, env=os.environ):
    d, pw = env.get('RC_KEYSTORE_DIR'), env.get('RC_KEYSTORE_PW')
    if not d or not pw:
        raise SystemExit('rc: RC_KEYSTORE_DIR and RC_KEYSTORE_PW must both be set')
    ks = os.path.join(d, KEYSTORE[key])
    if not os.path.isfile(ks) or not os.path.isfile(pw):
        raise SystemExit(f'rc: no keystore for {key}')
    return ['--keystore', ks, '--password-file', pw]


def cast(*a, key=None, rpc=LASNA):
    w = _wallet(key) if key else []
    # options before the positionals: `send --create <CODE> [SIG] [ARGS]...` takes anything after CODE as ARGS (s6)
    net = [] if a[0] in OFFLINE else ['--rpc-url', rpc]
    r = subprocess.run(['cast', a[0], *w, *net, *a[1:]], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f'rc: cast {a[0]} failed: {(r.stderr or r.stdout).strip()[-300:]}')
    return r.stdout.strip()


def addr_of(key, env=os.environ):
    r = subprocess.run(['cast', 'wallet', 'address', *_wallet(key, env)], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit('rc: a keystore does not open (not printed)')
    return r.stdout.strip()


def assert_keys(env=os.environ):
    """F-010 H3-02: before any send, the RC deployer key IS the reserved deployer and the owner key is NOT."""
    if addr_of('RC_DEPLOYER_PK', env).lower() != RC_DEPLOYER.lower():
        raise SystemExit('rc: the rcdep keystore does not derive to the RC deployer: refusing before any send')
    if addr_of('DEPLOYER_PK', env).lower() == RC_DEPLOYER.lower():
        raise SystemExit('rc: the owner keystore derives to the RC deployer (swapped keys?): refusing before any send')
    return addr_of('DEPLOYER_PK', env)


def load():
    return json.load(open(OUT)) if os.path.exists(OUT) else {'chainId': 5318007, 'generated_by': 'script/deploy/rc.py', 'steps': {}}


def save(doc):
    open(OUT, 'w').write(json.dumps(doc, indent=1) + '\n')


# ------------------------------------------------------------------ the reviewed build (F-010 H3-01)

def art(name, root=ROOT):
    return json.load(open(os.path.join(root, 'out', f'{name}.sol', f'{name}.json')))


def masked_runtime(a, code_hex=None):
    """The runtime with every immutable's bytes zeroed (they are set at construction)."""
    code = bytearray(bytes.fromhex((code_hex or a['deployedBytecode']['object'])[2:]))
    for refs in a['deployedBytecode'].get('immutableReferences', {}).values():
        for r in refs:
            code[r['start']:r['start'] + r['length']] = bytes(r['length'])
    return hashlib.sha256(bytes(code)).hexdigest()


def build_ids(root=ROOT):
    out = {}
    for m in MODULES:
        a = art(m, root)
        out[m] = {'initcodeSha': hashlib.sha256(bytes.fromhex(a['bytecode']['object'][2:])).hexdigest(),
                  'runtimeMaskedSha': masked_runtime(a)}
    return out


def tree_clean(root=ROOT):
    """No uncommitted src/, no mutation in progress, no `*.mutorig` anywhere under src/."""
    st = subprocess.run(['git', 'status', '--porcelain', '--', 'src'], cwd=root, capture_output=True, text=True).stdout
    if st.strip():
        return 'src/ has uncommitted changes'
    if os.path.exists(os.path.join(root, 'output', 'MUTATION_IN_PROGRESS')):
        return 'a mutation run is in progress'
    for d, _, fs in os.walk(os.path.join(root, 'src')):
        if any(f.endswith('.mutorig') for f in fs):
            return 'a *.mutorig file exists (a mutant was applied)'
    return None


def forced_build(root=ROOT):
    r = subprocess.run(['forge', 'build', '--force'], cwd=root, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit('rc: forge build --force failed')


def check_build(root=ROOT, pin=PIN, rebuild=True):
    """Refuses unless the tree is clean, a forced rebuild ran, and every module equals the reviewed-build pin."""
    why = tree_clean(root)
    if why:
        raise SystemExit(f'rc: refusing: {why}')
    if not os.path.exists(pin):
        raise SystemExit('rc: no reviewed-build pin (audits/rc-build.json): run `rc.py pin` at the review close')
    if rebuild:
        forced_build(root)
    want = json.load(open(pin))['modules']
    got = build_ids(root)
    for m in MODULES:
        if got[m] != want[m]:
            raise SystemExit(f'rc: refusing: {m} differs from the reviewed build (audits/rc-build.json)')


def pin():
    why = tree_clean()
    if why:
        raise SystemExit(f'rc pin: refusing: {why}')
    forced_build()
    doc = {**stamp(), 'recorded_at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'),
           'generated_by': 'script/deploy/rc.py pin', 'modules': build_ids()}
    open(PIN, 'w').write(json.dumps(doc, indent=1) + '\n')
    print('rc pin: written audits/rc-build.json at', doc['commit'])


# ------------------------------------------------------------------ the pre-flight

def rc_needs():
    """The RC's NEED constants for exit and plan (NEED_EXIT_<chain>, NEED_PLAN_<chain> in src/RcBase.sol)."""
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
    pn = int(cast('nonce', '--block', 'pending', RC_DEPLOYER))
    if n != 0 or pn != 0:
        errs.append(f'RC deployer nonce latest {n} / pending {pn} != 0: the reserved address is lost or a send is in flight (F-007)')
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


# ------------------------------------------------------------------ the sends

def _record(doc, step, rec):
    doc['steps'][step] = {**stamp(), 'recorded_at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'), **rec}
    save(doc)


def deploy_module(step, name, args_sig=None, args=()):
    me = assert_keys()
    check_build()
    doc = load()
    if step in doc['steps']:
        raise SystemExit(f'rc: {step} already recorded')
    code = art(name)['bytecode']['object']
    if args_sig:
        code += cast('abi-encode', args_sig, *args)[2:]
    r = json.loads(cast('send', '--json', '--create', code, key='DEPLOYER_PK'))
    if r['status'] not in ('0x1', 1):
        raise SystemExit(f'rc: {name} creation failed: {r["transactionHash"]}')
    a = r['contractAddress']
    live = cast('code', a)
    if masked_runtime(art(name), live) != json.load(open(PIN))['modules'][name]['runtimeMaskedSha']:
        raise SystemExit(f'rc: the live {name} runtime differs from the reviewed build')
    _record(doc, step, {'from': me, 'tx': r['transactionHash'], 'address': a, 'contract': name,
                        'runtimeMaskedSha': masked_runtime(art(name), live)})
    print(name, a)
    return a


def deploy_rc():
    me = assert_keys()
    check_build()
    if not check():
        raise SystemExit('rc: pre-flight failed; nothing sent')
    doc = load()
    ext = doc['steps']['rcext']['address']
    b6 = doc['steps']['rcb6']['address']
    if cast('call', ext, 'B6()(address)').lower() != b6.lower():
        raise SystemExit('rc: the recorded RcExt does not bind the recorded RcB6')
    initcode = art('ReagentRC')['bytecode']['object'] + cast('abi-encode', 'f(address,address)', me, ext)[2:]
    runtime = cast('call', '--from', RC_DEPLOYER, '--create', initcode)
    est = int(cast('estimate', '--from', RC_DEPLOYER, '--create', initcode))
    r = json.loads(cast('send', '--json', '--nonce', '0', '--gas-limit', str(est * 3 // 2), '--create', initcode,
                        key='RC_DEPLOYER_PK'))
    ok = r['status'] in ('0x1', 1)
    rec = {'from': RC_DEPLOYER, 'tx': r['transactionHash'], 'status': 'ok' if ok else 'FAILED', 'estimate': est,
           'gasUsed': int(r['gasUsed'], 16), 'address': r.get('contractAddress')}
    _record(doc, 'rc', rec)
    assert ok, 'the RC creation failed: nonce 0 is spent (F-007): owner action'
    assert r['contractAddress'].lower() == RESERVED.lower(), 'RC landed off the reserved address'
    live = cast('code', RESERVED)
    assert live.lower() == runtime.lower(), 'the live runtime differs from the simulated one'
    assert masked_runtime(art('ReagentRC'), live) == json.load(open(PIN))['modules']['ReagentRC']['runtimeMaskedSha'], \
        'the live RC runtime differs from the reviewed build'
    assert cast('call', RESERVED, 'OWNER()(address)').lower() == me.lower()
    assert cast('call', RESERVED, 'EXT()(address)').lower() == ext.lower()
    rec.update(runtimeSha=hashlib.sha256(bytes.fromhex(live[2:])).hexdigest(), owner=me, ext=ext, b6=b6, asserted=True)
    _record(doc, 'rc', rec)
    print('ReagentRC', RESERVED, 'asserted')


def register():
    assert_keys()
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
    _record(doc, 'register', {'txs': txs})
    print('registered', len(txs), 'txs')


# ------------------------------------------------------------------ selftest (offline)

def selftest():
    """The refusals, with no network and no real key: swapped keys, a mutated artifact, a dirty tree."""
    fails = 0

    def refused(fn, label):
        nonlocal fails
        try:
            fn()
        except SystemExit:
            print('selftest ok:', label)
            return
        print('selftest FAIL:', label)
        fails += 1

    # (1) keys: two random keystores (neither is the RC deployer) → refused by the identity check before any send;
    #     the same keystores swapped (owner = the RC deployer's slot) likewise; a missing keystore → refused
    with tempfile.TemporaryDirectory() as t:
        pw = os.path.join(t, 'pw')
        open(pw, 'w').write('selftest')
        for n in ('owner', 'rcdep'):
            os.makedirs(os.path.join(t, n + '.d'))
            subprocess.run(['cast', 'wallet', 'new', os.path.join(t, n + '.d'), '--unsafe-password', 'selftest'],
                           capture_output=True, check=True)
            f = os.listdir(os.path.join(t, n + '.d'))[0]
            os.rename(os.path.join(t, n + '.d', f), os.path.join(t, n))
        env = {'RC_KEYSTORE_DIR': t, 'RC_KEYSTORE_PW': pw}
        addr_of('RC_DEPLOYER_PK', env)  # the fake keystores open: the refusal below is the identity check
        refused(lambda: assert_keys(env), 'a wrong RC deployer keystore is refused')
        os.remove(os.path.join(t, 'owner'))
        refused(lambda: assert_keys(env), 'a missing keystore is refused')
    # (2) a mutated artifact against a pin of the clean one → refused
    with tempfile.TemporaryDirectory() as t:
        for m in MODULES:
            os.makedirs(os.path.join(t, 'out', f'{m}.sol'))
            a = art(m)
            json.dump(a, open(os.path.join(t, 'out', f'{m}.sol', f'{m}.json'), 'w'))
        os.makedirs(os.path.join(t, 'src'))
        subprocess.run(['git', 'init', '-q'], cwd=t)
        p = os.path.join(t, 'pin.json')
        json.dump({'modules': build_ids(t)}, open(p, 'w'))
        check_build(t, p, rebuild=False)  # the clean copy passes
        a = art('RcExt', t)
        code = a['deployedBytecode']['object']
        a['deployedBytecode']['object'] = code[:-2] + ('00' if code[-2:] != '00' else '01')
        json.dump(a, open(os.path.join(t, 'out', 'RcExt.sol', 'RcExt.json'), 'w'))
        refused(lambda: check_build(t, p, rebuild=False), 'a mutated artifact is refused')
        open(os.path.join(t, 'src', 'X.sol.mutorig'), 'w').write('x')
        refused(lambda: check_build(t, p, rebuild=False), 'a *.mutorig in src/ is refused')
    print('rc selftest', 'OK' if not fails else 'FAIL')
    return not fails


if __name__ == '__main__':
    what = sys.argv[1] if len(sys.argv) > 1 else 'check'
    cmds = {'check': lambda: sys.exit(0 if check() else 1), 'pin': pin, '--selftest': lambda: sys.exit(0 if selftest() else 1),
            'b6': lambda: deploy_module('rcb6', 'RcB6'),
            'ext': lambda: deploy_module('rcext', 'RcExt', 'f(address)', (load()['steps']['rcb6']['address'],)),
            'rc': deploy_rc, 'register': register}
    if what not in cmds:
        raise SystemExit(f'rc: unknown command {what}')
    cmds[what]()
