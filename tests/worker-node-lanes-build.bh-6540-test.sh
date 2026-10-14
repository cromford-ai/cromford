#!/bin/bash
# tests/worker-node-lanes-build.bh-6540-test.sh — BH-6540: every suite that
# runs node over worker/jobs/src/index.js writes catalog/lanes.json first.
#
# Since BH-1175/BH-1178 catalog/lanes.json is composed from catalog/lanes.d/ and
# is git-ignored. worker/jobs/src/lib/core.js imports it, so a suite that loads
# index.js on a fresh checkout dies in node with ERR_MODULE_NOT_FOUND. CI's
# traced shards now build it before the suites run (the tests-shard step that
# tests/ci-catalogs-before-suites.bh-6540-test.sh pins). This ratchet is for a
# local run of one suite on a fresh checkout.
#
# WHAT COUNTS. scan() is tests/worker-node-catalog-compose.bh-6452-test.sh's
# scan, signals A, B and C exactly as that file defines them. Only the
# compliance test differs:
#   compliant a non-comment line has both 'lanes-build.sh' and '--write'.
# The scan skips this file and the BH-6452 scanner, whose fixture lines match
# signal A but which loads no worker. The fix line, put directly above the
# suite's llm-sites-build.sh --compose line:
#   "$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
#
# Cases: R0 the real tree; R1-R4 fixtures with and without that line; N1-N2
# suites that must not be flagged. Fixtures live under $T only.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/worker-node-lanes-build.bh-6540-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

SELF=$(basename "$0")
BH6452=worker-node-catalog-compose.bh-6452-test.sh
FIX='"$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }'

# code <file>: the file's non-comment lines.
code() { grep -v '^[[:space:]]*#' "$1" 2>/dev/null; }

