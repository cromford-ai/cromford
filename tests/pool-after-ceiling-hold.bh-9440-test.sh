#!/bin/bash
# tests/pool-after-ceiling-hold.bh-9440-test.sh — BH-9440 C0: a wait ceiling
# never releases a held ticket onto a LIVE blocker. Past the ceiling with the
# blocker's PR still open, or its build still in flight, the hold stays and one
# alert per blocker per UTC day names the BLOCKER as the thing to move. The
# ceiling still releases when the blocker's state is unknown (its PR read did
# not answer) and when the blocker is only queued.
#
# THE DEFECT. bin/fly-pool.sh pool_after_gate tested POOL_AFTER_MAX_MIN before
# it tested `pool_after_open` rc 0, so a 6-hour hold on an open PR was released
# and a machine spawned on top of it. bin/sibling-serial.sh check released at
# SIBLING_SERIAL_MAX_MIN whatever the sibling's state. On project-6 6 of 24
# ceiling-released tickets then conflicted.
#
#   H1  BH-1016 waits 7 h for BH-890 whose PR is open: no RELEASED line, no
#       machine, the row unchanged, ONE alert line that names BH-890
#   H2  a second tick the same day, with a second row (BH-1017) held on BH-890
#       past the ceiling too: still ONE alert line for BH-890
#   H3  BH-890 in flight on a machine, no PR: the 7 h hold stays
#   H3b BH-890 only queued (no build, no PR): released at the ceiling, as before
#   H3c BH-890 queued for a re-run while its PR is open: the hold stays
#   H4  BH-890's PR read does not answer past the ceiling: released (a fresh
#       queue row), as before
#   H5  sibling-serial check: TK-142.1 in flight past SIBLING_SERIAL_MAX_MIN:
#       rc 3, SIBLING_SERIAL_HELD names TK-142.1, one alert over two checks
#   H5b TK-142.1's open PR (prs.json) past the ceiling: rc 3, HELD (PR #11)
#   H6  TK-142.1 only queued past the ceiling: SIBLING_SERIAL_RELEASED, rc 0
#
# Driven through bin/fly-pool.sh and bin/sibling-serial.sh against a scratch
# HARNESS, a fake flyctl, a fake gh (no network) and a recording jobs client.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
# The stuck alert is one per blocker per UTC day: keep H1-H3 on one day.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 120
# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/builds" "$T/fakebin"
printf 'FLY_API_TOKEN_project-5=fixture-fly-token\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 local\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"
for L in bin/result-prefix-ok.sh bin/fleet-conf.sh bin/alert-line.sh bin/lib/hold.sh bin/lib/deferral-after.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
# The jobs client RECORDS the queue writes: the row is the thing under test.
# Executed (a setting read) it answers nothing, so every setting falls back.
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
           FLY_API_TOKEN_project-5=fixture-fly-token FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
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
# gh: the repo is visible; ticket/bh-890's open-PR list is $T/pr-890 (open,
# none or broken); ticket/bh-1016 has no PR; the hold read finds an ai-build
# issue with no comments.
cat > "$T/fakebin/gh" <<GH
#!/bin/bash
if [[ "\$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "\$*" == *"issues/101"[67]* ]] && [[ "\$*" != *"-i"* ]]; then
  echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"TS fixture","body":""}'; exit 0
fi
if [[ "\$*" == *"-i"* ]]; then
  if [[ "\$*" == *"repos/example-org/project-5"* ]] && [[ "\$*" != *"/"*"/"*"/"* ]]; then
    printf 'HTTP/1.1 200 OK\\n\\n{"full_name":"example-org/project-5"}\\n'; exit 0
  fi
  if [[ "\$*" == *"pulls?state=open"*"ticket/bh-890"* ]]; then
    case "\$(cat "$T/pr-890" 2>/dev/null)" in
      open)   printf 'HTTP/1.1 200 OK\\n\\n[{"number":890,"html_url":"https://github.com/example-org/project-5/pull/890"}]\\n' ;;
      broken) printf 'HTTP/1.1 502 Bad Gateway\\n\\n{}\\n' ;;
      *)      printf 'HTTP/1.1 200 OK\\n\\n[]\\n' ;;
    esac
    exit 0
  fi
  if [[ "\$*" == *"pulls?state=open"* ]]; then printf 'HTTP/1.1 200 OK\\n\\n[]\\n'; exit 0; fi
  printf 'HTTP/1.1 404 Not Found\\n\\n{}\\n'; exit 0
fi
exit 0
GH
chmod +x "$T/fakebin/gh"

