#!/bin/bash
# tests/ci-workflow-guard.bh-10228-test.sh — the merge guard of
# bin/render-ci-workflow.sh --write (BH-10228, slice C4 of BH-9704): a
# regenerate after a merge keeps both sides' new fragments, and it never
# writes over a .github/workflows/harness-ci.yml that a side edited by hand.
# Real git merges in scratch repos over a small config/harness-ci/ tree (top
# level blocks plus job dirs, the renderer's own layout rule), so each case
# controls every byte. P1 drives the conductor's own mc_regen_generated
# (bin/lib/mc/rebase.sh) through a Generated files row.
#   C0  --check rc 0 on this checkout (the render is today's file)
#   G1  plain tree, no merge state, stale render: rc 0, written
#   G2  in-progress merge: side a adds 120-lint/995-a.yml, side b adds
#       130-determinism/995-b.yml, each re-rendered: rc 0, both steps
#   G3  in-progress merge: side b touched only config/harness-ci/README.md: rc 0
#   G4  in-progress merge: side b edited a fragment AND re-rendered: rc 0
#   G5  a merge commit at HEAD (no MERGE_HEAD) of two clean sides: rc 0
#   G6  a train union: the render conflict took --theirs (one parent's render
#       verbatim) and committed, both parents clean: rc 0, every step
#   G7  the render already equals the fragment render, a side hand-edited it
#       earlier but the edit now lives in a fragment: rc 0 (no guard asked)
#   N1  in-progress merge: side b hand-appends `# HAND` to the render: rc 4,
#       the file is unchanged, stderr names b's commit
#   N2  side b adds a fragment, re-renders, then appends `# HAND`: rc 4
#   N3  a merge commit at HEAD where one parent hand-edited: rc 4
#   N4  a train union resolved by hand (no parent's render, not its
#       fragments' render): rc 4
#   N5  a stopped cherry-pick of a hand-edit commit (CHERRY_PICK_HEAD): rc 4
#   N6  a stopped rebase of a hand-edit commit (REBASE_HEAD): rc 4
#   C1  --check and print in the N1 merge state: the same rc as with no guard
#   M1  a guard that always says yes turns N1 red (the `# HAND` line is lost)
#   M2  a --write that always asks the guard turns G7 red
#   M3  a guard that does not descend into a union merge turns G6 red
#   P1  mc_regen_generated: a good conflicted merge gets one regenerate commit
#       with both steps; a hand edit is kept and the log says
#       `regenerate FAILED: bin/render-ci-workflow.sh --write`
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

RCW=bin/render-ci-workflow.sh
WF=.github/workflows/harness-ci.yml
FD=config/harness-ci

# ============================== C0 ==============================
RC=0; bash "$DIR/$RCW" --root "$DIR" --check >/dev/null 2>&1 || RC=$?
[ "$RC" = 0 ] && ok || bad "C0: $RCW --check must be rc 0 on this checkout, rc=$RC"

TOOL="$T/tool"; mkdir -p "$TOOL"
scratch_install_closure "$RCW" "$TOOL" >/dev/null || bad "closure install: $RCW"
SCRIPT="$TOOL/$RCW"
M1="$TOOL/bin/rcw-m1.sh"
sed 's/^rcw_guard() {$/rcw_guard() { return 0/' "$SCRIPT" > "$M1"
cmp -s "$M1" "$SCRIPT" && bad "M1: the mutant changed nothing"
M2="$TOOL/bin/rcw-m2.sh"
sed 's/cmp -s -- "\$TMP" "\$DST"; }/false; }/' "$SCRIPT" > "$M2"
cmp -s "$M2" "$SCRIPT" && bad "M2: the mutant changed nothing"
M3="$TOOL/bin/rcw-m3.sh"
sed 's/if \[ "\$taken" = 1 \]; then/if false; then/' "$SCRIPT" > "$M3"
cmp -s "$M3" "$SCRIPT" && bad "M3: the mutant changed nothing"

