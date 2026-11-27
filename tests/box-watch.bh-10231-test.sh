#!/bin/bash
# tests/box-watch.bh-10231-test.sh — BH-10231 (C1 of BH-9889): the hub duty
# bin/box-watch.sh tick + act. A box that fails box_watch.fail_probes (3) ssh
# probes in a row is restarted through bin/box-ops.sh restart --apply, at most
# once per box per restart window, then recovered, re-probed and recorded.
#
# DRIVEN, NOT GREPPED. Every case runs the shipped script in a scratch harness
# (scratch_install_closure: the real fleet-conf.sh, lane gate, jobs client,
# orgo-lever lib). Stubbed on PATH or by seam, and the only ones a case can
# reach: ssh (answers per IP from a map file), curl (the jobs worker: records
# every request), bin/alert-line.sh (records its argv), box-ops (records its
# argv; BOX_WATCH_BOX_OPS), timeout (records its first argument, then runs the
# real one) and claude (records a call; the lane must never make one).
# No network, no real ssh, no real Orgo. Each case builds its own harness.
#   A  probe command: ssh -o BatchMode=yes root@<ip> true under timeout 15
#   B  no settings row: 2 fails = no act; the 3rd = one restart (fallback 3)
#   C  settings row box_watch.fail_probes 5: 4 fails no act, the 5th acts
#   D  window: a second act inside it = 0 more restarts (local stamp; the
#      claim answering claimed:false; a stamp 60 min old with window 120);
#      a stamp 121 min old = a restart
#   E  recovery: one ssh with dns-guard, the settings refresh +
#      lane_env_apply update-runners and tmpfs-ensure, then ONE re-probe
#   F  the record body has box, probes, restart_rc, recovery_rc, outcome,
#      back_at; a jobs worker that does not answer = row=unrecorded, never
#      row=recorded, and the restart still runs (the stamp decides)
#   G  box-ops rc 2 (refused) = exactly 1 critical box-watch-dark-<box> page,
#      outcome refused, no recovery
#   H  still dark after the restart = 1 critical page, outcome still_dark,
#      back_at null
#   I  back = 0 critical pages, 1 resolved retraction, outcome back
#   J  a bad settings row (abc, 0) = the fallback 3 plus one WARN log line
#   K  flags/lane-off-box-watch (and flags/all-off): 0 probes, 0 restarts,
#      for tick, act and lever-check
#   M  3 dark boxes in one tick = 0 restarts and exactly 1 warn
#      box-watch-mass-dark alert
#   N  the hub, a retired box, a box with no tailnet IP and this box are
#      never probed or restarted
#   O  a fleet.conf with no box to watch: 0 probes, 0 restarts, exit 0
#      (a missing one is not driven here: bin/fleet-conf.sh then falls back
#      to /root/harness/fleet.conf, which is the box's own file)
#   P  box-ops lock held (`already running`, rc 0): the boot wait and the
#      re-probe decide the outcome
#   Q  an act that passes act_timeout_s pages once (TIMED OUT)
#   R  a rc 0 probe between fails resets the counter: fail, fail, ok, fail,
#      fail = no restart
# Run: HARNESS_TEST_SANDBOX=1 bash tests/box-watch.bh-10231-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }
command -v jq >/dev/null || { echo "box-watch.bh-10231-test: SKIPPED — jq missing"; exit 0; }
command -v flock >/dev/null || { echo "box-watch.bh-10231-test: SKIPPED — flock missing"; exit 0; }
[ -f "$DIR/bin/box-watch.sh" ] || { echo "FAIL: missing bin/box-watch.sh"; exit 1; }

