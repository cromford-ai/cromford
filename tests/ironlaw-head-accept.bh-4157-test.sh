#!/bin/bash
# tests/ironlaw-head-accept.bh-4157-test.sh — the head-bound iron-law ACCEPT as
# a jobs-DB row (BH-4157 slice C0).
#
# WHAT IS UNDER TEST. bin/lib/ironlaw-carry.sh's ila_key / ila_accepted / ila_put
# read and write one `ironlaw-head-accept` ledger row per accepted head. The
# conductor and the merge sweep unpark a head only on such a row; the resolver
# and the family carry write the row and no marker file (BH-7804). The
# three lanes are DRIVEN against a stub `curl` that serves /api/ledger and
# /api/ledger/claim from a directory, so every assertion is a row or a log line
# a real run wrote.
#
# Sections:
#   L1-L9   the lib, sourced over the real jobs client
#   R1      ila_put then ila_accepted; the first ACCEPT stands
#   C1-C5   the conductor tick
#   S1-S3   the merge sweep
#   W1-W3   the resolver's ACCEPT arm and the family carry write the row
#   N       every new source is named here (the orphan ratchet), and the worker
#           and console node suites run when node can run them
#   N1      the claim body ila_put sent in R1, replayed through the real
#           POST /api/ledger/claim: claimed, then write-once
# Run: HARNESS_TEST_SANDBOX=1 bash tests/ironlaw-head-accept.bh-4157-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# The worker imports these generated, git-ignored catalogs (section N).
"$DIR/bin/lanes-build.sh" --root "$DIR" --write >/dev/null || { echo "FAIL: cannot write catalog/lanes.json"; exit 1; }
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
"$DIR/bin/context-budgets-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/context-budgets.json"; exit 1; }
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: ironlaw-head-accept.bh-4157-test: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v sha1sum >/dev/null || { echo "sha1sum missing — skipping"; exit 0; }

LIB="$DIR/bin/lib/ironlaw-carry.sh"
FIX="$DIR/tests/fixtures/bh-4157/head-accept.json"
for SRC in "$LIB" "$FIX" "$DIR/bin/merge-conductor.sh" "$DIR/bin/merge-sweep.sh" \
           "$DIR/bin/merge-conductor.d/bh-4157-ironlaw-accept.sh" \
           "$DIR/bin/blocked-resolver.sh" "$DIR/bin/lib/br/opt/family.sh" \
           "$DIR/worker/jobs/src/routes/ironlaw-accept.js" \
           "$DIR/worker/jobs/test/route-table.d/bh-4157-ironlaw-accept.txt" \
           "$DIR/worker/jobs/test/ironlaw-accept.bh-4157.test.js" \
           "$DIR/worker/jobs/test/ironlaw-accept-indexes.bh-4157.test.js" \
           "$DIR/console-ui/functions/_lib/coord-writes.d/7581-ironlaw-accept.js" \
           "$DIR/console-ui/src/ui/IronLawHold.js" "$DIR/console-ui/src/api.js" \
           "$DIR/console-ui/src/screens/PR.js" \
           "$DIR/console-ui/tests/ironlaw-hold.bh-4157.test.js"; do
  [ -r "$SRC" ] && ok || bad "missing $SRC"
done

SHA_A=aaaaaaaa11111111111111111111111111111111
SHA_B=$(jq -r .head "$FIX")
FIX_URL=$(jq -r .url "$FIX")
FIX_KEY=$(jq -r .key "$FIX")
DIFF_HIT() { printf '+++ b/src/ui.js\n@@ -1,0 +1,2 @@\n+const a = 1;\n+if (window.confirm("delete?")) go();\n'; }
DIFF_CLEAN() { printf '+++ b/src/ui.js\n@@ -1,0 +1,1 @@\n+const a = 1;\n'; }

# ---- the ledger stub -------------------------------------------------------
# One file per (kind, key) under $L. Switches, each a file in $L:
#   get-503 / get-empty   the ironlaw-head-accept GET answers 503 / a 2xx {}
#   claim-503             the ironlaw-head-accept claim answers 503
# gets.log has one line per ironlaw-head-accept GET; puts.log every PUT body
# (the conductor's mc-merge-verdict lands there); claims.log every claim body.
L="$T/ledger"; mkdir -p "$L"
mkcurl() { # mkcurl <fakebin>
  cat > "$1/curl" <<EOF
#!/bin/bash
L="$L"
EOF
  cat >> "$1/curl" <<'EOF'
M=GET; BODY=""; URL=""
while [ $# -gt 0 ]; do case "$1" in
  -X) M="$2"; shift 2 ;; --data-binary) BODY="$2"; shift 2 ;;
  -m|--connect-timeout|-w|-H) shift 2 ;; -*) shift ;; *) URL="$1"; shift ;; esac; done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
