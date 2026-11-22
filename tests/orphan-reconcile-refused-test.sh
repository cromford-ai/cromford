#!/bin/bash
# tests/orphan-reconcile-refused-test.sh — bin/orphan-reconcile.sh never
# launches a ticket bin/run-build.sh is going to refuse.
#
# WHY THIS EXISTS (2026-09-26/27). The reconciler re-launched the same nine
# project-5 tickets on EVERY tick (TK-1174, 1795, 1805, 2040, 2091, 2325, 2326,
# 2492, 2510). run-build refused each one — SKIP_ABANDONED (the fleet ledger's
# `abandoned` row) or HELD `hold:title` — so nothing was built, but every
# refusal left a new builds/<p>-<KEY>-*/RESULT behind, and that RESULT list is
# an input of bin/triage-gate.sh's queue fingerprint. A fingerprint that moves
# every tick defeats the queue-unchanged brake, and the tick bought a paid Opus
# triage session instead: about $830 in ~26h.
#
# Three gaps, each driven here against the real script:
#   1. ABANDONED / SUPERSEDED. run-build reads `ledger abandoned "<p> <KEY>"` and
#      the queue row's ABANDONED reason; the reconciler read neither.
#   2. THE HOLD READING. The reconciler judged holds with its own copy of the
#      regexes and no bot filter, so run-build's own BUILD_DEFERRED close-out
#      ("…; RESUME on the ticket lifts it", posted by the App) read as a LIFT of
#      a title HOLD. bin/lib/hold.sh's hold_classify skips bot comments.
#   3. THE RESHAPE DROPPED LABELS, so a `hold` label (BH-2504) was invisible.
# And the property that cost the money: the queue fingerprint, computed by the
# real QFP line lifted out of bin/triage-gate.sh, is identical across two ticks
# that see the same refused tickets.
#
# gh and curl are PATH shims (no network, no secrets). run-build.sh is a shim
# that records its argv AND leaves what the real one leaves on a refusal: a
# fresh build dir with a BUILD_REFUSED RESULT (already swept, COMMENTED).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" \
         "$H/prompts" "$H/builds" "$H/fixture" "$T/fakebin"
export HARNESS="$H"
P=project-5
cp "$DIR/bin/orphan-reconcile.sh" "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/preplan-lib.sh" "$DIR/bin/lib/gh-budget.sh" "$DIR/bin/lib/hold.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-list.sh" "$H/bin/lib/"
ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
export FLEET_CONF="$DIR/fleet.conf"
echo 'setsid /root/harness/bin/run-build.sh project-5 <issue-number> TK-<issue-number> > x' > "$H/prompts/$P.md"
printf 'HARNESS_SECRET=s3cret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
printf '#!/bin/bash\n:\n' > "$H/bin/lane-alert.sh"; chmod +x "$H/bin/lane-alert.sh"

# The real run-build refuses these, and a refusal is a build dir with a RESULT.
cat > "$H/bin/run-build.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/launches.log"
d="$HARNESS/builds/$1-$3-$(date +%s%N)"
mkdir -p "$d" && echo "BUILD_REFUSED refused by the fixture" > "$d/RESULT" && : > "$d/COMMENTED"
SH
chmod +x "$H/bin/run-build.sh"

# gh shim: a REST endpoint (status line, blank line, body), like the
# orphan-reconcile suite's. Fixtures are authored in wire shape.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
ARGS="$*"
PAGE=$(printf '%s' "$ARGS" | sed -nE 's/.*page=([0-9]+).*/\1/p'); PAGE="${PAGE:-1}"
[ "$PAGE" = 1 ] || SEND 200 '[]'
case "$ARGS" in
  *"api rate_limit"*) exit 1 ;;
  *"/issues/"*"/comments"*)
    n=$(printf '%s' "$ARGS" | sed -nE 's#.*/issues/([0-9]+)/comments.*#\1#p')
    SEND 200 "$(jq -c --argjson n "$n" '[ .[] | select(.number==$n) | (.thread // [])[] ]' "$HARNESS/fixture/open.json")" ;;
  *"/pulls"*) SEND 200 '[]' ;;
  *"/issues"*"state=all"*)
    SEND 200 "$(jq -c '[ .[] | {number, state:"open", closed_at:null} ]' "$HARNESS/fixture/open.json")" ;;
  *"/issues"*)
    SEND 200 "$(jq -c '[ .[] | del(.thread) ]' "$HARNESS/fixture/open.json")" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"

