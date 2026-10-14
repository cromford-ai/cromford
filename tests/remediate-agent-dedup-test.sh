#!/bin/bash
# tests/remediate-agent-dedup-test.sh — BH-1038: tier 2 pays for a remediation
# payload ONCE.
#
# bin/remediate-agent.sh had exactly one spend bound before its model call (the
# daily cap) and nothing at all that noticed it was being handed the SAME alert
# payload it had already paid to think about. The 6h throttle in beat.sh is the
# caller's, keyed on the akey, and this script is directly runnable by hand.
#
# What this suite pins: a fingerprint of (akey, line, key-sorted payload) is
# written to state/remediation-payload-dedup.tsv BEFORE the call and settled
# after it to one of three outcomes. Inside the window, `ok` and `empty` are
# terminal on the first answer — an empty answer was billed too — and `failed`
# is retried to a cap of 3. A hit NEVER suppresses the alert: it fails open with
# the reason on the page, because a cached verdict is not evidence.
#
# THE AGENT IS ALWAYS A STUB. bin/agent-call.sh is replaced by a fixture that
# records the call, copies the ledger as the call sees it, and exits with a
# canned rc. Nothing here makes an LLM call, and the last check proves nothing
# here touched the real ALERTS.log or quarantine file.
# Run from anywhere: tests/remediate-agent-dedup-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

# Read the clock ONCE. Every fixture age below is derived from this.
NOW=$(date -u +%s)

mkdir -p "$T/bin/remediations" "$T/prompts" "$T/logs" "$T/state" "$T/flags" "$T/fakebin"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$T" project-4 project-3 x-os || exit 1  # BH-1510.2: lanes read models from model_routes

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq        >/dev/null 2>&1 || { echo "FAIL: jq required by this test"; exit 1; }
command -v python3   >/dev/null 2>&1 || { echo "FAIL: python3 required by this test"; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "FAIL: sha256sum required by this test"; exit 1; }

# Real-file tripwire: snapshot the live artifacts BEFORE anything runs.
REALQ=/root/harness/state/alert-quarantine.jsonl
REALA=/root/harness/logs/ALERTS.log
snap() { [ -f "$1" ] && stat -c '%Y %s' "$1" || echo absent; }
Q0=$(snap "$REALQ"); A0=$(snap "$REALA")

cp "$DIR/bin/beat.sh" "$DIR/bin/remediate-agent.sh" "$T/bin/"
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$T/bin/lib/"
cp "$DIR/bin/remediator-settings.json" "$T/bin/"
cp "$DIR/prompts/remediator.md" "$T/prompts/"

# beat.sh bounds tier 2 at `timeout 360`; nothing here hangs, so the shim only
# keeps a runaway fixture from owning the suite's runtime.
cat > "$T/fakebin/timeout" <<'EOF'
#!/bin/bash
shift              # drop beat.sh's bound
exec /usr/bin/timeout 20 "$@"
EOF
chmod +x "$T/fakebin/timeout"

# ---- THE STUB. The only agent this suite ever runs. -------------------------
# It records the call AND copies the dedup ledger exactly as it stands at call
# time, which is how C6 proves the marker is written BEFORE the spend.
cat > "$T/bin/agent-call.sh" <<'EOF'
#!/bin/bash
H="${HARNESS:?stub needs HARNESS}"
printf 'stage=%s project=%s model=%s timeout=%s out=%s\n' \
  "$1" "$2" "$3" "$4" "$5" >> "$H/AGENT_CALLS"
cp "$H/state/remediation-payload-dedup.tsv" "$H/LEDGER_AT_CALL" 2>/dev/null
cat "$H/AGENT_SCENARIO" > "$5" 2>/dev/null
exit "$(cat "$H/AGENT_RC" 2>/dev/null || echo 0)"
EOF
chmod +x "$T/bin/agent-call.sh"

Q="$T/state/alert-quarantine.jsonl"
RLOG="$T/logs/remediation.log"
LDG="$T/state/remediation-payload-dedup.tsv"
CNT="$T/state/remediation-agent-$(date -u +%Y%m%d).count"

