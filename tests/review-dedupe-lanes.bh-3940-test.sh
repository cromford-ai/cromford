#!/bin/bash
# tests/review-dedupe-lanes.bh-3940-test.sh — BH-3940 (BH-3930 slice 4): the
# three review lanes share the per-head guard key and ask "already bought?"
# before buying a review.
#
#   C1  bin/review-prs.sh (the real lane): review_bought rc 0 on this head buys
#       nothing, records {sha, verdict, reused_from} and logs
#       review_skip_unchanged. rc 2 buys exactly one review on stage review-head
#       under `review:<slug>#<n>@<head>`. An odd class is never an APPROVE.
#   C2  a re-review request buys under `~rereq` and is never skipped; a second
#       request on the same head is refused by the K=1 guard and handed back.
#   C3  a step-up of a trivial APPROVE buys under `~stepup`, never skipped.
#   C4  mc_rereview (the real conductor lib): stage review-head, key `review:`,
#       and one `rrverdict` row after a parsed verdict, with pr-state rows OFF.
#       No verdict, no row. A row that does not land is one log line, and the
#       verdict still stands.
#   C5  mc_rereview_spawn passes MC_RR_REASON=noverdict after a `failed` job
#       (or the retry marker that replaced its file), empty otherwise; the
#       noverdict deferral line is said once per (PR, head).
#   C6  the real conductor tick: a bound approve on a green head is consumed
#       (hb_approve_bind, rbverdict, no spawn); a bound block parks; a pending
#       head consumes nothing; no lib in the tree is today's spawn.
#   C7  the resolver's `# >>> br rereview post` block with a verdict on record:
#       no mc_rereview, no llm count, WAIT_REVIEW, "Re-review not bought".
#   C8  the same block on a miss names its own reason: brnv<n+1> or preflight.
#
# BH-4134 changed C1 (a no-served reuse is served:reused-unknown), C4 (the
# rrverdict row's 4th field) and C6a/C6c (the bound approve is Claude-served).
#
# review_bought is stubbed (STUB_RB_RC / STUB_RB_SOURCE / STUB_RB_WORD /
# STUB_RB_CLASS / STUB_RB_SERVED) on top of the real bin/lib/review-bought.sh, so review_fp and
# review_skip_log are the real ones. The fake agent-call.sh emulates the K=1
# guard per fingerprint.
# Run from anywhere: bash tests/review-dedupe-lanes.bh-3940-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$(dirname "$0")/lib/model-route-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

HEAD=ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12
OLD=0123456789abcdef0123456789abcdef01234567
mkdir -p "$T/fakebin"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"

# The review_bought stub: the real lib, with only review_bought replaced.
{ cat "$DIR/bin/lib/review-bought.sh"
  cat <<'EOF'
review_bought() {
  RB_SOURCE=""; RB_WORD=""; RB_CLASS=""
  printf '%s\n' "$*" >> "${STUB_RB_CALLS:-/dev/null}"
  local rc="${STUB_RB_RC:-2}"
  if [ "$rc" = 0 ]; then
    RB_SOURCE="${STUB_RB_SOURCE:-}"; RB_WORD="${STUB_RB_WORD:-}"; RB_CLASS="${STUB_RB_CLASS:-}"; RB_SERVED="${STUB_RB_SERVED:-}"
    printf '%s\t%s\n' "$RB_SOURCE" "$RB_WORD"
  fi
  return "$rc"
}
EOF
} > "$T/rb-stub.sh"
export STUB_RB_CALLS="$T/rb-calls.txt"
rb() { export STUB_RB_RC="$1" STUB_RB_SOURCE="${2:-}" STUB_RB_WORD="${3:-}" STUB_RB_CLASS="${4:-}" STUB_RB_SERVED="${5:-}"; }

# The fake agent-call: a paid call is one sink line; a second sight of the same
# fingerprint is the K=1 refusal (rc 74, nothing called).
mk_agent() { # mk_agent <file> <verdict-file>
  cat > "$1" <<EOF
#!/bin/bash
if grep -qxF "\${AGENT_CALL_FP:-}" "$T/seen-fps.txt" 2>/dev/null || [ -f "$T/guard-refuse" ]; then
  printf 'stage=%s fp=%s\n' "\${AGENT_CALL_GUARD_STAGE-}" "\${AGENT_CALL_FP-}" >> "$T/refused.txt"
  printf 'AGENT_CALL_REFUSED call-guard repeat review-head paid=1/1 fp=%s\n' "\${AGENT_CALL_FP:-}" > "\$5"
  exit 74
fi
printf '%s\n' "\${AGENT_CALL_FP:-}" >> "$T/seen-fps.txt"
printf 'stage=%s fp=%s\n' "\${AGENT_CALL_GUARD_STAGE-}" "\${AGENT_CALL_FP-}" >> "$T/sink.txt"
printf 'claude\n' > "\$5.runner"; printf 'claude-fable-5-1\n' > "\$5.model"
if [ -f "$T/noverdict" ]; then printf 'findings and no verdict line\n' > "\$5"; exit 0; fi
printf 'Static review.\nTIER: 2\nVERDICT: %s\n' "\$(cat "$2" 2>/dev/null || echo APPROVE)" > "\$5"
EOF
  chmod +x "$1"
}
reset_calls() { rm -f "$T/sink.txt" "$T/refused.txt" "$T/seen-fps.txt" "$T/rb-calls.txt" "$T/guard-refuse" "$T/noverdict"; }
sinkn() { [ -f "$T/sink.txt" ] && wc -l < "$T/sink.txt" | tr -d ' ' || echo 0; }

