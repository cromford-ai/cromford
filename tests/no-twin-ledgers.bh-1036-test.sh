#!/bin/bash
# tests/no-twin-ledgers.bh-1036-test.sh — BH-1036, state→DB slice 11: the six
# file stores that were the ONLY record that paid or client-visible work already
# happened now have a row twin in `ledgers`, behind the `no-twin-ledgers` flag.
# (The seventh store the ticket named, bin/check-migration-prs.sh's alert file,
# is NOT here: BH-1040 already moved that lane onto ledgers(kind=migration) with
# its own three-way read and a deliberate write-AFTER-send.)
#
# WHAT IS UNDER TEST, and why it is driven rather than grepped. The whole point
# of the ticket is that a hub wipe (or a build re-offered to another machine)
# must not re-buy work: an empty `state/` plus populated rows has to do ZERO
# paid work. That claim is only provable by running each lane with its state
# directory empty and asserting that the thing that costs money — the
# agent-call, the beat, the browser drive, the plan session, the GitHub write —
# never happened. So every section below drives the REAL shipped script (or, for
# bin/run-build.sh, the shipped region read through tests/lib/rb-all.sh, which is
# the BH-568 seam rule) with the network at the edges stubbed, and asserts on
# sinks, request logs, RESULT files, marker files and exit codes. No assertion
# in this file is a regex over source text.
#
# THE NEGATIVES CARRY THE WEIGHT. A twin that reads a stale, neighbouring or
# absent row as "already done" is strictly worse than no twin at all — it drops
# work silently. So each section also pins: a row at a DIFFERENT head does not
# dedup; a `red` row does not satisfy a `landed` guard; a neighbouring ticket key
# does not hold this ticket; a ledger OUTAGE is never "done"; and with the flag
# OFF every lane behaves exactly as it does today, rows or no rows.
#
# Two scripts are copied with ONE line rewritten — bin/review-autopilot.sh's
# `H=/root/harness` and bin/lander.sh's `HARNESS=/root/harness`. Both are on
# tests/env-path-allowlist.d/port-b.txt (not yet ported to the env-path idiom),
# so a scratch tree cannot be handed to them any other way; the rewrite is
# asserted to have matched, so a rename cannot turn it into a silent no-op that
# drives /root/harness.
#
# No network, no model call, no secrets. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 tests/no-twin-ledgers.bh-1036-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 57 || exit 1
# BH-1941: the script under test resolves its vendor base URL through
# endpoint_url (env, else the registry default); this sandbox composes no
# registry, so the env carries today's URL — the registry default itself.
export ENDPOINT_CLERK=https://api.clerk.com
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
LT_LIB="$DIR/bin/lib/ledger-twin.sh"

# ---------------------------------------------------------------------------
# Shared fakes.
# ---------------------------------------------------------------------------
# The curl shim: every request is recorded, /api/ledger GETs are answered from a
# TSV fixture (kind, key, status, detail), /api/flags answers 404 so flag_active
# falls to the FILE (its own documented contract), /api/artifacts is answered
# from a JSON fixture, and CURL_MODE=down is a transport failure (rc 7), which is
# what a worker outage looks like to bin/jobs-client.sh.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
write_curl() { # write_curl <path>
  cat > "$1" <<'CURL'
#!/bin/bash
URL=""; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; shift 2;;
    -H|-m|--connect-timeout|-w) shift 2;;
    -sS|-S|-s|-L|-f) shift;;
    *) URL="$1"; shift;;
  esac
done
[ -n "${REQ_LOG:-}" ] && printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_LOG"
[ -n "${ORDER_LOG:-}" ] && printf 'CURL %s %s\n' "$METHOD" "${URL%%\?*}" >> "$ORDER_LOG"
[ "${CURL_MODE:-ok}" = down ] && exit 7
ud() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }
qp() { printf '%s' "${URL#*\?}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
case "$URL" in
  # BH-1510.1: no model_routes endpoint on this worker — a 404 is the resolver's
  # "worker unreachable", so a lane serves its box cache (mrs_fixture below).
  */api/model-routes/*) printf '{"error":"not found"}\n404\n'; exit 0 ;;
  */api/flags/*) printf '{"error":"no such flag"}\n404\n'; exit 0 ;;
  */api/ledger\?*)
    K=$(ud "$(qp kind)"); V=$(ud "$(qp key)")
    LINE=$(awk -F'\t' -v k="$K" -v v="$V" '$1==k && $2==v {print; exit}' "${LEDGER_ROWS:-/dev/null}" 2>/dev/null)
    if [ -n "$LINE" ]; then
      jq -nc --arg s "$(printf '%s' "$LINE" | cut -f3)" --arg d "$(printf '%s' "$LINE" | cut -f4)" \
        '{ledger:{status:$s,detail:$d}}'
      printf '\n200\n'
    else
      printf '{"error":"not found"}\n404\n'
    fi
    exit 0 ;;
  */api/artifacts\?*)
    if [ -s "${ARTIFACT_FEED:-/dev/null}" ]; then cat "$ARTIFACT_FEED"; else printf '{"artifacts":[]}'; fi
    printf '\n200\n'; exit 0 ;;
esac
printf '{"ok":true}\n200\n'
CURL
  chmod +x "$1"
}

# The function-level stub of the two ledger verbs, for the bin/run-build.sh
# regions, which are extracted and driven rather than run as a whole pipeline.
# It is KEY-AWARE on purpose: a neighbouring ticket's row must be able to miss.
write_ledger_stub() { # write_ledger_stub <path>
  cat > "$1" <<'STUB'
job_ledger_get() {
  local st
  [ "${LEDGER_DOWN:-0}" = 1 ] && return 1
  st=$(awk -F'\t' -v k="$1" -v v="$2" '$1==k && $2==v {print $3; exit}' "${LEDGER_ROWS:-/dev/null}" 2>/dev/null)
  [ -n "$st" ] || return 2
  printf '%s' "$st"
}
job_ledger_put() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "${LEDGER_SINK:-/dev/null}"; }
STUB
}

sink_lines() { # sink_lines <file> -> how many lines, 0 when the file was never written
  [ -f "$1" ] || { echo 0; return 0; }
  grep -c . "$1" 2>/dev/null || true
}

# BH-1194: bin/jobs-client.sh is a SHIM over bin/lib/jobs/*.sh, and it refuses to
# half-load — a copy of the client with no modules beside it `exit 1`s, and since
# every lane here SOURCES the client, the lane script dies with it. So a fixture
# that copies the client copies the modules too (the shape e008c9f3 gave the two
# other bare-tree fixtures); without this the flag-OFF cases go green for the
# wrong reason, having run no lane at all.
copy_jobs_client() { # copy_jobs_client <dest bin/ dir>
  cp "$DIR/bin/jobs-client.sh" "$1/" || return 1
  mkdir -p "$1/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$1/lib/jobs/"
}

echo "== A. bin/lib/ledger-twin.sh: the verbs, and the outage breaker =="

A="$T/A"
mkdir -p "$A/h/bin/lib" "$A/h/env" "$A/h/flags" "$A/h/logs" "$A/fakebin"
copy_jobs_client "$A/h/bin"
# The fixture itself is under test first: every module the shipped shim names on
# its literal JC_MODULES line has to be beside the copied client, or every lane
# in B/C/F below exits 1 on source and its flag-OFF cases pass having done
# nothing at all (that is the 60/36 shape BH-1194 produced here).
A_MODS=$(sed -n 's/^JC_MODULES="\(.*\)"$/\1/p' "$DIR/bin/jobs-client.sh" | head -1)
[ -n "$A_MODS" ] && ok || bad "A0: bin/jobs-client.sh no longer carries a literal JC_MODULES line"
A_MISS=""
for m in $A_MODS; do [ -r "$A/h/bin/lib/jobs/$m.sh" ] || A_MISS="$A_MISS $m"; done
[ -z "$A_MISS" ] && ok || bad "A0: copy_jobs_client left modules behind:$A_MISS"
cp "$DIR/bin/lib/env-path.sh" "$A/h/bin/lib/"
cp "$LT_LIB" "$A/h/bin/lib/" 2>/dev/null || true
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$A/h/env/global.env"
write_curl "$A/fakebin/curl"
printf 'review_autopilot\texample-org/demo-os#101@aaaaaaaaaaaa\treviewed\tverdict=MERGE\n' >  "$A/rows.tsv"
printf 'batch_member\texample-org/demo-os#101@deadbeef\tred\t\n'                           >> "$A/rows.tsv"
cat > "$A/drive.sh" <<'DRV'
#!/bin/bash
set -uo pipefail
if [ "${LT_NO_CLIENT:-}" != 1 ]; then
  # shellcheck source=/dev/null
  . "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1
fi
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/ledger-twin.sh" || exit 90
"$@"
DRV
a_drive() {
  ( export PATH="$A/fakebin:$PATH" HARNESS="$A/h" JOBS_BOX=testbox \
           HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
           REQ_LOG="$A/req.log" LEDGER_ROWS="$A/rows.tsv" JOBS_RETRIES=0 \
           CURL_MODE="${CURL_MODE:-ok}" LT_NO_CLIENT="${LT_NO_CLIENT:-}"
    bash "$A/drive.sh" "$@" )
}
flag_on()  { touch "$A/h/flags/no-twin-ledgers"; }
flag_off() { rm -f "$A/h/flags/no-twin-ledgers"; }
RK='example-org/demo-os#101@aaaaaaaaaaaa'

# A1. Flag OFF is the shipped default: no read, and — the part that matters —
# NO LEDGER TRAFFIC. The one request a dark lane still makes is flag_active's own
# reconcile of flags/no-twin-ledgers, which is how every DB-backed flag in the
# fleet works and is what makes the flag flippable from the hub at all.
flag_off; : > "$A/req.log"
OUT=$(a_drive lt_get review_autopilot "$RK"); RC=$?
[ "$RC" -eq 1 ] && ok || bad "A1: lt_get with the flag off must answer rc 1, got $RC ($OUT)"
grep -q '/api/ledger' "$A/req.log" && bad "A1: the flag being off must read no ledger row: $(cat "$A/req.log")" || ok
[ "$(grep -c . "$A/req.log")" = 1 ] && ok \
  || bad "A1: a dark lane must make exactly one request (the flag reconcile): $(cat "$A/req.log")"

