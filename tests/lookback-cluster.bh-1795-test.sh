#!/bin/bash
# tests/lookback-cluster.bh-1795-test.sh — BH-1795.2 (BH-3327): the lookback
# lane's clustering call, lookback_cluster_run in bin/lib/lookback-cluster.sh,
# and the mechanical validator that drops any cluster whose key is not true of
# every item.
#
# The unit cases source the REAL lib and bin/lib/lookback-common.sh from a
# scratch $HARNESS ($T/h) and call lookback_cluster_run directly. L2, L5 and L6
# drive the real bin/lookback.sh. lane-model.sh, agent-call.sh, alert-line.sh,
# the collector, jobs-client and lane-alert are stubs:
#   STUB_ROUTE_MODEL / STUB_ROUTE_RUNNER  the route (unset model = no route, rc 75)
#   STUB_ANSWER                           the file agent-call copies to its outfile
#   STUB_CALL_RC                          agent-call's exit code
#
#   C1  one file cluster over two reopens -> one valid cluster, stable fingerprint
#   D1  a second run on the same bundle with the .done marker present: no call
#   N1-N11  each adversarial answer -> [] and invalid: 1 (N5 keeps the first)
#   N6a/N6b prose / truncated JSON -> rc 2, no file, one ALERTS line
#   F1  one ```json fenced block is accepted
#   H1/H2 target resolution; K1/K2 LOOKBACK_CLUSTER_MIN; R1 ranking; E0 []
#   S1  em dashes stripped; M1 the shared item_matches def is the predicate
#   PP1 the pre-pass groups ride in the prompt; P1 no prompt file -> rc 75
#   X1  agent-call rc 1 -> rc 1, no marker, one ALERTS line
#   L2/L2b/L5/L6/L6b through bin/lookback.sh and the route stubs
#   SEED1 the lookback.cluster seed parses through bin/model-route-seed-lint.sh
#   Z1  no `claude-` literal in the lib
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: '$3' not in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: '$3' must not be in: $2" ;; *) ok ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "lookback-cluster.bh-1795-test: SKIPPED — jq missing"; exit 0; }
command -v flock >/dev/null 2>&1 || { echo "lookback-cluster.bh-1795-test: SKIPPED — flock missing"; exit 0; }

LIBF="$DIR/bin/lib/lookback-cluster.sh"
PROMPTF="$DIR/catalog/prompts/lookback-cluster.md"
FX="$DIR/tests/fixtures/lookback/cluster"
REG=$(HARNESS_TEST_SANDBOX=1 bash -c '. "$1/bin/lib/lanes-registry.sh" && lanes_json_path "$1"' _ "$DIR") \
  || { echo "FAIL: could not render the lane registry"; exit 1; }
H="$T/h"
RUN="$H/state/lookback/unit"
OUT="$RUN/clusters.json"

