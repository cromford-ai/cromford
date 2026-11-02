#!/bin/bash
# tests/lead-enqueue-retired.bh-8589-test.sh — BH-8589 (C1 of BH-8525): the
# hub enqueue bin/lead-review-enqueue.sh is deleted with everything that only
# existed for it. This is the four-path pin of #5878, plus the lib, the
# fragment dir, the catalog rows and the replay rule's enqueue branch.
#   A1  the four #5878 paths do not exist: the script, its 713 cron fragment,
#       its lane JSON and its BH-3545 suite.
#   A2  bin/lib/lead-reenqueue.sh and bin/lead-review-enqueue.d/ do not exist.
#   A3  catalog/list-files.tsv has no row for bin/lead-review-enqueue.sh.
#   A4  catalog/lead-protected-paths.seed.tsv has no bin/lead-review-enqueue row.
#   A5  a scratch bin/lanes-build.sh --write renders no lane named or scripted
#       lead-review-enqueue; no non-comment line of cron/lanes/*.cron runs it.
#   A6  no non-comment line of bin/ or worker/jobs/src names lead-review-enqueue:.
#   A7  bin/lead-review.sh tick (fixture lib bh-4956): a requested row with
#       requested_by lead-review-enqueue:hub on a main-merge of a head the lead
#       approved is reviewed (1 agent call, no lead-replay result, a no-replay
#       line). The same row with requested_by lead-review-worklist is replayed.
#   A8  _lr_fresh_lane_request (bin/lib/lead-review/fresh-conflict.sh): rc 0 for
#       the 3 lane-own rows, rc 1 for the 6 negatives.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-enqueue-retired.bh-8589-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lead-worklist-fixture.bh-4956.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }

# ── A1: the four #5878 paths ──
for p in bin/lead-review-enqueue.sh cron/lanes/713-lead-review-enqueue.cron \
         catalog/lanes.d/lead-review-enqueue.json tests/lead-review-enqueue.bh-3545-test.sh; do
  [ ! -e "$SRC/$p" ] && ok || bad "A1 $p exists"
done

# ── A2: the lib and the fragment dir ──
[ ! -e "$SRC/bin/lib/lead-reenqueue.sh" ] && ok || bad "A2 bin/lib/lead-reenqueue.sh exists"
[ ! -e "$SRC/bin/lead-review-enqueue.d" ] && ok || bad "A2 bin/lead-review-enqueue.d exists"

# ── A3: no list-files row ──
[ -s "$SRC/catalog/list-files.tsv" ] && ok || bad "A3 setup: catalog/list-files.tsv is missing or empty"
hit=$(awk -F'\t' '$1 == "bin/lead-review-enqueue.sh"' "$SRC/catalog/list-files.tsv") \
  && [ -z "$hit" ] && ok || bad "A3 catalog/list-files.tsv row: $hit"

# ── A4: no protected-path seed row ──
[ -s "$SRC/catalog/lead-protected-paths.seed.tsv" ] && ok || bad "A4 setup: the seed is missing or empty"
hit=$(grep -n 'bin/lead-review-enqueue' "$SRC/catalog/lead-protected-paths.seed.tsv") \
  && bad "A4 seed rows: $hit" || ok

