#!/bin/bash
# tests/ci-plan-nightly-split.bh-6838-test.sh — BH-6838: a merge blocks only on
# the factory checks and the suites the change reaches, plus the committed
# batch-fail regression list; the full corpus and the test-hygiene lints run
# nightly on main.
#
#   G1  select --why prints a regression row's suite with kind `regression`
#   G2  the builder gate (--runner plan, cap 80, 85 always suites) runs the
#       regression suite; it is not left to CI by the cap
#   G3  an unreadable regression fragment: select answers full with a reason
#   A1  a batch of one bin/ file plans reach + always + regression,
#       mode=batch-selected
#   A2  that batch has no day-boundary guard (the real catalog/test-tiers.tsv
#       puts it in the nightly tier); the fixture-hygiene suite it reaches is in
#       the batch (a leak check, not a nightly row)
#   A3  a .github/ action change plans full (a top-level workflow file selects
#       its readers since BH-6876); the `full` label plans full
#   A3b a non-global tests/lib/ helper change plans reach + always, not full
#   A4  every row of the real catalog/ci-batch-regression.d/ names an existing
#       suite and at least one existing path
#   A5  a regression suite with a nightly tier row is in the batch; a
#       quarantined one is not
#   A6  --tier nightly-full: every suite, mode=nightly-full, reuse off; an
#       empty corpus is rc 2
#   D1  CI_FULL_TRIGGERS unset, empty and `-` plan byte-identical output
#   D2  `+bin/foo.sh` escalates; `-.mergify.yml` selects
#   D3  `-bin/ci-plan.sh` is refused and the batch stays full; `+a..b` is ignored
#   D3b `-tests/lib/scratch.sh` and `-bin/lib/suite-runner.sh` are refused
#   D4  full_triggers is in GITHUB_OUTPUT; a shard given it agrees on --expect-n
#   W1-W5  the two workflows (see the W block)
#   NR  a nightly red writes ticket request rows and exits 0
#
# The real bin/ci-plan.sh, bin/test-impact.sh, bin/test-impact-gate.sh and
# bin/test-tiers.sh drive every case, over a small fixture repo.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
command -v git >/dev/null || { echo "ci-plan-nightly-split: git is required"; exit 2; }
TAB=$'\t'
export GIT_AUTHOR_DATE="@1790000000 +0000" GIT_COMMITTER_DATE="@1790000000 +0000"
# No live harness answers for a gate run here: a box setting would move the cap.
export HARNESS="$T/empty"

# ── the fixture repo ─────────────────────────────────────────────────────────
R="$T/repo"
mkdir -p "$R/bin" "$R/tests/lib" "$R/catalog/ci-batch-regression.d" "$R/worker/jobs/test/route-table.d" "$R/.github/workflows"
for s in bin/ci-plan.sh bin/test-impact.sh bin/test-impact-gate.sh bin/test-tiers.sh bin/test-impact-workflow.sh; do
  scratch_install_closure "$s" "$R" > /dev/null || { echo "FAIL: cannot install $s"; exit 1; }
