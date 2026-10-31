#!/bin/bash
# tests/br-rungs-test.sh — THE LADDER, DRIVEN END TO END on a real local git.
# Sections 8 and 8f of the old tests/blocked-resolver-test.sh, moved here
# verbatim by BH-1196 and named for the rungs slice of the bin/lib/br/ split.
#
# WHY THESE TWO ARE ONE SUITE. 8 drives the order of the rungs — mechanical, then
# the agent fix round ON THE EXISTING BRANCH, then the rebuild and only after the
# fix round failed — and 8f drives the edge that decides whether the order can be
# trusted at all: a SETUP failure (no clone, no lease, a machine that died) is not
# a failed fix round, so it must not spend a rung. Both run on the same real git
# fixture, tests/lib/fixture-harness.sh's fx_br_ladder_git.
#
# Sections carried (original numbering, from tests/blocked-resolver-test.sh):
#   8.  the ladder, driven end to end
#   8f. a setup failure is not a failed fix round
# Run from anywhere: tests/br-rungs-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The whole fixture — scratch tree, br modules, sibling libs, the stubbed PATH
# and the RUN/ROW/ROWST/STATEJSON/SPENT helpers — is tests/lib/fixture-harness.sh
# (BH-1196). What is installed and why is documented there.
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
# The scripts this suite drives. The copy stays HERE, in the suite's own text,
# so bin/test-impact.sh still selects this suite when one of them changes.
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
fx_br_harness "$DIR" "$T" || exit 1
# BH-1510.1: the resolver's models are model_routes rows; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes

# ============================================================================
# 8. THE LADDER, DRIVEN END TO END (2026-09-15).
#
#    24 hours of the live log: 121 rebuild-fresh outcomes, ZERO fix rounds, one
#    ABANDONED. A rebuild is plan + execute + review — the most expensive thing
#    this lane can buy — and it was the DEFAULT answer to a rebase conflict and
#    to red CI, which are the two cheapest things in the harness to actually fix.
#    So the order is the claim under test, and it is driven rather than read:
#    rung 1 mechanical, rung 2 the agent fix round ON THE EXISTING BRANCH, rung 3
#    the rebuild and only after rung 2 has failed.
#
#    THE GIT IS REAL AND LOCAL. A bare repo stands in for the remote, the fix
#    round merges main into a branch that genuinely conflicts, and the "agent"
#    is a stub that either resolves the conflict and commits or does nothing —
#    which is the difference between rung 2 landing and rung 3 being reached.
#    Only mc_rebase (the mechanical rung's own body, whose rc contract
#    tests/merge-conductor-test.sh drives) is stubbed, because running it for
#    real would need a credential and somebody's repo.
# ============================================================================
# The real local git this section and tests/br-contested-test.sh both drive, plus
# the mc_rebase rc-contract stub and the section's gh and agent-call stubs: the
# old suite's lines 846-988, now tests/lib/fixture-harness.sh.
fx_br_ladder_git "$DIR" "$T" || exit 1

# ---- 8a. rung 1 is MECHANICAL, and a mechanical rung that lands ends the tick
printf 'ticket/TK-88\n' > "$T/prbranch"; osha ticket/TK-88 > "$T/prhead"
echo 0 > "$T/rebase-rc"; echo "dddddddddddddddddddddddddddddddddddddddd" > "$T/rebase-out"
ROW "o/tproj#88" "conflict-unresolvable: CONFLICT (content): a.txt" "https://github.com/o/tproj/pull/88"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/rebase.txt"; : > "$H/logs/blocked-resolver.log"
RUN
grep -q 'EVENT resolver_rung .*rung 1 mechanical' "$H/logs/blocked-resolver.log" && ok \
  || bad "a rebase-conflict park's first rung must be the mechanical one, as an event (log: $(tail -3 "$H/logs/blocked-resolver.log"))"
