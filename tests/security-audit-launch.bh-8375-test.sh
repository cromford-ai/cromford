#!/bin/bash
# tests/security-audit-launch.bh-8375-test.sh — BH-8375: bin/security-audit-launch.sh
# starts bin/security-audit.sh detached on the box that owns the project, so the
# console's run_script command can start the pilot with no ssh, and --status
# reads the numbers back. The real runner runs with the BH-7910 stub agent.
#
#   L1  refused: a bad name, a name not in fleet.conf, no checkout, a dir with
#       no .git, extra argv (a cap raise), --status with no project; 0 claude calls
#   L2  start through the REAL bin/cmd-run-script.sh: result ok, tail `started`
#   L3  --status is `none` before a summary; then counts 2/3/1, completed
#   L4  a held runner lock: already-running, no new run dir, 0 new claude calls
#   L5  a stale unheld lock file: started
#   L6  --status prints no finding title of the fixture
#   L7  the launcher returns at once while the agent sleeps (detached)
#   L8  the artifact stays out of git (the scratch harness repo shows no path)
#   L9  an unreadable latest-summary.json is failed (rc 1), never none
#   L10 a start at an already audited sha: the runner's SKIP already-audited,
#       0 new claude calls
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/security-audit-launch.bh-8375-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/security-audit-fixture.sh" || exit 1
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq git flock setsid; do command -v "$c" >/dev/null 2>&1 || { echo "$c missing — skipping"; exit 0; }; done

# Every process this suite started carries SA_T=$T in its environment: kill
# them before the scratch tree goes, a detached runner included.
kill_ours() {
  local p
  for p in /proc/[0-9]*; do
    [ "${p#/proc/}" = "$$" ] && continue
    { tr '\0' '\n' < "$p/environ"; } 2>/dev/null | grep -qxF "SA_T=$T" && kill -KILL "${p#/proc/}" 2>/dev/null
  done
  return 0
}
trap 'kill_ours; __scratch_exit_trap' EXIT

PJ=fixture-proj
sa_fixture_setup "$PJ" || { echo "FAIL: fixture setup"; exit 1; }
for s in bin/security-audit-launch.sh bin/security-audit.sh bin/security-audit-sandbox.sh bin/agent-call.sh \
         bin/transcript-cost.sh bin/jobs-client.sh bin/cmd-run-script.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$T" >/dev/null || bad "install $s"
done
mkdir -p "$T/prompts" "$T/catalog"
cp "$REPO_DIR/prompts/security-audit.md" "$T/prompts/"
cp -r "$REPO_DIR/catalog/run-script-allowlist.json" "$REPO_DIR/catalog/run-script-allowlist.d" "$T/catalog/"
printf '# fixture\n%s example-org/%s - - 1 hub\nother example-org/other - - 2 hub\n' "$PJ" "$PJ" > "$T/fleet.conf"
mkdir -p "$T/repos"
git init -q "$T/repos/$PJ"
mkdir -p "$T/repos/other"           # in fleet.conf, a dir, no .git
git -C "$T" init -q 2>/dev/null     # L8: is anything under state/ tracked-able?
OUTD="$T/state/security-audit"

env_run() { # env_run <cmd...> — the env sa_run gives the runner, plus the launcher's seams
  env -u AGENT_CALL_TICKET -u AGENT_CALL_FP -u COST_KEY -u HARNESS_TICKET -u CLAUDE_CONFIG_DIR \
      -u ACCOUNTS_DIR -u ACCOUNT_OWN_PROJECTS \
      PATH="$T/fakebin:$PATH" HARNESS="$T" HOME="$T" SA_T="$T" SA_FIX="$SA_FIX" SA_PROJECT="$PJ" \
      SA_CONF="$T/sa.conf" SA_REPO_URL="$T/target" SA_POLL_S=1 SA_KILL_GRACE_S=2 \
      HARNESS_ENV_DIR="$T/env" ACCOUNT_ROUTING=0 FLEET_CONF="$T/fleet.conf" SA_REPOS_DIR="$T/repos" \
      BUILD="$T/not-the-out" "$@"
}
la() { OUT=$(env_run bash "$T/bin/security-audit-launch.sh" "$@" 2>"$T/err"); RC=$?; }
jf() { jq -r "$1" <<<"$OUT" 2>/dev/null; }
wait_summary() { # wait_summary <file> — up to 60 s
  local i=0
  while [ ! -f "$1" ] && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done
  [ -f "$1" ]
}
wait_unlocked() { # the runner holds its lock for its life; wait for it to end
  local i=0
  while ! flock -n "$OUTD/.$PJ.lock" true 2>/dev/null && [ "$i" -lt 60 ]; do sleep 1; i=$((i + 1)); done
}

