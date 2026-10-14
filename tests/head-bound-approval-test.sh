#!/bin/bash
# tests/head-bound-approval-test.sh — SDLC item 1: an approval is about a SHA.
#
# The hole this closes: bin/run-build.sh records `review-head` once, after the
# general review, and then the security, refuter and preview-QA fix rounds all
# commit on top of it. Nothing re-ran the suite, nothing re-reviewed, and the
# tier-1 merge never compared HEAD to the sha that was approved — so a QA-fix
# commit no reviewer had read could merge unattended.
#
# WHY DRIVEN AND NOT GREPPED. `grep -q review-head bin/run-build.sh` passes just
# as happily on a gate that demotes every build, or on one that fails open on a
# real mismatch. What is under test is the control flow: which way each of the
# five shapes of drift goes, and — the property the whole rollout rests on —
# that ABSENCE of a reviewed sha leaves every merge path behaving exactly as it
# did before this shipped.
#
# The blocks are extracted VERBATIM from the shipped scripts by their markers,
# so a regression in the real lines fails here rather than in a paraphrase.
# Run from anywhere: tests/head-bound-approval-test.sh   (exit 0 = all pass)
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
mkdir -p "$T/bin" "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/fakebin" "$T/builds/rec-1"
# Both merge paths below (the hub sweep in 4, the box queue in 5) read PRs
# through bin/lib/merge-conductor-lib.sh -> bin/lib/gh-rest.sh (BH-784), so the
# scratch $HARNESS carries both exactly as a box does. Without gh-rest.sh the
# lib's fail-closed shims answer "unverifiable" to every read, and every gate
# here would be green on a sweep that never read a PR.
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
cp "$DIR/bin/alert-line.sh" "$T/bin/"
mkdir -p "$T/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/bin/lib/mc/"
# The stub `gh` arms below answer `gh api -i -X …` with a REAL HTTP response —
# gh-rest.sh judges the status line, not gh's exit code, so an `echo` of JSON
# would read as "no status line", i.e. UNVERIFIABLE. tests/lib/rest-emit.sh is
# the shared emitter.
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ============================================================================
# 1. bin/run-build.sh — the gate that answers the drift
# ============================================================================
awk '/^# >>> head-bound approval/{f=1;next} /^# <<< head-bound approval/{exit} f' \
  "$RB_ALL" > "$T/gate.sh"
[ -s "$T/gate.sh" ] && ok || bad "could not extract the head-bound block from bin/run-build.sh — markers missing?"
grep -q 'review-head' "$T/gate.sh" && ok || bad "the extracted block never reads review-head — wrong markers?"

# The gate re-runs the repo's suite on the moved head through HARNESS_SUITE_RUN,
# which lives in its own marked block and calls the stage timers. Both come out
# of bin/run-build.sh VERBATIM, the same way the gate itself does — a stub would
# let the real function break while this suite stayed green.
awk '/^# >>> stage timing/{f=1;next} /^# <<< stage timing/{exit} f' \
  "$RB_ALL" > "$T/timing.sh"
[ -s "$T/timing.sh" ] && ok || bad "could not extract the stage-timing block — markers missing?"
awk '/^# >>> harness suite run/{f=1;next} /^# <<< harness suite run/{exit} f' \
  "$RB_ALL" > "$T/suite-run.sh"
[ -s "$T/suite-run.sh" ] && ok || bad "could not extract the harness-suite-run block — markers missing?"

REPO="$T/repo"
setup_repo() { # setup_repo <extra-commits>
  scratch_rm "$REPO"; mkdir -p "$REPO"
  ( cd "$REPO" || exit 1
    git init -q -b main
    git config user.email t@example.com; git config user.name tester
    echo one > a.txt; git add -A; git -c commit.gpgsign=false commit -qm "base"
  )
  rm -rf "$T/build"; mkdir -p "$T/build"
  ( cd "$REPO" && git rev-parse HEAD ) > "$T/build/review-head"
  if [ "${1:-0}" -gt 0 ]; then
    ( cd "$REPO" || exit 1
      echo fix >> a.txt; git add -A; git -c commit.gpgsign=false commit -qm "qa fix round" )
  fi
}

gate() { # gate <cc-verdict: APPROVE|BLOCK|none> [env assignments...]
  local v="$1"; shift
  : > "$T/cc-calls.txt"; : > "$T/cc-prompt.txt"
  ( cd "$REPO" || exit 1
    env CC_VERDICT="$v" BUILD="$T/build" PROJECT=p KEY=K BASE=main BRANCH=b \
        REVIEW_MODEL=review-model TIER=1 QA_NOTE="" CC_SINK="$T/cc-calls.txt" \
        CC_PROMPT="$T/cc-prompt.txt" "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      CC() { printf "%s %s\n" "$1" "$2" >> "$CC_SINK"
             printf "%s" "$5" > "$CC_PROMPT"
             [ "$CC_VERDICT" = none ] || printf "findings\nVERDICT: %s\n" "$CC_VERDICT" > "$BUILD/headbound-review.md"; }
      . "$1"
      . "$2"
      . "$0"
      printf "TIER=%s|NOTE=%s|RH=%s\n" "$TIER" "$QA_NOTE" "$(cat "$BUILD/review-head")"
    ' "$T/gate.sh" "$T/timing.sh" "$T/suite-run.sh" 2>/dev/null )
}

