#!/bin/bash
# tests/suite-quarantine.bh-9697-test.sh — BH-9697 (Part D of BH-9582): suite
# quarantine. A suite that is red on the PR tree AND red on main AND not changed
# by the diff gets one active suite_quarantine row and leaves the gate's red:.
# The hub lane bin/flaky-tier.sh files ONE repair ticket per row, projects the
# active rows into CI_QUARANTINE (the merge batch drops them), and releases a
# row after a green nightly on a newer main sha.
#
# PINNED. The REAL bin/selection-gate.sh with a stub planner and a stub runner
# (head.out for the head tree, base.out for any other tree), and the REAL
# bin/flaky-tier.sh. The jobs worker is a fake $HARNESS/bin/jobs-client.sh: run
# directly it loads the REAL bin/jobs-client.d/bh-9697-*.sh verbs over a
# stateful fake _jobs_req that keeps the suite_quarantine rows in a JSON file
# the way the worker route does (one active row per (repo, suite)). Q0 drives
# the REAL bin/jobs-client.sh too, over a PATH curl stub. gh is a PATH stub. No
# network, one HARNESS and one TMPDIR per case.
#   Q0  the REAL jobs-client.sh loads the four verbs; list prints the TSV
#   Q1  X red on head and base, not in the diff: quarantined: X, red -,
#       baseline-red -, rc 0, one row with main_sha_red = the base
#   Q2  an active row for X, X red on head: quarantined: X, no base run for X
#   Q3  red head, green base: red X, no put        Q4 the diff edits X: red X, no put
#   Q5  base `FAIL: expected 3` / x.sh.bak lines: red X, no put
#   Q6  an active row for X and the diff edits X: red X
#   Q7  the list read fails: baseline-red X, quarantined -, no put
#   Q8  four candidates, cap 3: none written, quarantine-cap: 4 > 3
#   Q8b the put fails: baseline-red X, write-failed X
#   Q8c knob unset: no quarantined: line, the BH-8901 file
#   Q9  the wrapper _sg_run passes the four knobs; the knob files' defaults
#   Q10 gate.txt readers are unchanged by the two new lines
#   Q11 flaky-tier files one ticket with the marker for a NULL row and links it
#   Q12 an open issue with the marker is reused (no POST); Q12b a linked row: no call
#   Q13 four NULL rows, cap 3: three POSTs      Q14 issue list 502: no POST, row NULL; next tick files it
#   Q15 a newer green nightly on another sha releases the row
#   Q16 the newest run is red: kept   Q17a-d only main_sha_red / older run / unreadable / no line: kept
#   Q18 CI_QUARANTINE = sorted union of the flaky row and the suite row; a
#       protected suite row is not projected     Q19 after release the suite leaves it
#   Q20 --dry-run: no POST, no put, no release, no link
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/suite-quarantine.bh-9697-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SG="${SG:-$DIR/bin/selection-gate.sh}"
LIB="$DIR/bin/lib/selection-gate.sh"
LANE="$DIR/bin/flaky-tier.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -r "$SG" ] || { echo "FAIL: $SG is missing"; exit 1; }
X=tests/x.sh; Y=tests/y.sh
SLUG=example-org/cromford