pl() { # pl <akey> [line] [project]
  jq -nc --arg k "$1" --arg l "${2:-a line about $1}" --arg p "${3:-x-os}" \
    '{kind:"fleet_alert",project:$p,akey:$k,line:$l}'
}
scenario() { # scenario <rc> ; canned transcript on stdin
  echo "$1" > "$T/AGENT_RC"; cat > "$T/AGENT_SCENARIO"
}
FIRE_ENV=()
fire_direct() { # fire_direct <payload-json>  — the wrapper, run by hand
  local ak ln
  ak=$(jq -r '.akey' <<<"$1"); ln=$(jq -r '.line' <<<"$1")
  HARNESS="$T" env "${FIRE_ENV[@]}" bash "$T/bin/remediate-agent.sh" "$ak" "$ln" "$1"
}
fire_beat() { # fire_beat <payload-json> — the production entry point
  HARNESS="$T" PATH="$T/fakebin:$PATH" env "${FIRE_ENV[@]}" bash "$T/bin/beat.sh" "$1"
}
reset() {
  : > "$Q"; : > "$RLOG"; : > "$T/AGENT_CALLS"
  rm -f "$T/state/remediation-attempts.tsv" "$T/flags/remediation-disabled"
  rm -f "$T/state"/remediation-agent-*.count* "$T/LEDGER_AT_CALL"
  # scratch_rm, not `rm -rf $LDG`: only the lib can prove a path is inside the
  # scratch tree (checks/tests-scratch-only R2, family b3957447980a).
  local p
  for p in "$LDG" "$LDG.lock" "$LDG.tmp" "$T/logs/remediator" "$T/state/remediation-scratch"; do
    scratch_rm "$p" || return 1
  done
  FIRE_ENV=()
}
touch "$T/flags/remediation-agent-enabled"

calls()  { grep -c . "$T/AGENT_CALLS" 2>/dev/null; }
lrows()  { grep -c . "$LDG" 2>/dev/null; }
lf()     { cut -f"$1" "$LDG" 2>/dev/null | tail -1; }   # field of the last row
logged() { grep -qE "	$1	.*	$2" "$RLOG" 2>/dev/null; }
quarantined() { grep -qF "\"akey\":\"$1\"" "$Q" 2>/dev/null; }
# backdate every ledger row's last_ts to NOW minus <seconds>
backdate() {
  awk -F'\t' -v t=$(( NOW - $1 )) 'BEGIN{OFS="\t"} {$1=t; print}' "$LDG" > "$LDG.b" \
    && mv -f "$LDG.b" "$LDG"
}

# ---------- C1 the same payload twice makes ONE call -------------------------
reset
scenario 0 <<'EOF'
EVIDENCE: gh pr view 229 --json state -> {"state":"MERGED"}
VERDICT: REMEDIATED the PR this alert names was merged an hour ago
EOF
P1=$(pl 'dup:a1')
fire_direct "$P1" >/dev/null 2>&1; RC1=$?
O2=$(fire_direct "$P1" 2>&1); RC2=$?
[ "$(calls)" -eq 1 ] && ok || bad "C1: the same payload twice made $(calls) agent calls, expected 1"
[ "$RC1" -eq 0 ] && ok || bad "C1: the first (evidenced REMEDIATED) run did not exit 0 (rc=$RC1)"
[ "$RC2" -eq 1 ] && ok || bad "C1: a dedup hit must fail open with rc 1, got rc=$RC2"
logged 'dup:a1' 'FAILOPEN-dedup' && ok || bad "C1: the hit is not in remediation.log as FAILOPEN-dedup: $(cat "$RLOG")"
[ -n "$O2" ] && ok || bad "C1: a dedup hit printed nothing — beat.sh would have no diagnosis for the page"
[ "$(cat "$CNT" 2>/dev/null)" = 1 ] && ok \
  || bad "C1: the hit spent a daily-cap slot (counter reads '$(cat "$CNT" 2>/dev/null)', expected 1)"