# 1a. no drift: the reviewed head IS the head. Nothing is bought, nothing moves.
setup_repo 0
HEAD0=$(cd "$REPO" && git rev-parse HEAD)
OUT=$(gate APPROVE)
grep -q "TIER=1|NOTE=|RH=$HEAD0" <<<"$OUT" \
  && ok || bad "an unmoved head must change nothing (got: $OUT)"
[ -s "$T/cc-calls.txt" ] \
  && bad "an unmoved head bought a re-review it did not need: $(cat "$T/cc-calls.txt")" || ok

# 1b. drift + a re-review that APPROVES: the approval rebinds to the new head and
#     the build keeps the tier it earned. This is the path that keeps the tier-1
#     lane alive through an ordinary QA fix round.
setup_repo 1
HEAD1=$(cd "$REPO" && git rev-parse HEAD)
OUT=$(gate APPROVE)
grep -q "TIER=1|NOTE=|RH=$HEAD1" <<<"$OUT" \
  && ok || bad "a re-approved head must keep its tier and rebind review-head (got: $OUT)"
grep -q '^review review-model$' "$T/cc-calls.txt" \
  && ok || bad "the re-review did not run on the primary review lane: $(cat "$T/cc-calls.txt")"
grep -q 'HARNESS_EXIT' "$T/build/harness-suite-head.txt" 2>/dev/null \
  && ok || bad "the suite was not re-run on the moved head — the reviewer got no ground truth"

# 1c. drift + a re-review that BLOCKS: tier 2, and RESULT says why.
setup_repo 1
HEAD1=$(cd "$REPO" && git rev-parse HEAD)
OUT=$(gate BLOCK)
grep -q '^TIER=2' <<<"$OUT" && ok || bad "a blocked re-review must demote to tier 2 (got: $OUT)"
grep -q 'HEAD: 1 commit(s) after the reviewed head' <<<"$OUT" \
  && ok || bad "the demotion note must name the drift (got: $OUT)"
grep -q "RH=$HEAD1" <<<"$OUT" \
  && bad "a BLOCKed head was rebound as reviewed anyway (got: $OUT)" || ok

# 1d. a re-review that produced NO verdict file (session died, model outage) is
#     not an approval. Silence is the one answer that must never read as PASS.
setup_repo 1
OUT=$(gate none)
grep -q '^TIER=2' <<<"$OUT" && ok || bad "a re-review with no verdict must demote (got: $OUT)"

# 1e. HEADBOUND_REREVIEW=0: no model call, straight to the demotion. Cheaper,
#     and it still never merges code nobody read.
setup_repo 1
OUT=$(gate APPROVE HEADBOUND_REREVIEW=0)
grep -q '^TIER=2' <<<"$OUT" && ok || bad "with the re-review off, drift must demote (got: $OUT)"
[ -s "$T/cc-calls.txt" ] \
  && bad "HEADBOUND_REREVIEW=0 still bought a review: $(cat "$T/cc-calls.txt")" || ok

# 1f. HEADBOUND_ENFORCE=0 is the warn-only kill switch: the tier stands, and the
#     drift is still stated in RESULT rather than swallowed.
setup_repo 1
OUT=$(gate BLOCK HEADBOUND_ENFORCE=0)
grep -q '^TIER=1' <<<"$OUT" && ok || bad "the kill switch must leave the tier alone (got: $OUT)"
grep -q 'warn only' <<<"$OUT" && ok || bad "a warn-only run must still say so in the note (got: $OUT)"

# 1g. a verdict left behind by an EARLIER resume of this build approved an
#     earlier head. Reusing it would be the checkpoint bug this gate exists to
#     stop, one level up.
setup_repo 1
printf 'stale findings\nVERDICT: APPROVE\n' > "$T/build/headbound-review.md"
OUT=$(gate none HEADBOUND_REREVIEW=0)
grep -q '^TIER=2' <<<"$OUT" \
  && ok || bad "a stale APPROVE from a previous resume was accepted for this head (got: $OUT)"

# 1h. main's own merged work is NOT this build's drift. A 1-2h execute means main
#     moves; once it is merged or rebased in, HEADBOUND_SHA..HEAD sweeps up every
#     commit main gained, and the prompt would hand the reviewer other people's
#     PRs as "the part nobody has adjudicated" — a scope-creep BLOCK on main's
#     code, i.e. a tier-2 demotion on a build that did nothing wrong.
setup_repo 0
( cd "$REPO" || exit 1
  git checkout -q -b sidemain
  echo m1 >> m.txt; git add -A; git -c commit.gpgsign=false commit -qm "main commit 1"
  echo m2 >> m.txt; git add -A; git -c commit.gpgsign=false commit -qm "main commit 2"
  git update-ref refs/remotes/origin/main HEAD
  git checkout -q main
  git -c commit.gpgsign=false merge -q --no-ff --no-edit sidemain
  echo fix >> a.txt; git add -A; git -c commit.gpgsign=false commit -qm "qa fix round" )
