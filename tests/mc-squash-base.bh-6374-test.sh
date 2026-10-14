#!/bin/bash
# tests/mc-squash-base.bh-6374-test.sh — a stacked child whose base PR merged as
# a SQUASH merges main with the squash commit as the base of each add/add file
# (BH-6374 C1, scope item 5, acceptance A6).
#
# THE INCIDENT. project-6-os #209/#210/#211 were stacked on the TK-145.0
# contract branch. #201 merged that contract as a squash. Merging main into a
# child then found no common base for the files the contract created and called
# all three add/add, although main's only real change in them was one check. An
# operator ran `git merge-file <pr> <squash:file> <main:file>` by hand: 0
# conflicts.
#
# Driven through mc_resolve_conflicts (the call mc_rebase, rebase_job_run and the
# regen path all make) against REAL git merges.
#   Q1  A6: the child keeps its line AND main's edit, nothing unmerged, rc 0,
#       stdout empty, and MERGE_MSG carries the Union-resolved trailer
#   Q2  main added the path with content no branch commit had: no proof, rc 1,
#       the path listed, the worktree bytes exactly as git left them
#   Q3  proof holds but both sides changed the same line: rc 1
#   Q4  a content conflict (stage 1 present) is not this resolver's: rc 1
#   Q5  the Q1 shape on docs/x.md is resolved by the squash base, not glued by
#       the *.md union
#   Q6  MC_SQUASH_BASE_MERGE=0: today's behaviour, rc 1
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/config"
cp "$DIR/config/generated-paths.conf" "$DIR/config/regenerated-paths.conf" "$T/h/config/"
# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh"
mc_init
MCLOG="$T/h/logs/merge-conductor.log"
F=src/lib/meeting-notes/run.ts

g() { git -C "$R" "$@"; }
commit() { g add -A; g -c commit.gpgsign=false commit -qm "$1"; }
lines() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do printf 'line %s\n' "$i"; done; }
# mkstack <dir> <path> [main-adds-own] — main: base; ticket/parent: P1 adds
# <path>, P2 edits line 3; ticket/child (from P2): adds a line at the end;
# main: squash of the parent, then an edit of line 1. ticket/child checked out.
# With main-adds-own, main's squash adds <path> with content no branch had.
mkstack() {
  local own="${3:-}"
  R="$1"; scratch_rm "$R" || return 1
  mkdir -p "$R"; git -C "$R" init -q -b main
  g config user.email t@fixture.test; g config user.name t
  printf 'base\n' > "$R/README"; commit base
  g checkout -q -b ticket/parent
  mkdir -p "$R/$(dirname "$2")"
  lines > "$R/$2"; commit P1
  sed -i 's/^line 3$/line 3 parent/' "$R/$2"; commit P2
  g checkout -q -b ticket/child
  printf 'child line\n' >> "$R/$2"; commit C1
  g checkout -q main
  if [ -n "$own" ]; then
    mkdir -p "$R/$(dirname "$2")"; lines | sed 's/^line 3$/line 3 other/' > "$R/$2"; commit "own add"
  else
    g merge -q --squash ticket/parent >/dev/null 2>&1; commit "squash parent (#201)"
  fi
  sed -i 's/^line 1$/line 1 main/' "$R/$2"; commit "main edit (#204)"
  g checkout -q ticket/child
}
merge_main() { g -c commit.gpgsign=false merge -q --no-edit main >/dev/null 2>&1 && bad "$1: the fixture should conflict"; }

# ── Q1: A6 ──────────────────────────────────────────────────────────────────
mkstack "$T/q1" "$F"
merge_main Q1
[ "$(g ls-files -u -- "$F" | awk '{print $3}' | tr '\n' ' ')" = "2 3 " ] && ok || bad "Q1: expected an add/add (stages 2 3), got: $(g ls-files -u)"
: > "$MCLOG"
OUT=$(mc_resolve_conflicts "$R" ticket/child); RC=$?
[ "$RC" = 0 ] && ok || bad "Q1: rc 0 expected (rc $RC, left: $OUT) $(cat "$MCLOG")"
[ -z "$OUT" ] && ok || bad "Q1: stdout must be empty: $OUT"
[ -z "$(g ls-files -u)" ] && ok || bad "Q1: paths left unmerged: $(g ls-files -u)"
grep -qx 'child line' "$R/$F" && ok || bad "Q1: the child's line is lost: $(cat "$R/$F")"
grep -qx 'line 1 main' "$R/$F" && ok || bad "Q1: main's edit is lost: $(cat "$R/$F")"
grep -qx 'line 3 parent' "$R/$F" && ok || bad "Q1: the parent's edit is lost: $(cat "$R/$F")"
grep -Eq '^(<<<<<<<|=======|>>>>>>>)' "$R/$F" && bad "Q1: conflict markers left" || ok
[ "$(g show ":$F")" = "$(cat "$R/$F")" ] && ok || bad "Q1: the staged file is not the merged file"
SQ=$(g rev-parse --short=8 main~1)
grep -qxF "Union-resolved: $F (squash base $SQ, BH-6374)" "$R/.git/MERGE_MSG" && ok \
  || bad "Q1: no trailer in MERGE_MSG: $(cat "$R/.git/MERGE_MSG")"
