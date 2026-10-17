#!/bin/bash
# bin/pool-never-wait-seed.sh — write the "never wait" settings rows for the
# project-6-os and cromford Fly pools (BH-7190). Dry run by default.
#
#   bin/pool-never-wait-seed.sh            print PLAN lines, write nothing
#   bin/pool-never-wait-seed.sh --apply    write the rows that differ
#
# One row per line below: <settings key><TAB><value><TAB><why>. Every key is the
# lane-knob form lane.<lane>[.<project>].<knob>, so the console and
# bin/lib/lane-gate.sh read the same row. Re-running changes nothing once the
# rows match (SAME). A value is never clamped here: the knob registry bounds
# (catalog/lanes.d/fly-pool.knobs.d, fly-pool.json) are pinned by
# tests/pool-never-wait-seed.bh-7190-test.sh, so a row that the lane would clamp
# cannot be added.
#
# WHY THESE VALUES: docs/FLY-POOL.md, section "Knobs that can hold a build".
# The two defer-max rows are fleet-wide on purpose: bin/jobs-watchdog.sh reads
# its own copy of the knob and does not know the project, so a per-project value
# in one lane would disagree with the other.
#
# Needs the hub (the settings API). Exit 0 done, 1 a write failed, 2 usage.
set -uo pipefail
H="${HARNESS:-/root/harness}"
JC="$H/bin/jobs-client.sh"
APPLY=0
case "${1:-}" in
  "") ;;
  --apply) APPLY=1 ;;
  *) echo "usage: pool-never-wait-seed.sh [--apply]" >&2; exit 2 ;;
esac

rows() {
  local p
  for p in project-6-os cromford; do
    printf 'lane.fly-pool.%s.pool_cap\t0\texplicit no per-project ceiling; beats any fly/pool-caps.conf line\n' "$p"
    printf 'lane.fly-pool.%s.pool_spawn_cap_per_key\t24\ta rebuild after a fix is the 3rd to 24th spawn of a key in a day, never a wait\n' "$p"
  done
  printf 'lane.fly-pool.project-6-os.pool_machine_hours_daily\t300\talert at 80%%; about 2x the busiest recent day (164 machine-hours on 2026-10-15)\n'
  printf 'lane.fly-pool.cromford.pool_machine_hours_daily\t700\talert at 80%%; above the busiest recent day (638 machine-hours on 2026-10-14)\n'
  printf 'lane.fly-pool.pool_budget_alert_pct\t80\tthe first budget alert of a UTC day\n'
  printf 'lane.fly-pool.jobs_queue_defer_max\t12\tstand-downs before a row parks for the blocked-resolver (pool side)\n'
  printf 'lane.jobs-watchdog.jobs_queue_defer_max\t12\tthe same cap on the watchdog side; the two must agree\n'
}

rc=0
while IFS=$'\t' read -r key val why; do
  [ "${#key}" -le 64 ] || { echo "REFUSED $key: longer than 64 characters" >&2; rc=1; continue; }
  cur=$("$JC" setting-get "$key" 2>/dev/null) || cur=""
  cur=$(printf '%s' "$cur" | tr -d '[:space:]')
  if [ "$cur" = "$val" ]; then printf 'SAME %s = %s\n' "$key" "$val"; continue; fi
  if [ "$APPLY" = 0 ]; then printf 'PLAN %s %s -> %s  (%s)\n' "$key" "${cur:-unset}" "$val" "$why"; continue; fi
  if "$JC" setting-set "$key" "$val" "BH-7190 never-wait: $why" >/dev/null 2>&1; then
    printf 'SET %s %s -> %s\n' "$key" "${cur:-unset}" "$val"
  else
    printf 'FAILED %s\n' "$key" >&2; rc=1
  fi
done < <(rows)
exit "$rc"
