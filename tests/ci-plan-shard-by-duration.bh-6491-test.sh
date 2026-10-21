#!/bin/bash
# tests/ci-plan-shard-by-duration.bh-6491-test.sh — bin/ci-plan.sh sizes the
# shard count by recorded suite duration, not by suite count (BH-6491,
# acceptance 1).
#
# WHY. The count rule, ceil(suites / CI_SUITES_PER_SHARD), put batch #6418's 93
# suites on ONE shard and the batch took 32 min: five slow suites set the wall
# time. The sizing itself shipped with BH-6876 (CI_PLAN_DURATIONS_FILE,
# suite_shard_size, the CI_SHARD_BUDGET_S knob, default 480 s). This suite pins
# the ticket's own numbers on that mechanism, and the BH-6491 run-page notice.
#
#   D1  93 suites, 5 at 360 s, the rest 10 s (40 in the file, 48 at the median):
#       n >= 3, sizing by time, every shard of suite_shard_plan <n> <= 720 s
#   D2  a missing file and a header-only `# source: none` file: the count rule (n=1), rc 0,
#       and the fallback is logged (`ci-plan: sizing: count, ... (<why>)`)
#   D3  CI_PLAN_DURATIONS_FILE unset: the count rule, said as such
#   D4  CI_SHARD_BUDGET_S=300 -> budget 300s and more shards than at 480;
#       CI_SHARD_BUDGET_S=abc -> budget 480s and one stderr note
#   D5  --expect-n with the same file agrees; with other weights it is rc 1
#   D6  the reused suites are subtracted BEFORE the sizing (n drops)
#   D7  a batch sends ONE `::notice title=ci-plan sizing::` with the sizing line
#       (red before BH-6491), and the step summary has the line
#
# The real bin/ci-plan.sh runs a merge-queue batch, with the CI_PLAN_IMPACT
# fake of tests/ci-plan-batch-impact.bh-4968-test.sh and no tier rows.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PLAN="$DIR/bin/ci-plan.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
HEADSHA=$(git -C "$DIR" rev-parse HEAD 2>/dev/null) || HEADSHA=0123456789abcdef0123456789abcdef01234567

# The selection: 93 suites. d0001..d0005 weigh 360 s; d0006..d0045 are in the
# file at 10 s; d0046..d0093 are not in it and weigh the file median (10 s).
: > "$T/sel"; for ((i = 1; i <= 93; i++)); do printf 'tests/d%04d-test.sh\n' "$i" >> "$T/sel"; done
: > "$T/all"; for ((i = 1; i <= 980; i++)); do printf 'tests/d%04d-test.sh\n' "$i" >> "$T/all"; done
mkdur() { # mkdur <file> — the 45-row ledger file of a real fetch
  { echo "# source: api"
    echo "# ci-suite-durations.tsv from the jobs worker's ci_suite_durations (BH-5653); <suite>\t<seconds>\t<run>"
    for ((i = 1; i <= 45; i++)); do
      if [ "$i" -le 5 ]; then s=360; else s=10; fi
      printf 'tests/d%04d-test.sh\t%s\t7001\n' "$i" "$s"
    done; } > "$1"
}
mkdur "$T/dur.tsv"
printf '# source: none\n# ci-suite-durations.tsv — no artifact and no seed; every suite weighs the same.\n' > "$T/none.tsv"
# Other weights: every suite 10 s, so the 93 fit one shard.
{ echo "# source: api"; for ((i = 1; i <= 45; i++)); do printf 'tests/d%04d-test.sh\t10\t7001\n' "$i"; done; } > "$T/flat.tsv"
: > "$T/notiers.tsv"

cat > "$T/impact.sh" <<'FAKE'
#!/bin/bash
OUT=""
while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift ;; --changed) shift ;; *) CMD="$1" ;; esac; shift; done
case "$CMD" in
  select|ci-select) echo "impact: $(grep -c . "$FAKE_SELECT") of $(grep -c . "$FAKE_ALL") suites (selected: 1 changed path(s))" >&2 ;;
esac
cat "$FAKE_SELECT" > "$OUT"
FAKE
chmod +x "$T/impact.sh"
printf 'console-ui/src/screens/Jobs.js\n' > "$T/changed"

