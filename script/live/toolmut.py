#!/usr/bin/env python3
"""Hand mutants of script/live/loops.py, each of which `loops.py --selftest` must kill (s7 loops review r2 M-02's
standing check: every decoder and branch of the evidence collector is pinned by a failing selftest cell).

  python3 script/live/toolmut.py     apply each mutant alone to a scratch copy, run the selftest, report

A mutant marked EQUIVALENT carries its reason; any other survivor fails the run."""
import os, shutil, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MUTANTS = [
    ('Applied-side young refusal removed', """                if not old:
                    raise SystemExit(f'loops: {key} {otx}: no Applied >= seq {snd["seq"]} yet; re-run later')
""", '', 'EQUIVALENT: the coverage check that follows (the search must reach t0 + 4 h) refuses every loop younger '
     'than 4 h, so the outcome is the same refusal'),
    ('seq decoded from the actions word', "'actions': int(a[4], 16), 'seq': int(a[5], 16)}",
     "'actions': int(a[4], 16), 'seq': int(a[4], 16)}", None),
    ('the recorded-Hub check removed', "            if snd['hub'].lower() != hub(dest).lower():", '            if False:', None),
    ('the to == SYSTEM check removed', "    if (t.get('to') or '').lower() != SYSTEM or got != want:", '    if got != want:', None),
    ('the origin-chain word not compared', "    got = {'rc': w[0], 'chain': w[2],", "    got = {'rc': w[0], 'chain': want['chain'],", None),
    ('callback_outcome always passes', "    r = json.loads(cast('receipt', '--json', tx, rpc=rpc(ch)))\n    h = hub(ch).lower()\n    if any(",
     "    return True, None\n    r = json.loads(cast('receipt', '--json', tx, rpc=rpc(ch)))\n    h = hub(ch).lower()\n    if any(", None),
    ('cron_reactions matches any system tx', "if len(w) > 13 and w[0] == RC[2:].lower().rjust(64, '0') and w[4] == T_CRON100[2:]:",
     'if len(w) > 13:', None),
    ('the margin rule < instead of <=', 'return lhs * 10 <= live * 9', 'return lhs * 10 < live * 9', None),
    ('the absence scan removed', '            lx, scanned = lasna_scan(ch, otx, li, t0)', '            lx, scanned = None, None', None),
    ('the seq filter >= replaced by any Applied', "hit = lambda es: [e for e in es if int(e['data'], 16) >= seq]",
     'hit = lambda es: list(es)', None),
    ('the proxy-sender check removed', "    if tx['to'].lower() != CH[dest]['proxy'].lower():", '    if False:', None),
    ('p95 lower-bound threshold off by one', "'p95IsLowerBound': und * 20 > len(rs)", "'p95IsLowerBound': und * 20 >= len(rs)", None),
    ('lgas_key ignores the Cron forward', "and bool(cron and cron['pass'])", '', None),
]


def main():
    src = open(os.path.join(ROOT, 'script', 'live', 'loops.py')).read()
    bad = 0
    with tempfile.TemporaryDirectory() as t:
        os.makedirs(os.path.join(t, 'script', 'live'))
        for d in ('rnk', 'deploy'):
            shutil.copytree(os.path.join(ROOT, 'script', d), os.path.join(t, 'script', d))
        for d in ('audits', 'src'):
            shutil.copytree(os.path.join(ROOT, d), os.path.join(t, d))
        env = {k: v for k, v in os.environ.items() if 'RPC' not in k}
        for name, a, b, equiv in MUTANTS:
            if src.count(a) != 1:
                print(f'toolmut: ANCHOR LOST ({src.count(a)}): {name}')
                bad += 1
                continue
            open(os.path.join(t, 'script', 'live', 'loops.py'), 'w').write(src.replace(a, b))
            r = subprocess.run([sys.executable, os.path.join(t, 'script', 'live', 'loops.py'), '--selftest'],
                               capture_output=True, text=True, env=env)
            killed = r.returncode != 0
            if killed:
                print('KILLED    ', name)
            elif equiv:
                print('EQUIVALENT', name, '--', equiv)
            else:
                print('SURVIVED  ', name)
                bad += 1
    print('toolmut', 'OK' if not bad else f'FAIL ({bad})')
    return 0 if not bad else 1


if __name__ == '__main__':
    sys.exit(main())
