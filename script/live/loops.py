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
import json, os, subprocess, sys, time, datetime as dt

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


# The MCP's verdicts for a log no subscription carried, as recorded on 2026-11-25 for an unsubscribed 1301 Transfer
# (0x4a79…b2 log 0): verdict FILTER_MISMATCH, finding SEQUENCED_NOT_CARRIED (s7 loops r3 m-03).
NOT_CARRIED = ('FILTER_MISMATCH', 'SEQUENCED_NOT_CARRIED')


def not_carried(tr):
    vs = [tr.get('verdict')] + [f.get('verdict') for f in tr.get('findings', []) if isinstance(f, dict)]
    return any(v in NOT_CARRIED for v in vs)


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


def lasna_block_at(t):
    """The first Lasna block with timestamp >= t, by bisection from RC_BLOCK (the RC's creation era): the node is
    pruned, so `cast find-block` (which starts at block 1) fails there (s7: found by r2 m-01's live control)."""
    lo, hi = RC_BLOCK, int(cast('block-number', rpc=LASNA))
    bt = lambda b: int(cast('block', str(b), '--field', 'timestamp', rpc=LASNA))  # noqa: E731
    if bt(lo) >= t:
        raise SystemExit(f'loops: {t} precedes Lasna block {lo}: outside the RC era')
    while hi - lo > 1:
        mid = (lo + hi) // 2
        lo, hi = (mid, hi) if bt(mid) < t else (lo, mid)
    return hi


def lasna_scan(ch, origin_tx, log_index, t0):
    """Positive evidence of absence (r1 B-01): every Lasna block from the one at the origin's time to TIMEOUT_S after
    it, every system tx whose LogRecord names this RC and origin (tx, logIndex). Returns the reaction tx or None.
    Cost: one block read per Lasna block (~0.3 s each): a full 4 h miss reads ~12.7k blocks (about an hour); it runs
    only for a loop older than 4 h that the MCP cannot place."""
    b = b0 = lasna_block_at(t0)
    tail = origin_tx[2:].lower(), hex(log_index)[2:].rjust(64, '0'), RC[2:].lower().rjust(64, '0')
    while True:  # every block until one is past t0 + TIMEOUT_S (r2 m-01: coverage by timestamp, not by a count)
        blk = json.loads(cast('rpc', 'eth_getBlockByNumber', hex(b), 'true', rpc=LASNA) or 'null')
        if not blk:
            raise SystemExit(f'loops: Lasna block {b} not served: the absence scan cannot conclude')
        for t in blk.get('transactions', []):
            if (t.get('to') or '').lower() != SYSTEM:
                continue
            w = words(t['input'][10:])
            if len(w) > 13 and (w[12], w[13], w[0]) == tail:
                return t['hash'], (b0, b)
        if int(blk['timestamp'], 16) > t0 + TIMEOUT_S:
            return None, (b0, b)
        b += 1


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
        if not lx and not_carried(tr):
            raise SystemExit(f'loops: {otx}: the MCP says the log was not carried ({tr["verdict"]}): no attempted '
                             'loop (the subscription was not in effect at the origin); investigate')
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
                if ts(dest, upto) < t0 + TIMEOUT_S:
                    raise SystemExit(f'loops: {key} {otx}: the search reached block {upto}, short of 4 h; re-run later')
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
            'pass': len(rs) >= 50 and len(batches) >= 3,  # PB-17's gate (r2 M-01); claims.py reads it
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
    h = hub(ch).lower()
    tr, last, src = None, '', 'parity trace_transaction (publicnode)'
    for i in range(5):  # publicnode load-balances across nodes, some without trace_ (seen s7): a bounded retry
        try:
            tr = json.loads(cast('rpc', 'trace_transaction', tx, rpc=TRACE[ch]))
            break
        except SystemExit as e:
            last = str(e)
            if 'insufficient changesets' in last or 'pruned' in last.lower():
                break
            if 'not available' not in last and 'does not exist' not in last:
                raise  # a real error (a wrong tx, a bad answer) is never retried away (lcron r1 m-03)
            time.sleep(2 * (i + 1))
    if tr is None:
        if ch != '1301':
            raise SystemExit(f'loops: {ch} {tx}: no trace_transaction after retries; last: {last[-200:]}')
        src = 'callTracer (drpc)'
        # the 1301 publicnode keeps ~10k blocks of state; drpc's callTracer serves older 1301 deliveries (same frame)
        ct = json.loads(cast('rpc', 'debug_traceTransaction', tx, '{"tracer":"callTracer"}', rpc=DEBUG_1301))
        tr = []

        def walk(f):
            tr.append({'action': {'to': f.get('to'), 'callType': (f.get('type') or '').lower(), 'input': f['input'],
                                  'gas': f['gas']}, 'error': f.get('error')})
            for c in f.get('calls', []):
                walk(c)
        walk(ct)
    fr = [f for f in tr if (f['action'].get('to') or '').lower() == h and f['action'].get('callType') == 'call'
          and f['action']['input'][2:10] in KIND_SEL]
    if not fr:
        raise SystemExit(f'loops: {ch} {tx}: no callback frame into the Hub')
    f = fr[0]
    return KIND_SEL[f['action']['input'][2:10]], int(f['action']['gas'], 16), f.get('error'), src


RELAY_FAILED = 6  # Outcome.RELAY_FAILED
T_STALE = '0xefb60aea3ab96907066bbced4f58785ff7b8c28be82924866fc6839082f32530'  # IReagent.Stale(uint8,uint64)
T_BUDGET_APPLIED = '0xf8a6aac26004de219a651c93a920566d656f9282511a6369c7298dc84c2d8823'  # IReagent.BudgetApplied


