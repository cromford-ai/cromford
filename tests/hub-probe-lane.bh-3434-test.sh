#!/bin/bash
# tests/hub-probe-lane.bh-3434-test.sh — BH-3450 (BH-3434.3): the hub-probe
# cron lane, driven through the REAL bin/hub-probe.sh.
#
# WHAT IS STUBBED. The lane runs from a scratch harness ($H, a symlink tree of
# the repo's bin/) with bin/alert-line.sh swapped for a recorder. Through
# HUB_PROBE_FIXTURE (sandbox only) $T/fx.sh replaces, after the lane sources
# its libs: lane_gate_or_exit / lane_env_apply (no-ops), lane_switch (reads
# $T/switch_on), _jobs_req (answers per path from $T/jobs/*, records every
# call), gh_rest and gh_rest_issue_comments (answer from $T/gh/*, record every
# call), hp_run (prints $T/probe-out, sets HP_HTTP_STATUS, returns $T/probe-rc)
# and hp_on_pass (recorder). The contract verbs hp_claim / hp_result /
# hp_commented / hp_count_today are the REAL ones, over the stubbed _jobs_req.
# fleet-conf.sh is the real one over a fixture fleet.conf.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/hub-probe-lane.bh-3434-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "hub-probe-lane: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

LANE_SRC="$DIR/bin/hub-probe.sh"
[ -f "$LANE_SRC" ] || { echo "FAIL: $LANE_SRC is missing"; echo "hub-probe-lane: 0 passed, 1 failed"; exit 1; }

H="$T/h"
mkdir -p "$H"
cp -rs "$DIR/bin" "$H/bin"
rm -f "$H/bin/alert-line.sh"
printf '#!/bin/bash\necho "alert-line $*" >> "%s/alerts"\n' "$T" > "$H/bin/alert-line.sh"
chmod +x "$H/bin/alert-line.sh"
LANE="$H/bin/hub-probe.sh"

cat > "$H/fleet.conf" <<'CONF'
bp   o/r        -                 -           5  local
iap  o/iap      https://iap.test  /api/board  3  local
CONF

export HARNESS="$H" FLEET_CONF="$H/fleet.conf" FXT="$T" HUB_PROBE_FIXTURE="$T/fx.sh"
unset HUB_PROBE_TICK_CAP HUB_PROBE_DAILY_CAP 2>/dev/null || true

cat > "$T/fx.sh" <<'SH'
touch "$FXT/fixture-loaded"
lane_gate_or_exit() { :; }
lane_env_apply() { :; }
lane_switch() { echo "lane_switch $*" >> "$FXT/calls.log"; [ -e "$FXT/switch_on" ]; }
# _jobs_req <method> <path> [body]: $FXT/jobs/<name> is the answer, and
# $FXT/jobs/<name>.rc (when present) its rc. Bodies are kept one per line.
_jobs_req() {
  local name
  case "$2" in
    /api/hub-probe/claim) name=claim ;;
    /api/hub-probe/result) name=result ;;
    /api/hub-probe/commented) name=commented ;;
    /api/hub-probe/count-today*) name=count ;;
    *) name=other ;;
  esac
  echo "_jobs_req $1 $2" >> "$FXT/calls.log"
  [ -n "${3:-}" ] && printf '%s\n' "$3" >> "$FXT/body-$name"
  [ -e "$FXT/jobs/$name.rc" ] && return "$(cat "$FXT/jobs/$name.rc")"
  cat "$FXT/jobs/$name" 2>/dev/null || echo '{"ok":true}'
}
gh_rest_issue_comments() {
  echo "gh_rest_issue_comments $*" >> "$FXT/calls.log"
  local rc; rc=$(cat "$FXT/gh/thread.rc" 2>/dev/null || echo 0)
  [ "$rc" = 0 ] || return "$rc"
  cat "$FXT/gh/thread.json" 2>/dev/null || echo '[]'
}
gh_rest() {
  echo "gh_rest $1 $2" >> "$FXT/calls.log"
  local a b=""
  for a in "$@"; do case "$a" in body=@*) b=${a#body=@} ;; esac; done
  GH_REST_STATUS=$(cat "$FXT/gh/post.status" 2>/dev/null || echo 201)
  local rc; rc=$(cat "$FXT/gh/post.rc" 2>/dev/null || echo 0)
  if [ -n "$b" ]; then
    n=$(ls "$FXT"/posted.* 2>/dev/null | wc -l)
    cp "$b" "$FXT/posted.$((n + 1))"
    # A 2xx lands on the thread, so the next read sees it.
    [ "$rc" = 0 ] && jq -Rs --slurpfile t <(cat "$FXT/gh/thread.json" 2>/dev/null || echo '[]') \
      '$t[0] + [{body: .}]' < "$b" > "$FXT/gh/thread.next" && mv "$FXT/gh/thread.next" "$FXT/gh/thread.json"
  fi
  [ "$rc" = 0 ] || return "$rc"
  echo '{"id":1}'
}
hp_run() {
  echo "hp_run $*" >> "$FXT/calls.log"
  cat "$FXT/probe-out" 2>/dev/null
  HP_HTTP_STATUS=$(cat "$FXT/probe-status" 2>/dev/null)
  return "$(cat "$FXT/probe-rc" 2>/dev/null || echo 0)"
}
hp_on_pass() { echo "$*" >> "$FXT/onpass"; return "$(cat "$FXT/onpass.rc" 2>/dev/null || echo 0)"; }
SH

