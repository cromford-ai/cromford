# Two more literals become settings knobs: the lane-alert DM chat and the state-backup switch

Doc: OPERATOR-SETUP, ALERTS-STATE-MACHINE

## What changed

BH-1938 is one BH-1511.1 slice. It converts two `${VAR:-literal}` defaults
into required registry knobs. Each value now resolves row > cached row > env >
registry default > fail closed (`bin/lib/lane-gate.sh`). The registry default
is the old literal, so a box with no row behaves exactly as before.

| Var | Script | Registry | Settings key |
|---|---|---|---|
| `LANE_ALERT_DM_CHAT` | `bin/lane-alert.sh` | new `catalog/lanes.d/_lib.lane-alert.json` (lib `lane-alert`, string, default `"100000000"`) | `lib.lane-alert.lane_alert_dm_chat` |
| `STATE_BACKUP` | `bin/state-backup.sh` | `catalog/lanes.d/state-backup.json` (int 0..1, default 1, `zero_means: off`) | `lane.state-backup.state_backup` |

Both are `required: true, settable: true`, so `seed-registry` seeds them.

- **lane-alert.sh** resolves the chat only on the `--critical` path with the
  monitor off and a bot token present. It calls `lib_env_apply lane-alert` in a
  subshell, so the gate's exit 75 can't fail the caller, and the script still
  always exits 0. If no chat resolves, no DM is sent and exactly one ALERTS
  line says why. That line comes from the gate itself on a 75, from
  `_lg_alert_once lib-lane-alert-unresolved` when the gate loaded but the
  registry was unreadable, or directly when lane-gate.sh couldn't be loaded.
  The alert's own ALERTS line and beat are unchanged.
- **state-backup.sh** tests `${STATE_BACKUP:-} = 0`. The lane already ran
  `lane_env_apply state-backup` twice, and the second call keeps a row ahead of
  `env/global.env`. Without lane-gate (CI), empty is not 0, so the backup runs
  as it did before.

The chat id is a string because Telegram group ids are negative (`-100…`), and
a string knob is never clamped.

## Not converted, and why

| Var | Where | Decision |
|---|---|---|
| `ACCOUNT_VENDORS` | `bin/quota-status.sh:65` | Code constant. Its owner `bin/account-pick.sh` assigns it outright and quota-status.sh sources that first, so a settings row would be overwritten and do nothing. The literal in quota-status.sh is the half-synced-box guard its comment describes. |
| `ALERT_WARN_BATCH` | `bin/lib/alert-state.sh` | A box-layout path with a computed `${A:-$B}` default. Left alone. |
| `BACKUP_STALE_MIN` | `bin/lib/backup-freshness.sh` | No literal (an emptiness test), and already DB-first through `setting_get backup_stale_min`. |
| `WAKE_BACKSTOP_S` | `bin/lib/wake-lanes.sh` | Already converted by #1547 (lib `wake-lanes`). |

## Known gap

`bin/lib/backup-freshness.sh` decides "this box is deliberately off" from
`STATE_BACKUP=0` in env/global.env or `flags/state-backup-off`. It doesn't read
the settings row. A box switched off only by a row 0 therefore shows as stale on
the freshness page and pages. That's loud, not silent, and it matches what
`harness-ctl off state-backup` does today. Teaching freshness to read the row
is out of this slice.

## Acceptance grep deviation

The ticket's check (`config-literal-lint.sh | grep` over the six files prints
nothing) still prints ten lines on this base. All ten are knobs BH-1165 already
registered (`MODEL_COOLDOWN_SECS`, `HUB_BOX_NAME`, and eight state-backup
`BACKUP_*`/path knobs), none of them a slice var. They belong to the final
lint-to-0 slice. Removing them here would break `tests/state-backup.bh-447-test.sh`
and `tests/backup-freshness-test.sh` on CI, where lane-gate is absent.
`tests/config-slice-small.bh-1938-test.sh` P3 pins that none of the six slice
vars appears and that nothing new was added beyond those ten.

Tests: `tests/config-slice-small.bh-1938-test.sh` (P1-P6, L1-L6, S1-S6).
`tests/lane-alert-test.sh` now renders the registry, because the DM default
lives there.
