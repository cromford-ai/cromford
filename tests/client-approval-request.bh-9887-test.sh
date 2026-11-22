#!/bin/bash
# tests/client-approval-request.bh-9887-test.sh — BH-9887 slice C0:
# bin/client-approval-request.sh against a fake board
# (tests/fixtures/client-approval/fake-board.py on 127.0.0.1). The real script,
# the real bin/lib/client-approval.sh, tracker.sh, board.sh, fleet-conf.sh,
# internal-token-for.sh and alert-line.sh run in a scratch tree; setting_get is
# a stub jobs client that reads $ROWS/<key>. No call leaves the box.
#
#   S1-S9   the switch: only `on` (trim + lowercase) is on; off = 0 requests
#   R1-R9   answer classes: 201, 409, 404, timeout, 401, 500, non-JSON 200,
#           a bad request id, no approvers
#   RT1     marker round-trip; RT2 the request body names and types
#   P1-P3   paths parsing        J1 the reason has no internal jargon
#   I1-I2   idempotent per head; a new head asks again
#   A1-A2   the retry cap and its ONE ALERTS line; a 404 board alerts nothing
#   X1-X7   exit paths: bad args, lock held, switch off, no ticket, not board,
#           no base/token, terminal marker
#   C1-C5   the comment: once, names, no names, escaping, comment cap
#   N10     no client text carries internal words
#   B1      every request is on the fake board; no token in any log
#   D1      code fallbacks equal the seed SQL values
#   PR1     prune: 91-day marker deleted, 89-day kept
#   K1-K3   the payload caps are knobs: approvers_max, approver_name_max,
#           summary_max_chars each change what the board and the client get
#   K4      no harness root: no marker path, nothing written under /
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/client-approval-request.bh-9887-test.sh
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
TOKEN=tok-fake-board-9887
export FLEET_CONF="$H/fleet.conf"
mkdir -p "$H/bin/lib" "$H/env" "$H/logs" "$H/state" "$H/locks" "$ROWS" "$FB"
cat > "$H/bin/jobs-client.sh" <<'SH'
# stub jobs client: setting_get <key> -> $ROWS/<key>; rc 2 no row, rc 1 worker down
setting_get() {
  printf '%s\n' "$1" >> "$ROWS/calls"
  [ -e "$ROWS/down" ] && return 1
  [ -r "$ROWS/$1" ] || return 2
  cat "$ROWS/$1"
}
SH
for f in bin/client-approval-request.sh bin/fleet-conf.sh bin/internal-token-for.sh bin/lib/tracker.sh bin/alert-line.sh bin/lib/release-model.sh; do
  scratch_install_closure "$f" "$H" >/dev/null || { echo "FAIL: closure of $f"; exit 1; }
done
[ -r "$H/bin/lib/client-approval.sh" ] || { echo "FAIL: closure did not install bin/lib/client-approval.sh"; exit 1; }
[ -r "$H/bin/lib/tracker/board.sh" ] || { echo "FAIL: closure did not install bin/lib/tracker/board.sh"; exit 1; }
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
project-3  example-org/project-3  https://om.example  /api/feature-board  6 box-1 192.0.2.1
nobase   example-org/nobase   https://nb.example  /api/feature-board  7 box-1 192.0.2.1
ghp      example-org/ghp      https://gh.example  -                   8 box-1 192.0.2.1
CONF
printf 'PROJECT_3_OS_API_BASE=%s/\nproject-3_OS_INTERNAL_API_TOKEN=%s\n' "$BASE" "$TOKEN" > "$H/env/project-3.env"
printf 'NOBASE_INTERNAL_API_TOKEN=%s\n' "$TOKEN" > "$H/env/nobase.env"
SW=client_approval_board.example-org.project-3
on() { printf 'on' > "$ROWS/$SW"; }

