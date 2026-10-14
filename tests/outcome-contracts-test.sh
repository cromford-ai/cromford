#!/bin/bash
# tests/outcome-contracts-test.sh — phase 7 on the SHELL side.
#
# The worker's own rules live in worker/jobs/test/index.test.js. What this file
# proves is the half that runs on a box: which artifacts the pipeline records
# and WHEN, what bin/merge-sweep.sh does with a verdict that came out of the
# ledger instead of off its own disk, and — the property every one of these
# rests on — that an empty ledger or an unreachable worker leaves each script
# behaving exactly as it did before phase 7.
#
# WHY DRIVEN AND NOT GREPPED. `grep -q job_verdict bin/merge-sweep.sh` would
# pass just as happily on a sweep that merged on a BLOCK, or one that stopped
# merging entirely when the coordination DB blinked. curl is stubbed, so what is
# under test is the shell's control flow, which is where all of those live.
#
# Run from anywhere: tests/outcome-contracts-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
mkdir -p "$T/logs" "$T/locks" "$T/flags" "$T/state" "$T/bin" "$T/fakebin" "$T/builds/rec-1"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/merge-sweep.sh" "$T/bin/merge-sweep.sh"
mkdir -p "$T/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$T/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
cp "$DIR/bin/alert-line.sh" "$T/bin/"
# Since BH-784 the sweep's decision reads go through the conductor lib and
# bin/lib/gh-rest.sh. Without both in the scratch box's bin/lib the sweep's
# fail-closed shims answer "unverifiable" to every read and nothing is swept.
mkdir -p "$T/bin/lib"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
mkdir -p "$T/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/bin/lib/mc/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# --- the stubbed worker -------------------------------------------------------
# VERDICT_MODE picks what the ledger says about a PR. `none` is the empty-ledger
# case (404 -> a REAL answer), `down` is the outage (transport failure).
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary) BODY="$2"; shift 2;; *) shift;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
case "$URL" in
  */api/verdict*)
    case "${VERDICT_MODE:-none}" in
      down)     exit 7 ;;
      none)     printf '{"error":"no job has recorded this PR"}\n404\n' ;;
      approve)  printf '{"pr":"p","job_id":"build-project-3-TK-1-1","verdict":"APPROVE","tier":"2","provenance":"claude","merge_sha":null}\n200\n' ;;
      block)    printf '{"pr":"p","job_id":"build-project-3-TK-1-1","verdict":"BLOCK","tier":"2","provenance":"claude","merge_sha":null}\n200\n' ;;
      cheap)    printf '{"pr":"p","job_id":"build-project-3-TK-1-1","verdict":"APPROVE","tier":"2","provenance":"grok","merge_sha":null}\n200\n' ;;
      novrd)    printf '{"pr":"p","job_id":"build-project-3-TK-1-1","verdict":null,"tier":null,"provenance":null}\n200\n' ;;
    esac ;;
  */api/catalog/*)
    case "${CAP_MODE:-plain}" in
      down)     exit 7 ;;
      plain)    printf '{"lane":"x","matched":"execute/p/claude","budget_usd":12.50,"source":"catalog","explicit":0}\n200\n' ;;
      explicit) printf '{"lane":"x","matched":"execute/p/claude","budget_usd":12.50,"source":"catalog","explicit":1,"explicit_reason":"on purpose"}\n200\n' ;;
      # The build-family tier the worker actually returns since 2026-08-30
      # ($50, raised from $10.50). The VALUE is not what this stub proves — a
      # tier answer is reported as a miss whatever it says — but a fixture that
      # quotes a number the worker no longer serves is a lie waiting to be read
      # as a spec.
      tier)     printf '{"lane":"x","matched":null,"budget_usd":50,"source":"tier","explicit":0}\n200\n' ;;
    esac ;;
  */phases/close)  printf '{"job_id":"j","closed":1,"phases":[{"phase":"plan"}]}\n200\n' ;;
  */api/phases/*)
    case "${PHASE_MODE:-ok}" in
      unmet) printf '{"contract_unmet":true,"reason":"phase plan must record a plan_file artifact before it can close done, and none was recorded","phase":{"id":11,"status":"contract_unmet"}}\n409\n' ;;
      *)     printf '{"phase":{"id":11,"status":"done"}}\n200\n' ;;
    esac ;;
  */artifacts)     printf '{"artifact":{"artifact_kind":"k","artifact_ref":"r"}}\n200\n' ;;
  */api/ledger*)   printf '{"error":"not found"}\n404\n' ;;
  # TEST-CHANGE BH-4153: flag_active now reads automerge-disabled* DB-first; the '{}' 200
  # catch-all is an unreadable row, which a stop switch reads as ON (fail closed). No row = off.
  */api/flags/*)   printf '{"error":"not found"}\n404\n' ;;
  *)               printf '{}\n200\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

probe() { # probe <shell-snippet>
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box REQ_SINK="$T/req.txt"
    unset JOB_ID JOB_BEAT JOB_PHASE_ID
    # shellcheck source=/dev/null
    . "$T/bin/jobs-client.sh"; eval "$1" )
}

# --- 1. job_verdict: three answers, and only one of them is a verdict ---------
# rc 2 is the load-bearing one. "The ledger has nothing to say about this PR"
# and "the worker is down" must BOTH fall through to the caller's own record,
# because that record is the same evidence and falling back to it is byte-for-
# byte today's behaviour. Anything else starves a PR on a network blip.
# The trailing "-" is reviewed_sha (SDLC item 1) on a row that carries none: the
# ledger has no claim about which head was approved, and every merge gate reads
# that as today's behaviour rather than as a mismatch.
OUT=$(probe 'VERDICT_MODE=approve job_verdict https://x/pull/1; echo " rc=$?"')
case "$OUT" in
  "APPROVE	2	claude	-	build-project-3-TK-1-1	- rc=0") ok ;;
  *) bad "job_verdict did not return the ledger row as TSV: $OUT" ;;
esac
OUT=$(probe 'VERDICT_MODE=none job_verdict https://x/pull/1; echo "rc=$?"')
[ "$OUT" = "rc=2" ] && ok || bad "an empty ledger must be rc 2 (a real miss), got: $OUT"
OUT=$(probe 'VERDICT_MODE=down job_verdict https://x/pull/1; echo "rc=$?"')
[ "$OUT" = "rc=1" ] && ok || bad "an outage must be rc 1 and silent, got: $OUT"
# A job that recorded its PR but not yet its verdict is the SAME real miss —
# returning rc 0 with a blank line would hand a merge gate an empty verdict.
OUT=$(probe 'VERDICT_MODE=novrd job_verdict https://x/pull/1; echo "rc=$?"')
[ "$OUT" = "rc=2" ] && ok || bad "a PR with no verdict recorded yet must read as a miss, got: $OUT"

# --- 2. job_cap_row carries the explicit flag; job_cap keeps its old shape ----
# bin/ syncs per box and not atomically across the fleet, so a NEW jobs-client
# under an OLD bin/agent-call.sh has to keep answering the bare number that
# script parses. A cap that arrived as "12.50<TAB>1" and was compared
# numerically would be a budget bug wearing a feature's clothes.
OUT=$(probe 'CAP_MODE=plain job_cap_row execute/p/claude; echo " rc=$?"')
[ "$OUT" = "12.50	0 rc=0" ] && ok || bad "job_cap_row on a default row: $OUT"
OUT=$(probe 'CAP_MODE=explicit job_cap_row execute/p/claude; echo " rc=$?"')
[ "$OUT" = "12.50	1 rc=0" ] && ok || bad "job_cap_row on an explicit row: $OUT"
OUT=$(probe 'CAP_MODE=explicit job_cap execute/p/claude; echo " rc=$?"')
[ "$OUT" = "12.50 rc=0" ] && ok || bad "job_cap changed shape — an older agent-call.sh parses this: $OUT"
OUT=$(probe 'CAP_MODE=tier job_cap_row execute/p/claude; echo "rc=$?"')
[ "$OUT" = "rc=1" ] && ok || bad "a tier fallback must stay nonzero so UNBUDGETED LANE still fires: $OUT"
OUT=$(probe 'CAP_MODE=down job_cap_row execute/p/claude; echo "rc=$?"')
[ "$OUT" = "rc=1" ] && ok || bad "an outage must leave job_cap_row silent: $OUT"

# --- 3. _budget_for: explicit binds VERBATIM, default keeps the family floor --
# The REAL function from bin/agent-call.sh, extracted, so a regression in the
# shipped lines fails here. execute's family max is 150: a $12.50 default row is
# floored to 150.00 ("max cost, not target cost"), and the same row marked
# explicit binds at 12.50 because a human said that exact number on purpose.
awk '/^_budget_for\(\) \{/,/^\}$/' "$DIR/bin/agent-call.sh" > "$T/budget-for.sh"
grep -q 'job_cap_row' "$T/budget-for.sh" \
  && ok || bad "could not extract _budget_for from bin/agent-call.sh — this step would test nothing"

budget_for() { # budget_for <cap-mode>
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box CAP_MODE="$1"
    bash -c 'set -uo pipefail
      HARNESS="'"$T"'"; CONTEXT_BUDGETS="'"$T"'/nonexistent.json"
      declare -A _JOB_CAP_MEMO=()
      . "'"$T"'/bin/jobs-client.sh"
      . "'"$T"'/budget-for.sh"
      _budget_for execute p claude' )
}
[ "$(budget_for plain)" = "150.00" ] \
  && ok || bad "a DEFAULT db cap must still be floored at the family max, got: $(budget_for plain)"
[ "$(budget_for explicit)" = "12.50" ] \
  && ok || bad "an EXPLICIT db cap must bind verbatim, got: $(budget_for explicit)"
[ "$(budget_for down)" = "150.00" ] \
  && ok || bad "with the worker down the tier must still fund the lane, got: $(budget_for down)"

# --- 4. a contract breach is visible, and never changes what a stage returns --
# job_phase_close hands back rc 9 on a 409 and logs WHY. Every caller in the
# fleet closes a phase best-effort (`|| true`), so this can never alter a
# stage's own exit code — but a human reading jobs-client.log has to be able to
# see why a `done` became something else.
OUT=$(probe 'JOB_PHASE_ID=11 PHASE_MODE=unmet job_phase_close 0 1.5 note; echo "rc=$?"')
[ "$OUT" = "rc=9" ] && ok || bad "a contract breach must surface as rc 9, got: $OUT"
grep -q 'phase 11 close refused: phase plan must record a plan_file artifact' "$T/logs/jobs-client.log" \
  && ok || bad "the breach reason never reached jobs-client.log: $(tail -2 "$T/logs/jobs-client.log" 2>/dev/null)"
OUT=$(probe 'JOB_PHASE_ID=11 PHASE_MODE=ok job_phase_close 0 1.5 note; echo "rc=$?"')
[ "$OUT" = "rc=0" ] && ok || bad "a satisfied contract must close cleanly, got: $OUT"

# --- 5. merge-sweep: the ledger decides when it can, the record when it cannot -
# The sweep is driven whole, against a build record that would merge today, so
# what is measured is the shipped control flow and not a paraphrase of it.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  # An empty rate_limit answer leaves bin/lib/gh-budget.sh a 0-byte cache file
  # and a later sweep in this scratch tree dies on it mid-tick.
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  # THE DECISION READS ARE REST (BH-784): one gh api -i -X GET on the pull,
  # judged on its HTTP status line, so restpr prints a whole response. The diff
  # shares that path and is told apart by its Accept header, so it matches FIRST.
  # After the merge call the sweep re-reads the same pull to learn what actually
  # happened (gh's exit code is not a landing: on a merge-queue repo the same
  # call only enqueues), and that answer carries the merge sha.
  *"v3.diff"*)                              restpr --diff '+ const x = 1;
' ;;
  *"api -i -X GET repos/o/r/pulls/7"*)
    if [ -s "$MERGE_SINK" ]; then restpr MERGED headsha ticket/x main "" MERGEABLE CLEAN operator deadbeefcafe
    else restpr OPEN headsha ticket/x main "" MERGEABLE CLEAN operator; fi ;;
  *"pr merge"*)                             echo "merged" >> "$MERGE_SINK"; exit 0 ;;
  *)                                        echo "" ;;
esac
EOF
chmod +x "$T/fakebin/gh"
mkdir -p "$T/bin"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/fleet-conf.sh"; chmod +x "$T/bin/fleet-conf.sh"

setup_record() { # setup_record <record-verdict APPROVE|BLOCK>
  rm -rf "$T/builds/rec-1"; mkdir -p "$T/builds/rec-1"
  echo "PR_CREATED https://github.com/o/r/pull/7" > "$T/builds/rec-1/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: %s\n' "$1" > "$T/builds/rec-1/review.md"
  : > "$T/builds/rec-1/pipeline.log"
  : > "$T/state/merge-sweep-done.txt"
  : > "$T/logs/merge-sweep.log"; : > "$T/logs/ALERTS.log"; : > "$T/merges.txt"
}
sweep() { # sweep <verdict-mode>
  ( export PATH="$T/fakebin:$T/bin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box VERDICT_MODE="$1" \
           MERGE_SINK="$T/merges.txt" REQ_SINK="$T/req.txt"
    bash "$T/bin/merge-sweep.sh" >/dev/null 2>&1 )
}

# 5a. EMPTY LEDGER = today, byte for byte. The record's APPROVE merges; its
#     BLOCK does not. This is the whole safety argument for filling the ledger
#     one build at a time.
setup_record APPROVE; sweep none
grep -q merged "$T/merges.txt" \
  && ok || bad "with an empty ledger an APPROVE record must merge exactly as before"
setup_record BLOCK; sweep none
grep -q merged "$T/merges.txt" \
  && bad "with an empty ledger a BLOCK record merged" || ok

# 5b. an outage is the same fallback, never a starved PR
setup_record APPROVE; sweep down
grep -q merged "$T/merges.txt" \
  && ok || bad "a worker outage stopped the sweep — the record is the same evidence"

# 5c. the ledger's APPROVE merges, and the merge sha lands on the BUILD's job
setup_record APPROVE; sweep approve
grep -q merged "$T/merges.txt" \
  && ok || bad "a ledger APPROVE did not merge"
grep -q 'PUT .*/api/jobs/build-project-3-TK-1-1/artifacts.*merge_sha' "$T/req.txt" \
  && ok || bad "the merge sha was not recorded on the build's own job"
