#!/bin/bash
# tests/ci-pyyaml.bh-1741-test.sh — BH-1741: PYYAML IS ON EVERY MACHINE THE
# CORPUS RUNS ON, AND A MACHINE WITHOUT IT IS RED IN CI, NEVER A SKIP.
#
# The mergify-template compare arms parse YAML with python3 + PyYAML. Neither
# the bh-ci runner image nor the test host carried it, so the suites printed
# "PyYAML missing — skipping", exited 0, and CI reported a green for arms that
# never ran. That is the codegraph/semgrep/rsync shape again, one tool over.
#
#   A  bin/ci-tool-present.sh --python-module <name>: rc 0 importable, rc 1 not
#      (or no python3), rc 2 misuse — and a name that is not a module name is
#      refused BEFORE python3 sees it, because the name is python source
#   B  both shard jobs install python3-yaml behind that guard and then assert
#      it UNGUARDED, before the step that runs the corpus
#   C  both images bake python3-yaml in their apt block
#   D  tests/hotfix-mergify-template-test.sh without PyYAML: CI=true is a FAIL
#      and exit 1; outside CI it is still the dev-laptop skip
#
# The real helper and the real suite are driven, against fake python3 shims on
# PATH. No network, no clock.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PRESENT="$DIR/bin/ci-tool-present.sh"
WF="$DIR/.github/workflows/harness-ci.yml"
BASH_BIN=$(command -v bash)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# fake_python <dir> <import-rc> — a python3 that logs every call and answers
# `-c "import yaml"` with <import-rc>. Anything else it was not built for is
# rc 99, so a caller that sends a different program is visible.
fake_python() {
  mkdir -p "$1"
  cat > "$1/python3" <<SH
#!$BASH_BIN
printf '%s\n' "\$*" >> "$1/calls.log"
[ "\$1" = -c ] && [ "\$2" = "import yaml" ] && exit $2
exit 99
SH
  chmod +x "$1/python3"
}

# ── A. the helper's --python-module form ────────────────────────────────────
fake_python "$T/py-ok" 0
fake_python "$T/py-no" 1
mkdir -p "$T/empty"
present() { # present <path> <args...> -> rc on stdout
  local p="$1"; shift
  PATH="$p" "$BASH_BIN" "$PRESENT" "$@" >"$T/present.out" 2>&1; echo $?
}
RC=$(present "$T/py-ok" --python-module yaml)
[ "$RC" = 0 ] && ok || bad "A1: an importable module must be rc 0 (got $RC: $(cat "$T/present.out"))"
grep -qx -- '-c import yaml' "$T/py-ok/calls.log" 2>/dev/null \
  && ok || bad "A1: the helper must ask python3 to import exactly the named module (calls: $(cat "$T/py-ok/calls.log" 2>/dev/null))"
RC=$(present "$T/py-no" --python-module yaml)
[ "$RC" = 1 ] && ok || bad "A2: a failed import must be rc 1 — install it (got $RC: $(cat "$T/present.out"))"
RC=$(present "$T/empty" --python-module yaml)
[ "$RC" = 1 ] && ok || bad "A3: no python3 on PATH must be rc 1 (got $RC: $(cat "$T/present.out"))"
RC=$(present "$T/py-ok" --python-module)
[ "$RC" = 2 ] && ok || bad "A4: --python-module with no name is misuse, rc 2 — never 0 (got $RC)"
: > "$T/py-ok/calls.log"
RC=$(present "$T/py-ok" --python-module 'yaml;x')
[ "$RC" = 2 ] && ok || bad "A5: a name that is not a module name must be rc 2 (got $RC: $(cat "$T/present.out"))"
[ -s "$T/py-ok/calls.log" ] && bad "A5: python3 must never see a refused name (calls: $(cat "$T/py-ok/calls.log"))" || ok
RC=$(present "$T/py-ok" --python-module yaml extra)
[ "$RC" = 2 ] && ok || bad "A5: a trailing argument is misuse, rc 2 (got $RC)"
# The existing form is untouched: a command on PATH is still rc 0.
printf '#!%s\necho "jq-1.7"\n' "$BASH_BIN" > "$T/py-ok/jq"; chmod +x "$T/py-ok/jq"
RC=$(present "$T/py-ok" jq)
[ "$RC" = 0 ] && ok || bad "A6: 'ci-tool-present.sh jq' must still be rc 0 (got $RC: $(cat "$T/present.out"))"

