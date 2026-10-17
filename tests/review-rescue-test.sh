#!/bin/bash
# tests/review-rescue-test.sh — bin/review-rescue.sh, the lane that re-enters a
# build whose review stopped without a PR.
#
# WHY. On 2026-09-13 thirty-nine pool builds fleet-wide (23 on project-5) sat on
# `REVIEW_BLOCKED test-tamper:` from a scanner that counted a RETITLED test case
# as a deletion. Their branch was pushed, no PR was ever opened, and the ledger
# row said failed. This lane exists to re-enter exactly that, and it declined
# every one of them twice over:
#
#   1. a relayed pool build dir is named pool-<project>-<KEY>-<stamp>, and the
#      parse asked project-of.sh --prefix about the WHOLE name, so every one
#      resolved to "cannot parse project/key" — and then touched .review-rescued,
#      which is the one state from which the dir is never looked at again;
#   2. four of them already carried `VERDICT: APPROVE` from the original run, and
#      the candidate filter skipped any dir with a verdict — they were not
#      waiting for a review, they were waiting for a PR.
#
# So this file drives the script against a REAL throwaway origin+clone (the
# worktree add, the merge-base and the re-scan are all real git) with a fake gh
# and a fake review agent, and pins: the pool parse, the tamper re-scan branch
# (clean -> continue, still-deleted -> stop and alert), PR creation for a branch
# that has none, the reuse of a standing APPROVE, and the per-tick cap.
#
# Run from anywhere: tests/review-rescue-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2' want '$3'"; fi; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

PRURL="https://github.com/example-org/project-5/pull/777"

# ── the fixture harness tree ─────────────────────────────────────────────────
export HARNESS="$T/h"; H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/locks" "$H/builds" "$H/env" "$T/fakebin" "$T/repos"
cp "$DIR/bin/review-rescue.sh" "$DIR/bin/project-of.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/fleet-projects-or-alert.sh" "$DIR/bin/test-tamper-scan.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
mkdir -p "$H/bin/lib" && cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"   # TEST-CHANGE BH-1651: the state read is REST
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
printf 'project-5 example-org/project-5 - - 2 box-ts\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
# BH-2504: the rescue's main-merge push goes through bin/lib/hold-push.sh.
. "$DIR/tests/lib/hold-fixture.sh" && hold_fixture_libs "$DIR" "$H" || exit 1
: > "$H/env/global.env"
export REPOS_ROOT="$T/repos"
# BH-1510.1: this lane's model is a model_routes row (rescue.review); this
# worker-less box carries the resolver beside the lane and its cache of #1507's table.
mkdir -p "$H/bin/lib"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" project-5 project-3

# flock and timeout are GNU/util-linux on the hub and absent on a mac; the lane's
# use of both is incidental to everything asserted here, so they are stubbed
# rather than skipped — a test that only runs on the hub pins nothing.
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in
    -k) shift 2 ;;
    -*) shift ;;
    [0-9]*) shift; break ;;
    *) break ;;
  esac
done
exec "$@"
EOF
chmod +x "$T/fakebin/flock" "$T/fakebin/timeout"

# The fake gh. Logs its argv, and answers the three calls this lane makes.
#   $T/prlist.out  — what `gh pr list --search <KEY>` returns ("" = no open PR)
#   $T/pr-create-rc — 0 opens $PRURL, 1 refuses (the un-rescued retry path)
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr create"*)
    printf '%s\n' "\$*" >> "$T/pr-creates.txt"
    if [ "\$(cat "$T/pr-create-rc" 2>/dev/null || echo 0)" != 0 ]; then
      echo "GraphQL: No commits between main and the head branch" >&2; exit 1
    fi
    echo "$PRURL"; exit 0 ;;
  *"pr list"*"--head"*) cat "$T/prhead.out" 2>/dev/null ;;
  # BH-2504: the main-merge push reads the ticket's thread for a HOLD (none here).
  *"-i -X GET"*"/issues/"*"/comments"*) printf 'HTTP/2 200\r\n\r\n[]' ;;
  *"-i -X GET"*"/issues/"*)   # TEST-CHANGE BH-1651: gh_rest_issue_state, same fixture
    printf 'HTTP/2 %s\r\n\r\n{"state":"%s"}' "\$(cat "$T/issue-state.st" 2>/dev/null || echo 200)" "\$(tr A-Z a-z < "$T/issue-state.out" 2>/dev/null || echo open)" ;;
  *"pr list"*)          cat "$T/prlist.out" 2>/dev/null ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"

