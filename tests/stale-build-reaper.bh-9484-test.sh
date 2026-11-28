#!/bin/bash
# tests/stale-build-reaper.bh-9484-test.sh — BH-9484 (items 4 and 7 of #9406):
# bin/stale-build-reaper.sh marks a planning/executing build dead after
# STALE_REAPER_MINUTES with no queue row, no machine, no fresh job row and no
# fresh build dir; it fails closed on any unreadable evidence source; and it
# only logs (observe mode) until STALE_REAPER_ACT is exactly 1.
#
# The curl stub plays the console (stale feed, close POST) and the jobs worker
# (/api/queue, /api/machines, /api/jobs, PATCH /api/jobs/<id>). It records every
# POST and PATCH. 0 network calls. Every case uses its own ticket keys.
# Run from anywhere: tests/stale-build-reaper.bh-9484-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$T" || exit 1
mkdir -p "$T/bin/lib/jobs" "$T/env" "$T/logs" "$T/locks" "$T/state" "$T/builds" "$T/fakebin" "$T/fx"
for S in bin/stale-build-reaper.sh bin/jobs-client.sh bin/alert-line.sh; do
  scratch_install_closure "$S" "$T" >/dev/null || { echo "FAIL: scratch_install_closure $S"; exit 1; }
done
cat > "$T/fleet.conf" <<'EOF'
alpha-os Org/alpha https://a.example /api/board 2 local
beta-os Org/beta https://b.example /api/board 4 box-remote
EOF
export FLEET_CONF="$T/fleet.conf"
unset FLY_MACHINES_ROWS STALE_REAPER_ACT STALE_REAPER_MINUTES STALE_REAPER_MAX STALE_REAPER_PAGE STALE_REAPER_HTTP_TIMEOUT_S
printf 'CONSOLE_URL=http://console.invalid\nHARNESS_SECRET=fixture-secret-example\n' > "$T/env/global.env"
printf '#!/bin/bash\ntrue\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"; chmod +x "$T/fakebin/timeout"
printf '#!/bin/bash\n[ -f "%s/fx/LOCK_HELD" ] && exit 1\nexit 0\n' "$T" > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
# BH-9484 C1: the PR step's gh, refused and recorded (these bkeys have no build start, so 0 calls).
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/fx/GH.log"\nexit 1\n' "$T" > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The stub. Flag files under fx/ switch a source to "down" (curl rc 7) or to a
# full page (500 rows). Fixtures: fx/FEED.json, fx/QUEUE_<status>.json,
# fx/MACHINES.json, fx/JOBS.json.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
X=\$T_FX; MODE=""; URL=""; METHOD=GET; BODY=""; P=0
for a; do
  [ "\$P" = 1 ] && { BODY="\$a"; P=0; }
  [ "\$P" = 2 ] && { METHOD="\$a"; P=0; }
  case "\$a" in -d|--data-binary) P=1;; -X) P=2;; esac
  case "\$a" in
    *api/builds/stale*) MODE=feed; URL="\$a";;
    *api/builds/close*) MODE=close;;
    *api/queue*) MODE=queue; URL="\$a";;
    *api/machines*) MODE=machines; URL="\$a";;
    *api/jobs*) MODE=jobs; URL="\$a";;
  esac