FB="$T/fakebin"; mkdir -p "$FB"
# curl: the jobs worker. Records "<METHOD> <PATH> <BODY>"; the claim answers
# $CLAIM_RESP; CURL_DOWN=1 = a transport failure (rc 7, no output).
cat > "$FB/curl" <<'CURL'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2;; --data-binary|-d|--data) BODY="$2"; shift 2;; *) shift;; esac
done
case "$BODY" in @-) BODY=$(cat) ;; @*) BODY=$(cat "${BODY#@}") ;; esac
P="/${URL#*://*/}"; P="${P%%\?*}"
printf '%s %s %s\n' "$METHOD" "$P" "$BODY" >> "$REQ_SINK"
[ "${CURL_DOWN:-0}" = 1 ] && exit 7
case "$P" in
  /api/box-watch/claim)
    R='{"claimed":true,"id":41,"window_min":120}'
    [ -n "${CLAIM_RESP:-}" ] && R="$CLAIM_RESP"
    printf '%s\n200\n' "$R" ;;
  /api/box-watch/actions/*) printf '{"id":41}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
CURL
# ssh: one line per call to $SSH_LOG, then the rc the map gives the IP.
cat > "$FB/ssh" <<'SSH'
#!/bin/bash
ip=""; for a in "$@"; do case "$a" in root@*) ip="${a#root@}" ;; esac; done
printf '%s %s\n' "${ip:-none}" "$*" >> "$SSH_LOG"
v=$(awk -v ip="$ip" '$1 == ip {print $2}' "$SSH_MAP")
exit "${v:-255}"
SSH
REAL_TIMEOUT=$(command -v timeout)
cat > "$FB/timeout" <<TO
#!/bin/bash
echo "\$1" >> "\$TIMEOUT_LOG"
exec "$REAL_TIMEOUT" "\$@"
TO
# box-ops: records argv; BOXOPS_RC / BOXOPS_OUT; BOXOPS_BACK=<ip> marks that
# box back in the ssh map (the restart worked); BOXOPS_SLEEP holds it.
cat > "$FB/box-ops" <<'BO'
#!/bin/bash
echo "$*" >> "$BOXOPS_LOG"
[ -n "${BOXOPS_BACK:-}" ] && { grep -v "^$BOXOPS_BACK " "$SSH_MAP" > "$SSH_MAP.n"; echo "$BOXOPS_BACK 0" >> "$SSH_MAP.n"; mv "$SSH_MAP.n" "$SSH_MAP"; }
[ -n "${BOXOPS_SLEEP:-}" ] && sleep "$BOXOPS_SLEEP"   # determinism: ok the stub holds the act past its timeout on purpose
echo "${BOXOPS_OUT:-box-ops: verb=restart box=$2 orgo=o-1 result=OK running}"
exit "${BOXOPS_RC:-0}"
BO
printf '#!/bin/bash\necho "$*" >> "$CLAUDE_LOG"\n' > "$FB/claude"
chmod +x "$FB/curl" "$FB/ssh" "$FB/timeout" "$FB/box-ops" "$FB/claude"

NOW=1795000000
HN=0
new_harness() { # -> H, a scratch harness with the lane closure and a fleet.conf
  HN=$((HN+1)); H="$T/h$HN"; C="$T/c$HN"
  mkdir -p "$H/logs" "$H/state" "$H/env" "$H/locks" "$H/flags" "$H/bin" "$C"
  local S
  for S in bin/box-watch.sh bin/fleet-conf.sh bin/jobs-client.sh bin/lib/lane-gate.sh; do
    scratch_install_closure "$S" "$H" >/dev/null || { bad "scratch_install_closure $S failed"; return 1; }
  done
  cat > "$H/bin/alert-line.sh" <<'AL'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_LOG"
AL
  chmod +x "$H/bin/alert-line.sh"
  : > "$H/env/global.env"
  cat > "$C/fleet.conf" <<'FC'
# @retired po box-old
# @boxrole box-noip noip build
pa acme/pa - - 1 box-alpha 192.0.2.11
pb acme/pb - - 1 box-bravo 192.0.2.12
pc acme/pc - - 1 box-charlie 192.0.2.13
ph acme/ph - - 1 box-hub 192.0.2.10
# @box box-old 192.0.2.14
FC
  printf '192.0.2.11 0\n192.0.2.12 0\n192.0.2.13 0\n192.0.2.10 0\n192.0.2.14 255\n' > "$C/ssh.map"
  : > "$C/req.log"; : > "$C/ssh.log"; : > "$C/timeout.log"; : > "$C/alert.log"; : > "$C/boxops.log"; : > "$C/claude.log"
}
dark() { # dark <ip> [rc] — that box fails its probes
  grep -v "^$1 " "$C/ssh.map" > "$C/ssh.map.n"; echo "$1 ${2:-255}" >> "$C/ssh.map.n"; mv "$C/ssh.map.n" "$C/ssh.map"
}
settings() { # settings <json object of values> — the settings cache the knob reader reads
  jq -nc --argjson v "$1" --argjson fa "$(date -u +%s)" '{fetched_at:$fa, values:$v, seeded:{}}' > "$H/state/settings-cache.json"
}
run() { # run <verb> [args] [-- VAR=value ...] -> RC
  local args=() envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  envs=("$@")
  env PATH="$FB:$PATH" HARNESS="$H" HARNESS_TEST_SANDBOX=1 FLEET_CONF="$C/fleet.conf" \
    HUB_BOX_NAME=box-hub HARNESS_HUB_BOX=box-hub HARNESS_BOX_PREFIX=box- \
    JOBS_URL="http://jobs.fixture.test" HARNESS_SECRET="sec-fixture-10231" JOBS_RETRIES=0 \
    LANE_GATE_DISABLE=1 LANE_GATE_CACHE_S=999999999 BOX_WATCH_NOW="$NOW" BOX_WATCH_SELF=box-self \
    BOX_WATCH_BOX_OPS="$FB/box-ops" BOX_WATCH_ACT_SYNC=1 BOX_WATCH_BOOT_WAIT_SEAM_S=0 \
    REQ_SINK="$C/req.log" SSH_LOG="$C/ssh.log" SSH_MAP="$C/ssh.map" TIMEOUT_LOG="$C/timeout.log" \
    ALERT_LOG="$C/alert.log" BOXOPS_LOG="$C/boxops.log" CLAUDE_LOG="$C/claude.log" \
    "${envs[@]+"${envs[@]}"}" bash "$H/bin/box-watch.sh" "${args[@]}" </dev/null >"$C/out" 2>&1
  RC=$?
}
n() { [ -s "$1" ] && grep -c . "$1" || echo 0; }
restarts() { n "$C/boxops.log"; }
probes_of() { grep -c "^$1 .* true\$" "$C/ssh.log"; }
crit() { grep -c -- "--severity critical --id box-watch-dark-$1 " "$C/alert.log"; }
record_body() { grep '^POST /api/box-watch/actions/' "$C/req.log" | tail -1 | cut -d' ' -f3-; }
ctx() { echo "rc=$RC out=[$(cat "$C/out")] log=[$(tail -5 "$H/logs/box-watch.log" 2>/dev/null)] boxops=[$(cat "$C/boxops.log")] alerts=[$(cat "$C/alert.log")]"; }

# ---- A probe command ----
new_harness
run tick
[ "$RC" = 0 ] && ok || bad "A rc $(ctx)"
grep -q '^192.0.2.11 .*BatchMode=yes.* root@192.0.2.11 true$' "$C/ssh.log" && ok || bad "A ssh command: $(cat "$C/ssh.log")"
[ "$(sort -u "$C/timeout.log")" = 15 ] && ok || bad "A timeout given: $(cat "$C/timeout.log")"
[ "$(probes_of 192.0.2.11)" = 1 ] && [ "$(probes_of 192.0.2.12)" = 1 ] && [ "$(probes_of 192.0.2.13)" = 1 ] && ok || bad "A each box once: $(cat "$C/ssh.log")"
[ "$(restarts)" = 0 ] && [ "$(n "$C/alert.log")" = 0 ] && ok || bad "A all up: nothing happens $(ctx)"

# ---- B no row: fallback 3 ----
new_harness; dark 192.0.2.11
run tick; run tick
[ "$(restarts)" = 0 ] && ok || bad "B 2 fails must not act $(ctx)"
[ "$(cat "$H/state/box-watch/box-alpha.fails")" = 2 ] && ok || bad "B counter 2: $(cat "$H/state/box-watch/box-alpha.fails")"
run tick
[ "$(restarts)" = 1 ] && ok || bad "B the 3rd fail acts once $(ctx)"
[ "$(cat "$C/boxops.log")" = "restart alpha --host box-alpha --apply" ] && ok || bad "B box-ops argv: $(cat "$C/boxops.log")"
grep -q '^POST /api/box-watch/claim .*"box":"box-alpha"' "$C/req.log" && ok || bad "B claim posted: $(cat "$C/req.log")"
# The claim is written BEFORE the restart: the stamp exists and holds NOW.
[ "$(cat "$H/state/box-watch/box-alpha.restart")" = "$NOW" ] && ok || bad "B stamp"
[ "$(n "$C/claude.log")" = 0 ] && ok || bad "B no model call"

# ---- C row 5 ----
new_harness; dark 192.0.2.12; settings '{"box_watch.fail_probes":"5"}'
for _ in 1 2 3 4; do run tick; done
[ "$(restarts)" = 0 ] && ok || bad "C 4 fails with row 5 must not act $(ctx)"
run tick
[ "$(restarts)" = 1 ] && grep -q '^restart bravo ' "$C/boxops.log" && ok || bad "C the 5th fail acts $(ctx)"

# ---- D window ----
new_harness; dark 192.0.2.11
for _ in 1 2 3; do run tick; done
run tick; run tick
[ "$(restarts)" = 1 ] && ok || bad "D local stamp: a second act inside the window must not restart $(ctx)"
[ "$(grep -c '^POST /api/box-watch/claim' "$C/req.log")" = 1 ] && ok || bad "D one claim only: $(cat "$C/req.log")"
grep -q 'inside restart_window_min 120; no restart' "$H/logs/box-watch.log" && ok || bad "D log line"
new_harness; dark 192.0.2.11
for _ in 1 2; do run tick; done
run tick -- 'CLAIM_RESP={"claimed":false,"id":7,"last_acted_at":"2026-11-26T13:00:00Z","window_min":120}'
[ "$(restarts)" = 0 ] && ok || bad "D claimed:false must not restart $(ctx)"
grep -q 'claim refused' "$H/logs/box-watch.log" && ok || bad "D claim refused log"
new_harness; dark 192.0.2.11; mkdir -p "$H/state/box-watch"
echo $((NOW - 3600)) > "$H/state/box-watch/box-alpha.restart"
run act box-alpha 3
[ "$(restarts)" = 0 ] && ok || bad "D a stamp 60 min old with window 120 must not restart $(ctx)"
echo $((NOW - 7260)) > "$H/state/box-watch/box-alpha.restart"
run act box-alpha 3
[ "$(restarts)" = 1 ] && ok || bad "D a stamp 121 min old restarts $(ctx)"

# ---- E recovery then one re-probe ----
new_harness; dark 192.0.2.13
for _ in 1 2; do run tick; done
: > "$C/ssh.log"
run tick -- BOXOPS_BACK=192.0.2.13
RECOV=$(grep '^192.0.2.13 ' "$C/ssh.log" | grep -v ' true$')
[ "$(grep -c . <<<"$RECOV")" = 1 ] && ok || bad "E exactly one recovery ssh: $(cat "$C/ssh.log")"
grep -q 'bin/dns-guard.sh' <<<"$RECOV" && grep -q '_lg_settings_refresh' <<<"$RECOV" \
  && grep -q 'lane_env_apply update-runners' <<<"$RECOV" && grep -q 'bin/tmpfs-ensure.sh' <<<"$RECOV" && ok || bad "E recovery steps: $RECOV"
# tick probe (dark), boot-wait probe (up), recovery, re-probe: the recovery
# line is followed by exactly one probe.
AFTER=$(awk '/^192.0.2.13 /{print}' "$C/ssh.log" | awk 'f && / true$/ {c++} !/ true$/ {f=1} END {print c+0}')
[ "$AFTER" = 1 ] && ok || bad "E one re-probe after recovery, got $AFTER: $(cat "$C/ssh.log")"

# ---- F record body; I back ----
B=$(record_body)
[ "$(jq -r '[.box, .probes, .restart_rc, .recovery_rc, .outcome] | map(tostring) | join(",")' <<<"$B")" = "box-charlie,3,0,0,back" ] && ok || bad "F record body: $B"
[[ "$(jq -r '.back_at' <<<"$B")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && ok || bad "F back_at: $B"
grep -q '^POST /api/box-watch/actions/41 ' "$C/req.log" && ok || bad "F record path uses the claim id"
grep -q 'row=recorded id=41' "$H/logs/box-watch.log" && ok || bad "F recorded log"
[ "$(crit box-charlie)" = 0 ] && ok || bad "I back = no page: $(cat "$C/alert.log")"
[ "$(grep -c -- '--severity resolved --id box-watch-dark-box-charlie ' "$C/alert.log")" = 1 ] && ok || bad "I one retraction: $(cat "$C/alert.log")"
[ "$(cat "$H/state/box-watch/box-charlie.fails")" = 0 ] && ok || bad "I counter reset on back"
# A worker that does not answer: the restart still runs, the row is unrecorded.
new_harness; dark 192.0.2.11
for _ in 1 2 3; do run tick -- CURL_DOWN=1 BOXOPS_BACK=192.0.2.11; done
[ "$(restarts)" = 1 ] && ok || bad "F worker down: the stamp decides, one restart $(ctx)"
grep -q 'row=unrecorded' "$H/logs/box-watch.log" && ok || bad "F row=unrecorded: $(cat "$H/logs/box-watch.log")"
grep -q 'row=recorded' "$H/logs/box-watch.log" && bad "F must never log row=recorded when the worker is down" || ok

# ---- G refused ----
new_harness; dark 192.0.2.11
for _ in 1 2; do run tick; done
run tick -- BOXOPS_RC=2 'BOXOPS_OUT=box-ops: verb=restart box=alpha orgo=- result=REFUSED not configured: ORGO_API_KEY unset'
[ "$(crit box-alpha)" = 1 ] && ok || bad "G exactly one critical page $(ctx)"
grep -q 'REFUSED' "$C/alert.log" && ok || bad "G the page says refused: $(cat "$C/alert.log")"
B=$(record_body)
[ "$(jq -r '.outcome, .restart_rc, .recovery_rc, .back_at' <<<"$B" | paste -sd,)" = "refused,2,null,null" ] && ok || bad "G record: $B"
[ "$(grep -c '^192.0.2.11 ' "$C/ssh.log")" = 3 ] && ok || bad "G no boot wait or recovery after a refusal: $(cat "$C/ssh.log")"

# ---- H still dark ----
new_harness; dark 192.0.2.12
for _ in 1 2 3; do run tick; done
[ "$(crit box-bravo)" = 1 ] && ok || bad "H one critical page $(ctx)"
grep -q 'still DARK' "$C/alert.log" && ok || bad "H page text"
B=$(record_body)
[ "$(jq -r '.outcome, .back_at' <<<"$B" | paste -sd,)" = "still_dark,null" ] && ok || bad "H record: $B"

# ---- J bad knob ----
for V in abc 0; do
  new_harness; dark 192.0.2.11; settings "{\"box_watch.fail_probes\":\"$V\"}"
  run tick; run tick
  [ "$(restarts)" = 0 ] && ok || bad "J[$V] 2 fails must not act $(ctx)"
  run tick
  [ "$(restarts)" = 1 ] && ok || bad "J[$V] the fallback 3 acts $(ctx)"
  W=$(grep -c "WARN knob row box_watch.fail_probes='$V'" "$H/logs/box-watch.log")
  [ "$W" -ge 1 ] && ok || bad "J[$V] WARN line: $(cat "$H/logs/box-watch.log")"
done

# ---- K kill switch ----
for FLAG in lane-off-box-watch all-off; do
  new_harness; dark 192.0.2.11; mkdir -p "$H/state/box-watch"; echo 5 > "$H/state/box-watch/box-alpha.fails"
  touch "$H/flags/$FLAG"
  run tick -- LANE_GATE_DISABLE=0 LANE_START_SPREAD_S=0
  [ "$RC" = 0 ] && [ "$(n "$C/ssh.log")" = 0 ] && [ "$(restarts)" = 0 ] && ok || bad "K[$FLAG] tick: 0 probes, 0 restarts $(ctx)"
  run act box-alpha 5 -- LANE_GATE_DISABLE=0 LANE_START_SPREAD_S=0
  [ "$(n "$C/ssh.log")" = 0 ] && [ "$(restarts)" = 0 ] && ! grep -q '/api/box-watch/' "$C/req.log" && ok || bad "K[$FLAG] act: nothing $(ctx) req=[$(cat "$C/req.log")]"
  run lever-check -- LANE_GATE_DISABLE=0 LANE_START_SPREAD_S=0
  [ "$(n "$C/alert.log")" = 0 ] && ok || bad "K[$FLAG] lever-check: no alert $(ctx)"
done

# ---- M mass dark ----
new_harness; dark 192.0.2.11; dark 192.0.2.12; dark 192.0.2.13
for _ in 1 2 3 4; do run tick; done
[ "$(restarts)" = 0 ] && ok || bad "M 3 dark boxes must restart none $(ctx)"
[ "$(grep -c -- '--severity critical' "$C/alert.log")" = 0 ] && ok || bad "M no critical page"
[ "$(grep -c -- '--severity warn --id box-watch-mass-dark ' "$C/alert.log")" -ge 1 ] && ok || bad "M warn alert $(ctx)"
[ "$(grep -- '--id' "$C/alert.log" | sed 's/.*--id \([^ ]*\).*/\1/' | sort -u)" = box-watch-mass-dark ] && ok || bad "M one alert id only: $(cat "$C/alert.log")"
# The network comes back: one retraction, then a single dark box acts normally.
dark 192.0.2.11 0; dark 192.0.2.12 0
run tick
[ "$(grep -c -- '--severity resolved --id box-watch-mass-dark ' "$C/alert.log")" = 1 ] && ok || bad "M retraction when it clears: $(cat "$C/alert.log")"
[ "$(restarts)" = 1 ] && grep -q '^restart charlie ' "$C/boxops.log" && ok || bad "M one dark box acts after it clears $(ctx)"

