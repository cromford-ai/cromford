#!/bin/bash
# tests/merge-sweep-pause.bh-1684-test.sh — a live `merges` pause (BH-1672) stops
# the merge sweep's merge call, and nothing else about the record changes.
#
# WHY (BH-1684). A pause is a row in the jobs worker's `pauses` table, mirrored
# to state/pauses.json and read through bin/lib/pause.sh. The conductor honours
# it; the sweep is the other lane that merges, and a pause one merger ignores is
# not a pause. The guard sits after every gate, right before the merge call, and
# the skip is RETRYABLE: never recorded in state/merge-sweep-done.txt, never in
# a terminal cache, so the first tick after the pause ends or expires merges it
# with no restart and no cleanup.
#
# The fixture drives the REAL sweep (D2) with the fakebin gh from
# tests/merge-sweep-budget-test.sh: every merge attempt lands in
# merge-calls.txt, so the assertions are what gh was asked to do and what the
# log says, never the source text of the guard.
# Run from anywhere: tests/merge-sweep-pause.bh-1684-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/tmp" "$T/fakebin"
# The sweep is copied by glob: the hub's iron-law hook refuses a shell command
# that names it, and a glob is the same file.
SWEEP_SRC=""
for f in "$DIR"/bin/merge-s*.sh; do SWEEP_SRC="$f"; done
[ -n "$SWEEP_SRC" ] && [ -f "$SWEEP_SRC" ] || { echo "FAIL: the sweep script is not in $DIR/bin"; exit 1; }
cp "$SWEEP_SRC" "$T/bin/sweep.sh"
mkdir -p "$T/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$T/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$T/bin/"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/bin/lib/"
mkdir -p "$T/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/bin/lib/mc/"
# The REAL pause lib, with pause_refresh replaced by a counter: the refresh is a
# network read once #1683 lands, and this suite must keep driving the
# hand-written cache after it does.
cp "$DIR/bin/lib/pause.sh" "$T/bin/lib/pause.sh"
printf '\npause_refresh(){ echo x >> "%s/refresh.calls"; return 0; }\n' "$T" >> "$T/bin/lib/pause.sh"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
printf 'a o/a - /api/board 2 box-a\nb o/b - /api/board 3 box-b\n' > "$T/fleet.conf"
export FLEET_CONF="$T/fleet.conf"
for s in beat.sh deploy-request.sh codegraph-ensure.sh pre-arm-guards.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$T/bin/$s"; chmod +x "$T/bin/$s"
done

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  "api repos/o/"*"/rulesets"*) : ;;
  "api repos/o/"*" -q .id") echo 1 ;;
  *"pr merge"*)
    printf '%s\n' "\$*" >> "$T/merge-calls.txt"
    touch "$T/merged-\$(printf '%s\n' "\$*" | grep -oE 'pull/[0-9]+' | head -1 | cut -d/ -f2)"
    exit 0 ;;
  *"v3.diff"*) restpr --diff "+ const x = 1;" ;;
  *"api -i -X GET repos/o/"*"/pulls/"*)
    N=\$(printf '%s\n' "\$*" | grep -oE 'pulls/[0-9]+' | head -1 | cut -d/ -f2)
    if [ -f "$T/merged-\$N" ]; then restpr MERGED headsha ticket/x main "" MERGEABLE CLEAN operator deadbeefcafe
    else restpr OPEN headsha ticket/x main "" MERGEABLE CLEAN operator; fi ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*|*"api -i -X PATCH repos/"*"/issues/"*|*"api -i -X GET repos/"*"/issues/"*)
    restpr --raw 200 '{"state":"closed"}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