fresh() {
  scratch_rm "$H"; rm -f "$T"/calls.* "$T"/prompt.* "$T/out"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$H/locks" "$H/catalog/prompts" "$RUN"
  : > "$H/env/global.env"
  cp "$DIR/bin/lookback.sh" "$H/bin/"
  cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/lanes-registry.sh" "$DIR/bin/lib/env-path.sh" \
     "$DIR/bin/lib/lookback-common.sh" "$H/bin/lib/"
  [ -r "$LIBF" ] && cp "$LIBF" "$H/bin/lib/"
  cp "$PROMPTF" "$H/catalog/prompts/"
  cp "$REG" "$H/catalog/lanes.json"
  cat > "$H/bin/lib/lane-model.sh" <<'SH'
lane_model() { local v="${!1:-}"; [ -n "$v" ] && { echo "$v"; return 0; }
  [ -n "${STUB_ROUTE_MODEL:-}" ] || return 75; echo "$STUB_ROUTE_MODEL"; }
lane_model_ladder() { [ -n "${STUB_ROUTE_MODEL:-}" ] || return 75
  printf '0\t%s\t%s\n' "$STUB_ROUTE_MODEL" "${STUB_ROUTE_RUNNER:-claude}"; }
SH
  cat > "$H/bin/agent-call.sh" <<SH
#!/bin/bash
n=\$(( \$(cat "$T/calls.stub" 2>/dev/null | wc -l) + 1 ))
printf '%s|%s|%s|%s|%s|JOB_ID=%s|BUDGET=%s|RUNNERS=%s|LANE=%s\n' "\$1" "\$2" "\$3" "\$4" "\$5" \
  "\${JOB_ID:-}" "\${AGENT_CALL_BUDGET_USD:-}" "\${AGENT_CALL_RUNNERS:-}" "\${AGENT_CALL_LANE:-}" >> "$T/calls.stub"
printf '%s' "\$6" > "$T/prompt.\$n"
[ -n "\${STUB_ANSWER:-}" ] && cp "\$STUB_ANSWER" "\$5"
exit "\${STUB_CALL_RC:-0}"
SH
  cat > "$H/bin/alert-line.sh" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$H/logs/ALERTS.log"
SH
  cat > "$H/bin/lookback-collect.sh" <<SH
#!/bin/bash
out=""; while [ \$# -gt 0 ]; do [ "\$1" = --out ] && out="\$2"; shift; done
cp "\${STUB_BUNDLE:-$FX/bundle-l2.json}" "\$out"
SH
  cat > "$H/bin/jobs-client.sh" <<'SH'
job_lane_open()  { export JOB_ID=job-stub; }
job_lane_close() { :; }
SH
  cat > "$H/bin/lane-alert.sh" <<SH
#!/bin/bash
a="\$*"; printf '%s\n' "\${a//\$'\n'/ | }" >> "$T/calls.lane-alert"
SH
  chmod +x "$H/bin/"*.sh
}
# unit [VAR=value ...] -> call lookback_cluster_run on $BUNDLE; rc in $RC, stdout in $T/out
BUNDLE="$FX/bundle.json"
unit() {
  env -i PATH="$PATH" HOME="$T" HARNESS="$H" STUB_ROUTE_MODEL=route-model-x "$@" bash -c '
    . "$HARNESS/bin/lib/lookback-common.sh" || exit 91
    . "$HARNESS/bin/lib/lookback-cluster.sh" || exit 92
    lookback_cluster_run "$1" "$2"' _ "$BUNDLE" "$OUT" > "$T/out" 2>&1
  RC=$?
}
drive() {
  env -i PATH="$PATH" HOME="$T" HARNESS="$H" "$@" bash "$H/bin/lookback.sh" > "$T/out" 2>&1
  RC=$?
}
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
fp() { printf '%s|%s|%s|%s' "$1" "$2" "$3" "$4" | sha1sum | cut -c1-16; }

# --- C1: the positive case, and the fingerprint is stable across two real calls
fresh; unit STUB_ANSWER="$FX/answer-c1.json"
eq "C1 rc" "$RC" 0
has "C1 stdout" "$(cat "$T/out")" "invalid: 0"
eq "C1 one cluster" "$(jq -c '[.[]|[.key_kind,.key_value,.target,.project,(.item_ids|join(","))]]' "$OUT" 2>&1)" \
  '[["file","bin/foo.sh","harness","cromford","r1,r2"]]'
FP1=$(jq -r '.[0].fingerprint' "$OUT" 2>/dev/null)
eq "C1 fingerprint = lookback_fingerprint" "$FP1" "$(fp harness cromford file bin/foo.sh)"
case "$FP1" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ok ;; *) bad "C1 fingerprint not 16 hex: $FP1" ;; esac
eq "C1 text kept" "$(jq -r '.[0].title' "$OUT" 2>/dev/null)" "We reopen tickets that touch bin/foo.sh"
has "C1 log line" "$(cat "$H/logs/lookback.log" 2>/dev/null)" "cluster: 1 valid, 0 invalid"
eq "C1 no ALERTS" "$(lines "$H/logs/ALERTS.log")" 0
# D1: same bundle, marker present -> no second call, same result
rm -f "$OUT"; unit STUB_ANSWER="$FX/answer-c1.json"
eq "D1 rc" "$RC" 0
eq "D1 still one call" "$(lines "$T/calls.stub")" 1
eq "D1 same fingerprint from the saved output" "$(jq -r '.[0].fingerprint' "$OUT" 2>/dev/null)" "$FP1"
# C1 second run: marker removed, so the call really repeats
rm -f "$OUT" "$RUN"/cluster-call.*.done; unit STUB_ANSWER="$FX/answer-c1.json"
eq "C1 second call made" "$(lines "$T/calls.stub")" 2
eq "C1 fingerprint identical across runs" "$(jq -r '.[].fingerprint' "$OUT" 2>/dev/null)" "$FP1"

