#!/bin/bash
# tests/unblock-card.bh-7725-test.sh — BH-7725 (UNB-3): the Tackler escalation
# card, its bounded stage.unblock call, its answer grammar, the orchestrator
# intercept and the settings seeds.
#
# WHAT RUNS. The SHIPPED bin/lib/unblock/card.sh (sourced in subshells), the
# SHIPPED bin/unblock-reply.sh (its closure installed in a scratch harness with
# the real jobs client), the `# >>> tackler reply intercept` block lifted from
# bin/orchestrate.sh, and the schema fragment applied to a scratch sqlite.
#
# WHAT IS STUBBED, each one counted: bin/agent-call.sh (the LLM seam) writes
# the answer $T/ac.mode names; bin/lane-alert.sh (the Telegram seam) logs its
# argv; model_for is a function; a `curl` on PATH models the jobs worker's
# decision ledger over $T/ledger.json and logs every request to $T/reqlog.
# Nothing here reaches a network.
#
# Cases: C1-C8 the card, D1-D6 the answer grammar, E1 the orchestrate block,
# F1 the settings seeds.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-card.bh-7725-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "unblock-card: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

CARD="$DIR/bin/lib/unblock/card.sh"
REPLY="$DIR/bin/unblock-reply.sh"
PROMPT="$DIR/catalog/prompts/unblock-decide.md"
FRAG="$DIR/worker/jobs/schema.d/202610201530-bh-7725-unblock-infra.sql"
SITE="$DIR/catalog/llm-sites.d/7725-unblock.json"
for f in "$CARD" "$REPLY" "$PROMPT" "$FRAG" "$SITE"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
if [ ! -f "$CARD" ] || [ ! -f "$REPLY" ]; then echo "unblock-card: $PASS passed, $FAIL failed"; exit 1; fi

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/bin" "$H/catalog/prompts" "$H/logs" "$H/state" "$T/fakebin"
for s in bin/unblock-reply.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: cannot install the closure of $s"; exit 1; }
done
cp "$PROMPT" "$H/catalog/prompts/unblock-decide.md"
NOW=1792508400   # 2026-10-20T15:00:00Z
# A fixture decision key (64 hex, prefix 3f9a2c001122), built at run time so
# the file holds no hex token the share-mirror leakcheck reads as a secret.
KEY="3f9a2c001122$(printf 'ab%.0s' $(seq 26))"

# The LLM seam: one line per call (the env flag and the prompt's first line),
# the prompt kept whole, the answer chosen by $T/ac.mode (or $T/ac.seq, one
# mode per line, consumed in order).
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
p="$6"; [ "${p#@}" != "$p" ] && p=$(cat "${p#@}")
printf '%s\t%s\t%s\t%s\n' "${AGENT_CALL_NO_TOOLS:-unset}" "$1" "$3" "$(head -1 <<<"$p")" >> "$FXT/ac.log"
printf '%s' "$p" > "$FXT/ac.prompt"
mode=$(cat "$FXT/ac.mode" 2>/dev/null)
if [ -s "$FXT/ac.seq" ]; then mode=$(head -1 "$FXT/ac.seq"); sed -i 1d "$FXT/ac.seq"; fi
case "$mode" in
  ok) printf '```json\n{"what":"The alpha pool waits on CI_MAX_SHARDS.","options":["hold: keep it parked","raise CI_MAX_SHARDS by hand","move alpha builds to the pool"],"recommendation":1,"reason":"CI_MAX_SHARDS is a spend knob."}\n```\n' > "$5" ;;
  empty) : > "$5" ;;
  invalid) printf 'I think you should hold.\n' > "$5" ;;
  badshape) printf '{"what":"x","options":["only one"],"recommendation":1,"reason":"r"}\n' > "$5" ;;
  fail) exit 1 ;;
  refuse) exit 76 ;;
esac
exit 0
SH
cat > "$H/bin/lane-alert.sh" <<'SH'
#!/bin/bash
a="$*"; printf '%s\n' "${a//$'\n'/\\n}" >> "$FXT/alerts.log"
SH
chmod +x "$H/bin/agent-call.sh" "$H/bin/lane-alert.sh"

# card <fn> <args...> — one card.sh function in a subshell with the seams set.
# MODEL_RC: what the model_for stub returns (default 0, model "m-fixture").
card() {
  ( export HARNESS="$H" HARNESS_TEST_SANDBOX=1 FXT="$T"
    . "$CARD" || exit 9
    model_for() { echo "model_for $*" >> "$FXT/mf.log"; [ "${MODEL_RC:-0}" = 0 ] || return "$MODEL_RC"; echo m-fixture; }
    "$@" )
}

