#!/bin/bash
# bin/pool-budget.sh — per-project DAILY MACHINE-HOUR BUDGET for the Fly pool (BH-7190).
#
# WHY. The pool has no slot cap (bin/pool-cap.sh prints 0 = unlimited, the operator
# 2026-09-14). "Uncapped" must still be bounded by money, not by a slot count.
# This guard reads one settings row per project and ALERTS when the project's
# machines have run for that many machine-hours in the current UTC day.
#
# IT ALERTS. IT DOES NOTHING ELSE (the operator: tripwires alert only). No machine is
# stopped, no queue row is held, no cap or flag is written. The only files it
# writes are a log line, an alert line and a once-a-day marker.
#
# THE ROWS
#   lane.fly-pool.<project>.pool_machine_hours_daily   machine-hours per UTC day.
#       No row, 0 or a non-number: no budget, this project is skipped.
#   lane.fly-pool.pool_budget_alert_pct                 default 80, range 1..100.
#
# THE LEVELS (one alert each per project per UTC day, markers in state/pool-budget/)
#   warn   used >= alert_pct of the budget   --id pool-budget-warn-<project>
#   limit  used >= 100% of the budget        --id pool-budget-limit-<project>
#
# THE NUMBER. Machine-hours = sum over this project's machine rows of the time
# each machine ran inside [00:00 UTC today, now]. A terminal row (destroyed,
# gone) runs spawned_at..last_seen. A live row runs spawned_at..now. A live row
# with no spawned_at cannot be timed: it is counted in the log line as "not
# counted", never guessed. The listing holds the 500 newest rows; a project
# with 500 rows inside today is marked "listing full" (the figure is a floor).
#
# THE PRICE in the alert is the pool machine size from catalog/fly-prices.json:
# POOL_BUDGET_VM_CPUS x POOL_BUDGET_VM_MEM_MB (defaults 8 and 16384, the
# `machine run` size in bin/fly-pool.sh).
#
# OUTAGE. A settings or listing read that fails is logged and skipped. It is not
# a quiet day and it raises no alert. The exit code is always 0.
#
# Usage: bin/pool-budget.sh [--project <p>]     (no flag: every project with flags/fly-pool-<p>)
# Called by bin/fly-pool-tick.sh once per tick. POOL_BUDGET_NOW is a test seam (epoch seconds).
set -uo pipefail
H="${HARNESS:-/root/harness}"
NOW="${POOL_BUDGET_NOW:-$(date -u +%s)}"
DAY=$(date -u -d "@$NOW" +%F 2>/dev/null || python3 -c "import time,sys;print(time.strftime('%F',time.gmtime(int(sys.argv[1]))))" "$NOW")
LOG="$H/logs/fly-pool.log"
MK="$H/state/pool-budget"
JC="$H/bin/jobs-client.sh"
# shellcheck source=bin/lib/fly-cost-row.sh
. "$H/bin/lib/fly-cost-row.sh" 2>/dev/null || true
# shellcheck source=bin/lib/flag-on.sh
. "$H/bin/lib/flag-on.sh" 2>/dev/null || flag_on() { [ -f "$H/flags/$1-$2" ]; }

say() { mkdir -p "$H/logs" 2>/dev/null; printf '%s [pool-budget/%s] %s\n' "$(date -u '+%F %TZ')" "$1" "$2" >> "$LOG"; }

# row_get <key> — prints the value; rc 0 found, 2 no row, 3 unreadable.
row_get() {
  local v rc
  [ -x "$JC" ] || return 3
  v=$("$JC" setting-get "$1" 2>/dev/null); rc=$?
  case "$rc" in 0) ;; 2) return 2 ;; *) return 3 ;; esac
  printf '%s' "$v" | tr -d '[:space:]'
}

# knob_key <project> <knob> — the lane-knob settings key, rc 1 when it is not a legal key.
# The two knobs read through it are registered as POOL_MACHINE_HOURS_DAILY (per project)
# and POOL_BUDGET_ALERT_PCT (fleet-wide) in catalog/lanes.d/fly-pool.knobs.d; the key is
# the lower-cased name in the lane-knob form lane.fly-pool[.<project>].<name>.
knob_key() {
  local k
  k=$(printf 'lane.fly-pool.%s%s' "${1:+$1.}" "$2" | tr '[:upper:]' '[:lower:]')
  case "$k" in *[!a-z0-9_.-]*) return 1 ;; esac
  [ "${#k}" -le 64 ] || return 1
  printf '%s\n' "$k"
}

alert_pct() {
  local k v
  k=$(knob_key "" pool_budget_alert_pct) || { echo 80; return; }
  v=$(row_get "$k") || v=""
  case "$v" in ''|*[!0-9]*) echo 80; return ;; esac
  { [ "$v" -ge 1 ] && [ "$v" -le 100 ]; } && echo "$v" || echo 80
}

