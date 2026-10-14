# Account cooldowns are fleet facts (BH-2355)

Doc: ACCOUNT-ROUTING

This is BH-2319.2. It wires the account cooldown writers and readers to the fleet cooldown seam from BH-2352 (`bin/lib/fleet-cooldown.sh`).

- **Write-through, file first.** `_acct_cooldown_write` in `bin/account-pick.sh` (behind `account_cooldown_stamp` and `account_cooldown_stamp_short`) still writes `state/quota/cooldown/<vendor>/<account>` exactly as before. Then it calls `fcd_put account <vendor> <account> <stamp + ACCOUNT_COOLDOWN_SECS>`. The backdated short stamp therefore lands as a short until. The put also runs when the file write was skipped as not-later. The store keeps the later until, so a replay never shortens a row.
- `pool_account_cooldown` (`bin/lib/pool-account.sh`) puts the reset epoch as the until on its reset branch. On its inline fallback, the one used when no picker is sourced beside it, it puts `now + window`. When the picker is present, the picker's stamp puts the row.
- `orc_account_refuse` (`bin/lib/orc-account.sh`) puts `now + window` after its file write.
- **Read is an OR.** `account_cooling` answers cooling when this box's file is in window (`_acct_cooling_file`, the old body), OR when `fcd_live account <vendor> <account>` returns 0. rc 1 (no row) and rc 2 (unknown) both mean not cooling. Every caller of `account_cooling` picks this up: the picker, the pool lease rank, pool status and the fly-pool reap check. A fleet-only cooldown is never written back into the local file.
- **Clear both sides.** `bin/quota-status.sh --clear-cooldown <vendor> <account>` removes the file, then calls `fcd_clear`. It appends one suffix to the line: `(fleet row cleared)`, `(no fleet row)` or `(fleet not reachable)`. It returns rc 0 when either side existed, rc 1 when neither did, and rc 2 for bad arguments, as before. On a box without the seam lib it prints exactly what it printed before, with no suffix.
- **Status table.** A live fleet row that this box has no local cooldown for prints after the table as ` cooldown: <account> <vendor> to HH:MMZ (fleet, set on <box>)`. That line is not cut to 40 columns. `--json` is unchanged.

Every call is guarded with `command -v`, and every source of the lib is guarded too. A box or scratch tree without the lib keeps today's box-local behaviour.

**What this does on prod today: nothing new.** Nothing in this repo sets `FLEET_COOLDOWN_STORE` (checked 2026-09-25: only the seam, its tests and this note name it). The seam's worker backend is still the BH-2352 stub: `fcd_put` does nothing, `fcd_live` and `fcd_clear` return 2 and `fcd_list` prints nothing. So the picker reads the file alone, as before. The only visible change is the `(fleet not reachable)` suffix on `--clear-cooldown`. Cooldowns start crossing boxes when the worker slice lands. `bin/agent-call.sh` still writes its own stamps box-locally, and a sibling slice converts it.

Pinned by `tests/account-cooldown-fleet.bh-2319-test.sh`. That suite runs two scratch boxes that share one `FLEET_COOLDOWN_STORE`.