done
cp "$DIR/catalog/ci-batch-escalate.tsv" "$R/catalog/"
printf '#!/bin/bash\necho widget\n' > "$R/bin/widget.sh"
printf '#!/bin/bash\necho foo\n' > "$R/bin/foo.sh"
printf 'GET /api/a\n' > "$R/worker/jobs/test/route-table.d/a.txt"
printf 'queue_rules: []\n' > "$R/.mergify.yml"
printf 'name: Harness CI\non: [pull_request]\njobs:\n  tests:\n    runs-on: x\n    steps:\n      - run: echo t\n' > "$R/.github/workflows/harness-ci.yml"
printf 'helper_fn() { :; }\n' > "$R/tests/lib/helper.sh"
suite() { # suite <name> <body line>
  printf '#!/bin/bash\nDIR=$(cd "$(dirname "$0")/.." && pwd)\n%s\necho ok\n' "$2" > "$R/tests/$1"
}
suite widget-test.sh 'bash "$DIR/bin/widget.sh"'
suite foo-test.sh 'bash "$DIR/bin/foo.sh"'
suite mergify-test.sh 'grep -q queue "$DIR/.mergify.yml"'
suite helper-test.sh '. "$DIR/tests/lib/helper.sh"'
suite route-keyed-merge.bh-5788-test.sh 'cp -R "$DIR/worker/jobs/test/route-table.d" "$TMPDIR/x"'
suite reg-test.sh 'true'
suite reg-night-test.sh 'true'
suite reg-quar-test.sh 'true'
suite star-test.sh 'true'
suite always-test.sh 'true'
# The day-boundary guard moves to nightly; the fixture-hygiene suite does not.
# Both reach bin/widget.sh.
suite day-boundary-guard.bh-6052-test.sh 'bash "$DIR/bin/widget.sh"'
suite fixture-hygiene.bh-5789-test.sh 'bash "$DIR/bin/widget.sh"'
printf 'tests/always-test.sh\n' > "$R/catalog/test-impact-always.txt"
printf '# fixture: nothing protected\n' > "$R/catalog/test-quarantine-protected.txt"
cat > "$R/catalog/ci-batch-regression.d/bh-1.txt" <<EOF
# fixture rows
tests/route-keyed-merge.bh-5788-test.sh${TAB}worker/jobs/test/route-table.d/,worker/jobs/scripts/routes-build.mjs
tests/reg-test.sh${TAB}bin/widget.sh
tests/reg-night-test.sh${TAB}bin/wid*.sh
tests/reg-quar-test.sh${TAB}bin/widget.sh
tests/star-test.sh${TAB}*
tests/no-such-suite.sh${TAB}bin/widget.sh
EOF
# The tier rows: the two hygiene suites' rows (if any) are the REAL file's rows (A2).
{ printf '# fixture tiers\n'
  grep -E "^tests/(day-boundary-guard\.bh-6052|fixture-hygiene\.bh-5789)-test\.sh${TAB}" "$DIR/catalog/test-tiers.tsv"
  printf 'tests/reg-night-test.sh\tnightly\t10\t-\tfixture: a regression suite with a nightly row\n'
} > "$R/catalog/test-tiers.tsv"
gitc() { git -C "$R" -c user.email=t@example.com -c user.name=t "$@"; }
gitc init -q; gitc add -A; gitc commit -qm base
BASE=$(git -C "$R" rev-parse HEAD)

# bplan <path>... [-- VAR=val ...] — one batch plan; sets RC OUT ERR GO, list in $T/list
bplan() {
  local paths=() vars=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do paths+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift; vars=("$@")
  printf '%s\n' ${paths[@]+"${paths[@]}"} | grep . > "$T/changed" || : > "$T/changed"
  rm -f "$T/go" "$T/list"
  OUT=$(cd "$R" && env -u GITHUB_ACTIONS -u CI_FULL_TRIGGERS CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$BASE" \
          CI_PLAN_ESCALATION=- TI_PR_LABELS= CI_QUARANTINE= CI_PLAN_CHANGED_FILE="$T/changed" GITHUB_OUTPUT="$T/go" \
          ${vars[@]+"${vars[@]}"} bin/ci-plan.sh --out "$T/list" 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err"); GO=$(cat "$T/go" 2>/dev/null)
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }
inlist() { grep -qxF "$1" "$T/list" 2>/dev/null; }

# ── G1. select --why: the regression kind.
printf 'GET /api/x\n' > "$R/worker/jobs/test/route-table.d/bh-1-x.txt"
printf 'worker/jobs/test/route-table.d/bh-1-x.txt\n' > "$T/g1.changed"
W=$(cd "$R" && bin/test-impact.sh select --why --changed "$T/g1.changed" 2>/dev/null)
grep -qxF "tests/route-keyed-merge.bh-5788-test.sh${TAB}regression${TAB}worker/jobs/test/route-table.d/bh-1-x.txt" <<<"$W" \
  && ok "G1 route-table fragment selects route-keyed-merge as regression" \
  || bad "G1 no regression row for route-keyed-merge: [$W]"
rm -f "$R/worker/jobs/test/route-table.d/bh-1-x.txt"