echo "--- L1: refused cases start nothing"
lcase() { # lcase <label> <want-rc> <args...>
  local label="$1" want="$2"; shift 2
  la "$@"
  [ "$RC" = "$want" ] && ok || bad "L1 $label rc $RC, want $want (out=$OUT err=$(cat "$T/err"))"
  [ "$(printf '%s\n' "$OUT" | wc -l)" = 1 ] && ok || bad "L1 $label: not one stdout line: $OUT"
  [ "$want" = 3 ] && { [ "$(jf .result)" = refused ] && ok || bad "L1 $label result (out=$OUT)"; }
  return 0
}
lcase uppercase 3 Fixture-proj
lcase dotdot 3 ../x
lcase space 3 'a b'
lcase not-in-fleet 3 nope
lcase no-checkout-dir 3 other
lcase no-checkout 3 fixture-other
lcase extra-argv 2 "$PJ" --cap-usd 999
lcase two-projects 2 "$PJ" other
lcase status-no-project 2 --status
lcase none 2
lcase status-bad 3 --status ../x
la other; jf .reason | grep -q 'no checkout of other' && ok || bad "L1 no-checkout reason (out=$OUT)"
sleep 1
[ "$(sa_calls claude)" = 0 ] && ok || bad "L1 claude ran $(sa_calls claude) times on a refused case"
[ ! -d "$OUTD/$PJ" ] && ok || bad "L1 a refused case made $OUTD/$PJ"

echo "--- L3a: --status before any run"
la --status "$PJ"
{ [ "$RC" = 0 ] && [ "$(jf .result)" = none ] && [ "$(jf .running)" = false ]; } && ok || bad "L3 --status before a run (rc $RC out=$OUT)"

echo "--- L2: start through the real cmd-run-script"
OUT=$(env_run bash "$T/bin/cmd-run-script.sh" "$PJ" "$(jq -nc --arg p "$PJ" '{script:"security-audit-launch.sh",args:[$p]}')" 91 2>"$T/err"); RC=$?
{ [ "$RC" = 0 ] && [ "$(jf .result)" = ok ] && [ "$(jf .rc)" = 0 ]; } && ok || bad "L2 run_script rc $RC (out=$OUT err=$(cat "$T/err"))"
TAIL=$(jf .tail)
[ "$(jq -r .result <<<"$TAIL" 2>/dev/null)" = started ] && ok || bad "L2 tail is not started: $TAIL"
[ "$(jq -r .out <<<"$TAIL" 2>/dev/null)" = "$OUTD" ] && ok || bad "L2 out is not state/security-audit: $TAIL"

echo "--- L3b: the runner writes the summary, --status reads it"
wait_summary "$OUTD/$PJ/latest-summary.json" && ok || bad "L3 no latest-summary.json in 60 s: $(cat "$T/logs/security-audit-launch.log" 2>/dev/null)"
wait_unlocked
la --status "$PJ"
{ [ "$RC" = 0 ] && [ "$(jf .result)" = ok ]; } && ok || bad "L3 --status rc $RC (out=$OUT)"
[ "$(jf .counts.confirmed)/$(jf .counts.needs_validation)/$(jf .counts.rejected)" = 2/3/1 ] && ok || bad "L3 counts (out=$OUT)"
[ "$(jf .stopped)" = completed ] && ok || bad "L3 stopped (out=$OUT)"
[ "$(jf .sha)" = "${SA_TARGET_SHA:0:12}" ] && ok || bad "L3 sha (out=$OUT)"
[ "$(jf .run)" = 1 ] && [ "$(jf .running)" = false ] && [ "$(jf .project)" = "$PJ" ] && ok || bad "L3 run/running/project (out=$OUT)"
for k in cost_usd duration_min sandbox validators; do
  jq -e --arg k "$k" 'has($k)' <<<"$OUT" >/dev/null 2>&1 && ok || bad "L3 --status has no $k (out=$OUT)"
done
[ ! -e "$T/not-the-out/security-audit" ] && ok || bad "L3 the child used BUILD, not --out"
[ "$(sa_calls claude)" = 1 ] && ok || bad "L3 claude calls $(sa_calls claude), want 1"

