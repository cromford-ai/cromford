#!/bin/bash
# tests/generated-files-train-test.sh — BH-865. cromford declares its
# generated files, so bin/batch-resolve.sh's merge train is ARMED for this repo.
#
# WHAT WAS WRONG. bin/batch-resolve.sh (BH-498) lands approved siblings whose
# only conflicts are in machine-written files as one union branch, one
# regenerate, one verification run. Its own rule is that a repo which declares
# no `generated files` table exits 0 having done nothing at all — and
# cromford declared none, while `docs/verification-map/README.md` was the
# single most common hunk in its dirty-PR tail. The lane built to kill that tail
# was off, by omission, on the repo with the tail.
#
# WHAT THIS SUITE IS WORTH. Every case drives the REAL production code:
#
#   * the table, union list, allow-list and contract functions are EXTRACTED
#     VERBATIM from bin/batch-resolve.sh by function name and run here. Nothing
#     below restates that logic, and an extraction that comes back empty FAILS
#     the suite rather than silently testing nothing (a renamed function must
#     turn this red, not green).
#   * the README under test is built by the REAL bin/verification-map-build.sh
#     from the REAL sources, into a scratch copy.
#   * the merge behaviour is proved by REAL git: two sibling branches that each
#     add an entry file, merged with `git merge-tree --write-tree`, must merge
#     with NO merge attribute at all — and a control pair that both edit a
#     COMMITTED file must still conflict, so a pass cannot be fixture luck.
#     (Until BH-1175 this proved the union ATTRIBUTE on the committed README in
#     both directions. The README is no longer committed, so there is nothing
#     for the attribute to be about; see GT-3 and GT-4.)
#
#   * GT-9 asks git itself about every DERIVED path in this repo: not tracked,
#     covered by .gitignore, and carrying no merge attribute (BH-1175, BH-1203,
#     BH-1268 are one rule with three subjects).
#
# No network, no clock, no gh: one scratch repository under $T and nothing else.
#
# Run from anywhere:  bash tests/generated-files-train-test.sh   (exit 0 = all pass)
# As root next to a live harness:  HARNESS_TEST_SANDBOX=1 bash tests/generated-files-train-test.sh
#
# GT-8 runs this repo's Verification Contract, and that contract runs THIS
# suite. The nested run is the real thing minus GT-8 — the guard below is what
# stops a self-referential contract from recursing forever.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
BR="$DIR/bin/batch-resolve.sh"
VMB="$DIR/bin/verification-map-build.sh"
NESTED="${BH865_CONTRACT_NESTED:-0}"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
done_() { echo "generated-files-train: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; }

command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
[ -r "$BR" ]  || { echo "FAIL: bin/batch-resolve.sh is missing"; exit 1; }
[ -x "$VMB" ] || { echo "FAIL: bin/verification-map-build.sh is missing or not executable"; exit 1; }

# ── the production functions, verbatim ───────────────────────────────────────
# An empty extraction is a FAIL, never a skip: `sed` answering nothing is
# exactly what a renamed or deleted function looks like, and a suite that
# evaluates nothing passes every case after it.
block() { sed -n "/^$1()/,/^}/p" "$BR"; }
oneline() { grep -m1 "^$1() {.*}\$" "$BR"; }

SRC=""
for fn in regen_table verify_cmd path_allowed regen_cmd_for; do
  b=$(block "$fn")
  if [ -z "$b" ]; then bad "could not extract $fn() from bin/batch-resolve.sh — the suite would test nothing"; done_; exit 1; fi
  SRC="$SRC$b"$'\n'
done
b=$(oneline union_paths)
if [ -z "$b" ]; then bad "could not extract union_paths() from bin/batch-resolve.sh — the suite would test nothing"; done_; exit 1; fi
SRC="$SRC$b"$'\n'
ok

# ── a real repository, built from the branch's real sources ──────────────────
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false

SR="$T/repo"
mkdir -p "$SR/bin"
git init -q -b main "$SR"
cp -r "$DIR/docs" "$SR/docs"
# The generated index is NOT committed here, because it is not committed on main
# (BH-1175). The working-tree copy comes along with `cp -r`; dropping it before
# the first commit is what makes this fixture the tree the fleet actually runs.
rm -f "$SR/docs/verification-map/README.md"
# …and the repo's own .gitignore comes with it, or the `git add -A` inside sib()
# below would commit the generated index back and GT-4 would be measuring a
# fixture nobody ships.
cp "$DIR/.gitignore" "$SR/.gitignore" 2>/dev/null || :
cp "$VMB" "$SR/bin/verification-map-build.sh"
git -C "$SR" add -A
git -C "$SR" commit -qm "sources, no .gitattributes"
BASE=$(git -C "$SR" rev-parse HEAD)

# The declaration half lands in a SECOND commit, so the same repo can answer
# both halves of GT-4: BASE has no attribute file, main has it.
cp "$DIR/.gitattributes" "$SR/.gitattributes" 2>/dev/null
cp "$DIR/CLAUDE.md" "$SR/CLAUDE.md" 2>/dev/null
git -C "$SR" add -A
git -C "$SR" commit -qm "the BH-865 declaration" >/dev/null 2>&1
git -C "$SR" update-ref refs/remotes/origin/main "$(git -C "$SR" rev-parse HEAD)"

# show_base is what bin/batch-resolve.sh reads the repo's own claims through.
# Bound here to the scratch repo's origin/main, which is the branch's tree.
show_base() { git -C "$SR" show "origin/main:$1" 2>/dev/null; }
# shellcheck disable=SC1090
eval "$SRC"

# ── GT-1 the generated README declares the table, below the conventions ──────
OUT=$("$VMB" --repo "$SR" 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "GT-1: the real generator must exit 0 over the real sources (got $RC: $OUT)"
RM="$SR/docs/verification-map/README.md"
HEAD_LN=$(grep -niE '^#+[[:space:]]*.*generated files' "$RM" | head -1 | cut -d: -f1)
CONV_LN=$(grep -n '^## Driving conventions' "$RM" | head -1 | cut -d: -f1)
[ -n "$HEAD_LN" ] && ok || bad "GT-1: the generated README carries no 'generated files' heading — bin/batch-resolve.sh finds the table by that heading, so the train stays off"
if [ -n "$HEAD_LN" ] && [ -n "$CONV_LN" ] && [ "$HEAD_LN" -gt "$CONV_LN" ]; then ok
else bad "GT-1: the 'generated files' heading must come AFTER '## Driving conventions' (heading=$HEAD_LN conventions=$CONV_LN), or bin/verification-map.sh's primer section swallows the table"; fi

# ── GT-2 regen_table answers exactly the declared rows, each naming a script
#    that exists. The list is WRITTEN OUT rather than counted: every row is a
#    file the train may resolve by taking one side and regenerating, so a row
#    arriving without a reader is the thing this pin exists to stop.
#
#    It was one row (the verification-map README) until BH-1178 made the ten
#    crontabs, the env template and the lane registry renders of per-lane files.
#    The crontabs are listed ONE BY ONE and never as `cron/*.cron`: see GT-7.
REGEN_TABLE=$(regen_table)
WANT_ROW=$(printf '%s\n' \
  "$(printf 'docs/verification-map/README.md\tbin/verification-map-build.sh')" \
  "$(for b in project-4 hub project-6 project-1 project-3 project-10 project-9 small project-2 project-5; do
        printf 'cron/%s.cron\tbin/render-crontab.sh --from-fragments --all --write\n' "$b"; done)" \
  "$(printf 'env-templates/global.env.example\tbin/render-env-example.sh --write')" \
  "$(printf 'catalog/lanes.json\tbin/lanes-build.sh --write')" \
  "$(printf 'rules/CLAUDE.md\tbin/render-rules.sh --write')" \
  "$(printf 'docs/PR-OWNERSHIP.md\tbin/render-doc-sections.sh --write')" \
  "$(printf 'worker/jobs/schema.sql\tbin/schema-build.sh --write')")
#    …and of the last three rows two are still COMMITTED. rules/CLAUDE.md
#    (BH-1336): five scripts copy it verbatim onto every box, so it cannot leave
#    git yet, which is exactly why a train must regenerate it rather than hand
#    merge two siblings' renders. docs/PR-OWNERSHIP.md (BH-5235.2) is linked by
#    path and read on GitHub, so it stays too. worker/jobs/schema.sql (BH-4987)
#    is composed from worker/jobs/schema.d/ and is NOT in git since BH-6005:
#    every reader composes its own. (BH-5239.4 deleted the Cloud schema row.)
if [ "$REGEN_TABLE" = "$WANT_ROW" ]; then ok
else bad "GT-2: regen_table must print exactly the declared rows. Got:
$(printf '%s' "$REGEN_TABLE" | cat -A)"; fi
# Every distinct command, not just the first: a row whose generator is missing
# or unexecutable is a train that abandons on the command it was told to run.
BADCMD=""
while IFS= read -r CMD; do
  [ -n "$CMD" ] || continue
  set -- $CMD
  [ -x "$DIR/$1" ] || BADCMD="$BADCMD $1"
done <<<"$(printf '%s\n' "$REGEN_TABLE" | cut -f2 | awk 'NF && !seen[$0]++')"
[ -z "${BADCMD// /}" ] && ok \
  || bad "GT-2: every regenerate command the table names must exist and be executable in the repo — build_union runs it verbatim. Missing:$BADCMD"

# ── GT-3 the union list, and what git itself says about those paths ──────────
# WHAT CHANGED AND WHY (BH-1175). docs/verification-map/README.md was the FIRST
# of the three union declarations, and it is gone from both lists — from this
# one because it is no longer committed, and from .gitattributes because a merge
# driver for a file git never sees is a rule with no subject. It moves to the
# NEGATIVE list below, where it is now asserted to carry no merge attribute at
# all: an attribute left behind on that path would silently come back into force
# the day somebody re-added the file.
# AND AGAIN, FOR TWELVE MORE (BH-1247). The ten cron/<box>.cron,
# catalog/lanes.json and env-templates/global.env.example left git for exactly
# the reason the README did, one ticket later and with three dead merge trains
# behind it (#1241, #1257, #1263, 2026-09-21). They are gone from this list and
# from .gitattributes, and they join the NEGATIVE list below. What is left is
# env-templates/project.env.example: the one union declaration in this repo
# whose subject is a HAND-MAINTAINED file (BH-865), which is the only kind a
# merge driver can legitimately have.
UNION_PATHS=$(union_paths)
WANT_UNION=$(printf '%s\n' 'env-templates/project.env.example')
if [ "$UNION_PATHS" = "$WANT_UNION" ]; then ok
else bad "GT-3: union_paths must print exactly the declared paths. Got:
$UNION_PATHS"; fi

attr() { git -C "$DIR" check-attr merge -- "$1" 2>/dev/null | sed 's/.*: merge: //'; }
for p in env-templates/project.env.example; do
  [ "$(attr "$p")" = union ] && ok || bad "GT-3: git check-attr says merge=$(attr "$p") for $p — the declaration is not the one git reads"
done
# The negatives carry the weight: a union attribute on real code silently
# concatenates two edits into a file nobody reviewed, and alerts.conf.example is
# READ AT RUNTIME by bin/lib/alert-state.sh, so a duplicated rule there changes
# behaviour.
for p in docs/verification-map/README.md bin/run-build.sh bin/lib/merge-conductor-lib.sh env-templates/alerts.conf.example docs/MERGE-CONDUCTOR.md \
         env-templates/global.env.example catalog/lanes.json \
         cron/project-4.cron cron/hub.cron cron/project-6.cron cron/project-1.cron \
         cron/project-3.cron cron/project-10.cron cron/project-9.cron \
         cron/small.cron cron/project-2.cron cron/project-5.cron; do
  [ "$(attr "$p")" = unspecified ] && ok || bad "GT-3: $p must have NO merge attribute (got $(attr "$p")) — it is GENERATED and not committed (BH-1247), and an attribute for a path git never sees comes back into force the day somebody re-adds the file"
done
# ...and none of the twelve is TRACKED, which is the fact the line above depends
# on. An attribute check on a file that quietly came back would pass while the
# contested cell was in git again.
BACK=""
for p in env-templates/global.env.example catalog/lanes.json \
         cron/project-4.cron cron/hub.cron cron/project-6.cron cron/project-1.cron \
         cron/project-3.cron cron/project-10.cron cron/project-9.cron \
         cron/small.cron cron/project-2.cron cron/project-5.cron; do
  [ -n "$(git -C "$DIR" ls-files -- "$p" 2>/dev/null)" ] && BACK="$BACK $p"
done
[ -z "${BACK// /}" ] && ok || bad "GT-3: these GENERATED renders are TRACKED again:$BACK (BH-1247)"

# ── GT-4 two tickets adding an entry each, proved by real git ───────────────
# WHAT CHANGED AND WHY (BH-1175). This case used to prove the union ATTRIBUTE in
# both directions: without it the pair conflicted on the committed README, with
# it the pair merged. The README is no longer committed, so the first half can
# no longer be red (there is nothing to conflict on) and the second half would
# be testing an attribute this repo no longer declares. What replaces it is the
# stronger claim the ticket actually makes — the pair merges with NO attribute
# at all, because nothing contested is in git — plus a negative that proves the
# fixture can still report a conflict, so "merged clean" is not fixture luck.
sib() { # sib <branch> <key> — a sibling that adds its own entry row and regenerates
  git -C "$SR" checkout -q -b "$2" "$BASE"
  printf '%s\n' "| Feature $1 | [f$1.md](f$1.md) | \`bin/f$1.sh\` |" > "$SR/docs/verification-map/entries/BH-$1.md"
  printf '%s\n' "# f$1" > "$SR/docs/verification-map/f$1.md"
  ( cd "$SR" && bash bin/verification-map-build.sh >/dev/null 2>&1 )
  git -C "$SR" add -A
  git -C "$SR" commit -qm "BH-$1"
}
sib 90001 sib-a
sib 90002 sib-b

git -C "$SR" checkout -q "$BASE"          # no .gitattributes in tree or index
OUT=$(git -C "$SR" merge-tree --write-tree --name-only sib-a sib-b 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "GT-4: two tickets that each add an entry file must merge with NO merge attribute (rc=$RC):
$OUT"

# The fixture is not vacuous: two branches that both edit a file that IS
# committed still conflict here, so the clean merge above is a fact about what
# is in git, not about merge-tree being unable to report anything.
git -C "$SR" checkout -q -b clash-a "$BASE"
printf '%s\n' 'a side' >> "$SR/docs/verification-map/index/tail.md"
git -C "$SR" commit -qam "clash a" >/dev/null 2>&1
git -C "$SR" checkout -q -b clash-b "$BASE"
printf '%s\n' 'b side' >> "$SR/docs/verification-map/index/tail.md"
git -C "$SR" commit -qam "clash b" >/dev/null 2>&1
git -C "$SR" checkout -q "$BASE"
CL=$(git -C "$SR" merge-tree --write-tree --name-only clash-a clash-b 2>&1); CLRC=$?
[ "$CLRC" != 0 ] && ok || bad "GT-4: the fixture reported a clean merge for two branches editing the SAME committed file — merge-tree is not detecting conflicts here, so the clean merge above proves nothing (rc=$CLRC)"

git -C "$SR" checkout -q main             # back to the branch's own tree
OUT=$(git -C "$SR" merge-tree --write-tree --name-only sib-a sib-b 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "GT-4: the same pair must merge clean from main too (rc=$RC):
$OUT"
MERGED=$(head -1 <<<"$OUT")

# ── GT-5 the regenerate step corrects the union's row order ─────────────────
if [ "$RC" = 0 ] && [ -n "$MERGED" ]; then
  C=$(git -C "$SR" commit-tree "$MERGED" -p sib-a -p sib-b -m union)
  git -C "$SR" checkout -q "$C"
  ( cd "$SR" && bash bin/verification-map-build.sh >/dev/null 2>&1 ); RRC=$?
  [ "$RRC" = 0 ] && ok || bad "GT-5: the table's regenerate command must exit 0 over the union tree (got $RRC)"
  ( cd "$SR" && bash bin/verification-map-build.sh --check >/dev/null 2>&1 ); CRC=$?
  [ "$CRC" = 0 ] && ok || bad "GT-5: after the regenerate, --check must accept the union's README (got $CRC)"
  R2="$SR/docs/verification-map/README.md"
  [ "$(grep -c 'Feature 90001' "$R2")" = 1 ] && [ "$(grep -c 'Feature 90002' "$R2")" = 1 ] && ok \
    || bad "GT-5: the regenerated union README must carry each sibling's row exactly once (90001=$(grep -c 'Feature 90001' "$R2") 90002=$(grep -c 'Feature 90002' "$R2"))"
else
  bad "GT-5: not reached — the union merge did not produce a tree"
fi
git -C "$SR" checkout -q main

# ── GT-6 the allow-list: positives, and the negatives that matter ───────────
for p in docs/verification-map/README.md env-templates/project.env.example env-templates/global.env.example; do
  path_allowed "$p" && ok || bad "GT-6: path_allowed must accept the declared path $p"
done
for p in bin/run-build.sh bin/lib/merge-conductor-lib.sh bin/blocked-resolver.sh docs/MERGE-CONDUCTOR.md env-templates/alerts.conf.example; do
  if path_allowed "$p"; then bad "GT-6: path_allowed accepted $p — a source conflict must take today's path, which is the safety property of this lane"
  else ok; fi
  if [ -n "$(regen_cmd_for "$p")" ]; then bad "GT-6: regen_cmd_for returned a command for $p"; else ok; fi
done

# ── GT-7 the attribute file itself declares nothing else ───────────────────
# 1 = env-templates/project.env.example, and nothing else. The count has only
# ever gone down, and each step is the same argument: a merge driver declared
# for a path git never sees is a rule with no subject that comes back into force
# the moment somebody re-adds the file. It was 3, became 2 with BH-1175
# (docs/verification-map/README.md left git), 13 with BH-1178 (eleven renders
# arrived), and 1 with BH-1247 (those eleven plus
# env-templates/global.env.example left git too). What remains is the one
# declaration whose subject is HAND-MAINTAINED, which is the only kind that can
# legitimately need a driver. The count is pinned rather than left open because
# every line here is a file git will merge by concatenating both sides, and one
# added without a regenerate row is a file merged with no reader at all.
LINES=$(grep -cvE '^[[:space:]]*(#|$)' "$DIR/.gitattributes" 2>/dev/null)
[ "$LINES" = 1 ] && ok || bad "GT-7: .gitattributes must hold exactly 1 declaration (got $LINES) — every extra line is a file merged without a reader"
grep -q 'verification-map' "$DIR/.gitattributes" 2>/dev/null \
  && bad "GT-7: .gitattributes still declares a verification-map path — that file is generated and not committed (BH-1175)" || ok
# The no-glob half stays EXACTLY as written, and BH-1178 answered it by writing
# the ten crontabs out one by one. `cron/*.cron` would have been read by
# bin/batch-resolve.sh's `case` match, where `*` crosses `/`, so it would also
# claim cron/lanes/<lane>.cron — and a conflicted path with a regenerate command
# is resolved by taking one side. Two approved PRs editing the same lane
# fragment in one train would silently lose one, with every check green.
if grep -vE '^[[:space:]]*(#|$)' "$DIR/.gitattributes" 2>/dev/null | grep -qE '\.sh|^bin/|\*'; then
  bad "GT-7: .gitattributes matches a code path or a glob — union-merging code concatenates two edits nobody reviewed"
else ok; fi
# And neither does the regenerate table, for the same reason and the same reader.
if printf '%s\n' "$REGEN_TABLE" | cut -f1 | grep -qE '\*|\?|\['; then
  bad "GT-7: the regenerate table holds a glob — bin/batch-resolve.sh matches it with shell case, where * crosses /, so it would claim the fragments the generated file is built FROM and resolve a conflicted one by taking a side"
else ok; fi

# ── GT-9 every DERIVED path is out of git, ignored, and carries no attribute ─
# BH-1175 took docs/verification-map/README.md out of git; BH-1203 did the same
# for the test-impact map; BH-1268 does it for the orphan list and the LLM
# call-site census. The three properties are one rule, and each one fails
# differently: a TRACKED copy is the contested cell coming back (and a file
# whose own gate reads it can switch that gate off by being committed), a
# missing IGNORE line means the next `git add -A` commits it again, and a merge
# ATTRIBUTE left on a path git never sees comes silently back into force the day
# somebody re-adds the file.
for p in docs/verification-map/README.md catalog/test-impact.tsv \
         catalog/test-impact-orphans.txt docs/LLM_CALL_SITES.md; do
  if [ -z "$(git -C "$DIR" ls-files -- "$p" 2>/dev/null)" ]; then ok
  else bad "GT-9: $p is TRACKED in git — it is generated, and a generated file in git is a cell every build writes"; fi
  if git -C "$DIR" check-ignore -q --no-index -- "$p" 2>/dev/null; then ok
  else bad "GT-9: .gitignore does not cover $p — the next 'git add -A' commits the generated file back"; fi
  if [ "$(attr "$p")" = unspecified ]; then ok
  else bad "GT-9: $p carries merge=$(attr "$p") — a merge driver for a file git never sees is a rule with no subject that revives the moment the file is re-added"; fi
done
# The probe is not vacuous: a file that IS committed must read as tracked here,
# or every line above passes on a `git ls-files` that answers nothing at all.
if [ -n "$(git -C "$DIR" ls-files -- bin/run-build.sh 2>/dev/null)" ]; then ok
else bad "GT-9: git ls-files reports bin/run-build.sh as untracked — the tracked probe above is answering nothing"; fi

# ── GT-8 the Verification Contract this repo hands the lane ────────────────
CONTRACT=$(verify_cmd)
[ "$CONTRACT" != "npm test" ] && ok \
  || bad "GT-8: verify_cmd fell back to 'npm test' — this repo has no package.json, so an armed train would be red on every attempt and land nothing"
grep -q 'generated-files-train-test.sh' <<<"$CONTRACT" && ok \
  || bad "GT-8: the contract must run this suite, which is what pins the lane. Got: $CONTRACT"
if [ "$NESTED" = 1 ]; then
  echo "generated-files-train: GT-8 execution skipped (nested run inside the contract it runs)"
  ok
else
  ( cd "$DIR" && BH865_CONTRACT_NESTED=1 eval "$CONTRACT" ) >"$T/contract.out" 2>&1; CRC=$?
  [ "$CRC" = 0 ] && ok || bad "GT-8: the contract command must exit 0 from the repo root, exactly as bin/batch-resolve.sh runs it (got $CRC):
$(tail -20 "$T/contract.out")"
fi

done_