grep -q 'ticket/TK-88' "$T/rebase.txt" && ok || bad "the mechanical rung must ask mc_rebase to merge main into the PR branch (got: $(cat "$T/rebase.txt"))"
grep -q 'MECHANICAL — pushed' "$H/logs/blocked-resolver.log" && ok || bad "a pushed mechanical rung must say so"
[ "$(STATEJSON tproj-TK-88 | jq -r .mechanicals)" = 1 ] && ok || bad "the mechanical rung must be counted (got $(STATEJSON tproj-TK-88 | jq -r .mechanicals))"
[ "$(STATEJSON tproj-TK-88 | jq -r .rebuilds)" = 0 ] && ok || bad "a mechanical rung that landed must NOT also rebuild"
[ -s "$T/closed.txt" ] && bad "the mechanical rung must not close the PR" || ok
[ -s "$T/queue.txt" ] && bad "the mechanical rung must not enqueue a rebuild (got: $(cat "$T/queue.txt"))" || ok

# ---- 8b. rung 2 is the FIX ROUND on the EXISTING branch, with the conflict in
#          its prompt — and when it lands, nothing is rebuilt.
touch "$T/agent-resolves"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/prompt.txt"; : > "$H/logs/blocked-resolver.log"
BEFORE88=$(osha ticket/TK-88)
RUN
grep -q 'EVENT resolver_rung .*rung 2 fix-round' "$H/logs/blocked-resolver.log" && ok \
  || bad "the DEFAULT second rung must be the fix round (log: $(tail -5 "$H/logs/blocked-resolver.log"))"
grep -q 'THE MERGE OF origin/main IS IN PROGRESS' "$T/prompt.txt" && ok \
  || bad "the fix round's prompt must hand the agent the conflict, not abort it away"
grep -q '<<<<<<<' "$T/prompt.txt" && ok || bad "the prompt must carry the conflict MARKERS (got $(head -c 300 "$T/prompt.txt"))"
grep -q 'a.txt' "$T/prompt.txt" && ok || bad "the prompt must name the conflicted path"
grep -q 'REVIEW FINDINGS AS POSTED ON THE PR' "$T/prompt.txt" && ok || bad "posted findings must still ride into the prompt"
grep -q 'FIX ROUND pushed' "$H/logs/blocked-resolver.log" && ok \
  || bad "a verified fix round must push to the PR branch (log: $(tail -5 "$H/logs/blocked-resolver.log"))"
[ "$(osha ticket/TK-88)" != "$BEFORE88" ] && ok || bad "the fix round must move the PR branch on the remote"
[ "$(STATEJSON tproj-TK-88 | jq -r .fixrounds)" = 1 ] && ok || bad "the fix round must be counted"
[ "$(STATEJSON tproj-TK-88 | jq -r .rebuilds)" = 0 ] && ok || bad "a fix round that landed must never also rebuild"
[ -s "$T/closed.txt" ] && bad "a landed fix round must not close the PR" || ok
[ -s "$T/queue.txt" ] && bad "a landed fix round must not enqueue a rebuild (got: $(cat "$T/queue.txt"))" || ok
# The branch it worked on is cleaned up, so the next park starts from the PR.
git -C "$T/repos/tproj" rev-parse --verify -q brfix/tproj-TK-88 >/dev/null 2>&1 \
  && bad "a finished fix round must not leave its working branch behind" || ok

