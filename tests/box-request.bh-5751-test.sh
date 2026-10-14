#!/bin/bash
# tests/box-request.bh-5751-test.sh — BH-5751: the orchestrator's box and
# project verbs, driven through the SHIPPED bin/box-request.sh (intercept and
# watch) and the `# >>> box request intercept` block lifted from
# bin/orchestrate.sh.
#
# WHAT IS STUBBED. A scratch harness $H gets the script's closure, the real
# bin/jobs-client.sh transport and bin/fleet-conf.sh. PATH carries a `curl`
# that models the jobs worker over $T/db.json: POST/GET /api/box-commands
# (the owner gate on $T/owners, the open-row dedup, the stale_quote check of
# routes/box-commands.js), GET /api/orgo-computers, and GET/PUT
# /api/ledger + POST /api/ledger/claim (the compare-and-set). Every request
# lands in $T/reqlog as `<method> <path> <body>`. A finished hub row is
# modelled by $T/finish.<type> (line 1 status, line 2 detail): the row is
# born finished, as if bin/box-ops.sh ran it at once. bin/alert-line.sh and
# bin/archie-tg-send.sh are stubs that log to $T/alerts.log and $T/sends.log.
#
# Sections: O owner, P placement, N sentence matcher, Q quote, Y yes/launch,
# L /project load, W watch, R /box list, I orchestrate block, S authority,
# K knobs, X mutations of the shipped script (D1).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/box-request.bh-5751-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "box-request: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

# The product paths this ticket ships (D41).
SCRIPT="$DIR/bin/box-request.sh"
RULES="$DIR/prompts/box-placement.json"
KNOBS="$DIR/env-templates/lanes/383-box-request.env.example"
for f in "$SCRIPT" "$RULES" "$KNOBS" "$DIR/docs/notes/2026-10-14-BH-5751-box-requests.md"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
if [ ! -f "$SCRIPT" ]; then echo "box-request: $PASS passed, $FAIL failed"; exit 1; fi

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/bin" "$H/env" "$H/logs" "$H/locks" "$H/flags" "$H/prompts" "$H/catalog" "$T/fakebin"
for s in bin/box-request.sh bin/jobs-client.sh bin/fleet-conf.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: cannot install the closure of $s"; exit 1; }
done
cp "$RULES" "$H/prompts/box-placement.json"
cat > "$T/fleet.conf" <<'EOF'
alpha example-org/alpha https://alpha.example.com /api/board 3 project-6-os
EOF
# The plan map in the shipped shape, with a disk default so a bare ask can be priced.
jq '.accounts["project-6-account"].defaults.disk_gb = 50' "$DIR/catalog/orgo-plans.json" > "$T/plans-disk.json"
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts.log"
SH
cat > "$H/bin/archie-tg-send.sh" <<'SH'
#!/bin/bash
printf '%s\t%s\n' "$1" "$2" >> "$FXT/sends.log"
exit "$(cat "$FXT/send.rc" 2>/dev/null || echo 0)"
SH
cat > "$H/bin/orc-context.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/orc-context.log"
SH
chmod +x "$H/bin/alert-line.sh" "$H/bin/archie-tg-send.sh" "$H/bin/orc-context.sh"

