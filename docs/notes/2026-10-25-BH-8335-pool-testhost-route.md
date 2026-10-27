# BH-8335: a pool machine gets flyctl and its own route to the Fly test host

Doc: REMOTE-GATE, FLY-POOL

## Why

`bin/selection-gate.sh` runs a build's selected suites on the Fly test host
through `bin/remote-gate.sh`. On a pool machine that needs `flyctl` and a Fly
credential that opens the test host. The pool image had no flyctl and
`bin/fly-pool.sh` shipped no credential. So every pool build wrote
`rc: could-not-run why=runner-rc-125` into `gate.txt`, and the gate's only
line ("flyctl is not on PATH") named none of the parts.

The first version of this change shipped a cert from `flyctl ssh issue <org>`.
That cert is org-wide: flyctl's `ssh issue` passes no app names, so every
machine in the org accepts it. The pool apps, the builder apps and the test
host are all in `board-builders`, so one project's build could open a root
shell on another project's builder (lead BLOCK #4386, tenant-leak). On
2026-10-27 the operator decided: no new Fly org; the test host stays in
`board-builders`, and the credential is scoped to the test-host app.

## What changed

1. `fly/Dockerfile` has a `bake-flyctl` block. It installs flyctl at the
   `bake.flyctl.version` row (manifest row `flyctl FLYCTL_VERSION flyctl` in
   `bin/lib/bake-deps.sh`) into `/root/.fly/bin`, which is on `PATH`. With no
   row, the bake uses this project's last baked flyctl, then the hub's own
   `flyctl --version` (the hub installs the same release tarball). The block
   checks the tarball against `flyctl_<v>_checksums.txt`, the name
   `fly/hub/Dockerfile` bakes with. A bare `checksums.txt` is 404 on flyctl
   releases (commit 1e82d292, BH-7715). `fly/lane-run.Dockerfile`'s
   `bake-flyctl` block still reads `checksums.txt`. That block is not changed
   here.
