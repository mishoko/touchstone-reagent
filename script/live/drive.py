#!/usr/bin/env python3
"""The loop driver (spec §9.5 L rows, PB-17; R-04): triggers each path's ORIGIN event from the owner/curator key and
records the origin transactions by script into `audits/deployments-<chain>.json`; the evidence (Lasna reaction,
destination delivery, latency) is collected afterwards by `script/live/loops.py`, never here.

  python3 script/live/drive.py status VAULT          the vault's Action budget left this RC epoch, the RC's Action
                                                     subscription for it, cooldown, liveRef, balances (read only)
  python3 script/live/drive.py action VAULT [--n N] [--gap S] [--dry]
                                                     N curator re-placements (`CuratorBundler.setPositions` on the
                                                     range centred on the hook's liveRef, W_TICKS wide: one `Action`
                                                     each) spaced >= COOLDOWN blocks + S seconds; the L-CON-* origins
  python3 script/live/drive.py poke VAULT [--dry]    an open `poke()` (the epoch roll's `EpochRecorded` re-opens the
                                                     RC's Action budget for that vault)
  python3 script/live/drive.py cov-create CHAIN [--dry]   the owner's Covenant (allow on the demo allowlist, create)
  python3 script/live/drive.py cov-rules CHAIN [--k 1 --b3 1 --share 6000 --budget WEI --agentcap WEI --ids 2,1] [--dry]
  python3 script/live/drive.py cov-fund CHAIN --t0 AMT --t1 AMT [--dry]   owner tokens into the Covenant
  python3 script/live/drive.py cov-alloc VAULT --shares S [--dry]          the owner's guarded allocate
  python3 script/live/drive.py retire YA [--dry | --yes-irreversible]   the curator retires Y_A (B3 gone: L-CRON's
                                                     exit; only once the owner's Covenant holds Y_A)
  python3 script/live/drive.py resolve STEP TX        a `pending` entry resolved from its receipt
  python3 script/live/drive.py --selftest            the refusals, offline

VAULT is XA, YA (1301) or XB (11155111), resolved from the recorded L-DYN deploys (the factory's `Deployed` log in the
`deployAndPlace` receipt; the hook from `vault.HOOK()`). Each send is preceded by its own eth_call dry run with the same
arguments, refused if that reverts, and followed by a receipt check (status 1, exactly one log of the expected kind
from the vault); `--dry` stops after the dry runs. Every landed tx is appended to the step
`lcon_<VAULT>_<UTC date>` (actions) or `poke_<VAULT>_<UTC date>` (pokes); entries are never rewritten.

Refusals before any send: the signer (the owner keystore) is not the bundler's OWNER; the RC's Action subscription for
the vault is not active (read from the Reactive MCP's live filter index: an Action sent now would not be delivered);
the vault's Action budget this RC epoch (ACTION_BUDGET = 8 Actions after the vault's last `EpochRecorded`, spec §6,
PB-6) is spent or would be exceeded by N.

Keys: the owner keystore (RC_KEYSTORE_DIR/owner with RC_KEYSTORE_PW, the handoff §3 recipe); never printed, never on
argv. Needs UNICHAIN_SEPOLIA_RPC_URL / ETH_SEPOLIA_RPC_URL (never printed); logs come from the public endpoints.
"""
import json, os, subprocess, sys, time, datetime as dt

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, 'script', 'deploy'))
sys.path.insert(0, os.path.join(ROOT, 'script', 'rnk'))
from prov import stamp  # noqa: E402

