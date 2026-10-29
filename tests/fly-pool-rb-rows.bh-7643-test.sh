#!/bin/bash
# tests/fly-pool-rb-rows.bh-7643-test.sh — conductor rebase rows (RB-<pr>-<head8>)
# in the pool SPAWN walk: a per-tick cap, no machine for a closed or merged PR,
# and the walk's hot-first contract (BH-7643).
#
#   K1-K3  pool_rb_max_per_tick (bin/lib/pool-rb-rows.sh): the env value, the
#          fallback 4, and a bad value -> 4 with one line
#   C1     6 RB + 2 ticket rows, cap 8, limit 4 -> 4 RB + 2 ticket machines, the
#          2 RB rows past the limit stay queued, one wait line names them
#   C2     the same queue, limit 0 (no limit) -> 8 machines, no wait line
#   C3     cap 3, 2 RB + 2 ticket rows, limit 1 -> 1 RB + 2 ticket (a capped RB
#          row does not end the walk)
#   C4     an RR row is not counted against the RB limit
#   W1     cap 1, 1 live, an older RB row + a hotfix row: the hotfix spawns
#   W2     the same tick on a copy of bin/fly-pool.sh whose hotfix_first puts
#          RB before hot: the hotfix does NOT spawn (W1 can fail)
#   P1     PR merged -> row closed done "empty: pr-closed", file removed, no
#          machine; PR open -> 1 machine
#   P2     PR closed unmerged -> the same as merged
#   P3     an unreadable PR read (404, 403, 500, TIMEOUT, no status line, not
#          JSON) -> the row spawns, with a "state unreadable" line
#   P4     two RB rows of one PR -> one PR read in the tick
#   P5     near misses that must spawn: "closed" in the title, a draft, state
#          "Closed", a row slug that is not the pool's, a ticket id that is not
#          a number
#   P6     the reuse handoff: pool_spawn_decision on a merged PR's RB row -> rc
#          1 and the file removed; on an open PR -> rc 0
#   Z1     every gh call the ticks made went to the fake repo o/r, and no curl ran
#
# Everything runs the real bin/fly-pool.sh against a scratch $HARNESS with a
# fake fly, gh and jobs worker. 0 network calls.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset POOL_AUTOSCALE POOL_CAP_MAX HOTFIX HOTFIX_LANE POOL_RB_MAX_PER_TICK

LIB="$REPO/bin/lib/pool-rb-rows.sh"

# ══ K. the knob reader ═══════════════════════════════════════════════════════
kval() { # kval <value|-unset> -> "<printed> <lines said>"
  ( SAIDF="$T/k-said"; : > "$SAIDF"
    say() { echo "$*" >> "$SAIDF"; }
    if [ "$1" = -unset ]; then unset POOL_RB_MAX_PER_TICK; else export POOL_RB_MAX_PER_TICK="$1"; fi
    . "$LIB" 2>/dev/null || { echo "nolib 0"; exit 0; }
    v=$(pool_rb_max_per_tick)
    echo "$v $(wc -l < "$SAIDF" | tr -d ' ')" )
}
[ "$(kval 2)" = "2 0" ] && ok || bad "K1 POOL_RB_MAX_PER_TICK=2 must print 2 and say nothing (got '$(kval 2)')"
[ "$(kval 0)" = "0 0" ] && ok || bad "K1 POOL_RB_MAX_PER_TICK=0 (no limit) must print 0 (got '$(kval 0)')"
[ "$(kval -unset)" = "4 0" ] && ok || bad "K2 unset must print the fallback 4 (got '$(kval -unset)')"
[ "$(kval '')" = "4 0" ] && ok || bad "K2 empty must print the fallback 4 (got '$(kval '')')"
[ "$(kval abc)" = "4 1" ] && ok || bad "K3 abc must print 4 with one line (got '$(kval abc)')"
[ "$(kval -1)" = "4 1" ] && ok || bad "K3 -1 must print 4 with one line (got '$(kval -1)')"
[ "$(kval 1001)" = "4 1" ] && ok || bad "K3 1001 (over the max) must print 4 with one line (got '$(kval 1001)')"

