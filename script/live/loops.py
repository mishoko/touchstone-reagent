#!/usr/bin/env python3
"""Live loop evidence (R-04, spec §12 L-* rows), recorded by script into `audits/loops.json`: every entry is read back
from chain receipts and logs at collection time, never typed by hand.

  python3 script/live/loops.py ldyn     L-DYN: each recorded `ldyn_vault_*` deploy (audits/deployments-<chain>.json)
                                        → the Hub's `VaultBound(vault, id)` on the same chain; origin and delivery
                                        tx, blocks, timestamps, latency
  python3 script/live/loops.py lpay     L-PAY: the first callback each Hub received after its balance-only funding
                                        (`lpay_fund`): the Hub's balance before/after that delivery, and the proxy's
                                        debts/reserves of the Hub at the delivery block (want: debt 0, reserves 0)
  python3 script/live/loops.py lcon     L-CON-AA / L-CON-AB (and -BA / -BB once X_B has driver steps): each Action the
                                        loop driver recorded (`lcon_<VAULT>_<date>` steps, script/live/drive.py) →
                                        the RC's reaction on Lasna (found by the Reactive MCP's trace, then checked
                                        against the reaction tx's own LogRecord input) and the snapshot seq it sent
                                        each Hub → the first `Applied(id, seq' >= seq)` on each Hub (PB-17: a
                                        coalesced loop ends there); per path the median, nearest-rank p95, max and
                                        delivered/attempted, and per dated batch the Reactive-leg median and max
  python3 script/live/loops.py lgas [--cron FROM TO]
                                        L-GAS: per (chain, kind) one delivery at exactly its gasLimit, the Hub's
                                        entry gas (parity trace) and F; with --cron, the RC's live Cron100 forward
                                        (Lasna debug trace) against the reservation and the 10% margin rule

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
        raise SystemExit(redact(f'loops: cast {a[0]} failed: {(r.stderr or r.stdout).strip()[-300:]}'))
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
        # nothing reached the Hub before b (every delivery emits a Hub event), and the named tx is a delivery from
        # the callback proxy (s6 tools r2 m-1, m-2)
        prior = logs(ch, h, fb + 1, b - 1, '') if b - 1 > fb else []
        if prior:
            raise SystemExit(f'loops: {ch}: {len(prior)} Hub logs before the first balance step at {b}')
        txs = sorted({x['transactionHash'] for x in ev})
        tos = {t: json.loads(cast('tx', '--json', t, rpc=rpc(ch)))['to'].lower() for t in txs}
        if any(v != CH[ch]['proxy'].lower() for v in tos.values()):
            raise SystemExit(f'loops: {ch}: block {b} holds a Hub tx not sent by the callback proxy')
        to = tos[l['transactionHash']]
        before, after = bal(b - 1), bal(b)
        debt, res = call('debts(address)(uint256)', b), call('reserves(address)(uint256)', b)
        rows.append({'chain': int(ch), 'hub': h, 'funded': value, 'originTx': f['tx'], 'originBlock': fb,
                     'destTx': l['transactionHash'], 'destTo': to, 'destBlock': b, 'destTopic0': l['topics'][0],
                     'prior_hub_logs': 0, 'deliveries_in_block': txs,  # `charged` covers all of them
                     'balance_before': before, 'balance_after': after, 'charged': before - after,
                     'debt': debt, 'reserves': res, 'pass': before == value and after < before and debt == 0 and res == 0})
    doc = load()
    save(doc, 'L-PAY', rows, 'a Hub with zero reserves and only a balance receives its first callback (any kind): paid '
         'from the balance, debt 0 (spec §12 L-PAY, T-HUB-PAY (c), s2 D1-01)')


# ------------------------------------------------------------------ L-CON-* (spec §9.5; PB-17 loop method)

RC = '0xFbcDba49a040Ca5965377F73bB327F2F2B7DC4c9'
RC_BLOCK = 9199000  # below the RC's creation block on Lasna (audits/deployments-5318007.json step rc)
LASNA = 'https://lasna-rpc.rnk.dev/'
SYSTEM = '0x8888888888888888888888888888888888888888'
T_ACTION = '0x937e001463e9195c691b580d8f14c71c42291e5c57b3311a69422e91310293ba'   # RcBase.T_ACTION
T_APPLIED = '0xce93009ccd5ff6e5058f9aacacf4db6e4bdf49a9fbab795441ddeebee88b1615'  # RcBase.T_APPLIED
T_NOTE = '0x9f0625eae4d628e3bcc8083dac0036f15eb2c98996c115367665517f717810a7'     # RcBase.T_NOTE
T_CALLBACK = '0xef94dbc611c4b95bf4b8ba34b413972180c2faf26fbb480befacedd83e07b133'  # the system's callback request
T_GASSET = '0xb68a848ff7c438a62f8b5b6f266411729435dc2d60e1584fe7570ef90939af0e'  # IReagentRC.GasSet
SEL_CONDUCT = 'a5596b44'  # IReagentHub.rcConduct
TIMEOUT_S = 4 * 3600      # PB-17: undelivered after 4 h counts as ">= timeout"
LASNA_BLOCK_S = 1.13      # spec §6 (Lasna block time), for the absence scan's window only
SPAN = {'1301': 1_000, '11155111': 5_000}  # the public endpoints' eth_getLogs range caps
BLOCKTIME = {'1301': 1, '11155111': 12}
# spec §9.5: L-CON-AA/AB are Actions on X_A, -BA/-BB on X_B (r1 m-04: keyed by the vault, never by the chain)
PATHS = {'XA': ('1301', {'1301': 'L-CON-AA', '11155111': 'L-CON-AB'}),
         'XB': ('11155111', {'1301': 'L-CON-BA', '11155111': 'L-CON-BB'})}


def redact(text):
    for k in ('UNICHAIN_SEPOLIA_RPC_URL', 'ETH_SEPOLIA_RPC_URL'):
        if os.environ.get(k):
            text = text.replace(os.environ[k], f'${k}')
    return text


def logs_chunked(ch, addr, frm, to, topic0, topics=(), stop=None):
    """eth_getLogs in the endpoint's span; `stop(entries)` ends the walk early once it returns true."""
    out = []
    to = min(to, int(cast('block-number', rpc=CH[ch]['logs'])) - 5)
    while frm <= to:
        hi = min(to, frm + SPAN[ch] - 1)
        out += json.loads(cast('logs', '--json', '--from-block', str(frm), '--to-block', str(hi), '--address', addr,
                               topic0, *topics, rpc=CH[ch]['logs']) or '[]')
        if stop and stop(out):
            break
        frm = hi + 1
    return out, to


