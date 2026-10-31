#!/bin/bash
# tests/prequeue-cnr-fallback.bh-8801-test.sh — BH-8801: the pre-queue verdict
# fallback. With MC_PREQUEUE_GATE=0, pq_gate reads the PR body's
# selection-gate marker for the current head (LR_GR_RE, the regex of
# bin/lib/lead-review/gate-record.sh). A record rc 0, no-selection or off
# proceeds as before. A record rc could-not-run, or no record for this head,
# runs the gate-on verdict path (cache, prequeue-gate.yml dispatch) with one
# `PREQUEUE_FALLBACK <slug#num> <head> gate-record=<could-not-run|missing>`
# line. Knob MC_PREQUEUE_FALLBACK (lane merge-conductor, default 1) 0 = off.
#
# Every gate case runs the REAL pq_gate (bin/lib/mc-prequeue.sh) with the real
# hooks (mc-prequeue.d/dispatch.sh, status.sh, call-bound.sh), the real
# lane_knob (bin/lib/lane-gate.sh) over a settings cache, and a stub gh /
# gh_rest that serves a fake PR body. Each case has its own $T/<case> dir.
#
#   F1  gate 0, rc=0 for the head: proceed, "gate off", 0 dispatch, no
#       fallback line, no main tip read (no hook can act)
#   F1b gate 0, rc=no-selection and rc=off: proceed, 0 dispatch, no line
#   F1h gate 0, rc=no-selection, a hook can act: hooks run, tip read once,
#       0 dispatch, proceed
#   F1t gate 0, no time left in the worker: fallback on holds, fallback 0
#       proceeds as before
#   F2  gate 0, no fallback row, rc=could-not-run: 1 dispatch over 2 calls,
#       a pending entry, hold, the exact PREQUEUE_FALLBACK line
#   F3  gate 0, a marker for an older head only: 1 dispatch, gate-record=missing
#   F3b a malformed marker (rc=maybe) for the head: 1 dispatch, missing
#   F3c rc=0 and rc=could-not-run both for the head: 1 dispatch, could-not-run
#   F3d could-not-run for an older head, rc=0 for the head: proceed, no line
#   F4  gate 0, fallback row 0, rc=could-not-run: proceed, 0 dispatch, no
#       fallback line, no pulls read
#   F5  gate 1 (row 1, and no row): 1 dispatch, no fallback line, no pulls read
#   F6  the knob fragment and the rendered registry; lanes-build --check
#   F7  gate 0, the body read fails: proceed as the gate off does, one
#       PREQUEUE_FALLBACK_UNREAD line, 0 dispatch
#   F8  three markers, the head's last: its rc is used
#   F9  call budget 1 s, a body read that stalls: hold, call=gate-record
#   R   _pq_gate_record decision table; Rc agreement with lr_gate_record
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-cnr-fallback.bh-8801-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

NOW=1792814400
GKEY=lane.merge-conductor.mc_prequeue_gate
FKEY=lane.merge-conductor.mc_prequeue_fallback
SLUG=example-org/demo-os
HEAD0=$(printf 'a%.0s' $(seq 40))
HEAD1=$(printf 'e%.0s' $(seq 40))
MAIN=$(printf 'c%.0s' $(seq 40))
# The marker the builder writes (bin/selection-gate.sh, gate-record.sh:7).
mark() { printf '<!-- selection-gate: head=%s suites=%s rc=%s -->' "$1" "${3:-12}" "$2"; }

REG=$( . "$DIR/bin/lib/lanes-registry.sh" && lanes_json_path "$DIR" ) || REG=""
[ -r "$REG" ] || { echo "FAIL: setup: catalog/lanes.json could not be rendered"; exit 1; }

# setup <case> <values-json> <body> — the settings cache and the PR body.
setup() {
  mkdir -p "$T/$1/state"
  jq -nc --argjson fa "$NOW" --argjson v "$2" '{fetched_at:$fa, values:$v, seeded:{}}' > "$T/$1/state/settings-cache.json"
  printf '%s' "$3" > "$T/$1/body"
}

