#!/bin/bash
# tests/ironlaw-file-drop.bh-7804-test.sh — the iron-law ACCEPT is the DB row
# only (BH-7804, slice C4 of #4157).
#
# WHAT IS UNDER TEST. No lane writes or reads `<rec>/iron-law-accepted-<sha>`
# any more. The resolver's ACCEPT arm and the family carry write the
# `ironlaw-head-accept` ledger row; the conductor and the merge sweep unpark a
# head only on that row. When the row cannot be written, the resolver keeps the
# paid ruling as `.ila_pending` in its own record json and retries the write on
# the next tick with no model call (bin/blocked-resolver.d/bh-7804-ila-pending.sh).
# The lanes are DRIVEN against a stub `curl` that serves /api/ledger and
# /api/ledger/claim from a directory, the contract of the BH-4157 suite's stub.
#
# Sections:
#   D1-D4   the conductor and the sweep: a marker file alone no longer unparks
#   R1-R11  the resolver's ACCEPT arm and the pending retry
#   F1-F3   the family carry writes the row, and spends nothing when it cannot
#   G1      no bin/ code writes or tests for the marker file
# Run: HARNESS_TEST_SANDBOX=1 bash tests/ironlaw-file-drop.bh-7804-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: ironlaw-file-drop.bh-7804-test: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v sha1sum >/dev/null || { echo "sha1sum missing — skipping"; exit 0; }

FRAG="$DIR/bin/blocked-resolver.d/bh-7804-ila-pending.sh"
for SRC in "$FRAG" "$DIR/bin/blocked-resolver.sh" "$DIR/bin/lib/br/opt/family.sh" \
           "$DIR/bin/merge-conductor.sh" "$DIR/bin/merge-sweep.sh" "$DIR/bin/lib/ironlaw-carry.sh" \
           "$DIR/bin/merge-conductor.d/bh-4157-ironlaw-accept.sh"; do
  [ -r "$SRC" ] && ok || bad "missing $SRC"
done

SHA_A=aaaaaaaa77777777777777777777777777777777
SHA_B=bbbbbbbb77777777777777777777777777777777
DIFF_HIT() { printf '+++ b/src/ui.js\n@@ -1,0 +1,2 @@\n+const a = 1;\n+if (window.confirm("delete?")) go();\n'; }

# ---- the ledger stub (the BH-4157 suite's contract) -------------------------
# One file per (kind, key) under $L. Switches, each a file in $L:
#   get-503     the ironlaw-head-accept GET answers 503
#   claim-503   the ironlaw-head-accept claim answers 503
# claims.log holds every claim body, puts.log every PUT body.
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
    printf '%s' "$BODY" | jq -e '(.kind // "" | length > 0) and (.key // "" | length > 0)
      and (.stale_s | type == "number" and . >= 30 and . <= 86400)' >/dev/null 2>&1 \
      || { printf '{"error":"bad claim"}\n400\n'; exit 0; }
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
  [ -f "$L/get-503" ] && { printf '{"error":"down"}\n503\n'; exit 0; }