# --- N1..N11: every adversarial answer yields no valid cluster
for c in n1 n2 n3 n4 n7 n8 n9a n9b n10 n11; do
  fresh; unit STUB_ANSWER="$FX/answer-$c.json"
  eq "$c rc" "$RC" 0
  eq "$c clusters_out is []" "$(jq -c . "$OUT" 2>&1)" "[]"
  has "$c stdout" "$(cat "$T/out")" "invalid: 1"
done
# N5: the later cluster reusing r2 is dropped whole; the first one stays
fresh; unit STUB_ANSWER="$FX/answer-n5.json"
eq "N5 rc" "$RC" 0
eq "N5 first kept, second absent" "$(jq -c '[.[]|.item_ids]' "$OUT" 2>&1)" '[["r1","r2"]]'
has "N5 stdout" "$(cat "$T/out")" "invalid: 1"
# N6: prose / truncated JSON -> rc 2, nothing written, one ALERTS line
for c in n6a n6b; do
  fresh; unit STUB_ANSWER="$FX/answer-$c.txt"
  eq "$c rc" "$RC" 2
  [ -e "$OUT" ] && bad "$c clusters_out must not exist" || ok
  has "$c stdout" "$(cat "$T/out")" "invalid: unparseable"
  eq "$c one ALERTS line" "$(lines "$H/logs/ALERTS.log")" 1
  has "$c ALERTS text" "$(cat "$H/logs/ALERTS.log" 2>/dev/null)" "lookback: clustering output unparseable"
done
# F1: one ```json fenced block is accepted
fresh; unit STUB_ANSWER="$FX/answer-f1.txt"
eq "F1 rc" "$RC" 0
eq "F1 one cluster" "$(jq -r '.[].fingerprint' "$OUT" 2>&1)" "$(fp harness cromford file bin/foo.sh)"

# --- H1: no target on a bin/ file key -> harness, project forced
fresh; unit STUB_ANSWER="$FX/answer-h1.json"
eq "H1 target/project" "$(jq -c '[.[]|[.target,.project]]' "$OUT" 2>&1)" '[["harness","cromford"]]'
# H2: target=harness over app items on an app path -> invalid
fresh; unit STUB_ANSWER="$FX/answer-h2.json"
eq "H2 []" "$(jq -c . "$OUT" 2>&1)" "[]"
has "H2 stdout" "$(cat "$T/out")" "invalid: 1"
# K1: LOOKBACK_CLUSTER_MIN=3 makes a 2-item cluster invalid
fresh; unit STUB_ANSWER="$FX/answer-c1.json" LOOKBACK_CLUSTER_MIN=3
eq "K1 []" "$(jq -c . "$OUT" 2>&1)" "[]"
has "K1 stdout" "$(cat "$T/out")" "invalid: 1"
# K2: a non-integer minimum is treated as 2, and says so
fresh; unit STUB_ANSWER="$FX/answer-c1.json" LOOKBACK_CLUSTER_MIN=abc
eq "K2 one cluster" "$(jq 'length' "$OUT" 2>&1)" 1
has "K2 log" "$(cat "$H/logs/lookback.log" 2>/dev/null)" "LOOKBACK_CLUSTER_MIN=abc"
# R1: size desc, then fingerprint; a raw reason key is normalized; a duplicate id collapses
fresh; unit STUB_ANSWER="$FX/answer-r1.json"
eq "R1 rc" "$RC" 0
A=$(fp harness cromford reason "rebase conflict on"); B=$(fp app project-3 file src/x.ts)
if [[ "$A" < "$B" ]]; then TIE="$A $B"; else TIE="$B $A"; fi
eq "R1 order" "$(jq -r '[.[].fingerprint]|join(" ")' "$OUT" 2>&1)" "$(fp harness cromford file bin/foo.sh) $TIE"
eq "R1 3-item first, deduped" "$(jq -c '.[0].item_ids' "$OUT" 2>&1)" '["r1","r2","r3"]'
eq "R1 reason normalized" "$(jq -r '.[]|select(.key_kind=="reason")|.key_value' "$OUT" 2>&1)" "rebase conflict on"
# E0: [] is a success
fresh; unit STUB_ANSWER="$FX/answer-e0.json"
eq "E0 rc" "$RC" 0
eq "E0 []" "$(jq -c . "$OUT" 2>&1)" "[]"
has "E0 stdout" "$(cat "$T/out")" "invalid: 0"
# S1: em dashes stripped from the three text fields
fresh; unit STUB_ANSWER="$FX/answer-s1.json"
eq "S1 text" "$(jq -c '[.[0].title,.[0].cause,.[0].proposed_fix]' "$OUT" 2>&1)" \
  '["We reopen, twice","Merge-half applied","Fix it, now, please"]'
