#!/bin/bash
# tests/ci-merge-reuse-wiring.bh-5357-test.sh — BH-5357: the merge-from-main
# decider is wired into the real workflow, and only the steps its catalog maps
# can be skipped by it.
#
#   W1  jobs.lint has a step `id: reuse` that runs bin/ci-merge-reuse.sh, with
#       continue-on-error: true, `if` limited to pull_request, the knob from
#       vars. through env, and no ${{ in its run:.
#   W2  every catalog row id maps to exactly one lint step whose `if` carries
#       steps.reuse.outputs.run_<id> != '0', and no step names an id the
#       catalog lacks.
#   W3  the always steps carry no steps.reuse condition.
#   W4  jobs.lint.permissions is exactly contents: read + actions: read, plus
#       packages: read for the CI image pull (BH-7255).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/ci-merge-reuse-wiring.bh-5357-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
WF="${MR_WIRING_WORKFLOW:-$DIR/.github/workflows/harness-ci.yml}"
CAT="$DIR/catalog/ci-merge-reuse.tsv"
[ -f "$DIR/bin/ci-merge-reuse.sh" ] || { echo "FAIL: bin/ci-merge-reuse.sh does not exist"; exit 1; }
[ -f "$CAT" ] || { echo "FAIL: catalog/ci-merge-reuse.tsv does not exist"; exit 1; }
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ -n "${CI:-}" ] && { echo "FAIL: PyYAML missing on a CI runner"; exit 1; }
  echo "ci-merge-reuse-wiring: PyYAML missing — skipping on this dev machine"; exit 0
fi

python3 - "$WF" "$CAT" <<'PY'
import re, sys, yaml
wf_path, cat_path = sys.argv[1:3]
wf = yaml.safe_load(open(wf_path))
lint = (wf.get("jobs") or {}).get("lint") or {}
steps = lint.get("steps") or []
ids = [l.split("\t")[0] for l in open(cat_path).read().splitlines()
       if l.strip() and not l.startswith("#") and len(l.split("\t")) >= 2]
P = F = 0
def ok():
    global P; P += 1
def bad(m):
    global F; F += 1; print("FAIL: " + m)

# W1
reuse = [s for s in steps if s.get("id") == "reuse"]
if len(reuse) != 1:
    bad("W1: jobs.lint has %d steps with id: reuse, want 1" % len(reuse))
else:
    s = reuse[0]
    run = str(s.get("run", ""))
    ok() if "bin/ci-merge-reuse.sh" in run else bad("W1: the reuse step does not run bin/ci-merge-reuse.sh")
    ok() if "${{" not in run else bad("W1: the reuse step interpolates ${{ }} into run:")
    ok() if s.get("continue-on-error") is True else bad("W1: the reuse step is not continue-on-error: true")
    ok() if str(s.get("if", "")).strip() == "github.event_name == 'pull_request'" else bad("W1: the reuse step's if is %r" % s.get("if"))
    env = s.get("env") or {}
    ok() if str(env.get("PR_CI_MERGE_REUSE", "")).replace(" ", "") == "${{vars.PR_CI_MERGE_REUSE}}" else bad("W1: PR_CI_MERGE_REUSE does not come from vars. through env")
    for k in ("MR_ACTION", "MR_BEFORE", "MR_HEAD", "MR_BASE_REF", "MR_HEAD_REF", "CI_REPO", "GH_TOKEN"):
        ok() if k in env else bad("W1: the reuse step's env has no %s" % k)
    first = [i for i, x in enumerate(steps) if x.get("id") == "reuse"][0]
    later = [i for i, x in enumerate(steps) if "steps.reuse" in str(x.get("if", ""))]
    ok() if later and min(later) > first else bad("W1: a step reads steps.reuse before the reuse step runs")

# W2
for i in ids:
    pat = re.compile(r"steps\.reuse\.outputs\.run_%s\s*!=\s*'0'" % re.escape(i))
    hits = [s.get("name") for s in steps if pat.search(str(s.get("if", "")))]
    ok() if len(hits) == 1 else bad("W2: catalog id %s gates %d lint steps, want 1: %r" % (i, len(hits), hits))
for s in steps:
    for m in re.findall(r"steps\.reuse\.outputs\.run_([A-Za-z0-9_-]+)", str(s.get("if", ""))):
        ok() if m in ids else bad("W2: step %r names run_%s, which the catalog lacks" % (s.get("name"), m))
want_names = {
    "vmap": "verification-map index generates and its sources validate",
    "derived": "the derived docs generate and their gates pass",
    "renders": "lane renders generate and their sources validate",
    "render-diff": "what this PR changes about the files a box installs",
}
byname = {s.get("name"): s for s in steps}
for i, n in want_names.items():
    s = byname.get(n)
    if s is None:
        bad("W2: no lint step named %r" % n); continue
    ok() if ("run_%s" % i) in str(s.get("if", "")) else bad("W2: %r is not gated on run_%s" % (n, i))
rd = byname.get(want_names["render-diff"]) or {}
ok() if "github.event_name == 'pull_request'" in str(rd.get("if", "")) else bad("W2: render-diff lost its pull_request condition")

# W3
always = ["bash -n every script", "shellcheck (errors only)", "tests/ sourcing lint",
          "model-id literal lint (BH-1510)", "fast always-lints (BH-3860)",
          "share-mirror leakcheck pre-check (BH-3860)",
          "triage-gate decides RUN/SKIP shapes correctly",
          "merge-sweep refuses without record evidence"]
for n in always:
    s = byname.get(n)
    if s is None:
        bad("W3: no lint step named %r" % n); continue
    ok() if "steps.reuse" not in str(s.get("if", "")) else bad("W3: always step %r is gated on steps.reuse" % n)

# W4
perm = lint.get("permissions")
ok() if perm == {"contents": "read", "actions": "read", "packages": "read"} else bad("W4: jobs.lint.permissions is %r" % perm)

print("ci-merge-reuse-wiring (BH-5357): %d passed, %d failed" % (P, F))
sys.exit(1 if F else 0)
PY
