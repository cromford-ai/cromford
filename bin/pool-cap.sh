#!/bin/bash
# bin/pool-cap.sh <project> — print the Fly pool's live-machine cap for a project.
# bin/pool-cap.sh --autoscale — print 1|0, the autoscale knob itself.
# bin/pool-cap.sh --set <project> <n> [--apply] — re-number an enabled pool's cap.
# bin/pool-cap.sh --knob-key <project> — print the cap's settings row key.
#
# 0 MEANS NO CEILING (the operator, 2026-09-14: "we can launch unlimited builders with
# fly.io"). The default 3 was OUR number, not Fly's: nine projects times three
# machines was a 27-builder fleet ceiling nobody had ever chosen on purpose, and
# every throughput ceiling is a bug. With nothing configured this now prints 0
# and bin/fly-pool.sh spawns one machine per QUEUED build instead of counting
# down to a number.
#
# Resolution, first hit wins:
#   1. a NUMBER inside flags/fly-pool-<project> (the box-local override — the
#      file's presence is the pool's enable switch either way, see fly-pool.sh)
#   2. the settings row lane.fly-pool.<project lowercased>.pool_cap (knob
#      POOL_CAP, BH-6737), written by the console's pool_cap command
#      (bin/cmd-pool-cap.sh) or the lane knob page. Read through
#      bin/jobs-client.sh setting-get; on a worker outage, the last value in
#      state/settings-cache.json, whatever its age. A row with no digits is
#      ignored. Only when POOL_AUTOSCALE is on, and never when ROUTING_ROWS
#      is set to anything but "on" (the routing_rows_on env rule).
#   3. fly/pool-caps.conf, a repo-tracked line `<project> <n>` — so the cap is a
#      reviewed commit that reaches the hub on its own harness-sync, not a
#      one-liner typed over ssh on a box most sessions cannot reach (2026-09-12:
#      the operator's "raise it to 5" had no path to the hub from the Mac)
#   4. 0 — unlimited.
# An explicit number from 1, 2 or 3 is still a HARD ceiling (a row of 0 is an
# explicit "no per-project ceiling"). Cost safety is the one
# reason left to write one, so a project that has one keeps it exactly.
# POOL_CAP_MAX (env/global.env, unset = unlimited) is the only OTHER ceiling: a
# fleet-wide brake that trims every per-project answer, unlimited included.
#
# KILL FLAG. POOL_AUTOSCALE=0 (env, or env/global.env) restores the pre-2026-09-14
# answer byte-for-byte: flag number, else the conf, else 3, and POOL_CAP_MAX is
# not consulted at all, and neither is the settings row.
#
# KNOB KEY (BH-6737). bin/pool-cap.sh --knob-key <project> prints the row key,
# the lane-knob form `lane.fly-pool.<project>.pool_cap` (_lg_setting_key in
# bin/lib/lane-gate.sh), and is rc 2 with no output when the key is not legal
# for PUT /api/settings (^[a-z0-9_.-]{1,64}$). Read-only: the one definition
# of the key, for this script and for bin/cmd-pool-cap.sh.
#
# WRITE MODE (BH-5750). bin/pool-cap.sh --set <project> <n> [--apply]
# re-numbers an EXISTING flags/fly-pool-<project> to <n>. Without --apply it
# prints `PLAN cap <p> <old>-><n>` and writes nothing; with it, it writes the
# number (tmp + mv) and prints `SET cap <p> <old>-><n>`. <old> is what the
# print path answers before the write. The file's presence is the pool's enable
# switch, so a cap set never creates it: no file is rc 2 `not on the pool`.
# <n> is a positive integer with no leading zero, refused otherwise (D11:
# never clamped). Exit 0 done/planned, 1 write failed, 2 refused or usage. The
# Mission Control fly_pool_cap command runs it from bin/box-ops.sh on the hub.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
# knob_key <project> — the POOL_CAP row key, rc 1 when it is not a legal key.
knob_key() {
  local k
  [[ "${1:-}" =~ ^[A-Za-z0-9._-]{1,64}$ ]] && [[ "$1" != *..* ]] || return 1
  k=$(printf 'lane.fly-pool.%s.pool_cap' "$1" | tr '[:upper:]' '[:lower:]')
  case "$k" in *[!a-z0-9_.-]*) return 1 ;; esac
  [ "${#k}" -le 64 ] || return 1
  printf '%s\n' "$k"
}
if [ "${1:-}" = --knob-key ]; then
  [ $# -eq 2 ] || { echo "usage: pool-cap.sh --knob-key <project>" >&2; exit 2; }
  knob_key "$2" || { echo "pool-cap: no legal settings key for project '$2'" >&2; exit 2; }
  exit 0
fi
if [ "${1:-}" = --set ]; then
  setref() { echo "pool-cap: $*" >&2; exit 2; }
  [ $# -eq 3 ] || [ $# -eq 4 ] || setref "usage: pool-cap.sh --set <project> <n> [--apply]"
  SP="$2"; SN="$3"; SA="${4:-}"
  [ -z "$SA" ] || [ "$SA" = --apply ] || setref "usage: pool-cap.sh --set <project> <n> [--apply]"
  [[ "$SP" =~ ^[A-Za-z0-9._-]{1,64}$ ]] && [[ "$SP" != *..* ]] || setref "project '$SP' must match [A-Za-z0-9._-]{1,64}"
  [[ "$SN" =~ ^[1-9][0-9]*$ ]] || setref "cap '$SN' is not a positive integer"
  SF="$HARNESS/flags/fly-pool-$SP"
  # The file's presence is the enable switch, and the cap is written into it,
  # so the check is the one file-only reader (bin/lib/flag-on.sh, BH-5635),
  # never a raw test and never the row.
  . "$HARNESS/bin/lib/flag-on.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/flag-on.sh" 2>/dev/null \
    || flag_file_on() { [ -f "$HARNESS/flags/$1-$2" ]; }
  flag_file_on fly-pool "$SP" || setref "$SP is not on the pool (no flags/fly-pool-$SP); nothing written"
  old=$(bash "${BASH_SOURCE[0]}" "$SP" 2>/dev/null)
  if [ "$SA" != --apply ]; then printf 'PLAN cap %s %s->%s\n' "$SP" "${old:-?}" "$SN"; exit 0; fi
  printf '%s\n' "$SN" > "$SF.tmp.$$" && mv "$SF.tmp.$$" "$SF" \
    || { rm -f "$SF.tmp.$$"; echo "pool-cap: cannot write $SF" >&2; exit 1; }
  printf 'SET cap %s %s->%s\n' "$SP" "${old:-?}" "$SN"; exit 0
fi
P="${1:?project}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$HARNESS")

# Both knobs live in env/global.env and every caller reaches this script from
# cron with an unsourced environment. The keys are READ out of the file rather
# than sourced: global.env also holds tokens, and this script's whole output is
# stdout that a caller interpolates into a log line.
gkey() { # gkey <NAME> — the digits of NAME as env/global.env sets it, if it does
  [ -r "$HENV/global.env" ] || return 0
  sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=[\"']\{0,1\}\([^\"']*\).*/\2/p" \
    "$HENV/global.env" 2>/dev/null | tail -1 | tr -dc '0-9'
}

AUTOSCALE="${POOL_AUTOSCALE:-$(gkey POOL_AUTOSCALE)}"
case "$AUTOSCALE" in 0) AUTOSCALE=0 ;; *) AUTOSCALE=1 ;; esac
# ONE reader for the knob too: bin/fly-pool-tick.sh and bin/fly-pool-rollout.sh
# both branch on it, and a second copy of "is autoscale on" is how flags/ and
# the conf came to disagree about the cap in the first place.
[ "$P" = "--autoscale" ] && { printf '%s\n' "$AUTOSCALE"; exit 0; }