# A2/A3/A4. With the flag on, lt_get is job_ledger_get's rc contract verbatim:
# 0 = the row's status, 2 = a real miss, 1 = the worker is unusable.
flag_on; : > "$A/req.log"
OUT=$(a_drive lt_get review_autopilot "$RK"); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = reviewed ] && ok || bad "A2: lt_get hit rc=$RC out='$OUT' (want 0/reviewed)"
grep -q 'GET https://jobs.test/api/ledger' "$A/req.log" && ok \
  || bad "A2: lt_get must GET /api/ledger: $(cat "$A/req.log")"
OUT=$(a_drive lt_get review_autopilot 'example-org/demo-os#999@zzzzzzzzzzzz'); RC=$?
[ "$RC" -eq 2 ] && ok || bad "A3: a real miss must be rc 2, got $RC ($OUT)"
OUT=$(CURL_MODE=down a_drive lt_get review_autopilot "$RK"); RC=$?
[ "$RC" -eq 1 ] && ok || bad "A4: an outage must be rc 1 (never a miss), got $RC ($OUT)"

# A5. lt_seen is "is there a row at all", whatever its status — a `red` row is
# seen. An outage is NOT seen: rc 1 must never read as "already done" (D9/D11).
a_drive lt_seen review_autopilot "$RK" >/dev/null 2>&1 \
  && ok || bad "A5: lt_seen must answer rc 0 for an existing row"
a_drive lt_seen batch_member 'example-org/demo-os#101@deadbeef' >/dev/null 2>&1 \
  && ok || bad "A5: lt_seen must answer rc 0 for a row of ANY status"
a_drive lt_seen review_autopilot 'example-org/demo-os#999@zzzzzzzzzzzz' >/dev/null 2>&1 \
  && bad "A5: a miss must not read as seen" || ok
CURL_MODE=down a_drive lt_seen review_autopilot "$RK" >/dev/null 2>&1 \
  && bad "A5: an OUTAGE must never read as seen" || ok

# A6. lt_put is write-through and fail-open: rc 0 always, one PUT when on.
: > "$A/req.log"
a_drive lt_put postmerge_qa 'demo-os-BH-1-202609190000' PASS abcd1234 >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A6: lt_put rc=$RC (want 0)"
REQ=$(grep 'PUT https://jobs.test/api/ledger' "$A/req.log" | tail -1)
[ -n "$REQ" ] && ok || bad "A6: lt_put made no PUT: $(cat "$A/req.log")"
BODY=$(printf '%s' "$REQ" | cut -d' ' -f3-)
printf '%s' "$BODY" | jq -e '.kind == "postmerge_qa" and .status == "PASS" and .detail == "abcd1234"' \
  >/dev/null 2>&1 && ok || bad "A6: lt_put body wrong: $BODY"
: > "$A/req.log"
CURL_MODE=down a_drive lt_put postmerge_qa 'demo-os-BH-1-202609190000' PASS >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A6: lt_put must stay rc 0 through an outage, got $RC"

# A7. Flag OFF: lt_put is a no-op that is not a failure, and makes no request.
flag_off; : > "$A/req.log"
a_drive lt_put postmerge_qa 'demo-os-BH-1-202609190000' PASS >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A7: lt_put with the flag off must be rc 0, got $RC"
grep -q '/api/ledger' "$A/req.log" && bad "A7: lt_put with the flag off wrote a row: $(cat "$A/req.log")" || ok

# A8. No client in the tree at all — today's tree on a box mid-sync. Every verb
# is a no-op, nothing is "seen", nothing throws, and lt_put is still rc 0.
flag_on; : > "$A/req.log"
LT_NO_CLIENT=1 a_drive lt_get review_autopilot "$RK" >/dev/null 2>&1; RC=$?
[ "$RC" -eq 1 ] && ok || bad "A8: lt_get without the client must be rc 1, got $RC"
LT_NO_CLIENT=1 a_drive lt_seen review_autopilot "$RK" >/dev/null 2>&1 \
  && bad "A8: lt_seen without the client must not read as seen" || ok
LT_NO_CLIENT=1 a_drive lt_put review_autopilot "$RK" reviewed >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A8: lt_put without the client must be rc 0, got $RC"
[ ! -s "$A/req.log" ] && ok || bad "A8: a client-less tree made a request: $(cat "$A/req.log")"

# A9. THE OUTAGE BREAKER (r1 I3). A worker that REFUSES is cheap; one that HANGS
# costs JOBS_TIMEOUT x retries per call, and these verbs run once per candidate.
# So the first unusable read latches the library off for the rest of the
# process: three lt_seen calls in ONE process make exactly one ledger request.
# `eval` keeps them in the same shell — the latch is a shell variable, and a
# `$( )` around the second call would hide the first call's answer from it.
flag_on; : > "$A/req.log"
a_drive eval "lt_seen review_autopilot '$RK'; lt_seen review_autopilot '$RK'; lt_seen review_autopilot '$RK'" \
  >/dev/null 2>&1
[ "$(grep -c '/api/ledger' "$A/req.log")" = 3 ] && ok \
  || bad "A9: a healthy worker must be asked every time: $(grep -c '/api/ledger' "$A/req.log")"
: > "$A/req.log"
CURL_MODE=down a_drive eval "lt_seen review_autopilot '$RK'; lt_seen review_autopilot '$RK'; lt_seen review_autopilot '$RK'" \
  >/dev/null 2>&1
[ "$(grep -c '/api/ledger' "$A/req.log")" = 1 ] && ok \
  || bad "A9: an outage must be paid for once per process, not once per candidate: $(grep -c '/api/ledger' "$A/req.log")"

# A9'. Latched off is still FAIL-OPEN in the documented direction: a read is
# never "already done" and a write is still rc 0 (and silent).
: > "$A/req.log"
CURL_MODE=down a_drive eval "lt_seen review_autopilot '$RK'; lt_seen review_autopilot '$RK'" \
  >/dev/null 2>&1 && bad "A9': a latched-off read must never answer 'seen'" || ok
: > "$A/req.log"
CURL_MODE=down a_drive eval "lt_seen review_autopilot '$RK'; lt_put review_autopilot '$RK' reviewed" \
  >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && ok || bad "A9': a latched-off lt_put must still be rc 0, got $RC"
[ "$(grep -c '/api/ledger' "$A/req.log")" = 1 ] && ok \
  || bad "A9': the latched-off write must make no request: $(grep -c '/api/ledger' "$A/req.log")"

# A10. A REAL MISS IS NOT AN OUTAGE and must not trip the breaker — otherwise
# the first genuinely new candidate turns the rest of the tick blind, which is
# exactly the "row says nothing, so re-buy everything" failure this ships to
# prevent. Miss first, then a hit: the hit is still found.
: > "$A/req.log"
a_drive eval "lt_seen review_autopilot 'example-org/demo-os#999@zzzzzzzzzzzz'; lt_seen review_autopilot '$RK'" \
  >/dev/null 2>&1 && ok || bad "A10: a miss must not latch the library off"
[ "$(grep -c '/api/ledger' "$A/req.log")" = 2 ] && ok \
  || bad "A10: both reads must reach the worker: $(grep -c '/api/ledger' "$A/req.log")"

# A11. lt_read is the value read with the same breaker (the callers that want a
# status cannot use `$(lt_get ...)` — a latch set in a command substitution dies
# with it). Hit sets LT_VAL; an outage latches and the next read is free.
OUT=$(a_drive eval "lt_read review_autopilot '$RK' && printf '%s' \"\$LT_VAL\""); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = reviewed ] && ok || bad "A11: lt_read hit rc=$RC out='$OUT' (want 0/reviewed)"
OUT=$(a_drive eval "lt_read review_autopilot 'example-org/demo-os#999@zzzzzzzzzzzz'; printf '[%s]' \"\$LT_VAL\""); RC=$?
[ "$OUT" = '[]' ] && ok || bad "A11: a miss must leave LT_VAL empty, got '$OUT'"
: > "$A/req.log"
CURL_MODE=down a_drive eval "lt_read review_autopilot '$RK'; lt_seen review_autopilot '$RK'" >/dev/null 2>&1
[ "$(grep -c '/api/ledger' "$A/req.log")" = 1 ] && ok \
  || bad "A11: an lt_read outage must latch the breaker too: $(grep -c '/api/ledger' "$A/req.log")"

echo "== B. bin/review-autopilot.sh: the head marker and the daily cap =="

B="$T/B"
mkdir -p "$B/h/bin/lib" "$B/h/env" "$B/h/logs" "$B/h/locks" "$B/h/state" "$B/h/flags" "$B/fakebin"
sed 's|^H=/root/harness$|H="${HARNESS:-/root/harness}"|' "$DIR/bin/review-autopilot.sh" \
  > "$B/h/bin/review-autopilot.sh"
chmod +x "$B/h/bin/review-autopilot.sh"
grep -qF 'H="${HARNESS:-/root/harness}"' "$B/h/bin/review-autopilot.sh" && ok \
  || bad "B: the scratch-root rewrite did not match — this section would drive /root/harness"
