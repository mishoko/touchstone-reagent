#!/usr/bin/env python3
"""Curated mutation runner (Touchstone Reagent; ported in s2 from Touchstone's script/mutate.py, F-002). Applies ONE textual mutation at a time, runs the named killing test (or the full suite),
records the verdict and restores the file. A surviving mutant has three honest answers: write the missing test,
delete the line, or write down why it cannot be tested. Widening a tolerance is none of them. While a mutant is
applied the runner keeps the original as `<file>.mutorig` and writes `output/MUTATION_IN_PROGRESS`; never run another
`forge test` on this tree meanwhile (`script/markers.py` fails if either is left behind).

  python3 script/mutate.py                  # all mutants
  python3 script/mutate.py MU-003 MU-007    # a subset
  python3 script/mutate.py --changed        # only the mutants whose basis changed since their last KILLED (below)
  python3 script/mutate.py --since <rev>    # the mutants whose file, killer files or linked libraries changed since
                                            # the git revision <rev> (the close rule), plus every --changed one
  python3 script/mutate.py -j 1 ...         # the only worker count accepted (PROCESS §6, §8: one forge/solc-heavy
                                            # job at a time); -j N > 1 is refused, never silently capped
  python3 script/mutate.py --full           # the full suite per mutant instead of the named killer
  python3 script/mutate.py --audit          # every // [MU-xxx] tag in src/ has a mutant and every wired mutant
                                            # has its tag in its file
  python3 script/mutate.py --write          # also store each verdict (and a KILLED mutant's basis) in mutants.json

audits/mutants.json: {"mutants": [{"id": "MU-001", "area": "...", "desc": "...", "killer_id": "U-4" | null,
  "kill": "<test name pattern>" | "pending", "file": "src/..." | null, "find": "...", "replace": "...",
  "status": "...", "basis": "<hash>"}]}
Each mutant is tagged in the code it mutates with `// [MU-xxx]` next to the rule.

Verdicts (from `forge test --json`): KILLED (a test matching the killer pattern, or its suite's setUp, fails on the
mutant) | SURVIVED | INVALID (does not compile; not counted as killed) | ERROR (no test matched the killer, or the run
produced no result: never counted as killed) | BAD-PATTERN (the find string is not unique in the file) | BAD-KILLER
(the named killer fails on the clean tree) | PENDING (no code or no killing test yet). Exit 0 only if the list is
non-empty and every selected mutant is KILLED.

EQUIVALENT (a stored status, not a verdict): `"status": "EQUIVALENT"` with a non-empty `"reason"` naming the mutated
line and why no input distinguishes it other than gas, or why no line exists to mutate (spec §9.2,
`internal/reviews/mutation-survivors.md`), and `"anchors": [{"file": "src/...", "find": "<code>"}]`, the code its
premise rests on. Such an entry must stay unwired; it is never selected or run, it is outside the kill-rate denominator
(reported on its own line), `--write` never changes it and `--audit` counts it apart from the pending ones. `--audit`
fails on one without a reason, without anchors, wired, or with an anchor whose code does not match its file exactly
once (so an edit to the premise forces the reason to be re-checked); `--since` names an EQUIVALENT entry whose anchor
file changed as "re-check reason".

A mutant's basis is a hash of what its verdict depends on: the function containing its find string; the files that
define its killer and every test/ or script/ file they import, transitively; `foundry.toml`; every file under
src/libraries/, src/types/ and src/interfaces/ (inlined into the contracts); and `remappings.txt` plus the pinned
Touchstone commit (`git -C lib/touchstone rev-parse HEAD`), because every F-layer killer deploys a real Touchstone.
A change elsewhere in a contract is not in the basis: the close rule (`--since`) re-runs every mutant of a changed
file. Full campaigns still run at each phase close, at the freeze and after any structural move; the public kill rate
comes from one full run at one commit.

Memory guard: one `forge test` + solc peaks near 12 GB on this 16 GB machine; Touchstone's `-j 4` (~48 GB) pushed
macOS into a watchdog kernel panic twice (2026-11-17). Reagent therefore runs ONE worker only: `-j N` with N > 1 is
refused (exit 2). Before each mutant the runner checks swap use: more than TS_MUTATE_MAX_SWAP_GROWTH_GB (default 4)
above the swap in use at the start, or above TS_MUTATE_MAX_SWAP_GB (default 14) in total, it waits up to 2 minutes
for it to drop, then stops handing out mutants. The unstarted ones are reported ABORTED (never counted as killed,
never written by --write) and the run exits 1. TS_MUTATE_NO_MEM_GUARD=1 disables the swap check (never the -j 1 rule).
A run is one heavy job: never start one while another forge/solc job runs, and never auto-restart an interrupted one.

After each mutant the runner deletes the invariant counterexamples its run wrote under cache/invariant/failures/
(files new or changed during that run; F-056: a killed mutant's counterexamples otherwise stop the next clean
`forge test`), and a KILLED verdict's detail names the failing tests with forge's reason (P5-Ad-02)."""
import hashlib, json, os, re, shutil, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# TS_MUTANTS_LIST points at another list (the serial/parallel equivalence check uses a list with a known no-op)
LIST = os.environ.get('TS_MUTANTS_LIST') or os.path.join(ROOT, 'audits', 'mutants.json')
MARK = os.path.join(ROOT, 'output', 'MUTATION_IN_PROGRESS')