# ---- 8c. THE WHOLE LADDER IN ONE TICK when each rung fails: mechanical (the
#          conflict is real), fix round (the agent resolves nothing), rebuild.
rm -f "$T/agent-resolves"
printf 'ticket/TK-89\n' > "$T/prbranch"; osha ticket/TK-89 > "$T/prhead"
echo 1 > "$T/rebase-rc"; printf 'a.txt\n' > "$T/rebase-out"
# THE CONDUCTOR'S SIDECAR SAYS THIS CONFLICT IS A BIG ONE (BH-579), so this
# ticket takes the LARGE ladder — one fix round, then the rebuild — which is the
# ladder this section has always driven. Without the measurement the fix round's
# own two-line conflict would make the ticket small, buy it a second round and
# end the tick before rung 3.
mkdir -p "$H/state/merge-conductor/conflict-size"
printf '500\t%s\ta.txt\n' "$(osha ticket/TK-89)" > "$H/state/merge-conductor/conflict-size/o_tproj_89"
ROW "o/tproj#89" "conflict-unresolvable: CONFLICT (content): a.txt" "https://github.com/o/tproj/pull/89"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$H/logs/blocked-resolver.log"
RUN
SEQ=$(grep -o 'rung [123]' "$H/logs/blocked-resolver.log" | tr -d '\n' | tr -s ' ')
[ "$SEQ" = "rung 1rung 2rung 3" ] && ok || bad "the rungs must be taken in order 1,2,3 (got '$SEQ')"
grep -q 'the markers stay in the tree' "$H/logs/blocked-resolver.log" && ok \
  || bad "a conflict the mechanical rung could not resolve must be handed to the fix round, not aborted"
grep -q 'did not produce a verified commit' "$H/logs/blocked-resolver.log" && ok \
  || bad "a fix round that resolved nothing must be refused, not pushed"
[ "$(osha ticket/TK-89)" = "$(git -C "$T/repos/tproj" rev-parse refs/remotes/origin/ticket/TK-89)" ] && ok \
  || bad "an unverified fix round must never push — the remote branch moved"
[ "$(STATEJSON tproj-TK-89 | jq -r '[.mechanicals,.fixrounds,.rebuilds]|@csv')" = "1,1,1" ] && ok \
  || bad "one tick of a failing ladder must spend exactly one of each rung (got $(STATEJSON tproj-TK-89 | jq -r '[.mechanicals,.fixrounds,.rebuilds]|@csv'))"
[ -s "$T/closed.txt" ] && ok || bad "the rebuild rung must close the stale PR"
grep -q '^tproj TK-89 89 fly 0 ' "$T/queue.txt" && ok || bad "the rebuild rung must enqueue the ticket fresh (got: $(cat "$T/queue.txt"))"
[ "$(STATEJSON tproj-TK-89 | jq -r .outcome)" = ABANDONED ] \
  && bad "one failed ladder is not an abandonment — the rebuild cap is still 3" || ok
# THE PATHS ARE REMEMBERED, per (pr, head), from the mechanical rung's own
# stdout — that memory is what section 9's recurrence check reads.
[ "$(STATEJSON tproj-TK-89 | jq -c '.conflicts[0].paths')" = '["a.txt"]' ] && ok \
  || bad "a mechanical rung that conflicts must record the paths it conflicted on (got $(STATEJSON tproj-TK-89 | jq -c '.conflicts'))"
[ "$(STATEJSON tproj-TK-89 | jq -r '.conflicts[0].pr')" = 89 ] && ok \
  || bad "the conflict note must carry the PR it happened on (got $(STATEJSON tproj-TK-89 | jq -r '.conflicts[0].pr'))"
[ "$(STATEJSON tproj-TK-89 | jq -r '.conflict_lines')" = 500 ] && ok \
  || bad "the conductor's sidecar measurement must reach the ticket (got $(STATEJSON tproj-TK-89 | jq -r '.conflict_lines'))"