# bplan [VAR=val ...] — one merge-queue batch plan; sets RC OUT ERR GO SUM
bplan() {
  rm -f "$T/go" "$T/list" "$T/sum"
  OUT=$(env -u GITHUB_ACTIONS -u CI_PLAN_DURATIONS_FILE -u CI_SUITES_PER_SHARD -u CI_MAX_SHARDS -u CI_SHARD_BUDGET_S -u CI_PLAN_REUSE \
          CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$HEADSHA" \
          CI_PLAN_ESCALATION=- TI_PR_LABELS= CI_QUARANTINE= CI_PLAN_IMPACT="$T/impact.sh" CI_PLAN_CHANGED_FILE="$T/changed" \
          FAKE_SELECT="$T/sel" FAKE_ALL="$T/all" CI_PLAN_TIER_FILE="$T/notiers.tsv" \
          GITHUB_OUTPUT="$T/go" GITHUB_STEP_SUMMARY="$T/sum" \
          "$@" "${PLAN_BIN:-$PLAN}" --out "$T/list" ${EXPECT:+--expect-n "$EXPECT"} 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err"); GO=$(cat "$T/go" 2>/dev/null); SUM=$(cat "$T/sum" 2>/dev/null)
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }
sizing() { printf '%s\n' "$OUT" | sed -n 's/^ci-plan: sizing: //p' | tail -1; }
# maxshard <n> <durations> — the largest shard sum (ms) suite_shard_plan gives the list
maxshard() {
  ( . "$DIR/bin/lib/suite-runner.sh" || exit 9
    mapfile -t L < "$T/list"
    SUITE_DURATIONS_FILE="$2" suite_shard_plan "$1" "${L[@]}" ) \
    | awk -F'\t' '{ s[$1] += $2 } END { m = 0; for (k in s) if (s[k] > m) m = s[k]; print m + 0 }'
}

# ── D1. sizing by time: at least 3 shards, none over 12 minutes.
bplan CI_PLAN_DURATIONS_FILE="$T/dur.tsv"
N1=$(out n)
{ [ "$RC" = 0 ] && [ "$(out count)" = 93 ] && has "time (api), $N1 shard(s)" "$(out sizing)" && [ "${N1:-0}" -ge 3 ]; } && ok \
  || bad "D1: 93 suites with five 360 s ones must be time-sized to >= 3 shards (rc=$RC count=$(out count) n=$N1 sizing=$(out sizing)) [$OUT] [$ERR]"
if [ "${N1:-0}" -ge 1 ]; then
  M1=$(maxshard "$N1" "$T/dur.tsv")
  [ "${M1:-999999999}" -le 720000 ] && ok || bad "D1: every shard must be <= 720 s, the largest is ${M1} ms at n=$N1"
  # The line's estimate IS the split the shards run.
  P1=$(sizing | sed -n 's/.*slowest est \([0-9]*\)s of budget.*/\1/p')
  [ -n "$P1" ] && [ "$P1" = "$(( (M1 + 500) / 1000 ))" ] && ok || bad "D1: slowest est ${P1}s must be the split's max $(( (${M1:-0} + 500) / 1000 ))s [$(sizing)]"
else bad "D1: no n to split by"; fi
has "of budget 480s, cap 8" "$(sizing)" && ok || bad "D1: the default budget 480 s and cap 8 [$(sizing)]"
has "impact: 93 of 980 suites (" "$OUT" && has " — $N1 shard(s), mode=batch-selected" "$OUT" && ok \
  || bad "D1: the SUMMARY line keeps its format and carries n [$OUT]"

# ── D2. no ledger: the count rule, logged.
for f in "$T/missing.tsv" "$T/none.tsv"; do
  bplan CI_PLAN_DURATIONS_FILE="$f"
  { [ "$RC" = 0 ] && [ "$(out n)" = 1 ]; } && ok \
    || bad "D2 $(basename "$f"): the count rule n=1, rc 0 (rc=$RC n=$(out n)) [$OUT] [$ERR]"
  case "$(sizing)" in "count, ceil(93/120) cap 8 ("*")") ok ;; *) bad "D2 $(basename "$f"): the logged fallback line [$(sizing)]" ;; esac
