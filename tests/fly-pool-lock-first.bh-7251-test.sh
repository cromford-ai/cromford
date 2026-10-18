#!/bin/bash
# tests/fly-pool-lock-first.bh-7251-test.sh — BH-7251 part 1: a fly-pool.sh
# start that finds its per-project lock held exits before it sources any lib.
# A duplicate start costs one bash process (plus flock and the log line), not
# a lib load.
#
# Every lib fly-pool.sh sources is replaced by a SENTINEL stub that touches
# $SENT/<name>. env-path.sh, the first one, then exits 0, so a run that gets
# past the lock ends right there.
#
#   L1 the lock held by an outside flock: rc 0, no sentinel, one `already
#      running` line.
#   L2 control: the lock free -> the env-path.sh sentinel exists, rc 0.
#   L3 the lock held, locks/ and logs/ present: no mkdir runs.
#   L4 no flag file: rc 0, no lock file is created, no sentinel.
#
# Run: bash tests/fly-pool-lock-first.bh-7251-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
# waitfor <cond> — poll, 30 s at most. A bound for a stuck holder, not a timing claim.
waitfor() { local i=0; until eval "$1"; do i=$((i + 1)); [ "$i" -ge 150 ] && return 1; sleep 0.2; done; return 0; }
lines() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }

FH="$T/f"; SENT="$T/sent"; SHIM="$T/shim"
setup() {
  [ -e "$FH" ] && scratch_rm "$FH"
  [ -e "$SENT" ] && scratch_rm "$SENT"
  mkdir -p "$FH/bin/lib" "$FH/logs" "$FH/flags" "$FH/locks" "$FH/env" "$SENT" "$SHIM"
  : > "$FH/flags/fly-pool-p"; : > "$FH/env/fly.env"
  local n
  for n in env-path.sh lane-gate.sh fly-token.sh verdict-parse.sh execute-empty.sh; do
    printf 'touch "%s/%s"\n' "$SENT" "$n" > "$FH/bin/lib/$n"
  done
  echo 'exit 0' >> "$FH/bin/lib/env-path.sh"
  printf '#!/bin/bash\ntouch "%s/pool-cap"\necho 0\n' "$SENT" > "$FH/bin/pool-cap.sh"
  chmod +x "$FH/bin/pool-cap.sh"
  # A mkdir that counts its calls, then does the real work.
  printf '#!/bin/bash\necho x >> "%s/mkdir-calls"\nexec %s "$@"\n' "$T" "$(command -v mkdir)" > "$SHIM/mkdir"
  chmod +x "$SHIM/mkdir"
  : > "$T/mkdir-calls"
}
frun() { ( export HARNESS="$FH" PATH="$SHIM:$PATH" TMPDIR="$T"
           unset FLY_API_TOKEN FLY_API_TOKEN_P FLY_ACCESS_TOKEN
           bash "$DIR/bin/fly-pool.sh" p >/dev/null 2>&1 ) ; }
sentinels() { ls -A "$SENT" 2>/dev/null | tr '\n' ' '; }
hold() {
  rm -f "$T/held"
  flock "$FH/locks/fly-pool-p.lock" bash -c "touch '$T/held'; while [ ! -e '$T/release' ]; do sleep 0.1; done" &
  HOLDER=$!
  waitfor '[ -e "$T/held" ]' || bad "setup: the outside flock never took the lock"
}
release() { touch "$T/release"; wait "$HOLDER" 2>/dev/null; rm -f "$T/release"; }

# ── L1 + L3: the lock held ──────────────────────────────────────────────────
setup
hold
: > "$T/mkdir-calls"
frun; RC=$?
release
check "L1 a held-lock start exits rc 0 (rc=$RC)" '[ "$RC" = 0 ]'
check "L1 a held-lock start sources no lib (sentinels: $(sentinels))" '[ -z "$(sentinels)" ]'
check "L1 exactly one 'already running' line ($(lines 'already running' "$FH/logs/fly-pool.log"))" \
  '[ "$(lines "already running" "$FH/logs/fly-pool.log")" = 1 ]'
check "L3 a held-lock start with locks/ and logs/ present runs no mkdir ($(grep -c . "$T/mkdir-calls") calls)" \
  '[ "$(grep -c . "$T/mkdir-calls")" = 0 ]'

# ── L2: the lock free (control: the sentinel works) ─────────────────────────
setup
frun; RC=$?
check "L2 a free-lock start exits rc 0 at the env-path stub (rc=$RC)" '[ "$RC" = 0 ]'
check "L2 a free-lock start sources env-path.sh (sentinels: $(sentinels))" '[ -e "$SENT/env-path.sh" ]'
check "L2 a free-lock start writes no 'already running' line" \
  '[ "$(lines "already running" "$FH/logs/fly-pool.log")" = 0 ]'

# ── L2b: locks/ and logs/ missing -> created, then the run continues ────────
setup
scratch_rm "$FH/locks"; scratch_rm "$FH/logs"
frun; RC=$?
check "L2b missing locks/ and logs/ are created (rc=$RC)" '[ -d "$FH/locks" ] && [ -d "$FH/logs" ]'
check "L2b the run then passes the lock (sentinels: $(sentinels))" '[ -e "$SENT/env-path.sh" ]'

# ── L4: no flag file ────────────────────────────────────────────────────────
setup
rm -f "$FH/flags/fly-pool-p"
frun; RC=$?
check "L4 no flag: rc 0 (rc=$RC)" '[ "$RC" = 0 ]'
check "L4 no flag: no lock file is created" '[ ! -e "$FH/locks/fly-pool-p.lock" ]'
check "L4 no flag: no lib is sourced (sentinels: $(sentinels))" '[ -z "$(sentinels)" ]'

echo "fly-pool-lock-first.bh-7251: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