fi
f="$L/$(fname "$kind" "$key").json"
[ -n "$key" ] && [ -f "$f" ] && { cat "$f"; printf '\n200\n'; exit 0; }
printf '{"error":"not found"}\n404\n'
EOF
  chmod +x "$1/curl"
}
ledger_clear() { find "$L" -mindepth 1 -delete 2>/dev/null; mkdir -p "$L"; }
# HROW <key> <sha> — an accepted ironlaw-head-accept row, as the worker answers it.
HROW() {
  jq -nc --arg v "$1" --arg d "$(jq -nc --arg s "$2" '{sha:$s,source:"console",reason:"fixture",actor:"ops@x"}')" \
    '{ledger:{kind:"ironlaw-head-accept",key:$v,status:"accepted",actor:"ops@x",detail:$d}}' \
    > "$L/$(printf '%s\t%s' ironlaw-head-accept "$1" | sha1sum | cut -c1-40).json"
}
JENV=(HARNESS_SECRET=fixture-secret JOBS_URL=http://jobs.test JOBS_RETRIES=0)
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1

# ============================================================================
# The conductor's scratch harness ($T/c), the BH-4157 suite's C fixture.
# ============================================================================
C="$T/c"; CH="$C/h"
fx_mc_harness "$DIR" "$C" || exit 1
fx_conductor_tick "$DIR" "$C" || exit 1
( cd "$DIR" && scratch_install_closure bin/lib/ironlaw-carry.sh "$CH" >/dev/null ) || exit 1
mkdir -p "$CH/bin/merge-conductor.d" && cp "$DIR/bin/merge-conductor.d/bh-4157-ironlaw-accept.sh" "$CH/bin/merge-conductor.d/" || exit 1
mkcurl "$C/fakebin"
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$CH/fleet.conf"
: > "$CH/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$CH/bin/agent-call.sh"; chmod +x "$CH/bin/agent-call.sh"
CREC="$CH/builds/demo-os-TK-11-202610250001"
mkdir -p "$CREC"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/11" > "$CREC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$CREC/review.md"
echo "$SHA_B" > "$CREC/reviewed-sha"
cat > "$C/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
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
jq -nc --arg h "$SHA_B" '[{number:11,url:"https://github.com/example-org/demo-os/pull/11",headRefOid:$h,headRefName:"ticket/TK-11",baseRefName:"main",isDraft:false,mergeStateStatus:"CLEAN",mergeable:"MERGEABLE",state:"OPEN",updatedAt:"2026-10-25T10:00:00Z"}]' > "$C/openlist"
tick() {
  ( cd "$C" && PATH="$C/fakebin:$PATH" GH_LIST_BRIDGE_ROOT="$C" HARNESS="$CH" MC_MAIN_RED_DETECT=0 \
      env "${JENV[@]}" bash "$CH/bin/merge-conductor.sh" >/dev/null 2>>"$C/tick.err" ) || true
}
cfresh() {
  scratch_rm "$CH/state"; scratch_rm "$CH/logs"; scratch_rm "$CH/locks"
  mkdir -p "$CH/state" "$CH/logs" "$CH/locks"
  : > "$C/gh-writes.txt"
  rm -f "$CREC"/iron-law-accepted-*
  ledger_clear
}
clog() { cat "$CH/logs/merge-conductor.log" 2>/dev/null; }
cverdict() { jq -r 'select(.kind=="mc-merge-verdict") | .status + " " + .detail' "$L/puts.log" 2>/dev/null | tail -1; }
KEY11="example-org/demo-os#11"

# D1 — one hit on head B, a LEGACY marker file for B, no row: parks.
cfresh; DIFF_HIT > "$C/prdiff"; : > "$CREC/iron-law-accepted-$SHA_B"
tick
case "$(cverdict)" in "hold $SHA_B iron-law: "*) ok ;; *) bad "D1 a marker file alone must not unpark: the verdict holds B (got '$(cverdict)'; err: $(tail -3 "$C/tick.err" 2>/dev/null))" ;; esac
grep -q 'ADJUDICATED ACCEPT by the blocked-resolver' <<<"$(clog)" && bad "D1 the marker file is not read ($(clog | grep -i 'ADJUDICATED'))" || ok

# D3 — no marker, a row for head B: unparks on the row.
cfresh; DIFF_HIT > "$C/prdiff"; HROW "$KEY11@$SHA_B" "$SHA_B"
tick
[ "$(clog | grep -c "ACCEPTED in the DB by ops@x — not parking")" = 1 ] && ok \
  || bad "D3 one 'ACCEPTED in the DB' line (log: $(clog | grep -i iron | tail -3))"
[ "$(cverdict)" = "clear $SHA_B iron-law scan clean" ] && ok || bad "D3 the verdict publishes clear for B (got '$(cverdict)')"

# D4 — a marker and a row for head A, the PR is on head B: parks.
cfresh; DIFF_HIT > "$C/prdiff"; : > "$CREC/iron-law-accepted-$SHA_A"; HROW "$KEY11@$SHA_A" "$SHA_A"
tick
case "$(cverdict)" in "hold $SHA_B iron-law: "*) ok ;; *) bad "D4 an older head's marker and row must not unpark B (got '$(cverdict)')" ;; esac
[ -s "$C/gh-writes.txt" ] && bad "no conductor case may write to GitHub ($(cat "$C/gh-writes.txt"))" || ok

