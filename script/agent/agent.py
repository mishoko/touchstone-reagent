#!/usr/bin/env python3
"""The reference agent (spec §3.7): your agent (AI or script) holds the Covenant's `agent` key, which may only tighten
the depositor's rules and allocate within the caps, into the allowlist (`agentAllocate`; the Covenant picks no
recipient). This script is the reference: it reads a policy file and acts on it until it is stopped.

  python3 script/agent/agent.py run --policy script/agent/policy.json [--once] [--dry] [--prove-refusal]
      every `intervalSec`, for each policy entry (chain, covenant, vault, sharesPerTick): an eth_call dry run of
      `agentAllocate(vault, sharesPerTick, max0, max1)` (max0/max1 = the Covenant's token balances), pinned to one
      block. Passes -> sent (unless --dry). Reverts -> the 4-byte error decoded against CovenantBase's errors and
      logged as a refusal; nothing is sent. --prove-refusal: also sends ONE refused allocation per (chain, vault) per
      run, so the refusal is an on-chain reverted transaction (L-PAUSE / L-OFFLINE evidence).
  python3 script/agent/agent.py tighten --policy script/agent/policy.json [--dry]
      applies the policy's `tighten` block (a full Rulebook) via `tighten(Rulebook)`, only if it is stricter than
      the Covenant's current `rules()` by the Covenant's own rule (CovenantExt `_looser` / `_same` / `_validate`);
      refused before any send otherwise.
  python3 script/agent/agent.py --selftest      the refusals and the send rules, offline (no network, no key)

Refusals before any send: the agent keystore's address is not the Covenant's `agent()` on that chain, or it is the
owner (the owner key never runs as the agent).

Keys: the keystore RC_KEYSTORE_DIR/agent with the password file RC_KEYSTORE_PW; never printed, never on argv except as
`--keystore <path> --password-file <path>`. RPC: UNICHAIN_SEPOLIA_RPC_URL (1301) / ETH_SEPOLIA_RPC_URL (11155111),
never printed (redacted from every message). Every send: the eth_call dry run of the exact call first, an explicit
`--gas-limit` = max(1.5 x the node's estimate, the chain's floor), the hash logged as `pending` before the receipt
wait, then the outcome. The agent's own log: output/agent/agent-<chain>.jsonl (one JSON line per action, each with
ts, chain, block, action, tx, status, error); the chain evidence is collected separately from the tx hashes.
"""
import datetime as dt
import json
import os
import re
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(ROOT, 'output', 'agent')

OWNER = '0x07F30b8e65938aBC2F728878e8AFc51FfEdB8213'  # the depositor (owner) key: never the agent
CH = {'1301': 'UNICHAIN_SEPOLIA_RPC_URL', '11155111': 'ETH_SEPOLIA_RPC_URL'}
GAS_MARGIN = (3, 2)  # 1.5 x the node's estimate (as drive.py, s8)
GAS_FLOOR = {'1301': 2_000_000, '11155111': 4_000_000}

ALLOC = 'agentAllocate(address,uint256,uint256,uint256)'
# the Rulebook tuple: src/interfaces/IReagent.sol `struct Rulebook` (lines 6-16), in declaration order
RB_TYPE = '(uint8,bool,uint16,uint16,uint128,bool,uint16,uint128,uint32[4])'
RB_FIELDS = ('k', 'b3', 'b4FloorBps', 'maxShareBps', 'budget', 'b2', 'b5MaxBurnBps', 'agentCapPerEpoch', 'ids')
TIGHTEN = f'tighten({RB_TYPE})'
RULES = f'rules()({RB_TYPE})'
BPS = 10_000

# CovenantBase's errors (src/CovenantBase.sol, the `errors` block); read from the source when it is present, so the
# decoder follows the contract; this list is the fallback and the selftest checks the two agree
COV_ERRORS = ('NotOwner', 'NotAgent', 'NotHub', 'NotFactory', 'Initialized', 'Unbound', 'NotInIds', 'FifthVault',
              'ModeNotNormal', 'RecordPaused', 'Pending', 'Gone', 'BondFloor', 'HubPaused', 'OverBudget', 'Armed',
              'NotAllowed', 'AgentCap', 'RefStale', 'PriceTolerance', 'BadRules', 'NoChange', 'Looser', 'TooSoon',
              'PendingBreach', 'TooManyPlans', 'Self', 'NotDelegated')
