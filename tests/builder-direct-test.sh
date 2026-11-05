#!/bin/bash
# tests/builder-direct-test.sh — the builder finishes its own job, and nothing
# says a thing twice (W2-B, the operator 2026-09-14).
#
# WHAT IS ACTUALLY AT RISK HERE, which is what this file drives:
#   * A SECOND COMMENT ON A CLIENT'S TICKET. The builder posts the close-out and
#     the hub's relay, the owning box's staging and the hub's ingest all still
#     see the same build. Three paths, one client, no undo — so the marker that
#     suppresses them is driven from every side, not grepped for.
#   * TWO BUILDERS, ONE TICKET. The queue row is claimed with a conditional
#     write; losing that race must be a clean stand-down, never a second PR.
#   * A LOST CLOSE-OUT. Every new path fails open: a board that refuses the
#     comment, a ledger that cannot be read, a missing lib — each has to leave
#     the RESULT unmarked so the relay carries it exactly as it does today.
#   * THE KILL FLAG. BUILDER_DIRECT=0 has to give back today's behaviour, which
#     only means anything if the same inputs are driven through both settings.
#
# Run from anywhere: tests/builder-direct-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/h/bin/lib" "$T/h/env" "$T/h/flags" "$T/h/logs" "$T/h/state" "$T/h/builds" "$T/fakebin"
cp "$DIR/bin/lib/builder-direct.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/"
cp "$DIR/bin/alert-line.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
export PATH="$T/fakebin:$PATH"

# ══ 1. THE FLAG AND THE MARKER ═══════════════════════════════════════════════
# One definition of "is this on" and one of "has this already been closed out",
# because four scripts read them and a second opinion is a duplicate comment.
. "$T/h/bin/lib/builder-direct.sh"
[ "$(builder_direct_on "$T/h")" = 1 ] \
  && ok || bad "the direct path must default ON"
touch "$T/h/flags/builder-direct-off"
[ "$(builder_direct_on "$T/h")" = 0 ] \
  && ok || bad "flags/builder-direct-off must switch it off"
rm -f "$T/h/flags/builder-direct-off"
[ "$(BUILDER_DIRECT=0 builder_direct_on "$T/h")" = 0 ] \
  && ok || bad "BUILDER_DIRECT=0 in the environment must switch it off"
printf 'BUILDER_DIRECT=0\n' > "$T/h/env/global.env"
[ "$(builder_direct_on "$T/h")" = 0 ] \
  && ok || bad "BUILDER_DIRECT=0 in env/global.env must switch it off"
# The env FILE must not out-rank a caller that set the variable: a medic
# exporting BUILDER_DIRECT=1 for one run is the whole point of the variable.
[ "$(BUILDER_DIRECT=1 builder_direct_on "$T/h")" = 1 ] \
  && ok || bad "the environment must win over env/global.env"
rm -f "$T/h/env/global.env"

bd_closed_out "PR_CREATED https://github.com/o/r/pull/9 | CLOSED-OUT: the builder posted the board close-out on p/K-1 -> review" \
  && ok || bad "a marked RESULT line must read as closed out"
bd_closed_out "PR_CREATED https://github.com/o/r/pull/9 | QA: SKIPPED" \
  && bad "an ordinary RESULT line must NOT read as closed out" || ok
# The note must not break the canonical prefix every discovery in the fleet
# greps for — bin/result-prefix-ok.sh is that grep.
"$DIR/bin/result-prefix-ok.sh" "PR_CREATED https://github.com/o/r/pull/9$(bd_note p/K-1)" \
  && ok || bad "the close-out note must leave the RESULT prefix intact"

# ══ 2. bd_facts — the terminal facts, read from the record ══════════════════
B="$T/h/builds/rec"; mkdir -p "$B"
echo "PR_CREATED https://github.com/o/r/pull/9 | QA: PASS" > "$B/RESULT"
printf 'findings\nTIER: 1\nVERDICT: APPROVE\n' > "$B/review.md"
printf 'ts,box,project,stage,a,b,c,d,in,out,cr,cw,usd\n1,b,p,plan,,,,,1,2,3,4,0.5000\n1,b,p,execute,,,,,1,2,3,4,1.2500\n' > "$B/cost.csv"
F=$(bd_facts "$B" deadbeef)
[ "$(jq -r .pr_url <<<"$F")" = "https://github.com/o/r/pull/9" ] && ok || bad "bd_facts must carry the PR url: $F"
[ "$(jq -r .tier <<<"$F")" = 1 ]        && ok || bad "bd_facts must carry the tier: $F"
[ "$(jq -r .verdict <<<"$F")" = APPROVE ] && ok || bad "bd_facts must carry the verdict: $F"
[ "$(jq -r .sha <<<"$F")" = deadbeef ]  && ok || bad "bd_facts must carry the sha: $F"
[ "$(jq -r '.cost_usd == 1.75' <<<"$F")" = true ] && ok || bad "bd_facts must sum the build's own cost rows: $F"
# AN ABSENT FILE IS AN ABSENT FIELD, never a confident zero: "tier 1" invented
# from a missing review is a tier-1 auto-merge nobody reviewed.
B2="$T/h/builds/bare"; mkdir -p "$B2"; echo "PR_CREATED https://github.com/o/r/pull/4" > "$B2/RESULT"
F2=$(bd_facts "$B2")
# THE SETTLED TIER OUTRANKS review.md. The reviewer writes TIER: 1 before the QA,
# scope, size, repair and trust demoters have run; a caller that knows what those
# produced must be able to say so, or a demoted build reaches the merge queue as
# a tier-1 auto-merge.
[ "$(jq -r .tier <<<"$(bd_facts "$B" deadbeef 2)")" = 2 ] \
  && ok || bad "an explicit settled tier must win over review.md's"
