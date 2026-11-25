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
    ('L-CRON: the Cron filter may stay active', "row['backToBaseline'] = fid not in active_now and row['beforeMatchesPreflight']", "row['backToBaseline'] = row['beforeMatchesPreflight']", None),
    ('L-CRON: history consistency dropped', "and row['beforeMatchesPreflight'] and row['historyConsistent']", "and row['beforeMatchesPreflight']", None),
    ('L-CRON: the pre-flight count not checked', "row['beforeMatchesPreflight'] = len(before) == PREFLIGHT_ACTIVE", "row['beforeMatchesPreflight'] = True", None),
    ('L-CRON: the backwards rebuild inverted', "(on.discard if h_['kind'] == 'Subscribe' else on.add)(h_['filterId'])", "(on.add if h_['kind'] == 'Subscribe' else on.discard)(h_['filterId'])", None),
    ('L-CRON: one interval not required', "row['oneInterval'] = [k for k, _ in row['cronIntervals']] == ['Subscribe', 'Unsubscribe']", "row['oneInterval'] = True", None),
    ('hub_entry: every error retried', "            if 'not available' not in last and 'does not exist' not in last:\n                raise", "            if False:\n                raise", None),
    ('L-GAS: an EARLY exit fills its cell', "fills = ok and (kind not in ('exit', 'plan') or outcome == 1)", "fills = ok", None),
    ('L-CRON: other changes not attributed', "'backToBaseline', 'othersNotCron'))", "'backToBaseline'))", None),
    ('hero: the pause-before check dropped', "pausedBefore=r.get('pausedBefore') is False,", 'pausedBefore=True,', None),
    ('hero: any refusal error accepted', "hubPaused=r.get('refusedSelector') == HUB_PAUSED,", 'hubPaused=True,', None),
    ('hero: the nonce adjacency dropped', "noSendBetween=r.get('lastOkNonce') is not None and r.get('refusedNonce') == r['lastOkNonce'] + 1,", 'noSendBetween=True,', None),
    ('hero: the order not checked', "and r['lastOkTs'] < r['originTs'] <= r['appliedTs'] <= r['refusedTs'])", "and True)", None),
    ('plan: any SKIPPED reason accepted', "r['outcome'] == PLAN_SKIPPED and r['reason'] == SKIP_PAUSED and", "r['outcome'] == PLAN_SKIPPED and", None),
    ('plan: requests of another RC counted', "and int(l['topics'][2], 16) == int(RC, 16)\n", "\n", None),
    ('plan: the proxy not required', "d = [r for r in rows if r.get('delivered') and r.get('byProxy')]", "d = [r for r in rows if r.get('delivered')]", None),
    ('exit: the drip end not required', "afterDrip=r.get('doneBlock') is not None and r.get('dripEnd') is not None and r['doneBlock'] >= r['dripEnd'],", 'afterDrip=True,', None),
    ('exit: other recipients ignored', "noOtherRecipient=r.get('otherRecipients') == [])", 'noOtherRecipient=True)', None),
    ('hero: the proving send not indexed', "AGENT_SENDS = ('allocate', 'prove-refusal')", "AGENT_SENDS = ('allocate',)", None),
    ('hero: the curator binding dropped', "sameCurator=r.get('refusedVaultId') is not None and r.get('refusedVaultId') == r.get('curator'),", 'sameCurator=True,', None),
    ('exit: the value not required', "valueMeasured=(r.get('forfeitPoolAtProcess') or 0) > 0 and (r.get('poolBurned') or 0) > 0", 'valueMeasured=True or (r.get("x") or 0) > 0', None),
    ('not-carried verdicts ignored', '        if not lx and not_carried(tr):', '        if False:', None),
]

# Hand mutants of script/live/drive.py, each of which `drive.py --selftest` must kill (s8: the gas margin; the s7-close
# r1 M-02/M-03 rules)
DRIVE_MUTANTS = [
    ('drive: the send carries no gas limit', "*wallet(), '--rpc-url', rpc(ch), '--gas-limit', str(lim), to, sig,",
     "*wallet(), '--rpc-url', rpc(ch), to, sig,", None),
    ('drive: no margin over the estimate', 'GAS_MARGIN = (3, 2)', 'GAS_MARGIN = (1, 1)', None),
    ('drive: the read-back not retried', 'READBACK_TRIES, READBACK_WAIT = 4, 4', 'READBACK_TRIES, READBACK_WAIT = 1, 4', None),
    ('drive: no ref-back on an abnormal stop', "        print(f'drive: the breach run stopped abnormally: bringing the reference back (else run: ref-back {name})')\n        ref_back(name, False, step)\n", "        print(f'drive: the breach run stopped abnormally: bringing the reference back (else run: ref-back {name})')\n", None),
    ('drive: a foreign latch tx not recorded', "            record(ch, step, 'latch',", "            pass\n            if False: record(ch, step, 'latch',", None),
    ('drive: no Sepolia floor', "GAS_FLOOR = {'1301': 2_000_000, '11155111': 4_000_000}", "GAS_FLOOR = {'1301': 2_000_000, '11155111': 0}", None),
    ('drive: the gap-record bound ignored', '    if 1 < len(mine) <= n_max:', '    if 1 < len(mine):', None),
    ('drive: ok without the expected log', '    ok = ok and len(mine) == 1  #', '    ok = ok or len(mine) == 1  #', None),
]


def main():
    src = open(os.path.join(ROOT, 'script', 'live', 'loops.py')).read()
    dsrc = open(os.path.join(ROOT, 'script', 'live', 'drive.py')).read()
    bad = 0
    with tempfile.TemporaryDirectory() as t:
        os.makedirs(os.path.join(t, 'script', 'live'))
        for d in ('rnk', 'deploy'):
            shutil.copytree(os.path.join(ROOT, 'script', d), os.path.join(t, 'script', d))
        for d in ('audits', 'src'):
            shutil.copytree(os.path.join(ROOT, d), os.path.join(t, d))
        env = {k: v for k, v in os.environ.items() if 'RPC' not in k}
        for name, a, b, equiv in MUTANTS + DRIVE_MUTANTS:
            fname = 'drive.py' if name.startswith('drive:') else 'loops.py'
            text = dsrc if fname == 'drive.py' else src
            if text.count(a) != 1:
                print(f'toolmut: ANCHOR LOST ({text.count(a)}): {name}')
                bad += 1
                continue
            for f_, t_ in (('loops.py', src), ('drive.py', dsrc)):
                open(os.path.join(t, 'script', 'live', f_), 'w').write(t_)
            open(os.path.join(t, 'script', 'live', fname), 'w').write(text.replace(a, b))
            r = subprocess.run([sys.executable, os.path.join(t, 'script', 'live', fname), '--selftest'],
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