# ── G2. the gate's cap never leaves a regression suite to CI.
G="$T/gate"; cp -R "$R" "$G"
for i in $(seq -w 1 85); do printf '#!/bin/bash\necho ok\n' > "$G/tests/aw$i-test.sh"; echo "tests/aw$i-test.sh" >> "$G/catalog/test-impact-always.txt"; done
git -C "$G" -c user.email=t@example.com -c user.name=t add -A
git -C "$G" -c user.email=t@example.com -c user.name=t commit -qm always85
GB=$(git -C "$G" rev-parse HEAD)
printf 'GET /api/x\n' > "$G/worker/jobs/test/route-table.d/bh-1-x.txt"
git -C "$G" -c user.email=t@example.com -c user.name=t add -A
git -C "$G" -c user.email=t@example.com -c user.name=t commit -qm frag
GO2=$(cd "$G" && TEST_IMPACT_DURATIONS_FILE="$T/dur.tsv" TEST_IMPACT_GATE_FAST="$T/nofast" bin/test-impact-gate.sh --base "$GB" --runner plan --cap 80 2>&1); GRC=$?
LEFT=$(awk '/left to CI by the cap \(/{f=1;next} /^impact-gate:/{f=0} f' <<<"$GO2")
RUNL=$(awk '/^plan: /' <<<"$GO2")
{ [ "$GRC" = 0 ] && has 'left to CI by the cap: ' "$GO2" && ! has route-keyed-merge "$LEFT" && has tests/route-keyed-merge.bh-5788-test.sh "$RUNL"; } \
  && ok "G2 the gate runs route-keyed-merge ahead of the cap" \
  || bad "G2 rc=$GRC left=[$LEFT] run=[$(grep route-keyed <<<"$RUNL")]"
# The cap really bit: some always suite was left to CI.
grep -q 'tests/aw' <<<"$LEFT" && ok "G2 the cap left always suites to CI" || bad "G2 the cap left nothing to CI, so G2 proves nothing: [$LEFT]"

# ── G3. an unreadable fragment fails the map: the corpus, with a reason.
ln -s "$T/no-such-target" "$R/catalog/ci-batch-regression.d/broken.txt"
SEL=$(cd "$R" && bin/test-impact.sh select --changed "$T/g1.changed" 2>&1 >/dev/null)
has 'full: the map could not be built' "$SEL" && ok "G3 unreadable fragment selects full" || bad "G3 got [$SEL]"
(cd "$R" && bin/test-impact.sh regression > /dev/null 2>&1); [ "$?" = 2 ] && ok "G3 regression verb rc 2 on an unreadable fragment" || bad "G3 regression verb did not fail"
rm -f "$R/catalog/ci-batch-regression.d/broken.txt"

# ── A1/A2/A5. one bin/ file.
bplan bin/widget.sh -- CI_QUARANTINE=tests/reg-quar-test.sh
{ [ "$RC" = 0 ] && [ "$(out mode)" = batch-selected ]; } && ok "A1 mode=batch-selected" || bad "A1 rc=$RC mode=$(out mode) [$OUT] [$ERR]"
inlist tests/widget-test.sh && ok "A1 reach (widget-test)" || bad "A1 no widget-test in [$(cat "$T/list")]"
inlist tests/always-test.sh && ok "A1 always (always-test)" || bad "A1 no always-test"
{ inlist tests/reg-test.sh && inlist tests/star-test.sh; } && ok "A1 regression (reg-test, star-test)" || bad "A1 regression rows missing: [$(cat "$T/list")]"
inlist tests/foo-test.sh && bad "A1 an unreached suite (foo-test) ran" || ok "A1 unreached foo-test not planned"
# reg-test and star-test came in through the map; the union adds back only
# reg-night-test, which the tier step dropped.
has '+1 regression' "$(out summary)" && ok "A1 the summary says +1 regression" || bad "A1 summary [$(out summary)]"
has 'ci-plan: regression tests/reg-night-test.sh (bin/widget.sh)' "$ERR" && ok "A1 one stderr line per add" || bad "A1 stderr [$ERR]"
! inlist tests/day-boundary-guard.bh-6052-test.sh \
  && ok "A2 no day-boundary guard in the batch" || bad "A2 the day-boundary guard is in the batch: [$(cat "$T/list")]"
inlist tests/fixture-hygiene.bh-5789-test.sh \
  && ok "A2 the reached fixture-hygiene suite is in the batch" || bad "A2 the fixture-hygiene suite left the batch: [$(cat "$T/list")]"
