#!/bin/bash
# tests/ci-test-value.bh-6618-test.sh — BH-6636 (BH-6618.0): the CI test value
# tracer. An operator runs bin/ci-test-value-report.sh; it lists the failed
# harness-ci.yml runs of a window, reads their failed jobs and logs, writes one
# occurrences.tsv row per failed unit and a totals JSON. READ-ONLY.
#
# The CLI runs in place from this checkout, with HARNESS=$T/h, a pinned clock
# (CTV_NOW) and a `gh` shim plus a `curl` shim first on PATH. The gh shim serves
# tests/fixtures/bh-6618/core/ and refuses (rc 99, one line in a refusals file)
# any call that is not a REST GET. The shard log fixture is real
# `bin/test-trace-safety.sh --gate` output and the worker-jobs log is real
# Node 22 `node --test` output, both with GitHub's timestamp prefix added.
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
CLI="$REPO_DIR/bin/ci-test-value-report.sh"
LIB="$REPO_DIR/bin/lib/ci-test-value.sh"
RENDER="$REPO_DIR/bin/lib/ci-test-value-render.py"
FIX="$REPO_DIR/tests/fixtures/bh-6618/core"
REGISTRY_FILES=(
  "$REPO_DIR/bin/lib/ci-test-value/rules.d/10-infra.sh"
  "$REPO_DIR/bin/lib/ci-test-value/rules.d/20-flake.sh"
  "$REPO_DIR/bin/lib/ci-test-value/rules.d/30-order.sh"
  "$REPO_DIR/bin/lib/ci-test-value/rules.d/40-followup.sh"
  "$REPO_DIR/bin/lib/ci-test-value/rules.d/50-main-flake.sh"
  "$REPO_DIR/bin/lib/ci-test-value/rules.d/60-batch-fix.sh"
  "$REPO_DIR/bin/lib/ci-test-value/model.sh"
  "$REPO_DIR/bin/lib/ci-test-value/sources.sh"
)
CTV_TEST_NOW=1791979200 # 2026-10-14T12:00:00Z, the pinned clock of every case
TAB=$'\t'

FAILS=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi
}

for f in "$CLI" "$LIB" "$RENDER" "${REGISTRY_FILES[@]}"; do
  [ -f "$f" ] || bad "missing source file ${f#"$REPO_DIR"/}"
done

# ── shims ───────────────────────────────────────────────────────────────────
mkdir -p "$T/bin" "$T/h/state" "$T/h/logs"
echo "pre-existing fixture state" > "$T/h/state/keep.txt"
cat > "$T/bin/gh" <<'SHIM'
#!/bin/bash
log="${SHIM_LOG:?}"; fix="${SHIM_FIX:?}"
refuse() { echo "REFUSED $*" >> "$log.refused"; exit 99; }
[ "${1:-}" = api ] || refuse "$@"
shift
# `gh api --help`: the probe for the flag. SHIM_OLD_GH=1 is a gh without
# --allow-escape-sequences (the hub's gh 2.45): its help does not list the
# flag, it rejects the flag ("unknown flag", rc 1) and prints an ESC body raw.
for a in "$@"; do
  if [ "$a" = --help ]; then
    echo "      --hostname string   The GitHub hostname for the request"
    [ "${SHIM_OLD_GH:-0}" = 1 ] || echo "      --allow-escape-sequences   Allow printing terminal escape sequences"
    exit 0
  fi
done
m=GET inc=0 esc=0 path=
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--method) m="${2:-}"; shift 2 ;;
    --method=*) m="${1#--method=}"; shift ;;
    -X*) m="${1#-X}"; shift ;;
    -i|--include) inc=1; shift ;;
    --allow-escape-sequences)
      if [ "${SHIM_OLD_GH:-0}" = 1 ]; then echo "unknown flag: --allow-escape-sequences" >&2; exit 1; fi
      esc=1; shift ;;
    -H|--header|--jq|-q|--cache|-t|--template) shift 2 ;;
    -f|-F|--field|--raw-field|--input) refuse "field $*" ;;
    -*) shift ;;
    *) [ -z "$path" ] && path="$1"; shift ;;
  esac
done
[ "$m" = GET ] || refuse "method $m $path"
case "$path" in graphql|*/graphql) refuse "graphql" ;; esac
echo "GET $path" >> "$log"
[ "$esc" = 1 ] && echo "$path" >> "$log.esc"
st=200 f=
if [ -n "${SHIM_FAIL_RE:-}" ] && [[ "$path" =~ $SHIM_FAIL_RE ]]; then
  st=502
