#!/bin/bash
# tests/ticket-lock.cross-harness-test.sh — every build takes the cross-harness
# ticket lock IN CODE (2026-10-20).
#
# THE INCIDENT (TK-249, 2026-10-04). Our pool build of project-3 TK-249 started at
# 00:21. the partner harness asked the shared lock service for project-3:TK-249 at 00:43,
# nobody held it, and both harnesses opened a PR (#404 merged, #405 closed).
# Only the triage PROMPT asked for the lock (prompts/project-3.md); no script
# called /v1/acquire, so a build that did not come out of that prompt ran bare.
#
# THE ROWS (red first: every G row fails on main, which has no lock code):
#   L1  acquire 201 writes the state file (key + lease id) and sends the bearer,
#       kind, key and ttl the contract names
#   L2  acquire 409 is rc 3 and names the holder; no state file
#   L3  a 500 and a dead transport are rc 1 (an outage, never "held")
#   L4  an unmapped project, or no LOCKS_URL, is rc 2 with no request sent
#   L5  renew 200 is rc 0. renew 404 re-acquires (the worker rotates the lease
#       when the same holder acquires, e.g. a triage tick during the build):
#       201 = still ours, the new lease is stored, rc 0; 409 = LOST, rc 3 and
#       <state>.lost; an outage on the re-acquire is rc 1 and never lost
#   L6  release is by KEY (the worker deletes only our holder's row) and sends
#       the outcome; it removes the state file
#   G1  the build's acquire block defers on 409: exit 3, BUILD_DEFERRED naming
#       the key and the holder
#   G2  on 201 the build goes on holding the lock
#   G3  on an outage the build goes on and ALERTS says so
#   G4  the push gate yields when the lock was lost, and passes when held;
#       G4c: a lease our own triage rotated mid-build passes (lead review #7788)
#   G5  the exit hook releases with pr / skipped / blocked from the RESULT
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/ticket-lock.cross-harness-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

FB="$T/fakebin"; mkdir -p "$FB"
# Fake curl: records argv + body, answers by path from LK_<OP>_CODE / LK_<OP>_BODY.
cat > "$FB/curl" <<'EOF'
#!/bin/bash
out=""; data=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --data-binary) data="$2"; shift 2 ;;
    -w|-m|-X) shift 2 ;;
    -H) if [ "$2" = "@-" ]; then echo "H $(cat)" >> "$CURL_LOG"; else echo "H $2" >> "$CURL_LOG"; fi; shift 2 ;;
    --connect-timeout) shift 2 ;;
    -s) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "URL $url" >> "$CURL_LOG"; echo "DATA $data" >> "$CURL_LOG"
case "$url" in
  */v1/acquire) code="${LK_ACQ_CODE:-201}"; body="${LK_ACQ_BODY:-}"
                [ -n "$body" ] || body='{"lease_id":"L-1","expires_at":"x"}' ;;
  */v1/renew)   code="${LK_REN_CODE:-200}"; body='{}' ;;
  */v1/release) code="${LK_REL_CODE:-200}"; body='{}' ;;
  *) code=404; body='{}' ;;
esac
[ "$code" = dead ] && exit 7
printf '%s' "$body" > "$out"
printf '%s' "$code"
EOF
chmod +x "$FB/curl"
export PATH="$FB:$PATH" CURL_LOG="$T/curl.log"
export LOCKS_URL="https://locks.example" LOCKS_TOKEN="fixture-token-ours"
. "$DIR/bin/lib/ticket-lock.sh" || { echo "FAIL: ticket-lock.sh does not source"; exit 1; }

reset() { : > "$CURL_LOG"; rm -f "$T"/state*; unset LK_ACQ_CODE LK_ACQ_BODY LK_REN_CODE LK_REL_CODE; }

