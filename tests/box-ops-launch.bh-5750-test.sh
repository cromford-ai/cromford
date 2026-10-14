#!/bin/bash
# tests/box-ops-launch.bh-5750-test.sh — the launch handlers in run_op of
# bin/box-ops.sh (BH-5750 C5): a claimed box_commands_v2 row of type
# orgo_launch_quote|orgo_launch runs bin/box-launch.sh and posts ok/fail.
#
# Runs the REAL bin/box-ops.sh tick, bin/jobs-client.sh, bin/alert-line.sh
# and their libs in a scratch harness root. Stubbed: bin/box-launch.sh (records
# argv to $T/argv.log, prints $T/stub-out, exits $STUB_RC; its lines are copied
# from what the real bin/box-launch.sh prints), curl (the jobs worker),
# bin/box-name.sh and bin/hub-lease.sh (this box holds the hub lease).
#   L1  quote: argv has --root $BOX_OPS_REPO_ROOT and no --apply; ok; detail has capacity first and the usd_mo summary last
#   L2  launch with figure 40: argv has --root $BOX_OPS_REPO_ROOT --apply --confirm-monthly-usd 40
#   L3  rc 3: fail NEEDS PURCHASE, the lines first
#   L4  rc 4: fail WAITING (the register PR must merge)
#   L5  launch with no figure: refused no confirmed price, nothing runs
#   L6  rc 0 + "box-launch: <id> already running": fail already running (lock held)
#   L7  a missing/bad spec or project: refused bad args, nothing runs
#   L8  rc 2 COST: on a launch: fail refused: COST:
#   L9  BOX_OPS_REPO_ROOT unset, not a checkout, missing, or the live harness
#       root (even as a git checkout): quote and launch fail not configured,
#       and box-launch never runs, so no Orgo computer is bought
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

for f in "$DIR/bin/box-ops.sh" "$DIR/bin/box-launch.sh"; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/state" "$H/env" "$T/fakebin"
# The stub goes in FIRST: scratch_install_closure keeps a file already there.
cat > "$H/bin/box-launch.sh" <<'EOF2'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/argv.log"
[ -f "$STUB_DIR/stub-out" ] && cat "$STUB_DIR/stub-out"
exit "${STUB_RC:-0}"
EOF2
chmod +x "$H/bin/box-launch.sh"
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

# A git checkout for box-launch --root, and a plain directory that is not one.
RR="$T/repo-root"; mkdir -p "$RR" "$T/plain-dir"
git -C "$RR" init -q -b main || { echo "FAIL: git fixture"; exit 1; }

row() { # row <type> <target> <args-json>
  jq -nc --arg t "$1" --arg tg "$2" --argjson a "$3" \
    '{command:{id:1, box:"hub", type:$t, target:$tg, args:$a, reason:"fixture", status:"claimed", claimed_by:"b1"}}'
}
reset() {
  rm -f "$T/requests.log" "$T/other.log" "$T/queue" "$T/argv.log" "$T/stub-out" "$H/logs/box-ops.log"
  unset STUB_RC STUB_SLEEP BOX_OPS_ORGO_TIMEOUT_S BOX_OPS_REPO_ROOT
  export BOX_OPS_REPO_ROOT="$RR"
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
nocall() { [ "$(calls)" = 0 ] && ok || bad "$1: the box-launch stub ran: $(argv)"; }
starts() { case "$(detail)" in "$2"*) ok ;; *) bad "$1 detail does not start '$2': $(detail)" ;; esac; }

SUM_Q='box-launch: box=newbox orgo=- ip=- specs=4c/8gb/50gb usd_mo=40 smoke=PENDING'
CAP='capacity: pool fits 4c/8gb/50gb (used 2 computers, 8 vCPU, 16 GB RAM)'
QA='{"account":"fixture-acct","project":"pa","vcpus":4,"mem_gb":8,"disk_gb":50}'
LA='{"account":"fixture-acct","project":"pa","vcpus":4,"mem_gb":8,"disk_gb":50,"quote_id":51,"confirm_monthly_usd":"40"}'
BASE="newbox --project pa --account fixture-acct --vcpus 4 --mem-gb 8 --disk-gb 50 --root $RR"

# ── L1 quote ─────────────────────────────────────────────────────────────
reset; row orgo_launch_quote newbox "$QA" > "$T/queue"
out "$CAP" 'PLAN create POST /computers name=node-newbox specs=4c/8gb/50gb $40/mo (needs --confirm-monthly-usd 40)' \
    'PLAN running wait for the computer to report running (deadline 900s)' \
    'PLAN register bin/box-register.sh newbox --ip <ip> --project pa --account fixture-cost --apply' "$SUM_Q"
