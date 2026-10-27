#!/bin/bash
# tests/telegram-chat-id.bh-7939-test.sh — the Telegram seam
# (bin/lib/vendor/telegram.sh tg_latest_chat_id) and the hub verb
# bin/fleet-telegram-chat.sh that stores the chat id as settings rows
# (BH-7974, slice BH-7939.0).
#
#   G1  3 message updates 11/22/33 -> 33 (the newest)
#   G2  only channel_post -> its id
#   G3  ok:false "Unauthorized" (real mode, stub curl) -> rc 1, the description
#   G4  result:[] -> rc 4, nothing on stdout
#   G5  150 updates, the last is id 150 -> 150 (no cut at 100)
#   G6  a description and a curl error that hold the token -> `<token>`, never
#       the token
#   G7  last update edited_message, the one before it message 7 -> 7
#   G8  only callback_query -> rc 4, no id
#   G9  chat id "abc", no `ok`, a non-JSON body -> rc 1, nothing on stdout
#   G10 the stub curl's argv holds no token, its stdin does; one call,
#       --max-time 20, no offset
#   G11 a bad variable name rc 2, an unset token rc 3, HARNESS_VENDOR_MODE=Fake
#       rc 2 and no curl
#   G12 an unseeded fake method -> rc 70
#   V1  fake seed -> `TELEGRAM_CHAT ok -1009990001`, rows chat_id/bot_present/
#       state, read back through GET, 0 call-log lines
#   V2  result:[] -> waiting, telegram.state=waiting_for_message, no chat_id row
#   V3  a 409 ok:false body -> failed, rc 1, 0 PUTs
#   V4  PUT 500 -> failed after the first PUT; V4b the 2nd PUT fails -> failed,
#       no bot_present row
#   V5  the read-back answers another id -> failed
#   V6  no token anywhere -> failed `TELEGRAM_BOT_TOKEN is not set`, 0 PUTs;
#       V6b the token from env/global.env -> ok, token never printed
#   V7  an argument -> rc 2, 0 PUTs
#   V8  no bin/jobs-client.sh -> failed `jobs not configured`
#   V9  waiting, but the state PUT answers 500 -> failed
#   V10 a seam that answers rc 0 with a non-integer -> failed, 0 PUTs
#   V11 HARNESS_VENDOR_MODE=Fake -> failed, 0 PUTs
#   V12 bash -n and shellcheck -S error on the verb
#
# Fake-mode cases append to the inherited $VENDOR_CALL_LOG (the budget test
# hands one in) and assert it gained 0 lines. Real-mode cases use their own
# stub curl and their own call log.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/telegram-chat-id.bh-7939-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
has() { if grep -qF -- "$3" <<<"$2"; then ok; else bad "$1: '$3' not in: $2"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1: '$3' unexpectedly in: $2"; else ok; fi; }

SEAM="$DIR/bin/lib/vendor/telegram.sh"
TOK='123456:tok-fixture-AAA'
VENDOR_CALL_LOG="${VENDOR_CALL_LOG:-$T/calls.log}"
touch "$VENDOR_CALL_LOG"
LOG0=$(grep -c . "$VENDOR_CALL_LOG")

# seed <case> <getUpdates-json> — a seed dir $T/<case>/fake with that answer.
seed() {
  mkdir -p "$T/$1/fake"
  jq -n --argjson u "$2" '{getMe:{ok:true,result:{id:1,is_bot:true}}, getUpdates:$u}' > "$T/$1/fake/telegram.json"
}
# msgs <kind> <id>... — an ok getUpdates answer with one <kind> update per id.
msgs() {
  local kind="$1"; shift
  printf '%s\n' "$@" | jq -s --arg k "$kind" '{ok:true, result: [ to_entries[] | {update_id:(.key+1)} + {($k): {chat:{id:.value, type:"group"}}} ]}'
}
# stubcurl <case> <body> [rc] — a PATH curl that saves argv and stdin, prints body.
stubcurl() {
  mkdir -p "$T/$1/bin"
  printf '%s' "$2" > "$T/$1/body"
  cat > "$T/$1/bin/curl" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$T/$1/argv"
cat >> "$T/$1/stdin"
cat "$T/$1/body"
exit ${3:-0}
SH
  chmod +x "$T/$1/bin/curl"
}
# chat <case> <mode> [var] — tg_latest_chat_id in a child bash. Sets OUT ERR RC.
chat() {
  local c="$1" mode="$2" var="${3:-TOK_FIXTURE}" log="$VENDOR_CALL_LOG"
  [ "$mode" = fake ] || log="$T/$c/real-calls.log"
  env PATH="$T/$c/bin:$PATH" HARNESS_VENDOR_MODE="$mode" VENDOR_FAKE_DIR="$T/$c/fake" \
      VENDOR_CALL_LOG="$log" TOK_FIXTURE="$TOK" \
      bash -c '. "$1" || exit 99; tg_latest_chat_id "$2"' _ "$SEAM" "$var" \
      >"$T/$c/out" 2>"$T/$c/err"; RC=$?
  OUT=$(cat "$T/$c/out"); ERR=$(cat "$T/$c/err")
}

# G1 — the newest of 3 message updates.
seed g1 "$(msgs message 11 22 33)"; chat g1 fake
eq "G1 rc" "$RC" 0; eq "G1 newest id" "$OUT" 33

# G2 — channel_post only.
seed g2 "$(msgs channel_post -100777)"; chat g2 fake
eq "G2 rc" "$RC" 0; eq "G2 channel id" "$OUT" -100777

# G3 + G10 — ok:false through the real path (stub curl).
stubcurl g3 '{"ok":false,"error_code":401,"description":"Unauthorized"}'; chat g3 real
eq "G3 rc 1" "$RC" 1; eq "G3 stdout empty" "$OUT" ""
has "G3 description" "$ERR" "telegram: Unauthorized"
eq "G10 one curl call" "$(grep -c . "$T/g3/argv")" 1
hasnt "G10 argv has no token" "$(cat "$T/g3/argv")" "$TOK"
has "G10 argv --max-time 20" "$(cat "$T/g3/argv")" "--max-time 20"
has "G10 argv reads config from stdin" "$(cat "$T/g3/argv")" "-K -"
has "G10 stdin holds the getUpdates URL" "$(cat "$T/g3/stdin")" "https://api.telegram.org/bot$TOK/getUpdates?timeout=0"
hasnt "G10 no offset" "$(cat "$T/g3/stdin")" "offset"
eq "G10 one seam log line" "$(cat "$T/g3/real-calls.log" | cut -d' ' -f2-)" "telegram getUpdates"

# G4 — no update yet.
seed g4 '{"ok":true,"result":[]}'; chat g4 fake
eq "G4 rc 4" "$RC" 4; eq "G4 stdout empty" "$OUT" ""

# G5 — 150 updates; the newest is past 100.
seed g5 "$(msgs message $(seq 1 150))"; chat g5 fake
eq "G5 rc" "$RC" 0; eq "G5 id 150" "$OUT" 150

# G6 — the token is cut from a description and from a curl error.
stubcurl g6 "{\"ok\":false,\"description\":\"Not Found: https://api.telegram.org/bot$TOK/getUpdates ($TOK)\"}"; chat g6 real
eq "G6 rc 1" "$RC" 1; has "G6 cut" "$ERR" "bot<token>/getUpdates (<token>)"; hasnt "G6 no token" "$ERR$OUT" "$TOK"
stubcurl g6b "curl: (7) Failed to connect to https://api.telegram.org/bot$TOK/getUpdates" 7; chat g6b real
eq "G6b curl fail rc 1" "$RC" 1; has "G6b says curl" "$ERR" "curl rc 7"; hasnt "G6b no token" "$ERR$OUT" "$TOK"

# G7 — walk back past an edited_message.
seed g7 '{"ok":true,"result":[{"update_id":1,"message":{"chat":{"id":7}}},{"update_id":2,"edited_message":{"chat":{"id":99}}}]}'
chat g7 fake; eq "G7 rc" "$RC" 0; eq "G7 walks back to 7" "$OUT" 7

# G8 — only callback_query updates hold no chat we take.
seed g8 '{"ok":true,"result":[{"update_id":1,"callback_query":{"message":{"chat":{"id":5}}}}]}'
chat g8 fake; eq "G8 rc 4" "$RC" 4; eq "G8 no id" "$OUT" ""

# G9 — a non-integer id, a missing ok, a non-JSON body.
seed g9 '{"ok":true,"result":[{"update_id":1,"message":{"chat":{"id":"abc"}}}]}'
chat g9 fake; eq "G9 abc rc 1" "$RC" 1; eq "G9 abc stdout empty" "$OUT" ""
seed g9b '{"result":[{"update_id":1,"message":{"chat":{"id":5}}}]}'
chat g9b fake; eq "G9b no ok rc 1" "$RC" 1; eq "G9b stdout empty" "$OUT" ""
stubcurl g9c '<html>502 Bad Gateway</html>'; chat g9c real
eq "G9c non-JSON rc 1" "$RC" 1; eq "G9c stdout empty" "$OUT" ""; has "G9c bad answer" "$ERR" "telegram: bad answer"

# G11 — the argument is a NAME; an unset token; an unknown mode fails closed.
seed g11 "$(msgs message 1)"; chat g11 fake "tok"
eq "G11 lower-case name rc 2" "$RC" 2
chat g11 fake NO_SUCH_TOKEN_VAR; eq "G11 unset rc 3" "$RC" 3; has "G11 says not set" "$ERR" "NO_SUCH_TOKEN_VAR is not set"
stubcurl g11 '{"ok":true,"result":[]}'; chat g11 Fake
eq "G11 Fake rc 2" "$RC" 2; has "G11 says unknown" "$ERR" "vendor-mode: unknown 'Fake'"
eq "G11 Fake made no call" "$([ -f "$T/g11/argv" ] && echo called || echo none)" none

# G12 — an unseeded method.
mkdir -p "$T/g12/fake"; echo '{"getMe":{"ok":true}}' > "$T/g12/fake/telegram.json"; chat g12 fake
eq "G12 rc 70" "$RC" 70; has "G12 message" "$ERR" "vendor-fake: telegram.getUpdates not implemented"

# ---- the verb ----
H="$T/h"
mkdir -p "$H/logs" "$T/env"
scratch_install_closure bin/fleet-telegram-chat.sh "$H" >/dev/null || bad "install the verb closure"
cat > "$T/jobs-client.sh" <<'SH'
_jobs_req() {
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$CALLS"
  JOBS_HTTP=""; JOBS_BODY=""
  local n k
  case "$1 $2" in
    "PUT /api/settings")
      n=$(grep -c '^PUT ' "$CALLS"); k="PUT_HTTP_$n"
      JOBS_HTTP="${!k:-${PUT_HTTP:-200}}"
      case "$JOBS_HTTP" in 2*) ;; *) return 1 ;; esac
      jq -c --argjson b "$3" '[.[] | select(.key != $b.key)] + [$b]' "$ROWS_FILE" > "$ROWS_FILE.tmp" && mv "$ROWS_FILE.tmp" "$ROWS_FILE"
      JOBS_BODY='{"ok":true}'; printf '%s' "$JOBS_BODY"; return 0 ;;
    "GET /api/settings/"*)
      k="${2#/api/settings/}"
      JOBS_HTTP=200
      if [ -n "${GET_VALUE:-}" ]; then
        JOBS_BODY=$(jq -nc --arg k "$k" --arg v "$GET_VALUE" '{key:$k, setting:{key:$k, value:$v}}')
      else
        JOBS_BODY=$(jq -c --arg k "$k" '{key:$k, setting:(map(select(.key == $k)) | .[0] // null)}' "$ROWS_FILE")
      fi
      printf '%s' "$JOBS_BODY"; return 0 ;;
  esac
  return 1
}
SH
# verb <case> [args...] — the verb as an operator runs it. Sets OUT ERR RC.
# Env knobs: MODE (fake), TOKV (the token; empty = unset), PUT_HTTP, PUT_HTTP_2,
# GET_VALUE, NOCLIENT=1 (no bin/jobs-client.sh).
verb() {
  local c="$1"; shift
  mkdir -p "$T/$c"
  echo '[]' > "$T/$c/rows.json"; : > "$T/$c/calls"
  rm -f "$H/bin/jobs-client.sh"; [ -n "${NOCLIENT:-}" ] || cp "$T/jobs-client.sh" "$H/bin/jobs-client.sh"
  local -a tokenv=(-u TELEGRAM_BOT_TOKEN)
  [ -n "${TOKV-$TOK}" ] && tokenv=(TELEGRAM_BOT_TOKEN="${TOKV-$TOK}")
  local log="$VENDOR_CALL_LOG"; [ "${MODE:-fake}" = fake ] || log="$T/$c/real-calls.log"
  env "${tokenv[@]}" PATH="$T/$c/bin:$PATH" HARNESS="$H" HARNESS_ENV_DIR="${ENVDIR:-$T/env}" \
      HARNESS_VENDOR_MODE="${MODE:-fake}" VENDOR_FAKE_DIR="${FAKEDIR:-$T/$c/fake}" VENDOR_CALL_LOG="$log" \
      CALLS="$T/$c/calls" ROWS_FILE="$T/$c/rows.json" JOBS_URL=http://stub.invalid \
      PUT_HTTP="${PUT_HTTP:-200}" PUT_HTTP_2="${PUT_HTTP_2:-}" GET_VALUE="${GET_VALUE:-}" \
      "$H/bin/fleet-telegram-chat.sh" "$@" >"$T/$c/out" 2>"$T/$c/err"; RC=$?
  OUT=$(cat "$T/$c/out"); ERR=$(cat "$T/$c/err")
  ROWS=$(jq -r '.[] | "\(.key)=\(.value)"' "$T/$c/rows.json" 2>/dev/null)
  PUTS=$(grep -c '^PUT ' "$T/$c/calls")
}
lines() { grep -c . <<<"$1"; }