OUT=$(gate APPROVE)
grep -q "git log --oneline .*--not origin/main" "$T/cc-prompt.txt" \
  && ok || bad "the re-review prompt does not exclude main's own commits: $(head -c 400 "$T/cc-prompt.txt")"
grep -qE '2 commit\(s\) have landed since' "$T/cc-prompt.txt" \
  && ok || bad "the drift count swept in main's merged commits instead of this build's: $(grep -o '[0-9]* commit(s) have landed' "$T/cc-prompt.txt")"

# 1i. and when the reviewed sha is not on this branch AT ALL — a rebase whose
#     mapping did not resolve — there IS no honest commit range. Say that and
#     hand over the whole diff, rather than describing a gap with a range that
#     walks off into main.
setup_repo 1
echo "0000000000000000000000000000000000000000" > "$T/build/review-head"
OUT=$(gate BLOCK)
grep -q 'NO LONGER ON THIS BRANCH' "$T/cc-prompt.txt" \
  && ok || bad "an unreachable reviewed sha was described with a commit range anyway: $(head -c 400 "$T/cc-prompt.txt")"
grep -q '^TIER=2' <<<"$OUT" \
  && ok || bad "an unreachable reviewed sha must still demote when the re-review blocks (got: $OUT)"

# ============================================================================
# 1j. the pre-PR rebase carries the approval ACROSS itself, by DISTANCE
# ============================================================================
# The security and refuter fix rounds commit BEFORE this rebase runs, so
# review-head is normally an ANCESTOR of HEAD and not HEAD itself. Matching on
# equality alone left the file pointing at a sha the rebase orphaned — and the
# gate above then had no honest range to describe (1i). Both halves are lifted
# verbatim from bin/run-build.sh: the measurement taken before the rebase, and
# the carry taken after it.
awk '/^  # >>> head-bound rebase measure/{f=1;next} /^  # <<< head-bound rebase measure/{exit} f' \
  "$RB_ALL" > "$T/rb-measure.sh"
awk '/^      # >>> head-bound rebase carry/{f=1;next} /^      # <<< head-bound rebase carry/{exit} f' \
  "$RB_ALL" > "$T/rb-carry.sh"
[ -s "$T/rb-measure.sh" ] && [ -s "$T/rb-carry.sh" ] \
  && ok || bad "could not extract the rebase measure/carry blocks from bin/run-build.sh"

