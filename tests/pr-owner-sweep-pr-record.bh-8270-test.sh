#!/bin/bash
# tests/pr-owner-sweep-pr-record.bh-8270-test.sh — BH-8270: bin/pr-owner-sweep.sh
# reads the fleet's PR record (pr_records, BH-8067) before GitHub.
#
#   U1-U6  po_prr_read (bin/lib/pr-owner/prr.sh), sourced: every hit and miss
#          kind, its rc, its stdout and its one PRR_MISS line.
#   S1     the stale ladder's rebase rung takes the branch from the record's
#          head_ref; with no row it reads pulls/N, as before.
#   A1-A3, E1-E3, L1-L6, M1  the REAL bin/pr-owner-sweep.sh, whole, in its own
#          scratch tree per case, against a gh PATH shim that logs every call
#          and answers only what the case's fixture files hold (a missing file
#          is a failed call), and a file-backed jobs worker behind a curl shim
#          that serves GET /api/pr-records from $W/prr/<n>.json and stores what
#          PUT /api/pr-records sends. prs_wake_seen is an exported table double.
#
# PR reads are every gh call except the two infra probes the sweep makes
# before any PR read: `api rate_limit` (bin/lib/gh-budget.sh) and
# `api repos/<slug> -q .id` (bin/lib/gh-repo-token.sh). They are logged too,
# and counted apart.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pr-owner-sweep-pr-record.bh-8270-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

NOW=1790000000                      # pinned: PR_OWNER_NOW and WAKE_BACKSTOP_NOW
OLD=2026-09-01T00:00:00Z            # every PR moved long before the grace window
S=example-org/fx; P=fx
sha() { printf "$1%.0s" $(seq 40); }
HA=$(sha a); HB=$(sha b); HC=$(sha c)

# ============================================================================
# U. po_prr_read, sourced
# ============================================================================
UF="$T/u"; mkdir -p "$UF"
# U <answer|-> [knob] -- <args...>: one po_prr_read in a subshell. The
# _jobs_req stub answers $UF/answer (`-` = the GET fails) and counts calls.
U() {
  local ans="$1" knob="$2"; shift 3
  : > "$UF/say"; : > "$UF/reqs"; : > "$UF/out"
  if [ "$ans" = - ]; then rm -f "$UF/answer"; else printf '%s' "$ans" > "$UF/answer"; fi
  ( unset HARNESS H; export PR_RECORD_MAX_AGE_S="$knob"
    say() { printf '%s\n' "$*" >> "$UF/say"; }
    _jobs_req() { printf '%s %s\n' "$1" "$2" >> "$UF/reqs"; [ -f "$UF/answer" ] || return 1; cat "$UF/answer"; }
    . "$DIR/bin/lib/pr-owner/prr.sh" || exit 9
    po_prr_read "$@" > "$UF/out" ); URC=$?
  UOUT=$(cat "$UF/out"); USAY=$(cat "$UF/say"); UREQ=$(grep -c . "$UF/reqs")
}
ROW='{"repo":"example-org/fx","number":7,"state":"open","draft":false,"head_ref":"ticket/bh-7","head_sha":"'"$HA"'","mergeable_state":"clean","labels":[],"checks":null}'
ans() { jq -nc --argjson r "$1" --argjson a "$2" '{row:$r, age_s:$a}'; }  # ans <row> <age_s|null>

# U1 hits: h1 age 10, h2 age 900 exactly (<=), h3 dirty, h4 merged state+head only
U "$(ans "$ROW" 10)" 900 -- "$S" 7 state head_sha draft mergeable_state
[ "$URC" = 0 ] && [ "$(jq -r .head_sha <<<"$UOUT")" = "$HA" ] && [ -z "$USAY" ] && [ "$UREQ" = 1 ] && ok \
  || bad "U1 h1 wanted rc 0 + the row + no line, got rc $URC out '$UOUT' say '$USAY' reqs $UREQ"
