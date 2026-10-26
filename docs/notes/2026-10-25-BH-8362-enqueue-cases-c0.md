# Six mixed suites lose their enqueue cases; the live ones run on the worklist (BH-8362)

Doc: TESTING

Slice C0 of #8362 (BH-7236.1). Since BH-7235 no cron lane or wake starts `bin/lead-review-enqueue.sh`. Its
per-PR gates run in `bin/lead-review.sh tick` (the worklist, `bin/lib/lead-gates.d/`). On main at cb4ef259f, 21
suites still mixed enqueue `tick` cases with cases that test live code. This slice cleans the 6 whose enqueue
cases were mostly twinned. No file under `bin/`, `worker/`, `cron/` or `catalog/` changes.

## What left which suite

- `tests/pr-self-check-validate.bh-7072-test.sh`: H1, H1b, H1c went, with the enqueue rig (curl and gh
  stubs, the enqueue closure). H2 (`lgsc_run`) keeps a small rig: an origin, its clone and a fleet.conf.
- `tests/pr-snapshot.bh-4658-test.sh`: S3 went. The suite installs `bin/lib/pr-snapshot.sh` with
  `scratch_install_closure` in place of the enqueue closure. Its curl stub now only logs and answers 404.
- `tests/silence-scan.bh-5797-test.sh`: S5-S11 went, with their scratch harness. The scanner cases S1-S4 and
  the marker lint cases R1-R2 stay.
- `tests/lead-review-chain-doorbell.bh-4057-test.sh`: D1, D2, D5, D6 went. The lib cases L1-L5 stay.
- `tests/console-qa-gate.bh-5909-test.sh`: E1-E3 went. Q, L and B stay.
- `tests/lead-review-concurrent.bh-5317-test.sh`: C3 (the enqueue's own tick lock) went.

## Where each case went

`.harness/specs/BH-8362/twin-map.md` has one row per case id of the 6 suites: TWIN (the worklist suite and
case that pins the same outcome), ENQUEUE-OWN (output only the enqueue wrote), PORT or KEPT.

Three new suites hold the 7 ports. Each drives `bin/lead-review.sh tick` whole and has a mutation case (M1)
that removes its gate:

- `tests/lead-gates-plan-validate.bh-8362-test.sh`: PV1-PV3, the plan-validate hold of gate 75 (from
  bh-7072 H1-H1c).
- `tests/lead-gates-silence-ports.bh-8362-test.sh`: SP1 (a failed label POST holds), SP2 (a clean diff that
  is really scanned starts) for gate 30 (from bh-5797 S8, S9).
- `tests/lead-gates-doorbell-ports.bh-8362-test.sh`: DP1 (a new head rings with its own sha12), DP2 (a paid
  head rings nothing), DP3 (no `lcw_ring`: one log line) for the post hook 97 (from bh-4057 D2, D6).

## What is left (the next slices of #8362)

After this slice, 15 suites still run the enqueue `tick`.

- C1: the perf-trigger inputs. The enqueue passed `PSC_TICKET_TITLE`, `PSC_TICKET_LABELS`, `PSC_TICKET_REPO`
  and `PSC_TICKET_N` to `psc_check`. The worklist's `lgsc_run` (`bin/lib/lead-gates-selfcheck.sh`) passes only
  the linked issue body. So a ticket that is perf by label or title only is not held on the worklist. C1 fixes
  `lgsc_run`, then ports bh-6372 E1, E2.
- C2: gate 50 (replay and delta): bh-7043, bh-6391, bh-5294, bh-5582, bh-3930.
- C3: gate 60 (risk): bh-5325, bh-5024, bh-7041, bh-5875, bh-6968, bh-6967, silence-before-risk.
- C4: gate 70 (in-build grace): bh-5023, inbuild-grace-outside-push.
- Then #8363 (BH-7236.2): the static readers and the script deletion.
