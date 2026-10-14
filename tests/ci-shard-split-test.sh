#!/bin/bash
# tests/ci-shard-split-test.sh — BH-1192: THE SHARD SPLIT MUST COVER THE SUITE
# EXACTLY ONCE.
#
# The `decisions` job ran all ~513 tests/*.sh serially and took 35-45 minutes,
# and `harness-safety` traced the same corpus for another 40-45. Every PR in the
# drain waited for both, so throughput was CI-bound. Both are now four shards
# plus a fan-in job that keeps the old check NAME.
#
# THE FAILURE THIS SUITE EXISTS FOR IS SILENT. A split that drops a suite (an
# off-by-one in the modulo, a shard list built from an unsorted glob, a shard
# index read as a count) still shows four green jobs and a green fan-in. Nobody
# sees the missing suite until the thing it guarded breaks on a box. So the
# partition is asserted directly: the union of the four shards is the whole
# list, no suite appears twice, and a suite added to the corpus lands in exactly
# one shard.
#
# Four lanes, all against the REAL scripts and the REAL workflow file:
#   A. suite_shard_parse refuses every malformed spec (a bad spec must never
#      silently become shard 0, which is how three quarters of a suite stops
#      running while CI stays green).
#   B. suite_shard_filter partitions, deterministically, whatever order the
#      input arrives in.
#   C. bin/test-suite-run.sh --shard and bin/test-trace-safety.sh --shard
#      partition a scratch tests/ tree the same way — the two runners CI calls.
#   D. .github/workflows/harness-ci.yml carries the shape: four shards, no
#      fail-fast, the stable fan-in names the merge gate and the main-red
#      detector already pin, and the /N in the runner arguments equals the
#      number of entries in the matrix.
#
# Self-contained: no network, no secrets, no $HARNESS, no clock read, no dice.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# shellcheck source=../bin/lib/suite-runner.sh
. "$DIR/bin/lib/suite-runner.sh" || { echo "FAIL: cannot source bin/lib/suite-runner.sh"; exit 1; }

WF="${BH1192_WORKFLOW:-$DIR/.github/workflows/harness-ci.yml}"
RUNNER="$DIR/bin/test-suite-run.sh"
TRACE="$DIR/bin/test-trace-safety.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ── A. a malformed shard spec is refused, never rounded into shard 0 ─────────
parse_ok() { # <spec> <expected "i n">
  local out rc
  out=$(suite_shard_parse "$1" 2>/dev/null); rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "$2" ]; then ok
  else bad "A: suite_shard_parse '$1' should be '$2' (rc=$rc, got '$out')"; fi
}
parse_bad() { # <spec>
  local out rc
  out=$(suite_shard_parse "$1" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then ok
  else bad "A: suite_shard_parse accepted the malformed spec '$1' (got '$out')"; fi
  case "$out" in
    *shard*) ok ;;
    *) bad "A: refusing '$1' must say what was wrong, got '$out'" ;;
  esac
}

# Blocks A-C pin the split's PARTITION with no durations at all, where every
# suite weighs the same and the split is sorted names dealt round-robin (and so
# count-balanced). Block E pins the duration balance against a fixture file and
# the library's default path (the file is not committed since BH-5518; CI
# composes it, bin/ci-durations.sh).
export SUITE_DURATIONS_FILE=""

parse_ok "0/4" "0 4"
parse_ok "3/4" "3 4"
parse_ok "0/1" "0 1"
parse_bad "4/4"     # index equals the count — the classic off-by-one
parse_bad "9/4"
parse_bad "-1/4"
parse_bad "1/0"     # zero shards is a division by zero, not "run everything"
parse_bad "1"       # a bare index with no count
parse_bad "1/2/3"
parse_bad "abc"
parse_bad "a/4"
parse_bad "1/b"
parse_bad ""
parse_bad "1/"
parse_bad "/4"
parse_bad "1 / 4"

