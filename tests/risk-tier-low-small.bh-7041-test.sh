#!/bin/bash
# tests/risk-tier-low-small.bh-7041-test.sh — BH-7041: the low-small class in
# "$DIR/bin/lib/risk-tier.sh" (rt_rules_load's two rows, rt_low_small,
# rt_low_small_apply and the rt_low_rule `low-small` case), sourced
# as it is with the real "$DIR/bin/lib/lead-authority.sh" beside it, against
# fixture compare answers. setting_get is stubbed: rc 2 (no row) unless
# $T/set/<key> holds a value, or $T/set/<key>.rc1 exists (an outage). The
# protected-path rows come from tests/lib/lpp-stub.sh, rows in $LPPF.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/risk-tier-low-small.bh-7041-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/set" "$T/cmp" "$T/tmp"
export TMPDIR="$T/tmp"
unset HARNESS H
LPPF="$T/lpp.json"; DOWNF="$T/lpp-down"
lpp_set "$LPPF" example-org/demo-os 'bin/guarded.sh'
_jobs_req() { lpp_jobs_req "$LPPF" "$DOWNF" "$@"; }
setting_get() {
  [ -e "$T/set/$1.rc1" ] && return 1
  [ -f "$T/set/$1" ] || return 2
  cat "$T/set/$1"
}

# shellcheck source=/dev/null
. "$DIR/bin/lib/risk-tier.sh" && ok || bad "bin/lib/risk-tier.sh did not source"
command -v rt_classify >/dev/null 2>&1 || { echo "risk-tier-low-small.bh-7041: PASS=$PASS FAIL=$((FAIL+1)) (rt_classify missing)"; exit 1; }

# cmpo <name> <json array of {f, a, d, s?, pf?, p?}> — a compare answer with
# GitHub's field names (status defaults to modified, renamed with a pf).
cmpo() {
  jq -nc --argjson f "$2" '{total_commits:1, commits:[], files:[$f[] | {filename:.f, additions:.a, deletions:.d,
    status:(.s // (if .pf then "renamed" else "modified" end))}
    + (if .pf then {previous_filename:.pf} else {} end) + (if has("p") then {patch:.p} else {} end)]}' > "$T/cmp/$1.json"
}
reset_set() { scratch_rm "$T/set"; mkdir -p "$T/set"; RT_RULES_LOADED=""; }
cls() { rt_classify "$T/cmp/$1.json" example-org/demo-os | cut -f1; }
# ls1 <cmp> [tier] — runs rt_low_small on the tier rt_classify gives (or the
# one named): sets LS (yes|no|""), LWHY, LRC
ls1() {
  local out tier
  RT_RULES_LOADED=""; rt_rules_load
  tier="${2-$(cls "$1")}"
  out=$(rt_low_small "$T/cmp/$1.json" example-org/demo-os "$tier"); LRC=$?
  LS=$(cut -f1 <<<"$out"); LWHY=$(cut -f2 <<<"$out")
}
SPEC200='{"f":".harness/specs/BH-1/plan.md","a":200,"d":0,"s":"added"}'

command -v rt_low_small >/dev/null 2>&1 && ok || bad "rt_low_small is not defined"