hx() { printf '%040x' "$1"; }  # a unique 40-hex head per number
rec() { # rec <pr> [what-lines] — a build record with ticket tk_<pr>
  local d="$T/rec-$1"; mkdir -p "$d"
  printf '{"ticket_id":"tk_%s","key":"TK-%s"}\n' "$1" "$1" > "$d/job.json"
  [ -n "${2:-}" ] && printf '%s\n' "$2" > "$d/what.txt"
  printf '%s' "$d"
}
script() { mkdir -p "$FB/script"; printf '%s\n%s' "$2" "${3:-}" > "$FB/script/$1"; }
noscript() { rm -f "$FB/script/$1"; }
# run <project> <slug> <pr> <head> <rec> [paths] — the real script; prints rc.
run() {
  ( cd "$T" && HARNESS="$H" ROWS="$ROWS" bash "$H/bin/client-approval-request.sh" "$@" >>"$T/run.out" 2>&1 ); echo "rc=$?"
}
runom() { run project-3 example-org/project-3 "$1" "${2:-$(hx "$1")}" "${3:-$(rec "$1")}" "${4:-app/members/page.tsx, lib/mail/send.ts}"; }
# nreq <route> <ticket> — requests the fake board saw for that ticket and route.
nreq() {
  local sfx; [ "$1" = request ] && sfx=approval-requests || sfx=comments
  if [ -r "$FB/requests.jsonl" ]; then
    jq -s --arg p "/api/feature-board/tickets/$2/$sfx" '[.[] | select(.path == $p)] | length' "$FB/requests.jsonl"
  else echo 0; fi
}
lastbody() { jq -s -c --arg p "/api/feature-board/tickets/$2/$1" '[.[] | select(.path == $p)] | last | .body' "$FB/requests.jsonl"; }
lasthdr() { jq -s -r --arg p "/api/feature-board/tickets/$2/approval-requests" --arg h "$3" '[.[] | select(.path == $p)] | last | .headers[$h] | tostring' "$FB/requests.jsonl"; }
mk() { printf '%s/state/client-approval/%s/%s-%s.json' "$H" "${3:-project-3}" "$1" "$2"; }
mf() { jq -r "$3" "$(mk "$1" "$2")" 2>/dev/null; }
alerts() { local c; c=$(grep -c -- "$1" "$H/logs/ALERTS.log" 2>/dev/null); echo "${c:-0}"; }
logc() { local c; c=$(grep -c -- "$1" "$H/logs/client-approval.log" 2>/dev/null); echo "${c:-0}"; }
OKBODY='{"id":"req_1","approvers":[{"name":"Dana"}]}'
on
script request 201 "$OKBODY"; script comment 201 '{"id":"c1"}'

# ── S1-S9: the switch ───────────────────────────────────────────────────────
pr=100
for v in "" off true 1 'on;' onn ' ' '-' DOWN; do
  pr=$((pr + 1))
  rm -f "$ROWS/$SW" "$ROWS/down"
  case "$v" in '') ;; DOWN) printf 'on' > "$ROWS/$SW"; touch "$ROWS/down" ;; *) printf '%s' "$v" > "$ROWS/$SW" ;; esac
  eq "S($v) rc" "$(runom $pr)" rc=0
  eq "S($v) no request" "$(nreq request tk_$pr)" 0
  [ -e "$(mk $pr "$(hx $pr)")" ] && bad "S($v): no marker when off" || ok
done
rm -f "$ROWS/down"
printf ' ON \n' > "$ROWS/$SW"
eq "S-on trimmed rc" "$(runom 110)" rc=0
eq "S-on ' ON ' is on" "$(nreq request tk_110)" 1
grep -q 'switch unreadable for example-org/project-3' "$H/logs/client-approval.log" && ok || bad "S(DOWN): an unreadable switch is logged"
grep -qx 'client_approval_board' "$ROWS/calls" && bad "S: the global key alone is read" || ok
on

# ── R1: 201 ─────────────────────────────────────────────────────────────────
script request 201 "$OKBODY"
eq "R1 rc" "$(runom 1)" rc=0
eq "R1 one POST" "$(nreq request tk_1)" 1
eq "R1 status done" "$(mf 1 "$(hx 1)" .status)" done
eq "R1 request id" "$(mf 1 "$(hx 1)" .request_id)" req_1
eq "R1 approvers" "$(jq -c .approvers "$(mk 1 "$(hx 1)")")" '["Dana"]'
eq "R1 one comment" "$(nreq comment tk_1)" 1
eq "R1 idempotency key" "$(lasthdr x tk_1 idempotency-key)" "client-approval:project-3:1:$(hx 1)"
eq "R1 token sent" "$(lasthdr x tk_1 authorization_ok)" true
eq "R1 requested log" "$(logc "requested example-org/project-3#1@$(hx 1 | cut -c1-8) request=req_1 approvers=1")" 1
eq "R1 commented log" "$(logc "commented example-org/project-3#1@")" 1

