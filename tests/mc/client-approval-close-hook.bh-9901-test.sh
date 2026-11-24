#!/bin/bash
# tests/mc/client-approval-close-hook.bh-9901-test.sh — BH-9901 (BH-9887
# slice C2): the conductor closes the board approval request of a PR that
# merged or closed. tick_project calls mc_ca_close_tick (fragment
# bin/merge-conductor.d/bh-9901-client-approval-close.sh) after the
# closed/merged settle. It spawns ONE detached bin/client-approval-close.sh per
# PR that has an open request (a C0 marker with a request id), is not on the
# open list, and whose row says MERGED/CLOSED or whose closed-watch memo says
# merged/closed. The switch client_approval_board.<owner>.<name> must be `on`.
#
# WHAT IS DRIVEN. The real fragment, the real bin/lib/client-approval.sh and
# the real mc_row_field / closed_watch_dir (bin/lib/mc/settle.sh), sourced in a
# fresh bash with a stub setting_get and mc_log, and a stub
# bin/client-approval-close.sh that records its argv (no board call here;
# tests/client-approval-close.bh-9901-test.sh drives the real script). K7/K8
# drive the real bin/merge-conductor.sh tick (tests/lib/nhv-conductor-fixture.sh).
#   K1 row MERGED, PR not open -> 1 spawn, argv project slug pr merged
#   K2 row CLOSED -> closed      K3 no row + memo merged -> merged
#   K4 the cap: 12 candidates, close_max_per_tick 10 -> 10 spawns + 1 deferred line
#   K5 a closed marker with hub=pending -> 1 spawn (the hub-only retry)
#   K6 observe mode / kill switch -> a WOULD line, 0 spawns
#   K7 a real conductor tick, empty open list, a MERGED row -> 1 spawn
#   K8 the real tick with no fragment -> no spawn, no error
#   N1-N8 the near misses: 0 spawns each
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc/client-approval-close-hook.bh-9901-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

FRAG="$DIR/bin/merge-conductor.d/bh-9901-client-approval-close.sh"
U="$T/u"; ROWS="$T/rows"
mkdir -p "$U/bin/merge-conductor.d" "$U/logs" "$U/state/merge-conductor/closed-watch" "$ROWS"
for f in bin/lib/client-approval.sh bin/lib/mc/settle.sh bin/lib/mc/locks.sh; do
  scratch_install_closure "$f" "$U" >/dev/null || { echo "FAIL: closure of $f"; exit 1; }
done
[ -r "$FRAG" ] && cp "$FRAG" "$U/bin/merge-conductor.d/" || bad "the fragment exists"
cat > "$U/bin/client-approval-close.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/spawns.txt"
EOF
chmod +x "$U/bin/client-approval-close.sh"
SW="client_approval_board.example-org.project-3"
SLUG=example-org/project-3

