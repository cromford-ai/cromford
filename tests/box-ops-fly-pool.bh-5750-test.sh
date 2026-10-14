#!/bin/bash
# tests/box-ops-fly-pool.bh-5750-test.sh — the Fly pool handlers in run_op of
# bin/box-ops.sh (BH-5750 C6): fly_pool_cap runs
# `bin/pool-cap.sh --set <p> <n> --apply`; fly_onboard runs
# `bin/fly-onboard.sh <p> [--cap N]` (no --apply exists there, plan A5).
#
# Runs the REAL bin/box-ops.sh tick, bin/jobs-client.sh, bin/alert-line.sh
# and their libs in a scratch harness root. Stubbed: bin/pool-cap.sh and
# bin/fly-onboard.sh (record argv to $T/argv.log, print $T/stub-out, exit
# $STUB_RC; the lines are the real scripts' output shapes), curl (the jobs
# worker), bin/box-name.sh and bin/hub-lease.sh (this box holds the hub lease).
#   F5  fly_pool_cap: argv --set pa 5 --apply; rc 0 ok; rc 2 fail refused
#   F5b a bad cap (0, -1, "3", absent) or project: refused bad args, nothing runs
#   F6  fly_onboard: the stub runs once; rc 3 fail; rc 0 OK ok; rc 1 fail; --cap N passes
#   F6  rc 0 with the lock line (no verdict): fail already running (lock held)
#   F6b a bad onboard project or cap: nothing runs
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

for f in "$DIR/bin/box-ops.sh" "$DIR/bin/pool-cap.sh" "$DIR/bin/fly-onboard.sh"; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/state" "$H/env" "$T/fakebin"
# The stub goes in FIRST: scratch_install_closure keeps a file already there.
for s in pool-cap fly-onboard; do
  cat > "$H/bin/$s.sh" <<'EOF2'
#!/bin/bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "$STUB_DIR/argv.log"
[ -f "$STUB_DIR/stub-out" ] && cat "$STUB_DIR/stub-out"
exit "${STUB_RC:-0}"
EOF2
  chmod +x "$H/bin/$s.sh"
done
for s in bin/box-ops.sh bin/jobs-client.sh bin/alert-line.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: closure install $s"; exit 1; }
done
: > "$H/env/global.env"
: > "$H/logs/ALERTS.log"
cat > "$H/bin/hub-lease.sh" <<'EOF'
#!/bin/bash
[ "${1:-}" = check ] || exit 2
exit 0
EOF
cat > "$H/bin/box-name.sh" <<'EOF'
#!/bin/bash
echo b1
EOF
chmod +x "$H/bin/hub-lease.sh" "$H/bin/box-name.sh"