# ============================================================================
# C1-C3 — bin/review-prs.sh, the real lane
# ============================================================================
PROJECT=project-1
SLUG=example-org/project-1
NUM=7
RP="$DIR/bin/review-prs.sh"
STATE="$T/h/state/$PROJECT.pr-reviews.json"
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
case "$*" in
  *"pr list"*) cat "$TEST_ROOT/prs.tsv" ;;
  *"pr diff"*"name-only"*) printf 'f.txt\n' ;;
  *"pr diff"*) printf 'diff --git a/f.txt b/f.txt\n+line 10 CHANGED BY PR\n' ;;
  *"pr view"*"state,mergeStateStatus"*) printf '{"state":"OPEN","mergeStateStatus":"BLOCKED"}\n' ;;
  *"pr view"*"comments,reviews"*) printf '{"comments":[],"reviews":[]}\n' ;;
  *"pr view"*"body"*) printf '{"body":"test body"}\n' ;;
  *"pr review"*|*"pr comment"*) printf '%s\n' "$*" >> "$TEST_ROOT/gh-writes.log" ;;
  *"pr merge"*) : ;;
  *actions/runs*) printf '{"s":"completed","c":"success","n":"CI"}\n' ;;
  *"issues/7/comments"*) restpr --raw 200 "$(cat "$TEST_ROOT/comments.json" 2>/dev/null || echo '[]')" ;;
  *"api"*) : ;;
esac
exit 0
STUB
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
chmod +x "$T/fakebin/gh" "$T/fakebin/sleep"
cat > "$T/stub.sh" <<'STUB'
job_lane_open() { JOB_ID="job-x"; export JOB_ID; return 0; }
job_lane_close() { JOB_ID=""; export JOB_ID; return 0; }
job_artifact_put() { return 0; }
job_event() { return 0; }
job_heartbeat() { return 0; }
job_update() { return 0; }
job_phase_open() { return 0; }
job_verdict_rebind() { return 0; }
STUB
fresh_rp() { # fresh_rp <state-json> [lib]  — lib=no leaves review-bought.sh out of the tree
  scratch_rm "$T/h" 2>/dev/null
  reset_calls; rm -f "$T/gh-writes.log" "$T/rp-verdict" "$T/comments.json"
  mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/locks" "$T/h/env" "$T/h/builds"
  mk_agent "$T/h/bin/agent-call.sh" "$T/rp-verdict"
  cp "$DIR/bin/lib/review-model.sh" "$DIR/bin/lib/fixround-preflight.sh" "$T/h/bin/lib/"
  [ "${2:-}" = no ] || cp "$T/rb-stub.sh" "$T/h/bin/lib/review-bought.sh"
  mrs_fixture "$T/h" "$PROJECT"
  cp "$T/stub.sh" "$T/h/bin/stub.sh"
  for b in beat.sh deploy-request.sh merge-queue.sh; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$b"; chmod +x "$T/h/bin/$b"; done
  printf '%s\n' "$1" > "$STATE"
  printf '%s\t%s\texternaldev\tTest PR\n' "$NUM" "$HEAD" > "$T/prs.tsv"
}
run_rp() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" FLEET_CONF="$DIR/fleet.conf" TEST_ROOT="$T" \
      REPOS_ROOT="$T/no-repos" BASH_ENV="$T/h/bin/stub.sh" REVIEW_LIVE_CI=0
    unset JOB_ID JOB_BEAT JOB_INFLIGHT JOB_REFUSED
    bash "$RP" "$PROJECT" >/dev/null 2>&1 )
}
st() { jq -r --arg n "$NUM" ".[\$n].$1 // \"\"" "$STATE" 2>/dev/null; }
rplog() { cat "$T/h/logs/"*review* 2>/dev/null; }

# ---- C1: a verdict on record for this head buys nothing
fresh_rp "{\"$NUM\":{\"sha\":\"$OLD\",\"verdict\":\"APPROVE\",\"trivial\":\"1\",\"served\":\"claude\"}}"
rb 0 box APPROVE approve
run_rp
[ "$(sinkn)" = 0 ] && ok || bad "C1 a head with a verdict on record must buy no review: $(cat "$T/sink.txt" 2>/dev/null)"
[ "$(st sha)" = "$HEAD" ] && [ "$(st verdict)" = APPROVE ] && [ "$(st reused_from)" = box ] && ok \
  || bad "C1 \$STATE must record {sha, verdict, reused_from} on this head: $(cat "$STATE")"
[ -z "$(st trivial)" ] && [ "$(st served)" = reused-unknown ] && ok || bad "C1 the previous head's trivial must not survive, and a no-served reuse is served:reused-unknown: $(cat "$STATE")"
case "$(st reviewing_attempts)" in ''|0) ok ;; *) bad "C1 a skip must charge no in-flight attempt: $(cat "$STATE")" ;; esac
rplog | grep -q "review_skip_unchanged $SLUG#$NUM@${HEAD:0:12} lane=review-prs by=box/APPROVE" && ok \
  || bad "C1 the skip must be logged as review_skip_unchanged: $(rplog | tail -3)"
