# BH-9465: slow tests no longer drop merge-queue batches
Doc: docs/verification-map/trace-safety.md, docs/ci-durations.md

## Problem

Batch draft #9456, shard 3/17, ran every test at about 2x its usual time.
`tests/lesson-propose.bh-5807-test.sh` (about 570 s traced in a normal batch)
was killed at its 900 s bound. The shard then hit the 45-minute job cap, wrote
no verdict file, and both fan-in checks failed with "shard 3/17 left no
verdict". The same shard spent 460 s on a 44-line share-mirror suite.

## What changed

1. Shard budget (`bin/test-trace-safety.sh --gate`). `TRACE_SAFETY_SHARD_BUDGET_S`
   is the time the whole run may take, from `TRACE_SAFETY_T0`. The running test
   gets at most the time left. Once the budget is spent, no test starts: each
   one prints `NOTRUN <path> (shard budget <B>s spent)`. The verdict file is
   always written, with three more keys: `notrun`, `timeout_names` and
   `notrun_names`. `pure=pass` now also needs `notrun=0`. The script default is
   0 (no budget). CI passes the repo variable `TRACE_SAFETY_SHARD_BUDGET_S`,
   fallback 2400 s (40 of 45 minutes), from a clock step right after checkout
   and setup-node. A traced test runs with the two budget knobs unset.
2. Named fan-ins (`bin/ci-verdicts.sh`). The pure lane names the timed-out and
   not-run tests. The trace lane is red on a not-run test (it was not traced)
   and gives a `::warning::` for a timeout with no hit. The count check adds
   `tests + notrun`. A verdict with the old five keys still parses. A not-run
   test turns the pure lane red even on a verdict that says `pure=pass`.
3. Cheaper share mirror. `bin/share/sanitize.py` `rewrite()` skips a rule when
   the rule's literal needle is not in the current text. A case-insensitive
   rule is never skipped on a text that holds a character re.I can fold onto an
   ASCII needle letter (U+212A, U+017F, U+0130, U+0131). The output is the same
   byte for byte. `bin/ci-share-mirror-warm.sh` builds the mirror once per CI
   shard, untraced, when the shard holds a suite that sources
   `tests/lib/share-mirror.sh`; the traced suites then reuse it.
   `bin/share/leakcheck.py` `scan()` skips `NAME_RE` (one re.I alternation of
   every name, 13.1 of 19.4 s of a scan) on a file whose lower-cased text holds
   no lower-cased name. The same fold guard applies (`NAME_FOLD`). The hit list
   is the same, in the same order. The share suites run leakcheck over the
   mirror, and the mirror ships this file as its own guard's engine.
4. lesson-propose split. The setup is `tests/lib/lesson-propose-fixture.bh-9465.sh`.
   The sections are in four files: `tests/lesson-propose.bh-5807-test.sh`
   (L1-L5), `-cooldown` (L6-L12), `-delivery` (L13-L18) and `-ledger` (L19, K,
   T, the worker node suite). Two causes of the slow run were in the setup:
   - every `node` process that loads the worker test lib wrote a 748 KB
     `jobs-schema-*` dir under the system temp dir and never removed it. One
     run on main left about 9100 of them (6.5 GB freed), and on this box they
     filled the disk. The fixture now gives each node call, the worker's
     `node --test` suite included, a TMPDIR inside the scratch tree;
   - the L19 fixtures put each verdict on its own PR, so each lane tick made
     two hub lookups per PR (400 to 1400 a tick). The triggers count distinct
     verdicts, and no L19 check reads a PR, so `bulk` now spreads the verdicts
     over 5 PRs. The ledger detail holds fp, attempts, blocks, seen (verdict
     ids), target, kind, path, number, url, at and draft, and no PR. With the
     verbatim one-PR-per-verdict fixture the ledger part alone ran over 590 s.

## Numbers (builder box, 8 vCPU, idle, 2026-11-14)

| Item | Before (main ed7c4cf8) | After |
|---|---|---|
| `sanitize.py` over one `git archive` of main (14024 output files) | 253 s | 59 s |
| `leakcheck.py` over that sanitized mirror (clean) | 179 s | 67 s |
| `leakcheck.py` over the raw archive (403 output lines, rc 1) | 284 s | 238 s |
| lesson-propose, untraced | 1458 s, 183 passed (one file) | 47 + 53 + 95 + 54 s, 186 passed (four parts) |
| lesson-propose, traced (`--gate --timings`) | not measured (main's file is 1458 s untraced here) | 54.7 / 62.5 / 105.1 / 59.9 s |

The traced CI numbers (on a runner) were not measured here. In CI the old
file took 563 s to 589 s traced in green batches.

## Proof that the output did not change

- `tests/share-sanitize-prefilter.bh-9465-test.sh`: `rewrite(prefilter=False)`
  against `rewrite()` over 227 files and 1419 adversarial strings, 0 differ.
- One-off: main's `sanitize.py` and the new one over the same `git archive`
  of main: `diff -r` of the two output trees is empty (14024 files), and the
  two stdout reports are the same. `build_rules()` gives the same 235
  (pattern, flags, replacement) rules in the same order; 218 carry a needle.
- One-off: main's `leakcheck.py` and the new one give the same output over
  the raw archive (403 lines, rc 1) and over the mirror (clean).
- `tests/leakcheck-prefilter.bh-9465-test.sh`: `scan(prefilter=False)`
  against `scan()` over a fixture tree (fold twins, CR and CRLF files, bad
  UTF-8) and 2369 files of this checkout (13276 hits): the same list.
- lesson-propose: 183 passes before, 186 after (the setup check now runs once
  in each of the four parts). The sections moved verbatim; the only changed
  fixture line is the L19 `bulk` PR spread.
