#!/usr/bin/env python3
"""Records a forge broadcast into `audits/deployments-<chain>.json` (R-04: addresses and tx hashes by script, never by
hand). Reads `broadcast/<Script>.s.sol/<chain>/run-latest.json` and the receipts it holds, and merges one step:

  python3 script/deploy/record.py <step> <Script>.s.sol <chainId> [--rpc URL] [--note TEXT] [--replace]
      (CREATE2 txs: the address recomputed from deployer, salt and initcode, and checked for code with --rpc)
  python3 script/deploy/record.py tx <step> <chainId> <rpc> <label>=<txhash> ... [--note TEXT]
      (transactions sent outside a forge broadcast, read from their receipts; failed ones are kept and marked)

Each step stores: every CREATE (contract name, address, tx hash, block), every CALL (function, to, tx hash, block,
gasUsed), the run's commit and a timestamp. Steps already recorded are replaced only with --replace. The forge
console logs are not evidence; the receipts are.
"""
import json, os, subprocess, sys, datetime as dt

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
    commit = subprocess.run(['git', 'rev-parse', '--short', 'HEAD'], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    doc['steps'][step] = {'source': 'receipts', 'commit': commit,
                          'recorded_at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'), 'note': note, 'txs': txs}
    open(out, 'w').write(json.dumps(doc, indent=1) + '\n')
    print(f'record: {step} -> {out} ({len(txs)} txs)')
    return 0


def create2(deployer, salt, initcode):
    """keccak256(0xff ++ deployer ++ salt ++ keccak256(initcode))[12:] (EIP-1014)."""
    k = lambda hx: subprocess.run(['cast', 'keccak', hx], capture_output=True, text=True, check=True).stdout.strip()
    h = k('0xff' + deployer[2:].lower() + salt[2:].lower() + k(initcode)[2:])
    return subprocess.run(['cast', 'to-check-sum-address', '0x' + h[-40:]], capture_output=True, text=True, check=True).stdout.strip()


def main(argv):
    if argv and argv[0] == 'tx':
        return record_txs(argv[1:])
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
        if r is None or int(r['status'], 16) != 1:
            print(f'record: tx {h} has no successful receipt; refusing to record a partial step')
            return 1
        e = {'type': t['transactionType'], 'tx': h, 'block': int(r['blockNumber'], 16), 'gasUsed': int(r['gasUsed'], 16)}
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
    commit = subprocess.run(['git', 'rev-parse', '--short', 'HEAD'], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    doc['steps'][step] = {'script': script, 'commit': commit, 'recorded_at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'),
                          'note': note, 'txs': txs}
    open(out, 'w').write(json.dumps(doc, indent=1) + '\n')
    print(f'record: {step} -> {out} ({len(txs)} txs)')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