carry_repo() { # carry_repo <fix-commits-above-the-reviewed-head>
  scratch_rm "$REPO"; rm -rf "$T/build"; mkdir -p "$REPO" "$T/build"
  ( cd "$REPO" || exit 1
    git init -q -b main
    git config user.email t@example.com; git config user.name tester
    echo one > a.txt; git add -A; git -c commit.gpgsign=false commit -qm base
    git branch -q side
    echo m >> main.txt; git add -A; git -c commit.gpgsign=false commit -qm "main moved"
    git update-ref refs/remotes/origin/main HEAD
    git checkout -q side
    echo r >> b.txt; git add -A; git -c commit.gpgsign=false commit -qm "the reviewed work"
    git rev-parse HEAD > "$T/build/review-head"
    for i in $(seq 1 "$1"); do
      echo "f$i" >> b.txt; git add -A; git -c commit.gpgsign=false commit -qm "fix round $i"
    done )
}
run_carry() {
  ( cd "$REPO" || exit 1
    env BUILD="$T/build" PROJECT=p KEY=K BASE=main \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      PREBASE=$(git rev-parse HEAD)
      . "$1"
      git rebase origin/main >/dev/null 2>&1
      . "$2"
    ' _ "$T/rb-measure.sh" "$T/rb-carry.sh" >/dev/null 2>&1 )
}

# 1j-1. two fix commits above the reviewed head: the carry lands on the rebased
#       copy of the reviewed commit, not on the new head and not on the orphan.
carry_repo 2; run_carry
RH=$(cat "$T/build/review-head")
EXP=$(cd "$REPO" && git rev-parse HEAD~2)
[ "$RH" = "$EXP" ] \
  && ok || bad "the reviewed head was not mapped across the rebase (got $RH, expected $EXP)"
( cd "$REPO" && git merge-base --is-ancestor "$RH" HEAD ) \
  && ok || bad "the carried reviewed head is not even on the branch — the gate has no honest range"

# 1j-2. no fix commits: the reviewed head IS the head, and stays the head.
carry_repo 0; run_carry
RH=$(cat "$T/build/review-head")
[ "$RH" = "$(cd "$REPO" && git rev-parse HEAD)" ] \
  && ok || bad "a rebase with no fix rounds did not carry the approval to the new head (got $RH)"

# 1j-3. no review-head file at all (a build that never reached the general
#       review) — the carry writes nothing rather than inventing a claim.
carry_repo 1; rm -f "$T/build/review-head"; run_carry
[ -f "$T/build/review-head" ] \
  && bad "the carry invented a reviewed head for a build that had none" || ok

# ============================================================================
# 2. the verdict artifact carries the sha the approval is bound to
# ============================================================================
awk '/^# >>> verdict artifact/{f=1;next} /^# <<< verdict artifact/{exit} f' \
  "$RB_ALL" > "$T/verdict.sh"
[ -s "$T/verdict.sh" ] && ok || bad "could not extract the verdict-artifact block from bin/run-build.sh"

verdict_row() { # verdict_row <reviewed-sha-or-empty>
  ( env HB="$1" BUILD="$T/build" TIER=1 QA_NOTE="" PR_URL=https://github.com/o/r/pull/7 \
        JOB_ID=build-p-K-1 SINK="$T/artifact.txt" \
    bash -c '
      set -uo pipefail
      HEADBOUND_SHA="$HB"
      job_artifact_put() { printf "%s %s %s\n" "$1" "$2" "$3" > "$SINK"; }
      . "$0"
    ' "$T/verdict.sh" )
}
mkdir -p "$T/build"; printf 'findings\nTIER: 1\nVERDICT: APPROVE\n' > "$T/build/review.md"
verdict_row "abc123def456"
grep -q '"reviewed_sha":"abc123def456"' "$T/artifact.txt" \
  && ok || bad "the verdict row does not carry the reviewed sha: $(cat "$T/artifact.txt")"
grep -q '"tier":"1"' "$T/artifact.txt" \
  && ok || bad "the verdict row lost a field it already carried: $(cat "$T/artifact.txt")"
verdict_row ""
grep -q 'reviewed_sha' "$T/artifact.txt" \
  && bad "an empty reviewed sha was written as a claim: $(cat "$T/artifact.txt")" || ok

# ============================================================================
# 3. bin/jobs-client.sh — the reviewed sha comes back on the verdict row
# ============================================================================
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/verdict*)
    case "${VERDICT_MODE:-plain}" in
      plain) printf '{"pr":"p","job_id":"j1","verdict":"APPROVE","tier":"1","provenance":"claude","merge_sha":null,"reviewed_sha":"cafe1234"}\n200\n' ;;
      old)   printf '{"pr":"p","job_id":"j1","verdict":"APPROVE","tier":"1","provenance":"claude","merge_sha":null}\n200\n' ;;
    esac ;;
  *) printf '{}\n200\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
client() { # client <verdict-mode>
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box VERDICT_MODE="$1"
    unset JOB_ID JOB_BEAT JOB_PHASE_ID
    # shellcheck source=/dev/null
    . "$T/bin/jobs-client.sh"; job_verdict https://x/pull/1 )
}
OUT=$(client plain)
[ "$(cut -f6 <<<"$OUT")" = "cafe1234" ] \
  && ok || bad "job_verdict did not return the reviewed sha as field 6: $OUT"
[ "$(cut -f1 <<<"$OUT")" = "APPROVE" ] && [ "$(cut -f5 <<<"$OUT")" = "j1" ] \
  && ok || bad "the first five fields moved — bin/merge-sweep.sh reads them positionally: $OUT"
OUT=$(client old)
[ "$(cut -f6 <<<"$OUT")" = "-" ] \
  && ok || bad "a row written before this feature must read as '-' (no claim), got: $OUT"

# 3b. job_verdict_rebind — the mechanical movers (the rebase train, the queue's
#     own rebase) push a NEW head carrying the tree a reviewer already read. If
#     the approval does not move with it, every PR they fix is parked by the
#     sweep forever, which is the starvation class the train exists to kill.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""
P=""; for a in "$@"; do [ "$P" = "--data-binary" ] && BODY="$a"; P="$a"; done
case "$URL" in
  */api/verdict*)
    # The detail is a JSON STRING holding JSON, exactly as the worker stores it.
    if [ "${VERDICT_MODE:-plain}" = old ]; then
      DET=$(jq -nc '{tier:"2",provenance:"claude",record:"rec-1",note:"QA ok"}')
      RSHA=null
    else
      DET=$(jq -nc '{tier:"2",provenance:"claude",record:"rec-1",note:"QA ok",reviewed_sha:"oldhead"}')
      RSHA='"oldhead"'
    fi
    jq -nc --arg d "$DET" --argjson r "$RSHA" \
      '{pr:"p",job_id:"j1",verdict:"APPROVE",tier:"2",provenance:"claude",reviewed_sha:$r,
        artifacts:[{artifact_kind:"pr_url",artifact_ref:"p"},
                   {artifact_kind:"verdict",artifact_ref:"APPROVE",detail:$d}]}'
    echo 200 ;;
  *artifacts*) printf '%s' "$BODY" > "$PUT_SINK"; printf '{"artifact":{}}\n200\n' ;;
  *) printf '{}\n200\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
