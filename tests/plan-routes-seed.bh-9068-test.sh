#!/bin/bash
# tests/plan-routes-seed.bh-9068-test.sh — BH-9068: the model_routes seed puts
# stage.plan rank 0 on the plan role's rank 0 (claude-opus-5-5) and
# stage.preplan rank 0 on triage.light's rank 0 (claude-sonnet-5) on a fresh
# DB, with no new model literal (runner-routes.bh-1766 S4), additive only, and
# never overrules an operator.
#
# The REAL composed schema (bin/schema-build.sh --to) is applied to an
# in-memory SQLite DB with python3's sqlite3, the same engine family as D1.
#
#   R1  fresh DB: stage.plan 0 = opus/claude, stage.preplan 0 = sonnet-5/claude,
#       rank 1 of both stays gpt-6-astra/codex, no claude-fable-5-1 in either
#   R2  a re-apply of the whole schema changes nothing
#   R3  a live DB that still holds the old Fable seed rung keeps it on the next
#       apply: schema.d is additive only (schema-additive.bh-1000), and the
#       live move is the owner's audited PUT /api/model-routes/<role>
#   R4  a role with a model_route_changes row (any rank) keeps rank 0 as it is
#   R5  a rung an operator wrote (updated_by not 'seed') keeps its model
#   R7  a seed rung with a later seed stamp keeps its model
#   R8  a role with audit history and no rank 0 (an operator cut it) is not
#       refilled by a re-apply
#   R6  the ticket's live models (claude-opus-5-5, claude-sonnet-5-5) have a
#       price row in catalog/model-prices.json, so the owner's PUT accepts them
# Run from anywhere: HARNESS_TEST_SANDBOX=1 tests/plan-routes-seed.bh-9068-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
python3 -I -c 'import sqlite3' 2>/dev/null || { echo "python3 sqlite3 missing — skipping"; exit 0; }

HARNESS_TEST_SANDBOX=1 bash "$REPO/bin/schema-build.sh" --root "$REPO" --worker jobs --to "$T/schema.sql" >/dev/null 2>&1 \
  || { echo "FAIL: bin/schema-build.sh --to failed"; exit 1; }