[ "$(jq -r .tier <<<"$(bd_facts "$B" deadbeef junk)")" = 1 ] \
  && ok || bad "a junk tier must fall back to the record, never be passed through"
[ "$(jq -r 'has("tier")' <<<"$F2")" = false ] && ok || bad "no review.md must mean NO tier field: $F2"
[ "$(jq -r 'has("cost_usd")' <<<"$F2")" = false ] && ok || bad "no cost.csv must mean NO cost field: $F2"
bd_facts "$T/h/builds/nope" >/dev/null 2>&1 && bad "a build dir with no RESULT must fail" || ok

# ══ 3. job_result_put — the job's final PATCH, idempotent on replay ══════════
# The curl stub records every request so the test can assert the SHAPE of the
# call, not just that something happened.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""; M=GET
while [ $# -gt 0 ]; do
  case "$1" in --data-binary) BODY="$2"; shift 2 ;; -X) M="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "${REQ_SINK:-}" ] && printf '%s %s %s\n' "$M" "$URL" "$BODY" >> "$REQ_SINK"
case "${CURL_MODE:-ok}" in
  down) exit 7 ;;
  claim409) case "$URL" in
              */api/queue/claim) printf '{"error":"another claimant took this build","refused":true}\n409\n' ;;
              *)                 printf '{}\n200\n' ;;
            esac ;;
  feed_has) case "$URL" in
              */api/artifacts*) printf '{"artifacts":[{"job_id":"J1","artifact_ref":"PR_CREATED https://github.com/o/r/pull/9","box":"builder-1","ticket_id":"T1","updated_at":"2026-09-14T04:00:00Z","detail":"{\"key\":\"TK-9\"}"}]}\n200\n' ;;
              *)                printf '{}\n200\n' ;;
            esac ;;
  feed_empty) case "$URL" in
              */api/artifacts*) printf '{"artifacts":[]}\n200\n' ;;
              *)                printf '{}\n200\n' ;;
            esac ;;
  *) printf '{}\n200\n' ;;
esac
STUB
chmod +x "$T/fakebin/curl"

jc() { ( export HARNESS="$T/h" JOBS_HARNESS="$T/h" HARNESS_SECRET=s JOBS_URL=https://jobs.invalid \
                JOBS_BOX=builder-1 JOBS_RETRIES=0 CURL_MODE="${CURL_MODE:-ok}" REQ_SINK="$T/req.txt"
         . "$T/h/bin/jobs-client.sh"; "$@" ); }

: > "$T/req.txt"
jc job_result_put J1 "$F" && ok || bad "job_result_put must accept a well-formed facts object"
jc job_result_put J1 "$F"
N=$(grep -c '^PATCH https://jobs.invalid/api/jobs/J1 ' "$T/req.txt")
[ "$N" = 2 ] && ok || bad "a replay must PATCH the same row again, not a different one (got $N)"
A=$(grep -m1 '^PATCH https://jobs.invalid/api/jobs/J1 ' "$T/req.txt" | cut -d' ' -f3-)
Bd=$(grep -m2 '^PATCH https://jobs.invalid/api/jobs/J1 ' "$T/req.txt" | tail -1 | cut -d' ' -f3-)
[ "$A" = "$Bd" ] && ok || bad "the replay body must be byte-identical — that is what makes it idempotent"
[ "$(jq -r '.meta | fromjson | .pr_url' <<<"$A")" = "https://github.com/o/r/pull/9" ] \
  && ok || bad "the terminal PATCH must carry the facts: $A"
# LIFECYCLE IS THE TRAP'S, NOT THIS CALL'S: a second writer moving the row to
# `done` here could walk the job into a state the trap then has to move it out
# of, which JOB_TRANSITIONS correctly forbids.
[ "$(jq -r 'has("status")' <<<"$A")" = false ] \
  && ok || bad "job_result_put must not touch status: $A"
jc job_result_put J1 'not json' && bad "junk facts must be refused" || ok
jc job_result_put "" "$F" && bad "an empty job id must be refused" || ok
CURL_MODE=down jc job_result_put J1 "$F" && bad "an unreachable worker must return nonzero (fail-open)" || ok