# ══ the pool fixture ═════════════════════════════════════════════════════════
H="$T/p"; QD="$H/state/build-queue/tproj"; PD="$H/state/fly-pool/tproj"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$PD" "$QD" "$H/builds" "$T/fakebin" "$T/prs"
scratch_install_closure bin/pool-cap.sh "$H" >/dev/null || { echo "closure install of bin/pool-cap.sh failed"; exit 1; }
scratch_install_closure bin/result-prefix-ok.sh "$H" >/dev/null || { echo "closure install of bin/result-prefix-ok.sh failed"; exit 1; }
scratch_install_closure bin/lib/hotfix-lib.sh "$H" >/dev/null || { echo "closure install of bin/lib/hotfix-lib.sh failed"; exit 1; }
printf 'HARNESS_SECRET=fixture-secret\n' > "$H/env/global.env"
: > "$H/env/fly.env"
printf 'pool-tproj\n' > "$H/flags/fly-pool-app-tproj"
printf '{"app":"pool-tproj"}\n' > "$H/state/fly/tproj.json"
printf 'registry.fly.io/builder-tproj:deployment-01\n' > "$H/state/fly/tproj.image"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
printf '#!/bin/bash\necho "curl $*" >> "%s"\nexit 7\n' "$T/curl-calls" > "$T/fakebin/curl"
cat > "$T/fakebin/fly" <<'STUB'
#!/bin/bash
case "$*" in
  *"machines list"*)  echo '[]' ;;
  *"machine status"*) echo "State: started" ;;
  *stat*heartbeat*)   echo 5 ;;
  *RESULT*)           : ;;
  *"machine run"*)    printf 'Machine ID: %014x\n' "$$" ;;
  *) : ;;
esac
exit 0
STUB
# The repo slug: SLUG_ON=1 gives o/r, so the pool's GitHub gates apply.
cat > "$H/bin/fleet-conf.sh" <<'FC'
#!/bin/bash
[ "${SLUG_ON:-0}" = 1 ] && [ "${2:-}" = repo ] && { echo o/r; exit 0; }
exit 1
FC
# gh: the repo probe answers 200; repos/o/r/pulls/<n> answers from $T/prs/<n>
# (line 1 the status code or TIMEOUT or NONE, the rest the body); anything else
# 404. Every call is one line in $T/gh-calls.
cat > "$T/fakebin/gh" <<GH
#!/bin/bash
p=""; for a in "\$@"; do case "\$a" in repos/*) p=\$a ;; esac; done
echo "\${p:-\$*}" >> "$T/gh-calls"
case "\$p" in
  repos/o/r) printf 'HTTP/1.1 200 OK\r\n\r\n{"full_name":"o/r"}\n'; exit 0 ;;
  repos/o/r/pulls/[0-9]*)
    n=\${p##*/}; f="$T/prs/\$n"
    [ -f "\$f" ] || { printf 'HTTP/1.1 404 Not Found\r\n\r\n{}\n'; exit 0; }
    c=\$(head -n 1 "\$f")
    case "\$c" in TIMEOUT) exit 124 ;; NONE) exit 1 ;; esac
    printf 'HTTP/1.1 %s X\r\n\r\n' "\$c"; tail -n +2 "\$f"; exit 0 ;;
esac
printf 'HTTP/1.1 404 Not Found\r\n\r\n{}\n'; exit 0
GH
# The jobs worker: the real queue_done (verbatim from bin/lib/jobs/queue.sh)
# over a _jobs_req that appends "<method> <path> <body>" to $T/jobs-calls.
{ printf '_jobs_req() { printf "%%s %%s %%s\\n" "$1" "$2" "$3" >> "%s"; }\n' "$T/jobs-calls"
  sed -n '/^queue_done() {/,/^}/p' "$REPO/bin/lib/jobs/queue.sh"; } > "$H/bin/jobs-client.sh"