RC = '0xFbcDba49a040Ca5965377F73bB327F2F2B7DC4c9'
T_ACTION = '0x937e001463e9195c691b580d8f14c71c42291e5c57b3311a69422e91310293ba'   # RcBase.T_ACTION
T_EPOCH = '0x52ac8c0ec192dc514cc63f10118a6ba589667d3548a5ffcb0886465085529050'    # RcBase.T_EPOCH
T_RETIRED = '0xfe4758e6ccdb65cb7d78b678b554dc5319e940c6ee582e94811b7d48fbb506c5'  # RcBase.T_RETIRED
T_NOTE = '0x9f0625eae4d628e3bcc8083dac0036f15eb2c98996c115367665517f717810a7'     # RcBase.T_NOTE (Hub `Note`)
T_ALLOWED = '0x64966f3fe2ac8cae5e6f7e4196d1315efafdb78a4377de3887c56fa3b9ac47cb'  # CovenantFactory.Allowed
T_CREATED = '0x587ece4cd19692c5be1a4184503d607d45542d2aca0698c0068f52e09ccb541c'  # CovenantFactory.Created
T_TRANSFER = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'
RULES = 'setRules((uint8,bool,uint16,uint16,uint128,bool,uint16,uint128,uint32[4]))'
T_TS_DEPLOYED = '0xd3718c34c2f5d26df60faa54c8035a99d8fc11a4d3437ec8c46bfcf64aaa2ee2'
ACTION_BUDGET = 8  # RcBase.ACTION_BUDGET (spec §6)
SET_POS = 'setPositions(int24,int24,(bool,bool,uint128),uint160,uint256)'
MAXU = str(2**256 - 1)
CH = {
    '1301': {'rpc': 'UNICHAIN_SEPOLIA_RPC_URL', 'logs': 'https://sepolia.unichain.org', 'span': 1_000,
             'cooldown': 30, 'epoch': 3600, 'w': 2000, 'spacing': 10, 'mcp': 'Unichain Sepolia (1301)'},
    '11155111': {'rpc': 'ETH_SEPOLIA_RPC_URL', 'logs': 'https://ethereum-sepolia-rpc.publicnode.com', 'span': 5_000,
                 'cooldown': 14, 'epoch': 120, 'w': 2000, 'spacing': 10, 'mcp': 'Ethereum Sepolia (11155111)'},
}
VAULTS = {'XA': ('1301', 'ldyn_vault_XA'), 'YA': ('1301', 'ldyn_vault_YA'), 'XB': ('11155111', 'ldyn_vault_XB')}


class Refused(SystemExit):
    pass


def refuse(why):
    raise Refused(f'drive: refusing: {why}')


# ------------------------------------------------------------------ chain access (the seams the selftest replaces)

def redact(text):
    """Keyed RPC URLs (they carry API keys) never reach the console: each is replaced by its variable's name."""
    for k in ('UNICHAIN_SEPOLIA_RPC_URL', 'ETH_SEPOLIA_RPC_URL'):
        if os.environ.get(k):
            text = text.replace(os.environ[k], f'${k}')
    return text


def _run(args):
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(redact(f'drive: cast {args[1]} failed: {(r.stderr or r.stdout).strip()[-300:]}'))
    return r.stdout.strip()


def cast(*a, rpc):
    # options before positionals (TRAPS s6): `cast <sub> --rpc-url R <positionals…>`
    return _run(['cast', a[0], '--rpc-url', rpc, *a[1:]])


def wallet():
    d, pw = os.environ.get('RC_KEYSTORE_DIR'), os.environ.get('RC_KEYSTORE_PW')
    if not d or not pw or not os.path.isfile(os.path.join(d, 'owner')) or not os.path.isfile(pw):
        refuse('RC_KEYSTORE_DIR/owner and RC_KEYSTORE_PW must name the owner keystore and its password file')
    return ['--keystore', os.path.join(d, 'owner'), '--password-file', pw]


def signer():
    return _run(['cast', 'wallet', 'address', *wallet()])


def rpc(ch):
    return os.environ[CH[ch]['rpc']]


def head(ch):
    return int(cast('block-number', rpc=CH[ch]['logs'])) - 5  # load-balanced heads lag (TRAPS s6)


def logs(ch, addr, frm, to, topic0):
    out = []
    to = min(to, head(ch))
    while frm <= to:
        hi = min(to, frm + CH[ch]['span'] - 1)
        out += json.loads(cast('logs', '--json', '--from-block', str(frm), '--to-block', str(hi), '--address', addr,
                               topic0, rpc=CH[ch]['logs']) or '[]')
        frm = hi + 1
    return out


def mcp_filters():
    from rmcp import call  # noqa: E402  (the public Reactive MCP; no credentials)
    return call('list_subscriptions', {'rc': RC})['data']['subscriptions']


# ------------------------------------------------------------------ the vaults

