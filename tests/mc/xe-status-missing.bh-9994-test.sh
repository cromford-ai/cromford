#!/bin/bash
# tests/mc/xe-status-missing.bh-9994-test.sh — BH-9994: the merge conductor's
# external path alerts in ONE tick when an approved, green, clean external
# head carries no verdict status on a repo whose .mergify.yml waits on it.
#
# THE DEFECT. On example-org/project-2 the conductor sent `@mergifyio queue`
# for #868 (an external PR) twice, and Mergify held it for hours on the one
# condition left: `check-success~=^(lead-verdict|harness-verdict)$`. Nothing
# alerted. The one alert that could (mc_status_unpublished_alert) runs only
# from mc_enqueue_mergify's failed publish, at most once per repo per UTC day.
#
# Sources the REAL bin/lib/verdict-status.sh, bin/lib/lead-required.sh,
# bin/lib/autoenqueue.sh, bin/lib/mc/queue.sh and bin/lib/mc/external-enqueue.sh
# and calls the REAL xe_project. Stubbed at their entry points: gh_rest (the
# open-PR list, .mergify.yml, the combined status), _ae_gates (pass or fail
# per PR), _ae_send_locked, mc_alert, mc_attempt_has/put and mc_log, the
# A1-A10 shape of tests/verdict-status-identity.bh-9287-test.sh. 0 network
# calls.
#
#   X1  approved, gates pass, yml names harness-verdict, no status: 1 alert,
#       mark `status-unpublished <slug> <head>`
#   X2  the same head on the next tick: 0 new alerts, no status read
#   X3  a second head on the same repo, the same day: 1 more alert
#   X4  harness-verdict success on the head: 0 alerts
#   X5  lead-verdict success only: 0 alerts
#   X6  a yml that names neither context: 0 alerts, no status read
#   X7  the status read answers 75: 0 alerts, no mark, 1 log line
#   X8  the gates fail (G4 red): no status read
#   X9  a harness-authored PR is never offered: no status read
#   X10 the 4-argument call (mc_enqueue_mergify's) keeps the per-day mark
#
#   HARNESS_TEST_SANDBOX=1 bash tests/mc/xe-status-missing.bh-9994-test.sh   exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1 || { echo "SKIP: jq or base64 missing"; exit 0; }
unset GH_TOKEN GH_APP_PROFILE LEAD_VERDICT_CONTEXT JOBS_URL HARNESS_SECRET

SLUG=example-org/bh9994-fixture
H1=$(printf 'a%.0s' $(seq 40)); H2=$(printf 'b%.0s' $(seq 40))
U="https://github.com/$SLUG/pull"
F="$T/fx"; mkdir -p "$F" "$T/h/bin" "$T/h/logs" "$T/h/state" "$T/h/env"
export HARNESS="$T/h" MC_H="$T/h" MC_LOCK_DIR="$T/locks"

yml_json() { jq -nc --arg c "$(base64 -w 60 < "$1")" '{type:"file", encoding:"base64", content:($c + "\n")}'; }
printf '%s\n' 'queue_rules:' '  - name: default' '    queue_conditions:' \
  '      - check-success~=^(lead-verdict|harness-verdict)$' > "$F/names.yml"
printf '%s\n' 'queue_rules:' '  - name: default' '    queue_conditions:' '      - check-success=ci' > "$F/neither.yml"

# A REST pull row.
pr_row() { # pr_row <num> <head> <login>
  jq -nc --argjson n "$1" --arg h "$2" --arg l "$3" --arg u "$U/$1" \
    '{number:$n, html_url:$u, head:{sha:$h, ref:"feature/x", repo:{full_name:"r"}},
      base:{ref:"main", repo:{full_name:"r"}}, draft:false, labels:[], updated_at:"2026-11-24T00:00:00Z", user:{login:$l}}'
}
status_json() { # status_json [<context> <state>]...
  local a='[]'
  while [ $# -ge 2 ]; do a=$(jq -c --arg c "$1" --arg s "$2" '. + [{context:$c, state:$s, updated_at:"2026-11-24T00:00:00Z", description:"d"}]' <<<"$a"); shift 2; done
  jq -nc --argjson s "$a" '{state:"pending", statuses:$s}'
}

# FIXTURE: list.json (the open PRs), yml (names|neither), status-<head>
# (a combined-status body, or the word rc75), gate-<num> (pass|fail).
gh_rest() {
  printf '%s %s\n' "$1" "$2" >> "$F/gh.log"
  case "$1 $2" in
    "GET repos/$SLUG/pulls?state=open&per_page=100") GH_REST_STATUS=200; cat "$F/list.json" ;;
    "GET repos/$SLUG/contents/.mergify.yml") GH_REST_STATUS=200; yml_json "$F/$(cat "$F/yml").yml" ;;
    "GET repos/$SLUG/commits/"*"/status")
      local h="${2#repos/"$SLUG"/commits/}"; h="${h%/status}"
      if [ "$(cat "$F/status-$h" 2>/dev/null)" = rc75 ]; then GH_REST_STATUS=000; GH_REST_REASON=network; return 75; fi
      GH_REST_STATUS=200; cat "$F/status-$h" 2>/dev/null || status_json ;;
    *) GH_REST_STATUS=404; return 44 ;;
  esac
}
gh_auth_for() { return 0; }
la_decide() { return 0; }
vd_standing() { return 1; }
setting_get() { return 2; }

