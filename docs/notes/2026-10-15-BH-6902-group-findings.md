# QA findings: collect first, one issue per screen or flow (BH-6902, slice C0)

Doc: OPERATING

## What changed

- New `bin/lib/group-findings.sh`. `gf_run <findings.jsonl> <run_dir> <owner/repo> [--dry-run]`
  takes one QA run's findings, writes the run ledger, groups the findings by
  screen or flow, and files ONE issue per group or comments on the open one.
  `gf_from_observed <board> <observed.json>...` turns a qa-drive `observed.json`
  into findings. `gf_key` is the one key normaliser.
- `bin/postmerge-qa.sh` calls it on a FAIL verdict, after `findings-log.sh`. The
  ALERTS line, the fleet_alert beat, the PR comment and `mark_done` do not change.
- New `bin/group-findings-replay.sh` (T5): replays the last N days of post-merge
  QA `observed.json` files and prints issues before (one per finding) and after
  (one per screen or flow), and `lost`.
- The rule is the fleet topic `rules/topics/12-qa-findings.md`. The PLAN, EXECUTE
  and REVIEW prompts carry one sentence: `FOLLOW-UPS ARE GROUPED: ...`. C2 adds
  it to the delta review scope, the moved-head re-review (`HB_PROMPT`) and the
  preview QA prompt (`QA_PROMPT_FOR`).

## Input format (one JSON object per line)

`{board, screen_or_flow, severity, title, repro, cause, class?, files?}`

- `severity`: `low|medium|high|critical`. Anything else is `medium`, and the
  ledger row says `severity_coerced: true`.
- `class`: `data-leak` or `launch-blocker`. Anything else is ignored.
- `files`: the repo paths the fix edits. The `Blocked-by:` rule reads them.
- A line that is not a JSON object, or that has no screen or flow, is an
  `invalid` ledger row. It is not filed and not dropped.

## Key

Trim, lower case, cut the query string and the `#` part, cut a viewport suffix
(`/clients@375`), cut the trailing `/`. A `flow:` key keeps its prefix. The exact
path is the key: `/clients/123` and `/clients` are two keys.

## Ledger and summary (in the run dir; they follow the build-dir retention)

- `findings-ledger.jsonl`, append-only. A finding's state is its LAST row
  (key `fp`, the sha256 of `board|key|title|repro`, 16 hex). Actions:
  `pending` (written first, for every finding, before any filing), `off`,
  `deferred`, `invalid`, `urgent`, `filed`, `commented`, `followup`, `failed`,
  `would_file`, `would_comment`, `would_followup`, `would_urgent` (dry run).
  A filed, commented or followup row always carries the `issue` number that the
  POST answered. A POST with no number is `failed` with its `http` status.
- `group-findings.md`: one line per group, then
  `group-findings: <F> findings, <G> groups, filed <a>, commented <b>, followup <c>, urgent <d>, deferred <e>, failed <f>, invalid <i>`.

## Markers (matched exactly, in an issue BODY only)

| Marker | Meaning |
|---|---|
| `<!-- findings-group: <board>\|<key> -->` | the group the issue belongs to |
| `<!-- findings-run: <run_id> -->` | the run that wrote the body or comment (run_id = run dir name) |
| `<!-- findings-urgent: <fp> -->` | the urgent finding's own issue |
| `<!-- findings-followup-of: #<n> -->` | a follow-up of issue `#<n>`, whose PR is approved |

## Decisions, per group

1. A terminal row of this run for the group: skip (rerun).
2. An open issue with this group's marker AND this run's marker: record it as
   `filed` (the ledger row was lost after the POST).
