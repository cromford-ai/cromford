#!/bin/bash
# tests/changelog-fragment.bh-9096-test.sh — a build never edits
# docs/RECENT-CHANGES.md in its PR: the entry it added moves to its own
# fragment docs/recent-changes.d/<key>.md, so two builds never touch one hunk
# (BH-9096).
#
#   F1 a top entry + code -> one commit; the changelog equals the base; the
#      fragment is the added lines byte for byte; F1b two hunks -> one fragment,
#      hunks joined by one blank line; F1c an entry in the middle -> moved
#   F2 the `moved` line names the path and the fragment
#   F3 an entry plus an edit of an older line -> left, HEAD unchanged
#   F4 a changelog the build created -> left
#   F5 a diff only on the changelog -> left
#   F6 switch changelog-fragment-off -> no action
#   F7 the commit fails (index.lock) -> not claimed, HEAD and the tree as before
#   F8 a rerun with the same key -> no new commit, one fragment
#   F9 CHANGELOG_FRAGMENT_PATHS names another file -> that file moves, the
#      default does not; an unsafe key (../x) -> left
#   E1 the `# >>> changelog fragment` block of the pipeline, lifted and run on a
#      scratch repo, writes `changelog fragment: moved` to pipeline.log
#   M1 (acceptance 4) two branches each add a top entry; stripped, both merge
#      with no conflict; the same fixture unstripped conflicts (control)
#
# Each case has its own scratch repo and key. No network.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/rb-all.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIB="$DIR/bin/lib/changelog-fragment.sh"
CL=docs/RECENT-CHANGES.md
mkdir -p "$T/h/flags"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

BASE_CL='# Recent changes

## TK-10 — older entry
- line one
- line two

## TK-9 — oldest entry
- line three
'
# mkrepo <name> — main with the changelog and one code file; origin/main points
# at it; then a ticket branch.
mkrepo() {
  local r="$T/$1"
  scratch_rm "$r"; mkdir -p "$r/docs" "$r/src"
  git -C "$r" init -q -b main
  printf '%s' "$BASE_CL" > "$r/$CL"; echo base > "$r/src/base.ts"
  git -C "$r" add -A && git -C "$r" commit -qm base
  git -C "$r" update-ref refs/remotes/origin/main HEAD
  git -C "$r" checkout -qb ticket
}
# top <repo> <key> — insert an entry above the newest one (no blank line in it,
# so the diff has one alignment and the expected fragment is exact)
top() { python3 - "$1/$CL" "$2" <<'PY'
import sys
p, k = sys.argv[1], sys.argv[2]
lines = open(p).read().split("\n")
lines[2:2] = ["## %s — new entry" % k, "- did %s" % k]
open(p, "w").write("\n".join(lines))
PY
}
commit() { git -C "$1" add -A && git -C "$1" commit -qm "$2"; }
strip() { # strip <repo> <key> [env...] -> OUTMSG, rc in RC
  local r="$1" k="$2"; shift 2
  OUTMSG=$(cd "$r" && env -u CHANGELOG_FRAGMENT_PATHS HARNESS="$T/h" LANE_GATE_DISABLE=1 "$@" \
           bash -c '. "$1" || exit 90; clf_strip origin/main "$2" "$3"' _ "$LIB" "$k" "$T/build" 2>&1); RC=$?
}
mkdir -p "$T/build"

# ---------- F1 ----------
mkrepo f1; top "$T/f1" TK-1; echo x > "$T/f1/src/x.ts"; commit "$T/f1" "TK-1: work"
H0=$(git -C "$T/f1" rev-parse HEAD)
strip "$T/f1" TK-1
[ "$RC" = 0 ] && ok || bad "F1: clf_strip must return 0, rc=$RC out=[$OUTMSG]"
[ "$OUTMSG" = "moved $CL entry to docs/recent-changes.d/TK-1.md" ] && ok || bad "F2: the moved line: [$OUTMSG]"
[ "$(git -C "$T/f1" rev-list --count "$H0..HEAD")" = 1 ] && ok || bad "F1: exactly one new commit"
[ "$(git -C "$T/f1" show HEAD:$CL)" = "$(git -C "$T/f1" show origin/main:$CL)" ] && ok || bad "F1: HEAD's changelog must equal the base"
printf '## TK-1 — new entry\n- did TK-1\n' > "$T/f1.want"
git -C "$T/f1" show HEAD:docs/recent-changes.d/TK-1.md > "$T/f1.got" 2>/dev/null
cmp -s "$T/f1.want" "$T/f1.got" && ok || bad "F1: the fragment must be the added lines byte for byte: [$(cat "$T/f1.got")]"
[ -z "$(git -C "$T/f1" status --porcelain)" ] && ok || bad "F1: the tree must be clean: $(git -C "$T/f1" status --porcelain)"
[ "$(git -C "$T/f1" show HEAD:src/x.ts 2>/dev/null)" = x ] && ok || bad "F1: the code change must stay"

