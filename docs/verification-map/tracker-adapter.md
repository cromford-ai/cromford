# Tracker contract and adapters (`bin/lib/tracker.sh`)

**What it is:** one set of ticket verbs every tracker answers the same way
(BH-4075, wave 2 of BH-3979): `list`, `read`, `comment`, `transition`,
`label_add`, `label_remove`, `link_pr`, `close_out`, `waiting_on`. The contract
and the dispatch live in `bin/lib/tracker.sh`. Each tracker is one adapter file:
`bin/lib/tracker/github-issues.sh` (functions `trk_gh_*`, every call through
`bin/lib/gh-rest.sh`), `bin/lib/tracker/board.sh` (functions `trk_board_*`,
the board routes in `docs/BOARD-API-CONTRACT.md`), `bin/lib/tracker/jira.sh`
(Jira Cloud, BH-4076, see [tracker-jira.md](tracker-jira.md)) and
`bin/lib/tracker/linear.sh` (functions `trk_linear_*`, Linear's GraphQL API,
BH-4077; see the Linear section below). It is sourced, never run.

**How an operator reaches it:** no cron line and no screen of its own. The
child filer, `file_children` in `bin/lib/file-children.sh`, picks its lane from
`tracker_adapter <project>`. The lanes listed under "Kind seam" below ask
`tracker_kind` (BH-7919). The two lane
modules call the adapters for the parent ticket: `bin/lib/fc-issues.sh` reads the
parent's labels (`trk_gh_labels`, one GET), posts the split comment
(`trk_gh_comment`) and removes `ai-build` (`trk_gh_label_remove`);
`bin/lib/fc-board.sh` sends every board call through `_trk_board_curl` and reads,
comments on and moves the master with `trk_board_ticket_raw`,
`trk_board_comment` and `trk_board_transition`. The triage lane,
`bin/board-closeout.sh` and the prompts still make their own calls.

**Which tracker a project uses** is the D1 settings row
`tracker_adapter.<project>`, value `github-issues`, `board`, `jira` or
`linear`. There is no seed row. When there is no row, or the worker did not
answer, the fallback is fleet.conf column 4: `-` is `github-issues`, a board
prefix is `board`; only a row selects `jira` or `linear`. A row of `jira` or
`linear` reaching `file_children` logs `FILE_CHILDREN no child-filing lane for
<adapter> (<project>)`, returns 1 and files nothing on any tracker. A row with
any other value (`jira-server`, `Board`, `github`) is refused: `tracker_adapter`
returns 1 with one stderr line naming the row, and `file_children` logs
`FILE_CHILDREN tracker adapter unresolved for <project>` and files nothing.

```bash
bin/jobs-client.sh setting-get tracker_adapter.<project>          # rc 2 = no row
bin/jobs-client.sh setting-set tracker_adapter.<project> board "why"
```

**Return codes**, the same for every adapter: `0` ok; `1` failed (absent
ticket, refused write, a 200 that did not take); `3` this tracker does not
support the verb and nothing was sent; `44` `label_remove` only, the label was
not there (success); `75` rate-limited or unverifiable, passed through from
`gh_rest`, retry later.

**Context** is variables, never arguments: `TRK_SLUG` (GitHub),
`TRK_BOARD_BASE` / `TRK_BOARD_TOKEN` / `TRK_BOARD_TOKEN_VAR` (board), `TRK_LOG`,
`TRK_ERR`, `TRK_DRY` (1 = every write prints `DRYRUN <line>` and sends nothing),
`TRK_REQ_FILE`, `TRK_STRICT`.

**How to drive it** (no network, stubs on PATH):

| what | how |
|---|---|
| the eleven contract cases against both adapters | `HARNESS_TEST_SANDBOX=1 bash tests/tracker-contract-test.sh` (cases in `tests/lib/tracker-contract.sh`) |
| the settings-row dispatch and the port's byte identity | `HARNESS_TEST_SANDBOX=1 bash tests/tracker-port.bh-4075-test.sh` |
| a real dry run of a board split, filing nothing | `FILE_CHILDREN_DRY_RUN=1 bin/run-rollout.sh <board-project> <ticket-id> <KEY> /tmp/rollout-dry` |

