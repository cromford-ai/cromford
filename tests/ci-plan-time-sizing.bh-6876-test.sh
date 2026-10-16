#!/bin/bash
# tests/ci-plan-time-sizing.bh-6876-test.sh — bin/ci-plan.sh sizes the shard
# count by MEASURED TIME when it has the durations file, so no shard goes over
# the per-shard budget (BH-6876).
#
# WHY. The split was already by time (suite_shard_plan, an LPT over the
# durations), but the COUNT was ceil(suites / CI_SUITES_PER_SHARD): a
# 186-suite batch got 2 shards and an estimate of 26.9 min. The count now
# comes from suite_shard_size over the same file the shards split by.
#
#   S1  40 suites, 5..300 s, 3000 s in all, budget 480 s, cap 16: N is the
#       smallest n whose split keeps every shard <= 480 s, and every shard of
#       that split is <= 480 s (acceptance test 1); the count rule would say 1
#   S2  one suite of 600 s > budget: N is the smallest n with a max load of
#       600 s, never the cap; the sizing line says `over budget`
#   S3  20 000 s, cap 4: N = 4, the line says `cap reached`; S3b with one
#       600 s suite too, both `over budget` and `cap reached` are said
#   S4  3 suites of 900 s: N <= 3 (never an empty shard)
#   S5  no CI_PLAN_DURATIONS_FILE, an unreadable one, a header-only one: the
#       count rule, byte for byte, and the line says `count`; one data row
#       picks time
#   S6  CI_SHARD_BUDGET_S=abc and =0: the default 480, said on stderr
#   S7  a re-plan with --expect-n N and the same file is rc 0; a different
#       budget is rc 1 with the disagreement message
#   S8  GITHUB_OUTPUT holds sizing=, shard_budget_s=480, max_shards=16, and
#       summary= keeps its old shape
#   S9  the S1 table under a `# source: seed <sha>` header: the count rule,
#       and the line says `weights are the seed <sha12>`; under `# source:
#       none`, or with no source line: count, `weights have no source`; under
#       `# source: cache` and `# source: artifact run 123`: time (comment
#       6197071504 item 3: never size by stale seed weights)
#   S10 the time line names the weights' source: `sizing: time (api), ...`
#   W1  the workflow: the plan job fetches the durations before ci-plan, with
#       no `if:`; the plan step sets CI_PLAN_DURATIONS_FILE and
#       CI_SHARD_BUDGET_S; the shard re-plan reads the plan's max_shards and
#       shard_budget_s outputs and the same file
#   R   bin/ci-plan-split-replay.sh with a stub durations fetch of 25 rows
#       prints exactly 20 `slowest:` lines, heaviest first, and
#       `over budget: <k>` with the right k
#
# bin/test-impact.sh is a recording fake (the seam tests/ci-plan-test.sh uses),
# so the planner under test is the real bin/ci-plan.sh with the real
# bin/lib/suite-runner.sh. R runs the real replay and planner in a scratch repo.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PLAN="$DIR/bin/ci-plan.sh"
WFILE="$DIR/.github/workflows/harness-ci.yml"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# The fake selector: ci-select prints $FAKE_SELECT and the reason line.
cat > "$T/fake-impact.sh" <<'FAKE'
#!/bin/bash
OUT=""
while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift ;; *) CMD="$1" ;; esac; shift; done
echo "impact: $(grep -c . "$FAKE_SELECT") of 2000 suites (selected: 1 changed path(s))" >&2
if [ -n "$OUT" ]; then cat "$FAKE_SELECT" > "$OUT"; else cat "$FAKE_SELECT"; fi
FAKE
chmod +x "$T/fake-impact.sh"

# mkdur <list> <durations> <seconds...> — one suite per weight, in the format
# bin/ci-durations.sh writes (`<suite>\t<seconds %.1f>\t<run>\t<values>`).
mkdur() {
  local list="$1" dur="$2" i=0 s; shift 2
  : > "$list"; printf '# source: api\n' > "$dur"
  for s in "$@"; do
    i=$((i + 1))
    printf 'tests/t%03d-test.sh\n' "$i" >> "$list"
    printf 'tests/t%03d-test.sh\t%.1f\t9001\t%.1f\n' "$i" "$s" "$s" >> "$dur"
  done
}

