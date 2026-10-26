# The conductor's pulls/{n} reads come from the PR record and the open list (BH-8457)

Doc: docs/MERGE-CONDUCTOR.md

## Why

After #8423 the GitHub App installation quota still ran out every hour. The
gh-calls ledger on bh-hub-2 (12:00-12:26Z, 2026-10-26, merge-conductor.sh
only) showed 2,071 `GET repos/{o}/{r}/pulls/{n}` of 2,688 calls. Three causes:

1. `_hpl_state_get` (bin/lib/gh-pr-list.sh) never serves a stored body in a CI
   state (blocked, unstable, has_hooks), so every such row was read live on
   every tick.
2. A keyed tick (`MC_ONLY_PR`) listed every open PR with the merge-state
   fields and filtered to the woken PRs only after that, so each wake cost one
   `pulls/{n}` per open PR.
3. The QUEUED pass read each QUEUED row twice per tick (`mc_pr_view`, then
   `mc_queue_state`).

## What changed

- `bin/lib/pr-record-serve.sh` (new). `prr_serve_state` answers a row's
  merge-state read from the PR record (`pr_record_peek`, one jobs GET, no
  GitHub call) when the row is this repo's, open, at the list head, has a
  known `mergeable_state`, and is at most `PR_RECORD_SERVE_MAX_AGE_S` old
  (default 120, 0 = off; `catalog/lanes.d/_lib.pr-record.knobs.d/`). A miss
  reads as before, and a live answer is written back into the record
  (`prr_serve_note`, source github). A failed write is one
  `logs/pr-record.log` line: `serve-note <repo>#<n> put=failed`.
- `bin/lib/gh-pr-list.sh`: with `HPL_PR_RECORD=1` (the conductor exports it),
  `_hpl_state_get` asks the record first. With `HPL_LAZY_ONLY="<n> …"`,
  `_hpl_lazy_row` reads the merge state of those rows only; every other row
  is `UNKNOWN` and is not counted as degraded. Unset, nothing changes, so
  batch-resolve and every other caller send the same requests as before.
- The conductor's keyed tick passes its woken PR numbers as `HPL_LAZY_ONLY`
  (`mc_lazy_scoped`, bin/lib/mc/tick-scope.sh).
- The QUEUED pass takes state, branch and head from the open list for a row
  still open at its QUEUED head (`mc_queued_open_heads`,
  `mc_queued_list_view`, bin/lib/mc/queue.sh). `mc_queue_state` still reads
  the PR live once, so a list older than a merge settles the row MERGED.
- `bg_reviewer_can_write` (bin/lib/block-gate.sh) keeps the permission word in
  `BG_PERM_MEMO_DIR` for one tick (`$MC_TICK_DIR/perm-<tick>`; the parent's
  EXIT trap removes it, `mc_tick_gc` prunes one a killed tick left). A failed
  read is never stored.
- `bin/lib/gh-repo-token.sh` keeps the verdict word of the `gh api
  repos/<slug>` visibility probe in `$_GHRT_PROBE_MEMO_DIR/<slug>.<app|pat>`
  for `_GHRT_PROBE_MEMO_TTL_S`. The conductor sets the dir to
  `state/gh-repo-probe` and the TTL from `MC_REPO_PROBE_TTL_S` (default 300,
  0 = off). `none` is never stored; the App token is still minted every tick.
- The tick log carries `<slug> PR-RECORD served=<n> miss=<n>` next to
  `PR-SNAPSHOT`.

## Proof

`tests/mc-pulls-quota.bh-8457-test.sh`: a whole full tick over 50 open PRs
with fresh records makes 0 `pulls/{n}` reads (was 48), and a keyed tick makes
1 (was 48). The live proof (one hour with the installation quota above 0, and
merge-conductor.sh `pulls/{n}` under 300 an hour in the gh-calls ledger) is
owed after deploy.
