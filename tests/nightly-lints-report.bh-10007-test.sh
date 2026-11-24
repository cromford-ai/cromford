#!/bin/bash
# tests/nightly-lints-report.bh-10007-test.sh — BH-10007: the payload-pin lint
# is a report in the nightly lints job, and the other two lints stay strict.
#
# It takes the `the hygiene lints, strict` step of harness-nightly.yml's
# `lints` job and runs its run body for real in a scratch tree, with stub
# lints whose exit codes each case sets:
#   N1  payload-pin rc 1, the other two rc 0: the step exits 0, writes no
#       lints.md, prints a ::warning:: line for the finding, and the step
#       summary has a `payload-pin: report only` section.
#   N2  determinism rc 1: the step exits 1, and lints.md names determinism.
#   N3  day-boundary-guard rc 1 (with payload-pin rc 1 too): the step exits 1,
#       and lints.md names day-boundary-guard and not payload-pin.
#   N4  all rc 0: the step exits 0 and writes no lints.md.
#   N5  the verdict job still needs lints and still fails on a red lints job.
# Mutations (each turns this suite red): call payload-pin through `lint`
# again (N1 rc 1); make `report` return the lint's rc (N1); drop the
# ::warning:: line (N1).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/nightly-lints-report.bh-10007-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
WF="${NL_WORKFLOW:-$DIR/.github/workflows/harness-nightly.yml}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ -n "${CI:-}" ] && { echo "FAIL: PyYAML missing on a CI runner"; exit 1; }
  echo "nightly-lints-report: PyYAML missing — skipping on this dev machine"; exit 0
fi

python3 - "$WF" "$T/lints-run.sh" "$T/verdict.txt" <<'PY'
import sys, yaml
wf, out, vout = sys.argv[1:4]
jobs = yaml.safe_load(open(wf)).get("jobs") or {}
st = [s for s in (jobs.get("lints") or {}).get("steps") or [] if s.get("name") == "the hygiene lints, strict"]
open(out, "w").write(str(st[0].get("run", "")) if st else "")
v = jobs.get("verdict") or {}
open(vout, "w").write("needs=%s\nrun=%s\n" % (v.get("needs"), "\n".join(str(s.get("run", "")) for s in v.get("steps") or [])))
PY
[ -s "$T/lints-run.sh" ] && ok || { bad "no 'the hygiene lints, strict' step with a run body in $WF"; echo "nightly-lints-report.bh-10007: $PASS passed, $FAIL failed"; exit 1; }

W="$T/w"; mkdir -p "$W/bin" "$W/tests"
stub() {  # stub <path> <env var holding the rc> <finding line>
  printf '#!/bin/bash\necho "%s"\nexit "${%s:-0}"\n' "$3" "$2" > "$W/$1"; chmod +x "$W/$1"
}
stub bin/test-determinism-lint.sh RC_DET 'tests/a-test.sh:3: clock-date-cmd: date -u'
stub bin/test-payload-pin-lint.sh RC_PIN 'console-ui/tests/x.test.js:49: payload-pin: deep-equal-whole: deep-equals the whole response'
stub tests/day-boundary-guard.bh-6052-test.sh RC_DAY 'day-boundary-guard: 1 fail'
run_step() {  # run_step <det> <pin> <day> -> rc; files under $T/rt
  rm -rf "$T/rt"; mkdir -p "$T/rt"; : > "$T/rt/summary.md"
  ( cd "$W" && RC_DET="$1" RC_PIN="$2" RC_DAY="$3" RUNNER_TEMP="$T/rt" GITHUB_STEP_SUMMARY="$T/rt/summary.md" \
      LINTS_BASE=0000000000000000000000000000000000000000 bash -e "$T/lints-run.sh" ) > "$T/rt/out" 2>&1
}

run_step 0 1 0; rc=$?
[ "$rc" = 0 ] && ok || bad "N1 a payload-pin finding alone must not make the step red (rc=$rc): $(tail -3 "$T/rt/out")"
[ ! -e "$T/rt/lints/lints.md" ] && ok || bad "N1 a payload-pin finding alone must write no lints.md: $(cat "$T/rt/lints/lints.md")"
grep -q '^::warning title=payload-pin (report only)::console-ui/tests/x.test.js:49: ' "$T/rt/out" && ok \
  || bad "N1 the finding must be a ::warning:: line: $(grep -n warning "$T/rt/out")"
grep -q '^### payload-pin: report only, rc 1' "$T/rt/summary.md" && ok || bad "N1 the step summary must carry the payload-pin report: $(cat "$T/rt/summary.md")"

run_step 1 0 0; rc=$?
[ "$rc" = 1 ] && ok || bad "N2 a determinism finding must make the step red (rc=$rc)"
grep -q '^# Nightly hygiene lints red: determinism' "$T/rt/lints/lints.md" 2>/dev/null && ok || bad "N2 lints.md must name determinism: $(cat "$T/rt/lints/lints.md" 2>/dev/null)"

run_step 0 1 1; rc=$?
[ "$rc" = 1 ] && ok || bad "N3 a day-boundary-guard failure must make the step red (rc=$rc)"
head -1 "$T/rt/lints/lints.md" 2>/dev/null | grep -qx '# Nightly hygiene lints red: day-boundary-guard' && ok \
  || bad "N3 lints.md must name day-boundary-guard only: $(head -1 "$T/rt/lints/lints.md" 2>/dev/null)"

run_step 0 0 0; rc=$?
[ "$rc" = 0 ] && [ ! -e "$T/rt/lints/lints.md" ] && ok || bad "N4 all green must be rc 0 with no lints.md (rc=$rc)"

grep -q "^needs=.*'lints'" "$T/verdict.txt" && ok || bad "N5 the verdict job must need lints: $(head -1 "$T/verdict.txt")"
grep -q 'LINTS_RESULT" != success' "$T/verdict.txt" && ok || bad "N5 the verdict must still fail on a red lints job"

echo "nightly-lints-report.bh-10007: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
