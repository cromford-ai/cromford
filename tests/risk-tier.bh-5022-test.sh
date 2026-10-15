#!/bin/bash
# tests/risk-tier.bh-5022-test.sh — BH-5022 (BH-4973.1): the rules classifier,
# "$DIR/bin/lib/risk-tier.sh", sourced as it is (with the real
# "$DIR/bin/lib/lead-authority.sh" beside it) against fixture compare answers.
# setting_get is stubbed: rc 2 (no row) unless $T/set/<key> holds a value, or
# $T/set/<key>.rc1 exists (an outage). The protected-path rows come from the
# jobs worker (BH-4148): _jobs_req is tests/lib/lpp-stub.sh, rows in $LPPF.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/risk-tier.bh-5022-test.sh
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
# TEST-CHANGE BH-4148 (merge of main): globs come from the DB, not the TSV.
# The same two demo-os globs the fixture catalog held, as lead_protected_paths rows.
unset HARNESS H
LPPF="$T/lpp.json"; DOWNF="$T/lpp-down"
lpp_set "$LPPF" example-org/demo-os 'bin/guarded.sh' 'catalog/lanes.d/**'
_jobs_req() { lpp_jobs_req "$LPPF" "$DOWNF" "$@"; }
setting_get() {
  [ -e "$T/set/$1.rc1" ] && return 1
  [ -f "$T/set/$1" ] || return 2
  cat "$T/set/$1"
}

if [ -f "$DIR/bin/lib/risk-tier.sh" ]; then
  # shellcheck source=/dev/null
  . "$DIR/bin/lib/risk-tier.sh" && ok || bad "bin/lib/risk-tier.sh did not source"
else
  bad "bin/lib/risk-tier.sh does not exist"
fi
command -v rt_classify >/dev/null 2>&1 || { echo "risk-tier.bh-5022: PASS=$PASS FAIL=$((FAIL+1)) (rt_classify missing)"; exit 1; }

# cmpf <name> <json array of [filename, additions, deletions, previous_filename?, status?]>
# (status defaults to modified, or renamed with a previous_filename)
cmpf() {
  jq -nc --argjson f "$2" '{total_commits:1, commits:[], files:[$f[] | {filename:.[0], additions:.[1], deletions:.[2],
    status:(.[4] // (if (.[3] // null) == null then "modified" else "renamed" end))}
    + (if (.[3] // null) == null then {} else {previous_filename:.[3]} end)]}' > "$T/cmp/$1.json"
}
# cls <cmp> — sets TIER and WHY
cls() {
  local out
  out=$(rt_classify "$T/cmp/$1.json" example-org/demo-os); CRC=$?
  TIER=$(cut -f1 <<<"$out"); WHY=$(cut -f2 <<<"$out")
}
reset_set() { scratch_rm "$T/set"; mkdir -p "$T/set"; }

# A1: docs only -> low, the reasons mention docs
cmpf a1 '[["docs/a.md",8,2]]'; cls a1
[ "$TIER" = low ] && ok || bad "A1 docs only: '$TIER' ($WHY)"
case "$WHY" in *docs*) ok ;; *) bad "A1 reasons do not mention docs: $WHY" ;; esac
case "$WHY" in *"10 lines"*) ok ;; *) bad "A1 reasons do not count 10 lines: $WHY" ;; esac

# A2: console-ui screens + ui, 120 lines -> low
cmpf a2 '[["console-ui/src/screens/Jobs.js",80,20],["console-ui/src/ui/X.js",15,5]]'; cls a2
[ "$TIER" = low ] && ok || bad "A2 screens only: '$TIER' ($WHY)"

# A3: NO bin/ script is low in wave 1, however small, standalone or not
# (BH-5022 lead BLOCK: a 35-line patch to bin/test-tamper-scan.sh read low)
for b in bin/solo.sh bin/test-tamper-scan.sh bin/render-cron.sh bin/size-gate.sh bin/lib/solo.sh; do
  cmpf a3 "[[\"$b\",30,5]]"; cls a3
  [ "$TIER" = medium ] && ok || bad "A3 $b read '$TIER' ($WHY)"
done
cmpf a3b '[["bin/fresh.sh",3,0,null,"added"],["docs/fresh.md",3,0]]'; cls a3b
[ "$TIER" = medium ] && ok || bad "A3b a new bin script beside docs: '$TIER' ($WHY)"
# ...nor any path under the other control dirs
for b in worker/jobs/src/x.js catalog/x.json cron/x.cron checks/x.sh guardrails/x.sh fly/x.toml config/x.json \
         console-ui/src/api.js console-ui/src/lib/x.js; do
  cmpf a3c "[[\"$b\",3,0]]"; cls a3c
  [ "$TIER" != low ] && ok || bad "A3c $b read low ($WHY)"
