#!/bin/bash
# tests/rb-prepr-gate.bh-1706-test.sh — BH-1706: the pre-PR gate in
# bin/run-build.sh. Before a build opens its PR it runs the two deterministic
# gates cromford CI runs (bin/checks-run.sh --tree . and
# bin/test-determinism-lint.sh) on the build worktree. A finding in a file the
# build changed buys ONE bounded fix turn through the real CC() -> agent-call.sh
# path, then both gates run again; still red opens the PR with a
# "Pre-PR gate: unresolved" section and " | prepr=red" in RESULT. Separately, a
# child slice's PR body never carries "Closes #<parent>".
#
# Every fixture worktree is a scratch git repo holding copies of the REAL gates
# (bin/checks-run.sh + checks/, bin/test-determinism-lint.sh +
# catalog/determinism-lint.conf). The agent is a stub $HARNESS/bin/agent-call.sh
# that logs its call and applies the case's scripted fix. The violating lines
# are assembled at runtime so this file stays clean under both gates.
# Run from anywhere: tests/rb-prepr-gate.bh-1706-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/prepr-gate.sh"
H="$T/h"
mkdir -p "$H/bin/lib"
[ -f "$LIB" ] && cp "$LIB" "$H/bin/lib/"
cp "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
# The registry the knob resolves through, composed from this checkout's lanes.d.
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" > "$T/lanes.json" 2>"$T/lanes.err" \
  && [ -s "$T/lanes.json" ] && ok || bad "could not compose the lanes registry: $(head -3 "$T/lanes.err")"

# The real CC() dispatcher, lifted from the driver by its first line.
awk '/^CC\(\) \{ # CC <stage>/{f=1} f{print} f&&/^\}/{exit}' "$RB_ALL" > "$T/cc.sh"
grep -q 'agent-call.sh' "$T/cc.sh" && ok || bad "could not lift CC() from bin/run-build.sh"

# The stub agent: one log line per call, the prompt beside it, then the case's
# scripted fix (run in the cwd CC was called from — the build worktree).
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s %s %s\n' "$1" "$3" "$4" >> "$CALLLOG"
printf '%s\n' "$6" >> "$CALLLOG.prompt"
echo "stub ran" > "$5"
[ -n "${STUB_FIX:-}" ] && [ -f "$STUB_FIX" ] && bash "$STUB_FIX"
exit 0
SH
chmod +x "$H/bin/agent-call.sh"

# Violating lines, assembled so this file never contains them.
RAW_RM=$(printf '%s -rf "$H/x"' rm)
DATE_NOW=$(printf 'const a = %s.now();' Date)
WARN_DATE=$(printf 'd=$(%s -u +%%Y-%%m-%%d)' date)
SCRATCH_SRC='. "$(dirname "$0")/lib/scratch.sh" || exit 1'

# mkwt <name> <base-setup-fn> <build-setup-fn> — a fixture worktree on branch
# ticket/x over main; prints its path.
mkwt() {
  local w="$T/wt-$1"; shift
  mkdir -p "$w/bin" "$w/catalog" "$w/tests"
  cp -r "$DIR/checks" "$w/"
  cp "$DIR/bin/checks-run.sh" "$DIR/bin/test-determinism-lint.sh" "$w/bin/"
  cp "$DIR/catalog/determinism-lint.conf" "$w/catalog/"
  ( cd "$w" || exit 1
    git init -q -b main && git config user.email t@example.com && git config user.name t
    git config commit.gpgsign false
    "$1"
    git add -A && git commit -qm base
    git checkout -qb ticket/x
    "$2"
    git add -A && git commit -qm build ) >/dev/null 2>&1
  printf '%s' "$w"
}
none()      { :; }
add_rawrm() { printf '#!/bin/bash\nH=/nonexistent\n%s\n' "$RAW_RM" > tests/x-test.sh; }
add_datenow() { printf '%s\n' "$DATE_NOW" > tests/z.test.js; }
add_clean() { printf '#!/bin/bash\n%s\n%s\necho "$d"\n' "$SCRATCH_SRC" "$WARN_DATE" > tests/ok-test.sh; }
crash_checks() { printf '#!/bin/bash\necho boom\nexit 2\n' > bin/checks-run.sh; chmod +x bin/checks-run.sh; }