STALL='{"family":"infra","kind":"pool-starved","project":"alpha","subject":"pool:alpha","subject_kind":"pool","stall_at":"2026-10-20T14:50:00Z","day":"2026-10-20","unknown":[],"truncated":false,"queued":40,"running":1,"stop":"cap","proposal":{"key":"CI_MAX_SHARDS","old":null,"new":null,"min":null,"max":null,"in_range":null,"key_allowlisted":false,"person_set_24h":null,"rollback_note":null},"near_miss":[{"rule":"U9","predicate":".proposal.key_allowlisted == true","read":"false"}]}'
jq -c --arg k "$KEY" '. + {decision_key: $k}' <<<"$STALL" > "$T/stall.json"
DECIDE3='{"what":"The alpha pool waits on CI_MAX_SHARDS, a spend knob.","options":["hold: keep it parked","raise CI_MAX_SHARDS by hand","move alpha builds to the pool"],"recommendation":1,"reason":"Spend knobs stay with a person."}'
printf '%s' "$DECIDE3" > "$T/decide3.json"

# ═════ C: the card ═══════════════════════════════════════════════════════════
eq "C0 card id is u- and the first 6 hex of the key" "$(card unblock_card_id "$KEY")" "u-3f9a2c"
check "C0 a non-hex key still gives a 6-hex id" '[[ $(card unblock_card_id "U9|pool:alpha|2026-10-20") =~ ^u-[0-9a-f]{6}$ ]]'

C=$(card unblock_card_compose "$T/stall.json" "$T/decide3.json" "$KEY" "$NOW"); rc=$?
eq "C1 compose rc" "$rc" 0
TXT=$(jq -r .text <<<"$C")
for fld in "TACKLER CARD u-3f9a2c" "WHAT:" "EVIDENCE:" "OPTIONS:" "1. hold: keep it parked" "2. raise CI_MAX_SHARDS by hand" "3. move alpha builds to the pool" "RECOMMEND: 1" "DEFAULT: it stays as it is now; nothing runs on silence" "DEADLINE: 2026-10-23T15:00:00Z" "ANSWER: Tackler u-3f9a2c <n>"; do
  check "C1 the text carries '$fld'" 'grep -qF -- "$fld" <<<"$TXT"'
done
eq "C1 card fields" "$(jq -c '[.id, .subject, (.options | length), .recommendation, .default]' <<<"$C")" \
  '["u-3f9a2c","pool:alpha",3,1,"it stays as it is now; nothing runs on silence"]'
check "C1 at most 900 chars" '[ "$(jq -r ".text | length" <<<"$C")" -le 900 ]'
printf '%s' '{"what":"x","options":["only one"],"recommendation":1,"reason":"r"}' > "$T/decide1.json"
C=$(card unblock_card_compose "$T/stall.json" "$T/decide1.json" "$KEY" "$NOW")
eq "C1 one option: falls back to the deterministic decide" "$(jq -c '[(.options | length), .reason]' <<<"$C")" '[2,"no rule covers this case"]'
printf '%s' '{"what":"x","options":["a","b","c","d","e"],"recommendation":1,"reason":"r"}' > "$T/decide5.json"
eq "C1 five options: falls back" "$(card unblock_card_compose "$T/stall.json" "$T/decide5.json" "$KEY" "$NOW" | jq -c '.options | length')" 2
printf '%s' '{"what":"x","options":["a","b"],"recommendation":3,"reason":"r"}' > "$T/decide-r.json"
eq "C1 a recommendation outside the options: falls back" "$(card unblock_card_compose "$T/stall.json" "$T/decide-r.json" "$KEY" "$NOW" | jq -r .reason)" "no rule covers this case"
FB=$(card unblock_card_fallback "$T/stall.json")
eq "C1 fallback options" "$(jq -c .options <<<"$FB")" '["hold: keep it parked","change CI_MAX_SHARDS by hand"]'
check "C1 fallback what names the predicate" 'jq -e ".what | contains(\"key_allowlisted\")" <<<"$FB" >/dev/null'

LONGEV=$(printf 'x%.0s' $(seq 1 3000))
jq -c --arg l "$LONGEV" '. + {log_excerpt: $l}' "$T/stall.json" > "$T/stall-long.json"
C=$(card unblock_card_compose "$T/stall-long.json" "$T/decide3.json" "$KEY" "$NOW"); rc=$?
eq "C2 long record: rc 0" "$rc" 0
check "C2 long record: text at most 900 chars" '[ "$(jq -r ".text | length" <<<"$C")" -le 900 ]'
check "C2 evidence is trimmed with an ellipsis, WHAT is whole" 'jq -e "(.text | contains(\"…\")) and (.text | contains(\"WHAT: The alpha pool waits on CI_MAX_SHARDS, a spend knob.\"))" <<<"$C" >/dev/null'
check "C2 every option survives the trim" 'jq -e ".text | contains(\"3. move alpha builds to the pool\")" <<<"$C" >/dev/null'
LONGW=$(printf 'w%.0s' $(seq 1 2000))
jq -c --arg l "$LONGW" '.what = $l' "$T/decide3.json" > "$T/decide-longwhat.json"
C=$(card unblock_card_compose "$T/stall-long.json" "$T/decide-longwhat.json" "$KEY" "$NOW"); rc=$?
check "C2 a long WHAT is trimmed after the evidence" '[ "$rc" = 0 ] && [ "$(jq -r ".text | length" <<<"$C")" -le 900 ]'
LONGO=$(printf 'o%.0s' $(seq 1 400))
jq -c --arg l "$LONGO" '.options = [$l, $l, $l]' "$T/decide3.json" > "$T/decide-longopt.json"
card unblock_card_compose "$T/stall-long.json" "$T/decide-longopt.json" "$KEY" "$NOW" > "$T/c2.out"; rc=$?
eq "C2 options alone over 900: rc 1, no card" "$rc:$(cat "$T/c2.out")" "1:"