# ── R2: 409 = already held ─────────────────────────────────────────────────
script request 409 '{"error":"exists"}'
runom 2 >/dev/null
eq "R2 409 is sent -> done" "$(mf 2 "$(hx 2)" .status)" done
eq "R2 request_id null" "$(mf 2 "$(hx 2)" .request_id)" null
eq "R2 comment posted" "$(nreq comment tk_2)" 1

# ── R3: 404 ─────────────────────────────────────────────────────────────────
noscript request
runom 3 >/dev/null
eq "R3 absent-route" "$(mf 3 "$(hx 3)" .status)" absent-route
eq "R3 attempts unchanged" "$(mf 3 "$(hx 3)" .attempts)" 0
eq "R3 no comment" "$(nreq comment tk_3)" 0
eq "R3 one log line" "$(logc "#3@.*board has no approval-requests route (404); today's behaviour kept")" 1

# ── R4: timeout (000) ───────────────────────────────────────────────────────
printf '1' > "$ROWS/client_approval_board.timeout_s"
script request "201 3" "$OKBODY"
runom 4 >/dev/null
eq "R4 timeout is failed" "$(mf 4 "$(hx 4)" .status)" failed
eq "R4 last_http 000" "$(mf 4 "$(hx 4)" .last_http)" 000
eq "R4 attempts 1" "$(mf 4 "$(hx 4)" .attempts)" 1
eq "R4 no comment" "$(nreq comment tk_4)" 0
rm -f "$ROWS/client_approval_board.timeout_s"

# ── R5-R7: 401, 500, non-JSON 200 ───────────────────────────────────────────
n=5
for c in "401|{\"error\":\"no\"}" "500|oops" "200|<html>ok</html>"; do
  script request "${c%%|*}" "${c#*|}"
  runom $n >/dev/null
  eq "R$n ${c%%|*} is failed" "$(mf $n "$(hx $n)" .status)" failed
  eq "R$n no comment" "$(nreq comment tk_$n)" 0
  eq "R$n no requested log" "$(logc "requested example-org/project-3#$n@")" 0
  n=$((n + 1))
done
script request 200 '"just a string"'
runom 30 >/dev/null
eq "R7b a 2xx that is not an object is failed" "$(mf 30 "$(hx 30)" .status)" failed

# ── R8: a bad request id; R9: no approvers ──────────────────────────────────
script request 201 '{"id":"bad id/../x","approvers":[{"name":"Dana"}]}'
runom 8 >/dev/null
eq "R8 sent with request_id null" "$(mf 8 "$(hx 8)" .request_id)" null
eq "R8 done" "$(mf 8 "$(hx 8)" .status)" done
eq "R8 log names no id" "$(logc '#8@.*no usable request id')" 1
script request 201 '{"request":{"id":"req_9"}}'
runom 9 >/dev/null
eq "R9 request.id read" "$(mf 9 "$(hx 9)" .request_id)" req_9
eq "R9 no approvers" "$(jq -c .approvers "$(mk 9 "$(hx 9)")")" '[]'
grep -q 'Someone on your team with approval rights can approve it.' <<<"$(lastbody comments tk_9)" && ok || bad "R9/C3 no names: the generic sentence ($(lastbody comments tk_9))"

# ── RT1: marker round-trip ──────────────────────────────────────────────────
m=$(jq -c . "$(mk 1 "$(hx 1)")")
for k in v project repo pr head ticket_id status attempts last_http checked_at request_id approvers comment comment_attempts updated_at; do
  printf '%s' "$m" | jq -e --arg k "$k" 'has($k)' >/dev/null && ok || bad "RT1 marker has $k ($m)"
done
eq "RT1 fields" "$(printf '%s' "$m" | jq -c '[.v,.project,.repo,.pr,.head,.ticket_id,.comment,.comment_attempts]')" "[1,\"project-3\",\"example-org/project-3\",1,\"$(hx 1)\",\"tk_1\",\"posted\",0]"
eq "RT1 ca_mark_read reads it" "$(HARNESS="$H" bash -c '. "$HARNESS/bin/lib/client-approval.sh"; ca_mark_read "$1" | jq -r .request_id' _ "$(mk 1 "$(hx 1)")")" req_1

