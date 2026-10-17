#!/bin/bash
# tests/fly-pool-stall-reclaim.bh-7107-test.sh — the pool reclaims the slots of
# machines Fly no longer has, says when its queue is stalled and why, and a HOLD
# or a closed issue cancels that ticket's in-flight build (BH-7107).
#
# THE DEFECT. bin/fly-pool.sh read only FLY_API_TOKEN_<P>. With that empty it
# ran `exit 0` before the reap, with no line and no alert, so the job files of
# dead machines held every slot of the project-6-os pool and nothing reclaimed
# them. The hub's fly.env carries the org FLY_API_TOKEN, which the pool never
# looked at.
#
#   Section U  the pure deciders: bin/lib/fly-token.sh and bin/lib/pool-stall.sh
#              (S1-S8 the stall verdict, H1-H12 the in-flight action, due and
#              grace tables, the cause line).
#   Section R  the real bin/fly-pool.sh: token order and the no-token path
#              (R1-R6); R7 the state-paths guard on the new libs.
#   Section S  the real bin/fly-pool.sh: the stall alert (S9-S11); S12 the
#              hourly flag name and its groom by bin/alerts-groom.sh.
#   Section H  the real bin/fly-pool.sh: the in-flight HOLD cancel (H13-H20),
#              with a gh stub that serves the issue, its thread and the open
#              ai-build listing, and the real bin/lib/hold.sh classifier.
#   Section K  the three knob defaults through lane_knob.
#
# Run from anywhere: tests/fly-pool-stall-reclaim.bh-7107-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
# Nothing from this box's own env may decide a token answer (D60).
unset FLY_API_TOKEN FLY_API_TOKEN_TPROJ FLY_ACCESS_TOKEN POOL_STALL_ALERT_S \
      POOL_INFLIGHT_HOLD_READS POOL_INFLIGHT_HOLD_GRACE_S POOL_AUTOSCALE POOL_CAP_MAX
TAB=$'\t'
NOW0=1791860000   # pinned for the pure tables

# ════ Section U: the pure deciders ═════════════════════════════════════════
# shellcheck source=bin/lib/fly-token.sh
. "$DIR/bin/lib/fly-token.sh" || { echo "FAIL: bin/lib/fly-token.sh cannot be sourced"; exit 1; }
# shellcheck source=bin/lib/pool-stall.sh
. "$DIR/bin/lib/pool-stall.sh" || { echo "FAIL: bin/lib/pool-stall.sh cannot be sourced"; exit 1; }

# T1 lib: project token first, org token second, FLY_ACCESS_TOKEN never.
( FLY_API_TOKEN_project-6_OS=tok-fixture-proj FLY_API_TOKEN=tok-fixture-org
  fly_token_resolve project-6-os; rc=$?
  [ "$rc" = 0 ] && [ "$FLY_TOKEN_SRC" = FLY_API_TOKEN_project-6_OS ] && [ "$FLY_TOKEN_VAL" = tok-fixture-proj ] ) && ok \
  || bad "U1: the project token must win over the org token"
( FLY_API_TOKEN=tok-fixture-org
  fly_token_resolve project-6-os; rc=$?
  [ "$rc" = 0 ] && [ "$FLY_TOKEN_SRC" = FLY_API_TOKEN ] && [ "$FLY_TOKEN_VAL" = tok-fixture-org ] ) && ok \
  || bad "U2: with no project token the org token is used"
( FLY_ACCESS_TOKEN=tok-fixture-other
  OUT=$(fly_token_resolve project-6-os); fly_token_resolve project-6-os; rc=$?
  [ "$rc" = 1 ] && [ -z "$FLY_TOKEN_SRC" ] && [ -z "$FLY_TOKEN_VAL" ] && [ -z "$OUT" ] ) && ok \
  || bad "U3: FLY_ACCESS_TOKEN alone must not resolve, and the resolve prints nothing"
( FLY_API_TOKEN_A_B_C=tok-fixture-dots; fly_token_resolve a.b-c; [ "$FLY_TOKEN_SRC" = FLY_API_TOKEN_A_B_C ] ) && ok \
  || bad "U4: '.' and '-' map to '_' in the project token name"

