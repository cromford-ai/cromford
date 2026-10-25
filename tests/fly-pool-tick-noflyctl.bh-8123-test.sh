#!/bin/bash
# tests/fly-pool-tick-noflyctl.bh-8123-test.sh — BH-8123: a streak of hub pool
# ticks with no flyctl raises ONE ALERTS line.
#
#   THE INCIDENT (2026-10-23). On the new hub bh-hub-2 bin/fly-pool.sh skipped
#   every tick for "no flyctl" for 3 h. It alerts once a day per project on the
#   first skip, so the streak itself named nothing.
#
# bin/fly-pool-tick.sh runs here against a scratch HARNESS with one hub
# project. bin/fly-pool.sh and bin/alert-line.sh are recording stubs. No
# flyctl: FLY_BIN_DIR is an empty dir, FLY_SYSTEM_DIRS="", HOME is scratch and
# PATH holds no dir with a flyctl or fly. A found flyctl is a stub in FLY_BIN_DIR.
#
#   F1  ticks 1-3 with no flyctl: no alert; the streak reads 3.
#   F2  tick 4: one alert, --id pool-noflyctl-streak, "for 4 pool ticks in a row".
#   F3  ticks 5-20: still one alert.
#   F4  flyctl found at tick 2, gone at tick 3: the streak reads 1, no alert.
#   F5  knob unset = 3; F6 POOL_NOFLYCTL_ALERT_TICKS=1 alerts on tick 2;
#   F7  =0 never alerts in 10 ticks; F8 =abc falls back to 3.
#   F9  every project fly-placed (PTB_HUB empty): no count, no alert, and the
#       streak is kept.
#   Every case: the bin/fly-pool.sh stub still runs once per hub tick.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/fly-pool-tick-noflyctl.bh-8123-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }

# A PATH with no flyctl or fly on it, whatever this box has installed.
NOFLY_PATH=""
IFS=: read -ra _dirs <<<"$PATH"
for _d in "${_dirs[@]}"; do
  [ -n "$_d" ] || continue
  [ -x "$_d/flyctl" ] || [ -x "$_d/fly" ] && continue
  NOFLY_PATH="${NOFLY_PATH:+$NOFLY_PATH:}$_d"
done

