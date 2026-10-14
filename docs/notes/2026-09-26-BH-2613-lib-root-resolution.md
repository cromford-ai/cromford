# bin/lib root resolution: no literal /root/harness fallback (contract, ratchet, child map)

Doc: LIB-ROOT-RESOLUTION

BH-2613.0 (#2648), part 1 of 5 of #2613. This slice changes no product code.
It adds the ratchet, its per-lib baseline and these rules. Sibling slices
convert the libs.

## What changed

- `tests/lib-root-literal-ratchet.bh-2613-test.sh` counts the literal
  `/root/harness` fallbacks in `bin/lib/**/*.sh` and compares each lib with its
  baseline. A site is an occurrence of `/root/harness` (followed by anything
  except `[A-Za-z0-9_]`) in the default word of `${NAME:-…}`, `${NAME:=…}` or
  `${1:-…}` (nested defaults count once per literal), or in
  `(local )?NAME=["']?/root/harness…` at a statement start. The scan skips
  comment lines, trailing ` #` comments and heredoc bodies. Each occurrence
  counts once, so a line with two defaults counts 2.
- The ratchet has two modes. **Delta** (the default, every PR and merge-queue
  run) counts each lib at the base and at HEAD and is red only when the diff
  raises a lib's count or adds a lib with sites. The base is the merge-base of
  HEAD with `RATCHET_BASE` (CI passes `pull_request.base.sha`; `TI_BASE` also
  works) or with `origin/main`, whichever is newer. A base that doesn't resolve
  is red, never a skip. Sites main lands in other libs sit on both sides and
  cancel, so main moving can't dequeue a batch or turn main red. The first cut
  was absolute only, went stale on every main move, and #2772 was dequeued
  twice on it. A lib renamed with its sites reads as a new lib (red).
- **Strict** (`RATCHET_MODE=strict` or `--strict`) is the absolute check, for a
  scheduled or post-merge run. `tests/fixtures/root-fallback-baseline/` has one
  `<relpath with / → __>.count.txt` per lib with sites (114 files, 238 sites
  when #2772 was rebuilt on f9029c9; 113 files, 234 sites on d3bb224; the
  first cut was 105 files, 214 sites on 230f092). The `.txt` is there because
  the public mirror's leakcheck refuses any extension it can't read as text. A
  lib with no baseline must have 0 sites. A lib with a baseline must have
  exactly that count. A baseline with no lib, a count that isn't a positive
  integer, or a baseline for a lib that now has 0 sites is an error. Strict red
  means main drifted from the inventory; regenerate it in its own PR.

Run it as `HARNESS_TEST_SANDBOX=1 bash tests/lib-root-literal-ratchet.bh-2613-test.sh`
(add `--strict` for strict mode). `--print` prints `<relpath>\t<n>` for every
lib with sites and runs no checks. The baseline is generated from `--print`,
never by hand (the loop is in the suite header; clear the old files first).

Once a sibling converts a lib, it deletes that lib's own `.count.txt` file so
strict mode stays green (delta mode needs no file edit for a drop). The files
are per lib, so siblings never share a hunk. If a lib drops to fewer sites but
not zero, lower its count.

## Resolution contract (from the parent plan; apply it, do not re-decide it)

1. **Sourced lib:** `root = ${HARNESS:-${H:-}}`. If a lib already honours a caller-scoped root var (MC_H, JOBS_HARNESS, HB_DIR, HB_DB_CMD, HARNESS_STATE_DIR, a positional `$1`), keep that var where it is in the chain. Only the trailing `/root/harness` literal becomes empty.
2. **No root:** skip every file write, mkdir, log append, cache write and lock. Reads return the function's existing default or "absent" answer, with rc 0 or the rc it already gives for "unreadable". Never exit a `set -e` caller. Never build a path from an empty root: `[ -n "$root" ] || return 0` goes before any `"$root/..."`. A relative `/state/...` path is as bad as the literal. Copy the idiom from `bin/lib/fleet-cooldown.sh` `_fcd_root` / `_fcd_state` (BH-2353).
3. **Lib run directly** (`[ "${BASH_SOURCE[0]}" = "$0" ]`, which only matters for the executable libs): with HARNESS and H both empty, the root is the lib's own install root, found with `$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)` (add one `..` per subdir level).
4. **The entry point owns the default.** A `bin/*.sh` that sources a converted lib without setting H/HARNESS first gets `H="${HARNESS:-/root/harness}"` before its source line. bin/ is outside the ratchet.
5. `set -u` safety: always `${H:-}`, never a bare `$H`. Every no-root guard is `|| return 0` (or the function's existing absent rc), never a failing test as the last statement.
6. **No root is not approval and not "sent".** A gate answers exactly what it answers today for an unreadable state dir. A lib that sends and also stamps a dedupe file still sends, and no stamp is written anywhere.

The idiom to copy is `bin/lib/fleet-cooldown.sh`: `_fcd_root` prints
`${HARNESS:-${H:-}}`, and `_fcd_state` returns 1 and prints nothing when that
is empty. The suite checks that fleet-cooldown.sh exists and has 0 sites.

## Child map (from the #2613 child issues)

| Order | Issue | Libs |
|---|---|---|
| 1 | #2648 (this) | none. Ratchet, baseline, this note |
| 2 | #2649 BH-2613.1 | `lane-gate`, `jobs/req`, `endpoints`, `cost-row`, `cost-rows-read`, `cost-budget` |
| 3 | #2650 BH-2613.2 | `triage-shards-lib`, `triage-hotfix-lib`, `triage-throttle`, `triage-gate-ledger`, `hotfix-lib`, `hotfix-migrate-workflow`, `conf-row`, `heartbeat`, `issue-state-lib`, `pause` |
| 4 | #2651 BH-2613.3 | `preplan-lib`, `prebuild-repro`, `prebuild-repro/drive`, `prebuild-repro/stop`, `ready-queue`, `orc-account`, `rt/scope`, `mc/rebase`, `dep-verify-lib`, `revdep-lib` |
| 5 | #2652 BH-2613.4 | `pool-account`, `session-profile`, `lane-model`, `fanin`, `fc-board`, `file-children`, `builds-of-record`, `backup-freshness`, `restore-drill-orgo`, `verdict-parse` |

`bin/lib/jobs/req.sh` has no baseline. Its root is `$JOBS_HARNESS` with no
literal default, so it has 0 sites by this counter. #2649's work there (write
nothing when `$JOBS_HARNESS` is empty) is behaviour this ratchet can't see.

Some site counts in the child issues were measured on 39520c7 and count lines,
not occurrences. The committed baseline is what the siblings must match. For
example, `triage-hotfix-lib` has 6 sites on 3 lines, and `pause` has 2 because
its third mention is a comment.

## Remainder (not converted by any child of this split)

These are copied verbatim from #2648. They stay pinned by their baseline files
until a follow-up ticket converts them.

`alert-state` `block-gate` `board-creds` `box-id` `br/opt/mechanical` `build-caps` `builder-direct` `cadence-backstop` `call-guard` `disk-guard` `docker-host` `env-path` `fc-issues` `gh-app-auth` `gh-app-default` `gh-budget` `gh-ci-read` `gh-limit-logger` `gh-policy-cache` `gh-pr-create` `gh-pr-list` `gh-pr-merge` `gh-push-identity` `gh-quota` `gh-repo-token` `gh-rest` `gh-rest-etag` `gh-rest-ledger` `gh-token-live` `gitleaks-pin` `hub-box` `lane-caps` `ledger-twin` `llm-gate` `main-red-gate` `main-red-label` `mc/log` `merge-conductor-lib` `model-route` `page-critical` `pr-dep-gate` `pr-terminal` `prepr-gate` `project-account` `queue-row-job` `rb/execute` `rb/pr` `rebuild-ledger` `reconcile-owner-watch` `reconcile-read` `resume-dead` `review-model` `review-post` `rt/gate` `scheduler-conf` `split-chain` `ticket-ownership` `tier2-autoenqueue` `trap-eval-cells` `verdicts` `wake-class-deploy` `wake-class-push` `wake-lanes`

Three libs reached main after #2648 was written and are pinned the same way:
`failover-drill-common` (2), `run-beat` (1), `untriaged-lib` (1).

On 337373a, `rebuild-ledger` mentions the literal only in a comment, so it has
0 sites and no baseline.

Five libs merged on 2026-09-26, after 39520c7, have sites but appear in neither
the child map nor the remainder. They are pinned by baselines and belong with
the remainder follow-up: `extra-usage-read` (2), `fix-delta-review` (1),
`groom-db` (2), `proposal-rows` (1), `review-saving` (4).

Eight more libs reached main before the baseline was regenerated on d3bb224.
They are pinned by baselines and belong with the remainder follow-up:
`box-cmd-exec` (1), `failover-drill-demote` (1), `failover-drill-proofs` (1),
`gate-self-comments` (1), `keyed-wake` (1), `pool-result-row` (2),
`rb/plan` (2), `test-home-lib` (1). On the same regeneration `hotfix-lib` went
from 12 to 13 sites and `preplan-lib` from 12 to 13; their children (#2650,
#2651) must match the new counts.

On the f9029c9 regeneration (when #2772 moved to delta mode), `route-rules` (1)
is new and `gh-app-auth`, `gh-app-default` and `gh-token-live` went from 1 to
2 sites. They belong with the remainder follow-up.

## Still owed (the #2613 close-out)

- Delete `tests/fixtures/root-fallback-baseline/` once every lib is converted.
  With no baselines, strict mode is red on any site in any lib. Delta mode
  reads no baseline and is unchanged by the deletion.
- Add `tests/lib-root-trace-nobody.bh-2613-test.sh`, a trace-safety run over the
  lib suites as `nobody` that reports hits=0. It isn't built yet.
