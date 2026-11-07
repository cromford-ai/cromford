#!/bin/bash
# bin/lane-wake-calendar.sh — the calendar scheduler (BH-9074, BH-9067.2; the
# seam doc is docs/events-bh-9067/2-wake-pollers.bh-9074.md). A hub lane on a
# `* * * * *` line (cron/lanes/738-lane-wake-calendar.cron). It rings the lane
# wake gate (bin/lib/lane-wake-gate.sh, BH-9072) for every calendar lane whose
# schedule matches one of the next LANE_WAKE_CALENDAR_LEAD_MIN minutes, so
# that lane's own tick in that minute takes the ring and runs.
#
#   bin/lane-wake-calendar.sh                    one tick (the cron line)
#   bin/lane-wake-calendar.sh --match '<expr>' <epoch>
#                                                rc 0 match, 1 no match, 2 malformed
#
# INPUTS. catalog/lane-calendar.d/<lane>.tsv, one line per calendar entry:
# `<5-field cron expr>\t<key format>`, `#` and blank lines ignored. The key
# format is a `date -u +FORMAT` string; the dedupe is `cal:<key>`, lowercased,
# and must match the worker's ^[a-z0-9:#@._-]{1,64}$ (else `bad-key`). The
# scope comes from catalog/lane-wakes.d/<lane>.json `.scope`: `fleet` rings
# once; `project` rings once per `bin/fleet-conf.sh --projects` entry.
#
# WHY A LEAD. The lane's own cron fires in the target minute, and a take acks
# only the rings that exist at take time. A ring sent in the same minute can
# lose that race, and a weekly lane then waits a week. So at minute M the
# scheduler rings for the targets M+1..M+LEAD (LEAD 0: M itself). The dedupe
# comes from the target minute, so the second attempt is `inserted=0`.
#
# Lines in logs/lane-wake-calendar.log:
#   lane-wake-calendar ring <lane> <scope> <dedupe> inserted=<0|1>
#   lane-wake-calendar ring-failed <lane> <scope> <dedupe>  (mode on: one ALERTS line per lane per day)
#   lane-wake-calendar skip <lane> (no catalog/lane-wakes.d/<lane>.json)   only when a line matched
#   lane-wake-calendar bad-expr <lane> <expr> | bad-key <lane> <fmt> | bad-scope <lane> <scope>
#   lane-wake-calendar off (no lane wake gate lib)          at minute 00 only
# A lane in mode off is skipped silently. Every path exits 0 (a cron line).
#
# Knob: LANE_WAKE_CALENDAR_LEAD_MIN (row lane.lane-wake-calendar.lane_wake_calendar_lead_min).
# Off switch: flags/lane-off-lane-wake-calendar (bin/harness-ctl.sh off lane-wake-calendar).
set -uo pipefail
H="${HARNESS:-/root/harness}"
export HARNESS="$H"
LOG="$H/logs/lane-wake-calendar.log"

say() { mkdir -p "$H/logs" 2>/dev/null; printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "lane-wake-calendar $*" >> "$LOG" 2>/dev/null; return 0; }

