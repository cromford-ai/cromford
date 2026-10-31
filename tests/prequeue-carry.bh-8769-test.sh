#!/bin/bash
# tests/prequeue-carry.bh-8769-test.sh — BH-8769 items 3 and 4: a green verdict
# carried to a new main (the BH-6924 impact reuse) names both mains in its
# prequeue-verdict status, and the knob lane.merge-conductor.mc_prequeue_carry
# (default 1) turns the carry off.
#
# Every case runs the REAL pq_gate (bin/lib/mc-prequeue.sh) with every real
# hook in bin/lib/mc-prequeue.d/ (dispatch.sh, impact-reuse.sh, status.sh), the
# real lane_knob over a settings cache, and the real bin/test-impact.sh select
# on a pinned map. GitHub (gh / gh_rest / vs_publish) is a stub: no network.
# The clock is pinned (a `date +%s` seam and touch -d on the store files).
#
#   C1  an entry on main B with a `.reuse` sidecar main=A: the status is
#       `green on main <A12>, carried to main <B12>`
#   C2  C1 after a `success` POST for this head on main A: one more POST
#   C3  no sidecar: `green on main <B12>` (the text before BH-8769)
#   C3b a sidecar with a malformed main: the text before BH-8769
#   C4  row mc_prequeue_carry=0, green on A, a disjoint main move: 0 compare
#       reads, no sidecar, 1 dispatch, hold
#   C5  no row (fallback 1), the same move: proceed, the sidecar names A,
#       the POST names both mains (writer and reader round-trip)
#   C5b no row, main B touches the PR's own file: 1 dispatch, hold
#   C6  a second tick on main B reads the carried entry: 0 more POSTs
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-carry.bh-8769-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/mc-prequeue.d/impact-reuse.sh" ] && [ -f "$DIR/bin/lib/mc-prequeue.d/status.sh" ] || exit 1   # impact: bin/lib/mc-prequeue.d/impact-reuse.sh bin/lib/mc-prequeue.d/status.sh

NOW=1792900800   # 2026-10-25T00:00:00Z, the settings cache's fetched_at and the gate's clock
CKEY=lane.merge-conductor.mc_prequeue_carry
SLUG=example-org/demo-os
MA=$(printf 'a%.0s' $(seq 40))
MB=$(printf 'b%.0s' $(seq 40))
SUITE=tests/a.sh

REG=$( . "$DIR/bin/lib/lanes-registry.sh" && lanes_json_path "$DIR" ) || REG=""
[ -r "$REG" ] || { echo "FAIL: setup: catalog/lanes.json could not be rendered"; exit 1; }

# The impact root: the real bin/test-impact.sh beside a tests/ dir, and its
# pinned map. tests/a.sh reaches bin/lib/a.sh, tests/b.sh reaches bin/lib/b.sh.
TI="$T/ti"; mkdir -p "$TI/tests"
scratch_install_closure bin/test-impact.sh "$TI" >/dev/null || exit 1
chmod +x "$TI/bin/test-impact.sh"
for s in always a b; do printf '#!/bin/bash\nexit 0\n' > "$TI/tests/$s.sh"; done
git -C "$TI" init -q 2>/dev/null; git -C "$TI" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false add -A >/dev/null 2>&1
git -C "$TI" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false commit -qm ti >/dev/null 2>&1
printf 'tests/always.sh\t*\ntests/a.sh\tbin/lib/a.sh\ntests/b.sh\tbin/lib/b.sh\n' > "$T/map"

# cache <case> <values-json> — the box settings cache lane_knob reads.
cache() {
  mkdir -p "$T/$1/state"
  jq -nc --argjson fa "$NOW" --argjson v "$2" '{fetched_at:$fa, values:$v, seeded:{}}' > "$T/$1/state/settings-cache.json"
}
# entry <case> <num> <head> <main> <line> <age_s> — a store entry as
#   pq_cache_put writes it, read <age_s> seconds before NOW.
entry() {
  local f; f="$T/$1/state/prequeue/${SLUG//\//_}_$2_$3_$4"
  mkdir -p "${f%/*}"; printf '%s\n' "$5" > "$f"; touch -d "@$((NOW - $6))" "$f"
  printf '%s\n' "$f"
}