# plan [VAR=value ...] [-- args] — the real planner as an ordinary PR; sets RC OUT GO
plan() {
  local vars=() args=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do vars+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift; args=("$@")
  rm -f "$T/go" "$T/list"
  OUT=$(env -u CI_SUITES_PER_SHARD -u CI_MAX_SHARDS -u CI_SHARD_BUDGET_S -u CI_PLAN_DURATIONS_FILE \
          -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY -u CI_BASE_REF -u CI_DISPATCH_SCOPE \
          CI_EVENT=pull_request TI_PR_HEAD_REF=ticket/bh-6876-fixture TI_BASE=deadbeef \
          CI_PLAN_IMPACT="$T/fake-impact.sh" GITHUB_OUTPUT="$T/go" ${vars[@]+"${vars[@]}"} \
          "$PLAN" --out "$T/list" ${args[@]+"${args[@]}"} 2>&1); RC=$?
  GO=$(cat "$T/go" 2>/dev/null)
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }
sizing() { printf '%s\n' "$OUT" | sed -n 's/^ci-plan: sizing: //p' | tail -1; }

# loads <n> <list> <dur> — the per-shard load in ms of the split the shards
# run (the unchanged suite_shard_plan), one per line, heaviest first.
loads() {
  # shellcheck disable=SC2046 # one suite path per line, no spaces
  ( . "$DIR/bin/lib/suite-runner.sh" || exit 9
    SUITE_DURATIONS_FILE="$3" suite_shard_plan "$1" $(cat "$2") ) \
    | awk -F'\t' '{ s[$1] += $2 } END { for (k in s) print s[k] }' | sort -rn
}
# smallest <list> <dur> <target ms> <cap> — the smallest n whose max load is <= target
smallest() {
  local n
  for ((n = 1; n <= $4; n++)); do
    [ "$(loads "$n" "$1" "$2" | head -1)" -le "$3" ] && { echo "$n"; return; }
  done
  echo none
}

# ── S1. acceptance test 1: every shard under the budget.
W1S=(300 250 200 150 5 55)
for ((i = 0; i < 34; i++)); do W1S+=(60); done
mkdur "$T/s1.list" "$T/s1.dur" "${W1S[@]}"
[ "$(awk -F'\t' 'NR > 1 { s += $2 } END { print s }' "$T/s1.dur")" = 3000 ] || bad "S1 fixture: the weights must total 3000 s"
[ "$(grep -c . "$T/s1.list")" = 40 ] || bad "S1 fixture: 40 suites"
WANT1=$(smallest "$T/s1.list" "$T/s1.dur" 480000 16)
plan FAKE_SELECT="$T/s1.list" CI_PLAN_DURATIONS_FILE="$T/s1.dur" CI_MAX_SHARDS=16
[ "$RC" = 0 ] && ok || bad "S1: the plan must be rc 0 (rc=$RC) [$OUT]"
[ "$(out n)" = "$WANT1" ] && ok || bad "S1: n must be the smallest n that keeps every shard <= 480 s ($WANT1), got '$(out n)' [$(sizing)]"
[ "$(out n)" != 1 ] && ok || bad "S1: the count rule (ceil(40/120) = 1) must not size a 3000 s selection"
over=$(loads "$(out n)" "$T/s1.list" "$T/s1.dur" | awk '$1 > 480000' | grep -c .)
[ "$over" = 0 ] && ok || bad "S1: $over shard(s) of the planned split are over 480 s: $(loads "$(out n)" "$T/s1.list" "$T/s1.dur" | paste -sd' ')"
[ "$(loads "$(out n)" "$T/s1.list" "$T/s1.dur" | grep -c .)" = "$(out n)" ] && ok || bad "S1: every one of the n shards carries a suite"
has "time (api), $WANT1 shard(s)" "$(sizing)" && has "of budget 480s, cap 16" "$(sizing)" && ok || bad "S1: the sizing line must say time (api), $WANT1 shard(s), budget 480s, cap 16: '$(sizing)'"
! has "over budget" "$(sizing)" && ! has "cap reached" "$(sizing)" && ok || bad "S1: nothing is over budget or capped: '$(sizing)'"