The port suite compares the board lane's `decompose-board.log`,
`children/comment.json`, `children/move.json` and call list, and the issues
lane's gh call sequence, against goldens in `tests/fixtures/tracker-port/`
captured from the pre-port tree (`0dab314`) by the suite's own
`TRACKER_PORT_REGEN=<ref>` mode.

**What a live box shows:** nothing new in a build directory except
`children/comment.html` beside `comment.json` on a board split (the body the
adapter turns into the comment request). `decompose-board.log` and
`decompose-gh.log` read exactly as before.

**What usually lies:**

- No row is not an error. Every project runs on the fleet.conf fallback today.
- No root, no row: with neither `HARNESS` nor `H` set, the row is not read at
  all (the client's own default root is the live `/root/harness`, which a lib
  never reaches), and the answer is the fleet.conf fallback.
- A worker outage is silent here: `tracker_adapter` uses the fallback and
  `bin/jobs-client.sh` logs the outage to `logs/jobs-client.log` (with
  `JOBS_ALERT=0`, so no ALERTS line from this reader). A row that says `board`
  on a project the worker cannot reach is filed on the fleet.conf lane.
- A row of `board` on a `-` project routes to the board lane, which then fails
  closed with `no board base` because the project has no board. That is the
  honest outcome; the row is not "fixed up" from fleet.conf.
- `link_pr` is a comment on GitHub and the board (`PR: <url>`) and a real
  attachment on Linear. Nothing calls it yet.
- `waiting_on` is `bin/triage-gate.sh --buildable` verbatim. GitHub Issues has
  no turn or verdict, so it answers `OK` unless a contested hold blocks it.
- GitHub's `tracker_read` refuses (rc 1) a thread at the 200-comment read cap
  rather than decide on a truncated thread.

## Linear (`bin/lib/tracker/linear.sh`, BH-4077)

Every call is one POST of `{query, variables}` to `TRK_LINEAR_API` (default
`https://api.linear.app/graphql`), with `Authorization: <key>`: a personal API
key, no `Bearer`. Nothing in the pipeline calls it yet: triage, run-build and
close-out make their own calls, and `file_children` refuses a Linear project.