grep -qx "$SLUG $NUM $HEAD" "$T/rb-calls.txt" 2>/dev/null && ok || bad "C1 review_bought must be asked about this exact head: $(cat "$T/rb-calls.txt" 2>/dev/null)"
# C1b: a miss buys exactly one review, on the shared per-head key
fresh_rp "{\"$NUM\":{\"sha\":\"$OLD\",\"verdict\":\"APPROVE\"}}"
rb 2
run_rp
[ "$(sinkn)" = 1 ] && ok || bad "C1b a miss must buy exactly one review: $(cat "$T/sink.txt" 2>/dev/null)"
grep -qx "stage=review-head fp=review:$SLUG#$NUM@$HEAD" "$T/sink.txt" 2>/dev/null && ok \
  || bad "C1b the call must be stage review-head, fp review:<slug>#<n>@<head>: $(cat "$T/sink.txt" 2>/dev/null)"
[ "$(st sha)" = "$HEAD" ] && [ -z "$(st reused_from)" ] && ok || bad "C1b the bought verdict is recorded, not a reuse: $(cat "$STATE")"
# C1c: rc 0 with an odd class is never an approval
fresh_rp "{\"$NUM\":{\"sha\":\"$OLD\",\"verdict\":\"APPROVE\"}}"
rb 0 box WHATEVER weird
run_rp
[ "$(sinkn)" = 0 ] && [ "$(st verdict)" = REQUEST_CHANGES ] && [ "$(st sha)" = "$HEAD" ] && ok \
  || bad "C1c an unknown class must record REQUEST_CHANGES, never APPROVE: calls=$(sinkn) $(cat "$STATE")"
# C1d: REVIEW_DEDUPE=0 reads nothing and buys as before
fresh_rp "{\"$NUM\":{\"sha\":\"$OLD\",\"verdict\":\"APPROVE\"}}"
rb 0 box APPROVE approve
REVIEW_DEDUPE=0 run_rp
[ "$(sinkn)" = 1 ] && [ ! -s "$T/rb-calls.txt" ] && ok || bad "C1d REVIEW_DEDUPE=0 must not ask and must buy: calls=$(sinkn) asks=$(cat "$T/rb-calls.txt" 2>/dev/null)"
# C1e: no lib in the tree is today's path, on the same inline key
fresh_rp "{\"$NUM\":{\"sha\":\"$OLD\",\"verdict\":\"APPROVE\"}}" no
rb 0 box APPROVE approve
scratch_rm "$T/nolib" 2>/dev/null; mkdir -p "$T/nolib/bin"
cp -R "$DIR/bin/lib" "$T/nolib/bin/lib"; rm -f "$T/nolib/bin/lib/review-bought.sh"
cp "$RP" "$DIR/bin/fleet-conf.sh" "$T/nolib/bin/"
( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" FLEET_CONF="$DIR/fleet.conf" TEST_ROOT="$T" \
    REPOS_ROOT="$T/no-repos" BASH_ENV="$T/h/bin/stub.sh" REVIEW_LIVE_CI=0
  unset JOB_ID JOB_BEAT JOB_INFLIGHT JOB_REFUSED
  bash "$T/nolib/bin/review-prs.sh" "$PROJECT" >/dev/null 2>&1 )
grep -qx "stage=review-head fp=review:$SLUG#$NUM@$HEAD" "$T/sink.txt" 2>/dev/null && [ "$(sinkn)" = 1 ] && ok \
  || bad "C1e without the lib the lane buys under the inline key: $(cat "$T/sink.txt" 2>/dev/null)"

# ---- C2: a re-review request buys under ~rereq and is never skipped
# BH-8419: the hub App posts the re-review request (cromford[bot], type Bot).
rq_comment() { jq -nc --arg b "<!-- harness:rereview-requested $HEAD -->" '[{user:{login:"cromford[bot]", type:"Bot"}, body:$b}]' > "$T/comments.json"; }
fresh_rp "{\"$NUM\":{\"sha\":\"$HEAD\",\"verdict\":\"REQUEST_CHANGES\"}}"
rq_comment; echo REQUEST_CHANGES > "$T/rp-verdict"
rb 0 box APPROVE approve
run_rp
[ "$(sinkn)" = 1 ] && ok || bad "C2 a requested re-review is never skipped, even with a verdict on record: $(cat "$T/sink.txt" 2>/dev/null)"
grep -qx "stage=review-head fp=review:$SLUG#$NUM@$HEAD~rereq" "$T/sink.txt" 2>/dev/null && ok \
  || bad "C2 the request must buy under ~rereq on review-head: $(cat "$T/sink.txt" 2>/dev/null)"