def load():
    doc = json.load(open(LIST)) if os.path.exists(LIST) else {}
    muts = doc.get('mutants', []) if isinstance(doc, dict) else []
    if not muts:
        print('mutate: the mutant list is empty; refusing to report a vacuous pass')
        sys.exit(1)
    return doc, muts


def equivalent(m):
    return m.get('status') == 'EQUIVALENT'


def wired(m):
    return not equivalent(m) and bool(m.get('file') and m.get('find') is not None and m.get('replace') is not None
                and m.get('kill') and m['kill'] != 'pending')


def audit(muts):
    tags = {}
    for d, _, fs in os.walk(os.path.join(ROOT, 'src')):
        for f in fs:
            if f.endswith('.sol'):
                p = os.path.relpath(os.path.join(d, f), ROOT)
                for t in re.findall(r'\[(MU-\d+)\]', open(os.path.join(ROOT, p)).read()):
                    tags.setdefault(t, set()).add(p)
    ids = {m['id']: m for m in muts}
    errs = [f'tag without a mutant: {t}' for t in sorted(set(tags) - set(ids))]
    for m in muts:
        if m.get('file') and m['file'] not in tags.get(m['id'], set()):
            errs.append(f"mutant without its tag in {m['file']}: {m['id']}")
    # every wired mutant's find string matches its file exactly once (a stale or ambiguous pattern is not a kill)
    for m in muts:
        if wired(m):
            n = open(os.path.join(ROOT, m['file'])).read().count(m['find'])
            if n != 1:
                errs.append(f"find string matches {n} times in {m['file']}: {m['id']}")
    # every wired mutant's killer pattern names at least one test (a pattern matching nothing is never a kill)
    names = _test_names()
    for m in muts:
        if wired(m) and not any(re.search(m['kill'], n) for n in names):
            errs.append(f"killer pattern matches no test: {m['id']} {m['kill']}")
    # an EQUIVALENT entry carries its reason and stays unwired (it is never run, so a mutation on it would be untested)
    for m in muts:
        if equivalent(m):
            if not str(m.get('reason') or '').strip():
                errs.append(f"EQUIVALENT without a reason: {m['id']}")
            if m.get('file') or m.get('find') is not None or m.get('replace') is not None or \
                    (m.get('kill') not in (None, 'pending')):
                errs.append(f"EQUIVALENT entry is wired (file/find/replace/kill set): {m['id']}")
            anchors = m.get('anchors') or []
            if not anchors:
                errs.append(f"EQUIVALENT without anchors: {m['id']}")
            for a in anchors:
                fp = os.path.join(ROOT, a.get('file') or '')
                n = open(fp).read().count(a.get('find') or '\0') if a.get('file') and os.path.isfile(fp) else 0
                if n != 1:
                    errs.append(f"EQUIVALENT anchor matches {n} times in {a.get('file')}: {m['id']} (re-check the reason)")
    eq = sum(1 for m in muts if equivalent(m))
    pending = sum(1 for m in muts if not wired(m) and not equivalent(m))
    for e in errs:
        print(e)
    print(f'audit: {len(muts)} mutants, {len(muts) - pending - eq} wired, {eq} equivalent (outside the denominator), '
          f'{pending} pending;', 'OK' if not errs else 'FAIL')
    return not errs