# The jobs worker, as the curl the transport runs (bin/lib/jobs/req.sh reads
# "<payload>\n<code>"). A $T/<route>.down file is a transport failure (rc 7).
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
m=GET; data=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift 2 ;;
    --data-binary) data="$2"; shift 2 ;;
    -H|-m|-w|--connect-timeout|-K) shift 2 ;;
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
case "$route" in /api/ledger*) [ -f "$FXT/ledger.down" ] && exit 7 ;; esac
case "$m $route" in
  "POST /api/box-commands")
    type=$(jq -r .type <<<"$data")
    [ -f "$FXT/post.$type.down" ] && exit 7
    [ -f "$FXT/post.$type.code" ] && ans "$(cat "$FXT/post.$type.code")" "$(cat "$FXT/post.$type.body")"
    grep -qxF -- "$(jq -r '.actor // ""' <<<"$data")" "$FXT/owners" || ans 403 '{"error":"owner_only"}'
    target=$(jq -r '.target // ""' <<<"$data")
    if [ "$type" = orgo_launch ]; then
      [ -f "$FXT/stale" ] && ans 409 '{"error":"stale_quote"}'
      jq -e --argjson b "$data" '.rows[] | select(.id == $b.quote_id and .type == "orgo_launch_quote"
        and .status == "ok" and .target == $b.target and .requested_by == $b.actor
        and ((.detail // "") | test("usd_mo=" + $b.confirm_monthly_usd + "\\b")))' "$db" >/dev/null \
        || ans 409 '{"error":"stale_quote"}'
    fi
    open=$(jq -c --arg t "$type" --arg g "$target" '[.rows[] | select(.type == $t and .target == $g
      and (.status == "requested" or .status == "claimed"))][0] // empty' "$db")
    [ -n "$open" ] && ans 200 "$(jq -c '{id, status, command: ., deduped: true}' <<<"$open")"
    id=$(jq .next "$db"); st=requested; det=null
    if [ -f "$FXT/finish.$type" ]; then st=$(sed -n 1p "$FXT/finish.$type"); det=$(sed -n 2p "$FXT/finish.$type" | jq -Rc .); fi
    jq --argjson b "$data" --argjson i "$id" --arg s "$st" --argjson d "$det" '.next += 1
      | .rows += [{id: $i, box: $b.box, type: $b.type, target: ($b.target // ""),
          args: ($b | del(.box, .type, .target, .reason, .actor, .confirm)), status: $s,
          requested_by: $b.actor, detail: $d,
          finished_at: (if $s == "requested" then null else "2026-10-14T07:00:00Z" end)}]' "$db" > "$db.t" && mv "$db.t" "$db"
    ans 201 "$(jq -c --argjson i "$id" '.rows[] | select(.id == $i) | {id, status, command: ., deduped: false}' "$db")" ;;
  "GET /api/box-commands")
    [ -f "$FXT/list.down" ] && exit 7
    ans 200 "$(jq -c '{commands: (.rows | reverse | .[0:50]), truncated: ((.rows | length) > 50)}' "$db")" ;;
  "GET /api/orgo-computers")
    [ -f "$FXT/computers.code" ] && ans "$(cat "$FXT/computers.code")" '{"error":"orgo_computers unavailable"}'
    ans 200 "$(jq -c '{computers: (.computers // []), accounts: {}, truncated: false}' "$db")" ;;
  "GET /api/ledger")
    k=$(qp key); k=$(printf '%b' "${k//%/\\x}")
    r=$(jq -c --arg k "$(qp kind)|$k" '.ledgers[$k] // empty' "$db")
    [ -n "$r" ] || ans 404 '{"error":"not found"}'
    ans 200 "$(jq -c '{ledger: .}' <<<"$r")" ;;
  "PUT /api/ledger")
    jq --argjson b "$data" '"\($b.kind)|\($b.key)" as $k
      | .ledgers[$k] = ((.ledgers[$k] // {kind: $b.kind, key: $b.key}) + {status: $b.status}
          + (if $b.detail then {detail: $b.detail} else {} end) + (if $b.actor then {actor: $b.actor} else {} end))' \
      "$db" > "$db.t" && mv "$db.t" "$db"
    ans 200 "$(jq -c --argjson b "$data" '{ledger: .ledgers["\($b.kind)|\($b.key)"]}' "$db")" ;;
  "POST /api/ledger/claim")
    [ -f "$FXT/claim.lost" ] && ans 200 '{"claimed":false}'
    k=$(jq -r '"\(.kind)|\(.key)"' <<<"$data")
    cur=$(jq -r --arg k "$k" '.ledgers[$k].status // ""' "$db")
    if [ -n "$cur" ] && { jq -e --arg c "$cur" '(.terminal // []) | index($c) != null' <<<"$data" >/dev/null \
         || [ "$cur" = "$(jq -r .status <<<"$data")" ]; }; then ans 200 '{"claimed":false}'; fi
    jq --argjson b "$data" '"\($b.kind)|\($b.key)" as $k | .ledgers[$k] = {kind: $b.kind, key: $b.key, status: $b.status, actor: $b.actor}' \
      "$db" > "$db.t" && mv "$db.t" "$db"
    ans 200 '{"claimed":true}' ;;
  *) ans 404 '{"error":"no route"}' ;;
esac
SH
chmod +x "$T/fakebin/curl"

NOW=1791190800                         # 2026-10-14T07:00:00Z, the offer clock
OWNERS_LINE='BOX_CHAT_OWNERS="telegram:owner_a=OWNER@EXAMPLE.COM ,telegram:@Second_B=second@example.com"'
QDETAIL='box-launch: box=acme orgo=- ip=- specs=4c/8gb/50gb usd_mo=42 smoke=PENDING'

# reset: a fresh worker, the default owner map and the disk-default plan map.
reset() {
  local f
  for f in reqlog alerts.log sends.log spawn.log orc-context.log stale claim.lost ledger.down list.down \
           computers.code send.rc; do rm -f "$T/$f"; done
  rm -f "$T"/post.* "$T"/finish.*
  echo '{"next":100,"rows":[],"ledgers":{},"computers":null}' > "$T/db.json"
  printf 'owner@example.com\nsecond@example.com\n' > "$T/owners"
  printf '%s\n' "$OWNERS_LINE" > "$H/env/global.env"
  cp "$T/plans-disk.json" "$H/catalog/orgo-plans.json"
  cp "$RULES" "$H/prompts/box-placement.json"
  printf 'ok\n%s\n' "$QDETAIL" > "$T/finish.orgo_launch_quote"
}
# br <user> <text> [script]: one intercept. USER_TR/CHAT/THREAD/AT override.
br() {
  env HARNESS_TEST_SANDBOX=1 HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" \
    JOBS_URL=http://jobs.invalid HARNESS_SECRET=fixture-secret JOBS_RETRIES=0 FLEET_CONF="$T/fleet.conf" \
    BOXREQ_TRANSPORT="${TR:-telegram}" BOXREQ_FROM_USER="$1" BOXREQ_CHAT="${CHAT:--1001234}" \
    BOXREQ_THREAD="${THREAD:-7}" BOXREQ_NOW="${AT:-$NOW}" BOXREQ_SPAWN_LOG="$T/spawn.log" \
    BOX_REQUEST_QUOTE_WAIT_S="${QWAIT:-2}" BOX_REQUEST_POLL_S=1 ${KNOB:+"$KNOB"} \
    bash "${3:-$H/bin/box-request.sh}" intercept "$2" > "$T/out" 2> "$T/err"
  RCV=$?; OUT=$(cat "$T/out")
}
cnt() { if [ -f "$T/reqlog" ]; then grep -c -- "$1" "$T/reqlog"; else echo 0; fi; }
posts() { cnt "^POST /api/box-commands {.*\"type\":\"$1\""; }
allposts() { cnt '^POST /api/box-commands '; }
nalerts() { if [ -f "$T/alerts.log" ]; then wc -l < "$T/alerts.log" | tr -d ' '; else echo 0; fi; }
body_of() { grep "^POST /api/box-commands {.*\"type\":\"$1\"" "$T/reqlog" | sed -n "${2:-1}p" | cut -d' ' -f3-; }
offer() { jq -r --arg k "box_offer|telegram:${CHAT:--1001234}:${THREAD:-7}" '.ledgers[$k].status // ""' "$T/db.json"; }

