# BH-2359 (BH-2319.4): lane-down writers stamp fleet rows, reprobe reseeds from them

Doc: SCHEDULER, ALERT-REMEDIATION

## What changed

- `bin/lib/lane-down.sh` sources `bin/lib/fleet-cooldown.sh` when it is beside it (functions only, and a
  missing file changes nothing).
  - `ld_mark` puts `lane <lane> <box>` with until = now + `LANE_DOWN_TTL_S` (default 7200; non-numeric or 0
    falls back), the record's since, and the flattened last error. The put runs before the local write, and
    every mark refreshes the until. `ld_mark` takes an optional 6th arg, a since hint, used only when the
    record has no since.
  - `ld_clear` runs `fcd_clear lane <lane> <box>` before it removes the STATE line, flag and record. rc 0
    (removed) and rc 1 (no row) are silent. Any other rc appends one line to `logs/agent-rules.log`
    (`[lane-down] fcd_clear lane <lane> <box> rc <n>; local state removed, row expires by TTL`), and the local
    removal goes ahead anyway.
- `bin/claude-auth-check.sh`: the claude box loop puts `lane claude <box>` on every down pass. That's every
  hour while the outage stands, so the TTL can't lapse under it, and the contract keeps the first since. The
  row is cleared where the `<box>` STATE line is removed (ok probe, and `degraded_note`). The project-1-lane
  block writes no row, because it's an account and not a box.
- `bin/lane-reprobe.sh`: `seed_fleet` runs after `seed` on each tick. Each live `fcd_list lane` row for a
  runner lane (`codex|openrouter|fireworks|grok`) whose `state/lane-down/<box>-<lane>` record is absent becomes
  a record carrying the row's since, plus a STATE line and today's flag, and logs
  `seeded <ID> from fleet row`. Claude rows aren't seeded, because the hourly canary re-derives those. Like
  the STATE seed, the new record is stamped `last_probe=now`, so its first probe is `LANE_REPROBE_FAST_S`
  later, not in the same tick.
- `LANE_DOWN_TTL_S` is a settings knob on the `lane-reprobe` and `claude-auth-check` lanes.

## Why

Lane-down state lived only on the hub. A hub rebuild lost every outage and its since, and no build box
could see one. The fleet row is the shared copy, and the hub records stay its working copy.

## Today, before the worker slice

With `FLEET_COOLDOWN_STORE` unset, the contract's backend is the worker stub: put is a no-op, clear is
rc 2, and list is empty. So on a box this writes nothing to the fleet yet. Each lane recovery logs one
`fcd_clear ... rc 2` line to `logs/agent-rules.log` until the worker backend lands.

## Unchanged

The hub-local readers (`bin/lib/mc/locks.sh`, `bin/lib/mc/classify.sh`, `bin/fleet-status-push.sh`), the
record format and the STATE lines.

Test: `tests/lane-down-fleet.bh-2359-test.sh`.
