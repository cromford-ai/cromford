#!/bin/bash
# tests/stuck-work-wake.bh-6976-test.sh — BH-6976 lane C: stuck-work keeps a
# quiet PR's cached CI answer for STUCK_WORK_CI_QUIET_TTL_S (1800) when the wake
# feed is healthy and has no wake for the PR. The real swf_pr_facts runs on the
# real verbs; only the transports (gh_rest, _jobs_req) and prs_wake_seen are
# doubles (a table: lines `kind key rc`, `*` matches anything, first match wins).
#
#   S1  a `checks <head>` wake at age 1000 -> both CI reads (CI-MISS)
#   S2  no wake, feed healthy, age 1000 (> 900 TTL, < 1800 quiet), no knob set
#       -> zero status / check-runs reads, CI-HIT
#   S3  no wake, age 1800 -> re-read (the backstop)
#   S4  a `pr <n>` wake at age 1000 -> re-read
#   S5  feed rc 2 at age 1000 -> re-read (the 900 s TTL rules)
#   S6  STUCK_WORK_CI_QUIET_TTL_S=0 -> age 1000 re-reads (off)
#   S7  STUCK_WORK_CI_TTL_S=0 -> never a hit, quiet feed or not
#   S8  STUCK_WORK_CI_QUIET_TTL_S=1200 reads as 1800: age 1500 is a hit
#   S9  the knob fragment is in the composed registry at default 1800
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/stuck-work-wake.bh-6976-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

for f in "$DIR/bin/lib/stuck-work/facts-pr.sh" "$DIR/bin/lib/pr-snapshot.sh"; do
  [ -f "$f" ] || { echo "FAIL: $f is missing"; echo "stuck-work-wake: 0 passed, 1 failed"; exit 1; }
done

NOW=1700009999
T0=1700000000
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
H1=$(printf 'a%039d' 1)
U1=2026-10-01T00:00:00Z

"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 && [ -s "$T/lanes.json" ] \
  || { echo "FAIL: bin/lanes-build.sh could not compose the registry"; echo "stuck-work-wake: 0 passed, 1 failed"; exit 1; }

cat > "$T/prelude.sh" <<EOF
. "$DIR/bin/lib/gh-rest.sh"
. "$DIR/bin/lib/gh-rest-list.sh"
. "$DIR/bin/lib/verdicts.sh"
. "$DIR/bin/lib/jobs/jobs.sh"
. "$DIR/bin/lib/jobs/dequeue-watch.sh"
. "$DIR/bin/lib/stuck-work/seen.sh"
eval "\$(sed -n '/^vs_context()/p' "$DIR/bin/lib/verdict-status.sh")"
eval "\$(sed -n '/^mc_mergify_check() {/,/^}/p;/^mc_mergify_check_live() {/,/^}/p' "$DIR/bin/lib/mc/queue.sh")"
eval "\$(sed -n '/^mc_handoff_id()/p;/^mc_resolver_claim_file()/p;/^mc_resolver_claim_get() {/,/^}/p' "$DIR/bin/lib/mc/classify.sh")"
. "$DIR/bin/lib/stuck-work/facts-pr.sh"
. "$DIR/bin/lib/pr-snapshot.sh"
EOF
cat >> "$T/prelude.sh" <<'EOF'
gh_rest() {
  local m="$1" p="$2" f
  printf '%s %s\n' "$m" "$p" >> "$T/gh.calls"
  GH_REST_STATUS=200; GH_REST_REASON=
  f="$T/gh/${p//\//_}"
  if [ -f "$f" ]; then cat "$f"; return 0; fi
  case "$p" in
    */status) echo '{"state":"pending","statuses":[]}' ;;
    */check-runs) echo '{"total_count":0,"check_runs":[]}' ;;
    *) GH_REST_STATUS=404; return 44 ;;
  esac
}
_jobs_req() {
  JOBS_HTTP=200; JOBS_BODY=
  case "$2" in
    /api/settings) echo '{"settings":[]}' ;;
    /api/verdicts\?*) echo '{"standing":null}' ;;
    /api/pr-state\?*) JOBS_HTTP=404; return 2 ;;
    /api/dequeue-watch/actions*) echo '{"rows":[],"truncated":false}' ;;
    *) return 1 ;;
  esac
}
prs_wake_seen() {
  local r
  printf 'WAKE %s %s %s %s\n' "$@" >> "$T/wake.calls"
  r=$(awk -v k="$2" -v key="$3" '($1 == k || $1 == "*") && ($2 == key || $2 == "*") { print $3; exit }' "$T/wake")
  return "${r:-1}"
}
EOF

