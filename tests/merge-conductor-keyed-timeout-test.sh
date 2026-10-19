#!/bin/bash
# tests/merge-conductor-keyed-timeout-test.sh — BH-7376 items 1 and 4: a keyed
# conductor run for one READY PR has the time to finish the whole READY arm
# (dep-gate, ticket-hold, prequeue, state-guard, enqueue).
#
# THE INCIDENT (hub, 2026-10-17/18). The backstop ran each keyed run under
# `timeout MC_BACKSTOP_TIMEOUT_S` (settings row 290 s) with its PR worker
# capped at 245 s, and the `prequeue` step alone took up to 265 s: cromford
# #7361 was killed in `prequeue` on every fire and sat in READY for 316 min. An
# operator run with `timeout 900` and a worker cap of 840 s reached `enqueue`
# (90 s) and merged.
#
# THE RULE. The keyed READY-arm budget is MC_KEYED_READY_ARM_S (lane
# merge-conductor, default 490 s: measured prequeue p95 ~290 s, the enqueue
# step floor 130 s, 70 s for the other steps). It is OPT-IN per launcher
# (MC_KEYED_READY_FLOOR=1: the backstop, the keyed pool and kw_conductor's
# direct launch), and it applies only to a row that is READY in pr-state.tsv.
# Such a row's PR worker gets at least that budget (MC_WORKER_DEADLINE_MIN_S),
# and its prequeue step's timeout is never under it. The backstop's timeout is
# never under that budget + 45 s, whatever its own row says, and the backstop
# starts at most MC_BACKSTOP_MAX_RUNNING runs at once, READY rows first.
#
# The REAL bin/merge-conductor-backstop.sh is driven with `timeout`, `setsid`
# and `flock` stubbed. The stub conductor walks a READY arm whose steps take
# virtual seconds (dep-gate 5, ticket-hold 2, prequeue 265, state-guard 5,
# enqueue 90). It dies at the first step past its step timeout (the REAL
# mc_step_timeout_s, bin/lib/fanin.sh) or past min(timeout, worker deadline)
# (the REAL mc_worker_deadline_s and mc_keyed_deadline_floor).
#   K1  settings row 290 s, step timeout 240 s: the keyed READY run reaches
#       enqueue (no timeout, deadline or step-timeout kill)
#   K2  the timeout the backstop passes is >= MC_KEYED_READY_ARM_S + 45
#   K3  a row above the floor wins (900 -> 900)
#   K4  MC_KEYED_READY_ARM_S moves the floor (600 -> timeout 645)
#   K5  the floor is named once in the backstop log when it raised the row
#   K6  the keyed pool's run (opt-in, no cap) of a READY row gets >= 490
#   K7  a full tick (no MC_ONLY_PR) keeps MC_WORKER_DEADLINE_S (180)
#   K8  a keyed run that did not opt in keeps 180 (pr-owner-sweep, the
#       archie queue kick: both run under `timeout 240` with no cap)
#   K9  every `MC_ONLY_PR=... timeout` launch site in bin/ passes a cap or
#       does not opt in to the floor; the opt-in launchers are the backstop
#       (with its cap), the keyed pool and kw_conductor
#   K10 a WAIT_CI row of an opted-in run keeps 180 (the floor is READY-only)
#   K11 step timeouts: prequeue of a floored row >= the floor, every other
#       step keeps MC_STEP_TIMEOUT_S, enqueue keeps its own floor
#   K12 mc_worker_bounded arms the same deadline mc_worker_deadline_s prints
#       (one rule), over a matrix of deadline, floor, cap and row state
#   K13 MC_BACKSTOP_MAX_RUNNING=2 and 5 candidates: 2 runs start, READY first,
#       and the rest are named for the next fire
#   K14 MC_KEYED_READY_ARM_S's registry min is 1 (the suites that pin it to
#       1 are inside its bounds)
#   K15 the READY re-kick waits for the PR lock no longer than
#       MC_WORKER_DEADLINE_S (not the floored deadline)
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-keyed-timeout-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