# curl shim for the jobs worker: jobs, queue rows, and the `abandoned` ledger
# row per key (fixture/ledger-<KEY>: its status; absent = HTTP 404, a real miss).
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/jobs*)  printf '{"jobs":[]}\n200\n' ;;
  */api/queue*)
    # Filtered the way the route filters (status, key), so queue_row reads
    # THIS key's row and not whichever row the fixture lists first.
    qp() { printf '%s' "$URL" | sed -nE "s/.*[?&]$1=([^&]*).*/\\1/p"; }
    printf '%s\n200\n' "$(jq -c --arg s "$(qp status)" --arg k "$(qp key)" \
      '.queue |= map(select(($s == "" or .status == $s) and ($k == "" or .ticket_key == $k)))' \
      "$HARNESS/fixture/queuerows.json")" ;;
  */api/ledger*kind=abandoned*)
    k=$(printf '%s' "$URL" | sed -nE 's/.*key=[a-z]+%20([A-Z]+-[0-9]+).*/\1/p')
    if [ -f "$HARNESS/fixture/ledger-$k" ]; then
      printf '{"ledger":{"kind":"abandoned","status":"%s","updated_at":"%s"}}\n200\n' "$(cat "$HARNESS/fixture/ledger-$k")" \
        "$(cat "$HARNESS/fixture/ledger-$k.at" 2>/dev/null)"
    else printf '{"error":"not found"}\n404\n'; fi ;;
  *)            printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

OLD=$(date -u -d "@$(( $(date +%s) - 7200 ))" '+%Y-%m-%dT%H:%M:%SZ')
# The bot close-out run-build posts on a held ticket (bin/lib/rb/gates.sh).
BOTC='{"body":"BUILD_DEFERRED held at queue — the ticket says hold:title; RESUME on the ticket lifts it","created_at":"2026-09-26T10:00:00Z","user":{"login":"harness[bot]","type":"Bot"}}'
cat > "$H/fixture/open.json" <<JSON
[
 {"number":1174,"title":"TK-1174 abandoned by the resolver","body":"## Scope","comments":0,"updated_at":"$OLD","labels":[{"name":"ai-build"}]},
 {"number":1795,"title":"TK-1795 row failed ABANDONED","body":"## Scope","comments":0,"updated_at":"$OLD","labels":[{"name":"ai-build"}]},
 {"number":1805,"title":"Compliance P9 (HOLD): residency","body":"## Scope","comments":1,"updated_at":"$OLD","labels":[{"name":"ai-build"}],"thread":[$BOTC]},
 {"number":2040,"title":"TK-2040 hold label","body":"## Scope","comments":0,"updated_at":"$OLD","labels":[{"name":"ai-build"},{"name":"hold"}]},
 {"number":2091,"title":"TK-2091 landed, resolver says superseded","body":"## Scope","comments":0,"updated_at":"$OLD","labels":[{"name":"ai-build"}]},
 {"number":2325,"title":"TK-2325 released abandon — buildable","body":"## Scope","comments":0,"updated_at":"$OLD","labels":[{"name":"ai-build"}]},
 {"number":2326,"title":"TK-2326 plain orphan","body":"## Scope","comments":0,"updated_at":"$OLD","labels":[{"name":"ai-build"}]}
]
JSON
echo abandoned > "$H/fixture/ledger-TK-1174"
echo released  > "$H/fixture/ledger-TK-2325"
cat > "$H/fixture/queuerows.json" <<JSON
{"queue":[
 {"project":"project-5","ticket_key":"TK-1795","ticket_id":"1795","status":"failed","target":"fly","attempt":2,"claimed_by":null,"enqueued_at":"$OLD","reason":"ABANDONED by the blocked-resolver: rebuilt fresh 3 times"},
 {"project":"project-5","ticket_key":"TK-2091","ticket_id":"2091","status":"done","target":"fly","attempt":1,"claimed_by":null,"enqueued_at":"$OLD","reason":"ticket TK-2091 already merged via https://github.com/example-org/project-5/pull/9, park is stale, nothing rebuilt"},
 {"project":"project-5","ticket_key":"TK-2325","ticket_id":"2325","status":"failed","target":"fly","attempt":2,"claimed_by":null,"enqueued_at":"$OLD","reason":"ABANDONED by the blocked-resolver: x"}
]}
JSON

# Grace 0: the enqueue marker must not be what keeps tick 2 quiet — the
# refusal reasons themselves must.
export ORPHAN_GRACE_MIN=0 ORPHAN_MAX_PER_RUN=20
run() { "$H/bin/orphan-reconcile.sh" "$P" --explain 2>/dev/null; }
launched() { sort -u "$H/launches.log" 2>/dev/null; }
was_launched() { grep -qx "project-5 $1 TK-$1" <<<"$(launched)"; }

