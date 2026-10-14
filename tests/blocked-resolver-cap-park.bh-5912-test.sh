#!/bin/bash
# tests/blocked-resolver-cap-park.bh-5912-test.sh — a FAILED row that the
# pre-BH-4859 pool wrote when the per-key spawn cap tripped ("pool spawn cap of
# <n> in <w>s reached — deferred to a human") has an owner (BH-5912).
#
# BH-4859 made the cap a timed retry, so no code writes that reason now. Rows
# written before it still sit FAILED, and br_from_queue picked up only `died N
# times` / `deferred N times`, so nothing ever re-offered them.
#
#   R1/R2  the legacy cap-park reason is offered as `pool-deferred-max`.
#   R3     unrelated FAILED rows stay out.
#   R4     the lane-failure skip (RUNNER_EXHAUSTED) still wins over it.
#   R5     the existing died/deferred triggers are unchanged.
#   R6     br_action maps that reason to rebuild-fresh (the capped ladder).
#
# HOW IT DRIVES: the functions are EXTRACTED from the real script and executed
# with queue_list stubbed (the tests/blocked-resolver-lane-exhausted-test.sh
# seam). No network, no clock, no LLM.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
BR="$DIR/bin/blocked-resolver.sh"
H="$T/h"; mkdir -p "$H/state/build-queue" "$H/logs" "$H/bin"

# BH-5241: the corpus is the driver plus bin/lib/br/*.sh (tests/lib/br-corpus.sh),
# because the ladder functions moved out of the driver into bin/lib/br/ladder.sh.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1
fn() { awk -v f="$1" '$0 ~ "^"f"\\(\\) \\{" {p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh"; }

{ fn br_rkey; fn br_from_queue; } > "$T/q.sh"
grep -q '^br_from_queue() {' "$T/q.sh" && ok || bad "setup: could not extract br_from_queue"
cat > "$T/rows.tsv" <<'EOF'
tproj	BH-7	7	failed	fly	1	-	-	pool spawn cap of 12 in 86400s reached — deferred to a human	-
tproj	BH-9	9	failed	fly	1	-	-	pool spawn cap of 2 in 86400s reached — deferred to a human	-
tproj	BH-8	8	failed	fly	1	-	-	an open PR already exists for ticket/bh-8 — no build started	-
tproj	BH-10	10	failed	fly	1	-	-	rebase machine stood down before the job ran; row FAILED, not requeued	-
tproj	BH-11	11	failed	fly	1	-	-	deferred 6 times (BUILD_DEFERRED plan session ended RUNNER_EXHAUSTED class=real-failure(agent)) — pool spawn cap of 12 in 86400s reached — deferred to a human	-
tproj	BH-12	12	failed	fly	1	-	-	deferred 6 times (BUILD_DEFERRED wip-limit 2 reached) — parked for the blocked-resolver	-
tproj	BH-13	13	failed	fly	2	-	-	pool machine died 2 times	-
EOF
OUT=$(H="$H" ONLY="" ROWS="$T/rows.tsv" bash -c '
  queue_list() { cat "$ROWS"; }
  . "$0"; br_from_queue' "$T/q.sh" 2>/dev/null)
KEYS=$(cut -f7 <<<"$OUT")

# R1 — the exact reason the pre-BH-4859 cap arm wrote.
grep -q "pool-deferred-max	-	-	BH-7	" <<<"$OUT" && ok \
  || bad "R1: a legacy 'spawn cap … deferred to a human' row is not offered: $OUT"
grep -q "^queue	tproj	tproj-BH-7	pool-deferred-max" <<<"$OUT" && ok \
  || bad "R1: the row is not a queue-source pool-deferred-max row keyed tproj-BH-7: $OUT"
# R2 — the default-cap wording.
grep -q "pool-deferred-max	-	-	BH-9	" <<<"$OUT" && ok \
  || bad "R2: the cap-of-2 wording is not offered: $OUT"
# R3 — unrelated FAILED rows.
grep -qx 'BH-8' <<<"$KEYS" && bad "R3: an open-PR row was offered for a rebuild" || ok
grep -qx 'BH-10' <<<"$KEYS" && bad "R3: a rebase stand-down row was offered for a rebuild" || ok
# R4 — a lane failure is never a rebuild, whatever else the reason says.
grep -qx 'BH-11' <<<"$KEYS" && bad "R4: a RUNNER_EXHAUSTED row was offered because it also names the cap" || ok
# R5 — the existing triggers.
grep -q "pool-deferred-max	-	-	BH-12	" <<<"$OUT" && ok \
  || bad "R5: an ordinary deferred-max row is no longer offered: $OUT"
grep -q "pool-died-twice	-	-	BH-13	" <<<"$OUT" && ok \
  || bad "R5: a died-twice row is no longer offered: $OUT"
# Exactly one row per offered key.
N=$(grep -c . <<<"$OUT")
[ "$N" = 4 ] && ok || bad "R5: expected 4 offered rows (BH-7, BH-9, BH-12, BH-13), got $N: $OUT"

# R6 — the reason enters the capped rebuild ladder.
fn br_action > "$T/a.sh"
grep -q '^br_action() {' "$T/a.sh" && ok || bad "R6: could not extract br_action"
ACT=$(BR_LADDER=0 bash -c '. "$0"; br_action pool-deferred-max' "$T/a.sh" 2>/dev/null)
[ "$ACT" = rebuild-fresh ] && ok || bad "R6: br_action pool-deferred-max answered '$ACT', want rebuild-fresh"

echo "blocked-resolver-cap-park: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
