#!/bin/bash
# tests/pool-bake-cause.bh-6710-test.sh — BH-6710 (BH-6259.1): the slow pool
# bakes on 2026-10-14 had two causes in the build phase, and this suite pins
# the fix for both.
#
# CAUSE A. bin/fly-image-build.sh passed WARM_BUST=<today's UTC date>, so every
# warm layer went cold at 00:00Z and the first propagate tick after midnight
# rebuilt all pools in the serial cold lane (project-3 build=1800s rc=124 at
# 02:20Z). Now the nightly refresh rolls the bust (state/fly/warm-bust), the
# build reads it, and pool_cold compares the last ok bake with its epoch.
# CAUSE B. bin/fly-image-refresh.sh baked with no lock, alongside the propagate
# bake lanes (project-2 build=198s alone, 1473s under contention, same
# layer key). Now it holds locks/fleet-propagate-bake.lock (fd 6), with a
# bounded wait that fails open.
#
#   1-4  bin/lib/warm-bust.sh: round trip, validity window, no partial file.
#   5    the real bin/fly-image-build.sh passes the bust date as WARM_BUST.
#   6    the real bin/fleet-propagate.sh --check routes by the bust epoch.
#   7-9  the real bin/fly-image-refresh.sh waits for the bake lock, fails open
#        on a bounded wait, and rolls the bust.
#
# Run from anywhere: tests/pool-bake-cause.bh-6710-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/warm-bust.sh"
# Pinned clock: the refresh at 2026-10-14 05:40Z, and "now" one hour later.
E=$(date -u -d 2026-10-14T05:40:00Z +%s)
NOW_P=$((E + 3600))
wb() { # wb <fn> <args...> — the lib function in a clean shell; output on stdout
  bash -c '. "$1" || exit 99; shift; "$@"' _ "$LIB" "$@" 2>/dev/null
}

# ══ 1 roll then read returns the same date and epoch ═════════════════════════
S1="$T/s1"
wb warm_bust_roll "$S1" "$E"; RC=$?
[ "$RC" = 0 ] && ok || bad "1 warm_bust_roll must succeed (rc=$RC)"
[ "$(cat "$S1/warm-bust" 2>/dev/null)" = "2026-10-14 $E" ] && ok \
  || bad "1 the file must hold '<date> <epoch>' (got '$(cat "$S1/warm-bust" 2>/dev/null)')"
[ "$(wb warm_bust_read "$S1" "$NOW_P")" = "2026-10-14 $E" ] && ok \
  || bad "1 warm_bust_read must return what the roll wrote (got '$(wb warm_bust_read "$S1" "$NOW_P")')"

# ══ 2 a bust of today or yesterday answers ═══════════════════════════════════
S2="$T/s2"; mkdir -p "$S2"
YE=$((E - 86400))
printf '2026-10-13 %s\n' "$YE" > "$S2/warm-bust"
[ "$(wb warm_bust_read "$S2" "$NOW_P")" = "2026-10-13 $YE" ] && ok \
  || bad "2 a bust dated yesterday must answer (got '$(wb warm_bust_read "$S2" "$NOW_P")')"
printf '2026-10-14 %s\n' "$E" > "$S2/warm-bust"
[ "$(wb warm_bust_read "$S2" "$NOW_P")" = "2026-10-14 $E" ] && ok || bad "2 a bust dated today must answer"
# A file written with no trailing newline still parses.
printf '2026-10-14 %s' "$E" > "$S2/warm-bust"
[ "$(wb warm_bust_read "$S2" "$NOW_P")" = "2026-10-14 $E" ] && ok || bad "2 a line with no newline must still answer"

# ══ 3 everything else answers nothing, rc 1 ══════════════════════════════════
no_answer() { # no_answer <label> — the current $S2/warm-bust must not answer
  local out rc
  out=$(wb warm_bust_read "$S2" "$NOW_P"); rc=$?
  [ -z "$out" ] && [ "$rc" = 1 ] && ok || bad "3 $1 must answer nothing with rc 1 (got '$out' rc=$rc)"
}
printf '2026-10-12 %s\n' "$((E - 2*86400))" > "$S2/warm-bust"; no_answer "a bust 2 days old"
printf 'not a bust line\n' > "$S2/warm-bust";                   no_answer "a garbage line"
: > "$S2/warm-bust";                                            no_answer "an empty file"
printf '2026-10-14 %s\n' "$((NOW_P + 60))" > "$S2/warm-bust";   no_answer "an epoch in the future"
printf '2026-10-15 %s\n' "$((E + 86400))" > "$S2/warm-bust";    no_answer "a date in the future"
printf '2026-10-13 %s\n' "$E" > "$S2/warm-bust";                no_answer "a date that is not its epoch's date"
printf '2026-10-14 %s extra\n' "$E" > "$S2/warm-bust";          no_answer "a line with a third field"
rm -f "$S2/warm-bust";                                          no_answer "a missing file"

