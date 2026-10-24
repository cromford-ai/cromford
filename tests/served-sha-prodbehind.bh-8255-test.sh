#!/bin/bash
# tests/served-sha-prodbehind.bh-8255-test.sh — bin/lib/served-sha-watch.d/30-prodbehind.sh:
# ONE critical page prodbehind:<project> when Vercel prod has been behind main
# HEAD for SERVED_SHA_PRODBEHIND_MIN minutes AND the newest production
# deployment failed; a reminder every SERVED_SHA_PRODBEHIND_REPEAT_H hours; a
# resolve when prod serves main again.
#
# Every tick runs the REAL bin/served-sha-watch.sh through
# tests/lib/served-sha-fixture.sh (stub curl/gh), with only 30-prodbehind.sh in
# the scratch hook dir and a recorder lane-alert that writes
# `ALERT_REMINDER_S=<v> <argv>` per call ($T/alerts.txt).
#   P1   page: one critical call, id prodbehind:demo-os, every text field
#   P2   behind exactly 45 min -> page; P6 44 min -> no page, since written
#   P3   project-3 shape: head moves 3 times over 27h -> one id, since kept
#   P4   state only in .readyState, lower-case -> page
#   P5   newest BUILDING / QUEUED / INITIALIZING -> no page
#   P7   the hook's compare read fails -> `? commits behind`, never 0
#   P8   newest READY / CANCELED -> no page
#   P9   older ERROR + newer READY, either array order -> no page
#   P10  list 500 / {} / [] -> no page; one extra list GET per behind tick
#   P11  in-sync after a page -> one resolve, state gone, a new clock after
#   P12  in-sync with nothing open -> no call, no extra GET; P12u unreadable
#   P13  MIN=0 -> off; P13m no conductor/build/deploy-queue state -> still pages
#   P14  knob defaults and fallbacks reach lane-alert
#   P15  the REAL lane-alert: one line, suppressed, reminded at 4h, resolved
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/served-sha-prodbehind.bh-8255-test.sh  (exit 0 = pass)
# scratch-closure-allow: copies the hook file under test into the hook dir ssw_fx_reset empties; the lane's own closure is installed by ssw_fx_setup's scratch_install_closure
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/served-sha-fixture.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
HOOK="$DIR/bin/lib/served-sha-watch.d/30-prodbehind.sh"
[ -s "$HOOK" ] || bad "setup: $HOOK is missing or empty"

ssw_fx_setup || { bad "setup: ssw_fx_setup failed"; exit 1; }
H="$T/h"
HD="$H/bin/lib/served-sha-watch.d"
SF="$H/state/served-sha-watch/demo-os.json"
AL="$T/alerts.txt"
LOG="$H/logs/served-sha-watch.log"
cat > "$H/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf 'ALERT_REMINDER_S=%s %s\n' "${ALERT_REMINDER_S:-unset}" "$*" >> "$SSW_FX_T/alerts.txt"
SH
chmod +x "$H/bin/lane-alert.sh"
cp "$H/bin/lane-alert.sh" "$T/recorder.sh"
export ORCHESTRATOR="$T/orc"   # the box's own monitor-off flag must not reach the real lane-alert in P15
B=2b2272a4e1f0c3d5b6a7980112233445566778aa
C=7c6b5a4938271605f4e3d2c1b0a9f8e7d6c5b4a3
D2=4d3c2b1a0f9e8d7c6b5a49382716051423324150
A=9f8e7d6c5b4a39281706f5e4d3c2b1a098765432
ID="prodbehind:demo-os"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }  # determinism: ok formats a pinned epoch, reads no clock