v() { pool_stall_verdict "$@"; }
# S1 token missing, queued 1 -> stall at the threshold
[ "$(v 1 3 0 unknown missing $((NOW0-1800)) "$NOW0" 1800)" = "stall${TAB}1800" ] && ok || bad "S1: token missing + queued 1 must stall: $(v 1 3 0 unknown missing $((NOW0-1800)) "$NOW0" 1800)"
# S2 queued 5, budget 0, building 0
[ "$(v 5 0 0 0 ok $((NOW0-3600)) "$NOW0" 1800)" = "stall${TAB}3600" ] && ok || bad "S2: queued 5 budget 0 building 0 must stall"
# S3 building unknown, age = threshold exactly (>=)
[ "$(v 1 0 0 unknown ok $((NOW0-1800)) "$NOW0" 1800)" = "stall${TAB}1800" ] && ok || bad "S3: age == threshold is a stall"
[ "$(v 1 0 0 unknown ok $((NOW0-1799)) "$NOW0" 1800)" = "pending${TAB}1799" ] && ok || bad "S3: age threshold-1 is pending"
[ "$(v 1 0 0 0 ok - "$NOW0" 1800)" = "pending${TAB}0" ] && ok || bad "S3: the first stalled tick is pending 0"
# S4 clear side: queued 0 with the token missing; free budget (held rows that skip)
[ "$(v 0 0 0 unknown missing $((NOW0-9999)) "$NOW0" 1800)" = clear ] && ok || bad "S4: queued 0 is never a stall"
[ "$(v 5 2 0 0 ok $((NOW0-9999)) "$NOW0" 1800)" = clear ] && ok || bad "S4: free slots are not a slot stall"
# S5 a machine building
[ "$(v 5 0 0 1 ok $((NOW0-9999)) "$NOW0" 1800)" = clear ] && ok || bad "S5: building 1 is not a stall"
# S6 the hotfix exemption spawns
[ "$(v 5 0 1 0 ok $((NOW0-9999)) "$NOW0" 1800)" = clear ] && ok || bad "S6: a hotfix exemption is not a stall"
# S7 threshold 0 = off
[ "$(v 5 0 0 0 ok $((NOW0-9999)) "$NOW0" 0)" = clear ] && ok || bad "S7: threshold 0 is off"
[ "$(v 1 0 0 unknown missing $((NOW0-9999)) "$NOW0" 0)" = clear ] && ok || bad "S7: threshold 0 is off for a missing token too"
# S8 a non-number is clear and rc 2
OUT=$(v x 0 0 0 ok - "$NOW0" 1800); RC=$?
[ "$OUT" = clear ] && [ "$RC" = 2 ] && ok || bad "S8: queued 'x' must be clear rc 2 (got '$OUT' rc $RC)"
OUT=$(v 3 0 0 '' ok - "$NOW0" 1800); RC=$?
[ "$OUT" = clear ] && [ "$RC" = 2 ] && ok || bad "S8: an empty building count must be clear rc 2 (got '$OUT' rc $RC)"
[ "$(v 3 -1 0 0 ok $((NOW0-1800)) "$NOW0" 1800)" = "stall${TAB}1800" ] && ok || bad "S8: a negative budget (POOL_AUTOSCALE=0, cap below live) is no budget"

# The cause line.
C=$(pool_stall_cause missing 0 "" 0 unknown 0 FLY_API_TOKEN_project-6_OS)
[ "$C" = "no Fly token (FLY_API_TOKEN_project-6_OS or FLY_API_TOKEN) in fly.env: the pool cannot reap, sweep or spawn" ] && ok || bad "C1: missing-token cause: '$C'"
C=$(pool_stall_cause FLY_API_TOKEN 1 "" 8 0 8 FLY_API_TOKEN_project-6_OS)
[ "$C" = "8 slots held by 8 job files, 0 building: 8 on machines Fly does not list" ] && ok || bad "C2: orphan cause: '$C'"
C=$(pool_stall_cause FLY_API_TOKEN 0 "empty-with-tracked" 8 unknown 0 FLY_API_TOKEN_project-6_OS)
[ "$C" = "machines list unusable (empty-with-tracked): cannot tell if the 8 held slots are building" ] && ok || bad "C3: listing cause: '$C'"

a() { pool_inflight_hold_action "$@"; }
# H1-H4 the action table
[ "$(a "held${TAB}closed")" = park ] && ok || bad "H1: closed must park"
for x in "held${TAB}hold:comment 2026-10-16T14:00:00Z HOLD" "held${TAB}hold:label" "held${TAB}abandon:comment 2026-10-16T14:00:00Z ABANDON"; do
  [ "$(a "$x")" = requeue ] && ok || bad "H2: '$x' must requeue"
done
[ "$(a "held${TAB}label-absent")" = keep ] && ok || bad "H3: label-absent must be kept"
for x in "clear${TAB}no hold" "unreadable${TAB}HTTP 502" "" "held" "held${TAB}"; do
  [ "$(a "$x")" = keep ] && ok || bad "H4: '$x' must be kept"
done
d() { pool_inflight_hold_due "$@"; }
K1='2026-10-16T14:00:00Z|3'; K2='2026-10-16T15:00:00Z|4'
# H5 read: absent from an ok listing; a changed key; no last key
[ "$(d 77 BH-77 ok 0 "" "" 0 4)" = read ] && ok || bad "H5: absent from an ok listing must be read"
[ "$(d 77 BH-77 ok 1 "$K2" "$K1" 0 4)" = read ] && ok || bad "H5: a changed key must be read"
[ "$(d 77 BH-77 ok 1 "$K1" "" 0 4)" = read ] && ok || bad "H5: no last key must be read"
# H6 skip: board cuid, RB- key
[ "$(d clxyz0fixture BH-77 ok 1 "$K1" "" 0 4)" = "skip${TAB}board-ticket" ] && ok || bad "H6: a board ticket is never read"
[ "$(d 12 RB-12 ok 1 "$K1" "" 0 4)" = "skip${TAB}rebase" ] && ok || bad "H6: an RB- key is never read"
# H7 skip: listing truncated / unreadable
[ "$(d 77 BH-77 truncated 1 "$K1" "" 0 4)" = "skip${TAB}listing truncated" ] && ok || bad "H7: a truncated listing reads nothing"
[ "$(d 77 BH-77 'unreadable(502)' 0 "" "" 0 4)" = "skip${TAB}listing unreadable(502)" ] && ok || bad "H7: an unreadable listing reads nothing"
# H8 skip: same key, same absence
[ "$(d 77 BH-77 ok 1 "$K1" "$K1" 0 4)" = "skip${TAB}unchanged" ] && ok || bad "H8: an unchanged key is not re-read"
[ "$(d 77 BH-77 ok 0 "" absent 0 4)" = "skip${TAB}unchanged" ] && ok || bad "H8: a still-absent issue is not re-read"
# H9 skip: budget, off
[ "$(d 77 BH-77 ok 1 "$K2" "$K1" 4 4)" = "skip${TAB}budget" ] && ok || bad "H9: reads 4 of 4 is deferred"
[ "$(d 77 BH-77 ok 1 "$K2" "$K1" 3 4)" = read ] && ok || bad "H9: reads 3 of 4 still reads"
[ "$(d 77 BH-77 ok 1 "$K2" "$K1" 0 0)" = "skip${TAB}off" ] && ok || bad "H10: reads_max 0 is off"
g() { pool_inflight_hold_grace "$@"; }
# H11 the grace edges
[ "$(g $((NOW0-600)) "$NOW0" 600)" = act ] && ok || bad "H11: seen grace ago exactly must act"
[ "$(g $((NOW0-3600)) "$NOW0" 600)" = act ] && ok || bad "H11: seen an hour ago must act"
[ "$(g $((NOW0-599)) "$NOW0" 600)" = wait ] && ok || bad "H12: seen grace-1 ago must wait"
[ "$(g - "$NOW0" 600)" = wait ] && ok || bad "H12: never seen must wait"
[ "$(g "$NOW0" "$NOW0" 600)" = wait ] && ok || bad "H12: seen now must wait"
[ "$(g "$NOW0" "$NOW0" 0)" = act ] && ok || bad "H12: grace 0 acts on the first held read"

