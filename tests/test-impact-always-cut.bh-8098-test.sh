#!/bin/bash
# tests/test-impact-always-cut.bh-8098-test.sh — BH-8098 (slice C1 of #8050):
# THE ALWAYS SET IS THE SUITES THAT READ THE REAL CHECKOUT AS A WHOLE, NOT THE
# ONES THAT RUN `--tree`, `find` OR `git -C … ls-files` ON A SCRATCH DIRECTORY.
#
# bin/test-impact.sh's detector (TI_ALWAYS_AWK) put a suite in the always set
# for any `git -C <X> ls-files`, any `--tree <X>` and any `find "$D…"`, also
# when <X> was a mktemp directory, and `$D` matched `$DEST`. C1 drops a hit
# whose target variable the suite itself assigns to a non-checkout value
# (bin/test-impact.sh, "the always-run set"). Every case drives the real CLI:
#
#   N1-N10  a scratch target: not always (N8: TI_ALWAYS_NARROW= is on;
#           N10: find "$DEST" with DEST unassigned is not find "$D")
#   K1-K18  a checkout, positional, loop-bound, read-bound, cwd or literal
#           target, a glob, a commented assignment: always
#   K12     TI_ALWAYS_NARROW=0 is today's detector: N1-N7 and N10 always again
#   K13     TI_ALWAYS_NARROW=yes is off and says so once on stderr
#   I1      the map has no `*` row for N1; `inputs` (the suite fingerprint)
#           keeps it: ti_inputs builds with TI_ALWAYS_NARROW=0
#   R1      the real tree: the removed suites are out, the kept ones in, and
#           each removed suite still has a non-`*` map row
#   R2      the real tree with TI_ALWAYS_NARROW=0: the detector suites are back
#   R3      the real always count is at most ALWAYS_MAX
#   R4      one prompt (prompts/build-discipline.md) selects at most Z2_MAX
#
# Self-contained: no network, no secrets, no clock read. It reads the tree and
# writes only under $T.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1

TI="$DIR/bin/test-impact.sh"
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

# The fixture lines are single-quoted on purpose: quoted text is data to the
# detector, so this suite's own fixtures do not put it in the always set.
R="$T/nk"
mkdir -p "$R/tests" "$R/catalog"
: > "$R/catalog/test-impact-always.txt"
# @D@ in a fixture line is the checkout variable: the map does not mask quoted
# text, and a rooted bin path there would make this suite read all of bin/.
fixture() { local n="$1"; shift; printf '%s\n' "$@" | awk '{ gsub(/@D@/, "$" "DIR"); print }' > "$R/tests/$n-test.sh"; }
run_always() { # [env assignments...] — the real CLI on the scratch root
  env "$@" "$TI" --root "$R" always > "$R.out" 2> "$R.err"; ARC=$?
}
is_always()  { grep -qxF "tests/$1-test.sh" "$R.out"; }
expect_in()  { if is_always "$1"; then ok "$2"; else bad "$2 (always: $(tr '\n' ' ' < "$R.out"))"; fi; }
expect_out() { if is_always "$1"; then bad "$2 (always: $(tr '\n' ' ' < "$R.out"))"; else ok "$2"; fi; }

fixture n1 'R=$(mktemp -d)' 'bash "$RP" --tree "$R" --base x'
fixture n2 'D=$(mktemp -d)' 'f=$(find "$D/fx" -maxdepth 1 -type f | head -1)'
fixture n3 'T=$(mktemp -d)' 'R="$T/repo"' '[ -z "$(git -C "$R" ls-files -u)" ] && echo merged'
fixture n4 'DEST=$(mktemp -d)' 'NF=$(find "$DEST/hub" -mindepth 1 | wc -l)'
fixture n5 'T=$(mktemp -d)' 'REPOS_ROOT="$T/repos"' 'B=$(find "$REPOS_ROOT" -maxdepth 1 | head -1)'
fixture n6 'T=$(mktemp -d)' 'run() {' '  local F="$T/f"' '  bash "$RP" --tree "$F" --base x' '}'
fixture n7 'T=$(mktemp -d)' 'export C="$T/c"' '"$CL" --tree "$C" --base x'
fixture n9 '. "$(dirname "$0")/lib/scratch.sh" || exit 1' 'RC=$(runchk --tree "$T/at1" --base x)'

