# The selection gate says why it could not run, and fly-ssh pins one machine (BH-8725)

Doc: REMOTE-GATE

## What changed

- `bin/selection-gate.sh`: a `runner-rc-<n>` or `red-without-names` why now
  carries the runner's reason, `<token>: <one remote-gate: line of run.txt>`.
  `_sg_reason` picks the `pool test-host route incomplete:` line, else the
  last `remote-gate:` line. It removes control characters, replaces a line
  with `FlyV1` or `fm2_` by `<token line dropped>`, and cuts the reason to
  `SELECTION_GATE_WHY_MAX` characters. `timeout`, `runner-failure`,
  `plan-rc-*` and the other tokens are unchanged.
- `bin/lib/selection-gate.sh`: the `SELECTION-GATE rc=` log line ends with
  ` why=<why>` when there is a why. The could-not-run alert prints the why and
  leaves out the generic `Needed:` hint when the why carries a reason.
  `_sg_run` writes `$BUILD/gate-run.tail.txt`: the last
  `SELECTION_GATE_RUN_TAIL_LINES` lines of run.txt, token lines replaced.
- `bin/lib/pool-record.sh` and the ssh pull list in `bin/fly-pool.sh`:
  `gate.txt` and `gate-run.tail.txt` are added at the end. A pool build's
  gate record now reaches the hub's `builds/pool-<project>-<KEY>-<ts>/`.
- `bin/remote-gate.sh`: on fly-ssh, `_rg_fly_pin` picks one machine (env
  `TESTHOST_MACHINE`, else one `-C hostname` probe) and every call passes
  `--machine <id>`. `bin/lib/remote-gate-fly-rsh.sh` adds `--machine` from
  `RG_FLY_MACHINE` and refuses a malformed id. A failed probe names flyctl's
  last stderr line, and a failed upload names rsync's rc and its last stderr
  line (token lines are never copied). The openssh transport does not change.
- Knobs (fly-pool lane): `SELECTION_GATE_WHY_MAX` (160 characters) and
  `SELECTION_GATE_RUN_TAIL_LINES` (40 lines).

## Why

Every pool build wrote `why: runner-rc-125` and nothing more. The plan session
reproduced the cause on a pool machine: `bin/remote-gate.sh . -- true` exited
125 with `the upload to the test host failed (rsync)`. Without `--machine`,
`flyctl ssh console` writes `No machine specified, using <id> in region sjc`
on stdout. rsync read that line as protocol bytes (`protocol version mismatch
-- is your shell clean?`). The app has 3 started machines, so unpinned calls
can also put the run dir and the job on different machines. The hub probe
`echo probe-ok` passed because its output still arrived after the extra line.

## Tests

- `tests/selection-gate-cnr-reason.bh-8725-test.sh`: the why, the log line, the
  alert, the tail, the record files and the knobs.
- `tests/remote-gate-fly-pin.bh-8725-test.sh`: the pin, `TESTHOST_MACHINE`, a
  failed probe, the wrapper and the rsync reason.
- `tests/selection-gate-host-run.bh-8725-test.sh`: the host compose step, the
  compose why, the host notes and the `host-noted:` line.

## Fix round (r3): the host run matches CI

With the pin, the gate ran on a pool machine (`SELECTION-GATE rc=1
suites=754`) and went red on six suites that plain main is also red on there.
Three causes, none of them this diff:

1. Four suites died on `ERR_MODULE_NOT_FOUND ... catalog/lanes.json`. The
   catalogs are git-ignored renders. CI composes them before the suites; the
   host did not. The suites job now runs CI's three compose commands once,
   before the suite copies. A failed compose is could-not-run
   `why=compose-<name>: <line>`.
2. `tests/fly-pool-split.bh-7542-test.sh` C3 reads `git log -1 -- <path>`. The
   host context is shallow, so it names the graft root. The last writer of
   `0100-head.sh` is far behind main and the pool clone is `--depth 50`, so a
   deeper context cannot reach it. The gate notes it (`shallow-context`).
3. `tests/issue-testhost-cert.bh-5210-test.sh` W1x and W1ix: a 6 s bound on a
   shared, loaded host. The gate notes them (`host-timing`).

The notes live in `catalog/selection-gate-host-notes.d/bh-8725.tsv`. The six
suites are not edited, and CI and the flaky quarantine do not change.

The r2 reason picker also chose the host-resources dump
(`remote-gate:   <free/df line>`) after a RUNNER FAILURE line. It now skips
those lines.

Not changed: `sg_off_gate` still writes the 9-line rc=off record (its line
count is pinned by `tests/selection-gate-off-record.bh-8062-test.sh` O1).
Every reader uses `_sg_field`, so a missing `host-noted:` reads as empty.

## Live check (build session, 2026-10-28)

On pool machine `pool-cromford-812445c9009018`, `bin/remote-gate.sh . -- true`
exited 125 with `could not pick one test-host machine … (the hostname probe
printed no machine id, rc 1: Error: get app: Get
"https://api.machines.dev/v1/apps/bh-testhost-example-org": Forbidden)`. The
route token on that machine could not read the app at build time, pinned or
not. That is a token scope or rotation problem, not the transport. The pin
itself is proven by the test suite only; a routed build after merge must show
the live result.
