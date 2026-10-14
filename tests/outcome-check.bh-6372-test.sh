#!/bin/bash
# tests/outcome-check.bh-6372-test.sh — bin/outcome-check.sh (BH-6382, slice C3
# of BH-6372) and its measurer bin/lib/outcome-metrics.d/mq-full-share.sh,
# driven against a scratch harness.
#
# THE WIRING IS REAL where it decides. The lane runs as shipped. The classifier
# (bin/lib/perf-ticket.sh + catalog/perf-ticket.tsv) and the REST layer
# (bin/lib/gh-rest.sh) are the real ones: tests/lib/gh-rest-fx.sh fakes only
# `gh`, and the issue fixtures are the real #5354 (perf) and #6049 (negative)
# bodies from tests/fixtures/bh-6372/. Faked: the jobs client (a jq store that
# logs every list and put), the lane gate, the GitHub budget, alert-line.sh
# (one line per call into logs/ALERTS.log), and, in the main tree, the
# mq-full-share measurer (it answers $FAKE_M, rc $FAKE_M_RC). E2E-M runs the
# real measurer in a second tree.
#
# CASES (the plan's acceptance list): O1-O5, T-due-edge, X1, X2, B1, S1, M5,
# F1, U1, P1, D1, D2, I1, OV1, W1, W2, W-edge, ME1, C3, N1, L1, NM1, CAP1, LB1,
# NC1, BL1, DRY, REG1, M1-M4, E2E-M.
#
#   HARNESS_TEST_SANDBOX=1 bash tests/outcome-check.bh-6372-test.sh   exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# shellcheck source=tests/lib/gh-rest-fx.sh
. "$(dirname "$0")/lib/gh-rest-fx.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
FX="$SRC/tests/fixtures/bh-6372"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
for f in issue-5354 issue-6049; do
  [ -r "$FX/$f.json" ] || { echo "FAIL: fixture missing: tests/fixtures/bh-6372/$f.json"; exit 1; }
done

NOW=$(date -u -d '2026-10-13T12:00:00Z' +%s)
HR=3600
iso() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
R=example-org/cromford
U() { echo "https://github.com/$R/pull/$1"; }
PERF='Closes #5354

Target metric: mq-full-share from 0.92 to 0.30'

ghfx_init
ghfx_extra <<'SH'
# Keep each POST body: the lane sends it as -F body=@<file>.
case "$A" in
  *"-X POST "*) for a in "$@"; do
      case "$a" in body=@*) { cat "${a#body=@}"; echo "=====END"; } >> "$GHFX/post-bodies.txt" ;; esac
    done ;;
esac
SH
mkdir -p "$T/tmp"

# mk_tree <dir> [stub] — one scratch harness. Stubs first: scratch_install_closure
# never clobbers a file already there, so with `stub` the measurer is the fake.
mk_tree() {
  local h="$1"
  mkdir -p "$h/bin/lib/outcome-metrics.d" "$h/logs" "$h/catalog"
  cat > "$h/bin/lib/lane-gate.sh" <<'SH'
lane_gate_or_exit() { :; }
lane_env_apply() { :; }
SH
  cat > "$h/bin/lib/gh-budget.sh" <<'SH'
gh_budget_low() { return "${FAKE_BUDGET_LOW:-1}"; }
SH
  cat > "$h/bin/alert-line.sh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/logs/ALERTS.log"
SH
  chmod +x "$h/bin/alert-line.sh"
  cat > "$h/bin/jobs-client.sh" <<'SH'
jobs_configured() { [ -n "${JOBS_URL:-}" ]; }
JOBS_HTTP=""
job_ledger_list() {
  echo "LIST $1" >> "$HARNESS/jobs-calls.txt"
  case ",${FAKE_LIST_FAIL:-}," in *",$1,"*) JOBS_HTTP=503; return 1 ;; esac
  case "$1" in
    merge) [ -f "$HARNESS/merge.tsv" ] && cat "$HARNESS/merge.tsv"; return 0 ;;
    outcome-check)
      [ -f "$HARNESS/oc-store.json" ] || return 0
      jq -r 'to_entries | sort_by(.value.seq) | reverse[] | [.key, .value.status, "-", "2026-10-13T00:00:00Z"] | @tsv' "$HARNESS/oc-store.json"
      return 0 ;;
  esac
  return 0
}
job_ledger_put() {
  local S="$HARNESS/oc-store.json" n
  echo "PUT $1 $2 $3 | ${4:-}" >> "$HARNESS/jobs-calls.txt"
  [ "$1" = outcome-check ] || return 1
  case ",${FAKE_PUT_FAIL:-}," in *",$3,"*) JOBS_HTTP=503; return 1 ;; esac
  [ -f "$S" ] || echo '{}' > "$S"
  n=$(( $(cat "$HARNESS/seq" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$HARNESS/seq"
  jq --arg k "$2" --arg s "$3" --arg d "${4:-}" --argjson n "$n" '.[$k] = {status: $s, detail: $d, seq: $n}' "$S" > "$S.n" && mv "$S.n" "$S"
}
_jobs_req() {
  echo "REQ $1 $2" >> "$HARNESS/jobs-calls.txt"
  case "$1 $2" in
    "GET /api/ci-batches"*) [ -z "${FAKE_CB_FAIL:-}" ] || { JOBS_HTTP=503; return 1; }
      cat "$HARNESS/ci-batches.json" ;;
    *) return 1 ;;
  esac
}
SH
  if [ "${2:-}" = stub ]; then
    cat > "$h/bin/lib/outcome-metrics.d/mq-full-share.sh" <<'SH'