# gate <case> [calls] — the real pq_gate on HEAD1, <calls> times (default 1).
#   Sinks: $C/gh (gh argv), $C/status, $C/log (mc_log), $C/hooks, $C/tipreads,
#   $C/pullreads, $C/out (last answer and PQ_WHY), $C/state/prequeue/.
gate() {
  local c="$1" n="${2:-1}"
  local C="$T/$c"
  mkdir -p "$C/state" "$C/tick" "$C/tmp" "$C/logs" "$C/bin"
  : > "$C/gh"; : > "$C/status"; : > "$C/log"; : > "$C/hooks"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/logs/ALERTS.log"\n' "$C" > "$C/bin/lane-alert.sh"; chmod +x "$C/bin/lane-alert.sh"
  ( export HARNESS="$C" LANE_REGISTRY="$REG" LANE_GATE_NOW="$NOW" JOBS_URL='' HARNESS_JOBS_URL='' TMPDIR="$C/tmp"
    P=""; MC_H="$C"; MC_STATE_DIR="$C/state"; MC_TICK_ID=t8801; MC_TICK_DIR="$C/tick"; MC_LOG="$C/mclog"
    . "$DIR/bin/lib/lane-gate.sh" || exit 1
    . "$DIR/bin/lib/fanin.sh"; . "$DIR/bin/lib/mc/queue.sh"
    . "$DIR/bin/lib/mc-prequeue.sh" || exit 1
    mc_safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
    mc_log() { printf '%s\n' "$*" >> "$C/log"; }
    mc_attempt_has() { return 1; }; mc_attempt_put() { :; }; mc_use_token() { :; }
    vs_publish() { printf '%s %s %s\n' "$LEAD_VERDICT_CONTEXT" "$3" "$4" >> "$C/status"; }
    pq_restamp_wanted() { [ "${RS_WANT:-1}" = 1 ]; }
    pq_restamp() { echo restamp >> "$C/hooks"; echo none; }
    pq_mignum_wanted() { [ "${MN_WANT:-1}" = 1 ]; }
    pq_mignum() { echo mignum >> "$C/hooks"; echo none; }
    pq_adopt_run() { return 1; }
    pq_impact_reuse() { _pq_ir=none; }; pq_dispatch_veto() { return 1; }
    gh() { printf '%s\n' "$*" >> "$C/gh"; return 0; }
    gh_rest() {
      case "$2" in
        */commits/*) echo tip >> "$C/tipreads"; printf '{"sha":"%s"}' "$MAIN" ;;
        */pulls/71) echo pull >> "$C/pullreads"; [ -n "${BODY_DOWN:-}" ] && return 44
          [ -n "${BODY_STALL:-}" ] && { sleep "$BODY_STALL" || return 75; }
          jq -nc --rawfile b "$C/body" '{body: (if $b == "" then null else $b end)}' ;;
        */actions/workflows/prequeue-gate.yml) printf '{}' ;;
        */runs\?*) printf '{"workflow_runs":[]}' ;;
        *) return 44 ;;
      esac
    }
    local i
    for ((i = 0; i < n; i++)); do
      pq_gate "$SLUG" 71 "https://github.com/$SLUG/pull/71" "$HEAD1" main > "$C/word"
    done
    printf 'word=%s why=%s\n' "$(cat "$C/word")" "$PQ_WHY" > "$C/out"
  ) > "$C/err" 2>&1
}
dispatches() { grep -c '^workflow run prequeue-gate.yml ' "$T/$1/gh" 2>/dev/null; }
fblines() { grep -c 'PREQUEUE_FALLBACK' "$T/$1/log" 2>/dev/null; }
reads() { [ -s "$T/$1/$2" ] && wc -l < "$T/$1/$2" | tr -d ' ' || echo 0; }
word() { sed -n 's/^word=\([a-z]*\) .*/\1/p' "$T/$1/out" 2>/dev/null; }
dump() { cat "$T/$1/out" "$T/$1/err" 2>/dev/null | head -c 600; }

# ── F1: rc=0 for the head — proceed as before ────────────────────────────────
setup f1 "{\"$GKEY\":\"0\"}" "Closes #20 $(mark "$HEAD1" 0)"; RS_WANT=0 MN_WANT=0 gate f1
[ "$(word f1)" = proceed ] && ok || bad "F1 rc=0: proceed ($(dump f1))"
[ "$(dispatches f1)" = 0 ] && ok || bad "F1 rc=0: no dispatch (got $(dispatches f1))"
[ "$(fblines f1)" = 0 ] && ok || bad "F1 rc=0: no PREQUEUE_FALLBACK line ($(cat "$T/f1/log"))"
[ "$(reads f1 tipreads)" = 0 ] && ok || bad "F1 rc=0, no hook can act: no main tip read (got $(reads f1 tipreads))"
grep -qx 'prequeue-verdict success gate off' "$T/f1/status" && ok || bad "F1 rc=0: status \"gate off\" ($(cat "$T/f1/status"))"
[ "$(reads f1 pullreads)" = 1 ] && ok || bad "F1 the PR body was read once (got $(reads f1 pullreads))"