rebind() { # rebind <verdict-mode> <new-sha>
  : > "$T/put.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box VERDICT_MODE="$1" PUT_SINK="$T/put.txt"
    unset JOB_ID JOB_BEAT JOB_PHASE_ID
    # shellcheck source=/dev/null
    . "$T/bin/jobs-client.sh"; job_verdict_rebind https://x/pull/1 "$2"; echo "rc=$?" )
}
OUT=$(rebind plain newhead)
grep -q 'rc=0' <<<"$OUT" && ok || bad "job_verdict_rebind refused a row that carries a reviewed sha: $OUT"
grep -q 'newhead' "$T/put.txt" \
  && ok || bad "the rebind did not write the new head: $(cat "$T/put.txt")"
grep -q 'oldhead' "$T/put.txt" \
  && bad "the rebind left the stale sha behind: $(cat "$T/put.txt")" || ok
# The artifact upserts on (job_id, artifact_kind), so a put that dropped the
# rest of the detail would silently erase the sweep's tier and provenance inputs.
grep -q 'provenance' "$T/put.txt" && grep -q 'QA ok' "$T/put.txt" \
  && ok || bad "the rebind overwrote the verdict row and lost tier/provenance/note: $(cat "$T/put.txt")"
# It MOVES a claim; it never makes one. A build from before item 1 shipped is
# not gated retroactively by a train run.
OUT=$(rebind old newhead)
grep -q 'rc=2' <<<"$OUT" \
  && ok || bad "a row with no reviewed sha was not left alone: $OUT"
[ -s "$T/put.txt" ] \
  && bad "the rebind INVENTED a head-bound claim on a pre-item-1 row: $(cat "$T/put.txt")" || ok

# ============================================================================
# 4. the hub sweep parks a PR whose head is not the head that was approved
# ============================================================================
cp "$DIR/bin/merge-sweep.sh" "$T/bin/sweep.sh"
mkdir -p "$T/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$T/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
# The sweep's decision reads are REST now (BH-784): ONE `gh api -i -X GET
# repos/o/r/pulls/7` answers state, mergeStateStatus, author and headRefOid
# together, and the diff is the same path under the v3.diff media type — so the
# diff arm has to be matched FIRST. `gh pr merge` is unchanged.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  # bin/lib/gh-budget.sh caches this read; an EMPTY answer leaves a 0-byte cache
  # file and the next run in this tree dies mid-tick without a word.
  *"api rate_limit"*)     echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"pr merge"*)           echo "merged" >> "$MERGE_SINK"; exit 0 ;;
  *v3.diff*)              restpr --diff "+ const x = 1;
" ;;
  *"api -i -X GET repos/o/r/pulls/7"*)
    restpr OPEN "${PR_HEAD:-headsha}" ticket/x main "" MERGEABLE CLEAN operator deadbeefcafe ;;
  *)                      echo "" ;;
