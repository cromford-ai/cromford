#!/bin/bash
# tests/lane-stage-ratchet.bh-2304-test.sh — BH-2304. A lane's REGISTERED cost
# stages (catalog/lanes.d/<id>.json `stats.cost_stage`, a string or an array)
# must EQUAL the stages its own script passes to bin/agent-call.sh.
#
# WHY. bin/lib/llm-gate.sh resolves which lane a model call belongs to from
# (stage, project) against `stats.cost_stage`, and that lane's knobs
# (LLM_LANE_ENABLED, LLM_USD_CAP_DAY) are what gate the call. postmerge-qa
# registered `fix` and calls `prodqa`; run-product registered `plan` and calls
# map/signals/ideate/synth. So neither lane's daily cap ever applied to its own
# calls — and both lanes' knobs landed on run-build's `fix` and `plan` stages
# instead, where setting run-product off would have refused every build plan in
# the fleet. Nothing checked the two agreed; this does.
#
# WHAT COUNTS AS A CALL. After `#` comments are stripped (quote-aware) and
# heredoc bodies skipped, a call is a `…/agent-call.sh` word written through a
# variable (`"$H/bin/agent-call.sh"`, `$SELF/agent-call.sh`) or a `"$VAR"`
# whose assignment in the same script ends in `agent-call.sh`, followed by the
# stage argument. The stage is a literal `[a-z][a-z0-9-]*`, or `$NAME` /
# `"${NAME}"` resolved from exactly one `NAME=<literal>` assignment in the same
# script. An unresolvable stage is a FAIL naming file:line — never skipped.
# Prose (`echo "bin/agent-call.sh refused"`) has no `$` before the path and is
# not a call; `[ -x "$SELF/agent-call.sh" ]` has no stage argument and is not a
# call.
#
# WHAT IT SKIPS, said plainly: a lane with ZERO direct call sites in its own
# `script` (fly-pool, preplan-tick, merge-conductor, run-triage reach
# agent-call through run-build.sh or sourced libraries the scanner cannot
# attribute to one lane). It checks the lanes that call directly.
#
#   bash tests/lane-stage-ratchet.bh-2304-test.sh          exit 0 = pass
# As root next to a live harness: HARNESS_TEST_SANDBOX=1 bash tests/…
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ── the checker ──────────────────────────────────────────────────────────────
# tests/lib/lane-stage-check.py (BH-2539 moved it out of a heredoc here so
# tests/lane-stage-ratchet.bh-2539-test.sh drives the same code). One script
# for the repo AND the fixtures below, so the fixtures prove the
# code that guards the repo. Usage: lane-stage-check.py <root> <lanes.d dir>. Prints
#   LANE <id> registered=<a,b> called=<a,b> sites=<n>
# per lane with >=1 call site, a `FAIL: …` line per problem, and exits 1 when
# any FAIL was printed.
CHECKER="$(dirname "$0")/lib/lane-stage-check.py"
[ -r "$CHECKER" ] || { echo "FAIL: missing checker $CHECKER"; exit 1; }
check() { python3 "$CHECKER" "$@"; }

# ── R1 / R2: the real repo ───────────────────────────────────────────────────
OUT=$(check "$DIR" "$DIR/catalog/lanes.d"); RC=$?
[ "$RC" = 0 ] && ok || bad "R1: registered stages differ from call-site stages:
$(printf '%s\n' "$OUT" | grep '^FAIL')"
grep -qx 'LANE postmerge-qa registered=prodqa called=prodqa sites=1' <<<"$OUT" && ok \
  || bad "R1: postmerge-qa is not registered as exactly {prodqa}: $(printf '%s\n' "$OUT" | grep 'postmerge-qa')"
grep -qE '^LANE run-product registered=ideate,map,mockup,prd,signals,synth called=ideate,map,mockup,prd,signals,synth ' <<<"$OUT" && ok \
  || bad "R1: run-product is not registered as exactly {map,signals,ideate,synth,prd,mockup} (the last two through its declared helper bin/draft-proposal.sh, BH-2489): $(printf '%s\n' "$OUT" | grep 'run-product')"
N=$(printf '%s\n' "$OUT" | grep -c '^LANE ')
[ "$N" -ge 10 ] && ok || bad "R2: only $N lanes had a direct agent-call site — the scanner is finding nothing"

# ── fixtures ─────────────────────────────────────────────────────────────────
mkfix() { # mkfix <name> <cost_stage-json> — lane file + an empty script path
  mkdir -p "$T/$1/catalog/lanes.d" "$T/$1/bin"
  jq -n --arg id "$1" --argjson cs "$2" \
    '{id:$id, script:"bin/\($id).sh", stats:{cost_stage:$cs, cost_project_filter:null}}' \
    > "$T/$1/catalog/lanes.d/$1.json"
}

