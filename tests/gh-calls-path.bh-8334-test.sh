#!/bin/bash
# tests/gh-calls-path.bh-8334-test.sh — BH-8334 (C0): the gh-calls ledger
# (logs/gh-calls/<hour>.log, bin/lib/gh-limit-logger.sh) records the templated
# endpoint of a gh_rest-shaped call as a 5th field, and gh_calls_top_endpoints
# (bin/lib/gh-quota.sh) names the busiest ones. Every call goes through the
# real gh() wrapper, from a real lane file, against a stub gh binary.
#
#   E1-E8   each gh_rest shape gets the expected <METHOD>:<template>
#   E9-E14  the near misses: no 5th field, or a segment kept as it is
#   E15     fields 1-4 are unchanged on a 5-field line
#   D3      an unwritable logs dir: stdout and rc identical, no stderr
#   R1      round trip: 4- and 5-field lines from two callers; gh_calls_top
#           counts all of them by caller, gh_calls_top_endpoints only the
#           5-field ones, by endpoint, for one caller
#   F1      the templater forks nothing: no $( or ` in _ghll_ep / _ghll_tpl
#   G1      gh_rest itself (bin/lib/gh-rest.sh) writes a 5-field line
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/gh-calls-path.bh-8334-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }

mkdir -p "$T/h/logs" "$T/bin/lib" "$T/fakebin"
for L in bin/lib/gh-limit-logger.sh bin/lib/gh-quota.sh bin/lib/gh-rest.sh; do
  scratch_install_closure "$L" "$T" >/dev/null || { echo "FAIL: closure install of $L"; exit 1; }
done
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf 'HTTP/1.1 200 OK\r\n\r\n{"ok":true}\n'
exit 0
SH
chmod +x "$T/fakebin/gh"
# A real lane file: the caller name is $0's basename. Each argument line of
# $T/argv is one call, split on tabs.
cat > "$T/demo-lane.sh" <<'SH'
#!/bin/bash
set -uo pipefail
. "$GHLL_LIB" || exit 9
while IFS= read -r L; do
  IFS=$'\t' read -r -a A <<<"$L"
  gh "${A[@]}" >/dev/null 2>&1 || true
done < "$ARGV"
SH
chmod +x "$T/demo-lane.sh"
lines() { cat "$T/h/logs/gh-calls/"*.log 2>/dev/null; }
run() { # run <caller> <argv line>... — one lane run, a clean ledger first unless KEEP=1
  local who="$1"; shift
  [ "${KEEP:-0}" = 1 ] || scratch_rm "$T/h/logs/gh-calls"
  printf '%s\n' "$@" > "$T/argv"
  env PATH="$T/fakebin:$PATH" HARNESS="$T/h" GHLL_LIB="$T/bin/lib/gh-limit-logger.sh" ARGV="$T/argv" \
    GH_CALL_CALLER="$who" bash "$T/demo-lane.sh"
}
f5() { lines | awk '{print (NF >= 5 ? $5 : "-")}' | tail -1; }
tab() { local IFS=$'\t'; printf '%s' "$*"; }
S40=0123456789abcdef0123456789abcdef01234567

# ---- E: the decision table ---------------------------------------------------
case_ep() { # case_ep <label> <expected 5th field or -> <argv...>
  local lbl="$1" want="$2"; shift 2
  run demo "$(tab "$@")"
  eq "$lbl" "$(f5)" "$want"
}
case_ep "E1 GET pulls/<n>"                  'GET:repos/{o}/{r}/pulls/{n}'            api -i -X GET repos/example-org/cromford/pulls/8334
case_ep "E2 commits/<40hex>/status"         'GET:repos/{o}/{r}/commits/{sha}/status' api -i -X GET "repos/o/r/commits/$S40/status"
case_ep "E3 the query string is dropped"    'GET:repos/{o}/{r}/issues/{n}/comments'  api -i -X GET 'repos/o/r/issues/12/comments?per_page=100&page=2'
case_ep "E4 POST with -f"                   'POST:repos/{o}/{r}/issues/{n}/comments' api -i -X POST repos/o/r/issues/5/comments -f body=x
case_ep "E5 --method and a leading slash"   'PATCH:repos/{o}/{r}/pulls/{n}'          api -i --method PATCH /repos/o/r/pulls/3
case_ep "E6 -H value skipped, heads/<ref>"  'GET:repos/{o}/{r}/git/refs/heads/{ref}' api -i -H 'Accept: x' -X GET repos/o/r/git/refs/heads/ticket/bh-8334
case_ep "E7 a short sha with a digit"       'GET:repos/{o}/{r}/commits/{sha}/check-runs' api -i -X GET repos/o/r/commits/abc1234/check-runs
case_ep "E8 no -X, has -f: POST"            'POST:graphql'                           api -i -f query=x graphql
case_ep "E9 argv2 is not a flag: 4 fields"  -                                        api repos/o/r/pulls/1
case_ep "E10 api rate_limit: 4 fields"      -                                        api rate_limit
case_ep "E11 pr list: 4 fields"             -                                        pr list -R o/r
case_ep "E12 api -i, no path: 4 fields"     -                                        api -i
case_ep "E13 a 7-char all-hex word with no digit is kept" 'GET:repos/{o}/{r}/labels/defaced' api -i -X GET repos/o/r/labels/defaced
case_ep "E14 a non-id word is kept"         'GET:repos/{o}/{r}/actions/runs/v2'      api -i -X GET repos/o/r/actions/runs/v2
run merge-conductor.sh "$(tab api -i -X GET repos/o/r/pulls/7)"
eq "E15 fields 1-4 unchanged" "$(lines | awk '{print ($1 ~ /^[0-9]{10}$/), $2, $3, $4, NF}')" "1 merge-conductor.sh api -i 5"
run demo "$(tab api repos/o/r/pulls/1)"
eq "E15 a plain api line is exactly 4 fields" "$(lines | awk '{print NF}')" 4

