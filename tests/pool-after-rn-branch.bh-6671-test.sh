#!/bin/bash
# tests/pool-after-rn-branch.bh-6671-test.sh — BH-6671: the pool `after` gate
# released a child while its parent's PR was open on a `ticket/bh-N-rK` branch.
#
# pool_after_open asked only `pulls?state=open&head=<owner>:ticket/<key>`, and
# GitHub matches head= exactly, so a re-run PR on `ticket/bh-6518-r2` (#6647)
# was invisible: `RELEASED BH-6501: BH-6518 is done` at 2026-10-14 09:37:33Z.
# The parent-done check now also matches an open PR by head ref
# `ticket/<key>(-r<N>)?` or by a title that starts `<KEY>:`.
#
#   R1  parent PR open on ticket/bh-890-r2: the child waits (red before BH-6671)
#   R2  parent PR open on another branch, titled `BH-890: ...`: waits
#   R3  head ref in upper case (TICKET/BH-890-R3): waits
#   R4  no open PR (merged or closed): released, machine spawned
#   R5  near-miss refs and titles never hold the row: released
#   R6  the list read answers 502: no machine, "its PR read did not answer"
#   R7  the match is on page 2 of the list: waits
#   R8  two rows on two blockers read the list ONCE in a tick
#   R9  the self open-PR gate stays on the exact read: a -r2 PR of the row's
#       own key does not park it
#
# Driven through bin/fly-pool.sh against a scratch HARNESS, a fake flyctl, a
# fake gh and a recording jobs client (scaffold of pool-after-release.bh-5967).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_project-5=fixture-fly-token\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"
for L in bin/result-prefix-ok.sh bin/fleet-conf.sh bin/alert-line.sh bin/lib/hold.sh bin/lib/deferral-after.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
# The jobs client RECORDS the queue writes: the row is the thing under test.
# Executed (a setting read) it answers nothing, so every setting falls back.
cat > "$H/bin/jobs-client.sh" <<JC
[ "\${BASH_SOURCE[0]}" = "\$0" ] && exit 1
queue_put()  { printf 'put %s\n' "\$*" >> "$T/q.log"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/q.log"; return 0; }
JC

cat > "$T/fakebin/base64" <<'B64'
#!/bin/bash
REAL=/usr/bin/base64; [ -x "$REAL" ] || REAL=/bin/base64
DEC=0; W0=0; FILE=""
for a in "$@"; do
  case "$a" in
    -d|-D)  DEC=1 ;;
    -w0|-w) W0=1 ;;
    0)      ;;
    -*)     ;;
    *)      FILE="$a" ;;
  esac
