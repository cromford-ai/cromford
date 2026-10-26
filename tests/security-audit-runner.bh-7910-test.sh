#!/bin/bash
# tests/security-audit-runner.bh-7910-test.sh — BH-7910: bin/security-audit.sh
# end to end through the real bin/agent-call.sh with a stub claude, plus the
# pure helpers of bin/lib/security-audit.sh and the sandbox detect table of
# bin/security-audit-sandbox.sh.
#
#   R1  a run writes summary.json: counts 2/3/1 from the fixture findings.json,
#       stopped completed, sha = the target's main, the default caps 60/240
#       from the conf, validators 0/0, every summary key present
#   R2  sandbox.txt names the mode `bin/security-audit-sandbox.sh --detect` picks
#   R3  the target's .claude/, CLAUDE.md, sub/CLAUDE.md, .mcp.json are gone at
#       claude time and listed in neutralized.txt; the skill is installed
#   R4  the scratch clone is removed; the target repo is unchanged; 0 gh calls
#   R5  dedup: a second run at the same sha makes 0 claude calls and prints
#       SKIP already-audited; --again, another skill_sha, a capped run and an
#       invalid summary.json each make 1 call
#   R6  validators: node rc 1 is recorded as 1
#   R7  an agent failure is stopped failed, rc 5, never completed
#   R8  sa_counts: missing file, an object, .findings, an unknown verdict, []
#   R9  sa_caps: flag > settings row > conf; a non-positive value is rc 2; a
#       flag with a leading zero (05) is recorded as the number 5
#   R10 the sandbox detect table (4 cases) with PATH stubs; none refuses to run
#   R11 --help prints the header usage; a bad project is rc 2
#   R12 a session that ends rc 0 with no AUDIT DONE line is stopped incomplete,
#       rc 0, and dedup does not count it (the next run makes 1 call)
#   R13 a run while another holds the project lock prints SKIP already-running
#       and makes 0 claude calls
#   R14 the sandbox caps come from the conf keys (sandbox_memory_kb,
#       sandbox_cpus, sandbox_cpu_s, sandbox_file_kb); fallbacks without them
#   R15 _sa_ledger_usd reads a quoted field that holds a comma
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/security-audit-runner.bh-7910-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/security-audit-fixture.sh" || exit 1
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq git; do command -v "$c" >/dev/null 2>&1 || { echo "$c missing — skipping"; exit 0; }; done

PJ=fixture-proj
sa_fixture_setup "$PJ" || { echo "FAIL: fixture setup"; exit 1; }
OUT="$T/out"
TARGET_REFS=$(git -C "$T/target" show-ref)

# ── R1..R4: one full run ─────────────────────────────────────────────────────
RC=$(sa_run "$PJ" --out "$OUT")
S="$OUT/$PJ/run-1/summary.json"
[ "$RC" = 0 ] && ok || bad "R1 rc $RC, want 0: $(cat "$T/run.out")"
[ -f "$S" ] && ok || bad "R1 no $S"
j() { jq -r "$1" "$S" 2>/dev/null; }
[ "$(j .counts.confirmed)" = 2 ] && ok || bad "R1 confirmed $(j .counts.confirmed), want 2"
[ "$(j .counts.needs_validation)" = 3 ] && ok || bad "R1 needs_validation $(j .counts.needs_validation), want 3"
[ "$(j .counts.rejected)" = 1 ] && ok || bad "R1 rejected $(j .counts.rejected), want 1"
[ "$(j .stopped)" = completed ] && ok || bad "R1 stopped $(j .stopped), want completed"
[ "$(j .sha)" = "$SA_TARGET_SHA" ] && ok || bad "R1 sha $(j .sha), want $SA_TARGET_SHA"
[ "$(j .skill_sha)" = "$SA_PIN" ] && ok || bad "R1 skill_sha $(j .skill_sha)"
[ "$(j .caps.usd)" = 60 ] && [ "$(j .caps.minutes)" = 240 ] && ok || bad "R1 caps $(j .caps), want 60/240 from the conf"
[ "$(j .validators.findings)" = 0 ] && [ "$(j .validators.ledger)" = 0 ] && ok || bad "R1 validators $(j -c .validators)"
for k in project run sha started ended duration_min cost_usd stopped sandbox counts validators; do
  jq -e --arg k "$k" 'has($k)' "$S" >/dev/null 2>&1 && ok || bad "R1 summary has no key $k"
