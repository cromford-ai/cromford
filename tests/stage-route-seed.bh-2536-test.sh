#!/bin/bash
# tests/stage-route-seed.bh-2536-test.sh — BH-2536: every stage a catalogued
# agent-call site passes has a seeded stage.<x> route, so the Models page can
# switch any of them. Loads the REAL worker/jobs/schema.sql into node:sqlite
# (the SQL harness-sync applies) and reads the REAL catalog/llm-sites.json.
#   R1  every through_agent_call stage token has a hub-scope rung-0 stage.<x> row
#   R2  every token is a plain stage name (a typo or $VAR fails, not skips)
#   R3  the stages run-build passes to `CC <stage>` are all on the rb-plan row
#   R4  each BH-2536 role is one rung, runner claude, updated_by seed
#   R5  no stage.verify row, no row for a claude-cost / raw-vendor site's stage
#   R6  a stage whose caller pins the runner in code (or that only claude can
#       run) has NO seeded row, and the pin is still in that caller — drop the
#       pin and the stage owes a row again
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
SCHEMA="$DIR/worker/jobs/schema.sql"
SITES="$DIR/catalog/llm-sites.json"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NEW_ROLES="qa preplan-files prodqa repro lead-review map signals ideate synth prd mockup revise remediate mine feature-map-draft readout chat"
# stage<TAB>caller<TAB>ERE that proves the caller decides the runner itself. A
# route for these would be a Models-page switch that changes nothing, and a
# non-claude pin next to it is an ALERTS line nobody can act on. Bootstrap's
# smoke (stage probe, BH-2535) is one that only claude can run: a fallback rung
# answering OK would green a dead claude login, so it pins AGENT_CALL_RUNNERS.
# The canary stage is the same (BH-2562): all three callers (lane-probe,
# claude-auth-check, oauth-refresh) pin AGENT_CALL_RUNNERS so no other rung can
# answer for the credential under test, so a stage.canary route would be a
# switch that changes nothing.
PINNED=$'decompose\tbin/run-decompose.sh\t^export RUNNER_DECOMPOSE=
orchestrator\tbin/orchestrate.sh\tenv RUNNER_ORCHESTRATOR="\\$r"
trapeval\tbin/trap-eval.sh\tRUNNER_TRAPEVAL="\\$runner"
bench\tbin/runner-bench.sh\tRUNNER_BENCH="\\$runner"
eval\tbin/prompt-eval.sh\tAGENT_CALL_NO_TOOLS=1 \\\\$
probe\tbin/bootstrap-machine.sh\t^AGENT_CALL_RUNNERS=claude AGENT_CALL_LANE=claude-auth-check
canary\tbin/oauth-refresh.sh\tAGENT_CALL_RUNNERS=claude AGENT_CALL_LANE=oauth-refresh'
# Output read first, then grep -q (no pipe for grep -q to close under pipefail).
PINNED_STAGES=$(cut -f1 <<<"$PINNED")
is_pinned() { grep -qx -- "$1" <<<"$PINNED_STAGES"; }

# role<TAB>position<TAB>runner<TAB>updated_by for every hub-scope stage.* row.
node -e '
const { DatabaseSync } = require("node:sqlite");
const db = new DatabaseSync(":memory:");
db.exec(require("fs").readFileSync(process.argv[1], "utf8"));
for (const r of db.prepare("SELECT role, position, runner, updated_by FROM model_routes WHERE project IS NULL AND role LIKE ? ORDER BY role, position").all("stage.%"))
  console.log([r.role, r.position, r.runner, r.updated_by].join("\t"));
' "$SCHEMA" > "$T/rows.tsv" 2> "$T/node.err" || { echo "FAIL: schema.sql did not load: $(cat "$T/node.err")"; exit 1; }
[ -s "$T/rows.tsv" ] || { echo "FAIL: no stage.* rows at all"; exit 1; }

