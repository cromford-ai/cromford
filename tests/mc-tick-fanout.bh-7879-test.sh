#!/bin/bash
# tests/mc-tick-fanout.bh-7879-test.sh — BH-7879 (BH-6518 C4): the conductor's
# per-project fan-out (the held-page flush, the project gate, one backgrounded
# tick_project subshell per fleet.conf project under the BH-5463 full-tick
# lock, and the final wait) lives in bin/lib/mc/tick-scope.sh as
# mc_tick_fanout. The driver calls it at the old place and refuses the tick
# when tick-scope.sh does not define it. tick_project stays in the driver
# (BH-685).
#
#   F1     two projects: both ticked, each with its own counter files named
#          merge-conductor.<p>.<pid> and prs-count.<p>.<pid> (two pids), the
#          files gone after the call, one PR-SNAPSHOT line per project and one
#          gh_rest_etag_report call per project.
#   F2     MC_ONLY_PROJECT=b ticks only b; a keyed tick ticks only the
#          projects whose repo mc_only_slug accepts.
#   F3     a's full-tick lock held from outside: an unkeyed tick logs one
#          `TICK a skipped:` line and still ticks b; a keyed tick and
#          MC_FULL_TICK_SINGLE=0 tick a.
#   F4     MC_PROJ_GATE as tick_project sees it: 0 on a machine, 0 on a
#          take-back, 0 when mc_fly_project_none says no fly project, 1 when it
#          says one, 1 when it is not defined.
#   F5     the held-page flush: a fleet tick calls mc_hold_tick_begin with no
#          argument before the first tick_project; a keyed tick calls it with
#          --load-only when the lib knows the flag, and not at all when not.
#   M1     mutation: with `tick_project "$P"` deleted from a scratch copy of
#          tick-scope.sh, F1's "both projects ticked" check fails.
#   D1     the real driver (production entry point) over a one-project fleet
#          exits 0 and leaves the full-tick lock file; with the call line
#          deleted no lock file appears.
#   D2     tick-scope.sh with the other four functions and no mc_tick_fanout
#          (and with mc_tick_fanout only a variable): rc 1, one CONDUCTOR
#          MODULE MISSING alert, no gh call; with the new guard clause dropped
#          the driver does not refuse.
#   L1     the shim (bin/lib/merge-conductor-lib.sh) never defines
#          mc_tick_fanout.
# Run from anywhere: tests/mc-tick-fanout.bh-7879-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
TS="$DIR/bin/lib/mc/tick-scope.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
[ -r "$TS" ] || { echo "FAIL: bin/lib/mc/tick-scope.sh is missing"; exit 1; }

# ── F1-F5. the fan-out, sourced alone ───────────────────────────────────────
# Each case gets its own dir C (set by nc, in this shell) used as H: a stub
# fleet of projects a and b (repos example-org/a and example-org/b), its own lock,
# tick and counter dirs. No case reads another's files.
NCASE=0
nc() {
  NCASE=$((NCASE+1)); C="$T/case$NCASE"
  mkdir -p "$C/bin" "$C/tick" "$C/locks" "$C/state/gh-etag/counts"
  cat > "$C/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1" in
  --projects) printf 'a\nb\n' ;;
  *) [ "${2:-}" = repo ] && printf 'example-org/%s\n' "$1" ;;
esac
SH
  chmod +x "$C/bin/fleet-conf.sh"
}
# fan <ts-file> <setup-shell-text> [VAR=value...] — runs mc_tick_fanout from
# <ts-file> in a clean subshell with stub collaborators, in case dir $C. In
# it: seq.txt (one line per tick_project and mc_hold_tick_begin call, in
# order), log.txt (mc_log lines), etag.txt (gh_rest_etag_report arguments)
# and rc.
fan() {
  local ts="$1" setup="$2"; shift 2
  ( H="$C"; MC_TICK_DIR="$C/tick"; MC_LOCK_DIR="$C/locks"
    MC_FLEET_SWEEPS=1; MC_ONLY_KEYS=""
    unset MC_ONLY_PROJECT MC_ON_MACHINE MC_PROJ_TAKEBACK MC_FULL_TICK_SINGLE MC_PROJ_GATE
    for kv in "$@"; do printf -v "${kv%%=*}" '%s' "${kv#*=}"; done
    mc_log() { printf '%s\n' "$*" >> "$C/log.txt"; }
    mc_safe_name() { printf '%s' "$1"; }
    mc_only_slug() { [ "$1" = example-org/b ]; }
    gh_rest_etag_report() { printf '%s\n' "$*" >> "$C/etag.txt"; }
    tick_project() {
      printf 'tick %s gate=%s etag=%s prs=%s\n' "$1" "${MC_PROJ_GATE-unset}" "$GH_ETAG_COUNT_FILE" "$PRS_COUNT_FILE" >> "$C/seq.txt"
      : > "$GH_ETAG_COUNT_FILE"; printf 'HIT x\n' > "$PRS_COUNT_FILE"
      SLUG="example-org/$1"
    }
    eval "$setup"
    # shellcheck source=bin/lib/mc/tick-scope.sh
    . "$ts" || exit 8
    mc_tick_fanout
    echo "$?" > "$C/rc" )
}
nl_() { grep -c -- "$2" "$1" 2>/dev/null || true; }
# hold <file> / release — another process holds a flock on <file>.
hold() {
  flock -x "$1" sleep 60 & HP=$!
  local i; for i in $(seq 1 50); do flock -n "$1" true 2>/dev/null || return 0; sleep 0.1; done
  bad "hold: the holder never took $1"
}
release() { kill "$HP" 2>/dev/null; wait "$HP" 2>/dev/null; }

