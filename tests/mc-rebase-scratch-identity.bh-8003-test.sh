#!/bin/bash
# tests/mc-rebase-scratch-identity.bh-8003-test.sh — mc_rebase's merge carries
# its own committer identity, and the resolver's rc-4 alert names the reason
# the conductor logged.
#
# WHAT THIS PINS (BH-8003). On the hub, the resolver ran mc_rebase on the
# scratch clone ($MC_H/tmp/conductor/<slug>) with no global git identity. The
# merge died "Committer identity unknown", mc_rebase returned rc 4, and the
# alert said "a clone or credential problem" on 5 project-6 PRs.
#   1   scratch clone, empty HOME, no global or system config: the merge lands,
#       committed as ${MC_GIT_NAME:-$HARNESS_MERGE_GIT_NAME}; MC_GIT_* wins.
#   1b  same env, an add/add conflict mc_resolve_conflicts resolves: the
#       resolved-merge commit lands too.
#   2   round trip: a real rc-4 fetch failure, written by the real mc_log, read
#       back by mc_rebase_reason.
#   3   mc_rebase_reason's decision table (match and reject sides).
#   4   the real resolver: the rc-4 alert names the logged reason, or says it
#       logged none; it spends nothing and closes nothing. Rung 1 and rung 1b.
#
# REAL GIT. Only mc_git_auth/mc_git_auth_clear are replaced in sections 1-3.
# Run from anywhere: tests/mc-rebase-scratch-identity.bh-8003-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# The tally is a file: sections 1-3 run in a subshell (their git env must not
# reach section 4), and a counter in a subshell is lost.
TALLY="$T/tally"; : > "$TALLY"
ok()  { echo ok >> "$TALLY"; }
bad() { echo bad >> "$TALLY"; echo "FAIL: $1"; }
[ -r "$DIR/bin/lib/mc/rebase.sh" ] && [ -r "$DIR/bin/lib/br/ladder.sh" ] || exit 1   # impact: the two libs this suite pins

# ONE clock read; every fixture commit is stamped from it.
NOW=$(date +%s)
export GIT_AUTHOR_DATE="@$NOW +0000" GIT_COMMITTER_DATE="@$NOW +0000"

