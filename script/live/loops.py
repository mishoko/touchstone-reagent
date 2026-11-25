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
    out = cast('logs', '--json', '--from-block', str(frm), '--to-block', str(to), '--address', addr, topic0,
               rpc=CH[ch]['logs'])
    return json.loads(out or '[]')


def load():
    return json.load(open(OUT)) if os.path.exists(OUT) else {'generated_by': 'script/live/loops.py', 'loops': {}}


def save(doc, key, rows, note):
    doc['loops'][key] = {**stamp(), 'recorded_at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'),
                         'note': note, 'n': len(rows), 'rows': rows}
    open(OUT, 'w').write(json.dumps(doc, indent=1) + '\n')
    print(f'loops: {key} -> {OUT} ({len(rows)} rows)')


def ldyn():
    rows = []
    for ch in CH:
        for step, s in deployments(ch).items():
            if not step.startswith('ldyn_vault_'):
                continue
            dep = [t for t in s['txs'] if 'deployAndPlace' in (t.get('function') or t.get('label') or '')]
            if len(dep) != 1 or dep[0].get('status') != 'ok':
                raise SystemExit(f'loops: {ch} {step}: no single successful deployAndPlace')
            o = dep[0]
            vb = logs(ch, hub(ch), o['block'], o['block'] + WINDOW, T_VAULT_BOUND)
            # the vault of this deploy: the bound vault with no code before the origin block and code at it
            created = {('0x' + l['topics'][1][-40:]).lower(): l for l in vb}
            mine = [a for a in created if cast('code', a, '--block', str(o['block'] - 1), rpc=rpc(ch)) in ('0x', '')
                    and cast('code', a, '--block', str(o['block']), rpc=rpc(ch)) not in ('0x', '')]
            if len(mine) != 1:
                raise SystemExit(f'loops: {ch} {step}: {len(mine)} VaultBound vaults created by the origin tx')
            l = created[mine[0]]
            b = int(l['blockNumber'], 16)
            t0, t1 = ts(ch, o['block']), ts(ch, b)
            rows.append({'chain': int(ch), 'step': step, 'vault': mine[0], 'id': int(l['topics'][2], 16),
                         'origin': {'tx': o['tx'], 'block': o['block'], 'ts': t0},
                         'delivery': {'tx': l['transactionHash'], 'block': b, 'ts': t1, 'event': 'VaultBound'},
                         'latency_blocks': b - o['block'], 'latency_s': t1 - t0})
    doc = load()
    save(doc, 'L-DYN', rows, 'a registered bundler deploys its vault -> the RC subscribes from react() -> the Hub binds '
         'the vault (rcVault delivered); spec §12 L-DYN, C-08')


def lpay():
    rows = []
    for ch in CH:
        f = deployments(ch)['lpay_fund']['txs'][0]
        h = hub(ch)
        vb = logs(ch, h, f['block'], f['block'] + 100_000, T_VAULT_BOUND)
        if not vb:
            raise SystemExit(f'loops: {ch}: no callback after the funding yet')
        l = min(vb, key=lambda x: (int(x['blockNumber'], 16), int(x['logIndex'], 16)))
        b = int(l['blockNumber'], 16)
        bal = lambda blk: int(cast('balance', h, '--block', str(blk), rpc=rpc(ch)))  # noqa: E731
        call = lambda sig, blk: int(cast('call', '--block', str(blk), CH[ch]['proxy'], sig, h, rpc=rpc(ch)).split()[0])  # noqa: E731
        before, after = bal(b - 1), bal(b)
        debt, res = call('debts(address)(uint256)', b), call('reserves(address)(uint256)', b)
        rows.append({'chain': int(ch), 'hub': h, 'funding': {'tx': f['tx'], 'block': f['block']},
                     'first_callback': {'tx': l['transactionHash'], 'block': b, 'event': 'VaultBound'},
                     'balance_before': before, 'balance_after': after, 'charged': before - after,
                     'debt': debt, 'reserves': res, 'pass': debt == 0 and res == 0 and after < before})
    doc = load()
    save(doc, 'L-PAY', rows, 'a Hub with zero reserves and a balance receives its first callback: paid from the '
         'balance, debt 0 (spec §12 L-PAY, T-HUB-PAY (c), s2 D1-01)')


if __name__ == '__main__':
    what = sys.argv[1] if len(sys.argv) > 1 else ''
    cmds = {'ldyn': ldyn, 'lpay': lpay}
    if what not in cmds:
        raise SystemExit(__doc__)
    cmds[what]()
