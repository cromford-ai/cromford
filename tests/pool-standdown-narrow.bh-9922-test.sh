#!/bin/bash
# tests/pool-standdown-narrow.bh-9922-test.sh — BH-9922, the pool-tick suite:
# the stand-down names its collision, a row stacks on a green queued blocker
# PR, and a row whose board ticket is archived, done, paused or gone gets no
# machine.
#
# THE CASE (project-3, 2026-11-23). Seven rows stood down behind TK-797 (PR
# #1326) at 18:16-18:22Z with `DEFERRED TK-xxx: waits for TK-797 (stand-down
# 2)`, and each tick until 20:01Z said `skipping TK-xxx: waits for TK-797`.
# No line named the shared file. At 20:01Z the pool said `RELEASED TK-810:
# TK-776 is done` and spawned machine 0803426fd77048 for TK-810, which the
# owner had archived on the board at 15:20Z.
#
#   N1  the DEFERRED line of a stand-down on prisma/schema.prisma ends
#       `collides on prisma/schema.prisma`; symbols and more= are named first
#   N2  the queue file and the recorded queue_put meta carry `after_on`
#   N3  the next tick's skip line ends `collides on <label>`
#   K1  blocker PR green and in the merge queue: RELEASED with `stack:`, the
#       requeue meta has stack_base=ticket/TK-797 and no after, the record has
#       defer-after.released, and a machine spawns with stack_base
#   K2  green but not queued: skip, no machine
#   K3  one check run failed (the real read path through the fake gh): skip
#   K4  the read does not answer: skip
#   K5  POOL_AFTER_STACK_QUEUED=0: skip
#   K6  sw_pre prints `queued 1326` for a ready parent branch, else `pending`;
#       as_pr_ready unit rows (ready, not queued, a failure, in progress, no
#       run, a second page, closed, fork, timeout)
#   B1  the project-3 TK-810 row: TK-776 done, ticket archived -> no machine, the
#       row is FAILED with `archived`, the queue file is gone
#   B2  not-found, B3 done, B4 paused: the same, with that word
#   B5  unreadable: released and spawned as before
#   B6  a 7 h old row with no `after` whose ticket is archived: no machine;
#       a 1 h old one is not read and spawns
#   B7  ptl_read unit rows on the real board read (fake curl): the terminal
#       and the near-miss classes
#   F1a TK-815 and TK-826 judged against PR #1326's schema patch: additive-safe
#       (they would not stand down); a plan on model Application collides
#   F1  one tick over the 8 recorded project-3 rows (as the reap writes them, with
#       after_on): 7 skip lines that name the collision, exactly 1 DROPPED
#       line (TK-810), 0 machines, 0 ALERTS lines
#
# Driven through bin/fly-pool.sh against a scratch HARNESS, a fake flyctl, a
# fake gh, a fake curl and a recording jobs client. No network: the after-stack
# and the board reads go through their seams (AFTER_STACK_FAKE_FILE,
# POOL_TICKET_LIVE_FILE) or the fake binaries, and a budget check at the end
# asserts that no unknown gh or curl call was made.
set -uo pipefail
# The build that runs this suite may itself be a hotfix (HOTFIX=1 in its env):
# sw_pre answers `exempt` first for one, so the cases set it themselves.
unset HOTFIX STACK_BASE
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
FX="$DIR/tests/fixtures/bh-9922-project-3"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
P=project-3

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/$P" \
         "$H/state/build-queue/$P" "$H/state/remote-results/$P" \
         "$H/state/pool/$P" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_project-3_OS=fixture-fly-token\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf '%s example-org/project-3 https://os.project-3.test /api/feature-board 6 local\n' "$P" > "$H/fleet.conf"
printf '12\n' > "$H/flags/fly-pool-$P"
printf 'pool-%s\n' "$P" > "$H/flags/fly-pool-app-$P"
printf '{"app":"pool-%s"}\n' "$P" > "$H/state/fly/$P.json"
printf 'registry.fly.io/pool-%s:deploy-01\n' "$P" > "$H/state/fly/$P.image"
for L in bin/result-prefix-ok.sh bin/fleet-conf.sh bin/alert-line.sh bin/lib/hold.sh \
         bin/lib/deferral-after.sh bin/lib/defer-after-stop.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
# The jobs client RECORDS the queue writes: the row is the thing under test.
cat > "$H/bin/jobs-client.sh" <<JC
[ "\${BASH_SOURCE[0]}" = "\$0" ] && exit 1
queue_put()  { printf 'put %s\n' "\$*" >> "$T/q.log"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/q.log"; return 0; }
JC
cat > "$T/fakebin/base64" <<'B64'
#!/bin/bash
REAL=/usr/bin/base64; [ -x "$REAL" ] || REAL=/bin/base64
DEC=0; W0=0; FILE=""
for a in "$@"; do
  case "$a" in -d|-D) DEC=1 ;; -w0|-w) W0=1 ;; 0|-*) ;; *) FILE="$a" ;; esac