(
# ============================================================================
# The env of the hub's failing call: no global, no system config, an empty
# HOME, and git may not guess a name from the host (user.useConfigOnly).
# ============================================================================
export HOME="$T/emptyhome"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.useConfigOnly GIT_CONFIG_VALUE_0=true
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL \
      MC_GIT_NAME MC_GIT_EMAIL HARNESS_MERGE_GIT_NAME HARNESS_GIT_EMAIL
export HARNESS="$T/lib-h"
mkdir -p "$HARNESS/logs" "$HARNESS/state" "$HARNESS/locks" "$HARNESS/flags" "$HARNESS/builds"
# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh" || exit 1
mc_init
: > "$MC_LOG"
# No hub clone for any slug: every call takes the scratch-clone path.
export MC_REPOS="$T/no-repos"; mkdir -p "$MC_REPOS"
WANT_ID="$HARNESS_MERGE_GIT_NAME <$HARNESS_GIT_EMAIL>"
[ "$WANT_ID" != " <>" ] && ok || bad "fixture: deployment.sh gave no merge identity"

# logmark — the line count of $MC_LOG now (0 when missing): the same mark the
# resolver takes inline before it calls mc_rebase.
logmark() { local n=0; [ -f "${MC_LOG:-}" ] && n=$(wc -l < "$MC_LOG" | tr -d ' '); echo "$n"; }
REMOTE=""
mc_git_auth()       { MC_REMOTE="$REMOTE"; return 0; }
mc_git_auth_clear() { :; }

# mk_origin <tag> [generated] — a bare origin: main 6 commits ahead of a branch
# forked at commit 2 with one commit of its own. `generated` = both sides add
# .harness/specs/BH-601/plan.md (the add/add class mc_resolve_conflicts takes).
# Built with `git clone --bare`, never a push.
mk_origin() {
  local tag="$1" mode="${2:-}" w i fork
  w="$T/$tag/work"; BRANCH=ticket/x
  [ "$mode" = generated ] && BRANCH=ticket/bh-600
  mkdir -p "$w"; git init -q -b main "$w"
  git -C "$w" config user.email t@t; git -C "$w" config user.name t
  git -C "$w" config commit.gpgsign false
  for i in 1 2 3 4 5 6 7 8; do
    echo "c$i" > "$w/f$i"
    [ "$i" = 8 ] && [ "$mode" = generated ] && { mkdir -p "$w/.harness/specs/BH-601"; echo "main copy" > "$w/.harness/specs/BH-601/plan.md"; }
    git -C "$w" add -A; git -C "$w" commit -qm "c$i"
    [ "$i" = 2 ] && fork=$(git -C "$w" rev-parse HEAD)
  done
  git -C "$w" checkout -q -b "$BRANCH" "$fork"
  echo branch > "$w/b.ts"
  [ "$mode" = generated ] && { mkdir -p "$w/.harness/specs/BH-601"; echo "branch copy" > "$w/.harness/specs/BH-601/plan.md"; }
  git -C "$w" add -A; git -C "$w" commit -qm "branch work"
  BR_HEAD=$(git -C "$w" rev-parse HEAD)
  git -C "$w" checkout -q main
  ORIGIN="$T/$tag/origin.git"
  git clone -q --bare "$w" "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  REMOTE="file://$ORIGIN"
}
committer() { git -C "$ORIGIN" log -1 --format='%cn <%ce>' "$1"; }

# ── 1. scratch clone, no identity anywhere: the merge lands ────────────────
mk_origin s1
U1=https://github.com/o/s1/pull/11
OUT=$(mc_rebase o/s1 demo-os ticket/x "$BR_HEAD" "$U1"); RC=$?
[ "$RC" = 0 ] && ok || bad "(1) the scratch-clone merge must land with no global identity, got rc $RC (log: $(grep -F "$U1" "$MC_LOG" | tail -2))"
[ -n "$OUT" ] && [ "$OUT" = "$(git -C "$ORIGIN" rev-parse ticket/x)" ] && ok \
  || bad "(1) stdout must be the pushed head: '$OUT' vs $(git -C "$ORIGIN" rev-parse ticket/x)"
git -C "$ORIGIN" merge-base --is-ancestor main ticket/x && ok || bad "(1) main must be an ancestor of the pushed branch"
[ -d "$HARNESS/tmp/conductor/o_s1/.git" ] && ok || bad "(1) the scratch-clone path must be the one that ran"
grep -q 'Committer identity unknown' "$MC_LOG" && bad "(1) the log must not say 'Committer identity unknown': $(grep -F "$U1" "$MC_LOG")" || ok
[ "$(committer ticket/x)" = "$WANT_ID" ] && ok || bad "(1) the merge must be committed as '$WANT_ID', got '$(committer ticket/x)'"
# MC_GIT_NAME/MC_GIT_EMAIL beat the deployment defaults.
mk_origin s1c
OUT=$(MC_GIT_NAME=x MC_GIT_EMAIL=x@y mc_rebase o/s1c demo-os ticket/x "$BR_HEAD" https://github.com/o/s1c/pull/12); RC=$?
[ "$RC" = 0 ] && [ "$(committer ticket/x)" = "x <x@y>" ] && ok \
  || bad "(1) MC_GIT_NAME/MC_GIT_EMAIL must set the committer: rc $RC, '$(committer ticket/x)'"

# ── 1b. the resolved-merge commit, same env ────────────────────────────────
mk_origin s1b generated
OUT=$(mc_rebase o/s1b demo-os ticket/bh-600 "$BR_HEAD" https://github.com/o/s1b/pull/13); RC=$?
[ "$RC" = 0 ] || [ "$RC" = 5 ] && ok || bad "(1b) the resolved merge must commit and push with no global identity, got rc $RC (log: $(grep -F pull/13 "$MC_LOG" | tail -2))"
git -C "$ORIGIN" merge-base --is-ancestor main ticket/bh-600 && ok || bad "(1b) the resolved merge must be on origin"
[ "$(committer ticket/bh-600)" = "$WANT_ID" ] && ok || bad "(1b) the resolved merge must be committed as '$WANT_ID', got '$(committer ticket/bh-600)'"

# ── 2. round trip: a real rc-4 line, read back ─────────────────────────────
mk_origin s2
U2=https://github.com/o/s2/pull/21
MARK=$(logmark); RC=0
mc_rebase o/s2 demo-os ticket/nope "$BR_HEAD" "$U2" >/dev/null || RC=$?
[ "$RC" = 4 ] && ok || bad "(2) a fetch of a branch origin does not have is rc 4, got $RC"
WHY=$(mc_rebase_reason "$U2" "$MARK"); RRC=$?
[ "$RRC" = 0 ] && [[ "$WHY" == "fetch on the scratch clone failed"* ]] && ok \
  || bad "(2) mc_rebase_reason must read the real line back: rc $RRC, '$WHY'"

# ── 3. mc_rebase_reason, decision table ────────────────────────────────────
U=https://github.com/o/r/pull/9
: > "$MC_LOG"
mc_log "$U rebase: merge failed — an earlier tick"          # (d) before the mark
M=$(logmark)
[ "$M" = 1 ] && ok || bad "(3) fixture: the mark must count the lines, got '$M'"
mc_rebase_reason "$U" "$M" >/dev/null && bad "(3d) a line before the mark must not be read" || ok
mc_log "https://github.com/o/r/pull/19 rebase: merge failed — pr 19"
mc_log "https://github.com/o/r/pull/92 rebase: merge failed — pr 92"
mc_rebase_reason "$U" "$M" >/dev/null && bad "(3e) pull/19 and pull/92 must not match pull/9: '$(mc_rebase_reason "$U" "$M")'" || ok
mc_log "$U restack: rebase --onto failed — a restack"
mc_rebase_reason "$U" "$M" >/dev/null && bad "(3f) a restack line must not be read" || ok
mc_log "$U rebase: merge failed — Committer identity unknown"
[ "$(mc_rebase_reason "$U" "$M")" = "merge failed — Committer identity unknown" ] && ok \
  || bad "(3a) one line after the mark: got '$(mc_rebase_reason "$U" "$M")'"
mc_log "$U rebase: merge failed — the newest"
[ "$(mc_rebase_reason "$U" "$M")" = "merge failed — the newest" ] && ok \
  || bad "(3b) two lines: the newest wins, got '$(mc_rebase_reason "$U" "$M")'"
mc_log "$U rebase: fetch failed — https://x:ghp_fixtureAAAA1234@h github_pat_fixture_BBBB2222 end"
R=$(mc_rebase_reason "$U" "$M")
case "$R" in *ghp_fixture*|*github_pat_fixture*) bad "(3c) a token must be redacted: '$R'" ;; *end) ok ;; *) bad "(3c) the redacted line lost its text: '$R'" ;; esac
mc_rebase_reason "$U" "$M" >/dev/null && ok || bad "(3c) a redacted line is still a reason (rc 0)"
mc_rebase_reason "$U" junk >/dev/null && bad "(3) a non-numeric mark must be rc 1" || ok
mc_rebase_reason "$U" "" >/dev/null && bad "(3) an empty mark must be rc 1" || ok
: > "$MC_LOG"
mc_rebase_reason "$U" 0 >/dev/null && bad "(3h) an empty log has no reason" || ok
rm -f "$MC_LOG"
mc_rebase_reason "$U" 0 >/dev/null && bad "(3g) a missing log has no reason" || ok
)