# newcase <name>: $S, a scratch HARNESS with one hub project `alpha`.
newcase() {
  S="$T/$1"
  mkdir -p "$S/bin/lib" "$S/flags" "$S/logs" "$S/locks" "$S/env" "$S/state/fly-pool" "$S/emptyfly" "$S/flyok" "$S/home"
  # scratch-closure-allow: pool-cap.sh is the real --autoscale reader the wrapper calls; the rest are recording stubs
  cp "$REPO/bin/pool-cap.sh" "$S/bin/"
  printf '#!/bin/bash\nexit 0\n' > "$S/bin/fly-lock-guard.sh"
  printf '#!/bin/bash\necho "$1" >> "%s/ticked.txt"\nexit 0\n' "$S" > "$S/bin/fly-pool.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$S" > "$S/bin/alert-line.sh"
  # ptb_split: PTB_ALL_FLY=1 batches every project to Fly (PTB_HUB empty).
  printf 'ptb_split() { if [ "${PTB_ALL_FLY:-0}" = 1 ]; then PTB_HUB=(); else PTB_HUB=("$@"); fi; }\n' > "$S/bin/lib/pool-tick-batch.sh"
  printf '#!/bin/bash\necho "flyctl fixture"\n' > "$S/flyok/flyctl"
  chmod +x "$S/bin"/*.sh "$S/flyok/flyctl"
  : > "$S/env/global.env"
  : > "$S/flags/fly-pool-alpha"
}
# wrapper [VAR=val ...] — one cron start, no flyctl unless FLY_BIN_DIR says so.
wrapper() {
  ( export HARNESS="$S" HOME="$S/home" FLY_BIN_DIR="$S/emptyfly" FLY_SYSTEM_DIRS="" PATH="$NOFLY_PATH" POOL_TICK_WAIT_S=5 "$@"
    unset FLYCTL_INSTALL
    timeout 30 bash "$REPO/bin/fly-pool-tick.sh" >> "$S/wrapper.out" 2>&1 )
}
ticks() { local i; for ((i = 0; i < $1; i++)); do wrapper "${@:2}"; done; }
alerts() { local n; n=$(grep -c -- '--id pool-noflyctl-streak' "$S/alerts.txt" 2>/dev/null); echo "${n:-0}"; }
streak() { cut -d' ' -f1 "$S/state/fly-pool-tick/noflyctl.streak" 2>/dev/null || echo none; }
pooled() { local n; n=$(grep -c '^alpha$' "$S/ticked.txt" 2>/dev/null); echo "${n:-0}"; }

# ==== F1-F3 =====================================================================
newcase f1
ticks 3
check F1-no-alert "$(alerts)" 0
check F1-streak "$(streak)" 3
check F1-pool-ran "$(pooled)" 3
wrapper
check F2-one-alert "$(alerts)" 1
grep -q -- 'for 4 pool ticks in a row' "$S/alerts.txt" 2>/dev/null && ok || bad "F2-text: $(cat "$S/alerts.txt" 2>/dev/null)"
grep -q -- '/usr/local/bin/flyctl' "$S/alerts.txt" 2>/dev/null && ok || bad "F2-names-path: $(cat "$S/alerts.txt" 2>/dev/null)"
check F2-log-line "$(grep -c 'no flyctl .* pool ticks in a row' "$S/logs/fly-pool.log" 2>/dev/null)" 1
check F2-alerted-marker "$( [ -e "$S/state/fly-pool-tick/noflyctl.alerted" ] && echo yes || echo no)" yes
ticks 16
check F3-still-one "$(alerts)" 1
check F3-streak "$(streak)" 20
check F3-pool-ran "$(pooled)" 20

# ==== F4: a found flyctl ends the streak ==========================================
newcase f4
wrapper
wrapper FLY_BIN_DIR="$S/flyok"
check F4-reset "$(streak)" none
wrapper
check F4-count-1 "$(streak)" 1
check F4-no-alert "$(alerts)" 0
# An episode that alerted, then a found flyctl, then a new streak alerts again.
newcase f4b
ticks 4
check F4b-first "$(alerts)" 1
wrapper FLY_BIN_DIR="$S/flyok"
check F4b-marker-gone "$( [ -e "$S/state/fly-pool-tick/noflyctl.alerted" ] && echo yes || echo no)" no
ticks 4
check F4b-second-episode "$(alerts)" 2

# ==== F5-F8: the knob =============================================================
newcase f5
ticks 3
check F5-default-3-no-alert "$(alerts)" 0
wrapper
check F5-default-3-alert "$(alerts)" 1
newcase f6
wrapper POOL_NOFLYCTL_ALERT_TICKS=1
check F6-tick1 "$(alerts)" 0
wrapper POOL_NOFLYCTL_ALERT_TICKS=1
check F6-tick2 "$(alerts)" 1
newcase f7
ticks 10 POOL_NOFLYCTL_ALERT_TICKS=0
check F7-off "$(alerts)" 0
check F7-pool-ran "$(pooled)" 10
newcase f8
ticks 3 POOL_NOFLYCTL_ALERT_TICKS=abc
check F8-fallback-no-alert "$(alerts)" 0
wrapper POOL_NOFLYCTL_ALERT_TICKS=abc
check F8-fallback-alert "$(alerts)" 1

# ==== F9: no hub project, no count ================================================
newcase f9
ticks 2
ticks 5 PTB_ALL_FLY=1
check F9-kept "$(streak)" 2
check F9-no-alert "$(alerts)" 0
check F9-no-hub-tick "$(pooled)" 2

echo "fly-pool-tick-noflyctl.bh-8123: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
