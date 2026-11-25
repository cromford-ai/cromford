# BH-9936: the merge conductor's CI word from the PR record

Doc: MERGE-CONDUCTOR, GH-REST

Wave 4 of 7 of BH-9926 (move lane reads from GitHub onto the PR record).

## What changed

- New lib `bin/lib/prr-ci-state.sh`, function `prr_ci_state <owner/repo> <n> <head>`.
  It prints `green`, `red`, `pending` or `unknown` from the `checks` field of
  the PR record (`pr_record_peek`: one jobs GET, no GitHub call).
  - It counts only the entries whose `sha` is the head and whose name does not
    match `PRR_CI_IGNORE_RE` (the Mergify and Vercel checks that GitHub's
    actions/runs view does not show).
  - It drops `cancelled`, `timed_out`, `skipped` and `neutral`, as `mc_ci_state` does.
  - `unknown` means "read GitHub": no row, a row whose `head_sha` is another
    sha, no entry for the head, or a checks object with `PRR_CI_CHECKS_MAX`
    names or more. `unknown` is never `green`.
- The missed-event guard. When a pending entry of the head is older than
  `PRR_CI_PENDING_MAX_S`, `prr_ci_state` reads GitHub one time
  (`actions/runs?head_sha=<head>&per_page=50`) and writes the answer back with
  one `pr_record_put ... github '{"checks":{...}}'`: one `workflow:<name>`
  entry per workflow, `at` = the read start. The PUT replaces the whole checks
  object. A failed read gives `unknown` and writes nothing. Each guard writes
  one `PRR_CI_GUARD` line to `logs/prr-shadow.log`.
- `mc_ci_state <slug> <sha> <n>` (`bin/lib/mc/classify.sh`) reads through
  `prr_read` (lane `merge-conductor`, row `lane.merge-conductor.gh_source`).
  The seam is `bin/lib/prr-shadow.d/merge-conductor.sh`. The record serves only
  `green` and `pending`. `red` and `unknown` read GitHub and log `PRR_MISS`
  (`why=ci:red` or `why=ci:unknown`), because the red arms need the run ids and
  the advisory split that only the actions/runs read gives. In step `shadow`
  the guard is off, so shadow makes no extra GitHub read.
- The old body is `_mc_ci_state_github`, unchanged. Only the conductor's
  ci-read step (`bin/merge-conductor.sh`) passes the PR number. Every other
  caller passes 2 args and keeps the GitHub read.

## Knobs

| Knob | Where | Default |
|---|---|---|
| `GH_SOURCE` (row `lane.merge-conductor.gh_source`) | `catalog/lanes.d/merge-conductor.knobs.d/` | `shadow` |
| `PRR_CI_PENDING_MAX_S` | `catalog/lanes.d/_lib.pr-record.knobs.d/` | 900 s (0 = read GitHub on every pending) |
| `PRR_CI_IGNORE_RE` | `catalog/lanes.d/_lib.pr-record.knobs.d/` | `Summary\|Mergify Merge Queue\|suite:mergify\|suite:vercel\|Vercel.*\|Rule: .*\|Queue: .*` (whole name: the code adds `^(?:...)$`) |
| `PRR_CI_CHECKS_MAX` | `catalog/lanes.d/_lib.pr-record.knobs.d/` | 100 (the worker's `CHECKS_MAX`) |

## Operator: move the conductor from shadow to record

1. Count the mismatches on the hub: `grep -c 'PRR_SHADOW lane=merge-conductor' logs/prr-shadow.log`.
2. If the count stays 0 over the shadow window, set the settings row
   `lane.merge-conductor.gh_source` to `record`.
3. Check `grep -c 'PRR_MISS lane=merge-conductor' logs/prr-shadow.log` and
   `grep 'PRR_CI_GUARD' logs/prr-shadow.log` after the change.

## Known limit

A missed check-run `created` event can give `green` too early: the guard cannot
see a check the record never heard of. The default step stays `shadow`, and
wave 7's sweep is the backstop.