fname() { printf '%s\t%s' "$1" "$2" | sha1sum | cut -c1-40; }
case "$URL" in
  */api/ledger/claim)
    k=$(printf '%s' "$BODY" | jq -r .kind); key=$(printf '%s' "$BODY" | jq -r .key)
    printf '%s\n' "$BODY" >> "$L/claims.log"
    # The contract worker/jobs/src/routes/ledger.js POST /api/ledger/claim
    # holds: kind, key, status non-empty; stale_s an integer in 30..86400;
    # terminal (when sent) an array of at most 8 non-empty strings. Else 400.
    printf '%s' "$BODY" | jq -e '
      (.kind // "" | type == "string" and length > 0)
      and (.key // "" | type == "string" and length > 0)
      and (.status // "" | type == "string" and length > 0)
      and (.stale_s | type == "number" and . == floor and . >= 30 and . <= 86400)
      and (if has("terminal") then (.terminal | type == "array" and length <= 8
            and all(.[]; type == "string" and length > 0)) else true end)' >/dev/null 2>&1 \
      || { printf '{"error":"stale_s must be an integer from 30 to 86400"}\n400\n'; exit 0; }
    [ "$k" = ironlaw-head-accept ] && [ -f "$L/claim-503" ] && { printf '{"error":"down"}\n503\n'; exit 0; }
    f="$L/$(fname "$k" "$key").json"
    if [ -f "$f" ]; then printf '{"claimed":false,"ledger":%s}\n200\n' "$(jq -c .ledger "$f")"; exit 0; fi
    printf '%s' "$BODY" | jq -c '{ledger:{kind,key,status,actor:(.actor // null),detail:(.detail // null)}}' > "$f"
    printf '{"claimed":true,"ledger":%s}\n200\n' "$(jq -c .ledger "$f")"; exit 0 ;;
  */api/ledger*) ;;
  *) printf '{"error":"not found"}\n404\n'; exit 0 ;;
esac
if [ "$M" = PUT ]; then
  k=$(printf '%s' "$BODY" | jq -r .kind); key=$(printf '%s' "$BODY" | jq -r .key)
  printf '%s\n' "$BODY" >> "$L/puts.log"
  case "$k" in ironlaw-accept|ironlaw-head-accept)
    printf '%s' "$BODY" | jq -c '{ledger:{kind,key,status,actor:(.actor // null),detail:(.detail // null)}}' > "$L/$(fname "$k" "$key").json" ;;
  esac
  printf '{"ok":true}\n200\n'; exit 0
fi
dec() { printf '%b' "${1//%/\\x}"; }
kind=""; key=""
IFS='&' read -ra parts <<<"${URL#*\?}"
for p in "${parts[@]}"; do case "$p" in kind=*) kind=$(dec "${p#kind=}") ;; key=*) key=$(dec "${p#key=}") ;; esac; done
if [ "$kind" = ironlaw-head-accept ]; then
  printf '%s\n' "$key" >> "$L/gets.log"
  [ -f "$L/get-503" ] && { printf '{"error":"down"}\n503\n'; exit 0; }
  [ -f "$L/get-empty" ] && { printf '{}\n200\n'; exit 0; }
