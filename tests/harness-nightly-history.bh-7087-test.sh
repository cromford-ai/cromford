#!/bin/bash
# tests/harness-nightly-history.bh-7087-test.sh — the nightly shard checks out
# full git history (BH-7087).
#
# WHY. Some suites read git history: B1 of schema-compose-deploy.bh-6005-0
# finds the commit that deleted worker/jobs/schema.sql (443cac1bd, BH-6011).
# The nightly `shard` job checked out at depth 1, the actions/checkout default,
# so B1 was red every night while the merge-queue tests-shard (fetch-depth 0)
# ran it green. This suite pins the checkout shape:
#   N1  jobs.shard's actions/checkout step has with.fetch-depth == integer 0
#   N2  the same step keeps persist-credentials: false (BH-6514)
#   N3  the N1 checker refuses fixtures: no fetch-depth, fetch-depth 1, "0" as a
#       string, fetch-depth 0 only on another job, a shard with no checkout;
#       and accepts fetch-depth 0
#   N4  end to end: on a depth-1 clone of this repo B1 prints its FAIL line,
#       and after --unshallow it does not (history depth alone decides B1)
# Run from anywhere: tests/harness-nightly-history.bh-7087-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NWF="${NIGHTLY_WORKFLOW:-$DIR/.github/workflows/harness-nightly.yml}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ -n "${CI:-}" ] && { echo "FAIL: PyYAML missing on a CI runner"; exit 1; }
  echo "harness-nightly-history.bh-7087-test: PyYAML missing — skipping on this dev machine"; exit 0
fi

# check <workflow> <key>: rc 0 when jobs.shard's checkout step satisfies <key>
# (depth: fetch-depth is integer 0; creds: persist-credentials is false).
check() {
  python3 - "$1" "$2" <<'PY'
import sys, yaml
path, key = sys.argv[1:3]
# GitHub Actions refuses a duplicate mapping key; safe_load keeps the last one
# silently. Reject it here so this suite fails on a file Actions would not run.
class Strict(yaml.SafeLoader):
    def construct_mapping(self, node, deep=False):
        seen = set()
        for k, _ in node.value:
            name = self.construct_object(k, deep=True)
            if name in seen:
                print("duplicate key %r at line %d" % (name, k.start_mark.line + 1)); sys.exit(1)
            seen.add(name)
        return super().construct_mapping(node, deep)
wf = yaml.load(open(path), Loader=Strict) or {}
steps = ((wf.get("jobs") or {}).get("shard") or {}).get("steps") or []
co = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout")]
if not co:
    print("jobs.shard has no actions/checkout step"); sys.exit(1)
w = co[0].get("with") or {}
if key == "depth":
    v = w.get("fetch-depth")
    if isinstance(v, bool) or not isinstance(v, int) or v != 0:
        print("jobs.shard checkout fetch-depth is %r, want integer 0" % (v,)); sys.exit(1)
elif key == "creds":
    if w.get("persist-credentials") is not False:
        print("jobs.shard checkout persist-credentials is %r, want false" % (w.get("persist-credentials"),)); sys.exit(1)
PY
}

# N1, N2: the real workflow.
if m=$(check "$NWF" depth); then ok; else bad "N1: $m"; fi
if m=$(check "$NWF" creds); then ok; else bad "N2: $m"; fi

# N3: the checker over fixtures. fx <name> <shard-with-lines> <lint-with-lines>
fx() {
  printf 'on: {schedule: [{cron: "0 3 * * *"}]}\njobs:\n  lint:\n    runs-on: x\n    steps:\n      - uses: actions/checkout@v4\n        with:\n          persist-credentials: false\n%b  shard:\n    runs-on: x\n    steps:\n%b      - run: true\n' "$3" "$2" > "$T/$1.yml"
}
CO='      - uses: actions/checkout@v4\n        with:\n          persist-credentials: false\n'
fx none    "$CO" ""
fx one     "${CO}          fetch-depth: 1\n" ""
fx string  "${CO}          fetch-depth: \"0\"\n" ""
fx other   "$CO" "          fetch-depth: 0\n"
fx nostep  "" ""
fx zero    "${CO}          fetch-depth: 0\n" ""
fx dup     "${CO}          fetch-depth: 0\n          fetch-depth: 0\n" ""
for f in none one string other nostep dup; do
  if check "$T/$f.yml" depth >/dev/null; then bad "N3: fixture '$f' passed the fetch-depth checker"; else ok; fi
done
if m=$(check "$T/zero.yml" depth); then ok; else bad "N3: fixture 'zero' failed the checker: $m"; fi

# N4: depth decides B1, end to end on a clone of this repo.
B1LINE='FAIL: B1: no commit in this repo tracks worker/jobs/schema.sql'
if [ -z "$(git -C "$DIR" log -1 --diff-filter=D --format=%H -- worker/jobs/schema.sql 2>/dev/null)" ]; then
  echo "skip: N4 source repo has no schema.sql deletion commit"
elif ! git clone -q --no-local --depth 1 "file://$DIR" "$T/shallow" 2>"$T/clone.err"; then
  bad "N4: depth-1 clone failed: $(head -c 300 "$T/clone.err")"
else
  out=$(HARNESS_TEST_SANDBOX=1 bash "$T/shallow/tests/schema-compose-deploy.bh-6005-0-test.sh" 2>&1)
  if grep -qF "$B1LINE" <<<"$out"; then ok; else bad "N4: depth-1 clone did not print the B1 FAIL line"; fi
  if ! git -C "$T/shallow" fetch -q --unshallow 2>"$T/fetch.err"; then
    bad "N4: --unshallow failed: $(head -c 300 "$T/fetch.err")"
  else
    out=$(HARNESS_TEST_SANDBOX=1 bash "$T/shallow/tests/schema-compose-deploy.bh-6005-0-test.sh" 2>&1)
    if grep -qF "$B1LINE" <<<"$out"; then bad "N4: B1 still fails on the unshallowed clone"; else ok; fi
  fi
fi

echo "harness-nightly-history.bh-7087-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
