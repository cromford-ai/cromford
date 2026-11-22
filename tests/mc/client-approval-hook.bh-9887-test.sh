#!/bin/bash
# tests/mc/client-approval-hook.bh-9887-test.sh — BH-9887 slice C0: a PR head
# that client mode withholds (la_decide rc 1) is told to the product board.
# mc_nhv_gate (bin/lib/mc/classify.sh) calls mc_ca_withheld (fragment
# bin/merge-conductor.d/bh-9887-client-approval.sh), which spawns ONE detached
# bin/client-approval-request.sh per (project, PR, head) while the per-repo
# switch client_approval_board.<owner>.<name> is `on` and the head's marker
# (state/client-approval/<project>/<pr>-<head>.json) is not settled.
#
# WHAT IS DRIVEN. The real classify.sh and the real fragment, sourced in a
# fresh bash with a stub la_decide / la_human_needed / setting_get, and a stub
# bin/client-approval-request.sh that records its argv (no board call here;
# tests/client-approval-request.bh-9887-test.sh drives the real script). H1c
# drives the real bin/merge-conductor.sh tick (tests/lib/nhv-conductor-fixture.sh).
#   H1   rc 1, switch on, actions=1: 1 spawn with project, slug, PR, head, rec,
#        paths; la_humanneeded still called once; MC_NEEDS_HV set
#   H1c  the same through a real conductor tick over a Mergify repo
#   H2   a second gate call on the same head (memo hit): the paths still passed
#   H3   switch off: 0 spawns     H4  marker `done`: 0 spawns
#   H5   marker absent-route younger than the window: 0; older: 1
#   H6   no fragment: the gate behaves as before (MC_NEEDS_HV set, no error)
#   N1-N9 the adversarial negatives: rc 0, rc 2, actions=0, another repo with
#        no row, no build record, a `true`/`ON;` row, an unreadable row, the
#        kill switch, markers cap-spent / no-ticket / not-board
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc/client-approval-hook.bh-9887-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

FRAG="$DIR/bin/merge-conductor.d/bh-9887-client-approval.sh"
U="$T/u"; ROWS="$T/rows"
mkdir -p "$U/bin/lib/mc" "$U/bin/merge-conductor.d" "$U/logs" "$U/state" "$U/builds/project-3-TK-7-1" "$ROWS"
scratch_install_closure bin/lib/mc/classify.sh "$U" >/dev/null || { echo "FAIL: closure of classify.sh"; exit 1; }
[ -r "$DIR/bin/lib/client-approval.sh" ] && { scratch_install_closure bin/lib/client-approval.sh "$U" >/dev/null || exit 1; }
[ -r "$FRAG" ] && cp "$FRAG" "$U/bin/merge-conductor.d/"
REC="$U/builds/project-3-TK-7-1"
printf '{"ticket_id":"tk_77"}\n' > "$REC/job.json"
cat > "$U/bin/client-approval-request.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/spawns.txt"
printf 'HARNESS=%s\n' "\${HARNESS:-}" >> "$T/spawn-env.txt"
EOF
chmod +x "$U/bin/client-approval-request.sh"

HA=aaaaaaaa11aaaaaaaaaaaaaaaaaaaaaaaaaaaa01
HB=bbbbbbbb22bbbbbbbbbbbbbbbbbbbbbbbbbbbb02
PATHS="app/members/page.tsx, lib/mail/send.ts"
SW="client_approval_board.example-org.project-3"