def words(hexdata):
    d = hexdata[2:] if hexdata.startswith('0x') else hexdata
    return [d[i:i + 64] for i in range(0, len(d), 64)]


def mcp_trace(ch, origin_tx, log_index):
    """The Reactive MCP's trace of ONE origin log (r1 M-01: keyed by tx AND logIndex; the widest scan). A tool error
    or an answer without data is a refusal, never 'no reaction' (r1 B-01)."""
    sys.path.insert(0, os.path.join(ROOT, 'script', 'rnk'))
    from rmcp import call  # noqa: E402
    tr = call('trace_origin_event', {'originChainId': int(ch), 'txHash': origin_tx, 'logIndex': log_index, 'rc': RC,
                                     'maxScanBlocks': 900})
    if not isinstance(tr, dict) or not tr.get('verdict') or not isinstance(tr.get('data'), dict):
        raise SystemExit(f'loops: the MCP trace of {origin_tx}#{log_index} failed or returned no data: refusing')
    return tr


def check_reaction(ch, lasna_tx, origin_tx, log_index, emitter):
    """The Lasna tx's own input (the system's call carrying `react(LogRecord)`) must name this RC, chain, emitter,
    Action topic, origin tx and log index: the attribution rests on Lasna data. Returns the reaction and the rcConduct
    it requested per destination chain (seq, id, gasLimit) from the system's callback-request logs."""
    t = json.loads(cast('tx', '--json', lasna_tx, rpc=LASNA))
    w = words(t['input'][10:])
    want = {'rc': RC[2:].lower().rjust(64, '0'), 'chain': hex(int(ch))[2:].rjust(64, '0'),
            'emitter': emitter[2:].lower().rjust(64, '0'), 'topic0': T_ACTION[2:], 'tx': origin_tx[2:].lower(),
            'logIndex': hex(log_index)[2:].rjust(64, '0')}
    got = {'rc': w[0], 'chain': w[2], 'emitter': w[3], 'topic0': w[4], 'tx': w[12], 'logIndex': w[13]} if len(w) > 13 else {}
    if (t.get('to') or '').lower() != SYSTEM or got != want:
        raise SystemExit(f'loops: the Lasna tx {lasna_tx} is not the RC\'s reaction to {origin_tx}#{log_index}')
    r = json.loads(cast('receipt', '--json', lasna_tx, rpc=LASNA))
    if int(r['status'], 16) != 1:
        raise SystemExit(f'loops: the reaction {lasna_tx} failed')
    sends = {}
    for l in r['logs']:
        if l['address'].lower() != SYSTEM or l['topics'][0] != T_CALLBACK or int(l['topics'][2], 16) != int(RC, 16):
            continue
        d = words(l['data'])
        dest, hub_, gas, plen = str(int(d[4], 16)), '0x' + d[5][-40:], int(d[6], 16), int(d[8], 16)
        payload = ''.join(d[9:])[:2 * plen]
        if payload[:8] != SEL_CONDUCT or plen != 4 + 6 * 32:
            continue
        a = [payload[8 + 64 * i:8 + 64 * (i + 1)] for i in range(6)]
        if dest in sends:
            raise SystemExit(f'loops: two rcConduct to {dest} in {lasna_tx}')
        sends[dest] = {'hub': hub_, 'gasLimit': gas, 'id': int(a[1], 16), 'actions': int(a[4], 16), 'seq': int(a[5], 16)}
    return {'tx': lasna_tx, 'block': int(t['blockNumber'], 16), 'ts': int(t['blockTimestamp'], 16),
            'gasUsed': int(r['gasUsed'], 16), 'sends': sends}