grep -q 'GET /api/pr-records?repo=example-org/fx&number=7' "$UF/reqs" && ok || bad "U1 the GET is lowercased repo + number: $(cat "$UF/reqs")"
U "$(ans "$ROW" 900)" 900 -- "$S" 7 state head_sha
[ "$URC" = 0 ] && [ -z "$USAY" ] && ok || bad "U1 h2 age 900 at knob 900 is a hit, got rc $URC say '$USAY'"
U "$(ans "$(jq -c '.mergeable_state="dirty"' <<<"$ROW")" 10)" 900 -- "$S" 7 mergeable_state
[ "$URC" = 0 ] && [ "$(jq -r .mergeable_state <<<"$UOUT")" = dirty ] && ok || bad "U1 h3 dirty is a hit, got rc $URC '$UOUT'"
U "$(ans "$(jq -c '.state="merged" | .mergeable_state=null' <<<"$ROW")" 10)" 900 -- "$S" 7 state head_sha
[ "$URC" = 0 ] && [ "$(jq -r .state <<<"$UOUT")" = merged ] && ok || bad "U1 h4 merged row asked for state head_sha is a hit, got rc $URC say '$USAY'"
# U2 m1 no row, m2 age 901
U '{"row":null}' 900 -- "$S" 7 state
[ "$URC" = 1 ] && [ -z "$UOUT" ] && [ "$USAY" = "PRR_MISS $S#7 why=no-row" ] && ok || bad "U2 m1 wanted rc 1 + 'PRR_MISS $S#7 why=no-row', got rc $URC say '$USAY'"
U "$(ans "$ROW" 901)" 900 -- "$S" 7 state
[ "$URC" = 1 ] && [ -z "$UOUT" ] && [ "$USAY" = "PRR_MISS $S#7 why=stale" ] && ok || bad "U2 m2 age 901 wanted why=stale, got rc $URC say '$USAY'"
# U3 m3 knob 0: stale, and no request at all; m4 age_s absent
U "$(ans "$ROW" 1)" 0 -- "$S" 7 state
[ "$URC" = 1 ] && [ "$UREQ" = 0 ] && [ "$USAY" = "PRR_MISS $S#7 why=stale" ] && ok || bad "U3 m3 knob 0 wanted why=stale + 0 requests, got rc $URC reqs $UREQ say '$USAY'"
U "$(jq -nc --argjson r "$ROW" '{row:$r}')" 900 -- "$S" 7 state
[ "$URC" = 1 ] && [ "$USAY" = "PRR_MISS $S#7 why=stale" ] && ok || bad "U3 m4 no age_s wanted why=stale, got rc $URC say '$USAY'"
# U4 m5 a null GitHub-filled field
U "$(ans "$(jq -c '.mergeable_state=null' <<<"$ROW")" 10)" 900 -- "$S" 7 state head_sha draft mergeable_state
[ "$URC" = 1 ] && [ "$USAY" = "PRR_MISS $S#7 why=no-field field=mergeable_state" ] && ok || bad "U4 m5 wanted why=no-field field=mergeable_state, got rc $URC say '$USAY'"
# U5 m6 the GET fails / answers {} / no _jobs_req
U - 900 -- "$S" 7 state
[ "$URC" = 1 ] && [ "$USAY" = "PRR_MISS $S#7 why=unreadable" ] && ok || bad "U5 m6 a failed GET wanted why=unreadable, got rc $URC say '$USAY'"
U '{}' 900 -- "$S" 7 state
[ "$URC" = 1 ] && [ "$USAY" = "PRR_MISS $S#7 why=unreadable" ] && ok || bad "U5 m6 {} wanted why=unreadable, got rc $URC say '$USAY'"
O=$( ( unset HARNESS H; say() { echo "$*"; }; . "$DIR/bin/lib/pr-owner/prr.sh"; po_prr_read "$S" 7 state ) 2>&1 ); RC=$?
[ "$RC" = 1 ] && [ "$O" = "PRR_MISS $S#7 why=unreadable" ] && ok || bad "U5 no _jobs_req wanted why=unreadable, got rc $RC '$O'"
# U6 m7 a null checks not asked is a hit; bad args and unknown fields are rc 2, no request, no line
U "$(ans "$ROW" 10)" 900 -- "$S" 7 head_ref checks
[ "$URC" = 0 ] && ok || bad "U6 m7 a null checks (not GitHub-filled) is still a hit, got rc $URC say '$USAY'"
for A in "$S 0 state" "nope 7 state" "$S 7 bogus" "$S 7"; do
  # shellcheck disable=SC2086
  U "$(ans "$ROW" 10)" 900 -- $A
  [ "$URC" = 2 ] && [ "$UREQ" = 0 ] && [ -z "$USAY" ] && ok || bad "U6 '$A' wanted rc 2, no request, no line; got rc $URC reqs $UREQ say '$USAY'"
done
# no pr-record.sh beside it: the lib defines nothing
( cd "$DIR" && scratch_install_closure bin/lib/pr-owner/prr.sh "$T/nolib" ) >/dev/null || { echo "setup: could not install prr.sh"; exit 1; }
rm -f "$T/nolib/bin/lib/pr-record.sh"
( . "$T/nolib/bin/lib/pr-owner/prr.sh"; command -v po_prr_read >/dev/null ) && bad "U6 with no pr-record.sh po_prr_read must not exist" || ok

