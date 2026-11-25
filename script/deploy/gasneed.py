#!/usr/bin/env python3
"""Merges the T-GAS-* measurements (`output/gas-need-<kind>.json`, written by test/GasNeed.t.sol) into
`audits/gas-need.json` with the spec §5.6 gas limits per chain (R-04: recorded by script). The NEED used for each
chain is the value the code holds (the Hub's `needs()` for exit/plan; the RC-side table for the rest), and the script
fails if any is below ceil(1.3 x the measurement).

  python3 script/deploy/gasneed.py
"""
import json, math, os, re, sys, datetime as dt
from prov import stamp

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
F = {'1301': 177_200, '11155111': 243_300}
RESERVE = 40_000
SLOT = {'1301': 22_274, '11155111': 110_980}
CREATE = {'1301': 53_799, '11155111': 210_421}
# the RC-side NEEDs (conduct, vault, budget) are spec §5.6 inputs to the RC's gasLimit table; they are read from
# src/ReagentRC.sol once it exists (NEED_<KIND>_<CHAIN> constants), else from this spec copy (printed as such)
SPEC_RC = {'rcConduct': {'1301': 35_000, '11155111': 150_000}, 'rcVault': {'1301': 91_000, '11155111': 437_000},
           'rcBudget': {'1301': 360_000, '11155111': 500_000}}  # s4 (cold); 11155111 s3 LF-S3-1 (method (a))


def _num(x):
    return int(x.replace('_', ''))


def code_needs():
    """The NEEDs the code holds (tools review m-6): the Hub's `needs()` parsed from source (both chain branches)."""
    hub = open(os.path.join(ROOT, 'src', 'ReagentHub.sol')).read()
    body = hub[hub.index('function needs()'):]
    body = body[:body.index('\n    }') + 6]
    sep = re.search(r'if \(block\.chainid == 11155111\) return \(([\d_]+), ([\d_]+)\);\s*return \(([\d_]+), ([\d_]+)\);', body)
    if not sep:
        raise SystemExit('gasneed: cannot parse ReagentHub.needs(); update the parser with the code')
    out = {'rcExit': {'11155111': _num(sep[1]), '1301': _num(sep[3])},
           'rcAllocate': {'11155111': _num(sep[2]), '1301': _num(sep[4])}}
    rc = ''.join(open(os.path.join(ROOT, 'src', f)).read() for f in ('ReagentRC.sol', 'RcBase.sol')
                 if os.path.exists(os.path.join(ROOT, 'src', f)))
    for kind, tag in (('rcConduct', 'CONDUCT'), ('rcVault', 'VAULT'), ('rcBudget', 'BUDGET')):
        row = {}
        for ch in ('1301', '11155111'):
            m = re.search(rf'NEED_{tag}_{ch}\s*=\s*([\d_]+)', rc)
            if not m and rc:
                raise SystemExit(f'gasneed: the RC source exists but holds no NEED_{tag}_{ch} (s3 rc r6 D6-04)')
            row[ch] = _num(m[1]) if m else SPEC_RC[kind][ch]
            if not m:
                print(f'gasneed: {kind} on {ch} from the spec copy (no src/ReagentRC.sol yet)')
        out[kind] = row
    return out