# pool_cap_row — the digits of the POOL_CAP settings row, or nothing. rc 2 from
# setting-get is "no row"; any other failure is an outage, and the last cached
# value answers then: skipping the row in a blip could turn a cap of 3 into
# unlimited, which is a cost risk.
# ROUTING_ROWS set to anything but "on" skips the row entirely: no GET and no
# cache read, so the cap is today's flag-then-conf answer. That is the
# routing_rows_on rule (bin/lib/jobs/routing.sh: "ROUTING_ROWS=off skips even
# that"), which pins the dark-default paths (fly-pool-rollout.sh, the routing
# preflight and seed scripts) to zero worker traffic.
pool_cap_row() {
  local key v rc
  if [ -n "${ROUTING_ROWS:-}" ] && [ "$ROUTING_ROWS" != on ]; then return 0; fi
  [ -r "$HARNESS/bin/jobs-client.sh" ] || return 0
  key=$(knob_key "$P") || return 0
  v=$(timeout 10 bash "$HARNESS/bin/jobs-client.sh" setting-get "$key" 2>/dev/null); rc=$?
  case "$rc" in
    0) ;;
    2) return 0 ;;
    *) v=$(jq -r --arg k "$key" '.values[$k] // empty' "$HARNESS/state/settings-cache.json" 2>/dev/null) ;;
  esac
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s\n' "$v"
  return 0
}

n=$(cat "$HARNESS/flags/fly-pool-$P" 2>/dev/null | tr -dc '0-9')
if [ -z "$n" ] && [ "$AUTOSCALE" = 1 ]; then POOL_CAP_ROW=$(pool_cap_row); n="$POOL_CAP_ROW"; fi
if [ -z "$n" ] && [ -r "$HARNESS/fly/pool-caps.conf" ]; then
  n=$(grep -vE '^\s*#' "$HARNESS/fly/pool-caps.conf" | awk -v p="$P" '$1 == p { print $2; exit }' | tr -dc '0-9')
fi

if [ "$AUTOSCALE" = 0 ]; then printf '%s\n' "${n:-3}"; exit 0; fi

MAX="${POOL_CAP_MAX:-$(gkey POOL_CAP_MAX)}"
case "$MAX" in ''|*[!0-9]*) MAX=0 ;; esac
n="${n:-0}"
# The fleet-wide brake trims a per-project number, and it trims "unlimited" too
# — that is the whole point of having it.
if [ "$MAX" != 0 ] && { [ "$n" = 0 ] || [ "$n" -gt "$MAX" ]; }; then n="$MAX"; fi
printf '%s\n' "$n"