# ── M: the two rows ──
reset_set; rt_rules_load
[ "${RT_LOW_SMALL_MODE:-}" = shadow ] && [ "${RT_LOW_SMALL_LINES:-}" = 250 ] && ok || bad "M1 no rows: mode '${RT_LOW_SMALL_MODE:-}' lines '${RT_LOW_SMALL_LINES:-}'"
SIG_SHADOW="$RT_RULES_SIG"
reset_set; printf 'enforce' > "$T/set/risk_tier.low_small_mode"; rt_rules_load
[ "${RT_LOW_SMALL_MODE:-}" = enforce ] && ok || bad "M2 enforce: '${RT_LOW_SMALL_MODE:-}'"
# M7: the sig moves with the mode, so a flip re-classifies cached heads
[ "$RT_RULES_SIG" != "$SIG_SHADOW" ] && ok || bad "M7 the rules sig did not change with the low-small mode"
SIG_ENF="$RT_RULES_SIG"
printf '100' > "$T/set/risk_tier.low_small_lines"; RT_RULES_LOADED=""; rt_rules_load
[ "$RT_RULES_SIG" != "$SIG_ENF" ] && ok || bad "M7 under enforce the sig did not change with the lines row"
# ...and with rule 2c on
reset_set; printf 25 > "$T/set/risk_tier.low_score_max"; rt_rules_load; S2C_SH="$RT_RULES_SIG"
printf 'enforce' > "$T/set/risk_tier.low_small_mode"; RT_RULES_LOADED=""; rt_rules_load
[ "$RT_RULES_SIG" != "$S2C_SH" ] && ok || bad "M7 with 2c on the sig did not change with the low-small mode"
# M8: shadow and off never change a cached tier, so they keep today's sig
# (tests/risk-tier-evidence.bh-6968-test.sh N10 pins it).
reset_set; printf 'off' > "$T/set/risk_tier.low_small_mode"; rt_rules_load
[ "$RT_RULES_SIG" = "$SIG_SHADOW" ] && ok || bad "M8 off and shadow gave two sigs: $RT_RULES_SIG $SIG_SHADOW"
reset_set; printf ' Enforce \n' > "$T/set/risk_tier.low_small_mode"; rt_rules_load
[ "${RT_LOW_SMALL_MODE:-}" = enforce ] && ok || bad "M3 ' Enforce ': '${RT_LOW_SMALL_MODE:-}'"
reset_set; printf 'off' > "$T/set/risk_tier.low_small_mode"; rt_rules_load
[ "${RT_LOW_SMALL_MODE:-}" = off ] && ok || bad "M3b off: '${RT_LOW_SMALL_MODE:-}'"
reset_set; printf 'bogus' > "$T/set/risk_tier.low_small_mode"; rt_rules_load
[ "${RT_LOW_SMALL_MODE:-}" = off ] && ok || bad "M4 bogus: '${RT_LOW_SMALL_MODE:-}'"
case "${RT_LOW_SMALL_WHY:-}" in *bogus*) ok ;; *) bad "M4 the why does not name the value: '${RT_LOW_SMALL_WHY:-}'" ;; esac
[ -z "${RT_RULES_UNREADABLE:-}" ] && ok || bad "M4 a bad low-small row marked the rules unreadable"
reset_set; printf '400' > "$T/set/risk_tier.low_small_lines"; rt_rules_load
[ "${RT_LOW_SMALL_LINES:-}" = 250 ] && [ "${RT_LOW_SMALL_MODE:-}" = shadow ] && ok || bad "M5 lines 400: '${RT_LOW_SMALL_LINES:-}' mode ${RT_LOW_SMALL_MODE:-}"
reset_set; printf '100' > "$T/set/risk_tier.low_small_lines"; rt_rules_load
[ "${RT_LOW_SMALL_LINES:-}" = 100 ] && ok || bad "M5 lines 100: '${RT_LOW_SMALL_LINES:-}'"
reset_set; printf 'abc' > "$T/set/risk_tier.low_small_lines"; rt_rules_load
[ "${RT_LOW_SMALL_MODE:-}" = off ] && [ -z "${RT_RULES_UNREADABLE:-}" ] && ok || bad "M5 lines abc: mode ${RT_LOW_SMALL_MODE:-} unreadable '${RT_RULES_UNREADABLE:-}'"
reset_set; : > "$T/set/risk_tier.low_small_mode.rc1"; rt_rules_load
[ "${RT_LOW_SMALL_MODE:-}" = off ] && [ -z "${RT_RULES_UNREADABLE:-}" ] && ok || bad "M6 mode rc 1: mode ${RT_LOW_SMALL_MODE:-} unreadable '${RT_RULES_UNREADABLE:-}'"
reset_set; : > "$T/set/risk_tier.low_small_lines.rc1"; rt_rules_load
[ "${RT_LOW_SMALL_MODE:-}" = off ] && [ -z "${RT_RULES_UNREADABLE:-}" ] && ok || bad "M6 lines rc 1: mode ${RT_LOW_SMALL_MODE:-}"
# ...and a bad low-small row never caps the wave-1 docs low
cmpo m6 '[{"f":"docs/a.md","a":5,"d":0}]'; [ "$(cls m6)" = low ] && ok || bad "M6 docs low lost to a bad low-small row"
reset_set

