#!/usr/bin/env python3
"""Storage-layout check (spec §5.4, s2 D2-07 / F1-04): a contract reached by delegatecall on another's storage must
declare exactly the same slots as it, all from their shared base: for each family, the base, the core and the
extension have the same label, slot, offset and type, in the same order (the base's own layout is the reference, so
"all from the base" is checked, not assumed; tools review m-8). Families: `CovenantBase` → `Covenant`, `CovenantExt`;
`RcBase` → `ReagentRC`, `RcExt` once those exist. Exit 0 iff every family is identical.

  python3 script/deploy/layout.py [--selftest]
"""
import json, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FAMILIES = [('CovenantBase', ['Covenant', 'CovenantExt'], 'src/CovenantBase.sol'),
            ('RcBase', ['ReagentRC', 'RcExt'], 'src/RcBase.sol')]


def parse(text):
    """Rows (label, slot, offset, type label) of a `forge inspect <C> storageLayout --json` document."""
    d = json.loads(text)
    return [(s['label'], str(s['slot']), int(s['offset']), d['types'][s['type']]['label']) for s in d['storage']]


def layout(name):
    r = subprocess.run(['forge', 'inspect', name, 'storageLayout', '--json'], cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0 and 'storage layout missing' in r.stderr:
        # a cached artifact built without the layout output: rebuild that contract once
        r = subprocess.run(['forge', 'inspect', name, 'storageLayout', '--json', '--force'], cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f'layout: forge inspect {name} failed: {r.stderr.strip()[:200]}')
    return parse(r.stdout)


def diff(a, b):
    return [f'{x} != {y}' for x, y in zip(a, b) if x != y] + ([f'length {len(a)} != {len(b)}'] if len(a) != len(b) else [])


SAMPLE = json.dumps({'storage': [
    {'astId': 1, 'contract': 'src/Covenant.sol:Covenant', 'label': 'HUB', 'offset': 0, 'slot': '0', 'type': 't_contract(IReagentHub)6975'},
    {'astId': 2, 'contract': 'src/Covenant.sol:Covenant', 'label': 'notePending', 'offset': 5, 'slot': '21', 'type': 't_bool'}],
    'types': {'t_contract(IReagentHub)6975': {'encoding': 'inplace', 'label': 'contract IReagentHub', 'numberOfBytes': '20'},
              't_bool': {'encoding': 'inplace', 'label': 'bool', 'numberOfBytes': '1'}}})


def selftest():
    a = [('owner', '0', 0, 'address'), ('agent', '1', 0, 'address')]
    assert diff(a, a) == []
    assert diff(a, a + [('extra', '2', 0, 'uint256')]), 'an extra slot must be caught'
    assert diff(a, [a[1], a[0]]), 'a reorder must be caught'
    assert diff(a, [a[0], ('agent', '1', 0, 'uint160')]), 'a type change must be caught'
    assert diff(a, [a[0], ('agent', '1', 12, 'address')]), 'an offset change must be caught'
    rows = parse(SAMPLE)  # the real `forge inspect` shape: string slots, the type resolved through `types`
    assert rows == [('HUB', '0', 0, 'contract IReagentHub'), ('notePending', '21', 5, 'bool')], rows
    print('layout selftest OK')
    return 0


def main():
    if '--selftest' in sys.argv:
        return selftest()
    bad = 0
    for base, kids, path in FAMILIES:
        if not os.path.exists(os.path.join(ROOT, path)):
            print(f'layout: {base} family not in the tree yet ({path}); skipped')
            continue
        ref = layout(base)
        for k in kids:
            d = diff(ref, layout(k))
            for x in d:
                print(f'layout: {k} vs {base}:', x)
            bad += bool(d)
            print(f'layout: {k} {"IDENTICAL to" if not d else "DIFFERS from"} {base} ({len(ref)} slots)')
    return 0 if not bad else 1


if __name__ == '__main__':
    sys.exit(main())
