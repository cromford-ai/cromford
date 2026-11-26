#!/bin/bash
# tests/plan-verify-budget.bh-9779-test.sh — BH-9779: a plan's `## Verify` list
# has a budget (bin/lib/plan-verify-budget.sh), bin/plan-gate.sh refuses a list
# over it, the plan gate's one repair pass gets a paragraph that says how to
# fix it, and the execute prompt says to run one suite per command.
#
#   V1  the BH-7921 Verify section (verbatim fixture): over, with loop and
#       main-runs on the grep line, no-timeout on the "run both" line and
#       slow-suite naming docs-guide-pages (488 s)
#   V2  five named suites, no loop: ok
#   V3  each loop form refuses; a glob outside tests/, a negation, a helper pass
#   V4  no-timeout forms refuse; "passed its 600 s timeout" and a negation pass
#   V5  30 suites pass, 31 refuse; one suite named twice, or with and without
#       -test.sh, counts once
#   V6  3 main-run suites pass, 4 refuse
#   V7  300 s passes, 301 s refuses; no durations file: unread, rc 0
#   V8  no Verify section: n/a; a fenced loop in another section is not read
#   V9  the BH-7921 named list alone passes suite-count at 30 (prints the count)
#   V10 bin/plan-gate.sh (the production entry point): rc 2 and the verify lines
#   V11 the real `# >>> plan gate` block of bin/lib/rb/plan.sh with a stub CC:
#       the repair prompt carries the paragraph; the repaired plan passes and
#       still names the three target suites; mutation: no call, no paragraph
#   V12 knob rows in the settings cache change the limits and turn it off
#   V13 the execute prompt (rendered by sp_render) has the three phrases
#   K1  the registry defaults equal the lib fallbacks
# No network, no model call: CC is a stub. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/plan-verify-budget.bh-9779-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
unset PROJECT KEY BUILD PLAN_VERIFY_BUDGET PLAN_VERIFY_MAX_SUITES PLAN_VERIFY_MAX_MAIN_SUITES PLAN_VERIFY_SLOW_SUITE_S PLAN_VERIFY_DURATIONS
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
FX="$DIR/tests/fixtures/bh-9779"
NOW=1794900000

H="$T/h"; mkdir -p "$H/state" "$H/logs"
scratch_install_closure bin/plan-gate.sh "$H" >/dev/null || { echo "FAIL: setup: closure install"; exit 1; }
LIB="$H/bin/lib/plan-verify-budget.sh"
[ -r "$LIB" ] && ok || { bad "setup: bin/lib/plan-verify-budget.sh is not in the plan-gate closure"; LIB="$DIR/bin/lib/plan-verify-budget.sh"; }
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" > "$T/lanes.json" 2> "$T/lanes.err" \
  && [ -s "$T/lanes.json" ] && ok || bad "setup: could not compose the lanes registry: $(head -3 "$T/lanes.err")"
export LANE_REGISTRY="$T/lanes.json" LANE_GATE_NOW="$NOW"
settings() { printf '{"fetched_at":%s,"values":%s,"seeded":{}}\n' "$NOW" "$1" > "$H/state/settings-cache.json"; }
settings '{}'

# chk <plan> [env...] — pvb_plan_check in a clean shell; sets OUT and RC.
chk() {
  local p="$1"; shift
  OUT=$(env HARNESS="$H" "$@" bash -c '. "$0" || exit 9; pvb_plan_check "$1"' "$LIB" "$p" 2>&1); RC=$?
}
# vp <body> — a plan with a Verify section holding <body> (printf %b).
vp() { printf '# p\n\n## Verify (run, not edited)\n\n%b\n\n## Tasks\n\n### T1. x\n- VALIDATE: x\n- SATISFIES: x\n' "$1" > "$T/vp.md"; echo "$T/vp.md"; }
hits() { grep -c '^  UNTRACED: verify budget — ' <<<"$OUT"; }
D="$FX/durations.tsv"

