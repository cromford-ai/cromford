# Act-time iron-law guard

**What it is:** a PreToolUse hook on Bash that mechanically DENIES the six
irreversible families the machine-wide rules forbid in prose — merging a PR,
pushing (main, and since BH-2741 any branch from a guarded lane), pointing prisma at a live DB, writing a prod DB with a raw client,
deploying/promoting on Vercel, and pointing a destructive filesystem verb at the
harness's own state — at the moment an agent reaches for them. It is
`bin/iron-law-guard.sh`, one stateless process per Bash call. It holds no lock,
keeps no cross-run state, and spawns nothing that outlives it.

**How an operator reaches it:** it is wired in three places, all running the
same script.

| wiring | lanes | families judged |
|---|---|---|
| `bin/agent-call.sh` (`PreToolUse`, `timeout:30`) | `plan execute review fix qa triage` | 1-6 |
| `bin/iron-law-arm.sh` | orchestrator, box-chat, greenfield | 6 only |
| `bin/lane-shims/_fence.sh` (PATH shim) | codex, gemini, grok | same classifier, reads rc 2 as a deny |

A session with no `HARNESS_LANE` marker is not a harness session and the hook has
no opinion on it at all — including when it crashes.

**The four verdicts.** Every path out of the script is one of these, and it is
decided exactly once (`DECIDED`). The verdict IS the exit code.

| verdict | exit | what the operator sees |
|---|---|---|
| allow | 0 | nothing |
| deny | 2 | the reason on stderr, one `family=actguard-*` row in `logs/findings.log` (family 6 also alerts) |
| INERT (self-diagnosed degrade) | 0 | one `iron-law guard INERT` line in `logs/ALERTS.log` — denies nothing |
| crash-block | 2 | one `[iron-law] guard crashed: <why>` line, and the refusal shape on stdout |

The last one is #409. Before it, a guard that ended without deciding exited with
the shell's own status — 143 on a SIGTERM — and the CLI reads any status other
than 2 as a non-blocking hook error and runs the tool call. The alert it filed
said `CRASHED (rc=0) ... that Bash call ran UNGUARDED`, with rc=0 because bash
runs the EXIT trap from its signal handler with `$?` of the last *completed*
command. It now traps TERM/INT/HUP and routes every undecided exit through the
same block.

The split between INERT and crash-block is who noticed. A guard that diagnoses
its own degrade (no jq on PATH, an empty or non-JSON payload, a child killed by
its own bound) knows what is wrong with it and steps aside; a guard killed
mid-thought knows nothing about the command it was judging, so it fails closed.

**Who sends the SIGTERM.** Two senders reach this hook:

1. **The stage window.** Every runner in `bin/agent-call.sh` runs under
   `timeout --kill-after=120 "$TO"`. GNU timeout puts itself and its child in
   their own process group and signals the whole group on expiry, so a hook in
   flight when a stage deadline lands is killed alongside `claude`. The session
   is dying either way, but the verdict must still be a block and the ALERTS line
   must stop claiming an unguarded call ran.
2. **The CLI's own hook budget** (`timeout:30` in `bin/agent-call.sh`). This is
   **the one remaining fail-open** and no exit code can answer it: a hook the CLI
   has ABANDONED is ignored whatever it prints. The defence is staying under it,
   so every child the guard spawns carries a `timeout 5` — read 3s + jq 5s +
   awk 5s + git 5s is ~18s worst case, plus the agent-push hold read below
   (6s) on that one deny path, ~24s. SIGKILL (the `--kill-after=120` second
   stage) is the same shape and is untrappable by construction.

