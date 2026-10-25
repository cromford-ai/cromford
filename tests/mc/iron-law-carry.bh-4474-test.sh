#!/bin/bash
# tests/mc/iron-law-carry.bh-4474-test.sh — an iron-law ACCEPT is carried to a
# new head when the hit set is unchanged (BH-4474).
#
# WHAT IS UNDER TEST. bin/lib/ironlaw-carry.sh fingerprints every hit as (rule,
# file, content hash of the flagged line). bin/blocked-resolver.sh's ACCEPT
# arm writes one `ironlaw-accept` row per fingerprint into the jobs ledger, and
# bin/merge-conductor.sh and bin/merge-sweep.sh carry the acceptance to a head
# whose every hit has a row for THIS PR. The three scripts are DRIVEN, against a
# stub `curl` that serves /api/ledger from a directory and a stub `gh` serving
# the PR diff, so what is asserted is a ledger row or a log line a real tick
# wrote, never the source text.
#
# Sections:
#   U1-U10  the lib, sourced (fingerprints, record/covered, the fail-closed rcs)
#   P1      the resolver's ACCEPT records rows; a REJECT records none
#   C1-C5   the conductor: the ticket's four acceptance tests plus an outage
#   S1-S2   the sweep, the other gate that reads the same acceptance
# Run from anywhere: tests/mc/iron-law-carry.bh-4474-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
# BH-1625: the lanes read every verdict through bin/lib/verdict-parse.sh.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v sha1sum >/dev/null || { echo "sha1sum missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/ironlaw-carry.sh" ] || { echo "FAIL: bin/lib/ironlaw-carry.sh is missing"; exit 1; }

SHA_A=aaaaaaaa11111111111111111111111111111111
SHA_B=bbbbbbbb22222222222222222222222222222222
# The flagged lines. A test path is outside both scans, so these literals do
# not park this PR.
CONF='if (window.confirm("delete?")) go();'
RAWQ='const r = db.$queryRawUnsafe(q);'
DIFF_A() { printf '+++ b/src/ui.js\n@@ -1,0 +1,3 @@\n+const a = 1;\n+  %s\n+%s\n' "$CONF" "$RAWQ"; }
# Head B: the same two hits moved down three lines and re-indented.
DIFF_B() { printf '+++ b/src/ui.js\n@@ -1,0 +1,6 @@\n+const a = 1;\n+const b = 2;\n+const c = 3;\n+const d = 4;\n+\t    %s   \n+%s\n' "$CONF" "$RAWQ"; }
# Head B plus a NEW hit in another file.
DIFF_B2() { DIFF_B; printf '+++ b/src/other.js\n@@ -1,0 +1,1 @@\n+window.alert("hi");\n'; }
# Head B with the flagged line's content changed by one character.
DIFF_B3() { printf '+++ b/src/ui.js\n@@ -1,0 +1,6 @@\n+const a = 1;\n+const b = 2;\n+const c = 3;\n+const d = 4;\n+    %s\n+%s\n' "${CONF/\?/??}" "$RAWQ"; }
# Head B with the accepted line copied a second time.
DIFF_DUP() { DIFF_B; printf '+++ b/src/ui.js\n@@ -20,0 +20,1 @@\n+%s\n' "$CONF"; }

# ---- the ledger stub -------------------------------------------------------
# One file per (kind, key). get-503 / put-503 in the ledger dir make the
# ironlaw-accept kind answer 503 (an outage); other kinds stay reachable so the
# lanes' other ledger reads behave as they always do in fixtures.
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
case "$URL" in */api/ledger*) ;; *) printf '{"error":"not found"}\n404\n'; exit 0 ;; esac
fname() { printf '%s\t%s' "$1" "$2" | sha1sum | cut -c1-40; }
if [ "$M" = PUT ]; then
  k=$(printf '%s' "$BODY" | jq -r .kind); key=$(printf '%s' "$BODY" | jq -r .key)
  # Only this ticket's kind is kept: every other ledger write is acknowledged
  # and forgotten, as tests/conductor-read-memo.bh-1486-test.sh's stub does, so
  # a lane's own bookkeeping (the sweep's `parked` row) never leaks across cases.
  if [ "$k" = ironlaw-accept ]; then
    [ -f "$L/put-503" ] && { printf '{"error":"down"}\n503\n'; exit 0; }
    printf '%s\n' "$BODY" >> "$L/puts.log"
    printf '%s' "$BODY" | jq -c '{ledger:{kind,key,status,detail:(.detail // null)}}' > "$L/$(fname "$k" "$key").json"
  fi
  printf '{"ok":true}\n200\n'; exit 0
