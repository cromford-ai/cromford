# The busy probe stops counting the run roots, and the six-hour sweep spares live work

Doc: REMOTE-GATE

## Why

Four follow-ups from the Fable review of #1213 (BH-1205, head 5e2ed123,
MERGE-WITH-NOTES). None of them blocked that merge; all four were about the two
things it added that nothing could see.

The first was a real defect. `_th_busy` asked the host `find /srv/tmp
/srv/tmp/runs /srv/runs -mindepth 1 -maxdepth 1 -mmin -120`, and `/srv/tmp/runs`
is a depth-1 child of `/srv/tmp` whose own mtime moves every time a run
directory is created or removed inside it. So a host with nothing on it but the
two empty run roots answered `TESTHOST_BUSY 1` for the whole 120-minute
`TESTHOST_BUSY_WINDOW_MIN` after the last gate run, the tick refused every stop
in that window, and `TESTHOST_IDLE_STOP_MIN` (30) never decided anything. The
knob was overridden in the safe direction by a directory nobody was using —
90 minutes of a performance-16x machine per drain.

The second was the assertion nobody had written: deleting `[ -d "$HARNESS" ] ||
HARNESS=…` from `bin/testhost-tick.sh` left `tests/testhost-tick-test.sh` 45/45
green, because that suite passes `HARNESS=$H` — a directory that exists. The
line is what lets a Mac (no `/root/harness`) stamp its own runs, and it was
unprotected.

The third and fourth were both about the composed job. The six-hour sweep is the
only `rm -rf` in this repo aimed at a path no ticket owns, it runs inside every
agent's job, and it had no test at all in either direction — the existing suite
executes the job with `RG_RUN_DIR` set, which is exactly what switched the sweep
off. And the runner-failure hint said `disk?`. Runs live on a 20 GB tmpfs now,
so a worker the kernel killed for memory and a full `/srv/tmp` produce the same
symptom (no rc file) and the hint named only one of them.

## What changed

**`bin/testhost-tick.sh`** — the busy probe's `find` now carries `! -path
/srv/tmp/runs ! -path /srv/runs`. A run directory INSIDE any of the three roots
still counts, and so does a live `bash tests/…` or `bash -s`; only the roots
themselves stopped counting. `! -path /srv/runs` never matches anything (it is
not a child of a listed root) and is there so the exclusion list reads as "the
roots". Nothing else in the probe moved: same pgrep witness, same rc semantics,
same `TESTHOST_BUSY` line.

**`bin/remote-gate.sh`** — the sweep is now a function in the job header,
`rg_sweep <root>…`, with two additions to what it did as a one-line `find
-exec`:

- **A live-process guard.** It reads `/proc/*/cwd` once and skips any candidate
  that is a cwd, or an ancestor of a cwd, of a live process. Six hours is "past
  the longest run we have seen", not "impossible", and a drain must never be
  deleted from under itself. Where `/proc` is absent the cwd list is empty and
  the sweep behaves exactly as it did before. The match is on `" $d "` or
  `" $d/"`, so `/srv/tmp/runs/1` is not protected by a live cwd of
  `/srv/tmp/runs/12`.
- **A test seam, `RG_SWEEP_ROOTS`.** Set, it is the list of roots to sweep.
  Unset, the old rule holds: `RG_RUN_DIR` set (a test driving the job locally)
  sweeps nothing, and on the host neither variable is set and the two baked-in
  roots are what is swept. So the suite can pin the sweep without going near
  `/srv`, and a test that forgets the seam still cannot reach it.

**`bin/remote-gate.sh`** — the three runner-failure hints now say "memory or
disk on the host" instead of "disk", and both failure blocks (cmd mode's copy
failure on stderr, suites mode's summary on stdout) print `rg_host_resources`:
`free -m` and `df -h /srv/tmp`, each line prefixed `remote-gate:   `. `free`
falls back to `/proc/meminfo` and `df -h /srv/tmp` to `df -h .` so the same job
text answers off the host too.

## What is pinned

Two new suites, both executing the real production artifact rather than reading
its source.

`tests/testhost-tick.bh-1221-test.sh` — the flyctl stub takes the exact command
string the tick composes for `-C`, points every `/srv` at a fixture root, and
runs it, so `find`, `wc -l` and the process witness are the real ones and the
thing under test is the command the host receives. A `pgrep` shim keeps the
process witness under fixture control. Cases: empty roots read idle and a
two-hour-idle host IS stopped; a run under `/srv/tmp/runs` and a run under
`/srv/runs` each read `busy 1` and are left alone; a run root three hours dead
reads idle; two live suite processes on empty roots read `busy 2`. Section 2
runs the tick out of a checkout COPY with `HARNESS` pointing at a directory that
does not exist and asserts the log lands under the checkout and the nonexistent
path is never created.

`tests/remote-gate.bh-1221-test.sh` — section 3 executes the composed job with
`RG_SWEEP_ROOTS` against a fixture tree: a root seven hours dead goes, a fresh
one stays, a root a live `sleep` is sitting in stays, and the sweep never
changes the job's exit code. Two recorder shims (`readlink`, `find`) are what
make the negative cases mean anything: a job with `RG_RUN_DIR` and no
`RG_SWEEP_ROOTS`, and a job with neither, are both asserted to never ENTER the
sweep, not merely to leave the fixture alone. Section 4 drives the job into a
runner failure in both modes and reads what it printed: exit 125, "memory or
disk on the host", a `df` header line, a `Mem:` line where `free` exists, and no
`(disk?)` anywhere.

## Not changed

`bin/ci-runners-status.sh` pagination, the fifth item on the ticket, was already
on main: `bin/ci-runners-status.sh:72-127` is an explicit `per_page=100&page=N`
loop with a short-read guard (train #1234, commit ea95d4e), and
`tests/ci-runners-status.bh-1206-test.sh` pins 120 runners over two pages.

The sweep's 360-minute window, the busy probe's three roots and
`TESTHOST_BUSY_WINDOW_MIN` are all unchanged. The ticket asked to pin the sweep,
not to parameterize it, and `RG_SWEEP_ROOTS` is a test seam in the job's own env
like `RG_RUN_DIR` — never a registry knob.

`docs/REMOTE-GATE.md` is not edited: every sentence it carries about the probe
and the sweep is still true (it already described the probe as counting "run
roots under `/srv/tmp`, `/srv/tmp/runs` and `/srv/runs`", which is what it now
does literally).