# The doorbell client (docs/EVENTS.md §5.1). The route is not in the worker yet,
# so the only thing to pin here is that an incomplete row is never sent and an
# outage is silent — a fail-open no-op must stay a no-op.
: > "$T/req.txt"
jc wake_put org/repo pr 9 && ok || bad "wake_put must send a complete row"
grep -q '^POST https://jobs.invalid/api/wakes ' "$T/req.txt" \
  && ok || bad "wake_put must POST /api/wakes: $(cat "$T/req.txt")"
W=$(grep -m1 '^POST https://jobs.invalid/api/wakes ' "$T/req.txt" | cut -d' ' -f3-)
[ "$(jq -r '[.repo,.kind,.key]|join(" ")' <<<"$W")" = "org/repo pr 9" ] \
  && ok || bad "identifiers only, and all three of them: $W"
: > "$T/req.txt"
jc wake_put org/repo pr "" && bad "an incomplete wake must be refused" || ok
[ ! -s "$T/req.txt" ] && ok || bad "an incomplete wake must not reach the worker at all"
CURL_MODE=down jc wake_put org/repo pr 9 && bad "an unreachable worker must return nonzero" || ok

# ══ 4. THE CLAIM LOSES CLEANLY ON 409 ═══════════════════════════════════════
CURL_MODE=claim409 jc queue_claim project-3 "" TK-9; RC=$?
[ "$RC" = 9 ] && ok || bad "a conditional claim that loses must return rc 9, not an error (got $RC)"

# ...and run-build stands down rather than opening a second PR for one ticket.
awk '/^# >>> queue claim/{f=1;next} /^# <<< queue claim/{exit} f' "$RB_ALL" > "$T/claim.sh"
[ -s "$T/claim.sh" ] && ok || bad "could not extract the queue-claim block — markers missing?"
run_claim() { # run_claim <BUILDER_DIRECT_ON> <queue_claim-rc> ; prints "rc|RESULT"
  mkdir -p "$T/h/builds/c"; rm -f "$T/h/builds/c/RESULT"; : > "$T/h/logs/ALERTS.log"
  ( export HARNESS="$T/h" PROJECT=project-3 KEY=TK-9 BUILD="$T/h/builds/c" \
           ALERTS="$T/h/logs/ALERTS.log" JOB_ID=J1 BUILDER_DIRECT_ON="$1" QRC_FAKE="$2"
    bash -c 'set -uo pipefail
      STAMP() { echo TS; }
      RESULT() { echo "$*" > "$BUILD/RESULT"; }
      queue_claim() { return "$QRC_FAKE"; }
      . "$0"
      echo "ran"' "$T/claim.sh" >/dev/null 2>&1; echo -n "$?|" )
  head -1 "$T/h/builds/c/RESULT" 2>/dev/null
}
R=$(run_claim 1 9)
[ "$R" = "3|BUILD_DEFERRED TK-9 claimed by another builder" ] \
  && ok || bad "armed, a lost claim must be a clean BUILD_DEFERRED (got '$R')"
grep -q 'standing down' "$T/h/logs/ALERTS.log" \
  && ok || bad "the stand-down must say so in ALERTS.log"
R=$(run_claim 0 9)
[ "$R" = "0|" ] \
  && ok || bad "KILL FLAG: with the direct path off, a lost claim is logged and built through, exactly as today (got '$R')"
grep -q 'building anyway' "$T/h/logs/ALERTS.log" \
  && ok || bad "the switched-off path must keep today's ALERTS wording"
R=$(run_claim 1 2)
[ "$R" = "0|" ] && ok || bad "rc 2 (no such row) must stay silent and build (got '$R')"

# ══ 5. bin/board-closeout.sh — the comment a client actually reads ═══════════
cat > "$T/h/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$2" in
  prod)         echo "https://app.example" ;;
  board_prefix) cat "$HARNESS/board-prefix" ;;
  repo)         echo "org/repo" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/h/bin/fleet-conf.sh"
printf '/api/board\n' > "$T/h/board-prefix"
printf '#!/bin/bash\necho board-token\n' > "$T/h/bin/internal-token-for.sh"
chmod +x "$T/h/bin/internal-token-for.sh"
# (BH-781) bin/board-closeout.sh's issues lane posts through
# bin/lib/gh-rest.sh, so the stub answers in that library's wire shape.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$GH_SINK"
case "$*" in
  *" -i "*) printf 'HTTP/2.0 201 Created\nx-stub: 1\n\n{"id":1}\n' ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"