# ── A5: no lane, no cron line ──
RR="$T/render"; mkdir -p "$RR"
cp -r "$SRC/cron" "$RR/" && cp "$SRC/fleet.conf" "$RR/" && ok || bad "A5 setup: copy cron, fleet.conf"
cp -r "$SRC/catalog" "$RR/" 2>/dev/null; [ -d "$RR/catalog/lanes.d" ] && ok || bad "A5 setup: copy catalog"
if bash "$SRC/bin/lanes-build.sh" --root "$RR" --write > "$T/lb.out" 2>&1; then ok; else bad "A5 lanes-build --write: $(head -5 "$T/lb.out")"; fi
n=$(jq '[.lanes[] | select(.id == "lead-review-enqueue" or .script == "bin/lead-review-enqueue.sh")] | length' "$RR/catalog/lanes.json" 2>/dev/null)
[ "$n" = 0 ] && ok || bad "A5 lanes.json enqueue lanes: ${n:-unreadable}"
hit=""
for f in "$SRC"/cron/lanes/*.cron; do
  [ -f "$f" ] || continue
  grep -v '^[[:space:]]*#' "$f" | grep -q 'lead-review-enqueue\.sh' && hit="$hit ${f#"$SRC"/}"
done
[ -z "$hit" ] && ok || bad "A5 cron fragments run the enqueue:$hit"

# ── A6: no code line names the enqueue's requested_by tag ──
hit=$(cd "$SRC" && git grep -n 'lead-review-enqueue:' -- bin worker/jobs/src 2>/dev/null \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(#|//|\*)')
[ -z "$hit" ] && ok || bad "A6 code lines: $hit"

# ── A8: the lane-own rule on its own ──
(
  log() { :; }
  . "$SRC/bin/lib/lead-review/fresh-conflict.sh" || exit 9
  declare -F _lr_fresh_lane_request >/dev/null || exit 9
  rc=0
  for row in '{"requested_by":"lead-review-worklist"}' '{"requested_by":"","src":"worklist"}' \
             '{"requested_by":"person-x","src":"worklist"}'; do
    _lr_fresh_lane_request "$row" || { echo "FAIL: A8 lane-own row not lane-own: $row"; rc=1; }
  done
  for row in '{"requested_by":"lead-review-enqueue:hub"}' '{"requested_by":"lead-review-enqueuer"}' \
             '{"requested_by":"lead-review-worklistx"}' '{"requested_by":"box-mac"}' \
             '{"requested_by":""}' '{"requested_by":"lead-verdict.sh:mac"}'; do
    _lr_fresh_lane_request "$row" && { echo "FAIL: A8 negative row counted as lane-own: $row"; rc=1; }
  done
  exit "$rc"
); RC=$?
[ "$RC" = 0 ] && ok || bad "A8 rc=$RC"

# ── A7: bin/lead-review.sh tick reviews an enqueue-tagged row ──
lwf_setup
export LEAD_REVIEW_AUTO_REPOS="example-org/demo-os" LEAD_DELTA_REVIEW_MAX_LINES=50
gc() { git -C "$W" -c user.email=t@t -c user.name=t "$@"; }
BASE=$(git -C "$W" rev-parse "$SHA~1")
gc checkout -q -b mainline "$BASE"; echo m > "$W/b.txt"; gc add b.txt; gc commit -qm "main moves"
NEWMAIN=$(gc rev-parse HEAD)
gc checkout -q -b prmerge "$SHA"; gc merge -q --no-edit mainline; H1=$(gc rev-parse HEAD)
git -C "$W" push -q "$O" "$NEWMAIN:refs/heads/main" "$H1:refs/pull/201/head"
a7row() { # a7row <requested_by>: one `requested` row for pr 201 at H1, the lead approved $SHA
  echo "$H1" > "$FX/head.201"
  jq -nc --arg s "$H1" --arg by "$1" '[{id:"r-201", repo:"example-org/demo-os", pr:201, head_sha:$s, status:"requested",
    created_at:"2026-10-28 03:00:00", scope_notes:null, requested_by:$by}]' > "$FX/rows.json"
  jq -nc --arg g "$SHA" '{rows:[{id:7, source:"lead", repo:"example-org/demo-os", pr:201, head_sha:$g, verdict:"MERGE", note:""}], truncated:false}' > "$FX/verdicts.json"
}
lwf_reset
a7row lead-review-enqueue:hub
lwf_tick
[ "$(lwf_agents)" = 1 ] && ok || bad "A7 the enqueue-tagged row was not reviewed: agent calls=$(lwf_agents): $(grep 'lr-201' "$L")"
grep -q 'lead-replay' "$T/log/worker" && bad "A7 posted a lead-replay result: $(grep lead-replay "$T/log/worker")" || ok
grep -q "lr-201-${H1:0:12}: no replay (requested by lead-review-enqueue:hub, not the worklist" "$L" && ok \
  || bad "A7 no no-replay line: $(grep 'no replay' "$L")"
# the control: the worklist's own row on the same head is replayed
lwf_reset
a7row lead-review-worklist
lwf_tick
[ "$(lwf_agents)" = 0 ] && ok || bad "A7 the worklist row was not replayed: agent calls=$(lwf_agents)"
grep -q '^POST /api/lead-reviews/r-201/result .*"reviewer_model":"lead-replay"' "$T/log/worker" && ok \
  || bad "A7 no replay result for the worklist row: $(grep result "$T/log/worker")"

echo "lead-enqueue-retired.bh-8589: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
