# Sibling parts get a file list: project roots, list source, cause per wait (BH-6715)

Doc: OPERATING

## The gap

`bin/planned-files.sh` kept a path only under the default prefixes (`src`,
`prisma`, `scripts`, `e2e`, `tests`, `app`, `lib`, ...). A cromford plan
that names `bin/lib/x.sh` and `catalog/lanes.d/y.json` wrote an empty
`planned-files.txt`. `bin/sibling-serial.sh` read that part as "no pre-plan
list", and a part with no list waits for every sibling in flight. Nothing said
why a part had no list: an unreachable pre-plan index read the same as no list.

## What changed

- New per-project rows `catalog/claim-roots.d/<project>.txt`, one top-level dir
  per line. `bin/lib/claim-roots.sh` reads them. `claim_roots_project` resolves
  a project from a name or a build/plan dir name (exact row, else the longest
  row `p` with the name starting `<p>-`, after a leading `pool-`).
  `claim_roots_list` prints the roots and drops a line that is not one plain
  name.
- The cromford row is `bin catalog worker console-ui cron fly config tests`.
  No other project has a row, so their lists do not change. To roll back,
  delete the row file.
- `bin/planned-files.sh <build-dir> [project]` and `bin/planned-files-cheap.sh`
  claim the row's roots too. A file must start with `<root>/`. A dir scope under
  a root must start a token and have 3 segments, so `catalog/lanes.d/` and
  `/root/harness/bin/lib/rb/` are not claimed. The skip rules (sibling claims,
  `VALIDATE:` lines, `## Verify (run, not edited)`) still hold.
- `preplan_planned_files` (`bin/lib/preplan-lib.sh`) returns rc 2 when it could
  not ask the index (no `jq`, no jobs client, the index read failed). rc 1 stays
  "asked, no list". Callers that test only rc 0 do not change.
- `files_of` in `bin/sibling-serial.sh` reads, in order: `plans/<p>-<K>/`, the
  pre-plan index, then each build record newest first: `touch-files.txt` when
  `touch-source` is `declared` (`build-touch`), else `planned-files.txt`
  (`build-planned`). With no list it names the cause: `empty-list` (a plan.md
  exists), `index-unreachable` (rc 2), else `no-plan`.
- `sibling-serial.sh check` writes one stderr note line per tick:
  `list sources: <K>=<src> <S>=<src> ...` (the pool log).
- `sibling-serial.sh replay` prints, after `REPLAY_TOTAL`, four
  `REPLAY_CAUSE <cause> waits=<n> pct=<p>` lines (no-plan, index-unreachable,
  empty-list, unknown; they sum to `nolist_waits`). A part with a list that
  waits on a listless sibling counts the sibling's cause. `--project` mode also
  prints `REPLAY_SOURCES plans-dir=<n> preplan-index=<n> build-touch=<n>
  build-planned=<n> none=<n>`. The `REPLAY` and `REPLAY_TOTAL` lines do not
  change. The wait rule (`decide`) does not change.

## Measure after merge

Run `bin/sibling-serial.sh replay --project cromford --last 30` and the
same for project-5 on the hub. Read `REPLAY_TOTAL fallback_pct`, the
`REPLAY_CAUSE` lines and `REPLAY_SOURCES`. The target is a fallback of 20% or
less. If project-5 paths fall outside its default prefixes, add
`catalog/claim-roots.d/project-5.txt`.