# ═════ O: owner resolution ═══════════════════════════════════════════════════
reset; br @Owner_A "we need a box for acme"
eq "O1 @Owner_A resolves: the quote's actor" "$(body_of orgo_launch_quote | jq -r .actor)" owner@example.com
eq "O1 rc 0" "$RCV" 0
reset; br stranger "we need a box for acme"
eq "O2 unknown username: no POST" "$(allposts)" 0
check "O2 the reply says only an owner" 'grep -qF "Only an owner can ask for this. I queued nothing." <<<"$OUT"'
reset; TR=slack br owner_a "we need a box for acme"
eq "O3 a slack sender: no POST" "$(allposts)" 0
reset; TR=dash br "" "/box launch acme"
eq "O4 a dash message (no sender): no POST" "$(allposts)" 0
check "O4 the reply says only an owner" 'grep -qF "Only an owner" <<<"$OUT"'
reset; printf '%s\n' 'BOX_CHAT_OWNERS="telegram:owner_a=owner@example.com,telegram:Owner_A=second@example.com"' > "$H/env/global.env"
br owner_a "we need a box for acme"
eq "O5 a username with two emails: no POST" "$(allposts)" 0
eq "O5 one ALERTS line" "$(nalerts)" 1
check "O5 the alert names the duplicate" 'grep -q "listed with two emails" "$T/alerts.log"'
reset; br owner_a "we need a box for acme"; br owner_a "yes"
check "O6 every POST carries the owner email as actor" \
  '[ "$(allposts)" = 2 ] && ! grep "^POST /api/box-commands " "$T/reqlog" | cut -d" " -f3- | jq -r .actor | grep -vqx owner@example.com'
check "O6 no POST carries orchestrator, console or hub as actor" \
  '! grep "^POST /api/box-commands " "$T/reqlog" | cut -d" " -f3- | jq -r .actor | grep -Eqx "orchestrator|console|hub"'

# ═════ P: the placement rule (read-only /project load) ═══════════════════════
place_of() { reset; br owner_a "/project load acme $1"; sed -n 's/^Placement rule for acme: \([a-z]*\),.*/\1/p' <<<"$OUT"; }
eq "P1 --desktop -> dedicated"        "$(place_of --desktop)" dedicated
eq "P2 --isolated -> dedicated"       "$(place_of --isolated)" dedicated
eq "P3 --repo-mb 2000 -> dedicated"   "$(place_of '--repo-mb 2000')" dedicated
eq "P3 --repo-mb 1999 -> shared"      "$(place_of '--repo-mb 1999')" shared
eq "P4 --builds-day 10 -> fly"        "$(place_of '--builds-day 10')" fly
eq "P4 --builds-day 9 -> shared"      "$(place_of '--builds-day 9')" shared
eq "P5 no facts -> shared"            "$(place_of '')" shared
reset; br owner_a "/project load acme"
check "P5 the reply names the four unknown facts" 'grep -qF "Unknown facts: repo_mb, builds_day, desktop, isolated" <<<"$OUT"'
reset; printf '{"rules": [{"when": {"fact": "colour", "is": true}, "place": "dedicated", "why": "x"}, {"place": "shared", "why": "y"}]}\n' > "$H/prompts/box-placement.json"
br owner_a "/box launch acme"
eq "P6 an unknown fact: no POST" "$(allposts)" 0
check "P6 the refusal reply" 'grep -qF "The placement rule file is broken: rule 1: unknown fact colour. I queued nothing." <<<"$OUT"'
eq "P6 one ALERTS line" "$(nalerts)" 1
reset; echo '{"rules": [' > "$H/prompts/box-placement.json"; br owner_a "/box launch acme"
check "P6 a file that does not parse: refusal, no POST" '[ "$(allposts)" = 0 ] && grep -qF "The placement rule file is broken" <<<"$OUT"'
check "P7 the shipped rule file has no usd, price or cost key" \
  '! jq -r "[paths | .[] | strings] | .[]" "$RULES" | grep -Eqi "usd|price|cost"'
check "P7 the shipped rule file parses and validates" \
  'reset; br owner_a "/project load acme"; grep -q "^Placement rule for acme: shared" <<<"$OUT"'

# ═════ N: the sentence matcher ═══════════════════════════════════════════════
reset; br owner_a "I need a new box for acme."
eq "N2 'I need a new box for acme.' quotes" "$(posts orgo_launch_quote)" 1
for s in "do we need a box for acme?" "we don't need a box for acme" "we need a box for acme to test" \
         "need a box" "fyi: /box launch acme" "/box launch ac;me" "/box launch ac me"; do
  reset; br owner_a "$s"
  eq "N3-N8 '$s': zero POSTs" "$(allposts)" 0
  check "N3-N8 '$s': rc 1 or a usage reply" '[ "$RCV" = 1 ] || grep -q "^.*Use: /box launch" <<<"$OUT"'
done
reset; br owner_a "what is the build queue doing?"
check "N9 not a verb: rc 1, nothing said, no request" '[ "$RCV" = 1 ] && [ -z "$OUT" ] && [ ! -f "$T/reqlog" ]'
reset; br owner_a $'[telegram: from Owner A (@owner_a), topic ops — a full-authority principal of the the operator Harness group]\n/box launch acme'
eq "N10 the poll-commands attribution line is dropped" "$(posts orgo_launch_quote)" 1
reset; br owner_a $'please look at this\n/box launch acme'
check "N11 a verb inside other text: rc 1, no POST" '[ "$RCV" = 1 ] && [ "$(allposts)" = 0 ]'

