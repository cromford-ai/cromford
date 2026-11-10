# BH-9177 (C1 of #9063): both gates read and write the suite ledger

Doc: CI-RUNNERS, DB-COORDINATION-SPEC, REMOTE-GATE

## What changed

1. **The helper serves reds.** `bin/suite-reuse.sh plan` takes `--reds OUT`
   and `--rerun-red`. With `--reds`, a fail row the ledger serves at the run's
   own `(suite, fingerprint)` (C0's `reds`) goes to OUT as
   `<suite>\t<run_id>\t<class>`, leaves `--run`, and prints
   `suite-reuse: red <suite> from <run_id>`. The summary reads
   `ran X reused R red D of N`. With `--rerun-red` the red stays in `--run`.
   Without `--reds` (bin/ci-plan.sh) nothing changes. `would run nothing` is
   now only an empty run list AND an empty reds list.
2. **A Fly machine's image id.** `bin/lib/suite-fingerprint.sh` rule 3: on a
   machine with `FLY_IMAGE_REF`, the image id is `fly:sha256:<hex>` (a ref
   with a digest) or `fly:<ref>` (`sfp_fly_image_id`). Before, a pool builder
   was `os:ubuntu:24.04:x86_64`, the same id as every other Ubuntu 24.04 box.
   Every fingerprint moves once with this file (it is infra).
3. **The test host says its image.** `bin/remote-gate.sh --image-id` reaches
   the host over the usual route, sends nothing, and prints `IMAGE <ref>` or
   `IMAGE -` (rc 0; 125 with no route; 2 with a directory argument). The
   suites job prints the same `IMAGE` line once and `TIME <secs> <suite>`
   after each PASS/FAIL/BLIND line. No reader of run.txt matches either line.
4. **The builder gate reads reds.** `bin/test-impact-gate.sh` passes `--reds`.
   The fly-pool knob `TEST_IMPACT_GATE_RERUN_RED` (default 1) passes
   `--rerun-red` too; the gate's own `--rerun-red` flag wins over a 0. At 0 a
   ledger red does not run: `impact-gate: red from the suite ledger <suite>
   (run <id>)`, verdict FAILED (rc 1), `--failed` names it, and the
   `--table` row reads `(red in ledger <id>)`. A run list left empty runs no
   runner. The key's image is the machine's own (item 2), not the test
   host's: the builder gate's suites run on the pool machine.
5. **The selection gate reads and writes the ledger.** With the fly-pool knob
   `SELECTION_GATE_SUITE_REUSE` = 1 (default; `bin/lib/selection-gate.sh`
   passes it, the script alone is 0), `bin/lib/selection-gate-reuse.sh`:
   - asks `<runner> --image-id` (bound `SELECTION_GATE_IMAGE_PROBE_S`, 60 s),
   - plans with `SUITE_IMAGE_ID=<fly id>+rg:<12 hex of bin/remote-gate.sh's
     blob at HEAD>`, class builder, ctx `fly-testhost`,
   - sends only the suites with no green at (tree, image); a ledger red is a
     red without a run when `SELECTION_GATE_RERUN_RED` = 0 (default 1: sent),
   - after the verdict, records PASS as ok and `FAIL (rc N)` (N not 127) as
     fail, with the TIME duration. No row for rc 127, BLIND, a host-noted red,
     or any suite when run.txt's `IMAGE` is not the probed image.
   gate.txt gets an 11th line, `reuse:`, only with the knob at 1:
   `ran X reused G green, R red of N (image <id>); recorded N result(s)`, or
   `...; record skipped (image moved)`, or `off (<why>)`.
6. **The trust row flips to image.** The worker's first trust read on a DB
   binding runs one guarded UPDATE (`TRUST_FLIP_SQL`,
   `worker/jobs/src/lib/suite-trust.js`): `lib.suite-reuse.suite_reuse_trust`
   becomes `image` (actor `seed:BH-9177`) only while it is still an untouched
   seed: value `class` with actor `seed` (the C0 schema.d row) or actor
   `registry-seed` (POST /api/settings/seed-registry wrote the row first; r2
   widened the guard for that case). An operator's value (any other actor) is
   kept. The flipped row's actor is not `registry-seed`, so a later registry
   seed does not move it back to the registry default `class`.

## Why the flip is in the worker, not in schema.d

The plan put the flip in a schema.d fragment. `harness-sync` re-applies the
composed schema on every deploy, so the schema holds additive statements only
(`tests/schema-additive.bh-1000-test.sh`): an UPDATE there is refused. The
same guarded UPDATE in the worker's read path is idempotent, runs once per
binding, and needs no hand step.

## Why both rerun-red knobs default to 1

A fail row is sticky at its key (repo, suite, fingerprint), not per PR. One
flaky fail at fingerprint F would make S red without a run for every PR that
does not touch S's inputs, for up to `SUITE_REUSE_MAX_AGE_H` (72 h), and a fix
round needs the suite's log. At 1 a red runs again, as before C1. Set a knob
row to 0 to try red-without-a-run on one gate.

## The test host can be more than one machine (BH-9065)

Since BH-9065 the test-host app scales to zero and can run more than one
machine, and `ensure` starts a stopped one. So the `--image-id` probe and the
suites run that follows can land on two machines. During an image deploy those
two machines can run two images. The selection gate checks this: it records a
run's results only when every `IMAGE` line in run.txt is the probed image.
Otherwise gate.txt says `record skipped (image moved)` and no row is written.
The probe can start a stopped host; the run would start it anyway.

## The prequeue gate reads the reds (BH-9178, C2)

`bin/prequeue-ledger.sh` (C2, merged before this slice) already calls
`bin/suite-reuse.sh plan ... --reds REDS`. Before C1 the helper refused the
flag, and C2 fell back to `reds=unsupported`. From this merge on the helper
writes the file, and C2 reads column 1 of each line as the suite. C2 never
passes `--rerun-red`, so a ledger red fails the prequeue gate without a run.
`tests/suite-reuse-reds.bh-9177-test.sh` H8 runs the real pair.

## Known limit (open after C2)

Under `image` trust a lookup matches rows of every class and ctx when the
fingerprint is equal. The fingerprint carries `SUITE_IMAGE_ID`, and a caller
sets it. So a builder that sets `SUITE_IMAGE_ID` to a `gh:` id can write a
green that a CI lookup trusts. C0 (merged, #9104) accepted this
design. A later slice must decide if a CI lookup trusts only rows that a CI writer
recorded, or if the worker checks the image id against the writer's class.

## Rollback

- Trust: set `lib.suite-reuse.suite_reuse_trust` to `class` with your own
  actor (`PUT /api/settings/...`). The flip never touches a non-seed row.
- Selection-gate reuse: row `lane.fly-pool.selection_gate_suite_reuse` = 0;
  gate.txt is the 10-line file again and no probe runs.
- Reds: the two rerun-red rows at 1 (the default).

## Tests

`tests/suite-reuse-reds.bh-9177-test.sh` (H1-H8),
`tests/suite-ledger-gates.bh-9177-test.sh` (G1-G9, S1-S9; acceptance test 1
of #9063 through both real gates), `tests/remote-gate-image.bh-9177-test.sh`
(I1-I7), `worker/jobs/test/suite-trust-flip.bh-9177.test.js` (F1-F5; F4 is
the registry-seed guard).
