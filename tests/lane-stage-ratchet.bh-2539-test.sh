#!/bin/bash
# tests/lane-stage-ratchet.bh-2539-test.sh — BH-2539. The lane-stage ratchet
# (tests/lib/lane-stage-check.py) also reads catalog/llm-sites.json: for every
# `kind: agent-call` site, the stages its script passes to bin/agent-call.sh
# must equal the site's declared `stage`, and a literal declared `project`
# must equal the literal project argument.
#
# WHY. cost-readout billed its fleet read-out as review/project-1, and
# runner-bench billed as triage, which the gate resolves to run-triage, so
# bench spend counted against run-triage's daily cap. Neither script is any
# lane's `script`, so the BH-2304 lanes pass never looked at them.
#
# WHAT IT SKIPS, said plainly: a site whose script has no call the scanner can
# resolve (rb-plan passes "$stage"; trap-eval reaches agent-call through a
# variable path it cannot see; since BH-2562 the canaries lane-probe and
# claude-auth-check do the same, calling it through "$AC"). S4 pins that exact
# set, so a new skip is loud. oauth-refresh names agent-call.sh literally, so
# it is checked, not skipped.
#
#   bash tests/lane-stage-ratchet.bh-2539-test.sh          exit 0 = pass
# As root next to a live harness: HARNESS_TEST_SANDBOX=1 bash tests/…
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
CHECKER="$(dirname "$0")/lib/lane-stage-check.py"
[ -r "$CHECKER" ] || { echo "FAIL: missing checker $CHECKER"; exit 1; }
check() { python3 "$CHECKER" "$@"; }

# ── S1-S4: the real repo ─────────────────────────────────────────────────────
OUT=$(check "$DIR" "$DIR/catalog/lanes.d"); RC=$?
[ "$RC" = 0 ] && ok || bad "S1: the real repo fails the ratchet:
$(printf '%s\n' "$OUT" | grep '^FAIL')"
# BH-2550: cost-readout makes no model call, so it is no longer a site at all.
# A here-string, not a pipe: under pipefail `! printf | grep -q` passes when
# grep -q exits early on a match and printf takes SIGPIPE (BH-1818).
! grep -q 'SITE cost-readout' <<<"$OUT" \
  && ! jq -e '.sites[] | select(.id == "cost-readout")' "$DIR/catalog/llm-sites.json" >/dev/null && ok \
  || bad "S2: cost-readout is still an llm site after BH-2550: $(printf '%s\n' "$OUT" | grep 'cost-readout')"
grep -qx 'SITE runner-bench stage=bench called=bench project=bench called_project=bench' <<<"$OUT" && ok \
  || bad "S3: runner-bench does not bill bench/bench: $(printf '%s\n' "$OUT" | grep 'runner-bench')"
SKIPS=$(printf '%s\n' "$OUT" | awk '/^SKIP SITE /{print $3}' | sort | tr '\n' ' ')
[ "$SKIPS" = "claude-auth-check lane-probe rb-plan trap-eval " ] && ok || bad "S4: skipped sites are [$SKIPS], expected exactly [claude-auth-check lane-probe rb-plan trap-eval]"
N=$(printf '%s\n' "$OUT" | grep -c '^SITE ')
[ "$N" -ge 20 ] && ok || bad "S4: only $N sites were checked — the sites pass is finding nothing"

# ── fixtures ─────────────────────────────────────────────────────────────────
mksite() { # mksite <name> <stage> <project> — a root with one agent-call site
  mkdir -p "$T/$1/catalog/lanes.d" "$T/$1/bin"
  jq -n --arg id "$1" --arg st "$2" --arg pj "$3" \
    '{version:1, sites:[{id:$id, script:"bin/\($id).sh", kind:"agent-call", stage:$st, project:$pj}]}' \
    > "$T/$1/catalog/llm-sites.json"
}

# S5: declared readout, the script calls review — the cost-readout bug.
mksite s5 readout fleet
printf '#!/bin/bash\n"$HARNESS/bin/agent-call.sh" review fleet "$M" 1200 out x\n' > "$T/s5/bin/s5.sh"
OUT=$(check "$T/s5" "$T/s5/catalog/lanes.d"); RC=$?
[ "$RC" != 0 ] && grep -q 'FAIL: site s5 declares stage \[readout\] but bin/s5.sh calls agent-call.sh with \[review\]' <<<"$OUT" && ok \
  || bad "S5: a site declaring readout and calling review passed (rc=$RC): $OUT"

# S6: declared project fleet, the script bills project-1.
mksite s6 readout fleet
printf '#!/bin/bash\n"$HARNESS/bin/agent-call.sh" readout project-1 "$M" 1200 out x\n' > "$T/s6/bin/s6.sh"
OUT=$(check "$T/s6" "$T/s6/catalog/lanes.d"); RC=$?
[ "$RC" != 0 ] && grep -q 'FAIL: site s6 declares project fleet but bin/s6.sh calls agent-call.sh with project \[project-1\]' <<<"$OUT" && ok \
  || bad "S6: a site declaring project fleet and billing project-1 passed (rc=$RC): $OUT"

# S7: prose, comments, heredocs and tests are not calls; the real one is.
mksite s7 bench bench
cat > "$T/s7/bin/s7.sh" <<'EOF'
#!/bin/bash
# "$H/bin/agent-call.sh" triage bench in a comment
echo "bin/agent-call.sh triage refused" >&2
[ -x "$H/bin/agent-call.sh" ] || exit 0
cat <<TXT
  "$H/bin/agent-call.sh" triage bench m 1 o x
TXT
RUNNER_BENCH=x "$H/bin/agent-call.sh" bench bench m 60 o x
EOF
OUT=$(check "$T/s7" "$T/s7/catalog/lanes.d"); RC=$?
[ "$RC" = 0 ] && grep -qx 'SITE s7 stage=bench called=bench project=bench called_project=bench' <<<"$OUT" && ok \
  || bad "S7: prose/comment/heredoc/test mentions were read as calls (rc=$RC): $OUT"

# S8: a site whose project is a variable is not compared, whatever it passes.
mksite s8 review '$PROJECT'
printf '#!/bin/bash\nP=someone\n"$H/bin/agent-call.sh" review "$P" m 60 o x\n' > "$T/s8/bin/s8.sh"
OUT=$(check "$T/s8" "$T/s8/catalog/lanes.d"); RC=$?
[ "$RC" = 0 ] && grep -qx 'SITE s8 stage=review called=review project=$PROJECT called_project=someone' <<<"$OUT" && ok \
  || bad "S8: a \$PROJECT site had its project compared (rc=$RC): $OUT"

# S9: the real mutation — runner-bench's catalog row set back to triage.
mkdir -p "$T/s9/catalog"
jq '(.sites[] | select(.id=="runner-bench") | .stage) = "triage"' "$DIR/catalog/llm-sites.json" > "$T/s9/catalog/llm-sites.json"
cp -r "$DIR/bin" "$T/s9/"
OUT=$(check "$T/s9" "$DIR/catalog/lanes.d"); RC=$?
[ "$RC" != 0 ] && grep -q 'FAIL: site runner-bench declares stage \[triage\]' <<<"$OUT" && ok \
  || bad "S9: runner-bench's row reverted to triage and the ratchet stayed green (rc=$RC)"

echo "lane-stage-ratchet-sites: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