# ── V1 ───────────────────────────────────────────────────────────────────────
chk "$FX/bh7921-plan.md" PLAN_VERIFY_DURATIONS="$D"
GL=$(grep -n "grep -l 'rb-all.sh" "$FX/bh7921-plan.md" | cut -d: -f1)
NL=$(grep -n 'The build must run both with no timeout' "$FX/bh7921-plan.md" | cut -d: -f1)
[ "$RC" = 2 ] && grep -qx 'PLAN_VERIFY_BUDGET: over' <<<"$OUT" && ok || bad "V1 the BH-7921 fixture is over, rc 2 (rc $RC): $OUT"
grep -q "^  UNTRACED: verify budget — line $GL: loop: .*grep -l 'rb-all.sh" <<<"$OUT" && ok || bad "V1 loop on line $GL (the grep loop): $OUT"
grep -q "^  UNTRACED: verify budget — line $GL: main-runs: " <<<"$OUT" && ok || bad "V1 main-runs on line $GL: $OUT"
grep -q "^  UNTRACED: verify budget — line $NL: no-timeout: The build must run both with no timeout" <<<"$OUT" && ok || bad "V1 no-timeout on line $NL: $OUT"
grep -q "^  UNTRACED: verify budget — line [0-9]*: slow-suite: tests/docs-guide-pages.bh-6507 recorded 488 s, over the limit of 300 s" <<<"$OUT" && ok \
  || bad "V1 slow-suite names docs-guide-pages at 488 s: $OUT"
[ -n "$GL" ] && [ -n "$NL" ] && ok || bad "V1 setup: the fixture lines are missing"

# ── V2 ───────────────────────────────────────────────────────────────────────
chk "$FX/five-suites-plan.md" PLAN_VERIFY_DURATIONS="$D"
[ "$RC" = 0 ] && grep -qx 'PLAN_VERIFY_BUDGET: ok' <<<"$OUT" && grep -qx 'PLAN_VERIFY_SUITES: 5' <<<"$OUT" && [ "$(hits)" = 0 ] && ok \
  || bad "V2 five named suites and no loop pass (rc $RC): $OUT"