install_hook() { mkdir -p "$HD" && cp "$HOOK" "$HD/30-prodbehind.sh"; }
reset() { ssw_fx_reset; install_hook; }
compare_ahead() { jq -nc --argjson n "$1" '{status:"ahead", ahead_by:$n, behind_by:0}' > "$T/fx/compare.json"; }
# dep <state> [field] [created_ms] [uid] — one deployment object
dep() { jq -nc --arg st "$1" --arg f "${2:-state}" --argjson c "${3:-1790000000000}" --arg u "${4:-dpl_fixture1}" --arg s "$B" \
  '{uid:$u, target:"production", created:$c, meta:{githubCommitSha:$s}} + {($f):$st}'; }
list1() { printf '{"deployments":[%s]}' "$(dep "$@")"; }
# base <head> <head age s> [served] — prod serves A, main is <head>, ahead 6
base() { ssw_fx_head "${1:-$B}" "$(iso $(( ${SERVED_SHA_NOW:-$NOW} - ${2:-3000} )))"; ssw_fx_served "${3:-$A}"; compare_ahead 6; }
lines() { [ -f "$AL" ] && wc -l < "$AL" || echo 0; }
since() { jq -r '.prodbehind.since // "none"' "$SF" 2>/dev/null || echo none; }
listgets() { grep -c '/v6/deployments?' "$T/req/argv.lines"; }

# ── P1: the page ─────────────────────────────────────────────────────────────
reset; base; ssw_fx_list "$(list1 ERROR)"; ssw_fx_run
L1=$(sed -n 1p "$AL" 2>/dev/null)
[ "$(lines)" = 1 ] && ok || bad "P1 exactly one call: $(cat "$AL" 2>&1) :: $(cat "$LOG" 2>&1)"
for want in "ALERT_REMINDER_S=14400 " "--critical --id $ID served-sha-watch " "PROD BEHIND MAIN: demo-os" \
            "prod serves ${A:0:8}" "main is ${B:0:8}" "6 commits behind" "for 0h50m" \
            "deployment dpl_fixture1 (${B:0:8}) failed (ERROR)" "vercel inspect dpl_fixture1 --logs --scope team_x"; do
  case "$L1" in *"$want"*) ok ;; *) bad "P1 call lacks '$want': $L1" ;; esac
done
case "$L1" in *"prodbehind:demo-os:"*) bad "P1 a per-sha id: $L1" ;; *) ok ;; esac
! grep -qP '\x{2014}' "$AL" 2>/dev/null && ok || bad "P1 an em dash in the page: $L1"
! grep -rq fixture-token-1 "$AL" "$H/logs" 2>/dev/null && ok || bad "P1 the Vercel token leaked"
[ "$(jq -r '.prodbehind.open' "$SF" 2>/dev/null)" = true ] && ok || bad "P1 .prodbehind.open: $(cat "$SF" 2>&1)"
[ "$(since)" = $((NOW - 3000)) ] && ok || bad "P1 since seeded from HEAD's age: $(since)"
grep -q 'hook ssw_hook_prodbehind rc=' "$LOG" && bad "P1 hook rc non-zero: $(cat "$LOG")" || ok
[ "$(listgets)" = 2 ] && ok || bad "P10a one extra list GET on a paging tick (lane 1 + hook 1): $(listgets)"

# ── P2 / P6: the edge ────────────────────────────────────────────────────────
reset; base "$B" 2700; ssw_fx_list "$(list1 ERROR)"; ssw_fx_run
[ "$(lines)" = 1 ] && grep -q 'for 0h45m' "$AL" && ok || bad "P2 exactly 45 min pages: $(cat "$AL" 2>&1)"
reset; base "$B" 2640; ssw_fx_list "$(list1 ERROR)"; ssw_fx_run
[ "$(lines)" = 0 ] && ok || bad "P6 44 min must not page: $(cat "$AL")"
[ "$(since)" = $((NOW - 2640)) ] && ok || bad "P6 since written under the threshold: $(cat "$SF" 2>&1)"
[ "$(listgets)" = 1 ] && ok || bad "P6 no extra list GET under the threshold: $(listgets)"