TOK=ghp_FIXTUREFAKEFAKEFAKEFAKEFAKEFAKE0001
jq -c --arg t "$TOK" '. + {log_excerpt: ("push failed with token " + $t + " and HARNESS_SECRET=abc123 and Authorization: Bearer fixture-bearer-value")}' "$T/stall.json" > "$T/stall-sec.json"
jq -c --arg t "$TOK" '.what = ("auth failed for " + $t)' "$T/decide3.json" > "$T/decide-sec.json"
C=$(card unblock_card_compose "$T/stall-sec.json" "$T/decide-sec.json" "$KEY" "$NOW")
check "C3 no token in the card" '! grep -qF "$TOK" <<<"$C"'
check "C3 no HARNESS_SECRET value in the card" '! grep -qF "abc123" <<<"$C"'
check "C3 no bearer value in the card" '! grep -qF "fixture-bearer-value" <<<"$C"'
check "C3 the redaction is visible" 'grep -qF "<redacted" <<<"$(jq -r .text <<<"$C")"'
eq "C3 scrub: KEY/PAT names and sk- shapes" "$(printf 'API_KEY=fixture-1234 GH_PAT: fixturepat99 sk-fixture0123456789 path=/x\n' | card unblock_card_scrub)" \
  "API_KEY=<redacted> GH_PAT: <redacted> <redacted> path=/x"

eq "C4 deadline is now + 72 h" "$(card unblock_card_compose "$T/stall.json" "$T/decide3.json" "$KEY" "$NOW" | jq -r .deadline_at)" "2026-10-23T15:00:00Z"
eq "C4 UNBLOCK_CARD_TTL_H=1: now + 1 h" "$(UNBLOCK_CARD_TTL_H=1 card unblock_card_compose "$T/stall.json" "$T/decide3.json" "$KEY" "$NOW" | jq -r .deadline_at)" "2026-10-20T16:00:00Z"
card unblock_card_compose "$T/stall.json" "$T/decide3.json" "$KEY" "$NOW" > "$T/card.json"

rm -f "$T/alerts.log"
eq "C5 shadow: WOULD_SEND_CARD" "$(card unblock_card_send "$T/card.json" shadow)" "WOULD_SEND_CARD u-3f9a2c"
eq "C5 act mode without UNBLOCK_ACT=1: still shadow" "$(card unblock_card_send "$T/card.json" act)" "WOULD_SEND_CARD u-3f9a2c"
eq "C5 UNBLOCK_ACT=1 without act mode: still shadow" "$(UNBLOCK_ACT=1 card unblock_card_send "$T/card.json" shadow)" "WOULD_SEND_CARD u-3f9a2c"
check "C5 shadow: 0 lane-alert calls" '[ ! -s "$T/alerts.log" ]'
eq "C5 act + UNBLOCK_ACT=1: sent" "$(UNBLOCK_ACT=1 card unblock_card_send "$T/card.json" act)" "SENT_CARD u-3f9a2c"
eq "C5 exactly one lane-alert call" "$(wc -l < "$T/alerts.log" | tr -d ' ')" 1
check "C5 the critical alert DM with the card's id (the operator 6294290004 item 5)" \
  'grep -q -- "^--critical --id unblock-3f9a2c001122 --severity critical unblock TACKLER CARD u-3f9a2c" "$T/alerts.log"'
check "C5 no Archie topic or thread argument" '! grep -qiE -- "archie|--thread|--topic" "$T/alerts.log"'
printf '#!/bin/bash\nexit 1\n' > "$T/la-fail"; chmod +x "$T/la-fail"; cp "$H/bin/lane-alert.sh" "$T/la-ok"; cp "$T/la-fail" "$H/bin/lane-alert.sh"
out=$(UNBLOCK_ACT=1 card unblock_card_send "$T/card.json" act); rc=$?
eq "C5 a failed send is rc 1 and says so" "$rc:$out" "1:SEND_FAILED u-3f9a2c"
cp "$T/la-ok" "$H/bin/lane-alert.sh"

