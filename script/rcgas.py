#!/usr/bin/env python3
"""R-GAS's reservation record (spec §5.5 "Deferred work", §9.2 R-GAS): runs the caps-tick cells (each tick the test
body's first reaction: cold) and writes `audits/rc-gas.json` from their console output, never by hand (R-04).

  python3 script/rcgas.py            run the cells (ONE forge job) and write the record
  python3 script/rcgas.py --from LOG parse an existing `forge test -vv` log of the same cells instead of running

Per cell: the first class, the live (modelled HEAD) Cron forward, the measured terms, the exact reservation's left side
`overhead + term + GAS_GUARD` (term: cursor (CURSOR_FLOOR − 1) · the dearest evaluation; lowers: the whole floor (2);
dirty: the whole floor (3), both conservative) and its margin. The shape matrix's terms come from the unbounded-forward runs of the same
cells. The record also carries the provenance stamp (commit, dirty, src_sha)."""
import json, os, re, subprocess, sys, datetime as dt

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'deploy'))
from prov import stamp  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'audits', 'rc-gas.json')
CELLS = {
    'RcGasCapsCursorFirstTest': 'cursor first: 8 curators (one target vault each, 1301), each Covenant holding 4 vaults with the target last, each evaluation entering its wait and resending (the dearest measured)',
    'RcGasCapsLowersFirstTest': 'lowers first: one 8-distinct-id stale head, then a head owing only its last (id, chain)',
    'RcGasCapsDirtyFirstTest': 'dirty first: a woken 4-id B6 park (its id without pairs)',
}
MATRIX = {
    'RcGasCronCapsTest': 'cursor 2 vaults with 16 + 8 Covenants; lowers [4 stale, H, 4 stale] 4 shared ids; 1-id park',
    'RcGasCronCapsNoStaleTest': 'as above, no stale head ahead (one visit that sends)',
    'RcGasCronCaps8IdsTest': '8 distinct ids; 4 stale ahead; 4-id park',
    'RcGasCronCaps8IdsNoStaleTest': '8 distinct ids; no stale ahead',
    'RcGasCronCapsLastOnlyTest': 'a head owing only its last (id, chain), 8 distinct ids',
    'RcGasCronCapsColdCursorTest': 'cursor 8 vaults of one curator, one Covenant each',
    'RcGasCronCapsColdCursor8CuratorsTest': 'cursor 8 curators, one vault each',
    'RcGasCronCapsColdCursorResendTest': 'cursor 8 curators, resends due',
    'RcGasCronCapsColdCursor4HoldTest': 'cursor 8 curators, each Covenant holding 4 vaults with the target last',
    'RcGasCronCapsColdCursorResendParkTest': 'cursor 8 curators, each evaluation resends and parks',
    'RcGasCronCapsColdCursor4HoldResendTest': 'cursor 8 curators, 4 holdings (target last), each entering its wait and resending',
    'RcGasCronCapsEmptyVaultsTest': 'cursor 8 curators, 24 vaults without Covenants (8 between each of the first 4 targets; V4-01)',
    'RcGasCronCapsColdCursor4HoldResendParkTest': 'cursor 8 curators, 4 holdings (target last), resend and park',
}
NUM = r'(\d+)'


def run():
    pat = '^(' + '|'.join(list(CELLS) + list(MATRIX)) + ')$'
    r = subprocess.run(['forge', 'test', '--match-path', 'test/RcGasCaps.t.sol', '--match-contract', pat, '-vv'],
                       cwd=ROOT, capture_output=True, text=True)
    open(os.path.join(ROOT, 'output', 'rcgas-last.log'), 'w').write(r.stdout)
    if r.returncode != 0:
        sys.stdout.write(r.stdout[-4000:])
        raise SystemExit('rcgas: the cells failed; nothing written')
    return r.stdout


def parse(log):
    rows = {}
    cur = None
    for line in log.splitlines():
        m = re.search(r'Ran \d+ tests? for (\S+):(\w+)', line)
        if m:
            # every suite header switches the cell: a subclass in another file (e.g. RcGasGuard's) prints its own
            # LIVE/TERMS rows, which must never land on the caps cell printed before it
            cur = m[2] if m[1] == 'test/RcGasCaps.t.sol' else None
            if cur is not None:
                if cur in rows:
                    raise SystemExit(f'rcgas: {cur} appears twice in the log')
                rows[cur] = {}
            continue
        if cur is None:
            continue
        if line.startswith('[FAIL'):
            raise SystemExit(f'rcgas: {cur} failed in the log: {line[:160]}')
        for key in ('LIVE', 'TERMS'):
            m = re.match(rf'\s*{key} (.*)', line)
            if not m:
                continue
            pairs = re.findall(r'([A-Za-z()0-9]+(?: [a-z]+)?) (\d+)', m[1])
            d = rows[cur].setdefault(key.lower(), {})
            for k, v in pairs:
                k = k.strip()
                if k in d:
                    raise SystemExit(f'rcgas: {cur}: a second {key} {k} row (a mixed log)')
                d[k] = int(v)
    return rows