# ── the fake jobs worker ─────────────────────────────────────────────────────
# mkjc <harness dir> <state dir> — the fake bin/jobs-client.sh. Sourced (as
# flaky-tier does), it gives the REAL bin/lib/jobs/cost.sh clients over the
# fake _jobs_req. Run directly, it sources the REAL bin/jobs-client.d verbs and
# runs jc_verb_<verb>. State: <state>/sq.json (the suite_quarantine rows),
# <state>/rows.json + flakes.json (the flake routes), *.fail files, calls.
mkjc() {
  local h="$1" st="$2"
  mkdir -p "$h/bin" "$st"
  [ -f "$st/sq.json" ] || echo '[]' > "$st/sq.json"
  [ -f "$st/rows.json" ] || echo '{"rows":[]}' > "$st/rows.json"
  [ -f "$st/flakes.json" ] || echo '{"flakes":[]}' > "$st/flakes.json"
  cat > "$h/bin/jobs-client.sh" <<EOF
#!/bin/bash
ST="$st"
# shellcheck source=/dev/null
. "$DIR/bin/lib/jobs/cost.sh"
_jobs_req() {
  echo "JOBS \$1 \$2 \${3:-}" >> "\$ST/calls"
  local body="\${3:-}" now=2026-11-14T12:00:00Z
  case "\$1 \${2%%\?*}" in
    "GET /api/metrics/flakes/quarantine") [ -f "\$ST/rows.fail" ] && return 1; cat "\$ST/rows.json" ;;
    "GET /api/metrics/flakes") cat "\$ST/flakes.json" ;;
    "PUT /api/metrics/flakes/quarantine")
      jq -c --argjson b "\$body" '.rows = ([.rows[] | select(.test != \$b.test)] + [\$b + {updated_at: "2026-11-14 12:00:00"}])' \
        "\$ST/rows.json" > "\$ST/r.tmp" && mv "\$ST/r.tmp" "\$ST/rows.json"; echo '{"ok":true}' ;;
    "GET /api/suite-quarantine")
      [ -f "\$ST/list.fail" ] && return 1
      jq -c '{rows: [.[] | select(.status == "active")] | sort_by(.suite)}' "\$ST/sq.json" ;;
    "POST /api/suite-quarantine")
      [ -f "\$ST/put.fail" ] && return 1
      jq -c --argjson b "\$body" --arg t "\$now" 'if any(.[]; .repo == \$b.repo and .suite == \$b.suite and .status == "active") then .
        else . + [\$b + {id: (length + 1), status: "active", repair_issue: null, created_at: \$t}] end' "\$ST/sq.json" > "\$ST/s.tmp" \
        && mv "\$ST/s.tmp" "\$ST/sq.json"
      jq -c --argjson b "\$body" '{row: ([.[] | select(.repo == \$b.repo and .suite == \$b.suite and .status == "active")][0]), created: true}' "\$ST/sq.json" ;;
    "POST /api/suite-quarantine/issue")
      [ -f "\$ST/issue.fail" ] && return 1
      jq -c --argjson b "\$body" '[.[] | if .repo == \$b.repo and .suite == \$b.suite and .status == "active" and .repair_issue == null
        then .repair_issue = \$b.repair_issue else . end]' "\$ST/sq.json" > "\$ST/s.tmp" && mv "\$ST/s.tmp" "\$ST/sq.json"; echo '{"updated":1}' ;;
    "POST /api/suite-quarantine/release")
      jq -c --argjson b "\$body" --arg t "\$now" '[.[] | if .repo == \$b.repo and .suite == \$b.suite and .status == "active"
        then .status = "released" | .released_at = \$t | .main_sha_green = \$b.main_sha_green else . end]' "\$ST/sq.json" > "\$ST/s.tmp" \
        && mv "\$ST/s.tmp" "\$ST/sq.json"; echo '{"released":1}' ;;
    *) return 1 ;;
  esac
}
if [ "\${BASH_SOURCE[0]}" = "\$0" ]; then
  for f in "$DIR"/bin/jobs-client.d/*.sh; do . "\$f"; done
  v="jc_verb_\${1//-/_}"; shift
  command -v "\$v" >/dev/null 2>&1 || exit 2
  "\$v" "\$@"; exit \$?
fi
EOF
}
# sqrow <state> <suite> [repair_issue|null] [created_at] [main_sha_red] — one active row.
sqrow() {
  jq -c --arg s "$2" --argjson i "${3:-null}" --arg c "${4:-2026-11-10T00:00:00Z}" --arg r "${5:-$(printf 'a%.0s' {1..40})}" --arg repo "$SLUG" \
    '. + [{id: (length + 1), repo: $repo, suite: $s, reason: "fixture", main_sha_red: $r, repair_issue: $i, status: "active", created_at: $c}]' \
    "$1/sq.json" > "$1/s.tmp" && mv "$1/s.tmp" "$1/sq.json"
}
# puts <state> — the suite-quarantine-put calls (0 when the fake was never called).
puts() { [ -f "$1/calls" ] || { echo 0; return; }; grep -c '^JOBS POST /api/suite-quarantine {' "$1/calls"; }

# ── Q0: the REAL client loads the verbs (curl stub) ──────────────────────────
mkdir -p "$T/q0/bin" "$T/q0/h"
cat > "$T/q0/bin/curl" <<'SH'
#!/bin/bash
url=""; m=GET
while [ $# -gt 0 ]; do case "$1" in -X) m="$2"; shift ;; https://*) url="$1" ;; esac; shift; done
echo "$m $url" >> "$CURL_LOG"
printf '%s\n200' '{"rows":[{"suite":"tests/x.sh","repair_issue":null,"main_sha_red":"aaaa","created_at":"2026-11-10T00:00:00Z"},{"suite":"tests/y.sh","repair_issue":42,"main_sha_red":"bbbb","created_at":"2026-11-11T00:00:00Z"}]}'
SH
chmod +x "$T/q0/bin/curl"
Q0=$(env PATH="$T/q0/bin:$PATH" CURL_LOG="$T/q0/curl.log" HARNESS="$T/q0/h" JOBS_HARNESS="$T/q0/h" HARNESS_SECRET=fixture-secret \
  JOBS_URL=https://jobs.fixture.test bash "$DIR/bin/jobs-client.sh" suite-quarantine-list "$SLUG" 2>"$T/q0/err"); Q0RC=$?
[ "$Q0RC" = 0 ] && [ "$Q0" = "$(printf 'tests/x.sh\t-\taaaa\t2026-11-10T00:00:00Z\ntests/y.sh\t42\tbbbb\t2026-11-11T00:00:00Z')" ] && ok \
  || bad "Q0 the real client's suite-quarantine-list (rc $Q0RC): '$Q0' $(cat "$T/q0/err")"
grep -qF "GET https://jobs.fixture.test/api/suite-quarantine?repo=example-org%2Fcromford&status=active" "$T/q0/curl.log" && ok \
  || bad "Q0 the list URL: $(cat "$T/q0/curl.log" 2>/dev/null)"
# Q0b: a list the worker cut at suite_quarantine.list_max is unreadable (rc 1, nothing printed).
mkdir -p "$T/q0b/bin" "$T/q0b/h"
cat > "$T/q0b/bin/curl" <<'SH'
#!/bin/bash
printf '%s\n200' '{"rows":[{"suite":"tests/x.sh","repair_issue":null,"main_sha_red":"aaaa","created_at":"2026-11-10T00:00:00Z"}],"truncated":true}'
SH
chmod +x "$T/q0b/bin/curl"
Q0B=$(env PATH="$T/q0b/bin:$PATH" HARNESS="$T/q0b/h" JOBS_HARNESS="$T/q0b/h" HARNESS_SECRET=fixture-secret \
  JOBS_URL=https://jobs.fixture.test bash "$DIR/bin/jobs-client.sh" suite-quarantine-list "$SLUG" 2>/dev/null); Q0BRC=$?
[ "$Q0BRC" = 1 ] && [ -z "$Q0B" ] && ok || bad "Q0b a truncated list must be rc 1 with no output (rc $Q0BRC): '$Q0B'"
grep -q 'suite-quarantine-put' <<<"$(env HARNESS="$T/q0/h" JOBS_HARNESS="$T/q0/h" bash "$DIR/bin/jobs-client.sh" 2>&1)" && ok || bad "Q0 the usage line lacks suite-quarantine-put"

# ── the gate scaffold (as tests/selection-gate-baseline.bh-8901-test.sh) ─────
R="$T/repo"; mkdir -p "$R/tests" "$R/bin"
g() { git -C "$1" -c user.email=t@example.com -c user.name=t "${@:2}"; }
for s in x y z w; do echo 'exit 0' > "$R/tests/$s.sh"; done
g "$R" init -q -b main; g "$R" add -A; g "$R" commit -qm base
MB=$(g "$R" rev-parse HEAD)
g "$R" checkout -q -b ticket/bh-1; echo b > "$R/b.txt"; g "$R" add -A; g "$R" commit -qm change
HEAD1=$(g "$R" rev-parse HEAD)
R4="$T/repo4"; cp -a "$R" "$R4"; echo 'exit 1' > "$R4/$X"; g "$R4" add -A; g "$R4" commit -qm 'edit x'

cat > "$T/plan.sh" <<'SH'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
printf '%s\n' ${STUB_SUITES:-tests/x.sh} > "$out"; echo "mode=batch-selected" >> "$GITHUB_OUTPUT"; exit 0
SH
cat > "$T/runner.sh" <<'SH'
#!/bin/bash
tree="$1"; shift
k=base; [ "$(cd "$tree" && pwd -P)" = "$(cd "$STUB_HEAD_TREE" && pwd -P)" ] && k=head
echo "$k $(git -C "$tree" rev-parse HEAD 2>/dev/null) $*" >> "$STUB_DIR/calls"
[ -f "$STUB_DIR/$k.out" ] && cat "$STUB_DIR/$k.out"
exit "$(cat "$STUB_DIR/$k.rc" 2>/dev/null || echo 0)"
SH
chmod +x "$T/plan.sh" "$T/runner.sh"
stub() {
  local c="$1" k="$2" rc="$3"; shift 3
  mkdir -p "$T/$c/stub"; printf '%s\n' "$@" > "$T/$c/stub/$k.out"; echo "$rc" > "$T/$c/stub/$k.rc"
}
# run <case> <tree> [VAR=value …] — one gate run with the base run and the
# suite quarantine on, the case's own HARNESS (with the fake client) and TMPDIR.
run() {
  local c="$1" tr="$2"; shift 2
  mkdir -p "$T/$c/stub" "$T/$c/tmp" "$T/$c/h" "$T/$c/st"
  mkjc "$T/$c/h" "$T/$c/st"
  env -u CI_QUARANTINE -u SELECTION_GATE_SQ_LIST -u SELECTION_GATE_FRESH_MAIN -u SELECTION_GATE_QUARANTINE_MAX_NEW \
    HARNESS="$T/$c/h" TMPDIR="$T/$c/tmp" REPO_SLUG="$SLUG" STUB_DIR="$T/$c/stub" STUB_HEAD_TREE="$tr" \
    SELECTION_GATE_PLAN="$T/plan.sh" SELECTION_GATE_RUNNER="$T/runner.sh" CI_QUARANTINE=- \
    SELECTION_GATE_BASELINE_RUN=1 SELECTION_GATE_SUITE_QUARANTINE=1 \
    "$@" bash "$SG" --tree "$tr" --base main --out "$T/$c/out" > "$T/$c/stdout" 2>&1
  RC=$?
}
gv() { sed -n "s/^$2: //p" "$T/$1/out/gate.txt" 2>/dev/null; }
gate() { cat "$T/$1/out/gate.txt" 2>/dev/null; cat "$T/$1/stdout" 2>/dev/null; }
calls() { awk -v k="$2" '$1 == k { n++ } END { print n + 0 }' "$T/$1/stub/calls" 2>/dev/null; }
HFAIL="FAIL $X (rc 1)"

# ── Q1: red on head and on base, not in the diff ─────────────────────────────
stub q1 head 1 "$HFAIL"; stub q1 base 1 "$HFAIL"
run q1 "$R"
[ "$RC" = 0 ] && [ "$(gv q1 rc)" = 0 ] && [ "$(gv q1 red)" = - ] && [ "$(gv q1 baseline-red)" = - ] && [ "$(gv q1 quarantined)" = "$X" ] && ok \
  || bad "Q1 quarantined: $X, red -, baseline-red -, rc 0 (exit $RC; $(gate q1))"
[ "$(puts "$T/q1/st")" = 1 ] && [ "$(jq -r --arg s "$X" '[.[] | select(.suite == $s and .status == "active")] | length' "$T/q1/st/sq.json")" = 1 ] && ok \
  || bad "Q1 one put and one active row ($(cat "$T/q1/st/calls" 2>/dev/null))"
[ "$(jq -r '.[0].main_sha_red' "$T/q1/st/sq.json")" = "$MB" ] && [ "$(jq -r '.[0].repo' "$T/q1/st/sq.json")" = "$SLUG" ] && ok \
  || bad "Q1 the row's main_sha_red is the base $MB and the repo $SLUG ($(cat "$T/q1/st/sq.json"))"
grep -q "red on main ${MB:0:12} and on ${HEAD1:0:12}" "$T/q1/st/sq.json" && ok || bad "Q1 the row's reason names both shas ($(cat "$T/q1/st/sq.json"))"
# The rerun: the row is active now, so step 5 moves X and no base run happens.
stub q1r head 1 "$HFAIL"; mkdir -p "$T/q1r/st"; cp "$T/q1/st/sq.json" "$T/q1r/st/sq.json"
run q1r "$R"
[ "$RC" = 0 ] && [ "$(gv q1r quarantined)" = "$X" ] && [ "$(calls q1r base)" = 0 ] && [ "$(puts "$T/q1r/st")" = 0 ] && ok \
  || bad "Q1 rerun: the active row moves X at step 5, no base run, no put (exit $RC; $(gate q1r))"

# ── Q2: the env list (test seam) names X ─────────────────────────────────────
stub q2 head 1 "$HFAIL"
run q2 "$R" SELECTION_GATE_SQ_LIST="$X"
[ "$RC" = 0 ] && [ "$(gv q2 quarantined)" = "$X" ] && [ "$(gv q2 red)" = - ] && [ "$(gv q2 noted)" = - ] && [ "$(calls q2 base)" = 0 ] && ok \
  || bad "Q2 an active row: quarantined $X, no base run (exit $RC; $(gate q2))"

# ── Q3: red head, green base ─────────────────────────────────────────────────
stub q3 head 1 "$HFAIL"; stub q3 base 0 "PASS $X"
run q3 "$R"
[ "$RC" = 1 ] && [ "$(gv q3 red)" = "$X" ] && [ "$(gv q3 quarantined)" = - ] && [ "$(puts "$T/q3/st")" = 0 ] && ok \
  || bad "Q3 green on base: red $X, no put (exit $RC; $(gate q3))"

# ── Q4: the diff edits X ─────────────────────────────────────────────────────
stub q4 head 1 "$HFAIL"; stub q4 base 1 "$HFAIL"
run q4 "$R4"
[ "$RC" = 1 ] && [ "$(gv q4 red)" = "$X" ] && [ "$(gv q4 quarantined)" = - ] && [ "$(puts "$T/q4/st")" = 0 ] && ok \
  || bad "Q4 the diff edits $X: red $X, no put (exit $RC; $(gate q4))"

# ── Q5: near-miss base lines ─────────────────────────────────────────────────
stub q5 head 1 "$HFAIL"; stub q5 base 1 'FAIL: expected 3' "FAIL $X.bak (rc 1)"
run q5 "$R"
[ "$RC" = 1 ] && [ "$(gv q5 red)" = "$X" ] && [ "$(puts "$T/q5/st")" = 0 ] && ok \
  || bad "Q5 near-miss base lines: red $X, no put (exit $RC; $(gate q5))"

# ── Q6: an active row for X, and the diff edits X ────────────────────────────
stub q6 head 1 "$HFAIL"; stub q6 base 0 "PASS $X"
run q6 "$R4" SELECTION_GATE_SQ_LIST="$X"
[ "$RC" = 1 ] && [ "$(gv q6 red)" = "$X" ] && [ "$(gv q6 quarantined)" = - ] && ok \
  || bad "Q6 the diff edits a quarantined $X: red $X (exit $RC; $(gate q6))"

# ── Q7: the list read fails ──────────────────────────────────────────────────
stub q7 head 1 "$HFAIL"; stub q7 base 1 "$HFAIL"; mkdir -p "$T/q7/st"; touch "$T/q7/st/list.fail"
run q7 "$R"
[ "$RC" = 0 ] && [ "$(gv q7 baseline-red)" = "$X" ] && [ "$(gv q7 quarantined)" = "- unreadable" ] && [ "$(puts "$T/q7/st")" = 0 ] && ok \
  || bad "Q7 list unreadable: baseline-red $X, quarantined '- unreadable', no put (exit $RC; $(gate q7))"
# No REPO_SLUG is unreadable too.
stub q7b head 1 "$HFAIL"; stub q7b base 1 "$HFAIL"
run q7b "$R" REPO_SLUG=
[ "$(gv q7b baseline-red)" = "$X" ] && [ "$(gv q7b quarantined)" = "- unreadable" ] && [ "$(puts "$T/q7b/st")" = 0 ] && ok \
  || bad "Q7b no REPO_SLUG: baseline-red $X, no put ($(gate q7b))"

# ── Q8: the cap ──────────────────────────────────────────────────────────────
F4=(); for s in x y z w; do F4+=("FAIL tests/$s.sh (rc 1)"); done
stub q8 head 1 "${F4[@]}"; stub q8 base 1 "${F4[@]}"
run q8 "$R" STUB_SUITES="tests/x.sh tests/y.sh tests/z.sh tests/w.sh" SELECTION_GATE_QUARANTINE_MAX_NEW=3
[ "$RC" = 0 ] && [ "$(gv q8 quarantined)" = "- quarantine-cap: 4 > 3" ] && [ "$(gv q8 baseline-red)" = "tests/w.sh,tests/x.sh,tests/y.sh,tests/z.sh" ] \
  && [ "$(puts "$T/q8/st")" = 0 ] && ok || bad "Q8 4 > 3: none written, all four baseline-red (exit $RC; $(gate q8))"
# Three is within the cap: all three are written.
F3=("${F4[@]:0:3}")
stub q8a head 1 "${F3[@]}"; stub q8a base 1 "${F3[@]}"
run q8a "$R" STUB_SUITES="tests/x.sh tests/y.sh tests/z.sh" SELECTION_GATE_QUARANTINE_MAX_NEW=3
[ "$(gv q8a quarantined)" = "tests/x.sh,tests/y.sh,tests/z.sh" ] && [ "$(puts "$T/q8a/st")" = 3 ] && ok \
  || bad "Q8a 3 = cap: three written ($(gate q8a))"
stub q8b head 1 "$HFAIL"; stub q8b base 1 "$HFAIL"; mkdir -p "$T/q8b/st"; touch "$T/q8b/st/put.fail"
run q8b "$R"
[ "$RC" = 0 ] && [ "$(gv q8b baseline-red)" = "$X" ] && [ "$(gv q8b quarantined)" = "- write-failed $X" ] && ok \
  || bad "Q8b a failed put: baseline-red $X, write-failed (exit $RC; $(gate q8b))"
stub q8c head 1 "$HFAIL"; stub q8c base 1 "$HFAIL"
run q8c "$R" SELECTION_GATE_SUITE_QUARANTINE=
[ "$RC" = 0 ] && [ "$(gv q8c baseline-red)" = "$X" ] && ! grep -q '^quarantined:' "$T/q8c/out/gate.txt" && [ "$(wc -l < "$T/q8c/out/gate.txt")" = 12 ] \
  && [ "$(puts "$T/q8c/st")" = 0 ] && ok || bad "Q8c knob unset: the 12-line BH-8901 file, no put ($(gate q8c))"
stub q8d head 1 "$HFAIL"; stub q8d base 1 "$HFAIL"
run q8d "$R" SELECTION_GATE_SUITE_QUARANTINE=yes
! grep -q '^quarantined:' "$T/q8d/out/gate.txt" && [ "$(puts "$T/q8d/st")" = 0 ] && ok || bad "Q8d knob 'yes' is off ($(gate q8d))"

# ── Q9: the wrapper passes the four knobs ────────────────────────────────────
W="$T/q9"; mkdir -p "$W/co/bin" "$W/build"
cat > "$W/co/bin/selection-gate.sh" <<'SH'
#!/bin/bash
env | grep -E '^SELECTION_GATE_(FRESH_MAIN|FRESH_FETCH_S|SUITE_QUARANTINE|QUARANTINE_MAX_NEW)=' | sort > "$Q9_ENV"
exit 0
SH
chmod +x "$W/co/bin/selection-gate.sh"
( cd "$W/co" && env -u SELECTION_GATE_FRESH_MAIN -u SELECTION_GATE_FRESH_FETCH_S -u SELECTION_GATE_SUITE_QUARANTINE -u SELECTION_GATE_QUARANTINE_MAX_NEW \
    HARNESS= H= BUILD="$W/build" BASE=main Q9_ENV="$W/env" bash -c ". '$LIB'; _sg_run 60 2" ) >/dev/null 2>&1
[ "$(cat "$W/env" 2>/dev/null)" = "$(printf 'SELECTION_GATE_FRESH_FETCH_S=60\nSELECTION_GATE_FRESH_MAIN=1\nSELECTION_GATE_QUARANTINE_MAX_NEW=3\nSELECTION_GATE_SUITE_QUARANTINE=1')" ] && ok \
  || bad "Q9 _sg_run passes FRESH_MAIN=1 FRESH_FETCH_S=60 SUITE_QUARANTINE=1 QUARANTINE_MAX_NEW=3 (got: $(cat "$W/env" 2>/dev/null))"
for kv in SELECTION_GATE_FRESH_MAIN:1 SELECTION_GATE_FRESH_FETCH_S:60 SELECTION_GATE_SUITE_QUARANTINE:1 SELECTION_GATE_QUARANTINE_MAX_NEW:3; do
  f="$DIR/catalog/lanes.d/fly-pool.knobs.d/${kv%%:*}.json"
  [ "$(jq -r '.default' "$f" 2>/dev/null)" = "${kv##*:}" ] && [ "$(jq -r '.read_in' "$f" 2>/dev/null)" = bin/lib/selection-gate.sh ] && ok \
    || bad "Q9 $f: default ${kv##*:}, read_in bin/lib/selection-gate.sh"
done
for kv in SUITE_QUARANTINE_MAX_NEW:3 SUITE_QUARANTINE_ACT:1; do
  f="$DIR/catalog/lanes.d/flaky-tier.knobs.d/${kv%%:*}.json"
  [ "$(jq -r '.default' "$f" 2>/dev/null)" = "${kv##*:}" ] && ok || bad "Q9 $f: default ${kv##*:}"
done

# ── Q10: the gate.txt readers ignore the two new lines ───────────────────────
G0="$T/q10/a/gate.txt"; G1="$T/q10/b/gate.txt"; mkdir -p "${G0%/*}" "${G1%/*}"
printf 'head: %s\nbase: %s\nsuites: 2\nrc: 0\nred: -\nnoted: -\nmode: batch-selected\nwhy: -\nquarantine: env\nhost-noted: -\nbaseline-red: %s\nbaseline: ran 1 on %s (0 cached)\n' \
  "$HEAD1" "$MB" "$Y" "${MB:0:12}" > "$G0"
{ cat "$G0"; printf 'quarantined: %s\nfresh-main: on %s\n' "$X" "${MB:0:12}"; } > "$G1"
for f in red baseline-red rc head base suites; do
  [ "$( . "$LIB" && _sg_field "$G0" "$f")" = "$( . "$LIB" && _sg_field "$G1" "$f")" ] && ok || bad "Q10 _sg_field $f differs with the new lines"
done
PRIME_RE=$(grep -o "sed -nE 's/^(red|baseline-red): //p'" "$DIR/bin/selection-gate-prime.sh" | head -n 1)
[ -n "$PRIME_RE" ] && [ "$(sed -nE 's/^(red|baseline-red): //p' "$G0")" = "$(sed -nE 's/^(red|baseline-red): //p' "$G1")" ] && ok \
  || bad "Q10 the prime reader's red|baseline-red read differs (or its sed moved: '$PRIME_RE')"
[ "$(grep -c '^red:' "$G0")" = "$(grep -c '^red:' "$G1")" ] && ok || bad "Q10 the resolver's ^red: read differs"
# sg_block's log line: ` quarantined=1` only when the field names a suite.
sgb() {   # <case> <gate.txt> — sg_block over a stub gate that copies <gate.txt>
  local c="$T/q10/$1"; mkdir -p "$c/co/bin" "$c/build"
  printf '#!/bin/bash\nmkdir -p "$BUILD/selection-gate"; cp %q "$BUILD/selection-gate/gate.txt"; exit 0\n' "$2" > "$c/co/bin/selection-gate.sh"
  chmod +x "$c/co/bin/selection-gate.sh"
  ( cd "$c/co" && HARNESS= H= BUILD="$c/build" BASE=main PROJECT=p KEY=K-1 bash -c ". '$LIB'; STAMP() { echo S; }; RESULT() { :; }; sg_block" ) >/dev/null 2>&1
  grep 'SELECTION-GATE rc=' "$c/build/pipeline.log" 2>/dev/null
}
L0=$(sgb a "$G0"); L1=$(sgb b "$G1")
[ -n "$L0" ] && [ "$L1" = "$L0 quarantined=1" ] && ok || bad "Q10 sg_block log: '$L0' then '$L1'"

# ── the hub lane (bin/flaky-tier.sh) ─────────────────────────────────────────
FAKE_NOW=1794657600            # 2026-11-14 12:00:00Z
TOKEN=ghp_FIXTURE_ADMIN_TOKEN
# hub <case> — a scratch HARNESS for the lane: the libs it sources, the fake
# client, a gh stub, suites, a protected list and the admin token.
hub() {
  local c="$1" h="$T/$1/h" fx="$T/$1/st"
  mkdir -p "$h/bin/lib" "$h/env" "$h/tests" "$h/catalog" "$T/$c/stubbin" "$fx"
  for f in env-path.sh gh-rest.sh gh-rest-list.sh gh-rest-var.sh test-protected.sh gh-ci-read.sh flaky-tier-release.sh suite-quarantine-hub.sh; do
    ln -sf "$DIR/bin/lib/$f" "$h/bin/lib/$f"
  done
  for s in a b c d e switch-x; do printf '#!/bin/bash\n' > "$h/tests/$s-test.sh"; done
  printf 'tests/switch-x-test.sh   fixture protected suite\n' > "$h/catalog/test-quarantine-protected.txt"
  printf 'GH_ADMIN_TOKEN=%s\n' "$TOKEN" > "$h/env/github-admin.env"
  printf '#!/bin/bash\necho "ALERT $*" >> %q\n' "$fx/calls" > "$h/bin/lane-alert.sh"; chmod +x "$h/bin/lane-alert.sh"
  mkjc "$h" "$fx"
  cat > "$T/$c/stubbin/gh" <<EOF
#!/bin/bash
shift; M=GET; P=
while [ \$# -gt 0 ]; do case "\$1" in -i) shift ;; -X) M="\$2"; shift 2 ;; *) P="\$1"; shift; break ;; esac; done
echo "GH \$M \$P | \$*" >> "$fx/calls"
val=; body=; title=
for a in "\$@"; do case "\$a" in value=*) val="\${a#value=}" ;; body=@*) body="\${a#body=@}" ;; title=*) title="\${a#title=}" ;; esac; done
reply() { printf 'HTTP/2 %s X\r\n\r\n%s\n' "\$1" "\${2:-}"; }
case "\$M \$P" in
  "GET repos/$SLUG/issues") reply "\$(cat "$fx/issues.status" 2>/dev/null || echo 200)" "\$(cat "$fx/issues.json" 2>/dev/null || echo '[]')" ;;
  "POST repos/$SLUG/issues")
    [ -f "$fx/post.fail" ] && { reply 500 '{}'; exit 0; }
    n=\$(( \$(cat "$fx/next" 2>/dev/null || echo 40) + 1 )); echo "\$n" > "$fx/next"
    cp "\$body" "$fx/issue-body.\$n"; echo "\$title" > "$fx/issue-title.\$n"
    reply 201 "{\"number\":\$n,\"labels\":[{\"name\":\"ai-build\"}]}" ;;
  "GET repos/$SLUG/actions/variables/CI_QUARANTINE")
    if [ -f "$fx/var" ]; then reply 200 "{\"name\":\"CI_QUARANTINE\",\"value\":\"\$(cat "$fx/var")\"}"; else reply 404 '{"message":"Not Found"}'; fi ;;
  "POST repos/$SLUG/actions/variables") printf '%s' "\$val" > "$fx/var"; reply 201 '{}' ;;
  "PATCH repos/$SLUG/actions/variables/CI_QUARANTINE") printf '%s' "\$val" > "$fx/var"; reply 204 '' ;;
  *) reply 500 '{}' ;;
esac
EOF
  chmod +x "$T/$c/stubbin/gh"
}
# tick <case> [VAR=value …] [-- lane args] — one tick of the REAL lane.
tick() {
  local c="$1"; shift
  mkdir -p "$T/$c/tmp"
  local -a ev=(); while [ $# -gt 0 ] && [ "$1" != -- ]; do ev+=("$1"); shift; done; [ "${1:-}" = -- ] && shift
  env -u FLAKY_TIER_ACT -u SUITE_QUARANTINE_ACT -u SUITE_QUARANTINE_MAX_NEW HARNESS="$T/$c/h" PATH="$T/$c/stubbin:$PATH" \
    TMPDIR="$T/$c/tmp" FLAKY_TIER_NOW="$FAKE_NOW" ${ev[@]+"${ev[@]}"} bash "$LANE" "$SLUG" "$@" > "$T/$c/out" 2>&1
  TRC=$?
}
hc() { [ -f "$T/$1/st/calls" ] || { echo 0; return; }; grep -c -- "$2" "$T/$1/st/calls"; }
rowv() { jq -r --arg s "$2" --arg k "$3" '[.[] | select(.suite == $s)] | last | .[$k] // "null"' "$T/$1/st/sq.json"; }

# ── Q11: a NULL row gets one ticket with the marker, then the link ──────────
hub q11; sqrow "$T/q11/st" tests/a-test.sh
tick q11
[ "$TRC" = 0 ] && [ "$(hc q11 "^GH POST repos/$SLUG/issues |")" = 1 ] && ok || bad "Q11 one issue POST (rc $TRC): $(cat "$T/q11/st/calls")"
[ "$(cat "$T/q11/st/issue-title.41" 2>/dev/null)" = "[suite-quarantine] tests/a-test.sh" ] && ok || bad "Q11 the title: '$(cat "$T/q11/st/issue-title.41" 2>/dev/null)'"
grep -qxF '<!-- harness-suite-quarantine: tests/a-test.sh -->' "$T/q11/st/issue-body.41" 2>/dev/null && ok || bad "Q11 the body has no marker"
grep -q 'labels\[\]=ai-build' <<<"$(grep "^GH POST repos/$SLUG/issues |" "$T/q11/st/calls")" && ok || bad "Q11 no ai-build label on the create"
[ "$(rowv q11 tests/a-test.sh repair_issue)" = 41 ] && ok || bad "Q11 the row links #41 ($(cat "$T/q11/st/sq.json"))"
LP=$(grep -n "^GH POST repos/$SLUG/issues |" "$T/q11/st/calls" | cut -d: -f1); LL=$(grep -n '^JOBS POST /api/suite-quarantine/issue' "$T/q11/st/calls" | cut -d: -f1)
[ -n "$LP" ] && [ -n "$LL" ] && [ "$LP" -lt "$LL" ] && grep -q 'suite-quarantine: filed #41 for tests/a-test.sh' "$T/q11/out" && ok \
  || bad "Q11 the POST (line $LP) before the link (line $LL), then the filed line: $(cat "$T/q11/out")"
# A second tick: the row is linked, nothing is filed.
: > "$T/q11/st/calls"; tick q11
[ "$(hc q11 "^GH POST repos/$SLUG/issues |")" = 0 ] && [ "$(hc q11 '^JOBS POST /api/suite-quarantine/issue')" = 0 ] && ok || bad "Q11 tick 2 filed again"

# ── Q12: an open issue with the marker is reused ─────────────────────────────
hub q12; sqrow "$T/q12/st" tests/b-test.sh
printf '[{"number":77,"title":"x","body":"<!-- harness-suite-quarantine: tests/b-test.sh -->\\nold"},{"number":78,"body":"<!-- harness-suite-quarantine: tests/b-test.sh.bak -->"}]' > "$T/q12/st/issues.json"
tick q12
[ "$(hc q12 "^GH POST repos/$SLUG/issues |")" = 0 ] && [ "$(rowv q12 tests/b-test.sh repair_issue)" = 77 ] && ok \
  || bad "Q12 the marker issue #77 is linked, no POST ($(cat "$T/q12/st/sq.json"); $(cat "$T/q12/st/calls"))"
hub q12b; sqrow "$T/q12b/st" tests/b-test.sh 55
tick q12b
[ "$(hc q12b "^GH POST repos/$SLUG/issues |")" = 0 ] && [ "$(hc q12b '^JOBS POST /api/suite-quarantine/issue')" = 0 ] && [ "$(hc q12b "^GH GET repos/$SLUG/issues ")" = 0 ] && ok \
  || bad "Q12b a linked row: no issue read, POST or link ($(cat "$T/q12b/st/calls"))"

# ── Q13: the per-tick cap ────────────────────────────────────────────────────
hub q13; for s in a b c d; do sqrow "$T/q13/st" "tests/$s-test.sh"; done
tick q13
[ "$(hc q13 "^GH POST repos/$SLUG/issues |")" = 3 ] && [ "$(rowv q13 tests/d-test.sh repair_issue)" = null ] && grep -q 'over SUITE_QUARANTINE_MAX_NEW=3' "$T/q13/out" && ok \
  || bad "Q13 four NULL rows, cap 3: three POSTs, d stays NULL: $(cat "$T/q13/out")"

# ── Q14: the issue list fails, then recovers ─────────────────────────────────
hub q14; sqrow "$T/q14/st" tests/c-test.sh; echo 502 > "$T/q14/st/issues.status"
tick q14
[ "$(hc q14 "^GH POST repos/$SLUG/issues |")" = 0 ] && [ "$(rowv q14 tests/c-test.sh repair_issue)" = null ] && ok \
  || bad "Q14 HTTP 502: no POST, the row stays NULL ($(cat "$T/q14/out"))"
rm -f "$T/q14/st/issues.status"; tick q14
[ "$(hc q14 "^GH POST repos/$SLUG/issues |")" = 1 ] && [ "$(rowv q14 tests/c-test.sh repair_issue)" = 41 ] && ok \
  || bad "Q14 the next tick files and links it ($(cat "$T/q14/out"))"
# A failed link leaves the row NULL; the next tick finds the issue by its marker.
hub q14b; sqrow "$T/q14b/st" tests/c-test.sh; touch "$T/q14b/st/issue.fail"
tick q14b
[ "$(rowv q14b tests/c-test.sh repair_issue)" = null ] && ! grep -q 'filed #' "$T/q14b/out" && ok || bad "Q14b a failed link: row NULL, no filed line ($(cat "$T/q14b/out"))"

# ── Q15-Q17: release on a green nightly ──────────────────────────────────────
RED_SHA=$(printf 'a%.0s' {1..40}); NEW_SHA=$(printf 'b%.0s' {1..40}); NEW2=$(printf 'c%.0s' {1..40})
# night <case> <id> <created_at> <sha> [suite rc]… — one cached nightly run file.
night() {
  local d="$T/$1/h/state/flaky-tier/nightly"; mkdir -p "$d"
  { printf '# created_at=%s sha=%s\n' "$3" "$4"; shift 4; while [ $# -ge 2 ]; do printf '%s\t%s\n' "$1" "$2"; shift 2; done; } > "$d/$2.tsv"
}
rel() {   # <case> — one active linked row for tests/e-test.sh, created 2026-11-10
  hub "$1"; sqrow "$T/$1/st" tests/e-test.sh 60 2026-11-10T00:00:00Z "$RED_SHA"
}
rel q15; night q15 900 2026-11-12T03:00:00Z "$NEW_SHA" tests/e-test.sh 0
tick q15
[ "$(rowv q15 tests/e-test.sh status)" = released ] && [ "$(rowv q15 tests/e-test.sh main_sha_green)" = "$NEW_SHA" ] && grep -q 'suite-quarantine: released tests/e-test.sh' "$T/q15/out" && ok \
  || bad "Q15 a newer green nightly releases the row ($(cat "$T/q15/out"))"
# The newer red run has the LOWER id, so file-name order alone cannot pick it.
rel q16; night q16 901 2026-11-12T03:00:00Z "$NEW_SHA" tests/e-test.sh 0; night q16 900 2026-11-13T03:00:00Z "$NEW2" tests/e-test.sh 1
tick q16
[ "$(rowv q16 tests/e-test.sh status)" = active ] && [ "$(hc q16 '/api/suite-quarantine/release')" = 0 ] && ok || bad "Q16 the newest run is red: kept ($(cat "$T/q16/out"))"
rel q17a; night q17a 900 2026-11-12T03:00:00Z "$RED_SHA" tests/e-test.sh 0
rel q17b; night q17b 900 2026-11-09T03:00:00Z "$NEW_SHA" tests/e-test.sh 0
rel q17c; mkdir -p "$T/q17c/h/state/flaky-tier/nightly"; printf '# unreadable created_at=2026-11-12T03:00:00Z\n' > "$T/q17c/h/state/flaky-tier/nightly/900.tsv"
rel q17d; night q17d 900 2026-11-12T03:00:00Z "$NEW_SHA" tests/a-test.sh 0
for c in q17a q17b q17c q17d; do
  tick "$c"
  [ "$(rowv "$c" tests/e-test.sh status)" = active ] && [ "$(hc "$c" '/api/suite-quarantine/release')" = 0 ] && ok || bad "$c kept ($(cat "$T/$c/out"))"
done

# ── Q18-Q19: the projection is the union ─────────────────────────────────────
hub q18; sqrow "$T/q18/st" tests/b-test.sh 61; sqrow "$T/q18/st" tests/switch-x-test.sh 62; sqrow "$T/q18/st" tests/gone-test.sh 63
jq -c '.rows += [{test: "tests/a-test.sh", active: 1, actor: "flaky-tier", updated_at: "2026-11-01 00:00:00", reason: "fixture"},
                 {test: "tests/b-test.sh", active: 1, actor: "flaky-tier", updated_at: "2026-11-01 00:00:00", reason: "fixture"}]' \
  "$T/q18/st/rows.json" > "$T/q18/st/r" && mv "$T/q18/st/r" "$T/q18/st/rows.json"
tick q18
[ "$(cat "$T/q18/st/var" 2>/dev/null)" = "tests/a-test.sh tests/b-test.sh" ] && ok || bad "Q18 CI_QUARANTINE='$(cat "$T/q18/st/var" 2>/dev/null)': $(cat "$T/q18/out")"
grep -q 'suite-quarantine: protected tests/switch-x-test.sh' "$T/q18/out" && ok || bad "Q18 no say line for the protected suite row"
hub q18b; sqrow "$T/q18b/st" tests/c-test.sh 64
tick q18b
[ "$(cat "$T/q18b/st/var" 2>/dev/null)" = "tests/c-test.sh" ] && ok || bad "Q18b a suite row alone is projected: '$(cat "$T/q18b/st/var" 2>/dev/null)'"
hub q19; sqrow "$T/q19/st" tests/c-test.sh 64 2026-11-10T00:00:00Z "$RED_SHA"; printf '%s' tests/c-test.sh > "$T/q19/st/var"
night q19 900 2026-11-12T03:00:00Z "$NEW_SHA" tests/c-test.sh 0
tick q19
[ "$(rowv q19 tests/c-test.sh status)" = released ] && [ "$(cat "$T/q19/st/var" 2>/dev/null)" = - ] && ok \
  || bad "Q19 a released row leaves the projection: var='$(cat "$T/q19/st/var" 2>/dev/null)' ($(cat "$T/q19/out"))"
# The list unreadable: the projection is the flaky rows only, and it says so.
hub q19b; touch "$T/q19b/st/list.fail"
jq -c '.rows += [{test: "tests/a-test.sh", active: 1, actor: "flaky-tier", updated_at: "2026-11-01 00:00:00", reason: "fixture"}]' \
  "$T/q19b/st/rows.json" > "$T/q19b/st/r" && mv "$T/q19b/st/r" "$T/q19b/st/rows.json"
tick q19b
[ "$(cat "$T/q19b/st/var" 2>/dev/null)" = tests/a-test.sh ] && grep -q 'suite-quarantine: rows unreadable' "$T/q19b/out" && ok \
  || bad "Q19b list unreadable: flaky rows only, said ($(cat "$T/q19b/out"))"

# ── Q20: --dry-run writes nothing ────────────────────────────────────────────
hub q20; sqrow "$T/q20/st" tests/a-test.sh; sqrow "$T/q20/st" tests/e-test.sh 60 2026-11-10T00:00:00Z "$RED_SHA"
night q20 900 2026-11-12T03:00:00Z "$NEW_SHA" tests/e-test.sh 0
tick q20 -- --dry-run
[ "$(hc q20 "^GH POST repos/$SLUG/issues |")" = 0 ] && [ "$(hc q20 '^JOBS POST /api/suite-quarantine')" = 0 ] && [ "$(rowv q20 tests/e-test.sh status)" = active ] \
  && grep -q 'would: .*suite-quarantine' "$T/q20/out" && ok || bad "Q20 --dry-run wrote: $(cat "$T/q20/st/calls"); $(cat "$T/q20/out")"
hub q20b; sqrow "$T/q20b/st" tests/a-test.sh
tick q20b SUITE_QUARANTINE_ACT=0
[ "$(hc q20b "^GH POST repos/$SLUG/issues |")" = 0 ] && [ "$(hc q20b '^JOBS POST /api/suite-quarantine')" = 0 ] && ok || bad "Q20b SUITE_QUARANTINE_ACT=0 filed: $(cat "$T/q20b/st/calls")"

echo "suite-quarantine.bh-9697: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
