#!/bin/bash
# bin/lib/tz-check.sh: SOURCED, never executed. One function, tz_check <root>.
#
# WHY (2026-09-15). The hub was running on CDT. Every log line, alert and
# forensic timestamp it wrote was five hours off real time, and the first pass
# over the wipe (#388) spent those five hours reconciling stamps that did not
# agree. A box whose timezone is not UTC has to say so itself, because nothing
# downstream can tell a skewed timestamp from an honest one.
#
# THE TWO CALLERS:
#   bin/healthcheck.sh  per project with a prod surface, 43 6,18.
#   bin/clock-sync.sh   */30 on every cron file, hub.cron included. This is
#                       the lane that covers the hub, which has no project
#                       block and so never runs healthcheck.sh at all.
# Both call it as `tz_check "$H" || true`: the timezone verdict never changes
# either script's exit code.
#
# THE ALERT: one condition, stable id "tz:<box-id>", raised --critical through
# bin/lane-alert.sh and resolved from the same id when the box is back on UTC.
# lane-alert stores the lifecycle row under the SANITISED id, so on a live box
# the file is state/alerts/tz_<box-id>.json (as_sanitize_id folds ":" to "_"),
# not tz:<box-id>.json.
#
# THE RESOLVE IS CONDITIONAL, on purpose. alert_state_resolve keeps the row and
# stamps resolved_at, so "the file exists" is not "something is open". A box
# that has been healthy since boot, or healthy since the last resolve, calls
# nothing at all: an unconditional resolve writes a resolve-silent line into
# logs/alerts-state.log every half hour, which is ~48 a day per box into an
# append-only ledger with no rotation. An unreadable or unparseable row falls
# towards calling, which at worst costs that one line. The question is
# alert_state_open (bin/lib/alert-state.sh): with flags/alerts-db on, the
# `alerts` row answers first and the file only when the worker does not
# (BH-7802). Without that lib, the file rule below is the whole answer.
#
# THE KNOBS:
#   TZ_CHECK=0    off. Read from the environment first, and otherwise from the
#                 single TZ_CHECK= line of global.env in the harness env dir,
#                 which is where CLOCK_SYNC=0 lives and where an operator will
#                 put it. clock-sync.sh exports global.env before calling;
#                 healthcheck.sh does not source it and should not, so reading
#                 the one key here is what makes the documented switch true on
#                 BOTH lanes. The directory is resolved through harness_env_dir
#                 (bin/lib/env-path.sh), never a hardcoded path. Anything that
#                 is not exactly 0, including an unreadable or absent
#                 global.env, leaves the check ON: a missing file must never
#                 silence a pager.
#   TZ_OVERRIDE   the zone to test with, instead of `date +%Z`. Test input and
#                 dry-run input only; nothing in production sets it.
tz_check() { # tz_check <harness-root> -> 0 UTC or off, 1 non-UTC (alert fired)
  local H="${1:?harness-root}" on="${TZ_CHECK-}" Z BOX envdir row r
  # shellcheck disable=SC1090,SC1091
  command -v harness_env_dir >/dev/null 2>&1 || . "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "$1/env"; }
  if [ -z "$on" ]; then
    envdir=$(harness_env_dir "$H")
    on=$(sed -n 's/^\(export \)\{0,1\}TZ_CHECK=//p' "$envdir/global.env" 2>/dev/null | tr -d "\"' " | head -n 1)
  fi
  [ "${on:-1}" = 0 ] && return 0
  # An empty zone is a broken TZ setup, not a UTC box. It alerts.
  Z="${TZ_OVERRIDE:-$(date +%Z)}"; Z="${Z:-unknown}"
  BOX=$(tr -dc 'A-Za-z0-9._-' < "$H/state/box-id" 2>/dev/null); [ -n "$BOX" ] || BOX=$(hostname)
  if [ "$Z" != UTC ]; then
    "$H/bin/lane-alert.sh" --critical --id "tz:$BOX" --severity critical tz-check \
      "this box's timezone is $Z, not UTC. Every log, alert and forensic timestamp it writes is skewed (the hub was CDT on 2026-09-15 and it cost the first forensic pass five hours). Fix: ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime && echo Etc/UTC > /etc/timezone (these containers have no systemd; where timedatectl works, timedatectl set-timezone UTC also does)"
    return 1
  fi
  # shellcheck disable=SC1090,SC1091
  command -v alert_state_open >/dev/null 2>&1 || HARNESS="$H" . "$H/bin/lib/alert-state.sh" 2>/dev/null || true
  if command -v alert_state_open >/dev/null 2>&1; then
    alert_state_open "tz_$BOX" || return 0
  else
    row="${ALERT_STATE_DIR:-$H/state/alerts}/tz_$BOX.json"
    [ -s "$row" ] || return 0
    r=$(jq -r '.resolved_at//0' "$row" 2>/dev/null)
    case "$r" in ''|*[!0-9]*) r=0 ;; esac
    [ "$r" -gt 0 ] && return 0
  fi
  "$H/bin/lane-alert.sh" --resolve --id "tz:$BOX" tz-check "timezone is UTC"
  return 0
}
