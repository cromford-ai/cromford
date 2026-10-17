#!/bin/bash
# tests/blocked-resolver-dequeue-brief.bh-3719-test.sh — BH-3728 (BH-3719.0):
# a PR Mergify dequeued is a fix round whose brief is the dequeue-watch brief.
#
# THE CONTRACT. bin/blocked-resolver.sh gives the reason `queue-dequeued` the
# ci-red ladder class and a fix cap of exactly one round, and br_fix_round puts
# the record's `.dequeue.brief` (written by the dequeue-watch lane from
# bin/lib/dequeue-watch/classify.sh) at the head of the findings — so the agent
# is told what the scanner flagged and to reword it, never to allowlist it.
#
# Every round case drives the REAL script through its `--fix-here` entry, the
# way bin/fix-round-claim.sh invokes it, and asserts on the prompt the agent
# stub was handed.
#
# Cases:
#   R1  queue-dequeued + .dequeue.brief -> the brief is in the agent prompt
#   R2  queue-dequeued without .dequeue -> no brief, and the prompt is
#       byte-identical to the one origin/main's copy of the script produces
#   R3  br_ladder_class / br_fix_cap, extracted by name and driven
#   R4  red-ci-twice carrying .dequeue.brief -> the brief is NOT used
#   MR  the prepend deleted from a copy -> R1's assertion goes red
# Run from anywhere: tests/blocked-resolver-dequeue-brief.bh-3719-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
# The scripts this suite drives. The copy stays HERE so bin/test-impact.sh
# selects this suite when one of them changes.
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
cp "$DIR/bin/lib/hub-box.sh" "$DIR/bin/lib/heartbeat.sh" "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/" || exit 1
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes
fx_br_ladder_git "$DIR" "$T" || exit 1

# ---- the brief, from the real classifier lib and fixture ---------------------
CLASSIFY="$DIR/bin/lib/dequeue-watch/classify.sh"
FIXTURE="$DIR/tests/fixtures/dequeue-watch/log-gitleaks.txt"
BRIEF=""; FAILLINE=""
if [ -f "$CLASSIFY" ] && [ -f "$FIXTURE" ]; then
  # shellcheck source=bin/lib/dequeue-watch/classify.sh
  . "$DIR/bin/lib/dequeue-watch/classify.sh" || exit 1
  dqw_parse_log "$FIXTURE" > "$T/parsed.tsv"
  BRIEF=$(dqw_brief scanner-fp - tests/share-publish-clean.bh-795-test.sh "$T/parsed.tsv" -)
  FAILLINE=$(head -1 "$T/parsed.tsv" | cut -f2)
fi
[ -n "$BRIEF" ] && grep -qF '## Mergify dequeued this PR' <<<"$BRIEF" && ok "setup: dqw_brief produced a brief" \
  || bad "setup: no brief from $CLASSIFY over $FIXTURE (lib or fixture missing?)"
[ -n "$FAILLINE" ] && grep -qF -- "- $FAILLINE" <<<"$BRIEF" && ok "setup: the brief carries the fixture's FAIL line" \
  || bad "setup: the parsed FAIL line ('$FAILLINE') is not a bullet in the brief"

# ---- stubs this suite owns ---------------------------------------------------
# The agent records the prompt it was handed (argv 6 of agent-call.sh execute).
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/agent.txt"
printf '%s' "\$6" > "$T/prompt.txt"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
# origin/main's copy of the script, for R2's byte comparison.
git -C "$DIR" show origin/main:bin/blocked-resolver.sh > "$H/bin/blocked-resolver.main.sh" 2>/dev/null \
  || bad "setup: origin/main:bin/blocked-resolver.sh would not read"

PR91="https://github.com/o/tproj/pull/91"
LOGF="$H/logs/blocked-resolver.log"
# FIXHERE <script> <reason> — one hopped round, stdin is $T/rec-in.json.
FIXHERE() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BOX_NAME=box-tproj \
              bash "$1" --fix-here tproj dqw-1-abc "$2" "$PR91" - - < "$T/rec-in.json" ) 2>>"$T/run.log"; }