# ── B. the filter partitions, and does it the same way twice ─────────────────
# Deliberately unsorted, with names whose glob order and sort order differ.
LIST=(
  tests/zeta-test.sh tests/alpha-test.sh tests/mc/one-test.sh
  tests/Beta-test.sh tests/gamma-test.sh tests/delta-test.sh
  tests/epsilon-test.sh tests/eta-test.sh tests/theta-test.sh
  tests/iota-test.sh tests/kappa-test.sh tests/lambda-test.sh
  tests/mu-test.sh
)

# collect_shards <n> <item...> — print every shard's members, one per line,
# prefixed with its shard index so duplicates across shards are visible.
collect_shards() {
  local n="$1"; shift
  local i
  for ((i = 0; i < n; i++)); do
    suite_shard_filter "$i" "$n" "$@" | sed "s|^|$i |"
  done
}

SH=$(collect_shards 4 "${LIST[@]}")
UNION=$(printf '%s\n' "$SH" | cut -d' ' -f2- | LC_ALL=C sort)
WHOLE=$(printf '%s\n' "${LIST[@]}" | LC_ALL=C sort)

if [ "$UNION" = "$WHOLE" ]; then ok
else bad "B: the four shards are not the whole list. missing/extra:
$(diff <(printf '%s\n' "$WHOLE") <(printf '%s\n' "$UNION") | head -10)"; fi

DUPES=$(printf '%s\n' "$UNION" | uniq -d)
if [ -z "$DUPES" ]; then ok; else bad "B: these suites are in more than one shard: $DUPES"; fi

COUNT=$(printf '%s\n' "$SH" | grep -c .)
if [ "$COUNT" -eq "${#LIST[@]}" ]; then ok
else bad "B: the shards hold $COUNT entries for ${#LIST[@]} suites"; fi

# Balance: 13 suites over 4 shards is 4,3,3,3 — never 13,0,0,0.
SIZES=$(printf '%s\n' "$SH" | cut -d' ' -f1 | LC_ALL=C sort | uniq -c | awk '{print $1}' | LC_ALL=C sort -n)
MIN=$(head -1 <<<"$SIZES"); MAX=$(printf '%s\n' "$SIZES" | tail -1)
if [ -n "$MIN" ] && [ -n "$MAX" ] && [ $((MAX - MIN)) -le 1 ]; then ok
else bad "B: the shards are unbalanced (smallest $MIN, largest $MAX)"; fi

AGAIN=$(collect_shards 4 "${LIST[@]}")
if [ "$SH" = "$AGAIN" ]; then ok; else bad "B: two runs over the same list produced different shards"; fi

