#!/bin/bash
# tests/archie-autonomy.bh-4067-test.sh — BH-4067 (BH-3966.6): Archie's earned
# autonomy, driven through the SHIPPED bin/archie.sh (the tick and the chat
# intercept) the way tests/archie-initiative-tracer-test.sh drives it.
#
# The ticket's four cases:
#   5 agreements -> delegation proposal                  (C1, C1b, C2)
#   approval -> class auto-handled + after-report        (C3, K1)
#   one overrule -> reverted                             (C4, C4b)
#   non-delegable class never proposed regardless of streak (C5, C6, K3, H3)
#
# WHAT IS STUBBED. A scratch harness ($H: a symlink tree of the repo's bin/, a
# copy of catalog/lanes.d and the two prompt files) with an agent-call.sh that
# answers $T/ac.text, a beat.sh that appends to $T/beats.jsonl and an
# alert-line.sh that appends to $T/alerts.log. ARCHIE_FIXTURE=$T/fx.sh replaces
# _jobs_req with a jq model over $T/db.json of the initiative routes AND the
# three BH-4067 routes (worker/jobs/src/routes/archie-autonomy.js): the same
# status codes and the same rules (auto only for a delegated, unprotected,
# non-sensitive class; a choice counts once; delegate refused when protected or
# not earned). The worker itself runs for real in the node suite at the end
# (worker/jobs/test/archie-autonomy.bh-4067.test.js over schema.sql). PATH
# carries a curl and a gh that log and fail: nothing here reaches the network.
#
# Sections: H1-H4 (helpers), K1-K7 (the tick), C1-C9 (the intercept),
# X1-X4 (mutations, D1), then the node suite.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-autonomy.bh-4067-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "archie-autonomy: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
# The expected reply lines live in variables: as literals inside a check's eval
# string, their `<what> /` reads as a redirect to / to bin/test-trace-safety.sh.
ASK_LINE='Reply: Archie approve I1 / Archie change I1 <what> / Archie drop I1'
OVERRULE_LINE='Overrule: Archie change I1 <what> / Archie drop I1'

# The product paths this ticket ships (D41).
for f in "$DIR/bin/archie.sh" "$DIR/bin/lib/archie.sh" "$DIR/worker/jobs/src/routes/archie-autonomy.js" \
         "$DIR/worker/jobs/test/archie-autonomy.bh-4067.test.js" "$DIR/catalog/prompts/archie-check.md" \
         "$DIR/catalog/lanes.d/archie.json" "$DIR/prompts/archie-soul.d/10-authority.md"; do
  [ -f "$f" ] && ok || bad "missing $f"
done

# ═════ H: the helpers, sourced from the repo ═════════════════════════════════
# shellcheck source=../bin/lib/archie.sh
. "$DIR/bin/lib/archie.sh" || { echo "FAIL: cannot source bin/lib/archie.sh"; exit 1; }
pc() { archie_parse_cmd "$1"; }
eq "H1 delegate, lowercased once"  "$(pc 'Archie delegate Watch-Cadence')" $'delegate\twatch-cadence'
eq "H1 ask first"                  "$(pc 'archie, ask first watch-cadence')" $'askfirst\twatch-cadence'
check "H1 bare delegate asks"      '[ "$(pc "Archie delegate" | cut -f1)" = ask ]'
check "H1 bare ask first asks"     '[ "$(pc "Archie ask first" | cut -f1)" = ask ]'
for neg in 'please delegate this' 'delegate watch-cadence' 'Archie delegate ../x' 'Archie delegate watch cadence' \
           'Archie, ask first' 'Archie, ask first?' 'can archie delegate merge?'; do
  out=$(pc "$neg"); rc=$?
  if [ "$rc" = 0 ] && [ "$(cut -f1 <<<"$out")" != ask ]; then bad "H1 [$neg] must not parse as a command ($out)"; else ok; fi
done
# The existing grammar is untouched (the tracer's P1-P3 pin the bytes).
eq "H1 approve unchanged" "$(pc 'Archie approve I7')" $'reply\tapprove\t7\t'

sc() { archie_split_class "$1"; }
eq "H2 split a CLASS line" "$(sc $'CLASS: watch-cadence\nCheck weekly.')" $'watch-cadence\nCheck weekly.'
eq "H2 uppercase class normalises" "$(sc $'CLASS: Merge\nMerge it.')" $'merge\nMerge it.'
for raw in $'Check weekly.' $'CLASS: ../x\nCheck weekly.' $'CLASS: watch-cadence; merge\nCheck weekly.' $'CLASS:\nCheck weekly.'; do
  eq "H2 [$(head -1 <<<"$raw")] is unclassified, text kept" "$(sc "$raw")" "unclassified"$'\n'"$raw"