# reset: a fresh tick world. Row id 7, project bp, ticket BH-12, a PASS.
reset() {
  rm -rf "$T/jobs" "$T/gh" "$T/calls.log" "$T"/body-* "$T"/posted.* "$T/onpass" "$T/onpass.rc" \
    "$T/probe-out" "$T/probe-status" "$T/probe-rc" "$T/switch_on" "$T/alerts" "$T/fixture-loaded" \
    "$H/state" "$H/logs" "$H/locks"
  mkdir -p "$T/jobs" "$T/gh"
  row 7 bp BH-12
  echo '{"count":0}' > "$T/jobs/count"
  echo 'probe says ok' > "$T/probe-out"; echo 0 > "$T/probe-rc"; echo 200 > "$T/probe-status"
}
row() { # row <id> <project> <ticket_key> — the claim answers that one row
  jq -nc --argjson i "$1" --arg p "$2" --arg k "$3" \
    '{rows:[{id:$i, project:$p, ticket_key:$k, probe:"app-status-write",
      args:["o/r","0123456789abcdef0123456789abcdef01234567"]}]}' > "$T/jobs/claim"
}
tick() { HARNESS_TEST_SANDBOX=1 bash "$LANE"; echo $? > "$T/tick.rc"; }
cnt() { local n; n=$(grep -c -- "$1" "$T/calls.log" 2>/dev/null); printf '%s' "${n:-0}"; }
posts() { ls "$T"/posted.* 2>/dev/null | wc -l | tr -d ' '; }
summary() { tail -1 "$H/logs/hub-probe.log" 2>/dev/null; }

# ── K1: the kill switch stops the tick before any claim or GitHub call ──────
reset; touch "$T/switch_on"; tick
check "K1 rc 0" '[ "$(cat "$T/tick.rc")" = 0 ]'
check "K1 no /claim" '[ "$(cnt /api/hub-probe/claim)" = 0 ]'
check "K1 no gh_rest" '[ "$(cnt "^gh_rest")" = 0 ]'
check "K1 summary ends off" 'summary | grep -q " off$"'

# ── K2: the fixture seam is ignored outside the sandbox ──────────────────────
reset; env -u HARNESS_TEST_SANDBOX bash "$LANE" >/dev/null 2>&1
check "K2 fixture not sourced without HARNESS_TEST_SANDBOX" '[ ! -e "$T/fixture-loaded" ]'

# ── C1: the same row over two ticks gives exactly one POST ───────────────────
reset; tick
check "C1 tick 1 posts once" '[ "$(posts)" = 1 ]'
check "C1 tick 1 stamps /commented" '[ "$(cnt /api/hub-probe/commented)" = 1 ]'
check "C1 spool drained" '[ ! -e "$H/state/hub-probe/owed/7.json" ]'
check "C1 one summary line" '[ "$(wc -l < "$H/logs/hub-probe.log")" = 1 ]'
check "C1 summary counts" 'summary | grep -q "claimed=1 ran=1 pass=1 fail=0 rejected=0 deferred=0 commented=1 healed=0"'
tick
check "C1 tick 2 posts nothing more" '[ "$(posts)" = 1 ]'
check "C1 tick 2 heals from the marker" '[ "$(cnt /api/hub-probe/commented)" = 2 ] && summary | grep -q "healed=1"'
check "C1 two summary lines" '[ "$(wc -l < "$H/logs/hub-probe.log")" = 2 ]'