# V1 — the Observable outcome: the repo seed, the rows, the read-back, 0 calls.
FAKEDIR="$DIR/tests/fakes/vendor" verb v1
eq "V1 rc 0" "$RC" 0
eq "V1 exactly one line" "$OUT" "TELEGRAM_CHAT ok -1009990001"
has "V1 chat_id row" "$ROWS" "telegram.chat_id=-1009990001"
has "V1 bot_present row" "$ROWS" "telegram.bot_present=1"
has "V1 state row" "$ROWS" "telegram.state=ok"
eq "V1 actor" "$(jq -r '[.[].actor] | unique | join(",")' "$T/v1/rows.json")" fleet-telegram-chat
eq "V1 read back after the PUTs" "$(tail -1 "$T/v1/calls" | cut -d' ' -f1-2)" "GET /api/settings/telegram.chat_id"

# V2 — no update yet: the state row only.
seed v2 '{"ok":true,"result":[]}'; verb v2
eq "V2 rc 0" "$RC" 0
eq "V2 one line" "$OUT" "TELEGRAM_CHAT waiting no update yet: send any message to the bot, then check again"
eq "V2 rows" "$ROWS" "telegram.state=waiting_for_message"
hasnt "V2 no chat_id PUT" "$(cat "$T/v2/calls")" "telegram.chat_id"

