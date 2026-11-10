#!/bin/bash
# tests/plan-blocked-stop.bh-8733-test.sh — BH-8733 (lifecycle 3/6): the pool's
# plan-blocked stop (bin/lib/plan-blocked-stop.sh, pbs_stop_check) decides from
# the ticket's build_queue phase alone. It refuses plan_blocked, abandoned,
# ejected and in_queue, and it reads no hub build record.
#
# Driven, not grepped, for the behavior. The REAL bin/lib/plan-blocked-stop.sh,
# bin/lib/pool-lifecycle.sh and bin/lib/jobs/lifecycle.sh run against
# tests/lib/fake-lifecycle.bh-8733.sh (a local fake of _jobs_req, 0 network).
#   G1-G9   the phase table: refuse plan_blocked/abandoned/ejected/in_queue,
#           pass every other phase, NULL, no row, an outage, knob 0, lane keys.
#   G10-G13 the files are not read: PLAN_BLOCKED records with phase NULL pass;
#           a bash xtrace of the gate and PATH shims see no builds/ path; the
#           lib text has no record path; no legacy gate file.
#   G14-G16 near misses: Plan_Blocked passes; plan_blocked with no record dir
#           refuses; the gate sends one GET /api/queue and nothing else.
#   K1      the knob fragments.
# The box runs builds as root, so a chmod 000 of builds/ proves nothing there;
# G11 uses the xtrace (every expanded command of the gate) instead.
# Needs node for the fake; HARNESS_ALLOW_SKIP=1 turns a missing node into SKIP.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/plan-blocked-stop.bh-8733-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/fake-lifecycle.bh-8733.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
if ! command -v node >/dev/null 2>&1; then
  [ "${HARNESS_ALLOW_SKIP:-0}" = 1 ] && { echo "SKIP: plan-blocked-stop.bh-8733: no node for the fake"; exit 0; }
  echo "FAIL: node is required (the fake runs the real lifecycleCheck); set HARNESS_ALLOW_SKIP=1 to skip"; exit 1
fi

LIB="$SRC/bin/lib/plan-blocked-stop.sh"
H="$T/h"; mkdir -p "$H/bin" "$H/builds" "$T/fakebin" "$T/shim"
for v in gh curl flyctl; do
  printf '#!/bin/bash\nprintf "%%s %%s\\n" %s "$*" >> "%s/vendor.log"\nexit 1\n' "$v" "$T" > "$T/fakebin/$v"
  chmod +x "$T/fakebin/$v"
done
# The read shims (G11): each logs any argument that names builds/, then runs the real tool.
for v in cat head tail stat ls find sed awk grep; do
  real=$(command -v "$v") || continue
  printf '#!/bin/bash\nfor a in "$@"; do case "$a" in *builds*) printf "%%s %%s\\n" %s "$a" >> "%s/reads.log" ;; esac; done\nexec %s "$@"\n' \
    "$v" "$T" "$real" > "$T/shim/$v"
  chmod +x "$T/shim/$v"
done

N=0
fresh() { N=$((N+1)); lf_init "$T/lf$N"; SAY="$T/say$N.log"; : > "$SAY"; }
# GATE <key> [VAR=value ...] -> the rc of pbs_stop_check bh <key> <n> <job>
GATE() {
  local k="$1"; shift
  ( for kv in "$@"; do export "${kv?}"; done
    export HARNESS="$H" PATH="${GATE_PATH:-$T/fakebin:$PATH}"
    say() { printf '%s\n' "$*" >> "$SAY"; }
    # shellcheck disable=SC1090,SC1091
    . "$SRC/bin/lib/jobs/lifecycle.sh" || exit 9
    # shellcheck disable=SC1090
    . "$LIB" || exit 9
    if [ -n "${GATE_TRACE:-}" ]; then exec 7>"$GATE_TRACE"; BASH_XTRACEFD=7; set -x; fi
    pbs_stop_check bh "$k" "${k#BH-}" "$T/$k.json" )
}
cnt() { local c; c=$(grep -c -- "${2:-.}" "$1" 2>/dev/null); echo "${c:-0}"; }
# rec <key> — a hub record that the BH-8309 record gate would have refused on.
rec() {
  local d="$H/builds/pool-bh-$1-202611011700"; mkdir -p "$d"
  printf 'PLAN_BLOCKED /root/harness/builds/cromford-%s-x/plan.md\n' "$1" > "$d/RESULT"
  printf 'BLOCKED: q\n' > "$d/plan.md"; printf 'After: BH-1\n' > "$d/plan-blocked.after"; : > "$d/plan-blocked.asked"
  printf 'other\n' > "$d/plan-blocked.class"
}

# ═════ G1-G9: the phase table ═══════════════════════════════════════════════
# G1 plan_blocked refuses; the line has phase_at and the question.
fresh; lf_row bh BH-9601 plan_blocked "Which Fly org owns the test host? The plan cannot pick one."
GATE BH-9601; R=$?
[ "$R" = 1 ] && grep -qx 'skipping BH-9601: phase plan_blocked since 2026-11-01T16:00:00Z — not spawned; re-entry is the lifecycle owner'"'"'s move. Question: Which Fly org owns the test host? The plan cannot pick one.' "$SAY" \
  && ok || bad "G1 plan_blocked must refuse with the question (rc $R; say $(cat "$SAY"))"
