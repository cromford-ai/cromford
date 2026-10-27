#!/bin/bash
# tests/lead-enqueue-lane-retired.bh-8363-test.sh — BH-8363 (BH-7236.2, slice
# C1): the lane lead-review-enqueue is out of the lane registry and out of the
# cron fragments. The D1 row lane_boxes {lead-review-enqueue, hub} stays, and
# the db-mode hub render ignores it: bin/render-cron.sh overlays D1 rows on
# file lanes only (`.lanes |= map(...)`), and no file lane has that id.
#   R1  catalog/lanes.d/lead-review-enqueue.json and its .knobs.d do not exist.
#   R2  cron/lanes/713-lead-review-enqueue.cron does not exist; no
#       cron/lanes/*.cron or cron/boxes/*.d/*.cron file runs the enqueue.
#   R3  a scratch bin/lanes-build.sh --write renders no lane with the id
#       lead-review-enqueue and no lane with the script bin/lead-review-enqueue.sh.
#   R4  the hub render in db mode over a registry cache that holds the D1 row:
#       rc 0, output, no non-comment line that names lead-review-enqueue.
#   D1-D4  the runs_enqueue matcher: a schedule line and an indented pr-mode
#       line are runs; a comment that names the script and a live line that
#       names state/lead-review-enqueue/ are not.
#   M1  (D1) a minimal lane JSON put back, no 713 fragment, same D1 row: the
#       db-mode render exits 1 with `registry lanes with no cron/lanes
#       fragment: lead-review-enqueue`. R4 sees the row, and the deletion of
#       both files is what keeps the render green.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-enqueue-lane-retired.bh-8363-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/registry-cache.bh-5651.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# runs_enqueue <file>: rc 0 when a non-comment line of <file> runs the enqueue.
runs_enqueue() {
  grep -v '^[[:space:]]*#' "$1" 2>/dev/null | grep -q 'bin/lead-review-enqueue\.sh'
}

# ── R1: no lane JSON ──
[ ! -e "$DIR/catalog/lanes.d/lead-review-enqueue.json" ] && ok || bad "R1 catalog/lanes.d/lead-review-enqueue.json exists"
[ ! -e "$DIR/catalog/lanes.d/lead-review-enqueue.knobs.d" ] && ok || bad "R1 catalog/lanes.d/lead-review-enqueue.knobs.d exists"

# ── R2: no 713 fragment, no fragment runs the enqueue ──
[ ! -e "$DIR/cron/lanes/713-lead-review-enqueue.cron" ] && ok || bad "R2 cron/lanes/713-lead-review-enqueue.cron exists"
NF=0; HITS=""
for f in "$DIR"/cron/lanes/*.cron "$DIR"/cron/boxes/*.d/*.cron; do
  [ -f "$f" ] || continue
  NF=$((NF + 1))
  runs_enqueue "$f" && HITS="$HITS ${f#"$DIR"/}"
done
[ -z "$HITS" ] && ok || bad "R2 fragments run the enqueue:$HITS"
[ "$NF" -ge 20 ] && ok || bad "R2 scanned $NF fragments, want 20 or more"

# ── D1-D4: the matcher ──
MD="$T/matcher"; mkdir -p "$MD"
printf '*/15 * * * * cd /root/harness && bin/lead-review-enqueue.sh tick >> logs/x.log 2>&1\n' > "$MD/d1.cron"
printf '   bash bin/lead-review-enqueue.sh pr x\n' > "$MD/d2.cron"
printf '# Nothing runs bin/lead-review-enqueue.sh since BH-7235.\n' > "$MD/d3.cron"
printf '*/15 * * * * cd /root/harness && bin/lead-review.sh tick --state state/lead-review-enqueue/ 2>&1\n' > "$MD/d4.cron"
runs_enqueue "$MD/d1.cron" && ok || bad "D1 a schedule line is not a run"
runs_enqueue "$MD/d2.cron" && ok || bad "D2 an indented pr-mode line is not a run"
runs_enqueue "$MD/d3.cron" && bad "D3 a comment line is a run" || ok
runs_enqueue "$MD/d4.cron" && bad "D4 a state/lead-review-enqueue/ line is a run" || ok