def lasna_scan(ch, origin_tx, log_index, t0):
    """Positive evidence of absence (r1 B-01): every Lasna block from the one at the origin's time to TIMEOUT_S after
    it, every system tx whose LogRecord names this RC and origin (tx, logIndex). Returns the reaction tx or None."""
    b0 = int(cast('find-block', str(t0), rpc=LASNA))
    n = int(TIMEOUT_S / LASNA_BLOCK_S) + 60
    tail = origin_tx[2:].lower(), hex(log_index)[2:].rjust(64, '0'), RC[2:].lower().rjust(64, '0')
    for b in range(b0, b0 + n):
        blk = json.loads(cast('rpc', 'eth_getBlockByNumber', hex(b), 'true', rpc=LASNA)) or {}
        for t in blk.get('transactions', []):
            if (t.get('to') or '').lower() != SYSTEM:
                continue
            w = words(t['input'][10:])
            if len(w) > 13 and (w[12], w[13], w[0]) == tail:
                return t['hash'], (b0, b)
    return None, (b0, b0 + n - 1)


def first_applied(dest, hub_, id_, seq, from_block, ceiling_block):
    """The first `Applied(id, seq')` with seq' >= seq on that Hub from `from_block` (PB-17: a coalesced loop ends at
    the first Applied with seq >= its own), delivered by the callback proxy."""
    hit = lambda es: [e for e in es if int(e['data'], 16) >= seq]  # noqa: E731
    es, upto = logs_chunked(dest, hub_, from_block, ceiling_block, T_APPLIED, ('0x' + hex(id_)[2:].rjust(64, '0'),),
                            stop=lambda es: bool(hit(es)))
    h = hit(es)
    if not h:
        return None, upto
    e = min(h, key=lambda x: (int(x['blockNumber'], 16), int(x['logIndex'], 16)))
    tx = json.loads(cast('tx', '--json', e['transactionHash'], rpc=rpc(dest)))
    if tx['to'].lower() != CH[dest]['proxy'].lower():
        raise SystemExit(f'loops: Applied {e["transactionHash"]} was not delivered by the callback proxy')
    return e, upto