grep -q '^queue_done() {' "$H/bin/jobs-client.sh" && ok || bad "fixture: could not extract queue_done from bin/lib/jobs/queue.sh"
chmod +x "$H/bin"/*.sh "$T/fakebin"/*

pr() { printf '%s\n%s\n' "$2" "${3:-}" > "$T/prs/$1"; }  # pr <n> <code> [body]
rb() { # rb <pr> <head8> <age-minutes> [slug] [ticket-id] — one RB queue file
  local slug="${4:-o/r}" tid="${5:-$1}"
  jq -nc --arg k "RB-$1-$2" --arg t "$tid" --arg s "$slug" --argjson n "$1" \
    '{ticket_id:$t,key:$k,attempt:0,deferrals:0,deaths:0,
      rebase:{kind:"rebase",slug:$s,pr:$n,branch:"ticket/x",head:"aaaaaaaa",base:"main"}}' > "$QD/RB-$1-$2.json"
  touch -d "@$((1577836800 + $3 * 60))" "$QD/RB-$1-$2.json"
}
row() { # row <key> <age-minutes> [hotfix] — one plain (or hotfix) queue file
  if [ "${3:-}" = hot ]; then
    jq -nc --arg k "$1" '{ticket_id:"7",key:$k,attempt:0,deferrals:0,deaths:0,hotfix:true}' > "$QD/$1.json"
  else
    jq -nc --arg k "$1" '{ticket_id:"7",key:$k,attempt:0,deferrals:0,deaths:0}' > "$QD/$1.json"
  fi
  touch -d "@$((1577836800 + $2 * 60))" "$QD/$1.json"
}
reset() { # reset <cap> [live] — empty queue and pool, the cap flag, live machines
  rm -f "$QD"/*.json "$PD"/*.json "$T/prs"/* "$T/jobs-calls"
  printf '%s\n' "$1" > "$H/flags/fly-pool-tproj"
  [ "${2:-0}" = 1 ] && jq -nc '{machine:"m0",key:"LIVE-0",ticket_id:"0",attempt:0,deferrals:0,deaths:0}' > "$PD/m0.json"
  return 0
}
POOLBIN="$REPO/bin/fly-pool.sh"
tick() { # tick [env...] — one pass of $POOLBIN
  : > "$H/logs/fly-pool.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLY_BIN_DIR="$T/fakebin" \
           FLY_API_TOKEN_TPROJ=fixture-tok "$@"
    bash "$POOLBIN" tproj >/dev/null 2>&1 )
}
spawned() { jq -r '.key' "$PD"/*.json 2>/dev/null | grep -v '^LIVE-0$' | sort | tr '\n' ' '; }
nspawned() { spawned | wc -w | tr -d ' '; }
logc() { grep -c -- "$1" "$H/logs/fly-pool.log" 2>/dev/null; }

# ══ C. the per-tick RB limit ═════════════════════════════════════════════════
c1queue() {
  reset 8
  for i in 1 2 3 4 5 6; do rb "10$i" "aaaaaaa$i" "$i"; done
  row TK-1 0; row TK-2 7
}
c1queue
tick POOL_RB_MAX_PER_TICK=4
S=$(spawned)
[ "$(nspawned)" = 6 ] && ok || bad "C1 limit 4, cap 8: expected 6 machines, got $(nspawned): $S"
[ "$S" = "RB-101-aaaaaaa1 RB-102-aaaaaaa2 RB-103-aaaaaaa3 RB-104-aaaaaaa4 TK-1 TK-2 " ] && ok \
  || bad "C1 expected the 4 oldest RB rows and both ticket rows, got: $S"
[ -f "$QD/RB-105-aaaaaaa5.json" ] && [ -f "$QD/RB-106-aaaaaaa6.json" ] && ok \
  || bad "C1 the 2 RB rows past the limit must stay queued for the next tick"
[ "$(logc 'past pool_rb_max_per_tick')" = 1 ] && ok || bad "C1 expected exactly one wait line, got $(logc 'past pool_rb_max_per_tick')"
grep -q 'rebase rows: 2 past pool_rb_max_per_tick=4 wait for the next tick (RB-105-aaaaaaa5 RB-106-aaaaaaa6)' "$H/logs/fly-pool.log" \
  && ok || bad "C1 the wait line must name the count, the limit and both keys: $(grep 'rebase rows:' "$H/logs/fly-pool.log")"

c1queue
tick POOL_RB_MAX_PER_TICK=0
[ "$(nspawned)" = 8 ] && ok || bad "C2 limit 0 is no limit: expected 8 machines, got $(nspawned): $(spawned)"
[ "$(logc 'past pool_rb_max_per_tick')" = 0 ] && ok || bad "C2 limit 0 must say no wait line"

reset 3
rb 201 bbbbbbb1 1; rb 202 bbbbbbb2 2; row TK-3 0; row TK-4 5
tick POOL_RB_MAX_PER_TICK=1
S=$(spawned)
[ "$S" = "RB-201-bbbbbbb1 TK-3 TK-4 " ] && ok \
  || bad "C3 limit 1, cap 3: a capped RB row must not end the walk — expected RB-201 + both tickets, got: $S"
[ -f "$QD/RB-202-bbbbbbb2.json" ] && ok || bad "C3 the capped RB row must stay queued"

reset 4
rb 301 ccccccc1 1
jq -nc '{ticket_id:"302",key:"RR-302-ccccccc2",attempt:0,deferrals:0,deaths:0}' > "$QD/RR-302-ccccccc2.json"
tick POOL_RB_MAX_PER_TICK=1
S=$(spawned)
[ "$S" = "RB-301-ccccccc1 RR-302-ccccccc2 " ] && ok || bad "C4 an RR row must not count against the RB limit, got: $S"

# ══ W. the walk's hot-first contract ═════════════════════════════════════════
wqueue() { reset 1 1; rb 401 ddddddd1 0; row HOT-1 9 hot; }
wqueue
tick POOL_RB_MAX_PER_TICK=1
S=$(spawned)
[ "$S" = "HOT-1 " ] && ok || bad "W1 BUDGET=0, HOTFIX_EXTRA=1, RB + hotfix: the hotfix must spawn, alone (got: $S)"
[ -f "$QD/RB-401-ddddddd1.json" ] && ok || bad "W1 the RB row must stay queued"

# W2: the same tick on a copy whose hotfix_first prints the RB group before the
# hot group. The copy sits in a bin/ of links to the real files, so it loads
# the same libs as the real script.
MB="$T/mut/bin"; mkdir -p "$MB"
for f in "$REPO"/bin/*; do [ "${f##*/}" = fly-pool.sh ] || ln -s "$f" "$MB/${f##*/}"; done
awk '
  /^hotfix_first\(\) \{/ { inf = 1 }
  inf && !held && /job_is_hot "\$f" && printf/ { held = $0; next }
  inf && held && !done && /RB-\*\|RR-\*/ && /job_is_hot "\$f" \|\| printf/ { print; print held; done = 1; next }
  { print }' "$REPO/bin/fly-pool.sh" > "$MB/fly-pool.sh"
HL=$(grep -n 'do job_is_hot "$f" && printf' "$MB/fly-pool.sh" | head -1 | cut -d: -f1)
RL=$(grep -n 'RB-\*|RR-\*.*job_is_hot "$f" || printf' "$MB/fly-pool.sh" | head -1 | cut -d: -f1)
[ -n "$HL" ] && [ -n "$RL" ] && [ "$HL" -gt "$RL" ] && ok \
  || bad "W2 the mutation did not apply (hot loop line ${HL:-none}, RB loop line ${RL:-none})"
wqueue
POOLBIN="$MB/fly-pool.sh" tick POOL_RB_MAX_PER_TICK=1
POOLBIN="$REPO/bin/fly-pool.sh"
S=$(spawned)
case "$S" in *HOT-1*) bad "W2 with RB before hot the hotfix must NOT spawn — W1 cannot tell the orders apart (got: $S)" ;; *) ok ;; esac

