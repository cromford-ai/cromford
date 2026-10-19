#!/bin/bash
# tests/deploy-train-green-sha.bh-6746-test.sh — BH-6746 (wave 3 of #6541):
# with DEPLOY_MAIN_CI_GATE=1 the deploy train departs only on an origin/main
# HEAD whose `main-ci` commit status is success (bin/lib/deploy-main-ci.sh).
#
#   T0 gate unset + a red HEAD -> departs as today
#   T1 success -> MAIN_CI_GREEN, then `train departing`, then VERIFIED
#   T2 failure -> no departure, MAIN_CI_RED <sha8>, the queue file kept, no hook
#   T3a no status, seen 10 min ago, bound 45 -> MAIN_CI_WAIT, no departure
#   T3b seen 46 min ago -> MAIN_CI_UNKNOWN, no departure, ONE ALERTS line after 2 runs
#   T3c the gh read fails -> wait
#   T3d only a lead-verdict success -> wait (near miss)
#   T3e a main-ci pending -> wait; a success on HEAD's parent only -> wait
#   T4 tick 1 HEAD=A red -> no departure; push B; tick 2 HEAD=B green ->
#      departs with target B, and A's queue entry is cleared (A is B's ancestor)
#   T5 newest success above an older failure (a re-run) -> departs
#   T6 a cached success + gh failing -> departs, no statuses read
#   T7 a queued sha that is not an ancestor of the gated sha stays on disk
#      after VERIFIED, and the log names it
#   K1 catalog/lanes.d/deploy-train.json: DEPLOY_MAIN_CI_WAIT_MIN default 45,
#      DEPLOY_MAIN_CI_GATE default 0
#
# The real bin/deploy-train.sh is driven in file mode (the
# tests/deploy-train-alert-only-test.sh fixture: a scratch repo, curl, gh,
# beat and flock shims).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS="$T" TRAIN_POLLS=1 TRAIN_POLL_SECS=0
# The gate's clock (DMC_NOW): the wait is counted against this, never the wall.
NOW=1700000000; export DMC_NOW="$NOW"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/bin" "$T/env" "$T/logs" "$T/locks" "$T/state/deploy-queue/p" "$T/calls" "$T/st"
G() { git -C "$T/repo" -c user.email=t@t -c user.name=t "$@"; }
git init -q "$T/repo" && G commit -q --allow-empty -m one && G commit -q --allow-empty -m two \
  && git init -q --bare "$T/origin.git" && G remote add origin "$T/origin.git" && G push -q origin HEAD:main \
  && G fetch -q origin || exit 1
A=$(G rev-parse HEAD); PARENT=$(G rev-parse HEAD~1)
export DEPLOY_TRAIN_REPO_DIR="$T/repo"
cp "$DIR/bin/alert-line.sh" "$T/bin/"
printf '#!/bin/bash\necho org/repo\n' > "$T/bin/fleet-conf.sh"
printf '#!/bin/bash\necho "$1" >> "$HARNESS/calls/beat"\n' > "$T/bin/beat.sh"
cat > "$T/bin/curl" <<'SH'
#!/bin/bash
case "$*" in *POST*) echo hook >> "$HARNESS/calls/hook" ;; *) printf '{"sha":"%s"}' "$(cat "$HARNESS/live")" ;; esac
SH
# gh: the statuses of <sha> are $HARNESS/st/<sha> ([] when absent); gh-fail fails every call.
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$HARNESS/calls/gh"
[ -e "$HARNESS/gh-fail" ] && exit 1
case "$*" in
  *"/statuses"*) a="$*"; s="${a#*commits/}"; s="${s%%/*}"; cat "$HARNESS/st/$s" 2>/dev/null || echo '[]' ;;
  *) exit 1 ;;
