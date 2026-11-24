#!/bin/bash
# tests/mc-prequeue-park.bh-10022-test.sh — BH-10022: a head that is red on the
# same invariant on N different mains is parked. The gate does not dispatch the
# pre-queue run again for that head on a newer main.
#
# THE DEFECT THIS PINS. bin/lib/mc-prequeue.d/dispatch.sh pq_resolve dispatched
# the gate again for every new main tip once the last red was older than
# MC_PREQUEUE_FRESH_S. Head 49c1689d56 (2026-11-10..24) was gated 10 times on
# 10 mains, red every time on invariant:lanes-registry, about 9 runner minutes
# per run. Knob MC_PREQUEUE_PARK_AFTER_REDS (default 2, 0 = off).
#
#   K1  reds on main A and main B, the same why, current main C: red, 0
#       dispatches, PQ_MAIN = B (the newest red), PQ_PATH is B's entry and its
#       .why names the invariant (the row reason reads it), one `PREQUEUE park`
#       line names the invariant, the count and both mains
#   K2  reds on A and B with different whys: 1 dispatch, hold, no park line
#   K3  the same head on the same main (a red cached on C): red, 0 dispatches,
#       no park line (the cache read answers before pq_resolve, as before)
#   K4  a new head sha on the same PR: 1 dispatch, hold (the count is per head)
#   K5  row lane.merge-conductor.mc_prequeue_park_after_reds = 0: K1's store
#       dispatches, holds, no park line (the old behavior)
#   K6  a green on a main newer than both reds: no park line (the newest
#       verdict is not red)
#   K7  row = 3 and only 2 reds: 1 dispatch, hold
#   K8  two reds with no .why sidecar: 1 dispatch, hold
#   K9  K1 a second tick: red again, still 0 dispatches
#
# MUTATIONS (each turns a case red):
#   - drop the park block in pq_resolve: K1, K9 fail (1 dispatch, hold)
#   - count reds whatever their why: K2 fails (red, no dispatch)
#   - ignore the knob (always 2): K5 and K7 fail
#   - count every red, not only those of the newest verdict's why, or skip the
#     "newest verdict is red" check: K6 fails
#   - accept an empty why: K8 fails
#   - pick the oldest red for PQ_MAIN: K1 fails (PQ_MAIN = A)
#
# Every case runs the REAL pq_gate (bin/lib/mc-prequeue.sh) with every real
# hook in bin/lib/mc-prequeue.d/ and the real lane_knob over a settings cache.
# GitHub (gh / gh_rest / vs_publish) is a stub: no network. The model is
# tests/prequeue-carry.bh-8769-test.sh.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-prequeue-park.bh-10022-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/mc-prequeue.d/dispatch.sh" ] && [ -f "$DIR/bin/lib/mc-prequeue.sh" ] || exit 1   # impact: bin/lib/mc-prequeue.d/dispatch.sh bin/lib/mc-prequeue.sh

# The clock is read once from the real clock: pq_prune's `find -mtime +7`
# reads the real clock (BH-8938).
NOW=$(date +%s)
KKEY=lane.merge-conductor.mc_prequeue_park_after_reds
SLUG=example-org/demo-os
MA=$(printf 'a%.0s' $(seq 40))
MB=$(printf 'b%.0s' $(seq 40))
MC=$(printf 'c%.0s' $(seq 40))
MD=$(printf 'd%.0s' $(seq 40))
SUITE=tests/lanes-registry.bh-2205-test.sh
WHY=invariant:lanes-registry

REG=$( . "$DIR/bin/lib/lanes-registry.sh" && lanes_json_path "$DIR" ) || REG=""
[ -r "$REG" ] || { echo "FAIL: setup: catalog/lanes.json could not be rendered"; exit 1; }

# cache <case> <values-json> — the box settings cache lane_knob reads.
cache() {
  mkdir -p "$T/$1/state"
  jq -nc --argjson fa "$NOW" --argjson v "$2" '{fetched_at:$fa, values:$v, seeded:{}}' > "$T/$1/state/settings-cache.json"
}
# entry <case> <num> <head> <main> <line> <age_s> [why] — a store entry as
#   pq_cache_put writes it, read <age_s> seconds before NOW, with its .why
#   sidecar as pq_read_run writes it when [why] is given.
entry() {
  local f; f="$T/$1/state/prequeue/${SLUG//\//_}_$2_$3_$4"
  mkdir -p "${f%/*}"; printf '%s\n' "$5" > "$f"; touch -d "@$((NOW - $6))" "$f"
  [ -n "${7:-}" ] && printf '%s\n' "$7" > "$f.why"
  printf '%s\n' "$f"
}
# red <case> <num> <head> <main> <dispatched_ago_s> [why] — a settled red,
#   older than MC_PREQUEUE_FRESH_S so no fresh rule reuses it.
red() { entry "$1" "$2" "$3" "$4" "red $((NOW - $5)) 9$2 $SUITE" $(($5 - 600)) "${6:-}" >/dev/null; }

