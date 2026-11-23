#!/usr/bin/env python3
"""Merges the T-GAS-* measurements (`output/gas-need-<kind>.json`, written by test/GasNeed.t.sol) into
`audits/gas-need.json` with the spec §5.6 gas limits per chain (R-04: recorded by script). The NEED used for each
chain is the value the code holds (the Hub's `needs()` for exit/plan; the RC-side table for the rest), and the script
fails if any is below ceil(1.3 x the measurement).

  python3 script/deploy/gasneed.py
"""
import json, math, os, subprocess, sys, datetime as dt

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
F = {'1301': 177_200, '11155111': 243_300}
RESERVE = 40_000
SLOT = {'1301': 22_274, '11155111': 110_980}
CREATE = {'1301': 53_799, '11155111': 210_421}
# the NEEDs in code (src/ReagentHub.sol needs(); the RC-side table is spec §5.6, held by the RC in s3)
CODE = {'rcConduct': {'1301': 35_000, '11155111': 150_000}, 'rcVault': {'1301': 91_000, '11155111': 437_000},
        'rcBudget': {'1301': 345_000, '11155111': 461_000}, 'rcExit': {'1301': 832_000, '11155111': 1_870_000},
        'rcAllocate': {'1301': 1_198_000, '11155111': 2_236_000}}


def gas_limit(chain, need):
    num = 11 * 64 * (64 * need + 63 * RESERVE)
    den = 10 * 63 * 63
    return -(-num // den) + F[chain]


def main():
    out = {'generated_by': 'script/deploy/gasneed.py', 'from': 'test/GasNeed.t.sol (T-GAS-*)',
           'generated_at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'),
           'commit': subprocess.run(['git', 'rev-parse', '--short', 'HEAD'], cwd=ROOT, capture_output=True, text=True).stdout.strip(),
           'method': 'entry gas = minimum succeeding entry gas at a constructed worst-case state, every account cold (vm.cool); '
                     '11155111 = that + fresh slots x (110,980 - 22,274) + creations x (210,421 - 53,799) (spec 5.6 method (b)); '
                     'NEED = 1.3 x, rounded up; gasLimit = ceil(1.1 (NEED 64/63 + RESERVE) 64/63) + F',
           'F': F, 'RESERVE': RESERVE, 'kinds': {}}
    bad = []
    for kind in CODE:
        p = os.path.join(ROOT, 'output', f'gas-need-{kind}.json')
        d = json.load(open(p))
        m = {k: v for k, v in d.items() if not isinstance(v, dict)}
        row = {'entry_1301': m['entry_1301'], 'fresh_slots': m['fresh_slots'], 'creates': m['creates'], 'chains': {}}
        for ch in F:
            entry = m['entry_1301'] + m['fresh_slots'] * (SLOT[ch] - SLOT['1301']) + m['creates'] * (CREATE[ch] - CREATE['1301'])
            need_min = math.ceil(entry * 1.3)
            need = CODE[kind][ch]
            if need < need_min:
                bad.append(f'{kind} on {ch}: code NEED {need} < 1.3 x measured {need_min}')
            row['chains'][ch] = {'entry': entry, 'need_min': need_min, 'need': need, 'gasLimit': gas_limit(ch, need)}
        out['kinds'][kind] = row
    for b in bad:
        print('gasneed:', b)
    if bad:
        return 1
    json.dump(out, open(os.path.join(ROOT, 'audits', 'gas-need.json'), 'w'), indent=1)
    for k, r in out['kinds'].items():
        print(f"{k:11s} " + '  '.join(f"{ch}: NEED {v['need']:>9,} gasLimit {v['gasLimit']:>9,}" for ch, v in r['chains'].items()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
