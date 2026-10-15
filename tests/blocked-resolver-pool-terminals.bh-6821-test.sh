#!/bin/bash
# tests/blocked-resolver-pool-terminals.bh-6821-test.sh — bin/blocked-resolver.sh
# lists push-rejected pool terminals and comments ONCE on each ticket (BH-6821).
#
# A pool terminal (state/pool/<p>/<KEY>.terminal) used to be visible only in
# fly-pool.log. bin/lib/br-pool-terminals.sh's br_pool_terminal_pass lists each
# one every tick and posts one ticket comment naming the branch and the head.
#
#   R1  one terminal with a ticket_id -> a list line naming branch + sha, one
#       comment POST whose body names both, .terminal-noted touched
#   R2  25 terminals -> 20 comments, 5 named as left for the next tick
#   R3  no ticket_id -> listed, no POST; a board project -> listed, no POST
#   R4  a second tick posts nothing (sentinel); a failed POST leaves no
#       sentinel and the next tick retries
#   R5  observe mode lists and posts nothing
#   R6  one real run of bin/blocked-resolver.sh posts the comment (D2)
#   R7  the lane-run manifests carry the terminal (ro) and the sentinel (rw),
#       and the pass works on a root holding only those files
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SHA=f56eba45f0a1b2c3d4e5f60718293a4b5c6d7e8f
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state/pool/tproj" "$H/state/pool/bproj" "$H/flags" "$H/locks" \
         "$H/env" "$H/builds" "$H/state/merge-conductor" "$H/state/build-queue/tproj" "$T/fakebin"
# tproj is a GitHub-Issues lane (board prefix "-"); bproj is an in-app board.
{ printf 'tproj o/tproj - - 2 box-tproj 192.0.2.9\n'
  printf 'bproj o/bproj https://bproj.example /api/internal 3 box-bproj 192.0.2.8\n'; } > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
scratch_install_closure bin/blocked-resolver.sh "$H" >/dev/null || { echo "FAIL: closure install"; exit 1; }
chmod +x "$H/bin/"*.sh
[ -f "$H/bin/lib/br-pool-terminals.sh" ] && ok \
  || bad "closure: bin/lib/br-pool-terminals.sh is not sourced by bin/blocked-resolver.sh"

# gh stub: an issue-comment POST is recorded (its body copied) and answers
# $T/post-code (default 201). Everything else answers the empty shapes an idle
# resolver tick reads.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  *"-X POST repos/"*"/issues/"*"/comments"*)
    N=\$(( \$(ls "$T"/body.* 2>/dev/null | wc -l) + 1 ))
    for a in "\$@"; do case "\$a" in body=@*) cp "\${a#body=@}" "$T/body.\$N" ;; esac; done
    C=\$(cat "$T/post-code" 2>/dev/null || echo 201)
    printf 'HTTP/1.1 %s X\r\n\r\n{"id":1}\n' "\$C"; exit 0 ;;
  *"-i"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;
