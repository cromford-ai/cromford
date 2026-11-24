#!/bin/bash
# tests/client-approval-close.bh-9901-test.sh — BH-9901 (BH-9887 slice C2):
# bin/client-approval-close.sh closes the board's approval request when the PR
# merges or closes, and bin/client-approval-request.sh mirrors the open request
# into the hub ledger (kind client-approval) for the console and MCP pr_stage.
# The real scripts, the real bin/lib/client-approval.sh, tracker.sh, board.sh,
# fleet-conf.sh and alert-line.sh run in a scratch tree against the C0 fake
# board (tests/fixtures/client-approval/fake-board.py on 127.0.0.1; the /close
# path is its `other` route). bin/jobs-client.sh is a stub: setting_get reads
# $ROWS/<key>, job_ledger_put appends its argv to $ROWS/puts.jsonl. No call
# leaves the box.
#
#   C1-C12  the close call and its answer table, superseded, no-id, tie
#   I1      a second run after closed: no POST
#   A1-A2   the retry cap and its ONE ALERTS line; a 404 alerts nothing
#   X1-X8   exit paths (bad args, lock held, switch off, no candidate, config
#           missing, hub fail -> pending -> hub-only retry, hub cap)
#   W1-W5   the request script writes the hub `waiting` row
#   U1-U6   lib units: ca_ticket_url, ca_mark_settled with hub
#   RT1     the ledger body equals tests/fixtures/client-approval/ledger-row.bh-9901.json
#   RT2     the new marker fields round-trip through every reader
#   D1      the close_max_per_tick fallback equals the seed row
#   B1      no external host, no token in a log
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/client-approval-close.bh-9901-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

H="$T/h"; ROWS="$T/rows"; FB="$T/fb"
TOKEN=tok-fixture-board-9901
export FLEET_CONF="$H/fleet.conf"
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/state" "$H/locks" "$ROWS" "$FB"
cat > "$H/bin/jobs-client.sh" <<'SH'
# stub jobs client: setting_get <key> -> $ROWS/<key> (rc 2 no row, rc 1 down);
# job_ledger_put <kind> <key> <status> <detail> -> one line in $ROWS/puts.jsonl,
# rc 1 while $ROWS/putfail exists.
setting_get() {
  [ -e "$ROWS/down" ] && return 1
  [ -r "$ROWS/$1" ] || return 2
  cat "$ROWS/$1"
}
job_ledger_put() {
  jq -nc --arg k "$1" --arg v "$2" --arg s "$3" --arg d "${4:-}" --arg f "$([ -e "$ROWS/putfail" ] && echo 1 || echo 0)" \
    '{kind:$k,key:$v,status:$s,detail:$d,failed:($f == "1")}' >> "$ROWS/puts.jsonl"
  [ -e "$ROWS/putfail" ] && return 1
  return 0
}
SH
NOLEDGER="$T/nl"; mkdir -p "$NOLEDGER"
for f in bin/client-approval-close.sh bin/client-approval-request.sh bin/fleet-conf.sh bin/internal-token-for.sh bin/lib/tracker.sh bin/alert-line.sh bin/lib/release-model.sh; do
  [ -e "$DIR/$f" ] || { bad "$f exists"; continue; }
  scratch_install_closure "$f" "$H" >/dev/null || { echo "FAIL: closure of $f"; exit 1; }
done
export ROWS

export FAKE_BOARD_TOKEN="$TOKEN"
python3 -I "$DIR/tests/fixtures/client-approval/fake-board.py" --dir "$FB" >/dev/null 2>&1 &
FBPID=$!
trap 'kill "$FBPID" 2>/dev/null' EXIT
for _ in $(seq 1 50); do [ -s "$FB/port" ] && break; sleep 0.1; done
[ -s "$FB/port" ] || { echo "FAIL: the fake board did not start"; exit 1; }
PORT=$(cat "$FB/port")
BASE="http://127.0.0.1:$PORT"