# ═════ Q: the quote step ═════════════════════════════════════════════════════
reset; br owner_a "we need a box for acme"
eq "Q1 exactly one orgo_launch_quote" "$(posts orgo_launch_quote)" 1
eq "Q1 zero orgo_launch" "$(posts orgo_launch)" 0
check "Q1 the reply carries \$42/mo from the quote row" 'grep -qF "costs \$42/mo" <<<"$OUT"'
check "Q1 the reply carries the recommendation" 'grep -qF "Placement rule: shared, because a small project" <<<"$OUT"'
check "Q1 the reply asks for a yes" 'grep -qF "Reply yes within 15 minutes to launch it." <<<"$OUT"'
B=$(body_of orgo_launch_quote)
eq "Q1 the quote body: box, target, specs, project, account" \
  "$(jq -c '[.box, .target, .account, .project, .vcpus, .mem_gb, .disk_gb, .confirm]' <<<"$B")" \
  '["hub","acme","project-6-account","acme",4,8,50,true]'
eq "Q1 an offer is open" "$(offer)" offered
reset; br owner_a "/box launch acme"
check "Q2 /box launch: one quote, no launch, the figure" '[ "$(posts orgo_launch_quote)" = 1 ] && [ "$(posts orgo_launch)" = 0 ] && grep -qF "\$42/mo" <<<"$OUT"'
reset; printf 'fail\nNEEDS PURCHASE: ram 8 $40/mo\n' > "$T/finish.orgo_launch_quote"; br owner_a "/box launch acme"
check "Q3 a failed quote: the detail is the reply" 'grep -qF "failed: NEEDS PURCHASE: ram 8 \$40/mo" <<<"$OUT"'
eq "Q3 no offer" "$(offer)" ""
reset; rm -f "$T/finish.orgo_launch_quote"; br owner_a "/box launch acme"
check "Q4 a quote that never finishes: the timeout reply" 'grep -qF "did not finish in 2s" <<<"$OUT"'
eq "Q4 no offer" "$(offer)" ""
reset; printf 'ok\nbox-launch: box=acme orgo=- ip=- specs=4c/8gb/50gb smoke=PENDING\n' > "$T/finish.orgo_launch_quote"; br owner_a "/box launch acme"
check "Q5 ok without usd_mo: no figure, no offer" '[ "$(offer)" = "" ] && grep -qF "named no monthly price" <<<"$OUT" && ! grep -q "costs \\$" <<<"$OUT"'
reset; cp "$DIR/catalog/orgo-plans.json" "$H/catalog/orgo-plans.json"; br owner_a "/box launch acme"
eq "Q6 the shipped plan map has no disk default: no POST" "$(allposts)" 0
check "Q6 the reply asks for --disk-gb" 'grep -qF "Send /box launch acme --disk-gb N; the plan has no default disk-gb." <<<"$OUT"'
reset; cp "$DIR/catalog/orgo-plans.json" "$H/catalog/orgo-plans.json"; br owner_a "/box launch acme --disk-gb 50"
eq "Q6 with --disk-gb: one quote" "$(posts orgo_launch_quote)" 1
reset; br owner_a "/box launch acme --id hub"
check "Q7 --id hub: no POST, taken" '[ "$(allposts)" = 0 ] && grep -qF "Box id hub is taken" <<<"$OUT"'
reset; br owner_a "/box launch acme --id project-6-os"
check "Q7 --id of a fleet.conf box: no POST, taken" '[ "$(allposts)" = 0 ] && grep -qF "Box id project-6-os is taken" <<<"$OUT"'
reset; br owner_a "/box launch Acme-OS"
eq "Q7 the derived id drops -os and case" "$(body_of orgo_launch_quote | jq -r .target)" acme
reset; printf 'ok\nbox-launch: box=acme orgo=- ip=- specs=4c/8gb/50gb usd_mo=17 smoke=PENDING\n' > "$T/finish.orgo_launch_quote"
br owner_a "/box launch acme"
check "Q8 the figure follows the quote row (usd_mo=17)" 'grep -qF "\$17/mo" <<<"$OUT" && ! grep -qF "\$42" <<<"$OUT"'
check "Q8 no \$ figure absent from the quote detail" \
  '[ -z "$(grep -o "\\$[0-9][0-9.]*" <<<"$OUT" | grep -vx "\\$17")" ]'
reset; echo 403 > "$T/post.orgo_launch_quote.code"; echo '{"error":"owner_only"}' > "$T/post.orgo_launch_quote.body"
br owner_a "/box launch acme"
check "Q9 the worker's 403: the BOX_OPS_OWNERS reply" 'grep -qF "not an owner (BOX_OPS_OWNERS)" <<<"$OUT"'
reset; echo 409 > "$T/post.orgo_launch_quote.code"; echo '{"error":"open_command_differs","id":77}' > "$T/post.orgo_launch_quote.body"
br owner_a "/box launch acme"
check "Q9 open_command_differs: names the open row" 'grep -qF "Price check #77 for acme is still open" <<<"$OUT"'
reset; echo 500 > "$T/post.orgo_launch_quote.code"; echo '{}' > "$T/post.orgo_launch_quote.body"
br owner_a "/box launch acme"
check "Q9 any other answer: HTTP n, nothing queued" 'grep -qF "did not take the quote (HTTP 500). I queued nothing." <<<"$OUT"'

