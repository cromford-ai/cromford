#!/bin/bash
# tests/main-red-recheck-stamp.bh-8195-test.sh — BH-8195: a missing
# state/main-red/recheck.last is a first run and prints nothing.
#
#   THE INCIDENT (2026-10-23). On the new hub bh-hub-2 logs/main-red-detector.log
#   showed `bin/main-red-recheck.sh: line 71: .../recheck.last: No such file or
#   directory`. The read was `tr ... < "$STAMPF" 2>/dev/null`: bash applies the
#   `<` before the `2>/dev/null`, so the failed open printed to the cron log. The
#   line read as "the script is missing".
#
#   R1  freeze up, no state/main-red/: no "No such file or directory", the
#       detector runs with --flagged-only, recheck.last holds a number.
#   R2  a second run inside the cadence does not run the detector.
#   R3  a stamp with junk (`abc`) gives a recheck and no error.
#   R4  no freeze up: no detector run and no state dir.
#
# The REAL bin/main-red-recheck.sh runs against a scratch HARNESS with a stub
# detector that records its argv. No JOBS_URL, so the stamp is the file.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/main-red-recheck-stamp.bh-8195-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1: unexpected [$3] in: ${2:0:400}"; else ok; fi; }
yn() { [ -e "$1" ] && echo yes || echo no; }

# newh <name> — a scratch harness with a stub detector; sets H.
newh() {
  H="$T/$1"; mkdir -p "$H/bin" "$H/flags"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/detector.calls"\nexit 0\n' "$H" > "$H/bin/main-red-detector.sh"
  chmod +x "$H/bin/main-red-detector.sh"
}
run() { env -u JOBS_URL -u HARNESS_SECRET -u MAIN_RED_RECHECK_MIN HARNESS="$H" bash "$DIR/bin/main-red-recheck.sh" 2>&1; }
calls() { grep -c . "$H/detector.calls" 2>/dev/null || echo 0; }

# ==== R1: first run with no state dir ==========================================
newh r1; : > "$H/flags/main-red-o-r"
out=$(run); check R1-rc "$?" 0
hasnt R1-no-bash-error "$out" "No such file or directory"
check R1-output-empty "$out" ""
check R1-detector-ran "$(cat "$H/detector.calls" 2>/dev/null)" "--flagged-only"
case "$(cat "$H/state/main-red/recheck.last" 2>/dev/null)" in ''|*[!0-9]*) bad "R1-stamp-numeric" ;; *) ok ;; esac

# ==== R2: a second run inside the cadence reads the stamp =======================
out=$(run); check R2-rc "$?" 0
check R2-output-empty "$out" ""
check R2-no-second-detector-run "$(calls)" 1

# ==== R3: a junk stamp is a recheck, no error ===================================
newh r3; : > "$H/flags/main-red-o-r"
mkdir -p "$H/state/main-red"; printf 'abc\n' > "$H/state/main-red/recheck.last"
out=$(run); check R3-rc "$?" 0
check R3-output-empty "$out" ""
check R3-detector-ran "$(calls)" 1

# ==== R4: no freeze up ==========================================================
newh r4; : > "$H/flags/main-red-detector-off"
out=$(run); check R4-rc "$?" 0
check R4-output-empty "$out" ""
check R4-no-detector "$(calls)" 0
check R4-no-state-dir "$(yn "$H/state/main-red")" no

echo "main-red-recheck-stamp.bh-8195: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