# One token per line for each through_agent_call site (split on |, skip *, lowercase),
# and separately for the sites that never reach agent-call.
python3 - "$SITES" "$T" <<'PY' || { echo "FAIL: llm-sites.json unreadable"; exit 1; }
import json, sys
sites = json.load(open(sys.argv[1]))["sites"]
out = {True: open(sys.argv[2] + "/tokens.txt", "w"), False: open(sys.argv[2] + "/offtokens.txt", "w")}
rb = open(sys.argv[2] + "/rbplan.txt", "w")
for s in sites:
    for t in str(s.get("stage", "")).split("|"):
        t = t.strip().lower()
        if t and t != "*":
            out[bool(s.get("through_agent_call"))].write(t + "\n")
            if s.get("id") == "rb-plan":
                rb.write(t + "\n")
PY
sort -u -o "$T/tokens.txt" "$T/tokens.txt"
[ -s "$T/tokens.txt" ] || { echo "FAIL: no agent-call stages in the census"; exit 1; }

has_rung0() { awk -F'\t' -v r="stage.$1" '$1==r && $2==0 {f=1} END {exit !f}' "$T/rows.tsv"; }

# R1 + R2
missing=""
while read -r tok; do
  if ! grep -Eq '^[a-z][a-z0-9-]*$' <<<"$tok"; then bad "R2 census stage '$tok' is not a plain stage name"; continue; fi
  ok
  is_pinned "$tok" && continue
  if has_rung0 "$tok"; then ok; else missing="$missing $tok"; fi
done < "$T/tokens.txt"
[ -z "$missing" ] && ok || bad "R1 no seeded stage.<x> rung-0 route for:$missing"

# R3: what run-build really calls is on the census row. Read as ONE text
# (tests/lib/rb-all.sh), the way every suite that reads the pipeline does.
. "$(dirname "$0")/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
grep -hoE '^[^#]*\bCC [a-z][a-z0-9-]* "' "$RB_ALL" \
  | grep -oE 'CC [a-z0-9-]+ "$' | awk '{print $2}' | sort -u > "$T/cc.txt"
[ -s "$T/cc.txt" ] || bad "R3 found no CC <stage> call in run-build (pattern drifted)"
unlisted=""
while read -r st; do grep -qx "$st" "$T/rbplan.txt" || unlisted="$unlisted $st"; done < "$T/cc.txt"
[ -z "$unlisted" ] && ok || bad "R3 run-build calls CC with stages the rb-plan census row omits:$unlisted"

# R4: current behaviour preserved — one claude rung, seeded.
for s in $NEW_ROLES; do
  got=$(awk -F'\t' -v r="stage.$s" '$1==r {printf "%s:%s:%s;", $2, $3, $4}' "$T/rows.tsv")
  [ "$got" = "0:claude:seed;" ] && ok || bad "R4 stage.$s ladder is '$got', want '0:claude:seed;'"
done

# R5 negatives.
grep -q . <<<"$(awk -F'\t' '$1=="stage.verify"' "$T/rows.tsv")" && bad "R5 a stage.verify row is seeded (nothing calls CC verify)" || ok
while read -r tok; do
  grep -qx "$tok" "$T/tokens.txt" && continue   # also an agent-call stage
  role=$(printf '%s' "$tok" | tr -c 'a-z0-9-\n' '_')
  grep -q . <<<"$(awk -F'\t' -v r="stage.$role" -v raw="stage.$tok" '$1==r || $1==raw' "$T/rows.tsv")" \
    && bad "R5 non-agent-call stage '$tok' has a seeded route" || ok
done < <(sort -u "$T/offtokens.txt")
grep -q . <<<"$(awk -F'\t' '$1=="stage.raw" || $1=="stage.$cost_stage"' "$T/rows.tsv")" && bad "R5 stage.raw/\$cost_stage seeded" || ok

# R6: the pinned stages — no row, the pin still where it is claimed, and each
# is really an agent-call stage (a stale entry here would hide nothing).
while IFS=$'\t' read -r st file re; do
  grep -qx "$st" "$T/tokens.txt" && ok || bad "R6 pinned stage '$st' is not an agent-call stage in the census"
  grep -Eq -- "$re" "$DIR/$file" && ok || bad "R6 $file no longer pins stage $st ('$re' gone) — seed stage.$st"
  grep -q . <<<"$(awk -F'\t' -v r="stage.$st" '$1==r' "$T/rows.tsv")" && bad "R6 stage.$st is seeded but $file decides its runner" || ok
done <<<"$PINNED"

echo "stage-route-seed.bh-2536: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
