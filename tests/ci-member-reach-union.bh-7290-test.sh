#!/bin/bash
# tests/ci-member-reach-union.bh-7290-test.sh — BH-7290 (BH-7033.4): a batch
# never goes full on one member's unmapped path. The batch plans the UNION of
# its members' selections: the unmapped path adds its directory's suites plus
# the infra canaries (bin/lib/ci-member-reach.sh). An escalate row still makes
# the batch full.
#
# The real bin/ci-plan.sh and the real bin/test-impact.sh drive U1-U4, U6-U10;
# the map is built once and handed to test-impact through a wrapper (as in
# tests/ci-plan-batch-impact.bh-4968-test.sh). Stubs drive the shapes the real
# selector does not produce on demand (U5, U9b, U11).
#
#   U1   three members, one with an unknown path: batch-selected, not full
#   U2   the list is the union of the per-member selections + dir + canaries
#   U3   cmr_dir_suites: bin/lib/ and a top-level path, against an independent awk;
#        an unmapped bin/lib/ path plans its directory suites plus the canaries
#   U4   near misses stay full: an escalate row (.mergify.yml) next to an unmapped path, and a
#        plan-job escalation handed to a shard
#   U4b  an infra path next to an unmapped path: the union, then the infra block
#   U5   a select that fails inside the union is rc 2 with no n=
#   U6   a canary list absent, bad or empty: full, an off line, no map call
#   U7   a member touching .mergify.yml: full, `selection input: .mergify.yml`
#   U8   the `full` label still wins; canary-line validity through cmr_canaries
#   U9   CI_PLAN_MEMBER_UNION=0 and more than 20 unmapped paths: full, off line
#   U10  a shard with --expect-n re-plans the same list and exits 0
#   U11  another full answer inside the union (infra, empty selection): full
#   U12  a map that fails, a select that does not answer unmapped again, an
#        unreadable changed list: off; a path that does not leave the list: rc 2
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PLAN="$DIR/bin/ci-plan.sh"
LIB="$DIR/bin/lib/ci-member-reach.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

