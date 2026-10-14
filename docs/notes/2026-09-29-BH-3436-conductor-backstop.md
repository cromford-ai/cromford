# Merge conductor keyed backstop, every 5 minutes (BH-3436.2 / BH-3454)

Doc: MERGE-CONDUCTOR

## What changed

A new hub lane, `merge-conductor-backstop`, fires every 5 minutes
(`cron/lanes/411-merge-conductor-backstop.cron`). It runs
`bin/merge-conductor-backstop.sh`, which reads one local file,
`state/merge-conductor/pr-state.tsv`, and makes no GitHub call of its own.

A row is a candidate when its state is `WAIT_CI` or `READY`, its `head` is set,
its `reviewed` sha equals its `head`, and its key is `owner/repo#number`. Rows
that fail the key shape are dropped here, so the conductor never sees an
all-invalid key list and falls back to a full tick.

No candidate: one `0 candidates — nothing to do` line and exit 0. Otherwise it
takes the oldest candidates by `since`, up to `MC_BACKSTOP_MAX_KEYS`, and hands
them to ONE keyed conductor run in the foreground:

    MC_ONLY_PR=<pr-list> WAKE_LAUNCH=1 timeout 240 bin/merge-conductor.sh

That is the same keyed tick a wake runs (BH-1387). It skips the fleet sweeps and
never restarts the cadence-hold clock, and runs the auto-enqueue step over the listed rows, so
a green WAIT_CI row goes READY and gets its `@mergifyio queue` in the same run.
The full `*/30` tick in `cron/lanes/410-merge-conductor.cron` is unchanged.

## Why

Parent BH-3436, ask 2: green to queued in 5 minutes at worst, without paying
for the heavy full tick every 5 minutes.

## Knob

`MC_BACKSTOP_MAX_KEYS` (int, default 6 since BH-4842 (was 20), 0 = no cap, 0..200). Set it with a
`lane.merge-conductor-backstop.mc_backstop_max_keys` settings row; the lane
reads it through `lane_env_apply`. A non-integer value falls back to 20. Over
the cap, the fire logs `<n> deferred (cap MC_BACKSTOP_MAX_KEYS=<cap>) — the next
fire takes them`.

`timeout 240` is not a knob. It has to stay under the 300 s cadence so two fires
never overlap. On a timeout the log says `hit timeout 240 — killed`; any other
conductor rc is logged as `rc=<n>`. The backstop itself exits 0 either way.

## Cost per fire

- Idle fleet: no GitHub call. The only network is the lane gate's and
  `flag_active`'s cached flag reads, both fail-open.
- Per project that owns a candidate: one open-PR list.
- Per candidate: the conductor's usual per-PR reads, and at most one
  `@mergifyio queue` post (the auto-enqueue ledger dedupes per head).

## Off switches

- Its own: `bin/harness-ctl.sh off merge-conductor-backstop`
  (`flags/lane-off-merge-conductor-backstop`), plus `flags/all-off`.
- It also stands down, exit 0, when `flags/automerge-disabled` or the
  conductor's `lane-off-merge-conductor` is set.
- Observe mode, the kill switch and merges pause are applied by the keyed
  conductor run itself, unchanged.

## Caveats

- A project with `mc_tick_secs` > 0 keeps its cadence hold on a keyed tick too
  (`tick_project` in `bin/merge-conductor.sh`), so there the worst case is
  `mc_tick_secs`, not 5 minutes. The default is 0.
- A stale WAIT_CI row for a closed PR costs one open-PR list for its project and
  then does nothing. The cap bounds it.
- A row whose head moved past its review is not a candidate. Re-review is the
  full tick's job.

## Hub-lease gating (BH-1000 rule)

The cron line sits behind `hub-lease.sh check &&`, like every other hub lane.
Probe, run on a build box (not the hub) against the rendered hub crontab:

    HARNESS_TEST_SANDBOX=1 bin/render-cron.sh hub | grep -c 'hub-lease.sh check &&'

Without this lane: 68. With it: 69. The 410 conductor line is one of the 68, so
the lease already gates the conductor and this lane adds no new dependency. The
live `bin/hub-lease.sh check` on the hub was not run from this build.

Suite: `tests/merge-conductor-backstop.bh-3454-test.sh`.