# ── RT2 / P1-P3 / J1: the request body ──────────────────────────────────────
script request 201 "$OKBODY"
SEVEN="a/1.tsx, a/2.tsx, a/3.tsx, a/4.tsx, a/5.tsx, +2 more"
runom 11 "" "$(rec 11 'TK-11: New member banner
Member list shows the joined date & plan')" "$SEVEN" >/dev/null
b=$(lastbody approval-requests tk_11)
eq "RT2 keys" "$(printf '%s' "$b" | jq -c 'keys')" '["headSha","paths","prNumber","prUrl","previewUrl","reason","summary"]'
eq "RT2 types" "$(printf '%s' "$b" | jq -c '[(.prNumber|type),(.prUrl|type),(.headSha|length),(.reason|type),(.paths|type),(.summary|type),(.previewUrl|type)]')" '["number","string",40,"string","array","string","null"]'
eq "RT2 prUrl" "$(printf '%s' "$b" | jq -r .prUrl)" https://github.com/example-org/project-3/pull/11
eq "P1 the +N more item is dropped, 5 kept" "$(printf '%s' "$b" | jq -c .paths)" '["a/1.tsx","a/2.tsx","a/3.tsx","a/4.tsx","a/5.tsx"]'
eq "RT2 summary from what.txt, key stripped" "$(printf '%s' "$b" | jq -r .summary)" 'New member banner; Member list shows the joined date & plan'
cap() { HARNESS="$H" bash -c '. "$HARNESS/bin/lib/client-approval.sh"; ca_paths_json "$1"' _ "$1"; }
eq P2 "$(cap 'a, b')" '["a","b"]'
eq P3 "$(cap '')" '[]'
eq "J1 reason" "$(printf '%s' "$b" | jq -r .reason)" "This change touches parts of the app that members see: a/1.tsx, a/2.tsx, a/3.tsx, a/4.tsx, a/5.tsx. It needs approval before it goes live."
c11=$(lastbody comments tk_11 | jq -r .body)
grep -q '<li>Member list shows the joined date &amp; plan</li>' <<<"$c11" && ok || bad "C4 summary escaped in the comment ($c11)"
# previewUrl from the release model, only a real https base (D26).
printf 'project-3\tstaging\thttps://staging.om.example/\n' > "$T/release-model.tsv"
( cd "$T" && RELEASE_MODEL_FILE="$T/release-model.tsv" HARNESS="$H" ROWS="$ROWS" bash "$H/bin/client-approval-request.sh" project-3 example-org/project-3 12 "$(hx 12)" "$(rec 12)" "a/1.tsx" >>"$T/run.out" 2>&1 )
eq "RT2 previewUrl from the staging model" "$(lastbody approval-requests tk_12 | jq -r .previewUrl)" https://staging.om.example
grep -q 'You can try it here: <a href="https://staging.om.example">' <<<"$(lastbody comments tk_12 | jq -r .body)" && ok || bad "RT2 the comment links the preview"

# ── I1-I2: idempotency ──────────────────────────────────────────────────────
runom 13 >/dev/null; runom 13 >/dev/null
eq "I1 two runs, one POST" "$(nreq request tk_13)" 1
eq "I1 two runs, one comment" "$(nreq comment tk_13)" 1
HB13=$(printf 'b%039x' 13)
runom 13 "$HB13" "$T/rec-13" >/dev/null
eq "I2 a new head asks again" "$(nreq request tk_13)" 2
eq "I2 the new headSha" "$(lastbody approval-requests tk_13 | jq -r .headSha)" "$HB13"
eq "I2 a second comment" "$(nreq comment tk_13)" 2