done
GNU=0; printf 'eA==' | "$REAL" -d >/dev/null 2>&1 && GNU=1
FLAGS=()
if [ "$DEC" = 1 ]; then [ "$GNU" = 1 ] && FLAGS+=(-d) || FLAGS+=(-D)
elif [ "$W0" = 1 ]; then [ "$GNU" = 1 ] && FLAGS+=(-w0) || FLAGS+=(-b 0); fi
if [ -n "$FILE" ]; then exec "$REAL" "${FLAGS[@]}" < "$FILE"; fi
exec "$REAL" "${FLAGS[@]}"
B64
# curl: the board seam is the only caller; any curl in a pool run is counted.
cat > "$T/fakebin/curl" <<CURL
#!/bin/bash
echo "\$*" >> "$T/curl-calls"
exit 7
CURL
chmod +x "$H/bin/"*.sh "$T/fakebin"/*

SHA=1326aaaabbbbccccddddeeeeffff000011112222
write_fly_stub() {
  local result="${1:-}"
  cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
case "\$*" in
  *"machine status"*) echo "State: started" ;;
  *"ssh console"*"head"*"RESULT"*) [ -n "$result" ] && echo "$result" ;;
  *"ssh console"*) : ;;
  *"ssh sftp put"*) : ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
  chmod +x "$T/fakebin/fly"
}
# gh: the repo is visible; ticket/TK-797's PR #1326 is open when $T/pr-797 says
# so; every other branch has no PR; pulls/1326 and its check runs are files.
cat > "$T/fakebin/gh" <<GH
#!/bin/bash
echo "\$*" >> "$T/gh-calls"
if [[ "\$*" == *"-i"* ]]; then
  if [[ "\$*" == *"repos/example-org/project-3" ]]; then
    printf 'HTTP/1.1 200 OK\\n\\n{"full_name":"example-org/project-3"}\\n'; exit 0
  fi
  OPEN=\$(cat "$T/pr-797" 2>/dev/null)
  if [[ "\$*" == *"pulls?state=open&head=example-org:ticket/TK-797&"* ]]; then
    if [ "\$OPEN" = open ]; then printf 'HTTP/1.1 200 OK\\n\\n[{"number":1326,"html_url":"https://github.com/example-org/project-3/pull/1326"}]\\n'
    else printf 'HTTP/1.1 200 OK\\n\\n[]\\n'; fi
    exit 0
  fi
  if [[ "\$*" == *"pulls?state=open&per_page=100&page="* ]]; then
    if [ "\$OPEN" = open ]; then printf 'HTTP/1.1 200 OK\\n\\n[{"head":{"ref":"ticket/TK-797"},"title":"TK-797: applications merge"}]\\n'
    else printf 'HTTP/1.1 200 OK\\n\\n[]\\n'; fi
    exit 0
  fi
  if [[ "\$*" == *"pulls?state=open"* ]]; then printf 'HTTP/1.1 200 OK\\n\\n[]\\n'; exit 0; fi
  if [[ "\$*" == *"repos/example-org/project-3/pulls/1326" ]] && [ -s "$T/pull-1326.json" ]; then
    printf 'HTTP/1.1 200 OK\\n\\n'; cat "$T/pull-1326.json"; exit 0
  fi
  if [[ "\$*" == *"repos/example-org/project-3/commits/$SHA/check-runs"* ]] && [ -s "$T/checks.json" ]; then
    printf 'HTTP/1.1 200 OK\\n\\n'; cat "$T/checks.json"; exit 0
  fi
  echo "\$*" >> "$T/gh-unknown"
  printf 'HTTP/1.1 404 Not Found\\n\\n{}\\n'; exit 0
fi
# The repo id probe (non -i) is known; anything else is counted.
[[ "\$*" == "api repos/example-org/project-3 -q .id" ]] && { echo 4242; exit 0; }
echo "\$*" >> "$T/gh-unknown"
exit 0
GH
chmod +x "$T/fakebin/gh"

QD="$H/state/build-queue/$P"
run_pool() {
  : > "$H/logs/fly-pool.log"; : > "$T/fly-calls"; : > "$T/q.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_project-3_OS=fixture-fly-token FLY_BIN_DIR="$T/fakebin" POOL_PR_BULK=0 \
           POOL_TICKET_LIVE_FILE="${PTL_FILE:-$FX/board-tickets.tsv}" \
           AFTER_STACK_FAKE_FILE="${ASF-$T/stack-none.tsv}" "$@"
    bash "$DIR/bin/fly-pool.sh" "$P" >/dev/null 2>&1 )
}
: > "$T/stack-none.tsv"
reset_state() {
  local p
  for p in "$QD"/*.json "$H/state/fly-pool/$P"/*.json \
           "$H/state/pool/$P"/* "$H/state/pool-marks/$P"/* "$H/builds"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  : > "$H/logs/ALERTS.log"; rm -f "$T/pull-1326.json" "$T/checks.json"
  return 0
}
spawned() { grep -c 'machine run' "$T/fly-calls" 2>/dev/null; }
pool_json() { grep -ls "\"key\":\"$1\"" "$H/state/fly-pool/$P/"*.json 2>/dev/null | head -n 1; }
qwait() { # qwait <key> <ticket> <after> [after_on]
  jq -nc --arg k "$1" --arg t "$2" --arg a "$3" --arg o "${4:-}" \
    '{ticket_id:$t,key:$k,attempt:1,deferrals:1,deaths:0,enqueued_at:"2026-11-23T18:16:00Z",after:$a}
     + (if $o == "" then {} else {after_on:$o} end)' > "$QD/$1.json"
}
# record <key> <RESULT line> — the hub build record a pool reap leaves.
record() { mkdir -p "$H/builds/pool-$P-$1-20261123181600"; printf '%s\n' "$2" > "$H/builds/pool-$P-$1-20261123181600/RESULT"; }
machine_json() { # machine_json <mid> <key> <ticket>
  jq -nc --arg m "$1" --arg k "$2" --arg t "$3" \
    '{machine:$m,key:$k,ticket_id:$t,attempt:1,deferrals:0,deaths:0,spawned_at:"2026-11-23T18:05:00Z"}' \
    > "$H/state/fly-pool/$P/$1.json"
}
LINE815="BUILD_DEFERRED OVERLAP_DEFER TK-815 vs TK-797 files=[prisma/schema.prisma,prisma/schema.prisma]; After: TK-797 — held until it merges (not before 2026-11-23 18:26:00Z), then the next triage tick re-offers TK-815 to any free box"

# ── N1/N2: the stand-down names the colliding file ──────────────────────────
reset_state; write_fly_stub "$LINE815"; echo open > "$T/pr-797"
machine_json m-n1 TK-815 cmfr815project-32611
run_pool
grep -q 'DEFERRED TK-815: waits for TK-797 (stand-down [0-9]*) .*; collides on prisma/schema.prisma$' "$H/logs/fly-pool.log" && ok \
  || bad "N1: THE BUG: the DEFERRED line names the colliding file: $(grep 'DEFERRED TK-815' "$H/logs/fly-pool.log")"
[ "$(jq -r '.after_on // empty' "$QD/TK-815.json" 2>/dev/null)" = prisma/schema.prisma ] && [ "$(jq -r '.after' "$QD/TK-815.json" 2>/dev/null)" = TK-797 ] && ok \
  || bad "N2: the queue file carries after_on next to after ($(cat "$QD/TK-815.json" 2>/dev/null || echo none))"
grep -q '^put project-3 TK-815 cmfr815project-32611 fly .*"after":"TK-797".*"after_on":"prisma/schema.prisma"' "$T/q.log" && ok \
  || bad "N2: the requeue meta carries after_on (q.log: $(tr '\n' '|' < "$T/q.log"))"
# N1b: symbols first, then files, at most 3, then the count.
reset_state; write_fly_stub "BUILD_DEFERRED OVERLAP_DEFER TK-815 vs TK-797 files=[prisma/schema.prisma,prisma/schema.prisma,src/lib/forms/service.ts,src/lib/forms/service.ts,src/lib/signups-sync.ts,src/lib/signups-sync.ts] symbols=[model:Application] more=2; After: TK-797 — held until it merges"
machine_json m-n1b TK-815 cmfr815project-32611
run_pool
grep -q 'DEFERRED TK-815: waits for TK-797 .*; collides on model:Application,prisma/schema.prisma,src/lib/forms/service.ts (+3 more)$' "$H/logs/fly-pool.log" && ok \
  || bad "N1b: the label is symbols, then files, first 3, then the count: $(grep 'DEFERRED TK-815' "$H/logs/fly-pool.log")"

# ── N3: the next tick's skip line names it ─────────────────────────────────
reset_state; write_fly_stub ""; echo open > "$T/pr-797"
qwait TK-815 cmfr815project-32611 TK-797 prisma/schema.prisma
run_pool
grep -q 'skipping TK-815: waits for TK-797 (still in flight or its PR is open) — no machine; collides on prisma/schema.prisma$' "$H/logs/fly-pool.log" && ok \
  || bad "N3: THE BUG: the skip line names the collision: $(grep 'TK-815' "$H/logs/fly-pool.log" | tail -2)"
[ "$(spawned)" = 0 ] && ok || bad "N3: no machine while TK-797's PR is open ($(spawned))"

# ── K1: a green, queued blocker PR: stack on its head ──────────────────────
printf 'example-org/project-3\t1326\tready\tticket/TK-797\t%s\n' "$SHA" > "$T/stack-ready.tsv"
reset_state; write_fly_stub ""; echo open > "$T/pr-797"
qwait TK-815 cmfr815project-32611 TK-797 prisma/schema.prisma
record TK-815 "$LINE815"
ASF="$T/stack-ready.tsv" run_pool
grep -q "RELEASED TK-815: stack: TK-797's PR #1326 is green and in the merge queue" "$H/logs/fly-pool.log" && ok \
  || bad "K1: THE BUG: the row is released onto the blocker's PR head: $(grep 'TK-815' "$H/logs/fly-pool.log" | tail -3)"
PUT=$(grep '^put project-3 TK-815' "$T/q.log")
[[ "$PUT" == *'"stack_base":"ticket/TK-797"'* ]] && [[ "$PUT" != *'"after"'* ]] && ok \
  || bad "K1: the requeue meta has stack_base and no after (q.log: $(tr '\n' '|' < "$T/q.log"))"
[ -e "$H/builds/pool-$P-TK-815-20261123181600/defer-after.released" ] && ok \
  || bad "K1: the record is marked released, so dfs_stop_check does not hold it again"
PJ=$(pool_json TK-815)
[ -n "$PJ" ] && [ "$(jq -r '.stack_base // empty' "$PJ")" = ticket/TK-797 ] && ok \
  || bad "K1: a machine spawns with stack_base ($(spawned) spawned; $(cat "$PJ" 2>/dev/null || echo 'no pool json'))"

# ── K2: green but not in the merge queue ───────────────────────────────────
printf 'example-org/project-3\t1326\tnot\tticket/TK-797\t%s\n' "$SHA" > "$T/stack-not.tsv"
reset_state; write_fly_stub ""; echo open > "$T/pr-797"
qwait TK-815 cmfr815project-32611 TK-797 prisma/schema.prisma
ASF="$T/stack-not.tsv" run_pool
[ "$(spawned)" = 0 ] && ! grep -q 'RELEASED TK-815' "$H/logs/fly-pool.log" && grep -q 'skipping TK-815: waits for TK-797' "$H/logs/fly-pool.log" && ok \
  || bad "K2: not queued: skip, no machine: $(grep 'TK-815' "$H/logs/fly-pool.log" | tail -2)"

# ── K3: one check run failed, read through the fake gh ─────────────────────
reset_state; write_fly_stub ""; echo open > "$T/pr-797"
qwait TK-815 cmfr815project-32611 TK-797 prisma/schema.prisma
jq -nc --arg s "$SHA" '{state:"open",merged:false,html_url:"https://github.com/example-org/project-3/pull/1326",head:{ref:"ticket/TK-797",sha:$s,repo:{full_name:"example-org/project-3"}}}' > "$T/pull-1326.json"
printf '{"total_count":3,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"failure"},{"status":"completed","conclusion":"skipped"}]}\n' > "$T/checks.json"
: > "$T/gh-calls"
ASF="" run_pool
[ "$(spawned)" = 0 ] && ! grep -q 'RELEASED TK-815' "$H/logs/fly-pool.log" && ok \
  || bad "K3: a failed check run is not ready: $(grep 'TK-815' "$H/logs/fly-pool.log" | tail -2)"
grep -q "commits/$SHA/check-runs" "$T/gh-calls" && ok || bad "K3: the check runs of the PR head were read ($(tr '\n' '|' < "$T/gh-calls"))"

# ── K4: the read does not answer ───────────────────────────────────────────
printf 'example-org/project-3\t1326\tunreadable\t\t\n' > "$T/stack-unr.tsv"
reset_state; write_fly_stub ""; echo open > "$T/pr-797"
qwait TK-815 cmfr815project-32611 TK-797 prisma/schema.prisma
ASF="$T/stack-unr.tsv" run_pool
[ "$(spawned)" = 0 ] && grep -q 'skipping TK-815: waits for TK-797' "$H/logs/fly-pool.log" && ok \
  || bad "K4: an unreadable PR is not stacked on: $(grep 'TK-815' "$H/logs/fly-pool.log" | tail -2)"

# ── K5: the knob off ───────────────────────────────────────────────────────
reset_state; write_fly_stub ""; echo open > "$T/pr-797"
qwait TK-815 cmfr815project-32611 TK-797 prisma/schema.prisma
ASF="$T/stack-ready.tsv" run_pool POOL_AFTER_STACK_QUEUED=0
[ "$(spawned)" = 0 ] && ! grep -q 'RELEASED TK-815' "$H/logs/fly-pool.log" && ok \
  || bad "K5: POOL_AFTER_STACK_QUEUED=0 keeps the plain hold: $(grep 'TK-815' "$H/logs/fly-pool.log" | tail -2)"

# ── K6: sw_pre and the as_pr_ready rules ───────────────────────────────────
printf 'example-org/project-3\tticket/TK-797\tready\tticket/TK-797\t%s\t1326\n' "$SHA" > "$T/branch-ready.tsv"
printf 'example-org/project-3\tticket/TK-797\tnot\t\t\t1326\n' > "$T/branch-not.tsv"
swp() { ( cd "$T" && HARNESS="$H" GH_AUTH_SLUG=example-org/project-3 SW_ROOT="$T/sw" "$@" bash -c '. "$0/bin/lib/stack-wait.sh"; sw_pre project-3 TK-815 ticket/TK-797' "$DIR" 2>/dev/null ); }
[ "$(swp env AFTER_STACK_FAKE_FILE="$T/branch-ready.tsv")" = "queued 1326" ] && ok || bad "K6: sw_pre on a ready parent prints 'queued 1326': '$(swp env AFTER_STACK_FAKE_FILE="$T/branch-ready.tsv")'"
[ "$(swp env AFTER_STACK_FAKE_FILE="$T/branch-not.tsv")" = pending ] && ok || bad "K6: sw_pre on a parent that is not ready prints pending: '$(swp env AFTER_STACK_FAKE_FILE="$T/branch-not.tsv")'"
[ "$(swp env AFTER_STACK_FAKE_FILE="$T/branch-ready.tsv" POOL_AFTER_STACK_QUEUED=0)" = pending ] && ok || bad "K6: the knob off keeps pending"
[ "$(swp env AFTER_STACK_FAKE_FILE="$T/branch-ready.tsv" HOTFIX=1)" = exempt ] && ok || bad "K6: a hotfix stays exempt first"
# as_pr_ready on canned reads: pool_rest_read and mc_pr_queued are stubs.
asr() { # asr <pull json> <checks json> <queued 0|1> -> "rc:<rc> <why>"
  printf '%s\n' "$1" > "$T/u-pull.json"; printf '%s\n' "$2" > "$T/u-checks.json"
  ( . "$DIR/bin/lib/after-stack.sh"
    pool_rest_read() {
      case "$1" in
        */pulls/1326) [ "$(cat "$T/u-pull.json")" = TIMEOUT ] && { echo TIMEOUT; return 0; }; echo 200; cat "$T/u-pull.json" ;;
        */check-runs*) echo 200; cat "$T/u-checks.json" ;;
        *) echo 404; echo '{}' ;;
      esac
    }
    mc_pr_queued() { [ "$Q" = 1 ]; }
    Q="$3"; as_pr_ready example-org/project-3 1326 >/dev/null; rc=$?; echo "rc:$rc $AS_WHY" )
}
PR_OK=$(jq -nc --arg s "$SHA" '{state:"open",merged:false,html_url:"u",head:{ref:"ticket/TK-797",sha:$s,repo:{full_name:"example-org/project-3"}}}')
RUNS3='{"total_count":3,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"neutral"},{"status":"completed","conclusion":"skipped"}]}'
case "$(asr "$PR_OK" "$RUNS3" 1)" in "rc:0 "*) ok ;; *) bad "K6: open, 3 green runs, queued is ready: $(asr "$PR_OK" "$RUNS3" 1)" ;; esac
case "$(asr "$PR_OK" "$RUNS3" 0)" in "rc:1 "*"not in the merge queue"*) ok ;; *) bad "K6: green but not queued is rc 1: $(asr "$PR_OK" "$RUNS3" 0)" ;; esac
case "$(asr "$PR_OK" '{"total_count":2,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"failure"}]}' 1)" in "rc:1 "*) ok ;; *) bad "K6: a failure is rc 1" ;; esac
case "$(asr "$PR_OK" '{"total_count":2,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"in_progress","conclusion":null}]}' 1)" in "rc:1 "*) ok ;; *) bad "K6: a run in progress is rc 1" ;; esac
case "$(asr "$PR_OK" '{"total_count":0,"check_runs":[]}' 1)" in "rc:1 "*"no check run"*) ok ;; *) bad "K6: no run is rc 1" ;; esac
R100=$(jq -nc '{total_count:101,check_runs:[range(100) | {status:"completed",conclusion:"success"}]}')
case "$(asr "$PR_OK" "$R100" 1)" in "rc:2 "*) ok ;; *) bad "K6: 101 runs with 100 on the page is unreadable: $(asr "$PR_OK" "$R100" 1)" ;; esac
case "$(asr "$(jq -c '.state="closed"' <<<"$PR_OK")" "$RUNS3" 1)" in "rc:1 "*) ok ;; *) bad "K6: a closed PR is rc 1" ;; esac
case "$(asr "$(jq -c '.head.repo.full_name="someone/project-3"' <<<"$PR_OK")" "$RUNS3" 1)" in "rc:1 "*) ok ;; *) bad "K6: a fork head is rc 1" ;; esac
case "$(asr TIMEOUT "$RUNS3" 1)" in "rc:2 "*) ok ;; *) bad "K6: a cut read is rc 2: $(asr TIMEOUT "$RUNS3" 1)" ;; esac