# the vault's own refusals an allocation can surface (src/libraries/VaultRead.sol maps them for plans)
VAULT_ERRORS = ('Slippage', 'MarkoutPending', 'NavCap')

STOP = False


class Refused(SystemExit):
    pass


def refuse(why):
    raise Refused(f'agent: refusing: {why}')


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds')


# ------------------------------------------------------------------ chain access (the seams the selftest replaces)

def redact(text):
    """Keyed RPC URLs (they carry API keys) never reach the console or the log: each becomes its variable's name."""
    for k in CH.values():
        if os.environ.get(k):
            text = text.replace(os.environ[k], f'${k}')
    return text


def _run(args):
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(redact(f'agent: cast {args[1]} failed: {(r.stderr or r.stdout).strip()[-300:]}'))
    return r.stdout.strip()


def _try(args):
    """A call that may revert: (True, stdout) or (False, the redacted error text)."""
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        return False, redact((r.stderr or r.stdout).strip())
    return True, r.stdout.strip()


def rpc(ch):
    if ch not in CH:
        refuse(f'unknown chain {ch!r} (one of {", ".join(CH)})')
    if not os.environ.get(CH[ch]):
        refuse(f'{CH[ch]} is not set')
    return os.environ[CH[ch]]


def cast(*a, rpc):
    # options before positionals (TRAPS s6): `cast <sub> --rpc-url R <options…> <positionals…>`
    return _run(['cast', a[0], '--rpc-url', rpc, *a[1:]])


def wallet():
    d, pw = os.environ.get('RC_KEYSTORE_DIR'), os.environ.get('RC_KEYSTORE_PW')
    if not d or not pw or not os.path.isfile(os.path.join(d, 'agent')) or not os.path.isfile(pw):
        refuse('RC_KEYSTORE_DIR/agent and RC_KEYSTORE_PW must name the agent keystore and its password file')
    return ['--keystore', os.path.join(d, 'agent'), '--password-file', pw]


def signer():
    return _run(['cast', 'wallet', 'address', *wallet()])


def head(ch):
    return int(cast('block-number', rpc=rpc(ch)).split()[0])


def try_call(ch, frm, to, sig, *args, block):
    return _try(['cast', 'call', '--rpc-url', rpc(ch), '--from', frm, '--block', str(block), to, sig, *args])