# ── C2: crash window, the marker is on the thread and the spool still owes ───
reset; echo '{"rows":[]}' > "$T/jobs/claim"
mkdir -p "$H/state/hub-probe/owed"
jq -nc '{id:7, project:"bp", ticket_key:"BH-12", probe:"app-status-write", verdict:"pass", http_status:"200"}' \
  > "$H/state/hub-probe/owed/7.json"
echo out > "$H/state/hub-probe/owed/7.out"
echo '[{"body":"## Hub probe app-status-write: PASS\n<!-- hub-probe:7 -->"}]' > "$T/gh/thread.json"
tick
check "C2 no POST" '[ "$(posts)" = 0 ] && [ "$(cnt "^gh_rest POST")" = 0 ]'
check "C2 one /commented" '[ "$(cnt /api/hub-probe/commented)" = 1 ]'
check "C2 /commented names id 7" 'grep -q "\"id\":7" "$T/body-commented"'
check "C2 spool gone" '[ ! -e "$H/state/hub-probe/owed/7.json" ] && [ ! -e "$H/state/hub-probe/owed/7.out" ]'
# C2b: a marker for a different id does not count as delivered.
reset; echo '{"rows":[]}' > "$T/jobs/claim"
mkdir -p "$H/state/hub-probe/owed"
jq -nc '{id:7, project:"bp", ticket_key:"BH-12", probe:"app-status-write", verdict:"pass", http_status:""}' \
  > "$H/state/hub-probe/owed/7.json"
echo out > "$H/state/hub-probe/owed/7.out"
echo '[{"body":"<!-- hub-probe:17 -->"},{"body":"see hub-probe:7 here"}]' > "$T/gh/thread.json"
tick
check "C2b other id's marker: one POST for id 7" '[ "$(posts)" = 1 ] && grep -qx "<!-- hub-probe:7 -->" "$T/posted.1"'

# ── C3: a 5xx on the post leaves commented_at NULL; the next tick retries ────
reset; echo 75 > "$T/gh/post.rc"; echo 502 > "$T/gh/post.status"; tick
check "C3 tick 1 no /commented" '[ "$(cnt /api/hub-probe/commented)" = 0 ]'
check "C3 tick 1 spool kept" '[ -e "$H/state/hub-probe/owed/7.json" ] && [ -e "$H/state/hub-probe/owed/7.out" ]'
check "C3 tick 1 counts post-failed" 'summary | grep -q "post-failed=1"'
rm -f "$T/gh/post.rc" "$T/gh/post.status" "$T"/posted.*; echo '{"rows":[]}' > "$T/jobs/claim"; tick
check "C3 tick 2 posts once" '[ "$(posts)" = 1 ]'
check "C3 tick 2 one /commented" '[ "$(cnt /api/hub-probe/commented)" = 1 ]'
check "C3 tick 2 spool gone" '[ ! -e "$H/state/hub-probe/owed/7.json" ]'

# ── C4: a FAIL body, output capped at 4096 bytes ─────────────────────────────
reset; head -c 10240 /dev/zero | tr '\0' 'x' > "$T/probe-out"; echo 403 > "$T/probe-status"; echo 1 > "$T/probe-rc"
tick
check "C4 /result is fail with http_status 403" 'jq -e "select(.id==7) | .result==\"fail\" and .http_status==403" "$T/body-result" >/dev/null'
check "C4 stored output <= 4096 bytes" '[ "$(jq -r "select(.id==7) | .output | utf8bytelength" "$T/body-result")" -le 4096 ]'
check "C4 body starts with the FAIL header" '[ "$(head -1 "$T/posted.1")" = "## Hub probe app-status-write: FAIL" ]'
check "C4 body carries HTTP 403" 'grep -q "HTTP 403" "$T/posted.1"'
check "C4 body ends with the marker" '[ "$(tail -1 "$T/posted.1")" = "<!-- hub-probe:7 -->" ]'
# C4b: output cannot close the fence or forge a marker.
reset; printf 'a\n```\nb <!-- hub-probe:9 -->\n' > "$T/probe-out"; tick
check "C4b exactly one marker line" '[ "$(grep -c "<!-- hub-probe:" "$T/posted.1")" = 1 ]'
check "C4b exactly one fence pair" '[ "$(grep -c "^\`\`\`" "$T/posted.1")" = 2 ]'