# gate <case> <num> <head> — one READY head through the real pq_gate on main
#   $CUR (default C). Sinks: $C/gh, $C/log, $C/out.
gate() {
  local c="$1" n="$2" hd="$3"
  local C="$T/$c"
  mkdir -p "$C/state" "$C/tick" "$C/tmp" "$C/logs" "$C/bin" "$C/locks"
  touch "$C/gh" "$C/log" "$C/attempts" "$C/out" "$C/status"
  [ -r "$C/state/settings-cache.json" ] || cache "$c" '{}'
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/logs/ALERTS.log"\n' "$C" > "$C/bin/lane-alert.sh"; chmod +x "$C/bin/lane-alert.sh"
  ( export HARNESS="$C" LANE_REGISTRY="$REG" LANE_GATE_NOW="$NOW" JOBS_URL='' HARNESS_JOBS_URL='' TMPDIR="$C/tmp"
    export HARNESS_TEST_SANDBOX=1
    P=""; MC_H="$C"; MC_STATE_DIR="$C/state"; MC_TICK_ID="t10022-$c-$(wc -l < "$C/out")"; MC_TICK_DIR="$C/tick"; MC_LOG="$C/mclog"
    HARNESS_REPO="$SLUG"; PROVIDER=mergify; MC_MAIN_RED_LABEL=fix-main-red
    . "$DIR/bin/lib/lane-gate.sh" || exit 1
    . "$DIR/bin/lib/fanin.sh"; . "$DIR/bin/lib/mc/queue.sh"
    . "$DIR/bin/lib/mc-prequeue.sh" || exit 1
    date() { if [ "${1:-}" = +%s ]; then echo "$NOW"; else command date "$@"; fi; }
    mc_safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
    mc_log() { printf '%s\n' "$*" >> "$C/log"; }
    mc_attempt_has() { grep -qxF -- "$1" "$C/attempts"; }
    mc_attempt_put() { printf '%s\n' "$1" >> "$C/attempts"; }
    mc_use_token() { :; }
    vs_publish() { printf '%s %s %s %s\n' "$LEAD_VERDICT_CONTEXT" "${2:0:12}" "$3" "$4" >> "$C/status"; }
    mc_pr_files() { printf 'bin/lib/a.sh\n'; }
    pq_merge_test() { return 0; }
    pq_restamp_wanted() { return 1; }; pq_mignum_wanted() { return 1; }; pq_fastlint_wanted() { return 1; }
    pq_adopt_run() { return 1; }; pq_dispatch_veto() { return 1; }; pq_impact_reuse() { _pq_ir=none; }
    gh() { printf '%s\n' "$*" >> "$C/gh"; return 0; }
    gh_rest() {
      case "$2" in
        */compare/*) printf '{"status":"ahead","ahead_by":50,"files":[]}' ;;
        */commits/*) printf '{"sha":"%s"}' "${CUR:-$MC}" ;;
        */actions/workflows/prequeue-gate.yml) printf '{}' ;;
        */runs\?*) printf '{"workflow_runs":[]}' ;;
        *) return 44 ;;
      esac
    }
    pq_gate "$SLUG" "$n" "https://github.com/$SLUG/pull/$n" "$hd" main > "$C/word"
    printf '%s word=%s main=%s path=%s suites=%s why=%s\n' "$n" "$(cat "$C/word")" "$PQ_MAIN" "$PQ_PATH" "$PQ_SUITES" "$PQ_WHY" >> "$C/out"
  ) >> "$C/err" 2>&1
}
dispatches() { grep -c '^workflow run ' "$T/$1/gh" 2>/dev/null; }
word() { grep "^$2 " "$T/$1/out" | tail -n1 | sed 's/^[0-9]* word=\([a-z]*\).*/\1/'; }
field() { grep "^$2 " "$T/$1/out" | tail -n1 | tr ' ' '\n' | sed -n "s/^$3=//p"; }
parks() { grep -c 'PREQUEUE park ' "$T/$1/log" 2>/dev/null; }
dump() { cat "$T/$1/out" "$T/$1/log" "$T/$1/err" 2>/dev/null | head -20; }
head_of() { local h; h=$(printf '%s0%s' "$1" "$(printf 'e%.0s' $(seq 40))"); printf '%s' "${h:0:40}"; }

