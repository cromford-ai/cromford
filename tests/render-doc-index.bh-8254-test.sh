#!/bin/bash
# tests/render-doc-index.bh-8254-test.sh — docs/notes/INDEX.md is a git-ignored
# render, and `bin/render-doc-index.sh --check` validates the notes instead of
# comparing bytes with a committed copy.
#
# WHY (BH-8254). The committed INDEX.md went stale on every PR that added a
# note. PR #7181 put the old byte `--check` into CI, and Mergify draft #8239
# dequeued it six minutes later, because #8060 merged first with one new note.
# The fix is the BH-1175 shape (docs/verification-map/README.md): the file
# leaves git, every reader renders its own copy, and `--check` validates the
# SOURCES and refuses a tracked index. The old compare is `--check-committed`.
#
# rc contract of --check pinned here:
#   rc 0 = the notes are valid, the render is deterministic, the index is untracked
#   rc 1 = a note has an empty Doc: line, two notes render the same row, or
#          the index is tracked in git
#   rc 2 = the check could not run (no notes dir, no temp dir)
#
# Sections: C1-C15 the --check contract, M1 two note PRs merge with no
# conflict, R1 docs-sync renders the index, R2 the share mirror renders it,
# R3 CI runs the check, R4 no regenerate row and no stale instruction left.
# Every case seeds its own scratch repo under $T. No clock, no vendor call.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
R="$DIR/bin/render-doc-index.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# mkrepo <dir> — a git repo shaped like this one: the real renderer and the
# real .gitignore, two notes committed, no index committed.
mkrepo() {
  local D="$1"
  mkdir -p "$D/bin" "$D/docs/notes"
  git -C "$D" init -q -b main
  git -C "$D" config user.email t@t; git -C "$D" config user.name t
  git -C "$D" config commit.gpgsign false
  cp "$R" "$D/bin/"
  cp "$DIR/.gitignore" "$D/.gitignore"
  note "$D" 2026-09-01-BH-1-one.md "Note one" "EVENTS"
  note "$D" 2026-09-02-BH-2-two.md "Note two" "MERGE-CONDUCTOR"
  git -C "$D" add -A; git -C "$D" commit -qm base
}
# note <repo> <file> <title> <doc-line-value>
note() { printf '# %s\n\nDoc: %s\n\nBody.\n' "$3" "$4" > "$1/docs/notes/$2"; }
chk() { "$1/bin/render-doc-index.sh" --check 2>&1; }

# ── C1. a new note, no render, a stale untracked index on disk: rc 0 ─────────
D="$T/c1"; mkrepo "$D"
printf '# Notes index\n\n- stale row from last week\n' > "$D/docs/notes/INDEX.md"
touch -d '2026-01-01 00:00:00' "$D/docs/notes/INDEX.md"
SUM0=$(sha256sum < "$D/docs/notes/INDEX.md"); MT0=$(stat -c %Y "$D/docs/notes/INDEX.md")
note "$D" 2026-09-03-BH-3-three.md "Note three" "EVENTS"
OUT=$(chk "$D"); RC=$?
[ "$RC" = 0 ] && ok || bad "C1: a new note with no render and a stale untracked index must be rc 0, got rc=$RC: $OUT"
[ "$(sha256sum < "$D/docs/notes/INDEX.md")" = "$SUM0" ] && ok || bad "C1: --check changed the index bytes"
[ "$(stat -c %Y "$D/docs/notes/INDEX.md")" = "$MT0" ] && ok || bad "C1: --check touched the index mtime"
[ -z "$(git -C "$D" status --porcelain -- docs/notes/INDEX.md)" ] && ok \
  || bad "C1: the real .gitignore must cover docs/notes/INDEX.md: $(git -C "$D" status --porcelain -- docs/notes/INDEX.md)"

# ── C2. the index tracked (git add -f): rc 1, names TRACKED and the fix ──────
git -C "$D" add -f docs/notes/INDEX.md
OUT=$(chk "$D"); RC=$?
[ "$RC" = 1 ] && ok || bad "C2: a tracked index must be rc 1, got rc=$RC: $OUT"
has "TRACKED" "$OUT" && has "git rm --cached docs/notes/INDEX.md" "$OUT" && ok \
  || bad "C2: the output must name TRACKED and 'git rm --cached docs/notes/INDEX.md', got: $OUT"
has ".gitignore no longer covers it" "$OUT" && bad "C2: .gitignore still covers it, so no .gitignore hint: $OUT" || ok

# ── C3. tracked AND the ignore line deleted: rc 1 plus the .gitignore hint ───
: > "$D/.gitignore"
OUT=$(chk "$D"); RC=$?
[ "$RC" = 1 ] && ok || bad "C3: tracked and not ignored must be rc 1, got rc=$RC: $OUT"
has ".gitignore no longer covers it" "$OUT" && ok || bad "C3: the output must carry the .gitignore hint, got: $OUT"