# ── L1: 180 code lines + a 200-line plan: medium today, low-small now ──
cmpo l1 "[{\"f\":\"bin/foo.sh\",\"a\":150,\"d\":30},$SPEC200]"
[ "$(cls l1)" = medium ] && ok || bad "L1 rt_classify read '$(cls l1)', not medium"
ls1 l1
[ "$LS" = yes ] && [ "$LRC" = 0 ] && ok || bad "L1 want yes rc 0, got '$LS' rc $LRC ($LWHY)"
case "$LWHY" in "180 code lines"*"spec lines 200 not counted"*) ok ;; *) bad "L1 the reason: $LWHY" ;; esac

# ── L2: 249 lines over 3 files yes; 250 no (the cap is exclusive) ──
cmpo l2 '[{"f":"bin/a.sh","a":100,"d":0},{"f":"bin/b.sh","a":100,"d":0},{"f":"bin/c.sh","a":40,"d":9}]'; ls1 l2
[ "$LS" = yes ] && ok || bad "L2 249 lines: '$LS' ($LWHY)"
cmpo l2b '[{"f":"bin/a.sh","a":100,"d":0},{"f":"bin/b.sh","a":100,"d":0},{"f":"bin/c.sh","a":40,"d":10}]'; ls1 l2b
[ "$LS" = no ] && [ "$LRC" = 1 ] && ok || bad "L2 250 lines: '$LS' rc $LRC ($LWHY)"
case "$LWHY" in *250*) ok ;; *) bad "L2 the no reason does not name the count: $LWHY" ;; esac

# ── L3: a lines row of 100 and 120 code lines -> no ──
printf '100' > "$T/set/risk_tier.low_small_lines"
cmpo l3 '[{"f":"bin/a.sh","a":120,"d":0}]'; ls1 l3
[ "$LS" = no ] && ok || bad "L3 row 100, 120 lines: '$LS' ($LWHY)"
reset_set

# ── L4-L6: an existing test that loses an assertion or gains a skip ──
cmpo l4 '[{"f":"bin/a.sh","a":10,"d":0},{"f":"tests/a-test.sh","a":0,"d":1,"p":"@@ -1,2 +1,1 @@\n x=1\n-ok \"x\""}]'; ls1 l4
[ "$LS" = no ] && ok || bad "L4 a dropped ok line: '$LS' ($LWHY)"
for pl in '-  assert_eq 1 1' '-expect(x).toBe(1)' '-echo FAIL: x' '-[ 1 ] || bad "x"' \
  '-eq "L1 tier" "$T1" medium' '-check "x" "$a" "b"' '-  want "x" "$a"' '-same "$a" "$b"' \
  '-  fail "x"' '-  pass "x"' '-[ "$a" = b ] && ok'; do
  cmpo l4b "$(jq -nc --arg p "@@ -1 +0,0 @@
$pl" '[{f:"tests/a-test.sh",a:0,d:1,p:$p}]')"; ls1 l4b
  [ "$LS" = no ] && ok || bad "L4 a dropped '$pl': '$LS' ($LWHY)"
done
cmpo l4c "$(jq -nc --arg p '@@ -1 +1 @@
-eq "x" "$a" medium
+eq "x" "$a" low' '[{f:"tests/a-test.sh",a:1,d:1,p:$p}]')"; ls1 l4c
[ "$LS" = no ] && ok || bad "L4 a flipped eq expected value: '$LS' ($LWHY)"
cmpo l4d "$(jq -nc --arg p '@@ -1,2 +1,3 @@
 x=1
-# old comment about equality
+# new comment
+y=2' '[{f:"tests/a-test.sh",a:2,d:1,p:$p}]')"; ls1 l4d
[ "$LS" = yes ] && ok || bad "L4 a reworded comment is no assertion: '$LS' ($LWHY)"
cmpo l5 '[{"f":"tests/a-test.sh","a":1,"d":0,"p":"@@ -1 +1,2 @@\n x=1\n+exit 0"}]'; ls1 l5
[ "$LS" = no ] && ok || bad "L5 an added exit 0: '$LS' ($LWHY)"
cmpo l6 '[{"f":"tests/a-test.sh","a":1,"d":0,"p":"@@ -1 +1,2 @@\n x=1\n+  skip \"slow\""}]'; ls1 l6
[ "$LS" = no ] && ok || bad "L6 an added skip: '$LS' ($LWHY)"
cmpo l6b '[{"f":"console-ui/tests/a.test.js","a":1,"d":0,"p":"@@ -1 +1,2 @@\n x\n+test.SKIP(1)"}]'; ls1 l6b
[ "$LS" = no ] && ok || bad "L6 an added SKIP (any case): '$LS' ($LWHY)"