# ── C5: an in-app-board project never posts ──────────────────────────────────
reset; row 7 iap TK-3; tick
check "C5 no gh calls" '[ "$(cnt "^gh_rest")" = 0 ]'
check "C5 not-configured=1" 'summary | grep -q "not-configured=1"'
check "C5 no /commented" '[ "$(cnt /api/hub-probe/commented)" = 0 ]'
check "C5 logs not-configured: comment" 'grep -q "not-configured: comment" "$H/logs/hub-probe.log"'
check "C5 result still stored" 'jq -e "select(.id==7) | .result==\"pass\"" "$T/body-result" >/dev/null'

# ── C6: the daily cap defers the row to pending, never fails it ──────────────
reset; echo '{"count":20}' > "$T/jobs/count"; tick
check "C6 one /result" '[ "$(cnt /api/hub-probe/result)" = 1 ]'
check "C6 pending with the note" 'jq -e ".result==\"pending\" and .note==\"deferred: daily cap\" and .id==7" "$T/body-result" >/dev/null'
check "C6 probe not run" '[ "$(cnt "^hp_run")" = 0 ]'
check "C6 no POST" '[ "$(posts)" = 0 ]'
check "C6 deferred=1" 'summary | grep -q "deferred=1"'
# C6b: an unreadable count defers too (unknown is never zero).
reset; echo 1 > "$T/jobs/count.rc"; tick
check "C6b deferred, not run" '[ "$(cnt "^hp_run")" = 0 ] && jq -e ".result==\"pending\" and (.note|startswith(\"deferred:\"))" "$T/body-result" >/dev/null'
# C6c: a cap of 25 with count 20 runs.
reset; echo '{"count":20}' > "$T/jobs/count"; HUB_PROBE_DAILY_CAP=25 tick
check "C6c under the cap runs" '[ "$(cnt "^hp_run")" = 1 ]'
# C6d (BH-8744): ready-facts is in HP_UNCAPPED_PROBES. At the cap it still runs
# and is stored as a finished row, so it never stays the oldest pending row and
# never blocks a newer row of another probe. The capped probe in the same claim
# still defers.
reset; echo '{"count":20}' > "$T/jobs/count"
jq -nc '{rows:[{id:8, project:"bp", ticket_key:"BH-12", probe:"ready-facts", args:["bp"]},
  {id:9, project:"bp", ticket_key:"BH-12", probe:"app-status-write",
   args:["o/r","0123456789abcdef0123456789abcdef01234567"]}]}' > "$T/jobs/claim"
tick
check "C6d ready-facts at the cap runs" '[ "$(cnt "^hp_run ready-facts bp")" = 1 ]'
check "C6d ready-facts stored finished, not pending" 'jq -e "select(.id==8) | .result==\"pass\"" "$T/body-result" >/dev/null && ! jq -e "select(.id==8) | .result==\"pending\"" "$T/body-result" >/dev/null'
check "C6d count read only for the capped probe" '[ "$(cnt /api/hub-probe/count-today)" = 1 ]'
check "C6d capped probe still defers" 'jq -e "select(.id==9) | .result==\"pending\" and .note==\"deferred: daily cap\"" "$T/body-result" >/dev/null'
check "C6d ready-facts is silent, no POST" '[ "$(posts)" = 0 ] && summary | grep -q "silent=1"'

