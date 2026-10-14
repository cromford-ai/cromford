# The restore-lab routes and the hub lane that runs them

Doc: HUB-RECOVERY-MCP

## What changed

- **`worker/jobs/src/routes/restore-lab.js`**: the four BH-1942 501 stubs are
  now real routes on `restore_lab_runs`, built on the contract helpers
  `confirmed`, `auditStmt` and `knownBox`. Request, claim and result are each
  one write judged by `meta.changes`. The claim re-offers a `claimed` row older
  than the settings row `restore_lab_claim_ttl_s`, with a fallback of 1800 s.
  That row is not seeded; set it with `PUT /api/settings`.
- **`bin/restore-lab.sh`** (new hub lane, `*/5`, hub-lease gated): claims one
  run and runs `bin/state-restore.sh <prefix> <snapshot> --dest <scratch>/tree
  --live <scratch>/empty-live` under `timeout` (never `--apply`). It judges the
  output, posts the verdict, and removes the scratch dir. It refuses (exit 2 +
  ALERTS) a scratch dir that resolves inside `/root/harness`.
- **`bin/lib/restore-drill-steps.sh`**: the `pulled <box>/<ts>.tar.zst` parse
  moved into `drill_pulled_stamp`. The drill and the lab both call it. The
  drill's behaviour is unchanged.

## How the shipped wire differs from the BH-1942 contract

`docs/HUB-RECOVERY-MCP.md` and the old header comment said three things the
ticket changed. The ticket is newer, so it wins:

- A second request for an open box+snapshot is **not** `409 already_open`. It
  is `200 {id, status, run, deduped:true}`, from `INSERT OR IGNORE` against
  the partial unique index. A new run is `201 {id, status, run, deduped:false}`,
  so the contract's 201 `{id, status}` still holds.
- The claim body is `{claimer}`, not `{claimed_by}`.
- The result body is `{claimer, ok, detail, sha256, snapshot_ts}`, not
  `{status, verdict_detail, …}`. `ok` must be a JSON boolean, `ok:true` needs a
  verified sha256 and stamp, and a claimer that does not hold the run gets
  `409 not_claimed_by_you`.

`docs/HUB-RECOVERY-MCP.md` is not edited here (siblings list it as contested).
This note is the correction until a docs pass folds it in.
`docs/verification-map/hub-recovery.md` and the BH-1942 map entry still
describe the restore-lab routes as 501 stubs. #1945 owns that page. The live
shapes are in `docs/verification-map/restore-lab.md`.

## Test

`worker/jobs/test/routes/restore-lab.bh-1944.test.js` (real SQLite through
`worker.fetch`) and `tests/restore-lab.bh-1944-test.sh` (the real lane with
curl, ssh and state-restore stubbed). Both were red before this change.