om_mq_full_share() {
  echo "$1 $2 ${OM_REPO:-}" >> "$HARNESS/measure-calls.txt"
  [ -z "${FAKE_M_RC:-}" ] || return "$FAKE_M_RC"
  echo "${FAKE_M:-0.92 10}"
}
SH
  fi
  scratch_install_closure bin/outcome-check.sh "$h" >/dev/null || bad "cannot install the bin/outcome-check.sh closure into $h"
  cp "$SRC/catalog/perf-ticket.tsv" "$h/catalog/perf-ticket.tsv"
}

routes_default() { # routes_default [post-status] [search-body]
  local none='{"total_count":0,"items":[]}'
  ghfx_route GET "repos/$R/issues/5354" 200 "$(cat "$FX/issue-5354.json")"
  ghfx_route GET "repos/$R/issues/6049" 200 "$(cat "$FX/issue-6049.json")"
  ghfx_route GET "search/issues" 200 "${2:-$none}"
  ghfx_route POST "repos/$R/issues" "${1:-201}" '{"number":7001,"html_url":"https://github.com/example-org/cromford/issues/7001"}'
}
# add_pr <n> <merged-age-s|-> <body> [ledger-age-s] [title]
add_pr() {
  local la="${4:-$2}"
  [ "$la" = - ] && la=$(( 7 * HR ))
  pr_route "$@"
  printf '%s\tmerged\t-\t%s\n' "$(U "$1")" "$(iso "$la")" >> "$HH/merge.tsv"
}
pr_route() { # pr_route <n> <merged-age-s|-> <body> [ledger-age-s] [title] — the GitHub side only
  local m="-"
  [ "$2" = - ] || m=$(iso "$2")
  ghfx_route GET "repos/$R/pulls/$1" 200 "$(jq -nc --argjson n "$1" --arg m "$m" --arg b "$3" --arg t "${5:-Faster CI}" \
    '{number: $n, title: $t, body: $b, state: "closed", labels: [],
      merged_at: (if $m == "-" then null else $m end), html_url: ("https://github.com/example-org/cromford/pull/" + ($n|tostring))}')"
}
reset() {
  rm -f "$HH/merge.tsv" "$HH/oc-store.json" "$HH/seq" "$HH/logs/"* "$T/post-bodies.txt" "$HH/ci-batches.json"
  ghfx_routes_reset; rm -f "$T/rest-bodies/"*; rm -f "$T/rest-bodies/.n"
}
ARGS=()
drive() { # drive [VAR=val...] — one tick of the lane in $HH
  rm -f "$HH/jobs-calls.txt" "$HH/measure-calls.txt"; ghfx_log_reset
  ( unset GH_TOKEN GH_LIMIT_IDENTITY GH_TOKEN_INSTALLATION_ID PERF_TICKET_CATALOG OUTCOME_CHECK_DELAY_H \
      OUTCOME_CHECK_LOOKBACK_H OUTCOME_CHECK_MIN_SAMPLES OUTCOME_CHECK_MAX_WAIT_H OUTCOME_CHECK_MAX_PRS OUTCOME_CHECK_DEADLINE_S
    export HARNESS="$HH" NOW PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.test HARNESS_SECRET=fixture-secret \
      GH_ETAG=0 TMPDIR="$T/tmp" HARNESS_REPO="$R"
    [ $# -gt 0 ] && export "${@?}"
    bash "$HH/bin/outcome-check.sh" ${ARGS[@]+"${ARGS[@]}"} ) > "$T/out.txt" 2>&1
  RC=$?
}
cnt() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }
posts()  { cnt "^api -i -X POST repos/$R/issues " "$T/gh-argv.log"; }
ghn()    { if [ -f "$T/gh-argv.log" ]; then wc -l < "$T/gh-argv.log" | tr -d ' '; else echo 0; fi; }
mcalls() { if [ -f "$HH/measure-calls.txt" ]; then wc -l < "$HH/measure-calls.txt" | tr -d ' '; else echo 0; fi; }
puts()   { cnt "^PUT outcome-check ${2:-.*} ${1:-[a-z-]*} |" "$HH/jobs-calls.txt"; }
alerts() { if [ -f "$HH/logs/ALERTS.log" ]; then wc -l < "$HH/logs/ALERTS.log" | tr -d ' '; else echo 0; fi; }
st()     { jq -r --arg k "$(U "$1")" '.[$k].status // ""' "$HH/oc-store.json" 2>/dev/null; }
det()    { jq -r --arg k "$(U "$1")" '.[$k].detail // ""' "$HH/oc-store.json" 2>/dev/null; }
LOGF() { echo "$HH/logs/outcome-check.log"; }
logq() { grep -qF -- "$1" "$(LOGF)" 2>/dev/null; }