done
case "\$MODE" in
  feed)
    printf '%s\n' "\$URL" >> \$X/FEEDQ.log
    [ -f \$X/FEED_DOWN ] && { echo '<html>502 bad gateway</html>'; exit 0; }
    cat \$X/FEED.json; exit 0 ;;
  close)
    printf '%s\n' "\$BODY" >> \$X/POSTS.jsonl
    [ -f \$X/CLOSE_REFUSE ] && { echo '{"ok":false,"error":"nope"}'; exit 0; }
    N=\$(printf '%s' "\$BODY" | jq '.closed | length')
    printf '{"ok":true,"requested":%s,"updated":%s}\n' "\$N" "\$N"; exit 0 ;;
  queue)
    [ -f \$X/QUEUE_DOWN ] && exit 7
    ST=\$(printf '%s' "\$URL" | sed -n 's/.*status=\([a-z]*\).*/\1/p')
    if [ -f \$X/QUEUE_FULL ] && [ "\$ST" = claimed ]; then
      jq -nc '{queue: [range(500) | {project:"alpha-os",ticket_key:"QF-\(.)",status:"claimed",target:"fly"}]}'
    else cat "\$X/QUEUE_\$ST.json" 2>/dev/null || echo '{"queue":[]}'; fi
    printf '\n200\n'; exit 0 ;;
  machines)
    printf '%s\n' "\${URL#*api/machines}" >> \$X/MQ.log
    [ -f \$X/MACHINES_DOWN ] && exit 7
    if [ -f \$X/MACHINES_FULL ]; then
      jq -nc '{machines: [range(500) | {machine_id:"f\(.)",project:"alpha-os",app:"pool-a",role:"pool",key:"MF-\(.)",state:"started"}]}'
    else cat \$X/MACHINES.json 2>/dev/null || echo '{"machines":[]}'; fi
    printf '\n200\n'; exit 0 ;;
  jobs)
    if [ "\$METHOD" = PATCH ]; then
      printf '%s %s\n' "\${URL##*/api/jobs/}" "\$BODY" >> \$X/PATCHES.log
      [ -f \$X/PATCH_500 ] && { printf '{"error":"boom"}\n500\n'; exit 0; }
      printf '{"ok":true}\n200\n'; exit 0
    fi
    [ -f \$X/JOBS_DOWN ] && exit 7
    if [ -f \$X/JOBS_FULL ]; then
      jq -nc '{jobs: [range(500) | {id:"jf\(.)",project:"alpha-os",kind:"build",stage:"execute",box:"hub",ticket_id:"JF-\(.)",activity_age_s:10}]}'
    else cat \$X/JOBS.json 2>/dev/null || echo '{"jobs":[]}'; fi
    printf '\n200\n'; exit 0 ;;
esac
exit 7
EOF
chmod +x "$T/fakebin/curl"

NOW=1763251200   # pinned clock (2025-11-16T00:00:00Z), passed as --now (D60)
ago() { date -u -d "@$((NOW - $1 * 60))" '+%Y-%m-%dT%H:%M:%SZ'; }   # ago <minutes> -> ISO
row() { # row <bkey> <project> <key> <stage> <updated_at>
  jq -nc --arg b "$1" --arg p "$2" --arg k "$3" --arg s "$4" --arg u "$5" \
    '{bkey:$b,project:$p,ticket_key:$k,stage:$s,updated_at:$u,pr_url:""}'; }
feed() { printf '%s\n' "$@" | jq -sc '{ok:true,count:length,builds:.}' > "$T/fx/FEED.json"; }
jobs() { printf '%s\n' "$@" | jq -sc '{jobs:.}' > "$T/fx/JOBS.json"; }
job()  { # job <id> <project> <key> <kind> <activity_age_s>
  jq -nc --arg i "$1" --arg p "$2" --arg k "$3" --arg d "$4" --argjson a "$5" \
    '{id:$i,project:$p,kind:$d,stage:"execute",box:"hub",ticket_id:$k,activity_age_s:$a}'; }
reset_fx() {
  rm -f "$T/fx/"*_DOWN "$T/fx/"*_FULL "$T/fx/CLOSE_REFUSE" "$T/fx/PATCH_500" "$T/fx/LOCK_HELD"
  rm -f "$T/fx/QUEUE_"*.json "$T/fx/MACHINES.json" "$T/fx/JOBS.json"
}
run() { # run [args] — env passes through; prints the true rc
  : > "$T/fx/POSTS.jsonl"; : > "$T/fx/PATCHES.log"; : > "$T/fx/MQ.log"; : > "$T/fx/FEEDQ.log"
  : > "$T/logs/stale-build-reaper.log"; : > "$T/logs/ALERTS.log"
  HARNESS="$T" T_FX="$T/fx" PATH="$T/fakebin:$PATH" HARNESS_SECRET=fixture-secret-example FLY_MACHINES_ROWS="${FLY_MACHINES_ROWS:-off}" \
    JOBS_URL=https://jobs.invalid JOBS_BOX=hub JOBS_RETRIES=0 \
    bash "$DIR/bin/stale-build-reaper.sh" --now "$NOW" "$@" >/dev/null 2>&1; echo $?; }
