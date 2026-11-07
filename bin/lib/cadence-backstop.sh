#!/bin/bash
# bin/lib/cadence-backstop.sh <lane> [--wake-dir <dir>]... — C2 (2026-09-24):
# a cron tick of a lane that events already wake runs only as a BACKSTOP.
# Executed from the lane's cron fragment, in front of the lane:
#
#   */5 * * * * …/hub-lease.sh check && { …/lib/cadence-backstop.sh merge-conductor; [ $? -ne 3 ]; } && …/merge-conductor.sh
#
#   rc 0  run the lane this tick
#   rc 3  skip it: the last backstop run was under N minutes ago and no wake is
#         pending. The ONLY rc 3, and always a positive decision with a log line.
#   anything else (a set -u abort's 1, a missing gate's 127, a non-executable
#         gate's 126) runs the lane: the cron line skips on 3 alone.
#
# WHY. GitHub webhooks are live on all 11 fleet repos (wakes rows since
# 2026-09-24 20:43Z), and bin/wake-loop.sh launches the merge conductor on every
# pr/checks wake. The */5 cron conductor was still the hub's biggest GitHub
# caller (~3,827 calls/hour on the App) and the */10 blocked resolver ~545/h, most
# of it re-reading PRs nothing had happened to. The cron line keeps its schedule
# (rendered crontabs are generated files, and a schedule change is a deploy); the
# row decides how often a tick is allowed through, so rollback is a row edit:
#
#   lib.cadence-backstop.cadence_backstop_min_merge_conductor   default 60 (BH-5521: hourly sweep; webhooks drive keyed runs)
#   lib.cadence-backstop.cadence_backstop_min_blocked_resolver  default 30
#   lib.cadence-backstop.cadence_backstop_min_orc_monitor       default 0 (BH-9074; 30 once rings wake it)
#   0 = off: every cron tick runs, exactly as before this file existed.
#
# A WAKE BEATS THE CLOCK. `--wake-dir <dir>`: any file in <dir> newer than the
# last backstop run lets the tick through. The blocked resolver passes the merge
# conductor's hand-off directory (state/merge-conductor/handoff), so a fresh
# park is drained on the next */10 tick rather than waiting out the half hour.
# A wake-loop launch of the conductor never comes through here at all.
#
# KNOBS COUNTED IN TICKS STRETCH WITH THE BACKSTOP (review of #2231). They are
# not rescaled here; set their rows if the stretched value is wrong for you:
#   BR_SATURATED_TICKS=12   "more parks than rungs" alert: 2h at */10, up to 6h
#                           at a 30 min backstop (less when hand-offs wake it)
#   BR_PER_TICK=4           resolver rungs per tick: 24/h at */10, ~8/h plus
#                           wake runs at 30 min. lane.blocked-resolver.br_per_tick
#                           = 12 keeps the old hourly throughput
#   MC_UNVERIFIABLE_ALERT_TICKS=6  conductor ticks reading UNVERIFIABLE before
#                           one alert: 30 min at */5 with no wakes, up to 90 min
#                           at a 15 min backstop — wake-loop's conductor runs
#                           count too, so on a busy repo it is barely changed
# Rollback of all three at once is the backstop row at 0.
#
# FAIL-OPEN, ALWAYS (rules: a gate in front of a lane must not become the thing
# that stops it). No lane name, an unreadable knob, a state dir that cannot be
# written, a clock that does not parse — every one of them is rc 0. The only
# dependency is this box's own filesystem; bin/lib/lane-gate.sh is consulted for
# the row in a subshell whose failure costs the row, never the lane.
#
# The cron schedule tolerance: a backstop of N minutes lets a tick through once
# N*60-30 seconds have passed, so cron start jitter on a */5 line cannot turn a
# 15-minute backstop into a 20-minute one.
set -u
H="${HARNESS:-/root/harness}"
LANE="${1:-}"
[ $# -gt 0 ] && shift
WAKES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --wake-dir) [ -n "${2:-}" ] && WAKES+=("$2"); shift; [ $# -gt 0 ] && shift ;;
    *) shift ;;
  esac
done
case "$LANE" in ''|*[!a-z0-9-]*) exit 0 ;; esac

MIN=$(
  if [ -r "$H/bin/lib/lane-gate.sh" ]; then
    # shellcheck source=bin/lib/lane-gate.sh
    { . "$H/bin/lib/lane-gate.sh" && command -v lib_env_apply && lib_env_apply cadence-backstop; } >/dev/null 2>&1
  fi
  case "$LANE" in
    merge-conductor)  printf '%s' "${CADENCE_BACKSTOP_MIN_MERGE_CONDUCTOR:-60}" ;;
    blocked-resolver) printf '%s' "${CADENCE_BACKSTOP_MIN_BLOCKED_RESOLVER:-30}" ;;
    orc-monitor)      printf '%s' "${CADENCE_BACKSTOP_MIN_ORC_MONITOR:-0}" ;;
    *)                printf '0' ;;
  esac
) 2>/dev/null || MIN=0
case "$MIN" in ''|*[!0-9]*) MIN=0 ;; esac
[ "$MIN" -gt 0 ] || exit 0

NOW=$(date -u +%s 2>/dev/null) || exit 0
case "$NOW" in ''|*[!0-9]*) exit 0 ;; esac
D="$H/state/cadence-backstop"
ST="$D/$LANE.last"
mkdir -p "$D" "$H/logs" 2>/dev/null || exit 0

stamp() { { printf '%s\n' "$NOW" > "$ST.$$" && mv -f "$ST.$$" "$ST"; } 2>/dev/null; rm -f "$ST.$$" 2>/dev/null; return 0; }
say() { printf '%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*" >> "$H/logs/cadence-backstop.log" 2>/dev/null; return 0; }

LAST=$(head -c 20 "$ST" 2>/dev/null | tr -dc '0-9')
if [ -z "$LAST" ]; then stamp; exit 0; fi
AGE=$((NOW - LAST))
if [ "$AGE" -lt 0 ] || [ "$AGE" -ge $((MIN * 60 - 30)) ]; then stamp; exit 0; fi

# ${WAKES[@]+…}: bash < 4.4 (macOS /bin/bash 3.2) calls an empty array unbound under set -u.
for d in ${WAKES[@]+"${WAKES[@]}"}; do
  [ -d "$d" ] || continue
  # `*.logged` is the conductor's per-park log marker (mc_handoff_* in
  # bin/lib/mc/classify.sh), rewritten hourly for every parked PR: not a new
  # hand-off, so never a wake (review of #2231).
  if [ -n "$(find "$d" -type f ! -name '*.logged' -newer "$ST" -print -quit 2>/dev/null)" ]; then
    say "RUN $LANE: wake pending in $d (last backstop run ${AGE}s ago)"
    stamp; exit 0
  fi
done

say "SKIP $LANE: last backstop run ${AGE}s ago, under the ${MIN}m backstop, and no wake is pending"
# rc 3, not 1 (lead review of #2231): a set -u abort or a crash also exits 1,
# and a missing gate is 126/127. The cron line skips the lane ONLY on 3, so
# anything that is not a deliberate decision runs the lane (fail-open).
exit 3
