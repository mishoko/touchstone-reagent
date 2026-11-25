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
    # r3's reviewer-supplied set (s7 loops r3 M-01's standing check: a reviewer's mutants join the author's)
    ('stats verdict always true', "'pass': len(rs) >= 50 and len(batches) >= 3,", "'pass': True,", None),
    ('stats verdict drops the 3-batch rule', "'pass': len(rs) >= 50 and len(batches) >= 3,", "'pass': len(rs) >= 50,", None),
    ('an L-GAS row passes without its outcome', 'ok = gas == want[\'gasLimit\'] and not err and entry >= thr and good',
     'ok = gas == want[\'gasLimit\'] and not err and entry >= thr', None),
    ('an L-GAS cell locks to its first delivery', '            if fills:\n                seen.add((ch, kind))',
     '            seen.add((ch, kind))', None),
    ('outcome: any note count accepted', '    if len(outs) != 1:', '    if not outs:', None),
    ('outcome: the note-kind filter removed', "and int(l['topics'][3], 16) in (2, 3):", ':', None),
    ('outcome: Stale from any address', "    if any(l['address'].lower() == h and l['topics'][0] == T_STALE for l in r['logs']):",
     "    if any(l['topics'][0] == T_STALE for l in r['logs']):", None),
    ('reaction: the status check removed', "    if int(r['status'], 16) != 1:\n        raise SystemExit(f'loops: the reaction {lasna_tx} failed')",
     '', None),
    ('reaction: the payload-length check removed', 'if payload[:8] != SEL_CONDUCT or plen != 4 + 6 * 32:',
     'if payload[:8] != SEL_CONDUCT:', None),
    ('reaction: the RC-topic check removed', " or int(l['topics'][2], 16) != int(RC, 16):", ':', None),
    ('reaction: the duplicate-destination check removed', '        if dest in sends:', '        if False:', None),
    ('lasna_block_at: < becomes <=', 'lo, hi = (mid, hi) if bt(mid) < t else (lo, mid)', 'lo, hi = (mid, hi) if bt(mid) <= t else (lo, mid)', None),
    ('lasna_block_at: the era guard removed', '    if bt(lo) >= t:', '    if False:', None),
    ('the cross-chain search starts at the origin block', 'fb = ob if dest == ch else', 'fb = ob if True else', None),
    ('lasna_scan: the SYSTEM check removed', """        for t in blk.get('transactions', []):
            if (t.get('to') or '').lower() != SYSTEM:
                continue
            w = words(t['input'][10:])
            if len(w) > 13 and (w[12], w[13], w[0]) == tail:""", """        for t in blk.get('transactions', []):
            w = words(t['input'][10:])
            if len(w) > 13 and (w[12], w[13], w[0]) == tail:""", None),
    ('lasna_scan: stops AT t0 + 4 h', "if int(blk['timestamp'], 16) > t0 + TIMEOUT_S:", "if int(blk['timestamp'], 16) >= t0 + TIMEOUT_S:", None),
    ('the callback leg measured from the origin', "'leg_callback_s': t1 - rx['ts']}", "'leg_callback_s': t1 - t0}", None),
    # lspoof r1 M-01
    ('L-SPOOF: the NotRc requirement dropped', "and row['word0IsSpoofRC']\n                   and row['rejectedNotRc'])", "and row['word0IsSpoofRC'])", None),
    ('L-SPOOF: the word-0 requirement dropped', "and row['word0IsSpoofRC']\n                   and row['rejectedNotRc'])", "\n                   and row['rejectedNotRc'])", None),
    ('L-SPOOF: any proxy tx is the delivery', "                    and needle in x['input'].lower()):", "                    ):", None),
    ('L-SPOOF: the operator check dropped', "and (x.get('from') or '').lower() == OPERATOR_1301", '', None),
    ('L-SPOOF: the charge always attributed', "row['chargeAttributable'] = not others", "row['chargeAttributable'] = True", None),
    ('L-SPOOF: debt left out of the charge', "        + (row['debtAfter'] - row['debtBefore'])\n    row['charged']", "\n    row['charged']", None),
    ('L-SPOOF: an unread conduct(99) passes', "row['hubLogs'] == 0 and bool(c99) and all(v == 0 for v in c99)", "row['hubLogs'] == 0 and all(v == 0 for v in (c99 or []))", None),
    # lcron r1 M-03
    ('L-CRON: the subscribe tuple not checked', "row['subscribesCron'] = len(subs_c) == 1 and subs_c[0] == CRON_ARGS", "row['subscribesCron'] = len(subs_c) == 1", None),
    ('L-CRON: the unsubscribe tuple not checked', "row['unsubscribesCron'] = len(uns_c) == 1 and uns_c[0] == CRON_ARGS", "row['unsubscribesCron'] = len(uns_c) == 1", None),
    ('L-CRON: the after-DONE order dropped', "row['unsubscribeAfterDone'] = unsub_ts >= done_ts", "row['unsubscribeAfterDone'] = True", None),
    ('L-CRON: the filter set compared by count', "row['backToBaseline'] = set(active_now) == before", "row['backToBaseline'] = len(active_now) == len(before)", None),
    ('L-CRON: one interval not required', "row['oneInterval'] = [k for k, _ in row['cronIntervals']] == ['Subscribe', 'Unsubscribe']", "row['oneInterval'] = True", None),
    ('hub_entry: every error retried', "            if 'not available' not in last and 'does not exist' not in last:\n                raise", "            if False:\n                raise", None),
    ('L-GAS: an EARLY exit fills its cell', "fills = ok and (kind not in ('exit', 'plan') or outcome == 1)", "fills = ok", None),
    ('not-carried verdicts ignored', '        if not lx and not_carried(tr):', '        if False:', None),
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