done
[ "$(j .project)" = "$PJ" ] && [ "$(j .run)" = 1 ] && ok || bad "R1 project/run $(j .project)/$(j .run)"
cmp -s "$S" "$OUT/$PJ/latest-summary.json" && ok || bad "R1 latest-summary.json is not the run's summary"
[ "$(sa_calls claude)" = 1 ] && ok || bad "R1 claude calls $(sa_calls claude), want 1"
grep -q "Output directory: \`$OUT/$PJ/run-1\`" "$T/claude-prompt" && ok || bad "R1 the prompt does not name the run dir"
NV=$(grep -c 'skills/security-audit' "$T/node-calls" 2>/dev/null)
[ "$NV" = 2 ] && ok || bad "R1 want 2 validator calls, got $NV"
grep -q "\[$PJ\] audit\|,$PJ,audit," "$T/logs/cost.csv" && ok || bad "R1 agent-call wrote no audit cost row"

# R2: the sandbox the box has.
WANT=$("$REPO_DIR/bin/security-audit-sandbox.sh" --detect)
[ "$(awk 'NR==1{print $1}' "$OUT/$PJ/run-1/sandbox.txt" | tr -d :)" = "$WANT" ] && ok \
  || bad "R2 sandbox.txt '$(head -1 "$OUT/$PJ/run-1/sandbox.txt")' does not start with $WANT"
[ "$(j .sandbox)" = "$WANT" ] && ok || bad "R2 summary sandbox $(j .sandbox), want $WANT"

# R3: neutralized before the session, and listed.
grep -qx 'CLAUDE.md' "$T/claude-ls" && bad "R3 CLAUDE.md was present at claude time" || ok
grep -qx '.mcp.json' "$T/claude-ls" && bad "R3 .mcp.json was present at claude time" || ok
grep -qx 'CLAUDE.md' "$T/claude-ls-sub" && bad "R3 sub/CLAUDE.md was present at claude time" || ok
[ "$(cat "$T/claude-ls-skills")" = security-audit ] && ok || bad "R3 .claude/skills holds '$(cat "$T/claude-ls-skills")', want only security-audit"
for p in .claude CLAUDE.md sub/CLAUDE.md .mcp.json; do
  grep -qx "$p" "$OUT/$PJ/run-1/neutralized.txt" && ok || bad "R3 neutralized.txt does not list $p"
done
[ "$(sa_calls npx)" = 1 ] && ok || bad "R3 npx calls $(sa_calls npx), want 1"
grep -q "skills@1.7.4 add $T/out/$PJ/.skill-" "$T/npx-calls" && ok || bad "R3 npx did not install the pinned CLI from the verified clone: $(cat "$T/npx-calls")"

# R4: no scratch left, the target untouched, no board call.
LEFT=$(ls -A "$OUT/$PJ" | grep '^\.' | tr '\n' ' ')
[ -z "$LEFT" ] && ok || bad "R4 scratch left behind: $LEFT"
[ "$(git -C "$T/target" show-ref)" = "$TARGET_REFS" ] && ok || bad "R4 the target refs changed"
[ -z "$(git -C "$T/target" status --porcelain)" ] && [ -f "$T/target/CLAUDE.md" ] && ok || bad "R4 the target work tree changed"
[ "$(sa_calls gh)" = 0 ] && ok || bad "R4 gh was called $(sa_calls gh) times"
grep -q "$PJ run-1 .*stopped=completed" "$T/logs/security-audit.log" && ok || bad "R4 no log line"

# ── R5: dedup before spend ───────────────────────────────────────────────────
RC=$(sa_run "$PJ" --out "$OUT")
[ "$RC" = 0 ] && ok || bad "R5 skip rc $RC"
grep -q "^SKIP already-audited $OUT/$PJ/run-1/summary.json" "$T/run.out" && ok || bad "R5 no SKIP line: $(cat "$T/run.out")"
[ "$(sa_calls claude)" = 1 ] && ok || bad "R5 a dedup hit called claude ($(sa_calls claude) calls)"
[ ! -e "$OUT/$PJ/run-2" ] && ok || bad "R5 a dedup hit made run-2"

