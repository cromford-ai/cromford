#!/bin/bash
# tests/fixround-repro.bh-9472-test.sh — BH-9472 (BH-9285 Fix 4): a ci-red fix
# round reproduces the failing CI test before it calls an agent, and pushes
# only after the same test passes on the box.
#
# Units: bin/lib/fixround-repro.sh (frr_failing_tests, _frr_parse,
# frr_reproduce, frr_confirm, knobs) over a stub gh that answers REST paths from
# files. Rounds: the REAL bin/blocked-resolver.sh through its --fix-here entry,
# with bin/blocked-resolver.d/bh-9472-fixround-repro.sh installed, over a real
# bare origin in the scratch dir. No call leaves the box.
#
# Cases:
#   P1-P7   _frr_parse: vitest, jest, harness lines; timestamp and colour;
#           unsafe and absent paths; FAIL inside a title or a summary
#   P8-P13  frr_failing_tests: jobs page 2; typecheck job (rc 3); mixed (rc 3);
#           a failed run with no failed job (rc 3, P10b);
#           a check that is not an Actions job (rc 3); green (rc 3);
#           unreadable (rc 2); a check-run job url
#   R1-R8   frr_reproduce / frr_confirm words: red, green, timeout, exit 127,
#           missing file, npm without node_modules, npm with VR_DEPS_FROM (the
#           link is removed after)
#   K1-K4   the knob rows and their reads
#   N1      NOT REPRODUCED: 0 agent calls, 0 pushes, 1 comment, fixrounds 1
#   N1c     NOT REPRODUCED at the fix cap: the ordinary terminal
#   N1b     a mixed red: the agent runs, no NOT REPRODUCED
#   N2      reproduced, the agent fixes it: REPRO_EXIT: passes, 1 push
#   N3      reproduced, still red: 0 pushes, "not proven green here"
#   N4      a review-blocked park: unchanged (no repro lines)
#   N5      FIXROUND_REPRO_GATE=0: unchanged
#   N6      main carries the fix: red at the head, passes on the round's tree
#   N7a     main moved, green at the head and on the round's tree: NOT REPRODUCED
#   N7b     green at the head, red on the round's tree: the round runs
#   N8      could-not-run before the agent (budget): the round runs
#   N9      npm with node_modules only in the clone: linked, then removed
#   MR1/MR2 mutations: the brfr_pre call removed; the brfr_verify gate line removed
# Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
# The scripts this suite drives. The copy stays HERE so bin/test-impact.sh
# selects this suite when one of them changes.
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
# fx_br_harness runs br_modules_install, so bin/lib/br/ travels with the copy.
[ -d "$H/bin/lib/br" ] || bad "setup: bin/lib/br/ was not installed beside the copied lane"
scratch_install_closure bin/blocked-resolver.sh "$H" >/dev/null || exit 1
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
fx_br_ladder_git "$DIR" "$T" || exit 1
# A missing fragment is a FAIL line, not an exit: every case below then shows
# its own red (the red run of this suite is taken that way).
scratch_install_closure bin/blocked-resolver.d/bh-9472-fixround-repro.sh "$H" >/dev/null \
  || bad "setup: bin/blocked-resolver.d/bh-9472-fixround-repro.sh and its closure would not install"
mkdir -p "$H/catalog/lanes.d" || exit 1
cp "$DIR/catalog/lanes.d/_lib.fixround-repro.json" "$DIR/catalog/lanes.d/_lib.ci-local.json" "$H/catalog/lanes.d/" || exit 1
FRAG="$H/bin/blocked-resolver.d/bh-9472-fixround-repro.sh"
[ -f "$FRAG" ] && [ -f "$H/bin/lib/fixround-repro.sh" ] && [ -f "$H/bin/lib/verify-run.sh" ] \
  && ok "setup: the fragment and its lib closure are installed" || bad "setup: closure install came back short"

# ---- the gh stub: this suite's CI paths, else the fixture's own stub --------
mv "$T/fakebin/gh" "$T/fakebin/gh.base" || exit 1
mkdir -p "$T/gh"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-all.txt"
case "\$*" in
  *"https://api."*) echo "an absolute API host URL refused by the stub" >&2; exit 1 ;;
esac
if [ "\${1:-}" = api ] && [ "\${2:-}" != -i ]; then
  case "\$2" in
    *actions/runs\?head_sha=*|*/actions/runs/*/jobs*|*/actions/jobs/*/logs|*/check-runs*)
      k=\$(printf '%s' "\$2" | sed -E 's#^repos/[^/]+/[^/]+/##; s#[^A-Za-z0-9]+#_#g')
      # No file: the fixture's own stub answers (br_failed_runs reads
      # per_page=50 from \$T/failedruns for the agent brief).
      [ -f "$T/gh/\$k" ] && { cat "$T/gh/\$k"; exit 0; } ;;
  esac