HH="$T/h"
mk_tree "$HH" stub

# ── O1: perf PR merged 5 h ago -> not measured, nothing written
reset; routes_default
add_pr 101 $(( 5 * HR )) "$PERF"
drive
[ "$RC" = 0 ] && [ "$(mcalls)" = 0 ] && [ "$(puts)" = 0 ] && [ "$(posts)" = 0 ] && ok \
  || bad "O1: merged 5 h ago -> rc 0, 0 measurer calls, 0 puts, 0 POSTs (rc=$RC m=$(mcalls) puts=$(puts) posts=$(posts)): $(cat "$T/out.txt")"
[ "$(cnt "pulls/101" "$T/gh-argv.log")" = 0 ] && ok || bad "O1: a merge row younger than DELAY_H costs no GitHub read (the pre-filter)"

# ── O2: merged 7 h ago, measured 0.92 (n=10) against 0.92 -> 0.30 -> one issue
#    (equal distance is NOT moved: this is also D2)
reset; routes_default
add_pr 102 $(( 7 * HR )) "$PERF"
drive
[ "$RC" = 0 ] && [ "$(posts)" = 1 ] && ok || bad "O2: exactly one issue POST (rc=$RC posts=$(posts)): $(cat "$(LOGF)" 2>/dev/null)"
PB=$(cat "$T/post-bodies.txt" 2>/dev/null)
for s in "<!-- outcome-check: $R#102 -->" "PR: $(U 102)" "Metric: mq-full-share" "Target: from 0.92 to 0.30" \
         "Measured: 0.92 (n=10) over $(iso $(( 7 * HR ))) to $(iso 0)" "The metric did not move toward the target." \
         "Check the PR's change, or correct its target."; do
  grep -qF -- "$s" <<<"$PB" && ok || bad "O2: the issue body has '$s': $PB"
done
PL=$(grep "^api -i -X POST repos/$R/issues " "$T/gh-argv.log" 2>/dev/null)
grep -qF -- "title=outcome-check: $R#102 did not move mq-full-share toward its target" <<<"$PL" && ok || bad "O2: the issue title: $PL"
grep -q 'labels' <<<"$PL" && bad "O2: the POST sends no labels field (no ai-build): $PL" || ok
[ "$(st 102)" = filed ] && grep -q 'issue=7001$' <<<"$(det 102)" && ok || bad "O2: ledger row filed with issue=7001: $(st 102) / $(det 102)"
[ "$(det 102)" = "mq-full-share from 0.92 to 0.30 measured 0.92 n=10 issue=7001" ] && ok || bad "O2: the row detail: $(det 102)"
logq "outcome-check: $R#102 mq-full-share from 0.92 to 0.30 measured 0.92 (n=10) -> filed" && ok \
  || bad "O2: the -> filed log line: $(cat "$(LOGF)")"
[ "$(cnt "^$(U 102)" "$HH/measure-calls.txt")" = 0 ] && grep -q "^$(iso $(( 7 * HR ))) $(iso 0) $R$" "$HH/measure-calls.txt" && ok \
  || bad "O2: the measurer gets <merged_at> <now> with OM_REPO=<pr repo>: $(cat "$HH/measure-calls.txt" 2>/dev/null)"
[ "$(puts filing)" = 1 ] && [ "$(puts filed)" = 1 ] && ok || bad "O2: filing then filed, once each: $(cat "$HH/jobs-calls.txt")"
[ "$(alerts)" = 0 ] && ok || bad "O2: a filed issue is not an ALERTS line"

# ── O5: a second tick after O2 -> no second POST, no measurement
drive
[ "$(posts)" = 0 ] && [ "$(mcalls)" = 0 ] && [ "$(puts)" = 0 ] && ok \
  || bad "O5: tick 2 POSTs nothing and measures nothing (posts=$(posts) m=$(mcalls) puts=$(puts))"

# ── DRY: --dry-run on the O2 state -> the would-be line, nothing written or sent
reset; routes_default
add_pr 102 $(( 7 * HR )) "$PERF"
ARGS=(--dry-run); drive; ARGS=()
[ "$RC" = 0 ] && [ "$(puts)" = 0 ] && [ "$(posts)" = 0 ] && [ "$(alerts)" = 0 ] && [ "$(cnt 'search/issues' "$T/gh-argv.log")" = 0 ] && ok \
  || bad "DRY: 0 puts, 0 POSTs, 0 searches, 0 ALERTS (rc=$RC puts=$(puts) posts=$(posts))"
grep -qF "outcome-check: $R#102 mq-full-share from 0.92 to 0.30 measured 0.92 (n=10) -> filed (dry run)" "$T/out.txt" && ok \
  || bad "DRY: stdout has the would-be '-> filed (dry run)' line: $(cat "$T/out.txt")"

# ── O3: measured 0.40 -> moved, no POST
reset; routes_default
add_pr 103 $(( 7 * HR )) "$PERF"
drive FAKE_M="0.40 10"
[ "$(posts)" = 0 ] && [ "$(st 103)" = moved ] && ok || bad "O3: 0.40 is closer to 0.30 -> moved, 0 POSTs (posts=$(posts) st=$(st 103))"
logq "outcome-check: $R#103 mq-full-share from 0.92 to 0.30 measured 0.40 (n=10) -> moved" && ok || bad "O3: the moved log line: $(cat "$(LOGF)")"