# A board stub that records what it was asked to write, and can refuse.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""
while [ $# -gt 0 ]; do case "$1" in -d) BODY="$2"; shift 2 ;; *) shift ;; esac; done
printf '%s\t%s\n' "$URL" "$BODY" >> "$BOARD_SINK"
case "$URL" in
  */comments) [ "${BOARD_MODE:-ok}" = refuse ] && { echo '{"error":"nope"}'; exit 0; }
              echo '{"comment":{"id":"c1"}}' ;;
  */move)     [ "${BOARD_MODE:-ok}" = nomove ] && { echo '{"error":"nope"}'; exit 0; }
              echo "{\"ticket\":{\"status\":\"$(sed -n 's/.*"toStatus":"\([a-z]*\)".*/\1/p' <<<"$BODY")\"}}" ;;
esac
STUB
chmod +x "$T/fakebin/curl"

BB="$T/h/builds/close"; mkdir -p "$BB"
seed_build() { # seed_build <result-line>
  scratch_rm "$BB"; mkdir -p "$BB"
  echo "$1" > "$BB/RESULT"
  printf -- '- add the export button\n- wire the totals\n' > "$BB/what.txt"
  printf '## QA screens\n- /clients — the list, sort by name\n- /clients/[id] — the detail\n\n## Size\n' > "$BB/plan.md"
}
closeout() { ( export HARNESS="$T/h" BOARD_SINK="$T/board.txt" GH_SINK="$T/gh.txt" \
                      BOARD_MODE="${BOARD_MODE:-ok}"
               "$DIR/bin/board-closeout.sh" project-3 T1 TK-9 "$BB" 2>>"$T/closeout.err" ); }

: > "$T/board.txt"; seed_build "PR_CREATED https://github.com/o/r/pull/9"
OUT=$(closeout); RC=$?
[ "$RC" = 0 ] && ok || bad "a PR_CREATED close-out must post (rc $RC; $(tail -2 "$T/closeout.err"))"
[ "$OUT" = "POSTED project-3/TK-9 -> review" ] && ok || bad "the caller needs to be told where it landed (got '$OUT')"
grep -q 'tickets/T1/comments' "$T/board.txt" && ok || bad "it must POST a comment"
# BUILT WORK GOES TO review; `done` MEANS MERGED (docs/BOARD-API-CONTRACT.md) —
# a `done` ticket with an open PR is an invariant alert in board-invariants.sh.
grep -q '"toStatus":"review"' "$T/board.txt" && ok || bad "PR_CREATED must move the ticket to review, never done"
grep -q 'app.example/clients' "$T/board.txt" \
  && ok || bad "the comment must carry DIRECT production links, taken from the plan's own QA screens"
grep -q 'add the export button' "$T/board.txt" \
  && ok || bad "the comment must say what actually shipped"
grep -q 'pull/9' "$T/board.txt" && ok || bad "the comment must link the PR"
grep -q 'Nobody drove the live app by hand' "$T/board.txt" \
  && ok || bad "with no QA pass the comment must say the claim is build-proof, not 'tested'"
# THE COMMENT BEFORE THE MOVE. A ticket that changes state with no explanation
# is the client-facing half of this going wrong.
[ "$(awk -F'\t' 'NR==1{print $1}' "$T/board.txt" | grep -c comments)" = 1 ] \
  && ok || bad "the comment must be the FIRST call, the move the second"

: > "$T/board.txt"; seed_build "PR_MERGED https://github.com/o/r/pull/9"
OUT=$(closeout)
[ "$OUT" = "POSTED project-3/TK-9 -> done" ] && ok || bad "a merged PR closes the ticket (got '$OUT')"
grep -q '"toStatus":"done"' "$T/board.txt" && ok || bad "PR_MERGED must move the ticket to done"

# A QA pass that really passed is the ONLY thing that buys the stronger sentence.
: > "$T/board.txt"; seed_build "PR_CREATED https://github.com/o/r/pull/9"
printf 'drove it\nQA COVERAGE: screens=2 flows=2 shots=4\nQA: PASS\n' > "$BB/qa.md"
closeout >/dev/null
grep -q 'browser pass drove the preview' "$T/board.txt" \
  && ok || bad "a real QA: PASS must be claimed"
grep -q 'Nobody drove the live app by hand' "$T/board.txt" \
  && bad "a QA: PASS must not also say nobody drove it" || ok

# EVERY REFUSAL PATH LEAVES THE CLOSE-OUT TO THE SWEEP.
seed_build "BUILD_DEFERRED TK-9 already building"
closeout >/dev/null 2>&1; [ "$?" = 4 ] && ok || bad "a non-PR RESULT is not this lane's to word"
seed_build "PLAN_BLOCKED needs clarification"
closeout >/dev/null 2>&1; [ "$?" = 4 ] && ok || bad "a PLAN_BLOCKED needs a sentence about WHY — not this lane's"
seed_build "PR_CREATED https://github.com/o/r/pull/9 | CLOSED-OUT: the builder posted the board close-out on project-3/TK-9 -> review"
closeout >/dev/null 2>&1; [ "$?" = 4 ] && ok || bad "an already-marked RESULT must never be posted twice"
seed_build "PR_CREATED https://github.com/o/r/pull/9"
BOARD_MODE=refuse closeout >/dev/null 2>&1
[ "$?" = 1 ] && ok || bad "a board that refuses the comment must report failure, so the caller leaves the RESULT unmarked"
: > "$T/board.txt"
BOARD_MODE=nomove closeout >/dev/null 2>&1
[ "$?" = 0 ] && ok || bad "a comment that landed is a close-out even if the move was refused"
touch "$T/h/flags/builder-direct-off"
closeout >/dev/null 2>&1; [ "$?" = 3 ] && ok || bad "KILL FLAG: switched off, nothing is posted"
rm -f "$T/h/flags/builder-direct-off"

