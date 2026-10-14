#!/bin/bash
# tests/archie-dm.bh-4779-test.sh — BH-4779: Archie's messages go to the operator's DM
# as ONE Telegram message each, through the SHIPPED bin/archie-tg-send.sh, and a
# no-action answer (or a blank-note follow-up) sends nothing.
#
# WHAT RUNS REAL. bin/archie-tg-send.sh, bin/archie.sh (the tick, with
# bin/lib/archie.sh and bin/lib/archie-wake.sh) and bin/daily-digest.sh, from a
# scratch harness ($H: a symlink tree of the repo's bin/, a copy of
# catalog/lanes.d and the prompts). Stubbed:
#   bin/agent-call.sh  counts calls, answers $T/ac.text;
#   bin/beat.sh        appends its payload to $T/beats.jsonl (nothing from
#                      Archie may reach it: C5 / D2);
#   bin/alert-line.sh / bin/lane-alert.sh append to $T/alerts.log.
# ARCHIE_FIXTURE=$T/fx.sh is the jobs worker for the Archie half (a jq model of
# initiatives, events, ledger and /api/settings over $T/db.json); the real
# bin/archie-tg-send.sh inherits it through the environment. The daily-digest
# half runs the real jobs client against $T/fakebin/curl's jobs arm.
# $T/fakebin/curl is Telegram when called with `-K -`: it reads the url from
# stdin, appends {url_has_sendMessage, chat_id, message_thread_id, text} to
# $T/tg.jsonl, logs its argv to $T/net.argv and a `TG` marker into $T/reqlog,
# and answers $T/tg.answer (default ok, message_id 101), or exits 7 when
# $T/tg.down exists. The clock is ARCHIE_NOW / DAILY_DIGEST_NOW, fixed.
#
# Cases S1-S7 (transport), C1-C6 (check path), N1-N4 (no-action guard), F1-F2
# (follow-ups), Q1-Q2 (quiet hours / cap), B1-B2 (mutations, D1), R1 (prompt),
# D1-D4 (daily digest) are the plan's acceptance tests.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-dm.bh-4779-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "archie-dm: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

# The product paths this ticket ships (D41).
for f in "$DIR/bin/archie-tg-send.sh" "$DIR/bin/archie.sh" "$DIR/bin/lib/archie-wake.sh" \
         "$DIR/bin/lib/archie.sh" "$DIR/bin/daily-digest.sh" "$DIR/catalog/lanes.d/archie.json" \
         "$DIR/catalog/prompts/archie-check.md"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
check "the transport is executable" '[ -x "$DIR/bin/archie-tg-send.sh" ]'

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/catalog/prompts" "$H/prompts" "$H/env" "$H/logs" "$T/fakebin"
cp -rs "$DIR/bin" "$H/bin"
cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
[ -d "$DIR/catalog/switches.d" ] && cp -r "$DIR/catalog/switches.d" "$H/catalog/"
cp -r "$DIR/prompts/archie-soul.d" "$H/prompts/"
cp "$DIR/catalog/prompts/archie-check.md" "$H/catalog/prompts/"
TOKEN_ENV='TELEGRAM_BOT_TOKEN=fixture-token'
printf '%s\n' "$TOKEN_ENV" > "$H/env/global.env"
rm -f "$H/bin/agent-call.sh" "$H/bin/beat.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s|%s\n' "$*" "${AGENT_CALL_FP:-}" >> "$FXT/agentcalls"
cat "$FXT/ac.text" > "$5"
exit 0
SH
cat > "$H/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$FXT/beats.jsonl"
exit 0
SH
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts.log"
exit 0
SH
cp "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
chmod +x "$H/bin/agent-call.sh" "$H/bin/beat.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"

# curl: Telegram on `-K -`, the jobs worker for the daily-digest half, and a
# refusal (logged to net.log) for anything else.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
ud() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }
kstdin=0; prev=""; chat=""; thread=""; text=""; m=GET; body=""; wfmt=0
for a in "$@"; do
  case "$prev" in
    -K) [ "$a" = - ] && kstdin=1 ;;
    -X) m="$a" ;;
    --data-binary|-d) body="$a" ;;
    -w) wfmt=1 ;;
    --data-urlencode)
      case "$a" in
        chat_id=*) chat="${a#chat_id=}" ;;
        message_thread_id=*) thread="${a#message_thread_id=}" ;;
        text=*) text="${a#text=}" ;;
      esac ;;
  esac
  prev="$a"
done
if [ "$kstdin" = 1 ]; then
  printf '%s\n' "$*" >> "$FXT/net.argv"
  cfg=$(cat)
  printf 'TG sendMessage\n' >> "$FXT/reqlog"
  [ -f "$FXT/tg.down" ] && exit 7
  jq -nc --arg c "$chat" --arg th "$thread" --arg t "$text" --arg u "$cfg" \
    '{url_has_sendMessage: ($u | test("^url = \"https://api\\.telegram\\.org/bot[^\"]+/sendMessage\"")),
      url_has_token: ($u | contains("fixture-token")), chat_id: $c, message_thread_id: $th, text: $t}' >> "$FXT/tg.jsonl"
  cat "$FXT/tg.answer" 2>/dev/null || printf '{"ok":true,"result":{"message_id":101}}'
  exit 0