# ============================================================================
# S1. the stale rebase rung's branch (the pr-stale-ladder harness, cut down)
# ============================================================================
SH_="$T/sh"; CALLS="$T/s-calls.log"; SAYF="$T/s-say.log"
mkdir -p "$SH_/logs"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
S1() { # S1 <record answer|-> — one po_stale on a rebase-due OWNED PR
  : > "$CALLS"; : > "$SAYF"
  if [ "$1" = - ]; then rm -f "$T/s-prr"; else printf '%s' "$1" > "$T/s-prr"; fi
  ( H="$SH_" HARNESS="$SH_" PR_RECORD_MAX_AGE_S=900
    . "$DIR/bin/lib/pr-health.sh" || exit 9
    gh_rest() {
      printf 'GH %s %s\n' "$1" "$2" >> "$CALLS"
      case "$2" in
        repos/*/commits/*) printf '{"commit":{"committer":{"date":"%s"}},"parents":[]}\n' "$(iso $((NOW - 25 * 3600)))" ;;
        repos/*/pulls/*)   printf '{"state":"open","head":{"ref":"ticket/bh-8105"},"labels":[]}\n' ;;
        *) return 75 ;;
      esac
    }
    gh_rest_comment() { return 0; }; gh_rest_close() { return 0; }; hold_check() { return 0; }
    _jobs_req() {
      printf 'JOBS %s %s\n' "$1" "$2" >> "$CALLS"
      case "$2" in
        /api/pr-records\?*) [ -f "$T/s-prr" ] || return 1; cat "$T/s-prr" ;;
        /api/verdicts\?*) printf '{"rows":[],"standing":null}' ;;
        *) return 2 ;;
      esac
    }
    pr_attempt_has() { return 2; }; pr_attempt_put() { :; }; pr_attempt_del() { :; }; pr_attempt_list() { return 2; }
    mc_row_get() { printf '%s\tWAIT_REVIEW\t1789000000\tabc\tdef\t-\t-\thttps://github.com/%s/pull/8105\n' "$1" "$S"; }
    mc_handoff_owns() { return 1; }; mc_transition() { :; }
    mc_rebase() { printf 'MC_REBASE %s\n' "$*" >> "$CALLS"; return 0; }
    say() { printf '%s\n' "$*" >> "$SAYF"; }
    . "$DIR/bin/lib/pr-owner/prr.sh" || exit 9
    . "$DIR/bin/lib/pr-owner/stale.sh" || exit 9
    PO_PROJECT=$P PO_SLUG=$S PO_NUM=8105 PO_HEAD=$HA PO_AUTHOR=operator PO_CLASS=OWNED PO_KEY=BH-8105
    PO_CREATED="$(iso $((NOW - 30 * 86400)))" PO_DRAFT=0 PO_MERGEABLE=MERGEABLE PO_OWNED=1
    PO_STALE_REBASE_H=24 PO_STALE_REPLAN_D=5 PO_STALE_CLOSE_D=10 PO_STALE_NOW=$NOW MAX_ACTIONS=5 DRY=0
    po_stale </dev/null )
}
S1 "$(jq -nc --argjson r "$(jq -c '.number=8105 | .head_ref="ticket/bh-8105-rec"' <<<"$ROW")" '{row:$r, age_s:5}')"
[ "$(grep -c "MC_REBASE $S $P ticket/bh-8105-rec $HA " "$CALLS")" = 1 ] && ok || bad "S1 a record hit wanted mc_rebase on the record's head_ref: $(cat "$CALLS")"
grep -q 'GH GET repos/.*/pulls/8105' "$CALLS" && bad "S1 a record hit still read pulls/8105: $(cat "$CALLS")" || ok
S1 '{"row":null}'
[ "$(grep -c "MC_REBASE $S $P ticket/bh-8105 $HA " "$CALLS")" = 1 ] && ok || bad "S1 no row wanted mc_rebase on the pulls/N branch: $(cat "$CALLS")"
[ "$(grep -c 'GH GET repos/example-org/fx/pulls/8105' "$CALLS")" = 1 ] && ok || bad "S1 no row wanted exactly 1 pulls/8105 read: $(cat "$CALLS")"
grep -qx "PRR_MISS $S#8105 why=no-row" "$SAYF" && ok || bad "S1 no row wanted one PRR_MISS why=no-row: $(cat "$SAYF")"

# ============================================================================
# The driven sweep: one template, one fresh copy per case
# ============================================================================
TPL="$T/tpl"
mkdir -p "$TPL/bin" "$TPL/logs" "$TPL/locks" "$TPL/flags" "$TPL/state" "$TPL/env" "$TPL/fx" "$TPL/w" "$T/fakebin"
ln -sf "$DIR/bin/fleet-conf.sh" "$TPL/bin/fleet-conf.sh"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
printf '%s %s https://fx.example - 2 box-fx\n' "$P" "$S" > "$TPL/fleet.conf"
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.test\n' > "$TPL/env/global.env"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/alerts.log"\nexit 0\n' > "$TPL/bin/lane-alert.sh"
printf '#!/bin/bash\necho "MC_ONLY_PR=${MC_ONLY_PR:-}" >> "$HARNESS/spawns.log"\n' > "$TPL/bin/merge-conductor.sh"
printf '#!/bin/bash\necho local\n' > "$TPL/bin/box-for.sh"
chmod +x "$TPL/bin/lane-alert.sh" "$TPL/bin/merge-conductor.sh" "$TPL/bin/box-for.sh"
for s in bin/pr-owner-sweep.sh bin/merge-conductor-backstop.sh bin/jobs-client.sh bin/alert-line.sh bin/lib/hub-box.sh; do
  scratch_install_closure "$s" "$TPL" >/dev/null || { echo "closure install failed: $s"; exit 1; }
done
[ -r "$TPL/bin/lib/pr-owner/prr.sh" ] || { echo "FAIL: the sweep's closure has no bin/lib/pr-owner/prr.sh"; FAIL=$((FAIL+1)); }
[ -r "$TPL/bin/lib/wake-backstop.sh" ] || { echo "FAIL: the sweep's closure has no bin/lib/wake-backstop.sh"; FAIL=$((FAIL+1)); }
touch "$TPL/flags/pr-state-rows"
export GH_TOKEN=tok-fixture-1 GH_BUDGET_TTL_S=0 GH_ETAG=0 PR_OWNER_NOW="$NOW" BOX_NAME=box-hub HUB_BOX_NAME=box-hub JOBS_RETRIES=0 JOBS_ALERT=0

# gh: answers only what $H/fx holds; a missing fixture is a failed call.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
FX="$HARNESS/fx"
printf '%s\n' "$*" >> "$HARNESS/gh-calls.log"
case "$*" in
  "api rate_limit"*) echo '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":2000000000},"graphql":{"remaining":4000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
  "api repos/"*" -q .id") echo 1234; exit 0 ;;
  *"pr list -R "*"--state open"*)   [ -f "$FX/open.json" ] || exit 1; cat "$FX/open.json"; exit 0 ;;
  *"pr list -R "*"--state merged"*) [ -f "$FX/merged.json" ] || exit 1; cat "$FX/merged.json"; exit 0 ;;
  *"api -i -X POST repos/"*|*"api -i -X PATCH repos/"*) restpr --raw 200 '{}'; exit 0 ;;
  *"api -i -X GET repos/"*"/actions/runs?head_sha="*)
    h=$(sed -nE 's/.*head_sha=([0-9a-f]+).*/\1/p' <<<"$*")
    [ -f "$FX/runs-$h" ] || exit 1; restpr --runs - < "$FX/runs-$h"; exit 0 ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    n=$(sed -nE 's#.*/pulls/([0-9]+).*#\1#p' <<<"$*")
    [ -f "$FX/pull-$n.status" ] && { restpr --raw "$(cat "$FX/pull-$n.status")" '{"message":"unavailable"}'; exit 0; }
    [ -f "$FX/pull-$n.json" ] || exit 1; restpr --raw 200 "$(cat "$FX/pull-$n.json")"; exit 0 ;;
