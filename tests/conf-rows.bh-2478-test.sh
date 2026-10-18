#!/bin/bash
# tests/conf-rows.bh-2478-test.sh — BH-2478, follow-ups to BH-2411's conf rows.
#
# What is proved here:
#   S1-S6 bin/lib/scheduler-conf.sh: a conf.scheduler.* row the knob's own
#         validator refuses is NO row, so flags/scheduler.conf answers (BH-2411
#         let it land on the code default). A valid row still beats the file; a
#         string knob takes any non-empty row; a refused BOX row falls to the
#         file, not the fleet row.
#   K1-K5 bin/lib/alert-state.sh: the same for alert_cfg's `set` scalars.
#   N1    the values a validator must NOT refuse.
#   M1-M6 conf_rows_preload: the rows are read into the calling shell once, so
#         every later `$(sched_num …)` / `$(alert_cfg …)` / fleet-slo `$(conf …)`
#         reuses them instead of running jq over the settings cache again. A jq
#         shim first on PATH counts every jq whose arguments name the cache.
#         M4 and M5 drive the production entry points (alert_state_enabled, the
#         real bin/fleet-slo.sh --dry-run).
# Run from anywhere: tests/conf-rows.bh-2478-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

# A fixture harness with NO bin/jobs-client.sh: conf-row never asks the worker
# to refresh, so the cache written by cache_in is read as it stands and the only
# jq over it is the row read itself.
H="$T/h"
mkdir -p "$H/bin" "$H/flags" "$H/state" "$H/logs"

REALJQ=$(command -v jq)
mkdir -p "$T/shim"
cat > "$T/shim/jq" <<SH
#!/bin/bash
for a in "\$@"; do case "\$a" in *settings-cache.json*) echo jq >> "\$JQLOG"; break ;; esac; done
exec "$REALJQ" "\$@"
SH
chmod +x "$T/shim/jq"