def callback_outcome(ch, tx, kind):
    """The delivery's own verdict from its receipt: for exit and plan, the Covenant's EXIT/PLAN note outcome
    (r1 m-03: DEFERRED means the pre-check refused; r2 m-03: RELAY_FAILED means the Covenant never ran); for every
    kind, a Hub `Stale` means the payload was refused as old. Returns (ok, outcome)."""
    r = json.loads(cast('receipt', '--json', tx, rpc=rpc(ch)))
    h = hub(ch).lower()
    if any(l['address'].lower() == h and l['topics'][0] == T_STALE for l in r['logs']):
        return False, 'Stale'
    if kind not in ('exit', 'plan'):
        return True, None
    outs = []
    for l in r['logs']:
        if l['address'].lower() == h and l['topics'][0] == T_NOTE and int(l['topics'][3], 16) in (2, 3):
            w = words(l['data'])[2:]  # abi.encode(bytes): offset, length, then the note's own words
            outs.append(int(w[1], 16) if kind == 'exit' else int(w[2], 16))
    if len(outs) != 1:
        return False, f'{len(outs)} outcome notes'
    return outs[0] not in (DEFERRED, RELAY_FAILED), outs[0]


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
        starts = [t['block'] for step, s in deployments(ch).items() if step.startswith('lcron_')
                  for t in s['txs'] if t.get('block')]
        if starts:  # the Hub's callback results since the Covenant path began (budget, exit, plan; r2 m-05)
            for topic in (T_BUDGET_APPLIED, T_NOTE):
                es, _ = logs_chunked(ch, hub(ch), min(starts), 10**12, topic)
                cand[ch] += [e['transactionHash'] for e in es]
    rows, seen = [], set()
    for ch in CH:
        for tx in dict.fromkeys(cand[ch]):
            t = json.loads(cast('tx', '--json', tx, rpc=rpc(ch)))
            if t['to'].lower() != CH[ch]['proxy'].lower():
                continue
            kind, entry, err, src = hub_entry(ch, tx)
            if (ch, kind) in seen:  # the first PASSING delivery per cell (r2 m-03); failing ones stay as rows
                continue
            want = table[(ch, kind)]
            gas, thr = int(t['gas'], 16), want['need'] * 64 / 63 + 40_000
            good, outcome = callback_outcome(ch, tx, kind)
            ok = gas == want['gasLimit'] and not err and entry >= thr and good
            # an exit/plan cell is filled only by a DONE delivery: the Covenant's work ran inside the limit (lcron r1
            # m-02); an EARLY delivery is a valid entry-gas reading and stays as a row
            fills = ok and (kind not in ('exit', 'plan') or outcome == 1)
            if fills:
                seen.add((ch, kind))
            rows.append({'chain': int(ch), 'kind': kind, 'destTx': tx, 'txGas': gas, 'gasLimit': want['gasLimit'],
                         'atGasLimit': gas == want['gasLimit'], 'need': want['need'], 'entryGas': entry,
                         'F_measured': gas - entry * 64 / 63, 'F_spec': want['F'],
                         'calldataBytes': (len(t['input']) - 2) // 2, 'hubFrameError': err, 'precheck': thr,
                         'entryCoversPrecheck': entry >= thr, 'outcome': outcome, 'fillsCell': fills,
                         'traceSource': src, 'pass': ok})
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
    cells = {(str(r['chain']), r['kind']) for r in rows if r.get('pass') and r.get('fillsCell', True)}
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
    key, missing = lgas_key(rows, cron)
    failing = [r for r in rows if not r.get('pass')]
    rows = [r for r in rows if r.get('pass')] + ([cron] if cron else [])
    doc = load()
    doc['loops'] = [e for e in doc.get('loops', []) if e.get('id') not in ('L-GAS', 'L-GAS-partial', 'L-GAS-failing')]
    if failing:  # kept as evidence under their own key, never inside the claimed ID (s7 loops r3 m-01)
        save(doc, 'L-GAS-failing', failing, 'deliveries that failed their L-GAS cell (kept, not claimed)')
    save(doc, key, rows, 'one delivery per (chain, kind) at exactly its gasLimit; the Hub entry gas from a parity '
         f'trace; F = gasLimit - entry*64/63 (spec §5.6, OQ-19); missing or failing: {missing or "none"}')
    for r in rows:
        print('loops:', key, {k: r.get(k) for k in ('chain', 'kind', 'txGas', 'entryGas', 'F_measured', 'pass',
                                                    'liveForwardMin', 'reservationLhsMax')})
    if cron and not cron['pass']:
        raise SystemExit('loops: L-GAS: the live Cron forward FAILS the 10% margin rule: STOP and escalate (handoff §6 2)')

# ------------------------------------------------------------------ L-SPOOF (spec §9.5, OQ-18, PB-12)

SPOOF_WINDOW_BLOCKS = 1800  # 1301 blocks (~1 s each) searched after the 1301 block at the Lasna reaction's time
NOT_RC = '0x1cac49a3'  # ReagentHub.NotRc()
OPERATOR_1301 = '0xf9f61c1d3325e2d4abb55dd9e0db84f7a0d914b0'  # the 1301 deliveries' sender (L-PAY / L-CON receipts)
DEBUG_1301 = 'https://unichain-sepolia.drpc.org'  # debug_traceTransaction (callTracer) on 1301


def mcp_trace_rc(ch, origin_tx, log_index, rc_addr):
    sys.path.insert(0, os.path.join(ROOT, 'script', 'rnk'))
    from rmcp import call  # noqa: E402
    tr = call('trace_origin_event', {'originChainId': int(ch), 'txHash': origin_tx, 'logIndex': log_index,
                                     'rc': rc_addr, 'maxScanBlocks': 900})
    if not isinstance(tr, dict) or not tr.get('verdict') or not isinstance(tr.get('data'), dict):
        raise SystemExit(f'loops: the MCP trace of {origin_tx}#{log_index} failed or returned no data: refusing')
    return tr


def spoof_delivery(spoof, b0):
    """The 1301 delivery of SpoofRC's callback: from the operator, to the callback proxy, its calldata carrying the
    rcConduct payload whose first word is SpoofRC (the injected word: `SEL_CONDUCT ++ word`, not a bare substring, so a
    decoy tx with the address elsewhere is skipped; s7 lspoof r1 m-03)."""
    proxy, needle = CH['1301']['proxy'].lower(), SEL_CONDUCT + spoof[2:].lower().rjust(64, '0')
    for b in range(b0, b0 + SPOOF_WINDOW_BLOCKS):
        blk = json.loads(cast('rpc', 'eth_getBlockByNumber', hex(b), 'true', rpc=rpc('1301')) or 'null')
        if not blk:
            raise SystemExit(f'loops: 1301 block {b} not served yet; re-run later')
        for x in blk['transactions']:
            if ((x.get('to') or '').lower() == proxy and (x.get('from') or '').lower() == OPERATOR_1301
                    and needle in x['input'].lower()):
                return x, blk
    raise SystemExit(f'loops: no 1301 delivery carrying the spoof RC within {SPOOF_WINDOW_BLOCKS} blocks')


def hub_frames(tx, h):
    ct = json.loads(cast('rpc', 'debug_traceTransaction', tx, '{"tracer":"callTracer"}', rpc=DEBUG_1301))
    out = []

    def walk(f):
        if (f.get('to') or '').lower() == h.lower() and f.get('type') == 'CALL' and f['input'][2:10] == SEL_CONDUCT:
            out.append(f)
        for c in f.get('calls', []):
            walk(c)
    walk(ct)
    return out


def spoof_verdict(row, frames, word, blk_txs, h, found_hash):
    """`pass` = the Hub rejected it: exactly one Hub rcConduct frame, carrying SpoofRC as word 0, reverted with
    NotRc(); no Hub log; conduct(99) read and all zero. `charged` is published only when the delivery is the block's
    only tx touching the Hub or the proxy (else the balance step is not this delivery's alone; lspoof r1 m-01)."""
    row['hubFrame'] = {'error': frames[0].get('error'), 'output': frames[0].get('output')} if len(frames) == 1 else None
    row['word0IsSpoofRC'] = len(frames) == 1 and frames[0]['input'][10:74].lower() == word
    row['rejectedNotRc'] = len(frames) == 1 and bool(frames[0].get('error')) and \
        (frames[0].get('output') or '')[:10] == NOT_RC
    c99 = row.get('conduct99')
    row['pass'] = (row['hubLogs'] == 0 and bool(c99) and all(v == 0 for v in c99) and row['word0IsSpoofRC']
                   and row['rejectedNotRc'])
    proxy = CH['1301']['proxy'].lower()
    others = [x for x in blk_txs if x['hash'] != found_hash and (x.get('to') or '').lower() in (proxy, h.lower())]
    row['otherHubOrProxyTxsInBlock'] = len(others)
    row['chargeAttributable'] = not others
    delta = (row['hubBalanceBefore'] - row['hubBalanceAfter']) + (row['reservesBefore'] - row['reservesAfter']) \
        + (row['debtAfter'] - row['debtBefore'])
    row['charged'] = delta if row['chargeAttributable'] else None
    row['billed'] = (delta > 0) if row['chargeAttributable'] else None
    return row