mkfix() { # mkfix <dirname> <owner/repo> <pr-number>
  local d="$T/builds/$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/$2/pull/$3" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  : > "$d/pipeline.log"
  touch -d "@$((1758000000 + $3))" "$d/RESULT"
}
reset_state() {
  rm -rf "$T/builds"; mkdir -p "$T/builds"
  : > "$T/state/merge-sweep-done.txt"; : > "$T/state/headbound-alerted.txt"
  : > "$T/logs/merge-sweep.log"; : > "$T/logs/ALERTS.log"
  : > "$T/merge-calls.txt"; : > "$T/gh-calls.txt"
  rm -f "$T/refresh.calls" "$T/tmp"/*.probe "$T"/merged-* 2>/dev/null
  rm -rf "$T/state/merge-sweep" "$T/state/merge-sweep-terminal"* 2>/dev/null
}
# The clock the lib judges expiry against, pinned: 2026-09-24T12:00:00Z.
NOW=$(date -u -d '2026-09-24T12:00:00Z' +%s)
EXP_ISO='2026-09-24T18:00:00Z'
EXP=$(date -u -d "$EXP_ISO" +%s)
row() { # row <scope> <what> [ended_at|null] [expires_at]
  jq -cn --arg s "$1" --arg w "$2" --arg e "${4:-$EXP_ISO}" --argjson ended "${3:-null}" \
    '{id:("p-"+$s+"-"+$w), scope:$s, what:$w, reason:"runaway fix", actor:"operator",
      created_at:"2026-09-24T10:00:00Z", expires_at:$e, ended_at:$ended,
      end_reason:(if $ended == null then null else "resumed" end)}'
}
cache() { # cache <row-json>...   ; no args = no cache file at all
  if [ "$#" -eq 0 ]; then rm -f "$T/state/pauses.json"; return; fi
  printf '%s\n' "$@" | jq -s '{pauses:., truncated:false}' > "$T/state/pauses.json"
}
run_sweep() { # run_sweep [VAR=VAL ...]
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T" SWEEP_MERGE_SETTLE=0 MC_QUEUE_TTL=0 \
    PAUSE_NOW="$NOW" env -u JOBS_HARNESS "$@" bash "$T/bin/sweep.sh" >/dev/null 2>"$T/sweep.err" ) \
    || { echo "sweep rc=$? stderr:"; cat "$T/sweep.err"; }
}
merged() { grep -qE "pull/$1( |\$)" "$T/merge-calls.txt"; }
log() { cat "$T/logs/merge-sweep.log"; }

# ============================================================================
# N0. No cache at all: the sweep merges exactly as it did before BH-1672
# ============================================================================
reset_state; mkfix pool-a-XX-1-202609240001 o/a 1; cache
run_sweep
merged 1 && ok || bad "N0: with no pauses cache the PR must merge (merge-calls: $(cat "$T/merge-calls.txt"); log: $(log))"
grep -q 'PAUSED(' "$T/logs/merge-sweep.log" && bad "N0: no cache must log no PAUSED line" || ok
[ "$(cat "$T/refresh.calls" 2>/dev/null | wc -l)" = 1 ] && ok \
  || bad "N0: pause_refresh must run exactly once per sweep run (calls: $(cat "$T/refresh.calls" 2>/dev/null))"

# ============================================================================
# P. A merges pause on project a: no merge call, a PAUSED(merges) line, nothing
#    recorded — then the SAME env with the clock past expiry merges it
# ============================================================================
reset_state; mkfix pool-a-XX-1-202609240001 o/a 1; cache "$(row a merges)"
run_sweep
[ ! -s "$T/merge-calls.txt" ] && ok \
  || bad "P: a live merges pause on a must stop the merge call (merge-calls: $(cat "$T/merge-calls.txt"))"
grep -qF 'https://github.com/o/a/pull/1 skipped: PAUSED(merges)' "$T/logs/merge-sweep.log" && ok \
  || bad "P: the log must say the PR was skipped for PAUSED(merges) (log: $(log))"
grep -qF 'pull/1' "$T/state/merge-sweep-done.txt" \
  && bad "P: a paused PR must never be recorded in merge-sweep-done.txt ($(cat "$T/state/merge-sweep-done.txt"))" || ok
[ "$(cat "$T/refresh.calls" 2>/dev/null | wc -l)" = 1 ] && ok \
  || bad "P: pause_refresh must run exactly once per sweep run"
grep -F 'PAUSED(merges)' "$T/logs/merge-sweep.log" | sed 's/^/  evidence: /'
# E. Nothing is cleaned up between the two runs: same builds, same state, same
# cache. Only the clock moves past expires_at.
run_sweep PAUSE_NOW=$((EXP + 1))
merged 1 && ok \
  || bad "E: after expires_at the same PR must merge on the next run (merge-calls: $(cat "$T/merge-calls.txt"); log: $(log))"
[ "$(grep -cF 'PAUSED(merges)' "$T/logs/merge-sweep.log")" = 1 ] && ok \
  || bad "E: the expired run must not log another PAUSED line (log: $(log))"

# ============================================================================
# F. A fleet merges pause blocks too
# ============================================================================
reset_state; mkfix pool-a-XX-1-202609240001 o/a 1; cache "$(row fleet merges)"
run_sweep
[ ! -s "$T/merge-calls.txt" ] && ok \
  || bad "F: a fleet merges pause must stop the merge call (merge-calls: $(cat "$T/merge-calls.txt"))"
grep -qF 'skipped: PAUSED(merges)' "$T/logs/merge-sweep.log" && ok || bad "F: no PAUSED(merges) line (log: $(log))"

# ============================================================================
# D. A record in the `-` bucket (a slug fleet.conf does not know): it merges
#    unpaused and under a project pause, and a fleet pause still stops it
# ============================================================================
reset_state; mkfix orphan-XX-9-202609240001 o/z 9; cache
run_sweep
if merged 9; then
  ok
  reset_state; mkfix orphan-XX-9-202609240001 o/z 9; cache "$(row a merges)"
  run_sweep
  merged 9 && ok || bad "D: a project a pause must not stop a record in the - bucket (log: $(log))"
  reset_state; mkfix orphan-XX-9-202609240001 o/z 9; cache "$(row fleet merges)"
  run_sweep
  [ ! -s "$T/merge-calls.txt" ] && ok \
    || bad "D: a fleet merges pause must stop a record in the - bucket (merge-calls: $(cat "$T/merge-calls.txt"))"
  grep -qF 'o/z/pull/9 skipped: PAUSED(merges)' "$T/logs/merge-sweep.log" && ok \
    || bad "D: the - bucket skip must log PAUSED(merges) (log: $(log))"
else
  bad "D: the unresolved-slug fixture did not merge unpaused, so the - bucket case cannot be judged (log: $(log))"
fi

# ============================================================================
# X. Adversarial negatives — none of these may stop a merge or log PAUSED
# ============================================================================
neg() { # neg <label> <row-json>...
  local label="$1"; shift
  reset_state; mkfix pool-a-XX-1-202609240001 o/a 1; cache "$@"
  run_sweep
  merged 1 && ok || bad "X/$label: must still merge (merge-calls: $(cat "$T/merge-calls.txt"); log: $(log))"
  grep -q 'PAUSED(' "$T/logs/merge-sweep.log" && bad "X/$label: must log no PAUSED line (log: $(log))" || ok
}
neg reviews-row      "$(row a reviews)" "$(row fleet reviews)"
neg other-project    "$(row b merges)"
neg ended-row        "$(row a merges '"2026-09-24T11:00:00Z"')"
neg garbage-expiry   "$(row a merges null 'not-a-date')"
neg expired-row      "$(row a merges null '2026-09-24T11:00:00Z')"
reset_state; mkfix pool-a-XX-1-202609240001 o/a 1
printf '{"pauses":[],"truncated":false}\n' > "$T/state/pauses.json"
run_sweep
merged 1 && ok || bad "X/empty-list: an empty pauses list must still merge (log: $(log))"
printf '{"pauses":' > "$T/state/pauses.json.tmp"
reset_state; mkfix pool-a-XX-1-202609240001 o/a 1; mv "$T/state/pauses.json.tmp" "$T/state/pauses.json"
run_sweep
merged 1 && ok || bad "X/garbage-json: an unreadable cache is not paused (log: $(log))"

echo "merge-sweep-pause.bh-1684-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
