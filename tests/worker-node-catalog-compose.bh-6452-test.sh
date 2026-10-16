#!/bin/bash
# tests/worker-node-catalog-compose.bh-6452-test.sh — BH-6452: every suite that
# runs node over worker/jobs/src/index.js composes catalog/llm-sites.json first.
#
# Since BH-4987 catalog/llm-sites.json is composed from catalog/llm-sites.d/ and
# is git-ignored. worker/jobs/src/lib/llm-sites-catalog.js imports it, and
# index.js reaches that module through its routes. A suite that loads index.js
# on a fresh checkout without composing the file dies in node with
# ERR_MODULE_NOT_FOUND. It passes only when an earlier suite in the same
# checkout composed the file, so a CI shard plan decides whether it is red.
#
# WHAT COUNTS. Only non-comment lines (first non-blank byte not '#') of each
# tests/*.sh and tests/mc/*.sh are read.
#   signal A  a line has import(...jobs/src/index.js) or from '...jobs/src/index.js'
#             (a heredoc driver). A line that only names index.js next to an
#             unrelated import string (a fixture, archie-fm-conflicts) is not.
#   signal B  a line runs node with --test and names test/<name>.js, and
#             worker/jobs/test/<name>.js imports '../src/index.js'.
#   signal C  a line runs node on a helper tests/lib/<name>.mjs (or .js), and
#             that helper imports jobs/src/index.js (signal A's pattern). The
#             helper starts the worker as a server (spend-lane-push.bh-6174
#             runs lane-spend-worker.bh-6174.mjs; merge-queue batch #6471).
#   compliant a line has both 'llm-sites-build.sh' and '--compose'; or one
#             line sources tests/lib/worker-catalogs.sh and another calls
#             worker_catalogs (BH-7119). A source with no call composes nothing.
# A suite with signal A, B or C that is not compliant is an offender. The fix is
# the two helper lines, put after DIR=:
#   . "$DIR/tests/lib/worker-catalogs.sh" || exit 1
#   worker_catalogs "$DIR" || exit 1
# The inline line stays compliant (the suites in a variant shape keep it):
#   "$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
#
# Cases: R0 the real tree; R1-R6 copies of real suites with and without the
# compose; R7-R9 the helper sourced and called, sourced only, named only in a
# comment; N1-N5 suites that must not be flagged. Fixtures live under $T only.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/worker-node-catalog-compose.bh-6452-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

SELF=$(basename "$0")

# code <file>: the file's non-comment lines.
code() { grep -v '^[[:space:]]*#' "$1" 2>/dev/null; }

# helper_called <body>: rc 0 when one line sources tests/lib/worker-catalogs.sh
# and another line calls worker_catalogs.
helper_called() {
  grep -qE '^[[:space:]]*(\.|source)[[:space:]].*lib/worker-catalogs\.sh' <<<"$1" || return 1
  grep -vE '^[[:space:]]*(\.|source)[[:space:]].*lib/worker-catalogs\.sh' <<<"$1" \
    | grep -qE '(^|[^A-Za-z0-9_])worker_catalogs([[:space:]]|$)'
}

