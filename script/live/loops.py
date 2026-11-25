#!/usr/bin/env python3
"""Live loop evidence (R-04, spec §12 L-* rows), recorded by script into `audits/loops.json`: every entry is read back
from chain receipts and logs at collection time, never typed by hand.

  python3 script/live/loops.py ldyn     L-DYN: each recorded `ldyn_vault_*` deploy (audits/deployments-<chain>.json)
                                        → the Hub's `VaultBound(vault, id)` on the same chain; origin and delivery
                                        tx, blocks, timestamps, latency
  python3 script/live/loops.py lpay     L-PAY: the first callback each Hub received after its balance-only funding
                                        (`lpay_fund`): the Hub's balance before/after that delivery, and the proxy's
                                        debts/reserves of the Hub at the delivery block (want: debt 0, reserves 0)

Needs UNICHAIN_SEPOLIA_RPC_URL and ETH_SEPOLIA_RPC_URL (never printed); logs are read from the public endpoints
(the keyed ones cap eth_getLogs ranges).
"""
import json, os, subprocess, sys, datetime as dt

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'deploy'))
from prov import stamp  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, 'audits', 'loops.json')
CH = {
    '1301': {'rpc': 'UNICHAIN_SEPOLIA_RPC_URL', 'logs': 'https://sepolia.unichain.org',
             'proxy': '0x775c9B990ADe401060B78D0e98684eEf8d2466C1'},
    '11155111': {'rpc': 'ETH_SEPOLIA_RPC_URL', 'logs': 'https://ethereum-sepolia-rpc.publicnode.com',
                 'proxy': '0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4'},
}
T_VAULT_BOUND = '0x4a93a23c2057d5ed35e9b920e7650109f5cfb0417a8dfea5c7a960a04cc02af4'  # VaultBound(address,uint32)
WINDOW = 200  # blocks searched after the origin


def cast(*a, rpc):
    r = subprocess.run(['cast', *a, '--rpc-url', rpc], capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f'loops: cast {a[0]} failed: {(r.stderr or r.stdout).strip()[-300:]}')
    return r.stdout.strip()


def rpc(ch):
    return os.environ[CH[ch]['rpc']]


def deployments(ch):
    return json.load(open(os.path.join(ROOT, 'audits', f'deployments-{ch}.json')))['steps']


def hub(ch):
    return deployments(ch)['reagent']['reads']['CovenantFactory.HUB()']


def ts(ch, block):
    return int(cast('block', str(block), '--field', 'timestamp', rpc=rpc(ch)))


def logs(ch, addr, frm, to, topic0):
    to = min(to, int(cast('block-number', rpc=CH[ch]['logs'])) - 5)  # load-balanced heads lag (TRAPS)
    out = cast('logs', '--json', '--from-block', str(frm), '--to-block', str(to), '--address', addr,
               *([topic0] if topic0 else []), rpc=CH[ch]['logs'])
    return json.loads(out or '[]')


def load():
    return json.load(open(OUT)) if os.path.exists(OUT) else {'generated_by': 'script/live/loops.py', 'loops': [], 'runs': {}}


def save(doc, key, rows, note):
    """claims.py's schema: `loops` is a list of entries {id, originTx, destTx, ...}; a re-collection of an ID replaces
    its entries; `runs` keeps the provenance of each collection."""
    doc['loops'] = [e for e in doc.get('loops', []) if e.get('id') != key] + [{**r, 'id': key} for r in rows]
    doc.setdefault('runs', {})[key] = {**stamp(), 'recorded_at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'),
                                       'note': note, 'n': len(rows)}
    open(OUT, 'w').write(json.dumps(doc, indent=1) + '\n')
    print(f'loops: {key} -> {OUT} ({len(rows)} rows)')


T_TS_DEPLOYED = '0xd3718c34c2f5d26df60faa54c8035a99d8fc11a4d3437ec8c46bfcf64aaa2ee2'  # the factory's deploy event


