#!/bin/bash
# tests/alerts-groom-component.bh-6971-test.sh — bin/alerts-groom.sh stamps the
# component on every open alerts row that has none (BH-6971, BH-6546.1).
#
# Runs the REAL bin/alerts-groom.sh with only its harness root rewritten, over
# the REAL bin/jobs-client.sh + bin/lib/jobs/*.sh, bin/lib/alert-state.sh,
# bin/component-of.sh and catalog/components.tsv. Only curl is stubbed (the jobs
# worker and the console), as in tests/alerts-groom-db.bh-2526-test.sh. The
# assertions are what the groomer SENT and what it LOGGED.
#
#   G1 three open rows with no component -> ONE POST with those ids and their
#      components (unowned included); nothing resolves, moves or claims a row.
#   G2 a stamped row is not re-read: the read is unstamped=1, and an empty read
#      posts nothing.
#   G3 the logged count is the worker's `stamped`, never the number sent; a 500
#      logs rc= and stamped 0 and the groom still exits 0.
#   G4 the knob: 1 reads limit=1, 0 is off, `abc` is skipped with one line.
#   G5 flags/alerts-db absent: no read, no stamp.
#   G6 more than 200 rows go in chunks of at most 200; the log sums the chunks.
#   G7 a bad catalog logs `catalog invalid` with the line and posts nothing.
#
# Run from anywhere: tests/alerts-groom-component.bh-6971-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "alerts-groom-component.bh-6971: jq missing, cannot run"; exit 1; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" "$H/catalog" \
         "$T/fakebin" "$T/fix"
printf 'CONSOLE_URL=https://console.invalid\nJOBS_URL=https://jobs.invalid\nHARNESS_SECRET=testsecret\nJOBS_RETRIES=0\n' \
  > "$H/env/global.env"

sed "s|/root/harness|$H|g" "$DIR/bin/alerts-groom.sh" > "$H/bin/alerts-groom.sh"; chmod +x "$H/bin/alerts-groom.sh"
cp "$DIR/bin/component-of.sh" "$H/bin/"; chmod +x "$H/bin/component-of.sh"
cp "$DIR/catalog/components.tsv" "$H/catalog/"
# The REAL client and the alerts-db gate, with every bin/lib file they source.
for s in bin/jobs-client.sh bin/lib/alert-state.sh; do
  ( cd "$DIR" && scratch_install_closure "$s" "$H" ) >/dev/null || { echo "setup: could not install $s"; exit 1; }
done
printf '#!/bin/sh\nexit 0\n' > "$H/bin/fleet-projects-or-alert.sh"; chmod +x "$H/bin/fleet-projects-or-alert.sh"
printf '#!/usr/bin/env python3\n' > "$H/bin/alerts-supersede.py"

# --- stubs -------------------------------------------------------------------
# curl: the jobs host speaks the jobs-client wire (body line, then status line);
# the console answers an empty open list, so the console half has nothing to do.
# Every request goes to req.log; every stamp body to stamps.jsonl.
{ echo '#!/bin/bash'; echo "FIX=$T/fix"; echo "OUT=$T"; cat <<'CURLEOF'
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary|-d) BODY="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
printf '%s %s\n' "$METHOD" "$URL" >> "$OUT/req.log"
case "$URL" in
  *jobs.invalid*)
    case "$METHOD $URL" in
      "GET "*/api/alerts\?*unstamped=1*) printf '%s\n200\n' "$(cat "$FIX/unstamped.json")" ;;
      "POST "*/api/alerts/component)
        printf '%s\n' "$BODY" >> "$OUT/stamps.jsonl"
        if [ -r "$FIX/stamp.status" ]; then printf '{"error":"boom"}\n%s\n' "$(cat "$FIX/stamp.status")"
        elif [ -r "$FIX/stamp.json" ]; then printf '%s\n200\n' "$(cat "$FIX/stamp.json")"
        else printf '{"stamped":%s,"as_of":"t"}\n200\n' "$(jq '.stamps | length' <<<"$BODY")"; fi ;;
      *) printf '{"error":"not found"}\n404\n' ;;
    esac ;;
  *console.invalid/api/alerts/open) echo '{"alerts":[]}' ;;
  *) echo '{}' ;;