copy_jobs_client "$B/h/bin"
cp "$DIR/bin/lib/env-path.sh" "$B/h/bin/lib/"
cp "$LT_LIB" "$B/h/bin/lib/" 2>/dev/null || true
cp "$DIR/bin/fleet-conf.sh" "$B/h/bin/"; chmod +x "$B/h/bin/fleet-conf.sh"
printf 'demo-os example-org/demo-os https://demo.test - 2 box-demo\n' > "$B/h/fleet.conf"
# BH-1510.1: the reviewer's model is a model_routes row, read through review_model;
# this box carries the resolver's cache of #1507's table.
cp "$DIR/bin/lib/review-model.sh" "$B/h/bin/lib/"
mrs_fixture "$B/h" demo-os
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$B/h/env/global.env"
write_curl "$B/fakebin/curl"
# The PR list lib is the network edge, so it is the stub: the lane's own
# selection (draft, age, author set) is bin/lib/gh-pr-list.sh's contract and is
# pinned by tests/harness-pr-authors-test.sh.
cat > "$B/h/bin/lib/gh-pr-list.sh" <<'PRL'
harness_pr_list() { cat "$PRS_JSON"; }
PRL
cat > "$B/fakebin/gh" <<'GH'
#!/bin/bash
printf 'GH %s\n' "$*" >> "$GH_SINK"
[ -n "${ORDER_LOG:-}" ] && printf 'GH %s\n' "$*" >> "$ORDER_LOG"
case "$*" in
  *"pr diff"*--name-only*) echo "src/a.ts" ;;
  *"pr diff"*) printf 'diff --git a/src/a.ts b/src/a.ts\n+one line\n' ;;
  *"--json body"*) echo "the PR body" ;;
  *mergeable*) echo "mergeable=MERGEABLE mergeState=CLEAN checks=ci=SUCCESS" ;;
esac
exit 0
GH
chmod +x "$B/fakebin/gh"
cat > "$B/h/bin/agent-call.sh" <<'AC'
#!/bin/bash
printf 'AGENT %s\n' "$1" >> "$AGENT_SINK"
[ -n "${ORDER_LOG:-}" ] && printf 'AGENT %s\n' "$1" >> "$ORDER_LOG"
printf 'Nothing blocking here.\n\nVERDICT: MERGE — looks good\n' > "$5"
exit 0
AC
chmod +x "$B/h/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$B/h/bin/beat.sh"; chmod +x "$B/h/bin/beat.sh"
B_HEAD=aaaaaaaaaaaabbbbccccddddeeeeffff11112222
B_H12=${B_HEAD:0:12}
B_RK="example-org/demo-os#101@$B_H12"
B_DAY=$(date -u +%Y%m%d)
jq -nc --arg h "$B_HEAD" \
  '[{number:101,createdAt:"2026-01-01T00:00:00Z",headRefOid:$h,title:"T1",isDraft:false}]' \
  > "$B/prs.json"

b_run() { # b_run [env...]
  scratch_rm "$B/h/state/review-autopilot"; mkdir -p "$B/h/state/review-autopilot"
  : > "$B/h/logs/review-autopilot.log"; : > "$B/gh.txt"; : > "$B/req.log"; : > "$B/order.log"
  rm -f "$B/agent.txt"
  env -i PATH="$B/fakebin:/usr/bin:/bin" HOME="$B" HARNESS="$B/h" FLEET_CONF="$B/h/fleet.conf" \
      JOBS_BOX=testbox JOBS_RETRIES=0 PRS_JSON="$B/prs.json" GH_SINK="$B/gh.txt" \
      AGENT_SINK="$B/agent.txt" REQ_LOG="$B/req.log" ORDER_LOG="$B/order.log" \
      LEDGER_ROWS="$B/rows.tsv" "$@" \
      bash "$B/h/bin/review-autopilot.sh" >/dev/null 2>&1
}
b_agent() { sink_lines "$B/agent.txt"; }

# B1. The hub-wipe case: nothing on disk, a `reviewed` row for exactly this
# head. No review is bought and no comment is posted.
printf 'review_autopilot\t%s\treviewed\tverdict=MERGE\n' "$B_RK" > "$B/rows.tsv"
touch "$B/h/flags/no-twin-ledgers"
b_run
[ "$(b_agent)" = 0 ] && ok || bad "B1: a reviewed row must stop the review being bought (agent: $(cat "$B/agent.txt" 2>/dev/null))"
grep -q 'pr comment' "$B/gh.txt" && bad "B1: no comment may be posted for a head already reviewed" || ok

# B1'. A row for a DIFFERENT head is not this head. The review is bought.
printf 'review_autopilot\texample-org/demo-os#101@0000deadbeef\treviewed\tverdict=MERGE\n' > "$B/rows.tsv"
b_run
[ "$(b_agent)" = 1 ] && ok || bad "B1': a row at another head must NOT dedup this head (agent: $(b_agent))"

# B2. The daily cap survives a wipe. Row says 40, no count file, cap 40.
printf 'review_autopilot_cap\tdemo-os %s\t40\t\n' "$B_DAY" > "$B/rows.tsv"
b_run REVIEW_AUTOPILOT_DAILY_CAP=40
[ "$(b_agent)" = 0 ] && ok || bad "B2: a cap row of 40 with cap 40 must buy nothing (agent: $(b_agent))"
grep -q 'daily review cap 40 reached' "$B/h/logs/review-autopilot.log" && ok \
  || bad "B2: the cap stop must be logged: $(cat "$B/h/logs/review-autopilot.log")"

# B2'. A cap row LOWER than the count file never lowers the ceiling (D11: the
# safer of the two wins, so a blip cannot buy a 41st review).
printf 'review_autopilot_cap\tdemo-os %s\t3\t\n' "$B_DAY" > "$B/rows.tsv"
scratch_rm "$B/h/state/review-autopilot"; mkdir -p "$B/h/state/review-autopilot"
echo 40 > "$B/h/state/review-autopilot/count-demo-os-$B_DAY"
: > "$B/h/logs/review-autopilot.log"; : > "$B/gh.txt"; rm -f "$B/agent.txt"
env -i PATH="$B/fakebin:/usr/bin:/bin" HOME="$B" HARNESS="$B/h" FLEET_CONF="$B/h/fleet.conf" \
    JOBS_BOX=testbox JOBS_RETRIES=0 PRS_JSON="$B/prs.json" GH_SINK="$B/gh.txt" \
    AGENT_SINK="$B/agent.txt" REQ_LOG="$B/req.log" ORDER_LOG="$B/order.log" \
    LEDGER_ROWS="$B/rows.tsv" REVIEW_AUTOPILOT_DAILY_CAP=40 \
    bash "$B/h/bin/review-autopilot.sh" >/dev/null 2>&1
[ "$(b_agent)" = 0 ] && ok || bad "B2': the file count must still cap when the row is lower (agent: $(b_agent))"

# B3. Flag OFF with the very same rows: today's behaviour, spend happens.
rm -f "$B/h/flags/no-twin-ledgers"
printf 'review_autopilot\t%s\treviewed\tverdict=MERGE\n' "$B_RK" > "$B/rows.tsv"
printf 'review_autopilot_cap\tdemo-os %s\t40\t\n' "$B_DAY" >> "$B/rows.tsv"
b_run REVIEW_AUTOPILOT_DAILY_CAP=40
[ "$(b_agent)" = 1 ] && ok || bad "B3: with the flag off the rows must change nothing (agent: $(b_agent))"

# B4. The write-through order, flag on and no rows: the review is bought, the
# marker FILE is written, and the row follows it. The file is the cache, so it
# can never be the thing that is missing after a successful post.
touch "$B/h/flags/no-twin-ledgers"
: > "$B/rows.tsv"
b_run
[ "$(b_agent)" = 1 ] && ok || bad "B4: an empty ledger must buy exactly one review (agent: $(b_agent))"
[ -f "$B/h/state/review-autopilot/example-org-demo-os-101-$B_H12" ] && ok \
  || bad "B4: the marker file must still be written (the one-cycle write-through cache)"
grep -q 'PUT https://jobs.test/api/ledger' "$B/req.log" && ok \
  || bad "B4: no ledger PUT was made: $(cat "$B/req.log")"
grep 'PUT https://jobs.test/api/ledger' "$B/req.log" | cut -d' ' -f3- \
  | jq -se 'map(select(.kind == "review_autopilot" and .status == "reviewed")) | length == 1' \
  >/dev/null 2>&1 && ok || bad "B4: no review_autopilot/reviewed row was written: $(grep PUT "$B/req.log")"
grep 'PUT https://jobs.test/api/ledger' "$B/req.log" | cut -d' ' -f3- \
  | jq -se 'map(select(.kind == "review_autopilot_cap" and .status == "1")) | length == 1' \
  >/dev/null 2>&1 && ok || bad "B4: the cap row must be written with the new count: $(grep PUT "$B/req.log")"
# The spend is counted BEFORE the comment goes out, exactly as the file half is.
CAPLINE=$(grep -n 'CURL PUT' "$B/order.log" | head -1 | cut -d: -f1)
CMTLINE=$(grep -n 'GH pr comment' "$B/order.log" | head -1 | cut -d: -f1)
[ -n "$CAPLINE" ] && [ -n "$CMTLINE" ] && [ "$CAPLINE" -lt "$CMTLINE" ] && ok \
  || bad "B4: the cap row must be written before the comment (cap=$CAPLINE comment=$CMTLINE)"

# B5. THE CAP ROW IS READ ONCE PER TICK, not once per open PR (r1 I3). The count
# cannot change inside a tick except by this lane's own writes, which move the
# count FILE in the same breath — so a per-PR read bought nothing and multiplied
# the cost of a hung worker by the length of the PR list. Three open PRs, empty
# ledger: three head reads (one per PR, they are different keys) and exactly one
# cap read.
jq -nc --arg h "$B_HEAD" \
  '[{number:101,createdAt:"2026-01-01T00:00:00Z",headRefOid:$h,title:"T1",isDraft:false},
    {number:102,createdAt:"2026-01-01T00:00:00Z",headRefOid:"bbbbbbbbbbbbccccddddeeeeffff111122223333",title:"T2",isDraft:false},
    {number:103,createdAt:"2026-01-01T00:00:00Z",headRefOid:"ccccccccccccddddeeeeffff11112222333344445",title:"T3",isDraft:false}]' \
  > "$B/prs3.json"