# C6: the bounded stage.unblock call.
printf '{"claimed":true,"decision_key":"%s"}' "$KEY" > "$T/claim.json"
decide() { rm -f "$T/ac.log" "$T/mf.log" "$T/dec.out"; printf '%s' "$1" > "$T/ac.mode"; card unblock_card_decide "$T/stall.json" "${2:-$T/claim.json}" "$T/dec.out"; }
calls() { if [ -s "$T/ac.log" ]; then wc -l < "$T/ac.log" | tr -d ' '; else echo 0; fi; }
printf '{"claimed":false,"decision_key":"%s"}' "$KEY" > "$T/noclaim.json"
decide ok "$T/noclaim.json"
eq "C6 no claim: refused, 0 calls, no route read" "$(jq -r .outcome "$T/dec.out"):$(calls):$([ -s "$T/mf.log" ] && echo read || echo none)" "refused:0:none"
printf '{"claimed":true,"decision_key":"ffff"}' > "$T/otherclaim.json"
decide ok "$T/otherclaim.json"
eq "C6 a claim for another key: refused, 0 calls" "$(jq -r .outcome "$T/dec.out"):$(calls)" "refused:0"
decide ok "$T/missing-claim.json"
eq "C6 no claim file: refused, 0 calls" "$(jq -r .outcome "$T/dec.out"):$(calls)" "refused:0"
rm -f "$T/ac.log"; printf ok > "$T/ac.mode"
MODEL_RC=75 card unblock_card_decide "$T/stall.json" "$T/claim.json" "$T/dec.out"
eq "C6 no route (rc 75): no-route, 0 calls" "$(jq -r '[.outcome, .model_calls] | join(":")' "$T/dec.out"):$(calls)" "no-route:0:0"
eq "C6 no route: the fallback decide rides the outfile" "$(jq -r .decide.reason "$T/dec.out")" "no rule covers this case"
eq "C6 the route read is stage.unblock for the project" "$(cat "$T/mf.log")" "model_for stage.unblock alpha"
decide ok
eq "C6 claimed + valid answer: ok, 1 call" "$(jq -r '[.outcome, .model_calls] | join(":")' "$T/dec.out"):$(calls)" "ok:1:1"
eq "C6 the call runs with AGENT_CALL_NO_TOOLS=1, stage unblock, the routed model" "$(cut -f1-3 "$T/ac.log")" "1	unblock	m-fixture"
eq "C6 the prompt starts with the SOP" "$(head -1 "$T/ac.prompt")" "$(head -1 "$PROMPT")"
check "C6 the record rides inside an UNTRUSTED fence" 'grep -q "UNTRUSTED" "$T/ac.prompt" && grep -qF "\"subject\":\"pool:alpha\"" "$T/ac.prompt"'
eq "C6 the answer is the decide" "$(jq -c '[.decide.recommendation, (.decide.options | length)]' "$T/dec.out")" "[1,3]"
check "C6 cost is not invented" 'jq -e "has(\"cost_usd\") and .cost_usd == null" "$T/dec.out" >/dev/null'
decide empty
eq "C6 empty answer: empty, 1 call (billed, terminal), fallback" "$(jq -r '[.outcome, .model_calls, .decide.reason] | join(":")' "$T/dec.out"):$(calls)" "empty:1:no rule covers this case:1"
decide invalid
eq "C6 prose answer: invalid, 1 call, fallback" "$(jq -r '[.outcome, .model_calls, .decide.reason] | join(":")' "$T/dec.out"):$(calls)" "invalid:1:no rule covers this case:1"
decide badshape
eq "C6 one-option answer: invalid, 1 call, fallback" "$(jq -r '[.outcome, .model_calls] | join(":")' "$T/dec.out"):$(calls)" "invalid:1:1"
decide fail
eq "C6 rc 1 twice: failed after 2 calls, fallback" "$(jq -r '[.outcome, .model_calls, .decide.reason] | join(":")' "$T/dec.out"):$(calls)" "failed:2:no rule covers this case:2"
printf 'fail\nok\n' > "$T/ac.seq"; decide fail
eq "C6 rc 1 then a valid answer: ok after 2 calls" "$(jq -r '[.outcome, .model_calls] | join(":")' "$T/dec.out"):$(calls)" "ok:2:2"
decide refuse
eq "C6 agent-call refused (rc 76, nothing billed): refused, no retry" "$(jq -r '[.outcome, .model_calls, .agent_call_rc] | join(":")' "$T/dec.out"):$(calls)" "refused:0:76:1"
jq -c --arg t "$TOK" --arg l "$(printf 'z%.0s' $(seq 1 12000))" '. + {log_excerpt: ("token " + $t + " " + $l)}' "$T/stall.json" > "$T/stall-big.json"
rm -f "$T/ac.log"; printf ok > "$T/ac.mode"
card unblock_card_decide "$T/stall-big.json" "$T/claim.json" "$T/dec.out"
check "C6 the prompt carries no token" '! grep -qF "$TOK" "$T/ac.prompt"'
check "C6 the record in the prompt is capped at 8 KB" '[ "$(wc -c < "$T/ac.prompt")" -lt $(( $(wc -c < "$PROMPT") + 8192 + 400 )) ]'