posted()   { jq -r '.closed[]?' "$T/fx/POSTS.jsonl" 2>/dev/null | sort | tr '\n' ' '; }
nposts()   { grep -c . "$T/fx/POSTS.jsonl" 2>/dev/null || true; }
npatch()   { grep -c . "$T/fx/PATCHES.log" 2>/dev/null || true; }
nalerts()  { grep -c "\[stale-build-reaper\]" "$T/logs/ALERTS.log" 2>/dev/null || true; }   # the reaper's own lines (jobs-client adds its daily outage line)
logged()   { cat "$T/logs/stale-build-reaper.log" 2>/dev/null; }
nlog()     { grep -c -- "$1" "$T/logs/stale-build-reaper.log" 2>/dev/null || true; }
LATCH="$T/state/stale-build-reaper/evidence-down"

# ---------- A1 parent acceptance, act: a 61-minute build with no machine ----------
reset_fx
feed "$(row bA1 alpha-os TK-1 executing "$(ago 61)")"
jobs "$(job j-a1 alpha-os TK-1 build 3700)"
RC=$(STALE_REAPER_ACT=1 run)
[ "$RC" = 0 ] && [ "$(posted)" = "bA1 " ] && [ "$(nposts)" = 1 ] && ok || bad "A1 one close POST with bA1 (rc=$RC posted=$(posted))"
[ "$(npatch)" = 1 ] && grep -q '^j-a1 ' "$T/fx/PATCHES.log" && grep -q '"status":"failed"' "$T/fx/PATCHES.log" \
  && grep -q 'STALE_REAPED bA1' "$T/fx/PATCHES.log" && ok || bad "A1 one PATCH status=failed of j-a1: $(cat "$T/fx/PATCHES.log")"
[ "$(nalerts)" = 1 ] && grep -q 'bA1' "$T/logs/ALERTS.log" && grep -q 'executing' "$T/logs/ALERTS.log" && ok || bad "A1 one ALERTS line naming bA1: $(cat "$T/logs/ALERTS.log")"
[ "$(nlog 'REAPED bA1')" = 1 ] && logged | grep 'REAPED bA1' | grep -q 'claim released job=j-a1' && ok || bad "A1 one REAPED line with the claim word: $(logged)"
logged | grep -q 'mode=act candidates=1 held=0 skipped=0 reaped=1 deferred=0 refused=0' && ok || bad "A1 summary line: $(logged)"
grep -q 'hours=1$' "$T/fx/FEEDQ.log" && ok || bad "A1 the feed asks for floor(60/60)=1 hour: $(cat "$T/fx/FEEDQ.log")"

# ---------- O1 parent acceptance, observe: no knob set ----------
reset_fx
feed "$(row bO1 alpha-os TK-2 executing "$(ago 61)")"
jobs "$(job j-o1 alpha-os TK-2 build 3700)"
RC=$(run)
[ "$RC" = 0 ] && [ "$(nposts)" = 0 ] && [ "$(npatch)" = 0 ] && [ "$(nalerts)" = 0 ] && ok || bad "O1 observe: 0 POSTs, 0 PATCHes, 0 alerts (rc=$RC posts=$(nposts) patches=$(npatch) alerts=$(nalerts))"
[ "$(nlog 'OBSERVE would reap bO1')" = 1 ] && [ "$(nlog 'OBSERVE')" = 1 ] && ok || bad "O1 exactly one OBSERVE line: $(logged)"
logged | grep 'OBSERVE would reap bO1' | grep -q 'project=alpha-os ticket=TK-2 stage=executing' && ok || bad "O1 the OBSERVE line names the facts: $(logged)"
logged | grep -q 'mode=observe candidates=1' && ok || bad "O1 summary names observe: $(logged)"
RC=$(STALE_REAPER_ACT=yes run)
[ "$(nposts)" = 0 ] && [ "$(npatch)" = 0 ] && [ "$(nlog 'OBSERVE would reap bO1')" = 1 ] && ok || bad "O1 ACT=yes is observe (posts=$(nposts))"
RC=$(STALE_REAPER_ACT=1 run --dry-run)
[ "$(nposts)" = 0 ] && [ "$(npatch)" = 0 ] && [ "$(nlog 'OBSERVE would reap bO1')" = 1 ] && ok || bad "O1 --dry-run with ACT=1 is observe (posts=$(nposts))"

