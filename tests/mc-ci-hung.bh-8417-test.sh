#!/bin/bash
# tests/mc-ci-hung.bh-8417-test.sh — BH-8417 (C): a CI run that stays not
# completed past MC_CI_HUNG_AFTER_S is a named finding, `CI run <id> hung <n>m`,
# and gets ONE cancel and ONE re-run per (PR, head). A second hang on the same
# head pages once and does nothing more.
#
# Incident (2026-10-26): #7750's Harness CI run started 2026-10-25T16:27:33Z
# and was still in_progress 15h later. The page said "deferred while CI is not
# green"; no line said the run was hung.
#
#   H1  in_progress 895m -> MC_CI_HUNG `CI run 18786401 hung 895m`, 1 cancel POST
#   H2  next tick, still in_progress -> 0 more POSTs
#   H3  the run reports completed (cancelled) -> 1 rerun POST, the line says
#       `requested`, never `fixed`, and the head's shared `cirerun` mark is spent
#   H4  next tick -> 0 more POSTs
#   H5  hung again on the same head -> 1 CI_HUNG_TWICE page; next tick still 1
#   N1-N6 near misses: completed run with an old start; in_progress 1 s under the
#       knob; a run listed for another sha; MC_CI_RUNS from another head;
#       no runs; a run with no start time
#   E1  exactly at the knob (5400 s) is hung
#   O1  observe mode (ACTIONS=0): one WOULD line, 0 POSTs, no mark
#   F1  a failed cancel POST: one `cancel-failed HTTP 500` line, mark kept, no retry
#   B1  the per-tick stuck-timer budget: a second PR in the same tick is deferred
#   K1-K3 MC_CI_HUNG_AFTER_S through lane_knob: no row 5400; a row 100000 -> the
#       H1 run is not hung; a project row applies to that project only
#
# Drives the REAL bin/lib/merge-conductor-lib.sh (mc_ci_state makes MC_CI_RUNS
# from an actions/runs body) and bin/merge-conductor.d/bh-8417-head-clock.sh.
# gh_rest is stubbed: 0 network.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-ci-hung.bh-8417-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: mc-ci-hung: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset GH_TOKEN GITHUB_TOKEN MC_CI_HUNG_AFTER_S
FRAG="$DIR/bin/merge-conductor.d/bh-8417-head-clock.sh"
[ -r "$FRAG" ] || { echo "FAIL: mc-ci-hung: bin/merge-conductor.d/bh-8417-head-clock.sh is missing"; exit 1; }

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
fx_mc_harness "$DIR" "$T" || exit 1
export HARNESS="$T/h"
cat > "$HARNESS/bin/lane-alert.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts.txt"
STUB
chmod +x "$HARNESS/bin/lane-alert.sh"
: > "$T/alerts.txt"
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/merge-conductor-lib.sh"
mc_init
H="$HARNESS"
# shellcheck source=bin/merge-conductor.d/bh-8417-head-clock.sh
. "$FRAG" || exit 1
export TMPDIR="$T"