# ── B1: the project-3 TK-810 row ────────────────────────────────────────────────
reset_state; write_fly_stub ""; echo none > "$T/pr-797"
cp "$FX/queue/TK-810.json" "$QD/TK-810.json"
# The row's wait clock from an earlier tick: a drop must clear it, or a later
# enqueue of TK-810 starts at this old epoch and hits POOL_AFTER_MAX_MIN at once.
mkdir -p "$H/state/pool/$P"; printf 'TK-776\t%s\n' "$((NOW - 86400))" > "$H/state/pool/$P/TK-810.after-since"
run_pool
[ "$(spawned)" = 0 ] && ok || bad "B1: THE BUG: no machine for an archived ticket ($(spawned) spawned)"
[ ! -e "$H/state/pool/$P/TK-810.after-since" ] && ok || bad "B1: a dropped row leaves no after-since wait clock ($(cat "$H/state/pool/$P/TK-810.after-since" 2>/dev/null))"
grep -q '^done project-3 TK-810 failed ticket cmfr810project-32611 is archived on the board — pool row dropped, no machine' "$T/q.log" && ok \
  || bad "B1: the row ends FAILED with the named reason (q.log: $(tr '\n' '|' < "$T/q.log"))"
[ ! -e "$QD/TK-810.json" ] && ok || bad "B1: the queue file is gone"
grep -q 'DROPPED TK-810: ticket cmfr810project-32611 is archived on the board' "$H/logs/fly-pool.log" && ok \
  || bad "B1: one line says so: $(grep TK-810 "$H/logs/fly-pool.log" | tail -2)"