# ---- 8d. a RED-CI park's fix round is briefed with the failing job's log
printf 'ticket/TK-90\n' > "$T/prbranch"; osha ticket/TK-90 > "$T/prhead"
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc '{project:"tproj",rkey:"tproj-TK-90",mechanicals:1,fixrounds:0,rebuilds:0,outcome:"",attempts:[]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-90.json"
printf '4242\n' > "$T/failedruns"
printf 'FAIL src/rate.test.ts > applies the fee\n  expected 3 to equal 4\n' > "$T/joblog"
: > "$T/findings"
ROWST "o/tproj#90" RED_TWICE "red-twice: still red on ${BEFORE88:0:8} after its failed jobs were re-run once" "https://github.com/o/tproj/pull/90"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/prompt.txt"; : > "$H/logs/blocked-resolver.log"
RUN
grep -q 'EVENT resolver_rung .*rung 2 fix-round' "$H/logs/blocked-resolver.log" && ok \
  || bad "with its mechanical rung spent, a red-CI park's next rung is the fix round (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
grep -q 'THE FAILING CI JOBS ON THIS HEAD' "$T/prompt.txt" && ok \
  || bad "a red-CI fix round must be briefed with the failing job's log, or it is an agent sent to go and look"
grep -q 'expected 3 to equal 4' "$T/prompt.txt" && ok || bad "the actual failure text must reach the prompt"

# ---- 8e. a CHECKPOINT branch left by a killed round is REUSED, not thrown away
printf 'ticket/TK-91\n' > "$T/prbranch"; osha ticket/TK-91 > "$T/prhead"
jq -nc '{project:"tproj",rkey:"tproj-TK-91",mechanicals:1,fixrounds:0,rebuilds:0,outcome:"",attempts:[]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-91.json"
: > "$T/failedruns"; : > "$T/joblog"
printf 'Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated.\n' > "$T/findings"
CPWT="$T/cpwt"
git -C "$T/repos/tproj" worktree add -q "$CPWT" -b brfix/tproj-TK-91 origin/ticket/TK-91
printf 'half the fix\n' > "$CPWT/c.txt"
git -C "$CPWT" add -A; git -C "$CPWT" -c user.email=t@t -c user.name=t commit -qm "checkpoint work from the killed round"
CP91=$(git -C "$CPWT" rev-parse HEAD)
git -C "$T/repos/tproj" worktree remove --force "$CPWT"
touch "$T/agent-resolves"
ROW "o/tproj#91" "head-not-reapproved" "https://github.com/o/tproj/pull/91"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$H/logs/blocked-resolver.log"
RUN
grep -q 'reusing the checkpoint branch brfix/tproj-TK-91' "$H/logs/blocked-resolver.log" && ok \
  || bad "a checkpoint branch left by a killed round must be reused (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
# REACHABILITY, ASKED OF git (BH-1232). This was `log --oneline | grep -q
# <subject>`, and grep -q exits at the first match while git is still writing
# the rest of the history: git takes SIGPIPE, `set -o pipefail` at the top of
# this file hands the && git's 141, and the assertion went red on ~1 run in 5
# under load with the commit sitting on the branch the whole time (it put main
# red at 4ffd1811). --is-ancestor answers the same question with no pipe, and
# answers it about the EXACT commit rather than about a subject line any
# later commit could repeat.
git -C "$ORIGIN" merge-base --is-ancestor "$CP91" ticket/TK-91 && ok \
  || bad "the checkpoint commit must survive into what the fix round pushes — reuse that throws the work away is not reuse"
grep -q 'FIX ROUND pushed' "$H/logs/blocked-resolver.log" && ok || bad "the reused round must still push"
# A review-blocked park starts at the fix round: no mechanical merge is bought
# for a PR whose problem is what a reviewer said about the code.
grep -q 'rung 1 mechanical' "$H/logs/blocked-resolver.log" \
  && bad "a head-not-reapproved park must not buy a mechanical rung" || ok
rm -f "$T/agent-resolves"