# ══ 4 the roll leaves no partial file ════════════════════════════════════════
wb warm_bust_roll "$S1" "$((E + 86400))"
[ "$(cat "$S1/warm-bust")" = "2026-10-15 $((E + 86400))" ] && ok || bad "4 a second roll must replace the line"
LEFT=$(find "$S1" -name 'warm-bust?*' 2>/dev/null)
[ -z "$LEFT" ] && ok || bad "4 the roll must leave no tmp file (found: $LEFT)"
RO="$T/ro"; mkdir -p "$RO"; printf '2026-10-14 %s\n' "$E" > "$RO/warm-bust"; chmod 555 "$RO"
if [ "$(id -u)" != 0 ]; then
  wb warm_bust_roll "$RO" "$((E + 86400))"; RC=$?
  [ "$RC" != 0 ] && ok || bad "4 a roll into a read-only dir must fail"
  [ "$(cat "$RO/warm-bust")" = "2026-10-14 $E" ] && ok || bad "4 a failed roll must leave the old bust"
fi
chmod 755 "$RO"
wb warm_bust_roll "$T/s4" "not-an-epoch"; RC=$?
[ "$RC" != 0 ] && [ ! -e "$T/s4/warm-bust" ] && ok || bad "4 a bad epoch must write nothing (rc=$RC)"

# ══ 5 the real fly-image-build.sh passes the bust date ═══════════════════════
H="$T/fib"
mkdir -p "$H/env" "$H/state/fly" "$T/stub" "$T/calls"
scratch_install_closure bin/fly-image-build.sh "$H" >/dev/null || exit 1
cp -r "$DIR/fly" "$H/fly"
printf 'FLY_ORG=testorg\nFLY_API_TOKEN=tok-fixture-1\n' > "$H/env/fly.env"
bash -c ". '$H/bin/lib/bake-deps.sh'; bake_dep_names" | sed 's/$/=1.0.0/' > "$H/state/fly/p.bake"
printf '#!/bin/bash\n[ "$1" = --version ] && echo "2.1.280 (Claude Code)"\n' > "$T/stub/claude"
printf '#!/bin/bash\n[ "$1" = --version ] && echo "codex-cli 0.153.4"\n' > "$T/stub/codex"
printf '#!/bin/bash\nexit 0\n' > "$T/stub/gh"
cat > "$T/stub/fly" <<'EOF'
#!/bin/bash
case "$1 ${2:-}" in
  "apps list") echo '[{"Name": "builder-p"}]' ;;
  deploy*) printf '%s\n' "$@" > "$STUB_CALLS/deploy.argv"; echo "image: registry.fly.io/builder-p:deployment-X" ;;