def pct(xs, p):
    xs = sorted(xs)
    return xs[max(0, -(-p * len(xs) // 100) - 1)]  # nearest rank: the ceil(p·n/100)-th value


def median(xs):
    xs = sorted(xs)
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2


def lcon_origins():
    """Driver-recorded Action origins per vault (steps `lcon_<VAULT>_<date>`); a vault with no L-CON path refuses."""
    out = []
    for ch in CH:
        for step, s in deployments(ch).items():
            if not step.startswith('lcon_'):
                continue
            name = step.split('_')[1]
            if name not in PATHS or PATHS[name][0] != ch:
                raise SystemExit(f'loops: {step}: the vault {name} on {ch} has no L-CON path (spec §9.5: X_A, X_B)')
            for o in s['txs']:
                if o.get('status') == 'pending':
                    raise SystemExit(f'loops: {step} {o["tx"]} is still pending: resolve it first')
                if o.get('status') == 'ok':  # a failed origin emitted no Action: not an attempted loop
                    out.append((name, ch, o['tx']))
    return out


def lcon_rows(now):
    rows = {k: [] for _, (_, m) in PATHS.items() for k in m.values()}
    for name, ch, otx in lcon_origins():
        r = json.loads(cast('receipt', '--json', otx, rpc=rpc(ch)))
        acts = [l for l in r['logs'] if l['topics'] and l['topics'][0] == T_ACTION]
        if int(r['status'], 16) != 1 or len(acts) != 1:
            raise SystemExit(f'loops: {otx}: not one landed Action')
        vault, li = acts[0]['address'], int(acts[0]['logIndex'], 16)
        ob = int(r['blockNumber'], 16)
        t0 = ts(ch, ob)
        old = now - t0 > TIMEOUT_S
        tr = mcp_trace(ch, otx, li)
        lx = ((tr['data'].get('reaction') or {}).get('tx'))
        scanned = None
        if not lx:
            if not old:
                raise SystemExit(f'loops: {otx}: no reaction found yet ({tr["verdict"]}); re-run later')
            lx, scanned = lasna_scan(ch, otx, li, t0)
        rx = check_reaction(ch, lx, otx, li, vault) if lx else None
        for dest, key in PATHS[name][1].items():
            row = {'batch': dt.datetime.fromtimestamp(t0, dt.timezone.utc).strftime('%Y-%m-%d'), 'vault': vault.lower(),
                   'originChain': int(ch), 'originTx': otx, 'originBlock': ob, 'logIndex': li, 'originTs': t0,
                   'destChain': int(dest)}
            if rx is None:
                rows[key].append({**row, 'delivered': False, 'destTx': None, 'lasnaScanned': scanned,
                                  'why': f'no reaction on Lasna within {TIMEOUT_S} s (MCP {tr["verdict"]}; scanned)'})
                continue
            row.update(lasnaTx=rx['tx'], lasnaBlock=rx['block'], lasnaTs=rx['ts'], leg_reactive_s=rx['ts'] - t0)
            if dest not in rx['sends']:
                # the RC reacted but sent no snapshot here (its Action budget or a lost Hub): an RC-side throttle,
                # not a delivery loss; the driver should never produce one (r1 m-05)
                raise SystemExit(f'loops: {key} {otx}: the reaction {rx["tx"]} sent no rcConduct to {dest}: investigate')
            snd = rx['sends'][dest]
            if snd['hub'].lower() != hub(dest).lower():
                raise SystemExit(f'loops: {rx["tx"]} sends {dest} to {snd["hub"]}, not the recorded Hub')
            fb = ob if dest == ch else int(cast('find-block', str(t0), rpc=rpc(dest))) - 1
            e, upto = first_applied(dest, hub(dest), snd['id'], snd['seq'], fb, fb + TIMEOUT_S // BLOCKTIME[dest] + 10)
            row.update(curator=snd['id'], seq=snd['seq'], actions=snd['actions'], gasLimit=snd['gasLimit'])
            if e is None:
                if not old:
                    raise SystemExit(f'loops: {key} {otx}: no Applied >= seq {snd["seq"]} yet; re-run later')
                rows[key].append({**row, 'delivered': False, 'destTx': None, 'searchedTo': upto,
                                  'why': f'no Applied >= its seq within {TIMEOUT_S} s'})
                continue
            b = int(e['blockNumber'], 16)
            t1 = ts(dest, b)
            a_seq = int(e['data'], 16)
            rows[key].append({**row, 'delivered': True, 'destTx': e['transactionHash'], 'destBlock': b, 'destTs': t1,
                              'appliedSeq': a_seq, 'coalesced': a_seq > snd['seq'], 'latency_s': t1 - t0,
                              'leg_callback_s': t1 - rx['ts']})
    return rows


def _mm(xs):
    return (median(xs), max(xs)) if xs else (None, None)  # r1 m-02: an empty set is no number, never 0


def lcon_stats(key, rs):
    lat = [r['latency_s'] if r['delivered'] else TIMEOUT_S for r in rs]
    und = sum(1 for r in rs if not r['delivered'])
    batches = {}
    for r in rs:
        batches.setdefault(r['batch'], []).append(r)
    bl = []
    for d, b in sorted(batches.items()):
        e2e = _mm([r['latency_s'] for r in b if r['delivered']])
        rx = _mm([r['leg_reactive_s'] for r in b if r.get('lasnaTx')])
        bl.append({'date': d, 'n': len(b), 'delivered': sum(1 for r in b if r['delivered']), 'e2eMedian': e2e[0],
                   'e2eMax': e2e[1], 'reactiveLegMedian': rx[0], 'reactiveLegMax': rx[1]})
    return {'id': key, 'unit': 's', 'attempted': len(rs), 'delivered': len(rs) - und, 'median': median(lat),
            'p95': pct(lat, 95), 'max': max(lat), 'p95IsLowerBound': und * 20 > len(rs), 'meetsN50': len(rs) >= 50,
            'datedBatches': len(batches), 'meets3Batches': len(batches) >= 3, 'batches': bl,
            'method': 'end-to-end = destination block time - origin block time (both read by RPC); legs unclamped '
                      '(+/-1 s skew); a coalesced loop ends at the first Applied with seq >= its own; undelivered after '
                      '4 h count as 14400 s (p95 a lower bound when > 5% are undelivered); nearest-rank p95; '
                      'Ethereum Sepolia destinations have a one-block (~12 s) floor'}


def lcon():
    rows = lcon_rows(int(dt.datetime.now(dt.timezone.utc).timestamp()))
    doc = load()
    stats = [x for x in doc.get('stats', []) if x.get('id') not in rows]
    for key, rs in rows.items():
        if not rs:
            continue
        save(doc, key, rs, f'{key}: Action on the origin vault (script/live/drive.py) -> the RC reaction on Lasna -> '
             'the first Applied with seq >= its own on the destination Hub (spec §9.5, PB-17)')
        stats.append(lcon_stats(key, rs))
    doc['stats'] = stats
    open(OUT, 'w').write(json.dumps(doc, indent=1) + '\n')
    for x in stats:
        print('loops: stats', {k: x[k] for k in ('id', 'attempted', 'delivered', 'median', 'p95', 'max')})


# ------------------------------------------------------------------ L-GAS (spec §9.5, §5.6; OQ-19; §5.5 the reservation)

KIND_SEL = {'a5596b44': 'conduct', 'fe0faba3': 'vault', 'a084332b': 'budget', '0be444a4': 'exit', 'ae7a4572': 'plan'}
KINDS = ('conduct', 'vault', 'budget', 'exit', 'plan')
SEL_REACT = '0x0d152c2c'
T_CRON100 = '0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70'  # RcBase.T_CRON100
TRACE = {'1301': 'https://unichain-sepolia-rpc.publicnode.com', '11155111': 'https://ethereum-sepolia-rpc.publicnode.com'}
MODELLED_FORWARD = 749_597  # test/base/RcEnv.sol reactGasFor (spec §5.5)
DEFERRED = 5                # Outcome.DEFERRED (src/interfaces/IReagent.sol)


def rc_gas_table():
    """gasLimit(chain, kind) = ceil(1.1 (NEED·64/63 + RESERVE) · 64/63) + F[chain] from the NEED constants in
    src/RcBase.sol (spec §5.6); `lgas` refuses if the RC owner ever called setGas (a `GasSet` log on Lasna)."""
    import re
    src = open(os.path.join(ROOT, 'src', 'RcBase.sol')).read()
    k = lambda n: int(re.search(rf'\b{n}\s*=\s*([\d_]+)', src)[1].replace('_', ''))  # noqa: E731
    out = {}
    for ch in CH:
        f = k(f'F_{ch}')
        for kind in KINDS:
            need = k(f'NEED_{kind.upper()}_{ch}')
            num = 11 * (need * 64 + 40_000 * 63) * 64  # 1.1 · (NEED·64/63 + RESERVE) · 64/63, as an exact fraction
            out[(ch, kind)] = {'need': need, 'F': f, 'gasLimit': -(-num // (10 * 63 * 63)) + f}
    return out


def gas_set_logs():
    return json.loads(cast('logs', '--json', '--from-block', str(RC_BLOCK), '--to-block', 'latest', '--address', RC,
                           T_GASSET, rpc=LASNA) or '[]')


def hub_entry(ch, tx):
    """The gas the callback proxy forwarded into the Hub (the first call frame whose callee is the Hub with a
    callback selector), from a parity `trace_transaction`; the kind is that frame's selector."""
    tr = json.loads(cast('rpc', 'trace_transaction', tx, rpc=TRACE[ch]))
    h = hub(ch).lower()
    fr = [f for f in tr if (f['action'].get('to') or '').lower() == h and f['action'].get('callType') == 'call'
          and f['action']['input'][2:10] in KIND_SEL]
    if not fr:
        raise SystemExit(f'loops: {ch} {tx}: no callback frame into the Hub')
    f = fr[0]
    return KIND_SEL[f['action']['input'][2:10]], int(f['action']['gas'], 16), f.get('error')


def deferred_note(ch, tx, kind):
    """For exit and plan: the Hub's EXIT/PLAN note in the delivery says DEFERRED (the pre-check refused: entry gas
    at the threshold is not gasleft at the check; r1 m-03)."""
    if kind not in ('exit', 'plan'):
        return False
    r = json.loads(cast('receipt', '--json', tx, rpc=rpc(ch)))
    for l in r['logs']:
        if l['address'].lower() == hub(ch).lower() and l['topics'][0] == T_NOTE:
            w = words(l['data'])[2:]  # abi.encode(bytes): offset, length, then the note's own words
            outcome = int(w[1], 16) if kind == 'exit' else int(w[2], 16)
            if outcome == DEFERRED:
                return True
    return False


def cron_reactions(frm, to):
    """The RC's Cron100 reactions on Lasna in [frm, to]: system txs whose LogRecord names this RC and topic0 =
    Cron100 (a Cron event is every 100 blocks; its reaction lands a block or more after it)."""
    found = []
    for base in range(frm - frm % 100, to + 1, 100):
        for b in range(base + 1, base + 8):
            blk = json.loads(cast('rpc', 'eth_getBlockByNumber', hex(b), 'true', rpc=LASNA)) or {}
            for t in blk.get('transactions', []):
                w = words(t['input'][10:]) if (t.get('to') or '').lower() == SYSTEM else []
                if len(w) > 13 and w[0] == RC[2:].lower().rjust(64, '0') and w[4] == T_CRON100[2:]:
                    found.append(t['hash'])
    return found


def react_forward(tx):
    tr = json.loads(cast('rpc', 'debug_traceTransaction', tx, '{"tracer":"callTracer"}', rpc=LASNA))
    out = []

    def walk(f):
        if (f.get('to') or '').lower() == RC.lower() and f['input'][:10] == SEL_REACT:
            out.append(int(f['gas'], 16))
        for c in f.get('calls', []):
            walk(c)
    walk(tr)
    if len(out) != 1:
        raise SystemExit(f'loops: {tx}: {len(out)} react frames')
    return out[0]


def margin_ok(lhs, live):
    """spec §5.5 (rc-fix r3 C3-04): the exact reservation leaves >= 10% of the live Cron forward to spare."""
    return lhs * 10 <= live * 9


def lgas_rows(cron_range=None):
    if gas_set_logs():
        raise SystemExit('loops: the RC owner called setGas: the formula table is not the live limit; refusing')
    table = rc_gas_table()
    cand = {ch: [] for ch in CH}
    for e in load().get('loops', []):
        dc = str(e.get('destChain', e.get('chain')))
        if e.get('destTx') and dc in CH:
            cand[dc].append(e['destTx'])
    for ch in CH:
        for step, s in deployments(ch).items():
            if step.startswith('lgas_'):
                cand[ch] += [t['tx'] for t in s['txs'] if t.get('status') == 'ok']
    rows, seen = [], set()
    for ch in CH:
        for tx in dict.fromkeys(cand[ch]):
            t = json.loads(cast('tx', '--json', tx, rpc=rpc(ch)))
            if t['to'].lower() != CH[ch]['proxy'].lower():
                continue
            kind, entry, err = hub_entry(ch, tx)
            if (ch, kind) in seen:
                continue
            seen.add((ch, kind))
            want = table[(ch, kind)]
            gas, thr = int(t['gas'], 16), want['need'] * 64 / 63 + 40_000
            dfr = deferred_note(ch, tx, kind)
            rows.append({'chain': int(ch), 'kind': kind, 'destTx': tx, 'txGas': gas, 'gasLimit': want['gasLimit'],
                         'atGasLimit': gas == want['gasLimit'], 'need': want['need'], 'entryGas': entry,
                         'F_measured': gas - entry * 64 / 63, 'F_spec': want['F'],
                         'calldataBytes': (len(t['input']) - 2) // 2, 'hubFrameError': err, 'precheck': thr,
                         'entryCoversPrecheck': entry >= thr, 'deferred': dfr,
                         'pass': gas == want['gasLimit'] and not err and entry >= thr and not dfr})
    cron = None
    if cron_range:
        txs = cron_reactions(*cron_range)
        if not txs:
            raise SystemExit(f'loops: no Cron100 reaction of the RC in Lasna blocks {cron_range}')
        fwd = [{'lasnaTx': x, 'forward': react_forward(x)} for x in txs]
        rg = json.load(open(os.path.join(ROOT, 'audits', 'rc-gas.json')))
        lhs = max(c['lhs'] for c in rg['cells'].values())
        live = min(f['forward'] for f in fwd)
        cron = {'kind': 'cronForward', 'reactions': fwd, 'liveForwardMin': live, 'modelledForward': MODELLED_FORWARD,
                'reservationLhsMax': lhs, 'marginRule': 'lhs <= 0.9 x the live Cron forward (spec §5.5, C3-04)',
                'liveAtLeastModelled': live >= MODELLED_FORWARD, 'pass': margin_ok(lhs, live),
                'originTx': txs[0], 'destTx': txs[0]}
    return rows, cron


def lgas_key(rows, cron):
    """`L-GAS` only when every (chain, kind) cell and the Cron forward are recorded and pass; else `L-GAS-partial`,
    which no claim cites (r1 M-02)."""
    cells = {(str(r['chain']), r['kind']) for r in rows if r.get('pass')}
    complete = all((c, k) in cells for c in CH for k in KINDS) and bool(cron and cron['pass'])
    missing = [f'{c}/{k}' for c in CH for k in KINDS if (c, k) not in cells] + ([] if cron and cron['pass'] else ['cron'])
    return ('L-GAS' if complete else 'L-GAS-partial'), missing


def lgas():
    """Per (chain, kind): one delivery at exactly its gasLimit (the tx gas = the formula's limit), the Hub's entry
    gas and F = gasLimit − entry·64/63 (OQ-19). With `--cron FROM TO` (Lasna blocks): the RC's live Cron forward
    against the reservation of audits/rc-gas.json and the 10% margin rule."""
    rng = None
    if '--cron' in sys.argv:
        i = sys.argv.index('--cron')
        rng = (int(sys.argv[i + 1]), int(sys.argv[i + 2]))
    rows, cron = lgas_rows(rng)
    if cron:
        rows.append(cron)
    key, missing = lgas_key(rows[:-1] if cron else rows, cron)
    doc = load()
    doc['loops'] = [e for e in doc.get('loops', []) if e.get('id') not in ('L-GAS', 'L-GAS-partial')]
    save(doc, key, rows, 'one delivery per (chain, kind) at exactly its gasLimit; the Hub entry gas from a parity '
         f'trace; F = gasLimit - entry*64/63 (spec §5.6, OQ-19); missing or failing: {missing or "none"}')
    for r in rows:
        print('loops:', key, {k: r.get(k) for k in ('chain', 'kind', 'txGas', 'entryGas', 'F_measured', 'pass',
                                                    'liveForwardMin', 'reservationLhsMax')})
    if cron and not cron['pass']:
        raise SystemExit('loops: L-GAS: the live Cron forward FAILS the 10% margin rule: STOP and escalate (handoff §6 2)')

# ------------------------------------------------------------------ selftest (offline: the seams replaced; s7 r1 M-03)

def selftest():
    g = globals()
    fails = []
    names = ('cast', 'lcon_origins', 'mcp_trace', 'lasna_scan', 'check_reaction', 'first_applied', 'ts', 'hub',
             'logs_chunked', 'load', 'deployments', 'rpc')
    saved = {k: g[k] for k in names}
    g['rpc'] = lambda ch: 'http://selftest.invalid'  # no network: every chain read goes through a replaced seam

    def ok(cond, label):
        print(('selftest ok: ' if cond else 'selftest FAIL: ') + label)
        if not cond:
            fails.append(label)

    def refuses(fn, must, label):
        try:
            fn()
        except SystemExit as e:
            ok(must in str(e), f'{label} (refused: {"its own reason" if must in str(e) else e})')
            return
        ok(False, f'{label} (not refused)')

    H = '0x' + 'ab' * 20
    try:
        # A. the statistics
        ok(pct(list(range(1, 21)), 95) == 19, 'nearest-rank p95 of 1..20 is the 19th value')
        ok(pct([5], 95) == 5 and median([1, 2, 3, 4]) == 2.5 and median([3, 1, 2]) == 2, 'p95 of one, medians')
        mk = lambda d, lat=10: {'batch': '2026-11-25', 'delivered': d, 'latency_s': lat if d else None,  # noqa: E731
                                'leg_reactive_s': 1, 'lasnaTx': '0x1' if d else None}
        s1 = lcon_stats('X', [mk(True)] * 19 + [mk(False)])
        s2 = lcon_stats('X', [mk(True)] * 18 + [mk(False)] * 2)
        ok(not s1['p95IsLowerBound'] and s2['p95IsLowerBound'], 'p95 is a lower bound only above 5% undelivered (1/20 no, 2/20 yes)')
        s3 = lcon_stats('X', [mk(False)])
        ok(s3['batches'][0]['e2eMedian'] is None and s3['batches'][0]['reactiveLegMax'] is None,
           'a batch with no deliveries reports no number, never 0 (r1 m-02)')
        ok(lcon_stats('X', [mk(True)])['meets3Batches'] is False, 'one dated batch does not meet the 3-batch rule')
        # B. the margin rule at its boundary
        ok(margin_ok(900, 1000) and not margin_ok(901, 1000), 'margin rule: lhs = 0.9 x live passes, +1 fails')
        # C. lgas_key
        allc = [{'chain': int(c), 'kind': k, 'pass': True} for c in CH for k in KINDS]
        ok(lgas_key(allc, {'pass': True})[0] == 'L-GAS', 'all ten cells and the Cron forward pass -> L-GAS')
        ok(lgas_key(allc[:-1], {'pass': True})[0] == 'L-GAS-partial', 'nine cells -> L-GAS-partial (r1 M-02)')
        ok(lgas_key(allc, {'pass': False})[0] == 'L-GAS-partial', 'a failing Cron forward -> L-GAS-partial')
        ok(lgas_key(allc, None)[0] == 'L-GAS-partial', 'no Cron forward -> L-GAS-partial')
        ok(lgas_key(allc[:-1] + [{**allc[-1], 'pass': False}], {'pass': True})[0] == 'L-GAS-partial',
           'a failing cell -> L-GAS-partial')
        # D. first_applied: seq filter and the proxy check
        ap = lambda seq, b: {'data': hex(seq), 'blockNumber': hex(b), 'logIndex': '0x0', 'transactionHash': f'0x{b}'}  # noqa: E731
        g['logs_chunked'] = lambda *a, **k: ([ap(3, 10), ap(5, 11), ap(6, 12)], 99)
        g['cast'] = lambda *a, rpc: json.dumps({'to': CH['1301']['proxy']})
        e, _ = first_applied('1301', H, 1, 5, 0, 100)
        ok(e['transactionHash'] == '0x11', 'the first Applied with seq >= its own (an older seq never counts)')
        e, _ = first_applied('1301', H, 1, 7, 0, 100)
        ok(e is None, 'no Applied >= seq -> none')
        g['cast'] = lambda *a, rpc: json.dumps({'to': H})
        refuses(lambda: first_applied('1301', H, 1, 5, 0, 100), 'not delivered by the callback proxy',
                'an Applied not sent by the callback proxy')
        # E. check_reaction: the Lasna input must name this origin (tx, logIndex)
        otx = '0x' + 'cd' * 32
        inp = lambda li: '0x0d0d0d0d' + ''.join([RC[2:].lower().rjust(64, '0'), '0' * 62 + '40', hex(1301)[2:].rjust(64, '0'),  # noqa: E731
                                                 H[2:].rjust(64, '0'), T_ACTION[2:]] + ['0' * 64] * 7 + [otx[2:], hex(li)[2:].rjust(64, '0')])
        rc_ok = {'tx': json.dumps({'to': SYSTEM, 'input': inp(7), 'blockNumber': '0x5', 'blockTimestamp': '0x64'}),
                 'receipt': json.dumps({'status': '0x1', 'gasUsed': '0x1', 'logs': []})}
        g['cast'] = lambda *a, rpc: rc_ok[a[0]]
        ok(saved['check_reaction']('1301', '0xL', otx, 7, H)['ts'] == 100, 'control: the matching reaction is accepted')
        refuses(lambda: saved['check_reaction']('1301', '0xL', otx, 8, H), 'is not the RC\'s reaction',
                'a reaction to another log of the same tx (logIndex differs)')
        # F. mcp_trace: an error or an empty answer refuses; it is keyed by logIndex
        sys.path.insert(0, os.path.join(ROOT, 'script', 'rnk'))
        import rmcp
        real_call, seen = rmcp.call, {}
        try:
            rmcp.call = lambda tool, args: seen.update(args) or {'text': 'error'}
            refuses(lambda: saved['mcp_trace']('1301', otx, 7), 'returned no data', 'an MCP tool error')
            ok(seen.get('logIndex') == 7 and seen.get('maxScanBlocks') == 900, 'the MCP trace is keyed by logIndex (r1 M-01)')
            rmcp.call = lambda tool, args: {'verdict': 'X', 'data': None}
            refuses(lambda: saved['mcp_trace']('1301', otx, 7), 'returned no data', 'an MCP answer without data')
        finally:
            rmcp.call = real_call
        # G. lcon_rows: the reaction lookup's branches
        T0, NOW_OLD, NOW_NEW = 1_000_000, 1_000_000 + TIMEOUT_S + 1, 1_000_000 + 60
        g['lcon_origins'] = lambda: [('XA', '1301', otx)]
        g['ts'] = lambda ch, b: T0 if b == 10 else T0 + 30
        g['hub'] = lambda ch: H
        rec = json.dumps({'status': '0x1', 'blockNumber': '0xa', 'logs': [{'topics': [T_ACTION], 'address': H, 'logIndex': '0x7'}]})
        g['cast'] = lambda *a, rpc: rec if a[0] == 'receipt' else '20'
        react = {'tx': '0xL', 'block': 5, 'ts': T0 + 2, 'gasUsed': 1,
                 'sends': {c: {'hub': H, 'gasLimit': 1, 'id': 1, 'actions': 1, 'seq': 4} for c in CH}}
        g['check_reaction'] = lambda *a: react
        g['first_applied'] = lambda dest, h, i, s, f, c: (ap(5, 40), 40)
        g['mcp_trace'] = lambda *a: {'verdict': 'REACTED', 'data': {'reaction': {'tx': '0xL'}}}
        rows = lcon_rows(NOW_NEW)
        r = rows['L-CON-AA'][0]
        ok(r['delivered'] and r['latency_s'] == 30 and r['coalesced'] and r['leg_reactive_s'] == 2,
           'control: a delivered loop (latency, coalesced seq 5 >= 4, Reactive leg)')
        g['mcp_trace'] = lambda *a: {'verdict': 'NOT_FOUND', 'data': {}}
        refuses(lambda: lcon_rows(NOW_NEW), 're-run later', 'no reaction found inside 4 h: refused, not undelivered')
        g['lasna_scan'] = lambda *a: (None, (1, 2))
        rows = lcon_rows(NOW_OLD)
        ok(not rows['L-CON-AA'][0]['delivered'] and 'no reaction on Lasna' in rows['L-CON-AA'][0]['why'],
           'no reaction after 4 h AND none in the Lasna scan: undelivered (positive evidence, r1 B-01)')
        g['lasna_scan'] = lambda *a: ('0xL', (1, 2))
        ok(lcon_rows(NOW_OLD)['L-CON-AA'][0]['delivered'], 'the MCP misses it but the Lasna scan finds it: delivered')
        g['mcp_trace'] = lambda *a: {'verdict': 'REACTED', 'data': {'reaction': {'tx': '0xL'}}}
        react['sends'] = {'11155111': react['sends']['11155111']}
        refuses(lambda: lcon_rows(NOW_NEW), 'sent no rcConduct', 'a reaction with no snapshot to a destination (r1 m-05)')
        # H. lcon_origins: only X_A / X_B paths; pending refuses
        g['deployments'] = lambda ch: {'lcon_YA_20261125': {'txs': [{'tx': otx, 'status': 'ok'}]}} if ch == '1301' else {}
        refuses(lambda: saved['lcon_origins'](), 'has no L-CON path', 'a Y_A step folded into L-CON-AA (r1 m-04)')
        g['deployments'] = lambda ch: {'lcon_XA_20261125': {'txs': [{'tx': otx, 'status': 'pending'}]}} if ch == '1301' else {}
        refuses(lambda: saved['lcon_origins'](), 'still pending', 'a pending origin')
        g['deployments'] = lambda ch: {'lcon_XA_20261125': {'txs': [{'tx': otx, 'status': 'ok'}, {'tx': '0x2', 'status': 'FAILED'}]}} if ch == '1301' else {}
        ok(saved['lcon_origins']() == [('XA', '1301', otx)], 'control: X_A origins collected, failed sends skipped')
    finally:
        g.update(saved)
    print('loops selftest', 'OK' if not fails else f'FAIL ({len(fails)})')
    return not fails


if __name__ == '__main__':
    what = sys.argv[1] if len(sys.argv) > 1 else ''
    if what == '--selftest':
        sys.exit(0 if selftest() else 1)
    cmds = {'ldyn': ldyn, 'lpay': lpay, 'lcon': lcon, 'lgas': lgas}
    if what not in cmds:
        raise SystemExit(__doc__)
    cmds[what]()
