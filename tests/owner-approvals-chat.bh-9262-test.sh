#!/bin/bash
# tests/owner-approvals-chat.bh-9262-test.sh — BH-9262 (C1): the two chat
# callers file an owner approval when the worker wants an owner proof.
# The hub holds no proof (no human token, no box-ops token). When the worker
# answers a proof-required 403, bin/archie.sh delegate and bin/box-request.sh
# file a pending row (POST /api/owner-approvals) that the owner runs from the
# console. Any other refusal keeps today's reply and files nothing.
#
# WHAT IS STUBBED. A scratch harness $H gets the closures of the SHIPPED
# bin/archie.sh and bin/box-request.sh and the real jobs-client transport.
# PATH carries a `curl` that models the jobs worker: per-route answers come
# from $T/ans.<key>.code + $T/ans.<key>.body files, everything else answers as
# tests/box-request.bh-5751-test.sh's worker does (quote, ledger). Every
# request lands in $T/reqlog as `<method> <path> <body>`; every header line
# the transport sends (-H and the -K config) lands in $T/headers.log.
#
# Sections: A archie delegate, B box-request quote/launch/fly, D the negative
# list (nothing filed), I the orchestrate.sh archie block, F the C1 files.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/owner-approvals-chat.bh-9262-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "owner-approvals-chat: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

# ═════ F: the files C1 ships (D41) ═══════════════════════════════════════════
for f in bin/archie.sh bin/box-request.sh bin/orchestrate.sh \
         worker/jobs/src/routes/owner-approvals.js \
         worker/jobs/src/routes/retention.d/bh-9262-owner-approvals.js \
         worker/jobs/schema.d/202611252112-bh-9262-owner-approvals.sql \
         console-ui/src/ui/OwnerApprovalsPanel.js \
         console-ui/functions/_lib/coord-writes.d/9262-owner-approvals.js; do
  check "F1 $f exists" '[ -f "$REPO/$f" ]'
done

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/bin" "$H/env" "$H/logs" "$H/locks" "$H/flags" "$H/prompts" "$H/catalog" "$T/fakebin"
for s in bin/box-request.sh bin/archie.sh bin/jobs-client.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: cannot install the closure of $s"; exit 1; }
done
cp "$REPO/prompts/box-placement.json" "$H/prompts/box-placement.json"
jq '.accounts["project-6-account"].defaults.disk_gb = 50' "$REPO/catalog/orgo-plans.json" > "$H/catalog/orgo-plans.json"
cat > "$T/fleet.conf" <<'EOF'
alpha example-org/alpha https://alpha.example.com /api/board 3 project-6-os
EOF
for s in alert-line.sh archie-tg-send.sh orc-context.sh; do
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FXT/%s.log"\n' "$s" > "$H/bin/$s"; chmod +x "$H/bin/$s"
done