g()  { git -C "$R" -c user.email=t@fixture.test -c user.name=t -c commit.gpgsign=false "$@"; }
rw() { RC=0; ERR=$(bash "${1:-$SCRIPT}" --root "$R" --write 2>&1 >/dev/null) || RC=$?; }
# render: the real renderer's print mode (no guard) writes the workflow.
render() { bash "$SCRIPT" --root "$R" > "$R/$WF.tmp" && mv "$R/$WF.tmp" "$R/$WF"; }
in_sync() { cmp -s <(bash "$SCRIPT" --root "$R") "$R/$WF"; }
# frag <job dir> <NNN> <slug>: one step fragment.
frag() { printf '      - run: echo %s\n' "$3" > "$R/$FD/$1/$2-$3.yml"; }
hand() { printf '# HAND\n' >> "$R/$WF"; }

base() { # base <dir>: commit 1 on main, a consistent tree and render.
  R="$1"; scratch_rm "$R"; mkdir -p "$R/$FD/120-lint" "$R/$FD/130-determinism" "$R/.github/workflows"
  git -C "$R" init -q -b main
  printf 'name: ci\n' > "$R/$FD/000-preamble.yml"
  printf 'jobs:\n' > "$R/$FD/030-jobs.yml"
  printf '# layout doc\n' > "$R/$FD/README.md"
  printf '  lint:\n    steps:\n' > "$R/$FD/120-lint/000-job.yml"
  frag 120-lint 010 checkout
  printf '  determinism:\n    steps:\n' > "$R/$FD/130-determinism/000-job.yml"
  frag 130-determinism 010 checkout
  render
  g add -A; g commit -qm base
}
# sides <b-kind>: branch a adds a lint step, branch b does <b-kind>; HEAD = a.
#   step   add a determinism step and re-render
#   readme edit README.md only
#   edit   edit a fragment and re-render
#   hand   append # HAND to the render, no fragment
#   both   add a step, re-render, then append # HAND
sides() {
  base "$1"
  g checkout -q -b a; frag 120-lint 995 a; render; g add -A; g commit -qm a
  g checkout -q main; g checkout -q -b b
  case "$2" in
    step)   frag 130-determinism 995 b; render ;;
    readme) printf '# more doc\n' >> "$R/$FD/README.md" ;;
    edit)   frag 130-determinism 010 checkout-v2; rm "$R/$FD/130-determinism/010-checkout.yml"; render ;;
    hand)   hand ;;
    both)   frag 130-determinism 995 b; render; hand ;;
  esac
  g add -A; g commit -qm b
  B_SHA=$(g rev-parse HEAD)
  g checkout -q a
}
# merge_open: merge b into a and leave it stopped (MERGE_HEAD set).
merge_open() {
  g merge -q --no-commit --no-ff --no-edit b >/dev/null 2>&1
  g rev-parse -q --verify MERGE_HEAD >/dev/null || bad "fixture $R: MERGE_HEAD must be set"
  cp "$R/$WF" "$T/before"
}

# ============================== G1 ==============================
base "$T/g1"; frag 120-lint 020 lint
in_sync && bad "G1 fixture: the render must be stale"
rw
[ "$RC" = 0 ] && grep -q 'echo lint' "$R/$WF" && in_sync && ok || bad "G1: a plain tree must write the stale render, rc=$RC err=[$ERR]"
R="$T/g1n"; scratch_rm "$R"; mkdir -p "$R/$FD" "$R/.github/workflows"
printf 'name: n\n' > "$R/$FD/000-preamble.yml"
rw
[ "$RC" = 0 ] && grep -q 'name: n' "$R/$WF" && ok || bad "G1: a tree with no git must write, rc=$RC err=[$ERR]"

# ============================== G2 / G3 / G4 ==============================
sides "$T/g2" step; merge_open; rw
[ "$RC" = 0 ] && grep -q 'echo a' "$R/$WF" && grep -q 'echo b' "$R/$WF" && in_sync && ok \
  || bad "G2: two step-adding sides must regenerate with both steps, rc=$RC err=[$ERR]"
sides "$T/g3" readme; merge_open; rw
[ "$RC" = 0 ] && in_sync && ok || bad "G3: a README-only side must not be refused, rc=$RC err=[$ERR]"
sides "$T/g4" edit; merge_open; rw
[ "$RC" = 0 ] && grep -q 'echo checkout-v2' "$R/$WF" && in_sync && ok || bad "G4: a side that edited a fragment and re-rendered must not be refused, rc=$RC err=[$ERR]"

