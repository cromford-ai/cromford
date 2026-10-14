#!/bin/bash
# tests/mc-unverifiable-alert.bh-1634-test.sh — a PR whose merge state stays
# UNVERIFIABLE for MC_UNVERIFIABLE_ALERT_TICKS consecutive conductor ticks raises
# ONE alert per streak (BH-1634).
#
# THE DEFECT THIS PINS. Since BH-1585 a failed per-PR merge-state read in the
# open list marks only that row UNVERIFIABLE, and the conductor skips the row
# with one log line. A PR whose read kept failing was skipped every tick for
# ever and nothing paged.
#
# WHAT IS DRIVEN. The real bin/merge-conductor.sh, observe-only, over the real
# bin/lib/gh-pr-list.sh through tests/lib/gh-list-bridge.sh. GH_LIST_BRIDGE_FAIL_LAZY
# makes the list's own read of #11 answer 502 (one PR's fault, not a rate limit,
# so the rest of the list stands). #12 and #13 read fine; #16 is a DRAFT (never
# lazily read). lane-alert.sh is a stub that records its argv. The knob is set
# to 3 through the env fallback (the scratch tree carries no lane-gate.sh).
#   U1  one failing tick: no alert, one log line "unverifiable 1/3", count 1
#   U2  ticks 2-3: count 3, exactly one alert naming demo-os#11 UNVERIFIABLE
#   U3  ticks 4-6 (2N): still exactly one alert
#   U4  a readable tick clears the streak; 2 failing ticks do not alert; a fresh
#       streak of 3 raises the second alert
#   U5  #12, #13 and the draft #16 never get a state file or an alert
#   U6  knob 0: five failing ticks, no alert, the counter still advances
#   U7  no GitHub write verb on any tick
#
# Run from anywhere: tests/mc-unverifiable-alert.bh-1634-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" || exit 1
fx_conductor_tick "$DIR" "$T" || exit 1
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
H1=aaaaaaaa1111; H2=bbbbbbbb2222
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/lane-alert.sh"
mkdir -p "$T/h/builds/demo-os-TK-11-202609120001"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/11" > "$T/h/builds/demo-os-TK-11-202609120001/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/h/builds/demo-os-TK-11-202609120001/review.md"
echo "$H1" > "$T/h/builds/demo-os-TK-11-202609120001/reviewed-sha"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*|*"-X PATCH"*|*"-X POST"*|*"-X PUT"*|*"-X DELETE"*)
    echo "WRITE VERB IN OBSERVE MODE: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R example-org/demo-os --state open"*)
    cat <<'J'
[{"number":11,"url":"https://github.com/example-org/demo-os/pull/11","headRefOid":"$H1","headRefName":"ticket/TK-11","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"},
 {"number":12,"url":"https://github.com/example-org/demo-os/pull/12","headRefOid":"$H2","headRefName":"ticket/TK-12","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"},
 {"number":13,"url":"https://github.com/example-org/demo-os/pull/13","headRefOid":"$H1","headRefName":"ticket/TK-13","isDraft":false,"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","state":"OPEN"},
 {"number":16,"url":"https://github.com/example-org/demo-os/pull/16","headRefOid":"$H1","headRefName":"ticket/TK-16","isDraft":true,"mergeStateStatus":"DRAFT","mergeable":"UNKNOWN","state":"OPEN"}]
J
    ;;
  *"repos/example-org/demo-os/pulls?state=closed"*) printf 'HTTP/2.0 200\r\n\r\n[]\n' ;;
  *"actions/runs?head_sha=$H1"*) printf 'completed|success\ncompleted|success\n' ;;
  *"actions/runs?head_sha=$H2"*) printf 'in_progress|\n' ;;
  *"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/11") restpr OPEN "$H1" ticket/TK-11 main "" ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/12") restpr OPEN "$H2" ticket/TK-12 main "" ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/13") restpr OPEN "$H1" ticket/TK-13 main "" CONFLICTING DIRTY ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