**Context:** `TRK_LINEAR_TOKEN` (the key, only on curl's argv),
`TRK_LINEAR_TOKEN_VAR` (its name, which is what `TRK_LOG` shows),
`TRK_LINEAR_TEAM` (the team key; `list` needs it, the other verbs do not),
`TRK_LINEAR_LABEL` (the list filter, default `ai-build`), `TRK_LINEAR_STATES`
(optional JSON from contract status to state name), plus the shared `TRK_LOG`,
`TRK_ERR`, `TRK_DRY`, `TRK_REQ_FILE`.

**Ids:** the Linear identifier (`CRO-12`) or the issue UUID. `id` and `key` are
both the identifier. Every write reads the issue first (UUID, labels, team
states), and that read is sent even in a dry run.

**Status:** `todo|in_progress|review|done|closed`, anything else is 3. A name in
`TRK_LINEAR_STATES` wins, case-insensitive; a name the team has no state for is
1 and nothing is sent. Otherwise by state type, lowest `position` first:
`todo` = unstarted, `in_progress` = started, `done` = completed, `closed` =
canceled, and `review` is the state named "In Review". `close_out` moves to
`done` by default. A 200 whose issue did not land in the target state is 1.

**Return codes:** 429, 5xx, no answer, or a `RATELIMITED` error on any status
(Linear sends it on a 400) is 75. Any other 4xx, a 200 whose `errors` is not
empty (an unknown issue answers `Entity not found` that way), or a mutation
answering `success: false` is 1. `list` follows up to 10 pages and is 1 if
there are more; `read` is 1 when the thread has more than 250 comments.

**Labels:** a workspace label or one of the issue's team, matched
case-insensitively; a label only on another team, or no such label, is 1. The
adapter never creates a label. `label_remove` of a label the issue does not
carry is 44.

**`link_pr`:** `attachmentLinkURL` with the title `PR #<n> <owner/repo>`. Only a
`https://github.com/<o>/<r>/pull/<n>` URL; anything else is 1, nothing sent.

**`waiting_on`** is the shared one: `OK` unless a contested hold blocks it.
Linear has no waiting-on-client turn, and its Asks / triage inbox are out of scope.

| what | how |
|---|---|
| the contract cases and the Linear-only cases, against hand-written GraphQL answers | `HARNESS_TEST_SANDBOX=1 bash tests/tracker-linear.bh-4077-test.sh` (answers in `tests/fixtures/tracker-linear/`) |
| live, against the test workspace (needs its key) | the block below |

```bash
set -a; . /etc/harness/env/<project>.env; set +a
. bin/lib/tracker.sh; tracker_load linear
TRK_LINEAR_TOKEN="$LINEAR_API_KEY" TRK_LINEAR_TOKEN_VAR=LINEAR_API_KEY TRK_LINEAR_TEAM=<KEY>
tracker_list; tracker_read <KEY-n>; tracker_comment <KEY-n> f; tracker_link_pr <KEY-n> <PR url>; tracker_close_out <KEY-n> f
```

**What usually lies:** the fixtures are written to Linear's documented schema,
not recorded from a workspace; the list filter (`labels: { some: { name:
{ eqIgnoreCase } } }`) is the first thing to check if a live `tracker_list`
comes back empty.

## Kind seam, context, refusal guard, ratchet (BH-7919)

**Why.** fleet.conf column 4 is `-` for a Linear or Jira project too. A lane
that read `-` as "GitHub Issues" turned `CRO-12` into GitHub issue #12: a
`Closes #12` line, a BUILD BLOCKED comment, a needs-human hold on the wrong
ticket. Wave 1 of #7916 puts one answer in front of every such decision. No
lane reads Linear or Jira yet.

**The seam** (`bin/lib/tracker.sh`):

| function | answer |
|---|---|
| `tracker_kind <project>` | `tracker_adapter`'s answer (row wins, column 4 fallback, a dry run reads no row), cached per process in `_TRK_KIND_CACHE` keyed by `live`/`dry` and project. A call in the current shell warms the cache; a `$( … )` call does not write it back. Safe under `set -u`. |
| `tracker_context <project> [<lane>]` | loads the adapter and sets its context: github-issues `TRK_SLUG`; board `TRK_BOARD_BASE`, `TRK_BOARD_TOKEN`, `TRK_BOARD_TOKEN_VAR` (board-creds + `bin/internal-token-for.sh`); jira `trk_jira_context`; linear `trk_linear_context`. No stdout. rc 1 sets `TRK_CTX_MISSING` to `kind`, `adapter`, `slug`, `base`, `token` or `context`. It never sets `TRK_LOG`, `TRK_ERR`, `TRK_DRY` or `TRK_REQ_FILE`. A dry run with no token variable does not call `internal-token-for.sh`. |
| `tracker_key_prefix <project>` | jira or linear only: the Linear team key, or the first `write_projects` (else `read_projects`) Jira key. rc 1 for any other kind. Runs in a subshell. |
| `trk_linear_context <project>` (`bin/lib/tracker/linear.sh`) | `LINEAR_API_KEY`, `LINEAR_TEAM`, `LINEAR_LABEL`, `LINEAR_STATES` from the env file; rows `tracker_linear.<p>.team`, `.label`, `.states` win; a row team and an env team that differ is rc 1; under `TRK_DRY=1` no row is read. rc 1 blanks every `TRK_LINEAR_*` but the API and prints one stderr line that names the variable or row, never a value. |

The three board contexts that were built by hand now call `tracker_context`:
`_drb_context` in `bin/deploy-rollback-board.sh` (was a local function named
`tracker_context`), `_ee_board_ctx` in `bin/lib/execute-empty.sh`, and
`fc_file_board` in `bin/lib/fc-board.sh`. fc-board now takes its token through
`internal-token-for.sh` like the other two: a digit-prefixed token variable
resolves, two token variables are refused, and the token is read from the
env file, not from an exported value.

**A child script gets the lib's root as `HARNESS`.** The lib resolves its
root as `${HARNESS:-${H:-}}`. A script it runs as a child process and that can
write (`bin/internal-token-for.sh`, the jobs client) is called with
`HARNESS="$root"`. `internal-token-for.sh` reads only `HARNESS`, else its own
directory: a caller that set only `H` (file-children under
`bin/file-health-ticket.sh`) would have it read the env and write its
once-a-day ALERTS flag beside the lib. That is the first build's suite-reach
refusal (lib-root-records `a6-seed-H`); it shows only when the checkout is
writable by the test user, as in a `nobody`-owned snapshot.
`tests/tracker-kind-seam.bh-7919-test.sh` case C7 pins it.

**The guard.** `trk_gh_issue_number <project> <key>` is the only place a KEY
becomes a GitHub issue number:

| tracker | key | answer |
|---|---|---|
| github-issues | `12`, `BH-12`, `bh-12` | `12`, rc 0 |
| github-issues | `BH-7916.1`, `CRO 12`, `TS2-12`, empty | nothing, rc 1 |
| board, jira, linear, a typo row, an unknown project | any | nothing, rc 3 |

The ported sites, each of which posts nothing to GitHub on rc 1 or 3:
`TICKET_META` and `TICKET_THREAD_SIG` (`bin/lib/rb/plan.sh`), the
`CLOSES_LINE` block (`bin/lib/rb/pr.sh`, so a non-GitHub tracker gets no
`Closes #N` and no `Refs #N`), `escalate_block` (`bin/lib/rb/execute.sh`),
`issue_closures` (`bin/wake-loop.sh`), `_ee_post_human` / `_ee_lift_epoch`
(`bin/lib/execute-empty.sh`), and the replan comment (`RPC_N`,
`bin/lib/rb/plan.sh`), which on a refusal writes `replan-comment-skipped` and
one `replan comment skipped: not a GitHub issue` pipeline.log line, never
`replan-commented`.

**Identity.** `ticket_identity <harness> <project> <id>`
(`bin/lib/ticket-identity.sh`) accepts an issue number on github-issues, a
board id on a board, and `<PREFIX>-<n>` on jira or linear with PREFIX from
`tracker_key_prefix` (case-insensitive). Source (a2) of
`ticket_identity_conflict` uses it, so a linear project derives no
`<PREFIX>-<id>` issues key. `preplan_key_prefix` (`bin/lib/preplan-lib.sh`)
answers `tracker_key_prefix` for jira and linear and never greps
`prompts/<project>.md` for them.

**The ratchet.** `tests/tracker-direct-calls-ratchet.bh-7919-test.sh` scans
every bash file under `bin/` (comment lines dropped; `bin/lib/tracker.sh` and
`bin/lib/tracker/*.sh` excluded) for `board_prefix`, a `gh_rest` / `gh api` /
`gh-rest-shim` line with `/issues`, `gh issue`, and a `curl` line with
`/tickets` or `/boards`. A file that matches must be listed in
`tests/fixtures/tracker-direct-allowlist.txt` (sorted, unique, `#` comments).
A new file fails the suite and names its line. A listed file with nothing left
prints a NOTE and passes. A wave that moves a file onto the seam removes its
line. The ratchet is per file.

| what | how |
|---|---|
| the seam and the Linear context | `HARNESS_TEST_SANDBOX=1 bash tests/tracker-kind-seam.bh-7919-test.sh` |
| the guard, identity and the ported sites | `HARNESS_TEST_SANDBOX=1 bash tests/tracker-identity-nonnumeric.bh-7919-test.sh` |
| no `Closes #` / `Refs #` for a non-GitHub tracker | `HARNESS_TEST_SANDBOX=1 bash tests/pr-body-no-closes-nongh.bh-7919-test.sh` |
| the ratchet | `HARNESS_TEST_SANDBOX=1 bash tests/tracker-direct-calls-ratchet.bh-7919-test.sh` |

**What usually lies:** a worker outage makes `tracker_kind` fall back to
column 4, so during an outage a Linear project with column 4 `-` reads as
github-issues for that process. The row is the truth; the fallback is today's
rule.
