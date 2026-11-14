#!/bin/bash
# tests/mc-state-paths-regen.bh-9426-test.sh — a stale PR that still edits
# catalog/state-paths.json, merged with a main where that file is a git-ignored
# render of catalog/state-paths.d/ (BH-8986), is resolved by the merge
# conductor and never reaches a human (BH-9426 scope 3).
#
# Driven through mc_resolve_conflicts, the function mc_rebase calls on every
# conflicted `git merge origin/<base>` (bin/lib/mc/rebase.sh). The merge here
# is the same command in the same orientation: the ticket branch is checked
# out and main is merged into it, so stage 2 is the branch and stage 3 is main.
#   E1  the conflict is only catalog/state-paths.json: rc 0, the path leaves
#       the index and the tree, the merge commits, no BLOCKED_HUMAN or
#       conflict-unresolvable line is written
#   E2  both sides edit the same fragment in catalog/state-paths.d/: a real
#       conflict, rc 1, the path is printed for the caller
#   E3  the mirror image (the BRANCH deleted it, main edited it) is never
#       taken: rc 1 (data-loss guard of mc_resolve_deleted_ignored)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/config"
scratch_install_closure bin/lib/merge-conductor-lib.sh "$T/h" >/dev/null || bad "closure install: bin/lib/merge-conductor-lib.sh"
cp "$DIR/config/generated-paths.conf" "$DIR/config/regenerated-paths.conf" "$T/h/config/"
[ -f "$T/h/bin/lib/mc/rebase.sh" ] || bad "closure: bin/lib/mc/rebase.sh missing"
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh" || { echo "FAIL: cannot source the conductor lib"; exit 1; }
mc_init
MCLOG="$T/h/logs/merge-conductor.log"
SP=catalog/state-paths.json

# mkrepo <dir> <branch> <mode>
#   stale: main moves state-paths.json to fragments + .gitignore; the branch
#          (cut before) edits state-paths.json
#   frag:  both sides already on fragments, both edit the same fragment line
#   mirror: the branch deletes + ignores state-paths.json, main edits it
mkrepo() {
  local R="$1" br="$2" mode="$3"
  scratch_rm "$R" || return 1
  mkdir -p "$R/catalog/state-paths.d"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@fixture.test; git -C "$R" config user.name t; git -C "$R" config commit.gpgsign false
  printf 'node_modules/\n' > "$R/.gitignore"
  if [ "$mode" = frag ]; then
    printf '{"path":"state/a","class":"x"}\n' > "$R/catalog/state-paths.d/0001-a.json"
    printf '%s\n' "$SP" >> "$R/.gitignore"
  else
    printf '[\n  {"path":"state/a","class":"x"}\n]\n' > "$R/$SP"
  fi
  git -C "$R" add -A; git -C "$R" commit -qm base
  git -C "$R" checkout -q -b "$br"
  case "$mode" in
    stale)  printf '[\n  {"path":"state/a","class":"x"},\n  {"path":"state/b","class":"y"}\n]\n' > "$R/$SP"
            git -C "$R" add -A ;;
    frag)   printf '{"path":"state/a","class":"branch"}\n' > "$R/catalog/state-paths.d/0001-a.json"; git -C "$R" add -A ;;
    mirror) git -C "$R" rm -q "$SP"; printf '%s\n' "$SP" >> "$R/.gitignore"; git -C "$R" add -A ;;
  esac
  git -C "$R" commit -qm branch
  git -C "$R" checkout -q main
  case "$mode" in
    stale)  git -C "$R" rm -q "$SP"; printf '%s\n' "$SP" >> "$R/.gitignore"
            printf '{"path":"state/a","class":"x"}\n' > "$R/catalog/state-paths.d/0001-a.json"
            printf '{"path":"state/c","class":"z"}\n' > "$R/catalog/state-paths.d/0002-c.json"
            git -C "$R" add -A ;;
    frag)   printf '{"path":"state/a","class":"main"}\n' > "$R/catalog/state-paths.d/0001-a.json"; git -C "$R" add -A ;;
    mirror) printf '[\n  {"path":"state/a","class":"main-edit"}\n]\n' > "$R/$SP"; git -C "$R" add -A ;;
  esac
  git -C "$R" commit -qm main
  git -C "$R" checkout -q "$br"
}
no_human() { # no_human <tag> — nothing in the conductor log or stdout sends it to a person
  if grep -Eq 'BLOCKED_HUMAN|conflict-unresolvable' "$MCLOG" 2>/dev/null || grep -Eq 'BLOCKED_HUMAN|conflict-unresolvable' <<<"$OUT"; then
    bad "$1: a BLOCKED_HUMAN / conflict-unresolvable line was written: $(cat "$MCLOG")"
  else ok; fi
}

