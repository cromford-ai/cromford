#!/bin/bash
# tests/verdict-at-review.bh-858-test.sh — THE JUDGEMENT IS RECORDED WHERE IT IS
# MADE, AND A PROVISIONAL ROW IS INVISIBLE TO THE MERGE LANES.
#
# THE DEFECT (BH-858, 2026-09-18). bin/run-build.sh had ONE verdict write and it
# sat behind `[ -n "$PR_URL" ]`, five hundred lines after the review settled. A
# build whose `gh pr create` died on the App installation's GraphQL cap wrote
# `PR_CREATE_FAILED` and no verdict at all — a reviewer had read the diff and
# answered, and the answer was thrown away. Fifteen records fleet-wide in one day.
#
# WHAT THIS SUITE PINS, driving bin/run-build.sh's OWN marked blocks and the real
# client functions (no restated logic anywhere):
#   §1  `# >>> verdict at review` writes the row with NO PR_URL: settled:false,
#       the tier, the provenance, and reviewed_sha bound to review-head (omitted
#       when there is none). A put that fails is logged and the block still
#       exits 0 — the build never dies for a ledger write.
#   §2  `# >>> verdict artifact` is now the UPDATE: settled:true plus every field
#       it already carried, and still nothing at all without a PR_URL.
#   §3  the readers: job_verdict answers rc 2 for a provisional row and rc 0 for
#       settled / legacy / unparseable; job_verdict_state and job_for_record.
#   §4  mc_job_running stays ARMED on a provisional row (it must not disarm the
#       double-review guard in the middle of the build that wrote the row).
#   §5  the reproduction, end to end: a stubbed `gh` that fails every create rung
#       leaves ONE verdict row (settled:false, bound to the reviewed head) and a
#       RESULT line reading PR_CREATE_FAILED.
#
# Run from anywhere: bash tests/verdict-at-review.bh-858-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" 2>/dev/null || { T=$(mktemp -d) && trap 'rm -rf "$T"' EXIT; }
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
. "$DIR/tests/lib/hold-gate-fixture.sh" || exit 1  # BH-6091: the pr-open HOLD gate for a pipeline slice
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
# ONE clock read for the whole file (bin/test-determinism-lint.sh): nothing below
# compares times, it only keeps fixture directory names unique.
NOW=$(date -u +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to drive these blocks"; exit 1; }
# A real credential in the runner's environment must never reach a fixture.
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR JOB_ID JOB_PHASE_ID

RB="$RB_ALL"
[ -r "$RB" ] || { echo "FAIL: bin/run-build.sh is missing"; exit 1; }
marked() { awk -v s="$1" -v e="$2" 'index($0,s){f=1} f{print} f && index($0,e){exit}' "$3"; }

# ═════════════════════════════════════════════════════════════════════════════
# §1 — the provisional write, at the moment the tier settles
# ═════════════════════════════════════════════════════════════════════════════
EARLY="$T/early.sh"
marked '# >>> verdict at review' '# <<< verdict at review' "$RB" > "$EARLY"
[ -s "$EARLY" ] \
  && ok || bad "§1: bin/run-build.sh carries no '# >>> verdict at review' block — the judgement is still written only after the PR exists"

# Drive the block exactly as the pipeline does, with the ledger call and the two
# provenance helpers stubbed. The sink records the three arguments verbatim, so
# every assertion below is about what the block WROTE, never about its source.
early() { # early <case> [env assignments via caller] -> B is the build dir, S the sink
  # A distinct directory per case, so nothing here ever deletes a tree: only
  # the sink file is cleared, and tests/lib/scratch.sh owns $T's removal.
  B="$T/b-$1-$NOW"; S="$T/sink-$1-$NOW"
  rm -f "$S"; mkdir -p "$B"
  return 0
}
run_early() { # run_early <put-rc> -> the block's true exit code
  ( export BUILD="$B" SINK="$S" JOB_ID="${JOB_ID_V-build-x}" TIER="${TIER_V:-1}" \
           PROJECT=cromford KEY=BH-858 PUTRC="$1"
    bash -c '
      STAMP(){ echo "2026-09-18 12:00:00Z"; }
      job_artifact_put(){ printf "%s\t%s\t%s\n" "$1" "$2" "$3" >> "$SINK"; return "$PUTRC"; }
      rp_out_is_claude(){ [ ! -f "${1}.cheap" ]; }
      rp_out_prov(){ echo fallback-runner; }
      . '"$EARLY"'' )
  return $?
}

early plain
printf 'findings\nTIER: 1\nVERDICT: APPROVE\n' > "$B/review.md"
echo abc123 > "$B/review-head"
run_early 0; RC=$?
[ "$RC" = 0 ] && ok || bad "§1: the block must exit 0, got $RC"
[ "$(wc -l < "$S")" = 1 ] && ok || bad "§1: exactly one ledger write, got $(cat "$S" 2>/dev/null)"
cut -f1,2 "$S" | grep -qx "$(printf 'verdict\tAPPROVE')" \
  && ok || bad "§1: the row must be 'verdict APPROVE', got: $(cut -f1,2 "$S")"
D=$(cut -f3 "$S")
[ "$(jq -r '.settled' <<<"$D")" = false ] \
  && ok || bad "§1: the early row must carry settled:false, got: $D"
[ "$(jq -r '.tier' <<<"$D")" = 1 ] && ok || bad "§1: the row must carry the settled tier, got: $D"
[ "$(jq -r '.reviewed_sha' <<<"$D")" = abc123 ] \
  && ok || bad "§1: reviewed_sha must be bound to review-head, got: $D"
[ "$(jq -r '.provenance' <<<"$D")" = claude ] \
  && ok || bad "§1: an all-Claude review is provenance claude, got: $D"
[ "$(jq -r '.record' <<<"$D")" = "$(basename "$B")" ] \
  && ok || bad "§1: the row must name the build record, got: $D"
grep -q 'recorded provisionally' "$B/pipeline.log" \
  && ok || bad "§1: pipeline.log must say the row was recorded provisionally, got: $(cat "$B/pipeline.log" 2>/dev/null)"
grep -q 'abc123' "$B/pipeline.log" \
  && ok || bad "§1: the log line must name the reviewed sha, got: $(cat "$B/pipeline.log" 2>/dev/null)"

# No review-head: the key is OMITTED, never written as "" — a blank sha reads as
# a claim about the head, and every reader downstream fails open on absence.
early nosha
printf 'findings\nVERDICT: APPROVE\n' > "$B/review.md"
run_early 0
D=$(cut -f3 "$S")
[ "$(jq -r 'has("reviewed_sha")' <<<"$D")" = false ] \
  && ok || bad "§1: an empty review-head must OMIT reviewed_sha, got: $D"
grep -q 'reviewed sha none' "$B/pipeline.log" \
  && ok || bad "§1: the log must say the row carries no sha, got: $(cat "$B/pipeline.log" 2>/dev/null)"

# The LAST line of review.md is the word. A review that quotes APPROVE in its
# findings and ends BLOCK is a BLOCK.
early block
printf 'the other lens said VERDICT: APPROVE\nTIER: 2\nVERDICT: BLOCK\n' > "$B/review.md"
echo def456 > "$B/review-head"
TIER_V=2 run_early 0
[ "$(cut -f2 "$S")" = BLOCK ] \
  && ok || bad "§1: the word is the LAST verdict line, got: $(cut -f2 "$S")"

# A cheap review lane demotes the PROVENANCE here too, or a tier-1 APPROVE that
# no Claude lane authored could auto-merge off this box.
early prov
printf 'findings\nVERDICT: APPROVE\n' > "$B/review.md"
: > "$B/review-run.txt.runner"; : > "$B/review-run.txt.cheap"
run_early 0
[ "$(jq -r '.provenance' <<<"$(cut -f3 "$S")")" = fallback-runner \
  ] && ok || bad "§1: a non-Claude review lane must demote the provenance, got: $(cut -f3 "$S")"

# A put that FAILS is logged and the build carries on: the settle write is the
# only copy, and that fact has to be on the record.
early putfail
printf 'findings\nVERDICT: APPROVE\n' > "$B/review.md"
run_early 1; RC=$?
[ "$RC" = 0 ] && ok || bad "§1: a failed put must not fail the block, got rc $RC"
grep -q 'was not written' "$B/pipeline.log" \
  && ok || bad "§1: a failed put must be named in pipeline.log, got: $(cat "$B/pipeline.log" 2>/dev/null)"

# No JOB_ID (the worker was down at job_open): byte-identical to before BH-858.
early nojob
printf 'findings\nVERDICT: APPROVE\n' > "$B/review.md"
JOB_ID_V=""; run_early 0; unset JOB_ID_V
[ ! -f "$S" ] && ok || bad "§1: with no JOB_ID nothing may be written, got: $(cat "$S")"

# ═════════════════════════════════════════════════════════════════════════════
# §2 — the late block is the UPDATE
# ═════════════════════════════════════════════════════════════════════════════
LATE="$T/late.sh"
marked '# >>> verdict artifact' '# <<< verdict artifact' "$RB" > "$LATE"
[ -s "$LATE" ] && ok || bad "§2: the '# >>> verdict artifact' block is missing"

run_late() { # run_late <pr-url>
  ( export BUILD="$B" SINK="$S" JOB_ID=build-x TIER=1 PROJECT=cromford KEY=BH-858 \
           PR_URL="$1" HEADBOUND_SHA=abc123 HB_OUTCOME=reapproved SCOPE_VERDICT=in-scope \
           KIND_D=bug REPAIRS=0
    bash -c '
      STAMP(){ echo "2026-09-18 12:00:00Z"; }
      job_artifact_put(){ printf "%s\t%s\t%s\n" "$1" "$2" "$3" >> "$SINK"; return 0; }
      rp_out_is_claude(){ return 0; }
      rp_out_prov(){ echo fallback-runner; }
      . '"$LATE"'' )
}
early late
printf 'findings\nTIER: 1\nVERDICT: APPROVE\n' > "$B/review.md"
run_late "https://github.com/example-org/cromford/pull/900"
D=$(cut -f3 "$S")
[ "$(jq -r '.settled' <<<"$D")" = true ] \
  && ok || bad "§2: the settle write must carry settled:true, got: $D"
for F in tier reviewed_sha headbound scope kind repairs note repair_rounds scope_counts kind_repro; do
  [ "$(jq -r "has(\"$F\")" <<<"$D")" = true ] \
    && ok || bad "§2: the settle write must keep the field '$F' it wrote before BH-858, got: $D"
done
[ "$(jq -r '.headbound' <<<"$D")" = reapproved ] \
  && ok || bad "§2: the settle write carries the head-bound answer, got: $D"

early lateno
printf 'findings\nVERDICT: APPROVE\n' > "$B/review.md"
run_late ""
[ ! -f "$S" ] \
  && ok || bad "§2: with no PR_URL the settle write must stay silent — a row claiming settled while the create failed would be a lie. Got: $(cat "$S")"

# ═════════════════════════════════════════════════════════════════════════════
# §3 — the readers understand `settled`
# ═════════════════════════════════════════════════════════════════════════════
mkdir -p "$T/fakebin" "$T/h/bin"
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/jobs-client.sh"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
# The stub worker: one fixture file per route, and EVERY request is recorded, so
# "exactly one feed call for two lookups" is an assertion about traffic and not
# about an implementation detail.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2 ;; --data-binary) BODY="$2"; shift 2 ;; *) shift ;; esac
done
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_SINK"
[ "${WORKER_DOWN:-0}" = 1 ] && exit 7
case "$URL" in
  */api/verdict*)   F="$FIX/verdict" ;;
  */api/artifacts*) F="$FIX/feed" ;;
  */artifacts)      F="$FIX/jobartifacts" ;;
  *)                F="" ;;