cat > "$H/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
project-3  example-org/project-3  https://os.project-3.example  /api/feature-board  6 box-1 192.0.2.1
nobase   example-org/nobase   https://nb.example    /api/feature-board  7 box-1 192.0.2.1
plain    example-org/plain    http://pl.example     /api/board          8 box-1 192.0.2.1
ghp      example-org/ghp      https://gh.example    -                   9 box-1 192.0.2.1
apib     example-org/apib     https://ab.example/   /api/board          9 box-1 192.0.2.1
CONF
printf 'PROJECT_3_OS_API_BASE=%s/\nproject-3_OS_INTERNAL_API_TOKEN=%s\n' "$BASE" "$TOKEN" > "$H/env/project-3.env"
printf 'NOBASE_INTERNAL_API_TOKEN=%s\n' "$TOKEN" > "$H/env/nobase.env"
SW=client_approval_board.example-org.project-3
on() { printf 'on' > "$ROWS/$SW"; }

hx() { printf '%040x' "$1"; }
hb() { printf 'b%039x' "$1"; }
mk() { printf '%s/state/client-approval/%s/%s-%s.json' "$H" "${3:-project-3}" "$1" "$2"; }
mf() { jq -r "$3" "$(mk "$1" "$2" "${4:-project-3}")" 2>/dev/null; }
# mark <pr> <head> <status> <rid|null> [checked_at] [extra-jq] [project] — a C0
# marker as bin/client-approval-request.sh writes it.
mark() {
  local f; f=$(mk "$1" "$2" "${7:-project-3}"); mkdir -p "${f%/*}"
  jq -nc --argjson pr "$1" --arg h "$2" --arg s "$3" --arg rid "$4" --argjson c "${5:-1795000000}" --arg p "${7:-project-3}" \
    '{v:1,project:$p,repo:"example-org/project-3",pr:$pr,head:$h,ticket_id:"T-\($pr)",status:$s,attempts:0,last_http:"201",
      checked_at:$c,request_id:(if $rid == "null" then null else $rid end),approvers:[],comment:"posted",comment_attempts:0,updated_at:$c}' \
    | jq -c "${6:-.}" > "$f"
}
script() { mkdir -p "$FB/script"; printf '%s\n%s' "$2" "${3:-}" > "$FB/script/$1"; }
noscript() { rm -f "$FB/script/$1"; }
# close <project> <slug> <pr> <state> — the real close script; prints rc.
close() {
  ( cd "$T" && HARNESS="$H" ROWS="$ROWS" bash "$H/bin/client-approval-close.sh" "$@" >>"$T/run.out" 2>&1 ); echo "rc=$?"
}
closeom() { close project-3 example-org/project-3 "$1" "${2:-merged}"; }
cpath() { printf '/api/feature-board/tickets/T-%s/approval-requests/%s/close' "$1" "$2"; }
nclose() { # nclose <pr> <rid> — close POSTs the fake board saw for that request.
  if [ -r "$FB/requests.jsonl" ]; then jq -s --arg p "$(cpath "$1" "$2")" '[.[] | select(.path == $p and .method == "POST")] | length' "$FB/requests.jsonl"; else echo 0; fi
}
nanyclose() {
  if [ -r "$FB/requests.jsonl" ]; then jq -s --arg p "/api/feature-board/tickets/T-$1/" '[.[] | select((.path | startswith($p)) and (.path | endswith("/close")))] | length' "$FB/requests.jsonl"; else echo 0; fi
}
lastreq() { jq -s -c --arg p "$(cpath "$1" "$2")" '[.[] | select(.path == $p)] | last' "$FB/requests.jsonl"; }
puts() { # puts <key> [status] — ledger PUTs recorded for that key (and status).
  if [ -r "$ROWS/puts.jsonl" ]; then jq -s --arg k "$1" --arg s "${2:-}" '[.[] | select(.key == $k and ($s == "" or .status == $s) and (.failed | not))] | length' "$ROWS/puts.jsonl"; else echo 0; fi
}
lastput() { jq -s -c --arg k "$1" '[.[] | select(.key == $k)] | last' "$ROWS/puts.jsonl" 2>/dev/null; }
alerts() { local c; c=$(grep -c -- "$1" "$H/logs/ALERTS.log" 2>/dev/null); echo "${c:-0}"; }
logc() { local c; c=$(grep -c -- "$1" "$H/logs/client-approval.log" 2>/dev/null); echo "${c:-0}"; }
on
script other 200 '{"ok":true}'