# ── C4-C6. a Doc: line that yields no tag: rc 1, names the note ──────────────
for c in "C4|Doc:" "C5|Doc: , ," "C6|doc:   "; do
  label="${c%%|*}"; line="${c#*|}"
  D="$T/$label"; mkrepo "$D"
  printf '# Bad note\n\n%s\n\nBody.\n' "$line" > "$D/docs/notes/2026-09-05-BH-5-bad-$label.md"
  OUT=$(chk "$D"); RC=$?
  [ "$RC" = 1 ] && ok || bad "$label: '$line' must be rc 1, got rc=$RC: $OUT"
  has "2026-09-05-BH-5-bad-$label.md" "$OUT" && ok || bad "$label: the output must name the note, got: $OUT"
  has "Doc:" "$OUT" && ok || bad "$label: the output must say the Doc: line is the problem, got: $OUT"
done

# ── C7. near miss: an empty Doc: line inside a code fence only: rc 0 ─────────
D="$T/c7"; mkrepo "$D"
printf '# Fenced\n\n```\nDoc:\n```\n\nBody.\n' > "$D/docs/notes/2026-09-06-BH-6-fenced.md"
printf '# Tilde\n\n~~~\ndoc: ,\n~~~\n' > "$D/docs/notes/2026-09-06-BH-7-tilde.md"
OUT=$(chk "$D"); RC=$?
[ "$RC" = 0 ] && ok || bad "C7: an empty Doc: inside a fence must be rc 0, got rc=$RC: $OUT"

# ── C8. near misses: no Doc: line, free text, a markdown link, case: rc 0 ────
D="$T/c8"; mkrepo "$D"
printf '# No doc line\n\nBody.\n' > "$D/docs/notes/2026-09-07-BH-8-nodoc.md"
note "$D" 2026-09-07-BH-9-none.md "Free text" "none (a harness-only change)"
note "$D" 2026-09-07-BH-10-link.md "A link" "[docs/EVENTS.md](../EVENTS.md)"
printf '# Upper\n\nDOC: events\n' > "$D/docs/notes/2026-09-07-BH-11-upper.md"
note "$D" 2026-09-07-BH-12-twice.md "Twice" "EVENTS, events"
OUT=$(chk "$D"); RC=$?
[ "$RC" = 0 ] && ok || bad "C8: realistic notes must be rc 0, got rc=$RC: $OUT"

# ── C9. two notes render the same row: rc 1, names both files ────────────────
D="$T/c9"; mkrepo "$D"
note "$D" 2026-09-08-BH-13-dup-a.md "Same title" "EVENTS"
note "$D" 2026-09-08-BH-13-dup-b.md "Same title" "EVENTS"
OUT=$(chk "$D"); RC=$?
[ "$RC" = 1 ] && ok || bad "C9: two notes with the same tag, date and title must be rc 1, got rc=$RC: $OUT"
has "2026-09-08-BH-13-dup-a.md" "$OUT" && has "2026-09-08-BH-13-dup-b.md" "$OUT" && ok \
  || bad "C9: the output must name both notes, got: $OUT"
# Every failure is printed, not only the first: an empty Doc: in the same tree.
printf '# Bad\n\nDoc:\n' > "$D/docs/notes/2026-09-08-BH-14-empty.md"
OUT=$(chk "$D"); RC=$?
[ "$RC" = 1 ] && has "2026-09-08-BH-13-dup-b.md" "$OUT" && has "2026-09-08-BH-14-empty.md" "$OUT" && ok \
  || bad "C9: both failures must be printed, got rc=$RC: $OUT"

# ── C10/C11. near misses: same title, other date / other tag: rc 0 ───────────
D="$T/c10"; mkrepo "$D"
note "$D" 2026-09-08-BH-15-a.md "Same title" "EVENTS"
note "$D" 2026-09-09-BH-15-b.md "Same title" "EVENTS"
OUT=$(chk "$D"); RC=$?
[ "$RC" = 0 ] && ok || bad "C10: same title on two dates must be rc 0, got rc=$RC: $OUT"
D="$T/c11"; mkrepo "$D"
note "$D" 2026-09-08-BH-16-a.md "Same title" "EVENTS"
note "$D" 2026-09-08-BH-16-b.md "Same title" "OPERATOR-SETUP"
OUT=$(chk "$D"); RC=$?
[ "$RC" = 0 ] && ok || bad "C11: same title and date under two tags must be rc 0, got rc=$RC: $OUT"