# The jobs worker. A $T/ans.<route-key>.code file answers that route with its
# code and $T/ans.<route-key>.body; the key is the path's last two segments
# joined by '_' (one segment under /api/: owner-approvals), and
# box-commands_<type> for POST /api/box-commands (box-commands_orgo_launch).
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
m=GET; data=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift 2 ;;
    --data-binary|-d|--data) data="$2"; shift 2 ;;
    -H) printf '%s\n' "$2" >> "$FXT/headers.log"; shift 2 ;;
    -K) cat "$2" >> "$FXT/headers.log" 2>/dev/null; shift 2 ;;
    -m|-w|--connect-timeout|-o) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$data" in @*) data=$(cat "${data#@}") ;; esac
p="${url#http://jobs.invalid}"
printf '%s %s %s\n' "$m" "$p" "$data" >> "$FXT/reqlog"
db="$FXT/db.json"
ans() { printf '%s\n%s' "$2" "$1"; exit 0; }
route="${p%%\?*}"
qp() { printf '%s' "$p" | sed -n "s/.*[?&]$1=\([^&]*\).*/\1/p"; }
key=$(printf '%s' "$route" | awk -F/ '{print ($(NF-1) == "api" ? $NF : $(NF-1) "_" $NF)}')
[ "$route" = /api/box-commands ] && key="box-commands_$(jq -r .type <<<"$data")"
[ -f "$FXT/ans.$key.down" ] && exit 7
[ -f "$FXT/ans.$key.code" ] && ans "$(cat "$FXT/ans.$key.code")" "$(cat "$FXT/ans.$key.body")"
case "$m $route" in
  "POST /api/owner-approvals")
    n=$(jq '.next' "$db"); jq '.next += 1' "$db" > "$db.t" && mv "$db.t" "$db"
    ans 201 "$(jq -c --argjson i "$n" '{id: $i, approval: (. + {id: $i, status: "pending"}), deduped: false}' <<<"$data")" ;;
  "POST /api/box-commands")
    n=$(jq '.next' "$db"); st=requested; det=null
    if [ -f "$FXT/finish.$(jq -r .type <<<"$data")" ]; then st=ok; det=$(jq -Rc . < "$FXT/finish.$(jq -r .type <<<"$data")"); fi
    jq --argjson b "$data" --argjson i "$n" --arg s "$st" --argjson d "$det" '.next += 1 | .rows += [{id: $i, type: $b.type,
      target: $b.target, status: $s, detail: $d, requested_by: $b.actor}]' "$db" > "$db.t" && mv "$db.t" "$db"
    ans 201 "$(jq -c --argjson i "$n" '.rows[] | select(.id == $i) | {id, status, command: ., deduped: false}' "$db")" ;;
  "GET /api/box-commands")
    ans 200 "$(jq -c '{commands: (.rows | reverse), truncated: false}' "$db")" ;;
  "POST /api/archie/classes/delegation")
    ans 200 "$(jq -c '{ok: true, class_state: {class: .class, state: "delegated"}}' <<<"$data")" ;;
  "GET /api/ledger")
    k=$(qp key); k=$(printf '%b' "${k//%/\\x}")
    r=$(jq -c --arg k "$(qp kind)|$k" '.ledgers[$k] // empty' "$db")
    [ -n "$r" ] || ans 404 '{"error":"not found"}'
    ans 200 "$(jq -c '{ledger: .}' <<<"$r")" ;;
  "PUT /api/ledger")
    jq --argjson b "$data" '"\($b.kind)|\($b.key)" as $k
      | .ledgers[$k] = ((.ledgers[$k] // {kind: $b.kind, key: $b.key}) + {status: $b.status}
          + (if $b.detail then {detail: $b.detail} else {} end))' "$db" > "$db.t" && mv "$db.t" "$db"
    ans 200 '{"ok":true}' ;;
  "POST /api/ledger/claim")
    k=$(jq -r '"\(.kind)|\(.key)"' <<<"$data")
    [ -n "$(jq -r --arg k "$k" '.ledgers[$k].status // ""' "$db")" ] && ans 200 '{"claimed":false}'
    jq --argjson b "$data" '"\($b.kind)|\($b.key)" as $k | .ledgers[$k] = {kind: $b.kind, key: $b.key, status: $b.status}' \
      "$db" > "$db.t" && mv "$db.t" "$db"
    ans 200 '{"claimed":true}' ;;
  "GET /api/settings") ans 200 '{"settings":[]}' ;;
  *) ans 404 '{"error":"no route"}' ;;
esac
SH
chmod +x "$T/fakebin/curl"

NOW=1791190800
CONSOLE='https://console.example.com'
PROOF403='{"error":"owner_only","proof":"required"}'
QDETAIL='box-launch: box=acme orgo=- ip=- specs=4c/8gb/50gb usd_mo=42 smoke=PENDING'
reset() {
  rm -f "$T"/ans.* "$T"/finish.* "$T/reqlog" "$T/headers.log" "$T/out"
  echo '{"next":100,"rows":[],"ledgers":{}}' > "$T/db.json"
  printf '%s\n' 'BOX_CHAT_OWNERS="telegram:owner_a=owner@example.com"' "CONSOLE_URL=$CONSOLE" > "$H/env/global.env"
  printf '%s\n' "$QDETAIL" > "$T/finish.orgo_launch_quote"
}
# answer <route-key> <code> <body>: the worker's answer for that route.
answer() { printf '%s\n' "$2" > "$T/ans.$1.code"; printf '%s\n' "$3" > "$T/ans.$1.body"; }
# Nothing from this box's environment reaches the scripts (D60).
UNSET=(-u CONSOLE_URL -u BOX_CHAT_OWNERS -u ARCHIE_DELEGATE_AFTER -u ARCHIE_FIXTURE -u BOX_NAME)
COMMON=(HARNESS_TEST_SANDBOX=1 HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" JOBS_URL=http://jobs.invalid
        HARNESS_SECRET=fixture-secret-9262 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 FLEET_CONF="$T/fleet.conf")
