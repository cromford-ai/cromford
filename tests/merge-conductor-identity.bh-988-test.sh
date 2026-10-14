#!/bin/bash
# tests/merge-conductor-identity.bh-988-test.sh — an identity-blocked row buys
# ONE page, and never calls itself "waiting on a required check" (BH-988).
#
# THE INCIDENT. A PR whose push identity is not on the base branch's push
# allow-list sits in WAIT_CI for ever: GitHub answers mergeState BLOCKED with no
# required check to report and no review to buy. The row is real, the wait is
# real, and nothing this lane does moves it — only a repo admin does. Today it
# pages three times: mc_budget_check at 30m, mc_stuck_check at 90m, and that
# second alert renders `waiting on a required check to report on this head
# (IDENTITY_NOT_PERMITTED …: … no required checks …)` — a sentence that
# contradicts its own parenthesis. The one alert that means something is the
# identity page itself (PR #908, review of BH-800, which is what raised this).
#
# WHY DRIVEN AND NOT GREPPED. Every claim here is about control flow: which
# branch of mc_budget_check a reason lands in, whether mc_stuck_check returns
# before it writes its marker, which arm of the mc_stuck_waiting_on case prints.
# `grep -q mc_identity_blocked bin/lib/merge-conductor-lib.sh` passes just as
# happily on a predicate no caller consults.
#
# WHAT §6 CAN AND CANNOT DRIVE. The suppression is keyed on the ROW REASON, and
# on this base `mc_classify` cannot emit an IDENTITY_NOT_PERMITTED reason at all
# — that classifier branch is PR #908's and is not merged. So no tick of
# bin/merge-conductor.sh can produce an identity-blocked row here, and §6 drives
# the real script on the reason that shape of PR classifies as TODAY
# (`mergeState BLOCKED (required context not green)`): it proves both guarded
# functions are on the live tick's path with the row reason as their argument,
# and that the fail-open direction still pages end to end. Delete either call
# site in bin/merge-conductor.sh and §6 goes red.
#
# MUTATION NOTES (D1 — each applied once during the build, the red observed, the
# product line restored):
#   - drop `mc_identity_blocked "$why" && return 1` from mc_stuck_check
#                                          -> §3 red (rc 0, ALERTS line, marker)
#   - drop the identity arm of mc_budget_check's chain
#                                          -> §2 red (1 ALERTS line, no log line)
#   - drop the identity sub-case of mc_stuck_waiting_on's WAIT_CI arm
#                                          -> §4 red ("a required check" printed)
#   - loosen mc_identity_blocked's anchor to a bare substring match
#                                          -> §1 red (conflict-unresolvable case)
#
# Run from anywhere: bash tests/merge-conductor-identity.bh-988-test.sh
# (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# BH-3223: scratch.sh blanks JOBS_URL; this suite's fake curl answers a worker URL.
export JOBS_URL=https://jobs.invalid
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read: every fixture age is derived from it.
NOW=$(date -u +%s)
OLD=$(( NOW - 7200 ))            # 120m: past WAIT_CI's 30m budget AND its 90m TTL

export HARNESS="$T/h"
export MC_REHYDRATE=0            # no worker in this tree; an empty row file is the fixture
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/env" \
         "$T/h/builds" "$T/fakebin"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" "$T/h/bin/lib/"
# TEST-CHANGE (BH-1585): the open list is REST now; the contract lib rides beside gh-pr-list.sh.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
# Since BH-680 the lib is a shim: it sources bin/lib/mc/*.sh and EXITS when one
# is missing, so a fixture that copies only the shim aborts at source time with
# zero assertions run. Copy the modules with it (same shape as the BH-800 one).
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init

H1=aaaaaaaa1111
ALOG="$T/h/logs/ALERTS.log"
: > "$ALOG"
# The reason bin/merge-conductor.sh writes into the row for this shape of PR
# once PR #908 lands. The suppression keys on this string, not on a variable.
IDW='IDENTITY_NOT_PERMITTED github-actions[bot]: mergeState BLOCKED with no required checks and no required reviews'
# grep -c PRINTS 0 and exits 1 on no match, so the rc is swallowed and never
# turned into a second line of output — `|| echo 0` here would answer "0\n0".
alerts_for() { grep -cF "$1" "$ALOG" 2>/dev/null || true; }

# ============================================================================
# 1. The matcher. It SUPPRESSES alerts, so the negatives are the load-bearing
#    half: anything it matches by accident is a PR that stops paging and nobody
#    finds out. The anchor is a space-terminated prefix for exactly that reason.
# ============================================================================
mc_identity_blocked "IDENTITY_NOT_PERMITTED" \
  && ok || bad "the bare token must match — mc_classify may emit the reason with no detail"