# ── P3: the project-3 shape ───────────────────────────────────────────────────────
reset; base "$B" 3000; ssw_fx_list "$(list1 ERROR)"; ssw_fx_run
S0=$(since)
SERVED_SHA_NOW=$((NOW + 3600)); export SERVED_SHA_NOW
printf 500 > "$T/fx/alias.code"; ssw_fx_run; rm -f "$T/fx/alias.code"
[ "$(since)" = "$S0" ] && ok || bad "P3 an unreadable tick keeps since: $(since) vs $S0"
SERVED_SHA_NOW=$((NOW + 7200)); base "$C" 200; ssw_fx_run
[ "$(since)" = "$S0" ] && ok || bad "P3 since kept when head moves to C: $(since) vs $S0"
SERVED_SHA_NOW=$((NOW + 97200)); base "$D2" 300; ssw_fx_run
unset SERVED_SHA_NOW
[ "$(since)" = "$S0" ] && ok || bad "P3 since kept when head moves to D: $(since) vs $S0"
[ "$(lines)" = 3 ] && [ "$(grep -c -- "--id $ID served-sha-watch " "$AL")" = 3 ] && ok || bad "P3 one id on every page: $(cat "$AL")"
! grep -q "prodbehind:demo-os:" "$AL" && ok || bad "P3 a per-sha id: $(cat "$AL")"
sed -n 3p "$AL" | grep -q "main is ${D2:0:8}, 6 commits behind for 27h50m" && ok || bad "P3 the +27h text: $(sed -n 3p "$AL")"

# ── P4: other format ─────────────────────────────────────────────────────────
reset; base; ssw_fx_list "$(list1 error readyState)"; ssw_fx_run
[ "$(lines)" = 1 ] && ok || bad "P4 readyState=error pages: $(cat "$AL" 2>&1)"

# ── P5 / P8: pending, ready, canceled ────────────────────────────────────────
for s in BUILDING QUEUED INITIALIZING READY CANCELED; do
  reset; base; ssw_fx_list "$(list1 "$s")"; ssw_fx_run
  [ "$(lines)" = 0 ] && ok || bad "P5/P8 newest $s must not page: $(cat "$AL")"
done

# ── P7: the hook's compare read fails ────────────────────────────────────────
reset; base; ssw_fx_list "$(list1 ERROR)"
printf 'ssw_hook_aflip() { printf 500 > "$SSW_FX_T/fx/compare.code"; }\n' > "$HD/05-flip.sh"
ssw_fx_run
[ "$(lines)" = 1 ] && grep -q '? commits behind' "$AL" && ! grep -q ' 0 commits behind' "$AL" \
  && ok || bad "P7 unread compare is '? commits behind': $(cat "$AL" 2>&1) :: $(cat "$LOG")"

# ── P9: order, not index 0 ───────────────────────────────────────────────────
OLD=$(dep ERROR state 1789990000000 dpl_old); NEW=$(dep READY state 1789999000000 dpl_new)
for l in "[$OLD,$NEW]" "[$NEW,$OLD]"; do
  reset; base; ssw_fx_list "{\"deployments\":$l}"; ssw_fx_run
  [ "$(lines)" = 0 ] && ok || bad "P9 a newer READY wins over an older ERROR ($l): $(cat "$AL")"
done
reset; base; ssw_fx_list "{\"deployments\":[$(dep READY state 1789990000000 dpl_old),$(dep ERROR state 1789999000000 dpl_new)]}"; ssw_fx_run
[ "$(lines)" = 1 ] && grep -q 'deployment dpl_new ' "$AL" && ok || bad "P9c a newer ERROR in position 2 pages: $(cat "$AL" 2>&1)"