: > "$B/rows.tsv"
b_run PRS_JSON="$B/prs3.json"
[ "$(b_agent)" = 3 ] && ok || bad "B5: three new heads must buy three reviews (agent: $(b_agent))"
[ "$(grep -c 'GET https://jobs.test/api/ledger?kind=review_autopilot_cap' "$B/req.log")" = 1 ] && ok \
  || bad "B5: the cap row must be read once per tick, got $(grep -c 'GET https://jobs.test/api/ledger?kind=review_autopilot_cap' "$B/req.log")"
[ "$(grep -c 'GET https://jobs.test/api/ledger?kind=review_autopilot&' "$B/req.log")" = 3 ] && ok \
  || bad "B5: each head is its own key and must still be read: $(grep -c 'GET https://jobs.test/api/ledger?kind=review_autopilot&' "$B/req.log")"

# B5'. And with the worker DOWN the whole tick pays for one request, not one per
# PR — the breaker, seen from the lane that has the loop.
b_run PRS_JSON="$B/prs3.json" CURL_MODE=down
[ "$(grep -c '/api/ledger' "$B/req.log")" -le 2 ] && ok \
  || bad "B5': a dead worker must not be paid for per PR: $(grep -c '/api/ledger' "$B/req.log")"

echo "== C. bin/lander.sh: one attempt per PR head =="

C="$T/C"
mkdir -p "$C/h/bin/lib" "$C/h/env" "$C/h/logs" "$C/h/flags" "$C/h/state" "$C/fakebin" "$C/h/repos/project-3"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$C/h" project-3 || exit 1  # BH-1510.2: lanes read models from model_routes
# Two roots are rewritten, both hardcoded literals this ticket does not touch:
# the harness root (bin/lander.sh is on tests/env-path-allowlist.d/port-b.txt)
# and /root/repos/<project>, which a scratch tree has no other way to redirect.
sed -e 's|^HARNESS=/root/harness$|HARNESS="${HARNESS:-/root/harness}"|' \
    -e 's|^REPO_DIR="/root/repos/\$PROJECT"$|REPO_DIR="$HARNESS/repos/$PROJECT"|' \
    "$DIR/bin/lander.sh" > "$C/h/bin/lander.sh"
chmod +x "$C/h/bin/lander.sh"
grep -qF 'HARNESS="${HARNESS:-/root/harness}"' "$C/h/bin/lander.sh" && ok \
  || bad "C: the scratch-root rewrite did not match — this section would drive /root/harness"
grep -qF 'REPO_DIR="$HARNESS/repos/$PROJECT"' "$C/h/bin/lander.sh" && ok \
  || bad "C: the repo-root rewrite did not match — this section would drive /root/repos"
copy_jobs_client "$C/h/bin"
cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/deployment.sh" "$C/h/bin/lib/"
# BH-4080: the lander reads the repo slug from fleet.conf (no literal table).
cp "$DIR/bin/fleet-conf.sh" "$C/h/bin/" && printf 'project-3 example-org/project-3\n' > "$C/h/fleet.conf"
cp "$LT_LIB" "$C/h/bin/lib/" 2>/dev/null || true
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$C/h/env/global.env"
write_curl "$C/fakebin/curl"
C_HEAD=cafe1234cafe1234cafe1234cafe1234cafe1234
cat > "$C/fakebin/gh" <<'GH'
#!/bin/bash
printf 'GH %s\n' "$*" >> "$GH_SINK"
case "$*" in
  *headRefName,headRefOid*) printf '%s %s\n' "feat/x" "$PR_HEAD" ;;
esac
exit 0
GH
chmod +x "$C/fakebin/gh"
# The git stub: enough of a merge to reach the conflict branch, and a recorder
# so "no worktree was ever made" is a claim about a command that did not run.
cat > "$C/fakebin/git" <<'GIT'
#!/bin/bash
printf 'GIT %s\n' "$*" >> "$GIT_SINK"
case "$*" in
  *"status --porcelain"*) echo "UU src/a.ts" ;;
  *merge*) exit 1 ;;
esac
exit 0
GIT
chmod +x "$C/fakebin/git"
cat > "$C/h/bin/agent-call.sh" <<'AC'
#!/bin/bash
printf 'AGENT %s\n' "$1" >> "$AGENT_SINK"
[ -n "${ORDER_LOG:-}" ] && printf 'AGENT %s\n' "$1" >> "$ORDER_LOG"
printf 'LANDER_BLOCKED: the stub declines, so nothing is pushed\n' > "$5"
exit 0
AC
chmod +x "$C/h/bin/agent-call.sh"
printf '#!/bin/bash\nexit 0\n' > "$C/h/bin/beat.sh"; chmod +x "$C/h/bin/beat.sh"

c_run() {
  scratch_rm "$C/h/state/lander"; mkdir -p "$C/h/state/lander"
  : > "$C/gh.txt"; : > "$C/git.txt"; : > "$C/req.log"; : > "$C/order.log"
  rm -f "$C/agent.txt"
  env -i PATH="$C/fakebin:/usr/bin:/bin" HOME="$C" HARNESS="$C/h" JOBS_BOX=testbox \
      JOBS_RETRIES=0 PR_HEAD="$C_HEAD" GH_SINK="$C/gh.txt" GIT_SINK="$C/git.txt" \
      AGENT_SINK="$C/agent.txt" REQ_LOG="$C/req.log" ORDER_LOG="$C/order.log" \
      LEDGER_ROWS="$C/rows.tsv" "$@" \
      bash "$C/h/bin/lander.sh" project-3 7 >/dev/null 2>&1
}

# C1. Empty state/lander, a `lander` row at this exact head: no attempt, no
# worktree, no agent session.
printf 'lander\tproject-3#7@%s\tattempted\t\n' "$C_HEAD" > "$C/rows.tsv"
touch "$C/h/flags/no-twin-ledgers"
c_run; RC=$?
[ "$RC" -eq 1 ] && ok || bad "C1: an already-attempted head must exit 1, got $RC"
[ "$(sink_lines "$C/agent.txt")" = 0 ] && ok || bad "C1: no resolution session may be bought"
grep -q 'worktree add' "$C/git.txt" && bad "C1: no worktree may be created" || ok
grep -q 'already attempted' "$C/h/logs/lander.log" && ok \
  || bad "C1: the stand-down must be logged: $(tail -2 "$C/h/logs/lander.log" 2>/dev/null)"

# C2. A row at ANOTHER head is a different attempt: the mark is written, the row
# is written, and both land BEFORE the agent is called.
printf 'lander\tproject-3#7@0000000000000000000000000000000000000000\tattempted\t\n' > "$C/rows.tsv"
c_run
[ "$(sink_lines "$C/agent.txt")" = 1 ] && ok \
  || bad "C2: a new head must buy exactly one resolution attempt (got $(sink_lines "$C/agent.txt"))"
[ "$(cat "$C/h/state/lander/project-3-7" 2>/dev/null)" = "$C_HEAD" ] && ok \
  || bad "C2: the mark file must carry the head"
grep 'PUT https://jobs.test/api/ledger' "$C/req.log" | cut -d' ' -f3- \
  | jq -se 'map(select(.kind == "lander" and .status == "attempted")) | length == 1' \
  >/dev/null 2>&1 && ok || bad "C2: no lander row was written: $(grep PUT "$C/req.log")"
PUTLINE=$(grep -n 'CURL PUT' "$C/order.log" | head -1 | cut -d: -f1)
AGLINE=$(grep -n '^AGENT ' "$C/order.log" | head -1 | cut -d: -f1)
[ -n "$PUTLINE" ] && [ -n "$AGLINE" ] && [ "$PUTLINE" -lt "$AGLINE" ] && ok \
  || bad "C2: the claim must be recorded before the session is bought (put=$PUTLINE agent=$AGLINE)"

# C3. Flag off with the same row: today's file-only path, the attempt proceeds.
rm -f "$C/h/flags/no-twin-ledgers"
printf 'lander\tproject-3#7@%s\tattempted\t\n' "$C_HEAD" > "$C/rows.tsv"
c_run
[ "$(sink_lines "$C/agent.txt")" = 1 ] && ok \
  || bad "C3: with the flag off the row must not dedup (got $(sink_lines "$C/agent.txt"))"
touch "$C/h/flags/no-twin-ledgers"

echo "== D. bin/batch-resolve.sh: train membership =="

D="$T/D"
mkdir -p "$D" "$D/fakebin" "$D/repos"
SLUG=example-org/demo-os
PROJ=demo-os
if ! command -v git >/dev/null; then
  echo "git missing — skipping section D"
