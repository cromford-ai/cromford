#!/bin/bash
# tests/archie-fm-watch-404.bh-8417-test.sh — BH-8417 (Scope E, T9): the
# archie-fm-watch lane tells a ROW 404 from a ROUTE 404, writes one tick line
# every acting tick, and turns a real route-absent into ONE ALERTS line a day.
#
# WHY. logs/archie-fm-watch.log stopped on 2026-10-19 03:24Z with "archie_actions
# route absent (HTTP 404)". The real bin/lib/jobs/req.sh prints NOTHING on a
# 404 (the body goes to JOBS_BODY / JOBS_BODY_FILE), so the lane read the
# worker's row miss {"error":"archie action not found"}
# (worker/jobs/src/routes/archie-actions.js) as "route absent" and stopped the
# tick on the first new finding. A quiet tick wrote no line at all.
#
# WHAT IS REAL. bin/archie-fm-watch.sh, its lib closure, bin/jobs-client.sh and
# bin/lib/jobs/req.sh (the real _jobs_req), and bin/alert-line.sh. WHAT IS
# STUBBED: `curl` on PATH answers as the jobs worker from a jq model in
# $T/db.json (no network); bin/beat.sh fails (alert-line.sh appends to the
# scratch logs/ALERTS.log); bin/fleet-conf.sh; `gh`, `df`, `crontab`.
#
# Cases: R1 row miss on the ledger read -> both findings handled; R2 a row-miss
# 404 on the claim (afw_handle rc 2) -> that finding failed, the next one
# handled; R2b a row-miss 404 on the outcome write -> the loop goes on; R3 the
# worker's unknown-endpoint 404 -> route absent + 1 ALERTS line, a 2nd tick the
# same day -> still 1, the next day -> 2; R4 an empty-body 404 -> route absent;
# R5 zero findings -> 1 tick line; R6 a tick line on a tick with findings.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-fm-watch-404.bh-8417-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "archie-fm-watch-404: jq is required"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "archie-fm-watch-404: flock is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

# The product paths this ticket touches (D41).
for f in "$DIR/bin/archie-fm-watch.sh" "$DIR/bin/lib/archie-fm-watch/common.sh" \
         "$DIR/bin/lib/jobs/req.sh" "$DIR/worker/jobs/src/routes/archie-actions.js"; do
  if [ -f "$f" ]; then ok; else bad "missing ${f#"$DIR"/}"; fi
done
# The row-miss body this lane keys on is the worker's own text.
check "the worker's row miss body is 'archie action not found'" \
  'grep -qF "notFound(\"archie action\")" "$DIR/worker/jobs/src/routes/archie-actions.js"'

NOW=1793001600                      # 2026-10-26T08:00:00Z
DAY=20261026
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
H="$T/h"
mkdir -p "$H/bin" "$H/env" "$H/logs" "$T/fakebin" "$T/home" "$T/tmp"
: > "$H/env/global.env"
# Stubs first: scratch_install_closure never clobbers a file already there.
printf '#!/bin/bash\nexit 1\n' > "$H/bin/beat.sh"
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1" in
  --projects) echo fixt ;;
  --*) ;;
  *) case "${2:-}" in repo) echo "acme/$1" ;; box) echo "box-$1" ;; esac ;;
esac
SH
chmod +x "$H/bin/beat.sh" "$H/bin/fleet-conf.sh"
for s in bin/archie-fm-watch.sh bin/jobs-client.sh bin/alert-line.sh; do
  scratch_install_closure "$s" "$H" >/dev/null \
    || { echo "FAIL: cannot install the closure of $s"; echo "archie-fm-watch-404: $PASS passed, 1 failed"; exit 1; }
done