def lspoof():
    """The third-party RC's (script/live/SpoofRC.sol, from the owner key; `lspoof` in deployments-5318007) single
    rcConduct to the 1301 Hub: trigger (`lspoof_<date>` on 1301) → SpoofRC's reaction on Lasna (MCP, checked against
    its LogRecord) → the 1301 delivery → the verdict and the charge (OQ-18, PB-12)."""
    sp = json.load(open(os.path.join(ROOT, 'audits', 'deployments-5318007.json')))['steps'].get('lspoof')
    if not sp or sp['txs'][0].get('status') != 'ok':
        raise SystemExit('loops: no landed lspoof step: the spoof RC is not deployed')
    spoof = sp['txs'][0]['address']
    trig = [t for step, s in deployments('1301').items() if step.startswith('lspoof_') for t in s['txs']
            if t.get('status') == 'ok']
    if len(trig) != 1:
        raise SystemExit(f'loops: {len(trig)} spoof triggers recorded (want exactly one)')
    otx = trig[0]['tx']
    tr = mcp_trace_rc('1301', otx, trig[0]['logIndex'], spoof)
    lx = (tr['data'].get('reaction') or {}).get('tx')
    if not lx:
        raise SystemExit(f'loops: no reaction of the spoof RC yet ({tr["verdict"]}); re-run later')
    t = json.loads(cast('tx', '--json', lx, rpc=LASNA))
    w = words(t['input'][10:])
    word = spoof[2:].lower().rjust(64, '0')
    if (t.get('to') or '').lower() != SYSTEM or w[0] != word or w[12] != otx[2:].lower():
        raise SystemExit(f'loops: {lx} is not the spoof RC\'s reaction to {otx}')
    b0 = int(cast('find-block', str(int(t['blockTimestamp'], 16)), rpc=rpc('1301'))) - 2
    found, blk = spoof_delivery(spoof, b0)
    db, h = int(found['blockNumber'], 16), hub('1301')
    r = json.loads(cast('receipt', '--json', found['hash'], rpc=rpc('1301')))
    pc = lambda sig, b: int(cast('call', '--block', str(b), CH['1301']['proxy'], sig, h, rpc=rpc('1301')).split()[0])  # noqa: E731
    bal = lambda b: int(cast('balance', '--block', str(b), h, rpc=rpc('1301')))  # noqa: E731
    c99 = cast('call', h, 'conduct(uint32)(uint32,uint32,uint32,uint64)', '99', rpc=rpc('1301')).split()
    row = {'spoofRC': spoof, 'originTx': otx, 'lasnaTx': lx, 'destTx': found['hash'], 'destBlock': db,
           'destStatus': int(r['status'], 16), 'destGasUsed': int(r['gasUsed'], 16),
           'hubLogs': sum(1 for l in r['logs'] if l['address'].lower() == h.lower()),
           'proxyLogs': [{'topic0': l['topics'][0], 'data': l['data']} for l in r['logs']
                         if l['address'].lower() == CH['1301']['proxy'].lower()],
           'conduct99': [int(x) for x in c99[:4]] if len(c99) >= 4 else None,
           'hubBalanceBefore': bal(db - 1), 'hubBalanceAfter': bal(db),
           'debtBefore': pc('debts(address)(uint256)', db - 1), 'debtAfter': pc('debts(address)(uint256)', db),
           'reservesBefore': pc('reserves(address)(uint256)', db - 1), 'reservesAfter': pc('reserves(address)(uint256)', db),
           'snapshotAtTrigger': trig[0].get('hubSnapshot')}
    row = spoof_verdict(row, hub_frames(found['hash'], h), word, blk['transactions'], h, found['hash'])
    doc = load()
    note = ('a third-party RC\'s rcConduct to the 1301 Hub: ' + ('rejected (NotRc, word 0 = the third party, no Hub log, '
            'conduct(99) zero)' if row['pass'] else 'NOT shown rejected: see the row') + '; the charge ' +
            (f'{row["charged"]} wei (billed: {row["billed"]})' if row['chargeAttributable'] else 'not attributable '
             '(other Hub/proxy txs in the block)') + ' (OQ-18, PB-12)')
    save(doc, 'L-SPOOF', [row], note)
    print('loops: L-SPOOF', {k: row[k] for k in ('destStatus', 'rejectedNotRc', 'charged', 'billed', 'pass')})


# ------------------------------------------------------------------ L-CRON (spec §9.5, C-10, §5.5 the Cron gate)

T_MODE = '0x73f069d8a008c9e2fe78e308751100d873455f99593c7d60eff545e91a90ab04'  # RcBase.T_MODE
SEL_SUB, SEL_UNSUB = '5a6aced0', '2f807336'  # IRnkSystem.subscribe / unsubscribe (six arguments)
CRON_ARGS = [hex(5318007)[2:].rjust(64, '0'), '0' * 58 + 'ffffff', T_CRON100[2:],
             'a65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad'] + \
            ['a65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad'] * 2  # (LASNA, CRON, T_CRON100, IGNORE x3)


def rc_subscriptions():
    sys.path.insert(0, os.path.join(ROOT, 'script', 'rnk'))
    from rmcp import call  # noqa: E402
    d = call('list_subscriptions', {'rc': RC, 'lookbackBlocks': 200000})
    if not isinstance(d, dict) or not isinstance(d.get('data'), dict):
        raise SystemExit('loops: the MCP subscription listing failed: refusing')
    return d['data']


def rc_system_calls(tx):
    """The RC's calls into the system contract inside one Lasna reaction (its own callTracer), after checking the tx
    is a landed system call whose LogRecord names this RC (lcron r1 M-01: chain data, the MCP only as an index)."""
    t = json.loads(cast('tx', '--json', tx, rpc=LASNA))
    r = json.loads(cast('receipt', '--json', tx, rpc=LASNA))
    w = words(t['input'][10:])
    if (t.get('to') or '').lower() != SYSTEM or int(r['status'], 16) != 1 or not w or w[0] != RC[2:].lower().rjust(64, '0'):
        raise SystemExit(f'loops: {tx} is not a landed reaction of the RC')
    ct = json.loads(cast('rpc', 'debug_traceTransaction', tx, '{"tracer":"callTracer"}', rpc=LASNA))
    out = []

    def walk(f, caller):
        if (f.get('from') or '').lower() == RC.lower() and (f.get('to') or '').lower() == SYSTEM:
            out.append((f['input'][2:10], words(f['input'][10:])[:6]))
        for c in f.get('calls', []):
            walk(c, f.get('to'))
    walk(ct, None)
    return t, w, out


PREFLIGHT_ACTIVE = 27  # the RC's active subscriptions at the s7 pre-flight (MCP, 2026-11-25), measured independently


def active_before(hist, block, active_now):
    """The RC's active filter ids just before `block`, rebuilt BACKWARDS from the active set now by undoing the window's
    events (the MCP history is truncated to its newest entries, so a forward rebuild from the RC's start is wrong;
    seen at the s7 close)."""
    on = set(active_now)
    for h_ in sorted((h for h in hist if h['block'] >= block), key=lambda x: -x['block']):
        (on.discard if h_['kind'] == 'Subscribe' else on.add)(h_['filterId'])
    return on