echo "--- L6: --status prints no finding text"
LEAK=0
while IFS= read -r t; do
  [ -n "$t" ] && grep -qF -- "$t" <<<"$OUT" && LEAK=1
done < <(jq -r '.[]? | .title, .location | strings' "$SA_FIX/findings.json")
[ "$LEAK" = 0 ] && ok || bad "L6 --status printed a finding field (out=$OUT)"
[ "${#OUT}" -le 300 ] && ok || bad "L6 --status is ${#OUT} bytes, over the 300-byte run_script tail"

echo "--- L8: nothing under the artifact root is a git candidate"
cp "$REPO_DIR/.gitignore" "$T/.gitignore"
grep -q 'security-audit/' <<<"$(git -C "$T" status --porcelain --untracked-files=all 2>/dev/null)" \
  && bad "L8 git sees the artifact: $(git -C "$T" status --porcelain --untracked-files=all | grep security-audit/ | head -3)" || ok

echo "--- L4: a held lock is already-running"
mkdir -p "$OUTD"; exec 8>"$OUTD/.$PJ.lock"
flock -n 8 || bad "L4 the test could not take the lock"
la "$PJ"
{ [ "$RC" = 0 ] && [ "$(jf .result)" = already-running ]; } && ok || bad "L4 rc $RC (out=$OUT)"
la --status "$PJ"
[ "$(jf .running)" = true ] && ok || bad "L4 --status running (out=$OUT)"
# A wrong start would show as run-2 or a second claude call: watch for it, bounded.
i=0; while [ ! -e "$OUTD/$PJ/run-2" ] && [ "$(sa_calls claude)" = 1 ] && [ "$i" -lt 2 ]; do sleep 1; i=$((i + 1)); done
[ ! -e "$OUTD/$PJ/run-2" ] && [ "$(sa_calls claude)" = 1 ] && ok || bad "L4 a held lock started a run"
exec 8>&-

echo "--- L10: a start at an audited sha spends nothing (the runner's dedup)"
la "$PJ"
[ "$(jf .result)" = started ] && ok || bad "L10 rc $RC (out=$OUT)"
i=0; until grep -q '^SKIP already-audited' "$T/logs/security-audit-launch.log" 2>/dev/null || [ "$i" -ge 30 ]; do sleep 1; i=$((i + 1)); done
grep -q '^SKIP already-audited' "$T/logs/security-audit-launch.log" && ok || bad "L10 no SKIP already-audited line"
wait_unlocked
[ "$(sa_calls claude)" = 1 ] && [ ! -e "$OUTD/$PJ/run-2" ] && ok || bad "L10 a dedup hit called claude ($(sa_calls claude))"

echo "--- L5 + L7: a stale lock file starts; the start does not wait on the agent"
[ -e "$OUTD/.$PJ.lock" ] || bad "L5 no stale lock file to test with"
( cd "$T/target" && echo 'console.log("v2")' > app.js && git commit -qam "fixture v2" ) || bad "L7 target commit"
echo sleep > "$T/claude-mode"
S0=$(date +%s)
la "$PJ"
EL=$(( $(date +%s) - S0 ))
{ [ "$RC" = 0 ] && [ "$(jf .result)" = started ]; } && ok || bad "L5 rc $RC (out=$OUT err=$(cat "$T/err"))"
[ "$EL" -lt 10 ] && ok || bad "L7 the launcher took ${EL}s; it must not wait on the run"
i=0; while [ "$(sa_calls claude)" -lt 2 ] && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
[ "$(sa_calls claude)" = 2 ] && ok || bad "L7 the detached runner never reached the agent ($(sa_calls claude) calls): $(tail -5 "$T/logs/security-audit-launch.log" 2>/dev/null)"
la --status "$PJ"
[ "$(jf .running)" = true ] && [ "$(jf .run)" = 1 ] && ok || bad "L7 --status while it runs (out=$OUT)"
la "$PJ"
[ "$(jf .result)" = already-running ] && ok || bad "L7 a second start while it runs (out=$OUT)"

echo "--- L9: an unreadable summary is failed, never none"
kill_ours
wait_unlocked
echo '{not json' > "$OUTD/$PJ/latest-summary.json"
la --status "$PJ"
{ [ "$RC" = 1 ] && [ "$(jf .result)" = failed ]; } && ok || bad "L9 rc $RC (out=$OUT)"

echo "security-audit-launch.bh-8375: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