# gate <slug> <num> <head> <actions> [frag=1] [extra snippet] — one or more
# mc_nhv_gate calls in a fresh bash; prints HV=<MC_NEEDS_HV non-empty 0|1>.
gate() {
  local slug="$1" num="$2" head="$3" actions="$4" frag="${5:-1}" extra="${6:-}"
  T="$T" U="$U" ROWS="$ROWS" REC_DIR="$REC" FRAGON="$frag" SLUG="$slug" NUM="$num" HEADX="$head" ACT="$actions" \
  EXTRA="$extra" bash -c '
    H="$U"; MC_H="$U"; MC_LOG="$T/mc.log"
    mc_log() { printf "%s\n" "$*" >> "$MC_LOG"; }
    setting_get() {
      printf "%s\n" "$1" >> "$ROWS/calls"
      [ -e "$ROWS/down" ] && return 1
      [ -r "$ROWS/$1" ] || return 2
      cat "$ROWS/$1"
    }
    la_decide() {
      printf "%s\n" "$*" >> "$T/la-calls.txt"
      LA_REASON="touches member-facing paths: $(cat "$T/la-paths" 2>/dev/null); withheld"
      LA_PROTECTED_PATHS=$(cat "$T/la-paths" 2>/dev/null)
      return "$(cat "$T/la-rc" 2>/dev/null || echo 1)"
    }
    la_human_needed() { printf "%s\n" "$*" >> "$T/lhn-calls.txt"; return 0; }
    . "$U/bin/lib/mc/classify.sh" || exit 9
    if [ "$FRAGON" = 1 ]; then
      for f in "$U"/bin/merge-conductor.d/*.sh; do [ -r "$f" ] && . "$f"; done
    else
      unset -f mc_ca_withheld 2>/dev/null
    fi
    P=project-3; REC="$REC_DIR"; ACTIONS="$ACT"; KILL="${KILLX:-0}"
    MC_LA_MEMO_KEY=""
    eval "$EXTRA"
    mc_nhv_gate "$SLUG" "$NUM" "$HEADX" "$ACT"; echo "rc=$?"
    [ -n "$MC_NEEDS_HV" ] && echo HV=1 || echo HV=0
  ' 2>"$T/gate.err"
}
# spawns_wait <n> — wait (max 5 s) until the stub saw <n> spawns; prints the count.
spawns_n() { if [ -r "$T/spawns.txt" ]; then wc -l < "$T/spawns.txt" | tr -d ' '; else echo 0; fi; }
spawns_wait() {
  local i=0 n=0
  while [ "$i" -lt 50 ]; do
    n=$(spawns_n)
    [ "$n" -ge "$1" ] && break
    sleep 0.1; i=$((i + 1))
  done
  if [ "$1" = 0 ]; then sleep 0.5; n=$(spawns_n); fi
  echo "$n"
}
reset() {
  rm -f "$T/spawns.txt" "$T/spawn-env.txt" "$T/la-calls.txt" "$T/lhn-calls.txt" "$T/mc.log" "$ROWS"/* 2>/dev/null
  scratch_rm "$U/state/client-approval"
  printf '%s' "$PATHS" > "$T/la-paths"; echo 1 > "$T/la-rc"
  printf 'on' > "$ROWS/$SW"
}
mark() { # mark <pr> <head> <status> [age-s]
  local f="$U/state/client-approval/project-3/$1-$2.json"
  mkdir -p "${f%/*}"
  jq -nc --arg s "$3" --arg h "$2" --argjson pr "$1" --argjson c "$(( $(date -u +%s) - ${4:-0} ))" \
    '{v:1,project:"project-3",repo:"example-org/project-3",pr:$pr,head:$h,status:$s,attempts:0,checked_at:$c,approvers:[],comment:"pending",comment_attempts:0}' > "$f"
}

# ── H1 ──────────────────────────────────────────────────────────────────────
reset
out=$(gate example-org/project-3 7 "$HA" 1)
n=$(spawns_wait 1)
[ "$n" = 1 ] && ok || bad "H1: one request spawned for the withheld head (spawns: $n; out: $out; err: $(cat "$T/gate.err"); log: $(cat "$T/mc.log" 2>/dev/null))"
want="project-3 example-org/project-3 7 $HA $REC $PATHS"
[ "$(head -1 "$T/spawns.txt" 2>/dev/null)" = "$want" ] && ok || bad "H1: argv is project slug pr head rec paths (got '$(head -1 "$T/spawns.txt" 2>/dev/null)', want '$want')"
grep -q "^HARNESS=$U\$" "$T/spawn-env.txt" 2>/dev/null && ok || bad "H1: the child runs with HARNESS = the conductor root (got $(cat "$T/spawn-env.txt" 2>/dev/null))"
[ "$(wc -l < "$T/lhn-calls.txt" 2>/dev/null | tr -d ' ')" = 1 ] && ok || bad "H1: la_human_needed still called once"
grep -qx 'HV=1' <<<"$out" && ok || bad "H1: MC_NEEDS_HV set (out: $out)"
grep -q "client-approval request spawned for example-org/project-3#7@${HA:0:8}" "$T/mc.log" 2>/dev/null && ok || bad "H1: one spawned log line (log: $(cat "$T/mc.log" 2>/dev/null))"

# ── H2: memo hit keeps the paths ────────────────────────────────────────────
reset
out=$(gate example-org/project-3 7 "$HA" 1 1 'mc_nhv_gate "$SLUG" "$NUM" "$HEADX" 0; LA_PROTECTED_PATHS=""')
n=$(spawns_wait 1)
[ "$(wc -l < "$T/la-calls.txt" 2>/dev/null | tr -d ' ')" = 1 ] && ok || bad "H2 setup: one la_decide for two gate calls (memo)"
[ "$n" = 1 ] && [ "$(head -1 "$T/spawns.txt" 2>/dev/null)" = "$want" ] && ok || bad "H2: the memo hit hands the same paths (spawns $n: $(cat "$T/spawns.txt" 2>/dev/null))"

# ── H3: switch off ──────────────────────────────────────────────────────────
reset; printf 'off' > "$ROWS/$SW"
out=$(gate example-org/project-3 7 "$HA" 1)
[ "$(spawns_wait 0)" = 0 ] && ok || bad "H3: switch off spawns nothing"
grep -qx 'HV=1' <<<"$out" && ok || bad "H3: the gate itself is unchanged (HV=1)"

# ── H4: marker done ─────────────────────────────────────────────────────────
reset; mark 7 "$HA" done
gate example-org/project-3 7 "$HA" 1 >/dev/null
[ "$(spawns_wait 0)" = 0 ] && ok || bad "H4: a done marker spawns nothing"
# ...and a new head on the same PR is asked again.
gate example-org/project-3 7 "$HB" 1 >/dev/null
[ "$(spawns_wait 1)" = 1 ] && grep -q " $HB " "$T/spawns.txt" && ok || bad "H4b: a new head spawns (spawns: $(cat "$T/spawns.txt" 2>/dev/null))"

# ── H5: absent-route window ─────────────────────────────────────────────────
reset; mark 7 "$HA" absent-route 60
gate example-org/project-3 7 "$HA" 1 >/dev/null
[ "$(spawns_wait 0)" = 0 ] && ok || bad "H5: an absent-route marker 60 s old spawns nothing (window 3600)"
reset; mark 7 "$HA" absent-route 4000
gate example-org/project-3 7 "$HA" 1 >/dev/null
[ "$(spawns_wait 1)" = 1 ] && ok || bad "H5b: an absent-route marker past the window spawns"
reset; mark 7 "$HA" absent-route 120; printf '60' > "$ROWS/client_approval_board.absent_recheck_s"
gate example-org/project-3 7 "$HA" 1 >/dev/null
[ "$(spawns_wait 1)" = 1 ] && ok || bad "H5c: the window is the absent_recheck_s row (60 s), not the fallback"
reset; mark 7 "$HA" failed
gate example-org/project-3 7 "$HA" 1 >/dev/null
[ "$(spawns_wait 1)" = 1 ] && ok || bad "H5d: a failed marker is retried (spawns)"
reset; mark 7 "$HA" sent
gate example-org/project-3 7 "$HA" 1 >/dev/null
[ "$(spawns_wait 1)" = 1 ] && ok || bad "H5e: a sent marker whose comment is pending spawns"

# ── H6: no fragment ─────────────────────────────────────────────────────────
reset
out=$(gate example-org/project-3 7 "$HA" 1 0)
[ "$(spawns_wait 0)" = 0 ] && grep -qx 'HV=1' <<<"$out" && grep -qx 'rc=0' <<<"$out" \
  && ok || bad "H6: without the fragment the gate is as before (out: $out; err: $(cat "$T/gate.err"))"

# ── N1-N9: adversarial negatives ────────────────────────────────────────────
reset; echo 0 > "$T/la-rc"; gate example-org/project-3 7 "$HA" 1 >/dev/null
[ "$(spawns_wait 0)" = 0 ] && ok || bad "N1: la rc 0 spawns nothing"
reset; echo 2 > "$T/la-rc"; gate example-org/project-3 7 "$HA" 1 >/dev/null
[ "$(spawns_wait 0)" = 0 ] && ok || bad "N2: la rc 2 spawns nothing"
reset; gate example-org/project-3 7 "$HA" 0 >/dev/null
[ "$(spawns_wait 0)" = 0 ] && ok || bad "N3: observe mode (actions=0) spawns nothing"
reset; gate example-org/other-os 7 "$HA" 1 >/dev/null
[ "$(spawns_wait 0)" = 0 ] && ok || bad "N4: another repo with no row spawns nothing"
reset; gate example-org/project-3 7 "$HA" 1 1 'REC=""' >/dev/null
[ "$(spawns_wait 0)" = 0 ] && ok || bad "N5: a PR with no build record spawns nothing"
for v in true 1 'on;' onn '' ' ' ; do
  reset; printf '%s' "$v" > "$ROWS/$SW"; gate example-org/project-3 7 "$HA" 1 >/dev/null
  [ "$(spawns_wait 0)" = 0 ] && ok || bad "N6: switch value '$v' is off"
done
reset; printf ' ON \n' > "$ROWS/$SW"; gate example-org/project-3 7 "$HA" 1 >/dev/null
[ "$(spawns_wait 1)" = 1 ] && ok || bad "N6b: ' ON ' is on (trim + lowercase)"
reset; touch "$ROWS/down"; gate example-org/project-3 7 "$HA" 1 >/dev/null
[ "$(spawns_wait 0)" = 0 ] && ok || bad "N7: an unreadable switch is off"
grep -q 'client-approval: switch unreadable for example-org/project-3, off this tick' "$T/mc.log" 2>/dev/null && ok || bad "N7: the unreadable switch is logged (log: $(cat "$T/mc.log" 2>/dev/null))"
reset; gate example-org/project-3 7 "$HA" 1 1 'KILL=1' >/dev/null
[ "$(spawns_wait 0)" = 0 ] && ok || bad "N8: the kill switch spawns nothing"
for s in cap-spent no-ticket not-board; do
  reset; mark 7 "$HA" "$s"; gate example-org/project-3 7 "$HA" 1 >/dev/null
  [ "$(spawns_wait 0)" = 0 ] && ok || bad "N9: a $s marker spawns nothing"
done

# ── H1c: a real conductor tick ──────────────────────────────────────────────
command -v flock >/dev/null || { echo "flock missing — skipping H1c"; echo "client-approval-hook.bh-9887-test: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit; }
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
# shellcheck source=tests/lib/nhv-conductor-fixture.sh
. "$(dirname "$0")/../lib/nhv-conductor-fixture.sh" || exit 1
nhvf_setup || { echo "FAIL: fixture setup"; exit 1; }
mkdir -p "$T/h/bin/merge-conductor.d"
[ -r "$FRAG" ] && cp "$FRAG" "$T/h/bin/merge-conductor.d/"
[ -r "$DIR/bin/lib/client-approval.sh" ] && { scratch_install_closure bin/lib/client-approval.sh "$T/h" >/dev/null || exit 1; }
cp "$U/bin/client-approval-request.sh" "$T/h/bin/client-approval-request.sh"
H41=cccccccc33cccccccccccccccccccccccccccc41
nhvf_pr 41 "$H41"
nhvf_reset
rm -f "$T/spawns.txt" "$T/spawn-env.txt"
# The switch through the real setting_get: the box settings cache (BH-5781).
jq -nc --argjson t "$(date -u +%s)" '{fetched_at:$t,values:{"client_approval_board.example-org.mgfy-os":"on"}}' > "$T/h/state/settings-cache.json"
printf '%s' "$PATHS" > "$T/la-paths"
nhvf_la 1 "touches member-facing paths: $PATHS; withheld until the client decision maker approves (lead_authority_mode=client)"
nhvf_tick
[ "$(nhvf_field 41 2)" = NEEDS_HUMAN_VERDICT ] && ok || bad "H1c setup: the row is NEEDS_HUMAN_VERDICT (got '$(nhvf_field 41 2)')"
n=$(spawns_wait 1)
REC41="$T/h/builds/pool-mgfy-MG-41-2026100100"
[ "$n" = 1 ] && [ "$(head -1 "$T/spawns.txt" 2>/dev/null)" = "mgfy example-org/mgfy-os 41 $H41 $REC41 $PATHS" ] && ok \
  || bad "H1c: the conductor tick spawns one request with the record and paths (spawns $n: $(cat "$T/spawns.txt" 2>/dev/null); log: $(grep -F 'client-approval' "$CLOG" | tail -3))"
grep -q "client-approval request spawned for example-org/mgfy-os#41@${H41:0:8}" "$CLOG" && ok || bad "H1c: the conductor log says spawned"

echo "client-approval-hook.bh-9887-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
