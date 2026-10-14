#!/bin/bash
# tests/planned-files-roots.bh-6715-test.sh — bin/planned-files.sh and
# bin/planned-files-cheap.sh claim a project's own source roots, read from the
# per-project row catalog/claim-roots.d/<project>.txt (BH-6715).
#
# THE DEFECT. The extractor kept a path only under src|prisma|scripts|e2e|tests
# |app|lib|... A cromford plan that names bin/lib/x.sh and
# catalog/lanes.d/y.json wrote an EMPTY planned-files.txt, so every cromford
# part read as "no pre-plan list" to bin/sibling-serial.sh and waited.
#
#   R1-R3  the roots are claimed; prose and short dir scopes are not
#   R4     a project with no row is byte-identical to a run with no catalog
#   R5-R6  project resolution and row validation (bin/lib/claim-roots.sh)
#   R7     the REPO's own bin/planned-files.sh against the committed row (D2)
#   R8     the BH-623/BH-6299 skip rules still hold with roots on
#   R9     bin/planned-files-cheap.sh claims the same roots
#
# No network. Run: HARNESS_TEST_SANDBOX=1 bash tests/planned-files-roots.bh-6715-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/catalog/claim-roots.d" "$H/builds" "$H/plans" "$H/logs" "$H/env" "$H/flags" "$H/state"
: > "$H/env/global.env"
scratch_install_closure bin/planned-files.sh "$H" >/dev/null || { echo "closure install of bin/planned-files.sh failed"; exit 1; }
scratch_install_closure bin/planned-files-cheap.sh "$H" >/dev/null || { echo "closure install of bin/planned-files-cheap.sh failed"; exit 1; }
printf '# fixture row\nbin\ncatalog\nworker\n' > "$H/catalog/claim-roots.d/cromford.txt"
PF="$H/bin/planned-files.sh"

mk() { # mk <dir-name> <plan-body> -> prints the build dir
  local d="$H/builds/$1"
  mkdir -p "$d"; printf '%b\n' "$2" > "$d/plan.md"; printf '%s\n' "$d"
}
has()   { grep -qxF "$2" "$3/planned-files.txt" && ok || bad "$1: '$2' not claimed, list: $(tr '\n' ' ' < "$3/planned-files.txt")"; }
hasnt() { grep -qE "$2" "$3/planned-files.txt" && bad "$1: /$2/ claimed, list: $(tr '\n' ' ' < "$3/planned-files.txt")" || ok; }

# R1: the cromford roots, files and a 3-segment dir scope
B=$(mk cromford-BH-1-20261014000000 '- `bin/lib/x.sh`\n- `catalog/lanes.d/y.json`\n- everything under worker/jobs/src/ moves')
"$PF" "$B"; RC=$?
[ "$RC" = 0 ] && ok || bad "R1: planned-files.sh must exit 0 (rc $RC)"
has R1 bin/lib/x.sh "$B"
has R1 catalog/lanes.d/y.json "$B"
has R1 worker/jobs/src "$B"

# R2: a default root still claims
B=$(mk cromford-BH-2-20261014000000 '- `src/a.ts`\n- `bin/lib/x.sh`')
"$PF" "$B"
has R2 src/a.ts "$B"
has R2 bin/lib/x.sh "$B"

# R3: prose, short scopes, absolute paths and a near-miss name are not claimed
B=$(mk cromford-BH-3-20261014000000 'the bin/ lane\nsee bin/lib/ for helpers\n`/root/harness/bin/run-build.sh` and /root/harness/bin/lib/rb/plan.sh\n`binary/x.ts`, robin/a/b/c/ and catalog/lanes.d/\n- `src/keep.ts`')
"$PF" "$B"
hasnt R3 '^bin' "$B"
hasnt R3 '^binary' "$B"
hasnt R3 '^catalog' "$B"
hasnt R3 '^/' "$B"
has R3 src/keep.ts "$B"