# ── S2. one suite over the budget: the fewest shards that reach it.
mkdur "$T/s2.list" "$T/s2.dur" 600 100 100 100
WANT2=$(smallest "$T/s2.list" "$T/s2.dur" 600000 16)
plan FAKE_SELECT="$T/s2.list" CI_PLAN_DURATIONS_FILE="$T/s2.dur" CI_MAX_SHARDS=16
[ "$RC" = 0 ] && [ "$WANT2" = 2 ] && [ "$(out n)" = 2 ] && ok || bad "S2: n must be 2, the smallest n with a max load of 600 s (want $WANT2, got '$(out n)', rc=$RC) [$(sizing)]"
has "over budget (biggest suite 600s)" "$(sizing)" && ok || bad "S2: the line must say over budget: '$(sizing)'"

# ── S3. the cap stops it, and says so.
S3W=(); for ((i = 0; i < 50; i++)); do S3W+=(400); done
mkdur "$T/s3.list" "$T/s3.dur" "${S3W[@]}"
plan FAKE_SELECT="$T/s3.list" CI_PLAN_DURATIONS_FILE="$T/s3.dur" CI_MAX_SHARDS=4
[ "$RC" = 0 ] && [ "$(out n)" = 4 ] && ok || bad "S3: 20 000 s on cap 4 must be 4 shards (rc=$RC n='$(out n)')"
has "cap reached" "$(sizing)" && has "cap 4" "$(sizing)" && ok || bad "S3: the line must say cap reached: '$(sizing)'"

# S3b: a suite over the budget AND the cap: both are said.
mkdur "$T/s3b.list" "$T/s3b.dur" 600 "${S3W[@]}"
plan FAKE_SELECT="$T/s3b.list" CI_PLAN_DURATIONS_FILE="$T/s3b.dur" CI_MAX_SHARDS=4
[ "$RC" = 0 ] && [ "$(out n)" = 4 ] && has "over budget (biggest suite 600s)" "$(sizing)" && has "cap reached" "$(sizing)" && ok \
  || bad "S3b: over budget and the cap must both be said (rc=$RC n='$(out n)'): '$(sizing)'"
# S2 control: an over-budget suite that its own shard fits is not a cap stop.
plan FAKE_SELECT="$T/s2.list" CI_PLAN_DURATIONS_FILE="$T/s2.dur" CI_MAX_SHARDS=2
! has "cap reached" "$(sizing)" && ok || bad "S3b: n = cap with the slowest shard at the biggest suite is not 'cap reached': '$(sizing)'"

# ── S4. never more shards than suites.
mkdur "$T/s4.list" "$T/s4.dur" 900 900 900
plan FAKE_SELECT="$T/s4.list" CI_PLAN_DURATIONS_FILE="$T/s4.dur" CI_MAX_SHARDS=16
[ "$RC" = 0 ] && [ -n "$(out n)" ] && [ "$(out n)" -le 3 ] && ok || bad "S4: 3 suites must never take more than 3 shards (rc=$RC n='$(out n)')"

# ── S5. no usable durations: the count rule, exactly as before.
mkdur "$T/s5.list" "$T/s5.dur" "${W1S[@]}"
printf '# source: none\n' > "$T/header-only.dur"
for c in "unset:" "missing:$T/no-such.dur" "header:$T/header-only.dur"; do
  tag="${c%%:*}"; f="${c#*:}"
  if [ -n "$f" ]; then plan FAKE_SELECT="$T/s5.list" CI_SUITES_PER_SHARD=7 CI_PLAN_DURATIONS_FILE="$f"
  else plan FAKE_SELECT="$T/s5.list" CI_SUITES_PER_SHARD=7; fi
  [ "$RC" = 0 ] && [ "$(out n)" = 6 ] && ok || bad "S5 ($tag): the count rule ceil(40/7) = 6, got '$(out n)' (rc=$RC)"
  has "count, ceil(40/7) cap 8" "$(sizing)" && ok || bad "S5 ($tag): the line must say count: '$(sizing)'"