grep -q 'RELEASED TK-810' "$H/logs/fly-pool.log" && bad "B1: no RELEASED line for a dropped row" || ok

# ── B2-B4: not-found, done, paused ─────────────────────────────────────────
for cls in not-found done paused; do
  printf 'project-3\tcmfr810project-32611\t%s\n' "$cls" > "$T/ptl-$cls.tsv"
  reset_state; write_fly_stub ""; cp "$FX/queue/TK-810.json" "$QD/TK-810.json"
  PTL_FILE="$T/ptl-$cls.tsv" run_pool
  [ "$(spawned)" = 0 ] && grep -q "^done project-3 TK-810 failed ticket cmfr810project-32611 is $cls on the board" "$T/q.log" && [ ! -e "$QD/TK-810.json" ] && ok \
    || bad "B-$cls: no machine, FAILED with '$cls' (q.log: $(tr '\n' '|' < "$T/q.log"); spawned $(spawned))"
done

# ── B5: unreadable: released and spawned as before ─────────────────────────
printf 'project-3\tcmfr810project-32611\tunreadable\n' > "$T/ptl-unr.tsv"
reset_state; write_fly_stub ""; cp "$FX/queue/TK-810.json" "$QD/TK-810.json"
PTL_FILE="$T/ptl-unr.tsv" run_pool
grep -q 'RELEASED TK-810: TK-776 is done' "$H/logs/fly-pool.log" && [ "$(spawned)" -ge 1 ] && ok \
  || bad "B5: an unreadable board read never drops a row: $(grep TK-810 "$H/logs/fly-pool.log" | tail -2)"