# C7: re-declaration and expiry.
redeclare_row() { jq -c --argjson l "$1" '{id, key, text, deadline_at, last_declared_at: ($l | todate)}' "$T/card.json" > "$T/row.json"; }
rm -f "$T/alerts.log"
redeclare_row "$NOW"
eq "C7 24 h after the send: REMIND" "$(UNBLOCK_ACT=1 card unblock_card_redeclare "$T/row.json" $((NOW + 86400)) act)" "REMIND u-3f9a2c"
eq "C7 one lane-alert call with the SAME id" "$(cut -d' ' -f1-3 "$T/alerts.log")" "--critical --id unblock-3f9a2c001122"
eq "C7 1 h after a send: wait, 0 calls" "$(UNBLOCK_ACT=1 card unblock_card_redeclare "$T/row.json" $((NOW + 3600)) act):$(wc -l < "$T/alerts.log" | tr -d ' ')" "wait:1"
eq "C7 past the deadline: expired, 0 calls" "$(UNBLOCK_ACT=1 card unblock_card_redeclare "$T/row.json" $((NOW + 72 * 3600)) act):$(wc -l < "$T/alerts.log" | tr -d ' ')" "expired:1"
eq "C7 shadow: WOULD_REMIND, 0 calls" "$(card unblock_card_redeclare "$T/row.json" $((NOW + 86400)) shadow):$(wc -l < "$T/alerts.log" | tr -d ' ')" "WOULD_REMIND u-3f9a2c:1"
rm -f "$T/alerts.log"
UNBLOCK_CARD_TTL_H=96 card unblock_card_compose "$T/stall.json" "$T/decide3.json" "$KEY" "$NOW" > "$T/card.json"
LAST=$NOW; RES=""
for h in $(seq 1 100); do
  redeclare_row "$LAST"
  r=$(UNBLOCK_ACT=1 card unblock_card_redeclare "$T/row.json" $((NOW + h * 3600)) act)
  case "$r" in REMIND*) LAST=$((NOW + h * 3600)); RES="$RES $h" ;; expired) RES="$RES x$h"; break ;; esac
done
eq "C7 hourly ticks over 4 days: reminders at 24, 48, 72 h, then expired at 96 h" "$RES" " 24 48 72 x96"
eq "C7 exactly 3 lane-alert calls, all the same id" "$(cut -d' ' -f3 "$T/alerts.log" | sort | uniq -c | tr -s ' ')" " 3 unblock-3f9a2c001122"
redeclare_row "$NOW"; cp "$T/la-fail" "$H/bin/lane-alert.sh"
out=$(UNBLOCK_ACT=1 card unblock_card_redeclare "$T/row.json" $((NOW + 86400)) act); rc=$?
eq "C7 a failed reminder send is rc 1 and says so" "$rc:$out" "1:REMIND_FAILED u-3f9a2c"
cp "$T/la-ok" "$H/bin/lane-alert.sh"
printf '{"id":"u-3f9a2c","deadline_at":"not a date","last_declared_at":"2026-10-20T15:00:00Z"}' > "$T/badrow.json"
card unblock_card_redeclare "$T/badrow.json" "$NOW" act > "$T/bad.out"; rc=$?
eq "C7 a row with no readable deadline: rc 1, no output" "$rc:$(cat "$T/bad.out")" "1:"
card unblock_card_compose "$T/missing-stall.json" "$T/decide3.json" "$KEY" "$NOW" > "$T/bad.out"; rc=$?
eq "C1 an unreadable stall record: rc 1, no card" "$rc:$(cat "$T/bad.out")" "1:"
card unblock_card_compose "$T/stall.json" "$T/decide3.json" "$KEY" "yesterday" > "$T/bad.out"; rc=$?
eq "C1 a clock that is not epoch seconds: rc 1, no card" "$rc:$(cat "$T/bad.out")" "1:"
card unblock_card_compose "$T/stall.json" "$T/decide3.json" "$KEY" "$NOW" > "$T/card.json"

# ═════ D: the answer grammar (bin/unblock-reply.sh) ══════════════════════════
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
m=GET; body=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift ;;
    --data-binary) body="$2"; shift ;;
    -H|-m|--connect-timeout|-w) shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
path="${url#http://jobs.invalid}"
printf '%s %s %s\n' "$m" "$path" "$body" >> "$FXT/reqlog"
if [ "$m" = GET ]; then
  if [ -s "$FXT/ledger.code" ]; then printf '\n%s' "$(cat "$FXT/ledger.code")"; exit 0; fi
  card="${path##*card=}"
  jq -c --arg c "$card" '{decisions: map(select(.card.id == $c and .outcome == "escalated"))}' "$FXT/ledger.json"
  printf '\n200'; exit 0