done
GNU=0; printf 'eA==' | "$REAL" -d >/dev/null 2>&1 && GNU=1
FLAGS=()
if [ "$DEC" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-d) || FLAGS+=(-D)
elif [ "$W0" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-w0) || FLAGS+=(-b 0)
fi
if [ -n "$FILE" ]; then exec "$REAL" "${FLAGS[@]}" < "$FILE"; fi
exec "$REAL" "${FLAGS[@]}"
B64
chmod +x "$H/bin/"*.sh "$T/fakebin"/*

run_pool() {
  : > "$H/logs/fly-pool.log"; : > "$T/fly-calls"; : > "$T/q.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_project-5=fixture-fly-token FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
write_fly_stub() {
  local result="${1:-}"
  cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
case "\$*" in
  *"machine status"*) echo "State: started" ;;
  *"ssh console"*"head"*"RESULT"*) [ -n "$result" ] && echo "$result" ;;
  *"ssh console"*) : ;;
  *"ssh sftp put"*) : ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
  chmod +x "$T/fakebin/fly"
}
# gh: the repo is visible; every exact head= read answers none; the open-PR
# list page <p> is $T/list-<p>.json ([] when absent, 502 when $T/list-broken
# exists); the hold read finds an ai-build issue with no comments. Every call is
# recorded in $T/gh-calls.
cat > "$T/fakebin/gh" <<GH
#!/bin/bash
echo "\$*" >> "$T/gh-calls"
if [[ "\$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "\$*" == *"issues/10"* ]] && [[ "\$*" != *"-i"* ]]; then
  echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"TS fixture","body":""}'; exit 0
fi
if [[ "\$*" == *"-i"* ]]; then
  if [[ "\$*" == *"repos/example-org/project-5"* ]] && [[ "\$*" != *"/"*"/"*"/"* ]]; then
    printf 'HTTP/1.1 200 OK\\n\\n{"full_name":"example-org/project-5"}\\n'; exit 0
  fi
  if [[ "\$*" == *"pulls?state=open"*"head="* ]]; then printf 'HTTP/1.1 200 OK\\n\\n[]\\n'; exit 0; fi
  if [[ "\$*" =~ pulls\?state=open\&per_page=100\&page=([0-9]+) ]]; then
    if [ -e "$T/list-broken" ]; then printf 'HTTP/1.1 502 Bad Gateway\\n\\n{}\\n'; exit 0; fi
    _f="$T/list-\${BASH_REMATCH[1]}.json"
    printf 'HTTP/1.1 200 OK\\n\\n'; if [ -r "\$_f" ]; then cat "\$_f"; else echo '[]'; fi
    exit 0
  fi
  printf 'HTTP/1.1 404 Not Found\\n\\n{}\\n'; exit 0
fi
exit 0
GH
chmod +x "$T/fakebin/gh"

reset_state() {
  local p
  for p in "$H/state/build-queue/project-5"/*.json \
           "$H/state/fly-pool/project-5"/*.json \
           "$H/state/pool/project-5"/* "$H/builds"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  : > "$H/logs/ALERTS.log"
  return 0
}
QF="$H/state/build-queue/project-5/BH-1016.json"
qf() { jq -r "$1" "$QF" 2>/dev/null || echo no-queue-file; }
spawned() { grep -c 'machine run' "$T/fly-calls" 2>/dev/null; }
log() { grep -E "$1" "$H/logs/fly-pool.log" | tail -3; }
# qwaitk <key> <ticket> [after] — a queued row, waiting on <after> when given.
qwaitk() {
  jq -nc --arg k "$1" --arg t "$2" --arg a "${3:-}" \
    '{ticket_id:$t,key:$k,attempt:1,deferrals:13,deaths:0,enqueued_at:"2026-10-10T13:00:00Z"} + (if $a == "" then {} else {after:$a} end)' \
    > "$H/state/build-queue/project-5/$1.json"
}
# pr_list <page> <ref|title>... — the open-PR list page, one PR per pair.
pr_list() {
  local p="$1"; shift
  jq -nc '[$ARGS.positional as $a | range(0; $a|length; 2) | {number: (1000 + .), title: $a[.+1], head: {ref: $a[.]}}]' \
    --args "$@" > "$T/list-$p.json"
}
fresh() {
  reset_state; write_fly_stub ""; : > "$T/gh-calls"
  rm -f "$T"/list-*.json "$T/list-broken"
}
# held <case> — BH-1016 is held on BH-890: no machine, row unchanged, one line.
held() {
  [ "$(spawned)" = 0 ] && ok || bad "$1: no machine while BH-890's PR is open ($(spawned) spawned)"
  [ "$(qf '.after')" = BH-890 ] && [ "$(qf '.deferrals')" = 13 ] && ok || bad "$1: the row keeps after=BH-890 ($(cat "$QF" 2>/dev/null || echo none))"
  grep -q 'skipping BH-1016: waits for BH-890 (still in flight or its PR is open)' "$H/logs/fly-pool.log" && ok || bad "$1: the line says it waits: $(log BH-1016)"
  grep -q 'RELEASED BH-1016' "$H/logs/fly-pool.log" && bad "$1: THE BUG: released while BH-890's PR is open: $(log RELEASED)" || ok
}
released() {
  grep -q 'RELEASED BH-1016: BH-890 is done (no open PR, nothing in flight)' "$H/logs/fly-pool.log" && ok || bad "$1: released when BH-890 has no open PR: $(log BH-1016)"
  [ "$(spawned)" -ge 1 ] && ok || bad "$1: a machine is spawned in the same tick ($(spawned))"
}

# ── R1: the parent's PR is open on ticket/bh-890-r2 ───────────────────────
fresh; qwaitk BH-1016 1016 BH-890; pr_list 1 ticket/bh-890-r2 "BH-890: fix"
run_pool; held R1

# ── R2: another branch, titled BH-890: ────────────────────────────────────
fresh; qwaitk BH-1016 1016 BH-890; pr_list 1 fix/other "BH-890: fix"
run_pool; held R2
fresh; qwaitk BH-1016 1016 BH-890; pr_list 1 fix/other "bh-890: lower-case key"
run_pool; held R2b

# ── R3: the ref in upper case ─────────────────────────────────────────────
fresh; qwaitk BH-1016 1016 BH-890; pr_list 1 TICKET/BH-890-R3 "something"
run_pool; held R3

# ── R4: the parent merged or closed: no open PR ───────────────────────────
fresh; qwaitk BH-1016 1016 BH-890; pr_list 1
run_pool; released R4
grep -q 'per_page=100&page=1' "$T/gh-calls" && ok || bad "R4: the list was read before the release ($(tr '\n' '|' < "$T/gh-calls"))"

# ── R5: near misses never hold the row ────────────────────────────────────
fresh; qwaitk BH-1016 1016 BH-890
pr_list 1 ticket/bh-8900 "a" ticket/bh-890-0 "b" ticket/bh-890-local "c" ticket/bh-89 "d" \
          x/1 "BH-8900: x" x/2 'Revert "BH-890: x"' x/3 "Follow-up to BH-890" x/4 "bh-8900: y"
run_pool; released R5

# ── R6: the list read does not answer ─────────────────────────────────────
fresh; qwaitk BH-1016 1016 BH-890; : > "$T/list-broken"
run_pool
[ "$(spawned)" = 0 ] && ok || bad "R6: no machine on an unreadable list ($(spawned))"
grep -q 'skipping BH-1016: waits for BH-890, and its PR read did not answer' "$H/logs/fly-pool.log" && ok || bad "R6: the line says the read did not answer: $(log BH-1016)"
[ "$(qf '.after')" = BH-890 ] && ok || bad "R6: the row keeps after ($(cat "$QF" 2>/dev/null || echo none))"

# ── R7: the match is on page 2 ────────────────────────────────────────────
fresh; qwaitk BH-1016 1016 BH-890
_a=(); for _i in $(seq 1 100); do _a+=("other/$_i" "OT-$_i: unrelated"); done
pr_list 1 "${_a[@]}"; pr_list 2 ticket/bh-890-r3 "re-plan"
run_pool; held R7
grep -q 'per_page=100&page=2' "$T/gh-calls" && ok || bad "R7: page 2 was read"

# ── R8: two rows, two blockers, one list read ─────────────────────────────
fresh; qwaitk BH-1016 1016 BH-890; qwaitk BH-1017 1017 BH-900; pr_list 1
run_pool
# The open-PR list is the list under test. BH-7874's unblock rank reads the
# open ai-build ISSUE listing once per tick too, so the count names the
# endpoint; the issue listing is held to once per tick as well.
[ "$(grep -cF 'pulls?state=open&per_page=100&page=1' "$T/gh-calls")" = 1 ] && ok || bad "R8: the list is read once per tick, got $(grep -cF 'pulls?state=open&per_page=100&page=1' "$T/gh-calls")"
[ "$(grep -cF 'issues?state=open&labels=ai-build&per_page=100&page=1' "$T/gh-calls")" -le 1 ] && ok || bad "R8: the issue listing is read at most once per tick, got $(grep -cF 'issues?state=open&labels=ai-build&per_page=100&page=1' "$T/gh-calls")"
grep -q 'RELEASED BH-1016: BH-890 is done' "$H/logs/fly-pool.log" && grep -q 'RELEASED BH-1017: BH-900 is done' "$H/logs/fly-pool.log" && ok \
  || bad "R8: both rows are released: $(log RELEASED)"

# ── R9: the self open-PR gate keeps the exact read ────────────────────────
fresh; qwaitk BH-1016 1016; pr_list 1 ticket/bh-1016-r2 "BH-1016: parked PR"
run_pool
grep -q 'skipping BH-1016: open PR exists' "$H/logs/fly-pool.log" && bad "R9: the self gate must not match a -r2 PR: $(log BH-1016)" || ok
[ "$(spawned)" -ge 1 ] && ok || bad "R9: the row spawns ($(spawned)): $(log BH-1016)"

echo "pool-after-rn-branch.bh-6671: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