# ── L7: a removed or renamed test -> no ──
cmpo l7 '[{"f":"tests/a-test.sh","a":0,"d":10,"s":"removed","p":"@@ -1,10 +0,0 @@\n-x"}]'; ls1 l7
[ "$LS" = no ] && ok || bad "L7 a removed test: '$LS' ($LWHY)"
cmpo l7b '[{"f":"tests/b-test.sh","a":0,"d":0,"pf":"tests/a-test.sh"}]'; ls1 l7b
[ "$LS" = no ] && ok || bad "L7 a renamed test: '$LS' ($LWHY)"

# ── L8: a modified test helper -> no ──
cmpo l8 '[{"f":"tests/lib/scratch.sh","a":2,"d":0,"p":"@@ -1 +1,3 @@\n x\n+y\n+z"}]'; ls1 l8
[ "$LS" = no ] && ok || bad "L8 tests/lib/scratch.sh: '$LS' ($LWHY)"
cmpo l8b '[{"f":"worker/jobs/test/fixtures/a.json","a":2,"d":0,"p":"@@ -1 +1,3 @@\n x\n+y\n+z"}]'; ls1 l8b
[ "$LS" = no ] && ok || bad "L8 a worker test fixture: '$LS' ($LWHY)"

# ── L9: the floor holds when the high_globs row is narrowed ──
printf 'bin/merge-*' > "$T/set/risk_tier.high_globs"
cmpo l9 '[{"f":".github/workflows/x.yml","a":3,"d":0}]'
ls1 l9
[ "$LS" = no ] && ok || bad "L9 .github with a narrowed row: '$LS' ($LWHY)"
case "$LWHY" in *".github/workflows/x.yml"*) ok ;; *) bad "L9 the reason does not name the path: $LWHY" ;; esac

# ── L10: each floor path (the narrowed row still in force) -> no ──
for p in catalog/lanes.d/x.json bin/lib/lead-authority.sh bin/lead-review.sh bin/lib/risk-tier.sh \
         worker/jobs/schema.d/x.sql worker/jobs/schema.sql .mergify.yml rules/topics/05-x.md cron/hub.cron; do
  cmpo l10 "[{\"f\":\"$p\",\"a\":3,\"d\":0}]"; ls1 l10
  [ "$LS" = no ] && ok || bad "L10 $p: '$LS' ($LWHY)"
done
# ...a rename AWAY from a floor path is a floor path too
cmpo l10b '[{"f":"bin/x.sh","a":0,"d":0,"pf":"cron/hub.cron"}]'; ls1 l10b
[ "$LS" = no ] && ok || bad "L10 a rename off cron/: '$LS' ($LWHY)"
reset_set

# ── L11: a protected-path row -> no ──
cmpo l11 '[{"f":"bin/guarded.sh","a":3,"d":0}]'
printf 'bin/merge-*' > "$T/set/risk_tier.high_globs"; ls1 l11
[ "$LS" = no ] && ok || bad "L11 a lead protected path: '$LS' ($LWHY)"
reset_set

# ── L12: the protected paths can not be read -> no ──
# TEST-CHANGE BH-6695: with no cache file, an outage holds only a repo with a
# seed line; a repo with no seed line is not governed. A scratch root whose seed
# file names demo-os keeps this case about an unreadable governed repo.
HARNESS="$T/gov"; mkdir -p "$HARNESS/catalog"; printf 'example-org/demo-os\tbin/guarded.sh\n' > "$HARNESS/catalog/lead-protected-paths.seed.tsv"
printf '500' > "$DOWNF"; ls1 l1; rm -f "$DOWNF"; unset HARNESS
[ "$LS" = no ] && ok || bad "L12 la_globs down: '$LS' ($LWHY)"
case "$LWHY" in *unreadable*) ok ;; *) bad "L12 the reason: $LWHY" ;; esac

# ── L13: a rules row could not be read -> no ──
: > "$T/set/risk_tier.high_lines.rc1"; ls1 l1
[ "$LS" = no ] && ok || bad "L13 a rules row rc 1: '$LS' ($LWHY)"
reset_set

# ── L14: a spec-only diff is 0 own lines -> no ──
cmpo l14 "[$SPEC200]"; ls1 l14
[ "$LS" = no ] && ok || bad "L14 spec only: '$LS' ($LWHY)"
# ...and a rename of code into the spec dir (a hidden delete) is never low-small
cmpo l14b '[{"f":".harness/specs/BH-1/x.sh","a":0,"d":0,"pf":"bin/plain.sh"},{"f":"bin/a.sh","a":5,"d":0}]'; ls1 l14b
[ "$LS" = no ] && ok || bad "L14 a rename into the spec dir: '$LS' ($LWHY)"

