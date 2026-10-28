#!/bin/bash
# tests/pool-after-slice-merged.bh-7731-test.sh — BH-7731 T3: the pool's sibling
# gate (pool_after_open in bin/fly-pool.sh) does not hold a row on a blocker
# whose build PR already merged and whose next slice is only queued.
#
# THE INCIDENT (2026-10-20). TK-1741's slice PR #2004 merged; the multi-slice
# ticket stayed open and its next slice sat in the queue. The gate read the
# queued row as "in flight" and held every sibling (TK-1521 and others) until
# the 360-min ceiling.
#
#   G1  queue file for TK-1741 + merged record + no open PR: TK-1521 is released
#   G2  the same through the jobs queue status `queued` (no queue file): released
#   G3  status `claimed` + merged record: held ("still in flight")
#   G4  merged record + an open ticket/TK-1741-r1 PR: held
#   G5  a pool machine file for TK-1741: held
#   G6  queued with no build record: held (the BH-5967 B2 premise)
#   G7  a record whose PR url is NOT in the done-file: held
#   G8  merged record, the PR read does not answer: held ("did not answer")
#
# Driven through bin/fly-pool.sh against a scratch HARNESS, a fake flyctl, a
# fake gh and a recording jobs client. curl is a tripwire.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ -r "$DIR/bin/fly-pool.sh" ] || exit 1

H="$T/h"; PJ=project-6-os
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/$PJ" \
         "$H/state/build-queue/$PJ" "$H/state/remote-results/$PJ" \
         "$H/state/pool/$PJ" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_project-6_OS=fixture-fly-token\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf '%s example-org/project-6 - - 0 local\n' "$PJ" > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-$PJ"
printf 'pool-%s\n' "$PJ" > "$H/flags/fly-pool-app-$PJ"
printf '{"app":"pool-%s"}\n' "$PJ" > "$H/state/fly/$PJ.json"
printf 'registry.fly.io/pool-%s:deploy-01\n' "$PJ" > "$H/state/fly/$PJ.image"
for L in bin/result-prefix-ok.sh bin/fleet-conf.sh bin/alert-line.sh bin/lib/hold.sh bin/lib/deferral-after.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
printf '#!/bin/bash\necho "$*" >> "%s/curl-calls"\nexit 7\n' "$T" > "$T/fakebin/curl"
# The jobs client records queue writes and answers queue_status from a file.
cat > "$H/bin/jobs-client.sh" <<JC
[ "\${BASH_SOURCE[0]}" = "\$0" ] && exit 1
queue_put()    { printf 'put %s\n' "\$*" >> "$T/q.log"; echo queued; }
queue_done()   { printf 'done %s\n' "\$*" >> "$T/q.log"; return 0; }
queue_status() { [ -r "$T/qstatus-\$2" ] || return 1; cat "$T/qstatus-\$2"; }
JC
cat > "$T/fakebin/base64" <<'B64'
#!/bin/bash
REAL=/usr/bin/base64; [ -x "$REAL" ] || REAL=/bin/base64
DEC=0; W0=0; FILE=""
for a in "$@"; do
  case "$a" in
    -d|-D)  DEC=1 ;;
    -w0|-w) W0=1 ;;
    0)      ;;
    -*)     ;;
    *)      FILE="$a" ;;
  esac
done
GNU=0; printf 'eA==' | "$REAL" -d >/dev/null 2>&1 && GNU=1
FLAGS=()
if [ "$DEC" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-d) || FLAGS+=(-D)
elif [ "$W0" = 1 ]; then
  [ "$GNU" = 1 ] && FLAGS+=(-w0) || FLAGS+=(-b 0)
fi
if [ -n "$FILE" ]; then exec "$REAL" "${FLAGS[@]}" < "$FILE"; fi
exec "$REAL" "${FLAGS[@]}"
B64