# The fake review agent: logs the call and writes the review.md the prompt names.
# (The prompt carries "<build-dir>/review.md" — the same string the real reviewer
# is told to rewrite — so the stub needs no out-of-band knowledge of the dir.)
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1 \$2 \$5" >> "$T/review-calls.txt"
RM=\$(printf '%s' "\${6:-}" | grep -oE '/[^ ]*/review\.md' | head -1)
[ -n "\$RM" ] && printf 'rescued findings\nTIER: 1\nVERDICT: %s\n' "\$(cat "$T/review-verdict" 2>/dev/null || echo APPROVE)" > "\$RM"
[ -n "\${5:-}" ] && : > "\$5"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"

# ── the fixture project: a real bare origin + a real clone ───────────────────
# `git worktree add origin/<branch>` and `git merge-base origin/main HEAD` are
# the two things this lane cannot fake, so neither is faked.
ORIGIN="$T/origin.git"
git init -q --bare "$ORIGIN"
W="$T/work"; mkdir -p "$W/tests"
(
  cd "$W" || exit 1
  git -c init.defaultBranch=main init -q .
  git config user.email t@t; git config user.name t
  cat > tests/thing.test.js <<'EOF'
describe('thing', () => {
  it('adds', () => { expect(add(1,2)).toBe(3) })
})
EOF
  echo "src" > app.js
  git add -A; git commit -qm "init"
  git branch -M main
  git remote add origin "$ORIGIN"; git push -q -u origin main

  # TK-551: the false-block shape — a feature plus an ADDED test. Nothing is
  # deleted, so a re-scan comes back clean and the block was never real.
  git checkout -q -b ticket/TK-551
  echo "feature" >> app.js
  cat >> tests/thing.test.js <<'EOF'
it('multiplies', () => { expect(mul(2,3)).toBe(6) })
EOF
  git add -A; git commit -qm "TK-551: add multiply and its test"
  git push -q -u origin ticket/TK-551

  # TK-552: a genuinely deleted test file — the re-scan must still refuse.
  git checkout -q main
  git checkout -q -b ticket/TK-552
  git rm -q tests/thing.test.js
  echo "more" >> app.js
  git add -A; git commit -qm "TK-552: drop the suite"
  git push -q -u origin ticket/TK-552

  # TK-555: a branch that CONFLICTS with main. It adds conflict.txt, then main
  # adds the same file with different content — which is what a branch pushed days
  # ago and never merged looks like. Only this pair touches that file, so every
  # other fixture branch still merges main cleanly.
  git checkout -q main
  git checkout -q -b ticket/TK-555
  printf 'branch side\n' > conflict.txt
  git add -A; git commit -qm "TK-555: add conflict.txt"
  git push -q -u origin ticket/TK-555

  # TK-553 / TK-554: two more clean branches, for the per-tick cap.
  for N in 553 554; do
    git checkout -q main
    git checkout -q -b "ticket/ts-$N"
    echo "f$N" >> app.js
    printf "it('n%s', () => { expect(n()).toBe(%s) })\n" "$N" "$N" >> tests/thing.test.js
    git add -A; git commit -qm "TK-$N: another"
    git push -q -u origin "ticket/ts-$N"
  done

  # main moves on AFTER every branch is cut, which is the whole point: a rescued
  # branch is always behind main by the time anyone looks at it.
  git checkout -q main
  printf 'main side\n' > conflict.txt
  git add -A; git commit -qm "main: add conflict.txt"
  git push -q origin main
) >/dev/null 2>&1
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git clone -q "$ORIGIN" "$T/repos/project-5"
# Pin the production requirement: the lane must supply git identity on the
# merge commit. GitHub Actions has none (this PR's first CI run, 14 false
# "conflicts with main" fails). Hide the runner's global config so a missing
# -c user.name/email cannot hide behind the hub's identity.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