# _cal_field <spec> <value> <lo> <hi> — rc 0 when <value> is in the field
# <spec> (`*`, `N`, `a-b`, `*/n`, `a-b/n`, comma lists), 1 when not, 2 when the
# spec is malformed. Every item of a list is checked, so a bad item is rc 2
# even after a match.
_cal_field() {
  local spec="$1" v="$2" lo="$3" hi="$4" item rng step a b hit=1
  [ -n "$spec" ] || return 2
  case "$spec" in ,*|*,|*,,*) return 2 ;; esac
  local -a items
  IFS=, read -r -a items <<<"$spec"   # read, not $spec: an unquoted `*` would glob
  for item in "${items[@]}"; do
    step=1; rng="$item"
    case "$item" in
      */*) rng="${item%/*}"; step="${item##*/}"
           [[ $step =~ ^[0-9]{1,2}$ ]] && [ "$((10#$step))" -ge 1 ] || return 2
           step=$((10#$step)) ;;
    esac
    case "$rng" in
      '*') a=$lo; b=$hi ;;
      *-*) a="${rng%-*}"; b="${rng#*-}"
           [[ $a =~ ^[0-9]{1,2}$ && $b =~ ^[0-9]{1,2}$ ]] || return 2
           a=$((10#$a)); b=$((10#$b)) ;;
      *)   [[ $rng =~ ^[0-9]{1,2}$ ]] || return 2
           a=$((10#$rng)); b=$a
           [ "$item" = "$rng" ] || return 2 ;;  # `N/n` is not a form this reader takes
    esac
    [ "$a" -ge "$lo" ] && [ "$b" -le "$hi" ] && [ "$a" -le "$b" ] || return 2
    [ "$v" -ge "$a" ] && [ "$v" -le "$b" ] && [ $(( (v - a) % step )) -eq 0 ] && hit=0
  done
  return "$hit"
}

# cal_match <expr> <epoch> — rc 0 match, 1 no match, 2 malformed. Standard cron
# semantics: day of week 0-7 (0 and 7 are Sunday); when both day of month and
# day of week are restricted (neither starts with `*`), either one matching is
# enough.
cal_match() {
  local expr="$1" t="$2" f mi ho dm mo dw rest M HH D MO W r1 r2 rdm rdw
  read -r mi ho dm mo dw rest <<<"$expr"
  [ -n "$dw" ] && [ -z "$rest" ] || return 2
  [[ $t =~ ^[0-9]+$ ]] || return 2
  f=$(date -u -d "@$t" '+%M %H %d %m %w' 2>/dev/null) || return 2
  read -r M HH D MO W <<<"$f"
  M=$((10#$M)); HH=$((10#$HH)); D=$((10#$D)); MO=$((10#$MO)); W=$((10#$W))
  _cal_field "$mi" "$M" 0 59; r1=$?; [ "$r1" = 2 ] && return 2
  _cal_field "$ho" "$HH" 0 23; r2=$?; [ "$r2" = 2 ] && return 2
  _cal_field "$dm" "$D" 1 31; rdm=$?; [ "$rdm" = 2 ] && return 2
  _cal_field "$mo" "$MO" 1 12; f=$?; [ "$f" = 2 ] && return 2
  _cal_field "$dw" "$W" 0 7; rdw=$?; [ "$rdw" = 2 ] && return 2
  # Sunday is 0 and 7: a 7 in the spec matches a %w of 0.
  if [ "$rdw" = 1 ] && [ "$W" = 0 ]; then _cal_field "$dw" 7 0 7 && rdw=0; fi
  [ "$r1" = 0 ] && [ "$r2" = 0 ] && [ "$f" = 0 ] || return 1
  case "$dm" in
    \**) [ "$rdm" = 0 ] && [ "$rdw" = 0 ]; return ;;
  esac
  case "$dw" in
    \**) [ "$rdm" = 0 ] && [ "$rdw" = 0 ] ;;
    *)   [ "$rdm" = 0 ] || [ "$rdw" = 0 ] ;;   # both restricted: OR
  esac
}

if [ "${1:-}" = --match ]; then
  cal_match "${2:-}" "${3:-}"; exit $?
fi

# shellcheck source=bin/lib/lane-gate.sh
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit lane-wake-calendar
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    lane-wake-calendar

NOW=""
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ]; then NOW="${LANE_WAKE_CALENDAR_NOW:-}"; fi  # test seam only
[[ $NOW =~ ^[0-9]+$ ]] || NOW=$(date -u +%s)
NOW=$(( NOW / 60 * 60 ))

# The wake gate is the contract's (#9122). Without it there is nothing to ring.
# The path is a variable so a tree without the lib still has a closed source
# graph (tests/lib/scratch.sh refuses a `.` of a file that does not exist).
LWG_LIB="$H/bin/lib/lane-wake-gate.sh"
if ! { [ -r "$LWG_LIB" ] && . "$LWG_LIB" 2>/dev/null \
       && command -v lwg_ring >/dev/null 2>&1 && command -v lwg_mode >/dev/null 2>&1; }; then
  [ "$(date -u -d "@$NOW" +%M)" = 00 ] && say "off (no lane wake gate lib)"
  exit 0
fi

# Code fallback 2 = the registry default of lane.lane-wake-calendar.lane_wake_calendar_lead_min.
LEAD="${LANE_WAKE_CALENDAR_LEAD_MIN:-2}"
if ! [[ $LEAD =~ ^[0-4]$ ]]; then
  say "LANE_WAKE_CALENDAR_LEAD_MIN='$LEAD' is not a whole number 0..4 — using 2"
  LEAD=2