# ------------------------------------------------------------------ the basis (what a verdict depends on)

def _read(p):
    try:
        return open(os.path.join(ROOT, p)).read()
    except OSError:
        return ''


def _test_files():
    out = []
    for d, _, fs in os.walk(os.path.join(ROOT, 'test')):
        out += [os.path.relpath(os.path.join(d, f), ROOT) for f in fs if f.endswith('.sol')]
    return sorted(out)


def _test_names():
    names = set()
    for f in _test_files():
        names |= set(re.findall(r'function (test\w*|invariant\w*)\s*\(', _read(f)))
    return names


def _function_text(src, idx):
    """The function, modifier or constructor enclosing `idx` (the whole file if none does)."""
    starts = [m.start() for m in re.finditer(r'^[ \t]*(function|modifier|constructor)\b', src, re.M) if m.start() <= idx]
    if not starts:
        return src
    s = starts[-1]
    b = src.find('{', s)
    if b < 0 or b > idx and src.find(';', s) < b:
        return src
    depth = 0
    for i in range(b, len(src)):
        depth += {'{': 1, '}': -1}.get(src[i], 0)
        if depth == 0:
            return src[s:i + 1] if i >= idx else src
    return src


def _named_function(src, name):
    m = re.search(r'^[ \t]*function ' + re.escape(name) + r'\s*\(', src, re.M)
    return _function_text(src, src.index('{', m.start())) if m else ''


def _killer_files(kill):
    """The files defining the killer, plus every test/ or script/ file they import, transitively (src/ is covered by
    the function, library and hot-path parts of the basis)."""
    files = [f for f in _test_files() if any(re.search(kill, n)
                                              for n in re.findall(r'function (\w+)\s*\(', _read(f)))]
    deps, todo = set(files), list(files)
    while todo:
        f = todo.pop()
        for imp in re.findall(r'import\s+[^;]*?"(\.[^"]+)"', _read(f)):
            p = os.path.normpath(os.path.join(os.path.dirname(f), imp))
            if (p.startswith('test' + os.sep) or p.startswith('script' + os.sep)) and p not in deps:
                deps.add(p)
                todo.append(p)
    return sorted(deps)


def _tree_files(*dirs):
    out = []
    for d0 in dirs:
        for d, _, fs in os.walk(os.path.join(ROOT, d0)):
            out += [os.path.relpath(os.path.join(d, f), ROOT) for f in fs if f.endswith('.sol')]
    return sorted(out)


def basis_parts(m):
    """(the files the basis reads, the hash). Files are repo-relative."""
    h = hashlib.sha256()
    src = _read(m['file'])
    i = src.find(m['find'])
    h.update(b'fn:' + _function_text(src, i if i >= 0 else 0).encode())
    files = [m['file']]
    kf = _killer_files(m['kill'])
    for f in kf:
        h.update(f'killer:{f}:'.encode() + _read(f).encode())
    files += kf
    extra = ['foundry.toml', 'remappings.txt']
    extra += _tree_files('src/libraries', 'src/types', 'src/interfaces')
    for f in extra:
        h.update(f'dep:{f}:'.encode() + _read(f).encode())
    files += extra
    pin = subprocess.run(['git', '-C', os.path.join(ROOT, 'lib', 'touchstone'), 'rev-parse', 'HEAD'],
                         capture_output=True, text=True).stdout.strip()
    h.update(b'touchstone:' + pin.encode())
    return files, h.hexdigest()[:16]


# ------------------------------------------------------------------ running one mutant

MUTANT_TIMEOUT_S = int(os.environ.get('TS_MUTATE_TIMEOUT_S', '900'))  # PROCESS §8: no run over 1 h (tools review m-1)


def forge(args, cwd=ROOT):
    try:
        return _forge(args, cwd)
    except subprocess.TimeoutExpired:
        return None


