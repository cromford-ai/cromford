#!/bin/bash
# tests/harness-ci-worker-jobs.bh-1137-test.sh — BH-1137: THE JOBS WORKER'S
# TESTS RAN NOWHERE.
#
# THE SILENCE THIS KILLS. `.github/workflows/harness-ci.yml` had exactly one JS
# job, `console-ui`. worker/jobs — the coordination API every box reads and
# writes (`/api/settings`, `/api/flags`, `/api/lanes/*`, the job rows, the
# schema's idempotence) — carried 302 `node --test` cases that CI never ran. A
# PR could break a route and every check stayed green.
#
# So this suite asserts three things about the workflow, and DRIVES the one
# piece of it that is code:
#
#   1. a job runs the worker/jobs suite (`working-directory: worker/jobs`,
#      `npm test`), and every worker package that declares a test script is
#      named by some job or run by a tests/*.sh suite — a new worker with tests
#      cannot land uncovered;
#   2. it does NOT `npm ci` there. worker/jobs has no dependencies on purpose
#      and therefore no package-lock.json, and `npm ci` EXITS NONZERO without
#      one — the ticket's own suggested command would have made the new gate
#      red on every PR for a reason unrelated to the diff;
#   3. the skip guard, extracted VERBATIM from the workflow by its
#      `# >>> worker-jobs skip guard` markers and run against recorded
#      reporter output, accepts a real run and refuses a skipped test, a
#      zero-pass run and an unreadable summary. `settings-schema.test.js`
#      skips itself when `node:sqlite` cannot be imported, and a skip inside a
#      green job is the same invisibility one layer down.
#
# No network, no clock, no model. Run from anywhere: exit 0 = all pass.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
WF="${BH1137_WORKFLOW:-$DIR/.github/workflows/harness-ci.yml}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

[ -f "$WF" ] || { echo "FAIL: workflow not found at $WF"; exit 1; }

# The block of one top-level job: from `^  <name>:` to the next job at the same
# indent. Read positionally so a missing job yields an empty string (and fails)
# rather than the next job's steps.
job_block() {
  awk -v want="$1" '
    /^  [a-zA-Z0-9_-]+:/ { inblk = ($0 ~ "^  "want":[[:space:]]*$") }
    inblk { print }
  ' "$WF"
}

# ── 1. a job runs the worker/jobs suite ──────────────────────────────────────
JOB=$(job_block worker-jobs)
# Comment-only lines are stripped first: the job explains in prose WHY it does
# not use npm ci, and an assertion that reads the explanation as the command is
# an assertion about nothing.
JOB_CODE=$(printf '%s\n' "$JOB" | grep -v '^[[:space:]]*#')
if [ -n "$JOB" ]; then ok; else bad "no 'worker-jobs:' job in $WF (BH-1137)"; fi

case "$JOB" in
  *"working-directory: worker/jobs"*) ok ;;
  *) bad "the worker-jobs job must run a step with 'working-directory: worker/jobs'" ;;
esac
case "$JOB_CODE" in
  *"npm test"*) ok ;;
  *) bad "the worker-jobs job must run 'npm test'" ;;
esac

