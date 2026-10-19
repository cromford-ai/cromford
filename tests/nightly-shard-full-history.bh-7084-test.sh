#!/bin/bash
# tests/nightly-shard-full-history.bh-7084-test.sh — the nightly shard checkout
# keeps full git history (BH-7084).
#
# BH-6838 moved tests/ci-durations-db.bh-5653-test.sh to the nightly tier. That
# suite reads its seed as the parent of the commit that deleted
# catalog/ci-suite-durations.tsv (BH-5518). The nightly shard checkout had no
# fetch-depth, so actions/checkout cloned at depth 1, the deleting commit was
# not in the clone, and the suite failed every night with "no seed in git
# history (0 rows)". harness-ci.yml tests-shard has always used depth 0.
#   H1  every checkout in jobs.shard has fetch-depth 0 and persist-credentials false
#   H2  the harness-ci.yml tests-shard checkout has fetch-depth 0 (the premise)
#   H3  four mutated workflows fail the H1 checker
#   H4  a quoted "0" passes the H1 checker
#   H5  a local depth-1 clone loses the deleting commit; a full clone keeps it
# Run from anywhere: tests/nightly-shard-full-history.bh-7084-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NWF="${NIGHTLY_WORKFLOW:-$DIR/.github/workflows/harness-nightly.yml}"
CIWF="$DIR/.github/workflows/harness-ci.yml"
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ -n "${CI:-}" ] && { echo "FAIL: PyYAML missing on a CI runner"; exit 1; }
  echo "nightly-shard-full-history.bh-7084: PyYAML missing — skipping on this dev machine"; exit 0
fi
T="$SCRATCH"

P=0; F=0
pass() { P=$((P+1)); }
fail() { F=$((F+1)); echo "FAIL: $1"; }

# check_full_history <workflow> <job> [creds]: rc 0 when every actions/checkout
# step of <job> has fetch-depth 0 (int or "0"), and, with creds, also
# persist-credentials false. rc 1 otherwise, rc 2 when the job has no checkout.
check_full_history() {
  python3 - "$1" "$2" "${3:-}" <<'PY'
import sys, yaml
path, job, creds = sys.argv[1:4]
steps = ((yaml.safe_load(open(path)).get("jobs") or {}).get(job) or {}).get("steps") or []
co = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout")]
if not co:
    print(f"{job}: no actions/checkout step"); sys.exit(2)
for s in co:
    w = s.get("with") or {}
    if str(w.get("fetch-depth")) != "0":
        print(f"{job}: fetch-depth is {w.get('fetch-depth')!r}, not 0"); sys.exit(1)
    if creds and w.get("persist-credentials") is not False:
        print(f"{job}: persist-credentials is {w.get('persist-credentials')!r}, not false"); sys.exit(1)
PY
}

# H1
if out=$(check_full_history "$NWF" shard creds); then pass
else fail "H1: the nightly shard checkout is not full history with no credentials: $out"; fi

# H2
if out=$(check_full_history "$CIWF" tests-shard); then pass
else fail "H2: harness-ci.yml tests-shard is no longer depth 0 — the premise of this suite moved: $out"; fi

# H3 / H4: variants of the real workflow, each edit asserted to have applied.
python3 - "$NWF" "$T" <<'PY' || fail "H3: could not write the mutated workflows"
import sys, yaml
src, out = sys.argv[1:3]
def variant(name, edit):
    wf = yaml.safe_load(open(src))
    for job in wf["jobs"].values():
        for s in job.get("steps") or []:
            if str(s.get("uses", "")).startswith("actions/checkout"):
                s.setdefault("with", {})
    edit(wf)
    yaml.safe_dump(wf, open(f"{out}/{name}.yml", "w"), sort_keys=False)
def shard_co(wf):
    return [s for s in wf["jobs"]["shard"]["steps"] if str(s.get("uses", "")).startswith("actions/checkout")]
def a(wf):
    for s in shard_co(wf): s["with"].pop("fetch-depth", None)
def b(wf):
    for s in shard_co(wf): s["with"]["fetch-depth"] = 1
def c(wf):
    a(wf)
    for s in wf["jobs"]["plan"]["steps"]:
        if str(s.get("uses", "")).startswith("actions/checkout"): s["with"]["fetch-depth"] = 0
def d(wf):
    for s in shard_co(wf):
        s["with"]["fetch-depth"] = 0; s["with"].pop("persist-credentials", None)
def q(wf):
    for s in shard_co(wf): s["with"]["fetch-depth"] = "0"
for n, e in (("a-no-key", a), ("b-depth-1", b), ("c-plan-only", c), ("d-no-creds", d), ("h4-quoted", q)):
    variant(n, e)
PY
for v in a-no-key b-depth-1 c-plan-only d-no-creds; do
  if [ ! -s "$T/$v.yml" ]; then fail "H3($v): variant not written"; continue; fi
  if check_full_history "$T/$v.yml" shard creds >/dev/null; then fail "H3($v): the checker passed a shallow or credentialed shard checkout"
  else pass; fi
done
# H3(c) must still be depth 0 on the plan job, or it tests nothing new.
check_full_history "$T/c-plan-only.yml" plan >/dev/null && pass || fail "H3(c): the plan-only variant did not set plan depth 0"
grep -q "fetch-depth: '0'" "$T/h4-quoted.yml" && pass || fail "H4: the quoted variant was not written as a string"
if out=$(check_full_history "$T/h4-quoted.yml" shard creds); then pass
else fail "H4: a quoted \"0\" must pass (actions/checkout reads it as 0): $out"; fi

# H5: a depth-1 clone has no deleting commit for the seed file; a full clone has it.
R="$T/origin"
mkdir -p "$R/catalog"
g() { git -C "$R" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@" >/dev/null 2>&1; }
git init -q "$R" 2>/dev/null
printf 'suite\tseconds\n' > "$R/catalog/ci-suite-durations.tsv"
g add -A; g commit -q -m seed
g rm -q catalog/ci-suite-durations.tsv; g commit -q -m delete
del=$(git -C "$R" rev-parse HEAD)
echo x > "$R/after"; g add -A; g commit -q -m after
git clone -q --depth 1 "file://$R" "$T/shallow" 2>/dev/null || fail "H5: depth-1 clone failed"
git clone -q "file://$R" "$T/full" 2>/dev/null || fail "H5: full clone failed"
s=$(git -C "$T/shallow" log -1 --format=%H --diff-filter=D -- catalog/ci-suite-durations.tsv 2>/dev/null)
f=$(git -C "$T/full" log -1 --format=%H --diff-filter=D -- catalog/ci-suite-durations.tsv 2>/dev/null)
[ -z "$s" ] && pass || fail "H5: a depth-1 clone still found the deleting commit ($s) — the premise moved"
[ "$f" = "$del" ] && pass || fail "H5: a full clone did not find the deleting commit (got '$f', want $del)"

echo "nightly-shard-full-history.bh-7084: $P passed, $F failed"
[ "$F" -eq 0 ]