else
  case "$path" in
    rate_limit) f="$fix/rate-limit-${SHIM_RATE:-healthy}.json" ;;
    repos/*/actions/workflows/harness-ci.yml/runs\?*)
      q="&${path#*\?}&"
      d=$(sed -n 's/.*&created=\([0-9-]*\)&.*/\1/p' <<<"$q")
      if [[ "$q" == *"&status=failure&"* ]]; then
        p=$(sed -n 's/.*&page=\([0-9]*\)&.*/\1/p' <<<"$q")
        f="$fix/runs/$d-fail-p$p.json"
      else
        f="$fix/runs/$d-all.json"
      fi
      [ -f "$f" ] || f="${SHIM_EMPTY:?}" ;;
    repos/*/actions/runs/*/attempts/*/jobs\?*)
      r=${path#*/actions/runs/}; id=${r%%/*}; a=${r#*/attempts/}; a=${a%%/*}
      f="$fix/jobs/$id-a$a.json" ;;
    repos/*/actions/jobs/*/logs)
      j=${path#*/actions/jobs/}; j=${j%%/*}
      f="$fix/joblogs/$j.txt" ;;
  esac
  [ -n "$f" ] && [ -f "$f" ] || st=404
fi
if [ "$inc" = 1 ]; then
  printf 'HTTP/2.0 %s fixture\r\nContent-Type: application/json\r\n\r\n' "$st"
fi
# Real gh (probed on a live job log, BH-6636): a body with an ESC byte and no
# --allow-escape-sequences prints the headers only and exits 1.
if [ "$st" = 200 ] && [ "$esc" = 0 ] && [ "${SHIM_OLD_GH:-0}" != 1 ] && grep -q $'\e' "$f"; then
  echo "the response contains terminal escape sequences; pass --allow-escape-sequences to output it anyway" >&2
  exit 1
fi
if [ "$st" = 200 ]; then cat "$f"; exit 0; fi
printf '{"message":"fixture %s"}\n' "$st"
exit 1
SHIM
cat > "$T/bin/curl" <<'SHIM'
#!/bin/bash
# The jobs worker client (bin/lib/jobs/req.sh) sends `-X <method>`. A GET is
# logged and answered 404, which the client reads as "no row"; anything else
# is refused.
log="${SHIM_LOG:?}.curl"; m=GET prev= url=
for a in "$@"; do
  case "$prev" in -X|--request) m="$a" ;; esac
  case "$a" in -d|--data*|-F|--form|-T|--upload-file) echo "REFUSED curl data" >> "${SHIM_LOG}.refused"; exit 99 ;; esac
  case "$a" in http://*|https://*) url="$a" ;; esac
  prev="$a"
done
[ "$m" = GET ] || { echo "REFUSED curl $m $url" >> "${SHIM_LOG}.refused"; exit 99; }
echo "GET $url" >> "$log"
printf '\n404'
SHIM
chmod +x "$T/bin/gh" "$T/bin/curl"
printf '{"total_count":0,"workflow_runs":[]}\n' > "$T/empty-list.json"

# A fixture dir per case that edits one: a copy of core/. The shim answers
# $T/empty-list.json for a day with no fixture file.
fixdir() { # fixdir <case> -> prints the copy
  mkdir -p "$T/fix-$1"
  cp -r "$FIX" "$T/fix-$1/core"
  printf '%s\n' "$T/fix-$1/core"
}

RC=0
CASE_H="$T/h"
run_cli() { # run_cli <case> <fixture dir> [env NAME=V ...] -- [cli args...]
  local c="$1" fx="$2"; shift 2
  local -a ev=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do ev+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  RC=0
  env PATH="$T/bin:$PATH" HARNESS="$CASE_H" HARNESS_TEST_SANDBOX=1 \
    HARNESS_SECRET=secret-fixture-ctv JOBS_URL=http://192.0.2.10:8787 CTV_NOW="$CTV_TEST_NOW" \
    GH_TOKEN=tok-fixture-ctv SHIM_EMPTY="$T/empty-list.json" SHIM_LOG="$T/$c.shim" SHIM_FIX="$fx" ${ev[@]+"${ev[@]}"} \
    "$CLI" "$@" > "$T/$c.out" 2> "$T/$c.err" || RC=$?
}
gets() { grep -c -v -e ' rate_limit$' "$1" 2>/dev/null || true; } # REST GETs that are not the budget read
data_rows() { grep -c -v '^#' "$1" 2>/dev/null || true; }

# ── AT-3: the parser ────────────────────────────────────────────────────────
P3=$( . "$LIB" && ctv_parse_job_log < "$FIX/joblogs/7100011.txt" | cut -f1-3 )
check "AT-3 shard log: rc 0 and rc>0 rows with their secs, nothing else" \
  "tests/alpha-fixture-test.sh${TAB}0${TAB}0
tests/beta-fixture-test.sh${TAB}1${TAB}0
tests/mc/gamma-fixture-test.sh${TAB}2${TAB}0" "$P3"
case "$P3" in *other-fixture*) bad "AT-3 the indented echoed harness line gave a row" ;; *) ok "AT-3 the indented echoed harness line gives no row" ;; esac
P3L=$( . "$LIB" && ctv_parse_job_log < "$FIX/joblogs/7100011.txt" | cut -f4 | tr '\n' ' ' )
check "AT-3 line numbers point at the rc lines" "3 4 9 " "$P3L"
P3W=$( . "$LIB" && ctv_parse_job_log < "$FIX/joblogs/7100021.txt" | cut -f1-3 )
check "AT-3 worker-jobs node --test log: the .test.js file once, rc 1" \
  "worker/jobs/test/routes/fixture-route.test.js${TAB}1${TAB}-" "$P3W"
P3N=$( . "$LIB" && printf '%s\n' \
  '--- tests/a.sh rc=1' \
  'FAIL notes.txt' \
  'FAIL test/x.test.js' \
  ' FAIL  src/lib/sort.spec.ts > sorts the rows' \
  'FAIL src/__tests__/grid.js' \
  "  location: '/home/runner/work/r/r/worker/jobs/test/helper.js:3:1'" \
  "2026-10-13T09:00:02.0000000Z   location: '/home/runner/work/r/r/console-ui/test/sort.test.js:9:1'" \
  '2026-10-13T09:00:02.0000000Z --- tests/a.sh rc=1 3s' \
  '2026-10-13T09:00:02.0000000Z     --- tests/b.sh rc=1 3s' \
  '--- tests/mc/c.sh rc=0 1s' | ctv_parse_job_log | cut -f1-3 )
check "AT-3 adversarial lines: only the anchored and test-file tokens give rows" \
  "test/x.test.js${TAB}1${TAB}-
src/lib/sort.spec.ts${TAB}1${TAB}-
src/__tests__/grid.js${TAB}1${TAB}-
console-ui/test/sort.test.js${TAB}1${TAB}-
tests/a.sh${TAB}1${TAB}3
tests/mc/c.sh${TAB}0${TAB}1" "$P3N"

# ── AT-REG: the rule registry ───────────────────────────────────────────────
mkdir -p "$T/rules-a" "$T/rules-b" "$T/rules-c"
cat > "$T/rules-a/15-x.sh" <<'RULE'
ctv_rule_x() { printf 'flake\tF9.test\twhy %s\n' "$CTV_UNIT"; return 0; }
RULE
cat > "$T/rules-a/25-y.sh" <<'RULE'
ctv_rule_y() { printf 'infra\tI9.test\twhy\n'; return 0; }
RULE
cat > "$T/rules-b/15-m-x.sh" <<'RULE'
ctv_rule_m_x() { printf 'Flake bad\n'; return 0; }
RULE
cp "$T/rules-a/25-y.sh" "$T/rules-b/25-y.sh"
cat > "$T/rules-c/05-q.sh" <<'RULE'
ctv_rule_q() { return 1; }
RULE
sed 's/ctv_rule_y/ctv_rule_y2/' "$T/rules-a/25-y.sh" > "$T/rules-c/09-y2.sh"
cp "$T/rules-a/15-x.sh" "$T/rules-c/15-x.sh"
# The fixture registries are read only in the sandbox (bin/lib/ci-test-value.sh).
# Set it here: CI's traced shards run this suite without HARNESS_TEST_SANDBOX.
R1=$( export HARNESS_TEST_SANDBOX=1 CTV_RULES_DIR="$T/rules-a"; . "$LIB" && CTV_UNIT=tests/u.sh ctv_classify_row )
check "AT-REG lowest-numbered deciding rule wins" "flake${TAB}F9.test${TAB}why tests/u.sh" "$R1"
R2=$( export HARNESS_TEST_SANDBOX=1 CTV_RULES_DIR="$T/rules-b"; . "$LIB" && ctv_classify_row )
check "AT-REG a malformed decision is U2.rule-error naming the rule" "unknown${TAB}U2.rule-error${TAB}m-x" "$R2"
R3=$( export HARNESS_TEST_SANDBOX=1 CTV_RULES_DIR="$T/rules-c"; . "$LIB" && ctv_classify_row )
check "AT-REG LC_ALL=C order, an rc 1 rule passes the row on" "infra${TAB}I9.test${TAB}why" "$R3"
R4=$( . "$LIB" && CTV_UNIT=tests/u.sh ctv_classify_row )
check "AT-REG the real registry decides nothing: U1.undecided" "unknown${TAB}U1.undecided${TAB}" "$R4"
R5=$( export CTV_RULES_DIR="$T/rules-a"; unset HARNESS_TEST_SANDBOX; . "$LIB" && ctv_classify_row )
check "AT-REG CTV_RULES_DIR is ignored outside the sandbox" "unknown${TAB}U1.undecided${TAB}" "$R5"
R6=$( . "$LIB" && ctv_rules_load && printf '%s ' "${_CTV_RULES[@]}" )
check "AT-REG the six placeholders load in rule order" \
  "ctv_rule_infra ctv_rule_flake ctv_rule_order ctv_rule_followup ctv_rule_main_flake ctv_rule_batch_fix " "$R6"
R7=$( . "$LIB" && ctv_model_pass /nonexistent && ctv_fetch_sources /nonexistent && echo seams-rc0 )
check "AT-REG the model and sources seams are rc 0 no-ops" "seams-rc0" "$R7"
mkdir -p "$T/rules-bad"; printf '# defines nothing\n' > "$T/rules-bad/05-z.sh"
run_cli reg-bad "$FIX" CTV_RULES_DIR="$T/rules-bad" -- --days 1 --out "$T/out-reg-bad"
check "AT-REG a rule file with no function stops the CLI with rc 2" 2 "$RC"
grep -q '05-z.sh' "$T/reg-bad.err" && ok "AT-REG the stderr line names the file" || bad "AT-REG stderr does not name 05-z.sh: $(cat "$T/reg-bad.err")"
[ -s "$T/reg-bad.shim" ] && bad "AT-REG a bad registry still read GitHub" || ok "AT-REG a bad registry reads nothing"

# ── AT-MODEL: the model seam is called unless CTV_NO_MODEL=1 ────────────────
(
  . "$LIB" || exit 1
  ctv_model_pass() { echo "$1" >> "$T/model.marker"; }
  CTV_OUT="$T/out-model"; mkdir -p "$CTV_OUT"
  CTV_RUN_ID=5 CTV_ATTEMPT=1 CTV_JOB_ID=6 CTV_DAY=2026-10-13 CTV_UNIT=$'tests/a\tb.sh' CTV_RC=1 \
    CTV_DISPLAY_TITLE=$'two\nlines' ctv_row_put > "$T/model-rows"
  CTV_NO_MODEL=1 ctv_classify_all "$T/model-rows"
  [ -e "$T/model.marker" ] && echo "marker-after-no-model"
  ctv_classify_all "$T/model-rows"
) > "$T/model.out" 2>&1
check "AT-MODEL --no-model skips the seam, the default calls it once" "" "$(cat "$T/model.out")"
check "AT-MODEL the seam gets occurrences.tsv" "$T/out-model/occurrences.tsv" "$(cat "$T/model.marker" 2>/dev/null)"
check "AT-MODEL a tab in a field becomes a space" "tests/a b.sh" "$(grep -v '^#' "$T/out-model/occurrences.tsv" | cut -f8)"

# ── AT-8: usage errors write nothing ────────────────────────────────────────
n8=0
for spec in "--days 0" "--days 91" "--days x" "--bogus" "--max-reads 0" "--repo bad/repo/x" "--days"; do
  n8=$((n8 + 1))
  # shellcheck disable=SC2086 # the spec is split into its words on purpose
  run_cli "u$n8" "$FIX" -- $spec --out "$T/out-u$n8"
  check "AT-8 '$spec' is rc 2" 2 "$RC"
  [ -e "$T/out-u$n8" ] && bad "AT-8 '$spec' wrote --out" || ok "AT-8 '$spec' wrote nothing"
done
for ev in CTV_GH_MAX_READS=abc CTV_EXCERPT_LINES=x; do
  n8=$((n8 + 1))
  run_cli "u$n8" "$FIX" "$ev" -- --days 2 --out "$T/out-u$n8"
  check "AT-8 $ev is rc 2" 2 "$RC"
  [ -e "$T/out-u$n8" ] && bad "AT-8 $ev wrote --out" || ok "AT-8 $ev wrote nothing"
done
grep -q -- '--days' "$T/u1.err" && ok "AT-8 usage goes to stderr" || bad "AT-8 no usage on stderr"

# ── AT-4 + AT-OUT + AT-RT: the whole CLI, read-only, against fixtures ───────
# A fresh $HARNESS, so every file the run creates shows up in the diff.
CASE_H="$T/h-ro"
mkdir -p "$CASE_H/state" "$CASE_H/logs"
echo "pre-existing fixture state" > "$CASE_H/state/keep.txt"
snap_h() { (cd "$CASE_H" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum); }
snap_co() {
  git -C "$REPO_DIR" status --porcelain=v1 --untracked-files=all --ignored 2>/dev/null \
    | while IFS= read -r l; do p=${l:3}; printf '%s %s\n' "$l" "$(sha256sum < "$REPO_DIR/$p" 2>/dev/null | cut -c1-16)"; done
}
snap_h > "$T/h.before"; snap_co > "$T/co.before"
OUT="$CASE_H/out-ro"
run_cli ro "$FIX" -- --days 30 --no-model --out "$OUT"
snap_h > "$T/h.after"; snap_co > "$T/co.after"
CASE_H="$T/h"
check "AT-4 the fixture run is rc 0" 0 "$RC"
[ -e "$T/ro.shim.refused" ] && bad "AT-4 the gh/curl shims refused: $(cat "$T/ro.shim.refused")" || ok "AT-4 0 refused (non-GET) calls"
grep -q -v '^GET ' "$T/ro.shim" && bad "AT-4 a gh shim line that is not a GET" || ok "AT-4 every gh call is a REST GET"
grep -q -v '^GET ' "$T/ro.shim.curl" 2>/dev/null && bad "AT-4 a curl line that is not a GET" || ok "AT-4 every worker call is a GET"
cmp -s "$T/co.before" "$T/co.after" && ok "AT-4 the checkout is unchanged" || bad "AT-4 the checkout changed: $(diff "$T/co.before" "$T/co.after")"
changed=$(diff <(awk '{print $2, $1}' "$T/h.before") <(awk '{print $2, $1}' "$T/h.after") | sed -n 's/^[<>] \(\S*\) .*/\1/p' | LC_ALL=C sort -u)
ALLOW=(
  -e '^$' -e '^\./out-ro/'
  -e '^\./state/gh-rest-ledger/'      # bin/lib/gh-rest-ledger.sh: one ledger line per REST call
  -e '^\./state/gh-budget/'           # bin/lib/gh-budget.sh: the rate_limit cache and its log markers
  -e '^\./logs/ci-test-value\.log$'   # bin/lib/gh-budget.sh: gh_budget_low's line for this caller
  -e '^\./logs/gh-budget\.log$'       # bin/lib/gh-budget.sh: unwritable cache, bad threshold
  -e '^\./logs/gh-rate\.log$'         # bin/lib/gh-rest-ledger.sh: the quota log
  -e '^\./state/lane-gate/'           # bin/lib/lane-gate.sh, via gh-budget.sh's lib_env_apply: knob cache markers
  -e '^\./logs/lane-gate\.log$'       # bin/lib/lane-gate.sh: "registry default for GH_BUDGET_TTL_S"
)
outside=$(printf '%s\n' "$changed" | grep -v "${ALLOW[@]}" || true)
check "AT-4 every changed path is under --out or in the telemetry allowlist" "" "$outside"
grep -q '^\./out-ro/occurrences.tsv$' <<<"$changed" && ok "AT-4 the snapshot sees the --out writes" || bad "AT-4 the snapshot missed occurrences.tsv"

OCC="$OUT/occurrences.tsv"
check "AT-OUT header" \
  "#run_id${TAB}attempt${TAB}job_id${TAB}day${TAB}event${TAB}is_batch${TAB}head_sha${TAB}unit${TAB}rc${TAB}secs${TAB}class${TAB}rule${TAB}run_url${TAB}job_url${TAB}why" \
  "$(head -1 "$OCC")"
U=https://github.com/example-org/cromford/actions/runs
check "AT-OUT one row per fixture failure, unit/rc/run_url from the fixture, unknown U1.undecided" \
"9100001${TAB}1${TAB}7100011${TAB}2026-10-12${TAB}pull_request${TAB}0${TAB}aaaaaaa1aaaaaaa1aaaaaaa1aaaaaaa1aaaaaaa1${TAB}tests/beta-fixture-test.sh${TAB}1${TAB}0${TAB}unknown${TAB}U1.undecided${TAB}$U/9100001
9100001${TAB}1${TAB}7100011${TAB}2026-10-12${TAB}pull_request${TAB}0${TAB}aaaaaaa1aaaaaaa1aaaaaaa1aaaaaaa1aaaaaaa1${TAB}tests/mc/gamma-fixture-test.sh${TAB}2${TAB}0${TAB}unknown${TAB}U1.undecided${TAB}$U/9100001
9100001${TAB}1${TAB}7100013${TAB}2026-10-12${TAB}pull_request${TAB}0${TAB}aaaaaaa1aaaaaaa1aaaaaaa1aaaaaaa1aaaaaaa1${TAB}job:Tests cannot touch a real harness${TAB}-${TAB}-${TAB}unknown${TAB}U1.undecided${TAB}$U/9100001
9100002${TAB}2${TAB}7100021${TAB}2026-10-13${TAB}merge_group${TAB}1${TAB}aaaaaaa2aaaaaaa2aaaaaaa2aaaaaaa2aaaaaaa2${TAB}worker/jobs/test/routes/fixture-route.test.js${TAB}1${TAB}-${TAB}unknown${TAB}U1.undecided${TAB}$U/9100002
9100003${TAB}1${TAB}7100031${TAB}2026-10-14${TAB}push${TAB}0${TAB}aaaaaaa3aaaaaaa3aaaaaaa3aaaaaaa3aaaaaaa3${TAB}tests/delta-fixture-test.sh${TAB}124${TAB}900${TAB}unknown${TAB}U1.undecided${TAB}$U/9100003" \
  "$(grep -v '^#' "$OCC" | cut -f1-13)"
check "AT-OUT the job_url column is the job's html_url" "$U/9100002/job/7100021" "$(grep -v '^#' "$OCC" | sed -n 4p | cut -f14)"
grep -v '^#' "$OCC" | LC_ALL=C sort -c -t"$TAB" -k1,1n -k2,2n -k3,3n -k8,8 && ok "AT-OUT rows are sorted" || bad "AT-OUT rows are not sorted"
check "AT-OUT summary line" \
  "ctv: occurrences=5 red_runs=3 read=3 unread=0 gh_reads=$(gets "$T/ro.shim") incomplete=false report=$OUT/2026-10-14/ci-test-value.json" \
  "$(cat "$T/ro.out")"
EX="$OUT/cache/excerpt"
grep -q 'FAIL: beta row count 3 != 4' "$EX/7100011-1.txt" && ok "AT-OUT the beta excerpt holds its failure" || bad "AT-OUT beta excerpt: $(cat "$EX/7100011-1.txt" 2>&1)"
grep -q 'gamma: timed out' "$EX/7100011-1.txt" && bad "AT-OUT the beta excerpt ran past the next suite line" || ok "AT-OUT the beta excerpt stops at the next suite line"
grep -q 'gamma: timed out' "$EX/7100011-2.txt" && ok "AT-OUT the gamma excerpt holds its failure" || bad "AT-OUT gamma excerpt: $(cat "$EX/7100011-2.txt" 2>&1)"
grep -q 'exit code 1' "$EX/7100013-1.txt" && ok "AT-OUT a job: unit's excerpt is the log tail" || bad "AT-OUT job: excerpt: $(cat "$EX/7100013-1.txt" 2>&1)"
grep -q "fixture route answers 200" "$EX/7100021-1.txt" && ok "AT-OUT a node unit's excerpt starts at the location line's test" || bad "AT-OUT node excerpt: $(cat "$EX/7100021-1.txt" 2>&1)"
grep -q 'actions/jobs/7100022/logs' "$T/ro.shim" && bad "AT-OUT a cancelled job's log was read" || ok "AT-OUT a cancelled job is not a failure"

J="$OUT/2026-10-14/ci-test-value.json"
jqv() { jq -r "$1" "$J" 2>/dev/null; }
check "AT-RT totals.occurrences equals the data rows" "$(data_rows "$OCC")" "$(jqv .totals.occurrences)"
check "AT-RT rules[U1.undecided] equals the data rows" "$(data_rows "$OCC")" "$(jqv '.rules["U1.undecided"]')"
check "AT-RT totals.by_class.unknown" 5 "$(jqv .totals.by_class.unknown)"
check "AT-RT coverage.gh_reads equals the shim's non-rate_limit GETs" "$(gets "$T/ro.shim")" "$(jqv .coverage.gh_reads)"
check "AT-RT coverage counts" "16 3 3 0 false 0 " "$(jqv '.coverage|"\(.runs_listed) \(.red_runs) \(.red_runs_read) \(.unread) \(.incomplete) \(.days_unlisted) \(.stop)"')"
check "AT-RT window, repo, generated_at" "2026-09-15 2026-10-14 30 example-org/cromford 2026-10-14T12:00:00Z" \
  "$(jqv '"\(.window.from) \(.window.to) \(.window.days) \(.repo) \(.generated_at)"')"
check "AT-RT 30 days list in 60 reads, 3 jobs reads, 4 log reads" 67 "$(gets "$T/ro.shim")"

# ── AT-5c: a second run reads only what can still change ───────────────────
cp "$OCC" "$T/occ.first"
run_cli ro2 "$FIX" -- --days 30 --no-model --out "$OUT"
check "AT-5c the second run is rc 0" 0 "$RC"
check "AT-5c the second run re-reads only today's listing" \
  "GET repos/example-org/cromford/actions/workflows/harness-ci.yml/runs?created=2026-10-14&per_page=1
GET repos/example-org/cromford/actions/workflows/harness-ci.yml/runs?created=2026-10-14&status=failure&per_page=100&page=1" \
  "$(grep -v ' rate_limit$' "$T/ro2.shim")"
cmp -s "$T/occ.first" "$OCC" && ok "AT-5c the cached run gives the same rows" || bad "AT-5c rows differ: $(diff "$T/occ.first" "$OCC")"
[ -e "$OUT/cache/list/2026-10-14-all.json" ] && bad "AT-5c today's listing was cached" || ok "AT-5c today's listing is not cached"

# ── AT-GH: the escape flag rides only on log reads, and only when gh has it ──
# Lead review 2026-10-14 (verdict #2216): a gh without --allow-escape-sequences
# rejected it on every read, so every listing was unlisted and the run read
# nothing. The flag is probed once from `gh api --help`.
grep -v '/logs$' "$T/ro.shim.esc" > "$T/ro.esc.json" 2>/dev/null || true
check "AT-GH a gh with the flag: no JSON read carries it" "" "$(cat "$T/ro.esc.json")"
check "AT-GH a gh with the flag: every log read carries it" "$(grep -c '/logs$' "$T/ro.shim")" "$(grep -c '/logs$' "$T/ro.shim.esc" 2>/dev/null || echo 0)"
run_cli oldgh "$FIX" SHIM_OLD_GH=1 -- --days 30 --no-model --out "$T/out-oldgh"
check "AT-GH a gh without the flag: rc 0" 0 "$RC"
check "AT-GH a gh without the flag: the same rows as a gh with it" "$(cat "$T/occ.first")" "$(cat "$T/out-oldgh/occurrences.tsv" 2>/dev/null)"
check "AT-GH a gh without the flag: the flag is never passed" "" "$(cat "$T/oldgh.shim.esc" 2>/dev/null)"
check "AT-GH a gh without the flag: the same reads as a gh with it" "$(gets "$T/ro.shim")" "$(gets "$T/oldgh.shim")"
L13="$T/out-oldgh/cache/log/7100013.txt"
if [ ! -s "$L13" ]; then bad "AT-GH the ESC log was not read"
elif grep -q $'\e' "$L13"; then bad "AT-GH the raw log kept its ESC bytes"
else ok "AT-GH ESC sequences are stripped from a raw log"; fi
grep -q 'exit code 1' "$T/out-oldgh/cache/excerpt/7100013-1.txt" 2>/dev/null && ok "AT-GH the ESC log's excerpt still holds its failure" \
  || bad "AT-GH ESC log excerpt: $(cat "$T/out-oldgh/cache/excerpt/7100013-1.txt" 2>&1)"

# ── AT-5d: a day is cached only after it is closed (lead review, 2026-10-14) ──
# A run created at 23:50Z on D can fail after midnight. A listing of D read at
# 00:05Z on D+1 must not be cached, or that failure is lost for good. D is
# closed only CTV_DAY_CLOSE_MARGIN_S (default 21600 s) after it ends.
FMID=$(fixdir mid); OMID="$T/out-mid"
redn() { sed -n 's/.* red_runs=\([0-9]*\) .*/\1/p' "$T/$1.out"; }
run_cli mid1 "$FMID" CTV_NOW=1791936300 -- --days 2 --dry-run --out "$OMID"   # 2026-10-14T00:05:00Z
check "AT-5d run 1 (00:05Z) is rc 0" 0 "$RC"
R0=$(redn mid1)
[ -e "$OMID/cache/list/2026-10-13-fail-p1.json" ] || [ -e "$OMID/cache/list/2026-10-13-all.json" ] \
  && bad "AT-5d a listing of 2026-10-13 read at 00:05Z was cached" || ok "AT-5d 2026-10-13 is not cached 5 min after it ended"
# The 23:50Z run fails at 00:15Z: it appears in D's failure listing only now.
jq '.total_count += 1 | .workflow_runs += [(.workflow_runs[0] | .id = 9100099 | .created_at = "2026-10-13T23:50:00Z" | .run_started_at = "2026-10-13T23:50:00Z" | .updated_at = "2026-10-14T00:15:00Z")]' \
  "$FMID/runs/2026-10-13-fail-p1.json" > "$T/x.json" && mv "$T/x.json" "$FMID/runs/2026-10-13-fail-p1.json"
run_cli mid2 "$FMID" CTV_NOW=1791961200 -- --days 2 --dry-run --out "$OMID"   # 2026-10-14T07:00:00Z
check "AT-5d run 2 (07:00Z) is rc 0" 0 "$RC"
check "AT-5d run 2 sees the run that failed after midnight" "$((R0 + 1))" "$(redn mid2)"
[ -e "$OMID/cache/list/2026-10-13-fail-p1.json" ] && ok "AT-5d 2026-10-13 is cached once the margin has passed" \
  || bad "AT-5d 2026-10-13 was not cached at 07:00Z"
run_cli mid3 "$FMID" CTV_NOW=1791964800 -- --days 2 --dry-run --out "$OMID"   # 2026-10-14T08:00:00Z
check "AT-5d run 3 reads the closed day from the cache" 0 "$(grep -c 'created=2026-10-13' "$T/mid3.shim")"
check "AT-5d run 3 keeps the after-midnight run" "$((R0 + 1))" "$(redn mid3)"
run_cli mid4 "$FMID" CTV_NOW=1791936300 CTV_DAY_CLOSE_MARGIN_S=60 -- --days 2 --dry-run --out "$T/out-mid4"
[ -e "$T/out-mid4/cache/list/2026-10-13-fail-p1.json" ] && ok "AT-5d CTV_DAY_CLOSE_MARGIN_S=60 closes the day at 00:01Z" \
  || bad "AT-5d the margin knob is not read"

# ── AT-5a: no day listable → rc 3, no report ───────────────────────────────
run_cli l75 "$FIX" SHIM_FAIL_RE='/actions/workflows/' -- --days 3 --out "$T/out-l75"
check "AT-5a every listing answers 502: rc 3" 3 "$RC"
check "AT-5a only the cache dir and the lock remain" ".lock" "$(ls -A "$T/out-l75" | grep -v '^cache$' | tr '\n' ' ' | sed 's/ $//')"
[ -z "$(find "$T/out-l75/cache" -type f 2>/dev/null)" ] && ok "AT-5a AT-CACHE-75: a 502 listing is not cached" || bad "AT-5a cached a 502: $(find "$T/out-l75/cache" -type f)"

# ── AT-5b + AT-CACHE-75: half the log reads answer 502 ──────────────────────
# 7100013 is the SECOND failed job of run 9100001, so the rows of its first
# failed job (7100011) are already built when the read fails.
run_cli j75 "$FIX" SHIM_FAIL_RE='actions/jobs/(7100013|7100031)/logs' -- --days 30 --out "$T/out-j75"
check "AT-5b half the job-log reads 502: rc 4" 4 "$RC"
J="$T/out-j75/2026-10-14/ci-test-value.json"
check "AT-5b coverage: incomplete, 2 unread, 1 read" "true 2 1" "$(jqv '.coverage|"\(.incomplete) \(.unread) \(.red_runs_read)"')"
check "AT-5b an unread run keeps none of its rows" "9100002" "$(grep -v '^#' "$T/out-j75/occurrences.tsv" | cut -f1 | sort -u | tr '\n' ' ' | sed 's/ $//')"
[ -e "$T/out-j75/cache/log/7100013.txt" ] && bad "AT-CACHE-75 a 502 log was cached" || ok "AT-CACHE-75 a 502 log is not cached"
[ -s "$T/out-j75/cache/log/7100011.txt" ] && ok "AT-CACHE-75 a 200 log is cached" || bad "AT-CACHE-75 the 200 log is not cached"
grep -q 'incomplete=true' "$T/j75.out" && ok "AT-5b the summary line says incomplete" || bad "AT-5b summary: $(cat "$T/j75.out")"

# ── unread runs: a 404 log and a run that is not completed ─────────────────
F404=$(fixdir f404); scratch_rm "$F404/joblogs/7100031.txt"
run_cli f404 "$F404" -- --days 3 --out "$T/out-f404"
check "a 404 log is unread, never a pass: rc 4" "4 1" "$RC $(jq -r .coverage.unread "$T/out-f404/2026-10-14/ci-test-value.json" 2>/dev/null)"
FIP=$(fixdir fip)
jq '.workflow_runs[0].status="in_progress"' "$FIP/runs/2026-10-14-fail-p1.json" > "$T/x.json" && mv "$T/x.json" "$FIP/runs/2026-10-14-fail-p1.json"
run_cli fip "$FIP" -- --days 3 --out "$T/out-fip"
check "a run that is not completed is unread: rc 4, 1 unread" "4 1" "$RC $(jq -r .coverage.unread "$T/out-fip/2026-10-14/ci-test-value.json" 2>/dev/null)"
grep -q 'runs/9100003/' "$T/fip.shim" && bad "a run that is not completed had its jobs read" || ok "a run that is not completed costs no job read"

# ── AT-7: the read budget ───────────────────────────────────────────────────
run_cli m5 "$FIX" -- --days 30 --max-reads 5 --out "$T/out-m5"
J="$T/out-m5/2026-10-14/ci-test-value.json"
check "AT-7a --max-reads 5: rc 4" 4 "$RC"
check "AT-7a exactly 5 GETs" 5 "$(gets "$T/m5.shim")"
check "AT-7a coverage.stop and gh_reads" "max-reads 5 true" "$(jqv '.coverage|"\(.stop) \(.gh_reads) \(.incomplete)"')"
# Its own $HARNESS: the healthy rate_limit reading the cases above cached is
# still inside the gh-budget TTL in $T/h.
CASE_H="$T/h-low"
run_cli low "$FIX" SHIM_RATE=low -- --days 30 --out "$T/out-low"
CASE_H="$T/h"
J="$T/out-low/2026-10-14/ci-test-value.json"
check "AT-7b a low rate_limit: rc 4" 4 "$RC"
grep -q -e '/jobs?' -e '/logs$' "$T/low.shim" && bad "AT-7b a job or log read after budget-low" || ok "AT-7b 0 job or log reads"
grep -q ' rate_limit$' "$T/low.shim" && ok "AT-7b the real gh_budget_low read rate_limit" || bad "AT-7b gh_budget_low never asked"
check "AT-7b coverage.stop budget-low, all 3 red runs unread" "budget-low 3" "$(jqv '.coverage|"\(.stop) \(.unread)"')"

# ── AT-CAP: a day with more failed runs than the list API returns ──────────
FCAP=$(fixdir cap)
jq '.total_count=1001' "$FCAP/runs/2026-10-13-fail-p1.json" > "$T/x.json" && mv "$T/x.json" "$FCAP/runs/2026-10-13-fail-p1.json"
run_cli cap "$FCAP" -- --days 3 --out "$T/out-cap"
check "AT-CAP failure total_count 1001: rc 4, stop list-cap" "4 list-cap" "$RC $(jq -r .coverage.stop "$T/out-cap/2026-10-14/ci-test-value.json" 2>/dev/null)"

# ── paging: a full page of 100 asks for the next page, a short one stops ───
FPG=$(fixdir page)
jq -c '{total_count: 101, workflow_runs: [range(0;100) as $i | .workflow_runs[0] | .id = (9200000 + $i) | .status = "queued"]}' \
  "$FPG/runs/2026-10-13-fail-p1.json" > "$T/x.json" && mv "$T/x.json" "$FPG/runs/2026-10-13-fail-p1.json"
jq -c '.total_count = 101' "$FIX/runs/2026-10-13-fail-p1.json" > "$FPG/runs/2026-10-13-fail-p2.json"
run_cli page "$FPG" -- --days 2 --dry-run --out "$T/out-page"
check "paging: page 2 read, page 3 not" "1 0" "$(grep -c 'created=2026-10-13&status=failure&per_page=100&page=2$' "$T/page.shim") $(grep -c 'page=3$' "$T/page.shim")"
check "paging: red_runs counts both pages" "ctv: dry-run days=2 runs_listed=7 red_runs=102 gh_reads=5 days_unlisted=0" "$(cat "$T/page.out")"

# ── AT-LOCK ─────────────────────────────────────────────────────────────────
mkdir -p "$T/out-lock"
exec 8> "$T/out-lock/.lock"
flock -n 8 || bad "AT-LOCK the test could not take the lock"
run_cli lock "$FIX" -- --days 1 --out "$T/out-lock"
exec 8>&-
check "AT-LOCK a held lock is rc 2" 2 "$RC"
check "AT-LOCK nothing else written" ".lock" "$(ls -A "$T/out-lock" | tr '\n' ' ' | sed 's/ $//')"

# ── AT-DRY ──────────────────────────────────────────────────────────────────
run_cli dry "$FIX" -- --days 30 --dry-run --out "$T/out-dry"
check "AT-DRY rc 0" 0 "$RC"
check "AT-DRY the summary line counts" "ctv: dry-run days=30 runs_listed=16 red_runs=3 gh_reads=60 days_unlisted=0" "$(cat "$T/dry.out")"
grep -q -e '/jobs?' -e '/logs$' "$T/dry.shim" && bad "AT-DRY read a job or a log" || ok "AT-DRY 0 job or log reads"
[ -e "$T/out-dry/occurrences.tsv" ] && bad "AT-DRY wrote occurrences.tsv" || ok "AT-DRY no occurrences.tsv"

# ── the renderer refuses an unreadable input ───────────────────────────────
mkdir -p "$T/rend"
RRC=0; python3 -I "$RENDER" "$T/rend" "$T/rend/day" 2>/dev/null || RRC=$?
check "render: no coverage.json is rc 1 and no output" "1 no" "$RRC $([ -e "$T/rend/day/ci-test-value.json" ] && echo yes || echo no)"

echo
if [ "$FAILS" -eq 0 ]; then echo "PASS ci-test-value.bh-6618"; exit 0; fi
echo "FAILED $FAILS check(s) in ci-test-value.bh-6618"; exit 1