esac
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/fleet-conf.sh"; chmod +x "$T/bin/fleet-conf.sh"
# The sweep's own worker stub: SWEEP_SHA is what the ledger says was reviewed.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/verdict*)
    if [ -n "${SWEEP_SHA:-}" ]; then
      printf '{"pr":"p","job_id":"j1","verdict":"APPROVE","tier":"2","provenance":"claude","merge_sha":null,"reviewed_sha":"%s"}\n200\n' "$SWEEP_SHA"
    else
      printf '{"pr":"p","job_id":"j1","verdict":"APPROVE","tier":"2","provenance":"claude","merge_sha":null}\n200\n'
    fi ;;
  */api/ledger*) printf '{"error":"not found"}\n404\n' ;;
  # TEST-CHANGE BH-4153: flag_active now reads automerge-disabled* DB-first; the '{}' 200
  # catch-all is an unreadable row, which a stop switch reads as ON (fail closed). No row = off.
  */api/flags/*) printf '{"error":"not found"}\n404\n' ;;
  *)             printf '{}\n200\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"

setup_record() { # setup_record <reviewed-sha-file-contents-or-empty>
  rm -rf "$T/builds/rec-1"; mkdir -p "$T/builds/rec-1"
  echo "PR_CREATED https://github.com/o/r/pull/7" > "$T/builds/rec-1/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/builds/rec-1/review.md"
  : > "$T/builds/rec-1/pipeline.log"
  [ -n "$1" ] && echo "$1" > "$T/builds/rec-1/reviewed-sha"
  : > "$T/state/merge-sweep-done.txt"; : > "$T/state/headbound-alerted.txt"
  : > "$T/logs/merge-sweep.log"; : > "$T/logs/ALERTS.log"; : > "$T/merges.txt"
  return 0
}
sweep() { # sweep [env assignments...]
  ( export PATH="$T/fakebin:$T/bin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box MERGE_SINK="$T/merges.txt"
    env "$@" bash "$T/bin/sweep.sh" >/dev/null 2>&1 )
}

# 4a. the ledger's reviewed sha IS the head: merges, exactly as before.
setup_record ""; sweep SWEEP_SHA=headsha PR_HEAD=headsha
grep -q merged "$T/merges.txt" \
  && ok || bad "a PR still on its reviewed head did not merge"

# 4b. the head moved after the approval: parked, alerted, never merged.
setup_record ""; sweep SWEEP_SHA=oldsha PR_HEAD=headsha
grep -q merged "$T/merges.txt" \
  && bad "a PR whose head moved past the approval was merged" || ok
grep -q 'is not the reviewed sha' "$T/logs/merge-sweep.log" \
  && ok || bad "the park did not say why: $(cat "$T/logs/merge-sweep.log")"
grep -q 'code no reviewer saw' "$T/logs/ALERTS.log" \
  && ok || bad "a parked head-bound PR did not page anyone: $(cat "$T/logs/ALERTS.log")"

# 4c. no reviewed sha anywhere = no claim = today's behaviour. This is the
#     property that makes the rollout safe: every build recorded before this
#     shipped, and every relayed record without the file, still merges.
setup_record ""; sweep PR_HEAD=headsha
grep -q merged "$T/merges.txt" \
  && ok || bad "a PR with no reviewed sha anywhere was held — the rollout would park the fleet"

# 4d. the build record's reviewed-sha file is the documented fallback, and it is
#     read with the same two answers.
setup_record "headsha"; sweep PR_HEAD=headsha
grep -q merged "$T/merges.txt" \
  && ok || bad "the reviewed-sha fallback refused a PR that is on its reviewed head"
setup_record "oldsha"; sweep PR_HEAD=headsha
grep -q merged "$T/merges.txt" \
  && bad "the reviewed-sha fallback merged a PR whose head moved" || ok

# 4d2. the fallback is reviewed-sha and NOT review-head. review-head is written
#      by the general review, and the OLD pipeline let the security, refuter and
#      QA fix rounds commit past it without moving it — so on a pre-item-1
#      record it is a sha that never meant "this is what merges". Reading it
#      here would park PRs on a claim nobody made.
setup_record ""; echo oldsha > "$T/builds/rec-1/review-head"; sweep PR_HEAD=headsha
grep -q merged "$T/merges.txt" \
  && ok || bad "the sweep parked on review-head, a file the OLD pipeline wrote and never moved"

# 4e. the kill switch: warn, merge, stay honest in the log.
setup_record ""; sweep SWEEP_SHA=oldsha PR_HEAD=headsha HEADBOUND_ENFORCE=0
grep -q merged "$T/merges.txt" \
  && ok || bad "HEADBOUND_ENFORCE=0 still parked the PR"
grep -q 'warn only' "$T/logs/merge-sweep.log" \
  && ok || bad "the warn-only path said nothing: $(cat "$T/logs/merge-sweep.log")"

# 4f. the park is REVERSIBLE, so it is never ledgered. A done-row would mark the
#     PR handled forever and it would never land after a human re-review, after
#     bin/rebase-train.sh rebinds the approval, or after the operator flips the switch —
#     the 10-PR starvation shape, re-created by the gate meant to prevent one.
setup_record ""; sweep SWEEP_SHA=oldsha PR_HEAD=headsha
grep -q 'pull/7' "$T/state/merge-sweep-done.txt" \
  && bad "the head-bound park was ledgered — the PR can never land again: $(cat "$T/state/merge-sweep-done.txt")" || ok
#     and the same record, once the head IS the reviewed sha again (the rebind),
#     merges on the very next tick rather than staying parked.
sweep SWEEP_SHA=headsha PR_HEAD=headsha
grep -q merged "$T/merges.txt" \
  && ok || bad "a PR parked on a head mismatch stayed parked after the rebind"

# 4g. the ALERT is deduped on the HEAD, not fired every tick. Ten minutes of
#     cron over a PR nobody has got to yet must not be ten minutes of pages.
setup_record ""; sweep SWEEP_SHA=oldsha PR_HEAD=headsha
sweep SWEEP_SHA=oldsha PR_HEAD=headsha
[ "$(grep -c 'code no reviewer saw' "$T/logs/ALERTS.log")" = 1 ] \
  && ok || bad "the head-bound park paged twice for one unchanged head: $(cat "$T/logs/ALERTS.log")"
#     a NEW head on the same PR is new information and pages again.
sweep SWEEP_SHA=oldsha PR_HEAD=thirdsha
[ "$(grep -c 'code no reviewer saw' "$T/logs/ALERTS.log")" = 2 ] \
  && ok || bad "a PR whose head moved AGAIN was muted by the dedupe: $(cat "$T/logs/ALERTS.log")"

# ============================================================================
# 5. the per-box merge queue applies the same rule, before its own rebase
# ============================================================================
# The queue hardcodes HARNESS=/root/harness, so the BLOCK is extracted and driven
# rather than the whole script: this test never writes outside its own tmpdir.
MQ="$DIR/bin/merge-queue.sh"
awk '/^# >>> head-bound approval/{f=1;next} /^# <<< head-bound approval/{exit} f' \
  "$MQ" > "$T/mq-gate.sh"
[ -s "$T/mq-gate.sh" ] && ok || bad "could not extract the head-bound block from the merge queue"
grep -q 'hb_blocked()' "$T/mq-gate.sh" \
  && ok || bad "the queue's head-bound check is not a function — the merge train cannot share it"
# mq_pr is the queue's ONE PR read (BH-784: mc_pr_view -> gh_rest -> `gh api -i`)
# and it is defined above the extracted block, so it is lifted verbatim too —
# the drivers below must read a head exactly the way the shipped queue does, not
# through a paraphrase that could pass on a gate the real script cannot feed.
sed -n '/^mq_pr() {/p' "$MQ" > "$T/mq-pr.sh"
[ -s "$T/mq-pr.sh" ] && ok || bad "could not extract the queue's mq_pr read from $MQ"
# mq_park is lifted for the same reason and on the same terms (BH-1366): the
# park a head-bound mismatch performs is one function now, shared with the
# three other sites that set an entry aside, and it is defined above the
# extracted block. Lifted VERBATIM — the drivers below must park exactly the
# way the shipped queue parks, row or file.
awk '/^mq_park\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$MQ" > "$T/mq-park.sh"
[ -s "$T/mq-park.sh" ] && ok || bad "could not extract the queue's mq_park from $MQ"
{ cat "$T/mq-pr.sh" "$T/mq-park.sh" "$T/mq-gate.sh"; echo 'hb_blocked "$NUM" && exit 0'; echo 'echo proceeded > "$REACHED"'; } > "$T/mq-driver.sh"
# The lander skip (a head-bound PR must not buy an agent resolution it will then
# be blocked on) and the train's member loop, driven from the same extraction.
{ cat "$T/mq-pr.sh" "$T/mq-park.sh" "$T/mq-gate.sh"; echo 'hb_lander_blocked "$NUM" "rebase CONFLICTS with main" && exit 0'
  echo 'echo lander-would-run > "$REACHED"'; } > "$T/mq-lander.sh"
awk '/# >>> head-bound train members/{f=1;next} /# <<< head-bound train members/{exit} f' \
  "$MQ" > "$T/mq-train-members.sh"
[ -s "$T/mq-train-members.sh" ] && ok || bad "could not extract the merge train's member loop"
{ cat "$T/mq-pr.sh" "$T/mq-park.sh" "$T/mq-gate.sh"; cat "$T/mq-train-members.sh"; echo 'echo "BATCH=$BATCH" > "$REACHED"'; } > "$T/mq-train.sh"

# The queue asks gh for a head PER PR — one REST read of repos/o/r/pulls/<n>
# (BH-784) that carries the state, the head sha and the head ref together. The
# number comes off the PATH now, not off a bare numeric argv word: HEAD_<num>
# when set, PR_HEAD otherwise.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
N=$(printf '%s' "$*" | sed -nE 's#.*/pulls/([0-9]+).*#\1#p' | head -1)
[ -n "$N" ] || N=7
V="HEAD_$N"; HEADOID="${!V:-${PR_HEAD:-headsha}}"
case "$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *v3.diff*)          restpr --diff ;;
  *"api -i -X GET repos/o/r/pulls/"*)
    restpr OPEN "$HEADOID" "br$N" main "" MERGEABLE CLEAN ;;
  *)                  echo "" ;;