br() {
  env "${UNSET[@]}" "${COMMON[@]}" BOXREQ_TRANSPORT=telegram BOXREQ_FROM_USER="${U:-owner_a}" BOXREQ_CHAT=-1001234 BOXREQ_THREAD=7 \
    BOXREQ_CMD_ID="${CID-c42}" BOXREQ_NOW="$NOW" BOXREQ_SPAWN_LOG="$T/spawn.log" BOX_REQUEST_QUOTE_WAIT_S=2 BOX_REQUEST_POLL_S=1 \
    bash "${BIN:-$H/bin/box-request.sh}" intercept "$1" > "$T/out" 2>/dev/null
  RCV=$?; OUT=$(cat "$T/out")
}
ai() {
  env "${UNSET[@]}" "${COMMON[@]}" ARCHIE_NOW="$NOW" ARCHIE_CMD_ID="${CID-c42}" ARCHIE_TRANSPORT=telegram ARCHIE_FROM_USER="${U:-operator_fixture}" \
    LANE_GATE_DISABLE=1 bash "${BIN:-$H/bin/archie.sh}" intercept "$1" > "$T/out" 2>/dev/null
  RCV=$?; OUT=$(cat "$T/out")
}
filed() { local l=""; [ -f "$T/reqlog" ] && l=$(cat "$T/reqlog"); grep -c '^POST /api/owner-approvals ' <<<"$l"; }
abody() { grep '^POST /api/owner-approvals ' "$T/reqlog" | sed -n "${1:-1}p" | cut -d' ' -f3-; }
# no proof header ever leaves the hub.
noproof() {
  local h=""; [ -f "$T/headers.log" ] && h=$(cat "$T/headers.log")
  check "$1: no proof header sent" '! grep -qi "x-box-ops\|x-human-verdict" <<<"$h"'
}
LINK="$CONSOLE/machines#owner-approvals"

# ═════ A: archie delegate ════════════════════════════════════════════════════
reset; answer classes_delegation 403 '{"error":"human_proof_required"}'
ai "Archie delegate Watch-Cadence"
eq "A1 rc 0" "$RCV" 0
eq "A1 one approval filed" "$(filed)" 1
B=$(abody)
eq "A1 kind" "$(jq -r .kind <<<"$B")" archie_delegation
eq "A1 payload" "$(jq -c .payload <<<"$B")" '{"class":"watch-cadence","min_streak":5}'
eq "A1 actor chat" "$(jq -r .actor <<<"$B")" chat
eq "A1 via the chat sender" "$(jq -r .via <<<"$B")" telegram:operator_fixture
eq "A1 dedupe key" "$(jq -r .dedupe_key <<<"$B")" archie-delegation:watch-cadence:c42
eq "A1 the reply" "$OUT" "Delegating watch-cadence needs your OK in the console, because chat cannot prove it is you. Approve it here: $LINK"
noproof A1
ai "Archie delegate Watch-Cadence"
eq "A2 a re-delivery posts the same dedupe key" "$(abody 2 | jq -r .dedupe_key)" archie-delegation:watch-cadence:c42
reset; answer classes_delegation 403 '{"error":"human_proof_required"}'; answer owner-approvals 503 '{"error":"down"}'
ai "Archie delegate watch-cadence"
check "A3 approval post fails: no 'needs your OK'" '! grep -q "needs your OK" <<<"$OUT"'
check "A3 the reply says nothing changed" 'grep -qF "I couldn'"'"'t file the delegation of watch-cadence for your approval" <<<"$OUT" && grep -qF "Nothing changed." <<<"$OUT"'
reset; answer classes_delegation 403 '{"error":"human_proof_required"}'; answer owner-approvals 200 '{"approval":{}}'
ai "Archie delegate watch-cadence"
check "A3 a 200 with no id: no 'needs your OK'" '! grep -q "needs your OK" <<<"$OUT"'
reset; printf '%s\n' 'BOX_CHAT_OWNERS="telegram:owner_a=owner@example.com"' > "$H/env/global.env"
answer classes_delegation 403 '{"error":"human_proof_required"}'
ai "Archie delegate watch-cadence"
check "A4 no CONSOLE_URL: names the panel, no invented URL" \
  'grep -qF "Approve it on the console Machines screen, Owner approvals panel" <<<"$OUT" && ! grep -q "https\?:" <<<"$OUT"'

# ═════ B: box-request ════════════════════════════════════════════════════════
# B1: the quote.
reset; answer box-commands_orgo_launch_quote 403 "$PROOF403"
br "/box launch acme"
eq "B1 rc 0" "$RCV" 0
eq "B1 one approval filed" "$(filed)" 1
B=$(abody)
eq "B1 kind" "$(jq -r .kind <<<"$B")" box_command
eq "B1 payload is the quote spec" "$(jq -c '.payload | [.box, .type, .target, .account, .project, .vcpus, .mem_gb, .disk_gb]' <<<"$B")" \
  '["hub","orgo_launch_quote","acme","project-6-account","acme",4,8,50]'