grep -q 'failed ticket' "$T/q.log" && bad "B5: no FAILED write on an unreadable read" || ok

# ── B6: an old row with no after is read before its spawn; a new one is not ─
reset_state; write_fly_stub ""
jq -nc --arg ts "$(date -u -d "@$((NOW - 7 * 3600))" +%Y-%m-%dT%H:%M:%SZ)" \
  '{ticket_id:"cmfr810project-32611",key:"TK-810",attempt:0,deferrals:0,deaths:0,enqueued_at:$ts}' > "$QD/TK-810.json"
run_pool
[ "$(spawned)" = 0 ] && grep -q '^done project-3 TK-810 failed ticket cmfr810project-32611 is archived' "$T/q.log" && ok \
  || bad "B6: a 7 h old row whose ticket is archived gets no machine (q.log: $(tr '\n' '|' < "$T/q.log"); spawned $(spawned))"
reset_state; write_fly_stub ""
jq -nc --arg ts "$(date -u -d "@$((NOW - 3600))" +%Y-%m-%dT%H:%M:%SZ)" \
  '{ticket_id:"cmfr810project-32611",key:"TK-810",attempt:0,deferrals:0,deaths:0,enqueued_at:$ts}' > "$QD/TK-810.json"
run_pool
[ "$(spawned)" -ge 1 ] && ! grep -q 'failed ticket' "$T/q.log" && ok \
  || bad "B6: a 1 h old row is not read and spawns (POOL_TICKET_LIVE_AGE_S default 21600; spawned $(spawned))"