fi
case "$body" in @*) body=$(cat "${body#@}") ;; esac
url="${!#}"
case "$url" in "${JOBS_URL:-x}"*) ;; *) printf 'curl %s\n' "$*" >> "$FXT/net.log"; exit 7 ;; esac
[ -f "$FXT/dd.on" ] || { printf 'curl %s\n' "$*" >> "$FXT/net.log"; exit 7; }
path="${url#"$JOBS_URL"}"
case "$path" in /api/settings*|/api/flags*|/api/lanes*) ;; *) printf '%s %s %s\n' "$m" "$path" "$body" >> "$FXT/reqlog" ;; esac
code=200; out='{"ok":true}'
case "$m $path" in
  "GET /api/settings"*) out='{"settings":[]}' ;;
  *" /api/ledger"*)
    if [ "$m" = GET ]; then
      k=$(ud "$(printf '%s' "$path" | sed -n 's/.*[?&]kind=\([^&]*\).*/\1/p')")
      v=$(ud "$(printf '%s' "$path" | sed -n 's/.*[?&]key=\([^&]*\).*/\1/p')")
      row=$(jq -c --arg i "$k/$v" '.[$i] // empty' "$FXT/ledger.json")
      if [ -n "$row" ]; then out=$(jq -nc --argjson r "$row" '{ledger: $r}'); else code=404; out='{"error":"not found"}'; fi
    else
      jq --argjson b "$body" '.[$b.kind + "/" + $b.key] = {status: $b.status, detail: ($b.detail // "")}' \
        "$FXT/ledger.json" > "$FXT/ledger.tmp" && mv "$FXT/ledger.tmp" "$FXT/ledger.json"
    fi ;;
  "GET /api/metrics/daily-digest"*) out=$(cat "$FXT/route.json") ;;
  "GET "*) code=404; out='{"error":"not found"}' ;;
esac
printf '%s' "$out"
[ "$wfmt" = 1 ] && printf '\n%s' "$code"
exit 0
SH
chmod +x "$T/fakebin/curl"

