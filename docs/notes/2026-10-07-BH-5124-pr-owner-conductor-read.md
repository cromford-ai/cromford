# pr-owner-sweep stops trusting a stale local conductor file (BH-5124)

Doc: PR-OWNERSHIP

## What changed

- New `bin/lib/pr-owner/mc-read.sh`, one function, `po_mc_read <slug> <outfile>`.
  `bin/pr-owner-sweep.sh` now gets the merge conductor's rows from it instead of
  grepping `state/merge-conductor/pr-state.tsv` on whatever box it runs on. In
  order:
  1. the D1 `pr_state` view, when the conductor's own gate (`pr_rows_on`, the
     `pr-state-rows` flag) is up. It reads at most 5 pages of 1000, the same
     loop as `_swf_cond_read` in `bin/lib/stuck-work/facts-pr.sh`. A failed
     page, a malformed page or the 5-page bound falls through to (2);
  2. the file, only when `is_hub_box "$(local_box_name)"` (`bin/lib/hub-box.sh`)
     and only while its mtime is within the new knob;
  3. otherwise it refuses and gives the reason.
- New knob: settings row `pr_owner.mc_max_age_s`, env fallback
  `PR_OWNER_MC_MAX_AGE_S`, default 900 s (two conductor ticks), read once per run
  through `ph_knob`. `0` = never trust the file. There is no seed row: the row
  is optional, and `tests/pr-health-lib.bh-3929-test.sh` pins the seed set.
- New class `UNREAD`. A harness PR with no ledger owner, no park and no grace
  is `UNREAD` instead of `ORPHAN` when the conductor read refused. Nothing acts
  on it (no close, label, comment or hand-back). `dirty_since` is still
  remembered. A stale file's rows are not used as OWNED evidence either. The
  sweep writes one line per repo per run, `<repo>: conductor rows unusable —
  <why>; <n> PR(s) with no ledger owner counted conductor-unread, no orphan
  action this run`, and sends no alert.
- The summary line gains `conductor-unread=<n> conductor=<rows|file:<age>s|unread>`
  right after `orphans=`. Every existing token is still there.
- `handback()` return codes: 0 handed back (or dry run), 1 only a `cm_clear`
  miss (`handback-failed`), 3 pool-routed (held `#N:pool-routed`), 4 no fleet
  project or no key (held `#N:no-project`). Codes 3 and 4 write nothing, so they
  no longer spend `PR_OWNER_MAX_ACTIONS`.
- Hooks get `PO_CLASS=UNREAD`, `PO_OWNED=0` for those PRs. All four hooks are
  still stubs.

## Why

On box-small (2026-10-07) the sweep read a `pr-state.tsv` last written
at 01:38Z. Only the hub's conductor writes that file, so a missing row looked
exactly like "the conductor does not own this", and every harness PR with no
ledger row was counted ORPHAN. Pool-routed refusals were logged
`handback-failed`, which reads like a jobs-DB outage.

Probes at about 05:30Z on 10-07, from planning: `flag_active pr-state-rows` was
down, and `pr_state_page 5` with no repo filter returned rc 2 (the view has no
rows fleet-wide). So today the file path is the one that actually runs, and
**after this lands, orphan actions only happen on the conductor's box, or once
the `pr-state-rows` flag is up.**

## Follow-ups (not this ticket)

- Per-project conductor freshness (`tick-<P>.json` `finished_at`, as
  `bin/lib/sweep-reads.sh` `_sweep_project_fresh` does). On the hub any
  project's tick rewrites the whole file, so a fresh mtime does not prove a
  given project's conductor is alive.
- Turning `pr-state-rows` up and backfilling the `pr_state` view is an
  operator decision.
