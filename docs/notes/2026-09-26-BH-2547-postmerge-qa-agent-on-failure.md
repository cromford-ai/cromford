# Post-merge QA pays the prodqa agent only when the drive failed

Doc: OPERATOR-SETUP

`bin/postmerge-qa.sh` drives the shipped screens on production with
`bin/qa-drive.mjs`, which is deterministic, and then used to open the `prodqa`
agent on top of every GREEN drive, never on a failed one. So every call bought
a second opinion on a PASS the drive had already written. The 2026-09-25
goal-gap audit (gap D7) put that at $127 in 7 days over 82 prodqa calls, with
the drive itself as the backup (issue #2547).

## What changed, in `bin/postmerge-qa.sh`

**The gate is inverted.** Before the agent block the script computes
`DRIVE_FAILED`: 1 when the drive's rc is non-zero or the report has a
`FLOW <persona> <flow> fail` row, 0 otherwise. `qa-drive.mjs` exits non-zero on
every `QA: FAIL` it prints, so the rc already covers that line. The agent runs
only when `DRIVE_FAILED=1`, nothing is BLOCKED, `POSTMERGE_QA_AGENT` is `1` and
`agent-call.sh` is present.

- A green drive writes its verdict with no call. The report says
  `flow drive: not run — the deterministic drive was green, its verdict stands`.
- A failed drive opens the agent to characterise the failure. The prompt now
  opens "A deterministic drive FAILED on these screens …" and asks whether the
  failure is an in-scope defect of this ticket or pre-existing/out of scope.
  The call still goes through `agent-call.sh` as `AGENT_CALL_ROLE=postmerge.qa`
  (model from the `postmerge.qa` model_routes row).
- BLOCKED (rc 90/91, persona blocks) and the rc 75 requeue still make no call.
  Nothing was observed, so there is nothing to characterise.

**The verdict block is untouched.** A non-zero rc or a fail row is FAIL, and an
agent's trailing `QA: PASS` cannot turn it back. The agent can still add a FAIL
of its own.

**No new knob.** `POSTMERGE_QA_AGENT=0` still turns the agent off entirely.
`catalog/lanes.d/postmerge-qa.json` is unchanged.

The `[lane:deterministic_prefix]` bound on the `postmerge-prodqa` lane in
`catalog/context-budgets.json` now describes the new skip condition.

## Tests

`tests/postmerge-qa.bh-2547-test.sh` drives the real script: a green classic or
persona drive makes 0 agent-call rows; a failed drive (rc 1, a fail row at rc 0,
a fail row that is not the last persona's, a crashed drive with no verdict line)
makes exactly one; an agent `QA: PASS` on a failed drive stays FAIL; BLOCKED,
requeue and `POSTMERGE_QA_AGENT=0` make none. `tests/postmerge-qa-test.sh`,
`tests/postmerge-qa-personas-test.sh` and `tests/postmerge-qa.bh-2005-test.sh`
pinned the old gate and now pin this one.
