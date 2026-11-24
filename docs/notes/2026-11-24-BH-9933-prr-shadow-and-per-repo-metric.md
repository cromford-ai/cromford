# BH-9933: per-repo GitHub calls per merged PR, and the PR-record shadow steps

Doc: EVENTS, GH-REST

Wave 1 of 7 of BH-9926 (move lane reads from GitHub onto the PR record).

## The metric

`bin/gh-ledger-report.sh --per-merged-pr --by-repo` prints, after the
existing `per_merged_pr=` total line, one line per registry repo:

    per_merged_pr_repo=<owner/repo> counted=<c> merged=<m> per_merged_pr=<n>

`n/a` when the repo merged 0 PRs, `unknown (<repo> unreadable)` when its
merged count could not be read, `unknown (ambiguous fold)` when two registry
repos fold to one ledger name, and one `(other)` line for rows with no
registry repo. The window is `--last`. Without `--by-repo` the output is
unchanged.

`--fleet` (only with `--by-repo`) counts from the fleet table
(`GET /api/metrics/gh-ledger?group=repo`, 14-day retention) and not from this
box's hour files, which are swept at 48 h. A failed fleet read prints
`per_merged_pr_repo=unknown (fleet ledger: <why>)`, never a local number.

Once a day `bin/pipeline-health.sh` runs
`bin/gh-ledger-report.sh --fleet --last 168h --per-merged-pr --by-repo`
through `gpd_run` (`bin/lib/gh-per-pr-daily.sh`). It writes one
`gh per merged PR (168h): <repo> ...` line per repo to
`logs/pipeline-health.log` and the file `state/gh-per-merged-pr.json`.
`bin/fleet-status-push.sh` section 13 sends that file to the console as the
fleet-status field `gh_per_merged_pr`. No alert. Knobs:
`PH_GH_PER_PR_EVERY_S` (86400, 0 = off), `PH_GH_PER_PR_WINDOW_H` (168),
`PH_GH_PER_PR_TIMEOUT_S` (120).

Operator check on the hub:

    bin/gh-ledger-report.sh --fleet --last 168h --per-merged-pr --by-repo

## Shadow steps

`bin/lib/prr-shadow.sh` is the one helper every moved lane uses. The step of a
lane is the settings row `lane.<id>.gh_source` (knob `GH_SOURCE`):

- `off`: GitHub only, the read of today.
- `shadow` (default): the PR record and GitHub. The lane uses the GitHub
  answer. A record answer that differs writes one line:
  `PRR_SHADOW lane=<l> key=<k> record=<n> github=<n> only_record=<n> only_github=<n> changed=<n>`.
- `record`: the PR record only, 0 GitHub calls. A record miss reads GitHub
  and writes `PRR_MISS lane=<l> key=<k> why=<word> fallback=github`.

A record miss in `shadow` writes `PRR_MISS ... fallback=none` and no
`PRR_SHADOW` line. A bad step value is `shadow` plus one `PRR_STEP` line. All
lines go to `logs/prr-shadow.log`. Count one lane's mismatches with:

    grep -c 'PRR_SHADOW lane=<l>' logs/prr-shadow.log

Each lane keeps its record, GitHub and compare functions in
`bin/lib/prr-shadow.d/<lane-id>.sh`. Wave 1 fills `tickets-snapshot-push.sh`:
the open PR list of each board repo (`pulls?state=open`) now goes through
`prr_read`, sized by `TICKETS_SNAPSHOT_OPEN_PR_LIMIT` (100). The
`git/matching-refs/heads/` read stays on GitHub: the record holds no branch
list. The seam files of waves 5 and 6 (`unblock`, `blocked-resolver`,
`pr-state-reconcile`, `main-red-pr-pair`, `merge-conductor`, `pipeline-health`,
`dequeue-watch`, `wake-loop`) exist with a header comment only.

## Owed after the merge

Post on BH-9933 the `tickets-snapshot-push.sh` counted calls for 24 h before
(23,077) and 24 h after an operator sets
`lane.tickets-snapshot-push.gh_source=record`:

    bin/gh-ledger-report.sh --last 24h --top 0 | grep tickets-snapshot-push
