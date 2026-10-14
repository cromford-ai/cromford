#!/bin/bash
# Extract the plan's touched-file list into <build-dir>/planned-files.txt.
# Heuristic: any repo-relative path token in plan.md with a code/db extension,
# plus bare src/... dir mentions. Conservative superset — over-listing only
# costs a serialization, under-listing costs a conflict; prefer the former.
# One deliberate exception (BH-623): a "## Sibling claims (not touched)" section
# is not scanned. It ends at the next #/## heading, or at any deeper heading
# whose title does not start with a ticket key (BH-1919): "### BH-455" stays
# inside it as a per-sibling sub-heading, "### Task 1" ends it. The planner quotes a live
# sibling's paths there only to say it avoids them; scraping them made this
# build's claim equal the sibling's and conflict-check deferred it every time.
# A path the tasks also name is still listed, from the task line.
# Two more run-only places are not scanned either (BH-6299): a "## Verify (run,
# not edited)" section, which runs to the next #/## heading, and any line whose
# first word is VALIDATE: (after an optional - or * bullet). The planner names a
# test or check it only RUNS there; a guard test every plan runs became every
# plan's claim, and six project-6-os tickets took six waves on it. A path also
# named on any other line is still listed.
# A project's own source roots (bin/, catalog/, ...) count too when it has a row
# in catalog/claim-roots.d/<project>.txt (bin/lib/claim-roots.sh). The project is
# arg 2, else the row the build dir's name resolves to. Such a root needs its
# slash (`binary/x.ts` is not under `bin`), and a dir scope under it must start
# a token (`/root/harness/bin/lib/rb/` is not) and have 3 segments even with a
# dot in it (`catalog/lanes.d/` is not). No row = the defaults only.
# usage: planned-files.sh <build-dir> [project]
set -uo pipefail
BUILD="${1:?build dir}"
PLAN="$BUILD/plan.md"
[ -s "$PLAN" ] || exit 0
HERE="$(dirname "$0")"
EXTRA=""
# shellcheck source=bin/lib/claim-roots.sh
if [ -r "$HERE/lib/claim-roots.sh" ] && . "$HERE/lib/claim-roots.sh"; then
  PROJ="${2:-$(claim_roots_project "$HERE/../catalog" "$(basename "$BUILD")")}"
  EXTRA=$(claim_roots_list "$HERE/../catalog" "$PROJ" | sed 's/\./\\./g' | paste -sd'|')
fi
scan() {
  awk '/^#+[[:space:]]/ {
         t = tolower($0)
         if (t ~ /^##?[[:space:]]/) {
           skip = (t ~ /^##[[:space:]]+sibling claims/)
           vskip = (t ~ /^##[[:space:]]+verify/)
         }
         else if (skip && t !~ /^#+[[:space:]]+[a-z][a-z0-9]*-[0-9]+/) skip = 0
       }
       /^[[:space:]]*([-*][[:space:]]+)?VALIDATE:/ { next }
       !skip && !vskip' "$PLAN"
}
scan | grep -oE '[][A-Za-z0-9_@()/.-]+\.(ts|tsx|js|jsx|mjs|sql|prisma|css|scss|json|sh|md|yml|yaml)' \
  | grep -E "^(src|prisma|scripts|e2e|tests|app|lib|components|pages|public|docs|content|middleware)${EXTRA:+|^($EXTRA)/}" \
  | sed 's|^\./||' | sort -u > "$BUILD/planned-files.txt"
# Bare directory scopes ("everything under src/lib/foo/") count too
scan | grep -oE '(src|prisma|scripts|e2e|tests)/[][A-Za-z0-9_@()/.-]+/' \
  | sed 's|/$||' | sort -u >> "$BUILD/planned-files.txt"
[ -n "$EXTRA" ] && scan | grep -oE "(^|[^][A-Za-z0-9_@()/.-])($EXTRA)/[][A-Za-z0-9_@()/.-]+/" \
  | sed -e 's|^[^][A-Za-z0-9_@()/.-]||' -e 's|/$||' | awk -F/ 'NF>=3' | sort -u >> "$BUILD/planned-files.txt"
# Drop over-broad dir scopes (fewer than 3 segments, e.g. bare "src/lib") —
# they would serialize against everything and starve parallelism.
awk -F/ '/\./ || NF>=3' "$BUILD/planned-files.txt" | sort -u > "$BUILD/planned-files.txt.new" \
  && mv "$BUILD/planned-files.txt.new" "$BUILD/planned-files.txt"
exit 0
