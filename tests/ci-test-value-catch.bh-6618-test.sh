#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/ci-test-value-catch.bh-6618-test.sh — BH-6638 (BH-6618.2): the real
# catch, test defect and order rules of the CI test value report.
#
#   O1.batch-member-added-suite                 bin/lib/ci-test-value/rules.d/30-order.sh
#   T1 R1 T2 R2 (follow-up and main fix)        bin/lib/ci-test-value/rules.d/40-followup.sh
#   B1.batch-member-fix                         bin/lib/ci-test-value/rules.d/60-batch-fix.sh
#   ctv_followup_files, ctv_reaches             bin/lib/ci-test-value/followup.sh
#
# Rule rows call ctv_classify_row (the real registry) with the CTV_* row vars
# set and a `gh` shim first on PATH. The shim serves
# tests/fixtures/bh-6618/catch/ and refuses any call that is not a REST GET;
# a path with no fixture is a 404. The E2E rows run bin/ci-test-value-report.sh
# over the same fixtures.
set -uo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
CLI="$REPO_DIR/bin/ci-test-value-report.sh"
LIB="$REPO_DIR/bin/lib/ci-test-value.sh"
GHREST="$REPO_DIR/bin/lib/gh-rest.sh"
FU_LIB="$REPO_DIR/bin/lib/ci-test-value/followup.sh"
R_ORDER="$REPO_DIR/bin/lib/ci-test-value/rules.d/30-order.sh"
R_FOLLOW="$REPO_DIR/bin/lib/ci-test-value/rules.d/40-followup.sh"
R_BATCH="$REPO_DIR/bin/lib/ci-test-value/rules.d/60-batch-fix.sh"
FIX="$REPO_DIR/tests/fixtures/bh-6618/catch"
U=tests/ci-test-value-catch.bh-6618-test.sh
U2=tests/ci-test-value-infra-flake.bh-6618-test.sh
CTV_TEST_NOW=1791979200 # 2026-10-14T12:00:00Z
TAB=$'\t'
REPO=example-org/cromford
W=5300001

FAILS=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi
}
for f in "$CLI" "$LIB" "$GHREST" "$FU_LIB" "$R_ORDER" "$R_FOLLOW" "$R_BATCH"; do
  [ -f "$f" ] || bad "missing source file ${f#"$REPO_DIR"/}"
