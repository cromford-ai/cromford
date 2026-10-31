#!/bin/bash
# tests/evidence-files-base.bh-7114-test.sh — the PR evidence file list is this
# build's own diff, from the merge base with origin/<base> (BH-7114).
#
# THE DEFECT. Three writers filled $BUILD/changed-files.txt with
# `git diff --name-only "$BASE"...HEAD`, where $BASE is the LOCAL branch name.
# Every worktree of a hub checkout shares that local ref, and it moves once at
# build start. The pre-PR block rebases onto origin/$BASE, so after a sibling
# PR merges, `main...HEAD` takes the merge base with the OLD local main and the
# sibling's files land in this build's list, its tier pattern and its
# `| files |` row (project-6 #908: 28 listed, 17 real; #3049: 34 listed, 4 real).
#
# THE FIXTURE (no network): one bare origin, one hub clone with two worktrees
# (the shared-refs shape). Build A and build B fork from M0. B also trims
# tests/a-test.sh. B is squash-merged into origin's main (M1); the hub fetches,
# A rebases onto origin/main, and the hub's local main stays M0.
#
# The rb blocks are extracted VERBATIM from bin/lib/rb/*.sh, so the shipped
# lines are what runs here. The settle blocks of A and B run AT ONCE.
#
# determinism: ok-file branch-arm-ungated every git diff below runs in a scratch
# fixture repo built by this suite; none judges the branch under test.
# Run from anywhere: tests/evidence-files-base.bh-7114-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/diff-base.sh"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
G() { git -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

# The scratch HARNESS: the renderer and libs the rb blocks read, copied from
# this checkout. diff-base.sh is copied only when it exists, so the suite run
# against the old tree drives the old lines.
H="$T/h"; mkdir -p "$H/bin/lib" "$H/logs"
for S in bin/evidence-summary.sh bin/size-scope.sh bin/lib/evidence.sh; do
  scratch_install_closure "$S" "$H" >/dev/null || bad "could not install the closure of $S"
done
if [ -f "$LIB" ]; then
  scratch_install_closure bin/lib/diff-base.sh "$H" >/dev/null || bad "could not install bin/lib/diff-base.sh"
fi

# ── the fixture ──────────────────────────────────────────────────────────────
FX="$T/fx"; mkdir -p "$FX"
G init -q --bare "$FX/origin.git"
( cd "$FX" && G clone -q origin.git seed 2>/dev/null && cd seed || exit 1
  mkdir -p tests
  printf 'ok\nok\nok\nok\n' > tests/a-test.sh
  echo base > README.md
  G add -A && G commit -qm M0 && G push -q origin HEAD:main ) >/dev/null 2>&1
G clone -q "$FX/origin.git" "$FX/hub" >/dev/null 2>&1
G -C "$FX/hub" worktree add -q -b ta "$FX/wa" origin/main >/dev/null 2>&1
G -C "$FX/hub" worktree add -q -b tb "$FX/wb" origin/main >/dev/null 2>&1
M0=$(G -C "$FX/hub" rev-parse main)
( cd "$FX/wa" || exit 1; mkdir -p a
  for f in one two three; do echo "$f" > "a/$f.ts"; done
  G add -A && G commit -qm "A: three files" ) >/dev/null 2>&1
( cd "$FX/wb" || exit 1; mkdir -p b
  for f in 1 2 3 4 5 auth; do echo "$f" > "b/$f.ts"; done
  printf 'ok\nok\n' > tests/a-test.sh
  G add -A && G commit -qm "B: six files and a trimmed test" && G push -q origin tb ) >/dev/null 2>&1
# GitHub's squash merge: B's work lands on origin's main as a new commit M1.
( cd "$FX/seed" || exit 1
  G fetch -q origin && G merge -q --squash origin/tb && G commit -qm "B (#2)" && G push -q origin HEAD:main ) >/dev/null 2>&1
# The pre-PR shape: the hub fetches, A rebases onto origin/main, local main stays M0.
G -C "$FX/hub" fetch -q origin >/dev/null 2>&1
G -C "$FX/wa" rebase -q origin/main >/dev/null 2>&1
[ "$(G -C "$FX/hub" rev-parse main)" = "$M0" ] && ok || bad "fixture: the hub's local main moved"
[ "$(G -C "$FX/wa" merge-base HEAD origin/main)" = "$(G -C "$FX/hub" rev-parse origin/main)" ] \
  && ok || bad "fixture: A is not rebased onto origin/main"
A_FILES=$'a/one.ts\na/three.ts\na/two.ts'
B_FILES=$'b/1.ts\nb/2.ts\nb/3.ts\nb/4.ts\nb/5.ts\nb/auth.ts\ntests/a-test.sh'

# ── L: the lib ───────────────────────────────────────────────────────────────
# L1 pins the defect: the old line lists B's 7 files beside A's 3.
L1=$(cd "$FX/wa" && git diff --name-only main...HEAD | grep -c .)
[ "$L1" = 10 ] && ok || bad "L1: main...HEAD in A should list 10 files (the stale-base defect), got $L1"

if [ -f "$LIB" ]; then
  L2=$(cd "$FX/wa" && . "$LIB" && diff_changed_files main | sort)
  [ "$L2" = "$A_FILES" ] && ok || bad "L2: diff_changed_files main in A should be A's 3 files, got: $(tr '\n' ' ' <<<"$L2")"
  REF=$(cd "$FX/wa" && . "$LIB" && diff_base_ref main)
  [ "$REF" = origin/main ] && ok || bad "L2: diff_base_ref main should be origin/main, got '$REF'"
  # L2b: origin equal to local main: the two lists are equal.
  L2B=$(cd "$FX/wb" && . "$LIB" && diff_changed_files main | sort)
  L2BO=$(cd "$FX/wb" && git diff --name-only main...HEAD | sort)
  [ "$L2B" = "$B_FILES" ] && [ "$L2B" = "$L2BO" ] && ok || bad "L2b: B's list should be B's 7 files either way, got: $(tr '\n' ' ' <<<"$L2B")"
  # L3: no origin remote: today's behaviour.
  G clone -q "$FX/origin.git" "$FX/noorigin" >/dev/null 2>&1
  ( cd "$FX/noorigin" && G checkout -q -b x && echo z > z.ts && G add -A && G commit -qm z && G remote remove origin ) >/dev/null 2>&1
  L3=$(cd "$FX/noorigin" && . "$LIB" && diff_changed_files main)
  L3O=$(cd "$FX/noorigin" && git diff --name-only main...HEAD)
  [ "$L3" = z.ts ] && [ "$L3" = "$L3O" ] && ok || bad "L3: no origin should equal main...HEAD (z.ts), got '$L3' vs '$L3O'"
  REF=$(cd "$FX/noorigin" && . "$LIB" && diff_base_ref main)
  [ "$REF" = main ] && ok || bad "L3: diff_base_ref main with no origin should be main, got '$REF'"
  # L3b: a base already named origin/main resolves to itself.
  REF=$(cd "$FX/wa" && . "$LIB" && diff_base_ref origin/main)
  [ "$REF" = origin/main ] && ok || bad "L3b: diff_base_ref origin/main should be origin/main, got '$REF'"
  # L4: an unknown ref: git's nonzero rc, nothing printed.
  L4=$(cd "$FX/wa" && . "$LIB" && diff_changed_files no-such-branch 2>/dev/null); L4RC=$?
  [ "$L4RC" != 0 ] && [ -z "$L4" ] && ok || bad "L4: unknown ref should fail with no output (rc=$L4RC, out='$L4')"
  # L4b: unrelated history (no merge base): the three-dot fallback, git's rc.
  ( cd "$FX/wa" && G checkout -q --orphan lone && G rm -rqf . && echo l > lone.ts && G add -A && G commit -qm lone && G checkout -q ta ) >/dev/null 2>&1
  L4B=$(cd "$FX/wa" && . "$LIB" && diff_changed_files lone 2>/dev/null); L4BRC=$?
  L4BO=$(cd "$FX/wa" && git diff --name-only lone...HEAD 2>/dev/null); L4BORC=$?
  [ "$L4BRC" = "$L4BORC" ] && [ "$L4B" = "$L4BO" ] && ok || bad "L4b: no merge base should behave as lone...HEAD (rc $L4BRC vs $L4BORC)"
  # Sourcing prints nothing and survives set -u.
  [ -z "$(bash -c 'set -euo pipefail; . "$1"' _ "$LIB" 2>&1)" ] && ok || bad "L: sourcing the lib printed output or failed under set -euo pipefail"
else
  bad "L2-L4: bin/lib/diff-base.sh does not exist"
fi

# ── P1: the pr.sh tier lines, verbatim, in A ─────────────────────────────────
awk '/^TIER=1$/{f=1} f{print} f && /&& TIER=2$/{exit}' "$DIR/bin/lib/rb/pr.sh" > "$T/tier.sh"
grep -q 'CHANGED=' "$T/tier.sh" && ok || bad "P1: could not extract the pr.sh tier lines"
P1=$(cd "$FX/wa" && HARNESS="$H" BASE=main bash -c 'set -uo pipefail; . "$1"; printf "%s\n%s\n" "$TIER" "$CHANGED"' _ "$T/tier.sh" 2>"$T/p1.err")
P1_TIER=$(head -1 <<<"$P1"); P1_CH=$(tail -n +2 <<<"$P1" | sort)
[ "$P1_CH" = "$A_FILES" ] && ok || bad "P1: CHANGED in A should be A's 3 files, got: $(tr '\n' ' ' <<<"$P1_CH")"
[ "$P1_TIER" = 1 ] && ok || bad "P1: TIER should stay 1 (B's b/auth.ts is not A's), got '$P1_TIER'"

# ── S1: the settle blocks of A and B, at once ────────────────────────────────
awk '/^# >>> evidence settle/{f=1;next} /^# <<< evidence settle/{exit} f' \
  "$DIR/bin/lib/rb/result.sh" > "$T/settle.sh"
grep -q 'changed-files' "$T/settle.sh" && ok || bad "S1: could not extract the evidence settle block"
mkbuild() { # mkbuild <dir> <planned files> <test>
  mkdir -p "$1"
  printf '%s\n' "$2" > "$1/planned-files.txt"
  printf 'stale\n' > "$1/changed-files.txt"
  printf 'ok %s\nHARNESS_EXIT: 0\n' "$3" > "$1/harness-suite.txt"
  printf '{"tamper":0,"repro":0,"intent":0,"e2e":"pass","migration":"none"}\n' > "$1/gates.json"
  printf '# plan\n\n## Acceptance tests\n\n- the suite %s passes\n' "$3" > "$1/plan.md"
}
mkbuild "$T/bA" "$A_FILES" tests/a-test.sh
mkbuild "$T/bB" "$B_FILES" tests/b-test.sh
settle() { # settle <worktree> <build>
  ( cd "$1" && HARNESS="$H" BUILD="$2" bash -c '
      set -uo pipefail
      STAMP() { echo TS; }; MERGE_NOTE_FOR() { :; }
      hold_push_verdict() { return 0; }; job_evidence_put() { return 0; }
      PROJECT=p; KEY=K; BASE=main; TIER=1; QA_NOTE=""; PR_URL=""; BRANCH=b
      . "$0"' "$T/settle.sh" 2>"$2/settle.err" )
}
settle "$FX/wa" "$T/bA" & PA=$!
settle "$FX/wb" "$T/bB" & PB=$!
wait "$PA"; wait "$PB"
SA=$(sort "$T/bA/changed-files.txt")
[ "$SA" = "$A_FILES" ] && ok || bad "S1: A's changed-files.txt should be A's 3 files, got: $(tr '\n' ' ' <<<"$SA")"
grep -qF '| files | 3 changed, 3 planned, 0 unplanned |' "$T/bA/evidence.md" 2>/dev/null \
  && ok || bad "S1: A's files row: $(grep '| files |' "$T/bA/evidence.md" 2>/dev/null || echo 'no evidence.md')"
grep -q 'b/' "$T/bA/evidence.md" "$T/bA/changed-files.txt" 2>/dev/null \
  && bad "S1: A's evidence names a b/ path" || ok
SB=$(sort "$T/bB/changed-files.txt")
[ "$SB" = "$B_FILES" ] && ok || bad "S1: B's changed-files.txt should be B's 7 files, got: $(tr '\n' ' ' <<<"$SB")"
grep -q '[^/]a/' "$T/bB/evidence.md" "$T/bB/changed-files.txt" 2>/dev/null \
  && bad "S1: B's evidence names an a/ path" || ok

# ── C1: the claim scorer's staging base (result.sh evidence demoter) ─────────
# B trimmed tests/a-test.sh 4 -> 2 and merged. A never touched it. Counted at
# the stale local main, A "staged" a test it never edited.
awk '/^# >>> evidence demoter/{f=1;next} /^# <<< evidence demoter/{exit} f' \
  "$DIR/bin/lib/rb/result.sh" > "$T/demoter.sh"
grep -q 'evidence_score' "$T/demoter.sh" && ok || bad "C1: could not extract the evidence demoter block"
demote() { # demote <worktree> <build>
  ( cd "$1" && HARNESS="$H" BUILD="$2" ALERTS="$T/alerts.log" bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      PROJECT=p; KEY=K; BASE=main; TIER=1; QA_NOTE=""
      . "$0"' "$T/demoter.sh" 2>"$2/demote.err" )
}
demote "$FX/wa" "$T/bA" & PA=$!
demote "$FX/wb" "$T/bB" & PB=$!
wait "$PA"; wait "$PB"
C1=$(jq -r '.claims[0].verdict + " " + .claims[0].artifact' "$T/bA/evidence.json" 2>/dev/null)
case "$C1" in
  "CONFIRMED harness-suite.txt:"*) ok ;;
  *) bad "C1: A's claim for tests/a-test.sh should be CONFIRMED from harness-suite.txt, got '$C1' ($(jq -r '.claims[0].note' "$T/bA/evidence.json" 2>/dev/null))" ;;
esac
grep -q 'tests/b-test.sh' "$T/bA/evidence.json" 2>/dev/null && bad "C1: A's evidence.json names tests/b-test.sh" || ok

# C1b: the review-stage scorer (review.sh evidence verdicts), same fixture.
awk '/^# >>> evidence verdicts/{f=1;next} /^# <<< evidence verdicts/{exit} f' \
  "$DIR/bin/lib/rb/review.sh" > "$T/verdicts.sh"
grep -q 'evidence_score' "$T/verdicts.sh" && ok || bad "C1b: could not extract the review evidence verdicts block"
rm -f "$T/bA/evidence.json"
( cd "$FX/wa" && HARNESS="$H" BUILD="$T/bA" bash -c '
    set -uo pipefail
    STAMP() { echo TS; }
    PROJECT=p; KEY=K; BASE=main; GATES_NOTE=""
    . "$0"' "$T/verdicts.sh" 2>"$T/bA/verdicts.err" )
C1B=$(jq -r '.claims[0].verdict' "$T/bA/evidence.json" 2>/dev/null)
[ "$C1B" = CONFIRMED ] && ok || bad "C1b: the review-stage claim for tests/a-test.sh should be CONFIRMED, got '$C1B' ($(jq -r '.claims[0].note' "$T/bA/evidence.json" 2>/dev/null))"

# ── R1: every writer and both scorer call sites use the lib ──────────────────
for f in pr.sh result.sh execute.sh; do
  grep -q 'diff_changed_files "\$BASE"' "$DIR/bin/lib/rb/$f" && ok || bad "R1: bin/lib/rb/$f does not call diff_changed_files"
done
for f in result.sh review.sh; do
  grep -q 'EV_BASE=$(diff_base_ref "$EV_BASE")' "$DIR/bin/lib/rb/$f" \
    && grep -q 'evidence_score "$BUILD" "$BUILD/plan.md" "$EV_BASE"' "$DIR/bin/lib/rb/$f" \
    && ok || bad "R1: bin/lib/rb/$f does not pass diff_base_ref to evidence_score"
done

echo "evidence-files-base.bh-7114-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