# The same set in a different order must produce the SAME shards: the split is
# defined on the sorted list, so a caller's glob order cannot move a suite.
REV=()
for ((k = ${#LIST[@]} - 1; k >= 0; k--)); do REV+=("${LIST[$k]}"); done
SHREV=$(collect_shards 4 "${REV[@]}")
if [ "$SH" = "$SHREV" ]; then ok
else bad "B: reordering the input moved suites between shards — the split is not sorted-stable"; fi

# A NEW suite lands in exactly one shard.
WITH=$(collect_shards 4 "${LIST[@]}" tests/nu-new-test.sh)
HITS=$(printf '%s\n' "$WITH" | grep -c ' tests/nu-new-test\.sh$')
if [ "$HITS" -eq 1 ]; then ok; else bad "C: a new suite landed in $HITS shards, not 1"; fi
WITH_UNION=$(printf '%s\n' "$WITH" | cut -d' ' -f2- | LC_ALL=C sort)
WITH_WHOLE=$(printf '%s\n' "${LIST[@]}" tests/nu-new-test.sh | LC_ALL=C sort)
if [ "$WITH_UNION" = "$WITH_WHOLE" ]; then ok
else bad "C: adding one suite broke the partition"; fi

# One shard of one is the whole list — the degenerate case CI falls back to.
ONE=$(suite_shard_filter 0 1 "${LIST[@]}" | LC_ALL=C sort)
if [ "$ONE" = "$WHOLE" ]; then ok; else bad "B: shard 0/1 must be the whole list"; fi

# ── C. the two runners CI calls partition a real scratch tree ────────────────
mkdir -p "$T/c/tests/lib"
printf '#!/bin/bash\n' > "$T/c/tests/lib/scratch.sh"
for n in a b c d e f g h i; do
  cat > "$T/c/tests/$n-test.sh" <<EOF
#!/bin/bash
echo "$n-test: 1 pass, 0 fail"
exit 0
EOF
done
NSUITES=9

# bin/test-suite-run.sh names each suite it runs on a `--- <path>` line.
RUN_UNION=""
RUN_RC_OK=1
for i in 0 1 2 3; do
  OUT=$(bash "$RUNNER" --shard "$i/4" "$T/c/tests" 2>&1); RC=$?
  [ "$RC" -eq 0 ] || { RUN_RC_OK=0; echo "  (shard $i/4 exited $RC: $(printf '%s' "$OUT" | tail -3))"; }
  RUN_UNION="$RUN_UNION$(printf '%s\n' "$OUT" | sed -n 's|^--- ||p')"$'\n'
done
if [ "$RUN_RC_OK" -eq 1 ]; then ok; else bad "C: a green shard of bin/test-suite-run.sh exited nonzero"; fi

RUN_SORTED=$(printf '%s' "$RUN_UNION" | grep -c . )
if [ "$RUN_SORTED" -eq "$NSUITES" ]; then ok
else bad "C: bin/test-suite-run.sh --shard ran $RUN_SORTED of $NSUITES suites across four shards"; fi
RUN_DUPES=$(printf '%s' "$RUN_UNION" | grep . | LC_ALL=C sort | uniq -d)
if [ -z "$RUN_DUPES" ]; then ok; else bad "C: these suites ran in two shards: $RUN_DUPES"; fi

# A malformed spec must refuse, not run everything and not run nothing.
OUT=$(bash "$RUNNER" --shard 4/4 "$T/c/tests" 2>&1); RC=$?
if [ "$RC" -ne 0 ]; then ok; else bad "C: bin/test-suite-run.sh accepted --shard 4/4"; fi
case "$OUT" in *shard*) ok ;; *) bad "C: refusing a bad --shard must say so: $OUT" ;; esac
OUT=$(bash "$RUNNER" --shard 2>&1); RC=$?
if [ "$RC" -ne 0 ]; then ok; else bad "C: bin/test-suite-run.sh accepted --shard with no spec"; fi

# No --shard at all still sweeps the whole tree: the local and hub callers that
# never pass one must be untouched by this change.
OUT=$(bash "$RUNNER" "$T/c/tests" 2>&1); RC=$?
ALL=$(printf '%s\n' "$OUT" | sed -n 's|^--- ||p' | grep -c .)
if [ "$RC" -eq 0 ] && [ "$ALL" -eq "$NSUITES" ]; then ok
else bad "C: an unsharded run swept $ALL of $NSUITES suites (rc=$RC)"; fi

# bin/test-trace-safety.sh --list prints the suites it WOULD trace.
TR_UNION=""
TR_RC_OK=1
for i in 0 1 2 3; do
  OUT=$("$TRACE" --list --shard "$i/4" "$T/c" 2>&1); RC=$?
  [ "$RC" -eq 0 ] || { TR_RC_OK=0; echo "  (trace shard $i/4 exited $RC: $OUT)"; }
  TR_UNION="$TR_UNION$(printf '%s\n' "$OUT" | grep '^tests/')"$'\n'
done
if [ "$TR_RC_OK" -eq 1 ]; then ok; else bad "C: a --list shard of bin/test-trace-safety.sh exited nonzero"; fi
TR_N=$(printf '%s' "$TR_UNION" | grep -c .)
if [ "$TR_N" -eq "$NSUITES" ]; then ok
else bad "C: bin/test-trace-safety.sh --shard listed $TR_N of $NSUITES suites across four shards"; fi
TR_DUPES=$(printf '%s' "$TR_UNION" | grep . | LC_ALL=C sort | uniq -d)
if [ -z "$TR_DUPES" ]; then ok; else bad "C: these suites are traced twice: $TR_DUPES"; fi

OUT=$("$TRACE" --list --shard 9/4 "$T/c" 2>&1); RC=$?
if [ "$RC" -eq 2 ]; then ok
else bad "C: bin/test-trace-safety.sh must exit 2 on a bad --shard (rc=$RC) [$OUT]"; fi

# A LONE COPY of the runner still scans — the mutation and nesting fixtures in
# tests/tests-trace-safety-test.sh both run one, and so does anyone who copies
# it at a box. What a lone copy must NOT do is accept --shard and trace
# everything: it has no split to read, so it says so and exits 2.
mkdir -p "$T/lone"
cp "$TRACE" "$T/lone/test-trace-safety.sh"
chmod 755 "$T/lone/test-trace-safety.sh"
OUT=$("$T/lone/test-trace-safety.sh" --list "$T/c" 2>&1); RC=$?
LONE_N=$(printf '%s\n' "$OUT" | grep -c '^tests/')
if [ "$RC" -eq 0 ] && [ "$LONE_N" -eq "$NSUITES" ]; then ok
else bad "C: a copy of the runner with no lib/ must still list all $NSUITES suites (rc=$RC) [$OUT]"; fi
OUT=$("$T/lone/test-trace-safety.sh" --list --shard 0/4 "$T/c" 2>&1); RC=$?
if [ "$RC" -eq 2 ]; then ok
else bad "C: a copy with no lib/ must refuse --shard rather than trace everything (rc=$RC) [$OUT]"; fi
case "$OUT" in *suite-runner.sh*) ok ;; *) bad "C: that refusal must name the missing library: $OUT" ;; esac