3. The open issues with the group marker, lowest number first. The first one
   with no linked open PR approved on its head gets a comment (skipped if a
   comment with this run's marker is already there).
4. If every match has an approved PR: a new follow-up issue with
   `findings-followup-of: #<lowest>` and one `Blocked-by: #<pr>` per approved PR.
5. No match: a new issue, `QA findings: <key> (<n> items)`, no label.

A linked PR is an open PR whose body says `close(s|d)`, `fix(es|ed)`,
`resolve(s|d)`, `refs` or `part of` `#<n>`, or whose head ref ends `-<n>` or
`-<n>-r<k>`. Approved is a review `APPROVED` with `commit_id` equal to the PR
head, or a comment that `bg_verdict_clears` accepts on that head (a machine
login only). If the reviews or comments cannot be read, or either list is at
its 300-row cap, the PR counts as approved: no scope is added to a PR nobody
can read in full.

Urgent: severity rank >= `GROUP_FINDINGS_URGENT_RANK` AND class `data-leak` or
`launch-blocker`. It is filed before the groups, and it stays in the group
checklist as `(filed at once as #<n>)`.

Shared files: when a group lists a file that an earlier group of the run also
lists, its new issue (or comment) gets `Blocked-by: #<earlier issue>`.

## Return codes of gf_run

`0` every group acted, or the knob is off. `1` one or more POSTs failed; a
rerun on the run dir retries only those groups. `75` the open-issue list is
unknown (an error, rate limit, or 1000 rows, the cap), or the open PR list a
group needs is unknown: nothing is filed blind, the rows are `deferred`. `2` bad
arguments.

## Knobs (catalog/lanes.d/_lib.group-findings.json, lib id `group-findings`)

| Knob | Default | Row for one board |
|---|---|---|
| `GROUP_FINDINGS` | 0 (off: no GitHub call, rows `off`) | `lib.group-findings.<board>.group_findings` |
| `GROUP_FINDINGS_URGENT_RANK` | 3 (high) | `lib.group-findings.<board>.group_findings_urgent_rank` |

## Audit of the lanes the ticket names

| Lane | Files issues today? | Per finding? | Action |
|---|---|---|---|
| bin/postmerge-qa.sh | No (qa-prod.md, findings.log, PR comment, ALERTS) | n/a | Calls gf_run on FAIL (this slice) |
| bin/console-postmerge-qa.sh | No (qa.md, PR comment, warn alert) | n/a | Wired (C1): a FAIL calls gf_run with board cromford; gap 503s are not findings |
| bin/nightly-ticket.sh, bin/ci-nightly-full.sh | Yes | No: one marker issue per red, an open one gets a comment | None |
| bin/flaky-tier.sh | Yes | One per quarantined suite, bound to its quarantine row (`fix #T`) | None: the suite is the flow |
| bin/outcome-check.sh | Yes | One per PR, marker dedup | None |
| bin/lib/post-merge-verify.sh | Yes | One per key, title dedup | None |
| bin/lib/slice-remainder.sh, slice-closeout.sh, file-children.sh, fc-issues.sh | Yes | Decomposition children, not findings | None |
| bin/lib/archie-fm-improve/tickets.sh | Yes | One per cause fingerprint, comments on recurrence | None |
| bin/post-proposal.sh | Yes | Proposals, not findings | None |
| bin/preplan-candidates.sh | No (reads issues) | n/a | None |
| PLAN / EXECUTE / REVIEW prompts | n/a | n/a | One sentence each, nine sites (rb/plan.sh, rb/execute.sh, rb/review.sh x3 with the delta review scope (C2), rb/result.sh HB_PROMPT (C2), rb/pr.sh QA_PROMPT_FOR (C2), run-preplan.sh, review-prs.sh) |

## Not in this slice

- C1: Wired (C1): a FAIL calls gf_run with board cromford; gap 503s are
  not findings. `bin/console-qa-run.mjs` now writes each screen of
  observed.json as judged (the gap 503s only in `gaps`). Tested by
  `tests/console-postmerge-qa-group.bh-6902-test.sh`.
- C2 (code): the replay also reads the console post-merge QA runs in
  `state/console-postmerge-qa/<sha40>/observed.json` (`--console DIR`, board
  cromford) and prints `console: runs=<n> dir=<DIR>`. Tested by
  `tests/group-findings-console-replay.bh-6902-test.sh`.
- Still owed (a run, not code): turn the knob on for cromford, then on the
  hub run `bin/group-findings-replay.sh --days 7` over the real build dirs and
  console runs and post the numbers on #6902. This builder box has no post-merge
  QA history.
