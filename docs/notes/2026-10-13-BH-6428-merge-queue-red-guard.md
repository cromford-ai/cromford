# Box merge queue re-checks CI, reviewed sha and park state before every merge (BH-6428)

Doc: MERGE-CONDUCTOR, READINESS

## Incident

example-org/project-6 #216, 2026-10-13 (UTC):

- 07:13: the conductor re-ran 1 failed run on head 1ad9442c (red ladder rung 1).
- 07:23:55: the conductor moved #216 to RED_TWICE on 1ad9442c.
- 07:26:02: `bin/merge-queue.sh` on project-6-os took #216 from the coordination DB.
- 07:26:24: the queue merged #216 over REST at ad1c44e1. Main went red.

Three facts let the merge through:

1. The box queue never read CI.
2. `cv_hold` (`bin/lib/conductor-verdict.sh`) reads only ledger kind
   `mc-merge-verdict`. A RED_TWICE park writes kind `pr_state`, not that kind.
3. The project-6 `main` ruleset has no `required_status_checks` rule, so
   GitHub accepted the REST merge.

## What changed

- New lib `bin/lib/mq-premerge.sh`, function `pmg_check`. `mq_land` in
  `bin/merge-queue.sh` calls it through `mq_premerge_guard` after the
  conductor-verdict gate and before any merge rung (REST and the
  `gh pr merge` fallback). Both landing paths (union train, serial loop) call
  `mq_land`. The legs, first miss wins:

  | Leg | Read | Miss |
  |---|---|---|
  | `head` | the head the pass pinned, else `mq_pr .head.sha` | not 7-40 hex: `hold head-unread` |
  | `reviewed-sha` | `hb_sha` (job_verdict), else `reviewed_sha` on the `pr_state` row | empty: `handback no-reviewed-sha`; no prefix match: `handback head-not-reviewed`. `HEADBOUND_ENFORCE=0` skips the leg with one log line |
  | `park` | ledger `pr_state` row, key `<slug>#<num>` | `RED_TWICE`, `BLOCKED_*` or `NEEDS_REBASE` on this head: `handback conductor-park`; on another head, parked after the enqueue (or either time unreadable): `handback stale-enqueue` |
  | `ci` | `mc_ci_state <slug> <head>` | `red`: `handback ci-red`; `pending`, `none`: `hold`; `unavailable` or no `mc_ci_state`: `hold ci-unavailable` |

  A ledger outage on the park leg passes with one log line. The CI leg reads
  GitHub, so a red head is still refused.
- Each miss writes `MERGE_REFUSED premerge-<leg>: …` to `logs/merge-queue.log`.
  `mq_land` prints `REFUSED <hold|handback> <reason>`.
- `hold`: the entry stays queued and the next pass asks again.
- `handback`: the queue file goes, the row goes to `dropped` with reason
  `MERGE_REFUSED <reason> — handed back to the merge conductor`. No page, no
  `.blocked`. The conductor lands every READY PR itself. A fresh APPROVE
  re-queues the PR.
- The enqueue time is the queued row's `enqueued_at`, else the queue file's
  mtime.
- Behaviour change: an entry with no reviewed sha anywhere used to land pinned
  to the head the pass read. Now it is handed back.
- `bin/readiness-report.sh` has a new report-only check `ci.required_check`.
  It fails with `OWED: required status check` when neither the branch
  protection rule nor a ruleset on the default branch requires a status check.
  No readiness level reads it.
- New read-only script `bin/merge-queue-red-audit.sh [--days N]`. It lists each
  `landed` merge_queue row in the window whose head CI was not success at
  merge time. It names a project as `incomplete` when its read hits the
  route's 500-row cap.

## Commands

- Fleet audit (needs the worker credential and a GitHub token, run on the hub):
  `bin/merge-queue-red-audit.sh --days 7`
- Readiness: `bin/readiness-report.sh /root/repos/<project>` shows
  `ci.required_check`.

## Owed separately

The project-6 `main` ruleset needs a `required_status_checks` rule for the
`ci` workflow. That is a repo setting. The harness does not depend on it.