CLK=1792999367            # 2026-10-26T07:22:47Z
mc_now() { printf '%s\n' "$CLK"; }
SLUG=example-org/cromford
HEADX=fe37f152fe37f152fe37f152fe37f152fe37f152
OTHER=0bd1d2e30bd1d2e30bd1d2e30bd1d2e30bd1d2e3
FX="$T/fx"; mkdir -p "$FX"
# The REST seam: actions/runs from FX/runs.json, the PR's live head, POSTs logged.
gh_rest() {
  printf '%s %s\n' "$1" "$2" >> "$FX/rest.log"
  case "$1 $2" in
    "GET "*"/actions/runs?head_sha="*) GH_REST_STATUS=200; cat "$FX/runs.json" ;;
    "GET "*"/pulls/"*) GH_REST_STATUS=200; printf '{"head":{"sha":"%s"}}\n' "$HEADX" ;;
    "POST "*) if [ -e "$FX/postfail" ]; then GH_REST_STATUS=500; return 1; fi
              GH_REST_STATUS=202; echo '{}' ;;
    *) GH_REST_STATUS=404; return 1 ;;
  esac
}
mc_ci_read_timeout_s() { echo 30; }
runs() { local x; for x in "$@"; do printf '%s\n' "$x"; done | jq -Rnc '[inputs | split("|")
  | {id: (.[0]|tonumber), name: .[1], status: .[2], conclusion: (if .[3] == "" then null else .[3] end),
     run_started_at: (if .[4] == "" then null else .[4] end), created_at: (if .[4] == "" then null else .[4] end),
     run_attempt: 1, head_sha: .[5], head_commit: {id: .[5], timestamp: "2026-10-25T16:24:30Z"}}]
  | {total_count: length, workflow_runs: .}'; }
HUNG="18786401|Harness CI|in_progress||2026-10-25T16:27:33Z|$HEADX"
DONE="18786401|Harness CI|completed|cancelled|2026-10-25T16:27:33Z|$HEADX"
POSTS() { grep -c "^POST " "$FX/rest.log" 2>/dev/null || true; }
NPOST() { grep -c "^POST .*/$1\$" "$FX/rest.log" 2>/dev/null || true; }
PAGES() { grep -c "CI_HUNG_TWICE" "$T/alerts.txt" 2>/dev/null || true; }

# One pr_worker's view: the globals mc_ci_hung_check reads.
P=cromford; KEY="$SLUG#7750"; URL="https://github.com/$SLUG/pull/7750"; ACTIONS=1
tick() { # tick <runs-spec...> — mc_ci_state (as pr_worker runs it), then the arm
  runs "$@" > "$FX/runs.json"; HEAD=${TICKHEAD:-$HEADX}
  mc_ci_state "$SLUG" "$HEAD" > "$T/ci.out"
  [ -n "${STALE_RUNS:-}" ] && MC_CI_RUNS_SHA=$OTHER
  MC_TICK_ID="t$CLK"; mc_ci_hung_check
}
RESET() { : > "$FX/rest.log"; : > "$MC_LOG"; : > "$MC_ATTEMPTS"; : > "$T/alerts.txt"; rm -f "$FX/postfail"; CLK=1792999367; ACTIONS=1; unset MC_CI_HUNG_AFTER_S; }

# ---------------------------------------------------------------------------
RESET; tick "$HUNG"
[ "${MC_CI_HUNG:-}" = "CI run 18786401 hung 895m" ] && ok || bad "H1 the finding names the run and its age (got '${MC_CI_HUNG:-}')"
[ "$(NPOST cancel)" = 1 ] && [ "$(POSTS)" = 1 ] && ok || bad "H1 one cancel POST, nothing else ($(grep POST "$FX/rest.log"))"
grep -q "repos/$SLUG/actions/runs/18786401/cancel" "$FX/rest.log" && ok || bad "H1 the cancel names the hung run"
grep -q "CI run 18786401 hung 895m (Harness CI) on fe37f152.*cancel requested" "$MC_LOG" && ok || bad "H1 the log line ($(tail -1 "$MC_LOG"))"
grep -qx "cihung $KEY $HEADX 18786401" "$MC_ATTEMPTS" && ok || bad "H1 the cihung mark is written"
CLK=$((CLK + 1800)); tick "$HUNG"
[ "$(POSTS)" = 1 ] && ok || bad "H2 still in_progress on the next tick: no second POST ($(POSTS))"
CLK=$((CLK + 1800)); tick "$DONE"
[ "$(NPOST rerun)" = 1 ] && [ "$(POSTS)" = 2 ] && ok || bad "H3 one rerun POST once the run reports completed ($(grep POST "$FX/rest.log"))"
grep -q "CI run 18786401 rerun requested on fe37f152" "$MC_LOG" && ok || bad "H3 the rerun line says requested"
grep -qi "fixed" "$MC_LOG" && bad "H3 no line claims the run is fixed" || ok
[ -n "$(mc_rerun_mark "$KEY" "$HEADX")" ] && ok || bad "H3 the head's shared cirerun mark is spent (no flake-ladder rerun of the same run)"
[ -z "${MC_CI_HUNG:-}" ] && ok || bad "H3 a completed run is not hung (got '${MC_CI_HUNG:-}')"
CLK=$((CLK + 1800)); tick "$DONE"
[ "$(POSTS)" = 2 ] && ok || bad "H4 no more POSTs ($(POSTS))"
CLK=$((CLK + 7200)); tick "18786401|Harness CI|in_progress||$(date -u -d "@$((CLK - 5500))" +%Y-%m-%dT%H:%M:%SZ)|$HEADX"
[ "$(PAGES)" = 1 ] && [ "$(POSTS)" = 2 ] && ok || bad "H5 hung again after the rerun: one page, no POST (pages $(PAGES), posts $(POSTS))"
CLK=$((CLK + 1800)); tick "18786401|Harness CI|in_progress||$(date -u -d "@$((CLK - 7300))" +%Y-%m-%dT%H:%M:%SZ)|$HEADX"
[ "$(PAGES)" = 1 ] && [ "$(POSTS)" = 2 ] && ok || bad "H5 the next tick: still one page (pages $(PAGES), posts $(POSTS))"