esac
exit 1
SH
# the jobs worker: reads logged to reads.log, writes to writes.log. Any URL
# that is not the fixture worker is logged to escapes.log and fails.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
W="$HARNESS/w"; URL="${!#}"; M=GET; BODY=""
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; --data-binary) BODY="$2"; shift 2 ;; *) shift ;; esac; done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
case "$URL" in https://jobs.test/*) ;; *) printf '%s %s\n' "$M" "$URL" >> "$HARNESS/escapes.log"; exit 7 ;; esac
P="${URL#https://jobs.test}"
ans() { printf '%s\n%s\n' "$2" "$1"; exit 0; }
dec() { printf '%b' "${1//%/\\x}"; }
if [ "$M" != GET ]; then
  printf 'JOBS %s %s %s\n' "$M" "${P%%\?*}" "$BODY" >> "$HARNESS/writes.log"
  case "$P" in
    /api/pr-records)
      n=$(jq -r .number <<<"$BODY"); mkdir -p "$W/prr"
      row=$(jq -c '.fields + {repo, number}' <<<"$BODY")
      jq -nc --argjson r "$row" '{row:$r, age_s:0}' > "$W/prr/$n.json"
      ans 200 "$(jq -nc --argjson r "$row" '{row:$r, applied:($r|keys), stale:[]}')" ;;
    /api/pr-owners*) ans 200 '{"ok":true,"as_of":"2026-09-21T14:13:20Z"}' ;;
  esac
  ans 200 '{"ok":true}'