# ══ P. a closed or merged PR gets no machine ═════════════════════════════════
: > "$T/gh-calls"
reset 8
pr 11 200 '{"number":11,"state":"closed","merged":true}'
pr 12 200 '{"number":12,"state":"open","merged":false}'
rb 11 eeeeeee1 1; rb 12 eeeeeee2 2
tick SLUG_ON=1
S=$(spawned)
[ "$S" = "RB-12-eeeeeee2 " ] && ok || bad "P1 merged PR: 0 machines, open PR: 1 machine (got: $S)"
[ -f "$QD/RB-11-eeeeeee1.json" ] && bad "P1 the merged PR's queue file must be removed" || ok
PB=$(grep '^PATCH /api/queue ' "$T/jobs-calls" 2>/dev/null | sed 's#^PATCH /api/queue ##' | jq -c 'select(.key=="RB-11-eeeeeee1")' 2>/dev/null)
[ "$(jq -r .status <<<"$PB" 2>/dev/null)" = done ] && ok || bad "P1 the row must be closed with status done (PATCH: ${PB:-none})"
case "$(jq -r .reason <<<"$PB" 2>/dev/null)" in "empty: pr-closed (PR #11 merged)") ok ;; *) bad "P1 reason must be 'empty: pr-closed (PR #11 merged)' (PATCH: ${PB:-none})" ;; esac
grep -E 'died|deferred' <<<"$PB" >/dev/null && bad "P1 the close reason must not carry a died/deferred text br_from_queue reads" || ok
grep -q 'RB-11-eeeeeee1: PR #11 is merged — row closed empty (pr-closed), queue file removed, no machine' "$H/logs/fly-pool.log" \
  && ok || bad "P1 the close line is missing"
