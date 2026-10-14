# pipeline-health runs one process per project (BH-5941)

Doc: OPERATING, ALERTS-STATE-MACHINE

## Why

Two faults on the hub's 10-minute pipeline-health lane:

1. The cron run did `flock -n 9 || true` on `locks/pipeline-health.lock`. It
   ran even when the lock was held, so 2-3 runs overlapped.
2. Checks 4 (`no board close-out`) and 5 (`empty url`) visited every aged-out
   build dir on every tick. Each visit cost a `stat`, a `head`, a `grep`, a
   fork of `bin/queued-fly-relayed.sh` and a `closeout_record_aged` call. With
   the BH-1033 table flag on, that call made one `closeout_aged_put` worker
   call that answered rc 3 ("already recorded"). project-1 paid this for
   386 dirs on every tick.

One project with many dirs also made every other project wait. This change
moves the lane onto the per-project runner from BH-5913
(`docs/notes/2026-10-10-BH-5913-project-lanes.md`).

## Run modes

| invocation | mode | sections | lock |
|---|---|---|---|
| `--dispatch` (cron) | `fleet`, after the dispatch | fleet sections | `locks/pipeline-health.lock`, never a skip (a sections run may hold it); exits only when another full run holds `locks/pipeline-health-full.lock` (log: `full run skipped, another full run is in flight`). The dispatch runs before the locks. |
| `--project <p>` | `project` | per-project sections, `PROJECTS=<p>` | `locks/pipeline-health-<p>.lock` on fd 9 (the runner's, or taken by a hand run); exits 0 when held |
| no arguments (operator) | `all` | every section | as `--dispatch`: exits only when another full run holds `locks/pipeline-health-full.lock` |
| `--sections <csv>` | `sections` | as BH-4055 | as BH-4055 |

`--dispatch`, `--project` and `--sections` are exclusive (exit 2). An unknown
or unsafe `--project` name writes one log line and exits 2.

The dispatch uses `pl_dispatch pipeline-health $PH_DISPATCH_SPREAD_SECS
bin/pipeline-health.sh --project`. The knob is a lane setting, default 540. A
non-number logs one line and uses 540. When `bin/lib/project-lanes.sh` is not
loaded (a box in mid-sync), the dispatcher logs `project-lanes.sh not loaded`
and runs mode `all`: the lane runs as it did before.

Each project run writes `pipeline-health project <p>: run done in <s>s` to
`logs/pipeline-health.log`. The runner's own lines (`a run of <p> is still
live`) go to `logs/pipeline-health-cron.log`, with the cron line's output.

## Section split

Per-project (each alert key is `<ns>:<p>[:…]`): stuck queue, pool refusal halt,
no board close-out, empty url, remote-result json, wasted-tick loop, stalepr,
starved, stranded queue, stale dequeue, stale parent. The namespaces are
`PH_PROJ_NS` in the script.

Fleet: hung machine liveness, sweepstall, leadunqueued, perma-red, flake rate,
cost budget, spend alerts, cost rollup liveness, hub sync stall, hub repo
shallow, tmp headroom, fleet checkout freshness, console pages drift, deploy
workers run, build over cap, backup freshness, restore drill, pause expiry,
factory stop, preplan hit rate, wake classes armed.

## Key ownership

`state/health-alerted.json` and `state/health-active.txt` stay shared. Project
runs and the fleet run now write them at the same time, so:

- `alert()` and `alert_digest()` read, compare and write the dedupe map under
  `state/health-alerted.json.lock` (5 s wait, then go on), with a per-process
  tmp name.
- The retraction epilogue holds `state/health-active.txt.lock` for its read and
  write. Each run replaces only the keys it owns. The namespace is the text
  before the first `:` and the owner is the next field.
  - A project run owns the `PH_PROJ_NS` keys of its own project.
  - The fleet run owns every other key. It also owns the `PH_PROJ_NS` keys of a
    project that is no longer in fleet.conf, so those retract once.
  - A key that no run owns this tick (a held project) is carried, not
    retracted.
  - Mode `all` (an operator's run with no arguments) owns every key, as
    before.
  - Mode `sections` owns only the namespaces in `PH_SEL` (BH-6616). It carries
    every other key from the ACTIVE the epilogue reads under the lock. Before
    BH-6616 it copied those keys into `$FIRED` outside the lock, so a project
    run that wrote ACTIVE in the window lost its new key, and a key it
    retracted came back.
  - A skipped check writes a carry marker to `$FIRED`, not a copy of ACTIVE
    lines: `+=<key>` carries that exact key, `+^<prefix>` carries every key
    that starts with the prefix. The epilogue resolves each marker against the
    ACTIVE it reads under the lock, so a key another run retracted in the
    window stays retracted. A marker never reaches ACTIVE. The stalepr and
    leadunqueued skips use the markers (BH-6616); the other skip carries still
    copy lines.
- `state/health-active.stamp` is written inside the same lock, so its `n`
  matches the file.

The emit cap (`ALERT_LINE_TICK_MAX`, BH-2364) is per process. It is now one cap
per project run plus one for the fleet run. Lines over a cap still go to
`logs/ALERTS.log`.

## Close-out skip set

`bin/lib/closeout-terminal.sh` has a new block, `closeout skip set (BH-5941)`.
The file is `state/pipeline-health/<p>/closeout-aged.tsv` (the runner's
`PL_STATE_DIR`), one line per dir: `dir<TAB>RESULT mtime<TAB>aged|emptyurl`.

- Checks 4 and 5 read all RESULT mtimes for a project with one `stat`.
- A dir in the set is counted as aged out and not read again when its RESULT
  mtime equals the recorded one and that mtime is still past the
  `CLOSEOUT_AGE_OUT_H` ceiling. A rewritten RESULT or a raised ceiling is
  judged again.
- A line is added only after `closeout_record_aged` returned 0. A failed record
  is retried on the next tick, as before.
- A dir that is gone or rewritten is pruned from the file.
- A lost or junk file costs one tick of re-reads. `closeout_record_aged` still
  dedupes the audit tsv and the table.

## Proof

- `tests/pipeline-health-dispatch.bh-5941-test.sh`: the dispatch, the locks,
  key ownership, the fail-open path.
- `tests/pipeline-health-closeout-skip.bh-5941-test.sh`: the skip set.
- `tests/pipeline-health-closeout-ageout-test.sh`: its `reset()` now clears
  `state/pipeline-health` with the tsv. A dir that was already decided is not
  recorded again, so the fixture must clear both.
