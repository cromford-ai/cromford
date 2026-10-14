#!/bin/bash
# tests/mc-full-tick-window.bh-6518-test.sh — BH-6518 slice C1: the conductor's
# full-tick window (BH-5521) lives in bin/lib/mc/tick-scope.sh as
# mc_full_tick_window. The driver calls it after mc_keyed_tick_parse and
# refuses the tick when the file defines one function and not the other.
#
#   W1-W8  the window, sourced alone: the window width, MC_WINDOW_NEXT, the
#          export attribute and the exact log line (or none). Inputs are the
#          shapes mc_keyed_tick_parse and bin/merge-conductor-backstop.sh set.
#   D1     the real driver (production entry point), unkeyed, logs exactly one
#          window line; with the call line deleted it logs none.
#   D2     the real driver, keyed, logs no window line.
#   D3     tick-scope.sh with mc_keyed_tick_parse and no mc_full_tick_window:
#          rc 1, one CONDUCTOR MODULE MISSING alert, no window line, no gh
#          call; with the new guard clause dropped the driver does not refuse.
#   L1     the closure still lists tick-scope.sh, and the shim
#          (bin/lib/merge-conductor-lib.sh) never defines mc_full_tick_window.
# Run from anywhere: tests/mc-full-tick-window.bh-6518-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
TS="$DIR/bin/lib/mc/tick-scope.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

WIN="full tick: worker window"
TAIL="(MC_FULL_TICK_BUDGET_S) — a PR that does not fit is deferred, not started"
NEXT="the next hourly sweep or a wake for this PR takes it"

# ── W1-W8. the window, sourced alone ────────────────────────────────────────
# win_case <MC_ONLY_KEYS> <MC_WORKERS_DONE_BY or UNSET or X-EXPORTED>
#          <MC_FULL_TICK_BUDGET_S or UNSET> — prints four lines:
#   width=<done_by minus now, or unset, or same>  next=[<MC_WINDOW_NEXT or unset>]
#   export=<x|-|unset>  log=[<every mc_log line, | joined>]
win_case() {
  ( LOGF="$T/w.log"; : > "$LOGF"
    mc_log() { printf '%s\n' "$*" >> "$LOGF"; }
    unset MC_WORKERS_DONE_BY MC_WINDOW_NEXT MC_FULL_TICK_BUDGET_S
    MC_ONLY_KEYS="$1"
    case "$2" in
      UNSET) ;;
      X-EXPORTED) export MC_WORKERS_DONE_BY=x ;;
      *) MC_WORKERS_DONE_BY="$2" ;;
    esac
    [ "$3" = UNSET ] || MC_FULL_TICK_BUDGET_S="$3"
    # shellcheck source=bin/lib/mc/tick-scope.sh
    . "$TS" || exit 8
    before="${MC_WORKERS_DONE_BY-}"
    now=$(date +%s)
    mc_full_tick_window || exit 7
    if [ -z "${MC_WORKERS_DONE_BY+x}" ]; then printf 'width=unset\n'
    elif [ "$MC_WORKERS_DONE_BY" = "$before" ]; then printf 'width=same\n'
    else
      d=$(( MC_WORKERS_DONE_BY - now ))
      # 0-2 s tolerance: report the budget the window was opened with.
      for b in 600 1500; do
        [ "$d" -ge "$b" ] && [ "$d" -le $((b + 2)) ] && d=$b
      done
      printf 'width=%s\n' "$d"
    fi
    printf 'next=[%s]\n' "${MC_WINDOW_NEXT-unset}"
    if [ -z "${MC_WORKERS_DONE_BY+x}" ]; then printf 'export=unset\n'
    else
      dp=$(declare -p MC_WORKERS_DONE_BY)
      case "$dp" in "declare -x"*) printf 'export=x\n' ;; *) printf 'export=-\n' ;; esac
    fi
    printf 'log=[%s]\n' "$(paste -sd'|' "$LOGF")" )
}
want_case() { # want_case <id> <keys> <done_by> <budget> <width> <next> <export> <log>
  local got want
  got=$(win_case "$2" "$3" "$4" 2>&1)
  want=$(printf 'width=%s\nnext=[%s]\nexport=%s\nlog=[%s]' "$5" "$6" "$7" "$8")
  [ "$got" = "$want" ] && ok || bad "$1: keys=[$2] done_by=$3 budget=$4
--- want
$want
--- got
$got"
}
FAR=$(( $(date +%s) + 100000 ))
want_case W1 ''               UNSET      UNSET 1500  "$NEXT" -     "$WIN 1500s $TAIL"
want_case W2 ''               UNSET      600   600   "$NEXT" -     "$WIN 600s $TAIL"
want_case W3 ''               UNSET      abc   1500  "$NEXT" -     "$WIN 1500s $TAIL"
want_case W4 ''               UNSET      0     unset unset   unset ''
want_case W5 ' example-org/a#7 ' UNSET     600   unset unset   unset ''
want_case W6 ''               "$FAR"     600   same  unset   -     ''
want_case W7 ''               X-EXPORTED 600   600   "$NEXT" -     "$WIN 600s $TAIL"
want_case W8 ''               UNSET      -5    1500  "$NEXT" -     "$WIN 1500s $TAIL"