done
# ...and a low_globs row can narrow low, never widen it past the ceiling
reset_set; printf 'docs/* bin/* worker/* catalog/*' > "$T/set/risk_tier.low_globs"
cmpf a3d '[["bin/solo.sh",3,0]]'; cls a3d
[ "$TIER" = medium ] && ok || bad "A3d a low_globs row made a bin script low: '$TIER' ($WHY)"
cmpf a3e '[["worker/jobs/src/x.js",3,0]]'; cls a3e
[ "$TIER" = medium ] && ok || bad "A3e a low_globs row made a worker path low: '$TIER' ($WHY)"
reset_set; printf '900' > "$T/set/risk_tier.low_lines"
cmpf a3f '[["docs/a.md",350,0]]'; cls a3f
[ "$TIER" = medium ] && ok || bad "A3f low_lines=900 lifted the 300-line cap: '$TIER' ($WHY)"
reset_set

# T: wave 1 (the operator, 10-07 04:23Z): only a NEW test file is low. Any edit to an
# existing test, even a purely additive one (an inserted `exit 0` is
# additive), and anything under tests/lib/ or another helper/fixture, is not.
cmpf t1 '[["tests/new-test.sh",40,0,null,"added"],["docs/a.md",2,0]]'; cls t1
[ "$TIER" = low ] && ok || bad "T1 a brand-new test file: '$TIER' ($WHY)"
cmpf t1b '[["tests/mc/new.bh-1-test.sh",10,0,null,"added"],["console-ui/tests/new.bh-1.test.js",10,0,null,"added"]]'; cls t1b
[ "$TIER" = low ] && ok || bad "T1b new tests/mc and console-ui test files: '$TIER' ($WHY)"
cmpf t2 '[["tests/old-test.sh",1,0,null,"modified"]]'; cls t2
[ "$TIER" = medium ] && ok || bad "T2 an existing suite with exit 0 inserted: '$TIER' ($WHY)"
case "$WHY" in *"tests/old-test.sh is an existing test file"*) ok ;; *) bad "T2 reason: $WHY" ;; esac
cmpf t2b '[["console-ui/tests/old.test.js",3,0,null,"modified"]]'; cls t2b
[ "$TIER" = medium ] && ok || bad "T2b an additive edit to an existing console test: '$TIER' ($WHY)"
cmpf t3 '[["tests/old-test.sh",12,1,null,"modified"]]'; cls t3
[ "$TIER" = medium ] && ok || bad "T3 one line deleted in an existing test: '$TIER' ($WHY)"
cmpf t4 '[["tests/old-test.sh",1,1,null,"modified"],["tests/new-test.sh",9,0,null,"added"]]'; cls t4
[ "$TIER" = medium ] && ok || bad "T4 one modified line beside a new test: '$TIER' ($WHY)"
cmpf t5 '[["tests/old-test.sh",0,40,null,"removed"]]'; cls t5
[ "$TIER" = medium ] && ok || bad "T5 a deleted test file: '$TIER' ($WHY)"
cmpf t6 '[["tests/moved-test.sh",0,0,"tests/old-test.sh"]]'; cls t6
[ "$TIER" = medium ] && ok || bad "T6 a renamed test file: '$TIER' ($WHY)"
cmpf t7 '[["tests/old-test.sh",3,0,null,"changed"]]'; cls t7
[ "$TIER" = medium ] && ok || bad "T7 a status that is not added: '$TIER' ($WHY)"
jq -nc '{total_commits:1, commits:[], files:[{filename:"tests/new-test.sh", additions:3, deletions:0}]}' > "$T/cmp/t8.json"; cls t8
[ "$TIER" = medium ] && ok || bad "T8 no status (unreadable) read low: '$TIER' ($WHY)"
# ...tests/lib/** and any shared helper or fixture is never low, new or not
cmpf t10 '[["tests/lib/scratch.sh",1,0,null,"modified"]]'; cls t10
[ "$TIER" = medium ] && ok || bad "T10 tests/lib/scratch.sh with one added line: '$TIER' ($WHY)"
for f in tests/lib/new-test.sh tests/lib/helper.sh tests/fixtures/x.json tests/br/new-test.sh console-ui/tests/helpers/x.test.js; do
  cmpf t11 "[[\"$f\",5,0,null,\"added\"]]"; cls t11
  [ "$TIER" = medium ] && ok || bad "T11 a new $f read '$TIER' ($WHY)"