A2N=$(grep -cE "^tests/day-boundary-guard\.bh-6052-test\.sh${TAB}nightly${TAB}" "$DIR/catalog/test-tiers.tsv"); [ "$A2N" = 1 ] \
  && ok "A2 the real tier file has the day-boundary nightly row" || bad "A2 catalog/test-tiers.tsv lacks the day-boundary nightly row"
A2F=$(grep -cE "^tests/fixture-hygiene\.bh-5789-test\.sh${TAB}nightly${TAB}" "$DIR/catalog/test-tiers.tsv"); [ "$A2F" = 0 ] \
  && ok "A2 the real tier file has no fixture-hygiene nightly row" || bad "A2 catalog/test-tiers.tsv moves the fixture-hygiene suite to nightly"
inlist tests/reg-night-test.sh && ok "A5 a nightly-tier regression suite still runs in the batch" || bad "A5 reg-night-test dropped"
inlist tests/reg-quar-test.sh && bad "A5 a quarantined regression suite was added" || ok "A5 quarantined reg-quar-test not added"
has 'reg-quar-test.sh (bin/widget.sh) not added: quarantined' "$ERR" && ok "A5 the quarantine skip is said" || bad "A5 stderr [$ERR]"

# ── A3. a CI plumbing change and the full label.
bplan .github/actions/x/action.yml
{ [ "$(out mode)" = full ] && [ "$(out escalation)" = "selection input: .github/actions/x/action.yml" ]; } \
  && ok "A3 a .github/ action change plans full" || bad "A3 mode=$(out mode) escalation=$(out escalation) [$OUT]"
bplan bin/widget.sh -- TI_PR_LABELS=full
{ [ "$(out mode)" = full ] && [ "$(out escalation)" = "the 'full' label" ]; } && ok "A3 the full label plans full" || bad "A3 label: mode=$(out mode) escalation=$(out escalation)"

# ── A3b. a non-global tests/lib/ helper.
bplan tests/lib/helper.sh
{ [ "$(out mode)" = batch-selected ] && inlist tests/helper-test.sh && inlist tests/always-test.sh && [ "$(out count)" -lt "$(out total)" ]; } \
  && ok "A3b a tests/lib/ helper plans reach + always, not full" || bad "A3b mode=$(out mode) count=$(out count) total=$(out total) [$OUT]"

# ── A4. the real regression list names real suites.
A4=0; A4N=0
for f in "$DIR"/catalog/ci-batch-regression.d/*.txt; do
  while IFS=$'\t' read -r s ps; do
    case "$s" in ''|'#'*) continue ;; esac
    A4N=$((A4N + 1))
    [ -f "$DIR/$s" ] || { bad "A4 ${f##*/}: $s is not a suite"; A4=1; continue; }
    hit=0; IFS=',' read -r -a pa <<<"$ps"
    for p in "${pa[@]}"; do
      case "$p" in '*') hit=1 ;; */) [ -d "$DIR/$p" ] && hit=1 ;; *) compgen -G "$DIR/$p" > /dev/null && hit=1 ;; esac
    done
    [ "$hit" = 1 ] || { bad "A4 ${f##*/}: $s names no existing path ($ps)"; A4=1; }
  done < "$f"
done
{ [ "$A4" = 0 ] && [ "$A4N" -ge 1 ]; } && ok "A4 $A4N regression row(s), every one real" || bad "A4 rows=$A4N"
grep -qxF "tests/route-keyed-merge.bh-5788-test.sh${TAB}worker/jobs/test/route-table.d/,worker/jobs/scripts/routes-build.mjs" "$DIR/catalog/ci-batch-regression.d/bh-6838.txt" \
  && ok "A4 the #6830 route-table row is seeded" || bad "A4 the route-table row is missing from bh-6838.txt"