# scan <ROOT>: one line per offender, "<suite path relative to root>: <why>".
# The glob is "$ROOT"/tests/*.sh on purpose: that is the "$DIR"/tests/* signal
# bin/test-impact.sh always reads, and it keeps this suite in the always set.
scan() {
  local ROOT=$1 f rel body why name wt
  for f in "$ROOT"/tests/*.sh "$ROOT"/tests/mc/*.sh; do
    [ -f "$f" ] || continue
    case $(basename "$f") in "$SELF"|"$BH6452") continue ;; esac
    body=$(code "$f")
    why=""
    if grep -qE "import\([^)]*jobs/src/index\.js|from[[:space:]]*['\"][^'\"]*jobs/src/index\.js['\"]" <<<"$body"; then
      why="imports worker/jobs/src/index.js"
    else
      for name in $(printf '%s\n' "$body" | grep -E '(^|[^A-Za-z0-9_-])node[[:space:]]' | grep -e '--test' \
                    | grep -oE 'test/[A-Za-z0-9._-]+\.js' | sed 's#^test/##' | sort -u); do
        wt="$ROOT/worker/jobs/test/$name"
        [ -f "$wt" ] || continue
        if code "$wt" | grep -qE "from ['\"]\.\./src/index\.js['\"]|import\(['\"]\.\./src/index\.js['\"]\)"; then
          why="node --test worker/jobs/test/$name imports ../src/index.js"; break
        fi
      done
      if [ -z "$why" ]; then
        for name in $(printf '%s\n' "$body" | grep -E '(^|[^A-Za-z0-9_-])node[[:space:]]' \
                      | grep -oE 'tests/lib/[A-Za-z0-9._-]+\.m?js' | sed 's#^tests/lib/##' | sort -u); do
          wt="$ROOT/tests/lib/$name"
          [ -f "$wt" ] || continue
          if code "$wt" | grep -qE "import\([^)]*jobs/src/index\.js|from[[:space:]]*['\"][^'\"]*jobs/src/index\.js['\"]"; then
            why="node runs tests/lib/$name, which imports worker/jobs/src/index.js"; break
          fi
        done
      fi
    fi
    [ -n "$why" ] || continue
    printf '%s\n' "$body" | grep 'lanes-build\.sh' | grep -qe '--write' && continue
    rel=${f#"$ROOT"/}
    echo "$rel: $why, and the suite never runs bin/lanes-build.sh --write"
  done
}

# fixture <name>: a fresh fixture root under $T.
fixture() { mkdir -p "$T/$1/tests/mc" "$T/$1/worker/jobs/test"; echo "$T/$1"; }

# The worker path is split so this file's own lines carry no signal A for the
# BH-6452 scanner; the fixtures it writes do.
IDX=jobs/src/index.js

# --- R0: the real tree ---------------------------------------------------------
OUT=$(scan "$DIR")
if [ -z "$OUT" ]; then ok "R0 real tree: no suite loads the worker without writing catalog/lanes.json"
else
  bad "R0 real tree has offenders:"
  printf '%s\n' "$OUT" | sed 's/^/         /'
  echo "       fix: add this line above the suite's llm-sites-build.sh --compose line:"
  echo "         $FIX"
fi

# --- R1-R3: signal A, a driver that imports index.js ----------------------------
RA=$(fixture a)
SA="$RA/tests/drive-worker-test.sh"
write_a() {
  { printf '#!/bin/bash\nDIR=$(cd "$(dirname "$0")/.." && pwd)\n'
    [ -n "$1" ] && printf '%s\n' "$1"
    printf "node --input-type=module -e 'await import(\"'\"\$DIR\"'/worker/%s\")'\n" "$IDX"; } > "$SA"
}
write_a ""
OUT=$(scan "$RA")
case $OUT in
  "tests/drive-worker-test.sh: imports worker/jobs/src/index.js, and the suite never runs bin/lanes-build.sh --write") ok "R1 driver import without lanes-build: flagged" ;;
  *) bad "R1 driver import without lanes-build: want the suite flagged, got [$OUT]" ;;
esac
write_a "$FIX"
OUT=$(scan "$RA")
[ -z "$OUT" ] && ok "R2 driver import with lanes-build --write: clean" || bad "R2 with the fix line: want nothing, got [$OUT]"
write_a '"$DIR/bin/lanes-build.sh" --root "$DIR" --check >/dev/null || exit 1'
OUT=$(scan "$RA")
case $OUT in
  "tests/drive-worker-test.sh: imports worker/jobs/src/index.js"*) ok "R3 lanes-build --check only: flagged" ;;
  *) bad "R3 lanes-build --check only: want the suite flagged, got [$OUT]" ;;
esac

# --- R4: signal B, a copy of staff-record plus its worker test ------------------
B_SRC="$DIR/tests/staff-record.bh-5561-test.sh"
B_JS="$DIR/worker/jobs/test/staff-record.bh-5561.test.js"
RB=$(fixture b)
cp "$B_JS" "$RB/worker/jobs/test/"
grep -v 'lanes-build\.sh' "$B_SRC" > "$RB/tests/staff-record.bh-5561-test.sh"
OUT=$(scan "$RB")
case $OUT in
  "tests/staff-record.bh-5561-test.sh: node --test worker/jobs/test/staff-record.bh-5561.test.js imports ../src/index.js"*)
    ok "R4 node --test on an index.js importer without lanes-build: flagged" ;;
  *) bad "R4 node --test on an index.js importer without lanes-build: want the suite flagged, got [$OUT]" ;;
esac
{ grep -v 'lanes-build\.sh' "$B_SRC" | sed -n '1,/^DIR=/p'
  printf '%s\n' "$FIX"
  grep -v 'lanes-build\.sh' "$B_SRC" | sed '1,/^DIR=/d'; } > "$RB/tests/staff-record.bh-5561-test.sh"
OUT=$(scan "$RB")
[ -z "$OUT" ] && ok "R4 node --test on an index.js importer with lanes-build: clean" || bad "R4 with the fix line: want nothing, got [$OUT]"

# --- N1: index.js named only in a comment ---------------------------------------
RN=$(fixture n1)
printf '#!/bin/bash\nDIR=x\n# node -e '\''await import("worker/%s")'\'' runs nowhere\n' "$IDX" > "$RN/tests/n1-test.sh"
OUT=$(scan "$RN")
if ! grep -q "import(\"worker/$IDX\")" "$RN/tests/n1-test.sh"; then bad "N1 fixture premise: the comment does not name index.js"
elif [ -z "$OUT" ]; then ok "N1 index.js only in a comment: not flagged"
else bad "N1: want nothing, got [$OUT]"; fi

# --- N2: the BH-6452 scanner itself ---------------------------------------------
RN=$(fixture n2)
cp "$DIR/tests/$BH6452" "$RN/tests/"
OUT=$(scan "$RN")
[ -z "$OUT" ] && ok "N2 the BH-6452 scanner: not flagged" || bad "N2: want nothing, got [$OUT]"

echo "worker-node-lanes-build: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