# ── C1: merged -> one POST to the request's close path ──────────────────────
mark 501 "$(hx 501)" done r-1
eq "C1 rc" "$(closeom 501 merged)" rc=0
eq "C1 one close POST" "$(nclose 501 r-1)" 1
r=$(lastreq 501 r-1)
eq "C1 body" "$(printf '%s' "$r" | jq -c '[.body.reason, .body.prNumber, .body.headSha]')" "[\"merged\",501,\"$(hx 501)\"]"
eq "C1 idempotency key" "$(printf '%s' "$r" | jq -r '.headers["idempotency-key"]')" "client-approval-close:project-3:501:r-1"
eq "C1 bearer token" "$(printf '%s' "$r" | jq -r '.headers.authorization_ok')" true
eq "C1 marker close" "$(mf 501 "$(hx 501)" '.close + " " + .close_reason')" "closed merged"
[[ "$(mf 501 "$(hx 501)" .closed_at)" =~ ^[0-9]+$ ]] && ok || bad "C1 closed_at is an epoch"
eq "C1 closed log" "$(logc "closed example-org/project-3#501 request=r-1 (merged, HTTP 200)")" 1
eq "C1 one hub PUT closed" "$(puts example-org/project-3#501 closed)" 1
p=$(lastput example-org/project-3#501)
eq "C1 hub detail close fields" "$(printf '%s' "$p" | jq -r '.detail | fromjson | [.close_reason, (.closed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")), .request_id] | @tsv')" "merged	true	r-1"
eq "C1 hub marker" "$(mf 501 "$(hx 501)" .hub)" written

# ── I1: a second run after closed sends nothing ─────────────────────────────
closeom 501 merged >/dev/null
eq "I1 still one POST" "$(nclose 501 r-1)" 1
eq "I1 still one PUT" "$(puts example-org/project-3#501 closed)" 1

# ── C2: closed -> reason closed ─────────────────────────────────────────────
mark 502 "$(hx 502)" sent r-2
closeom 502 closed >/dev/null
eq "C2 reason closed" "$(lastreq 502 r-2 | jq -r .body.reason)" closed
eq "C2 marker" "$(mf 502 "$(hx 502)" '.close + " " + .close_reason')" "closed closed"

# ── C3-C9: the answer table ─────────────────────────────────────────────────
script other 409 '{"error":"already closed"}'
mark 503 "$(hx 503)" done r-3; closeom 503 >/dev/null
eq "C3 409 is closed" "$(mf 503 "$(hx 503)" .close)" closed
noscript other
mark 504 "$(hx 504)" done r-4; closeom 504 >/dev/null
eq "C4 404 is gone" "$(mf 504 "$(hx 504)" '.close + " " + .close_reason')" "gone gone"
eq "C4 no ALERTS" "$(alerts T-504)" 0
eq "C4 hub closed (gone)" "$(lastput example-org/project-3#504 | jq -r '.status + " " + (.detail | fromjson | .close_reason)')" "closed gone"
n=505
for c in "000" 400 401 403 500 502 405; do
  if [ "$c" = 000 ]; then printf '1' > "$ROWS/client_approval_board.timeout_s"; script other "200 3" '{}'
  else script other "$c" '{"error":"x"}'; fi
  mark $n "$(hx $n)" done "r-$n"
  closeom $n >/dev/null
  eq "C$n $c is failed: no close" "$(mf $n "$(hx $n)" '.close // "absent"')" absent
  eq "C$n $c attempts 1" "$(mf $n "$(hx $n)" .close_attempts)" 1
  eq "C$n $c last http" "$(mf $n "$(hx $n)" .close_last_http)" "$c"
  eq "C$n $c no closed log" "$(logc "closed example-org/project-3#$n ")" 0
  eq "C$n $c no hub PUT" "$(puts "example-org/project-3#$n")" 0
  rm -f "$ROWS/client_approval_board.timeout_s"
  n=$((n + 1))
done
script other 200 'not json'
mark 520 "$(hx 520)" done r-20; closeom 520 >/dev/null
eq "C5b a non-JSON 200 is still closed" "$(mf 520 "$(hx 520)" .close)" closed
script other 200 '{"ok":true}'