R="$T/r"; mkdir -p "$R/bin/lib" "$R/logs" "$R/locks" "$R/state/merge-conductor" "$R/flags" "$R/env" "$T/rbin" "$T/rec"
( cd "$DIR" && scratch_install_closure bin/merge-conductor-backstop.sh "$R" ) >/dev/null || { echo "FAIL: cannot install the backstop"; exit 1; }
: > "$R/env/global.env"
# Stubs: `timeout` hands its seconds to the run as MC_FAKE_TO, `setsid` just
# runs, `flock` always gets the lock (no earlier run holds a key).
printf '#!/bin/bash\nto="$1"; shift\nMC_FAKE_TO="$to" exec "$@"\n' > "$T/rbin/timeout"
printf '#!/bin/bash\nexec "$@"\n' > "$T/rbin/setsid"
printf '#!/bin/bash\nexit 0\n' > "$T/rbin/flock"
printf '#!/bin/bash\nexit 1\n' > "$T/rbin/gh"
chmod +x "$T/rbin/"*
ROWSF="$R/state/merge-conductor/pr-state.tsv"
# The stub conductor: a READY arm in virtual seconds, one record per key.
cat > "$R/bin/merge-conductor.sh" <<EOF
#!/usr/bin/env bash
mc_log() { :; }
. "$DIR/bin/lib/fanin.sh"
. "$DIR/bin/lib/mc/tick-scope.sh"
mc_keyed_tick_parse
declare -F mc_keyed_deadline_floor >/dev/null && mc_keyed_deadline_floor
SLUG="\${MC_ONLY_PR%#*}"; NUM="\${MC_ONLY_PR##*#}"; MC_ROWS="$ROWSF"
d=\$(mc_worker_deadline_s "\$NUM" 2>/dev/null); [ -n "\$d" ] || d=\${MC_WORKER_DEADLINE_S:-180}
st=\${MC_STEP_TIMEOUT_S:-240}
lim=\${MC_FAKE_TO:-0}; { [ "\$lim" = 0 ] || [ "\$d" -lt "\$lim" ]; } && lim=\$d
t=0; reached=start; killed=none
for s in dep-gate:5 ticket-hold:2 prequeue:265 state-guard:5 enqueue:90; do
  n="\${s%%:*}"; dur="\${s#*:}"
  if declare -F mc_step_timeout_s >/dev/null; then eff=\$(mc_step_timeout_s "\$n" "\$NUM"); else eff=\$st; fi
  if [ "\$eff" -gt 0 ] && [ "\$eff" -lt "\$d" ] && [ "\$dur" -gt "\$eff" ]; then killed="\$n:step-timeout"; break; fi
  t=\$((t + dur)); if [ "\$t" -gt "\$lim" ]; then killed="\$n"; break; fi; reached="\$n"