# ── A6. nightly-full.
NOUT=$(cd "$R" && env -u GITHUB_ACTIONS CI_EVENT=schedule CI_QUARANTINE= GITHUB_OUTPUT="$T/ngo" bin/ci-plan.sh --tier nightly-full --out "$T/nlist" 2>&1); NRC=$?
NTOT=$(cd "$R" && ls tests/*.sh | grep -c .)
{ [ "$NRC" = 0 ] && grep -qx 'mode=nightly-full' "$T/ngo" && [ "$(grep -c . "$T/nlist")" = "$NTOT" ]; } \
  && ok "A6 nightly-full plans all $NTOT suites" || bad "A6 rc=$NRC list=$(grep -c . "$T/nlist" 2>/dev/null) of $NTOT [$NOUT]"
has 'reuse: off: nightly never reuses' "$NOUT" && ok "A6 nightly-full never reuses" || bad "A6 reuse line [$NOUT]"
inlist_n() { grep -qxF "$1" "$T/nlist"; }
{ inlist_n tests/day-boundary-guard.bh-6052-test.sh && inlist_n tests/fixture-hygiene.bh-5789-test.sh && inlist_n tests/reg-night-test.sh; } \
  && ok "A6 nightly-full includes every suite, the nightly-tier ones too" || bad "A6 a nightly suite is missing"
E="$T/empty-repo"; mkdir -p "$E/bin" "$E/tests"
for s in bin/ci-plan.sh bin/test-impact.sh bin/test-tiers.sh; do scratch_install_closure "$s" "$E" > /dev/null; done
git -C "$E" init -q; git -C "$E" -c user.email=t@example.com -c user.name=t add -A; git -C "$E" -c user.email=t@example.com -c user.name=t commit -qm e
(cd "$E" && env -u GITHUB_ACTIONS CI_EVENT=schedule bin/ci-plan.sh --tier nightly-full --out "$T/elist" > /dev/null 2>&1); ERC=$?
[ "$ERC" = 2 ] && ok "A6 an empty corpus is rc 2" || bad "A6 empty corpus rc=$ERC"
(cd "$R" && bin/ci-plan.sh --tier nightly-x > /dev/null 2>&1); [ "$?" = 2 ] && ok "A6 an unknown tier is refused" || bad "A6 unknown tier accepted"

# ── D1. unset, empty and `-` are byte-identical.
bplan bin/widget.sh; D1A="$OUT|$GO|$(cat "$T/list")"
bplan bin/widget.sh -- CI_FULL_TRIGGERS=; D1B="$OUT|$GO|$(cat "$T/list")"
bplan bin/widget.sh -- CI_FULL_TRIGGERS=-; D1C="$OUT|$GO|$(cat "$T/list")"
{ [ "$D1A" = "$D1B" ] && [ "$D1A" = "$D1C" ]; } && ok "D1 unset, empty and - plan the same" || bad "D1 differ: [$D1A] [$D1B] [$D1C]"
[ "$(out full_triggers)" = - ] && ok "D1 full_triggers=-" || bad "D1 full_triggers=$(out full_triggers)"

# ── D2. + escalates, - selects.
bplan bin/foo.sh
[ "$(out mode)" = batch-selected ] && ok "D2 bin/foo.sh selects with no delta" || bad "D2 base: mode=$(out mode) [$OUT]"
bplan bin/foo.sh -- 'CI_FULL_TRIGGERS=+bin/foo.sh'
{ [ "$(out mode)" = full ] && [ "$(out escalation)" = "selection input: bin/foo.sh" ]; } && ok "D2 +bin/foo.sh escalates" || bad "D2 + : mode=$(out mode) escalation=$(out escalation)"
bplan .mergify.yml
[ "$(out escalation)" = "selection input: .mergify.yml" ] && ok "D2 .mergify.yml escalates with no delta" || bad "D2 base mergify: $(out escalation)"
bplan .mergify.yml -- 'CI_FULL_TRIGGERS=-.mergify.yml'
{ [ "$(out mode)" = batch-selected ] && inlist tests/mergify-test.sh; } && ok "D2 -.mergify.yml selects" || bad "D2 - : mode=$(out mode) escalation=$(out escalation) [$OUT]"

# ── D3. a self row cannot be removed; `..` is ignored.
bplan bin/ci-plan.sh -- 'CI_FULL_TRIGGERS=-bin/ci-plan.sh +a..b +bin/foo.sh'
{ [ "$(out mode)" = full ] && [ "$(out escalation)" = "selection input: bin/ci-plan.sh" ]; } && ok "D3 -bin/ci-plan.sh is refused, the batch stays full" || bad "D3 mode=$(out mode) escalation=$(out escalation)"
[ "$(out full_triggers)" = "+bin/foo.sh" ] && ok "D3 full_triggers keeps only +bin/foo.sh" || bad "D3 full_triggers=[$(out full_triggers)]"
{ has 'token -bin/ci-plan.sh refused (a self row)' "$ERR" && has 'token +a..b ignored (..)' "$ERR"; } && ok "D3 each dropped token is said" || bad "D3 stderr [$ERR]"
# D3b: the two runner rows are self rows too (lead review note 2).
bplan bin/widget.sh -- 'CI_FULL_TRIGGERS=-tests/lib/scratch.sh -bin/lib/suite-runner.sh'
[ "$(out full_triggers)" = - ] && ok "D3b the runner-row removals are dropped" || bad "D3b full_triggers=[$(out full_triggers)]"
{ has 'token -tests/lib/scratch.sh refused (a self row)' "$ERR" && has 'token -bin/lib/suite-runner.sh refused (a self row)' "$ERR"; } \
  && ok "D3b -tests/lib/scratch.sh and -bin/lib/suite-runner.sh are refused" || bad "D3b stderr [$ERR]"

# ── D4. the shard re-plans from full_triggers.
bplan bin/foo.sh -- 'CI_FULL_TRIGGERS=+bin/foo.sh +a..b'
FT=$(out full_triggers); PN=$(out n)
[ "$FT" = "+bin/foo.sh" ] && ok "D4 full_triggers in GITHUB_OUTPUT" || bad "D4 full_triggers=[$FT]"
bplan bin/foo.sh -- "CI_FULL_TRIGGERS=$FT" CI_SUITES_PER_SHARD=2
(cd "$R" && env -u GITHUB_ACTIONS CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$BASE" CI_PLAN_ESCALATION=- \
   TI_PR_LABELS= CI_QUARANTINE= CI_PLAN_CHANGED_FILE="$T/changed" CI_SUITES_PER_SHARD=2 CI_FULL_TRIGGERS="$FT" \
   bin/ci-plan.sh --expect-n "$(out n)" --out "$T/shard" > /dev/null 2>&1); SRC=$?
[ "$SRC" = 0 ] && ok "D4 a shard given full_triggers agrees on --expect-n ($(out n))" || bad "D4 shard rc=$SRC (plan n=$PN)"
(cd "$R" && env -u GITHUB_ACTIONS CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$BASE" CI_PLAN_ESCALATION=- \
   TI_PR_LABELS= CI_QUARANTINE= CI_PLAN_CHANGED_FILE="$T/changed" CI_SUITES_PER_SHARD=2 \
   bin/ci-plan.sh --expect-n "$(out n)" --out "$T/shard" > /dev/null 2>&1); SRC=$?
[ "$SRC" = 1 ] && ok "D4 a shard WITHOUT the delta disagrees (rc 1)" || bad "D4 a shard without the delta rc=$SRC — D4 proves nothing"

# >>> W cases
# The workflow shapes are pinned as YAML on purpose (D3's exception): no
# runner here can execute GitHub Actions.
if python3 -c 'import yaml' 2>/dev/null; then
  WOUT=$(python3 - "$DIR/.github/workflows/harness-nightly.yml" "$DIR/.github/workflows/harness-ci.yml" "$DIR/bin/main-red-detector.sh" <<'PY'
import re, sys, yaml
nwf, ciwf, det = sys.argv[1:4]
n = yaml.safe_load(open(nwf)); c = yaml.safe_load(open(ciwf))
def steps(wf, j): return ((wf.get("jobs") or {}).get(j) or {}).get("steps") or []
def runs(wf, j): return "\n".join(str(s.get("run", "")) for s in steps(wf, j))
def res(tag, cond, msg): print(("PASS: " if cond else "FAIL: ") + tag + " " + msg)
# W1
for j in ("plan", "shard"):
    res("W1", "bin/ci-plan.sh --tier nightly-full" in runs(n, j), f"nightly {j} plans --tier nightly-full")
    e = {}
    for s in steps(n, j): e.update(s.get("env") or {})
    res("W1", "vars.CI_SUITES_PER_SHARD" in str(e.get("CI_SUITES_PER_SHARD")) and "vars.CI_MAX_SHARDS" in str(e.get("CI_MAX_SHARDS")),
        f"nightly {j} is sized by the repo variables")
# W2
lj = (n.get("jobs") or {}).get("lints") or {}
lr = runs(n, "lints")
res("W2", bool(lj), "harness-nightly.yml has a lints job")
res("W2", re.search(r"(^|\s)bin/test-determinism-lint\.sh\s*$", lr, re.M) is not None and "--warn-only" not in lr, "the lints job runs the determinism lint strict")
res("W2", "bin/fixture-hygiene.sh" not in lr, "the lints job leaves fixture-hygiene to the PR rules pack")
res("W2", "bin/test-payload-pin-lint.sh --strict" in lr, "the lints job runs the payload-pin lint in error mode")
res("W2", "tests/day-boundary-guard.bh-6052-test.sh" in lr, "the lints job runs the day-boundary guard")
res("W2", "LINTS_BASE" in lr and "lints_base" in str(lj.get("outputs")) and "last_green" in str(lj.get("outputs")), "the lints judge the range since the last green lints night")
res("W2", '"Nightly hygiene lints"' in lr and lj.get("name") == "Nightly hygiene lints", "the lints base reads this job's own conclusion, by its name")
vn = ((n.get("jobs") or {}).get("verdict") or {}).get("needs") or []
res("W2", "lints" in vn, f"the ticket (verdict) job needs lints: {vn}")
res("W2", "needs.lints.result" in str(steps(n, "verdict")) and "NT_LAST_GREEN" in str(steps(n, "verdict")), "the verdict reads the lints result and the last green sha")
co = [s for s in steps(n, "lints") if str(s.get("uses", "")).startswith("actions/checkout")]
res("W2", bool(co) and all((s.get("with") or {}).get("persist-credentials") is False for s in co), "the lints checkout keeps no credential")
# W3
dr = runs(c, "determinism")
res("W3", "bin/test-determinism-lint.sh --warn-only" in dr and "::warning::" in dr, "the CI determinism job is warn-only with annotations")
res("W3", ((c.get("jobs") or {}).get("determinism") or {}).get("name") == "Test determinism lint", "the determinism job name is unchanged (Mergify requires it)")
fl = runs(c, "lint")
res("W3", re.search(r"--skip determinism(\s|$)", fl) is not None and "fixture-hygiene" not in re.sub(r"^\s*#.*$", "", fl, flags=re.M),
    "fast always-lints skips determinism only; the fixture-hygiene leak checks stay blocking")
allci = open(ciwf).read()
res("W3", "bin/test-payload-pin-lint.sh" not in "\n".join(runs(c, j) for j in (c.get("jobs") or {})), "no CI step runs the payload-pin lint")
# W4
lname = str(((c.get("jobs") or {}).get("lint") or {}).get("name", ""))
for want, why in (("bash -n", "syntax"), ("bin/ci-shellcheck.sh", "shellcheck"), ("bin/rules-pack.sh", "rules-pack"),
                  ("bin/sql-ident-lint.sh", "the SQL identifier lint")):
    res("W4", want in fl, f"the lint job still runs {why} ({want})")
res("W4", "config integrity" in lname, f"the lint job is still the config-integrity check: {lname!r}")
res("W4", "-S error" in allci or "--severity=error" in allci or "error" in open(sys.argv[2]).read(), "shellcheck at error severity")
# W5
m = re.search(r"^SKIP_DEFAULT='([^']*)'", open(det).read(), re.M)
on = n.get("on", n.get(True)) or {}
res("W5", bool(m) and re.search(m.group(1), str(n.get("name")), re.I) is not None, f"the nightly name {n.get('name')!r} matches the main-red skip regex")
res("W5", "schedule" in on and not ({"push", "pull_request"} & set(on)), "the nightly runs on a schedule, never on push or PR")
res("W1", "ci-plan.sh --tier nightly-full" in open(nwf).read(), "harness-nightly.yml names nightly-full")
PY
  ); echo "$WOUT"
  PASS=$((PASS + $(grep -c '^PASS:' <<<"$WOUT"))); FAIL=$((FAIL + $(grep -c '^FAIL:' <<<"$WOUT")))
  grep -q '^PASS: W' <<<"$WOUT" || bad "W the workflow checks did not run"
else
  [ -n "${CI:-}" ] && bad "W PyYAML missing on a CI runner" || echo "SKIP: W1-W5 (no PyYAML on this machine)"
fi
# <<< W cases

echo "ci-plan-nightly-split.bh-6838: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
