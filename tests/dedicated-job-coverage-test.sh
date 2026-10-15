#!/bin/bash
# tests/dedicated-job-coverage-test.sh — a suite may stop repeating a dedicated
# CI job's work only while that job really does it (2026-09-28).
#
# Two kinds of work ran twice in every merge-queue batch:
#   * three test-determinism-lint suites re-ran the lint over the whole tree,
#     the same scan the "Test determinism lint" job runs on every event;
#   * jobs-worker-test, cost-caps-contract and job-abandon re-ran worker/jobs
#     node files that the "Jobs worker — routes + schema" job runs with
#     `npm test` on the same run (their duplicate reds in the 09-25..28 window
#     were the job's own router-table red, three times over).
# The copies are gone (the lint suites) or skipped when WORKER_JOBS_CI_JOB=1
# (the worker suites, which still run for a builder's pre-push gate). What keeps
# that from being a hole is this suite, which pins the other side:
#   D1  the determinism job runs the lint over the whole tree, on every event,
#       and it is a required check. Since BH-6838 it runs --warn-only on a PR
#       and a batch, and the STRICT whole-tree run is the nightly `lints` job
#       (.github/workflows/harness-nightly.yml), with nothing that could
#       soften it
#   D2  the worker job runs exactly when the traced shards do, renders the
#       registry, runs `npm test` in worker/jobs, and refuses a skipped test
#   D3  worker/jobs `npm test` covers every node file the three suites name
#   D4  the shard step sets WORKER_JOBS_CI_JOB=1 and nothing else in any
#       workflow does; each of the three suites honours it
# Run from anywhere: tests/dedicated-job-coverage-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
WF="${DEDICATED_WORKFLOW:-$DIR/.github/workflows/harness-ci.yml}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ -n "${CI:-}" ] && { echo "FAIL: PyYAML missing on a CI runner"; exit 1; }
  echo "dedicated-job-coverage: PyYAML missing — skipping on this dev machine"; exit 0
fi

# D1, D2, D4 (the workflow half).
PYOUT=$(python3 - "$WF" "$DIR/.mergify.yml" "$DIR/.github/workflows" <<'PY'
import glob, os, sys, yaml
wf_path, mergify_path, wf_dir = sys.argv[1:4]
wf = yaml.safe_load(open(wf_path)); jobs = wf.get("jobs") or {}
def bad(m): print("BAD " + m)
def ok(): print("OK")
# D1
d = jobs.get("determinism") or {}
ok() if d.get("name") == "Test determinism lint" else bad(f"D1: no 'Test determinism lint' job (got {d.get('name')!r})")
ok() if not d.get("if") else bad(f"D1: the determinism job must run on every event: if: {d.get('if')!r}")
runs = [str(s.get("run", "")).strip() for s in d.get("steps") or [] if s.get("run")]
ok() if any("bin/test-determinism-lint.sh --warn-only" in r for r in runs) else bad(f"D1: the CI job must run `bin/test-determinism-lint.sh --warn-only` over the whole tree (BH-6838): {runs!r}")
# BH-6838: the strict whole-tree scan is the nightly lints job.
nwf = yaml.safe_load(open(os.path.join(wf_dir, "harness-nightly.yml")))
ln = ((nwf.get("jobs") or {}).get("lints") or {})
lruns = "\n".join(str(s.get("run", "")) for s in ln.get("steps") or [])
import re as _re
ok() if _re.search(r"(^|\s)bin/test-determinism-lint\.sh\s*$", lruns, _re.M) and "--warn-only" not in lruns \
    else bad(f"D1: the nightly lints job must run bare `bin/test-determinism-lint.sh` (whole tree, strict): {lruns!r}")
ok() if not ln.get("if") else bad(f"D1: the nightly lints job must run on every nightly event: if: {ln.get('if')!r}")
ok() if not any(s.get("continue-on-error") for s in ln.get("steps") or []) else bad("D1: a nightly lint step with continue-on-error gates nothing")
ok() if not any(s.get("continue-on-error") for s in d.get("steps") or []) else bad("D1: a lint step with continue-on-error gates nothing")
m = yaml.safe_load(open(mergify_path))
for r in m.get("queue_rules") or []:
    conds = " ".join(str(c) for c in (r.get("queue_conditions") or []) + (r.get("merge_conditions") or []))
    ok() if "Test determinism lint" in conds else bad(f"D1: queue {r.get('name')} must require 'Test determinism lint'")
# D2
w = jobs.get("worker-jobs") or {}
sh = jobs.get("tests-shard") or {}
ok() if w else bad("D2: no worker-jobs job")
ok() if str(w.get("if", "")).strip() and str(w.get("if", "")).strip() == str(sh.get("if", "")).strip() \
    else bad(f"D2: worker-jobs must run exactly when tests-shard does: {w.get('if')!r} vs {sh.get('if')!r}")
steps = w.get("steps") or []
ok() if any("bin/lanes-build.sh --write" in str(s.get("run", "")) for s in steps) else bad("D2: worker-jobs must render the registry the worker imports")
ok() if any(s.get("working-directory") == "worker/jobs" and "npm test" in str(s.get("run", "")) for s in steps) \
    else bad("D2: worker-jobs must run `npm test` in worker/jobs")
ok() if any("worker-jobs skip guard" in str(s.get("run", "")) for s in steps) else bad("D2: worker-jobs must refuse a skipped test")
# D4
senv = {}
for s in sh.get("steps") or []:
    if "test-trace-safety.sh --gate" in str(s.get("run", "")):
        senv = s.get("env") or {}
ok() if str(senv.get("WORKER_JOBS_CI_JOB")) == "1" else bad(f"D4: the traced shard step must set WORKER_JOBS_CI_JOB=1: {senv!r}")
for f in sorted(glob.glob(os.path.join(wf_dir, "*.yml"))):
    t = yaml.safe_load(open(f)) or {}
    for jn, jb in (t.get("jobs") or {}).items():
        if os.path.abspath(f) == os.path.abspath(wf_path) and jn == "tests-shard":
            continue
        for s in (jb or {}).get("steps") or []:
            if "WORKER_JOBS_CI_JOB" in (s.get("env") or {}) or "WORKER_JOBS_CI_JOB" in str(s.get("run", "")):
                bad(f"D4: {os.path.basename(f)} job {jn} sets WORKER_JOBS_CI_JOB, but no worker job runs beside it")
        if "WORKER_JOBS_CI_JOB" in ((jb or {}).get("env") or {}):
            bad(f"D4: {os.path.basename(f)} job {jn} sets WORKER_JOBS_CI_JOB at job level")
    if "WORKER_JOBS_CI_JOB" in (t.get("env") or {}):
        bad(f"D4: {os.path.basename(f)} sets WORKER_JOBS_CI_JOB for every job")
PY
)
PASS=$((PASS + $(grep -c '^OK$' <<<"$PYOUT")))
while IFS= read -r l; do bad "${l#BAD }"; done < <(grep '^BAD ' <<<"$PYOUT")