**Family 2 has two rules (BH-2741).** `push-main` is judged first and keeps its
name. `agent-push` is every other `git push` from a guarded lane: those lanes
commit, and the harness pushes the branch after the session through
`bin/lib/hold-push.sh`, which re-reads the ticket's HOLD at the push. After the
deny is decided, the guard runs ONE `hold_push_verdict` read (`timeout 6`, with
`HARNESS_LANE` dropped so a codex lane's `gh` shim does not re-enter the guard).
The one findings row then ends in ` :: hold=held …`, `hold=clear …`,
`hold=unreadable …` or `hold=unchecked (…)`. A held ticket also puts
"The ticket is on HOLD (…)" in the model's reason. The read can change that
wording and never the verdict. `hold_push` runs its own `git push` with
`HARNESS_LANE` unset (a subshell `unset`), so the PATH shim and the pre-push hook do not refuse the
sanctioned push. The remediator is not a guarded lane; its `git push` is denied
by `Bash(git push:*)` in `bin/remediator-settings.json`.

**Family 7: the review lane on a live harness box (BH-8103).** On 2026-10-23
00:18Z the conductor's re-review agent ran `git checkout -q pr8069` in the hub's
`/root/harness-checkout` and then ran a test suite there as root. Family 7 is
judged only on `HARNESS_LANE=review` on a live box. A box is live when
`${HARNESS_CHECKOUT:-/root/harness-checkout}/.git` exists (the hub and every
Orgo box; not Fly pool machines or CI). `HARNESS_LIVE=1` or `HARNESS_LIVE=0`
overrides that test. Two rules, findings row only (no ALERTS line):

| rule | denies | still allowed |
|---|---|---|
| `review-checkout` | `git checkout/switch/reset/pull/merge/rebase/restore/stash/cherry-pick/am` and `gh pr checkout`, when the dir (`-C`, else the cwd after any `cd`) is under the deploy checkout, `$HARNESS`, `/root/harness`, `/root/repos` or `/root/orchestrator` (each also through `readlink -f`), or cannot be resolved | read-only git (`log show diff fetch worktree add stash list …`) anywhere; any verb in the lane's own clone or worktree elsewhere, or strictly inside a shared root when it is the lane's `HARNESS_LANE_WT`/`WT`/`BUILD_DIR` |
| `review-suite` | a run of `tests/**/*.sh`, `bin/test-impact-gate.sh` or `bin/fast-lints.sh`: direct, through `bash`/`sh` (flags, `timeout`, `VAR=` and `bash -c` included), or as the body of a `for` loop over suite paths | `bash -n <suite>`, and reading a suite (`cat`, `grep`, `sed`, `shellcheck`) |

The deny text tells the model to keep the review static and to say in its review
that a suite was not run here. Honest limits: `find -exec`, `xargs`, `while read`
loops, `source` and a script the session writes get through, and on a
codex/gemini/grok lane only the shimmed `git`/`gh` reach the guard. The
re-review agent also starts in a private scratch dir (`MC_RR_SCRATCH_ROOT`,
docs/notes/2026-10-23-BH-8103-review-lane-live-box.md).

**How to drive it:**

| what | how |
|---|---|
| the six families, the lane fence, findings shape, heredoc bodies | `bash tests/iron-law-guard-test.sh` |
| the crash path — signals, internal errors, bounded children | `bash tests/iron-law-guard-signal-test.sh` |
| family 6 (filesystem targets) in depth | `bash tests/iron-law-fs-test.sh` |
| the arming wiring for the conversational lanes | `bash tests/iron-law-arm-test.sh` |
| the same classifier reached through the PATH shim | `bash tests/lane-fence-test.sh` |
| agent-push: the hold named in the finding, the codex path, `hold_push` still landing | `bash tests/agent-push-guard.bh-2741-test.sh` |
| no agent prompt tells the agent to push | `bash tests/agent-push-ratchet.bh-2741-test.sh` |
| family 7: the review lane on a live box (checkout moves, suite runs) | `bash tests/iron-law-live-review.bh-8103-test.sh` |
| the re-review agent's private scratch cwd | `bash tests/mc-rereview-scratch-cwd.bh-8103-test.sh` |

Clear the box's own lane marker first, or the fence cases inherit it and go red
for a reason that has nothing to do with the code:
`env -u HARNESS_LANE -u HARNESS_LANE_PROJECT -u HARNESS_LANE_WT -u IRON_LAW_LANES bash tests/…`

**The one-liner that shows the crash contract working**, against a scratch
`$HARNESS` (it writes only into `$T`):

```sh
T=$(mktemp -d); mkdir -p "$T/logs"; mkfifo "$T/r.fifo"; exec 8<>"$T/r.fifo"
jq -nc --arg c 'gh pr merge 1' --arg d "$T" \
  '{session_id:"s1",hook_event_name:"PreToolUse",cwd:$d,tool_name:"Bash",tool_input:{command:$c}}' >&8
env -u HARNESS_LANE HARNESS="$T" HARNESS_LANE=execute HARNESS_LANE_PROJECT=testproj \
  bash /root/harness/bin/iron-law-guard.sh <&8 >"$T/out" 2>/dev/null & G=$!
sleep 0.2; kill -TERM $G; wait $G; echo "rc=$? stdout=$(cat "$T/out")"; exec 8>&-
cat "$T/logs/ALERTS.log"
```

Working box: `rc=2`, stdout `{"decision":"block","reason":"guard crashed: SIGTERM"}`,
and exactly one `[iron-law] guard crashed: SIGTERM` line. A box printing `rc=143`
with empty stdout is running a guard from before #409 and is not guarded against
a stage-window kill.

**Files it owns on a live box:**

- `logs/findings.log` — one `lens=act-guard verdict=BLOCK family=actguard-<rule>`
  row per real deny. `bin/rule-miner.sh` walks these. The crash path writes no
  findings row, so a crash mints no family and does not skew recurrence mining.
- `logs/ALERTS.log` — the three tokens an operator greps for:
  `[iron-law] guard crashed` (crashed, and the call was BLOCKED),
  `iron-law guard INERT` (degraded, calls are running unguarded),
  `iron-law guard MISSING` (no guard script on the box at all).

**What must never regress:** an ordinary build command stays untouched (exit 0,
silent); a real deny is never reported as a crash; one crash files exactly one
ALERTS line however many signals land; an unmarked session gets no opinion even
on a crash; a self-diagnosed degrade still denies nothing; and the guard reaches
a verdict on its own clock, never the caller's. The command string never reaches
the crash line — only a signal name or an rc — so a crash cannot become a new
path for a connection string into ALERTS.log.