# ---------- F1 parent acceptance, fail closed: each source down in turn ----------
reset_fx
feed "$(row bF1 alpha-os TK-3 executing "$(ago 61)")"
fail_case() { # fail_case <name> <flag-file|-> ; the flag file is set for both ticks
  local name="$1" flag="$2"
  rm -f "$LATCH"
  [ "$flag" = - ] || : > "$T/fx/$flag"
  RC=$(STALE_REAPER_ACT=1 FLY_MACHINES_ROWS=on run)
  [ "$RC" = 3 ] && [ "$(nposts)" = 0 ] && [ "$(npatch)" = 0 ] && ok || bad "F1 $name: rc 3, 0 POSTs, 0 PATCHes (rc=$RC posts=$(nposts) patches=$(npatch))"
  [ "$(nalerts)" = 1 ] && [ -f "$LATCH" ] && ok || bad "F1 $name: first tick writes 1 ALERTS line and the latch (alerts=$(nalerts)): $(cat "$T/logs/ALERTS.log")"
  RC=$(STALE_REAPER_ACT=1 FLY_MACHINES_ROWS=on run)
  [ "$RC" = 3 ] && [ "$(nalerts)" = 0 ] && [ "$(nposts)" = 0 ] && ok || bad "F1 $name: second tick writes 0 ALERTS lines (rc=$RC alerts=$(nalerts))"
  [ "$flag" = - ] || rm -f "$T/fx/$flag"
}
fail_case "feed has no .builds" FEED_DOWN
fail_case "queue read fails" QUEUE_DOWN
fail_case "queue full page" QUEUE_FULL
fail_case "machines read fails (flag on)" MACHINES_DOWN
fail_case "machines full page" MACHINES_FULL
fail_case "jobs read fails" JOBS_DOWN
fail_case "jobs full page" JOBS_FULL
mv "$T/bin/jobs-client.sh" "$T/bin/jobs-client.sh.off"
fail_case "no bin/jobs-client.sh" -
mv "$T/bin/jobs-client.sh.off" "$T/bin/jobs-client.sh"
# every source up again: the latch goes, the reap happens
: > "$LATCH"
RC=$(STALE_REAPER_ACT=1 FLY_MACHINES_ROWS=on run)
[ "$RC" = 0 ] && [ ! -f "$LATCH" ] && [ "$(posted)" = "bF1 " ] && ok || bad "F1 a complete read removes the latch and reaps (rc=$RC latch=$([ -f "$LATCH" ] && echo yes) posted=$(posted))"

# ---------- D1 decision table, reap ----------
reset_fx
feed "$(row bD1 alpha-os TK-10 planning "$(ago 61)")" \
     "$(row bD2 alpha-os TK-11 executing "$(ago 61)")" \
     "$(row bD3 alpha-os TK-12 executing "$(ago 61)")" \
     "$(row bD4 alpha-os TK-13 executing "$((NOW - 61*60))")"
jobs "$(job j-d3 alpha-os TK-12 build 4200)"
RC=$(STALE_REAPER_ACT=1 run)
[ "$RC" = 0 ] && [ "$(posted)" = "bD1 bD2 bD3 bD4 " ] && ok || bad "D1 planning/executing 61 min, quiet build job, epoch updated_at all reap (rc=$RC posted=$(posted))"
[ "$(npatch)" = 1 ] && grep -q '^j-d3 ' "$T/fx/PATCHES.log" && ok || bad "D1 only the stale build job is patched: $(cat "$T/fx/PATCHES.log")"
logged | grep 'REAPED bD1' | grep -q 'claim none' && ok || bad "D1 no job row: claim none: $(logged)"
[ "$(nalerts)" = 4 ] && ok || bad "D1 one alert per reaped build (alerts=$(nalerts))"