check "B1 payload has no actor or confirm" '[ "$(jq -c ".payload | has(\"actor\"), has(\"confirm\")" <<<"$B" | tr "\n" " ")" = "false false " ]'
eq "B1 actor is the owner" "$(jq -r .actor <<<"$B")" owner@example.com
eq "B1 via" "$(jq -r .via <<<"$B")" telegram:owner_a
eq "B1 dedupe key" "$(jq -r .dedupe_key <<<"$B")" box:orgo_launch_quote:acme:c42
check "B1 the reply links the console" 'grep -qF "needs your OK in the console, because chat cannot prove it is you. Nothing runs until you approve it there: $LINK" <<<"$OUT"'
check "B1 no offer written" '[ "$(jq ".ledgers | length" "$T/db.json")" = 0 ]'
noproof B1
reset; answer box-commands_orgo_launch_quote 403 "$PROOF403"; answer owner-approvals 503 '{"error":"down"}'
br "/box launch acme"
check "B1b approval post fails: no 'needs your OK', says nothing queued" '! grep -q "needs your OK" <<<"$OUT" && grep -qF "I queued nothing." <<<"$OUT"'
# B2: the launch (a priced offer, then the yes is refused for proof).
reset; br "/box launch acme"
check "B2 setup: the offer is priced" 'grep -qF "costs \$42/mo" <<<"$OUT"'
answer box-commands_orgo_launch 403 "$PROOF403"
br "yes"
eq "B2 one approval filed" "$(filed)" 1
B=$(abody)
eq "B2 the launch files the QUOTE spec (re-priced in the console)" \
  "$(jq -c '.payload | [.type, .target, .account, .project, .vcpus, .mem_gb, .disk_gb, has("quote_id"), has("confirm_monthly_usd")]' <<<"$B")" \
  '["orgo_launch_quote","acme","project-6-account","acme",4,8,50,false,false]'
eq "B2 the launch ledger is refused" "$(jq -r '[.ledgers[] | select(.kind == "box_launch")][0].status' "$T/db.json")" refused
check "B2 the reply" 'grep -qF "The launch of box acme (\$42/mo) needs your OK in the console" <<<"$OUT"'
noproof B2
# B3: fly onboard.
reset; br "/project load acme --builds-day 12"; answer box-commands_fly_onboard 403 "$PROOF403"; br "yes"
eq "B3 one approval filed" "$(filed)" 1
eq "B3 payload" "$(abody | jq -c '.payload')" '{"box":"hub","type":"fly_onboard","target":"acme","reason":"chat: yes to the project offer for acme"}'
eq "B3 the offer is refused" "$(jq -r '.ledgers["box_offer|telegram:-1001234:7"].status' "$T/db.json")" refused
check "B3 the reply" 'grep -qF "fly_onboard for acme needs your OK in the console" <<<"$OUT"'
noproof B3
# B4: fly pool cap.
reset; : > "$H/flags/fly-pool-acme"; br "/project load acme --builds-day 12 --cap 3"
answer box-commands_fly_pool_cap 403 "$PROOF403"; br "yes"; rm -f "$H/flags/fly-pool-acme"
eq "B4 fly_pool_cap payload with the cap" "$(abody | jq -c '.payload | [.type, .target, .cap]')" '["fly_pool_cap","acme",3]'
noproof B4