grep -q '"key":"RB-12-eeeeeee2"' <<<"$(grep '^PATCH /api/queue ' "$T/jobs-calls" 2>/dev/null)" && bad "P1 the open PR's row must not be closed" || ok

reset 8
pr 21 200 '{"number":21,"state":"closed","merged":false}'
rb 21 fffffff1 1
tick SLUG_ON=1
[ "$(nspawned)" = 0 ] && [ ! -f "$QD/RB-21-fffffff1.json" ] && ok || bad "P2 a closed unmerged PR: no machine and the file removed (got: $(spawned))"
grep '^PATCH /api/queue ' "$T/jobs-calls" 2>/dev/null | grep -q '"reason":"empty: pr-closed (PR #21 closed)"'  && ok || bad "P2 the row must be closed 'empty: pr-closed (PR #21 closed)'"

reset 8
pr 31 404 '{"message":"Not Found"}'; pr 32 403 '{"message":"rate limit"}'; pr 33 500 'oops'
pr 34 TIMEOUT; pr 35 NONE; pr 36 200 'not json'
for n in 31 32 33 34 35 36; do rb "$n" "aaaa00$n" "$n"; done
tick SLUG_ON=1 POOL_RB_MAX_PER_TICK=0
[ "$(nspawned)" = 6 ] && ok || bad "P3 every unreadable PR state spawns as before: expected 6, got $(nspawned): $(spawned)"
[ "$(logc 'state unreadable')" = 6 ] && ok || bad "P3 expected one 'state unreadable' line per row, got $(logc 'state unreadable')"
grep -q '^PATCH /api/queue ' "$T/jobs-calls" 2>/dev/null && bad "P3 no row may be closed on an unreadable read: $(grep '^PATCH' "$T/jobs-calls")" || ok

reset 8
pr 13 200 '{"number":13,"state":"open"}'
rb 13 aaaaaaaa 1; rb 13 bbbbbbbb 2
tick SLUG_ON=1
[ "$(grep -c '^repos/o/r/pulls/13$' "$T/gh-calls")" = 1 ] && ok || bad "P4 two rows of one PR must read it once per tick (got $(grep -c '^repos/o/r/pulls/13$' "$T/gh-calls"))"
[ "$(nspawned)" = 2 ] && ok || bad "P4 both rows of an open PR spawn (got $(spawned))"