# ── OV1: overshoot (0.10 against 0.92 -> 0.30) is moved
reset; routes_default
add_pr 105 $(( 7 * HR )) "$PERF"
drive FAKE_M="0.10 10"
[ "$(st 105)" = moved ] && [ "$(posts)" = 0 ] && ok || bad "OV1: overshoot -> moved: $(st 105)"

# ── worse (1.00) -> filed
reset; routes_default
add_pr 106 $(( 7 * HR )) "$PERF"
drive FAKE_M="1.00 10"
[ "$(st 106)" = filed ] && [ "$(posts)" = 1 ] && ok || bad "D2: 1.00 is further from 0.30 -> filed: $(st 106)"

# ── I1: an increasing target, 10 -> 20
reset; routes_default
add_pr 107 $(( 7 * HR )) "Closes #5354

Target metric: mq-full-share from 10 to 20"
drive FAKE_M="15 10"
[ "$(st 107)" = moved ] && ok || bad "I1: 15 against 10 -> 20 is moved: $(st 107)"
reset; routes_default
add_pr 107 $(( 7 * HR )) "Closes #5354

Target metric: mq-full-share from 10 to 20"
drive FAKE_M="9 10"
[ "$(st 107)" = filed ] && [ "$(posts)" = 1 ] && ok || bad "I1: 9 against 10 -> 20 is not moved -> filed: $(st 107)"

# ── O4 and the due edges
reset; routes_default
add_pr 104 $(( 3 * HR )) "$PERF"
drive
[ "$(mcalls)" = 0 ] && ok || bad "O4: at the default DELAY_H=6, 3 h is not due"
drive OUTCOME_CHECK_DELAY_H=2
[ "$(mcalls)" = 1 ] && ok || bad "O4: OUTCOME_CHECK_DELAY_H=2 -> measured at 3 h (m=$(mcalls))"
reset; routes_default
add_pr 108 $(( 6 * HR )) "$PERF"
drive
[ "$(mcalls)" = 1 ] && ok || bad "T-due-edge: merged exactly 6 h ago is due (m=$(mcalls)): $(cat "$(LOGF)")"
reset; routes_default
add_pr 109 $(( 6 * HR - 60 )) "$PERF"
drive
[ "$(mcalls)" = 0 ] && [ "$(puts)" = 0 ] && ok || bad "T-due-edge: 5 h 59 m is not due"
# merged_at is the authority: the merge row is 7 h old, GitHub says 5 h 59 m
reset; routes_default
add_pr 110 $(( 6 * HR - 60 )) "$PERF" $(( 7 * HR ))
drive
[ "$(mcalls)" = 0 ] && [ "$(puts)" = 0 ] && [ "$(cnt "pulls/110" "$T/gh-argv.log")" = 1 ] && ok \
  || bad "T-due-edge: merged_at (5 h 59 m) wins over the merge row's 7 h; read, not measured (m=$(mcalls))"

# ── X1: either ledger list fails -> rc 1, no GitHub call, no POST
reset; routes_default
add_pr 111 $(( 7 * HR )) "$PERF"
drive FAKE_LIST_FAIL=merge
[ "$RC" = 1 ] && [ "$(ghn)" = 0 ] && [ "$(puts)" = 0 ] && logq 'ledger unreadable' && ok \
  || bad "X1: merge ledger down -> rc 1, 0 GitHub calls (rc=$RC gh=$(ghn)): $(cat "$(LOGF)" 2>/dev/null)"
drive FAKE_LIST_FAIL=outcome-check
[ "$RC" = 1 ] && [ "$(ghn)" = 0 ] && [ "$(puts)" = 0 ] && ok \
  || bad "X1: done-set unreadable -> rc 1, 0 GitHub calls (rc=$RC gh=$(ghn))"

# ── W1 / X2: too few samples -> wait once; then moved; each status put once
reset; routes_default
add_pr 112 $(( 7 * HR )) "$PERF"
drive FAKE_M="0.92 4"
[ "$(st 112)" = wait ] && [ "$(posts)" = 0 ] && [ "$(alerts)" = 0 ] && ok || bad "W1: n=4 at 7 h -> wait: $(st 112)"
drive FAKE_M="0.92 4"
[ "$(mcalls)" = 1 ] && [ "$(puts)" = 0 ] && ok || bad "W1/X2: a wait row is measured again but not re-put (m=$(mcalls) puts=$(puts))"
drive FAKE_M="0.40 10"
[ "$(st 112)" = moved ] && ok || bad "X2: the third tick decides moved: $(st 112)"
drive FAKE_M="0.40 10"
[ "$(cnt "^PUT outcome-check $(U 112) wait " "$HH/jobs-calls.txt")" = 0 ] && [ "$(mcalls)" = 0 ] && ok || bad "X2: a terminal row is not read again"
# W-edge: n = MIN_SAMPLES (5) is enough
reset; routes_default
add_pr 113 $(( 7 * HR )) "$PERF"
drive FAKE_M="0.92 5"
[ "$(st 113)" = filed ] && ok || bad "W-edge: n=5 = MIN_SAMPLES decides: $(st 113)"
# n=0 prints '- 0' and is too few, never a 0.00 share
reset; routes_default
add_pr 114 $(( 7 * HR )) "$PERF"
drive FAKE_M="- 0"
[ "$(st 114)" = wait ] && [ "$(det 114)" = "mq-full-share from 0.92 to 0.30 measured - n=0" ] && ok || bad "W1: '- 0' -> wait: $(st 114) / $(det 114)"

