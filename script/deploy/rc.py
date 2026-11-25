#!/usr/bin/env python3
"""The ReagentRC deploy on Lasna (spec §3.2, §9.2 R-DEPLOY; F-007, F-013), recorded by script into
`audits/deployments-5318007.json` (R-04).

  python3 script/deploy/rc.py check --post  the post-deploy check (every session's pre-flight since R-DEPLOY): the RC
                                         deployer's nonce is exactly 1 (its one transaction, F-007), the live RC code
                                         is the recorded runtime and the reviewed-build pin (immutables masked), OWNER
                                         and EXT are the recorded ones, and the Hubs' checks below
  python3 script/deploy/rc.py runtime    record the live RC's masked runtime (step `rc_runtime`) for test_R_DEPLOY__
  python3 script/deploy/rc.py receipts STEP NOTE LABEL:CHAIN:TX ...   record funding txs (faucet, depositTo) from
                                         their receipts (R-04: never typed by hand)
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
import json, os, re, shutil, subprocess, sys, hashlib, tempfile, datetime as dt

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


def redact(text, env=os.environ):
    """Keyed RPC URLs (they carry API keys) never reach the console: each is replaced by its variable's name (s8-forge
    r1 m-03; the same rule as drive.py)."""
    for k in ('UNICHAIN_SEPOLIA_RPC_URL', 'ETH_SEPOLIA_RPC_URL'):
        if env.get(k):
            text = text.replace(env[k], f'${k}')
    return text


def cast(*a, key=None, rpc=LASNA):
    w = _wallet(key) if key else []
    # options before the positionals: `send --create <CODE> [SIG] [ARGS]...` takes anything after CODE as ARGS (s6)
    net = [] if a[0] in OFFLINE else ['--rpc-url', rpc]
    r = subprocess.run(['cast', a[0], *w, *net, *a[1:]], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(redact(f'rc: cast {a[0]} failed: {(r.stderr or r.stdout).strip()[-300:]}'))
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


def post_errors(n, pn, live, rec, pin_masked, live_masked, owner, ext):
    """The post-deploy conditions (pure, so the selftest runs them offline)."""
    errs = []
    if n != 1 or pn != 1:
        errs.append(f'RC deployer nonce latest {n} / pending {pn} != 1 (its one transaction, the RC creation): F-007')
    if live in ('0x', ''):
        errs.append('no code at the reserved address')
        return errs
    if hashlib.sha256(bytes.fromhex(live[2:])).hexdigest() != rec.get('runtimeSha'):
        errs.append('the live RC runtime differs from the one recorded at the deploy')
    if live_masked != pin_masked:
        errs.append('the live RC runtime (masked) differs from the reviewed-build pin')
    if owner.lower() != str(rec.get('owner', '')).lower():
        errs.append('OWNER() differs from the recorded owner')
    if ext.lower() != str(rec.get('ext', '')).lower():
        errs.append('EXT() differs from the recorded RcExt')
    return errs


def check(post=False):
    errs = []
    n = int(cast('nonce', RC_DEPLOYER))
    pn = int(cast('nonce', '--block', 'pending', RC_DEPLOYER))
    if post:
        live = cast('code', RESERVED)
        rec = load()['steps']['rc']
        check_build(rebuild=False)  # the local artifact (its immutable map) is the pinned build
        errs += post_errors(n, pn, live, rec, json.load(open(PIN))['modules']['ReagentRC']['runtimeMaskedSha'],
                            masked_runtime(art('ReagentRC'), live) if live not in ('0x', '') else '',
                            cast('call', RESERVED, 'OWNER()(address)'), cast('call', RESERVED, 'EXT()(address)'))
    else:
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
    print('rc check' + (' --post' if post else ''), 'OK' if not errs else 'FAIL')
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


def record_runtime():
    """Step `rc_runtime`: the live RC's runtime hashes (plain and immutable-masked) and its OWNER / EXT, read now;
    refused unless the post-deploy check passes (s7-close r1 m-01: test_R_DEPLOY__ pins the RC's own runtime)."""
    if not check(post=True):
        raise SystemExit('rc runtime: the post-deploy check failed; nothing recorded')
    live = cast('code', RESERVED)
    doc = load()
    _record(doc, 'rc_runtime', {'source': 'eth_getCode', 'address': RESERVED,
                                'runtimeSha': hashlib.sha256(bytes.fromhex(live[2:])).hexdigest(),
                                'runtimeMaskedSha': masked_runtime(art('ReagentRC'), live),
                                'owner': cast('call', RESERVED, 'OWNER()(address)'),
                                'ext': cast('call', RESERVED, 'EXT()(address)')})
    print('rc runtime: recorded')


RPC_ENV = {'1301': 'UNICHAIN_SEPOLIA_RPC_URL', '11155111': 'ETH_SEPOLIA_RPC_URL'}


DEPOSIT_TO = '0xb760faf9'  # depositTo(address)
REQUEST = '0x27c78c42'     # the faucet's request(address)


def record_receipts(step, note, specs, replace=False):
    """A funding step (faucet request, depositTo) recorded from its receipts: LABEL:CHAIN:TX, CHAIN 5318007 = Lasna.
    The beneficiary of a depositTo / request call is decoded from the tx's own input (s8-forge r1 m-04); a receipt
    with status != 1 is refused before anything is written. `replace` re-records an existing step from the current
    tree and keeps the old record under `superseded`."""
    doc = load()
    if step in doc['steps'] and not replace:
        raise SystemExit(f'rc: {step} already recorded')
    txs = []
    for spec in specs:
        label, ch, tx = spec.split(':')
        rpc = LASNA if ch == '5318007' else os.environ[RPC_ENV[ch]]
        r = json.loads(cast('receipt', '--json', tx, rpc=rpc))
        t = json.loads(cast('tx', '--json', tx, rpc=rpc))
        if r['status'] not in ('0x1', 1):
            raise SystemExit(f'rc: {tx} did not land (status {r["status"]}): nothing recorded')
        row = {'label': label, 'chain': int(ch), 'tx': tx, 'block': int(r['blockNumber'], 16),
               'gasUsed': int(r['gasUsed'], 16), 'status': 'ok', 'from': t['from'], 'to': r['to'],
               'value': str(int(t['value'], 16))}
        inp = t.get('input') or ''
        if inp[:10] in (DEPOSIT_TO, REQUEST) and len(inp) >= 74:
            row['beneficiary'] = '0x' + inp[34:74]
            row['call'] = 'depositTo(address)' if inp[:10] == DEPOSIT_TO else 'request(address)'
        txs.append(row)
    rec = {'source': 'receipts', 'note': note, 'txs': txs}
    if step in doc['steps']:
        rec['superseded'] = doc['steps'][step]
    _record(doc, step, rec)
    print(step, 'recorded', len(txs), 'txs')


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

    def refused(fn, label, must=''):
        """The refusal must be the stated one: its message contains `must` (s6 tools r1 m-1)."""
        nonlocal fails
        try:
            fn()
        except SystemExit as e:
            if must in str(e):
                print('selftest ok:', label)
                return
            print('selftest FAIL (refused for another reason):', label, '->', e)
            fails += 1
            return
        print('selftest FAIL:', label)
        fails += 1

    # (1) keys, each refusal by its own check (s6 tools r1 m-1): (a) an rcdep keystore that is not the RC deployer;
    #     (b) the RC deployer's keystore in the owner slot (swapped); (c) a missing owner keystore
    global RC_DEPLOYER
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
        real = RC_DEPLOYER
        try:
            refused(lambda: assert_keys(env), 'a wrong RC deployer keystore is refused', 'does not derive to the RC deployer')
            RC_DEPLOYER = addr_of('RC_DEPLOYER_PK', env)  # the fake rcdep plays the RC deployer
            assert assert_keys(env) == addr_of('DEPLOYER_PK', env)  # control: the right pair passes
            shutil.copy(os.path.join(t, 'rcdep'), os.path.join(t, 'owner'))
            refused(lambda: assert_keys(env), 'swapped keys (the RC deployer in the owner slot) are refused', 'swapped')
            os.remove(os.path.join(t, 'owner'))
            refused(lambda: assert_keys(env), 'a missing keystore is refused', 'no keystore for DEPLOYER_PK')
        finally:
            RC_DEPLOYER = real
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
        refused(lambda: check_build(t, p, rebuild=False), 'a mutated artifact is refused', 'differs from the reviewed build')
        # git ignores it (as a mutation leaves it untracked-but-ignored), so the refusal is the *.mutorig check itself
        open(os.path.join(t, '.gitignore'), 'w').write('*.mutorig\nout/\npin.json\n')
        open(os.path.join(t, 'src', 'X.sol.mutorig'), 'w').write('x')
        refused(lambda: check_build(t, p, rebuild=False), 'a *.mutorig in src/ is refused', '.mutorig')
    # (3) the post-deploy conditions (offline): a correct read passes; each wrong read is refused by its own check
    code = '0x6001'
    rec = {'runtimeSha': hashlib.sha256(bytes.fromhex(code[2:])).hexdigest(), 'owner': '0xAa', 'ext': '0xBb'}
    good = dict(n=1, pn=1, live=code, rec=rec, pin_masked='m', live_masked='m', owner='0xaa', ext='0xbb')
    cases = [({}, ''), ({'n': 2}, 'its one transaction'), ({'pn': 2}, 'its one transaction'), ({'n': 0, 'pn': 0}, 'its one transaction'),
             ({'live': '0x'}, 'no code'), ({'live': '0x6002'}, 'recorded at the deploy'),
             ({'live_masked': 'x'}, 'reviewed-build pin'), ({'owner': '0xcc'}, 'OWNER()'), ({'ext': '0xcc'}, 'EXT()')]
    for over, must in cases:
        e = post_errors(**{**good, **over})
        ok = (not e) if not must else (len(e) == 1 and must in e[0])
        print('selftest ok:' if ok else 'selftest FAIL:', 'post-deploy', over or 'control passes', e)
        fails += 0 if ok else 1
    # (4) receipts (offline, a fake cast): the beneficiary decoded; a failed receipt refused before any write; a
    #     duplicate step refused; --replace keeps the old record; and keyed URLs redacted (s8-forge r1 m-03, m-04)
    global OUT, cast
    real_out, real_cast = OUT, cast
    with tempfile.TemporaryDirectory() as t:
        OUT = os.path.join(t, 'd.json')
        rc_hex = RESERVED[2:].lower().rjust(64, '0')
        fake = {'status': '0x1'}

        def fcast(*a, key=None, rpc=LASNA):
            if a[0] == 'receipt':
                return json.dumps({'status': fake['status'], 'blockNumber': '0x10', 'gasUsed': '0x5', 'to': SYSTEM})
            return json.dumps({'from': '0x' + '07' * 20, 'value': hex(10**18), 'input': DEPOSIT_TO + rc_hex})
        cast = fcast
        try:
            record_receipts('st', 'n', ['depositTo_RC:5318007:0xaa'])
            row = load()['steps']['st']['txs'][0]
            ok = row['beneficiary'].lower() == RESERVED.lower() and row['call'] == 'depositTo(address)'
            print('selftest ok:' if ok else 'selftest FAIL:', 'receipts: the depositTo beneficiary is decoded')
            fails += not ok
            refused(lambda: record_receipts('st', 'n', ['x:5318007:0xbb']), 'receipts: a duplicate step is refused',
                    'already recorded')
            fake['status'] = '0x0'
            refused(lambda: record_receipts('st2', 'n', ['x:5318007:0xcc']), 'receipts: a failed receipt is refused',
                    'did not land')
            ok = 'st2' not in load()['steps']
            print('selftest ok:' if ok else 'selftest FAIL:', 'receipts: nothing written for a failed receipt')
            fails += not ok
            fake['status'] = '0x1'
            record_receipts('st', 'n2', ['depositTo_RC:5318007:0xdd'], replace=True)
            st = load()['steps']['st']
            ok = st['note'] == 'n2' and st['superseded']['note'] == 'n'
            print('selftest ok:' if ok else 'selftest FAIL:', 'receipts: --replace keeps the old record as superseded')
            fails += not ok
        finally:
            OUT, cast = real_out, real_cast
    env = {'ETH_SEPOLIA_RPC_URL': 'https://x.example/v2/SECRETKEY'}
    red = redact('error sending request for url (https://x.example/v2/SECRETKEY)', env)
    ok = 'SECRETKEY' not in red and '$ETH_SEPOLIA_RPC_URL' in red and redact('plain', env) == 'plain'
    print('selftest ok:' if ok else 'selftest FAIL:', 'a keyed RPC URL in a cast error is redacted (control: plain text kept)')
    fails += not ok
    print('rc selftest', 'OK' if not fails else 'FAIL')
    return not fails


if __name__ == '__main__':
    what = sys.argv[1] if len(sys.argv) > 1 else 'check'
    if what == 'receipts':
        rest = [x for x in sys.argv[4:] if x != '--replace']
        record_receipts(sys.argv[2], sys.argv[3], rest, replace='--replace' in sys.argv[4:])
        sys.exit(0)
    cmds = {'check': lambda: sys.exit(0 if check('--post' in sys.argv[2:]) else 1), 'runtime': record_runtime, 'pin': pin, '--selftest': lambda: sys.exit(0 if selftest() else 1),
            'b6': lambda: deploy_module('rcb6', 'RcB6'),
            'ext': lambda: deploy_module('rcext', 'RcExt', 'f(address)', (load()['steps']['rcb6']['address'],)),
            'rc': deploy_rc, 'register': register}
    if what not in cmds:
        raise SystemExit(f'rc: unknown command {what}')
    cmds[what]()