# cache_in <harness> k=v... — a FRESH settings cache written straight to disk.
cache_in() {
  local h="$1" kv out='{}'; shift
  for kv in "$@"; do
    out=$(printf '%s' "$out" | "$REALJQ" -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[$k]=$v')
  done
  mkdir -p "$h/state"
  "$REALJQ" -nc --argjson fa "$(date -u +%s)" --argjson v "$out" '{fetched_at:$fa, values:$v, seeded:{}}' \
    > "$h/state/settings-cache.json"
}
reset() {
  scratch_rm "$H/state/lane-gate"; rm -f "$H/logs/lane-gate.log" "$H/state/settings-cache.json" "$H/flags"/*
  : > "$T/jq.log"
}
jqn() { wc -l < "$T/jq.log" | tr -d ' '; }
XENV=()
# lib <snippet> — a cold child shell with HARNESS=$H, the jq shim first on PATH.
lib() {
  env PATH="$T/shim:$PATH" HARNESS="$H" JOBS_BOX=hub-1 JQLOG="$T/jq.log" "${XENV[@]}" \
      bash -c 'set -uo pipefail; D=$1; shift; eval "$1"' _ "$DIR" "$1" 2>/dev/null
}
sched() { lib '. "$D/bin/lib/scheduler-conf.sh" || exit 9; '"$1"; }
as()    { lib '. "$D/bin/lib/alert-state.sh" || exit 9; '"$1"; }
loglines() { if [ -f "$1" ]; then grep -c -- "$2" "$1"; else echo 0; fi; }

# ── S: scheduler.conf ─────────────────────────────────────────────────────────
reset; cache_in "$H" conf.scheduler.overlap_pr_limit=abc; printf 'OVERLAP_PR_LIMIT=45\n' > "$H/flags/scheduler.conf"
eq "S1 a malformed row falls through to flags/scheduler.conf, not the code default" \
  "$(sched 'sched_num OVERLAP_PR_LIMIT 30')" "45"
eq "S1 the refused row is logged" \
  "$(loglines "$H/logs/lane-gate.log" "conf scheduler: row conf.scheduler.overlap_pr_limit='abc' refused, flags/scheduler.conf used")" "1"
sched 'sched_num OVERLAP_PR_LIMIT 30' >/dev/null
eq "S1 and not again inside the throttle" "$(loglines "$H/logs/lane-gate.log" 'refused')" "1"
eq "S1 a refused row does not claim to override the file" \
  "$(loglines "$H/logs/lane-gate.log" 'settings rows override')" "0"
reset; cache_in "$H" conf.scheduler.overlap_threshold=1.7; printf 'OVERLAP_THRESHOLD=0.4\n' > "$H/flags/scheduler.conf"
eq "S2 a fraction row above 1 falls through to the file" "$(sched 'sched_frac OVERLAP_THRESHOLD 0')" "0.4000"
reset; cache_in "$H" conf.scheduler.overlap_pr_limit=12; printf 'OVERLAP_PR_LIMIT=45\n' > "$H/flags/scheduler.conf"
eq "S3 a valid row still beats the file" "$(sched 'sched_num OVERLAP_PR_LIMIT 30')" "12"
reset; cache_in "$H" conf.scheduler.overlap_pr_limit=abc
eq "S4 a malformed row and no file: the code default" "$(sched 'sched_num OVERLAP_PR_LIMIT 30')" "30"
reset; cache_in "$H" 'conf.scheduler.overlap_ignore=*.lock'; printf 'OVERLAP_IGNORE=package.json\n' > "$H/flags/scheduler.conf"
eq "S5 a string knob takes any non-empty row" "$(sched 'sched_conf OVERLAP_IGNORE x')" "*.lock"
reset; cache_in "$H" conf.scheduler.overlap_pr_limit.hub-1=abc conf.scheduler.overlap_pr_limit=12
printf 'OVERLAP_PR_LIMIT=45\n' > "$H/flags/scheduler.conf"
eq "S6 a refused box row falls to the file, not the fleet row" "$(sched 'sched_num OVERLAP_PR_LIMIT 30')" "45"

# ── K: alerts.conf ────────────────────────────────────────────────────────────
reset; cache_in "$H" conf.alerts.alert_reminder_s=soon; printf 'set ALERT_REMINDER_S 900\n' > "$H/flags/alerts.conf"
eq "K1 a non-number *_S row falls through to flags/alerts.conf" "$(as 'alert_cfg ALERT_REMINDER_S 21600')" "900"
eq "K1 the refused row is logged" \
  "$(loglines "$H/logs/lane-gate.log" "conf alerts: row conf.alerts.alert_reminder_s='soon' refused, flags/alerts.conf used")" "1"
reset; cache_in "$H" conf.alerts.alert_default_severity=loud; printf 'set ALERT_DEFAULT_SEVERITY warn\n' > "$H/flags/alerts.conf"
eq "K2 an unknown severity row falls through" "$(as 'alert_cfg ALERT_DEFAULT_SEVERITY critical')" "warn"
reset; cache_in "$H" 'conf.alerts.alert_park_downgrade_re=(('; printf 'set ALERT_PARK_DOWNGRADE_RE X|Y\n' > "$H/flags/alerts.conf"
eq "K3 a regex row that does not compile falls through" "$(as 'alert_cfg ALERT_PARK_DOWNGRADE_RE d')" "X|Y"
reset; cache_in "$H" conf.alerts.alert_state_enabled=0; printf 'set ALERT_STATE_ENABLED 1\n' > "$H/flags/alerts.conf"
eq "K4 a valid row 0 still turns alert_state_enabled off" "$(as 'alert_state_enabled; echo "rc=$?"')" "rc=1"
reset; cache_in "$H" conf.alerts.alert_state_enabled=yes; printf 'set ALERT_STATE_ENABLED 0\n' > "$H/flags/alerts.conf"
eq "K4 an _ENABLED row that is not 0|1 falls to the file's 0" "$(as 'alert_state_enabled; echo "rc=$?"')" "rc=1"
reset; cache_in "$H" conf.alerts.alert_warn_batch_max=15; printf 'set ALERT_WARN_BATCH_MAX 60\n' > "$H/flags/alerts.conf"
eq "K5 a valid *_MAX row still beats the file" "$(as 'alert_cfg ALERT_WARN_BATCH_MAX 60')" "15"

# ── N: values a validator must not refuse ─────────────────────────────────────
for v in 0 00 1800; do
  reset; cache_in "$H" "conf.scheduler.overlap_pr_limit=$v"; printf 'OVERLAP_PR_LIMIT=45\n' > "$H/flags/scheduler.conf"
  eq "N1 num row '$v' is accepted" "$(sched 'sched_num OVERLAP_PR_LIMIT 30')" "$v"
done
for v in 0 0.25 1 .5; do
  reset; cache_in "$H" "conf.scheduler.overlap_threshold=$v"; printf 'OVERLAP_THRESHOLD=0.4\n' > "$H/flags/scheduler.conf"
  eq "N1 frac row '$v' is accepted" "$(sched 'sched_frac OVERLAP_THRESHOLD 0')" "$(awk -v x="$v" 'BEGIN{printf "%.4f", x+0}')"
done
for v in 'a b|c d' 'LANE DOWN|AUTH DOWN'; do
  reset; cache_in "$H" "conf.alerts.alert_park_downgrade_re=$v"; printf 'set ALERT_PARK_DOWNGRADE_RE X\n' > "$H/flags/alerts.conf"
  eq "N1 regex row '$v' is accepted" "$(as 'alert_cfg ALERT_PARK_DOWNGRADE_RE d')" "$v"
done
reset; cache_in "$H" conf.alerts.alert_default_severity=warn; printf 'set ALERT_DEFAULT_SEVERITY info\n' > "$H/flags/alerts.conf"
eq "N1 severity row 'warn' is accepted" "$(as 'alert_cfg ALERT_DEFAULT_SEVERITY critical')" "warn"
reset; cache_in "$H" 'conf.scheduler.overlap_ignore=package.json *.md'
eq "N1 an OVERLAP_IGNORE row with a space is accepted" "$(sched 'sched_conf OVERLAP_IGNORE x')" "package.json *.md"

# ── M: the rows are read once per process ─────────────────────────────────────
M3SNIP='a=$(sched_num OVERLAP_PR_LIMIT 30); b=$(sched_num REBASE_TRAIN_MAX 3); c=$(sched_frac OVERLAP_THRESHOLD 0); echo "$a $b $c"'
reset; cache_in "$H" conf.scheduler.overlap_pr_limit=11 conf.scheduler.rebase_train_max=7 conf.scheduler.overlap_threshold=0.5
eq "M1 without a preload, each \$(sched_*) reads the cache again (baseline)" \
  "$(sched "$M3SNIP" >/dev/null; [ "$(jqn)" -ge 3 ] && echo ge3 || echo "$(jqn)")" "ge3"
: > "$T/jq.log"
eq "M2 after conf_rows_preload the three answers are the rows" \
  "$(sched 'conf_rows_preload scheduler; '"$M3SNIP")" "11 7 0.5000"
eq "M3 and jq ran over the settings cache exactly once" "$(jqn)" "1"

reset; cache_in "$H" conf.alerts.alert_reminder_s=77
eq "M4 alert_state_enabled loads the rows, later \$(alert_cfg) reuse them" \
  "$(as 'alert_state_enabled; for n in 1 2 3; do x=$(alert_cfg ALERT_REMINDER_S 1); done; echo "$x"')" "77"
# The gate also reads its kill switch row through lane_switch (BH-2434): the
# refresh's age check, the box row and the fleet row. Three alert_cfg calls add
# nothing to what the gate alone costs.
M4ALL=$(jqn); : > "$T/jq.log"
as 'alert_state_enabled' >/dev/null
eq "M4 three alert_cfg calls add no jq over the cache to the gate's own" "$M4ALL" "$(jqn)"
# TEST-CHANGE (BH-7251): the gate's switch row (the refresh's age check, the box
# row, the fleet row) was three jq over the cache; lane-gate.sh's settings memo
# (_lg_sc_load) now parses the cache ONCE per file content and answers all
# three from memory. That reduction is the ticket's goal (plan part 2:
# "_lg_settings_refresh, _lg_setting_lookup … no longer call jq"), so the
# count drops from 1 + 3 to 1 + 1. The memo's jq still names the cache, so this
# shim still counts it.
eq "M4 the gate's own: one for the rows, one for the switch row's settings memo" "$(jqn)" "2"
: > "$H/flags/alerts-db"; : > "$T/jq.log"
eq "M4 alerts_db_on preloads too" \
  "$(as 'alerts_db_on; for n in 1 2 3; do x=$(alert_cfg ALERT_REMINDER_S 1); done; echo "$x"')" "77"
eq "M4 one jq over the cache behind alerts_db_on" "$(jqn)" "1"

# M5: the real bin/fleet-slo.sh. Its scratch harness HAS a jobs client, so the
# preload's one refresh reads fetched_at (the cache is fresh, no GET) and then
# loads the rows: two jq over the cache for eighteen conf reads.
O="$T/o"; mkdir -p "$O/bin" "$O/flags" "$O/logs" "$O/builds"
cp "$DIR/bin/result-prefix-ok.sh" "$O/bin/"
printf '#!/bin/bash\nexit 0\n' > "$O/bin/lane-alert.sh"; chmod +x "$O/bin/"*.sh
: > "$O/fleet.conf"
printf '_jobs_req() { echo "{\\"jobs\\":[]}"; }\nlanes_list() { return 1; }\n' > "$O/bin/jobs-client.sh"
printf 'SLO_WINDOW_MIN 60\n' > "$O/flags/slo.conf"
: > "$T/jq.log"; rm -f "$O/logs/fleet-slo.log"
cache_in "$O" conf.slo.slo_window_min=15 conf.slo.slo_refusal_rate=0.5 conf.slo.slo_refusal_min_launches=9 \
  conf.slo.slo_lane_death_rate=0.4 conf.slo.slo_lane_min_lanes=8 conf.slo.slo_stale_running_max=5
env PATH="$T/shim:$PATH" JQLOG="$T/jq.log" HARNESS="$O" JOBS_BOX=hub-1 bash "$DIR/bin/fleet-slo.sh" --dry-run >/dev/null 2>&1
eq "M5 fleet-slo --dry-run reads the row value" "$(grep -o '(window [0-9]*m)' "$O/logs/fleet-slo.log" 2>/dev/null | tail -1)" "(window 15m)"
eq "M5 and runs jq over the settings cache twice (one refresh check, one row read), not per knob" "$(jqn)" "2"

# M6: the off paths source nothing and read nothing.
reset; cache_in "$H" conf.alerts.alert_reminder_s=77
XENV=(LANE_GATE_DISABLE=1)
eq "M6 LANE_GATE_DISABLE=1: the preload sources nothing" \
  "$(as 'alert_state_enabled; x=$(alert_cfg ALERT_REMINDER_S 1); command -v _lg_settings_refresh >/dev/null && echo sourced || echo "none $x"')" "none 1"
eq "M6 LANE_GATE_DISABLE=1: no jq over the cache" "$(jqn)" "0"
cp /dev/null "$T/fixture-alerts.conf"
XENV=(ALERTS_CONF="$T/fixture-alerts.conf")
eq "M6 ALERTS_CONF set: the preload sources nothing" \
  "$(as 'alert_state_enabled; command -v _lg_settings_refresh >/dev/null && echo sourced || echo none')" "none"
eq "M6 ALERTS_CONF set: no jq over the cache" "$(jqn)" "0"
XENV=()
: > "$T/jq.log"; rm -f "$O/logs/fleet-slo.log"
env PATH="$T/shim:$PATH" JQLOG="$T/jq.log" HARNESS="$O" JOBS_BOX=hub-1 SLO_CONF="$O/flags/slo.conf" \
  bash "$DIR/bin/fleet-slo.sh" --dry-run >/dev/null 2>&1
eq "M6 SLO_CONF set: fleet-slo reads the file and no jq over the cache" \
  "$(grep -o '(window [0-9]*m)' "$O/logs/fleet-slo.log" 2>/dev/null | tail -1) $(jqn)" "(window 60m) 0"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