# THE REAL FINGERPRINT: the QFP line of bin/triage-gate.sh, lifted verbatim and
# evaluated with the real rq_fp (bin/lib/ready-queue.sh; the rows slice is off
# here, so it contributes nothing — exactly the default on a box).
QFPLINE=$(grep -E '^[[:space:]]*QFP=\$\(' "$DIR/bin/triage-gate.sh" | head -1)
[ -n "$QFPLINE" ] && ok || bad "could not lift the QFP line out of bin/triage-gate.sh"
qfp() {
  ( HARNESS="$H" PROJECT="$P"
    # shellcheck source=/dev/null
    . "$DIR/bin/lib/ready-queue.sh" 2>/dev/null
    command -v rq_fp >/dev/null 2>&1 || rq_fp() { :; }
    eval "$QFPLINE"; printf '%s' "$QFP" )
}

# ---------- tick 1 -----------------------------------------------------------
OUT=$(run)
verdict() { awk -F'\t' -v k="$1" '$1==k {print $3"\t"$4}' <<<"$OUT"; }
FP1=$(qfp)

was_launched 1174 && bad "1: a ticket with an ABANDONED ledger row must not be launched (run-build answers SKIP_ABANDONED)" || ok
was_launched 1795 && bad "2: a queue row failed 'ABANDONED by the blocked-resolver' must not be launched" || ok
was_launched 2091 && bad "3: a ticket the resolver resolved as already merged (superseded) must not be launched" || ok
was_launched 1805 && bad "4: a title HOLD must stand over run-build's own bot close-out ('RESUME on the ticket lifts it'): $(verdict TK-1805)" || ok
grep -q '^TK-1805	1805	OWNED	hold:title' <<<"$OUT" && ok || bad "4: the verdict must be hold.sh's hold:title: $(verdict TK-1805)"
was_launched 2040 && bad "5: a ticket carrying the 'hold' label must not be launched — the reshape must keep labels: $(verdict TK-2040)" || ok
grep -q '^TK-2040	2040	OWNED	hold:label' <<<"$OUT" && ok || bad "5: the verdict must be hold.sh's hold:label: $(verdict TK-2040)"
was_launched 2325 && ok || bad "6: a RELEASED abandoned ledger row must let the ticket build, as run-build does: $(launched)"
was_launched 2326 && ok || bad "7: a plain orphan must still be launched: $(launched)"
grep -q 'TK-1174:abandoned' "$H/logs/$P.log" && ok || bad "1: the run summary must name TK-1174's skip: $(grep -o 'reconcile: open.*' "$H/logs/$P.log" | tail -1)"
grep -q 'TK-2091:superseded' "$H/logs/$P.log" && ok || bad "3: the run summary must name TK-2091's skip: $(grep -o 'reconcile: open.*' "$H/logs/$P.log" | tail -1)"

# ---------- tick 2: the same refused tickets, the fingerprint must not move --
# The two buildable ones were launched and are now owned by their queue rows,
# exactly as they would be on the hub; the refused ones are unchanged.
jq --arg t "$OLD" '.queue += [
  {project:"project-5",ticket_key:"TK-2325",ticket_id:"2325",status:"queued",target:"fly",attempt:0,claimed_by:null,enqueued_at:$t},
  {project:"project-5",ticket_key:"TK-2326",ticket_id:"2326",status:"queued",target:"fly",attempt:0,claimed_by:null,enqueued_at:$t}]
  | .queue |= (map(select(.ticket_key != "TK-2325" or .status == "queued")))' \
  "$H/fixture/queuerows.json" > "$H/fixture/q2" && mv "$H/fixture/q2" "$H/fixture/queuerows.json"
: > "$H/launches.log"
run >/dev/null
FP2=$(qfp)
[ -z "$(launched)" ] && ok || bad "tick 2 re-launched refused tickets: $(launched | tr '\n' ' ')"
[ -n "$FP1" ] && [ "$FP1" = "$FP2" ] && ok \
  || bad "the triage-gate queue fingerprint moved between two ticks with the same refused tickets ($FP1 -> $FP2): every move buys a paid triage session"