# ── L15: a modified test with no patch -> no ──
cmpo l15 '[{"f":"tests/a-test.sh","a":3,"d":0}]'; ls1 l15
[ "$LS" = no ] && ok || bad "L15 a test with no patch: '$LS' ($LWHY)"
case "$LWHY" in *"patch not readable"*) ok ;; *) bad "L15 the reason: $LWHY" ;; esac

# ── L16: a modified test that only adds ok lines -> yes; and low-small is no rules-text low ──
cmpo l16 '[{"f":"tests/a-test.sh","a":2,"d":0,"p":"@@ -1 +1,3 @@\n x=1\n+ok \"y\"\n+[ 1 ] && ok"},{"f":"bin/a.sh","a":10,"d":2}]'; ls1 l16
[ "$LS" = yes ] && ok || bad "L16 an additive test edit: '$LS' ($LWHY)"
# ...a NEW test file is never patch-checked
cmpo l16b '[{"f":"tests/new-test.sh","a":40,"d":0,"s":"added"},{"f":"bin/foo.sh","a":100,"d":0}]'; ls1 l16b
[ "$LS" = yes ] && ok || bad "L16 a new test + 100 code lines: '$LS' ($LWHY)"
# ── L16b: a tier that is not medium is never low-small, whatever the diff ──
for t in high low ""; do
  ls1 l1 "$t"
  [ "$LS" = no ] && [ "$LRC" = 1 ] && ok || bad "L16b tier '$t': '$LS' rc $LRC ($LWHY)"
done
# ── L17: low-small is no rules-text low ──
rt_rules_low low "low-small: x" && bad "L17 rt_rules_low read a low-small reason as rules text" || ok

# ── unreadable files[] -> rc 2, nothing printed; a high head -> no ──
printf '{"files":"x"}' > "$T/cmp/u.json"
OUT=$(rt_low_small "$T/cmp/u.json" example-org/demo-os medium); URC=$?
[ "$URC" = 2 ] && [ -z "$OUT" ] && ok || bad "an unreadable files[]: rc $URC '$OUT'"
cmpo hi '[{"f":"bin/a.sh","a":700,"d":0}]'; ls1 hi
[ "$LS" = no ] && ok || bad "a high head: '$LS' ($LWHY)"
# ...a head high only by a lowered high_lines row is not medium, so never low-small
printf '100' > "$T/set/risk_tier.high_lines"
cmpo hi2 '[{"f":"bin/a.sh","a":150,"d":0}]'; ls1 hi2
[ "$LS" = no ] && ok || bad "a head over a high_lines row of 100: '$LS' ($LWHY)"
case "$LWHY" in "risk tier high, not medium") ok ;; *) bad "the high head's reason: $LWHY" ;; esac
reset_set
cmpo nonum '[{"f":"bin/a.sh","a":null,"d":0}]'; ls1 nonum
[ "$LS" = no ] && ok || bad "an absent additions count: '$LS' ($LWHY)"

# ── A: rt_low_small_apply <cmp> <slug> <tier> <why> -> tier, why, log line ──
# ap <cmp> <tier> <why> — sets AT AW AL from one apply call under RT_LOW_SMALL_MODE.
ap() { AT=""; AW=""; AL=""; IFS=$'\t' read -r AT AW AL < <(rt_low_small_apply "$T/cmp/$1.json" example-org/demo-os "$2" "$3"); }
command -v rt_low_small_apply >/dev/null 2>&1 && ok || bad "rt_low_small_apply is not defined"
# A counter on rt_low_small, for A5 (the apply runs it in a subshell).
if declare -f rt_low_small >/dev/null 2>&1; then
  eval "_orig_$(declare -f rt_low_small)"
  rt_low_small() { echo x >> "$T/lscalls"; _orig_rt_low_small "$@"; }