# ── C12. rc 2 when the check cannot run; no temp file left on any rc ─────────
mkdir -p "$T/tmp12"
D="$T/c12"; mkrepo "$D"
TMPDIR="$T/tmp12" "$D/bin/render-doc-index.sh" --check >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "C12: the fixture must be rc 0, got $RC"
note "$D" 2026-09-10-BH-17-a.md "Dup" "EVENTS"; note "$D" 2026-09-10-BH-17-b.md "Dup" "EVENTS"
TMPDIR="$T/tmp12" "$D/bin/render-doc-index.sh" --check >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && ok || bad "C12: the dup fixture must be rc 1, got $RC"
TMPDIR="$T/tmp12" "$R" --check "$T/no-such-dir" "$T/x.md" >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && ok || bad "C12: no notes dir must be rc 2, got $RC"
OUT=$(TMPDIR="$T/no-such-tmp" "$D/bin/render-doc-index.sh" --check 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "C12: a missing TMPDIR must be rc 2, got rc=$RC: $OUT"
[ -z "$(ls -A "$T/tmp12")" ] && ok || bad "C12: --check left temp files in TMPDIR: $(ls -A "$T/tmp12")"
grep -q '^\.render-doc-index' <<<"$(ls -A "$D/docs/notes")" && bad "C12: --check left a temp file beside the index" || ok
[ -e "$D/docs/notes/INDEX.md" ] && bad "C12: --check wrote the index" || ok

# ── C13. --check-committed keeps the old byte contract ───────────────────────
D="$T/c13"; mkrepo "$D"
"$D/bin/render-doc-index.sh" >/dev/null 2>&1
"$D/bin/render-doc-index.sh" --check-committed >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "C13: --check-committed on a fresh render must be rc 0, got $RC"
note "$D" 2026-09-11-BH-18-new.md "New note" "EVENTS"
OUT=$("$D/bin/render-doc-index.sh" --check-committed 2>&1); RC=$?
[ "$RC" = 1 ] && has "is stale" "$OUT" && ok || bad "C13: --check-committed on drift must be rc 1 and say stale, got rc=$RC: $OUT"
# The plain render on this repo reads back clean through the compare mode.
"$R" "$DIR/docs/notes" "$T/real-index.md" >/dev/null 2>&1 || bad "C13: the plain render of the real notes failed"
"$R" --check-committed "$DIR/docs/notes" "$T/real-index.md" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "C13: a plain render must match --check-committed, got $RC"

# ── C14. the real tree: --check rc 0 ─────────────────────────────────────────
mkdir -p "$T/tmp14"
OUT=$(TMPDIR="$T/tmp14" "$R" --check 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "C14: bin/render-doc-index.sh --check on this tree must be rc 0, got rc=$RC: $OUT"
[ -z "$(ls -A "$T/tmp14")" ] && ok || bad "C14: --check left temp files: $(ls -A "$T/tmp14")"

# ── C15. the real tree: INDEX.md is not tracked, and .gitignore covers it ────
[ -z "$(git -C "$DIR" ls-files docs/notes/INDEX.md)" ] && ok || bad "C15: docs/notes/INDEX.md is still tracked in git"
git -C "$DIR" check-ignore -q --no-index docs/notes/INDEX.md && ok || bad "C15: .gitignore must cover docs/notes/INDEX.md"

# ── M1. two PRs that each add a note land with no conflict ───────────────────
# Each branch does what a box does: renders its own copy (a reader) and
# commits everything with `git add -A`. The lint --check is green on each.
D="$T/m1"; mkrepo "$D"
"$D/bin/render-doc-index.sh" >/dev/null 2>&1
for br in a b; do
  git -C "$D" checkout -q -b "ticket/bh-90$br" main
  note "$D" "2026-09-20-BH-90$br-note.md" "PR note $br" "EVENTS"
  "$D/bin/render-doc-index.sh" >/dev/null 2>&1
  git -C "$D" add -A; git -C "$D" commit -qm "note $br"
  OUT=$(chk "$D"); RC=$?
  [ "$RC" = 0 ] && ok || bad "M1: the lint --check on branch $br must be rc 0, got rc=$RC: $OUT"
done
git -C "$D" checkout -q main
git -C "$D" merge -q --no-ff --no-edit ticket/bh-90a >/dev/null 2>&1 && ok || bad "M1: merging PR a must not conflict"
git -C "$D" merge -q --no-ff --no-edit ticket/bh-90b >/dev/null 2>&1 && ok \
  || bad "M1: merging PR b after PR a must not conflict: $(git -C "$D" diff --name-only --diff-filter=U)"
OUT=$(chk "$D"); RC=$?
[ "$RC" = 0 ] && ok || bad "M1: --check on the merged main must be rc 0, got rc=$RC: $OUT"
"$D/bin/render-doc-index.sh" >/dev/null 2>&1
grep -q 'PR note a' "$D/docs/notes/INDEX.md" && grep -q 'PR note b' "$D/docs/notes/INDEX.md" && ok \
  || bad "M1: a render on the merged main must list both notes"

# ── R1. bin/docs-sync.sh renders the index into the checkout ─────────────────
CK="$T/r1/ck"; H="$T/r1/h"
mkdir -p "$CK/bin" "$CK/docs/notes" "$H"
cp "$R" "$CK/bin/"
note "$CK" 2026-09-21-BH-91-a.md "Sync note a" "EVENTS"
note "$CK" 2026-09-21-BH-92-b.md "Sync note b" "EVENTS"
HARNESS="$H" HARNESS_CHECKOUT="$CK" "$DIR/bin/docs-sync.sh" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "R1: docs-sync must be rc 0, got $RC"
grep -q 'Sync note a' "$CK/docs/notes/INDEX.md" 2>/dev/null && grep -q 'Sync note b' "$CK/docs/notes/INDEX.md" && ok \
  || bad "R1: docs-sync must render docs/notes/INDEX.md listing both notes"
grep -q 'docs/notes/INDEX.md could not be regenerated' "$H/logs/update-runners.log" 2>/dev/null \
  && bad "R1: a good render must not log a failure" || ok
# A renderer that fails: docs-sync logs one line and goes on.
printf '#!/bin/sh\nexit 1\n' > "$CK/bin/render-doc-index.sh"; chmod +x "$CK/bin/render-doc-index.sh"
printf '#!/bin/sh\necho vmap-ran >> "%s/vmap.ran"\n' "$T/r1" > "$CK/bin/verification-map-build.sh"; chmod +x "$CK/bin/verification-map-build.sh"
HARNESS="$H" HARNESS_CHECKOUT="$CK" "$DIR/bin/docs-sync.sh" >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "R1: docs-sync with a failed render must still be rc 0, got $RC"
[ "$(grep -c 'docs/notes/INDEX.md could not be regenerated' "$H/logs/update-runners.log" 2>/dev/null)" = 1 ] && ok \
  || bad "R1: a failed render must log exactly one line: $(cat "$H/logs/update-runners.log" 2>/dev/null)"
[ -s "$T/r1/vmap.ran" ] && ok || bad "R1: docs-sync must go on to the verification-map build after a failed render"

# ── R2. the share mirror renders the index into its source ───────────────────
PS=$(grep -n 'render-doc-index.sh' "$DIR/bin/publish-share.sh" | grep -v '^[0-9]*:[[:space:]]*#')
has '"$SRC/bin/render-doc-index.sh"' "$PS" && has '"$SRC/docs/notes"' "$PS" && ok \
  || bad "R2: bin/publish-share.sh must render \$SRC/docs/notes into the mirror, got: $PS"
grep -q 'WARNING docs/notes/INDEX.md could not be generated' "$DIR/bin/publish-share.sh" && ok \
  || bad "R2: a failed render in publish-share must be a WARNING, not a stop"

# ── R3. CI runs the new --check, through the rendered workflow ───────────────
grep -q 'run: bin/render-doc-index.sh --check$' "$DIR/.github/workflows/harness-ci.yml" && ok \
  || bad "R3: .github/workflows/harness-ci.yml must run bin/render-doc-index.sh --check"
grep -qh 'run: bin/render-doc-index.sh --check$' "$DIR"/config/harness-ci/120-lint/*.yml && ok \
  || bad "R3: the step must come from config/harness-ci/120-lint/"
"$DIR/bin/render-ci-workflow.sh" --root "$DIR" --check >/dev/null 2>&1; RC=$?
[ "$RC" = 0 ] && ok || bad "R3: bin/render-ci-workflow.sh --check must be rc 0, got $RC"

# ── R4. no regenerate row, no stale "refresh" instruction ────────────────────
export HARNESS="$T/r4h"
mkdir -p "$HARNESS/config"
cp "$DIR/config/regenerated-paths.conf" "$HARNESS/config/"
# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
mc_regen_cmd_for_path docs/notes/INDEX.md >/dev/null 2>&1 && bad "R4: the conf must have no docs/notes/INDEX.md row" || ok
MC_REGENERATED_PATHS_CONF="$T/no-such.conf" mc_regen_cmd_for_path docs/notes/INDEX.md >/dev/null 2>&1 \
  && bad "R4: the compiled default must have no docs/notes/INDEX.md row" || ok
[ "$(mc_regen_cmd_for_path rules/CLAUDE.md 2>/dev/null)" = "bin/render-rules.sh --write" ] && ok \
  || bad "R4: rules/CLAUDE.md must still map to its generator"
LEFT=$(git -C "$DIR" grep -n 'refresh docs/notes/INDEX.md' -- guardrails prompts 2>/dev/null)
[ -z "$LEFT" ] && ok || bad "R4: a stale 'refresh docs/notes/INDEX.md' instruction is left: $LEFT"

echo "render-doc-index.bh-8254-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