# ── F1b: rc=no-selection and rc=off — proceed as before ──────────────────────
for rc in no-selection off; do
  setup "f1b-$rc" "{\"$GKEY\":\"0\"}" "$(mark "$HEAD1" "$rc")"; RS_WANT=0 MN_WANT=0 gate "f1b-$rc"
  [ "$(word "f1b-$rc")" = proceed ] && [ "$(dispatches "f1b-$rc")" = 0 ] && [ "$(fblines "f1b-$rc")" = 0 ] && ok \
    || bad "F1b rc=$rc: proceed, no dispatch, no line ($(dump "f1b-$rc"))"
  grep -qx 'prequeue-verdict success gate off' "$T/f1b-$rc/status" && ok || bad "F1b rc=$rc: status \"gate off\" ($(cat "$T/f1b-$rc/status"))"
done

# ── F1t: no time left in this worker ─────────────────────────────────────────
printf -v NOWS '%(%s)T' -1
setup f1t "{\"$GKEY\":\"0\"}" "$(mark "$HEAD1" could-not-run)"; RS_WANT=0 MN_WANT=0 MC_WORKER_DEADLINE_AT=$NOWS gate f1t
[ "$(word f1t)" = hold ] && [ "$(dispatches f1t)" = 0 ] && ok || bad "F1t no budget, fallback on: hold, no dispatch ($(dump f1t))"
setup f1c "{\"$GKEY\":\"0\",\"$FKEY\":\"0\"}" "$(mark "$HEAD1" could-not-run)"; RS_WANT=0 MN_WANT=0 MC_WORKER_DEADLINE_AT=$NOWS gate f1c
[ "$(word f1c)" = proceed ] && ok || bad "F1t no budget, fallback 0: proceed as before ($(dump f1c))"

# ── F2: rc=could-not-run, no fallback row (the registry default 1) ──────────
setup f2 "{\"$GKEY\":\"0\"}" "body text
$(mark "$HEAD1" could-not-run 2946)"; RS_WANT=0 MN_WANT=0 gate f2 2
[ "$(dispatches f2)" = 1 ] && ok || bad "F2 could-not-run: exactly 1 dispatch over 2 calls (got $(dispatches f2); $(dump f2))"
grep -q "^workflow run prequeue-gate.yml -R $SLUG --ref main -f pr=71 -f head=$HEAD1 -f main=$MAIN" "$T/f2/gh" && ok || bad "F2 the dispatch names this PR, head and main ($(cat "$T/f2/gh"))"
PF=$(find "$T/f2/state/prequeue" -type f -name "*_71_${HEAD1}_${MAIN}" 2>/dev/null | head -1)
[ -n "$PF" ] && grep -q '^pending ' "$PF" && ok || bad "F2 a pending entry for (71, head, main) ($(find "$T/f2/state" -type f 2>/dev/null))"
[ "$(word f2)" = hold ] && ok || bad "F2 could-not-run: hold ($(dump f2))"
grep -qx "PREQUEUE_FALLBACK $SLUG#71 $HEAD1 gate-record=could-not-run" "$T/f2/log" && ok || bad "F2 the PREQUEUE_FALLBACK line ($(grep -v PREQUEUE_CALL "$T/f2/log"))"
! grep -q 'gate off' "$T/f2/status" && ok || bad "F2 publishes no \"gate off\" ($(cat "$T/f2/status"))"

# ── F3: a marker for an older head only ──────────────────────────────────────
setup f3 "{\"$GKEY\":\"0\"}" "$(mark "$HEAD0" 0)"; RS_WANT=0 MN_WANT=0 gate f3
[ "$(dispatches f3)" = 1 ] && ok || bad "F3 older head only: 1 dispatch (got $(dispatches f3); $(dump f3))"
grep -qx "PREQUEUE_FALLBACK $SLUG#71 $HEAD1 gate-record=missing" "$T/f3/log" && ok || bad "F3 gate-record=missing ($(grep -v PREQUEUE_CALL "$T/f3/log"))"
setup f3b "{\"$GKEY\":\"0\"}" "$(mark "$HEAD1" maybe)"; RS_WANT=0 MN_WANT=0 gate f3b
[ "$(dispatches f3b)" = 1 ] && grep -qx "PREQUEUE_FALLBACK $SLUG#71 $HEAD1 gate-record=missing" "$T/f3b/log" && ok \
  || bad "F3b rc=maybe is no marker: 1 dispatch, missing (got $(dispatches f3b); $(grep -v PREQUEUE_CALL "$T/f3b/log"))"
