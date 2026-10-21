# The settings memo loads from a pre-rendered env file, not one jq per process (BH-7717)

Doc: OPERATING

## Problem

On 2026-10-20 the top CPU users on the hub included three or more copies of
one jq program, each at 9 to 15% CPU. The program is `_LG_SC_JQ` in
`bin/lib/lane-gate.sh`. `_lg_sc_load` runs it over `state/settings-cache.json`
to fill the settings memo. BH-7494 made it one jq per process, but every new
bash process that sources lane-gate (each lane tick, each `$(…)` that loads the
memo first) ran it again over the same file.

## What changed

1. `_lg_settings_refresh` writes a new cache, then renders
   `state/lane-gate/settings-cache.env` from it. The render is atomic: a temp file
   `.settings-cache.env.XXXXXX` in the same dir, then `mv`.
2. `_lg_sc_load` reads `state/lane-gate/settings-cache.env` with shell builtins (0
   forks). It uses the file only when the file is bound to the cache bytes it
   just read. Otherwise it runs the jq as before.
3. The file lives in `state/lane-gate/`. `bk_manifest` in
   `bin/state-backup.sh` already prunes that dir, so a render does not change
   the backup manifest and the backup does not ship on every cycle
   (`tests/settings-env.bh-7717-test.sh` E10). `bin/state-backup.sh` is not
   changed.
4. `bin/settings-jq-sample.sh` (new, read-only) counts the jq processes that
   read the settings cache, and their CPU seconds per hour.

The knob order does not change. `lane_knob` still reads the DB row (the
cache) first, then the environment, then the registry default. The memo from
the env file is the same, byte for byte, as the memo from the jq
(`tests/settings-env.bh-7717-test.sh` E1).

## File format and the binding rule

```
# settings-cache.env v1 <N>
<the N bytes of state/settings-cache.json>
<the text _LG_SC_JQ prints for those bytes>
#end-v1
```

There is one `\n` between the parts and none after `#end-v1`. `N` is a byte
count (the read and the write run in the `C` locale). A reader uses the file
only when all of these are true:

- `LANE_GATE_SC_ENV` is not `0`.
- Line 1 is `# settings-cache.env v1 <digits>`, and the digits equal the
  byte length of the cache it read.
- The next N bytes equal the cache bytes, and a `\n` follows them.
- The file ends with `\n#end-v1`.

Any other file (no file, another version, a cut write, a file rendered from
an older cache) makes the reader run the jq. So a wrong file costs one jq,
never a wrong value. You can delete the file at any time.

`_setting_cache_stale` (`bin/lib/jobs/settings.sh`) rewrites the cache with
`fetched_at` 0 after a `setting_set`. The env file then no longer binds, and
readers run the jq until the next refresh renders a new file.

## Rollback

Set `LANE_GATE_SC_ENV=0` in the lane environment. No process then reads or
writes the env file, and every load runs the jq, as before this change. It is
an environment variable, not a settings row, because it controls the reader
of the settings rows.

## Measurement: hub before and after

Run this on the hub once after the merge reaches it:

```
/root/harness/bin/settings-jq-sample.sh --seconds 900 --interval-ms 50
```

For the "before" line, run the same script before the merge reaches the hub,
from a copy of this branch's `bin/settings-jq-sample.sh` (it needs no other
file, reads only `/proc` and writes nothing), with the same arguments.

It prints one line:

```
settings_jq pids=<n> per_min=<x> cpu_s_per_h=<y> window_s=900 interval_ms=50 (lower bound: ...)
```

Both numbers are a lower bound. The tool polls every 50 ms, so a jq that
starts and stops between two polls is not seen. The tool writes nothing.

## The bh-1938 history check and harness snapshots

The first build of this ticket (r1) was refused by the suite-reach gate. The
cause was `tests/config-slice-small.bh-1938-test.sh` P1, not the lane-gate
code. P1 fails when a non-shallow history with more than 1 commit holds no
pre-BH-1938 literal. `rp_snapshot_build` (`bin/lib/rules-pack-snapshot.sh`)
makes the head snapshot a fresh `git init` with 2 commits, `base` and `head`.
That history can never hold the literal, so every diff that touches
`bin/lib/lane-gate.sh` (a path the suite names) was red there.

P1 now skips a harness snapshot history, the same as a shallow clone:

- the root commit author is `rules-pack@harness` or `suite-reach@harness`, or
- the history has at most 2 commits and the root subject is `base`.

The second rule is needed because an exported `GIT_AUTHOR_EMAIL` (set on
builder boxes) beats the snapshot's `git -c user.email`. A full CI history
(thousands of commits) still runs the check exactly as before.
`tests/config-slice-snapshot.bh-7717-test.sh` C1-C4 pins both rules and shows
that a real short history with no literal still fails.

## Owed after merge (C1)

- The hub numbers, before and after, from the command above. This build ran
  on a pool machine, which cannot read the hub's `/proc`.
- Ticket step 3: the next two top hub CPU users, if each is above 5%. That
  needs the hub measurement first.