done

sens() { archie_sensitive "$@" && echo yes || echo no; }
for c in merge deploy production spend client-board; do
  eq "H3 class $c is sensitive" "$(sens "$c" 'Keep the queue short' 'Keep watching.')" yes
done
while IFS= read -r rec; do
  [ -n "$rec" ] || continue
  eq "H3 [$rec] is sensitive" "$(sens watch-cadence 'Keep the queue short' "$rec")" yes
done <<'EOF'
Merge #4120 now, it's green
Land the train before 5pm
Deploy the worker
Push the release
Roll back prod
Bump the spend cap to $40
This costs $12 a day, cut it
Reply to the client on the project-1 board
Ask the customer
Rotate the prod key
Run the migration
EOF
eq "H3 a billing goal"  "$(sens watch-cadence 'Cut billing errors' 'Keep watching.')" yes
eq "H3 a budget goal"   "$(sens watch-cadence 'Stay inside the budget' 'Keep watching.')" yes
while IFS='|' read -r c rec; do
  eq "H3 [$rec] is NOT sensitive" "$(sens "$c" 'Tracer-first slicing cuts rework' "$rec")" no
done <<'EOF'
watch-continue|Keep watching, decomposed rate held at 0.12
watch-cadence|Check weekly instead of daily
watch-stop|Drop this goal, it hit target
ticket-file|File a ticket for the flaky lint
EOF

A=$(archie_compose 'Check weekly.' 'Goal g' 9 always '[]' 1 600)
B=$(archie_compose 'Check weekly.' 'Goal g' 9 always '[]' 1 600 '')
eq "H4 an empty 8th arg changes nothing" "$B" "$A"
check "H4 the ask body asks" 'grep -qxF "$ASK_LINE" <<<"$A"'
C=$(archie_compose 'Check weekly.' 'Goal g' 9 always '[]' 1 600 auto:watch-cadence)
eq "H4 the after-report leads with the standing OK" "$(head -1 <<<"$C")" "Handled under your standing OK for watch-cadence: Check weekly."
check "H4 the after-report offers the overrule ($C)" 'grep -qxF "$OVERRULE_LINE" <<<"$C"'
check "H4 the after-report does not ask for approval" '! grep -qF "Archie approve" <<<"$C"'
eq "H4 still signed" "$(tail -1 <<<"$C")" Archie

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/catalog/prompts" "$H/prompts" "$H/env" "$H/logs" "$T/fakebin"
cp -rs "$DIR/bin" "$H/bin"
cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
[ -d "$DIR/catalog/switches.d" ] && cp -r "$DIR/catalog/switches.d" "$H/catalog/"
cp -r "$DIR/prompts/archie-soul.d" "$H/prompts/" 2>/dev/null
cp "$DIR/catalog/prompts/archie-check.md" "$H/catalog/prompts/" 2>/dev/null
: > "$H/env/global.env"
rm -f "$H/bin/agent-call.sh" "$H/bin/beat.sh" "$H/bin/archie-tg-send.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s|%s\n' "$*" "${AGENT_CALL_FP:-}" >> "$FXT/agentcalls"
cat "$FXT/ac.text" > "$5"
exit 0
SH
cat > "$H/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$FXT/beats.jsonl"
printf 'BEAT\n' >> "$FXT/reqlog"
exit 0
SH
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts.log"
exit 0
SH
cp "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
# BH-4779: Archie's Telegram transport, captured where the beats were.
cat > "$H/bin/archie-tg-send.sh" <<'SH'
#!/bin/bash
jq -nc --arg a "$1" --arg l "$2" '{akey: $a, line: $l}' >> "$FXT/beats.jsonl"
printf 'BEAT\n' >> "$FXT/reqlog"
exit "$(cat "$FXT/beat.rc" 2>/dev/null || echo 0)"
SH
chmod +x "$H/bin/agent-call.sh" "$H/bin/beat.sh" "$H/bin/archie-tg-send.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
for c in curl gh; do
  printf '#!/bin/bash\nprintf "%%s %%s\\n" %s "$*" >> "$FXT/net.log"\nexit 7\n' "$c" > "$T/fakebin/$c"
  chmod +x "$T/fakebin/$c"
done