# ============================================================================
# 8f. A SETUP FAILURE IS NOT A FAILED FIX ROUND — NO PR DIES OF A MACHINE
#     PROBLEM (2026-09-16).
#
#     THE INCIDENT. cromford #489 (12:04:57Z) and #465 (01:44:26Z) were
#     both CLOSED by the rebuild rung, with finished work on the branch, because
#     the hub has no /root/repos/cromford clone:
#
#       12:04:51Z mechanical rung still conflicts (…) — FIX ROUND with the conflict in its prompt
#                 fatal: cannot change to '/root/repos/cromford': No such file or directory
#       12:04:53Z worktree add failed for origin/ticket/bh-438 — REBUILD FRESH instead
#       12:04:57Z closed https://github.com/example-org/cromford/pull/489
#
#     `worktree add failed` is a fact about the BOX, not an event about the PR,
#     and the operator's rule (2026-09-16) is that only an event may take a terminal. So
#     every edge that stops rung 2 BEFORE the agent runs is driven here, with
#     the assertions that matter being the negative ones: nothing closed,
#     nothing enqueued, no counter spent — and one alert, because a lane that
#     cannot act has to say so.
# ============================================================================
rm -f "$T/agent-resolves"
printf 'ticket/TK-94\n' > "$T/prbranch"; osha ticket/TK-94 > "$T/prhead"
printf 'Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated.\n' > "$T/findings"
: > "$T/failedruns"; : > "$T/joblog"
echo 1 > "$T/rebase-rc"; printf 'a.txt\n' > "$T/rebase-out"
SETUPJSON() { # SETUPJSON <cap-key> — a park whose next rung is the FIX ROUND
  jq -nc --arg k "$1" '{project:"tproj",rkey:$k,mechanicals:1,fixrounds:0,rebuilds:0,outcome:"",attempts:[]}' \
    > "$H/state/blocked-resolver/tproj/$1.json"
  rm -f "$H/state/blocked-resolver/tproj/$1.setup-alerted"
}

# ---- 8f-1. NO LOCAL CLONE — the #489 shape, exactly
SETUPJSON tproj-TK-94
mv "$T/repos/tproj" "$T/repos/tproj.away"
ROW "o/tproj#94" "conflict-unresolvable: CONFLICT (content): a.txt" "https://github.com/o/tproj/pull/94"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/lane-alert.txt"; : > "$H/logs/blocked-resolver.log"
RUN
[ -s "$T/closed.txt" ] \
  && bad "THE #489 BUG: a missing local clone must NEVER close the PR (closed: $(cat "$T/closed.txt"))" || ok
grep -q '^tproj TK-94 ' "$T/queue.txt" \
  && bad "a missing local clone must not enqueue a rebuild either (got: $(cat "$T/queue.txt"))" || ok
[ "$(STATEJSON tproj-TK-94 | jq -r '[.fixrounds,.rebuilds]|@csv')" = "0,0" ] && ok \
  || bad "a fix round that could not START spends no rung (got $(STATEJSON tproj-TK-94 | jq -r '[.fixrounds,.rebuilds]|@csv'))"
grep -q 'could not START' "$H/logs/blocked-resolver.log" && ok \
  || bad "the log must say the rung could not start, not that it failed (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
grep -q 'no local clone at' "$H/logs/blocked-resolver.log" && ok \
  || bad "the missing clone must be named — 'worktree add failed' is what nobody could act on (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
grep -q 'EVENT resolver_setup_blocked' "$H/logs/blocked-resolver.log" && ok \
  || bad "a setup block is an event line like every other rung transition (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
grep -q 'retried next tick' "$H/logs/blocked-resolver.log" && ok \
  || bad "the log must say the same rung is retried, so a reader knows nothing was given up"
grep -q 'pull/94' "$T/lane-alert.txt" && grep -q 'LEFT OPEN' "$T/lane-alert.txt" && ok \
  || bad "stopping is an alert, not a whisper: one actionable line naming the PR (got: $(cat "$T/lane-alert.txt"))"
grep -q 'repos/tproj' "$T/lane-alert.txt" && ok \
  || bad "the alert must name what the box is missing (got: $(cat "$T/lane-alert.txt"))"
