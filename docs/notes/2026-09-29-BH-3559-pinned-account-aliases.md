# Pinned project accounts resolve on their owning boxes, and say so when they don't (BH-3559)

Doc: ACCOUNT-ROUTING

## What happened

On 2026-09-28 13:25Z the `account.<project>` rows pinned project-4, project-3 and project-2 to
`own:project-4` / `own:project-3` / `own:project-2`. The token files for those labels existed
only on the hub. On each owning box the live project token's fp was labelled
`claude:<x>-dedicated` in `state/auth-accounts.local.json`, so agent-call's
live-fp check (exact label match) never matched either. Every claude call for
those projects on their own boxes was refused rc 76 for about 32 hours, and the
only record was a line in `failovers.log` and `account-routing.log`.

## What changed

- **Aliases, not a secret sync.** `catalog/account-aliases.json` maps a pin label
  to the labels that name the same account (`own:project-3` -> `claude:project-3-dedicated`,
  and the same for project-4 and project-2). It holds labels only and reaches every box with
  the rest of `catalog/`. `project_account_live_matches` in
  `bin/lib/project-account.sh` accepts the live token when its fp label is the pin
  or an alias. `unknown` never matches, and an absent or malformed alias file gives
  the old exact match. The other option in the ticket (shipping
  `accounts.d/<label>.env` to the owning box) would have been a new path that
  distributes secrets, which the harness does not have today.
- **One alert per refusal window.** A `pinned_unavailable` refusal calls
  `project_account_alert_unavailable`: one warn `lane-alert.sh` with id
  `account-pin-<box>-<project>`, naming the box and label, at most once per
  `ACCOUNT_PIN_ALERT_WINDOW_S` (default 21600 s, settings row
  `lib.project-account.account_pin_alert_window_s`). It is stamped in
  `state/account-pin/<project>.alerted` under a `flock -n`, and the stamp is
  removed if the send fails. The first pinned call that works resolves it.
- **The pin checks its own work.** `bin/account-pin-probe.sh [--alert] <project>...`
  prints `unpinned`, `ok file`, `ok live` or `UNRESOLVABLE` per project, loading
  `global.env` then `<project>.env` as a build does. It never prints a token or
  calls a model. `bin/claude-auth-check.sh` (hourly, hub) runs it for every pinned
  project on the hub and, over ssh, once per owning box. An ssh failure or a box
  without the script (rc 127) writes `could-not-probe` to
  `logs/account-pin-probe.log` and raises no alert.

## Checking it

On an owning box: `/root/harness/bin/account-pin-probe.sh project-4 project-3 project-2`.
On the hub: `tail logs/account-pin-probe.log`, `grep account-pin logs/ALERTS.log`.
