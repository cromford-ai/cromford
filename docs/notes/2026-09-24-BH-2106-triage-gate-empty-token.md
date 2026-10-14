# triage-gate alerts when a board token or base resolves to an empty value

Doc: BOARD-API-CONTRACT

## What changed

- **`bin/triage-gate.sh`, generic in-app arm.** When `board_token_var` and
  `board_base_var` both resolve to one name but the token (or the base) value
  is empty (`X_INTERNAL_API_TOKEN=`, `=""`, `=''`, `export X_…=`), the gate now
  writes one ALERTS line through `_bc_alert` in `bin/lib/board-creds.sh`:
  `[internal-token] <p>: <envfile> sets <NAME> to an empty value (triage-gate)`.
  It uses the same `flags/alerted-token-<project>-<YYYYMMDD>` flag as the
  no-match and duplicate refusals, so a project gets at most one line a day.
  Stdout and rc are the same as before: `SKIP token-unresolved`,
  `BLOCKED token-unresolved` under `--buildable`, rc 1 under `--pending`, and
  no board call.

## Why

Before this, the empty-value case printed `SKIP token-unresolved` and wrote
nothing to ALERTS.log, so triage for that project stopped with no signal. The
file header already said this case alerts. Now the code does too.

## Test

`tests/triage-gate-empty-token.bh-2106-test.sh` drives the real gate.