esac
if [ -n "$F" ] && [ -f "$F" ]; then printf '%s\n200\n' "$(cat "$F")"; exit 0; fi
printf '{}\n404\n'
STUB
chmod +x "$T/fakebin/curl"

FIX="$T/fix"; mkdir -p "$FIX"
client() { # client <shell snippet> -> runs it with the real jobs-client loaded
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box FIX="$FIX" JOBS_RETRIES=0 \
           REQ_SINK="${REQ_SINK:-$T/req.txt}" WORKER_DOWN="${WORKER_DOWN:-0}"
    unset JOB_ID JOB_PHASE_ID
    # shellcheck source=/dev/null
    . "$T/h/bin/jobs-client.sh"; eval "$1" )
}
PR=https://github.com/example-org/cromford/pull/900

# (a) job_verdict: a PROVISIONAL row is rc 2 — "the ledger has nothing to say" —
#     which every caller already handles by scraping its own build record.
printf '%s' '{"verdict":"APPROVE","tier":"1","provenance":"claude","job_id":"build-x","reviewed_sha":"abc123","artifacts":[{"artifact_kind":"verdict","detail":"{\"settled\":false,\"tier\":\"1\"}"}]}' > "$FIX/verdict"
client "job_verdict '$PR' >/dev/null"; RC=$?
[ "$RC" = 2 ] && ok || bad "§3: job_verdict must answer rc 2 for a provisional row (got $RC) — a merge lane must not act on a tier the demoters have not judged"