else
export GIT_CONFIG_GLOBAL="$D/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name t
git config --global init.defaultBranch main
git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global "url.$D/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$D/origin.git.insteadOf" "https://github.com/$SLUG.git" --add
git init -q --bare "$D/origin.git"
git clone -q "$D/origin.git" "$D/seed" 2>/dev/null
S="$D/seed"
mkdir -p "$S/src" "$S/scripts" "$S/tests"
printf 'tests/static-guards.txt merge=union\n' > "$S/.gitattributes"
printf 'guard-base\n' > "$S/tests/static-guards.txt"
printf '{"imports":["src/base.ts"]}\n' > "$S/scripts/worker-import-set.json"
printf 'export const base = 1\n' > "$S/src/base.ts"
cat > "$S/scripts/regen.sh" <<REGEN
#!/bin/sh
ls src/*.ts | sort | jq -R . | jq -sc '{imports:.}' > scripts/worker-import-set.json
REGEN
chmod +x "$S/scripts/regen.sh"
printf '#!/bin/sh\nexit 0\n' > "$S/ci-stub.sh"; chmod +x "$S/ci-stub.sh"
cat > "$S/AGENT_ARCHITECTURE.md" <<'ARCH'
# Architecture

## Generated files

| File | Regenerate with |
|---|---|
| `scripts/worker-import-set.json` | `bash scripts/regen.sh` |
ARCH
cat > "$S/CLAUDE.md" <<'CLAUDEMD'
# demo-os

## Verification Contract

```bash
bash ci-stub.sh
```
CLAUDEMD
git -C "$S" add -A && git -C "$S" commit -qm base >/dev/null && git -C "$S" push -q origin main
D_BASE=$(git -C "$S" rev-parse HEAD)
mkbranch() {
  local br="$1" m="$2"
  git -C "$S" checkout -q -b "$br" "$D_BASE"
  printf 'export const %s = 1\n' "$m" > "$S/src/feature-$m.ts"
  printf 'guard-base\nguard-%s\n' "$m" > "$S/tests/static-guards.txt"
  printf '{"imports":["src/base.ts","src/feature-%s.ts"]}\n' "$m" > "$S/scripts/worker-import-set.json"
  git -C "$S" add -A && git -C "$S" commit -qm "$m" >/dev/null && git -C "$S" push -q origin "$br"
  git -C "$S" rev-parse HEAD
}
HEAD_A=$(mkbranch ticket/tk-11 a)
HEAD_B=$(mkbranch ticket/tk-12 b)
HEAD_C=$(mkbranch ticket/tk-13 c)
git -C "$S" checkout -q main

DH="$D/h"
mkdir -p "$DH/bin/lib" "$DH/logs" "$DH/state" "$DH/flags" "$DH/locks" "$DH/builds" "$DH/env" "$DH/tmp"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/env-path.sh" \
   "$DIR/bin/lib/hotfix-lib.sh" "$DH/bin/lib/"
# BH-680 (#929): merge-conductor-lib.sh is a shim that sources bin/lib/mc/*.sh and
# aborts when they are missing — a fixture that copies only the shim gets a
# conductor with no verbs, and batch-resolve.sh then builds no train at all.
mkdir -p "$DH/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$DH/bin/lib/mc/"
# BH-781 (#1094, landed on main after this branch's r1 rebase): batch-resolve.sh's
# close-out comment/close/head-moved notice moved onto bin/lib/gh-rest.sh. Without
# a copy here, gh_rest_comment/gh_rest_close/gh_rest_pr_state are undefined —
# "command not found" under set -u, `!`-negated to "true", so settle_member
# returns 1 having never called gh at all. That is a fixture gap this rebase
# owes, not a change to what D5-D7 assert.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DH/bin/lib/"
cp "$LT_LIB" "$DH/bin/lib/" 2>/dev/null || true
cp "$DIR/bin/batch-resolve.sh" "$DIR/bin/fleet-conf.sh" "$DH/bin/"
# BH-1606: a train opens only as the App (never the lead PAT), so this box can mint one.
cp "$DIR/bin/lib/gh-app-auth.sh" "$DH/bin/lib/"; : > "$DH/env/github-app.env"
# TEST-CHANGE (BH-1630): the lane now reads the token's expiry (`gh-token.sh
# --expires-at`) before it pushes a union, so the stub answers one, far ahead.
printf '#!/bin/bash\n[ "${1:-}" = --expires-at ] && { echo 2099-01-01T00:00:00Z; exit 0; }\necho ghs_fixture_installation_token\n' > "$DH/bin/gh-token.sh"; chmod +x "$DH/bin/gh-token.sh"
printf '%s %s https://demo.example - 2 box-demo\n' "$PROJ" "$SLUG" > "$DH/fleet.conf"
: > "$DH/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$DH/bin/beat.sh"; chmod +x "$DH/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$DH/bin/lane-alert.sh"; chmod +x "$DH/bin/lane-alert.sh"
# The client stub is the batch-resolve-test shape plus the two verbs this ticket
# reads: the flag (file-backed, exactly as flag_active resolves it) and the
# ledger GET (fixture-backed and key-aware, so a neighbour row can miss).
cat > "$DH/bin/jobs-client.sh" <<EOF
job_ledger_put() { printf '%s\t%s\t%s\t%s\n' "\$1" "\$2" "\$3" "\${4:-}" >> "$D/ledger.tsv"; }
job_ledger_get() {
  local st
  st=\$(awk -F'\t' -v k="\$1" -v v="\$2" '\$1==k && \$2==v {print \$3; exit}' "\${LEDGER_ROWS:-/dev/null}" 2>/dev/null)
  [ -n "\$st" ] || return 2
  printf '%s' "\$st"
}
flag_active() { [ -f "$DH/flags/\$1" ]; }
merge_queue_put() { printf '%s\t%s\t%s\n' "\$1" "\$2" "\${4:-}" >> "$D/mqueue.tsv"; echo queued; }
EOF
git clone -q "$D/origin.git" "$D/repos/$PROJ" 2>/dev/null
cat > "$D/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$D/gh-calls.txt"
num=\$(printf '%s\n' "\$*" | grep -oE '(pull|pulls|issues)/[0-9]+' | head -1 | grep -oE '[0-9]+')
case "\$*" in
  *"auth token"*) echo faketoken; exit 0 ;;
  *"--json headRefOid"*)
    jq -r --arg n "\$num" '.[]|select(.number==(\$n|tonumber))|.headRefOid' "$D/prs.json"; exit 0 ;;
  *"contents/.mergify.yml"*) exit 1 ;;
  # BH-781: settle_member's close-out now goes through bin/lib/gh-rest.sh, which
  # parses a real HTTP status line and — for a GET — a real body. The PATCH
  # marks the number closed in a small file so the RE-READ gh_rest_close does
  # right after (and the pre-read at the top of settle_member) agree with each
  # other: open before the PATCH, closed after.
  *"api -i -X POST "*"/comments"*)
    printf 'HTTP/1.1 200 OK

{}'; exit 0 ;;
  *"api -i -X PATCH "*"state=closed"*)
    [ -n "\$num" ] && echo "\$num" >> "$D/gh-closed.txt"
    printf 'HTTP/1.1 200 OK

{}'; exit 0 ;;
  *"api -i -X GET "*"/pulls/"*)
    if [ -n "\$num" ] && grep -qxF "\$num" "$D/gh-closed.txt" 2>/dev/null; then
      printf 'HTTP/1.1 200 OK

{"state":"closed"}'
    else
      printf 'HTTP/1.1 200 OK

{"state":"open"}'
    fi
    exit 0 ;;
  *"api -i -X GET "*"/issues/"*)
    if [ -n "\$num" ] && grep -qxF "\$num" "$D/gh-closed.txt" 2>/dev/null; then
      printf 'HTTP/1.1 200 OK

{"state":"closed"}'
    else
      printf 'HTTP/1.1 200 OK

{"state":"open"}'
    fi
    exit 0 ;;
  *"/pulls/"*"/files"*)
    jqx=""; want=0
    for a in "\$@"; do
      [ "\$want" = 1 ] && { jqx="\$a"; want=0; continue; }
      case "\$a" in --jq|-q) want=1 ;; esac
    done
    printf '[]' | jq -r "\${jqx:-.}"; exit 0 ;;
  *"--json comments"*)
    jqx=""; want=0
    for a in "\$@"; do
      [ "\$want" = 1 ] && { jqx="\$a"; want=0; continue; }
      case "\$a" in --jq|-q) want=1 ;; esac
    done
    printf '{"comments":[]}' | jq -r "\${jqx:-.}"; exit 0 ;;
  *"pr list -R $SLUG --state open --author"*) cat "$D/prs.json"; exit 0 ;;
  *"pr list"*) echo '[]'; exit 0 ;;
  *"pr create"*)
    prev=""; for a in "\$@"; do
      [ "\$prev" = "--body-file" ] && cp "\$a" "$D/train-body.txt"
      prev="\$a"
    done
    echo "https://github.com/$SLUG/pull/900"; exit 0 ;;
  *"pr view https://github.com/$SLUG/pull/9"*)
    cat "$D/train-state.json" 2>/dev/null || echo '{}'; exit 0 ;;
  *"issue view"*) echo OPEN; exit 0 ;;
esac
exit 0
EOF
chmod +x "$D/fakebin/gh"
command -v flock >/dev/null 2>&1 || { printf '#!/bin/sh\nexit 0\n' > "$D/fakebin/flock"; chmod +x "$D/fakebin/flock"; }
mkpr() {
  jq -nc --arg n "$1" --arg br "$2" --arg h "$3" --arg slug "$SLUG" --arg c "$4" '
    {number:($n|tonumber), url:("https://github.com/"+$slug+"/pull/"+$n),
     headRefOid:$h, headRefName:$br, baseRefName:"main", isDraft:false,
     mergeStateStatus:"CLEAN", mergeable:"MERGEABLE", state:"OPEN", createdAt:$c, labels:[]}'
}
{ mkpr 101 ticket/tk-11 "$HEAD_A" 2026-09-16T01:00:00Z
  mkpr 102 ticket/tk-12 "$HEAD_B" 2026-09-16T02:00:00Z
  mkpr 103 ticket/tk-13 "$HEAD_C" 2026-09-16T03:00:00Z; } | jq -sc '.' > "$D/prs.json"
mkrec() {
  local d="$DH/builds/$PROJ-TK-$1-2026091600$1"
  mkdir -p "$d"
  echo "PR_CREATED https://github.com/$SLUG/pull/$2" > "$d/RESULT"
  printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
  echo "$3" > "$d/reviewed-sha"
}
mkrec 11 101 "$HEAD_A"; mkrec 12 102 "$HEAD_B"; mkrec 13 103 "$HEAD_C"

d_reset() {
  : > "$D/gh-calls.txt"; : > "$D/ledger.tsv"; : > "$D/mqueue.tsv"; : > "$D/gh-closed.txt"
  : > "$DH/logs/batch-resolve.log"; : > "$D/run.out"
  rm -f "$D/train-body.txt" "$D/train-state.json"
  scratch_rm "$DH/state/batch-resolve"; scratch_rm "$DH/state/merge-conductor"
  scratch_rm "$DH/state/merge-queue"
  rm -f "$DH/tmp/merge-queue-"*.provider 2>/dev/null
  git -C "$D/origin.git" for-each-ref --format='%(refname)' 'refs/heads/batch/' \
    | while read -r r; do git -C "$D/origin.git" update-ref -d "$r"; done
}
d_run() {
  env PATH="$D/fakebin:$PATH" HARNESS="$DH" FLEET_CONF="$DH/fleet.conf" MC_REPOS="$D/repos" \
      GIT_CONFIG_GLOBAL="$D/gitconfig" GIT_CONFIG_NOSYSTEM=1 LEDGER_ROWS="$D/rows.tsv" \
      bash "$DH/bin/batch-resolve.sh" "$PROJ" >> "$D/run.out" 2>&1
}
ghcount() { grep -c "$1" "$D/gh-calls.txt" 2>/dev/null || true; }

# D1. Empty state dir, a `landed` row for #101 at its head. #101 must not be in
# the train; #102 and #103 still are, so the train is really built.
touch "$DH/flags/no-twin-ledgers"
d_reset
printf 'batch_member\t%s#101@%s\tlanded\t\n' "$SLUG" "$HEAD_A" > "$D/rows.tsv"
d_run
[ -f "$D/train-body.txt" ] && ok || bad "D1: no train PR was opened: $(tail -5 "$DH/logs/batch-resolve.log")"
grep -q '#101' "$D/train-body.txt" 2>/dev/null \
  && bad "D1: a member with a landed row must not be batched again: $(cat "$D/train-body.txt")" || ok
grep -q '#102' "$D/train-body.txt" 2>/dev/null && grep -q '#103' "$D/train-body.txt" 2>/dev/null && ok \
  || bad "D1: the other members must still form the train: $(cat "$D/train-body.txt" 2>/dev/null)"

# D2. A `red` row excludes just the same — it is the "this union already went
# red" record, and re-batching it rebuilds the same red union for ever.
d_reset
printf 'batch_member\t%s#101@%s\tred\t\n' "$SLUG" "$HEAD_A" > "$D/rows.tsv"
d_run
grep -q '#101' "$D/train-body.txt" 2>/dev/null \
  && bad "D2: a red row must exclude the member too" || ok

# D3. A row for a NEIGHBOURING head does not exclude anything.
d_reset
printf 'batch_member\t%s#101@%s\tlanded\t\n' "$SLUG" "${HEAD_B}" > "$D/rows.tsv"
d_run
grep -q '#101' "$D/train-body.txt" 2>/dev/null && ok \
  || bad "D3: a row at another head must not exclude #101: $(cat "$D/train-body.txt" 2>/dev/null)"

# D4. Flag OFF with every row present: today's behaviour, #101 is batched.
rm -f "$DH/flags/no-twin-ledgers"
d_reset
printf 'batch_member\t%s#101@%s\tlanded\t\n' "$SLUG" "$HEAD_A" > "$D/rows.tsv"
d_run
grep -q '#101' "$D/train-body.txt" 2>/dev/null && ok \
  || bad "D4: with the flag off the row must change nothing: $(cat "$D/train-body.txt" 2>/dev/null)"
touch "$DH/flags/no-twin-ledgers"

# D5. THE SETTLE GUARD. The train merged and #101 was settled, but the state
# directory is gone — only the row survives. #101 must not be commented on a
# second time, and #102/#103 must still settle exactly once.
d_reset
: > "$D/rows.tsv"
d_run                                             # builds the train
jq -nc '{state:"MERGED",mergeCommit:{oid:"batchsha0001"}}' > "$D/train-state.json"
: > "$D/gh-calls.txt"; : > "$D/ledger.tsv"
printf 'batch_member\t%s#101@%s\tlanded\t\n' "$SLUG" "$HEAD_A" > "$D/rows.tsv"
rm -f "$DH/state/batch-resolve/$PROJ/landed.txt"
d_run
[ "$(ghcount 'issues/101/comments')" = 0 ] && ok \
  || bad "D5: a member with a landed ROW must not be commented on again (got $(ghcount 'issues/101/comments'))"
[ "$(ghcount 'issues/102/comments')" = 1 ] && [ "$(ghcount 'issues/103/comments')" = 1 ] && ok \
  || bad "D5: the unsettled members must each settle once (102=$(ghcount 'issues/102/comments') 103=$(ghcount 'issues/103/comments'))"

# D6. A `red` row does NOT satisfy the settle's `landed` guard: the member is
# still owed its close-out comment.
d_reset
: > "$D/rows.tsv"
d_run
jq -nc '{state:"MERGED",mergeCommit:{oid:"batchsha0002"}}' > "$D/train-state.json"
: > "$D/gh-calls.txt"; : > "$D/ledger.tsv"
printf 'batch_member\t%s#101@%s\tred\t\n' "$SLUG" "$HEAD_A" > "$D/rows.tsv"
rm -f "$DH/state/batch-resolve/$PROJ/landed.txt"
d_run
[ "$(ghcount 'issues/101/comments')" = 1 ] && ok \
  || bad "D6: a red row must not satisfy the landed settle guard (got $(ghcount 'issues/101/comments'))"

# D7. The write-through half: a settled member writes its file line AND a
# `batch_member … landed` row.
grep -q "batch_member.*#102@$HEAD_B" "$D/ledger.tsv" 2>/dev/null \
  && ok || bad "D7: a settled member must write its batch_member row: $(cat "$D/ledger.tsv")"
grep -qxF "102 $HEAD_B" "$DH/state/batch-resolve/$PROJ/landed.txt" 2>/dev/null && ok \
  || bad "D7: the file half must still be written: $(cat "$DH/state/batch-resolve/$PROJ/landed.txt" 2>/dev/null)"
fi

echo "== E. bin/run-build.sh: the overlap-defer artifact, read back before a plan =="

E="$T/E"
mkdir -p "$E/h/state" "$E/h/flags"
# shellcheck source=tests/lib/rb-all.sh
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$E/run-build.all.sh")
[ -s "$RB_ALL" ] && ok || bad "E: the flattened pipeline text is empty"
{ echo 'set -uo pipefail'
  echo 'RESULT() { printf "%s\n" "$*" > "$E_RES"; }'
  echo '[ -r "$LT_LIB" ] && . "$LT_LIB"'
  echo 'job_artifact_feed() { printf "FEED %s %s\n" "$1" "$2" >> "$FEED_LOG"; [ "${FEED_RC:-0}" = 0 ] || return "$FEED_RC"; cat "${FEED_TSV:-/dev/null}"; }'
  sed -n '/^# >>> overlap not-before/,/^# <<< overlap not-before/p' "$RB_ALL"
  echo 'echo PLANNED > "$E_PLAN"'
} > "$E/gate.sh"
grep -q 'OVERLAP_SCHED' "$E/gate.sh" && ok || bad "E: the extracted region is not the not-before gate"
bash -n "$E/gate.sh" 2>/dev/null && ok || bad "E: the extracted not-before gate does not parse"

e_feed() { # e_feed <ref> <ticket> <age-seconds> <detail-json>
  local ts; ts=$(date -u -d "@$(( $(date -u +%s) - $3 ))" '+%Y-%m-%dT%H:%M:%SZ')
  printf 'job1\t%s\tbox1\t%s\t%s\t%s\n' "$1" "$2" "$ts" "$4" > "$E/feed.tsv"
}
e_run() {
  rm -f "$E/res.txt" "$E/plan.txt"; : > "$E/feed.log"
  env HARNESS="$E/h" PROJECT=demo-os KEY=BH-1036 LT_LIB="$LT_LIB" \
      E_RES="$E/res.txt" E_PLAN="$E/plan.txt" FEED_LOG="$E/feed.log" FEED_TSV="$E/feed.tsv" \
      "$@" bash "$E/gate.sh" >/dev/null 2>&1
}

# E1. A `deferred` artifact 5 minutes old with a 600s window: the ticket is
# inside its window, so the plan is NOT bought.
touch "$E/h/flags/no-twin-ledgers"
e_feed deferred BH-1036 300 '{"scope":"fleet","conflict":"src/a.ts","not_before_s":600}'
e_run; RC=$?
[ "$RC" -eq 3 ] && ok || bad "E1: a live artifact deferral must exit 3, got $RC"
grep -q 'BUILD_DEFERRED plan overlap not-before' "$E/res.txt" 2>/dev/null && ok \
  || bad "E1: the RESULT must be the documented not-before terminal: $(cat "$E/res.txt" 2>/dev/null)"
[ ! -f "$E/plan.txt" ] && ok || bad "E1: no plan may be bought inside the window"

# E2. The same artifact 20 minutes old: the window expired, the build proceeds.
e_feed deferred BH-1036 1200 '{"scope":"fleet","conflict":"src/a.ts","not_before_s":600}'
e_run; RC=$?
[ "$RC" -eq 0 ] && [ -f "$E/plan.txt" ] && ok || bad "E2: an expired window must build (rc $RC)"

# E3. A `proceeded` artifact carries no not_before_s and must never defer.
e_feed proceeded BH-1036 60 '{"scope":"fleet","verdict":"proceeded"}'
e_run; RC=$?
[ "$RC" -eq 0 ] && [ -f "$E/plan.txt" ] && ok || bad "E3: a proceeded artifact must not defer (rc $RC)"

# E4. A NEIGHBOURING ticket key must not hold this one (BH-10360 vs BH-1036).
e_feed deferred BH-10360 300 '{"scope":"fleet","conflict":"src/a.ts","not_before_s":600}'
e_run; RC=$?
[ "$RC" -eq 0 ] && [ -f "$E/plan.txt" ] && ok || bad "E4: another ticket's deferral must not hold BH-1036 (rc $RC)"

# E5. A feed outage falls through to today's path — never to a deferral.
e_feed deferred BH-1036 300 '{"scope":"fleet","conflict":"src/a.ts","not_before_s":600}'
e_run FEED_RC=1; RC=$?
[ "$RC" -eq 0 ] && [ -f "$E/plan.txt" ] && ok || bad "E5: a feed outage must build (rc $RC)"

# E6. Flag OFF: the feed is not even asked.
rm -f "$E/h/flags/no-twin-ledgers"
e_feed deferred BH-1036 300 '{"scope":"fleet","conflict":"src/a.ts","not_before_s":600}'
e_run; RC=$?
[ "$RC" -eq 0 ] && [ -f "$E/plan.txt" ] && ok || bad "E6: with the flag off the artifact must be ignored (rc $RC)"
[ ! -s "$E/feed.log" ] && ok || bad "E6: with the flag off no feed read may happen: $(cat "$E/feed.log")"

# E7. The file marker still wins when it is there (the write-through cache), and
# is still consumed when it expires.
touch "$E/h/flags/no-twin-ledgers"
mkdir -p "$E/h/state/overlap-defer/demo-os"
rm -f "$E/feed.tsv"
echo "$(( $(date -u +%s) + 300 ))" > "$E/h/state/overlap-defer/demo-os/BH-1036"
e_run; RC=$?
[ "$RC" -eq 3 ] && ok || bad "E7: the file marker must still defer (rc $RC)"
[ ! -s "$E/feed.log" ] && ok || bad "E7: the file answer must not also buy a feed read"
echo "$(( $(date -u +%s) - 10 ))" > "$E/h/state/overlap-defer/demo-os/BH-1036"
e_run; RC=$?
[ "$RC" -eq 0 ] && ok || bad "E7: an expired file marker must build (rc $RC)"
[ ! -e "$E/h/state/overlap-defer/demo-os/BH-1036" ] && ok || bad "E7: an expired marker must be consumed"

# E8. AN EXPIRED FILE MUST NOT SHADOW A LIVE FLEET DEFERRAL (r1 F1). This is the
# exact case the ticket names — the same ticket re-offered to a different pool
# box. Box 1 deferred BH-1036 once and its window has passed (the file is stale
# and gets consumed); the hub then handed BH-1036 to box 2, which deferred again
# 5 minutes ago with a 600s window and wrote the artifact. Box 1 gets it back:
# reading the stale FILE as the answer and never asking the feed buys a PLAN
# session inside box 2's window, which is the spend loop this whole gate exists
# to close. The feed has to be asked whenever the file did not answer — expired
# counts as "did not answer", not as "no".
e_feed deferred BH-1036 300 '{"scope":"fleet","conflict":"src/a.ts","not_before_s":600}'
echo "$(( $(date -u +%s) - 10 ))" > "$E/h/state/overlap-defer/demo-os/BH-1036"
e_run; RC=$?
[ "$RC" -eq 3 ] && ok || bad "E8: an expired file must not shadow a live fleet deferral (rc $RC)"
[ ! -f "$E/plan.txt" ] && ok || bad "E8: no plan may be bought inside another box's window"
[ -s "$E/feed.log" ] && ok || bad "E8: the feed must be asked once the file has expired"
[ ! -e "$E/h/state/overlap-defer/demo-os/BH-1036" ] && ok \
  || bad "E8: the expired file is still consumed on this path"

# E9. Flag OFF, expired file, live artifact: today's behaviour exactly — the
# file is consumed, no feed read happens, and the build proceeds. The E8 fix
# must not leak a request into the lane the flag is meant to leave alone.
rm -f "$E/h/flags/no-twin-ledgers"
echo "$(( $(date -u +%s) - 10 ))" > "$E/h/state/overlap-defer/demo-os/BH-1036"
e_run; RC=$?
[ "$RC" -eq 0 ] && [ -f "$E/plan.txt" ] && ok || bad "E9: with the flag off an expired file must build (rc $RC)"
[ ! -s "$E/feed.log" ] && ok || bad "E9: with the flag off no feed read may happen: $(cat "$E/feed.log")"
touch "$E/h/flags/no-twin-ledgers"

echo "== F. bin/postmerge-qa.sh: the ledger the header promises =="

F="$T/F"
mkdir -p "$F"
f_harness() {
  local X; X=$(mktemp -d "$F/h-XXXXXX")
  mkdir -p "$X/bin/lib" "$X/fakebin" "$X/env" "$X/logs" "$X/locks" "$X/state" "$X/flags" \
           "$X/builds" "$X/clerk" "$X/repo"
  local f
  for f in postmerge-qa.sh qa-unbanned.sh qa-clerk-ban.sh qa-account.sh fleet-conf.sh \
           prod-url.sh findings-log.sh alert_family.py; do
    cp "$DIR/bin/$f" "$X/bin/$f"; chmod +x "$X/bin/$f"
  done
  copy_jobs_client "$X/bin"; chmod +x "$X/bin/jobs-client.sh"
  cp "$DIR/bin/lib/env-path.sh" "$X/bin/lib/"
  cp "$DIR/bin/lib/endpoints.sh" "$X/bin/lib/"   # BH-1941: the Clerk base URL resolver
  cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$X/bin/lib/"
  cp "$LT_LIB" "$X/bin/lib/" 2>/dev/null || true
  printf 'project-3 example-org/project-3 https://os.project-3.test /api/board 6 box-project-3-2\n' > "$X/fleet.conf"
  printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.test\n' > "$X/env/global.env"
  printf 'QA_CLERK_SECRET_KEY=sk_test_fake\nQA_TEST_USER_ID=user_QA\n' > "$X/env/project-3.env"
  # BH-1510.1: the QA agent's model is a model_routes row (postmerge.qa); this box
  # carries the resolver beside the lane and its cache of #1507's table.
  mrs_fixture "$X" project-3
  echo active > "$X/clerk/user_QA"
  printf '#!/bin/bash\necho "$*" >> "%s/beats.txt"\nexit 0\n' "$X" > "$X/bin/beat.sh"
  chmod +x "$X/bin/beat.sh"
  printf '#!/bin/bash\necho "$*" >> "%s/agent-calls.txt"\nexit 0\n' "$X" > "$X/bin/agent-call.sh"
  chmod +x "$X/bin/agent-call.sh"
  cat > "$X/fakebin/gh" <<'GH'
#!/bin/bash
echo "$*" >> "$GH_SINK"
case "$*" in
  *"pr view"*state,mergeCommit*) printf '%s\t%s\n' MERGED deadbeefcafe1234 ;;
  *"deployments/"*"/statuses"*)  echo success ;;
  *deployments*)                 echo 99 ;;
esac
exit 0
GH
  chmod +x "$X/fakebin/gh"
  # ONE curl for two jobs: Clerk (so the real qa-clerk-ban.sh runs) and the
  # harness-jobs API (so the real ledger verbs run).
  cat > "$X/fakebin/curl" <<'CURLF'
#!/bin/bash
case " $* " in
  *" $JOBS_URL"*|*"jobs.test"*) exec "$JOBS_CURL" "$@" ;;
esac
URL="${!#}"
case "$URL" in
  *"/v1/users/"*)
    U="${URL##*/v1/users/}"; U="${U%%/*}"
    SF="$CLERK_STATE_DIR/$U"; [ -f "$SF" ] || echo active > "$SF"
    case "$URL" in
      */ban)   echo banned > "$SF"; printf '200'; exit 0 ;;
      */unban) echo active > "$SF"; printf '200'; exit 0 ;;
    esac
    printf '{"id":"%s","banned":false}' "$U" ;;
  *) printf '' ;;