# ═════ Y: yes and the launch step ════════════════════════════════════════════
reset; br owner_a "we need a box for acme"
QID=$(jq '.rows[] | select(.type == "orgo_launch_quote") | .id' "$T/db.json")
br owner_a "yes"
eq "Y1 exactly one orgo_launch" "$(posts orgo_launch)" 1
L=$(body_of orgo_launch)
eq "Y1 quote_id = the quote row id" "$(jq -r .quote_id <<<"$L")" "$QID"
eq "Y1 confirm_monthly_usd = \"42\"" "$(jq -c .confirm_monthly_usd <<<"$L")" '"42"'
eq "Y1 actor = the owner" "$(jq -r .actor <<<"$L")" owner@example.com
eq "Y1 the launch args equal the quote's" "$(jq -c '[.target, .account, .project, .vcpus, .mem_gb, .disk_gb]' <<<"$L")" \
  "$(body_of orgo_launch_quote | jq -c '[.target, .account, .project, .vcpus, .mem_gb, .disk_gb]')"
LID=$(jq '.rows[] | select(.type == "orgo_launch") | .id' "$T/db.json")
check "Y1 the reply names the launch and the figure" 'grep -qF "Launch #$LID is queued at \$42/mo." <<<"$OUT"'
eq "Y1 the watcher is started for that id" "$(cat "$T/spawn.log")" "watch $LID"
eq "Y1 the launch claim is queued" "$(jq -r --arg k "box_launch|q$QID" '.ledgers[$k].status' "$T/db.json")" queued
eq "Y1 the offer is accepted" "$(offer)" accepted
br owner_a "yes"
eq "Y2 a second yes: still one orgo_launch" "$(posts orgo_launch)" 1
reset; br owner_a "we need a box for acme"; N0=$(allposts); br stranger "yes"
eq "Y3 a non-owner yes: no POST" "$(allposts)" "$N0"
check "Y3 the reply names the owner" 'grep -qF "Only owner@example.com can approve this. I queued nothing." <<<"$OUT"'
br second_b "yes"
eq "Y4 another owner's yes: no POST" "$(allposts)" "$N0"
eq "Y4 the offer stays open" "$(offer)" offered
reset; br owner_a "we need a box for acme"; QID=$(jq '.rows[0].id' "$T/db.json")
: > "$T/stale"; printf 'ok\nbox-launch: box=acme orgo=- ip=- specs=4c/8gb/50gb usd_mo=44 smoke=PENDING\n' > "$T/finish.orgo_launch_quote"
br owner_a "yes"
eq "Y5 stale_quote: a second orgo_launch_quote" "$(posts orgo_launch_quote)" 2
eq "Y5 one orgo_launch POST, with the old quote id" "$(grep -c "\"quote_id\":$QID" <(body_of orgo_launch))" 1
check "Y5 the reply asks again with the new figure" 'grep -qF "The price expired, so I checked it again." <<<"$OUT" && grep -qF "costs \$44/mo" <<<"$OUT" && grep -qF "Reply yes" <<<"$OUT"'
eq "Y5 the old claim is refused" "$(jq -r --arg k "box_launch|q$QID" '.ledgers[$k].status' "$T/db.json")" refused
rm -f "$T/stale"; br owner_a "yes"
NEWQ=$(jq '[.rows[] | select(.type == "orgo_launch_quote")] | last | .id' "$T/db.json")
eq "Y5 the next yes launches with the NEW quote" "$(body_of orgo_launch 2 | jq -c '[.quote_id, .confirm_monthly_usd]')" "[$NEWQ,\"44\"]"
eq "Y5 the old quote id is sent once only" "$(grep -c "\"quote_id\":${QID}[,}]" "$T/reqlog")" 1
reset; br owner_a "yes"
check "Y6 yes with no offer: rc 1, no POST" '[ "$RCV" = 1 ] && [ "$(allposts)" = 0 ] && [ -z "$OUT" ]'
reset; br owner_a "we need a box for acme"; N0=$(allposts); AT=$((NOW + 901)) br owner_a "yes"
check "Y7 a yes 901s after the offer: rc 1, no POST" '[ "$RCV" = 1 ] && [ "$(allposts)" = "$N0" ]'
AT=$((NOW + 900)) br owner_a "YES!"
eq "Y7 YES! at 900s launches" "$(posts orgo_launch)" 1
reset; br owner_a "we need a box for acme"; THREAD=8 br owner_a "yes"
check "Y7 a yes in another thread: rc 1, no launch" '[ "$RCV" = 1 ] && [ "$(posts orgo_launch)" = 0 ]'
br owner_a "yes, but wait"
check "Y7 'yes, but wait': rc 1, no launch" '[ "$RCV" = 1 ] && [ "$(posts orgo_launch)" = 0 ]'
: > "$T/claim.lost"; br owner_a "yes"
eq "Y8 the claim is lost: no orgo_launch" "$(posts orgo_launch)" 0
check "Y8 the reply" 'grep -qF "This launch is already being queued." <<<"$OUT"'
rm -f "$T/claim.lost"; : > "$T/ledger.down"; br owner_a "yes"
eq "Y8 the ledger is down: no orgo_launch (no offer read)" "$(posts orgo_launch)" 0
rm -f "$T/ledger.down"
reset; br owner_a "we need a box for acme"; : > "$T/post.orgo_launch.down"; br owner_a "yes"
check "Y9 transport failure: the unknown-outcome reply" 'grep -qF "I do not know if the launch was queued" <<<"$OUT"'
N0=$(cnt '"type":"orgo_launch"'); rm -f "$T/post.orgo_launch.down"; br owner_a "yes"
eq "Y9 a third yes makes no POST" "$(cnt '"type":"orgo_launch"')" "$N0"
eq "Y9 the claim stays claimed" "$(jq -r '[.ledgers[] | select(.kind == "box_launch")][0].status' "$T/db.json")" claimed
reset; br owner_a "we need a box for acme"; echo 403 > "$T/post.orgo_launch.code"; echo '{"error":"owner_only"}' > "$T/post.orgo_launch.body"
br owner_a "yes"
check "Y10 the worker's 403 on launch: refused, BOX_OPS_OWNERS reply" \
  'grep -qF "not an owner (BOX_OPS_OWNERS)" <<<"$OUT" && [ "$(jq -r "[.ledgers[] | select(.kind == \"box_launch\")][0].status" "$T/db.json")" = refused ]'