done
# ...and prompts/ is not low in wave 1
cmpf t12 '[["prompts/build-discipline.md",2,0]]'; cls t12
[ "$TIER" = medium ] && ok || bad "T12 prompts/build-discipline.md: '$TIER' ($WHY)"
reset_set; printf 'docs/* prompts/*' > "$T/set/risk_tier.low_globs"; cls t12
[ "$TIER" = medium ] && ok || bad "T12 a low_globs row made prompts/ low: '$TIER' ($WHY)"
reset_set
# ...while docs may delete lines and still be low
cmpf t9 '[["docs/a.md",3,30]]'; cls t9
[ "$TIER" = low ] && ok || bad "T9 a docs deletion: '$TIER' ($WHY)"

# A5: a schema.sql line -> high, naming it
cmpf a5 '[["worker/jobs/schema.sql",1,0],["docs/x.md",1,0]]'; cls a5
[ "$TIER" = high ] && ok || bad "A5 schema.sql: '$TIER' ($WHY)"
case "$WHY" in *worker/jobs/schema.sql*) ok ;; *) bad "A5 reason does not name schema.sql: $WHY" ;; esac
# A6: .mergify.yml -> high
cmpf a6 '[[".mergify.yml",2,1]]'; cls a6
[ "$TIER" = high ] && ok || bad "A6 .mergify.yml: '$TIER' ($WHY)"
# ...a sensitive path, and a lead-protected catalog glob, are high too
cmpf a6b '[["bin/lib/env-path.sh",1,1]]'; cls a6b
[ "$TIER" = high ] && ok || bad "A6b an env-handling path: '$TIER' ($WHY)"
cmpf a6c '[["catalog/lanes.d/x.json",1,1]]'; cls a6c
[ "$TIER" = high ] && ok || bad "A6c a catalog-protected glob: '$TIER' ($WHY)"
cmpf a6d '[["bin/guarded.sh",1,1]]'; cls a6d
[ "$TIER" = high ] && ok || bad "A6d a catalog-protected standalone script: '$TIER' ($WHY)"

# A7: 700 lines in tests only -> medium, not high
cmpf a7 '[["tests/x-test.sh",700,0,null,"added"]]'; cls a7
[ "$TIER" = medium ] && ok || bad "A7 700 test lines: '$TIER' ($WHY)"
case "$WHY" in *"over low limit 300"*) ok ;; *) bad "A7 reason: $WHY" ;; esac
# ...while 700 lines of ordinary code is high, and 26 files is high
cmpf a7b '[["bin/lib/thing.sh",650,50]]'; cls a7b
[ "$TIER" = high ] && ok || bad "A7b 700 lines of code: '$TIER' ($WHY)"
F26=$(jq -nc '[range(26) | ["bin/lib/f\(.).sh",1,0]]'); cmpf a7c "$F26"; cls a7c
[ "$TIER" = high ] && ok || bad "A7c 26 files: '$TIER' ($WHY)"
cmpf a7d '[["bin/lib/thing.sh",50,50]]'; cls a7d
[ "$TIER" = medium ] && ok || bad "A7d an ordinary small change: '$TIER' ($WHY)"

# A8: a DB rule row overrides the fallback
reset_set; printf 'docs/*' > "$T/set/risk_tier.low_globs"; cls a2
[ "$TIER" = medium ] && ok || bad "A8 low_globs=docs/* still read screens as low: '$TIER' ($WHY)"
cls a1; [ "$TIER" = low ] && ok || bad "A8 docs stays low under the row: '$TIER'"
reset_set; printf '5' > "$T/set/risk_tier.low_lines"; cls a1
[ "$TIER" = medium ] && ok || bad "A8 low_lines=5 kept 10 lines low: '$TIER' ($WHY)"
reset_set; printf 'docs/a.md' > "$T/set/risk_tier.high_globs"; cls a1
[ "$TIER" = high ] && ok || bad "A8 a high_globs row did not bite: '$TIER' ($WHY)"
# ...a junk integer row is unreadable (capped), never a zero
reset_set; printf 'lots' > "$T/set/risk_tier.low_lines"; cls a1
[ "$TIER" = medium ] && ok || bad "A8 a junk low_lines row: '$TIER' ($WHY)"
# ...and no rule row can take a lead-protected glob out of high
reset_set; printf 'x' > "$T/set/risk_tier.high_globs"; printf 'x' > "$T/set/risk_tier.sensitive_globs"; printf 'bin/* catalog/*' > "$T/set/risk_tier.low_globs"; cls a6d
[ "$TIER" = high ] && ok || bad "A8 rows removed a catalog-protected path: '$TIER' ($WHY)"
reset_set