fixture n10 'NF=$(find "$DEST/hub" -mindepth 1 | wc -l)'
fixture k18 'R="@D@/tests"' 'git -C "$R" ls-files | wc -l'
fixture k1 'DIR=$(cd "$(dirname "$0")/.." && pwd)' 'git -C "@D@" ls-files | wc -l'
fixture k2 'DIR=$(cd "$(dirname "$0")/.." && pwd)' 'R="@D@"' 'git -C "$R" ls-files | wc -l'
fixture k3 'DIR=$(cd "$(dirname "$0")/.." && pwd)' 'R="@D@/tests/fixtures"' 'bash x --tree "$R"'
fixture k4 'git -C "$1" ls-files -z | wc -l'
fixture k5 '[ -z "$(git -C "$R" ls-files -u)" ] && echo merged'
fixture k6 'R=$(mktemp -d)' 'git -C "$R" ls-files | wc -l' 'DIR=$(cd "$(dirname "$0")/.." && pwd)' 'R="@D@"'
fixture k7 'T=$(mktemp -d)' 'R=$(mktemp -d)' 'for R in "@D@" "$T"; do git -C "$R" ls-files; done'
fixture k8 'T=$(mktemp -d)' 'R=$(mktemp -d)' 'read -r R < "$T/x"' 'bash x --tree "$R"'
fixture k9 'T=$(mktemp -d)' 'run "$T/wt" -- "$CR" --tree .'
fixture k10 'R=$(mktemp -d)' '(cd "@D@" && git ls-files -z | tar -cf - -T -) | tar -x -C "$R"'
fixture k11 'T=$(mktemp -d)' 'for t in "@D@"/tests/*.sh; do echo "$t"; done'
fixture k14 '# R=$(mktemp -d)' '[ -z "$(git -C "$R" ls-files -u)" ] && echo merged'
fixture k15 'D=$(mktemp -d)' 'find "@D@/bin" -name x'
fixture k16 'HERE=$(cd "$(dirname "$0")" && pwd)' 'find "$HERE" -name x'
fixture k17 'R=$1' 'git -C "$R" ls-files | wc -l'

N_ALL="n1 n2 n3 n4 n5 n6 n7 n9 n10"
K_ALL="k1 k2 k3 k4 k5 k6 k7 k8 k9 k10 k11 k14 k15 k16 k17 k18"

echo "N/K: the detector on scratch fixtures (TI_ALWAYS_NARROW unset)"
run_always -u TI_ALWAYS_NARROW
[ "$ARC" = 0 ] && ok "N always rc 0" || bad "N always rc=$ARC err=$(cat "$R.err")"
for c in $N_ALL; do expect_out "$c" "$c: a scratch target is not always"; done
for c in $K_ALL; do expect_in "$c" "$c: a checkout or unknown target stays always"; done
[ ! -s "$R.err" ] && ok "N/K: the default prints nothing on stderr" || bad "N/K stderr: $(cat "$R.err")"

echo "N8: TI_ALWAYS_NARROW= (empty) and =1 are on"
run_always TI_ALWAYS_NARROW=
expect_out n1 "N8 empty: N1 is not always"
run_always TI_ALWAYS_NARROW=1
expect_out n1 "N8 =1: N1 is not always"
expect_in k1 "N8 =1: K1 is always"

echo "K12: TI_ALWAYS_NARROW=0 is today's detector"
run_always TI_ALWAYS_NARROW=0
[ "$ARC" = 0 ] && ok "K12 rc 0" || bad "K12 rc=$ARC"
for c in n1 n2 n3 n4 n5 n6 n7 n10; do expect_in "$c" "K12 $c is always with the switch off"; done
[ ! -s "$R.err" ] && ok "K12 =0 prints nothing on stderr" || bad "K12 stderr: $(cat "$R.err")"

