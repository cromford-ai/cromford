# Dispatch mode per project: normal, hotfix-only with an allow-list, paused (BH-6350)

Doc: VERIFICATION-MAP, OPERATING

## What happened

On 2026-10-13 the operator asked to stop new non-hotfix builds on cromford until
the conflict fixes merged (#6011, #5241), while hotfixes kept building. There
was no switch for that. The project pause stops hotfixes too. So 23 tickets had
their `ai-build` label removed by hand and a `throttle-hold` label added: 23
writes to set, 23 to undo, and the tickets were hidden from every ai-build view.

## What changed

1. A new harness_flags row per project, `dispatch-mode-<project>` (scope
   `fleet`), read by `bin/lib/dispatch-mode.sh` (`dm_read`). Value
   `hotfix-only` or `hotfix-only:<n>,<n>`. Cleared means normal. `paused` is
   the existing `paused-<project>` row. `dispatch-mode-.+` joins
   `FLAG_PORTED_RE` in `bin/lib/jobs/flags.sh` and
   `worker/jobs/src/lib/harness-flags.js`, so the value, the last-good cache
   and the `config_changes` audit row come from the BH-4153 path.
2. In hotfix-only, five places hold a ticket that has no hotfix label and is
   not on the allow-list: the fastpath (condition 15c), the triage prompt
   (`rt_dispatch_mode`), the run-build backstop (`# >>> dispatch mode gate`,
   `BUILD_DEFERRED`, exit 3), the fly-pool spawn loop and reuse handoff, and
   the fly-dispatch file and rows picks. Each writes one log line per tick.
   Nothing is written to a ticket.
3. Resumes, pool machines, rebase jobs, blocked-resolver rebuilds
   (`rebuild:true`, carried by `queue_row_job_file` from the row meta's
   `blocked_resolver`) and death requeues pass.
4. One warn alert (the digest), `dispatch-mode-hotfix-only:<p>`, when hotfix-only has stood past
   `DISPATCH_MODE_ALERT_H` hours (default 24,
   `catalog/lanes.d/_lib.dispatch-mode.json`).
5. Mission Control: a sortable `MODE` column and a `SET` dialog on the Fleet
   projects table.

## Operator step after merge

Lift the manual throttle: add `ai-build` back to each `throttle-hold` issue and
remove `throttle-hold`. Then set `dispatch-mode-cromford` to
`hotfix-only:6291,6292,6293` in Mission Control.

Verified by `tests/dispatch-hotfix-only.bh-6350-test.sh`,
`worker/jobs/test/dispatch-mode.bh-6350.test.js` and
`console-ui/tests/dispatch-mode.bh-6350.test.js`. Reference:
`docs/verification-map/dispatch-mode.md`.
