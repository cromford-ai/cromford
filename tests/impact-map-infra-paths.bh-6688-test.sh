#!/bin/bash
# tests/impact-map-infra-paths.bh-6688-test.sh — the culprit finder's reach of
# one member uses the batch select, so an infra path reaches the suites the
# map ties to it, not the corpus (BH-6688).
#
# WHY. bim_reach (bin/lib/mc-batch-impact.sh) ran `test-impact.sh select`
# without TI_BATCH_SELECT=1. Every catalog/ and tests/lib/ path then matched the
# PR select's infra list and reached `*`. In the BH-5373 replay 17 of 20 draft
# members reached `*`, and the culprit decision was `several` on all 10 decided
# drafts. The map built from THIS tree is the fixture: the cases are the path
# classes the replay named.
#
#   C1  catalog/lanes.d/<lane>.json is bounded and holds a suite that names it
#   C2  catalog/lanes.d/<lane>.knobs.d/<K>.json is bounded
#   C3  catalog/pr-self-check.tsv is bounded
#   C4  a seed rules fragment, catalog/ci-batch-escalate.d/seed-infra.tsv, is
#       bounded and holds the fragments suite (the old single file is retired,
#       BH-8649)
#   C5  a tests/lib/ helper (not scratch.sh) is bounded
#   C6  an unmapped bin/lib/ file is `*` with its reason in <files>.full, and
#       _bim_compute logs BATCH_IMPACT_FULL and BATCH_IMPACT_REACH
#   C7  the docker runner, a nested workflow path, and a list with the runner
#       are `*`; a top-level workflow file reaches its readers since BH-6876
#       (the batch select runs them, not the corpus)
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/impact-map-infra-paths.bh-6688-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

BIM_LIB="$DIR/bin/lib/mc-batch-impact.sh"
BEJ_LIB="$DIR/bin/lib/mc-batch-eject.sh"
MAP="$T/map"
bash "$DIR/bin/test-impact.sh" map --root "$DIR" --out "$MAP" 2>"$T/map.err" && [ -s "$MAP" ] \
  || { echo "FAIL: the map could not be built: $(cat "$T/map.err")"; exit 1; }

# reach <tag> <path…> — bim_reach on that list; sets RC, R (the reach) and F
# (the list file, whose .full sidecar the lib writes).
reach() {
  F="$T/files.$1"; shift
  printf '%s\n' "$@" > "$F"
  R=$(HARNESS="$DIR" bash -c '. "$1" || exit 9; bim_reach "$2" "$3"' _ "$BIM_LIB" "$F" "$MAP"); RC=$?
}
# bounded <case> <path> — the reach is a non-empty list, never `*`.
bounded() {
  reach "$1" "$2"
  if [ "$RC" = 0 ] && [ -n "$R" ] && ! grep -qxF '*' <<<"$R" && [ ! -e "$F.full" ]; then ok
  else bad "$1 $2 reaches a bounded list (rc $RC, $(grep -c . <<<"$R") lines: $(head -3 <<<"$R" | paste -sd' ' -))"; fi
}
# rows_for <path> — the suites the map ties to that path by name or directory
# (no whole-tree row).
rows_for() {
  awk -F'\t' -v p="$1" '$2 != "*" && ($2 == p || ($2 ~ /\/$/ && $2 != "catalog/" && index(p, $2) == 1)) { print $1 }' "$MAP" | LC_ALL=C sort -u
}

# C1 — a lane file.
LANE=catalog/lanes.d/merge-conductor.json
[ -f "$DIR/$LANE" ] || bad "C1 fixture: $LANE is not in this tree"
bounded C1 "$LANE"
SPEC=$(rows_for "$LANE" | head -1)
[ -n "$SPEC" ] && grep -qxF "$SPEC" <<<"$R" && ok || bad "C1 the reach holds $SPEC, a suite the map ties to $LANE"