run
expect L1 true 'usd_mo=40'
[ "$(argv)" = "$BASE" ] && ok || bad "L1 argv: $(argv)"
grep -q -- '--apply' <<<"$(argv)" && bad "L1 the quote ran with --apply" || ok
[ "$(detail)" = "$CAP | $SUM_Q" ] && ok || bad "L1 detail: $(detail)"

# ── L2 launch with the confirmed figure ──────────────────────────────────
SUM_L='box-launch: box=newbox orgo=o-fixture-7 ip=192.0.2.40 specs=4c/8gb/50gb usd_mo=40 smoke=PASS'
reset; row orgo_launch newbox "$LA" > "$T/queue"; out "$CAP" "$SUM_L"; run
expect L2 true 'smoke=PASS'
[ "$(argv)" = "$BASE --apply --confirm-monthly-usd 40" ] && ok || bad "L2 argv: $(argv)"

# ── L3 rc 3 NEEDS PURCHASE ───────────────────────────────────────────────
reset; row orgo_launch_quote newbox "$QA" > "$T/queue"
out 'NEEDS PURCHASE: vcpu 2 $20/mo' 'NEEDS PURCHASE: ram-gb 4 $16/mo' "$SUM_Q"; STUB_RC=3 run
expect L3 false 'NEEDS PURCHASE: ram-gb 4 $16/mo'
starts L3 'NEEDS PURCHASE: vcpu 2 $20/mo | NEEDS PURCHASE: ram-gb 4'

# ── L4 rc 4 WAITING ──────────────────────────────────────────────────────
reset; row orgo_launch newbox "$LA" > "$T/queue"
out 'WAITING: commit the box-register change, open its PR, merge it, then re-run' "$SUM_L"; STUB_RC=4 run
expect L4 false 'usd_mo=40'
starts L4 'WAITING: commit the box-register change'

# ── L5 no figure ─────────────────────────────────────────────────────────
reset; row orgo_launch newbox "$QA" > "$T/queue"; out "$SUM_L"; run
expect L5 false 'refused: no confirmed price'; nocall L5

# ── L6 already running ───────────────────────────────────────────────────
reset; row orgo_launch newbox "$LA" > "$T/queue"; out 'box-launch: newbox already running'; run
expect L6 false 'already running (lock held)'

# ── L7 bad args ──────────────────────────────────────────────────────────
for a in '{"account":"fixture-acct","project":"pa","vcpus":4,"mem_gb":8}' \
         '{"account":"fixture-acct","vcpus":4,"mem_gb":8,"disk_gb":50}' \
         '{"account":"fixture-acct","project":"pa;id","vcpus":4,"mem_gb":8,"disk_gb":50}' \
         '{"account":"fixture-acct","project":"pa","vcpus":"4","mem_gb":8,"disk_gb":50}'; do
  reset; row orgo_launch_quote newbox "$a" > "$T/queue"; out "$SUM_Q"; run
  expect "L7 $a" false 'refused: bad args'; nocall "L7 $a"
done
reset; row orgo_launch_quote hub "$QA" > "$T/queue"; out "$SUM_Q"; run
expect "L7 hub" false 'refused: bad target'; nocall "L7 hub"

# ── L8 a moved price on launch ───────────────────────────────────────────
reset; row orgo_launch newbox "$LA" > "$T/queue"
out 'COST: box newbox $44/mo — re-run with --confirm-monthly-usd 44'; STUB_RC=2 run
expect L8 false 'COST: box newbox $44/mo'
starts L8 'refused: COST: box newbox $44/mo'

# ── L9 no usable repo root: nothing runs, nothing is bought ──────────────
for r in unset "$T/plain-dir" "$T/missing-dir" "$H"; do
  for ty in orgo_launch_quote orgo_launch; do
    reset; if [ "$r" = unset ]; then unset BOX_OPS_REPO_ROOT; else export BOX_OPS_REPO_ROOT="$r"; fi
    a=$QA; [ "$ty" = orgo_launch ] && a=$LA
    row "$ty" newbox "$a" > "$T/queue"; out "$CAP" "$SUM_L"; run
    expect "L9 $ty $r" false "not configured: BOX_OPS_REPO_ROOT"; nocall "L9 $ty $r"
  done
done
# the live harness root is refused even when it is a git checkout
git -C "$H" init -q -b main 2>/dev/null
for ty in orgo_launch_quote orgo_launch; do
  a=$QA; [ "$ty" = orgo_launch ] && a=$LA
  reset; export BOX_OPS_REPO_ROOT="$H"; row "$ty" newbox "$a" > "$T/queue"; out "$CAP" "$SUM_L"; run
  expect "L9 $ty harness-git" false "not configured: BOX_OPS_REPO_ROOT"; nocall "L9 $ty harness-git"
done
scratch_rm "$H/.git"

echo "box-ops-launch.bh-5750: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
