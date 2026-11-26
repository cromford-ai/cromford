#!/bin/bash
# tests/ci-each-check-once.bh-10006-test.sh — BH-10006: each check runs once,
# on the tree and the event where its result is read.
#
#   E1  the `Test determinism lint` job keeps its name, has no job `if:`, and
#       checks out with fetch-depth 2. Its step, run for real with a stub lint:
#       on a merge-queue batch, a push and a dispatch it does not call the lint
#       and exits 0; on an ordinary PR it calls the lint once with
#       `--warn-only --changed HEAD^1` and prints each `(fail)` finding as a ::warning:: line.
#   E2  the two report steps of the lint job (`what this PR changes about the
#       files a box installs`, `PR body sections`) are true on an ordinary PR
#       and false on a merge-queue batch, evaluated by bin/ci-local-plan.py's
#       expression evaluator. Every other lint step `if` is unchanged by this
#       ticket (they carry no merge-queue exclusion).
#   E3  publish-cromford.yml has no push trigger, keeps workflow_dispatch, and
#       has four daily cron lines.
#   E4  tests/tracker-direct-calls-ratchet.bh-7919-test.sh is in the always set
#       (catalog/test-impact-always.txt), so every batch, every builder gate
#       and the PR fast-lints run it; no regression row for it.
# Mutations (each turns this suite red): drop the `push:*` arm of the case
# (E1 push calls the lint); drop `--changed HEAD^1` (E1 argv); drop the
# startsWith clause from either report step (E2); put `push:` back in
# publish-cromford.yml (E3); delete the always line (E4).
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/ci-each-check-once.bh-10006-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
WF="${EC_WORKFLOW:-$DIR/.github/workflows/harness-ci.yml}"
PUB="${EC_PUBLISH:-$DIR/.github/workflows/publish-cromford.yml}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ -n "${CI:-}" ] && { echo "FAIL: PyYAML missing on a CI runner"; exit 1; }
  echo "ci-each-check-once: PyYAML missing — skipping on this dev machine"; exit 0
fi

# ── E1. the determinism job and its step, run for real ───────────────────────
python3 - "$WF" "$T/det-run.sh" "$T/det-meta.txt" <<'PY'
import sys, yaml
wf, out, meta = sys.argv[1:4]
j = (yaml.safe_load(open(wf)).get("jobs") or {}).get("determinism") or {}
steps = j.get("steps") or []
co = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout")]
run = [s for s in steps if s.get("name") == "no clock or dice in the test suite (warn-only)"]
open(out, "w").write(str(run[0].get("run", "")) if run else "")
open(meta, "w").write("name=%s\nif=%s\ndepth=%s\nenv=%s\n" % (
    j.get("name"), j.get("if", ""),
    ((co[0].get("with") or {}).get("fetch-depth") if co else None),
    sorted((run[0].get("env") or {}).keys()) if run else []))
PY
grep -qx 'name=Test determinism lint' "$T/det-meta.txt" && ok || bad "E1 the job must keep the required name 'Test determinism lint': $(head -1 "$T/det-meta.txt")"
grep -qx 'if=' "$T/det-meta.txt" && ok || bad "E1 the job must have no job-level if: $(sed -n 2p "$T/det-meta.txt")"
grep -qx 'depth=2' "$T/det-meta.txt" && ok || bad "E1 the checkout must fetch depth 2 (HEAD^1 is the base tip): $(sed -n 3p "$T/det-meta.txt")"
grep -q "DET_EVENT" "$T/det-meta.txt" && grep -q "DET_HEAD_REF" "$T/det-meta.txt" && ok \
  || bad "E1 the step must get the event and head ref through env: $(sed -n 4p "$T/det-meta.txt")"
[ -s "$T/det-run.sh" ] && ok || bad "E1 no 'no clock or dice in the test suite (warn-only)' step with a run body"

mkdir -p "$T/wd/bin"
cat > "$T/wd/bin/test-determinism-lint.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_CALLS"
printf '%s\n' '── determinism findings (fail) ──' 'tests/x-test.sh:3: clock-date-cmd: date -u'
# --warn-only reports and exits 0, as bin/test-determinism-lint.sh does.
exit 0
STUB
chmod +x "$T/wd/bin/test-determinism-lint.sh"
det() {  # det <event> <head_ref> -> rc; output in $T/det.out, calls in $T/calls
  : > "$T/calls"
  ( cd "$T/wd" && STUB_CALLS="$T/calls" DET_EVENT="$1" DET_HEAD_REF="$2" bash -e "$T/det-run.sh" ) > "$T/det.out" 2>&1
}
for ev in "pull_request mergify/merge-queue/abc123" "push -" "workflow_dispatch -"; do
  set -- $ev; hr="$2"; [ "$hr" = - ] && hr=""
  det "$1" "$hr"; rc=$?
  [ "$rc" = 0 ] && [ ! -s "$T/calls" ] && ok \
    || bad "E1 on '$1 ${hr}' the step must exit 0 and not call the lint (rc=$rc, calls: $(cat "$T/calls"))"