fi
printf 'JOBS GET %s\n' "$P" >> "$HARNESS/reads.log"
case "$P" in
  /api/pr-records\?*) [ -f "$W/prr-down" ] && ans 500 '{"error":"down"}'
    n=$(dec "${P#*\?}" | sed -nE 's/.*number=([0-9]+).*/\1/p')
    [ -f "$W/prr/$n.json" ] && ans 200 "$(cat "$W/prr/$n.json")"; ans 200 '{"row":null}' ;;
  /api/pr-state\?*) q=$(dec "${P#*\?}"); r=$(sed -nE 's/.*repo=([^&]+).*/\1/p' <<<"$q")
    [ -s "$W/prstate-${r//\//_}.json" ] && ans 200 "$(cat "$W/prstate-${r//\//_}.json")"; ans 404 '{"error":"no rows"}' ;;
  /api/verdict\?*) n=$(sed -nE 's/.*pull%2F([0-9]+).*/\1/p' <<<"$P")
    [ -f "$W/verdict-$n.json" ] && ans 200 "$(cat "$W/verdict-$n.json")"; ans 404 '{"error":"no verdict"}' ;;
  /api/verdicts\?*) ans 200 '{"standing":null}' ;;
  /api/jobs*) ans 200 '{"jobs":[]}' ;;
  /api/queue*) ans 200 '{"queue":[]}' ;;
esac
ans 404 '{"error":"no rows"}'
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

prs_wake_seen() {
  local r
  [ -f "$HARNESS/wake" ] || return 2
  r=$(awk -v k="$2" -v key="$3" '($1 == k || $1 == "*") && ($2 == key || $2 == "*" || key == "-") { print $3; exit }' "$HARNESS/wake")
  return "${r:-1}"
}
export -f prs_wake_seen

# fresh <case>: a new $H from the template, wake feed quiet.
fresh() {
  H="$T/c-$1"; W="$H/w"
  cp -a "$TPL" "$H" || { echo "setup: could not copy the template for $1"; exit 1; }
  export HARNESS="$H" FLEET_CONF="$H/fleet.conf"
  printf '* * 1\n' > "$H/wake"
  CD="$H/state/pr-owner-sweep/example-org_fx"
}
# pr_open <num> <head> [author]: one open PR on the list fixture (no ticket key)
pr_open() {
  local f="$H/fx/open.json"; [ -s "$f" ] || echo '[]' > "$f"
  jq --argjson n "$1" --arg h "$2" --arg a "${3:-operator}" --arg s "$S" --arg t "$OLD" \
    '. + [{number:$n,title:"scratch tool",headRefName:"operator/scratch-tool",headRefOid:$h,author:{login:$a},labels:[],body:"",
           mergeable:"MERGEABLE",updatedAt:$t,createdAt:$t,url:("https://github.com/"+$s+"/pull/"+($n|tostring)),isDraft:false}]' \
    "$f" > "$f.t" && mv "$f.t" "$f"
  [ -s "$H/fx/merged.json" ] || echo '[]' > "$H/fx/merged.json"
}
# pr_rest <num> <head> <state open|closed|merged> [mergeable_state]: the pulls/N answer
pr_rest() {
  jq -nc --arg s "$S" --argjson n "$1" --arg h "$2" --arg st "$3" --arg ms "${4:-clean}" \
    '{number:$n,state:(if $st == "merged" then "closed" else $st end),merged_at:(if $st == "merged" then "2026-09-20T00:00:00Z" else null end),
      html_url:("https://github.com/"+$s+"/pull/"+($n|tostring)),draft:false,mergeable_state:$ms,labels:[],
      updated_at:"2026-09-01T00:00:00Z",head:{sha:$h,ref:"operator/scratch-tool"},base:{ref:"main",sha:"'"$HC"'"}}' > "$H/fx/pull-$1.json"
}
# rec <num> <head> <state> <age_s> [mergeable_state]: the record's row for a PR
rec() {
  mkdir -p "$W/prr"
  jq -nc --arg r "example-org/fx" --argjson n "$1" --arg h "$2" --arg st "$3" --argjson a "$4" --arg ms "${5:-clean}" \
    '{row:{repo:$r,number:$n,state:$st,draft:false,head_ref:"operator/scratch-tool",base_ref:"main",head_sha:$h,
           mergeable_state:$ms,labels:[],checks:null}, age_s:$a}' > "$W/prr/$1.json"
}
owned() { # owned <num> <head>: a QUEUED conductor row owns the PR
  jq -nc --arg r "$S" --argjson n "$1" --arg h "$2" --arg t "$OLD" \
    '{rows:[{id:7,repo:$r,number:$n,state:"QUEUED",reason:"queued-by-fixture",head:$h,since:$t}]}' > "$W/prstate-example-org_fx.json"
}
approve() { jq -nc --arg s "$2" '{verdict:"APPROVE",artifacts:[{artifact_kind:"verdict",detail:({reviewed_sha:$s,settled:true}|tojson)}]}' > "$W/verdict-$1.json"; }
green() { printf 'completed|success\n' > "$H/fx/runs-$1"; }
nogh() { rm -f "$H/fx/open.json" "$H/fx/merged.json" "$H/fx/pull-"* "$H/fx/runs-"*; }   # every PR read fails
store_lists() { # store_lists <epoch>: the stored list pair, from the list fixtures
  mkdir -p "$CD"
  cp "$H/fx/open.json" "$CD/openlist.json"; printf -- '-\t%s\n' "$1" > "$CD/openlist.meta"
  cp "$H/fx/merged.json" "$CD/mergedlist.json"; printf -- '-\t%s\n' "$1" > "$CD/mergedlist.meta"
}
# run <at> [VAR=val...]: one fleet-wide --explain sweep; each run starts its own logs.
run() {
  local at="$1"; shift
  for f in gh-calls.log reads.log writes.log; do cat "$H/$f" >> "$H/$f.all" 2>/dev/null; rm -f "$H/$f"; done
  : > "$H/logs/pr-owner-sweep.log"
  OUT=$(env HARNESS_TEST_SANDBOX=1 WAKE_BACKSTOP_NOW="$at" "$@" "$H/bin/pr-owner-sweep.sh" --explain "$P" 2>/dev/null)
  LOGS=$(cat "$H/logs/pr-owner-sweep.log" 2>/dev/null)
}
prcalls() { grep -vE '^api rate_limit|^api repos/[^ ]+ -q \.id$' "$H/gh-calls.log" 2>/dev/null; }
nprcalls() { prcalls | grep -c .; }
listcalls() { prcalls | grep -c 'pr list -R'; }
pulls() { prcalls | grep -c "repos/$S/pulls/$1"; }
misses() { grep -c ' PRR_MISS ' <<<"$LOGS"; }
miss() { grep -cE "^[0-9-]+ [0-9:]+Z PRR_MISS $S#$1 why=$2\$" <<<"$LOGS"; }
verdicts() { awk 'f; /^# example-org\/fx$/ {f=1}' <<<"$OUT"; }
summary() { grep -oE "$S: open=.*" <<<"$LOGS" | tail -1; }
enrolled() { grep -oE "enrolled $S#$1 .*" <<<"$LOGS"; }
prr_gets() { grep -c 'GET /api/pr-records' "$H/reads.log" 2>/dev/null; }