# ── P10: cannot tell ─────────────────────────────────────────────────────────
reset; base; ssw_fx_list "$(list1 ERROR)"; printf 500 > "$T/fx/list.code"; ssw_fx_run
[ "$(lines)" = 0 ] && ok || bad "P10 list 500 must not page: $(cat "$AL")"
[ "$(listgets)" = 2 ] && ok || bad "P10 exactly one extra list GET: $(listgets)"
for l in '{}' '{"deployments":[]}' '{"deployments":[{"uid":"dpl_x","created":1}]}'; do
  reset; base; ssw_fx_list "$l"; ssw_fx_run
  [ "$(lines)" = 0 ] && ok || bad "P10 list $l must not page: $(cat "$AL")"
done

# ── P11: resolve ─────────────────────────────────────────────────────────────
reset; base; ssw_fx_list "$(list1 ERROR)"; ssw_fx_run
ssw_fx_served "$B"; ssw_fx_run
[ "$(lines)" = 2 ] && [ "$(sed -n 2p "$AL")" = "ALERT_REMINDER_S=unset --resolve --id $ID served-sha-watch demo-os: prod serves ${B:0:8}, main is ${B:0:8}, back in sync" ] \
  && ok || bad "P11 one resolve: $(cat "$AL" 2>&1)"
[ ! -e "$SF" ] && ok || bad "P11 state gone after in-sync"
ssw_fx_run
[ "$(lines)" = 2 ] && ok || bad "P11 a 2nd in-sync tick sends nothing: $(cat "$AL")"
SERVED_SHA_NOW=$((NOW + 600)) ; export SERVED_SHA_NOW; base "$C" 120 "$B"; ssw_fx_run; unset SERVED_SHA_NOW
[ "$(since)" = $((NOW + 480)) ] && ok || bad "P11 a new behind run starts a fresh clock: $(since)"

# ── P12: in-sync / unreadable ────────────────────────────────────────────────
reset; base "$B" 3000 "$B"; ssw_fx_list "$(list1 ERROR)"; ssw_fx_run
[ "$(lines)" = 0 ] && ok || bad "P12 in-sync with nothing open: $(cat "$AL")"
[ "$(listgets)" = 1 ] && ok || bad "P12 no extra list GET in sync: $(listgets)"
reset; base; ssw_fx_list "$(list1 ERROR)"; ssw_fx_run
printf 500 > "$T/fx/alias.code"; ssw_fx_run
[ "$(lines)" = 1 ] && ok || bad "P12u an unreadable tick neither pages nor resolves: $(cat "$AL")"
[ "$(jq -r '.prodbehind.open' "$SF" 2>/dev/null)" = true ] && ok || bad "P12u state kept: $(cat "$SF" 2>&1)"

# ── P13: off / Mergify-style merge ───────────────────────────────────────────
reset; base; ssw_fx_list "$(list1 ERROR)"; SERVED_SHA_PRODBEHIND_MIN=0 ssw_fx_run
[ "$(lines)" = 0 ] && ok || bad "P13 MIN=0 is off: $(cat "$AL")"
[ "$(jq -r 'has("prodbehind")' "$SF" 2>/dev/null)" = false ] && ok || bad "P13 MIN=0 writes no .prodbehind: $(cat "$SF" 2>&1)"
reset; base; ssw_fx_list "$(list1 ERROR)"
[ ! -e "$H/state/merge-conductor" ] && [ ! -e "$H/builds" ] && [ ! -e "$H/state/deploy-queue" ] && ok || bad "P13m scratch has conductor/build state"
ssw_fx_run
[ "$(lines)" = 1 ] && ok || bad "P13m a merge with no conductor record still pages: $(cat "$AL")"

# ── P14: knobs ───────────────────────────────────────────────────────────────
reset; base; ssw_fx_list "$(list1 ERROR)"; SERVED_SHA_PRODBEHIND_REPEAT_H=2 ssw_fx_run
grep -q '^ALERT_REMINDER_S=7200 ' "$AL" && ok || bad "P14 REPEAT_H=2 -> 7200: $(cat "$AL")"
for v in x 0; do
  reset; base; ssw_fx_list "$(list1 ERROR)"; SERVED_SHA_PRODBEHIND_REPEAT_H=$v ssw_fx_run
  grep -q '^ALERT_REMINDER_S=14400 ' "$AL" && ok || bad "P14 REPEAT_H=$v -> 14400: $(cat "$AL")"
  [ "$(grep -c 'SERVED_SHA_PRODBEHIND_REPEAT_H' "$LOG")" = 1 ] && ok || bad "P14 REPEAT_H=$v one log line: $(cat "$LOG")"