# C2 — a lane knob file.
KNOB=$(cd "$DIR" && ls catalog/lanes.d/*.knobs.d/*.json 2>/dev/null | head -1)
[ -n "$KNOB" ] && bounded C2 "$KNOB" || bad "C2 fixture: no catalog/lanes.d/*.knobs.d/*.json in this tree"

# C3, C4 — catalog TSVs read by one script.
bounded C3 catalog/pr-self-check.tsv
WSUITE=$(head -1 <<<"$R")
bounded C4 catalog/ci-batch-escalate.d/seed-infra.tsv
grep -qxF tests/ci-batch-escalate-fragments.bh-8608-test.sh <<<"$R" && ok \
  || bad "C4 catalog/ci-batch-escalate.d/seed-infra.tsv reaches tests/ci-batch-escalate-fragments.bh-8608-test.sh"

# C5 — the first tests/lib/ helper the map names, scratch.sh and docs aside.
HELPER=$(awk -F'\t' '$2 ~ /^tests\/lib\// && $2 !~ /\/$/ && $2 != "tests/lib/scratch.sh" && $2 !~ /\.md$/ { print $2 }' "$MAP" | LC_ALL=C sort -u | head -1)
[ -n "$HELPER" ] && bounded C5 "$HELPER" || bad "C5 fixture: the map names no tests/lib/ helper"

# C6 — an unmapped bin/lib/ file is `*`, and the reason is beside the list.
NEWLIB=bin/lib/new-bh6688-unmapped.sh
reach C6 "$NEWLIB"
[ "$RC" = 0 ] && [ "$R" = '*' ] && ok || bad "C6 $NEWLIB reaches * (rc $RC, $(grep -c . <<<"$R") lines: $(head -2 <<<"$R" | paste -sd' ' -))"
[ "$(cat "$F.full" 2>/dev/null)" = "full: unmapped path ($NEWLIB)" ] && ok \
  || bad "C6 the .full sidecar names the path: '$(cat "$F.full" 2>/dev/null)'"
# A bounded re-run on the same list file clears a stale sidecar.
printf 'catalog/pr-self-check.tsv\n' > "$F"
HARNESS="$DIR" bash -c '. "$1" || exit 9; bim_reach "$2" "$3" >/dev/null' _ "$BIM_LIB" "$F" "$MAP"
[ ! -e "$F.full" ] && ok || bad "C6 a bounded reach removes the old .full sidecar"

# C6 through _bim_compute: draft #20 holds #11 (a catalog TSV) and #12 (the
# unmapped lib), and the failed suite is one #11 reaches. Every network read is stubbed at the function the lib calls.
S="$T/c6"; mkdir -p "$S"
printf 'catalog/pr-self-check.tsv\n' > "$S/files-11"
printf '%s\n' "$NEWLIB" > "$S/files-12"
: > "$S/log"
HARNESS="$DIR" HARNESS_REPO=example-org/cromford HARNESS_TEST_SANDBOX=1 MC_BATCH_IMPACT_MAP="$MAP" WSUITE="$WSUITE" \
  bash -c '
    S="$1"; unset H
    mc_log() { echo "$*" >> "$S/log"; }
    . "$2" || exit 9
    . "$3" || exit 9
    mc_rest_var() { local __o="$1" __v="" __rc=0; shift; __v=$("$@") || __rc=$?; printf -v "$__o" "%s" "$__v"; return "$__rc"; }
    gh_rest() {
      case "$2" in
        */pulls/20) jq -nc "{number: 20, title: \"merge queue: checking #11 + #12 together on main (abc1234)\"}" ;;
        */pulls/1[12]) jq -nc "{head: {sha: \"$(printf "%040d" "${2##*/}")\"}}" ;;
        *) return 44 ;;
      esac
    }
    gh_rest_issue_comments() { echo "[]"; }
    bej_parse_dequeue() { printf "20\tx\n"; }
    mc_pr_files() { cat "$S/files-$2"; }
    _bs_facts() { _bs_f="ok abc1234def5678901234567890abcdef12345678 $WSUITE 11 12"; }
    _bim_compute example-org/cromford 20 -
    echo "$BIM_DECISION" > "$S/decision"
  ' _ "$S" "$BEJ_LIB" "$BIM_LIB"
grep -qxF "BATCH_IMPACT_FULL draft=20 pr=12 full: unmapped path ($NEWLIB)" "$S/log" && ok \
  || bad "C6 _bim_compute logs BATCH_IMPACT_FULL for #12: $(cat "$S/log")"
grep -q "BATCH_IMPACT_FULL draft=20 pr=11" "$S/log" && bad "C6 the bounded #11 logs no BATCH_IMPACT_FULL: $(cat "$S/log")" || ok
grep -qxF "BATCH_IMPACT_REACH draft=20 full=1 of 2 members" "$S/log" && ok \
  || bad "C6 _bim_compute logs BATCH_IMPACT_REACH full=1 of 2: $(cat "$S/log")"
grep -q '^bisect several ' "$S/decision" 2>/dev/null && ok \
  || bad "C6 #11 reaches the failed suite and #12 is *, so the decision is several: $(cat "$S/decision" 2>/dev/null)"

# C7 — the negatives: these stay `*`.
reach C7a bin/run-tests-in-docker.sh
[ "$RC" = 0 ] && [ "$R" = '*' ] && ok || bad "C7 bin/run-tests-in-docker.sh stays * (rc $RC): $(head -2 <<<"$R")"
reach C7b .github/workflows/sub/x.yml
[ "$RC" = 0 ] && [ "$R" = '*' ] && ok || bad "C7 a nested workflow path stays * (rc $RC): $(head -2 <<<"$R")"
reach C7b2 .github/workflows/harness-ci.yml
{ [ "$RC" = 0 ] && [ "$R" != '*' ] && grep -qxF tests/ci-test-tiers-workflow.bh-5653-test.sh <<<"$R"; } && ok \
  || bad "C7 harness-ci.yml reaches its readers since BH-6876 (rc $RC): $(head -2 <<<"$R")"
reach C7c catalog/pr-self-check.tsv bin/run-tests-in-docker.sh
[ "$RC" = 0 ] && [ "$R" = '*' ] && ok || bad "C7 a bounded path plus the runner is * (rc $RC): $(head -2 <<<"$R")"
grep -qF 'bin/run-tests-in-docker.sh' "$F.full" 2>/dev/null && ok || bad "C7 the sidecar names the runner: $(cat "$F.full" 2>/dev/null)"

echo "impact-map-infra-paths.bh-6688: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
