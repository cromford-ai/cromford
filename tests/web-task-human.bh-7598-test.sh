#!/bin/bash
# tests/web-task-human.bh-7598-test.sh — BH-7598 (slice C0): a person completes
# a 2FA step of a web-task run. wh_request_human (bin/lib/web-human.sh, with
# its seams bin/lib/web-human/telegram.sh and bin/lib/web-human/board.sh) is
# driven over real curl against the REAL jobs worker
# (tests/lib/web-vault-worker.bh-7595.mjs serves worker/jobs/src/index.js; the
# routes are worker/jobs/src/routes/web-task-human.js, their node suite is
# worker/jobs/test/web-task-human.bh-7598.test.js). Telegram and the 2FA
# fixture site are tests/lib/web-task-human-fakes.bh-7598.mjs; GitHub is a gh
# shim on PATH. No real vendor is called (ALL_PROXY points at a dead address).
#
#   H1  code kind: the fixture site asks for a code only the stub human knows;
#       the stub replies to the Telegram ask; rc 0 prints the code; the code
#       signs in to the fixture site
#   H2  the callback_data and the ref: line the fake recorded parse in the
#       route; H2b a wrong nonce, another run and a second answer are refused
#   H3  approve kind: Done gives rc 0 `done`; Cancel gives rc 3
#   H4  no answer in time: rc 4, `waiting on human`, the step stays open; the
#       wait is the web_task.human_wait_s row; an old nonce is refused
#   H5  the Telegram send: photo, chat from the settings row, caption with
#       project, site and prompt, the buttons
#   H6  one board comment; first line matches hold.sh's NEEDS-HUMAN regex;
#       no nonce in it
#   H7  board answers: a bot and a non-listed login are ignored;
#       HUMAN-STEP-DONE by operator completes the step (answer_via=board);
#       H7b the board seam alone: a listed bot never counts; unreadable is rc 2
#       H7c no chat row and no bot token: the board answer still gives rc 0
#   H8  the code is used once: a poll after rc 0 is `consumed`, no code
#   H9  no TELEGRAM_BOT_TOKEN: not-configured, 0 Telegram calls, board still
#   H10 the code is in no log, argv, fake record, comment or stderr
#   H11 no channel delivered (none configured, or the send failed): rc 1, the
#       step is cancelled
#   H12 missing env: rc 2, no request
#
# Run from anywhere: tests/web-task-human.bh-7598-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV="$DIR/tests/lib/web-vault-worker.bh-7595.mjs"
FAKES="$DIR/tests/lib/web-task-human-fakes.bh-7598.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }

MISSING=0
for f in "$DIR/bin/lib/web-human.sh" "$DIR/bin/lib/web-human/telegram.sh" "$DIR/bin/lib/web-human/board.sh" \
         "$DIR/worker/jobs/src/routes/web-task-human.js" "$DIR/worker/jobs/test/route-table.d/bh-7598-web-task-human.txt" \
         "$DIR/worker/jobs/schema.d/202610251632-bh-7598-web-task-human.sql" "$FAKES" "$SRV"; do
  if [ -s "$f" ]; then ok "source exists: ${f#"$DIR"/}"; else bad "missing source ${f#"$DIR"/}"; MISSING=1; fi
done
if [ "$MISSING" = 1 ]; then echo "web-task-human: $PASS passed, $FAIL failed"; exit 1; fi

H="$T/h"
mkdir -p "$H/logs"
( cd "$DIR" && scratch_install_closure bin/lib/web-human.sh "$H" ) >/dev/null 2>&1 || bad "setup: could not install bin/lib/web-human.sh"
# HARNESS is the scratch root: it holds no env/github-app.env, so the board
# seam's gh_auth_for (bin/lib/gh-app-auth.sh) is unarmed and mints nothing.
export HARNESS="$H"
unset GH_TOKEN JOBS_URL HARNESS_SECRET LANE_RUN_ID WEB_VAULT_MACHINE FLY_MACHINE_ID WEB_VAULT_RUN_TOKEN TELEGRAM_BOT_TOKEN WEB_TASK_HUMAN_WAIT_S WEB_HUMAN_TG_API
SECRET=fixture-harness-secret
RUN_TOKEN=fixture-run-token-7598
BOT=fixture-bot-token-7598
SITE_CODE=731905            # the code only the stub human knows
BOARD_CODE=264028           # the code the board human posts in H7
PROMPT='Enter the 6-digit code sent to your phone'
printf '\x89PNG\r\n\x1a\nfixture-screenshot' > "$T/shot.png"

