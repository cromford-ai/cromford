# BH-5035: the `human` value of tier_gate_mode and lead_authority_mode is removed

Doc: MERGE-CONDUCTOR, VERIFICATION-MAP

Decision: the operator, 2026-10-31 (parent #4572). The hub had 0 rows of either key,
0 tier-gate holds in the logs, and every LEAD_READY line read
`lead_authority_mode=lane`.

## What changed

1. `bin/lib/tier-gate.sh` (`tg_mode`, `tg_holds`, `_tg_page`) is deleted. Its
   four call sites are gone: the run-build APPROVE hand-off in
   `bin/lib/rb/pr.sh` and `bin/lib/rb/result.sh`, and the `merge_retry` hold
   and the fresh-merge hold in `bin/review-prs.sh`. No code reads
   `tier_gate_mode`. A stored row is inert. No hold was added to
   `bin/merge-sweep.sh` or to the conductor's autoenqueue.
2. `lead_authority_mode` accepts only `lane` (no row = lane).
   `_la_mode` refuses a stored `human` (trimmed, any case): rc 2 with
   `LA_MODE_RETIRED=1`. `la_decide` then holds (rc 2) with the reason
   `the mode row <key> reads 'human', a value BH-5035 retired: delete the row
   or set it to lane (bin/jobs-client.sh setting-set <key> lane)`. It is never
   read as lane. `la_decide` no longer reads the authority row
   `lead_authority.<owner>.<name>` and no longer returns rc 1. Its callers keep
   their rc-1 branch, which holds.
3. `bin/lead-review-precision.sh` no longer writes `human:precision` and no
   longer sends the critical revocation page. A low precision is one log line
   and the day's warn beat. A legacy `human:precision` row still goes back to
   `lane` when precision recovers.
4. `PUT /api/settings` refuses the value `human` for `tier_gate_mode`,
   `tier_gate_mode.<x>`, `lead_authority_mode` and `lead_authority_mode.<x>`
   with a 400, before any DB read
   (`worker/jobs/src/lib/retired-mode-values.js`). `bin/jobs-client.sh
   setting-set`, `bin/protected-setting.sh` and the console all write through
   it.
5. The console SETTINGS → PROTECTED PATHS hint has no SET human button. A
   stored `human` row shows as removed, with SET lane.
6. The tier is still recorded: the `tier-<n> APPROVE from <key>` queue note,
   the review-prs state `.tier`, the RESULT tier and the console tier event do
   not change.

Out of scope and unchanged: `human_verdict_mode`, `human_verdict_sig_mode`,
the authority row family and its BH-4090 signing rules, every
`--source human` verdict path.

## Operator

If a row exists, clear it:
`bin/jobs-client.sh setting-set lead_authority_mode[.<owner>.<name>] lane`.
A `tier_gate_mode` row can stay; nothing reads it.

## Tests

`tests/tier-gate-removed.bh-5035-test.sh` (G1-G10),
`tests/lead-authority-human-retired.bh-5035-test.sh` (L1-L9, P1-P3),
`worker/jobs/test/retired-mode-values.bh-5035.test.js` (W1-W8),
`console-ui/tests/lead-authority-hint.bh-5035.test.js` (C1-C4).
