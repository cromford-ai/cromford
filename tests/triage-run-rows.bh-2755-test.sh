#!/bin/bash
# tests/triage-run-rows.bh-2755-test.sh — per-key triage runs reach the console
# `runs` table (BH-2755, part of #2751).
#
# Two senders, both driven for real against a scratch $HARNESS:
#   bin/launch-fastpath.sh — a key it LAUNCHED sends one kind:"run" beat, after
#     the launch; a declined or failed key sends none.
#   bin/triage-shard.sh    — one shard sends one kind:"run" beat.
# Both send through bin/lib/run-beat.sh with BEAT_STRICT=1, and a beat the
# console did not take is ONE logs/ALERTS.log line per box per UTC day
# (flags/alerted-run-beat-<box>-<yyyymmdd>), never a changed exit code.
#
# The recording beat stub is the console: what it RECEIVED is the assertion.
# C3 swaps it for the REAL bin/beat.sh with no CONSOLE_URL, so the rc 2 that
# drives the alert comes from production code, not from the fixture.
# Run from anywhere: bash tests/triage-run-rows.bh-2755-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
command -v flock   >/dev/null || { echo "flock missing — skipping"; exit 0; }

# The box's own console config must never leak into the scratch tree.
unset CONSOLE_URL HARNESS_SECRET

NOW=$(date +%s)
DAY=$(date -u +%Y%m%d)
BOX=box-small
P=cromford

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" \
         "$H/prompts" "$H/builds" "$H/fixture" "$T/fakebin"
export HARNESS="$H"

# ---- the scripts under test, and the libs they source -----------------------
cp "$DIR/bin/launch-fastpath.sh" "$H/bin/"
sed -e "s|/root/harness|$H|g" -e "s|/root/repos|$T/repos|g" "$DIR/bin/triage-shard.sh" > "$H/bin/triage-shard.sh"
chmod +x "$H/bin/launch-fastpath.sh" "$H/bin/triage-shard.sh"
[ -f "$DIR/bin/lib/run-beat.sh" ] && cp "$DIR/bin/lib/run-beat.sh" "$H/bin/lib/"
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/dep-verify-lib.sh" "$DIR/bin/lib/gh-budget.sh" \
   "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/lock-hygiene.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" \
   "$DIR/bin/lib/env-path.sh" "$H/bin/lib/"
ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"

cat > "$H/fleet.conf" <<'CONF'
cromford example-org/cromford https://console.example - 9 box-small 10.0.0.13
CONF
export FLEET_CONF="$H/fleet.conf"
SOP='  `setsid /root/harness/bin/run-build.sh cromford <issue-number> BH-<issue-number> > /root/harness/logs/cromford.bh-<issue-number>-build.out 2>&1 &`'
printf '%s\n' "$SOP" > "$H/prompts/$P.md"
# HARNESS_SECRET set, CONSOLE_URL deliberately absent: the real beat.sh in C3
# must answer "not configured" from this file, not from the test's environment.
printf 'HARNESS_SECRET=s3cret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"

# run-build.sh: the launch, recorded.
cat > "$H/bin/run-build.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/launches.log"
SH
chmod +x "$H/bin/run-build.sh"
printf '#!/bin/bash\necho "UNKNOWN shim"\n' > "$H/bin/dep-verify.sh"; chmod +x "$H/bin/dep-verify.sh"