eq "S1 no em dash" "$(jq -r '.[]|.title,.cause,.proposed_fix' "$OUT" | grep -c '—')" 0
# M1: the predicate is the shared item_matches def: make it always false and C1 is []
fresh
sed -i 's/and (\$project == "cromford" or \.project == \$project);/and false;/' "$H/bin/lib/lookback-common.sh"
grep -q 'and false;' "$H/bin/lib/lookback-common.sh" || bad "M1 could not mutate the shared def"
unit STUB_ANSWER="$FX/answer-c1.json"
eq "M1 [] under an always-false item_matches" "$(jq -c . "$OUT" 2>&1)" "[]"

# --- PP1: the candidate groups ride in the prompt; size-1 groups do not
fresh; unit STUB_ANSWER="$FX/answer-e0.json"
P=$(cat "$T/prompt.1" 2>/dev/null)
has "PP1 contract line" "$P" "Answer ONLY a JSON array"
G=$(printf '%s\n' "$P" | awk '/^## Candidate groups/{f=1;next} /^## Items/{f=0} f')
has "PP1 bin/foo.sh group" "$G" '{"key_kind":"file","key_value":"bin/foo.sh","item_ids":["r1","r2","r3"]}'
has "PP1 reason family group" "$G" '"key_value":"review blocked: missing test"'
hasnt "PP1 no size-1 group" "$G" "docs/a.md"
has "PP1 items ride" "$P" '"id":"x1"'
# PP2: a reason rides the prompt cut to 300 chars
fresh; LONG=$(printf 'x%.0s' $(seq 1 500))
jq --arg r "$LONG" '.items[0].reason = $r' "$FX/bundle.json" > "$T/long.json"
BUNDLE="$T/long.json" unit STUB_ANSWER="$FX/answer-e0.json"
eq "PP2 reason cut to 300" "$(awk '/^## Items/{f=1;next} f' "$T/prompt.1" | jq -r 'select(.id=="r1")|.reason|length' 2>&1)" 300
# P1: no prompt file -> rc 75, no spend
fresh; rm -f "$H/catalog/prompts/lookback-cluster.md"; unit STUB_ANSWER="$FX/answer-c1.json"
eq "P1 rc" "$RC" 75
eq "P1 no call" "$(lines "$T/calls.stub")" 0
# X1: agent-call rc 1 -> rc 1, no marker, nothing written, one ALERTS line
fresh; unit STUB_ANSWER="$FX/answer-c1.json" STUB_CALL_RC=1
eq "X1 rc" "$RC" 1
[ -e "$OUT" ] && bad "X1 clusters_out must not exist" || ok
eq "X1 no marker" "$(ls "$RUN" | grep -c '^cluster-call\.')" 0
eq "X1 one ALERTS line" "$(lines "$H/logs/ALERTS.log")" 1
has "X1 ALERTS text" "$(cat "$H/logs/ALERTS.log" 2>/dev/null)" "lookback: clustering call rc=1"

# --- L6 / L6b: resolution
fresh; unit STUB_ANSWER="$FX/answer-c1.json" STUB_ROUTE_RUNNER=grok
eq "L6 rc" "$RC" 75
eq "L6 no call" "$(lines "$T/calls.stub")" 0
eq "L6 one ALERTS line" "$(lines "$H/logs/ALERTS.log")" 1
has "L6 ALERTS names the role" "$(cat "$H/logs/ALERTS.log" 2>/dev/null)" "lookback.cluster"
has "L6 ALERTS names the fix" "$(cat "$H/logs/ALERTS.log" 2>/dev/null)" "PUT /api/model-routes/lookback.cluster"
fresh; unit STUB_ANSWER="$FX/answer-c1.json" STUB_ROUTE_MODEL=
eq "L6b rc" "$RC" 75
eq "L6b no call" "$(lines "$T/calls.stub")" 0
eq "L6b no ALERTS from the lib" "$(lines "$H/logs/ALERTS.log")" 0
has "L6b log" "$(cat "$H/logs/lookback.log" 2>/dev/null)" "no model route for role lookback.cluster"