# --- L1 ---------------------------------------------------------------------
reset
tl_acquire project-3 TK-249 "$T/state"; rc=$?
[ "$rc" = 0 ] && ok || bad "L1 acquire 201 must be rc 0 (got $rc)"
[ "$(sed -n 1p "$T/state" 2>/dev/null)" = "project-3:TK-249" ] && ok || bad "L1 state key must be project-3:TK-249"
[ "$(sed -n 2p "$T/state" 2>/dev/null)" = "L-1" ] && ok || bad "L1 state must hold the lease id"
grep -q 'H Authorization: Bearer fixture-token-ours' "$CURL_LOG" && ok || bad "L1 bearer header missing"
grep -q 'URL.*fixture-token-ours' "$CURL_LOG" && bad "L1 the token must never be on argv" || ok
grep -q 'URL https://locks.example/v1/acquire' "$CURL_LOG" && ok || bad "L1 wrong URL"
D=$(sed -n 's/^DATA //p' "$CURL_LOG")
[ "$(jq -r '.kind+" "+.key+" "+(.ttl_s|tostring)' <<<"$D")" = "ticket project-3:TK-249 7200" ] && ok || bad "L1 body must be kind/key/ttl_s: $D"

# --- L2 ---------------------------------------------------------------------
reset; export LK_ACQ_CODE=409 LK_ACQ_BODY='{"holder":"partner-collaborator-1","expires_at":"x"}'
H=$(tl_acquire project-3 TK-249 "$T/state"); rc=$?
[ "$rc" = 3 ] && ok || bad "L2 acquire 409 must be rc 3 (got $rc)"
[ "$H" = partner-collaborator-1 ] && ok || bad "L2 must print the holder (got '$H')"
[ ! -e "$T/state" ] && ok || bad "L2 a refused acquire must write no state"

# --- L3 ---------------------------------------------------------------------
reset; export LK_ACQ_CODE=500
tl_acquire project-3 TK-249 "$T/state" >/dev/null; rc=$?
[ "$rc" = 1 ] && ok || bad "L3 a 500 is an outage, rc 1 (got $rc)"
reset; export LK_ACQ_CODE=dead
tl_acquire project-3 TK-249 "$T/state" >/dev/null; rc=$?
[ "$rc" = 1 ] && ok || bad "L3 a dead transport is an outage, rc 1 (got $rc)"

# --- L4 ---------------------------------------------------------------------
reset
tl_acquire project-6-os TK-1 "$T/state" >/dev/null; rc=$?
[ "$rc" = 2 ] && ok || bad "L4 an unmapped project must be rc 2 (got $rc)"
[ ! -s "$CURL_LOG" ] && ok || bad "L4 an unmapped project must send nothing"
reset
( unset LOCKS_URL; tl_acquire project-3 TK-1 "$T/state" >/dev/null; exit $? ); rc=$?
[ "$rc" = 2 ] && ok || bad "L4 no LOCKS_URL must be rc 2 (got $rc)"
for p in project-3:project-3 project-2:project-2 project-4:project-4 project-1:project-1; do
  [ "$(tl_ns "${p%%:*}")" = "${p#*:}" ] && ok || bad "L4 namespace for ${p%%:*} must be ${p#*:}"
done

# --- L5 ---------------------------------------------------------------------
reset; printf 'project-3:TK-249\nL-1\n' > "$T/state"
tl_renew "$T/state"; rc=$?
[ "$rc" = 0 ] && ok || bad "L5 renew 200 must be rc 0 (got $rc)"
# The lead-review BLOCK case: our own triage re-acquired, the lease rotated.
export LK_REN_CODE=404 LK_ACQ_CODE=201 LK_ACQ_BODY='{"lease_id":"L-2","expires_at":"x"}'
tl_renew "$T/state"; rc=$?
[ "$rc" = 0 ] && ok || bad "L5 renew 404 + re-acquire 201 must be rc 0, still ours (got $rc)"
[ "$(sed -n 2p "$T/state")" = "L-2" ] && ok || bad "L5 the rotated lease must be stored (got $(sed -n 2p "$T/state"))"
tl_lost "$T/state" && bad "L5 a rotated lease is not lost" || ok
export LK_ACQ_CODE=503
tl_renew "$T/state"; rc=$?
[ "$rc" = 1 ] && ok || bad "L5 renew 404 + re-acquire outage must be rc 1 (got $rc)"
tl_lost "$T/state" && bad "L5 an outage must never mark the lock lost" || ok
export LK_ACQ_CODE=409 LK_ACQ_BODY='{"holder":"partner-collaborator-1"}'
tl_renew "$T/state"; rc=$?
[ "$rc" = 3 ] && ok || bad "L5 renew 404 + re-acquire 409 must be rc 3 (got $rc)"
tl_lost "$T/state" && ok || bad "L5 renew 404 + re-acquire 409 must write the .lost marker"