esac
exit 0
CURLF
  chmod +x "$X/fakebin/curl"
  write_curl "$X/fakebin/jobs-curl"
  cat > "$X/fakebin/node" <<'NODE'
#!/bin/bash
echo "$*" >> "$NODE_SINK"
OUT=""
for A in "$@"; do case "$A" in */qa-prod-shots) OUT="$A" ;; esac; done
[ -n "$OUT" ] && { mkdir -p "$OUT"; : > "$OUT/root-1280.png"; }
echo "LANDED:https://os.project-3.test/dashboard"
echo "QA COVERAGE: screens=1 flows=0 shots=1"
echo "QA: PASS"
exit 0
NODE
  chmod +x "$X/fakebin/node"
  printf '%s' "$X"
}
f_build() { # f_build <harness> <name>
  local d="$1/builds/$2"; mkdir -p "$d"
  echo "PR_CREATED https://github.com/example-org/project-3/pull/7" > "$d/RESULT"
  printf '# plan\n\n## QA screens\n\n/clients\n' > "$d/plan.md"
  printf '%s' "$d"
}
f_run() { # f_run <harness> [env...]
  local X="$1"; shift
  env -i PATH="$X/fakebin:/usr/bin:/bin" HOME="$X" HARNESS="$X" FLEET_CONF="$X/fleet.conf" \
      QA_ACCOUNTS="$X/state/qa-accounts.json" CLERK_STATE_DIR="$X/clerk" \
      GH_SINK="$X/gh.txt" NODE_SINK="$X/node.txt" QA_REPO_DIR="$X/repo" \
      JOBS_CURL="$X/fakebin/jobs-curl" JOBS_BOX=testbox JOBS_RETRIES=0 \
      REQ_LOG="$X/req.log" LEDGER_ROWS="$X/rows.tsv" ENDPOINT_CLERK="$ENDPOINT_CLERK" "$@" \
      "$X/bin/postmerge-qa.sh" project-3 >/dev/null 2>&1
}
f_drives() { [ -f "$1/node.txt" ] || { echo 0; return 0; }; grep -c 'qa-drive' "$1/node.txt" 2>/dev/null || true; }