# THE GITHUB-ISSUES LANE (fleet.conf column 4 = "-"): an issue comment, and NO
# status write — the PR body's Closes #n and CLOSE_ISSUE_AFTER_MERGE own that.
printf -- '-\n' > "$T/h/board-prefix"
: > "$T/gh.txt"; : > "$T/board.txt"; seed_build "PR_CREATED https://github.com/o/r/pull/9"
OUT=$(closeout)
[ "$OUT" = "POSTED org/repo#9" ] && ok || bad "the issues lane comments on the issue (got '$OUT')"
grep -q -- '-X POST repos/org/repo/issues/9/comments' "$T/gh.txt" && ok \
  || bad "it must post the comment over REST: $(cat "$T/gh.txt")"
grep -q -- '-F body=@' "$T/gh.txt" && ok \
  || bad "the body must travel by file, never on argv: $(cat "$T/gh.txt")"
grep -qE 'issue close|-X PATCH' "$T/gh.txt" \
  && bad "this lane must NOT close the issue — two closers is two states" || ok
[ ! -s "$T/board.txt" ] && ok || bad "the issues lane must not call a board API"
printf '/api/board\n' > "$T/h/board-prefix"

# ══ 6. run-build's close-out block, driven ══════════════════════════════════
awk '/^# >>> builder-direct close-out/{f=1;next} /^# <<< builder-direct close-out/{exit} f' \
  "$RB_ALL" > "$T/bd.sh"
[ -s "$T/bd.sh" ] && ok || bad "could not extract the builder-direct block — markers missing?"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$CLOSE_SINK"\n[ "${CLOSE_RC:-0}" = 0 ] || exit "$CLOSE_RC"\necho "POSTED project-3/TK-9 -> review"\n' \
  > "$T/h/bin/board-closeout.sh"; chmod +x "$T/h/bin/board-closeout.sh"
run_bd() { # run_bd <BUILDER_EXEC> <BUILDER_DIRECT_ON> [CLOSE_RC]
  rm -rf "$T/h/builds/bd"; mkdir -p "$T/h/builds/bd"
  echo "PR_CREATED https://github.com/o/r/pull/9 | QA: PASS" > "$T/h/builds/bd/RESULT"
  printf 'TIER: 1\nVERDICT: APPROVE\n' > "$T/h/builds/bd/review.md"
  : > "$T/h/builds/bd/pipeline.log"; : > "$T/close.txt"; : > "$T/calls.txt"
  ( export HARNESS="$T/h" PROJECT=project-3 KEY=TK-9 TICKET=T1 BUILD="$T/h/builds/bd" \
           BASE=main SLUG=org/repo JOB_ID=J1 BUILDER_EXEC="$1" BUILDER_DIRECT_ON="$2" \
           CLOSE_RC="${3:-0}" CLOSE_SINK="$T/close.txt" CALL_SINK="$T/calls.txt"
    . "$T/h/bin/lib/builder-direct.sh"
    bash -c 'set -uo pipefail
      STAMP() { echo TS; }
      STAGE_START() { echo 0; }
      STAGE_END() { :; }
      git() { case "$*" in "rev-parse HEAD") echo cafe1234 ;; *log*) printf -- "- did the thing\n" ;; esac; }
      job_result_put()  { printf "result_put %s %s\n" "$1" "$2" >> "$CALL_SINK"; }
      merge_queue_put() { printf "mq_put %s\n" "$*" >> "$CALL_SINK"; }
      wake_put()        { printf "wake %s\n" "$*" >> "$CALL_SINK"; }
      . "'"$T/h/bin/lib/builder-direct.sh"'"
      . "$0"' "$T/bd.sh" >/dev/null 2>&1 )
}

run_bd 1 1
grep -q 'CLOSED-OUT:' "$T/h/builds/bd/RESULT" \
  && ok || bad "a posted close-out must mark the RESULT line: $(head -1 "$T/h/builds/bd/RESULT")"
head -1 "$T/h/builds/bd/RESULT" | grep -q '^PR_CREATED https://github.com/o/r/pull/9 | QA: PASS | CLOSED-OUT:' \
  && ok || bad "the marker is APPENDED — the existing line and its notes must survive intact"