fi
exec "$T/fakebin/gh.base" "\$@"
EOF
chmod +x "$T/fakebin/gh"
# ghk <api path without repos/o/tproj/> — the file the stub answers it from.
ghk() { printf '%s/gh/%s' "$T" "$(printf '%s' "$1" | sed -E 's#[^A-Za-z0-9]+#_#g')"; }
# ci_red <sha> <run-id> <job-log>... — a red workflow run on <sha>, one failed
# job per log argument, each answered with that log text.
ci_red() {
  local sha="$1" rid="$2" i=0 jobs="[]" l
  shift 2
  rm -f "$T"/gh/*
  jq -nc --arg r "$rid" '{workflow_runs:[{name:"harness-ci",status:"completed",conclusion:"failure",
       html_url:("https://github.com/o/tproj/actions/runs/" + $r),run_started_at:"2026-11-12T00:00:00Z",run_attempt:1}]}' \
    > "$(ghk "actions/runs?head_sha=$sha&per_page=100")"
  printf '{"check_runs":[]}' > "$(ghk "commits/$sha/check-runs?per_page=100")"
  for l in "$@"; do
    i=$((i+1))
    jobs=$(jq -c --arg id "$rid$i" '. + [{id:($id|tonumber),name:("job" + $id),conclusion:"failure"}]' <<<"$jobs")
    printf '%s\n' "$l" > "$(ghk "actions/jobs/$rid$i/logs")"
  done
  jq -nc --argjson j "$jobs" '{total_count:($j|length),jobs:$j}' \
    > "$(ghk "actions/runs/$rid/jobs?filter=latest&per_page=100&page=1")"
  # br_ci_log's own reads (the agent brief) are the fixture's $T/failedruns
  # and $T/joblog.
  printf '81\n' > "$T/failedruns"
  printf '%s\n' "$@" > "$T/joblog"
}

# ============================================================================
# Units: the lib, sourced in a subshell from the scratch harness
# ============================================================================
U="$T/u"; mkdir -p "$U/tests" "$U/src"
printf 'exit 0\n' > "$U/tests/a.test.ts"
printf 'exit 0\n' > "$U/tests/b.test.js"
printf 'exit 0\n' > "$U/tests/c-test.sh"
ln -s c-test.sh "$U/tests/link-test.sh"
LIB() { ( export HARNESS="$H" CI_LOCALE=C PATH="$T/fakebin:$PATH"; . "$H/bin/lib/fixround-repro.sh" || exit 9; "$@" ); }
parse() { printf '%s\n' "$1" | LIB _frr_parse "$U"; }

[ "$(parse ' FAIL  tests/a.test.ts > suite > case one')" = tests/a.test.ts ] \
  && ok "P1: a vitest FAIL line names tests/a.test.ts" || bad "P1: vitest line: '$(parse ' FAIL  tests/a.test.ts > suite > case one')'"
[ "$(parse 'FAIL tests/b.test.js (5.12 s)')" = tests/b.test.js ] && [ "$(parse 'FAIL tests/b.test.js')" = tests/b.test.js ] \
  && ok "P2: a jest FAIL line names tests/b.test.js" || bad "P2: jest line not parsed"
[ "$(parse '--- tests/c-test.sh rc=1 12s')" = tests/c-test.sh ] && [ -z "$(parse '--- tests/c-test.sh rc=0 12s')" ] \
  && ok "P3: a harness '--- <suite> rc=1' line names the suite; rc=0 names nothing" || bad "P3: harness line"
[ "$(parse $'2026-11-12T01:02:03.4567890Z \e[31m FAIL \e[39m tests/a.test.ts > x')" = tests/a.test.ts ] \
  && ok "P4: a timestamped, coloured FAIL line is read" || bad "P4: timestamp/colour line: '$(parse $'2026-11-12T01:02:03.4567890Z \e[31m FAIL \e[39m tests/a.test.ts > x')'"
got=$(printf '%s\n' 'FAIL ../etc/passwd' 'FAIL /etc/passwd' 'FAIL -rf' 'FAIL tests/link-test.sh' 'FAIL tests/none.test.ts' 'FAIL tests' | LIB _frr_parse "$U")
[ -z "$got" ] && ok "P5: '..', an absolute path, '-rf', a symlink, an absent file and a directory are not test names" \
  || bad "P5: unsafe names came through: $got"
got=$(printf '%s\n' ' ✓ handles FAIL  tests/a.test.ts > x' '      Tests  1 failed | 3 passed' 'Test Files  1 failed (2)' | LIB _frr_parse "$U")
[ -z "$got" ] && ok "P6: FAIL inside a title and the summary lines name nothing" || bad "P6: got '$got'"
got=$(parse ' FAIL  |unit| tests/a.test.ts > s > c')
[ "$got" = tests/a.test.ts ] && ok "P7: a vitest project-prefixed line is read" || bad "P7: got '$got'"

SHA=1111111111111111111111111111111111111111
FT() { LIB frr_failing_tests o/tproj "$SHA" "$U"; }
# P8: the failed job is on page 2 of the job list.
ci_red "$SHA" 71 'x'
jq -nc '{total_count:101,jobs:[range(0;100)|{id:(9000+.),conclusion:"success"}]}' > "$(ghk "actions/runs/71/jobs?filter=latest&per_page=100&page=1")"
jq -nc '{total_count:101,jobs:[{id:9555,conclusion:"failure"}]}' > "$(ghk "actions/runs/71/jobs?filter=latest&per_page=100&page=2")"
printf '%s\n' '2026-11-12T00:00:00.1Z  FAIL  tests/a.test.ts > s > c' 'FAIL tests/b.test.js' > "$(ghk "actions/jobs/9555/logs")"
got=$(FT); rc=$?
[ "$rc" = 0 ] && [ "$got" = $'tests/a.test.ts\ntests/b.test.js' ] \
  && ok "P8: a failed job on page 2 names its two test files (rc 0)" || bad "P8: rc=$rc got='$got'"
ci_red "$SHA" 72 'error TS2322: Type string is not assignable' ; got=$(FT); rc=$?
[ "$rc" = 3 ] && [ -z "$got" ] && ok "P9: a typecheck job with no FAIL line is rc 3 (not gated)" || bad "P9: rc=$rc got='$got'"
ci_red "$SHA" 73 ' FAIL  tests/a.test.ts > s' 'error TS2322: nope'; got=$(FT); rc=$?
[ "$rc" = 3 ] && ok "P10: one test job plus one typecheck job is rc 3 (a mixed red is never gated)" || bad "P10: rc=$rc got='$got'"
ci_red "$SHA" 78 'x'
jq -nc '{total_count:2,jobs:[{id:7801,conclusion:"success"},{id:7802,conclusion:"skipped"}]}' \
  > "$(ghk "actions/runs/78/jobs?filter=latest&per_page=100&page=1")"
got=$(FT); rc=$?
[ "$rc" = 3 ] && [ -z "$got" ] && ok "P10b: a failed run with no failed job is rc 3" || bad "P10b: rc=$rc got='$got'"
ci_red "$SHA" 74 'x'
jq -nc '{workflow_runs:[]}' > "$(ghk "actions/runs?head_sha=$SHA&per_page=100")"
jq -nc '{check_runs:[{name:"vercel",status:"completed",conclusion:"failure",html_url:"https://vercel.example/deploy/1",started_at:"2026-11-12T00:00:00Z"}]}' \
  > "$(ghk "commits/$SHA/check-runs?per_page=100")"
got=$(FT); rc=$?
[ "$rc" = 3 ] && ok "P11: a failed check that is not an Actions job is rc 3" || bad "P11: rc=$rc"
ci_red "$SHA" 75 'x'
jq -nc '{workflow_runs:[{name:"harness-ci",status:"completed",conclusion:"success",html_url:"https://github.com/o/tproj/actions/runs/75",run_started_at:"2026-11-12T00:00:00Z"}]}' \
  > "$(ghk "actions/runs?head_sha=$SHA&per_page=100")"
got=$(FT); rc=$?
[ "$rc" = 3 ] && ok "P12: a green head is rc 3" || bad "P12: green rc=$rc"
rm -f "$T"/gh/*; : > "$T/failedruns"
got=$(FT); rc=$?
[ "$rc" = 2 ] && ok "P12: an unreadable CI is rc 2" || bad "P12: unreadable rc=$rc"
ci_red "$SHA" 76 'x'
jq -nc '{workflow_runs:[]}' > "$(ghk "actions/runs?head_sha=$SHA&per_page=100")"
jq -nc '{check_runs:[{name:"unit",status:"completed",conclusion:"failure",html_url:"https://github.com/o/tproj/actions/runs/76/job/7601",started_at:"2026-11-12T00:00:00Z"}]}' \
  > "$(ghk "commits/$SHA/check-runs?per_page=100")"
printf -- '--- tests/c-test.sh rc=1 3s\n' > "$(ghk "actions/jobs/7601/logs")"
got=$(FT); rc=$?
[ "$rc" = 0 ] && [ "$got" = tests/c-test.sh ] && ok "P13: a check-run job url reads that job's log" || bad "P13: rc=$rc got='$got'"
grep -q 'https://api[.]' "$T/gh-all.txt" 2>/dev/null && bad "P: a call named an absolute API host" || ok "P: no call named an absolute API host"

# ---- R: the runs -------------------------------------------------------------
printf 'echo "FAIL: red"; exit 1\n' > "$U/tests/red-test.sh"
printf 'exit 0\n' > "$U/tests/green-test.sh"
printf 'while :; do :; done\n' > "$U/tests/slow-test.sh"   # never ends: the budget kills it
printf 'exit 127\n' > "$U/tests/e127-test.sh"
RW() { LIB bash -c '. "$1"; shift; w=$("$@"); r=$?; printf "%s %s|%s" "$w" "$r" "$FRR_WHY"' _ "$H/bin/lib/fixround-repro.sh" "$@"; }
# FRR_WHY survives only an in-shell call: call each word fn in this subshell.
RX() { LIB bash -c '. "$1"; shift; "$@" > "$0.w"; r=$?; printf "%s %s|%s" "$(cat "$0.w")" "$r" "$FRR_WHY"' "$T/rx" "$H/bin/lib/fixround-repro.sh" "$@"; }
got=$(RX frr_reproduce "$U" "$T/r1.log" tests/red-test.sh)
[ "${got%%|*}" = "reproduced 1" ] && grep -q 'FAIL: red' "$T/r1.log" && grep -q '^HARNESS_LOCALE: ' "$T/r1.log" \
  && ok "R1: a red file is 'reproduced' rc 1, run with the CI locale record" || bad "R1: got '$got' ($(head -3 "$T/r1.log"))"
got=$(RX frr_reproduce "$U" "$T/r2.log" tests/green-test.sh)
[ "${got%%|*}" = "not-reproduced 0" ] && ok "R2: a green file is 'not-reproduced' rc 0" || bad "R2: got '$got'"
got=$( CL_BUDGET_CAP=1 RX frr_reproduce "$U" "$T/r3.log" tests/slow-test.sh)
[ "${got%%|*}" = "could-not-run 2" ] && grep -q 'budget' <<<"${got#*|}" \
  && ok "R3: past the budget is could-not-run, never green (${got#*|})" || bad "R3: got '$got'"
got=$(RX frr_reproduce "$U" "$T/r4.log" tests/e127-test.sh)
[ "${got%%|*}" = "could-not-run 2" ] && ok "R4: exit 127 is could-not-run" || bad "R4: got '$got'"
got=$(RX frr_reproduce "$U" "$T/r5.log" tests/none-test.sh)
[ "${got%%|*}" = "could-not-run 2" ] && ok "R5: an absent file is could-not-run" || bad "R5: got '$got'"
a=$(RX frr_confirm "$U" "$T/r6.log" tests/green-test.sh); b=$(RX frr_confirm "$U" "$T/r6.log" tests/red-test.sh)
[ "${a%%|*}" = "passes 0" ] && [ "${b%%|*}" = "still-red 1" ] && ok "R6: frr_confirm says passes rc 0 / still-red rc 1" || bad "R6: '$a' '$b'"
NP="$T/np"; mkdir -p "$NP/tests" "$T/deps/node_modules"
printf '{"scripts":{"test":"bash -c '"'"'for f; do bash \\"$f\\" || exit 1; done'"'"' _"}}\n' > "$NP/package.json"
printf 'exit 0\n' > "$NP/tests/n-test.sh"
got=$(RX frr_reproduce "$NP" "$T/r7.log" tests/n-test.sh)
[ "${got%%|*}" = "could-not-run 2" ] && grep -q 'node_modules' <<<"${got#*|}" \
  && ok "R7: npm with no node_modules anywhere is could-not-run" || bad "R7: got '$got'"
if command -v npm >/dev/null 2>&1; then
  got=$(VR_DEPS_FROM="$T/deps" RX frr_reproduce "$NP" "$T/r8.log" tests/n-test.sh)
  [ "${got%%|*}" = "not-reproduced 0" ] && [ ! -e "$NP/node_modules" ] && [ -d "$T/deps/node_modules" ] \
    && ok "R8: npm with VR_DEPS_FROM runs, and only the link is removed after" || bad "R8: got '$got' ($(tail -3 "$T/r8.log"))"
else
  ok "R8: skipped — no npm on this box"
fi
unset -f RW

# ---- K: the knobs ------------------------------------------------------------
K="$DIR/catalog/lanes.d/_lib.fixround-repro.json"
[ "$(jq -r '.libs[0].knobs[] | select(.env=="FIXROUND_REPRO_GATE") | "\(.default) \(.min) \(.max)"' "$K")" = "1 0 1" ] \
  && ok "K1: FIXROUND_REPRO_GATE int 0..1 default 1" || bad "K1: the gate knob row"
[ "$(jq -r '.libs[0].knobs[] | select(.env=="FIXROUND_REPRO_LOG_MAX_KB") | "\(.default) \(.min) \(.max)"' "$K")" = "2048 1 65536" ] \
  && ok "K1: FIXROUND_REPRO_LOG_MAX_KB int 1..65536 default 2048" || bad "K1: the log knob row"
[ "$(jq -r '.libs[0].knobs[] | select(.env=="FIXROUND_REPRO_VERIFY_TAIL_BYTES") | "\(.default) \(.min) \(.max)"' "$K")" = "4000 1 1048576" ] \
  && ok "K1: FIXROUND_REPRO_VERIFY_TAIL_BYTES int 1..1048576 default 4000" || bad "K1: the verify tail knob row"
[ "$(LIB frr_verify_tail_bytes)" = 4000 ] && [ "$(FIXROUND_REPRO_VERIFY_TAIL_BYTES=0 LIB frr_verify_tail_bytes)" = 4000 ] \
  && [ "$(FIXROUND_REPRO_VERIFY_TAIL_BYTES=50 LIB frr_verify_tail_bytes)" = 50 ] \
  && ok "K5: the verify tail reads the knob, and an out-of-range value reads the default" || bad "K5: frr_verify_tail_bytes"
LIB frr_on && ok "K2: the gate is on by default" || bad "K2: the gate is off by default"
( FIXROUND_REPRO_GATE=0 LIB frr_on ) && bad "K2: FIXROUND_REPRO_GATE=0 left the gate on" || ok "K2: FIXROUND_REPRO_GATE=0 turns it off"
( FIXROUND_REPRO_GATE=yes LIB frr_on ) && ok "K3: a bad value reads the default (on)" || bad "K3: a bad value turned it off"
[ "$(LIB _frr_log_max_kb)" = 2048 ] && [ "$(FIXROUND_REPRO_LOG_MAX_KB=0 LIB _frr_log_max_kb)" = 2048 ] \
  && [ "$(FIXROUND_REPRO_LOG_MAX_KB=4 LIB _frr_log_max_kb)" = 4 ] \
  && ok "K4: the log cap reads the knob, and an out-of-range value reads the default" || bad "K4: _frr_log_max_kb"
ci_red "$SHA" 77 "$(printf ' FAIL  tests/a.test.ts > s\n'; head -c 3000 /dev/zero | tr '\0' 'x')"
got=$(FIXROUND_REPRO_LOG_MAX_KB=1 FT); rc=$?
[ "$rc" = 3 ] && ok "K4: a FAIL line before the log tail is not read: rc 3, never a false NOT REPRODUCED" || bad "K4: rc=$rc got='$got'"
got=$(FT); rc=$?
[ "$rc" = 0 ] && [ "$got" = tests/a.test.ts ] && ok "K4: the default tail reads the same line" || bad "K4: default rc=$rc got='$got'"

# ============================================================================
# Rounds: the real driver, --fix-here
# ============================================================================
# The agent: records the prompt; with $T/agent-fixes it creates fixed.txt,
# with $T/agent-touches it commits an unrelated file.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/agent.txt"
printf '%s' "\$6" > "$T/prompt.txt"
if [ -f "$T/agent-fixes" ]; then
  printf 'fixed\n' > fixed.txt; git add fixed.txt; git commit -q -m "fix round: the fix" >/dev/null 2>&1
elif [ -f "$T/agent-touches" ]; then
  printf 'other\n' > other.txt; git add other.txt; git commit -q -m "fix round: a guess" >/dev/null 2>&1
fi
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
cp "$H/bin/blocked-resolver.sh" "$H/bin/blocked-resolver.real.sh"

# mkrepro <branch> <tip|old> <test body> [extra-file] — a PR branch with
# tests/repro-a-test.sh, cut from main's tip (the merge is a no-op, so the
# round's tree IS the CI head) or from the first commit (main moves under it).
mkrepro() {
  git -C "$SEED" checkout -q main
  git -C "$SEED" reset -q --hard origin/main
  [ "$2" = old ] && git -C "$SEED" reset -q --hard "$(git -C "$SEED" rev-list --max-parents=0 HEAD)"
  git -C "$SEED" checkout -q -B "$1"
  mkdir -p "$SEED/tests"
  printf '%s\n' "$3" > "$SEED/tests/repro-a-test.sh"
  [ -n "${4:-}" ] && printf 'x\n' > "$SEED/$4"
  git -C "$SEED" add -A; git -C "$SEED" commit -qm "work on $1"; git -C "$SEED" push -q -f origin "$1"
  git -C "$SEED" checkout -q main
}
# main_add <file> — main moves: one new file on main.
main_add() {
  git -C "$SEED" checkout -q main; git -C "$SEED" fetch -q origin; git -C "$SEED" reset -q --hard origin/main
  printf 'x\n' > "$SEED/$1"; git -C "$SEED" add -A; git -C "$SEED" commit -qm "main adds $1"; git -C "$SEED" push -q origin main
}
REDBODY='[ -f fixed.txt ] || { echo "FAIL: fixed.txt is missing"; exit 1; }'
PR="https://github.com/o/tproj/pull/91"
ST="$H/state/blocked-resolver/tproj"
LOGF="$H/logs/blocked-resolver.log"
# RESET <branch> <reason> — clean state, the PR names <branch>, CI red on its
# head naming tests/repro-a-test.sh (or the logs given after).
RESET() {
  local b="$1"; shift
  scratch_rm "$H/state/blocked-resolver"; scratch_rm "$H/state/lane-gate"; scratch_rm "$H/tmp/brfix"
  rm -f "$H/flags/all-off" "$H/flags/lane-off-"* "$H/flags/blocked-resolver-"* "$H/locks/blocked-resolver-cron.lock"
  : > "$LOGF"; : > "$T/agent.txt"; : > "$T/comment-bodies.txt"; : > "$T/comments.txt"; rm -f "$T/prompt.txt" "$T/agent-fixes" "$T/agent-touches"
  git -C "$T/repos/tproj" worktree prune >/dev/null 2>&1
  git -C "$T/repos/tproj" for-each-ref --format='%(refname:short)' refs/heads/brfix/ \
    | while read -r x; do git -C "$T/repos/tproj" branch -D "$x" >/dev/null 2>&1; done
  git -C "$T/repos/tproj" fetch -q origin 2>/dev/null
  printf '%s' "$b" > "$T/prbranch"; osha "$b" | tr -d '\n' > "$T/prhead"
  printf 'CI is red on this head.\n' > "$T/findings"
  if [ $# -gt 0 ]; then ci_red "$(osha "$b")" 81 "$@"
  else ci_red "$(osha "$b")" 81 '2026-11-12T00:00:01.0Z --- tests/repro-a-test.sh rc=1 2s'; fi
  jq -nc '{project:"tproj",rkey:"repro-1",fixrounds:0,rebuilds:0,mechanicals:0,outcome:"",attempts:[]}' > "$T/rec-in.json"
}
# FIXHERE <reason> [VAR=value...] — one hopped round of the driver in $DRV.
DRV="$H/bin/blocked-resolver.sh"
FIXHERE() {
  local reason="$1"; shift
  ( env HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BOX_NAME=box-tproj CI_LOCALE=C \
        BR_MAX_FIXROUNDS="${CAP:-2}" "$@" bash "$DRV" --fix-here tproj repro-1 "$reason" "$PR" - - < "$T/rec-in.json" ) 2>>"$T/run.log"
}
FV() { cat "$ST"/*.fix-verify.txt 2>/dev/null; }
REC() { cat "$ST"/*.json 2>/dev/null | jq -s 'map(select(.rkey? == "repro-1")) | .[0] // {}'; }
NOTREP() { grep -c 'NOT REPRODUCED' "$T/comment-bodies.txt" 2>/dev/null; }

# ---- N1: NOT REPRODUCED ------------------------------------------------------
mkrepro ticket/TK-201 tip 'exit 0'
RESET ticket/TK-201
before=$(osha ticket/TK-201)
out=$(FIXHERE red-ci-twice)
[ ! -s "$T/agent.txt" ] && ok "N1: no agent call" || bad "N1: the agent ran ($(head -2 "$T/agent.txt"))"
[ "$(osha ticket/TK-201)" = "$before" ] && ok "N1: no push" || bad "N1: the branch moved"
[ "$(NOTREP)" = 1 ] && grep -q 'tests/repro-a-test.sh pass locally on' "$T/comment-bodies.txt" \
  && grep -q 'LC_ALL=C' "$T/comment-bodies.txt" && grep -q 'actions/runs/81 failed' "$T/comment-bodies.txt" \
  && ok "N1: one PR comment: NOT REPRODUCED, the file, the locale, the CI run" || bad "N1: comment bodies: $(cat "$T/comment-bodies.txt")"
grep -q '^REPRO_EXIT: not-reproduced$' <<<"$(FV)" && grep -q '^REPRO_FILES: tests/repro-a-test.sh$' <<<"$(FV)" \
  && ok "N1: fix-verify.txt says REPRO_EXIT: not-reproduced" || bad "N1: fix-verify.txt: $(FV)"
[ "$(REC | jq -r '.fixrounds')" = 1 ] && jq -e '.attempts[-1].detail | test("^NOT REPRODUCED")' <<<"$(REC)" >/dev/null \
  && ok "N1: the record counts one fix round with a NOT REPRODUCED attempt" || bad "N1: record: $(REC | jq -c '{fixrounds,attempts}')"
grep -q 'FIX_RESULT done' <<<"$out" && grep -q 'fix round 2 next tick' "$LOGF" \
  && ok "N1: under the cap the round ends with 'next tick'" || bad "N1: out=$(grep FIX_RESULT <<<"$out") log=$(grep -i 'not repro' "$LOGF" | tail -2)"
[ -z "$(ls -A "$H/tmp/brfix" 2>/dev/null)" ] && ! git -C "$T/repos/tproj" rev-parse -q --verify "refs/heads/brfix/$(ls "$ST" | sed -n 's/\.json$//p' | head -1)" >/dev/null 2>&1 \
  && ok "N1: no worktree left, the checkpoint branch dropped" || bad "N1: left behind: $(ls -A "$H/tmp/brfix" 2>/dev/null)"

# ---- N1c: NOT REPRODUCED at the cap -> the ordinary terminal -----------------
RESET ticket/TK-201
out=$(CAP=1 FIXHERE red-ci-twice)
[ ! -s "$T/agent.txt" ] && grep -q 'FIX_RESULT terminal' <<<"$out" && [ "$(NOTREP)" = 1 ] \
  && ok "N1c: at the fix cap NOT REPRODUCED takes the ordinary terminal" || bad "N1c: $(grep FIX_RESULT <<<"$out")"

# ---- N1b: a mixed red is not gated -------------------------------------------
RESET ticket/TK-201 '--- tests/repro-a-test.sh rc=1 2s' 'error TS2322: nope'
FIXHERE red-ci-twice >/dev/null
[ -s "$T/agent.txt" ] && [ "$(NOTREP)" = 0 ] && ! grep -q '^REPRO_EXIT' <<<"$(FV)" \
  && ok "N1b: a mixed red runs the agent, no NOT REPRODUCED" || bad "N1b: agent=$(wc -l < "$T/agent.txt") fv=$(FV | grep REPRO)"

# ---- N2: reproduced, the agent fixes it, the push follows the pass ------------
mkrepro ticket/TK-202 tip "$REDBODY"
RESET ticket/TK-202
before=$(osha ticket/TK-202)
touch "$T/agent-fixes"
FIXHERE red-ci-twice >/dev/null
[ -s "$T/agent.txt" ] && grep -q 'REPRODUCED red on the CI head' "$LOGF" \
  && ok "N2: reproduced red here, the agent ran" || bad "N2: $(grep -i repro "$LOGF" | head -3)"
grep -q '^REPRO_EXIT: passes$' <<<"$(FV)" && ok "N2: fix-verify.txt says REPRO_EXIT: passes" || bad "N2: fix-verify: $(FV | grep -A1 '== repro')"
[ "$(osha ticket/TK-202)" != "$before" ] && git -C "$ORIGIN" cat-file -e "ticket/TK-202:fixed.txt" 2>/dev/null \
  && ok "N2: one push, carrying the fix" || bad "N2: no push ($(tail -5 "$LOGF"))"

# ---- N3: reproduced, still red after the agent -> no push ---------------------
mkrepro ticket/TK-203 tip "$REDBODY"
RESET ticket/TK-203
before=$(osha ticket/TK-203)
touch "$T/agent-touches"
FIXHERE red-ci-twice >/dev/null
grep -q '^REPRO_EXIT: still-red$' <<<"$(FV)" && ok "N3: fix-verify.txt says REPRO_EXIT: still-red" || bad "N3: fix-verify: $(FV | grep REPRO)"
[ "$(osha ticket/TK-203)" = "$before" ] && ok "N3: no push" || bad "N3: the branch moved"
grep -q 'the failing CI test is not proven green here (still-red) — not pushed' "$LOGF" \
  && ok "N3: the log says not proven green here" || bad "N3: no 'not proven green here' line"

# ---- N4: a review-blocked park is not gated ----------------------------------
RESET ticket/TK-201
printf 'Head-bound harness re-review: BLOCK. Finding: the route is unauthenticated.\n' > "$T/findings"
FIXHERE head-not-reapproved >/dev/null
[ -s "$T/agent.txt" ] && [ "$(NOTREP)" = 0 ] && ! grep -q '^REPRO_' <<<"$(FV)" \
  && ok "N4: head-not-reapproved runs as before (agent, no repro lines)" || bad "N4: agent=$(wc -l < "$T/agent.txt") $(FV | grep REPRO) $(tail -4 "$LOGF")"

# ---- N5: the gate off --------------------------------------------------------
RESET ticket/TK-201
FIXHERE red-ci-twice FIXROUND_REPRO_GATE=0 >/dev/null
[ -s "$T/agent.txt" ] && [ "$(NOTREP)" = 0 ] && ! grep -q '^REPRO_' <<<"$(FV)" && grep -q 'repro gate off' "$LOGF" \
  && ok "N5: FIXROUND_REPRO_GATE=0 runs as before, with one log line" || bad "N5: agent=$(wc -l < "$T/agent.txt")"

# ---- N6: main carries the fix: red at the head, passes on the round's tree ----
mkrepro ticket/TK-206 old "$REDBODY"
main_add fixed.txt
RESET ticket/TK-206
before=$(osha ticket/TK-206)
touch "$T/agent-touches"
FIXHERE red-ci-twice >/dev/null
grep -q 'REPRODUCED red on the CI head' "$LOGF" && grep -q '^REPRO_EXIT: passes$' <<<"$(FV)" && [ "$(osha ticket/TK-206)" != "$before" ] \
  && ok "N6: red at the head (detached tree), passes on the merged tree, pushed" || bad "N6: $(grep -i repro "$LOGF" | head -3) / $(FV | grep REPRO_EXIT)"
[ -z "$(ls -d "$H"/tmp/brfix/repro-* 2>/dev/null)" ] && ok "N6: the detached repro worktree is removed" || bad "N6: repro worktree left"

# ---- N7a: main moved, green at the head and on the merged tree ----------------
mkrepro ticket/TK-207 old 'exit 0'
RESET ticket/TK-207
FIXHERE red-ci-twice >/dev/null
[ ! -s "$T/agent.txt" ] && [ "$(NOTREP)" = 1 ] && grep -q "^REPRO_WHERE: the round's tree" <<<"$(FV)" \
  && ok "N7a: green at the head is re-run on the merged tree before NOT REPRODUCED" || bad "N7a: agent=$(wc -l < "$T/agent.txt") $(FV)"

# ---- N7b: green at the head, red on the merged tree -> the round runs ---------
mkrepro ticket/TK-208 old '[ ! -f broken.txt ] || { echo "FAIL: broken"; exit 1; }'
main_add broken.txt
RESET ticket/TK-208
FIXHERE red-ci-twice >/dev/null
[ -s "$T/agent.txt" ] && [ "$(NOTREP)" = 0 ] && grep -q "REPRODUCED red on the round's tree" "$LOGF" \
  && ok "N7b: a red on the merged tree is reproduced, the agent runs" || bad "N7b: agent=$(wc -l < "$T/agent.txt") $(grep -i repro "$LOGF" | head -2)"

# ---- N8: could-not-run before the agent --------------------------------------
mkrepro ticket/TK-209 tip 'while :; do :; done'   # never ends: the budget kills it
RESET ticket/TK-209
FIXHERE red-ci-twice CL_BUDGET_CAP=1 >/dev/null
[ -s "$T/agent.txt" ] && [ "$(NOTREP)" = 0 ] && grep -q 'could not run here (timed out' "$LOGF" \
  && ok "N8: a could-not-run is never NOT REPRODUCED; the round runs" || bad "N8: agent=$(wc -l < "$T/agent.txt") $(grep -i 'repro gate' "$LOGF" | head -2)"

# ---- N9: npm, node_modules only in the clone ----------------------------------
if command -v npm >/dev/null 2>&1; then
  mkrepro ticket/TK-210 tip 'exit 0' package.json
  git -C "$SEED" checkout -q ticket/TK-210
  printf '{"scripts":{"test":"bash -c '"'"'for f; do bash \\"$f\\" || exit 1; done'"'"' _"}}\n' > "$SEED/package.json"
  git -C "$SEED" commit -qam "npm test script"; git -C "$SEED" push -q origin ticket/TK-210; git -C "$SEED" checkout -q main
  RESET ticket/TK-210
  FIXHERE red-ci-twice >/dev/null
  [ "$(NOTREP)" = 0 ] && [ -s "$T/agent.txt" ] && grep -q 'no node_modules' "$LOGF" \
    && ok "N9: npm with no node_modules anywhere is could-not-run; the round runs" || bad "N9: $(grep -i 'repro gate' "$LOGF" | head -2)"
  mkdir -p "$T/repos/tproj/node_modules"
  RESET ticket/TK-210
  FIXHERE red-ci-twice >/dev/null
  [ "$(NOTREP)" = 1 ] && [ ! -s "$T/agent.txt" ] && [ -d "$T/repos/tproj/node_modules" ] \
    && ok "N9: node_modules linked from the clone: NOT REPRODUCED, the clone's node_modules kept" || bad "N9: $(grep -i 'repro gate\|NOT REPRO' "$LOGF" | head -2)"
  rmdir "$T/repos/tproj/node_modules"
else
  ok "N9: skipped — no npm on this box"
fi

# ---- MR: mutations -----------------------------------------------------------
sed '/brfr_pre "\$p"/d' "$H/bin/blocked-resolver.real.sh" > "$H/bin/blocked-resolver.mut1.sh"
sed '/! brfr_verify "\$wt"/d' "$H/bin/blocked-resolver.real.sh" > "$H/bin/blocked-resolver.mut2.sh"
if cmp -s "$H/bin/blocked-resolver.real.sh" "$H/bin/blocked-resolver.mut1.sh" || cmp -s "$H/bin/blocked-resolver.real.sh" "$H/bin/blocked-resolver.mut2.sh"; then
  bad "MR: a mutation changed nothing — a call site is not in bin/blocked-resolver.sh"
else
  DRV="$H/bin/blocked-resolver.mut1.sh"
  RESET ticket/TK-201
  FIXHERE red-ci-twice >/dev/null
  [ -s "$T/agent.txt" ] && ok "MR1: without the brfr_pre call the agent runs (N1 goes red)" || bad "MR1: the mutant still skipped the agent"
  DRV="$H/bin/blocked-resolver.mut2.sh"
  # Its own red condition: main carries fixed.txt since N6.
  mkrepro ticket/TK-204 tip '[ -f fixed-mr2.txt ] || { echo "FAIL: fixed-mr2.txt is missing"; exit 1; }'
  RESET ticket/TK-204
  before=$(osha ticket/TK-204)
  touch "$T/agent-touches"
  FIXHERE red-ci-twice >/dev/null
  [ "$(osha ticket/TK-204)" != "$before" ] && ok "MR2: without the brfr_verify gate line a still-red round pushes (N3 goes red)" \
    || bad "MR2: the mutant still held the push ($(FV | grep EXIT) $(tail -4 "$LOGF"))"
  DRV="$H/bin/blocked-resolver.sh"
fi
grep -q 'https://api[.]' "$T/gh-all.txt" 2>/dev/null && bad "N: a call named an absolute API host" || ok "N: 0 calls to an absolute API host"

echo "fixround-repro.bh-9472: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