SPEC = os.path.join(ROOT, 'internal', 'REAGENT-SPEC.md')


def lint_spec(cells):
    """The spec's [M s5] reservation figures are the record's (v13 r3 V3-02's standing check)."""
    if not os.path.exists(SPEC):
        print('rcgas: no internal spec here; the lint is skipped')
        return
    text = open(SPEC).read()
    for name, c in cells.items():
        for frag in (f"{c['lhs']:,}", f"margin {c['margin']:,}"):
            if frag not in text:
                raise SystemExit(f'rcgas: the spec does not quote {name} {frag!r} (re-quote §5.5 from the record)')
    cf = cells['RcGasCapsCursorFirstTest']
    if f"3 × {cf['maxEval1']:,}" not in text:
        raise SystemExit(f"rcgas: the spec does not quote the dearest evaluation 3 × {cf['maxEval1']:,}")


def main():
    if '--from' in sys.argv:
        log = open(sys.argv[sys.argv.index('--from') + 1]).read()
    else:
        log = run()
    rows = parse(log)
    cells = {}
    for name, desc in CELLS.items():
        lv = rows.get(name, {}).get('live')
        if not lv:
            raise SystemExit(f'rcgas: no LIVE row for {name}')
        want = {'RcGasCapsCursorFirstTest': 0, 'RcGasCapsLowersFirstTest': 1, 'RcGasCapsDirtyFirstTest': 2}[name]
        if lv['class'] != want:
            raise SystemExit(f'rcgas: {name}: first class {lv["class"]} != {want}')
        lhs, fwd = lv['lhs'], lv['forward']
        cells[name] = {'shape': desc, 'firstClass': lv['class'], 'forward': fwd, 'overhead': lv['overhead'],
                       'floor1': lv['worst(1)'], 'maxEval1': lv['maxEval1'], 'floor2': lv['floor(2)'],
                       'item3': lv['item(3)'], 'gasGuard': lv['guard'], 'lhs': lhs, 'margin': fwd - lhs}
        if lhs > fwd * 9 // 10:
            raise SystemExit(f'rcgas: {name}: the reservation breaks the 10% margin rule ({lhs} > 0.9 × {fwd})')
    matrix = {n: {'shape': d, **rows[n]['terms']} for n, d in MATRIX.items() if 'terms' in rows.get(n, {})}
    missing = [n for n in MATRIX if n not in matrix]
    if missing:
        raise SystemExit(f'rcgas: the shape matrix is incomplete (v13 r3 V3-02): {missing}')
    # each phase cell runs on its class's dearest measured shape (rc-fix r3 C3-03), terms against terms
    for cell, key in (('RcGasCapsCursorFirstTest', 'maxEval1'), ('RcGasCapsLowersFirstTest', 'floor(2)'),
                      ('RcGasCapsDirtyFirstTest', 'item(3)')):
        own = rows.get(cell, {}).get('terms', {}).get(key)
        if own is None:
            raise SystemExit(f'rcgas: no TERMS row for {cell}')
        worse = {n: m[key] for n, m in matrix.items() if m[key] > own}
        if worse:
            raise SystemExit(f'rcgas: {cell} is not the dearest {key} ({own}): {worse}')
    doc = {**stamp(), 'recorded_at': dt.datetime.now(dt.timezone.utc).isoformat(timespec='seconds'),
           'generated_by': 'script/rcgas.py', 'spec': 'REAGENT-SPEC §5.5 "Deferred work" (v1.3), §9.2 R-GAS',
           'forward_note': 'the modelled HEAD forward (test/base/RcEnv.sol reactGasFor); L-GAS pins the live one',
           'cells': cells, 'minMargin': min(c['margin'] for c in cells.values()), 'matrix': matrix}
    open(OUT, 'w').write(json.dumps(doc, indent=1) + '\n')
    print('rc-gas: min margin', doc['minMargin'], 'written', os.path.relpath(OUT, ROOT))
    lint_spec(cells)  # after the write: a mismatch means the spec is re-quoted from this record, then `--from` again


if __name__ == '__main__':
    main()