def receipt(ch, tx, tries=30):
    for _ in range(tries):
        r = subprocess.run(['cast', 'receipt', '--json', '--rpc-url', rpc(ch), tx], capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            return json.loads(r.stdout)
        time.sleep(4)
    return None


def sel_of(sig):
    return _run(['cast', 'sig', sig]).lower()


# ------------------------------------------------------------------ the log (output/agent/agent-<chain>.jsonl)

def log_line(ch, rec):
    os.makedirs(OUT, exist_ok=True)
    line = {'ts': now(), 'chain': ch, 'block': None, 'action': None, 'tx': None, 'status': None, 'error': None, **rec}
    with open(os.path.join(OUT, f'agent-{ch}.jsonl'), 'a') as f:
        f.write(redact(json.dumps(line)) + '\n')
    print(redact('agent: ' + ' '.join(f'{k}={line[k]}' for k in ('chain', 'block', 'action', 'status', 'error', 'tx')
                                      if line[k] is not None)))


# ------------------------------------------------------------------ errors

_SELS = {}


def error_names():
    p = os.path.join(ROOT, 'src', 'CovenantBase.sol')
    names = re.findall(r'^\s*error\s+(\w+)\(\)\s*;', open(p).read(), re.M) if os.path.isfile(p) else []
    return tuple(names) or COV_ERRORS


def selectors():
    """selector -> error name, computed with `cast sig` once and cached."""
    if not _SELS:
        for n in error_names():
            _SELS[sel_of(f'{n}()')] = n
        for n in VAULT_ERRORS:
            _SELS.setdefault(sel_of(f'{n}()'), f'vault:{n}')
    return _SELS


def decode(text):
    """The revert's error name from cast's message: a known name as `Name()`, else the first 4-byte selector after
    `data:` / `custom error`. Returns (name or None, selector or None)."""
    sels = selectors()
    m = re.search(r'(?:data:\s*"?|custom error:?\s*)(0x[0-9a-fA-F]{8})', text)
    sel = m.group(1).lower() if m else None
    if sel in sels:
        return sels[sel], sel
    for s, n in sels.items():
        if re.search(rf'\b{n.split(":")[-1]}\(\)', text):
            return n, s
    return None, sel


# ------------------------------------------------------------------ gas and sends

def gas_limit(estimate, ch):
    return max(int(str(estimate).split()[0]) * GAS_MARGIN[0] // GAS_MARGIN[1], GAS_FLOOR[ch])


def send(ch, to, sig, *args, lim, action, extra):
    """An async send with an explicit gas limit; the hash is logged as `pending` before the receipt wait, so a
    landed tx is never lost to a timeout; then one outcome line (ok / reverted / no receipt) with its block."""
    h = _run(['cast', 'send', '--async', *wallet(), '--rpc-url', rpc(ch), '--gas-limit', str(lim), to, sig,
              *args]).split()[-1]
    log_line(ch, {'action': action, 'tx': h, 'status': 'pending', 'gasLimit': lim, **extra})
    r = receipt(ch, h)
    if r is None:
        log_line(ch, {'action': action, 'tx': h, 'status': 'no receipt (check it)', 'gasLimit': lim, **extra})
        return h, None
    st = 'ok' if int(r['status'], 16) == 1 else 'reverted'
    log_line(ch, {'action': action, 'tx': h, 'block': int(r['blockNumber'], 16), 'status': st, 'gasLimit': lim,
                  'gasUsed': int(r['gasUsed'], 16), **extra})
    return h, st


# ------------------------------------------------------------------ policy and the agent check

def load_policy(path):
    try:
        p = json.load(open(path))
    except (OSError, ValueError) as e:
        refuse(f'policy {path}: {e}')
    iv = p.get('intervalSec')
    if not isinstance(iv, int) or iv < 1:
        refuse('policy: intervalSec must be an integer >= 1')
    ents = p.get('entries') or []
    for e in ents:
        for k in ('chain', 'covenant', 'vault', 'sharesPerTick'):
            if k not in e:
                refuse(f'policy entry {e}: missing {k}')
        if str(e['chain']) not in CH:
            refuse(f'policy entry: unknown chain {e["chain"]!r}')
        if not str(e['sharesPerTick']).isdigit() or int(e['sharesPerTick']) == 0:
            refuse('policy entry: sharesPerTick must be a positive integer (as a string)')
    return p


def check_agent(ch, covenant, me):
    """The keystore must be this Covenant's agent() on this chain, and never the owner."""
    agent = cast('call', covenant, 'agent()(address)', rpc=rpc(ch)).split()[0]
    owner = cast('call', covenant, 'owner()(address)', rpc=rpc(ch)).split()[0]
    if me.lower() in (OWNER.lower(), owner.lower()):
        refuse(f'the keystore address {me} is the owner key: the owner never runs as the agent')
    if me.lower() != agent.lower():
        refuse(f'the keystore address {me} is not the Covenant\'s agent() {agent} on {ch} ({covenant})')


# ------------------------------------------------------------------ run

_TOKENS = {}


def tokens(ch, vault):
    if (ch, vault) not in _TOKENS:
        hook = cast('call', vault, 'HOOK()(address)', rpc=rpc(ch)).split()[0]
        ref = cast('call', hook, 'REF_POOL()(address)', rpc=rpc(ch)).split()[0]
        _TOKENS[(ch, vault)] = tuple(cast('call', ref, f'token{i}()(address)', rpc=rpc(ch)).split()[0] for i in (0, 1))
    return _TOKENS[(ch, vault)]


def tick(policy, me, dry, prove, proved):
    """One pass over the policy entries. `proved` = the (chain, vault) pairs that already had their proving send in
    this run (at most one each)."""
    for e in policy['entries']:
        ch, c, v, s = str(e['chain']), e['covenant'], e['vault'], str(e['sharesPerTick'])
        blk = head(ch)
        m0, m1 = (cast('call', '--block', str(blk), t, 'balanceOf(address)(uint256)', c, rpc=rpc(ch)).split()[0]
                  for t in tokens(ch, v))
        args = (v, s, m0, m1)
        base = {'covenant': c, 'vault': v, 'shares': s, 'max0': m0, 'max1': m1, 'dry': dry}
        ok, out = try_call(ch, me, c, ALLOC, *args, block=blk)
        if ok:
            if dry:
                log_line(ch, {'block': blk, 'action': 'allocate', 'status': 'dry run passes (not sent)', **base})
                continue
            est = cast('estimate', '--from', me, c, ALLOC, *args, rpc=rpc(ch))
            send(ch, c, ALLOC, *args, lim=gas_limit(est, ch), action='allocate', extra=base)
            continue
        name, sel = decode(out)
        log_line(ch, {'block': blk, 'action': 'allocate', 'status': 'refused (dry run, not sent)',
                      'error': name or f'unknown {sel}', 'selector': sel, **base})
        if prove and not dry and name and (ch, v.lower()) not in proved:
            proved.add((ch, v.lower()))  # before the send: a failed send never earns a second one
            # the estimate of a reverting call fails, so the proving send carries the chain's floor
            send(ch, c, ALLOC, *args, lim=GAS_FLOOR[ch], action='prove-refusal',
                 extra={**base, 'expect': name, 'dryBlock': blk})


def on_signal(signum, frame):
    global STOP
    STOP = True


def run(path, once, dry, prove):
    global STOP
    p = load_policy(path)
    if not p['entries']:
        refuse('policy: no entries')
    me = signer()
    for ch, c in sorted({(str(e['chain']), e['covenant']) for e in p['entries']}):
        check_agent(ch, c, me)
    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)
    STOP = False
    print(f'agent started {now()} as {me}: every {p["intervalSec"]} s'
          f'{" (dry: nothing is sent)" if dry else ""}{" (prove-refusal on)" if prove and not dry else ""}')
    for e in p['entries']:
        print(f'  chain {e["chain"]}  covenant {e["covenant"]}  vault {e["vault"]}  sharesPerTick {e["sharesPerTick"]}')
    for ch in sorted({str(e['chain']) for e in p['entries']}):
        log_line(ch, {'action': 'start', 'status': 'agent started', 'agent': me, 'dry': dry})
    proved = set()
    try:
        while not STOP:
            tick(p, me, dry, prove, proved)
            if once:
                break
            t_end = time.time() + p['intervalSec']
            while not STOP and time.time() < t_end:
                time.sleep(0.5)
    finally:
        for ch in sorted({str(e['chain']) for e in p['entries']}):
            log_line(ch, {'action': 'stop', 'status': 'agent stopped', 'agent': me})
        print(f'agent stopped {now()}')


# ------------------------------------------------------------------ tighten

def parse_rules(out):
    """cast's tuple output, e.g. `(1, true, 0, 6000, 100000000000000000000 [1e20], false, 0, 1e19…, [2, 1, 0, 0])`."""
    s = re.sub(r'\s\[\d+(?:\.\d+)?e\d+\]', '', out.strip())
    s = s.replace('(', '[').replace(')', ']')
    v = json.loads(s)
    if len(v) != len(RB_FIELDS) or len(v[-1]) != 4:
        refuse(f'rules(): unexpected shape {out!r}')
    return dict(zip(RB_FIELDS, v))


def norm_rules(r):
    try:
        x = {f: r[f] for f in RB_FIELDS}
        for f in ('k', 'b4FloorBps', 'maxShareBps', 'budget', 'b5MaxBurnBps', 'agentCapPerEpoch'):
            x[f] = int(x[f])
        for f in ('b3', 'b2'):
            if not isinstance(x[f], bool):
                raise ValueError(f'{f} must be true/false')
        x['ids'] = [int(i) for i in x['ids']]
        if len(x['ids']) != 4 or any(i < 0 or i >= 2**32 for i in x['ids']):
            raise ValueError('ids must be four uint32 (0 = empty slot)')
    except (KeyError, ValueError, TypeError) as e:
        refuse(f'tighten: the rulebook is not a full Rulebook ({e})')
    return x


def _idset(ids):
    return {i for i in ids if i != 0}


def stricter(n, o):
    """The Covenant's own test (CovenantExt `_validate`, `_looser`, `_same`; spec §5.4): '' if `n` may replace `o`
    by `tighten`, else why not."""
    if not 1 <= n['k'] <= 3 or n['agentCapPerEpoch'] > n['budget'] // 10 or n['b5MaxBurnBps'] != 0 \
            or n['b4FloorBps'] > BPS or n['maxShareBps'] > BPS:
        return 'invalid rules (BadRules): k in 1..3, agentCapPerEpoch <= budget/10, b5MaxBurnBps = 0, bps <= 10000'
    loose = [f for f, bad in (
        ('k', n['k'] > o['k']), ('b3', o['b3'] and not n['b3']), ('b4FloorBps', n['b4FloorBps'] < o['b4FloorBps']),
        ('maxShareBps', o['maxShareBps'] != 0 and (n['maxShareBps'] == 0 or n['maxShareBps'] > o['maxShareBps'])),
        ('budget', n['budget'] > o['budget']), ('b2', o['b2'] and not n['b2']),
        ('agentCapPerEpoch', n['agentCapPerEpoch'] > o['agentCapPerEpoch']),
        ('ids', not _idset(n['ids']) <= _idset(o['ids']))) if bad]
    if loose:
        return f'looser than the current rules (Looser): {", ".join(loose)}'
    if all(n[f] == o[f] for f in RB_FIELDS if f != 'ids') and _idset(n['ids']) == _idset(o['ids']):
        return 'changes nothing (NoChange)'
    return ''


def enc_rules(r):
    b = lambda x: 'true' if x else 'false'  # noqa: E731
    return (f'({r["k"]},{b(r["b3"])},{r["b4FloorBps"]},{r["maxShareBps"]},{r["budget"]},{b(r["b2"])},'
            f'{r["b5MaxBurnBps"]},{r["agentCapPerEpoch"]},[{",".join(map(str, r["ids"]))}])')


def tighten(path, dry):
    p = load_policy(path)
    t = p.get('tighten')
    if not t:
        refuse('policy: no tighten block (it is null): nothing to apply')
    ch, c = str(t.get('chain')), t.get('covenant')
    if ch not in CH or not c:
        refuse('tighten: the block needs chain and covenant')
    me = signer()
    check_agent(ch, c, me)
    new = norm_rules(t.get('rulebook') or {})
    cur = norm_rules(parse_rules(cast('call', c, RULES, rpc=rpc(ch))))
    why = stricter(new, cur)
    if why:
        refuse(f'tighten: {why}; nothing sent')
    rb = enc_rules(new)
    blk = head(ch)
    ok, out = try_call(ch, me, c, TIGHTEN, rb, block=blk)
    if not ok:
        name, sel = decode(out)
        log_line(ch, {'block': blk, 'action': 'tighten', 'status': 'refused (dry run, not sent)',
                      'error': name or f'unknown {sel}', 'selector': sel, 'covenant': c, 'rules': rb})
        refuse(f'tighten: the dry run reverts ({name or sel}); nothing sent')
    if dry:
        log_line(ch, {'block': blk, 'action': 'tighten', 'status': 'dry run passes (not sent)', 'covenant': c,
                      'rules': rb, 'dry': True})
        return None
    est = cast('estimate', '--from', me, c, TIGHTEN, rb, rpc=rpc(ch))
    h, st = send(ch, c, TIGHTEN, rb, lim=gas_limit(est, ch), action='tighten', extra={'covenant': c, 'rules': rb})
    print(f'agent: tighten {rb}: {st or "no receipt"} ({h})')
    return h


# ------------------------------------------------------------------ selftest (offline: every seam replaced)

def selftest():
    import tempfile
    global OUT, STOP
    g = globals()
    names = ('signer', 'cast', 'head', 'try_call', '_run', 'receipt', 'wallet', 'rpc')
    saved = {k: g[k] for k in names}
    saved_out, saved_env = OUT, {k: os.environ.get(k) for k in CH.values()}
    fails = 0

    def check(label, good):
        nonlocal fails
        print(('selftest ok: ' if good else 'selftest FAIL: ') + label)
        fails += not good

    def refused(label, must, fn):
        try:
            fn()
        except Refused as e:
            check(f'{label} is refused', must in str(e))
            if must not in str(e):
                print('   (refused for another reason:', e, ')')
            return
        check(f'{label} is refused (it was not)', False)

    def passes(label, fn):
        try:
            fn()
            check(f'control: {label} passes', True)
        except Refused as e:
            check(f'control: {label} passes (refused: {e})', False)

    AG, CV = '0x' + 'a1' * 20, '0x' + 'c0' * 20
    V1, V2, T0, T1 = '0x' + 'b1' * 20, '0x' + 'b2' * 20, '0x' + '70' * 20, '0x' + '71' * 20
    HUBPAUSED = sel_of('HubPaused()')
    st = {}

    def fake_cast(*a, rpc):
        if a[0] == 'call':
            sig = next(x for x in a if '(' in x)
            if sig.startswith('agent()'):
                return st['agent']
            if sig.startswith('owner()'):
                return st['owner']
            if sig.startswith('HOOK()') or sig.startswith('REF_POOL()'):
                return '0x' + '99' * 20
            if sig.startswith('token0()') or sig.startswith('token1()'):
                return T0 if 'token0' in sig else T1
            if sig.startswith('balanceOf'):
                return '5000000000000000000 [5e18]'
            if sig.startswith('rules()'):
                return st['rules']
        if a[0] == 'estimate':
            return st['estimate']
        if a[0] == 'block-number':
            return '777'
        raise AssertionError(f'unexpected cast {a}')

    sent = []

    def fake_run(args):
        if args[:2] == ['cast', 'send']:
            sent.append(args)
            return '0x' + f'{len(sent):064x}'
        return saved['_run'](args)

    npol = [0]

    def policy(td, entries, tight=None):
        npol[0] += 1
        p = os.path.join(td, f'policy{npol[0]}.json')
        json.dump({'intervalSec': 60, 'entries': entries, 'tighten': tight}, open(p, 'w'))
        return p

    def lines(td, ch):
        f = os.path.join(td, f'agent-{ch}.jsonl')
        return [json.loads(x) for x in open(f)] if os.path.isfile(f) else []

    def lim_of(args):
        return int(args[args.index('--gas-limit') + 1]) if '--gas-limit' in args else None

    ent = lambda v, ch='11155111': {'chain': ch, 'covenant': CV, 'vault': v, 'sharesPerTick': str(10**18)}  # noqa: E731
    try:
        with tempfile.TemporaryDirectory() as td:
            OUT = td
            g['rpc'] = lambda ch: 'http://selftest.invalid'
            g['cast'], g['_run'], g['wallet'] = fake_cast, fake_run, lambda: ['--keystore', '<k>', '--password-file', '<p>']
            g['receipt'] = lambda ch, tx, tries=30: {'status': st.get('rstatus', '0x1'), 'blockNumber': hex(778),
                                                     'gasUsed': hex(500_000)}
            g['head'] = lambda ch: 777
            g['signer'] = lambda: AG

            # the decoder follows the source
            check('the CovenantBase error list read from the source equals the fallback list',
                  error_names() == COV_ERRORS)
            check('HubPaused decodes from `data: "0x…"` and from `custom error 0x…`',
                  decode(f'execution reverted, data: "{HUBPAUSED}"')[0] == 'HubPaused'
                  and decode(f'execution reverted: custom error {HUBPAUSED}')[0] == 'HubPaused')
            check('control: an unknown selector decodes to no name (its selector kept)',
                  decode('execution reverted, data: "0xdeadbeef"') == (None, '0xdeadbeef'))

            # (a) (b) the agent check
            p1 = policy(td, [ent(V1)])
            st.update(agent=AG, owner=OWNER, estimate='1000000', rules='')
            g['try_call'] = lambda *a, block: (True, '0x')
            passes('the keystore is the Covenant\'s agent()', lambda: run(p1, True, True, False))
            st['agent'] = '0x' + 'ee' * 20
            refused('(a) a keystore that is not the Covenant\'s agent()', 'is not the Covenant\'s agent()',
                    lambda: run(p1, True, False, False))
            st['agent'] = OWNER
            g['signer'] = lambda: OWNER
            refused('(b) the owner key set as the agent and used as the keystore', 'is the owner key',
                    lambda: run(p1, True, False, False))
            st['agent'], st['owner'] = AG, AG
            g['signer'] = lambda: AG
            refused('(b) a keystore equal to the Covenant\'s owner()', 'is the owner key',
                    lambda: run(p1, True, False, False))
            st['owner'] = OWNER
            check('(a)(b) no send while refused', not sent)

            # (c) a dry-run revert (HubPaused): logged as HubPaused, not sent
            for f in os.listdir(td):
                if f.endswith('.jsonl'):
                    os.remove(os.path.join(td, f))
            g['try_call'] = lambda *a, block: (False, f'Error: server returned an error response: error code 3: '
                                                      f'execution reverted, data: "{HUBPAUSED}"')
            run(p1, True, False, False)
            ls = [x for x in lines(td, '11155111') if x['action'] == 'allocate']
            check('(c) a HubPaused dry run is logged as HubPaused with its block, and nothing is sent',
                  len(ls) == 1 and ls[0]['error'] == 'HubPaused' and ls[0]['block'] == 777 and not sent)
            acts = [x['action'] for x in lines(td, '11155111')]
            check('the log carries start and stop lines around the run', acts[0] == 'start' and acts[-1] == 'stop')

            # (d) --prove-refusal: exactly one send per (chain, vault) per run, with the floor as its gas limit
            p2 = policy(td, [ent(V1), ent(V2), ent(V1.upper().replace('0X', '0x'))])
            st['rstatus'] = '0x0'
            proved = set()
            for _ in range(3):
                tick(load_policy(p2), AG, False, True, proved)
            to_v = sorted(a[a.index(CV) + 2].lower() for a in sent)
            check('(d) three ticks over V1, V2 and V1 again -> exactly two proving sends, one per vault',
                  len(sent) == 2 and to_v == sorted([V1.lower(), V2.lower()]))
            check('(d) each proving send carries --gas-limit 4,000,000 (the 11155111 floor)',
                  all(lim_of(a) == 4_000_000 for a in sent))
            pr = [x for x in lines(td, '11155111') if x['action'] == 'prove-refusal']
            check('(d) each proving send is logged pending, then reverted with its tx and block',
                  [x['status'] for x in pr] == ['pending', 'reverted'] * 2
                  and all(x['tx'] for x in pr) and pr[1]['block'] == 778 and pr[1]['expect'] == 'HubPaused')
            sent.clear()
            proved2 = set()
            g['try_call'] = lambda *a, block: (False, 'execution reverted, data: "0xdeadbeef"')
            tick(load_policy(p1), AG, False, True, proved2)
            check('(d) control: an undecoded revert is not proven on chain', not sent)
            g['try_call'] = lambda *a, block: (False, f'execution reverted, data: "{HUBPAUSED}"')
            tick(load_policy(p1), AG, True, True, proved2)
            check('(d) control: --dry never sends a proving refusal', not sent)
            run(p1, True, False, True)
            check('(d) control: a fresh run proves again (once)', len(sent) == 1)
            sent.clear()

            # (e) a passing dry run sends with --gas-limit max(1.5 x estimate, floor)
            st['rstatus'] = '0x1'
            g['try_call'] = lambda *a, block: (True, '0x')
            for ch, est, want in (('11155111', '3000000', 4_500_000), ('11155111', '1000000', 4_000_000),
                                  ('1301', '1600000', 2_400_000), ('1301', '100000', 2_000_000)):
                sent.clear()
                st['estimate'] = est
                tick({'entries': [ent(V1, ch)]}, AG, False, False, set())
                check(f'(e) on {ch} an estimate of {est} sends --gas-limit {want:,}',
                      len(sent) == 1 and lim_of(sent[0]) == want and sent[0][sent[0].index('--gas-limit') + 2] == CV)
            al = [x for x in lines(td, '1301') if x['action'] == 'allocate']
            check('(e) the send is logged pending (tx) before its outcome (tx, block, ok)',
                  al[-2]['status'] == 'pending' and al[-2]['tx'] and al[-1]['status'] == 'ok'
                  and al[-1]['block'] == 778 and al[-1]['tx'] == al[-2]['tx'])
            sent.clear()
            tick({'entries': [ent(V1)]}, AG, True, False, set())
            check('(e) control: --dry with a passing dry run sends nothing', not sent)

            # (f) tighten: looser refused before any send; stricter passes
            st['rules'] = '(2, true, 0, 6000, 100000000000000000000 [1e20], false, 0, 10000000000000000000 [1e19], [2, 1, 0, 0])'
            cur = parse_rules(st['rules'])
            check('the rules() tuple parses in IReagent.sol field order',
                  cur == {'k': 2, 'b3': True, 'b4FloorBps': 0, 'maxShareBps': 6000, 'budget': 10**20, 'b2': False,
                          'b5MaxBurnBps': 0, 'agentCapPerEpoch': 10**19, 'ids': [2, 1, 0, 0]})
            st['estimate'] = '300000'
            for label, ch_, must in (
                    ('k 2 -> 3', {'k': 3}, 'Looser): k'),
                    ('maxShareBps 6000 -> 0 (off)', {'maxShareBps': 0}, 'Looser): maxShareBps'),
                    ('a new id 3', {'ids': [2, 1, 3, 0]}, 'Looser): ids'),
                    ('b3 off', {'b3': False}, 'Looser): b3'),
                    ('a raised budget', {'budget': 2 * 10**20}, 'Looser): budget'),
                    ('a permutation of ids', {'ids': [1, 2, 0, 0]}, 'NoChange'),
                    ('b5 non-zero', {'k': 1, 'b5MaxBurnBps': 1}, 'BadRules')):
                sent.clear()
                pt = policy(td, [], {'chain': '11155111', 'covenant': CV, 'rulebook': {**cur, **ch_}})
                refused(f'(f) a tighten with {label}', must, lambda: tighten(pt, False))
                check(f'(f) ... and nothing is sent for {label}', not sent)
            sent.clear()
            pt = policy(td, [], {'chain': '11155111', 'covenant': CV,
                                 'rulebook': {**cur, 'k': 1, 'ids': [2, 0, 0, 0], 'agentCapPerEpoch': 5 * 10**18}})
            passes('(f) a stricter tighten (k 2 -> 1, id 1 removed, a lower agent cap)', lambda: tighten(pt, False))
            check('(f) the stricter tighten is sent once, as the IReagent tuple, with --gas-limit 4,000,000',
                  len(sent) == 1 and TIGHTEN in sent[0] and lim_of(sent[0]) == 4_000_000
                  and sent[0][-1] == f'(1,true,0,6000,{10**20},false,0,{5 * 10**18},[2,0,0,0])')
            check('(f) the tighten selector is the spec\'s 0x1dae7e0c', sel_of(TIGHTEN) == '0x1dae7e0c')
            sent.clear()
            st['agent'] = '0x' + 'ee' * 20
            refused('(f) a stricter tighten from a key that is not the agent', 'is not the Covenant\'s agent()',
                    lambda: tighten(pt, False))
            st['agent'] = AG
            refused('(f) a tighten with the block null', 'nothing to apply', lambda: tighten(p1, False))
            check('(f) no send from the refused tightens', not sent)

            # (g) redaction of a keyed RPC URL
            key = 'https://eth-sepolia.example.invalid/v2/SELFTESTKEY123'
            os.environ['ETH_SEPOLIA_RPC_URL'] = key
            msg = ''
            try:
                saved['_run'](['sh', '-c', f'echo "error sending request for url ({key})" >&2; exit 1'])
            except SystemExit as e:
                msg = str(e)
            check('(g) a keyed RPC URL in a cast error is redacted',
                  'SELFTESTKEY123' not in msg and '$ETH_SEPOLIA_RPC_URL' in msg)
            ok_, txt = _try(['sh', '-c', f'echo "reverted at {key}" >&2; exit 1'])
            check('(g) ... and in a dry-run revert text', not ok_ and 'SELFTESTKEY123' not in txt)
            log_line('11155111', {'action': 'selftest', 'status': f'url {key}'})
            check('(g) ... and in a log line', 'SELFTESTKEY123' not in open(os.path.join(td, 'agent-11155111.jsonl')).read())
            check('(g) control: text without the URL is unchanged', redact('plain text 0x1234') == 'plain text 0x1234')

            # the stop flag ends the loop (SIGINT/SIGTERM handler)
            STOP = False
            on_signal(signal.SIGINT, None)
            check('SIGINT sets the stop flag', STOP)
            STOP = False
    finally:
        g.update(saved)
        OUT = saved_out
        for k, v in saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        signal.signal(signal.SIGINT, signal.default_int_handler)
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
    print(f'selftest: {"all passed" if not fails else f"{fails} FAILED"}')
    return fails == 0


def main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        print(__doc__)
        return 2
    if argv[0] == '--selftest':
        return 0 if selftest() else 1
    pol = argv[argv.index('--policy') + 1] if '--policy' in argv and argv.index('--policy') + 1 < len(argv) else None
    if not pol:
        refuse('--policy FILE is required')
    if argv[0] == 'run':
        run(pol, '--once' in argv, '--dry' in argv, '--prove-refusal' in argv)
    elif argv[0] == 'tighten':
        tighten(pol, '--dry' in argv)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