# ---------------------------------------------------------------------------
nm() { # nm <label> <runs-spec...>
  local l="$1"; shift; RESET; tick "$@"
  [ -z "${MC_CI_HUNG:-}" ] && [ "$(POSTS)" = 0 ] && ok || bad "$l: not hung (MC_CI_HUNG='${MC_CI_HUNG:-}', posts $(POSTS))"
}
nm "N1 completed with an old start" "$DONE"
nm "N2 in_progress 1 s under the knob" "18786401|Harness CI|in_progress||$(date -u -d "@$((1792999367 - 5399))" +%Y-%m-%dT%H:%M:%SZ)|$HEADX"
nm "N3 a run on another sha" "18786401|Harness CI|in_progress||2026-10-25T16:27:33Z|$OTHER" "18786402|Harness CI|completed|success|2026-10-25T17:00:00Z|$HEADX"
STALE_RUNS=1 nm "N4 MC_CI_RUNS read for another head" "$HUNG"
RESET; MC_CI_RUNS=""; MC_CI_RUNS_SHA=""; HEAD=$HEADX; mc_ci_hung_check
[ -z "${MC_CI_HUNG:-}" ] && [ "$(POSTS)" = 0 ] && ok || bad "N5 no runs (a memo-hit tick): nothing"
nm "N6 a run with no start time" "18786401|Harness CI|in_progress|||$HEADX"
RESET; tick "18786401|Harness CI|in_progress||$(date -u -d "@$((1792999367 - 5400))" +%Y-%m-%dT%H:%M:%SZ)|$HEADX"
[ "${MC_CI_HUNG:-}" = "CI run 18786401 hung 90m" ] && [ "$(NPOST cancel)" = 1 ] && ok || bad "E1 exactly at 5400 s is hung (got '${MC_CI_HUNG:-}', cancels $(NPOST cancel))"
# A second workflow green beside the hung one: the hung one is still named.
RESET; tick "$HUNG" "18786409|Lint|completed|success|2026-10-25T16:27:40Z|$HEADX"
[ "${MC_CI_HUNG:-}" = "CI run 18786401 hung 895m" ] && ok || bad "N7 a green second workflow does not hide the hung one (got '${MC_CI_HUNG:-}')"

