#!/bin/bash
# tests/pm-tg-buttons.bh-8650-test.sh — BH-8650: the Telegram Approve/Reject
# keyboard message for a PM brief. The seam function tg_send_message
# (bin/lib/vendor/telegram.sh), the sender pmtb_send (bin/lib/pm-tg-buttons.sh),
# and its call from send() in bin/pm-groom.sh.
#
# Part A drives the lib with shell fakes for _jobs_req and the job_ledger_*
# functions. Part C drives the SHIPPED bin/pm-groom.sh against the REAL worker
# routes (pm-brief.js, pm-tg.js, ledger.js, ...) over a node:sqlite file built
# from the composed jobs schema, with the Telegram seam in fake mode. curl on
# PATH logs every call that is not the fake worker into net.log. Nothing here
# reaches Telegram.
#
#   S1  fake mode: tg_send_message prints the seeded sendMessage answer, 0
#       net.log lines, 0 VENDOR_CALL_LOG lines
#   S2  an unseeded fake method is rc 70
#   S3  real mode with a stub curl: exactly one `telegram sendMessage` call-log
#       line; the stub's argv holds neither the token nor the text; its stdin
#       config holds chat_id, message_thread_id, text and reply_markup
#   B1  happy path: `buttons=sent 77`, one ledger put pm_tg_buttons <p>:<w> sent,
#       and the markup is the keyboard GET's markup byte for byte
#   B2  the ledger already `sent`: buttons=skip already-sent, no seam call;
#       an unreadable ledger: buttons=skip ledger-unreadable, no seam call
#   B3  no token: buttons=skip not-configured, 0 _jobs_req and 0 ledger calls
#   B4  a Telegram refusal: `buttons=failed 400 Bad Request: x`, no ledger put;
#       through pm-groom.sh exactly one ALERTS line; each skip gives 0
#   B5  bin/lib/pm-tg-buttons.sh holds no curl and no api.telegram.org
#   B6  the fake-mode parts end with net.log and the inherited VENDOR_CALL_LOG
#       at 0 new lines
#   B7  an archie_tg detail made with archie-tg-send.sh's exact jq expression
#       (chat -100123, thread 7) gives a seam call with that chat and thread
#   B8  send() in bin/pm-groom.sh still writes one Mission Control link per
#       move, and calls pmtb_send after TG=sent and on no TG=failed path
#   B9  keyboard-read failure and no-moves / no-chat skips
#   B10 sent, but the ledger write failed: `buttons=sent 77 ledger-write-failed`
#   L1-L3  the lane end to end (Part C) with pm.tg_buttons_enabled=1: sent,
#          a refusal, and no token
#   L4  the seeded pm.tg_buttons_enabled=0: `buttons=skip disabled`, no
#       keyboard GET, no ledger row, 0 ALERTS
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pm-tg-buttons.bh-8650-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
command -v jq >/dev/null 2>&1 || { echo "pm-tg-buttons: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }
has() { if grep -qF -- "$3" <<<"$2"; then ok; else bad "$1: '$3' not in: $2"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1: '$3' unexpectedly in: $2"; else ok; fi; }
n() { local c; c=$(grep -c . "$1" 2>/dev/null); printf '%s' "${c:-0}"; }

LIB="$DIR/bin/lib/pm-tg-buttons.sh"
SEAM="$DIR/bin/lib/vendor/telegram.sh"
LANE="$DIR/bin/pm-groom.sh"
ROUTES="$DIR/worker/jobs/src/routes/pm-tg.js"
FRAG="$DIR/worker/jobs/schema.d/202610291811-bh-8650-pm-tg.sql"
RTAB="$DIR/worker/jobs/test/route-table.d/bh-8650-pm-tg.txt"
WTEST="$DIR/worker/jobs/test/pm-tg.bh-8650.test.js"
CONTRACT="$DIR/tests/contract/telegram-send.bh-8650.contract-test.sh"
ARCHIE="$DIR/bin/archie-tg-send.sh"
for f in "$LIB" "$SEAM" "$LANE" "$ROUTES" "$FRAG" "$RTAB" "$WTEST" "$CONTRACT" "$ARCHIE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
[ -f "$LIB" ] || { echo "pm-tg-buttons: $PASS passed, $FAIL failed"; exit 1; }
for f in "$LIB" "$SEAM" "$CONTRACT"; do bash -n "$f" && ok || bad "bash -n $f"; done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S error "$LIB" "$SEAM" "$CONTRACT" && ok || bad "shellcheck -S error"
fi

TOK='123456:tok-fixture-PMTB'
TEXT_SECRET='fixture text that must stay off argv'
VENDOR_CALL_LOG="${VENDOR_CALL_LOG:-$T/calls.log}"
export VENDOR_CALL_LOG
touch "$VENDOR_CALL_LOG"
LOG0=$(n "$VENDOR_CALL_LOG")

# A PATH curl for the fake-mode parts: every call is a defect, logged to net.log.
mkdir -p "$T/netbin"
cat > "$T/netbin/curl" <<SH
#!/bin/bash
printf 'curl %s\n' "\$*" >> "$T/net.log"
exit 99
SH
chmod +x "$T/netbin/curl"
: > "$T/net.log"

# ═════ Part A: the seam and pmtb_send with shell fakes ══════════════════════
A="$T/a"
mkdir -p "$A"
( cd "$DIR" && scratch_install_closure bin/lib/pm-tg-buttons.sh "$A" ) >/dev/null \
  || { echo "FAIL: scratch_install_closure bin/lib/pm-tg-buttons.sh"; exit 1; }
[ -f "$A/bin/lib/vendor/telegram.sh" ] && ok || bad "the lib's closure holds bin/lib/vendor/telegram.sh"
mkdir -p "$T/fake"
seed() { jq -nc --argjson s "$1" '{sendMessage: $s}' > "$T/fake/telegram.json"; }
SEED_OK='{"ok":true,"result":{"message_id":77,"chat":{"id":-100123}}}'

# S1 / S2 — fake mode.
seed "$SEED_OK"
out=$(env PATH="$T/netbin:$PATH" HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$T/fake" TELEGRAM_BOT_TOKEN="$TOK" \
  bash -c '. "$1" || exit 98; tg_send_message TELEGRAM_BOT_TOKEN -100123 7 "hi" "{}"' _ "$A/bin/lib/vendor/telegram.sh" 2>&1); rc=$?
eq "S1 fake mode rc" "$rc" 0
eq "S1 fake mode prints the seed" "$(jq -c . <<<"$out" 2>/dev/null)" "$SEED_OK"
echo '{}' > "$T/fake/telegram.json"
env PATH="$T/netbin:$PATH" HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$T/fake" TELEGRAM_BOT_TOKEN="$TOK" \
  bash -c '. "$1" || exit 98; tg_send_message TELEGRAM_BOT_TOKEN -100123 "" "hi"' _ "$A/bin/lib/vendor/telegram.sh" >/dev/null 2>&1; rc=$?
eq "S2 an unseeded sendMessage is rc 70" "$rc" 70
env PATH="$T/netbin:$PATH" HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$T/fake" \
  bash -c '. "$1" || exit 98; tg_send_message TELEGRAM_BOT_TOKEN -100123 "" "hi"' _ "$A/bin/lib/vendor/telegram.sh" >/dev/null 2>&1; rc=$?
eq "S2 no token is rc 3" "$rc" 3
env PATH="$T/netbin:$PATH" bash -c '. "$1" || exit 98; tg_send_message "bad name" 1 "" hi' _ "$A/bin/lib/vendor/telegram.sh" >/dev/null 2>&1; rc=$?
eq "S2 a bad variable name is rc 2" "$rc" 2
eq "S1 fake mode makes 0 net.log lines" "$(n "$T/net.log")" 0

# S3 — real mode with a stub curl that keeps argv and stdin.
S3="$T/s3"; mkdir -p "$S3/bin"
cat > "$S3/bin/curl" <<SH
#!/bin/bash
printf '%s\n' "\$*" >> "$S3/argv"
cat >> "$S3/stdin"
printf '%s' '{"ok":true,"result":{"message_id":5}}'
SH
chmod +x "$S3/bin/curl"
out=$(env PATH="$S3/bin:$PATH" HARNESS_VENDOR_FAKE=0 VENDOR_CALL_LOG="$S3/calls.log" TELEGRAM_BOT_TOKEN="$TOK" TELEGRAM_API_TIMEOUT_S=9 \
  bash -c '. "$1" || exit 98; tg_send_message TELEGRAM_BOT_TOKEN -100123 7 "$2" "$3"' _ "$A/bin/lib/vendor/telegram.sh" \
  "$TEXT_SECRET"$'\n''line "two" \ end' '{"inline_keyboard":[[{"text":"Approve 1","callback_data":"pm:a:x"}]]}' 2>&1); rc=$?
eq "S3 real mode rc" "$rc" 0
eq "S3 prints the raw answer" "$(jq -r '.result.message_id' <<<"$out" 2>/dev/null)" 5
eq "S3 exactly one seam call-log line" "$(grep -c ' telegram sendMessage$' "$S3/calls.log" 2>/dev/null)" 1
eq "S3 one curl call" "$(n "$S3/argv")" 1
argv=$(cat "$S3/argv" 2>/dev/null); stdin=$(cat "$S3/stdin" 2>/dev/null)
hasnt "S3 argv holds no token" "$argv" "$TOK"
hasnt "S3 argv holds no text" "$argv" "fixture text"
has "S3 argv bounds the time with the knob" "$argv" "--max-time 9"
has "S3 the config names sendMessage" "$stdin" "/bot$TOK/sendMessage\""
has "S3 the config holds chat_id" "$stdin" 'form-string = "chat_id=-100123"'
has "S3 the config holds the thread" "$stdin" 'form-string = "message_thread_id=7"'
has "S3 the config escapes the text" "$stdin" "form-string = \"text=$TEXT_SECRET\\nline \\\"two\\\" \\\\ end\""
has "S3 the config holds the markup" "$stdin" 'form-string = "reply_markup={\"inline_keyboard\":[[{\"text\":\"Approve 1\",\"callback_data\":\"pm:a:x\"}]]}"'
# No thread: no message_thread_id line. A curl failure: rc 1, the token cut.
: > "$S3/stdin"
env PATH="$S3/bin:$PATH" HARNESS_VENDOR_FAKE=0 VENDOR_CALL_LOG="$S3/calls.log" TELEGRAM_BOT_TOKEN="$TOK" \
  bash -c '. "$1" || exit 98; tg_send_message TELEGRAM_BOT_TOKEN -100123 "" hi' _ "$A/bin/lib/vendor/telegram.sh" >/dev/null 2>&1
hasnt "S3 no thread, no message_thread_id" "$(cat "$S3/stdin")" "message_thread_id"
printf '#!/bin/bash\ncat >/dev/null\necho "curl: (6) cannot reach bot%s/sendMessage"\nexit 6\n' "$TOK" > "$S3/bin/curl"
out=$(env PATH="$S3/bin:$PATH" HARNESS_VENDOR_FAKE=0 VENDOR_CALL_LOG="$S3/calls.log" TELEGRAM_BOT_TOKEN="$TOK" \
  bash -c '. "$1" || exit 98; tg_send_message TELEGRAM_BOT_TOKEN -100123 "" hi' _ "$A/bin/lib/vendor/telegram.sh" 2>&1); rc=$?
eq "S3 a curl failure is rc 1" "$rc" 1
hasnt "S3 the curl error does not hold the token" "$out" "$TOK"

# The fakes. Files under $A/f: kb.json/kb.rc (the keyboard GET), ledger.<kind>
# (status), ledger.<kind>.rc, archie.json (the job_ledger_row answer).
F="$A/f"
cat > "$A/fakes.sh" <<'SH'
_jobs_req() { printf '%s %s\n' "$1" "$2" >> "$F/jobs.log"; cat "$F/kb.json" 2>/dev/null; return "$(cat "$F/kb.rc" 2>/dev/null || echo 0)"; }
job_ledger_get() {
  printf 'get %s %s\n' "$1" "$2" >> "$F/ledger.log"
  [ -f "$F/ledger.$1.rc" ] && return "$(cat "$F/ledger.$1.rc")"
  [ -f "$F/ledger.$1" ] || return 2
  cat "$F/ledger.$1"
}
job_ledger_row() {
  printf 'row %s %s\n' "$1" "$2" >> "$F/ledger.log"
  [ -f "$F/row.$1" ] || return 2
  cat "$F/row.$1"
}
job_ledger_put() { printf 'put %s %s %s %s\n' "$1" "$2" "$3" "${4:-}" >> "$F/puts.log"; return "$(cat "$F/put.rc" 2>/dev/null || echo 0)"; }
SH
# The spy keeps the arguments of every seam call and then runs the real seam.
cat > "$A/spy.sh" <<'SH'
eval "real_tg_send_message() $(declare -f tg_send_message | tail -n +2)"
tg_send_message() {
  printf '%s\n' "$@" > "$F/seam.args"
  printf '%s\n' "$5" > "$F/seam.markup"
  echo call >> "$F/seam.calls"
  real_tg_send_message "$@"
}
SH
KB=$(jq -nc '{project:"pa", week:"2026-W43", buttons_max:25,
  moves:[{n:1,id:"m1"},{n:2,id:"m2"}], omitted:[], text:"Decide the 2026-W43 moves for pa. Each button acts once.\n1. A: ideas -> next",
  reply_markup:{inline_keyboard:[[{text:"Approve 1",callback_data:"pm:a:m1:sig"},{text:"Reject 1",callback_data:"pm:r:m1:sig"}],
                                [{text:"Approve 2",callback_data:"pm:a:m2:sig"},{text:"Reject 2",callback_data:"pm:r:m2:sig"}]]}}')
# B7: the detail is made with the exact jq expression of bin/archie-tg-send.sh.
ARCHIE_JQ='{chat: $c, thread: (if $t == "" then null else $t end), message_ids: $m, chunks: $n, at: $at}'
grep -qF -- "'$ARCHIE_JQ'" "$ARCHIE" && ok || bad "B7 bin/archie-tg-send.sh still writes its detail with: $ARCHIE_JQ"
archie_detail() { jq -nc --arg c "$1" --arg t "$2" --argjson m '[901]' --argjson n 1 --arg at 2026-10-19T11:05:00Z "$ARCHIE_JQ"; }
# fresh: reset the fakes to a happy path.
fresh() {
  scratch_rm "$F" || exit 1; mkdir -p "$F"
  printf '%s' "$KB" > "$F/kb.json"
  jq -nc --arg d "$(archie_detail -100123 7)" '{status:"sent", detail:$d}' > "$F/row.archie_tg"
  seed "$SEED_OK"
}
# pmtb [VAR=value...]: one pmtb_send pa 2026-W43 in fake mode; its line in $F/out.
pmtb() {
  env PATH="$T/netbin:$PATH" HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$T/fake" F="$F" TELEGRAM_BOT_TOKEN="$TOK" "$@" \
    bash -c '. "$1" || exit 98; . "$2"; . "$3"; pmtb_send pa 2026-W43' _ "$A/bin/lib/pm-tg-buttons.sh" "$A/fakes.sh" "$A/spy.sh" > "$F/out" 2>"$F/err"
  echo $? > "$F/rc"
}

# B1 — the happy path.
fresh; pmtb
eq "B1 rc 0" "$(cat "$F/rc")" 0
eq "B1 the outcome line" "$(cat "$F/out")" "buttons=sent 77"
eq "B1 one keyboard GET" "$(cat "$F/jobs.log")" "GET /api/pm/moves/tg-keyboard?project=pa&week=2026-W43"
eq "B1 one ledger put" "$(n "$F/puts.log")" 1
eq "B1 the put is pm_tg_buttons pa:2026-W43 sent" "$(cut -d' ' -f1-4 "$F/puts.log")" "put pm_tg_buttons pa:2026-W43 sent"
eq "B1 the put detail" "$(cut -d' ' -f5- "$F/puts.log" | jq -c '{chat, message_id, moves}')" '{"chat":"-100123","message_id":77,"moves":2}'
eq "B1 the markup is the GET's markup byte for byte" "$(cat "$F/seam.markup")" "$(jq -c .reply_markup <<<"$KB")"
eq "B1 the text is the GET's text" "$(sed -n 4,5p "$F/seam.args")" "$(jq -r .text <<<"$KB")"
eq "B1 the token travels by name" "$(sed -n 1p "$F/seam.args")" TELEGRAM_BOT_TOKEN
# B7 — the chat and the thread of the brief text.
eq "B7 the chat of the brief" "$(sed -n 2p "$F/seam.args")" "-100123"
eq "B7 the thread of the brief" "$(sed -n 3p "$F/seam.args")" "7"
eq "B7 the archie_tg row key" "$(grep '^row ' "$F/ledger.log")" "row archie_tg pm-brief:pa:2026-W43"
fresh; jq -nc --arg d "$(archie_detail 555 "")" '{status:"sent", detail:$d}' > "$F/row.archie_tg"; pmtb
eq "B7 no thread: an empty thread argument" "$(sed -n 2,3p "$F/seam.args" | paste -sd'|')" "555|"

# B2 — already sent, or a ledger that cannot be read: no seam call.
fresh; echo sent > "$F/ledger.pm_tg_buttons"; pmtb
eq "B2 already-sent" "$(cat "$F/out")" "buttons=skip already-sent"
eq "B2 already-sent makes no seam call" "$(n "$F/seam.calls")" 0
eq "B2 already-sent makes no keyboard GET" "$(n "$F/jobs.log")" 0
fresh; echo 1 > "$F/ledger.pm_tg_buttons.rc"; pmtb
eq "B2 ledger-unreadable" "$(cat "$F/out")" "buttons=skip ledger-unreadable"
eq "B2 ledger-unreadable makes no seam call" "$(n "$F/seam.calls")" 0

# B3 — no token: nothing at all.
fresh; pmtb TELEGRAM_BOT_TOKEN=
eq "B3 not-configured" "$(cat "$F/out")" "buttons=skip not-configured"
eq "B3 0 _jobs_req" "$(n "$F/jobs.log")" 0
eq "B3 0 ledger calls" "$(n "$F/ledger.log")" 0

# B4 — a Telegram refusal.
fresh; seed '{"ok":false,"error_code":400,"description":"Bad Request: x"}'; pmtb
eq "B4 the failed line" "$(cat "$F/out")" "buttons=failed 400 Bad Request: x"
eq "B4 no ledger put" "$(n "$F/puts.log")" 0
fresh; seed "{\"ok\":false,\"error_code\":400,\"description\":\"$(printf 'd%.0s' $(seq 1 300))\"}"; pmtb
eq "B4 the description is cut to 120" "$(cat "$F/out")" "buttons=failed 400 $(printf 'd%.0s' $(seq 1 120))"
fresh; seed '{"ok":true,"result":{"message_id":"77"}}'; pmtb
eq "B4 a message_id that is not a number is a failure" "$(cut -d' ' -f1 "$F/out")" "buttons=failed"
eq "B4 ... and no ledger put" "$(n "$F/puts.log")" 0
fresh; echo '{}' > "$T/fake/telegram.json"; pmtb
eq "B4 a seam error is a failure" "$(cat "$F/out")" "buttons=failed seam rc=70"

# B9 — the keyboard read, no moves, no chat.
fresh; echo 1 > "$F/kb.rc"; pmtb
eq "B9 keyboard-read" "$(cat "$F/out")" "buttons=failed keyboard-read"
fresh; echo 'not json' > "$F/kb.json"; pmtb
eq "B9 an answer that is not the keyboard" "$(cat "$F/out")" "buttons=failed keyboard-read"
fresh; jq -c '.moves = [] | .reply_markup.inline_keyboard = []' <<<"$KB" > "$F/kb.json"; pmtb
eq "B9 no-moves" "$(cat "$F/out")" "buttons=skip no-moves"
eq "B9 no-moves makes no seam call" "$(n "$F/seam.calls")" 0
fresh; rm -f "$F/row.archie_tg"; pmtb
eq "B9 no-chat" "$(cat "$F/out")" "buttons=skip no-chat"
eq "B9 no-chat makes no seam call" "$(n "$F/seam.calls")" 0
fresh; jq -nc '{status:"sent", detail:""}' > "$F/row.archie_tg"; pmtb
eq "B9 a row with no detail is no-chat" "$(cat "$F/out")" "buttons=skip no-chat"
# B10 — sent, but the ledger write failed: the message is out, so it is not a failure line.
fresh; echo 1 > "$F/put.rc"; pmtb
eq "B10 sent with a failed ledger write" "$(cat "$F/out")" "buttons=sent 77 ledger-write-failed"
eq "B10 one put was tried" "$(n "$F/puts.log")" 1
# Sourcing the lib prints nothing.
eq "A the lib sources silently" "$(bash -c '. "$1"' _ "$A/bin/lib/pm-tg-buttons.sh" 2>&1)" ""

# ═════ Part B: static checks ═════════════════════════════════════════════════
# B5 — every send goes through the seam.
eq "B5 the lib names no curl and no api.telegram.org" "$(grep -vE '^[[:space:]]*#' "$LIB" | grep -cE 'curl|api\.telegram\.org')" 0
has "B5 the lib sends with tg_send_message" "$(grep -vE '^[[:space:]]*#' "$LIB")" "tg_send_message TELEGRAM_BOT_TOKEN"
# B8 — send() in pm-groom.sh.
SEND=$(awk '/^send\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$LANE")
has "B8 send() still writes one Mission Control link per move" "$SEND" 'link("&move=" + $mid)'
has "B8 send() calls pmtb_send" "$SEND" 'pmtb_send "$P" "$WEEK"'
eq "B8 pmtb_send runs only on the TG=sent branch" \
  "$(awk '/TG=sent/{s=1} /TG=failed/{s=0} /pmtb_send "\$P"/{print (s ? "sent" : "other")}' <<<"$SEND" | sort -u | paste -sd,)" "sent"
eq "B8 the lane sources the lib" "$(grep -c '^ *\. "\$SELF/lib/pm-tg-buttons.sh"' "$LANE")" 1

# ═════ Part C: the lane end to end ═══════════════════════════════════════════
if ! command -v node >/dev/null 2>&1 || ! node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  echo "pm-tg-buttons: Part C SKIPPED — node with node:sqlite is not installed on this box"
else
  NOW=2026-10-19T11:05:00Z
  NOW_S=$(date -u -d "$NOW" +%s)
  WEEK=2026-W43
  C="$T/c"; H="$C/h"
  mkdir -p "$H/env" "$H/logs" "$H/flags" "$H/bin" "$H/prompts/product-stages" "$C/fakebin" "$H/catalog"
  for L in bin/pm-groom.sh bin/jobs-client.sh; do
    ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "FAIL: scratch_install_closure $L"; exit 1; }
  done
  [ -f "$H/bin/lib/pm-tg-buttons.sh" ] && ok || bad "L the lane's closure holds bin/lib/pm-tg-buttons.sh"
  cp "$DIR/prompts/product-stages/pm-groom.md" "$H/prompts/product-stages/pm-groom.md"
  cp "$DIR/catalog/lanes.json" "$H/catalog/"
  : > "$H/env/global.env"
  cat > "$C/q.mjs" <<'JS'
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync(process.env.FXT + '/d1.sqlite');
const [sql, ...binds] = process.argv.slice(2);
const st = db.prepare(sql);
if (/^\s*(select|with)/i.test(sql)) console.log(JSON.stringify(st.all(...binds)));
else { st.run(...binds); console.log('[]'); }
JS
  cat > "$C/mkdb.mjs" <<JS
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
const db = new DatabaseSync(process.argv[2]);
db.exec(readFileSync('$DIR/worker/jobs/schema.sql', 'utf8'));
JS
  # The worker: the REAL route families this lane and this lib call.
  cat > "$C/wdrv.mjs" <<'JS'
import { DatabaseSync } from 'node:sqlite';
import { appendFileSync, readFileSync } from 'node:fs';
const W = process.env.PG_WORKER_DIR;
const { d1 } = await import(`${W}/test/lib/d1-sqlite.bh-1030.js`);
const { matchRoute } = await import(`${W}/src/lib/router.js`);
const routes = [];
for (const f of ['settings', 'roadmap-ideas', 'pm-brief', 'pm-tg', 'ledger', 'model-routes']) {
  routes.push(...(await import(`${W}/src/routes/${f}.js`)).routes);
}
const [method, pathq, bodyFile] = process.argv.slice(2);
let raw = '';
if (bodyFile) { try { raw = readFileSync(bodyFile, 'utf8'); } catch { raw = ''; } }
appendFileSync(`${process.env.FXT}/reqlog`, `${method} ${pathq}\n`);
const url = new URL('https://jobs.test' + pathq);
let body = null;
if (raw) { try { body = JSON.parse(raw); } catch { body = null; } }
const hit = matchRoute(routes, method, url.pathname);
if (!hit) { process.stdout.write(JSON.stringify({ error: 'unknown endpoint', worker: 'harness-jobs' }) + '\n404'); process.exit(0); }
const db = new DatabaseSync(`${process.env.FXT}/d1.sqlite`, { timeout: 10000 });
const res = await hit.handler({ env: { DB: d1(db), HARNESS_SECRET: process.env.HARNESS_SECRET }, url, path: url.pathname, t: process.env.FXT_NOW, body: body || {}, m: hit.m });
process.stdout.write(await res.text() + '\n' + res.status);
JS
  cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
cat "${PG_ANSWER:-/dev/null}" > "$5"
SH
  cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
while [ $# -gt 1 ]; do case "$1" in --severity|--id|--project) shift 2 ;; *) break ;; esac; done
printf '%s %s\n' "$(date -u '+%F %TZ')" "$1" >> "$HARNESS/logs/ALERTS.log"
SH
  # archie-tg-send: records the brief text's delivery the way the real script
  # does (step 5), through the real jobs client, with the same jq expression.
  cat > "$H/bin/archie-tg-send.sh" <<SH
#!/bin/bash
. "\$HARNESS/bin/jobs-client.sh"
printf '%s\n' "\$2" > "\$FXT/tg.text"
d=\$(jq -nc --arg c "-100123" --arg t "7" --argjson m '[901]' --argjson n 1 --arg at "$NOW" '$ARCHIE_JQ')
job_ledger_put archie_tg "\$1" sent "\$d" >/dev/null 2>&1
SH
  cat > "$C/fakebin/curl" <<'SH'
#!/bin/bash
method=GET; data=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data-binary|-d|--data) data="$2"; [ "$method" = GET ] && method=POST; shift 2 ;;
    -o|-w|-H|-m|--max-time|--connect-timeout) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  "$JOBS_URL"/*)
    bf=""
    if [ -n "$data" ]; then
      bf=$(mktemp "$FXT/body.XXXXXX")
      case "$data" in @*) cp "${data#@}" "$bf" ;; *) printf '%s' "$data" > "$bf" ;; esac
    fi
    nt=$(mktemp -d "$FXT/nodetmp.XXXXXX")
    TMPDIR="$nt" node "$FXT/wdrv.mjs" "$method" "${url#"$JOBS_URL"}" "$bf"
    rc=$?; [ -n "$bf" ] && rm -f "$bf"; rm -rf "$nt"; exit "$rc" ;;
esac
printf 'curl %s\n' "$url" >> "$FXT/net.log"
exit 7
SH
  chmod +x "$H/bin/agent-call.sh" "$H/bin/alert-line.sh" "$H/bin/archie-tg-send.sh" "$C/fakebin/curl"
  export FXT="$C" FXT_NOW="$NOW" PG_WORKER_DIR="$DIR/worker/jobs" NODE_NO_WARNINGS=1
  node "$C/mkdb.mjs" "$C/d1.template.sqlite" 2> "$C/mkdb.err" || { echo "FAIL: the schema does not apply: $(head -3 "$C/mkdb.err")"; exit 1; }
  q() { node "$C/q.mjs" "$@"; }
  : > "$C/net.log"
  ALF="$H/logs/ALERTS.log"; LOGF="$H/logs/pm-groom.log"
  # lane <project> [VAR=value...]: a fresh database, 2 ideas, a 2-move answer, one run.
  # TGB (default 1) is the value of the settings row pm.tg_buttons_enabled;
  # TGB=seed keeps the seeded row.
  lane() {
    local p="$1"; shift
    cp "$C/d1.template.sqlite" "$C/d1.sqlite"; : > "$C/reqlog"
    [ "${TGB:-1}" = seed ] || q "UPDATE settings SET value=? WHERE key='pm.tg_buttons_enabled'" "${TGB:-1}" >/dev/null
    scratch_rm "$H/locks" || exit 1; scratch_rm "$H/state" || exit 1; rm -f "$H/logs/"*
    for i in 1 2; do
      q "INSERT INTO roadmap_ideas (id, project, title, source, lane, version, created_by, created_at, updated_at) VALUES (?, ?, ?, 'operator', 'ideas', 1, 'operator', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')" \
        "$p-$i" "$p" "Idea $p-$i" >/dev/null
    done
    jq -nc --arg a "$p-1" --arg b "$p-2" '{summary:"Two stale ideas.", moves:[
        {idea_id:$a, from_col:"ideas", to_col:"next", reason:"fixture", evidence:["stale.\($a)"]},
        {idea_id:$b, from_col:"ideas", to_col:"discarded", reason:"fixture", evidence:["stale.\($b)"]}], now:[], next_wave:[]}' > "$C/answer.json"
    env -u PM_MODEL -u CONSOLE_PAGES_URL PATH="$C/fakebin:$PATH" HARNESS="$H" JOBS_URL=https://jobs.test HARNESS_SECRET=tok-fixture-bh8650 JOBS_RETRIES=0 \
      HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 PM_GROOM_NOW="$NOW_S" PG_ANSWER="$C/answer.json" \
      HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$T/fake" TELEGRAM_BOT_TOKEN="$TOK" "$@" \
      bash "$H/bin/pm-groom.sh" "$p" > "$C/out" 2>&1
    echo $? > "$C/rc"
  }
  alerts() { local c; c=$(grep -c 'pm-groom' "$ALF" 2>/dev/null); printf '%s' "${c:-0}"; }

  # L1 — sent: the brief text, then the keyboard message, then its ledger row.
  seed "$SEED_OK"
  lane pl1
  eq "L1 rc 0 ($(cat "$C/out"))" "$(cat "$C/rc")" 0
  eq "L1 the lane logs buttons=sent 77" "$(grep -c 'buttons=sent 77$' "$LOGF" 2>/dev/null)" 1
  eq "L1 the summary line still says tg=sent" "$(grep -c ' tg=sent rc=0$' "$LOGF" 2>/dev/null)" 1
  eq "L1 one keyboard GET for the week" "$(grep -c "^GET /api/pm/moves/tg-keyboard?project=pl1&week=$WEEK$" "$C/reqlog")" 1
  eq "L1 the GET comes after POST /sent" "$(grep -nE '^(POST /api/pm/briefs/sent|GET /api/pm/moves/tg-keyboard)' "$C/reqlog" | cut -d' ' -f2 | paste -sd,)" \
    "/api/pm/briefs/sent,/api/pm/moves/tg-keyboard?project=pl1&week=$WEEK"
  eq "L1 the pm_tg_buttons row" "$(q "SELECT status FROM ledgers WHERE kind='pm_tg_buttons' AND key=?" "pl1:$WEEK" | jq -r '.[0].status // "none"')" sent
  eq "L1 its detail" "$(q "SELECT detail FROM ledgers WHERE kind='pm_tg_buttons' AND key=?" "pl1:$WEEK" | jq -c '.[0].detail | fromjson | {chat, message_id, moves}')" \
    '{"chat":"-100123","message_id":77,"moves":2}'
  eq "L1 0 ALERTS lines" "$(alerts)" 0
  eq "L1 the brief text keeps one Mission Control link per move" "$(grep -c "/roadmap/pl1?view=brief&week=$WEEK&move=" "$C/tg.text")" 2

  # L2 — Telegram refuses the keyboard message: exactly one ALERTS line.
  seed '{"ok":false,"error_code":400,"description":"Bad Request: x"}'
  lane pl2
  eq "L2 rc 0" "$(cat "$C/rc")" 0
  eq "L2 the lane logs the failure" "$(grep -c 'buttons=failed 400 Bad Request: x$' "$LOGF" 2>/dev/null)" 1
  eq "L2 exactly one ALERTS line" "$(alerts)" 1
  has "L2 the ALERTS line says the links still work" "$(cat "$ALF")" "the Mission Control links still work"
  eq "L2 no pm_tg_buttons row" "$(q "SELECT COUNT(*) AS n FROM ledgers WHERE kind='pm_tg_buttons'" | jq -r '.[0].n')" 0
  eq "L2 sent_tg is still 1" "$(q "SELECT sent_tg FROM pm_briefs WHERE project='pl2'" | jq -r '.[0].sent_tg')" 1

  # L3 — no token: one skip line, 0 ALERTS, no keyboard GET.
  seed "$SEED_OK"
  lane pl3 TELEGRAM_BOT_TOKEN=
  eq "L3 rc 0" "$(cat "$C/rc")" 0
  eq "L3 the skip line" "$(grep -c 'buttons=skip not-configured$' "$LOGF" 2>/dev/null)" 1
  eq "L3 0 ALERTS lines" "$(alerts)" 0
  eq "L3 no keyboard GET" "$(grep -c 'tg-keyboard' "$C/reqlog")" 0

  # L4 — the seeded row pm.tg_buttons_enabled=0: no keyboard read, no send, 0 ALERTS.
  seed "$SEED_OK"
  TGB=seed lane pl4
  eq "L4 the schema seeds pm.tg_buttons_enabled=0" "$(q "SELECT value FROM settings WHERE key='pm.tg_buttons_enabled'" | jq -r '.[0].value // "none"')" 0
  eq "L4 rc 0" "$(cat "$C/rc")" 0
  eq "L4 the skip line" "$(grep -c 'buttons=skip disabled (settings pm.tg_buttons_enabled=0)$' "$LOGF" 2>/dev/null)" 1
  eq "L4 the brief text still went out" "$(grep -c ' tg=sent rc=0$' "$LOGF" 2>/dev/null)" 1
  eq "L4 no keyboard GET" "$(grep -c 'tg-keyboard' "$C/reqlog")" 0
  eq "L4 no pm_tg_buttons row" "$(q "SELECT COUNT(*) AS n FROM ledgers WHERE kind='pm_tg_buttons'" | jq -r '.[0].n')" 0
  eq "L4 0 ALERTS lines" "$(alerts)" 0
  eq "L the lane runs made 0 net.log lines" "$(n "$C/net.log")" 0
fi

# B6 — the whole file made no vendor call in fake mode.
eq "B6 net.log has 0 lines" "$(n "$T/net.log")" 0
eq "B6 the inherited VENDOR_CALL_LOG gained 0 lines" "$(n "$VENDOR_CALL_LOG")" "$LOG0"

# The worker half of this ticket (D41: every new source is named above).
if command -v node >/dev/null 2>&1 && node -e 'require("node:sqlite")' >/dev/null 2>&1; then
  ( cd "$DIR/worker/jobs" && node --test test/pm-tg.bh-8650.test.js ) > "$T/node.out" 2>&1 && ok \
    || { bad "worker/jobs/test/pm-tg.bh-8650.test.js"; grep -E '^not ok|AssertionError' "$T/node.out" | head -20; }
fi

echo "pm-tg-buttons: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