RC=$(sa_run "$PJ" --out "$OUT" --again)
[ "$RC" = 0 ] && [ "$(sa_calls claude)" = 2 ] && [ -f "$OUT/$PJ/run-2/summary.json" ] && ok || bad "R5 --again did not run (rc $RC, calls $(sa_calls claude))"

# Negatives: each must run. Rewrite every existing summary to the case.
dedup_case() { # dedup_case <label> <jq edit>
  local s before
  for s in "$OUT/$PJ"/run-*/summary.json; do
    if [ "$2" = invalid ]; then echo '{not json' > "$s"; else jq "$2" "$s" > "$s.t" && mv "$s.t" "$s"; fi
  done
  before=$(sa_calls claude)
  RC=$(sa_run "$PJ" --out "$OUT")
  [ "$RC" = 0 ] && [ "$(sa_calls claude)" = $((before + 1)) ] && ok || bad "R5 $1: want 1 call, got $(( $(sa_calls claude) - before )) (rc $RC): $(tail -3 "$T/run.out")"
  for s in "$OUT/$PJ"/run-*; do scratch_rm "$s"; done
  mkdir -p "$OUT/$PJ/run-1"; cp "$OUT/$PJ/latest-summary.json" "$OUT/$PJ/run-1/summary.json"
}
dedup_case "another skill_sha" '.skill_sha = "0000000000000000000000000000000000000000"'
dedup_case "a capped run" '.stopped = "cap-usd"'
dedup_case "an older target sha" '.sha = "1111111111111111111111111111111111111111"'
dedup_case "an invalid summary.json" invalid

# ── R6: a validator failure is recorded ──────────────────────────────────────
echo 1 > "$T/node-rc"
RC=$(sa_run "$PJ" --out "$OUT" --again)
S=$(ls -d "$OUT/$PJ"/run-* | sort -V | tail -1)/summary.json
[ "$(jq -r .validators.findings "$S")" = 1 ] && [ "$(jq -r .validators.ledger "$S")" = 1 ] && ok || bad "R6 validators $(jq -c .validators "$S"), want 1/1"
rm -f "$T/node-rc"

# ── R7: an agent failure ─────────────────────────────────────────────────────
echo fail > "$T/claude-mode"
RC=$(sa_run "$PJ" --out "$OUT" --again)
S=$(ls -d "$OUT/$PJ"/run-* | sort -V | tail -1)/summary.json
[ "$RC" = 5 ] && ok || bad "R7 rc $RC, want 5"
[ "$(jq -r .stopped "$S")" = failed ] && ok || bad "R7 stopped $(jq -r .stopped "$S"), want failed"
[ "$(jq -r .counts.confirmed "$S")" = null ] && ok || bad "R7 counts of a run with no findings.json are not null"
jq -r .failed_reason "$S" | grep -q 'agent-call' && ok || bad "R7 failed_reason $(jq -r .failed_reason "$S")"
rm -f "$T/claude-mode"

# ── R8: sa_counts ────────────────────────────────────────────────────────────
. "$REPO_DIR/bin/lib/security-audit.sh" || { echo "FAIL: cannot source the lib"; exit 1; }
C=$(sa_counts "$T/nope.json")
[ "$(jq -r .confirmed <<<"$C")" = null ] && jq -r .note <<<"$C" | grep -q missing && ok || bad "R8 missing file: $C"
echo '{"a":1}' > "$T/obj.json"; C=$(sa_counts "$T/obj.json")
[ "$(jq -r .rejected <<<"$C")" = null ] && ok || bad "R8 an object is not null: $C"
echo '{"findings":[{"verdict":"confirmed"},{"verdict":"maybe"}]}' > "$T/wrapped.json"; C=$(sa_counts "$T/wrapped.json")
[ "$(jq -r .confirmed <<<"$C")" = 1 ] && [ "$(jq -r .needs_validation <<<"$C")" = 0 ] && jq -r .note <<<"$C" | grep -q 'maybe x1' && ok || bad "R8 .findings + unknown verdict: $C"
echo '[]' > "$T/empty.json"; C=$(sa_counts "$T/empty.json")
[ "$(jq -c '[.confirmed,.needs_validation,.rejected]' <<<"$C")" = '[0,0,0]' ] && ok || bad "R8 [] is not 0/0/0: $C"
echo 'not json' > "$T/bad.json"; C=$(sa_counts "$T/bad.json")
[ "$(jq -r .confirmed <<<"$C")" = null ] && ok || bad "R8 invalid JSON is not null: $C"

