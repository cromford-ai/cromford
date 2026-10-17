#!/bin/bash
# tests/ci-local-gates.bh-6897-test.sh — BH-6897: the three callers of
# bin/ci-local.sh, through bin/lib/ci-local-verify.sh.
#
#   V1-V3 cl_run words for a stub ci-local answering rc 0 / 1 / 2, a missing
#         bin (skipped) and the knob off; cl_verify_lines on red and clean
#   P1    the real prepr_gate: a red ci-local is an in-diff CI-LOCAL finding;
#         the one fix turn's brief carries it and says how to reproduce it
#   P2    still red after the turn: the pr.sh `rules pack block` span exits 6
#         with REVIEW_BLOCKED rules-pack before PR create
#   P3    the turn fixes it: fixed, cilocal=clean, no block; the late pass on a
#         moved head runs ci-local again
#   P4    ci-local could not run: no fix turn, cilocal=could-not-run, no block
#   P4b   red, then the re-scan after the fix turn could not run: lint red,
#         blocked before PR create
#   P5    the turn turns ci-local green by editing bin/ci-local.sh: still red,
#         blocked
#   P6    CI_LOCAL_GATE=0: off, the stub never runs
#   R1-R4 the real bin/blocked-resolver.sh verify block and brief block: red is
#         vrc=1 and a "not pushed" line; could-not-run and skipped are vrc=0;
#         the next round's brief carries the last round's findings; R5 the
#         round judges against origin/<the PR's base>; R6 an off round clears
#         the last round's findings
#   LR1-3 the real bin/lead-review.sh ci-local block: red is a BLOCK report
#         with no agent call; CI's lint job green is `skipped`; clean reaches
#         the agent, and the final report header names `- ci-local:`
#   RT1   the REAL bin/ci-local.sh on a fixture: its findings.txt reaches
#         prepr_scan, cl_verify_lines and the lead BLOCK with the same step name
#   M1    mutants: the ci-local block cut from prepr_scan fails P1; the
#         CI_LOCAL_EXIT grep cut from the resolver fails R1; the lead block's
#         red arm cut fails LR1
# Run from anywhere: tests/ci-local-gates.bh-6897-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset CI_LOCAL_GATE CI_LOCAL_BUDGET_S CL_BUDGET_CAP
export GIT_AUTHOR_DATE="2026-10-15T12:00:00Z" GIT_COMMITTER_DATE="2026-10-15T12:00:00Z"
export TMPDIR="$T/tmp"; mkdir -p "$TMPDIR"

CL="$DIR/bin/ci-local.sh"
PLAN="$DIR/bin/ci-local-plan.py"
LIB="$DIR/bin/lib/ci-local-verify.sh"
BR="$DIR/bin/blocked-resolver.sh"
LR="$DIR/bin/lead-review.sh"
LINT_JOB="Syntax + shellcheck + config integrity"
FINDING="CI-LOCAL $LINT_JOB / new scripts do not write row-backed state paths: STATE-PATHS-GUARD: bin/y.sh:3: writes state/pool (class rows)"

# The harness the gates source from: the prepr gate's closure (it carries
# ci-local-verify.sh and lane-gate.sh) and the lib's registry fragment.
H="$T/h"; mkdir -p "$H/bin/lib" "$H/catalog/lanes.d"
scratch_install_closure bin/lib/prepr-gate.sh "$H" >/dev/null || exit 1
cp "$DIR/catalog/lanes.d/_lib.ci-local.json" "$H/catalog/lanes.d/"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" > "$T/lanes.json" 2>"$T/lanes.err" \
  && [ -s "$T/lanes.json" ] && ok || bad "could not compose the lanes registry: $(head -3 "$T/lanes.err")"
export LANE_REGISTRY="$T/lanes.json"
[ -r "$H/bin/lib/ci-local-verify.sh" ] && ok || bad "setup: the prepr-gate closure lacks ci-local-verify.sh"

