#!/bin/bash
# tests/harness-ci-main-ci.bh-6746-test.sh — BH-6746 (wave 3 of #6541): the
# Harness CI wiring of the push-direct class and the `main-ci` commit status.
#
#   W1 the job `main-ci` exists, runs only on a push and not when cancelled
#   W2 the plan job outputs push_class; the plan step sets CI_PLAN_LANDING '1'
#      and the plan job may read commit statuses (statuses: read)
#   W3 the shard re-plan step passes CI_PLAN_PUSH_CLASS from the plan's output
#   W4 the job's step, RUN with a fake gh: every needed job green or skipped ->
#      one POST statuses/<sha> context=main-ci state=success; one failed or
#      cancelled job -> state=failure naming it; a refused POST -> rc != 0 and
#      an ::error:: line
#   W5 permissions are exactly {statuses: write}; runs-on reads vars.CI_RUNNER
#   W6 needs covers plan, ci-image, lint, determinism, console-ui, worker-jobs,
#      tests-shard, decisions and harness-safety, and the step reads each result
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
WF="$DIR/.github/workflows/harness-ci.yml"
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ -n "${CI:-}" ] && { echo "FAIL: PyYAML missing on a CI runner"; exit 1; }
  echo "harness-ci-main-ci: PyYAML missing — skipping on this dev machine"; exit 0
fi
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# W1-W3, W5, W6: the YAML, parsed.
R=$(python3 - "$WF" "$T/run.sh" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1])); jobs = wf.get("jobs") or {}
out = []
def say(ok, msg): out.append(("ok " if ok else "FAIL: ") + msg)
m = jobs.get("main-ci")
say(m is not None, "W1: job main-ci exists")
m = m or {}
cond = str(m.get("if", ""))
say("github.event_name == 'push'" in cond and "!cancelled()" in cond, "W1: main-ci if has push and !cancelled(): %r" % cond)
plan = jobs.get("plan") or {}
say("push_class" in (plan.get("outputs") or {}) and "steps.plan.outputs.push_class" in str(plan["outputs"].get("push_class")),
    "W2: plan outputs push_class")
penv = {}
for st in plan.get("steps") or []:
    if st.get("id") == "plan": penv = st.get("env") or {}
say(str(penv.get("CI_PLAN_LANDING")) == "1", "W2: the plan step sets CI_PLAN_LANDING '1' (got %r)" % penv.get("CI_PLAN_LANDING"))
say((plan.get("permissions") or {}).get("statuses") == "read", "W2: the plan job has statuses: read")
senv = {}
for st in (jobs.get("tests-shard") or {}).get("steps") or []:
    if "--expect-n" in str(st.get("run", "")): senv = st.get("env") or {}
say("needs.plan.outputs.push_class" in str(senv.get("CI_PLAN_PUSH_CLASS", "")), "W3: the shard re-plan passes CI_PLAN_PUSH_CLASS")
say(m.get("permissions") == {"statuses": "write"}, "W5: permissions exactly statuses: write (got %r)" % m.get("permissions"))
say("vars.CI_RUNNER" in str(m.get("runs-on", "")), "W5: runs-on reads vars.CI_RUNNER")
want = ["plan", "ci-image", "lint", "determinism", "console-ui", "worker-jobs", "tests-shard", "decisions", "harness-safety"]
needs = m.get("needs") or []
say(all(w in needs for w in want), "W6: needs covers %s (got %r)" % (want, needs))
steps = m.get("steps") or []
run = "".join(str(s.get("run", "")) for s in steps)
env = {}
for s in steps: env.update(s.get("env") or {})
for w in want:
    say(env.get("R_" + w.upper().replace("-", "_")) == "${{ needs.%s.result }}" % w, "W6: the step reads needs.%s.result" % w)
say(all(w in run for w in ["R_" + x.upper().replace("-", "_") for x in want]), "W6: the run loop judges every R_ variable")
# The run script, with the two expressions the runner would substitute.
open(sys.argv[2], "w").write(run.replace("${{ github.repository }}", "o/r").replace("${{ github.sha }}", "abc123def4567890abc123def4567890abc12345"))
print("\n".join(out))
PY
)
while IFS= read -r l; do case "$l" in "ok "*) ok ;; *) bad "${l#FAIL: }" ;; esac; done <<<"$R"

# W4: the step itself, run with a fake gh.
mkdir -p "$T/bin" || exit 1
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
[ -z "${GH_FAIL:-}" ] || exit 1
SH
chmod +x "$T/bin/gh"
JOBS="PLAN CI_IMAGE LINT DETERMINISM CONSOLE_UI WORKER_JOBS TESTS_SHARD DECISIONS HARNESS_SAFETY"
step() { # step [VAR=value ...] — every R_ success unless overridden
  local -a e=(PATH="$T/bin:$PATH" GH_SINK="$T/sink" GITHUB_SHA=abc123def4567890abc123def4567890abc12345
              PLAN_MODE=push-direct "PLAN_SUMMARY=impact: 33 of 983 suites" RUN_URL=https://github.com/o/r/actions/runs/1)
  local j; for j in $JOBS; do e+=("R_$j=success"); done
  : > "$T/sink"
  OUT=$(env "${e[@]}" "$@" bash "$T/run.sh" 2>&1); RC=$?
  SINK=$(cat "$T/sink")
}
step R_CONSOLE_UI=skipped R_DECISIONS=skipped
{ [ "$RC" = 0 ] && [ "$(grep -c . <<<"$SINK")" = 1 ]; } && ok || bad "W4: green -> one POST (rc=$RC sink=$SINK out=$OUT)"
case "$SINK" in "api -X POST repos/o/r/statuses/abc123def4567890abc123def4567890abc12345 "*) ok ;; *) bad "W4: POST to the pushed sha: $SINK" ;; esac
for f in "state=success" "context=main-ci" "description=push-direct: impact: 33 of 983 suites" "target_url=https://github.com/o/r/actions/runs/1"; do
  case "$SINK" in *"-f $f"*) ok ;; *) bad "W4: field $f missing: $SINK" ;; esac
done
step R_TESTS_SHARD=failure
case "$SINK" in *"-f state=failure"*"-f context=main-ci"*"TESTS_SHARD=failure"*) ok ;; *) bad "W4: a failed shard -> failure naming it: $SINK" ;; esac
step R_LINT=cancelled
case "$SINK" in *"-f state=failure"*) ok ;; *) bad "W4: a cancelled job -> failure: $SINK" ;; esac
step GH_FAIL=1
{ [ "$RC" != 0 ] && case "$OUT" in *"::error::main-ci=success could not be posted"*) true ;; *) false ;; esac; } && ok \
  || bad "W4: a refused POST is a red job with an ::error:: (rc=$RC out=$OUT)"

echo "harness-ci-main-ci: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
