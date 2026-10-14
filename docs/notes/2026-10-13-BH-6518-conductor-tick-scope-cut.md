# The conductor's keyed-tick parse lives in bin/lib/mc/tick-scope.sh (BH-6518)

Doc: MERGE-CONDUCTOR

BH-6518 slice C0 starts "the conductor becomes a driver". It moved one inline concern out of `bin/merge-conductor.sh`: the keyed-tick parse (BH-1387, BH-1841), which reads `MC_ONLY_PR` and sets `MC_ONLY_KEYS`.
The parse is now `mc_keyed_tick_parse` in `bin/lib/mc/tick-scope.sh`. Its body is the old driver lines, byte for byte. It uses no `local`, so `MC_ONLY_KEYS` and its helper variables stay global, and the keyed arm still replaces `mc_tick_metrics` with a no-op for the rest of the process.
The driver calls it at the same place as before: after `pause_refresh`, before the full-tick window. The input format, the dedupe and both log lines (`keyed tick: N key(s) — …`, `MC_ONLY_PR ignored: …`) did not change.

The seam rule for the later slices:

1. The file is driver-only and has no `# module:` header. `mm_load` never loads it, and the scripts that source `bin/lib/merge-conductor-lib.sh` never see its functions. `bin/lib/mc/MODULES` and `tests/mc/expected-map.d/` do not list it. `bin/lib/mc/external-enqueue.sh` has the same shape.
2. The driver sources it by a literal path (`. "$H/bin/lib/mc/tick-scope.sh"`), so `scratch_closure_list` follows it and the fixtures that copy `bin/lib/mc/*.sh` get it with no edit.
3. If the source fails or the function is not defined, the tick refuses. It writes one `CONDUCTOR MODULE MISSING` line to `logs/ALERTS.log` (`--id conductor-module-missing`), one `refusing the tick` line to `logs/merge-conductor.log`, and exits 1 before `mc_init` and before any GitHub call.

`tests/mc-tick-scope.bh-6518-test.sh` pins the parse (eight cases), the closure, the real driver's run path and both refusal paths, and that the file is not a module.
`tests/mc/driver-complete-test.sh` is unchanged: the driver still defines only `flag_on`, `use_token`, `reset_token`, `pr_worker` and `tick_project`.

Later slices, one concern each, same seam: C1 the full-tick window, C2 the flags/MODE block, C3 the budget and knob prelude, C4 the per-project loop, then the `tick_project` and `pr_worker` stages, each with its own return-code protocol. The merge-sweep remainder of BH-5242 is not carried by this ticket.