# ── V3 loop ──────────────────────────────────────────────────────────────────
for l in 'for t in tests/*.sh tests/mc/*.sh; do bash "$t" || exit 1; done' \
         "find tests -name '*.sh' | xargs -n1 bash" \
         'for t in $(ls tests/); do bash "tests/$t"; done' \
         "grep -l rb_all tests/ | while read t; do bash \"\$t\"; done" \
         'bash tests/mc/*.sh'; do
  chk "$(vp "- \`$l\`")"
  [ "$RC" = 2 ] && grep -q ': loop: ' <<<"$OUT" && ok || bad "V3 the loop '$l' refuses (rc $RC): $OUT"
done
for l in '`bash -n bin/*.sh`' 'never run tests/*.sh in a loop' 'Do not run `for t in tests/*.sh`.' '`tests/lib/scratch.sh` is a helper.'; do
  chk "$(vp "- $l")"
  [ "$RC" = 0 ] && ! grep -q ': loop: ' <<<"$OUT" && ok || bad "V3 '$l' passes (rc $RC): $OUT"
done
chk "$(vp '- `tests/lib/scratch.sh` and `tests/fixtures/x/a.sh`')"
grep -qx 'PLAN_VERIFY_SUITES: 0' <<<"$OUT" && ok || bad "V3 tests/lib and tests/fixtures are not suites: $OUT"

# ── V4 no-timeout ────────────────────────────────────────────────────────────
for l in 'Run it with no timeout.' 'Run tests/a.sh without a timeout.' 'bash tests/a.sh --timeout=0' 'run it with timeout 0 here'; do
  chk "$(vp "- $l")"
  [ "$RC" = 2 ] && grep -q ': no-timeout: ' <<<"$OUT" && ok || bad "V4 '$l' refuses (rc $RC): $OUT"
done
for l in '`tests/a.sh` passed its 600 s timeout at plan time.' 'Do not run with no timeout.' 'run tests/a.sh with timeout 600'; do
  chk "$(vp "- $l")"
  [ "$RC" = 0 ] && ok || bad "V4 '$l' passes (rc $RC): $OUT"
done

# ── V5 suite-count ───────────────────────────────────────────────────────────
b30=""; for i in $(seq 1 30); do b30+="- \`bash tests/s$i-test.sh\`\n"; done
chk "$(vp "$b30")"
[ "$RC" = 0 ] && grep -qx 'PLAN_VERIFY_SUITES: 30' <<<"$OUT" && ok || bad "V5 30 suites pass (rc $RC): $OUT"
chk "$(vp "${b30}- \`bash tests/s31-test.sh\`\n")"
[ "$RC" = 2 ] && grep -q ': suite-count: 31 distinct suites named, over the limit of 30' <<<"$OUT" && ok || bad "V5 31 suites refuse (rc $RC): $OUT"
chk "$(vp "${b30}- \`bash tests/s1-test.sh\` again, and \`tests/s2\`\n")"
[ "$RC" = 0 ] && grep -qx 'PLAN_VERIFY_SUITES: 30' <<<"$OUT" && ok || bad "V5 a suite named twice, and with no -test.sh, counts once (rc $RC): $OUT"

# ── V6 main-runs ─────────────────────────────────────────────────────────────
chk "$(vp '- Run `tests/a.sh`, `tests/b.sh` and `tests/c.sh` on the head and on main.')"
[ "$RC" = 0 ] && ok || bad "V6 3 main-run suites pass (rc $RC): $OUT"
chk "$(vp '- Run `tests/a.sh`, `tests/b.sh` and `tests/c.sh` on the head and on main.\n- Also run `tests/d.sh` on main to compare.')"
[ "$RC" = 2 ] && [ "$(grep -c ': main-runs: 4 suites to run on main, over the limit of 3' <<<"$OUT")" = 2 ] && ok \
  || bad "V6 4 main-run suites refuse, one hit per line (rc $RC): $OUT"
chk "$(vp '- Do not run `tests/a.sh` `tests/b.sh` `tests/c.sh` `tests/d.sh` on main.')"
[ "$RC" = 0 ] && ok || bad "V6 a negated main run passes (rc $RC): $OUT"

# ── V7 slow-suite ────────────────────────────────────────────────────────────
printf 'tests/a.sh\t300\ntests/b-test.sh\t301\n' > "$T/d.tsv"
chk "$(vp '- `bash tests/a.sh`')" PLAN_VERIFY_DURATIONS="$T/d.tsv"
[ "$RC" = 0 ] && grep -qx "PLAN_VERIFY_DURATIONS: $T/d.tsv" <<<"$OUT" && ok || bad "V7 300 s passes (rc $RC): $OUT"
chk "$(vp '- `bash tests/b.sh`')" PLAN_VERIFY_DURATIONS="$T/d.tsv"
[ "$RC" = 2 ] && grep -q ': slow-suite: tests/b recorded 301 s, over the limit of 300 s' <<<"$OUT" && ok || bad "V7 301 s refuses (rc $RC): $OUT"
chk "$(vp '- `bash tests/b.sh`')" PLAN_VERIFY_DURATIONS="$T/none.tsv"
[ "$RC" = 0 ] && grep -qx 'PLAN_VERIFY_DURATIONS: unread' <<<"$OUT" && ! grep -q slow-suite <<<"$OUT" && ok \
  || bad "V7 no durations file: unread and rc 0 (rc $RC): $OUT"
mkdir -p "$H/state/ci-durations"; printf '# source: fixture\ntests/b.sh\t900\n' > "$H/state/ci-durations/api.tsv"
chk "$(vp '- `bash tests/b.sh`')"
[ "$RC" = 2 ] && grep -qx "PLAN_VERIFY_DURATIONS: $H/state/ci-durations/api.tsv" <<<"$OUT" && ok || bad "V7 the root's CI durations cache is read (rc $RC): $OUT"
rm -f "$H/state/ci-durations/api.tsv"

# ── V8 ───────────────────────────────────────────────────────────────────────
printf '# p\n\n## Tasks\n\n```\nfor t in tests/*.sh; do bash "$t"; done\n```\n\n## Verification checklist\n\n- tests/*.sh\n' > "$T/nov.md"
chk "$T/nov.md"
[ "$RC" = 0 ] && [ "$OUT" = 'PLAN_VERIFY_BUDGET: n/a' ] && ok || bad "V8 no Verify section is n/a (rc $RC): $OUT"
printf '# p\n\n## Verify\n\n- `bash tests/a.sh`\n\n## Notes\n\n```\nfor t in tests/*.sh; do bash "$t"; done\n```\n' > "$T/fence.md"
chk "$T/fence.md"
[ "$RC" = 0 ] && ok || bad "V8 a fenced loop in another section is not read (rc $RC): $OUT"
printf '# p\n\n## Verify\n\n```bash\nfor t in tests/*.sh; do bash "$t"; done\n```\n' > "$T/fence2.md"
chk "$T/fence2.md"
[ "$RC" = 2 ] && ok || bad "V8 a fenced loop inside Verify is read (rc $RC): $OUT"

# ── V9 the BH-7921 named list alone ─────────────────────────────────────────
grep -v "grep -l 'rb-all.sh\|no timeout\|RED ON MAIN\|red ON MAIN" "$FX/bh7921-plan.md" > "$T/named.md"
chk "$T/named.md"
N9=$(sed -n 's/^PLAN_VERIFY_SUITES: //p' <<<"$OUT")
[ "$RC" = 0 ] && [ "${N9:-0}" -ge 15 ] && [ "$N9" -le 30 ] && ok || bad "V9 the BH-7921 named list passes at 30 (rc $RC): $OUT"
echo "V9 measured: the BH-7921 Verify list names ${N9:-?} distinct suites (the limit is 30)"

# ── V10 bin/plan-gate.sh ─────────────────────────────────────────────────────
PG_OUT=$(HARNESS="$H" PLAN_VERIFY_DURATIONS="$D" "$H/bin/plan-gate.sh" "$FX/bh7921-plan.md" 2>&1); PG_RC=$?
[ "$PG_RC" = 2 ] && grep -qx 'PLAN_TRACE: untraced' <<<"$PG_OUT" && grep -q "^  UNTRACED: verify budget — line $GL: loop: " <<<"$PG_OUT" \
  && ok || bad "V10 plan-gate.sh refuses the BH-7921 fixture with the verify lines (rc $PG_RC): $PG_OUT"
# The refusal is the verify budget's: with it off, the same gate passes.
PG_OFF=$(HARNESS="$H" PLAN_VERIFY_BUDGET=0 "$H/bin/plan-gate.sh" "$FX/bh7921-plan.md" 2>&1); PG_OFF_RC=$?
[ "$PG_OFF_RC" = 0 ] && grep -qx 'PLAN_VERIFY_BUDGET: off' <<<"$PG_OFF" && ok || bad "V10 with the budget off the same plan passes (rc $PG_OFF_RC): $PG_OFF"
[ "$(tail -n 1 <<<"$PG_OUT")" = 'PLAN_TRACE: untraced' ] && ok || bad "V10 PLAN_TRACE stays the last line: $PG_OUT"
PG_OUT=$(HARNESS="$H" "$H/bin/plan-gate.sh" "$FX/five-suites-plan.md" 2>&1); PG_RC=$?
! grep -q 'verify budget' <<<"$PG_OUT" && grep -qx 'PLAN_VERIFY_BUDGET: ok' <<<"$PG_OUT" && ok || bad "V10 the five-suite plan adds no verify line: $PG_OUT"
PG_OUT=$(HARNESS="$H" "$H/bin/plan-gate.sh" "$FX/bh7921-plan-repaired.md" 2>&1); PG_RC=$?
[ "$PG_RC" = 0 ] && grep -qx 'PLAN_TRACE: ok' <<<"$PG_OUT" && ok || bad "V10 the repaired fixture passes the whole gate (rc $PG_RC): $PG_OUT"

# ── V11 the plan gate block of bin/lib/rb/plan.sh ────────────────────────────
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> plan gate$/{f=1;next} /^# <<< plan gate$/{exit} f' "$RB_ALL" > "$T/pgblock.sh"
[ -s "$T/pgblock.sh" ] && grep -q 'pvb_repair_note' "$T/pgblock.sh" && ok || bad "V11 setup: the plan gate block carries the pvb_repair_note call"
sed 's/\$( \. "\$HARNESS\/bin\/lib\/plan-verify-budget.sh" 2>\/dev\/null && pvb_repair_note "\$BUILD\/plan-gate.txt")//' "$T/pgblock.sh" > "$T/pgblock-mut.sh"
cmp -s "$T/pgblock.sh" "$T/pgblock-mut.sh" && bad "V11 setup: the mutation removed nothing" || ok
# The only CC in this suite: it saves the prompt and writes the repaired plan.
cat > "$T/drive.sh" <<'EOS'
set -uo pipefail
STAMP() { echo TS; }
RESULT() { echo "RESULT=$*"; }
BB() { :; }
CC() { printf '%s\n' "$5" >> "$CCLOG"; cp "$REPAIRED" "$BUILD/plan.md"; printf 'stub repair\n' > "$4"; }
. "$PGBLOCK"
echo CONTINUED
EOS
drive() { # drive <block> <plan>
  rm -rf "$T/b"; mkdir -p "$T/b"; cp "$2" "$T/b/plan.md"; printf '{"body":"fixture"}\n' > "$T/b/ticket-meta.json"
  : > "$T/cc.log"; : > "$H/logs/ALERTS.log"; rm -f "$H/state/plan-malformed.txt"
  ( env HARNESS="$H" BUILD="$T/b" PROJECT=widget-os KEY=WD-9779 TICKET=1 PLAN_MODEL=stub-model \
        ALERTS="$H/logs/ALERTS.log" CCLOG="$T/cc.log" PGBLOCK="$1" REPAIRED="$FX/bh7921-plan-repaired.md" \
        bash "$T/drive.sh" 2>&1 )
}
O11=$(drive "$T/pgblock.sh" "$FX/bh7921-plan.md")
grep -q CONTINUED <<<"$O11" && ! grep -q PLAN_MALFORMED <<<"$O11" && ok || bad "V11 one repair pass, then the build continues: $O11"
[ "$(grep -c 'Repair the plan' "$T/cc.log")" = 1 ] && ok || bad "V11 exactly one repair session: $(cat "$T/cc.log")"
grep -q 'name only the suites this change can break' "$T/cc.log" && grep -q 'Leave the wide run to the gate' "$T/cc.log" \
  && grep -q "line $GL: loop: " "$T/cc.log" && ok || bad "V11 the repair prompt carries the verify paragraph and the hits: $(cat "$T/cc.log")"
! grep -q 'verify budget —' "$T/b/plan-gate.txt" && grep -qx 'PLAN_VERIFY_BUDGET: ok' "$T/b/plan-gate.txt" && ok \
  || bad "V11 the second gate run has no verify budget line: $(cat "$T/b/plan-gate.txt")"
for s in run-build-linear-stub run-build-jira-stub docs-connectors.bh-7924; do
  sed -n '/^## Verify/,/^## /p' "$T/b/plan.md" | grep -q "tests/$s" && ok || bad "V11 the repaired Verify list names $s"
done
drive "$T/pgblock-mut.sh" "$FX/bh7921-plan.md" >/dev/null
grep -q 'name only the suites this change can break' "$T/cc.log" && bad "V11 mutation: with the call removed the paragraph must be gone" || ok

# ── V12 knob rows ────────────────────────────────────────────────────────────
settings '{"lib.plan-verify-budget.plan_verify_max_suites":"4"}'
chk "$FX/five-suites-plan.md"
[ "$RC" = 2 ] && grep -q 'suite-count: 5 distinct suites named, over the limit of 4' <<<"$OUT" && ok || bad "V12 a max_suites row of 4 refuses five suites (rc $RC): $OUT"
settings '{"lib.plan-verify-budget.plan_verify_slow_suite_s":"600"}'
chk "$FX/bh7921-plan.md" PLAN_VERIFY_DURATIONS="$D"
! grep -q slow-suite <<<"$OUT" && grep -q ': loop: ' <<<"$OUT" && ok || bad "V12 a slow_suite_s row of 600 lets the 488 s suite pass: $OUT"
settings '{"lib.plan-verify-budget.plan_verify_budget":"0"}'
chk "$FX/bh7921-plan.md" PLAN_VERIFY_DURATIONS="$D"
[ "$RC" = 0 ] && [ "$OUT" = 'PLAN_VERIFY_BUDGET: off' ] && ok || bad "V12 the budget row at 0 is off, rc 0 (rc $RC): $OUT"
settings '{"lib.plan-verify-budget.plan_verify_max_main_suites":"10"}'
chk "$(vp '- Run `tests/a.sh`, `tests/b.sh`, `tests/c.sh` and `tests/d.sh` on the head and on main.')"
[ "$RC" = 0 ] && ok || bad "V12 a max_main_suites row of 10 lets 4 main runs pass (rc $RC): $OUT"
settings '{}'

# ── V13 the execute prompt ───────────────────────────────────────────────────
EXP=$(env HARNESS="$H" PROJECT= KEY=K-1 BUILD="$T/b" BRANCH=br-1 bash -c '. "$0" || exit 9; sp_render execute' "$DIR/bin/lib/stage-prompt.sh" 2>&1)
grep -qF 'one command per suite' <<<"$EXP" && grep -qF '/dev/null' <<<"$EXP" && grep -qF 'the gate runs the wide selection' <<<"$EXP" && ok \
  || bad "V13 the rendered execute prompt has the three phrases: ${EXP:0:400}"

# ── K1 registry defaults = lib fallbacks ─────────────────────────────────────
REG="$DIR/catalog/lanes.d/_lib.plan-verify-budget.json"
for kv in PLAN_VERIFY_BUDGET=1 PLAN_VERIFY_MAX_SUITES=30 PLAN_VERIFY_MAX_MAIN_SUITES=3 PLAN_VERIFY_SLOW_SUITE_S=300; do
  k=${kv%%=*}; d=${kv#*=}
  [ "$(jq -r --arg e "$k" '.libs[0].knobs[] | select(.env == $e) | .default' "$REG")" = "$d" ] \
    && grep -q "_pvb_knob $k $d)" "$DIR/bin/lib/plan-verify-budget.sh" && ok || bad "K1 $k: registry default and lib fallback are $d"
done

echo "plan-verify-budget.bh-9779: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