reset 8
pr 51 200 '{"number":51,"state":"open","title":"closed it","body":"closed"}'
pr 52 200 '{"number":52,"state":"open","draft":true}'
pr 53 200 '{"number":53,"state":"Closed","merged":true}'
pr 54 200 '{"number":54,"state":"closed","merged":true}'
pr 55 200 '{"number":55,"state":"closed","merged":true}'
rb 51 aaaaaa51 1; rb 52 aaaaaa52 2; rb 53 aaaaaa53 3
rb 54 aaaaaa54 4 other/repo
rb 55 aaaaaa55 5 o/r x
tick SLUG_ON=1 POOL_RB_MAX_PER_TICK=0
[ "$(nspawned)" = 5 ] && ok || bad "P5 near misses must all spawn: expected 5, got $(nspawned): $(spawned)"
grep -q '^PATCH /api/queue ' "$T/jobs-calls" 2>/dev/null && bad "P5 no near miss may be closed: $(grep '^PATCH' "$T/jobs-calls")" || ok
grep -q '^repos/o/r/pulls/54$' "$T/gh-calls" && bad "P5 a row of another repo must not be read with this pool's token" || ok

# ══ P6. the reuse handoff runs the same check ════════════════════════════════
FN="$T/psd.sh"
sed -n '/^pool_rest_read() {/,/^}/p; /^pool_spawn_decision() {/,/^}/p' "$REPO/bin/fly-pool.sh" > "$FN"
[ "$(grep -c '^pool_spawn_decision() {\|^pool_rest_read() {' "$FN")" = 2 ] && ok || bad "P6 could not extract pool_spawn_decision and pool_rest_read"
reset 8
pr 61 200 '{"state":"closed","merged":true}'; pr 62 200 '{"state":"open"}'
rb 61 aaaaaa61 1; rb 62 aaaaaa62 2
P6OUT=$( PATH="$T/fakebin:$PATH" bash -c '
  P=tproj; POOL_SLUG=o/r; POOL_SLUG_TOK=""; LOG="$1/p6.log"
  say() { echo "$*" >> "$LOG"; }
  QROW() { echo "QROW $*" >> "$LOG"; }
  pool_gates_applicable() { return 0; }
  . "$2"; . "$3"
  pool_spawn_decision "$4/RB-61-aaaaaa61.json" RB-61-aaaaaa61 61; a=$?
  pool_spawn_decision "$4/RB-62-aaaaaa62.json" RB-62-aaaaaa62 62; b=$?
  echo "$a $b"' _ "$T" "$FN" "$LIB" "$QD" 2>/dev/null )
[ "$P6OUT" = "1 0" ] && ok || bad "P6 merged PR -> rc 1, open PR -> rc 0 (got '$P6OUT')"
[ -f "$QD/RB-61-aaaaaa61.json" ] && bad "P6 the merged PR's file must be removed on the reuse path" || ok
[ -f "$QD/RB-62-aaaaaa62.json" ] && ok || bad "P6 the open PR's file must stay"
grep -q 'QROW done RB-61-aaaaaa61 empty: pr-closed (PR #61 merged)' "$T/p6.log" 2>/dev/null && ok || bad "P6 the reuse path must close the row: $(cat "$T/p6.log" 2>/dev/null)"

# ══ Z1. 0 real vendor calls ══════════════════════════════════════════════════
[ -s "$T/gh-calls" ] && ok || bad "Z1 the slug ticks made no gh call at all (the fake was not reached)"
ZOUT=$(grep -v '^repos/o/r\([/?].*\)\{0,1\}$' "$T/gh-calls")
[ -n "$ZOUT" ] && bad "Z1 a gh call outside the fake repo o/r: $ZOUT" || ok
[ -s "$T/curl-calls" ] && bad "Z1 a curl call left the tick: $(head -3 "$T/curl-calls")" || ok

echo "fly-pool-rb-rows.bh-7643: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