echo "K13: any other value is off, with one stderr line"
run_always TI_ALWAYS_NARROW=yes
expect_in n1 "K13 yes: N1 is always"
[ "$(grep -cxF 'always: off (TI_ALWAYS_NARROW=yes)' "$R.err")" = 1 ] && ok "K13 one off line" \
  || bad "K13 stderr: $(cat "$R.err")"

echo "I1: the map drops the * row, the suite fingerprint (inputs) keeps it"
"$TI" --root "$R" map > "$R.map" 2> "$R.maperr"; rc=$?
[ "$rc" = 0 ] && ! grep -qxF "tests/n1-test.sh	*" "$R.map" && ok "I1 map: N1 has no * row" \
  || bad "I1 map rc=$rc rows: $(grep -F tests/n1-test.sh "$R.map" | tr '\n' '|')"
"$TI" --root "$R" inputs > "$R.inputs" 2> "$R.inerr"; rc=$?
[ "$rc" = 0 ] && grep -qxF "tests/n1-test.sh	*" "$R.inputs" && ok "I1 inputs: N1 keeps its * row (today's detector)" \
  || bad "I1 inputs rc=$rc rows: $(grep -F tests/n1-test.sh "$R.inputs" | tr '\n' '|') err=$(cat "$R.inerr")"

# ── the real tree ───────────────────────────────────────────────────────────
# Measured on main 8bed51d1 (2026-10-23, docs/notes/2026-10-23-BH-8098-always-cut.md):
# the always set was 84 suites and prompts/build-discipline.md selected 118.
# REMOVED_DET left through the narrowed detector, REMOVED_PIN through the
# catalog pins BH-8098 deleted.
# The lists name the suites without their tests/ prefix (added back by
# tpath): a literal suite path is a read to the map, and naming 50 suites
# would select this suite on every diff that reaches any of them.
REMOVED_DET="agent-call-no-tools-lint.bh-7276-test.sh ci-local.bh-6897-test.sh discipline-dupes.bh-5788-test.sh
fixture-hygiene.bh-5789-test.sh gh-rest-etag-test.sh
gh-rest-etag.bh-1322-test.sh gh-rest-lib-test.sh gh-rest-list-lib-test.sh
gh-rest-quota-test.sh gh-rest-quota.bh-1509-test.sh index-on-create-table.bh-6730-test.sh
lane-run-warm-clones.bh-7716-test.sh mc/schema-drop-safe.bh-6005-3-test.sh
plan-diff-bind.bh-7273-test.sh project-loop-lint.bh-5945-test.sh
rules-pack.bh-3510-test.sh schema-fragment-lint.bh-5788-test.sh schema-fragment-name.bh-5788-test.sh
schema-stamp-order.bh-7229-test.sh state-restore-standby.bh-401-test.sh
suite-reach-check.bh-7669-test.sh tests-trace-safety-test.sh
tier-wording-lint.bh-4582-test.sh triage-state-pr-record.bh-3417-test.sh untriaged-lib.bh-2752-test.sh"
REMOVED_PIN="ci-shard-split-test.sh fixround-lead-reviews.bh-2200-test.sh
fixround-unaddressed-report.bh-2276-test.sh hold-push-guard.bh-2504-test.sh
lead-review-rules-pack.bh-3546-test.sh remote-gate.bh-1597-test.sh
readiness-report-test.sh spec-artifact-test.sh"
KEPT="test-impact-test.sh registry-parity.bh-5651-test.sh pycache-untracked.bh-1138-test.sh
br-split-layout-test.sh remote-gate-test.sh watchdog-url-tree.bh-2091-test.sh
gh-rest-no-subshell-lint.sh gh-app-ratchet-test.sh pr-scoped-test-lint.bh-5684-test.sh
config-literal-lint.sh model-literal-lint.sh generated-files-train-test.sh
llm-call-ratchet-test.sh ratchet-markers-test.sh registry-no-commit-test.sh
share-publish-clean.bh-795-test.sh verification-map-no-commit-test.sh
generated-not-tracked.bh-5518-test.sh"
# Each bound is the after-number this build measured on its own tree plus at
# most 10% for corpus growth (docs/notes/2026-10-23-BH-8098-always-cut.md).
ALWAYS_MAX=55   # after 51, before 84
Z2_MAX=95       # after 88 (this suite names the prompt), before 118 (119 with this suite)

