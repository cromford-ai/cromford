#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/ci-test-value-infra-flake.bh-6618-test.sh — BH-6637 (BH-6618.1): the
# infra and flake rules of the CI test value report's rule registry.
#
#   I1.cancelled  I2.step  I3.pattern   bin/lib/ci-test-value/rules.d/10-infra.sh
#   F1.same-head-green                  bin/lib/ci-test-value/rules.d/20-flake.sh
#   F2.main-unrelated-green             bin/lib/ci-test-value/rules.d/50-main-flake.sh
#
# Rule rows call ctv_classify_row (the real registry) with the CTV_* row vars
# set and a `gh` shim first on PATH. The shim serves
# tests/fixtures/bh-6618/infra-flake/ and refuses any call that is not a REST
# GET. The E2E rows run bin/ci-test-value-report.sh over the same fixtures.
set -uo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
CLI="$REPO_DIR/bin/ci-test-value-report.sh"
LIB="$REPO_DIR/bin/lib/ci-test-value.sh"
GHREST="$REPO_DIR/bin/lib/gh-rest.sh"
R_INFRA="$REPO_DIR/bin/lib/ci-test-value/rules.d/10-infra.sh"
R_FLAKE="$REPO_DIR/bin/lib/ci-test-value/rules.d/20-flake.sh"
R_MAIN="$REPO_DIR/bin/lib/ci-test-value/rules.d/50-main-flake.sh"
CAT_STEPS="$REPO_DIR/catalog/ci-test-value/infra-steps.tsv"
CAT_PATTERNS="$REPO_DIR/catalog/ci-test-value/infra-patterns.tsv"
FIX="$REPO_DIR/tests/fixtures/bh-6618/infra-flake"
SUITE=tests/ci-test-value-infra-flake.bh-6618-test.sh
CTV_TEST_NOW=1791979200 # 2026-10-14T12:00:00Z
TAB=$'\t'
REPO=example-org/cromford

FAILS=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi
}
for f in "$CLI" "$LIB" "$GHREST" "$R_INFRA" "$R_FLAKE" "$R_MAIN" "$CAT_STEPS" "$CAT_PATTERNS"; do
  [ -f "$f" ] || bad "missing source file ${f#"$REPO_DIR"/}"
done
h40() { local o=; while [ ${#o} -lt 40 ]; do o+=$1; done; printf '%s' "${o:0:40}"; }

# ── shims ───────────────────────────────────────────────────────────────────
mkdir -p "$T/bin" "$T/h/state" "$T/h/logs"
cat > "$T/bin/gh" <<'SHIM'
#!/bin/bash
log="${SHIM_LOG:?}"; fix="${SHIM_FIX:?}"
refuse() { echo "REFUSED $*" >> "$log.refused"; exit 99; }
[ "${1:-}" = api ] || refuse "$@"
shift
for a in "$@"; do [ "$a" = --help ] && { echo "      --allow-escape-sequences   Allow printing terminal escape sequences"; exit 0; }; done
m=GET inc=0 path=
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--method) m="${2:-}"; shift 2 ;;
    -i|--include) inc=1; shift ;;
    -H|--header|--jq|-q|--cache|-t|--template) shift 2 ;;
    -f|-F|--field|--raw-field|--input) refuse "field $*" ;;
    -*) shift ;;
    *) [ -z "$path" ] && path="$1"; shift ;;
  esac
done
[ "$m" = GET ] || refuse "method $m $path"
echo "GET $path" >> "$log"
st=200 f=
if [ -n "${SHIM_FAIL_RE:-}" ] && [[ "$path" =~ $SHIM_FAIL_RE ]]; then
  st=502