# --- L6 ---------------------------------------------------------------------
reset; printf 'project-3:TK-249\nL-1\n' > "$T/state"
tl_release "$T/state" pr
D=$(sed -n 's/^DATA //p' "$CURL_LOG")
[ "$(jq -r '.key+" "+.outcome' <<<"$D")" = "project-3:TK-249 pr" ] && ok || bad "L6 release body wrong: $D"
[ "$(jq -r 'has("lease_id")' <<<"$D")" = false ] && ok || bad "L6 release must be by key (a rotated lease must still be freed): $D"
[ ! -e "$T/state" ] && ok || bad "L6 release must remove the state file"

# ============================================================================
# G — the wiring in bin/lib/rb/gates.sh, driven from its own marked blocks
# ============================================================================
blk() { awk -v b="# >>> $1" -v e="# <<< $1" 'index($0, b) {on=1} on {print} index($0, e) {exit}' "$DIR/bin/lib/rb/gates.sh"; }
fn()  { awk -v f="$1(){" 'index($0, f) == 1 {on=1} on {print} on && /^}/ {exit}' "$DIR/bin/lib/rb/gates.sh"; }
ACQ=$(blk "ticket lock acquire"); REL=$(blk "ticket lock release"); GATE=$(fn RB_TICKET_LOCK_GATE)
[ -n "$ACQ" ] && ok || bad "G the acquire block is missing from gates.sh"
[ -n "$REL" ] && ok || bad "G the release block is missing from gates.sh"
[ -n "$GATE" ] && ok || bad "G RB_TICKET_LOCK_GATE is missing from gates.sh"

mkdir -p "$T/h/bin"
printf '#!/bin/bash\necho "$*" >> "%s/alert-line.log"\n' "$T" > "$T/h/bin/alert-line.sh"; chmod +x "$T/h/bin/alert-line.sh"
DRIVE() { # DRIVE <code...> — run a snippet as the build would, rc + files out
  mkdir -p "$T/build"; rm -f "$T/build/RESULT" "$T/build/.ticket-lock"* "$T/build/pipeline.log" "$T/alert-line.log"
  ( HARNESS="$T/h" PROJECT=project-3 KEY=TK-249 BUILD="$T/build" ALERTS="$T/alerts" JOB_ID="${DRIVE_JOB_ID-job-1}" TL_STATE="" TL_BEAT=""
    STAMP() { echo 2026-10-20T00:00:00Z; }
    RESULT() { printf '%s\n' "$*" > "$BUILD/RESULT"; }
    tl_beat_start() { echo 4242; }
    _job_finish() { :; }
    eval "$1"
    echo "TL_STATE=$TL_STATE" > "$T/build/after"
    trap -p EXIT >> "$T/build/after" ) </dev/null
}

# --- G1 ---------------------------------------------------------------------
reset; export LK_ACQ_CODE=409 LK_ACQ_BODY='{"holder":"partner-collaborator-1"}'
DRIVE "$ACQ"; rc=$?
[ "$rc" = 3 ] && ok || bad "G1 a held ticket must exit 3 (got $rc)"
grep -q '^BUILD_DEFERRED ticket lock project-3:TK-249 held by partner-collaborator-1' "$T/build/RESULT" 2>/dev/null \
  && ok || bad "G1 RESULT must defer naming key and holder: '$(cat "$T/build/RESULT" 2>/dev/null)'"

# --- G2 ---------------------------------------------------------------------
reset
DRIVE "$ACQ"; rc=$?
[ "$rc" = 0 ] && ok || bad "G2 an acquired lock must let the build go on (rc $rc)"
grep -q "TL_STATE=$T/build/.ticket-lock" "$T/build/after" && ok || bad "G2 TL_STATE must point at the state file"
[ ! -e "$T/build/RESULT" ] && ok || bad "G2 an acquired lock must write no RESULT"

