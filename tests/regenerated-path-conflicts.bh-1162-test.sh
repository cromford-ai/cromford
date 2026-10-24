#!/bin/bash
# tests/regenerated-path-conflicts.bh-1162-test.sh — a conflict on
# docs/notes/INDEX.md is resolved by RE-RENDERING it over the merged tree.
#
# WHAT THIS PINS (BH-1162, found landing #1097). INDEX.md is rendered by
# bin/render-doc-index.sh from the dated notes beside it, and every PR that adds
# a note and re-renders touches the same few lines of it. Two such PRs conflict
# on INDEX.md and on nothing else. Before this ticket the conductor had no rule
# for the path: it carries no ticket key, so mc_resolve_generated passed, and it
# fell to the `*.md` UNION arm, which glues both sides of the hunk into a
# "sorted" index with rows out of order or twice. the operator's ruling on the ticket
# (2026-09-24): "regenerate on conflict. Do not use merge=union ... Acceptance:
# two PRs that each add a note both land, and the conductor regenerates the
# index with no human involved."
#
# TEST-CHANGE (BH-8254): docs/notes/INDEX.md left git (.gitignore) and so
# left the regenerate registry. Section 1 now pins that it has NO row, in the
# conf or the compiled default. Sections 2-3 still drive the whole regenerate
# mechanism on the same INDEX.md fixture, through a scratch conf that names the
# row ($T/regen.conf), because the fixture repos still COMMIT a render: the
# shape this mechanism exists for. Section 4 flips "must stay tracked" to "must
# not be tracked, and .gitignore covers it".
#
# WHY REAL GIT. The question is what git's index holds mid-merge and whether the
# file the generator writes is what gets staged. A fake git pins none of that,
# so every section below makes a real conflicting merge and reads real bytes.
# Run from anywhere: tests/regenerated-path-conflicts.bh-1162-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The library is sourced against a SCRATCH harness, never /root/harness.
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/config"
cp "$DIR/config/generated-paths.conf" "$T/h/config/"
[ -r "$DIR/config/regenerated-paths.conf" ] && cp "$DIR/config/regenerated-paths.conf" "$T/h/config/"
# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh"
mc_init
MCLOG="$T/h/logs/merge-conductor.log"

# ---------------------------------------------------------------------------
# 1. THE TABLE: one exact path, one command, conf and compiled default agree
# ---------------------------------------------------------------------------
[ -r "$DIR/config/regenerated-paths.conf" ] && ok || bad "config/regenerated-paths.conf is missing"
mc_regen_cmd_for_path docs/notes/INDEX.md >/dev/null 2>&1 \
  && bad "docs/notes/INDEX.md left git (BH-8254): the conf must have no row for it" || ok
MC_REGENERATED_PATHS_CONF="$T/no-such.conf" mc_regen_cmd_for_path docs/notes/INDEX.md >/dev/null 2>&1 \
  && bad "docs/notes/INDEX.md left git (BH-8254): the compiled default must have no row for it" || ok
FROM_CONF=$(mc_regen_paths 2>/dev/null)
FROM_DEFAULT=$(MC_REGENERATED_PATHS_CONF="$T/no-such.conf" mc_regen_paths 2>/dev/null)
[ -n "$FROM_CONF" ] && [ "$FROM_CONF" = "$FROM_DEFAULT" ] && ok \
  || bad "config/regenerated-paths.conf and MC_REGENERATED_PATHS_DEFAULT disagree: conf='$FROM_CONF' default='$FROM_DEFAULT'"
# From here on the regenerate mechanism runs on a conf that names the row.
printf 'docs/notes/INDEX.md\tbin/render-doc-index.sh\n' > "$T/regen.conf"
export MC_REGENERATED_PATHS_CONF="$T/regen.conf"
CMD=$(mc_regen_cmd_for_path docs/notes/INDEX.md 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ "$CMD" = bin/render-doc-index.sh ] && ok \
  || bad "with the scratch conf, docs/notes/INDEX.md should map to bin/render-doc-index.sh (rc=$RC, got '$CMD')"
# Exact match only: a glob would let `*` span `/` in `case`.
for p in docs/notes/README.md docs/notes/INDEX.md.orig other/docs/notes/INDEX.md \
         docs/verification-map/README.md docs/notes/2026-09-24-BH-1-x.md INDEX.md ""; do
  mc_regen_cmd_for_path "$p" >/dev/null 2>&1 && bad "'$p' must NOT be in the regenerate class" || ok