# ---------- N1 decision table, no reap ----------
reset_fx
feed "$(row bN1 alpha-os TK-20 planning "$(ago 59)")" \
     "$(row bN2 alpha-os TK-21 reviewing "$(ago 61)")" \
     "$(row bN3 alpha-os TK-22 pr_created "$(ago 61)")" \
     "$(row bN4 alpha-os TK-23 executing "$(ago 61)")" \
     "$(row bN5 alpha-os TK-24 executing "$(ago 61)")" \
     "$(row bN8 alpha-os TK-27 executing "$(ago 61)")" \
     "$(row bN9 alpha-os TK-28 executing "$(ago 61)")" \
     "$(row bN10 alpha-os TK-29 executing "not-a-time")" \
     "$(row bN15 alpha-os TK-33 executing "")" \
     "$(row bN16 alpha-os TK-34 executing "$(ago 61)")" \
     "$(row bN17 alpha-os TK-35 executing "$(ago 61)")" \
     "$(row "" alpha-os TK-30 executing "$(ago 61)")" \
     "$(row bN12 alpha-os "" executing "$(ago 61)")"
echo '{"queue":[{"project":"alpha-os","ticket_key":"TK-23","status":"claimed","target":"fly"}]}' > "$T/fx/QUEUE_claimed.json"
echo '{"queue":[{"project":"alpha-os","ticket_key":"TK-24","status":"queued","target":"fly"}]}' > "$T/fx/QUEUE_queued.json"
mkdir -p "$T/builds/alpha-os-TK-27-202611150000" "$T/builds/fly-alpha-os-TK-34-202611150000" "$T/builds/alpha-os-TK-35-2-202611150000"
jobs "$(job j-n9 alpha-os TK-28 lane 120)"
RC=$(STALE_REAPER_ACT=1 run)
# bN17 is the near miss: the dir alpha-os-TK-35-2-<ts> is key TK-35-2, not TK-35, so bN17 reaps.
[ "$RC" = 0 ] && [ "$(posted)" = "bN17 " ] && [ "$(npatch)" = 0 ] && [ "$(nalerts)" = 1 ] && ok || bad "N1 no row but the near miss bN17 may reap (rc=$RC posted=$(posted) patches=$(npatch))"
for h in 'HOLD bN4 (alpha-os TK-23)' 'HOLD bN5 (alpha-os TK-24)' 'HOLD bN8 (alpha-os TK-27)' 'HOLD bN9 (alpha-os TK-28)' 'HOLD bN16 (alpha-os TK-34)'; do
  [ "$(nlog "$h")" = 1 ] && ok || bad "N1 '$h' logged once: $(logged)"