[ "$(lrows)" -eq 1 ] && ok || bad "C1: expected one ledger row, got $(lrows): $(cat "$LDG" 2>/dev/null)"
[ "$(lf 3)" = 1 ] && ok || bad "C1: ledger attempts is '$(lf 3)', expected 1"
[ "$(lf 4)" = ok ] && ok || bad "C1: ledger outcome is '$(lf 4)', expected ok"
# the payload's text is spend metadata, not a log line
grep -qF 'a line about dup:a1' "$LDG" && bad "C1: the alert line text was written into the ledger" || ok
grep -qF 'a line about dup:a1' "$RLOG" && bad "C1: the alert line text was written into remediation.log" || ok

# ---------- C2 a failed call is retried to the cap, then terminal ------------
reset
scenario 1 <<'EOF'
EVIDENCE: something
VERDICT: REMEDIATED all good
EOF
P2=$(pl 'dup:b1')
for i in 1 2 3; do
  RCF=$(fire_direct "$P2" >/dev/null 2>&1; echo $?)
  [ "$RCF" -eq 1 ] && ok || bad "C2: failed attempt $i did not fail open (rc=$RCF)"
done
[ "$(calls)" -eq 3 ] && ok || bad "C2: three attempts under a cap of 3 made $(calls) calls, expected 3"
logged 'dup:b1' 'FAILOPEN-crash' && ok || bad "C2: a crashed lane stopped being logged FAILOPEN-crash"
[ "$(lf 3)" = 3 ] && ok || bad "C2: ledger attempts is '$(lf 3)' after three failures, expected 3"
[ "$(lf 4)" = failed ] && ok || bad "C2: ledger outcome is '$(lf 4)' after a crash, expected failed"
O4=$(fire_direct "$P2" 2>&1); RC4=$?
[ "$(calls)" -eq 3 ] && ok || bad "C2: the 4th attempt ran past the cap of 3 ($(calls) calls)"
[ "$RC4" -eq 1 ] && ok || bad "C2: the capped 4th attempt did not fail open (rc=$RC4)"
logged 'dup:b1' 'FAILOPEN-dedup' && ok || bad "C2: the capped 4th attempt is not logged FAILOPEN-dedup: $(cat "$RLOG")"
grep -qF 'already' <<<"$O4" && ok || bad "C2: the page says nothing about why no attempt was made: $O4"

# a timeout is a FAILED attempt — retryable, never terminal on the first one
reset
scenario 124 </dev/null
P2T=$(pl 'dup:b2')
fire_direct "$P2T" >/dev/null 2>&1
[ "$(lf 4)" = failed ] && ok || bad "C2: an rc-124 timeout settled as '$(lf 4)', expected failed"
fire_direct "$P2T" >/dev/null 2>&1
[ "$(calls)" -eq 2 ] && ok || bad "C2: a timed-out attempt was treated as terminal ($(calls) calls, expected 2)"
[ "$(lf 3)" = 2 ] && ok || bad "C2: the retry did not count an attempt (attempts='$(lf 3)')"

# ---------- C3 an empty result is terminal -----------------------------------
# rc 0 and nothing usable in the file: the model answered, we were billed, and
# asking the identical question again buys the identical nothing.
reset
scenario 0 </dev/null
P3=$(pl 'dup:c1')
fire_direct "$P3" >/dev/null 2>&1
logged 'dup:c1' 'FAILOPEN-parse' && ok || bad "C3: an empty transcript stopped being FAILOPEN-parse"
[ "$(lf 4)" = empty ] && ok || bad "C3: an empty transcript settled as '$(lf 4)', expected empty"
O3=$(fire_direct "$P3" 2>&1); RC3=$?
[ "$(calls)" -eq 1 ] && ok || bad "C3: an empty result was paid for twice ($(calls) calls)"
[ "$RC3" -eq 1 ] && ok || bad "C3: the repeat of an empty result did not fail open (rc=$RC3)"
logged 'dup:c1' 'FAILOPEN-dedup' && ok || bad "C3: the repeat is not logged FAILOPEN-dedup: $(cat "$RLOG")"

