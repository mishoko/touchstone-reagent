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

def _run(args):
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f'drive: cast {args[1]} failed: {(r.stderr or r.stdout).strip()[-300:]}')
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


def send(v, to, sig, *args, expect_topic, dry):
    """The eth_call dry run of the exact call, then (unless dry) the send and its receipt check."""
    ch, me = v['chain'], signer()
    cast('call', '--from', me, to, sig, *args, rpc=rpc(ch))  # a revert raises: nothing is sent
    if dry:
        return None
    r = json.loads(_run(['cast', 'send', '--json', *wallet(), '--rpc-url', rpc(ch), to, sig, *args]))
    ok = int(r['status'], 16) == 1
    mine = [l for l in r['logs'] if l['address'].lower() == v['vault'].lower() and l['topics'][0] == expect_topic]
    rec = {'tx': r['transactionHash'], 'block': int(r['blockNumber'], 16), 'gasUsed': int(r['gasUsed'], 16),
           'status': 'ok' if ok else 'FAILED', 'to': to.lower(), 'function': sig.split('(')[0],
           'logIndex': int(mine[0]['logIndex'], 16) if len(mine) == 1 else None}
    return rec, ok and len(mine) == 1


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
        out = send(v, v['bundler'], SET_POS, str(lo), str(hi), '(false,false,0)', '0', MAXU,
                   expect_topic=T_ACTION, dry=dry)
        if dry:
            print(f'drive: dry run {k + 1}/{n}: setPositions({lo}, {hi}) at liveRef {lr}: does not revert')
            return
        rec, ok = out
        rec.update(range=[lo, hi], liveRef=lr)
        record(v['chain'], step, f'action_{v["name"]}', rec)
        print(f'drive: {k + 1}/{n} {rec["tx"]} block {rec["block"]} {rec["status"]}')
        if not ok:
            refuse(f'{rec["tx"]} did not land one Action from the vault (recorded as {rec["status"]}): stopping')
        prev = rec['block']


def poke(name, dry):
    v = resolve(name)
    preflight(v, 0)
    step = f'poke_{name}_{dt.datetime.now(dt.timezone.utc):%Y%m%d}'
    out = send(v, v['vault'], 'poke()', expect_topic=T_EPOCH, dry=dry)
    if dry:
        print(f'drive: dry run: poke() on {name} does not revert')
        return
    rec, ok = out
    rec['epochRecorded'] = ok
    record(v['chain'], step, f'poke_{name}', rec)
    print(f'drive: poke {rec["tx"]} {rec["status"]}; EpochRecorded in it: {ok}')


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
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
