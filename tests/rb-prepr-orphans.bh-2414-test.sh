#!/bin/bash
# tests/rb-prepr-orphans.bh-2414-test.sh — BH-2414: the pre-PR gate runs CI's
# orphan ratchet. On 2026-09-25 three pool PRs (#2382, #2388, #2402) opened red
# on `bin/test-impact.sh orphans --check`: each added console-ui files that only
# a node test imported, by a relative path, and the orphan gate wants the path
# named in a tests/*.sh suite. The build's own pre-PR gate ran checks-run and
# the determinism lint, never the ratchet, so it passed all three.
#
# Every fixture worktree is a scratch git repo holding copies of the REAL gates
# (bin/checks-run.sh + checks/, bin/test-determinism-lint.sh + its conf, and
# bin/test-impact.sh), driven through the real prepr_gate with the real CC()
# and a stub $HARNESS/bin/agent-call.sh that applies the case's scripted fix.
#
#   O1  a console-ui file only a node test imports -> the scan names it, the
#       fix turn gets it (and the rooted-path rule), a suite that names it is
#       `fixed`
#   O2  the same build with the naming suite from the start -> clean, no call
#   O3  an orphan the BASE already had is not this build's -> clean
#   O4  the fix turn fixes nothing -> red, and the section names the ratchet
#   O5  a committed catalog/test-impact-orphans.txt is a finding, not a
#       parse failure
#   O6  a ratchet that cannot run is could-not-run, never clean
#   O7  the invocation IS CI's: the argv the gate runs ($0 and its args, as
#       the ratchet itself sees them) equals the command in
#       .github/workflows/harness-ci.yml, from the repo root, with TI_BASE set
#       to the build's merge-base (CI sets TI_BASE on that step too)
#   O8  a repo that ships no bin/test-impact.sh keeps the old behaviour
#   O9  the rule is in the brief the builder reads (build-discipline.md)
# Run from anywhere: tests/rb-prepr-orphans.bh-2414-test.sh   (exit 0 = all pass)
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
cp "$LIB" "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" > "$T/lanes.json" 2>"$T/lanes.err" \
  && [ -s "$T/lanes.json" ] && ok || bad "could not compose the lanes registry: $(head -3 "$T/lanes.err")"

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
chmod +x "$H/bin/agent-call.sh"