# A curl shim that records its argv, then runs the real curl. Any host but
# 127.0.0.1 goes to a dead proxy (RFC 5737), so a real vendor is never reached.
REAL_CURL=$(command -v curl)
mkdir -p "$T/shim" "$T/ghpost"
cat > "$T/shim/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/argv.log"
exec "$REAL_CURL" "\$@"
EOF
# A gh shim: never the real gh. POST appends the comment (by the bot) to the
# issue's comment file and answers it; GET answers the file.
cat > "$T/shim/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.log"
[ "\$1" = api ] || exit 1
path=""; post=0
for a in "\$@"; do case "\$a" in repos/*) path="\$a" ;; POST) post=1 ;; esac; done
num=\$(printf '%s' "\$path" | sed -E 's#^repos/[^/]+/[^/]+/issues/([0-9]+)/comments.*#\1#')
store="$T/comments-\$num.json"
[ -s "\$store" ] || echo '[]' > "\$store"
if [ "\$post" = 1 ]; then
  k=\$(( \$(find "$T/ghpost" -name '*.body' | wc -l) + 1 ))
  cat > "$T/ghpost/\$k.body"
  c=\$(jq -nc --rawfile b "$T/ghpost/\$k.body" --arg now "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson id "\$((900 + k))" \
        '{id:\$id, created_at:\$now, body:\$b, user:{login:"fixture-harness[bot]", type:"Bot"}}')
  jq -c --argjson c "\$c" '. + [\$c]' "\$store" > "\$store.tmp" && mv "\$store.tmp" "\$store"
  printf '%s\n' "\$c"
else
  [ -e "$T/gh.fail" ] && { echo "gh: fixture outage" >&2; exit 1; }
  cat "\$store"
fi
EOF
chmod +x "$T/shim/curl" "$T/shim/gh"
: > "$T/argv.log"; : > "$T/gh.log"; : > "$T/calls.jsonl"
export PATH="$T/shim:$PATH"
export ALL_PROXY=http://192.0.2.1:9 HTTPS_PROXY=http://192.0.2.1:9 https_proxy=http://192.0.2.1:9 NO_PROXY=127.0.0.1 no_proxy=127.0.0.1

PID=""; FPID=""
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; [ -n "$FPID" ] && kill "$FPID" 2>/dev/null' EXIT
: > "$T/srv.log"; : > "$T/srv.port"; : > "$T/fake.port"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
PID=$!
node "$FAKES" "$T/calls.jsonl" "$BOT" "$SITE_CODE" > "$T/fake.port" 2> "$T/fake.err" &
FPID=$!
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && [ -s "$T/fake.port" ] && break; kill -0 "$PID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port"); FPORT=$(head -1 "$T/fake.port")
if [ -z "$PORT" ]; then
  wait "$PID"; src=$?
  [ "$src" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
[ -n "$FPORT" ] || { echo "setup: fakes did not start: $(cat "$T/fake.err")"; exit 1; }
URL="http://127.0.0.1:$PORT"; FAKE="http://127.0.0.1:$FPORT"
sql() { "$REAL_CURL" -sS -X POST "$URL/__sql" --data-binary "$1" >/dev/null; }
get() { "$REAL_CURL" -sS -X POST "$URL/__get" --data-binary "$1"; }
reqs() { wc -l < "$T/srv.log" | tr -d ' '; }
calls() { wc -l < "$T/calls.jsonl" | tr -d ' '; }

sql "INSERT INTO settings (key,value,note,actor,updated_at) VALUES
       ('lib.lane-alert.lane_alert_dm_chat','1000000001','','test','2026-10-23T00:00:00Z')
     ON CONFLICT(key) DO UPDATE SET value=excluded.value;
     UPDATE settings SET value='1' WHERE key='web_task.human_poll_s';"
TOKEN_HASH=$(printf '%s' "$RUN_TOKEN" | sha256sum | cut -d' ' -f1)
# newrun <project> — a claimed web-task run of <project> by m1, its run-token
# row and its allow-list row; prints the id. One live run per (lane, project),
# so every case names its own project.
newrun() {
  sql "INSERT INTO settings (key,value,note,actor,updated_at) VALUES ('lane.web-task.$1.allowed_domains','app.example.com','','test','2026-10-23T00:00:00Z')
         ON CONFLICT(key) DO NOTHING;
       INSERT INTO lane_runs (lane, project, args_json, enqueued_at, claimed_at, claimed_by, lease_until, attempts, status)
         VALUES ('web-task','$1','[]', strftime('%Y-%m-%dT%H:%M:%SZ','now'), strftime('%Y-%m-%dT%H:%M:%SZ','now'), 'm1',
                 strftime('%Y-%m-%dT%H:%M:%SZ','now','+1 hour'), 1, 'claimed');"
  local id
  id=$(get "SELECT id FROM lane_runs WHERE lane='web-task' AND project='$1' AND status='claimed'" | jq -r '.[0].id')
  sql "INSERT INTO web_vault_run_token (run_id, machine, token_hash, created_at) VALUES ($id, 'm1', '$TOKEN_HASH', strftime('%Y-%m-%dT%H:%M:%SZ','now'));"
  printf '%s' "$id"
}
# WEB_TASK_HUMAN_WAIT_S only shortens the 300 s row: a broken build fails in 20 s, not 300.
export JOBS_URL="$URL" HARNESS_SECRET="$SECRET" WEB_VAULT_MACHINE=m1 WEB_VAULT_RUN_TOKEN="$RUN_TOKEN" WEB_HUMAN_TG_API="$FAKE" WEB_TASK_HUMAN_WAIT_S=20
# whr <tag> <args...> — wh_request_human in a subshell that sources the lib;
# stdout/stderr go to $T/<tag>.out/.err; sets RC, OUT, ERR.
whr() {
  local tag="$1"; shift
  ( . "$H/bin/lib/web-human.sh" || exit 9; wh_request_human "$@" ) > "$T/$tag.out" 2> "$T/$tag.err"; RC=$?
  OUT=$(cat "$T/$tag.out"); ERR=$(cat "$T/$tag.err")
}
# wait_calls <n> — until the fake Telegram has recorded n calls (10 s max).
wait_calls() { for _ in $(seq 1 100); do [ "$(calls)" -ge "$1" ] && return 0; sleep 0.1; done; return 1; }
# answer_raw <json> — POST it to the answer route as the console forward would; prints the HTTP code.
answer_raw() {
  printf '%s' "$1" | "$REAL_CURL" -sS -o "$T/ans.out" -w '%{http_code}' -H "authorization: Bearer $SECRET" \
    -H 'content-type: application/json' --data-binary @- "$URL/api/web-task/answer"
}
# The stub human on Telegram: reply to the n-th ask with a code, or press a button.
tg_reply() {
  wait_calls "$1" || return 1
  local rec key
  rec=$(sed -n "${1}p" "$T/calls.jsonl")
  key=$(jq -r 'if .has_photo then "caption" else "text" end' <<<"$rec")
  answer_raw "$(jq -c --arg code "$2" --arg k "$key" '{message:{text:$code, reply_to_message:{($k): .text}}}' <<<"$rec")" > "$T/stub.$1.code"
}
tg_press() {
  wait_calls "$1" || return 1
  local data
  data=$(sed -n "${1}p" "$T/calls.jsonl" | jq -r --arg s ":$2" '[.reply_markup.inline_keyboard[][] | .callback_data | select(endswith($s))][0]')
  answer_raw "{\"callback_query\":{\"data\":\"$data\"}}" > "$T/stub.$1.code"
}

# --- H1: code kind, the stub human replies on Telegram ------------------------
LOGIN=$("$REAL_CURL" -sS "$FAKE/login")
[ "$LOGIN" = "Enter the code we sent to your phone" ] && ok "H1 the fixture site asks for a code" || bad "H1 login page: $LOGIN"
R1=$(newrun wt-h1)
N0=$(calls)
tg_reply $((N0 + 1)) "$SITE_CODE" &
STUB=$!
LANE_RUN_ID="$R1" TELEGRAM_BOT_TOKEN="$BOT" whr h1 wt-h1 app.example.com code "$PROMPT" --shot "$T/shot.png" --issue fixture-org/fixture-repo#7
wait "$STUB"
if [ "$RC" = 0 ] && [ "$OUT" = "$SITE_CODE" ] && [ "$(wc -c < "$T/h1.out" | tr -d ' ')" = 6 ]; then
  ok "H1 wh_request_human rc 0 prints the code with no newline"
else bad "H1 rc=$RC out='$OUT' err='$ERR' stub=$(cat "$T/stub.$((N0 + 1)).code" 2>/dev/null)"; fi
SIGNED=$("$REAL_CURL" -sS -X POST --data-binary "code=$OUT" "$FAKE/verify")
[ "$SIGNED" = "signed in" ] && ok "H1 the code signs in to the fixture site" || bad "H1 verify: $SIGNED"
WRONG=$("$REAL_CURL" -sS -o /dev/null -w '%{http_code}' -X POST --data-binary "code=000000" "$FAKE/verify")
[ "$WRONG" = 401 ] && ok "H1 the fixture site refuses another code" || bad "H1 verify wrong: $WRONG"
S1=$(get "SELECT id, status, answer_via, tg_outcome, board_outcome FROM web_task_human_step WHERE run_id=$R1" | jq -c '.[0]')
[ "$(jq -r '.status + " " + .answer_via' <<<"$S1")" = "consumed telegram" ] && ok "H1 the step is consumed, answered by telegram" || bad "H1 step: $S1"
[[ $(jq -r '.tg_outcome' <<<"$S1") == "sent "* ]] && [[ $(jq -r '.board_outcome' <<<"$S1") == "posted "* ]] \
  && ok "H1 the step records both channel outcomes" || bad "H1 outcomes: $S1"
STEP1=$(jq -r '.id' <<<"$S1")

# --- H2: round trip and refusals through the same route -----------------------
[ "$(cat "$T/stub.$((N0 + 1)).code")" = 200 ] && ok "H2 the ref: line the fake recorded parses in the route" || bad "H2 stub answer: $(cat "$T/stub.$((N0 + 1)).code") $(cat "$T/ans.out")"
REC1=$(sed -n "$((N0 + 1))p" "$T/calls.jsonl")
DATA1=$(jq -r '.reply_markup.inline_keyboard[][] | .callback_data' <<<"$REC1" | head -1)
NONCE1=$(cut -d: -f3 <<<"$DATA1")
[[ $DATA1 =~ ^wt:$STEP1:[A-Za-z0-9_-]{22}:c$ ]] && ok "H2 the code ask carries the Cancel callback for its step" || bad "H2 callback: $DATA1"
FLIP="${NONCE1%?}$([ "${NONCE1: -1}" = A ] && echo B || echo A)"
C=$(answer_raw "{\"callback_query\":{\"data\":\"wt:$STEP1:$FLIP:c\"}}")
[ "$C" = 403 ] && [ "$(jq -r .refused "$T/ans.out")" = bad_nonce ] && ok "H2b a wrong nonce is refused" || bad "H2b wrong nonce: $C $(cat "$T/ans.out")"
ROTHER=$(newrun wt-h2)
C=$(answer_raw "{\"run_id\":$ROTHER,\"step_id\":$STEP1,\"nonce\":\"$NONCE1\",\"action\":\"cancel\"}")
[ "$C" = 403 ] && [ "$(jq -r .refused "$T/ans.out")" = other_run ] && ok "H2b an answer for another run is refused" || bad "H2b other run: $C $(cat "$T/ans.out")"
C=$(answer_raw "{\"callback_query\":{\"data\":\"$DATA1\"}}")
[ "$C" = 409 ] && [ "$(jq -r .refused "$T/ans.out")" = already_answered ] && ok "H2b a second answer is refused" || bad "H2b second: $C $(cat "$T/ans.out")"

# --- H8: the code is used once -----------------------------------------------
P=$(jq -nc --argjson r "$R1" --argjson s "$STEP1" '{run_id:$r, machine:"m1", step_id:$s}' \
    | "$REAL_CURL" -sS -H "authorization: Bearer $SECRET" -H "x-web-vault-run-token: $RUN_TOKEN" -H 'content-type: application/json' \
        --data-binary @- "$URL/api/web-task/human/poll")
[ "$(jq -r .state <<<"$P")" = consumed ] && [ "$(jq 'has("code")' <<<"$P")" = false ] && ok "H8 a poll after rc 0 is consumed, with no code" || bad "H8 poll: $P"

# --- H3: approve kind, Done and Cancel ---------------------------------------
R3=$(newrun wt-h3)
N0=$(calls)
tg_press $((N0 + 1)) d &
STUB=$!
LANE_RUN_ID="$R3" TELEGRAM_BOT_TOKEN="$BOT" whr h3 wt-h3 app.example.com approve 'Approve the sign-in on your phone'
wait "$STUB"
[ "$RC" = 0 ] && [ "$OUT" = done ] && ok "H3 Done gives rc 0 and done" || bad "H3 done: rc=$RC out='$OUT' err='$ERR'"
REC3=$(sed -n "$((N0 + 1))p" "$T/calls.jsonl")
R3B=$(newrun wt-h3b)
N0=$(calls)
tg_press $((N0 + 1)) c &
STUB=$!
LANE_RUN_ID="$R3B" TELEGRAM_BOT_TOKEN="$BOT" whr h3b wt-h3b app.example.com approve 'Approve the sign-in on your phone'
wait "$STUB"
[ "$RC" = 3 ] && [ -z "$OUT" ] && grep -qx 'web-human: cancelled' "$T/h3b.err" && ok "H3 Cancel gives rc 3 and cancelled" || bad "H3 cancel: rc=$RC out='$OUT' err='$ERR'"

# --- H5: the Telegram sends --------------------------------------------------
if [ "$(jq -r '[.method, .has_photo, .chat_id, .token_ok] | map(tostring) | join(" ")' <<<"$REC1")" = "sendPhoto true 1000000001 true" ]; then
  ok "H5 the code ask is one sendPhoto with the screenshot to the chat from the settings row"
else bad "H5 photo record: $REC1"; fi
CAP=$(jq -r .text <<<"$REC1")
[[ $CAP == *wt-h1* && $CAP == *app.example.com* && $CAP == *"$PROMPT"* ]] && grep -qx "ref: wt:$STEP1:$NONCE1" <<<"$CAP" \
  && ok "H5 the caption holds project, site, prompt and the ref: line" || bad "H5 caption: $CAP"
[ "$(jq -c '[.reply_markup.inline_keyboard[][] | .text]' <<<"$REC1")" = '["Cancel"]' ] && ok "H5 the code ask has a Cancel button" || bad "H5 code buttons: $REC1"
if [ "$(jq -r '.method' <<<"$REC3")" = sendMessage ] && [ "$(jq -c '[.reply_markup.inline_keyboard[][] | .text]' <<<"$REC3")" = '["Done","Cancel"]' ] \
   && [ "$(jq -r '[.reply_markup.inline_keyboard[][] | .callback_data | .[-2:]] | join(" ")' <<<"$REC3")" = ":d :c" ]; then
  ok "H5 the approve ask is one sendMessage with Done and Cancel"
else bad "H5 approve record: $REC3"; fi

# --- H6: the board comment ---------------------------------------------------
B1="$T/ghpost/1.body"
if [ -s "$B1" ] && [ "$(find "$T/ghpost" -name '*.body' | wc -l | tr -d ' ')" = 1 ] && head -1 "$B1" | grep -Pq '^NEEDS-HUMAN:[ \t]*\S'; then
  ok "H6 one board comment whose first line is a NEEDS-HUMAN hold"
else bad "H6 comment: $(cat "$B1" 2>/dev/null)"; fi
[ "$(head -1 "$B1")" = "NEEDS-HUMAN: web-task code on app.example.com: $PROMPT" ] && ok "H6 the first line names kind, site and prompt" || bad "H6 first line: $(head -1 "$B1")"
grep -qF -- "$NONCE1" "$B1" && bad "H6 the comment holds the nonce" || ok "H6 the comment holds no nonce"
grep -qF "<!-- wt-step:$STEP1 -->" "$B1" && ok "H6 the comment carries the step marker" || bad "H6 no step marker"
grep -q 'repos/fixture-org/fixture-repo/issues/7/comments' "$T/gh.log" && ok "H6 gh posted to the ticket's issue" || bad "H6 gh log: $(cat "$T/gh.log")"

# --- H4: no answer in time; an old nonce ---------------------------------------
sql "UPDATE settings SET value='10' WHERE key='web_task.human_wait_s';"
R4=$(newrun wt-h4)
N0=$(calls)
T0=$(date +%s)
LANE_RUN_ID="$R4" TELEGRAM_BOT_TOKEN="$BOT" WEB_TASK_HUMAN_WAIT_S=2 whr h4 wt-h4 app.example.com code "$PROMPT"
EL=$(( $(date +%s) - T0 ))
S4=$(get "SELECT id, status, CAST(strftime('%s', wait_until) AS INTEGER) - CAST(strftime('%s', created_at) AS INTEGER) AS w FROM web_task_human_step WHERE run_id=$R4" | jq -c '.[0]')
STEP4=$(jq -r .id <<<"$S4")
if [ "$RC" = 4 ] && [ -z "$OUT" ] && grep -qx "web-human: waiting on human (step $STEP4)" "$T/h4.err" && [ "$EL" -lt 8 ]; then
  ok "H4 no answer in time: rc 4, waiting on human, after the shorter env wait"
else bad "H4 rc=$RC out='$OUT' err='$ERR' elapsed=$EL"; fi
[ "$(jq -r '.status' <<<"$S4")" = open ] && ok "H4 the step stays open for a later answer" || bad "H4 step: $S4"
[ "$(jq -r '.w' <<<"$S4")" = 10 ] && ok "H4 wait_until comes from the web_task.human_wait_s row" || bad "H4 wait: $S4"
DATA4=$(sed -n "$((N0 + 1))p" "$T/calls.jsonl" | jq -r '.reply_markup.inline_keyboard[][] | .callback_data' | head -1)
# A second ask of the same run, with an env wait LONGER than the 10 s row: the row wins.
T0=$(date +%s)
LANE_RUN_ID="$R4" TELEGRAM_BOT_TOKEN="$BOT" WEB_TASK_HUMAN_WAIT_S=60 whr h4b wt-h4 app.example.com code "$PROMPT"
EL=$(( $(date +%s) - T0 ))
[ "$RC" = 4 ] && [ "$EL" -ge 8 ] && [ "$EL" -lt 30 ] && ok "H4 WEB_TASK_HUMAN_WAIT_S never lengthens the row's wait" || bad "H4b rc=$RC elapsed=$EL err='$ERR'"
sql "UPDATE settings SET value='300' WHERE key='web_task.human_wait_s';"
C=$(answer_raw "{\"callback_query\":{\"data\":\"$DATA4\"}}")
[ "$C" = 409 ] && [ "$(jq -r .refused "$T/ans.out")" = old_nonce ] && ok "H4 the first ask's nonce is old after a second ask" || bad "H4 old nonce: $C $(cat "$T/ans.out")"

# --- H7 + H9: board answers, no Telegram token --------------------------------
R7=$(newrun wt-h7)
N0=$(calls)
(
  for _ in $(seq 1 100); do [ -s "$T/comments-8.json" ] && break; sleep 0.1; done
  later=$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)
  jq -c --arg at "$later" --arg code "$BOARD_CODE" '. + [
      {id:1, created_at:$at, body:("HUMAN-STEP-DONE: " + $code + "\nthanks"), user:{login:"operator", type:"User"}},
      {id:2, created_at:$at, body:"see this:\nHUMAN-STEP-DONE: 555555", user:{login:"operator", type:"User"}},
      {id:3, created_at:$at, body:"HUMAN-STEP-DONE: 111111", user:{login:"fixture-stranger", type:"User"}},
      {id:4, created_at:$at, body:"HUMAN-STEP-DONE: 000000", user:{login:"fixture-harness[bot]", type:"Bot"}}]' \
    "$T/comments-8.json" > "$T/comments-8.json.tmp" && mv "$T/comments-8.json.tmp" "$T/comments-8.json"
) &
STUB=$!
LANE_RUN_ID="$R7" whr h7 wt-h7 app.example.com code "$PROMPT" --issue fixture-org/fixture-repo#8
wait "$STUB"
[ "$RC" = 0 ] && [ "$OUT" = "$BOARD_CODE" ] && ok "H7 HUMAN-STEP-DONE by operator gives the code; bot, stranger and mid-text lines are ignored" || bad "H7 rc=$RC out='$OUT' err='$ERR'"
[ "$(get "SELECT answer_via FROM web_task_human_step WHERE run_id=$R7" | jq -r '.[0].answer_via')" = board ] && ok "H7 the step was answered by board" || bad "H7 answer_via"
grep -qx 'web-human: telegram: not-configured: TELEGRAM_BOT_TOKEN' "$T/h7.err" && ok "H9 no bot token: not-configured on stderr" || bad "H9 stderr: $ERR"
[ "$(calls)" = "$N0" ] && ok "H9 no bot token: 0 Telegram calls" || bad "H9 calls $N0 -> $(calls)"
[ "$(get "SELECT board_outcome FROM web_task_human_step WHERE run_id=$R7" | jq -r '.[0].board_outcome')" != null ] \
  && grep -q '^web-human: board: posted ' "$T/h7.err" && ok "H9 the board comment still went out" || bad "H9 board: $ERR"

# --- H7b: the board seam on its own: a bot never counts, even when listed ----
printf '%s' '[{"id":1,"created_at":"2026-10-23T10:00:00Z","body":"HUMAN-STEP-DONE: 222222\nthanks","user":{"login":"operator","type":"User"}},
  {"id":2,"created_at":"2026-10-23T10:05:00Z","body":"HUMAN-STEP-DONE: 333333","user":{"login":"fixture-harness[bot]","type":"Bot"}},
  {"id":3,"created_at":"2026-10-23T10:06:00Z","body":"HUMAN-STEP-DONE: 444444","user":{"login":"fixture-app","type":"Bot"}},
  {"id":4,"created_at":"2026-10-23T08:00:00Z","body":"HUMAN-STEP-DONE: 555555","user":{"login":"operator","type":"User"}}]' > "$T/comments-9.json"
WB=$( . "$H/bin/lib/web-human/board.sh" || exit 9; whb_done_after fixture-org/fixture-repo 9 2026-10-23T09:00:00Z 'operator,fixture-harness[bot],fixture-app' ); RC=$?
[ "$RC" = 0 ] && [ "$WB" = 222222 ] && ok "H7b a listed bot login or a Bot user never answers; an older comment never answers; one line only" || bad "H7b rc=$RC out='$WB'"
WB=$( . "$H/bin/lib/web-human/board.sh" || exit 9; whb_done_after fixture-org/fixture-repo 9 2026-10-23T09:00:00Z 'fixture-stranger' ); RC=$?
[ "$RC" = 1 ] && [ -z "$WB" ] && ok "H7b no listed login: rc 1" || bad "H7b none rc=$RC out='$WB'"
touch "$T/gh.fail"
WB=$( . "$H/bin/lib/web-human/board.sh" || exit 9; whb_done_after fixture-org/fixture-repo 9 2026-10-23T09:00:00Z operator ); RC=$?
rm -f "$T/gh.fail"
[ "$RC" = 2 ] && ok "H7b an unreadable board is rc 2, never none" || bad "H7b unreadable rc=$RC"

# --- H7c: no chat row and no bot token: the board answer still works ----------
# With no lib.lane-alert.lane_alert_dm_chat row the ask answers tg_chat null.
# The empty field must not shift the logins (a tab-split read collapsed it).
CHAT_ROW=$(get "SELECT value FROM settings WHERE key='lib.lane-alert.lane_alert_dm_chat'" | jq -r '.[0].value')
sql "DELETE FROM settings WHERE key='lib.lane-alert.lane_alert_dm_chat';"
R7C=$(newrun wt-h7c)
N0=$(calls)
(
  for _ in $(seq 1 100); do [ -s "$T/comments-10.json" ] && break; sleep 0.1; done
  later=$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M:%SZ)
  jq -c --arg at "$later" --arg code "$BOARD_CODE" '. + [
      {id:1, created_at:$at, body:("HUMAN-STEP-DONE: " + $code), user:{login:"operator", type:"User"}}]' \
    "$T/comments-10.json" > "$T/comments-10.json.tmp" && mv "$T/comments-10.json.tmp" "$T/comments-10.json"
) &
STUB=$!
LANE_RUN_ID="$R7C" whr h7c wt-h7c app.example.com code "$PROMPT" --issue fixture-org/fixture-repo#10
wait "$STUB"
sql "INSERT INTO settings (key,value,note,actor,updated_at) VALUES
       ('lib.lane-alert.lane_alert_dm_chat','$CHAT_ROW','','test','2026-10-23T00:00:00Z')
     ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
[ "$RC" = 0 ] && [ "$OUT" = "$BOARD_CODE" ] && ok "H7c no chat row, no bot token: HUMAN-STEP-DONE by operator still gives the code" || bad "H7c rc=$RC out='$OUT' err='$ERR'"
[ "$(calls)" = "$N0" ] && ok "H7c no chat row: 0 Telegram calls" || bad "H7c calls $N0 -> $(calls)"

# --- H11: no channel delivered ------------------------------------------------
R11=$(newrun wt-h11)
LANE_RUN_ID="$R11" whr h11 wt-h11 app.example.com code "$PROMPT"
[ "$RC" = 1 ] && grep -qx 'web-human: no channel delivered the ask' "$T/h11.err" && ok "H11 no channel configured: rc 1" || bad "H11 rc=$RC err='$ERR'"
[ "$(get "SELECT status, answer_via FROM web_task_human_step WHERE run_id=$R11" | jq -r '.[0] | .status + " " + .answer_via')" = "cancelled api" ] \
  && ok "H11 the undelivered step is cancelled" || bad "H11 step"
R11B=$(newrun wt-h11b)
"$REAL_CURL" -sS -X POST "$FAKE/__fail_next" >/dev/null
LANE_RUN_ID="$R11B" TELEGRAM_BOT_TOKEN="$BOT" whr h11b wt-h11b app.example.com code "$PROMPT"
[ "$RC" = 1 ] && grep -q '^web-human: telegram: failed 400 ' "$T/h11b.err" && grep -qx 'web-human: no channel delivered the ask' "$T/h11b.err" \
  && ok "H11 a failed Telegram send is not a delivery" || bad "H11b rc=$RC err='$ERR'"

# --- H12: missing env ---------------------------------------------------------
N=$(reqs)
whr h12 p1 app.example.com code "$PROMPT"
[ "$RC" = 2 ] && [ "$(reqs)" = "$N" ] && ok "H12 no LANE_RUN_ID: rc 2, no request" || bad "H12 rc=$RC err='$ERR'"
LANE_RUN_ID="$R11" whr h12b wt-h11 app.example.com captcha "$PROMPT"
[ "$RC" = 2 ] && [ "$(reqs)" = "$N" ] && ok "H12 a bad kind: rc 2, no request" || bad "H12b rc=$RC err='$ERR'"
LANE_RUN_ID="$R11" WEB_VAULT_RUN_TOKEN='' whr h12c wt-h11 app.example.com code "$PROMPT"
[ "$RC" = 2 ] && [ "$(reqs)" = "$N" ] && ok "H12 no run token: rc 2, no request" || bad "H12c rc=$RC err='$ERR'"
LANE_RUN_ID="$R11" WEB_VAULT_RUN_TOKEN=fixture-run-token-guess WEB_HUMAN_TIMEOUT_S=7 WEB_HUMAN_CONNECT_TIMEOUT_S=3 whr h12d wt-h11 app.example.com code "$PROMPT"
[ "$RC" = 1 ] && grep -qx 'web-human: refused bad_token' "$T/h12d.err" && ok "H12 a wrong run token: rc 1, refused" || bad "H12d rc=$RC err='$ERR'"
# The HTTP timeouts are the web-human lib knobs, not literals.
# One call is two log lines: curl's -w value holds a newline.
tail -2 "$T/argv.log" | grep -q -- '^-sS -m 7 --connect-timeout 3 ' && ok "H12 the timeouts come from WEB_HUMAN_TIMEOUT_S and WEB_HUMAN_CONNECT_TIMEOUT_S" || bad "H12 timeout argv: $(tail -2 "$T/argv.log")"
grep -q -- '-m 15 --connect-timeout 5 ' "$T/argv.log" && ok "H12 the documented fallbacks are 15 s and 5 s" || bad "H12 no fallback argv"

# --- H10: the code is nowhere -------------------------------------------------
LEAK=0
for f in "$T/srv.log" "$T/argv.log" "$T/calls.jsonl" "$T/gh.log" "$T"/ghpost/*.body "$T"/*.err "$H"/logs/*; do
  [ -e "$f" ] || continue
  for c in "$SITE_CODE" "$BOARD_CODE"; do
    if grep -qF -- "$c" "$f"; then LEAK=1; bad "H10 $(basename "$f") holds a code"; fi
  done
done
[ -s "$T/argv.log" ] || { LEAK=1; bad "H10 the curl shim recorded no call"; }
grep -qF -- "$BOT" "$T/argv.log" && { LEAK=1; bad "H10 the bot token is on a curl argv"; }
grep -qF -- "$RUN_TOKEN" "$T/argv.log" && { LEAK=1; bad "H10 the run token is on a curl argv"; }
[ "$LEAK" = 0 ] && ok "H10 no code in the worker log, curl argv, fake record, gh log, comments, stderr or logs"
if grep -Eq '(^|[^_])set -x|set -o xtrace' "$DIR/bin/lib/web-human.sh" "$DIR/bin/lib/web-human/telegram.sh" "$DIR/bin/lib/web-human/board.sh"; then
  bad "H10 a lib turns on xtrace"; else ok "H10 no xtrace in the libs"; fi

# --- Budget: no real vendor ---------------------------------------------------
if grep -vE '^api ' "$T/gh.log" | grep -q .; then bad "budget: gh ran something but api: $(cat "$T/gh.log")"; else ok "budget: gh is the shim, api calls only"; fi
grep -Eq 'api\.telegram\.org|api\.github\.com' "$T/argv.log" && bad "budget: a curl argv names a real vendor" || ok "budget: no curl argv names a real vendor"

echo "web-task-human: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