printf '%s' '{"verdict":"APPROVE","tier":"1","provenance":"claude","job_id":"build-x","reviewed_sha":"abc123","artifacts":[{"artifact_kind":"verdict","detail":"{\"settled\":true,\"tier\":\"1\"}"}]}' > "$FIX/verdict"
OUT=$(client "job_verdict '$PR'"); RC=$?
{ [ "$RC" = 0 ] && [ "$(cut -f1 <<<"$OUT")" = APPROVE ]; } \
  && ok || bad "§3: job_verdict must answer rc 0 with the TSV for a settled row, got rc $RC '$OUT'"

# Legacy rows — no `.artifacts` at all, and an unparseable detail — read as
# SETTLED. That is what makes this change additive: nothing already in the
# ledger changes meaning.
printf '%s' '{"verdict":"APPROVE","tier":"2","provenance":"claude","job_id":"build-x"}' > "$FIX/verdict"
client "job_verdict '$PR' >/dev/null"; RC=$?
[ "$RC" = 0 ] && ok || bad "§3: a legacy row with no artifacts must stay rc 0, got $RC"
printf '%s' '{"verdict":"APPROVE","tier":"2","job_id":"build-x","artifacts":[{"artifact_kind":"verdict","detail":"not json at all"}]}' > "$FIX/verdict"
client "job_verdict '$PR' >/dev/null"; RC=$?
[ "$RC" = 0 ] && ok || bad "§3: an unparseable detail must read as settled (rc 0), got $RC"
# Only the JSON boolean false is provisional. The STRING "false" is not.
printf '%s' '{"verdict":"APPROVE","tier":"2","job_id":"build-x","artifacts":[{"artifact_kind":"verdict","detail":"{\"settled\":\"false\"}"}]}' > "$FIX/verdict"
client "job_verdict '$PR' >/dev/null"; RC=$?
[ "$RC" = 0 ] && ok || bad "§3: a settled:\"false\" STRING is not the boolean and must read as settled, got $RC"