# The worker for the Archie half, modelled in jq over $T/db.json (the shape of
# tests/archie-wakeups.bh-4063-test.sh's, plus a settings arm and a one-shot
# refusal of the `sent` write). _jobs_req's rc contract: 0 on a 2xx, 9 on 409,
# 2 on 404, 1 on anything else.
cat > "$T/fx.sh" <<'SH'
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" out code=200 id k t
  JOBS_HTTP=""; JOBS_BODY=""
  case "$p" in /api/settings*|/api/flags*|/api/lanes*)
    [ "$p" = /api/settings ] && { cat "$FXT/settings.json" 2>/dev/null || printf '{"settings":[]}'; JOBS_HTTP=200; return 0; }
    JOBS_HTTP=404; return 2 ;;
  esac
  printf '%s %s %s\n' "$m" "$p" "$b" >> "$FXT/reqlog"
  [ -f "$FXT/jobs.down" ] && { JOBS_HTTP=503; return 1; }
  ud() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }
  qp() { ud "$(printf '%s' "$p" | sed -n "s/.*[?&]$1=\([^&]*\).*/\1/p")"; }
  local db="$FXT/db.json"
  t=$(date -u -d "@${ARCHIE_NOW:-0}" +%Y-%m-%dT%H:%M:%SZ)
  case "$m ${p%%\?*}" in
    "GET /api/initiatives")
      id=$(qp id)
      if [ -n "$id" ]; then
        out=$(jq -c --argjson i "$id" '.initiatives[] | select(.id == $i) | {initiative: .}' "$db")
        [ -n "$out" ] || { JOBS_HTTP=404; return 2; }
      else
        out=$(jq -c --arg s "$(qp status)" --arg d "$(qp due_before)" --argjson l "$(qp limit)" '
          [.initiatives[] | select(($s == "" or .status == $s) and ($d == "" or .next_check_at <= $d))]
          | sort_by(.next_check_at, .id) | {initiatives: .[0:$l], truncated: (length > $l)}' "$db")
      fi ;;
    "GET /api/initiatives/events")
      out=$(jq -c --arg k "$(qp key)" '.events[$k] // empty | {event: .}' "$db")
      [ -n "$out" ] || { JOBS_HTTP=404; return 2; } ;;
    "POST /api/initiatives/check")
      id=$(jq -r .id <<<"$b")
      if [ "$(jq -r .status <<<"$b")" = sent ] && [ -f "$FXT/sent.refuse" ]; then
        rm -f "$FXT/sent.refuse"; JOBS_HTTP=503; return 1
      fi
      jq -e --argjson i "$id" '.initiatives[] | select(.id == $i)' "$db" >/dev/null || { JOBS_HTTP=404; return 2; }
      if jq -e --argjson b "$b" '$b.advance_to != null and (.initiatives[] | select(.id == $b.id)
           | (.next_check_at != $b.due_at or .status != "active"))' "$db" >/dev/null; then
        JOBS_HTTP=409; JOBS_BODY='{"error":"stale"}'; printf '%s' "$JOBS_BODY"; return 9
      fi
      jq --argjson b "$b" '
        ("check:\($b.id):\($b.due_at)") as $k
        | .events[$k] = {status: $b.status, value: $b.value,
            body: ($b.body // .events[$k].body), attempts: ($b.attempts // .events[$k].attempts // 0)}
        | .initiatives |= map(if .id == $b.id then
            .last_check_status = $b.status
            | (if $b.advance_to != null then .next_check_at = $b.advance_to else . end)
          else . end)' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
      out='{"ok":true}' ;;
    "GET /api/ledger")
      k=$(qp kind)
      if grep -q '[?&]key=' <<<"$p"; then
        out=$(jq -c --arg k "$k" --arg v "$(qp key)" '.ledger[$k + "|" + $v] // empty | {ledger: .}' "$db")
        [ -n "$out" ] || { JOBS_HTTP=404; return 2; }
      else
        out=$(jq -c --arg k "$k" --argjson l "$(qp limit)" --arg bf "$(qp before)" --arg bk "$(qp before_key)" '
          [.ledger[] | select(.kind == $k)
             | select($bf == "" or .updated_at < $bf or (.updated_at == $bf and $bk != "" and .key < $bk))]
          | sort_by(.updated_at, .key) | reverse | {ledgers: .[0:$l]}' "$db")
      fi ;;
    "PUT /api/ledger")
      jq --argjson b "$b" --arg t "$t" '($b.kind + "|" + $b.key) as $k
        | .ledger[$k] = {kind: $b.kind, key: $b.key, status: $b.status,
                         detail: ($b.detail // .ledger[$k].detail), updated_at: $t}' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
      out='{"ok":true}' ;;
    *) JOBS_HTTP=404; return 2 ;;
  esac
  JOBS_HTTP=$code; JOBS_BODY="$out"; printf '%s' "$out"; return 0
}
lane_role_model() { [ "$1" = stage.archie ] || return 75; echo test-model; }
SH

export HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 \
  HARNESS_SECRET=test JOBS_BOX=hub CONSOLE_PAGES_URL=https://console.invalid/
unset ARCHIE_ENABLED ARCHIE_MAX_PER_TICK ARCHIE_NOW ARCHIE_FIXTURE ARCHIE_TIMED BEAT_STRICT \
  ARCHIE_BEAT_CAP_DAY ARCHIE_QUIET_FROM_H ARCHIE_QUIET_TO_H ARCHIE_WAKE_ALERT_SCOPE \
  ARCHIE_TELEGRAM_TARGET ARCHIE_NO_ACTION_RE ARCHIE_ASK_RE TELEGRAM_BOT_TOKEN LANE_ALERT_DM_CHAT \
  DAILY_DIGEST_ENABLED DAILY_DIGEST_SEND_HOUR_UTC DAILY_DIGEST_TEXT_MAX_CHARS DAILY_DIGEST_NOW \
  DAILY_DIGEST_FIXTURE DAILY_DIGEST_MAX_ITEMS DAILY_DIGEST_LLM_SUMMARY DD_TIMED 2>/dev/null || true

NOW=1791184500                       # 2026-10-05T07:15:00Z, fixed: no wall-clock read
D0=1791158400                        # 2026-10-05T00:00:00Z
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
NOWISO=$(iso "$NOW")
DUE=$(iso $((NOW - 900)))
FUTURE=$(iso $((NOW + 3600)))
DM=100000000                         # lib.lane-alert.lane_alert_dm_chat's registry default
SENT_REC='The rework rate went from 9.0 to 12.5, so I would check every 3 days instead of weekly.'
NOOP_REC="A follow-up I set for today fired with no note on what to check, and nothing else is pending, so there's nothing for you to do here."
ASK_REC='Nothing to do on the merge itself, but the spend cap hit 0.60 twice, can you raise it?'

# row <id> [next_check_at]: an always-escalating initiative with no metric.
row() {
  jq -nc --argjson i "$1" --arg n "${2:-$DUE}" \
    '{id: $i, slug: "init-\($i)", goal: "Watch rework (#\($i))", metric_query: "none", cadence_hours: 168,
      escalation_rule: "always", status: "active", next_check_at: $n, links: [], last_value: null,
      last_check_status: null}'
}
reset() {
  local p
  for p in reqlog beats.jsonl agentcalls alerts.log tg.jsonl tg.answer tg.down net.log net.argv \
           settings.json sent.refuse jobs.down out rc dd.on ledger.json route.json; do
    scratch_rm "$T/$p" || exit 1
  done
  scratch_rm "$H/state" || exit 1; scratch_rm "$H/locks" || exit 1; scratch_rm "$H/flags" || exit 1
  scratch_rm "$H/logs" || exit 1; mkdir -p "$H/logs"
  printf '%s\n' "$TOKEN_ENV" > "$H/env/global.env"
  printf 'CLASS: watch-cadence\n%s\n' "$SENT_REC" > "$T/ac.text"
  jq -nc '{initiatives: $ARGS.positional, events: {}, ledger: {}}' --jsonargs "$@" > "$T/db.json"
  : > "$T/reqlog"
  CLOCK=$NOW
}
settings() { # settings <key> <value>: one operator row; the box cache is dropped
  jq -nc --arg k "$1" --arg v "$2" '{settings: [{key: $k, value: $v, actor: "operator"}]}' > "$T/settings.json"
  scratch_rm "$H/state/lane-gate" || exit 1; scratch_rm "$H/state/settings-cache.json" || exit 1
}
tick() {
  env HARNESS_TEST_SANDBOX=1 ARCHIE_NOW="$CLOCK" ARCHIE_FIXTURE="$T/fx.sh" LANE_GATE_DISABLE=1 "$@" \
    bash "$H/bin/archie.sh" tick > "$T/out" 2>&1
  echo $? > "$T/rc"
}
send() { # send <akey> <text>: the transport alone; rc in $T/rc
  env HARNESS_TEST_SANDBOX=1 ARCHIE_FIXTURE="$T/fx.sh" LANE_GATE_DISABLE=1 \
    bash "$H/bin/archie-tg-send.sh" "$@" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
n()     { local c; c=$(wc -l 2>/dev/null < "$1"); printf '%s' "${c:-0}" | tr -d ' '; }
calls() { n "$T/agentcalls"; }
tgs()   { n "$T/tg.jsonl"; }
tg()    { sed -n "${2:-1}p" "$T/tg.jsonl" | jq -r ".$1"; }
rcv()   { cat "$T/rc"; }
lg()    { jq -r --arg k "$1|$2" '.ledger[$k].status // "none"' "$T/db.json"; }
lgd()   { jq -r --arg k "$1|$2" '.ledger[$k].detail // "none"' "$T/db.json"; }
lcount() { jq -r --arg k "$1" --arg s "${2:-}" '[.ledger[] | select(.kind == $k and ($s == "" or .status == $s))] | length' "$T/db.json"; }
evs()   { jq -r --arg k "check:$1:${2:-$DUE}" '.events[$k].status // "none"' "$T/db.json"; }
evb()   { jq -r --arg k "check:$1:${2:-$DUE}" '.events[$k].body // ""' "$T/db.json"; }
fld()   { jq -r --argjson i "$1" --arg f "$2" '.initiatives[] | select(.id == $i) | .[$f] // "null"' "$T/db.json"; }
fleet_archie() { [ -s "$T/beats.jsonl" ] || { echo 0; return; }; jq -s '[.[] | select(.kind == "fleet_alert" and (.akey // "" | startswith("archie")))] | length' "$T/beats.jsonl"; }
FLEET_ARCHIE=0       # C5 sums every Archie world's fleet_alert count
fa_add() { FLEET_ARCHIE=$((FLEET_ARCHIE + $(fleet_archie))); }

# ═════ S: the transport ══════════════════════════════════════════════════════
reset
send k1 "hello"
eq "S1 rc 0 ($(cat "$T/out"))" "$(rcv)" 0
eq "S1 one sendMessage" "$(tgs)" 1
eq "S1 to the operator's DM (the lane-alert registry default)" "$(tg chat_id)" "$DM"
eq "S1 the text" "$(tg text)" hello
eq "S1 no thread" "$(tg message_thread_id)" ""
eq "S1 the sendMessage url" "$(tg url_has_sendMessage)" true
eq "S1 ledger archie_tg/k1 sent" "$(lg archie_tg k1)" sent
check "S1 detail message_ids [101], chat, chunks 1 ($(lgd archie_tg k1))" \
  'lgd archie_tg k1 | jq -e --arg c "$DM" ".message_ids == [101] and .chat == \$c and .chunks == 1" >/dev/null'
check "S1 one log line, no text, no token" 'grep -q "tg k1 chat=$DM chunks=1 rc=0" "$H/logs/archie.log" && ! grep -q "hello\|fixture-token" "$H/logs/archie.log"'
check "S2 the token never in curl's argv" '[ -s "$T/net.argv" ] && ! grep -q fixture-token "$T/net.argv"'
eq "S2 the token arrived on stdin" "$(tg url_has_token)" true
send k1 "hello"
eq "S3 dedupe rc 0" "$(rcv)" 0
eq "S3 dedupe: still one sendMessage" "$(tgs)" 1
printf '{"ok":false,"description":"Too Many Requests"}' > "$T/tg.answer"
send k2 "hi"
eq "S4 not-ok answer rc 1" "$(rcv)" 1
eq "S4 no archie_tg/k2 row" "$(lg archie_tg k2)" none
check "S4 send failed logged with the description" 'grep -q "send failed (chunk 1/1: Too Many Requests)" "$H/logs/archie.log"'
rm -f "$T/tg.answer"
# S5: the settings row overrides the target.
reset
settings lane.archie.archie_telegram_target "-100000000001/42"
send k5 "to the group"
eq "S5 supergroup rc 0" "$(rcv)" 0
eq "S5 supergroup chat" "$(tg chat_id)" "-100000000001"
eq "S5 supergroup thread" "$(tg message_thread_id)" 42
settings lane.archie.archie_telegram_target "777777/42"
send k6 "to a dm"
eq "S5 a plain chat" "$(tg chat_id 2)" 777777
eq "S5 a plain chat gets no thread" "$(tg message_thread_id 2)" ""
: > "$H/logs/archie.log"
settings lane.archie.archie_telegram_target "bogus"
send k7 "fallback"
eq "S5 bogus: rc 0" "$(rcv)" 0
eq "S5 bogus: the default DM" "$(tg chat_id 3)" "$DM"
eq "S5 bogus: one warn line" "$(grep -c 'warn: ARCHIE_TELEGRAM_TARGET=bogus' "$H/logs/archie.log")" 1
# S6: no token.
reset
: > "$H/env/global.env"
send k8 "no token"
eq "S6 no token: rc 2" "$(rcv)" 2
eq "S6 no token: nothing sent" "$(tgs)" 0
eq "S6 one ALERTS line naming the token" "$(grep -c TELEGRAM_BOT_TOKEN "$H/logs/ALERTS.log" 2>/dev/null)" 1
send k8 "no token"
eq "S6 a second call: no second ALERTS line" "$(grep -c TELEGRAM_BOT_TOKEN "$H/logs/ALERTS.log" 2>/dev/null)" 1
eq "S6 no row" "$(lg archie_tg k8)" none
# S7: the ledger is down.
reset
: > "$T/jobs.down"
send k9 "ledger down"
eq "S7 ledger down: rc 3" "$(rcv)" 3
eq "S7 ledger down: nothing sent" "$(tgs)" 0
rm -f "$T/jobs.down"
send "" "x"
eq "S0 an empty akey is rc 64" "$(rcv)" 64
send k10 "   "
eq "S0 a blank text is rc 64" "$(rcv)" 64
eq "S0 nothing sent" "$(tgs)" 0

# ═════ C: the check path ═════════════════════════════════════════════════════
reset "$(row 7)"
tick
check "C1 rc 0 ($(cat "$T/out"))" '[ "$(rcv)" = 0 ]'
eq "C1 one model call" "$(calls)" 1
eq "C1 one Telegram message" "$(tgs)" 1
eq "C1 to the target" "$(tg chat_id)" "$DM"
check "C1 the sentence first ($(tg text | head -1))" '[ "$(tg text | head -1)" = "$SENT_REC" ]'
eq "C1 signed Archie" "$(tg text | tail -1)" Archie
eq "C1 event sent" "$(evs 7)" sent
eq "C1 archie_tg row" "$(lg archie_tg "archie:7:$DUE")" sent
L_COMP=$(grep -n '^POST /api/initiatives/check .*"status":"composed"' "$T/reqlog" | head -1 | cut -d: -f1)
L_TG=$(grep -n '^TG sendMessage' "$T/reqlog" | head -1 | cut -d: -f1)
L_SENT=$(grep -n '^POST /api/initiatives/check .*"status":"sent"' "$T/reqlog" | head -1 | cut -d: -f1)
check "C1 composed ($L_COMP) < Telegram ($L_TG) < sent ($L_SENT)" \
  '[ -n "$L_COMP" ] && [ -n "$L_TG" ] && [ -n "$L_SENT" ] && [ "$L_COMP" -lt "$L_TG" ] && [ "$L_TG" -lt "$L_SENT" ]'
eq "C1 today's count" "$(lg archie_beatday 2026-10-05)" 1
check "C1 no network but Telegram" '[ ! -s "$T/net.log" ]'
fa_add
# C2 / C3: a failed send stays composed; the next tick resends it, no new call.
reset "$(row 7)"
: > "$T/tg.down"
tick
eq "C2 event composed" "$(evs 7)" composed
check "C2 the body is stored" '[ -n "$(evb 7)" ]'
eq "C2 one model call" "$(calls)" 1
eq "C2 no archie_tg row" "$(lg archie_tg "archie:7:$DUE")" none
check "C2 logged as not delivered" 'grep -q "initiative 7: not delivered" "$H/logs/archie.log"'
rm -f "$T/tg.down"
CLOCK=$((NOW + 900)); tick
eq "C3 no new model call" "$(calls)" 1
eq "C3 one message delivered" "$(tgs)" 1
check "C3 the stored body, byte for byte" '[ "$(tg text)" = "$(evb 7)" ]'
eq "C3 event sent" "$(evs 7)" sent
fa_add
# C4: a lost `sent` write is not a second message.
reset "$(row 7)"
: > "$T/sent.refuse"
tick
eq "C4 sent write lost: composed" "$(evs 7)" composed
eq "C4 one message" "$(tgs)" 1
CLOCK=$((NOW + 900)); tick
eq "C4 resend: still one message" "$(tgs)" 1
eq "C4 now sent" "$(evs 7)" sent
check "C4 the transport said already sent" 'grep -q "tg archie:7:$DUE already sent" "$H/logs/archie.log"'
fa_add
# C6: the settings row on the check path.
reset "$(row 7)"
settings lane.archie.archie_telegram_target "-100000000002/7"
tick
eq "C6 one message" "$(tgs)" 1
eq "C6 to the settings chat" "$(tg chat_id)" "-100000000002"
eq "C6 in its thread" "$(tg message_thread_id)" 7
eq "C6 sent" "$(evs 7)" sent
fa_add

# ═════ N: no-action answers send nothing ═════════════════════════════════════
reset "$(row 8)"
printf 'CLASS: watch-continue\n%s\n' "$NOOP_REC" > "$T/ac.text"
tick
eq "N1 event empty" "$(evs 8)" empty
eq "N1 no message" "$(tgs)" 0
check "N1 no decision POST" '! grep -q "^POST /api/archie/decisions" "$T/reqlog"'
eq "N1 advanced by its cadence" "$(fld 8 next_check_at)" "$(iso $((NOW + 168 * 3600)))"
check "N1 logged" 'grep -q "initiative 8: answer says nothing is needed" "$H/logs/archie.log"'
reset "$(row 8)"
printf 'CLASS: spend\n%s\n' "$ASK_REC" > "$T/ac.text"
tick
eq "N2 an ask still sends" "$(tgs)" 1
eq "N2 sent" "$(evs 8)" sent
fa_add
reset "$(row 8)"
printf 'CLASS: watch-continue\n\n' > "$T/ac.text"
tick
eq "N3 blank line 2: empty" "$(evs 8)" empty
eq "N3 no message" "$(tgs)" 0
reset "$(row 8)"
printf 'CLASS: watch-continue\n%s\n' "$NOOP_REC" > "$T/ac.text"
settings lane.archie.archie_no_action_re "zzz-never"
tick
eq "N4 the knob overrides: the sentence sends" "$(tgs)" 1
eq "N4 sent" "$(evs 8)" sent
fa_add
# The guard itself, on sentences the model writes.
# shellcheck source=../bin/lib/archie.sh
( . "$DIR/bin/lib/archie.sh" || exit 9
  for s in "$NOOP_REC" "No action needed from you; the numbers held." "Nothing for you to do, the rate held at 9.0."; do
    archie_no_action "$s" || { echo "N5 missed: $s"; exit 1; }
  done
  # News that also says nothing is needed is still news (the ticket: only an
  # answer whose ONLY content is "nothing needed" is silent).
  for s in "$ASK_REC" "$SENT_REC" "Nothing to do yet. Should I drop it?" "Approve I7 so I can file the ticket." "" \
      "Main has been red for 6 hours and there's nothing you need to do since I already reverted it." \
      "The spend cap tripped twice and I paused the lane, nothing for you to do yet but it will block BH-12 tomorrow." \
      "CI went red on three PRs overnight; I re-queued them, no action needed."; do
    archie_no_action "$s" && { echo "N5 false positive: $s"; exit 1; }
  done
  ARCHIE_ASK_RE='(' archie_no_action "$NOOP_REC" 2>/dev/null && { echo "N5 a malformed ARCHIE_ASK_RE silenced it"; exit 1; }
  ARCHIE_NEWS_RE='(' archie_no_action "$NOOP_REC" 2>/dev/null && { echo "N5 a malformed ARCHIE_NEWS_RE silenced it"; exit 1; }
  exit 0 ) > "$T/out" 2>&1
check "N5 the classifier ($(cat "$T/out"))" '[ ! -s "$T/out" ]'
# N6: the shipped tick sends a no-action sentence that carries news.
NEWS_REC="CI went red on three PRs overnight; I re-queued them, no action needed."
reset "$(row 8)"
printf 'CLASS: watch-continue\n%s\n' "$NEWS_REC" > "$T/ac.text"
tick
eq "N6 news with 'no action needed' still sends" "$(tgs)" 1
eq "N6 sent" "$(evs 8)" sent
check "N6 the line carries the news" 'tg text | grep -qF "$NEWS_REC"'
fa_add
reset "$(row 8)"
printf 'CLASS: watch-continue\n%s\n' "$NEWS_REC" > "$T/ac.text"
settings lane.archie.archie_news_re "zzz-never"
tick
eq "N6 the news knob is read from settings: silenced" "$(tgs)" 0
eq "N6 empty" "$(evs 8)" empty

# ═════ F: follow-ups ═════════════════════════════════════════════════════════
fu_world() { # fu_world <note>: I9 lives, not due; its follow-up is due
  reset "$(row 9 "$FUTURE")"
  jq --arg n "$1" --arg d "$(iso $((NOW - 60)))" '.ledger["archie_followup|fu-0000aaaa"] = {kind: "archie_followup", key: "fu-0000aaaa",
      status: "pending", detail: ({due_at: $d, initiative_id: 9, note: $n} | tojson), updated_at: "2026-10-05T06:00:00Z"}' \
    "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
}
fu_world ""
tick
eq "F1 archie_wake empty" "$(lg archie_wake followup:fu-0000aaaa)" empty
eq "F1 the follow-up fired" "$(lg archie_followup fu-0000aaaa)" fired
eq "F1 no model call" "$(calls)" 0
eq "F1 no message" "$(tgs)" 0
check "F1 no wake context" '[ ! -e "$H/state/archie/wake-context/9.txt" ]'
eq "F1 I9 not woken" "$(fld 9 next_check_at)" "$FUTURE"
check "F1 logged" 'grep -q "follow-up fu-0000aaaa fired with no note; closed silently" "$H/logs/archie.log"'
fu_world "re-check rework"
tick
check "F2 a note wakes ($(lg archie_wake followup:fu-0000aaaa))" '[[ "$(lg archie_wake followup:fu-0000aaaa)" == woken* ]]'
eq "F2 one model call" "$(calls)" 1
eq "F2 its message goes to the DM" "$(tg chat_id)" "$DM"
fa_add