# ── D. the workflow carries the shape ────────────────────────────────────────
# ── E: the split is balanced by DURATION (plan item A2, 2026-09-28) ──────────
# A merge-queue batch waits for its slowest shard. The count-balanced split
# measured 10..23 minutes across eight shards when the even share was ~14.5.
DF="$T/durations.tsv"
printf '# fixture\n' > "$DF"
for row in a:40 b:30 c:20 d:20 e:10 f:10 g:10 h:10 i:5 j:5 k:5 l:5; do
  printf 'tests/%s-test.sh\t%s\trun-1\n' "${row%%:*}" "${row#*:}" >> "$DF"
done
ELIST=(); for x in a b c d e f g h i j k l; do ELIST+=("tests/$x-test.sh"); done

eplan() { SUITE_DURATIONS_FILE="$DF" suite_shard_plan "$@" 2>/dev/null; }
max_over_ideal_pct() { # <plan text> <n> — how far the heaviest shard is past the even share, in %
  printf '%s\n' "$1" | awk -F'\t' -v n="$2" 'NF == 3 { l[$1] += $2; t += $2 }
    END { m = 0; for (s in l) if (l[s] > m) m = l[s]; if (t == 0) { print 999; exit }
          printf "%d\n", (m * n * 100 / t) - 100 }'
}

EP=$(eplan 4 "${ELIST[@]}")
PCT=$(max_over_ideal_pct "$EP" 4)
if [ -n "$EP" ] && [ "$PCT" -le 10 ]; then ok
else bad "E: with known durations the heaviest of 4 shards is ${PCT:-?}% past the even share (want <= 10%):
$EP"; fi

EUNION=$(printf '%s\n' "$EP" | cut -f3 | LC_ALL=C sort)
EWHOLE=$(printf '%s\n' "${ELIST[@]}" | LC_ALL=C sort)
[ -n "$EP" ] && [ "$EUNION" = "$EWHOLE" ] && ok || bad "E: the duration split did not place every suite exactly once"

FUNION=$(for i in 0 1 2 3; do SUITE_DURATIONS_FILE="$DF" suite_shard_filter "$i" 4 "${ELIST[@]}"; done | LC_ALL=C sort)
[ "$FUNION" = "$EWHOLE" ] && ok || bad "E: suite_shard_filter's four shards are not the duration plan's partition"
F0=$(SUITE_DURATIONS_FILE="$DF" suite_shard_filter 0 4 "${ELIST[@]}")
P0=$(printf '%s\n' "$EP" | awk -F'\t' '$1 == 0 { print $3 }' | LC_ALL=C sort)
[ -n "$F0" ] && [ "$F0" = "$P0" ] && ok || bad "E: shard 0 of suite_shard_filter is not shard 0 of suite_shard_plan"