rplog | grep -q 're-review requested by cromford\[bot\].*REREVIEW_REASON=rereq' && ok || bad "C2 the request line must name REREVIEW_REASON=rereq: $(rplog | grep -i requested)"
[ "$(st rereq_sha)" = "$HEAD" ] && ok || bad "C2 the honoured request is spent on this head: $(cat "$STATE")"
# A wiped rereq_sha asks again: the guard refuses the same key, nothing is paid,
# and the request is handed back.
jq --arg n "$NUM" '.[$n] |= del(.rereq_sha)' "$STATE" > "$STATE.t" && mv "$STATE.t" "$STATE"
run_rp
[ "$(sinkn)" = 1 ] && ok || bad "C2 a second rereq on the same head must not be paid: $(cat "$T/sink.txt")"
[ "$(wc -l < "$T/refused.txt" 2>/dev/null | tr -d ' ')" = 1 ] && grep -q "fp=review:$SLUG#$NUM@$HEAD~rereq" "$T/refused.txt" && ok \
  || bad "C2 the second rereq must reach the K=1 guard on the same key and be refused: $(cat "$T/refused.txt" 2>/dev/null)"
[ -z "$(st rereq_sha)" ] && ok || bad "C2 a refused rereq hands the request back: $(cat "$STATE")"

# ---- C3: a step-up of a trivial APPROVE buys under ~stepup
fresh_rp "{\"$NUM\":{\"sha\":\"$HEAD\",\"verdict\":\"APPROVE\",\"trivial\":\"1\"}}"
rb 0 box APPROVE approve
run_rp
[ "$(sinkn)" = 1 ] && grep -qx "stage=review-head fp=review:$SLUG#$NUM@$HEAD~stepup" "$T/sink.txt" && ok \
  || bad "C3 the step-up must buy under ~stepup, never skipped: $(cat "$T/sink.txt" 2>/dev/null)"
rplog | grep -q "trivial route's advisory read.*REREVIEW_REASON=stepup" && ok || bad "C3 the step-up line must name REREVIEW_REASON=stepup: $(rplog | grep -i advisory)"

# ============================================================================
# C4-C5 — the conductor lib: mc_rereview, mc_rereview_spawn, mc_rereview_run
# ============================================================================
M="$T/mc"; MFB="$T/mc-fakebin"
mkdir -p "$M/bin/lib/mc" "$M/logs" "$M/state" "$M/env" "$MFB"
cp "$DIR/bin/lib/review-model.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/review-provenance.sh" "$DIR/bin/lib/gh-pr-list.sh" \
   "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$M/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$M/bin/lib/mc/"
cp "$T/rb-stub.sh" "$M/bin/lib/review-bought.sh"
cp "$T/fakebin/restpr" "$MFB/restpr"
mrs_fixture "$M" proj
mk_agent "$M/bin/agent-call.sh" "$T/mc-verdict"
# pr-state rows OFF; the D1 put is recorded, and fails on demand.
cat > "$M/bin/jobs-client.sh" <<EOF
pr_rows_on() { return 1; }
pr_attempt_put() { printf 'PUT /api/pr-attempts repo=%s num=%s kind=%s sha=%s\n' "\$1" "\$2" "\$3" "\$4" >> "$T/puts.txt"
  [ -f "$T/put-fails" ] && return 1; return 0; }
EOF
cat > "$MFB/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"v3.diff"*) restpr --diff '--- a/x.sh
+++ b/x.sh
+echo hi
' ;;
  *"api -i -X GET repos/acme/widgets/pulls/34"*) restpr OPEN deadbeef ticket/x main "" MERGEABLE CLEAN operator "" 'a PR body' ;;
esac
exit 0
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/setsid.txt"\nexit 0\n' "$T" > "$MFB/setsid"
chmod +x "$MFB/gh" "$MFB/setsid"
MLOG="$M/logs/merge-conductor.log"
mc() { # mc <bash snippet> — runs with the real lib loaded against the scratch tree
  ( export HARNESS="$M" PATH="$MFB:$PATH" MC_RR_LIVE_CI=0
    bash -c 'set -uo pipefail; . "$HARNESS/bin/lib/merge-conductor-lib.sh"; '"$1" )
}
RRARGS="acme/widgets 34 proj https://github.com/acme/widgets/pull/34 oldsha $HEAD ''"

# ---- C4: key, stage, and the rrverdict row
reset_calls; rm -f "$T/puts.txt" "$T/put-fails"; : > "$MLOG"
V=$(mc "mc_rereview $RRARGS \"$T/rr.out\""); RC=$?
[ "$V" = APPROVE ] && [ "$RC" = 0 ] && ok || bad "C4 mc_rereview must still print exactly APPROVE, rc 0 (got '$V' rc $RC)"
grep -qx "stage=review-head fp=review:acme/widgets#34@$HEAD" "$T/sink.txt" 2>/dev/null && ok \
  || bad "C4 the re-review must buy on stage review-head under review:<slug>#<n>@<head>: $(cat "$T/sink.txt" 2>/dev/null)"
grep -qE "^PUT /api/pr-attempts repo=acme/widgets num=34 kind=rrverdict sha=$HEAD APPROVE [0-9]{10} claude\$" "$T/puts.txt" 2>/dev/null && ok \
  || bad "C4 a parsed verdict must write the rrverdict row '<head> <WORD> <epoch> <served>' with rows OFF: $(cat "$T/puts.txt" 2>/dev/null)"