fi
code=$(cat "$FXT/post.code" 2>/dev/null); code="${code:-200}"
printf '{"ok":true}\n%s' "$code"
SH
chmod +x "$T/fakebin/curl"
jq -c '[{id: 17, outcome: "escalated", decision_key: .key, card: .}]' "$T/card.json" > "$T/ledger.json"
# reply <text> [from] [cmd] — one delivery through the shipped script. Prints
# "<rc>|<stdout>". TRANSPORT (default telegram) is the sidecar transport.
reply() {
  local out rc
  out=$(env HARNESS="$H" HARNESS_TEST_SANDBOX=1 FXT="$T" PATH="$T/fakebin:$PATH" JOBS_URL=http://jobs.invalid \
    HARNESS_SECRET=fixture-secret JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 BOX_CHAT_OWNERS="${OWNERS:-telegram:owner_a=owner@example.com}" \
    UNBLOCK_TRANSPORT="${TRANSPORT-telegram}" UNBLOCK_FROM_USER="${2-owner_a}" UNBLOCK_CMD_ID="${3-}" "$H/bin/unblock-reply.sh" intercept "$1" 2>/dev/null); rc=$?
  printf '%s|%s' "$rc" "$out"
}
posts() { grep -c '^POST ' "$T/reqlog" 2>/dev/null || true; }
ATTR='[telegram: from @owner_a]'
rm -f "$T/reqlog"
for t in "Tackler status" "Archie approve I3" "u-3f9a2c 1" "Tackler u-3f9a 1" "Tackler u-3f9a2c" \
         "$ATTR"$'\n'"hello"$'\n'"Tackler u-3f9a2c 1" "Tackler u-3f9a2c 1; rm -rf /" "Tackler U-3F9A2C 1" \
         "please see Tackler u-3f9a2c 1" "/box list"; do
  eq "D1 not ours: [$(printf '%s' "$t" | tr '\n' '/')]" "$(reply "$t")" "1|"
done
check "D1 0 HTTP calls for every non-match" '[ ! -s "$T/reqlog" ]'
for t in "Tackler u-3f9a2c 9" "tackler, u-3f9a2c 2" "Tackler: u-3f9a2c hold wait for #7709" "$ATTR"$'\n'"Tackler u-3f9a2c 9"; do
  check "D1 parses: [$(printf '%s' "$t" | tr '\n' '/')]" '[[ $(reply "$t") == 0\|Tackler:* ]]'
done

rm -f "$T/reqlog"; scratch_rm "$H/state/unblock-replies"
R1=$(reply "$ATTR"$'\n'"Tackler u-3f9a2c 1" owner_a c41)
R2=$(reply "$ATTR"$'\n'"Tackler u-3f9a2c 1" owner_a c41)
eq "D2 first delivery recorded" "$R1" "0|Tackler: recorded answer 1 for u-3f9a2c (pool:alpha). It runs on the next Tackler tick."
eq "D2 second delivery, same command id: already recorded" "$R2" "0|Tackler: already recorded under command c41."
eq "D2 exactly one POST" "$(posts)" 1
check "D2 the POST carries the answer, the owner and the command id" \
  'grep "^POST " "$T/reqlog" | grep -q "^POST /api/unblock/decisions/17/answer {\"answer\":\"1\",\"answered_by\":\"owner@example.com\",\"command_id\":\"c41\"}$"'
check "D2 the marker is on disk" '[ -s "$H/state/unblock-replies/c41" ]'
rm -f "$T/reqlog"
printf 409 > "$T/post.code"
eq "D2 the worker already holds the command id (409): already recorded" "$(reply "Tackler u-3f9a2c 2" owner_a c42)" "0|Tackler: already recorded under command c42."
check "D2 ... and the marker is written" '[ -s "$H/state/unblock-replies/c42" ]'
printf 500 > "$T/post.code"
eq "D2 a 500 on the POST: not recorded, no marker" "$(reply "Tackler u-3f9a2c 2" owner_a c43):$([ -e "$H/state/unblock-replies/c43" ] && echo marker || echo none)" \
  "0|Tackler: answer 2 for u-3f9a2c was not recorded (HTTP 500).:none"
rm -f "$T/post.code"
rm -f "$T/reqlog"
eq "D2 no command id: no local dedup, the worker's key is the backstop" "$(reply "Tackler u-3f9a2c 1" owner_a "" | cut -c1-31)" "0|Tackler: recorded answer 1 fo"
eq "D2 a command id that is not a safe file name: no marker path built" "$(reply "Tackler u-3f9a2c 1" owner_a "../x" | cut -c1-31):$(ls "$H/state" | tr '\n' ' ')" "0|Tackler: recorded answer 1 fo:unblock-replies "

rm -f "$T/reqlog"
eq "D3 option 9 on a 3-option card: not an option" "$(reply "Tackler u-3f9a2c 9" owner_a c50)" "0|Tackler: 9 is not an option on u-3f9a2c (1-3). Nothing recorded."
eq "D3 option 0: not an option" "$(reply "Tackler u-3f9a2c 0" owner_a c51)" "0|Tackler: 0 is not an option on u-3f9a2c (1-3). Nothing recorded."
eq "D3 0 POST" "$(posts)" 0
eq "C8 the composed card's options count reaches the reply (3 is an option)" "$(reply "Tackler u-3f9a2c 3" owner_a c52 | cut -c1-35)" "0|Tackler: recorded answer 3 for u-"
eq "D3 no open card with that id" "$(reply "Tackler u-000000 1" owner_a c53)" "0|Tackler: no open card u-000000. Nothing recorded."