mc_identity_blocked "$IDW" \
  && ok || bad "the full reason mc_classify emits must match"
while IFS= read -r NEG; do
  mc_identity_blocked "$NEG" \
    && bad "a non-identity reason must NEVER be silenced: '$NEG'" || ok
done <<NEGATIVES
mergeState BLOCKED (required context not green)
checks pending
checks none
checks flake — a required context was cancelled/timed_out; re-run once
conflict-unresolvable: bin/lib/IDENTITY_NOT_PERMITTED-notes.sh
IDENTITY_NOT_PERMITTEDX foo
identity_not_permitted github-actions[bot]: mergeState BLOCKED
-
NEGATIVES
mc_identity_blocked "" && bad "an empty reason must never be silenced" || ok
mc_identity_blocked   && bad "a missing reason must never be silenced" || ok

# ============================================================================
# 2. The budget arm: no page at 120m, a line in the conductor log saying which
#    alert IS the page, and a row that still ages and still records its mark.
# ============================================================================
K2='example-org/x#41'; U2=https://github.com/example-org/x/pull/41
mc_row_put "$K2" WAIT_CI "$OLD" "$H1" "$H1" - "$IDW" "$U2"
mc_budget_check "$K2" WAIT_CI "$OLD" "$U2" "$IDW (verdict=APPROVE ci=green mergeState=BLOCKED mode=observe)"
[ "$(alerts_for "$K2")" = 0 ] \
  && ok || bad "an identity-blocked row must not page at the WAIT_CI budget (got $(alerts_for "$K2"): $(grep -F "$K2" "$ALOG"))"
grep -qF 'the IDENTITY_NOT_PERMITTED alert is the page' "$MC_LOG" \
  && ok || bad "the suppressed budget must say so in the conductor log — a silence with no record is indistinguishable from a bug"
grep -qF "$U2" <(grep -F "$K2" "$MC_LOG") \
  && ok || bad "the conductor line must name the PR URL"
[ "$(mc_row_field "$K2" 6)" = "WAIT_CI@$OLD" ] \
  && ok || bad "suppressing the page must not stop the row recording its alerted mark (got '$(mc_row_field "$K2" 6)')"
[ "$(mc_row_field "$K2" 3)" = "$OLD" ] \
  && ok || bad "the row must keep ageing (since must not be reset)"

# 2b. FAIL OPEN. The same row, same age, with the reason main writes today for a
#     genuinely blocked PR: it must page exactly as it always has.
K2B='example-org/x#42'; U2B=https://github.com/example-org/x/pull/42
WHY2B='mergeState BLOCKED (required context not green)'
mc_row_put "$K2B" WAIT_CI "$OLD" "$H1" "$H1" - "$WHY2B" "$U2B"
mc_budget_check "$K2B" WAIT_CI "$OLD" "$U2B" "$WHY2B (verdict=APPROVE ci=green mergeState=BLOCKED mode=observe)"
[ "$(alerts_for "$K2B")" = 1 ] \
  && ok || bad "a genuinely blocked row must still page once at the budget (got $(alerts_for "$K2B"))"

# ============================================================================
# 3. The TTL arm: rc 1 BEFORE the marker is written, so nothing pages, nothing
#    re-kicks, and the row keeps its one stuck alert for the day the identity is
#    permitted and it then genuinely stalls on a check.
# ============================================================================
mc_stuck_check "$K2" WAIT_CI "$OLD" "$H1" "$U2" "$IDW" "verdict=APPROVE ci=green mode=observe" \
  && bad "mc_stuck_check must return 1 on an identity-blocked row — rc 0 is what calls stuck_rekick" || ok
[ "$(alerts_for "$K2")" = 0 ] \
  && ok || bad "an identity-blocked row must not page at the TTL either (got $(grep -F "$K2" "$ALOG"))"
grep -q 'STUCK' <(grep -F "$K2" "$MC_LOG") \
  && bad "no STUCK line belongs in the conductor log for a suppressed row" || ok
[ -z "$(ls -A "$MC_STUCK_DIR" 2>/dev/null)" ] \
  && ok || bad "no stuck marker may be burned: the row must be able to page if it later stalls for real ($(ls -A "$MC_STUCK_DIR"))"

# 3b. FAIL OPEN. A plain `checks pending` row at the same age still trips the
#     TTL, pages once, and writes its marker.
K3B='example-org/x#43'; U3B=https://github.com/example-org/x/pull/43
mc_row_put "$K3B" WAIT_CI "$OLD" "$H1" "$H1" - "checks pending" "$U3B"
mc_stuck_check "$K3B" WAIT_CI "$OLD" "$H1" "$U3B" "checks pending" "verdict=APPROVE" \
  && ok || bad "a non-identity WAIT_CI row past its TTL must still be called stuck"