# mkwt <name> <base-setup-fn> <build-setup-fn> [no-ti] — a fixture worktree on
# branch ticket/x over main; prints its path.
mkwt() {
  local w="$T/wt-$1" ti="${4:-}"
  mkdir -p "$w/bin" "$w/catalog" "$w/tests"
  cp -r "$DIR/checks" "$w/"
  cp "$DIR/bin/checks-run.sh" "$DIR/bin/test-determinism-lint.sh" "$w/bin/"
  [ "$ti" = no-ti ] || cp "$DIR/bin/test-impact.sh" "$w/bin/"
  cp "$DIR/catalog/determinism-lint.conf" "$w/catalog/"
  ( cd "$w" || exit 1
    git init -q -b main && git config user.email t@example.com && git config user.name t
    git config commit.gpgsign false
    "$2"
    git add -A && git commit -qm base
    git checkout -qb ticket/x
    "$3"
    git add -A && git commit -qm build ) >/dev/null 2>&1
  printf '%s' "$w"
}
# The base every fixture shares: one script a suite names, one nothing names.
base_tree() {
  printf '#!/bin/bash\necho mapped\n' > bin/mapped.sh
  printf '#!/bin/bash\necho lonely\n' > bin/lonely.sh
  printf '#!/bin/bash\nDIR=$(cd "$(dirname "$0")/.." && pwd)\nbash "$DIR/bin/mapped.sh" >/dev/null\n' > tests/mapped-test.sh
  chmod +x bin/*.sh tests/*.sh
}
# The #2382 shape: a console-ui lib that only a node test imports, relatively.
add_node_only() {
  mkdir -p console-ui/src/lib console-ui/tests
  printf 'export const widget = (n) => n + 1;\n' > console-ui/src/lib/widget.js
  printf "import { widget } from '../src/lib/widget.js';\nimport test from 'node:test';\ntest('w', () => widget(1));\n" \
    > console-ui/tests/widget.bh-9-test.js
}
NAMING_SUITE='#!/bin/bash
DIR=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$DIR/console-ui/src/lib/widget.js" ] || exit 1'
add_named() { add_node_only; printf '%s\n' "$NAMING_SUITE" > tests/widget.bh-9-test.sh; chmod +x tests/widget.bh-9-test.sh; }
add_plain() { printf '#!/bin/bash\necho plain\n' > bin/mapped.sh; }
add_tracked_list() {
  add_plain
  printf 'bin/lonely.sh\n' > catalog/test-impact-orphans.txt
}
none() { :; }

cat > "$T/fix-name.sh" <<SH
printf '%s\n' '$NAMING_SUITE' > tests/widget.bh-9-test.sh
chmod +x tests/widget.bh-9-test.sh
git add -A && git commit -qm "name widget.js in a shell suite"
SH

# drive <wt> <case> [env...] — prepr_gate on the fixture with the real CC().
drive() {
  local w="$1" c="$2"; shift 2
  mkdir -p "$T/$c"
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
first() { cat "$T/$1/prepr-findings.first.txt" 2>/dev/null; }

# ── O1: node-only import -> finding named, fix turn, a naming suite fixes it ─
W=$(mkwt o1 base_tree add_node_only)
drive "$W" o1 STUB_FIX="$T/fix-name.sh"
vars o1
first o1 | grep -q '^ORPHAN console-ui/src/lib/widget.js ' && ok \
  || bad "O1: the scan did not name console-ui/src/lib/widget.js as an orphan: $(first o1) $(cat "$T/o1/prepr-scan.txt" 2>/dev/null)"
[ "$(calls o1)" = 1 ] && ok || bad "O1: expected exactly 1 fix call, got $(calls o1): $(cat "$T/o1/out.txt")"
grep -q '^ORPHAN console-ui/src/lib/widget.js ' "$T/o1/calls.prompt" 2>/dev/null && ok \
  || bad "O1: the fix brief does not carry the orphan line"
grep -qF 'tests/cost-breaker-console.bh-2331-test.sh' "$T/o1/calls.prompt" 2>/dev/null \
  && grep -qF 'rooted path on a non-comment line' "$T/o1/calls.prompt" && ok \
  || bad "O1: the fix brief does not state the rooted-path, non-comment-line rule with the pattern suite"
[ "$PREPR_STATE" = fixed ] && ok || bad "O1: state '$PREPR_STATE', want fixed ($(cat "$T/o1/prepr-scan.txt" 2>/dev/null))"
grep -q '^orphans rc=0' "$T/o1/prepr-scan.txt" 2>/dev/null && ok || bad "O1: the re-scan did not record orphans rc=0"

# ── O2: the same build with the naming suite already there -> clean ─────────
W=$(mkwt o2 base_tree add_named)
drive "$W" o2
vars o2
[ "$PREPR_STATE" = clean ] && ok || bad "O2: state '$PREPR_STATE', want clean: $(first o2) $(cat "$T/o2/prepr-scan.txt" 2>/dev/null)"
[ "$(calls o2)" = 0 ] && ok || bad "O2: a clean build bought $(calls o2) call(s)"

# ── O3: the base's own orphan (bin/lonely.sh) is not this build's ───────────
W=$(mkwt o3 base_tree add_plain)
drive "$W" o3
vars o3
[ "$PREPR_STATE" = clean ] && ok || bad "O3: a pre-existing orphan made the build '$PREPR_STATE': $(first o3)"
grep -q 'lonely' "$T/o3/prepr-findings.txt" && bad "O3: bin/lonely.sh was charged to this build" || ok

# ── O4: the fix turn fixes nothing -> red, the section names the ratchet ────
W=$(mkwt o4 base_tree add_node_only)
drive "$W" o4
vars o4
[ "$PREPR_STATE" = red ] && ok || bad "O4: state '$PREPR_STATE', want red"
[ "$PREPR_NOTE" = " | prepr=red" ] && ok || bad "O4: note '$PREPR_NOTE'"
grep -qF '`bin/test-impact.sh orphans --check`' <<<"$PREPR_SECTION" && ok \
  || bad "O4: the section does not name the orphan ratchet: $PREPR_SECTION"
grep -qF 'test-determinism-lint' <<<"$PREPR_SECTION" && bad "O4: an ORPHAN line was labelled a determinism-lint finding" || ok
grep -q 'ORPHAN console-ui/src/lib/widget.js' <<<"$PREPR_SECTION" && ok || bad "O4: the section does not list the orphan"

# ── O5: a committed orphan list is a finding, not a parse failure ───────────
W=$(mkwt o5 base_tree add_tracked_list)
drive "$W" o5
vars o5
first o5 | grep -q '^ORPHAN catalog/test-impact-orphans.txt ' && ok \
  || bad "O5: a TRACKED orphan list was not reported as a finding (state '$PREPR_STATE'): $(cat "$T/o5/orphans.txt" 2>/dev/null | head -3)"

# ── O6: a ratchet that cannot run is could-not-run, never clean ─────────────
crash_ti() { base_tree; printf '#!/bin/bash\necho boom >&2\nexit 2\n' > bin/test-impact.sh; chmod +x bin/test-impact.sh; }
W=$(mkwt o6 crash_ti add_plain no-ti)
drive "$W" o6
vars o6
[ "$PREPR_STATE" = could-not-run ] && ok || bad "O6: state '$PREPR_STATE', want could-not-run"
[ "$(calls o6)" = 0 ] && ok || bad "O6: a crashed ratchet bought an agent call"

# ── O7: the invocation is CI's, byte for byte ───────────────────────────────
# The command CI runs, read from the workflow, and the env the step sets.
CI_CMD=$(grep -E '^[[:space:]]+bin/test-impact\.sh orphans' "$DIR/.github/workflows/harness-ci.yml" | sed 's/^[[:space:]]*//')
[ "$(grep -c . <<<"$CI_CMD")" = 1 ] && ok || bad "O7: expected one orphans line in harness-ci.yml, got '$CI_CMD'"
awk '/^      - name:/{step=""} {step=step $0 "\n"} /bin\/test-impact\.sh orphans --check/{print step; exit}' \
  "$DIR/.github/workflows/harness-ci.yml" | grep -q 'TI_BASE: \${{ github.event.pull_request.base.sha }}' && ok \
  || bad "O7: CI's orphan step no longer sets TI_BASE to the PR base — the gate's analog is stale"
record_ti() {
  base_tree
  cat > bin/test-impact.sh <<'SH'
#!/bin/bash
printf 'argv=%s %s\ncwd=%s\nti_base=%s\n' "$0" "$*" "$PWD" "${TI_BASE:-}" > "$RECORD"
exit 0
SH
  chmod +x bin/test-impact.sh
}
W=$(mkwt o7 record_ti add_plain no-ti)
drive "$W" o7 RECORD="$T/o7/record.txt"
GATE_CMD=$(sed -n 's/^argv=//p' "$T/o7/record.txt" 2>/dev/null)
[ -n "$GATE_CMD" ] && [ "$GATE_CMD" = "$CI_CMD" ] && ok \
  || bad "O7: the gate ran '$GATE_CMD', CI runs '$CI_CMD'"
diff <(printf '%s\n' "$CI_CMD") <(printf '%s\n' "$GATE_CMD") >/dev/null && ok || bad "O7: the two invocations differ"
[ "$(sed -n 's/^cwd=//p' "$T/o7/record.txt" 2>/dev/null)" = "$(cd "$W" && pwd)" ] && ok \
  || bad "O7: the gate did not run the ratchet from the worktree root"
MB=$(git -C "$W" merge-base main HEAD)
[ "$(sed -n 's/^ti_base=//p' "$T/o7/record.txt" 2>/dev/null)" = "$MB" ] && ok \
  || bad "O7: TI_BASE was '$(sed -n 's/^ti_base=//p' "$T/o7/record.txt" 2>/dev/null)', want the merge-base $MB"

# ── O8: no bin/test-impact.sh -> the ratchet is skipped, not a failure ──────
W=$(mkwt o8 base_tree add_node_only no-ti)
drive "$W" o8
vars o8
[ "$PREPR_STATE" = clean ] && ok || bad "O8: a repo without the ratchet went '$PREPR_STATE'"
grep -q '^orphans: skipped' "$T/o8/prepr-scan.txt" 2>/dev/null && ok || bad "O8: prepr-scan.txt does not say the ratchet was skipped"

# ── O9: the builder's brief carries the rule ────────────────────────────────
D="$DIR/prompts/build-discipline.md"
grep -E '^- \*\*D[0-9]+ ' "$D" | grep -F 'rooted path on a non-comment line' | grep -qF 'tests/cost-breaker-console.bh-2331-test.sh' && ok \
  || bad "O9: build-discipline.md has no rule naming new sources by rooted path on a non-comment line with the pattern suite"
# TEST-CHANGE (BH-7970): the execute block renders prompts/stages/execute.md through sp_render; the pointer lives in that template.
grep -q '^sp_render execute ' <(awk '/^# >>> execute prompt/{f=1} f{print} /^# <<< execute prompt/{exit}' "$RB_ALL") \
  && grep -qF 'build-discipline.md' "$DIR/prompts/stages/execute.md" && ok \
  || bad "O9: the execute prompt no longer points the builder at build-discipline.md"

echo "rb-prepr-orphans: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
