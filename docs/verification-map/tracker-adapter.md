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
`trk_board_comment` and `trk_board_transition`. The triage gate reads a Jira
or Linear project through the contract (see "List filters and the triage
gate" below). The rest of the triage lane, `bin/board-closeout.sh` and the
prompts still make their own calls.

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
For a project whose env file sets `LINEAR_API_KEY` and whose row is `linear`,
the gate reads the ticket first (`tracker_read`): a read it cannot make is
`BLOCKED unreadable` under `TRK_STRICT=1`.

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

## List filters and the triage gate (BH-7920)

**The filters.** `tracker_list [--state open|all] [--label <name>] [--since <iso>]`.
With no flag each adapter sends the request it always sent: GitHub
`state=open labels=ai-build`, the board's two routes, Jira's JQL with
`statusCategory != Done`, Linear's filter with `nin: ["completed", "canceled"]`.
The values reach the adapter as `TRK_LIST_STATE`, `TRK_LIST_LABEL` and
`TRK_LIST_SINCE`, set for that one call. GitHub sends them as the `state`,
`labels` and `since` params. Jira puts them in the JQL; `--since` adds
`updated >= "<the UTC day before>"`, because JQL reads a date in the API
user's time zone. Linear adds `updatedAt: { gte: $since }` and declares
`$since` only then. The board has no server filter. After the adapter answers,
`tracker_list` runs one check on every row, whatever the server did: `--state
open` keeps `state == "open"`, `--label` compares case-insensitively, and
`--since` compares epoch seconds and KEEPS a row with a null `updatedAt`. A
bad flag (unknown, no value, a state other than `open|all`, a label outside
`[A-Za-z0-9_.: -]{1,100}`, a `--since` that is not `YYYY-MM-DDTHH:MM:SS[.f]Z`)
is rc 1 with one stderr line, and nothing is sent.

**The row keys.** Every list row also carries `updatedAt` (UTC
`YYYY-MM-DDTHH:MM:SSZ`, no fraction, or null), `state` (`open|closed`) and
`commentCount` (an integer, or null when the tracker gave no exact count).
GitHub: `updated_at`, `state`, `comments`. Board: `lastActivityAt` (else
`updatedAt`); `closed` for `done closed cancelled canceled archived`;
`commentCount` only when the board sends a number. Jira: `fields.updated`
(offset turned to UTC), `closed` when the status category is `done`,
`fields.comment.total`. Linear: `updatedAt`; `closed` for state type
`completed` or `canceled`; the number of comment ids on the row's first page,
or null when that page has more. `tracker_read` carries the same `state` by
the same rule (BH-8449, below).

**The Linear knob.** The settings row `tracker_linear.<project>.list_comment_cap`
(integer 1..50, read by `trk_linear_context`) is how many comment ids one list
row asks for. No row is 25. A value outside 1..50 fails the context (rc 1, one
stderr line naming the row). The bound keeps `issues(first: 100)` x
(`labels(first: 50)` + comments) under Linear's 10,000 point complexity limit.

```bash
bin/jobs-client.sh setting-set tracker_linear.<project>.list_comment_cap 10 "why"
```

**The triage gate** (`bin/triage-gate.sh`, generic arm). When the project's env
file sets `JIRA_BASE` or `LINEAR_API_KEY`, the gate asks `tracker_kind`. A
`jira` or `linear` answer loads `tracker_context <project> triage-gate` and the
gate reads through the contract in every mode:

- the fingerprint (plain mode, `--seed`, `--pending`) is
  `{"jira"|"linear": [{id,key,status,state,title,updatedAt,commentCount,waitingOn,triageVerdict}]}`
  from `tracker_list --state open --label <the project's label>`, sorted by id.
  A changed fingerprint is `RUN board-changed`, unless every moved row moved
  only by our own comments (`SKIP self-writes-only`, BH-8449, below).
  A list that fails is `RUN gate-fetch-failed` and `--pending` exits 1.
- `--thread` and `--signal` read `tracker_read` as an `inapp` doc.
- `--buildable` reads `trk_jira_gate_raw` (Jira) or `tracker_read` (Linear).
- the split-chain, gate-reoffer and inapp-deps wakes stay off, as they were.

A context that does not load writes one ALERTS line (at most one per project
per day, `flags/alerted-token-<p>-<day>`), then answers `BLOCKED
token-unresolved` (`--buildable[-strict]`), exit 1 (`--pending`, `--signal`,
`--thread`), `SEED-FAILED` (`--seed`) or `SKIP token-unresolved` (plain). Any
other kind (a `board` row, no row, a worker that did not answer) is the
GitHub or board arm, as before. A project with neither env key makes no
settings call.

| what | how |
|---|---|
| contract case C12 against the four adapters, the request of today, the Linear knob | `HARNESS_TEST_SANDBOX=1 bash tests/tracker-list-filters.bh-7920-test.sh` (case in `tests/lib/tracker-contract-c12.bh-7920.sh`) |
| the real gate on a Linear project | `HARNESS_TEST_SANDBOX=1 bash tests/triage-intake-linear.bh-7920-test.sh` (stub `tests/lib/linear-stub.bh-7920.sh`) |
| the real gate on a Jira project | `HARNESS_TEST_SANDBOX=1 bash tests/triage-intake-jira.bh-7920-test.sh` |

**What usually lies:** the gate reads `env/<project>.env` and the row
`tracker_adapter.<project>`. A sandbox whose env file or row is named for a
different project name keeps the GitHub arm. A Linear project with no
`LINEAR_API_KEY` in its env file also keeps the GitHub arm.

## Wake and scope on the contract (BH-8449)

**The read's `state`.** `tracker_read` prints an 11th key, `state`
(`open|closed`), on all four adapters, by the list row's rule: GitHub
`.state == "closed"`; board, a lower-cased status of `done closed cancelled
canceled archived` (one `_TRK_BOARD_STATE` expression for the list and the
read); Jira status category `done`; Linear state type `completed` or
`canceled` (the `TrkIssue` query asks `state { name type }`). Anything else, a
missing field included, is `open`.

**The wake key.** A Linear or Jira delivery makes a `kind=issue` wake row
keyed on the ticket key (`CRO-12`), and `bin/wake-loop.sh` keeps that key in
the launch's `state/wake-keys-<p>`. `issue_closures` reads a jira or linear
project's keys through `tracker_context` + `tracker_read` and prints the ones
whose `state` is `closed`. A key that is not `^[A-Z][A-Z0-9_]{0,19}-[1-9][0-9]{0,8}$`
is skipped with no read, a failed read is skipped, and a context that does not
load is rc 1. `released_by` still keeps digits only, so a closed Linear key
releases nothing yet (C3 of #7920 ports `bin/unblocked-children.sh`).

**The scope.** `bin/lib/rt/scope.sh` `_rts_trk_kind` asks `tracker_kind`
only when the project env sets `JIRA_BASE` or `LINEAR_API_KEY`. For a jira or
linear answer, `board_section` uses the gate diff as the whole scope (rc 0:
`BOARD_OK=1` and the "ALSO changed on the board" text; rc 2: `BOARD_OK=1`,
no text) and runs none of `bin/unblocked-children.sh`, the hotfix marker, the
stack filter or the in-app release lanes. `inapp_released_lines` returns at
once for such a project, whatever column 4 says. A GitHub or board project
makes no settings call and takes the same path as before.

**Self-write absorption.** The settings row
`tracker_<jira|linear>.<project>.self_actors` holds our comment authors,
comma-separated, as `tracker_read` prints them (Linear `displayName`, else
`name`, else `botActor.name`; Jira `displayName`). There is no seed row, and
no row means no absorption: a changed fingerprint is `RUN board-changed`.
With a row, `gate_trk_selfwrite` (`bin/lib/gate-trk-selfwrite.sh`) runs
`bin/gate-selfwrite.py` in `GATE_SELFWRITE_MODE=ids`: only `commentCount` and
`updatedAt` may move, the count must go up, at most 5 rows. Then it reads each
moved ticket, and the newest `new - old` comments must each have an author in
the row (exact match after a trim). Only then does the gate move
`gate.pending` onto `gate.json` and print `SKIP self-writes-only`. Any other
answer, or any failed read, is `RUN board-changed`.

```bash
bin/jobs-client.sh setting-set tracker_linear.<project>.self_actors "Harness Bot" "our Linear comment author"
```

| what | how |
|---|---|
| scope routing and `issue_closures` on the contract, the read's `state` | `HARNESS_TEST_SANDBOX=1 bash tests/scope-trk-route.bh-8449-test.sh` |
| the real gate's absorption on Linear and Jira | `HARNESS_TEST_SANDBOX=1 bash tests/gate-trk-selfwrite.bh-8449-test.sh` |
| a signed Linear delivery through the real worker, the real wake-loop and the real gate | `HARNESS_TEST_SANDBOX=1 bash tests/webhook-to-triage-linear.bh-8449-test.sh` (stage 1 `tests/lib/linear-wake-worker.bh-8449.mjs`) |

**What usually lies:** the worker route row `webhook_route.linear.<team>` names
a repo, and that repo must be the fleet.conf repo of the project whose
`tracker_adapter.<project>` row says `linear`. A route row that names another
spelling of the repo makes a wake row no loop claims. The worker also needs
`LINEAR_WEBHOOK_SECRET` (or `JIRA_WEBHOOK_SECRET`) and the vendor webhook
registered; until then the route answers 503 and only the 10-minute cron tick
sees a change.

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