done
has "no durations file" "$(plan FAKE_SELECT="$T/s5.list"; sizing)" && ok || bad "S5: the count line says why (no file)"
has "no data rows" "$(plan FAKE_SELECT="$T/s5.list" CI_PLAN_DURATIONS_FILE="$T/header-only.dur"; sizing)" && ok || bad "S5: the count line says why (header only)"
printf '# source: api\ntests/t001-test.sh\t1000.0\t9001\t1000.0\n' > "$T/one-row.dur"
plan FAKE_SELECT="$T/s5.list" CI_PLAN_DURATIONS_FILE="$T/one-row.dur" CI_MAX_SHARDS=16
has "time (api)," "$(sizing)" && ok || bad "S5: one data row is enough to size by time: '$(sizing)'"

# ── S6. a bad budget falls back to 480 and says so.
for b in abc 0; do
  plan FAKE_SELECT="$T/s1.list" CI_PLAN_DURATIONS_FILE="$T/s1.dur" CI_MAX_SHARDS=16 CI_SHARD_BUDGET_S="$b"
  { [ "$RC" = 0 ] && [ "$(out n)" = "$WANT1" ] && [ "$(out shard_budget_s)" = 480 ]; } && ok || bad "S6 ($b): the default 480 must size it (n='$(out n)' budget='$(out shard_budget_s)')"
  has "CI_SHARD_BUDGET_S='$b' is not a positive integer" "$OUT" && ok || bad "S6 ($b): the fallback must be said [$OUT]"
done

# ── S7. the shard re-plan agrees, and a different budget does not.
plan FAKE_SELECT="$T/s1.list" CI_PLAN_DURATIONS_FILE="$T/s1.dur" CI_MAX_SHARDS=16
N7=$(out n)
plan FAKE_SELECT="$T/s1.list" CI_PLAN_DURATIONS_FILE="$T/s1.dur" CI_MAX_SHARDS=16 -- --expect-n "$N7"
[ "$RC" = 0 ] && ok || bad "S7: a re-plan from the same file must agree on $N7 (rc=$RC) [$OUT]"
plan FAKE_SELECT="$T/s1.list" CI_PLAN_DURATIONS_FILE="$T/s1.dur" CI_MAX_SHARDS=16 CI_SHARD_BUDGET_S=1500 -- --expect-n "$N7"
[ "$RC" = 1 ] && has "the two would split the corpus differently" "$OUT" && ok || bad "S7: a different budget must be rc 1 (rc=$RC) [$OUT]"

# ── S8. the outputs the shards read.
plan FAKE_SELECT="$T/s1.list" CI_PLAN_DURATIONS_FILE="$T/s1.dur" CI_MAX_SHARDS=16
[ "$(out shard_budget_s)" = 480 ] && [ "$(out max_shards)" = 16 ] && ok || bad "S8: shard_budget_s=480 and max_shards=16 expected: [$GO]"
[ "$(out sizing)" = "$(sizing)" ] && [ -n "$(out sizing)" ] && ok || bad "S8: sizing= must be the sizing line without its prefix: '$(out sizing)' vs '$(sizing)'"
grep -qE "^impact: 40 of 2000 suites \(selected: 1 changed path\(s\)\) — $WANT1 shard\(s\), mode=selected$" <<<"$(out summary)" && ok \
  || bad "S8: summary= keeps its old shape: '$(out summary)'"

