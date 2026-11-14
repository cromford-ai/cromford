#!/bin/bash
# tests/prequeue-equals-batch.bh-9697-test.sh — BH-9697 (Part D of BH-9582):
# the pre-queue selection gate runs on the PR merged with fresh main, so the
# gate tests what the merge-queue batch tests.
#
# PINNED. The REAL bin/selection-gate.sh in a scratch repo whose main moved
# ahead of the ticket branch. The stub planner records the TI_BASE it got, the
# HEAD of the tree it ran in and `git diff --name-only $TI_BASE HEAD` there, and
# selects the tests/*.sh files of that diff plus tests/x.sh. The stub runner
# records its tree's HEAD and that commit's parents.
#   P1  knob 1, main ahead, no conflict: fresh-main: on <main12>, base: = main,
#       head: = the PR head, the runner's HEAD has parents (PR head, main)
#   P1b the same through a real fetch of origin's main (no FRESH_REF)
#   P2  the planner's diff is `git diff main <merged>`; selection.txt equals a
#       direct planner run over that range (pre-queue set == batch set)
#   P3  HEAD contains main: off (head already contains main <12>), runner on HEAD
#   P4  a conflicting edit: off (head conflicts with main <12>), runner on HEAD
#   P5  FRESH_REF=nope: off (cannot resolve nope); no origin: off (no origin
#       remote); an origin that cannot be fetched: off (fetch of origin main failed (rc N))
#   P6  knob unset: no fresh-main: line, the 10-line file. P6b knob 0, yes: no line
#   P7  after a green, a red, a could-not-run and a base-run case: no merged
#       worktree, no temp dir, no refs/harness/sg-fresh-main-* ref
#   P8  SELECTION_GATE_SUITE_REUSE=1, a stub bin/suite-reuse.sh that reuses X:
#       the runner is not sent X, reuse: names 1 reused, the stub ran in the merged tree
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-equals-batch.bh-9697-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SG="${SG:-$DIR/bin/selection-gate.sh}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
[ -r "$SG" ] || { echo "FAIL: $SG is missing"; exit 1; }
X=tests/x.sh