else
  q="&${path#*\?}&"
  case "$path" in
    rate_limit) f="$fix/rate-limit-healthy.json" ;;
    repos/*/actions/workflows/harness-ci.yml/runs\?*)
      d=$(sed -n 's/.*&created=\([0-9-]*\)&.*/\1/p' <<<"$q")
      if [[ "$q" == *"&status=failure&"* ]]; then f="$fix/runs/$d-fail-p1.json"; else f="$fix/runs/$d-all.json"; fi ;;
    repos/*/actions/workflows/*/runs\?*)
      w=${path#*/actions/workflows/}; w=${w%%/*}
      d=$(sed -n 's/.*&created=\([0-9-]*\)\.\..*/\1/p' <<<"$q")
      f="$fix/main-green/$w-$d.json" ;;
    repos/*/actions/runs\?*)
      s=$(sed -n 's/.*&head_sha=\([0-9a-f]*\)&.*/\1/p' <<<"$q")
      f="$fix/heads/$s.json" ;;
    repos/*/actions/runs/*/attempts/*/jobs\?*)
      r=${path#*/actions/runs/}; id=${r%%/*}; a=${r#*/attempts/}; a=${a%%/*}
      f="$fix/jobs/$id-a$a.json" ;;
    repos/*/actions/jobs/*/logs)
      j=${path#*/actions/jobs/}; j=${j%%/*}
      f="$fix/joblogs/$j.txt" ;;
    repos/*/compare/*) f="$fix/compare/${path#*/compare/}.json" ;;
  esac
  [ -n "$f" ] && [ -f "$f" ] || st=404
fi
[ "$inc" = 1 ] && printf 'HTTP/2.0 %s fixture\r\nContent-Type: application/json\r\n\r\n' "$st"
if [ "$st" = 200 ]; then cat "$f"; exit 0; fi
printf '{"message":"fixture %s"}\n' "$st"
exit 1
SHIM
cat > "$T/bin/curl" <<'SHIM'
#!/bin/bash
m=GET prev=
for a in "$@"; do case "$prev" in -X|--request) m="$a" ;; esac; prev="$a"; done
[ "$m" = GET ] || { echo "REFUSED curl $m" >> "${SHIM_LOG:?}.refused"; exit 99; }
printf '\n404'
SHIM
chmod +x "$T/bin/gh" "$T/bin/curl"

