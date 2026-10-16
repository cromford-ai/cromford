# pipeline-health project runs off the hub: the fleet-wide writes (BH-6892, BH-6881.10)

Doc: HARNESS-COORDINATION, ALERTS-STATE-MACHINE

## What changed

Part 10 of #6881. `catalog/lane-run-inputs.d/pipeline-health.rw` listed seven
fleet-wide writes as NOT CARRIED. Each one blocked a flip of the
`pipeline-health` project runs to Fly. This change removes every one of them.
Nothing runs on a machine yet: `lane_placement.pipeline-health` is seeded
`hub`.

Every change is gated on `LANE_RUN_ID` set (a lane-run machine). With
`LANE_RUN_ID` unset or empty the run does what it did before, with one
exception: the closeout lock. It is now `state/closeout-aged-out.tsv.lock` on
the hub too, because the hub's `@rows` apply is the other writer of that file.

## The choice per file

| File | Choice | Why |
|---|---|---|
| `state/health-active.txt` | `@rows` with ERE `^(<PH_PROJ_NS>):$p(:\|$)` | One key per line. A project run already owns exactly these keys (the epilogue's `owned()`, BH-5941) and carries the rest. |
| `state/health-active.stamp` | Not written on a machine | It describes the whole file (`n` = all keys). The hub's fleet run keeps writing it. |
| `state/health-alerted.json` | The machine uses `state/pipeline-health/$p/alerted.json` (already in the `.rw` glob), seeded once from the snapshot's fleet JSON | A JSON map cannot be `@rows`. A per-project file needs no merge. |
| `state/closeout-aged-out.tsv` | `@rows` with ERE `^$p[[:space:]]`; every writer takes `state/closeout-aged-out.tsv.lock` | Rows are already `proj TAB dir`. The apply lock is `<path>.lock`, so the appenders take the same lock. |
| `logs/ALERTS.log` appends | `bin/alert-line.sh` → `alr_post` (#6889) on every line, past `ALERT_LINE_TICK_MAX` too | The only path that leaves the machine. |
| `state/alert-line-sent/*`, `state/alerts/*`, `logs/alerts-state.log` | Not written on a machine | They come from `beat.sh` and alert-state. A machine run makes no `beat.sh` call. The hub replay of each line runs `bin/alert-line.sh`, which writes them on the hub. |
| `state/alert-quarantine.jsonl`, `bin/remediations/health-*` | Not written, not run | `bin/beat.sh` quarantines and runs `rem_try` only for a `kind:"fleet_alert"` beat. The machine drops the `fleet_alert` beat of `alert()`, and the hub replay beats `kind:"alert"`. So a machine-raised alert gets no quarantine row and no remediation handler. |
| `/root/repos/$p` refs (stale-parent) | GitHub REST: the PR commit list, the base commit list, commit diffs, `git patch-id --stable` on the REST diff, cached by sha | No checkout on a machine. Both sides of a compare come from the same GitHub diff, so the patch-ids are comparable. |

## Details

- `bin/pipeline-health.sh`, `# >>> machine dedup`: with `LANE_RUN_ID` set and
  `--project <p>`, `DEDUP` is `state/pipeline-health/<p>/alerted.json` and its
  lock is `locks/ph-alerted-<p>.lock` (`locks/*` never rides back). When the
  file is absent or empty, it is seeded from `state/health-alerted.json` with
  the keys whose second `:` field is `<p>` and the `leadunqueued:<slug>#` keys.
  Stamps older than 8 days are dropped at the seed and on each write. The
  largest TTL in the file is 604800 s, so a dropped stamp can never suppress a
  page.
- `alert_emit`: with `LANE_RUN_ID` set, every line goes through
  `bin/alert-line.sh --project <p>`. There is no cap-overflow append.
- `alert()`: with `LANE_RUN_ID` set, no `beat.sh` fleet_alert call. The
  replayed line carries the same `ph-<key>` id to the same console row.
- The epilogue: with `LANE_RUN_ID` set, a retraction is ONE
  `bin/alert-line.sh --severity resolved --id ph-<key>` line, and the stamp is
  not written.
- `bin/alert-line.sh --severity resolved`: the beat payload carries
  `resolved:true` and no `severity`. Every other severity is unchanged.
  `POST /api/alert-lines` accepts `severity: "resolved"`
  (`worker/jobs/src/routes/alert-lines.js`). No schema change: the column is
  free text.
- The stale-parent block: with `LANE_RUN_ID` set it never computes the clone
  path and never runs `git`. Per PR it calls `spr_stale_commits`
  (`bin/lib/stale-parent-rest.sh`). The cache is
  `state/pipeline-health/<p>/patch-ids.tsv` (`key TAB pid TAB last-used`):
  rows unused for 14 days go, then the newest 1800 stay (at most about
  241 KB, under the 256 KB `LRI_FILE_MAX` of a write-back member). At most
  `STALE_PARENT_REST_DIFF_MAX` (default 120, `catalog/lanes.d/_lib.stale-parent.json`)
  uncached diffs are read per project per tick. Log lines in
  `logs/pipeline-health.log`:
  - `stale-parent rest <p>: judged <j> PR(s), <f> diff(s) fetched, <c> cached`
  - `stale-parent rest <p>: diff budget spent, <n> PR(s) left for next tick`
  - `stale-parent rest <p>: the <base> commit list is past 3 pages, project carried`
  A PR that is not judged keeps its standing key (a skip is never a clear).
- `bin/disk-clean.sh` step 4 takes `locks/closeout-aged-out.lock`, then
  `state/closeout-aged-out.tsv.lock`. A held lock still skips the prune
  (`tsv prune skipped: lock held`).

## What still runs on the hub

The fleet run (`--dispatch`, fleet sections), the active stamp, the
`@rows` and file applies of every write-back, and the alert-line replay
(`bin/lane-snapshot-publish.sh`).

## Known costs

- A flip back to `hub` starts from the hub's older fleet JSON, so each active
  condition of that project can page once.
- The daily `disk-clean` prune can change a project's closeout rows between a
  fetch and an apply. That write-back then counts one conflict on that file;
  the next tick's row comes back, because the closeout skip file records a dir
  only after `closeout_record_aged` returns 0.
- If `alr_post` fails on a machine, `bin/alert-line.sh` falls back to a local
  append that nobody reads (the #6889 contract). The run still exits 0.
  `alert()` writes its dedup stamp before the POST, so that condition does not
  page again until its TTL ends (21600 s for staleparent).
- Machine-raised alerts skip the remediation tier: `bin/remediations/health-stalepr.sh`
  and `health-uncommented.sh` run only for a `fleet_alert` beat, and the
  machine sends none. The page itself still reaches the hub.

## Not covered (follow-up)

The BH-6719 inventory did not list one more machine-side write, and this
change does not fix it: `gh_repo_invisible_alert` (`bin/lib/gh-repo-token.sh`),
which the stalepr check calls when no token can see a repo. On a machine its
alert line is posted, but it also makes a `beat.sh` fleet_alert call and
touches a once-a-day `flags/alerted-repo-invisible-*` file that no write-back
carries, so a machine would repeat that alert every tick. It fires only when a
repo is invisible to every token. It belongs in a follow-up for the
pipeline-health flip, before `lane_placement.pipeline-health` is set to `fly`.

## The flip procedure

1. Run one proof tick of one project on a machine.
2. On the hub, read the `bin/lane-snapshot-publish.sh` summary line for that
   tick. It must show the write-back applied and `0 conflicts`.
3. Read the `alert lines: <r> replayed` line of the same tick. It must show at
   least one replayed line from that run.
4. If both hold, set the settings row `lane_placement.pipeline-health` to `fly`.

## Metric

The ticket's metric (the lane's hub share, 9% to under 1%) needs the flip, so
this change does not move it. The source is the `pipeline-health=<share %>`
field of `state/hub-load/<YYYY-MM-DD>.tsv` (bin/hub-load-sample.sh), 24 h before
and 24 h after the flip. This build box has no `state/hub-load/` files, so this
note gives no numbers.

## Tests

- `tests/pipeline-health-offhub.bh-6892-test.sh`: the manifests, both `@rows`
  EREs, a real machine run from a published snapshot, two write-backs with 0
  conflicts, the alert-line POST and hub replay, the per-project dedup, the
  REST stale-parent path with a `git` shim, both closeout locks, and the hub
  path with `LANE_RUN_ID` unset or empty.
- `tests/stale-parent-rest.bh-6892-test.sh`: `bin/lib/stale-parent-rest.sh`
  on real git fixtures served by a fake `gh`.
- `worker/jobs/test/alert-lines-resolved.bh-6892.test.js`: the route accepts
  `resolved`.
- `tests/lane-run-inputs-manifest.bh-6719-test.sh` changed its premise:
  `state/health-active.txt` is now a `.rw` path, so M4 and the member table use
  `state/health-alerted.json` as the file a write-back cannot carry.