2. `bin/fly-pool.sh` gives each pushed spawn its own route
   (`bin/lib/pool-testhost-route.sh`). Before the launch, `ptr_build` mints a
   Fly SSH token scoped to the test-host app:
   `flyctl tokens create ssh -a <TESTHOST_APP> -x <h>h -n pool-<key>`. It
   always passes `-x` (flyctl's default expiry is 20 years). The mint tries
   the tick's own Fly credential first, then the flyctl session
   (`bin/fly-pool-rollout.sh` mints that way). The push phase sends the route
   before `job.json`. A reused machine gets a fresh route before its next
   `job.json` (`next_job_or_destroy`). Nothing calls `flyctl ssh issue`.
3. `bin/remote-gate.sh` reads `$HARNESS_ENV_DIR/testhost.env` (or
   `REMOTE_GATE_ROUTE_ENV`) through a whitelist of three keys. It never
   sources the file. A variable already in the env wins over the file. The
   route sets `REMOTE_GATE_TRANSPORT=fly-ssh`. On that transport every remote
   call is `flyctl ssh console -a <TESTHOST_APP> -q -C …`: no `flyctl proxy`,
   no key file, no cert issue. The `bash -s` jobs go up wrapped in a subshell
   with one marker line after them, so the job's own exit code comes back
   (flyctl's exit code is not used). No marker is rc 255, the same as
   OpenSSH's "could not run anything", so the gate exits 125. rsync's remote
   shell is `bin/lib/remote-gate-fly-rsh.sh`. It refuses (exit 2) anything
   but `rsync --server` to localhost, and any argument with a character
   outside `[A-Za-z0-9._/=,+:-]`. With `POOL_MODE=1`, when flyctl, the route
   file or the token is missing, or the token has expired, it prints one line:
   `remote-gate: pool test-host route incomplete: flyctl=<path|MISSING> route=<file> (present|MISSING) transport=fly-ssh token=<present|MISSING|expired>`.
   The token is never printed. The exit codes do not change. On the hub
   nothing changes: the transport is `openssh` (proxy + cert) as before.

## The credential

`flyctl tokens create ssh -a <app>` (flyctl `internal/command/tokens/create.go`,
`runSSH`) starts from a deploy token for the app and keeps two parts: app read,
and the two mutations `issueCertificate` and `addWireGuardPeer`. With it,
`flyctl ssh console -a <app>` gets a cert for that one app (the `allowed-apps`
critical option) for each connection.

| can | cannot |
|---|---|
| open a root shell on the test host's machines | deploy, set secrets, start, stop or destroy a machine |
| read the test-host app | open a shell on any other app's machine (their ssh servers refuse the cert) |
| add a WireGuard peer to the org network | issue an org-wide cert through this route (the code never asks) |

Residual: the token can add a WireGuard peer to `board-builders`. A peer
reaches every app's private 6PN address. Other apps' Fly ssh servers refuse
the cert, but any other service that listens on 6PN without its own auth is
reachable. Each pool machine that runs the gate can add one peer.

A machine-exec token (`flyctl tokens create machine-exec -a <app>`) is
narrower: exec only, no WireGuard. It is not used, because one exec call ends
at 60 s and buffers its output, so it cannot carry the rsync upload or a
suite run that streams for up to 25 minutes.

## The route on a machine

One file, mode 600, on the tmpfs `/run/harness-env/`:

| file | content |
|---|---|
| `testhost.env` | `REMOTE_GATE_TRANSPORT=fly-ssh`, `FLY_API_TOKEN=<the SSH token>`, `TESTHOST_ROUTE_EXPIRES=<epoch>` |

`fly/builder-runner.sh` deletes `*.env` in that dir when the machine goes
idle, so the token goes with the other secrets. The token is the one Fly
credential that leaves the hub. It never goes to a log line, a `say` line,
the machine json or `global.env`. remote-gate runs flyctl with
`FLY_ACCESS_TOKEN` unset, so the route token is the credential it uses.

The test host's power stays with the hub. The SSH token cannot start a
machine, so on a pool machine `bin/testhost-tick.sh ensure` cannot start a
stopped host. If the idle stop has put the host away, the pool gate records
could-not-run with the ssh failure as its reason.

## Knobs

- `lane.fly-pool[.<project>].pool_testhost_route`: 0 (default) ships no
  route. Only cromford has the selection gate today, so the row
  `lane.fly-pool.cromford.pool_testhost_route` = 1 turns it on for
  cromford alone. 0 is the rollback.
- `lane.fly-pool[.<project>].pool_testhost_token_hours`: 0 (default) derives
  the hours: `ceil(lane_reap_deadline_secs / 3600) + 1`, which is 6 for the
  16200 s default. 1..72, the knob's registry range.
- The mint's time bound is the existing row
  `lib.remote-gate.remote_gate_cert_issue_timeout_s` (default 60 s).

## Failure

A failed mint writes no route file and logs one line in `logs/fly-pool.log`:
`<key>: testhost route: not shipped (token mint rc N | token empty) — the selection gate will record could-not-run`.
The spawn goes on. A failed push is one `push FAILED` line. The line
`<key>: testhost route shipped to <mid> (expires <iso>)` means only that the
file was pushed. The proof that the route works is the build's `gate.txt`
(`rc: 0`, or `rc: 1` with red suites) and `SELECTION-GATE rc=` in its
`pipeline.log`.

A pull spawn (`POOL_MACHINE_PULL=1`) ships no route yet. On such a machine
the gate prints the named-miss line.

## Operator steps

1. `bin/bake-seed.sh flyctl=<the hub's flyctl version>`. Without the row,
   the bake uses the hub's installed flyctl, and `bin/fly-image-refresh.sh`
   writes an ALERTS line every night.
2. Set the row `lane.fly-pool.cromford.pool_testhost_route` to `1`.
3. After the first cromford pool spawn, read `logs/fly-pool.log` on the
   hub. Expect `testhost route shipped to <mid>`. A `not shipped (token mint
   rc N)` line means the hub's Fly credential cannot mint an SSH token for
   the test-host app.
4. After one pool build, read its gate record on the hub:
   `ls -t /root/harness/builds/cromford-*/gate.txt | head -1 | xargs cat`.