cp "$T/ledger.json" "$T/ledger.ok"; jq -c 'map(del(.id))' "$T/ledger.ok" > "$T/ledger.json"; rm -f "$T/reqlog"
eq "D4 a ledger row with no id: says so, 0 POST" "$(reply "Tackler u-3f9a2c 1" owner_a c59):$(posts)" "0|Tackler: the decision ledger row for u-3f9a2c has no usable id. Nothing recorded.:0"
cp "$T/ledger.ok" "$T/ledger.json"
rm -f "$T/reqlog"; printf 404 > "$T/ledger.code"
eq "D4 ledger GET 404: did not answer" "$(reply "Tackler u-3f9a2c 1" owner_a c60)" "0|Tackler: the decision ledger did not answer (HTTP 404). Nothing recorded."
printf 503 > "$T/ledger.code"
eq "D4 ledger GET 503: did not answer" "$(reply "Tackler u-3f9a2c 1" owner_a c61)" "0|Tackler: the decision ledger did not answer (HTTP 503). Nothing recorded."
eq "D4 0 POST, no marker" "$(posts):$([ -e "$H/state/unblock-replies/c60" ] && echo marker || echo none)" "0:none"
rm -f "$T/ledger.code"

rm -f "$T/reqlog"
eq "D5 a non-owner: only an owner" "$(reply "Tackler u-3f9a2c 1" stranger c70)" "0|Tackler: only an owner can answer a Tackler card. Nothing recorded."
eq "D5 no sender: only an owner" "$(reply "Tackler u-3f9a2c 1" "" c71 | cut -c1-35)" "0|Tackler: only an owner can answer"
eq "D5 a broken owner map: nobody resolves" "$(OWNERS='telegram:owner_a=owner@example.com,garbage' reply "Tackler u-3f9a2c 1" owner_a c72 | cut -c1-35)" "0|Tackler: only an owner can answer"
eq "D5 an owner listed with two emails: nobody resolves" "$(OWNERS='telegram:owner_a=owner@example.com,telegram:owner_a=other@example.com' reply "Tackler u-3f9a2c 1" owner_a c73 | cut -c1-35)" "0|Tackler: only an owner can answer"
eq "D5 a Slack sender with an owner's username: only an owner" "$(TRANSPORT=slack reply "Tackler u-3f9a2c 1" owner_a c75)" "0|Tackler: only an owner can answer a Tackler card. Nothing recorded."
eq "D5 a Slack attribution line with an owner's username: only an owner" "$(TRANSPORT=slack reply "[slack: from owner_a]"$'\n'"Tackler u-3f9a2c 1" owner_a c76 | cut -c1-35)" "0|Tackler: only an owner can answer"
eq "D5 no transport: only an owner" "$(TRANSPORT= reply "Tackler u-3f9a2c 1" owner_a c77 | cut -c1-35)" "0|Tackler: only an owner can answer"
check "D5 0 HTTP calls for a non-owner" '[ ! -s "$T/reqlog" ]'
eq "D5 case and @ do not matter" "$(reply "Tackler u-3f9a2c 1" @Owner_A c74 | cut -c1-31)" "0|Tackler: recorded answer 1 fo"

rm -f "$T/reqlog"
eq "D6 hold with a note" "$(reply "Tackler u-3f9a2c hold wait for #7709" owner_a c80)" "0|Tackler: recorded hold for u-3f9a2c (pool:alpha). It stays parked."
check "D6 the POST carries answer hold and the note" \
  'grep -q "^POST /api/unblock/decisions/17/answer {\"answer\":\"hold\",\"answered_by\":\"owner@example.com\",\"command_id\":\"c80\",\"note\":\"wait for #7709\"}$" "$T/reqlog"'

# ═════ E: the orchestrate.sh block ═══════════════════════════════════════════
SRC="$DIR/bin/orchestrate.sh"
BLOCK=$(sed -n '/^# >>> tackler reply intercept/,/^# <<< tackler reply intercept/p' "$SRC")
check "E1 the block exists and runs unblock-reply.sh intercept" 'grep -q "unblock-reply.sh\" intercept" <<<"$BLOCK"'
run_block() {
  rm -rf "$T/orc"; mkdir -p "$T/orc"; rm -f "$T/delivered" "$T/fell" "$T/orc-context.log"
  printf '%s' "$BLOCK" > "$T/block.sh"
  env HARNESS_TEST_SANDBOX=1 FXT="$T" HARNESS="$1" ORC="$T/orc" TEXT="$2" CMD_ID=c9 META_FROM_USER=owner_a META_TRANSPORT="${3-telegram}" \
    bash -c 'set -uo pipefail
      deliver_reply() { printf "%s" "$1" > "$FXT/delivered"; }
      archie_sign() { printf "%s\n\nArchie\n" "$1"; }
      . "$FXT/block.sh"
      : > "$FXT/fell"' > /dev/null 2>&1
}
SH_="$T/stubh"; mkdir -p "$SH_/bin"
printf '#!/bin/bash\nprintf "%%s %%s\\n" "$*" "$FXT" >> "$FXT/orc-context.log"\n' > "$SH_/bin/orc-context.sh"
printf '#!/bin/bash\nprintf "%%s|%%s|%%s|%%s\\n" "$UNBLOCK_TRANSPORT" "$UNBLOCK_FROM_USER" "$UNBLOCK_CMD_ID" "$2" > "$FXT/stub.args"\necho "Tackler: R"\n' > "$SH_/bin/unblock-reply.sh"
chmod +x "$SH_/bin/unblock-reply.sh" "$SH_/bin/orc-context.sh"
run_block "$SH_" "Tackler u-3f9a2c 1"
check "E1 stub rc 0: delivered once, unsigned (Tackler is not Archie), the turn never ran" '[ "$(cat "$T/delivered")" = "Tackler: R" ] && [ ! -e "$T/fell" ]'
eq "E1 the transport, the sender and the command id reach the script" "$(cat "$T/stub.args")" "telegram|owner_a|c9|Tackler u-3f9a2c 1"
run_block "$SH_" "Tackler u-3f9a2c 1" slack
eq "E1 a Slack transport reaches the script as slack" "$(cut -d'|' -f1 "$T/stub.args")" "slack"
check "E1 the turn is recorded for the next lane, last-reply.txt replaced" 'grep -q "^append tackler " "$T/orc-context.log" && [ "$(cat "$T/orc/last-reply.txt")" = "Tackler: R" ]'
printf '#!/bin/bash\nexit 1\n' > "$SH_/bin/unblock-reply.sh"
run_block "$SH_" "hello"
check "E1 stub rc 1: no delivery, falls through" '[ -e "$T/fell" ] && [ ! -e "$T/delivered" ]'
rm -f "$SH_/bin/unblock-reply.sh"; run_block "$SH_" "Tackler u-3f9a2c 1"
check "E1 no script: falls through" '[ -e "$T/fell" ] && [ ! -e "$T/delivered" ]'
check "E1 the block sits after the box request block and before orct_claim" \
  'a=$(grep -n "^# <<< box request intercept" "$SRC" | cut -d: -f1); b=$(grep -n "^# >>> tackler reply intercept" "$SRC" | cut -d: -f1); c=$(grep -n "^orct_claim " "$SRC" | head -1 | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]'