# D3. `npm test` in worker/jobs is node --test over test/*.test.js (and
# test/routes/), so every file the three suites hand to node --test must live
# there (jobs-worker-test hands it the test/*.test.js glob itself).
TESTSCRIPT=$(jq -r '.scripts.test // ""' "$DIR/worker/jobs/package.json" 2>/dev/null)
case " $TESTSCRIPT " in *" test/*.test.js "*) ok ;; *) bad "D3: worker/jobs npm test no longer covers test/*.test.js: '$TESTSCRIPT'" ;; esac
SUITES="tests/jobs-worker-test.sh tests/cost-caps-contract.bh-2563-test.sh tests/job-abandon.bh-2406-test.sh"
for s in $SUITES; do
  grep -q 'node --test' "$DIR/$s" && ok || bad "D3: $s runs no node --test at all — nothing here is a copy of the worker job"
  for f in $(grep 'node --test' "$DIR/$s" | grep -oE 'test/[A-Za-z0-9._-]+\.test\.js' | LC_ALL=C sort -u); do
    [ -f "$DIR/worker/jobs/$f" ] && ok || bad "D3: $s names worker/jobs/$f, which npm test cannot run (no such file)"
  done
done

# D4 (the suite half): each suite honours the flag, and says so when it does.
for s in $SUITES; do
  grep -q 'WORKER_JOBS_CI_JOB:-}" = 1' "$DIR/$s" && ok || bad "D4: $s does not read WORKER_JOBS_CI_JOB"
done
OUT=$(WORKER_JOBS_CI_JOB=1 bash "$DIR/tests/jobs-worker-test.sh" 2>&1); RC=$?
{ [ "$RC" = 0 ] && grep -q 'Jobs worker CI job' <<<"$OUT" && ! grep -q '^# pass\|^ℹ pass' <<<"$OUT"; } && ok \
  || bad "D4: jobs-worker-test under the flag must say the worker job runs it, and run no node test (rc=$RC): $(head -5 <<<"$OUT")"

echo "dedicated-job-coverage: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
