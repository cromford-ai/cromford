# Groom closes pipeline-health rows whose condition cleared (BH-4056)

Doc: ALERTS-GROOMING-SPEC, ALERTS-STATE-MACHINE

## What changed

- `bin/pipeline-health.sh` writes `state/health-active.stamp` right after its
  retraction epilogue moves the pass's fired keys into
  `state/health-active.txt` (block `# >>> active stamp (BH-4056)`). One JSON
  line: `{"at":<epoch>,"n":<keys in the file>,"retract_ns":"<RETRACT_NS>"}`.
  It is written only when that `mv` landed.
- New `bin/ph_active.py`: `ph_id(key)` (the same fold as `alert()`'s `aid=`
  line), `ns_of(ph_id)`, and `load_active(harness)`, which returns the active
  ph ids and retractable namespaces only for a fresh, complete pass. Otherwise
  it returns a hold reason: `no stamp`, `stamp unparseable`,
  `stamp in the future`, `stale: pass <m>m ago > <N>m`, `active file missing`,
  `active file has <k> keys, stamp says <n>`, `empty retract_ns`,
  `bad window <v>`.
- `bin/alerts-supersede.py` (run by `bin/alerts-groom.sh` on the hub) has a
  ph-absent pass. An open `alert:ph-<key>` row whose namespace is in the
  stamp's `retract_ns` and whose id is not in the active set resolves with
  `condition absent from health-active.txt (complete pass <m>m ago, BH-4056)`.
  A hold prints `ph-absent pass held: <reason>` and that pass resolves nothing.
  When the module loads, each run prints `ph-absent resolve=<k>`. Both lines go to
  `logs/alerts-groom.log`.
- New one-shot `bin/alerts-hygiene-ph-backlog.sh [--dry-run | --apply]` for
  the pipeline-health rows still open under the pre-#3997 keys. Those are
  `health:<key>` and `alert:auto-*`/`auto-*` with a `[pipeline-health]` line.
  The dry run is the default and writes nothing. `--apply` makes one
  `POST /api/alerts/resolve` of the close set, prints `closed … (superseded by
  stable-key alerts (#3997))` per row only after a 2xx, and appends one line
  to `logs/alerts-groom.log`. rc 0 ok, 1 console failure, 2 usage or no
  console env, 3 held.
- Knob `PH_ACTIVE_FRESH_MIN` on the `alerts-groom` lane (settings row
  `lane.alerts-groom.ph_active_fresh_min`), code fallback 30 minutes. A value
  that is not a whole number >= 1 holds; it is never clamped.

## Why

pipeline-health already retracts a cleared condition in its own log, but the
console row it opened stayed open until the 72h TTL. The active file cannot be
judged by mtime, because the pass `touch`es it at the start. A pass that dies
midway leaves a fresh mtime over the previous pass's keys, and a deleted file
comes back fresh and empty, which would read as "everything cleared". The
stamp is what says a pass completed.

## Limits

- Only namespaces in pipeline-health's `RETRACT_NS`. Throttled checks
  (costcap and the like) are absent on the ticks they skip, so their rows keep
  the 72h TTL.
- Console rows only. The jobs-worker `alerts` table row is not resolved by
  this pass, the same as every other supersede pass.
- The console resolve body is `{ids}`, so the #3997 reason is in the script's
  output and the groom log, not on the row.
- A legacy `auto-*` row is held only while an open `alert:ph-X` row of the same
  `shape()` is in the active set. A live condition whose stable row has not
  been emitted yet (dedupe TTL) is closed and reopens under `alert:ph-*` on its
  next emit. Read the dry run before `--apply`.

## Commands

    bin/alerts-hygiene-ph-backlog.sh            # dry run on the hub
    bin/alerts-hygiene-ph-backlog.sh --apply    # after reading it
    grep 'condition absent\|ph-absent pass held' /root/harness/logs/alerts-groom.log