# usd_per_hour — price of one pool machine-hour, "" when the catalog cannot price it.
usd_per_hour() {
  local out
  command -v fly_price_per_s >/dev/null 2>&1 || return 0
  out=$(fly_price_per_s "$H/catalog/fly-prices.json" performance "${POOL_BUDGET_VM_CPUS:-8}" "${POOL_BUDGET_VM_MEM_MB:-16384}") || return 0
  awk -v s="${out%% *}" 'BEGIN{printf "%.4f", s*3600}'
}

# hours_used — stdin: machines-list TSV. Prints "<hours> <live-untimed> <rows>".
hours_used() {
  python3 -I -c '
import sys, calendar, time
now = int(sys.argv[1]); start = now - now % 86400
def ts(s): return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))
hours = 0.0; untimed = 0; rows = 0
for line in sys.stdin:
    f = line.rstrip("\n").split("\t")
    if len(f) < 9: continue
    rows += 1
    state, spawned, seen = f[6], f[7], f[8]
    dead = state in ("destroyed", "gone")
    try: a = ts(spawned) if spawned else None
    except ValueError: a = None
    if a is None:
        if not dead: untimed += 1
        continue
    try: b = (ts(seen) if seen else a) if dead else now
    except ValueError: b = a
    lo, hi = max(a, start), min(b, now)
    if hi > lo: hours += (hi - lo) / 3600.0
print("%.1f %d %d" % (hours, untimed, rows))
' "$NOW"
}

# fire <project> <level> <id> <text> — once per project, level and UTC day.
fire() {
  local p="$1" lvl="$2" id="$3" text="$4"
  mkdir -p "$MK" 2>/dev/null
  [ -e "$MK/$p.$DAY.$lvl" ] && return 0
  : > "$MK/$p.$DAY.$lvl"
  if [ "$lvl" = limit ]; then : > "$MK/$p.$DAY.warn"; fi
  HARNESS="$H" "$H/bin/alert-line.sh" --severity warn --id "$id-$p" --project "$p" "$text"
}

budget_one() { # budget_one <project>
  local p="$1" key budget used untimed n rows pct apct rate usd cap lvl text rc
  key=$(knob_key "$p" pool_machine_hours_daily) || return 0
  budget=$(row_get "$key"); rc=$?
  case "$rc" in 0) ;; 2) return 0 ;; *) say "$p" "budget row unreadable (settings outage); no check this tick"; return 0 ;; esac
  [[ "$budget" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v b="$budget" 'BEGIN{exit !(b>0)}' || return 0
  rows=$("$JC" machines-list "$p" 2>/dev/null) || { say "$p" "machine list unreadable; no check this tick"; return 0; }
  read -r used untimed n <<< "$(hours_used <<< "$rows")"
  [ -n "${used:-}" ] || { say "$p" "machine list unparseable; no check this tick"; return 0; }
  pct=$(awk -v u="$used" -v b="$budget" 'BEGIN{printf "%d", u*100/b}')
  rate=$(usd_per_hour)
  usd=""; [ -n "$rate" ] && usd=$(awk -v u="$used" -v b="$budget" -v r="$rate" 'BEGIN{printf " (about $%.2f of $%.2f at $%.2f per machine-hour)", u*r, b*r, r}')
  text="$used of $budget machine-hours"
  say "$p" "$DAY UTC: $text, ${pct}%${usd}$([ "${untimed:-0}" -gt 0 ] && echo "; ${untimed} live row(s) not counted (no spawn time)")$([ "${n:-0}" -ge 500 ] && echo '; listing full (500 rows), figure is a floor')"
  apct=$(alert_pct)
  if [ "$pct" -ge 100 ]; then lvl=limit; cap="LIMIT REACHED"
  elif [ "$pct" -ge "$apct" ]; then lvl=warn; cap="${apct}% WARNING"
  else return 0; fi
  fire "$p" "$lvl" "pool-budget-$lvl" "[pool/$p] MACHINE-HOUR BUDGET $cap: $text used on $DAY UTC (${pct}%)${usd}. This is an alert only: no machine was stopped and no cap changed. To change the budget, set the row $key."
}

projects() {
  local p
  if [ "${1:-}" = --project ]; then printf '%s\n' "${2:-}"; return; fi
  "$H/bin/fleet-conf.sh" --projects 2>/dev/null | while read -r p; do
    [ -n "$p" ] && flag_on fly-pool "$p" && printf '%s\n' "$p"
  done
}

while read -r P; do
  [ -n "$P" ] || continue
  budget_one "$P"
done < <(projects "$@")
exit 0