# F1: both projects, their counter files, the snapshot and ETag lines.
f1_ticked() { [ "$(nl_ "$C/seq.txt" '^tick a ')" = 1 ] && [ "$(nl_ "$C/seq.txt" '^tick b ')" = 1 ]; }
nc; fan "$TS" ''
f1_ticked && ok || bad "F1: want a and b ticked once each, got: $(cat "$C/seq.txt" 2>/dev/null)"
pa=$(sed -n 's|^tick a .*etag=.*/merge-conductor\.a\.\([0-9][0-9]*\) prs=.*/prs-count\.a\.\([0-9][0-9]*\)$|\1 \2|p' "$C/seq.txt" 2>/dev/null)
pb=$(sed -n 's|^tick b .*etag=.*/merge-conductor\.b\.\([0-9][0-9]*\) prs=.*/prs-count\.b\.\([0-9][0-9]*\)$|\1 \2|p' "$C/seq.txt" 2>/dev/null)
read -r pa1 pa2 <<<"$pa"; read -r pb1 pb2 <<<"$pb"
[ -n "${pa1:-}" ] && [ -n "${pb1:-}" ] && [ "$pa1" = "${pa2:-}" ] && [ "$pb1" = "${pb2:-}" ] && [ "$pa1" != "$pb1" ] \
  && ok || bad "F1: want merge-conductor.<p>.<pid> and prs-count.<p>.<pid>, one pid per project, two pids, got: $(cat "$C/seq.txt" 2>/dev/null)"
case "$(grep '^tick a ' "$C/seq.txt" 2>/dev/null)" in
  *"etag=$C/state/gh-etag/counts/merge-conductor.a."*" prs=$C/tick/prs-count.a."*) ok ;;
  *) bad "F1: counter files not under state/gh-etag/counts and MC_TICK_DIR: $(cat "$C/seq.txt" 2>/dev/null)" ;;
esac
left=$(find "$C/state/gh-etag/counts" "$C/tick" -type f | wc -l)
[ "$left" = 0 ] && ok || bad "F1: $left counter file(s) left after the fan-out returned"
[ "$(nl_ "$C/log.txt" '^example-org/a PR-SNAPSHOT hit=1 miss=0$')" = 1 ] && [ "$(nl_ "$C/log.txt" '^example-org/b PR-SNAPSHOT hit=1 miss=0$')" = 1 ] \
  && ok || bad "F1: want one PR-SNAPSHOT hit=1 miss=0 line per project: $(cat "$C/log.txt" 2>/dev/null)"
[ "$(sort "$C/etag.txt" 2>/dev/null | tr '\n' ' ')" = "merge-conductor:a merge-conductor:b " ] \
  && ok || bad "F1: want gh_rest_etag_report for merge-conductor:a and :b, got: $(cat "$C/etag.txt" 2>/dev/null)"
[ "$(cat "$C/rc" 2>/dev/null)" = 0 ] && ok || bad "F1: the fan-out returned '$(cat "$C/rc" 2>/dev/null)'"

# M1: delete the tick_project call in a scratch copy; F1's tick check must fail.
cp "$TS" "$T/ts-m1.sh"
sed -i '/^      tick_project "\$P"$/d' "$T/ts-m1.sh"
if cmp -s "$TS" "$T/ts-m1.sh"; then
  bad "M1: tick-scope.sh has no 'tick_project \"\$P\"' line to delete"