# ── B. the two shard jobs install and assert it before the corpus runs ──────
# job_steps <job> -> "<step#>\t<line>" for the job's non-comment lines, with
# backslash continuations joined. A job that is not there prints nothing.
job_steps() {
  awk -v job="  $1:" '
    $0 == job { inj = 1; next }
    inj && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { exit }
    !inj { next }
    /^[[:space:]]*#/ { next }
    /^      - / { n++ }
    { line = $0; sub(/^[[:space:]]+/, "", line)
      if (held != "") { line = held " " line; held = "" }
      if (line ~ /\\$/) { sub(/[[:space:]]*\\$/, "", line); held = line; next }
      if (n) print n "\t" line }' "$WF"
}
check_job() { # check_job <job> <literal marking the step that must come after>
  local J="$1" after="$2" S step later
  S=$(job_steps "$J")
  [ -n "$S" ] || { bad "B: job '$J' not found in $WF"; return; }
  # The PyYAML step: the one that apt-installs python3-yaml.
  step=$(printf '%s\n' "$S" | awk -F'\t' '$2 ~ /apt-get install/ && $2 ~ /python3-yaml/ { print $1; exit }')
  [ -n "$step" ] || { bad "B1: '$J' has no step that apt-installs python3-yaml"; return; }
  ok
  BODY=$(printf '%s\n' "$S" | awk -F'\t' -v s="$step" '$1 == s { print $2 }')
  grep -qx 'if ! bin/ci-tool-present.sh --python-module yaml; then' <<<"$BODY" \
    && ok || bad "B1: '$J' must guard the install with 'if ! bin/ci-tool-present.sh --python-module yaml' (step: $(printf '%s' "$BODY" | tr '\n' '|'))"
  # The LAST line of the step is the unguarded assert — what makes the job red.
  [ "$(printf '%s\n' "$BODY" | tail -1)" = 'bin/ci-tool-present.sh --python-module yaml' ] \
    && ok || bad "B1: '$J' must END the step with an unguarded 'bin/ci-tool-present.sh --python-module yaml' (step: $(printf '%s' "$BODY" | tr '\n' '|'))"
  grep -qx 'set -euo pipefail' <<<"$BODY" \
    && ok || bad "B1: '$J' PyYAML step must run under set -euo pipefail"
  later=$(printf '%s\n' "$S" | awk -F'\t' -v a="$after" 'index($2, a) { print $1; exit }')
  [ -n "$later" ] || { bad "B2: '$J' has no step matching '$after'"; return; }
  [ "$step" -lt "$later" ] && ok || bad "B2: '$J' must install PyYAML (step $step) BEFORE '$after' (step $later)"
}
# ONE corpus job since the CI cost cut (2026-09-24): the traced shards run the
# suite once for both checks, so the PyYAML-before-the-corpus rule is one job.
check_job tests-shard 'bin/test-trace-safety.sh --gate'

# ── C. both images bake it ──────────────────────────────────────────────────
# The first logical RUN instruction that apt-installs, continuations joined;
# python3-yaml must be a whole word in it.
apt_block() {
  awk '{ line = $0
         if (held != "") { line = held " " line; held = "" }
         if (line ~ /\\$/) { sub(/\\$/, "", line); held = line; next }
         if (line ~ /apt-get install/) { print line; exit } }' "$1"
}
for F in fly/testhost/Dockerfile fly/Dockerfile; do
  B=$(apt_block "$DIR/$F")
  [ -n "$B" ] || { bad "C: no apt-get install block in $F"; continue; }
  printf '%s\n' "$B" | tr -s ' \t;' '\n' | grep -qx 'python3-yaml' \
    && ok || bad "C: $F's apt block must install python3-yaml"
done

# ── D. the PyYAML suite fails, not skips, under CI=true ─────────────────────
SUITE="$DIR/tests/hotfix-mergify-template-test.sh"
if command -v jq >/dev/null; then
  CI=true PATH="$T/py-no:$PATH" bash "$SUITE" > "$T/d1.out" 2>&1; RC=$?
  [ "$RC" != 0 ] && ok || bad "D1: no PyYAML under CI=true must exit nonzero (got $RC: $(cat "$T/d1.out"))"
  grep -qF 'FAIL: PyYAML missing under CI=true' "$T/d1.out" && grep -q 'BH-1741' "$T/d1.out" \
    && ok || bad "D1: the failure must say why (got: $(cat "$T/d1.out"))"
  grep -q 'skipping' "$T/d1.out" && bad "D1: CI=true must not print a skip" || ok
  env -u CI PATH="$T/py-no:$PATH" bash "$SUITE" > "$T/d2.out" 2>&1; RC=$?
  [ "$RC" = 0 ] && ok || bad "D2: no PyYAML outside CI stays the dev-laptop skip, exit 0 (got $RC: $(cat "$T/d2.out"))"
  grep -q 'PyYAML missing — skipping' "$T/d2.out" && ok || bad "D2: outside CI the skip line must be printed (got: $(cat "$T/d2.out"))"
else
  bad "D: jq is required to reach the suite's PyYAML check"
fi

echo "ci-pyyaml: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