# A1 fixture: #8101 record closed, #8102 record merged, #8103 owned by a conductor row
a1() {
  pr_open 8101 "$HA"; pr_open 8102 "$HB"; pr_open 8103 "$HC"; owned 8103 "$HC"
  pr_rest 8101 "$HA" closed; pr_rest 8102 "$HB" merged
  rec 8101 "$HA" closed 10; rec 8102 "$HB" merged 10; rec 8103 "$HC" open 10
}

# ── A1: 0 PR reads; same verdicts and summary as the knob-0 baseline ────────
fresh a1-base; a1
run "$NOW" PR_RECORD_MAX_AGE_S=0
BASE_V=$(verdicts); BASE_S=$(summary)
[ -n "$BASE_V" ] && [ -n "$BASE_S" ] && ok || bad "A1 baseline produced no verdicts or no summary: out '$OUT' log '$LOGS'"
grep -q $'^8101\tORPHAN' <<<"$BASE_V" && grep -q $'^8102\tORPHAN' <<<"$BASE_V" && grep -q $'^8103\tOWNED' <<<"$BASE_V" && ok \
  || bad "A1 baseline verdicts are not ORPHAN, ORPHAN, OWNED: $BASE_V"
[ "$(pulls 8101)" = 1 ] && [ "$(pulls 8102)" = 1 ] && [ "$(listcalls)" = 2 ] && ok \
  || bad "A1 baseline (knob 0) wanted 2 list reads + pulls/8101 + pulls/8102: $(prcalls)"
fresh a1; a1; store_lists $((NOW - 60)); nogh
run "$NOW"
[ "$(nprcalls)" = 0 ] && ok || bad "A1 wanted 0 PR reads on GitHub, got: $(prcalls)"
[ "$(verdicts)" = "$BASE_V" ] && ok || bad "A1 verdicts differ from the baseline: $(verdicts) vs $BASE_V"
[ "$(summary)" = "$BASE_S" ] && ok || bad "A1 summary differs: '$(summary)' vs '$BASE_S'"
grep -q 'enroll-skipped .* unreadable' <<<"$LOGS" && bad "A1 an enroll-skipped unreadable line: $LOGS" || ok
[ "$(misses)" = 0 ] && ok || bad "A1 wanted no PRR_MISS: $(grep PRR_MISS <<<"$LOGS")"