esac
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/git"; chmod +x "$T/fakebin/git"

mq_run() { # mq_run <driver> <ledger-sha-or-empty> <pr-head> [env assignments...]
  local drv="$1" lsha="$2" phead="$3"; shift 3
  mkdir -p "$T/q" "$T/wt"; rm -f "$T/q"/* "$T/reached"
  for _n in ${MQ_ENTRIES:-7}; do : > "$T/q/$_n"; done
  : > "$T/mq.log"
  ( export PATH="$T/fakebin:$T/bin:$PATH" PR_HEAD="$phead"
    env LSHA="$lsha" Q="$T/q" F=7 NUM=7 QUEUED=7 WT="$T/wt" BATCH="" REPO_DIR="$T/repo" \
        PROJECT=p SLUG=o/r LOG="$T/mq.log" HARNESS="$T" REACHED="$T/reached" "$@" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      # mq_pr reads through bin/lib/merge-conductor-lib.sh -> gh-rest.sh, which
      # the shipped queue sources a few lines above the extracted block. The
      # fixture sources the same files from the same place; without them every
      # head read below would be rc 75 and no gate could ever see a mismatch.
      # shellcheck source=/dev/null
      . "$HARNESS/bin/lib/merge-conductor-lib.sh"
      # The train members block now asks the batch-hold gate first (BH-576);
      # this suite is about the HEAD-BOUND gate, so the answer is a defined
      # "not held" rather than an unknown command that happens to be false.
      bh_held() { return 1; }
      job_verdict() { [ -n "$LSHA" ] || return 2
                      printf "APPROVE\t2\tclaude\t-\tj1\t%s" "$LSHA"; }
      . "$0"
    ' "$drv" >/dev/null 2>&1 )
}
mq() { # mq <ledger-sha-or-empty> <pr-head> [env assignments...]
  mq_run "$T/mq-driver.sh" "$@"
}

# 5a. head is the reviewed head: the queue proceeds to its own gates.
mq reviewedsha reviewedsha
[ -f "$T/reached" ] && ok || bad "the queue blocked a PR that is on its reviewed head"
[ -f "$T/q/7.blocked" ] && bad "the queue blocked a matching head" || ok

# 5b. head moved after the approval: the entry is blocked and says why.
mq oldsha newsha
[ -f "$T/reached" ] && bad "the queue landed a PR whose head moved past the approval" || ok
[ -f "$T/q/7.blocked" ] && ok || bad "the queue entry was not moved aside for a human"
grep -q 'is not the reviewed sha' "$T/mq.log" \
  && ok || bad "the queue block did not say why: $(cat "$T/mq.log")"

# 5c. no ledger row: unchanged behaviour, same as everywhere else.
mq "" newsha
[ -f "$T/reached" ] && ok || bad "a PR with no ledger row was blocked — that is not a mismatch, it is silence"

# 5d. the same kill switch name, the same warn-only outcome.
mq oldsha newsha HEADBOUND_ENFORCE=0
[ -f "$T/reached" ] && ok || bad "HEADBOUND_ENFORCE=0 still blocked the queue entry"
grep -q 'warn only' "$T/mq.log" \
  && ok || bad "the queue's warn-only path said nothing: $(cat "$T/mq.log")"

# 5e. THE BUSY PATH. With 2+ entries the queue takes the union merge train and
#     lands its members with cheap gh merges — and bin/tier2-merge-sweep.sh
#     enqueues every approved tier-2 PR in one pass on every box, so 2+ is the
#     normal case, not the edge. A gate that lives only in the serial loop below
#     leaves the hole open on the path that actually merges. The drifted member
#     must never reach the union: not typechecked into the candidate, not landed.
MQ_ENTRIES="7 8" mq_run "$T/mq-train.sh" ignored headsha "QUEUED=7 8" HEAD_7=headsha HEAD_8=drifted LSHA=headsha
grep -q 'BATCH=.*\b7\b' "$T/reached" \
  && ok || bad "the merge train dropped a member that IS on its reviewed head: $(cat "$T/reached" 2>/dev/null)"
grep -q '\b8\b' "$T/reached" \
  && bad "the merge train took a drifted head into the union — the busy path bypasses the gate: $(cat "$T/reached")" || ok
[ -f "$T/q/8.blocked" ] \
  && ok || bad "the train left the drifted entry queued instead of setting it aside for a human"

# 5f. the LANDER writes code with an agent. Running it on a head-bound PR spends
#     a model call to produce a head the very next pass blocks anyway, and the
#     alert that follows blames the conflict rather than the real reason. Block
#     first, and name it.
mq_run "$T/mq-lander.sh" boundsha boundsha
[ -f "$T/reached" ] \
  && bad "the lander ran on a head-bound PR — its resolution would be code no reviewer saw" || ok
grep -q 'lander skipped' "$T/mq.log" \
  && ok || bad "the lander skip did not name its reason: $(cat "$T/mq.log")"
#     with no head-bound claim the lander runs exactly as it always has.
mq_run "$T/mq-lander.sh" "" headsha
[ -f "$T/reached" ] \
  && ok || bad "a PR with no head-bound claim lost its lander attempt"
#     and the kill switch reaches this path too.
mq_run "$T/mq-lander.sh" boundsha boundsha HEADBOUND_ENFORCE=0
[ -f "$T/reached" ] \
  && ok || bad "HEADBOUND_ENFORCE=0 did not restore the lander"

# 5g. a rebase THIS queue performed and typechecked is not unreviewed code: it
#     rebinds, or the queue would block next pass on a head it created itself.
grep -q 'hb_rebind()' "$T/mq-gate.sh" \
  && ok || bad "the queue has no rebind for its own verified rebase — it will block its own output"
grep -q 'hb_rebind' "$MQ" \
  && ok || bad "hb_rebind is defined but never called"
[ "$(grep -c 'hb_rebind' "$MQ")" -ge 2 ] \
  && ok || bad "hb_rebind is defined but never called after the queue's own push"

# ============================================================================
# 6. no secret reaches a log
# ============================================================================
for F in "$T/logs/ALERTS.log" "$T/logs/merge-sweep.log" "$T/mq.log" "$T/logs/jobs-client.log"; do
  [ -f "$F" ] || continue
  grep -q 'test-secret' "$F" && bad "HARNESS_SECRET reached $(basename "$F")" || ok
done

echo "head-bound-approval-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