# ── W2: n=4 at 25 h -> insufficient, exactly one ALERTS line over two ticks
reset; routes_default
add_pr 115 $(( 25 * HR )) "$PERF"
drive FAKE_M="0.92 4"
drive FAKE_M="0.92 4"
[ "$(st 115)" = insufficient ] && [ "$(alerts)" = 1 ] && [ "$(posts)" = 0 ] && ok \
  || bad "W2: insufficient + 1 ALERTS line (st=$(st 115) alerts=$(alerts))"
grep -q "$R#115" "$HH/logs/ALERTS.log" 2>/dev/null && ok || bad "W2: the ALERTS line names the PR"

# ── B1: three perf PRs with no target line -> no-target, no POST, no ALERTS
reset; routes_default
for n in 121 122 123; do add_pr "$n" $(( 7 * HR )) "Closes #5354

Faster merge queue."; done
drive
[ "$(st 121)$(st 122)$(st 123)" = no-targetno-targetno-target ] && [ "$(posts)" = 0 ] && [ "$(alerts)" = 0 ] && [ "$(mcalls)" = 0 ] && ok \
  || bad "B1: 3 x no-target, 0 POSTs, 0 ALERTS (posts=$(posts) alerts=$(alerts)): $(st 121) $(st 122) $(st 123)"

# ── S1: the POST fails -> file-failed, no filed line; next tick files once
reset; routes_default 500
add_pr 124 $(( 7 * HR )) "$PERF"
drive
[ "$(st 124)" = file-failed ] && [ "$(puts filed)" = 0 ] && [ "$(alerts)" = 0 ] && ok \
  || bad "S1: POST 500 -> file-failed (st=$(st 124) filed-puts=$(puts filed))"
logq '-> filed' && bad "S1: no '-> filed' log line on a failed POST" || ok
ghfx_routes_reset; routes_default; pr_route 124 $(( 7 * HR )) "$PERF"
drive
[ "$(posts)" = 1 ] && [ "$(st 124)" = filed ] && ok || bad "S1: the next tick POSTs once and stamps filed (posts=$(posts) st=$(st 124))"

# ── M5: an issue with the marker already exists (closed) -> filed, no POST
reset
routes_default 201 "{\"total_count\":2,\"items\":[{\"number\":6990,\"state\":\"open\",\"body\":\"outcome-check: $R#125 is a title echo\"},{\"number\":6999,\"state\":\"closed\",\"body\":\"<!-- outcome-check: $R#125 -->\\nPR: x\"}]}"
add_pr 125 $(( 7 * HR )) "$PERF"
drive
[ "$(posts)" = 0 ] && [ "$(st 125)" = filed ] && grep -q 'issue=6999$' <<<"$(det 125)" && ok \
  || bad "M5: marker hit -> filed issue=6999, 0 POSTs (posts=$(posts) det=$(det 125))"
grep -q 'search/issues' "$T/gh-argv.log" && grep -qF "in:title \"outcome-check: $R#125\"" "$T/gh-argv.log" && ok \
  || bad "M5: the search asks for the deterministic title: $(grep search "$T/gh-argv.log")"
# a title hit without the marker is not a match
reset
routes_default 201 "{\"total_count\":1,\"items\":[{\"number\":6990,\"state\":\"open\",\"body\":\"outcome-check: $R#126\"}]}"
add_pr 126 $(( 7 * HR )) "$PERF"
drive
[ "$(posts)" = 1 ] && grep -q 'issue=7001$' <<<"$(det 126)" && ok || bad "M5: a hit without the marker -> POST (posts=$(posts))"
# an unverifiable search -> file-failed, no POST
reset; ghfx_route GET "search/issues" 403 '{"message":"API rate limit exceeded"}'; routes_default
add_pr 127 $(( 7 * HR )) "$PERF"
drive
[ "$(posts)" = 0 ] && [ "$(st 127)" = file-failed ] && ok || bad "M5: search rc 75 -> file-failed, 0 POSTs (posts=$(posts) st=$(st 127))"