# tick <open-nums> [extra snippet] — one mc_ca_close_tick in a fresh bash.
tick() {
  T="$T" U="$U" ROWS="$ROWS" OPENX="$1" EXTRA="${2:-}" bash -c '
    H="$U"; MC_H="$U"; MC_LOG="$T/mc.log"
    MC_STATE_DIR="$U/state/merge-conductor"; MC_ROWS="$MC_STATE_DIR/pr-state.tsv"; MC_CLOSED_WATCH_DIR="$MC_STATE_DIR/closed-watch"
    mc_log() { printf "%s\n" "$*" >> "$MC_LOG"; }
    setting_get() {
      [ -e "$ROWS/down" ] && return 1
      [ -r "$ROWS/$1" ] || return 2
      cat "$ROWS/$1"
    }
    . "$U/bin/lib/mc/locks.sh" || exit 9
    . "$U/bin/lib/mc/settle.sh" || exit 9
    for f in "$U"/bin/merge-conductor.d/*.sh; do [ -r "$f" ] && . "$f"; done
    P=project-3; ACTIONS=1; KILL=0; MC_ONLY_KEYS=""
    eval "$EXTRA"
    mc_ca_close_tick example-org/project-3 "$OPENX"; echo "rc=$?"
  ' 2>"$T/tick.err"
}
spawns_n() { if [ -r "$T/spawns.txt" ]; then wc -l < "$T/spawns.txt" | tr -d ' '; else echo 0; fi; }
spawns_wait() {
  local i=0 n=0
  while [ "$i" -lt 50 ]; do
    n=$(spawns_n); [ "$n" -ge "$1" ] && break
    sleep 0.1; i=$((i + 1))
  done
  if [ "$1" = 0 ]; then sleep 0.3; n=$(spawns_n); fi
  echo "$n"
}
reset() {
  rm -f "$T/spawns.txt" "$T/mc.log" "$ROWS"/* "$U/state/merge-conductor/pr-state.tsv" 2>/dev/null
  scratch_rm "$U/state/client-approval"; scratch_rm "$U/state/merge-conductor/closed-watch"
  mkdir -p "$U/state/merge-conductor/closed-watch"
  printf 'on' > "$ROWS/$SW"
}
hx() { printf '%040x' "$1"; }
# mark <pr> [status] [rid|null] [extra-jq] [project]
mark() {
  local f="$U/state/client-approval/${5:-project-3}/$1-$(hx "$1").json"
  mkdir -p "${f%/*}"
  jq -nc --argjson pr "$1" --arg h "$(hx "$1")" --arg s "${2:-done}" --arg rid "${3:-r-$1}" \
    '{v:1,project:"project-3",repo:"example-org/project-3",pr:$pr,head:$h,ticket_id:"T-\($pr)",status:$s,attempts:0,checked_at:1795000000,
      request_id:(if $rid == "null" then null else $rid end),approvers:[],comment:"posted",comment_attempts:0}' | jq -c "${4:-.}" > "$f"
}
row() { printf '%s#%s\t%s\t0\t%s\t-\t-\t-\thttps://github.com/%s/pull/%s\n' "$SLUG" "$1" "$2" "$(hx "$1")" "$SLUG" "$1" >> "$U/state/merge-conductor/pr-state.tsv"; }
memo() { local d="$U/state/merge-conductor/closed-watch/example-org_project-3"; mkdir -p "$d"; printf '%s\t1795000000\thttps://github.com/%s/pull/%s\t-\n' "$2" "$SLUG" "$1" > "$d/$1"; }

# ── K1-K3 ───────────────────────────────────────────────────────────────────
reset; mark 11; row 11 MERGED
out=$(tick "5 6")
[ "$(spawns_wait 1)" = 1 ] && [ "$(head -1 "$T/spawns.txt")" = "project-3 example-org/project-3 11 merged" ] && ok \
  || bad "K1: one spawn with project slug pr merged (spawns: $(cat "$T/spawns.txt" 2>/dev/null); out: $out; err: $(cat "$T/tick.err"); log: $(cat "$T/mc.log" 2>/dev/null))"
grep -qx 'rc=0' <<<"$out" && ok || bad "K1: rc 0"
grep -q 'client-approval close spawned for example-org/project-3#11 (merged)' "$T/mc.log" 2>/dev/null && ok || bad "K1: the spawned log line"
reset; mark 12; row 12 CLOSED; tick "" >/dev/null
[ "$(spawns_wait 1)" = 1 ] && [ "$(head -1 "$T/spawns.txt")" = "project-3 example-org/project-3 12 closed" ] && ok || bad "K2: row CLOSED -> closed ($(cat "$T/spawns.txt" 2>/dev/null))"
reset; mark 13; memo 13 merged; tick "" >/dev/null
[ "$(spawns_wait 1)" = 1 ] && [ "$(head -1 "$T/spawns.txt")" = "project-3 example-org/project-3 13 merged" ] && ok || bad "K3: no row + memo merged ($(cat "$T/spawns.txt" 2>/dev/null); log: $(cat "$T/mc.log" 2>/dev/null))"
reset; mark 14; memo 14 closed; tick "" >/dev/null
[ "$(spawns_wait 1)" = 1 ] && [ "$(head -1 "$T/spawns.txt")" = "project-3 example-org/project-3 14 closed" ] && ok || bad "K3b: memo closed -> closed"

# ── K4: the cap ─────────────────────────────────────────────────────────────
reset
for n in $(seq 21 32); do mark "$n"; row "$n" MERGED; done
tick "" >/dev/null
[ "$(spawns_wait 10)" = 10 ] && ok || bad "K4: 10 spawns at the default cap (got $(spawns_n))"
sleep 0.3; [ "$(spawns_n)" = 10 ] && ok || bad "K4: not more than 10 (got $(spawns_n))"
grep -q 'client-approval close: 2 more PR(s) deferred to the next tick' "$T/mc.log" && ok || bad "K4: one deferred line ($(cat "$T/mc.log"))"
rm -f "$T/spawns.txt"; printf '3' > "$ROWS/client_approval_board.close_max_per_tick"
tick "" >/dev/null
[ "$(spawns_wait 3)" = 3 ] && { sleep 0.3; [ "$(spawns_n)" = 3 ]; } && ok || bad "K4b: the close_max_per_tick row 3 -> 3 spawns (got $(spawns_n))"

# ── K5: the hub-only retry candidate ────────────────────────────────────────
reset; mark 15 done r-15 '.close = "closed" | .hub = "pending"'; row 15 MERGED; tick "" >/dev/null
[ "$(spawns_wait 1)" = 1 ] && ok || bad "K5: closed + hub pending spawns"

# ── K6: observe mode / kill switch ──────────────────────────────────────────
reset; mark 16; row 16 MERGED; tick "" 'ACTIONS=0' >/dev/null
[ "$(spawns_wait 0)" = 0 ] && ok || bad "K6: observe mode spawns nothing"
grep -q 'WOULD spawn a client-approval close for example-org/project-3#16 (merged)' "$T/mc.log" && ok || bad "K6: a WOULD line"
reset; mark 16; row 16 MERGED; tick "" 'KILL=1' >/dev/null
[ "$(spawns_wait 0)" = 0 ] && ok || bad "K6b: the kill switch spawns nothing"

# ── N1-N8: near misses ──────────────────────────────────────────────────────
reset; mark 41; row 41 MERGED; tick "40 41 42" >/dev/null
[ "$(spawns_wait 0)" = 0 ] && ok || bad "N1: a PR on the open list with a stale MERGED row spawns nothing"
for s in READY QUEUED NEEDS_HUMAN_VERDICT; do
  reset; mark 42; row 42 "$s"; tick "" >/dev/null
  [ "$(spawns_wait 0)" = 0 ] && ok || bad "N2: row $s spawns nothing"
done
for s in open gone; do
  reset; mark 43; memo 43 "$s"; tick "" >/dev/null
  [ "$(spawns_wait 0)" = 0 ] && ok || bad "N3: memo $s spawns nothing"
done
reset; mark 44; tick "" >/dev/null
[ "$(spawns_wait 0)" = 0 ] && ok || bad "N3b: no row and no memo spawns nothing"
[ "$(grep -c '#44 client-approval close: the PR is off the open list' "$T/mc.log")" = 1 ] && ok || bad "N3b: one log line for the unknown end state"
reset; mark 45 done null; row 45 MERGED; tick "" >/dev/null
[ "$(spawns_wait 0)" = 0 ] && ok || bad "N4: a null request id spawns nothing"
for s in absent-route failed cap-spent no-ticket; do
  reset; mark 46 "$s"; row 46 MERGED; tick "" >/dev/null
  [ "$(spawns_wait 0)" = 0 ] && ok || bad "N4b: status $s spawns nothing"
done
for c in 'closed|written' 'gone|written' 'superseded|' 'no-id|' 'cap-spent|'; do
  reset; mark 47 done r-47 ".close = \"${c%%|*}\" | (if \"${c#*|}\" == \"\" then . else .hub = \"${c#*|}\" end)"; row 47 MERGED; tick "" >/dev/null
  [ "$(spawns_wait 0)" = 0 ] && ok || bad "N5: close ${c%%|*} hub ${c#*|} spawns nothing"
done
for v in off true '' DOWN NONE; do
  reset; mark 48; row 48 MERGED
  case "$v" in DOWN) touch "$ROWS/down" ;; NONE) rm -f "$ROWS/$SW" ;; *) printf '%s' "$v" > "$ROWS/$SW" ;; esac
  tick "" >/dev/null
  [ "$(spawns_wait 0)" = 0 ] && ok || bad "N6: switch '$v' spawns nothing"
done
reset; mark 49; row 49 MERGED; tick "" 'MC_ONLY_KEYS="example-org/project-3#49"' >/dev/null
[ "$(spawns_wait 0)" = 0 ] && ok || bad "N7: a keyed tick spawns nothing"
reset; mark 50 done r-50 . other-os; row 50 MERGED; tick "" >/dev/null
[ "$(spawns_wait 0)" = 0 ] && ok || bad "N8: a marker of another project dir spawns nothing"
reset; mark 12; row 12 MERGED; tick "120 121" >/dev/null
[ "$(spawns_wait 1)" = 1 ] && ok || bad "N8b: PR 12 is not open when 120 is (no prefix match)"
reset; mark 120; row 120 MERGED; tick "12" >/dev/null
[ "$(spawns_wait 1)" = 1 ] && grep -qx 'project-3 example-org/project-3 120 merged' "$T/spawns.txt" && ok || bad "N8c: PR 120 is not open when 12 is"

# ── K7/K8: a real conductor tick ────────────────────────────────────────────
command -v flock >/dev/null || { echo "flock missing — skipping K7"; echo "client-approval-close-hook.bh-9901-test: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
# shellcheck source=tests/lib/nhv-conductor-fixture.sh
. "$(dirname "$0")/../lib/nhv-conductor-fixture.sh" || exit 1
nhvf_setup || { echo "FAIL: fixture setup"; exit 1; }
mkdir -p "$T/h/bin/merge-conductor.d"
scratch_install_closure bin/lib/client-approval.sh "$T/h" >/dev/null || exit 1
cp "$U/bin/client-approval-close.sh" "$T/h/bin/client-approval-close.sh"
H61=dddddddd44dddddddddddddddddddddddddddd61
nhvf_pr 61 "$H61"
nhvf_reset
jq -nc --argjson t "$(date -u +%s)" '{fetched_at:$t,values:{"client_approval_board.example-org.mgfy-os":"on"}}' > "$T/h/state/settings-cache.json"
mkdir -p "$T/h/state/client-approval/mgfy"
jq -nc --arg h "$H61" '{v:1,project:"mgfy",repo:"example-org/mgfy-os",pr:61,head:$h,ticket_id:"T-61",status:"done",attempts:0,checked_at:1795000000,request_id:"r-61",approvers:[],comment:"posted",comment_attempts:0}' \
  > "$T/h/state/client-approval/mgfy/61-$H61.json"
# The PR merged: off the open list, its row MERGED.
: > "$T/prs"
awk -F'\t' 'BEGIN{OFS="\t"} $1=="example-org/mgfy-os#61" {$2="MERGED"} {print}' "$ROWS" > "$T/rows.tmp" && mv "$T/rows.tmp" "$ROWS"
[ "$(nhvf_field 61 2)" = MERGED ] && ok || bad "K7 setup: row 61 MERGED (got '$(nhvf_field 61 2)')"
# K8 first: the same tick with no fragment spawns nothing and errs nothing.
rm -f "$T/spawns.txt"
nhvf_tick
[ "$(spawns_wait 0)" = 0 ] && ok || bad "K8: no fragment, no spawn"
grep -q 'mc_ca_close_tick\|client-approval' "$T/tick.err" && bad "K8: no error from the missing hook ($(cat "$T/tick.err"))" || ok
[ -r "$FRAG" ] && cp "$FRAG" "$T/h/bin/merge-conductor.d/"
nhvf_tick
n=$(spawns_wait 1)
[ "$n" = 1 ] && [ "$(head -1 "$T/spawns.txt" 2>/dev/null)" = "mgfy example-org/mgfy-os 61 merged" ] && ok \
  || bad "K7: the conductor tick spawns one close (spawns $n: $(cat "$T/spawns.txt" 2>/dev/null); log: $(grep -F 'client-approval' "$CLOG" | tail -3); err: $(head -5 "$T/tick.err"))"
grep -q "client-approval close spawned for example-org/mgfy-os#61 (merged)" "$CLOG" && ok || bad "K7: the conductor log says spawned"

echo "client-approval-close-hook.bh-9901-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