done
printf 'to=%s cap=%s deadline=%s reached=%s killed=%s\n' "\${MC_FAKE_TO:-}" "\${MC_WORKER_DEADLINE_CAP_S:-}" "\$d" "\$reached" "\$killed" > "$T/rec/run.\$NUM"
EOF
chmod +x "$R/bin/merge-conductor.sh"
H1=$(printf 'a%.0s' $(seq 40)); NOW=$(date +%s)
row() { printf 'example-org/demo#%s\t%s\t%s\t%s\t%s\t-\t-\thttps://github.com/example-org/demo/pull/%s\n' "$1" "$2" "$((NOW - ${3:-60}))" "$H1" "$H1" "$1"; }
row 7361 READY > "$ROWSF"
fire() { # fire <records to wait for> [VAR=val...] — one backstop fire
  local want="$1" n=0; shift
  rm -f "$T/rec"/run.*
  ( cd "$T" && env PATH="$T/rbin:$PATH" HARNESS="$R" MC_WORKER_DEADLINE_S=180 MC_STEP_TIMEOUT_S=240 "$@" bash "$R/bin/merge-conductor-backstop.sh" > "$T/bs.out" 2>&1 )
  while [ "$(ls "$T/rec" | grep -c '^run\.')" -lt "$want" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done   # determinism: ok waits for the detached runs' records
  sleep 0.3   # determinism: ok lets a run past the cap write a record if one (wrongly) started
}
field() { sed -n "s/.*$2=\([^ ]*\).*/\1/p; s/^$2=\([^ ]*\).*/\1/p" "$T/rec/run.$1" 2>/dev/null | head -1; }
# lib <shell text> — the real fanin.sh + tick-scope.sh in a clean bash, rows in ROWSF.
lib() { MC_ROWS="$ROWSF" SLUG=example-org/demo bash -c "mc_log() { :; }; . '$DIR/bin/lib/fanin.sh'; . '$DIR/bin/lib/mc/tick-scope.sh'; $1" 2>&1; }

# --- K1/K2/K5. the hub's row: 290 s --------------------------------------------
fire 1 MC_BACKSTOP_TIMEOUT_S=290
[ "$(field 7361 reached)" = enqueue ] && [ "$(field 7361 killed)" = none ] && ok \
  || bad "K1 a keyed READY run with a 265 s prequeue must reach enqueue under the row of 290 s and a 240 s step timeout ($(cat "$T/rec/run.7361" 2>/dev/null || echo 'no run'); $(cat "$T/bs.out"))"
TO=$(field 7361 to)
[ -n "$TO" ] && [ "$TO" -ge 535 ] && ok || bad "K2 the keyed timeout must be >= MC_KEYED_READY_ARM_S (490) + 45 (got ${TO:-none})"
grep -q 'MC_KEYED_READY_ARM_S' "$T/bs.out" && ok || bad "K5 the backstop names the floor that raised the row ($(cat "$T/bs.out"))"

# --- K3. a row above the floor wins ------------------------------------------------
fire 1 MC_BACKSTOP_TIMEOUT_S=900
[ "$(field 7361 to)" = 900 ] && [ "$(field 7361 cap)" = 855 ] && ok || bad "K3 a row of 900 s stays 900 with cap 855 ($(cat "$T/rec/run.7361" 2>/dev/null))"

# --- K4. the arm budget moves the floor ---------------------------------------------
fire 1 MC_BACKSTOP_TIMEOUT_S=290 MC_KEYED_READY_ARM_S=600
[ "$(field 7361 to)" = 645 ] && ok || bad "K4 MC_KEYED_READY_ARM_S=600 gives a timeout of 645 ($(cat "$T/rec/run.7361" 2>/dev/null))"

# --- K6/K7/K8/K10. who gets the floor ------------------------------------------------
row 7361 READY > "$ROWSF"; row 7362 WAIT_CI >> "$ROWSF"
OUT=$(MC_ONLY_PR="example-org/demo#7361" MC_KEYED_READY_FLOOR=1 MC_WORKER_DEADLINE_S=180 lib 'mc_keyed_tick_parse; mc_keyed_deadline_floor; mc_worker_deadline_s 7361')
[ -n "$OUT" ] && [ "$OUT" -ge 490 ] 2>/dev/null && ok || bad "K6 an opted-in keyed run of a READY row with no cap gets >= 490 (got: $OUT)"
OUT=$(MC_ONLY_PR="" MC_KEYED_READY_FLOOR=1 MC_WORKER_DEADLINE_S=180 lib 'mc_keyed_tick_parse; mc_keyed_deadline_floor; mc_worker_deadline_s 7361')
[ "$OUT" = 180 ] && ok || bad "K7 a full tick keeps MC_WORKER_DEADLINE_S=180 (got: $OUT)"
OUT=$(MC_ONLY_PR="example-org/demo#7361" MC_WORKER_DEADLINE_S=180 lib 'mc_keyed_tick_parse; mc_keyed_deadline_floor; mc_worker_deadline_s 7361')
[ "$OUT" = 180 ] && ok || bad "K8 a keyed run that did not opt in keeps 180 (got: $OUT)"
OUT=$(MC_ONLY_PR="example-org/demo#7362" MC_KEYED_READY_FLOOR=1 MC_WORKER_DEADLINE_S=180 lib 'mc_keyed_tick_parse; mc_keyed_deadline_floor; mc_worker_deadline_s 7362')
[ "$OUT" = 180 ] && ok || bad "K10 a WAIT_CI row keeps 180 even when the run opted in (got: $OUT)"

# --- K9. every MC_ONLY_PR + timeout launch site is safe -----------------------------
# One logical command per site: a line ending in `\` is joined to the next.
SITES=$(cd "$DIR" && for f in $(grep -rlE 'MC_ONLY_PR=' bin --include='*.sh'); do
  awk -v f="$f" '{ l = (c ? c " " : "") $0 } /\\$/ { sub(/\\$/, "", l); c = l; next } { c = ""; if (l ~ /MC_ONLY_PR=/ && l !~ /^[[:space:]]*#/) print f ": " l }' "$f"; done)
UNSAFE=$(grep -E '(^|[^A-Za-z_])timeout ' <<<"$SITES" | grep 'MC_KEYED_READY_FLOOR=1' | grep -v 'MC_WORKER_DEADLINE_CAP_S=' || true)
[ -z "$UNSAFE" ] && ok || bad "K9 a launch site runs under timeout, opts in to the floor and passes no cap: $UNSAFE"
OPTIN=$(grep 'MC_KEYED_READY_FLOOR=1' <<<"$SITES" | cut -d: -f1 | sort -u | tr '\n' ' ')
[ "$OPTIN" = "bin/lib/keyed-wake.sh bin/mc-keyed-pool.sh bin/merge-conductor-backstop.sh " ] && ok \
  || bad "K9 the opt-in launchers are the backstop, the keyed pool and kw_conductor (got: $OPTIN)"
TO240=$(grep -E 'bin/pr-owner-sweep.sh|bin/lib/archie-fm-queue/reconcile.sh' <<<"$SITES" || true)
case "$TO240" in
  *MC_KEYED_READY_FLOOR*) bad "K9 pr-owner-sweep and the archie queue kick run under timeout 240 with no cap: they must not opt in" ;;
  *) ok ;;
