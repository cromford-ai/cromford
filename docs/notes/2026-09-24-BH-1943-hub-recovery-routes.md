# Hub recovery read and guarded promote are live (BH-1943)

Doc: HUB-RECOVERY-MCP

## What changed

- `GET /api/hub/recovery` and `POST /api/hub/promote` in
  `worker/jobs/src/routes/hub-recovery.js` no longer answer 501. The four
  restore-lab routes still do (#1944).
- The GET reads `hub_lease`, `box_status`, `settings.backup_stale_min` and
  `hub_lease_changes`. The backup `state` follows `bf_state_age` in
  `bin/lib/backup-freshness.sh`: off, ok/stale by age, unknown for an
  unparseable stamp, unconfigured, missing. `age_min` is `null` unless there is
  a real stamp. A future stamp reads `ok` with age 0 (clock skew).
- The promote is confirm-gated and epoch-fenced. Every refusal except a missing
  `actor` writes one `promote_refused` row. On success the `UPDATE ... WHERE
  epoch=?` and the `promote` audit row go in one `env.DB.batch`. The audit row
  is an `INSERT ... SELECT ... FROM hub_lease WHERE <the state the UPDATE
  wrote>`, so a CAS that changed nothing leaves no `ok` row. A plain
  `auditStmt` in that batch would have recorded a promote that never happened,
  because a D1 batch rolls back only on a thrown error.

## Split-brain guard (BH-2198, after merge)

#2158 merged this route without the guard the lead's review required. #2198
adds it:

- **Stop the old hub first.** The human step before any promote is to stop the
  old hub (stop its cron, or power it off) or cut its lane gate.
  `bin/hub-lease.sh` fails open on the configured hub while the worker is
  unreachable (BH-1000), so an isolated old hub keeps acting after the epoch
  bump. Every 200 repeats the step in `stop_old_hub`.
- `settings.hub.promote_enabled`, seeded `'0'`, is checked right after the
  actor. Off is `403 promote-disabled` with one `refused:promote-disabled` row.
- A live lease is `409 lease_live` with no write at all, unless the body says
  `override_live_lease: true`; that promote's audit outcome is
  `ok:override_live_lease`. The UPDATE is fenced on the lease still being
  expired, so a holder that renews mid-request keeps its lease.
- The actor is stamped by the console proxy (#2204).

## Contract vs issue

The issue body and the BH-1942 contract disagreed. The contract won where they
conflicted, and the issue's extra fields were added on top:

- Body: `target` / `expected_epoch` (the contract). `holder` / `expect_epoch`
  (the issue) are accepted as aliases.
- Unknown box: 400 `unknown_box`. Stale epoch: 409 `stale_epoch`.
- Success: `{ok, before, after}` plus `{lease, promoted, audit_id, as_of}`.
- `role.standby` is `[]` plus a `standby_note`, not `null`.
- A missing `actor` is 400 `actor_required` with no audit row, because
  `hub_lease_changes.actor` is NOT NULL and nothing invents one.

`POST /api/hub/lease/promote` and `bin/hub-lease.sh` are unchanged.
Since BH-2272 (#2281) the legacy route answers 410
`{error:"gone", use:"/api/hub/promote"}`, and `bin/hub-lease.sh promote` goes
through `POST /api/hub/promote`.

## Apply

The routes read `hub_lease_changes`. Until `bin/harness-sync.sh` has applied
that table from `worker/jobs/schema.sql`, both answer 503
`hub_lease schema not applied`, never a 200.

## Verification after review

The harness run of the impact gate went red on one case,
`tests/registry-no-commit-test.sh` RN-9 (rendered hub crontab missing the
hub-lease gate). This diff touches nothing under `cron/`, `bin/` or
`catalog/`, so it cannot reach that render. I re-ran it on this head:

- `tests/registry-no-commit-test.sh`: 52 passed, 0 failed, five runs in a row,
  and again inside the gate.
- `bin/test-impact-gate.sh --base origin/main`: ran 30 of 77 selected suites,
  all passed; 47 left by the budget.
- Those 47 run by hand (`HARNESS_TEST_SANDBOX=1 bash <suite>`): 47 passed.
- `worker/jobs` `npm test`: 773 passed, 0 failed. The repo has no
  `npm run build` script; `node --check src/routes/hub-recovery.js` is clean.

So RN-9 looks like the same one-off red on a shared runner that BH-1554 already
recorded. It was not reproduced here.