GOT=$(python3 -I - "$T/schema.sql" <<'PY' 2>&1
import sqlite3, sys
schema = open(sys.argv[1]).read()
db = sqlite3.connect(":memory:")
db.executescript(schema)
def rungs(role):
    return ",".join("%d:%s/%s" % r for r in db.execute(
        "SELECT position, model, runner FROM model_routes WHERE project IS NULL AND role=? ORDER BY position", (role,)))
out = []
out.append("R1 plan=" + rungs("stage.plan"))
out.append("R1 preplan=" + rungs("stage.preplan"))
db.executescript(schema)
out.append("R2 plan=" + rungs("stage.plan") + " preplan=" + rungs("stage.preplan"))
# R3: the old seed rung on a live DB (the 0002 seed stamp), no audit row. The
# apply is additive, so it stays until the owner's PUT moves it.
db.execute("UPDATE model_routes SET model='claude-fable-5-1', updated_at='2026-09-24T00:00:00Z' WHERE project IS NULL AND role IN ('stage.plan','stage.preplan') AND position=0")
db.executescript(schema)
out.append("R3 plan=" + rungs("stage.plan") + " preplan=" + rungs("stage.preplan"))
# R4: the role has audit history (an operator PUT its rank 1), and rank 0 is
# still the old seed rung: the role is the operator's, so it stays.
# R5: an operator wrote stage.preplan rank 0 (its own updated_by), no audit row.
db.execute("UPDATE model_routes SET model='claude-fable-5-1', updated_at='2026-09-24T00:00:00Z' WHERE project IS NULL AND role='stage.plan' AND position=0")
db.execute("INSERT INTO model_route_changes (scope, project, role, position, before_model, before_runner, after_model, after_runner, actor, reason, at) "
           "VALUES ('hub', NULL, 'stage.plan', 1, 'gpt-6-astra', 'codex', 'gpt-6-astra', 'codex', 'console:fixture', 'fixture', '2026-11-05T01:00:00Z')")
db.execute("UPDATE model_routes SET model='claude-fable-5-1', updated_by='console:fixture', updated_at='2026-09-24T00:00:00Z' WHERE project IS NULL AND role='stage.preplan' AND position=0")
db.executescript(schema)
out.append("R4 plan=" + rungs("stage.plan"))
out.append("R5 preplan=" + rungs("stage.preplan"))
# R7: a seed rung a LATER seed wrote (another stamp) is not the 0002 seed: it stays.
db.execute("UPDATE model_routes SET model='claude-fable-5-1', updated_by='seed', updated_at='2026-12-01T00:00:00Z' WHERE project IS NULL AND role='stage.preplan' AND position=0")
db.executescript(schema)
out.append("R7 preplan=" + rungs("stage.preplan"))
# R8: stage.plan has an audit row (R4); an operator cut its rank 0.
db.execute("DELETE FROM model_routes WHERE project IS NULL AND role='stage.plan' AND position=0")
db.executescript(schema)
out.append("R8 plan=" + rungs("stage.plan"))
print("\n".join(out))
PY
)
line() { printf '%s\n' "$GOT" | grep -F -- "$1" | head -1; }
[ "$(line 'R1 plan=')" = "R1 plan=0:claude-opus-5-5/claude,1:gpt-6-astra/codex" ] && ok || bad "R1 stage.plan on a fresh DB: $(line 'R1 plan=') :: $GOT"
[ "$(line 'R1 preplan=')" = "R1 preplan=0:claude-sonnet-5/claude,1:gpt-6-astra/codex" ] && ok || bad "R1 stage.preplan on a fresh DB: $(line 'R1 preplan=')"
grep -q 'fable' <<<"$(grep '^R1 ' <<<"$GOT")" && bad "R1 claude-fable-5-1 is still in a plan ladder" || ok
[ "$(line "R2 ")" = "R2 plan=0:claude-opus-5-5/claude,1:gpt-6-astra/codex preplan=0:claude-sonnet-5/claude,1:gpt-6-astra/codex" ] && ok || bad "R2 a re-apply changed the ladders: $(line R2)"
[ "$(line "R3 ")" = "R3 plan=0:claude-fable-5-1/claude,1:gpt-6-astra/codex preplan=0:claude-fable-5-1/claude,1:gpt-6-astra/codex" ] && ok || bad "R3 the apply moved a live rung (schema.d must stay additive): $(line R3)"
[ "$(line "R4 ")" = "R4 plan=0:claude-fable-5-1/claude,1:gpt-6-astra/codex" ] && ok || bad "R4 an audited operator choice was overruled: $(line R4)"
[ "$(line "R5 ")" = "R5 preplan=0:claude-fable-5-1/claude,1:gpt-6-astra/codex" ] && ok || bad "R5 an operator-written rung was overruled: $(line R5)"

[ "$(line "R7 ")" = "R7 preplan=0:claude-fable-5-1/claude,1:gpt-6-astra/codex" ] && ok || bad "R7 a rung a later seed wrote was moved: $(line "R7 ")"
[ "$(line "R8 ")" = "R8 plan=1:gpt-6-astra/codex" ] && ok || bad "R8 a re-apply refilled a rank 0 an operator cut: $(line "R8 ")"

# R6 ---------------------------------------------------------------------------
for m in claude-opus-5-5 claude-sonnet-5-5; do
  jq -e --arg m "$m" '.per_token | has($m)' "$REPO/catalog/model-prices.json" >/dev/null 2>&1 \
    && ok || bad "R6 $m has no row in catalog/model-prices.json"
done

echo "plan-routes-seed.bh-9068: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