# Every worker package that declares a test script is covered by SOME CI run: a
# workflow job with `working-directory: worker/<name>`, or a `tests/*.sh` suite
# (which CI's tests loop runs) that cds into worker/<name> and runs `node --test`
# or `npm test` there. worker/watchdog is covered the second way (BH-1920). A
# future worker with tests and neither fails here, rather than shipping the same
# silence again. Comment lines in a runner are ignored: prose that NAMES the
# directory runs nothing.
# $1 = repo root, $2 = workflow, $3 = worker name → rc 0 when covered.
worker_covered() {
  local root=$1 wf=$2 name=$3 t code
  grep -q "working-directory: worker/$name\$" "$wf" && return 0
  for t in "$root"/tests/*.sh; do
    [ -f "$t" ] || continue
    code=$(grep -v '^[[:space:]]*#' "$t")
    grep -Eq "^[[:space:]]*cd [^;&|]*worker/$name/?[\"']?([[:space:]]|\$)" <<<"$code" || continue
    grep -Eq '(^|[[:space:];&|])(node --test|npm test)([[:space:]]|$)' <<<"$code" && return 0
  done
  return 1
}

for pkg in "$DIR"/worker/*/package.json; do
  [ -f "$pkg" ] || continue
  grep -q '"test"[[:space:]]*:' "$pkg" || continue
  name=$(basename "$(dirname "$pkg")")
  if worker_covered "$DIR" "$WF" "$name"; then ok
  else bad "worker/$name declares a test script but no CI job runs it (BH-1137)"; fi
done

# Drive worker_covered itself over fixture trees, so the runner route cannot
# quietly widen into "any file that mentions the directory".
FX="$T/fx"; mkdir -p "$FX/tests"
printf 'jobs:\n  worker-jobs:\n    steps:\n      - run: npm test\n        working-directory: worker/jobs\n' > "$FX/wf.yml"
worker_covered "$FX" "$FX/wf.yml" jobs && ok || bad "worker_covered refused a workflow job with working-directory: worker/jobs"
worker_covered "$FX" "$FX/wf.yml" demo && bad "worker_covered accepted worker/demo with no job and no runner" || ok
printf '#!/bin/bash\ncd "$(dirname "$0")/../worker/demo" || exit 1\nnode --test test/*.test.js\n' > "$FX/tests/demo-test.sh"
worker_covered "$FX" "$FX/wf.yml" demo && ok || bad "worker_covered refused a tests/*.sh runner that cds into worker/demo and runs node --test"
worker_covered "$FX" "$FX/wf.yml" dem && bad "worker_covered matched worker/dem against a runner for worker/demo" || ok
printf '#!/bin/bash\n# cd worker/other && node --test\necho nothing\n' > "$FX/tests/demo-test.sh"
worker_covered "$FX" "$FX/wf.yml" other && bad "worker_covered accepted a runner whose cd and node --test are only in a comment" || ok
printf '#!/bin/bash\ncd "$(dirname "$0")/../worker/other" || exit 1\nls test\n' > "$FX/tests/demo-test.sh"
worker_covered "$FX" "$FX/wf.yml" other && bad "worker_covered accepted a runner that cds into worker/other but runs no tests" || ok

# ── 2. no `npm ci` where there is no lockfile ────────────────────────────────
# Conditional on purpose: the day worker/jobs grows a lockfile, `npm ci` becomes
# the right command and this assertion steps aside instead of blocking it.
if [ -f "$DIR/worker/jobs/package-lock.json" ]; then
  ok
else
  case "$JOB_CODE" in
    *"npm ci"*) bad "the worker-jobs job runs 'npm ci' but worker/jobs has no package-lock.json — npm ci exits nonzero without one" ;;
    *) ok ;;
  esac
fi

# ── 3. drive the skip guard itself ───────────────────────────────────────────
# Extracted verbatim between the markers, de-indented (YAML indents it; bash
# does not care). A test that restated the guard would pass while the guard in
# the workflow was broken.
GUARD="$T/skip-guard.sh"
awk '/# >>> worker-jobs skip guard/{f=1;next} /# <<< worker-jobs skip guard/{f=0} f' "$WF" \
  | sed 's/^[[:space:]]*//' > "$GUARD"
if [ -s "$GUARD" ]; then ok; else bad "no '# >>> worker-jobs skip guard' block in $WF"; fi

run_guard() {  # $1 = log file → prints rc
  ( TEST_LOG="$1" bash "$GUARD" >"$T/guard.out" 2>&1 ); echo $?
}

# (a) a real spec-reporter summary — what Node prints on the runner today
cat > "$T/spec.log" <<'EOF'
✔ vendor-spend is behind the same bearer as every other metrics route (1.5ms)
ℹ tests 302
ℹ suites 0
ℹ pass 302
ℹ fail 0
ℹ cancelled 0
ℹ skipped 0
ℹ todo 0
ℹ duration_ms 134.2
EOF
RC=$(run_guard "$T/spec.log")
if [ "$RC" = 0 ]; then ok; else bad "guard refused a clean spec-reporter run (rc=$RC): $(cat "$T/guard.out")"; fi

# (b) the tap reporter prints the same counts behind a '#'
cat > "$T/tap.log" <<'EOF'
1..28
# tests 28
# suites 0
# pass 28
# fail 0
# cancelled 0
# skipped 0
# todo 0
# duration_ms 69.5
EOF
RC=$(run_guard "$T/tap.log")
if [ "$RC" = 0 ]; then ok; else bad "guard refused a clean tap-reporter run (rc=$RC): $(cat "$T/guard.out")"; fi

# (c) a SKIPPED test is the whole point — node:sqlite missing, schema unproven
sed 's/^ℹ skipped 0$/ℹ skipped 1/' "$T/spec.log" > "$T/skipped.log"
RC=$(run_guard "$T/skipped.log")
if [ "$RC" != 0 ]; then ok; else bad "guard accepted a run with 1 skipped test — a skipped test gates nothing"; fi
grep -qi 'skip' "$T/guard.out" && ok || bad "the guard's refusal must name the skip: $(cat "$T/guard.out")"

# (d) zero passing tests is a suite that did not run, not a green
sed 's/^ℹ pass 302$/ℹ pass 0/' "$T/spec.log" > "$T/zero.log"
RC=$(run_guard "$T/zero.log")
if [ "$RC" != 0 ]; then ok; else bad "guard accepted a run that passed 0 tests"; fi

# (e) an unreadable summary fails loudly rather than reading as clean
printf 'some other output\nno summary here\n' > "$T/junk.log"
RC=$(run_guard "$T/junk.log")
if [ "$RC" != 0 ]; then ok; else bad "guard accepted a log with no summary at all"; fi

echo "harness-ci-worker-jobs.bh-1137-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
