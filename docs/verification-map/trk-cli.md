# `trk` — the ticket tracker CLI

**What it is:** `bin/trk`, one command per verb of the tracker contract
(`bin/lib/tracker.sh`). A watcher session for a Jira or Linear project reads and
writes its tickets with it and never holds a token, an API URL or a hand-made
call. It is the twin of `bin/gh-rest-shim` for tickets. It resolves the
project's tracker and context, calls one contract verb, and passes the
contract's return code through. It never prints a `TRK_*` value.

**How an operator reaches it:**
- By hand: `/root/harness/bin/trk <verb> <project> [<id>] [args]`.
- In a watcher prompt: `bin/load-project.sh` renders a NEW
  `prompts/<project>.md` through `_obs_prompt_render`
  (`bin/lib/onboard-stations.sh`). When `tracker_kind <project>` is `jira` or
  `linear`, the render puts the block from `prompts/_template/trk-commands.md`
  in place of the GitHub Issues command block, and the header line says
  `(Jira tracker)` or `(Linear tracker)`. It prints
  `prompts/<p>.md rendered (trk commands, tracker <kind>)`. Any other kind, or
  no answer, renders the GitHub prompt byte for byte as before.

**Verbs:**

| Command | Contract verb |
|---|---|
| `trk list <p> [--state open\|all] [--label <l>] [--since <iso>]` | `tracker_list`, its JSON printed as is |
| `trk read <p> <id>` | `tracker_read`; header lines, then UNTRUSTED INPUT blocks |
| `trk comment <p> <id> (--body <t> \| --body-file <f>)` | `tracker_comment` |
| `trk transition <p> <id> <todo\|in_progress\|review\|done\|closed>` | `tracker_transition` |
| `trk label-add <p> <id> <label>` / `trk label-remove <p> <id> <label>` | `tracker_label_add` / `tracker_label_remove` |
| `trk link-pr <p> <id> <https url>` | `tracker_link_pr` |
| `trk close-out <p> <id> (--body … \| --body-file …) [--status <s>]` | `tracker_close_out` (comment, then status; default done) |

`trk read` prints `id:`, `key:`, `status:`, `labels:`, `waitingOn:`,
`triageVerdict:`, `url:`, then `Title: <title>` and the body in one
`ui_wrap ticket-body` block, then `comments: <n>` and per comment a
`--- comment <i> of <n> (<createdAt>[, internal])` line and one
`ui_wrap ticket-thread` block holding `author: <name>` and the body
(`bin/lib/untrusted-input.sh`).

**Exit codes:** 0 ok (a write prints `trk: <verb> <id> ok` only when it was
sent); 1 failed (`trk: no tracker context for <p> (missing: <what>)`, an absent
ticket, a refused write); 2 usage error, nothing read or sent; 3 unsupported by
this tracker; 44 label-remove, the label was not there; 75 rate limited, never
"absent".

**Env:** `TRK_DRY=1` prints `DRYRUN <line>` for each write and sends nothing
(the issue reads before a write are still sent). Empty or `0` is live. Any other
value is rc 2. The tracker and context are resolved live even when dry.
`TRK_LOG` is the write log, default `$HARNESS/logs/trk.log`; empty = no log.
`TRK_ERR` takes the adapter's curl stderr (empty = `/dev/null`).

**How to drive it:**
- `HARNESS_TEST_SANDBOX=1 bash tests/trk-cli.bh-8450-test.sh` — every verb
  against a Linear stub, the key never on stdout or in the log, `TRK_DRY=1`
  sends no write.
- `HARNESS_TEST_SANDBOX=1 bash tests/trk-prompt-render.bh-8450-test.sh` — the
  render for linear, jira, github-issues, board and a refused row.

**Not done yet:** the two existing sandbox prompts
(`prompts/cromford-sbx-linear.md`, `prompts/cromford-sbx-jira.md`) are not
converted; an existing prompt keeps the "exists — skipping" path. The launch
line, the duplicate check and the results sweep in a rendered prompt still use
GitHub issue numbers (wave 3 of #7920).