# The worker, modelled in jq over $T/db.json. _jobs_req's rc contract
# (bin/lib/jobs/req.sh): 0 on a 2xx, 9 on 409 (body printed), 2 on 404, 1 on
# anything else. The protected-name regex is archie-autonomy.js's.
cat > "$T/fx.sh" <<'SH'
PROT='client|customer|money|spend|cost|budget|billing|invoice|price|prod|merge|deploy|release|unclassified'
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" out code=200 id
  JOBS_HTTP=""; JOBS_BODY=""
  case "$p" in /api/settings*|/api/flags*|/api/lanes*)
    [ "$p" = /api/settings ] && { cat "$FXT/settings.json" 2>/dev/null || printf '{"settings":[]}'; JOBS_HTTP=200; return 0; }
    JOBS_HTTP=404; return 2 ;;
  esac
  printf '%s %s %s\n' "$m" "$p" "$b" >> "$FXT/reqlog"
  [ -f "$FXT/jobs.down" ] && { JOBS_HTTP=503; return 1; }
  qp() { printf '%s' "$p" | sed -n "s/.*[?&]$1=\([^&]*\).*/\1/p"; }
  local db="$FXT/db.json"
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
      jq --argjson b "$b" '
        ("check:\($b.id):\($b.due_at)") as $k
        | .events[$k] = {kind: "check", status: $b.status, value: $b.value,
            body: ($b.body // .events[$k].body), attempts: ($b.attempts // .events[$k].attempts // 0)}
        | .initiatives |= map(if .id == $b.id then .last_check_status = $b.status
            | (if $b.advance_to != null then .next_check_at = $b.advance_to else . end) else . end)' \
        "$db" > "$db.tmp" && mv "$db.tmp" "$db"
      out='{"ok":true}' ;;
    "POST /api/initiatives/reply")
      id=$(jq -r .id <<<"$b")
      jq -e --argjson i "$id" '.initiatives[] | select(.id == $i)' "$db" >/dev/null || { JOBS_HTTP=404; return 2; }
      jq --argjson b "$b" '.events[$b.dedupe_key] = {kind: "reply", status: $b.decision, actor: $b.actor}
          | .initiatives |= map(if .id == $b.id then .last_decision = $b.decision
          | (if $b.decision == "drop" then .status = "dropped" else . end) else . end)' \
        "$db" > "$db.tmp" && mv "$db.tmp" "$db"
      out='{"ok":true}'; code=201 ;;
    "POST /api/archie/decisions")
      [ -f "$FXT/ledger.down" ] && { JOBS_HTTP=503; return 1; }
      out=$(jq -c --argjson b "$b" '.decisions[] | select(.escalation_key == $b.escalation_key)' "$db")
      if [ -n "$out" ]; then
        if [ "$(jq -r --argjson b "$b" '.recommendation == $b.recommendation' <<<"$out")" = true ]; then
          out=$(jq -c '{ok: true, existing: true, decision: .}' <<<"$out")
        else
          JOBS_HTTP=409; JOBS_BODY=$(jq -c '{error: "different payload", decision: .}' <<<"$out"); printf '%s' "$JOBS_BODY"; return 9
        fi
      else
        jq --argjson b "$b" --arg prot "$PROT" --arg allauto "$([ -f "$FXT/x.allauto" ] && echo 1)" '
          ($b.class | ascii_downcase | ltrimstr(" ") | rtrimstr(" ")) as $c0
          | (if .classes[$c0] == null then "unclassified" else $c0 end) as $c
          | (.classes[$c].never_delegable == 1 or ($c | test($prot))) as $p
          | (if $allauto == "1" or (.classes[$c].state == "delegated" and ($p | not) and ($b.sensitive | not))
             then "auto" else "ask" end) as $mode
          | .decisions += [{id: (.decisions | length + 1), escalation_key: $b.escalation_key,
              initiative_id: $b.initiative_id, class: $c, sensitive: $b.sensitive,
              recommendation: $b.recommendation, mode: $mode,
              auto_choice: (if $mode == "auto" then "approve" else null end),
              choice: null, choice_key: null, counted: 0}]
          | if $mode == "auto" then
              .events["reply:\($b.initiative_id):auto-\($b.escalation_key | @base64 | .[0:16])"] = {kind: "reply", status: "approve", actor: "archie"}
              | .initiatives |= map(if .id == $b.initiative_id then .last_decision = "approve" else . end)
            else . end' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
        out=$(jq -c '{ok: true, created: true, decision: .decisions[-1]}' "$db"); code=201
      fi ;;
    "POST /api/archie/decisions/choice")
      out=$(jq -c --argjson b "$b" --arg prot "$PROT" '
        ([.decisions[] | select(.initiative_id == $b.initiative_id)] | last) as $d
        | def st($c; $counted; $rev): {ok: true, counted: $counted, class: $c, state: .classes[$c].state,
            streak: .classes[$c].streak, protected: (.classes[$c].never_delegable == 1 or ($c | test($prot))),
            reverted: $rev};
          if $d == null then {db: ., out: {ok: true, counted: false}}
          elif $d.choice_key == $b.choice_key then {db: ., out: st($d.class; ($d.counted == 1); false)}
          elif $d.choice != null then {db: ., out: st($d.class; false; false)}
          else
            ((.classes[$d.class].never_delegable == 1 or ($d.class | test($prot))) | not) as $deleg
            | ($deleg and ($d.sensitive | not) and $b.choice == "approve") as $count
            | (.classes[$d.class].state == "delegated" and $b.choice != "approve") as $rev
            | .decisions |= map(if .id == $d.id then .choice = $b.choice | .choice_key = $b.choice_key
                | .counted = (if $count then 1 else 0 end) else . end)
            | (if $count then .classes[$d.class].streak += 1
               elif $b.choice != "approve" then .classes[$d.class].streak = 0 | .classes[$d.class].state = "ask_first"
               else . end)
            | {db: ., out: st($d.class; $count; $rev)}
          end' "$db")
      jq '.db' <<<"$out" > "$db.tmp" && mv "$db.tmp" "$db"
      out=$(jq -c '.out' <<<"$out") ;;
    "POST /api/archie/classes/delegation")
      local c dec ms
      c=$(jq -r '.class | ascii_downcase' <<<"$b"); dec=$(jq -r .decision <<<"$b"); ms=$(jq -r '.min_streak // 0' <<<"$b")
      jq -e --arg c "$c" '.classes[$c]' "$db" >/dev/null || { JOBS_HTTP=404; JOBS_BODY='{"error":"class not found"}'; return 2; }
      if [ "$dec" = delegate ]; then
        if jq -e --arg c "$c" --arg prot "$PROT" '.classes[$c].never_delegable == 1 or ($c | test($prot))' "$db" >/dev/null; then
          JOBS_HTTP=409; JOBS_BODY='{"error":"never_delegable"}'; printf '%s' "$JOBS_BODY"; return 9
        fi
        if jq -e --arg c "$c" --argjson ms "$ms" '.classes[$c].state != "delegated" and .classes[$c].streak < $ms' "$db" >/dev/null; then
          JOBS_HTTP=409; JOBS_BODY=$(jq -c --arg c "$c" '{error: "not_earned", streak: .classes[$c].streak}' "$db"); printf '%s' "$JOBS_BODY"; return 9
        fi
        jq --arg c "$c" '.classes[$c].state = "delegated"' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
      else
        jq --arg c "$c" '.classes[$c].state = "ask_first" | .classes[$c].streak = 0' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
      fi
      out=$(jq -c --arg c "$c" '{ok: true, class_state: (.classes[$c] + {class: $c})}' "$db") ;;
    *) JOBS_HTTP=404; return 2 ;;
  esac
  JOBS_HTTP=$code; JOBS_BODY="$out"; printf '%s' "$out"; return 0
}
lane_role_model() { [ "$1" = stage.archie ] || return 75; echo test-model; }
SH

export HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.invalid HARNESS_SECRET=test
unset ARCHIE_ENABLED ARCHIE_MAX_PER_TICK ARCHIE_DEFAULT_CADENCE_H ARCHIE_MAX_ATTEMPTS ARCHIE_TEXT_MAX_CHARS \
  ARCHIE_LLM_MAX_USD ARCHIE_NOW ARCHIE_FIXTURE ARCHIE_CMD_ID ARCHIE_TIMED BEAT_STRICT ARCHIE_DELEGATE_AFTER 2>/dev/null || true

NOW=1791184500                       # 2026-10-05T07:15:00Z
REC='Check weekly instead of daily.'
CLASSES='{"watch-continue":{"never_delegable":0,"state":"ask_first","streak":0},
  "watch-cadence":{"never_delegable":0,"state":"ask_first","streak":0},
  "watch-stop":{"never_delegable":0,"state":"ask_first","streak":0},
  "ticket-file":{"never_delegable":0,"state":"ask_first","streak":0},
  "hold-resume":{"never_delegable":0,"state":"ask_first","streak":0},
  "client-board":{"never_delegable":1,"state":"ask_first","streak":0},
  "spend":{"never_delegable":1,"state":"ask_first","streak":0},
  "production":{"never_delegable":1,"state":"ask_first","streak":0},
  "merge":{"never_delegable":1,"state":"ask_first","streak":0},
  "deploy":{"never_delegable":1,"state":"ask_first","streak":0},
  "unclassified":{"never_delegable":1,"state":"ask_first","streak":0}}'