# A9: a rules read outage -> medium, never low
: > "$T/set/risk_tier.low_globs.rc1"; cls a1
[ "$TIER" = medium ] && ok || bad "A9 an outage left it '$TIER' ($WHY)"
case "$WHY" in *"rules unreadable"*) ok ;; *) bad "A9 reason: $WHY" ;; esac
reset_set
# ...and the protected-path list unreadable is medium too
printf '500' > "$DOWNF"; cls a1; rm -f "$DOWNF"
[ "$TIER" = medium ] && ok || bad "A9b no catalog left it '$TIER' ($WHY)"

# A10: a rename out of .mergify.yml -> high
cmpf a10 '[["docs/a.md",1,0,".mergify.yml"]]'; cls a10
[ "$TIER" = high ] && ok || bad "A10 previous_filename .mergify.yml: '$TIER' ($WHY)"

# A11: 300 compare files -> high, diff too large
F300=$(jq -nc '[range(300) | ["docs/f\(.).md",1,0]]'); cmpf a11 "$F300"; cls a11
[ "$TIER" = high ] && ok || bad "A11 300 files: '$TIER' ($WHY)"
case "$WHY" in *"diff too large"*) ok ;; *) bad "A11 reason: $WHY" ;; esac

# A13: a compare with no files[] is rc 2 and prints nothing; an empty diff is never low
echo '{"message":"boom"}' > "$T/cmp/a13.json"; cls a13
[ "$CRC" = 2 ] && [ -z "$TIER" ] && ok || bad "A13 unreadable compare: rc=$CRC tier='$TIER'"
cmpf a13b '[]'; cls a13b
[ "$TIER" = medium ] && ok || bad "A13 empty diff: '$TIER'"
# lines and files ride fields 3 and 4
OUT=$(rt_classify "$T/cmp/a2.json" example-org/demo-os)
[ "$(cut -f3,4 <<<"$OUT")" = "120	2" ] && ok || bad "A13 lines/files fields: $OUT"

# M: the mode row: per repo wins, global next, none = off, junk/outage = off with
# a why. Wave 1 honours it for example-org/cromford only.
BHR=example-org/cromford
reset_set; [ "$(rt_mode $BHR | cut -f1)" = off ] && ok || bad "M no row is not off"
printf 'shadow' > "$T/set/risk_tier.mode"; [ "$(rt_mode $BHR | cut -f1)" = shadow ] && ok || bad "M global row not read"
printf ' Enforce\n' > "$T/set/risk_tier.mode.example-org.cromford"; [ "$(rt_mode $BHR | cut -f1)" = enforce ] && ok || bad "M per-repo row does not win (or is not trimmed/lowercased)"
printf 'yes' > "$T/set/risk_tier.mode.example-org.cromford"; M=$(rt_mode $BHR)
[ "$(cut -f1 <<<"$M")" = off ] && [ -n "$(cut -f2 <<<"$M")" ] && ok || bad "M junk value: '$M'"
reset_set; : > "$T/set/risk_tier.mode.example-org.cromford.rc1"; M=$(rt_mode $BHR)
[ "$(cut -f1 <<<"$M")" = off ] && [ -n "$(cut -f2 <<<"$M")" ] && ok || bad "M outage: '$M'"
# ...any other repo stays off, whatever its own row or the global row says
reset_set; printf 'enforce' > "$T/set/risk_tier.mode.example-org.demo-os"; printf 'enforce' > "$T/set/risk_tier.mode"
M=$(rt_mode example-org/demo-os)
[ "$(cut -f1 <<<"$M")" = off ] && ok || bad "M a non-cromford repo read '$M'"
case "$(cut -f2 <<<"$M")" in *"wave 1"*) ok ;; *) bad "M off why for another repo: '$M'" ;; esac
reset_set

# S: RT_RULES_SIG moves with any rules row, and only with one
reset_set; rt_rules_load; S1=$RT_RULES_SIG; rt_rules_load
[ -n "$S1" ] && [ "$RT_RULES_SIG" = "$S1" ] && ok || bad "S the same rules gave two sigs: $S1 $RT_RULES_SIG"
printf 'docs/*' > "$T/set/risk_tier.low_globs"; rt_rules_load
[ "$RT_RULES_SIG" != "$S1" ] && ok || bad "S a low_globs row left the sig at $S1"
reset_set; printf '500' > "$T/set/risk_tier.high_lines"; rt_rules_load
[ "$RT_RULES_SIG" != "$S1" ] && ok || bad "S a high_lines row left the sig at $S1"
reset_set; RT_RULES_LOADED=""

echo "risk-tier.bh-5022: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
