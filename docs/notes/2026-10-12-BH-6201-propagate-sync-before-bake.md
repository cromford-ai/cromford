# fleet-propagate: box sync never waits on a pool bake (BH-6201)

Doc: OPERATING

## What happened

On 2026-10-12 the boxes did not get new harness code for more than one hour.
`bin/fleet-propagate.sh` held its lane lock (`locks/fleet-propagate.lock`, fd 9)
for the whole run, and the pool bakes it started inherited that fd. Bakes of
project-3, project-2 and project-1 ran to the 1800 s limit. Each tick in
that time exited at the lock and wrote no log line. A tick that found any
`fly-image-build.sh` process running wrote `DEFERRED` and did not reach the box
step either. No alert said that the boxes were behind.

## What changed

1. **Sync before bake.** A run has two steps. The sync step is the hub pull and
   `harness-sync.sh`, the boxes (it waits for the box PIDs only), the crontab,
   the record and `state/fleet-propagate/box-shas.tsv`. Then the run closes fd 9.
   Then the bake step runs under a new lock, `locks/fleet-propagate-bake.lock`
   (fd 6). The next tick can sync the boxes while the bakes run. The sync step
   bound is fetch 60 s + pull 120 s + harness-sync 300 s + boxes 660 s.
2. **No global bake defer.** A running `fly-image-build.sh` no longer defers the
   tick. The bake step checks each pool (`pgrep -f 'fly-image-build\.sh <pool>( |$)'`).
   A match makes that pool `busy`: tolerated like `debounced`, the dirty mark
   kept, no bake, no retry counted. The `harness-sync.lock` defer stays.
3. **Overlapping runs.** When the bake lock is held, the run bakes nothing. It
   marks its pools dirty at its sha, writes no `pool-*` file, records
   `bake:"deferred"`, and its line says `images=deferred(<n>)`. The alert says
   `<n> pool images deferred to the bake step already running`. That is never a
   page. A drain tick that finds the bake lock held logs
   `drain deferred: a bake step is running (<pools>)` and exits before the hub step.
4. **Dirty marks.** `fp_mark_dirty` never replaces a newer mark or a mark the
   checkout does not know. `fp_clear_dirty` removes a mark at the sha, an older
   one, or one the checkout does not know (stale: every real mark is a sha this
   checkout fetched). So an older run never loses a newer run's mark.
5. **Record merge.** The sync step writes `state/fleet-propagate.json` with
   `bake:"pending"|"deferred"|"none"`. The bake step merges `.pools`,
   `bake:"done"`, `.bake_sha` and `.bake_finished_at` under
   `locks/fleet-propagate-state.lock`. It never writes `.last_sha`.
6. **Log lines.** With pools to bake, the sync step writes
   `<old7>..<new7> hub=.. boxes=K/N images=pending(<n>) cron=.. paths=..`.
   The final line after the bakes keeps its shape, and it is still the last
   line of the run.
7. **Box lag alert.** Before the lane lock, each deploy tick compares
   `box-shas.tsv` with the hub checkout HEAD. A box is behind when it has no
   row, its sha is `-`, or the hub sha is not in its history AND the two differ
   on a fleet path (the BH-5247 rule). The first sighting writes
   `boxes-behind-since` (`<epoch> <hub7>`). Past `PROPAGATE_BOX_LAG_ALERT_MIN`
   minutes (settings row, default 30, 0 = off) the lane sends ONE
   `--critical --id fleet-propagate-boxes-behind` alert and writes
   `boxes-behind-alerted`. When no box is behind, it sends one `--log-only
   --resolve` and removes both files. `--check` prints `box lag: ...`.
8. **Bake phases.** Every bake logs
   `pool <P>: bake phases build=<s>s push=<s>s record=<s>s total=<s>s rc=<rc>`
   (`-` for a phase it did not reach). The same value is the sixth field of
   the pool result, `.pools[<p>].phases` in the record, and `phases=` in the
   capture header.

## What this does NOT do

The cause of the project-3 / project-2 / project-1 bake timeouts is NOT
found by this change. The hub logs were not readable from the build box.
`POOL_BAKE_TIMEOUT_S` stays 1800 s. The cause is owed after the first measured
bakes.

## Procedure on the hub (scope 3, owed)

1. Run `grep 'bake phases' /root/harness/logs/fleet-propagate.log | tail`.
2. Run `ls /root/harness/logs/fly-image-build/`.
3. For a bake that timed out, read the `## step timings` block of its capture.
4. If `build=` is near 1800 s, the build is slow: find the slow step in the
   capture. If `push=` is large, the push is slow.
5. Do not raise `POOL_BAKE_TIMEOUT_S` before step 4 names the slow phase.