# ── helpers ──────────────────────────────────────────────────────────────────
# The candidate scan is `find -mmin +90`, so every fixture RESULT must be aged.
# LOCAL time, deliberately: `touch -t` reads its stamp in local time, so a UTC
# stamp on a box west of Greenwich lands in the FUTURE and -mmin never matches.
ago() { date -d "-$1 minutes" +%Y%m%d%H%M.%S 2>/dev/null || date -v-"$1"M +%Y%m%d%H%M.%S; }

reset_h() { scratch_rm "$H/builds"; scratch_rm "$H/logs"; scratch_rm "$H/flags"; mkdir -p "$H/builds" "$H/logs" "$H/flags"
            : > "$T/gh-calls.txt"; : > "$T/pr-creates.txt"; : > "$T/review-calls.txt"
            : > "$T/prlist.out"; : > "$T/prhead.out"; echo 0 > "$T/pr-create-rc"; echo OPEN > "$T/issue-state.out"; }

# mkbuild <dir-name> <age-min> <RESULT first line> [review.md body]
mkbuild() {
  local D="$H/builds/$1"
  mkdir -p "$D"
  printf '%s\n' "$3" > "$D/RESULT"
  printf '# %s — the ticket title from the plan\n\n## Tasks\n' "${1}" > "$D/plan.md"
  [ -n "${4:-}" ] && printf '%s' "$4" > "$D/review.md"
  touch -t "$(ago "$2")" "$D/RESULT"
  echo "$D"
}
run() { bash "$H/bin/review-rescue.sh" >>"$T/run.log" 2>&1; }

TAMPER_RESULT="REVIEW_BLOCKED test-tamper: TAMPER_COUNT: 1 (deleted_files=0 deleted_cases=1 added_skips=0) — no TEST-CHANGE justification; see /root/harness/builds/x/test-tamper.txt"

# ── 1. a pool build dir parses ───────────────────────────────────────────────
# The whole incident in one assertion: pool-project-5-TK-551-… must resolve to
# project-5/TK-551 and must NOT be retired as unparseable.
reset_h
D=$(mkbuild pool-project-5-TK-551-202609131444 200 "$TAMPER_RESULT")
run
grep -q 'cannot parse project/key' "$H/logs/review-rescue.log" 2>/dev/null \
  && bad "a pool build dir was refused as unparseable" || ok
grep -q 'project=project-5 key=TK-551' "$H/logs/review-rescue.log" 2>/dev/null && ok \
  || bad "pool dir did not parse to project-5/TK-551 (log: $(cat "$H/logs/review-rescue.log" 2>/dev/null))"
[ -f "$D/.review-rescued" ] && ok || bad "a rescued pool build must be marked done"

# ── 2. tamper block + clean re-scan + no PR -> a PR is opened ────────────────
reset_h
D=$(mkbuild pool-project-5-TK-551-202609131444 200 "$TAMPER_RESULT")
run
grep -q -- '--head ticket/TK-551' "$T/pr-creates.txt" && ok \
  || bad "no PR was created for the branch (creates: $(cat "$T/pr-creates.txt"))"
eq "RESULT becomes PR_CREATED with the real URL" \
   "$(head -1 "$D/RESULT")" "PR_CREATED $PRURL"
grep -q '^RESCUED:' "$D/RESULT" && ok || bad "RESULT must record that this was a rescue"
[ -s "$D/test-tamper-rescan.txt" ] && ok || bad "the re-scan report must be saved next to the build"
grep -q 'TAMPER_COUNT: 0' "$D/test-tamper-rescan.txt" 2>/dev/null && ok \
  || bad "the re-scan should have come back clean: $(head -1 "$D/test-tamper-rescan.txt" 2>/dev/null)"
[ -s "$T/review-calls.txt" ] && ok || bad "a build with no verdict must still get its review"

