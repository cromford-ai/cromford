# 2026-09-22 — BH-1539: the remote gate's nested excludes, its HEAD line, and its stderr

Doc: REMOTE-GATE

The five follow-ups the Fable review of #1535 left on `bin/remote-gate.sh`. Three
were defects in the composed job, two were behaviours that worked and had only
ever been checked by hand.

## What changed

1. **Excluded directories are restored at any depth.** The job put back tracked
   files the upload drops (`.claude`, `node_modules`, `.codegraph`) with
   `git ls-files --deleted -- .claude node_modules .codegraph`, which names
   TOP-LEVEL pathspecs. `rsync --exclude .claude` drops that name wherever it
   appears, so a tracked `tests/fixtures/x/.claude/nested.md` stayed deleted on
   the host: a clean tree grew a "the uncommitted work in the upload" commit and
   the file appeared in every `origin/main...HEAD` diff a suite took. The restore
   now filters all deleted paths through `grep -E '(^|/)(\.claude|node_modules|\.codegraph)/'`,
   which anchors on a whole path segment, so a sibling `my.claude-thing/` is left
   alone.
2. **The host line names the real `HEAD`.** It printed
   `HEAD $(git rev-parse HEAD)` AFTER the snapshot commit, so on a dirty upload
   the sha in the line existed on no branch and in no clone. It now prints
   `HEAD <client HEAD>`, plus ` (+ uncommitted work as <sha>)` when a snapshot
   commit was made.
3. **`--` mode keeps stderr on stderr.** `$q 2>&1 | tee "$R/cmd.log"` merged the
   streams, so a caller capturing stdout got both and
   `remote-gate.sh . -- cmd 2>/dev/null` was not usable. The command now runs
   `$q 2>"$R/cmd.err" | tee "$R/cmd.log"` and the job replays `cmd.err` to its
   own stderr after the command; `$rc` still comes from `PIPESTATUS[0]`.
   Interleaving between the streams is lost, the streams themselves are correct.
   The `no merge base` BLIND rule reads BOTH files, because under `2>&1` it saw
   stderr and narrowing it to stdout would have quietly loosened the rule.
4. **The exit-125 merge-base mismatch guard is pinned** (`tests/remote-gate.bh-1539-test.sh`
   cases 1a-1c): a forged or deleted `refs/remotes/origin/main` in the uploaded
   context exits 125, names both merge bases, runs no suite and removes the run
   root, in suites mode and in `--` mode.
5. **The BLIND rule's mid-line negative control is pinned** (cases 2a-2b): a
   suite printing `FAIL: expected no merge base` or `#3 b: no merge base with
   origin/main` — the phrase NOT at line start — is a clean pass. The positive
   control stays in `tests/remote-gate.bh-1527-test.sh` (4a-4d).

## Verification

`tests/remote-gate.bh-1539-test.sh`, 26 assertions, all through the real composed
job (ssh/rsync/flyctl are PATH shims; the rsync shim excludes by basename at any
depth as real rsync does). Every one of the five behaviours was mutation-checked:
reverting the restore to top-level pathspecs, dropping the label, printing the
synthetic sha, restoring `2>&1`, dropping the stderr arm of the BLIND check,
neutering the merge-base comparison, and removing the `^` from `RG_BLIND_RE` each
turn cases red. `tests/remote-gate.bh-1527-test.sh` (22/0) and
`tests/remote-gate-test.sh` are unchanged and green.

## Not done

Review findings 5 and 6 (a shared CI definition, the `REMOTE_GATE_BASE` sentence)
are not in the ticket and are not in this change.
