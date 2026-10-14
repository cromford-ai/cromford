# A full hub /tmp now says so, and the patch-id rebind stops leaking askpass files (BH-4464)

Doc: MERGE-CONDUCTOR

## What changed

- **The real reason is logged.** When `git worktree add` fails in `mc_rebase` or
  `mc_restack` (`bin/lib/mc/rebase.sh`), the log line now carries the last
  `fatal:`/`error:` line of git's stderr, picked by the new `mc_git_fail_line`.
  It used to be `head -1`, which is git's progress line
  (`Preparing worktree (detached HEAD …)`). That progress line was the only
  reason the hub logged while /tmp was full. If no line starts with
  `fatal:`/`error:`, the last non-empty line is logged instead, and empty
  stderr logs `(no stderr)`. Tokens are redacted and the line is capped at 160
  characters, as `mc_git_err_line` does. The fetch sites are unchanged.
- **rc 8 = tmp full.** `mc_rebase` and `mc_restack` call `mc_tmp_room` before
  `mc_git_auth`. If `${TMPDIR:-/tmp}` has less than `MC_TMP_MIN_FREE_MB` free,
  they log `<url> <lane>: tmp full (<n> MB free on <dir>, need <min> MB) — rc 8,
  nothing fetched` and return 8. No askpass helper is created, nothing is
  fetched and nothing is cloned. The pool path (`REBASE_ON_POOL`) is checked
  first and never reaches the precheck. If df fails or prints no number, the
  precheck lets the rebase through.
- **`rebase_result` has an `8)` arm.** It logs `<key> rebase refused: hub tmp
  full — nothing spent, retried next tick` and moves the row to NEEDS_REBASE
  with reason `tmp full, retry`. That is the same transition the `*)` arm
  makes. The other rc readers (blocked-resolver, rebase-train-ahead, the
  stack-follow, pr-url-reconcile) already treat an unknown rc as "setup failed,
  retry" and were not edited.
- **Knob `MC_TMP_MIN_FREE_MB`** (merge-conductor lane, default 256, `0` turns
  the check off; an empty or non-integer value means 256).
- **The askpass leak.** `mc_patch_wt` (`bin/lib/mc/settle.sh`) now sets
  `MC_PATCH_WT` and prints nothing, and `mc_patch_id`/`mc_patch_same` call it
  in their own shell. Before this, `wt=$(mc_patch_wt …)` armed `mc_git_auth`
  inside the command substitution. The helper file was created there and its
  name died with the subshell, so the caller's `mc_git_auth_clear` had nothing
  to remove. Each call leaked one `mc-askpass-*`, and the hub had 32,510 of them
  on 2026-10-04. One more effect of the fix: the patch-id fetch now runs with
  `GIT_ASKPASS` exported. Before, it ran unauthenticated. On a private repo, a
  patch-id rebind that used to fail closed (and pay for a re-review) can now
  succeed. That is what BH-2310 intended.

## Still owed (C1 of #4464, after #4454 / BH-4440 merges)

- A hub /tmp sweep: top-level entries older than 12h that are not a live cwd,
  and `gh-cli-cache` older than 1h. It also catches the one askpass file a
  SIGKILL'd detached rebase can still leave behind.
- An alert at 80% /tmp use through #4440's disk alert.

Neither is built here, because #4454 adds its own /tmp sweep and disk alert in
the same files.
