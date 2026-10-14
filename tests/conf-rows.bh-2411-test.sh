#!/bin/bash
# tests/conf-rows.bh-2411-test.sh — BH-2411 (BH-2320.C5): the nine flags/
# config files become `conf.<file>.<key>` settings rows, box row
# `conf.<file>.<key>.<box>` first, read ABOVE flags/<file> and nowhere else.
#
# What is proved here:
#   H1-H8 bin/lib/conf-row.sh: fleet row, box row over fleet row, another
#         box's row and a prefix-colliding / seeded row answer nothing,
#         LANE_GATE_DISABLE=1, an outage keeps the last cache, no cache = no
#         rows, the "row overrides flags/<file>" log line is throttled, a value
#         holding a newline and a box key over 64 chars are refused and logged;
#   S  scheduler.conf  through sched_num          (bin/lib/scheduler-conf.sh)
#   C  cost-caps.conf  through cost_budget_*      (bin/lib/cost-budget.sh)
#   L  lane-caps.conf  through lane_cap_*         (bin/lib/lane-caps.sh)
#   W  ledger-ttl.conf through the real bin/jobs-watchdog.sh (which rows it reaps)
#   O  slo.conf        through the real bin/fleet-slo.sh --dry-run
#   K  alerts.conf     through alert_cfg / alert_state_enabled
#   D  dora-digest.conf through the real bin/dora-digest.sh
#   T  determinism-lint.conf through the real bin/test-determinism-lint.sh
#   R  readiness-levels.json through the real bin/readiness-report.sh --print-levels
#   Every converted reader is driven twice: once with a row set against a
#   contradicting file (the row must win), once with no row (the file answers,
#   exactly as before).
#   N1 no bin/ or fly/ script writes one of the nine files; N2 each of the nine
#   resolvers calls conf_row/conf_rows.
# Run from anywhere: tests/conf-rows.bh-2411-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

NOW=1758300000
H="$T/h"
mkdir -p "$H/bin" "$H/flags" "$H/state" "$H/logs"

# The stub worker, at the path lane-gate's _lg_ensure_client sources. It sets
# -uo pipefail at its top level exactly like bin/jobs-client.sh, so K3 can see
# a caller's options survive it. Every request lands in $CALLS.
cat > "$H/bin/jobs-client.sh" <<'SH'
set -uo pipefail
_jobs_req() {
  echo "$1 $2" >> "$CALLS"
  [ -n "${UNREACHABLE:-}" ] && return 1
  case "$2" in
    /api/settings) printf '{"settings":%s}' "$(cat "$ROWS_FILE" 2>/dev/null || echo '[]')" ;;
    *) return 1 ;;
  esac
}
SH