esac
echo ""
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
chmod +x "$T/fakebin"/*
export PATH="$T/fakebin:$PATH" GH_TOKEN=""

term() { # term <p> <KEY> [ticket_id]
  jq -nc --arg t "${3:-}" --arg k "$2" --arg s "$SHA" \
    '{branch:("ticket/" + ($k|ascii_downcase)),head_sha:$s,reason:"BUILD_DEFERRED push rejected",created_at:"2026-10-14 23:07:10Z"}
     + (if $t == "" then {} else {ticket_id:$t} end)' > "$H/state/pool/$1/$2.terminal"
}
clean() {
  local p
  for p in "$H/state/pool/tproj"/* "$H/state/pool/bproj"/* "$T"/body.* "$T/gh.txt" "$T/post-code" "$T/say.log"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  : > "$T/gh.txt"; : > "$T/say.log"
}
posts() { ls "$T"/body.* 2>/dev/null | wc -l | tr -d ' '; }
# pass [project] — the lib alone, over the scratch root, with a recording say.
pass() {
  ( export HARNESS="$H" H="$H" OBSERVE="${OBSERVE:-0}"
    say() { printf '%s\n' "$*" >> "$T/say.log"; }
    . "$H/bin/lib/gh-rest.sh" || exit 9
    . "$H/bin/lib/br-pool-terminals.sh" || exit 9
    br_pool_terminal_pass "$@" ) >/dev/null 2>&1
}

# ── R1 ─────────────────────────────────────────────────────────────────────
clean; term tproj BH-77 77
pass
grep -q "tproj/BH-77: push-rejected terminal on ticket/bh-77 at $SHA since 2026-10-14 23:07:10Z" "$T/say.log" && ok \
  || bad "R1: the list line must name branch and sha: $(cat "$T/say.log")"
[ "$(posts)" = 1 ] && ok || bad "R1: one comment POST expected, got $(posts)"
grep -q 'repos/o/tproj/issues/77/comments' "$T/gh.txt" && ok || bad "R1: the POST must go to o/tproj#77: $(cat "$T/gh.txt")"
grep -qF 'ticket/bh-77' "$T/body.1" 2>/dev/null && grep -qF "$SHA" "$T/body.1" && ok \
  || bad "R1: the comment must name the branch and the head: $(cat "$T/body.1" 2>/dev/null)"
[ -f "$H/state/pool/tproj/BH-77.terminal-noted" ] && ok || bad "R1: the sentinel must be touched after the POST"

# ── R4: a second tick, then a failed POST ─────────────────────────────────
: > "$T/say.log"
pass
[ "$(posts)" = 1 ] && ok || bad "R4: a second tick must not comment again, got $(posts)"
# A told terminal is a count, not a line per tick (the log must not grow for ever).
grep -q 'tproj/BH-77' "$T/say.log" && bad "R4: a told terminal must not be listed again: $(cat "$T/say.log")" || ok
grep -qx '1 push-rejected terminal(s) already told on their ticket' "$T/say.log" && ok \
  || bad "R4: the told terminals must be one count line: $(cat "$T/say.log")"
clean; term tproj BH-77 77; echo 403 > "$T/post-code"
pass
[ -f "$H/state/pool/tproj/BH-77.terminal-noted" ] && bad "R4: a failed POST must leave no sentinel" || ok
grep -q 'tproj/BH-77: the terminal comment on o/tproj#77 was not posted' "$T/say.log" && ok \
  || bad "R4: a failed POST must say so: $(cat "$T/say.log")"
rm -f "$T/post-code"
pass
[ -f "$H/state/pool/tproj/BH-77.terminal-noted" ] && ok || bad "R4: the next tick must retry and post"

# ── R2: the cap ───────────────────────────────────────────────────────────
clean
for i in $(seq 10 34); do term tproj "BH-$i" "$i"; done
pass
[ "$(posts)" = 20 ] && ok || bad "R2: 20 comments expected under the default cap, got $(posts)"
grep -q '5 push-rejected terminal comment(s) left for the next tick (BR_POOL_TERMINAL_MAX=20)' "$T/say.log" && ok \
  || bad "R2: the deferred count must be named: $(grep -v 'push-rejected terminal on' "$T/say.log")"
pass
[ "$(posts)" = 25 ] && ok || bad "R2: the next tick must post the 5 left, got $(posts) in total"

# ── R3: no ticket id; a board project ─────────────────────────────────────
clean; term tproj BH-90; term bproj TK-91 91
pass
[ "$(posts)" = 0 ] && ok || bad "R3: no POST without a ticket id or on a board project, got $(posts)"
grep -q 'tproj/BH-90: .*no ticket id on the terminal file — not commented' "$T/say.log" && ok \
  || bad "R3: the no-ticket line is missing: $(cat "$T/say.log")"
grep -q 'bproj/TK-91: .*board project, no GitHub issue — not commented' "$T/say.log" && ok \
  || bad "R3: the board line is missing: $(cat "$T/say.log")"

# ── R5: observe mode ──────────────────────────────────────────────────────
clean; term tproj BH-77 77
OBSERVE=1 pass
grep -q 'tproj/BH-77: push-rejected terminal' "$T/say.log" && ok || bad "R5: observe mode must still list"
[ "$(posts)" = 0 ] && ok || bad "R5: observe mode must post nothing"
[ -f "$H/state/pool/tproj/BH-77.terminal-noted" ] && bad "R5: observe mode wrote a sentinel" || ok

# ── R6: one real resolver run ─────────────────────────────────────────────
clean; term tproj BH-77 77
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj bproj
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh lane-alert.sh run-build.sh agent-call.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF
: > "$H/state/merge-conductor/pr-state.tsv"
( HARNESS="$H" BR_UNCHANGED_RECHECK_S=0 bash "$H/bin/blocked-resolver.sh" >"$T/run.log" 2>&1 ) || true
[ "$(posts)" = 1 ] && ok || bad "R6: one resolver run must post one comment, got $(posts): $(tail -5 "$H/logs/blocked-resolver.log" 2>/dev/null; tail -5 "$T/run.log")"
grep -q "tproj/BH-77: push-rejected terminal on ticket/bh-77 at $SHA" "$H/logs/blocked-resolver.log" 2>/dev/null && ok \
  || bad "R6: the resolver log must list the terminal: $(tail -5 "$H/logs/blocked-resolver.log" 2>/dev/null)"
[ -f "$H/state/pool/tproj/BH-77.terminal-noted" ] && ok || bad "R6: the run must touch the sentinel"

# ── R7: the lane-run manifests, and an off-hub root ───────────────────────
LRI() { ( export HARNESS="$DIR"; . "$DIR/bin/lib/lane-run-inputs.sh" || exit 9; "$@" ) >/dev/null 2>&1; }
LRI lri_member_ok tproj state/pool/tproj/BH-77.terminal - ro blocked-resolver && ok \
  || bad "R7: the ro snapshot must carry state/pool/<p>/<KEY>.terminal"
LRI lri_member_ok tproj state/pool/tproj/BH-77.terminal-noted - rw blocked-resolver && ok \
  || bad "R7: the rw write-back must carry state/pool/<p>/<KEY>.terminal-noted"
LRI lri_member_ok tproj state/pool/tproj/BH-77.push-diverged - ro blocked-resolver && bad "R7: the snapshot must not carry other pool state" || ok
O="$T/offhub"; mkdir -p "$O/bin/lib" "$O/state/pool/tproj" "$O/logs"
cp "$H/state/pool/tproj/BH-77.terminal" "$O/state/pool/tproj/"; cp "$H/fleet.conf" "$O/"
cp "$H/bin/fleet-conf.sh" "$O/bin/"
scratch_install_closure bin/lib/br-pool-terminals.sh "$O" >/dev/null || bad "R7: closure install of the lib failed"
scratch_install_closure bin/lib/gh-rest.sh "$O" >/dev/null || bad "R7: closure install of gh-rest.sh failed"
: > "$T/say.log"; rm -f "$T"/body.*
( export HARNESS="$O" H="$O" FLEET_CONF="$O/fleet.conf"
  say() { printf '%s\n' "$*" >> "$T/say.log"; }
  . "$O/bin/lib/gh-rest.sh"; . "$O/bin/lib/br-pool-terminals.sh"; br_pool_terminal_pass tproj ) >/dev/null 2>&1
[ "$(posts)" = 1 ] && [ -f "$O/state/pool/tproj/BH-77.terminal-noted" ] && ok \
  || bad "R7: the pass must work on a root holding only the snapshot's files: $(cat "$T/say.log")"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