# V3 — a webhook conflict: failed, no row.
stubcurl v3 '{"ok":false,"error_code":409,"description":"Conflict: can'"'"'t use getUpdates method while webhook is active"}'
MODE=real verb v3
eq "V3 rc 1" "$RC" 1; eq "V3 one line" "$(lines "$OUT")" 1
has "V3 failed + why" "$OUT" "TELEGRAM_CHAT failed telegram: Conflict"
eq "V3 0 PUTs" "$PUTS" 0

# V4 — the first PUT fails: stop, failed. V4b the second fails.
seed v4 "$(msgs message -42)"; PUT_HTTP=500 verb v4
eq "V4 rc 1" "$RC" 1; has "V4 failed" "$OUT" "TELEGRAM_CHAT failed PUT telegram.chat_id answered http=500"
hasnt "V4 never ok" "$OUT" "TELEGRAM_CHAT ok"; eq "V4 stopped after 1 PUT" "$PUTS" 1
seed v4b "$(msgs message -42)"; PUT_HTTP_2=500 verb v4b
eq "V4b rc 1" "$RC" 1; has "V4b failed" "$OUT" "TELEGRAM_CHAT failed PUT telegram.bot_present"
eq "V4b only chat_id written" "$ROWS" "telegram.chat_id=-42"