# --- L2 / L5 / L6 through the real driver (the production entry point)
DRV_RUN() { ls -d "$H"/state/lookback/*/ 2>/dev/null | grep -v /unit/ | head -1; }
fresh; drive STUB_ROUTE_MODEL=route-model-x STUB_ANSWER="$FX/answer-c1.json"
eq "L2 driver rc" "$RC" 0
eq "L2 exactly one agent-call" "$(lines "$T/calls.stub")" 1
C=$(head -1 "$T/calls.stub" 2>/dev/null)
eq "L2 stage|project|model|timeout" "$(printf '%s' "$C" | cut -d'|' -f1-4)" "lookback|lookback|route-model-x|1800"
has "L2 budget env" "$C" "|BUDGET=15|"
has "L2 runners env" "$C" "|RUNNERS=claude|"
has "L2 lane env" "$C" "|LANE=lookback"
has "L5 JOB_ID reaches agent-call" "$C" "|JOB_ID=job-stub|"
P=$(cat "$T/prompt.1" 2>/dev/null)
has "L2 prompt contract" "$P" "Answer ONLY a JSON array"
has "L2 prompt ids r1" "$P" '"id":"r1"'
has "L2 prompt ids r2" "$P" '"id":"r2"'
DR=$(DRV_RUN)
eq "L2 driver clusters.json" "$(jq -r '.[].fingerprint' "${DR}clusters.json" 2>&1)" "$(fp harness cromford file bin/foo.sh)"
has "L2 summary" "$(cat "$T/calls.lane-alert" 2>/dev/null)" "2 items, 1 clusters"
# L2b: an explicit LOOKBACK_MODEL wins over the route
fresh; drive STUB_ROUTE_MODEL=route-model-x LOOKBACK_MODEL=explicit-m STUB_ANSWER="$FX/answer-c1.json"
eq "L2b model" "$(cut -d'|' -f3 "$T/calls.stub" 2>/dev/null)" "explicit-m"
# L6 through the driver: not configured, no call
fresh; drive STUB_ROUTE_MODEL=route-model-x STUB_ROUTE_RUNNER=grok STUB_ANSWER="$FX/answer-c1.json"
eq "L6 driver rc" "$RC" 0
eq "L6 driver no call" "$(lines "$T/calls.stub")" 0
has "L6 driver summary" "$(cat "$T/calls.lane-alert" 2>/dev/null)" "clustering not configured"

# --- SEED1: the lookback.cluster seed, read from the REAL schema.sql loaded
# into node:sqlite (the SQL harness-sync applies, as stage-route-seed.bh-2536
# reads it). TEST-CHANGE (lead, R6 of alert-triage-runners.bh-2544): the seed
# copies rule.miner's claude rung 0 instead of adding a model literal, so the
# VALUES-only parser of bin/model-route-seed-lint.sh no longer sees it; the
# assertions are the same: a hub rung-0 row on claude, with a model.
S=$(node -e '
const { DatabaseSync } = require("node:sqlite");
const db = new DatabaseSync(":memory:");
db.exec(require("fs").readFileSync(process.argv[1], "utf8"));
for (const r of db.prepare("SELECT role, position, model, runner FROM model_routes WHERE project IS NULL AND role = ?").all("lookback.cluster"))
  console.log([r.role, r.position, r.model, r.runner].join("\t"));
' "$DIR/worker/jobs/schema.sql" 2>&1)
has "SEED1 lookback.cluster rung 0 on claude" "$S" "$(printf 'lookback.cluster\t0\t')"
eq "SEED1 runner" "$(printf '%s\n' "$S" | awk -F'\t' '$1=="lookback.cluster"{print $4}')" claude
eq "SEED1 model is set" "$(printf '%s\n' "$S" | awk -F'\t' '$1=="lookback.cluster" && $3!=""{print "yes"}')" yes

# --- Z1: the ticket's own literal ratchet
eq "Z1 no claude- literal in the lib" "$(grep -c 'claude-' "$LIBF")" 0

echo "lookback-cluster.bh-1795-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
