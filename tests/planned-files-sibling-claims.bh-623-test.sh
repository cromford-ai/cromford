#!/bin/bash
# tests/planned-files-sibling-claims.bh-623-test.sh — a sibling's paths that the
# planner quotes ONLY to say it avoids them are not this build's claim.
#
# WHY (BH-623, 2026-09-17). The PLAN prompt tells the planner to read the live
# sibling claims and avoid them, so plans started carrying a note like "Active
# sibling claim BH-455 edits docs/x.md … No overlap". bin/planned-files.sh
# scrapes every path token in plan.md, so that note put the sibling's own paths
# into THIS build's planned-files.txt, conflict-check matched them against the
# sibling, and the build answered BUILD_DEFERRED on its first check.
# BH-417/418/444/445/446/447/463 all deferred against BH-455 that way.
#
# The fix: a '## Sibling claims (not touched)' section, running to the next
# level-1/2 heading, is skipped by both extraction passes. Everything else keeps
# the deliberate over-listing (tests/size-gate-mentions-test.sh pins that).
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PF="$REPO/bin/planned-files.sh"
CC="$REPO/bin/conflict-check.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

mkdir -p "$T/h/builds"
# A build dir named like a real one; no RESULT file = running (4h mtime window).
mkbuild() { mkdir -p "$T/h/builds/$1"; printf '%s' "$T/h/builds/$1"; }
has()  { grep -qxF "$2" "$1/planned-files.txt"; }

# The note shape a real planner writes (BH-417's plan, abridged).
SIB_NOTE='Active sibling claim BH-455 edits `docs/sib-only.md`, `lib/sib-only.sh` and everything under src/sib/dir/. No overlap.'

# --- A1: the section's paths are dropped, the task's path is kept ------------
C1=$(mkbuild proj-BH-1-a)
cat > "$C1/plan.md" <<EOF
# BH-1 plan

## Scope
Fix the thing.

## Sibling claims (not touched)
$SIB_NOTE