# ── A2: one PR missing from the record: exactly one GitHub read, one miss ──
fresh a2; a1; store_lists $((NOW - 60)); nogh; rm -f "$W/prr/8102.json"; pr_rest 8102 "$HB" merged
run "$NOW"
[ "$(nprcalls)" = 1 ] && [ "$(pulls 8102)" = 1 ] && ok || bad "A2 wanted exactly 1 PR read (pulls/8102), got: $(prcalls)"
[ "$(misses)" = 1 ] && [ "$(miss 8102 no-row)" = 1 ] && ok || bad "A2 wanted exactly 1 'PRR_MISS $S#8102 why=no-row': $(grep PRR_MISS <<<"$LOGS")"
[ "$(verdicts)" = "$BASE_V" ] && [ "$(summary)" = "$BASE_S" ] && ok || bad "A2 verdicts or summary differ from the baseline"
# M1: one miss line per fallback read, and the line's exact shape
[ "$(misses)" = "$(nprcalls)" ] && ok || bad "M1 PRR_MISS lines ($(misses)) must equal fallback reads ($(nprcalls))"

# ── A3: an open, clean record row: no pulls/N, the CI read stays ───────────
a3() { pr_open 8104 "$HA"; approve 8104 "$HA"; green "$HA"; pr_rest 8104 "$HA" open clean; rec 8104 "$HA" open 10; }
fresh a3-base; a3
run "$NOW" PR_RECORD_MAX_AGE_S=0
BASE_E=$(enrolled 8104)
[ -n "$BASE_E" ] && ok || bad "A3 baseline enrolled nothing: $LOGS"
fresh a3; a3
run "$NOW"
[ "$(pulls 8104)" = 0 ] && ok || bad "A3 a fresh open row wanted no pulls/8104 read: $(prcalls)"
[ "$(prcalls | grep -c "actions/runs?head_sha=$HA")" = 1 ] && ok || bad "A3 wanted exactly 1 actions/runs read on the head: $(prcalls)"
[ "$(enrolled 8104)" = "$BASE_E" ] && ok || bad "A3 enrolled line '$(enrolled 8104)' differs from the baseline '$BASE_E'"

# ── E1/E2: a stale row reads GitHub once, writes it back, then hits ────────
e1() { pr_open 8105 "$HA"; pr_rest 8105 "$HA" open dirty; green "$HA"; rec 8105 "$HA" open 901 dirty; }
fresh e1; e1
run "$NOW" PR_RECORD_MAX_AGE_S=900
[ "$(pulls 8105)" = 1 ] && [ "$(miss 8105 stale)" = 1 ] && ok || bad "E1 age 901 wanted 1 pulls/8105 + why=stale: $(prcalls) / $(grep PRR_MISS <<<"$LOGS")"
PUTS=$(grep 'JOBS PUT /api/pr-records' "$H/writes.log" 2>/dev/null)
[ "$(grep -c . <<<"$PUTS")" = 1 ] && jq -e --arg h "$HA" '.source == "github" and .number == 8105 and .repo == "example-org/fx"
    and .fields.head_sha == $h and .fields.state == "open" and .fields.mergeable_state == "dirty"' <<<"${PUTS#JOBS PUT /api/pr-records }" >/dev/null 2>&1 \
  && ok || bad "E2 wanted one PUT /api/pr-records source github with the read's fields: $PUTS"
run "$NOW" PR_RECORD_MAX_AGE_S=900
[ "$(pulls 8105)" = 0 ] && [ "$(misses)" = 0 ] && ok \
  || bad "E2 tick 2 on the written-back row wanted 0 pulls/8105 reads and only the list miss: $(prcalls) / $(grep PRR_MISS <<<"$LOGS")"
run "$NOW" PR_RECORD_MAX_AGE_S=0 PR_OWNER_DRY_RUN=1
grep -q 'JOBS PUT /api/pr-records' "$H/writes.log" 2>/dev/null && bad "E2 a dry run wrote the record back" || ok

# ── E3: record unreadable and GitHub 503: skipped, repo unread, as before ──
fresh e3; pr_open 8106 "$HA"; echo 503 > "$H/fx/pull-8106.status"; touch "$W/prr-down"
run "$NOW"
grep -q "enroll-skipped $S#8106 pull unreadable (HTTP 503" <<<"$LOGS" && ok || bad "E3 wanted 'enroll-skipped ... pull unreadable (HTTP 503': $LOGS"
[ "$(miss 8106 unreadable)" = 1 ] && ok || bad "E3 wanted one why=unreadable: $(grep PRR_MISS <<<"$LOGS")"
grep -q 'PUT /api/settings.*streak.pr-owner-ownerless' "$H/writes.log" 2>/dev/null && bad "E3 an unread repo moved the ownerless clock: $(cat "$H/writes.log")" || ok

