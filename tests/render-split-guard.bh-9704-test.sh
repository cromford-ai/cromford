#!/bin/bash
# tests/render-split-guard.bh-9704-test.sh — the merge guard of
# bin/render-split.sh --write: a regenerate after a merge keeps both sides'
# new fragments, and it never writes over a render a side edited by hand
# (BH-9704). Real git merges in a scratch repo; G9 drives the conductor's own
# mc_regen_generated (bin/lib/mc/rebase.sh) through a Generated files row.
#   G1  two branches each add one fragment, conflicted merge, --theirs, commit:
#       --write rc 0 and the render holds both blocks
#   G2  the PR side hand-edited the render: rc 4, the render is unchanged
#   G3  the PR side predates the split and edited the render: rc 4
#   G4  the PR side predates the split and did not touch the render: rc 0
#   G5  an in-progress conflicted merge, both sides consistent: rc 0
#   G6  the same, with the theirs side hand-edited: rc 4
#   G7  a plain tree, no merge, a stale render: rc 0, written
#   G8  a stopped cherry-pick of a hand-edit commit: rc 4
#   G9  mc_regen_generated: a conflicted good merge resolved by taking one side
#       gets one regenerate commit with both blocks; a hand edit is kept and
#       the log has `regenerate FAILED: bin/render-split.sh --write`
#   G10 the fix round of G3 on the merge commit: the fragments now reproduce
#       the render, so --write is rc 0 (nothing to drop)
#   G11 a stopped rebase of a hand-edit commit (REBASE_HEAD): rc 4
#   M4  a guard that always says yes turns G2, G3 and G6 red
#   M5  a --write that always asks the guard turns G10 red
#   G12 a batch train (batch-resolve build_union): members merge one by one
#       into a union branch, each render conflict takes --theirs and commits,
#       and --write runs once after the last merge. 3 members, 2 conflicts:
#       rc 0, the render is the union of every fragment. Also the 2+1 shape
#       (A, B conflicts, C unrelated) and a 2-conflict train ending in one
#       stopped merge (MERGE_HEAD)
#   G13 the same train with one member that hand-edited the render: rc 4,
#       and the refusal names that member's commit
#   G14 a union merge whose render conflict was resolved by hand (no parent's
#       render, not its fragments' render): rc 4
#   M6  a guard blind to REBASE_HEAD turns G11 red
#   M7  a guard that does not descend into a union merge commit turns G12 red
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

RS=bin/render-split.sh
# The shipped registry file and fragment dir are what G0 pins; the fixture
# below uses its own small split so each case controls every byte.
REG=catalog/splits.d/bh-9704-rb-plan.tsv
FDIR=config/rb-plan.d
[ -f "$DIR/$REG" ] && [ -d "$DIR/$FDIR" ] && ok || bad "G0: $REG and $FDIR/ must ship"

TOOL="$T/tool"; mkdir -p "$TOOL"
scratch_install_closure "$RS" "$TOOL" >/dev/null || bad "closure install: $RS"
SCRIPT="$TOOL/$RS"
M4="$TOOL/bin/render-split-m4.sh"
sed 's/^rs_guard() {$/rs_guard() { return 0/' "$SCRIPT" > "$M4"
cmp -s "$M4" "$SCRIPT" && bad "M4: the mutant changed nothing"

