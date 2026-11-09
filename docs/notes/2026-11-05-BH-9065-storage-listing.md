# BH-9065 — idle Fly storage, stopped machines and artifact retention

Doc: REMOTE-GATE

Fix 6 of BH-9065 deletes idle storage and sets GitHub Actions artifact
retention. Each of these is irreversible or changes a setting outside a PR. So
the build runs none of them (guardrails 1 and 4). This note gives the read-only
listing commands and the numbered operator steps.

## Storage listing

NOT RUN on the build box: it has no Fly token (`flyctl` answered `no access
token available`). An operator with a Fly token runs these read-only commands
and pastes the output into the PR body under `## Storage listing`, one line per
volume and one per stopped machine id:

1. `flyctl volumes list -a <harness-hub app> --json` (the 200 GB hub volume;
   its machine stopped on 2026-10-21, the hub moved on 2026-10-23).
2. `flyctl volumes list -a <builder app> --json` (the 50 GB builder volume).
3. For each app of the org: `flyctl machine list -a <app> --json | jq -r
   '.[] | select(.state=="stopped") | "\(.id) \(.name) \(.updated_at)"'`
   (the audit counted 25 stopped machines; 13 are CI runners stopped since
   2026-09-23).

## testhost-4 background load

NOT RUN on the build box, for the same reason. The audit saw testhost-4
(`48e6391b9e2178`) at a constant 37.6% CPU, system above user. The read-only
probe:

1. `flyctl machine status 48e6391b9e2178 -a bh-testhost-example-org`
2. `bin/issue-testhost-cert.sh` (never a raw `flyctl ssh issue`, BH-5210), then
   `flyctl ssh console -a bh-testhost-example-org --machine 48e6391b9e2178 -C
   'ps -eo pid,pcpu,etime,args --sort=-pcpu'` and keep the first 20 lines.

If the top process is a harness process (a stuck gate run, a leaked drain), it
is a code defect: file it against `bin/remote-gate.sh`. If not, stop it as an
operator step. The idle stop in `bin/testhost-tick.sh` stops an idle host only
when the busy probe sees no live run, so a stuck run keeps that host started.

## Operator steps

Do these after the listing, in this order. Each one is irreversible.

1. For each volume of the listing that has no started machine:
   `flyctl volumes destroy <volume-id> -a <app> --yes`.
2. For each stopped machine of the listing that is not a CI runner:
   `flyctl machine destroy <machine-id> -a <app>`. The CI runners are out of
   scope (ticket: "CI runner machines (stopped, no change)").
3. Set the artifact and log retention of example-org/cromford to 7 days:
   `gh api -X PUT repos/example-org/cromford/actions/permissions/artifact-and-log-retention -F days=7`.
4. Read it back: `gh api repos/example-org/cromford/actions/permissions/artifact-and-log-retention`
   must show `"days": 7`.

The test hosts and the pool need no operator step: the 10-minute idle stop and
the model class are on at deploy (fallbacks of `TESTHOST_IDLE_STOP_MIN` and
`VM_CLASS`). The `lane-run-mk` and `lane-run-ts` group rows move to
`shared-cpu-2x` / 4096 as an operator step (see
`2026-11-05-BH-9065-pool-machine-shape.md`, part 4b).