# THE CONSOLE: records every payload, plus whether the launch was already
# logged and its marker written when the beat arrived — "sent after the launch"
# is a claim only the receiver can prove. run-build.sh itself runs detached, so
# its own record is not an ordering witness; the marker and the launched log
# line are written synchronously before the spawn returns.
cat > "$H/bin/beat-stub.sh" <<'SH'
#!/bin/bash
lg=0; grep -q 'FASTPATH .* — launched' "$HARNESS/logs/cromford.log" 2>/dev/null && lg=1
mk=0; ls "$HARNESS"/state/orphan-reconcile/cromford/*.enqueued >/dev/null 2>&1 && mk=1
printf '%s\tlaunched_before=%s marker=%s strict=%s\n' "$1" "$lg" "$mk" "${BEAT_STRICT:-}" >> "$HARNESS/beats.log"
exit "${BEAT_RC:-0}"
SH
chmod +x "$H/bin/beat-stub.sh"
use_stub_beat() { cp "$H/bin/beat-stub.sh" "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"; }
use_real_beat() { cp "$DIR/bin/beat.sh" "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"; }

# shard stubs: the model call, the contract, the decision log
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "tickets=1 done" > "$5"
exit 0
SH
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$H/bin/triage-contract.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/decision-log.sh"
chmod +x "$H/bin/agent-call.sh" "$H/bin/triage-contract.sh" "$H/bin/decision-log.sh"
echo "Triage one ticket." > "$T/prompt.txt"

# ---- PATH shims: hostname, gh (REST), curl (jobs ledger), setsid -------------
printf '#!/bin/sh\necho %s\n' "$BOX" > "$T/fakebin/hostname"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
ARGS="$*"
PAGE=$(printf '%s' "$ARGS" | sed -nE 's/.*page=([0-9]+).*/\1/p'); PAGE="${PAGE:-1}"
case "$ARGS" in
  *"api rate_limit"*) exit 1 ;;
  *"/issues/"*"/comments"*) SEND 200 '[]' ;;
  *"/issues/"*)
    n=$(printf '%s' "$ARGS" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    [ -f "$HARNESS/fixture/issue-$n.json" ] || SEND 404 '{"message":"Not Found"}'
    SEND 200 "$(cat "$HARNESS/fixture/issue-$n.json")" ;;
  *"/issues"*|*"/pulls"*) SEND 200 '[]' ;;
  *"api repos/"*) echo 12345 ;;
  *) exit 1 ;;