# ═════ Q: quiet hours and the cap ════════════════════════════════════════════
reset "$(row 10 "$(iso $((D0 + 5 * 3600 - 60)))")"
CLOCK=$((D0 + 5 * 3600))
tick ARCHIE_QUIET_FROM_H=0 ARCHIE_QUIET_TO_H=23
eq "Q1 05:00Z quiet: one call" "$(calls)" 1
eq "Q1 05:00Z quiet: no message" "$(tgs)" 0
eq "Q1 held" "$(lcount archie_digest queued)" 1
CLOCK=$((D0 + 23 * 3600)); tick ARCHIE_QUIET_FROM_H=0 ARCHIE_QUIET_TO_H=23
eq "Q1 23:00Z: one message" "$(tgs)" 1
check "Q1 the digest header ($(tg text | head -1))" 'tg text | head -1 | grep -q "^Held 1 update"'
check "Q1 carries the held sentence" 'tg text | grep -qF "$SENT_REC"'
eq "Q1 the held row sent" "$(lcount archie_digest sent)" 1
DGK=$(jq -r '.ledger | keys[] | select(startswith("archie_tg|archie:digest:"))' "$T/db.json" | sed 's/^archie_tg|//')
check "Q1 archie_tg/archie:digest:<sha8> ($DGK)" '[[ $DGK =~ ^archie:digest:[0-9a-f]{8}$ ]] && [ "$(lg archie_tg "$DGK")" = sent ]'
fa_add
reset "$(row 11)" "$(row 12)"
tick ARCHIE_BEAT_CAP_DAY=1
eq "Q2 two calls" "$(calls)" 2
eq "Q2 the cap: one message" "$(tgs)" 1
eq "Q2 the other held" "$(lcount archie_digest queued)" 1
fa_add