esac
CURLEOF
} > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"

# --- fixtures ----------------------------------------------------------------
rows() { # rows <id> <line> [<id> <line>...] -> the unstamped GET answer
  local a="[" sep=""
  while [ $# -ge 2 ]; do
    a="$a$sep$(jq -nc --arg i "$1" --arg l "$2" '{id:$i,family:"abcdef012345",box:"hub",project:"",state:"new",count:1,
      first_seen:"2026-10-15T10:00:00Z",last_seen:"2026-10-15T10:00:00Z",claimed_by:null,claimed_at:null,
      notified_at:null,severity:"warn",line:$l,component:null}')"
    sep=","; shift 2
  done
  printf '{"alerts":%s],"truncated":false,"as_of":"t"}' "$a" > "$T/fix/unstamped.json"
}
reset() {
  rm -f "$T/req.log" "$T/stamps.jsonl" "$T/fix/stamp.json" "$T/fix/stamp.status"
  : > "$T/req.log"; : > "$H/logs/alerts-groom.log"
  touch "$H/flags/alerts-db"
}
GRC=0
groom() { PATH="$T/fakebin:$PATH" bash "$H/bin/alerts-groom.sh" >/dev/null 2>&1; GRC=$?; }
glog() { cat "$H/logs/alerts-groom.log" 2>/dev/null; }
reqs() { cat "$T/req.log" 2>/dev/null; }
stamps() { jq -c '.stamps[] | [.id, .component]' "$T/stamps.jsonl" 2>/dev/null; }
posts() { grep -c '^POST .*/api/alerts/component$' "$T/req.log"; }

MC='[merge-conductor] HEAD_MOVED example-org/cromford#1 head moved after review'
COST='[cost-rollup] NEW UNPRICED PAIR(S): openrouter/x; the cost ledger stores these as NULL'
UNK='[some-new-lane] something broke'

# ---- G1 open rows with no component get one ------------------------------------
reset; rows a1 "$MC" a2 "$COST" a3 "$UNK"
groom
[ "$GRC" = 0 ] && ok || bad "G1 groom rc must be 0, got $GRC"
grep -E '^GET .*/api/alerts\?' <(reqs) | grep 'unstamped=1' | grep -E 'state=(!|%21)resolved' | grep -q 'limit=200' \
  && ok || bad "G1 the read must be state=!resolved, unstamped=1, limit=200 (requests: $(reqs))"
[ "$(posts)" = 1 ] && ok || bad "G1 want ONE stamp POST, got $(posts)"
[ "$(stamps | tr '\n' ' ')" = '["a1","merge-conductor"] ["a2","cost"] ["a3","unowned"] ' ] \
  && ok || bad "G1 stamp body: $(stamps | tr '\n' ' ')"
grep -qE '/api/alerts/(resolve|state|claim|flush)' <(reqs) && bad "G1 the stamp step must not decide on an alert (requests: $(reqs))" || ok
grep -q 'component stamp: read 3 stamped 3 unowned 1$' <(glog) && ok || bad "G1 log: $(glog)"

# ---- G2 a stamped row is not re-read ---------------------------------------------
# The worker answers only the rows still NULL: a1 and a2 are stamped, a3 stays
# (here a fresh row b1 arrived instead). Then an empty read posts nothing.
reset; rows b1 "$MC"
groom
[ "$(stamps | tr '\n' ' ')" = '["b1","merge-conductor"] ' ] && ok || bad "G2 only the unstamped row is posted: $(stamps | tr '\n' ' ')"
reset; rows
groom
[ "$(posts)" = 0 ] && ok || bad "G2 an empty read must post nothing, got $(posts)"
grep -q 'component stamp: read 0 stamped 0 unowned 0$' <(glog) && ok || bad "G2 empty log: $(glog)"