# ── S9. the weights' source gates the time rule (comment 6197071504 item 3).
# The headers are the exact shapes bin/ci-durations.sh fetch writes.
SEEDSHA=abc123def4567890abc123def4567890abc12345
for c in "seed:# source: seed $SEEDSHA" "none:# source: none" "nohdr:"; do
  tag="${c%%:*}"; hdr="${c#*:}"
  { [ -z "$hdr" ] || printf '%s\n' "$hdr"; grep -v '^#' "$T/s1.dur"; } > "$T/s9-$tag.dur"
  plan FAKE_SELECT="$T/s1.list" CI_PLAN_DURATIONS_FILE="$T/s9-$tag.dur" CI_MAX_SHARDS=16
  [ "$RC" = 0 ] && [ "$(out n)" = 1 ] && ok || bad "S9 ($tag): the count rule ceil(40/120) = 1 must answer, got '$(out n)' (rc=$RC) [$(sizing)]"
  has "count, ceil(40/120) cap 16" "$(sizing)" && ok || bad "S9 ($tag): the line must say count: '$(sizing)'"
  case "$tag" in
    seed) has "weights are the seed abc123def456)" "$(sizing)" && ok || bad "S9 (seed): the line must name the seed sha12: '$(sizing)'" ;;
    *)    has "weights have no source" "$(sizing)" && ok || bad "S9 ($tag): the line must say the weights have no source: '$(sizing)'" ;;
  esac
done
for c in "cache:# source: cache:cache" "artifact:# source: artifact run 123:artifact"; do
  tag="${c%%:*}"; rest="${c#*:}"; hdr="${rest%:*}"; name="${rest##*:}"
  { printf '%s\n' "$hdr"; grep -v '^#' "$T/s1.dur"; } > "$T/s9-$tag.dur"
  plan FAKE_SELECT="$T/s1.list" CI_PLAN_DURATIONS_FILE="$T/s9-$tag.dur" CI_MAX_SHARDS=16
  [ "$RC" = 0 ] && [ "$(out n)" = "$WANT1" ] && ok || bad "S9 ($tag): a $tag fetch sizes by time ($WANT1), got '$(out n)' (rc=$RC) [$(sizing)]"
  has "time ($name), $WANT1 shard(s)" "$(sizing)" && ok || bad "S9 ($tag): the line must say time ($name): '$(sizing)'"
done

# ── S10. the time line names its source, and so does the sizing= output.
plan FAKE_SELECT="$T/s1.list" CI_PLAN_DURATIONS_FILE="$T/s1.dur" CI_MAX_SHARDS=16
grep -qE '^ci-plan: sizing: time \(api\), [0-9]+ shard\(s\), ' <<<"$OUT" && ok || bad "S10: the line must start 'sizing: time (api), N shard(s)': '$(sizing)'"
has "time (api)," "$(out sizing)" && ok || bad "S10: sizing= must name the source: '$(out sizing)'"