done
reset; base "$B" 3000; ssw_fx_list "$(list1 ERROR)"; SERVED_SHA_PRODBEHIND_MIN=60 ssw_fx_run
[ "$(lines)" = 0 ] && ok || bad "P14 MIN=60 does not page at 50 min: $(cat "$AL")"
reset; base "$B" 3000; ssw_fx_list "$(list1 ERROR)"; SERVED_SHA_PRODBEHIND_MIN=abc ssw_fx_run
[ "$(lines)" = 1 ] && grep -q "SERVED_SHA_PRODBEHIND_MIN='abc' is not a whole number" "$LOG" && ok || bad "P14 MIN=abc -> 45 + log: $(cat "$AL" 2>&1) :: $(cat "$LOG")"

# ── P15: the REAL lane-alert ─────────────────────────────────────────────────
reset; base; ssw_fx_list "$(list1 ERROR)"
rm -f "$H/bin/lane-alert.sh"
scratch_install_closure bin/lane-alert.sh "$H" >/dev/null || bad "P15 install lane-alert closure"
touch "$H/flags/alert-quarantine-disabled" "$H/flags/remediation-disabled"
: > "$T/alerts.conf"
export ALERTS_CONF="$T/alerts.conf"
SID="$H/state/alerts/prodbehind_demo-os.json"
pages() { grep -c 'PROD BEHIND MAIN' "$H/logs/ALERTS.log" 2>/dev/null; }
# back <s> — move the row's last_notified <s> seconds into the past (relative to its own value, no clock read)
back() { local n; n=$(jq -r '.last_notified' "$SID") && jq -c --argjson n "$((n - $1))" '.last_notified = $n' "$SID" > "$SID.t" && mv "$SID.t" "$SID"; }
ssw_fx_run
[ "$(pages)" = 1 ] && ok || bad "P15 tick 1 one ALERTS.log line: $(cat "$H/logs/ALERTS.log" 2>&1)"
[ -f "$SID" ] && ok || bad "P15 state row: $(ls "$H/state/alerts" 2>&1)"
ssw_fx_run
[ "$(pages)" = 1 ] && ok || bad "P15 tick 2 suppressed: $(cat "$H/logs/ALERTS.log")"
back 3600; ssw_fx_run
[ "$(pages)" = 1 ] && ok || bad "P15 1h after the page still suppressed: $(cat "$H/logs/ALERTS.log")"
back 14460; SERVED_SHA_PRODBEHIND_REPEAT_H=6 ssw_fx_run
[ "$(pages)" = 1 ] && ok || bad "P15 control: REPEAT_H=6 does not remind at ~4h: $(cat "$H/logs/ALERTS.log")"
ssw_fx_run
[ "$(pages)" = 2 ] && grep 'PROD BEHIND MAIN' "$H/logs/ALERTS.log" | sed -n 2p | grep -q 'still firing' \
  && ok || bad "P15 the 4h reminder: $(cat "$H/logs/ALERTS.log")"
ssw_fx_served "$B"; ssw_fx_run
[ "$(grep -c 'RESOLVED: demo-os: prod serves' "$H/logs/ALERTS.log")" = 1 ] && ok || bad "P15 one RESOLVED line: $(cat "$H/logs/ALERTS.log")"
unset ALERTS_CONF
rm -f "$H/bin/lane-alert.sh"; cp "$T/recorder.sh" "$H/bin/lane-alert.sh"; chmod +x "$H/bin/lane-alert.sh"

echo "served-sha-prodbehind.bh-8255: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