# R4: a project with no row = today's output, byte for byte
B=$(mk acme-AC-1-20261014000000 '- `bin/lib/x.sh`\n- `src/a.ts`\n- `catalog/x.json`')
"$PF" "$B"
[ "$(cat "$B/planned-files.txt")" = "src/a.ts" ] && ok || bad "R4: acme claims only src/a.ts, got: $(tr '\n' ' ' < "$B/planned-files.txt")"
H2="$T/h2"; mkdir -p "$H2/builds"
scratch_install_closure bin/planned-files.sh "$H2" >/dev/null || { echo "closure install into h2 failed"; exit 1; }
rm -f "$H2/bin/lib/claim-roots.sh"
mkdir -p "$H2/builds/acme-AC-1-20261014000000"; cp "$B/plan.md" "$H2/builds/acme-AC-1-20261014000000/"
"$H2/bin/planned-files.sh" "$H2/builds/acme-AC-1-20261014000000"
cmp -s "$B/planned-files.txt" "$H2/builds/acme-AC-1-20261014000000/planned-files.txt" && ok \
  || bad "R4: no row must equal no catalog and no lib"
# and a cromford dir with no lib at all is today's output too
mkdir -p "$H2/builds/cromford-BH-4-20261014000000"
printf -- '- `bin/lib/x.sh`\n' > "$H2/builds/cromford-BH-4-20261014000000/plan.md"
"$H2/bin/planned-files.sh" "$H2/builds/cromford-BH-4-20261014000000"
[ ! -s "$H2/builds/cromford-BH-4-20261014000000/planned-files.txt" ] && ok || bad "R4: no lib must claim no extra root"

# R5: project resolution
B=$(mk pool-cromford-BH-5-20261014000000 '- `bin/lib/x.sh`')
"$PF" "$B"; has R5 bin/lib/x.sh "$B"
B=$(mk acme-AC-5-20261014000000 '- `bin/lib/x.sh`')
"$PF" "$B" cromford; has "R5 arg 2" bin/lib/x.sh "$B"
B=$(mk cromford-BH-6-20261014000000 '- `bin/lib/x.sh`')
"$PF" "$B" acme; hasnt "R5 arg 2 overrides" '^bin' "$B"
mkdir -p "$H/plans/cromford-BH-7"; printf -- '- `bin/lib/x.sh`\n' > "$H/plans/cromford-BH-7/plan.md"
"$PF" "$H/plans/cromford-BH-7"; has "R5 plans dir" bin/lib/x.sh "$H/plans/cromford-BH-7"
printf 'fly\n' > "$H/catalog/claim-roots.d/board.txt"
CR="$H/bin/lib/claim-roots.sh"
proj() { bash -c '. "$1" || exit 9; claim_roots_project "$2" "$3"' _ "$CR" "$H/catalog" "$1"; }
[ "$(proj cromford-BH-1-20261014000000)" = cromford ] && ok || bad "R5: longest match must be cromford, got '$(proj cromford-BH-1-20261014000000)'"
[ "$(proj pool-cromford-BH-1-20261014000000)" = cromford ] && ok || bad "R5: pool- prefix, got '$(proj pool-cromford-BH-1-20261014000000)'"
[ "$(proj board-BH-1)" = board ] && ok || bad "R5: board-BH-1 is board, got '$(proj board-BH-1)'"
[ "$(proj cromford)" = cromford ] && ok || bad "R5: exact name"
[ -z "$(proj acme-AC-1-20261014000000)" ] && ok || bad "R5: acme has no row"
[ -z "$(proj boardx-1)" ] && ok || bad "R5: boardx-1 is not board, got '$(proj boardx-1)'"
rm -f "$H/catalog/claim-roots.d/board.txt"