# ---------- 8. parity with run-build, not wider (review of #3061) -----------
# run-build refuses a queue row ONLY as `failed|ABANDONED by the blocked-resolver`
# (bin/lib/rb/gates.sh). The resolver's "the ticket says ABANDON" row carries no
# ledger row and tells the human to comment RESUME; after the RESUME hold.sh
# reads the ticket clear and run-build builds it, so the reconciler must launch
# it — skipping on the stale row reason would park it forever. An ABANDON that
# was NOT lifted is refused by hold.sh (the ticket), not by the row. An
# operator's pool abandon (fly-pool.sh, BH-2406) is not a run-build refusal
# either, so it launches as run-build would build it.
HAB='{"body":"ABANDON this one","created_at":"2026-09-26T09:00:00Z","user":{"login":"operator","type":"User"}}'
HRS='{"body":"RESUME","created_at":"2026-09-26T12:00:00Z","user":{"login":"operator","type":"User"}}'
cat > "$H/fixture/open.json" <<JSON
[
 {"number":3001,"title":"TK-3001 abandoned then resumed","body":"## Scope","comments":2,"updated_at":"$OLD","labels":[{"name":"ai-build"}],"thread":[$HAB,$HRS]},
 {"number":3002,"title":"TK-3002 abandoned, not resumed","body":"## Scope","comments":1,"updated_at":"$OLD","labels":[{"name":"ai-build"}],"thread":[$HAB]},
 {"number":3003,"title":"TK-3003 operator pool abandon","body":"## Scope","comments":0,"updated_at":"$OLD","labels":[{"name":"ai-build"}]}
]
JSON
cat > "$H/fixture/queuerows.json" <<JSON
{"queue":[
 {"project":"project-5","ticket_key":"TK-3001","ticket_id":"3001","status":"failed","target":"fly","attempt":1,"claimed_by":null,"enqueued_at":"$OLD","reason":"the ticket says ABANDON — the PR was closed by the blocked-resolver"},
 {"project":"project-5","ticket_key":"TK-3002","ticket_id":"3002","status":"failed","target":"fly","attempt":1,"claimed_by":null,"enqueued_at":"$OLD","reason":"the ticket says ABANDON — the PR was closed by the blocked-resolver"},
 {"project":"project-5","ticket_key":"TK-3003","ticket_id":"3003","status":"failed","target":"fly","attempt":1,"claimed_by":null,"enqueued_at":"$OLD","reason":"ABANDONED by an operator (job j9): the pool does not requeue it"}
]}
JSON
: > "$H/launches.log"
OUT=$(run)
was_launched 3001 && ok || bad "8: an ABANDON lifted by RESUME must be launched (run-build builds it; the stale 'the ticket says ABANDON' row must not park it): $(verdict TK-3001) launched=$(launched | tr '\n' ' ')"
was_launched 3002 && bad "8: an ABANDON not lifted must not be launched: $(verdict TK-3002)" || ok
grep -q '^TK-3002	3002	OWNED	abandon:comment' <<<"$OUT" && ok || bad "8: the unlifted ABANDON is hold.sh's verdict, not the row's: $(verdict TK-3002)"
was_launched 3003 && ok || bad "8: an operator pool abandon is not a run-build refusal, so it launches: $(verdict TK-3003)"

# ---------- 9. a person's RESUME lifts a LEDGER abandon (project-6 #3720) ----
# The resolver ABANDONED the ticket (ledger row), then a person wrote RESUME.
# run-build's gate releases the row on that RESUME, so the reconciler must
# launch the ticket and not skip it as <KEY>:abandoned for ever. A RESUME older
# than the row (the ladder ran again after it) lifts nothing.
cat > "$H/fixture/open.json" <<JSON
[
 {"number":3720,"title":"TK-3720 resolver abandon, then RESUME","body":"## Scope","comments":1,"updated_at":"$OLD","labels":[{"name":"ai-build"}],"thread":[$HRS]},
 {"number":3699,"title":"TK-3699 RESUME, then resolver abandon","body":"## Scope","comments":1,"updated_at":"$OLD","labels":[{"name":"ai-build"}],"thread":[$HRS]},
 {"number":3740,"title":"TK-3740 resolver abandon, no RESUME","body":"## Scope","comments":0,"updated_at":"$OLD","labels":[{"name":"ai-build"}]}
]
JSON
echo '{"queue":[]}' > "$H/fixture/queuerows.json"
for k in 3720 3699 3740; do echo abandoned > "$H/fixture/ledger-TK-$k"; done
echo 2026-09-26T08:00:00Z > "$H/fixture/ledger-TK-3720.at"   # before the 12:00 RESUME
echo 2026-09-26T18:00:00Z > "$H/fixture/ledger-TK-3699.at"   # after it
echo 2026-09-26T08:00:00Z > "$H/fixture/ledger-TK-3740.at"
: > "$H/launches.log"; : > "$H/logs/$P.log"
OUT=$(run)
was_launched 3720 && ok || bad "9: a RESUME newer than the ledger abandon must launch the ticket: $(verdict TK-3720) summary=$(grep -o 'reconcile: open.*' "$H/logs/$P.log" | tail -1)"
was_launched 3699 && bad "9: a RESUME older than the ledger abandon must not launch the ticket" || ok
was_launched 3740 && bad "9: a ledger abandon with no RESUME must not be launched" || ok
grep -q 'TK-3699:abandoned' "$H/logs/$P.log" && grep -q 'TK-3740:abandoned' "$H/logs/$P.log" && ok \
  || bad "9: the summary still names the two standing abandons: $(grep -o 'reconcile: open.*' "$H/logs/$P.log" | tail -1)"
grep -q 'TK-3720:abandoned' "$H/logs/$P.log" && bad "9: the resumed ticket must not be in the skipped list" || ok

echo "orphan-reconcile-refused: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