# ── 3. tamper block + a standing APPROVE -> reuse it, do not re-review ───────
reset_h
D=$(mkbuild pool-project-5-TK-551-202609131444 200 "$TAMPER_RESULT" \
    'findings from the original round
TIER: 2
VERDICT: APPROVE
')
run
[ -s "$T/review-calls.txt" ] && bad "a standing APPROVE must not be re-reviewed" || ok
eq "the standing verdict ships as PR_CREATED" "$(head -1 "$D/RESULT")" "PR_CREATED $PRURL"
grep -qx 'TIER: 2' "$D/RESULT" && ok || bad "the original TIER must survive: $(cat "$D/RESULT")"
grep -q -- '--head ticket/TK-551' "$T/pr-creates.txt" && ok || bad "the PR must still be opened"
grep -q 'rescued review = APPROVE' "$H/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "the APPROVE alert must fire for a reused verdict"

# ── 4. the re-scan still finds a real deletion -> stop, alert, no PR ─────────
reset_h
D=$(mkbuild pool-project-5-TK-552-202609131444 200 "$TAMPER_RESULT")
run
eq "RESULT is left exactly as the gate wrote it" "$(head -1 "$D/RESULT")" "$TAMPER_RESULT"
[ -f "$D/.review-rescued" ] && ok || bad "a genuinely-tampered build must be retired for a human"
[ -s "$T/pr-creates.txt" ] && bad "no PR may be opened for a build that really deleted a test" || ok
[ -s "$T/review-calls.txt" ] && bad "no review may be spent on a build that really deleted a test" || ok
eq "exactly one ALERTS line" \
   "$(grep -c 'pool-project-5-TK-552' "$H/logs/ALERTS.log" 2>/dev/null)" "1"
grep -q 'still blocked after re-scan' "$H/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "the alert must say the re-scan still blocks (got: $(cat "$H/logs/ALERTS.log" 2>/dev/null))"

# ── 5. RESCUE_PER_TICK bounds the tick ──────────────────────────────────────
reset_h
mkbuild pool-project-5-TK-551-202609131440 300 "$TAMPER_RESULT" >/dev/null
mkbuild pool-project-5-TK-553-202609131441 250 "$TAMPER_RESULT" >/dev/null
mkbuild pool-project-5-TK-554-202609131442 200 "$TAMPER_RESULT" >/dev/null
RESCUE_PER_TICK=2 run
eq "exactly RESCUE_PER_TICK candidates are processed in one tick" \
   "$(grep -c 'rescue attempt 1' "$H/logs/review-rescue.log" 2>/dev/null)" "2"
# Oldest first: the 300-minute-old dir must be one of the two.
grep -q 'pool-project-5-TK-551-202609131440: rescue attempt' "$H/logs/review-rescue.log" 2>/dev/null && ok \
  || bad "the oldest candidate must be taken first"
# And the third is still waiting, untouched.
[ -f "$H/builds/pool-project-5-TK-554-202609131442/.review-rescued" ] \
  && bad "the third candidate must be left for the next tick" || ok

# ── 6. a PR that cannot be opened leaves the dir for the next tick ───────────
reset_h
D=$(mkbuild pool-project-5-TK-551-202609131444 200 "$TAMPER_RESULT")
echo 1 > "$T/pr-create-rc"
run
[ -f "$D/.review-rescued" ] && bad "a failed PR open must NOT retire the build" || ok
eq "RESULT is untouched when no PR could be opened" "$(head -1 "$D/RESULT")" "$TAMPER_RESULT"
eq "the failed attempt is still counted" "$(cat "$D/.rescue-attempts" 2>/dev/null)" "1"
grep -q 'could not open a PR' "$H/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "a PR that cannot be opened must alert (got: $(cat "$H/logs/ALERTS.log" 2>/dev/null))"

# ── 7. an ordinary orphan WITH a verdict is still skipped ───────────────────
# The candidate widening is for test-tamper blocks only: a died-mid-review
# orphan that DID reach a verdict was already acted on, and re-entering it would
# re-review every settled build in the fleet.
reset_h
D=$(mkbuild pool-project-5-TK-551-202609131444 200 \
    "REVIEW_BLOCKED review: the reviewer refused" \
    'findings
TIER: 1
VERDICT: BLOCK
')
run
[ -f "$D/.review-rescued" ] && bad "a settled non-tamper orphan must not be re-entered" || ok
[ -s "$T/review-calls.txt" ] && bad "a settled non-tamper orphan must not be re-reviewed" || ok

# ── 8. no leftover worktrees ────────────────────────────────────────────────
# Every exit path removes its throwaway worktree; a leak is how a box runs out
# of disk a week later.
eq "no rescue worktree is left behind" \
   "$(git -C "$T/repos/project-5" worktree list 2>/dev/null | grep -c rescue-)" "0"

# ── 8. a closed ticket is nothing to rescue ──────────────────────────────────
# The oldest candidates on the hub were three-week-old dirs whose tickets had
# long been closed by other means. Opening a PR for those, or spending a review
# on them, is waste — and a stale PR on a closed ticket confuses the merge lanes.
reset_h
echo CLOSED > "$T/issue-state.out"
D=$(mkbuild pool-project-5-TK-551-202609131444 200 "$TAMPER_RESULT")
run
[ -f "$D/.review-rescued" ] && ok || bad "a closed ticket's build must be retired"
[ -s "$T/pr-creates.txt" ] && bad "no PR may be opened for a closed ticket" || ok
[ -s "$T/review-calls.txt" ] && bad "no review may be spent on a closed ticket" || ok
grep -q 'is closed' "$H/logs/review-rescue.log" 2>/dev/null && ok || bad "the log must say the ticket is closed"
eq "RESULT is left as it was" "$(head -1 "$D/RESULT")" "$TAMPER_RESULT"
grep -q -- '-i -X GET repos/example-org/project-5/issues/551' "$T/gh-calls.txt" && ok || bad "8: the ticket state must be read over REST"
grep -qE 'issue (view|list)' "$T/gh-calls.txt" && bad "8: no GraphQL issue read may remain" || ok

# ── 8b. an unanswered state read (403) is not a closed ticket (BH-1651) ─────
reset_h
echo CLOSED > "$T/issue-state.out"; echo 403 > "$T/issue-state.st"
D=$(mkbuild pool-project-5-TK-551-202609131444 200 "$TAMPER_RESULT")
run
rm -f "$T/issue-state.st"
grep -q 'is closed' "$H/logs/review-rescue.log" 2>/dev/null && bad "8b: a 403 must never retire the ticket as closed" || ok

# ── 9. RESCUE_ONLY=<project> restricts a run to that project's dirs ──────────
reset_h
D1=$(mkbuild pool-project-3-TK-131-202609020038 300 "$TAMPER_RESULT")
D2=$(mkbuild pool-project-5-TK-551-202609131444 200 "$TAMPER_RESULT")
RESCUE_ONLY=project-5 run
[ -f "$D2/.review-rescued" ] && ok || bad "RESCUE_ONLY=project-5 must process the project-5 dir"
[ -f "$D1/.review-rescued" ] && bad "RESCUE_ONLY=project-5 must leave other projects' dirs alone" || ok

# ── 10. a board project's key number is not a GitHub issue ──────────────────
# project-4's TK-791 is a board ticket; GitHub's #791 in that repo is an unrelated
# (merged) PR. The closed-ticket guard must not read it.
reset_h
printf 'project-5 example-org/project-5 - - 2 box-ts\nproject-3 example-org/project-3 https://os.project-3.example /api/feature-board 3 box-om\n' > "$H/fleet.conf"
echo CLOSED > "$T/issue-state.out"
D=$(mkbuild pool-project-3-TK-131-202609020038 200 "$TAMPER_RESULT")
run
grep -q 'is closed' "$H/logs/review-rescue.log" 2>/dev/null && bad "a board project's ticket must not be judged by gh issue view" || ok
grep -q 'project=project-3 key=TK-131' "$H/logs/review-rescue.log" 2>/dev/null && ok || bad "the board project's dir must still be parsed and attempted"
printf 'project-5 example-org/project-5 - - 2 box-ts\n' > "$H/fleet.conf"

# ── 11. a clean branch gets NO main merge before the PR is opened ─────────────
# BH-7042 changed this premise. A clean merge of main makes a new head that
# loses its verdict and restarts CI, and the merge queue already tests every PR
# on current main. So the lane asks bin/lib/main-merge-need.sh first: a branch
# that is clean against main opens its PR on the pushed head as it stands, and
# the log says the merge was skipped. Section 12 (a conflict) is unchanged.
# TK-554: section 5 leaves it unrescued, so no earlier section merged main into it.
reset_h
( cd "$DIR" && scratch_install_closure bin/lib/main-merge-need.sh "$H" ) >/dev/null || bad "11: could not install bin/lib/main-merge-need.sh"
B554=$(git -C "$T/repos/project-5" rev-parse "origin/ticket/TK-554" 2>/dev/null)
D=$(mkbuild pool-project-5-TK-554-202609131442 200 "$TAMPER_RESULT")
run
[ -s "$T/pr-creates.txt" ] && ok || bad "a pushed branch with no PR must still get one"
git -C "$T/repos/project-5" fetch -q origin 2>/dev/null
git -C "$T/repos/project-5" merge-base --is-ancestor origin/main "origin/ticket/TK-554" 2>/dev/null \
  && bad "11: origin/main was merged into a branch that is clean against main" || ok
eq "11: the branch head did not move" "$(git -C "$T/repos/project-5" rev-parse "origin/ticket/TK-554" 2>/dev/null)" "$B554"
grep -q 'main merge skipped: clean against main' "$H/logs/review-rescue.log" 2>/dev/null && ok \
  || bad "11: the log must say the main merge was skipped (log: $(tail -3 "$H/logs/review-rescue.log" 2>/dev/null))"
[ -f "$D/.conflicts-with-main" ] && bad "a clean branch must not leave a conflict marker" || ok

# ── 12. a branch that conflicts with main gets NO PR ────────────────────────
# Resolving a conflict is the resolver lane's job, not this one's. This lane stops
# short: no PR, no review spent, the candidate left exactly where the resolver
# finds it, and a log line that names the condition.
reset_h
D=$(mkbuild pool-project-5-TK-555-202609131500 200 "$TAMPER_RESULT")
cat > "$T/prlist.out" <<'EOF'
EOF
run
[ -s "$T/pr-creates.txt" ] && bad "no PR may be opened for a branch that conflicts with main" || ok
[ -s "$T/review-calls.txt" ] && bad "no review may be bought for a diff that cannot land" || ok
grep -q 'conflicts with main' "$H/logs/review-rescue.log" 2>/dev/null \
  && ok || bad "the log must name the conflict (log: $(cat "$H/logs/review-rescue.log" 2>/dev/null))"
[ -f "$D/.conflicts-with-main" ] && ok || bad "the candidate must be marked as conflicting, for the resolver to find"
[ -f "$D/.review-rescued" ] && bad "a conflicted candidate must NOT be retired — the resolver still has it" || ok
eq "no rescue worktree survives a conflict" \
   "$(git -C "$T/repos/project-5" worktree list 2>/dev/null | grep -c rescue-)" "0"

# ── 13. the tick holds NO global lock: candidates run in parallel ────────────
# One locks/review-rescue.lock for the whole tick meant every rescue in the fleet
# queued behind one 40-minute Fable review (the operator, 2026-09-13: never serialize).
grep -qE '^[^#]*flock[^#]*review-rescue\.lock|^[^#]*review-rescue\.lock' "$DIR/bin/review-rescue.sh" \
  && bad "the global review-rescue lock is back — every rescue would queue behind one review" || ok
grep -qE 'locks/build-key-\$PROJECT-\$KEY.lock' "$DIR/bin/review-rescue.sh" \
  && ok || bad "a rescue must take the SAME per-key lock a live build takes, or it can race one"
grep -q 'rescue_one "$C" ) &' "$DIR/bin/review-rescue.sh" \
  && ok || bad "candidates must run in their own background subshells"

# ── 14. env/global.env is loaded BEFORE the auth libs are sourced ───────────
# bin/lib/gh-app-auth.sh and bin/lib/gh-repo-token.sh snapshot "the token this
# shell started with" AT SOURCE TIME, and this lane runs from cron/hub.cron with
# no GH_TOKEN in the crontab env. While `set -a; . env/global.env` sat at the
# BOTTOM of the file that snapshot was empty, so the PAT rung of both helpers
# was nothing at all: after bin/ensure-box-gh-app-default.sh logs the hub's
# keyring out, a candidate on a repo the App cannot mint for (a board repo the
# App is not installed on) has no token left to fall back to and is left
# un-rescued with an invisible-repo alert. The stub lib below is the snapshot:
# it records what GH_TOKEN was at the moment the lane sourced it.
reset_h
printf 'GH_TOKEN=pat_from_global_env_fixture\n' > "$H/env/global.env"
mkdir -p "$H/bin/lib"
cat > "$H/bin/lib/gh-app-auth.sh" <<EOF
printf '%s\n' "\${GH_TOKEN:-unset}" > "$T/lib-saw-token.txt"
EOF
rm -f "$T/lib-saw-token.txt"
env -u GH_TOKEN bash "$H/bin/review-rescue.sh" >>"$T/run.log" 2>&1
eq "the auth lib is sourced with global.env's PAT already in the environment" \
   "$(cat "$T/lib-saw-token.txt" 2>/dev/null)" "pat_from_global_env_fixture"
rm -f "$H/bin/lib/gh-app-auth.sh"; : > "$H/env/global.env"

# ── 15. a record bin/blocked-resolver.sh has already superseded is not a candidate
# Since BH-1047 the resolver's 90-minute fast path adjudicates a contract-first
# tamper block on the SAME record this lane scans on the same cron minute. When
# it rules, it closes the PR, enqueues a fresh build and stamps the record
# `.blocked-resolver-superseded`. This lane must read that stamp: rescuing a
# superseded record opens a second PR on the old branch and buys a second
# review for one ticket.
reset_h
D=$(mkbuild pool-project-5-TK-551-202609131444 200 "$TAMPER_RESULT")
: > "$D/.blocked-resolver-superseded"
run
[ -s "$T/pr-creates.txt" ] && bad "no PR may be opened on a branch the resolver has superseded" || ok
[ -s "$T/review-calls.txt" ] && bad "no review may be bought for a superseded record" || ok
[ -f "$D/.review-rescued" ] && bad "a superseded record is the resolver's, not this lane's to retire" || ok

# ── 16. a rescued BLOCK says what really happens next, and is claimed (BH-5125)
# 2026-10-07 04:34:50Z: the BLOCK arm logged "#5067 goes to
# bin/blocked-resolver.sh for an agent fix round" and no round ran. The resolver
# offers a plain REVIEW_BLOCKED record as rescue-giving-up (a fresh rebuild) and
# only once its RESULT is 90 minutes old. The line has to say that, and the
# hand-off is claimed so the resolver's sweep can page if it never acts.
# R3 first: this tree carries no bin/lib/handoff-watch.sh, which is a box whose
# sync has not landed it.
reset_h
echo BLOCK > "$T/review-verdict"
D=$(mkbuild pool-project-5-TK-553-202609131441 200 "$TAMPER_RESULT")
run; RRC=$?
grep -q 'rescued review = BLOCK' "$H/logs/review-rescue.log" 2>/dev/null && ok \
  || bad "R3: the BLOCK arm must run without the hand-off lib (log: $(tail -3 "$H/logs/review-rescue.log" 2>/dev/null))"
eq "R3: the lane exits 0 without the hand-off lib" "$RRC" "0"
[ -d "$H/state/blocked-resolver/handoffs" ] && bad "R3: no hand-off lib, no claim" || ok
reset_h
echo BLOCK > "$T/review-verdict"
( cd "$DIR" && scratch_install_closure bin/lib/handoff-watch.sh "$H" ) >/dev/null || bad "R1: could not install bin/lib/handoff-watch.sh"
D=$(mkbuild pool-project-5-TK-553-202609131441 200 "$TAMPER_RESULT")
NB=$(( $(stat -c %Y "$D/RESULT") + 5400 ))
AT=$(date -u -d "@$NB" +%H:%MZ)
run
grep -q 'rescued review = BLOCK' "$H/logs/review-rescue.log" 2>/dev/null && ok \
  || bad "R1: the rescue never reached its BLOCK arm (log: $(tail -3 "$H/logs/review-rescue.log" 2>/dev/null))"
grep -q 'for an agent fix round' "$H/logs/review-rescue.log" 2>/dev/null \
  && bad "R1: the BLOCK line still promises an agent fix round" || ok
grep -q "offers it as rescue-giving-up (a fresh rebuild) from $AT" "$H/logs/review-rescue.log" 2>/dev/null && ok \
  || bad "R1: the BLOCK line must name rescue-giving-up from $AT: $(grep 'rescued review' "$H/logs/review-rescue.log" 2>/dev/null)"
CLM="$H/state/blocked-resolver/handoffs/claims/project-5-TK-553"
eq "R2: the claim's not_before is the RESULT mtime + 5400" "$(cut -f2 "$CLM" 2>/dev/null)" "$NB"
eq "R2: the claim is review-rescue's" "$(cut -f6 "$CLM" 2>/dev/null)" "review-rescue"
rm -f "$T/review-verdict" "$H/bin/lib/handoff-watch.sh"

echo "review-rescue-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