# ── L1: the list pair is written on a read and reused on the next tick ─────
fresh l1; a1
run "$NOW"
[ "$(listcalls)" = 2 ] && [ "$(miss list no-row)" = 1 ] && ok || bad "L1 tick 1 wanted 2 list reads + 'PRR_MISS $S#list why=no-row': $(prcalls) / $(grep PRR_MISS <<<"$LOGS")"
for b in openlist mergedlist; do
  [ -s "$CD/$b.json" ] && [ "$(cat "$CD/$b.meta" 2>/dev/null)" = "-"$'\t'"$NOW" ] && ok || bad "L1 $b not stored with meta '-<TAB>$NOW': $(cat "$CD/$b.meta" 2>&1)"
done
V1=$(verdicts); S1L=$(summary)
nogh
run $((NOW + 60))
[ "$(nprcalls)" = 0 ] && [ "$(misses)" = 0 ] && ok || bad "L1 tick 2 wanted 0 PR reads and no miss: $(prcalls) / $(grep PRR_MISS <<<"$LOGS")"
[ "$(verdicts)" = "$V1" ] && [ "$(summary)" = "$S1L" ] && ok || bad "L1 tick 2 verdicts/summary differ from tick 1: $(verdicts) / $(summary)"
run $((NOW + 900))
[ "$(listcalls)" = 0 ] && ok || bad "L1 a copy exactly PR_RECORD_MAX_AGE_S old is still a hit: $(prcalls)"

# ── L2-L4 and the negative list: every one reads the lists again ───────────
l_read() { # l_read <name> <why> <at> [VAR=val...] — after setup, one run that must read
  local name="$1" why="$2" at="$3"; shift 3
  run "$at" "$@"
  [ "$(listcalls)" = 2 ] && [ "$(miss list "$why")" = 1 ] && ok \
    || bad "$name wanted 2 list reads + 'PRR_MISS $S#list why=$why': $(prcalls) / $(grep PRR_MISS <<<"$LOGS")"
}
fresh l2; a1; store_lists "$NOW"; printf 'pr 8101 0\n* * 1\n' > "$H/wake"; l_read L2 stale $((NOW + 60))
fresh l3; a1; store_lists "$NOW"; l_read L3 stale $((NOW + 901))
fresh l4; a1; store_lists "$NOW"; printf '* * 2\n' > "$H/wake"; l_read L4 stale $((NOW + 60))
fresh l-part; a1; store_lists "$NOW"; rm -f "$CD/mergedlist.json"; l_read "L r5 (merged half missing)" stale $((NOW + 60))
fresh l-future; a1; store_lists $((NOW + 120)); l_read "L r6 (meta in the future)" stale $((NOW + 60))
fresh l-switch; a1; store_lists "$NOW"; l_read "L WAKE_BACKSTOP=0" stale $((NOW + 60)) WAKE_BACKSTOP=0

# ── L5: a failed open list read writes no copy and skips the repo ──────────
fresh l5; a1; rm -f "$H/fx/open.json"
run "$NOW"
[ -e "$CD/openlist.json" ] || [ -e "$CD/mergedlist.json" ] && bad "L5 a failed list read wrote a copy: $(ls "$CD")" || ok
[ -z "$(summary)" ] && ok || bad "L5 the repo was not skipped: $(summary)"
fresh l5m; a1; rm -f "$H/fx/merged.json"
run "$NOW"
[ -e "$CD/openlist.json" ] && bad "L5 a failed merged list read stored the pair" || ok
[ -n "$(summary)" ] && ok || bad "L5 a failed merged read must still sweep the repo (as [] ): $LOGS"

# ── L6: PR_RECORD_MAX_AGE_S=0: every read on GitHub, 0 record GETs ─────────
fresh l6; a1; store_lists "$NOW"
run $((NOW + 60)) PR_RECORD_MAX_AGE_S=0
[ "$(listcalls)" = 2 ] && [ "$(pulls 8101)" = 1 ] && [ "$(pulls 8102)" = 1 ] && ok || bad "L6 knob 0 wanted every read on GitHub: $(prcalls)"
[ "$(prr_gets)" = 0 ] && ok || bad "L6 knob 0 wanted 0 GET /api/pr-records, got $(prr_gets)"

# ── Budget: nothing left the box ───────────────────────────────────────────
ESC=$(cat "$T"/c-*/escapes.log 2>/dev/null)
[ -z "$ESC" ] && ok || bad "Budget: a call left the fixture worker: $ESC"

echo "pr-owner-sweep-pr-record: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