# ============================================================================
# The resolver family's scratch harness ($T/h), the BH-4157 suite's W fixture
# plus this ticket's fragment.
# ============================================================================
H="$T/h"; mkdir -p "$H/bin"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-sweep.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
( cd "$DIR" && for m in bin/lib/ms/*.sh bin/jobs-client.sh bin/lib/ironlaw-carry.sh bin/lib/br/opt/family.sh; do
    scratch_install_closure "$m" "$H" >/dev/null || exit 1
  done ) || exit 1
mkdir -p "$H/bin/blocked-resolver.d" || exit 1
[ -r "$FRAG" ] && { cp "$FRAG" "$H/bin/blocked-resolver.d/" || exit 1; }   # its absence is the first FAIL above
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
REC="$H/builds/tproj-TK-9-202610250001"; mkdir -p "$REC"
URL9=https://github.com/o/tproj/pull/9
printf 'PR_CREATED %s\n' "$URL9" > "$REC/RESULT"
printf 'findings\nVERDICT: APPROVE\n' > "$REC/review.md"
blog() { cat "$H/logs/blocked-resolver.log" 2>/dev/null; }
claims() { jq -c 'select(.kind=="ironlaw-head-accept")' "$L/claims.log" 2>/dev/null; }
nclaims() { claims | grep -c . ; }
rjson() { cat "$H/state/blocked-resolver/tproj/"*.json 2>/dev/null | head -1; }
rfile() { find "$H/state/blocked-resolver/tproj" -maxdepth 1 -name '*.json' 2>/dev/null | head -1; }
ctrs() { rjson | jq -c '{adjudications:(.adjudications // 0),fixrounds:(.fixrounds // 0),rebuilds:(.rebuilds // 0)}' 2>/dev/null; }
ncalls() { local n; n=$(grep -c "^call " "$T/agent.txt" 2>/dev/null); echo "${n:-0}"; }
nofile() { [ -z "$(find "$H" "$T/c" -name 'iron-law-accepted-*' -newer "$T/fresh-mark" 2>/dev/null)" ]; }
# A new tick on the same record: the log, the ledger and the call log restart,
# the record json and the family store stay.
again() { ledger_clear; : > "$H/logs/blocked-resolver.log"; rm -f "$T/agent.txt"; touch "$T/fresh-mark"; }
wfresh() {
  again; scratch_rm "$H/state/blocked-resolver"
  rm -f "$H/flags/blocked-resolver-observe"
  printf 'PR_CREATED %s\n' "$URL9" > "$REC/RESULT"
  DIFF_HIT > "$T/prdiff"; printf '%s' "$SHA_A" > "$T/prhead"
  ROW "o/tproj#9" "iron-law (1 hit(s))" "$URL9"
}
BRENV=(ADJ_VERDICT=ACCEPT JOBS_BOX=box-fixture "${JENV[@]}")
# setpend <json> — overwrite the record's .ila_pending (the R8/R9/R11 inputs).
setpend() { local f; f=$(rfile); jq -c --argjson v "$1" '.ila_pending = $v' "$f" > "$f.t" && mv "$f.t" "$f"; }

# R1 — ACCEPT on head A with the claim route up: one row, no file, no pending.
wfresh; RUN
[ "$(claims | jq -r '.key + " " + (.detail | fromjson | .source)')" = "o/tproj#9@$SHA_A resolver" ] && ok \
  || bad "R1 one resolver claim keyed o/tproj#9@A (got '$(claims)'; log: $(blog | grep -i iron | tail -3))"
nofile && ok || bad "R1 no iron-law-accepted-* file ($(find "$H" -name 'iron-law-accepted-*'))"
blog | grep -q "ADJUDICATED ACCEPT — DB accept recorded (o/tproj#9@$SHA_A)" && ok || bad "R1 the recorded line (log: $(blog | grep -i iron | tail -3))"
[ "$(rjson | jq -r 'has("ila_pending")')" = false ] && ok || bad "R1 no .ila_pending ($(rjson | jq -c .ila_pending))"

# R2 — the same with the claim route down: no file, the ruling kept as pending.
wfresh; : > "$L/claim-503"; RUN
nofile && ok || bad "R2 no iron-law-accepted-* file"
[ "$(rjson | jq -r '.ila_pending.head + " " + .ila_pending.url')" = "$SHA_A $URL9" ] && ok \
  || bad "R2 .ila_pending names head A and URL9 ($(rjson | jq -c .ila_pending); log: $(blog | grep -i iron | tail -3))"
[ "$(rjson | jq -r '.adjudications')" = 1 ] && ok || bad "R2 adjudications 1 ($(ctrs))"
[ "$(ncalls)" = 1 ] && ok || bad "R2 one model call ($(ncalls))"
blog | grep -q 'DB accept NOT recorded; kept as pending in the record' && ok || bad "R2 the kept-as-pending line (log: $(blog | grep -i iron | tail -3))"
grep -q 'DB accept recorded' <<<"$(blog)" && bad "R2 no recorded claim on a 503" || ok
cp "$(rfile)" "$T/r2-record.json"; R2CTRS=$(ctrs)
R2NAME=$(basename "$(rfile)")
r2() { wfresh; mkdir -p "$H/state/blocked-resolver/tproj"; cp "$T/r2-record.json" "$H/state/blocked-resolver/tproj/$R2NAME"; }

# R3 — the next tick, the claim route up, the same head: the row, no model call.
r2; RUN
[ "$(claims | jq -r '.key + " " + (.detail | fromjson | .source)')" = "o/tproj#9@$SHA_A resolver" ] && ok \
  || bad "R3 one resolver claim for A (got '$(claims)'; log: $(blog | tail -4))"
[ "$(rjson | jq -r 'has("ila_pending")')" = false ] && ok || bad "R3 the pending is cleared ($(rjson | jq -c .ila_pending))"
[ "$(ncalls)" = 0 ] && ok || bad "R3 no model call ($(ncalls))"
[ "$(ctrs)" = "$R2CTRS" ] && ok || bad "R3 the counters stay ($(ctrs) vs $R2CTRS)"
blog | grep -q 'pending ACCEPT recorded' && ok || bad "R3 the pending-recorded line (log: $(blog | tail -4))"
grep -q 'dropping to the rung below' <<<"$(blog)" && bad "R3 no rung is spent ($(blog | grep 'rung below'))" || ok
nofile && ok || bad "R3 no iron-law-accepted-* file"

# R4 — the next tick with the claim still down: kept, nothing spent, no page.
r2; : > "$L/claim-503"; : > "$T/lane-alert.txt"; RUN
[ "$(rjson | jq -r .ila_pending.head)" = "$SHA_A" ] && ok || bad "R4 the pending is kept ($(rjson | jq -c .ila_pending))"
[ "$(ncalls)" = 0 ] && ok || bad "R4 no model call ($(ncalls))"
[ "$(ctrs)" = "$R2CTRS" ] && ok || bad "R4 the counters stay ($(ctrs) vs $R2CTRS)"
blog | grep -q 'pending ACCEPT still NOT recorded' && ok || bad "R4 the still-not-recorded line (log: $(blog | tail -4))"
[ -s "$T/lane-alert.txt" ] && bad "R4 no page ($(cat "$T/lane-alert.txt"))" || ok

# R5 — the PR head moved to B: the pending is dropped, the rung below runs.
r2; printf '%s' "$SHA_B" > "$T/prhead"; RUN
[ "$(rjson | jq -r 'has("ila_pending")')" = false ] && ok || bad "R5 the pending is cleared ($(rjson | jq -c .ila_pending))"
[ "$(nclaims)" = 0 ] && ok || bad "R5 no claim ($(claims))"
blog | grep -q "pending ACCEPT was for ${SHA_A:0:8}, head is now ${SHA_B:0:8} — dropped" && ok || bad "R5 the dropped line (log: $(blog | tail -4))"
blog | grep -q 'dropping to the rung below' && ok || bad "R5 the rung below runs (log: $(blog | tail -4))"

# R6 — observe mode: says WOULD, writes nothing.
r2; touch "$H/flags/blocked-resolver-observe"; RUN
blog | grep -q 'WOULD retry pending ACCEPT' && ok || bad "R6 the WOULD line (log: $(blog | tail -4))"
[ "$(nclaims)" = 0 ] && ok || bad "R6 no claim in observe mode ($(claims))"
[ "$(rjson | jq -r .ila_pending.head)" = "$SHA_A" ] && ok || bad "R6 the pending is kept ($(rjson | jq -c .ila_pending))"
rm -f "$H/flags/blocked-resolver-observe"

# R7 — ACCEPT with no build record for the PR: the row is still written (A3).
wfresh; printf 'PR_CREATED https://github.com/o/tproj/pull/999\n' > "$REC/RESULT"; RUN
[ "$(claims | jq -r .key)" = "o/tproj#9@$SHA_A" ] && ok || bad "R7 the row is written with no build record (got '$(claims)'; log: $(blog | grep -i iron | tail -3))"
nofile && ok || bad "R7 no iron-law-accepted-* file"
printf 'PR_CREATED %s\n' "$URL9" > "$REC/RESULT"

# R8 — a pending for another PR url: dropped, the rung runs.
r2; setpend "$(jq -nc --arg h "$SHA_A" '{url:"https://github.com/o/tproj/pull/10",head:$h,at:"x"}')"; RUN
[ "$(nclaims)" = 0 ] && ok || bad "R8 no claim for another PR's pending ($(claims))"
[ "$(rjson | jq -r 'has("ila_pending")')" = false ] && ok || bad "R8 the pending is cleared"
blog | grep -q 'dropping to the rung below' && ok || bad "R8 the rung below runs (log: $(blog | tail -4))"

# R9 — a pending head that is not 40 hex: dropped, the rung runs.
r2; setpend "$(jq -nc --arg u "$URL9" '{url:$u,head:"abc",at:"x"}')"; RUN
[ "$(nclaims)" = 0 ] && ok || bad "R9 no claim for a bad head ($(claims))"
[ "$(rjson | jq -r 'has("ila_pending")')" = false ] && ok || bad "R9 the pending is cleared"
blog | grep -q 'dropping to the rung below' && ok || bad "R9 the rung below runs (log: $(blog | tail -4))"

# R11 — a pending head in upper case: compared and written lower case (D17).
r2; setpend "$(jq -nc --arg u "$URL9" --arg h "$(printf '%s' "$SHA_A" | tr 'a-f' 'A-F')" '{url:$u,head:$h,at:"x"}')"; RUN
[ "$(claims | jq -r .key)" = "o/tproj#9@$SHA_A" ] && ok || bad "R11 the lower-case key (got '$(claims)'; log: $(blog | tail -4))"
[ "$(ncalls)" = 0 ] && ok || bad "R11 no model call ($(ncalls))"

# R10 — the retry answers only an iron-law park: a test-tamper reason never
# retries, whatever the record holds (the fragment, sourced over its stubs).
R10=$(
  say() { :; }; OBSERVE=0
  br_load() { jq -nc --arg u "$URL9" --arg h "$SHA_A" '{adjudications:1,ila_pending:{url:$u,head:$h,at:"x"}}'; }
  br_save() { echo SAVED; }; br_pr_field() { printf '%s' "$SHA_A"; }
  ila_put() { echo PUT; return 0; }
  . "$FRAG" 2>/dev/null || exit 9
  br_ila_pending_retry tproj k1 test-tamper "$URL9"; echo "rc=$?"
)
[ "$R10" = "rc=1" ] && ok || bad "R10 a test-tamper reason falls through with no write (got '$R10')"
grep -qE '\[ "\$reason" = iron-law \] && command -v br_ila_pending_retry' "$DIR/bin/blocked-resolver.sh" && ok \
  || bad "R10 the n>=1 call site guards on reason=iron-law"

# ============================================================================
# F. the family carry (the store holds the ruling an ACCEPT just recorded)
# ============================================================================
fam_seed() { wfresh; RUN; }      # an ACCEPT on A records the family ruling
fam_tick() { # fam_tick — the same PR on head B, a fresh record, the store kept
  again
  find "$H/state/blocked-resolver" -mindepth 1 -maxdepth 1 ! -name '.families' -exec rm -rf {} + 2>/dev/null
  printf '%s' "$SHA_B" > "$T/prhead"
  ROW "o/tproj#9" "iron-law (1 hit(s))" "$URL9"
  RUN
}
fuses() { cat "$H/state/blocked-resolver/.families/"*.json 2>/dev/null | jq -rs 'map(.uses // 0) | add // 0'; }
# F1 — the carry onto head B: one family row, no file, no model call.
fam_seed; FU0=$(fuses); fam_tick
if blog | grep -q "CARRIED family .* — DB accept recorded (o/tproj#9@$SHA_B), no model call"; then ok
else bad "F1 the carried line (log: $(blog | grep -i 'family\|iron' | tail -4))"; fi
[ "$(claims | jq -r '.key + " " + (.detail | fromjson | .source)')" = "o/tproj#9@$SHA_B family" ] && ok || bad "F1 one family claim on B (got '$(claims)')"
nofile && ok || bad "F1 no iron-law-accepted-* file"
[ "$(ncalls)" = 0 ] && ok || bad "F1 no model call ($(ncalls))"
[ "$(blog | grep -c 'EVENT family-carried')" = 1 ] && ok || bad "F1 one EVENT family-carried ($(blog | grep -c 'EVENT family-carried'))"

# F2 — the same with the claim route down: nothing carried, nothing spent.
fam_tick_keep() { # the F2/F3 tick: like fam_tick, but the ledger switches stay
  : > "$H/logs/blocked-resolver.log"; rm -f "$T/agent.txt"; touch "$T/fresh-mark"
  find "$H/state/blocked-resolver" -mindepth 1 -maxdepth 1 ! -name '.families' -exec rm -rf {} + 2>/dev/null
  printf '%s' "$SHA_B" > "$T/prhead"
  ROW "o/tproj#9" "iron-law (1 hit(s))" "$URL9"
  RUN
}
fam_seed; FU0=$(fuses); : > "$T/comment-bodies.txt"; : > "$L/claim-503"
fam_tick_keep
[ "$(ncalls)" = 0 ] && ok || bad "F2 no model call on a DB outage ($(ncalls); log: $(blog | tail -4))"
[ "$(blog | grep -c 'EVENT family-carried')" = 0 ] && ok || bad "F2 no EVENT family-carried"
[ "$(fuses)" = "$FU0" ] && ok || bad "F2 the store's uses unchanged ($(fuses) vs $FU0)"
grep -q 'We ruled on this exact shape already' "$T/comment-bodies.txt" 2>/dev/null && bad "F2 no carry comment" || ok
blog | grep -q 'nothing carried, the carry is offered next tick' && ok || bad "F2 the deferred line (log: $(blog | grep -i 'family\|iron' | tail -4))"
nofile && ok || bad "F2 no iron-law-accepted-* file"

# F3 — a tree without the lib (no ila_put): the same as F2.
fam_seed; FU0=$(fuses)
mv "$H/bin/lib/ironlaw-carry.sh" "$T/ironlaw-carry.sh.off"
fam_tick_keep
mv "$T/ironlaw-carry.sh.off" "$H/bin/lib/ironlaw-carry.sh"
[ "$(ncalls)" = 0 ] && ok || bad "F3 no model call with no lib ($(ncalls); log: $(blog | tail -4))"
[ "$(blog | grep -c 'EVENT family-carried')" = 0 ] && ok || bad "F3 no EVENT family-carried"
[ "$(fuses)" = "$FU0" ] && ok || bad "F3 the store's uses unchanged ($(fuses) vs $FU0)"
blog | grep -q 'nothing carried, the carry is offered next tick' && ok || bad "F3 the deferred line (log: $(blog | grep -i 'family\|iron' | tail -4))"
BRENV=()

# ============================================================================
# D2. the sweep, with a legacy marker file and no row: parks.
# ============================================================================
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
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
ledger_clear; DIFF_HIT > "$T/prdiff"; : > "$H/state/merge-sweep-done.txt"; : > "$H/logs/merge-sweep.log"
: > "$REC/iron-law-accepted-$SHA_B"
SWEEP
slog | grep -q 'parked:' && ok || bad "D2 the sweep parks on a marker file alone (log: $(slog | tail -3))"
grep -q 'ADJUDICATED ACCEPT' <<<"$(slog)" && bad "D2 the sweep does not read the marker ($(slog | grep ADJUDICATED))" || ok
[ -s "$T/merged.txt" ] && bad "D2 nothing merged ($(cat "$T/merged.txt"))" || ok
rm -f "$REC/iron-law-accepted-$SHA_B"

# ============================================================================
# G1. no bin/ code writes or tests for the marker file (D3: the pattern is
# proven live on a fixture line first).
# ============================================================================
PAT='(:[[:space:]]*>[[:space:]]*|-[fe][[:space:]]+)"?\$[A-Za-z_{}]+/iron-law-accepted-'
grep -qE "$PAT" <<<"$(printf ': > "$rec/iron-law-accepted-$head"\n')" && ok || bad "G1 the pattern matches a writer line"
grep -qE "$PAT" <<<"$(printf '[ -f "$REC/iron-law-accepted-$HEAD" ]\n')" && ok || bad "G1 the pattern matches a reader line"
G1=$(grep -rnE "$PAT" "$DIR/bin" 2>/dev/null)
[ -z "$G1" ] && ok || bad "G1 bin/ still writes or reads the marker: $G1"

echo "ironlaw-file-drop.bh-7804: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