# C4b: no verdict, no row
reset_calls; rm -f "$T/puts.txt"; touch "$T/noverdict"
V=$(mc "mc_rereview $RRARGS \"$T/rr.out\""); RC=$?
[ "$RC" = 1 ] && [ -z "$V" ] && ok || bad "C4b a review with no verdict is rc 1 (got '$V' rc $RC)"
[ ! -s "$T/puts.txt" ] && ok || bad "C4b no rrverdict row may be written without a parsed verdict: $(cat "$T/puts.txt")"
# C4c: a row that does not land is one log line; the verdict stands
reset_calls; rm -f "$T/puts.txt"; touch "$T/put-fails"; : > "$MLOG"
echo BLOCK > "$T/mc-verdict"
V=$(mc "mc_rereview $RRARGS \"$T/rr.out\""); RC=$?
[ "$V" = BLOCK ] && [ "$RC" = 0 ] && ok || bad "C4c a failed row put must not fail the review (got '$V' rc $RC)"
grep -q "kind=rrverdict sha=$HEAD BLOCK " "$T/puts.txt" 2>/dev/null && ok || bad "C4c the put must have been tried: $(cat "$T/puts.txt" 2>/dev/null)"
[ "$(grep -c 'rrverdict row .*did not land' "$MLOG")" = 1 ] && ok || bad "C4c exactly one 'rrverdict row … did not land' line: $(cat "$MLOG")"
rm -f "$T/put-fails" "$T/mc-verdict"

# ---- C5: the spawn names noverdict only after a billed no-verdict
spawn_reason() { # spawn_reason <job-status|none> [retry-marker] -> the MC_RR_REASON word in the setsid argv
  rm -f "$T/setsid.txt"
  mc '
    mkdir -p "$MC_RR_DIR"; : > "$MC_ATTEMPTS"
    jf=$(mc_rr_file acme/widgets 34 '"$HEAD"')
    rm -f "$jf"
    [ "'"$1"'" = none ] || mc_rr_write "$jf" "'"$1"'" 0 0 0 - '"$HEAD"' oldsha "${jf%.json}.out"
    [ -z "'"${2:-}"'" ] || echo "rereviewretry acme/widgets#34 '"$HEAD"'" >> "$MC_ATTEMPTS"
    mc_rereview_spawn acme/widgets 34 proj https://github.com/acme/widgets/pull/34 oldsha '"$HEAD"' ""'
  tr ' ' '\n' < "$T/setsid.txt" 2>/dev/null | grep '^MC_RR_REASON=' | head -1
}
R=$(spawn_reason failed);       [ "$R" = MC_RR_REASON=noverdict ] && ok || bad "C5 a spawn over a failed job must pass MC_RR_REASON=noverdict (got '$R': $(cat "$T/setsid.txt" 2>/dev/null))"
R=$(spawn_reason lane-failed);  [ "$R" = MC_RR_REASON= ] && ok || bad "C5 a spawn over a lane-failed job passes it empty (got '$R')"
R=$(spawn_reason none);         [ "$R" = MC_RR_REASON= ] && ok || bad "C5 a first read passes it empty (got '$R')"
R=$(spawn_reason none retry);   [ "$R" = MC_RR_REASON=noverdict ] && ok || bad "C5c the retry marker left by rereview_lane_retry means noverdict (got '$R')"
# C5d: the refused noverdict claim is said once per (PR, head)
run_twice() { # run_twice <reason> -> number of deferral lines
  : > "$MLOG"
  mc '
    mkdir -p "$MC_RR_DIR"; : > "$MC_ATTEMPTS"
    jf=$(mc_rr_file acme/widgets 34 '"$HEAD"')
    for i in 1 2; do
      MC_RR_REASON="'"$1"'" mc_rereview_run acme/widgets 34 proj https://github.com/acme/widgets/pull/34 oldsha '"$HEAD"' "" "$jf" "${jf%.json}.out"
    done
    cp "$MC_ATTEMPTS" "'"$T"'/att-'"${1:-plain}"'.txt"'
  grep -c 'deferred by the call-guard' "$MLOG"
}
reset_calls; touch "$T/guard-refuse"
[ "$(run_twice noverdict)" = 1 ] && ok || bad "C5d the noverdict deferral must be said once per (PR, head): $(cat "$MLOG")"
grep -qx "rrnvdefer acme/widgets#34 $HEAD" "$T/att-noverdict.txt" && ok || bad "C5d the once-only marker must be recorded: $(cat "$T/att-noverdict.txt")"
[ "$(run_twice '')" = 2 ] && ok || bad "C5d any other deferral is still said every time: $(cat "$MLOG")"
rm -f "$T/guard-refuse"

# ============================================================================
# C6 — the real conductor tick consumes a bound verdict instead of spawning
# ============================================================================
export JOBS_URL=https://jobs.invalid
C="$T/c"
mkdir -p "$C/bin/lib/mc" "$C/bin/lib/jobs" "$C/logs" "$C/state" "$C/flags" "$C/locks" "$C/builds" "$C/env" \
         "$T/cfb" "$T/runs" "$T/repos"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/block-gate.sh" "$DIR/bin/lib/verdicts.sh" "$C/bin/lib/"