fi
TARGETS=()
if [ "$LEAD" = 0 ]; then TARGETS=("$NOW")
else for ((k = 1; k <= LEAD; k++)); do TARGETS+=($((NOW + 60 * k))); done
fi

command -v jq >/dev/null 2>&1 || { say "off (no jq)"; exit 0; }
PROJECTS=""
WORK=$(mktemp -d "${TMPDIR:-/tmp}/lwcal.XXXXXX" 2>/dev/null) || { say "off (mktemp failed)"; exit 0; }
trap 'rm -rf "$WORK"' EXIT
n=0
declare -A MODES=()

for tsv in "$H"/catalog/lane-calendar.d/*.tsv; do
  [ -f "$tsv" ] || continue
  lane=$(basename "$tsv" .tsv)
  case "$lane" in ''|*[!a-z0-9-]*) say "bad-lane $lane"; continue ;; esac
  keys=()
  while IFS=$'\t' read -r expr fmt rest || [ -n "$expr" ]; do
    case "$expr" in ''|'#'*) continue ;; esac
    if [ -z "${fmt:-}" ] || [ -n "${rest:-}" ]; then say "bad-line $lane $expr"; continue; fi
    for t in "${TARGETS[@]}"; do
      cal_match "$expr" "$t"; rc=$?
      if [ "$rc" = 2 ]; then say "bad-expr $lane $expr"; break; fi
      [ "$rc" = 0 ] || continue
      key="cal:$(date -u -d "@$t" +"$fmt" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
      if ! [[ $key =~ ^[a-z0-9:#@._-]{1,64}$ ]]; then say "bad-key $lane $fmt"; break; fi
      keys+=("$key")
    done
  done < "$tsv"
  [ "${#keys[@]}" -gt 0 ] || continue
  reg="$H/catalog/lane-wakes.d/$lane.json"
  scope=$(jq -r '.scope // empty' "$reg" 2>/dev/null)
  if [ -z "$scope" ]; then say "skip $lane (no catalog/lane-wakes.d/$lane.json)"; continue; fi
  mode=$(lwg_mode "$lane" 2>/dev/null)
  [ "$mode" = off ] && continue
  MODES[$lane]=$mode
  case "$scope" in
    fleet) scopes=(fleet) ;;
    project)
      # project-loop-ok: one ring row per project (a D1 write), no project work runs here; each box's own lane tick takes its ring
      [ -n "$PROJECTS" ] || PROJECTS=$("$H/bin/fleet-conf.sh" --projects 2>/dev/null)
      read -r -d '' -a scopes <<<"$PROJECTS" ;;
    *) say "bad-scope $lane $scope"; continue ;;
  esac
  # One ring per distinct key and scope, each in its own background job: the
  # rings are independent writes, so they run in parallel.
  while IFS= read -r key; do
    for sc in "${scopes[@]}"; do
      case "$sc" in ''|.*|*[!a-z0-9._-]*) say "bad-scope $lane $sc"; continue ;; esac
      n=$((n + 1))
      printf '%s %s %s\n' "$lane" "$sc" "$key" > "$WORK/$n.job"
      ( out=$(lwg_ring "$lane" "$sc" "$key" 2>/dev/null); printf '%s\n%s\n' "$?" "$out" > "$WORK/$n.out" ) &
    done
  done < <(printf '%s\n' "${keys[@]}" | awk '!seen[$0]++')
done
wait

for ((i = 1; i <= n; i++)); do
  read -r lane sc key < "$WORK/$i.job"
  rc=$(sed -n 1p "$WORK/$i.out" 2>/dev/null)
  ins=$(sed -n 's/^inserted=\([01]\)$/\1/p' "$WORK/$i.out" 2>/dev/null | head -1)
  if [ "$rc" = 0 ] && [ -n "$ins" ]; then
    say "ring $lane $sc $key inserted=$ins"
  else
    say "ring-failed $lane $sc $key"
    if [ "${MODES[$lane]:-}" = on ] && command -v _lg_alert_once >/dev/null 2>&1; then
      _lg_alert_once "lane-wake-calendar-$lane" \
        "[lane-wake-calendar] ring for $lane ($sc, $key) failed with the lane in mode on: its next tick may skip. Check the jobs worker (POST /api/lane-wakes/ring) and logs/lane-wake-gate.log; settings row lib.lane-wake-gate.mode_${lane//-/_}=shadow stops the skip."
    fi
  fi
done
exit 0