# ---------------------------------------------------------------------------
RESET; ACTIONS=0; tick "$HUNG"
[ "$(POSTS)" = 0 ] && ok || bad "O1 observe mode sends no POST ($(POSTS))"
grep -q "CI run 18786401 hung 895m.*would cancel and re-run it once (observe mode" "$MC_LOG" && ok || bad "O1 one WOULD line ($(cat "$MC_LOG"))"
grep -q "^cihung " "$MC_ATTEMPTS" && bad "O1 observe mode writes no mark" || ok

RESET; touch "$FX/postfail"; tick "$HUNG"
grep -q "cancel-failed HTTP 500" "$MC_LOG" && ok || bad "F1 a failed cancel is one cancel-failed line ($(cat "$MC_LOG"))"
grep -q "^cihung " "$MC_ATTEMPTS" && ok || bad "F1 the mark stays after a failed POST"
CLK=$((CLK + 1800)); tick "$HUNG"
[ "$(NPOST cancel)" = 1 ] && ok || bad "F1 a failed cancel is not retried ($(NPOST cancel) cancel POSTs)"

RESET; mst_max_per_tick() { echo 1; }
tick "$HUNG"
KEY="$SLUG#7751"; URL="https://github.com/$SLUG/pull/7751"; tick "$HUNG"
[ "$(NPOST cancel)" = 1 ] && ok || bad "B1 the per-tick budget (1) allows one cancel ($(NPOST cancel))"
grep -q "#7751 CI run 18786401 hung 895m on fe37f152 — this tick's stuck-timer budget (1) is spent" "$MC_LOG" && ok || bad "B1 the second PR is deferred with a line"
unset -f mst_max_per_tick; KEY="$SLUG#7750"; URL="https://github.com/$SLUG/pull/7750"

# ---------------------------------------------------------------------------
# K1-K3 — the knob through lane_knob (settings rows), not the env alone.
mkdir -p "$T/reg/catalog" && cp -r "$DIR/catalog/lanes.d" "$T/reg/catalog/" || exit 1
HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/lanes-build.sh" --root "$T/reg" --write >/dev/null 2>&1 \
  || bad "K: the lane registry does not render"
KH="$T/kh"; mkdir -p "$KH/state"
( cd "$DIR" && scratch_install_closure bin/lib/lane-gate.sh "$KH" >/dev/null ) || exit 1
kv() { ( HARNESS="$KH" LANE_REGISTRY="$T/reg/catalog/lanes.json" JOBS_URL="" bash -c \
  ". '$KH/bin/lib/lane-gate.sh'; . '$FRAG'; mc_ci_hung_after_s '$1'" 2>/dev/null ); }
printf '{"fetched_at":%s,"values":{}}' "$(date +%s)" > "$KH/state/settings-cache.json"
[ "$(kv cromford)" = 5400 ] && ok || bad "K1 no row reads the registry default 5400 (got $(kv cromford))"
printf '{"fetched_at":%s,"values":{"lane.merge-conductor.mc_ci_hung_after_s":"86400"}}' "$(date +%s)" > "$KH/state/settings-cache.json"
[ "$(kv cromford)" = 86400 ] && ok || bad "K2 a global row of 86400 reads 86400 (got $(kv cromford))"
printf '{"fetched_at":%s,"values":{"lane.merge-conductor.cromford.mc_ci_hung_after_s":"86400"}}' "$(date +%s)" > "$KH/state/settings-cache.json"
[ "$(kv cromford)" = 86400 ] && [ "$(kv other-os)" = 5400 ] && ok || bad "K3 a project row applies to that project only ($(kv cromford) / $(kv other-os))"
# And the arm obeys the knob: 86400 s makes the 895m run not hung.
RESET; mc_ci_hung_after_s() { echo 86400; }; tick "$HUNG"
[ -z "${MC_CI_HUNG:-}" ] && [ "$(POSTS)" = 0 ] && ok || bad "K2 a knob of 86400 s: the 895m run is not hung (got '${MC_CI_HUNG:-}')"

echo "mc-ci-hung.bh-8417: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
