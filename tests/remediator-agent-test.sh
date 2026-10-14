#!/bin/bash
# tests/remediator-agent-test.sh — TIER 2 of the alert remediation lane.
#
# Tier 1 (bin/remediations/*.sh) is covered by tests/remediation-hook-test.sh.
# This file covers what tier 2 adds: an LLM remediator that may TRY TO FIX, one
# bounded attempt per alert, behind a pilot flag, under a daily spend cap.
#
# The property under test is the same one tier 1 has, and it matters more here
# because tier 2 can act on the world: a remediator must never be able to
# swallow an alert it did not prove settled. So most of what follows is failure
# cases — no evidence, escalate, timeout, crash, unparseable, over cap, killed —
# each asserting the alert still lands in the quarantine file.
#
# THE AGENT IS ALWAYS A STUB. bin/agent-call.sh is replaced by a fixture script
# that echoes canned verdicts. Nothing here makes an LLM call, and the last
# check proves nothing here touched the real ALERTS.log or quarantine file.
# Run from anywhere: tests/remediator-agent-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin/remediations" "$T/prompts" "$T/logs" "$T/state" "$T/flags" "$T/env" "$T/fakebin"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T" project-3 x-os || exit 1  # BH-1510.2: lanes read models from model_routes

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq      >/dev/null 2>&1 || { echo "FAIL: jq required by this test"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required by this test"; exit 1; }

# Real-file tripwire: snapshot the live artifacts BEFORE anything runs.
REALQ=/root/harness/state/alert-quarantine.jsonl
REALA=/root/harness/logs/ALERTS.log
snap() { [ -f "$1" ] && stat -c '%Y %s' "$1" || echo absent; }
Q0=$(snap "$REALQ"); A0=$(snap "$REALA")

cp "$DIR/bin/beat.sh" "$DIR/bin/remediate-agent.sh" "$T/bin/"
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$T/bin/lib/"
cp "$DIR/bin/remediator-settings.json" "$T/bin/"
cp "$DIR/prompts/remediator.md" "$T/prompts/"

# beat.sh bounds tier 1 at `timeout 60` and tier 2 at `timeout 360`. Shrink both
# to 2s so the timeout cases are REAL SIGTERMs rather than mocked exit codes,
# without making the suite take six minutes.
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
shift              # drop beat.sh's bound
exec /usr/bin/timeout 2 "$@"
EOF
chmod +x "$T/fakebin/timeout"

# ---- THE STUB. This is the only agent this suite ever runs. ----------------
# It records how it was called (including its CWD and the tool policy it was
# handed), copies the rendered prompt out for inspection, writes the canned
# transcript to the outfile, and exits with the canned rc.
cat > "$T/bin/agent-call.sh" <<'EOF'
#!/bin/bash
H="${HARNESS:?stub needs HARNESS}"
printf 'stage=%s project=%s model=%s timeout=%s out=%s cwd=%s\n' \
  "$1" "$2" "$3" "$4" "$5" "$PWD" >> "$H/AGENT_CALLS"
case "${6:-}" in @/*) cp "${6#@}" "$H/LAST_PROMPT" 2>/dev/null ;; esac
printf '%s' "${AGENT_SETTINGS:-}"          > "$H/LAST_SETTINGS"
printf '%s' "${AGENT_DISALLOWED_TOOLS:-}"  > "$H/LAST_DENY"
printf '%s' "${AGENT_SYSTEM_APPEND:-}"     > "$H/LAST_SYSAPPEND"
cat "$H/AGENT_SCENARIO" > "$5" 2>/dev/null
exit "$(cat "$H/AGENT_RC" 2>/dev/null || echo 0)"
EOF
chmod +x "$T/bin/agent-call.sh"

Q="$T/state/alert-quarantine.jsonl"
RLOG="$T/logs/remediation.log"

handler() { # handler <name> <body>
  printf '#!/bin/bash\n%s\n' "$2" > "$T/bin/remediations/$1.sh"
  chmod +x "$T/bin/remediations/$1.sh"
}
payload() { # payload <akey>
  jq -nc --arg k "$1" '{kind:"fleet_alert",project:"x-os",akey:$k,line:"a line about \($k)"}'
}
fire() { # fire <payload-json> [extra env assignments...]
  HARNESS="$T" PATH="$T/fakebin:$PATH" env "${FIRE_ENV[@]}" bash "$T/bin/beat.sh" "$1"
}
FIRE_ENV=()

scenario() { # scenario <rc> ; canned transcript on stdin
  echo "$1" > "$T/AGENT_RC"; cat > "$T/AGENT_SCENARIO"
}
agent_on()  { touch "$T/flags/remediation-agent-enabled"; }
agent_off() { rm -f "$T/flags/remediation-agent-enabled"; }

reset() {
  : > "$Q"; : > "$RLOG"; : > "$T/AGENT_CALLS"
  rm -f "$T/state/remediation-attempts.tsv" "$T/flags/remediation-disabled"
  rm -f "$T/state"/remediation-agent-*.count* "$T/LAST_PROMPT"
  # this suite fires one identical payload across most of its sections, so the
  # tier-2 payload dedup ledger is cross-run state like every line above it
  rm -f "$T/state/remediation-payload-dedup.tsv"*
  rm -rf "$T/bin/remediations"/*.sh "$T/logs/remediator" "$T/state/remediation-scratch"
  FIRE_ENV=()
}

quarantined() { grep -qF "\"akey\":\"$1\"" "$Q" 2>/dev/null; }
logged()      { grep -qE "	$1	.*	$2" "$RLOG" 2>/dev/null; }
calls()       { grep -c . "$T/AGENT_CALLS" 2>/dev/null; }   # grep -c prints 0 and exits 1 on empty; the 0 is the answer

# ---------- 1. the pilot flag is the whole gate ------------------------------
# Default-off is the fleet's state after this ships. Nothing about tier 2 may
# happen on a box where nobody created the flag.
reset; agent_off
scenario 0 <<'EOF'
EVIDENCE: re-ran it, gone
VERDICT: REMEDIATED nothing to see
EOF
fire "$(payload 'nohandler:z')"
[ "$(calls)" -eq 0 ] && ok || bad "tier 2 ran with the pilot flag ABSENT — the pilot is not opt-in"
quarantined 'nohandler:z' && ok || bad "flag off: the alert must page exactly as it does today"
[ ! -s "$T/state/remediation-attempts.tsv" ] && ok \
  || bad "flag off + no handler burned a throttle claim"
[ ! -s "$RLOG" ] && ok || bad "flag off wrote a remediation.log line: $(cat "$RLOG")"

# ---------- 2. REMEDIATED with evidence suppresses ---------------------------
reset; agent_on
scenario 0 <<'EOF'
I looked at the lane and re-ran its check.
EVIDENCE: gh pr view 229 --json state -> {"state":"MERGED"}
VERDICT: REMEDIATED the PR this alert names was merged an hour ago
EOF
fire "$(payload 'nohandler:z')"
if quarantined 'nohandler:z'; then bad "an evidenced REMEDIATED did not suppress"; else ok; fi
[ "$(calls)" -eq 1 ] && ok || bad "expected exactly one agent call, got $(calls)"
logged 'nohandler:z' 'REMEDIATED' && ok || bad "REMEDIATED not logged: $(cat "$RLOG")"
grep -q 'the PR this alert names was merged' "$RLOG" && ok || bad "the agent's summary is missing from remediation.log"
grep -q 'evidence: gh pr view 229' "$RLOG" && ok || bad "the quoted evidence is missing from remediation.log"

# the lane it was dispatched through is agent-call's `remediate` stage, at 300s
grep -q 'stage=remediate ' "$T/AGENT_CALLS" && ok \
  || bad "tier 2 did not go through agent-call's remediate stage: $(cat "$T/AGENT_CALLS")"
grep -q ' timeout=300 ' "$T/AGENT_CALLS" && ok \
  || bad "tier 2 was not bounded at 300s: $(cat "$T/AGENT_CALLS")"

# ...and it ran in a scratch dir, never a repo checkout
CWD=$(sed -n 's/.* cwd=//p' "$T/AGENT_CALLS" | head -1)
case "$CWD" in "$T/state/remediation-scratch"/*) ok ;; *) bad "the agent ran in '$CWD', not a scratch dir" ;; esac
[ ! -d "$CWD/.git" ] && ok || bad "the agent's working dir is a git checkout"

# ...and the transcript path it logged is a real, readable file
TP=$(sed -n 's/.*transcript=//p' "$RLOG" | head -1)
[ -n "$TP" ] && [ -f "$TP" ] && ok || bad "remediation.log names no readable transcript (got '$TP')"
grep -q 'VERDICT: REMEDIATED' "$TP" 2>/dev/null && ok || bad "the transcript does not contain the run's own output"

# ---------- 3. THE EVIDENCE RULE ---------------------------------------------
# A verdict is a claim. Without a quoted re-check it is an unverifiable claim,
# and an unverifiable claim must never be worth a suppressed alert.
reset; agent_on
scenario 0 <<'EOF'
I am confident this is fine.
VERDICT: REMEDIATED trust me, the machine is gone
EOF
fire "$(payload 'nohandler:z')"
quarantined 'nohandler:z' && ok || bad "REMEDIATED with NO EVIDENCE line suppressed the alert"
logged 'nohandler:z' 'FAILOPEN-noevidence' && ok || bad "unevidenced REMEDIATED not logged as FAILOPEN-noevidence: $(cat "$RLOG")"
grep -qF '[remediator tried:' "$Q" && ok || bad "the downgraded verdict did not enrich the page"

# TERMINAL suppresses just as completely, so it needs evidence just as much.
reset; agent_on
scenario 0 <<'EOF'
VERDICT: TERMINAL this is an expected end state
EOF
fire "$(payload 'nohandler:z')"
quarantined 'nohandler:z' && ok || bad "TERMINAL with NO EVIDENCE line suppressed the alert"

reset; agent_on
scenario 0 <<'EOF'
EVIDENCE: cat builds/x/RESULT -> BUILD_DEFERRED all 3 slots busy
VERDICT: TERMINAL a deferred build owes no close-out
EOF
fire "$(payload 'nohandler:z')"
if quarantined 'nohandler:z'; then bad "an evidenced TERMINAL did not suppress"; else ok; fi
logged 'nohandler:z' 'TERMINAL' && ok || bad "evidenced TERMINAL not logged as TERMINAL: $(cat "$RLOG")"

# ---------- 4. ESCALATE pages, and the page arrives enriched -----------------
reset; agent_on
scenario 0 <<'EOF'
EVIDENCE: ssh root@box-project-3-1 true -> exit 255
VERDICT: ESCALATE box is genuinely down, ssh refused twice; needs a console reboot
EOF
fire "$(payload 'nohandler:z')"
quarantined 'nohandler:z' && ok || bad "ESCALATE swallowed the alert — fail-open is broken"
grep -qF '[remediator tried: box is genuinely down' "$Q" \
  && ok || bad "ESCALATE did not append the diagnosis to the alert line: $(cat "$Q")"
# the original line survives alongside the diagnosis
grep -qF 'a line about nohandler:z [remediator tried:' "$Q" \
  && ok || bad "enrichment replaced the alert line instead of extending it"
logged 'nohandler:z' 'FAILOPEN-escalate' && ok || bad "ESCALATE not logged as FAILOPEN-escalate: $(cat "$RLOG")"

# ---------- 5. timeout, crash, and unparseable all page ----------------------
reset; agent_on
scenario 124 <<'EOF'
EOF
fire "$(payload 'nohandler:z')"
quarantined 'nohandler:z' && ok || bad "an agent timeout suppressed the alert"
logged 'nohandler:z' 'FAILOPEN-timeout' && ok || bad "timeout not logged as FAILOPEN-timeout: $(cat "$RLOG")"
grep -qF '[remediator tried:' "$Q" && ok || bad "a timed-out attempt did not say so on the page"

# a non-zero lane NEVER suppresses, even when the text in the file says REMEDIATED
reset; agent_on
scenario 1 <<'EOF'
EVIDENCE: something
VERDICT: REMEDIATED all good
EOF
fire "$(payload 'nohandler:z')"
quarantined 'nohandler:z' && ok || bad "a crashed agent-call was allowed to suppress on leftover text"
logged 'nohandler:z' 'FAILOPEN-crash' && ok || bad "a non-zero agent lane not logged as FAILOPEN-crash: $(cat "$RLOG")"

# no VERDICT line at all
reset; agent_on
scenario 0 <<'EOF'
I thought about it for a while and then wandered off.
EOF
fire "$(payload 'nohandler:z')"
quarantined 'nohandler:z' && ok || bad "an answer with no VERDICT line suppressed the alert"
logged 'nohandler:z' 'FAILOPEN-parse' && ok || bad "missing VERDICT not logged as FAILOPEN-parse: $(cat "$RLOG")"

# a verdict word nobody defined
reset; agent_on
scenario 0 <<'EOF'
EVIDENCE: whatever
VERDICT: PROBABLY_FINE I would not worry about it
EOF
fire "$(payload 'nohandler:z')"
quarantined 'nohandler:z' && ok || bad "an unknown verdict word suppressed the alert"

# the wrapper KILLED mid-run still leaves a record and still pages
reset; agent_on
cat > "$T/bin/agent-call.sh" <<'EOF'
#!/bin/bash
sleep 30   # determinism: ok the hang IS the fixture — beat.sh's outer bound must kill it
EOF
chmod +x "$T/bin/agent-call.sh"
fire "$(payload 'nohandler:z')"
quarantined 'nohandler:z' && ok || bad "a wrapper killed at beat.sh's outer bound suppressed the alert"
logged 'nohandler:z' 'FAILOPEN-timeout' && ok \
  || bad "beat.sh logged nothing for a wrapper it killed — the attempt would be invisible: $(cat "$RLOG")"
# restore the recording stub for the rest of the suite
cat > "$T/bin/agent-call.sh" <<'EOF'
#!/bin/bash
H="${HARNESS:?stub needs HARNESS}"
printf 'stage=%s project=%s model=%s timeout=%s out=%s cwd=%s\n' \
  "$1" "$2" "$3" "$4" "$5" "$PWD" >> "$H/AGENT_CALLS"
case "${6:-}" in @/*) cp "${6#@}" "$H/LAST_PROMPT" 2>/dev/null ;; esac
printf '%s' "${AGENT_SETTINGS:-}"          > "$H/LAST_SETTINGS"
printf '%s' "${AGENT_DISALLOWED_TOOLS:-}"  > "$H/LAST_DENY"
printf '%s' "${AGENT_SYSTEM_APPEND:-}"     > "$H/LAST_SYSAPPEND"
cat "$H/AGENT_SCENARIO" > "$5" 2>/dev/null
exit "$(cat "$H/AGENT_RC" 2>/dev/null || echo 0)"
EOF
chmod +x "$T/bin/agent-call.sh"

# ---------- 6. the two tiers share ONE attempt per akey per 6h ---------------
# The throttle is a bound on remediation, not on handlers. A key that has had a
# static attempt and an agent attempt has had its attempt.
reset; agent_on
handler counted 'echo "not provably gone" >> '"$T"'/COUNT; exit 1'
: > "$T/COUNT"
scenario 0 <<'EOF'
EVIDENCE: ssh -> 255
VERDICT: ESCALATE still down
EOF
fire "$(payload 'counted:k1')"
[ "$(wc -l < "$T/COUNT")" -eq 1 ] && ok || bad "tier 1 did not run before tier 2"
[ "$(calls)" -eq 1 ] && ok || bad "tier 2 did not pick up an alert tier 1 failed open on"
fire "$(payload 'counted:k1')"
fire "$(payload 'counted:k1')"
[ "$(wc -l < "$T/COUNT")" -eq 1 ] && ok || bad "the handler ran again inside the shared 6h window"
[ "$(calls)" -eq 1 ] && ok || bad "the agent ran again inside the shared 6h window ($(calls) calls)"
[ "$(grep -c 'counted:k1' "$Q")" -eq 3 ] && ok \
  || bad "throttled repeats must still page ($(grep -c 'counted:k1' "$Q") of 3)"
# the claim is ONE row, not one per tier
[ "$(grep -c 'counted:k1' "$T/state/remediation-attempts.tsv")" -eq 1 ] && ok \
  || bad "the two tiers each claimed the window separately"

# a settled tier 1 never reaches tier 2 — no LLM call is made for free
reset; agent_on
handler settled 'echo "machine is gone"; exit 0'
fire "$(payload 'settled:m1')"
[ "$(calls)" -eq 0 ] && ok || bad "tier 2 ran even though tier 1 settled the alert"
if quarantined 'settled:m1'; then bad "tier 1 exit 0 stopped suppressing"; else ok; fi

# ---------- 7. the daily cap ------------------------------------------------
# The 6h throttle bounds one akey. Nothing in it bounds an alert STORM across
# hundreds of distinct akeys, which is exactly the shape that turns a helpful
# lane into an unbounded bill.
reset; agent_on
scenario 0 <<'EOF'
EVIDENCE: ssh -> 255
VERDICT: ESCALATE still down
EOF
FIRE_ENV=(REMEDIATE_DAILY_CAP=2)
fire "$(payload 'storm:a')"
fire "$(payload 'storm:b')"
[ "$(calls)" -eq 2 ] && ok || bad "the first two runs under a cap of 2 did not both run ($(calls))"
fire "$(payload 'storm:c')"
[ "$(calls)" -eq 2 ] && ok || bad "the cap of 2 let a third agent run through ($(calls))"
quarantined 'storm:c' && ok || bad "an alert over the daily cap was suppressed instead of paging"
logged 'storm:c' 'FAILOPEN-cap' && ok || bad "the capped run is not visible in remediation.log: $(cat "$RLOG")"
[ "$(cat "$T/state/remediation-agent-$(date -u +%Y%m%d).count")" = 2 ] && ok \
  || bad "the counter is not the cap's own state"

# the default is 20 when nothing overrides it
grep -q 'REMEDIATE_DAILY_CAP:-20' "$DIR/bin/remediate-agent.sh" \
  && ok || bad "the documented default daily cap of 20 is not in the code"

# ---------- 8. one kill switch kills BOTH tiers ------------------------------
reset; agent_on
handler killme 'echo "would have suppressed"; exit 0'
: > "$T/COUNT"
touch "$T/flags/remediation-disabled"
fire "$(payload 'killme:1')"
quarantined 'killme:1' && ok || bad "flags/remediation-disabled did not bypass tier 1"
[ "$(calls)" -eq 0 ] && ok || bad "flags/remediation-disabled did not bypass tier 2"
[ ! -s "$RLOG" ] && ok || bad "the kill switch still produced a log line: $(cat "$RLOG")"

# ...and directly, so a switch that only holds on one call path is caught
OUTD=$(HARNESS="$T" bash "$T/bin/remediate-agent.sh" 'killme:1' 'line' '{}' 2>&1); RCD=$?
[ "$RCD" -ne 0 ] && [ "$RCD" -ne 10 ] && ok || bad "remediate-agent run directly ignored the kill switch (rc=$RCD)"
grep -qi 'kill switch' <<<"$OUTD" && ok || bad "the direct refusal does not say why: $OUTD"
rm -f "$T/flags/remediation-disabled"

# ...and the pilot flag holds on the direct path too
reset; agent_off
OUTD=$(HARNESS="$T" bash "$T/bin/remediate-agent.sh" 'any:1' 'line' '{}' 2>&1); RCD=$?
[ "$RCD" -ne 0 ] && [ "$RCD" -ne 10 ] && ok || bad "remediate-agent run directly ignored the pilot flag (rc=$RCD)"
[ "$(calls)" -eq 0 ] && ok || bad "remediate-agent called the runner with the pilot flag absent"

# ---------- 9. what the agent is actually handed -----------------------------
reset; agent_on
scenario 0 <<'EOF'
EVIDENCE: x
VERDICT: ESCALATE y
EOF
P=$(jq -nc '{kind:"fleet_alert",project:"project-3",akey:"migration:example-org/project-3#229",line:"PR #229 shipped migration SQL"}')
fire "$P"
[ -s "$T/LAST_PROMPT" ] && ok || bad "the rendered prompt was never handed to the runner"
grep -qF 'migration:example-org/project-3#229' "$T/LAST_PROMPT" && ok || bad "the prompt does not carry the akey"
grep -qF 'PR #229 shipped migration SQL' "$T/LAST_PROMPT" && ok || bad "the prompt does not carry the alert line"
grep -qF '"project":"project-3"' "$T/LAST_PROMPT" && ok || bad "the prompt does not carry the payload JSON"
grep -q '{{' "$T/LAST_PROMPT" && bad "an unsubstituted {{PLACEHOLDER}} survived into the prompt" || ok

# the tool policy, from ONE file, on both the flags and the settings path
[ "$(cat "$T/LAST_SETTINGS")" = "$T/bin/remediator-settings.json" ] && ok \
  || bad "the runner was not handed the remediator settings file: $(cat "$T/LAST_SETTINGS")"
grep -qF 'Bash(gh pr merge:*)' "$T/LAST_DENY" && ok || bad "gh pr merge is not in the runner's deny list"
grep -qF 'Bash(git push origin main:*)' "$T/LAST_DENY" && ok || bad "push-to-main is not in the runner's deny list"
# BH-2741: no push of any kind — the rebase train pushes, through its hold check.
grep -qxF 'Bash(git push:*)' "$T/LAST_DENY" && ok || bad "git push (any branch) is not in the runner's deny list"
grep -qF 'Read(/root/harness/env/**)' "$T/LAST_DENY" && ok || bad "env/ reads are not denied"
DN=$(jq -r '.permissions.deny|length' "$T/bin/remediator-settings.json")
[ "$(grep -c . "$T/LAST_DENY")" -eq "$DN" ] && ok \
  || bad "the deny list handed to the runner ($(grep -c . "$T/LAST_DENY")) is not the file's ($DN) — the two copies have drifted"
grep -qi 'never merge' "$T/LAST_SYSAPPEND" && ok || bad "the hard bounds are not in the system prompt"

# ---------- 10. the authority contract is IN the prompt, as MUST rules -------
# Written down or it does not exist: this is the only thing standing between an
# unattended agent and a merge, and a deny list cannot express most of it.
TPL="$DIR/prompts/remediator.md"
for RULE in 'gh pr merge' 'push to .main.' 'git push. of any kind' 'production database' 'Vercel' 'Fly machine' 'env/' 'install anything' 'bin/. or .rules/'; do
  grep -qiE "MUST-NOT:.*$RULE" "$TPL" && ok || bad "prompts/remediator.md has no MUST-NOT rule for: $RULE"
done
for RULE in 'read anything' 'gh' 'ssh' 'stale lock'; do
  grep -qiE "MUST-ALLOWED:.*$RULE" "$TPL" && ok || bad "prompts/remediator.md has no MUST-ALLOWED rule for: $RULE"
done
grep -qiE 'MUST-ALLOWED:.*push' "$TPL" && bad "prompts/remediator.md still allows a push (BH-2741)" || ok
grep -q 'When in doubt: ESCALATE' "$TPL" && ok || bad "the prompt does not state the tie-breaker"
grep -qE '^VERDICT: REMEDIATED\|TERMINAL\|ESCALATE' "$TPL" && ok || bad "the prompt does not pin the machine-parseable verdict line"
grep -q 'EVIDENCE:' "$TPL" && ok || bad "the prompt does not require an EVIDENCE line"
grep -qiE 'MANDATORY for .REMEDIATED. and .TERMINAL' "$TPL" && ok \
  || bad "the prompt does not say evidence is mandatory for BOTH suppressing verdicts"

# ---------- 11. the migration lane now flows through the hook ---------------
# The documented gap: this lane beat kind:"migration_check" and wrote its own
# ALERTS.log line, so neither tier ever saw the single most mechanically
# answerable alert class in the harness.
reset; agent_off
cp "$DIR/bin/check-migration-prs.sh" "$T/bin/"
cp "$DIR/fleet.conf" "$T/fleet.conf" 2>/dev/null || true
cp "$DIR/bin/fleet-conf.sh" "$T/bin/"  # BH-4080: the lane reads each repo slug from fleet.conf through it
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
# only project-3 has a merged migration PR in this fixture
case "$*" in *project-3*) printf '229\tadd finance tables\t0006_finance.sql\n' ;; esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/logs/ALERTS.log"; : > "$T/logs/migrations.log"
rm -f "$T/state/migration-prs-alerted.txt"
HARNESS="$T" PATH="$T/fakebin:$T/bin:$PATH" bash "$T/bin/check-migration-prs.sh"

quarantined 'migration:example-org/project-3#229' && ok \
  || bad "the migration lane still does not reach the hook: $(cat "$Q")"
grep -qF '"kind":"fleet_alert"' "$Q" && ok || bad "the migration beat is not a fleet_alert"
# VERBATIM: the text a human reads must not have moved with the plumbing
grep -qF 'PR #229 shipped migration SQL — confirm it is applied to prod (add finance tables)' "$Q" \
  && ok || bad "the migration alert's message text changed: $(cat "$Q")"
# and the direct ALERTS.log write is gone — poll-commands.sh re-beats every new
# ALERTS.log line to the console, so leaving it would page around the hook
[ ! -s "$T/logs/ALERTS.log" ] && ok \
  || bad "the migration lane still writes ALERTS.log, which pages around the hook: $(cat "$T/logs/ALERTS.log")"
grep -qF 'MIGRATION-PR merged: #229 (add finance tables) — confirm SQL applied to prod' "$T/logs/migrations.log" \
  && ok || bad "the local record moved without keeping its text: $(cat "$T/logs/migrations.log")"
# code only: the header comment names the old kind on purpose, to say what moved
grep -qF 'migration_check' <<<"$(grep -v '^[[:space:]]*#' "$DIR/bin/check-migration-prs.sh")" \
  && bad "check-migration-prs.sh still emits the unhooked migration_check kind" || ok

# ...and with the pilot on, that same alert gets a tier-2 attempt and still pages
reset; agent_on
scenario 0 <<'EOF'
EVIDENCE: curl .../api/internal/migrations/status -> 0006_finance.sql absent
VERDICT: ESCALATE the SQL is genuinely unapplied; a human must run it
EOF
rm -f "$T/state/migration-prs-alerted.txt"; : > "$T/logs/ALERTS.log"
HARNESS="$T" PATH="$T/fakebin:$T/bin:$PATH" bash "$T/bin/check-migration-prs.sh"
[ "$(calls)" -eq 1 ] && ok || bad "the migration alert got no tier-2 attempt ($(calls) calls)"
quarantined 'migration:example-org/project-3#229' && ok || bad "an escalated migration alert stopped paging"
grep -qF '[remediator tried: the SQL is genuinely unapplied' "$Q" \
  && ok || bad "the migration page did not arrive enriched: $(cat "$Q")"

# ---------- 12. enrichment can never be the thing that breaks a page --------
# It runs on the way OUT, on a payload that is already going to page. Every
# failure mode of it must leave the alert exactly as it arrived.
reset; agent_on
scenario 0 <<'EOF'
EVIDENCE: x
VERDICT: ESCALATE it said "quoted", it said \backslash\, it said 	tabbed and $DOLLAR
EOF
fire "$(payload 'nohandler:z')"
quarantined 'nohandler:z' && ok || bad "a hostile diagnosis string lost the alert"
LINE=$(cut -f2 "$Q" | tail -1)
jq -e . <<<"$LINE" >/dev/null 2>&1 && ok || bad "enrichment produced invalid JSON: $LINE"
[ "$(jq -r '.akey' <<<"$LINE")" = 'nohandler:z' ] && ok || bad "enrichment corrupted the payload's other fields"
grep -qF 'quoted' <<<"$LINE" && ok || bad "the diagnosis did not survive quoting"

# with jq gone entirely there is no hook at all, and the alert still pages
reset; agent_on
cat > "$T/fakebin/jq" <<'EOF'
#!/bin/bash
exit 127
EOF
chmod +x "$T/fakebin/jq"
P=$(printf '{"kind":"fleet_alert","project":"x-os","akey":"nohandler:z","line":"raw"}')
HARNESS="$T" PATH="$T/fakebin:$PATH" bash "$T/bin/beat.sh" "$P"; RCJ=$?
[ "$RCJ" -eq 0 ] && ok || bad "beat.sh failed its caller with jq broken (rc=$RCJ)"
quarantined 'nohandler:z' && ok || bad "an alert was lost when jq was unavailable"
rm -f "$T/fakebin/jq"

# ---------- 13. beat.sh still never fails its caller ------------------------
reset; agent_on
scenario 3 <<'EOF'
garbage
EOF
fire "$(payload 'nohandler:z')"; RC=$?
[ "$RC" -eq 0 ] && ok || bad "beat.sh returned rc=$RC through the tier-2 path"

# ---------- 14. the shipped wrapper is honest about its own bounds ----------
grep -q 'remediation-agent-enabled' "$DIR/bin/beat.sh" \
  && ok || bad "beat.sh does not gate tier 2 on the pilot flag"
grep -q 'timeout "$REM_AGENT_BOUND"' "$DIR/bin/beat.sh" \
  && ok || bad "beat.sh no longer bounds the tier-2 wrapper"
grep -q 'timeout 60 "$handler"' "$DIR/bin/beat.sh" \
  && ok || bad "beat.sh no longer bounds tier-1 handlers at 60s"
# the pilot flag is not created anywhere in the repo — shipping it on would make
# every box a pilot box the moment this merges
! grep -rl 'touch .*flags/remediation-agent-enabled' "$DIR/bin" "$DIR/cron" >/dev/null 2>&1 \
  && ok || bad "something in bin/ or cron/ creates the pilot flag — the pilot would not be opt-in"

# ---------- 15. the real harness was never touched --------------------------
[ "$Q0" = "$(snap "$REALQ")" ] && ok || bad "THIS TEST WROTE THE REAL QUARANTINE FILE ($REALQ)"
[ "$A0" = "$(snap "$REALA")" ] && ok || bad "THIS TEST WROTE THE REAL ALERTS.log ($REALA)"

echo "remediator-agent-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