[ "$(STATEJSON tproj-TK-94 | jq -r '[.attempts[].action] | index("fix-round-blocked") != null')" = true ] && ok \
  || bad "the blocked rung must be recorded as an attempt, so the ABANDONED alert can never claim a fix round ran"

# ---- 8f-2. the next tick tries the SAME rung again, and does not page twice
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/lane-alert.txt"; : > "$H/logs/blocked-resolver.log"
RUN
[ -s "$T/closed.txt" ] && bad "the second tick must not close the PR either" || ok
grep -q 'could not START' "$H/logs/blocked-resolver.log" && ok \
  || bad "the park must be re-offered the same rung, not escalated (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
[ -s "$T/lane-alert.txt" ] \
  && bad "ONE alert per park: this lane re-offers every ten minutes and 144 alerts a day is none (got: $(cat "$T/lane-alert.txt"))" || ok
[ "$(STATEJSON tproj-TK-94 | jq -r '[.fixrounds,.rebuilds]|@csv')" = "0,0" ] && ok \
  || bad "no tick of a setup block spends a rung (got $(STATEJSON tproj-TK-94 | jq -r '[.fixrounds,.rebuilds]|@csv'))"
# ONE record and ONE event per episode too, for the same reason as the alert: a
# block that stands for a day would otherwise write 144 attempt entries into the
# record whose job is to say what was TRIED, and 144 beats behind them.
[ "$(STATEJSON tproj-TK-94 | jq -r '[.attempts[] | select(.action == "fix-round-blocked")] | length')" = 1 ] && ok \
  || bad "the blocked rung is recorded once per episode, not once per tick (got $(STATEJSON tproj-TK-94 | jq -r '[.attempts[] | select(.action == "fix-round-blocked")] | length'))"
grep -q 'EVENT resolver_setup_blocked' "$H/logs/blocked-resolver.log" \
  && bad "the event line is per episode as well — the per-tick evidence is the plain log line" || ok

# ---- 8f-3. the box is fixed: the SAME rung runs on the SAME branch and lands
mv "$T/repos/tproj.away" "$T/repos/tproj"
touch "$T/agent-resolves"
BEFORE94=$(osha ticket/TK-94)
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/lane-alert.txt"; : > "$H/logs/blocked-resolver.log"
RUN
grep -q 'EVENT resolver_rung .*rung 2 fix-round' "$H/logs/blocked-resolver.log" && ok \
  || bad "once the clone is back the park takes rung 2, not a rebuild (log: $(tail -5 "$H/logs/blocked-resolver.log"))"
grep -q 'FIX ROUND pushed' "$H/logs/blocked-resolver.log" && ok \
  || bad "the retried rung must be able to land (log: $(tail -5 "$H/logs/blocked-resolver.log"))"
[ "$(osha ticket/TK-94)" != "$BEFORE94" ] && ok || bad "the landed fix round must move the branch the PR already had"
[ -s "$T/closed.txt" ] && bad "and it must still not close anything" || ok
[ -e "$H/state/blocked-resolver/tproj/tproj-TK-94.setup-alerted" ] \
  && bad "the setup marker must be cleared when a rung actually runs, so a LATER box problem pages again" || ok
rm -f "$T/agent-resolves"

# ---- 8f-4. NO REPO/BRANCH — the other edge #465 took (01:44Z, then 02:25Z)
: > "$T/prbranch"; osha ticket/TK-94 > "$T/prhead"
ROW "o/tproj#92" "conflict-unresolvable: CONFLICT (content): a.txt" "https://github.com/o/tproj/pull/92"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$H/logs/blocked-resolver.log"
RUN
[ -s "$T/closed.txt" ] \
  && bad "THE #465 BUG: a branch gh would not name must not close the PR (closed: $(cat "$T/closed.txt"))" || ok
grep -q 'no repo/branch could be resolved' "$H/logs/blocked-resolver.log" && ok \
  || bad "the unresolved repo/branch must be reported as a setup block (log: $(tail -4 "$H/logs/blocked-resolver.log"))"