# ---------- F1b: two hunks ----------
mkrepo f3; top "$T/f3" TK-3
printf -- '- appended at the end\n' >> "$T/f3/$CL"
echo y > "$T/f3/src/y.ts"; commit "$T/f3" "TK-3: work"
strip "$T/f3" TK-3
[ "$OUTMSG" = "moved $CL entry to docs/recent-changes.d/TK-3.md" ] && ok || bad "F1b: message: [$OUTMSG]"
printf '## TK-3 — new entry\n- did TK-3\n\n- appended at the end\n' > "$T/f3.want"
git -C "$T/f3" show HEAD:docs/recent-changes.d/TK-3.md 2>/dev/null | cmp -s "$T/f3.want" - && ok \
  || bad "F1b: two hunks must join with one blank line: [$(git -C "$T/f3" show HEAD:docs/recent-changes.d/TK-3.md 2>&1)]"
[ "$(git -C "$T/f3" show HEAD:$CL)" = "$(git -C "$T/f3" show origin/main:$CL)" ] && ok || bad "F1b: the changelog must equal the base"

# ---------- F1c: an entry in the middle ----------
mkrepo f1c; python3 - "$T/f1c/$CL" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read().replace("## TK-9 — oldest entry", "## TK-13 — mid entry\n- did TK-13\n\n## TK-9 — oldest entry")
open(p, "w").write(s)
PY2
echo m > "$T/f1c/src/m.ts"; commit "$T/f1c" TK-13
strip "$T/f1c" TK-13
[ "$OUTMSG" = "moved $CL entry to docs/recent-changes.d/TK-13.md" ] && ok || bad "F1c: a mid-file entry is a pure addition and must move: [$OUTMSG]"
[ "$(git -C "$T/f1c" show HEAD:$CL)" = "$(git -C "$T/f1c" show origin/main:$CL)" ] && ok || bad "F1c: the changelog must equal the base"

# ---------- F3: not a pure addition ----------
mkrepo f5; top "$T/f5" TK-5; sed -i 's/- line one/- line 1/' "$T/f5/$CL"; echo z > "$T/f5/src/z.ts"; commit "$T/f5" "TK-5"
H0=$(git -C "$T/f5" rev-parse HEAD)
strip "$T/f5" TK-5
[ "$RC" = 0 ] && [ "$(git -C "$T/f5" rev-parse HEAD)" = "$H0" ] && ok || bad "F3: a non-pure diff must leave HEAD, rc=$RC"
case "$OUTMSG" in *"not a pure addition — left"*) ok ;; *) bad "F3: message must say left: [$OUTMSG]" ;; esac
[ ! -e "$T/f5/docs/recent-changes.d" ] && ok || bad "F3: no fragment may be written"

# ---------- F4: created by the build ----------
mkrepo f6b; git -C "$T/f6b" rm -q "$CL"; git -C "$T/f6b" commit -qm rm; git -C "$T/f6b" update-ref refs/remotes/origin/main HEAD
mkdir -p "$T/f6b/docs"; printf '# Recent changes\n- first\n' > "$T/f6b/$CL"; echo q > "$T/f6b/src/q.ts"; commit "$T/f6b" "TK-7"
H0=$(git -C "$T/f6b" rev-parse HEAD)
strip "$T/f6b" TK-7
[ "$(git -C "$T/f6b" rev-parse HEAD)" = "$H0" ] && ok || bad "F4: a changelog the build created must be left"
case "$OUTMSG" in *"created by this build"*"left"*) ok ;; *) bad "F4: created message: [$OUTMSG]" ;; esac

# ---------- F5: only the changelog ----------
mkrepo f6; top "$T/f6" TK-6; commit "$T/f6" "TK-6: changelog only"
H0=$(git -C "$T/f6" rev-parse HEAD)
strip "$T/f6" TK-6
[ "$(git -C "$T/f6" rev-parse HEAD)" = "$H0" ] && ok || bad "F5: a changelog-only diff must be left"
case "$OUTMSG" in *"only the changelog"*"left"*) ok ;; *) bad "F5: message: [$OUTMSG]" ;; esac
# ---------- F7 ----------
mkrepo f7; top "$T/f7" TK-8; echo w > "$T/f7/src/w.ts"; commit "$T/f7" "TK-8"
H0=$(git -C "$T/f7" rev-parse HEAD)
: > "$T/f7/.git/index.lock"
strip "$T/f7" TK-8
rm -f "$T/f7/.git/index.lock"
[ "$RC" = 0 ] && [ "$(git -C "$T/f7" rev-parse HEAD)" = "$H0" ] && ok || bad "F7: a failed commit must leave HEAD, rc=$RC"
case "$OUTMSG" in moved*) bad "F7: a failed move must never say moved: [$OUTMSG]" ;; *"not claimed"*) ok ;; *) bad "F7: message must say not claimed: [$OUTMSG]" ;; esac
[ -z "$(git -C "$T/f7" status --porcelain)" ] && ok || bad "F7: the tree must be as HEAD has it: $(git -C "$T/f7" status --porcelain)"