reset() {
  rm -rf "$T/gh" "$T/h" "$T/wake" "$T/wake.calls" "$T/count"
  mkdir -p "$T/gh" "$T/claims" "$T/h"
}
run() { # run [VAR=val...] — one swf_pr_facts pass in a clean env
  : > "$T/gh.calls"; : > "$T/count"
  env -i PATH="$PATH" HOME="$T" T="$T" HARNESS="$T/h" JOBS_BOX=test HARNESS_TEST_SANDBOX=1 \
    STUCK_WORK_NOW="$NOW" MC_RESOLVER_CLAIM_DIR="$T/claims" SWF_COUNT_FILE="$T/count" PR_SNAPSHOT_TTL_S=0 \
    LANE_REGISTRY="$T/lanes.json" "$@" bash -c '. "$T/prelude.sh"; swf_pr_facts o/r > "$T/out.pr"' 2> "$T/err"
  return 0
}
calls() { grep -c -- "$1" "$T/gh.calls"; }
prime() { # PR #5 at H1/U1, a quiet feed, pass 1 at NOW; extra args go to run
  reset
  jq -nc --arg h "$H1" --arg u "$U1" --arg c "$(iso "$T0")" \
    '[{number:5, html_url:"https://github.com/o/r/pull/5", draft:false, created_at:$c,
       head:{sha:$h}, labels:[{name:"ai-build"}], updated_at:$u}]' > "$T/gh/repos_o_r_pulls"
  jq -nc --arg t "$(iso "$T0")" '{state:"success",statuses:[{context:"lead-verdict",state:"success",updated_at:$t}]}' \
    > "$T/gh/repos_o_r_commits_${H1}_status"
  printf '* * 1\n' > "$T/wake"
  run "$@"
}
reread() { # reread <case> — both CI reads exactly once, counted CI-MISS
  [ "$(calls 'commits/.*/status')" = 1 ] && [ "$(calls 'commits/.*/check-runs')" = 1 ] && ok \
    || bad "$1 wanted 1 status + 1 check-runs read, got $(calls 'commits/.*/status') / $(calls 'commits/.*/check-runs') ($(cat "$T/err"))"
  grep -qx 'CI-MISS 5' "$T/count" && ok || bad "$1 count is '$(cat "$T/count")', wanted CI-MISS 5"
}
hit() { # hit <case> — no CI read, counted CI-HIT
  [ "$(calls 'commits/.*/status')" = 0 ] && [ "$(calls 'commits/.*/check-runs')" = 0 ] && ok \
    || bad "$1 wanted 0 status / 0 check-runs reads, got $(calls 'commits/.*/status') / $(calls 'commits/.*/check-runs') ($(cat "$T/err"))"
  grep -qx 'CI-HIT 5' "$T/count" && ok || bad "$1 count is '$(cat "$T/count")', wanted CI-HIT 5"
}

# ── S1 ── a checks wake on the head
prime
printf 'checks %s 0\n* * 1\n' "$H1" > "$T/wake"
run STUCK_WORK_NOW=$((NOW+1000)); reread S1

# ── S2 ── the quiet PR keeps its CI answer past the 900 s TTL
prime
[ "$(calls 'commits/.*/check-runs')" = 1 ] && ok || bad "S2 pass 1 did not read check-runs: $(cat "$T/gh.calls")"
run STUCK_WORK_NOW=$((NOW+1000)); hit S2
grep -q "^WAKE o/r checks $H1 $NOW\$" "$T/wake.calls" && grep -q "^WAKE o/r pr 5 $NOW\$" "$T/wake.calls" && ok \
  || bad "S2 the feed was not asked about checks and pr since the line's epoch: $(cat "$T/wake.calls" 2>/dev/null)"
prime
run STUCK_WORK_NOW=$((NOW+1799)); hit S2b

# ── S3 ── the backstop
prime
run STUCK_WORK_NOW=$((NOW+1800)); reread S3

# ── S4 ── a pr wake
prime
printf 'pr 5 0\n* * 1\n' > "$T/wake"
run STUCK_WORK_NOW=$((NOW+1000)); reread S4

# ── S5 ── the feed cannot tell
prime
printf '* * 2\n' > "$T/wake"
run STUCK_WORK_NOW=$((NOW+1000)); reread S5
prime
printf 'checks * 1\npr * 2\n' > "$T/wake"
run STUCK_WORK_NOW=$((NOW+1000)); reread S5b
prime
printf '* * 2\n' > "$T/wake"
run STUCK_WORK_NOW=$((NOW+899)); hit S5c

# ── S6 ── quiet TTL off
prime
run STUCK_WORK_CI_QUIET_TTL_S=0 STUCK_WORK_NOW=$((NOW+1000)); reread S6

# ── S7 ── TTL 0 is still no cache
prime STUCK_WORK_CI_TTL_S=0
run STUCK_WORK_CI_TTL_S=0 STUCK_WORK_NOW=$((NOW+10)); reread S7

# ── S8 ── a quiet TTL under 1800 reads as 1800
prime
run STUCK_WORK_CI_QUIET_TTL_S=1200 STUCK_WORK_NOW=$((NOW+1500)); hit S8
prime
run STUCK_WORK_CI_QUIET_TTL_S=bogus STUCK_WORK_NOW=$((NOW+1500)); hit S8b

# ── S9 ── the knob is registered
k=$(jq -c '.lanes[] | select(.id == "stuck-work") | .knobs[] | select(.env == "STUCK_WORK_CI_QUIET_TTL_S") | [.default, .min, .read_in]' "$T/lanes.json" 2>/dev/null)
[ "$k" = '[1800,0,"bin/lib/stuck-work/facts-pr.sh"]' ] && ok || bad "S9 the registry knob is '$k'"

echo "stuck-work-wake: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