# The worker, by path. A claim pops the next line of $T/queue.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
method=GET; body=""; url=""; prev=""
for a in "$@"; do
  case "$prev" in -X) method=$a ;; --data-binary|-d) body=$a ;; esac
  case "$a" in http*://*) url=$a ;; esac
  prev=$a
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
path="/${url#*://*/}"; path="${path%%\?*}"
case "$path" in
  /api/box-commands/claim)
    printf '%s %s %s\n' "$method" "$path" "$body" >> "$STUB_DIR/requests.log"
    ans='{"command":null}'
    if [ -s "$STUB_DIR/queue" ]; then ans=$(head -1 "$STUB_DIR/queue"); sed -i 1d "$STUB_DIR/queue"; fi
    printf '%s\n%s' "$ans" 200 ;;
  /api/box-commands/*/result)
    printf '%s %s %s\n' "$method" "$path" "$body" >> "$STUB_DIR/requests.log"
    printf '%s\n%s' '{"ok":true}' 200 ;;
  *)
    printf '%s %s %s\n' "$method" "$path" "$body" >> "$STUB_DIR/other.log"
    printf '%s\n%s' '{}' 404 ;;
esac
EOF
chmod +x "$T/fakebin/curl"
export STUB_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=tok-fixture-secret
export JOBS_URL=https://jobs.fixture JOBS_RETRIES=0

row() { # row <type> <target> <args-json>
  jq -nc --arg t "$1" --arg tg "$2" --argjson a "$3" \
    '{command:{id:1, box:"hub", type:$t, target:$tg, args:$a, reason:"fixture", status:"claimed", claimed_by:"b1"}}'
}
reset() {
  rm -f "$T/requests.log" "$T/other.log" "$T/queue" "$T/argv.log" "$T/stub-out" "$H/logs/box-ops.log"
  unset STUB_RC STUB_SLEEP BOX_OPS_ORGO_TIMEOUT_S BOX_OPS_REPO_ROOT
}
out() { printf '%s\n' "$@" > "$T/stub-out"; }
run() { bash "$H/bin/box-ops.sh" > "$T/out" 2>&1; RC=$?; }
result() { grep ' /api/box-commands/1/result ' "$T/requests.log" 2>/dev/null | tail -1 | cut -d' ' -f3-; }
okv()    { result | jq -r '.ok'; }
detail() { result | jq -r '.detail'; }
argv()   { cat "$T/argv.log" 2>/dev/null; }
calls()  { if [ -f "$T/argv.log" ]; then wc -l < "$T/argv.log"; else echo 0; fi; }
expect() { # expect <case> <true|false> <detail substring>
  [ "$RC" = 0 ] && ok || bad "$1 rc=$RC ($(cat "$T/out"))"
  [ "$(okv)" = "$2" ] && ok || bad "$1 ok is not $2: $(result)"
  detail | grep -qF -- "$3" && ok || bad "$1 detail lacks '$3': $(detail)"
}
nocall() { [ "$(calls)" = 0 ] && ok || bad "$1: a pool stub ran: $(argv)"; }
starts() { case "$(detail)" in "$2"*) ok ;; *) bad "$1 detail does not start '$2': $(detail)" ;; esac; }

# ── F5 fly_pool_cap ──────────────────────────────────────────────────────
reset; row fly_pool_cap pa '{"cap":5}' > "$T/queue"; out 'SET cap pa 3->5'; run
expect F5 true 'SET cap pa 3->5'
[ "$(argv)" = "pool-cap.sh --set pa 5 --apply" ] && ok || bad "F5 argv: $(argv)"

reset; row fly_pool_cap pa '{"cap":5}' > "$T/queue"; out 'pool-cap: pa is not on the pool (no flags/fly-pool-pa); nothing written'
STUB_RC=2 run
expect "F5 rc2" false 'refused: pool-cap: pa is not on the pool'

reset; row fly_pool_cap pa '{"cap":5}' > "$T/queue"; out 'odd'; STUB_RC=1 run
expect "F5 rc1" false 'pool-cap rc=1'

# ── F5b bad cap args ─────────────────────────────────────────────────────
for a in '{"cap":0}' '{"cap":-1}' '{"cap":"3"}' '{}' '{"cap":2.5}'; do
  reset; row fly_pool_cap pa "$a" > "$T/queue"; out 'SET cap pa 3->5'; run
  expect "F5b $a" false 'refused: bad args'; nocall "F5b $a"
done
for tg in 'pa;id' '' '../pa'; do
  reset; row fly_pool_cap "$tg" '{"cap":5}' > "$T/queue"; out 'SET cap pa 3->5'; run
  expect "F5b '$tg'" false 'refused: bad target'; nocall "F5b '$tg'"
done

# ── F6 fly_onboard ───────────────────────────────────────────────────────
reset; row fly_onboard pa '{"cap":2}' > "$T/queue"
out "refused on b1: fly-onboard runs only on the hub (node-hub): it mints org tokens from the hub's flyctl session and writes hub-side routing flags. Queue it instead: bin/load-project.sh <owner/repo> --fly, or add 'pa' to fly/onboard-queue.conf and merge."
STUB_RC=3 run
expect "F6 rc3" false 'refused on b1: fly-onboard runs only on the hub'
[ "$(calls)" = 1 ] && ok || bad "F6 rc3 calls=$(calls)"
[ "$(argv)" = "fly-onboard.sh pa --cap 2" ] && ok || bad "F6 argv: $(argv)"
grep -q -- '--apply' <<<"$(argv)" && bad "F6 fly-onboard got --apply" || ok

OKL='FLY_ONBOARD pa OK: /root/harness/flags/fly-pool-pa=present(cap 2) /root/harness/flags/builder-fly-pa=present free-slots="pa 0/2"'
reset; row fly_onboard pa '{}' > "$T/queue"; out 'start (cap 2)' "$OKL"; run
expect "F6 ok" true "$OKL"
[ "$(argv)" = "fly-onboard.sh pa" ] && ok || bad "F6 ok argv: $(argv)"

FL='FLY_ONBOARD pa FAILED: /root/harness/flags/fly-pool-pa=absent /root/harness/flags/builder-fly-pa=absent free-slots=""'
reset; row fly_onboard pa '{}' > "$T/queue"; out "$FL"; STUB_RC=1 run
expect "F6 rc1" false "$FL"

reset; row fly_onboard pa '{}' > "$T/queue"; out 'usage: fly-onboard.sh <project> [--cap N]   (N = a positive integer)'; STUB_RC=2 run
expect "F6 rc2" false 'refused: usage'

# rc 0 without a verdict line is a skipped run, not an onboard (D9)
reset; row fly_onboard pa '{}' > "$T/queue"
out 'another fly-onboard for pa is running (locks/fly-onboard-pa.lock held) — not starting a second'; run
expect "F6 lock" false 'already running (lock held)'
reset; row fly_onboard pa '{}' > "$T/queue"
out 'FLY_ONBOARD pa ALREADY: /root/harness/flags/fly-pool-pa=present(cap 2) /root/harness/flags/builder-fly-pa=present free-slots="pa 0/2"'; run
expect "F6 already" true 'FLY_ONBOARD pa ALREADY'

# ── F6b bad onboard args ─────────────────────────────────────────────────
for a in '{"cap":0}' '{"cap":"2"}'; do
  reset; row fly_onboard pa "$a" > "$T/queue"; out "$OKL"; run
  expect "F6b $a" false 'refused: bad args'; nocall "F6b $a"
done
reset; row fly_onboard 'pa x' '{}' > "$T/queue"; out "$OKL"; run
expect "F6b target" false 'refused: bad target'; nocall "F6b target"

echo "box-ops-fly-pool.bh-5750: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