# ── C10: two heads -> one POST to the newer request; the older superseded ───
mark 530 "$(hx 530)" done r-old 1795000000
mark 530 "$(hb 530)" done r-new 1795000100
closeom 530 >/dev/null
eq "C10 newer closed" "$(nclose 530 r-new)" 1
eq "C10 older not called" "$(nclose 530 r-old)" 0
eq "C10 older superseded" "$(mf 530 "$(hx 530)" .close)" superseded
eq "C10 newer closed marker" "$(mf 530 "$(hb 530)" .close)" closed
# ── C11: no request id -> no-id, no POST ────────────────────────────────────
mark 531 "$(hx 531)" done null
closeom 531 >/dev/null
eq "C11 no POST" "$(nanyclose 531)" 0
eq "C11 no-id" "$(mf 531 "$(hx 531)" .close)" no-id
eq "C11 one log line" "$(logc "#531.*no request id")" 1
# ── C12: equal checked_at -> the file-name order decides ────────────────────
mark 532 "$(hx 532)" done r-a 1795000000
mark 532 "$(hb 532)" done r-b 1795000000
closeom 532 >/dev/null
eq "C12 the later file name is closed" "$(nclose 532 r-b)" 1
eq "C12 the earlier is superseded" "$(mf 532 "$(hx 532)" .close)" superseded
# ── C13: markers of a PR number that is a prefix (53 vs 530) are not read ──
mark 53 "$(hx 53)" done r-53
closeom 53 >/dev/null
eq "C13 PR 53 closes only its own request" "$(nclose 53 r-53)" 1
eq "C13 PR 530 untouched" "$(nclose 530 r-new)" 1

# ── A1: the cap and its ONE ALERTS line ─────────────────────────────────────
# A wrapper records the alert-line argv (the --id is not in ALERTS.log), then
# runs the real bin/alert-line.sh.
mv "$H/bin/alert-line.sh" "$H/bin/alert-line.real.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alert-argv.txt"\nexec "%s/bin/alert-line.real.sh" "$@"\n' "$T" "$H" > "$H/bin/alert-line.sh"
chmod +x "$H/bin/alert-line.sh"
script other 500 boom
mark 540 "$(hx 540)" done r-40abcdefghijklmnop
for i in 1 2 3 4 5; do closeom 540 >/dev/null; done
eq "A1 five POSTs" "$(nclose 540 r-40abcdefghijklmnop)" 5
eq "A1 cap-spent" "$(mf 540 "$(hx 540)" .close)" cap-spent
eq "A1 one ALERTS line" "$(alerts 'client-approval: the project-3 board did not close the approval request r-40abcdefghijklmnop of ticket T-540')" 1
grep -q -- '--id client-approval-close-project-3-540-r-40abcdefgh --project project-3' "$T/alert-argv.txt" && ok || bad "A1 the alert id carries the request id, 12 chars ($(cat "$T/alert-argv.txt" 2>/dev/null))"
closeom 540 >/dev/null
eq "A1 a 6th run: no POST" "$(nclose 540 r-40abcdefghijklmnop)" 5
eq "A1 a 6th run: no new line" "$(alerts 'ticket T-540')" 1
eq "A1 no hub PUT" "$(puts example-org/project-3#540)" 0
# ── A2: 404s alert nothing ──────────────────────────────────────────────────
noscript other
mark 541 "$(hx 541)" done r-41
for i in 1 2 3; do closeom 541 >/dev/null; done
eq "A2 one POST (gone is terminal)" "$(nclose 541 r-41)" 1
eq "A2 no ALERTS" "$(alerts T-541)" 0
eq "A2 one log line" "$(logc '#541.*(404)')" 1
script other 200 '{"ok":true}'