chmod +x "$H/bin/"*.sh "$T/fakebin"/*

run_pool() {
  : > "$H/logs/fly-pool.log"; : > "$T/fly-calls"; : > "$T/q.log"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           FLY_API_TOKEN_project-6_OS=fixture-fly-token FLY_BIN_DIR="$T/fakebin"
    bash "$DIR/bin/fly-pool.sh" "$PJ" >/dev/null 2>&1 )
}
cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$*" >> "$T/fly-calls"
case "\$*" in
  *"machine status"*) echo "State: started" ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
chmod +x "$T/fakebin/fly"
# gh: the repo is visible. The exact-head read for ticket/TK-1741 answers from
# $T/pr-exact (none | broken); the open-PR list (the pool's bulk read and
# pr_open_for_key_any_rest) answers $T/pr-list (a JSON array, or `broken`).
cat > "$T/fakebin/gh" <<GH
#!/bin/bash
echo "\$*" >> "$T/gh-calls"
if [[ "\$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "\$*" == *"issues/"* ]] && [[ "\$*" != *"-i"* ]]; then
  echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"MK fixture","body":""}'; exit 0
fi
if [[ "\$*" == *"-i"* ]]; then
  if [[ "\$*" == *"repos/example-org/project-6"* ]] && [[ "\$*" != *"/"*"/"*"/"* ]]; then
    printf 'HTTP/1.1 200 OK\\n\\n{"full_name":"example-org/project-6"}\\n'; exit 0
  fi
  if [[ "\$*" == *"pulls?state=open"*"ticket/TK-1741"* ]]; then
    case "\$(cat "$T/pr-exact" 2>/dev/null)" in
      broken) printf 'HTTP/1.1 502 Bad Gateway\\n\\n{}\\n' ;;
      *)      printf 'HTTP/1.1 200 OK\\n\\n[]\\n' ;;
    esac
    exit 0
  fi
  if [[ "\$*" == *"pulls?state=open&per_page=100"* ]]; then
    if [ "\$(cat "$T/pr-list" 2>/dev/null)" = broken ]; then printf 'HTTP/1.1 502 Bad Gateway\\n\\n{}\\n'; exit 0; fi
    printf 'HTTP/1.1 200 OK\\n\\n%s\\n' "\$(cat "$T/pr-list" 2>/dev/null || echo '[]')"; exit 0
  fi
  if [[ "\$*" == *"pulls?state=open"* ]]; then printf 'HTTP/1.1 200 OK\\n\\n[]\\n'; exit 0; fi
  printf 'HTTP/1.1 404 Not Found\\n\\n{}\\n'; exit 0
fi
exit 0
GH
chmod +x "$T/fakebin/gh"

QD="$H/state/build-queue/$PJ"
MURL=https://github.com/example-org/project-6/pull/2004
reset_state() {
  local p
  for p in "$QD"/*.json "$H/state/fly-pool/$PJ"/*.json "$H/state/pool/$PJ"/* "$H/builds"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  rm -f "$T"/qstatus-* "$T/pr-exact" "$T/pr-list"
  : > "$H/logs/ALERTS.log"; : > "$H/state/merge-sweep-done.txt"; : > "$T/curl-calls"
  # TK-1521 (the sibling) waits for TK-1741 in the queue.
  jq -nc '{ticket_id:"1521",key:"TK-1521",attempt:1,deferrals:3,deaths:0,enqueued_at:"2026-10-20T06:00:00Z",after:"TK-1741"}' > "$QD/TK-1521.json"
  return 0
}
# merged_record [in-done]: TK-1741's slice record, PR_CREATED #2004.
merged_record() {
  mkdir -p "$H/builds/pool-$PJ-TK-1741-202610200540"
  echo "PR_CREATED $MURL" > "$H/builds/pool-$PJ-TK-1741-202610200540/RESULT"
  [ "${1:-done}" = done ] && echo "$MURL" >> "$H/state/merge-sweep-done.txt"
  return 0
}
q1741() { jq -nc '{ticket_id:"1741",key:"TK-1741",attempt:0,deferrals:0,deaths:0,enqueued_at:"2026-10-20T06:20:00Z"}' > "$QD/TK-1741.json"; }
released() { grep -q 'RELEASED TK-1521: TK-1741 is done' "$H/logs/fly-pool.log"; }
held()     { grep -q "skipping TK-1521: waits for TK-1741$1" "$H/logs/fly-pool.log"; }
why()      { grep TK-1521 "$H/logs/fly-pool.log" | tail -2; }

# G1 queue file + merged record + no open PR: released
reset_state; merged_record; q1741
run_pool
released && ok || bad "G1: THE BUG: a queued TK-1741 whose PR merged must release TK-1521: $(why)"

# G2 queue status `queued`, no queue file: released
reset_state; merged_record; echo queued > "$T/qstatus-TK-1741"
run_pool
released && ok || bad "G2: a 'queued' status with a merged record releases TK-1521: $(why)"

# G3 claimed + merged record: held
reset_state; merged_record; echo claimed > "$T/qstatus-TK-1741"
run_pool
held ' (still in flight' && ok || bad "G3: a claimed TK-1741 is in flight: $(why)"
released && bad "G3: a claimed blocker must not release the row" || ok

# G4 merged record + an open re-run PR: held
reset_state; merged_record; q1741
echo '[{"number":2050,"title":"TK-1741: next slice","head":{"ref":"ticket/TK-1741-r1"}}]' > "$T/pr-list"
run_pool
held ' (still in flight' && ok || bad "G4: an open ticket/TK-1741-r1 PR holds the row: $(why)"

# G5 a pool machine file for TK-1741: held
reset_state; merged_record
jq -nc '{machine:"m-g5",key:"TK-1741",ticket_id:"1741",attempt:1,deferrals:0,deaths:0,spawned_at:"2026-10-20T06:30:00Z"}' > "$H/state/fly-pool/$PJ/m-g5.json"
run_pool
held ' (still in flight' && ok || bad "G5: a running TK-1741 machine holds the row: $(why)"

# G6 queued, no build record: held (BH-5967 B2)
reset_state; q1741
run_pool
held ' (still in flight' && ok || bad "G6: a queued TK-1741 with no record holds the row: $(why)"

# G7 a record whose url is not in the done-file: held
reset_state; merged_record no; q1741
run_pool
held ' (still in flight' && ok || bad "G7: an unmerged record holds the row: $(why)"

# G8 merged record, unreadable PR read: held
reset_state; merged_record; q1741; echo broken > "$T/pr-exact"; echo broken > "$T/pr-list"
run_pool
held ', and its PR read did not answer' && ok || bad "G8: an unreadable PR read holds the row: $(why)"
released && bad "G8: silence must not release the row" || ok

[ ! -s "$T/curl-calls" ] && ok || bad "budget: curl was called ($(head -3 "$T/curl-calls"))"

echo "pool-after-slice-merged.bh-7731: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