# ---- N skipped boxes ----
new_harness
dark 192.0.2.10; dark 192.0.2.14
# A box whose @boxrole is hub but whose name is not HUB_BOX_NAME (a standby
# promoted to hub, say): the role alone keeps it out.
printf '# @boxrole box-hubtwo hubtwo hub\n# @box box-hubtwo 192.0.2.16\n' >> "$C/fleet.conf"; dark 192.0.2.16
printf 'px acme/px - - 1 box-self 192.0.2.15\n' >> "$C/fleet.conf"; dark 192.0.2.15
for _ in 1 2 3 4; do run tick; done
[ "$(probes_of 192.0.2.10)" = 0 ] && ok || bad "N the hub is never probed"
[ "$(probes_of 192.0.2.16)" = 0 ] && ok || bad "N a role-hub box is never probed"
[ "$(probes_of 192.0.2.15)" = 0 ] && ok || bad "N this box is never probed"
grep -q 'box-noip: no tailnet IP\|skip box-noip' "$H/logs/box-watch.log" && ok || bad "N no-IP box skipped: $(cat "$H/logs/box-watch.log")"
[ "$(restarts)" = 0 ] && ok || bad "N nothing restarted $(ctx)"
run act box-hub 9
[ "$(restarts)" = 0 ] && ok || bad "N act on the hub refused $(ctx)"
run act box-self 9
[ "$(restarts)" = 0 ] && ok || bad "N act on this box refused $(ctx)"
# A retired box: only a @retired directive names it.
new_harness
for _ in 1 2 3 4; do run tick; done
run act box-old 9
[ "$(probes_of 192.0.2.14)" = 0 ] && [ "$(restarts)" = 0 ] && ok || bad "N a retired box is never probed $(ctx) ssh=[$(cat "$C/ssh.log")]"