# ============================== G5 / N3 ==============================
g5() { # g5 <b-kind>: commit the merge, HEAD is the merge commit.
  sides "$T/g5" "$1"; merge_open
  if [ -n "$(g diff --name-only --diff-filter=U)" ]; then g checkout --ours -- "$WF" 2>/dev/null; fi
  g add -A; g commit -q --no-edit >/dev/null 2>&1 || bad "G5/N3 fixture: the merge must commit"
  [ "$(g rev-list --parents -n1 HEAD | wc -w)" = 3 ] || bad "G5/N3 fixture: HEAD must be a merge commit"
  g rev-parse -q --verify MERGE_HEAD >/dev/null && bad "G5/N3 fixture: MERGE_HEAD must be gone"
  cp "$R/$WF" "$T/before"
  rw
}
g5 step
[ "$RC" = 0 ] && grep -q 'echo a' "$R/$WF" && grep -q 'echo b' "$R/$WF" && in_sync && ok \
  || bad "G5: a merge commit of two clean sides must regenerate, rc=$RC err=[$ERR]"
g5 hand
[ "$RC" = 4 ] && cmp -s "$T/before" "$R/$WF" && ok || bad "N3: a merge commit with a hand-edited parent must refuse, rc=$RC err=[$ERR]"

# ============================== N1 / N2 / M1 / C1 ==============================
n1() { sides "$T/n1" hand; merge_open; rw "$@"; }
n1
[ "$RC" = 4 ] && cmp -s "$T/before" "$R/$WF" && grep -q '^# HAND$' "$R/$WF" && ok \
  || bad "N1: a hand-edited side must refuse (rc 4) and keep # HAND, rc=$RC err=[$ERR]"
grep -q "refused: $WF was edited by hand on ${B_SHA:0:12}; move the edit into $FD/" <<<"$ERR" && ok \
  || bad "N1: the refusal must name the render, b's commit ${B_SHA:0:12} and the dir, err=[$ERR]"
# C1: --check and print do not run the guard, in this same merge state.
RC=0; bash "$SCRIPT" --root "$R" --check >/dev/null 2>&1 || RC=$?
[ "$RC" = 1 ] && ok || bad "C1: --check in the N1 state must report drift (rc 1), not the guard, rc=$RC"
RC=0; bash "$SCRIPT" --root "$R" >/dev/null 2>&1 || RC=$?
[ "$RC" = 0 ] && ok || bad "C1: print in the N1 state must be rc 0, rc=$RC"
cmp -s "$T/before" "$R/$WF" && ok || bad "C1: --check and print must not write"
n1 "$M1"
[ "$RC" = 0 ] && ! grep -q '^# HAND$' "$R/$WF" && ok || bad "M1: with no guard N1 must lose # HAND (else N1 proves nothing), rc=$RC"
sides "$T/n2" both; merge_open; rw
[ "$RC" = 4 ] && cmp -s "$T/before" "$R/$WF" && ok || bad "N2: a fragment plus a hand edit on one side must refuse, rc=$RC err=[$ERR]"

# ============================== N5 cherry-pick / N6 rebase ==============================
base "$T/n5"
g checkout -q -b h; hand; g commit -qam hand; H=$(g rev-parse HEAD)
g checkout -q main; frag 130-determinism 995 m; render; g add -A; g commit -qm m
g cherry-pick "$H" >/dev/null 2>&1 && bad "N5 fixture: the cherry-pick must stop on a conflict"
g rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null || bad "N5 fixture: CHERRY_PICK_HEAD must be set"
rw
[ "$RC" = 4 ] && ok || bad "N5: a stopped cherry-pick of a hand edit must refuse, rc=$RC err=[$ERR]"
g cherry-pick --abort >/dev/null 2>&1
base "$T/n6"
g checkout -q -b h; hand; g commit -qam hand
g checkout -q main; frag 130-determinism 995 m; render; g add -A; g commit -qm m
g checkout -q h
g rebase main >/dev/null 2>&1 && bad "N6 fixture: the rebase must stop on a conflict"
g rev-parse -q --verify REBASE_HEAD >/dev/null || bad "N6 fixture: REBASE_HEAD must be set"
cp "$R/$WF" "$T/before"
rw
[ "$RC" = 4 ] && cmp -s "$T/before" "$R/$WF" && ok || bad "N6: a stopped rebase of a hand edit must refuse and leave the file, rc=$RC err=[$ERR]"
g rebase --abort >/dev/null 2>&1