# ════ the scratch harness for the real bin/fly-pool.sh ═════════════════════
H="$T/h"
QD="$H/state/build-queue/tproj"; MD="$H/state/fly-pool/tproj"; GF="$T/gh"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" "$H/plans" \
         "$H/state/fly" "$MD" "$QD" "$H/state/remote-results/tproj" \
         "$H/state/pool/tproj" "$H/builds" "$T/fakebin" "$GF"
: > "$H/env/fly.env"; : > "$H/env/global.env"
printf 'tproj example-org/tproj - - 0 local\n' > "$H/fleet.conf"
printf 'pool-tproj\n' > "$H/flags/fly-pool-app-tproj"
printf '{"app":"pool-tproj"}\n' > "$H/state/fly/tproj.json"
printf 'registry.fly.io/pool-tproj:deploy-01\n' > "$H/state/fly/tproj.image"
printf '#!/bin/bash\necho "$*" >> "%s/alert-calls"\nexit 0\n' "$T" > "$H/bin/alert-line.sh"
# The ledger, recorded: QROW's queue_done / queue_put land here, one line each.
cat > "$H/bin/jobs-client.sh" <<EOF
queue_done() { printf 'done %s\n' "\$*" >> "$T/qrow.log"; return 0; }
queue_put()  { printf 'put %s\n'  "\$*" >> "$T/qrow.log"; return 0; }
EOF
# The stall alert's hour flag goes through bin/lib/flags.sh, so the stub client
# carries the real flag verbs (bin/lib/jobs/flags.sh) with no worker: every
# write lands on the flags/ file path, as on a box with JOBS_URL unset.
scratch_install_closure bin/lib/flags.sh "$H" >/dev/null || { echo "closure install of bin/lib/flags.sh failed"; exit 1; }
cat >> "$H/bin/jobs-client.sh" <<EOF
JOBS_HARNESS="$H"; JOBS_BOX=fixture-box
_jobs_req() { return 1; }
_jobs_log() { :; }
. "$H/bin/lib/jobs/flags.sh"
EOF
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/pool-cap.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nmkdir -p "$2"; : > "$2/global.env"; : > "$2/$1.env"; exit 0\n' > "$H/bin/fly-envbundle.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
# The fly stub logs every call with a checksum of the token it ran on (never the
# value), and writes a destroy into fly-pool.log too, so the order of "destroyed"
# and the pool's own "cancelled" line is a fact the log shows.
cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "\$* tok=\$(printf '%s' "\${FLY_ACCESS_TOKEN:-}" | cksum | cut -d' ' -f1)" >> "$T/fly-calls"
case "\$*" in
  *"machines list"*) cat "$T/listing.json" 2>/dev/null || echo '[]' ;;
  *"machine status"*) echo "State: started" ;;
  *"machine destroy"*) echo "FLYSTUB machine destroy \$3" >> "$H/logs/fly-pool.log" ;;
  *"ssh console"*) case "\$*" in *heartbeat*) cat "$T/heartbeat" 2>/dev/null ;; esac ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\\n' ;;
esac
exit 0
FLY
# The gh stub (the tests/pool-hold-cache.bh-6549-test.sh shape) serves from $GF:
#   listing-<page>.json  the open ai-build issue listing
#   issue-<n>.json       the issue (default: open, ai-build)
#   comments-<n>.json / comments-<n>.fail   the thread, or a failed read
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
T=@T@; GF="$T/gh"
args="$*"; inc=0
for a in "$@"; do
  case "$a" in issue) echo "$args" >> "$T/gh-sink.txt"; exit 0 ;; -i) inc=1 ;; esac
done
num() { local x="${args#*issues/}"; printf '%s' "${x%%[!0-9]*}"; }
if [[ "$args" == *"/comments"* ]] && [[ "$args" == *"body=@"* ]]; then
  echo "$args" >> "$T/gh-post.txt"; echo '{"id":1}'; exit 0
fi
if [[ "$args" == *"--paginate"* ]] && [[ "$args" == *"issues/"*"/comments"* ]]; then
  n=$(num); echo "$n" >> "$T/comment-reads.log"
  [ -e "$GF/comments-$n.fail" ] && { echo "HTTP 502: fixture failure" >&2; exit 1; }
  cat "$GF/comments-$n.json" 2>/dev/null || echo '[]'
  exit 0