# ============================================================================
# 4. THE REAL RESOLVER on the section-8 fixture. mc_rebase is overridden to
#    write a reason through the real mc_log (or nothing) and return 4.
# ============================================================================
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
fx_br_harness "$DIR" "$T" || exit 1
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
fx_br_ladder_git "$DIR" "$T" || exit 1
cat >> "$H/bin/lib/merge-conductor-lib.sh" <<EOF
# --- BH-8003 override: rc 4 with the reason in \$T/rebase-why (or none) ------
mc_rebase() {
  printf '%s\n' "\$*" >> "$T/rebase.txt"
  [ -s "$T/rebase-why" ] && mc_log "\$5 rebase: \$(cat "$T/rebase-why")"
  return 4
}
EOF
MCL="$H/logs/merge-conductor.log"
U91=https://github.com/o/tproj/pull/91
park91() { # <reason> <mechanicals>
  mkdir -p "$H/state/blocked-resolver/tproj"
  printf 'ticket/TK-91\n' > "$T/prbranch"; osha ticket/TK-91 > "$T/prhead"
  jq -nc --argjson m "$2" '{project:"tproj",rkey:"tproj-TK-91",mechanicals:$m,fixrounds:0,rebuilds:0,regens:0,outcome:"",attempts:[]}' \
    > "$H/state/blocked-resolver/tproj/tproj-TK-91.json"
  rm -f "$H/state/blocked-resolver/tproj/tproj-TK-91.setup-alerted"
  # Each case is a fresh project episode too: 4a+4b write 3 setup blocks in the
  # hour, which trips the project rate alert, and its 24 h hold sends no
  # per-park page (BH-7630 br_setup_rate, comment 6315926752).
  rm -f "$H/state/blocked-resolver/tproj/setup-blocked.tsv" "$H/state/blocked-resolver/tproj/setup-blocked.alerted"
  ROW "o/tproj#91" "$1" "$U91"
  : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/lane-alert.txt"; : > "$T/rebase.txt"; : > "$H/logs/blocked-resolver.log"
}
spent() { STATEJSON tproj-TK-91 | jq -r '[.mechanicals,.fixrounds,.rebuilds]|@csv'; }