# ── K1: two reds on the same invariant on two mains park the head ────────────
H=$(head_of 301)
red k1 301 "$H" "$MA" 9000 "$WHY"; red k1 301 "$H" "$MB" 5000 "$WHY"
gate k1 301 "$H"
[ "$(word k1 301)" = red ] && [ "$(dispatches k1)" = 0 ] && ok || bad "K1 parked: red, 0 dispatches (got $(dispatches k1); $(dump k1))"
[ "$(field k1 301 main)" = "$MB" ] && ok || bad "K1 PQ_MAIN is the newest red's main B ($(field k1 301 main))"
[ "$(field k1 301 suites)" = "$SUITE" ] && ok || bad "K1 PQ_SUITES names the suite ($(field k1 301 suites))"
P1=$(field k1 301 path)
[ "${P1##*_}" = "$MB" ] && [ "$(head -n1 "$P1.why" 2>/dev/null)" = "$WHY" ] && ok || bad "K1 PQ_PATH is B's entry and its .why names the invariant ($P1)"
[ "$(parks k1)" = 1 ] && ok || bad "K1 one PREQUEUE park line ($(dump k1))"
grep 'PREQUEUE park ' "$T/k1/log" | grep -q "why=$WHY" && grep 'PREQUEUE park ' "$T/k1/log" | grep -q "reds=2" \
  && grep 'PREQUEUE park ' "$T/k1/log" | grep -q "${MA:0:12}" && grep 'PREQUEUE park ' "$T/k1/log" | grep -q "${MB:0:12}" \
  && grep 'PREQUEUE park ' "$T/k1/log" | grep -q "current-main=${MC:0:12}" && ok || bad "K1 the park line names the invariant, the count and the mains ($(grep 'PREQUEUE park' "$T/k1/log"))"
[ ! -e "$T/k1/state/prequeue/${SLUG//\//_}_301_${H}_$MC" ] && ok || bad "K1 no pending entry for main C"

# ── K9: a second tick on the same main: still parked, still 0 dispatches ─────
gate k1 301 "$H"
[ "$(word k1 301)" = red ] && [ "$(dispatches k1)" = 0 ] && ok || bad "K9 a second tick stays parked ($(dump k1))"

# ── K2: different invariants do not park ─────────────────────────────────────
H=$(head_of 302)
red k2 302 "$H" "$MA" 9000 "$WHY"; red k2 302 "$H" "$MB" 5000 invariant:other
gate k2 302 "$H"
[ "$(word k2 302)" = hold ] && [ "$(dispatches k2)" = 1 ] && [ "$(parks k2)" = 0 ] && ok || bad "K2 different whys: 1 dispatch, hold, no park (got $(dispatches k2); $(dump k2))"

# ── K3: the same head on the same main: the cache read, unchanged ────────────
H=$(head_of 303)
red k3 303 "$H" "$MC" 5000 "$WHY"
gate k3 303 "$H"
[ "$(word k3 303)" = red ] && [ "$(dispatches k3)" = 0 ] && [ "$(parks k3)" = 0 ] && [ "$(field k3 303 main)" = "$MC" ] \
  && ok || bad "K3 a red on the current main: red from the cache, no park line ($(dump k3))"

# ── K4: a new head sha wakes the PR ──────────────────────────────────────────
H=$(head_of 301); H2=$(head_of 401)
red k4 301 "$H" "$MA" 9000 "$WHY"; red k4 301 "$H" "$MB" 5000 "$WHY"
gate k4 301 "$H2"
[ "$(word k4 301)" = hold ] && [ "$(dispatches k4)" = 1 ] && [ "$(parks k4)" = 0 ] && ok || bad "K4 a new head: 1 dispatch, hold (got $(dispatches k4); $(dump k4))"

# ── K5: knob 0 = off ─────────────────────────────────────────────────────────
H=$(head_of 305); cache k5 "{\"$KKEY\":\"0\"}"
red k5 305 "$H" "$MA" 9000 "$WHY"; red k5 305 "$H" "$MB" 5000 "$WHY"
gate k5 305 "$H"
[ "$(word k5 305)" = hold ] && [ "$(dispatches k5)" = 1 ] && [ "$(parks k5)" = 0 ] && ok || bad "K5 knob 0: 1 dispatch, hold (got $(dispatches k5); $(dump k5))"

# ── K6: a green newer than the reds: not parked ──────────────────────────────
H=$(head_of 306)
red k6 306 "$H" "$MA" 9000 "$WHY"; red k6 306 "$H" "$MB" 7000 "$WHY"
entry k6 306 "$H" "$MD" "green $((NOW - 4000)) 77 $SUITE" 3400 >/dev/null
gate k6 306 "$H"
[ "$(parks k6)" = 0 ] && [ "$(word k6 306)" != red ] && ok || bad "K6 a newer green: no park ($(dump k6))"

# ── K7: knob 3, only 2 reds: not parked ──────────────────────────────────────
H=$(head_of 307); cache k7 "{\"$KKEY\":\"3\"}"
red k7 307 "$H" "$MA" 9000 "$WHY"; red k7 307 "$H" "$MB" 5000 "$WHY"
gate k7 307 "$H"
[ "$(word k7 307)" = hold ] && [ "$(dispatches k7)" = 1 ] && [ "$(parks k7)" = 0 ] && ok || bad "K7 knob 3, 2 reds: 1 dispatch, hold ($(dump k7))"

# ── K8: reds with no why: not parked ─────────────────────────────────────────
H=$(head_of 308)
red k8 308 "$H" "$MA" 9000; red k8 308 "$H" "$MB" 5000
gate k8 308 "$H"
[ "$(word k8 308)" = hold ] && [ "$(dispatches k8)" = 1 ] && [ "$(parks k8)" = 0 ] && ok || bad "K8 reds with no why: 1 dispatch, hold ($(dump k8))"

echo "mc-prequeue-park.bh-10022: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
