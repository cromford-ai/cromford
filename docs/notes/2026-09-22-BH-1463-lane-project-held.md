# 2026-09-22 — BH-1463: `lane_project_held`, the per-project hold contract

Doc: harness-control-plane

A hub-scoped lane can only be stopped FLEET-WIDE today. `bin/harness-ctl.sh`
refuses a project argument on one by design, and every switch the resolver reads
(`all-off`, `lane-off-<id>`) is global. So pausing a fix round or a re-review on
ONE project meant stopping merge-conductor, merge-sweep, blocked-resolver,
review-autopilot and main-red-pr-pair for all eleven.

This is the contract slice of #1419 and nothing else.

## What changed

**`bin/lib/lane-gate.sh`** gained one function, between `lane_paused` and
`lane_gate_or_exit`, inside `# >>> project hold` / `# <<< project hold`:

```
lane_project_held <id> <project>    # rc 0 = this project is held, rc 1 = run it
LANE_HELD_FLAG                      # the switch name it found, for the caller's own log
```

It reads exactly one name, `lane-off-<id>-<project>`, through the existing
`_lg_name` and `_lg_db_paused` — so reconcile-then-read, the 60s cache, the
exact-filename comparison and fail-open all come for free, with no second copy
of any of them. It does NOT re-check `all-off` or `lane-off-<id>`: the lane
already exited on those at its own `lane_gate_or_exit`, and asking again would
double-count the sighting rail.

**`catalog/lanes.d/`** — `"per_project_hold": true` on the five hub lanes that
will honour it: `blocked-resolver`, `review-autopilot`, `merge-conductor`,
`merge-sweep`, `main-red-pr-pair`. Absent means false, so every other lane on
every box is untouched, and no build lane carries it — project-5 builds keep
running while a project-5 fix round is held. `catalog/lanes.d/` composes
arbitrary keys through `bin/lanes-build.sh`'s jq slurp, so this needed no schema
change and `catalog/lanes.json` stays generated and uncommitted.

No schema change and no migration anywhere: `pause_flags.name` is already
free-form and already accepts `lane-off-<id>-<project>`
(`worker/jobs/src/routes/flags.js:47`). The hold IS the database row; the
on-box `flags/<name>` file is its write-through cache, exactly as for every
other switch here.

## It is DARK

Nothing calls `lane_project_held` after this merges. Every box behaves
byte-identically; `lane_paused` and `lane_gate_or_exit` are byte-identical in
the diff. The callers land in the siblings: #1465 (the five lane scripts),
#1464 (the CLI), #1466 (worker + console). Until then nobody can set a hold
that does anything, which is the point of landing the contract first.

## Three decisions worth the words

**It posts nothing.** No `_lg_liveness` row, no `state/lane-gate/<id>.paused`
stamp, no `_lg_flag_seen` sighting. The lane RAN this tick — it skipped one
project's records and merged everyone else's — and
`worker/jobs/src/routes/lanes.js` filters `lane_ticks` by `scope !== "project"`
for a hub lane, so a `paused` tick posted from here would render the lane as
paused on the HUB tab while it was working. The caller names the row in its own
log line through `LANE_HELD_FLAG`.

**It fails open, like everything else in this file.** An unreachable worker with
nothing cached answers "run it". A control plane that stops lanes when the
database blinks is worse than no control plane — that is BH-1132's rule and this
inherits it rather than re-deciding it. A hand-touched `flags/<name>` file with
no row behind it still holds, for the same reason it holds for `lane_paused`:
`flag_sync` answers rc 2 and leaves it alone.

**It memoises per (id, project), per process.** `bin/merge-sweep.sh` walks
hundreds of records a tick and would otherwise re-read the cache file and re-run
`jq` per record. The store is a plain space-delimited string in the shape
`_LG_REG_CACHE` already uses — not an associative array, so the library keeps
working under every `set` combination its callers use (`bin/preplan-tick.sh`
runs `set -u` without pipefail). The key is the sanitised name, matched with its
delimiters, so `lane-off-x-project-3=1` can never answer for `lane-off-x-project-3`.
The cost: a hold flipped mid-tick is seen on the NEXT tick. That is already true
of the 60s cache every other reader here goes through.

`LANE_GATE_DISABLE=1` is checked BEFORE the memo, so the escape hatch still wins
after an answer has been cached in-process.

## Verified

`tests/lane-project-held.bh-1463-test.sh` — 29 assertions over the eight cases
the ticket names: the row decides and the lane-wide switch is never read here;
empty id, empty project, `-` and an illegal project name all run, having read
nothing; `LANE_GATE_DISABLE`; fail-open; prefix collision both directions; the
memo counted in stub worker calls; `lane_paused`/`lane_gate_or_exit` unchanged
with a project row set; and the registry ratchet (exactly five lanes, no build
lane). Nine deliberate mutations of the function and the registry were each
confirmed red on the section that owns them before the tree was restored.