# ---- 8f-5. origin/<branch> will not resolve (a fetch that did not run, a dead
#            credential) — a branch GitHub names and this clone has never seen
# The PR head is blank too: `lease` falls back to the head gh reports
# (`[ -n "$lease" ] || lease="$head"`), so a head that IS known makes this the
# worktree-add edge of 8f-6 instead. Nothing resolvable anywhere is what drives
# the lease branch.
printf 'ticket/TK-93\n' > "$T/prbranch"; : > "$T/prhead"
SETUPJSON tproj-TK-93
ROW "o/tproj#93" "conflict-unresolvable: CONFLICT (content): a.txt" "https://github.com/o/tproj/pull/93"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$H/logs/blocked-resolver.log"
RUN
[ -s "$T/closed.txt" ] \
  && bad "an unresolvable origin ref must not close the PR (closed: $(cat "$T/closed.txt"))" || ok
grep -q 'origin/ticket/TK-93 will not resolve' "$H/logs/blocked-resolver.log" && ok \
  || bad "the unresolvable ref must be named (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
[ "$(STATEJSON tproj-TK-93 | jq -r '[.fixrounds,.rebuilds]|@csv')" = "0,0" ] && ok \
  || bad "an unresolvable ref spends no rung (got $(STATEJSON tproj-TK-93 | jq -r '[.fixrounds,.rebuilds]|@csv'))"

# ---- 8f-6. `git worktree add` FAILS — the literal line in the #489 log. Its
#            working branch is checked out in another worktree and does not
#            contain the PR head, so the reuse path declines and the add refuses.
printf 'ticket/TK-90\n' > "$T/prbranch"; osha ticket/TK-90 > "$T/prhead"
SETUPJSON tproj-TK-90
BLKWT="$T/blkwt"
git -C "$T/repos/tproj" fetch -q origin
git -C "$T/repos/tproj" worktree add -q "$BLKWT" -b brfix/tproj-TK-90 origin/main
ROW "o/tproj#90" "conflict-unresolvable: CONFLICT (content): a.txt" "https://github.com/o/tproj/pull/90"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$H/logs/blocked-resolver.log"
RUN
grep -q 'worktree add failed for origin/ticket/TK-90' "$H/logs/blocked-resolver.log" && ok \
  || bad "the worktree-add failure must be reached and reported (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
[ -s "$T/closed.txt" ] \
  && bad "THE EXACT #489 EDGE: a failed worktree add must not close the PR (closed: $(cat "$T/closed.txt"))" || ok
grep -q '^tproj TK-90 ' "$T/queue.txt" \
  && bad "a failed worktree add must not enqueue a rebuild (got: $(cat "$T/queue.txt"))" || ok
[ "$(STATEJSON tproj-TK-90 | jq -r '[.fixrounds,.rebuilds]|@csv')" = "0,0" ] && ok \
  || bad "a failed worktree add spends no rung (got $(STATEJSON tproj-TK-90 | jq -r '[.fixrounds,.rebuilds]|@csv'))"
git -C "$T/repos/tproj" worktree remove --force "$BLKWT" >/dev/null 2>&1
git -C "$T/repos/tproj" branch -D brfix/tproj-TK-90 >/dev/null 2>&1

# ---- 8f-7. AND THE ESCALATION THAT MUST STILL WORK: an agent that RAN and
#            produced nothing is an EVENT, and rung 3 still closes and rebuilds.
#            Without this the fix above would have replaced one stuck PR with
#            another.
printf 'ticket/TK-90\n' > "$T/prbranch"; osha ticket/TK-90 > "$T/prhead"
SETUPJSON tproj-TK-90
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$H/logs/blocked-resolver.log"
RUN
grep -q 'did not produce a verified commit' "$H/logs/blocked-resolver.log" && ok \
  || bad "a fix round whose agent ran and landed nothing is still a FAILED round (log: $(tail -5 "$H/logs/blocked-resolver.log"))"