# ---------- F8: a rerun ----------
H1=$(git -C "$T/f1" rev-parse HEAD)
strip "$T/f1" TK-1
[ "$RC" = 0 ] && [ "$(git -C "$T/f1" rev-parse HEAD)" = "$H1" ] && ok || bad "F8: a rerun must add no commit, rc=$RC out=[$OUTMSG]"
git -C "$T/f1" show HEAD:docs/recent-changes.d/TK-1.md 2>/dev/null | cmp -s "$T/f1.want" - && ok || bad "F8: the fragment must not change"

# ---------- F9: the path list ----------
mkrepo f8; top "$T/f8" TK-9; echo v > "$T/f8/src/v.ts"; commit "$T/f8" "TK-9"
H0=$(git -C "$T/f8" rev-parse HEAD)
strip "$T/f8" TK-9 CHANGELOG_FRAGMENT_PATHS=docs/OTHER.md
[ "$(git -C "$T/f8" rev-parse HEAD)" = "$H0" ] && [ -z "$OUTMSG" ] && ok || bad "F9: another path list must not touch $CL: [$OUTMSG]"
mkrepo f9; printf '# Other\n\n## old\n- x\n' > "$T/f9/docs/OTHER.md"; commit "$T/f9" other
git -C "$T/f9" update-ref refs/remotes/origin/main HEAD
printf '# Other\n\n## TK-19\n- new\n\n## old\n- x\n' > "$T/f9/docs/OTHER.md"; top "$T/f9" TK-19; echo u > "$T/f9/src/u.ts"; commit "$T/f9" TK-19
strip "$T/f9" TK-19 CHANGELOG_FRAGMENT_PATHS=docs/OTHER.md
[ "$OUTMSG" = "moved docs/OTHER.md entry to docs/other.d/TK-19.md" ] && ok || bad "F9: the override path must move: [$OUTMSG]"
[ "$(git -C "$T/f9" show HEAD:docs/OTHER.md)" = "$(git -C "$T/f9" show origin/main:docs/OTHER.md)" ] && ok || bad "F9: docs/OTHER.md must equal the base"
# pr-scoped: ok reads the fixture repo $T/f9 built above, whose origin/main ref this test sets; never the real PR range
git -C "$T/f9" diff --quiet origin/main HEAD -- "$CL" && bad "F9: $CL is not in the list and must keep its entry" || ok
H0=$(git -C "$T/f8" rev-parse HEAD)
strip "$T/f8" ../x
[ "$RC" = 0 ] && [ "$(git -C "$T/f8" rev-parse HEAD)" = "$H0" ] && ok || bad "F9: an unsafe key must leave HEAD, rc=$RC"
case "$OUTMSG" in *"not a safe file name"*left*) ok ;; *) bad "F9: an unsafe key message: [$OUTMSG]" ;; esac
[ ! -e "$T/f8/docs/recent-changes.d" ] && [ ! -e "$T/f8/docs/x.md" ] && ok || bad "F9: an unsafe key must write no file"

# ---------- F6: the switch ----------
touch "$T/h/flags/changelog-fragment-off"
strip "$T/f8" TK-9
rm -f "$T/h/flags/changelog-fragment-off"
[ "$(git -C "$T/f8" rev-parse HEAD)" = "$H0" ] && ok || bad "F6: switch changelog-fragment-off must stop the move: [$OUTMSG]"
[ -f "$DIR/catalog/switches.d/changelog-fragment-off.json" ] \
  && [ "$(jq -r .name "$DIR/catalog/switches.d/changelog-fragment-off.json" 2>/dev/null)" = changelog-fragment-off ] \
  && ok || bad "F6: catalog/switches.d/changelog-fragment-off.json must exist and name the switch"
strip "$T/f8" TK-9
[ "$OUTMSG" = "moved $CL entry to docs/recent-changes.d/TK-9.md" ] && ok || bad "F6: with no switch the move must run: [$OUTMSG]"