# ── W1. the workflow wiring (parsed, not grepped).
command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null || { echo "FAIL: W1 needs python3 with yaml"; FAIL=$((FAIL+1)); }
W1=$(python3 - "$WFILE" <<'PY' 2>&1
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
jobs = wf["jobs"]
errs = []
plan = jobs["plan"]
steps = plan["steps"]
def idx(pred):
    for i, s in enumerate(steps):
        if pred(s): return i
    return -1
fetch = idx(lambda s: "ci-durations.sh fetch" in str(s.get("run", "")))
pl = idx(lambda s: s.get("id") == "plan")
if fetch < 0 or pl < 0: errs.append("no durations fetch (%d) or plan step (%d)" % (fetch, pl))
else:
    if fetch > pl: errs.append("the durations fetch runs after the plan step")
    if "if" in steps[fetch]: errs.append("the durations fetch has an if: %r" % steps[fetch]["if"])
    env = steps[pl].get("env", {})
    if env.get("CI_PLAN_DURATIONS_FILE") != "${{ runner.temp }}/ci-durations/ci-durations.tsv":
        errs.append("plan CI_PLAN_DURATIONS_FILE=%r" % env.get("CI_PLAN_DURATIONS_FILE"))
    if env.get("CI_SHARD_BUDGET_S") != "${{ vars.CI_SHARD_BUDGET_S }}":
        errs.append("plan CI_SHARD_BUDGET_S=%r" % env.get("CI_SHARD_BUDGET_S"))
    if "--out" not in steps[fetch]["run"] or "ci-durations/ci-durations.tsv" not in steps[fetch]["run"]:
        errs.append("the fetch does not write the file the plan reads")
outs = plan.get("outputs", {})
for k in ("sizing", "shard_budget_s", "max_shards"):
    if outs.get(k) != "${{ steps.plan.outputs.%s }}" % k: errs.append("plan output %s=%r" % (k, outs.get(k)))
up = [s for s in steps if s.get("name") == "hand the shard weights to every shard"]
if not up or up[0].get("if") != "steps.plan.outputs.corpus == '1'": errs.append("the upload lost its corpus if:")
shard = jobs["tests-shard"]["steps"]
rp = [s for s in shard if "--expect-n" in str(s.get("run", ""))]
if len(rp) != 1: errs.append("%d shard re-plan steps" % len(rp))
else:
    env = rp[0].get("env", {})
    want = {"CI_MAX_SHARDS": "${{ needs.plan.outputs.max_shards }}",
            "CI_SHARD_BUDGET_S": "${{ needs.plan.outputs.shard_budget_s }}",
            "CI_PLAN_DURATIONS_FILE": "${{ runner.temp }}/ci-durations/ci-durations.tsv"}
    for k, v in want.items():
        if env.get(k) != v: errs.append("shard %s=%r" % (k, env.get(k)))
print("\n".join(errs) if errs else "ok")
PY
)
[ "$W1" = ok ] && ok || bad "W1: the workflow wiring: $W1"

# ── R. the replay's 20 slowest suites and the over-budget count.
G="$T/repo"; mkdir -p "$G/catalog" "$G/tests/lib" "$G/.github/workflows"
for s in bin/ci-plan-split-replay.sh bin/ci-plan.sh bin/test-impact.sh bin/test-tiers.sh bin/ci-durations.sh; do
  ( cd "$DIR" && scratch_install_closure "$s" "$G" ) > /dev/null || { echo "FAIL: R cannot install $s's closure"; exit 1; }
done
cp "$DIR/catalog/ci-batch-escalate.tsv" "$G/catalog/" && cp "$DIR/tests/lib/scratch.sh" "$G/tests/lib/" \
  || { echo "FAIL: R fixture copy"; exit 1; }
printf 'tests/always-a-test.sh\n' > "$G/catalog/test-impact-always.txt"
printf '# a scratch tier file\n' > "$G/catalog/test-tiers.tsv"
printf '#!/bin/bash\necho foo\n' > "$G/bin/foo.sh"
printf '#!/bin/bash\n. "$(dirname "$0")/lib/scratch.sh" || exit 1\n' > "$G/tests/always-a-test.sh"
printf '#!/bin/bash\n. "$(dirname "$0")/lib/scratch.sh" || exit 1\nbash "$DIR/bin/foo.sh"\n' > "$G/tests/foo-x-test.sh"
printf 'name: Harness CI\njobs: {}\n' > "$G/.github/workflows/harness-ci.yml"
git -C "$G" init -q && git -C "$G" add -A \
  && git -C "$G" -c user.email=t@example.invalid -c user.name=t commit -qm fixture \
  || { echo "FAIL: R cannot commit the scratch repo"; exit 1; }
B=$(printf 'b%039d' 1); H=$(printf 'a%039d' 1)
FX="$T/fx"; mkdir -p "$FX"
jq -nc --arg b "$B" --arg h "$H" '[{number: 901, title: "merge queue: embarking #11 together", body: "fixture", labels: [],
  user: {login: "mergify[bot]"}, base: {sha: $b}, head: {sha: $h, ref: "mergify/merge-queue/901"}}]' > "$FX/pulls.json"
jq -nc '{files: [{filename: "bin/foo.sh"}]}' > "$FX/cmp.json"
jq -nc '{workflow_runs: [{id: 1, name: "Harness CI", conclusion: "success",
  run_started_at: "2026-10-13T10:00:00Z", updated_at: "2026-10-13T10:20:00Z"}]}' > "$FX/runs.json"