# The same balance read off what the runners actually call, with the weights
# taken from the fixture rather than from the plan's own column.
FP=$(for i in 0 1 2 3; do SUITE_DURATIONS_FILE="$DF" suite_shard_filter "$i" 4 "${ELIST[@]}" | sed "s|^|$i |"; done \
  | awk -v df="$DF" 'BEGIN { FS = "\t"; while ((getline l < df) > 0) { split(l, f, "\t"); w[f[1]] = f[2] * 1000 }; FS = " " }
                    { print $1 "\t" w[$2] "\t" $2 }')
FPCT=$(max_over_ideal_pct "$FP" 4)
[ "$FPCT" -le 10 ] && ok || bad "E: suite_shard_filter's heaviest of 4 shards is ${FPCT}% past the even share (want <= 10%)"

[ "$EP" = "$(eplan 4 "${ELIST[@]}")" ] && ok || bad "E: two plans over the same inputs differ"
EREV=(); for ((k = ${#ELIST[@]} - 1; k >= 0; k--)); do EREV+=("${ELIST[$k]}"); done
[ "$EP" = "$(eplan 4 "${EREV[@]}")" ] && ok || bad "E: reordering the input changed the duration plan"

# A suite the file does not name weighs the file's median (5,5,5,5,10,10,10,10,
# 20,20,30,40 -> 10 s) and is placed exactly once.
NP=$(eplan 4 "${ELIST[@]}" tests/zz-new-test.sh)
NROW=$(printf '%s\n' "$NP" | awk -F'\t' '$3 == "tests/zz-new-test.sh"')
[ "$(grep -c . <<<"$NROW")" -eq 1 ] && ok || bad "E: a suite with no duration was placed $(grep -c . <<<"$NROW") times"
[ "$(printf '%s\n' "$NROW" | cut -f2)" = "10000" ] && ok || bad "E: a suite with no duration must weigh the median (10000 ms), got '$NROW'"

# An absolute path (bin/test-trace-safety.sh's shape) weighs what the relative one does.
AW=$(eplan 2 "/x/root/tests/a-test.sh" | cut -f2)
[ "$AW" = "40000" ] && ok || bad "E: /x/root/tests/a-test.sh must weigh tests/a-test.sh's 40 s, got '$AW'"

# The default path. catalog/ci-suite-durations.tsv is not committed (BH-5518:
# CI composes it and hands it over as SUITE_DURATIONS_FILE), but a local fetch
# writes it there, so with the override unset the library must still find it
# next to itself. A scratch tree with the library and the fixture at that path.
# scratch-closure-allow: the library alone is the subject, beside a fixture catalog/
mkdir -p "$T/dp/bin/lib" "$T/dp/catalog"
cp "$DIR/bin/lib/suite-runner.sh" "$T/dp/bin/lib/" && cp "$DF" "$T/dp/catalog/ci-suite-durations.tsv"
DP=$(unset SUITE_DURATIONS_FILE; . "$T/dp/bin/lib/suite-runner.sh" && suite_shard_plan 4 "${ELIST[@]}" 2>/dev/null)
[ -n "$DP" ] && [ "$DP" = "$EP" ] && ok || bad "E: with no override the library must read catalog/ci-suite-durations.tsv beside it:
$DP"

[ -f "$WF" ] || { echo "FAIL: workflow not found at $WF"; echo "ci-shard-split-test.sh: $PASS passed, $((FAIL+1)) failed"; exit 1; }

# The block of one top-level job, read positionally so a missing job is empty
# rather than the next job's steps.
job_block() {
  awk -v want="$1" '
    /^  [a-zA-Z0-9_-]+:/ { inblk = ($0 ~ "^  "want":[[:space:]]*$") }
    inblk { print }
  ' "$WF"
}
# The `name:` of one job block.
job_name() { printf '%s\n' "$1" | sed -n 's|^    name: ||p' | head -1; }

# ONE TRACED MATRIX, TWO FAN-INS (CI cost cut, 2026-09-24). Until then this
# section pinned two fixed 8-way matrices, one bare and one traced, that ran the
# same corpus twice. Now `tests-shard` runs it once under
# bin/test-trace-safety.sh --gate, sized by the plan job, and each fan-in judges
# its own verdict. Every invariant the old shape carried is carried here:
# stable fan-in names, a shard index in every shard name, fail-fast off, the
# /N the runner is handed equal to the matrix's size (now: both are the plan's
# outputs), the fan-ins run if: !cancelled() and refuse missing evidence, and every
# job reads vars.CI_RUNNER.
SB=$(job_block tests-shard)
if [ -n "$SB" ]; then ok; else bad "D: no 'tests-shard:' job in the workflow"; fi

# The corpus runs ONCE: no job other than tests-shard may execute it. A second
# copy is exactly the ~49% of billed minutes the merge of the lanes removed.
for OLD in decisions-shard harness-safety-shard; do
  [ -z "$(job_block "$OLD")" ] && ok || bad "D: the '$OLD' job is back — the corpus would run twice per CI run"
done
RUNNERS=$(awk '
  /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ { job = $1; sub(/:$/, "", job) }
  /^[[:space:]]*#/ { next }
  /bin\/test-suite-run\.sh|bin\/test-trace-safety\.sh/ { print job }' "$WF" | LC_ALL=C sort -u | tr '\n' ' ')
[ "$RUNNERS" = "tests-shard " ] && ok || bad "D: only tests-shard may run the corpus, found it in: $RUNNERS"

NAME=$(job_name "$SB")
case "$NAME" in *'${{ matrix.shard }}'*) ok ;; *) bad "D: the shard job must name its shard index, found '$NAME'" ;; esac
case "$NAME" in *'needs.plan.outputs.n'*) ok ;; *) bad "D: the shard job must name the shard count it was planned for, found '$NAME'" ;; esac
case "$NAME" in "Pure-logic gate fixtures"|"Tests cannot touch a real harness") bad "D: a shard must never carry a required check's bare name" ;; *) ok ;; esac