[ "$(alerts_for "$K3B")" = 1 ] \
  && ok || bad "the ordinary stuck alert must still fire exactly once (got $(alerts_for "$K3B"))"
[ -n "$(ls -A "$MC_STUCK_DIR" 2>/dev/null)" ] \
  && ok || bad "the ordinary stuck path must still write its dedupe marker"

# ============================================================================
# 4. The waiting-on text. If the TTL guard is ever relaxed, or a second caller
#    appears, the sentence must still be true.
# ============================================================================
W4=$(mc_stuck_waiting_on WAIT_CI "$IDW")
grep -qF 'permit this identity to push' <<<"$W4" \
  && ok || bad "an identity-blocked WAIT_CI row must name the move a repo admin makes (got '$W4')"
grep -qF 'a required check' <<<"$W4" \
  && bad "the identity text must never say it is waiting on a required check — the reason says there are none (got '$W4')" || ok
grep -qF 'github-actions[bot]' <<<"$W4" \
  && ok || bad "the text must carry the reason verbatim, identity included (got '$W4')"
[ "$(mc_stuck_waiting_on WAIT_CI checks)" = 'a required check to report on this head (checks)' ] \
  && ok || bad "every other WAIT_CI reason must print today's string byte for byte (got '$(mc_stuck_waiting_on WAIT_CI checks)')"
[ "$(mc_stuck_waiting_on WAIT_CI)" = 'a required check to report on this head (checks)' ] \
  && ok || bad "the no-reason default must be unchanged (got '$(mc_stuck_waiting_on WAIT_CI)')"
grep -qF 'blocked-resolver.sh to drain the park' <<<"$(mc_stuck_waiting_on BLOCKED_HUMAN 'conflict-unresolvable: x')" \
  && ok || bad "restructuring the case must not cost the park its own sentence"

# ============================================================================
# 5. One page, both orders. The two suppressions must not depend on which of the
#    two checks a tick reaches first.
# ============================================================================
K5='example-org/x#51'; U5=https://github.com/example-org/x/pull/51
mc_row_put "$K5" WAIT_CI "$OLD" "$H1" "$H1" - "$IDW" "$U5"
mc_budget_check "$K5" WAIT_CI "$OLD" "$U5" "$IDW"
mc_stuck_check  "$K5" WAIT_CI "$OLD" "$H1" "$U5" "$IDW" detail >/dev/null
[ "$(alerts_for "$K5")" = 0 ] \
  && ok || bad "budget-then-TTL must leave ALERTS.log untouched (got $(grep -F "$K5" "$ALOG"))"
K6='example-org/x#52'; U6=https://github.com/example-org/x/pull/52
mc_row_put "$K6" WAIT_CI "$OLD" "$H1" "$H1" - "$IDW" "$U6"
mc_stuck_check  "$K6" WAIT_CI "$OLD" "$H1" "$U6" "$IDW" detail >/dev/null
mc_budget_check "$K6" WAIT_CI "$OLD" "$U6" "$IDW"
[ "$(alerts_for "$K6")" = 0 ] \
  && ok || bad "TTL-then-budget must leave ALERTS.log untouched (got $(grep -F "$K6" "$ALOG"))"
[ "$(grep -cF 'IDENTITY_NOT_PERMITTED' "$ALOG")" = 0 ] \
  && ok || bad "this lib must emit no identity alert of its own — the one page is bin/merge-conductor.sh's"

# ============================================================================
# 6. THE PRODUCTION ENTRY POINT. One real tick of bin/merge-conductor.sh, gh and
#    curl stubbed, observe-only. See the header: the identity reason cannot be
#    classified on this base, so what this pins is that mc_budget_check and
#    mc_stuck_check are the tick's own calls, fed the row's reason — and that
#    the fail-open direction pages end to end.
# ============================================================================
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
B6="$T/h/builds/demo-os-TK-61-202609190001"; mkdir -p "$B6"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/61" > "$B6/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$B6/review.md"
echo "$H1" > "$B6/reviewed-sha"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*|*"api -X PATCH"*)
    echo "WRITE VERB IN OBSERVE MODE: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R example-org/demo-os --state open"*)
    echo '[{"number":61,"url":"https://github.com/example-org/demo-os/pull/61","headRefOid":"$H1","headRefName":"ticket/TK-61","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"}]' ;;
  *"pr list"*) echo "[]" ;;
  # The flake read and the CI read ask the same URL and differ only in their -q
  # (mc_ci_flake_runs selects cancelled/timed_out). No flake here: this PR is
  # BLOCKED with every run it has green, which is the identity shape today.
  *'select(.s == "completed"'*) echo "" ;;
  *"actions/runs?head_sha=$H1"*) printf 'completed|success\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
