# Pool bake evidence reaches a cromford pool build (BH-6259, slice C0)

Doc: OPERATING

## Why

BH-6259 asks for the slow phase of the project-3, project-2 and project-1
pool bakes, measured from at least 3 `bake phases` lines per pool. Those lines
are in `logs/fleet-propagate.log` on the hub. The step timings of a timed-out
bake are in `logs/fly-image-build/<pool>-<sha7>.log`, also on the hub. A
cromford build runs on a Fly pool machine, and that machine has neither
file. So a build could not quote one measured line.

## What changed

1. **`bin/bake-evidence.sh`** (new, read-only). It prints a digest of
   `logs/fleet-propagate.log` and `logs/fleet-propagate-cron.log`, plus the
   newest bake captures. It keeps a log line that matches
   `pool <P>: bake phases `, `pool <P>: outer timeout hit ` or
   `pool <P>: bake ran <n>s, past `, and only the last `--lines` (default 10) of
   each pool. For each of the newest `--captures` (default 6) captures, it keeps
   the capture header line and at most 80 `## step timings` lines, never the
   `## last 200 lines` tail. It drops any line with a token value
   (`x-access-token:<value>`, `ghp_`, `ghs_`, `github_pat_`). It cuts the
   digest at `--max-bytes` (default 24576) on a line end and then prints
   `# truncated at <B> bytes`. Exit 0 = digest, 3 = nothing found (one
   `# bake evidence (BH-6259): none on <host>` line), 2 = bad argument.
2. **`push_bake_evidence`** (`bin/fly-pool.sh`, block
   `# >>> bake-evidence relay (BH-6259)`). At dispatch of a cromford job,
   after `push_build_note`, it runs the script (`timeout 20`) and copies a
   digest with rc 0 to `/data/harness/state/bake-evidence.txt` on the machine.
   It writes `relayed the hub bake evidence to <mid>` or
   `<mid>: bake-evidence push FAILED — this build plans without it` to
   `logs/fly-pool.log`. It always returns 0 and never changes the dispatch.
   Other projects get no digest. Both dispatch paths call it: `spawn_one`
   (a new machine) and `next_job_or_destroy` (the REAP loop reuses a live
   machine for the next queued job). On a reused machine a failed copy leaves
   the digest of the earlier job in place, so the planner compares `at=` with
   its own dispatch time.
3. **`prompts/cromford.md`** tells the planner where the digest is, and
   that a missing file does not mean that no bakes ran.

## Digest format

```
# bake evidence (BH-6259) host=<hostname> at=<UTC ISO-8601> sources=<files read>
## bake phases (last <N> per pool)
<matching log lines, time order>
## captures (newest <M>, logs/fly-image-build/)
### <capture file>
<capture header line: pool=... rc=... phases=...>
<'## step timings' lines, at most 80>
# truncated at <B> bytes            (only when the cap cut the output)
```

## What this does NOT do

This slice measures nothing and fixes no bake. No phase line was quoted,
because the build machine had none. Scope 2 (find the slow phase and its
cause), scope 3 (fix it) and acceptance test 1 (quote at least 3 lines per pool
before and after) are owed to the next build of BH-6259 (slice C1).
`POOL_BAKE_TIMEOUT_S` stays 1800 s.

## Probe

1. On the hub, run `HARNESS=/root/harness /root/harness/bin/bake-evidence.sh | head -40`.
   It must list `bake phases` lines for project-3, project-2 and project-1.
2. After the next cromford pool dispatch, run
   `grep 'relayed the hub bake evidence' /root/harness/logs/fly-pool.log | tail -1`.
3. On that pool machine, run `head -5 /root/harness/state/bake-evidence.txt`.