# (b) job_verdict_state — keyed on the JOB, because a PR_CREATE_FAILED build
#     wrote no pr_url artifact and the pr-keyed read cannot find it.
printf '%s' '{"artifacts":[{"artifact_kind":"result","artifact_ref":"ok"},{"artifact_kind":"verdict","artifact_ref":"APPROVE","detail":"{\"settled\":false,\"reviewed_sha\":\"abc123\"}"}]}' > "$FIX/jobartifacts"
OUT=$(client "job_verdict_state build-x"); RC=$?
{ [ "$RC" = 0 ] && [ "$OUT" = "$(printf 'provisional\tabc123')" ]; } \
  && ok || bad "§3: job_verdict_state must print 'provisional<TAB>abc123', got rc $RC '$OUT'"
printf '%s' '{"artifacts":[{"artifact_kind":"verdict","artifact_ref":"APPROVE","detail":"{\"settled\":true}"}]}' > "$FIX/jobartifacts"
OUT=$(client "job_verdict_state build-x"); RC=$?
{ [ "$RC" = 0 ] && [ "$OUT" = "$(printf 'settled\t-')" ]; } \
  && ok || bad "§3: a settled row with no sha must print 'settled<TAB>-', got rc $RC '$OUT'"
printf '%s' '{"artifacts":[{"artifact_kind":"result","artifact_ref":"ok"}]}' > "$FIX/jobartifacts"
client "job_verdict_state build-x >/dev/null"; RC=$?
[ "$RC" = 2 ] && ok || bad "§3: a job with no verdict artifact is rc 2, got $RC"
WORKER_DOWN=1 client "job_verdict_state build-x >/dev/null"; RC=$?
[ "$RC" = 1 ] && ok || bad "§3: an outage is rc 1, never 'no verdict' (D11), got $RC"

# (c) job_for_record — the record→job map, from the result feed's build_dir.
printf '%s' '{"artifacts":[
  {"job_id":"build-project-4-1","artifact_ref":"ok","box":"pool-1","ticket_id":"TK-1","updated_at":"u","detail":"{\"build_dir\":\"project-4-TK-1-1\",\"terminal\":\"PR_CREATE_FAILED\"}"},
  {"job_id":"build-project-4-2","artifact_ref":"ok","box":"pool-2","ticket_id":"TK-2","updated_at":"u","detail":"{\"build_dir\":\"project-4-TK-2-1\"}"}]}' > "$FIX/feed"