# ═════ L: /project load ══════════════════════════════════════════════════════
reset; br owner_a "/project load acme --builds-day 12"
eq "L1 /project load: zero POSTs before yes" "$(allposts)" 0
check "L1 the reply recommends fly and asks for a yes" 'grep -qF "Placement rule for acme: fly" <<<"$OUT" && grep -qF "Reply yes within 15 minutes to go ahead." <<<"$OUT"'
br owner_a "yes"
eq "L2 owner yes: one fly_onboard" "$(posts fly_onboard)" 1
eq "L2 target acme, the owner as actor" "$(body_of fly_onboard | jq -c '[.target, .actor, .box, has("cap")]')" '["acme","owner@example.com","hub",false]'
br owner_a "yes"
eq "L6 a second yes: no more POSTs" "$(allposts)" 1
reset; : > "$H/flags/fly-pool-acme"; br owner_a "/project load acme --builds-day 12 --cap 3"; br owner_a "yes"
check "L3 in the pool + --cap 3: one fly_pool_cap with cap 3" '[ "$(posts fly_pool_cap)" = 1 ] && [ "$(body_of fly_pool_cap | jq .cap)" = 3 ] && [ "$(posts fly_onboard)" = 0 ]'
reset; br owner_a "/project load acme --builds-day 12"; br owner_a "yes"
check "L3 in the pool, no cap: nothing to queue" '[ "$(allposts)" = 0 ] && grep -qF "already in the Fly pool" <<<"$OUT"'
rm -f "$H/flags/fly-pool-acme"
reset; br owner_a "/project load acme --desktop"; br owner_a "yes"
check "L4 dedicated + yes: one quote, no launch" '[ "$(posts orgo_launch_quote)" = 1 ] && [ "$(posts orgo_launch)" = 0 ] && grep -qF "costs \$42/mo" <<<"$OUT"'
br owner_a "yes"
eq "L4 a second yes after the price launches" "$(posts orgo_launch)" 1
reset; br owner_a "/project load acme"; br owner_a "yes"
check "L5 shared + yes: zero POSTs, the fleet.conf reply" '[ "$(allposts)" = 0 ] && grep -qF "fits the shared box. Adding it is a fleet.conf PR" <<<"$OUT"'
reset; br owner_a "/project load acme --builds-day 12"; echo 403 > "$T/post.fly_onboard.code"; echo '{"error":"owner_only"}' > "$T/post.fly_onboard.body"
br owner_a "yes"
check "L8 the worker's 403 on fly_onboard: the BOX_OPS_OWNERS reply, offer refused" 'grep -qF "not an owner (BOX_OPS_OWNERS)" <<<"$OUT" && [ "$(offer)" = refused ]'
reset; br owner_a "/project load acme --builds-day 12"; : > "$T/post.fly_onboard.down"; br owner_a "yes"
check "L9 transport failure on fly_onboard: the unknown-outcome reply" 'grep -qF "I do not know if fly_onboard was queued" <<<"$OUT"'
rm -f "$T/post.fly_onboard.down"; N0=$(cnt '"type":"fly_onboard"'); br owner_a "yes"
eq "L9 a second yes makes no POST" "$(cnt '"type":"fly_onboard"')" "$N0"
reset; br stranger "/project load acme"
check "L7 a non-owner /project load: no offer" '[ "$(offer)" = "" ] && grep -qF "Only an owner" <<<"$OUT"'

# ═════ W: the launch watcher ═════════════════════════════════════════════════
# addrow <id> <status> <detail>: a launch row in the hub list.
addrow() { jq --argjson i "$1" --arg s "$2" --arg d "$3" '.rows += [{id: $i, box: "hub", type: "orgo_launch", target: "acme", status: $s, detail: $d}]' "$T/db.json" > "$T/db.t" && mv "$T/db.t" "$T/db.json"; }
wt() {
  env HARNESS_TEST_SANDBOX=1 HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" JOBS_URL=http://jobs.invalid \
    HARNESS_SECRET=fixture-secret JOBS_RETRIES=0 BOX_REQUEST_WATCH_S="${WS:-5}" BOX_REQUEST_WATCH_POLL_S=1 \
    bash "$H/bin/box-request.sh" watch "$1" > "$T/out" 2> "$T/err"; RCV=$?
}
WLINE='box-launch: box=acme orgo=o1 ip=192.0.2.4 specs=4c/8gb/50gb usd_mo=42 smoke=PASS'
reset; addrow 300 ok "NEXT: done
$WLINE"; wt 300
eq "W1 one send" "$(wc -l < "$T/sends.log" | tr -d ' ')" 1
eq "W1 the send carries the summary line" "$(cat "$T/sends.log")" "box-launch-300	launch #300: ok $WLINE"
reset; addrow 301 fail "bootstrap: ssh refused"; wt 301
check "W2 a failed launch: one send that starts fail" 'grep -q "^box-launch-301	launch #301: fail bootstrap: ssh refused$" "$T/sends.log"'
reset; addrow 302 claimed ""; WS=2 wt 302
check "W3 never finishes: zero sends, one ALERTS line" '[ ! -f "$T/sends.log" ] && [ "$(nalerts)" = 1 ] && grep -qF "launch #302 did not finish in 2s" "$T/alerts.log"'
reset; addrow 303 ok "$WLINE"
( exec 8>"$H/locks/box-request-watch-303.lock"; flock -n 8; wt 303; echo "$RCV" > "$T/w4.rc" )
check "W4 the lock held: exit 0, zero requests" '[ "$(cat "$T/w4.rc")" = 0 ] && [ ! -f "$T/reqlog" ] && [ ! -f "$T/sends.log" ]'
reset; addrow 304 ok "$WLINE"; echo 1 > "$T/send.rc"; WS=2 wt 304
check "W5 a failed send is retried on the next poll" '[ "$(wc -l < "$T/sends.log" | tr -d " ")" -ge 2 ]'