reset_state() {
  local p
  for p in "$H/state/build-queue/project-5"/*.json \
           "$H/state/fly-pool/project-5"/*.json \
           "$H/state/pool/project-5"/* "$H/state/pool-marks/project-5"/* "$H/builds"/*; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  : > "$H/logs/ALERTS.log"
  return 0
}
# machine_json <mid> <deferrals> — a live machine for BH-1016 whose RESULT is read.
machine_json() {
  jq -nc --arg m "$1" --argjson d "$2" \
    '{machine:$m,key:"BH-1016",ticket_id:"1016",attempt:1,deferrals:$d,deaths:0,spawned_at:"2026-10-10T13:20:00Z"}' \
    > "$H/state/fly-pool/project-5/$1.json"
}
QF="$H/state/build-queue/project-5/BH-1016.json"
qf() { jq -r "$1" "$QF" 2>/dev/null || echo no-queue-file; }
spawned() { grep -c 'machine run' "$T/fly-calls" 2>/dev/null; }
unset GH_TOKEN GITHUB_TOKEN

qwaitk() { # qwaitk <key> <ticket> <after> — a queued row that waits on <after>
  jq -nc --arg k "$1" --arg t "$2" --arg a "$3" \
    '{ticket_id:$t,key:$k,attempt:1,deferrals:13,deaths:0,enqueued_at:"2026-10-10T13:00:00Z",after:$a}' \
    > "$H/state/build-queue/project-5/$1.json"
}
aged() { printf '%s\t%s\n' "$2" "$((NOW - 7 * 3600))" > "$H/state/pool/project-5/$1.after-since"; }
stuck_lines() { grep -c 'BH-890' "$H/logs/ALERTS.log" 2>/dev/null; }

# ── H1: an open blocker PR past the ceiling holds, with one alert ─────────
reset_state; write_fly_stub ""; echo open > "$T/pr-890"
qwaitk BH-1016 1016 BH-890; aged BH-1016 BH-890
SINCE1=$(cat "$H/state/pool/project-5/BH-1016.after-since")
run_pool
grep -q 'RELEASED BH-1016' "$H/logs/fly-pool.log" && bad "H1: THE BUG: BH-1016 was released onto BH-890's open PR: $(grep 'RELEASED BH-1016' "$H/logs/fly-pool.log")" || ok
[ "$(spawned)" = 0 ] && ok || bad "H1: THE BUG: no machine while BH-890's PR is open ($(spawned) spawned)"
grep -q 'skipping BH-1016: waits for BH-890 past the ceiling' "$H/logs/fly-pool.log" && ok \
  || bad "H1: one line says the row waits past the ceiling: $(grep BH-1016 "$H/logs/fly-pool.log" | tail -2)"
[ "$(stuck_lines)" = 1 ] && ok || bad "H1: THE BUG: one alert line names BH-890, got $(stuck_lines): $(cat "$H/logs/ALERTS.log")"
grep -q 'hold is released' <<<"$(grep 'BH-890' "$H/logs/ALERTS.log")" && bad "H1: the alert must not say the hold is released: $(cat "$H/logs/ALERTS.log")" || ok
[ "$(qf '.after')" = BH-890 ] && [ "$(qf '.deferrals')" = 13 ] && ok || bad "H1: the row is unchanged ($(cat "$QF" 2>/dev/null))"
[ "$(cat "$H/state/pool/project-5/BH-1016.after-since" 2>/dev/null)" = "$SINCE1" ] && ok || bad "H1: the wait clock is kept"
[ -s "$T/q.log" ] && bad "H1: a hold writes no queue row (q.log: $(tr '\n' '|' < "$T/q.log"))" || ok

# ── H2: a second tick, and a second held row, the same day: one line ──────
qwaitk BH-1017 1017 BH-890; aged BH-1017 BH-890
# Two queued rows turn on the bulk PR listing, which this fake gh does not
# serve; the per-key PR read is the one under test here.
run_pool POOL_PR_BULK=0
grep -q 'RELEASED BH-101[67]' "$H/logs/fly-pool.log" && bad "H2: a held row was released: $(grep RELEASED "$H/logs/fly-pool.log")" || ok
[ "$(spawned)" = 0 ] && ok || bad "H2: no machine ($(spawned) spawned)"
grep -q 'skipping BH-1017: waits for BH-890 past the ceiling' "$H/logs/fly-pool.log" && ok || bad "H2: BH-1017 is held too: $(grep BH-1017 "$H/logs/fly-pool.log" | tail -2)"
[ "$(stuck_lines)" = 1 ] && ok || bad "H2: still one alert line for BH-890 over two ticks and two rows, got $(stuck_lines): $(cat "$H/logs/ALERTS.log")"

# ── H3: the blocker is in flight on a machine, no PR: the hold stays ──────
reset_state; write_fly_stub ""; echo none > "$T/pr-890"
qwaitk BH-1016 1016 BH-890; aged BH-1016 BH-890
jq -nc '{machine:"m-890",key:"BH-890",ticket_id:"890",attempt:1,deferrals:0,deaths:0,spawned_at:"2026-10-10T13:20:00Z"}' \
  > "$H/state/fly-pool/project-5/m-890.json"
run_pool
grep -q 'RELEASED BH-1016' "$H/logs/fly-pool.log" && bad "H3: THE BUG: released onto BH-890's live build: $(grep 'RELEASED BH-1016' "$H/logs/fly-pool.log")" || ok
[ "$(spawned)" = 0 ] && ok || bad "H3: no machine while BH-890 builds ($(spawned) spawned)"
[ "$(stuck_lines)" = 1 ] && ok || bad "H3: one alert names BH-890, got $(stuck_lines): $(cat "$H/logs/ALERTS.log")"

# ── H3b: the blocker is only queued (no build, no PR): released, as before ─
reset_state; write_fly_stub ""; echo none > "$T/pr-890"
qwaitk BH-1016 1016 BH-890; aged BH-1016 BH-890
jq -nc '{ticket_id:"890",key:"BH-890",attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-10T13:00:00Z"}' > "$H/state/build-queue/project-5/BH-890.json"
# The spawn loop walks rows by `ls -tr` (mtime). Equal mtimes can put BH-890
# first, and then BH-890 spawns and BH-1016 is held (correctly). Fix the order:
# BH-1016 is older, so it is judged first on every run.
touch -d "@$((NOW - 120))" "$QF"
touch -d "@$((NOW - 60))" "$H/state/build-queue/project-5/BH-890.json"
run_pool POOL_PR_BULK=0
grep -q 'RELEASED BH-1016: ceiling' "$H/logs/fly-pool.log" && ok || bad "H3b: a queued-only blocker releases at the ceiling: $(grep BH-1016 "$H/logs/fly-pool.log" | tail -2)"
grep -q 'BH-890 is only queued' "$H/logs/ALERTS.log" && ok || bad "H3b: the alert says the blocker is only queued: $(cat "$H/logs/ALERTS.log")"
grep -q 'AFTER STUCK' "$H/logs/ALERTS.log" && bad "H3b: no stuck alert for a queued-only blocker" || ok

# ── H3c: queued, but its PR is open (a re-run): the hold stays ────────────
reset_state; write_fly_stub ""; echo open > "$T/pr-890"
qwaitk BH-1016 1016 BH-890; aged BH-1016 BH-890
jq -nc '{ticket_id:"890",key:"BH-890",attempt:2,deferrals:0,deaths:0,enqueued_at:"2026-10-10T13:00:00Z"}' > "$H/state/build-queue/project-5/BH-890.json"
run_pool POOL_PR_BULK=0
grep -q 'RELEASED BH-1016' "$H/logs/fly-pool.log" && bad "H3c: a queued re-run with an open PR must hold: $(grep 'RELEASED BH-1016' "$H/logs/fly-pool.log")" || ok
grep -q 'skipping BH-1016: waits for BH-890 past the ceiling' "$H/logs/fly-pool.log" && ok || bad "H3c: held past the ceiling: $(grep BH-1016 "$H/logs/fly-pool.log" | tail -2)"

# ── H4: the PR read does not answer past the ceiling: released, as today ──
reset_state; write_fly_stub ""; echo broken > "$T/pr-890"
qwaitk BH-1016 1016 BH-890; aged BH-1016 BH-890
run_pool
grep -q 'RELEASED BH-1016: ceiling' "$H/logs/fly-pool.log" && ok || bad "H4: an unknown blocker state still releases at the ceiling: $(grep BH-1016 "$H/logs/fly-pool.log" | tail -2)"
# (no spawn this tick: after a 502 the later PR gate stops reading PRs for the
# tick, so the fresh row spawns on the next one.)
grep -q '^put project-5 BH-1016 1016 fly 1 {"deferrals":0}' "$T/q.log" && ok || bad "H4: the release writes a fresh row (q.log: $(tr '\n' '|' < "$T/q.log"))"
[ "$(grep -c 'AFTER CEILING' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "H4: one AFTER CEILING alert: $(cat "$H/logs/ALERTS.log")"

# ── H5/H6: bin/sibling-serial.sh check, the second ceiling ────────────────
S="$T/s"; SQ="$S/state/build-queue/project-5"; SM="$S/state/fly-pool/project-5"; SD="$S/state/sibling-serial/project-5"
mkdir -p "$S/bin" "$S/logs" "$S/flags" "$S/plans" "$S/env" "$SQ" "$SM" "$SD"
: > "$S/env/global.env"
printf 'project-5 - - - 0 local\n' > "$S/fleet.conf"
printf '#!/bin/bash\necho "$*" >> "%s/s-alerts"\nexit 0\n' "$T" > "$S/bin/alert-line.sh"; chmod +x "$S/bin/alert-line.sh"
( cd "$DIR" && scratch_install_closure bin/sibling-serial.sh "$S" ) >/dev/null || { echo "setup: could not install bin/sibling-serial.sh"; exit 1; }
SNOW=1791860000
plan_files() { local k="$1"; shift; mkdir -p "$S/plans/project-5-$k"; printf '%s\n' "$@" > "$S/plans/project-5-$k/planned-files.txt"; }
squeue() { jq -nc --arg k "$1" --arg t "$2" --arg e "$3" '{ticket_id:$t,key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:$e}' > "$SQ/$1.json"; }
sreset() { local p; for p in "$SQ"/* "$SM"/* "$SD"/* "$S/state/overlap-guard" "$T/s-alerts"; do [ -e "$p" ] && scratch_rm "$p"; done; return 0; }
chk() { HARNESS="$S" SIBLING_SERIAL_NOW="$SNOW" "$S/bin/sibling-serial.sh" check project-5 TK-142.2 2>"$T/s-err"; }
sfix() { # the common fixture: .1 and .2 plan the same file, .2 queued, .2's clock 361 min old
  sreset
  plan_files TK-142.1 src/x/board.tsx; plan_files TK-142.2 src/x/board.tsx
  squeue TK-142.2 1422 2026-10-13T02:30:00Z
  printf 'TK-142.1\t%s\n' "$((SNOW - 361 * 60))" > "$SD/TK-142.2.sibling-since"
}

# H5: .1 in flight past the ceiling
sfix
jq -nc '{machine:"m-one",key:"TK-142.1",ticket_id:"1421",attempt:1,deferrals:0,deaths:0,spawned_at:"2026-10-13T02:30:00Z"}' > "$SM/m-one.json"
OUT=$(chk); RC=$?
[ "$RC" = 3 ] && ok || bad "H5: THE BUG: a live TK-142.1 past the ceiling must hold .2 (rc $RC, out '$OUT')"
grep -q '^SIBLING_SERIAL_HELD TK-142.2 past ceiling behind TK-142.1 (in flight)$' <<<"$OUT" && ok \
  || bad "H5: a SIBLING_SERIAL_HELD line names TK-142.1 (out '$OUT')"
grep -q RELEASED <<<"$OUT" && bad "H5: no release line on a live blocker (out '$OUT')" || ok
OUT=$(chk); RC=$?
[ "$RC" = 3 ] && ok || bad "H5: a second check still holds (rc $RC)"
[ "$(grep -c 'TK-142.1' "$T/s-alerts" 2>/dev/null)" = 1 ] && ok || bad "H5: one alert naming TK-142.1 over two checks, got: $(cat "$T/s-alerts" 2>/dev/null)"
grep -q 'sibling-serial-stuck-project-5-TK-142.1-' "$T/s-alerts" 2>/dev/null && ok || bad "H5: the alert id names the blocker: $(cat "$T/s-alerts" 2>/dev/null)"

# H5b: .1's PR is open (overlap-guard snapshot) past the ceiling
sfix
mkdir -p "$S/state/overlap-guard"
jq -nc '[{number:11, headRefName:"ticket/TK-142.1", isDraft:false, files:[{path:"src/x/board.tsx"}]}]' > "$S/state/overlap-guard/project-5-prs.json"
OUT=$(chk); RC=$?
[ "$RC" = 3 ] && grep -q '^SIBLING_SERIAL_HELD TK-142.2 past ceiling behind TK-142.1 (PR #11)$' <<<"$OUT" && ok \
  || bad "H5b: an open PR of TK-142.1 past the ceiling holds .2 (rc $RC, out '$OUT')"

# H6: .1 only queued (fresh, no machine, no PR) past the ceiling: released
sfix
squeue TK-142.1 1421 "$(date -u -d "@$((SNOW - 600))" +%Y-%m-%dT%H:%M:%SZ)"
OUT=$(chk); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "SIBLING_SERIAL_RELEASED TK-142.2 after 361 min behind TK-142.1" ] && ok \
  || bad "H6: a queued-only sibling past the ceiling releases .2 (rc $RC, out '$OUT')"

# 0 GitHub calls left this box: gh is a fake on PATH, and no token is set.
[ -z "${GH_TOKEN:-}" ] && ok || bad "no GH_TOKEN in the test"

echo "pool-after-ceiling-hold.bh-9440: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
