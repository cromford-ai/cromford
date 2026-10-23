#!/bin/bash
# tests/builder-push-once.bh-8049-test.sh — BH-8049: a build attempt on a branch
# that already has a PR pushes ONCE, at the end of the attempt. Every push to a
# PR branch starts the repo's PR CI and cancels the run before it, so the
# backup pushes after execute and after each fix round are deferred, the
# commits collect locally, and the end-of-attempt push carries them all.
#
#   A1/A2  one attempt, three fixups → one push; a second attempt → a second push
#   F1/F2  the exit flush: a no-op when nothing is new; a held ticket is not pushed
#   K      the po_active table (BUILD_PUSH_ONCE: pr | always | off)
#   K-old  a first build with no PR keeps its backup pushes (the old behavior)
#   C1     CKPT_START starts no checkpoint watcher while push-once is active
#   W      the wiring: gates.sh loads the lib, run-build.sh's EXIT trap flushes
#
# The functions under test are EXTRACTED from the real files (PUSH_BRANCH from
# bin/lib/rb/execute.sh, RB_PUSH and track_pushed from bin/lib/rb/gates.sh,
# CKPT_START from bin/lib/rb/plan.sh) and run beside the real
# bin/lib/push-once.sh. The remote is a local bare repo whose post-receive hook
# appends one line per push. hold_push is a stub that runs a real
# `git push --force-with-lease` to it. No network.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/builder-push-once.bh-8049-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# fn_src <file> <name> — the function's source, from its `name() {` line to the
# first line that is only `}` (or the same line, for a one-liner).
fn_src() {
  awk -v n="$2" '
    !f && index($0, n "()") == 1 { f = 1; print; if ($0 ~ /\}[[:space:]]*$/ && $0 !~ /\{[[:space:]]*(#.*)?$/) exit; next }
    f { print } f && /^}/ { exit }' "$DIR/$1"
}
for spec in "bin/lib/rb/execute.sh PUSH_BRANCH" "bin/lib/rb/gates.sh RB_PUSH" "bin/lib/rb/gates.sh track_pushed" "bin/lib/rb/plan.sh CKPT_START"; do
  read -r f n <<<"$spec"
  fn_src "$f" "$n" > "$T/fn-$n.sh"
  [ -s "$T/fn-$n.sh" ] && bash -n "$T/fn-$n.sh" 2>/dev/null || { bad "setup: could not extract $n from $f"; continue; }
  # shellcheck source=/dev/null
  . "$T/fn-$n.sh"
done
[ -f "$DIR/bin/lib/push-once.sh" ] || bad "setup: bin/lib/push-once.sh is missing"
# shellcheck source=bin/lib/push-once.sh
. "$DIR/bin/lib/push-once.sh" 2>/dev/null

# ── the environment the extracted functions run in ──────────────────────────
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
PROJECT=demo; KEY=BH-1; BRANCH=ticket/bh-1
STAMP() { echo 2026-10-22T00:00:00Z; }
GH_LIVE() { :; }
RB_TICKET_LOCK_GATE() { return 0; }
RB_HOLD_YIELD() { echo "HOLD_YIELD $1" >> "$BUILD/pipeline.log"; return 3; }
hold_push() { # hold_push [-u] <project> - <wt> <remote> <src> <dst> <lease>
  local up=() lease
  [ "$1" = -u ] && { up=(-u); shift; }
  [ -n "${HOLD_RC:-}" ] && return "$HOLD_RC"
  lease="$7"
  if [ "$lease" = new ]; then
    git -C "$3" push -q ${up[@]+"${up[@]}"} "$4" "$5:refs/heads/$6"
  else
    git -C "$3" push -q ${up[@]+"${up[@]}"} --force-with-lease="$6:$lease" "$4" "$5:refs/heads/$6"
  fi
}
unset -f lane_knob 2>/dev/null

# ── the fixture remote: one line in $T/pushes.txt per push it receives ─────
R="$T/remote.git"
git init -q --bare "$R"
printf '#!/bin/sh\necho push >> "%s/pushes.txt"\n' "$T" > "$R/hooks/post-receive"; chmod +x "$R/hooks/post-receive"
git init -q -b main "$T/seed"
( cd "$T/seed" && echo base > f && git add f && git commit -qm base && git checkout -qb "$BRANCH" \
  && echo pr > g && git add g && git commit -qm "the PR's first commit" \
  && git remote add origin "$R" && git push -q origin main "$BRANCH" ) || { echo "setup: seed push failed"; exit 1; }
: > "$T/pushes.txt"
pushes() { grep -c '' "$T/pushes.txt"; }
remote_head() { git --git-dir="$R" rev-parse "refs/heads/$BRANCH"; }
# attempt <n> — a fresh clone of the PR branch, the way a build attempt starts
attempt() {
  git clone -q -b "$BRANCH" "$R" "$T/wt$1" && cd "$T/wt$1" || return 1
  BUILD="$T/b$1"; mkdir -p "$BUILD"; : > "$BUILD/pipeline.log"
  PO_DEFERRED=0
}
fixup() { echo "$1" >> f && git add f && git commit -qm "$1"; }

# ═══ A1: one attempt on an existing PR branch, three fixups → ONE push ══════
export BUILD_PUSH_ONCE=pr SQUASH_OK=0; unset RB_PR_OPEN
attempt 1 || exit 1
for i in 1 2 3; do
  fixup "fixup $i"
  PUSH_BRANCH "fix round $i"
  [ "$(pushes)" = 0 ] && ok || bad "A1: no push after fixup $i (got $(pushes))"
done
grep -q 'push-once: deferred push after fix round 3 — 3 commit(s) wait for the end-of-attempt push (BH-8049)' "$BUILD/pipeline.log" \
  && ok || bad "A1: the deferral line counts the waiting commits: $(cat "$BUILD/pipeline.log")"
RB_PUSH -u pr-push && track_pushed
[ "$(pushes)" = 1 ] && ok || bad "A1: the end-of-attempt push is exactly one push (got $(pushes))"
[ "$(remote_head)" = "$(git rev-parse HEAD)" ] && ok || bad "A1: the remote head is the local HEAD"
SUBJ=$(git --git-dir="$R" log --format=%s "refs/heads/$BRANCH")
grep -qx 'fixup 1' <<<"$SUBJ" && grep -qx 'fixup 2' <<<"$SUBJ" && grep -qx 'fixup 3' <<<"$SUBJ" \
  && ok || bad "A1: all three fixups are on the remote: $SUBJ"

# F1: the exit flush right after pr-push, nothing new → no push
PO_FLUSH_ON_EXIT; RC=$?
[ "$RC" = 0 ] && [ "$(pushes)" = 1 ] && ok || bad "F1: nothing new after pr-push → the flush pushes nothing (rc $RC, $(pushes) pushes)"
cd "$T" || exit 1

# ═══ A2: a retry attempt that ends early → its exit flush is ONE more push ══
attempt 2 || exit 1
fixup "retry fix"
PUSH_BRANCH execute
[ "$(pushes)" = 1 ] && ok || bad "A2: the retry's backup push is deferred too (got $(pushes))"
PO_FLUSH_ON_EXIT; RC=$?
[ "$RC" = 0 ] && [ "$(pushes)" = 2 ] && [ "$(remote_head)" = "$(git rev-parse HEAD)" ] && ok \
  || bad "A2: a second attempt makes a second push (rc $RC, $(pushes) pushes)"
grep -q "push-once: end-of-attempt push $(git rev-parse --short=12 HEAD) (exit)" "$BUILD/pipeline.log" \
  && ok || bad "A2: the flush logs its push: $(cat "$BUILD/pipeline.log")"
[ "$(git rev-parse "refs/remotes/origin/$BRANCH")" = "$(git rev-parse HEAD)" ] && ok || bad "A2: track_pushed after the flush"
PO_FLUSH_ON_EXIT; [ "$(pushes)" = 2 ] && ok || bad "A2: a second flush pushes nothing"
cd "$T" || exit 1

# ═══ F2: a held ticket → no push, one line, rc 0 ════════════════════════════
attempt 3 || exit 1
fixup "held fix"
PUSH_BRANCH execute
HOLD_RC=3 PO_FLUSH_ON_EXIT; RC=$?
[ "$RC" = 0 ] && [ "$(pushes)" = 2 ] && grep -q 'push-once: end-of-attempt push not pushed (3)' "$BUILD/pipeline.log" \
  && ok || bad "F2: a held flush pushes nothing, says so, rc 0 (rc $RC, $(pushes) pushes): $(cat "$BUILD/pipeline.log")"
grep -q 'HOLD_YIELD' "$BUILD/pipeline.log" && bad "F2: the flush never yields the build (no RESULT, no exit)" || ok
cd "$T" || exit 1

# ═══ K: the po_active table ═════════════════════════════════════════════════
# kcase <name> <want rc> <BUILD_PUSH_ONCE> <SQUASH_OK> [RB_PR_OPEN]
kcase() {
  local rc=0
  ( export BUILD_PUSH_ONCE="$3" SQUASH_OK="$4"; unset RB_PR_OPEN; [ -n "${5:-}" ] && RB_PR_OPEN="$5"; po_active ) || rc=$?
  [ "$rc" = "$2" ] && ok || bad "K $1: po_active want rc $2, got $rc"
}
kcase always        0 always 1
kcase pr+PR         0 pr 0
kcase pr+RB_PR_OPEN 0 pr 1 1
kcase pr+noPR       1 pr 1
kcase off           1 off 0
kcase garbage       0 garbage 0
kcase PR-upper      0 PR 0
kcase empty         0 "" 0
for v in PR garbage ""; do
  M=$(BUILD_PUSH_ONCE="$v" po_mode); [ "$M" = pr ] && ok || bad "K: po_mode '$v' reads as pr (got '$M')"
done
M=$(lane_knob() { echo off; }; BUILD_PUSH_ONCE=always po_mode); [ "$M" = off ] && ok || bad "K: the settings row (lane_knob) wins over the env (got '$M')"
# po_defer is rc 1 and writes nothing when push-once is off
( BUILD="$T/k"; mkdir -p "$BUILD"; export BUILD_PUSH_ONCE=off SQUASH_OK=0; po_defer x ) && bad "K: po_defer is rc 1 when off" || ok
[ ! -s "$T/k/pipeline.log" ] && ok || bad "K: po_defer off writes no line"

# ═══ K-old: a first build with no PR keeps its backup pushes ════════════════
export SQUASH_OK=1 BUILD_PUSH_ONCE=pr
attempt 4 || exit 1
for i in 1 2 3; do fixup "first-build fix $i"; PUSH_BRANCH "stage $i"; done
[ "$(pushes)" = 5 ] && ok || bad "K-old: pr + no PR pushes after each stage (want 5 total, got $(pushes))"
PO_FLUSH_ON_EXIT; [ "$(pushes)" = 5 ] && ok || bad "K-old: nothing deferred → the flush pushes nothing"
cd "$T" || exit 1

# ═══ C1: CKPT_START starts no watcher while push-once is active ═════════════
HARNESS="$T/hh"; mkdir -p "$HARNESS/bin"
printf '#!/bin/bash\necho "$*" >> "%s/ckpt-calls.txt"\n' "$T" > "$HARNESS/bin/lane-checkpoint.sh"; chmod +x "$HARNESS/bin/lane-checkpoint.sh"
CKPT_ON() { return 0; }
CKPT_ON_EXIT() { :; }
BUILD="$T/c1"; mkdir -p "$BUILD"; WT="$T/wt1"
export SQUASH_OK=0 BUILD_PUSH_ONCE=pr
CKPT_ACTIVE=0; CKPT_PID=""
CKPT_START
sleep 0.3
[ ! -e "$T/ckpt-calls.txt" ] && ok || bad "C1: no lane-checkpoint watcher while push-once is active: $(cat "$T/ckpt-calls.txt")"
[ "$CKPT_ACTIVE" = 0 ] && [ -z "$CKPT_PID" ] && ok || bad "C1: CKPT_ACTIVE stays 0 (got $CKPT_ACTIVE, pid '$CKPT_PID')"
[ -n "$(trap -p TERM)" ] && [ -n "$(trap -p INT)" ] && ok || bad "C1: the TERM/INT traps are still installed"
grep -q 'CHECKPOINT watcher not started: push-once defers pushes on a PR branch (BH-8049)' "$BUILD/pipeline.log" \
  && ok || bad "C1: one line says why: $(cat "$BUILD/pipeline.log" 2>/dev/null)"
trap - TERM INT
# the negative: push-once off → the watcher starts, as before
export BUILD_PUSH_ONCE=off
CKPT_START
sleep 0.3
[ "$CKPT_ACTIVE" = 1 ] && grep -q -- '--watch' "$T/ckpt-calls.txt" 2>/dev/null && ok || bad "C1: push-once off starts the watcher as before"
[ -n "$CKPT_PID" ] && { kill "$CKPT_PID" 2>/dev/null; wait "$CKPT_PID" 2>/dev/null; }
trap - TERM INT

# ═══ W: the wiring in the real pipeline (read flattened, tests/lib/rb-all.sh) ═
# shellcheck source=tests/lib/rb-all.sh
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || { bad "W: could not flatten the pipeline"; RB_ALL=/dev/null; }
grep -qE '^\[ -r "\$HARNESS/bin/lib/push-once.sh" \] && \. "\$HARNESS/bin/lib/push-once.sh"' "$RB_ALL" \
  && ok || bad "W: the pipeline (bin/lib/rb/gates.sh) loads bin/lib/push-once.sh"
grep -q 'CKPT_ON_EXIT; declare -F PO_FLUSH_ON_EXIT >/dev/null && PO_FLUSH_ON_EXIT;' <<<"$(grep -E "^trap '.*' EXIT" "$RB_ALL")" \
  && ok || bad "W: run-build.sh's EXIT trap flushes the deferred commits after CKPT_ON_EXIT"
grep -qE 'git( -C [^ ]+)? push' <<<"$(grep -n 'push' "$DIR/bin/lib/push-once.sh" 2>/dev/null | grep -v '^[0-9]*:[[:space:]]*#')" \
  && bad "W: push-once.sh has a raw git push (it must go through hold_push)" || ok

echo "builder-push-once.bh-8049: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