# ============================== G6 / N4 / M3 train union ==============================
g6() { # g6 [script]: 3 members, each adds a lint step; union takes --theirs.
  local n
  base "$T/g6"
  for n in 1 2 3; do g checkout -q main; g checkout -q -b "m$n"; frag 120-lint "99$n" "s$n"; render; g add -A; g commit -qm "m$n"; done
  g checkout -q main; g checkout -q -b union; CONFLICTS=0
  for n in 1 2 3; do
    if ! g merge -q --no-ff --no-edit "m$n" >/dev/null 2>&1; then
      CONFLICTS=$((CONFLICTS + 1))
      g checkout --theirs -- "$WF" 2>/dev/null; g add -A; g commit -q --no-edit >/dev/null 2>&1 || bad "G6 fixture: the --theirs union of m$n must commit"
    fi
  done
  [ "$CONFLICTS" = 2 ] || bad "G6 fixture: 3 members at one spot must give 2 render conflicts, got $CONFLICTS"
  in_sync && bad "G6 fixture: the --theirs render must not hold every step yet"
  rw "$@"
}
g6
[ "$RC" = 0 ] && in_sync && grep -q 'echo s1' "$R/$WF" && grep -q 'echo s2' "$R/$WF" && grep -q 'echo s3' "$R/$WF" && ok \
  || bad "G6: a train union that took --theirs must regenerate every step, rc=$RC err=[$ERR]"
g6 "$M3"
[ "$RC" = 4 ] && ok || bad "M3: a guard that does not descend into the union must refuse G6 (else G6 proves nothing), rc=$RC"
# N4: the union's render conflict is resolved by hand.
base "$T/n4"
g checkout -q -b m1; frag 120-lint 991 s1; render; g add -A; g commit -qm m1
g checkout -q main; g checkout -q -b m2; frag 120-lint 992 s2; render; g add -A; g commit -qm m2
g checkout -q main; g checkout -q -b union
g merge -q --no-ff --no-edit m1 >/dev/null 2>&1 || bad "N4 fixture: m1 must merge clean"
g merge -q --no-ff --no-edit m2 >/dev/null 2>&1 && bad "N4 fixture: m2 must conflict"
bash "$SCRIPT" --root "$R" > "$R/$WF.tmp" && mv "$R/$WF.tmp" "$R/$WF"; hand
g add -A; g commit -q --no-edit >/dev/null 2>&1 || bad "N4 fixture: the hand resolution must commit"
g checkout -q main; g checkout -q -b m3; printf 'c\n' > "$R/c.txt"; g add -A; g commit -qm m3
g checkout -q union; g merge -q --no-ff --no-edit m3 >/dev/null 2>&1 || bad "N4 fixture: m3 must merge clean"
cp "$R/$WF" "$T/before"
rw
[ "$RC" = 4 ] && cmp -s "$T/before" "$R/$WF" && grep -q '^# HAND$' "$R/$WF" && ok \
  || bad "N4: a union resolved by hand must refuse and keep the edit, rc=$RC err=[$ERR]"