g() { git -C "$1" -c user.email=t@example.com -c user.name=t "${@:2}"; }
# The scratch repo: base on main (a.txt, two suites, a runner blob and a reuse
# stub for P8), the ticket branch adds tests/new.sh and b.txt, then main moves
# ahead with m.txt.
R="$T/repo"; mkdir -p "$R/tests" "$R/bin"
printf 'one\ntwo\n' > "$R/a.txt"; echo 'exit 0' > "$R/$X"; echo 'exit 0' > "$R/tests/y.sh"
echo '# fixture runner blob' > "$R/bin/remote-gate.sh"
cat > "$R/bin/suite-reuse.sh" <<'SH'
#!/bin/bash
[ "$1" = plan ] || { echo "suite-reuse: recorded 0 result(s) fixture"; exit 0; }
while [ $# -gt 0 ]; do case "$1" in --suites) in=$2 ;; --run) run=$2 ;; --reused) re=$2 ;; --reds) rd=$2 ;; --fingerprints) fp=$2 ;; esac; shift; done
pwd -P > "$REUSE_SEEN"
grep -vxF tests/x.sh "$in" > "$run"; printf 'tests/x.sh\tFP1\tbuilder\n' > "$re"; : > "$rd"; : > "$fp"
SH
chmod +x "$R/bin/suite-reuse.sh"
g "$R" init -q -b main; g "$R" add -A; g "$R" commit -qm base
MB=$(g "$R" rev-parse HEAD)
g "$R" checkout -q -b ticket/bh-1
echo 'exit 0' > "$R/tests/new.sh"; echo b > "$R/b.txt"; g "$R" add -A; g "$R" commit -qm change
HEADP=$(g "$R" rev-parse HEAD)
g "$R" checkout -q main; echo m > "$R/m.txt"; g "$R" add -A; g "$R" commit -qm 'main moves'
MAIN=$(g "$R" rev-parse HEAD)
g "$R" checkout -q ticket/bh-1
# R3: the ticket already merged main. R4: the ticket and main edit one line.
R3="$T/repo3"; cp -a "$R" "$R3"; g "$R3" merge -q --no-edit main
R4="$T/repo4"; cp -a "$R" "$R4"; printf 'ONE\ntwo\n' > "$R4/a.txt"; g "$R4" commit -qam 'ticket edits a'
g "$R4" checkout -q main; printf 'uno\ntwo\n' > "$R4/a.txt"; g "$R4" commit -qam 'main edits a'; g "$R4" checkout -q ticket/bh-1
MAIN4=$(g "$R4" rev-parse main)
# R1b: a clone whose origin is a bare copy of R (main ahead), no local main move.
git clone -q --bare "$R" "$T/origin.git"
# Its local main stays at the old base, so only the fetch can know main moved.
R1b="$T/repo1b"; git clone -q "$T/origin.git" "$R1b"; g "$R1b" checkout -q ticket/bh-1; g "$R1b" branch -f main "$MB"
# R5: no origin. R5f: an origin path that does not exist.
R5="$T/repo5"; cp -a "$R" "$R5"
R5f="$T/repo5f"; cp -a "$R" "$R5f"; g "$R5f" remote add origin "$T/no-such-origin.git"

cat > "$T/plan.sh" <<'SH'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; shift; done
d=$(git diff --name-only "$TI_BASE" HEAD)
[ -n "${STUB_DIR:-}" ] && { echo "$TI_BASE $(git rev-parse HEAD)" > "$STUB_DIR/plan.seen"; printf '%s\n' "$d" > "$STUB_DIR/plan.diff"; }
{ grep -E '^tests/[^/]+\.sh$' <<<"$d"; echo tests/x.sh; } | sort -u > "$out"
echo "mode=batch-selected" >> "$GITHUB_OUTPUT"; exit 0
SH
cat > "$T/runner.sh" <<'SH'
#!/bin/bash
if [ "$1" = --image-id ]; then echo "IMAGE registry.fly.io/bh-testhost-fixture:testhost-1"; exit 0; fi
tree="$1"; shift
echo "run $(git -C "$tree" rev-parse HEAD) $(git -C "$tree" rev-list --parents -n 1 HEAD | cut -d' ' -f2-) | $*" >> "$STUB_DIR/calls"
echo "IMAGE registry.fly.io/bh-testhost-fixture:testhost-1"
[ -f "$STUB_DIR/run.out" ] && cat "$STUB_DIR/run.out"
exit "$(cat "$STUB_DIR/run.rc" 2>/dev/null || echo 0)"
SH
chmod +x "$T/plan.sh" "$T/runner.sh"
run() {
  local c="$1" tr="$2"; shift 2
  mkdir -p "$T/$c/stub" "$T/$c/tmp" "$T/$c/h"
  env -u CI_QUARANTINE -u SELECTION_GATE_FRESH_MAIN -u SELECTION_GATE_FRESH_REF -u SELECTION_GATE_BASELINE_RUN \
    -u SELECTION_GATE_SUITE_REUSE -u SELECTION_GATE_SUITE_QUARANTINE \
    HARNESS="$T/$c/h" TMPDIR="$T/$c/tmp" REPO_SLUG= STUB_DIR="$T/$c/stub" CI_QUARANTINE=- \
    SELECTION_GATE_PLAN="$T/plan.sh" SELECTION_GATE_RUNNER="$T/runner.sh" \
    "$@" bash "$SG" --tree "$tr" --base main --out "$T/$c/out" > "$T/$c/stdout" 2>&1
  RC=$?
}
gv() { sed -n "s/^$2: //p" "$T/$1/out/gate.txt" 2>/dev/null; }
gate() { cat "$T/$1/out/gate.txt" 2>/dev/null; cat "$T/$1/stdout" 2>/dev/null; }
runhead() { awk '$1 == "run" { print $2; exit }' "$T/$1/stub/calls" 2>/dev/null; }
runparents() { awk '$1 == "run" { print $3 " " $4; exit }' "$T/$1/stub/calls" 2>/dev/null; }
# clean <case> <repo> — no worktree but the repo's own, no temp dir, no private ref.
clean() {
  [ "$(git -C "$2" worktree list --porcelain | grep -c '^worktree ')" = 1 ] \
    && [ -z "$(find "$T/$1/tmp" -mindepth 1 -maxdepth 1 2>/dev/null)" ] \
    && [ -z "$(git -C "$2" for-each-ref 'refs/harness/')" ]
}

# ── P1: main ahead, no conflict ──────────────────────────────────────────────
run p1 "$R" SELECTION_GATE_FRESH_MAIN=1 SELECTION_GATE_FRESH_REF=main
M1=$(runhead p1)
[ "$RC" = 0 ] && [ "$(gv p1 fresh-main)" = "on ${MAIN:0:12}" ] && [ "$(gv p1 base)" = "$MAIN" ] && [ "$(gv p1 head)" = "$HEADP" ] && ok \
  || bad "P1 fresh-main: on ${MAIN:0:12}, base = main, head = the PR head (exit $RC; $(gate p1))"
[ "$(runparents p1)" = "$HEADP $MAIN" ] && ok || bad "P1 the runner's HEAD $M1 has parents (PR head, main): '$(runparents p1)'"
[ "$(tail -n 1 "$T/p1/out/gate.txt")" = "fresh-main: on ${MAIN:0:12}" ] && ok || bad "P1 fresh-main: is the last line"
[ "$(cat "$T/p1/stub/plan.seen" 2>/dev/null)" = "$MAIN $M1" ] && ok || bad "P1 the planner saw TI_BASE=main and HEAD=merged: '$(cat "$T/p1/stub/plan.seen" 2>/dev/null)'"
[ -z "$(git -C "$R" for-each-ref --points-at "$M1")" ] && ok || bad "P1 a ref points at the merged commit"
clean p1 "$R" && ok || bad "P1 cleanup: $(git -C "$R" worktree list) | $(ls "$T/p1/tmp")"

run p1b "$R1b" SELECTION_GATE_FRESH_MAIN=1 SELECTION_GATE_FRESH_FETCH_S=30
[ "$RC" = 0 ] && [ "$(gv p1b fresh-main)" = "on ${MAIN:0:12}" ] && [ "$(runparents p1b)" = "$HEADP $MAIN" ] && ok \
  || bad "P1b a real fetch of origin main: on ${MAIN:0:12} (exit $RC; $(gate p1b))"
clean p1b "$R1b" && [ -z "$(git -C "$R1b" for-each-ref 'refs/harness/')" ] && ok || bad "P1b the private ref or worktree is left: $(git -C "$R1b" for-each-ref)"

# ── P2: the pre-queue selection equals a batch over main..merged ─────────────
[ "$(cat "$T/p1/stub/plan.diff")" = "$(git -C "$R" diff --name-only "$MAIN" "$M1")" ] && ok || bad "P2 the planner's diff is not main..merged"
grep -qxF b.txt "$T/p1/stub/plan.diff" && ! grep -qxF m.txt "$T/p1/stub/plan.diff" && ok || bad "P2 the diff holds the PR's file and not main's: $(cat "$T/p1/stub/plan.diff")"
mkdir -p "$T/p2/w" "$T/p2/stub"; git -C "$R" worktree add -q --detach "$T/p2/w/m" "$M1" 2>/dev/null
( cd "$T/p2/w/m" && TI_BASE="$MAIN" GITHUB_OUTPUT="$T/p2/gho" "$T/plan.sh" --out "$T/p2/sel" ) >/dev/null 2>&1
git -C "$R" worktree remove --force "$T/p2/w/m" >/dev/null 2>&1
[ -s "$T/p2/sel" ] && cmp -s "$T/p2/sel" "$T/p1/out/selection.txt" && grep -qxF tests/new.sh "$T/p1/out/selection.txt" && ok \
  || bad "P2 selection.txt differs from a direct batch run over main..merged: $(cat "$T/p1/out/selection.txt") vs $(cat "$T/p2/sel" 2>/dev/null)"

# ── P3: HEAD contains main ───────────────────────────────────────────────────
run p3 "$R3" SELECTION_GATE_FRESH_MAIN=1 SELECTION_GATE_FRESH_REF=main
[ "$RC" = 0 ] && [ "$(gv p3 fresh-main)" = "off (head already contains main ${MAIN:0:12})" ] && [ "$(runhead p3)" = "$(g "$R3" rev-parse HEAD)" ] && ok \
  || bad "P3 head contains main: off, runner on HEAD (exit $RC; $(gate p3))"

# ── P4: a conflict ───────────────────────────────────────────────────────────
run p4 "$R4" SELECTION_GATE_FRESH_MAIN=1 SELECTION_GATE_FRESH_REF=main
[ "$RC" = 0 ] && [ "$(gv p4 fresh-main)" = "off (head conflicts with main ${MAIN4:0:12})" ] && [ "$(runhead p4)" = "$(g "$R4" rev-parse HEAD)" ] && ok \
  || bad "P4 a conflict: off, runner on HEAD (exit $RC; $(gate p4))"
clean p4 "$R4" && ok || bad "P4 cleanup"

# ── P5: the ref or the fetch fails ───────────────────────────────────────────
run p5 "$R5" SELECTION_GATE_FRESH_MAIN=1 SELECTION_GATE_FRESH_REF=nope
[ "$(gv p5 fresh-main)" = "off (cannot resolve nope)" ] && [ "$(runhead p5)" = "$HEADP" ] && ok || bad "P5 FRESH_REF=nope ($(gate p5))"
run p5b "$R5" SELECTION_GATE_FRESH_MAIN=1
[ "$(gv p5b fresh-main)" = "off (no origin remote)" ] && [ "$(runhead p5b)" = "$HEADP" ] && ok || bad "P5b no origin ($(gate p5b))"
run p5c "$R5f" SELECTION_GATE_FRESH_MAIN=1 SELECTION_GATE_FRESH_FETCH_S=30
[[ "$(gv p5c fresh-main)" =~ ^off\ \(fetch\ of\ origin\ main\ failed\ \(rc\ [1-9][0-9]*\)\)$ ]] && [ "$(runhead p5c)" = "$HEADP" ] && clean p5c "$R5f" && ok \
  || bad "P5c an origin that cannot be fetched ($(gate p5c))"

# ── P6: the knob off ─────────────────────────────────────────────────────────
run p6 "$R" SELECTION_GATE_FRESH_REF=main
[ "$RC" = 0 ] && ! grep -q '^fresh-main:' "$T/p6/out/gate.txt" && [ "$(wc -l < "$T/p6/out/gate.txt")" = 10 ] && [ "$(runhead p6)" = "$HEADP" ] \
  && [ "$(gv p6 base)" = "$MB" ] && ok || bad "P6 knob unset: the 10-line file on HEAD ($(gate p6))"
for v in 0 yes; do
  run "p6$v" "$R" SELECTION_GATE_FRESH_MAIN="$v" SELECTION_GATE_FRESH_REF=main
  ! grep -q '^fresh-main:' "$T/p6$v/out/gate.txt" && [ "$(runhead "p6$v")" = "$HEADP" ] && ok || bad "P6b knob '$v' is off ($(gate "p6$v"))"
done

# ── P7: cleanup on every exit ────────────────────────────────────────────────
mkdir -p "$T/p7r/stub"; printf 'FAIL tests/x.sh (rc 1)\n' > "$T/p7r/stub/run.out"; echo 1 > "$T/p7r/stub/run.rc"
run p7r "$R" SELECTION_GATE_FRESH_MAIN=1 SELECTION_GATE_FRESH_REF=main
[ "$RC" = 1 ] && [ "$(gv p7r red)" = "$X" ] && clean p7r "$R" && ok || bad "P7 red: rc 1 and clean (exit $RC; $(gate p7r))"
mkdir -p "$T/p7c/stub"; echo 'RUNNER-FAILURE tests/x.sh' > "$T/p7c/stub/run.out"; echo 1 > "$T/p7c/stub/run.rc"
run p7c "$R" SELECTION_GATE_FRESH_MAIN=1 SELECTION_GATE_FRESH_REF=main
[ "$RC" = 3 ] && [ "$(gv p7c fresh-main)" = "on ${MAIN:0:12}" ] && clean p7c "$R" && ok || bad "P7 could-not-run: rc 3 and clean (exit $RC; $(gate p7c))"
mkdir -p "$T/p7b/stub"; printf 'FAIL tests/x.sh (rc 1)\n' > "$T/p7b/stub/run.out"; echo 1 > "$T/p7b/stub/run.rc"
run p7b "$R" SELECTION_GATE_FRESH_MAIN=1 SELECTION_GATE_FRESH_REF=main SELECTION_GATE_BASELINE_RUN=1
[ "$(gv p7b baseline)" = "ran 1 on ${MAIN:0:12} (0 cached)" ] && clean p7b "$R" && ok \
  || bad "P7 base run on main's tip, both worktrees gone ($(gate p7b); $(git -C "$R" worktree list))"
[ "$(awk '$1 == "run" { n++ } END { print n + 0 }' "$T/p7b/stub/calls")" = 2 ] && [ "$(awk '$1 == "run" && NR == 2 { print $2 }' "$T/p7b/stub/calls")" = "$MAIN" ] && ok \
  || bad "P7 the base run is on main's tip: $(cat "$T/p7b/stub/calls")"

# ── P8: the suite ledger reuses greens on the merged tree ────────────────────
run p8 "$R" SELECTION_GATE_FRESH_MAIN=1 SELECTION_GATE_FRESH_REF=main SELECTION_GATE_SUITE_REUSE=1 REUSE_SEEN="$T/p8/seen" REPO_SLUG=example-org/cromford
M8=$(runhead p8)
[ "$RC" = 0 ] && [[ "$(gv p8 reuse)" == "ran 1 reused 1 green, 0 red of 2 "* ]] && ok || bad "P8 reuse: 1 reused of 2 (exit $RC; $(gate p8))"
! grep -q "tests/x.sh" <<<"$(awk '$1 == "run"' "$T/p8/stub/calls")" && ok || bad "P8 the runner was sent X: $(cat "$T/p8/stub/calls")"
SEEN=$(cat "$T/p8/seen" 2>/dev/null)
[ -n "$SEEN" ] && [ "$SEEN" != "$(cd "$R" && pwd -P)" ] && [ "$(git -C "$R" rev-parse "$M8^1" 2>/dev/null)" = "$HEADP" ] && case "$SEEN" in "$(cd "$T/p8/tmp" && pwd -P)"/*) true ;; *) false ;; esac && ok \
  || bad "P8 the reuse helper ran in the merged worktree: '$SEEN'"
clean p8 "$R" && ok || bad "P8 cleanup"

echo "prequeue-equals-batch.bh-9697: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