# rows k=v [k=v...] — the settings table. `seed:k=v` is a registry-seed row.
rows() {
  local out='[]' kv k v actor
  for kv in "$@"; do
    actor=api
    case "$kv" in seed:*) actor=registry-seed; kv="${kv#seed:}" ;; esac
    k="${kv%%=*}"; v="${kv#*=}"
    out=$(printf '%s' "$out" | jq -c --arg k "$k" --arg v "$v" --arg a "$actor" '. + [{key:$k,value:$v,actor:$a}]')
  done
  printf '%s' "$out" > "$T/rows.json"
}
reset() {
  scratch_rm "$H/state/lane-gate"; rm -f "$H/logs/lane-gate.log" "$H/state/settings-cache.json" "$T/rows.json"
  rm -f "$H/flags"/*
  : > "$T/calls"; UNREACHABLE=""; AT="$NOW"; BOX=hub-1
}
# lib <snippet> — a cold child shell with HARNESS=$H and the repo's libraries.
lib() {
  env HARNESS="$H" LANE_GATE_NOW="$AT" CALLS="$T/calls" ROWS_FILE="$T/rows.json" \
      UNREACHABLE="$UNREACHABLE" JOBS_BOX="$BOX" "${XENV[@]}" \
      bash -c 'set -uo pipefail; D=$1; shift; . "$D/bin/lib/conf-row.sh" || exit 9; eval "$1"' _ "$DIR" "$1" 2>/dev/null
}
XENV=()
loglines() { if [ -f "$1" ]; then grep -c "$2" "$1"; else echo 0; fi; }
# cache_in <harness> k=v... — a FRESH settings cache written straight to disk,
# for the real-script cases whose scratch harness has no worker client.
cache_in() {
  local h="$1"; shift
  rows "$@"
  mkdir -p "$h/state"
  jq -c --argjson fa "$(date -u +%s)" \
    '{fetched_at:$fa, values:(reduce (.[]|select(.actor!="registry-seed")) as $s ({}; .[$s.key]=$s.value)),
      seeded:(reduce (.[]|select(.actor=="registry-seed")) as $s ({}; .[$s.key]=$s.value))}' \
    "$T/rows.json" > "$h/state/settings-cache.json"
}

# ── H: the helper ─────────────────────────────────────────────────────────────
reset; rows conf.scheduler.overlap_threshold=5 conf.cost-caps.ceiling=10
eq "H1 conf_rows lists the file's fleet rows" "$(lib 'conf_rows scheduler')" "$(printf 'overlap_threshold\t5')"
eq "H1 one GET for two reads" "$(lib 'conf_rows scheduler >/dev/null; conf_row cost-caps ceiling >/dev/null'; grep -c 'GET /api/settings' "$T/calls")" "1"

reset; BOX=Hub-1; rows conf.scheduler.overlap_threshold.hub-1=7 conf.scheduler.overlap_threshold=5
eq "H2 box row beats fleet row" "$(lib 'conf_row scheduler overlap_threshold > "$HARNESS/o"; echo "$(cat "$HARNESS/o") $CONF_ROW_SRC"')" "7 box-row"
eq "H2 conf_rows applies the box row" "$(lib 'conf_rows scheduler')" "$(printf 'overlap_threshold\t7')"
reset; rows conf.scheduler.overlap_threshold=5
eq "H2 fleet row alone" "$(lib 'conf_row scheduler overlap_threshold > "$HARNESS/o"; echo "$(cat "$HARNESS/o") $CONF_ROW_SRC"')" "5 fleet-row"

reset; rows conf.scheduler.overlap_threshold.otherbox=9 conf.scheduler.overlap_threshold_x=3 seed:conf.scheduler.overlap_threshold=4
eq "H3 another box / prefix collision / seed row answer nothing" \
  "$(lib 'conf_row scheduler overlap_threshold; echo "rc=$? src=$CONF_ROW_SRC"')" "rc=1 src=none"

reset; rows conf.scheduler.overlap_threshold=5
XENV=(LANE_GATE_DISABLE=1)
eq "H4 LANE_GATE_DISABLE=1 reads no row" "$(lib 'conf_rows scheduler; conf_row scheduler overlap_threshold; echo "rc=$?"')" "rc=1"
XENV=()
eq "H4 and asks nobody" "$(grep -c . "$T/calls")" "0"

reset; rows conf.scheduler.overlap_threshold=5
lib 'conf_rows scheduler >/dev/null'
AT=$((NOW + 86400)); UNREACHABLE=1; rows
eq "H5 an outage keeps the last cache at any age" "$(lib 'conf_row scheduler overlap_threshold')" "5"
grep -q 'GET /api/settings' "$T/calls" && ok || bad "H5 the stale cache must still try the worker once"

reset; UNREACHABLE=1
eq "H6 no cache, no worker: no row" "$(lib 'conf_row scheduler overlap_threshold; echo "rc=$?"')" "rc=1"
printf 'OVERLAP_THRESHOLD=4\n' > "$H/flags/scheduler.conf"
eq "H6 and the file answers, as before" "$(lib '. "$D/bin/lib/scheduler-conf.sh"; sched_num OVERLAP_THRESHOLD 0')" "4"

reset; rows conf.scheduler.overlap_threshold=5
printf 'OVERLAP_THRESHOLD=0\n' > "$H/flags/scheduler.conf"
lib '. "$D/bin/lib/scheduler-conf.sh"; sched_num OVERLAP_THRESHOLD 0' >/dev/null
eq "H7 row over a contradicting file is logged once" "$(loglines "$H/logs/lane-gate.log" 'conf scheduler: settings rows override flags/scheduler.conf for: overlap_threshold')" "1"
lib '. "$D/bin/lib/scheduler-conf.sh"; sched_num OVERLAP_THRESHOLD 0' >/dev/null
eq "H7 and not again inside the throttle" "$(loglines "$H/logs/lane-gate.log" 'conf scheduler:')" "1"

reset; rows "conf.scheduler.overlap_threshold=5
6"
eq "H8 a value holding a newline is no row" "$(lib 'conf_row scheduler overlap_threshold; echo "rc=$?"'; lib 'conf_rows scheduler')" "rc=1"
grep -q 'conf scheduler: row conf.scheduler.overlap_threshold' "$H/logs/lane-gate.log" 2>/dev/null && ok || bad "H8 the refused value must be logged"
LONG=abcdefghijabcdefghijabcdefghijabcdefghijabcdefg   # fleet key 62 chars, box key 68
reset; rows "conf.scheduler.$LONG=3" "conf.scheduler.$LONG.hub-1=8"
eq "H8 a box key over 64 chars: fleet row reads" "$(lib "conf_row scheduler $LONG")" "3"
grep -q "conf scheduler: box row for $LONG" "$H/logs/lane-gate.log" 2>/dev/null && ok || bad "H8 the impossible box key must be logged"

# ── S: scheduler.conf ─────────────────────────────────────────────────────────
sched() { lib '. "$D/bin/lib/scheduler-conf.sh"; sched_num OVERLAP_THRESHOLD 0'; }
reset; rows conf.scheduler.overlap_threshold=5; printf 'OVERLAP_THRESHOLD=0\n' > "$H/flags/scheduler.conf"
eq "S1 row beats a contradicting flags/scheduler.conf" "$(sched)" "5"
reset; printf 'OVERLAP_THRESHOLD=0\n' > "$H/flags/scheduler.conf"
eq "S2 no row: the file" "$(sched)" "0"
reset; rows conf.scheduler.overlap_threshold=5 conf.scheduler.overlap_threshold.hub-1=7; printf 'OVERLAP_THRESHOLD=0\n' > "$H/flags/scheduler.conf"
eq "S3 box row beats fleet row through sched_num" "$(sched)" "7"
XENV=(OVERLAP_THRESHOLD=2)
eq "S4 env still beats the row" "$(sched)" "2"
XENV=()
reset; rows conf.scheduler.overlap_threshold=abc; printf 'OVERLAP_THRESHOLD=0\n' > "$H/flags/scheduler.conf"
eq "S5 an unparseable row falls to the documented default, as the file would" "$(sched)" "0"

# ── C: cost-caps.conf ─────────────────────────────────────────────────────────
cb() { lib '. "$D/bin/lib/cost-budget.sh"; '"$1"; }
cfile() { printf 'budget project-5 100 5\nceiling 3000\n' > "$H/flags/cost-caps.conf"; }
reset; cfile; rows 'conf.cost-caps.budget.project-5=250 3'
eq "C1 row beats flags/cost-caps.conf" "$(cb 'cost_budget_for project-5')" "250 3"
eq "C1 the source names the rows" "$(cb 'cost_budget_source')" "$H/flags/cost-caps.conf + settings conf.cost-caps.*"
for v in abc -5 0; do
  reset; cfile; rows "conf.cost-caps.ceiling=$v"
  eq "C2 ceiling row '$v' never overrides" "$(cb 'cost_budget_ceiling')" "3000"
  case " $(cb 'cost_budget_legacy_rows') " in *" row:ceiling "*) ok ;; *) bad "C2 ceiling row '$v' must be named as refused" ;; esac
done
reset; cfile; cp "$H/flags/cost-caps.conf" "$T/fixture-caps.conf"; rows 'conf.cost-caps.budget.project-5=250 3'
XENV=(COST_CAPS_CONF="$T/fixture-caps.conf")
eq "C3 COST_CAPS_CONF set: rows are not read" "$(cb 'cost_budget_for project-5')" "100 5"
XENV=()
reset; cfile
eq "C4 no rows: values from the file" "$(cb 'cost_budget_for project-5; cost_budget_ceiling')" "$(printf '100 5\n3000')"
eq "C4 no rows: source is the file alone" "$(cb 'cost_budget_source')" "$H/flags/cost-caps.conf"
reset; cfile; rows 'conf.cost-caps.budget.project-5.otherbox=1 1'
eq "C5 another box's budget row changes nothing" "$(cb 'cost_budget_for project-5')" "100 5"

# ── L: lane-caps.conf ─────────────────────────────────────────────────────────
lc() { lib '. "$D/bin/lib/lane-caps.sh"; '"$1"; }
lfile() { printf 'lane medic 90\n' > "$H/flags/lane-caps.conf"; }
reset; lfile; rows conf.lane-caps.lane.medic=off
eq "L1 row off beats flags lane medic 90" "$(lc 'lane_cap_usd medic')" "off"
for v in -3 '1.5 x'; do
  reset; lfile; rows "conf.lane-caps.lane.medic=$v"
  eq "L2 row '$v' never overrides" "$(lc 'lane_cap_usd medic')" "90"
  case " $(lc 'lane_caps_legacy_rows') " in *" row:lane.medic "*) ok ;; *) bad "L2 row '$v' must be named as refused" ;; esac
done
reset; lfile; rows conf.lane-caps.lane.medic=off
XENV=(LANE_USD_CAP_MEDIC=5)
eq "L3 env beats the row" "$(lc 'lane_cap_usd medic')" "5"
XENV=()
reset; lfile
eq "L4 no rows: the file" "$(lc 'lane_cap_usd medic; lane_caps_source')" "$(printf '90\n%s' "$H/flags/lane-caps.conf")"
reset; lfile; rows conf.lane-caps.lane.medic=50
lc 'lane_cap_usd medic' >/dev/null
AT=$((NOW + 86400)); UNREACHABLE=1; rows
eq "L5 an outage keeps the cached cap, never off" "$(lc 'lane_cap_usd medic')" "50"
reset; lfile; rows 'conf.lane-caps.lane.medic=90 40000' conf.lane-caps.noise.medic=4
eq "L6 bytes and noise rows" "$(lc 'lane_cap_bytes medic; lane_noise_cap medic')" "$(printf '40000\n4')"

# ── W: ledger-ttl.conf, through the real bin/jobs-watchdog.sh ──────────────────
W="$T/w"; mkdir -p "$W/bin/lib/jobs" "$W/flags" "$W/logs" "$W/state" "$W/fakebin"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$W/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$W/bin/lib/jobs/"
cp "$DIR/bin/lib/gh-repo-token.sh" "$W/bin/lib/"
: > "$W/fleet.conf"
cat > "$W/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  */api/jobs\?status=running*) cat "$STALE_JSON"; printf '\n200\n' ;;
  */api/jobs/*)                printf '{"job":{"id":"x","status":"orphaned"}}\n200\n' ;;
  */events)                    printf '{"event_id":1}\n201\n' ;;
  *)                           printf '{}\n404\n' ;;