setup f3c "{\"$GKEY\":\"0\"}" "$(mark "$HEAD1" 0) $(mark "$HEAD1" could-not-run)"; RS_WANT=0 MN_WANT=0 gate f3c
[ "$(dispatches f3c)" = 1 ] && grep -qx "PREQUEUE_FALLBACK $SLUG#71 $HEAD1 gate-record=could-not-run" "$T/f3c/log" && ok \
  || bad "F3c rc=0 and could-not-run for the head: could-not-run wins (got $(dispatches f3c); $(grep -v PREQUEUE_CALL "$T/f3c/log"))"
setup f3d "{\"$GKEY\":\"0\"}" "$(mark "$HEAD0" could-not-run) $(mark "$HEAD1" 0)"; RS_WANT=0 MN_WANT=0 gate f3d
[ "$(word f3d)" = proceed ] && [ "$(dispatches f3d)" = 0 ] && [ "$(fblines f3d)" = 0 ] && ok \
  || bad "F3d could-not-run for an older head, rc=0 for this one: proceed, no line ($(dump f3d))"

# ── F4: fallback row 0 — today's gate-off path ───────────────────────────────
setup f4 "{\"$GKEY\":\"0\",\"$FKEY\":\"0\"}" "$(mark "$HEAD1" could-not-run)"; RS_WANT=0 MN_WANT=0 gate f4
[ "$(word f4)" = proceed ] && ok || bad "F4 fallback 0: proceed ($(dump f4))"
[ "$(dispatches f4)" = 0 ] && [ "$(fblines f4)" = 0 ] && ok || bad "F4 fallback 0: no dispatch, no fallback line (dispatch $(dispatches f4), lines $(fblines f4))"
[ "$(reads f4 pullreads)" = 0 ] && [ "$(reads f4 tipreads)" = 0 ] && ok || bad "F4 fallback 0: no pulls read, no tip read"
grep -qx 'prequeue-verdict success gate off' "$T/f4/status" && ok || bad "F4 status \"gate off\" ($(cat "$T/f4/status"))"
# F4b: fallback 0 while a hook can act — the hooks run, still no fallback.
setup f4b "{\"$GKEY\":\"0\",\"$FKEY\":\"0\"}" "$(mark "$HEAD1" could-not-run)"; gate f4b
[ "$(word f4b)" = proceed ] && [ "$(dispatches f4b)" = 0 ] && [ "$(fblines f4b)" = 0 ] && [ "$(reads f4b pullreads)" = 0 ] && ok \
  || bad "F4b fallback 0, hooks on: proceed, no dispatch, no fallback line, no pulls read ($(dump f4b); dispatch $(dispatches f4b))"
[ "$(tr '\n' ' ' < "$T/f4b/hooks")" = "restamp mignum " ] && ok || bad "F4b the hooks ran ($(cat "$T/f4b/hooks"))"

# ── F5: gate on — unchanged, no fallback ─────────────────────────────────────
for c in f5 f5n; do
  if [ "$c" = f5 ]; then setup f5 "{\"$GKEY\":\"1\"}" "$(mark "$HEAD1" could-not-run)"; else setup f5n '{}' "$(mark "$HEAD1" could-not-run)"; fi
  RS_WANT=0 MN_WANT=0 gate "$c"
  [ "$(dispatches "$c")" = 1 ] && ok || bad "F5 $c gate on: 1 dispatch (got $(dispatches "$c"))"
  [ "$(fblines "$c")" = 0 ] && [ "$(reads "$c" pullreads)" = 0 ] && ok || bad "F5 $c gate on: no fallback line, no pulls read"
done

# ── F6: the knob ─────────────────────────────────────────────────────────────
KF="$DIR/catalog/lanes.d/merge-conductor.knobs.d/MC_PREQUEUE_FALLBACK.json"
jq -e '.env=="MC_PREQUEUE_FALLBACK" and .type=="int" and .default==1 and .min==0 and .max==1 and .zero_means=="off" and .read_in=="bin/lib/mc-prequeue.sh"' "$KF" >/dev/null 2>&1 \
  && ok || bad "F6 the knob fragment $KF (env, int, default 1, 0..1, zero_means off)"