# ── X1-X8: exit paths ───────────────────────────────────────────────────────
mark 550 "$(hx 550)" done r-50
eq "X1 bad pr rc 2" "$(close project-3 example-org/project-3 5x merged)" rc=2
eq "X1 bad state rc 2" "$(close project-3 example-org/project-3 550 open)" rc=2
eq "X1 unknown project rc 2" "$(close nope example-org/project-3 550 merged)" rc=2
eq "X1 repo not the project's rc 2" "$(close project-3 example-org/other 550 merged)" rc=2
eq "X1 no POST" "$(nclose 550 r-50)" 0
eq "X1 no counter" "$(mf 550 "$(hx 550)" '.close_attempts // 0')" 0
exec 8>"$H/locks/client-approval-project-3-550.lock"; flock -n 8
eq "X2 lock held rc 0" "$(closeom 550)" rc=0
eq "X2 no POST" "$(nclose 550 r-50)" 0
exec 8>&-
printf 'off' > "$ROWS/$SW"
eq "X3 switch off rc 0" "$(closeom 550)" rc=0
eq "X3 switch off: no POST" "$(nclose 550 r-50)" 0
eq "X3 switch off: no PUT" "$(puts example-org/project-3#550)" 0
eq "X3 switch off: marker unchanged" "$(mf 550 "$(hx 550)" '.close // "absent"')" absent
on
eq "X4 no candidate rc 0" "$(closeom 559)" rc=0
mark 551 "$(hx 551)" done r-51 1795000000 . nobase
printf 'on' > "$ROWS/client_approval_board.example-org.nobase"
eq "X5 config missing rc 0" "$(close nobase example-org/nobase 551 merged)" rc=0
eq "X5 a failed attempt" "$(mf 551 "$(hx 551)" '(.close_attempts | tostring) + " " + .close_last_http' nobase)" "1 config"
# X6: the hub PUT fails -> hub=pending; the next run retries the PUT only.
touch "$ROWS/putfail"
mark 552 "$(hx 552)" done r-52
closeom 552 >/dev/null
eq "X6 closed" "$(mf 552 "$(hx 552)" .close)" closed
eq "X6 hub pending" "$(mf 552 "$(hx 552)" '.hub + " " + (.hub_attempts | tostring)')" "pending 1"
rm -f "$ROWS/putfail"
closeom 552 >/dev/null
eq "X7 hub-only retry: no new POST" "$(nclose 552 r-52)" 1
eq "X7 hub written" "$(mf 552 "$(hx 552)" .hub)" written
eq "X7 one good PUT closed" "$(puts example-org/project-3#552 closed)" 1
# X8: the hub cap
touch "$ROWS/putfail"; printf '2' > "$ROWS/client_approval_board.retry_max"
mark 553 "$(hx 553)" done r-53b
closeom 553 >/dev/null; closeom 553 >/dev/null; closeom 553 >/dev/null
eq "X8 hub cap-spent" "$(mf 553 "$(hx 553)" .hub)" cap-spent
eq "X8 one POST" "$(nclose 553 r-53b)" 1
eq "X8 one cap log line" "$(logc '#553.*hub ledger write failed 2 time')" 1
eq "X8 no ALERTS line" "$(alerts T-553)" 0
rm -f "$ROWS/putfail" "$ROWS/client_approval_board.retry_max"

# ── W1-W5: the request script writes the hub `waiting` row ──────────────────
rec() { local d="$T/rec-$1"; mkdir -p "$d"; printf '{"ticket_id":"T-%s"}\n' "$1" > "$d/job.json"; printf '%s' "$d"; }
runreq() { ( cd "$T" && HARNESS="$H" ROWS="$ROWS" bash "$H/bin/client-approval-request.sh" project-3 example-org/project-3 "$1" "$(hx "$1")" "$(rec "$1")" "app/x.tsx" >>"$T/run.out" 2>&1 ); echo "rc=$?"; }
nreq() { jq -s --arg p "/api/feature-board/tickets/T-$1/$2" '[.[] | select(.path == $p)] | length' "$FB/requests.jsonl"; }
script request 201 '{"id":"rq-560","approvers":[]}'; script comment 201 '{"id":"c1"}'
eq "W1 rc" "$(runreq 560)" rc=0
eq "W1 one waiting PUT" "$(puts example-org/project-3#560 waiting)" 1
d=$(lastput example-org/project-3#560 | jq -c '.detail | fromjson')
eq "W1 detail" "$(printf '%s' "$d" | jq -r '[.v, .project, .ticket_id, .ticket_url, .request_id, .head, (.requested_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")), .closed_at, .close_reason] | map(tostring) | join(" ")')" \
  "1 project-3 T-560 https://os.project-3.example/feature-board?ticket=T-560 rq-560 $(hx 560) true null null"