done
# The conf reaches every box: config/ is synced and propagated whole.
grep -q 'rsync -a --delete "$CHECKOUT/config/"' "$DIR/bin/harness-sync.sh" && ok || bad "harness-sync.sh no longer syncs config/"
grep -Eq '^FLEET_PATHS=".* config/ ' "$DIR/bin/lib/fleet-paths.sh" && ok || bad "bin/lib/fleet-paths.sh FLEET_PATHS no longer lists config/"

# ---------------------------------------------------------------------------
# Fixture: a repo shaped like this one — the real renderer, docs/notes/, a
# rendered INDEX.md. Two PRs each add a note and re-render.
# ---------------------------------------------------------------------------
note() { # note <repo> <file> <title>
  printf '# %s\n\nDoc: MERGE-CONDUCTOR\n\nBody of %s.\n' "$3" "$3" > "$1/docs/notes/$2"
}
render() { ( cd "$1" && bin/render-doc-index.sh >/dev/null 2>&1 ); }
# mkrepo <dir> <branch> — main has one note; <branch> adds B, main adds C,
# each re-renders; <branch> is checked out. The merge is left to the caller.
mkrepo() {
  local R="$1" br="$2"
  scratch_rm "$R" || return 1; mkdir -p "$R/bin" "$R/docs/notes"
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t; git -C "$R" config user.name t
  git -C "$R" config commit.gpgsign false
  cp "$DIR/bin/render-doc-index.sh" "$R/bin/"
  note "$R" 2026-09-01-BH-1-first.md "First note"
  render "$R"
  git -C "$R" add -A; git -C "$R" commit -qm base
  git -C "$R" checkout -q -b "$br"
  note "$R" 2026-09-10-BH-9001-branch-note.md "Branch note B"
  render "$R"
  git -C "$R" add -A; git -C "$R" commit -qm "B"
  git -C "$R" checkout -q main
  note "$R" 2026-09-11-BH-9002-main-note.md "Main note C"
  render "$R"
  git -C "$R" add -A; git -C "$R" commit -qm "C"
  git -C "$R" checkout -q "$br"
}
unmerged() { git -C "$1" ls-files -u -- "$2"; }
# fresh <repo> — what the renderer writes over the repo's notes right now.
fresh() { "$DIR/bin/render-doc-index.sh" "$1/docs/notes" "$T/fresh.md" >/dev/null 2>&1; cat "$T/fresh.md"; }

# ---------------------------------------------------------------------------
# 2. E2E through mc_resolve_conflicts, the production entry point (mc_rebase
#    and rebase-job.sh both call it): two note PRs both land.
# ---------------------------------------------------------------------------
for BR in ticket/bh-9001 design/foo; do
  R="$T/repo-${BR//\//-}"
  mkrepo "$R" "$BR"
  git -C "$R" merge -q --no-edit main >/dev/null 2>&1 && bad "[$BR] the fixture should conflict"
  CONF=$(git -C "$R" diff --name-only --diff-filter=U | tr '\n' ' ')
  [ "$CONF" = "docs/notes/INDEX.md " ] && ok || bad "[$BR] expected a conflict on INDEX.md alone, got: $CONF"
  : > "$MCLOG"
  OUT=$(mc_resolve_conflicts "$R" "$BR"); RC=$?
  [ "$RC" = 0 ] && ok || bad "[$BR] mc_resolve_conflicts should regenerate INDEX.md (rc=$RC, left: $OUT)"
  [ -z "$OUT" ] && ok || bad "[$BR] a resolved conflict prints nothing on stdout (the generator's own output leaked?): $OUT"
  [ -z "$(git -C "$R" ls-files -u)" ] && ok || bad "[$BR] paths left unmerged: $(git -C "$R" ls-files -u)"
  [ "$(cat "$R/docs/notes/INDEX.md")" = "$(fresh "$R")" ] && ok \
    || bad "[$BR] INDEX.md is not a fresh render of the merged notes: $(diff <(fresh "$R") "$R/docs/notes/INDEX.md")"
  [ "$(git -C "$R" show :docs/notes/INDEX.md)" = "$(fresh "$R")" ] && ok || bad "[$BR] the STAGED index is not the fresh render"
  [ "$(grep -c 'Branch note B' "$R/docs/notes/INDEX.md")" = 1 ] && ok || bad "[$BR] note B should be listed exactly once"
  [ "$(grep -c 'Main note C' "$R/docs/notes/INDEX.md")" = 1 ] && ok || bad "[$BR] note C should be listed exactly once"
  [ "$(grep -c 'First note' "$R/docs/notes/INDEX.md")" = 1 ] && ok || bad "[$BR] the base note should be listed exactly once"
  grep -Eq '^(<<<<<<<|=======|>>>>>>>)' "$R/docs/notes/INDEX.md" && bad "[$BR] conflict markers in the index" || ok
  grep -q 'regenerated path docs/notes/INDEX.md resolved by re-running bin/render-doc-index.sh' "$MCLOG" && ok \
    || bad "[$BR] no conductor log line for the regenerate: $(cat "$MCLOG")"
  git -C "$R" commit -q --no-edit >/dev/null 2>&1 && ok || bad "[$BR] the resolved merge must commit"
  [ -z "$(git -C "$R" status --porcelain)" ] && ok || bad "[$BR] the regenerate left the tree dirty: $(git -C "$R" status --porcelain)"