# ── D1-D3. the real driver ──────────────────────────────────────────────────
HD="$T/hd"
mkdir -p "$HD/logs" "$HD/state" "$HD/flags" "$HD/locks" "$HD/builds" "$HD/env" "$HD/fakebin"
scratch_install_closure bin/merge-conductor.sh "$HD" >/dev/null || exit 1
scratch_install_closure bin/alert-line.sh "$HD" >/dev/null || exit 1
[ -r "$HD/bin/merge-conductor.sh" ] || { echo "FAIL: the closure did not install bin/merge-conductor.sh"; exit 1; }
cp "$HD/bin/merge-conductor.sh" "$T/driver.pristine" || exit 1
# An empty fleet: the tick parses, logs, and has no project to touch.
: > "$HD/fleet.conf"
cat > "$HD/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
exit 0
SH
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$HD/fakebin/curl"
chmod +x "$HD/fakebin/gh" "$HD/fakebin/curl"
resetd() { : > "$HD/logs/merge-conductor.log"; : > "$HD/logs/ALERTS.log"; : > "$T/gh.txt"
           cp "$T/driver.pristine" "$HD/bin/merge-conductor.sh"; }
# tick <MC_ONLY_PR> — one conductor tick with a 1500 s budget; prints its rc.
tick() {
  ( cd "$T" || exit 9
    export PATH="$HD/fakebin:$HD/bin:$PATH" HARNESS="$HD" HARNESS_ENV_DIR="$HD/env" HARNESS_SECRET=s-fixture \
           JOBS_URL=https://jobs.invalid JOBS_BOX=b GH_SINK="$T/gh.txt" FLEET_CONF="$HD/fleet.conf" \
           MC_REHYDRATE=0 LAND_FIRE=0 MC_ONLY_PR="$1" MC_FULL_TICK_BUDGET_S=1500
    unset GH_TOKEN MC_WORKERS_DONE_BY
    bash "$HD/bin/merge-conductor.sh" >/dev/null 2>"$T/err.txt"; echo $? )
}
mclog() { cat "$HD/logs/merge-conductor.log" 2>/dev/null; }
nlog() { grep -c -- "$1" "$HD/logs/merge-conductor.log" 2>/dev/null || true; }
alerts() { grep -c 'CONDUCTOR MODULE MISSING: bin/lib/mc/tick-scope.sh' "$HD/logs/ALERTS.log" 2>/dev/null || true; }

# D1: the unkeyed run path.
resetd
rc=$(tick '')
[ "$rc" = 0 ] && ok || bad "D1: an unkeyed tick exited $rc (stderr: $(tail -3 "$T/err.txt"))"
[ "$(nlog "$WIN 1500s $TAIL")" = 1 ] && ok || bad "D1: want exactly one '$WIN 1500s' line: $(mclog)"
[ "$(alerts)" = 0 ] && ok || bad "D1: a tick that loaded tick-scope.sh raised CONDUCTOR MODULE MISSING"

