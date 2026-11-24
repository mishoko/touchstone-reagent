#!/usr/bin/env python3
"""Records a forge broadcast into `audits/deployments-<chain>.json` (R-04: addresses and tx hashes by script, never by
hand). Reads `broadcast/<Script>.s.sol/<chain>/run-latest.json` and the receipts it holds, and merges one step:

  python3 script/deploy/record.py <step> <Script>.s.sol <chainId> [--rpc URL] [--note TEXT] [--replace]
      (CREATE2 txs: the address recomputed from deployer, salt and initcode, and checked for code with --rpc)
  python3 script/deploy/record.py tx <step> <chainId> <rpc> <label>=<txhash> ... [--note TEXT]
      (transactions sent outside a forge broadcast, read from their receipts; failed ones are kept and marked)
  python3 script/deploy/record.py supersede <chainId> <step> --note TEXT
      (renames the step to <step>_superseded_<n> and marks it, so it is never cited as current evidence)

Each step stores: every CREATE (contract name, address, tx hash, block), every CALL (function, to, tx hash, block,
gasUsed), the run's commit and a timestamp. Steps already recorded are replaced only with --replace. The forge
console logs are not evidence; the receipts are.
"""
import json, os, subprocess, sys, datetime as dt
from prov import stamp

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def record_txs(argv):
    step, chain, rpc = argv[0], argv[1], argv[2]
    note = argv[argv.index('--note') + 1] if '--note' in argv else ''
    pairs = [a for a in argv[3:] if '=' in a and not a.startswith('--')]
    txs = []
    for pr in pairs:
        label, h = pr.split('=', 1)
        r = json.loads(subprocess.run(['cast', 'receipt', h, '--json', '--rpc-url', rpc], capture_output=True, text=True, check=True).stdout)
        e = {'label': label, 'tx': h, 'block': int(r['blockNumber'], 16), 'gasUsed': int(r['gasUsed'], 16),
             'status': 'ok' if int(r['status'], 16) == 1 else 'FAILED'}
        if r.get('contractAddress'):
            e['address'] = r['contractAddress']
        else:
            e['to'] = r.get('to')
        txs.append(e)
    out = os.path.join(ROOT, 'audits', f'deployments-{chain}.json')
    doc = json.load(open(out)) if os.path.exists(out) else {'chainId': int(chain), 'generated_by': 'script/deploy/record.py', 'steps': {}}
    if step in doc['steps'] and '--replace' not in argv:
        print(f'record: step {step} already recorded in {out}; pass --replace to overwrite')
        return 1
    doc['steps'][step] = {'source': 'receipts', **stamp(),
                          'recorded_at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'), 'note': note, 'txs': txs}
    open(out, 'w').write(json.dumps(doc, indent=1) + '\n')
    print(f'record: {step} -> {out} ({len(txs)} txs)')
    return 0


def supersede(argv):
    if len(argv) < 2 or '--note' not in argv:
        print(__doc__)
        return 2
    chain, step, note = argv[0], argv[1], argv[argv.index('--note') + 1]
    out = os.path.join(ROOT, 'audits', f'deployments-{chain}.json')
    doc = json.load(open(out))
    if step not in doc['steps']:
        print(f'record: no step {step} in {out}')
        return 1
    n = 1 + sum(1 for k in doc['steps'] if k.startswith(step + '_superseded_'))
    rec = doc['steps'].pop(step)
    rec['superseded'] = note
    rec['superseded_at'] = dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')
    rec['superseded_by'] = 'script/deploy/record.py supersede'
    doc['steps'][f'{step}_superseded_{n}'] = rec
    open(out, 'w').write(json.dumps(doc, indent=1) + '\n')
    print(f'record: {step} -> {step}_superseded_{n}')
    return 0


def _reagent_reads(txs, rpc):
    """The deployed links read from chain at record time: the factory's HUB(), the Hub's FACTORY(), RC(), PROXY()
    and needs() (s3: formerly a hand-run companion read)."""
    f = [t['address'] for t in txs if t.get('contract') == 'CovenantFactory' and t.get('address')]
    if len(f) != 1:
        return None
    c = lambda *a: subprocess.run(['cast', 'call', *a, '--rpc-url', rpc], capture_output=True, text=True).stdout.strip()
    hub = c(f[0], 'HUB()(address)')
    impl = c(f[0], 'IMPL()(address)')
    return {'addresses': {'ext': c(impl, 'EXT()(address)'), 'impl': impl, 'factory': f[0], 'hub': hub},
            'source': 'script/deploy/record.py (cast call at record time)',
            'at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'),
            'CovenantFactory.HUB()': hub, 'ReagentHub.FACTORY()': c(hub, 'FACTORY()(address)'),
            'ReagentHub.RC()': c(hub, 'RC()(address)'), 'ReagentHub.PROXY()': c(hub, 'PROXY()(address)'),
            'ReagentHub.needs()': c(hub, 'needs()(uint256,uint256)').replace('\n', ' ')}


