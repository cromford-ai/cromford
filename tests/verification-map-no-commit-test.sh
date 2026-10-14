#!/bin/bash
# tests/verification-map-no-commit-test.sh — BH-1175. The verification-map index
# is GENERATED, and it is not committed.
#
# WHAT WAS WRONG. `docs/verification-map/README.md` was a committed artifact:
# every build that added a feature entry regenerated it, so every build touched
# the same file. It was in 105 of the last 200 merges to main, it conflicted on
# every rebase of the 2026-09-20 drain, and it turned main RED three times in one
# day — the `merge=union` driver glued one squash merge's table onto another's
# and produced a duplicated row that `--check` then refused (e71b2de1, dd2cee5a,
# 855c0b42). A generated file that is committed is a shared mutable cell with a
# merge driver in front of it.
#
# So the README stops being committed at all. `docs/verification-map/entries/`
# stays the source (one file per ticket — conflict-free by construction),
# `bin/verification-map-build.sh` still writes the README, and the path is
# git-ignored so nothing can put it back. `--check` stops comparing bytes
# (there is nothing committed to compare against) and instead validates what IS
# committed: the sources parse, no two of them produce the same row, every entry
# link resolves, and no README is tracked.
#
# WHAT THESE ASSERTIONS ARE WORTH. Every case drives the REAL
# bin/verification-map-build.sh and the REAL mc_regen_table over REAL git — real
# branches, a real `git merge-tree`, the repo's real sources copied into a
# scratch repository. Nothing below restates the logic it is testing.
#
# The five properties, and why each one is here:
#
#   NC-1 two tickets that each add an entry MERGE CLEAN with no attribute and no
#        resolver. This is the whole ticket: the conflict is gone because the
#        contested file is gone, not because something resolves it afterwards.
#   NC-2 a TRACKED README fails --check, by name, so the file cannot come back
#        through a stale branch or a hand `git add -f`.
#   NC-3 this repo really does not track it, and really does ignore it.
#   NC-4 mc_regen_table still finds the `generated files` table with NO committed
#        README — it now reads docs/verification-map/index/tail.md. Without this
#        bin/batch-resolve.sh reads an empty table and turns the merge train OFF
#        for this repo (BH-865), silently.
#   NC-5 a DUPLICATE ROW across two entry files fails --check. That is the exact
#        shape of the three main-red freezes, and byte-comparison could never
#        catch it once the README stopped being committed.
#   NC-6 an entry whose doc link resolves to nothing fails --check. The index is
#        a table of links; a link to a file that is not there is a dead end a
#        reader finds and a byte-comparison never did.
#   NC-9 the guard is ORIENTATION-AWARE. The mirror image of NC-8 — the BRANCH
#        deletes a tracked-but-ignored file and the BASE still edits it — must
#        stay a REAL conflict, or the base's edit is discarded silently.
#   NC-10 --check refuses a TRACKED index whether or not .gitignore still covers
#        it, so a PR cannot switch its own gate off by dropping the ignore line.
#   NC-8 THE DAY-ONE CASE. A branch that still COMMITS the index meets a base
#        that deleted and ignores it: a modify/delete, which git leaves with no
#        conflict markers, so the `*.md` union resolver fails on it and the real
#        mc_resolve_conflicts used to call it a REAL conflict — one Opus fix
#        round for each of the 48 open PRs in that shape, on a file the repo has
#        just decided nothing may commit. It must resolve as a DELETION, and the
#        branch's own entry file must survive (that is what makes dropping the
#        index safe).
#
# No network, no clock, no gh: scratch repositories under $T and nothing else.
# Run from anywhere: bash tests/verification-map-no-commit-test.sh (0 = all pass)
# As root next to a live harness: HARNESS_TEST_SANDBOX=1 bash tests/verification-map-no-commit-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
VMB="$DIR/bin/verification-map-build.sh"
MCL="$DIR/bin/lib/merge-conductor-lib.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
done_() { echo "verification-map-no-commit: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; }

command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
[ -x "$VMB" ] || { echo "FAIL: bin/verification-map-build.sh is missing or not executable"; exit 1; }
[ -r "$MCL" ] || { echo "FAIL: bin/lib/merge-conductor-lib.sh is missing"; exit 1; }

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false

# ── a scratch repository carrying this branch's REAL committed docs ─────────
# `git archive HEAD -- docs`, NOT `cp -r docs`: the fixture must commit exactly
# what this branch commits, or the cases below grade a tree nobody ships. While
# the README was committed that archive carries one, and NC-1 conflicts; once it
# is out of git the archive carries none, and NC-1 merges. A working-tree copy
# would carry the generated file either way and NC-1 would never have been red.
SR="$T/repo"
mkdir -p "$SR/bin" "$SR/docs"
git init -q -b main "$SR"
if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 \
   && git -C "$DIR" archive HEAD -- docs 2>/dev/null | tar -x -C "$SR" 2>/dev/null \
   && [ -d "$SR/docs/verification-map/entries" ]; then :
else
  # No git (a bare export): fall back to the working tree, minus the artifact.
  # scratch_rm, not `rm -rf`: checks/tests-scratch-only refuses a recursive
  # delete it cannot prove lives under $T, and being unable to prove it is the
  # whole reason that check exists (#388).
  scratch_rm "$SR/docs"
  cp -r "$DIR/docs" "$SR/docs"
  rm -f "$SR/docs/verification-map/README.md"
fi
cp "$VMB" "$SR/bin/verification-map-build.sh"
chmod +x "$SR/bin/verification-map-build.sh"
cp "$DIR/.gitignore" "$SR/.gitignore" 2>/dev/null || :
git -C "$SR" add -A
git -C "$SR" commit -qm "the committed docs tree, as this branch ships it"
BASE=$(git -C "$SR" rev-parse HEAD)

# ── NC-1 two tickets adding an entry each merge clean, and the index is right ─
# No .gitattributes anywhere in this fixture: if the pair still merges, it is
# because nothing contested is committed, not because a driver papered over it.
sib() { # sib <n> <branch>
  git -C "$SR" checkout -q -b "$2" "$BASE"
  printf '%s\n' "| Feature $1 | [nc-$1.md](nc-$1.md) | \`bin/nc-$1.sh\` |" \
    > "$SR/docs/verification-map/entries/BH-$1.md"
  printf '%s\n' "# Feature $1" > "$SR/docs/verification-map/nc-$1.md"
  ( cd "$SR" && bash bin/verification-map-build.sh >/dev/null 2>&1 )
  git -C "$SR" add -A
  git -C "$SR" commit -qm "BH-$1"
}
sib 91001 nc-a
sib 91002 nc-b
git -C "$SR" checkout -q "$BASE"

OUT=$(git -C "$SR" merge-tree --write-tree --name-only nc-a nc-b 2>&1); RC=$?
if [ "$RC" = 0 ]; then ok
else bad "NC-1: two tickets that each add an entry file must merge with NO conflict and no merge attribute (rc=$RC):
$OUT"; fi

MERGED=$(head -1 <<<"$OUT")
if [ "$RC" = 0 ] && [ -n "$MERGED" ]; then
  C=$(git -C "$SR" commit-tree "$MERGED" -p nc-a -p nc-b -m union)
  git -C "$SR" checkout -q "$C"
  ( cd "$SR" && bash bin/verification-map-build.sh >/dev/null 2>&1 ); GRC=$?
  [ "$GRC" = 0 ] && ok || bad "NC-1: the generator must exit 0 over the merged tree (got $GRC)"
  R="$SR/docs/verification-map/README.md"
  if [ "$(grep -c 'Feature 91001' "$R" 2>/dev/null)" = 1 ] \
     && [ "$(grep -c 'Feature 91002' "$R" 2>/dev/null)" = 1 ]; then ok
  else bad "NC-1: the generated index must carry each ticket's row EXACTLY ONCE (91001=$(grep -c 'Feature 91001' "$R" 2>/dev/null) 91002=$(grep -c 'Feature 91002' "$R" 2>/dev/null))"; fi
  ( cd "$SR" && bash bin/verification-map-build.sh --check >/dev/null 2>&1 ); CRC=$?
  [ "$CRC" = 0 ] && ok || bad "NC-1: --check must accept the merged sources (got $CRC)"
else
  bad "NC-1: not reached — the merge produced no tree"
  bad "NC-1: not reached — the generator was never run over a merged tree"
  bad "NC-1: not reached — the row count was never asserted"
fi
git -C "$SR" checkout -q main

# ── NC-2 a TRACKED README fails --check, and says which ticket to read ───────
# `add -f`, because the path is ignored: this is exactly how it would come back
# — a stale branch, or somebody forcing it in — and the check has to catch it
# rather than trust the ignore rule.
( cd "$SR" && bash bin/verification-map-build.sh >/dev/null 2>&1 )
git -C "$SR" add -f docs/verification-map/README.md >/dev/null 2>&1
git -C "$SR" commit -qm "put the index back in git" >/dev/null 2>&1
OUT=$( cd "$SR" && bash bin/verification-map-build.sh --check 2>&1 ); RC=$?
[ "$RC" != 0 ] && ok || bad "NC-2: --check must FAIL while docs/verification-map/README.md is tracked (got rc $RC: $OUT)"
grep -q 'BH-1175' <<<"$OUT" && ok \
  || bad "NC-2: the refusal must name BH-1175, or the next reader has no way to learn why the file left. Got: $OUT"
grep -q 'docs/verification-map/README.md' <<<"$OUT" && ok \
  || bad "NC-2: the refusal must name the tracked path. Got: $OUT"
git -C "$SR" rm -q --cached docs/verification-map/README.md >/dev/null 2>&1
git -C "$SR" commit -qm "untrack it again" >/dev/null 2>&1
OUT=$( cd "$SR" && bash bin/verification-map-build.sh --check 2>&1 ); RC=$?
[ "$RC" = 0 ] && ok || bad "NC-2: --check must pass again once the index is untracked (got rc $RC: $OUT)"

# ── NC-3 this repository tracks no README, and ignores the path ──────────────
if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  TRACKED=$(git -C "$DIR" ls-files -- docs/verification-map/README.md 2>/dev/null)
  [ -z "$TRACKED" ] && ok \
    || bad "NC-3: docs/verification-map/README.md is TRACKED in this repository — the generated index is committed again"
  git -C "$DIR" check-ignore -q docs/verification-map/README.md 2>/dev/null && ok \
    || bad "NC-3: .gitignore does not ignore docs/verification-map/README.md, so the next 'git add -A' commits it back"
else
  echo "NC-3: not a git checkout — skipped"; ok; ok
fi

# ── NC-4 the regenerate table survives without a committed README ────────────
# bin/batch-resolve.sh exits 0 having done NOTHING when the table is empty, so a
# table that moved out of reach turns the generated-files train off for this
# repo silently. mc_regen_table is the shared parser (BH-968); it is run here
# against a tree with no committed README, which is what main now looks like.
# A scratch harness root for the library's own logs, exactly as
# tests/verification-map-retrofit-test.sh does it: mc_log writes under
# $HARNESS/logs, and a lib sourced without one would write into the real
# install.
export HARNESS="$T/h"; mkdir -p "$HARNESS/logs" "$HARNESS/state" "$HARNESS/bin"
# shellcheck source=/dev/null
. "$MCL" >/dev/null 2>&1 && mc_init >/dev/null 2>&1
#
# THE PIN IS THE WHOLE TABLE, NOT ONE ROW (BH-1178). The README row was the only
# row until BH-1178 made the ten crontabs, the env template and the lane
# registry renders of per-lane files. What NC-4 is worth is unchanged — that
# this parser still REACHES the table with no committed README — and it is
# worth more when the table is long, because bin/batch-resolve.sh regenerates
# every row it finds and silently regenerates nothing when it finds none. The
# rows are written out rather than counted: a row arriving without a reader is
# the thing tests/generated-files-train-test.sh GT-2 exists to stop, and the two
# lists must not be able to drift apart.
if command -v mc_regen_table >/dev/null 2>&1; then
  TBL=$(mc_regen_table "$SR" HEAD 2>/dev/null)
  WANT=$(printf '%s\n' \
    "$(printf 'docs/verification-map/README.md\tbin/verification-map-build.sh')" \
    "$(for b in project-4 hub project-6 project-1 project-3 project-10 project-9 small project-2 project-5; do
          printf 'cron/%s.cron\tbin/render-crontab.sh --from-fragments --all --write\n' "$b"; done)" \
    "$(printf 'env-templates/global.env.example\tbin/render-env-example.sh --write')" \
    "$(printf 'catalog/lanes.json\tbin/lanes-build.sh --write')" \
    "$(printf 'rules/CLAUDE.md\tbin/render-rules.sh --write')" \
    "$(printf 'docs/PR-OWNERSHIP.md\tbin/render-doc-sections.sh --write')" \
    "$(printf 'worker/jobs/schema.sql\tbin/schema-build.sh --write')")
  # Of the last three rows two are still COMMITTED: rules/CLAUDE.md (BH-1336),
  # a render five box scripts copy verbatim, and docs/PR-OWNERSHIP.md
  # (BH-5235.2), linked by path. worker/jobs/schema.sql, the composition of
  # worker/jobs/schema.d/, is not in git since BH-6005 (BH-5239.4 deleted the
  # Cloud schema row). Each is declared here so a conflict on it is regenerated
  # instead of hand merged. GT-2 pins the same list; the two must not drift.
  if [ "$TBL" = "$WANT" ]; then ok
  else bad "NC-4: mc_regen_table over a tree with NO committed README must still print the declared rows, the verification-map README among them (the table lives in docs/verification-map/index/tail.md). Got:
$(printf '%s' "$TBL" | cat -v)"; fi
else
  bad "NC-4: mc_regen_table could not be sourced from bin/lib/merge-conductor-lib.sh — the suite would test nothing"
fi

# ── NC-5 a duplicate row is refused ─────────────────────────────────────────
# The three main-red freezes were a duplicated row, produced by the union driver
# and committed. Byte-comparison cannot see one (a duplicated row regenerates to
# itself); this is what replaces it.
DUP="$SR/docs/verification-map/entries/BH-91003.md"
cp "$SR/docs/verification-map/entries/BH-91001.md" "$DUP" 2>/dev/null \
  || printf '%s\n' '| Feature 91001 | [nc-91001.md](nc-91001.md) | `bin/nc-91001.sh` |' > "$DUP"
OUT=$( cd "$SR" && bash bin/verification-map-build.sh --check 2>&1 ); RC=$?
[ "$RC" != 0 ] && ok || bad "NC-5: --check must FAIL when two entry files produce the same row (got rc $RC: $OUT)"
grep -q 'BH-91003.md\|duplicate' <<<"$OUT" && ok \
  || bad "NC-5: the duplicate-row refusal must name the duplicate. Got: $OUT"
rm -f "$DUP"
OUT=$( cd "$SR" && bash bin/verification-map-build.sh --check 2>&1 ); RC=$?
[ "$RC" = 0 ] && ok || bad "NC-5: --check must pass once the duplicate is gone (got rc $RC: $OUT)"

# ── NC-6 an entry whose doc link resolves to nothing is refused ──────────────
BROKEN="$SR/docs/verification-map/entries/BH-91004.md"
printf '%s\n' '| Nowhere | [nc-nowhere.md](nc-nowhere.md) | `bin/nc-nowhere.sh` |' > "$BROKEN"
OUT=$( cd "$SR" && bash bin/verification-map-build.sh --check 2>&1 ); RC=$?
[ "$RC" != 0 ] && ok || bad "NC-6: --check must FAIL when an entry links a doc that does not exist (got rc $RC: $OUT)"
grep -q 'nc-nowhere.md' <<<"$OUT" && ok \
  || bad "NC-6: the dead-link refusal must name the missing document. Got: $OUT"
rm -f "$BROKEN"

# ── NC-8 a branch that still commits the index MERGES, it does not conflict ──
# THE DAY-ONE CASE. 48 of the 63 PRs open when this landed carried a commit that
# regenerated the index, so merging this change into any of them is a
# modify/delete — and git resolves a modify/delete by leaving OUR file in the
# worktree with NO conflict markers. The `*.md` union resolver finds zero marker
# blocks and fails, so without a guard the harness's own rebase lanes call the
# path a REAL conflict and buy one blocked-resolver fix round per PR, on a file
# the repo has just decided nothing may commit.
#
# Its own repository, because the shape needs a base that COMMITS the index: the
# fixture above is already post-BH-1175 and could never produce a modify/delete.
# Drives the REAL mc_resolve_conflicts against a REAL merge.
if command -v mc_resolve_conflicts >/dev/null 2>&1; then
  OLD="$T/oldstyle"
  mkdir -p "$OLD/bin" "$OLD/docs/verification-map/index" "$OLD/docs/verification-map/entries"
  git init -q -b main "$OLD"
  printf '# Map\n' > "$OLD/docs/verification-map/index/head.md"
  printf '## Driving conventions\n\n- Drive the real script.\n' > "$OLD/docs/verification-map/index/tail.md"
  printf '%s\n' '| Alpha | [alpha.md](alpha.md) | `bin/alpha.sh` |' > "$OLD/docs/verification-map/entries/BH-1.md"
  printf '# alpha\n' > "$OLD/docs/verification-map/alpha.md"
  printf 'echo alpha\n' > "$OLD/bin/alpha.sh"
  cp "$VMB" "$OLD/bin/verification-map-build.sh"; chmod +x "$OLD/bin/verification-map-build.sh"
  ( cd "$OLD" && bash bin/verification-map-build.sh >/dev/null 2>&1 )
  git -C "$OLD" add -A >/dev/null 2>&1
  git -C "$OLD" commit -qm "the pre-BH-1175 layout: the index is COMMITTED"
  OLD_BASE=$(git -C "$OLD" rev-parse HEAD)

  # The branch: adds an entry and regenerates, committing the index — what all
  # 48 of those PRs did.
  git -C "$OLD" checkout -q -b ticket/bh-90099 "$OLD_BASE"
  printf '%s\n' '| Old style | [old.md](old.md) | `bin/old.sh` |' > "$OLD/docs/verification-map/entries/BH-90099.md"
  printf '# old\n' > "$OLD/docs/verification-map/old.md"
  ( cd "$OLD" && bash bin/verification-map-build.sh >/dev/null 2>&1 )
  git -C "$OLD" add -A >/dev/null 2>&1
  git -C "$OLD" commit -qm "BH-90099, the old way"

  # main does what this ticket does: untrack the index and ignore the path.
  git -C "$OLD" checkout -q main
  git -C "$OLD" rm -q --cached docs/verification-map/README.md >/dev/null 2>&1
  printf '%s\n' 'docs/verification-map/README.md' > "$OLD/.gitignore"
  git -C "$OLD" add -A >/dev/null 2>&1
  git -C "$OLD" commit -qm "BH-1175 on main"

  git -C "$OLD" checkout -q ticket/bh-90099
  git -C "$OLD" merge -q --no-edit main >/dev/null 2>&1
  CONF=$(git -C "$OLD" diff --name-only --diff-filter=U)
  if grep -qx 'docs/verification-map/README.md' <<<"$CONF"; then ok
  else bad "NC-8: the fixture did not produce the modify/delete this case is about — it proves nothing (conflicts: ${CONF:-none})"; fi
  # And it really has no markers, which is why the union resolver cannot help.
  grep -q '<<<<<<<' "$OLD/docs/verification-map/README.md" 2>/dev/null \
    && bad "NC-8: the fixture has conflict markers — then this is not the modify/delete shape" || ok

  OUT=$(mc_resolve_conflicts "$OLD" ticket/bh-90099 2>/dev/null); RC=$?
  [ "$RC" = 0 ] && ok \
    || bad "NC-8: the real mc_resolve_conflicts must RESOLVE a deleted-and-ignored index, not report a conflict (rc=$RC, conflicts: $OUT)"
  [ -z "$(git -C "$OLD" diff --name-only --diff-filter=U)" ] && ok \
    || bad "NC-8: the path must be left resolved, not unmerged"
  [ -z "$(git -C "$OLD" ls-files -- docs/verification-map/README.md 2>/dev/null)" ] && ok \
    || bad "NC-8: the resolution must UNTRACK the index — re-tracking it is what makes the next --check refuse the head"
  git -C "$OLD" commit -qm "merged" >/dev/null 2>&1
  OUT=$( cd "$OLD" && bash bin/verification-map-build.sh --check 2>&1 ); RC=$?
  [ "$RC" = 0 ] && ok || bad "NC-8: --check must pass on the merged head (got rc $RC: $OUT)"
  # The branch's own entry row survived, so nothing was lost with the index:
  # dropping it is safe BECAUSE the rows live in files of their own.
  [ -f "$OLD/docs/verification-map/entries/BH-90099.md" ] && ok \
    || bad "NC-8: the branch's entry file must survive — that is what makes dropping the index safe"
  # A modify/delete on a TRACKED path is still a REAL conflict. Without this the
  # guard could be quietly dropping every deletion in the repo and the case
  # above would read exactly the same. A script, not a doc: `.md` has its own
  # union arm, so a markdown control would grade that arm instead of this guard.
  git -C "$OLD" checkout -q -b ticket/bh-90098 "$OLD_BASE"
  printf 'echo branch side\n' >> "$OLD/bin/alpha.sh"
  git -C "$OLD" add -A >/dev/null 2>&1
  git -C "$OLD" commit -qm "BH-90098 edits a tracked script" >/dev/null 2>&1
  git -C "$OLD" checkout -q main
  git -C "$OLD" rm -q bin/alpha.sh >/dev/null 2>&1
  git -C "$OLD" commit -qm "main deletes a TRACKED script" >/dev/null 2>&1
  git -C "$OLD" checkout -q ticket/bh-90098
  git -C "$OLD" merge -q --no-edit main >/dev/null 2>&1
  OUT=$(mc_resolve_conflicts "$OLD" ticket/bh-90098 2>/dev/null); RC=$?
  [ "$RC" = 1 ] && ok \
    || bad "NC-8: a modify/delete on a TRACKED path must STAY a real conflict — the guard may only act where .gitignore says the file must not be in git (rc=$RC)"
  git -C "$OLD" merge --abort >/dev/null 2>&1
else
  bad "NC-8: mc_resolve_conflicts could not be sourced from bin/lib/merge-conductor-lib.sh — the suite would test nothing"
fi

# ── NC-9 the guard is ORIENTATION-AWARE: only a BASE-side deletion is taken ──
# THE DATA-LOSS MIRROR IMAGE. NC-8 proves the base deleting an ignored file
# resolves. The reverse — the BRANCH deletes a tracked-but-ignored file and the
# BASE still edits it — must stay a real conflict: taking the deletion there
# throws the base's edit away with no conflict for anyone to look at, no log
# line a reviewer would read as loss, and no way back. The first cut of the
# guard tested only "not both sides present" and did exactly that.
#
# A `*.log` path rather than the index, because the shape is general: the
# resolver runs against every target repo's own .gitignore, and any repo can
# have a file that is both tracked and ignored (this one had
# locks-worker/.wrangler/cache/cf.json until BH-5518 C2).
if command -v mc_resolve_conflicts >/dev/null 2>&1; then
  ORI="$T/orientation"
  mkdir -p "$ORI/docs"
  git init -q -b main "$ORI"
  printf 'base line\n' > "$ORI/docs/x.log"
  printf '%s\n' '*.log' > "$ORI/.gitignore"
  git -C "$ORI" add -A -f >/dev/null 2>&1
  git -C "$ORI" commit -qm "a file that is TRACKED and IGNORED at once"
  ORI_BASE=$(git -C "$ORI" rev-parse HEAD)
  # Sanity: the fixture really is the awkward shape, or the case proves nothing.
  { [ -n "$(git -C "$ORI" ls-files -- docs/x.log)" ] \
    && git -C "$ORI" check-ignore -q --no-index -- docs/x.log; } && ok \
    || bad "NC-9: the fixture file must be BOTH tracked and ignored — otherwise this case is not the shape under test"

  git -C "$ORI" checkout -q -b ticket/bh-90097 "$ORI_BASE"
  git -C "$ORI" rm -q docs/x.log >/dev/null 2>&1
  git -C "$ORI" commit -qm "BH-90097 deletes it on the BRANCH"
  git -C "$ORI" checkout -q main
  printf 'base edited this after the branch was cut\n' > "$ORI/docs/x.log"
  git -C "$ORI" add -f docs/x.log >/dev/null 2>&1
  git -C "$ORI" commit -qm "main EDITS it"
  MAIN_BODY=$(git -C "$ORI" show HEAD:docs/x.log)

  git -C "$ORI" checkout -q ticket/bh-90097
  git -C "$ORI" merge -q --no-edit main >/dev/null 2>&1
  CONF9=$(git -C "$ORI" diff --name-only --diff-filter=U)
  grep -qx 'docs/x.log' <<<"$CONF9" && ok \
    || bad "NC-9: the fixture did not produce the delete/modify this case is about (conflicts: ${CONF9:-none})"

  OUT=$(mc_resolve_conflicts "$ORI" ticket/bh-90097 2>/dev/null); RC=$?
  [ "$RC" = 1 ] && ok \
    || bad "NC-9: a BRANCH-side deletion of a file the BASE modified must stay a REAL conflict — taking it discards the base's edit silently (rc=$RC)"
  [ "$(git -C "$ORI" show main:docs/x.log 2>/dev/null)" = "$MAIN_BODY" ] && ok \
    || bad "NC-9: the base's content must be intact — this is the data-loss assertion"
  git -C "$ORI" merge --abort >/dev/null 2>&1
else
  bad "NC-9: mc_resolve_conflicts could not be sourced — the suite would test nothing"
  bad "NC-9: not reached"
  bad "NC-9: not reached"
  bad "NC-9: not reached"
fi

# ── NC-10 a PR cannot switch its own gate off by deleting the ignore line ────
# The verdict is "the index is TRACKED", not "tracked AND ignored". The narrower
# form left the obvious way back in wide open: drop the .gitignore line, force
# the file in, and --check passes while main quietly commits the artifact again.
( cd "$SR" && bash bin/verification-map-build.sh >/dev/null 2>&1 )
cp "$SR/.gitignore" "$T/gitignore.keep"
: > "$SR/.gitignore"
git -C "$SR" add -A "$SR/.gitignore" >/dev/null 2>&1
git -C "$SR" add docs/verification-map/README.md >/dev/null 2>&1
git -C "$SR" commit -qm "drop the ignore line and commit the index" >/dev/null 2>&1
if [ -n "$(git -C "$SR" ls-files -- docs/verification-map/README.md)" ]; then ok
else bad "NC-10: the fixture failed to track the index without the ignore rule — the case proves nothing"; fi
OUT=$( cd "$SR" && bash bin/verification-map-build.sh --check 2>&1 ); RC=$?
[ "$RC" != 0 ] && ok \
  || bad "NC-10: --check must refuse a TRACKED index even when .gitignore no longer covers it, or a PR can switch its own gate off (got rc $RC: $OUT)"
grep -q 'gitignore no longer covers it' <<<"$OUT" && ok \
  || bad "NC-10: the refusal must also name the missing ignore line, or the fix puts the file back next build. Got: $OUT"
git -C "$SR" rm -q --cached docs/verification-map/README.md >/dev/null 2>&1
cp "$T/gitignore.keep" "$SR/.gitignore"
git -C "$SR" add -A >/dev/null 2>&1
git -C "$SR" commit -qm "restore" >/dev/null 2>&1
OUT=$( cd "$SR" && bash bin/verification-map-build.sh --check 2>&1 ); RC=$?
[ "$RC" = 0 ] && ok || bad "NC-10: --check must pass again once both are restored (got rc $RC: $OUT)"

# ── NC-7 the write path still works, and is still deterministic ─────────────
( cd "$SR" && bash bin/verification-map-build.sh >/dev/null 2>&1 )
cp "$SR/docs/verification-map/README.md" "$T/first" 2>/dev/null
( cd "$SR" && bash bin/verification-map-build.sh >/dev/null 2>&1 )
cmp -s "$T/first" "$SR/docs/verification-map/README.md" && ok \
  || bad "NC-7: two runs of the generator over the same sources produced different bytes"

done_