grep -q 'deadbeefcafe' "$T/req.txt" \
  && ok || bad "the recorded merge sha is not the one gh reported"

# 5d. a ledger BLOCK stops the merge even though the local record says APPROVE
#     is impossible to reach here — the two disagreeing is a PARK, not a vote.
setup_record APPROVE; sweep block
grep -q merged "$T/merges.txt" \
  && bad "a ledger/record disagreement merged instead of parking" || ok
grep -q 'ledger says BLOCK, build record says APPROVE' "$T/logs/merge-sweep.log" \
  && ok || bad "the park did not name both verdicts: $(cat "$T/logs/merge-sweep.log")"
grep -q 'disagree about the verdict' "$T/logs/ALERTS.log" \
  && ok || bad "a verdict disagreement did not page anyone: $(cat "$T/logs/ALERTS.log")"

# 5d-bis. ledger and record AGREEING on BLOCK is not a disagreement — it is a
#         plain skip, and it must not page anyone.
setup_record BLOCK; sweep block
grep -q merged "$T/merges.txt" \
  && bad "a BLOCK the ledger and the record agree on merged anyway" || ok
grep -q 'disagree about the verdict' "$T/logs/ALERTS.log" \
  && bad "two records that AGREE were alerted as a disagreement" || ok

# 5e. judge provenance, from the ROW: a cheap-lane APPROVE gates but never merges
setup_record APPROVE; sweep cheap
grep -q merged "$T/merges.txt" \
  && bad "a cheap-lane review authored the verdict and the sweep merged it anyway" || ok
grep -q 'ledger provenance is grok' "$T/logs/merge-sweep.log" \
  && ok || bad "the provenance skip did not say which lane served it"

# --- 6. no secret ever reaches a log -----------------------------------------
for F in "$T/logs/ALERTS.log" "$T/logs/merge-sweep.log" "$T/logs/jobs-client.log" "$T/req.txt"; do
  [ -f "$F" ] || continue
  grep -q 'test-secret' "$F" \
    && bad "HARNESS_SECRET reached $(basename "$F")" || ok
done

echo "outcome-contracts-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