# ── F1: POST OK, then the put of filed fails -> row stays filing; next tick finds the marker
reset; routes_default
add_pr 128 $(( 7 * HR )) "$PERF"
drive FAKE_PUT_FAIL=filed
[ "$(posts)" = 1 ] && [ "$(st 128)" = filing ] && ok || bad "F1: POST once, row stays filing (posts=$(posts) st=$(st 128))"
logq '-> filed' && bad "F1: no '-> filed' line when the put failed" || ok
logq 'ledger write failed' && ok || bad "F1: the failed put is logged: $(cat "$(LOGF)")"
ghfx_routes_reset
routes_default 201 "{\"total_count\":1,\"items\":[{\"number\":7001,\"state\":\"open\",\"body\":\"<!-- outcome-check: $R#128 -->\"}]}"
pr_route 128 $(( 7 * HR )) "$PERF"
drive
[ "$(posts)" = 0 ] && [ "$(st 128)" = filed ] && grep -q 'issue=7001$' <<<"$(det 128)" && ok \
  || bad "F1: tick 2 finds the issue by marker, 0 POSTs, filed (posts=$(posts) st=$(st 128))"

# ── a put failure BEFORE the POST: no POST
reset; routes_default
add_pr 129 $(( 7 * HR )) "$PERF"
drive FAKE_PUT_FAIL=filing
[ "$(posts)" = 0 ] && [ "$(cnt 'search/issues' "$T/gh-argv.log")" = 0 ] && [ -z "$(st 129)" ] && ok \
  || bad "F1: the filing put fails -> no search, no POST (posts=$(posts))"

# ── U1: unknown metric id -> unmeasurable + one ALERTS line over two ticks
reset; routes_default
add_pr 131 $(( 7 * HR )) "Closes #5354

Target metric: no-such-metric from 3 to 1"
drive; drive
[ "$(st 131)" = unmeasurable ] && [ "$(alerts)" = 1 ] && [ "$(posts)" = 0 ] && ok \
  || bad "U1: unmeasurable + 1 ALERTS line (st=$(st 131) alerts=$(alerts))"
grep -q "no-such-metric" "$HH/logs/ALERTS.log" 2>/dev/null && grep -q "$R#131" "$HH/logs/ALERTS.log" && ok \
  || bad "U1: the ALERTS line names the id and the PR: $(cat "$HH/logs/ALERTS.log" 2>/dev/null)"

# ── P1: an unparseable target line -> unparseable + one ALERTS line
reset; routes_default
add_pr 132 $(( 7 * HR )) "Closes #5354

Target metric: mq-full-share from fast to slow"
drive; drive
[ "$(st 132)" = unparseable ] && [ "$(alerts)" = 1 ] && [ "$(mcalls)" = 0 ] && ok \
  || bad "P1: unparseable + 1 ALERTS line (st=$(st 132) alerts=$(alerts))"

# ── D1: from == to -> no-direction
reset; routes_default
add_pr 133 $(( 7 * HR )) "Closes #5354

Target metric: mq-full-share from 0.5 to 0.50"
drive
[ "$(st 133)" = no-direction ] && [ "$(posts)" = 0 ] && [ "$(mcalls)" = 0 ] && ok || bad "D1: 0.5 -> 0.50 is no-direction: $(st 133)"

# ── ME1: the measurer fails, or prints garbage -> no row, no ALERTS, retried
reset; routes_default
add_pr 134 $(( 7 * HR )) "$PERF"
drive FAKE_M_RC=1
[ -z "$(st 134)" ] && [ "$(alerts)" = 0 ] && [ "$(posts)" = 0 ] && logq 'measurer' && ok \
  || bad "ME1: measurer rc 1 -> no row, logged (st=$(st 134)): $(cat "$(LOGF)")"
drive FAKE_M="lots 10"
[ -z "$(st 134)" ] && [ "$(posts)" = 0 ] && ok || bad "ME1: unparseable measurer output -> no row: $(st 134)"
drive FAKE_M="- 7"
[ -z "$(st 134)" ] && ok || bad "ME1: '-' with samples is not a number -> no row: $(st 134)"

# ── C3: the linked issue read fails -> classifier rc 3 -> no row, no POST
reset
ghfx_route GET "repos/$R/issues/5354" 500 '{"message":"boom"}'; routes_default
add_pr 135 $(( 7 * HR )) "$PERF"
drive
[ -z "$(st 135)" ] && [ "$(puts)" = 0 ] && [ "$(posts)" = 0 ] && [ "$(mcalls)" = 0 ] && ok \
  || bad "C3: classifier unknown -> no write (st=$(st 135) puts=$(puts))"

# ── N1: linked #6049 (negative) with a target line -> not-perf
reset; routes_default
add_pr 136 $(( 7 * HR )) "Fixes #6049

Target metric: mq-full-share from 0.92 to 0.30"
drive
[ "$(st 136)" = not-perf ] && [ "$(posts)" = 0 ] && [ "$(mcalls)" = 0 ] && [ "$(alerts)" = 0 ] && ok \
  || bad "N1: a non-perf linked issue -> not-perf, 0 POSTs (st=$(st 136))"
# L1: no linked issue -> the PR's own text is classified (here by its target line)
reset; routes_default
add_pr 137 $(( 7 * HR )) "Target metric: mq-full-share from 0.92 to 0.30" - "Tune the queue"
drive
[ "$(st 137)" = filed ] && [ "$(cnt 'issues/5354' "$T/gh-argv.log")" = 0 ] && ok || bad "L1: no link -> the PR body classifies perf: $(st 137)"
reset; routes_default
add_pr 138 $(( 7 * HR )) "Fix a typo in the README." - "Docs typo"
drive
[ "$(st 138)" = not-perf ] && [ "$(mcalls)" = 0 ] && ok || bad "L1: no link, plain text -> not-perf: $(st 138)"