# ── C7: hp_on_pass runs once on a stored PASS, never on a FAIL ───────────────
reset; tick
check "C7 on-pass called once with the row" '[ "$(wc -l < "$T/onpass")" = 1 ] && grep -q "^bp BH-12 app-status-write \[" "$T/onpass"'
reset; echo 1 > "$T/probe-rc"; tick
check "C7b FAIL never calls on-pass" '[ ! -e "$T/onpass" ]'
reset; echo 2 > "$T/probe-rc"; tick
check "C7b rejected never calls on-pass" '[ ! -e "$T/onpass" ] && jq -e "select(.id==7)|.result==\"rejected\"" "$T/body-result" >/dev/null'
check "C7b rejected renders FAIL" '[ "$(head -1 "$T/posted.1")" = "## Hub probe app-status-write: FAIL" ] && grep -q "^rejected: probe or arguments not on the allowlist" "$T/posted.1"'
reset; echo 1 > "$T/jobs/result.rc"; tick
check "C7c PASS with a failed store: no on-pass" '[ ! -e "$T/onpass" ]'

# ── C8: a failed store posts nothing and alerts once ─────────────────────────
reset; echo 1 > "$T/jobs/result.rc"; tick
check "C8 no POST" '[ "$(posts)" = 0 ] && [ "$(cnt "^gh_rest")" = 0 ]'
check "C8 store-failed=1" 'summary | grep -q "store-failed=1"'
check "C8 one alert-line call" '[ "$(wc -l < "$T/alerts" 2>/dev/null || echo 0)" = 1 ] && grep -q -- "--id hub-probe" "$T/alerts"'
check "C8 no spool" '[ ! -e "$H/state/hub-probe/owed/7.json" ]'

# ── C9: a failed claim skips the tick ────────────────────────────────────────
reset; echo 1 > "$T/jobs/claim.rc"; tick
check "C9 rc 0" '[ "$(cat "$T/tick.rc")" = 0 ]'
check "C9 claim-failed" 'summary | grep -q " claim-failed$"'
check "C9 no gh calls and no run" '[ "$(cnt "^gh_rest")" = 0 ] && [ "$(cnt "^hp_run")" = 0 ]'

# ── C10: an unreadable thread is never read as "no marker" ───────────────────
reset; echo 75 > "$T/gh/thread.rc"; tick
check "C10 no POST" '[ "$(posts)" = 0 ]'
check "C10 spool kept" '[ -e "$H/state/hub-probe/owed/7.json" ]'
check "C10 no /commented" '[ "$(cnt /api/hub-probe/commented)" = 0 ]'

# ── C12: the tick cap bounds the claim; 0 claims nothing ─────────────────────
reset; HUB_PROBE_TICK_CAP=3 tick
check "C12 claim asks for the cap" 'jq -e ".n==3" "$T/body-claim" >/dev/null'
reset; HUB_PROBE_TICK_CAP=0 tick
check "C12 cap 0 claims nothing" '[ "$(cnt /api/hub-probe/claim)" = 0 ] && summary | grep -q "claimed=0"'

# ── C11: the registry entries ────────────────────────────────────────────────
L="$DIR/catalog/lanes.d/hub-probe.json"
check "C11 lane entry parses, hub scope, */10" 'jq -e ".id==\"hub-probe\" and .scope==\"hub\" and .script==\"bin/hub-probe.sh\" and .cadence==\"*/10 * * * *\" and .switch.name==\"lane-off-hub-probe\"" "$L" >/dev/null'
check "C11 no per_project_hold" 'jq -e "has(\"per_project_hold\")|not" "$L" >/dev/null'
check "C11 caps settable with defaults 10 and 20" 'jq -e "[.knobs[] | select((.env==\"HUB_PROBE_TICK_CAP\" and .default==10) or (.env==\"HUB_PROBE_DAILY_CAP\" and .default==20)) | select(.settable != false)] | length == 2" "$L" >/dev/null'
check "C11b seams not settable" 'jq -e "[.knobs[] | select((.env==\"HUB_PROBE_FIXTURE\" or .env==\"HARNESS_TEST_SANDBOX\") and .settable==false)] | length == 2" "$L" >/dev/null'
check "C11 switch entry" 'jq -e ".name==\"hub-probe-off\" and .readers==[\"bin/hub-probe.sh\"] and .box_scoped==false" "$DIR/catalog/switches.d/hub-probe-off.json" >/dev/null'
check "C11 cron line" 'grep -qx "\*/10 \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/hub-probe.sh >/dev/null 2>&1" "$DIR/cron/lanes/720-hub-probe.cron" && grep -qx "# @hub-lanes" "$DIR/cron/lanes/720-hub-probe.cron"'

echo "hub-probe-lane: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