# ---- D3: an unwritable logs dir ---------------------------------------------
: > "$T/notafile"
OUT=$( ( export PATH="$T/fakebin:$PATH" HARNESS="$T/notafile/nope"
         . "$T/bin/lib/gh-limit-logger.sh"; gh api -i -X GET repos/o/r/pulls/1; echo "rc=$?" ) 2>"$T/d3err" )
eq "D3 stdout and rc are the binary's" "$OUT" "$(printf 'HTTP/1.1 200 OK\r\n\r\n{"ok":true}\nrc=0')"
[ ! -s "$T/d3err" ] && ok "D3 no stderr" || bad "D3 stderr: $(cat "$T/d3err")"

# ---- R1: the round trip ---------------------------------------------------------
scratch_rm "$T/h/logs/gh-calls"
KEEP=1 run merge-conductor.sh \
  "$(tab api -i -X GET repos/o/r/pulls/1)" "$(tab api -i -X GET repos/o/r2/pulls/2)" "$(tab api -i -X GET repos/x/y/pulls/3)" \
  "$(tab api -i -X GET "repos/o/r/commits/$S40/status")" "$(tab api repos/o/r/pulls/9)"
KEEP=1 run other-lane.sh "$(tab api -i -X GET repos/o/r/issues/4)"
TOP=$(env HARNESS="$T/h" bash -c '. "$1"; gh_calls_top 5 3600' _ "$T/bin/lib/gh-quota.sh")
eq "R1 gh_calls_top counts 4- and 5-field lines by caller" "$TOP" "$(printf 'merge-conductor.sh 5\nother-lane.sh 1')"
EPS=$(env HARNESS="$T/h" bash -c '. "$1"; gh_calls_top_endpoints merge-conductor.sh 10 3600' _ "$T/bin/lib/gh-quota.sh")
eq "R1 gh_calls_top_endpoints merge-conductor.sh 10: busiest first, 4-field lines not counted" "$EPS" \
  "$(printf '3 GET:repos/{o}/{r}/pulls/{n}\n1 GET:repos/{o}/{r}/commits/{sha}/status')"
EPS=$(env HARNESS="$T/h" bash -c '. "$1"; gh_calls_top_endpoints "" 1 3600' _ "$T/bin/lib/gh-quota.sh")
eq "R1 no caller: every caller, top 1" "$EPS" '3 GET:repos/{o}/{r}/pulls/{n}'
EPS=$(env HARNESS="$T/h" bash -c '. "$1"; gh_calls_top_endpoints nobody.sh' _ "$T/bin/lib/gh-quota.sh")
eq "R1 a caller with no lines: nothing" "$EPS" ""

# ---- F1: no fork in the templater -------------------------------------------
BODY=$(awk '/^_ghll_(tpl|ep)\(\)/{f=1} f{print} f && /^}/{f=0}' "$DIR/bin/lib/gh-limit-logger.sh")
[ -n "$BODY" ] && ok "F1 _ghll_tpl and _ghll_ep exist" || bad "F1 _ghll_tpl / _ghll_ep not found"
grep -nE '\$\(|`' <<<"$BODY" >/dev/null && bad "F1 the templater forks: $(grep -nE '\$\(|`' <<<"$BODY")" \
  || ok "F1 no \$( or backtick in the templater"

# ---- G1: gh_rest writes the 5th field ----------------------------------------
scratch_rm "$T/h/logs/gh-calls"
( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" GH_CALL_CALLER=g1-lane
  . "$T/bin/lib/gh-limit-logger.sh"; . "$T/bin/lib/gh-rest.sh"; gh_rest GET repos/o/r/pulls/41 >/dev/null )
eq "G1 gh_rest GET repos/o/r/pulls/41 -> GET:repos/{o}/{r}/pulls/{n}" "$(lines | awk '$2 == "g1-lane" {print $5}')" 'GET:repos/{o}/{r}/pulls/{n}'

echo "gh-calls-path.bh-8334: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
