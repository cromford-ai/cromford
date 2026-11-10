#!/bin/bash
# tests/nightly-shard-weights.bh-9384-test.sh — BH-9384: the nightly shards
# split by measured time, not by name.
#
# Run 42777389915 (main 806b8883): the nightly plan logged `ci-plan: sizing:
# count, ceil(3220/30) cap 24 (no durations file)`. harness-nightly.yml never
# fetched the shard weights, so suite_shard_plan fell back to equal weights
# (sorted names dealt round-robin). Shard 18 got the 591 s, 465 s and 344 s
# suites together and hit its 60-minute job timeout with every suite at rc=0.
# Harness CI fetches the weights (BH-5518, BH-6876); the nightly now does too.
#
#   N1  the nightly plan job has one `bin/ci-durations.sh fetch` step, after
#       the tier fetch and before the ci-plan step
#   N2  that step's env: CI_WORKFLOW is the literal `Harness CI` (the weights
#       come from Harness CI batches, never ${{ github.workflow }}), GH_TOKEN
#       is github.token, JOBS_URL/CI_DURATIONS_TOKEN from vars./secrets.
#   N3  the plan job's permissions grant actions: read
#   N4  the plan ci-plan CI_PLAN_DURATIONS_FILE == the fetch --out == the
#       nightly-durations upload path
#   N5  the shard downloads nightly-durations (@v4.3.0, no continue-on-error)
#       before a guard with exit 1, before the shard's ci-plan step
#   N6  the shard ci-plan CI_PLAN_DURATIONS_FILE and the trace step's
#       SUITE_DURATIONS_FILE are the downloaded file
#   N7  CI_SHARD_BUDGET_S is set the same on the plan and the shard ci-plan
#   N8  the real suite_shard_filter: no weights stacks the two heavy suites on
#       one shard (the defect); weights separate them; an unnamed suite
#       weighs the median and is still placed
#   N9  the real bin/ci-plan.sh --tier nightly-full sizes by time with an api
#       weights file, by count without one, and by count (rc 0) on
#       `# source: none`
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
TAB=$'\t'
export HARNESS="$T/empty"