done
h40() { local o=; while [ ${#o} -lt 40 ]; do o+=$1; done; printf '%s' "${o:0:40}"; }
UNK="unknown${TAB}U1.undecided"

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
      if [[ "$q" == *"&event=pull_request&"* ]]; then
        b=$(sed -n 's/.*&branch=\([^&]*\)&.*/\1/p' <<<"$q")
        f="$fix/branch-runs/${b//\//__}.json"
      else
        d=$(sed -n 's/.*&created=\([0-9-]*\)\.\..*/\1/p' <<<"$q")
        f="$fix/main-green/$w-$d.json"
      fi ;;
    repos/*/actions/runs\?*)
      s=$(sed -n 's/.*&head_sha=\([0-9a-f]*\)&.*/\1/p' <<<"$q")
      f="$fix/heads/$s.json" ;;
    repos/*/actions/runs/*/attempts/*/jobs\?*)
      r=${path#*/actions/runs/}; id=${r%%/*}; a=${r#*/attempts/}; a=${a%%/*}
      f="$fix/jobs/$id-a$a.json" ;;
    repos/*/actions/jobs/*/logs)
      j=${path#*/actions/jobs/}; j=${j%%/*}
      f="$fix/joblogs/$j.txt" ;;
    repos/*/pulls/*/files\?*)
      n=${path#*/pulls/}; n=${n%%/*}
      p=$(sed -n 's/.*&page=\([0-9]*\)&.*/\1/p' <<<"$q")
      f="$fix/pulls/$n-files-p$p.json" ;;
    repos/*/pulls/*) f="$fix/pulls/${path#*/pulls/}.json" ;;
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
      SHIM_LOG="$T/$c.shim" SHIM_FIX="$FIX" GH_ETAG=0 CTV_IMPACT_MAP="$FIX/impact-map.tsv" CTV_F2_IMPACT_MAP="$FIX/impact-map.tsv" \
      CTV_OUT="$T/out-$c"
    unset CTV_RULES_DIR
    . "$GHREST" && . "$LIB" || exit 1
    CTV_GH_READS=0 CTV_GH_MAX_READS=3000 CTV_BUDGET_CHECK=0 CTV_STOP=
    while [ $# -gt 0 ]; do printf -v "${1%%=*}" '%s' "${1#*=}"; export "${1%%=*}"; shift; done
    ctv_classify_row )
}
# fu <case> <shell code> — run code with the registry (and so followup.sh)
# loaded, the shim on PATH and a row's out dir. Prints what the code prints.
fu() {
  local c="$1" code="$2"
  ( export PATH="$T/bin:$PATH" HARNESS="$T/h" HARNESS_TEST_SANDBOX=1 GH_TOKEN=tok-fixture-ctv \
      SHIM_LOG="$T/$c.shim" SHIM_FIX="$FIX" GH_ETAG=0 CTV_IMPACT_MAP="$FIX/impact-map.tsv"
    unset CTV_RULES_DIR
    . "$GHREST" && . "$LIB" || exit 1
    ctv_rules_load || exit 1
    CTV_GH_READS=0 CTV_GH_MAX_READS=3000 CTV_BUDGET_CHECK=0 CTV_STOP= CTV_OUT="$T/out-$c" CTV_REPO=$REPO
    eval "$code" )
}
gets() { [ -f "$1" ] || { echo 0; return; }; grep -c -v ' rate_limit$' "$1" || true; }
cnt() { [ -f "$2" ] || { echo 0; return; }; grep -c -e "$1" "$2" || true; } # cnt <re> <file>
ledger() { cat "$1"/.rules-scratch/*/reads 2>/dev/null | grep -c . || true; }
cr() { cut -f1-2; }

# ── FU: the follow-up set and the reach check ───────────────────────────────
check "FU-minus head compare minus base compare" "bin/y.sh
tests/x.sh" "$(fu fum "ctv_followup_files $(h40 a1) $(h40 b1) $(h40 a2) $(h40 b2)")"
check "FU-minus two compare GETs" 2 "$(cnt '/compare/' "$T/fum.shim")"
[ -s "$T/out-fum/cache/fu/compare-$(h40 a1)-$(h40 a2).json" ] && ok "FU-minus the head compare is cached under fu/" \
  || bad "FU-minus no cache/fu/compare-<a>-<b>.json"
check "FU-empty a rebase only is rc 0 and prints nothing" "rc=0 out=[]" \
  "$(fu fue "o=\$(ctv_followup_files $(h40 a3) $(h40 b1) $(h40 a4) $(h40 b2)); echo \"rc=\$? out=[\$o]\"")"
check "FU-404 a 404 head compare is rc 1" "rc=1 out=[]" \
  "$(fu fu4 "o=\$(ctv_followup_files $(h40 a5) $(h40 b1) $(h40 a6) $(h40 b2)); echo \"rc=\$? out=[\$o]\"")"
check "FU-404 nothing under cache/fu/" "" "$(find "$T/out-fu4/cache/fu" -type f 2>/dev/null)"
check "FU-404 a 404 base compare is rc 1" "rc=1" \
  "$(fu fu4b "ctv_followup_files $(h40 a1) $(h40 b1) $(h40 a2) $(h40 b9) > /dev/null; echo rc=\$?")"
check "FU-502 an unread head compare is rc 1" "rc=1" \
  "$(fu fu5 "SHIM_FAIL_RE=/compare/ ctv_followup_files $(h40 a1) $(h40 b1) $(h40 a2) $(h40 b2) > /dev/null; echo rc=\$?")"
check "FU-cap 300 files is rc 1" "rc=1" \
  "$(fu fuc "ctv_followup_files $(h40 a7) $(h40 b1) $(h40 a8) $(h40 b1) > /dev/null; echo rc=\$?")"
check "FU-cap 251 commits is rc 1" "rc=1" \
  "$(fu fuc2 "ctv_followup_files $(h40 a9) $(h40 b1) $(h40 aa) $(h40 b1) > /dev/null; echo rc=\$?")"
fu fus "ctv_followup_files $(h40 ab) $(h40 b1) $(h40 ac) $(h40 b1) > /dev/null"
check "FU-samebase the same base reads one compare" 1 "$(cnt '/compare/' "$T/fus.shim")"
check "FU-rename a rename counts both names" "bin/new.sh
bin/old.sh" "$(fu fur "ctv_followup_files $(h40 ab) $(h40 b1) $(h40 ac) $(h40 b1)")"
check "FU-badsha a short sha is rc 1" "rc=1" "$(fu fub "ctv_followup_files abc $(h40 b1) $(h40 a2) $(h40 b2); echo rc=\$?")"
check "FU-badsha a short sha reads nothing" 0 "$(gets "$T/fub.shim")"
check "FU-reach a specific map row is rc 0" "rc=0" "$(fu fur0 "ctv_reaches $U bin/fx-reach.sh; echo rc=\$?")"
check "FU-reach a directory row is rc 0" "rc=0" "$(fu fur0d "ctv_reaches $U docs/x.md bin/lib/fx-dir/a.sh; echo rc=\$?")"
check "FU-reach a path of another suite is rc 1" "rc=1" "$(fu fur1 "ctv_reaches $U bin/fx-other.sh; echo rc=\$?")"
check "FU-reach a unit the map does not name is rc 2" "rc=2" \
  "$(fu fur2 "ctv_reaches tests/gone-fixture-test.sh bin/fx-reach.sh; echo rc=\$?")"
check "FU-reach a path the map does not know (full:) is rc 2" "rc=2" \
  "$(fu fur3 "ctv_reaches $U bin/fx-unknown.sh; echo rc=\$?")"
check "FU-always an always-only pick is rc 1" "rc=1" "$(fu fua "ctv_reaches $U2 bin/fx-other.sh; echo rc=\$?")"
check "FU-path the test-path predicate" "0 0 1 1 1" "$(fu fup "for p in tests/a.sh catalog/fixtures/x.json bin/tests/a.sh catalog/x.tsv testsx/a.sh; do _ctv_fu_is_test_path \"\$p\"; printf '%s ' \$?; done" | sed 's/ $//')"

# FU-cache: the same compare in two runs. The second run reads it from cache/.
CO="$T/out-fucache"
fu fuc1 "CTV_OUT=$CO; ctv_followup_files $(h40 a1) $(h40 b1) $(h40 a2) $(h40 b2) > /dev/null"
for x in "$CO"/.rules-scratch/*; do mv "$x" "$CO/.rules-scratch/1-1"; done
check "FU-cache the second run prints the same set" "bin/y.sh
tests/x.sh" "$(fu fuc2r "CTV_OUT=$CO; ctv_followup_files $(h40 a1) $(h40 b1) $(h40 a2) $(h40 b2)")"
check "FU-cache the second run sends 0 GETs" 0 "$(gets "$T/fuc2r.shim")"

# FU-map / FU-map-prod: outside the sandbox CTV_IMPACT_MAP is ignored and the
# real map is built once per run.
MO="$T/out-fumap"
# A mapped path outside this suite's closure. It is built at run time: a path
# this file spells out is a map row of this suite, so it would reach it.
NOREACH=bin/issue-testhost-cert; NOREACH+=.sh
( export PATH="$T/bin:$PATH" HARNESS="$T/h" GH_TOKEN=tok-fixture-ctv SHIM_LOG="$T/fumap.shim" SHIM_FIX="$FIX" GH_ETAG=0 \
    CTV_IMPACT_MAP="$FIX/impact-map.tsv"
  unset HARNESS_TEST_SANDBOX CTV_RULES_DIR
  . "$GHREST" && . "$LIB" || exit 1
  ctv_rules_load || exit 1
  CTV_OUT=$MO
  ctv_reaches "$U" bin/lib/ci-test-value/rules.d/40-followup.sh; echo "rc=$?"
  stat -c %Y "$MO/cache/impact-map.tsv" > "$T/fumap.mtime1" 2>/dev/null
  sleep 1
  ctv_reaches "$U" "$NOREACH"; echo "rc=$?"
  stat -c %Y "$MO/cache/impact-map.tsv" > "$T/fumap.mtime2" 2>/dev/null ) > "$T/fumap.out" 2> "$T/fumap.err"
runid=$(find "$MO/.rules-scratch" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null)
check "FU-map the stamp holds this run's id" "$runid" "$(cat "$MO/cache/impact-map.stamp" 2>/dev/null)"
[ -n "$runid" ] && ok "FU-map one run id ($runid)" || bad "FU-map no run id"
n_map=$(grep -c . "$MO/cache/impact-map.tsv" 2>/dev/null || echo 0)
[ "$n_map" -gt 100 ] && ok "FU-map-prod the real map was built ($n_map rows), CTV_IMPACT_MAP is ignored" \
  || bad "FU-map-prod map has $n_map rows: $(cat "$T/fumap.err")"
[ -s "$T/fumap.mtime1" ] && check "FU-map the second call did not rebuild it" "$(cat "$T/fumap.mtime1")" "$(cat "$T/fumap.mtime2")" \
  || bad "FU-map no map after call 1"
check "FU-map-prod the real map: this suite reaches 40-followup.sh, not $NOREACH" "rc=0
rc=1" "$(cat "$T/fumap.out")"

# ── O1.batch-member-added-suite ─────────────────────────────────────────────
o1() { # o1 <case> <run> <title> [NAME=V ...]
  local c=$1 r=$2 t=$3; shift 3
  rule "$c" CTV_REPO=$REPO CTV_EVENT=pull_request CTV_HEAD_BRANCH=mergify/merge-queue/main/fx CTV_IS_BATCH=1 \
    CTV_HEAD_SHA="$(h40 0c)" CTV_BASE_SHA="$(h40 b0)" CTV_PR_NUMBERS=7999 CTV_WORKFLOW_ID=$W CTV_RUN_ID="$r" CTV_ATTEMPT=1 \
    CTV_DAY=2026-10-14 CTV_JOB_CONCLUSION=failure "CTV_JOB_NAME=run the traced corpus" CTV_UNIT=$U CTV_RC=1 \
    "CTV_DISPLAY_TITLE=$t" "$@"
}
check "O1+a a 2-member batch, #7001 added the unit, its run green" \
  "order${TAB}O1.batch-member-added-suite${TAB}#7001 added $U; its run 9600005 was green on $(h40 a1 | cut -c1-12); 1 other member(s)" \
  "$(o1 o1a 9600010 'merge queue: embarking #7001 and #7002 together')"
check "O1+b a 3-member batch, #7012 modified the unit" "order${TAB}O1.batch-member-added-suite" \
  "$(o1 o1b 9600020 'merge queue: embarking #7013, #7011 and #7012 together' | cr)"
check "O1+mergify CTV_IS_BATCH=0 on a mergify/merge-queue/ branch is a batch" "order${TAB}O1.batch-member-added-suite" \
  "$(o1 o1m 9600010 'merge queue: embarking #7001 and #7002 together' CTV_IS_BATCH=0 | cr)"
check "O1-single a batch of one" "$UNK" "$(o1 o1s 9600010 'merge queue: embarking #7001 together' | cr)"
check "O1-red the member's last pre-batch run is red" "$UNK" "$(o1 o1r 9600030 'merge queue: embarking #7021 and #7022 together' | cr)"
check "O1-wf the member's green run is another workflow" "$UNK" "$(o1 o1w 9600040 'merge queue: embarking #7031 and #7022 together' | cr)"
check "O1-removed the member removed the unit" "$UNK" "$(o1 o1x 9600050 'merge queue: embarking #7041 and #7022 together' | cr)"
check "O1-notitle a title with no #N" "$UNK" "$(o1 o1n 9600010 'merge queue: embarking together' | cr)"
check "O1-notitle no pulls/ read" 0 "$(cnt '/pulls/' "$T/o1n.shim")"
check "O1-notbatch a PR row with a #N title is not a batch" "$UNK" \
  "$(o1 o1p 9600010 'Fix #7001 and #7002' CTV_IS_BATCH=0 CTV_HEAD_BRANCH=ticket/fx | cr)"

# ── T1 / R1: the next green head of the same PR ─────────────────────────────
pr() { # pr <case> <branch> <pr> <red head> [NAME=V ...]
  local c=$1 b=$2 n=$3 s=$4; shift 4
  rule "$c" CTV_REPO=$REPO CTV_EVENT=pull_request CTV_HEAD_BRANCH="$b" CTV_IS_BATCH=0 CTV_HEAD_SHA="$s" \
    CTV_BASE_SHA="$(h40 b0)" CTV_PR_NUMBERS="$n" CTV_WORKFLOW_ID=$W CTV_RUN_ID=9700010 CTV_ATTEMPT=1 CTV_DAY=2026-10-14 \
    CTV_JOB_CONCLUSION=failure "CTV_JOB_NAME=run the traced corpus" CTV_UNIT=$U CTV_RC=1 "CTV_DISPLAY_TITLE=fixture" "$@"
}
check "T1+a the next green head changed one test path" \
  "test-defect${TAB}T1.followup-tests-only${TAB}next green head $(h40 91 | cut -c1-12) (run 9700015) changed only test paths: tests/x-fixture.sh" \
  "$(pr t1a ticket/fx-t1a 7101 "$(h40 71)")"
check "T1+b test paths and catalog/fixtures, base moved (main's change subtracted)" "test-defect${TAB}T1.followup-tests-only" \
  "$(pr t1b ticket/fx-t1b 7102 "$(h40 72)" | cr)"
check "T1-mixed a reaching non-test path is R1, not T1" "real-pr${TAB}R1.followup-reaches-suite" \
  "$(pr t1m ticket/fx-t1m 7103 "$(h40 73)" | cr)"
check "T1-rebase an empty follow-up set" "$UNK" "$(pr t1r ticket/fx-t1r 7104 "$(h40 74)" | cr)"
check "T1-batch a mergify draft run is not a PR row" "$UNK" \
  "$(pr t1q mergify/merge-queue/main/t1 7105 "$(h40 75)" | cr)"
check "T1-batch no branch run list read" 0 "$(cnt 'event=pull_request' "$T/t1q.shim")"
check "T1-nopr a row with no PR number" "$UNK" "$(pr t1n ticket/fx-t1a '' "$(h40 71)" | cr)"
check "T1-nonext no green run after the red run" "$UNK" "$(pr t1x ticket/fx-t1a 7101 "$(h40 71)" CTV_RUN_ID=9700020 | cr)"
check "R1+a a non-test path the map links to the unit" \
  "real-pr${TAB}R1.followup-reaches-suite${TAB}next green head $(h40 96 | cut -c1-12) (run 9700015) changed bin/fx-reach.sh docs/x.md which reaches $U" \
  "$(pr r1a ticket/fx-r1a 7111 "$(h40 76)")"
check "R1+b a renamed file under a directory row" "real-pr${TAB}R1.followup-reaches-suite" \
  "$(pr r1b ticket/fx-r1b 7112 "$(h40 77)" | cr)"
check "R1-noreach a non-test path of another suite" "$UNK" "$(pr r1n ticket/fx-r1n 7113 "$(h40 78)" | cr)"
check "R1-always the unit is picked only by an always row" "$UNK" "$(pr r1w ticket/fx-r1a 7111 "$(h40 76)" CTV_UNIT=$U2 | cr)"
check "R1-unread the compare answers 502" "$UNK" "$(pr r1u ticket/fx-r1a 7111 "$(h40 76)" SHIM_FAIL_RE=/compare/ | cr)"
check "FP-404 a force-pushed red head GitHub does not compare" "$UNK" "$(pr fp ticket/fx-fp 7114 "$(h40 79)" | cr)"
grep -q "/compare/$(h40 79)\.\.\.$(h40 99)$" "$T/fp.shim" && ok "FP-404 the compare was asked" || bad "FP-404 no compare GET"
check "FP-404 no cache/fu/ file" "" "$(find "$T/out-fp/cache/fu" -type f 2>/dev/null)"

# ── T2 / R2: a fix PR merged on main ────────────────────────────────────────
mn() { # mn <case> <workflow> [NAME=V ...]
  local c=$1 w=$2; shift 2
  rule "$c" CTV_REPO=$REPO CTV_EVENT=push CTV_HEAD_BRANCH=main CTV_IS_BATCH=0 CTV_HEAD_SHA="$(h40 d0)" CTV_PR_NUMBERS= \
    CTV_WORKFLOW_ID="$w" CTV_RUN_ID=9800010 CTV_ATTEMPT=1 CTV_DAY=2026-10-14 CTV_JOB_CONCLUSION=failure \
    "CTV_JOB_NAME=run the traced corpus" CTV_UNIT=$U CTV_RC=1 "CTV_DISPLAY_TITLE=fixture" "$@"
}
check "T2+a the fix PR names the unit, tests only" \
  "test-defect${TAB}T2.main-fix-tests-only${TAB}#7301 merged between $(h40 d0 | cut -c1-12) and $(h40 41 | cut -c1-12), names ${U##*/}, changed only test paths" \
  "$(mn t2a 5400001)"
check "T2+b the fix PR names the red run id" \
  "test-defect${TAB}T2.main-fix-tests-only${TAB}#7302 merged between $(h40 d0 | cut -c1-12) and $(h40 42 | cut -c1-12), names run 9800010, changed only test paths" \
  "$(mn t2b 5400002)"
check "T2-idsub the run id only inside a longer number" "$UNK" "$(mn t2i 5400003 | cr)"
check "T2-unmerged the PR that names the unit did not merge" "$UNK" "$(mn t2u 5400004 | cr)"
check "R2+a the fix PR has a reaching non-test path" \
  "real-main${TAB}R2.main-fix-pr${TAB}#7305 merged between $(h40 d0 | cut -c1-12) and $(h40 45 | cut -c1-12), names ${U##*/}, changed bin/fx-reach.sh which reaches $U" \
  "$(mn r2a 5400005)"
check "R2+b the second merged PR names the run id" "real-main${TAB}R2.main-fix-pr" "$(mn r2b 5400006 | cr)"
check "R2+b both merge commits' PRs were read" 2 "$(cnt '/pulls/730[67]$' "$T/r2b.shim")"
check "R2-noref no merged PR names the unit or the run" "$UNK" "$(mn r2n 5400007 | cr)"
check "R2-noreach the named PR does not reach the unit: F2 decides" "flake${TAB}F2.main-unrelated-green" \
  "$(mn r2x 5400008 | cr)"
check "R2-unread the compare answers 502" "$UNK" "$(mn r2u 5400005 SHIM_FAIL_RE=/compare/ | cr)"
check "R2-pr a pull_request row reads no main green list" "$UNK" \
  "$(mn r2p 5400005 CTV_EVENT=pull_request CTV_HEAD_BRANCH=ticket/x | cr)"
check "R2-pr no main green read" 0 "$(cnt 'branch=main' "$T/r2p.shim")"

# ── B1.batch-member-fix ─────────────────────────────────────────────────────
check "B1+real a merged member's new head changed a reaching path" \
  "real-pr${TAB}B1.batch-member-fix${TAB}#7401 new head $(h40 61 | cut -c1-12) after the batch changed bin/fx-reach.sh which reaches $U" \
  "$(o1 b1r 9900010 'merge queue: embarking #7401 and #7402 together')"
check "B1+test a tests-only follow-up that reaches the unit" \
  "test-defect${TAB}B1.batch-member-fix${TAB}#7411 new head $(h40 63 | cut -c1-12) after the batch changed only test paths that reach $U" \
  "$(o1 b1t 9900020 'merge queue: embarking #7411 and #7412 together')"
check "B1-unmerged the member never merged" "$UNK" "$(o1 b1u 9900030 'merge queue: embarking #7421 together' | cr)"
check "B1-nohead no new green head after the batch" "$UNK" "$(o1 b1n 9900040 'merge queue: embarking #7431 together' | cr)"
check "B1-404 the follow-up compare is 404" "$UNK" "$(o1 b14 9900050 'merge queue: embarking #7441 together' | cr)"
check "B1-noreach the follow-up does not reach the unit" "$UNK" "$(o1 b1o 9900060 'merge queue: embarking #7451 together' | cr)"
check "B1-notitle a title with no #N" "$UNK" "$(o1 b1x 9900010 'merge queue: embarking together' | cr)"
check "B1-notitle no pulls/ read" 0 "$(cnt '/pulls/' "$T/b1x.shim")"
check "B1-pr a PR row is not a batch" "$UNK" \
  "$(o1 b1p 9900010 'merge queue: embarking #7401 and #7402 together' CTV_IS_BATCH=0 CTV_HEAD_BRANCH=ticket/fx | cr)"

# ── LEDGER: every rule read is in the read ledger ───────────────────────────
for c in o1a t1b r2b b1r; do
  check "LEDGER $c: the ledger holds one line per GET" "$(gets "$T/$c.shim")" "$(ledger "$T/out-$c")"
done
refused=$(cat "$T"/*.shim.refused 2>/dev/null)
check "REFUSED no rule row sent a non-GET" "" "$refused"

# ── E2E: the CLI over the fixture set ───────────────────────────────────────
EO="$T/out-e2e"
RC=0
env PATH="$T/bin:$PATH" HARNESS="$T/h-e2e" HARNESS_TEST_SANDBOX=1 HARNESS_SECRET=secret-fixture-ctv \
  JOBS_URL=http://192.0.2.10:8787 CTV_NOW="$CTV_TEST_NOW" GH_TOKEN=tok-fixture-ctv SHIM_LOG="$T/e2e.shim" SHIM_FIX="$FIX" \
  CTV_IMPACT_MAP="$FIX/impact-map.tsv" CTV_F2_IMPACT_MAP="$FIX/impact-map.tsv" \
  "$CLI" --days 1 --no-model --out "$EO" > "$T/e2e.out" 2> "$T/e2e.err" || RC=$?
check "E2E the CLI is rc 0" 0 "$RC"
[ "$RC" = 0 ] || cat "$T/e2e.err"
[ -e "$T/e2e.shim.refused" ] && bad "E2E the shims refused: $(cat "$T/e2e.shim.refused")" || ok "E2E no REFUSED line from the shims"
occ() { grep -v '^#' "$EO/occurrences.tsv" 2>/dev/null | awk -F'\t' -v r="$1" '$1 == r { print $11 "\t" $12 }'; }
check "E2E the PR run with a reaching follow-up is real-pr R1" "real-pr${TAB}R1.followup-reaches-suite" "$(occ 9910001)"
check "E2E the PR run with a tests-only follow-up is test-defect T1" "test-defect${TAB}T1.followup-tests-only" "$(occ 9910002)"
check "E2E the push run on main with a fix PR is real-main R2" "real-main${TAB}R2.main-fix-pr" "$(occ 9910003)"
check "E2E the 2-member batch is order O1" "order${TAB}O1.batch-member-added-suite" "$(occ 9910004)"
check "E2E the 1-member batch is not order" "$UNK" "$(occ 9910005)"
EJ="$EO/2026-10-14/ci-test-value.json"
check "E2E the driver's gh_reads plus the rule ledger equal the shim's GETs" "$(gets "$T/e2e.shim")" \
  "$(( $(jq -r .coverage.gh_reads "$EJ" 2>/dev/null || echo 0) + $(ledger "$EO") ))"

echo
if [ "$FAILS" -eq 0 ]; then echo "PASS ci-test-value-catch.bh-6618"; exit 0; fi
echo "FAILED $FAILS check(s) in ci-test-value-catch.bh-6618"; exit 1