# ═════ R: /box list ══════════════════════════════════════════════════════════
reset
jq '.computers = [{orgo_id: "o1", name: "acme", account: "project-6-account", status: "running", cpu: 4, ram_gb: 8, disk_gb: 50},
                  {orgo_id: "o2", name: "beta", account: "project-6-account", status: "stopped", cpu: null, ram_gb: 4, disk_gb: null, gone_at: "2026-10-13T00:00:00Z"}]' \
  "$T/db.json" > "$T/db.t" && mv "$T/db.t" "$T/db.json"
addrow 201 ok x; addrow 202 fail y; addrow 203 requested ""
jq '.rows += [{id: 204, box: "hub", type: "backup_now", target: "", status: "ok"}]' "$T/db.json" > "$T/db.t" && mv "$T/db.t" "$T/db.json"
br stranger "/box list"
check "R1 both computers are named" 'grep -q "^- acme (project-6-account): running, 4 vCPU, 8 GB RAM, 50 GB disk$" <<<"$OUT" && grep -q "^- beta .*? vCPU.*gone since" <<<"$OUT"'
check "R1 the three box command ids, not the backup" 'grep -q "^- #201 orgo_launch" <<<"$OUT" && grep -q "^- #202 " <<<"$OUT" && grep -q "^- #203 " <<<"$OUT" && ! grep -q "#204" <<<"$OUT"'
check "R2 only GET requests" '[ "$(grep -vc "^GET " "$T/reqlog")" = 0 ]'
echo 503 > "$T/computers.code"; br stranger "/box list"
check "R3 a 503 on computers: says so and still lists the rows" 'grep -qF "the jobs worker did not answer (HTTP 503). Nothing listed." <<<"$OUT" && grep -q "^- #201 " <<<"$OUT"'

# ═════ I: the orchestrate.sh block ═══════════════════════════════════════════
SRC="$DIR/bin/orchestrate.sh"
BLOCK=$(sed -n '/^# >>> box request intercept/,/^# <<< box request intercept/p' "$SRC")
check "I0 the box request block exists" 'grep -q "box-request.sh\" intercept" <<<"$BLOCK"'
# run_block <harness> <text>: the block lifted verbatim; deliver_reply recorded,
# a fall-through marker after it standing in for the model turn.
run_block() {
  rm -rf "$T/orc"; mkdir -p "$T/orc"; rm -f "$T/delivered" "$T/fell"
  printf '%s' "$BLOCK" > "$T/block.sh"
  env HARNESS_TEST_SANDBOX=1 FXT="$T" PATH="$T/fakebin:$PATH" JOBS_URL=http://jobs.invalid HARNESS_SECRET=fixture-secret \
    JOBS_RETRIES=0 FLEET_CONF="$T/fleet.conf" HARNESS="$1" ORC="$T/orc" TEXT="$2" CMD_ID=c9 META_TRANSPORT=telegram \
    META_FROM_USER="${3:-owner_a}" META_CHAT=-1001234 META_THREAD=7 \
    bash -c 'set -uo pipefail
      deliver_reply() { printf "%s" "$1" > "$FXT/delivered"; }
      archie_sign() { printf "%s\n" "$1"; }
      . "$FXT/block.sh"
      : > "$FXT/fell"' > /dev/null 2>&1
}
SH_="$T/stubh"; mkdir -p "$SH_/bin"
cp "$H/bin/orc-context.sh" "$SH_/bin/orc-context.sh"
printf '#!/bin/bash\nprintf "%%s|%%s|%%s|%%s|%%s\\n" "$BOXREQ_TRANSPORT" "$BOXREQ_FROM_USER" "$BOXREQ_CHAT" "$BOXREQ_THREAD" "$2" > "$FXT/stub.args"\necho R\n' > "$SH_/bin/box-request.sh"
chmod +x "$SH_/bin/box-request.sh"
run_block "$SH_" "/box list"
check "I1 stub rc 0 + R: delivered, the turn never ran" '[ "$(cat "$T/delivered")" = R ] && [ ! -e "$T/fell" ]'
eq "I1 the sidecar values reach the script" "$(cat "$T/stub.args")" "telegram|owner_a|-1001234|7|/box list"
check "I1 the turn is recorded for the next lane" 'grep -q "^append box " "$T/orc-context.log"'
printf '#!/bin/bash\nexit 1\n' > "$SH_/bin/box-request.sh"
run_block "$SH_" "hello"
check "I2 stub rc 1: no delivery, falls through" '[ -e "$T/fell" ] && [ ! -e "$T/delivered" ]'
rm -f "$SH_/bin/box-request.sh"; run_block "$SH_" "/box list"
check "I2 no script: falls through" '[ -e "$T/fell" ] && [ ! -e "$T/delivered" ]'
check "I3 the block sits after the archie block and before orct_claim" \
  'a=$(grep -n "^# <<< archie intercept" "$SRC" | cut -d: -f1); b=$(grep -n "^# >>> box request intercept" "$SRC" | cut -d: -f1); c=$(grep -n "^orct_claim " "$SRC" | head -1 | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]'