# V5 — the read-back answers another id.
seed v5 "$(msgs message -42)"; GET_VALUE=-1 verb v5
eq "V5 rc 1" "$RC" 1; has "V5 failed read-back" "$OUT" "TELEGRAM_CHAT failed read-back"
eq "V5 one line" "$(lines "$OUT")" 1

# V6 — no token in the environment or env/global.env.
seed v6 "$(msgs message -42)"; TOKV="" verb v6
eq "V6 rc 1" "$RC" 1; eq "V6 line" "$OUT" "TELEGRAM_CHAT failed telegram: TELEGRAM_BOT_TOKEN is not set"
eq "V6 0 PUTs" "$PUTS" 0
mkdir -p "$T/v6b/env"; echo 'export TELEGRAM_BOT_TOKEN="654321:tok-fixture-ENV"' > "$T/v6b/env/global.env"
seed v6b "$(msgs message -43)"; TOKV="" ENVDIR="$T/v6b/env" verb v6b
eq "V6b token from global.env -> ok" "$OUT" "TELEGRAM_CHAT ok -43"
hasnt "V6b token never printed" "$OUT$ERR" "tok-fixture-ENV"

# V7 — the verb takes no argument.
seed v7 "$(msgs message -42)"; verb v7 extra
eq "V7 rc 2" "$RC" 2; eq "V7 0 PUTs" "$PUTS" 0; has "V7 usage" "$OUT" "usage: bin/fleet-telegram-chat.sh"

