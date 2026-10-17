#!/bin/bash
# tests/pool-machine-hours-budget.bh-7190-test.sh — bin/pool-budget.sh, the
# per-project daily machine-hour budget (BH-7190).
#
# "Uncapped" is bounded by money, not by a slot count. The budget is a settings
# row `lane.fly-pool.<project>.pool_machine_hours_daily`. The guard ALERTS at
# POOL_BUDGET_ALERT_PCT (80) and again at 100. It never stops, pauses or caps
# anything (the operator: tripwires alert only), and this suite pins that: no flag, no
# queue row and no settings row changes.
#
# Fixed clock: NOW = 2026-10-16T12:00:00Z, so the UTC day started at 00:00:00Z.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/state" "$H/catalog"
scratch_install_closure bin/pool-budget.sh "$H" >/dev/null
scratch_install_closure bin/fleet-conf.sh "$H" >/dev/null
# flag-on stand-in: production reads the fly-pool flag through bin/lib/flag-on.sh
# (worker row first). This suite tests the budget, not the flag reader, so the
# fixture answers from its flags/ files (flag-callsites-pool.bh-5635 owns the reader).
printf 'flag_on() { [ -f "$HARNESS/flags/$1-$2" ]; }\n' > "$H/bin/lib/flag-on.sh"
cp "$DIR/catalog/fly-prices.json" "$H/catalog/fly-prices.json"
printf 'project-6-os example-org/project-6 - - 1 local\ncromford example-org/cromford - - 3 local\nidle-os example-org/idle - - 5 local\n' > "$H/fleet.conf"
: > "$H/flags/fly-pool-project-6-os"; : > "$H/flags/fly-pool-cromford"; : > "$H/flags/fly-pool-idle-os"

# jobs-client stand-in. setting-get reads $H/rows.tsv (rc 2 = no row);
# machines-list <project> prints $H/machines-<project>.tsv; DOWN=1 is an outage.
cat > "$H/bin/jobs-client.sh" <<'JC'
#!/bin/bash
[ -f "$HARNESS/DOWN" ] && exit 1
case "${1:-}" in
  setting-get) v=$(awk -F'\t' -v k="$2" '$1==k{print $2; f=1} END{exit !f}' "$HARNESS/rows.tsv" 2>/dev/null) || exit 2; printf '%s\n' "$v" ;;
  machines-list) cat "$HARNESS/machines-$2.tsv" 2>/dev/null ;;
  *) exit 1 ;;