jq -e '[.. | objects | select(.env? == "MC_PREQUEUE_FALLBACK" and .default? == 1)] | length >= 1' "$REG" >/dev/null 2>&1 \
  && ok || bad "F6 the rendered registry carries MC_PREQUEUE_FALLBACK"
jq -e '.lanes["merge-conductor"].knobs | tostring | contains("MC_PREQUEUE_FALLBACK")' "$REG" >/dev/null 2>&1 \
  || jq -e '[.. | objects | select(has("knobs")) | .knobs | tostring | select(contains("MC_PREQUEUE_FALLBACK"))] | length >= 1' "$REG" >/dev/null 2>&1 \
  && ok || bad "F6 the knob sits under a lane's knobs in the registry"
HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/lanes-build.sh" --check >/dev/null 2>&1 && ok || bad "F6 bin/lanes-build.sh --check"

# ── R: _pq_gate_record decision table ────────────────────────────────────────
# rec <case> <body> -> _pq_gr, through the real function and the stub body read.
rec() {
  local C="$T/rec-$1"
  mkdir -p "$C/tmp"; printf '%s' "$2" > "$C/body"
  ( export TMPDIR="$C/tmp"; MC_STATE_DIR="$C"; MC_H="$C"
    . "$DIR/bin/lib/mc/queue.sh" || exit 1; . "$DIR/bin/lib/mc-prequeue.sh" || exit 1
    mc_log() { :; }
    gh_rest() {
      case "$2" in
        */pulls/71) [ -n "${BODY_DOWN:-}" ] && return 44
          [ -n "${BODY_RAW:-}" ] && { printf '%s' "$BODY_RAW"; return 0; }
          jq -nc --rawfile b "$C/body" '{body: (if $b == "" then null else $b end)}' ;;
        *) return 44 ;;
      esac
    }
    _pq_gr=""; _pq_key="$SLUG#71"
    _pq_gate_record "$SLUG" 71 "$HEAD1"
    printf '%s' "$_pq_gr" )
}
row() { local got; got=$(rec "$1" "$3"); [ "$got" = "$2" ] && ok || bad "R $1: _pq_gr=$2 (got '$got')"; }
row rc0      0             "$(mark "$HEAD1" 0)"
row nosel    no-selection  "$(mark "$HEAD1" no-selection)"
row off      off           "$(mark "$HEAD1" off)"
row cnr      could-not-run "$(mark "$HEAD1" could-not-run)"
row older    missing       "$(mark "$HEAD0" 0)"
row none     missing       "Closes #20"
row empty    missing       ""
row both1    could-not-run "$(mark "$HEAD0" 0)
$(mark "$HEAD1" could-not-run)"
row both2    0             "$(mark "$HEAD0" could-not-run)
$(mark "$HEAD1" 0)"
row prefix   missing       "$(mark "${HEAD1:0:12}" 0)"
row prose    missing       "the gate said rc=could-not-run for head=$HEAD1"
row nospace  missing       "<!--selection-gate: head=$HEAD1 suites=1 rc=0-->"
row case     missing       "$(mark "$HEAD1" Could-Not-Run)"
row crlf     could-not-run "$(mark "$HEAD1" could-not-run)"$'\r\n'"next line"
row crlf0    0             "$(mark "$HEAD1" 0)"$'\r\n'
row maybe    missing       "$(mark "$HEAD1" maybe)"
row third    off           "$(mark "$HEAD0" 0) $(mark "$(printf 'b%.0s' $(seq 40))" could-not-run) $(mark "$HEAD1" off)"
got=$(BODY_DOWN=1 rec down "x"); [ "$got" = unread ] && ok || bad "R body read rc 44: unread (got '$got')"
got=$(BODY_RAW='not json' rec badjson "x"); [ "$got" = unread ] && ok || bad "R a body answer that is not JSON: unread (got '$got')"

# ── Rc: the same answer as lr_gate_record (one regex, LR_GR_RE) ──────────────
R="$T/f7c-repo"
if git init -q "$R" 2>/dev/null && mkdir -p "$R/bin" && echo '#!/bin/bash' > "$R/bin/selection-gate.sh" \
   && git -C "$R" add -A && git -C "$R" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null; then
  SHA=$(git -C "$R" rev-parse HEAD); git -C "$R" update-ref refs/remotes/origin/main "$SHA"
  for rc in 0 could-not-run; do
    lr=$( . "$DIR/bin/lib/lead-review/gate-record.sh" && lr_gate_record "$(mark "$SHA" "$rc")" "$SHA" ticket/x block "$R" main )
    pq=$( HEAD1=$SHA rec "f7c-$rc" "$(mark "$SHA" "$rc")" )
    [ "$lr" = "ok 12 $rc" ] && [ "$pq" = "$rc" ] && ok || bad "Rc rc=$rc: lr_gate_record '$lr' and _pq_gate_record '$pq' agree"
  done