# scan <ROOT>: one line per offender, "<suite path relative to root>: <why>".
# The glob is "$ROOT"/tests/*.sh on purpose: that is the "$DIR"/tests/* signal
# bin/test-impact.sh always reads, and it keeps this suite in the always set.
scan() {
  local ROOT=$1 f rel body why name wt
  for f in "$ROOT"/tests/*.sh "$ROOT"/tests/mc/*.sh; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "$SELF" ] && continue
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
    printf '%s\n' "$body" | grep 'llm-sites-build\.sh' | grep -qe '--compose' && continue
    helper_called "$body" && continue
    rel=${f#"$ROOT"/}
    echo "$rel: $why, and the suite never runs bin/llm-sites-build.sh --compose"
  done
}

# fixture <name>: a fresh fixture root under $T.
fixture() { mkdir -p "$T/$1/tests/mc" "$T/$1/worker/jobs/test"; echo "$T/$1"; }

# --- R0: the real tree ---------------------------------------------------------
OUT=$(scan "$DIR")
if [ -z "$OUT" ]; then ok "R0 real tree: no suite loads the worker without composing the catalog"
else
  bad "R0 real tree has offenders:"
  printf '%s\n' "$OUT" | sed 's/^/         /'
  echo "       fix: add the two helper lines (see this file's header) after DIR= in each suite above:"
  echo "         . \"\$DIR/tests/lib/worker-catalogs.sh\" || exit 1"
  echo "         worker_catalogs \"\$DIR\" || exit 1"
fi

# --- R1/R2: signal A, a copy of ci-plan-reuse-full --------------------------------
A_SRC="$DIR/tests/ci-plan-reuse-full.bh-6406-test.sh"
RA=$(fixture a)
grep -v -e 'llm-sites-build\.sh' -e 'worker[-_]catalogs' "$A_SRC" > "$RA/tests/ci-plan-reuse-full.bh-6406-test.sh"
OUT=$(scan "$RA")
case $OUT in
  "tests/ci-plan-reuse-full.bh-6406-test.sh: imports worker/jobs/src/index.js"*) ok "R1 driver import without compose: flagged" ;;
  *) bad "R1 driver import without compose: want the suite flagged, got [$OUT]" ;;
esac
cp "$A_SRC" "$RA/tests/ci-plan-reuse-full.bh-6406-test.sh"
OUT=$(scan "$RA")
[ -z "$OUT" ] && ok "R2 driver import with compose: clean" || bad "R2 driver import with compose: want nothing, got [$OUT]"

# --- R3/R4: signal B, a copy of staff-record plus its worker test ---------------
B_SRC="$DIR/tests/staff-record.bh-5561-test.sh"
B_JS="$DIR/worker/jobs/test/staff-record.bh-5561.test.js"
RB=$(fixture b)
cp "$B_JS" "$RB/worker/jobs/test/"
grep -v -e 'llm-sites-build\.sh' -e 'worker[-_]catalogs' "$B_SRC" > "$RB/tests/staff-record.bh-5561-test.sh"
OUT=$(scan "$RB")
case $OUT in
  "tests/staff-record.bh-5561-test.sh: node --test worker/jobs/test/staff-record.bh-5561.test.js imports ../src/index.js"*)
    ok "R3 node --test on an index.js importer without compose: flagged" ;;
  *) bad "R3 node --test on an index.js importer without compose: want the suite flagged, got [$OUT]" ;;
esac
cp "$B_SRC" "$RB/tests/staff-record.bh-5561-test.sh"
OUT=$(scan "$RB")
[ -z "$OUT" ] && ok "R4 node --test on an index.js importer with compose: clean" || bad "R4 with compose: want nothing, got [$OUT]"

# --- R5/R6: signal C, a copy of spend-lane-push plus its worker helper ---------
C_SRC="$DIR/tests/spend-lane-push.bh-6174-test.sh"
C_LIB="$DIR/tests/lib/lane-spend-worker.bh-6174.mjs"
RC_=$(fixture c)
mkdir -p "$RC_/tests/lib"; cp "$C_LIB" "$RC_/tests/lib/"
grep -v -e 'llm-sites-build\.sh' -e 'worker[-_]catalogs' "$C_SRC" > "$RC_/tests/spend-lane-push.bh-6174-test.sh"
OUT=$(scan "$RC_")
case $OUT in
  "tests/spend-lane-push.bh-6174-test.sh: node runs tests/lib/lane-spend-worker.bh-6174.mjs, which imports worker/jobs/src/index.js"*)
    ok "R5 node on a worker-server helper without compose: flagged" ;;
  *) bad "R5 node on a worker-server helper without compose: want the suite flagged, got [$OUT]" ;;
esac
{ grep -v -e 'llm-sites-build\.sh' -e 'worker[-_]catalogs' "$C_SRC" | sed -n '1,/^DIR=/p'
  printf '%s\n' '"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || exit 1'
  grep -v -e 'llm-sites-build\.sh' -e 'worker[-_]catalogs' "$C_SRC" | sed '1,/^DIR=/d'; } > "$RC_/tests/spend-lane-push.bh-6174-test.sh"
OUT=$(scan "$RC_")
[ -z "$OUT" ] && ok "R6 node on a worker-server helper with compose: clean" || bad "R6 with compose: want nothing, got [$OUT]"

# --- R7-R9: signal B, the staff-record copy with the BH-7119 helper ------------
# helper_suite <root> <lines>: the staff-record copy, no inline compose and no
# helper lines, with <lines> put after DIR=.
helper_suite() {
  { grep -v -e 'llm-sites-build\.sh' -e 'worker[-_]catalogs' "$B_SRC" | sed -n '1,/^DIR=/p'
    printf '%s\n' "$2"
    grep -v -e 'llm-sites-build\.sh' -e 'worker[-_]catalogs' "$B_SRC" | sed '1,/^DIR=/d'; } > "$1/tests/staff-record.bh-5561-test.sh"
}
SRC_LINE='. "$DIR/tests/lib/worker-catalogs.sh" || exit 1'
CALL_LINE='worker_catalogs "$DIR" || exit 1'
RH=$(fixture h)
cp "$B_JS" "$RH/worker/jobs/test/"
helper_suite "$RH" "$SRC_LINE
$CALL_LINE"
OUT=$(scan "$RH")
[ -z "$OUT" ] && ok "R7 helper sourced and called before node --test: clean" || bad "R7 helper sourced and called: want nothing, got [$OUT]"
helper_suite "$RH" "$SRC_LINE"
OUT=$(scan "$RH")
case $OUT in
  "tests/staff-record.bh-5561-test.sh: node --test worker/jobs/test/staff-record.bh-5561.test.js imports ../src/index.js"*)
    ok "R8 helper sourced, worker_catalogs never called: flagged" ;;
  *) bad "R8 helper sourced, never called: want the suite flagged, got [$OUT]" ;;
esac
helper_suite "$RH" "# $SRC_LINE
# $CALL_LINE"
OUT=$(scan "$RH")
case $OUT in
  "tests/staff-record.bh-5561-test.sh: node --test worker/jobs/test/staff-record.bh-5561.test.js imports ../src/index.js"*)
    ok "R9 helper named only in a comment: flagged" ;;
  *) bad "R9 helper named only in a comment: want the suite flagged, got [$OUT]" ;;
esac

# --- N5: node on a tests/lib helper that does not import the worker ------------
RN=$(fixture n5)
mkdir -p "$RN/tests/lib"
printf "import { readFileSync } from 'node:fs';\nconsole.log(readFileSync(process.argv[2], 'utf8').length);\n" > "$RN/tests/lib/plain-helper.mjs"
printf '#!/bin/bash\nDIR=x\nnode "$DIR/tests/lib/plain-helper.mjs" /etc/hostname\n' > "$RN/tests/n5-test.sh"
OUT=$(scan "$RN")
[ -z "$OUT" ] && ok "N5 node on a helper that does not import the worker: not flagged" || bad "N5: want nothing, got [$OUT]"

# --- N1: node --test on a worker test that does not import ../src/index.js ------
N1_JS="$DIR/worker/jobs/test/account-usage-contract.bh-167.test.js"
if code "$N1_JS" | grep -q 'src/index\.js'; then
  bad "N1 fixture premise: $N1_JS now imports src/index.js; pick another worker test"
else
  RN=$(fixture n1)
  cp "$N1_JS" "$RN/worker/jobs/test/"
  grep -v -e 'llm-sites-build\.sh' -e 'worker[-_]catalogs' "$B_SRC" | sed 's#test/staff-record\.bh-5561\.test\.js test/route-table\.test\.js#test/account-usage-contract.bh-167.test.js#' \
    > "$RN/tests/n1-test.sh"
  if grep -q 'node --test.*account-usage-contract\.bh-167\.test\.js' "$RN/tests/n1-test.sh"; then
    OUT=$(scan "$RN")
    [ -z "$OUT" ] && ok "N1 node --test on a non-index worker test: not flagged" || bad "N1: want nothing, got [$OUT]"
  else
    bad "N1 fixture premise: the node --test line of $B_SRC changed shape"
  fi
fi

# --- N2: a console-ui node --test with no worker test of that name ---------------
N2_SRC="$DIR/tests/block-categories-console.bh-5806-test.sh"
RN=$(fixture n2)
cp "$N2_SRC" "$RN/tests/"
if code "$N2_SRC" | grep -q 'node --test'; then
  OUT=$(scan "$RN")
  [ -z "$OUT" ] && ok "N2 console-ui node --test: not flagged" || bad "N2: want nothing, got [$OUT]"
else
  bad "N2 fixture premise: $N2_SRC has no node --test line"
fi

# --- N3: index.js named only in a comment or a [ -r ] path check ------------------
RN=$(fixture n3)
cp "$B_JS" "$RN/worker/jobs/test/"
grep -v -e 'llm-sites-build\.sh' -e 'worker[-_]catalogs' "$B_SRC" | grep -v 'node --test' > "$RN/tests/staff-record.bh-5561-test.sh"
printf '# import("worker/jobs/src/index.js") is named in a comment only\n' >> "$RN/tests/staff-record.bh-5561-test.sh"
if grep -q 'src/index\.js' "$RN/tests/staff-record.bh-5561-test.sh"; then
  OUT=$(scan "$RN")
  [ -z "$OUT" ] && ok "N3 index.js only in a comment and a path check: not flagged" || bad "N3: want nothing, got [$OUT]"
else
  bad "N3 fixture premise: the staff-record copy no longer names src/index.js"
fi

# --- N4: index.js and an unrelated import string on one line (a fixture) -------
N4_SRC="$DIR/tests/archie-fm-conflicts.bh-4585-test.sh"
RN=$(fixture n4)
cp "$N4_SRC" "$RN/tests/"
if code "$N4_SRC" | grep 'import' | grep -q 'jobs/src/index\.js'; then
  OUT=$(scan "$RN")
  [ -z "$OUT" ] && ok "N4 index.js beside a fixture import string: not flagged" || bad "N4: want nothing, got [$OUT]"
else
  bad "N4 fixture premise: $N4_SRC no longer has import and index.js on one line"
fi

echo "worker-node-catalog-compose: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