# 4a. rung 1, a reason logged during this call.
park91 "conflict-unresolvable: CONFLICT (content): a.txt" 0
printf 'merge failed — Committer identity unknown *** Please tell me who you are.\n' > "$T/rebase-why"
RUN
[ -s "$T/rebase.txt" ] && ok || bad "(4a) fixture: rung 1 must call mc_rebase (log: $(tail -3 "$H/logs/blocked-resolver.log"))"
grep -q 'Committer identity unknown' "$T/lane-alert.txt" && ok || bad "(4a) the alert must name the logged reason: $(cat "$T/lane-alert.txt")"
grep -q 'clone or credential' "$T/lane-alert.txt" && bad "(4a) the alert must not say 'clone or credential'" || ok
grep -q 'mechanical rung cannot START' "$T/lane-alert.txt" && ok || bad "(4a) the alert must name the rung"
grep -q 'the cause in that merge-conductor.log line fixed' "$T/lane-alert.txt" && ok || bad "(4a) the alert's need must point at the log line: $(cat "$T/lane-alert.txt")"
[ "$(grep -c . "$T/lane-alert.txt")" = 1 ] && ok || bad "(4a) exactly one alert, got $(grep -c . "$T/lane-alert.txt")"
[ "$(spent)" = "0,0,0" ] && ok || bad "(4a) a setup block spends nothing, got $(spent)"
[ -s "$T/closed.txt" ] && bad "(4a) rc 4 must not close the PR" || ok
# A second tick of the same episode (the .setup-alerted marker stands): no second alert.
[ -e "$H/state/blocked-resolver/tproj/tproj-TK-91.setup-alerted" ] && ok || bad "(4a) the episode marker must be written"
: > "$T/rebase.txt"; RUN
[ -s "$T/rebase.txt" ] && ok || bad "(4a) fixture: the second tick must call mc_rebase again"
[ "$(grep -c . "$T/lane-alert.txt")" = 1 ] && ok || bad "(4a) the second tick must not page again, got $(grep -c . "$T/lane-alert.txt") alerts"
[ "$(spent)" = "0,0,0" ] && ok || bad "(4a) the second tick spends nothing, got $(spent)"

# 4b. rung 1, nothing logged during this call (an older tick's line is in the log).
park91 "conflict-unresolvable: CONFLICT (content): a.txt" 0
printf '%s %s rebase: merge failed — an older tick\n' "2026-10-21 00:00:00Z" "$U91" >> "$MCL"
: > "$T/rebase-why"
RUN
[ -s "$T/rebase.txt" ] && ok || bad "(4b) fixture: rung 1 must call mc_rebase"
grep -q 'logged no reason' "$T/lane-alert.txt" && ok || bad "(4b) no line → 'logged no reason': $(cat "$T/lane-alert.txt")"
grep -q 'an older tick' "$T/lane-alert.txt" && bad "(4b) an earlier tick's line must not be named" || ok
grep -q 'clone or credential problem' "$T/lane-alert.txt" && bad "(4b) the old text must be gone" || ok
[ "$(spent)" = "0,0,0" ] && ok || bad "(4b) a setup block spends nothing, got $(spent)"

# 4c. rung 1b (the regenerate rung): a red-ci park with mechanicals=1.
park91 "red-ci-twice: still red on $(cut -c1-8 "$T/prhead") after its failed jobs were re-run once" 1
printf 'merge failed — regen reason fixture\n' > "$T/rebase-why"
RUN
if grep -q 'rung 1b regenerate' "$H/logs/blocked-resolver.log"; then
  ok
  grep -q 'regenerate rung cannot START\|regen rung cannot START' "$T/lane-alert.txt" && ok || bad "(4c) the alert must name the regen rung: $(cat "$T/lane-alert.txt")"
  grep -q 'regen reason fixture' "$T/lane-alert.txt" && ok || bad "(4c) the regen alert must name the logged reason: $(cat "$T/lane-alert.txt")"
  grep -q 'clone or credential' "$T/lane-alert.txt" && bad "(4c) the regen alert must not say 'clone or credential'" || ok
else
  bad "(4c) fixture: the regenerate rung did not run (log: $(tail -4 "$H/logs/blocked-resolver.log"))"
fi

PASS=$(grep -c '^ok$' "$TALLY"); FAIL=$(grep -c '^bad$' "$TALLY")
echo "mc-rebase-scratch-identity.bh-8003: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