# I4: the sidecar block, lifted, keeps from_username before it removes the file.
SIDE=$(sed -n '/^ORIGIN=""; CMD_ID=""/,/^fi$/p' "$SRC")
printf '%s' '{"command_id":"c1","origin":"","from_username":"Owner_A","chat_id":"-1001234","thread_id":"7","transport":"telegram"}' > "$T/m.meta"
: > "$T/m"
U=$(env MSGF="$T/m" bash -c "$SIDE"$'\n''printf "%s|%s" "$META_FROM_USER" "$([ -e "$MSGF.meta" ] && echo kept || echo gone)"' 2>/dev/null)
eq "I4 META_FROM_USER is read before the sidecar goes" "$U" "Owner_A|gone"
U=$(env MSGF="$T/none" bash -c "$SIDE"$'\n''printf "[%s]" "$META_FROM_USER"' 2>/dev/null)
eq "I4 no sidecar: META_FROM_USER is empty" "$U" "[]"
# D2: the lifted block over the REAL script.
reset; run_block "$H" "/project load acme --builds-day 12"
check "I5 the real script through the block: the recommendation is delivered" 'grep -qF "Placement rule for acme: fly" "$T/delivered" && [ ! -e "$T/fell" ]'
reset; run_block "$H" "what is the build queue doing?"
check "I5 the real script, not a verb: falls through" '[ -e "$T/fell" ] && [ ! -e "$T/delivered" ]'

# ═════ S: the authority text ═════════════════════════════════════════════════
AUTH="$DIR/prompts/archie-soul.d/10-authority.md"
NEV=$(sed -n '/^NEVER:/,/^REPORT:/p' "$AUTH" | tr '\n' ' ' | tr -s ' ')
for s in "owner's yes" "price check is free" "only orgo_launch with a confirm token spends money"; do
  check "S1 the NEVER block names [$s]" 'grep -qF "$s" <<<"$NEV"'
done
check "S1 the MAY block names the free price check" \
  'sed -n "/^MAY, without asking:/,/^NEVER:/p" "$AUTH" | tr "\n" " " | tr -s " " | grep -qF "a free box price check (orgo_launch_quote)"'

# ═════ K: knobs ══════════════════════════════════════════════════════════════
reset; KNOB=BOX_REQUEST_QUOTE_WAIT_S=abc br owner_a "/box launch acme"
check "K1 a bad knob: no POST, one ALERTS line, the reply" \
  '[ "$(allposts)" = 0 ] && [ "$(nalerts)" = 1 ] && grep -qF "Box requests are not configured: BOX_REQUEST_QUOTE_WAIT_S." <<<"$OUT"'
reset; KNOB=BOX_REQUEST_OFFER_S=0 br owner_a "/box launch acme"
check "K1 zero is refused, never clamped" '[ "$(allposts)" = 0 ] && grep -qF "not configured: BOX_REQUEST_OFFER_S" <<<"$OUT"'
for k in BOX_CHAT_OWNERS BOX_REQUEST_QUOTE_WAIT_S BOX_REQUEST_POLL_S BOX_REQUEST_OFFER_S BOX_REQUEST_WATCH_S BOX_REQUEST_WATCH_POLL_S; do
  check "K2 the env template names $k" 'grep -q "^#$k=" "$KNOBS"'
done

# ═════ X: mutations of the shipped script (D1) ═══════════════════════════════
# X1: without the ledger claim, Y8's lost claim would still launch.
sed 's/^  \[ "\$claimed" = true \] || {.*$/  :/' "$H/bin/box-request.sh" > "$H/bin/box-request-x1.sh"
check "X1 the claim line exists" '! cmp -s "$H/bin/box-request-x1.sh" "$H/bin/box-request.sh"'
reset; br owner_a "we need a box for acme"; : > "$T/claim.lost"; br owner_a "yes" "$H/bin/box-request-x1.sh"
check "X1 mutant launches on a lost claim (so Y8 is a real guard)" '[ "$(posts orgo_launch)" = 1 ]'
# X2: a mutant that queues as the orchestrator; O6's check sees it.
sed 's/--arg o "\$OWNER"/--arg o orchestrator/' "$H/bin/box-request.sh" > "$H/bin/box-request-x2.sh"
check "X2 the actor binding exists" '! cmp -s "$H/bin/box-request-x2.sh" "$H/bin/box-request.sh"'
reset; br owner_a "we need a box for acme" "$H/bin/box-request-x2.sh"
check "X2 mutant sends actor orchestrator (so O6 is a real guard)" \
  'grep "^POST /api/box-commands " "$T/reqlog" | cut -d" " -f3- | jq -r .actor | grep -qx orchestrator'
# X3: a mutant whose figure is a constant, not the quote row's.
sed 's/fig="\${BASH_REMATCH\[2\]}"/fig=42/' "$H/bin/box-request.sh" > "$H/bin/box-request-x3.sh"
check "X3 the figure read exists" '! cmp -s "$H/bin/box-request-x3.sh" "$H/bin/box-request.sh"'
reset; printf 'ok\nbox-launch: box=acme orgo=- ip=- specs=4c/8gb/50gb usd_mo=17 smoke=PENDING\n' > "$T/finish.orgo_launch_quote"
br owner_a "/box launch acme" "$H/bin/box-request-x3.sh"
check "X3 mutant says \$42 for a \$17 quote (so Q8 is a real guard)" 'grep -qF "\$42/mo" <<<"$OUT"'
rm -f "$H/bin/box-request-x1.sh" "$H/bin/box-request-x2.sh" "$H/bin/box-request-x3.sh"

echo "box-request: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