else
  nc; fan "$T/ts-m1.sh" ''
  f1_ticked && bad "M1: with tick_project deleted F1 still passes — F1 does not pin the call" || ok
fi

# F2: the project filters.
nc; fan "$TS" '' MC_ONLY_PROJECT=b
[ "$(nl_ "$C/seq.txt" '^tick ')" = 1 ] && [ "$(nl_ "$C/seq.txt" '^tick b ')" = 1 ] \
  && ok || bad "F2: MC_ONLY_PROJECT=b: want only b ticked, got: $(cat "$C/seq.txt" 2>/dev/null)"
nc; fan "$TS" '' MC_FLEET_SWEEPS=0 'MC_ONLY_KEYS= example-org/b#3 '
[ "$(nl_ "$C/seq.txt" '^tick ')" = 1 ] && [ "$(nl_ "$C/seq.txt" '^tick b ')" = 1 ] \
  && ok || bad "F2: keyed on b: want only b ticked, got: $(cat "$C/seq.txt" 2>/dev/null)"

# F3: the full-tick lock, held by another process.
SKIP_A='^TICK a skipped: another full tick of a is still running'
nc; hold "$C/locks/merge-conductor-a-fulltick.lock"; fan "$TS" ''; release
[ "$(nl_ "$C/log.txt" "$SKIP_A")" = 1 ] && ok || bad "F3: held + unkeyed: want one 'TICK a skipped' line: $(cat "$C/log.txt" 2>/dev/null)"
[ "$(nl_ "$C/seq.txt" '^tick a ')" = 0 ] && [ "$(nl_ "$C/seq.txt" '^tick b ')" = 1 ] \
  && ok || bad "F3: held + unkeyed: want a skipped and b ticked, got: $(cat "$C/seq.txt" 2>/dev/null)"
[ "$(cat "$C/rc" 2>/dev/null)" = 0 ] && ok || bad "F3: held + unkeyed: the fan-out returned '$(cat "$C/rc" 2>/dev/null)'"
nc; hold "$C/locks/merge-conductor-a-fulltick.lock"
fan "$TS" 'mc_only_slug() { return 0; }' MC_FLEET_SWEEPS=0 'MC_ONLY_KEYS= example-org/a#7 '; release
[ "$(nl_ "$C/seq.txt" '^tick a ')" = 1 ] && [ "$(nl_ "$C/log.txt" "$SKIP_A")" = 0 ] \
  && ok || bad "F3: held + keyed: want a ticked and no skip line, got: $(cat "$C/seq.txt" "$C/log.txt" 2>/dev/null)"
nc; hold "$C/locks/merge-conductor-a-fulltick.lock"; fan "$TS" '' MC_FULL_TICK_SINGLE=0; release
[ "$(nl_ "$C/seq.txt" '^tick a ')" = 1 ] && [ "$(nl_ "$C/log.txt" "$SKIP_A")" = 0 ] \
  && ok || bad "F3: held + MC_FULL_TICK_SINGLE=0: want a ticked and no skip line, got: $(cat "$C/seq.txt" "$C/log.txt" 2>/dev/null)"
nc; fan "$TS" ''
[ -e "$C/locks/merge-conductor-a-fulltick.lock" ] && flock -n "$C/locks/merge-conductor-a-fulltick.lock" true \
  && ok || bad "F3: an unkeyed tick must leave a's lock file, released"

# F4: the project gate tick_project sees.
gate() { sed -n 's/^tick a gate=\([^ ]*\) .*/\1/p' "$C/seq.txt" 2>/dev/null; }
nc; fan "$TS" 'mc_fly_project_none() { return 1; }' MC_ON_MACHINE=1
[ "$(gate)" = 0 ] && ok || bad "F4: MC_ON_MACHINE=1: want gate 0, got '$(gate)'"
nc; fan "$TS" 'mc_fly_project_none() { return 1; }' MC_PROJ_TAKEBACK=1
[ "$(gate)" = 0 ] && ok || bad "F4: MC_PROJ_TAKEBACK=1: want gate 0, got '$(gate)'"
nc; fan "$TS" 'mc_fly_project_none() { return 0; }'
[ "$(gate)" = 0 ] && ok || bad "F4: no fly project: want gate 0, got '$(gate)'"
nc; fan "$TS" 'mc_fly_project_none() { return 1; }'
[ "$(gate)" = 1 ] && ok || bad "F4: a fly project: want gate 1, got '$(gate)'"
nc; fan "$TS" 'unset -f mc_fly_project_none'
[ "$(gate)" = 1 ] && ok || bad "F4: no mc_fly_project_none: want gate 1, got '$(gate)'"