reset_state; write_fly_stub ""
jq -nc --arg ts "$(date -u -d "@$((NOW - 3600))" +%Y-%m-%dT%H:%M:%SZ)" \
  '{ticket_id:"cmfr810project-32611",key:"TK-810",attempt:0,deferrals:0,deaths:0,enqueued_at:$ts}' > "$QD/TK-810.json"
run_pool POOL_TICKET_LIVE_AGE_S=0
[ "$(spawned)" = 0 ] && ok || bad "B6: POOL_TICKET_LIVE_AGE_S=0 reads before every spawn ($(spawned) spawned)"

# ── B7: ptl_read on the real board read, through a fake curl ───────────────
mkdir -p "$T/board"
cat > "$T/fakebin/curl-board" <<CB
#!/bin/bash
url="\${@: -1}"
echo "\$url" >> "$T/board-calls"
case "\$url" in
  */boards) c=\$(cat "$T/boards-code" 2>/dev/null); [ "\$c" = 200 ] && { echo '[{"id":"b1"}]'; exit 0; }
            echo "curl: (22) The requested URL returned error: \${c:-404}" >&2; exit 22 ;;
  */tickets/*) id="\${url##*/}"
            [ -f "$T/board/\$id.timeout" ] && { echo "curl: (28) Operation timed out" >&2; exit 28; }
            [ -f "$T/board/\$id.json" ] && { cat "$T/board/\$id.json"; exit 0; }
            echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
