# Sweeper and metrics kill switches read through lane_switch (BH-2444)

Doc: CONFIG, VERIFICATION-MAP

Slice 4 of BH-2408. Six kill switches in five files now read the `switch.<name>` settings row
(and its `switch.<name>.<box>` form) before the file:

| switch | reader | mode |
|---|---|---|
| main-red-pr-pair-off | bin/main-red-pr-pair.sh | file |
| orc-account-routing-off | bin/lib/orc-account.sh (`orc_pick_account`) | file |
| orphan-reconcile-off | bin/orphan-reconcile.sh | file |
| pr-owner-sweep-off | bin/orphan-reconcile.sh (the pr-owner-sweep hook) | file |
| outcome-metrics-disabled | bin/outcome-metrics.sh | flag |
| overlap-guard-off | bin/overlap-guard.sh | file |

**Behaviour is unchanged on every box until a `switch.*` row exists.** Merging writes no row, and
`bin/switch-migrate.sh` was not run. With no row, `file` mode is `[ -f flags/<name> ]` and nothing
else: no `/api/flags` request, no touch or rm of the file. That is what five of these sites did
before. outcome-metrics already split on `flag_active` (the pause_flags reconcile when the jobs
client is loaded, else the file), and the default `flag` mode does the same split. The only new I/O
is the settings GET `lane_knob` already makes, through the same 60 s cache.

Two details a reader might trip on:
- `flags/overlap-guard-off-<project>` is still a bare file read. The name is dynamic, so it has no
  catalog entry and no row.
- orc-account and overlap-guard tested `[ -e ]`; `file` mode tests `[ -f ]`. They differ only when a
  directory sits at `flags/<name>`.

When `bin/lib/lane-switch.sh` has not synced to a box yet, each site defines a fallback
`lane_switch` that reads the file the way it did before, so a partly synced box behaves as it did.
The six switches are registered in `catalog/switches.d/`. `pr-owner-sweep-off.json` lists both
`bin/orphan-reconcile.sh` and `bin/pr-owner-sweep.sh`, whose own read is left for BH-2408's C3.
`tests/switch-ratchet.d/BH-2444.drop` records the 5 bare reads removed; the `[ ! -f` form was never
counted.