# reset [class=state:streak ...]: one active initiative I1, due, the 11 classes.
reset() {
  local p kv
  for p in reqlog beats.jsonl agentcalls alerts.log net.log out rc settings.json ledger.down jobs.down x.allauto; do
    scratch_rm "$T/$p" || exit 1
  done
  scratch_rm "$H/state" || exit 1; scratch_rm "$H/locks" || exit 1; scratch_rm "$H/logs/archie.log" || exit 1
  printf 'CLASS: watch-cadence\n%s\n' "$REC" > "$T/ac.text"
  jq -nc --argjson cl "$CLASSES" '{initiatives: [{id: 1, slug: "queue", goal: "Keep the review queue short",
      metric_query: "none", cadence_hours: 168, escalation_rule: "always", status: "active",
      next_check_at: "2026-10-05T07:00:00Z", links: [], last_value: null}],
    events: {}, decisions: [], classes: $cl}' > "$T/db.json"
  for kv in "$@"; do
    jq --arg c "${kv%%=*}" --arg s "$(cut -d= -f2 <<<"$kv" | cut -d: -f1)" --argjson n "${kv##*:}" \
      '.classes[$c].state = $s | .classes[$c].streak = $n' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
  done
  : > "$T/reqlog"; DUE_N=0
}
# due_again: I1 due once more, on a fresh slot (a new escalation key).
due_again() {
  DUE_N=$((DUE_N + 1))
  jq --arg d "$(printf '2026-10-05T06:%02d:00Z' "$DUE_N")" '.initiatives[0].next_check_at = $d | .initiatives[0].status = "active"' \
    "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
}
tick() {
  env HARNESS_TEST_SANDBOX=1 ARCHIE_NOW="$NOW" ARCHIE_FIXTURE="$T/fx.sh" LANE_GATE_DISABLE=1 \
    bash "$H/bin/${ARCHIE_BIN:-archie.sh}" tick > "$T/out" 2>&1
  echo $? > "$T/rc"
}
icpt() {
  env HARNESS_TEST_SANDBOX=1 ARCHIE_NOW="$NOW" ARCHIE_FIXTURE="$T/fx.sh" ARCHIE_CMD_ID="${CMD:-}" \
    bash "$H/bin/${ARCHIE_BIN:-archie.sh}" intercept "$1" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
n()      { local c; c=$(wc -l 2>/dev/null < "$1"); printf '%s' "${c:-0}" | tr -d ' '; }
calls()  { n "$T/agentcalls"; }
beats()  { n "$T/beats.jsonl"; }
line()   { sed -n "${1:-\$}p" "$T/beats.jsonl" | jq -r .line; }
clsf()   { jq -r --arg c "$1" --arg f "$2" '.classes[$c][$f]' "$T/db.json"; }
lastd()  { jq -r --arg f "$1" '.decisions[-1][$f] | tostring' "$T/db.json"; }
out()    { cat "$T/out"; }
# round <cmd-id> [decision text]: one escalation through the tick, then the operator's answer.
round() { due_again; tick; CMD="$1" icpt "${2:-Archie approve I1}"; }

# ═════ K: the tick ═══════════════════════════════════════════════════════════
# K1 (AT2): a delegated class is handled and reported after.
reset watch-cadence=delegated:5
due_again; tick
eq "K1 rc 0" "$(cat "$T/rc")" 0
eq "K1 exactly one model call" "$(calls)" 1
eq "K1 exactly one beat" "$(beats)" 1
eq "K1 the after-report leads with the standing OK" "$(line 1 | head -1)" "Handled under your standing OK for watch-cadence: $REC"
check "K1 the after-report offers the overrule" 'line 1 | grep -qxF "$OVERRULE_LINE"'
check "K1 the CLASS line never reaches the operator" '! line 1 | grep -q "CLASS:"'
check "K1 the act is recorded: an auto approve by archie" \
  'jq -e "[.events | to_entries[] | select(.key | test(\"^reply:1:auto-\")) | select(.value.status == \"approve\" and .value.actor == \"archie\")] | length == 1" "$T/db.json" >/dev/null'
eq "K1 the initiative carries the approve" "$(jq -r '.initiatives[0].last_decision' "$T/db.json")" approve
eq "K1 the ledger row: class" "$(lastd class)" watch-cadence
eq "K1 the ledger row: mode" "$(lastd mode)" auto
eq "K1 the ledger row: recommendation" "$(lastd recommendation)" "$REC"
DL=$(grep -n '^POST /api/archie/decisions ' "$T/reqlog" | head -1 | cut -d: -f1)
BL=$(grep -n '^BEAT$' "$T/reqlog" | head -1 | cut -d: -f1)
CL=$(grep -n '"status":"composed"' "$T/reqlog" | head -1 | cut -d: -f1)
check "K1 the act came BEFORE the composed write and the beat (decisions=$DL composed=$CL beat=$BL)" \
  '[ -n "$DL" ] && [ -n "$CL" ] && [ -n "$BL" ] && [ "$DL" -lt "$CL" ] && [ "$CL" -lt "$BL" ]'
eq "K1 the event is sent" "$(jq -r '.events["check:1:2026-10-05T06:01:00Z"].status' "$T/db.json")" sent

# K2: the ledger does not answer -> the ordinary ask, and a warn line.
reset watch-cadence=delegated:5; : > "$T/ledger.down"
due_again; tick
eq "K2 the ask body" "$(line 1 | head -1)" "$REC"
check "K2 asks for approval" 'line 1 | grep -qxF "$ASK_LINE"'
check "K2 a warn line ($(cat "$H/logs/archie.log" 2>/dev/null))" 'grep -q "warn: initiative 1: decision ledger unavailable" "$H/logs/archie.log"'
eq "K2 no act recorded" "$(jq -r '.initiatives[0].last_decision // "none"' "$T/db.json")" none

# K3: a sensitive recommendation on a delegated class -> ask, and it never counts.
reset watch-cadence=delegated:5
printf 'CLASS: watch-cadence\nMerge #4120 now, it is green.\n' > "$T/ac.text"
due_again; tick
eq "K3 the ask body" "$(line 1 | head -1)" "Merge #4120 now, it is green."
eq "K3 the ledger row says sensitive" "$(lastd sensitive)" true
eq "K3 the ledger row is ask" "$(lastd mode)" ask
CMD=k3 icpt "Archie approve I1"
eq "K3 the approve did not count" "$(clsf watch-cadence streak)" 5

# K4: an ask_first class -> the ordinary body; R1, the row holds class + recommendation.
reset
due_again; tick
eq "K4 the ask body" "$(line 1 | head -1)" "$REC"
check "K4 the ledger row: class, recommendation, mode ask, no choice yet" \
  '[ "$(lastd class)" = watch-cadence ] && [ "$(lastd recommendation)" = "$REC" ] && [ "$(lastd mode)" = ask ] && [ "$(lastd choice)" = null ]'
CMD=k4 icpt "Archie approve I1"
eq "K4 the operator's choice is on the row" "$(lastd choice)" approve

# K5: no CLASS line -> unclassified, ask.
reset watch-cadence=delegated:5
printf '%s\n' "$REC" > "$T/ac.text"
due_again; tick
eq "K5 unclassified" "$(lastd class)" unclassified
eq "K5 the ask body" "$(line 1 | head -1)" "$REC"

# K6 (R6): a tick never changes the authority list, whatever the streaks.
reset watch-continue=ask_first:99 watch-cadence=ask_first:99 watch-stop=ask_first:99 ticket-file=ask_first:99 hold-resume=ask_first:99
BEFORE=$(jq -c '.classes' "$T/db.json")
for _ in 1 2 3; do due_again; tick; done
eq "K6 three ticks, three beats" "$(beats)" 3
eq "K6 every class unchanged" "$(jq -c '.classes' "$T/db.json")" "$BEFORE"
check "K6 the tick never calls the delegation route" '! grep -q "/api/archie/classes" "$T/reqlog"'

# K7: a CLASS line and nothing else -> empty, no beat.
reset
printf 'CLASS: watch-cadence\n   \n' > "$T/ac.text"
due_again; tick
eq "K7 no beat" "$(beats)" 0
eq "K7 event empty" "$(jq -r '.events["check:1:2026-10-05T06:01:00Z"].status' "$T/db.json")" empty

# ═════ C: the intercept ══════════════════════════════════════════════════════
# C1 (AT1): five agreements -> the proposal on the fifth, not before.
reset
for i in 1 2 3 4 5; do
  round "c1-$i"
  R[$i]=$(out)
done
for i in 1 2 3 4; do
  check "C1 reply $i carries no proposal ($(tr '\n' ' ' <<<"${R[$i]}"))" '! grep -q "Archie delegate" <<<"${R[$i]}"'
  check "C1 reply $i is still the recording" 'grep -qF "Recorded: you approved I1." <<<"${R[$i]}"'
done
check "C1 reply 5 proposes ($(tr '\n' ' ' <<<"${R[5]}"))" \
  'grep -qF "You'"'"'ve agreed with my last 5 watch-cadence calls. Want me to handle those myself and tell you after? Say: Archie delegate watch-cadence, or Archie ask first watch-cadence." <<<"${R[5]}"'
eq "C1 streak 5" "$(clsf watch-cadence streak)" 5
eq "C1 still ask_first: a proposal is not a delegation" "$(clsf watch-cadence state)" ask_first

# C3 (AT2): yes -> delegated, then the next escalation is handled + reported.
icpt "Archie delegate watch-cadence"
check "C3 Done ($(out))" 'grep -qF "Done. I'"'"'ll handle watch-cadence calls and report after each one. One overrule puts it back." "$T/out"'
eq "C3 delegated" "$(clsf watch-cadence state)" delegated
due_again; tick
eq "C3 the next escalation is an after-report" "$(line '$' | head -1)" "Handled under your standing OK for watch-cadence: $REC"
eq "C3 auto in the ledger" "$(lastd mode)" auto

# C4 (AT3): one overrule -> back to ask-first, and the next tick asks.
CMD=c4 icpt "Archie change I1 too slow"
check "C4 says so ($(out))" 'grep -qF "Got it, watch-cadence calls go back to asking you first." "$T/out"'
eq "C4 ask_first" "$(clsf watch-cadence state)" ask_first
eq "C4 streak 0" "$(clsf watch-cadence streak)" 0
due_again; tick
eq "C4 the next tick asks" "$(line '$' | head -1)" "$REC"
check "C4 the next tick asks for approval" 'line "\$" | grep -qxF "$ASK_LINE"'

# C4b: the drop overrule reverts too.
reset watch-cadence=delegated:5
due_again; tick
CMD=c4b icpt "Archie drop I1"
check "C4b says so ($(out))" 'grep -qF "Got it, watch-cadence calls go back to asking you first." "$T/out"'
eq "C4b ask_first" "$(clsf watch-cadence state)" ask_first

# C1b: N is the settings row lane.archie.archie_delegate_after.
reset
printf '{"settings":[{"key":"lane.archie.archie_delegate_after","value":"3","actor":"operator"}]}' > "$T/settings.json"
for i in 1 2 3; do round "c1b-$i"; R[$i]=$(out); done
check "C1b reply 2 carries no proposal" '! grep -q "Archie delegate" <<<"${R[2]}"'
check "C1b reply 3 proposes at N=3 ($(tr '\n' ' ' <<<"${R[3]}"))" 'grep -qF "my last 3 watch-cadence calls" <<<"${R[3]}"'

# C2: consecutive means consecutive: a change in the middle resets.
reset
for i in 1 2 3; do round "c2-$i"; done
round c2-x "Archie change I1 weekly please"
check "C2 a change on an ask_first class says nothing about reverting" '! grep -q "go back to asking" "$T/out"'
for i in 4 5 6 7; do round "c2-$i"; R[$i]=$(out); done
check "C2 no proposal after 3 + change + 4" '! grep -q "Archie delegate" <<<"${R[4]}${R[5]}${R[6]}${R[7]}"'
eq "C2 streak 4" "$(clsf watch-cadence streak)" 4
# C8: four in a row and a delegate -> not yet.
icpt "Archie delegate watch-cadence"
check "C8 not yet ($(out))" 'grep -qF "Not yet. watch-cadence is at 4 of 5 agreements in a row." "$T/out"'
eq "C8 still ask_first" "$(clsf watch-cadence state)" ask_first

# C5 (AT4): a protected class at streak 9 is never proposed.
reset merge=ask_first:9
printf 'CLASS: merge\nMerge #4120, CI is green.\n' > "$T/ac.text"
for i in 1 2; do round "c5-$i"; R[$i]=$(out); done
check "C5 no proposal for merge ($(tr '\n' ' ' <<<"${R[1]}${R[2]}"))" '! grep -q "Archie delegate" <<<"${R[1]}${R[2]}"'
eq "C5 merge streak untouched" "$(clsf merge streak)" 9
# C6: and the operator cannot hand it over either.
icpt "Archie delegate merge"
check "C6 stays with you ($(out))" 'grep -qF "merge stays with you. Clients, money, direct merges, pushes to main, production DB writes and deploys outside the deploy lanes always do." "$T/out"'
eq "C6 merge still ask_first" "$(clsf merge state)" ask_first
icpt "Archie delegate Deploy"
check "C6 deploy too (case folded)" 'grep -qF "deploy stays with you." "$T/out"'

# C7: a replayed Telegram message counts once.
reset
due_again; tick
CMD=same icpt "Archie approve I1"
CMD=same icpt "Archie approve I1"
eq "C7 counted once" "$(clsf watch-cadence streak)" 1

# C9: the honest answers when nothing changed.
reset
icpt "Archie delegate no-such"
check "C9 unknown class ($(out))" 'grep -qF "I don'"'"'t have a no-such category. Nothing changed." "$T/out"'
icpt "Archie ask first watch-cadence"
check "C9 ask first ($(out))" '[ "$(cat "$T/rc")" = 0 ] && grep -qi "watch-cadence" "$T/out" && [ "$(clsf watch-cadence state)" = ask_first ]'
: > "$T/jobs.down"
icpt "Archie delegate watch-cadence"
check "C9 jobs DB down ($(out))" 'grep -qF "I couldn'"'"'t save that, the jobs DB didn'"'"'t answer. Nothing changed." "$T/out"'
check "C9 never claims Done when down" '! grep -q "^Done" "$T/out"'
rm -f "$T/jobs.down"; : > "$T/reqlog"
icpt "Archie delegate"
check "C9 bare delegate asks, writes nothing" '[ "$(cat "$T/rc")" = 0 ] && ! grep -q "/api/archie" "$T/reqlog"'
icpt "please delegate this"
check "C9 normal chat falls through" '[ "$(cat "$T/rc")" = 1 ] && [ ! -s "$T/out" ]'

# ═════ X: mutations of the shipped code (D1) ═════════════════════════════════
# X1: archie_sensitive always "no" -> K3's merge recommendation is auto-handled.
rm -f "$H/bin/lib/archie.sh"
sed 's/^archie_sensitive() {$/archie_sensitive() { return 1/' "$DIR/bin/lib/archie.sh" > "$H/bin/lib/archie.sh"
check "X1 the archie_sensitive line exists" '! cmp -s "$H/bin/lib/archie.sh" "$DIR/bin/lib/archie.sh"'
reset watch-cadence=delegated:5
printf 'CLASS: watch-cadence\nMerge #4120 now, it is green.\n' > "$T/ac.text"
due_again; tick
check "X1 mutant auto-handles a merge (so K3 is a real guard): $(line 1 | head -1)" '[ "$(lastd mode)" = auto ]'
rm -f "$H/bin/lib/archie.sh"; ln -s "$DIR/bin/lib/archie.sh" "$H/bin/lib/archie.sh"

# X2: no choice call in the intercept -> C1's fifth reply has no proposal.
sed '/^      # >>> archie choice/,/^      # <<< archie choice/d' "$DIR/bin/archie.sh" > "$H/bin/archie-x2.sh"
check "X2 the archie choice markers exist" '! cmp -s "$H/bin/archie-x2.sh" "$DIR/bin/archie.sh"'
reset
for i in 1 2 3 4 5; do ARCHIE_BIN=archie-x2.sh round "x2-$i"; done
check "X2 mutant never proposes (so C1 is a real guard)" '! grep -q "Archie delegate" "$T/out"'

# X3: the auto: argument not passed to archie_compose -> K1's body asks.
sed 's/ "\$TEXT_MAX" "\$auto")/ "$TEXT_MAX")/' "$DIR/bin/archie.sh" > "$H/bin/archie-x3.sh"
check "X3 the auto argument exists" '! cmp -s "$H/bin/archie-x3.sh" "$DIR/bin/archie.sh"'
reset watch-cadence=delegated:5
due_again; ARCHIE_BIN=archie-x3.sh tick
check "X3 mutant sends an ask body for an auto act (so K1 is a real guard)" '[ "$(line 1 | head -1)" = "$REC" ]'

# X4: the worker model answers auto whatever the state -> C4's next tick is red.
reset watch-cadence=ask_first:0; : > "$T/x.allauto"
due_again; tick
check "X4 a mode-always-auto worker is caught by C4's assertion" '[ "$(line "\$" | head -1)" != "$REC" ]'
rm -f "$H/bin/archie-x2.sh" "$H/bin/archie-x3.sh"

# ═════ the worker half, for real ═════════════════════════════════════════════
if ! command -v node >/dev/null 2>&1; then
  echo "archie-autonomy: node suite SKIPPED — node is not installed on this box"
elif [ ! -f "$DIR/catalog/lanes.json" ]; then
  echo "archie-autonomy: node suite SKIPPED — catalog/lanes.json is not composed (bin/lanes-build.sh --write)"
elif NOUT=$(cd "$DIR/worker/jobs" && node --test test/archie-autonomy.bh-4067.test.js 2>&1); then ok
else bad "node suite worker/jobs/test/archie-autonomy.bh-4067.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error|expected|actual' | head -30
fi

echo "archie-autonomy: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