done
det pull_request ticket/bh-1-x; rc=$?
[ "$rc" = 0 ] && ok || bad "E1 on an ordinary PR the warn-only step must exit 0 (rc=$rc): $(cat "$T/det.out")"
[ "$(cat "$T/calls")" = "--warn-only --changed HEAD^1" ] && ok \
  || bad "E1 on an ordinary PR the lint must run once with '--warn-only --changed HEAD^1', got: $(cat "$T/calls")"
grep -q '^::warning::determinism (strict in the nightly run): tests/x-test.sh:3: ' "$T/det.out" && ok \
  || bad "E1 a (fail) finding must become a ::warning:: line: $(cat "$T/det.out")"

# ── E2. the report steps skip a merge-queue batch ───────────────────────────
python3 - "$WF" "$DIR/bin/ci-local-plan.py" > "$T/e2.out" 2>&1 <<'PY'
import importlib.util, sys, yaml
wf, plan = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("clp", plan)
clp = importlib.util.module_from_spec(spec); spec.loader.exec_module(clp)
steps = ((yaml.safe_load(open(wf)).get("jobs") or {}).get("lint") or {}).get("steps") or []
by = {s.get("name"): s for s in steps}
want = ["what this PR changes about the files a box installs", "PR body sections (BH-5790, report only)"]
def ev(cond, head):
    return clp.eval_if(cond, clp.Ctx({"event_name": "pull_request", "base_ref": "main", "head_ref": head}, "Harness CI"))
for n in want:
    s = by.get(n)
    if not s:
        print("BAD missing step %r" % n); continue
    c = s.get("if", "")
    print("OK" if ev(c, "ticket/bh-1-x") else "BAD %r is false on an ordinary PR: %r" % (n, c))
    print("OK" if not ev(c, "mergify/merge-queue/abc") else "BAD %r is true on a merge-queue batch: %r" % (n, c))
for n, s in by.items():
    if n not in want and "mergify/merge-queue/" in str(s.get("if", "")):
        print("BAD lint step %r also skips a batch; only the two report steps may" % n)
PY
while IFS= read -r l; do
  case "$l" in OK) ok ;; *) bad "E2 $l" ;; esac
done < "$T/e2.out"
grep -q . "$T/e2.out" || bad "E2 the evaluator printed nothing"

# ── E3. publish-cromford runs on a schedule and on dispatch ─────────────────
python3 - "$PUB" > "$T/e3.out" 2>&1 <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get("on", d.get(True)) or {}
print("OK" if "push" not in on else "BAD the push trigger is back: %r" % on.get("push"))
print("OK" if "workflow_dispatch" in on else "BAD no workflow_dispatch")
crons = [c.get("cron") for c in (on.get("schedule") or [])]
print("OK" if len(crons) == 4 else "BAD want 4 cron lines, got %r" % crons)
PY
while IFS= read -r l; do
  case "$l" in OK) ok ;; *) bad "E3 $l" ;; esac
done < "$T/e3.out"

# ── E4. the tracker R1 ratchet is in the always set ──────────────────────────
R=tests/tracker-direct-calls-ratchet.bh-7919-test.sh
grep -qx "$R" "$DIR/catalog/test-impact-always.txt" && ok || bad "E4 no $R line in catalog/test-impact-always.txt"
out=$(HARNESS_TEST_SANDBOX=1 "$DIR/bin/test-impact.sh" always-why 2>/dev/null)
grep -q "^$R	catalog/test-impact-always.txt$" <<<"$out" && ok || bad "E4 test-impact always-why must list $R from the catalog: $(grep tracker <<<"$out")"
[ ! -e "$DIR/catalog/ci-batch-regression.d/bh-10006.txt" ] && ok || bad "E4 the ratchet is always-run, not a regression row (a bin/ row breaks the batch-plan fixtures)"

echo "ci-each-check-once.bh-10006: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
