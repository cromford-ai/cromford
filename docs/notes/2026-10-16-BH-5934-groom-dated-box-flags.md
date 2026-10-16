# alerts-groom removes the dated box flag families (BH-5934, slice C0)

Doc: ALERTS-GROOMING-SPEC

## Why

Three flag families in `flags/` had no retention rule:

- `degraded-<box>-YYYYMMDD` (`bin/claude-auth-check.sh`, `degraded_note`)
- `authprobe-inconclusive-<box>-YYYYMMDD` (`bin/claude-auth-check.sh`, `inconclusive_note`)
- `lane-caps-degraded-<lane>-YYYYMMDD-<cksum>` (`bin/lib/lane-caps.sh`, `_lc_log`)

Each writer checks only TODAY's name. An old file dedupes nothing. Nothing
deleted them, so they grew without a bound. `lane-caps-degraded` writes one
file per lane per distinct message per day.

## What changed

`groom_alert_flags` in `bin/alerts-groom.sh` has a second loop after the
BH-1954 `alerted-*` loop. It uses the same knob (`ALERT_FLAG_RETENTION_DAYS`,
settings row `lane.alerts-groom.alert_flag_retention_days`, fallback 7), the
same cutoff and the same safety rules:

- Only a regular file that is not a symlink is removed.
- The date comes from the NAME, never the mtime. It must be exactly 8 digits
  and strictly before the cutoff.
- `degraded-` and `authprobe-inconclusive-`: the date is the last segment.
- `lane-caps-degraded-`: the last segment must be all digits (the cksum). The
  date is the segment before it. The writer name does not change.
- A knob below 2 or not a whole number deletes nothing in either family.

The loop writes one new line to `logs/alerts-groom.log`:
`flag groom: removed <m> dated box flag(s) (degraded-, authprobe-inconclusive-, lane-caps-degraded-) dated before <cutoff> (retention <d>d)`.
The BH-1954 `alerted-*` line does not change.

Test: `tests/alerts-groom-box-flags.bh-5934-test.sh`.

## Items 2 and 3 wait for BH-4154 C2 and C4

On main the latch families are files with the full name, and the box
`*-disabled` switches are files that `bin/fleet-status-push.sh` already pushes
in the fleet pause list. The shortened latch name (item 2) and the box-switch
rows in the console (item 3) exist only after BH-4154 C2 (latches to rows) and
C4 (kill switches to rows). Those slices own the fix. When C2 ports these three
families to rows, its row prune must cover them with the same rule.

## Post-deploy probe

On the hub, before and after the next `alerts-groom` tick:

```bash
ls /root/harness/flags | grep -cE '^(degraded|authprobe-inconclusive|lane-caps-degraded)-'
grep 'dated box flag' /root/harness/logs/alerts-groom.log | tail -1
```