grep -q '^result_put J1 ' "$T/calls.txt" && ok || bad "the terminal facts must go to the ledger: $(cat "$T/calls.txt")"
[ "$(grep -c '^result_put ' "$T/calls.txt")" = 2 ] \
  && ok || bad "the row must be re-written after the marker lands, so the ledger carries the line the file has (got $(grep -c '^result_put ' "$T/calls.txt"))"
grep -q '^mq_put project-3 9 org/repo' "$T/calls.txt" \
  && ok || bad "a tier-1 APPROVE the builder may not merge needs the merge-queue row: $(cat "$T/calls.txt")"
[ "$(grep -c '^wake org/repo pr 9$' "$T/calls.txt")" = 1 ] \
  && ok || bad "the conductor gets exactly ONE doorbell: $(cat "$T/calls.txt")"
grep -q 'project-3 T1 TK-9' "$T/close.txt" && ok || bad "board-closeout must be called with the ticket"
grep -q 'did the thing' "$T/h/builds/bd/what.txt" \
  && ok || bad "the change list must be written next to the record for the comment to use"

# A TIER-2 BUILD NEVER REACHES THE BOX MERGE QUEUE, even though review.md still
# says TIER: 1 — that is exactly what a demoter leaves behind.
run_bd_tier2() {
  rm -rf "$T/h/builds/bd"; mkdir -p "$T/h/builds/bd"
  echo "PR_CREATED https://github.com/o/r/pull/9" > "$T/h/builds/bd/RESULT"
  printf 'TIER: 1\nVERDICT: APPROVE\n' > "$T/h/builds/bd/review.md"
  : > "$T/h/builds/bd/pipeline.log"; : > "$T/close.txt"; : > "$T/calls.txt"
  ( export HARNESS="$T/h" PROJECT=project-3 KEY=TK-9 TICKET=T1 BUILD="$T/h/builds/bd" \
           BASE=main SLUG=org/repo JOB_ID=J1 BUILDER_EXEC=1 BUILDER_DIRECT_ON=1 TIER=2 \
           CLOSE_RC=0 CLOSE_SINK="$T/close.txt" CALL_SINK="$T/calls.txt"
    bash -c 'set -uo pipefail
      STAMP() { echo TS; }
      STAGE_START() { echo 0; }
      STAGE_END() { :; }
      git() { case "$*" in "rev-parse HEAD") echo cafe1234 ;; *log*) printf -- "- did the thing\n" ;; esac; }
      job_result_put()  { printf "result_put %s %s\n" "$1" "$2" >> "$CALL_SINK"; }
      merge_queue_put() { printf "mq_put %s\n" "$*" >> "$CALL_SINK"; }
      wake_put()        { printf "wake %s\n" "$*" >> "$CALL_SINK"; }
      . "'"$T/h/bin/lib/builder-direct.sh"'"
      . "$0"' "$T/bd.sh" >/dev/null 2>&1 )
}
run_bd_tier2
grep -q '^mq_put ' "$T/calls.txt" \
  && bad "a demoted tier-2 PR must NOT be enqueued for auto-merge" || ok
[ "$(grep -m1 '^result_put ' "$T/calls.txt" | cut -d' ' -f3- | jq -r .tier)" = 2 ] \
  && ok || bad "the ledger must carry the SETTLED tier: $(head -1 "$T/calls.txt")"

# A CLOSE-OUT THAT DID NOT POST LEAVES NO MARKER — that is what keeps the
# owning box's sweep responsible for the client's comment.
run_bd 1 1 1
grep -q 'CLOSED-OUT:' "$T/h/builds/bd/RESULT" \
  && bad "a refused close-out must NOT mark the RESULT" || ok
grep -q 'no board close-out from this machine' "$T/h/builds/bd/pipeline.log" \
  && ok || bad "the miss must say so in pipeline.log"
grep -q '^result_put ' "$T/calls.txt" \
  && ok || bad "the terminal facts still go to the ledger even when the board refused"

# KILL FLAG and WATCHERS: byte-for-byte today.
run_bd 1 0
[ "$(cat "$T/h/builds/bd/RESULT")" = "PR_CREATED https://github.com/o/r/pull/9 | QA: PASS" ] \
  && ok || bad "KILL FLAG: switched off, the RESULT must be untouched"
[ ! -s "$T/calls.txt" ] && [ ! -s "$T/close.txt" ] \
  && ok || bad "KILL FLAG: switched off, nothing may be called at all"
run_bd "" 1
[ "$(cat "$T/h/builds/bd/RESULT")" = "PR_CREATED https://github.com/o/r/pull/9 | QA: PASS" ] \
  && ok || bad "a WATCHER build (no BUILDER_EXEC) must be untouched — its own box sweeps it"
[ ! -s "$T/calls.txt" ] && ok || bad "a watcher build must not run the direct path"