# ---- O empty / missing roster ----
new_harness; : > "$C/fleet.conf"
run tick
[ "$RC" = 0 ] && [ "$(n "$C/ssh.log")" = 0 ] && [ "$(restarts)" = 0 ] && ok || bad "O empty fleet.conf $(ctx)"
grep -q 'nothing probed\|no box to watch' "$H/logs/box-watch.log" && ok || bad "O log line: $(cat "$H/logs/box-watch.log")"

# ---- P box-ops lock held ----
new_harness; dark 192.0.2.11
for _ in 1 2; do run tick; done
run tick -- 'BOXOPS_OUT=box-ops: alpha already running' BOXOPS_BACK=192.0.2.11
[ "$(jq -r .outcome <<<"$(record_body)")" = back ] && ok || bad "P a restart in progress, box back: outcome back $(ctx)"
grep -q 'lock held' "$H/logs/box-watch.log" && ok || bad "P log"
new_harness; dark 192.0.2.11
for _ in 1 2; do run tick; done
run tick -- 'BOXOPS_OUT=box-ops: alpha already running'
[ "$(jq -r .outcome <<<"$(record_body)")" = still_dark ] && [ "$(crit box-alpha)" = 1 ] && ok || bad "P a restart in progress, box dark: still_dark + page $(ctx)"

# ---- Q act timeout ----
new_harness; dark 192.0.2.11
run act box-alpha 3 -- BOX_WATCH_ACT_TIMEOUT_SEAM_S=1 BOXOPS_SLEEP=4
[ "$(crit box-alpha)" = 1 ] && grep -q 'TIMED OUT' "$C/alert.log" && ok || bad "Q one TIMED OUT page $(ctx)"
[ -s "$H/state/box-watch/box-alpha.restart" ] && ok || bad "Q the stamp stays"

# ---- R a rc 0 probe resets the counter ----
new_harness; dark 192.0.2.11
run tick; run tick; dark 192.0.2.11 0; run tick; dark 192.0.2.11; run tick; run tick
[ "$(restarts)" = 0 ] && ok || bad "R fail fail ok fail fail must not act $(ctx)"
[ "$(cat "$H/state/box-watch/box-alpha.fails")" = 2 ] && ok || bad "R counter 2"

echo "box-watch.bh-10231-test: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
