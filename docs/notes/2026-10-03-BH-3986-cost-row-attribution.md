# One auth_account per account, and the served model on every cost row (BH-3986)

Doc: ACCOUNT-ROUTING

## What changed

- `bin/lib/cost-row.sh`: new `cost_row_auth_account <fp_label> <acct_name>
  <label_hint> [pinned]`, the one rule for a cost row's `auth_account`. Order:
  a live fingerprint label, a pinned own account verbatim (BH-1657), `unknown`
  for no account or `default`, the picker's `label=`, the registry file's
  `ACCOUNT_LABEL` (grep only, never sourced, and only for a name that passes the
  picker's name rule), else `acct:<name>`. It sets `COST_ROW_AUTH_ACCOUNT` and
  `COST_ROW_ACCT_FROM` and prints nothing. Also new: `cost_row_model_note
  <served> <requested>`.
- `bin/agent-call.sh`: the routed pick's `label=` line is kept
  (`ACCT_PICK_LABEL`), and `ac_cost_row_write` calls the rule instead of its own
  `acct:$ACCT_NAME` fallback. When the label came from the name, the note gets
  `acct=<name>`. The note ends with `requested_model=<argv model>` whenever the
  row's model differs from it, after the pricer's own token. The three pre-call
  refusals (tripwire, context-kill repeat, call guard) go through
  `ac_refused_row`. That function names the model the primary runner's rung
  would have used (`grok_model`, `codex_model`, `fireworks_model`) and adds
  `;requested_model=` after the `refused:<why>` reason, so the worker's prefix
  match is unchanged. A runner with no route keeps the argv model and still
  carries the note.
- `bin/claude-cost.sh`: same rule, fed `COST_ACCT_NAME` and `ORC_ACCOUNT_LABEL`
  from `bin/lib/orc-account.sh`. Its empty note field now carries `acct=<name>`
  in that case.
- `bin/cost-rows-acct-backfill.sh` (new): a dry-run SQL generator for the
  historic rows. It sends nothing.

## Why

A read-only pull of `cost_rows` for 2026-09-21 → 2026-10-03 (19,028 rows)
showed one account under two names. The hub wrote `acct:max1` (1,386 rows),
`acct:max5` (875), `acct:max3` (408), `acct:max6` (107) and so on. The pool
wrote `max1@example.com` and the other `maxN@example.com` labels for the same
accounts, through its fp overlay. The console's ACCOUNT USAGE table split each
account in two.

It also showed 77 rows with `runner=grok` and `model=claude-opus-5-5`: 54 from
`orgo-desktop`, 23 from `box-project-4-1`. All were `stage=triage`, rc 74,
`refused:call-guard:repeat`, $0, dated 2026-09-26 → 2026-09-28. The refusals
ran before any rung resolved its model and wrote the argv model beside the
grok runner. Rows from grok calls that actually ran already carried `grok-4.x`.
They lacked only the requested model.

## Backfill runbook (human, from the hub)

The build never touches prod D1. An operator runs these steps:

1. Dry run, reading the hub's registry (`<env dir>/accounts.d`):
   `bin/cost-rows-acct-backfill.sh --out /tmp/acct-backfill.sql`
2. Review the file. There is one block per labelled account: a `before_<name>`
   count, one `UPDATE` of `auth_account` and of field 16 inside `raw`, and an
   `after_<name>` count.
3. Apply: `wrangler d1 execute harness-jobs --remote --file=/tmp/acct-backfill.sql`
4. Verify: every `after_<name>` reads 0, and
   `SELECT auth_account, COUNT(*) FROM cost_rows WHERE auth_account LIKE 'acct:%' GROUP BY 1`
   lists only accounts that have no `ACCOUNT_LABEL`. A second apply changes 0
   rows.

`raw` is rewritten too because `cost_rows_fetch` re-emits it verbatim, so the
rollup, cost-report and reconcile would keep reading `acct:<name>`. The box
mirror's re-push conflicts on `(box,row_hash)` and only fills NULL
`lane_id`/`guard_fp`, so it does not undo the rewrite. One known side effect: a
rewritten row's `raw` no longer hashes to its `row_hash`, so
`bin/cost-rows-lane-backfill.sh` skips it. That is harmless, because those rows
already have `lane_id`.

Until the backfill runs, rows written before the deploy stay split. Boxes'
local `logs/cost.csv` history is not rewritten.

## Follow-ups, not done here

- The 77 historic refusal rows keep `model=claude-opus-5-5`. They are $0 and
  `row_source=refused`.
- `catalog/cost-accounts.json` `auth_accounts` does not list the max1..7
  labels. That is a reconcile-map change.