# ══ 7. THE HUB'S INGEST IS BOOKKEEPING ON AN ALREADY-TERMINAL RESULT ═════════
mkdir -p "$T/h/state/fly" "$T/h/logs"
printf 'FLY_API_TOKEN_PROJECT_3_OS=tok\n' > "$T/h/env/fly.env"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
# The probe rides through `printf %q`, so the stub matches on the words that
# survive the escaping rather than on the shell line the script composed.
cat > "$T/fakebin/flyctl" <<'SH'
#!/bin/bash
case "$*" in
  *sftp*)       : ;;
  *echo*yes*)   echo yes ;;
  *cat*RESULT*) cat "$RESULT_SRC" ;;
  *)            : ;;
esac
exit 0
SH
chmod +x "$T/fakebin/flyctl"
# BOTH NAMES. The script resolves `fly` first and only falls back to `flyctl`,
# so stubbing one of them lets a real flyctl on the box answer a test.
cp "$T/fakebin/flyctl" "$T/fakebin/fly"
printf '#!/bin/bash\nprintf "ssh %%s\\n" "$*" >> "$SSH_SINK"\nexit 0\n' > "$T/fakebin/ssh"
chmod +x "$T/fakebin/ssh"
cat > "$T/h/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "${1:-}" in --tailnet-ip) echo 10.0.0.9; exit 0 ;; esac
case "${2:-}" in prod) echo https://app.example ;; board_prefix) echo /api/board ;; repo) echo org/repo ;; *) exit 1 ;; esac
SH
chmod +x "$T/h/bin/fleet-conf.sh"

ingest() { # ingest <result-line> <curl-mode>
  rm -rf "$T/h/state/remote-results" "$T/h/builds/fly-"* 2>/dev/null
  mkdir -p "$T/h/state/fly"
  # TEST-CHANGE (BH-1041): a deferred tick leaves the flag and the active-job
  # row behind on purpose, so each case starts from a clean deferral state.
  rm -f "$T/h/state/fly/project-3-TK-9.relay-deferred" "$T/h/logs/ALERTS.log"
  printf '%s\n' "$1" > "$T/result.src"
  jq -nc '{key:"TK-9",ticket_id:"T1"}' > "$T/h/state/fly/project-3-active.json"
  jq -nc '{app:"builder-project-3"}'        > "$T/h/state/fly/project-3.json"
  : > "$T/ssh.txt"
  ( export HARNESS="$T/h" JOBS_HARNESS="$T/h" HARNESS_SECRET=s JOBS_URL=https://jobs.invalid \
           JOBS_BOX=hub JOBS_RETRIES=0 CURL_MODE="$2" REQ_SINK="$T/req2.txt" \
           RESULT_SRC="$T/result.src" SSH_SINK="$T/ssh.txt" PATH="$T/fakebin:$PATH"
    bash "$DIR/bin/fly-results-ingest.sh" project-3 >/dev/null 2>&1 )
}
# Restore the recording curl stub for the ledger read-back.
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
URL="${!#}"
case "${CURL_MODE:-feed_empty}" in
  feed_has)   case "$URL" in */api/artifacts*) printf '{"artifacts":[{"job_id":"J1","artifact_ref":"PR_CREATED https://github.com/o/r/pull/9","box":"builder-1","ticket_id":"T1","updated_at":"t","detail":"{\"key\":\"TK-9\"}"}]}\n200\n' ;; *) printf '{}\n200\n' ;; esac ;;
  down)       exit 7 ;;
  *)          case "$URL" in */api/artifacts*) printf '{"artifacts":[]}\n200\n' ;; *) printf '{}\n200\n' ;; esac ;;
esac
STUB
chmod +x "$T/fakebin/curl"

# (a) the RESULT says the builder already closed out -> no json, no ssh.
ingest "PR_CREATED https://github.com/o/r/pull/9 | CLOSED-OUT: the builder posted the board close-out on project-3/TK-9 -> review" feed_empty
[ ! -e "$T/h/state/remote-results/project-3/TK-9.json" ] \
  && ok || bad "a closed-out result must NOT be parked for a second close-out"
grep -q 'remote-results' "$T/ssh.txt" \
  && bad "a closed-out result must not be pushed over ssh: $(cat "$T/ssh.txt")" || ok
ls "$T/h/builds"/fly-project-3-TK-9-*/RELAYED >/dev/null 2>&1 \
  && ok || bad "custody must still be stamped RELAYED for the close-out checks"
[ ! -e "$T/h/state/fly/project-3-active.json" ] \
  && ok || bad "the hub's active-job state must still be cleared"

# (b) the ledger already carries the result -> same answer, without the marker.
ingest "PR_CREATED https://github.com/o/r/pull/9" feed_has
[ ! -e "$T/h/state/remote-results/project-3/TK-9.json" ] \
  && ok || bad "a result already terminal in the ledger must not be relayed again"

# (c) NOTHING in the ledger and no marker -> today's relay, untouched.
ingest "PR_CREATED https://github.com/o/r/pull/9" feed_empty
grep -q 'remote-results' "$T/ssh.txt" \
  && ok || bad "an undelivered result must still be relayed: $(cat "$T/ssh.txt")"