cp "$DIR"/bin/lib/mc/*.sh "$C/bin/lib/mc/"; cp "$DIR"/bin/lib/jobs/*.sh "$C/bin/lib/jobs/"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$C/bin/"
cp "$T/rb-stub.sh" "$C/bin/lib/review-bought.sh"
cp "$T/fakebin/restpr" "$T/cfb/restpr"
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$C/fleet.conf"
: > "$C/env/global.env"
printf '#!/bin/bash\nprintf "static review\\nVERDICT: APPROVE\\n" > "$5"; exit 0\n' > "$C/bin/agent-call.sh"
chmod +x "$C/bin/agent-call.sh"
H_OLD=aaaaaaaa1111
H_GRN=$HEAD
H_PND=eeeeeeee4444eeeeeeeeeeeeeeeeeeeeeeeeeeee
REC="$C/builds/pool-demo-os-TK-12-202609120002"
mkdir -p "$REC"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/12" > "$REC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
runs_green() { printf '{"workflow_runs":[{"id":%s,"name":"Harness CI","run_started_at":"2026-09-18T00:00:00Z","run_attempt":1,"status":"completed","conclusion":"success"}]}\n' "$2" > "$T/runs/$1.json"; }
runs_green "$H_OLD" 900; runs_green "$H_GRN" 901
printf '{"workflow_runs":[{"id":902,"name":"Harness CI","run_started_at":"2026-09-18T00:00:00Z","run_attempt":1,"status":"in_progress","conclusion":null}]}\n' > "$T/runs/$H_PND.json"
for S in "$H_OLD" "$H_GRN" "$H_PND"; do printf 'patch for %s\n' "$S" > "$T/patch.$S"; done
cat > "$T/cfb/gh" <<EOF
#!/bin/bash
Q=""; ARGS=()
while [ \$# -gt 0 ]; do case "\$1" in -q|--jq) Q="\$2"; shift 2 ;; *) ARGS+=("\$1"); shift ;; esac; done
A="\${ARGS[*]}"
HEAD=\$(cat "$T/prhead" 2>/dev/null)
answer() {
  case "\$A" in *"api -i -X GET "*) [ -f "\$1" ] || { restpr --raw 404 '{"message":"Not Found"}'; exit 0; }; restpr --raw 200 "\$(cat "\$1")"; exit 0 ;; esac
  [ -f "\$1" ] || exit 1
  if [ -n "\$Q" ]; then jq -r "\$Q" "\$1"; else cat "\$1"; fi
}
case "\$A" in
  *"auth token"*) echo faketoken ;;
  *"pr merge"*) echo "MERGE ATTEMPTED" >> "$T/c-writes.txt"; exit 1 ;;
  *"pr list -R example-org/demo-os --state open"*)
    printf '[{"number":12,"url":"https://github.com/example-org/demo-os/pull/12","headRefOid":"%s","headRefName":"ticket/TK-12","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"}]\n' "\$HEAD" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) SHA="\${A#*head_sha=}"; SHA="\${SHA%%&*}"; SHA="\${SHA%% *}"; answer "$T/runs/\$SHA.json" ;;
  *"api -i -X POST repos/example-org/demo-os/issues/12/comments"*)
    { printf 'pr comment\n'; for a in "\${ARGS[@]}"; do case "\$a" in body=@*) cat "\${a#body=@}"; echo ;; esac; done; } >> "$T/c-comments.txt"
    restpr --raw 201 '{"id":1}' ;;
  *"v3.diff"*) restpr --diff '+++ b/src/x.ts
+const a = 1;
' ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/12"*) restpr OPEN "\$HEAD" ticket/TK-12 main "" MERGEABLE CLEAN app/cromford "" "plain body" ;;
  *"issues/12/comments"*) echo '[]' > "$T/c-empty.json"; answer "$T/c-empty.json" ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
cat > "$T/cfb/git" <<EOF
#!/bin/bash
A="\$*"
case "\$A" in
  *--version*) echo "git version 2.43.0" ;;
  *merge-tree*) exit 0 ;;
  *merge-base*) echo base0000base0000 ;;
  *patch-id*) md5sum | cut -d' ' -f1 ;;
  *" diff "*) SHA="\${A##* }"; cat "$T/patch.\$SHA" 2>/dev/null || printf 'diff-%s\n' "\$SHA" ;;
esac
exit 0
EOF
cat > "$T/cfb/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "GET "*/api/verdicts\?*) printf '{"standing":null,"rows":[],"truncated":false}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/cfb/gh" "$T/cfb/git" "$T/cfb/curl"
touch "$C/flags/merge-conductor-actions"
( export HARNESS="$C"; . "$C/bin/lib/merge-conductor-lib.sh"; mc_init ) >/dev/null 2>&1
CATT="$C/state/merge-conductor/attempts.txt"; CROWS="$C/state/merge-conductor/pr-state.tsv"
CLOG="$C/logs/merge-conductor.log"; CRR="$C/state/merge-conductor/rereview"
CKEY='example-org/demo-os#12'
ctick() { ( cd "$T" && PATH="$T/cfb:$PATH" HARNESS="$C" HARNESS_SECRET=x MC_MERGE_SETTLE=0 MC_REPOS="$T/repos" \
            MC_RR_PATH="$T/cfb:$PATH" MC_MERGE_TREE=0 bash "$C/bin/merge-conductor.sh" >/dev/null 2>"$T/ctick.err" ); }