done

# 2b. Order: the notes themselves conflict too. A note that sorts BEFORE
# INDEX.md (dated) and one that sorts AFTER it (lowercase) are both unioned by
# the `*.md` arm; the index is rendered only once both are staged, so it lists
# each exactly once.
R="$T/repo-order"; mkrepo "$R" ticket/bh-9001
note "$R" 2026-09-12-BH-9003-shared.md "Shared note (branch)"
printf '# zeta\n\nDoc: EVENTS\n\nbranch side\n' > "$R/docs/notes/zeta.md"
render "$R"; git -C "$R" add -A; git -C "$R" commit -qm "branch adds the shared notes"
git -C "$R" checkout -q main
note "$R" 2026-09-12-BH-9003-shared.md "Shared note (main)"
printf '# zeta\n\nDoc: EVENTS\n\nmain side\n' > "$R/docs/notes/zeta.md"
render "$R"; git -C "$R" add -A; git -C "$R" commit -qm "main adds the shared notes"
git -C "$R" checkout -q ticket/bh-9001
git -C "$R" merge -q --no-edit main >/dev/null 2>&1
CONF=$(git -C "$R" diff --name-only --diff-filter=U | tr '\n' ' ')
[ "$CONF" = "docs/notes/2026-09-12-BH-9003-shared.md docs/notes/INDEX.md docs/notes/zeta.md " ] && ok \
  || bad "[order] expected three conflicts, got: $CONF"
OUT=$(mc_resolve_conflicts "$R" ticket/bh-9001); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "[order] should resolve all three (rc=$RC, left: $OUT)"
[ "$(cat "$R/docs/notes/INDEX.md")" = "$(fresh "$R")" ] && ok || bad "[order] INDEX.md is not a fresh render of the merged notes"
[ "$(grep -c 'BH-9003-shared.md' "$R/docs/notes/INDEX.md")" = 1 ] && ok || bad "[order] the shared note should be listed exactly once"
[ "$(grep -c '(zeta.md)' "$R/docs/notes/INDEX.md")" = 1 ] && ok || bad "[order] zeta.md should be listed exactly once"
[ -z "$(git -C "$R" ls-files -u)" ] && ok || bad "[order] paths left unmerged"

# ---------------------------------------------------------------------------
# 3. NEGATIVES: a real conflict stays real. Each leaves INDEX.md unmerged with
#    its markers, and mc_resolve_conflicts never unions it instead.
# ---------------------------------------------------------------------------
# conflicted <repo> <label> — INDEX.md still has stages and markers.
conflicted() {
  [ -n "$(unmerged "$1" docs/notes/INDEX.md)" ] && ok || bad "[$2] INDEX.md should still be unmerged"
  grep -q '^<<<<<<<' "$1/docs/notes/INDEX.md" && ok || bad "[$2] INDEX.md should carry its conflict markers again"
}

# 3a. The generator is absent from the merged tree (another project's repo).
R="$T/repo-neg"; mkrepo "$R" ticket/bh-9001
git -C "$R" merge -q --no-edit main >/dev/null 2>&1
rm -f "$R/bin/render-doc-index.sh"
mc_resolve_generated "$R" docs/notes/INDEX.md BH-9001; RC=$?
[ "$RC" = 1 ] && ok || bad "[no generator] mc_resolve_generated should be rc 1, got $RC"
conflicted "$R" "no generator"
OUT=$(mc_resolve_conflicts "$R" ticket/bh-9001); RC=$?
[ "$RC" = 1 ] && grep -qx 'docs/notes/INDEX.md' <<<"$OUT" && ok \
  || bad "[no generator] mc_resolve_conflicts should report INDEX.md as a real conflict (rc=$RC, out: $OUT)"
conflicted "$R" "no generator, via mc_resolve_conflicts (no union)"
git -C "$R" merge --abort; git -C "$R" checkout -q -- .