esac
grep -q 'mc_keyed_deadline_floor' "$DIR/bin/merge-conductor.sh" && ! grep -q 'MC_KEYED_READY_FLOOR' "$DIR/bin/lib/mc/tick-scope.sh" \
  && bad "K9 the conductor's floor must be opt-in (MC_KEYED_READY_FLOOR) in mc_keyed_deadline_floor" || ok

# --- K11. step timeouts ---------------------------------------------------------------
OUT=$(MC_ONLY_PR="example-org/demo#7361" MC_KEYED_READY_FLOOR=1 MC_STEP_TIMEOUT_S=240 lib 'mc_keyed_tick_parse; mc_keyed_deadline_floor
  printf "%s %s %s %s\n" "$(mc_step_timeout_s prequeue 7361)" "$(mc_step_timeout_s dep-gate 7361)" "$(mc_step_timeout_s enqueue 7361)" "$(mc_step_timeout_s prequeue 7362)"')
read -r PQ DG EQ PW <<<"$OUT"
[ "${PQ:-0}" -ge 490 ] 2>/dev/null && ok || bad "K11 a floored READY row's prequeue step timeout is >= 490 (got: $OUT)"
[ "${DG:-}" = 240 ] && ok || bad "K11 dep-gate keeps MC_STEP_TIMEOUT_S 240 (got: $OUT)"
[ "${EQ:-}" = 240 ] && ok || bad "K11 enqueue keeps max(240, its own floor 130) (got: $OUT)"
[ "${PW:-}" = 240 ] && ok || bad "K11 a WAIT_CI row's prequeue keeps 240 (got: $OUT)"

# --- K12. one rule: mc_worker_bounded arms what mc_worker_deadline_s prints ---------
K12=""
for c in "180 - - 7361" "180 490 - 7361" "180 490 - 7362" "180 490 300 7361" "0 490 - 7361" "0 - 75 7361" "600 490 - 7361" "abc 490 855 7361"; do
  read -r D M C N <<<"$c"
  ENVS=(MC_WORKER_DEADLINE_S="$D"); [ "$M" != - ] && ENVS+=(MC_WORKER_DEADLINE_MIN_S="$M"); [ "$C" != - ] && ENVS+=(MC_WORKER_DEADLINE_CAP_S="$C")
  WANT=$(env "${ENVS[@]}" bash -c "mc_log() { :; }; . '$DIR/bin/lib/fanin.sh'; MC_ROWS='$ROWSF' SLUG=example-org/demo mc_worker_deadline_s $N")
  GOT=$(env "${ENVS[@]}" T="$T" bash -c "
    mc_log() { :; }; . '$DIR/bin/lib/fanin.sh'; MC_ROWS='$ROWSF'; SLUG=example-org/demo
    _mc_deadline_mark() { printf '%s/mark/k12' \"\$T\"; }
    mc_step_read() { :; }; mc_step_close() { :; }
    pr_worker() { if [ -n \"\${MC_WORKER_DEADLINE_AT:-}\" ]; then echo \$((MC_WORKER_DEADLINE_AT - \$(date +%s))); else echo 0; fi; }
    mc_worker_bounded '$N	row'" 2>/dev/null | head -1)
  # The armed deadline is read a moment after it is set: allow 1 s.
  [ -n "$GOT" ] && [ $((WANT - GOT)) -ge 0 ] && [ $((WANT - GOT)) -le 1 ] || K12="$K12 [$c: rule=$WANT armed=$GOT]"
done
[ -z "$K12" ] && ok || bad "K12 mc_worker_bounded and mc_worker_deadline_s disagree:$K12"

# --- K13. the backstop's count cap ---------------------------------------------------
: > "$ROWSF"; row 101 WAIT_CI 500 >> "$ROWSF"; row 102 WAIT_CI 400 >> "$ROWSF"; row 103 READY 300 >> "$ROWSF"
row 104 WAIT_CI 200 >> "$ROWSF"; row 105 READY 100 >> "$ROWSF"
fire 2 MC_BACKSTOP_MAX_RUNNING=2
STARTED=$(ls "$T/rec" | sed -n 's/^run\.//p' | sort | tr '\n' ' ')
[ "$STARTED" = "103 105 " ] && ok || bad "K13 a cap of 2 starts the 2 READY rows first (started: $STARTED; $(cat "$T/bs.out"))"
grep -q 'MC_BACKSTOP_MAX_RUNNING' "$T/bs.out" && grep -q '3 left for the next fire' "$T/bs.out" && ok \
  || bad "K13 the fire names the cap and the 3 keys left for the next fire ($(cat "$T/bs.out"))"
K="$DIR/catalog/lanes.d/merge-conductor-backstop.knobs.d/MC_BACKSTOP_MAX_RUNNING.json"
[ "$(jq -r '.default' "$K")" -gt 0 ] 2>/dev/null && ok \
  || bad "K13 MC_BACKSTOP_MAX_RUNNING is a registered knob with a positive default ($K)"

# --- K14. registry bounds ------------------------------------------------------------
[ "$(jq -r .min "$DIR/catalog/lanes.d/merge-conductor.knobs.d/MC_KEYED_READY_ARM_S.json")" = 1 ] && ok \
  || bad "K14 MC_KEYED_READY_ARM_S's registry min is 1"

# --- K15. the re-kick's PR-lock wait -------------------------------------------------
BODY=$(awk '/^mc_ready_rekick\(\)/ { f = 1 } f { print } f && /^}/ { exit }' "$DIR/bin/lib/mc/classify.sh")
grep -q 'mc_worker_deadline_s' <<<"$BODY" && bad "K15 the re-kick's lock wait must not use the floored deadline (it doubles a slot to 980 s)" || ok

echo "merge-conductor-keyed-timeout: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