grep -q "$F: add/add merged with the squash commit $SQ as the base" "$MCLOG" && ok || bad "Q1: no log line: $(cat "$MCLOG")"
g -c commit.gpgsign=false commit -q --no-edit >/dev/null 2>&1 && ok || bad "Q1: the resolved merge must commit"

# ── Q2: no proof ────────────────────────────────────────────────────────────
mkstack "$T/q2" "$F" own
merge_main Q2
BEFORE=$(sha1sum < "$R/$F")
: > "$MCLOG"
OUT=$(mc_resolve_conflicts "$R" ticket/child); RC=$?
[ "$RC" = 1 ] && ok || bad "Q2: rc 1 expected with no proof (rc $RC)"
grep -qxF "$F" <<<"$OUT" && ok || bad "Q2: the path must be in the conflict list: $OUT"
[ "$(sha1sum < "$R/$F")" = "$BEFORE" ] && ok || bad "Q2: the resolver changed the worktree file"
[ "$(g ls-files -u -- "$F" | awk '{print $3}' | tr '\n' ' ')" = "2 3 " ] && ok || bad "Q2: the index must be as git left it"
grep -q "$F: .*no proof" "$MCLOG" && ok || bad "Q2: the decline is logged: $(cat "$MCLOG")"

# ── Q3: proof, but both sides change the same line ─────────────────────────
mkstack "$T/q3" "$F"
sed -i 's/^line 1$/line 1 child/' "$R/$F"; commit C2
merge_main Q3
BEFORE=$(sha1sum < "$R/$F")
: > "$MCLOG"
OUT=$(mc_resolve_conflicts "$R" ticket/child); RC=$?
[ "$RC" = 1 ] && ok || bad "Q3: an overlapping edit stays a real conflict (rc $RC)"
grep -qxF "$F" <<<"$OUT" && ok || bad "Q3: the path must be listed: $OUT"
[ "$(sha1sum < "$R/$F")" = "$BEFORE" ] && ok || bad "Q3: the worktree file was changed"
grep -q "$F: .*merge-file conflict" "$MCLOG" && ok || bad "Q3: the decline is logged: $(cat "$MCLOG")"

# ── Q4: a content conflict (stage 1 present) ───────────────────────────────
R="$T/q4"; scratch_rm "$R"; mkdir -p "$R"; git -C "$R" init -q -b main
g config user.email t@fixture.test; g config user.name t
mkdir -p "$R/src"; lines > "$R/src/a.ts"; commit base
g checkout -q -b ticket/child; sed -i 's/^line 2$/line 2 child/' "$R/src/a.ts"; commit child
g checkout -q main; sed -i 's/^line 2$/line 2 main/' "$R/src/a.ts"; commit main
g checkout -q ticket/child
merge_main Q4
: > "$MCLOG"
OUT=$(mc_resolve_conflicts "$R" ticket/child); RC=$?
[ "$RC" = 1 ] && grep -qxF src/a.ts <<<"$OUT" && ok || bad "Q4: a content conflict is not resolved (rc $RC, out $OUT)"
# not this resolver's shape at all: it says nothing (no "no add" decline)
grep -q 'BH-6374' "$MCLOG" && bad "Q4: the squash-base resolver must not judge a stage-1 conflict: $(cat "$MCLOG")" || ok

# ── Q5: the Q1 shape on a *.md file ─────────────────────────────────────────
mkstack "$T/q5" docs/x.md
merge_main Q5
OUT=$(mc_resolve_conflicts "$R" ticket/child); RC=$?
[ "$RC" = 0 ] && ok || bad "Q5: rc 0 expected (rc $RC, $OUT)"
[ "$(grep -c '^line 2$' "$R/docs/x.md")" = 1 ] && ok || bad "Q5: the *.md union glued two copies: $(cat "$R/docs/x.md")"
grep -qx 'child line' "$R/docs/x.md" && grep -qx 'line 1 main' "$R/docs/x.md" && ok || bad "Q5: both changes kept: $(cat "$R/docs/x.md")"
grep -q 'squash base' "$R/.git/MERGE_MSG" && ok || bad "Q5: resolved by the squash base"

# ── Q6: the kill switch ────────────────────────────────────────────────────
mkstack "$T/q6" "$F"
merge_main Q6
OUT=$(MC_SQUASH_BASE_MERGE=0 mc_resolve_conflicts "$R" ticket/child); RC=$?
[ "$RC" = 1 ] && grep -qxF "$F" <<<"$OUT" && ok || bad "Q6: MC_SQUASH_BASE_MERGE=0 keeps today's real conflict (rc $RC, $OUT)"

echo "mc-squash-base: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