esac
SH
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/jobs*)  printf '{"jobs":[]}\n200\n' ;;
  */api/queue*) printf '{"queue":[]}\n200\n' ;;
  # TEST-CHANGE BH-4153: paused-*/automerge-disabled* are now harness_flags rows read DB-first; a 200 with no .flag row is UNREADABLE and fails closed (paused), so the flag GET must answer the worker's real no-row 404.
  */api/flags/*) printf '{"error":"not found"}\n404\n' ;;
  *)            printf '{"ok":true}\n200\n' ;;
esac
SH
printf '#!/bin/bash\nexec "$@"\n' > "$T/fakebin/setsid"
chmod +x "$T/fakebin/hostname" "$T/fakebin/gh" "$T/fakebin/curl" "$T/fakebin/setsid"
export PATH="$T/fakebin:$PATH"

BODY_OK=$'## Scope\nBuild the thing.\n\n## Acceptance tests\n- it works\n'
mkissue() { # mkissue <n> <labels-json>
  jq -nc --argjson n "$1" --argjson lb "$2" --arg b "$BODY_OK" \
     --arg ca "$(date -u -d "@$((NOW - 86400))" '+%Y-%m-%dT%H:%M:%SZ')" \
     '{number:$n,state:"open",title:"BH-\($n) a ticket",body:$b,labels:$lb,comments:0,created_at:$ca}' \
     > "$H/fixture/issue-$1.json"
}
reset() {
  scratch_rm "$H/state"; scratch_rm "$H/locks"; scratch_rm "$H/logs"; scratch_rm "$H/flags"
  mkdir -p "$H/state" "$H/locks" "$H/logs" "$H/flags"
  rm -f "$H/launches.log" "$H/beats.log" "$H"/fixture/issue-*.json
  chmod +x "$H/bin/run-build.sh"
  use_stub_beat
  unset BEAT_RC
}
fp()    { FOUT=$("$H/bin/launch-fastpath.sh" "$@" 2>/dev/null); FRC=$?; }
shard() { TSH_MODEL=m TSH_RUNNER=claude "$H/bin/triage-shard.sh" "$P" "$1" "$T/prompt.txt" >/dev/null 2>&1; SRC=$?; }
nbeats() { local n; n=$(grep -c . "$H/beats.log" 2>/dev/null); echo "${n:-0}"; }
beat()   { sed -n "${1}p" "$H/beats.log" 2>/dev/null | cut -f1; }
nalert() { local n; n=$(grep -c 'run beat not delivered' "$H/logs/ALERTS.log" 2>/dev/null); echo "${n:-0}"; }
waitlaunch() { local i=0; while [ "$i" -lt 40 ] && [ ! -s "$H/launches.log" ]; do sleep 0.1; i=$((i+1)); done; }
MARKER="$H/flags/alerted-run-beat-$BOX-$DAY"
ISO='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

# ---------- C1 (A3): a launched key sends one run beat, after the launch ------
reset
mkissue 42 '[{"name":"ai-build"}]'
fp "$P" 42
waitlaunch
[ "$FRC" = 0 ] && ok || bad "C1: a launched key must exit 0, got rc=$FRC"
[ -z "$FOUT" ] && ok || bad "C1: stdout is declined keys only, got '$FOUT'"
grep -q "^$P 42 BH-42" "$H/launches.log" 2>/dev/null && ok || bad "C1: key 42 did not launch: $(cat "$H/launches.log" 2>/dev/null) / $(tail -3 "$H/logs/$P.log" 2>/dev/null)"
[ "$(nbeats)" = 1 ] && ok || bad "C1: want exactly one beat after a launch, got $(nbeats): $(cat "$H/beats.log" 2>/dev/null)"
B=$(beat 1)
if [ -n "$B" ]; then
  [ "$(jq -r .kind <<<"$B")" = run ] && ok || bad "C1: kind: $B"
  [ "$(jq -r .project <<<"$B")" = "$P" ] && ok || bad "C1: project: $B"
  [ "$(jq -r .run_kind <<<"$B")" = triage ] && ok || bad "C1: run_kind: $B"
  [ "$(jq -r .rc <<<"$B")" = 0 ] && ok || bad "C1: rc: $B"
  jq -r .rkey <<<"$B" | grep -qE "^run:$P:BH-42:fastpath:[0-9]+$" && ok || bad "C1: rkey: $(jq -r .rkey <<<"$B")"
  [ "$(jq -r .summary <<<"$B")" = "fastpath BH-42: launched build" ] && ok || bad "C1: summary: $B"
  jq -r .started_at  <<<"$B" | grep -qE "$ISO" && ok || bad "C1: started_at: $B"
  jq -r .finished_at <<<"$B" | grep -qE "$ISO" && ok || bad "C1: finished_at: $B"
  grep -q 'launched_before=1 marker=1 strict=1' "$H/beats.log" && ok || bad "C1: the beat must follow the launch, strict: $(cut -f2 "$H/beats.log")"
fi
[ "$(nalert)" = 0 ] && ok || bad "C1: a delivered beat owes no alert: $(cat "$H/logs/ALERTS.log")"

# ---------- C2: one shard, one run beat ---------------------------------------
reset
shard BH-7
[ "$SRC" = 0 ] && ok || bad "C2: shard rc=$SRC"
[ "$(nbeats)" = 1 ] && ok || bad "C2: want one shard beat, got $(nbeats): $(cat "$H/beats.log" 2>/dev/null)"
B=$(beat 1)
[ "$(jq -r .kind <<<"$B" 2>/dev/null)" = run ] && ok || bad "C2: kind: $B"
case "$(jq -r .rkey <<<"$B" 2>/dev/null)" in "run:$P:BH-7:"*) ok ;; *) bad "C2: rkey: $B" ;; esac
grep -q 'strict=1' "$H/beats.log" 2>/dev/null && ok || bad "C2: the shard beat must be strict: $(cut -f2 "$H/beats.log" 2>/dev/null)"

# ---------- C3: the REAL beat.sh, no CONSOLE_URL → ONE alert per box per day ---
reset
use_real_beat
shard BH-7; R1=$SRC
shard BH-8; R2=$SRC
[ "$R1" = 0 ] && [ "$R2" = 0 ] && ok || bad "C3: shard exit codes must not change: $R1 $R2"
[ "$(nalert)" = 1 ] && ok || bad "C3: want exactly one ALERTS line, got $(nalert): $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
L=$(grep 'run beat not delivered' "$H/logs/ALERTS.log" 2>/dev/null)
case "$L" in *"$BOX"*) ok ;; *) bad "C3: the line must name the box: '$L'" ;; esac
case "$L" in *"CONSOLE_URL/HARNESS_SECRET unset"*) ok ;; *) bad "C3: the line must say not configured: '$L'" ;; esac
case "$L" in *s3cret*) bad "C3: the alert leaked the secret" ;; *) ok ;; esac
[ -f "$MARKER" ] && ok || bad "C3: marker $MARKER missing"
grep -q "shard BH-8 rc=0" "$H/logs/$P.log" && ok || bad "C3: shard log line must stay rc=0"
mkissue 42 '[{"name":"ai-build"}]'
fp "$P" 42
waitlaunch
[ "$FRC" = 0 ] && ok || bad "C3: an undelivered beat must not fail the launch, rc=$FRC"
[ -z "$FOUT" ] && ok || bad "C3: stdout must stay empty, got '$FOUT'"
[ "$(nalert)" = 1 ] && ok || bad "C3: the fastpath must not add a second line today, got $(nalert)"

# ---------- C4: delivery failed (rc 1) → the non-2xx line ---------------------
reset
export BEAT_RC=1
shard BH-9
unset BEAT_RC
[ "$SRC" = 0 ] && ok || bad "C4: shard rc=$SRC"
[ "$(nalert)" = 1 ] && ok || bad "C4: want one ALERTS line, got $(nalert)"
grep 'run beat not delivered' "$H/logs/ALERTS.log" 2>/dev/null | grep -q "box=$BOX.*POST /api/beat returned non-2xx (rc=1)" \
  && ok || bad "C4: non-2xx line: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
grep -q "shard BH-9 rc=0" "$H/logs/$P.log" && ok || bad "C4: shard log line must stay rc=0"

# ---------- C5: no beat for a key that did not launch -------------------------
reset
mkissue 43 '[]'
fp "$P" 43
[ "$FRC" = 1 ] && [ "$FOUT" = 43 ] && ok || bad "C5: a declined key: rc=$FRC out='$FOUT'"
[ "$(nbeats)" = 0 ] && ok || bad "C5: a declined key sent a beat: $(cat "$H/beats.log")"
reset
mkissue 44 '[{"name":"ai-build"}]'
chmod -x "$H/bin/run-build.sh"
fp "$P" 44
chmod +x "$H/bin/run-build.sh"
[ "$FRC" = 1 ] && ok || bad "C5: a failed spawn must exit 1, got rc=$FRC"
grep -q 'launch failed (126)' "$H/logs/$P.log" && ok || bad "C5: expected the FAILED 126 path: $(tail -2 "$H/logs/$P.log")"
[ "$(nbeats)" = 0 ] && ok || bad "C5: a failed launch sent a beat: $(cat "$H/beats.log")"

# ---------- C6: the lib on its own — no stdout, rc 0, whatever beat.sh does ---
if [ -f "$DIR/bin/lib/run-beat.sh" ]; then
  reset
  rm -f "$H/bin/beat.sh"   # missing beat.sh = 127: delivery failed, not "unconfigured"
  OUT6=$( . "$DIR/bin/lib/run-beat.sh"; run_beat '{"kind":"run"}'; echo "rc=$?" )
  [ "$OUT6" = "rc=0" ] && ok || bad "C6: run_beat must print nothing and return 0, got '$OUT6'"
  grep -q 'non-2xx (rc=127)' "$H/logs/ALERTS.log" 2>/dev/null && ok || bad "C6: a missing beat.sh is a failed delivery: $(cat "$H/logs/ALERTS.log" 2>/dev/null)"
else
  bad "C6: bin/lib/run-beat.sh does not exist"
fi

echo "triage-run-rows.bh-2755: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
