#!/bin/bash
# tests/worker-catalogs.bh-7119-test.sh — BH-7119: tests/lib/worker-catalogs.sh,
# the one helper a suite uses to write catalog/lanes.json and compose
# catalog/llm-sites.json before it loads the worker.
#
# Cases: H1-H4 run the helper on fixture roots under $T whose two builders are
# stubs that log their argv; H5 runs it on the real tree.
#   H1 both builders run, lanes first, with today's arguments; rc 0.
#   H2 lanes-build fails: the lanes FAIL line, rc 1, llm-sites-build never runs.
#   H3 llm-sites-build fails: the llm-sites FAIL line, rc 1.
#   H4 a failure returns to the caller; it never exits the caller's shell.
#   H5 the real tree: both catalogs exist and parse.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/worker-catalogs.bh-7119-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

# stub_root <name> <lanes rc> <llm-sites rc>: a fixture root whose two builders
# append "<builder> <argv>" to <root>/calls.log and exit with the given rc.
stub_root() {
  local r="$T/$1"
  mkdir -p "$r/bin"
  printf '#!/bin/bash\necho "lanes-build $*" >> "%s/calls.log"\nexit %s\n' "$r" "$2" > "$r/bin/lanes-build.sh"
  printf '#!/bin/bash\necho "llm-sites-build $*" >> "%s/calls.log"\nexit %s\n' "$r" "$3" > "$r/bin/llm-sites-build.sh"
  chmod +x "$r/bin/lanes-build.sh" "$r/bin/llm-sites-build.sh"
  : > "$r/calls.log"
  echo "$r"
}

# --- H1: both run, in order, with today's arguments ------------------------------
R=$(stub_root h1 0 0)
OUT=$(worker_catalogs "$R"); RC=$?
WANT="lanes-build --root $R --write
llm-sites-build --compose --repo $R"
GOT=$(cat "$R/calls.log")
if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$GOT" = "$WANT" ]; then ok "H1 lanes then llm-sites, today's arguments, rc 0"
else bad "H1 want rc 0, no output and [$WANT]; got rc $RC, [$OUT], [$GOT]"; fi

# --- H2: lanes-build fails -------------------------------------------------------
R=$(stub_root h2 1 0)
OUT=$(worker_catalogs "$R"); RC=$?
GOT=$(cat "$R/calls.log")
if [ "$RC" -eq 1 ] && [ "$OUT" = "FAIL: cannot write catalog/lanes.json" ] && [ "$GOT" = "lanes-build --root $R --write" ]; then
  ok "H2 lanes-build fails: its FAIL line, rc 1, llm-sites-build not run"
else bad "H2 want rc 1, the lanes FAIL line and one lanes call; got rc $RC, [$OUT], [$GOT]"; fi

# --- H3: llm-sites-build fails ---------------------------------------------------
R=$(stub_root h3 0 1)
OUT=$(worker_catalogs "$R"); RC=$?
if [ "$RC" -eq 1 ] && [ "$OUT" = "FAIL: cannot compose catalog/llm-sites.json" ]; then
  ok "H3 llm-sites-build fails: its FAIL line, rc 1"
else bad "H3 want rc 1 and the llm-sites FAIL line; got rc $RC, [$OUT]"; fi

# --- H4: a failure returns, it never exits the caller ------------------------------
R=$(stub_root h4 1 0)
OUT=$(bash -c '. "$1/tests/lib/worker-catalogs.sh" || exit 9; worker_catalogs "$2" || echo "after rc=$?"' _ "$DIR" "$R")
if [ "$OUT" = "FAIL: cannot write catalog/lanes.json
after rc=1" ]; then ok "H4 a failure returns rc 1 to the caller, the caller goes on"
else bad "H4 want the FAIL line then 'after rc=1'; got [$OUT]"; fi

# --- H5: the real tree -------------------------------------------------------------
OUT=$(worker_catalogs "$DIR"); RC=$?
if [ "$RC" -ne 0 ]; then bad "H5 real tree: rc $RC, [$OUT]"
elif jq -e . "$DIR/catalog/lanes.json" >/dev/null 2>&1 && jq -e . "$DIR/catalog/llm-sites.json" >/dev/null 2>&1; then
  ok "H5 real tree: catalog/lanes.json and catalog/llm-sites.json exist and parse"
else bad "H5 real tree: rc 0 but a catalog is missing or does not parse"; fi

echo "worker-catalogs: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