# shellcheck source=bin/lib/verdict-status.sh
. "$DIR/bin/lib/verdict-status.sh" || exit 1
# shellcheck source=bin/lib/lead-required.sh
. "$DIR/bin/lib/lead-required.sh" || exit 1
# shellcheck source=bin/lib/mc/classify.sh
. "$DIR/bin/lib/mc/classify.sh" || exit 1
# shellcheck source=bin/lib/mc/settle.sh
. "$DIR/bin/lib/mc/settle.sh" || exit 1
# shellcheck source=bin/lib/mc/queue.sh
. "$DIR/bin/lib/mc/queue.sh" || exit 1
# shellcheck source=bin/lib/autoenqueue.sh
. "$DIR/bin/lib/autoenqueue.sh" || exit 1
# shellcheck source=bin/lib/mc/external-enqueue.sh
. "$DIR/bin/lib/mc/external-enqueue.sh" || exit 1

# --- neighbours, stubbed after the libs ---------------------------------------
mc_log()   { printf '%s\n' "$*" >> "$F/log"; }
mc_alert() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$F/alerts"; }
mc_attempt_has() { grep -qxF "$1" "$F/attempts" 2>/dev/null; }
mc_attempt_put() { echo "$1" >> "$F/attempts"; }
harness_pr_author_match() { [ "${1:-}" = 'cromford-builders[bot]' ]; }
_ae_home() { printf '%s\n' "$T/h"; }
_ae_required_checks() { printf ''; }
_ae_gates() { # the real gates' contract: AE_NUM… set only when every gate passed
  local num url head
  AE_GATE=""; AE_LEDGER_READ=0; AE_GATE_KEY=""
  IFS=$'\t' read -r num url head _ <<<"$1"
  printf '%s\n' "$num" >> "$F/gates.log"
  [ "$(cat "$F/gate-$num" 2>/dev/null || echo pass)" = pass ] || return 1
  AE_NUM="$num"; AE_URL="$url"; AE_HEAD="$head"; AE_JOB=-; AE_KEY="$AE_SLUG#$num"
  return 0
}
_ae_send_locked() { printf '%s\n' "$AE_NUM" >> "$F/sends"; return 0; }
export MODE=merge MERGES=1

