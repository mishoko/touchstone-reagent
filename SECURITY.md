# Security

Reagent runs on testnets only (Unichain Sepolia, Ethereum Sepolia, Reactive Lasna) with mock tokens. It has not
had an external audit. If you find a problem, open an issue or a private security advisory on this repository.

## What we promise, and the test that holds us to it

| Invariant | In plain words | Tests |
|---|---|---|
| I-OWN | Tokens leave a Covenant only to its owner or into a vault on the same chain. | invariant + `A-` cells |
| I-AUTH | A callback with the wrong proxy, sender or first word reverts and changes nothing. | A-SPOOF-PROXY, A-SPOOF-RC, A-SPOOF-WORD, live L-SPOOF |
| I-IDEM | Replaying a callback changes nothing after its first application. | A-REPLAY |
| I-LEAVE | `leave()` works whenever Touchstone's `withdraw` would, in every Covenant, Hub or RC state. | T-LEAVE-MATRIX (differential against a twin EOA) |
| I-TIGHT | The agent key never loosens a rule, raises a budget or moves the drip end earlier. | A-AGENT-LOOSEN, A-TIGHTEN-RESPLIT |
| I-MONO | The Hub's conduct mirror never goes down. | A-LATEPAUSE |
| I-STALE | An exit withdraws only if you are still paused for that curator when it arrives. | A-STALE |
| I-CAP, I-B6SUM | Cross-chain budgets stay within your cap under any delivery order, loss or duplicate, except for exposure already spent before you tighten (and a raise already in flight when you tighten, which the next update lowers). | A-B6LAG, A-B6-CLAWBACK, R-B6SCHED |

Every attack test asserts that the attack loses, and has a twin positive control that shows the same attack
winning once the defence is removed (for the exit sandwich, the control is a price-based exit, which loses
more to the same sandwich). Every defence line carries a `// [MU-xxx]` tag and a mutant in
`audits/mutants.json` that its named test must kill (141 of 141 killable mutants are killed; 7 are equivalent).

## Who you trust

- **Reactive's operators** deliver events and callbacks and write the requesting RC's address into each
  callback. A compromised operator set could pause you or delay you. Before a B7 or B3 exit the Covenant
  re-checks the breach locally, so a forged log cannot make you exit a healthy vault on those rules. A B2
  (opt-in contagion) exit skips that re-check by design; it still pays only you, in kind. A compromised operator
  set could also trigger your standing plan's deposits (within the plan cap, into a vault you already hold) or
  move your B6 budget between chains (within your cap). It cannot send your tokens anywhere but to you or into
  a vault on the same chain.
- **The RC owner** registers curators, bundlers, factories and Hubs (write-once) and may set a callback gas
  limit within fixed bounds (never below what the callback needs). The RC code has no upgrade path.
- **The factory admin** controls the demo's Covenant allowlist, never funds or rules.
- **Touchstone** at the pinned commit `b893fc6`.

## Known limits

- During a Reactive lag the other chain can still accept an allocation: a missed protection, never a loss of
  funds.
- A third party's reactive contract can make a Hub pay for callbacks the Hub then rejects (seen live in
  L-SPOOF). Each Hub keeps a small balance for fees and holds no tokens.
- A Hub or the RC in debt stops delivery. Local guards and `leave()` keep working.
- Events need vault activity; an idle vault emits nothing.