"$DIR/bin/test-impact.sh" map --out "$T/map" || { echo "FAIL: the map could not be built"; exit 1; }
# The wrapper: `map` copies the built map, every other call selects against it.
cat > "$T/impact.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/impact-calls.txt"
if [ "\$1" = map ]; then
  while [ \$# -gt 0 ]; do [ "\$1" = --out ] && { cp "$T/map" "\$2"; exit \$?; }; shift; done
  cat "$T/map"; exit 0
fi
exec "$DIR/bin/test-impact.sh" "\$@" --map "$T/map"
EOF
chmod +x "$T/impact.sh"
"$DIR/bin/test-impact.sh" always --map "$T/map" > "$T/always" || { echo "FAIL: always set unreadable"; exit 1; }
: > "$T/notiers.tsv"
HEADSHA=$(git -C "$DIR" rev-parse HEAD)
# Two real suites as the canaries (#7287's list may not be on this tree yet).
printf '# canaries\ntests/scratch-lib-test.sh\n\ntests/ci-plan-test.sh' > "$T/canary"
printf 'tests/ci-plan-test.sh\ntests/scratch-lib-test.sh\n' > "$T/canary.sorted"

A=bin/merge-sweep.sh; B=console-ui/src/screens/Jobs.js; C=zz-bh7290/x.sh

# bplan <path>... [-- VAR=val ...] — one batch plan; sets RC OUT GO SUM ERR, list in $T/list
bplan() {
  local paths=() vars=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do paths+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift; vars=("$@")
  if [ "${#paths[@]}" -gt 0 ]; then printf '%s\n' "${paths[@]}" > "$T/changed"; else : > "$T/changed"; fi
  rm -f "$T/go" "$T/list" "$T/sum"; : > "$T/impact-calls.txt"
  OUT=$(env -u GITHUB_ACTIONS -u CI_PLAN_MEMBER_UNION CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$HEADSHA" \
          CI_PLAN_ESCALATION=- TI_PR_LABELS= CI_QUARANTINE= CI_PLAN_IMPACT="$T/impact.sh" CI_PLAN_CHANGED_FILE="$T/changed" \
          CI_PLAN_TIER_FILE="$T/notiers.tsv" CI_INFRA_CANARY_FILE="$T/canary" GITHUB_OUTPUT="$T/go" GITHUB_STEP_SUMMARY="$T/sum" \
          ${vars[@]+"${vars[@]}"} "$PLAN" --out "$T/list" 2>"$T/err"); RC=$?
  GO=$(cat "$T/go" 2>/dev/null); SUM=$(cat "$T/sum" 2>/dev/null); ERR=$(cat "$T/err")
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }
full_is() { # full_is <tag> <escalation> — mode=full with that escalation
  { [ "$RC" = 0 ] && [ "$(out mode)" = full ] && [ "$(out escalation)" = "$2" ]; } && ok \
    || bad "$1: must be mode=full, escalation '$2' (rc=$RC mode=$(out mode) escalation='$(out escalation)') [$ERR]"
}
sel1() { # sel1 <out> <path>... — one member's own batch select (no path = the empty diff)
  local o="$1"; shift
  if [ $# -gt 0 ]; then printf '%s\n' "$@" > "$T/one"; else : > "$T/one"; fi
  TI_BATCH_SELECT=1 "$DIR/bin/test-impact.sh" select --changed "$T/one" --map "$T/map" --out "$o" 2>/dev/null
}

# ── U1. three members, one unmapped: the union, not full.
bplan "$A" "$B" "$C"
U1_LIST="$T/u1.list"; cp "$T/list" "$U1_LIST" 2>/dev/null; U1_N=$(out n)
{ [ "$RC" = 0 ] && [ "$(out mode)" = batch-selected ] && [ "$(out escalation)" = - ]; } && ok \
  || bad "U1: A+B+C must be batch-selected, escalation=- (rc=$RC mode=$(out mode) escalation='$(out escalation)') [$ERR]"
has "(member union (BH-7033.4): 1 unmapped path(s) ($C): 0 directory + 2 canaries; " "$(out summary)" && ok \
  || bad "U1: the summary names the union: '$(out summary)'"
{ [ -n "$(out count)" ] && [ "$(out count)" -lt "$(out total)" ]; } && ok || bad "U1: count ($(out count)) < total ($(out total))"
[ "$(out mode)" != full ] && ok || bad "U1: NEGATIVE: one member's unmapped path no longer makes the batch full"
has "member union (BH-7033.4)" "$SUM" && ok || bad "U1: the step summary carries the union reason [$SUM]"

# ── U2. the list is sel(A) u sel(B) u sel(C minus x.sh) u dir(C) u canaries.
sel1 "$T/sa" "$A" && sel1 "$T/sb" "$B" && sel1 "$T/sc" || bad "U2: a per-member select failed"
awk -F'\t' '$2 ~ /^zz-bh7290\// { print $1 }' "$T/map" > "$T/dc"
printf '%s\n' "$A" "$B" "$C" > "$T/abc"
"$DIR/bin/test-impact.sh" regression --changed "$T/abc" 2>/dev/null | cut -f1 > "$T/reg"
LC_ALL=C sort -u "$T/sa" "$T/sb" "$T/sc" "$T/dc" "$T/canary.sorted" "$T/reg" > "$T/want"
cmp -s "$T/want" <(LC_ALL=C sort -u "$U1_LIST") && ok \
  || bad "U2: the plan must equal the union of the members' selections ($(grep -c . "$U1_LIST") vs $(grep -c . "$T/want"); diff: $(diff "$T/want" <(LC_ALL=C sort -u "$U1_LIST") | head -5))"
grep -qxF tests/ci-plan-test.sh "$U1_LIST" && grep -qxF tests/scratch-lib-test.sh "$U1_LIST" && ok || bad "U2: both canaries are in the list"
[ -z "$(LC_ALL=C comm -23 <(LC_ALL=C sort -u "$T/always") <(LC_ALL=C sort -u "$U1_LIST"))" ] && ok || bad "U2: the always set is in the list"

# ── U3. the directory suites.
( . "$LIB" || exit 9; cmr_dir_suites "$T/map" bin/lib/zz-bh7290-new.sh ) > "$T/d-lib"
awk -F'\t' '$2 != "bin/lib/" && $2 != "*" && index($2, "bin/lib/") == 1 { print $1 }' "$T/map" | LC_ALL=C sort -u > "$T/d-lib.want"
{ [ -s "$T/d-lib" ] && cmp -s "$T/d-lib" "$T/d-lib.want"; } && ok || bad "U3: bin/lib/ dir suites ($(grep -c . "$T/d-lib") vs $(grep -c . "$T/d-lib.want"))"
( . "$LIB" || exit 9; cmr_dir_suites "$T/map" zz-bh7290-top ) > "$T/d-top"
awk -F'\t' '$2 != "*" && index($2, "/") == 0 { print $1 }' "$T/map" | LC_ALL=C sort -u > "$T/d-top.want"
cmp -s "$T/d-top" "$T/d-top.want" && ok || bad "U3: a top-level path takes the top-level rows only ($(grep -c . "$T/d-top") vs $(grep -c . "$T/d-top.want"))"
# a root row (bin/, catalog/) never counts as a directory row
printf 'tests/a-test.sh\tbin/\ntests/b-test.sh\tbin/lib/\ntests/c-test.sh\tcatalog/\ntests/d-test.sh\t*\ntests/e-test.sh\tbin/lib/x.sh\ntests/f-test.sh\tbin/libx/y.sh\n' > "$T/mini.map"
[ "$( . "$LIB" || exit 9; cmr_dir_suites "$T/mini.map" bin/lib/new.sh | paste -sd, -)" = tests/e-test.sh ] && ok \
  || bad "U3: root rows, * rows and a sibling prefix (bin/libx/) are not directory rows"
bplan "$A" bin/lib/zz-bh7290-new.sh
{ [ "$RC" = 0 ] && [ "$(out escalation)" = - ] && has "member union (BH-7033.4): 1 unmapped path(s) (bin/lib/zz-bh7290-new.sh): $(grep -c . "$T/d-lib") directory + 2 canaries" "$(out summary)"; } && ok \
  || bad "U3: an unmapped bin/lib/ path plans its directory suites (rc=$RC mode=$(out mode) escalation='$(out escalation)' summary='$(out summary)') [$ERR]"
[ -z "$(LC_ALL=C comm -23 <(LC_ALL=C sort -u "$T/d-lib" "$T/canary.sorted") <(LC_ALL=C sort -u "$T/list"))" ] && ok \
  || bad "U3: the bin/lib/ directory suites and the canaries are in the list"

# ── U4. near misses stay full.
# .mergify.yml is an escalate row. bin/test-impact.sh was one until BH-7287
# made bin/test-impact*.sh an infra row (catalog/ci-batch-escalate.tsv).
bplan "$A" .mergify.yml "$C"
full_is "U4 escalate row + unmapped" "selection input: .mergify.yml"
# U4b. an infra path next to an unmapped path: the union reads the diff without
# the infra path, then the BH-7287 infra block adds that path's suites.
bplan "$A" bin/test-impact.sh "$C"
{ [ "$RC" = 0 ] && [ "$(out mode)" = infra ] && [ "$(out escalation)" = - ]; } && ok \
  || bad "U4b infra + unmapped must be mode=infra, escalation=- (rc=$RC mode=$(out mode) escalation='$(out escalation)') [$ERR]"
has "infra: 1 path(s) (bin/test-impact.sh): " "$(out summary)" && has "member union (BH-7033.4): 1 unmapped path(s) ($C): " "$(out summary)" && ok \
  || bad "U4b: the summary names the infra path and the union: '$(out summary)'"
[ -z "$(LC_ALL=C comm -23 "$T/canary.sorted" <(LC_ALL=C sort -u "$T/list"))" ] && ok || bad "U4b: the canaries are in the list"
bplan "$A" "$C" -- "CI_PLAN_ESCALATION=unmapped: x"
full_is "U4 shard given the plan job's escalation" "unmapped: x"

# ── U5. a select that fails inside the union is rc 2, never a plan.
cat > "$T/fail2.sh" <<EOF
#!/bin/bash
if [ "\$1" = select ]; then
  n=\$(cat "$T/selects" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$T/selects"
  [ "\$n" -lt 2 ] || exit 1
fi
exec "$T/impact.sh" "\$@"
EOF
chmod +x "$T/fail2.sh"; rm -f "$T/selects"
bplan "$A" "$C" -- CI_PLAN_IMPACT="$T/fail2.sh"
{ [ "$RC" = 2 ] && [ -z "$(out n)" ] && has "ci-plan: member union: select failed" "$ERR"; } && ok \
  || bad "U5: a failed union select must be rc 2 with no n= (rc=$RC n=$(out n)) [$ERR]"

# ── U6. a canary list that cannot be trusted: full, an off line, no map call.
printf 'bin/x.sh\n' > "$T/c-bin"; printf 'tests/zz-bh7290-missing.sh\n' > "$T/c-miss"; printf '# only comments\n\n' > "$T/c-none"
for c in "$T/no-such-canary" "$T/c-bin" "$T/c-miss" "$T/c-none"; do
  bplan "$A" "$C" -- CI_INFRA_CANARY_FILE="$c"
  full_is "U6 $(basename "$c")" "unmapped: $C"
  has "ci-plan: member union: off (canary list unreadable (" "$ERR" && ok || bad "U6 $(basename "$c"): the off line [$ERR]"
  grep -q '^map' "$T/impact-calls.txt" && bad "U6 $(basename "$c"): no map is built when the canaries are off" || ok
done

# ── U7. a member touching .mergify.yml still plans full.
bplan "$A" .mergify.yml "$C"
full_is "U7" "selection input: .mergify.yml"

# ── U8. the `full` label still wins; canary validity on its own.
bplan "$A" "$C" -- "TI_PR_LABELS=docs, full"
full_is "U8 full label" "the 'full' label"
canary() { printf "$1" > "$T/cv"; ( . "$LIB" || exit 9; CI_INFRA_CANARY_FILE="$T/cv" cmr_canaries "$DIR" "$T/cv.out" || { echo "WHY:$CMR_WHY"; exit 1; } ); }
for good in 'tests/scratch-lib-test.sh\n' '# c\ntests/scratch-lib-test.sh\n' 'tests/scratch-lib-test.sh'; do
  canary "$good" >/dev/null && [ "$(cat "$T/cv.out")" = tests/scratch-lib-test.sh ] && ok || bad "U8 canary '$good' is valid"
done
for badl in 'tests/*.sh\n' 'tests/../bin/x.sh\n' 'tests/scratch-lib-test.sh \n' 'bin/x.sh\n' 'tests/zz-missing.sh\n' '# only\n'; do
  canary "$badl" >/dev/null && bad "U8 canary '$badl' must be refused" || ok
done

# ── U9. the knob, and more than 20 unmapped paths.
bplan "$A" "$C" -- CI_PLAN_MEMBER_UNION=0
full_is "U9 knob" "unmapped: $C"
has "ci-plan: member union: off (CI_PLAN_MEMBER_UNION=0)" "$ERR" && ok || bad "U9: the knob's off line [$ERR]"
grep -q '^map' "$T/impact-calls.txt" && bad "U9: the knob is checked before the map" || ok
# A stub: every select answers unknown reach on its first path.
cat > "$T/unk.sh" <<'EOF'
#!/bin/bash
cmd="$1"; out=""; ch=""
while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift ;; --changed) ch="$2"; shift ;; esac; shift; done
# UNK_STOP set: a list that no longer starts with zz-bh7290/x.sh answers
# `full: $UNK_STOP` instead. An empty list selects one suite.
all() { printf 'tests/a-test.sh\ntests/b-test.sh\ntests/c-test.sh\n' > "$out"; }
# UNK_NOMAP: `map` fails. UNK_FIXED: every select names that path. UNK_ONCE
# (a counter file): only the first select answers unknown reach.
case "$cmd" in
  map) [ -z "${UNK_NOMAP:-}" ] || exit 1; printf 'tests/a-test.sh\tbin/a.sh\n' > "$out" ;;
  ci-select) all; echo "impact: 300 of 300 suites (full: event)" >&2 ;;
  select) p=$(grep -m1 . "$ch"); [ -z "${UNK_FIXED:-}" ] || p="$UNK_FIXED"
          if [ -n "${UNK_ONCE:-}" ]; then
            n=$(cat "$UNK_ONCE" 2>/dev/null || echo 0); echo $((n + 1)) > "$UNK_ONCE"
            [ "$n" = 0 ] || { printf 'tests/a-test.sh\n' > "$out"; echo "impact: 1 of 300 suites (selected: 1 changed path(s))" >&2; exit 0; }
          fi
          if [ -z "$p" ]; then printf 'tests/a-test.sh\n' > "$out"; echo "impact: 1 of 300 suites (selected: the diff is empty)" >&2
          elif [ -n "${UNK_STOP:-}" ] && [ "$p" != zz-bh7290/x.sh ]; then all; echo "impact: 300 of 300 suites (full: $UNK_STOP)" >&2
          else all; echo "impact: 300 of 300 suites (full: unknown reach ($p))" >&2; fi ;;