# F5: the held-page flush, before the first worker forks.
# shellcheck disable=SC2016
HB_NEW='mc_hold_tick_begin() { case "${1:-}" in --load-only) echo "hold load-only" ;; *) echo "hold full" ;; esac >> "$C/seq.txt"; }'
# shellcheck disable=SC2016
HB_OLD='mc_hold_tick_begin() { echo "hold ${1:-full}" >> "$C/seq.txt"; }'
nc; fan "$TS" "$HB_NEW"
[ "$(head -1 "$C/seq.txt" 2>/dev/null)" = "hold full" ] && [ "$(nl_ "$C/seq.txt" '^hold')" = 1 ] \
  && ok || bad "F5: fleet tick: want one 'hold full' line before the first tick, got: $(cat "$C/seq.txt" 2>/dev/null)"
nc; fan "$TS" "$HB_NEW" MC_FLEET_SWEEPS=0
[ "$(head -1 "$C/seq.txt" 2>/dev/null)" = "hold load-only" ] && [ "$(nl_ "$C/seq.txt" '^hold')" = 1 ] \
  && ok || bad "F5: keyed tick, new lib: want one 'hold load-only' line first, got: $(cat "$C/seq.txt" 2>/dev/null)"
nc; fan "$TS" "$HB_OLD" MC_FLEET_SWEEPS=0
[ "$(nl_ "$C/seq.txt" '^hold')" = 0 ] && [ "$(nl_ "$C/seq.txt" '^tick ')" = 2 ] \
  && ok || bad "F5: keyed tick, old lib: want no hold call and two ticks, got: $(cat "$C/seq.txt" 2>/dev/null)"

# ── D1-D2. the real driver ──────────────────────────────────────────────────
HD="$T/hd"
mkdir -p "$HD/logs" "$HD/state" "$HD/flags" "$HD/locks" "$HD/builds" "$HD/env" "$HD/fakebin" "$T/repos/fx/.git"
scratch_install_closure bin/merge-conductor.sh "$HD" >/dev/null || exit 1
scratch_install_closure bin/alert-line.sh "$HD" >/dev/null || exit 1
# The fan-out reads the fleet through bin/fleet-conf.sh, which the driver's
# closure does not carry.
scratch_install_closure bin/fleet-conf.sh "$HD" >/dev/null || exit 1
[ -x "$HD/bin/fleet-conf.sh" ] || { echo "FAIL: the closure did not install bin/fleet-conf.sh"; exit 1; }
[ -r "$HD/bin/merge-conductor.sh" ] || { echo "FAIL: the closure did not install bin/merge-conductor.sh"; exit 1; }
cp "$HD/bin/merge-conductor.sh" "$T/driver.pristine" || exit 1
printf 'fx example-org/fx https://fx.example /api/board 2 local\n' > "$HD/fleet.conf"
cat > "$HD/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
exit 0
SH
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$HD/fakebin/curl"
printf '#!/bin/bash\nexit 0\n' > "$HD/fakebin/git"
chmod +x "$HD/fakebin/gh" "$HD/fakebin/curl" "$HD/fakebin/git"
LOCKF="$HD/locks/merge-conductor-fx-fulltick.lock"
resetd() { : > "$HD/logs/merge-conductor.log"; : > "$HD/logs/ALERTS.log"; : > "$T/gh.txt"
           rm -f "$LOCKF"; cp "$T/driver.pristine" "$HD/bin/merge-conductor.sh"; }
# tick — one unkeyed conductor tick; prints its rc.
tick() {
  ( cd "$T" || exit 9
    export PATH="$HD/fakebin:$HD/bin:$PATH" HARNESS="$HD" HARNESS_ENV_DIR="$HD/env" HARNESS_SECRET=s-fixture \
           JOBS_URL=https://jobs.invalid JOBS_BOX=b GH_SINK="$T/gh.txt" FLEET_CONF="$HD/fleet.conf" \
           MC_REPOS="$T/repos" MC_REHYDRATE=0 LAND_FIRE=0 MC_ONLY_PR='' MC_FULL_TICK_BUDGET_S=1500 \
           MC_MAIN_RED_DETECT=0 MC_TICK_SECS=0 PR_SNAPSHOT=0
    unset GH_TOKEN MC_WORKERS_DONE_BY MC_MODE MC_TICK_ID
    timeout 120 bash "$HD/bin/merge-conductor.sh" >/dev/null 2>"$T/err.txt"; echo $? )
}
mclog() { cat "$HD/logs/merge-conductor.log" 2>/dev/null; }
alerts() { grep -c 'CONDUCTOR MODULE MISSING: bin/lib/mc/tick-scope.sh' "$HD/logs/ALERTS.log" 2>/dev/null || true; }