eq "W1 marker hub written" "$(mf 560 "$(hx 560)" '.hub + " " + .status')" "written done"
# W2: a failed PUT -> pending, the comment still posted once
script request 201 '{"id":"rq-561"}'
touch "$ROWS/putfail"
runreq 561 >/dev/null
eq "W2 hub pending" "$(mf 561 "$(hx 561)" '.hub + " " + (.hub_attempts | tostring)')" "pending 1"
eq "W2 comment posted" "$(nreq 561 comments)" 1
eq "W2 status done" "$(mf 561 "$(hx 561)" .status)" done
# W3: the next run retries the PUT only
rm -f "$ROWS/putfail"
runreq 561 >/dev/null
eq "W3 hub written" "$(mf 561 "$(hx 561)" .hub)" written
eq "W3 no new POST" "$(nreq 561 approval-requests)" 1
eq "W3 no new comment" "$(nreq 561 comments)" 1
eq "W3 one good waiting PUT" "$(puts example-org/project-3#561 waiting)" 1
runreq 561 >/dev/null
eq "W3 settled after written: no PUT" "$(puts example-org/project-3#561 waiting)" 1
# W4: the hub cap
script request 201 '{"id":"rq-562"}'
touch "$ROWS/putfail"; printf '2' > "$ROWS/client_approval_board.retry_max"
runreq 562 >/dev/null; runreq 562 >/dev/null; runreq 562 >/dev/null
eq "W4 hub cap-spent" "$(mf 562 "$(hx 562)" .hub)" cap-spent
eq "W4 one POST" "$(nreq 562 approval-requests)" 1
eq "W4 one comment" "$(nreq 562 comments)" 1
rm -f "$ROWS/putfail" "$ROWS/client_approval_board.retry_max"
# W5: switch off -> no PUT
printf 'off' > "$ROWS/$SW"
runreq 563 >/dev/null
eq "W5 switch off: no PUT" "$(puts example-org/project-3#563)" 0
on
# W6: no jobs client -> no hub field (C0 behaviour kept)
mv "$H/bin/jobs-client.sh" "$T/jc.sh"
cat > "$H/bin/jobs-client.sh" <<'SH'
setting_get() { [ -r "$ROWS/$1" ] || return 2; cat "$ROWS/$1"; }
SH
script request 201 '{"id":"rq-564"}'
runreq 564 >/dev/null
eq "W6 no jobs client: done, no hub field" "$(mf 564 "$(hx 564)" '.status + " " + (.hub // "absent")')" "done absent"
mv -f "$T/jc.sh" "$H/bin/jobs-client.sh"

# ── U1-U6: lib units ────────────────────────────────────────────────────────
lib() { HARNESS="$H" ROWS="$ROWS" bash -c '. "$HARNESS/bin/lib/client-approval.sh"; "$@"' _ "$@"; }
eq "U1 project-3 ticket url" "$(lib ca_ticket_url project-3 T-1)" "https://os.project-3.example/feature-board?ticket=T-1"
eq "U2 /api/board -> /board, trailing slash" "$(lib ca_ticket_url apib 7)" "https://ab.example/board?ticket=7"
eq "U3 prefix - -> empty" "$(lib ca_ticket_url ghp 7)" ""
eq "U4 prod not https -> empty" "$(lib ca_ticket_url plain 7)" ""
eq "U5 id url-encoded" "$(lib ca_ticket_url project-3 'a b&c')" "https://os.project-3.example/feature-board?ticket=a%20b%26c"
mark 570 "$(hx 570)" done r-70 1795000000 '.hub = "pending"'
lib ca_mark_settled "$(mk 570 "$(hx 570)")"; eq "U6 done + hub pending is not settled" "$?" 1
mark 571 "$(hx 571)" done r-71 1795000000 '.hub = "written"'
lib ca_mark_settled "$(mk 571 "$(hx 571)")"; eq "U6 done + hub written is settled" "$?" 0
mark 572 "$(hx 572)" done r-72
lib ca_mark_settled "$(mk 572 "$(hx 572)")"; eq "U6 a C0 done marker (no hub) is settled" "$?" 0

