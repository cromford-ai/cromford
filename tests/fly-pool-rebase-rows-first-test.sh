#!/bin/bash
# tests/fly-pool-rebase-rows-first-test.sh — conductor rebase rows (RB-*) are
# walked before ticket builds in the pool SPAWN walk.
#
# 2026-10-19: project-6-os had 140 queued rows. The Fly conductor queued three
# pool rebases (RB-1957, RB-1975, RB-1924) at 23:49Z. The SPAWN walk takes
# hotfix_first $(ls -tr …): hotfix rows, then oldest first. The RB rows were
# the newest, and the 600 s tick budget ran out on older TK-* builds every
# tick, so no rebase machine started and the merge lane waited.
#
#   R1  an RB row comes before an older ticket row
#   R2  a hotfix row comes before an RB row: the SPAWN walk `break`s on the
#       first non-hot row once its budget is spent, so every hot row must lead
#       or it loses its cap exemption (BH-7382)
#   R3  the full order is hot, RB (oldest first), now, rest
#   R4  every row is printed exactly once
#   R5  with HOTFIX_ON=0 the RB rows lead
set -uo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

. "$(dirname "$0")/lib/scratch.sh" || exit 1
FN="$T/fn.sh"
# The three helpers, verbatim from the pool script.
sed -n '/^job_is_hot() {/,/^}/p; /^job_is_now() {/,/^}/p; /^hotfix_first() {/,/^}/p' "$DIR/bin/fly-pool.sh" > "$FN"
[ "$(grep -c '() {' "$FN")" = 3 ] && ok || bad "could not extract the three helpers from bin/fly-pool.sh"

Q="$T/q"; mkdir -p "$Q" "$T/h/state/dispatch-now/p"
printf '{"key":"TK-1"}\n'                 > "$Q/TK-1.json"
printf '{"key":"TK-2","hotfix": true}\n'  > "$Q/TK-2.json"
printf '{"key":"TK-3"}\n'                 > "$Q/TK-3.json"
printf '{"key":"RB-9-aaaa"}\n'            > "$Q/RB-9-aaaa.json"
printf '{"key":"RB-8-bbbb"}\n'            > "$Q/RB-8-bbbb.json"
touch "$T/h/state/dispatch-now/p/TK-3"

order() { # order <HOTFIX_ON> — the queue files in age order through hotfix_first
  HOTFIX_ON="$1" HARNESS="$T/h" P=p bash -c '. "$1"; shift; hotfix_first "$@"' _ "$FN" \
    "$Q/TK-1.json" "$Q/TK-2.json" "$Q/RB-9-aaaa.json" "$Q/TK-3.json" "$Q/RB-8-bbbb.json" \
    | xargs -n1 basename | tr '\n' ' '
}
OUT=$(order 1)
[ "${OUT%% *}" = TK-2.json ] && ok || bad "R2 the hotfix row is not first: $OUT"
case "$OUT" in *RB-8-bbbb.json*TK-1.json*) ok ;; *) bad "R1 an RB row is not before the older ticket row TK-1: $OUT" ;; esac
[ "$OUT" = "TK-2.json RB-9-aaaa.json RB-8-bbbb.json TK-3.json TK-1.json " ] && ok || bad "R3 order is not hot, RB, now, rest: $OUT"
[ "$(wc -w <<<"$OUT" | tr -d ' ')" = 5 ] && ok || bad "R4 a row is missing or printed twice: $OUT"
OUT=$(order 0)
[ "$OUT" = "RB-9-aaaa.json RB-8-bbbb.json TK-3.json TK-1.json TK-2.json " ] && ok || bad "R5 with HOTFIX_ON=0 the order is not RB, now, rest: $OUT"

echo "fly-pool-rebase-rows-first: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
