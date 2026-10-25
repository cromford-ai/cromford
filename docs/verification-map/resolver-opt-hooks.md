# Resolver optional hooks (`bin/lib/br/opt/`)

**What it is:** the seam the optional modules of `bin/blocked-resolver.sh` plug
into — `mechanical` (#1470: carry an unchanged verdict, rebase a derived-only
conflict) and `family` (#1471: family-batched iron-law adjudication). It ships
as a contract only: with `bin/lib/br/opt/` holding a README and no module, the
lane does exactly what it did before, the four new counters read 0 or the lane's
own model calls, and nothing in the seam can change a decision.
`bin/lib/br/opt/README.md` is the normative table; this page is how an operator
verifies the seam on a box.

**How a user reaches it:** there is **no UI route**. Two observable surfaces:

- `tail -1 /root/harness/logs/blocked-resolver.log` on the hub — the `tick:`
  line carries four extra fields between `retired=` and `projects=`:
  `carried= mechanical= families= llm_rungs=`.
- The lanes registry (`catalog/lanes.d/blocked-resolver.json`, composed into the
  console's settings surface) lists the two knobs this seam declares,
  `BR_OPT_OFF` and `BR_FAMILY_TTL_SECS`, with their defaults and what 0 means.

**The primary lane** is `cron/hub.cron`, `4,14,24,34,44,54 * * * *`
(`bin/blocked-resolver.sh`). The optional loop runs once per tick, immediately
after the required `BR_MODULES` loop.

**Key behaviours to drive:**

- **Absent is silent.** No `bin/lib/br/opt/` directory is the normal box: no log
  line, no alert, and an idle tick's log is byte-identical to one with a module
  loaded.
- **Fail-open.** An unparseable `bin/lib/br/opt/<name>.sh` logs one
  `does not parse` line; one that fails while being sourced logs one
  `failed on source` line. Both leave the tick rc 0 and the dispatch unchanged.
  Contrast the REQUIRED loop, which writes `RESOLVER MODULE MISSING` to
  `logs/ALERTS.log` and exits 1.
- **Kill switch.** `BR_OPT_OFF=mechanical` leaves the file on disk unsourced;
  it is a comma list with no spaces, and a name nothing ships is ignored.
- **rc 0 = handled.** `br_opt_carry_rung` / `br_opt_conflict_rung` answering 0
  makes `br_one` return 0: the row spends its `PER_TICK` slot, dispatches
  nothing and calls no model. `br_opt_family_pre` answering 0 makes
  `br_adjudicate` return without a model call, a posted ruling or a spent
  adjudication counter.
- **Ordering.** `br_opt_family_record` runs at the END of the `ACCEPT` and
  `REJECT` arms, so the per-PR `ironlaw-head-accept` row (or its `.ila_pending`)
  is already written when it is called. A run that produced no verdict reaches neither arm, so it
  is never called and nothing is stored.
- **Counters.** `llm_rungs=` counts every dispatch that REACHED a model call
  (adjudication, fix round, re-review); the other three are written by the
  modules through `br_count`, into a per-tick scratch file, because each rung
  runs in its own subshell and an assignment there is lost.

**Selectors:** not applicable — no rendered screen. The observable artifacts are
the `tick:` line in `logs/blocked-resolver.log`, the recorded hook argv, and the
`-> <action>` dispatch lines.

**Preconditions:** the hub box (the lane is hub-scoped and gated on the hub
lease).

**Tests that pin it:** `tests/blocked-resolver-opt-hooks.bh-1468-test.sh` drives
the whole script against a scratch `$HARNESS` with canary modules at each hook;
`tests/blocked-resolver.bh-1122-test.sh`, `tests/blocked-resolver.bh-980-test.sh`
and `tests/blocked-resolver-prepass.bh-1457-test.sh` own the `tick:` line's
literal shape.