# F1. Empty state, a `PASS` row for this build dir: nothing is driven.
X=$(f_harness); f_build "$X" project-3-TK-1-202609190000 >/dev/null
touch "$X/flags/no-twin-ledgers"
printf 'postmerge_qa\tproject-3-TK-1-202609190000\tPASS\tdeadbeef\n' > "$X/rows.tsv"
f_run "$X"
[ "$(f_drives "$X")" = 0 ] && ok || bad "F1: a build with a PASS row must not be re-driven"
[ ! -s "$X/agent-calls.txt" ] && ok || bad "F1: no QA agent lane may run for a build already done"

# F2. No row and no file: the build is driven, the file line lands, and the row
# follows it with the verdict as its status.
X=$(f_harness); f_build "$X" project-3-TK-2-202609190000 >/dev/null
touch "$X/flags/no-twin-ledgers"
: > "$X/rows.tsv"
f_run "$X"
[ "$(f_drives "$X")" = 1 ] && ok || bad "F2: an unrecorded build must be driven once (got $(f_drives "$X"))"
grep -q ' PASS$' "$X/state/postmerge-qa-done.txt" 2>/dev/null && ok \
  || bad "F2: the file half must still be written: $(cat "$X/state/postmerge-qa-done.txt" 2>/dev/null)"