# The matrix IS the plan's list of shard indexes, and the runner's /N is the
# plan's n — the two values the old test compared as literals. ci-plan.sh
# derives both from one number (tests/ci-plan-test.sh P4), so they cannot drift.
grep -q '^        shard: \${{ fromJSON(needs.plan.outputs.shards) }}$' <<<"$SB" && ok \
  || bad "D: tests-shard's matrix must be 'shard: \${{ fromJSON(needs.plan.outputs.shards) }}'"
case "$SB" in *"fail-fast: false"*) ok ;; *) bad "D: tests-shard must set fail-fast: false, or one red shard hides the rest" ;; esac
grep -q '^    needs: \[plan\]$' <<<"$SB" && ok || bad "D: tests-shard must need the plan job"
grep -q "SHARD: \${{ matrix.shard }}" <<<"$SB" && ok || bad "D: the suite step must take SHARD from matrix.shard, not a typed number"
grep -q "PLAN_N: \${{ needs.plan.outputs.n }}" <<<"$SB" && ok || bad "D: the suite step must take PLAN_N from the plan"
CMD=$(printf '%s\n' "$SB" | grep -v '^[[:space:]]*#' | awk '/bin\/test-trace-safety\.sh --gate/ { on = 1 } on { print } on && !/\\$/ { exit }' | tr -s ' \n' ' ')
case "$CMD" in *'--shard "$SHARD/$PLAN_N"'*) ok ;; *) bad "D: the tracer must get --shard \"\$SHARD/\$PLAN_N\", got: $CMD" ;; esac
case "$CMD" in *'--only-file "$RUNNER_TEMP/impact.txt"'*) ok ;; *) bad "D: the tracer must be narrowed to the plan's list, got: $CMD" ;; esac
case "$CMD" in *'--verdict "$RUNNER_TEMP/verdict/shard-$SHARD.txt"'*) ok ;; *) bad "D: the tracer must write the shard's verdict file, got: $CMD" ;; esac
# The re-plan must be held to the plan job's count.
grep -q 'bin/ci-plan.sh --out "$RUNNER_TEMP/impact.txt" --expect-n "$PLAN_N"' <<<"$SB" && ok \
  || bad "D: tests-shard must re-plan with --expect-n the plan job's n"