# G1b the question in the line is cut at 200 chars.
fresh; lf_row bh BH-9602 plan_blocked "$(printf 'q%.0s' $(seq 1 400))"
GATE BH-9602; R=$?
L=$(grep -o 'Question: .*' "$SAY"); [ "$R" = 1 ] && [ "${#L}" = $((10 + 200)) ] && ok || bad "G1b the question excerpt is 200 chars (got ${#L})"
# G2 knob 0 passes, with 0 calls.
fresh; lf_row bh BH-9603 plan_blocked "q"
GATE BH-9603 POOL_PLAN_BLOCKED_STOP=0; R=$?
[ "$R" = 0 ] && [ "$(lf_calls)" = 0 ] && ok || bad "G2 POOL_PLAN_BLOCKED_STOP=0 passes with 0 calls (rc $R)"
# G3 a lane key passes, with 0 calls.
for k in RB-8765-abcd1234 RR-77-abc12345 LR-BH-1 FXR-BH-1-2 CP-BH-1; do
  fresh; lf_row bh "$k" plan_blocked "q"
  GATE "$k"; R=$?
  [ "$R" = 0 ] && [ "$(lf_calls)" = 0 ] && ok || bad "G3 lane key $k passes with 0 calls (rc $R)"
done
# G4-G6 abandoned, ejected and in_queue refuse.
fresh; lf_row bh BH-9604 abandoned; GATE BH-9604; R=$?
[ "$R" = 1 ] && grep -q "^skipping BH-9604: phase abandoned since .* — not spawned; re-entry is the lifecycle owner's move$" "$SAY" && ok || bad "G4 abandoned refuses (rc $R; $(cat "$SAY"))"
fresh; lf_row bh BH-9605 ejected; GATE BH-9605; R=$?
[ "$R" = 1 ] && grep -q "^skipping BH-9605: phase ejected since .* — not spawned; re-entry is the lifecycle owner's move$" "$SAY" && ok || bad "G5 ejected refuses (rc $R; $(cat "$SAY"))"
fresh; lf_row bh BH-9606 in_queue; GATE BH-9606; R=$?
[ "$R" = 1 ] && grep -q '^skipping BH-9606: phase in_queue since .* — not spawned; the PR is in the merge queue, and the conductor owns the exit$' "$SAY" && ok || bad "G6 in_queue refuses (rc $R; $(cat "$SAY"))"
# G7 every other phase and NULL pass, silently.
for ph in "" triaged planned building pr_open merged closed; do
  fresh; lf_row bh BH-9607 "$ph"; GATE BH-9607; R=$?
  [ "$R" = 0 ] && [ ! -s "$SAY" ] && ok || bad "G7 phase '${ph:-NULL}' passes with no line (rc $R; $(cat "$SAY"))"
done
# G8 no row passes.
fresh; GATE BH-9608; R=$?
[ "$R" = 0 ] && [ ! -s "$SAY" ] && ok || bad "G8 no row passes (rc $R)"
# G9 an outage passes, with one line; it is never read as plan_blocked.
fresh; lf_row bh BH-9609 plan_blocked "q"; echo 1 > "$LF_DIR/rc"
GATE BH-9609; R=$?
[ "$R" = 0 ] && [ "$(cnt "$SAY")" = 1 ] && grep -qx 'BH-9609: phase unreadable — not gated this tick' "$SAY" && ok || bad "G9 outage passes with one line (rc $R; $(cat "$SAY"))"
# G9b no HARNESS root, or no project: pass, 0 calls.
fresh; lf_row bh BH-9610 plan_blocked "q"
( unset HARNESS H; say() { :; }
  # shellcheck disable=SC1090,SC1091
  . "$SRC/bin/lib/jobs/lifecycle.sh"; . "$LIB"; pbs_stop_check bh BH-9610 9610 ""; echo "rc=$?" > "$T/g9b" )
( export HARNESS="$H"; say() { :; }
  # shellcheck disable=SC1090,SC1091
  . "$SRC/bin/lib/jobs/lifecycle.sh"; . "$LIB"; pbs_stop_check "" BH-9610 9610 ""; echo "rc=$?" >> "$T/g9b" )
[ "$(tr '\n' ' ' < "$T/g9b")" = "rc=0 rc=0 " ] && [ "$(lf_calls)" = 0 ] && ok || bad "G9b no root / no project passes with 0 calls ($(cat "$T/g9b"))"