# in_tree <path> — rc 0 when the checkout holds <path>. A cd, not a rooted
# path: the map reads a checkout tail it cannot bind as a whole-tree read.
in_tree() { ( cd "$DIR" && [ -f "$1" ] ); }
tpath() { printf 'tests/%s\n' "$@"; }

echo "R1: the real tree drops the scratch-target suites and the 8 pins"
# R1 pins what the catalog holds, so an edit to it selects this suite.
CAT="$DIR/catalog/test-impact-always.txt"
[ -f "$CAT" ] && ok "R1 the always catalog is in the tree" || bad "R1 no $CAT"
"$TI" always > "$T/real.always" 2> "$T/real.err"; rc=$?
[ "$rc" = 0 ] && [ -s "$T/real.always" ] && ok "R1 real always rc 0, non-empty" || bad "R1 real always rc=$rc err=$(cat "$T/real.err")"
"$TI" map --out "$T/map" 2> "$T/map.err" || bad "R1 the map could not be built: $(cat "$T/map.err")"
for s in $(tpath $REMOVED_DET $REMOVED_PIN); do
  in_tree "$s" || continue
  grep -qxF "$s" "$T/real.always" && bad "R1 $s is still always"
  [ "$(awk -F'\t' -v s="$s" '$1 == s && $2 != "*"' "$T/map" | grep -c .)" -gt 0 ] || bad "R1 $s has no non-* map row (it would never run)"
done
ok "R1 checked the removed list"
for s in $(tpath $KEPT); do
  grep -qxF "$s" "$T/real.always" && ok "R1 $s stays always" || bad "R1 $s left the always set"
done

echo "R2: TI_ALWAYS_NARROW=0 on the real tree brings the detector suites back"
TI_ALWAYS_NARROW=0 "$TI" always > "$T/real0.always" 2> "$T/real0.err"; rc=$?
[ "$rc" = 0 ] && ok "R2 rc 0" || bad "R2 rc=$rc err=$(cat "$T/real0.err")"
miss=""
for s in $(tpath $REMOVED_DET); do in_tree "$s" || continue; grep -qxF "$s" "$T/real0.always" || miss="$miss $s"; done
[ -z "$miss" ] && ok "R2 every detector-removed suite is back with the switch off" || bad "R2 not back:$miss"

echo "R3: the real always count"
n=$(grep -c . "$T/real.always")
[ "$n" -le "$ALWAYS_MAX" ] && [ "$n" -lt 84 ] && ok "R3 always holds $n suites (at most $ALWAYS_MAX)" || bad "R3 always holds $n suites (bound $ALWAYS_MAX)"

echo "R4: one prompt selects at most Z2_MAX"
printf '%s\n' prompts/build-discipline.md > "$T/z2.changed"
"$TI" select --map "$T/map" --changed "$T/z2.changed" > "$T/z2.out" 2> "$T/z2.err"; rc=$?
n=$(grep -c . "$T/z2.out")
[ "$rc" = 0 ] && [ "$n" -le "$Z2_MAX" ] && [ "$n" -lt 118 ] && ok "R4 Z2 selects $n suites (at most $Z2_MAX)" \
  || bad "R4 Z2 rc=$rc selects $n (bound $Z2_MAX): $(grep '^impact:' "$T/z2.err")"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