def resolve(name):
    if name not in VAULTS:
        refuse(f'unknown vault {name!r} (one of {", ".join(VAULTS)})')
    ch, step = VAULTS[name]
    s = json.load(open(os.path.join(ROOT, 'audits', f'deployments-{ch}.json')))['steps'][step]
    dep = [t for t in s['txs'] if 'deployAndPlace' in (t.get('function') or t.get('label') or '')]
    if len(dep) != 1:
        refuse(f'{step}: no single deployAndPlace recorded')
    r = json.loads(cast('receipt', '--json', dep[0]['tx'], rpc=rpc(ch)))
    ev = [l for l in r['logs'] if l['topics'] and l['topics'][0] == T_TS_DEPLOYED]
    if int(r['status'], 16) != 1 or len(ev) != 1:
        refuse(f'{step}: the recorded deploy is not one landed factory deploy')
    bundler = '0x' + ev[0]['topics'][1][-40:]
    vault = '0x' + ev[0]['data'][2 + 24:2 + 64]
    hook = cast('call', vault, 'HOOK()(address)', rpc=rpc(ch))
    return {'name': name, 'chain': ch, 'bundler': bundler, 'vault': vault, 'hook': hook,
            'deployBlock': int(r['blockNumber'], 16)}


def budget_used(v):
    """Actions on the vault after its last `EpochRecorded` (a log-order comparison: block, then logIndex). The RC
    counts only the Actions it received while subscribed, so this is an upper bound on its `actionsThisEpoch`:
    refusing on it can only stop a send early, never let a 9th Action through."""
    ch, frm = v['chain'], max(v['deployBlock'], head(v['chain']) - 2 * CH[v['chain']]['epoch'])
    key = lambda l: (int(l['blockNumber'], 16), int(l['logIndex'], 16))  # noqa: E731
    ep = logs(ch, v['vault'], frm, head(ch), T_EPOCH)
    acts = logs(ch, v['vault'], frm, head(ch), T_ACTION)
    if not ep and frm > v['deployBlock']:
        # no epoch roll inside the window: count from the deploy (exact, at a higher read cost)
        frm = v['deployBlock']
        ep = logs(ch, v['vault'], frm, head(ch), T_EPOCH)
        acts = logs(ch, v['vault'], frm, head(ch), T_ACTION)
    last = max((key(l) for l in ep), default=(0, -1))
    return sum(1 for l in acts if key(l) > last)


def action_sub_active(v, filters=None):
    filters = mcp_filters() if filters is None else filters
    return any(f['active'] and f['contract'].lower() == v['vault'].lower() and f['topic0'] == T_ACTION
               and f['chain'] == CH[v['chain']]['mcp'] for f in filters)


def range_now(v):
    lr = int(cast('call', v['hook'], 'liveRef()(int24)', rpc=rpc(v['chain'])).split()[0])
    sp, w = CH[v['chain']]['spacing'], CH[v['chain']]['w']
    c = (lr // sp) * sp if lr >= 0 else -((-lr + sp - 1) // sp) * sp  # floor to the spacing (TsDeploy's centring)
    return lr, c - w // 2, c + w // 2


# ------------------------------------------------------------------ recording (R-04)

def record(ch, step, label, rec):
    out = os.path.join(ROOT, 'audits', f'deployments-{ch}.json')
    doc = json.load(open(out))
    s = doc['steps'].setdefault(step, {'source': 'receipts (script/live/drive.py)', **stamp(),
                                       'recorded_at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'),
                                       'note': 'loop-driver origins (spec §9.5); evidence by script/live/loops.py',
                                       'txs': []})
    if any(t['tx'] == rec['tx'] for t in s['txs']):
        refuse(f'{rec["tx"]} already recorded in {step}')
    s['txs'].append({'label': label, **rec})
    open(out, 'w').write(json.dumps(doc, indent=1) + '\n')


def record_update(ch, step, tx, fields):
    out = os.path.join(ROOT, 'audits', f'deployments-{ch}.json')
    doc = json.load(open(out))
    for t in doc['steps'][step]['txs']:
        if t['tx'] == tx:
            t.update(fields)
    open(out, 'w').write(json.dumps(doc, indent=1) + '\n')