# V8 — no jobs client.
seed v8 "$(msgs message -42)"; NOCLIENT=1 verb v8
eq "V8 rc 1" "$RC" 1; eq "V8 line" "$OUT" "TELEGRAM_CHAT failed jobs not configured"

# V9 — waiting, but the state PUT fails.
seed v9 '{"ok":true,"result":[]}'; PUT_HTTP=500 verb v9
eq "V9 rc 1" "$RC" 1; has "V9 failed" "$OUT" "TELEGRAM_CHAT failed PUT telegram.state answered http=500"

# V10 — a seam that answers rc 0 with a non-integer is not stored.
# Its own scratch tree, so the stub seam never reaches another case.
H="$T/h10"; mkdir -p "$H/logs"
scratch_install_closure bin/fleet-telegram-chat.sh "$H" >/dev/null || bad "V10 install the verb closure"
printf '%s\n' 'tg_latest_chat_id() { printf "12 junk\n"; return 0; }' > "$H/bin/lib/vendor/telegram.sh"
seed v10 "$(msgs message -42)"; verb v10
H="$T/h"
eq "V10 rc 1" "$RC" 1; has "V10 failed" "$OUT" "TELEGRAM_CHAT failed chat id"; eq "V10 0 PUTs" "$PUTS" 0

# V11 — an unknown vendor mode fails closed.
seed v11 "$(msgs message -42)"; MODE=Fake verb v11
eq "V11 rc 1" "$RC" 1; has "V11 failed" "$OUT" "TELEGRAM_CHAT failed vendor-mode: unknown 'Fake'"; eq "V11 0 PUTs" "$PUTS" 0

# V12 — syntax and shellcheck.
bash -n "$DIR/bin/fleet-telegram-chat.sh" && ok || bad "V12 bash -n"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S error "$DIR/bin/fleet-telegram-chat.sh" && ok || bad "V12 shellcheck"
else
  echo "SKIP shellcheck: not installed"
fi

eq "fake-mode cases made 0 vendor calls" "$(grep -c . "$VENDOR_CALL_LOG")" "$LOG0"

echo "telegram-chat-id.bh-7939: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