# --- E1. THE TICKET'S CASE ------------------------------------------------------
R="$T/e1"; BR=ticket/bh-9001
mkrepo "$R" "$BR" stale
git -C "$R" merge -q --no-edit main >/dev/null 2>&1 && bad "E1 the fixture should conflict"
CONF=$(git -C "$R" diff --name-only --diff-filter=U | tr '\n' ' ')
[ "$CONF" = "$SP " ] && ok || bad "E1 expected a conflict on $SP alone, got: [$CONF]"
: > "$MCLOG"
OUT=$(mc_resolve_conflicts "$R" "$BR"); RC=$?
[ "$RC" = 0 ] && ok || bad "E1 a $SP-only conflict must resolve, not park (rc=$RC, left: $OUT) $(cat "$MCLOG")"
[ -z "$OUT" ] && ok || bad "E1 a resolved conflict prints nothing on stdout: [$OUT]"
[ -z "$(git -C "$R" ls-files -u)" ] && ok || bad "E1 paths left unmerged: $(git -C "$R" ls-files -u)"
git -C "$R" ls-files --error-unmatch -- "$SP" >/dev/null 2>&1 && bad "E1 $SP must leave the index (it is a git-ignored render on main)" || ok
[ ! -e "$R/$SP" ] && ok || bad "E1 $SP must leave the tree"
grep -q "$SP: deleted on the other side and git-ignored" "$MCLOG" && ok || bad "E1 no conductor log line for the resolve: $(cat "$MCLOG")"
git -C "$R" -c commit.gpgsign=false commit -q --no-edit >/dev/null 2>&1 && ok || bad "E1 the resolved merge must commit"
[ -f "$R/catalog/state-paths.d/0002-c.json" ] && ok || bad "E1 main's fragments must be in the merged tree"
no_human E1

# --- E2. a real fragment conflict still stops ----------------------------------
R="$T/e2"; BR=ticket/bh-9002
mkrepo "$R" "$BR" frag
git -C "$R" merge -q --no-edit main >/dev/null 2>&1 && bad "E2 the fixture should conflict"
: > "$MCLOG"
OUT=$(mc_resolve_conflicts "$R" "$BR"); RC=$?
[ "$RC" = 1 ] && ok || bad "E2 both sides editing one fragment is a REAL conflict and must return 1, rc=$RC"
grep -qxF catalog/state-paths.d/0001-a.json <<<"$OUT" && ok || bad "E2 the conflicted fragment must be printed for the caller: [$OUT]"
git -C "$R" merge --abort >/dev/null 2>&1

# --- E3. the mirror image is never taken ----------------------------------------
R="$T/e3"; BR=ticket/bh-9003
mkrepo "$R" "$BR" mirror
git -C "$R" merge -q --no-edit main >/dev/null 2>&1 && bad "E3 the fixture should conflict"
: > "$MCLOG"
OUT=$(mc_resolve_conflicts "$R" "$BR"); RC=$?
[ "$RC" = 1 ] && ok || bad "E3 a branch-side deletion of a file main edits must stay a conflict (data-loss guard), rc=$RC"
git -C "$R" merge --abort >/dev/null 2>&1

# --- M1. mutation: without the deleted-ignored step, E1 parks ------------------
R="$T/m1"; BR=ticket/bh-9004
mkrepo "$R" "$BR" stale
git -C "$R" merge -q --no-edit main >/dev/null 2>&1
OUT=$(mc_resolve_deleted_ignored() { return 1; }; mc_resolve_conflicts "$R" "$BR"); RC=$?
[ "$RC" = 1 ] && ok || bad "M1 with mc_resolve_deleted_ignored disabled E1 must park (else E1 proves nothing), rc=$RC"
git -C "$R" merge --abort >/dev/null 2>&1

echo "mc-state-paths-regen.bh-9426: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
