#!/bin/bash
# tests/codegraph-injection-test.sh — the orientation line reaches every
# code-touching stage's prompt, and the soft sentence that produced the defect
# is gone.
#
# This extracts run-build.sh's REAL CC() dispatcher and its real ORIENTATION
# block and executes them, rather than retyping either — a test of a copy proves
# the copy, which is this repo's most-repeated lesson.
#
# The soft sentence being replaced was: "If the repo has a .codegraph/ index,
# use codegraph explore...". That is a probabilistic instruction that asks the
# model to test a PATH, and the path is exactly what lies in a worktree. The
# line injected here is a deterministic FACT, capability-tested by the harness
# before the model sees it.
# Run from anywhere: tests/codegraph-injection-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
RB="$RB_ALL"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------- extract the REAL CC dispatcher and run it ------------------------
python3 - "$RB" "$T/cc.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
start = src.index("CC() { # CC <stage>")
end = src.index("\n}\n", start) + len("\n}\n")
open(sys.argv[2], "w").write(src[start:end])
PY
[ -s "$T/cc.sh" ] && ok || bad "could not extract CC() from run-build.sh"

# a stub agent-call that records the prompt each stage was actually handed
mkdir -p "$T/h/bin" "$T/out"
cat > "$T/h/bin/agent-call.sh" <<'STUB'
#!/bin/bash
printf '%s' "$6" > "$OUTDIR/$1.prompt"
STUB
chmod +x "$T/h/bin/agent-call.sh"

call() {  # call <stage> — returns the prompt that stage's runner received
  HARNESS="$T/h" PROJECT=demo-os CG_ORIENT="$2" OUTDIR="$T/out" bash -c '
    set -uo pipefail
    HARNESS="'"$T"'/h"; PROJECT=demo-os
    . "'"$T"'/cc.sh"
    CC "$1" model 60 /dev/null "STAGE BODY TEXT"' _ "$1"
  cat "$T/out/$1.prompt"
}

LINE='CODEGRAPH AVAILABLE (index @ main deadbee, 42 symbols, indexed 2026-08-25T00:00:00Z; query via: codegraph explore -p /root/repos/demo-os "<symbols or question>")'

# ---------- 1. every code-touching stage gets the line, FIRST ---------------
for STAGE in plan execute review fix; do
  P=$(call "$STAGE" "$LINE")
  grep -q 'CODEGRAPH AVAILABLE' <<<"$P" \
    && ok || bad "$STAGE: the orientation line must be in the prompt"
  [ "$(head -1 <<<"$P")" = "$LINE" ] \
    && ok || bad "$STAGE: the line must come FIRST, before the stage body"
  grep -q 'STAGE BODY TEXT' <<<"$P" \
    && ok || bad "$STAGE: injecting the line must not displace the stage's own prompt"
done

# ---------- 2. stages that do not read code are left alone -----------------
# QA drives a browser against a deployment; handing it a graph line is noise,
# and noise in a prompt is the thing this whole wave is removing.
P=$(call qa "$LINE")
! grep -q 'CODEGRAPH' <<<"$P" \
  && ok || bad "qa must not receive the graph line"

# ---------- 3. a NOT AVAILABLE line rides too -------------------------------
# Silence would be indistinguishable from "nobody checked", and a session that
# cannot tell those apart goes probing — which is the defect.
P=$(call plan 'CODEGRAPH NOT AVAILABLE (no main clone at /root/repos/demo-os)')
grep -q 'CODEGRAPH NOT AVAILABLE' <<<"$P" \
  && ok || bad "a NOT AVAILABLE verdict must be injected too, not omitted"

# ---------- 4. the ensure call is wired at build start ----------------------
grep -q 'CG_ORIENT=$("$HARNESS/bin/codegraph-ensure.sh"' "$RB" \
  && ok || bad "run-build.sh must call codegraph-ensure.sh"
# and it must degrade rather than abort: a graph problem may not fail a build
grep -q 'CG_ORIENT="CODEGRAPH NOT AVAILABLE (codegraph-ensure.sh failed)"' "$RB" \
  && ok || bad "a failing ensure must degrade to NOT AVAILABLE, never block the build"

# ---------- 5. the probabilistic sentence is GONE ---------------------------
# It is the direct cause: it told the model to test for a directory, and the
# directory is present-and-empty in every worktree.
# TEST-CHANGE (BH-7970): the plan and execute prompt texts moved to prompts/stages/*.md, so these three greps read the pipeline AND the stage files.
! grep -q "If the repo has a .codegraph/ index, use 'codegraph explore'" "$RB" "$DIR"/prompts/stages/*.md \
  && ok || bad "the old soft 'if the repo has a .codegraph/ index' sentence must be gone"
! grep -q 'if this repo is indexed (a .codegraph/ directory exists' "$RB" "$DIR"/prompts/stages/*.md \
  && ok || bad "the old 'if a .codegraph/ directory exists' plan sentence must be gone"
# and the replacement must warn the model off probing for the directory
grep -q 'do not probe for a .codegraph/ directory' "$RB" "$DIR"/prompts/stages/*.md \
  && ok || bad "the prompts must tell the model NOT to probe for the directory"

# ---------- 6. the after-merge refresh pulls before indexing ---------------
# codegraph indexes the main clone's WORKING TREE. Refreshing after a merge
# without pulling would faithfully re-index the tree that lacks the merge and
# then report itself fresh — a stale index wearing a current timestamp.
MS="$DIR/bin/merge-sweep.sh"
grep -q 'codegraph-ensure.sh' "$MS" \
  && ok || bad "merge-sweep must refresh the graph after a merge"
python3 - "$MS" <<'PY' && ok || bad "the post-merge refresh must git pull BEFORE it re-indexes"
import sys
s = open(sys.argv[1]).read()
b = s.index("# --- CODEGRAPH REFRESH (begin) ---")
e = s.index("# --- CODEGRAPH REFRESH (end) ---")
blk = s[b:e]
sys.exit(0 if ("git pull" in blk and blk.index("git pull") < blk.index("codegraph-ensure.sh")) else 1)
PY

# ---------- 7. CI actually RUNS the capability suite ------------------------
# The capability suite used to skip in CI, which is a green that proves nothing
# — the same shape as the path-probe it exists to catch. These assertions pin
# the workflow itself, because "we added a CI step" is a claim like any other.
WF="$DIR/.github/workflows/harness-ci.yml"
grep -qE 'npm install -g @colbymchenry/codegraph@[0-9]+\.[0-9]+\.[0-9]+' "$WF" \
  && ok || bad "CI must install codegraph with a PINNED version (an unpinned install lets CI's truth drift with someone else's releases)"
grep -q 'CODEGRAPH_REQUIRED=1' "$WF" \
  && ok || bad "CI must set CODEGRAPH_REQUIRED so the capability suite cannot take the skip path"
# a failed install must fail the JOB — 'the CLI vanished' reading as 'tests
# passed' is the same hole one layer up
python3 - "$WF" <<'PY' && ok || bad "the install step must assert the CLI is on PATH afterwards, under set -e"
import sys
s = open(sys.argv[1]).read()
b = s.index("install codegraph (pinned)")
blk = s[b:s.index("- name: tests/ suite", b)]
sys.exit(0 if ("set -euo pipefail" in blk and "command -v codegraph" in blk) else 1)
PY
# and the suite itself must honour the flag rather than the workflow merely setting it
grep -q 'CODEGRAPH_REQUIRED' "$DIR/tests/codegraph-ensure-test.sh" \
  && ok || bad "the capability suite must honour CODEGRAPH_REQUIRED"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