# --- G3 ---------------------------------------------------------------------
reset; export LK_ACQ_CODE=503
DRIVE "$ACQ"; rc=$?
[ "$rc" = 0 ] && ok || bad "G3 an outage must not stop the build (rc $rc)"
grep -q 'ticket lock service unreachable' "$T/build/pipeline.log" 2>/dev/null && ok || bad "G3 an outage must be named in pipeline.log"
grep -q -- '--id ticket-lock-outage-project-3' "$T/alert-line.log" 2>/dev/null && ok || bad "G3 an outage must raise one alert through bin/alert-line.sh"

# --- G4 ---------------------------------------------------------------------
reset; printf 'project-3:TK-249\nL-1\n' > "$T/lk"
YIELD='STAMP() { echo x; }; RESULT() { printf "%s\n" "$*" > "$T/yield"; }; PROJECT=project-3 KEY=TK-249 BUILD="$T"'
rm -f "$T/yield"
( TL_STATE="$T/lk"; eval "$YIELD"; eval "$GATE"; RB_TICKET_LOCK_GATE pr-push ); rc=$?
[ "$rc" = 0 ] && ok || bad "G4 a held lock must let the push through (rc $rc)"
[ ! -e "$T/yield" ] && ok || bad "G4 a held lock must not yield"
export LK_REN_CODE=404 LK_ACQ_CODE=409 LK_ACQ_BODY='{"holder":"partner-collaborator-1"}'
# A top-level shell, as the build is: in a subshell the gate returns 3 without a RESULT.
T="$T" GATE="$GATE" YIELD="$YIELD" bash -c 'TL_STATE="$T/lk"; . "'"$DIR"'/bin/lib/ticket-lock.sh"; eval "$YIELD"; eval "$GATE"; RB_TICKET_LOCK_GATE pr-push'; rc=$?
[ "$rc" = 3 ] && ok || bad "G4 a lost lock must stop the push (rc $rc)"
grep -q '^BUILD_DEFERRED TICKET_LOCK_LOST project-3:TK-249 at pr-push' "$T/yield" 2>/dev/null \
  && ok || bad "G4 a lost lock must defer naming the key: '$(cat "$T/yield" 2>/dev/null)'"
grep -q 'TICKET_LOCK_LOST project-3:TK-249 at pr-push' "$T/pipeline.log" 2>/dev/null && ok || bad "G4 pipeline.log must say the lock was lost"
rm -f "$T/yield"
( TL_STATE="$T/lk"; RB_PR_OPEN=1; eval "$YIELD"; eval "$GATE"; RB_TICKET_LOCK_GATE qa-fix; echo "rc=$? note=$HOLD_YIELD_NOTE" > "$T/g4b" ); rc=$?
[ "$rc" = 0 ] && ok || bad "G4 with a PR open a lost lock must not exit the build (rc $rc)"
grep -q 'rc=3 note=.*TICKET_LOCK_LOST project-3:TK-249 at qa-fix' "$T/g4b" && ok || bad "G4 with a PR open the push is skipped with a note: $(cat "$T/g4b")"
[ ! -e "$T/yield" ] && ok || bad "G4 with a PR open no RESULT is written"

# --- G4c: the lead-review BLOCK case end to end ------------------------------
# A triage tick acquires the key mid-build (the worker rotates the lease), then
# the build reaches its push: the gate must re-acquire and PASS, not yield.
reset; printf 'project-3:TK-249\nL-1\n' > "$T/lk"; rm -f "$T/yield" "$T/lk.lost"
export LK_REN_CODE=404 LK_ACQ_CODE=201 LK_ACQ_BODY='{"lease_id":"L-triage","expires_at":"x"}'
T="$T" GATE="$GATE" YIELD="$YIELD" bash -c 'TL_STATE="$T/lk"; . "'"$DIR"'/bin/lib/ticket-lock.sh"; eval "$YIELD"; eval "$GATE"; RB_TICKET_LOCK_GATE pr-push'; rc=$?
[ "$rc" = 0 ] && ok || bad "G4c a lease rotated by our own triage must let the push through (rc $rc)"
[ ! -e "$T/yield" ] && ok || bad "G4c a rotated lease must not yield: $(cat "$T/yield" 2>/dev/null)"
[ "$(sed -n 2p "$T/lk")" = "L-triage" ] && ok || bad "G4c the build must adopt the rotated lease"