g()  { git -C "$R" -c user.email=t@fixture.test -c user.name=t -c commit.gpgsign=false "$@"; }
rw() { RC=0; ERR=$(bash "${1:-$SCRIPT}" --root "$R" --write 2>&1 >/dev/null) || RC=$?; }
render() { cat "$R"/f.d/*.txt > "$R/out/r.sh"; }
frag() { printf '# >>> %s\necho %s\n' "$2" "$2" > "$R/f.d/$1-$2.txt"; }

# base <dir> [split|presplit]: commit 1 on main. split = registry + fragments +
# render; presplit = the render alone (the tool's registry row is added by
# main's split commit later).
base() {
  R="$1"; scratch_rm "$R"; mkdir -p "$R/out" "$R/catalog/splits.d"
  git -C "$R" init -q -b main
  printf 'node_modules/\n' > "$R/.gitignore"
  if [ "${2:-split}" = split ]; then
    printf 'out/r.sh\tf.d/\t644\n' > "$R/catalog/splits.d/x.tsv"
    mkdir -p "$R/f.d"
    printf 'echo head\n' > "$R/f.d/0100-head.txt"
    frag 1300 x; frag 1400 y; frag 1500 z
    render
  else
    printf 'echo head\n# >>> x\necho x\n# >>> y\necho y\n# >>> z\necho z\n' > "$R/out/r.sh"
  fi
  g add -A; g commit -qm base
}
# split_on_main: main makes the byte-identical split of a presplit base.
split_on_main() {
  g checkout -q main
  printf 'out/r.sh\tf.d/\t644\n' > "$R/catalog/splits.d/x.tsv"
  mkdir -p "$R/f.d"; printf 'echo head\n' > "$R/f.d/0100-head.txt"; frag 1300 x; frag 1400 y; frag 1500 z
  cmp -s <(cat "$R"/f.d/*.txt) "$R/out/r.sh" || bad "fixture: the presplit render must equal the split"
  g add -A; g commit -qm split
}

# ============================== G1 ==============================
g1() { # g1 [script]
  base "$T/g1"
  g checkout -q -b a; frag 1350 a; render; g add -A; g commit -qm a
  g checkout -q main; g checkout -q -b b; frag 1360 b; render; g add -A; g commit -qm b
  g checkout -q a
  g merge -q --no-edit b >/dev/null 2>&1
  g checkout --theirs -- out/r.sh 2>/dev/null; g add -A; g commit -q --no-edit >/dev/null 2>&1
  [ "$(g rev-list --parents -n1 HEAD | wc -w)" = 3 ] || bad "G1 fixture: HEAD must be a merge commit"
  rw "$@"
}
g1
grep -q 'echo a' "$R/out/r.sh" && grep -q 'echo b' "$R/out/r.sh" && [ "$RC" = 0 ] && ok \
  || bad "G1: two entry-adding branches must merge through --write with both blocks, rc=$RC err=[$ERR]"
cmp -s <(cat "$R"/f.d/*.txt) "$R/out/r.sh" && ok || bad "G1: the render must equal the merged fragments"

# ============================== G2 ==============================
g2() {
  base "$T/g2"
  g checkout -q -b p; sed -i 's/^echo head$/echo HAND/' "$R/out/r.sh"; g commit -qam hand
  g checkout -q main; frag 1450 m; render; g add -A; g commit -qm main-adds
  g checkout -q p; g merge -q --no-edit main >/dev/null 2>&1 || bad "G2 fixture: the merge must be clean"
  cp "$R/out/r.sh" "$T/g2.before"
  rw "$@"
}
g2
[ "$RC" = 4 ] && ok || bad "G2: a hand edit on the PR side must refuse the write (rc 4), rc=$RC err=[$ERR]"
grep -q 'refused: out/r.sh was edited by hand on [0-9a-f]\{12\}; move the edit into f.d/' <<<"$ERR" && ok || bad "G2: the refusal must name the render, the side and the dir, err=[$ERR]"
cmp -s "$T/g2.before" "$R/out/r.sh" && grep -q 'echo HAND' "$R/out/r.sh" && ok || bad "G2: the render (with its hand edit) must be unchanged"
g2 "$M4"
[ "$RC" = 0 ] && ! grep -q 'echo HAND' "$R/out/r.sh" && ok || bad "M4: with no guard G2 must lose the hand edit (else G2 proves nothing), rc=$RC"

# ============================== G3 / G4 ==============================
g34() { # g34 <touch render 1|0> [script]
  local touch="$1"; shift
  base "$T/g34" presplit
  g checkout -q -b p
  if [ "$touch" = 1 ]; then sed -i 's/^echo y$/echo HAND/' "$R/out/r.sh"; else printf 'x\n' > "$R/other.txt"; g add -A; fi
  g commit -qam pre
  split_on_main
  g checkout -q p; g merge -q --no-edit main >/dev/null 2>&1 || bad "G3/G4 fixture: the merge must be clean"
  rw "$@"
}
g34 1
[ "$RC" = 4 ] && grep -q 'echo HAND' "$R/out/r.sh" && ok || bad "G3: a pre-split PR that edited the render must refuse (rc 4) and keep it, rc=$RC err=[$ERR]"
g34 1 "$M4"
[ "$RC" = 0 ] && ! grep -q 'echo HAND' "$R/out/r.sh" && ok || bad "M4: with no guard G3 must lose the edit (else G3 proves nothing), rc=$RC"
g34 0
[ "$RC" = 0 ] && ok || bad "G4: a pre-split PR that never touched the render must not be refused, rc=$RC err=[$ERR]"
cmp -s <(cat "$R"/f.d/*.txt) "$R/out/r.sh" && ok || bad "G4: the render must equal the fragments"

# ============================== G5 / G6 ==============================
g56() { # g56 <hand-edit theirs 1|0> [script]
  local hand="$1"; shift
  base "$T/g56"
  g checkout -q -b a; frag 1350 a; render; g add -A; g commit -qm a
  g checkout -q main; g checkout -q -b b; frag 1360 b; render
  [ "$hand" = 1 ] && sed -i 's/^echo z$/echo HAND/' "$R/out/r.sh"
  g add -A; g commit -qm b
  g checkout -q a
  g merge -q --no-edit b >/dev/null 2>&1 && bad "G5/G6 fixture: the merge must conflict"
  g rev-parse -q --verify MERGE_HEAD >/dev/null || bad "G5/G6 fixture: MERGE_HEAD must be set"
  [ -n "$(g diff --name-only --diff-filter=U)" ] || bad "G5/G6 fixture: the render must be unmerged"
  cp "$R/out/r.sh" "$T/g56.before"
  rw "$@"
}
g56 0
[ "$RC" = 0 ] && cmp -s <(cat "$R"/f.d/*.txt) "$R/out/r.sh" && ok || bad "G5: an in-progress merge of two consistent sides must write, rc=$RC err=[$ERR]"
g56 1
[ "$RC" = 4 ] && cmp -s "$T/g56.before" "$R/out/r.sh" && ok || bad "G6: a hand-edited theirs side must refuse and leave the file, rc=$RC err=[$ERR]"
g56 1 "$M4"
[ "$RC" = 0 ] && ok || bad "M4: with no guard G6 must write (else G6 proves nothing), rc=$RC"

# ============================== G7 ==============================
base "$T/g7"; frag 1300 x2
rw
[ "$RC" = 0 ] && grep -q 'echo x2' "$R/out/r.sh" && ok || bad "G7: a plain tree must write the stale render, rc=$RC err=[$ERR]"
R="$T/g7n"; scratch_rm "$R"; mkdir -p "$R/out" "$R/catalog/splits.d" "$R/f.d"
printf 'out/r.sh\tf.d/\t644\n' > "$R/catalog/splits.d/x.tsv"; frag 0100 n
rw
[ "$RC" = 0 ] && grep -q 'echo n' "$R/out/r.sh" && ok || bad "G7: a tree with no git must write, rc=$RC err=[$ERR]"

# ============================== G8 ==============================
base "$T/g8"
g checkout -q -b h; sed -i 's/^echo y$/echo HAND/' "$R/out/r.sh"; g commit -qam hand
H=$(g rev-parse HEAD)
g checkout -q main; frag 1400 y2; render; g add -A; g commit -qm y2
g cherry-pick "$H" >/dev/null 2>&1 && bad "G8 fixture: the cherry-pick must stop on a conflict"
g rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null && ok || bad "G8 fixture: CHERRY_PICK_HEAD must be set"
rw
[ "$RC" = 4 ] && ok || bad "G8: a cherry-pick of a hand edit must refuse, rc=$RC err=[$ERR]"
g cherry-pick --abort >/dev/null 2>&1

# ============================== G11 ==============================
# A rebase that stops on the hand-edit commit sets REBASE_HEAD (not
# MERGE_HEAD or CHERRY_PICK_HEAD), and HEAD is not a merge commit then.
g11() { # g11 [script]
  base "$T/g11"
  g checkout -q -b h; sed -i 's/^echo y$/echo HAND/' "$R/out/r.sh"; g commit -qam hand
  g checkout -q main; frag 1400 y2; render; g add -A; g commit -qm y2
  g checkout -q h
  g rebase main >/dev/null 2>&1 && bad "G11 fixture: the rebase must stop on a conflict"
  g rev-parse -q --verify REBASE_HEAD >/dev/null || bad "G11 fixture: REBASE_HEAD must be set"
  g rev-parse -q --verify MERGE_HEAD >/dev/null && bad "G11 fixture: MERGE_HEAD must not be set"
  cp "$R/out/r.sh" "$T/g11.before"
  rw "$@"
}
g11
[ "$RC" = 4 ] && cmp -s "$T/g11.before" "$R/out/r.sh" && ok || bad "G11: a stopped rebase of a hand edit must refuse and leave the file, rc=$RC err=[$ERR]"
g rebase --abort >/dev/null 2>&1
M6="$TOOL/bin/render-split-m6.sh"
sed 's/for ref in MERGE_HEAD CHERRY_PICK_HEAD REBASE_HEAD; do/for ref in MERGE_HEAD CHERRY_PICK_HEAD; do/' "$SCRIPT" > "$M6"
cmp -s "$M6" "$SCRIPT" && bad "M6: the mutant changed nothing"
g11 "$M6"
[ "$RC" = 0 ] && ok || bad "M6: a guard blind to REBASE_HEAD must write in G11 (else G11 proves nothing), rc=$RC"
g rebase --abort >/dev/null 2>&1

# ============================== G10 ==============================
# The fix round of G3: the pre-split PR merged main (HEAD is that merge commit)
# and then moved its hand edit into the fragment. The render already holds
# exactly those bytes, so --write drops nothing and must not be refused.
M5="$TOOL/bin/render-split-m5.sh"
sed 's/cmp -s -- "\$tmp" "\${REG_RENDER\[\$i\]}"; }/false; }/' "$SCRIPT" > "$M5"
cmp -s "$M5" "$SCRIPT" && bad "M5: the mutant changed nothing"
g10() { # g10 [script]
  g34 1 "$SCRIPT" >/dev/null
  [ "$(g rev-list --parents -n1 HEAD | wc -w)" = 3 ] || bad "G10 fixture: HEAD must be the merge commit"
  sed -i 's/^echo y$/echo HAND/' "$R/f.d/1400-y.txt"
  cmp -s <(cat "$R"/f.d/*.txt) "$R/out/r.sh" || bad "G10 fixture: the fragments must now reproduce the render"
  rw "$@"
}
g10
[ "$RC" = 0 ] && grep -q 'echo HAND' "$R/out/r.sh" && ok || bad "G10: a render the fragments already reproduce must not be refused, rc=$RC err=[$ERR]"
g10 "$M5"
[ "$RC" = 4 ] && ok || bad "M5: without the no-change check G10 must be refused (else G10 proves nothing), rc=$RC"
grep -q 'reproduces out/r.sh byte for byte, --check is rc 0' <<<"$ERR" && ok || bad "M5: the refusal must say how to clear it, err=[$ERR]"

# ============================== G12 / G13 / G14 batch train ==============================
# train <member spec>... : base, one branch per member off main, then a union
# branch merges them in order the way batch-resolve build_union does (take
# --theirs on a render conflict and commit). Spec: frag:<n>:<slug> adds a
# fragment and renders; other:<name> changes an unrelated file; hand:<slug>
# adds a fragment, renders, then hand-edits the render. CONFLICTS counts the
# merges that conflicted. last=open leaves the last merge stopped (MERGE_HEAD).
train() { # train <open|commit> <spec>...
  local last="$1" spec kind a b n=0 total; shift
  total=$#
  base "$T/train"
  for spec in "$@"; do
    n=$((n + 1)); IFS=: read -r kind a b <<<"$spec"
    g checkout -q main; g checkout -q -b "m$n"
    case "$kind" in
      frag)  frag "$a" "$b"; render ;;
      hand)  frag "$a" "$b"; render; sed -i 's/^echo head$/echo HAND/' "$R/out/r.sh" ;;
      other) printf '%s\n' "$a" > "$R/$a.txt" ;;
    esac
    g add -A; g commit -qm "m$n"
  done
  g checkout -q main; g checkout -q -b union
  CONFLICTS=0; n=0
  for spec in "$@"; do
    n=$((n + 1))
    if ! g merge -q --no-ff --no-edit "m$n" >/dev/null 2>&1; then
      CONFLICTS=$((CONFLICTS + 1))
      [ "$last" = open ] && [ "$n" = "$total" ] && break
      g checkout --theirs -- out/r.sh 2>/dev/null; g add -A; g commit -q --no-edit >/dev/null 2>&1 \
        || bad "train fixture: the --theirs resolution of m$n must commit"
    fi
  done
  M_HAND=$(g rev-parse -q --verify m2 2>/dev/null) || M_HAND=
  cp "$R/out/r.sh" "$T/train.before"
}
union_ok() { cmp -s <(cat "$R"/f.d/*.txt) "$R/out/r.sh"; }
g12() { # g12 [script]
  train commit frag:1350:a frag:1360:b frag:1370:c
  [ "$CONFLICTS" = 2 ] || bad "G12 fixture: 3 members at one spot must give 2 render conflicts, got $CONFLICTS"
  [ "$(g rev-list --parents -n1 HEAD | wc -w)" = 3 ] || bad "G12 fixture: HEAD must be the last union merge"
  union_ok && bad "G12 fixture: the --theirs render must not hold every block yet"
  rw "$@"
}
g12
[ "$RC" = 0 ] && union_ok && grep -q 'echo a' "$R/out/r.sh" && grep -q 'echo b' "$R/out/r.sh" && grep -q 'echo c' "$R/out/r.sh" && ok \
  || bad "G12: a 3-member train with 2 render conflicts must regenerate to every block, rc=$RC err=[$ERR]"
M7="$TOOL/bin/render-split-m7.sh"
sed 's/if \[ "\$taken" = 1 \]; then/if false; then/' "$SCRIPT" > "$M7"
cmp -s "$M7" "$SCRIPT" && bad "M7: the mutant changed nothing"
g12 "$M7"
[ "$RC" = 4 ] && ok || bad "M7: a guard that does not descend into the union must refuse G12 (else G12 proves nothing), rc=$RC"

train commit frag:1350:a frag:1360:b other:c
[ "$CONFLICTS" = 1 ] || bad "G12 fixture (2+1): one render conflict expected, got $CONFLICTS"
rw
[ "$RC" = 0 ] && union_ok && grep -q 'echo a' "$R/out/r.sh" && grep -q 'echo b' "$R/out/r.sh" && [ -f "$R/c.txt" ] && ok \
  || bad "G12 (2+1): the train with one unrelated member must regenerate, rc=$RC err=[$ERR]"

train open frag:1350:a frag:1360:b frag:1370:c
g rev-parse -q --verify MERGE_HEAD >/dev/null || bad "G12 fixture (open): MERGE_HEAD must be set"
rw
[ "$RC" = 0 ] && union_ok && grep -q 'echo c' "$R/out/r.sh" && ok \
  || bad "G12 (open): a stopped last merge over an earlier --theirs union must regenerate, rc=$RC err=[$ERR]"
g merge --abort >/dev/null 2>&1

train commit frag:1350:a hand:1360:b frag:1370:c
rw
[ "$RC" = 4 ] && cmp -s "$T/train.before" "$R/out/r.sh" && ok \
  || bad "G13: a train with a hand-edited member must refuse and leave the file, rc=$RC err=[$ERR]"
grep -q "edited by hand on ${M_HAND:0:12}" <<<"$ERR" && ok || bad "G13: the refusal must name the hand-edit member ${M_HAND:0:12}, err=[$ERR]"

g14() {
  train commit frag:1350:a
  g checkout -q main; g checkout -q -b m2; frag 1360 b; render; g add -A; g commit -qm m2
  g checkout -q union
  g merge -q --no-ff --no-edit m2 >/dev/null 2>&1 && bad "G14 fixture: the merge must conflict"
  { cat "$R"/f.d/*.txt; printf 'echo HAND\n'; } > "$R/out/r.sh"
  g add -A; g commit -q --no-edit >/dev/null 2>&1 || bad "G14 fixture: the hand resolution must commit"
  g checkout -q main; g checkout -q -b m3; printf 'c\n' > "$R/c.txt"; g add -A; g commit -qm m3
  g checkout -q union; g merge -q --no-ff --no-edit m3 >/dev/null 2>&1 || bad "G14 fixture: m3 must merge clean"
  cp "$R/out/r.sh" "$T/g14.before"
  rw
}
g14
[ "$RC" = 4 ] && cmp -s "$T/g14.before" "$R/out/r.sh" && grep -q 'echo HAND' "$R/out/r.sh" && ok \
  || bad "G14: a union merge resolved by hand must refuse and keep the edit, rc=$RC err=[$ERR]"

# ============================== G9 production entry ==============================
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/config"
scratch_install_closure bin/lib/merge-conductor-lib.sh "$T/h" >/dev/null || bad "closure install: bin/lib/merge-conductor-lib.sh"
cp "$DIR/config/generated-paths.conf" "$DIR/config/regenerated-paths.conf" "$T/h/config/"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh" || { echo "FAIL: cannot source the conductor lib"; exit 1; }
mc_init
MCLOG="$T/h/logs/merge-conductor.log"
g9base() { # the split repo, plus the tool and a Generated files row
  base "$T/g9"
  mkdir -p "$R/docs/verification-map/index"
  scratch_install_closure "$RS" "$R" >/dev/null || bad "G9 fixture: closure install of $RS"
  printf '## Generated files\n\n| path | regenerate with | committed |\n| --- | --- | --- |\n| `out/r.sh` | `%s --write` | committed |\n' "$RS" \
    > "$R/docs/verification-map/index/tail.md"
  g add -A; g commit -qm tool
}
# good merge: both sides add a block at the same spot, so the render
# conflicts. It is resolved the way a train resolves a declared path (take one
# side), which leaves main's block out of the render; only the regenerate can
# put it back.
g9base
g checkout -q -b p; frag 1450 pr; render; g add -A; g commit -qm p
g checkout -q main; frag 1460 main; render; g add -A; g commit -qm m
g checkout -q p
g merge -q --no-edit main >/dev/null 2>&1 && bad "G9 fixture: the good merge must conflict on the render"
g checkout --ours -- out/r.sh 2>/dev/null; g add -A; g commit -q --no-edit >/dev/null 2>&1 || bad "G9 fixture: the resolved merge must commit"
grep -q 'echo main' "$R/out/r.sh" && bad "G9 fixture: the taken side must not hold main's block yet"
before=$(g rev-parse HEAD)
: > "$MCLOG"
mc_regen_generated "$R" main "G9 good"
grep -q 'regenerate FAILED' "$MCLOG" && bad "G9: a good merge must regenerate cleanly: $(cat "$MCLOG")" || ok
cmp -s <(cat "$R"/f.d/*.txt) "$R/out/r.sh" && grep -q 'echo pr' "$R/out/r.sh" && grep -q 'echo main' "$R/out/r.sh" && ok \
  || bad "G9: after mc_regen_generated the render must equal the merged fragments, with both blocks"
[ "$(g rev-parse HEAD^)" = "$before" ] && g log -1 --format=%s | grep -q '^regenerate out/r.sh' && ok \
  || bad "G9: the good merge must add exactly one regenerate commit, got [$(g log -1 --format=%s)]"
[ -z "$(g status --porcelain)" ] && ok || bad "G9: the good merge must leave a clean tree: $(g status --porcelain)"
# hand-edit merge
g9base
g checkout -q -b p; sed -i 's/^echo head$/echo HAND/' "$R/out/r.sh"; g commit -qam hand
g checkout -q main; frag 1550 bottom; render; g add -A; g commit -qm m
g checkout -q p; g merge -q --no-edit main >/dev/null 2>&1 || bad "G9 fixture: the hand-edit merge must be clean"
before=$(g rev-parse HEAD)
: > "$MCLOG"
mc_regen_generated "$R" main "G9 hand"
grep -q "regenerate FAILED: $RS --write" "$MCLOG" && ok || bad "G9: the log must say regenerate FAILED: $RS --write, log=[$(cat "$MCLOG")]"
[ "$(g rev-parse HEAD)" = "$before" ] && ok || bad "G9: a refused regenerate must add no commit"
grep -q 'echo HAND' "$R/out/r.sh" && ok || bad "G9: the hand edit must still be in the render"

echo "render-split-guard.bh-9704: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