fi
f="$L/$(fname "$kind" "$key").json"
[ -n "$key" ] && [ -f "$f" ] && { cat "$f"; printf '\n200\n'; exit 0; }
printf '{"error":"not found"}\n404\n'
EOF
  chmod +x "$1/curl"
}
ledger_clear() { find "$L" -mindepth 1 -delete 2>/dev/null; mkdir -p "$L"; }
# ROWFILE <kind> <key> <status> <detail-json> — a row exactly as the worker
# answers it (GET /api/ledger?kind&key → {ledger:{…}}).
ROWFILE() {
  jq -nc --arg k "$1" --arg v "$2" --arg s "$3" --arg d "$4" '{ledger:{kind:$k,key:$v,status:$s,actor:"ops@x",detail:$d}}' \
    > "$L/$(printf '%s\t%s' "$1" "$2" | sha1sum | cut -c1-40).json"
}
# CONSOLE_ROW <key> <sha> — the row POST /api/ironlaw-accept writes (its detail
# shape; worker/jobs/test/ironlaw-accept.bh-4157.test.js pins the same shape).
CONSOLE_ROW() {
  ROWFILE ironlaw-head-accept "$1" accepted \
    "$(jq -nc --arg s "$2" '{sha:$s,source:"console",reason:"read the lines, fixture",actor:"ops@x"}')"
}
hacc_rows() { grep -l '"ironlaw-head-accept"' "$L"/*.json 2>/dev/null | wc -l | tr -d ' '; }
ngets() { if [ -f "$L/gets.log" ]; then grep -c . "$L/gets.log"; else echo 0; fi; }
JENV=(HARNESS_SECRET=fixture-secret JOBS_URL=http://jobs.test JOBS_RETRIES=0)

# fixture: tests/lib/fixture-harness.sh (BH-1196).
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1

# ============================================================================
# C fixture — the conductor's scratch harness ($T/c).
# ============================================================================
C="$T/c"; CH="$C/h"
fx_mc_harness "$DIR" "$C" || exit 1
fx_conductor_tick "$DIR" "$C" || exit 1
# The lib under test only: the conductor's whole closure brings the App-token
# libs, and this fixture answers the default-PAT reads the others are built on.
( cd "$DIR" && scratch_install_closure bin/lib/ironlaw-carry.sh "$CH" >/dev/null ) || exit 1
# The conductor's DB-ACCEPT reader is a BH-7453 fragment; the fixture tree has
# no bin/merge-conductor.d/, so install this one.
mkdir -p "$CH/bin/merge-conductor.d" && cp "$DIR/bin/merge-conductor.d/bh-4157-ironlaw-accept.sh" "$CH/bin/merge-conductor.d/" || exit 1
mkcurl "$C/fakebin"
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$CH/fleet.conf"
: > "$CH/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$CH/bin/agent-call.sh"; chmod +x "$CH/bin/agent-call.sh"
CREC="$CH/builds/demo-os-TK-11-202610190001"
mkdir -p "$CREC"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/11" > "$CREC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$CREC/review.md"
echo "$SHA_B" > "$CREC/reviewed-sha"
cat > "$C/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$C/gh-calls.txt"
case "\$*" in
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*)
    echo "WRITE VERB: \$*" >> "$C/gh-writes.txt"; exit 1 ;;
  *"v3.diff"*) restpr --diff "\$(cat "$C/prdiff" 2>/dev/null)" ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/11"*) restpr OPEN "$SHA_B" "ticket/TK-11" main "" ;;
  *"pr list -R example-org/demo-os --state open"*) cat "$C/openlist" ;;
  *"pulls?state=closed"*) restpr --raw 200 '[]' ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n' | restpr --runs - ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$C/fakebin/gh"
jq -nc --arg h "$SHA_B" '[{number:11,url:"https://github.com/example-org/demo-os/pull/11",headRefOid:$h,headRefName:"ticket/TK-11",baseRefName:"main",isDraft:false,mergeStateStatus:"CLEAN",mergeable:"MERGEABLE",state:"OPEN",updatedAt:"2026-10-19T10:00:00Z"}]' > "$C/openlist"
tick() {
  ( cd "$C" && PATH="$C/fakebin:$PATH" GH_LIST_BRIDGE_ROOT="$C" HARNESS="$CH" MC_MAIN_RED_DETECT=0 \
      env "${JENV[@]}" bash "$CH/bin/merge-conductor.sh" >/dev/null 2>>"$C/tick.err" ) || true
}
cfresh() {
  scratch_rm "$CH/state"; scratch_rm "$CH/logs"; scratch_rm "$CH/locks"
  mkdir -p "$CH/state" "$CH/logs" "$CH/locks"
  : > "$C/gh-calls.txt"; : > "$C/gh-writes.txt"
  rm -f "$CREC"/iron-law-accepted-*
  ledger_clear
}
clog() { cat "$CH/logs/merge-conductor.log" 2>/dev/null; }
crow() { awk -F'\t' -v k="$1" '$1==k' "$CH/state/merge-conductor/pr-state.tsv" 2>/dev/null; }
# The last mc-merge-verdict the tick published: "<status> <detail>".
cverdict() { jq -r 'select(.kind=="mc-merge-verdict") | .status + " " + .detail' "$L/puts.log" 2>/dev/null | tail -1; }
URL11=https://github.com/example-org/demo-os/pull/11
KEY11="example-org/demo-os#11@$SHA_B"

# ============================================================================
# L. the lib, sourced, over the real jobs client and the ledger stub
# ============================================================================
(
  export HARNESS="$CH" PATH="$C/fakebin:$PATH"; export "${JENV[@]}"
  . "$CH/bin/jobs-client.sh" || exit 9
  . "$LIB" || exit 9
  F=0; no() { F=$((F+1)); echo "FAIL: ironlaw-head-accept.bh-4157-test: $1"; }
  # L0 the key: the shared fixture's url and head build the shared fixture's key.
  [ "$(ila_key "$FIX_URL" "$SHA_B")" = "$FIX_KEY" ] || no "L0 ila_key of the fixture (got '$(ila_key "$FIX_URL" "$SHA_B")', want '$FIX_KEY')"
  # L1 an accepted row for the head: rc 0, prints the actor.
  ledger_clear; CONSOLE_ROW "$KEY11" "$SHA_B"
  O=$(ila_accepted "$URL11" "$SHA_B"); rc=$?
  [ "$rc" = 0 ] && [ "$O" = ops@x ] || no "L1 accepted row must be rc 0 printing ops@x (rc $rc: '$O')"
  # L2 no row (404): rc 1.
  ledger_clear
  ila_accepted "$URL11" "$SHA_B" >/dev/null; rc=$?
  [ "$rc" = 1 ] || no "L2 no row must be rc 1 (rc $rc)"
  # L3 a row for another sha: rc 1, both at its own key and (hand-made) under this key.
  ledger_clear; CONSOLE_ROW "example-org/demo-os#11@$SHA_A" "$SHA_A"
  ila_accepted "$URL11" "$SHA_B" >/dev/null; rc=$?
  [ "$rc" = 1 ] || no "L3a the previous head's row must be rc 1 (rc $rc)"
  ledger_clear; CONSOLE_ROW "$KEY11" "$SHA_A"
  ila_accepted "$URL11" "$SHA_B" >/dev/null; rc=$?
  [ "$rc" = 1 ] || no "L3b a row whose detail.sha is another head must be rc 1 (rc $rc)"
  # L4 detail unparseable: rc 2.
  ledger_clear; ROWFILE ironlaw-head-accept "$KEY11" accepted 'not json{'
  ila_accepted "$URL11" "$SHA_B" >/dev/null; rc=$?
  [ "$rc" = 2 ] || no "L4 an unparseable detail must be rc 2 (rc $rc)"
  # L4b a row with another status: never accepted.
  ledger_clear; ROWFILE ironlaw-head-accept "$KEY11" revoked "$(jq -nc --arg s "$SHA_B" '{sha:$s}')"
  ila_accepted "$URL11" "$SHA_B" >/dev/null; rc=$?
  [ "$rc" != 0 ] || no "L4b a row with status revoked must not be rc 0"
  # L5 a 503: rc 2.
  ledger_clear; CONSOLE_ROW "$KEY11" "$SHA_B"; : > "$L/get-503"
  ila_accepted "$URL11" "$SHA_B" >/dev/null; rc=$?
  [ "$rc" = 2 ] || no "L5 a 503 must be rc 2 (rc $rc)"
  # L6 a 2xx with no .ledger.status: rc 2.
  ledger_clear; CONSOLE_ROW "$KEY11" "$SHA_B"; : > "$L/get-empty"
  ila_accepted "$URL11" "$SHA_B" >/dev/null; rc=$?
  [ "$rc" = 2 ] || no "L6 a 2xx with no row status must be rc 2 (rc $rc)"
  # L7 the repo case: an upper-case url reads the lower-case row.
  ledger_clear; CONSOLE_ROW "$KEY11" "$SHA_B"
  ila_accepted https://github.com/example-org/Demo-OS/pull/11 "$SHA_B" >/dev/null; rc=$?
  [ "$rc" = 0 ] || no "L7 an upper-case repo url must read the same key (rc $rc)"
  # L8 a 39-char or upper-case head: rc 2 and no request.
  ledger_clear
  ila_accepted "$URL11" "${SHA_B:0:39}" >/dev/null; rc=$?
  [ "$rc" = 2 ] || no "L8 a 39-char head must be rc 2 (rc $rc)"
  ila_accepted "$URL11" "$(printf '%s' "$SHA_B" | tr 'a-f' 'A-F')" >/dev/null; rc=$?
  [ "$rc" = 2 ] || no "L8 an upper-case head must be rc 2 (rc $rc)"
  [ "$(ngets)" = 0 ] || no "L8 a bad head must make no request ($(ngets) GETs)"
  ila_accepted https://github.com/example-org/demo-os/issues/11 "$SHA_B" >/dev/null; rc=$?
  [ "$rc" = 2 ] || no "L8 a non-PR url must be rc 2 (rc $rc)"
  # L9 a BH-4474 fingerprint row for this PR is not a head ACCEPT.
  ledger_clear
  ROWFILE ironlaw-accept "example-org/demo-os#11|$(printf x | sha1sum | cut -c1-40)" accepted "$(jq -nc --arg s "$SHA_B" '{sha:$s,rule:"redflag:window.confirm(",path:"src/ui.js",n:1}')"
  ila_accepted "$URL11" "$SHA_B" >/dev/null; rc=$?
  [ "$rc" = 1 ] || no "L9 a fingerprint row must be rc 1 (rc $rc)"
  # R1 ila_put then ila_accepted; a second put leaves the first detail.
  ledger_clear
  JOBS_BOX=box-fixture ila_put "$URL11" "$SHA_B" resolver "adjudicated ACCEPT"; rc=$?
  [ "$rc" = 0 ] || no "R1 ila_put must be rc 0 (rc $rc)"
  [ "$(hacc_rows)" = 1 ] || no "R1 one row written (got $(hacc_rows))"
  # The exact claim body ila_put sent; section N replays it through the real worker.
  jq -c 'select(.kind=="ironlaw-head-accept")' "$L/claims.log" | head -1 > "$T/ila-claim-body.json"
  [ -s "$T/ila-claim-body.json" ] || no "R1 the claim body was captured"
  O=$(ila_accepted "$URL11" "$SHA_B"); rc=$?
  [ "$rc" = 0 ] && [ "$O" = box-fixture ] || no "R1 round trip rc 0 naming box-fixture (rc $rc: '$O')"
  JOBS_BOX=box-other ila_put "$URL11" "$SHA_B" family "a later carry"; rc=$?
  [ "$rc" = 0 ] || no "R1 a second put on a held key is rc 0 (rc $rc)"
  D=$(jq -r 'select(.ledger.kind=="ironlaw-head-accept") | .ledger.detail' "$L"/*.json | jq -r .source)
  [ "$D" = resolver ] || no "R1 the first ACCEPT stands (source '$D')"
  ila_put "$URL11" "${SHA_B:0:39}" resolver x; rc=$?
  [ "$rc" = 1 ] || no "R1 a bad head writes nothing, rc 1 (rc $rc)"
  ledger_clear; : > "$L/claim-503"
  ila_put "$URL11" "$SHA_B" resolver x; rc=$?
  [ "$rc" = 1 ] && [ "$(hacc_rows)" = 0 ] || no "R1 a claim outage is rc 1, no row (rc $rc, rows $(hacc_rows))"
  exit "$F"
); URC=$?
[ "$URC" = 0 ] && ok || bad "L/R: $URC lib case(s) failed"
ledger_clear

# ============================================================================
# C. the conductor, driven
# ============================================================================
# C1 — two hits on head B, NO marker file, a console ACCEPT row for B.
cfresh; DIFF_HIT > "$C/prdiff"; CONSOLE_ROW "$KEY11" "$SHA_B"
tick
[ "$(clog | grep -c "ACCEPTED in the DB by ops@x — not parking")" = 1 ] && ok \
  || bad "C1 one 'ACCEPTED in the DB' line (log: $(clog | grep -i iron | tail -3); err: $(tail -3 "$C/tick.err" 2>/dev/null))"
[ "$(cverdict)" = "clear $SHA_B iron-law scan clean" ] && ok || bad "C1 the verdict publishes clear for B (got '$(cverdict)')"
grep -q 'iron-law' <<<"$(crow 'example-org/demo-os#11')" && bad "C1 must not park on iron-law ($(crow 'example-org/demo-os#11'))" || ok
[ -z "$(find "$C" -name 'iron-law-accepted-*' 2>/dev/null)" ] && ok || bad "C1 no marker file anywhere ($(find "$C" -name 'iron-law-accepted-*'))"
[ -z "$(find "$CH/state" -type f -newer "$C/prdiff" -path '*iron*' 2>/dev/null)" ] && ok || bad "C1 the read writes no iron state file"

# C2 — the ACCEPT row is for the previous head A: parks.
cfresh; DIFF_HIT > "$C/prdiff"; CONSOLE_ROW "example-org/demo-os#11@$SHA_A" "$SHA_A"
tick
grep -q 'ACCEPTED in the DB' <<<"$(clog)" && bad "C2 an older head's row must not unpark" || ok
case "$(cverdict)" in "hold $SHA_B iron-law: "*) ok ;; *) bad "C2 the verdict holds B on iron-law (got '$(cverdict)')" ;; esac

# C3 — the ledger answers 503: parks, one UNVERIFIABLE line.
cfresh; DIFF_HIT > "$C/prdiff"; CONSOLE_ROW "$KEY11" "$SHA_B"; : > "$L/get-503"
tick
[ "$(clog | grep -c "iron-law: DB accept UNVERIFIABLE on ${SHA_B:0:8}")" = 1 ] && ok \
  || bad "C3 one UNVERIFIABLE line (log: $(clog | grep -i iron | tail -3))"
case "$(cverdict)" in "hold $SHA_B iron-law: "*) ok ;; *) bad "C3 an outage holds (got '$(cverdict)')" ;; esac

# C4 — a legacy marker file is present and the DB is down: parks. Since
# BH-7804 no lane reads the file; the DB row is the only ACCEPT.
cfresh; DIFF_HIT > "$C/prdiff"; : > "$CREC/iron-law-accepted-$SHA_B"; : > "$L/get-503"
tick
grep -q 'ADJUDICATED ACCEPT by the blocked-resolver' <<<"$(clog)" && bad "C4 the file marker is not read ($(clog | grep -i 'ADJUDICATED'))" || ok
[ "$(clog | grep -c "iron-law: DB accept UNVERIFIABLE on ${SHA_B:0:8}")" = 1 ] && ok || bad "C4 the DB is asked: one UNVERIFIABLE line (log: $(clog | grep -i iron | tail -3))"
case "$(cverdict)" in "hold $SHA_B iron-law: "*) ok ;; *) bad "C4 a marker file with the DB down holds (got '$(cverdict)')" ;; esac

# C5 — no hits: no ironlaw-head-accept GET at all.
cfresh; DIFF_CLEAN > "$C/prdiff"
tick
[ "$(ngets)" = 0 ] && ok || bad "C5 a clean head makes no accept read ($(ngets) GETs)"
[ "$(cverdict)" = "clear $SHA_B iron-law scan clean" ] && ok || bad "C5 clear (got '$(cverdict)')"
[ -s "$C/gh-writes.txt" ] && bad "no conductor case may write to GitHub ($(cat "$C/gh-writes.txt"))" || ok

# ============================================================================
# W / S fixture — the resolver family's scratch harness ($T/h).
# ============================================================================
H="$T/h"; mkdir -p "$H/bin"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-sweep.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
# The sweep's own modules (BH-5242), the jobs client, the lib under test and the
# family carry module: what tests/mc/iron-law-carry.bh-4474-test.sh installs,
# plus family.sh, through the closure helper.
( cd "$DIR" && for m in bin/lib/ms/*.sh bin/jobs-client.sh bin/lib/ironlaw-carry.sh bin/lib/br/opt/family.sh; do
    scratch_install_closure "$m" "$H" >/dev/null || exit 1
  done ) || exit 1
# The BH-7804 fragment keeps an ACCEPT the DB could not take (W2).
mkdir -p "$H/bin/blocked-resolver.d" && cp "$DIR/bin/blocked-resolver.d/bh-7804-ila-pending.sh" "$H/bin/blocked-resolver.d/" || exit 1
mkcurl "$T/fakebin"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf 'call %s\n' "\$*" >> "$T/agent.txt"
printf 'the reasoning\n%s\n' "\${ADJ_VERDICT:-REJECT}" > "\$5"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
REC="$H/builds/tproj-TK-9-202610190001"; mkdir -p "$REC"
URL9=https://github.com/o/tproj/pull/9
printf 'PR_CREATED %s\n' "$URL9" > "$REC/RESULT"
printf 'findings\nVERDICT: APPROVE\n' > "$REC/review.md"
blog() { cat "$H/logs/blocked-resolver.log" 2>/dev/null; }
claims() { jq -c 'select(.kind=="ironlaw-head-accept")' "$L/claims.log" 2>/dev/null; }
adjs() { jq -r '.adjudications // 0' "$H/state/blocked-resolver/tproj/"*.json 2>/dev/null | head -1; }
wfresh() {
  ledger_clear; scratch_rm "$H/state/blocked-resolver"; : > "$H/logs/blocked-resolver.log"
  rm -f "$REC"/iron-law-accepted-* "$T/agent.txt"
}

# W1 — the resolver's ADJUDICATED ACCEPT on head A: one DB row, no marker file.
wfresh; DIFF_HIT > "$T/prdiff"; printf '%s' "$SHA_A" > "$T/prhead"
ROW "o/tproj#9" "iron-law (1 hit(s))" "$URL9"
BRENV=(ADJ_VERDICT=ACCEPT JOBS_BOX=box-fixture "${JENV[@]}")
RUN
[ ! -e "$REC/iron-law-accepted-$SHA_A" ] && ok || bad "W1 no marker file is written (BH-7804) (log: $(blog | tail -3))"
[ "$(claims | jq -r .key)" = "o/tproj#9@$SHA_A" ] && ok || bad "W1 one claim keyed o/tproj#9@A (got '$(claims)')"
[ "$(claims | jq -r '.detail | fromjson | .source + " " + .sha')" = "resolver $SHA_A" ] && ok || bad "W1 detail source resolver, sha A ($(claims))"
[ "$(hacc_rows)" = 1 ] && ok || bad "W1 one ironlaw-head-accept row (got $(hacc_rows))"
blog | grep -q 'DB accept recorded' && ok || bad "W1 the recorded line (log: $(blog | grep -i iron | tail -3))"
W1ADJ=$(adjs)
W1CALLS=$(grep -c . "$T/agent.txt" 2>/dev/null)

# W2 — the DB claim fails: no marker, the ACCEPT kept as pending in the record,
# the counters match W1's.
wfresh; : > "$L/claim-503"
ROW "o/tproj#9" "iron-law (1 hit(s))" "$URL9"
RUN
[ ! -e "$REC/iron-law-accepted-$SHA_A" ] && ok || bad "W2 no marker file is written (BH-7804) (log: $(blog | tail -3))"
blog | grep -q 'DB accept NOT recorded; kept as pending in the record' && ok || bad "W2 the kept-as-pending line (log: $(blog | grep -i iron | tail -3))"
[ "$(jq -r '.ila_pending.head // empty' "$H/state/blocked-resolver/tproj/"*.json 2>/dev/null | head -1)" = "$SHA_A" ] && ok \
  || bad "W2 .ila_pending.head is A in the record ($(jq -c .ila_pending "$H/state/blocked-resolver/tproj/"*.json 2>/dev/null))"
[ "$(hacc_rows)" = 0 ] && ok || bad "W2 no row (got $(hacc_rows))"
[ -n "$W1ADJ" ] && [ "$(adjs)" = "$W1ADJ" ] && ok || bad "W2 the adjudication count matches W1 ($(adjs) vs $W1ADJ)"
[ "$(grep -c . "$T/agent.txt" 2>/dev/null)" = "$W1CALLS" ] && ok || bad "W2 the same model calls as W1, no re-buy ($(grep -c . "$T/agent.txt" 2>/dev/null) vs $W1CALLS)"
[ "$(blog | grep -c 'ADJUDICATED ACCEPT')" = 1 ] && ok || bad "W2 one ADJUDICATED ACCEPT ($(blog | grep -c 'ADJUDICATED ACCEPT'))"

# W3 — the family carry: the store from W2's ruling carries to head B with a DB row.
ledger_clear; rm -f "$REC"/iron-law-accepted-* "$T/agent.txt"
find "$H/state/blocked-resolver" -mindepth 1 -maxdepth 1 ! -name '.families' -exec rm -rf {} + 2>/dev/null
: > "$H/logs/blocked-resolver.log"
printf '%s' "$SHA_B" > "$T/prhead"
ROW "o/tproj#9" "iron-law (1 hit(s))" "$URL9"
RUN
if blog | grep -q 'CARRIED family'; then
  ok
  [ ! -e "$REC/iron-law-accepted-$SHA_B" ] && ok || bad "W3 the carry writes no marker file on B (BH-7804)"
  [ "$(claims | jq -r '.key + " " + (.detail | fromjson | .source)')" = "o/tproj#9@$SHA_B family" ] && ok \
    || bad "W3 one family claim on B (got '$(claims)')"
  [ -s "$T/agent.txt" ] && bad "W3 a carry buys no model call" || ok
else
  bad "W3 the family carry ran (log: $(blog | grep -i 'family\|iron' | tail -4))"
fi
BRENV=()

# ============================================================================
# S. the sweep, the second gate
# ============================================================================
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  *"v3.diff"*) restpr --raw 200; cat "$T/prdiff" 2>/dev/null ;;
  *"api -i -X GET repos/o/tproj/pulls/9"*) restpr OPEN "$SHA_B" ticket/TK-9 main "" MERGEABLE CLEAN operator ;;
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/merged.txt"; exit 0 ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
SWEEP() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" env "${JENV[@]}" bash "$H/bin/merge-sweep.sh" >/dev/null 2>&1 ) || true; }
slog() { cat "$H/logs/merge-sweep.log" 2>/dev/null; }
sfresh() { ledger_clear; rm -f "$REC"/iron-law-accepted-*; DIFF_HIT > "$T/prdiff"; : > "$H/state/merge-sweep-done.txt"; : > "$H/logs/merge-sweep.log"; }
# S1 — a DB ACCEPT for head B, no marker: not parked.
sfresh; CONSOLE_ROW "o/tproj#9@$SHA_B" "$SHA_B"
SWEEP
[ "$(slog | grep -c "ACCEPTED in the DB by ops@x — not parking")" = 1 ] && ok || bad "S1 one sweep DB-accept line (log: $(slog | tail -3))"
grep -q 'parked:' <<<"$(slog)" && bad "S1 the sweep must not park an accepted head ($(slog | grep parked:))" || ok
# S2 — the row is for head A: parked.
sfresh; CONSOLE_ROW "o/tproj#9@$SHA_A" "$SHA_A"
SWEEP
slog | grep -q 'parked:' && ok || bad "S2 an older head's row parks (log: $(slog | tail -3))"
grep -q 'ACCEPTED in the DB' <<<"$(slog)" && bad "S2 no DB-accept line" || ok
# S3 — a 503: parked, one UNVERIFIABLE line.
sfresh; CONSOLE_ROW "o/tproj#9@$SHA_B" "$SHA_B"; : > "$L/get-503"
SWEEP
[ "$(slog | grep -c "iron-law: DB accept UNVERIFIABLE on ${SHA_B:0:8}")" = 1 ] && ok || bad "S3 one UNVERIFIABLE line (log: $(slog | tail -3))"
slog | grep -q 'parked:' && ok || bad "S3 an outage parks"

# ============================================================================
# N. the node suites (worker routes + EXPLAIN, console panel + proxy row)
# ============================================================================
if command -v node >/dev/null 2>&1 && node -e 'import("node:sqlite").then(()=>process.exit(0),()=>process.exit(1))' 2>/dev/null; then
  NLOG="$T/worker.log"
  ( cd "$DIR/worker/jobs" && node --test --test-reporter=spec test/ironlaw-accept.bh-4157.test.js test/ironlaw-accept-indexes.bh-4157.test.js ) > "$NLOG" 2>&1
  RC=$?
  NP=$(sed -n 's/^[^ ]* pass \([0-9][0-9]*\)$/\1/p' "$NLOG" | tail -1)
  NS=$(sed -n 's/^[^ ]* skipped \([0-9][0-9]*\)$/\1/p' "$NLOG" | tail -1)
  if [ "$RC" -ne 0 ]; then cat "$NLOG"; bad "worker node --test rc=$RC"
  elif [ -z "$NP" ] || [ "$NP" -eq 0 ] || [ "${NS:-0}" != 0 ]; then cat "$NLOG"; bad "worker: $NP passed, ${NS:-?} skipped"
  else ok; fi
  # N1 the body ila_put sends (captured in R1) through the REAL POST
  # /api/ledger/claim on the composed schema: claimed, then write-once.
  N1=$(cd "$DIR/worker/jobs" && node --input-type=module -e '
    import { readFileSync } from "node:fs";
    const worker = (await import("./src/index.js")).default;
    const { openDb } = await import("./test/lib/d1-sqlite.bh-1030.js");
    const h = await openDb();
    if (h === null) { console.log("no-sqlite"); process.exit(0); }
    const body = readFileSync(process.argv[1], "utf8");
    const send = async (b) => {
      const res = await worker.fetch(new Request("https://jobs.test/api/ledger/claim", {
        method: "POST", body: b,
        headers: { "content-type": "application/json", authorization: "Bearer tok-n1" } }),
        { DB: h.DB, HARNESS_SECRET: "tok-n1" });
      return `${res.status} ${JSON.stringify(await res.json().catch(() => null))}`;
    };
    const first = await send(body);
    const later = JSON.parse(body); later.detail = JSON.stringify({ sha: "x", source: "family" });
    const second = await send(JSON.stringify(later));
    const row = h.db.prepare("SELECT status, detail FROM ledgers WHERE kind=?1").get("ironlaw-head-accept");
    console.log(JSON.stringify({ first, second, status: row?.status, source: row ? JSON.parse(row.detail).source : null }));
  ' "$T/ila-claim-body.json" 2>&1)
  if [ "$N1" = no-sqlite ]; then bad "N1 openDb found no node:sqlite"
  else
    [[ "$(jq -r .first <<<"$N1" 2>/dev/null)" == '200 '*'"claimed":true'* ]] && ok || bad "N1 the real worker claims ila_put's body ($N1)"
    [[ "$(jq -r .second <<<"$N1" 2>/dev/null)" == '200 '*'"claimed":false'* ]] && ok || bad "N1 a second claim is refused ($N1)"
    [ "$(jq -r '.status + " " + .source' <<<"$N1" 2>/dev/null)" = "accepted resolver" ] && ok || bad "N1 the first ACCEPT stands ($N1)"
  fi
else
  echo "ironlaw-head-accept.bh-4157-test: worker suite SKIPPED — no node with node:sqlite"
fi
if command -v node >/dev/null 2>&1 && [ -d "$DIR/console-ui/node_modules/preact" ]; then
  KLOG="$T/console.log"
  ( cd "$DIR/console-ui" && node --test --test-reporter=spec tests/ironlaw-hold.bh-4157.test.js ) > "$KLOG" 2>&1
  RC=$?
  KP=$(sed -n 's/^[^ ]* pass \([0-9][0-9]*\)$/\1/p' "$KLOG" | tail -1)
  if [ "$RC" -ne 0 ]; then cat "$KLOG"; bad "console node --test rc=$RC"
  elif [ -z "$KP" ] || [ "$KP" -eq 0 ]; then cat "$KLOG"; bad "console: 0 tests passed"
  else ok; fi
else
  echo "ironlaw-head-accept.bh-4157-test: console suite SKIPPED — console-ui dependencies are not installed"
fi

echo "ironlaw-head-accept.bh-4157: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