# ── A1: the retry cap ───────────────────────────────────────────────────────
script request 500 'boom'
for i in 1 2 3 4 5; do runom 14 >/dev/null; done
eq "A1 five POSTs" "$(nreq request tk_14)" 5
eq "A1 cap-spent" "$(mf 14 "$(hx 14)" .status)" cap-spent
eq "A1 one ALERTS line" "$(alerts 'client-approval: the project-3 board did not take the approval request for ticket tk_14, PR https://github.com/example-org/project-3/pull/14')" 1
runom 14 >/dev/null
eq "A1 a 6th run: no POST" "$(nreq request tk_14)" 5
eq "A1 a 6th run: no new line" "$(alerts 'ticket tk_14')" 1
eq "A1 no comment" "$(nreq comment tk_14)" 0
# The cap is the retry_max row.
printf '2' > "$ROWS/client_approval_board.retry_max"
runom 15 >/dev/null; runom 15 >/dev/null
eq "A1b retry_max row 2: cap after 2" "$(mf 15 "$(hx 15)" .status)" cap-spent
rm -f "$ROWS/client_approval_board.retry_max"

# ── A2: a 404 board ─────────────────────────────────────────────────────────
noscript request
for i in 1 2 3; do runom 16 >/dev/null; done
eq "A2 one POST inside the window" "$(nreq request tk_16)" 1
eq "A2 one log line" "$(logc '#16@.*(404)')" 1
eq "A2 no ALERTS line" "$(alerts 'tk_16')" 0
# Past the window (absent_recheck_s row 1, the marker 2 s old): one more POST, no new line.
printf '1' > "$ROWS/client_approval_board.absent_recheck_s"
jq -c '.checked_at -= 5' "$(mk 16 "$(hx 16)")" > "$T/m" && mv "$T/m" "$(mk 16 "$(hx 16)")"
runom 16 >/dev/null
eq "A2 past the window: one more POST" "$(nreq request tk_16)" 2
eq "A2 past the window: no new log line" "$(logc '#16@.*(404)')" 1
rm -f "$ROWS/client_approval_board.absent_recheck_s"
# ...and the board route ships: the waiting head gets its request.
script request 201 "$OKBODY"
jq -c '.checked_at -= 7200' "$(mk 16 "$(hx 16)")" > "$T/m" && mv "$T/m" "$(mk 16 "$(hx 16)")"
runom 16 >/dev/null
eq "A2 the route ships: done" "$(mf 16 "$(hx 16)" .status)" done

# ── X1-X7: exit paths ───────────────────────────────────────────────────────
eq "X1 bad pr rc 2" "$(run project-3 example-org/project-3 1x "$(hx 1)" -)" rc=2
eq "X1 bad head rc 2" "$(run project-3 example-org/project-3 17 abc -)" rc=2
eq "X1 unknown project rc 2" "$(run nope example-org/project-3 17 "$(hx 17)" -)" rc=2
eq "X1 repo not the project's rc 2" "$(run project-3 example-org/other 17 "$(hx 17)" -)" rc=2
[ -e "$(mk 17 "$(hx 17)")" ] && bad "X1: bad args write no marker" || ok
exec 8>"$H/locks/client-approval-project-3-18.lock"; flock -n 8
eq "X2 lock held rc 0" "$(runom 18)" rc=0
eq "X2 lock held: no request" "$(nreq request tk_18)" 0
exec 8>&-
eq "X3 no ticket rc 0" "$(run project-3 example-org/project-3 19 "$(hx 19)" -)" rc=0
eq "X3 marker no-ticket" "$(mf 19 "$(hx 19)" .status)" no-ticket
printf 'on' > "$ROWS/client_approval_board.example-org.ghp"
eq "X4 not board rc 0" "$(run ghp example-org/ghp 20 "$(hx 20)" "$(rec 20)")" rc=0
eq "X4 marker not-board" "$(jq -r .status "$(mk 20 "$(hx 20)" ghp)")" not-board
eq "X4 no request" "$(nreq request tk_20)" 0
printf 'on' > "$ROWS/client_approval_board.example-org.nobase"
eq "X5 no base rc 0" "$(run nobase example-org/nobase 21 "$(hx 21)" "$(rec 21)")" rc=0
eq "X5 a failed attempt" "$(jq -r '.status + " " + .last_http' "$(mk 21 "$(hx 21)" nobase)")" "failed config"
eq "X7 terminal marker: no request" "$(runom 1 >/dev/null; nreq request tk_1)" 1