esac
exit 7
CB
chmod +x "$T/fakebin/curl-board"
mkdir -p "$T/cbin"; cp "$T/fakebin/curl-board" "$T/cbin/curl"
bt() { printf '%s\n' "$2" > "$T/board/$1.json"; }
bt t-arch  '{"id":"t-arch","status":"archived","title":"x"}'
bt t-arat  '{"ticket":{"id":"t-arat","status":"review","archivedAt":"2026-11-23T15:20:00Z"}}'
bt t-done  '{"id":"t-done","status":"done"}'
bt t-canc  '{"id":"t-canc","status":"cancelled"}'
bt t-paus  '{"id":"t-paus","status":"paused"}'
bt t-isar  '{"id":"t-isar","status":"todo","isArchived":true}'
bt t-todo  '{"id":"t-todo","status":"todo"}'
bt t-prog  '{"id":"t-prog","status":"in_progress"}'
bt t-revw  '{"id":"t-revw","status":"review","archivedAt":null}'
bt t-note  '{"id":"t-note","status":"todo","title":"ARCHIVED_NOTE: keep the old export"}'
: > "$T/board/t-slow.timeout"
ptl() { # ptl <ticket> [boards-code] -> the class ptl_read gives on the real board path
  printf '%s\n' "${2:-200}" > "$T/boards-code"
  ( export PATH="$T/cbin:$PATH" HARNESS="$H"
    . "$DIR/bin/lib/tracker.sh"; . "$DIR/bin/lib/tracker/board.sh"
    tracker_context() { TRK_BOARD_BASE="https://os.project-3.test/api/feature-board"; TRK_BOARD_TOKEN=fixture; TRK_BOARD_TOKEN_VAR=X; return 0; }
    . "$DIR/bin/lib/pool-ticket-live.sh"
    ptl_read "$H" project-3 "$1" 2>/dev/null )
}
for row in t-arch:archived t-arat:archived t-done:done t-canc:done t-paus:paused t-isar:archived \
           t-todo:live t-prog:live t-revw:live t-note:live t-gone:not-found t-slow:unreadable; do
  id="${row%%:*}"; want="${row#*:}"
  got=$(ptl "$id")
  [ "$got" = "$want" ] && ok || bad "B7: ptl_read $id -> '$got', want '$want'"