# R6: row validation
printf '# header\n\nbin\n../etc\na/b\n.\n..\n  catalog  \n.github\nbad root\n' > "$H/catalog/claim-roots.d/vtest.txt"
GOT=$(bash -c '. "$1" || exit 9; claim_roots_list "$2" vtest' _ "$CR" "$H/catalog" | tr '\n' ' ')
[ "$GOT" = "bin catalog .github " ] && ok || bad "R6: valid roots only, got '$GOT'"
GOT=$(bash -c '. "$1" || exit 9; claim_roots_list "$2" nosuch; echo "rc=$?"' _ "$CR" "$H/catalog")
[ "$GOT" = "rc=0" ] && ok || bad "R6: a missing row prints nothing rc 0, got '$GOT'"
B=$(mk vtest-V-1-20261014000000 '- `a/b/x.ts`\n- `etc/x.sh`\n- `bin/x.sh`')
"$PF" "$B"
[ "$(cat "$B/planned-files.txt")" = "bin/x.sh" ] && ok || bad "R6: only the valid root claims, got: $(tr '\n' ' ' < "$B/planned-files.txt")"

# R7: the repo's own script and the committed row (production entry point)
R7="$T/r7/cromford-BH-9-20261014000000"; mkdir -p "$R7"
printf -- '- `bin/lib/x.sh`\n- `worker/jobs/src/routes/x.js`\n- `console-ui/src/lib/y.js`\n' > "$R7/plan.md"
"$DIR/bin/planned-files.sh" "$R7"
has R7 bin/lib/x.sh "$R7"
has R7 worker/jobs/src/routes/x.js "$R7"
has R7 console-ui/src/lib/y.js "$R7"
GOT=$(bash -c '. "$1" || exit 9; claim_roots_project "$2" pool-cromford-BH-9-20261014000000' _ "$DIR/bin/lib/claim-roots.sh" "$DIR/catalog")
[ "$GOT" = cromford ] && ok || bad "R7: the repo lib resolves cromford from the committed catalog, got '$GOT'"
for r in bin catalog worker console-ui cron fly config tests; do
  grep -qxF "$r" "$DIR/catalog/claim-roots.d/cromford.txt" && ok || bad "R7: committed row lacks $r"
done

# R8: the skip rules hold with roots on
B=$(mk cromford-BH-8-20261014000000 '## Sibling claims (not touched)\n- `bin/lib/sib.sh`\n## Tasks\n- `bin/lib/real.sh`\nVALIDATE: `bash bin/lib/val.sh`\n## Verify (run, not edited)\n- `bin/lib/ver.sh`\n## After')
"$PF" "$B"
[ "$(cat "$B/planned-files.txt")" = "bin/lib/real.sh" ] && ok || bad "R8: only the task path, got: $(tr '\n' ' ' < "$B/planned-files.txt")"

# R9: bin/planned-files-cheap.sh, tier 1 from a body file
printf 'Fix `bin/lib/x.sh` and `src/a.ts`.\n' > "$T/body"
cheap() { HARNESS="$H" PLANNED_FILES_BODY_FILE="$T/body" PLANNED_FILES_FREE_ONLY=1 PLANNED_FILES_KIND=bug \
            PLANNED_FILES_REPO="$T/no-repo" "$H/bin/planned-files-cheap.sh" "$@" >/dev/null 2>&1; }
cheap cromford BH-9
L="$H/plans/cromford-BH-9/planned-files.txt"
grep -qxF bin/lib/x.sh "$L" 2>/dev/null && ok || bad "R9: cheap list must claim bin/lib/x.sh, got: $(tr '\n' ' ' < "$L" 2>/dev/null)"
grep -qxF src/a.ts "$L" 2>/dev/null && ok || bad "R9: cheap list must keep src/a.ts"
cheap acme AC-9
L="$H/plans/acme-AC-9/planned-files.txt"
grep -qxF src/a.ts "$L" 2>/dev/null && ok || bad "R9: acme cheap list keeps src/a.ts"
grep -q '^bin' "$L" 2>/dev/null && bad "R9: acme has no row, bin must not claim" || ok

echo "planned-files-roots: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