# gate <case> <num> <head> — one READY head through the real pq_gate on main
#   B. Env: MAIN_FILES (the compare's files for A...B). A case dir that exists
#   keeps its store, attempt ledger and log (a later tick).
#   Sinks: $C/gh, $C/compare, $C/status, $C/log, $C/out, $C/attempts.
gate() {
  local c="$1" n="$2" hd="$3"
  local C="$T/$c"
  mkdir -p "$C/state" "$C/tick" "$C/tmp" "$C/logs" "$C/bin" "$C/locks"
  touch "$C/gh" "$C/compare" "$C/status" "$C/log" "$C/attempts" "$C/out"
  [ -r "$C/state/settings-cache.json" ] || cache "$c" '{}'
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/logs/ALERTS.log"\n' "$C" > "$C/bin/lane-alert.sh"; chmod +x "$C/bin/lane-alert.sh"
  ( export HARNESS="$C" LANE_REGISTRY="$REG" LANE_GATE_NOW="$NOW" JOBS_URL='' HARNESS_JOBS_URL='' TMPDIR="$C/tmp"
    export HARNESS_TEST_SANDBOX=1 MC_PREQUEUE_IMPACT_MAP="$T/map"
    P=""; MC_H="$C"; MC_STATE_DIR="$C/state"; MC_TICK_ID=t8769; MC_TICK_DIR="$C/tick"; MC_LOG="$C/mclog"
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
    _fr_ti_root() { printf '%s\n' "$TI"; }
    mc_pr_files() { printf 'bin/lib/a.sh\n'; }
    pq_merge_test() { return 0; }
    pq_restamp_wanted() { return 1; }; pq_mignum_wanted() { return 1; }
    pq_adopt_run() { return 1; }; pq_dispatch_veto() { return 1; }
    gh() { printf '%s\n' "$*" >> "$C/gh"; return 0; }
    gh_rest() {
      case "$2" in
        */compare/*) printf '%s\n' "${2##*/compare/}" >> "$C/compare"
          printf '%s\n' ${MAIN_FILES:-docs/x.md} | jq -R -s -c '{status:"ahead",ahead_by:1,files:[split("\n")[]|select(length>0)|{filename:.}]}' ;;
        */commits/*) printf '{"sha":"%s"}' "$MB" ;;
        */actions/workflows/prequeue-gate.yml) printf '{}' ;;
        */runs\?*) printf '{"workflow_runs":[]}' ;;
        *) return 44 ;;
      esac
    }
    pq_gate "$SLUG" "$n" "https://github.com/$SLUG/pull/$n" "$hd" main > "$C/word"
    printf '%s word=%s why=%s\n' "$n" "$(cat "$C/word")" "$PQ_WHY" >> "$C/out"
  ) >> "$C/err" 2>&1
}
dispatches() { grep -c '^workflow run prequeue-gate.yml ' "$T/$1/gh" 2>/dev/null; }
posts() { wc -l < "$T/$1/status" | tr -d ' '; }
word() { grep "^$2 " "$T/$1/out" | tail -n1 | sed 's/^[0-9]* word=\([a-z]*\).*/\1/'; }
dump() { cat "$T/$1/out" "$T/$1/status" "$T/$1/err" 2>/dev/null | head -20; }
head_of() { local h; h=$(printf '%s0%s' "$1" "$(printf 'd%.0s' $(seq 40))"); printf '%s' "${h:0:40}"; }
CARRIED="green on main ${MA:0:12}, carried to main ${MB:0:12}"
SIDE="reused-from main=$MA run=77 commits=1 files=1 reason=impact-disjoint"

# ── C1: a carried entry names both mains ─────────────────────────────────────
H=$(head_of 201); F=$(entry c1 201 "$H" "$MB" "green $((NOW - 2400)) 77 $SUITE" 60)
printf '%s\n' "$SIDE" > "$F.reuse"
gate c1 201 "$H"
[ "$(word c1 201)" = proceed ] && ok || bad "C1 the answer is proceed ($(dump c1))"
grep -qx "prequeue-verdict ${H:0:12} success $CARRIED" "$T/c1/status" && ok || bad "C1 the status names both mains ($(cat "$T/c1/status"))"
grep -qx "pqst $SLUG $H success carry $MB" "$T/c1/attempts" && ok || bad "C1 the attempt key carries the main ($(cat "$T/c1/attempts"))"

# ── C2: a head that got success on main A posts once more for main B ─────────
H=$(head_of 202); F=$(entry c2 202 "$H" "$MB" "green $((NOW - 2400)) 77 $SUITE" 60)
printf '%s\n' "$SIDE" > "$F.reuse"
mkdir -p "$T/c2"; printf 'pqst %s %s success\n' "$SLUG" "$H" > "$T/c2/attempts"
gate c2 202 "$H"
[ "$(posts c2)" = 1 ] && grep -qx "prequeue-verdict ${H:0:12} success $CARRIED" "$T/c2/status" && ok \
  || bad "C2 an earlier success on main A does not swallow the carried POST ($(cat "$T/c2/status"))"