def receipt(ch, tx, tries=30):
    for _ in range(tries):
        r = subprocess.run(['cast', 'receipt', '--json', '--rpc-url', rpc(ch), tx], capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            return json.loads(r.stdout)
        time.sleep(4)
    return None


def send(ch, to, sig, *args, expect, dry, step, label, extra=None):
    """The eth_call dry run of the exact call (a revert raises: nothing is sent); then (unless dry) an async send
    whose hash is recorded as `pending` BEFORE waiting, so a landed tx is never lost to a receipt timeout (r1 m-01);
    then the receipt: status 1 and exactly one log `expect` = (emitter, topic0)."""
    me = signer()
    cast('call', '--from', me, to, sig, *args, rpc=rpc(ch))
    if dry:
        return None, True
    h = _run(['cast', 'send', '--async', *wallet(), '--rpc-url', rpc(ch), to, sig, *args]).split()[-1]
    record(ch, step, label, {'tx': h, 'status': 'pending', 'to': to.lower(), 'function': sig.split('(')[0],
                             **(extra or {})})
    r = receipt(ch, h)
    if r is None:
        refuse(f'{h}: no receipt after 2 min (recorded as pending in {step}): check it before anything else')
    ok = int(r['status'], 16) == 1
    mine = [l for l in r['logs'] if l['topics'] and l['address'].lower() == expect[0].lower()
            and l['topics'][0] == expect[1]]
    rec = {'block': int(r['blockNumber'], 16), 'gasUsed': int(r['gasUsed'], 16), 'status': 'ok' if ok else 'FAILED',
           'logIndex': int(mine[0]['logIndex'], 16) if len(mine) == 1 else None}
    record_update(ch, step, h, rec)
    rec['tx'] = h
    if not (ok and len(mine) == 1):
        refuse(f'{h} did not land exactly one expected log (recorded as {rec["status"]} in {step}): stopping')
    return rec, True


def resolve_pending(step, tx):
    """A `pending` entry (its receipt timed out at send time) resolved from its receipt by script (r2 m-05)."""
    ch = next((c for c in CH if step in json.load(open(os.path.join(ROOT, 'audits', f'deployments-{c}.json')))['steps']), None)
    if ch is None:
        refuse(f'no step {step}')
    r = receipt(ch, tx, tries=3)
    if r is None:
        refuse(f'{tx}: still no receipt')
    want = {'lcon': T_ACTION, 'poke': T_EPOCH}.get(step.split('_')[0])
    mine = [l for l in r['logs'] if l['topics'] and want and l['topics'][0] == want]
    record_update(ch, step, tx, {'block': int(r['blockNumber'], 16), 'gasUsed': int(r['gasUsed'], 16),
                                 'status': 'ok' if int(r['status'], 16) == 1 else 'FAILED',
                                 'logIndex': int(mine[0]['logIndex'], 16) if len(mine) == 1 else None})
    print(f'drive: {step} {tx} resolved')


def preflight(v, n=1, filters=None):
    me = signer()
    owner = cast('call', v['bundler'], 'OWNER()(address)', rpc=rpc(v['chain']))
    if me.lower() != owner.lower():
        refuse('the owner keystore is not the bundler OWNER')
    if n and not action_sub_active(v, filters):
        refuse(f'the RC Action subscription for {v["name"]} is not active (a new Action would not be delivered): '
               '`poke` after the vault epoch rolls, then wait for the resubscription')
    used = budget_used(v)
    if n and used + n > ACTION_BUDGET:
        refuse(f'{v["name"]}: {used} Actions since its last EpochRecorded; {n} more exceed ACTION_BUDGET {ACTION_BUDGET}')
    return used


# ------------------------------------------------------------------ commands

def status(name):
    v = resolve(name)
    ch = v['chain']
    lr, lo, hi = range_now(v)
    print(json.dumps({**v, 'liveRef': lr, 'range': [lo, hi], 'actionsSinceEpochRoll': budget_used(v),
                      'actionSubActive': action_sub_active(v), 'head': head(ch),
                      'signer': signer(), 'signerBalanceWei': int(cast('balance', signer(), rpc=rpc(ch)))}, indent=1))


def action(name, n, gap, dry):
    v = resolve(name)
    used = preflight(v, n)
    step = f'lcon_{name}_{dt.datetime.now(dt.timezone.utc):%Y%m%d}'
    print(f'drive: {name} {v["vault"]}: {used} Actions since the epoch roll; sending {n}{" (dry)" if dry else ""}')
    prev = None
    for k in range(n):
        if prev is not None:
            # COOLDOWN blocks since the last Action, then the gap (the markout window settles in the next prologue)
            while int(cast('block-number', rpc=rpc(v['chain']))) < prev + CH[v['chain']]['cooldown'] + 1:
                time.sleep(2)
            time.sleep(gap)
            preflight(v, 1)  # re-checked before every send: the subscription and the budget
        lr, lo, hi = range_now(v)
        rec, _ = send(v['chain'], v['bundler'], SET_POS, str(lo), str(hi), '(false,false,0)', '0', MAXU,
                      expect=(v['vault'], T_ACTION), dry=dry, step=step, label=f'action_{v["name"]}',
                      extra={'range': [lo, hi], 'liveRef': lr})
        if dry:
            print(f'drive: dry run {k + 1}/{n}: setPositions({lo}, {hi}) at liveRef {lr}: does not revert')
            return
        print(f'drive: {k + 1}/{n} {rec["tx"]} block {rec["block"]} {rec["status"]}')
        prev = rec['block']


def poke(name, dry):
    v = resolve(name)
    preflight(v, 0)
    step = f'poke_{name}_{dt.datetime.now(dt.timezone.utc):%Y%m%d}'
    rec, _ = send(v['chain'], v['vault'], 'poke()', expect=(v['vault'], T_EPOCH), dry=dry, step=step,
                  label=f'poke_{name}')
    print(f'drive: dry run: poke() on {name} does not revert' if dry else
          f'drive: poke {rec["tx"]} {rec["status"]}: EpochRecorded emitted')


# ------------------------------------------------------------------ the Covenant path (L-CRON, L-GAS budget/exit/plan)

def reagent(ch):
    a = json.load(open(os.path.join(ROOT, 'audits', f'deployments-{ch}.json')))['steps']['reagent']['reads']['addresses']
    return a['factory'], a['hub']


def covenant(ch):
    f, _ = reagent(ch)
    return cast('call', f, 'predict(address)(address)', signer(), rpc=rpc(ch))


def tokens(ch):
    v = resolve('XA' if ch == '1301' else 'XB')
    ref = cast('call', v['hook'], 'REF_POOL()(address)', rpc=rpc(ch))
    return cast('call', ref, 'token0()(address)', rpc=rpc(ch)), cast('call', ref, 'token1()(address)', rpc=rpc(ch))


def cov_create(ch, dry):
    """allow(owner) on the demo allowlist (PA-11; the owner is the factory ADMIN) if needed, then create()."""
    f, _ = reagent(ch)
    me, step = signer(), f'lcron_{ch}_{dt.datetime.now(dt.timezone.utc):%Y%m%d}'
    if cast('call', f, 'ADMIN()(address)', rpc=rpc(ch)).lower() != me.lower():
        refuse('the owner keystore is not the CovenantFactory ADMIN')
    c = covenant(ch)
    if cast('code', c, rpc=rpc(ch)) not in ('0x', ''):
        print(f'drive: Covenant {c} already exists on {ch}')
        return
    if cast('call', f, 'allowed(address)(bool)', me, rpc=rpc(ch)) != 'true':
        send(ch, f, 'allow(address,bool)', me, 'true', expect=(f, T_ALLOWED),
             dry=dry, step=step, label='factory_allow')
        if dry:
            print('drive: dry run: allow(owner) does not revert (create() is dry-run after it lands)')
            return
    send(ch, f, 'create()', expect=(f, T_CREATED), dry=dry, step=step, label='covenant_create')
    print(f'drive: {"dry run: create() does not revert" if dry else "Covenant created at " + c}')


def cov_rules(ch, k, b3, share, budget, agentcap, ids, dry):
    _, hub_ = reagent(ch)
    c, step = covenant(ch), f'lcron_{ch}_{dt.datetime.now(dt.timezone.utc):%Y%m%d}'
    ids4 = (ids + [0, 0, 0, 0])[:4]
    rb = f'({k},{str(bool(b3)).lower()},0,{share},{budget},false,0,{agentcap},[{",".join(map(str, ids4))}])'
    send(ch, c, RULES, rb, expect=(hub_, T_NOTE), dry=dry, step=step, label='setRules', extra={'rules': rb})
    print(f'drive: setRules {rb} {"(dry: does not revert)" if dry else "landed"}')


def cov_fund(ch, a0, a1, dry):
    c, step = covenant(ch), f'lcron_{ch}_{dt.datetime.now(dt.timezone.utc):%Y%m%d}'
    for t, a in zip(tokens(ch), (a0, a1)):
        if int(a):
            send(ch, t, 'transfer(address,uint256)', c, str(a), expect=(t, T_TRANSFER), dry=dry, step=step,
                 label='fund_covenant')
    print(f'drive: Covenant funded {a0} / {a1}{" (dry)" if dry else ""}')


def cov_alloc(name, shares, dry):
    v = resolve(name)
    ch = v['chain']
    _, hub_ = reagent(ch)
    c, step = covenant(ch), f'lcron_{ch}_{dt.datetime.now(dt.timezone.utc):%Y%m%d}'
    m0, m1 = (cast('call', t, 'balanceOf(address)(uint256)', c, rpc=rpc(ch)).split()[0] for t in tokens(ch))
    send(ch, c, 'allocate(address,uint256,uint256,uint256)', v['vault'], str(shares), m0, m1,
         expect=(hub_, T_NOTE), dry=dry, step=step, label=f'allocate_{name}')
    print(f'drive: allocate {shares} shares of {name} {"(dry: does not revert)" if dry else "landed"}')


RETIRABLE = ('YA',)  # owner decision s7: only Y_A (curator 2) is retired; X_A / X_B carry the L-CON paths


def retire(name, dry, yes):
    """The curator retires its vault (Touchstone: EXITED, the unvested pay forfeited over the drip): the B3 'gone'
    trigger of L-CRON's exit (owner decision s7). Irreversible: only a RETIRABLE vault, only once the owner's
    Covenant holds it (else the trigger is spent with no exit to watch), and only with --yes-irreversible (r2 m-04)."""
    if name not in RETIRABLE:
        refuse(f'{name} is not retirable (owner decision: {RETIRABLE} only)')
    v = resolve(name)
    preflight(v, 0)
    held = int(cast('call', v['vault'], 'balanceOf(address)(uint256)', covenant(v['chain']), rpc=rpc(v['chain'])).split()[0])
    if held == 0:
        refuse(f'the owner\'s Covenant holds no {name} shares: allocate first (L-CRON needs a holding to exit)')
    if not dry and not yes:
        refuse('retire is irreversible: pass --yes-irreversible')
    step = f'lcron_{v["chain"]}_{dt.datetime.now(dt.timezone.utc):%Y%m%d}'
    send(v['chain'], v['bundler'], 'retire()', expect=(v['vault'], T_RETIRED), dry=dry, step=step,
         label=f'retire_{name}')
    print(f'drive: retire {name} {"(dry: does not revert)" if dry else "landed"}')


# ------------------------------------------------------------------ selftest (offline: the seams replaced)

def selftest():
    fails = 0
    g = globals()
    saved = {k: g[k] for k in ('signer', 'cast', 'budget_used', 'mcp_filters', 'head', 'logs', 'rpc')}
    g['rpc'] = lambda ch: 'http://selftest.invalid'
    v = {'name': 'XA', 'chain': '1301', 'bundler': '0x' + '11' * 20, 'vault': '0x' + '22' * 20, 'hook': '0x' + '33' * 20,
         'deployBlock': 1}
    on = [{'active': True, 'contract': v['vault'], 'topic0': T_ACTION, 'chain': CH['1301']['mcp']}]

    def case(label, must, used=0, filters=on, me='0x' + 'aa' * 20, owner='0x' + 'aa' * 20, n=1):
        nonlocal fails
        g['signer'] = lambda: me
        g['cast'] = lambda *a, rpc: owner if a[0] == 'call' else '0'
        g['budget_used'] = lambda _v: used
        try:
            preflight(v, n, filters)
        except Refused as e:
            if must and must in str(e):
                print('selftest ok:', label)
                return
            print('selftest FAIL (refused for another reason):', label, '->', e)
            fails += 1
            return
        if must:
            print('selftest FAIL (not refused):', label)
            fails += 1
        else:
            print('selftest ok:', label)

    try:
        case('control: owner signer, subscription active, budget free → passes', None, used=0)
        case('control: the 8th Action (7 used) passes', None, used=7)
        case('a signer that is not the bundler OWNER is refused', 'not the bundler OWNER', owner='0x' + 'bb' * 20)
        case('an inactive Action subscription is refused', 'not active', filters=[{**on[0], 'active': False}])
        case('another vault\'s subscription does not count', 'not active', filters=[{**on[0], 'contract': '0x' + '44' * 20}])
        case('the same vault on the other chain does not count', 'not active',
             filters=[{**on[0], 'chain': CH['11155111']['mcp']}])
        case('a 9th Action (8 used) is refused', 'exceed ACTION_BUDGET', used=8)
        case('a batch that would cross the budget (6 used, 3 more) is refused', 'exceed ACTION_BUDGET', used=6, n=3)
        g['cast'] = saved['cast']
        for nm, must in (('XA', 'not retirable'), ('XB', 'not retirable')):
            try:
                retire(nm, True, False)
                print(f'selftest FAIL (not refused): retire {nm}')
                fails += 1
            except Refused as e:
                print(f'selftest ok: retire {nm} is refused' if must in str(e) else f'selftest FAIL: {e}')
                fails += 0 if must in str(e) else 1
        saved2 = {k: g[k] for k in ('resolve', 'preflight', 'covenant')}
        g['resolve'] = lambda nm: {**v, 'name': nm}
        g['preflight'] = lambda *a, **k: 0
        g['covenant'] = lambda ch: '0x' + '55' * 20
        for held, flag, must, label in (('0', True, 'holds no YA shares', 'retire YA before the Covenant holds it'),
                                        ('7', False, 'pass --yes-irreversible', 'a live retire without --yes-irreversible')):
            g['cast'] = lambda *a, rpc, _h=held: _h
            try:
                retire('YA', flag, False)
                print('selftest FAIL (not refused):', label)
                fails += 1
            except Refused as e:
                print(f'selftest ok: {label} is refused' if must in str(e) else f'selftest FAIL: {label}: {e}')
                fails += 0 if must in str(e) else 1
        g['cast'] = lambda *a, rpc: '7'
        retire('YA', True, False)  # control: held, a dry run passes every refusal (the send's own dry run is stubbed)
        print('selftest ok: control: retire YA --dry with a holding passes the refusals')
        g.update(saved2)
        g['cast'] = saved['cast']
        try:
            resolve('ZZ')
            print('selftest FAIL (not refused): an unknown vault')
            fails += 1
        except Refused as e:
            print('selftest ok: an unknown vault is refused' if 'unknown vault' in str(e) else f'selftest FAIL: {e}')
            fails += 0 if 'unknown vault' in str(e) else 1
        # the budget counter: Actions after the last EpochRecorded, by (block, logIndex)
        g['head'] = lambda ch: 10_000

        def fake_logs(ch, addr, frm, to, topic0):
            mk = lambda b, i: {'blockNumber': hex(b), 'logIndex': hex(i)}  # noqa: E731
            return [mk(100, 5)] if topic0 == T_EPOCH else [mk(90, 1), mk(100, 4), mk(100, 6), mk(150, 0)]
        g['logs'] = fake_logs
        got = saved['budget_used']({**v, 'deployBlock': 1})
        if got != 2:
            print(f'selftest FAIL: budget counter {got} != 2 (Actions after the roll at (100, 5))')
            fails += 1
        else:
            print('selftest ok: the budget counter counts only Actions after the last EpochRecorded (same block too)')
    finally:
        g.update(saved)
    print('drive selftest', 'OK' if not fails else 'FAIL')
    return not fails


def main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        print(__doc__)
        return 2
    if argv[0] == '--selftest':
        return 0 if selftest() else 1
    opt = lambda k, d: type(d)(argv[argv.index(k) + 1]) if k in argv else d  # noqa: E731
    cmd, name = argv[0], (argv[1] if len(argv) > 1 else '')
    if cmd == 'status':
        status(name)
    elif cmd == 'action':
        action(name, opt('--n', 1), opt('--gap', 15), '--dry' in argv)
    elif cmd == 'poke':
        poke(name, '--dry' in argv)
    elif cmd == 'cov-create':
        cov_create(name, '--dry' in argv)
    elif cmd == 'cov-rules':
        cov_rules(name, opt('--k', 1), opt('--b3', 1), opt('--share', 6000), opt('--budget', 10**20),
                  opt('--agentcap', 10**19), [int(x) for x in opt('--ids', '2,1').split(',')], '--dry' in argv)
    elif cmd == 'cov-fund':
        cov_fund(name, opt('--t0', 0), opt('--t1', 0), '--dry' in argv)
    elif cmd == 'cov-alloc':
        cov_alloc(name, opt('--shares', 0), '--dry' in argv)
    elif cmd == 'retire':
        retire(name, '--dry' in argv, '--yes-irreversible' in argv)
    elif cmd == 'resolve':
        resolve_pending(name, argv[2] if len(argv) > 2 else '')
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