def create2(deployer, salt, initcode):
    """keccak256(0xff ++ deployer ++ salt ++ keccak256(initcode))[12:] (EIP-1014)."""
    k = lambda hx: subprocess.run(['cast', 'keccak', hx], capture_output=True, text=True, check=True).stdout.strip()
    h = k('0xff' + deployer[2:].lower() + salt[2:].lower() + k(initcode)[2:])
    return subprocess.run(['cast', 'to-check-sum-address', '0x' + h[-40:]], capture_output=True, text=True, check=True).stdout.strip()


def main(argv):
    if argv and argv[0] == 'tx':
        return record_txs(argv[1:])
    if argv and argv[0] == 'supersede':
        return supersede(argv[1:])
    if len(argv) < 3:
        print(__doc__)
        return 2
    step, script, chain = argv[0], argv[1], argv[2]
    note = argv[argv.index('--note') + 1] if '--note' in argv else ''
    rpc = argv[argv.index('--rpc') + 1] if '--rpc' in argv else None
    src = os.path.join(ROOT, 'broadcast', script, chain, 'run-latest.json')
    run = json.load(open(src))
    rec = {r['transactionHash']: r for r in run.get('receipts', [])}
    txs = []
    for t in run['transactions']:
        h = t.get('hash')
        r = rec.get(h)
        if r is None:
            print(f'record: tx {h} has no receipt; refusing to record a partial step')
            return 1
        ok = int(r['status'], 16) == 1
        e = {'type': t['transactionType'], 'tx': h, 'block': int(r['blockNumber'], 16), 'gasUsed': int(r['gasUsed'], 16),
             'status': 'ok' if ok else 'FAILED'}
        if not ok:
            # a failed tx is kept and marked, never dropped (tools review m-7), and records no address
            print(f'record: tx {h} FAILED; recorded as FAILED')
            e.update(contract=t.get('contractName'), function=t.get('function'))
            txs.append(e)
            continue
        if t['transactionType'] == 'CREATE':
            e.update(contract=t.get('contractName'), address=t.get('contractAddress'))
        elif t['transactionType'] == 'CREATE2':
            # through the 0x4e59 deployer: the address is recomputed from (deployer, salt, initcode) and must hold
            # code on chain (s2 tools review M-1: these were recorded as bare calls)
            data = t['transaction']['input']
            salt, initcode = '0x' + data[2:66], '0x' + data[66:]
            addr = create2(t['transaction']['to'], salt, initcode)
            if t.get('contractAddress') and t['contractAddress'].lower() != addr.lower():
                print(f'record: CREATE2 address mismatch for {h}: {t["contractAddress"]} vs {addr}')
                return 1
            if rpc and len(subprocess.run(['cast', 'code', addr, '--rpc-url', rpc], capture_output=True, text=True).stdout.strip()) <= 2:
                print(f'record: no code at the CREATE2 address {addr} ({h})')
                return 1
            e.update(contract=t.get('contractName'), address=addr, deployer=t['transaction']['to'], salt=salt)
        else:
            e.update(function=t.get('function'), to=t['transaction'].get('to'))
        # contracts created inside the call (factory deploys)
        inner = [{'contract': a.get('contractName'), 'address': a.get('address')} for a in t.get('additionalContracts', [])]
        if inner:
            e['created'] = inner
        txs.append(e)
    out = os.path.join(ROOT, 'audits', f'deployments-{chain}.json')
    doc = json.load(open(out)) if os.path.exists(out) else {'chainId': int(chain), 'generated_by': 'script/deploy/record.py', 'steps': {}}
    if step in doc['steps'] and '--replace' not in argv:
        print(f'record: step {step} already recorded in {out}; pass --replace to overwrite')
        return 1
    reads = _reagent_reads(txs, rpc) if script == 'Reagent.s.sol' and rpc else None
    doc['steps'][step] = {'script': script, **stamp(), **({'reads': reads} if reads else {}), 'recorded_at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'),
                          'note': note, 'txs': txs}
    open(out, 'w').write(json.dumps(doc, indent=1) + '\n')
    print(f'record: {step} -> {out} ({len(txs)} txs)')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