def lcron_verdict(row, sub_calls, unsub_calls, hist, fid, active_now, done_ts, unsub_ts, trigger_of=None):
    """`pass`: the retire's reaction subscribed exactly the Cron tuple; one Cron interval (no earlier unsubscribe, no
    re-subscribe) whose unsubscribe is a Cron reaction's exact six-argument unsubscribe AFTER the ExitDone by time;
    and the active filter set now equals the set just before the retire's reaction (lcron r1 M-01, M-02, m-01)."""
    subs_c = [a for s, a in sub_calls if s == SEL_SUB]
    row['subscribesCron'] = len(subs_c) == 1 and subs_c[0] == CRON_ARGS
    uns_c = [a for s, a in unsub_calls if s == SEL_UNSUB]
    row['unsubscribesCron'] = len(uns_c) == 1 and uns_c[0] == CRON_ARGS
    ev = [h_ for h_ in sorted(hist, key=lambda x: x['block']) if h_['filterId'] == fid
          and row['subscribeBlock'] <= h_['block'] <= row['unsubscribeBlock']]
    row['cronIntervals'] = [(h_['kind'], h_['block']) for h_ in ev]
    row['oneInterval'] = [k for k, _ in row['cronIntervals']] == ['Subscribe', 'Unsubscribe']
    row['unsubscribeAfterDone'] = unsub_ts >= done_ts
    row['exitDoneTs'], row['unsubscribeTs'] = done_ts, unsub_ts
    before = active_before(hist, row['subscribeBlock'], active_now)
    row['activeBefore'], row['activeNow'] = len(before), len(active_now)
    # the rebuilt set's size against the count measured independently at the pre-flight (before this run's changes)
    row['beforeMatchesPreflight'] = len(before) == PREFLIGHT_ACTIVE
    # the window's history agrees with the set now: each filter's last event says whether it is active now
    last = {}
    for h_ in sorted((h for h in hist if h['block'] >= row['subscribeBlock']), key=lambda x: x['block']):
        last[h_['filterId']] = h_['kind']
    row['historyConsistent'] = all((k_ == 'Subscribe') == (f_ in active_now) for f_, k_ in last.items())
    # changes made in the window by OTHER reactions (e.g. A-ACTION-SPAM's Action unsubscribe at the budget) are listed,
    # never absorbed silently; Cron's own filter is never among them; outside them the set is restored exactly
    others = [h_ for h_ in hist if h_['block'] >= row['subscribeBlock'] and h_['filterId'] != fid]
    # each other change is attributed to its reaction's trigger (its LogRecord topic0); one made by a Cron reaction or by
    # the retire's own reaction is Cron's footprint and fails the verdict (s7 close r1 M-01)
    trig = trigger_of or (lambda tx: None)
    row['otherChanges'] = [{'kind': h_['kind'], 'filterId': h_['filterId'], 'block': h_['block'], 'tx': h_['tx'],
                            'trigger': trig(h_['tx'])} for h_ in sorted(others, key=lambda x: x['block'])]
    row['othersNotCron'] = all(c_['trigger'] not in (None, T_CRON100) and c_['tx'].lower() != row.get('reactionTx', '').lower()
                               for c_ in row['otherChanges'])
    row['backToBaseline'] = fid not in active_now and row['beforeMatchesPreflight'] and row['historyConsistent']
    row['pass'] = all(row[k] for k in ('subscribesCron', 'unsubscribesCron', 'oneInterval', 'unsubscribeAfterDone',
                                       'backToBaseline', 'othersNotCron'))
    return row


def exit_notes(c, vault, frm):
    """The Hub's EXIT notes for (covenant, vault) from `frm`: (tx, block, outcome) in order."""
    h = hub('1301')
    es, _ = logs_chunked('1301', h, frm, 10**12, T_NOTE)
    out = []
    for e in sorted(es, key=lambda x: (int(x['blockNumber'], 16), int(x['logIndex'], 16))):
        if int(e['topics'][3], 16) != 2 or int(e['topics'][2], 16) != int(c, 16):
            continue
        w = words(e['data'])[2:]
        if int(w[0], 16) != int(vault, 16):
            continue
        out.append({'tx': e['transactionHash'], 'block': int(e['blockNumber'], 16), 'outcome': int(w[1], 16),
                    'a': int(w[3], 16), 'b': int(w[4], 16)})
    return out


def lcron():
    """L-CRON: the Cron subscribe and unsubscribe txs around one exit (the owner's Covenant on Y_A, retired by its
    curator: B3 gone, the owner decision of s7), and the RC's filter set back to what it was before."""
    st = [s for k, s in deployments('1301').items() if k.startswith('lcron_')]
    ret = [t for s in st for t in s['txs'] if t['label'] == 'retire_YA' and t.get('status') == 'ok']
    alloc = [t for s in st for t in s['txs'] if t['label'] == 'allocate_YA' and t.get('status') == 'ok']
    if len(ret) != 1 or not alloc:
        raise SystemExit('loops: L-CRON needs one landed retire_YA and an allocate_YA (lcron_ steps)')
    rtx = ret[0]['tx']
    r = json.loads(cast('receipt', '--json', rtx, rpc=rpc('1301')))
    mode = [l for l in r['logs'] if l['topics'][0] == T_MODE]
    if len(mode) != 1:
        raise SystemExit(f'loops: {rtx}: not one ModeChanged log')
    vault, li = mode[0]['address'], int(mode[0]['logIndex'], 16)
    ya = [e['vault'] for e in load().get('loops', []) if e.get('id') == 'L-DYN' and e.get('step') == 'ldyn_vault_YA']
    owner = json.load(open(os.path.join(ROOT, 'audits', 'deployments-5318007.json')))['steps']['rc']['owner']
    fac = deployments('1301')['reagent']['reads']['addresses']['factory']
    covenant = cast('call', fac, 'predict(address)(address)', owner, rpc=rpc('1301'))
    if ya != [vault.lower()] or alloc[-1]['to'].lower() != covenant.lower():  # lcron r1 m-05
        raise SystemExit('loops: the retired vault is not Y_A or the allocation was not the owner\'s Covenant')
    d = rc_subscriptions()
    hist = d['history']
    tr = mcp_trace('1301', rtx, li)
    rx = (tr['data'].get('reaction') or {}).get('tx')
    if not rx:
        raise SystemExit(f'loops: no reaction to the retire\'s ModeChanged yet ({tr["verdict"]})')
    t, w, sub_calls = rc_system_calls(rx)
    if (w[2], w[3], w[4], w[12], int(w[13], 16)) != (hex(1301)[2:].rjust(64, '0'), vault[2:].lower().rjust(64, '0'),
                                                    T_MODE[2:], rtx[2:].lower(), li):
        raise SystemExit(f'loops: {rx} is not the RC\'s reaction to the retire\'s ModeChanged')
    subs = [h_ for h_ in hist if h_['tx'].lower() == rx.lower() and h_['kind'] == 'Subscribe']
    if len(subs) != 1:
        raise SystemExit(f'loops: the retire\'s reaction {rx} made {len(subs)} subscriptions (want the Cron one)')
    fid = subs[0]['filterId']
    if min(h_['block'] for h_ in hist) > subs[0]['block']:
        raise SystemExit('loops: the MCP history does not reach back to the Cron subscribe: cannot rebuild the window')
    notes = exit_notes(covenant, vault, ret[0]['block'])
    done = [n for n in notes if n['outcome'] == 1]
    if not done:
        raise SystemExit(f'loops: no ExitDone yet (notes so far: {notes}); re-run later')
    done_ts = ts('1301', done[0]['block'])
    unsubs = [h_ for h_ in sorted(hist, key=lambda x: x['block']) if h_['filterId'] == fid
              and h_['kind'] == 'Unsubscribe' and h_['block'] > subs[0]['block']]
    later = [u_ for u_ in unsubs if int(cast('block', str(u_['block']), '--field', 'timestamp', rpc=LASNA)) >= done_ts]
    if not later:
        raise SystemExit('loops: no Cron unsubscribe after the ExitDone yet; re-run later')
    u = later[0]
    ut, uw, unsub_calls = rc_system_calls(u['tx'])
    unsub_ts = int(ut['blockTimestamp'], 16)
    row = {'originTx': rtx, 'vault': vault.lower(), 'covenant': covenant, 'reactionTx': rx, 'cronFilter': fid,
           'subscribeTx': subs[0]['tx'], 'subscribeBlock': subs[0]['block'], 'exitNotes': notes,
           'exitDoneTx': done[0]['tx'], 'exitDoneBlock': done[0]['block'], 'destTx': done[0]['tx'],
           'unsubscribeTx': u['tx'], 'unsubscribeBlock': u['block'],
           'unsubscribeInCronReaction': uw[4] == T_CRON100[2:]}
    row['cronTicks'] = len(cron_reactions(subs[0]['block'], u['block']))
    active_now = {s['filterId'] for s in d['subscriptions'] if s['active']}
    row = lcron_verdict(row, sub_calls, unsub_calls, hist, fid, active_now, done_ts, unsub_ts,
                        trigger_of=lambda tx: '0x' + rc_system_calls(tx)[1][4])
    row['pass'] = row['pass'] and row['unsubscribeInCronReaction']
    doc = load()
    doc['loops'] = [e for e in doc.get('loops', []) if e.get('id') not in ('L-CRON', 'L-CRON-failing')]
    for k_ in ('L-CRON', 'L-CRON-failing'):
        doc.get('runs', {}).pop(k_, None)  # no stale run beside the fresh one (s7 close r1 m-04)
    key = 'L-CRON' if row['pass'] else 'L-CRON-failing'
    save(doc, key, [row], 'Cron subscribed in the reaction to the retire (B3 gone) and unsubscribed by a Cron '
         'reaction after the patient exit was DONE, one interval; every other subscription change in the window was made '
         'by a non-Cron reaction (listed with its trigger in otherChanges) (spec §9.5, C-10)'
         if row['pass'] else 'L-CRON NOT shown: see the row\'s flags')
    print('loops:', key, {k: row[k] for k in ('subscribeBlock', 'unsubscribeBlock', 'cronTicks', 'oneInterval',
                                              'unsubscribeAfterDone', 'backToBaseline', 'pass')})