REQ_SINK="$T/req-jfr.txt"; : > "$REQ_SINK"
OUT=$(client 'job_for_record project-4 pool-project-4-TK-1-1; echo; job_for_record project-4 project-4-TK-1-1'; )
[ "$OUT" = "$(printf 'build-project-4-1\nbuild-project-4-1')" ] \
  && ok || bad "§3: both spellings of the record (with and without the hub's pool- prefix) must resolve to the same job, got '$OUT'"
[ "$(grep -c '/api/artifacts' "$REQ_SINK")" = 1 ] \
  && ok || bad "§3: two lookups in one process must cost ONE feed request, got $(grep -c '/api/artifacts' "$REQ_SINK")"
client 'job_for_record project-4 project-4-NOPE-9 >/dev/null'; RC=$?
[ "$RC" = 2 ] && ok || bad "§3: a dir the feed does not name is rc 2, got $RC"
REQ_SINK="$T/req-down.txt"; : > "$REQ_SINK"
OUT=$(WORKER_DOWN=1 client 'job_for_record project-4 project-4-TK-1-1 >/dev/null; echo "rc=$?"; job_for_record project-4 project-4-TK-1-1 >/dev/null; echo "rc=$?"')
[ "$OUT" = "$(printf 'rc=1\nrc=1')" ] \
  && ok || bad "§3: an outage is rc 1 and is NEVER cached — the next call must ask again. Got '$OUT'"
[ "$(grep -c '/api/artifacts' "$T/req-down.txt")" = 2 ] \
  && ok || bad "§3: an outage must leave the cache empty (two calls, two requests), got $(grep -c '/api/artifacts' "$T/req-down.txt")"
REQ_SINK="$T/req.txt"

# ═════════════════════════════════════════════════════════════════════════════
# §4 — mc_job_running stays armed on a provisional row
# ═════════════════════════════════════════════════════════════════════════════
# THE HAZARD: without this the conductor's tick sees a verdict on a PR whose
# build is still running, disarms the guard, and buys a second Fable read of a
# head the build's own reviewer has just finished with.
mcrun() { # mcrun <verdict fixture body> -> mc_job_running's true exit code
  printf '%s' "$1" > "$FIX/verdict"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box FIX="$FIX" REQ_SINK="$T/req.txt" \
           MC_JOB_RUNNING_MAX_AGE_MIN=600
    unset JOB_ID
    # shellcheck source=/dev/null
    . "$T/h/bin/jobs-client.sh"
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
    mc_job_running "$PR" >/dev/null 2>&1 )
  return $?
}
# Derived from the file's ONE clock read: mc_job_running compares updated_at
# against MC_JOB_RUNNING_MAX_AGE_MIN, so the fixture has to be recent.
NOW_ISO=$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$NOW" '+%Y-%m-%dT%H:%M:%SZ')
RUNNING='"job":{"status":"running","stage":"qa","updated_at":"'"$NOW_ISO"'"},"job_id":"build-x"'
mcrun "{\"verdict\":\"APPROVE\",$RUNNING,\"artifacts\":[{\"artifact_kind\":\"verdict\",\"detail\":\"{\\\"settled\\\":false}\"}]}"; RC=$?
[ "$RC" = 0 ] \
  && ok || bad "§4: a RUNNING job whose row is PROVISIONAL must keep the guard armed (rc 0 = wait), got $RC"
mcrun "{\"verdict\":\"APPROVE\",$RUNNING,\"artifacts\":[{\"artifact_kind\":\"verdict\",\"detail\":\"{\\\"settled\\\":true}\"}]}"; RC=$?
[ "$RC" = 1 ] \
  && ok || bad "§4: a SETTLED verdict means the review this guard waits for is finished (rc 1), got $RC"
mcrun "{\"verdict\":\"APPROVE\",$RUNNING}"; RC=$?
[ "$RC" = 1 ] \
  && ok || bad "§4: a legacy row with no artifacts must disarm exactly as it did before BH-858 (rc 1), got $RC"