# ---------- C4 the negatives: this is a PAYLOAD key, never an akey key -------
reset
scenario 0 <<'EOF'
EVIDENCE: x
VERDICT: ESCALATE still down
EOF
fire_direct "$(pl 'dup:d1' 'the disk filled at 04:00Z')" >/dev/null 2>&1
fire_direct "$(pl 'dup:d1' 'the disk filled at 05:00Z')" >/dev/null 2>&1
[ "$(calls)" -eq 2 ] && ok || bad "C4a: same akey with a DIFFERENT line was deduped ($(calls) calls, expected 2)"
[ "$(lrows)" -eq 2 ] && ok || bad "C4a: expected two ledger rows, got $(lrows)"
reset
scenario 0 <<'EOF'
EVIDENCE: x
VERDICT: ESCALATE still down
EOF
fire_direct "$(pl 'dup:d2' 'same line' 'project-3')" >/dev/null 2>&1
fire_direct "$(pl 'dup:d2' 'same line' 'project-4')"    >/dev/null 2>&1
[ "$(calls)" -eq 2 ] && ok || bad "C4b: a different payload project was deduped ($(calls) calls, expected 2)"

# ---------- C5 the window boundary -------------------------------------------
reset
scenario 0 <<'EOF'
EVIDENCE: x
VERDICT: REMEDIATED settled
EOF
P5=$(pl 'dup:e1')
fire_direct "$P5" >/dev/null 2>&1
backdate 90000                       # older than the 86400s window
fire_direct "$P5" >/dev/null 2>&1
[ "$(calls)" -eq 2 ] && ok || bad "C5: a payload last seen 25h ago was still deduped ($(calls) calls)"
[ "$(lrows)" -eq 1 ] && ok || bad "C5: an expired row was duplicated instead of rewritten ($(lrows) rows)"
[ "$(lf 3)" = 1 ] && ok || bad "C5: an expired row did not restart attempts at 1 (got '$(lf 3)')"
[ "$(lf 4)" = ok ] && ok || bad "C5: the fresh episode settled as '$(lf 4)', expected ok"
[ "$(lf 1)" -ge "$NOW" ] && ok || bad "C5: last_ts was not refreshed by the new attempt ('$(lf 1)' < $NOW)"
backdate 3600                        # an hour ago: well inside the window
fire_direct "$P5" >/dev/null 2>&1
[ "$(calls)" -eq 2 ] && ok || bad "C5: a payload seen an hour ago was paid for again ($(calls) calls)"

# ---------- C6 the marker exists BEFORE the money is spent -------------------
reset
scenario 0 <<'EOF'
EVIDENCE: x
VERDICT: REMEDIATED settled
EOF
fire_direct "$(pl 'dup:f1')" >/dev/null 2>&1
[ -s "$T/LEDGER_AT_CALL" ] && ok \
  || bad "C6: the ledger was empty at call time — the marker is written after the spend, not before"
[ "$(cut -f3 "$T/LEDGER_AT_CALL" 2>/dev/null | tail -1)" = 1 ] && ok \
  || bad "C6: the marker at call time does not count the attempt: $(cat "$T/LEDGER_AT_CALL" 2>/dev/null)"
[ "$(cut -f4 "$T/LEDGER_AT_CALL" 2>/dev/null | tail -1)" = pending ] && ok \
  || bad "C6: the marker at call time is not 'pending': $(cat "$T/LEDGER_AT_CALL" 2>/dev/null)"
# and the fingerprint it holds is the row the outcome lands on
[ "$(cut -f2 "$T/LEDGER_AT_CALL" 2>/dev/null | tail -1)" = "$(lf 2)" ] && ok \
  || bad "C6: the settled row has a different fingerprint than the claimed one"