# ── N1-N7: the workflow wiring (YAML; no runner here executes Actions).
if python3 -c 'import yaml' 2>/dev/null; then
  WOUT=$(python3 - "$DIR/.github/workflows/harness-nightly.yml" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
jobs = wf.get("jobs") or {}
def steps(j): return (jobs.get(j) or {}).get("steps") or []
def res(tag, cond, msg): print(("PASS: " if cond else "FAIL: ") + tag + " " + msg)
def idx(j, pred): return [i for i, s in enumerate(steps(j)) if pred(s)]
def run_has(t): return lambda s: t in str(s.get("run", ""))
def art(kind, name): return lambda s: str(s.get("uses", "")).startswith(f"actions/{kind}-artifact@") and (s.get("with") or {}).get("name") == name
def env(j, i): return (steps(j)[i].get("env") or {}) if i is not None else {}
def one(l): return l[0] if len(l) == 1 else None

# N1
fe = idx("plan", run_has("bin/ci-durations.sh fetch"))
tf = one(idx("plan", run_has("bin/ci-test-tiers.sh fetch")))
pp = one(idx("plan", run_has("bin/ci-plan.sh")))
f = one(fe)
res("N1", len(fe) == 1, f"the nightly plan has one ci-durations fetch step ({len(fe)})")
res("N1", None not in (f, tf, pp) and tf < f < pp, f"tier fetch ({tf}) < weights fetch ({f}) < ci-plan ({pp})")
# N2
fenv = env("plan", f)
res("N2", fenv.get("CI_WORKFLOW") == "Harness CI", f"CI_WORKFLOW is the literal Harness CI: {fenv.get('CI_WORKFLOW')!r}")
res("N2", "github.workflow" not in str(fenv.get("CI_WORKFLOW")), "CI_WORKFLOW is not ${{ github.workflow }} (the nightly writes no ci-durations-next)")
res("N2", fenv.get("GH_TOKEN") == "${{ github.token }}", f"GH_TOKEN is the job token: {fenv.get('GH_TOKEN')!r}")
res("N2", fenv.get("CI_REPO") == "${{ github.repository }}", f"CI_REPO: {fenv.get('CI_REPO')!r}")
res("N2", fenv.get("JOBS_URL") == "${{ vars.JOBS_URL }}" and fenv.get("CI_DURATIONS_TOKEN") == "${{ secrets.CI_DURATIONS_TOKEN }}",
    f"JOBS_URL/CI_DURATIONS_TOKEN from vars./secrets.: {sorted(fenv)!r}")
# N3
perm = (jobs.get("plan") or {}).get("permissions") or {}
res("N3", perm.get("actions") == "read" and perm.get("contents") == "read", f"the plan job permissions: {perm!r}")
# N4
fout = str(steps("plan")[f].get("run", "")) if f is not None else ""
P = "${{ runner.temp }}/durations/ci-durations.tsv"
res("N4", '--out "$RUNNER_TEMP/durations/ci-durations.tsv"' in fout, f"the fetch writes runner.temp/durations: {fout!r}")
res("N4", env("plan", pp).get("CI_PLAN_DURATIONS_FILE") == P, f"plan ci-plan CI_PLAN_DURATIONS_FILE: {env('plan', pp).get('CI_PLAN_DURATIONS_FILE')!r}")
up = one(idx("plan", art("upload", "nightly-durations")))
uw = (steps("plan")[up].get("with") or {}) if up is not None else {}
res("N4", up is not None and uw.get("path") == P and int(uw.get("retention-days", 0)) == 3, f"one nightly-durations upload of that file: {uw!r}")
res("N4", None not in (up, f) and f < up, f"the upload ({up}) is after the fetch ({f})")
# N5
dl = one(idx("shard", art("download", "nightly-durations")))
dls = steps("shard")[dl] if dl is not None else {}
g = one(idx("shard", run_has("::error::no shard weights from the plan job")))
sp = one(idx("shard", run_has("bin/ci-plan.sh")))
res("N5", dl is not None and str(dls.get("uses")) == "actions/download-artifact@v4.3.0" and "continue-on-error" not in dls,
    f"one pinned nightly-durations download, no continue-on-error: {dls.get('uses')!r}")
res("N5", g is not None and "exit 1" in str(steps("shard")[g].get("run", "")) and "durations/ci-durations.tsv" in str(steps("shard")[g].get("run", "")),
    "a guard fails the shard when the weights file is missing")
res("N5", None not in (dl, g, sp) and dl < g < sp, f"download ({dl}) < guard ({g}) < ci-plan ({sp})")
# N6
D = ((dls.get("with") or {}).get("path") or "") + "/ci-durations.tsv"
tr = one(idx("shard", run_has("bin/test-trace-safety.sh")))
res("N6", D == P, f"the download lands where the plan wrote it: {D!r}")
res("N6", env("shard", sp).get("CI_PLAN_DURATIONS_FILE") == D, f"shard ci-plan CI_PLAN_DURATIONS_FILE: {env('shard', sp).get('CI_PLAN_DURATIONS_FILE')!r}")
res("N6", env("shard", tr).get("SUITE_DURATIONS_FILE") == D, f"trace step SUITE_DURATIONS_FILE: {env('shard', tr).get('SUITE_DURATIONS_FILE')!r}")
# N7
pb, sb = env("plan", pp).get("CI_SHARD_BUDGET_S"), env("shard", sp).get("CI_SHARD_BUDGET_S")
res("N7", pb is not None and pb == sb == "${{ vars.CI_SHARD_BUDGET_S }}", f"CI_SHARD_BUDGET_S plan={pb!r} shard={sb!r}")
PY
  ); echo "$WOUT"
  PASS=$((PASS + $(grep -c '^PASS:' <<<"$WOUT"))); FAIL=$((FAIL + $(grep -c '^FAIL:' <<<"$WOUT")))
  grep -q '^PASS: N\|^FAIL: N' <<<"$WOUT" || bad "N1-N7 the workflow checks did not run"
else
  [ -n "${CI:-}" ] && bad "N1-N7 PyYAML missing on a CI runner" || echo "SKIP: N1-N7 (no PyYAML on this machine)"
fi