n() { if [ -f "$1" ]; then grep -c -- "${2:-.}" "$1"; else echo 0; fi; }
reads() { n "$F/gh.log" "/commits/$1/status"; }
reset() { rm -f "$F"/log "$F"/alerts "$F"/attempts "$F"/gh.log "$F"/gates.log "$F"/sends "$F"/status-* "$F"/gate-*; scratch_rm "$T/locks"; echo "${1:-names}" > "$F/yml"; }
list() { local r=""; while [ $# -ge 3 ]; do r="$r$(pr_row "$1" "$2" "$3")"$'\n'; shift 3; done; printf '%s' "$r" | jq -sc . > "$F/list.json"; }
tick() { xe_project tproj "$SLUG" mergify main; }

# X1 — the alert, in the first tick.
reset names; list 868 "$H1" partner-dev
tick
[ "$(n "$F/sends")" = 1 ] && ok || bad "X1: the queue ask was not sent (gates fixture): $(cat "$F/sends" 2>/dev/null)"
[ "$(n "$F/alerts")" = 1 ] && ok || bad "X1: expected 1 alert, got $(n "$F/alerts"): $(cat "$F/alerts" 2>/dev/null)"
grep -qxF "status-unpublished $SLUG $H1" "$F/attempts" && ok || bad "X1: the per-head mark is missing: $(cat "$F/attempts" 2>/dev/null)"
txt=$(cut -f3 "$F/alerts" 2>/dev/null)
grep -q "${H1:0:12}" <<<"$txt" && grep -q 'harness-verdict' <<<"$txt" && grep -q 'review lane' <<<"$txt" && grep -q "$U/868" <<<"$txt" \
  && ok || bad "X1: the alert text does not name the head, the context, the review lane and the PR: $txt"
[ "$(cut -f2 "$F/alerts" 2>/dev/null)" = READY ] && ok || bad "X1: the alert severity is not READY: $(cut -f2 "$F/alerts")"

# X2 — the same head on the next tick: no second alert, no second read.
tick
[ "$(n "$F/alerts")" = 1 ] && ok || bad "X2: the same head alerted again ($(n "$F/alerts") alerts)"
[ "$(reads "$H1")" = 1 ] && ok || bad "X2: the alerted head was read again ($(reads "$H1") reads)"

# X3 — a second head on the same repo, the same day (the old per-day rule's near miss).
list 878 "$H2" partner-dev
tick
[ "$(n "$F/alerts")" = 2 ] && ok || bad "X3: a second head the same day did not alert ($(n "$F/alerts") alerts)"
grep -qxF "status-unpublished $SLUG $H2" "$F/attempts" && ok || bad "X3: no mark for the second head"
grep -q "status-unpublished $SLUG $(date -u +%Y%m%d)" "$F/attempts" && bad "X3: a per-day mark was written by the per-head path" || ok

# X4 — harness-verdict success on the head.
reset names; list 868 "$H1" partner-dev; status_json harness-verdict success > "$F/status-$H1"
tick
[ "$(reads "$H1")" = 1 ] && ok || bad "X4: the status was not read ($(reads "$H1"))"
[ "$(n "$F/alerts")" = 0 ] && ok || bad "X4: a head with harness-verdict success alerted: $(cat "$F/alerts")"
[ "$(n "$F/attempts")" = 0 ] && ok || bad "X4: a mark was written for a cleared head"

# X5 — lead-verdict success only.
reset names; list 868 "$H1" partner-dev; status_json lead-verdict success > "$F/status-$H1"
tick
[ "$(n "$F/alerts")" = 0 ] && ok || bad "X5: a head with lead-verdict success alerted: $(cat "$F/alerts")"

# X5b — harness-verdict failure (a lane BLOCK) is not a clearance: it alerts.
reset names; list 868 "$H1" partner-dev; status_json harness-verdict failure > "$F/status-$H1"
tick
[ "$(n "$F/alerts")" = 1 ] && grep -q '(failure)' "$F/alerts" && ok || bad "X5b: a failure status did not alert with its state: $(cat "$F/alerts" 2>/dev/null)"

# X6 — a yml that names neither context: no read, no alert.
reset neither; list 868 "$H1" partner-dev
tick
[ "$(n "$F/sends")" = 1 ] && ok || bad "X6: the gates did not pass"
[ "$(reads "$H1")" = 0 ] && ok || bad "X6: the status was read on a repo whose yml names neither context"
[ "$(n "$F/alerts")" = 0 ] && ok || bad "X6: an alert fired on a repo whose yml names neither context: $(cat "$F/alerts")"

# X7 — the status read answers 75: no alert, no mark, 1 log line.
reset names; list 868 "$H1" partner-dev; echo rc75 > "$F/status-$H1"
tick
[ "$(n "$F/alerts")" = 0 ] && ok || bad "X7: an unread status alerted: $(cat "$F/alerts")"
[ "$(n "$F/attempts")" = 0 ] && ok || bad "X7: an unread status wrote a mark: $(cat "$F/attempts")"
[ "$(n "$F/log" 'verdict status unread')" = 1 ] && ok || bad "X7: expected 1 'verdict status unread' log line: $(cat "$F/log" 2>/dev/null)"
# ... and the next tick, with the read back, alerts.
rm -f "$F/status-$H1"; tick
[ "$(n "$F/alerts")" = 1 ] && ok || bad "X7: the tick after an unread status did not alert"

# X8 — the gates fail: no status read, no alert.
reset names; list 868 "$H1" partner-dev; echo fail > "$F/gate-868"
tick
[ "$(n "$F/gates.log")" = 1 ] && ok || bad "X8: the row was not offered to the gates"
[ "$(reads "$H1")" = 0 ] && ok || bad "X8: the status was read for a row that failed a gate"
[ "$(n "$F/alerts")" = 0 ] && ok || bad "X8: a row that failed a gate alerted"

# X9 — a harness-authored PR is not the external path's: no read.
reset names; list 900 "$H1" 'cromford-builders[bot]'
tick
[ "$(reads "$H1")" = 0 ] && [ "$(n "$F/alerts")" = 0 ] && ok || bad "X9: a harness PR was checked by the external path"

# X10 — mc_enqueue_mergify's 4-argument call keeps the per-day mark and text.
reset names
mc_status_unpublished_alert "$SLUG" "$U/41" "vs_publish: 403" harness-verdict
grep -qxF "status-unpublished $SLUG $(date -u +%Y%m%d)" "$F/attempts" && ok || bad "X10: the 4-argument call lost its per-day mark: $(cat "$F/attempts" 2>/dev/null)"
grep -q 'Commit statuses' "$F/alerts" && ok || bad "X10: the 4-argument call lost its publish-failure text: $(cat "$F/alerts" 2>/dev/null)"
mc_status_unpublished_alert "$SLUG" "$U/42" "vs_publish: 403" harness-verdict
[ "$(n "$F/alerts")" = 1 ] && ok || bad "X10: the 4-argument call paged twice in one day"
# A 5th argument that is not a 40-hex head is the per-day form.
reset names
mc_status_unpublished_alert "$SLUG" "$U/41" "why" harness-verdict "not-a-sha"
grep -qxF "status-unpublished $SLUG $(date -u +%Y%m%d)" "$F/attempts" && ok || bad "X10b: a bad head argument did not fall back to the per-day mark"

echo "xe-status-missing (BH-9994): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