# ── C3, C3b: no sidecar, or a malformed one: the text before BH-8769 ─────────
H=$(head_of 203); entry c3 203 "$H" "$MB" "green $((NOW - 2400)) 77 $SUITE" 60 >/dev/null
gate c3 203 "$H"
grep -qx "prequeue-verdict ${H:0:12} success green on main ${MB:0:12}" "$T/c3/status" && ok || bad "C3 no sidecar: 'green on main <B12>' ($(cat "$T/c3/status"))"
grep -qx "pqst $SLUG $H success" "$T/c3/attempts" && ok || bad "C3 the attempt key is the one before BH-8769 ($(cat "$T/c3/attempts"))"
H=$(head_of 213); F=$(entry c3b 213 "$H" "$MB" "green $((NOW - 2400)) 77 $SUITE" 60)
printf 'reused-from main=xyz run=77 commits=1 files=1 reason=impact-disjoint\n' > "$F.reuse"
gate c3b 213 "$H"
grep -qx "prequeue-verdict ${H:0:12} success green on main ${MB:0:12}" "$T/c3b/status" && ok || bad "C3b a malformed sidecar: the old text ($(cat "$T/c3b/status"))"

# ── C4: the knob row at 0 turns the carry off ────────────────────────────────
H=$(head_of 204); cache c4 "{\"$CKEY\":\"0\"}"
entry c4 204 "$H" "$MA" "green $((NOW - 2400)) 77 $SUITE" 2400 >/dev/null
gate c4 204 "$H"
[ ! -s "$T/c4/compare" ] && ok || bad "C4 row 0: no compare read ($(cat "$T/c4/compare"))"
[ ! -e "$T/c4/state/prequeue/${SLUG//\//_}_204_${H}_$MB.reuse" ] && ok || bad "C4 row 0: no .reuse sidecar"
[ "$(dispatches c4)" = 1 ] && [ "$(word c4 204)" = hold ] && ok || bad "C4 row 0: one dispatch, hold (got $(dispatches c4); $(dump c4))"

# ── C5: no row, the fallback 1: the carry runs and names both mains ──────────
H=$(head_of 205)
entry c5 205 "$H" "$MA" "green $((NOW - 2400)) 77 $SUITE" 2400 >/dev/null
gate c5 205 "$H"
[ "$(word c5 205)" = proceed ] && [ "$(dispatches c5)" = 0 ] && ok || bad "C5 no row: the carry proceeds with no dispatch ($(dump c5))"
grep -q "^reused-from main=$MA " "$T/c5/state/prequeue/${SLUG//\//_}_205_${H}_$MB.reuse" 2>/dev/null && ok || bad "C5 the .reuse sidecar names main A"
grep -qx "prequeue-verdict ${H:0:12} success $CARRIED" "$T/c5/status" && ok || bad "C5 the POST names both mains ($(cat "$T/c5/status"))"
[ "$(cat "$T/c5/compare")" = "$MA...$MB" ] && ok || bad "C5 one compare read A...B ($(cat "$T/c5/compare"))"

# ── C5b: main B touches the PR's own file: the re-gate, as today ─────────────
H=$(head_of 215)
entry c5b 215 "$H" "$MA" "green $((NOW - 2400)) 77 $SUITE" 2400 >/dev/null
MAIN_FILES=bin/lib/a.sh gate c5b 215 "$H"
[ "$(dispatches c5b)" = 1 ] && [ "$(word c5b 215)" = hold ] && ok || bad "C5b a main move on the PR's file dispatches (got $(dispatches c5b); $(dump c5b))"
! grep -q carried "$T/c5b/status" && ok || bad "C5b no carried text ($(cat "$T/c5b/status"))"

# ── C6: a later tick reads the carried entry: no second POST ─────────────────
H=$(head_of 205)
gate c5 205 "$H"
[ "$(word c5 205)" = proceed ] && ok || bad "C6 the second tick proceeds ($(dump c5))"
[ "$(posts c5)" = 1 ] && ok || bad "C6 the second tick on main B makes no second POST ($(cat "$T/c5/status"))"
[ "$(wc -l < "$T/c5/compare" | tr -d ' ')" = 1 ] && ok || bad "C6 the second tick reads no compare ($(cat "$T/c5/compare"))"

echo "prequeue-carry.bh-8769: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
