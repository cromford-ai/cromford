# `gh` over REST — the shim contract

`bin/gh-rest-shim` is a `gh` entry point that turns the `gh pr|issue|run|repo`
calls this harness makes into single REST requests. Everything it cannot
translate reaches the real `gh` binary untouched, and says so in a log.

This is the contract doc: what each verb becomes, what it costs, what it
refuses to do, and how to turn it off. Every claim below is taken from the
merged code and carries the `file:line` it came from.

## 1. Why it exists

On 2026-09-18 the fleet exhausted its GraphQL budget (#768) and lanes that read
PR state through `gh pr view` stopped being able to decide anything. the operator,
2026-09-17: stop all harness ops from using GraphQL, use REST only. One PAT is
one 5000/h REST bucket for every lane on every box, and `gh pr view --json
state` spends several GraphQL points where `GET /repos/{slug}/pulls/{n}` costs
one REST call out of that bucket (`bin/gh-rest-shim:10-13`).

The shim is the translation layer. It is not installed anywhere yet — see
section 11.

## 2. The census

`tests/fixtures/gh-shim-census.txt` is the machine-readable copy: one `gh` argv
per line, every subcommand and flag form the harness writes.
`tests/gh-passthrough-budget.bh-791-test.sh` drives every line through the real
shim and asserts the pass-through log stays empty, then scans `bin/**/*.sh`,
`catalog/` and `skills/` for `gh <group> <verb>` at command position and asserts
that verb set is a subset of the census. A new subcommand in the harness is red
until somebody adds it to the census, where the shim must prove it translates
it.

Call-site counts measured on the merged tree, 2026-09-22:

| group | verb | sites | first site | translated |
|---|---|---|---|---|
| issue | close | 2 | `bin/hotfix-after-deploy.sh:253` | yes |
| issue | comment | 4 | `bin/hotfix-after-deploy.sh:251` | yes |
| issue | create | 4 | `bin/lib/fc-issues.sh:368` | yes |
| issue | edit | 2 | `bin/lib/fc-issues.sh:449` | yes |
| issue | list | 10 | `bin/bootstrap-machine.sh:302` | yes |
| issue | view | 11 | `bin/launch-fastpath.sh:574` | yes |
| pr | checks | 1 | `bin/hotfix-migrate.sh:72` | **no** |
| pr | comment | 7 | `bin/lib/block-gate.sh:458` | yes |
| pr | create | 9 | `bin/batch-resolve.sh:1457` | yes |
| pr | diff | 5 | `bin/review-autopilot.sh:469` | yes |
| pr | edit | 1 | `bin/run-build.sh:5881` | yes |
| pr | list | 28 | `bin/batch-resolve.sh:860` | yes |
| pr | merge | 7 | `bin/lib/mc/queue.sh:553` | yes |
| pr | review | 1 | `bin/review-prs.sh:1088` | yes |
| pr | view | 25 | `bin/alerts-groom.sh:68` | yes |
| repo | clone | 4 | `bin/bootstrap-machine.sh:207` | yes (execs git) |
| repo | view | 2 | `bin/load-project.sh:153` | yes |
| run | list | 2 | `bin/lib/hotfix-migrate-workflow.sh:321` | yes |
| run | rerun | 3 | `bin/lib/mc/classify.sh:1444` | yes |
| run | view | 7 | `bin/blocked-resolver.sh:3094` | yes |
| run | watch | 1 | `bin/lib/hotfix-migrate-workflow.sh:342` | **no** |

The two "no" rows are long-poll watches. `gh pr checks --required --watch
--fail-fast` (`bin/hotfix-migrate.sh:72`) and `gh run watch --exit-status`
(`bin/lib/hotfix-migrate-workflow.sh:342`) both block until a check set
settles; neither is one REST call, and neither has a handler. They stay in the
census marked `!`, and the suite asserts they DO log a pass-through — a silent
pass-through is the failure this ratchet exists to catch.

## 3. What each verb becomes

Every rule below is one a caller depends on.

| call | REST | the rule that matters |
|---|---|---|
| `pr view <n> --json …` | `GET repos/{slug}/pulls/{n}` | `mergeCommit` is `null` on an open PR, always (`pr-read.sh:46`). REST's `merge_commit_sha` is a TEST-MERGE sha there, and three merge-path scripts read `.mergeCommit.oid` as "what landed". |
| | | `state` is `MERGED` when `merged_at` is set, not REST's `state` (`pr-read.sh:31`). |
| | | `mergeable` is `MERGEABLE` / `CONFLICTING` / `UNKNOWN`; every enum is upper-cased, the way GraphQL answers (`pr-read.sh:42-45`, `read-maps.sh:22`). |
| | | `author.login` is `app/<name>` for a Bot whose login ends `[bot]` — decided by TYPE, not by the suffix, so a human login ending `[bot]` is left alone (`read-maps.sh:24-31`). |
| | | `id` on a label is `node_id`, not the REST integer (`read-maps.sh:34`). |
| `pr list` | `GET repos/{slug}/pulls` | `--state merged` is `closed` plus a `merged_at` filter, applied after the fetch, so the window over-fetches and widens rather than answering short (`pr-read.sh:249-273`). `--search` goes to `search/issues` instead (`pr-read.sh:324-371`). |
| `issue view <n> --json …` | `GET repos/{slug}/issues/{n}` | same author/label rules. |
| `issue list` | `GET repos/{slug}/issues` | every row carrying `.pull_request` is dropped BEFORE `--limit` (`issue-read.sh:133`, `issue-read.sh:154`). That endpoint returns pull requests too, and a board pass that reads a PR as a ticket triages a PR. |
| `repo view` | `GET repos/{slug}` | `defaultBranchRef` is an object `{name}`, not a bare string (`repo.sh:23-24`). |
| `repo clone` | `GET` nothing — execs `git clone` | section 13. |
| `run view <id> --json …` | `GET repos/{slug}/actions/runs/{id}` | `databaseId` is REST's `id` (`actions.sh:26`). |
| `run view --log` / `--log-failed` | `GET …/runs/{id}/jobs` then `…/jobs/{jid}/logs` | the framing is OURS: `=== <job> ===` then the raw bytes, not gh's `job\tstep\tline` (`actions.sh:10-15`). Section 14. |
| `run list` | `GET …/actions/runs` or `…/workflows/{file}/runs` | `--workflow` picks the per-workflow endpoint (`actions.sh:83-87`). |
| `run rerun` | `POST …/runs/{id}/rerun` (`rerun-failed-jobs` with `--failed`) | `actions.sh:71-72`. |
| `pr create` | `POST repos/{slug}/pulls` | `--label` is a second call, `POST …/issues/{n}/labels`, after the URL is already on stdout; a label failure warns and exits 1 but never swallows the URL (`pr-write.sh:166-174`). |
| `pr edit` | `POST …/labels`, `DELETE …/labels/{name}`, `PATCH …/pulls/{n}` | `pr-write.sh:185-201`. |
| `pr close` / `issue close` | comment FIRST, then `PATCH state=closed` | `pr-write.sh:206-226`, `issue-write.sh:70-95`. A failed comment leaves the record open, which is the recoverable order. |
| `pr comment` / `issue comment` | `POST …/issues/{n}/comments` | prints the comment's `html_url`. |
| `pr review` | `POST …/pulls/{n}/reviews` | exactly one event flag, or the call passes through: guessing an event is guessing whether a PR was approved (`pr-write.sh:264`). |
| `pr diff` | `GET …/pulls/{n}` with the `v3.diff` Accept header, or `…/files` for `--name-only` | `pr-write.sh:274-287`. |
| `pr merge` | one `PUT …/pulls/{n}/merge` | defaults to squash, prints gh's own `✓ Squashed and merged pull request #<n> (<title>)` line (`pr-write.sh:292-330`). Section 12 covers the merge-queue case. |
| `issue create` | `POST repos/{slug}/issues` | prints the issue's `html_url`. |
| `issue edit` | same label/PATCH shape as `pr edit` | `issue-write.sh:32-53`. |
| `issue close --reason` | `PATCH state_reason` | gh spells it `"not planned"`, REST spells it `not_planned`; the handler translates (`issue-write.sh:88-92`). |

`id` on a comment is `node_id` too (`read-maps.sh:186`). The triage state file
keys `lastSeenCommentId` on gh's node id, and the REST integer is a different
namespace — emitting it would make every thread look brand new.

## 4. What the sub-fetches cost

A `--json` field nobody asked for never costs a call, and the ones below each
cost their own:

- `--json comments` on `pr view` or `issue view` is one extra REST call per
  record (`issue-read.sh:10-12`). `bin/triage-gate.sh` asks for 100 records and
  `bin/orphan-reconcile.sh` for 200, so that is 100 and 200 extra calls per
  tick.
- `files`, `reviews`, `commits` and `statusCheckRollup` each cost their own
  call on `pr view` (`pr-read.sh:19-20`).
- `statusCheckRollup` costs TWO: check runs and commit statuses, both paged
  (`pr-read.sh:163-173`).

## 5. Unmappable fields pass the whole call through

Four field sets are mappable, and they are the whole list:

| set | where |
|---|---|
| `GSHIM_PR_VIEW_FIELDS` | `pr-read.sh:23` |
| `GSHIM_PR_LIST_FIELDS` | `pr-read.sh:184` |
| `GSHIM_ISSUE_FIELDS` | `issue-read.sh:14` |
| `GSHIM_REPO_FIELDS` | `repo.sh:12` |
| `GSHIM_ACT_FIELDS` | `actions.sh:21` |

A `--json` field outside its set sends the WHOLE call to the real binary
(`gshim_fields_ok`, `bin/gh-rest-shim:325-337`) rather than coming back
invented. Absent is not zero and not false.

## 6. Exit codes

| code | meaning |
|---|---|
| 0 | the call succeeded |
| 1 | the call failed (`bin/gh-rest-shim:252`) |
| 75 | REST rate limited — `EX_TEMPFAIL`: back off, the request itself was fine (`bin/gh-rest-shim:245`). An exit 75 is never an empty answer. |
| 127 | no real `gh` binary, or a shim loop at depth 3 (`bin/gh-rest-shim:88`, `bin/gh-rest-shim:126`) |

Anything else is the real binary's own code.

75 needs both halves to fire: an `HTTP 403|429` AND a rate-limit or
abuse-detection message (`bin/gh-rest-shim:234-235`). A 403 is far more often
"not accessible by integration" than a rate limit, and 75 tells every caller
"come back later".

**One coincidence worth knowing.** `bin/lib/cost-row.sh:68` also exits 75, for
"the flock was not acquired". Different namespace, same number — a reader
tracing a 75 checks which producer it came from.

## 7. The decision rule

A decision path never trusts an empty answer. An exit 75 is UNVERIFIABLE, not
ABSENT: nothing may record "no PRs", "no comments" or "not merged" off a 75.
The sibling library `bin/lib/gh-rest.sh` uses the same number for the same
meaning and its 0/44/75 table is in `docs/verification-map/gh-rest.md`.

## 8. The kill switch

- `GH_SHIM_OFF=1` — exactly `1`; nothing else is off.
- `$HARNESS/flags/gh-shim-off` — the same switch as a file.

Both are checked before any parsing (`bin/gh-rest-shim:134`). On a Fly builder
that flag path is `/data/harness/flags/gh-shim-off`, because
`fly/builder-runner.sh:35` sets `HARNESS=/data/harness`.

Other knobs, all on/off switches for an executable rather than business config
(`bin/gh-rest-shim:16-22`): `GH_REAL` (the real binary when PATH cannot find
it), `GH_SHIM_FALLBACK`, `GH_SHIM_LIB`, `GH_SHIM_MAX_PAGES`.

## 9. The pass-through log

`$HARNESS/logs/gh-passthrough.log`, one line per untranslated call:

```
<ts> <argv0> <argv1> <argv2> pid=<n> caller=<name> reason=<r>
```

Reasons: `untranslated`, `field:<name>`, `no-slug`, `flag:<flag>`, and
`merge-queue` from `pr merge` (`bin/gh-rest-shim:151`, `pr-write.sh:320`).

The line goes down BEFORE the exec, because afterwards the process is gone and
an unlogged pass-through is indistinguishable from a call that never happened.

**The caller's command line is not in the line, and must not be.** A lane
running `gh … --token ghp_…` through `bash -c` would write that token into a
log that lives on the box (iron law 3), and truncating at 80 bytes publishes a
token prefix instead of a token. `gshim_caller` names the PROGRAM, which is the
part an operator needs (`bin/gh-rest-shim:163-167`).

## 10. What passes through unlogged

`api`, `auth`, `--version`, `version`, `help`, `-h`, `--help`, an empty argv,
and any call already inside a shim (`GH_REST_SHIM_DEPTH` set)
(`bin/gh-rest-shim:138-143`, `bin/gh-rest-shim:123-130`). `api` is the REST
path this shim exists to produce; logging it would bury the log in its own
traffic.

## 11. Installation — NOT DONE

**Nothing on any box or builder puts this shim on a PATH today.** `grep -rl
gh-rest-shim` over the tree reaches `bin/gh-rest-shim`, its handlers, `tests/`,
`.harness/specs/`, the verification-map entry and `.github/workflows/harness-ci.yml`
— no symlink, no `update-runners.sh` hook, no cron `PATH=` header. #790 closed
without landing install logic. Every `gh` call on every box still goes to the
real binary.

The operator procedure, for whoever lands it (this is a procedure, not a
description of something that runs):

```bash
ln -sfn /root/harness/bin/gh-rest-shim /usr/local/bin/gh
```

Cron lanes would need more than that: a crontab runs with a minimal PATH, and
no fragment under `cron/` carries a `PATH=` header today (`cron/boxes/`,
`cron/lanes/`; the rendered crontabs have been git-ignored since BH-1247). So
installing the symlink alone would cover interactive and lane-script calls and
miss cron entirely.

## 12. The `pr merge` deviation

On a repo with GitHub's native merge queue, `gh pr merge` ENQUEUES and REST has
no equivalent. GitHub answers the PUT with a 405, and that 405 wrote nothing —
so the handler hands the ORIGINAL argv to the real binary and lets it enqueue
(`pr-write.sh:310-321`). Translating it instead would leave the PR un-queued
and read to the caller as a failed merge.

Every other refusal — 409, 422, another 405 — is GitHub's answer about THIS
merge and is never retried through a second path.

When to flip it to a label path: when every merge-queue repo in the fleet moves
to Mergify labels. They have not.

## 13. `repo clone` and credentials

Cloning is git's job, so this is the one handler that execs something other
than a REST call (`repo.sh:33-73`).

- The origin stays the bare `https://github.com/<slug>.git`.
  `bin/lib/merge-conductor-lib.sh` expects exactly that.
- Auth arrives as a credential HELPER in the environment, never a credential on
  disk and never a token in argv (`repo.sh:70-72`).
- The helper is APPENDED at the next free `GIT_CONFIG_*` index, never index 0
  (`repo.sh:68-72`). `bin/lane-fence.sh:93-94` ships `core.hooksPath` through
  the same variables; clobbering index 0 threw that pointer away and ran the
  clone outside its fence, with no error to say so.

## 14. `run view --log` framing

`--log` and `--log-failed` print one `=== <job name> ===` header per job and
then that job's raw log bytes. gh's `job\tstep\tline` framing is not reproduced
(`actions.sh:10-15`).

The three fleet callers — `bin/pre-arm-guards.sh`, `bin/blocked-resolver.sh`,
`bin/lib/flaky.sh` — grep patterns and tail bytes out of the stream. None reads
the job or the step column. A future caller that wants those columns needs the
real binary, not this handler.

## 15. The REST budget

`bin/lib/gh-budget.sh` resolves its floor in this order: `setting_get
gh_budget_min_remaining` -> `GH_BUDGET_MIN_REMAINING` -> 800
(`gh-budget.sh:19`, `gh-budget.sh:29`). That floor now covers traffic GraphQL
used to carry, because every translated call spends from the core REST bucket
instead. The shim does not raise the ceiling; it moves the spend.

## 16. Operator QA, rungs named honestly

None of this runs in CI, and on a box where the shim is not installed (all of
them, today) none of it can run at all.

| step | what it proves | rung |
|---|---|---|
| `bash tests/gh-passthrough-budget.bh-791-test.sh` | every census form translates, and the two watches log | BUILT |
| `ln -sfn …/gh-rest-shim /usr/local/bin/gh` then `gh --version` | the real binary is still reachable through the shim | DEPLOYED, once a box has it |
| `gh pr view <n> -R <slug> --json state` and compare to `gh api repos/<slug>/pulls/<n> -q .state` | the translation answers what REST answers | LIVE |
| `wc -l $HARNESS/logs/gh-passthrough.log` after a day | which calls the census is still missing | LIVE |
| `GH_SHIM_OFF=1 gh pr view <n> -R <slug> --json state` | the kill switch reaches the real binary | LIVE |

The log file does not exist on any box today, because nothing has ever called
the shim on one.

## 17. Could not read is not a fact (BH-9594)

A REST answer is one of two kinds. A **decision** is a fact the lane may act
on: 200, 304, 404 (the thing is absent), 422 and every other status. A
**could-not-read** tells the lane nothing about the board: 401, 403, 429, 500,
502, 503, 504 (gateway timeout), `000` (no status line: network, timeout), or `GH_REST_REASON`
`rate-limit` or `auth-skipped` with any status.

`bin/lib/could-not-read.sh` holds the rule. `cnr_classify_status <status>
<reason>` classifies a `GH_REST_STATUS` / `GH_REST_REASON` pair, and
`cnr_classify_text <reason>` classifies a free-text skip reason (a status
number counts only after `gh`, `github`, `api` or `http`, never after `#` and
never before ` days`). A lane that gets a could-not-read keeps its fail-closed
reading and calls `cnr_record`, which records the read against the box (see
`docs/STATE-STORES.md`, `box_read_failures`). The local refusals
`quota-reserve`, `bad-args` and `cache-miss` are not recorded: they are not a
fault of the box's credential.

## BH-9555.5 pr_records first

## BH-9555.6 lane budget
