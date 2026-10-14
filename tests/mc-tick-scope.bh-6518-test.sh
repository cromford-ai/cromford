#!/bin/bash
# tests/mc-tick-scope.bh-6518-test.sh — BH-6518: the conductor's keyed-tick
# parse (MC_ONLY_PR -> MC_ONLY_KEYS, BH-1387/BH-1841) lives in
# bin/lib/mc/tick-scope.sh as mc_keyed_tick_parse. The driver sources it, calls
# it, and refuses the tick when it is missing or unusable.
#
#   P1-P8  the parse, sourced alone: the exact MC_ONLY_KEYS, the exact log line
#          (or none), and whether mc_tick_metrics was replaced. Inputs are the
#          shapes bin/wake-loop.sh and bin/lib/keyed-wake.sh write.
#   D1     the closure scanner follows the driver's source line to the file.
#   D2     the real driver (production entry point) with MC_ONLY_PR=garbage
#          exits 0 and logs the ignored line once; with the call line deleted
#          it does not.
#   D3     the file is gone: rc 1, one CONDUCTOR MODULE MISSING alert, no tick
#          line, no gh call.
#   D4     the file parses but defines no mc_keyed_tick_parse: rc 1, one alert.
#   L1     the file is not a module: no "# module:" header, not in MODULES, and
#          the shim (bin/lib/merge-conductor-lib.sh) never defines the function.
# Run from anywhere: tests/mc-tick-scope.bh-6518-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
TS="$DIR/bin/lib/mc/tick-scope.sh"
DRIVER="$DIR/bin/merge-conductor.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ── P1-P8. the parse, sourced alone ─────────────────────────────────────────
# parse_case <MC_ONLY_PR or the word UNSET> — prints three lines:
#   keys=[<MC_ONLY_KEYS>]  log=[<every mc_log line, | joined>]  metrics=<REAL|noop>
mkdir -p "$T/p8"; : > "$T/p8/x#1"
parse_case() {
  ( cd "$T/p8" || exit 9
    LOGF="$T/p.log"; : > "$LOGF"
    mc_log() { printf '%s\n' "$*" >> "$LOGF"; }
    mc_tick_metrics() { echo REAL; }
    if [ "$1" = UNSET ]; then unset MC_ONLY_PR; else MC_ONLY_PR="$1"; fi
    # shellcheck source=bin/lib/mc/tick-scope.sh
    . "$TS" || exit 8
    mc_keyed_tick_parse
    printf 'keys=[%s]\n' "$MC_ONLY_KEYS"
    printf 'log=[%s]\n' "$(paste -sd'|' "$LOGF")"
    m=$(mc_tick_metrics); printf 'metrics=%s\n' "${m:-noop}" )
}
want_case() { # want_case <id> <input> <keys> <log> <metrics>
  local got want
  got=$(parse_case "$2" 2>&1)
  want=$(printf 'keys=[%s]\nlog=[%s]\nmetrics=%s' "$3" "$4" "$5")
  [ "$got" = "$want" ] && ok || bad "$1: MC_ONLY_PR=$2
--- want
$want
--- got
$got"
}
IGN="holds no owner/repo#number key — running the full tick"
want_case P1 UNSET '' '' REAL
want_case P2 '' '' '' REAL
want_case P3 'example-org/a#7' ' example-org/a#7 ' 'keyed tick: 1 key(s) — example-org/a#7' noop
want_case P4 'example-org/A#7,example-org/a#7,o/b#9' ' example-org/a#7 o/b#9 ' 'keyed tick: 2 key(s) — example-org/A#7,o/b#9' noop
want_case P5 'garbage' '' "MC_ONLY_PR ignored: 'garbage' $IGN" REAL
want_case P6 'example-org/a#abc' '' "MC_ONLY_PR ignored: 'example-org/a#abc' $IGN" REAL
want_case P7 'o/a#1, o/b#2' ' o/a#1 ' 'keyed tick: 1 key(s) — o/a#1' noop
want_case P8 '*#1' ' *#1 ' 'keyed tick: 1 key(s) — *#1' noop

# ── D1. the closure follows the driver's literal source line ────────────────
scratch_closure_list bin/merge-conductor.sh 2>/dev/null | grep -qx 'bin/lib/mc/tick-scope.sh' && ok \
  || bad "D1: scratch_closure_list bin/merge-conductor.sh does not list bin/lib/mc/tick-scope.sh"

