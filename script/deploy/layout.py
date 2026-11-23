#!/usr/bin/env python3
"""Storage-layout check (spec §5.4, s2 D2-07 / F1-04): `Covenant` (the clone's core) and `CovenantExt` (reached by
delegatecall on the clone's storage) must declare exactly the same slots, all from `CovenantBase`: same label, slot,
offset and type, in the same order. Exit 0 iff identical. `--selftest` checks that a divergence is caught.

  python3 script/deploy/layout.py [--selftest]
"""
import json, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def layout(name):
    r = subprocess.run(['forge', 'inspect', name, 'storageLayout', '--json'], cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0 and 'storage layout missing' in r.stderr:
        # a cached artifact built without the layout output: rebuild that contract once
        r = subprocess.run(['forge', 'inspect', name, 'storageLayout', '--json', '--force'], cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f'layout: forge inspect {name} failed: {r.stderr.strip()[:200]}')
    d = json.loads(r.stdout)
    return [(s['label'], s['slot'], s['offset'], d['types'][s['type']]['label']) for s in d['storage']]


def diff(a, b):
    return [f'{x} != {y}' for x, y in zip(a, b) if x != y] + ([f'length {len(a)} != {len(b)}'] if len(a) != len(b) else [])


def main():
    if '--selftest' in sys.argv:
        a = [('owner', '0', 0, 'address'), ('agent', '1', 0, 'address')]
        assert diff(a, a) == []
        assert diff(a, a + [('extra', '2', 0, 'uint256')]), 'an extra slot must be caught'
        assert diff(a, [a[1], a[0]]), 'a reorder must be caught'
        print('layout selftest OK')
        return 0
    c, e = layout('Covenant'), layout('CovenantExt')
    d = diff(c, e)
    for x in d:
        print('layout:', x)
    print(f'layout: Covenant {len(c)} slots, CovenantExt {len(e)} slots:', 'IDENTICAL' if not d else 'DIFFER')
    return 0 if not d else 1


if __name__ == '__main__':
    sys.exit(main())