# ── NM1: the ledger says merged, GitHub says merged_at null -> skip, no row
reset; routes_default
add_pr 139 - "$PERF" $(( 7 * HR ))
drive
[ -z "$(st 139)" ] && [ "$(puts)" = 0 ] && ok || bad "NM1: merged_at null -> no row"

# ── CAP1: MAX_PRS=1 with 3 due -> the oldest decided, 2 deferred
reset; routes_default
add_pr 141 $(( 9 * HR )) "$PERF"
add_pr 142 $(( 8 * HR )) "$PERF"
add_pr 143 $(( 7 * HR )) "$PERF"
drive OUTCOME_CHECK_MAX_PRS=1 FAKE_M="0.40 10"
[ "$(st 141)" = moved ] && [ -z "$(st 142)" ] && [ -z "$(st 143)" ] && ok || bad "CAP1: the oldest goes first, one decided: $(st 141)/$(st 142)/$(st 143)"
logq 'deferred 2' && ok || bad "CAP1: 'deferred 2' is logged: $(cat "$(LOGF)")"
drive OUTCOME_CHECK_MAX_PRS=1 FAKE_M="0.40 10"
[ "$(st 142)" = moved ] && [ -z "$(st 143)" ] && ok || bad "CAP1: the next tick drains the next oldest"

# ── LB1: a merge 50 h ago is outside the lookback
reset; routes_default
add_pr 144 $(( 50 * HR )) "$PERF"
drive
[ "$(cnt 'pulls/144' "$T/gh-argv.log")" = 0 ] && [ -z "$(st 144)" ] && ok || bad "LB1: a 50 h old merge is not read"
grep -q 'seen=0 ' "$(LOGF)" && ok || bad "LB1: the summary counts it out: $(tail -1 "$(LOGF)")"

# ── NC1 / BL1: not configured, budget low -> rc 0, nothing read
reset; routes_default
add_pr 145 $(( 7 * HR )) "$PERF"
drive JOBS_URL=
[ "$RC" = 0 ] && [ "$(ghn)" = 0 ] && [ ! -s "$HH/jobs-calls.txt" ] && logq 'not configured' && ok \
  || bad "NC1: no JOBS_URL -> 'not configured', 0 gh calls, rc 0 (rc=$RC gh=$(ghn))"
grep -q 'fixture-secret' "$(LOGF)" "$T/out.txt" && bad "the secret is never logged" || ok
drive FAKE_BUDGET_LOW=0
[ "$RC" = 0 ] && [ "$(ghn)" = 0 ] && [ ! -s "$HH/jobs-calls.txt" ] && logq 'budget' && ok || bad "BL1: budget low -> rc 0, no read"

# ── the summary line counts outcomes
reset; routes_default
add_pr 146 $(( 7 * HR )) "$PERF"
add_pr 147 $(( 7 * HR )) "Fix a typo." - "Docs"
drive
tail -1 "$(LOGF)" | grep -q 'seen=2 candidates=2 decided=2 filed=1 waiting=0 skipped=0 deferred=0' && ok \
  || bad "summary: $(tail -1 "$(LOGF)")"

# ── REG1: each knob default in the registry is the script's knob default
REGF="$SRC/catalog/lanes.d/outcome-check.json"
for k in OUTCOME_CHECK_DELAY_H OUTCOME_CHECK_LOOKBACK_H OUTCOME_CHECK_MIN_SAMPLES OUTCOME_CHECK_MAX_WAIT_H OUTCOME_CHECK_MAX_PRS OUTCOME_CHECK_DEADLINE_S; do
  rd=$(jq -r --arg k "$k" '.knobs[] | select(.env == $k) | .default' "$REGF" 2>/dev/null)
  sd=$(grep -oE "knob $k [0-9]+" "$SRC/bin/outcome-check.sh" 2>/dev/null | awk '{print $3}')
  [ -n "$rd" ] && [ "$rd" = "$sd" ] && ok || bad "REG1: $k registry default '$rd' = script default '$sd'"
done
[ "$(jq -r '.knobs[] | select(.env == "OUTCOME_CHECK_DELAY_H") | .default' "$REGF" 2>/dev/null)" = 6 ] && ok || bad "REG1: DELAY_H defaults to 6"