# ═════════════════════════════════════════════════════════════════════════════
# §5 — THE REPRODUCTION, THROUGH THE PRODUCTION ENTRY POINT
# ═════════════════════════════════════════════════════════════════════════════
# run-build.sh's own four blocks, in pipeline order, with a `gh` that fails every
# create rung. Before BH-858 this wrote no verdict row at all.
mkdir -p "$T/ghbin"
cat > "$T/ghbin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CASE/gh-calls.log"
case "$1 $2" in
  "pr create") printf 'GraphQL: API rate limit already exceeded for installation ID 161623167.\n' >&2; exit 1 ;;
  "pr list")   printf 'GraphQL: API rate limit already exceeded for installation ID 161623167.\n' >&2; exit 1 ;;
  "api -i")    printf 'HTTP/2.0 403 Forbidden\r\nContent-Type: application/json\r\n\r\n{"message":"API rate limit exceeded."}\n'; exit 0 ;;
esac
exit 1
STUB
chmod +x "$T/ghbin/gh"

CASE="$T/case-e2e-$NOW"; mkdir -p "$CASE"
: > "$CASE/gh-calls.log"
HH="$T/h5"; mkdir -p "$HH/bin/lib" "$HH/flags" "$HH/logs"
cp "$DIR/bin/lib/gh-pr-create.sh" "$DIR/bin/lib/env-path.sh" "$HH/bin/lib/" 2>/dev/null
BLK="$CASE/blk.sh"
{ marked '# >>> verdict at review'    '# <<< verdict at review'    "$RB"
  marked '# >>> result pr url ratchet' '# <<< result pr url ratchet' "$RB"
  marked '# >>> pr create call'        '# <<< pr create call'        "$RB"
  marked '# >>> verdict artifact'      '# <<< verdict artifact'      "$RB"; } > "$BLK"
hold_gate_prepend "$RB" "$BLK"   # BH-6091: the real gate, a no-HOLD ticket read
BUILDDIR="$CASE/b"; mkdir -p "$BUILDDIR"
printf 'findings\nTIER: 1\nVERDICT: APPROVE\n' > "$BUILDDIR/review.md"
echo deadbee > "$BUILDDIR/review-head"
( cd "$BUILDDIR" \
  && git init -q . \
  && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "the subject line" \
  && git remote add origin "https://github.com/example-org/cromford.git" ) >/dev/null 2>&1
SINK5="$CASE/sink"
( cd "$BUILDDIR" && PATH="$T/ghbin:$PATH" CASE="$CASE" HARNESS="$HH" BUILD="$BUILDDIR" \
    PROJECT=cromford KEY=BH-858 JOB_ID=build-x TIER=1 SINK="$SINK5" \
    BRANCH=ticket/bh-858 BASE=main BASE_MAIN=main ALERTS="$CASE/ALERTS.log" \
    bash -c '
      STAMP(){ echo "2026-09-18 12:00:00Z"; }
      PR_BODY_FOR(){ echo body; }
      EVIDENCE_SECTION=
      GH_LIVE(){ :; }
      job_artifact_put(){ printf "%s\t%s\t%s\n" "$1" "$2" "$3" >> "$SINK"; return 0; }
      rp_out_is_claude(){ return 0; }
      rp_out_prov(){ echo fallback-runner; }
      HEADBOUND_SHA=$(cat "$BUILD/review-head")
      . '"$BLK"'; RESULT "PR_CREATED $PR_URL"' ) >"$CASE/out.txt" 2>&1

[ -s "$SINK5" ] \
  && ok || bad "§5 (the reproduction): every create rung failed and the ledger got NOTHING — the reviewer's judgement was thrown away. Sink: $(cat "$SINK5" 2>/dev/null); out: $(tail -5 "$CASE/out.txt" 2>/dev/null)"
[ "$(grep -c '^verdict' "$SINK5" 2>/dev/null)" = 1 ] \
  && ok || bad "§5: exactly ONE verdict row — the late block must not write a second one without a PR. Got: $(cat "$SINK5" 2>/dev/null)"
D5=$(grep '^verdict' "$SINK5" 2>/dev/null | head -1 | cut -f3)
[ "$(jq -r '.settled' <<<"$D5" 2>/dev/null)" = false ] \
  && ok || bad "§5: the surviving row must still be PROVISIONAL (the pipeline never settled), got: $D5"
[ "$(jq -r '.reviewed_sha' <<<"$D5" 2>/dev/null)" = deadbee ] \
  && ok || bad "§5: the row must be bound to the head the review ran on, got: $D5"
head -1 "$BUILDDIR/RESULT" 2>/dev/null | grep -q '^PR_CREATE_FAILED' \
  && ok || bad "§5: the RESULT line must still read PR_CREATE_FAILED, got: $(head -1 "$BUILDDIR/RESULT" 2>/dev/null)"

echo "verdict-at-review.bh-858-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