def _forge(args, cwd=ROOT):
    return subprocess.run(['forge', 'test', '--json'] + args, cwd=cwd, capture_output=True, text=True, timeout=MUTANT_TIMEOUT_S,
                          env={**os.environ, 'TS_MUTATION_RUN': '1',
                               'FOUNDRY_PROFILE': os.environ.get('FOUNDRY_PROFILE', 'mutation')})


def compile_error(r):
    out = (r.stdout + r.stderr).lower()
    return 'compiler run failed' in out or 'error (' in out or 'compilation failed' in out


def verdict(r, kill, full):
    """KILLED / SURVIVED / INVALID / ERROR / TIMEOUT from a `forge test --json` run (TIMEOUT: never a kill)."""
    if r is None:
        return 'TIMEOUT'
    if compile_error(r):
        return 'INVALID'
    raw = r.stdout
    try:
        res = json.loads(raw[raw.index('{'):])
    except ValueError:
        return 'ERROR'
    matched, failed = 0, 0
    for _, suite in res.items():
        tr = suite.get('test_results', {})
        setup_failed = any(n.startswith('setUp') and t.get('status') == 'Failure' for n, t in tr.items())
        for n, t in tr.items():
            if full or re.search(kill, n) or (setup_failed and n.startswith('setUp')):
                matched += 1
                failed += t.get('status') == 'Failure'
    if matched == 0:
        return 'ERROR'
    return 'KILLED' if failed else 'SURVIVED'


def failing(r, kill, full, limit=3):
    """The failing matched tests with forge's reason (P5-Ad-02), e.g. `test_x: assertion failed`; at most `limit`."""
    if r is None:
        return []
    raw = r.stdout
    try:
        res = json.loads(raw[raw.index('{'):])
    except ValueError:
        return []
    out = []
    for _, suite in res.items():
        for n, t in suite.get('test_results', {}).items():
            if t.get('status') == 'Failure' and (full or re.search(kill, n) or n.startswith('setUp')):
                out.append(f"{n}: {str(t.get('reason') or 'no reason').strip()[:120]}")
    return sorted(out, key=lambda x: (not x.startswith('setUp'), x))[:limit]   # a setUp failure first (S27F-07)


FAILURES = os.path.join('cache', 'invariant', 'failures')


def _failure_files(root):
    d = os.path.join(root, FAILURES)
    out = {}
    for dd, _, fs in os.walk(d):
        for f in fs:
            p = os.path.join(dd, f)
            out[p] = os.stat(p).st_mtime_ns
    return out


def drop_new_failures(root, before):
    """Deletes the invariant counterexamples a mutant's run wrote (F-056): files that are new or changed since
    `before`, a snapshot from `_failure_files`. Files that existed unchanged are left alone. Returns the count."""
    n = 0
    for p, t in _failure_files(root).items():
        if before.get(p) != t:
            os.remove(p)
            n += 1
    return n


def restore_leftovers(root=ROOT):
    """Restores any file left mutated by an interrupted run (its `.mutorig` backup is the original)."""
    for d, _, fs in os.walk(os.path.join(root, 'src')):
        for f in fs:
            if f.endswith('.mutorig'):
                orig = os.path.join(d, f)
                os.replace(orig, orig[:-len('.mutorig')])
                print('restored', orig[:-len('.mutorig')])


def run_one(m, root, full, clean_ok):
    k = m['kill']
    if not full and not clean_ok(k, root):
        return (m['id'], 'BAD-KILLER', f"{m['desc']} [{k} fails on the clean tree]")
    f = os.path.join(root, m['file'])
    src = open(f).read()
    n = src.count(m['find'])
    if n != 1:
        return (m['id'], f'BAD-PATTERN({n})', m['desc'])
    # atomic backup: a kill mid-write never leaves a truncated original (tools review m-4)
    open(f + '.mutorig.tmp', 'w').write(src)
    os.replace(f + '.mutorig.tmp', f + '.mutorig')
    open(f, 'w').write(src.replace(m['find'], m['replace']))
    before = _failure_files(root)
    try:
        t = time.time()
        r = forge(['--nmp', 'test/fork/*'] if full else ['--mt', k], cwd=root)
        v = verdict(r, k, full)
        fl = failing(r, k, full, limit=50) if v == 'KILLED' else []
        why = '; '.join(fl[:3])
        # a kill by setUp alone may be a broken deployment, not the rule: flagged for triage (P5-Ad-02, S27F-07)
        tag = ' (setUp)' if fl and all(x.startswith('setUp') for x in fl) else ''
        return (m['id'], v, f"{m['desc']} [{'full' if full else k}] {time.time() - t:.0f}s{tag}" + (f' <{why}>' if why else ''))
    finally:
        open(f, 'w').write(src)
        if os.path.exists(f + '.mutorig'):
            os.remove(f + '.mutorig')
        dropped = drop_new_failures(root, before)
        if dropped:
            print(f"{m['id']}: deleted {dropped} invariant counterexample(s) written by the mutant's run (F-056)")