# R3: prose and comments are not calls; a real call on the same script is.
mkfix r3 '"real"'
cat > "$T/r3/bin/r3.sh" <<'EOF'
#!/bin/bash
# agent-call.sh writes a cost row; "$H/bin/agent-call.sh" bogus in a comment
echo "bin/agent-call.sh refused" >&2
[ -x "$H/bin/agent-call.sh" ] || exit 0
if [ -x "$H/bin/agent-call.sh" ]; then :; fi
cat <<TXT
  "$H/bin/agent-call.sh" heredoc p m 1 o x
TXT
"$H/bin/agent-call.sh" real p m 60 "$OUT" "$PROMPT"
EOF
OUT=$(check "$T/r3" "$T/r3/catalog/lanes.d"); RC=$?
[ "$RC" = 0 ] && grep -qx 'LANE r3 registered=real called=real sites=1' <<<"$OUT" && ok \
  || bad "R3: prose/comment/heredoc/test mentions were read as calls (rc=$RC): $OUT"

# R4: the call through a variable, the stage through a variable, a
# continuation line between them.
mkfix r4 '"eval"'
cat > "$T/r4/bin/r4.sh" <<'EOF'
#!/bin/bash
SELF=$(dirname "$0")
S="eval"
AGENT_CALL="${PROMPT_EVAL_AGENT_CALL:-$SELF/agent-call.sh}"
env A=1 \
  "$AGENT_CALL" "$S" p m 60 out prompt
EOF
OUT=$(check "$T/r4" "$T/r4/catalog/lanes.d"); RC=$?
[ "$RC" = 0 ] && grep -qx 'LANE r4 registered=eval called=eval sites=1' <<<"$OUT" && ok \
  || bad "R4: \"\$AGENT_CALL\" \"\$S\" did not resolve to {eval} (rc=$RC): $OUT"

# R5a: the ticket's own bug, in miniature — registered fix, calls prodqa.
mkfix r5 '"fix"'
cat > "$T/r5/bin/r5.sh" <<'EOF'
#!/bin/bash
AGENT_CALL_ROLE=postmerge.qa "$SELF/agent-call.sh" prodqa "$P" m 1500 out x
EOF
OUT=$(check "$T/r5" "$T/r5/catalog/lanes.d"); RC=$?
[ "$RC" != 0 ] && grep -q 'FAIL: lane r5 registers cost_stage \[fix\] but bin/r5.sh calls agent-call.sh with \[prodqa\]' <<<"$OUT" && ok \
  || bad "R5a: a lane registering fix and calling prodqa passed (rc=$RC): $OUT"
# R5b: an unresolvable stage is a FAIL naming file:line, never skipped.
mkfix r5b '"x"'
printf '#!/bin/bash\n"$H/bin/agent-call.sh" "$1" p m 60 o x\n' > "$T/r5b/bin/r5b.sh"
OUT=$(check "$T/r5b" "$T/r5b/catalog/lanes.d"); RC=$?
[ "$RC" != 0 ] && grep -q 'FAIL: bin/r5b.sh:2: agent-call stage argument "\$1" does not resolve' <<<"$OUT" && ok \
  || bad "R5b: an unresolvable \"\$1\" stage was not a FAIL naming the line (rc=$RC): $OUT"
# R5c: an array registering MORE than the script calls is a mismatch too.
mkfix r5c '["a","b"]'
printf '#!/bin/bash\n"$H/bin/agent-call.sh" a p m 60 o x\n' > "$T/r5c/bin/r5c.sh"
OUT=$(check "$T/r5c" "$T/r5c/catalog/lanes.d"); RC=$?
[ "$RC" != 0 ] && ok || bad "R5c: registered [a,b] vs called [a] passed: $OUT"

# ── R6: the real mutation — postmerge-qa set back to `fix` ───────────────────
mkdir -p "$T/r6/catalog"
cp -r "$DIR/catalog/lanes.d" "$T/r6/catalog/"
jq '.stats.cost_stage = "fix"' "$DIR/catalog/lanes.d/postmerge-qa.json" > "$T/r6/catalog/lanes.d/postmerge-qa.json"
OUT=$(check "$DIR" "$T/r6/catalog/lanes.d"); RC=$?
[ "$RC" != 0 ] && grep -q 'FAIL: lane postmerge-qa registers cost_stage \[fix\]' <<<"$OUT" && ok \
  || bad "R6: postmerge-qa reverted to cost_stage=fix and the ratchet stayed green (rc=$RC)"

echo "lane-stage-ratchet: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