# ============================== G7 / M2 ==============================
# The fix round of N3: the merge commit holds the hand edit, then the edit
# moves into a fragment, so the fragments reproduce the render byte for byte.
# Build G7 so the hand line is the last line of the last fragment.
g7() { # g7 [script]
  g5 hand >/dev/null
  last=$(cd "$R" && find "$FD" -name '*.yml' | LC_ALL=C sort | tail -1)
  printf '# HAND\n' >> "$R/$last"
  in_sync || bad "G7 fixture: the fragments must now reproduce the render"
  rw "$@"
}
g7
[ "$RC" = 0 ] && grep -q '^# HAND$' "$R/$WF" && ok || bad "G7: a render the fragments already reproduce must not be refused, rc=$RC err=[$ERR]"
g7 "$M2"
[ "$RC" = 4 ] && ok || bad "M2: without the no-change check G7 must be refused (else G7 proves nothing), rc=$RC"
grep -q "when $FD/ reproduces $WF byte for byte, --check is rc 0" <<<"$ERR" && ok || bad "M2: the refusal must say how to clear it, err=[$ERR]"

# ============================== P1 production entry ==============================
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/config"
scratch_install_closure bin/lib/merge-conductor-lib.sh "$T/h" >/dev/null || bad "closure install: bin/lib/merge-conductor-lib.sh"
cp "$DIR/config/generated-paths.conf" "$DIR/config/regenerated-paths.conf" "$T/h/config/"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh" || { echo "FAIL: cannot source the conductor lib"; exit 1; }
mc_init
MCLOG="$T/h/logs/merge-conductor.log"
p1base() { # the CI tree, plus the renderer and the shipped Generated files row
  base "$T/p1"
  mkdir -p "$R/docs/verification-map/index"
  scratch_install_closure "$RCW" "$R" >/dev/null || bad "P1 fixture: closure install of $RCW"
  { printf '## Generated files\n\n| path | regenerate with | committed |\n| --- | --- | --- |\n'
    grep -F "| \`$WF\` |" "$DIR/docs/verification-map/index/tail.md"; } > "$R/docs/verification-map/index/tail.md"
  grep -qF "| \`$WF\` |" "$R/docs/verification-map/index/tail.md" || bad "P1 fixture: the shipped tail.md must hold the $WF row"
  g add -A; g commit -qm tool
}
p1base
g checkout -q -b p; frag 120-lint 995 pr; render; g add -A; g commit -qm p
g checkout -q main; frag 120-lint 996 main; render; g add -A; g commit -qm m
g checkout -q p
g merge -q --no-edit main >/dev/null 2>&1 && bad "P1 fixture: the good merge must conflict on the render"
g checkout --ours -- "$WF" 2>/dev/null; g add -A; g commit -q --no-edit >/dev/null 2>&1 || bad "P1 fixture: the resolved merge must commit"
grep -q 'echo main' "$R/$WF" && bad "P1 fixture: the taken side must not hold main's step yet"
before=$(g rev-parse HEAD)
: > "$MCLOG"
mc_regen_generated "$R" main "P1 good"
grep -q 'regenerate FAILED' "$MCLOG" && bad "P1: a good merge must regenerate cleanly: $(cat "$MCLOG")" || ok
in_sync && grep -q 'echo pr' "$R/$WF" && grep -q 'echo main' "$R/$WF" && ok \
  || bad "P1: after mc_regen_generated the render must hold both steps"
[ "$(g rev-parse HEAD^)" = "$before" ] && ok || bad "P1: the good merge must add exactly one regenerate commit, got [$(g log -1 --format=%s)]"
[ -z "$(g status --porcelain)" ] && ok || bad "P1: the good merge must leave a clean tree: $(g status --porcelain)"
p1base
g checkout -q -b p; sed -i '1i # HAND' "$R/$WF"; g commit -qam hand
g checkout -q main; frag 130-determinism 995 bottom; render; g add -A; g commit -qm m
g checkout -q p; g merge -q --no-edit main >/dev/null 2>&1 || bad "P1 fixture: the hand-edit merge must be clean"
before=$(g rev-parse HEAD)
: > "$MCLOG"
mc_regen_generated "$R" main "P1 hand"
grep -q "regenerate FAILED: $RCW --write" "$MCLOG" && ok || bad "P1: the log must say regenerate FAILED: $RCW --write, log=[$(cat "$MCLOG")]"
[ "$(g rev-parse HEAD)" = "$before" ] && ok || bad "P1: a refused regenerate must add no commit"
grep -q '^# HAND$' "$R/$WF" && ok || bad "P1: the hand edit must still be in the render"

echo "ci-workflow-guard.bh-10228: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