fi
dec() { printf '%b' "${1//%/\\x}"; }
kind=""; key=""
IFS='&' read -ra parts <<<"${URL#*\?}"
for p in "${parts[@]}"; do case "$p" in kind=*) kind=$(dec "${p#kind=}") ;; key=*) key=$(dec "${p#key=}") ;; esac; done
if [ "$kind" = ironlaw-accept ]; then
  printf '%s\n' "$key" >> "$L/gets.log"
  [ -f "$L/get-503" ] && { printf '{"error":"down"}\n503\n'; exit 0; }
fi
f="$L/$(fname "$kind" "$key").json"
[ -n "$key" ] && [ -f "$f" ] && { cat "$f"; printf '\n200\n'; exit 0; }
printf '{"error":"not found"}\n404\n'
EOF
  chmod +x "$1/curl"
}
ledger_clear() { find "$L" -mindepth 1 -delete 2>/dev/null; mkdir -p "$L"; }
ilc_rows() { grep -l '"ironlaw-accept"' "$L"/*.json 2>/dev/null | wc -l | tr -d ' '; }
JENV=(HARNESS_SECRET=x JOBS_URL=http://jobs.test JOBS_RETRIES=0)

# fixture: tests/lib/fixture-harness.sh (BH-1196).
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1

# ============================================================================
# C fixture — the conductor's scratch harness, in its own root ($T/c).
# ============================================================================
C="$T/c"; CH="$C/h"
fx_mc_harness "$DIR" "$C" || exit 1
fx_conductor_tick "$DIR" "$C" || exit 1
cp "$DIR/bin/lib/ironlaw-carry.sh" "$CH/bin/lib/" || exit 1
# The REAL check runner and catalog: a CHECK-HIT is half of what is fingerprinted.
cp "$DIR/bin/checks-run.sh" "$CH/bin/" && cp -r "$DIR/checks" "$CH/checks" || exit 1
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
mkcurl "$C/fakebin"
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$CH/fleet.conf"
: > "$CH/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$CH/bin/agent-call.sh"; chmod +x "$CH/bin/agent-call.sh"
for N in 11 12; do
  mkdir -p "$CH/builds/demo-os-TK-$N-202610040001"
  echo "PR_CREATED https://github.com/example-org/demo-os/pull/$N" > "$CH/builds/demo-os-TK-$N-202610040001/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$CH/builds/demo-os-TK-$N-202610040001/review.md"
  echo "$SHA_B" > "$CH/builds/demo-os-TK-$N-202610040001/reviewed-sha"
done
cat > "$C/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$C/gh-calls.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/pulls/([0-9]+).*#\1#p' | head -1)
case "\$*" in
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*)
    echo "WRITE VERB: \$*" >> "$C/gh-writes.txt"; exit 1 ;;
  *"v3.diff"*) restpr --diff "\$(cat "$C/prdiff-\$N" 2>/dev/null)" ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/\$N"*) restpr OPEN "$SHA_B" "ticket/pb-\$N" main "" ;;
  *"pr list -R example-org/demo-os --state open"*) cat "$C/openlist" ;;
  *"pulls?state=closed"*) restpr --raw 200 '[]' ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n' | restpr --runs - ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$C/fakebin/gh"
openlist() { # openlist <pr number>
  jq -nc --arg h "$SHA_B" --argjson n "$1" '[{number:$n,url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)),headRefOid:$h,headRefName:("ticket/pb-"+($n|tostring)),baseRefName:"main",isDraft:false,mergeStateStatus:"CLEAN",mergeable:"MERGEABLE",state:"OPEN",updatedAt:"2026-10-04T10:00:00Z"}]' > "$C/openlist"
}
tick() {
  ( cd "$C" && PATH="$C/fakebin:$PATH" GH_LIST_BRIDGE_ROOT="$C" HARNESS="$CH" MC_MAIN_RED_DETECT=0 \
      env "${JENV[@]}" bash "$CH/bin/merge-conductor.sh" >/dev/null 2>>"$C/tick.err" ) || true
}
fresh() {
  scratch_rm "$CH/state"; scratch_rm "$CH/logs"; scratch_rm "$CH/locks"
  mkdir -p "$CH/state" "$CH/logs" "$CH/locks"
  : > "$C/gh-calls.txt"; : > "$C/gh-writes.txt"
  rm -f "$L/get-503" "$L/put-503" "$L/gets.log"
}
clog() { cat "$CH/logs/merge-conductor.log" 2>/dev/null; }
crow() { awk -F'\t' -v k="$1" '$1==k' "$CH/state/merge-conductor/pr-state.tsv" 2>/dev/null; }
# SEED <pr-url> <sha> <diff-fn> — rows exactly as an ACCEPT on that head writes
# them, through the lib and the real jobs client (P1 drives the resolver's arm).
SEED() {
  ( export HARNESS="$CH" PATH="$C/fakebin:$PATH"; export "${JENV[@]}"
    . "$CH/bin/jobs-client.sh"; . "$CH/bin/lib/ironlaw-carry.sh"
    "$3" > "$T/seed.diff"; ilc_hits "$T/seed.diff" > "$T/seed.hits" || exit 3
    ilc_record "$1" "$2" "$T/seed.hits" >/dev/null ) || bad "SEED $1 failed (rc $?)"
}
URL11=https://github.com/example-org/demo-os/pull/11
URL12=https://github.com/example-org/demo-os/pull/12

# ============================================================================
# U. the lib, sourced, over the real jobs client and the ledger stub
# ============================================================================
(
  export HARNESS="$CH" PATH="$C/fakebin:$PATH"; export "${JENV[@]}"
  . "$CH/bin/jobs-client.sh" || exit 9
  . "$DIR/bin/lib/ironlaw-carry.sh" || exit 9
  F=0; no() { F=$((F+1)); echo "FAIL: $1"; }
  DIFF_A > "$T/a.diff"; DIFF_B > "$T/b.diff"; DIFF_B3 > "$T/b3.diff"; DIFF_DUP > "$T/dup.diff"
  # U1 — one grep hit and one CHECK-HIT, each with its rule and path.
  HA=$(ilc_hits "$T/a.diff"); rc=$?
  [ "$rc" = 0 ] && [ "$(printf '%s\n' "$HA" | grep -c .)" = 2 ] || no "U1 two hits rc 0 (rc $rc: $HA)"
  grep -q $'^redflag:window.confirm(\tsrc/ui.js\t[0-9a-f]\{40\}$' <<<"$HA" || no "U1 redflag rule + path ($HA)"
  grep -q $'^check:sql-command-injection\tsrc/ui.js\t[0-9a-f]\{40\}$' <<<"$HA" || no "U1 check rule + path ($HA)"
  # U2 — moved + re-indented is the same fingerprint; one character is not.
  [ "$(ilc_hits "$T/b.diff")" = "$HA" ] || no "U2 a moved, re-indented line must fingerprint the same"
  [ "$(ilc_hits "$T/b3.diff" | grep redflag)" != "$(printf '%s\n' "$HA" | grep redflag)" ] || no "U2 a changed character must change the fingerprint"
  # U3 — record on A, covered on B, printing A's sha.
  ilc_hits "$T/a.diff" > "$T/a.hits"
  W=$(ilc_record "$URL11" "$SHA_A" "$T/a.hits"); rc=$?
  [ "$rc" = 0 ] && [ "$W" = 2 ] || no "U3 record writes 2 rows rc 0 (rc $rc, wrote '$W')"
  O=$(ilc_covered "$URL11" 2 "$T/b.diff"); rc=$?
  [ "$rc" = 0 ] && [ "$O" = "$SHA_A" ] || no "U3 covered rc 0 naming A (rc $rc: $O)"
  # U4 — a CHECK-HIT at no added line: the hit set is unknown.
  printf '#!/bin/bash\necho "CHECK-HIT sql-command-injection src/ui.js:99 x"; exit 1\n' > "$T/cr-bad"; chmod +x "$T/cr-bad"
  ILC_CHECKS_RUN="$T/cr-bad" ilc_hits "$T/a.diff" >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] || no "U4 an unresolvable CHECK-HIT must be rc 2 (rc $rc)"
  # U5 — the PR key: lowercased repo, the number, nothing else parses.
  [ "$(ilc_pr_key https://github.com/example-org/Cromford/pull/9)" = 'example-org/cromford#9' ] || no "U5 key (got $(ilc_pr_key https://github.com/example-org/Cromford/pull/9))"
  [ "$(ilc_pr_key https://github.com/example-org/Cromford/pull/10)" != "$(ilc_pr_key https://github.com/example-org/Cromford/pull/9)" ] || no "U5 pull/10 must be a different key"
  ilc_pr_key https://github.com/example-org/Cromford/issues/9 >/dev/null; [ $? = 1 ] || no "U5 a non-PR url must be rc 1"
  # U6 — a second copy of the accepted line is not covered.
  O=$(ilc_covered "$URL11" 3 "$T/dup.diff"); rc=$?
  [ "$rc" = 1 ] && grep -q 'redflag:window.confirm( src/ui.js (more copies than accepted)' <<<"$O" || no "U6 duplicate must be rc 1 more-copies (rc $rc: $O)"
  # U7 — over the cap fails closed.
  ILC_MAX_HITS=1 ilc_hits "$T/a.diff" >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] || no "U7 over ILC_MAX_HITS must be rc 2 (rc $rc)"
  # U8 — checks-run rc 2 (could not run) fails closed.
  printf '#!/bin/bash\necho "CHECKS: could not run"; exit 2\n' > "$T/cr-2"; chmod +x "$T/cr-2"
  ILC_CHECKS_RUN="$T/cr-2" ilc_hits "$T/a.diff" >/dev/null 2>&1; rc=$?
  [ "$rc" = 2 ] || no "U8 checks-run rc 2 must be rc 2 (rc $rc)"
  # U9 — an outage is never covered and never uncovered.
  : > "$L/get-503"
  O=$(ilc_covered "$URL11" 2 "$T/b.diff"); rc=$?
  rm -f "$L/get-503"
  [ "$rc" = 2 ] || no "U9 a 503 ledger must be rc 2 (rc $rc: $O)"
  # U10 — the same PR number in another repo is not covered.
  O=$(ilc_covered https://github.com/example-org/other-os/pull/11 2 "$T/b.diff"); rc=$?
  [ "$rc" = 1 ] || no "U10 another repo's PR 11 must be rc 1 (rc $rc: $O)"
  # U11 — fewer hits than the scan counted is not a proof.
  O=$(ilc_covered "$URL11" 3 "$T/b.diff"); rc=$?
  [ "$rc" = 2 ] || no "U11 fingerprinted < scan count must be rc 2 (rc $rc: $O)"
  exit "$F"
); URC=$?
[ "$URC" = 0 ] && ok || bad "U: $URC unit case(s) failed"
ledger_clear

# ============================================================================
# C. the conductor, driven
# ============================================================================
# C1 (ticket test 1) — accepted on A with H; head B carries the same H, moved.
fresh; ledger_clear; SEED "$URL11" "$SHA_A" DIFF_A
openlist 11; DIFF_B > "$C/prdiff-11"
tick
[ "$(clog | grep -c "iron-law: carried acceptance from ${SHA_A:0:8}")" = 1 ] && ok \
  || bad "C1 exactly one carry line naming A (log: $(clog | grep -i iron | tail -3))"
grep -q 'iron-law' <<<"$(crow 'example-org/demo-os#11')" && bad "C1 a carried head must not park on iron-law ($(crow 'example-org/demo-os#11'))" || ok
crow 'example-org/demo-os#11' | grep -q $'\tREADY\t' && ok || bad "C1 the carried head classifies READY ($(crow 'example-org/demo-os#11'))"
# C1b — the next tick answers the scan from its memo and must re-read the diff
# to carry, not park and not carry blind.
tick
[ "$(clog | grep -c "iron-law: carried acceptance from ${SHA_A:0:8}")" = 2 ] && ok \
  || bad "C1b a memoised scan must still carry (log: $(clog | grep -i 'iron\|memo' | tail -3))"
crow 'example-org/demo-os#11' | grep -q $'\tREADY\t' && ok || bad "C1b still READY ($(crow 'example-org/demo-os#11'))"

# C2 (ticket test 2) — B adds H2 in another file: parked, naming H2 only.
fresh; DIFF_B2 > "$C/prdiff-11"
tick
REF=$(clog | grep 'iron-law: carry refused')
[ -n "$REF" ] && ok || bad "C2 a carry-refused line (log: $(clog | grep -i iron | tail -3))"
grep -q 'redflag:window.alert( src/other.js (new or changed)' <<<"$REF" && ok || bad "C2 names H2 ($REF)"
grep -q 'src/ui.js' <<<"$REF" && bad "C2 must not name the covered H ($REF)" || ok
crow 'example-org/demo-os#11' | grep -q 'iron-law' && ok || bad "C2 parked on iron-law ($(crow 'example-org/demo-os#11'))"
grep -q 'carried acceptance' <<<"$(clog)" && bad "C2 must not carry" || ok

# C3 (ticket test 3) — the flagged line's content changed: parked.
fresh; DIFF_B3 > "$C/prdiff-11"
tick
clog | grep -q 'iron-law: carry refused.*redflag:window.confirm( src/ui.js (new or changed)' && ok \
  || bad "C3 a changed line is refused (log: $(clog | grep -i iron | tail -3))"
crow 'example-org/demo-os#11' | grep -q 'iron-law' && ok || bad "C3 parked on iron-law ($(crow 'example-org/demo-os#11'))"

# C4 (ticket test 4) — the same H on another PR of the same repo: parked.
fresh; openlist 12; DIFF_B > "$C/prdiff-12"
tick
clog | grep -q 'example-org/demo-os#12 iron-law: carry refused' && ok || bad "C4 PR 12 refused (log: $(clog | grep -i iron | tail -3))"
crow 'example-org/demo-os#12' | grep -q 'iron-law' && ok || bad "C4 PR 12 parked on iron-law ($(crow 'example-org/demo-os#12'))"
grep -q 'carried acceptance' <<<"$(clog)" && bad "C4 the carry must never cross PRs" || ok

# C5 — the ledger is down: UNVERIFIABLE, parked.
fresh; openlist 11; DIFF_B > "$C/prdiff-11"; : > "$L/get-503"
tick
clog | grep -q 'iron-law: carry UNVERIFIABLE' && ok || bad "C5 an outage is UNVERIFIABLE (log: $(clog | grep -i iron | tail -3))"
crow 'example-org/demo-os#11' | grep -q 'iron-law' && ok || bad "C5 parked on iron-law ($(crow 'example-org/demo-os#11'))"
rm -f "$L/get-503"
[ -s "$C/gh-writes.txt" ] && bad "no conductor case may write to GitHub ($(cat "$C/gh-writes.txt"))" || ok
ledger_clear

# ============================================================================
# P / S fixture — the resolver family's scratch harness ($T/h).
# ============================================================================
H="$T/h"; mkdir -p "$H/bin"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-sweep.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$DIR/bin/jobs-client.sh" "$H/bin/" || exit 1
mkdir -p "$H/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$H/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
fx_br_harness "$DIR" "$T" || exit 1
mkdir -p "$H/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/" || exit 1
cp "$DIR/bin/lib/ironlaw-carry.sh" "$H/bin/lib/" || exit 1
cp "$DIR/bin/checks-run.sh" "$H/bin/" && cp -r "$DIR/checks" "$H/checks" || exit 1
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
REC="$H/builds/tproj-TK-9-202610040001"; mkdir -p "$REC"
URL9=https://github.com/o/tproj/pull/9
printf 'PR_CREATED %s\n' "$URL9" > "$REC/RESULT"
printf 'findings\nVERDICT: APPROVE\n' > "$REC/review.md"
blog() { cat "$H/logs/blocked-resolver.log" 2>/dev/null; }

# P1 — the resolver's ADJUDICATED ACCEPT on head A records one row per hit.
DIFF_A > "$T/prdiff"; printf '%s' "$SHA_A" > "$T/prhead"
ROW "o/tproj#9" "iron-law (2 hit(s))" "$URL9"
BRENV=(ADJ_VERDICT=ACCEPT "${JENV[@]}")
RUN
[ ! -e "$REC/iron-law-accepted-$SHA_A" ] && ok || bad "P1 no marker file is written (BH-7804: the ironlaw-head-accept row replaced it) (log: $(blog | tail -3))"
[ "$(ilc_rows)" = 2 ] && ok || bad "P1 two ironlaw-accept rows (got $(ilc_rows); log: $(blog | grep -i 'iron' | tail -3))"
K=$(jq -r 'select(.kind=="ironlaw-accept") | .key' "$L/puts.log" 2>/dev/null | sort -u)
[ "$(printf '%s\n' "$K" | grep -c '^o/tproj#9|[0-9a-f]\{40\}$')" = 2 ] && ok || bad "P1 keys are <repo>#<pr>|<sha1> ($K)"
[ "$(jq -r 'select(.kind=="ironlaw-accept") | .detail | fromjson | .sha' "$L/puts.log" 2>/dev/null | sort -u)" = "$SHA_A" ] && ok \
  || bad "P1 every row names head A ($(cat "$L/puts.log" 2>/dev/null))"
blog | grep -q 'recorded 2 hit fingerprint(s) for carry' && ok || bad "P1 the record line (log: $(blog | tail -3))"
[ "$(find "$REC" -newer "$REC/RESULT" -type f -name 'iron-law*' | wc -l | tr -d ' ')" = 0 ] && ok \
  || bad "P1 no new iron-law file state in the record ($(ls "$REC"))"

# P2 — a REJECT records nothing.
ledger_clear; scratch_rm "$H/state/blocked-resolver"; : > "$H/logs/blocked-resolver.log"
rm -f "$REC"/iron-law-accepted-*
ROW "o/tproj#9" "iron-law (2 hit(s))" "$URL9"
BRENV=(ADJ_VERDICT=REJECT "${JENV[@]}")
RUN
blog | grep -q 'ADJUDICATED REJECT' && ok || bad "P2 the REJECT arm ran (log: $(blog | tail -3))"
[ "$(ilc_rows)" = 0 ] && ok || bad "P2 a REJECT writes no ironlaw-accept row (got $(ilc_rows))"
BRENV=()

# ============================================================================
# S. the sweep, the second gate reading the same acceptance
# ============================================================================
ledger_clear
( export HARNESS="$H" PATH="$T/fakebin:$PATH"; export "${JENV[@]}"
  . "$H/bin/jobs-client.sh"; . "$H/bin/lib/ironlaw-carry.sh"
  DIFF_A > "$T/sa.diff"; ilc_hits "$T/sa.diff" > "$T/sa.hits"
  ilc_record "$URL9" "$SHA_A" "$T/sa.hits" >/dev/null ) || bad "S seed failed"
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
# S1 — head B, the same hits: carried, not parked.
DIFF_B > "$T/prdiff"; : > "$H/state/merge-sweep-done.txt"; : > "$H/logs/merge-sweep.log"
SWEEP
[ "$(slog | grep -c "iron-law: carried acceptance from ${SHA_A:0:8}")" = 1 ] && ok \
  || bad "S1 one sweep carry line (log: $(slog | tail -3))"
grep -q 'parked:' <<<"$(slog)" && bad "S1 the sweep must not park a carried head ($(slog | grep parked:))" || ok
# S2 — head B with a new hit: refused, parked.
DIFF_B2 > "$T/prdiff"; : > "$H/state/merge-sweep-done.txt"; : > "$H/logs/merge-sweep.log"
SWEEP
slog | grep -q 'iron-law: carry refused.*src/other.js' && ok || bad "S2 refused naming H2 (log: $(slog | tail -3))"
slog | grep -q 'parked:' && ok || bad "S2 the sweep parks a new hit"

echo "iron-law-carry: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