# ---- G3 the count is the worker's ------------------------------------------------
reset; rows c1 "$MC" c2 "$COST"; echo '{"stamped":1,"as_of":"t"}' > "$T/fix/stamp.json"
groom
grep -q 'component stamp: read 2 stamped 1 unowned 0$' <(glog) && ok || bad "G3 log must carry the worker's count 1: $(glog)"
reset; rows c1 "$MC" c2 "$COST"; echo 500 > "$T/fix/stamp.status"
groom
[ "$GRC" = 0 ] && ok || bad "G3 a failed stamp must not fail the groom, rc $GRC"
grep -qE 'component stamp: rc=[1-9][0-9]* \(stamp\), stamped 0$' <(glog) && ok || bad "G3 500 log: $(glog)"
grep -q 'component stamp: read' <(glog) && bad "G3 a failed stamp must not log a read/stamped line: $(glog)" || ok

# ---- G4 the knob -----------------------------------------------------------------
reset; rows d1 "$MC"
ALERTS_GROOM_COMPONENT_MAX=1 groom
grep 'unstamped=1' <(reqs) | grep -qE '[?&]limit=1(&|$)' && ok || bad "G4 MAX=1 must read limit=1 (requests: $(reqs))"
reset; rows d1 "$MC"
ALERTS_GROOM_COMPONENT_MAX=0 groom
grep -q 'unstamped=1' <(reqs) && bad "G4 MAX=0 must not read (requests: $(reqs))" || ok
[ "$(posts)" = 0 ] && ok || bad "G4 MAX=0 must not post"
grep -q 'component stamp' <(glog) && bad "G4 MAX=0 is off and logs nothing: $(glog)" || ok
reset; rows d1 "$MC"
ALERTS_GROOM_COMPONENT_MAX=abc groom
grep -q 'unstamped=1' <(reqs) && bad "G4 MAX=abc must not read (requests: $(reqs))" || ok
grep -q 'component stamp skipped: ALERTS_GROOM_COMPONENT_MAX=abc is not a whole number' <(glog) && ok || bad "G4 abc log: $(glog)"

# ---- G5 no flags/alerts-db, no stamp -----------------------------------------------
reset; rm -f "$H/flags/alerts-db"; rows e1 "$MC"
groom
grep -q 'unstamped=1' <(reqs) && bad "G5 without flags/alerts-db there is no read (requests: $(reqs))" || ok
[ "$(posts)" = 0 ] && ok || bad "G5 without flags/alerts-db there is no POST"

# ---- G6 more than 200 rows go in chunks ------------------------------------------
reset
args=(); for i in $(seq 1 250); do args+=("f$i" "$MC"); done; rows "${args[@]}"
ALERTS_GROOM_COMPONENT_MAX=250 groom
[ "$(posts)" = 2 ] && ok || bad "G6 250 stamps must be 2 POSTs, got $(posts)"
[ "$(jq -c '.stamps | length' "$T/stamps.jsonl" | tr '\n' ' ')" = '200 50 ' ] && ok || bad "G6 chunk sizes: $(jq -c '.stamps | length' "$T/stamps.jsonl" | tr '\n' ' ')"
grep -q 'component stamp: read 250 stamped 250 unowned 0$' <(glog) && ok || bad "G6 log: $(glog)"

# ---- G7 a bad catalog posts nothing -------------------------------------------------
reset; rows g1 "$MC"
printf 'merge-conductor\t^x\tmerge-conductor\n' > "$T/bad.tsv"
COMPONENTS_TSV="$T/bad.tsv" groom
[ "$(posts)" = 0 ] && ok || bad "G7 a bad catalog must post nothing"
grep -q 'component stamp: catalog invalid: component-of: bad.tsv:1: want 5 tab-separated fields' <(glog) && ok || bad "G7 log: $(glog)"

echo "alerts-groom-component.bh-6971: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
