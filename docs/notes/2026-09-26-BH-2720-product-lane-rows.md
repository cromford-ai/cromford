# Product lanes write through to proposal rows (BH-2531 part 3, BH-2720)

Doc: DB-COORDINATION-SPEC

## What changed

- **`bin/run-product.sh` honours an inherited `HARNESS`** (`HARNESS="${HARNESS:-/root/harness}"`).
  Cron sets nothing, so a box still runs against `/root/harness`.
- **Both lanes source the jobs client and `bin/lib/proposal-rows.sh`,**
  each guarded by `[ -r ... ]` and placed after the env load, so `JOBS_URL`
  from `global.env` is already set. When either file is missing, `prow_put`
  and `prow_restore` are stubs that return 1.
- **run-product restores before it decides.** `prow_restore` runs right after
  `flock -n 8` on `locks/<project>-product.lock`, before the `[]` fallback
  and before SELECT. A wiped box gets back its gated, posted and vetoed slugs,
  and SELECT skips them as it always has. The SELECT jq is unchanged.
- **run-product writes rows** for each candidate it newly appends to the
  ledger this run, and for each idea it gates (`gate_pending`).
- **product-cmd restores before both ledger checks** (chat, and the gate
  verbs). `update_company_map` never reads the ledger and skips the restore.
  A wiped box now answers kill, revise and chat from the rows, where it used to
  alert `no ledger`.
- **product-cmd writes the row** after each of its ledger writes: the chat
  `IDEA_UPDATE`, `ledger_update` (kill), the fresh-draft `.dir` in revise, and
  the revise `gate_pending`. `post_proposal` is still the same `exec` of
  `bin/post-proposal.sh`.

## Order and failure

The file is written first, then the row, and every row call is `|| true`.
Nothing reads a put's rc. A put that does not land changes neither the lane's rc
nor its file, and the jobs client logs outages to `logs/jobs-client.log` as it
does for every caller. With `JOBS_URL` empty (rc 3),
the route not deployed (worker 404 `unknown endpoint`, rc 1) or a 503, the
restore leaves the file untouched and the lanes run exactly as they did before
this change.

## Tests

`tests/product-lane-rows.bh-2720-test.sh` runs the real `run-product.sh` and
`product-cmd.sh` in a scratch harness, with a stub `curl` as the worker (R1-R3,
C1-C3c, N1).