esac
EOF
printf '#!/bin/bash\nexit 1\n' > "$W/fakebin/gh"
chmod +x "$W/fakebin/curl" "$W/fakebin/gh"
# TK-109: a build/execute row 400m old that never beat. PR-5: a pr-* row 35m old.
cat > "$W/stale.json" <<'EOF'
{"jobs":[
 {"id":"build-project-3-TK-109","project":"project-3","kind":"build","stage":"execute",
  "box":"b1","ticket_id":"TK-109","activity_age_s":24000,"budget_usd":150,"spent_usd":1,"last_beat_at":null},
 {"id":"triage-project-3-pr-5","project":"project-3","kind":"triage","stage":"triage",
  "box":"b1","ticket_id":"pr-5","activity_age_s":2100,"budget_usd":25,"spent_usd":0.1,"last_beat_at":null}
]}
EOF
printf 'ttl execute 360\n' > "$W/flags/ledger-ttl.conf"
wd() { # wd [k=v rows...] -> the PATCH lines the sweep made
  rm -f "$W/req.log" "$W/logs/ALERTS.log" "$W/state/jobs-watchdog-alerted.txt" "$W/state/settings-cache.json"
  scratch_rm "$W/state/lane-gate"
  [ $# -gt 0 ] && cache_in "$W" "$@"
  ( export PATH="$W/fakebin:$PATH" HARNESS="$W" HARNESS_SECRET=s JOBS_URL=https://jobs.invalid \
           STALE_JSON="$W/stale.json" REQ_SINK="$W/req.log" FLEET_CONF="$W/fleet.conf" \
           JOBS_RECONCILE_EVERY=0 JOBS_BOX=hub-1
    bash "$DIR/bin/jobs-watchdog.sh" >/dev/null 2>&1 )
}
reaped() { grep -c "PATCH .*/api/jobs/$1 .*\"status\":\"orphaned\"" "$W/req.log" 2>/dev/null || true; }
wd conf.ledger-ttl.ttl.execute=999
eq "W1 row ttl.execute=999 beats flags ttl execute 360 (400m row lives)" "$(reaped build-project-3-TK-109)" "0"
wd conf.ledger-ttl.ttl.pr-_=30
eq "W2 row ttl.pr-_=30 reaps a 35m pr-* row" "$(reaped triage-project-3-pr-5)" "1"
wd conf.ledger-ttl.ttl.execute=soon
eq "W3 row ttl.execute=soon falls to the file's 360" "$(reaped build-project-3-TK-109)" "1"
wd
eq "W4 no rows: the file's 360 reaps the 400m row" "$(reaped build-project-3-TK-109)" "1"
eq "W4 no rows: the pr-* row lives under the catalog's 360" "$(reaped triage-project-3-pr-5)" "0"

# ── O: slo.conf, through the real bin/fleet-slo.sh ──────────────────────────────
O="$T/o"; mkdir -p "$O/bin" "$O/flags" "$O/logs" "$O/builds"
cp "$DIR/bin/result-prefix-ok.sh" "$O/bin/"
printf '#!/bin/bash\nexit 0\n' > "$O/bin/lane-alert.sh"; chmod +x "$O/bin/"*.sh
: > "$O/fleet.conf"
printf '_jobs_req() { echo "{\\"jobs\\":[]}"; }\nlanes_list() { return 1; }\n' > "$O/bin/jobs-client.sh"
printf 'SLO_WINDOW_MIN 60\n' > "$O/flags/slo.conf"
slo() { rm -f "$O/logs/fleet-slo.log" "$O/state/settings-cache.json"; [ $# -gt 0 ] && cache_in "$O" "$@"
        HARNESS="$O" JOBS_BOX=hub-1 bash "$DIR/bin/fleet-slo.sh" --dry-run >/dev/null 2>&1
        grep -o '(window [0-9]*m)' "$O/logs/fleet-slo.log" | tail -1; }
eq "O1 row slo_window_min=15 beats flags SLO_WINDOW_MIN 60" "$(slo conf.slo.slo_window_min=15)" "(window 15m)"
eq "O2 no row: the file" "$(slo)" "(window 60m)"

# ── K: alerts.conf ────────────────────────────────────────────────────────────
as() { lib '. "$D/bin/lib/alert-state.sh"; '"$1"; }
reset; printf 'set ALERT_STATE_ENABLED 1\n' > "$H/flags/alerts.conf"; rows conf.alerts.alert_state_enabled=0
eq "K1 row 0 beats flags set ALERT_STATE_ENABLED 1" "$(as 'alert_state_enabled; echo "rc=$?"')" "rc=1"
reset; printf 'set ALERT_PARK_DOWNGRADE_RE from file\n' > "$H/flags/alerts.conf"; rows 'conf.alerts.alert_park_downgrade_re=a b|c d'
eq "K2 a row value with spaces survives whole" "$(as 'alert_cfg ALERT_PARK_DOWNGRADE_RE x')" "a b|c d"
reset; rows conf.alerts.alert_state_enabled=0
eq "K3 a -u caller without pipefail keeps it off" \
  "$(env HARNESS="$H" LANE_GATE_NOW="$AT" CALLS="$T/calls" ROWS_FILE="$T/rows.json" JOBS_BOX=hub-1 bash -c '
      set -u; . "$1/bin/lib/alert-state.sh"; conf_rows alerts >/dev/null; alert_cfg X d >/dev/null
      set -o | awk '\''$1=="pipefail"{print $2}'\''' _ "$DIR" 2>/dev/null)" "off"
reset; printf 'set ALERT_STATE_ENABLED 0\n' > "$H/flags/alerts.conf"
eq "K4 no row: the file" "$(as 'alert_state_enabled; echo "rc=$?"')" "rc=1"
cp "$H/flags/alerts.conf" "$T/fixture-alerts.conf"; rows conf.alerts.alert_state_enabled=1
XENV=(ALERTS_CONF="$T/fixture-alerts.conf")
eq "K4 ALERTS_CONF set: rows are not read" "$(as 'alert_state_enabled; echo "rc=$?"')" "rc=1"
XENV=()

# ── D: dora-digest.conf, through the real bin/dora-digest.sh ────────────────────
DD="$T/d"; mkdir -p "$DD/bin" "$DD/flags" "$DD/logs" "$DD/state"
cp "$H/bin/jobs-client.sh" "$DD/bin/jobs-client.sh"
: > "$DD/fleet.conf"
printf 'DORA_WINDOW=7d\n' > "$DD/flags/dora-digest.conf"
TODAY=$(date -u +%F)
digest() {
  scratch_rm "$DD/state/dora"; rm -f "$DD/state/settings-cache.json"; scratch_rm "$DD/state/lane-gate"
  cache_in "$DD" "$@"   # always: an empty cache is "no rows", and the stub worker never answers stale rows
  env HARNESS="$DD" FLEET_CONF="$DD/fleet.conf" CALLS="$T/calls" ROWS_FILE="$T/rows.json" JOBS_BOX=hub-1 \
      DORA_LEDGER=0 "$DIR/bin/dora-digest.sh" --no-send >/dev/null 2>&1
  ls "$DD/state/dora" 2>/dev/null | grep '\.json$' | tr '\n' ' '
}
eq "D1 row dora_window=30d beats flags DORA_WINDOW=7d" "$(digest conf.dora-digest.dora_window=30d)" "$TODAY-30d.json "
eq "D2 a row outside the DORA_* namespace, or with shell in it, is never exported" \
  "$(digest conf.dora-digest.path=/x 'conf.dora-digest.dora_window=$(id)')" "$TODAY-7d.json "
eq "D3 no row: the file" "$(digest)" "$TODAY-7d.json "

# ── T: determinism-lint.conf, through the real bin/test-determinism-lint.sh ─────
DL="$T/dl"; mkdir -p "$DL/flags" "$DL/c/tests"
cp "$DIR/catalog/determinism-lint.conf" "$DL/flags/determinism-lint.conf"
printf '#!/bin/bash\nKEY="build-$RANDOM"\n' > "$DL/c/tests/leaky-test.sh"  # determinism: ok the fixture text the lint is pointed at, never run
lint() { OUT=$(HARNESS="$DL" JOBS_BOX=hub-1 bash "$DIR/bin/test-determinism-lint.sh" "$@" 2>&1); RC=$?; }
rm -f "$DL/state/settings-cache.json"
lint --rules; BASE_RULES="$OUT"
lint "$DL/c"; eq "T0 the file alone fails the leak" "$RC" "1"
cache_in "$DL" 'conf.determinism-lint.rule.rand-bash=warn sh \$RANDOM'  # determinism: ok the fixture text the lint is pointed at, never run
lint --rules
grep -qxF 'rule rand-bash warn sh \$RANDOM' <<<"$OUT" && ok || bad "T1 --rules must show the row's rule: $OUT"  # determinism: ok the fixture text the lint is pointed at, never run
grep -q '^rule rand-bash[[:space:]]*error' <<<"$OUT" && bad "T1 the file's rand-bash line must be replaced" || ok
grep -qxF "conf: $DL/flags/determinism-lint.conf + settings conf.determinism-lint.*" <<<"$OUT" && ok || bad "T1 --rules must name the rows: $(head -1 <<<"$OUT")"
lint "$DL/c"; eq "T1 the row's warn severity decides the scan" "$RC" "0"
rm -f "$DL/state/settings-cache.json"
lint --rules; eq "T2 no rows: --rules byte-identical to the file alone" "$OUT" "$BASE_RULES"
eq "T2 the baseline is the file" "$(head -1 <<<"$BASE_RULES")" "conf: $DL/flags/determinism-lint.conf"

# ── R: readiness-levels.json, through the real bin/readiness-report.sh ──────────
RH="$T/r"; mkdir -p "$RH/flags"
jq '.max_level = 5' "$DIR/catalog/readiness-levels.json" > "$RH/flags/readiness-levels.json"
DOC3=$(jq -c '.max_level = 3' "$DIR/catalog/readiness-levels.json")
DOC4=$(jq -c '.max_level = 4' "$DIR/catalog/readiness-levels.json")
levels() { rm -f "$RH/state/settings-cache.json"; [ $# -gt 0 ] && cache_in "$RH" "$@"
           env HARNESS="$RH" JOBS_BOX=hub-1 "${XENV[@]}" bash "$DIR/bin/readiness-report.sh" --print-levels 2>"$T/r.err" \
             | jq -r '"\(.max_level) \(.levels_source)"'; }
eq "R1 the document row beats flags/readiness-levels.json" "$(levels "conf.readiness-levels=$DOC3")" "3 settings conf.readiness-levels"
eq "R1 the box document row beats the fleet one" "$(levels "conf.readiness-levels=$DOC3" "conf.readiness-levels.hub-1=$DOC4")" "4 settings conf.readiness-levels.hub-1"
eq "R2 a row that is not JSON falls to the file" "$(levels 'conf.readiness-levels={not json')" "5 $RH/flags/readiness-levels.json"
grep -q 'conf.readiness-levels' "$T/r.err" && ok || bad "R2 the refused row must be named on stderr"
eq "R2 a row with no .levels falls to the file" "$(levels 'conf.readiness-levels={"max_level":1}')" "5 $RH/flags/readiness-levels.json"
eq "R3 no row: the file" "$(levels)" "5 $RH/flags/readiness-levels.json"
XENV=(READINESS_LEVELS="$RH/flags/readiness-levels.json")
eq "R3 READINESS_LEVELS set: rows are not read" "$(levels "conf.readiness-levels=$DOC3")" "5 $RH/flags/readiness-levels.json"
XENV=()

# ── N: nothing writes the files; every resolver reads rows ────────────────────
NINE='(scheduler|cost-caps|lane-caps|ledger-ttl|slo|alerts|dora-digest|determinism-lint)\.conf|readiness-levels\.json'
# Comment lines are dropped first: "environment > flags/alerts.conf" in a header
# is prose about precedence, not a redirect.
W1=$(grep -rnE "(>>?|\btee\b( -a)?)[[:space:]]*\"?[^[:space:]|;&]*flags/($NINE)" "$DIR/bin" "$DIR/fly" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
W2=$(grep -rnE "(^|[;&|][[:space:]]*)(cp|mv|install)[[:space:]][^#]*flags/($NINE)" "$DIR/bin" "$DIR/fly" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
eq "N1 no script writes flags/<one of the nine> (it must write the row)" "$W1$W2" ""
for f in bin/lib/scheduler-conf.sh bin/lib/cost-budget.sh bin/lib/lane-caps.sh bin/jobs-watchdog.sh \
         bin/fleet-slo.sh bin/lib/alert-state.sh bin/dora-digest.sh bin/test-determinism-lint.sh bin/readiness-report.sh; do
  if [ -r "$DIR/$f" ] && grep -qE '(^|[^_a-z])conf_rows?[[:space:]]' "$DIR/$f"; then ok; else bad "N2 $f does not read conf_row/conf_rows"; fi
done

echo "conf-rows.bh-2411: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