# The real script through the real block: a full delivery end to end.
rm -f "$T/reqlog"
rm -rf "$T/orc"; mkdir -p "$T/orc"; rm -f "$T/delivered" "$T/fell"
env HARNESS_TEST_SANDBOX=1 FXT="$T" HARNESS="$H" ORC="$T/orc" TEXT="$ATTR"$'\n'"Tackler u-3f9a2c 2" CMD_ID=c90 META_FROM_USER=owner_a META_TRANSPORT=telegram \
  PATH="$T/fakebin:$PATH" JOBS_URL=http://jobs.invalid HARNESS_SECRET=fixture-secret JOBS_RETRIES=0 BOX_CHAT_OWNERS=telegram:owner_a=owner@example.com \
  bash -c 'set -uo pipefail
    deliver_reply() { printf "%s" "$1" > "$FXT/delivered"; }
    archie_sign() { printf "%s\n\nArchie\n" "$1"; }
    . "$FXT/block.sh"
    : > "$FXT/fell"' > /dev/null 2>&1
eq "E1 the shipped script through the block: recorded and delivered" "$(cut -c1-37 "$T/delivered" 2>/dev/null)" "Tackler: recorded answer 2 for u-3f9a"
check "E1 ... and the turn did not run" '[ ! -e "$T/fell" ]'

# ═════ F: the settings seeds ═════════════════════════════════════════════════
LIST='lane.fly-pool-tick.pool_tick_max_parallel,hub_load.shed,lane.fly-pool.*.pool_record_read,lane_placement.*,conductor_remote_spawn.*'
F=$(python3 - "$FRAG" <<'PY'
import sqlite3, sys
db = sqlite3.connect(":memory:")
db.execute("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, note TEXT, actor TEXT, updated_at TEXT NOT NULL)")
sql = open(sys.argv[1]).read()
db.executescript(sql); db.executescript(sql)
rows = dict(db.execute("SELECT key, value FROM settings").fetchall())
print(rows.get("unblock.knob_allowlist", "-"))
print(rows.get("lane.unblock.unblock_box_hung_min", "-"), rows.get("lane.unblock.unblock_respawn_max_day", "-"))
print(len(rows), sum(1 for k in rows if k.startswith("unblock.project.")))
PY
); rc=$?
eq "F1 applied twice: rc 0" "$rc" 0
eq "F1 the allowlist is exactly the operator's five entries (6294290004 item 3)" "$(sed -n 1p <<<"$F")" "$LIST"
eq "F1 the two lane seeds" "$(sed -n 2p <<<"$F")" "30 6"
eq "F1 three rows, no unblock.project.* mode row (act mode not flipped)" "$(sed -n 3p <<<"$F")" "3 0"
check "F1 the fixtures carry the same allowlist as the seed" \
  '[ "$(jq -r ".routes[\"/api/settings/unblock.knob_allowlist\"].setting.value" "$DIR/tests/fixtures/unblock/pool-project-6.json")" = "$LIST" ]'
check "F1 the llm site names the card lib and its marker" \
  'jq -e ".[0].script == \"bin/lib/unblock/card.sh\" and .[0].stage == \"unblock\"" "$SITE" >/dev/null && grep -qF "$(jq -r ".[0].marker" "$SITE")" "$CARD"'

echo "unblock-card: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