done
logged | grep -q 'SKIP unparsable updated_at bN10' && logged | grep -q 'SKIP unparsable updated_at bN15' && ok || bad "N1 unparsable time skipped: $(logged)"
logged | grep -q 'mode=act candidates=6 held=5 skipped=4 reaped=1' && ok || bad "N1 summary counts: $(logged)"
# a live machine row (flag on) / a pool file (flag off)
reset_fx
feed "$(row bN6 alpha-os TK-25 executing "$(ago 61)")"
echo '{"machines":[{"machine_id":"m6","project":"alpha-os","app":"pool-a","role":"pool","key":"TK-25","state":"started"}]}' > "$T/fx/MACHINES.json"
RC=$(STALE_REAPER_ACT=1 FLY_MACHINES_ROWS=on run)
[ "$RC" = 0 ] && [ "$(nposts)" = 0 ] && [ "$(nlog 'HOLD bN6')" = 1 ] && grep -qx '?live=1' "$T/fx/MQ.log" && ok || bad "N1 a live machine row holds (rc=$RC posted=$(posted)): $(logged)"
reset_fx
feed "$(row bN7 alpha-os TK-26 executing "$(ago 61)")"
mkdir -p "$T/state/fly-pool/alpha-os"; echo '{"machine":"m7","key":"TK-26"}' > "$T/state/fly-pool/alpha-os/m7.json"
RC=$(STALE_REAPER_ACT=1 FLY_MACHINES_ROWS=off run)
[ "$RC" = 0 ] && [ "$(nposts)" = 0 ] && [ "$(nlog 'HOLD bN7')" = 1 ] && [ ! -s "$T/fx/MQ.log" ] && ok || bad "N1 flag off: a pool file holds (rc=$RC posted=$(posted)): $(logged)"
rm -rf "$T/state/fly-pool"
# the threshold is a knob
reset_fx
feed "$(row bN13 alpha-os TK-31 executing "$(ago 61)")"
RC=$(STALE_REAPER_ACT=1 STALE_REAPER_MINUTES=90 run)
[ "$RC" = 0 ] && [ "$(nposts)" = 0 ] && ok || bad "N1 MINUTES=90: a 61-min row does not reap (rc=$RC posted=$(posted))"
RC=$(STALE_REAPER_ACT=1 run --minutes 90)
[ "$RC" = 0 ] && [ "$(nposts)" = 0 ] && grep -q 'hours=1$' "$T/fx/FEEDQ.log" && ok || bad "N1 --minutes 90: a 61-min row does not reap (rc=$RC posted=$(posted))"
RC=$(STALE_REAPER_ACT=1 STALE_REAPER_MINUTES=junk run)
[ "$(posted)" = "bN13 " ] && logged | grep -q 'STALE_REAPER_MINUTES' && ok || bad "N1 a junk MINUTES falls back to 60 with a log line (posted=$(posted)): $(logged)"

# a full page at a smaller STALE_REAPER_PAGE is a refusal, not a live set
reset_fx; rm -f "$LATCH"
feed "$(row bN14 alpha-os TK-32 executing "$(ago 61)")"
echo '{"queue":[{"project":"alpha-os","ticket_key":"PQ-1","status":"queued","target":"fly"},{"project":"alpha-os","ticket_key":"PQ-2","status":"queued","target":"fly"}]}' > "$T/fx/QUEUE_queued.json"
RC=$(STALE_REAPER_ACT=1 STALE_REAPER_PAGE=2 run)
[ "$RC" = 3 ] && [ "$(nposts)" = 0 ] && grep -q 'full page (2 of 2)' "$T/logs/stale-build-reaper.log" && ok || bad "N1 PAGE=2 with 2 queued rows refuses (rc=$RC posted=$(posted)): $(logged)"
rm -f "$LATCH"

# ---------- X1 near miss: the same key live in ANOTHER project still reaps ----------
reset_fx
feed "$(row bX1 alpha-os TK-40 executing "$(ago 61)")"
echo '{"queue":[{"project":"beta-os","ticket_key":"TK-40","status":"claimed","target":"fly"}]}' > "$T/fx/QUEUE_claimed.json"
jobs "$(job j-x1 beta-os TK-40 build 30)"
RC=$(STALE_REAPER_ACT=1 run)
[ "$RC" = 0 ] && [ "$(posted)" = "bX1 " ] && [ "$(npatch)" = 0 ] && ok || bad "X1 liveness matches (project, key), not the key alone (rc=$RC posted=$(posted) patches=$(npatch))"

# ---------- C1 cap ----------
reset_fx
feed "$(row bC1 alpha-os TK-50 executing "$(ago 61)")" "$(row bC2 alpha-os TK-51 executing "$(ago 61)")"
RC=$(STALE_REAPER_ACT=1 STALE_REAPER_MAX=1 run)
[ "$RC" = 0 ] && [ "$(nposts)" = 1 ] && [ "$(nlog 'DEFERRED')" = 1 ] && [ "$(nalerts)" = 1 ] && ok || bad "C1 MAX=1: 1 POST, 1 DEFERRED (posts=$(nposts)): $(logged)"
logged | grep -q 'reaped=1 deferred=1' && ok || bad "C1 summary counts the deferral: $(logged)"

