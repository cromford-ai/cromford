#!/bin/bash
# tests/fly-pool-no-flyctl-test.sh — a pool tick on a host with no flyctl.
#
# THE INCIDENT (project-3, 2026-10-21 09:10Z). Cron's PATH is /usr/bin:/bin and the
# Fly hub image puts flyctl in /usr/local/bin (BH-7715). bin/fly-pool.sh set
# FLY=$(command -v fly || command -v flyctl), got nothing, and wrapped the empty
# path: the no-leak wrapper ran `exec ''`, and every flyctl call in the tick
# failed ("machines list unusable (exec: : not found)").
#
# THE ROWS (N1-N3 fail on main):
#   N1  no flyctl anywhere: the tick exits 0, writes no fly-noleak wrapper that
#       execs an empty path, and logs "no flyctl on this host"
#   N2  one alert a day through bin/alert-line.sh, not one per tick
#   N3  flyctl only in an install dir (not on PATH): bin/lib/fly-bin.sh finds it
#       and the tick drives it
#   N4  a stub on FLY_BIN_DIR still wins (the existing test seam)
# Run: HARNESS_TEST_SANDBOX=1 bash tests/fly-pool-no-flyctl-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

setup() { # setup <dir>
  local h="$1"
  mkdir -p "$h/bin/lib/jobs" "$h/logs" "$h/flags" "$h/locks" "$h/env" "$h/state/fly" \
           "$h/state/fly-pool/project-5" "$h/state/build-queue/project-5" "$h/builds" "$h/fakebin" "$h/emptybin" "$h/home"
  cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/result-prefix-ok.sh" "$h/bin/"
  cp "$DIR"/bin/lib/jobs/*.sh "$h/bin/lib/jobs/"
  cp "$DIR/bin/lib/fly-bin.sh" "$h/bin/lib/"  # scratch-closure-allow: fly-bin.sh is the lib under test (unit-tests its lookup)
  cp "$DIR/fleet.conf" "$h/fleet.conf"
  printf 'HARNESS_SECRET=test-secret\n' > "$h/env/global.env"; : > "$h/env/fly.env"
  printf '3\n' > "$h/flags/fly-pool-project-5"; printf 'pool-project-5\n' > "$h/flags/fly-pool-app-project-5"
  printf '{"app":"pool-project-5"}\n' > "$h/state/fly/project-5.json"
  printf '#!/bin/bash\nexit 0\n' > "$h/bin/beat.sh"
  printf '#!/bin/bash\necho "$*" >> "%s/alert-line.log"\n' "$h" > "$h/bin/alert-line.sh"
  printf '#!/bin/bash\nexit 0\n' > "$h/fakebin/flock"
  printf '#!/bin/bash\nshift; exec "$@"\n' > "$h/fakebin/timeout"
  printf '#!/bin/bash\nprintf "{\\"ok\\":true}\\n200\\n"\n' > "$h/fakebin/curl"
  chmod +x "$h/bin/"*.sh "$h/fakebin"/*
}
# A PATH with the system tools but no fly/flyctl anywhere.
SYS=""
for d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
  [ -d "$d" ] || continue
  { [ -x "$d/fly" ] || [ -x "$d/flyctl" ]; } && continue
  SYS="${SYS:+$SYS:}$d"
done
tick() { # tick <dir> [FLY_BIN_DIR] [extra PATH dir]
  local h="$1" fbd="${2:-$1/emptybin}" extra="${3:-}"
  ( export PATH="$h/fakebin${extra:+:$extra}:$SYS" HARNESS="$h" HOME="$h/home" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 FLEET_CONF="$h/fleet.conf" \
           FLY_API_TOKEN_project-5=tok TMPDIR="$h" FLY_BIN_DIR="$fbd" FD_SINK="$h/fly.txt"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 ); echo $?
}

# --- N1 / N2 ----------------------------------------------------------------
H="$T/n1"; setup "$H"
rc=$(tick "$H")
[ "$rc" = 0 ] && ok || bad "N1 no flyctl must exit 0 (got $rc)"
grep -q 'no flyctl on this host' "$H/logs/fly-pool.log" 2>/dev/null && ok || bad "N1 the log must say no flyctl: $(cat "$H/logs/fly-pool.log" 2>/dev/null | tail -2)"
if grep -l "exec ''" "$H"/fly-noleak.* >/dev/null 2>&1; then bad "N1 a wrapper that execs an empty path was written"; else ok; fi
[ "$(grep -c 'pool-noflyctl-project-5' "$H/alert-line.log" 2>/dev/null)" = 1 ] && ok || bad "N2 the first tick raises one alert (got $(grep -c . "$H/alert-line.log" 2>/dev/null))"
tick "$H" >/dev/null
[ "$(grep -c 'pool-noflyctl-project-5' "$H/alert-line.log" 2>/dev/null)" = 1 ] && ok || bad "N2 a second tick the same day must not alert again"

# --- N3: flyctl only in an install dir --------------------------------------
H="$T/n3"; setup "$H"; mkdir -p "$H/home/.fly/bin"
printf '#!/bin/bash\necho "$*" >> "%s/fly.txt"\ncase "$*" in *"machine status"*) echo "State: started";; esac\nexit 0\n' "$H" > "$H/home/.fly/bin/flyctl"
chmod +x "$H/home/.fly/bin/flyctl"
rc=$(tick "$H")
[ "$rc" = 0 ] && ok || bad "N3 the tick must run (rc $rc)"
[ -s "$H/fly.txt" ] && ok || bad "N3 fly-bin.sh must find \$HOME/.fly/bin/flyctl and the tick must drive it"
grep -q 'no flyctl' "$H/logs/fly-pool.log" 2>/dev/null && bad "N3 must not report no flyctl" || ok

# --- N4: the FLY_BIN_DIR stub seam still wins --------------------------------
H="$T/n4"; setup "$H"; mkdir -p "$H/stubdir"
printf '#!/bin/bash\necho "STUB $*" >> "%s/fly.txt"\nexit 0\n' "$H" > "$H/stubdir/fly"; chmod +x "$H/stubdir/fly"
rc=$(tick "$H" "$H/stubdir" "$H/stubdir")
grep -q '^STUB' "$H/fly.txt" 2>/dev/null && ok || bad "N4 a fly stub on PATH must be the one driven"

echo "fly-pool-no-flyctl-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