grep 'PUT https://jobs.test/api/ledger' "$X/req.log" 2>/dev/null | cut -d' ' -f3- \
  | jq -se 'map(select(.kind == "postmerge_qa" and .status == "PASS")) | length == 1' \
  >/dev/null 2>&1 && ok || bad "F2: no postmerge_qa row was written: $(grep -c PUT "$X/req.log" 2>/dev/null)"

# F3. Flag OFF with the row present: today's behaviour, the build is driven.
X=$(f_harness); f_build "$X" project-3-TK-3-202609190000 >/dev/null
printf 'postmerge_qa\tproject-3-TK-3-202609190000\tPASS\tdeadbeef\n' > "$X/rows.tsv"
f_run "$X"
[ "$(f_drives "$X")" = 1 ] && ok || bad "F3: with the flag off the row must change nothing"

# F4. An OUTAGE is never "already done": the build is driven from the file half.
X=$(f_harness); f_build "$X" project-3-TK-4-202609190000 >/dev/null
touch "$X/flags/no-twin-ledgers"
printf 'postmerge_qa\tproject-3-TK-4-202609190000\tPASS\tdeadbeef\n' > "$X/rows.tsv"
f_run "$X" CURL_MODE=down
[ "$(f_drives "$X")" = 1 ] && ok || bad "F4: a ledger outage must never read as done"

echo "== G. bin/run-build.sh: the plan-malformed hold answers from the row first =="

G="$T/G"
mkdir -p "$G/h/state" "$G/h/logs" "$G/h/flags" "$G/b"
write_ledger_stub "$G/ledger-stub.sh"
{ echo 'set -uo pipefail'
  echo 'STAMP() { echo TS; }'
  echo 'RESULT() { printf "%s\n" "$*" > "$G_RES"; }'
  echo 'BB() { :; }'
  echo '[ -r "$LT_LIB" ] && . "$LT_LIB"'
  cat "$G/ledger-stub.sh"
  sed -n '/^# >>> plan malformed hold/,/^# <<< plan malformed hold/p' "$RB_ALL"
  echo 'echo PLANNED > "$G_PLAN"'
} > "$G/hold.sh"
grep -q 'PM_HOLD_STATUS' "$G/hold.sh" && ok || bad "G: the extracted region is not the plan-malformed hold"
bash -n "$G/hold.sh" 2>/dev/null && ok || bad "G: the extracted hold region does not parse"

g_run() {
  rm -f "$G/res.txt" "$G/plan.txt"; : > "$G/h/logs/ALERTS.log"; : > "$G/b/pipeline.log"
  env HARNESS="$G/h" BUILD="$G/b" PROJECT=demo-os KEY=BH-1036 LT_LIB="$LT_LIB" \
      ALERTS="$G/h/logs/ALERTS.log" G_RES="$G/res.txt" G_PLAN="$G/plan.txt" \
      LEDGER_ROWS="$G/rows.tsv" LEDGER_SINK="$G/ledger.tsv" "$@" \
      bash "$G/hold.sh" >/dev/null 2>&1
}

# G1. Empty state file, a `skipped` row: the ticket is held with no plan bought.
touch "$G/h/flags/no-twin-ledgers"
rm -f "$G/h/state/plan-malformed.txt"
printf 'plan_malformed\tdemo-os BH-1036\tskipped\t\n' > "$G/rows.tsv"
g_run; RC=$?
[ "$RC" -eq 4 ] && ok || bad "G1: a held ticket must exit 4, got $RC"
grep -q 'PLAN_MALFORMED held for a human' "$G/res.txt" 2>/dev/null && ok \
  || bad "G1: the RESULT must stay the documented terminal: $(cat "$G/res.txt" 2>/dev/null)"
[ ! -f "$G/plan.txt" ] && ok || bad "G1: no plan session may be bought"

# G2. The ROW is the record: a stale file `released` does not overrule a `skipped`
# row while the flag is on.
printf 'demo-os BH-1036 released TS\n' > "$G/h/state/plan-malformed.txt"
g_run; RC=$?
[ "$RC" -eq 4 ] && ok || bad "G2: the row must win over a stale file row, got rc $RC"

# G3. Flag OFF: today's file-first order, so the file `released` launches.
rm -f "$G/h/flags/no-twin-ledgers"
g_run; RC=$?
[ "$RC" -eq 0 ] && [ -f "$G/plan.txt" ] && ok || bad "G3: with the flag off the file must win (rc $RC)"
touch "$G/h/flags/no-twin-ledgers"

# G4. An outage falls back to the file, which says `skipped` — still held.
printf 'demo-os BH-1036 skipped TS art.txt\n' > "$G/h/state/plan-malformed.txt"
g_run LEDGER_DOWN=1; RC=$?
[ "$RC" -eq 4 ] && ok || bad "G4: an outage must fall back to the file, got rc $RC"

# G5. A NEIGHBOUR ticket's row must not hold this ticket.
rm -f "$G/h/state/plan-malformed.txt"
printf 'plan_malformed\tdemo-os BH-10360\tskipped\t\n' > "$G/rows.tsv"
g_run; RC=$?
[ "$RC" -eq 0 ] && [ -f "$G/plan.txt" ] && ok || bad "G5: a neighbour key must not hold BH-1036 (rc $RC)"

# G6. No row anywhere and no file: the ticket launches. Absent is never held.
: > "$G/rows.tsv"
g_run; RC=$?
[ "$RC" -eq 0 ] && [ -f "$G/plan.txt" ] && ok || bad "G6: absent must never read as held (rc $RC)"

echo "== H. bin/lib/rb/: the dark stage modules carry the same two regions =="

# WHY THIS ONE IS A TEXT COMPARISON and every other assertion in this file is a
# drive. bin/lib/rb/gates.sh and bin/lib/rb/plan.sh are BH-478's slices of the
# driver and they are DARK: nothing calls an `rb_*` stage yet (the driver still
# runs its own inline copy, which is what sections E and G above drive), so
# there is no behaviour here to exercise. What the files themselves promise is
# textual — "Each body is the VERBATIM text of its slice of bin/run-build.sh" —
# and that promise is exactly what this PR can break: edit the driver's two
# regions, leave the module copies on the old text, and the day BH-478 flips
# those stages to module calls the overlap read-back and the row-first
# PM_HOLD_STATUS vanish from the pipeline with no suite going red. So the two
# regions are lifted by their own markers from both sides and compared byte for
# byte — no regex, no grep for a symbol.
#
# The pipeline side is read through $RB_ALL (the BH-568 seam, already flattened
# by section E), never the raw driver — which is also what keeps this honest
# after the flip: once a stage IS a module call, the flatten inlines the module
# body and there is no second copy left to drift from. The window this guards is
# the one before that, where both copies exist and only one is edited.
HH="$T/H"
mkdir -p "$HH"
sed -n '/^# >>> overlap not-before$/,/^# <<< overlap not-before$/p' "$RB_ALL"                  > "$HH/drv-overlap.txt"
sed -n '/^# >>> overlap not-before$/,/^# <<< overlap not-before$/p' "$DIR/bin/lib/rb/gates.sh" > "$HH/mod-overlap.txt"
[ -s "$HH/drv-overlap.txt" ] && ok || bad "H: the pipeline text has no overlap not-before region to compare"
[ -s "$HH/mod-overlap.txt" ] && ok || bad "H: bin/lib/rb/gates.sh has no overlap not-before region"
cmp -s "$HH/drv-overlap.txt" "$HH/mod-overlap.txt" && ok \
  || bad "H: bin/lib/rb/gates.sh's overlap not-before copy has drifted from the pipeline: $(diff "$HH/drv-overlap.txt" "$HH/mod-overlap.txt" | head -4 | tr '\n' ' ')"
sed -n '/^PM_HOLD_STATUS() {/,/^}$/p' "$RB_ALL"                 > "$HH/drv-pm.txt"
sed -n '/^PM_HOLD_STATUS() {/,/^}$/p' "$DIR/bin/lib/rb/plan.sh" > "$HH/mod-pm.txt"
[ -s "$HH/drv-pm.txt" ] && ok || bad "H: the pipeline text has no PM_HOLD_STATUS to compare"
[ -s "$HH/mod-pm.txt" ] && ok || bad "H: bin/lib/rb/plan.sh has no PM_HOLD_STATUS"
cmp -s "$HH/drv-pm.txt" "$HH/mod-pm.txt" && ok \
  || bad "H: bin/lib/rb/plan.sh's PM_HOLD_STATUS copy has drifted from the pipeline: $(diff "$HH/drv-pm.txt" "$HH/mod-pm.txt" | head -4 | tr '\n' ' ')"
# And both copies still parse on their own — a slice that only matches is no
# use if the file it lives in cannot be sourced.
bash -n "$DIR/bin/lib/rb/gates.sh" 2>/dev/null && ok || bad "H: bin/lib/rb/gates.sh does not parse"
bash -n "$DIR/bin/lib/rb/plan.sh"  2>/dev/null && ok || bad "H: bin/lib/rb/plan.sh does not parse"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