esac
JC
# alert-line stand-in: one line per call, "<id>|<severity>|<project>|<text>".
cat > "$H/bin/alert-line.sh" <<'AL'
#!/bin/bash
SEV=""; AID=""; PROJ=""
while [ $# -gt 0 ]; do case "$1" in --severity) SEV="$2"; shift 2 ;; --id) AID="$2"; shift 2 ;; --project) PROJ="$2"; shift 2 ;; *) break ;; esac; done
printf '%s|%s|%s|%s\n' "$AID" "$SEV" "$PROJ" "$*" >> "$HARNESS/alerts.out"
AL
chmod +x "$H/bin/jobs-client.sh" "$H/bin/alert-line.sh"

NOW=$(date -u -d '2026-10-16T12:00:00Z' +%s 2>/dev/null || python3 -c 'import calendar,time;print(calendar.timegm(time.strptime("2026-10-16T12:00:00Z","%Y-%m-%dT%H:%M:%SZ")))')
DAY=2026-10-16

# row <id> <project> <state> <spawned_at> <last_seen>  (machines-list column order)
row() { printf '%s\t%s\tpool-%s\tpool\t\t\t%s\t%s\t%s\n' "$1" "$2" "$2" "$3" "$4" "$5"; }
run_budget() { # run_budget [args...] — one pass at the fixed clock
  ( export HARNESS="$H" FLEET_CONF="$H/fleet.conf" POOL_BUDGET_NOW="$NOW"; bash "$H/bin/pool-budget.sh" "$@" ) 2>&1
}
fresh() { scratch_rm "$H/alerts.out"; scratch_rm "$H/state/pool-budget"; scratch_rm "$H/DOWN"; : > "$H/logs/fly-pool.log"; }
alerts() { cat "$H/alerts.out" 2>/dev/null; }
count() { alerts | grep -c "$1"; }

# Machine-hours in the day: closed 3h (08:00-11:00) + live since 10:00 (2h) = 5h.
# A row spawned yesterday 23:00, gone 01:00 counts only the 1h inside today.
set_machines() { # set_machines <project> <rows...>
  local p="$1"; shift; printf '%s\n' "$@" > "$H/machines-$p.tsv"
}
M_MIX=( "$(row a project-6-os destroyed 2026-10-16T08:00:00Z 2026-10-16T11:00:00Z)"
        "$(row b project-6-os started   2026-10-16T10:00:00Z 2026-10-16T11:59:00Z)"
        "$(row c project-6-os gone      2026-10-15T23:00:00Z 2026-10-16T01:00:00Z)" )
# = 3 + 2 + 1 = 6.0 machine-hours

# ── a: no budget row -> silent, nothing alerted ──────────────────────────────
fresh; printf '' > "$H/rows.tsv"; set_machines project-6-os "${M_MIX[@]}"
run_budget --project project-6-os >/dev/null
[ -z "$(alerts)" ] && ok || bad "a: alert written with no budget row"

# ── b: under 80% -> a log line with the numbers, no alert ────────────────────
fresh; printf 'lane.fly-pool.project-6-os.pool_machine_hours_daily\t10\n' > "$H/rows.tsv"
run_budget --project project-6-os >/dev/null
[ -z "$(alerts)" ] && ok || bad "b: alert at 60% of budget: $(alerts)"
grep -q 'project-6-os.*6\.0.*of 10' "$H/logs/fly-pool.log" && ok || bad "b: no usage line (6.0 of 10) in fly-pool.log: $(cat "$H/logs/fly-pool.log")"

# ── c: 80% -> one alert, a second pass the same day adds none ────────────────
fresh; printf 'lane.fly-pool.project-6-os.pool_machine_hours_daily\t7\n' > "$H/rows.tsv"
run_budget --project project-6-os >/dev/null; run_budget --project project-6-os >/dev/null
[ "$(count 'pool-budget-warn-project-6-os')" = 1 ] && ok || bad "c: want exactly 1 80% alert over two passes, got $(count 'pool-budget-warn-project-6-os')"
[ "$(count 'pool-budget-limit')" = 0 ] && ok || bad "c: a 100% alert at 86%"
alerts | grep -q 'project-6-os|warn|project-6-os|' && ok || bad "c: id/severity/project wrong: $(alerts)"
alerts | grep -q 'no machine was stopped' && ok || bad "c: alert text must say nothing was stopped"
alerts | grep -q '\$' && ok || bad "c: alert text must carry the dollar estimate"

# ── d: 100% -> a second, separate alert ──────────────────────────────────────
printf 'lane.fly-pool.project-6-os.pool_machine_hours_daily\t5\n' > "$H/rows.tsv"
run_budget --project project-6-os >/dev/null
[ "$(count 'pool-budget-limit-project-6-os')" = 1 ] && ok || bad "d: want 1 100% alert, got $(count 'pool-budget-limit-project-6-os')"

# ── e: alert only — flags, queue and settings are untouched ─────────────────
before=$(cd "$H" && ls flags; cat rows.tsv)
run_budget --project project-6-os >/dev/null
after=$(cd "$H" && ls flags; cat rows.tsv)
[ "$before" = "$after" ] && ok || bad "e: the guard changed flags or settings"
[ -f "$H/flags/fly-pool-project-6-os" ] && ok || bad "e: pool enable flag was removed"
grep -Eq 'setting-set|rule-set|cap-explicit|flag-set|flag-clear|pause|\bkill\b|machine (stop|destroy)' "$DIR/bin/pool-budget.sh" \
  && bad "e: bin/pool-budget.sh names a stop/cap/destroy action" || ok

# ── f: the day rolls over: yesterday's closed hours do not count today ───────
fresh; printf 'lane.fly-pool.project-6-os.pool_machine_hours_daily\t3\n' > "$H/rows.tsv"
set_machines project-6-os "$(row a project-6-os destroyed 2026-10-16T08:00:00Z 2026-10-16T11:00:00Z)"
run_budget --project project-6-os >/dev/null
( export HARNESS="$H" FLEET_CONF="$H/fleet.conf" POOL_BUDGET_NOW=$((NOW + 86400)); bash "$H/bin/pool-budget.sh" --project project-6-os >/dev/null 2>&1 )
# next day starts empty: 0 hours, so no second-day alert; the marker is per day
[ "$(count 'pool-budget-limit-project-6-os')" = 1 ] && ok || bad "f: want 1 alert (day 2 has no usage)"
ls "$H/state/pool-budget" | grep -q "$DAY" && ok || bad "f: marker not keyed by day: $(ls "$H/state/pool-budget")"

# ── g: a live row with no spawned_at is reported, never guessed ──────────────
fresh; printf 'lane.fly-pool.project-6-os.pool_machine_hours_daily\t100\n' > "$H/rows.tsv"
set_machines project-6-os "$(row z project-6-os started '' 2026-10-16T11:59:00Z)" "$(row a project-6-os destroyed 2026-10-16T08:00:00Z 2026-10-16T11:00:00Z)"
run_budget --project project-6-os >/dev/null
grep -q '1 live.*no spawn time\|1 not counted' "$H/logs/fly-pool.log" && ok || bad "g: unknown row not named in the log: $(cat "$H/logs/fly-pool.log")"
grep -q '3\.0.*of 100' "$H/logs/fly-pool.log" && ok || bad "g: the 3.0 known hours are wrong: $(cat "$H/logs/fly-pool.log")"

# ── h: an outage is not a quiet day and not an alert ─────────────────────────
fresh; printf 'lane.fly-pool.project-6-os.pool_machine_hours_daily\t5\n' > "$H/rows.tsv"; : > "$H/DOWN"
out=$(run_budget --project project-6-os); rc=$?
[ "$rc" = 0 ] && ok || bad "h: outage must exit 0, got $rc"
[ -z "$(alerts)" ] && ok || bad "h: alert during an outage"
grep -qi 'unreadable\|unreachable\|outage' <<<"$out$(cat "$H/logs/fly-pool.log")" && ok || bad "h: outage not logged"

# ── i: all pool projects in one pass; a project without a row is skipped ─────
fresh; printf 'lane.fly-pool.project-6-os.pool_machine_hours_daily\t5\nlane.fly-pool.cromford.pool_machine_hours_daily\t2\n' > "$H/rows.tsv"
set_machines project-6-os "${M_MIX[@]}"
set_machines cromford "$(row h cromford destroyed 2026-10-16T01:00:00Z 2026-10-16T05:00:00Z)"
run_budget >/dev/null
[ "$(count 'pool-budget-limit-project-6-os')" = 1 ] && [ "$(count 'pool-budget-limit-cromford')" = 1 ] && ok \
  || bad "i: want one 100% alert per project: $(alerts)"
[ "$(count 'idle-os')" = 0 ] && ok || bad "i: idle-os has no row and must be silent"

# ── j: the knob registry names the new rows, with the bounds the guard uses ──
for k in POOL_MACHINE_HOURS_DAILY POOL_BUDGET_ALERT_PCT; do
  [ -f "$DIR/catalog/lanes.d/fly-pool.knobs.d/$k.json" ] && ok || bad "j: no knob file for $k"
done
printf 'lane.fly-pool.project-6-os.pool_machine_hours_daily\t7\nlane.fly-pool.pool_budget_alert_pct\t95\n' > "$H/rows.tsv"; fresh2() { scratch_rm "$H/alerts.out"; scratch_rm "$H/state/pool-budget"; }
fresh2; set_machines project-6-os "${M_MIX[@]}"
run_budget --project project-6-os >/dev/null
[ -z "$(alerts)" ] && ok || bad "j: 86% must not alert when the threshold row is 95: $(alerts)"

echo "pool-machine-hours-budget: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