# --- G5 ---------------------------------------------------------------------
for c in "PR_CREATED https://x/pull/1:pr" "BUILD_DEFERRED x:skipped" "PLAN_BLOCKED x:skipped" "DECOMPOSED x:skipped" "ROLLOUT_FILED x:skipped" "EXECUTE_FAILED x:blocked"; do
  reset; mkdir -p "$T/build"; printf 'project-3:TK-249\nL-1\n' > "$T/build/.ticket-lock"
  printf '%s\n' "${c%%:*}" > "$T/build/RESULT"
  ( BUILD="$T/build" TL_STATE="$T/build/.ticket-lock" TL_BEAT=""
    eval "_rel() { $REL
}"; _rel )
  D=$(sed -n 's/^DATA //p' "$CURL_LOG")
  [ "$(jq -r '.outcome' <<<"$D" 2>/dev/null)" = "${c##*:}" ] && ok || bad "G5 RESULT '${c%%:*}' must release with '${c##*:}' (got '$D')"
done

reset; mkdir -p "$T/build"; printf 'project-3:TK-249\nL-1\n' > "$T/build/.ticket-lock"; : > "$T/build/.ticket-lock.lost"
printf 'PR_CREATED x\n' > "$T/build/RESULT"
( BUILD="$T/build" TL_STATE="$T/build/.ticket-lock" TL_BEAT=""; eval "_rel() { $REL
}"; _rel )
D=$(sed -n 's/^DATA //p' "$CURL_LOG")
[ "$(jq -r 'has("lease_id")' <<<"$D" 2>/dev/null)" = false ] && ok || bad "G5 a lost lock is released by key only, which the worker scopes to our holder: $D"
[ ! -e "$T/build/.ticket-lock" ] && ok || bad "G5 a lost lock's state file is removed"

# --- G6: no ledger row -> the acquire block installs the EXIT trap itself ----
reset; DRIVE_JOB_ID="" DRIVE "$ACQ"
grep -q "_job_finish" "$T/build/after" && ok || bad "G6 with no JOB_ID the acquire block must install the _job_finish EXIT trap: $(cat "$T/build/after")"
reset; DRIVE "$ACQ"
grep -q "trap -- '_job_finish' EXIT" "$T/build/after" && bad "G6 with a JOB_ID the block must leave the existing trap alone" || ok

# --- G7: both write gates call the lock gate --------------------------------
fn RB_PUSH | grep -q 'RB_TICKET_LOCK_GATE "\$stage"' && ok || bad "G7 RB_PUSH must call RB_TICKET_LOCK_GATE before it pushes"
fn RB_HOLD_GATE | grep -q 'RB_TICKET_LOCK_GATE "\$1"' && ok || bad "G7 RB_HOLD_GATE (pr-open) must call RB_TICKET_LOCK_GATE"
fn rb_gate_claim_and_workspace >/dev/null
awk '/^rb_gate_claim_and_workspace\(\) \{/{on=1} on' "$DIR/bin/lib/rb/gates.sh" | awk '/job_open "\$PROJECT"/{j=NR} /tl_acquire "\$PROJECT"/{a=NR} END{exit !(j && a && a>j)}' \
  && ok || bad "G7 the acquire must come after job_open inside rb_gate_claim_and_workspace"

# --- G8: the renew loop holds no inherited fd ---------------------------------
if [ -d /proc/self/fd ]; then
  reset; printf 'project-3:TK-249\nL-1\n' > "$T/beat-state"
  exec 7>"$T/flock-7"
  BP=$(TL_BEAT_SECS=30 tl_beat_start "$T/beat-state")
  sleep 1
  # bash keeps an internal fd 10 on /dev/null (job_beat_start's loop has it too);
  # what matters is that no descriptor still points at the caller's lock file.
  HELD=""
  for f in "/proc/$BP/fd"/*; do [ "$(readlink "$f" 2>/dev/null)" = "$T/flock-7" ] && HELD="$HELD ${f##*/}"; done
  kill "$BP" 2>/dev/null; exec 7>&-
  [ -z "$HELD" ] && ok || bad "G8 the renew loop must not hold the caller's flock fd (held:$HELD)"
fi

echo "ticket-lock.cross-harness-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