[ -s "$T/closed.txt" ] && ok \
  || bad "an EVENT must still reach the rebuild rung — a ladder that never escalates is the other failure"
[ "$(STATEJSON tproj-TK-90 | jq -r '[.fixrounds,.rebuilds]|@csv')" = "1,1" ] && ok \
  || bad "the failed round and the rebuild are both counted (got $(STATEJSON tproj-TK-90 | jq -r '[.fixrounds,.rebuilds]|@csv'))"

# ---- 8f-7b. RUNG 1 TOO: mc_rebase rc 4 is a clone/credential problem, not a
#             mechanical rung that ran and failed. It used to spend the rung,
#             which walked the park one step closer to the rung that closes PRs
#             for a reason that was never about the PR.
printf 'ticket/TK-91\n' > "$T/prbranch"; osha ticket/TK-91 > "$T/prhead"
jq -nc '{project:"tproj",rkey:"tproj-TK-91",mechanicals:0,fixrounds:0,rebuilds:0,outcome:"",attempts:[]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-91.json"
rm -f "$H/state/blocked-resolver/tproj/tproj-TK-91.setup-alerted"
# A fresh project too: the 8f blocks above tripped the project rate alert, whose
# 24 h hold sends no per-park page (BH-7630, comment 6315926752).
rm -f "$H/state/blocked-resolver/tproj/setup-blocked.tsv" "$H/state/blocked-resolver/tproj/setup-blocked.alerted"
echo 4 > "$T/rebase-rc"; : > "$T/rebase-out"
ROW "o/tproj#91" "conflict-unresolvable: CONFLICT (content): a.txt" "https://github.com/o/tproj/pull/91"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/lane-alert.txt"; : > "$H/logs/blocked-resolver.log"
RUN
[ "$(STATEJSON tproj-TK-91 | jq -r '[.mechanicals,.fixrounds,.rebuilds]|@csv')" = "0,0,0" ] && ok \
  || bad "a mechanical rung that could not run spends nothing (got $(STATEJSON tproj-TK-91 | jq -r '[.mechanicals,.fixrounds,.rebuilds]|@csv'))"
[ -s "$T/closed.txt" ] && bad "rc 4 must not close the PR" || ok
grep -q 'the mechanical rung could not START' "$H/logs/blocked-resolver.log" && ok \
  || bad "the blocked rung must be named as rung 1 (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
grep -q 'mechanical rung cannot START' "$T/lane-alert.txt" && ok \
  || bad "the alert must say which rung cannot start (got: $(cat "$T/lane-alert.txt"))"
[ "$(STATEJSON tproj-TK-91 | jq -r '[.attempts[].action] | index("mechanical-blocked") != null')" = true ] && ok \
  || bad "the blocked rung 1 is recorded under its own action word"
# and the tick after the box is fixed takes the SAME free rung
echo 0 > "$T/rebase-rc"; printf 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\n' > "$T/rebase-out"
: > "$T/lane-alert.txt"; : > "$H/logs/blocked-resolver.log"
RUN
grep -q 'rung 1 mechanical' "$H/logs/blocked-resolver.log" && ok \
  || bad "once the box is fixed the free rung must still be available (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
[ "$(STATEJSON tproj-TK-91 | jq -r '.mechanicals')" = 1 ] && ok \
  || bad "the rung that RAN is the one that counts (got $(STATEJSON tproj-TK-91 | jq -r '.mechanicals'))"
[ -e "$H/state/blocked-resolver/tproj/tproj-TK-91.setup-alerted" ] \
  && bad "a rung that ran clears the setup marker" || ok
echo 1 > "$T/rebase-rc"; printf 'a.txt\n' > "$T/rebase-out"

echo "br-rungs-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