RESET() { # RESET [dequeue-brief]
  scratch_rm "$H/state/blocked-resolver"
  scratch_rm "$H/state/lane-gate"
  scratch_rm "$H/state/heartbeat"
  scratch_rm "$H/tmp/brfix"
  rm -f "$H/flags/all-off" "$H/flags/lane-off-"* "$H/flags/blocked-resolver-"* "$H/locks/blocked-resolver-cron.lock"
  : > "$LOGF"; : > "$H/logs/ALERTS.log"
  : > "$T/agent.txt"; rm -f "$T/prompt.txt"
  git -C "$T/repos/tproj" worktree prune >/dev/null 2>&1
  git -C "$T/repos/tproj" for-each-ref --format='%(refname:short)' refs/heads/brfix/ \
    | while read -r b; do git -C "$T/repos/tproj" branch -D "$b" >/dev/null 2>&1; done
  printf 'ticket/TK-91\n' > "$T/prbranch"; osha ticket/TK-91 | tr -d '\n' > "$T/prhead"
  printf 'Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated.\n' > "$T/findings"
  if [ $# -gt 0 ]; then
    jq -nc --arg b "$1" '{project:"tproj",rkey:"dqw-1-abc",fixrounds:0,rebuilds:0,mechanicals:0,outcome:"",attempts:[],dequeue:{brief:$b}}' > "$T/rec-in.json"
  else
    jq -nc '{project:"tproj",rkey:"dqw-1-abc",fixrounds:0,rebuilds:0,mechanicals:0,outcome:"",attempts:[]}' > "$T/rec-in.json"
  fi
}
# HASBRIEF — rc 0 when the prompt carries all three of the brief's markers.
HASBRIEF() {
  [ -s "$T/prompt.txt" ] || return 1
  grep -qF '## Mergify dequeued this PR' "$T/prompt.txt" || return 1
  grep -qF 'Never add an allowlist entry' "$T/prompt.txt" || return 1
  [ -n "$FAILLINE" ] && grep -qF -- "$FAILLINE" "$T/prompt.txt"
}

# ============================================================================
# R1. queue-dequeued with .dequeue.brief -> the brief reaches the agent
# ============================================================================
RESET "$BRIEF"
out=$(FIXHERE "$H/bin/blocked-resolver.sh" queue-dequeued)
[ -s "$T/prompt.txt" ] && ok "R1: the round reached the agent" \
  || bad "R1: the agent never ran (stdout: $out; log: $(tail -3 "$LOGF"))"
HASBRIEF && ok "R1: the prompt carries the dequeue brief (header, FAIL line, no-allowlist hint)" \
  || bad "R1: the dequeue brief is missing from the agent prompt"
if [ -s "$T/prompt.txt" ]; then
  awk '/^REVIEW FINDINGS AS POSTED ON THE PR:$/{f=1;next} f' "$T/prompt.txt" | grep -qF '## Mergify dequeued this PR' \
    && ok "R1: the brief sits under REVIEW FINDINGS AS POSTED ON THE PR:" \
    || bad "R1: the brief is not under the REVIEW FINDINGS header"
fi

# ============================================================================
# R2. queue-dequeued WITHOUT .dequeue -> exactly origin/main's prompt
# ============================================================================
RESET
FIXHERE "$H/bin/blocked-resolver.sh" queue-dequeued >/dev/null
cp "$T/prompt.txt" "$T/prompt-head.txt" 2>/dev/null || : > "$T/prompt-head.txt"
[ -s "$T/prompt-head.txt" ] && ok "R2: the round reached the agent" || bad "R2: the agent never ran ($(tail -3 "$LOGF"))"
grep -qF '## Mergify dequeued this PR' "$T/prompt-head.txt" && bad "R2: a record with no .dequeue must carry no brief" \
  || ok "R2: no dequeue header without .dequeue"
RESET
FIXHERE "$H/bin/blocked-resolver.main.sh" queue-dequeued >/dev/null
cp "$T/prompt.txt" "$T/prompt-main.txt" 2>/dev/null || : > "$T/prompt-main.txt"
# No normalisation needed: the prompt names the branch, slug, PR url, reason and
# the brief — never the brfix worktree path — and every one of those is fixed
# by the fixture.
# TEST-CHANGE (BH-7042): BH-7042 adds ONE sentence to the fix-round prompt on
# purpose (do not merge origin/main unless the branch conflicts). The byte
# comparison below removes exactly that sentence from BOTH sides and compares
# the rest, so any other drift still fails. It holds before and after BH-7042
# is on main. tests/main-merge-need.bh-7042-test.sh asserts the sentence itself.
BH7042_SENTENCE=' The harness has already merged what it needs; do not merge origin/main again unless this branch still conflicts with main: the merge queue tests every PR on current main, and a clean merge only makes a new head that loses its review and restarts CI.'
bh7042_strip() { local s; s=$(cat "$1" 2>/dev/null; printf x); s=${s%x}; printf '%s' "${s//"$BH7042_SENTENCE"/}" > "$2"; }
bh7042_strip "$T/prompt-head.txt" "$T/prompt-head.cmp"; bh7042_strip "$T/prompt-main.txt" "$T/prompt-main.cmp"
[ -s "$T/prompt-main.txt" ] && cmp -s "$T/prompt-head.cmp" "$T/prompt-main.cmp" \
  && ok "R2: the prompt is byte-identical to origin/main's" \
  || bad "R2: the prompt differs from origin/main's ($(diff "$T/prompt-main.cmp" "$T/prompt-head.cmp" | head -5))"

# ============================================================================
# R3. the classifier and the cap, extracted by name and driven
# ============================================================================
extract() { # extract <script> <out>
  : > "$2"
  for fn in br_num br_shape br_ladder_class br_fix_cap; do
    awk -v f="^$fn\\(\\)" '$0 ~ f {p=1} p{print} p&&/^}$/{exit}' "$1" >> "$2"
  done
}
# BH-5241: the corpus is the driver plus bin/lib/br/*.sh (tests/lib/br-corpus.sh),
# because the ladder functions moved out of the driver into bin/lib/br/ladder.sh.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$H" "$T/br-corpus.sh" || exit 1
extract "$T/br-corpus.sh" "$T/cls.sh"
# origin/main's side reads origin/main's corpus too: once this cut is on main,
# its driver alone no longer carries br_num/br_shape/br_fix_cap.
mkdir -p "$T/mainroot"
{ git -C "$DIR" archive origin/main bin/blocked-resolver.sh bin/lib/br | tar -x -C "$T/mainroot"; } 2>/dev/null
br_corpus "$T/mainroot" "$T/br-corpus-main.sh" \
  || { echo "FAIL: setup: origin/main's bin/blocked-resolver.sh + bin/lib/br would not read"; exit 1; }
extract "$T/br-corpus-main.sh" "$T/cls-main.sh"
grep -q '^br_fix_cap()' "$T/cls.sh" && grep -q '^br_shape()' "$T/cls.sh" && grep -q '^br_num()' "$T/cls.sh" \
  && ok "R3: extracted br_num/br_shape/br_ladder_class/br_fix_cap" || bad "R3: extraction came back short"
# MAX_FIXROUNDS=3 so the queue-dequeued arm is distinguishable from the default
# shape-driven cap (which answers 1 on an unset knob and would pass vacuously).
call() { MAX_FIXROUNDS=3 bash -c '. "$0"; shift; "$@"' "$@" 2>/dev/null; }
got=$(call "$T/cls.sh" x br_ladder_class queue-dequeued)
[ "$got" = ci-red ] && ok "R3: br_ladder_class queue-dequeued = ci-red" || bad "R3: br_ladder_class queue-dequeued = '${got:-empty}', want ci-red"
got=$(call "$T/cls.sh" x br_ladder_class red-ci-twice)
[ "$got" = ci-red ] && ok "R3: br_ladder_class red-ci-twice = ci-red" || bad "R3: br_ladder_class red-ci-twice = '${got:-empty}', want ci-red"
got=$(call "$T/cls.sh" x br_fix_cap '{}' queue-dequeued)
[ "$got" = 1 ] && ok "R3: br_fix_cap {} queue-dequeued = 1 (MAX_FIXROUNDS=3)" || bad "R3: br_fix_cap {} queue-dequeued = '${got:-empty}', want 1"
got=$(call "$T/cls.sh" x br_fix_cap '{}' '')
want=$(call "$T/cls-main.sh" x br_fix_cap '{}' '')
[ -n "$want" ] && [ "$got" = "$want" ] && ok "R3: br_fix_cap {} '' unchanged from origin/main ($got)" \
  || bad "R3: br_fix_cap {} '' = '$got', origin/main says '$want'"

# ============================================================================
# R4. red-ci-twice carrying .dequeue.brief -> the brief is NOT used
# ============================================================================
RESET "$BRIEF"
FIXHERE "$H/bin/blocked-resolver.sh" red-ci-twice >/dev/null
[ -s "$T/prompt.txt" ] && ok "R4: the red-ci-twice round reached the agent" \
  || bad "R4: the red-ci-twice round never reached the agent ($(tail -3 "$LOGF"))"
[ -s "$T/prompt.txt" ] && ! grep -qF '## Mergify dequeued this PR' "$T/prompt.txt" \
  && ok "R4: red-ci-twice ignores .dequeue.brief" || bad "R4: the dequeue brief leaked into a red-ci-twice round (or no prompt)"

# ============================================================================
# MR. mutation: the prepend deleted -> R1 goes red
# ============================================================================
sed '/if \[ "\$reason" = queue-dequeued \]; then/,/^  fi$/d' "$H/bin/blocked-resolver.sh" > "$H/bin/blocked-resolver.mut.sh"
if cmp -s "$H/bin/blocked-resolver.sh" "$H/bin/blocked-resolver.mut.sh"; then
  bad "MR: the mutation changed nothing — the queue-dequeued prepend is not in bin/blocked-resolver.sh"
else
  RESET "$BRIEF"
  FIXHERE "$H/bin/blocked-resolver.mut.sh" queue-dequeued >/dev/null
  [ -s "$T/prompt.txt" ] || bad "MR: the mutant's round never reached the agent — the kill would be vacuous"
  if [ -s "$T/prompt.txt" ]; then
    HASBRIEF && bad "MR: R1 still passes with the prepend deleted" || ok "MR: deleting the prepend turns R1 red"
  fi
fi

echo "blocked-resolver-dequeue-brief.bh-3719: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
