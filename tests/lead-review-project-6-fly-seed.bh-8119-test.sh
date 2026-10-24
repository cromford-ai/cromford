#!/bin/bash
# tests/lead-review-project-6-fly-seed.bh-8119-test.sh — BH-8119 (the rest of
# BH-8027): the composed jobs schema seeds
# lane_placement.lead-review.project-6-os=fly, so project-6-os lead reviews go
# to the Fly pool after the deploy applies it, and no other project moves.
#
# The schema is the REAL composition of worker/jobs/schema.d/, loaded into an
# in-memory node:sqlite DB. The answer is read through the REAL setting_get
# (bin/lib/jobs/settings.sh), lp_decide (bin/lib/lane-placement.sh) and
# lrp_placed (bin/lib/lead-pool.sh). Only the HTTP call (_jobs_req) and
# queue_routing_facts are stubs: _jobs_req answers from the DB's settings rows.
#
#   S1  exactly 1 row lane_placement.lead-review.project-6-os, value fly
#   S2  no lane row lane_placement.lead-review, no other lead-review project row
#   a   seeded fly + routing pool|0 -> placed (rc 0)
#   b   seeded fly + routing pool|1 (halted) -> box
#   c   seeded fly + routing local|0 -> box
#   d   an operator row box before the seed applies stays box -> box
#   e   row ' FLY ' -> fly after trim and lowercase -> placed
#   f   fixture-other-os, routing pool|0, no row -> box
#
# Run from anywhere: tests/lead-review-project-6-fly-seed.bh-8119-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-6005: worker/jobs/schema.sql is composed from schema.d/, not committed.
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SCHEMA="$DIR/worker/jobs/schema.sql"
FRAG="$DIR/worker/jobs/schema.d/202610230754-bh-8119-lead-review-project-6-fly.sql"
KEY=lane_placement.lead-review.project-6-os
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
  || { echo "SKIP: node or jq missing"; exit 0; }
node -e "require('node:sqlite')" 2>/dev/null || { echo "SKIP: node has no node:sqlite"; exit 0; }
T=$(mktemp -d "${TMPDIR:-/tmp}/bh8119.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

# settings_dump <out.tsv> [<sql before the re-apply>] — load the composed schema
# into a fresh DB, run the optional operator SQL, apply this ticket's fragment
# again (a deploy re-applies every fragment), and write key<TAB>value per row.
settings_dump() {
  node --no-warnings --input-type=module -e '
import { DatabaseSync } from "node:sqlite";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
const [schema, frag, out, pre] = process.argv.slice(1);
const db = new DatabaseSync(":memory:");
db.exec(readFileSync(schema, "utf8"));
if (pre) db.exec(pre);
if (existsSync(frag)) db.exec(readFileSync(frag, "utf8"));
const rows = db.prepare("SELECT key, value FROM settings ORDER BY key").all();
writeFileSync(out, rows.map(r => `${r.key}\t${r.value}`).join("\n") + "\n");
' "$SCHEMA" "$FRAG" "$1" "${2:-}"
}

# The decision, in a subshell: the real setting_get over the dump, the real
# lp_decide and lrp_placed. Prints placed|box and LP_WHY.
decide() { # decide <dump.tsv> <project> <routing>
  ( export HARNESS="$T/h" JOBS_BOX=test; DUMP="$1"; ROUTING="$3"
    mkdir -p "$HARNESS/state"
    # shellcheck source=bin/lib/jobs/settings.sh
    . "$DIR/bin/lib/jobs/settings.sh" || exit 9
    _jobs_req() {
      local k="${2#/api/settings/}"
      awk -F'\t' -v k="$k" '$1 == k {print $2; f=1} END {exit !f}' "$DUMP" > "$T/v" \
        && jq -nc --rawfile v "$T/v" '{setting: {value: ($v | rtrimstr("\n"))}}' || echo '{}'
    }
    queue_routing_facts() { printf '%s' "$ROUTING"; }
    log() { :; }
    # shellcheck source=bin/lib/lane-placement.sh
    . "$DIR/bin/lib/lane-placement.sh" || exit 9
    # shellcheck source=bin/lib/lead-pool.sh
    . "$DIR/bin/lib/lead-pool.sh" || exit 9
    if lrp_placed "$2"; then w=placed; else w=box; fi
    lp_decide lead-review "$2"
    printf '%s|%s' "$w" "$LP_WHY" )
}

echo "S: the composed schema"
[ -s "$FRAG" ] && ok "S0 fragment exists" || bad "S0 no fragment $FRAG"
settings_dump "$T/seed.tsv" || { bad "S could not load the composed schema"; echo "$PASS passed, $FAIL failed"; exit 1; }
n=$(awk -F'\t' -v k="$KEY" '$1 == k' "$T/seed.tsv" | wc -l)
v=$(awk -F'\t' -v k="$KEY" '$1 == k {print $2}' "$T/seed.tsv")
[ "$n" = 1 ] && [ "$v" = fly ] && ok "S1 exactly 1 row $KEY = fly" || bad "S1 rows=$n value='$v'"
other=$(awk -F'\t' -v k="$KEY" '$1 ~ /^lane_placement\.lead-review(\.|$)/ && $1 != k {print $1}' "$T/seed.tsv" | tr '\n' ' ')
[ -z "$other" ] && ok "S2 no lane row and no other lead-review project row" || bad "S2 other rows: $other"

echo "D: lrp_placed on the seeded schema"
D=$(decide "$T/seed.tsv" project-6-os 'pool|0')
[ "$D" = "placed|$KEY=fly" ] && ok "a fly + pool|0 -> placed ($D)" || bad "a -> $D"
D=$(decide "$T/seed.tsv" project-6-os 'pool|1')
[ "${D%%|*}" = box ] && ok "b fly + pool|1 (halted) -> box" || bad "b -> $D"
D=$(decide "$T/seed.tsv" project-6-os 'local|0')
[ "${D%%|*}" = box ] && ok "c fly + local|0 -> box" || bad "c -> $D"

settings_dump "$T/op.tsv" "UPDATE settings SET value='box', actor='op' WHERE key='$KEY'" \
  || bad "d could not load the schema with the operator row"
v=$(awk -F'\t' -v k="$KEY" '$1 == k {print $2}' "$T/op.tsv")
[ "$v" = box ] && ok "d an operator value box survives the seed re-apply" || bad "d value after re-apply: '$v'"
D=$(decide "$T/op.tsv" project-6-os 'pool|0')
[ "${D%%|*}" = box ] && ok "d operator box + pool|0 -> box" || bad "d -> $D"

settings_dump "$T/case.tsv" "UPDATE settings SET value=' FLY ' WHERE key='$KEY'" \
  || bad "e could not load the schema with ' FLY '"
D=$(decide "$T/case.tsv" project-6-os 'pool|0')
[ "$D" = "placed|$KEY=fly" ] && ok "e ' FLY ' + pool|0 -> placed" || bad "e -> $D"

D=$(decide "$T/seed.tsv" fixture-other-os 'pool|0')
[ "${D%%|*}" = box ] && ok "f fixture-other-os (no row) + pool|0 -> box ($D)" || bad "f -> $D"

echo "lead-review-project-6-fly-seed.bh-8119: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