# ════ M1-M4: the measurer, through a fake _jobs_req ═════════════════════════
MEAS="$SRC/bin/lib/outcome-metrics.d/mq-full-share.sh"
cbrow() { # cbrow <run_id> <head_ref> <mode> <completed_at>
  jq -nc --argjson i "$1" --arg h "$2" --arg m "$3" --arg c "$4" '{run_id: $i, head_ref: $h, mode: $m, completed_at: $c}'
}
cbset() { # cbset <truncated> <row>... -> $T/cb.json
  local tr="$1"; shift
  local IFS=,; echo "{\"rows\":[$*],\"as_of\":\"x\",\"truncated\":$tr}" > "$T/cb.json"
}
meas() { # meas <since> <until> -> OUT, RC; the read's path in $T/cb-path
  OUT=$(bash -c '_jobs_req() { echo "$2" > "$CBP"; [ -z "${CB_FAIL:-}" ] || return 1; cat "$CBJ"; }
    . "$1" || exit 9; shift; om_mq_full_share "$@"' m "$MEAS" "$@" 2>/dev/null); RC=$?
}
export CBP="$T/cb-path" CBJ="$T/cb.json" OM_REPO="$R"
Q=mergify/merge-queue/main
cbset false "$(cbrow 1 $Q/a full 2026-10-13T06:00:00Z)" "$(cbrow 2 $Q/b batch-selected 2026-10-13T07:00:00Z)" \
  "$(cbrow 3 $Q/c full 2026-10-13T08:00:00Z)" "$(cbrow 4 $Q/d batch-selected 2026-10-13T09:00:00Z)"
meas 2026-10-13T05:00:00Z 2026-10-13T12:00:00Z
[ "$OUT" = "0.50 4" ] && [ "$RC" = 0 ] && ok || bad "M1: 2 full of 4 -> '0.50 4' rc 0, got '$OUT' rc $RC"
[ "$(cat "$T/cb-path" 2>/dev/null)" = "/api/ci-batches?repo=example-org%2Fcromford&since=2026-10-13T05:00:00Z&limit=5000" ] && ok \
  || bad "M1: the read asks for the repo since <since>: $(cat "$T/cb-path" 2>/dev/null)"
cbset false "$(cbrow 1 $Q/a full 2026-10-13T06:00:00Z)" "$(cbrow 2 $Q/b batch-selected 2026-10-13T07:00:00Z)" \
  "$(cbrow 5 $Q/e full-legacy 2026-10-13T07:30:00Z)" "$(cbrow 6 ticket/bh-1 full 2026-10-13T07:40:00Z)" \
  "$(cbrow 7 $Q/f full 2026-10-13T12:30:00Z)"
meas 2026-10-13T05:00:00Z 2026-10-13T12:00:00Z
[ "$OUT" = "0.50 2" ] && ok || bad "M2: legacy, non-queue and after-until rows are out of n -> '0.50 2', got '$OUT'"
cbset false "$(cbrow 6 ticket/bh-1 full 2026-10-13T07:40:00Z)"
meas 2026-10-13T05:00:00Z 2026-10-13T12:00:00Z
[ "$OUT" = "- 0" ] && [ "$RC" = 0 ] && ok || bad "M2: no kept row -> '- 0', never 0.00, got '$OUT' rc $RC"
cbset true "$(cbrow 1 $Q/a full 2026-10-13T06:00:00Z)"
meas 2026-10-13T05:00:00Z 2026-10-13T12:00:00Z
[ -z "$OUT" ] && [ "$RC" = 1 ] && ok || bad "M3: truncated -> rc 1, nothing printed, got '$OUT' rc $RC"
echo '{"error":"x"}' > "$T/cb.json"
meas 2026-10-13T05:00:00Z 2026-10-13T12:00:00Z
[ -z "$OUT" ] && [ "$RC" = 1 ] && ok || bad "M3: no rows array -> rc 1, got '$OUT' rc $RC"
CB_FAIL=1 meas 2026-10-13T05:00:00Z 2026-10-13T12:00:00Z
[ -z "$OUT" ] && [ "$RC" = 1 ] && ok || bad "M4: a failed read -> rc 1, got '$OUT' rc $RC"
unset OM_REPO

# ════ E2E-M: the lane with the REAL measurer ════════════════════════════════
HH="$T/h2"
mk_tree "$HH"
reset; routes_default
# 0.90 is further from 0.30 than 0.80 is: not moved, so the lane files.
add_pr 150 $(( 7 * HR )) "Closes #5354

Target metric: mq-full-share from 0.80 to 0.30"
ROWS=()
for i in 1 2 3 4 5 6 7 8 9; do ROWS+=("$(cbrow "$i" "$Q/r$i" full "$(iso $(( i * 600 )))")"); done
ROWS+=("$(cbrow 10 "$Q/r10" batch-selected "$(iso 300)")" "$(cbrow 11 "$Q/r11" full-legacy "$(iso 300)")" \
  "$(cbrow 12 ticket/bh-9 batch-selected "$(iso 300)")")
( IFS=,; echo "{\"rows\":[${ROWS[*]}],\"as_of\":\"x\",\"truncated\":false}" ) > "$HH/ci-batches.json"
drive
[ "$(posts)" = 1 ] && grep -qF "Measured: 0.90 (n=10)" "$T/post-bodies.txt" 2>/dev/null && [ "$(st 150)" = filed ] && ok \
  || bad "E2E-M: the real measurer feeds 0.90 (n=10) into one POST (posts=$(posts) st=$(st 150)): $(cat "$(LOGF)" 2>/dev/null)"
grep -qF "REQ GET /api/ci-batches?repo=example-org%2Fcromford&since=$(iso $(( 7 * HR )))&limit=5000" "$HH/jobs-calls.txt" && ok \
  || bad "E2E-M: the measurer reads ci_batches since merged_at: $(cat "$HH/jobs-calls.txt")"

echo "outcome-check: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