# D1: the real tick runs the fan-out: the project's full-tick lock file exists.
resetd
rc=$(tick)
[ "$rc" = 0 ] && ok || bad "D1: a one-project tick exited $rc (stderr: $(tail -3 "$T/err.txt"))"
[ -e "$LOCKF" ] && ok || bad "D1: want locks/merge-conductor-fx-fulltick.lock after a tick: $(mclog | tail -5)"
[ "$(alerts)" = 0 ] && ok || bad "D1: a tick that loaded tick-scope.sh raised CONDUCTOR MODULE MISSING"

# D1 mutation: the driver no longer calls the fan-out, so no lock file appears.
resetd
sed -i '/^mc_tick_fanout$/d' "$HD/bin/merge-conductor.sh"
if cmp -s "$HD/bin/merge-conductor.sh" "$T/driver.pristine"; then
  bad "D1-mutation: the driver has no 'mc_tick_fanout' call line to delete"
else
  rc=$(tick)
  [ ! -e "$LOCKF" ] && ok \
    || bad "D1-mutation: with the call line deleted the lock file still appears (rc $rc) — the test does not pin the call"
fi

# D2: tick-scope.sh defines the other four functions and not the fan-out. D2
# and its mutation are the last driver cases: they replace the installed file
# and nothing after them needs the real one back.
c3_ts() { cat > "$HD/bin/lib/mc/tick-scope.sh" <<SH
#!/bin/bash
# shellcheck shell=bash
mc_keyed_tick_parse() { MC_ONLY_KEYS=""; }
mc_full_tick_window() { :; }
mc_tick_mode() { KILL=0 ACTIONS=0 MERGES=0 MODE=observe; MC_MODE=observe; export MC_MODE; }
mc_tick_prelude() { REBASE_BUDGET=2 REREVIEW_BUDGET=2 MERGE_BUDGET=5 REREVIEW_CAP=0 CAPFILE=/dev/null; MC_TICK_ID=stub; export MC_TICK_ID; }
mc_tick_main_red() { MC_FLEET_SWEEPS=0; }
mc_tick_sweeps() { :; }
${1:-}
SH
}
for variant in none variable; do
  resetd
  if [ "$variant" = variable ]; then c3_ts 'mc_tick_fanout=1'; else c3_ts; fi
  rc=$(tick)
  [ "$rc" = 1 ] && ok || bad "D2 ($variant): a tick with no mc_tick_fanout function exited $rc, want 1"
  [ "$(alerts)" = 1 ] && ok || bad "D2 ($variant): want exactly one CONDUCTOR MODULE MISSING line, got $(alerts): $(cat "$HD/logs/ALERTS.log")"
  [ ! -s "$T/gh.txt" ] && ok || bad "D2 ($variant): a refused tick called gh: $(head -3 "$T/gh.txt")"
  [ ! -e "$LOCKF" ] && ok || bad "D2 ($variant): a refused tick took a full-tick lock"
done

# D2 mutation: drop the new guard clause, and the driver no longer refuses.
resetd; c3_ts
sed -i 's/ || ! declare -F mc_tick_fanout >\/dev\/null//' "$HD/bin/merge-conductor.sh"
if cmp -s "$HD/bin/merge-conductor.sh" "$T/driver.pristine"; then
  bad "D2-mutation: the driver has no 'declare -F mc_tick_fanout' guard clause to drop"
else
  rc=$(tick)
  [ "$(alerts)" = 0 ] && ok \
    || bad "D2-mutation: with the guard clause dropped the driver still alerted (rc $rc) — the test does not pin the clause"
fi

# ── L1. the shim ────────────────────────────────────────────────────────────
HL="$T/hl"; mkdir -p "$HL"
scratch_install_closure bin/merge-conductor.sh "$HL" >/dev/null || exit 1
shim=$(env -i PATH="$PATH" HARNESS="$HL" bash -c '. "$1" >/dev/null 2>&1; declare -F mc_tick_fanout >/dev/null && echo defined || echo absent' _ "$HL/bin/lib/merge-conductor-lib.sh")
[ "$shim" = absent ] && [ -r "$HL/bin/lib/mc/tick-scope.sh" ] && ok \
  || bad "L1: after sourcing the shim, mc_tick_fanout is '$shim' (file beside it: $([ -r "$HL/bin/lib/mc/tick-scope.sh" ] && echo y || echo n))"

echo "mc-tick-fanout: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