fi
if [ "$inc" = 1 ]; then
  if [[ "$args" == *"issues?state=open"* ]]; then
    echo "$args" >> "$T/listing-reads.log"
    page="${args##*&page=}"; page="${page%%[!0-9]*}"
    printf 'HTTP/1.1 200 Fixture\n\n'
    cat "$GF/listing-$page.json" 2>/dev/null || echo '[]'
    exit 0
  fi
  if [[ "$args" == *"repos/example-org/tproj" ]] || [[ "$args" == *"repos/example-org/tproj "* ]]; then
    printf 'HTTP/1.1 200 OK\n\n{"full_name":"example-org/tproj"}\n'; exit 0
  fi
  if [[ "$args" == *"pulls?state=open"* ]]; then printf 'HTTP/1.1 200 OK\n\n[]\n'; exit 0; fi
  printf 'HTTP/1.1 404 Not Found\n\n{}\n'; exit 0
fi
if [[ "$args" == *"repos/example-org/tproj/issues/"* ]]; then
  n=$(num); echo "$n" >> "$T/issue-reads.log"
  cat "$GF/issue-$n.json" 2>/dev/null \
    || echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"fixture ticket","body":"fixture body"}'
  exit 0
fi
exit 0
GH
sed -i "s#@T@#$T#" "$T/fakebin/gh"
chmod +x "$H/bin"/*.sh "$T/fakebin"/*

NOW=$(date +%s)   # ONE clock read for the real-script sections
FRESH=$(date -u -d "@$((NOW - 60))" +%Y-%m-%dT%H:%M:%SZ)
LIVE_ROW="{\"id\":\"m4smoke\",\"state\":\"started\",\"updated_at\":\"$FRESH\"}"
listing() { printf '%s\n' "$1" > "$T/listing.json"; }
reset() {
  local p
  for p in "$QD"/* "$MD"/* "$MD"/.sweep.json "$GF"/* "$H/state/pool/tproj"/* "$H/state/pool-stall" \
           "$T/fly-calls" "$T/alert-calls" "$T/qrow.log" "$T/heartbeat" "$T/listing.json" \
           "$T/comment-reads.log" "$T/issue-reads.log" "$T/listing-reads.log" "$T/gh-post.txt" "$T/gh-sink.txt"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  for p in "$H/flags"/alerted-*; do [ -e "$p" ] && scratch_rm "$p"; done
  : > "$H/logs/fly-pool.log"; : > "$H/logs/ALERTS.log"
  printf '3\n' > "$H/flags/fly-pool-tproj"
  printf '{"app":"pool-tproj"}\n' > "$H/state/fly/tproj.json"
  return 0
}
# tick [VAR=value ...] — one real pool tick. No token is set unless named.
tick() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 )
}
tokhash() { printf '%s' "$1" | cksum | cut -d' ' -f1; }
nlines() { grep -c "$1" "$2" 2>/dev/null || true; }
job() { # job <mid> <key> <ticket> [deaths] [deferrals] [attempt]
  jq -nc --arg m "$1" --arg k "$2" --arg t "$3" --argjson x "${4:-0}" --argjson d "${5:-0}" --argjson a "${6:-0}" \
    '{machine:$m,key:$k,ticket_id:$t,attempt:$a,deferrals:$d,deaths:$x}' > "$MD/$1.json"
}
queue() { jq -nc --arg k "$1" --arg t "$2" '{ticket_id:$t,key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-16T10:00:00Z"}' > "$QD/$1.json"; }

# ════ Section R: the token order and the no-token path ═════════════════════
# R1 the org token alone reaps an orphan (the REPRO).
reset
job m9gone OJ-1 77
listing "[$LIVE_ROW]"
tick FLY_API_TOKEN=tok-fixture-org POOL_SPAWN=0
[ -f "$QD/OJ-1.json" ] && ok || bad "R1: with only FLY_API_TOKEN the orphan must be requeued (queue: $(ls "$QD"))"
[ "$(jq -r '.deaths' "$QD/OJ-1.json" 2>/dev/null)" = 1 ] && ok || bad "R1: the requeue carries deaths=1: $(cat "$QD/OJ-1.json" 2>/dev/null)"
[ -f "$MD/m9gone.json" ] && bad "R1: the orphan's job file must go" || ok
grep -q 'using the org FLY_API_TOKEN: FLY_API_TOKEN_TPROJ is not set' "$H/logs/fly-pool.log" && ok \
  || bad "R1: the tick must say it used the org token: $(head -c 600 "$H/logs/fly-pool.log")"
grep -q "machines list.* tok=$(tokhash tok-fixture-org)\$" "$T/fly-calls" 2>/dev/null && ok \
  || bad "R1: flyctl must run on the org token: $(head -n 3 "$T/fly-calls" 2>/dev/null)"

# R2 the project token wins over the org token.
reset
job m9gone OJ-1 77
listing "[$LIVE_ROW]"
tick FLY_API_TOKEN=tok-fixture-org FLY_API_TOKEN_TPROJ=tok-fixture-proj POOL_SPAWN=0
grep -q "machines list.* tok=$(tokhash tok-fixture-proj)\$" "$T/fly-calls" 2>/dev/null && ok \
  || bad "R2: flyctl must run on the project token: $(head -n 3 "$T/fly-calls" 2>/dev/null)"
grep -q "tok=$(tokhash tok-fixture-org)\$" "$T/fly-calls" 2>/dev/null && bad "R2: the org token must not be used when the project token is set" || ok
grep -q 'using the org FLY_API_TOKEN' "$H/logs/fly-pool.log" && bad "R2: no org-token line when the project token is set" || ok

# R3 an exported FLY_ACCESS_TOKEN alone does not authenticate this pool.
reset
job m9gone OJ-1 77
listing "[$LIVE_ROW]"
tick FLY_ACCESS_TOKEN=tok-fixture-other POOL_SPAWN=0
[ -s "$T/fly-calls" ] && bad "R3: FLY_ACCESS_TOKEN alone must make no fly call: $(cat "$T/fly-calls")" || ok
[ -f "$MD/m9gone.json" ] && ok || bad "R3: nothing is reaped without a token"

# R4 no token, app set, queued 2, the stall 31 min old: one alert names it.
reset
job m9gone OJ-1 77
queue BH-1 1; queue BH-2 2
mkdir -p "$H/state/pool-stall"
jq -nc --argjson s "$((NOW - 1860))" '{since:$s,cause:"x"}' > "$H/state/pool-stall/tproj.json"
tick
[ -s "$T/fly-calls" ] && bad "R4: no token must make no fly call: $(cat "$T/fly-calls")" || ok
[ -f "$MD/m9gone.json" ] && [ -f "$QD/BH-1.json" ] && [ -f "$QD/BH-2.json" ] && ok || bad "R4: no file may be touched without a token"
[ "$(nlines 'no Fly token' "$T/alert-calls")" = 1 ] && ok || bad "R4: one alert must name the missing token: $(cat "$T/alert-calls" 2>/dev/null)"
grep -q '^\[pool/tproj\] queued 2, building unknown, for 31m: no Fly token (FLY_API_TOKEN_TPROJ or FLY_API_TOKEN)' "$T/alert-calls" 2>/dev/null && ok \
  || bad "R4: the alert text: $(cat "$T/alert-calls" 2>/dev/null)"
grep -q 'no Fly token' "$H/logs/fly-pool.log" && ok || bad "R4: the tick must say it has no token: $(cat "$H/logs/fly-pool.log")"
tick
[ "$(nlines 'no Fly token' "$T/alert-calls")" = 1 ] && ok || bad "R4: a second tick in the same hour must not page again"
# R4b no token and the stall younger than the window: the since-file starts, no page.
reset; queue BH-1 1
tick
[ -s "$T/alert-calls" ] && bad "R4b: a new stall must not page before the window: $(cat "$T/alert-calls")" || ok
[ "$(jq -r '.since' "$H/state/pool-stall/tproj.json" 2>/dev/null | tr -dc '0-9' | wc -c)" -ge 9 ] && ok \
  || bad "R4b: the first stalled tick writes the since-file: $(cat "$H/state/pool-stall/tproj.json" 2>/dev/null)"

# R5 no app: exit 0, no alert, as before.
reset
queue BH-1 1; queue BH-2 2
rm -f "$H/state/fly/tproj.json"
( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" FLY_BIN_DIR="$T/fakebin"
  bash "$DIR/bin/fly-pool.sh" tproj >/dev/null 2>&1 ); RC=$?
[ "$RC" = 0 ] && ok || bad "R5: no app must exit 0, got $RC"
[ -s "$T/alert-calls" ] && bad "R5: no app must not alert: $(cat "$T/alert-calls")" || ok
[ -e "$H/state/pool-stall/tproj.json" ] && bad "R5: no app writes no stall state" || ok

# R6 the org token reaches the heartbeat death (TK-917 / TK-809).
reset
job m5stale OJ-6 66
listing "[$LIVE_ROW,{\"id\":\"m5stale\",\"state\":\"started\",\"updated_at\":\"$FRESH\"}]"
printf '1000\n' > "$T/heartbeat"
tick FLY_API_TOKEN=tok-fixture-org POOL_SPAWN=0 POOL_INFLIGHT_HOLD_READS=0
[ -f "$QD/OJ-6.json" ] && [ ! -f "$MD/m5stale.json" ] && ok \
  || bad "R6: a 1000 s stale heartbeat must requeue (queue: $(ls "$QD"); pool: $(ls "$MD"))"

# R7 the new libs name no `rows` state path (bin/state-paths-guard.sh, CI step):
# the no-token counts come from bin/fly-pool.sh as arguments.
printf '%s\n' bin/lib/fly-token.sh bin/lib/pool-stall.sh > "$T/spg-files"
SPG_OUT=$(cd "$DIR" && SPG_FILES="$T/spg-files" bash bin/state-paths-guard.sh 2>&1); RC=$?
[ "$RC" = 0 ] && ok || bad "R7: the state-paths guard must pass the new libs (rc=$RC): $SPG_OUT"
grep -q 'pool-stall.sh' <<<"$SPG_OUT" && bad "R7: no guard line may name pool-stall.sh: $SPG_OUT" || ok

# ════ Section S: the stall alert through the real script ═══════════════════
# S9 cap 2, two tracked live files, an empty listing beside them (unusable),
# queued 3, the stall 31 min old: one page, "building unknown", the listing named.
reset
printf '2\n' > "$H/flags/fly-pool-tproj"
job m1a BH-11 11; job m1b BH-12 12
queue BH-21 21; queue BH-22 22; queue BH-23 23
listing '[]'
printf '5\n' > "$T/heartbeat"
mkdir -p "$H/state/pool-stall"
jq -nc --argjson s "$((NOW - 1860))" '{since:$s,cause:"x"}' > "$H/state/pool-stall/tproj.json"
tick FLY_API_TOKEN_TPROJ=tok-fixture-proj POOL_INFLIGHT_HOLD_READS=0
[ "$(nlines 'queued 3' "$T/alert-calls")" = 1 ] && ok || bad "S9: exactly one stall page: $(cat "$T/alert-calls" 2>/dev/null)"
grep -q '^\[pool/tproj\] queued 3, building unknown, for 31m: machines list unusable (empty-with-tracked): cannot tell if the 2 held slots are building' "$T/alert-calls" 2>/dev/null && ok \
  || bad "S9: the page text: $(grep 'queued 3' "$T/alert-calls" 2>/dev/null)"
grep -q 'stall: queued 3, building unknown' "$H/logs/fly-pool.log" && ok || bad "S9: the tick says it is stalled"
[ "$(jq -r '.since' "$H/state/pool-stall/tproj.json" 2>/dev/null)" = "$((NOW - 1860))" ] && ok \
  || bad "S9: the since stays while stalled: $(cat "$H/state/pool-stall/tproj.json" 2>/dev/null)"
tick FLY_API_TOKEN_TPROJ=tok-fixture-proj POOL_INFLIGHT_HOLD_READS=0
[ "$(nlines 'queued 3' "$T/alert-calls")" = 1 ] && ok || bad "S9: a second tick in the same hour adds no page"
[ "$(nlines 'stall: queued 3' "$H/logs/fly-pool.log")" = 2 ] && ok || bad "S9: one say line every stalled tick"
# S10 a clear tick removes the since-file.
rm -f "$QD"/BH-2*.json
tick FLY_API_TOKEN_TPROJ=tok-fixture-proj POOL_INFLIGHT_HOLD_READS=0
[ -e "$H/state/pool-stall/tproj.json" ] && bad "S10: a clear tick must remove the since-file" || ok
# S11 free budget with queued rows (held rows that skip) is not a stall.
reset
queue BH-31 31
jq -nc --argjson s "$((NOW - 7200))" '{since:$s,cause:"x"}' > "$T/since.json"
mkdir -p "$H/state/pool-stall"; cp "$T/since.json" "$H/state/pool-stall/tproj.json"
listing "[$LIVE_ROW]"
printf '%s\n' '[{"id":101,"created_at":"2026-10-16T09:00:00Z","body":"HOLD — do not build","user":{"login":"fixture-person","type":"User"}}]' > "$GF/comments-31.json"
tick FLY_API_TOKEN_TPROJ=tok-fixture-proj
[ -s "$T/alert-calls" ] && grep -q 'queued' "$T/alert-calls" && bad "S11: free slots with held rows must not page: $(cat "$T/alert-calls")" || ok
[ -e "$H/state/pool-stall/tproj.json" ] && bad "S11: free budget is a clear tick" || ok

# S12 the hourly dedupe flag ends in the 8-digit date, so bin/alerts-groom.sh
# prunes an old one and keeps today's (the flag retention rule).
reset
queue BH-41 41; queue BH-42 42
mkdir -p "$H/state/pool-stall"
jq -nc --argjson s "$((NOW - 1860))" '{since:$s,cause:"x"}' > "$H/state/pool-stall/tproj.json"
tick; tick
[ "$(nlines 'no Fly token' "$T/alert-calls")" = 1 ] && ok || bad "S12: two stalled ticks in one hour give one page: $(cat "$T/alert-calls" 2>/dev/null)"
S12F=$(cd "$H/flags" && ls alerted-pool-stall-tproj-* 2>/dev/null)
[[ "$S12F" =~ ^alerted-pool-stall-tproj-h[0-2][0-9]-[0-9]{8}$ ]] && ok || bad "S12: the flag name is ...-h<HH>-<YYYYmmdd>: '$S12F'"
S12OLD="alerted-pool-stall-tproj-h05-$(date -u -d '-30 days' +%Y%m%d)"
: > "$H/flags/$S12OLD"
env -u ALERT_FLAG_RETENTION_DAYS -u CONSOLE_URL -u HARNESS_SECRET -u HARNESS_ENV_DIR \
  HARNESS="$H" bash "$DIR/bin/alerts-groom.sh" >/dev/null 2>&1
[ -e "$H/flags/$S12OLD" ] && bad "S12: the groom must remove a 30-day-old stall flag" || ok
[ -n "$S12F" ] && [ -e "$H/flags/$S12F" ] && ok || bad "S12: the groom must keep today's stall flag '$S12F'"

# ════ Section H: the in-flight HOLD cancel ═════════════════════════════════
HOLD_THREAD='[{"id":101,"created_at":"2026-10-16T14:00:00Z","body":"HOLD — do not build","user":{"login":"fixture-person","type":"User"}}]'
live_job() { # live_job <mid> <key> <ticket> [deaths] [deferrals] [attempt] — a started, beating machine
  job "$@"
  listing "[$LIVE_ROW,{\"id\":\"$1\",\"state\":\"started\",\"updated_at\":\"$FRESH\"}]"
  printf '5\n' > "$T/heartbeat"
}
in_listing() { # in_listing <n> <updated_at> <comments>
  jq -nc --argjson n "$1" --arg u "$2" --argjson c "$3" '[{number:$n,updated_at:$u,comments:$c,state:"open"}]' > "$GF/listing-1.json"
}
age_seen() { # age_seen <mid> <seconds> — move the recorded first-seen back
  local s
  [ -f "$MD/$1.json" ] || return 0
  s=$(jq -r '.inflight_hold.seen_at // empty' "$MD/$1.json" 2>/dev/null)
  case "$s" in ''|*[!0-9]*) return 0 ;; esac
  jq -c --argjson s "$((s - $2))" '.inflight_hold.seen_at = $s' "$MD/$1.json" > "$MD/$1.json.t" \
    && mv "$MD/$1.json.t" "$MD/$1.json"
}
htick() { tick FLY_API_TOKEN_TPROJ=tok-fixture-proj POOL_SPAWN=0 "$@"; }

# H13 a closed issue: first tick records it and keeps the machine; 11 min later
# the machine is destroyed, the file goes, the row is failed, nothing requeued.
reset
live_job m1live BH-3001 3001
echo '[]' > "$GF/listing-1.json"
echo '{"state":"closed","labels":[{"name":"ai-build"}],"title":"fixture ticket","body":"fixture body"}' > "$GF/issue-3001.json"
htick
[ -f "$MD/m1live.json" ] && ok || bad "H13: the first closed read must not cancel (grace)"
[ "$(jq -r '.inflight_hold.verdict' "$MD/m1live.json" 2>/dev/null)" = "held${TAB}closed" ] && ok \
  || bad "H13: the verdict rides the machine json: $(cat "$MD/m1live.json" 2>/dev/null)"
grep -q 'in-flight BH-3001 on m1live: ticket 3001 closed — cancel after 600s' "$H/logs/fly-pool.log" && ok || bad "H13: the grace line: $(grep in-flight "$H/logs/fly-pool.log")"
age_seen m1live 660
htick
grep -q 'machine destroy m1live' "$T/fly-calls" 2>/dev/null && ok || bad "H13: the machine must be destroyed: $(cat "$T/fly-calls" 2>/dev/null)"
[ -f "$MD/m1live.json" ] && bad "H13: the job file must go" || ok
grep -q "^done tproj BH-3001 failed ticket 3001 is closed — in-flight build cancelled, pool slot released" "$T/qrow.log" 2>/dev/null && ok \
  || bad "H13: the row must be failed with the reason: $(cat "$T/qrow.log" 2>/dev/null)"
grep -q '^put ' "$T/qrow.log" 2>/dev/null && bad "H13: a closed ticket is not requeued" || ok
[ -f "$QD/BH-3001.json" ] && bad "H13: no queue file for a closed ticket" || ok
DL=$(grep -n 'FLYSTUB machine destroy m1live' "$H/logs/fly-pool.log" | head -1 | cut -d: -f1)
CL=$(grep -n 'cancelled in-flight BH-3001 on m1live: ticket 3001 closed' "$H/logs/fly-pool.log" | head -1 | cut -d: -f1)
[ -n "$DL" ] && [ -n "$CL" ] && [ "$DL" -lt "$CL" ] && ok || bad "H13: the destroy must come before the cancelled line (destroy@${DL:-none} said@${CL:-none})"

# H14 a HOLD comment: 11 min after the first read the build is cancelled and
# requeued with deaths, deferrals and attempt unchanged.
reset
live_job m2live BH-3002 3002 1 2 3
in_listing 3002 2026-10-16T14:00:00Z 1
printf '%s\n' "$HOLD_THREAD" > "$GF/comments-3002.json"
htick
[ -f "$MD/m2live.json" ] && ok || bad "H15: a HOLD seen just now must keep the machine"
grep -q 'machine destroy' "$T/fly-calls" 2>/dev/null && bad "H15: no destroy inside the grace" || ok
age_seen m2live 660
htick
[ -f "$MD/m2live.json" ] && bad "H14: the held build's job file must go" || ok
grep -q 'machine destroy m2live' "$T/fly-calls" 2>/dev/null && ok || bad "H14: the held machine must be destroyed"
[ "$(jq -r '[.deaths,.deferrals,.attempt,.ticket_id]|map(tostring)|join(" ")' "$QD/BH-3002.json" 2>/dev/null)" = "1 2 3 3002" ] && ok \
  || bad "H14: the queue file keeps deaths/deferrals/attempt: $(cat "$QD/BH-3002.json" 2>/dev/null)"
grep -q '^put tproj BH-3002 3002 fly 3 ' "$T/qrow.log" 2>/dev/null && ok || bad "H14: the row is requeued: $(cat "$T/qrow.log" 2>/dev/null)"
grep -q "in-flight build cancelled, pool slot released" "$T/qrow.log" 2>/dev/null && ok || bad "H14: the requeue reason names the cancel"

# H15b a HOLD whose first sight was 2 min ago is still inside the grace.
reset
live_job m3live BH-3003 3003
in_listing 3003 2026-10-16T14:00:00Z 1
printf '%s\n' "$HOLD_THREAD" > "$GF/comments-3003.json"
htick; age_seen m3live 120; htick
[ -f "$MD/m3live.json" ] && ok || bad "H15b: a HOLD seen 2 min ago must keep the machine"
# The listing key did not change and the cache holds the verdict: the second tick reads no thread.
[ "$(grep -cx 3003 "$T/comment-reads.log" 2>/dev/null)" = 1 ] && ok || bad "H15b: an unchanged key reads the thread once, read $(grep -cx 3003 "$T/comment-reads.log" 2>/dev/null)"

# H16 label-absent is kept, whatever its age.
reset
live_job m4live BH-3004 3004
echo '[]' > "$GF/listing-1.json"
echo '{"state":"open","labels":[],"title":"fixture ticket","body":"fixture body"}' > "$GF/issue-3004.json"
htick
jq -c --argjson s "$((NOW - 3600))" '.inflight_hold.seen_at = $s' "$MD/m4live.json" > "$MD/m4live.json.t" && mv "$MD/m4live.json.t" "$MD/m4live.json"
htick
[ -f "$MD/m4live.json" ] && ok || bad "H16: label-absent must not cancel"
grep -q 'machine destroy' "$T/fly-calls" 2>/dev/null && bad "H16: label-absent must not destroy" || ok
[ "$(grep -cx 3004 "$T/issue-reads.log" 2>/dev/null)" = 1 ] && ok || bad "H16: a still-absent issue is read once, read $(grep -cx 3004 "$T/issue-reads.log" 2>/dev/null)"

# H17 POOL_INFLIGHT_HOLD_READS=0: no hold read at all, as today.
reset
live_job m5live BH-3005 3005
echo '[]' > "$GF/listing-1.json"
echo '{"state":"closed","labels":[{"name":"ai-build"}],"title":"fixture ticket","body":"fixture body"}' > "$GF/issue-3005.json"
jq -c --argjson s "$((NOW - 3600))" '.inflight_hold = {ticket:"3005",key:"absent",verdict:"held\tclosed",seen_at:$s}' "$MD/m5live.json" > "$MD/m5live.json.t" && mv "$MD/m5live.json.t" "$MD/m5live.json"
htick POOL_INFLIGHT_HOLD_READS=0
[ -f "$MD/m5live.json" ] && ok || bad "H17: off must not cancel"
[ -s "$T/issue-reads.log" ] || [ -s "$T/listing-reads.log" ] || [ -s "$T/comment-reads.log" ] && bad "H17: off must read nothing" || ok

# H18 an unreadable read never cancels, even over an old held record.
reset
live_job m6live BH-3006 3006
in_listing 3006 2026-10-16T15:00:00Z 2
: > "$GF/comments-3006.fail"
jq -c --argjson s "$((NOW - 3600))" '.inflight_hold = {ticket:"3006",key:"2026-10-16T14:00:00Z|1",verdict:"held\thold:comment x HOLD",seen_at:$s}' "$MD/m6live.json" > "$MD/m6live.json.t" && mv "$MD/m6live.json.t" "$MD/m6live.json"
htick
[ -f "$MD/m6live.json" ] && ok || bad "H18: an unreadable read must not cancel"
[ -s "$T/qrow.log" ] && bad "H18: no QROW call on an unreadable read: $(cat "$T/qrow.log")" || ok
grep -q 'in-flight hold read for BH-3006 unreadable' "$H/logs/fly-pool.log" && ok || bad "H18: the tick says the read did not answer"

# H19 a held record for a DIFFERENT ticket (a reused machine json) is ignored.
reset
live_job m7live BH-3007 3007
in_listing 3007 2026-10-16T14:00:00Z 0
jq -c --argjson s "$((NOW - 3600))" '.inflight_hold = {ticket:"9999",key:"absent",verdict:"held\tclosed",seen_at:$s}' "$MD/m7live.json" > "$MD/m7live.json.t" && mv "$MD/m7live.json.t" "$MD/m7live.json"
htick
[ -f "$MD/m7live.json" ] && ok || bad "H19: another ticket's record must not cancel this build"
grep -q 'machine destroy' "$T/fly-calls" 2>/dev/null && bad "H19: no destroy" || ok

# H20 lower-case "hold" in harness prose is not a HOLD.
reset
live_job m8live BH-3008 3008
in_listing 3008 2026-10-16T14:00:00Z 1
printf '%s\n' '[{"id":102,"created_at":"2026-10-16T14:00:00Z","body":"the build will hold the lock for a minute","user":{"login":"fixture-person","type":"User"}}]' > "$GF/comments-3008.json"
htick; htick
[ -f "$MD/m8live.json" ] && ok || bad "H20: lower-case prose must not cancel"
[ "$(jq -r '.inflight_hold.seen_at' "$MD/m8live.json" 2>/dev/null)" = null ] && ok || bad "H20: a clear verdict records no first-seen"

# H21 more due reads than POOL_INFLIGHT_HOLD_READS: the rest are deferred and said.
reset
for i in 1 2 3; do job "m9l$i" "BH-310$i" "310$i"; done
listing "[$LIVE_ROW,{\"id\":\"m9l1\",\"state\":\"started\"},{\"id\":\"m9l2\",\"state\":\"started\"},{\"id\":\"m9l3\",\"state\":\"started\"}]"
printf '5\n' > "$T/heartbeat"
echo '[]' > "$GF/listing-1.json"
htick POOL_INFLIGHT_HOLD_READS=2
[ "$(grep -c . "$T/issue-reads.log" 2>/dev/null)" = 2 ] && ok || bad "H21: 2 reads allowed, made $(grep -c . "$T/issue-reads.log" 2>/dev/null)"
[ "$(nlines 'in-flight hold read for BH-310[0-9] deferred: 2 of 2' "$H/logs/fly-pool.log")" = 1 ] && ok || bad "H21: the deferred read is said: $(grep deferred "$H/logs/fly-pool.log")"

# ════ Section K: the knob defaults ═════════════════════════════════════════
mkdir -p "$T/reg/catalog"
cp -r "$DIR/catalog/lanes.d" "$T/reg/catalog/"
if HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/lanes-build.sh" --root "$T/reg" --write >/dev/null 2>&1; then
  KV=$( export LANE_REGISTRY="$T/reg/catalog/lanes.json" HARNESS="$T/reg"
        . "$DIR/bin/lib/lane-gate.sh" 2>/dev/null
        printf '%s %s %s' "$(lane_knob fly-pool POOL_STALL_ALERT_S)" "$(lane_knob fly-pool POOL_INFLIGHT_HOLD_READS)" "$(lane_knob fly-pool POOL_INFLIGHT_HOLD_GRACE_S)" )
  [ "$KV" = "1800 4 600" ] && ok || bad "K1: the knob defaults must be 1800 4 600, got '$KV'"
else
  bad "K1: could not render the lane registry"
fi

echo "fly-pool-stall-reclaim (BH-7107): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