def gas_limit(chain, need):
    num = 11 * 64 * (64 * need + 63 * RESERVE)
    den = 10 * 63 * 63
    return -(-num // den) + F[chain]


def main():
    out = {'generated_by': 'script/deploy/gasneed.py', 'from': 'test/GasNeed.t.sol (T-GAS-*)',
           'generated_at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'),
           **stamp(),
           'method': 'entry gas = minimum succeeding entry gas at a constructed worst-case state built in setUp, the search the '
                     'first state-touching step of its test body (every account and slot cold, F-011; vm.cool cools accounts only); '
                     '11155111: method (a), 1.3 x the eth_simulateV1 twin minimum (sepolia_twins, per row: same src/, pass; spec 5.6, 14 #76); method (b) = that + fresh '
                     'slots x (110,980 - 22,274) + creations x (210,421 - 53,799) kept as information (spec 5.6, 6); '
                     'NEED = 1.3 x, rounded up; gasLimit = ceil(1.1 (NEED 64/63 + RESERVE) 64/63) + F',
           'F': F, 'RESERVE': RESERVE, 'kinds': {}}
    bad = []
    CODE = code_needs()
    # spec §5.6 / §14 #76 (owner ruling s6): a kind's NEED[11155111] is certified by its post-deploy twin (method (a))
    # once one exists; the twin row must be measured on the current src/ and pass, else the kind fails; with no twin
    # row, method (b) certifies (the pre-deploy estimate)
    path0 = os.path.join(ROOT, 'audits', 'gas-need.json')
    tw0 = (json.load(open(path0)) if os.path.exists(path0) else {}).get('sepolia_twins', {})
    src_now = stamp().get('src_sha')
    TWINS = {k: v for k, v in tw0.items() if isinstance(v, dict) and 'measured' in v}
    for kind in ('rcConduct', 'rcVault', 'rcBudget', 'rcExit', 'rcAllocate'):
        p = os.path.join(ROOT, 'output', f'gas-need-{kind}.json')
        d = json.load(open(p))
        m = {k: v for k, v in d.items() if not isinstance(v, dict)}
        # F-010 H2-02: only a cold measurement certifies a NEED; H4-03: never older than the source it measures
        if m.get('cold') is not True:
            raise SystemExit(f'gasneed: {p} is not a cold measurement (F-011); re-run test/GasNeedCold.t.sol')
        newest = max(os.path.getmtime(os.path.join(dp, f)) for dp, _, fs in os.walk(os.path.join(ROOT, 'src'))
                     for f in fs if f.endswith('.sol'))
        if os.path.getmtime(p) < newest:
            raise SystemExit(f'gasneed: {p} predates the newest src/ file; re-run the T-GAS tests')
        row = {'entry_1301': m['entry_1301'], 'fresh_slots': m['fresh_slots'], 'creates': m['creates'], 'chains': {}}
        for ch in F:
            entry = m['entry_1301'] + m['fresh_slots'] * (SLOT[ch] - SLOT['1301']) + m['creates'] * (CREATE[ch] - CREATE['1301'])
            need_min = math.ceil(entry * 1.3)
            need = CODE[kind][ch]
            rec = {'entry': entry, 'need_min': need_min}
            tw = TWINS.get(kind) if ch == '11155111' else None
            if ch == '11155111' and tw is None:
                print(f'gasneed: {kind} on 11155111: no twin row, certified by method (b) (spec §5.6)')
            if tw is not None and (tw.get('src_sha') != src_now or tw.get('pass') is not True):
                bad.append(f'{kind} on 11155111: its twin is stale or failed (src {tw.get("src_sha")} vs {src_now}, '
                           f'pass {tw.get("pass")}): re-run sepgas.py (spec §14 #76)')
            if tw is not None:
                # spec §5.6 / §14 #76: method (a) certifies; method (b) is kept as information only
                ms = tw['measured']
                base = ms['covenantNeedUpper'] if 'covenantNeedUpper' in ms else ms['entryMin']
                rec = {'method': 'a', 'twin_measured': base, 'need_min': math.ceil(base * 1.3),
                       'method_b_entry': entry, 'method_b_need_min': need_min}
                need_min = rec['need_min']
            if need < need_min:
                bad.append(f'{kind} on {ch}: code NEED {need} < 1.3 x measured {need_min}')
            row['chains'][ch] = {**rec, 'need': need, 'gasLimit': gas_limit(ch, need)}
        out['kinds'][kind] = row
    for b in bad:
        print('gasneed:', b)
    if bad:
        return 1
    path = os.path.join(ROOT, 'audits', 'gas-need.json')
    prev = json.load(open(path)) if os.path.exists(path) else {}
    for k, v in prev.items():
        if k not in out:
            out[k] = v  # other records (e.g. sepolia_twins by sepgas.py) are kept
    json.dump(out, open(path, 'w'), indent=1)
    for k, r in out['kinds'].items():
        print(f"{k:11s} " + '  '.join(f"{ch}: NEED {v['need']:>9,} gasLimit {v['gasLimit']:>9,}" for ch, v in r['chains'].items()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