# The verdict leaves the shard whatever the suite step answered.
UP=$(printf '%s\n' "$SB" | awk '/uses: actions\/upload-artifact@/ { on = 1 } on { print }')
case "$UP" in *'name: verdict-${{ matrix.shard }}'*) ok ;; *) bad "D: each shard must upload verdict-<shard>" ;; esac
printf '%s\n' "$SB" | grep -B1 'uses: actions/upload-artifact@' | grep -q 'if: always()' && ok \
  || bad "D: the verdict upload must run if: always(), or a red shard's verdict never reaches the fan-ins"
# HARNESS_TEST_SANDBOX is never set on the traced lane (the #388 guards).
if printf '%s\n' "$SB" | grep -v '^[[:space:]]*#' | grep -q 'HARNESS_TEST_SANDBOX'; then
  bad "D: tests-shard must NOT set HARNESS_TEST_SANDBOX — it disarms the root guards that stopped the #388 wipe"
else ok; fi

check_fanin() { # <fan-in-job-id> <stable check name> <ci-verdicts lane>
  local FB NAME NEEDS
  FB=$(job_block "$1")
  if [ -n "$FB" ]; then ok; else bad "D: no '$1:' fan-in job in the workflow"; return; fi
  NAME=$(job_name "$FB")
  [ "$NAME" = "$2" ] && ok || bad "D: the fan-in job '$1' must stay named '$2' (found '$NAME')"
  NEEDS=$(printf '%s\n' "$FB" | sed -n 's|^    needs: ||p' | head -1)
  case "$NEEDS" in *tests-shard*) ok ;; *) bad "D: '$1' must need tests-shard, found '$NEEDS'" ;; esac
  case "$NEEDS" in *plan*) ok ;; *) bad "D: '$1' must need plan (its count is what the verdicts are held to), found '$NEEDS'" ;; esac
  case "$FB" in *'if: ${{ !cancelled() && ('*) ok ;; *) bad "D: '$1' must run with if: !cancelled() && (...), or a red shard skips the gate" ;; esac
  case "$FB" in *"PLAN_RESULT: \${{ needs.plan.result }}"*) ok ;; *) bad "D: '$1' must hand needs.plan.result to bin/ci-verdicts.sh" ;; esac
  case "$FB" in *"bin/ci-verdicts.sh $3 "*) ok ;; *) bad "D: '$1' must judge with bin/ci-verdicts.sh $3" ;; esac
  case "$FB" in *"pattern: verdict-*"*) ok ;; *) bad "D: '$1' must download the shards' verdict-* artifacts" ;; esac
  case "$FB" in *'runs-on: ${{ fromJSON(vars.CI_RUNNER'*) ok ;; *) bad "D: '$1' must read vars.CI_RUNNER, not name a runner (BH-1206)" ;; esac
}
check_fanin decisions "Pure-logic gate fixtures" pure
check_fanin harness-safety "Tests cannot touch a real harness" trace
case "$SB" in *'runs-on: ${{ fromJSON(vars.CI_RUNNER'*) ok ;; *) bad "D: tests-shard must read vars.CI_RUNNER, not name a runner (BH-1206)" ;; esac

# The single-run checks stay single: the determinism lint and the static
# scratch-only check must not be inside a matrix job.
if [ -n "$(job_block determinism)" ]; then ok; else bad "D: the determinism job disappeared"; fi
case "$(job_block determinism)" in
  *matrix*) bad "D: the determinism lint must stay a single run" ;;
  *) ok ;;
esac
case "$(job_block harness-safety)" in
  *"bin/checks-run.sh --tree"*) ok ;;
  *) bad "D: the static scratch-only check must stay in the single fan-in job" ;;
esac

echo "ci-shard-split-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
