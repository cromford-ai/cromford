# Hub load sampler lane (BH-6882, part of #6881)

Doc: OPERATING

## What changed

`bin/hub-load-sample.sh` is a new hub lane, `hub-load-sample`. It runs every
10 min behind `bin/hub-lease.sh check` (`cron/lanes/732-hub-load-sample.cron`).
It has no LLM call and no paid call. One run takes about 45 s.

One run:

1. Takes 30 `ps -eo pid=,ppid=,stat=,comm=,args=` samples, 1 s apart. Each
   R-state process counts once per sample. It is put under the nearest
   process in its own parent chain (itself first) whose args hold
   `bin/<name>.sh`, else under `(<comm>)`. The chain walk stops at depth 64,
   pid 0 or 1, or a repeat. The sampler's own process tree is not counted.
   A sample whose `ps` fails or prints nothing is not counted.
2. Reads one `vmstat 5 2`. The us, sy, id, wa and st values come from the
   LAST data line, by the column names in the second header line.
3. Reads the `processes` line of `/proc/stat` twice, 10 s apart, for forks
   per second.
4. Appends one line to `state/hub-load/<YYYY-MM-DD UTC>.tsv`.
5. Upserts one ledger row through the jobs client: `job_ledger_put hub-load
   <box>:<HH>:<M0> ok <detail JSON>`. The key is the 10-minute slot of the UTC
   day, so the ledger holds at most 144 rows per box (a rolling 24 h ring on
   the existing `(kind, key)` unique key).
6. Deletes `state/hub-load/????-??-??.tsv` files whose filename date is more
   than `hub_load.keep_days` days before today (UTC). A name that is not a
   real date is not touched.
7. If the p90 of the last 6 `runnable` values (today's file, then
   yesterday's; NA skipped; linear interpolation) is over
   `hub_load.max_runnable`, writes one `bin/lane-alert.sh --log-only` line per
   UTC hour. The latch is `state/hub-load/alert-hour`, written before the
   line. `--log-only` opens no alert state row and sends no page.

A value that could not be read is `NA` in the tsv and `null` in the ledger
detail, never `0`: no `vmstat` on PATH or output that does not parse gives
`steal=NA cpu=NA`; a missing stat file or `processes` line gives
`forks_s=NA`; no good `ps` sample gives `runnable=NA` (that run is not used by
the alert).

## The tsv line

Tab separated. The time first, then `key=value` fields:

```
<ISO time>  runnable=<x.xx|NA>  steal=<n|NA>  forks_s=<x.x|NA>  cpu=us:<n>,sy:<n>,id:<n>,wa:<n>|NA  samples=<ok>/<want>  <name>=<share %> (up to 15)
```

`runnable` is the mean R count per good sample. A name's share is its R
count over all R counts, in percent. The 15 names are ordered by count, then
by name.

The ledger detail JSON holds the same values:
`{ts, runnable, steal, forks_s, us, sy, id, wa, samples, top:[{n, share}]}`.

## Knobs

| Key | Default | Meaning |
|---|---|---|
| `hub_load.keep_days` | 14 | Days of tsv files kept. Settings row (`worker/jobs/schema.d/202610151351-bh-6882-hub-load-knobs.sql`). |
| `hub_load.max_runnable` | 8 | The alert limit (the hub vCPU count). Settings row, same fragment. |

A row value that is not a positive integer is ignored, and the default is
used. The summary line shows the source: `keep_days=14(default)` or
`keep_days=14(row)`.

Test seams in `catalog/lanes.d/hub-load-sample.json`, not settable:
`HUB_LOAD_SAMPLES` (30, range 1..300), `HUB_LOAD_INTERVAL_S` (1),
`HUB_LOAD_FORK_WINDOW_S` (10), `HUB_LOAD_PROC_STAT` (`/proc/stat`),
`HUB_LOAD_NOW` (epoch seconds).

Off: `bin/harness-ctl.sh off hub-load-sample` (flag
`lane-off-hub-load-sample`).

## Summary line

`logs/hub-load-sample.log`, one line per run:

```
<ts> runnable=<x> steal=<x> forks_s=<x> samples=<ok>/<want> push=<ok|failed|not-configured|not-loaded> pruned=<n> alert=<written|latched|under|insufficient(<n>)> keep_days=<n>(row|default) max_runnable=<n>(row|default)
```

or `<ts> skipped (running)` when another run holds
`locks/hub-load-sample.lock`. A failed push does not stop the tsv write and
does not alert. The lane exits 0 on every path.

## The 24 h baseline (#6881)

24 h after deploy, run this on the hub. It prints runnable p50/p90, steal p50
and forks/s p50 over the last 144 lines (NA skipped):

```bash
cat $(ls /root/harness/state/hub-load/????-??-??.tsv | tail -2) | tail -144 | awk -F'\t' '{for(i=2;i<=NF;i++){split($i,a,"=");if(a[2]!="NA"&&(a[1]=="runnable"||a[1]=="steal"||a[1]=="forks_s"))print a[1],a[2]}}' | sort -k1,1 -k2,2g | awk '{v[$1,++n[$1]]=$2} END{for(k in n){c=n[k];printf "%s p50=%s p90=%s n=%d\n",k,v[k,int((c+1)*0.5)],v[k,int((c-1)*0.9)+1],c}}'
```