# D1 mutation: the driver no longer calls the window, so the line is gone.
resetd
sed -i '/^mc_full_tick_window$/d' "$HD/bin/merge-conductor.sh"
rc=$(tick '')
[ "$(nlog "$WIN")" = 0 ] && ok \
  || bad "D1-mutation: with the call line deleted the window line still appears (rc $rc) — the test does not pin the call"

# D2: a keyed tick gets no window.
resetd
rc=$(tick 'example-org/a#7')
[ "$rc" = 0 ] && ok || bad "D2: a keyed tick exited $rc (stderr: $(tail -3 "$T/err.txt"))"
[ "$(nlog 'keyed tick: 1 key(s)')" = 1 ] && ok || bad "D2: want one 'keyed tick' line: $(mclog)"
[ "$(nlog 'full tick:')" = 0 ] && ok || bad "D2: a keyed tick logged a window line: $(mclog)"

# D3: tick-scope.sh defines the parse and the mode, and not the window (a file
# with the parse and the mode, and no window). The mode stub keeps the
# mc_tick_mode guard clause (BH-6518 C2) satisfied, so the mutation below drops
# the only clause that refuses.
# D3 and its mutation are the last driver cases: they replace the installed
# file and nothing after them needs the real one back.
c0_ts() { cat > "$HD/bin/lib/mc/tick-scope.sh" <<'SH'
#!/bin/bash
# shellcheck shell=bash
mc_keyed_tick_parse() { MC_ONLY_KEYS=""; }
mc_tick_mode() { KILL=0 ACTIONS=0 MERGES=0 MODE=observe; MC_MODE=observe; export MC_MODE; }
SH
}
resetd; c0_ts
rc=$(tick '')
[ "$rc" = 1 ] && ok || bad "D3: a tick with no mc_full_tick_window exited $rc, want 1"
[ "$(alerts)" = 1 ] && ok || bad "D3: want exactly one CONDUCTOR MODULE MISSING line, got $(alerts): $(cat "$HD/logs/ALERTS.log")"
[ "$(nlog 'full tick:')" = 0 ] && ok || bad "D3: a refused tick logged a window line: $(mclog)"
[ ! -s "$T/gh.txt" ] && ok || bad "D3: a refused tick called gh: $(head -3 "$T/gh.txt")"
[ "$(nlog 'bin/lib/mc/tick-scope.sh is missing or unusable — refusing the tick')" = 1 ] && ok \
  || bad "D3: want one refusal line in logs/merge-conductor.log: $(mclog)"

# D3 mutation: drop the new guard clause, and the driver no longer refuses.
resetd; c0_ts
sed -i 's/ || ! declare -F mc_full_tick_window >\/dev\/null//' "$HD/bin/merge-conductor.sh"
if cmp -s "$HD/bin/merge-conductor.sh" "$T/driver.pristine"; then
  bad "D3-mutation: the driver has no 'declare -F mc_full_tick_window' guard clause to drop"
else
  rc=$(tick '')
  [ "$(alerts)" = 0 ] && ok \
    || bad "D3-mutation: with the guard clause dropped the driver still alerted (rc $rc) — the test does not pin the clause"
fi

# ── L1. the closure and the shim ────────────────────────────────────────────
cl=$(scratch_closure_list bin/merge-conductor.sh 2>/dev/null)
grep -qx 'bin/lib/mc/tick-scope.sh' <<<"$cl" && ok \
  || bad "L1: scratch_closure_list bin/merge-conductor.sh does not list bin/lib/mc/tick-scope.sh"
HL="$T/hl"; mkdir -p "$HL"
scratch_install_closure bin/merge-conductor.sh "$HL" >/dev/null || exit 1
shim=$(env -i PATH="$PATH" HARNESS="$HL" bash -c '. "$1" >/dev/null 2>&1; declare -F mc_full_tick_window >/dev/null && echo defined || echo absent' _ "$HL/bin/lib/merge-conductor-lib.sh")
[ "$shim" = absent ] && [ -r "$HL/bin/lib/mc/tick-scope.sh" ] && ok \
  || bad "L1: after sourcing the shim, mc_full_tick_window is '$shim' (file beside it: $([ -r "$HL/bin/lib/mc/tick-scope.sh" ] && echo y || echo n))"

echo "mc-full-tick-window: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