# render_db <tree> <out-prefix>: the hub render in db mode over a cache built
# from <tree>'s own registry emit plus the D1 row lead-review-enqueue/hub.
# Same shape as U3 of tests/lead-enqueue-unwired.bh-7235-test.sh.
render_db() {
  local tree="$1" o="$2" hr="$1/hroot"
  scratch_rm "$hr"; mkdir -p "$hr"
  bash "$DIR/bin/registry-seed.sh" --emit --root "$tree" > "$o.emit" 2> "$o.emit.err" || { echo "registry-seed --emit: $(head -3 "$o.emit.err")" > "$o.err"; return 2; }
  jq '.lane_boxes += [{lane: "lead-review-enqueue", box_id: "hub"}]' "$o.emit" > "$o.reg" || return 2
  ( RCACHE_REGISTRY_JSON="$o.reg" rcache_install "$hr" "$tree" > "$o.rc.err" 2>&1 || exit 2
    HARNESS="$hr" bash "$DIR/bin/render-cron.sh" --root "$tree" hub > "$o" 2> "$o.err" )
}
# tree <dir>: a scratch copy of the repo's cron, catalog and fleet.conf.
tree() {
  mkdir -p "$1"
  cp -r "$DIR/cron" "$1/" || return 1
  # A suite run beside this one may rewrite the git-ignored catalog/lanes.json
  # while cp reads it; lanes-build renders it again below anyway.
  cp -r "$DIR/catalog" "$1/" 2>/dev/null; [ -d "$1/catalog/lanes.d" ] || return 1
  cp "$DIR/fleet.conf" "$1/"
}

# ── R3: the rendered lane registry has no such lane ──
RR="$T/render"
tree "$RR" && ok || bad "R3 setup: copy cron, catalog, fleet.conf"
if bash "$DIR/bin/lanes-build.sh" --root "$RR" --write > "$T/lb.out" 2>&1; then ok; else bad "R3 lanes-build --write: $(head -5 "$T/lb.out")"; fi
[ "$(jq '[.lanes[] | select(.id == "lead-review-enqueue")] | length' "$RR/catalog/lanes.json" 2>/dev/null)" = 0 ] && ok \
  || bad "R3 lanes.json has a lead-review-enqueue lane: $(jq -c '[.lanes[] | select(.id == "lead-review-enqueue") | .id]' "$RR/catalog/lanes.json" 2>&1)"
[ "$(jq '[.lanes[] | select(.script == "bin/lead-review-enqueue.sh")] | length' "$RR/catalog/lanes.json" 2>/dev/null)" = 0 ] && ok \
  || bad "R3 lanes.json has a lane with script bin/lead-review-enqueue.sh"

# ── R4: the hub in db mode, the D1 row still there ──
render_db "$RR" "$T/db.hub"; RC=$?
[ "$RC" = 0 ] && ok || bad "R4 db-mode hub render rc=$RC: $(head -3 "$T/db.hub.err" 2>/dev/null) $(cat "$T/db.hub.rc.err" 2>/dev/null)"
jq -e '.lane_boxes | any(.lane == "lead-review-enqueue" and .box_id == "hub")' "$RR/hroot/state/registry/registry.json" >/dev/null 2>&1 \
  && ok || bad "R4 setup: the cache does not hold the lead-review-enqueue/hub row"
[ -s "$T/db.hub" ] && ok || bad "R4 the db-mode render printed nothing"
hit=$(grep -v '^[[:space:]]*#' "$T/db.hub" | grep 'lead-review-enqueue') && bad "R4 db mode has an enqueue line: $hit" || ok

# ── M1: the lane JSON put back with no 713 fragment -> the render refuses ──
RM="$T/render-m1"
tree "$RM" && ok || bad "M1 setup: copy cron, catalog, fleet.conf"
rm -f "$RM/cron/lanes/713-lead-review-enqueue.cron"
cat > "$RM/catalog/lanes.d/lead-review-enqueue.json" <<'JSON'
{
  "id": "lead-review-enqueue",
  "name": "Lead review auto-request",
  "scope": "hub",
  "script": "bin/lead-review-enqueue.sh",
  "cadence": "*/15 * * * *",
  "boxes": [],
  "switch": {"kind": "flag", "name": "lane-off-lead-review-enqueue", "aliases": []},
  "wired": true,
  "knobs": [],
  "stats": {"cost_stage": null, "cost_project_filter": null, "lanes_row": false, "log": "logs/lead-review-enqueue.log"}
}
JSON
if bash "$DIR/bin/lanes-build.sh" --root "$RM" --write > "$T/lb-m1.out" 2>&1; then ok; else bad "M1 lanes-build --write: $(head -5 "$T/lb-m1.out")"; fi
render_db "$RM" "$T/m1.hub"; RC=$?
[ "$RC" = 1 ] && ok || bad "M1 db-mode render with the lane JSON and no stub rc=$RC (want 1): $(head -3 "$T/m1.hub.err" 2>/dev/null)"
grep -q 'registry lanes with no cron/lanes fragment: *lead-review-enqueue' "$T/m1.hub.err" 2>/dev/null && ok \
  || bad "M1 no 'registry lanes with no cron/lanes fragment: lead-review-enqueue' line: $(head -3 "$T/m1.hub.err" 2>/dev/null)"

echo "lead-enqueue-lane-retired.bh-8363: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