# Scripted fixes the stub agent applies.
cat > "$T/fix-rawrm.sh" <<SH
printf '#!/bin/bash\n%s\nscratch_rm "\$T/x"\n' '$SCRATCH_SRC' > tests/x-test.sh
git add -A && git commit -qm fix
SH
cat > "$T/fix-datenow.sh" <<'SH'
printf 'const a = 1726000000000;\n' > tests/z.test.js
git add -A && git commit -qm fix
SH
cat > "$T/fix-dirty.sh" <<SH
printf '#!/bin/bash\n%s\nscratch_rm "\$T/x"\n' '$SCRATCH_SRC' > tests/x-test.sh
SH
cat > "$T/fix-rules.sh" <<'SH'
printf '#!/bin/bash\nexit 0\n' > checks/tests-scratch-only/check.sh
git add -A && git commit -qm "silence the check"
SH

# drive <wt> <case> [env...] — prepr_gate on the fixture with the real CC(); the
# resulting globals land in $T/<case>/vars.sh.
drive() {
  local w="$1" c="$2"; shift 2
  mkdir -p "$T/$c"
  rm -f "$T/$c/calls" "$T/$c/calls.prompt"
  ( cd "$w" || exit 1
    env HARNESS="$H" BUILD="$T/$c" PROJECT=cromford KEY=BH-1 BRANCH=ticket/x FIX_MODEL=fix-model-x \
        LANE_REGISTRY="$T/lanes.json" CALLLOG="$T/$c/calls" STUB_FIX= "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      CG_ORIENT=""
      . "$0"
      . "$HARNESS/bin/lib/prepr-gate.sh" || exit 9
      prepr_gate . main "$BUILD"
      declare -p PREPR_STATE PREPR_NOTE PREPR_SECTION > "$BUILD/vars.sh"
    ' "$T/cc.sh" >"$T/$c/out.txt" 2>&1 )
}
calls() { [ -f "$T/$1/calls" ] && wc -l < "$T/$1/calls" | tr -d ' ' || echo 0; }
vars()  { PREPR_STATE="<unset>"; PREPR_NOTE="<unset>"; PREPR_SECTION="<unset>"
          [ -f "$T/$1/vars.sh" ] && . <(sed 's/^declare -- /declare -g /' "$T/$1/vars.sh"); }

# ── C1: a raw rm-rf in an added test -> one fix turn, fixed ─────────────────
W=$(mkwt c1 none add_rawrm)
drive "$W" c1 STUB_FIX="$T/fix-rawrm.sh"
vars c1
[ "$(calls c1)" = 1 ] && ok || bad "C1: expected exactly 1 agent call, got $(calls c1): $(cat "$T/c1/out.txt")"
st=""; md=""; to=""
[ -f "$T/c1/calls" ] && read -r st md to < "$T/c1/calls"
[ "$st $md $to" = "fix fix-model-x 4800" ] && ok || bad "C1: call was '$st $md $to', want 'fix fix-model-x 4800'"
grep -q '^CHECK-HIT tests-scratch-only tests/x-test.sh:3 ' "$T/c1/calls.prompt" 2>/dev/null && ok \
  || bad "C1: the brief does not carry the CHECK-HIT line verbatim"
[ "$PREPR_STATE" = fixed ] && ok || bad "C1: state '$PREPR_STATE', want fixed"
[ -z "$PREPR_NOTE" ] && [ -z "$PREPR_SECTION" ] && ok || bad "C1: a fixed gate left a note/section: '$PREPR_NOTE'"
grep -q 'PREPR state=fixed .*fix_calls=1' "$T/c1/pipeline.log" 2>/dev/null && ok || bad "C1: no PREPR pipeline.log line"

# ── C2: a Date.now() read in an added test -> one fix turn, fixed ───────────
W=$(mkwt c2 none add_datenow)
drive "$W" c2 STUB_FIX="$T/fix-datenow.sh"
vars c2
[ "$(calls c2)" = 1 ] && ok || bad "C2: expected 1 call, got $(calls c2)"
grep -q '^tests/z.test.js:1: clock-now-js:' "$T/c2/calls.prompt" 2>/dev/null && ok \
  || bad "C2: the brief does not carry the determinism finding verbatim"
[ "$PREPR_STATE" = fixed ] && ok || bad "C2: state '$PREPR_STATE', want fixed"

# ── C3: the fix turn fixes nothing -> red, section, RESULT field ────────────
W=$(mkwt c3 none add_rawrm)
drive "$W" c3
vars c3
[ "$(calls c3)" = 1 ] && ok || bad "C3: expected exactly 1 call (never a second turn), got $(calls c3)"
[ "$PREPR_STATE" = red ] && ok || bad "C3: state '$PREPR_STATE', want red"
[ "$PREPR_NOTE" = " | prepr=red" ] && ok || bad "C3: note '$PREPR_NOTE'"
grep -q '^## Pre-PR gate: unresolved' <<<"$PREPR_SECTION" && ok || bad "C3: no unresolved heading in the section"
[ "$(grep -c 'CHECK-HIT tests-scratch-only tests/x-test.sh:3' <<<"$PREPR_SECTION")" = 2 ] && ok \
  || bad "C3: the section does not list both remaining findings: $PREPR_SECTION"
grep -q '2 finding' <<<"$PREPR_SECTION" && ok || bad "C3: the section does not state the total"
# The evidence block, lifted verbatim, renders the section into the PR body.
awk '/^# >>> evidence block/{f=1;next} /^# <<< evidence block/{exit} f' "$RB_ALL" > "$T/block.sh"
cat > "$T/bin-fleet-conf.sh" <<'SH'
#!/bin/bash
[ "${2:-}" = board_prefix ] && echo "-"
SH
mkdir -p "$T/fh/bin/lib"; cp "$T/bin-fleet-conf.sh" "$T/fh/bin/fleet-conf.sh"; chmod +x "$T/fh/bin/fleet-conf.sh"
# BH-7919: the Closes line (bin/lib/rb/pr.sh) now asks bin/lib/tracker.sh trk_gh_issue_number.
scratch_install_closure bin/lib/tracker.sh "$T/fh" >/dev/null || exit 1
render_body() { # render_body <build> <out> <why> [with-lib]
  ( cd "$W" || exit 1
    env HARNESS="$T/fh" BUILD="$1" KEY=BH-1706 WHY="$3" WITHLIB="${4:-}" LIBF="$H/bin/lib/prepr-gate.sh" VARS="$T/c3/vars.sh" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      PROJECT=cromford; SLUG=o/r; BASE=main; TIER=2; QA_NOTE=""; MIG_NOTE=""; ADDED_SQL=""; E2E_VERDICT=pass
      CHANGED="a.txt"; TAMPER_RC=0; REPRO_RC=0; INTENT_RC=0
      WHAT_LIST="- did a thing"; WHY_EXCERPT="$WHY"; VERIFY_LINE="v"; SPEC_LINE="s"
      PLAN_MODEL=pm; EXECUTE_MODEL=em; REVIEW_MODEL=rm; MIG_SECTION=""; COST_LINE="c"; MERGE_NOTE=""
      CTX_SIG=sig; CTX_COMMIT=abc; CTX_SYNC=yes; CTX_FRESH=yes
      job_evidence_put() { return 0; }
      [ -n "$WITHLIB" ] && { . "$LIBF"; . "$VARS"; }
      . "$0"
      printf "%s" "$(PR_BODY_FOR "EVIDENCE")" > "$1"
    ' "$T/block.sh" "$2" 2>"$2.err" )
}
mkdir -p "$T/pb"
render_body "$T/pb" "$T/body-c3.txt" "because" lib
grep -q '^## Pre-PR gate: unresolved' "$T/body-c3.txt" 2>/dev/null && grep -q 'tests/x-test.sh:3' "$T/body-c3.txt" && ok \
  || bad "C3: the rendered PR body has no unresolved section: $(head -c 300 "$T/body-c3.txt" 2>/dev/null) $(cat "$T/body-c3.txt.err" 2>/dev/null)"
# The final PR_CREATED RESULT line, lifted from the driver, carries the field.
RLINE=$(grep -E '^[[:space:]]*RESULT "PR_CREATED \$PR_URL\$QA_NOTE' "$RB_ALL")
[ -n "$RLINE" ] && ok || bad "C3: could not find the PR_CREATED RESULT line"
ROUT=$( RESULT() { printf '%s\n' "$*"; }
        PR_URL=https://github.com/o/r/pull/9; QA_NOTE=""; MIG_NOTE=""; REBASE_NOTE=""; STACK_NOTE=""
        . "$T/c3/vars.sh"; eval "$RLINE" )
[ "$ROUT" = "PR_CREATED https://github.com/o/r/pull/9 | prepr=red" ] && ok || bad "C3: RESULT was '$ROUT'"
# All three PR_CREATED lines carry the note.
[ "$(grep -cE 'RESULT "PR_CREATED \$PR_URL.*\$\{PREPR_NOTE:-\}' "$RB_ALL")" = 3 ] && ok \
  || bad "C3: not every PR_CREATED RESULT line appends \${PREPR_NOTE:-}"
# Without the lib (the three suites that source the block alone) the body has no section.
render_body "$T/pb" "$T/body-nolib.txt" "because"
[ -s "$T/body-nolib.txt" ] && ! grep -q 'Pre-PR gate' "$T/body-nolib.txt" && ok \
  || bad "C3: a body rendered without the lib is empty or has the section: $(cat "$T/body-nolib.txt.err" 2>/dev/null)"

# ── C4: clean (a warn-level lint line does not count) -> no call ────────────
W=$(mkwt c4 none add_clean)
drive "$W" c4
vars c4
[ ! -f "$T/c4/calls" ] && ok || bad "C4: a clean diff bought an agent call"
[ "$PREPR_STATE" = clean ] && ok || bad "C4: state '$PREPR_STATE', want clean: $(cat "$T/c4/out.txt")"
grep -q 'determinism warnings' "$T/c4/determinism.txt" 2>/dev/null && ok || bad "C4: the fixture did not produce a warn-level line"

# ── C5: RB_PREPR_FIX_TURNS=0 -> detection only ──────────────────────────────
W=$(mkwt c5 none add_rawrm)
drive "$W" c5 RB_PREPR_FIX_TURNS=0 STUB_FIX="$T/fix-rawrm.sh"
vars c5
[ ! -f "$T/c5/calls" ] && ok || bad "C5: turns=0 still called the agent"
[ "$PREPR_STATE" = off ] && ok || bad "C5: state '$PREPR_STATE', want off"
[ -z "$PREPR_NOTE" ] && [ -z "$PREPR_SECTION" ] && ok || bad "C5: turns=0 changed the PR body/RESULT"
grep -q 'tests/x-test.sh:3' "$T/c5/prepr-findings.txt" 2>/dev/null && ok || bad "C5: findings not recorded"

# ── C6: RB_PREPR_FIX_TURNS=5 with a surviving finding -> still ONE call ─────
W=$(mkwt c6 none add_rawrm)
drive "$W" c6 RB_PREPR_FIX_TURNS=5
vars c6
[ "$(calls c6)" = 1 ] && ok || bad "C6: turns=5 made $(calls c6) calls, want 1"
[ "$PREPR_STATE" = red ] && ok || bad "C6: state '$PREPR_STATE', want red"

# ── C7: a finding already on main in a file this build did not touch ────────
W=$(mkwt c7 add_rawrm add_clean)
drive "$W" c7
vars c7
[ ! -f "$T/c7/calls" ] && ok || bad "C7: a pre-existing finding bought a fix turn"
[ "$PREPR_STATE" = clean ] && ok || bad "C7: state '$PREPR_STATE', want clean"
grep -q 'tests/x-test.sh:3' "$T/c7/prepr-preexisting.txt" 2>/dev/null && ok || bad "C7: preexisting finding not recorded"
grep -q 'preexisting=2' "$T/c7/pipeline.log" 2>/dev/null && ok || bad "C7: the log line does not count the preexisting findings"

# ── C8: a gate that crashes is could-not-run, never clean ───────────────────
W=$(mkwt c8 crash_checks add_rawrm)
drive "$W" c8
vars c8
[ "$PREPR_STATE" = could-not-run ] && ok || bad "C8: state '$PREPR_STATE', want could-not-run"
[ ! -f "$T/c8/calls" ] && ok || bad "C8: a crashed gate bought an agent call"

# ── C11: a repo that ships neither gate is skipped ──────────────────────────
W=$(mkwt c11 none add_rawrm); ( cd "$W" && git rm -q bin/checks-run.sh && git commit -qm drop ) >/dev/null 2>&1
drive "$W" c11
vars c11
[ "$PREPR_STATE" = skipped ] && [ ! -f "$T/c11/calls" ] && ok || bad "C11: state '$PREPR_STATE', want skipped with no call"

# ── C12: a fix left uncommitted, or one that edits the gate's own rules ─────
W=$(mkwt c12 none add_rawrm)
drive "$W" c12 STUB_FIX="$T/fix-dirty.sh"
vars c12
[ "$PREPR_STATE" = red ] && grep -q 'uncommitted' <<<"$PREPR_SECTION" && ok \
  || bad "C12: a dirty-tree fix was '$PREPR_STATE', want red with the reason"
W=$(mkwt c13 none add_rawrm)
drive "$W" c13 STUB_FIX="$T/fix-rules.sh"
vars c13
[ "$PREPR_STATE" = red ] && grep -q "gate's own rules" <<<"$PREPR_SECTION" && ok \
  || bad "C13: a fix that silenced the check was '$PREPR_STATE', want red with the reason"

# ── C9: the production block, lifted from the driver, with the real CC() ────
awk '/^# >>> prepr gate/{f=1;next} /^# <<< prepr gate/{exit} f' "$RB_ALL" > "$T/prepr-block.sh"
grep -q 'prepr_gate' "$T/prepr-block.sh" && ok || bad "C9: no '# >>> prepr gate' block calling prepr_gate in bin/run-build.sh"
awk '/^# <<< spec artifact/{s=NR} /^# >>> prepr gate/{p=NR} /THE TREE SURVIVES THIS MACHINE/{if(!t)t=NR}
     END{exit !(s && p && t && s<p && p<t)}' "$RB_ALL" && ok \
  || bad "C9: the prepr gate block is not between the spec artifact and THE TREE SURVIVES push"
W=$(mkwt c9 none add_rawrm)
mkdir -p "$T/c9"; rm -f "$T/c9/calls"
( cd "$W" || exit 1
  env HARNESS="$H" BUILD="$T/c9" PROJECT=cromford KEY=BH-1 BRANCH=ticket/x FIX_MODEL=fix-model-x BASE=main \
      LANE_REGISTRY="$T/lanes.json" CALLLOG="$T/c9/calls" STUB_FIX="$T/fix-rawrm.sh" \
  bash -c '
    set -uo pipefail
    STAMP() { echo TS; }
    CG_ORIENT=""
    . "$0"; . "$1"
    declare -p PREPR_STATE PREPR_NOTE PREPR_SECTION > "$BUILD/vars.sh"
  ' "$T/cc.sh" "$T/prepr-block.sh" >"$T/c9/out.txt" 2>&1 )
vars c9
[ "$(calls c9)" = 1 ] && ok || bad "C9: the driver block made $(calls c9) agent calls, want 1: $(cat "$T/c9/out.txt")"
[ "$PREPR_STATE" = fixed ] && ok || bad "C9: the driver block ended '$PREPR_STATE', want fixed"
# Fails open: no lib on the box means one log line and today's behaviour.
mkdir -p "$T/c9b/h/bin"; rm -f "$T/c9b/calls"
( cd "$W" || exit 1
  env HARNESS="$T/c9b/h" BUILD="$T/c9b" PROJECT=cromford KEY=BH-1 BASE=main CALLLOG="$T/c9b/calls" \
  bash -c 'set -uo pipefail; STAMP() { echo TS; }; . "$0"; declare -p PREPR_NOTE PREPR_SECTION > "$BUILD/vars.sh"' \
  "$T/prepr-block.sh" >"$T/c9b/out.txt" 2>&1 )
PREPR_NOTE="<unset>"; PREPR_SECTION="<unset>"; [ -f "$T/c9b/vars.sh" ] && . "$T/c9b/vars.sh"
[ -z "$PREPR_NOTE" ] && [ -z "$PREPR_SECTION" ] && grep -q 'prepr' "$T/c9b/pipeline.log" 2>/dev/null && ok \
  || bad "C9: a box without the lib did not fail open with a log line: $(cat "$T/c9b/out.txt")"

# ── C10: no model literal and no numeric default for the knob ───────────────
if [ -f "$LIB" ]; then
  [ "$(grep -c 'claude-' "$LIB")" = 0 ] && ok || bad "C10: a model literal in $LIB"
  grep -q 'RB_PREPR_FIX_TURNS' "$LIB" && ok || bad "C10: the lib does not read RB_PREPR_FIX_TURNS"
  grep -qE 'RB_PREPR_FIX_TURNS:?[-=][0-9]' "$LIB" && bad "C10: a numeric default for RB_PREPR_FIX_TURNS in the lib" || ok
else
  bad "C10: $LIB does not exist"
fi

# ── K: the closing-keyword rewrite for child slices ─────────────────────────
kw() { # kw <build-dir> <input> — prints the filtered text
  env BUILD="$1" LIBF="$LIB" bash -c 'set -uo pipefail; . "$LIBF" || exit 9; printf "%s" "$0" | prepr_body_keywords' "$2"
}
mkdir -p "$T/k1" "$T/k2" "$T/k4"
jq -n '{title:"BH-1706.2: a slice", body:"The slice.\n\n---\nPart of #1657\nOrder: 2 of 3\n"}' > "$T/k1/ticket-meta.json"
jq -n '{title:"BH-1706: whole", body:"The whole thing.\nOrder: 1 of 1\n"}' > "$T/k2/ticket-meta.json"
IN_K1=$'Ticket BH-1706 — x\nCloses #1657\n## What\n- a'
OUT=$(kw "$T/k1" "$IN_K1")
grep -qx 'Part of #1657' <<<"$OUT" && ! grep -q 'Closes #1657' <<<"$OUT" && ok || bad "K1: child slice kept Closes: $OUT"
[ ! -f "$T/k1/calls" ] && ok || bad "K1: the rewrite called an agent"
OUT=$(kw "$T/k2" "$IN_K1")
[ "$OUT" = "$IN_K1" ] && ok || bad "K2: a single-slice body changed: $OUT"
IN_K3=$'Fixes: #1657\n- also resolves #1657.\n**closes #1657**\nCloses #16570\nCloses #1706\nPart of #1657\nthis closes the gap in #1657 design'
WANT_K3=$'Part of #1657\n- also Part of #1657.\n**Part of #1657**\nCloses #16570\nCloses #1706\nPart of #1657\nthis closes the gap in #1657 design'
OUT=$(kw "$T/k1" "$IN_K3")
[ "$OUT" = "$WANT_K3" ] && ok || bad "K3: rewrite was
$OUT"
OUT=$(kw "$T/k4" "$IN_K1")
[ "$OUT" = "$IN_K1" ] && ok || bad "K4: no ticket-meta.json changed the body: $OUT"
# Through PR_BODY_FOR: the child's draft body says Closes #1657, the PR opens with Part of.
jq -n '{title:"x", body:"Part of #1657"}' > "$T/pb/ticket-meta.json"
render_body "$T/pb" "$T/body-k.txt" "Closes #1657 is the parent" lib
grep -q 'Part of #1657 is the parent' "$T/body-k.txt" 2>/dev/null && grep -qx 'Closes #1706' "$T/body-k.txt" && ok \
  || bad "K5: PR_BODY_FOR did not rewrite the parent keyword or lost its own Closes: $(head -5 "$T/body-k.txt" 2>/dev/null)"

echo "rb-prepr-gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