done
has "(durations file unreadable)" "$(bplan CI_PLAN_DURATIONS_FILE="$T/missing.tsv"; sizing)" && ok || bad "D2: the missing file says why"
has "(no data rows)" "$(bplan CI_PLAN_DURATIONS_FILE="$T/none.tsv"; sizing)" && ok || bad "D2: the none file says why"

# ── D3. no file at all: the count rule, said as such.
bplan
{ [ "$RC" = 0 ] && [ "$(out n)" = 1 ] && [ "$(sizing)" = "count, ceil(93/120) cap 8 (no durations file)" ]; } && ok \
  || bad "D3: unset must keep the count rule and say so (rc=$RC n=$(out n)) [$(sizing)]"

# ── D4. the budget knob.
bplan CI_PLAN_DURATIONS_FILE="$T/dur.tsv" CI_SHARD_BUDGET_S=300
N300=$(out n)
{ [ "$RC" = 0 ] && has "of budget 300s" "$(sizing)" && [ "${N300:-0}" -gt "${N1:-99}" ]; } && ok \
  || bad "D4: CI_SHARD_BUDGET_S=300 must say budget 300s and plan more than $N1 shards (n=$N300) [$(sizing)]"
bplan CI_PLAN_DURATIONS_FILE="$T/dur.tsv" CI_SHARD_BUDGET_S=abc
{ [ "$RC" = 0 ] && has "of budget 480s" "$(sizing)" && [ "$(out n)" = "$N1" ] \
    && [ "$(printf '%s\n' "$ERR" | grep -c 'CI_SHARD_BUDGET_S')" = 1 ]; } && ok \
  || bad "D4: CI_SHARD_BUDGET_S=abc must fall back to 480 with one stderr note (n=$(out n)) [$(sizing)] [$ERR]"

# ── D5. --expect-n: the same file agrees, other weights are red.
EXPECT="$N1" bplan CI_PLAN_DURATIONS_FILE="$T/dur.tsv"
[ "$RC" = 0 ] && ok || bad "D5: --expect-n $N1 with the same file must pass (rc=$RC) [$ERR]"
EXPECT="$N1" bplan CI_PLAN_DURATIONS_FILE="$T/flat.tsv"
{ [ "$RC" = 1 ] && has "the plan job said $N1" "$ERR"; } && ok || bad "D5: other weights must be rc 1 (rc=$RC) [$OUT] [$ERR]"

# ── D6. reuse first, sizing second: the five slow suites reused.
mkdir -p "$T/reuse"
for ((i = 1; i <= 5; i++)); do printf 'tests/d%04d-test.sh\t6001\t360\n' "$i"; done > "$T/reuse/reused.tsv"
bplan CI_PLAN_DURATIONS_FILE="$T/dur.tsv" CI_PLAN_REUSED_FILE="$T/reuse/reused.tsv"
{ [ "$RC" = 0 ] && [ "$(out count)" = 88 ] && has "time (api)" "$(sizing)" && [ "${N1:-0}" -gt "$(out n)" ]; } && ok \
  || bad "D6: sizing must run on the 88 that run, so n drops below $N1 (count=$(out count) n=$(out n)) [$OUT] [$ERR]"

# ── D7. the run page: an own-title notice and the step summary.
bplan CI_PLAN_DURATIONS_FILE="$T/dur.tsv"
NOTE=$(printf '%s\n' "$OUT" | grep -c "^::notice title=ci-plan sizing::sizing: time (api), $N1 shard(s), ")
{ [ "$NOTE" = 1 ] && has "sizing: time (api), $N1 shard(s)" "$SUM"; } && ok \
  || bad "D7: one ::notice title=ci-plan sizing:: and the line in the step summary (notices=$NOTE) [$OUT] [$SUM]"
printf '%s\n' "$OUT" | grep '^::notice title=ci-plan::' | grep -q "n=$N1" && ok || bad "D7: the ci-plan notice keeps its title and n [$OUT]"
bplan CI_PLAN_DURATIONS_FILE="$T/missing.tsv"
[ "$(printf '%s\n' "$OUT" | grep -c '^::notice title=ci-plan sizing::sizing: count, ')" = 1 ] && ok \
  || bad "D7: the fallback is on the run page too [$OUT]"

echo "ci-plan-shard-by-duration: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