# ---------- R1 refused POST ----------
reset_fx
feed "$(row bR1 alpha-os TK-60 executing "$(ago 61)")"
: > "$T/fx/CLOSE_REFUSE"
RC=$(STALE_REAPER_ACT=1 run)
[ "$(nposts)" = 1 ] && [ "$(nlog 'REFUSED bR1')" = 1 ] && [ "$(nlog 'REAPED')" = 0 ] && ok || bad "R1 a refused POST is REFUSED, never REAPED: $(logged)"
[ "$(nalerts)" = 1 ] && grep -q 'refused' "$T/logs/ALERTS.log" && ! grep -q 'bR1 ' "$T/logs/ALERTS.log" && ok || bad "R1 one refused-count alert, no per-build alert: $(cat "$T/logs/ALERTS.log")"
logged | grep -q 'reaped=0 deferred=0 refused=1' && ok || bad "R1 summary: $(logged)"

# ---------- P1 PATCH answered 500: the reap goes on ----------
reset_fx
feed "$(row bP1 alpha-os TK-70 executing "$(ago 61)")"
jobs "$(job j-p1 alpha-os TK-70 build 4000)"
: > "$T/fx/PATCH_500"
RC=$(STALE_REAPER_ACT=1 run)
[ "$RC" = 0 ] && [ "$(posted)" = "bP1 " ] && logged | grep 'REAPED bP1' | grep -q 'claim left job=j-p1 to bin/jobs-watchdog.sh' && ok || bad "P1 a failed PATCH is 'claim left' and the reap goes on: $(logged)"
grep -q 'claim left job=j-p1' "$T/logs/ALERTS.log" && ! grep -q 'claim released' "$T/logs/ALERTS.log" && ok || bad "P1 the alert carries the claim word: $(cat "$T/logs/ALERTS.log")"

# ---------- E1 exits that touch nothing ----------
reset_fx
feed "$(row bE1 alpha-os TK-80 executing "$(ago 61)")"
RC=$(STALE_REAPER_ACT=1 run --bogus)
[ "$RC" = 1 ] && [ "$(nposts)" = 0 ] && ok || bad "E1 unknown argument: rc 1 (rc=$RC)"
: > "$T/fx/LOCK_HELD"
RC=$(STALE_REAPER_ACT=1 run)
[ "$RC" = 0 ] && [ "$(nposts)" = 0 ] && ok || bad "E1 lock held: rc 0, no POST (rc=$RC)"
rm -f "$T/fx/LOCK_HELD"
mv "$T/env/global.env" "$T/env/global.env.off"
RC=$(STALE_REAPER_ACT=1 CONSOLE_URL= run)
[ "$RC" = 0 ] && [ "$(nposts)" = 0 ] && logged | grep -q 'no CONSOLE_URL' && ok || bad "E1 no console env: rc 0 (rc=$RC): $(logged)"
mv "$T/env/global.env.off" "$T/env/global.env"
feed
RC=$(STALE_REAPER_ACT=1 run)
[ "$RC" = 0 ] && [ "$(nposts)" = 0 ] && logged | grep -q '0 candidates' && ok || bad "E1 empty feed: rc 0 and a 0-candidates line (rc=$RC): $(logged)"
grep -qi 'clean' <<<"$(logged)" && bad "E1 an empty feed is never called clean: $(logged)" || ok

# ---------- H1 BH-9484 C1: no bkey above names a build start, so the PR step made 0 gh calls ----------
[ ! -s "$T/fx/GH.log" ] && ok || bad "H1 the act and observe cases made 0 gh calls: $(cat "$T/fx/GH.log")"

# ---------- G1 the state-paths guard passes the new script ----------
printf 'bin/stale-build-reaper.sh\n' > "$T/spg.txt"
GOUT=$(cd "$DIR" && SPG_FILES="$T/spg.txt" SPG_ROOT="$DIR" bin/state-paths-guard.sh 2>&1); GRC=$?
[ "$GRC" = 0 ] && ! grep -q 'STATE-PATHS-GUARD: bin/' <<<"$GOUT" && ok || bad "G1 state-paths-guard on the new script: rc=$GRC $GOUT"

echo "stale-build-reaper.bh-9484-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