# ---------- C7 a marker that cannot be persisted buys NO call ----------------
# If the spend cannot be recorded, the spend does not happen. This guard can
# never suppress an alert, so refusing the call is the safe side.
#
# The ledger path here is a DIRECTORY, which is the shape that caught the lane
# out: `touch` on a directory succeeds and `mv table dir` lands the table INSIDE
# it, rc 0, so a claim that never persisted reads as claimed. awk is no backstop
# — mawk errors on a directory argument (which is why this case passed locally),
# gawk warns and skips it with rc 0 (which is why it failed on the runner). The
# last assertion below is the awk-independent one: whatever the claim decided,
# nothing may be written inside that path.
reset
rm -f "$LDG"; mkdir -p "$LDG"
scenario 0 <<'EOF'
EVIDENCE: x
VERDICT: REMEDIATED settled
EOF
O7=$(fire_direct "$(pl 'dup:g1')" 2>&1); RC7=$?
[ "$(calls)" -eq 0 ] && ok || bad "C7: an unpersistable marker still bought a model call ($(calls))"
[ "$RC7" -eq 1 ] && ok || bad "C7: an unpersistable marker did not fail open (rc=$RC7)"
logged 'dup:g1' 'FAILOPEN-dedup' && ok || bad "C7: nothing logged for an unpersistable marker: $(cat "$RLOG")"
grep -qi 'marker' <<<"$O7" && ok || bad "C7: the page does not say the marker is the problem: $O7"
[ -z "$(ls -A "$LDG" 2>/dev/null)" ] && ok \
  || bad "C7: the claim wrote inside the unusable ledger path instead of refusing: $(ls -A "$LDG")"
scratch_rm "$LDG"

# ---------- C8 the production path: beat.sh -> remediate-agent.sh ------------
# D2: the real hook, the real wrapper, the real 6h throttle, one stub agent.
reset
scenario 0 <<'EOF'
EVIDENCE: ssh root@box-project-3-1 true -> exit 255
VERDICT: ESCALATE box is genuinely down; needs a console reboot
EOF
P8=$(pl 'dup:h1')
fire_beat "$P8"
[ "$(calls)" -eq 1 ] && ok || bad "C8: the first alert got $(calls) tier-2 attempts, expected 1"
quarantined 'dup:h1' && ok || bad "C8: an escalated alert stopped paging"
# step outside the 6h akey throttle so the ONLY thing that can stop the second
# attempt is the payload dedup
awk -F'\t' -v t=$(( NOW - 25000 )) 'BEGIN{OFS="\t"} {$1=t; print}' \
  "$T/state/remediation-attempts.tsv" > "$T/state/ra.b" \
  && mv -f "$T/state/ra.b" "$T/state/remediation-attempts.tsv"
fire_beat "$P8"
[ "$(calls)" -eq 1 ] && ok || bad "C8: the repeat alert paid for a second call ($(calls)) through beat.sh"
[ "$(grep -c 'dup:h1' "$Q")" -eq 2 ] && ok \
  || bad "C8: a deduped alert stopped paging ($(grep -c 'dup:h1' "$Q") of 2 quarantined)"
grep -qF '[remediator tried:' "$Q" && ok || bad "C8: the deduped page arrived without a diagnosis: $(cat "$Q")"
logged 'dup:h1' 'FAILOPEN-dedup' && ok || bad "C8: no FAILOPEN-dedup row from the beat.sh path: $(cat "$RLOG")"
logged 'dup:h1' 'FAILOPEN' && ok || bad "C8: beat.sh did not record the dispatch as a fail-open"
grep -q 'tier2-dispatch' "$RLOG" && ok || bad "C8: beat.sh's own dispatch line is missing: $(cat "$RLOG")"

# ---------- C9 a garbage knob falls back to the default, never to unlimited --
reset
scenario 1 </dev/null
FIRE_ENV=(REMEDIATE_DEDUP_CAP=0 REMEDIATE_DEDUP_WINDOW=abc)
P9=$(pl 'dup:i1')
for i in 1 2 3 4; do fire_direct "$P9" >/dev/null 2>&1; done
[ "$(calls)" -eq 3 ] && ok \
  || bad "C9: a zero cap / unparseable window was not read as the default ($(calls) calls, expected 3)"
[ "$(lf 3)" = 3 ] && ok || bad "C9: ledger attempts is '$(lf 3)', expected 3"

# ---------- C10 the real harness was never touched ---------------------------
[ "$Q0" = "$(snap "$REALQ")" ] && ok || bad "C10: THIS TEST WROTE THE REAL QUARANTINE FILE ($REALQ)"
[ "$A0" = "$(snap "$REALA")" ] && ok || bad "C10: THIS TEST WROTE THE REAL ALERTS.log ($REALA)"

echo "remediate-agent-dedup-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