# ------------------------------------------------------------------ selftest (offline: the seams replaced; s7 r1 M-03)

def selftest():
    g = globals()
    fails = []
    names = ('cast', 'lcon_origins', 'mcp_trace', 'lasna_scan', 'check_reaction', 'first_applied', 'ts', 'hub',
             'logs_chunked', 'load', 'deployments', 'rpc', 'callback_outcome', 'lasna_scan', 'cron_reactions',
             'lasna_block_at', 'gas_set_logs', 'hub_entry', 'spoof_delivery')
    saved = {k: g[k] for k in names}
    g['rpc'] = lambda ch: 'http://selftest.invalid'  # no network: every chain read goes through a replaced seam

    n_ok = [0]

    def ok(cond, label):
        n_ok[0] += bool(cond)
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
        # I. (r2 M-02) the decoders on bytes
        W = lambda x: hex(x)[2:].rjust(64, '0') if isinstance(x, int) else x[2:].lower().rjust(64, '0')  # noqa: E731
        payload = SEL_CONDUCT + ''.join(W(x) for x in (0, 1, 0, 0, 3, 9))  # rc, id 1, breaches, gone, actions 3, seq 9
        payload += '0' * (-len(payload) % 64)
        cb = lambda chn, hub_: {'address': SYSTEM, 'topics': [T_CALLBACK, '0x' + W(chn), '0x' + W(RC), '0x' + W(hub_)],  # noqa: E731
                                'data': '0x' + ''.join(W(x) for x in (0, 0x40, 0x1a0, 0x20, chn, hub_, 261631, 0x80, 0xc4)) + payload}
        good_in = inp(7)
        rc_b = {'tx': json.dumps({'to': SYSTEM, 'input': good_in, 'blockNumber': '0x5', 'blockTimestamp': '0x64'}),
                'receipt': json.dumps({'status': '0x1', 'gasUsed': '0x1', 'logs': [cb(1301, H), cb(11155111, H)]})}
        g['cast'] = lambda *a, rpc: rc_b[a[0]]
        rx = saved['check_reaction']('1301', '0xL', otx, 7, H)
        ok(rx['sends']['1301']['seq'] == 9 and rx['sends']['1301']['actions'] == 3 and rx['sends']['1301']['gasLimit'] == 261631
           and rx['sends']['11155111']['hub'].lower() == H, 'the callback request decodes seq 9 / actions 3 / gasLimit / hub per chain')
        rc_b['tx'] = json.dumps({'to': H, 'input': good_in, 'blockNumber': '0x5', 'blockTimestamp': '0x64'})
        refuses(lambda: saved['check_reaction']('1301', '0xL', otx, 7, H), 'is not the RC\'s reaction', 'a Lasna tx not sent to the system contract')
        rc_b['tx'] = json.dumps({'to': SYSTEM, 'input': good_in, 'blockNumber': '0x5', 'blockTimestamp': '0x64'})
        refuses(lambda: saved['check_reaction']('11155111', '0xL', otx, 7, H), 'is not the RC\'s reaction', 'a reaction to the same tx hash on another chain')
        # J. lcon_rows: the wrong Hub, the Applied-side timeout branches (r2 M-02 1, 3), a not-carried verdict (r2 m-02)
        g['lcon_origins'] = lambda: [('XA', '1301', otx)]
        g['ts'] = lambda ch, b: T0 if b == 10 else (T0 + TIMEOUT_S + 5 if b == 999 else T0 + 30)
        g['cast'] = lambda *a, rpc: rec if a[0] == 'receipt' else '20'
        g['mcp_trace'] = lambda *a: {'verdict': 'REACTED', 'data': {'reaction': {'tx': '0xL'}}}
        react['sends'] = {c: {'hub': H, 'gasLimit': 1, 'id': 1, 'actions': 1, 'seq': 4} for c in CH}
        g['hub'] = lambda ch: '0x' + 'ef' * 20
        refuses(lambda: lcon_rows(NOW_NEW), 'not the recorded Hub', 'a snapshot sent to another Hub address')
        g['hub'] = lambda ch: H
        g['first_applied'] = lambda *a: (None, 50)
        refuses(lambda: lcon_rows(NOW_NEW), 're-run later', 'no Applied yet inside 4 h: refused, not undelivered')
        refuses(lambda: lcon_rows(NOW_OLD), 'short of 4 h', 'an old loop whose search stopped short of 4 h: refused')
        g['first_applied'] = lambda *a: (None, 999)
        r = lcon_rows(NOW_OLD)['L-CON-AA'][0]
        ok(not r['delivered'] and 'no Applied' in r['why'], 'control: no Applied in a search covering 4 h: undelivered')
        g['mcp_trace'] = lambda *a: {'verdict': 'FILTER_MISMATCH', 'data': {},
                                     'findings': [{'verdict': 'SEQUENCED_NOT_CARRIED'}]}  # the recorded answer
        refuses(lambda: lcon_rows(NOW_OLD), 'not carried', 'a log the subscription did not carry is no attempted loop')
        # K. callback_outcome (r1 m-03, r2 m-03)
        note = lambda kind, outcome: {'address': H, 'topics': [T_NOTE, '0x0', '0x0', '0x' + W(kind)],  # noqa: E731
                                      'data': '0x' + W(0x20) + W(0x120) + W(H) + (W(outcome) if kind == 2 else W(7) + W(outcome)) + W(0) * 6}
        for kind, kname in ((2, 'exit'), (3, 'plan')):
            for oc, want in ((1, True), (DEFERRED, False), (RELAY_FAILED, False)):
                g['cast'] = lambda *a, rpc, _n=note(kind, oc): json.dumps({'logs': [_n]})
                ok(saved['callback_outcome']('1301', '0x1', kname)[0] is want, f'{kname} outcome {oc} -> pass {want}')
        g['cast'] = lambda *a, rpc: json.dumps({'logs': [{'address': H, 'topics': [T_STALE], 'data': '0x'}]})
        ok(saved['callback_outcome']('1301', '0x1', 'conduct')[0] is False, 'a Stale answer fails the cell')
        g['cast'] = lambda *a, rpc: json.dumps({'logs': []})
        ok(saved['callback_outcome']('1301', '0x1', 'conduct')[0] is True, 'control: a conduct delivery without Stale passes')
        g['cast'] = lambda *a, rpc: json.dumps({'logs': [note(2, 1), note(2, 1)]})
        ok(saved['callback_outcome']('1301', '0x1', 'exit')[0] is False, 'two EXIT notes in one delivery fail the cell')
        g['cast'] = lambda *a, rpc: json.dumps({'logs': [note(1, 0), note(2, 1)]})
        ok(saved['callback_outcome']('1301', '0x1', 'exit') == (True, 1), 'a STATE note beside the EXIT note is not an outcome')
        g['cast'] = lambda *a, rpc: json.dumps({'logs': [{'address': '0x' + '77' * 20, 'topics': [T_STALE], 'data': '0x'}]})
        ok(saved['callback_outcome']('1301', '0x1', 'conduct')[0] is True, 'a Stale from another contract is not the Hub\'s')
        # L. the Lasna scanners on fake blocks
        sys_tx = lambda h, rc_, li, t0w=T_ACTION: {'hash': h, 'to': SYSTEM, 'input': '0x0d0d0d0d' + ''.join(  # noqa: E731
            [W(rc_), W(0x40), W(1301), W(H), t0w[2:]] + ['0' * 64] * 7 + [otx[2:], W(li)])}
        blocks = {0x100: {'timestamp': hex(T0), 'transactions': [sys_tx('0xother', '0x' + '99' * 20, 7)]},
                  0x101: {'timestamp': hex(T0 + 1), 'transactions': [sys_tx('0xhit', RC, 7)]}}
        def fake_rpc(*a, rpc):
            if a[0] == 'find-block':
                return str(0x100)
            b = int(a[2], 16)
            return json.dumps(blocks.get(b, {'timestamp': hex(T0 + TIMEOUT_S + 1), 'transactions': []}) if b < 0x110 else None)
        g['cast'] = fake_rpc
        g['lasna_block_at'] = lambda t: 0x100
        ok(saved['lasna_scan']('1301', otx, 7, T0)[0] == '0xhit', 'the scan finds the RC\'s reaction, not another RC\'s')
        ok(saved['lasna_scan']('1301', otx, 8, T0)[0] is None, 'the scan reports none after the timestamp passes 4 h')
        blocks[0x102] = None
        g['cast'] = lambda *a, rpc: str(0x100) if a[0] == 'find-block' else json.dumps(blocks.get(int(a[2], 16), {'timestamp': hex(T0), 'transactions': []}))
        refuses(lambda: saved['lasna_scan']('1301', otx, 8, T0), 'not served', 'a null Lasna block stops the absence scan')
        cblocks = {201: {'transactions': [sys_tx('0xcron', RC, 0, T_CRON100), sys_tx('0xact', RC, 0),
                                          sys_tx('0xothercron', '0x' + '99' * 20, 0, T_CRON100)]}}
        g['cast'] = lambda *a, rpc: json.dumps(cblocks.get(int(a[2], 16), {'transactions': []}))
        ok(saved['cron_reactions'](200, 200) == ['0xcron'], 'cron_reactions: this RC\'s Cron100 only')
        # M. (r3 M-01) lcon_stats' own verdict: >= 50 loops over >= 3 dated batches
        mkd = lambda d: {**mk(True), 'batch': d}  # noqa: E731
        ok(lcon_stats('X', [mkd('2026-11-25')] * 50)['pass'] is False, 'stats verdict: 50 loops on one date fail')
        ok(lcon_stats('X', [mkd('2026-11-25')] * 17 + [mkd('2026-11-26')] * 16 + [mkd('2026-11-27')] * 16)['pass'] is False,
           'stats verdict: 49 loops over 3 dates fail')
        ok(lcon_stats('X', [mkd('2026-11-25')] * 17 + [mkd('2026-11-26')] * 17 + [mkd('2026-11-27')] * 16)['pass'] is True,
           'stats verdict: 50 loops over 3 dates pass')
        # N. check_reaction's receipt guards
        def rc_case(status='0x1', logs_=None, ch_='1301'):
            d = {'tx': json.dumps({'to': SYSTEM, 'input': good_in, 'blockNumber': '0x5', 'blockTimestamp': '0x64'}),
                 'receipt': json.dumps({'status': status, 'gasUsed': '0x1', 'logs': logs_ if logs_ is not None else [cb(1301, H)]})}
            g['cast'] = lambda *a, rpc: d[a[0]]
            return lambda: saved['check_reaction'](ch_, '0xL', otx, 7, H)
        refuses(rc_case('0x0'), 'failed', 'a failed reaction receipt')
        short = dict(cb(1301, H)); short['data'] = short['data'][:-64]
        short['data'] = short['data'][:2 + 64 * 8] + W(0xa4) + short['data'][2 + 64 * 9:]
        ok('1301' not in rc_case(logs_=[short])()['sends'], 'a 5-argument payload is not read as an rcConduct')
        other = dict(cb(1301, H)); other['topics'] = other['topics'][:2] + ['0x' + W('0x' + '99' * 20)] + other['topics'][3:]
        ok('1301' not in rc_case(logs_=[other])()['sends'], 'another RC\'s callback request is ignored')
        refuses(rc_case(logs_=[cb(1301, H), cb(1301, H)]), 'two rcConduct', 'two snapshots to one chain in one reaction')
        # O. lasna_block_at on a fake chain (the era guard and the boundary)
        g['cast'] = lambda *a, rpc: str(RC_BLOCK + 1000) if a[0] == 'block-number' else str(T0 + (int(a[1]) - RC_BLOCK) * 2)
        ok(saved['lasna_block_at'](T0 + 10) == RC_BLOCK + 5, 'lasna_block_at: the first block at the timestamp')
        ok(saved['lasna_block_at'](T0 + 11) == RC_BLOCK + 6, 'lasna_block_at: the first block after a timestamp between blocks')
        refuses(lambda: saved['lasna_block_at'](T0), 'outside the RC era', 'lasna_block_at: a time at or before the RC era')
        # P. lasna_scan: only system txs; the walk stops only PAST t0 + 4 h
        g['lasna_block_at'] = lambda t: 0x100
        blocks2 = {0x100: {'timestamp': hex(T0), 'transactions': [{**sys_tx('0xnotsys', RC, 7), 'to': H}]},
                   0x101: {'timestamp': hex(T0 + TIMEOUT_S), 'transactions': []},
                   0x102: {'timestamp': hex(T0 + TIMEOUT_S), 'transactions': [sys_tx('0xlate', RC, 7)]}}
        g['cast'] = lambda *a, rpc: json.dumps(blocks2.get(int(a[2], 16), {'timestamp': hex(T0 + TIMEOUT_S + 1), 'transactions': []}))
        ok(saved['lasna_scan']('1301', otx, 7, T0)[0] == '0xlate',
           'lasna_scan: a non-system tx never counts, and a block at exactly t0 + 4 h is still scanned')
        # Q. lcon_rows: the cross-chain search starts at the destination's own block; the callback leg from the reaction
        g['lcon_origins'] = lambda: [('XA', '1301', otx)]
        g['ts'] = lambda ch, b: T0 if b == 10 else T0 + 30
        g['hub'] = lambda ch: H
        g['mcp_trace'] = lambda *a: {'verdict': 'REACTED', 'data': {'reaction': {'tx': '0xL'}}}
        g['check_reaction'] = lambda *a: react
        react['sends'] = {c: {'hub': H, 'gasLimit': 1, 'id': 1, 'actions': 1, 'seq': 4} for c in CH}
        starts = {}
        g['first_applied'] = lambda dest, h, i, s_, f, c: (starts.__setitem__(dest, f), (ap(5, 40), 40))[1]
        g['cast'] = lambda *a, rpc: rec if a[0] == 'receipt' else ('777' if a[0] == 'find-block' else '20')
        r = lcon_rows(NOW_NEW)
        ok(starts == {'1301': 10, '11155111': 776}, 'the same-chain search starts at the origin block, the cross-chain one '
           'at the destination block for the origin time')
        ok(r['L-CON-AB'][0]['leg_callback_s'] == 28, 'the callback leg is measured from the reaction, not the origin')
        # R. lgas_rows: a DEFERRED exit then a DONE exit: one failing row, then the passing one fills the cell
        tbl = rc_gas_table()
        lim = tbl[('1301', 'exit')]['gasLimit']
        g['gas_set_logs'] = lambda: []
        g['load'] = lambda: {'loops': [{'destChain': 1301, 'destTx': '0xd1'}, {'destChain': 1301, 'destTx': '0xd2'}]}
        g['deployments'] = lambda ch: {}
        g['hub'] = lambda ch: H
        g['hub_entry'] = lambda ch, tx: ('exit', 1_200_000, None, 'stub')
        outc = {'0xd1': DEFERRED, '0xd2': 1}
        def lg_cast(*a, rpc):
            if a[0] == 'tx':
                return json.dumps({'to': CH['1301']['proxy'], 'gas': hex(lim), 'input': '0x00'})
            return json.dumps({'logs': [note(2, outc[a[2]])]})
        g['cast'] = lg_cast
        rows_, _ = lgas_rows()
        ok([r_['pass'] for r_ in rows_] == [False, True] and rows_[0]['outcome'] == DEFERRED,
           'lgas_rows: a DEFERRED exit fails its row and the next DONE exit fills the cell')
        ok(lgas_key(rows_, {'pass': True})[1] == [f'{c}/{k}' for c in CH for k in KINDS if (c, k) != ('1301', 'exit')],
           'lgas_key: the filled exit cell is not listed missing')
        outc = {'0xd1': 2, '0xd2': 2}  # EARLY twice: valid readings, but the Covenant's exit work never ran
        rows_, _ = lgas_rows()
        ok(all(r_['pass'] and not r_['fillsCell'] for r_ in rows_) and '1301/exit' in lgas_key(rows_, {'pass': True})[1],
           'an EARLY exit is a passing reading but does not fill the exit cell (lcron r1 m-02)')
        # S. L-SPOOF (lspoof r1 M-01): the delivery search and the verdict
        SP_ = '0x' + '5a' * 20
        wordS = SP_[2:].rjust(64, '0')
        dlv = {'hash': '0xdlv', 'to': CH['1301']['proxy'], 'from': OPERATOR_1301, 'input': '0x8d1f0fa1' + '00' * 64 + SEL_CONDUCT + wordS,
               'blockNumber': hex(0x201)}
        decoy = {**dlv, 'hash': '0xdecoy', 'from': '0x' + '66' * 20}
        bare = {**dlv, 'hash': '0xbare', 'input': '0x' + wordS}
        sblocks = {0x200: {'transactions': [decoy, bare]}, 0x201: {'transactions': [decoy, dlv]}}
        g['cast'] = lambda *a, rpc: json.dumps(sblocks.get(int(a[2], 16)))
        ok(saved['spoof_delivery'](SP_, 0x200)[0]['hash'] == '0xdlv',
           'the spoof delivery: from the operator, the rcConduct payload\'s first word (decoys skipped)')
        base_row = lambda: {'hubLogs': 0, 'conduct99': [0, 0, 0, 0], 'hubBalanceBefore': 100, 'hubBalanceAfter': 90,  # noqa: E731
                            'reservesBefore': 0, 'reservesAfter': 0, 'debtBefore': 0, 'debtAfter': 0}
        fr = lambda out, err='execution reverted', w0=wordS: {'input': '0x' + SEL_CONDUCT + w0, 'error': err, 'output': out}  # noqa: E731
        v = spoof_verdict(base_row(), [fr(NOT_RC)], wordS, [dlv], H, '0xdlv')
        ok(v['pass'] and v['charged'] == 10 and v['billed'], 'control: NotRc, word 0 = SpoofRC, charge attributable -> pass, 10 wei billed')
        for frames, label in (([fr('0x' + 'ab' * 4)], 'another revert (NotProxy-like) is not a NotRc rejection'),
                              ([fr(NOT_RC, err=None)], 'a Hub frame that did not revert'),
                              ([fr(NOT_RC, w0=RC[2:].lower().rjust(64, '0'))], 'word 0 = the real RC'),
                              ([fr(NOT_RC), fr(NOT_RC)], 'two Hub frames'), ([], 'no Hub frame')):
            ok(spoof_verdict(base_row(), frames, wordS, [dlv], H, '0xdlv')['pass'] is False, f'L-SPOOF fails: {label}')
        ok(spoof_verdict({**base_row(), 'hubLogs': 1}, [fr(NOT_RC)], wordS, [dlv], H, '0xdlv')['pass'] is False, 'L-SPOOF fails: a Hub log')
        ok(spoof_verdict({**base_row(), 'conduct99': [0, 0, 0, 1]}, [fr(NOT_RC)], wordS, [dlv], H, '0xdlv')['pass'] is False,
           'L-SPOOF fails: conduct(99) moved')
        ok(spoof_verdict({**base_row(), 'conduct99': None}, [fr(NOT_RC)], wordS, [dlv], H, '0xdlv')['pass'] is False,
           'L-SPOOF fails: conduct(99) not read')
        v = spoof_verdict(base_row(), [fr(NOT_RC)], wordS, [dlv, {'hash': '0xo', 'to': CH['1301']['proxy']}], H, '0xdlv')
        ok(v['charged'] is None and v['billed'] is None and v['pass'], 'another proxy tx in the block: the charge is not attributed')
        v = spoof_verdict({**base_row(), 'hubBalanceAfter': 100, 'reservesBefore': 50, 'reservesAfter': 40}, [fr(NOT_RC)], wordS, [dlv], H, '0xdlv')
        ok(v['charged'] == 10, 'the charge from reserves counts')
        v = spoof_verdict({**base_row(), 'hubBalanceAfter': 100, 'debtAfter': 7}, [fr(NOT_RC)], wordS, [dlv], H, '0xdlv')
        ok(v['charged'] == 7 and v['billed'], 'a charge left as debt counts')
        # T. L-CRON (lcron r1 M-03): the verdict over its flags
        hist0 = [{'kind': 'Subscribe', 'block': 10, 'filterId': 'a', 'tx': '0x'}, {'kind': 'Subscribe', 'block': 11, 'filterId': 'b', 'tx': '0x'},
                 {'kind': 'Subscribe', 'block': 100, 'filterId': 'cron', 'tx': '0xrx'}, {'kind': 'Unsubscribe', 'block': 200, 'filterId': 'cron', 'tx': '0xu'}]
        base = lambda: {'subscribeBlock': 100, 'unsubscribeBlock': 200}  # noqa: E731
        good = [(SEL_SUB, CRON_ARGS)], [(SEL_UNSUB, CRON_ARGS)]
        g['PREFLIGHT_ACTIVE'] = 2
        v = lcron_verdict(base(), *good, hist0, 'cron', {'a', 'b'}, 1000, 1010)
        ok(v['pass'], 'control: Cron tuple subscribed and unsubscribed, one interval, after DONE, filter set restored')
        ok(active_before(hist0, 100, {'a', 'b'}) == {'a', 'b'} and active_before(hist0, 100, {'a', 'b', 'cron'}) == {'a', 'b'},
           'the filter set before the retire\'s reaction, rebuilt backwards from now')
        ok(not lcron_verdict(base(), [(SEL_SUB, CRON_ARGS[:2] + ['00' * 32] + CRON_ARGS[3:])], good[1], hist0, 'cron', {'a', 'b'}, 1000, 1010)['pass'],
           'L-CRON fails: the reaction subscribed a non-Cron tuple')
        ok(not lcron_verdict(base(), good[0], [(SEL_UNSUB, CRON_ARGS[:5] + ['00' * 32])], hist0, 'cron', {'a', 'b'}, 1000, 1010)['pass'],
           'L-CRON fails: an unsubscribe that is not the exact six arguments')
        ok(not lcron_verdict(base(), *good, hist0, 'cron', {'a', 'b'}, 1000, 999)['pass'], 'L-CRON fails: unsubscribed before the ExitDone')
        ok(not lcron_verdict(base(), *good, hist0, 'cron', {'a'}, 1000, 1010)['pass'], 'L-CRON fails: the set before is not the pre-flight count (one less)')
        ok(not lcron_verdict(base(), *good, hist0, 'cron', {'a', 'b', 'c'}, 1000, 1010)['pass'], 'L-CRON fails: the set before is not the pre-flight count (one more)')
        hist3 = hist0 + [{'kind': 'Unsubscribe', 'block': 150, 'filterId': 'b', 'tx': '0xact'}]
        v3 = lcron_verdict(base(), *good, hist3, 'cron', {'a'}, 1000, 1010, trigger_of=lambda tx: T_ACTION)
        ok(v3['pass'] and v3['otherChanges'][0]['filterId'] == 'b',
           'another reaction\'s unsubscribe in the window is listed and accounted, not a Cron failure')
        ok(not lcron_verdict(base(), *good, hist3, 'cron', {'a'}, 1000, 1010, trigger_of=lambda tx: T_CRON100)['pass'],
           'L-CRON fails: another filter changed by a Cron reaction (Cron\'s own footprint)')
        ok(not lcron_verdict({**base(), 'reactionTx': '0xact'}, *good, hist3, 'cron', {'a'}, 1000, 1010, trigger_of=lambda tx: T_ACTION)['pass'],
           'L-CRON fails: another filter changed by the retire\'s own reaction')
        ok(not lcron_verdict(base(), *good, hist3, 'cron', {'a'}, 1000, 1010)['pass'], 'L-CRON fails: an unattributed other change')
        ok(not lcron_verdict(base(), *good, hist3, 'cron', {'a', 'b'}, 1000, 1010, trigger_of=lambda tx: T_ACTION)['pass'],
           'L-CRON fails: a filter the window unsubscribed is still active (history and set disagree)')
        hist4 = hist0 + [{'kind': 'Subscribe', 'block': 300, 'filterId': 'cron', 'tx': '0xlater'}]
        ok(not lcron_verdict(base(), *good, hist4, 'cron', {'a', 'b', 'cron'}, 1000, 1010)['pass'],
           'L-CRON fails: Cron subscribed again later and still on (the filter must be gone)')
        ok(not lcron_verdict(base(), *good, hist0, 'cron', {'a', 'b', 'cron'}, 1000, 1010)['pass'],
           'L-CRON fails: the Cron filter still active')
        hist2 = hist0[:3] + [{'kind': 'Unsubscribe', 'block': 150, 'filterId': 'cron', 'tx': '0x'},
                             {'kind': 'Subscribe', 'block': 160, 'filterId': 'cron', 'tx': '0x'}] + hist0[3:]
        ok(not lcron_verdict(base(), *good, hist2, 'cron', {'a', 'b'}, 1000, 1010)['pass'], 'L-CRON fails: two Cron intervals (a park between)')
        g['PREFLIGHT_ACTIVE'] = 27
        # U. hub_entry: the callTracer fallback reads the same frame as parity; a real error is not retried away
        par = [{'action': {'to': H, 'callType': 'call', 'input': '0x' + SEL_CONDUCT + '00' * 32, 'gas': hex(84271)}, 'error': None}]
        ctr = {'to': CH['1301']['proxy'], 'type': 'CALL', 'input': '0x8d1f0fa1', 'gas': hex(261631), 'calls': [
            {'to': H, 'type': 'CALL', 'input': '0x' + SEL_CONDUCT + '00' * 32, 'gas': hex(84271), 'calls': []}]}
        g['hub'] = lambda ch: H
        g['cast'] = lambda *a, rpc: json.dumps(par)
        p_ = saved['hub_entry']('1301', '0x1')
        def pruned(*a, rpc):
            if a[1] == 'trace_transaction':
                raise SystemExit('loops: cast rpc failed: insufficient changesets to revert')
            return json.dumps(ctr)
        g['cast'] = pruned
        c_ = saved['hub_entry']('1301', '0x1')
        ok(p_[:3] == c_[:3] == ('conduct', 84271, None) and p_[3] != c_[3], 'the callTracer fallback reads the parity frame\'s gas (source recorded)')
        def wrong(*a, rpc):
            raise SystemExit('loops: cast rpc failed: invalid transaction hash')
        g['cast'] = wrong
        try:
            saved['hub_entry']('11155111', '0x1')
            ok(False, 'a real trace error is raised (not refused)')
        except SystemExit as e:
            ok('invalid transaction hash' in str(e) and 'after retries' not in str(e),
               'a real trace error is raised at once, not retried away')
        # H. lcon_origins: only X_A / X_B paths; pending refuses
        g['deployments'] = lambda ch: {'lcon_YA_20261125': {'txs': [{'tx': otx, 'status': 'ok'}]}} if ch == '1301' else {}
        refuses(lambda: saved['lcon_origins'](), 'has no L-CON path', 'a Y_A step folded into L-CON-AA (r1 m-04)')
        g['deployments'] = lambda ch: {'lcon_XA_20261125': {'txs': [{'tx': otx, 'status': 'pending'}]}} if ch == '1301' else {}
        refuses(lambda: saved['lcon_origins'](), 'still pending', 'a pending origin')
        g['deployments'] = lambda ch: {'lcon_XA_20261125': {'txs': [{'tx': otx, 'status': 'ok'}, {'tx': '0x2', 'status': 'FAILED'}]}} if ch == '1301' else {}
        ok(saved['lcon_origins']() == [('XA', '1301', otx)], 'control: X_A origins collected, failed sends skipped')
    finally:
        g.update(saved)
    print(f'loops selftest: {n_ok[0]} cells passed,', 'OK' if not fails else f'FAIL ({len(fails)})')
    return not fails


if __name__ == '__main__':
    what = sys.argv[1] if len(sys.argv) > 1 else ''
    if what == '--selftest':
        sys.exit(0 if selftest() else 1)
    cmds = {'ldyn': ldyn, 'lpay': lpay, 'lcon': lcon, 'lgas': lgas, 'lspoof': lspoof, 'lcron': lcron}
    if what not in cmds:
        raise SystemExit(__doc__)
    cmds[what]()