# ── RT1: the ledger body the box sends is the committed fixture ─────────────
mark 501 "$(hx 501)" done r-1
rm -f "$ROWS/puts.jsonl"
HARNESS="$H" ROWS="$ROWS" bash -c '. "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/client-approval.sh"; ca_hub_put project-3 example-org/project-3 501 waiting "$(cat "$1")"' _ "$(mk 501 "$(hx 501)")"
eq "RT1 rc" "$?" 0
eq "RT1 the PUT equals the fixture" "$(lastput example-org/project-3#501 | jq -c '{kind,key,status,detail}')" "$(jq -c '{kind,key,status,detail}' "$DIR/tests/fixtures/client-approval/ledger-row.bh-9901.json")"
rc3=$(HARNESS="$H" bash -c '. "$HARNESS/bin/lib/client-approval.sh"; ca_hub_put project-3 example-org/project-3 501 waiting "{}"; echo $?')
eq "RT1 no jobs client: rc 3" "$rc3" 3

# ── RT2: the new marker fields round-trip through every reader ──────────────
mark 580 "$(hx 580)" done r-80 1795000000 '.hub = "pending" | .hub_attempts = 2 | .close = "closed" | .close_attempts = 1 | .close_reason = "merged" | .closed_at = 1795000500'
m=$(lib ca_mark_read "$(mk 580 "$(hx 580)")")
eq "RT2 ca_mark_read keeps the fields" "$(printf '%s' "$m" | jq -c '[.hub,.hub_attempts,.close,.close_attempts,.close_reason,.closed_at]')" '["pending",2,"closed",1,"merged",1795000500]'
grep -qx 580 <<<"$(lib ca_close_candidates project-3)" && ok || bad "RT2 closed + hub pending is a close candidate"
grep -qx 501 <<<"$(lib ca_close_candidates project-3)" && ok || bad "RT2 an open request is a close candidate"
grep -qx 552 <<<"$(lib ca_close_candidates project-3)" && bad "RT2 closed + hub written is not a candidate" || ok
grep -qx 531 <<<"$(lib ca_close_candidates project-3)" && bad "RT2 no-id is not a candidate" || ok
grep -qx 540 <<<"$(lib ca_close_candidates project-3)" && bad "RT2 cap-spent is not a candidate" || ok
eq "RT2 candidates print each PR once" "$(lib ca_close_candidates project-3 | sort | uniq -d | wc -l | tr -d ' ')" 0
d=$(lib ca_hub_detail project-3 "$m")
eq "RT2 detail closed_at ISO" "$(printf '%s' "$d" | jq -r '.closed_at + " " + .close_reason')" "2026-11-18T11:15:00Z merged"

# ── D1: the knob fallback equals the seed ───────────────────────────────────
SEED=$(ls "$DIR"/worker/jobs/schema.d/*-bh-9901-client-approval-close-seed.sql 2>/dev/null | head -1)
[ -n "$SEED" ] && ok || bad "D1 the seed fragment exists"
code=$(HARNESS="$H" bash -c '. "$HARNESS/bin/lib/client-approval.sh"; printf "%s" "${CA_CLOSE_MAX_PER_TICK_DEFAULT:-}"')
seed=$(grep -o "('client_approval_board\.close_max_per_tick','[0-9]*'" "${SEED:-/dev/null}" | sed -E "s/.*','([0-9]+)'/\1/")
eq "D1 close_max_per_tick fallback = seed" "$code" "${seed:-none}"

# ── B1: nothing leaves the box; no token in a log ───────────────────────────
eq "B1 the board base is 127.0.0.1" "$(grep -c "$BASE" "$H/env/project-3.env")" 1
eq "B1 every close request is on the fake board" "$(jq -s '[.[] | select(.path | endswith("/close"))] | length > 0' "$FB/requests.jsonl" 2>/dev/null)" true
leak=$(grep -rlF "$TOKEN" "$H/logs" "$H/state" "$T/run.out" "$FB/requests.jsonl" "$ROWS/puts.jsonl" 2>/dev/null | head -3)
[ -z "$leak" ] && ok || bad "B1 the token is in: $leak"

echo "client-approval-close.bh-9901-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