c_state() { awk -F'\t' -v k="$CKEY" '$1==k {print $2}' "$CROWS" 2>/dev/null; }
c_why()   { awk -F'\t' -v k="$CKEY" '$1==k {print $7}' "$CROWS" 2>/dev/null; }
c_jobs()  { ls "$CRR"/*.json 2>/dev/null | wc -l | tr -d ' '; }
c_reset() { # c_reset <head>
  rm -f "$CROWS" "$CATT" "$T/c-comments.txt" "$T/rb-calls.txt"; touch "$CATT"
  find "$CRR" -maxdepth 1 -type f -delete 2>/dev/null
  scratch_rm "$C/state/merge-conductor/handoff" 2>/dev/null; scratch_rm "$C/state/merge-conductor/stuck" 2>/dev/null
  echo "$H_OLD" > "$REC/reviewed-sha"; printf '%s' "$1" > "$T/prhead"; : > "$CLOG"
}

# ---- C6a: a bound approve on a green head is consumed
c_reset "$H_GRN"; rb 0 review-prs APPROVE approve claude
ctick
grep -q "review-prs already verdicted APPROVE on this exact head" "$T/c-comments.txt" 2>/dev/null && ok \
  || bad "C6a the approval must be rebound with the 'already verdicted' comment: $(cat "$T/c-comments.txt" 2>/dev/null) / $(grep -i 'bound\|spawn' "$CLOG" | tail -3)"
[ "$(c_jobs)" = 0 ] && ok || bad "C6a a consumed verdict must spawn no re-review"
grep -qx "rbverdict $CKEY $H_GRN" "$CATT" && ok || bad "C6a the consume must be recorded as rbverdict: $(cat "$CATT")"
[ "$(c_state)" = WAIT_REVIEW ] && [ "$(head -1 "$REC/reviewed-sha")" = "$H_GRN" ] && ok \
  || bad "C6a the row goes to WAIT_REVIEW with reviewed-sha rebound (got $(c_state), $(head -1 "$REC/reviewed-sha"))"
grep -q "BOUND_VERDICT consumed" "$CLOG" && grep -q "review_skip_unchanged $CKEY@${H_GRN:0:12} lane=merge-conductor by=review-prs/APPROVE" "$CLOG" && ok \
  || bad "C6a the consume must be logged: $(grep -i 'bound\|skip' "$CLOG")"
grep -qx "example-org/demo-os 12 $H_GRN --except-builder" "$T/rb-calls.txt" 2>/dev/null && ok \
  || bad "C6a the conductor must ask with --except-builder: $(cat "$T/rb-calls.txt" 2>/dev/null)"
# ---- C6b: a bound block parks
c_reset "$H_GRN"; rb 0 lead BLOCK block
ctick
[ "$(c_state)" = BLOCKED_HUMAN ] && [ "$(c_why)" = head-not-reapproved ] && ok \
  || bad "C6b a bound block must park head-not-reapproved (got $(c_state) / $(c_why))"
grep -q "lead already verdicted BLOCK on this exact head" "$T/c-comments.txt" 2>/dev/null && ok || bad "C6b the park comment: $(cat "$T/c-comments.txt" 2>/dev/null)"
[ "$(c_jobs)" = 0 ] && ok || bad "C6b a bound block must spawn no re-review"
# ---- C6c: a bound approve on a pending head consumes nothing
c_reset "$H_PND"; rb 0 review-prs APPROVE approve claude
ctick
grep -q "^rbverdict " "$CATT" && bad "C6c a pending head must record no rbverdict" || ok
[ ! -s "$T/c-comments.txt" ] && ok || bad "C6c nothing may be posted on a pending head: $(cat "$T/c-comments.txt")"
grep -q "re-review deferred — CI pending on ${H_PND:0:8}" "$CLOG" && ok || bad "C6c the ordinary CI deferral must stand: $(tail -3 "$CLOG")"
# ---- C6d: no lib in the tree is today's spawn
c_reset "$H_GRN"; rb 0 review-prs APPROVE approve
mv "$C/bin/lib/review-bought.sh" "$T/rb-parked.sh"
ctick
[ "$(c_jobs)" = 1 ] && ! grep -q "^rbverdict " "$CATT" && ok || bad "C6d without the lib the conductor spawns as today (jobs=$(c_jobs)): $(tail -3 "$CLOG")"
mv "$T/rb-parked.sh" "$C/bin/lib/review-bought.sh"
# ---- C6e: a miss is today's spawn too
c_reset "$H_GRN"; rb 2
ctick
[ "$(c_jobs)" = 1 ] && ok || bad "C6e a miss spawns the re-review (jobs=$(c_jobs))"

# ============================================================================
# C7-C8 — bin/blocked-resolver.sh's `# >>> br rereview post`, extracted
# ============================================================================
awk '/^ *# >>> br rereview post/{f=1;next} /^ *# <<< br rereview post/{exit} f' \
  "$DIR/bin/blocked-resolver.sh" > "$T/br-post.sh"
[ -s "$T/br-post.sh" ] && ok || bad "C7 no '# >>> br rereview post' block to drive"
br_drive() { # br_drive <name> <kind> <n>
  local d="$1"
  rm -f "$T/br-$d".*
  mkdir -p "$T/br-rec-$d"
  ( set -uo pipefail
    . "$T/rb-stub.sh"
    mc_rereview() { printf 'MC_RR_REASON=%s\n' "${MC_RR_REASON-<unset>}" >> "$T/br-$d.rr"
      printf 'findings\nVERDICT: APPROVE\n' > "$8"; printf APPROVE; return 0; }
    mc_transition() { printf '%s\n' "$*" >> "$T/br-$d.tr"; }
    mc_slug_of_url() { printf 'acme/widgets'; }
    mc_num_of_url()  { printf '7'; }
    mc_row_field()   { printf '0000111122223333'; }
    br_pr_field()    { printf '%s' "$HEAD"; return 0; }
    br_record()      { local a; for a in "$@"; do printf '%s|' "$a"; done >> "$T/br-$d.rec"; echo >> "$T/br-$d.rec"; }
    say()            { printf '%s\n' "$*" >> "$T/br-$d.say"; }
    rp_post()        { printf '%s\n' "$5" >> "$T/br-$d.note"; }
    br_count()       { printf '%s\n' "$1" >> "$T/br-$d.count"; }
    p=widgets; rkey=WI-1; url=https://github.com/acme/widgets/pull/7; rec="$T/br-rec-$d"
    kind="$2"; n="$3"
    if [ "$kind" = preflight ]; then tag=preflight-rereview ctr=preflight_rereviews lfctr="" nth='the preflight one'
    else tag=no-verdict ctr=rereviews lfctr=lanefails nth="read $((n+1)) of 5"; fi
    bought='after the conductor got no verdict'
    . "$T/br-post.sh"
  ) 2> "$T/br-$d.err"
}
# ---- C7: a lead MERGE on the head is not re-bought
rb 0 lead MERGE approve
br_drive c7 no-verdict 0
[ ! -s "$T/br-c7.rr" ] && ok || bad "C7 mc_rereview must not be called: $(cat "$T/br-c7.rr")"
[ ! -s "$T/br-c7.count" ] && ok || bad "C7 br_count llm must not run: $(cat "$T/br-c7.count")"
grep -q ' WAIT_REVIEW ' "$T/br-c7.tr" 2>/dev/null && ok || bad "C7 APPROVE still moves the row to WAIT_REVIEW: $(cat "$T/br-c7.tr" 2>/dev/null)"
grep -q "Re-review not bought: lead verdicted MERGE on this exact head (${HEAD:0:12})" "$T/br-c7.note" 2>/dev/null && ok \
  || bad "C7 the comment must say the re-review was not bought: $(cat "$T/br-c7.note" 2>/dev/null)"
grep -q '^widgets|WI-1|re-review|reused|.*||$' "$T/br-c7.rec" 2>/dev/null && ok \
  || bad "C7 br_record takes tag reused and bumps no counter: $(cat "$T/br-c7.rec" 2>/dev/null)"
grep -q "review_skip_unchanged — lead verdicted MERGE on ${HEAD:0:8}" "$T/br-c7.say" 2>/dev/null && ok || bad "C7 the resolver log line: $(cat "$T/br-c7.say" 2>/dev/null)"
! grep -q 'unbound variable' "$T/br-c7.err" && ok || bad "C7 the block hit an unset variable: $(cat "$T/br-c7.err")"
# ---- C7b: a block on the head parks, still not re-bought
rb 0 lead BLOCK block
br_drive c7b no-verdict 0
[ ! -s "$T/br-c7b.rr" ] && grep -q 'BLOCKED_HUMAN head-not-reapproved' "$T/br-c7b.tr" 2>/dev/null && ok \
  || bad "C7b a block on record parks head-not-reapproved with no read: rr=$(cat "$T/br-c7b.rr" 2>/dev/null) tr=$(cat "$T/br-c7b.tr" 2>/dev/null)"
grep -q "Re-review not bought: lead verdicted BLOCK on this exact head" "$T/br-c7b.note" 2>/dev/null && ok || bad "C7b the park comment: $(cat "$T/br-c7b.note" 2>/dev/null)"
# ---- C7c: an odd class is a BLOCK, never an approval
rb 0 lead HMM weird
br_drive c7c no-verdict 0
grep -q 'WAIT_REVIEW' "$T/br-c7c.tr" 2>/dev/null && bad "C7c an unknown class must never approve" || ok
# ---- C8: a miss names its own reason
rb 2
br_drive c8 no-verdict 1
grep -qx 'MC_RR_REASON=brnv2' "$T/br-c8.rr" 2>/dev/null && ok || bad "C8 no-verdict read 2 must buy under brnv2: $(cat "$T/br-c8.rr" 2>/dev/null)"
grep -qx 'llm' "$T/br-c8.count" 2>/dev/null && ok || bad "C8 a bought read still counts llm: $(cat "$T/br-c8.count" 2>/dev/null)"
grep -q '|rereviews|$' "$T/br-c8.rec" 2>/dev/null && ok || bad "C8 a bought read still bumps its counter: $(cat "$T/br-c8.rec" 2>/dev/null)"
br_drive c8p preflight 0
grep -qx 'MC_RR_REASON=preflight' "$T/br-c8p.rr" 2>/dev/null && ok || bad "C8 the preflight re-review buys under preflight: $(cat "$T/br-c8p.rr" 2>/dev/null)"

echo "review-dedupe-lanes.bh-3940: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