# rule <case> [NAME=V ...] — one ctv_classify_row through the real registry, in
# a subshell, with the shim on PATH. Prints `class\trule\twhy`.
rule() {
  local c="$1"; shift
  ( export PATH="$T/bin:$PATH" HARNESS="$T/h" HARNESS_TEST_SANDBOX=1 GH_TOKEN=tok-fixture-ctv \
      SHIM_LOG="$T/$c.shim" SHIM_FIX="$FIX" GH_ETAG=0
    unset CTV_RULES_DIR
    . "$GHREST" && . "$LIB" || exit 1
    CTV_GH_READS=0 CTV_GH_MAX_READS=3000 CTV_BUDGET_CHECK=0 CTV_STOP=
    while [ $# -gt 0 ]; do printf -v "${1%%=*}" '%s' "${1#*=}"; export "${1%%=*}"; shift; done
    ctv_classify_row )
}
gets() { [ -f "$1" ] || { echo 0; return; }; grep -c -v ' rate_limit$' "$1" || true; }
cnt() { [ -f "$2" ] || { echo 0; return; }; grep -c -e "$1" "$2" || true; } # cnt <re> <file>
ledger() { cat "$1"/.rules-scratch/*/reads 2>/dev/null | grep -c . || true; }

# ── CAT: the two catalogs ───────────────────────────────────────────────────
for cf in "$CAT_STEPS" "$CAT_PATTERNS"; do
  n=0 badrow=
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    n=$((n + 1))
    re=${line%%"$TAB"*}; why=${line#*"$TAB"}
    { [[ "$line" == *"$TAB"* ]] && [ -n "$re" ] && [ -n "$why" ] && [[ "$why" != *"$TAB"* ]]; } || badrow+="[$line] "
    rc=0; printf '' | LC_ALL=C grep -Eq -e "$re" 2>/dev/null || rc=$?
    [ "$rc" = 2 ] && badrow+="[bad ERE $re] "
  done < "$cf"
  check "CAT ${cf##*/}: every row is <ERE>\\t<why> and grep accepts the ERE" "" "$badrow"
  [ "$n" -ge 6 ] && ok "CAT ${cf##*/}: $n rows" || bad "CAT ${cf##*/}: only $n rows"
done
hits=
for s in "run the traced corpus" "trace shard" "worker-jobs unit tests" "console-ui unit tests" "fan-in"; do
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    re=${line%%"$TAB"*}
    [[ "$s" =~ $re ]] && hits+="[$s ~ $re] "
  done < "$CAT_STEPS"
done
check "CAT no infra-steps row matches a test step name" "" "$hits"

# ── I1.cancelled ────────────────────────────────────────────────────────────
check "I1 + cancelled job, job: row" "infra${TAB}I1.cancelled${TAB}job cancelled, the log names no failed unit" \
  "$(rule i1a CTV_JOB_CONCLUSION=cancelled CTV_UNIT=job:console-ui)"
check "I1 + timed_out job, job: row" "infra${TAB}I1.cancelled${TAB}job timed_out, the log names no failed unit" \
  "$(rule i1b CTV_JOB_CONCLUSION=timed_out "CTV_UNIT=job:trace shard (2/4)")"
check "I1 - timed_out job with a named unit rc 124" "unknown${TAB}U1.undecided${TAB}" \
  "$(rule i1c CTV_JOB_CONCLUSION=timed_out CTV_UNIT=tests/delta-fixture-test.sh CTV_RC=124 "CTV_STEP=trace shard")"
check "I1 - failure job with a job: row" "unknown${TAB}U1.undecided${TAB}" \
  "$(rule i1d CTV_JOB_CONCLUSION=failure CTV_UNIT=job:x)"
printf 'cat: catalog/lanes.json: No such file or directory\n' > "$T/ex-lanes.txt"
check "I-order a cancelled job: row whose step and excerpt also match is I1" "infra${TAB}I1.cancelled" \
  "$(rule io CTV_JOB_CONCLUSION=cancelled CTV_UNIT=job:x "CTV_STEP=install semgrep" CTV_EXCERPT_FILE="$T/ex-lanes.txt" | cut -f1-2)"

# ── I2.step ─────────────────────────────────────────────────────────────────
why_of() { grep -v '^#' "$1" | grep -F -m1 "$2$TAB" | cut -f2; }
check "I2 + install semgrep" "infra${TAB}I2.step${TAB}$(why_of "$CAT_STEPS" '^(I|i)nstall ')" \
  "$(rule i2a CTV_JOB_CONCLUSION=failure CTV_UNIT=job:lint "CTV_STEP=install semgrep")"
check "I2 + Set up job" "infra${TAB}I2.step${TAB}$(why_of "$CAT_STEPS" '^Set up job$')" \
  "$(rule i2b CTV_JOB_CONCLUSION=failure CTV_UNIT=job:lint "CTV_STEP=Set up job")"
check "I2 - run the traced corpus" "unknown${TAB}U1.undecided${TAB}" \
  "$(rule i2c CTV_JOB_CONCLUSION=failure CTV_UNIT=tests/a-fixture-test.sh "CTV_STEP=run the traced corpus")"
check "I2 - trace shard" "unknown${TAB}U1.undecided${TAB}" \
  "$(rule i2d CTV_JOB_CONCLUSION=failure CTV_UNIT=tests/a-fixture-test.sh "CTV_STEP=trace shard")"

# ── I3.pattern ──────────────────────────────────────────────────────────────
printf 'curl: (28) Operation timed out after 30001 milliseconds\n' > "$T/ex-curl28.txt"
printf 'FAIL: expected rate limit message, got none\n' > "$T/ex-ratelimit.txt"
printf 'curl: (22) The requested URL returned error: 404\n' > "$T/ex-curl22.txt"
check "I3 + catalog/lanes.json: No such file" "infra${TAB}I3.pattern${TAB}$(why_of "$CAT_PATTERNS" 'catalog/lanes\.json: No such file')" \
  "$(rule i3a CTV_JOB_CONCLUSION=failure CTV_UNIT=tests/a-fixture-test.sh CTV_RC=1 "CTV_STEP=trace shard" CTV_EXCERPT_FILE="$T/ex-lanes.txt")"
check "I3 + curl: (28)" "infra${TAB}I3.pattern${TAB}$(why_of "$CAT_PATTERNS" 'curl: \((6|7|28|35)\)')" \
  "$(rule i3b CTV_JOB_CONCLUSION=failure CTV_UNIT=tests/a-fixture-test.sh CTV_RC=1 CTV_EXCERPT_FILE="$T/ex-curl28.txt")"
check "I3 - an assertion that prints 'rate limit', rc 1" "unknown${TAB}U1.undecided${TAB}" \
  "$(rule i3c CTV_JOB_CONCLUSION=failure CTV_UNIT=tests/a-fixture-test.sh CTV_RC=1 CTV_EXCERPT_FILE="$T/ex-ratelimit.txt")"
check "I3 - curl: (22) is an HTTP answer, not infra" "unknown${TAB}U1.undecided${TAB}" \
  "$(rule i3d CTV_JOB_CONCLUSION=failure CTV_UNIT=tests/a-fixture-test.sh CTV_RC=1 CTV_EXCERPT_FILE="$T/ex-curl22.txt")"
check "I3 - an excerpt file that does not exist" "unknown${TAB}U1.undecided${TAB}" \
  "$(rule i3e CTV_JOB_CONCLUSION=failure CTV_UNIT=tests/a-fixture-test.sh CTV_RC=1 CTV_EXCERPT_FILE="$T/nope.txt")"

# ── F1.same-head-green ──────────────────────────────────────────────────────
f1() { # f1 <case> <sha> <run> <attempt> [NAME=V ...]
  local c=$1 s=$2 r=$3 a=$4; shift 4
  rule "$c" CTV_OUT="$T/out-$c" CTV_REPO=$REPO CTV_EVENT=pull_request CTV_HEAD_BRANCH=fx CTV_HEAD_SHA="$s" \
    CTV_WORKFLOW_ID=5100001 CTV_RUN_ID="$r" CTV_ATTEMPT="$a" CTV_JOB_CONCLUSION=failure \
    "CTV_JOB_NAME=trace shard (1/4)" "CTV_STEP=trace shard" CTV_UNIT=tests/a-fixture-test.sh CTV_RC=1 "$@"
}
check "F1 + a sibling run of the same workflow is green on the same head" \
  "flake${TAB}F1.same-head-green${TAB}run 9400002 attempt 1 green on the same head" "$(f1 f1a "$(h40 c1)" 9400001 1)"
check "F1 + the row's own run is green on a later attempt" \
  "flake${TAB}F1.same-head-green${TAB}run 9400011 attempt 2 green on the same head" "$(f1 f1b "$(h40 c2)" 9400011 1)"
check "F1 + the same job is green on another attempt of this run" \
  "flake${TAB}F1.same-head-green${TAB}job trace shard (1/4) green on attempt 1 of this run" "$(f1 f1c "$(h40 c3)" 9400021 2)"
grep -q 'runs/9400021/attempts/1/jobs' "$T/f1c.shim" && ok "F1 step b read attempt 1's jobs" || bad "F1 step b did not read attempt 1"
grep -q 'runs/9400021/attempts/2/jobs' "$T/f1c.shim" && bad "F1 step b read the row's own attempt" || ok "F1 step b skips the row's own attempt"
[ -s "$T/out-f1c/cache/run/9400021-a1-jobs.json" ] && ok "F1 an attempt's jobs use the driver's cache key" || bad "F1 no cache/run/9400021-a1-jobs.json"
check "F1 - another job name green on attempt 1 does not count" "unknown${TAB}U1.undecided${TAB}" \
  "$(f1 f1c2 "$(h40 c3)" 9400021 2 CTV_JOB_NAME=other-job)"
check "F1 - green only on a different head of the same PR (the API returned it)" "unknown${TAB}U1.undecided${TAB}" \
  "$(f1 f1d "$(h40 c4)" 9400031 1)"
check "F1 - only cancelled, skipped, neutral or in-progress siblings" "unknown${TAB}U1.undecided${TAB}" \
  "$(f1 f1e "$(h40 c6)" 9400041 1)"
check "F1 - green only in another workflow on the same head" "unknown${TAB}U1.undecided${TAB}" \
  "$(f1 f1f "$(h40 c7)" 9400051 1)"
check "F1 - the head list answers 502" "unknown${TAB}U1.undecided${TAB}" \
  "$(f1 f1g "$(h40 c1)" 9400001 1 SHIM_FAIL_RE='head_sha=')"
check "F1 - a 502 head list leaves no file under cache/" "" "$(find "$T/out-f1g/cache" -type f 2>/dev/null)"
check "F1 - a row with no CTV_OUT reads nothing" "unknown${TAB}U1.undecided${TAB}" \
  "$(rule f1h CTV_REPO=$REPO CTV_HEAD_SHA="$(h40 c1)" CTV_WORKFLOW_ID=5100001 CTV_RUN_ID=9400001 CTV_ATTEMPT=1 CTV_UNIT=tests/a-fixture-test.sh)"
[ -s "$T/f1h.shim" ] && bad "F1 - a row with no CTV_OUT sent a GET" || ok "F1 - a row with no CTV_OUT sends no GET"
# A file where the scratch dir goes: mkdir fails, as root too.
mkdir -p "$T/out-ro"; : > "$T/out-ro/.rules-scratch"
check "F1 - no scratch dir decides nothing" "unknown${TAB}U1.undecided${TAB}" "$(rule f1i CTV_OUT="$T/out-ro" CTV_REPO=$REPO \
  CTV_HEAD_SHA="$(h40 c1)" CTV_WORKFLOW_ID=5100001 CTV_RUN_ID=9400001 CTV_ATTEMPT=1 CTV_UNIT=tests/a-fixture-test.sh 2>/dev/null)"
[ -s "$T/f1i.shim" ] && bad "F1 - no scratch dir still sent a GET" || ok "F1 - no scratch dir sends no GET"
check "F1 - no scratch dir: I3 still decides" "infra${TAB}I3.pattern" "$(rule f1j CTV_OUT="$T/out-ro" CTV_REPO=$REPO \
  CTV_HEAD_SHA="$(h40 c1)" CTV_WORKFLOW_ID=5100001 CTV_RUN_ID=9400001 CTV_ATTEMPT=1 CTV_UNIT=tests/a-fixture-test.sh \
  CTV_EXCERPT_FILE="$T/ex-lanes.txt" 2>/dev/null | cut -f1-2)"

# ── RR: the rule read ledger and the per-run memo ───────────────────────────
C9=$(h40 c9)
RRO="$T/out-rr"
( export PATH="$T/bin:$PATH" HARNESS="$T/h" HARNESS_TEST_SANDBOX=1 GH_TOKEN=tok-fixture-ctv SHIM_LOG="$T/rr.shim" SHIM_FIX="$FIX" GH_ETAG=0
  unset CTV_RULES_DIR
  . "$GHREST" && . "$LIB" || exit 1
  CTV_GH_READS=0 CTV_GH_MAX_READS=3000 CTV_BUDGET_CHECK=0 CTV_STOP=
  CTV_OUT=$RRO CTV_REPO=$REPO CTV_EVENT=pull_request CTV_HEAD_SHA=$C9 CTV_WORKFLOW_ID=5100001 CTV_RUN_ID=9400091 CTV_ATTEMPT=1
  CTV_JOB_CONCLUSION=failure CTV_JOB_NAME=lint
  for u in tests/a-fixture-test.sh tests/b-fixture-test.sh tests/c-fixture-test.sh; do
    CTV_UNIT=$u
    IFS=$'\t' read -r cls rl _ < <(ctv_classify_row)   # the driver's own call shape
    echo "$cls $rl"
  done ) > "$T/rr.out" 2>&1
check "RR three rows of one head: all undecided" "unknown U1.undecided
unknown U1.undecided
unknown U1.undecided" "$(cat "$T/rr.out")"
check "RR three rows of one head: one head_sha GET" 1 "$(cnt 'head_sha=' "$T/rr.shim")"
check "RR the ledger holds one line per rule GET" "$(gets "$T/rr.shim")" "$(ledger "$RRO")"
check "RR max-reads spent: undecided" "unknown${TAB}U1.undecided${TAB}" \
  "$(f1 rrm "$(h40 c1)" 9400001 1 CTV_GH_READS=5 CTV_GH_MAX_READS=5)"
check "RR max-reads spent: zero GETs" 0 "$(gets "$T/rrm.shim")"
# The ledger makes the budget see reads of earlier rows: budget 1, two heads.
( export PATH="$T/bin:$PATH" HARNESS="$T/h" HARNESS_TEST_SANDBOX=1 GH_TOKEN=tok-fixture-ctv SHIM_LOG="$T/rrb.shim" SHIM_FIX="$FIX" GH_ETAG=0
  unset CTV_RULES_DIR
  . "$GHREST" && . "$LIB" || exit 1
  CTV_GH_READS=0 CTV_GH_MAX_READS=1 CTV_BUDGET_CHECK=0 CTV_STOP=
  CTV_OUT="$T/out-rrb" CTV_REPO=$REPO CTV_EVENT=pull_request CTV_WORKFLOW_ID=5100001 CTV_ATTEMPT=1 CTV_UNIT=tests/a-fixture-test.sh
  CTV_HEAD_SHA=$C9 CTV_RUN_ID=9400091 ctv_classify_row
  CTV_HEAD_SHA=$(h40 c1) CTV_RUN_ID=9400001 ctv_classify_row ) > "$T/rrb.out" 2>&1
check "RR budget 1 over two rows: one GET in all, the second row is not decided" "1 unknown${TAB}U1.undecided${TAB}" \
  "$(gets "$T/rrb.shim") $(sed -n 2p "$T/rrb.out")"
check "RR budget 1: the ledger has the one read" 1 "$(ledger "$T/out-rrb")"
# A new run (another driver pid) removes the old run's scratch dir. Every row
# above ran under this suite's pid, so the rr dir is renamed to a runid that
# is not this one: to the next row it is an earlier run's dir.
for x in "$RRO"/.rules-scratch/*; do mv "$x" "$RRO/.rules-scratch/1-1"; done
f1 rrn "$C9" 9400091 1 CTV_OUT="$RRO" > /dev/null
check "RR a new run keeps only its own scratch dir" 1 "$(find "$RRO/.rules-scratch" -mindepth 1 -maxdepth 1 -type d | grep -c .)"
check "RR a new run reads the head list again (the memo is per run)" 1 "$(cnt 'head_sha=' "$T/rrn.shim")"

# ── F2.main-unrelated-green ─────────────────────────────────────────────────
M0=$(h40 d0)
f2() { # f2 <case> <workflow> [NAME=V ...]
  local c=$1 w=$2; shift 2
  rule "$c" CTV_OUT="$T/out-$c" CTV_REPO=$REPO CTV_EVENT=push CTV_HEAD_BRANCH=main CTV_HEAD_SHA="$M0" CTV_DAY=2026-10-14 \
    CTV_WORKFLOW_ID="$w" CTV_RUN_ID=9500001 CTV_ATTEMPT=1 CTV_JOB_CONCLUSION=failure "CTV_JOB_NAME=trace shard (1/4)" \
    "CTV_STEP=trace shard" CTV_UNIT=$SUITE CTV_RC=1 CTV_F2_IMPACT_MAP="$FIX/impact-map.tsv" "$@"
}
check "F2 + the next green push run changed only docs/x.md" \
  "flake${TAB}F2.main-unrelated-green${TAB}next green push run 9500002 at $(h40 1a | cut -c1-12), 1 changed path(s) do not reach $SUITE" \
  "$(f2 f2a 5200001)"
grep -q "compare/$M0\.\.\.$(h40 1a)$" "$T/f2a.shim" && ok "F2 compare reads <red sha>...<green sha>" || bad "F2 compare path: $(grep compare "$T/f2a.shim")"
[ -s "$T/out-f2a/cache/f2/compare-$M0-$(h40 1a).json" ] && ok "F2 a compare of two fixed shas is cached" || bad "F2 the compare was not cached"
check "F2 + ahead by 1 with an empty file list" \
  "flake${TAB}F2.main-unrelated-green${TAB}next green push run 9500002 at $(h40 2a | cut -c1-12), 0 changed path(s) do not reach $SUITE" \
  "$(f2 f2b 5200002)"
check "F2 - a changed path the map links to the unit" "unknown${TAB}U1.undecided${TAB}" "$(f2 f2c 5200003)"
check "F2 - the unit itself was renamed away" "unknown${TAB}U1.undecided${TAB}" "$(f2 f2d 5200004)"
check "F2 - compare 404" "unknown${TAB}U1.undecided${TAB}" "$(f2 f2e 5200005)"
check "F2 - compare 404 is not cached" "" "$(find "$T/out-f2e/cache/f2" -type f 2>/dev/null)"
check "F2 - compare 502" "unknown${TAB}U1.undecided${TAB}" "$(f2 f2e2 5200001 SHIM_FAIL_RE='/compare/')"
check "F2 - a changed path the map does not know (select says full: unknown reach)" "unknown${TAB}U1.undecided${TAB}" "$(f2 f2u 5200009)"
check "F2 - compare diverged" "unknown${TAB}U1.undecided${TAB}" "$(f2 f2f 5200006)"
check "F2 - no later green run of another sha" "unknown${TAB}U1.undecided${TAB}" "$(f2 f2g 5200007)"
grep -q '/compare/' "$T/f2g.shim" && bad "F2 - no later green run still read a compare" || ok "F2 - no later green run reads no compare"
check "F2 - a vitest unit is not in the map" "unknown${TAB}U1.undecided${TAB}" "$(f2 f2h 5200001 CTV_UNIT=worker/jobs/test/x.test.js)"
check "F2 - a job: unit" "unknown${TAB}U1.undecided${TAB}" "$(f2 f2i 5200001 CTV_UNIT=job:x)"
check "F2 - a suite that is not in the map (renamed or deleted)" "unknown${TAB}U1.undecided${TAB}" "$(f2 f2k 5200008 CTV_UNIT=tests/gone-fixture-test.sh)"
check "F2 - event pull_request" "unknown${TAB}U1.undecided${TAB}" "$(f2 f2j 5200001 CTV_EVENT=pull_request)"
grep -q '/workflows/' "$T/f2j.shim" && bad "F2 - a pull_request row read the main green list" || ok "F2 - a pull_request row reads no main green list"

# Map once per run, from the checkout. The sandbox is unset, so the fixture
# map in CTV_F2_IMPACT_MAP is ignored and the real map is built.
MO="$T/out-f2map"
( export PATH="$T/bin:$PATH" HARNESS="$T/h" GH_TOKEN=tok-fixture-ctv SHIM_LOG="$T/f2map.shim" SHIM_FIX="$FIX" GH_ETAG=0 \
    CTV_F2_IMPACT_MAP="$FIX/impact-map.tsv"
  unset HARNESS_TEST_SANDBOX CTV_RULES_DIR
  . "$GHREST" && . "$LIB" || exit 1
  CTV_GH_READS=0 CTV_GH_MAX_READS=3000 CTV_BUDGET_CHECK=0 CTV_STOP=
  CTV_OUT=$MO CTV_REPO=$REPO CTV_EVENT=push CTV_HEAD_BRANCH=main CTV_HEAD_SHA=$M0 CTV_DAY=2026-10-14 CTV_RUN_ID=9500001
  CTV_ATTEMPT=1 CTV_JOB_CONCLUSION=failure CTV_UNIT=$SUITE CTV_RC=1
  CTV_WORKFLOW_ID=5200001 ctv_classify_row | cut -f1-2
  stat -c %Y "$MO/cache/impact-map-f2.tsv" > "$T/f2map.mtime1" 2>/dev/null
  sleep 1
  CTV_WORKFLOW_ID=5200002 ctv_classify_row | cut -f1-2
  stat -c %Y "$MO/cache/impact-map-f2.tsv" > "$T/f2map.mtime2" 2>/dev/null ) > "$T/f2map.out" 2> "$T/f2map.err"
runid=$(find "$MO/.rules-scratch" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null)
check "F2 map: the stamp holds this run's id" "$runid" "$(cat "$MO/cache/impact-map-f2.stamp" 2>/dev/null)"
[ -n "$runid" ] && ok "F2 map: one run id ($runid)" || bad "F2 map: no run id"
n_map=$(grep -c . "$MO/cache/impact-map-f2.tsv" 2>/dev/null || echo 0)
[ "$n_map" -gt 100 ] && ok "F2 map: the real map was built ($n_map rows), the fixture override is ignored outside the sandbox" \
  || bad "F2 map: map has $n_map rows: $(cat "$T/f2map.err")"
[ -s "$T/f2map.mtime1" ] && check "F2 map: the second row did not rebuild it" "$(cat "$T/f2map.mtime1")" "$(cat "$T/f2map.mtime2")" \
  || bad "F2 map: no map after row 1"
check "F2 map: no map temp file left" "" "$(find "$MO/cache" -name 'impact-map-f2.tsv.tmp*' 2>/dev/null)"
check "F2 map: both rows decide on the real map" "flake${TAB}F2.main-unrelated-green
flake${TAB}F2.main-unrelated-green" "$(cat "$T/f2map.out")"

# The unit itself changed: no decision, and no map is built for it.
UO="$T/out-f2self"
( export PATH="$T/bin:$PATH" HARNESS="$T/h" GH_TOKEN=tok-fixture-ctv SHIM_LOG="$T/f2self.shim" SHIM_FIX="$FIX" GH_ETAG=0
  unset HARNESS_TEST_SANDBOX CTV_RULES_DIR CTV_F2_IMPACT_MAP
  . "$GHREST" && . "$LIB" || exit 1
  CTV_GH_READS=0 CTV_GH_MAX_READS=3000 CTV_BUDGET_CHECK=0 CTV_STOP=
  CTV_OUT=$UO CTV_REPO=$REPO CTV_EVENT=push CTV_HEAD_BRANCH=main CTV_HEAD_SHA=$M0 CTV_DAY=2026-10-14 CTV_RUN_ID=9500001
  CTV_ATTEMPT=1 CTV_JOB_CONCLUSION=failure CTV_UNIT=$SUITE CTV_RC=1 CTV_WORKFLOW_ID=5200004 ctv_classify_row ) > "$T/f2self.out" 2>&1
check "F2 - the unit itself changed, real registry outside the sandbox" "unknown${TAB}U1.undecided${TAB}" "$(cat "$T/f2self.out")"
[ -e "$UO/cache/impact-map-f2.tsv" ] && bad "F2 - the unit itself changed, yet the map was built" || ok "F2 - the unit itself changed: decided before any map build"

# ── E2E: the CLI over the fixture set ───────────────────────────────────────
EO="$T/out-e2e"
RC=0
env PATH="$T/bin:$PATH" HARNESS="$T/h-e2e" HARNESS_TEST_SANDBOX=1 HARNESS_SECRET=secret-fixture-ctv \
  JOBS_URL=http://192.0.2.10:8787 CTV_NOW="$CTV_TEST_NOW" GH_TOKEN=tok-fixture-ctv SHIM_LOG="$T/e2e.shim" SHIM_FIX="$FIX" \
  "$CLI" --days 1 --no-model --out "$EO" > "$T/e2e.out" 2> "$T/e2e.err" || RC=$?
check "E2E the CLI is rc 0" 0 "$RC"
[ -e "$T/e2e.shim.refused" ] && bad "E2E the shims refused: $(cat "$T/e2e.shim.refused")" || ok "E2E no REFUSED line from the shims"
occ() { grep -v '^#' "$EO/occurrences.tsv" 2>/dev/null | awk -F'\t' -v u="$1" '$8 == u { print $11 "\t" $12 }'; }
check "E2E the missing-catalog row is infra I3.pattern" "infra${TAB}I3.pattern" "$(occ tests/lanes-fixture-test.sh)"
check "E2E the retry row is flake F1.same-head-green" "flake${TAB}F1.same-head-green" "$(occ tests/retry-fixture-test.sh)"
check "E2E the adversarial 'rate limit' row is unknown U1.undecided" "unknown${TAB}U1.undecided" "$(occ tests/ratelimit-fixture-test.sh)"
EJ="$EO/2026-10-14/ci-test-value.json"
check "E2E .rules counts I3 and F1" true "$(jq '.rules["I3.pattern"] >= 1 and .rules["F1.same-head-green"] >= 1' "$EJ" 2>/dev/null)"
check "E2E the driver's gh_reads plus the rule ledger equal the shim's GETs" "$(gets "$T/e2e.shim")" \
  "$(( $(jq -r .coverage.gh_reads "$EJ" 2>/dev/null || echo 0) + $(ledger "$EO") ))"

echo
if [ "$FAILS" -eq 0 ]; then echo "PASS ci-test-value-infra-flake.bh-6618"; exit 0; fi
echo "FAILED $FAILS check(s) in ci-test-value-infra-flake.bh-6618"; exit 1
