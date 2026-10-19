#!/bin/bash
# tests/pipeline-health-hub-run-done.bh-7522-test.sh — BH-7522: a hub (non-Fly)
# `pipeline-health.sh --project <p>` run writes the `pipeline-health project <p>:
# run done in <N>s` line, exactly once, and the lane-move counter
# (bin/lib/lane-move/pipeline-health.sh) counts it. Drives the REAL script in
# the scratch tree of tests/lib/ph-sections-fixture.sh (placement: hub, no
# LANE_RUN_ID).
#   H1  one hub run of pa: one `run done` line for pa, none for pb
#   H2  the counter over a window that holds the run: pa 1
#   H3  a second hub run of pa: two lines, counter pa 2 (no double count)
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pipeline-health-hub-run-done.bh-7522-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/ph-sections-fixture.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null && command -v flock >/dev/null \
  || { echo "jq/python3/flock missing — skipping"; exit 0; }

NOW=$(date +%s)
mk() { # mk <dir> — the fixture tree, two projects, the runner and the qfr stub
  local d="$1"; phs_mktree "$d"
  printf 'pa\to/pa\npb\to/pb\n' > "$d/fleet.conf"
  mkdir -p "$d/builds"
  ln -sf "$DIR/bin/project-lane-run.sh" "$d/bin/project-lane-run.sh"
  ln -sf "$DIR/bin/lib/project-lanes.sh" "$d/bin/lib/project-lanes.sh"
  ln -sf "$DIR/bin/lib/closeout-terminal.sh" "$d/bin/lib/closeout-terminal.sh"
  cat > "$d/bin/queued-fly-relayed.sh" <<'QFR'
#!/bin/bash
echo "$1 $$" >> "$HARNESS/qfr.$1"
# Only a project's FIRST call blocks, so a hold costs one wait, not one per dir.
[ "$(grep -c . "$HARNESS/qfr.$1")" -le 1 ] || exit 1
n=0
while [ -f "$HARNESS/hold.$1" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
exit 1
QFR
  chmod +x "$d/bin/queued-fly-relayed.sh"
}
seed() { # seed <dir> <project> <count> — uncommented 2h-old build dirs
  local d="$1" p="$2" c="$3" i
  for i in $(seq 1 "$c"); do
    mkdir -p "$d/builds/$p-X-$i-202610100000"
    printf 'PR_CREATED https://github.com/o/%s/pull/%s\n' "$p" "$i" > "$d/builds/$p-X-$i-202610100000/RESULT"
  done
  touch -d "@$(( NOW - 7200 ))" "$d"/builds/"$p"-X-*/RESULT
}
ph() { # ph <dir> [args...] — one REAL run; RC is its exit code
  local d="$1"; shift
  ( export HARNESS="$d"; phs_env; export PH_DISPATCH_SPREAD_SECS="${SPREAD:-0}"
    bash "$d/bin/pipeline-health.sh" "$@" ) >"$d/out.txt" 2>"$d/err.txt"
  RC=$?
}

D="$T/d"; mk "$D"
ph "$D" --project pa
LOGF="$D/logs/pipeline-health.log"
n_pa=$(grep -c 'pipeline-health project pa: run done in [0-9]*s$' "$LOGF" 2>/dev/null)
n_pb=$(grep -c 'pipeline-health project pb: run done' "$LOGF" 2>/dev/null)
[ "$RC" = 0 ] && [ "${n_pa:-0}" = 1 ] && [ "${n_pb:-0}" = 0 ] && ok "H1 one hub run -> one run-done line for pa" \
  || bad "H1 rc=$RC pa=${n_pa:-0} pb=${n_pb:-0}: $(cat "$LOGF" 2>/dev/null | tail -5)"

count() { ( HARNESS="$D"; . "$DIR/bin/lib/lane-move/pipeline-health.sh"; lm_runs_done_pipeline_health "$(( $(date +%s) - 3600 ))" "$(( $(date +%s) + 60 ))" ); }
[ "$(count)" = "$(printf 'pa\t1')" ] && ok "H2 the counter counts the hub run" || bad "H2 counter: $(count)"

ph "$D" --project pa
[ "$(count)" = "$(printf 'pa\t2')" ] && ok "H3 two runs, counter pa 2" || bad "H3 counter: $(count)"

echo "pipeline-health-hub-run-done: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