done
got=$(ptl t-gone 404)
[ "$got" = unreadable ] && ok || bad "B7: a 404 whose /boards control read also fails (bad token) is unreadable, never not-found: '$got'"
# A GitHub-Issues project is not read at all.
printf 'project-5 example-org/project-5 - - 0 local\n' >> "$H/fleet.conf"
: > "$T/board-calls"
got=$( ( export PATH="$T/cbin:$PATH" HARNESS="$H"; . "$DIR/bin/lib/pool-ticket-live.sh"; ptl_read "$H" project-5 1016 ) )
[ "$got" = live ] && [ ! -s "$T/board-calls" ] && ok || bad "B7: a GitHub-Issues ticket is live with no read ('$got'; calls $(cat "$T/board-calls"))"
sed -i '/^project-5 /d' "$H/fleet.conf"

# ── F1a: the two recorded plans judged against PR #1326's schema patch ──────
# TK-815 (adds a field to Recording) and TK-826 (adds model CreditLedger) share
# only additive files with PR #1326, whose patch edits model Application. Under
# BH-9922 neither stands down (bin/lib/additive-overlap.sh, the rule
# plan-overlap.sh and plan-sibling.sh inflight use). A plan that names
# Application still collides, and the symbol is named.
mkdir -p "$T/repo/prisma"; cp "$FX/schema.prisma" "$T/repo/prisma/schema.prisma"
jq -r '.[] | select(.filename == "prisma/schema.prisma") | .patch' "$FX/pr-1326-files.json" > "$T/pr1326.patch"
printf '# Plan\n\n## Files to touch\n- `prisma/schema.prisma` — add `mergedAt` to model Application.\n' > "$T/plan-app.md"
f1a() { # f1a <plan.md> -> "rc:<rc> <symbols>"
  ( unset PLAN_OVERLAP_ADDITIVE_FILES; HARNESS="$H"; . "$DIR/bin/lib/additive-overlap.sh"
    AO_REPO_DIR="$T/repo"; AO_PROJECT="$P"
    ao_patch_blocks "$T/pr1326.patch" > "$T/pr1326.blocks"
    ao_pair_judge "prisma/schema.prisma ~ prisma/schema.prisma" "$1" "$T/pr1326.blocks"; echo "rc:$? ${AO_SYMBOLS:-}" )
}
case "$(f1a "$FX/plan-TK-815.md")" in "rc:0"*) ok ;; *) bad "F1a: TK-815 (Recording) vs PR #1326 (Application) is additive-safe: $(f1a "$FX/plan-TK-815.md")" ;; esac
case "$(f1a "$FX/plan-TK-826.md")" in "rc:0"*) ok ;; *) bad "F1a: TK-826 (new CreditLedger) vs PR #1326 is additive-safe: $(f1a "$FX/plan-TK-826.md")" ;; esac
case "$(f1a "$T/plan-app.md")" in "rc:1 "*model:Application*) ok ;; *) bad "F1a: a plan on model Application collides and names it: $(f1a "$T/plan-app.md")" ;; esac

# ── F1: one tick over the 8 recorded project-3 rows ─────────────────────────────
reset_state; write_fly_stub ""; echo open > "$T/pr-797"
for f in "$FX"/queue/*.json; do cp "$f" "$QD/"; done
run_pool
[ "$(grep -c 'skipping TK-8[0-9][0-9]: waits for TK-797 (still in flight or its PR is open) — no machine; collides on prisma/schema.prisma$' "$H/logs/fly-pool.log")" = 7 ] && ok \
  || bad "F1: the 7 rows behind TK-797 are held with a named collision: $(grep -c 'collides on' "$H/logs/fly-pool.log") lines"
[ "$(grep -c 'DROPPED ' "$H/logs/fly-pool.log")" = 1 ] && grep -q 'DROPPED TK-810' "$H/logs/fly-pool.log" && ok \
  || bad "F1: exactly one DROPPED line, for TK-810: $(grep DROPPED "$H/logs/fly-pool.log")"
[ "$(spawned)" = 0 ] && ok || bad "F1: no machine ($(spawned))"
[ ! -s "$H/logs/ALERTS.log" ] && ok || bad "F1: no ALERTS line: $(cat "$H/logs/ALERTS.log")"

# ── budget: no unknown gh read and no curl from a pool run ─────────────────
[ ! -s "$T/gh-unknown" ] && ok || bad "budget: a gh call the fakes do not know: $(sort -u "$T/gh-unknown" | head -3 | tr '\n' '|')"
[ ! -s "$T/curl-calls" ] && ok || bad "budget: a pool run called curl: $(head -3 "$T/curl-calls" | tr '\n' '|')"

echo "pool-standdown-narrow.bh-9922: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