# ------------------------------------------------------------------ selection

def git(*a):
    return subprocess.run(['git'] + list(a), cwd=ROOT, capture_output=True, text=True)


def select_changed(muts):
    return [m for m in muts if wired(m) and m.get('basis') != basis_parts(m)[1]]


def select_since(muts, rev):
    r = git('diff', '--name-only', rev)
    if r.returncode != 0:
        print('mutate --since:', r.stderr.strip())
        sys.exit(2)
    changed = set(r.stdout.split()) | set(git('ls-files', '--others', '--exclude-standard').stdout.split())
    sel = []
    for m in muts:
        if wired(m) and (set(basis_parts(m)[0]) & changed or m.get('basis') != basis_parts(m)[1]):
            sel.append(m)
        if equivalent(m) and {a.get('file') for a in m.get('anchors') or []} & changed:
            print(f"{m['id']} | EQUIVALENT | re-check reason: an anchor file changed since {rev}")
    return sel


def split_equivalent(sel):
    """(the mutants to run or report, the EQUIVALENT ones): an EQUIVALENT entry is never run or counted."""
    return [m for m in sel if not equivalent(m)], [m for m in sel if equivalent(m)]


def apply_write(muts, res):
    """Stores each run verdict. ABORTED keeps the previous status and basis; an EQUIVALENT entry is never changed."""
    st = {r[0]: r[1] for r in res if r[1] != 'ABORTED'}  # not run: keep its previous status and basis
    for m in muts:
        if m['id'] in st and not equivalent(m):
            m['status'] = st[m['id']]
            if st[m['id']] == 'KILLED':
                m['basis'] = basis_parts(m)[1]
            else:
                m.pop('basis', None)


FLAGS = ('--audit', '--full', '--write', '--changed', '--selftest')

# ------------------------------------------------------------------ memory guard (see the docstring)
GUARD = os.environ.get('TS_MUTATE_NO_MEM_GUARD') != '1'
GB = 1024 ** 3


