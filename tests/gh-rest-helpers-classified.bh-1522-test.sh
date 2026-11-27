#!/bin/bash
# tests/gh-rest-helpers-classified.bh-1522-test.sh — BH-1522 (N2): every
# gh_rest_* helper defined in bin/lib/gh-rest*.sh is CLASSIFIED, one way or the
# other.
#
# WHY. tests/gh-rest-no-subshell-lint.sh flags an ENUMERATED list of
# status-bearing helpers (its HELPERS tuple), deliberately not a `gh_rest*`
# wildcard — BH-1485's fix round explains why. The cost of enumerating is that
# a genuinely new status-bearing helper is OUTSIDE the lint the day it is
# defined and nothing says so. This suite closes that: a defined helper is
# either in HELPERS (caller-visible status, so the lint guards it) or in the
# PURE_ALLOW list below with a reason (no REST call, never sets
# GH_REST_STATUS/GH_REST_REASON, so capturing it loses nothing). In neither, or
# in both, is a FAIL that names the helper and the two places to fix.
#
# The HELPERS tuple is read from the scanner itself (`scan.py --helpers`),
# extracted from the lint the same way the lint writes it out — no
# regex-parsing of Python source.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/gh-rest-helpers-classified.bh-1522-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

# Pure helpers: named gh_rest_* but no REST call and no GH_REST_STATUS /
# GH_REST_REASON of their own, so a `$( )` capture loses nothing.
PURE_ALLOW=(
  gh_rest_path_class   # bin/lib/gh-rest-ledger.sh: classifies a path string
  gh_rest_etag_report  # bin/lib/gh-rest-etag.sh: writes a log line
  gh_rest_budget_empty # bin/lib/gh-rest-empty.sh: reads the .quota- file, rc only (BH-10196)
  gh_rest_empty_lane   # bin/lib/gh-rest-empty.sh: prints the lane id from LANE_GATE_RUN
  gh_rest_empty_switch # bin/lib/gh-rest-empty.sh: reads one settings row, rc only
)

# ── the enumeration: every definition under bin/lib/gh-rest*.sh ─────────────
# `^\s*` + `gh_rest` so `_gh_rest_*` privates and `_ghrv_*` internals are out
# of scope, and one-liner `name() { …; }` definitions are in.
defined_in() {
  grep -hoE '^[[:space:]]*(function[[:space:]]+)?gh_rest[A-Za-z0-9_]*[[:space:]]*\(\)' \
    "$1"/bin/lib/gh-rest*.sh 2>/dev/null | tr -d ' ()' | sort -u
}
DEFINED=$(defined_in "$DIR")
COUNT=$(printf '%s\n' "$DEFINED" | grep -c .)
# A scan that scanned nothing is not a pass (D9): 16 exist today.
[ "$COUNT" -ge 14 ] && ok \
  || bad "1: expected >= 14 gh_rest_* definitions under bin/lib/gh-rest*.sh (got $COUNT)"

# ── the lint's HELPERS tuple, read from the scanner ─────────────────────────
awk '/cat > "\$T\/scan.py" <<'"'"'PY'"'"'/{f=1;next} /^PY$/{f=0} f' \
  "$DIR/tests/gh-rest-no-subshell-lint.sh" > "$T/scan.py"
[ -s "$T/scan.py" ] && ok \
  || bad "1: could not extract scan.py from tests/gh-rest-no-subshell-lint.sh"
HELPERS=$(python3 "$T/scan.py" --helpers | sort -u)
[ -n "$HELPERS" ] && ok || bad "1: scan.py --helpers printed nothing"

in_list() { local n=$1; shift; local x; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }

# ── row 2: every defined helper in exactly one of HELPERS / PURE_ALLOW ──────
classify_tree() {   # prints one "name" per UNCLASSIFIED helper in tree $1
  local root=$1 n
  while read -r n; do
    [ -n "$n" ] || continue
    local inh=0 inp=0
    grep -qx "$n" <<<"$HELPERS" && inh=1
    in_list "$n" "${PURE_ALLOW[@]}" && inp=1
    [ $((inh + inp)) = 1 ] || echo "$n"
  done < <(defined_in "$root")
}
UNCLASSIFIED=$(classify_tree "$DIR")
if [ -z "$UNCLASSIFIED" ]; then ok
else bad "2: unclassified gh_rest_* helper(s) — add each to the lint's HELPERS tuple (tests/gh-rest-no-subshell-lint.sh) if it can set GH_REST_STATUS, else to PURE_ALLOW in this file with a reason; a name in BOTH is also this failure:
$UNCLASSIFIED"
fi

# ── row 3: no stale entry in either list ────────────────────────────────────
STALE=""
while read -r n; do
  grep -qx "$n" <<<"$DEFINED" || STALE="$STALE $n"
done <<<"$HELPERS"
for n in "${PURE_ALLOW[@]}"; do
  grep -qx "$n" <<<"$DEFINED" || STALE="$STALE $n"
done
[ -z "$STALE" ] && ok \
  || bad "3: list entries with no definition under bin/lib/gh-rest*.sh (stale):$STALE"

# ── row 4: a NEW unclassified helper is caught (D1 mutation) ────────────────
mkdir -p "$T/mut/bin/lib"
cp "$DIR"/bin/lib/gh-rest*.sh "$T/mut/bin/lib/"
printf '\ngh_rest_brand_new() { :; }\n' >> "$T/mut/bin/lib/gh-rest.sh"
MUT=$(classify_tree "$T/mut")
grep -qx "gh_rest_brand_new" <<<"$MUT" && ok \
  || bad "4: a newly defined gh_rest_brand_new must be reported unclassified (got: $MUT)"

echo "gh-rest-helpers-classified.bh-1522: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