# ═════ D: the negative list: nothing is filed ════════════════════════════════
# (a) a 403 with no proof field: today's "not an owner" reply.
reset; answer box-commands_orgo_launch_quote 403 '{"error":"owner_only"}'; br "/box launch acme"
check "Da quote 403 no proof: not an owner, nothing filed" '[ "$(filed)" = 0 ] && grep -qF "not an owner (BOX_OPS_OWNERS)" <<<"$OUT"'
reset; br "/box launch acme"; answer box-commands_orgo_launch 403 '{"error":"owner_only"}'; br "yes"
check "Da launch 403 no proof: not an owner, nothing filed" '[ "$(filed)" = 0 ] && grep -qF "not an owner (BOX_OPS_OWNERS)" <<<"$OUT"'
reset; br "/project load acme --builds-day 12"; answer box-commands_fly_onboard 403 '{"error":"owner_only"}'; br "yes"
check "Da fly 403 no proof: not an owner, nothing filed" '[ "$(filed)" = 0 ] && grep -qF "not an owner (BOX_OPS_OWNERS)" <<<"$OUT"'
# (b) archie_cannot_delegate, (c) not_earned / never_delegable.
reset; answer classes_delegation 403 '{"error":"archie_cannot_delegate"}'; ai "Archie delegate watch-cadence"
check "Db archie_cannot_delegate: nothing filed" '[ "$(filed)" = 0 ] && ! grep -q "needs your OK" <<<"$OUT"'
reset; answer classes_delegation 409 '{"error":"not_earned","streak":2}'; ai "Archie delegate watch-cadence"
check "Dc not_earned: today's reply, nothing filed" '[ "$(filed)" = 0 ] && grep -qF "Not yet. watch-cadence is at 2 of 5" <<<"$OUT"'
reset; answer classes_delegation 409 '{"error":"never_delegable"}'; ai "Archie delegate merge"
check "Dc never_delegable: nothing filed" '[ "$(filed)" = 0 ] && grep -qF "merge stays with you" <<<"$OUT"'
# (d) ask first never files, even on a proof 403.
reset; answer classes_delegation 403 '{"error":"human_proof_required"}'; ai "Archie ask first watch-cadence"
check "Dd ask first: nothing filed" '[ "$(filed)" = 0 ] && ! grep -q "needs your OK" <<<"$OUT"'
# (e) a deduped 200 is success.
reset; answer box-commands_orgo_launch_quote 200 '{"id":7,"status":"requested","command":{"id":7},"deduped":true}'
br "/box launch acme"
eq "De a deduped 200: nothing filed" "$(filed)" 0
# (f) 400 and 503.
reset; answer box-commands_orgo_launch_quote 400 '{"error":"account is required"}'; br "/box launch acme"
eq "Df 400: nothing filed" "$(filed)" 0
reset; answer box-commands_orgo_launch_quote 503 '{"error":"unavailable"}'; br "/box launch acme"
eq "Df 503: nothing filed" "$(filed)" 0
reset; answer classes_delegation 503 '{"error":"unavailable"}'; ai "Archie delegate watch-cadence"
eq "Df archie 503: nothing filed" "$(filed)" 0
# (g) proof:"required" on a 400 body.
reset; answer box-commands_orgo_launch_quote 400 '{"error":"x","proof":"required"}'; br "/box launch acme"
eq "Dg proof on a 400: nothing filed" "$(filed)" 0
reset; answer classes_delegation 400 '{"error":"human_proof_required"}'; ai "Archie delegate watch-cadence"
eq "Dg archie human_proof_required on a 400: nothing filed" "$(filed)" 0
# (h) transport failure.
reset; : > "$T/ans.box-commands_orgo_launch_quote.down"; br "/box launch acme"
eq "Dh quote transport failure: nothing filed" "$(filed)" 0
reset; : > "$T/ans.classes_delegation.down"; ai "Archie delegate watch-cadence"
check "Dh archie transport failure: today's reply, nothing filed" '[ "$(filed)" = 0 ] && grep -qF "didn'"'"'t answer. Nothing changed." <<<"$OUT"'
noproof D

# ═════ I: the orchestrate.sh archie block passes the sender ══════════════════
SRC="$REPO/bin/orchestrate.sh"
BLOCK=$(sed -n '/^# >>> archie intercept/,/^# <<< archie intercept/p' "$SRC")
check "I0 the archie block exists" 'grep -q "archie.sh\" intercept" <<<"$BLOCK"'
SH_="$T/stubh"; mkdir -p "$SH_/bin" "$SH_/bin/lib"
cp "$H/bin/orc-context.sh" "$SH_/bin/orc-context.sh"
printf '#!/bin/bash\nprintf "%%s|%%s|%%s|%%s\\n" "$ARCHIE_TRANSPORT" "$ARCHIE_FROM_USER" "$ARCHIE_CMD_ID" "$2" > "$FXT/stub.args"\necho R\n' > "$SH_/bin/archie.sh"
chmod +x "$SH_/bin/archie.sh"
printf '%s' "$BLOCK" > "$T/block.sh"
rm -rf "$T/orc"; mkdir -p "$T/orc"
env "${UNSET[@]}" FXT="$T" HARNESS="$SH_" ORC="$T/orc" TEXT="Archie delegate watch-cadence" CMD_ID=c9 META_TRANSPORT=telegram \
  META_FROM_USER=operator_fixture bash -c 'set -uo pipefail
    deliver_reply() { printf "%s" "$1" > "$FXT/delivered"; }
    . "$FXT/block.sh"' >/dev/null 2>&1
eq "I1 the sidecar sender reaches archie.sh" "$(cat "$T/stub.args" 2>/dev/null)" "telegram|operator_fixture|c9|Archie delegate watch-cadence"

echo "owner-approvals-chat: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