def _sysctl(name):
    try:
        return subprocess.run(['sysctl', '-n', name], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ''


def ram_bytes():
    v = _sysctl('hw.memsize')
    if v.isdigit():
        return int(v)
    try:
        return os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PHYS_PAGES')
    except (ValueError, OSError, AttributeError):
        return 0


def swap_used_bytes():
    """macOS: `vm.swapusage` = 'total = 2048.00M  used = 1741.06M  free = ...'; Linux: /proc/meminfo. None = unknown."""
    m = re.search(r'used = ([\d.]+)([MG])', _sysctl('vm.swapusage'))
    if m:
        return float(m.group(1)) * (GB if m.group(2) == 'G' else 1024 ** 2)
    try:
        info = dict(l.split(':', 1) for l in open('/proc/meminfo'))
        return (int(info['SwapTotal'].split()[0]) - int(info['SwapFree'].split()[0])) * 1024
    except (OSError, KeyError, ValueError):
        return None


_SWAP_BASE = []


def memory_ok(wait_s=120, step_s=10):
    """False when swap stays above the limit for wait_s: the caller stops starting new forge runs. The limit is
    relative to the swap in use when the campaign started (macOS keeps several GB swapped out at idle), plus an
    absolute ceiling."""
    if not GUARD:
        return True
    if not _SWAP_BASE:
        _SWAP_BASE.append(swap_used_bytes() or 0)
    growth = float(os.environ.get('TS_MUTATE_MAX_SWAP_GROWTH_GB', '4')) * GB
    ceiling = float(os.environ.get('TS_MUTATE_MAX_SWAP_GB', '14')) * GB
    limit = min(_SWAP_BASE[0] + growth, ceiling)
    waited = 0
    while True:
        used = swap_used_bytes()
        if used is None or used <= limit:
            return True
        if waited >= wait_s:
            print(f'mutate: memory guard: swap {used / GB:.1f} GB > {limit / GB:.0f} GB for {wait_s}s; '
                  f'not starting more mutants', flush=True)
            return False
        time.sleep(step_s)
        waited += step_s


def main(argv):
    if any(a in ('-h', '--help') for a in argv):
        print(__doc__)
        return 0
    jobs, since, rest, i = 1, None, [], 0
    while i < len(argv):
        a = argv[i]
        if a == '-j' and i + 1 < len(argv):
            jobs, i = int(argv[i + 1]), i + 2
            continue
        if a == '--since' and i + 1 < len(argv):
            since, i = argv[i + 1], i + 2
            continue
        rest.append(a)
        i += 1
    argv = rest
    bad = [a for a in argv if a.startswith('-') and a not in FLAGS]
    if bad:
        # an unknown flag must never fall through to "all mutants" (a campaign that mutates src/)
        print('mutate: unknown option', ' '.join(bad), '; known:', ' '.join(FLAGS), '-j N --since REV')
        return 2
    if jobs != 1:
        print(f'mutate: -j {jobs} refused: Reagent runs one worker only (PROCESS §6, §8 memory rule)')
        return 2
    if '--selftest' in argv:
        return selftest()
    doc, muts = load()
    if '--audit' in argv:
        return 0 if audit(muts) else 1
    if os.path.exists(MARK):
        try:
            pid = int(open(MARK).read().strip() or 0)
            os.kill(pid, 0)
            print(f'mutate: another campaign (pid {pid}) is running on this tree; refusing to start')
            return 1
        except PermissionError:
            print(f'mutate: another campaign is running on this tree (no permission to signal it); refusing to start')
            return 1
        except (ValueError, ProcessLookupError):
            print('mutate: removing a stale', MARK)
    restore_leftovers()
    full = '--full' in argv
    args = [a for a in argv if not a.startswith('--')]
    if since:
        sel = select_since(muts, since)
    elif '--changed' in argv:
        sel = select_changed(muts)
    else:
        sel = [m for m in muts if not args or m['id'] in args]
    if args and (since or '--changed' in argv):
        sel = [m for m in sel if m['id'] in args]
    sel, eqs = split_equivalent(sel)
    for m in eqs:
        print(f"{m['id']} | EQUIVALENT (not run; outside the denominator) | {m.get('reason', '')}")
    if not sel:
        print('mutate: no mutant selected' + (' (no basis changed)' if since or '--changed' in argv else ''))
        return 0 if (since or '--changed' in argv) else 1
    print(f'mutate: {len(sel)} mutants selected, 1 worker')
    if full and any(wired(m) for m in sel):
        if forge(['--nmp', 'test/fork/*']).returncode != 0:
            print('mutate --full: the clean suite is red; refusing to run')
            return 1
    os.makedirs(os.path.dirname(MARK), exist_ok=True)
    open(MARK, 'w').write(str(os.getpid()))
    res = []
    # every killer passes on the clean tree first, checked once in the (unmutated, warm) main tree before any mutation
    cache = {}
    todo = [m for m in sel if wired(m)]
    if not full:
        for k in sorted({m['kill'] for m in todo}):
            cache[k] = verdict(forge(['--mt', k]), k, False) == 'SURVIVED'

    def clean_ok(k, root):
        return cache[k]

    try:
        res += [(m['id'], 'PENDING', m['desc']) for m in sel if not wired(m)]
        stop = []

        def gated(m, root):
            if stop or not memory_ok():
                stop.append(1)
                return (m['id'], 'ABORTED', 'memory guard: not run')
            return run_one(m, root, full, clean_ok)

        for m in todo:
            res.append(gated(m, ROOT))
            print(' | '.join(res[-1]), flush=True)
    finally:
        os.remove(MARK)
        restore_leftovers()
    print('---')
    for r in res:
        print(' | '.join(r))
    killed = sum(1 for r in res if r[1] == 'KILLED')
    print(f'killed {killed}/{len(res)}')
    if eqs:
        print(f'equivalent (outside the denominator): {len(eqs)}')
    if '--write' in argv:
        apply_write(muts, res)
        open(LIST, 'w').write(json.dumps(doc, indent=1, ensure_ascii=False) + '\n')
    return 0 if res and killed == len(res) else 1


class _R:
    def __init__(self, out, err=''):
        self.stdout, self.stderr = out, err


def selftest():
    """A control per verdict form the runner claims to see (P-17): KILLED, SURVIVED, ERROR, INVALID, setUp kill,
    -j refusal, unknown flag refusal, and the audit's tag/find checks on a scratch tree."""
    ok = True

    def eq(name, got, want):
        nonlocal ok
        if got != want:
            ok = False
            print(f'selftest FAIL {name}: got {got!r} want {want!r}')

    def js(tests):
        return json.dumps({'t/A.t.sol:A': {'test_results': {n: {'status': s} for n, s in tests.items()}}})
    eq('killed', verdict(_R(js({'test_X__a': 'Failure', 'test_Y': 'Success'})), 'test_X', False), 'KILLED')
    eq('survived', verdict(_R(js({'test_X__a': 'Success', 'test_Y': 'Failure'})), 'test_X', False), 'SURVIVED')
    eq('error-nomatch', verdict(_R(js({'test_Y': 'Failure'})), 'test_X', False), 'ERROR')
    eq('error-nojson', verdict(_R('garbage'), 'test_X', False), 'ERROR')
    eq('invalid', verdict(_R('', 'Error (1234): Compiler run failed'), 'test_X', False), 'INVALID')
    eq('setup-kill', verdict(_R(js({'setUp()': 'Failure', 'test_X__a': 'Success'})), 'test_X', False), 'KILLED')
    eq('full', verdict(_R(js({'test_Y': 'Failure'})), 'nomatch', True), 'KILLED')
    eq('timeout', verdict(None, 'test_X', False), 'TIMEOUT')
    eq('j4-refused', main(['-j', '4', 'MU-001']), 2)
    eq('flag-refused', main(['--bogus']), 2)
    # the audit on a scratch tree: a tag without a mutant, a mutant without its tag, an ambiguous find
    import tempfile
    global ROOT
    old = ROOT
    with tempfile.TemporaryDirectory() as d:
        ROOT = d
        os.makedirs(os.path.join(d, 'src')); os.makedirs(os.path.join(d, 'test'))
        open(os.path.join(d, 'src', 'C.sol'), 'w').write('a = 1; // [MU-001]\nb = 1; b = 1; // [MU-003]\n')
        open(os.path.join(d, 'test', 'C.t.sol'), 'w').write('function test_C__x() public {}\n')
        base = dict(area='x', desc='d', killer_id=None, file='src/C.sol', kill='test_C__x')
        eq('audit-ok', audit([dict(base, id='MU-001', find='a = 1;', replace='a = 2;'),
                              dict(base, id='MU-003', find='b = 1; b', replace='b')]), True)
        eq('audit-orphan-tag', audit([dict(base, id='MU-001', find='a = 1;', replace='a = 2;')]), False)
        eq('audit-ambiguous', audit([dict(base, id='MU-001', find='a = 1;', replace='a = 2;'),
                                     dict(base, id='MU-003', find='b = 1;', replace='b = 2;')]), False)
        eq('audit-no-killer', audit([dict(base, id='MU-001', find='a = 1;', replace='a = 2;', kill='test_Nope'),
                                     dict(base, id='MU-003', find='b = 1; b', replace='b')]), False)
        eq('audit-missing-tag', audit([dict(base, id='MU-001', find='a = 1;', replace='a = 2;'),
                                       dict(base, id='MU-003', find='b = 1; b', replace='b'),
                                       dict(base, id='MU-004', find='a = 1;', replace='a = 3;')]), False)
    ROOT = old
    print('selftest', 'OK' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