else
  bad "Rc setup: a scratch git repo"
fi

# ── F7: the body read fails — the gate-off path, one UNREAD line ────────────
setup f7 "{\"$GKEY\":\"0\"}" "$(mark "$HEAD1" could-not-run)"; RS_WANT=0 MN_WANT=0 BODY_DOWN=1 gate f7
[ "$(word f7)" = proceed ] && ok || bad "F7 body unread: proceed as the gate off does ($(dump f7))"
[ "$(dispatches f7)" = 0 ] && [ "$(fblines f7)" = 1 ] && ok \
  || bad "F7 body unread: no dispatch, one line (dispatch $(dispatches f7), lines $(fblines f7))"
grep -qx "PREQUEUE_FALLBACK_UNREAD $SLUG#71 $HEAD1" "$T/f7/log" && ok || bad "F7 the PREQUEUE_FALLBACK_UNREAD line ($(grep -v PREQUEUE_CALL "$T/f7/log"))"
grep -qx 'prequeue-verdict success gate off' "$T/f7/status" && ok || bad "F7 status \"gate off\" ($(cat "$T/f7/status"))"
[ "$(reads f7 tipreads)" = 0 ] && ok || bad "F7 no hook can act: no main tip read (got $(reads f7 tipreads))"

# ── F8: data past the first marker: the head's own marker is the third ──────
setup f8 "{\"$GKEY\":\"0\"}" "$(mark "$HEAD0" 0)
$(mark "$(printf 'b%.0s' $(seq 40))" 0)
$(mark "$HEAD1" could-not-run)"; RS_WANT=0 MN_WANT=0 gate f8
[ "$(dispatches f8)" = 1 ] && grep -qx "PREQUEUE_FALLBACK $SLUG#71 $HEAD1 gate-record=could-not-run" "$T/f8/log" && ok \
  || bad "F8 the head's third marker is read: 1 dispatch, could-not-run (got $(dispatches f8); $(grep -v PREQUEUE_CALL "$T/f8/log"))"

# ── F9: the body read runs inside the call budget ───────────────────────────
setup f9 "{\"$GKEY\":\"0\",\"lane.merge-conductor.mc_prequeue_call_budget_s\":\"1\"}" "$(mark "$HEAD1" could-not-run)"
RS_WANT=0 MN_WANT=0 BODY_STALL=30 gate f9
[ "$(word f9)" = hold ] && [ "$(dispatches f9)" = 0 ] && [ "$(fblines f9)" = 0 ] && ok \
  || bad "F9 a stalled body read past the budget: hold, no dispatch, no line ($(dump f9))"
grep -q 'PREQUEUE_CALL_TIMEOUT call=gate-record ' "$T/f9/log" && ok || bad "F9 the timeout line names call=gate-record ($(cat "$T/f9/log"))"
[ ! -s "$T/f9/status" ] && ok || bad "F9 a hold publishes nothing ($(cat "$T/f9/status"))"

# ── F1h: rc=no-selection, a hook can act — the hook path is unchanged ────────
setup f1h "{\"$GKEY\":\"0\"}" "$(mark "$HEAD1" no-selection)"; RS_WANT=0 gate f1h
[ "$(word f1h)" = proceed ] && ok || bad "F1h no-selection: proceed ($(dump f1h))"
[ "$(tr '\n' ' ' < "$T/f1h/hooks")" = "restamp mignum " ] && ok || bad "F1h the hooks ran ($(cat "$T/f1h/hooks"))"
[ "$(reads f1h tipreads)" = 1 ] && [ "$(dispatches f1h)" = 0 ] && [ "$(fblines f1h)" = 0 ] && ok \
  || bad "F1h tip read once, 0 dispatch, no fallback line (tip $(reads f1h tipreads), dispatch $(dispatches f1h))"
grep -qx 'prequeue-verdict success gate off' "$T/f1h/status" && ok || bad "F1h status \"gate off\" ($(cat "$T/f1h/status"))"

echo "prequeue-cnr-fallback.bh-8801: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
