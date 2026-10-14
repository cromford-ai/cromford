#!/bin/bash
# tests/triage-route-off-grok.bh-3224-test.sh — BH-3224: project triage is
# pinned off grok by a settings row, not code. Loads the REAL
# worker/jobs/schema.sql into node:sqlite (the SQL harness-sync applies) and
# drives the REAL bin/lib/lane-gate.sh the run-triage lane sources.
#   S5  settings has lane.run-triage.runner_triage=claude, actor seed (an
#       operator row, not a registry mirror)
#   S6  an operator's value (codex) survives a re-apply (INSERT OR IGNORE)
#   S7  the diff adds no claude-/grok-/gpt- model id under bin/, catalog/ or
#       worker/ (skipped, and said so, with no merge-base)
#   S8  that row, as the box settings cache carries it, beats a box env
#       RUNNER_TRIAGE=grok through lane_env_apply run-triage
#   S9  no row: lane_env_apply leaves RUNNER_TRIAGE=grok alone (S8 is not vacuous)
#   bash tests/triage-route-off-grok.bh-3224-test.sh     exit 0 = all pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rendered.sh" || exit 1
SCHEMA="$DIR/worker/jobs/schema.sql"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
KEY=lane.run-triage.runner_triage

# sql <db file> <apply 0|1> <statement> — optionally apply the whole schema to
# the file database, then run one statement; SELECT rows print as value|actor.
sql() {
  node --no-warnings -e '
const { DatabaseSync } = require("node:sqlite");
const fs = require("fs");
const db = new DatabaseSync(process.argv[1]);
if (process.argv[2] === "1") db.exec(fs.readFileSync(process.argv[3], "utf8"));
const q = process.argv[4];
if (/^\s*select/i.test(q)) for (const r of db.prepare(q).all()) console.log(Object.values(r).join("|"));
else db.exec(q);
' "$1" "$2" "$SCHEMA" "$3"
}

DB="$T/d1.sqlite"
sql "$DB" 1 "SELECT 1" > /dev/null 2> "$T/node.err" || { echo "FAIL: schema.sql did not load: $(cat "$T/node.err")"; exit 1; }

# S5
ROW=$(sql "$DB" 0 "SELECT value, actor FROM settings WHERE key='$KEY'")
[ "$ROW" = "claude|seed" ] && ok || bad "S5: $KEY is claude by actor seed (got '$ROW')"

# S6
sql "$DB" 0 "UPDATE settings SET value='codex', actor='operator' WHERE key='$KEY'"
sql "$DB" 1 "SELECT 1" > /dev/null
ROW=$(sql "$DB" 0 "SELECT value, actor FROM settings WHERE key='$KEY'")
[ "$ROW" = "codex|operator" ] && ok || bad "S6: an operator's value survives a re-apply (got '$ROW')"

# S7
# S7 SCOPE (2026-09-29, Sonnet 5.5): catalog/model-prices.json and
# catalog/model-slugs.json are the fleet's one sanctioned list of model ids
# (PUT /api/model-routes refuses a model with no price row), so a new vendor
# model has to land there. They are excluded; every other path under bin/,
# catalog/ and worker/ is still scanned exactly as before.
# BH-4987: worker/*/schema.d/ fragments are the bytes of worker/*/schema.sql
# (bin/schema-build.sh --check keeps them equal), so a literal is judged once,
# on schema.sql, and a seed row moved between fragments is not an addition.
BASE=$(git -C "$DIR" merge-base HEAD origin/main 2>/dev/null) || BASE=""
if [ -n "$BASE" ]; then
  HITS=$(git -C "$DIR" diff "$BASE" -- bin catalog worker ':(exclude)catalog/model-prices.json' ':(exclude)catalog/model-slugs.json' ':(exclude,glob)worker/*/schema.d/**' | grep -E '^\+.*(claude-[a-z]+-[0-9]|grok-[0-9]|gpt-[0-9])')
  [ -z "$HITS" ] && ok || bad "S7: a model id was added under bin/catalog/worker: $HITS"
else
  echo "S7: skipped (no origin/main in this checkout)"
fi

# S8 / S9 — the row through the reader run-triage.sh actually calls.
H="$T/h"; mkdir -p "$H/state" "$H/logs" "$H/flags" "$H/catalog"
cp "$(rendered_registry)" "$H/catalog/lanes.json"
NOW=$(date -u +%s)
apply() { # apply <values json> — RUNNER_TRIAGE after lane_env_apply run-triage, box env grok
  jq -nc --argjson fa "$NOW" --argjson v "$1" '{fetched_at:$fa,values:$v,seeded:{}}' > "$H/state/settings-cache.json"
  ( unset HARNESS_SECRET JOBS_URL CONSOLE_URL
    env HARNESS="$H" LANE_REGISTRY="$H/catalog/lanes.json" LANE_GATE_NOW="$NOW" RUNNER_TRIAGE=grok bash -c '
      set -uo pipefail
      . "$1/bin/lib/lane-gate.sh"
      lane_env_apply run-triage cromford
      printf "%s" "${RUNNER_TRIAGE:-UNSET}"' _ "$DIR" 2>/dev/null )
}
SEEDED=$(sql "$T/fresh.sqlite" 1 "SELECT json_object(key, value) FROM settings WHERE key='$KEY'")
[ -n "$SEEDED" ] || bad "S8: the schema seeded no $KEY row to feed the cache"
V=$(apply "${SEEDED:-{\}}")
[ "$V" = claude ] && ok || bad "S8: the seeded row beats the box env RUNNER_TRIAGE=grok (got '$V')"
V=$(apply '{}')
[ "$V" = grok ] && ok || bad "S9: with no row the box env stands (got '$V')"

echo "triage-route-off-grok.bh-3224: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