# ── N8: the split, through the real suite-runner.
# shellcheck source=../bin/lib/suite-runner.sh
. "$DIR/bin/lib/suite-runner.sh" || { bad "N8 cannot source bin/lib/suite-runner.sh"; echo "nightly-shard-weights.bh-9384: $PASS passed, $FAIL failed"; exit 1; }
S=(tests/a-test.sh tests/b-test.sh tests/c-test.sh tests/d-test.sh)
W="$T/weights.tsv"
printf '# source: api\ntests/a-test.sh\t600\ntests/b-test.sh\t1\ntests/c-test.sh\t600\ntests/d-test.sh\t1\n' > "$W"
same_shard() { # same_shard <file> <x> <y> — rc 0 when x and y land on one shard of 2
  local s0 s1
  s0=$(SUITE_DURATIONS_FILE="$1" suite_shard_plan 2 "${S[@]}" | awk -F'\t' -v x="$2" '$3 == x { print $1 }')
  s1=$(SUITE_DURATIONS_FILE="$1" suite_shard_plan 2 "${S[@]}" | awk -F'\t' -v x="$3" '$3 == x { print $1 }')
  [ -n "$s0" ] && [ "$s0" = "$s1" ]
}
F0=$(SUITE_DURATIONS_FILE=/dev/null suite_shard_filter 0 2 "${S[@]}" | tr '\n' ' ')
{ has tests/a-test.sh "$F0" && has tests/c-test.sh "$F0"; } \
  && ok "N8a no weights (the old nightly): a and c both on shard 0 [$F0]" \
  || bad "N8a the defect does not reproduce: shard 0 = [$F0]"
same_shard "$W" tests/a-test.sh tests/c-test.sh \
  && bad "N8b with weights a and c still share a shard" \
  || ok "N8b with weights the two 600 s suites land on different shards"
printf '# source: api\ntests/a-test.sh\t600\ntests/c-test.sh\t600\ntests/d-test.sh\t1\n' > "$T/partial.tsv"
PL=$(SUITE_DURATIONS_FILE="$T/partial.tsv" suite_shard_plan 2 "${S[@]}")
BW=$(awk -F'\t' '$3 == "tests/b-test.sh" { print $2 }' <<<"$PL")
{ [ "$(grep -c . <<<"$PL")" = 4 ] && [ "$BW" = 600000 ]; } \
  && ok "N8c an unnamed suite weighs the median (600 s) and is placed" \
  || bad "N8c b weight=[$BW] plan=[$PL]"

# ── N9: the real bin/ci-plan.sh --tier nightly-full over a fixture repo.
R="$T/repo"
mkdir -p "$R/bin" "$R/tests" "$R/catalog"
for s in bin/ci-plan.sh bin/test-impact.sh bin/test-tiers.sh; do
  scratch_install_closure "$s" "$R" > /dev/null || { bad "N9 cannot install $s"; break; }
done
for x in a b c d; do printf '#!/bin/bash\necho ok\n' > "$R/tests/$x-test.sh"; done
printf '# fixture tiers\n' > "$R/catalog/test-tiers.tsv"
git -C "$R" init -q
git -C "$R" -c user.email=t@example.com -c user.name=t add -A
GIT_AUTHOR_DATE="@1790000000 +0000" GIT_COMMITTER_DATE="@1790000000 +0000" \
  git -C "$R" -c user.email=t@example.com -c user.name=t commit -qm base
nplan() { # nplan [VAR=val ...] — sets NRC NOUT
  NOUT=$(cd "$R" && env -u GITHUB_ACTIONS -u CI_PLAN_DURATIONS_FILE -u CI_SHARD_BUDGET_S CI_EVENT=schedule CI_QUARANTINE= \
           GITHUB_OUTPUT="$T/ngo" "$@" bin/ci-plan.sh --tier nightly-full --out "$T/nlist" 2>&1); NRC=$?
}
nplan CI_PLAN_DURATIONS_FILE="$W"
{ [ "$NRC" = 0 ] && has 'sizing: time (api)' "$NOUT"; } && ok "N9 an api weights file sizes by time" || bad "N9 api: rc=$NRC [$NOUT]"
nplan
{ [ "$NRC" = 0 ] && has 'sizing: count' "$NOUT"; } && ok "N9 no weights file sizes by count" || bad "N9 none set: rc=$NRC [$NOUT]"
printf '# source: none\n' > "$T/none.tsv"
nplan CI_PLAN_DURATIONS_FILE="$T/none.tsv"
{ [ "$NRC" = 0 ] && has 'sizing: count' "$NOUT"; } && ok "N9 a '# source: none' file sizes by count, rc 0" || bad "N9 source none: rc=$NRC [$NOUT]"

echo "nightly-shard-weights.bh-9384: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