: > "$T/gh-calls.txt"; : > "$T/gh-writes.txt"; : > "$T/alerts.txt"
printf '11\n16\n' > "$T/lazy-fail"
LOG="$T/h/logs/merge-conductor.log"
UDIR="$T/h/state/merge-conductor/unverifiable"
# tick [fail] — one real tick; "fail" makes the list's read of #11 answer 502.
# The knob rides the env (MC_UNVERIFIABLE_ALERT_TICKS, default 3 here).
tick() {
  local extra=()
  [ "${1:-}" = fail ] && extra=(GH_LIST_BRIDGE_FAIL_LAZY="$T/lazy-fail")
  ( cd "$T" && env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
      MC_UNVERIFIABLE_ALERT_TICKS="${KNOB:-3}" "${extra[@]}" \
      bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
    || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }
}
count11() { local f; f=$(ls "$UDIR"/*11 2>/dev/null | grep -v '\.lock$' | head -1)
  [ -n "$f" ] && cut -f1 "$f" || echo none; }
nalerts() { grep -c 'demo-os#11 UNVERIFIABLE' "$T/alerts.txt"; }
# Every alert line EXCEPT BH-1201's PAUSED reminder, which an observe-mode tick
# sends on its own MC_HOLD_REMINDER_S cadence whatever the PRs are doing. Any
# other stray alert still counts, so "exactly one" keeps meaning exactly one.
nall() { grep -v 'conductor PAUSED' "$T/alerts.txt" | grep -c .; }

# A clean first tick, so #11 has an ordinary row before the reads start failing.
tick
grep -q 'pulls?state=open' "$T/gh-calls.txt" && ok || bad "setup: the tick must have read the open list"

# U1
M=$(wc -l < "$LOG"); tick fail
NEW11=$(tail -n +"$((M+1))" "$LOG" | grep -F 'demo-os#11 ')
[ "$(grep -c . <<<"$NEW11")" = 1 ] && grep -q 'merge state UNVERIFIABLE this tick' <<<"$NEW11" \
  && grep -q 'unverifiable 1/3' <<<"$NEW11" \
  && ok || bad "U1: one failing tick must log exactly ONE line for #11 carrying 'unverifiable 1/3' (got: $NEW11)"
[ "$(count11)" = 1 ] && ok || bad "U1: the state file count must be 1 after one failing tick (got $(count11))"
[ "$(nalerts)" = 0 ] && ok || bad "U1: one failing tick must not alert: $(cat "$T/alerts.txt")"

# U2
tick fail; tick fail
[ "$(count11)" = 3 ] && ok || bad "U2: three failing ticks must count 3 (got $(count11))"
[ "$(nall)" = 1 ] && [ "$(nalerts)" = 1 ] \
  && ok || bad "U2: the third failing tick must raise exactly ONE alert naming demo-os#11 UNVERIFIABLE (got: $(cat "$T/alerts.txt"))"
grep -q 'pull/11' "$T/alerts.txt" && ok || bad "U2: the alert must carry the PR's url: $(cat "$T/alerts.txt")"

# U3
tick fail; tick fail; tick fail
[ "$(count11)" = 6 ] && ok || bad "U3: six failing ticks must count 6 (got $(count11))"
[ "$(nall)" = 1 ] && ok \
  || bad "U3: a streak of 2N must still have raised exactly ONE alert (got: $(cat "$T/alerts.txt"))"

# U4
tick
[ "$(count11)" = none ] && ok || bad "U4: a readable tick must clear #11's streak (count $(count11))"
tick fail; tick fail
[ "$(count11)" = 2 ] && [ "$(nalerts)" = 1 ] && ok \
  || bad "U4: two failing ticks after a recovery must count 2 and not alert (count $(count11), alerts $(nalerts))"
tick fail
[ "$(nalerts)" = 2 ] && ok || bad "U4: a fresh streak of 3 must raise a second alert (got $(nalerts): $(cat "$T/alerts.txt"))"

# U5
grep -Eq '(12|13|16)(\.lock)?$' <<<"$(ls "$UDIR" 2>/dev/null)" \
  && bad "U5: only #11 may have streak state: $(ls "$UDIR")" || ok
grep -Eq 'demo-os#(12|13|16) ' "$T/alerts.txt" && bad "U5: another PR alerted: $(cat "$T/alerts.txt")" || ok

# U6
tick; : > "$T/alerts.txt"
KNOB=0; for _ in 1 2 3 4 5; do tick fail; done; KNOB=3
[ ! -s "$T/alerts.txt" ] && ok || bad "U6: knob 0 must never alert: $(cat "$T/alerts.txt")"
[ "$(count11)" = 5 ] && ok || bad "U6: knob 0 still counts (got $(count11))"

# U7
[ ! -s "$T/gh-writes.txt" ] && ok || bad "U7: an observe tick used a write verb: $(cat "$T/gh-writes.txt")"

echo "mc-unverifiable-alert.bh-1634-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