# ═════ C5: nothing from Archie went through fleet_alert ══════════════════════
eq "C5 no fleet_alert beat for any archie-prefixed akey" "$FLEET_ARCHIE" 0
# Every Archie voice, not only the check lane: the research lane's daily line
# and weekly digest, and the learning lane's weekly report, have their own
# suites (archie-research*, archie-learning.bh-4066) that drive the sends; this
# pins the source so none of them can go back to a fleet_alert beat. (The
# research lane's kind:proposal beat is console data for the Ideas screen, not
# a message, and stays.)
FA_SRC=$(grep -nE 'fleet_alert' "$DIR"/bin/archie*.sh "$DIR"/bin/lib/archie*.sh "$DIR/bin/daily-digest.sh" \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
check "C5 no Archie script builds a fleet_alert ($FA_SRC)" '[ -z "$FA_SRC" ]'
for f in archie-research.sh archie-learn.sh; do
  check "C5 bin/$f sends through bin/archie-tg-send.sh" "grep -qF '\"\$H/bin/archie-tg-send.sh\"' \"\$DIR/bin/$f\""
done

# ═════ R1: the prompt ════════════════════════════════════════════════════════
check "R1 the prompt says leave line 2 blank" 'grep -qF "leave line 2 blank" "$DIR/catalog/prompts/archie-check.md"'
check "R1 the woken-check rule no longer says only 'answer with nothing at all'" \
  '! grep -qF "answer with nothing at all" "$DIR/catalog/prompts/archie-check.md"'
check "R1 knobs registered" 'jq -e "[.knobs[].env] | index(\"ARCHIE_TELEGRAM_TARGET\") and index(\"ARCHIE_NO_ACTION_RE\") and index(\"ARCHIE_ASK_RE\") and index(\"ARCHIE_NEWS_RE\")" "$DIR/catalog/lanes.d/archie.json" >/dev/null'

# ═════ B: mutations of the shipped code (D1) ═════════════════════════════════
WAKE="$H/bin/lib/archie-wake.sh"
rm -f "$WAKE"
sed '/^    # >>> archie send (BH-4779)/,/^    # <<< archie send/c\    BEAT_STRICT=1 "$(_aw_root)/bin/beat.sh" "$payload" >/dev/null 2>\&1 || return 1' \
  "$DIR/bin/lib/archie-wake.sh" > "$WAKE"
check "B1 the send markers exist" '! cmp -s "$WAKE" "$DIR/bin/lib/archie-wake.sh"'
reset "$(row 7)"
tick
check "B1 mutant (the old beat back): C1 goes red, tgs=$(tgs) beats=$(n "$T/beats.jsonl")" '[ "$(tgs)" = 0 ] && [ "$(n "$T/beats.jsonl")" = 1 ]'
rm -f "$WAKE"; ln -s "$DIR/bin/lib/archie-wake.sh" "$WAKE"
LIB="$H/bin/lib/archie.sh"
rm -f "$LIB"
sed 's/^archie_no_action() {$/archie_no_action() { return 1; }\narchie_no_action_unused() {/' "$DIR/bin/lib/archie.sh" > "$LIB"
check "B2 the guard exists" '! cmp -s "$LIB" "$DIR/bin/lib/archie.sh"'
reset "$(row 8)"
printf 'CLASS: watch-continue\n%s\n' "$NOOP_REC" > "$T/ac.text"
tick
check "B2 mutant (no guard): N1 goes red, tgs=$(tgs)" '[ "$(tgs)" = 1 ]'
rm -f "$LIB"; ln -s "$DIR/bin/lib/archie.sh" "$LIB"

# ═════ D: the daily digest as Archie's daily report ══════════════════════════
DD=2026-09-29
DNOW=1790751900          # 2026-09-30T07:05:00Z, so the day is 2026-09-29
SD="$H/state/daily-digest"
dd_reset() {
  reset
  : > "$T/dd.on"
  echo '{}' > "$T/ledger.json"
  jq --arg d "$DD" '.day = $d' "$DIR/tests/fixtures/daily-digest/fixture-day.json" > "$T/route.json"
}
dd_run() {
  env HARNESS_TEST_SANDBOX=1 DAILY_DIGEST_NOW="$DNOW" LANE_GATE_DISABLE=1 "$@" bash "$H/bin/daily-digest.sh" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
dl() { jq -r --arg i "$1/$2" '.[$i].status // "none"' "$T/ledger.json"; }
dd_reset
dd_run
eq "D1 rc 0 ($(cat "$T/out"))" "$(rcv)" 0
eq "D1 one message" "$(tgs)" 1
eq "D1 to the target" "$(tg chat_id)" "$DM"
check "D1 the digest ($(tg text | head -1))" 'tg text | head -1 | grep -qx "Daily digest $DD (UTC)"'
eq "D1 signed Archie" "$(tg text | tail -1)" Archie
eq "D1 daily_digest/<D> sent" "$(dl daily_digest "$DD")" sent
eq "D1 archie_tg/daily-digest:<D> sent" "$(dl archie_tg "daily-digest:$DD")" sent
check "D1 the stamp" '[ -f "$SD/sent-$DD" ]'
eq "D2 never a beat" "$(n "$T/beats.jsonl")" 0
dd_run
eq "D3 a re-run that day: rc 0" "$(rcv)" 0
eq "D3 still one message" "$(tgs)" 1
dd_reset
: > "$T/tg.down"
dd_run
eq "D4 failed send: send-failed" "$(dl daily_digest "$DD")" send-failed
check "D4 detail send_rc 1 ($(jq -r --arg i "daily_digest/$DD" '.[$i].detail' "$T/ledger.json"))" \
  'jq -r --arg i "daily_digest/$DD" ".[\$i].detail" "$T/ledger.json" | jq -e ".send_rc == 1" >/dev/null'
eq "D4 attempts 1" "$(cat "$SD/attempts-$DD" 2>/dev/null)" 1
check "D4 no stamp" '[ ! -f "$SD/sent-$DD" ]'
rm -f "$T/tg.down"
dd_run
eq "D4 the next run sends" "$(dl daily_digest "$DD")" sent
eq "D4 one delivered message" "$(n "$T/tg.jsonl")" 1

echo "archie-dm: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