# ── R9: sa_caps precedence ───────────────────────────────────────────────────
[ "$(sa_caps 5 7 "$T/sa.conf")" = "5 7 flag flag" ] && ok || bad "R9 flags: $(sa_caps 5 7 "$T/sa.conf")"
setting_get() { case "$1" in security_audit.cap_usd) printf 12 ;; *) return 2 ;; esac; }
[ "$(sa_caps "" "" "$T/sa.conf")" = "12 240 setting:security_audit.cap_usd conf" ] && ok || bad "R9 row > conf: $(sa_caps "" "" "$T/sa.conf")"
unset -f setting_get
sa_caps 0 7 "$T/sa.conf" >/dev/null 2>&1; [ $? = 2 ] && ok || bad "R9 cap 0 is not rc 2"
sa_caps abc 7 "$T/sa.conf" >/dev/null 2>&1; [ $? = 2 ] && ok || bad "R9 cap abc is not rc 2"
RC=$(sa_run "$PJ" --out "$OUT" --cap-usd -5)
[ "$RC" = 2 ] && ok || bad "R9 the runner took --cap-usd -5 (rc $RC)"
RC=$(sa_run "$PJ" --out "$OUT" --cap-usd 05 --again)
S=$(ls -d "$OUT/$PJ"/run-* | sort -V | tail -1)/summary.json
[ "$RC" = 0 ] && [ "$(jq -r .caps.usd "$S")" = 5 ] && ok || bad "R9 --cap-usd 05: rc $RC, caps $(jq -c .caps "$S" 2>/dev/null)"

# ── R10: the sandbox detect table ────────────────────────────────────────────
SB="$T/sbstub"; mkdir -p "$SB"
printf '#!/bin/bash\nexit "$(cat %s/docker-rc)"\n' "$SB" > "$SB/docker"
printf '#!/bin/bash\nexit "$(cat %s/unshare-rc)"\n' "$SB" > "$SB/unshare"
printf '#!/bin/bash\nexec /bin/cat "$@"\n' > "$SB/cat"
chmod +x "$SB/docker" "$SB/unshare" "$SB/cat"
detect_case() { # detect_case <docker-rc|absent> <unshare-rc> <want>
  rm -f "$SB/docker.off"
  if [ "$1" = absent ]; then mv "$SB/docker" "$SB/docker.off"; else echo "$1" > "$SB/docker-rc"; fi
  echo "$2" > "$SB/unshare-rc"
  local got; got=$(PATH="$SB" /bin/bash "$REPO_DIR/bin/security-audit-sandbox.sh" --detect)
  [ -f "$SB/docker.off" ] && mv "$SB/docker.off" "$SB/docker"
  [ "$got" = "$3" ] && ok || bad "R10 docker=$1 unshare=$2: got '$got', want $3"
}
detect_case 0 0 docker
detect_case 1 0 unshare-n
detect_case absent 0 unshare-n
detect_case 1 1 none
mkdir -p "$T/sbwork"
"$REPO_DIR/bin/security-audit-sandbox.sh" none "$T/sbwork" -- touch "$T/sbwork/ran" 2>/dev/null; RCN=$?
[ "$RCN" = 3 ] && [ ! -e "$T/sbwork/ran" ] && ok || bad "R10 mode none ran the command (rc $RCN)"
"$REPO_DIR/bin/security-audit-sandbox.sh" --describe none | grep -q 'executes nothing; a valid pilot outcome, not a failure' && ok || bad "R10 the none text"

# ── R11: CLI ─────────────────────────────────────────────────────────────────
H1=$(bash "$REPO_DIR/bin/security-audit.sh" --help | head -1)
[ "$H1" = "usage: security-audit.sh <project> [--out <dir>] [--cap-usd <n>] [--cap-minutes <n>] [--again]" ] && ok || bad "R11 --help: $H1"
RC=$(sa_run 'Bad/Proj' --out "$OUT"); [ "$RC" = 2 ] && ok || bad "R11 a bad project is rc $RC"