fi
lscalls() { [ -f "$T/lscalls" ] && wc -l < "$T/lscalls" | tr -d ' ' || echo 0; }
reset_set; printf 'enforce' > "$T/set/risk_tier.low_small_mode"; rt_rules_load
ap l1 medium "1 path(s) outside the low globs, e.g. bin/foo.sh"
[ "$AT" = low ] && ok || bad "A1 enforce + yes: tier '$AT' ($AW)"
case "$AW" in "low-small: 180 code lines, 2 files (spec lines 200 not counted)") ok ;; *) bad "A1 the why: '$AW'" ;; esac
[ -z "$AL" ] && ok || bad "A1 enforce logged: '$AL'"
reset_set; rt_rules_load
ap l1 medium "1 path(s) outside the low globs, e.g. bin/foo.sh"
[ "$AT" = medium ] && [ "$AW" = "1 path(s) outside the low globs, e.g. bin/foo.sh" ] && ok || bad "A2 shadow + yes: '$AT' '$AW'"
case "$AL" in "risk-tier WOULD sign off (low-small: 180 code lines, 2 files (spec lines 200 not counted)); shadow, so the lead review is requested as before") ok ;; *) bad "A2 the WOULD line: '$AL'" ;; esac
ap l4 medium "m"
[ "$AT" = medium ] && [ "$AW" = m ] && ok || bad "A3 shadow + no: '$AT' '$AW'"
case "$AL" in "low-small no (tests/a-test.sh loses an assertion line); medium") ok ;; *) bad "A3 the no line: '$AL'" ;; esac
printf 'enforce' > "$T/set/risk_tier.low_small_mode"; RT_RULES_LOADED=""; rt_rules_load
ap l4 medium "m"
[ "$AT" = medium ] && [ "$AW" = m ] && case "$AL" in "low-small no ("*) true ;; *) false ;; esac && ok || bad "A3 enforce + no: '$AT' '$AW' '$AL'"
ap hi high "700 lines, over 600"
[ "$AT" = high ] && [ "$AW" = "700 lines, over 600" ] && [ -z "$AL" ] && ok || bad "A4 high under enforce: '$AT' '$AW' '$AL'"
ap m6 low "docs, screens or new tests only, 5 lines"
[ "$AT" = low ] && [ "$AW" = "docs, screens or new tests only, 5 lines" ] && [ -z "$AL" ] && ok || bad "A4 a wave-1 low under enforce: '$AT' '$AW' '$AL'"
rm -f "$T/lscalls"
reset_set; printf 'off' > "$T/set/risk_tier.low_small_mode"; rt_rules_load
ap l1 medium "m"
[ "$AT" = medium ] && [ "$AW" = m ] && [ -z "$AL" ] && ok || bad "A5 mode off: '$AT' '$AW' '$AL'"
reset_set; printf 'bogus' > "$T/set/risk_tier.low_small_mode"; rt_rules_load
ap l1 medium "m"
[ "$AT" = medium ] && [ "$AW" = m ] && [ -z "$AL" ] && ok || bad "A5 a bad mode row: '$AT' '$AW' '$AL'"
[ "$(lscalls)" = 0 ] && ok || bad "A5 rt_low_small ran $(lscalls) time(s) with low-small off"
reset_set; printf 'enforce' > "$T/set/risk_tier.low_small_mode"; rt_rules_load
ap l1 medium "m"; [ "$(lscalls)" = 1 ] && ok || bad "A5 the counter did not see the enforce call ($(lscalls))"
ap l1 unclassified "compare files unreadable"
[ "$AT" = unclassified ] && [ "$AW" = "compare files unreadable" ] && [ -z "$AL" ] && ok || bad "A6 unclassified: '$AT' '$AW' '$AL'"
reset_set
# A7: risk.tsv column 8 names the low-small rule
[ "$(rt_low_rule low "low-small: x")" = low-small ] && ok || bad "A7 rt_low_rule low low-small: '$(rt_low_rule low "low-small: x")'"
[ "$(rt_low_rule withheld "low-small: x")" = low-small ] && ok || bad "A7 rt_low_rule withheld low-small: '$(rt_low_rule withheld "low-small: x")'"
[ "$(rt_low_rule low "evidence: x")" = evidence ] && ok || bad "A7 rt_low_rule evidence: '$(rt_low_rule low "evidence: x")'"
[ "$(rt_low_rule low "docs, screens or new tests only, 5 lines")" = path ] && ok || bad "A7 rt_low_rule path"
[ "$(rt_low_rule medium "low-small: x")" = - ] && ok || bad "A7 rt_low_rule medium: '$(rt_low_rule medium "low-small: x")'"

echo "risk-tier-low-small.bh-7041: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