# 3b. The generator exits non-zero.
git -C "$R" merge -q --no-edit main >/dev/null 2>&1
printf '#!/bin/sh\necho "stub render failed on purpose"\nexit 1\n' > "$R/bin/render-doc-index.sh"
: > "$MCLOG"
mc_resolve_generated "$R" docs/notes/INDEX.md BH-9001 >"$T/stdout" 2>&1; RC=$?
[ "$RC" = 1 ] && ok || bad "[generator fails] mc_resolve_generated should be rc 1, got $RC"
[ -s "$T/stdout" ] && bad "[generator fails] the generator's output leaked to stdout: $(cat "$T/stdout")" || ok
conflicted "$R" "generator fails"
grep -q 'docs/notes/INDEX.md.*stub render failed on purpose' "$MCLOG" && ok \
  || bad "[generator fails] the conductor log should carry the generator's failure: $(cat "$MCLOG")"
OUT=$(mc_resolve_conflicts "$R" ticket/bh-9001); RC=$?
[ "$RC" = 1 ] && ok || bad "[generator fails] mc_resolve_conflicts should be rc 1, got $RC"
conflicted "$R" "generator fails, via mc_resolve_conflicts (no union)"
git -C "$R" merge --abort; git -C "$R" checkout -q -- .

# 3c. A sibling note is still unmerged: the index is not rendered over markers.
git -C "$R" checkout -q main
note "$R" 2026-09-12-BH-9003-shared.md "Shared (main)"; render "$R"
git -C "$R" add -A; git -C "$R" commit -qm "main shared"
git -C "$R" checkout -q ticket/bh-9001
note "$R" 2026-09-12-BH-9003-shared.md "Shared (branch)"; render "$R"
git -C "$R" add -A; git -C "$R" commit -qm "branch shared"
git -C "$R" merge -q --no-edit main >/dev/null 2>&1
[ -n "$(unmerged "$R" docs/notes/2026-09-12-BH-9003-shared.md)" ] && ok || bad "[sibling] fixture: the note should conflict"
mc_resolve_generated "$R" docs/notes/INDEX.md BH-9001; RC=$?
[ "$RC" = 1 ] && ok || bad "[sibling unmerged] mc_resolve_generated should be rc 1, got $RC"
conflicted "$R" "sibling unmerged"
git -C "$R" merge --abort; git -C "$R" checkout -q -- .

# 3d. modify/delete: main deleted INDEX.md, the branch re-rendered it.
R="$T/repo-md"; mkrepo "$R" ticket/bh-9001
git -C "$R" checkout -q main; git -C "$R" rm -q docs/notes/INDEX.md; git -C "$R" commit -qm "drop index"
git -C "$R" checkout -q ticket/bh-9001
git -C "$R" merge -q --no-edit main >/dev/null 2>&1
STAGES0=$(unmerged "$R" docs/notes/INDEX.md)
[ -n "$STAGES0" ] && ok || bad "[modify/delete] fixture should conflict"
mc_resolve_generated "$R" docs/notes/INDEX.md BH-9001; RC=$?
[ "$RC" = 1 ] && ok || bad "[modify/delete] mc_resolve_generated should be rc 1, got $RC"
[ "$(unmerged "$R" docs/notes/INDEX.md)" = "$STAGES0" ] && ok || bad "[modify/delete] the stages must be left exactly as they were"
OUT=$(mc_resolve_conflicts "$R" ticket/bh-9001); RC=$?
[ "$RC" = 1 ] && ok || bad "[modify/delete] mc_resolve_conflicts should be rc 1, got $RC"

# ---------------------------------------------------------------------------
# 4. THE NEGATIVE PINS FROM THE RULING
# ---------------------------------------------------------------------------
# "Do not use merge=union": no attribute on INDEX.md.
[ "$(git -C "$DIR" check-attr merge docs/notes/INDEX.md)" = "docs/notes/INDEX.md: merge: unspecified" ] && ok \
  || bad "docs/notes/INDEX.md must carry no merge attribute: $(git -C "$DIR" check-attr merge docs/notes/INDEX.md)"
# BH-8254 took option 3 (stop committing it): the file is not tracked, and
# .gitignore covers it.
git -C "$DIR" ls-files --error-unmatch docs/notes/INDEX.md >/dev/null 2>&1 && bad "docs/notes/INDEX.md must not be tracked (BH-8254)" || ok
git -C "$DIR" check-ignore -q --no-index docs/notes/INDEX.md && ok || bad ".gitignore must cover docs/notes/INDEX.md (BH-8254)"
# Widening what the conductor resolves with no human is guard-sensitive.
# shellcheck source=/dev/null
. "$DIR/bin/lib/guard-silenced.sh"
gs_is_guard config/regenerated-paths.conf && ok || bad "guard-silenced must classify config/regenerated-paths.conf as a guard path"

echo "regenerated-path-conflicts.bh-1162-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