### BH-455
Also quoted: \`docs/sib-deep.md\` under a level-3 sub-heading.

## Tasks
### Task 1
Edit \`tests/own-file.sh\`.
VALIDATE: bash tests/own-file.sh
EOF
"$PF" "$C1"; rc=$?
[ "$rc" = 0 ] && ok || bad "planned-files.sh rc=$rc"
has "$C1" tests/own-file.sh && ok || bad "A1: the task's own file must be listed: $(cat "$C1/planned-files.txt")"
has "$C1" docs/sib-only.md && bad "A1: docs/sib-only.md is only in the sibling section: $(cat "$C1/planned-files.txt")" || ok
has "$C1" lib/sib-only.sh && bad "A1: lib/sib-only.sh is only in the sibling section: $(cat "$C1/planned-files.txt")" || ok
has "$C1" src/sib/dir && bad "A1: the bare dir src/sib/dir/ is only in the sibling section: $(cat "$C1/planned-files.txt")" || ok
has "$C1" docs/sib-deep.md && bad "A1: a ### sub-heading stays inside the section: $(cat "$C1/planned-files.txt")" || ok

# --- A2: conflict-check no longer defers against the sibling -----------------
S=$(mkbuild proj-BH-455-s)
printf 'docs/sib-only.md\nlib/sib-only.sh\n' > "$S/planned-files.txt"
OUT=$(HARNESS="$T/h" "$CC" proj "$C1" 2>&1); crc=$?
[ "$crc" = 0 ] && ok || bad "A2: conflict-check must allow the build (rc=$crc: $OUT)"
[ -z "$OUT" ] && ok || bad "A2: conflict-check printed: $OUT"

# --- A3: the section as the LAST section runs to EOF; heading is case-blind --
C3=$(mkbuild proj-BH-3-a)
cat > "$C3/plan.md" <<EOF
## Tasks
Edit \`tests/own-file.sh\`.

## sibling claims (not touched)
$SIB_NOTE
Trailing line naming \`docs/sib-tail.md\`.
EOF
"$PF" "$C3"
has "$C3" tests/own-file.sh && ok || bad "A3: task file missing: $(cat "$C3/planned-files.txt")"
has "$C3" docs/sib-only.md && bad "A3: lower-case heading must be skipped too: $(cat "$C3/planned-files.txt")" || ok
has "$C3" docs/sib-tail.md && bad "A3: the last section must be skipped to EOF: $(cat "$C3/planned-files.txt")" || ok

# --- A4: a path named in the section AND in a task is still a claim ----------
C4=$(mkbuild proj-BH-4-a)
cat > "$C4/plan.md" <<EOF
## Sibling claims (not touched)
$SIB_NOTE

## Tasks
Overlap is unavoidable: edit \`docs/sib-only.md\`.
EOF
"$PF" "$C4"
: > "$C1/RESULT"; : > "$C3/RESULT"   # finished: only the sibling S is running now
has "$C4" docs/sib-only.md && ok || bad "A4: a path the tasks name must stay listed: $(cat "$C4/planned-files.txt")"
has "$C4" lib/sib-only.sh && bad "A4: lib/sib-only.sh is still only in the section: $(cat "$C4/planned-files.txt")" || ok
OUT=$(HARNESS="$T/h" "$CC" proj "$C4" 2>&1); crc=$?
[ "$crc" = 1 ] && ok || bad "A4: a genuine overlap must still defer (rc=$crc: $OUT)"
[ "$OUT" = "CONFLICT with proj-BH-455-s: docs/sib-only.md ~ docs/sib-only.md" ] \
  && ok || bad "A4: conflict reason: $OUT"
scratch_rm "$C4"   # keep it from colliding with the fixtures below

# --- A5: no marker = byte-identical to the pre-BH-623 extractor --------------
old_extract() {  # the two greps and the prune exactly as they stood before BH-623
  grep -oE '[][A-Za-z0-9_@()/.-]+\.(ts|tsx|js|jsx|mjs|sql|prisma|css|scss|json|sh|md|yml|yaml)' "$1" \
    | grep -E '^(src|prisma|scripts|e2e|tests|app|lib|components|pages|public|docs|content|middleware)' \
    | sed 's|^\./||' | sort -u > "$2"
  grep -oE '(src|prisma|scripts|e2e|tests)/[][A-Za-z0-9_@()/.-]+/' "$1" | sed 's|/$||' | sort -u >> "$2"
  awk -F/ '/\./ || NF>=3' "$2" | sort -u > "$2.new" && mv "$2.new" "$2"
}
C5=$(mkbuild proj-BH-5-a)
cat > "$C5/plan.md" <<EOF
## Scope
The sibling claim note is prose here, not a heading: $SIB_NOTE
Out of scope: do NOT edit src/lib/shared.ts.

### Sibling claims (not touched)
Level-3 is not the marker: \`docs/lvl3.md\`.

## Tasks
Edit \`tests/own-file.sh\`, \`src/app/page.tsx\` and everything under src/lib/foo/bar/.
EOF
"$PF" "$C5"
old_extract "$C5/plan.md" "$T/old.txt"
cmp -s "$T/old.txt" "$C5/planned-files.txt" && ok \
  || bad "A5: a plan without the marker must list exactly what it did before: $(diff "$T/old.txt" "$C5/planned-files.txt")"
for p in src/lib/shared.ts docs/lvl3.md docs/sib-only.md src/sib/dir src/lib/foo/bar tests/own-file.sh; do
  has "$C5" "$p" && ok || bad "A5: $p must be listed: $(cat "$C5/planned-files.txt")"
done

# --- A6: the PLAN prompt tells the planner where the note goes --------------
# Since the BH-572 cut the prompt has ONE copy, in bin/lib/rb/plan.sh; the driver
# keeps only the eleven stage calls. So the pin is: absent from the raw driver,
# once in the module, once in the flattened pipeline (tests/lib/rb-all.sh), the
# text every build actually runs.
. "$REPO/tests/lib/rb-all.sh" || exit 1
FLAT=$(rb_all "$REPO" "$T/run-build.all.sh") || bad "A6: rb_all could not flatten bin/run-build.sh"
# TEST-CHANGE (BH-7970): the prompt text moved to prompts/stages/plan.md, and the
# flattened pipeline renders that file once through `sp_render plan` (pinned below).
for pair in "bin/run-build.sh:0" "prompts/stages/plan.md:1" "bin/lib/rb/plan.sh:0" "FLAT:0"; do
  f=${pair%:*}; want=${pair##*:}
  src="$REPO/$f"; [ "$f" = FLAT ] && src="$FLAT"
  n=$(grep -c "## Sibling claims (not touched)" "$src"); n=${n:-0}
  [ "$n" = "$want" ] && ok || bad "A6: $f carries the marker sentence $n times, want $want"
done
[ "$(grep -c '^sp_render plan ' "$FLAT")" = 1 ] && ok || bad "A6: FLAT must render prompts/stages/plan.md once (sp_render plan)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
