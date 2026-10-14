# PR owner clocks, build notes and the digest guard become DB rows (BH-5003, wave 4 of #4951)

Doc: DB-COORDINATION-SPEC

## What changed

Three per-box files stop being the record. Each still gets written exactly as
before, as a mirror; wave 6 (#5005) deletes them.

- **A ledger compare-and-set.** `POST /api/ledger/claim` in
  `worker/jobs/src/routes/ledger.js`. Body `{kind, key, status, actor?, detail?,
  terminal: [<=8 strings], stale_s: 30..86400}`, 400 on anything else. One
  upsert whose UPDATE arm runs only when the row's status is not terminal and
  (is not `status`, or is `status` older than `stale_s` on the worker's clock).
  Answers `200 {claimed, ledger, as_of}`. No schema change: `ledgers` exists.
  Client verb `job_ledger_claim <kind> <key> <status> <stale_s> [terminal-csv]
  [detail]` in `bin/lib/jobs/jobs.sh`: rc 0 won, rc 3 held (prints the
  holder's status), rc 2 the route did not answer its contract (a 404, or a 2xx
  with no boolean `claimed`), rc 1 outage.
- **Daily digest send-once on any hub** (`bin/daily-digest.sh`). After the
  render and right before `archie-tg-send.sh`, the lane claims
  `daily_digest/<D>` as `sending` (terminal `sent`). Held elsewhere: no send,
  summary ` claimed-elsewhere`. Route absent: one note line and the send as
  before. Claim failed while the dedupe read worked: no send, summary
  ` claim-failed`, retried next tick. Claim failed with the whole ledger down:
  the send goes ahead as before, and `archie-tg-send.sh`'s own ledger read
  refuses it while that read fails. A failed send writes `send-failed`, which
  releases the claim. `state/daily-digest/sent-<D>` is still written after a
  good send.
- **PR owners: the rows decide** (`bin/pr-owner-sweep.sh`). A state-file entry
  survives only when D1 holds an open `pr_owners` row for that PR, so a stale
  file (a restore, a reopened PR) cannot hand an old `since` to a PR D1 closed.
  Logged as `pr-owners: N file-only PR(s) dropped — D1 holds no open row for
  them (rows are the record)`. The old `file + fresh rows` merge still runs on
  rc 2, an outage, a 500-row answer (the route's cap), `push_pending:true` in
  the file (the last PUT did not land; written from the PUT's real rc), or the
  knob at 0. Watcher boxes whose own triage tick sweeps the same repo as the
  hub each PUT `complete:true`, so each closes the other's rows; with the drop
  filter on, a box resets `since` for a PR only the other side named, where it
  used to keep its file clock. That delays an owner action, never hastens one.
- **Build notes as a ledger kind** (`bin/lib/build-note-db.sh`):
  ledger kind `build_note`,
  key `"<project> <KEY>"`, status `pending` -> `consumed` or `relayed`.
  `bin/blocked-resolver.sh` (the test-tamper ACCEPT note) and
  `br_ci_replan_note` (`bin/lib/br/opt/cirepair.sh`) still write
  `state/build-notes/<p>/<KEY>.md` and then `bn_put` the row (a failed put is
  one say line: `build note NOT in the DB — only hub/pool builds will see it`).
  The plan stage (`bin/lib/rb/plan.sh`, `# >>> carried note`, the lib sourced
  by `bin/run-build.sh`) reads the pool relay file, then the row (`bn_take`
  claims a `pending` row as `consumed` through the claim route, and only a won
  claim writes the note), then the hub file; pipeline.log names the source
  (`relay`, `db` or `local`). A relay or local consume marks the row
  `consumed`; a hub file whose row another box already used is retired to
  `.relayed-<epoch>` instead. `push_build_note` (`bin/fly-pool.sh`) retires the
  hub file without a push when the row is `consumed`/`relayed`, and marks a
  `pending` row `relayed` after a good push. `br_ci_replan_floor` counts an
  un-suffixed hub `KIND: ci-replan` note whose row is `consumed`. All three
  "already used" reads go through `bn_used`, which also requires the row's
  detail to be THIS file's first 4000 bytes: the row outlives its note, so a
  second note whose put did not land would otherwise be retired on the first
  note's row and reach no build. Known gap:
  with `BR_CI_REPLAN_MAX` above 1, a second re-plan note overwrites the first
  un-suffixed file, so the floor can count one fewer; the default of 1 never
  writes a second note.

## Rollback knobs

| knob | where | 0 means |
|---|---|---|
| `DAILY_DIGEST_CLAIM` | lane `daily-digest` | the read dedupe alone, as before |
| `DAILY_DIGEST_CLAIM_STALE_S` (default 900) | lane `daily-digest` | (120..86400) how old another hub's `sending` must be to take over |
| `PR_OWNERS_ROWS_RECORD` | lane `pr-owner-sweep` | the `file + fresh rows` merge, as before |
| `BUILD_NOTE_DB` | `_lib.build-note-db` | no DB write or read; hub file and pool relay only |

Each is a `lane.*` settings row, so a flip back is a settings write.

## Deploy order

The worker route first. Until it is deployed the claim answers 404: the digest
sends on its read dedupe alone (one note line a tick), the build-note consume
falls back to the relay and the local file, and `bn_mark` does nothing. So the
PR is safe to merge before `harness-sync` deploys the worker.

## Live probes (on the hub, after merge and deploy)

1. `bin/jobs-client.sh ledger-get daily_digest $(date -u -d yesterday +%F)`
   shows `sent` after 07:00Z, and the next morning
   `grep -c 'sent=1' logs/daily-digest.log` grows by one for the day.
2. A bearer `POST /api/ledger/claim` with
   `{"kind":"bh5003_probe","key":"x","status":"probe","terminal":["done"],"stale_s":60}`
   answers `claimed:true`, and the same call again answers `claimed:false`.
3. `grep 'file-only PR(s) dropped\|push_pending' logs/pr-owner-sweep.log` and
   `jq .push_pending state/pr-owners/*.json`.
4. After the next resolver ACCEPT or ci-replan:
   `bin/jobs-client.sh ledger-list build_note 5`.

## Tests

`tests/digest-once.bh-5003-test.sh`, `tests/pr-owner-clock-db.bh-5003-test.sh`,
`tests/build-note-db.bh-5003-test.sh`,
`worker/jobs/test/routes/ledger-claim.bh-5003.test.js`.