# ---------- E1: the pipeline block ----------
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> changelog fragment/{f=1;next} /^# <<< changelog fragment/{exit} f' "$RB_ALL" > "$T/clf.sh"
[ -s "$T/clf.sh" ] && grep -q clf_strip "$T/clf.sh" && ok || bad "E1: could not lift '# >>> changelog fragment' out of the pipeline"
L_GEN=$(grep -n '^# <<< generated no-commit' "$RB_ALL" | head -1 | cut -d: -f1)
L_CLF=$(grep -n '^# >>> changelog fragment' "$RB_ALL" | head -1 | cut -d: -f1)
L_PRE=$(grep -n '^# >>> prepr gate' "$RB_ALL" | head -1 | cut -d: -f1)
[ -n "$L_GEN" ] && [ -n "$L_CLF" ] && [ -n "$L_PRE" ] && [ "$L_GEN" -lt "$L_CLF" ] && [ "$L_CLF" -lt "$L_PRE" ] \
  && ok || bad "E1: the block must sit after '# <<< generated no-commit' and before '# >>> prepr gate' (gen=$L_GEN clf=$L_CLF pre=$L_PRE)"
mkrepo e1; top "$T/e1" TK-11; echo e > "$T/e1/src/e.ts"; commit "$T/e1" "TK-11"
mkdir -p "$T/e1b"; : > "$T/e1b/pipeline.log"
( cd "$T/e1" && env -u CHANGELOG_FRAGMENT_PATHS HARNESS="$DIR" BUILD="$T/e1b" KEY=TK-11 PROJECT=demo BASE=origin/main LANE_GATE_DISABLE=1 \
    bash -c 'set -uo pipefail; STAMP() { echo TS; }; . "$0"' "$T/clf.sh" ) > "$T/e1.out" 2>&1
[ "$?" = 0 ] && ok || bad "E1: the block must exit 0: $(cat "$T/e1.out")"
grep -qF "TS [demo/TK-11] changelog fragment: moved $CL entry to docs/recent-changes.d/TK-11.md" "$T/e1b/pipeline.log" && ok \
  || bad "E1: pipeline.log must carry the moved line: [$(cat "$T/e1b/pipeline.log")]"
[ "$(git -C "$T/e1" show HEAD:$CL)" = "$(git -C "$T/e1" show origin/main:$CL)" ] && ok || bad "E1: the block must reset the changelog"
# E1b no changelog in the diff -> one honest line
mkrepo e2; echo e > "$T/e2/src/e.ts"; commit "$T/e2" "TK-12"; : > "$T/e1b/pipeline.log"
( cd "$T/e2" && env -u CHANGELOG_FRAGMENT_PATHS HARNESS="$DIR" BUILD="$T/e1b" KEY=TK-12 PROJECT=demo BASE=origin/main LANE_GATE_DISABLE=1 \
    bash -c 'set -uo pipefail; STAMP() { echo TS; }; . "$0"' "$T/clf.sh" ) > "$T/e2.out" 2>&1
grep -qF "TS [demo/TK-12] changelog fragment: no changelog entry in this diff" "$T/e1b/pipeline.log" && ok \
  || bad "E1b: a diff with no changelog edit must log 'no changelog entry in this diff': [$(cat "$T/e1b/pipeline.log")]"

# ---------- M1 (acceptance 4) ----------
m1() { # m1 <name> <strip:0|1> -> merge rc of B into main after A, in M1RC
  local r="$T/$1"
  mkrepo "$1"
  git -C "$r" checkout -q main && git -C "$r" checkout -qb a
  top "$r" TK-41; echo a > "$r/src/a.ts"; commit "$r" "TK-41"
  [ "$2" = 1 ] && { strip "$r" TK-41; [ "$OUTMSG" = "moved $CL entry to docs/recent-changes.d/TK-41.md" ] || bad "M1: strip A: [$OUTMSG]"; }
  git -C "$r" checkout -q main && git -C "$r" checkout -qb b
  top "$r" TK-42; echo b > "$r/src/b.ts"; commit "$r" "TK-42"
  [ "$2" = 1 ] && { strip "$r" TK-42; [ "$OUTMSG" = "moved $CL entry to docs/recent-changes.d/TK-42.md" ] || bad "M1: strip B: [$OUTMSG]"; }
  git -C "$r" checkout -q main
  git -C "$r" merge -q --no-ff --no-edit a >/dev/null 2>&1 || bad "M1: merge of A must be clean"
  git -C "$r" merge -q --no-ff --no-edit b >/dev/null 2>&1; M1RC=$?
}
m1 m1c 0
[ "$M1RC" != 0 ] && ok || bad "M1 control: two unstripped top entries must conflict (the fixture is real)"
m1 m1 1
[ "$M1RC" = 0 ] && ok || bad "M1: two stripped builds must merge with no conflict, rc=$M1RC"
grep -rq '^<<<<<<<' "$T/m1/docs" "$T/m1/src" && bad "M1: conflict markers in the tree" || ok
[ -f "$T/m1/docs/recent-changes.d/TK-41.md" ] && [ -f "$T/m1/docs/recent-changes.d/TK-42.md" ] && ok || bad "M1: both fragments must be on main"

echo "changelog-fragment.bh-9096: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