esac
EOF
chmod +x "$T/unk.sh"
mapfile -t Z21 < <(for i in $(seq 1 21); do echo "zz-bh7290/$i.sh"; done)
bplan "${Z21[@]}" -- CI_PLAN_IMPACT="$T/unk.sh"
full_is "U9 21 unmapped" "unmapped: zz-bh7290/1.sh"
has "ci-plan: member union: off (more than 20 unmapped paths)" "$ERR" && ok || bad "U9: the 21-path off line [$ERR]"
bplan "${Z21[@]:0:20}" -- CI_PLAN_IMPACT="$T/unk.sh"
{ [ "$(out escalation)" = - ] && has "member union (BH-7033.4): 20 unmapped path(s) (zz-bh7290/1.sh)" "$(out summary)"; } && ok \
  || bad "U9: 20 unmapped paths still union (escalation='$(out escalation)' summary='$(out summary)') [$ERR]"

# ── U10. a shard re-plans the same list.
printf '%s\n' "$A" "$B" "$C" > "$T/changed"
SHARD_OUT=$(env -u GITHUB_ACTIONS -u GITHUB_OUTPUT -u CI_PLAN_MEMBER_UNION CI_EVENT=pull_request TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$HEADSHA" \
  CI_PLAN_ESCALATION=- TI_PR_LABELS= CI_QUARANTINE= CI_PLAN_IMPACT="$T/impact.sh" CI_PLAN_CHANGED_FILE="$T/changed" \
  CI_PLAN_TIER_FILE="$T/notiers.tsv" CI_INFRA_CANARY_FILE="$T/canary" "$PLAN" --out "$T/shard.list" --expect-n "$U1_N" 2>&1); SRC=$?
{ [ "$SRC" = 0 ] && [ -n "$U1_N" ] && cmp -s "$T/shard.list" "$U1_LIST"; } && ok \
  || bad "U10: the shard (--expect-n $U1_N) plans U1's list and exits 0 (rc=$SRC) [$(printf '%s' "$SHARD_OUT" | tail -3)]"

# ── U11. another full answer inside the union keeps the corpus.
for stop in "infra change (bin/lib/suite-runner.sh)" "the selection came back empty"; do
  bplan "$C" zz-bh7290/y.sh -- CI_PLAN_IMPACT="$T/unk.sh" "UNK_STOP=$stop"
  full_is "U11 $stop" "unmapped: $C"
  has "ci-plan: member union: off (another full answer: $stop)" "$ERR" && ok || bad "U11 $stop: the off line [$ERR]"
done

# ── U12. the other off and error branches.
bplan "$C" -- CI_PLAN_IMPACT="$T/unk.sh" UNK_NOMAP=1
full_is "U12 map fails" "unmapped: $C"
has "ci-plan: member union: off (the map could not be built)" "$ERR" && ok || bad "U12: the map off line [$ERR]"
rm -f "$T/once"
bplan "$C" -- CI_PLAN_IMPACT="$T/unk.sh" UNK_ONCE="$T/once"
full_is "U12 not unmapped again" "unmapped: $C"
has "ci-plan: member union: off (the select did not answer unmapped again)" "$ERR" && ok || bad "U12: the not-again off line [$ERR]"
# a select that names a path the list does not hold would loop forever: rc 2
bplan "$C" -- CI_PLAN_IMPACT="$T/unk.sh" UNK_FIXED=zz-bh7290/not-in-the-list.sh
{ [ "$RC" = 2 ] && [ -z "$(out n)" ] && has "ci-plan: member union: select failed" "$ERR"; } && ok \
  || bad "U12: a path that does not leave the list is rc 2 (rc=$RC n=$(out n)) [$ERR]"
( . "$LIB" || exit 9; export CI_INFRA_CANARY_FILE="$T/canary"; mkdir -p "$T/u12"; cmr_union "$T/unk.sh" "$T/no-such-changed" "$T/u12/out" "$T/u12"; echo "rc=$? $CMR_WHY" ) > "$T/u12.out" 2>&1
[ "$(cat "$T/u12.out")" = "rc=1 the changed list could not be read" ] && ok \
  || bad "U12: an unreadable changed list is off (got $(cat "$T/u12.out"))"

echo "ci-member-reach-union.bh-7290: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