# ── D2-D4. the real driver ──────────────────────────────────────────────────
HD="$T/hd"
mkdir -p "$HD/logs" "$HD/state" "$HD/flags" "$HD/locks" "$HD/builds" "$HD/env" "$HD/fakebin"
scratch_install_closure bin/merge-conductor.sh "$HD" >/dev/null || exit 1
scratch_install_closure bin/alert-line.sh "$HD" >/dev/null || exit 1
[ -r "$HD/bin/merge-conductor.sh" ] || { echo "FAIL: the closure did not install $DRIVER"; exit 1; }
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
# tick — one conductor tick with MC_ONLY_PR=garbage; prints its rc.
tick() {
  ( cd "$T" || exit 9
    export PATH="$HD/fakebin:$HD/bin:$PATH" HARNESS="$HD" HARNESS_ENV_DIR="$HD/env" HARNESS_SECRET=s-fixture \
           JOBS_URL=https://jobs.invalid JOBS_BOX=b GH_SINK="$T/gh.txt" FLEET_CONF="$HD/fleet.conf" \
           MC_REHYDRATE=0 LAND_FIRE=0 MC_ONLY_PR=garbage
    unset GH_TOKEN
    bash "$HD/bin/merge-conductor.sh" >/dev/null 2>"$T/err.txt"; echo $? )
}
mclog() { cat "$HD/logs/merge-conductor.log" 2>/dev/null; }
nlog() { grep -c -- "$1" "$HD/logs/merge-conductor.log" 2>/dev/null || true; }
# A refused tick stops AT the guard: it never reaches the call or mc_init's
# readers. Without this, a guard that alerts and falls through still dies with
# rc 1, later, on `set -u` (MC_ONLY_KEYS unbound), and looks like a refusal.
past_guard() { grep -E 'mc_keyed_tick_parse: command not found|unbound variable' "$T/err.txt" 2>/dev/null; }
refused_line() { nlog 'bin/lib/mc/tick-scope.sh is missing or unusable — refusing the tick'; }
alerts() { grep -c 'CONDUCTOR MODULE MISSING: bin/lib/mc/tick-scope.sh' "$HD/logs/ALERTS.log" 2>/dev/null || true; }

# D2: the run path.
resetd
rc=$(tick)
[ "$rc" = 0 ] && ok || bad "D2: a tick with tick-scope.sh exited $rc (stderr: $(tail -3 "$T/err.txt"))"
[ "$(nlog "MC_ONLY_PR ignored: 'garbage'")" = 1 ] && ok || bad "D2: want one 'MC_ONLY_PR ignored' line: $(mclog)"
[ "$(alerts)" = 0 ] && ok || bad "D2: a tick that loaded tick-scope.sh raised CONDUCTOR MODULE MISSING"

# D2 mutation: the driver no longer calls the parse, so the line is gone.
resetd
sed -i '/^mc_keyed_tick_parse$/d' "$HD/bin/merge-conductor.sh"
rc=$(tick)
[ "$(nlog "MC_ONLY_PR ignored: 'garbage'")" = 0 ] && ok \
  || bad "D2-mutation: with the call line deleted the ignored line still appears (rc $rc) — the test does not pin the call"

# D3: the file is gone.
resetd; scratch_rm "$HD/bin/lib/mc/tick-scope.sh" 2>/dev/null || rm -f "$HD/bin/lib/mc/tick-scope.sh"
rc=$(tick)
[ "$rc" = 1 ] && ok || bad "D3: a tick with no tick-scope.sh exited $rc, want 1"
[ "$(alerts)" = 1 ] && ok || bad "D3: want exactly one CONDUCTOR MODULE MISSING line, got $(alerts): $(cat "$HD/logs/ALERTS.log")"
[ "$(nlog 'keyed tick:')" = 0 ] && [ "$(nlog 'full tick:')" = 0 ] && [ "$(nlog 'MC_ONLY_PR ignored')" = 0 ] && ok \
  || bad "D3: a refused tick still logged a tick line: $(mclog)"
[ ! -s "$T/gh.txt" ] && ok || bad "D3: a refused tick called gh: $(head -3 "$T/gh.txt")"
[ -z "$(past_guard)" ] && ok || bad "D3: the driver ran past the refusal: $(past_guard)"
[ "$(refused_line)" = 1 ] && ok || bad "D3: want one refusal line in logs/merge-conductor.log: $(mclog)"

# D4: the file parses but defines no function.
resetd; printf '#!/bin/bash\n# shellcheck shell=bash\n: tick-scope without its function\n' > "$HD/bin/lib/mc/tick-scope.sh"
rc=$(tick)
[ "$rc" = 1 ] && ok || bad "D4: a tick with an unusable tick-scope.sh exited $rc, want 1"
[ "$(alerts)" = 1 ] && ok || bad "D4: want exactly one CONDUCTOR MODULE MISSING line, got $(alerts)"
[ ! -s "$T/gh.txt" ] && ok || bad "D4: a refused tick called gh: $(head -3 "$T/gh.txt")"
[ -z "$(past_guard)" ] && ok || bad "D4: the driver ran past the refusal: $(past_guard)"

# ── L1. not a module ────────────────────────────────────────────────────────
if [ -r "$TS" ]; then
  grep -q '^# module:' <<<"$(head -30 "$TS")" && bad "L1: bin/lib/mc/tick-scope.sh has a '# module:' header" || ok
else
  bad "L1: bin/lib/mc/tick-scope.sh is missing"
fi
grep -qx 'tick-scope' "$DIR/bin/lib/mc/MODULES" 2>/dev/null && bad "L1: bin/lib/mc/MODULES lists tick-scope" || ok
HL="$T/hl"; mkdir -p "$HL"
# The driver's closure: the shim AND tick-scope.sh sit side by side, as on a box.
scratch_install_closure bin/merge-conductor.sh "$HL" >/dev/null || exit 1
shim=$(env -i PATH="$PATH" HARNESS="$HL" bash -c '. "$1" >/dev/null 2>&1; declare -F mc_keyed_tick_parse >/dev/null && echo defined || echo absent' _ "$HL/bin/lib/merge-conductor-lib.sh")
[ "$shim" = absent ] && [ -r "$HL/bin/lib/mc/tick-scope.sh" ] && ok || bad "L1: after sourcing the shim, mc_keyed_tick_parse is '$shim' (file beside it: $([ -r "$HL/bin/lib/mc/tick-scope.sh" ] && echo y || echo n))"

echo "mc-tick-scope: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