# ═════ G10-G13: the files are not read ══════════════════════════════════════
# G10 hub records say PLAN_BLOCKED (and carry every plan-blocked.* file), phase NULL: pass.
fresh; lf_row bh BH-9611; rec BH-9611
GATE BH-9611; R=$?
[ "$R" = 0 ] && ok || bad "G10 PLAN_BLOCKED records with phase NULL must pass (rc $R)"
# G11 the same, traced: no expanded command of the gate and no read tool names builds/.
fresh; lf_row bh BH-9612; rec BH-9612; : > "$T/reads.log"
GATE_TRACE="$T/trace.log" GATE_PATH="$T/shim:$T/fakebin:$PATH" GATE BH-9612; R=$?
[ -s "$T/trace.log" ] && grep -q 'pbs_stop_check' "$T/trace.log" && ok || bad "G11 setup: the xtrace caught nothing"
TR=$(grep -c 'builds' "$T/trace.log"); RD=$(grep -c . "$T/reads.log")
[ "$R" = 0 ] && [ "$TR" = 0 ] && [ "$RD" = 0 ] && ok || bad "G11 the gate touched builds/ ($TR trace lines, $RD shim reads): $(grep builds "$T/trace.log" | head -3)"
fresh; lf_row bh BH-9613 plan_blocked "q"; rec BH-9613; : > "$T/reads.log"
GATE_TRACE="$T/trace2.log" GATE_PATH="$T/shim:$T/fakebin:$PATH" GATE BH-9613; R=$?
[ "$R" = 1 ] && [ "$(grep -c 'builds' "$T/trace2.log")" = 0 ] && [ ! -s "$T/reads.log" ] && ok || bad "G11 a refusal reads no builds/ path either"
# G12 the lib text has no record path.
TXT=$(grep -v '^[[:space:]]*#' "$LIB")
case "$TXT" in *"builds/"*|*"/RESULT"*|*"plan-blocked."*|*_pbs_newest*) bad "G12 bin/lib/plan-blocked-stop.sh still names a record path" ;; *) ok ;; esac
# G13 no legacy gate file returns.
[ ! -e "$SRC/bin/lib/plan-blocked-stop-legacy.sh" ] && ok || bad "G13 bin/lib/plan-blocked-stop-legacy.sh must not exist"
P_TXT=$(cat "$SRC/bin/fly-pool.sh")
case "$P_TXT" in *pbs_legacy*|*plan-blocked-stop-legacy*) bad "G13 bin/fly-pool.sh names the legacy gate" ;; *) ok ;; esac

# ═════ G14-G16: near misses ═════════════════════════════════════════════════
fresh; lf_row bh BH-9614 Plan_Blocked "q"; GATE BH-9614; R=$?
[ "$R" = 0 ] && ok || bad "G14 'Plan_Blocked' is not plan_blocked: pass (rc $R)"
fresh; lf_row bh BH-9615 plan_blocked "the q"; GATE BH-9615; R=$?
[ "$R" = 1 ] && [ -z "$(ls -d "$H"/builds/pool-bh-BH-9615-* 2>/dev/null)" ] && ok || bad "G15 plan_blocked with no record dir refuses (rc $R)"
fresh; lf_row bh BH-9616 building; GATE BH-9616; GATE BH-9616
[ "$(lf_calls)" = 2 ] && [ "$(lf_calls 'GET /api/queue?project=bh&key=BH-9616&limit=1')" = 2 ] && [ ! -s "$LF_DIR/unimpl.log" ] \
  && ok || bad "G16 one GET /api/queue per gate call and nothing else: $(cat "$LF_DIR/req.log")"

# ═════ K1: the knobs ════════════════════════════════════════════════════════
KD="$SRC/catalog/lanes.d/fly-pool.knobs.d"
[ "$(jq -r '.default' "$KD/POOL_PLAN_BLOCKED_STOP.json")" = 1 ] && [ "$(jq -r '.read_in' "$KD/POOL_PLAN_BLOCKED_STOP.json")" = bin/lib/plan-blocked-stop.sh ] \
  && grep -q '${POOL_PLAN_BLOCKED_STOP:-1}' "$LIB" && ok || bad "K1 POOL_PLAN_BLOCKED_STOP: default 1, read in bin/lib/plan-blocked-stop.sh"
[ "$(jq -r '.default' "$KD/POOL_LIFECYCLE_QUESTION_MAX.json" 2>/dev/null)" = 2000 ] && [ "$(jq -r '.max' "$KD/POOL_LIFECYCLE_QUESTION_MAX.json" 2>/dev/null)" = 2000 ] \
  && [ "$(jq -r '.read_in' "$KD/POOL_LIFECYCLE_QUESTION_MAX.json" 2>/dev/null)" = bin/lib/pool-lifecycle.sh ] \
  && grep -q '${POOL_LIFECYCLE_QUESTION_MAX:-2000}' "$SRC/bin/lib/pool-lifecycle.sh" 2>/dev/null \
  && ok || bad "K1 POOL_LIFECYCLE_QUESTION_MAX: default 2000, max 2000, read in bin/lib/pool-lifecycle.sh"
[ ! -e "$KD/POOL_PLAN_BLOCKED_MAX.json" ] && [ ! -e "$KD/POOL_PLAN_BLOCKED_WINDOW_S.json" ] && ok || bad "K1 the knobs of the removed record gate are gone"

[ ! -s "$T/vendor.log" ] && ok || bad "a vendor client was called: $(cat "$T/vendor.log")"
echo "plan-blocked-stop.bh-8733: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