# ── C1-C5: the comment ──────────────────────────────────────────────────────
script request 201 '{"id":"r22","approvers":["Ann","Bo"]}'
runom 22 >/dev/null
grep -q 'Ann or Bo can approve it.' <<<"$(lastbody comments tk_22 | jq -r .body)" && ok || bad "C2 two names"
script request 201 '{"id":"r23","approvers":[{"name":"Ann"},{"name":"Bo"},{"name":" Cy "}]}'
runom 23 >/dev/null
c23=$(lastbody comments tk_23 | jq -r .body)
grep -q 'Ann, Bo or Cy can approve it.' <<<"$c23" && ok || bad "C2 three names ($c23)"
grep -q 'The Approve button is on this ticket.' <<<"$c23" && ok || bad "C1 the Approve button sentence"
grep -q 'goes live only after a named approval' <<<"$c23" && ok || bad "C1 waits for a named approval"
grep -q '<a href="https://github.com/example-org/project-3/pull/23">pull request #23</a>' <<<"$c23" && ok || bad "C1 the PR link"
grep -q 'Dana can approve it.' <<<"$(lastbody comments tk_1 | jq -r .body)" && ok || bad "C2 one name"
script request 201 '{"id":"r24","approvers":[{"name":"<b>x</b>"}]}'
runom 24 >/dev/null
c24=$(lastbody comments tk_24 | jq -r .body)
grep -qF '&lt;b&gt;x&lt;/b&gt; can approve it.' <<<"$c24" && ! grep -qF '<b>x' <<<"$c24" && ok || bad "C4 a name arrives escaped ($c24)"
script request 201 "$OKBODY"; script comment 500 'no'
for i in 1 2 3 4 5; do runom 25 >/dev/null; done
eq "C5 one request" "$(nreq request tk_25)" 1
eq "C5 five comment tries" "$(nreq comment tk_25)" 5
eq "C5 comment cap-spent" "$(mf 25 "$(hx 25)" .comment)" cap-spent
eq "C5 status done" "$(mf 25 "$(hx 25)" .status)" done
eq "C5 one ALERTS line" "$(alerts 'client-approval-comment\|the ticket comment failed 5 times')" 1
eq "C5 no commented log" "$(logc "commented example-org/project-3#25@")" 0
runom 25 >/dev/null
eq "C5 a 6th run: nothing" "$(nreq comment tk_25)" 5
script comment 201 '{"id":"c1"}'

# ── K1-K3: the payload caps are settings rows (BH-9887 fix round) ───────────
ELEVEN=$(jq -nc '{id:"r41", approvers:[range(1;12) | {name:"N\(.)"}]}')
script request 201 "$ELEVEN"
runom 41 >/dev/null
eq "K1 default approvers_max 10: 10 names kept" "$(mf 41 "$(hx 41)" '.approvers | length')" 10
grep -q 'N10 can approve it.' <<<"$(lastbody comments tk_41 | jq -r .body)" && ok || bad "K1 default: the 10th name ends the list"
printf '11' > "$ROWS/client_approval_board.approvers_max"
runom 42 >/dev/null
eq "K1 approvers_max row 11: 11 names kept" "$(mf 42 "$(hx 42)" '.approvers | length')" 11
grep -q 'N10 or N11 can approve it.' <<<"$(lastbody comments tk_42 | jq -r .body)" && ok || bad "K1 row 11: the 11th name is in the comment ($(lastbody comments tk_42 | jq -r .body))"
rm -f "$ROWS/client_approval_board.approvers_max"
LONG=$(printf 'A%.0s' $(seq 1 100))
script request 201 "$(jq -nc --arg n "$LONG" '{id:"r43", approvers:[{name:$n}]}')"
runom 43 >/dev/null
eq "K2 default approver_name_max 80" "$(mf 43 "$(hx 43)" '.approvers[0] | length')" 80
printf '90' > "$ROWS/client_approval_board.approver_name_max"
runom 44 >/dev/null
eq "K2 approver_name_max row 90" "$(mf 44 "$(hx 44)" '.approvers[0] | length')" 90
rm -f "$ROWS/client_approval_board.approver_name_max"
script request 201 "$OKBODY"
WHAT=$(printf 'B%.0s' $(seq 1 600))
runom 45 "" "$(rec 45 "TK-45: $WHAT")" >/dev/null
eq "K3 default summary_max_chars 500" "$(lastbody approval-requests tk_45 | jq -r '.summary | length')" 500
printf '550' > "$ROWS/client_approval_board.summary_max_chars"
runom 46 "" "$(rec 46 "TK-46: $WHAT")" >/dev/null
eq "K3 summary_max_chars row 550" "$(lastbody approval-requests tk_46 | jq -r '.summary | length')" 550
printf 'x' > "$ROWS/client_approval_board.summary_max_chars"
runom 47 "" "$(rec 47 "TK-47: $WHAT")" >/dev/null
eq "K3 a bad row falls back to 500" "$(lastbody approval-requests tk_47 | jq -r '.summary | length')" 500
rm -f "$ROWS/client_approval_board.summary_max_chars"