jq -nc '{jobs: []}' > "$FX/jobs.json"
cat > "$T/gh" <<EOF
#!/bin/bash
[ "\$1" = api ] || exit 9
case "\$2" in
  *pulls\?*page=1) cat "$FX/pulls.json" ;;
  *pulls\?*) echo '[]' ;;
  */pulls/[0-9]*) echo '{"number": 11, "labels": []}' ;;
  *compare/*) cat "$FX/cmp.json" ;;
  *actions/runs\?*) cat "$FX/runs.json" ;;
  *actions/runs/*/jobs*) cat "$FX/jobs.json" ;;
  *) exit 1 ;;
esac
EOF
# 25 rows: tests/r01 = 25 s ... tests/r25 = 625 s (25 s apart); r20..r25 are over 480 s.
cat > "$T/durations" <<'EOF'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
{ printf '# source: api\n'
  for i in $(seq 1 25); do printf 'tests/r%02d-test.sh\t%d.0\t9001\t%d.0\n' "$i" $((i * 25)) $((i * 25)); done; } > "$out"
EOF
chmod +x "$T/gh" "$T/durations"
ROUT=$(cd "$T" && env -u CI_SUITES_PER_SHARD -u CI_MAX_SHARDS -u CI_SHARD_BUDGET_S -u CI_FULL_TRIGGERS -u CI_QUARANTINE \
  REPLAY_GH="$T/gh" REPLAY_DURATIONS="$T/durations" bash "$G/bin/ci-plan-split-replay.sh" --repo o/r --out "$T/r.tsv" 2>&1); RRC=$?
[ "$RRC" = 0 ] && ok || bad "R: the replay must be rc 0 (rc=$RRC) [$ROUT]"
SL=$(printf '%s\n' "$ROUT" | grep '^slowest: ')
[ "$(printf '%s\n' "$SL" | grep -c .)" = 20 ] && ok || bad "R: exactly 20 slowest: lines expected: [$SL]"
WANTSL=$(for i in $(seq 25 -1 6); do printf 'slowest: %d tests/r%02d-test.sh %d.0s\n' $((26 - i)) "$i" $((i * 25)); done)
[ "$SL" = "$WANTSL" ] && ok || bad "R: the slowest lines must be ranked heaviest first: [$SL]"
has "over budget: 6 suite(s) over 480s" "$ROUT" && ok || bad "R: 6 suites (500..625 s) are over 480 s [$(grep '^over budget' <<<"$ROUT")]"
ROUT2=$(cd "$T" && env -u CI_SUITES_PER_SHARD -u CI_MAX_SHARDS -u CI_FULL_TRIGGERS -u CI_QUARANTINE CI_SHARD_BUDGET_S=600 \
  REPLAY_GH="$T/gh" REPLAY_DURATIONS="$T/durations" bash "$G/bin/ci-plan-split-replay.sh" --repo o/r 2>&1)
has "over budget: 1 suite(s) over 600s" "$ROUT2" && ok || bad "R: the budget comes from CI_SHARD_BUDGET_S [$(grep '^over budget' <<<"$ROUT2")]"
sed 's/source: api/source: seed fixture/' "$T/durations" > "$T/durations-seed"; chmod +x "$T/durations-seed"
ROUT3=$(cd "$T" && env -u CI_SUITES_PER_SHARD -u CI_MAX_SHARDS -u CI_SHARD_BUDGET_S -u CI_FULL_TRIGGERS -u CI_QUARANTINE \
  REPLAY_GH="$T/gh" REPLAY_DURATIONS="$T/durations-seed" bash "$G/bin/ci-plan-split-replay.sh" --repo o/r 2>&1)
[ "$(printf '%s\n' "$ROUT3" | grep '^slowest: ')" = "slowest: - (no durations)" ] && ok || bad "R: a seed fallback lists no slowest suites [$(grep '^slowest' <<<"$ROUT3")]"

echo "ci-plan-time-sizing.bh-6876: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
