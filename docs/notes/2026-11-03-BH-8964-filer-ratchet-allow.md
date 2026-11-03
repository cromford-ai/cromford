# BH-8964: allow bin/ci-image-rollout.sh in the filer-caller ratchet

Doc: tests/file-children.bh-981-test.sh

## What failed

PR #8942 (BH-7256) left the merge queue on 2026-11-02 in batch run 41428114263,
shard "Tests, traced (shard 0/8)". One assertion in
`tests/file-children.bh-981-test.sh` failed on one line:

```
FAIL: only bin/run-decompose.sh (+ its lane module) and bin/run-rollout.sh may call the filer (found):
bin/ci-image-rollout.sh:82:. "$HERE/lib/file-children.sh" 2>/dev/null || { echo "ci-image-rollout: cannot read $HERE/lib/file-children.sh" >&2; exit 2; }
```

`bin/ci-image-rollout.sh` sources `bin/lib/file-children.sh` for one function,
`fc_board_base`. It files its children through its own `gh api` and app-board
calls, never through `file_children` or an `fc_file_*` function. That is the
same use `bin/file-health-ticket.sh` makes (BH-1955).

## What changed

- The `CALLERS` exclusion list adds the exact path `^bin/ci-image-rollout\.sh:`,
  with a comment that says why.
- A new `CIR=` pin, the twin of the `FHT=` pin, holds that file to
  `fc_board_base` only. Any other `file_children` or `fc_*` use in it fails the
  suite. A comment line is still not a caller.

The lint does not get weaker. Every other file is still held by the `CALLERS`
grep. On main the pin is inert: `bin/ci-image-rollout.sh` does not exist there.

## Step left

Requeue #8942 after this PR is on main. Its head does not move, so its
head-bound approval stays valid. Its next queue batch (main + #8942) carries
this allow entry, and the ratchet passes.