# Everything the tick asks the worker still 404s (the fail-open direction the
# rest of this suite relies on) EXCEPT the two held-page verbs BH-1201 added:
# under observe the conductor now HOLDS its two age pages instead of sending
# them, so the surface this section reads them off is the PUT body, not
# ALERTS.log. Every request is recorded.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; BODY=""; METHOD=GET
while [ \$# -gt 0 ]; do
  case "\$1" in
    -X) METHOD="\$2"; shift 2 ;;
    --data-binary) BODY="\$2"; shift 2 ;;
    -H) shift 2 ;;
    *) shift ;;
  esac
done
printf '%s %s %s\n' "\$METHOD" "\$URL" "\$BODY" >> "$T/req.log"
case "\$METHOD \$URL" in
  "PUT "*/api/conductor/held) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/conductor/held*) printf '{"rows":[],"n_total":0}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
: > "$T/req.log"
# held_bodies <kind> — the text field of every held page the tick PUT for §6's PR
held_bodies() {
  grep 'PUT .*api/conductor/held' "$T/req.log" 2>/dev/null | sed 's/^[^ ]* [^ ]* //' \
    | jq -r --arg k "${1:-}" 'select(.number==61 and .kind==$k) | .text' 2>/dev/null
}
: > "$T/gh-writes.txt"
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
                 bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
             || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
K6P='example-org/demo-os#61'; U6P=https://github.com/example-org/demo-os/pull/61
run_tick
[ "$(mc_row_field "$K6P" 2)" = WAIT_CI ] \
  && ok || bad "a BLOCKED+MERGEABLE+green+approved PR must classify WAIT_CI (got '$(mc_row_field "$K6P" 2)')"
[ "$(mc_row_field "$K6P" 7)" = "$WHY2B" ] \
  && ok || bad "the reason the tick records for it must be the one main writes today (got '$(mc_row_field "$K6P" 7)')"
# Age the row past both thresholds and tick again: same state, so mc_transition
# keeps this `since` and both checks judge a 120m-old row.
mc_row_put "$K6P" WAIT_CI "$OLD" "$H1" "$H1" - "$WHY2B" "$U6P"
run_tick
# BH-1201 MOVED THE SURFACE, NOT THE CONTROL FLOW. A tick with no flags resolves
# MODE=observe, and observe is now a HOLD: the two age pagers write a
# conductor_held_pages row carrying the page's exact text instead of calling
# mc_alert, and the page is flushed unchanged on the first merge/actions tick.
# So what §6 reads is the held PUT body. Every claim below is the one it made
# before — both checks on the live tick's path, fed the row's reason, with the
# waiting-on sentence intact — asserted on the text the reader will receive.
# Delete either call site in bin/merge-conductor.sh and this still goes red.
BUDGETTEXT=$(held_bodies BUDGET); STUCKTEXT=$(held_bodies STUCK)
{ [ -n "$BUDGETTEXT" ] || [ -n "$STUCKTEXT" ]; } \
  && ok || bad "the real tick must still surface a genuinely blocked row (budget + TTL) — got nothing: $(cat "$T/req.log")"
grep -qF 'in WAIT_CI:' <<<"$BUDGETTEXT" \
  && ok || bad "mc_budget_check must be on the tick's path (no budget page held: '$BUDGETTEXT')"
grep -qF 'STUCK:' <<<"$STUCKTEXT" \
  && ok || bad "mc_stuck_check must be on the tick's path (no STUCK page held: '$STUCKTEXT')"
grep -qF 'waiting on a required check to report on this head' <<<"$STUCKTEXT" \
  && ok || bad "a genuinely blocked row must keep today's waiting-on sentence end to end: '$STUCKTEXT'"
grep -qF "$WHY2B" <<<"$(printf '%s\n%s' "$BUDGETTEXT" "$STUCKTEXT")" \
  && ok || bad "the tick must pass the ROW REASON to the checks — it is what the guard keys on"
# ... and NOTHING reached ALERTS.log, which is the whole of BH-1201: a lane an
# operator switched to observe does not page about age.
[ "$(alerts_for "$K6P")" = 0 ] \
  && ok || bad "an observe tick paged about age anyway: $(grep -F "$K6P" "$ALOG")"
[ -s "$T/gh-writes.txt" ] \
  && bad "observe-only tick used a write verb: $(cat "$T/gh-writes.txt")" || ok

echo "merge-conductor-identity.bh-988: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