# ── K4: an empty harness root never builds a path under / ───────────────────
k4=$(HARNESS= MC_H= H= bash -c '. "$1"; ca_mark_file project-3 1 '"$(hx 1)"'; echo "rc=$?"' _ "$H/bin/lib/client-approval.sh")
eq "K4 ca_mark_file refuses an empty root" "$k4" "rc=1"

# ── N10: no internal words reach the client ─────────────────────────────────
all=$(jq -r 'select(.path | test("/(approval-requests|comments)$")) | .body | tostring' "$FB/requests.jsonl")
for w in 'moves forward on its own' lead_authority_mode verdict conductor 'protected path'; do
  grep -qiF -- "$w" <<<"$all" && bad "N10: '$w' reached the board" || ok
done

# ── B1: no call leaves the box; no token in a log ───────────────────────────
eq "B1 every request is on the fake board (base is 127.0.0.1)" "$(grep -c "$BASE" "$H/env/project-3.env")" 1
leak=$(grep -rlF "$TOKEN" "$H/logs" "$H/state" "$T/run.out" "$FB/requests.jsonl" 2>/dev/null | head -3)
[ -z "$leak" ] && ok || bad "B1 the token is in: $leak"

# ── D1: code fallbacks equal the seeds ──────────────────────────────────────
SEED=$(ls "$DIR"/worker/jobs/schema.d/*-bh-9887-client-approval-board-seed.sql 2>/dev/null | head -1)
[ -n "$SEED" ] && ok || bad "D1: the seed fragment exists"
for kv in retry_max:CA_RETRY_MAX_DEFAULT timeout_s:CA_TIMEOUT_S_DEFAULT absent_recheck_s:CA_ABSENT_RECHECK_S_DEFAULT marker_keep_d:CA_MARKER_KEEP_D_DEFAULT prune_max:CA_PRUNE_MAX_DEFAULT \
          summary_max_chars:CA_SUMMARY_MAX_CHARS_DEFAULT approver_name_max:CA_APPROVER_NAME_MAX_DEFAULT approvers_max:CA_APPROVERS_MAX_DEFAULT; do
  k=${kv%%:*}; v=${kv#*:}
  code=$(HARNESS="$H" bash -c '. "$HARNESS/bin/lib/client-approval.sh"; printf "%s" "${!1}"' _ "$v")
  seed=$(grep -o "('client_approval_board\.$k','[0-9]*'" "${SEED:-/dev/null}" | sed -E "s/.*','([0-9]+)'/\1/")
  eq "D1 $k code fallback = seed" "$code" "$seed"
done
grep -q "('client_approval_board.example-org.project-3','on'" "${SEED:-/dev/null}" && ok || bad "D1 project-3 seeded on"

# ── PR1: prune ──────────────────────────────────────────────────────────────
d="$H/state/client-approval/project-3"
cp "$(mk 1 "$(hx 1)")" "$d/old-91.json"; touch -d '91 days ago' "$d/old-91.json"
cp "$(mk 1 "$(hx 1)")" "$d/old-89.json"; touch -d '89 days ago' "$d/old-89.json"
runom 1 >/dev/null
[ ! -e "$d/old-91.json" ] && ok || bad "PR1 a 91-day marker is pruned"
[ -e "$d/old-89.json" ] && ok || bad "PR1 an 89-day marker is kept"
eq "PR1 one prune log line" "$(logc 'pruned 1 marker(s) of project-3 older than 90 days')" 1

echo "client-approval-request.bh-9887-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