# The jobs worker, as curl sees it: body, newline, status (curl -w '\n%{http_code}').
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
m=GET; body=""; prev=""; wfmt=0
for a in "$@"; do
  case "$prev" in -X) m="$a" ;; --data-binary|-d) body="$a" ;; -w) wfmt=1 ;; esac
  prev="$a"
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
url="${!#}"
case "$url" in "$JOBS_URL"*) ;; *) printf 'curl %s\n' "$url" >> "$FXT/net.log"; exit 7 ;; esac
p="${url#"$JOBS_URL"}"
printf '%s %s %s\n' "$m" "$p" "$body" >> "$FXT/reqlog"
db="$FXT/db.json"; t=$(date -u -d "@$ARCHIE_FMW_NOW" +%Y-%m-%dT%H:%M:%SZ)
qp() { printf '%s' "$p" | sed -n "s/.*[?&]$1=\([^&]*\).*/\1/p"; }
code=200; out='{"ok":true}'
case "$m ${p%%\?*}" in
  "GET /api/settings") out='{"settings":[]}' ;;
  GET\ /api/settings/*)
    k=${p#/api/settings/}
    out=$(jq -c --arg k "$k" 'select(.settings | has($k)) | {setting: {key: $k, value: .settings[$k]}}' "$db")
    [ -n "$out" ] || { code=404; out='{"error":"no such setting"}'; } ;;
  "GET /api/initiatives") out='{"initiatives":[],"truncated":false,"as_of":"x"}' ;;
  "GET /api/alerts")
    st=$(qp state)
    out=$(jq -c --arg s "$st" '{alerts: [.alerts[] | select(.state == $s)], truncated: false, as_of: "x"}' "$db") ;;
  "POST /api/alerts/actions")
    k=$(jq -r .id <<<"$body")
    jq --arg k "$k" '.alerts |= map(if .id == $k then .state = "triaged" else . end)' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
    printf '%s\n' "$k" >> "$FXT/acks.log"
    out=$(jq -c --arg k "$k" '{alert: (.alerts[] | select(.id == $k)), action: {outcome: "ok"}}' "$db") ;;
  "GET /api/archie/actions"|"POST /api/archie/actions"|"POST /api/archie/actions/outcome")
    if [ -f "$FXT/archie.absent" ]; then
      code=404; out=$(cat "$FXT/archie.absent")
    elif [ "$m" = GET ] && [ -n "$(qp dedupe_key)" ]; then
      k=$(qp dedupe_key); k=$(printf '%b' "${k//%/\\x}")
      out=$(jq -c --arg k "$k" '.actions[] | select(.dedupe_key == $k) | {action: .}' "$db")
      [ -n "$out" ] || { code=404; out='{"error":"archie action not found"}'; }
    elif [ "$m" = GET ]; then
      d=$(qp day); pb=$(qp playbook)
      out=$(jq -c --arg d "$d" --arg pb "$pb" '[.actions[] | select(.day == $d and ($pb == "" or .playbook == $pb))] as $r
        | {ok: true, day: $d, actions: $r, counts: (reduce $r[] as $x ({}; .[$x.playbook][$x.mode][$x.outcome] += 1)), truncated: false}' "$db")
    elif [ "${p%%\?*}" = /api/archie/actions ]; then
      k=$(jq -r .dedupe_key <<<"$body")
      out=$(jq -c --arg k "$k" '.actions[] | select(.dedupe_key == $k)' "$db")
      if [ -f "$FXT/claim.miss" ] && grep -qF -- "$(cat "$FXT/claim.miss")" <<<"$k"; then
        code=404; out='{"error":"archie action not found"}'
      elif [ -z "$out" ]; then
        jq --argjson b "$body" --arg t "$t" '.actions += [$b + {id: ((.actions | length) + 1), day: $t[0:10], attempts: 1, created_at: $t, updated_at: $t}]' \
          "$db" > "$db.tmp" && mv "$db.tmp" "$db"
        out=$(jq -c --arg k "$k" '{ok: true, created: true, action: (.actions[] | select(.dedupe_key == $k))}' "$db"); code=201
      else
        out=$(jq -c '{ok: true, existing: true, action: .}' <<<"$out")
      fi
    else
      k=$(jq -r .dedupe_key <<<"$body")
      if [ -f "$FXT/outcome.miss" ] && grep -qF -- "$(cat "$FXT/outcome.miss")" <<<"$k"; then
        code=404; out='{"error":"archie action not found"}'
      else
        jq --argjson b "$body" --arg t "$t" '.actions |= map(if .id == $b.id then .outcome = $b.outcome | .updated_at = $t else . end)' \
          "$db" > "$db.tmp" && mv "$db.tmp" "$db"
        out=$(jq -c --argjson b "$body" '{ok: true, action: (.actions[] | select(.id == $b.id))}' "$db")
      fi
    fi ;;
  *) code=404; out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;;
esac
printf '%s' "$out"
[ "$wfmt" = 1 ] && printf '\n%s' "$code"
exit 0
SH
printf '#!/bin/bash\nprintf "gh %%s\\n" "$*" >> "$FXT/net.log"\nexit 1\n' > "$T/fakebin/gh"
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/crontab"
cat > "$T/fakebin/df" <<'SH'
#!/bin/bash
printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\n/dev/root 1000 100 900 10%% /\ntmpfs 1000 50 950 5%% /tmp\n'
SH
chmod +x "$T/fakebin/"*

export HOME="$T/home" HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.invalid HARNESS_SECRET=test \
  JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 MC_REHYDRATE=0 TMPDIR="$T/tmp" HARNESS_CHECKOUT="$T/no-checkout" \
  ARCHIE_FMW_STATE_MD="$T/STATE.md"
unset HARNESS_ENV_DIR ARCHIE_FMW_ENABLED ARCHIE_FMW_RETRY_S ARCHIE_FMW_NOW ARCHIE_FMW_FIXTURE ARCHIE_FMW_TIMED \
  ARCHIE_FMW_HOST ARCHIE_FMW_TICK_CEILING_S LANE_RUN_ID ALERT_LINE_STAMP JOBS_BODY_FILE JOBS_STATUS_FILE 2>/dev/null || true

ALOG="$H/logs/ALERTS.log"
WLOG="$H/logs/archie-fm-watch.log"
world() {
  local p
  for p in db.json reqlog acks.log net.log archie.absent outcome.miss claim.miss out rc; do scratch_rm "$T/$p" || exit 1; done
  for p in state locks flags logs; do scratch_rm "$H/$p" || exit 1; done
  mkdir -p "$H/state/merge-conductor" "$H/locks" "$H/flags" "$H/logs"
  : > "$H/state/merge-conductor/pr-state.tsv"; : > "$H/state/merge-conductor/attempts.txt"
  jq -n '{settings: {"archie.manage": "on", "archie.watch.interval_min": "10"}, actions: [], alerts: []}' > "$T/db.json"
}
alert() { # alert <id> <line> <box>
  jq --arg id "$1" --arg l "$2" --arg fs "$(iso $(( NOW - 3600 )))" --arg b "$3" \
    '.alerts += [{id: $id, family: "0123456789ab", box: $b, project: "", state: "new", count: 1, first_seen: $fs,
                  last_seen: $fs, claimed_by: null, claimed_at: null, notified_at: null, severity: "warn", line: $l}]' \
    "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
}
two_findings() {
  alert disk-high-box-a "[orchestrator/disk-guard] / at 91% on box-a." box-a
  alert disk-high-box-b "[orchestrator/disk-guard] / at 92% on box-b." box-b
}
tick() { # tick [VAR=value ...]
  env HARNESS_TEST_SANDBOX=1 ARCHIE_FMW_NOW="$NOW" ARCHIE_FMW_HOST=hubbox LANE_GATE_DISABLE=1 "$@" \
    bash "$H/bin/archie-fm-watch.sh" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
rc() { cat "$T/rc"; }
nacks() { if [ -f "$T/acks.log" ]; then grep -c . "$T/acks.log"; else echo 0; fi; }
acked() { grep -qx "$1" "$T/acks.log" 2>/dev/null; }
nabs() { local n; n=$(grep -c "route absent" "$ALOG" 2>/dev/null); printf '%s' "${n:-0}"; }
nticks() { local n; n=$(grep -c " tick findings=" "$WLOG" 2>/dev/null); printf '%s' "${n:-0}"; }
outcome() { jq -r --arg s "$1" '[.actions[] | select(.dedupe_key | contains($s))][0].outcome // "none"' "$T/db.json"; }

# ── R1: a row miss on the ledger read is "no row yet", never "route absent" ──
world; two_findings; tick
check "R1 rc 0 ($(rc): $(cat "$T/out"))" '[ "$(rc)" = 0 ]'
check "R1 the ledger read of a new key was a 404 row miss" \
  'grep -q "^GET /api/archie/actions?dedupe_key=" "$T/reqlog"'
check "R1 both findings acked ($(nacks): $(cat "$WLOG" 2>/dev/null))" \
  'acked disk-high-box-a && acked disk-high-box-b'
check "R1 both rows closed done" '[ "$(outcome box-a)" = done ] && [ "$(outcome box-b)" = done ]'
check "R1 no 'route absent' in the log or ALERTS" '! grep -q "route absent" "$WLOG" && [ "$(nabs)" = 0 ]'

# ── R2: a row 404 that reaches the loop fails that finding; the loop goes on ─
world; two_findings; printf 'box-a' > "$T/claim.miss"; tick
check "R2 rc 0" '[ "$(rc)" = 0 ]'
check "R2 box-a was not acked" '! acked disk-high-box-a'
check "R2 the next finding (box-b) was handled ($(cat "$WLOG" 2>/dev/null))" \
  'acked disk-high-box-b && [ "$(outcome box-b)" = done ]'
check "R2 no 'route absent' anywhere" '! grep -q "route absent" "$WLOG" && [ "$(nabs)" = 0 ]'
check "R2 the box-a row 404 is logged as a per-finding failure" \
  'grep "box-a" "$WLOG" | grep "archie action not found" >/dev/null'
check "R2 the tick line counts failed=1" 'grep " tick findings=" "$WLOG" | grep "failed=1" >/dev/null'
world; two_findings; printf 'box-a' > "$T/outcome.miss"; tick
check "R2b row 404 on the outcome write: box-b still handled, no route absent" \
  'acked disk-high-box-b && [ "$(outcome box-b)" = done ] && ! grep -q "route absent" "$WLOG" && [ "$(nabs)" = 0 ]'

# ── R3: the worker's unknown-endpoint 404 is the route absent ───────────────
world; two_findings; printf '{"error":"unknown endpoint","worker":"harness-jobs"}' > "$T/archie.absent"; tick
check "R3 rc 0" '[ "$(rc)" = 0 ]'
check "R3 'route absent' in the lane log" 'grep -q "route absent" "$WLOG"'
check "R3 one ALERTS line naming the route ($(cat "$ALOG" 2>/dev/null))" \
  '[ "$(nabs)" = 1 ] && grep "route absent" "$ALOG" | grep "archie-fm-watch" >/dev/null'
check "R3 nothing acked" '[ "$(nacks)" = 0 ]'
check "R3 a tick line still written" '[ "$(nticks)" = 1 ]'
tick
check "R3 2nd tick the same day: still one ALERTS line ($(nabs))" '[ "$(nabs)" = 1 ]'
check "R3 2nd tick: a 2nd tick line" '[ "$(nticks)" = 2 ]'
tick ARCHIE_FMW_NOW=$(( NOW + 86400 ))
check "R3 the next day: a 2nd ALERTS line ($(nabs))" '[ "$(nabs)" = 2 ]'
check "R3 only the newest day's marker is kept" \
  '[ "$(find "$H/state/archie-fm-watch" -name "route-absent-*" | wc -l)" = 1 ] && [ -e "$H/state/archie-fm-watch/route-absent-20261027" ]'

# ── R4: an empty-body 404 is the route absent too ───────────────────────────
world; two_findings; : > "$T/archie.absent"; tick
check "R4 empty 404 body: route absent, one ALERTS line" '[ "$(nabs)" = 1 ] && [ "$(nacks)" = 0 ]'

# ── R5: zero findings still write ONE tick line ─────────────────────────────
world; tick
check "R5 rc 0" '[ "$(rc)" = 0 ]'
check "R5 zero findings: exactly one tick line ($(cat "$WLOG" 2>/dev/null))" \
  '[ "$(nticks)" = 1 ] && grep " tick findings=" "$WLOG" | grep "findings=0" >/dev/null'
check "R5 the tick line starts with an ISO stamp (bin/log-freshness.sh reads it)" \
  'grep " tick findings=" "$WLOG" | grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z " >/dev/null'
tick
check "R5 a 2nd quiet tick: a 2nd tick line" '[ "$(nticks)" = 2 ]'

# ── R6: a tick with findings writes one tick line too ───────────────────────
world; two_findings; tick
check "R6 one tick line naming findings=2" \
  '[ "$(nticks)" = 1 ] && grep " tick findings=" "$WLOG" | grep "findings=2" >/dev/null'

check "no request left the box" '[ ! -s "$T/net.log" ]'
echo "archie-fm-watch-404: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