def ldyn():
    """The vault is read from the origin receipt (the Touchstone factory's deploy log, topic1 = the bundler, data
    word 0 = the vault), and the VaultBound must carry that vault (s6 tools r1 m-5)."""
    reg = {t['label']: t['tx'] for t in json.load(open(os.path.join(ROOT, 'audits', 'deployments-5318007.json')))
           ['steps']['ldyn_registry']['txs']}
    rows = []
    for ch in CH:
        for step, s in deployments(ch).items():
            if not step.startswith('ldyn_vault_'):
                continue
            dep = [t for t in s['txs'] if 'deployAndPlace' in (t.get('function') or t.get('label') or '')]
            if len(dep) != 1:
                raise SystemExit(f'loops: {ch} {step}: no single deployAndPlace')
            o = json.loads(cast('receipt', '--json', dep[0]['tx'], rpc=rpc(ch)))
            if int(o['status'], 16) != 1:
                raise SystemExit(f'loops: {ch} {step}: the origin tx failed')
            ob = int(o['blockNumber'], 16)
            ev = [l for l in o['logs'] if l['topics'] and l['topics'][0] == T_TS_DEPLOYED]
            if len(ev) != 1:
                raise SystemExit(f'loops: {ch} {step}: {len(ev)} factory deploy logs in the origin receipt')
            bundler = '0x' + ev[0]['topics'][1][-40:]
            vault = '0x' + ev[0]['data'][2 + 24:2 + 64]
            vb = [l for l in logs(ch, hub(ch), ob, ob + WINDOW, T_VAULT_BOUND)
                  if ('0x' + l['topics'][1][-40:]).lower() == vault.lower()]
            if len(vb) != 1:
                raise SystemExit(f'loops: {ch} {step}: {len(vb)} VaultBound for {vault} within {WINDOW} blocks')
            l = vb[0]
            b = int(l['blockNumber'], 16)
            t0, t1 = ts(ch, ob), ts(ch, b)
            label = 'addBundler_' + step.rsplit('_', 1)[1]
            rows.append({'chain': int(ch), 'step': step, 'bundler': bundler, 'vault': vault,
                         'curator': int(l['topics'][2], 16), 'addBundlerTx': reg.get(label),
                         'originTx': o['transactionHash'], 'originBlock': ob, 'originTs': t0,
                         'destTx': l['transactionHash'], 'destBlock': b, 'destTs': t1, 'destEvent': 'VaultBound',
                         'latency_blocks': b - ob, 'latency_s': t1 - t0})
    doc = load()
    save(doc, 'L-DYN', rows, 'addBundler on the RC -> a registered bundler deploys its vault -> the RC subscribes from '
         'react() -> the Hub binds that vault (rcVault delivered); spec §12 L-DYN, C-08')


def lpay():
    """The Hub's FIRST charge after its balance-only funding, of any callback kind (s6 tools r1 M-2): the funding
    is the Hub's whole balance (0 before, the value after), reserves and debt 0 at funding; the first block whose
    balance is below the funded value is found by bisection, and its Hub logs name the delivery."""
    rows = []
    for ch in CH:
        f = deployments(ch)['lpay_fund']['txs'][0]
        h = hub(ch)
        bal = lambda blk: int(cast('balance', h, '--block', str(blk), rpc=rpc(ch)))  # noqa: E731
        call = lambda sig, blk: int(cast('call', '--block', str(blk), CH[ch]['proxy'], sig, h, rpc=rpc(ch)).split()[0])  # noqa: E731
        value = int(cast('tx', f['tx'], 'value', rpc=rpc(ch)), 0)
        fb = f['block']
        if bal(fb - 1) != 0 or bal(fb) != value:
            raise SystemExit(f'loops: {ch}: the funding is not the Hub\'s whole balance')
        if call('debts(address)(uint256)', fb) or call('reserves(address)(uint256)', fb):
            raise SystemExit(f'loops: {ch}: the Hub had debt or reserves at funding')
        head = int(cast('block-number', rpc=rpc(ch))) - 5
        if bal(head) >= value:
            raise SystemExit(f'loops: {ch}: no charge since the funding yet')
        lo, hi = fb, head  # bal(lo) == value, bal(hi) < value
        while hi - lo > 1:
            mid = (lo + hi) // 2
            lo, hi = (mid, hi) if bal(mid) >= value else (lo, mid)
        b = hi
        ev = logs(ch, h, b, b, '')
        if not ev:
            raise SystemExit(f'loops: {ch}: the first charge at {b} has no Hub log')
        l = min(ev, key=lambda x: int(x['logIndex'], 16))
        before, after = bal(b - 1), bal(b)
        debt, res = call('debts(address)(uint256)', b), call('reserves(address)(uint256)', b)
        rows.append({'chain': int(ch), 'hub': h, 'funded': value, 'originTx': f['tx'], 'originBlock': fb,
                     'destTx': l['transactionHash'], 'destBlock': b, 'destTopic0': l['topics'][0],
                     'balance_before': before, 'balance_after': after, 'charged': before - after,
                     'debt': debt, 'reserves': res, 'pass': before == value and after < before and debt == 0 and res == 0})
    doc = load()
    save(doc, 'L-PAY', rows, 'a Hub with zero reserves and only a balance receives its first callback (any kind): paid '
         'from the balance, debt 0 (spec §12 L-PAY, T-HUB-PAY (c), s2 D1-01)')


if __name__ == '__main__':
    what = sys.argv[1] if len(sys.argv) > 1 else ''
    cmds = {'ldyn': ldyn, 'lpay': lpay}
    if what not in cmds:
        raise SystemExit(__doc__)
    cmds[what]()