# ── R12: no AUDIT DONE line ──────────────────────────────────────────────────
echo nodone > "$T/claude-mode"
RC=$(sa_run "$PJ" --out "$OUT" --again)
S=$(ls -d "$OUT/$PJ"/run-* | sort -V | tail -1)/summary.json
[ "$RC" = 0 ] && ok || bad "R12 rc $RC, want 0"
[ "$(jq -r .stopped "$S")" = incomplete ] && ok || bad "R12 stopped $(jq -r .stopped "$S"), want incomplete"
jq -r .failed_reason "$S" | grep -q 'AUDIT DONE' && ok || bad "R12 failed_reason $(jq -r .failed_reason "$S")"
rm -f "$T/claude-mode"
# Only run-1 (and R9's --again runs) are completed; move them so the next run
# finds just the incomplete one at this sha.
mkdir -p "$T/held"
for d in "$OUT/$PJ"/run-*; do [ "$(jq -r .stopped "$d/summary.json")" = completed ] && mv "$d" "$T/held/"; done
N0=$(sa_calls claude)
RC=$(sa_run "$PJ" --out "$OUT")
[ "$RC" = 0 ] && [ "$(( $(sa_calls claude) - N0 ))" = 1 ] && ok || bad "R12 dedup counted an incomplete run (rc $RC, calls $(( $(sa_calls claude) - N0 )))"

# ── R13: one run per project at a time ───────────────────────────────────────
N0=$(sa_calls claude)
exec 8>"$OUT/.$PJ.lock"; flock -n 8 || bad "R13 cannot take the lock"
RC=$(sa_run "$PJ" --out "$OUT" --again)
exec 8>&-
[ "$RC" = 0 ] && grep -q "SKIP already-running $PJ" "$T/run.out" && ok || bad "R13 rc $RC: $(cat "$T/run.out")"
[ "$(sa_calls claude)" = "$N0" ] && ok || bad "R13 a locked run called claude"

# ── R14: sandbox caps are conf keys ──────────────────────────────────────────
printf 'sandbox_memory_kb=1234\nsandbox_cpus=3\nsandbox_cpu_s=99\nsandbox_file_kb=77\n' > "$T/caps.conf"
D=$(SA_CONF="$T/caps.conf" "$REPO_DIR/bin/security-audit-sandbox.sh" --describe unshare-n)
grep -q 'ulimit -v 1234 KiB memory, -t 99 s CPU, -f 77 KiB per file' <<<"$D" && ok || bad "R14 unshare-n: $D"
D=$(SA_CONF="$T/caps.conf" "$REPO_DIR/bin/security-audit-sandbox.sh" --describe docker)
grep -q 'memory 1234 KiB, 3 cpus' <<<"$D" && ok || bad "R14 docker: $D"
D=$(SA_CONF="$T/nope.conf" "$REPO_DIR/bin/security-audit-sandbox.sh" --describe unshare-n)
grep -q 'ulimit -v 4194304 KiB memory, -t 1800 s CPU, -f 1048576 KiB per file' <<<"$D" && ok || bad "R14 fallbacks: $D"
for k in sandbox_memory_kb sandbox_cpus sandbox_cpu_s sandbox_file_kb agent_timeout_margin_s kill_grace_s; do
  sa_conf_get "$REPO_DIR/catalog/security-audit.conf" "$k" >/dev/null && ok || bad "R14 catalog/security-audit.conf has no $k"
done

# ── R15: the ledger is read as CSV ───────────────────────────────────────────
printf 'ts,host,project,stage,auth_account,cost_usd\n2026-10-25T00:00:00Z,hx,pj,audit,"a,b",1.5\n2026-10-25T00:00:01Z,hx,pj,audit,x,2\n' > "$T/q.csv"
[ "$(_sa_ledger_usd "$T/q.csv" pj hx 2026-10-24T00:00:00Z)" = 3.500000 ] && ok || bad "R15 quoted comma: $(_sa_ledger_usd "$T/q.csv" pj hx 2026-10-24T00:00:00Z)"

echo "security-audit-runner: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