# (d) AN UNREADABLE LEDGER IS NEITHER "DELIVERED" NOR "ABSENT" — it is HELD.
# TEST-CHANGE (BH-1041): this case asserted the REVERSE, "must fall back to the
# relay". That fallback is the defect: during a worker outage the row is usually
# there, so the relay put a second copy of a finished build on the owning box
# and the client's ticket got a second close-out comment. The result now stays
# on its builder and the */2 sweep re-asks. The half the old case was right
# about — never assume delivery — is pinned by (e) and by §3c of
# tests/remote-result-relay-once.bh-1041-test.sh, where the deferral resolves.
ingest "PR_CREATED https://github.com/o/r/pull/9" down
grep -q 'remote-results' "$T/ssh.txt" \
  && bad "an unreadable ledger must NOT relay: $(cat "$T/ssh.txt")" || ok
[ -f "$T/h/state/fly/project-3-active.json" ] \
  && ok || bad "a deferred ingest must keep the hub's active-job row, or nothing re-asks"
ls -d "$T/h/builds"/fly-project-3-TK-9-* >/dev/null 2>&1 \
  && bad "a deferred ingest must leave no half-made hub build dir" || ok
[ -f "$T/h/state/fly/project-3-TK-9.relay-deferred" ] \
  && ok || bad "the deferral must be recorded so the next tick does not page again"
ingest_again() { # the same builder, the same outage, one tick later
  ( export HARNESS="$T/h" JOBS_HARNESS="$T/h" HARNESS_SECRET=s JOBS_URL=https://jobs.invalid \
           JOBS_BOX=hub JOBS_RETRIES=0 CURL_MODE=down REQ_SINK="$T/req2.txt" \
           RESULT_SRC="$T/result.src" SSH_SINK="$T/ssh.txt" PATH="$T/fakebin:$PATH"
    bash "$DIR/bin/fly-results-ingest.sh" project-3 >/dev/null 2>&1 )
}
ingest_again
[ "$(grep -c 'LEDGER UNREADABLE' "$T/h/logs/ALERTS.log" 2>/dev/null | head -1)" = 1 ] \
  && ok || bad "two down ticks must page ONCE, got $(grep -c 'LEDGER UNREADABLE' "$T/h/logs/ALERTS.log")"

# (e) KILL FLAG: switched off, the marker is ignored and the relay runs.
touch "$T/h/flags/builder-direct-off"
ingest "PR_CREATED https://github.com/o/r/pull/9 | CLOSED-OUT: the builder posted the board close-out on project-3/TK-9 -> review" feed_has
grep -q 'remote-results' "$T/ssh.txt" \
  && ok || bad "KILL FLAG: switched off, the hub relays exactly as today"
rm -f "$T/h/flags/builder-direct-off"

# ══ 8. THE OWNING BOX STAGES IT, AND DOES NOT COMMENT AGAIN ═════════════════
# bin/run-triage.sh's staging marks a closed-out dir COMMENTED. Driven as the
# function it is, because the claim is about a decision and not a string.
awk '/^RR_CLOSED_OUT\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DIR/bin/lib/rt/staging.sh" > "$T/rrco.sh"
[ -s "$T/rrco.sh" ] && ok || bad "could not extract RR_CLOSED_OUT from bin/lib/rt/staging.sh"
mkdir -p "$T/staged"
( . "$T/h/bin/lib/builder-direct.sh"; . "$T/rrco.sh"
  RR_CLOSED_OUT "PR_CREATED https://github.com/o/r/pull/9 | CLOSED-OUT: posted on project-3/TK-9" "$T/staged" )
[ -f "$T/staged/COMMENTED" ] \
  && ok || bad "a staged dir whose builder already commented must be marked COMMENTED"
rm -f "$T/staged/COMMENTED"
( . "$T/h/bin/lib/builder-direct.sh"; . "$T/rrco.sh"
  RR_CLOSED_OUT "PR_CREATED https://github.com/o/r/pull/9" "$T/staged" )
[ ! -f "$T/staged/COMMENTED" ] \
  && ok || bad "an ordinary result must still reach the sweep"
# A box whose lib has not synced yet must behave exactly as it does today.
env -u BASH_FUNC_bd_closed_out%% bash -c '. "$1"; RR_CLOSED_OUT "PR_CREATED x | CLOSED-OUT: y" "$2"' _ "$T/rrco.sh" "$T/staged" 2>/dev/null
[ ! -f "$T/staged/COMMENTED" ] \
  && ok || bad "without the lib the guard must be inert, not guessing"
grep -q 'RR_CLOSED_OUT "\$RRRES" "\$RRDEST"' "$DIR/bin/lib/rt/staging.sh" \
  && ok || bad "the relay-json staging path must apply the guard"
grep -q 'RR_CLOSED_OUT "\$RREF" "\$RDEST"' "$DIR/bin/lib/rt/staging.sh" \
  && ok || bad "the ledger staging path must apply the guard"

echo "builder-direct: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