# The stub ci-local: answers call N from $CL_CTL (rc.N, find.N; call 1's
# files answer any call that has none), records its argv, writes --out.
cat > "$T/ci-local.stub" <<'SH'
#!/bin/bash
c="$CL_CTL"
n=$(( $(cat "$c/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$c/n"
printf '%s\n' "$*" >> "$c/argv"
k=$n; [ -f "$c/rc.$k" ] || k=1
out=""
while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
mkdir -p "$out"; : > "$out/findings.txt"; : > "$out/preexisting.txt"
[ -f "$c/find.$k" ] && cp "$c/find.$k" "$out/findings.txt"
echo "ci-local: stub call $n"
exit "$(cat "$c/rc.$k")"
SH
chmod +x "$T/ci-local.stub"
# ctl <case> <call> <rc> [finding] — script one call of the stub.
ctl() {
  local c="$T/$1/ctl"; mkdir -p "$c"
  echo "$3" > "$c/rc.$2"
  if [ -n "${4:-}" ]; then printf '%s\n' "$4" > "$c/find.$2"; else rm -f "$c/find.$2"; fi
}
ncalls() { cat "$T/$1/ctl/n" 2>/dev/null || echo 0; }

# ── V: the lib ──────────────────────────────────────────────────────────────
VW="$T/vw"; mkdir -p "$VW/bin"; cp "$T/ci-local.stub" "$VW/bin/ci-local.sh"
v() { # v <case> [env...] — cl_run on $VW, prints "<word> <rc>"
  local c="$1"; shift
  env HARNESS="$H" CL_CTL="$T/$c/ctl" "$@" bash -c '. "$0" || exit 9; w=$(cl_run "$1/bin/ci-local.sh" "$1" origin/main "$2" --skip-rules-pack); echo "$w $?"' \
    "$LIB" "$VW" "$T/$c/out"
}
ctl v1 1 0;  [ "$(v v1)" = "clean 0" ] && ok || bad "V1: rc 0 answers '$(v v1)'"
grep -q -- '--budget 900 --skip-rules-pack$' "$T/v1/ctl/argv" && grep -q -- "--tree $VW --base origin/main --out $T/v1/out" "$T/v1/ctl/argv" && ok \
  || bad "V1: argv '$(head -1 "$T/v1/ctl/argv")'"
ctl v2 1 1 "$FINDING"; [ "$(v v2)" = "red 1" ] && ok || bad "V2: rc 1 with a finding answers '$(v v2)'"
ctl v3 1 1;  [ "$(v v3)" = "could-not-run 2" ] && ok || bad "V3: rc 1 with no finding answers '$(v v3)'"
ctl v4 1 2;  [ "$(v v4)" = "could-not-run 2" ] && ok || bad "V3: rc 2 answers '$(v v4)'"
ctl v5 1 0;  [ "$(v v5 CI_LOCAL_GATE=0)" = "off 4" ] && [ "$(ncalls v5)" = 0 ] && ok || bad "V3: knob 0 answers '$(v v5 CI_LOCAL_GATE=0)'"
ctl v6 1 0;  [ "$(v v6 CL_BUDGET_CAP=77)" = "clean 0" ] && grep -q -- '--budget 77 ' "$T/v6/ctl/argv" && ok || bad "V1: CL_BUDGET_CAP=77 argv '$(cat "$T/v6/ctl/argv")'"
got=$(HARNESS="$H" bash -c '. "$0"; w=$(cl_run "$1/nope.sh" "$1" origin/main "$2"); echo "$w $?"' "$LIB" "$VW" "$T/v7")
[ "$got" = "skipped 3" ] && ok || bad "V3: a missing bin answers '$got'"
ctl v8 1 1 "$FINDING"
got=$(HARNESS="$H" CL_CTL="$T/v8/ctl" bash -c '. "$0"; cl_verify_lines "$1" origin/main "$2"' "$LIB" "$VW" "$T/v8/out")
[ "$got" = "== ci-local ==
$FINDING
CI_LOCAL_EXIT: 1" ] && ok || bad "V2: cl_verify_lines on red printed [$got]"
grep -q -- '--skip-rules-pack' "$T/v8/ctl/argv" && bad "V2: the fix-round run skipped the rules pack" || ok
ctl v9 1 0
got=$(HARNESS="$H" CL_CTL="$T/v9/ctl" bash -c '. "$0"; cl_verify_lines "$1" origin/main "$2"' "$LIB" "$VW" "$T/v9/out")
[ "$(tail -n 1 <<<"$got")" = "CI_LOCAL_EXIT: 0" ] && ok || bad "V2: cl_verify_lines on clean printed [$got]"

# ── P: the real prepr_gate ──────────────────────────────────────────────────
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^CC\(\) \{ # CC <stage>/{f=1} f{print} f&&/^\}/{exit}' "$RB_ALL" > "$T/cc.sh"
grep -q 'agent-call.sh' "$T/cc.sh" && ok || bad "could not lift CC() from bin/run-build.sh"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s %s %s\n' "$1" "$3" "$4" >> "$CALLLOG"
printf '%s\n' "$6" >> "$CALLLOG.prompt"
echo "stub ran" > "$5"
[ -n "${STUB_FIX:-}" ] && [ -f "$STUB_FIX" ] && bash "$STUB_FIX"
exit 0
SH
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERTLOG"
exit 0
SH
chmod +x "$H/bin/agent-call.sh" "$H/bin/alert-line.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/rules-pack.clean"; chmod +x "$T/rules-pack.clean"

# mkwt <name> [real] — a fixture worktree on ticket/x over main, with the real
# checks-run, determinism lint and test-impact, a clean stub pack, and the stub
# ci-local (or, with `real`, the real ci-local and a one-step workflow that is
# red only on the branch).
mkwt() {
  local w="$T/wt-$1"
  mkdir -p "$w/bin/lib" "$w/catalog" "$w/tests" "$w/.github/workflows"
  cp -r "$DIR/checks" "$w/"
  cp "$DIR/bin/checks-run.sh" "$DIR/bin/test-determinism-lint.sh" "$DIR/bin/test-impact.sh" "$w/bin/"
  cp "$DIR/catalog/determinism-lint.conf" "$w/catalog/"
  cp "$T/rules-pack.clean" "$w/bin/rules-pack.sh"
  if [ "${2:-}" = real ]; then
    cp "$CL" "$PLAN" "$w/bin/"; cp "$LIB" "$w/bin/lib/"; cp -r "$DIR/catalog/ci-local-skip.d" "$w/catalog/"
    printf '%s\n' 'name: Fixture CI' 'on: pull_request' 'jobs:' '  lint:' "    name: $LINT_JOB" '    runs-on: ubuntu-latest' \
      '    steps:' '      - uses: actions/checkout@v4' '      - name: the fixture lint' \
      '        run: |' '          if [ -f bin/y.sh ]; then echo "STATE-PATHS-GUARD: bin/y.sh:1: writes state/pool"; exit 1; fi' \
      '  determinism:' '    name: Test determinism lint' '    runs-on: ubuntu-latest' '    steps:' \
      '      - name: warn only' '        run: "true"' > "$w/.github/workflows/harness-ci.yml"
  else
    cp "$T/ci-local.stub" "$w/bin/ci-local.sh"
  fi
  ( cd "$w" || exit 1
    git init -q -b main && git config user.email t@example.com && git config user.name t
    git config commit.gpgsign false
    printf '#!/bin/bash\necho mapped\n' > bin/mapped.sh
    printf '#!/bin/bash\nDIR=$(cd "$(dirname "$0")/.." && pwd)\nbash "$DIR/bin/mapped.sh" >/dev/null\nbash "$DIR/bin/rules-pack.sh" >/dev/null\nbash "$DIR/bin/ci-local.sh" --list >/dev/null\nbash "$DIR/bin/ci-local-plan.py" >/dev/null\nbash "$DIR/bin/y.sh" >/dev/null\n' > tests/mapped-test.sh
    chmod +x bin/*.sh tests/*.sh
    git add -A && git commit -qm base
    git checkout -qb ticket/x
    printf '#!/bin/bash\necho plain\n' > bin/mapped.sh
    [ "${2:-}" = real ] && printf '#!/bin/bash\necho y\n' > bin/y.sh && chmod +x bin/y.sh
    git add -A && git commit -qm build ) >/dev/null 2>&1
  printf '%s' "$w"
}
cat > "$T/fix-commit.sh" <<'SH'
printf '#!/bin/bash\necho fixed\n' > bin/mapped.sh
git add -A && git commit -qm "fix the ci-local finding"
SH
cat > "$T/fix-edit-cl.sh" <<'SH'
printf '#!/bin/bash\nmkdir -p "$4"; : > "$4/findings.txt"; exit 0\n' > bin/ci-local.sh
git add -A && git commit -qm "make ci-local green"
SH

# drive <wt> <case> [env...] — prepr_gate; LATE=1 moves the head and runs the
# late pass.
drive() {
  local w="$1" c="$2"; shift 2
  mkdir -p "$T/$c/ctl"
  ( cd "$w" || exit 1
    env HARNESS="$H" BUILD="$T/$c" PROJECT=cromford KEY=BH-1 BRANCH=ticket/x FIX_MODEL=fix-model-x \
        CALLLOG="$T/$c/calls" STUB_FIX= CL_CTL="$T/$c/ctl" LATE= "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      CG_ORIENT=""
      . "$0"
      . "$HARNESS/bin/lib/prepr-gate.sh" || exit 9
      prepr_gate . main "$BUILD"
      if [ "$LATE" = 1 ]; then
        git commit -q --allow-empty -m move
        prepr_gate_late . main "$BUILD"
      fi
      declare -p PREPR_STATE PREPR_NOTE PREPR_SECTION PREPR_PACK_STATE PREPR_PACK_OUT PREPR_LINT_STATE PREPR_LINT_OUT > "$BUILD/vars.sh"
    ' "$T/cc.sh" >"$T/$c/out.txt" 2>&1 )
}
calls() { [ -f "$T/$1/calls" ] && wc -l < "$T/$1/calls" | tr -d ' ' || echo 0; }
vars()  { PREPR_STATE="<unset>"; PREPR_SECTION=""; PREPR_LINT_STATE="<unset>"
          [ -f "$T/$1/vars.sh" ] && . <(sed 's/^declare -- /declare -g /' "$T/$1/vars.sh"); }
awk '/^# >>> rules pack block/{f=1} f{print} /^# <<< rules pack block/{exit}' "$DIR/bin/lib/rb/pr.sh" > "$T/span-pr.sh"
[ -s "$T/span-pr.sh" ] && ok || bad "no '# >>> rules pack block' span in bin/lib/rb/pr.sh"
# block <case> — the pr.sh span after the case's gate; prints its exit code.
block() {
  local c="$1"
  rm -f "$T/$c/RESULT" "$T/$c/rules-pack-block.txt"
  env HARNESS="$H" BUILD="$T/$c" PROJECT=cromford KEY=BH-1 ALERTLOG="$T/$c/alerts" \
  bash -c '
    set -uo pipefail
    STAMP() { echo TS; }
    RESULT() { printf "%s\n" "$1" > "$BUILD/RESULT"; }
    escalate_block() { printf "%s\n%s\n" "$1" "$2" > "$BUILD/escalate"; }
    gh() { echo "gh $*" >> "$BUILD/gh.calls"; }
    . "$HARNESS/bin/lib/prepr-gate.sh" || exit 9
    . <(sed "s/^declare -- /declare -g /" "$BUILD/vars.sh")
    . "$0"
    gh pr create --title x
    echo PR_CREATE_REACHED
  ' "$T/span-pr.sh" > "$T/$c/block.out" 2>&1
  echo $?
}

# P1 / P2
W=$(mkwt p1)
ctl p1 1 1 "$FINDING"
drive "$W" p1
vars p1
grep -qF "$FINDING" "$T/p1/calls.prompt" 2>/dev/null && ok || bad "P1: the brief lacks the CI-LOCAL line: $(cat "$T/p1/prepr-scan.txt" 2>/dev/null) $(tail -3 "$T/p1/out.txt")"
grep -qF "bin/ci-local.sh --step '<step>'" "$T/p1/calls.prompt" 2>/dev/null && ok || bad "P1: the brief does not say how to reproduce a step"
grep -qF '`bin/ci-local.sh`' "$T/p1/calls.prompt" 2>/dev/null && ok || bad "P1: the brief's source list lacks bin/ci-local.sh"
[ "$(calls p1)" = 1 ] && ok || bad "P1: $(calls p1) fix calls, want 1"
[ "$(ncalls p1)" = 2 ] && ok || bad "P1: ci-local ran $(ncalls p1) times, want 2 (scan and re-scan)"
A=$(head -1 "$T/p1/ctl/argv" 2>/dev/null)
case " $A " in *" --base main "*" --skip-rules-pack "*) ok ;; *) bad "P1: argv '$A'" ;; esac
[ "$PREPR_STATE" = red ] && [ "$PREPR_LINT_STATE" = red ] && ok || bad "P1: state '$PREPR_STATE' lint '$PREPR_LINT_STATE', want red/red"
grep -qx 'cilocal=red' "$T/p1/prepr.txt" 2>/dev/null && ok || bad "P1: prepr.txt: $(tr '\n' ' ' < "$T/p1/prepr.txt" 2>/dev/null)"
grep -q 'PREPR ci-local=red red=1$' "$T/p1/pipeline.log" && ok || bad "P1: no 'PREPR ci-local=red red=1' log line"
grep -q 'PREPR state=red .*fix_calls=1 pack=clean$' "$T/p1/pipeline.log" && ok || bad "P1: the PREPR state= line changed shape: $(grep 'PREPR state=' "$T/p1/pipeline.log")"
grep -qF '`bin/ci-local.sh`' <<<"$PREPR_SECTION" && ok || bad "P1: the unresolved section does not name bin/ci-local.sh"
grep -qF 'test-determinism-lint' <<<"$PREPR_SECTION" && bad "P1: a CI-LOCAL line was credited to the determinism lint" || ok
RC=$(block p1)
[ "$RC" = 6 ] && ok || bad "P2: the pr.sh span exited $RC, want 6: $(cat "$T/p1/block.out")"
case "$(cat "$T/p1/RESULT" 2>/dev/null)" in "REVIEW_BLOCKED rules-pack: 1 finding(s)"*) ok ;; *) bad "P2: RESULT '$(cat "$T/p1/RESULT" 2>/dev/null)'" ;; esac
grep -qF "$FINDING" "$T/p1/rules-pack-block.txt" 2>/dev/null && ok || bad "P2: rules-pack-block.txt lacks the finding"
[ ! -f "$T/p1/gh.calls" ] && ! grep -q PR_CREATE_REACHED "$T/p1/block.out" && ok || bad "P2: the build reached gh pr create"

# P3
W=$(mkwt p3)
ctl p3 1 1 "$FINDING"; ctl p3 2 0; ctl p3 3 0
drive "$W" p3 STUB_FIX="$T/fix-commit.sh" LATE=1
vars p3
grep -qx 'state=fixed' "$T/p3/prepr.txt" && grep -qx 'cilocal=clean' "$T/p3/prepr.txt" && ok \
  || bad "P3: prepr.txt: $(tr '\n' ' ' < "$T/p3/prepr.txt" 2>/dev/null)"
[ "$(ncalls p3)" = 3 ] && ok || bad "P3: ci-local ran $(ncalls p3) times, want 3 (scan, re-scan, late pass)"
grep -qx 'cilocal=clean' "$T/p3/prepr-late/prepr.txt" 2>/dev/null && ok || bad "P3: the late pass recorded no cilocal=clean"
RC=$(block p3)
[ "$RC" = 0 ] && grep -q PR_CREATE_REACHED "$T/p3/block.out" && ok || bad "P3: a fixed ci-local was blocked (rc $RC)"

# P4b: red on the first pass, the fix turn commits, the re-scan's ci-local
# could not run (rc 2). The head is unchecked: lint red, the build stops.
W=$(mkwt p4b)
ctl p4b 1 1 "$FINDING"; ctl p4b 2 2
drive "$W" p4b STUB_FIX="$T/fix-commit.sh"
vars p4b
[ "$(calls p4b)" = 1 ] && [ "$(ncalls p4b)" = 2 ] && ok || bad "P4b: fix calls $(calls p4b) ci-local runs $(ncalls p4b), want 1 and 2"
[ "$PREPR_LINT_STATE" = red ] && ok || bad "P4b: a ci-local that could not re-run after the fix turn left lint '$PREPR_LINT_STATE' (state '$PREPR_STATE'), want red"
grep -qF '(still red: ci-local could not re-run after the fix turn' "$T/p4b/fast-lints-remaining.txt" 2>/dev/null && ok \
  || bad "P4b: fast-lints-remaining.txt [$(cat "$T/p4b/fast-lints-remaining.txt" 2>/dev/null)]"
RC=$(block p4b)
[ "$RC" = 6 ] && ! grep -q PR_CREATE_REACHED "$T/p4b/block.out" && ok || bad "P4b: the pr.sh span exited $RC, want 6: $(cat "$T/p4b/block.out")"

# P4
W=$(mkwt p4)
ctl p4 1 2
drive "$W" p4
vars p4
[ "$(calls p4)" = 0 ] && ok || bad "P4: a ci-local that could not run bought $(calls p4) fix call(s)"
grep -qx 'cilocal=could-not-run' "$T/p4/prepr.txt" && grep -qx 'state=clean' "$T/p4/prepr.txt" && ok \
  || bad "P4: prepr.txt: $(tr '\n' ' ' < "$T/p4/prepr.txt" 2>/dev/null)"
grep -q '^ci-local: could not run' "$T/p4/prepr-scan.txt" && ok || bad "P4: prepr-scan.txt does not say could not run"
RC=$(block p4)
[ "$RC" = 0 ] && ok || bad "P4: could-not-run blocked (rc $RC)"

# P5
W=$(mkwt p5)
ctl p5 1 1 "$FINDING"
drive "$W" p5 STUB_FIX="$T/fix-edit-cl.sh"
vars p5
[ "$PREPR_STATE" = red ] && [ "$PREPR_LINT_STATE" = red ] && ok || bad "P5: state '$PREPR_STATE' lint '$PREPR_LINT_STATE' after the turn edited bin/ci-local.sh"
grep -qF "edited the gate's own rules: bin/ci-local.sh" <<<"$PREPR_SECTION" && ok || bad "P5: section: $PREPR_SECTION"
RC=$(block p5)
[ "$RC" = 6 ] && grep -qF "edited ci-local's own rules" "$T/p5/rules-pack-block.txt" && ok || bad "P5: not blocked (rc $RC): $(cat "$T/p5/rules-pack-block.txt" 2>/dev/null)"

# P6
W=$(mkwt p6)
ctl p6 1 1 "$FINDING"
drive "$W" p6 CI_LOCAL_GATE=0
vars p6
[ "$(ncalls p6)" = 0 ] && grep -qx 'cilocal=off' "$T/p6/prepr.txt" && [ "$PREPR_STATE" = clean ] && ok \
  || bad "P6: knob 0 ran ci-local $(ncalls p6) time(s): $(tr '\n' ' ' < "$T/p6/prepr.txt" 2>/dev/null)"

# ── R: the real resolver blocks ─────────────────────────────────────────────
# The verify block from `local vrc=0` through the CI_LOCAL_EXIT grep, and the
# brief block, run as functions over the real lib and a stub ci-local.
awk '/^  local vrc=0$/{f=1} f{print} f && /CI_LOCAL_EXIT: 1/ {exit}' "$BR" > "$T/br-verify.sh"
awk '/# >>> br ci-local brief/{f=1} f{print} /# <<< br ci-local brief/{exit}' "$BR" > "$T/br-brief.sh"
grep -q 'cl_verify_lines "\$wt" "origin/\${mref:-main}"' "$T/br-verify.sh" && grep -q "CI_LOCAL_EXIT: 1' \"\$out\" && { vrc=1" "$T/br-verify.sh" && ok \
  || bad "R: the resolver verify block has no ci-local call or no CI_LOCAL_EXIT grep"
[ "$(grep -c '^\[ -r "\$H/bin/lib/ci-local-verify.sh" \] && \. "\$H/bin/lib/ci-local-verify.sh"$' "$BR")" = 1 ] && ok \
  || bad "R: bin/blocked-resolver.sh does not source bin/lib/ci-local-verify.sh"
[ -s "$T/br-brief.sh" ] && ok || bad "R: no '# >>> br ci-local brief' block"
RW="$T/rw"; mkdir -p "$RW/bin"; cp "$T/ci-local.stub" "$RW/bin/ci-local.sh"
# rver <case> <verify-file> [env...] — prints vrc; fix-verify text in $T/<case>.out
rver() {
  local c="$1" f="$2"; shift 2
  env HARNESS="$H" CL_CTL="$T/$c/ctl" "$@" bash -c '
    . "$0" || exit 9
    say() { printf "%s\n" "$*" >> "$OUTF.say"; }
    run() { local wt="$1" ST="$2" p=tproj ck=TK-1 out="$OUTF" rkey=r1 reason=lead-block H="$HARNESS"
      mkdir -p "$ST"
      . "$3"
      echo "$vrc"; }
    run "$1" "$2" "$3"' "$LIB" "$RW" "$T/$c/st" "$f" > "$T/$c.vrc" 2>"$T/$c.err"
  cat "$T/$c.vrc"
}
export OUTF
ctl r1 1 1 "$FINDING"; OUTF="$T/r1.out"
[ "$(rver r1 "$T/br-verify.sh")" = 1 ] && ok || bad "R1: a red ci-local leaves vrc '$(cat "$T/r1.vrc")': $(cat "$T/r1.err")"
grep -qx 'CI_LOCAL_EXIT: 1' "$T/r1.out" && grep -qF "$FINDING" "$T/r1.out" && ok || bad "R1: fix-verify: $(cat "$T/r1.out" 2>/dev/null)"
grep -q 'the CI lint steps are red .*1 finding line(s).* not pushed' "$T/r1.out.say" 2>/dev/null && ok || bad "R1: no 'not pushed' line"
[ -s "$T/r1/st/tproj/TK-1.ci-local/findings.txt" ] && ok || bad "R1: the round's findings are not kept for the next brief"
ctl r2 1 2; OUTF="$T/r2.out"
[ "$(rver r2 "$T/br-verify.sh")" = 0 ] && grep -qx 'CI_LOCAL_EXIT: could-not-run' "$T/r2.out" && ok || bad "R2: could-not-run vrc '$(cat "$T/r2.vrc")': $(cat "$T/r2.out")"
ctl r3 1 0; OUTF="$T/r3.out"
[ "$(rver r3 "$T/br-verify.sh")" = 0 ] && grep -qx 'CI_LOCAL_EXIT: 0' "$T/r3.out" && ok || bad "R2: clean vrc '$(cat "$T/r3.vrc")'"
OUTF="$T/r3b.out"; mv "$RW/bin/ci-local.sh" "$RW/bin/ci-local.off"
[ "$(rver r3b "$T/br-verify.sh")" = 0 ] && grep -qx 'CI_LOCAL_EXIT: skipped' "$T/r3b.out" && ok || bad "R2: a repo with no ci-local vrc '$(cat "$T/r3b.vrc")': $(cat "$T/r3b.out")"
mv "$RW/bin/ci-local.off" "$RW/bin/ci-local.sh"
# R4: the brief, with and without the last round's findings.
rbrief() { # rbrief <st-dir> — the brief text after the block
  bash -c 'brief="BASE BRIEF"; ST="$1"; p=tproj; ck=TK-1; . "$2"; printf "%s" "$brief"' _ "$1" "$T/br-brief.sh"
}
got=$(rbrief "$T/r1/st")
grep -qF 'THE CI LINT STEPS WERE RED ON THE LAST ROUND' <<<"$got" && grep -qF "$FINDING" <<<"$got" && ok || bad "R4: brief [$got]"
[ "$(rbrief "$T/r3/st")" = "BASE BRIEF" ] && ok || bad "R4: a clean last round changed the brief: [$(rbrief "$T/r3/st")]"
# R5: the round judges against the PR's own base (mref), not always main.
ctl r5 1 0; OUTF="$T/r5.out"
[ "$(rver r5 "$T/br-verify.sh" mref=stack/base)" = 0 ] && grep -q -- '--base origin/stack/base ' "$T/r5/ctl/argv" && ok \
  || bad "R5: a PR on stack/base ran ci-local with argv '$(cat "$T/r5/ctl/argv" 2>/dev/null)'"
grep -q -- '--base origin/main ' "$T/r3/ctl/argv" && ok || bad "R5: no mref did not default to origin/main: '$(cat "$T/r3/ctl/argv" 2>/dev/null)'"
# R6: a red round, then a round with the knob off: the stale findings are gone
# and the next brief carries none of them.
ctl r6 1 1 "$FINDING"; OUTF="$T/r6.out"
[ "$(rver r6 "$T/br-verify.sh")" = 1 ] && [ -s "$T/r6/st/tproj/TK-1.ci-local/findings.txt" ] && ok || bad "R6: setup: the red round kept no findings"
OUTF="$T/r6b.out"
[ "$(rver r6 "$T/br-verify.sh" CI_LOCAL_GATE=0)" = 0 ] && grep -qx 'CI_LOCAL_EXIT: off' "$T/r6b.out" && ok || bad "R6: knob 0 round: $(cat "$T/r6b.out" 2>/dev/null)"
[ ! -e "$T/r6/st/tproj/TK-1.ci-local/findings.txt" ] && [ "$(rbrief "$T/r6/st")" = "BASE BRIEF" ] && ok \
  || bad "R6: a knob-off round left the last round's findings for the next brief: [$(rbrief "$T/r6/st")]"

# ── LR: the real lead-review ci-local block ─────────────────────────────────
awk '/^  # >>> ci-local \(BH-6897\)/{f=1} f{print} /^  # <<< ci-local$/{exit}' "$LR" > "$T/lr-block.sh"
grep -q 'cl_run "\$H/bin/ci-local.sh" "\$WT" "origin/\$base" "\$WT.cl" --skip-rules-pack' "$T/lr-block.sh" && ok || bad "LR: no ci-local block in bin/lead-review.sh"
L_RP=$(grep -n '^  LR_RING_RP="\$RP_STATE"$' "$LR" | cut -d: -f1)
L_CL=$(grep -n '^  # >>> ci-local (BH-6897)' "$LR" | cut -d: -f1)
[ -n "$L_RP" ] && [ -n "$L_CL" ] && [ "$L_CL" -gt "$L_RP" ] && ok || bad "LR: the block must follow the rules pack (${L_RP:-none} < ${L_CL:-none})"
# The final report header names it between `- checklist` and `- pr body`, and
# the prompt has a `## CI local` section after the host suite.
# The real header printf, lifted from bin/lead-review.sh and run: its output
# names `- ci-local: <state>` before `- pr body:` (lead review lr-7005: the
# check reads real output, not the source text).
awk '/^  \{ printf .%s# Lead review %s/{f=1} f{print} f && /"\$bfp"$/{exit}' "$LR" > "$T/lr-header.sh"
printf '} > "$1"\n' >> "$T/lr-header.sh"
lrhead() { # lrhead <out> <CL_STATE or -unset>
  bash -c 'rl_mode() { echo strict; }
    RVLINE="" key=K repo=o/r pr=1 sha=abc verdict=APPROVE suite_line="host suite: x" RP_STATE=clean model=m CK_VER=1 ckl=v1 project=p rlk="" bfp=fp
    [ "$2" = -unset ] || CL_STATE="$2"
    . "$0"' "$T/lr-header.sh" "$1" "$2"
}
lrhead "$T/lrh1" clean
grep -qx -- '- ci-local: clean' "$T/lrh1" 2>/dev/null && [ "$(grep -n -- '^- ci-local: ' "$T/lrh1" | cut -d: -f1)" -lt "$(grep -n -- '^- pr body: ' "$T/lrh1" | cut -d: -f1)" ] && ok \
  || bad "LR3: the final report header has no '- ci-local:' line before '- pr body:': [$(cat "$T/lrh1" 2>/dev/null)] $(head -c 300 "$T/lr-header.sh")"
lrhead "$T/lrh2" -unset
grep -qx -- '- ci-local: not run' "$T/lrh2" 2>/dev/null && grep -qx -- '- pr body: fp' "$T/lrh2" && ok || bad "LR3: an unset CL_STATE header: [$(cat "$T/lrh2" 2>/dev/null)]"
L_HS=$(grep -n "^    printf '\\\\n## Host suite\\\\n%s\\\\n' \"\$suite_line\"$" "$LR" | cut -d: -f1)
L_CS=$(grep -n "^    printf '\\\\n## CI local\\\\n%s\\\\n' \"\$CL_STATE\"$" "$LR" | cut -d: -f1)
[ -n "$L_HS" ] && [ -n "$L_CS" ] && [ "$L_CS" -gt "$L_HS" ] && ok || bad "LR3: the prompt has no '## CI local' section after '## Host suite' (${L_HS:-none} ${L_CS:-none})"
LH="$T/lh"; mkdir -p "$LH/bin"; cp "$T/ci-local.stub" "$LH/bin/ci-local.sh"
# lrfn <block> <out> — the block as the body of review(), as it sits in
# review_one: its `return` must leave the function, not a sourced file.
lrfn() {
  { printf '%s\n' 'review() {' '  local H="$1" WT="$C/wt" repo="${LR_REPO:-example-org/cromford}" harness_repo=example-org/cromford'
    printf '%s\n' '  local sha=0123456789abcdef0123 base=main key=BH-9 pr=9 id=1 job=j1 report="$C/report.md" RVLINE="" bfp=fp'
    printf '%s\n' '  local RP_STATE=clean CL_STATE="" CL_TAIL="" left DEADLINE=$((SECONDS + 3600))'
    cat "$1"
    printf '%s\n' '  echo "AGENT_REACHED CL_STATE=$CL_STATE"' '}'; } > "$2"
}
lrfn "$T/lr-block.sh" "$T/lr-fn.sh"
# lr <case> <ci-green 0|1> [env...] — review() over the stub harness $LH.
lr() {
  local c="$1" g="$2"; shift 2
  mkdir -p "$T/$c"
  env HARNESS="$H" CL_CTL="$T/$c/ctl" CIGREEN="$g" "$@" bash -c '
    . "$0" || exit 9
    log() { printf "%s\n" "$*" >> "$C/log"; }
    job_update() { :; }
    finish_done() { printf "%s|" "$@" > "$C/finish"; }
    lr_ci_jobs_green() { printf "%s\n" "$*" >> "$C/cigreen"; [ "$CIGREEN" = 1 ]; }
    . "$2" || exit 9
    review "$1"' "$LIB" "${LR_H:-$LH}" "${LR_FN:-$T/lr-fn.sh}" > "$T/$c/out" 2>&1
}
export C
C="$T/lr1"; ctl lr1 1 1 "$FINDING"; lr lr1 0
grep -q AGENT_REACHED "$T/lr1/out" && bad "LR1: a red ci-local reached the agent" || ok
grep -qx -- '- ci-local: red' "$T/lr1/report.md" 2>/dev/null && grep -qx -- '- reviewer model: ci-local' "$T/lr1/report.md" \
  && grep -qx 'VERDICT: BLOCK' "$T/lr1/report.md" && grep -qxF -- "- [BLOCK] $FINDING" "$T/lr1/report.md" && ok \
  || bad "LR1: report [$(cat "$T/lr1/report.md" 2>/dev/null)] $(cat "$T/lr1/out")"
case "$(cat "$T/lr1/finish" 2>/dev/null)" in "1|j1|0123456789abcdef0123|BLOCK|$T/lr1/report.md|ci-local|ci-local: red|BH-9|") ok ;;
  *) bad "LR1: finish_done args '$(cat "$T/lr1/finish" 2>/dev/null)'" ;; esac
grep -q -- '--budget 900 --skip-rules-pack' "$T/lr1/ctl/argv" && ok || bad "LR1: argv '$(cat "$T/lr1/ctl/argv" 2>/dev/null)'"
grep -q "Syntax + shellcheck + config integrity" "$T/lr1/cigreen" && ok || bad "LR2: lr_ci_jobs_green was not asked about the lint job"
C="$T/lr2"; ctl lr2 1 1 "$FINDING"; lr lr2 1
grep -q '^AGENT_REACHED CL_STATE=skipped (CI lint job green on 0123456789ab)$' "$T/lr2/out" && [ "$(ncalls lr2)" = 0 ] && ok \
  || bad "LR2: CI green: $(cat "$T/lr2/out") calls $(ncalls lr2)"
C="$T/lr3"; ctl lr3 1 0; lr lr3 0
grep -q '^AGENT_REACHED CL_STATE=clean$' "$T/lr3/out" && ok || bad "LR3: clean: $(cat "$T/lr3/out")"
C="$T/lr4"; ctl lr4 1 2; lr lr4 0
grep -q '^AGENT_REACHED CL_STATE=could not run$' "$T/lr4/out" && ok || bad "LR3: could-not-run: $(cat "$T/lr4/out")"
C="$T/lr6"; ctl lr6 1 0; lr lr6 1 HOST_SUITE=always
grep -q '^AGENT_REACHED CL_STATE=clean$' "$T/lr6/out" && [ ! -e "$T/lr6/cigreen" ] && ok || bad "LR2: HOST_SUITE=always read the check runs or skipped the run: $(cat "$T/lr6/out")"
C="$T/lr5"; ctl lr5 1 1 "$FINDING"; lr lr5 0 CI_LOCAL_GATE=0
grep -q '^AGENT_REACHED CL_STATE=off$' "$T/lr5/out" && [ "$(ncalls lr5)" = 0 ] && ok || bad "LR3: knob 0: $(cat "$T/lr5/out")"

# ── RT1: the real ci-local through all three readers ────────────────────────
W=$(mkwt rt1 real)
( cd "$W" && HARNESS="$H" bash -c '. "$HARNESS/bin/lib/prepr-gate.sh" || exit 9; prepr_scan . main "$0"' "$T/rt1/scan" ) > "$T/rt1.scan.out" 2>&1; RC=$?
STEPN="CI-LOCAL $LINT_JOB / the fixture lint: STATE-PATHS-GUARD: bin/y.sh:1: writes state/pool"
[ "$RC" = 1 ] && grep -qxF "$STEPN" "$T/rt1/scan/prepr-findings.txt" 2>/dev/null && ok \
  || bad "RT1: prepr_scan rc $RC findings [$(cat "$T/rt1/scan/prepr-findings.txt" 2>/dev/null)] scan [$(cat "$T/rt1/scan/prepr-scan.txt" 2>/dev/null)] $(cat "$T/rt1/scan/ci-local.stdout" 2>/dev/null | tail -3)"
got=$(cd "$W" && HARNESS="$H" bash -c '. "$0"; cl_verify_lines "$1" main "$2"' "$LIB" "$W" "$T/rt1/verify")
grep -qxF "$STEPN" <<<"$got" && grep -qx 'CI_LOCAL_EXIT: 1' <<<"$got" && ok || bad "RT1: cl_verify_lines [$got]"
C="$T/rt1lr"; mkdir -p "$C"; ln -s "$W" "$C/wt"; mkdir -p "$T/rt1h/bin"; cp "$CL" "$PLAN" "$T/rt1h/bin/"
mkdir -p "$T/rt1h/bin/lib" "$T/rt1h/catalog"; cp "$LIB" "$T/rt1h/bin/lib/"; cp -r "$DIR/catalog/ci-local-skip.d" "$T/rt1h/catalog/"
( cd "$W" && git update-ref refs/remotes/origin/main main )
LR_H="$T/rt1h" lr rt1lr 0
grep -q AGENT_REACHED "$T/rt1lr/out" && bad "RT1: the real red ci-local reached the lead agent" || ok
grep -qxF -- "- [BLOCK] $STEPN" "$C/report.md" 2>/dev/null && ok || bad "RT1: the lead BLOCK report [$(cat "$C/report.md" 2>/dev/null)] $(cat "$T/rt1lr/out")"

# ── M1: mutants ─────────────────────────────────────────────────────────────
# prepr_scan without its ci-local block: P1's brief has no CI-LOCAL line.
mv "$H/bin/lib/prepr-gate.sh" "$T/prepr-gate.keep"
sed '/# >>> ci-local (BH-6897)/,/# <<< ci-local/d' "$T/prepr-gate.keep" > "$H/bin/lib/prepr-gate.sh"
cmp -s "$DIR/bin/lib/prepr-gate.sh" "$H/bin/lib/prepr-gate.sh" && bad "M1: the prepr mutation changed nothing" || ok
W=$(mkwt m1)
ctl m1 1 1 "$FINDING"
drive "$W" m1
grep -qF "$FINDING" "$T/m1/calls.prompt" 2>/dev/null && bad "M1: P1 still passes with the ci-local block cut from prepr_scan" || ok
mv -f "$T/prepr-gate.keep" "$H/bin/lib/prepr-gate.sh"
# the resolver without the CI_LOCAL_EXIT grep: R1's vrc is 0.
grep -v "CI_LOCAL_EXIT: 1' \"\$out\" && { vrc=1" "$T/br-verify.sh" > "$T/br-verify.mut.sh"
cmp -s "$T/br-verify.sh" "$T/br-verify.mut.sh" && bad "M1: the resolver mutation changed nothing" || ok
ctl m2 1 1 "$FINDING"; OUTF="$T/m2.out"
[ "$(rver m2 "$T/br-verify.mut.sh")" = 1 ] && bad "M1: R1 still passes with the CI_LOCAL_EXIT grep cut" || ok
# the lead block without its red arm: LR1 reaches the agent.
sed '/^      red)$/,/^        ;;$/d' "$T/lr-block.sh" > "$T/lr-block.mut.sh"
cmp -s "$T/lr-block.sh" "$T/lr-block.mut.sh" && bad "M1: the lead mutation changed nothing" || ok
lrfn "$T/lr-block.mut.sh" "$T/lr-fn.mut.sh"
C="$T/m3"; ctl m3 1 1 "$FINDING"; LR_FN="$T/lr-fn.mut.sh" lr m3 0
grep -q AGENT_REACHED "$T/m3/out" && ok || bad "M1: LR1 still passes with the red arm cut"

echo "ci-local-gates.bh-6897: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