esac
exit 0
EOF
chmod +x "$T/stub"/*
printf 'p Acme/p - - 2 box 192.0.2.1\n' > "$T/fleet.conf"
fib() { # fib — the real script at the pinned clock; deploy argv in $T/calls/deploy.argv
  rm -f "$T/calls/deploy.argv"
  ( export PATH="$T/stub:$PATH" STUB_CALLS="$T/calls" WARM_BUST_NOW="$NOW_P"
    FLEET_CONF="$T/fleet.conf" GH_TOKEN=tok-fixture-1 HARNESS="$H" "$H/bin/fly-image-build.sh" p ) > "$T/fib.out" 2>&1
  RC=$?
}
argv_has() { grep -qx -- "$1" "$T/calls/deploy.argv" 2>/dev/null; }
# 5a a valid bust dated yesterday: the build reuses yesterday's layer key.
printf '2026-10-13 %s\n' "$YE" > "$H/state/fly/warm-bust"
fib
[ "$RC" = 0 ] && ok || bad "5a the build must succeed (rc=$RC): $(tail -5 "$T/fib.out")"
argv_has 'WARM_BUST=2026-10-13' && ok \
  || bad "5a a valid bust must be the WARM_BUST arg: $(grep WARM_BUST "$T/calls/deploy.argv" 2>/dev/null)"
grep -q '^== warm bust: 2026-10-13 (state) ==$' "$T/fib.out" && ok \
  || bad "5a the build must name the bust and its source: $(grep -i bust "$T/fib.out")"
# 5b no file: the date of the pinned clock, and the source says so.
rm -f "$H/state/fly/warm-bust"
fib
argv_has 'WARM_BUST=2026-10-14' && ok \
  || bad "5b no bust file: WARM_BUST must be today's date: $(grep WARM_BUST "$T/calls/deploy.argv" 2>/dev/null)"
grep -q '^== warm bust: 2026-10-14 (date) ==$' "$T/fib.out" && ok \
  || bad "5b the date fallback must be named: $(grep -i bust "$T/fib.out")"
# 5c a stale bust (2 days) is not read: the date rule again.
printf '2026-10-12 %s\n' "$((E - 2*86400))" > "$H/state/fly/warm-bust"
fib
argv_has 'WARM_BUST=2026-10-14' && ok \
  || bad "5c a stale bust must fall back to the date: $(grep WARM_BUST "$T/calls/deploy.argv" 2>/dev/null)"

# ══ 6 the real fleet-propagate.sh --check routes by the bust epoch ═══════════
# fleet-propagate.sh reads its own clock. One wall-clock read places the bust
# at 23:00Z yesterday, so a bake one minute after it is from YESTERDAY's date:
# cold under the old date rule, warm under the bust rule.
NOW=$(date -u +%s) # determinism: ok the script under test has no clock seam; every fixture epoch below is derived from this one read
MID=$(( NOW - NOW % 86400 ))
BE=$(( MID - 3600 ))
BD=$(date -u -d "@$BE" +%F)
export HARNESS_LANE=test
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
FP="$T/fp"
mkdir -p "$FP/logs" "$FP/state/fly" "$FP/locks" "$FP/flags" "$T/fpbin"
scratch_install_closure bin/fleet-propagate.sh "$FP" >/dev/null || exit 1
scratch_install_closure bin/lib/fleet-paths.sh "$FP" >/dev/null || exit 1
echo hub > "$FP/state/box-id"
printf 'alpha-os Acme/alpha-os - - 2 box-alpha 192.0.2.1\n' > "$FP/fleet.conf"
printf '#!/bin/bash\nexit 1\n' > "$T/fpbin/pgrep"
chmod +x "$T/fpbin"/*
git init -q --bare "$T/origin"
git init -q -b main "$T/src" 2>/dev/null || { git init -q "$T/src"; git -C "$T/src" checkout -q -b main; }
git -C "$T/src" remote add origin "$T/origin"
mkdir -p "$T/src/bin"; echo "echo init" > "$T/src/bin/run-build.sh"
git -C "$T/src" add -A && git -C "$T/src" commit -qm init && git -C "$T/src" push -q origin main
git -C "$T/origin" symbolic-ref HEAD refs/heads/main
git clone -q "$T/origin" "$T/checkout"
echo "echo v1" > "$T/src/bin/run-build.sh"
git -C "$T/src" add -A && git -C "$T/src" commit -qm v1 && git -C "$T/src" push -q origin main
: > "$FP/flags/fly-pool-app-after"; : > "$FP/flags/fly-pool-app-before"
echo "$(( BE + 60 ))" > "$FP/state/fly/after.baked-at"
echo "$(( BE - 60 ))" > "$FP/state/fly/before.baked-at"
fpcheck() {
  ( HARNESS="$FP" HARNESS_CHECKOUT="$T/checkout" FLEET_PROPAGATE_PATH="$T/fpbin:/usr/bin:/bin:/usr/local/bin" \
    POOL_IMAGE_MIN_AGE_MIN=0 bash "$FP/bin/fleet-propagate.sh" --check ) > "$T/fp.out" 2>&1
}
printf '%s %s\n' "$BD" "$BE" > "$FP/state/fly/warm-bust"
fpcheck
grep -qx '    after: bake' "$T/fp.out" && ok \
  || bad "6 a pool baked after the bust epoch (yesterday's date) must be warm: $(grep -E 'after|before|pools' "$T/fp.out")"
grep -qx '    before: bake (cold, serial lane)' "$T/fp.out" && ok \
  || bad "6 a pool baked before the bust epoch must be cold: $(grep -E 'after|before|pools' "$T/fp.out")"
# Edge: a bake stamped exactly at the bust epoch is warm.
echo "$BE" > "$FP/state/fly/after.baked-at"
fpcheck
grep -qx '    after: bake' "$T/fp.out" && ok || bad "6 a bake stamped at the bust epoch must be warm: $(grep after "$T/fp.out")"
# No bust file: the old date rule holds, so the same pool is cold again.
echo "$(( BE + 60 ))" > "$FP/state/fly/after.baked-at"
rm -f "$FP/state/fly/warm-bust"
fpcheck
grep -qx '    after: bake (cold, serial lane)' "$T/fp.out" && ok \
  || bad "6 with no bust file the date rule must hold: $(grep after "$T/fp.out")"
# A garbage bust file is no bust: the date rule again.
echo garbage > "$FP/state/fly/warm-bust"
fpcheck
grep -qx '    after: bake (cold, serial lane)' "$T/fp.out" && ok \
  || bad "6 a garbage bust file must not mark a pool warm: $(grep after "$T/fp.out")"

# ══ 7-9 the real fly-image-refresh.sh: the bake lock and the bust roll ═══════
R="$T/rf"
mkdir -p "$R/logs" "$R/state/fly" "$R/flags" "$R/locks"
scratch_install_closure bin/fly-image-refresh.sh "$R" >/dev/null || exit 1
[ -f "$R/bin/lib/warm-bust.sh" ] && ok || bad "7 the refresh closure must carry bin/lib/warm-bust.sh"
: > "$R/flags/fly-pool-p"
# The build stub records the time it ran relative to the holder's release.
cat > "$R/bin/fly-image-build.sh" <<'EOF'
#!/bin/bash
if [ -e "$RELEASED" ]; then echo "after $1" >> "$BUILD_CALLS"; else echo "before $1" >> "$BUILD_CALLS"; fi
echo "image: registry.fly.io/builder-$1:deployment-Y"
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$R/bin/alert-line.sh"
chmod +x "$R/bin/fly-image-build.sh" "$R/bin/alert-line.sh"
LOCK="$R/locks/fleet-propagate-bake.lock"
refresh() { # refresh <wait-s> — the real lane at the pinned clock
  : > "$T/build.calls"
  ( HARNESS="$R" BUILD_CALLS="$T/build.calls" RELEASED="$T/released" WARM_BUST_NOW="$NOW_P" \
    FLY_IMAGE_REFRESH_LOCK_WAIT_S="$1" bash "$R/bin/fly-image-refresh.sh" ) > "$T/rf.out" 2>&1
}
hold() { # hold <seconds> — a propagate bake step holds fd 6, then marks the release
  rm -f "$T/held" "$T/released"
  ( exec 6>"$LOCK"; flock 6; : > "$T/held"; sleep "$1"; : > "$T/released" ) &  # determinism: ok race-sleep the hold IS the propagate bake step the refresh must wait for; the build stub reads the release marker, not the time
  HOLDER=$!
  local i; for i in $(seq 1 100); do [ -e "$T/held" ] && break; sleep 0.05; done  # determinism: ok race-sleep polls for the holder's marker, bounded at 5 s
}

# 7 the lock is held for 2 s: the build runs only after the release.
hold 2
refresh 30
wait "$HOLDER" 2>/dev/null
[ "$(cat "$T/build.calls")" = "after p" ] && ok \
  || bad "7 the refresh must not bake while a propagate bake step holds the lock (calls: $(cat "$T/build.calls"))"
grep -q 'bake lock taken' "$R/logs/fly-image-refresh.log" && ok \
  || bad "7 the log must say the lock was taken: $(cat "$R/logs/fly-image-refresh.log")"
grep -q 'refreshed: registry.fly.io/builder-p:deployment-Y' "$R/logs/fly-image-refresh.log" && ok \
  || bad "7 the bake must still run and record its ref: $(cat "$R/logs/fly-image-refresh.log")"

# 9 the refresh rolled the bust to the pinned clock.
[ "$(cat "$R/state/fly/warm-bust" 2>/dev/null)" = "2026-10-14 $NOW_P" ] && ok \
  || bad "9 the refresh must roll the bust to its own clock (got '$(cat "$R/state/fly/warm-bust" 2>/dev/null)')"
grep -q 'warm bust rolled to 2026-10-14' "$R/logs/fly-image-refresh.log" && ok \
  || bad "9 the log must name the rolled bust: $(cat "$R/logs/fly-image-refresh.log")"

# 8 the lock is never released within the wait: one line, and the bake runs.
: > "$R/logs/fly-image-refresh.log"
hold 6
refresh 1
[ "$(cat "$T/build.calls")" = "before p" ] && ok \
  || bad "8 a wait that runs out must bake without the lock (calls: $(cat "$T/build.calls"))"
grep -q 'bake lock busy for 1s — baking without it' "$R/logs/fly-image-refresh.log" && ok \
  || bad "8 the fail-open line is missing: $(cat "$R/logs/fly-image-refresh.log")"
grep -q 'bake lock taken' "$R/logs/fly-image-refresh.log" && bad "8 'bake lock taken' must not print when the wait ran out" || ok
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null

# 9b a bust roll that fails (state/fly is a file) logs one line and the bake still runs.
: > "$R/logs/fly-image-refresh.log"
R2="$T/rf2"; mkdir -p "$R2/logs" "$R2/flags" "$R2/locks" "$R2/state"
cp -a "$R/bin" "$R2/bin"
: > "$R2/flags/fly-pool-p"
: > "$R2/state/fly"   # not a directory: the roll cannot write
: > "$T/build.calls"; : > "$T/released"
( HARNESS="$R2" BUILD_CALLS="$T/build.calls" RELEASED="$T/released" WARM_BUST_NOW="$NOW_P" \
  FLY_IMAGE_REFRESH_LOCK_WAIT_S=1 bash "$R2/bin/fly-image-refresh.sh" ) > "$T/rf.out" 2>&1
grep -q 'warm bust NOT rolled' "$R2/logs/fly-image-refresh.log" && ok \
  || bad "9b a failed roll must log one line: $(cat "$R2/logs/fly-image-refresh.log")"
grep -q 'warm bust rolled to' "$R2/logs/fly-image-refresh.log" && bad "9b 'rolled' must not print when the roll failed" || ok
[ "$(cat "$T/build.calls")" = "after p" ] && ok || bad "9b a failed roll must not stop the bake (calls: $(cat "$T/build.calls"))"

# 8b the lock file cannot be opened (locks/ is a file): one line, the bake runs.
R3="$T/rf3"; mkdir -p "$R3/logs" "$R3/flags" "$R3/state/fly"
cp -a "$R/bin" "$R3/bin"
: > "$R3/flags/fly-pool-p"
: > "$R3/locks"
: > "$T/build.calls"
( HARNESS="$R3" BUILD_CALLS="$T/build.calls" RELEASED="$T/released" WARM_BUST_NOW="$NOW_P" \
  FLY_IMAGE_REFRESH_LOCK_WAIT_S=1 bash "$R3/bin/fly-image-refresh.sh" ) > "$T/rf.out" 2>&1
grep -q 'bake lock cannot be opened .* — baking without it' "$R3/logs/fly-image-refresh.log" && ok \
  || bad "8b an unopenable lock must log one line: $(cat "$R3/logs/fly-image-refresh.log")"
[ "$(cat "$T/build.calls")" = "after p" ] && ok || bad "8b an unopenable lock must not stop the bake (calls: $(cat "$T/build.calls"))"

# 8c a bad wait value is named and falls back to 2100; the free lock is taken.
: > "$R/logs/fly-image-refresh.log"
refresh soon
grep -q 'FLY_IMAGE_REFRESH_LOCK_WAIT_S=soon is not a number of seconds — using 2100' "$R/logs/fly-image-refresh.log" && ok \
  || bad "8c a bad wait must be named: $(cat "$R/logs/fly-image-refresh.log")"
grep -q 'bake lock taken' "$R/logs/fly-image-refresh.log" && ok || bad "8c a free lock must be taken: $(cat "$R/logs/fly-image-refresh.log")"

# 8d no pool flag: this hub bakes no pool image, so no lock and no roll.
R4="$T/rf4"; mkdir -p "$R4/logs" "$R4/flags" "$R4/state/fly" "$R4/locks"
cp -a "$R/bin" "$R4/bin"
( HARNESS="$R4" BUILD_CALLS="$T/build.calls" RELEASED="$T/released" WARM_BUST_NOW="$NOW_P" \
  bash "$R4/bin/fly-image-refresh.sh" ) > "$T/rf.out" 2>&1
[ ! -e "$R4/state/fly/warm-bust" ] && [ ! -e "$R4/locks/fleet-propagate-bake.lock" ] && ok \
  || bad "8d a hub with no pool flag must neither lock nor roll"

echo "pool-bake-cause.bh-6710-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