esac
SH
printf '#!/bin/bash\nexit 0\n' > "$T/bin/flock"
chmod +x "$T/bin/"*; export PATH="$T/bin:$PATH"
ENV_ON='VERSION_URL=https://example.test/api/internal/version
DEPLOY_ROLLBACK=off
DEPLOY_HOOK_URL=https://example.test/hook
DEPLOY_MAIN_CI_GATE=1
'
printf '%s' "$ENV_ON" > "$T/env/p.env"
st() { # st <sha> <context> <state> [<context> <state> ...] — newest first
  local s="$1" j='[]'; shift
  while [ $# -ge 2 ]; do j=$(jq -c --arg c "$1" --arg s "$2" '. + [{context:$c, state:$s, description:"x"}]' <<<"$j"); shift 2; done
  printf '%s\n' "$j" > "$T/st/$s"
}
enqueue() { printf '%s build-x\n' "$1" > "$T/state/deploy-queue/p/$(( $(date +%s) - ${2:-60} ))-${1:0:8}"; }
reset() { rm -rf "$T/calls"/* "$T/logs/deploy-train.log" "$T/logs/ALERTS.log" "$T/state/deploy-queue/p"/* "$T/state/deploy-main-ci" "$T/st"/* "$T/gh-fail"; }
run() { "$DIR/bin/deploy-train.sh" p; }
qn() { find "$T/state/deploy-queue/p" -type f | grep -c .; }
LOGF="$T/logs/deploy-train.log"
departed() { grep -q "train departing" "$LOGF" 2>/dev/null; }

# ── T0. the switch: gate unset, a red HEAD departs exactly as today.
reset; printf 'VERSION_URL=https://example.test/api/internal/version\nDEPLOY_ROLLBACK=off\n' > "$T/env/p.env"
st "$A" main-ci failure; enqueue "$A"; printf '%s' "$A" > "$T/live"
run; RC=$?
{ [ "$RC" = 0 ] && departed && grep -q "VERIFIED live at ${A:0:8}" "$LOGF"; } && ok || bad "T0: gate off must depart as today (rc=$RC log=$(cat "$LOGF" 2>/dev/null))"
[ ! -s "$T/calls/gh" ] && ok || bad "T0: gate off reads no status: $(cat "$T/calls/gh")"
printf '%s' "$ENV_ON" > "$T/env/p.env"

# ── T1. success: GREEN, then departing, then VERIFIED.
reset; st "$A" main-ci success lead-verdict success; enqueue "$A"; printf '%s' "$A" > "$T/live"
run; RC=$?
GL=$(grep -n "MAIN_CI_GREEN ${A:0:8}" "$LOGF" 2>/dev/null | head -1 | cut -d: -f1)
DL=$(grep -n "train departing" "$LOGF" 2>/dev/null | head -1 | cut -d: -f1)
{ [ "$RC" = 0 ] && [ -n "$GL" ] && [ -n "$DL" ] && [ "$GL" -lt "$DL" ] && grep -q "VERIFIED live at ${A:0:8}" "$LOGF"; } && ok \
  || bad "T1: GREEN before departing, then VERIFIED (rc=$RC log=$(cat "$LOGF" 2>/dev/null))"
[ "$(qn)" = 0 ] && ok || bad "T1: the queue is cleared after VERIFIED"
[ "$(grep -c '/statuses' "$T/calls/gh" 2>/dev/null)" = 1 ] && ok || bad "T1: one statuses read per tick: $(cat "$T/calls/gh" 2>/dev/null)"

# ── T2. failure: never departs, the log names it, the queue and hook untouched.
reset; st "$A" main-ci failure; enqueue "$A"; printf '%s' "$PARENT" > "$T/live"
run; RC=$?
{ [ "$RC" = 0 ] && grep -q "MAIN_CI_RED ${A:0:8}" "$LOGF" && ! departed; } && ok || bad "T2: rc=$RC log=$(cat "$LOGF" 2>/dev/null)"
{ [ "$(qn)" = 1 ] && [ ! -e "$T/calls/hook" ] && [ ! -e "$T/logs/ALERTS.log" ]; } && ok || bad "T2: queue kept ($(qn)), no hook, no alert"

# ── T3a. no status, first seen 10 minutes ago: wait.
reset; enqueue "$A"; mkdir -p "$T/state/deploy-main-ci/p"; echo $(( NOW - 600 )) > "$T/state/deploy-main-ci/p/$A.seen"
run; RC=$?
{ [ "$RC" = 0 ] && grep -q "MAIN_CI_WAIT ${A:0:8} (10m of 45m" "$LOGF" && ! departed && [ "$(qn)" = 1 ]; } && ok \
  || bad "T3a: rc=$RC log=$(cat "$LOGF" 2>/dev/null)"
# the first sight writes the .seen marker, once; a later tick counts from it.
rm -f "$T/state/deploy-main-ci/p/$A.seen"; run
S1=$(cat "$T/state/deploy-main-ci/p/$A.seen" 2>/dev/null); DMC_NOW=$(( NOW + 1200 )) run
{ [ "$S1" = "$NOW" ] && [ "$(cat "$T/state/deploy-main-ci/p/$A.seen")" = "$NOW" ] && grep -q "MAIN_CI_WAIT ${A:0:8} (20m of 45m" "$LOGF"; } && ok \
  || bad "T3a: .seen is written once on the first sight (S1=$S1 log=$(tail -1 "$LOGF"))"

# ── T3b. past the bound: UNKNOWN, no departure, one ALERTS line over two ticks.
reset; enqueue "$A"; mkdir -p "$T/state/deploy-main-ci/p"; echo $(( NOW - 2760 )) > "$T/state/deploy-main-ci/p/$A.seen"
run; run; RC=$?
{ [ "$RC" = 0 ] && [ "$(grep -c "MAIN_CI_UNKNOWN ${A:0:8} after 46m" "$LOGF")" = 2 ] && ! departed && [ "$(qn)" = 1 ]; } && ok \
  || bad "T3b: rc=$RC log=$(cat "$LOGF" 2>/dev/null)"
[ "$(grep -c "MAIN_CI_UNKNOWN" "$T/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok || bad "T3b: exactly one ALERTS line: $(cat "$T/logs/ALERTS.log" 2>/dev/null)"
# the bound is the knob.
reset; enqueue "$A"; mkdir -p "$T/state/deploy-main-ci/p"; echo $(( NOW - 2760 )) > "$T/state/deploy-main-ci/p/$A.seen"
DEPLOY_MAIN_CI_WAIT_MIN=60 run
grep -q "MAIN_CI_WAIT ${A:0:8} (46m of 60m" "$LOGF" && ok || bad "T3b: DEPLOY_MAIN_CI_WAIT_MIN=60 must wait at 46m: $(cat "$LOGF")"

# ── T3c/T3d/T3e. unreadable, another context, pending, a parent's success: wait.
reset; enqueue "$A"; st "$A" main-ci success; : > "$T/gh-fail"; run
grep -q "MAIN_CI_WAIT ${A:0:8} (0m of 45m, main-ci unreadable)" "$LOGF" && ! departed && ok || bad "T3c: $(cat "$LOGF" 2>/dev/null)"
reset; enqueue "$A"; st "$A" lead-verdict success main-ci-x success; run
grep -q "MAIN_CI_WAIT ${A:0:8} (0m of 45m, main-ci none)" "$LOGF" && ! departed && ok || bad "T3d: $(cat "$LOGF" 2>/dev/null)"
reset; enqueue "$A"; st "$A" main-ci pending; run
grep -q "MAIN_CI_WAIT ${A:0:8}" "$LOGF" && ! departed && ok || bad "T3e: pending must wait: $(cat "$LOGF" 2>/dev/null)"
reset; enqueue "$A"; st "$PARENT" main-ci success; run
grep -q "MAIN_CI_WAIT ${A:0:8}" "$LOGF" && ! departed && ok || bad "T3e: a parent's success is not HEAD's: $(cat "$LOGF" 2>/dev/null)"

# ── T5. a re-run: the newest success above an older failure departs.
reset; st "$A" main-ci success main-ci failure; enqueue "$A"; printf '%s' "$A" > "$T/live"; run
grep -q "VERIFIED live at ${A:0:8}" "$LOGF" && ok || bad "T5: $(cat "$LOGF" 2>/dev/null)"

# ── T6. a cached success departs with gh failing, and reads nothing.
reset; mkdir -p "$T/state/deploy-main-ci/p"; echo success > "$T/state/deploy-main-ci/p/$A"; : > "$T/gh-fail"
enqueue "$A"; printf '%s' "$A" > "$T/live"; run
{ grep -q "VERIFIED live at ${A:0:8}" "$LOGF" && ! grep -q '/statuses' "$T/calls/gh" 2>/dev/null; } && ok || bad "T6: $(cat "$LOGF" 2>/dev/null)"

# ── T4. red A, then green B: B departs, and A rides it (an ancestor of B).
reset; st "$A" main-ci failure; enqueue "$A" 120; printf '%s' "$PARENT" > "$T/live"
run
{ grep -q "MAIN_CI_RED ${A:0:8}" "$LOGF" && ! departed; } && ok || bad "T4: tick 1 must not depart on red A: $(cat "$LOGF")"
G commit -q --allow-empty -m three && G push -q origin HEAD:main || exit 1
B=$(G rev-parse HEAD); st "$B" main-ci success; enqueue "$B" 30; printf '%s' "$B" > "$T/live"
run
{ grep -q "MAIN_CI_GREEN ${B:0:8}" "$LOGF" && grep -q "VERIFIED live at ${B:0:8} (2 merges)" "$LOGF" && [ "$(qn)" = 0 ]; } && ok \
  || bad "T4: tick 2 departs on green B with A in the batch (queue $(qn)): $(cat "$LOGF")"

# ── T7. a queued sha that is not an ancestor of the gated sha stays queued.
reset; G checkout -q -b side && G commit -q --allow-empty -m side || exit 1
C=$(G rev-parse HEAD); G push -q origin side && G checkout -q - || exit 1
st "$B" main-ci success; enqueue "$B" 90; enqueue "$C" 30; printf '%s' "$B" > "$T/live"
run
{ grep -q "VERIFIED live at ${B:0:8} (1 merges)" "$LOGF" && grep -q "${C:0:8} is not in the gated ${B:0:8}" "$LOGF"; } && ok \
  || bad "T7: only B departs and C is named: $(cat "$LOGF")"
{ [ "$(qn)" = 1 ] && grep -q "^$C " "$T/state/deploy-queue/p"/*; } && ok || bad "T7: C's queue file must stay on disk ($(qn))"

# ── K1. the knobs are registered with their defaults.
# The knobs are per-knob files (BH-4987); bin/lanes-build.sh composes them into the lane.
KD="$DIR/catalog/lanes.d/deploy-train.knobs.d"
[ "$(jq -r 'select(.env == "DEPLOY_MAIN_CI_WAIT_MIN") | .default' "$KD/DEPLOY_MAIN_CI_WAIT_MIN.json" 2>/dev/null)" = 45 ] && ok || bad "K1: DEPLOY_MAIN_CI_WAIT_MIN default 45"
[ "$(jq -r 'select(.env == "DEPLOY_MAIN_CI_GATE") | .default' "$KD/DEPLOY_MAIN_CI_GATE.json" 2>/dev/null)" = 0 ] && ok || bad "K1: DEPLOY_MAIN_CI_GATE default 0"

echo "deploy-train-green-sha: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
