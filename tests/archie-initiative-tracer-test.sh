#!/bin/bash
# tests/archie-initiative-tracer-test.sh — BH-4062 (BH-3966.1): Archie's tracer,
# initiative -> check -> message, driven through the SHIPPED bin/archie.sh and
# the `# >>> archie intercept` block lifted verbatim from bin/orchestrate.sh.
#
# WHAT IS STUBBED. The lane runs from a scratch harness ($H: a symlink tree of
# the repo's bin/, a copy of catalog/lanes.d and the two prompt files) with
# these shims:
#   bin/agent-call.sh  counts calls, records argv, env and the prompt file, and
#                      answers $T/ac.text (or blank, or rc $T/ac.rc);
#   bin/beat.sh        appends its payload to $T/beats.jsonl, exits $T/beat.rc;
#   bin/alert-line.sh  appends its text to $T/alerts.log;
#   bin/orc-context.sh records the append it was asked for.
# ARCHIE_FIXTURE=$T/fx.sh replaces _jobs_req with a jq model of the
# /api/initiatives routes over $T/db.json (every request lands in $T/reqlog)
# and lane_role_model with a fixed `test-model` (rc 75 when $T/noroute
# exists). PATH carries a `curl` and a `gh` that log to $T/net.log and fail:
# nothing here may reach Telegram, GitHub or the real worker. The worker side
# of the same contract runs for real in the node suite at the end
# (worker/jobs/test/initiatives.bh-4062.test.js over schema.sql).
#
# Sections: P (command parse), M (csv metric), E (escalation), S (signature),
# T1-T14 (the tick), I1-I4 (the intercept), O (orchestrate.sh), X (mutations).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-initiative-tracer-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "archie-initiative-tracer: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

# The product paths this ticket ships (D41).
for f in "$DIR/bin/archie.sh" "$DIR/bin/lib/archie.sh" "$DIR/worker/jobs/src/routes/initiatives.js" \
         "$DIR/prompts/archie-soul.d/10-authority.md" "$DIR/catalog/prompts/archie-check.md" \
         "$DIR/catalog/lanes.d/archie.json" "$DIR/cron/lanes/724-archie.cron"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
if [ ! -f "$DIR/bin/archie.sh" ] || [ ! -f "$DIR/bin/lib/archie.sh" ]; then
  echo "archie-initiative-tracer: $PASS passed, $FAIL failed"; exit 1
fi

# ═════ P / M / E / S: the helpers, sourced from the repo ═════════════════════
# shellcheck source=../bin/lib/archie.sh
. "$DIR/bin/lib/archie.sh" || { echo "FAIL: cannot source bin/lib/archie.sh"; exit 1; }

pc() { archie_parse_cmd "$1"; }
eq "P1 track"            "$(pc 'Archie, track Rework under 10% | every: 7d')" $'track\tRework under 10% | every: 7d'
eq "P1 track, no comma"  "$(pc 'archie track ship it')" $'track\tship it'
eq "P1 track, colon"     "$(pc 'ARCHIE: track Ship It')" $'track\tShip It'
eq "P2 approve"          "$(pc 'Archie approve I7')" $'reply\tapprove\t7\t'
eq "P2 approve #"        "$(pc 'archie, approve #12')" $'reply\tapprove\t12\t'
eq "P2 change + note"    "$(pc 'Archie change I7 Make It weekly')" $'reply\tchange\t7\tMake It weekly'
eq "P2 bare drop I3"     "$(pc 'drop i3')" $'reply\tdrop\t3\t'
eq "P2 bare approve"     "$(pc '  approve I3  ')" $'reply\tapprove\t3\t'
check "P3 change with no text asks" '[ "$(pc "Archie change I7" | cut -f1)" = ask ]'
check "P3 Archie drop (no id) asks" '[ "$(pc "Archie drop" | cut -f1)" = ask ]'
# System invariants (c): none of these may be intercepted.
for neg in 'approve #3954' 'approve 7' 'please approve I3 later' 'can archie track this?' \
           'Archie, tracking is broken' 'Archie, what are you tracking?' 'archie trackX' \
           'drop the table' 'Archie, change the plan to weekly' 'approve I3x' 'Archie approve I0' \
           'status' 'archie' ''; do
  if pc "$neg" >/dev/null; then bad "P4 [$neg] must not be an Archie command ($(pc "$neg"))"; else ok; fi
done

tr_ok() { archie_parse_track "$1"; }
J=$(tr_ok 'Rework under 10% | metric: csv:logs/rework.csv#decomposed_rate@project=cromford | every: 7d | escalate: > 10 | links: https://github.com/example-org/cromford/issues/3954 https://x.test/a')
check "P5 track fields ($J)" 'jq -e ".goal == \"Rework under 10%\" and .metric_query == \"csv:logs/rework.csv#decomposed_rate@project=cromford\" and .cadence_hours == 168 and .escalation_rule == \"> 10\" and .links == [\"https://github.com/example-org/cromford/issues/3954\",\"https://x.test/a\"]" <<<"$J" >/dev/null'
J=$(tr_ok 'just a goal')
check "P5 defaults ($J)" 'jq -e ".metric_query == \"none\" and .cadence_hours == 24 and .escalation_rule == \"always\" and .links == []" <<<"$J" >/dev/null'
J=$(ARCHIE_DEFAULT_CADENCE_H=6 tr_ok 'goal')
check "P5 default cadence knob ($J)" 'jq -e ".cadence_hours == 6" <<<"$J" >/dev/null'
# Junk is refused with the field named, never clamped (D11).
while IFS='|' read -r want input; do
  input=${input//¦/|}
  got=$(tr_ok "$input"); rc=$?
  [ "$rc" = 1 ] && [ "$got" = "$want" ] && ok || bad "P6 [$input] want refusal '$want', got rc=$rc [$got]"
done <<'EOF'
goal|!!! ...
every|g ¦ every: 0h
every|g ¦ every: 99999h
every|g ¦ every: soon
every|g ¦ every: 91d
escalate|g ¦ metric: csv:logs/a.csv#x ¦ escalate: >= abc
escalate|g ¦ escalate: change
metric|g ¦ metric: csv:logs/../etc/passwd.csv#a
metric|g ¦ metric: csv:/etc/passwd#a
metric|g ¦ metric: rm -rf /
metric|g ¦ metric: $(id)
links|g ¦ links: javascript:alert(1)
colour|g ¦ colour: red
EOF
eq "P6 a | in the goal splits" "$(tr_ok 'a | b' ; echo "rc=$?")" $'field\nrc=1'
# (The heredoc writes ¦ for | so the outer read can split want|input.)

mkdir -p "$T/m/logs"
cat > "$T/m/logs/rework.csv" <<'EOF'
week,project,merged,reworked,rate,decomposed_merged,decomposed_reworked,decomposed_rate,sibling_reworked,source
2026-W38,cromford,10,2,20.0,4,1,25.0,0,"a,b"
2026-W38,project-3,3,0,0.0,0,0,-,0,x
2026-W39,cromford,12,1,8.3,5,0,0.0,0,x
2026-W40,cromford,9,1,11.1,0,0,-,0,x
EOF
mc() { HARNESS="$T/m" archie_metric_csv "$1"; }
eq "M1 last matching row" "$(mc 'csv:logs/rework.csv#rate@project=cromford')" 11.1
eq "M1 filter picks the project" "$(mc 'csv:logs/rework.csv#rate@project=project-3')" 0.0
eq "M1 no filter = last row" "$(mc 'csv:logs/rework.csv#merged')" 9
eq "M1 quoted comma in a later column" "$(mc 'csv:logs/rework.csv#reworked@rate=20.0')" 2
for spec in 'csv:logs/rework.csv#decomposed_rate@project=cromford' 'csv:logs/rework.csv#nope' \
            'csv:logs/missing.csv#rate' 'csv:logs/rework.csv#rate@project=nobody' \
            'csv:logs/../rework.csv#rate' 'none'; do
  v=$(mc "$spec"); rc=$?
  [ "$rc" = 1 ] && [ -z "$v" ] && ok || bad "M2 [$spec] must be unreadable (rc 1, no value), got rc=$rc [$v]"
done
v=$(env -u HARNESS bash -c ". '$DIR/bin/lib/archie.sh'; unset H; archie_metric_csv 'csv:logs/rework.csv#rate'"); rc=$?
[ "$rc" = 1 ] && [ -z "$v" ] && ok || bad "M3 no root must be unreadable, got rc=$rc [$v]"

esc() { archie_escalates "$@" && echo yes || echo no; }
eq "E1 always"                "$(esc always '' '')" yes
eq "E2 change, first reading" "$(esc change 9.0 '')" yes
eq "E2 change, same value"    "$(esc change 9.0 9.0)" no
eq "E2 change, 9 vs 9.0"      "$(esc change 9 9.0)" no
eq "E2 change, moved"         "$(esc change 8.3 9.0)" yes
eq "E2 change, no value"      "$(esc change '' 9.0)" no
eq "E3 > 10 with 9.9"         "$(esc '> 10' 9.9 '')" no
eq "E3 > 10 with 10"          "$(esc '> 10' 10 '')" no
eq "E3 > 10 with 10.5"        "$(esc '> 10' 10.5 '')" yes
eq "E3 >= 10 with 10"         "$(esc '>= 10' 10 '')" yes
eq "E3 < 5 with 4.9"          "$(esc '< 5' 4.9 '')" yes
eq "E3 < 5 with 5"            "$(esc '< 5' 5 '')" no
eq "E3 <= -1 with -1"         "$(esc '<= -1' -1 '')" yes
eq "E3 op with no value"      "$(esc '> 1' '' '')" no
eq "E3 junk rule"             "$(esc 'sometimes' 5 '')" no

eq "S1 signs"                 "$(archie_sign 'hello there')" $'hello there\n\nArchie'
eq "S1 signs once"            "$(archie_sign "$(archie_sign 'hello there')")" $'hello there\n\nArchie'
eq "S1 trailing blank lines"  "$(archie_sign $'hi\n\nArchie\n\n')" $'hi\n\nArchie'
eq "S1 Archie mid-text"       "$(archie_sign $'Archie says hi\nok')" $'Archie says hi\nok\n\nArchie'

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/catalog/prompts" "$H/prompts" "$H/env" "$H/logs" "$T/fakebin"
cp -rs "$DIR/bin" "$H/bin"
cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
[ -d "$DIR/catalog/switches.d" ] && cp -r "$DIR/catalog/switches.d" "$H/catalog/"
cp -r "$DIR/prompts/archie-soul.d" "$H/prompts/" 2>/dev/null
cp "$DIR/catalog/prompts/archie-check.md" "$H/catalog/prompts/" 2>/dev/null
: > "$H/env/global.env"
rm -f "$H/bin/agent-call.sh" "$H/bin/beat.sh" "$H/bin/archie-tg-send.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh" "$H/bin/orc-context.sh"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s|%s|%s\n' "$*" "${AGENT_CALL_LANE:-}" "${AGENT_CALL_FP:-}" >> "$FXT/agentcalls"
case "${6:-}" in @*) cp "${6#@}" "$FXT/prompt.last" ;; esac
[ -f "$FXT/ac.drop" ] && jq '.initiatives |= map(.status = "dropped")' "$FXT/db.json" > "$FXT/db.tmp" && mv "$FXT/db.tmp" "$FXT/db.json"
rc=$(cat "$FXT/ac.rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] || exit "$rc"
if [ -f "$FXT/ac.blank" ]; then printf '  \n' > "$5"; else cat "$FXT/ac.text" > "$5"; fi
exit 0
SH
cat > "$H/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$FXT/beats.jsonl"
exit "$(cat "$FXT/beat.rc" 2>/dev/null || echo 0)"
SH
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts.log"
exit 0
SH
cp "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
cat > "$H/bin/orc-context.sh" <<'SH'
#!/bin/bash
printf '%s %s / %s\n' "$2" "$(cat "$3")" "$(cat "$4")" >> "$FXT/orc-context.log"
SH
# BH-4779: Archie's Telegram transport, captured where the beats were.
cat > "$H/bin/archie-tg-send.sh" <<'SH'
#!/bin/bash
jq -nc --arg a "$1" --arg l "$2" '{akey: $a, line: $l}' >> "$FXT/beats.jsonl"
exit "$(cat "$FXT/beat.rc" 2>/dev/null || echo 0)"
SH
chmod +x "$H/bin/agent-call.sh" "$H/bin/beat.sh" "$H/bin/archie-tg-send.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh" "$H/bin/orc-context.sh"
for c in curl gh; do
  printf '#!/bin/bash\nprintf "%%s %%s\\n" %s "$*" >> "$FXT/net.log"\nexit 7\n' "$c" > "$T/fakebin/$c"
  chmod +x "$T/fakebin/$c"
done

# The worker, modelled in jq over $T/db.json: the same answers and status
# codes as worker/jobs/src/routes/initiatives.js, including the stale-advance
# 409 and the reply 404. _jobs_req's rc contract (bin/lib/jobs/req.sh): 0 on a
# 2xx, 9 on 409, 2 on 404, 1 on anything else.
cat > "$T/fx.sh" <<'SH'
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" q out code=200 key id
  JOBS_HTTP=""; JOBS_BODY=""
  case "$p" in /api/settings*|/api/flags*|/api/lanes*)
    printf '%s %s\n' "$m" "$p" >> "$FXT/gatelog"
    [ "$p" = /api/settings ] && { printf '{"settings":[]}'; JOBS_HTTP=200; return 0; }
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
      elif [ -f "$FXT/due.override" ]; then out=$(cat "$FXT/due.override")
      else
        out=$(jq -c --arg s "$(qp status)" --arg d "$(qp due_before)" --argjson l "$(qp limit)" '
          [.initiatives[] | select(($s == "" or .status == $s) and ($d == "" or .next_check_at <= $d))]
          | sort_by(.next_check_at, .id) | {initiatives: .[0:$l], truncated: (length > $l)}' "$db")
      fi ;;
    "GET /api/initiatives/events")
      key=$(qp key)
      out=$(jq -c --arg k "$key" '.events[$k] // empty | {event: .}' "$db")
      [ -n "$out" ] || { JOBS_HTTP=404; return 2; } ;;
    "POST /api/initiatives/check")
      [ -f "$FXT/check.down" ] && { JOBS_HTTP=503; return 1; }
      # The worker's optText(b.body, 4000), and a forced refusal of the composed
      # body (BH-4609: the pre-call attempt write carries body `attempt` now).
      if jq -e '(.body // "") | length > 4000' <<<"$b" >/dev/null || { [ -f "$FXT/check.body400" ] && jq -e '.body != null and .status == "composed"' <<<"$b" >/dev/null; }; then
        JOBS_HTTP=400; JOBS_BODY='{"error":"body"}'; return 1
      fi
      id=$(jq -r .id <<<"$b")
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
            | (if $b.advance_to != null then .next_check_at = $b.advance_to
                 | (if $b.value != null then .last_value = $b.value else . end) else . end)
          else . end)' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
      out=$(jq -c --argjson b "$b" '{ok: true, advanced: ($b.advance_to != null)}' <<<'{}') ;;
    "POST /api/initiatives")
      out=$(jq -c --argjson b "$b" '{ok: true, created: true, initiative: ($b + {id: 41, slug: "s", status: "active"})}' <<<'{}')
      code=201 ;;
    "POST /api/initiatives/reply")
      id=$(jq -r .id <<<"$b")
      jq -e --argjson i "$id" '.initiatives[] | select(.id == $i)' "$db" >/dev/null || { JOBS_HTTP=404; return 2; }
      jq --argjson b "$b" '.initiatives |= map(if .id == $b.id then .last_decision = $b.decision
          | .last_decision_note = $b.note | (if $b.decision == "drop" then .status = "dropped" else . end) else . end)' \
        "$db" > "$db.tmp" && mv "$db.tmp" "$db"
      out=$(jq -c --argjson i "$id" '{ok: true, created: true, initiative: (.initiatives[] | select(.id == $i))}' "$db")
      code=201 ;;
    *) JOBS_HTTP=404; return 2 ;;
  esac
  JOBS_HTTP=$code; JOBS_BODY="$out"; printf '%s' "$out"; return 0
}
lane_role_model() { [ -f "$FXT/noroute" ] && return 75; [ "$1" = stage.archie ] || return 75; echo test-model; }
# TEST-CHANGE (BH-9127): a tick that gets its lock now posts one Archie
# heartbeat (bin/lib/archie-hb.sh) through _jobs_req_file. It is not an
# initiatives request: it goes to its own log, never to reqlog or the network.
_jobs_req_file() { printf '%s %s\n' "$1" "$2" >> "$FXT/hblog"; JOBS_HTTP=201; return 0; }
SH

export HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.invalid HARNESS_SECRET=test
unset ARCHIE_ENABLED ARCHIE_MAX_PER_TICK ARCHIE_DEFAULT_CADENCE_H ARCHIE_MAX_ATTEMPTS ARCHIE_TEXT_MAX_CHARS \
  ARCHIE_LLM_MAX_USD ARCHIE_NOW ARCHIE_FIXTURE ARCHIE_CMD_ID ARCHIE_TIMED BEAT_STRICT 2>/dev/null || true

NOW=1791184500                       # 2026-10-05T07:15:00Z
NOWISO=2026-10-05T07:15:00Z
DUE=2026-10-05T07:00:00Z             # due 15 minutes ago
FUTURE=2026-10-05T08:00:00Z
iso_plus_h() { date -u -d "@$((NOW + $1 * 3600))" +%Y-%m-%dT%H:%M:%SZ; }
L1=https://github.com/example-org/cromford/issues/3954
L2=https://github.com/example-org/cromford/issues/3955
L3=https://github.com/example-org/cromford/issues/3956
REC='Keep slicing tracer-first — rework fell, so push it to every board.'
REC_FOLDED='Keep slicing tracer-first, rework fell, so push it to every board.'

cat > "$H/logs/rework.csv" <<'EOF'
week,project,merged,reworked,rate,decomposed_merged,decomposed_reworked,decomposed_rate,sibling_reworked,source
2026-W39,cromford,12,1,8.3,5,1,20.0,0,x
2026-W40,cromford,9,1,11.1,4,0,9.0,0,x
2026-W40,project-3,9,1,11.1,0,0,-,0,x
EOF
METRIC='csv:logs/rework.csv#decomposed_rate@project=cromford'

# row <id> <next_check_at> <rule> [metric] [last_value|null] [status]
row() {
  jq -nc --argjson i "$1" --arg n "$2" --arg r "$3" --arg m "${4:-$METRIC}" --argjson lv "${5:-null}" \
    --arg s "${6:-active}" --arg l1 "$L1" --arg l2 "$L2" --arg l3 "$L3" \
    '{id: $i, slug: "init-\($i)", goal: "Tracer-first slicing cuts rework (#3954, #3955, #3956)",
      metric_query: $m, cadence_hours: 168, escalation_rule: $r, status: $s, next_check_at: $n,
      links: [$l1, $l2, $l3], last_value: $lv, last_check_status: null}'
}
# reset <row-json>...: a fresh world holding exactly these rows.
reset() {
  local p
  for p in reqlog gatelog beats.jsonl agentcalls alerts.log prompt.last ac.rc ac.blank ac.drop beat.rc \
           due.override noroute jobs.down check.down check.body400 net.log orc-context.log out rc; do
    scratch_rm "$T/$p" || exit 1
  done
  scratch_rm "$H/state" || exit 1; scratch_rm "$H/locks" || exit 1; scratch_rm "$H/logs/archie.log" || exit 1
  printf '%s\n' "$REC" > "$T/ac.text"
  jq -nc '{initiatives: $ARGS.positional, events: {}}' --jsonargs "$@" > "$T/db.json"
  : > "$T/reqlog"
}
tick() {
  env HARNESS_TEST_SANDBOX=1 ARCHIE_NOW="$NOW" ARCHIE_FIXTURE="$T/fx.sh" LANE_GATE_DISABLE=1 "$@" \
    bash "$H/bin/archie.sh" tick > "$T/out" 2>&1
  echo $? > "$T/rc"
}
n()     { local c; c=$(wc -l 2>/dev/null < "$1"); printf '%s' "${c:-0}" | tr -d ' '; }
calls() { n "$T/agentcalls"; }
beats() { n "$T/beats.jsonl"; }
ev()    { jq -r --arg k "check:$1:$2" '.events[$k].status // "none"' "$T/db.json"; }
evf()   { jq -r --arg k "check:$1:$2" --arg f "$3" '.events[$k][$f] // "none"' "$T/db.json"; }
fld()   { jq -r --argjson i "$1" --arg f "$2" '.initiatives[] | select(.id == $i) | .[$f] // "null"' "$T/db.json"; }
beat()  { sed -n "${1:-1}p" "$T/beats.jsonl"; }
posts() { grep -c '^POST /api/initiatives/check ' "$T/reqlog"; }

# ── T1: a due row with rule `always` -> check, one model call, one beat ──────
reset "$(row 7 "$DUE" always)"
tick
check "T1 rc 0 ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
eq "T1 one model call" "$(calls)" 1
check "T1 agent-call argv: archie fleet test-model 300 ($(cat "$T/agentcalls"))" \
  'grep -qE "^archie fleet test-model 300 [^ ]+ @[^ ]+\|archie\|archie:7:$DUE$" "$T/agentcalls"'
check "T1 the prompt carries the soul" 'grep -qF "Owner, not assistant." "$T/prompt.last"'
check "T1 the prompt carries the check prompt" 'grep -qF "$(sed -n "/[A-Za-z]/{p;q}" "$DIR/catalog/prompts/archie-check.md")" "$T/prompt.last"'
check "T1 the prompt carries the measured value" 'grep -qF "\"value\":\"9.0\"" "$T/prompt.last"'
eq "T1 exactly one beat" "$(beats)" 1
check "T1 beat shape: $(beat)" \
  'beat | jq -e --arg a "archie:7:$DUE" ".akey == \$a and (has(\"kind\") | not)" >/dev/null'
LINE=$(beat | jq -r .line)
eq "T1 line 1 is the recommendation (dashes folded)" "$(head -1 <<<"$LINE")" "$REC_FOLDED"
check "T1 the three issue links" 'grep -qxF "$L1" <<<"$LINE" && grep -qxF "$L2" <<<"$LINE" && grep -qxF "$L3" <<<"$LINE"'
check "T1 the metric line" 'grep -qxF "Metric: 9.0 (always)" <<<"$LINE"'
# Not through check(): its eval puts "<what> / Archie" in the traced text, and
# the trace-safety lane reads that `> /` as a redirect to / (CI shard 7).
grep -qxF "Reply: Archie approve I7 / Archie change I7 <what> / Archie drop I7" <<<"$LINE" && ok || bad "T1 how to reply"
eq "T1 signed Archie" "$(tail -1 <<<"$LINE")" Archie
check "T1 no em dash in the beat" '! grep -q "—" <<<"$LINE"'
eq "T1 event sent" "$(ev 7 "$DUE")" sent
eq "T1 advanced to now + cadence" "$(fld 7 next_check_at)" "$(iso_plus_h 168)"
eq "T1 last_value stored" "$(fld 7 last_value)" 9.0
check "T1 the attempt BEFORE the call, composed BEFORE the send ($(grep "^POST /api/initiatives/check " "$T/reqlog"))" \
  '[ "$(grep "^POST /api/initiatives/check " "$T/reqlog" | sed "s/^POST [^ ]* //" | jq -r .status | tr "\n" " ")" = "model_failed composed sent " ]'
check "T1 summary line: $(tail -1 "$H/logs/archie.log" 2>/dev/null)" \
  'tail -1 "$H/logs/archie.log" | grep -qE "^[^ ]+ due=1 checked=1 beats=1 model_calls=1 skipped=0$"'
check "T1 no network ($(cat "$T/net.log" 2>/dev/null))" '[ ! -s "$T/net.log" ]'
# A second tick finds nothing due: zero calls, zero beats.
tick
eq "T1 the next tick makes no second call" "$(calls)" 1
eq "T1 the next tick sends no second beat" "$(beats)" 1

# ── T2: a not-due row handed back anyway -> no metric read, no call, no beat ─
reset "$(row 8 "$FUTURE" always)"
row 8 "$FUTURE" always | jq -c '{initiatives: [.], truncated: false}' > "$T/due.override"
tick
eq "T2 no model call" "$(calls)" 0
eq "T2 no beat" "$(beats)" 0
eq "T2 no check event" "$(posts)" 0
eq "T2 not advanced" "$(fld 8 next_check_at)" "$FUTURE"
# A dropped row handed back is skipped the same way.
reset "$(row 9 "$DUE" always '' null dropped)"
row 9 "$DUE" always '' null dropped | jq -c '{initiatives: [.], truncated: false}' > "$T/due.override"
tick
check "T2 a dropped row: no call, no beat, no event" '[ "$(calls)" = 0 ] && [ "$(beats)" = 0 ] && [ "$(posts)" = 0 ]'

# ── T3: nothing due -> one read, zero model calls ────────────────────────────
# BH-4063: a tick now also polls its event sources first (the merge ledger and
# the follow-up rows, bin/lib/archie-wake.sh), so the exact one-request pin is
# held with those collectors off (flags/archie-wake-off), and with them on the
# no-op tick is pinned to reads only: no write, no call, no beat.
reset "$(row 10 "$FUTURE" always)"
mkdir -p "$H/flags"; : > "$H/flags/archie-wake-off"
tick
rm -f "$H/flags/archie-wake-off"
eq "T3 no model call" "$(calls)" 0
eq "T3 no beat" "$(beats)" 0
eq "T3 exactly one request, the due read" "$(n "$T/reqlog")" 1
check "T3 the due query ($(cat "$T/reqlog"))" 'grep -qxF "GET /api/initiatives?status=active&due_before=$NOWISO&limit=3 " "$T/reqlog"'
# BH-8417: a no-op tick writes exactly one local `tick due=0` line, so
# bin/log-freshness.sh can tell a quiet lane from a dead one. Still no write
# to the worker, no call and no beat (above).
check "T3 one tick line, nothing else" '[ "$(grep -c . "$H/logs/archie.log")" = 1 ] && grep -q " tick due=0: no active initiative is due" "$H/logs/archie.log"'
reset "$(row 10 "$FUTURE" always)"
tick
eq "T3 wakes on: no model call" "$(calls)" 0
eq "T3 wakes on: no beat" "$(beats)" 0
eq "T3 wakes on: no write ($(cat "$T/reqlog"))" "$(grep -cvE '^GET ' "$T/reqlog")" 0
eq "T3 wakes on: the due read plus the merge and follow-up polls" \
  "$(sed 's/ $//' "$T/reqlog" | tr '\n' '|')" \
  "GET /api/ledger?kind=merge&limit=200|GET /api/ledger?kind=archie_followup&limit=100|GET /api/initiatives?status=active&due_before=$NOWISO&limit=3|"
# The worker unreachable: no call, rc 0, one log line.
reset "$(row 11 "$DUE" always)"; : > "$T/jobs.down"
tick
check "T3 worker down: rc 0, no call, no beat" '[ "$(cat "$T/rc")" = 0 ] && [ "$(calls)" = 0 ] && [ "$(beats)" = 0 ]'
check "T3 worker down is logged" 'grep -q "could not read" "$H/logs/archie.log"'
# Off switch.
reset "$(row 12 "$DUE" always)"
tick ARCHIE_ENABLED=0
check "T3 ARCHIE_ENABLED=0: no request at all" '[ "$(n "$T/reqlog")" = 0 ] && [ "$(calls)" = 0 ]'

# ── T6: escalation says no -> silent, advanced, no call ──────────────────────
reset "$(row 13 "$DUE" change "$METRIC" '"9.0"')"
tick
eq "T6 change, same value: no call" "$(calls)" 0
eq "T6 no beat" "$(beats)" 0
eq "T6 event silent" "$(ev 13 "$DUE")" silent
eq "T6 advanced" "$(fld 13 next_check_at)" "$(iso_plus_h 168)"
reset "$(row 14 "$DUE" change "$METRIC" '"20.0"')"
tick
check "T6 change, moved value: one call, one beat" '[ "$(calls)" = 1 ] && [ "$(beats)" = 1 ]'
reset "$(row 15 "$DUE" '> 10')"
tick
check "T6 > 10 with 9.0: silent, no call" '[ "$(ev 15 "$DUE")" = silent ] && [ "$(calls)" = 0 ]'
reset "$(row 16 "$DUE" '< 10')"
tick
check "T6 < 10 with 9.0: one beat" '[ "$(beats)" = 1 ] && [ "$(ev 16 "$DUE")" = sent ]'
# Unreadable metric (`-`): never zero, never a call. BH-4609: it re-checks in
# ARCHIE_UNREADABLE_RECHECK_H (24h), not a full cadence. BH-4765: this pins the
# already-told path (marker present); the first telling is
# tests/archie-unreadable-told.bh-4765-test.sh.
reset "$(row 17 "$DUE" always 'csv:logs/rework.csv#decomposed_rate@project=project-3')"
mkdir -p "$H/state/archie/unreadable-told" && : > "$H/state/archie/unreadable-told/17"
tick
check "T6 unreadable: event, advanced, no call, no beat" \
  '[ "$(ev 17 "$DUE")" = unreadable ] && [ "$(fld 17 next_check_at)" = "$(iso_plus_h 24)" ] && [ "$(calls)" = 0 ] && [ "$(beats)" = 0 ]'
check "T6 unreadable stores no value" '[ "$(fld 17 last_value)" = null ]'
# metric none + always: a call with no value.
reset "$(row 18 "$DUE" always none)"
tick
check "T6 metric none: beat says not measured" '[ "$(beats)" = 1 ] && beat | jq -r .line | grep -qxF "Metric: not measured (always)"'

# ── T7: model outcomes ───────────────────────────────────────────────────────
reset "$(row 20 "$DUE" always)"; echo 77 > "$T/ac.rc"
tick
check "T7 rc 77 (nothing billed): the attempt handed back, not advanced, no beat" \
  '[ "$(evf 20 "$DUE" attempts)" = 0 ] && [ "$(fld 20 next_check_at)" = "$DUE" ] && [ "$(beats)" = 0 ]'
echo 1 > "$T/ac.rc"
tick
check "T7 rc 1: model_failed, attempts 1, not advanced" \
  '[ "$(ev 20 "$DUE")" = model_failed ] && [ "$(evf 20 "$DUE" attempts)" = 1 ] && [ "$(fld 20 next_check_at)" = "$DUE" ]'
check "T7 no alert on the first failure" '[ ! -s "$T/alerts.log" ]'
tick
check "T7 rc 1 again: attempt cap reached, advanced" \
  '[ "$(evf 20 "$DUE" attempts)" = 2 ] && [ "$(fld 20 next_check_at)" = "$(iso_plus_h 168)" ]'
eq "T7 exactly one ALERTS line" "$(n "$T/alerts.log")" 1
check "T7 the alert names the initiative ($(cat "$T/alerts.log"))" 'grep -qF "archie: initiative 20 check $DUE failed 2 times" "$T/alerts.log"'
eq "T7 never a beat on failure" "$(beats)" 0
reset "$(row 21 "$DUE" always)"; : > "$T/ac.blank"
tick
check "T7 blank answer: empty, advanced, no beat" \
  '[ "$(ev 21 "$DUE")" = empty ] && [ "$(fld 21 next_check_at)" = "$(iso_plus_h 168)" ] && [ "$(beats)" = 0 ]'
# No stage.archie route: nothing guessed, nothing called, row stays due.
reset "$(row 22 "$DUE" always)"; : > "$T/noroute"
tick
check "T7 no route: no call, no event, still due" \
  '[ "$(calls)" = 0 ] && [ "$(ev 22 "$DUE")" = none ] && [ "$(fld 22 next_check_at)" = "$DUE" ]'

# ── T8: the beat does not land -> composed kept, resent without a 2nd call ───
reset "$(row 23 "$DUE" always)"; echo 1 > "$T/beat.rc"
tick
check "T8 beat failed: event composed, not advanced" '[ "$(ev 23 "$DUE")" = composed ] && [ "$(fld 23 next_check_at)" = "$DUE" ]'
B1=$(beat 1)
rm -f "$T/beat.rc"
tick
eq "T8 no second model call" "$(calls)" 1
eq "T8 a second beat" "$(beats)" 2
eq "T8 the same payload (akey and body)" "$(beat 2)" "$B1"
eq "T8 now sent" "$(ev 23 "$DUE")" sent
eq "T8 advanced" "$(fld 23 next_check_at)" "$(iso_plus_h 168)"
# Dropped while the model was thinking: composed, never sent.
reset "$(row 24 "$DUE" always)"; : > "$T/ac.drop"
tick
check "T8 dropped mid-check: no beat" '[ "$(beats)" = 0 ] && [ "$(ev 24 "$DUE")" = composed ]'

# ── T9: more due than the cap -> the rest wait (deferred, never dropped) ─────
reset "$(row 30 2026-10-05T06:00:00Z always)" "$(row 31 2026-10-05T06:10:00Z always)" \
      "$(row 32 2026-10-05T06:20:00Z always)" "$(row 33 2026-10-05T06:30:00Z always)"
tick ARCHIE_MAX_PER_TICK=3
eq "T9 three checked" "$(beats)" 3
eq "T9 the fourth is still due" "$(fld 33 next_check_at)" 2026-10-05T06:30:00Z
check "T9 the cap is logged as deferred" 'grep -q "deferred" "$H/logs/archie.log"'
tick ARCHIE_MAX_PER_TICK=3
eq "T9 next tick takes the fourth" "$(fld 33 next_check_at)" "$(iso_plus_h 168)"

# ── T10: an out-of-range knob is the default plus a warn line, never a clamp ─
reset "$(row 34 "$DUE" always)"
tick ARCHIE_MAX_PER_TICK=0
check "T10 MAX_PER_TICK=0 warns and uses 3" 'grep -qF "limit=3 " "$T/reqlog" && grep -q "ARCHIE_MAX_PER_TICK=0" "$H/logs/archie.log"'

# ── T11: the longest legal initiative -> the body still fits, one call ──────
GOAL300=$(printf 'g%.0s' $(seq 300)); LONG="https://x.test/$(printf 'a%.0s' $(seq 292))"
reset "$(row 40 "$DUE" always | jq -c --arg g "$GOAL300" --arg l "$LONG" '.goal = $g | .links = [range(10) | $l]')"
printf 'r%.0s' $(seq 2500) > "$T/ac.text"
tick ARCHIE_TEXT_MAX_CHARS=2000
eq "T11 one model call" "$(calls)" 1
eq "T11 sent" "$(ev 40 "$DUE")" sent
check "T11 the body is within the worker cap" '[ "$(beat | jq -r ".line | length")" -le 4000 ]'
check "T11 the links left out are counted" 'beat | jq -r .line | grep -qE "^[0-9]+ more links? on I40, not shown here$"'
tick ARCHIE_TEXT_MAX_CHARS=2000
eq "T11 no second call" "$(calls)" 1

# ── T12: the paid answer is refused by the ledger -> closed, never re-bought ─
reset "$(row 41 "$DUE" always)"; : > "$T/check.body400"
tick
eq "T12 one model call" "$(calls)" 1
eq "T12 no beat" "$(beats)" 0
check "T12 closed as model_failed, attempt counted, advanced" \
  '[ "$(ev 41 "$DUE")" = model_failed ] && [ "$(evf 41 "$DUE" attempts)" = 1 ] && [ "$(fld 41 next_check_at)" = "$(iso_plus_h 168)" ]'
check "T12 one ALERTS line ($(cat "$T/alerts.log" 2>/dev/null))" '[ "$(n "$T/alerts.log")" = 1 ] && grep -qF "archie: initiative 41 check $DUE answered but its body could not be recorded" "$T/alerts.log"'
tick
eq "T12 the next tick makes no second call" "$(calls)" 1

# ── T13: the attempt cannot be written -> no call ───────────────────────────
reset "$(row 42 "$DUE" always)"; : > "$T/check.down"
tick; tick
check "T13 no call, no beat, still due" '[ "$(calls)" = 0 ] && [ "$(beats)" = 0 ] && [ "$(fld 42 next_check_at)" = "$DUE" ]'

# ── T14: a slot already at the cap (its close was lost) -> closed, no call ──
reset "$(row 43 "$DUE" always)"
jq --arg k "check:43:$DUE" '.events[$k] = {status: "model_failed", value: null, body: null, attempts: 2}' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
tick
check "T14 no call, advanced, one ALERTS line ($(cat "$T/out" "$H/logs/archie.log" "$T/reqlog" 2>/dev/null | tail -8))" \
  '[ "$(calls)" = 0 ] && [ "$(fld 43 next_check_at)" = "$(iso_plus_h 168)" ] && [ "$(n "$T/alerts.log")" = 1 ]'

# ═════ I: the intercept ══════════════════════════════════════════════════════
icpt() {
  env HARNESS_TEST_SANDBOX=1 ARCHIE_NOW="$NOW" ARCHIE_FIXTURE="$T/fx.sh" ARCHIE_CMD_ID="${CMD:-}" \
    bash "$H/bin/archie.sh" intercept "$1" > "$T/out" 2>"$T/err"
  echo $? > "$T/rc"
}
reqs() { n "$T/reqlog"; }
reset "$(row 7 "$DUE" always)"
icpt "Archie, track Rework under 10% | metric: $METRIC | every: 7d | escalate: > 10 | links: $L1 https://x.test/a"
eq "I1 rc 0" "$(cat "$T/rc")" 0
eq "I1 one request" "$(reqs)" 1
TB=$(sed -n 's/^POST \/api\/initiatives //p' "$T/reqlog")
check "I1 POST body fields ($TB)" \
  'jq -e --arg m "$METRIC" --arg n "$(iso_plus_h 168)" --arg l "$L1" ".goal == \"Rework under 10%\" and .metric_query == \$m and .cadence_hours == 168 and .escalation_rule == \"> 10\" and .next_check_at == \$n and .links == [\$l, \"https://x.test/a\"] and (.created_by | length > 0)" <<<"$TB" >/dev/null'
check "I1 the reply names the new initiative ($(cat "$T/out"))" 'grep -q "I41" "$T/out"'
reset "$(row 7 "$DUE" always)"
for bad_in in "metric: csv:logs/../etc/x.csv#a|metric" "every: 0h|every" "every: 99999h|every" "escalate: >= abc|escalate"; do
  icpt "Archie, track g | ${bad_in%|*}"
  [ "$(cat "$T/rc")" = 0 ] && grep -qiF "${bad_in#*|}" "$T/out" && [ "$(reqs)" = 0 ] && ok \
    || bad "I2 [${bad_in%|*}]: want rc 0, a reply naming ${bad_in#*|}, zero requests; got rc=$(cat "$T/rc") reqs=$(reqs) [$(cat "$T/out")]"
done

reset "$(row 7 "$DUE" always)"
CMD=cmd-55 icpt "Archie approve I7"
RB=$(sed -n 's/^POST \/api\/initiatives\/reply //p' "$T/reqlog")
check "I3 approve POST ($RB)" 'jq -e ".id == 7 and .decision == \"approve\" and .dedupe_key == \"reply:7:cmd-55\" and (.note == null or .note == \"\")" <<<"$RB" >/dev/null'
check "I3 approve reply ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ] && grep -q "I7" "$T/out"'
eq "I3 approve recorded" "$(fld 7 last_decision)" approve
: > "$T/reqlog"
icpt "change I7 make it weekly"
RB=$(sed -n 's/^POST \/api\/initiatives\/reply //p' "$T/reqlog")
check "I3 change POST with note ($RB)" 'jq -e ".id == 7 and .decision == \"change\" and .note == \"make it weekly\" and (.dedupe_key | test(\"^reply:7:[0-9a-f]{16}$\"))" <<<"$RB" >/dev/null'
eq "I3 change note recorded" "$(fld 7 last_decision_note)" "make it weekly"
: > "$T/reqlog"
icpt "Archie, drop I7"
check "I3 drop" '[ "$(fld 7 status)" = dropped ] && [ "$(fld 7 last_decision)" = drop ] && grep -q "I7" "$T/out"'
# A dropped initiative leaves the due list: the next tick does nothing.
tick
check "I3 dropped: the tick calls nothing" '[ "$(calls)" = 0 ] && [ "$(beats)" = 0 ]'
: > "$T/reqlog"
icpt "Archie approve I99"
check "I3 unknown id: rc 0, said plainly ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ] && grep -q "I99" "$T/out" && grep -qi "nothing was recorded" "$T/out"'
: > "$T/jobs.down"
icpt "Archie approve I7"
check "I3 D1 down: rc 0, no claimed save ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ] && grep -qi "nothing was recorded" "$T/out" && ! grep -qi "^recorded" "$T/out"'
rm -f "$T/jobs.down"

reset "$(row 7 "$DUE" always)"
for neg in 'approve #3954' 'please approve I3 later' 'Archie, tracking is broken' 'Archie, what are you tracking?' 'drop the table' 'status'; do
  icpt "$neg"
  [ "$(cat "$T/rc")" = 1 ] && [ ! -s "$T/out" ] && [ "$(reqs)" = 0 ] && ok || bad "I4 [$neg] must fall through (rc 1, no output, no request); rc=$(cat "$T/rc") reqs=$(reqs)"
done
icpt "Archie drop"
check "I4 Archie drop asks, writes nothing" '[ "$(cat "$T/rc")" = 0 ] && [ "$(reqs)" = 0 ] && grep -qi "which initiative" "$T/out"'

# ═════ O: bin/orchestrate.sh ═════════════════════════════════════════════════
SRC="$DIR/bin/orchestrate.sh"
BLOCK=$(sed -n '/^# >>> archie intercept/,/^# <<< archie intercept/p' "$SRC")
check "O0 the archie intercept block exists" 'grep -q "archie.sh\" intercept" <<<"$BLOCK"'
# run_block <text>: the block lifted verbatim, with deliver_reply recorded and a
# fall-through marker after it, standing in for the claude turn.
run_block() {
  scratch_rm "$T/orc" || exit 1; mkdir -p "$T/orc"
  scratch_rm "$T/delivered" || exit 1; scratch_rm "$T/fell" || exit 1
  printf '%s' "$BLOCK" > "$T/block.sh"
  env HARNESS_TEST_SANDBOX=1 ARCHIE_NOW="$NOW" ARCHIE_FIXTURE="$T/fx.sh" HARNESS="$H" ORC="$T/orc" TEXT="$1" CMD_ID=c9 \
    bash -c 'set -uo pipefail
      deliver_reply() { printf "%s" "$1" > "$FXT/delivered"; }
      . "$FXT/block.sh"
      : > "$FXT/fell"' > /dev/null 2>&1
}
reset "$(row 7 "$DUE" always)"
run_block "Archie approve I7"
check "O1 intercepted: delivered, the turn never ran" '[ -s "$T/delivered" ] && [ ! -e "$T/fell" ]'
eq "O1 the reply is signed Archie" "$(tail -1 "$T/delivered")" Archie
check "O1 the turn is recorded for the next lane" 'grep -q "^archie Archie approve I7 / " "$T/orc-context.log"'
eq "O1 the decision landed" "$(fld 7 last_decision)" approve
run_block "what is the build queue doing?"
check "O2 not a command: falls through, nothing delivered" '[ -e "$T/fell" ] && [ ! -e "$T/delivered" ]'
# The persona: the v2 prompt says who it is and carries the soul.
FN=$(sed -n '/^compose_v2_prompt() {/,/^}/p' "$SRC")
P=$(env HARNESS="$H" TEXT=hi META_TRANSPORT=telegram ORIGIN="" bash -c "$FN"$'\n''compose_v2_prompt' 2>/dev/null)
check "O3 v2 prompt names ARCHIE" 'grep -q "You are ARCHIE" <<<"$P"'
check "O3 v2 prompt carries the soul" 'grep -qF "Owner, not assistant." <<<"$P"'
check "O3 the survival brief names Archie" 'sed -n "/^read -r -d .. SURVIVAL_BRIEF/,/^BRIEF$/p" "$SRC" | grep -q "Archie"'
# Every reply leaves signed: the line before the one delivery.
check "O4 OUT is signed right before deliver_reply" \
  '[ "$(grep -B1 "^deliver_reply \"\$OUT\"" "$SRC" | head -1)" = "OUT=\$(archie_sign \"\$OUT\")" ]'

# ═════ X: mutations of the shipped lane (D1) ═════════════════════════════════
# X1: without the client-side due re-check, T2's not-due row would be paid for.
sed '/^  # >>> due recheck/,/^  # <<< due recheck/d' "$DIR/bin/archie.sh" > "$T/archie-x1.sh"
check "X1 the due-recheck markers exist" '! cmp -s "$T/archie-x1.sh" "$DIR/bin/archie.sh"'
reset "$(row 8 "$FUTURE" always)"
row 8 "$FUTURE" always | jq -c '{initiatives: [.], truncated: false}' > "$T/due.override"
cp "$T/archie-x1.sh" "$H/bin/archie-x1.sh"
env HARNESS_TEST_SANDBOX=1 ARCHIE_NOW="$NOW" ARCHIE_FIXTURE="$T/fx.sh" LANE_GATE_DISABLE=1 bash "$H/bin/archie-x1.sh" tick >/dev/null 2>&1
check "X1 mutant pays for a not-due row (so T2 is a real guard)" '[ "$(calls)" = 1 ]'
# X2: without reusing a composed body, T8's retry would call the model again.
sed '/^    # >>> composed reuse/,/^    # <<< composed reuse/d' "$DIR/bin/archie.sh" > "$H/bin/archie-x2.sh"
check "X2 the composed-reuse markers exist" '! cmp -s "$H/bin/archie-x2.sh" "$DIR/bin/archie.sh"'
reset "$(row 23 "$DUE" always)"; echo 1 > "$T/beat.rc"
env HARNESS_TEST_SANDBOX=1 ARCHIE_NOW="$NOW" ARCHIE_FIXTURE="$T/fx.sh" LANE_GATE_DISABLE=1 bash "$H/bin/archie-x2.sh" tick >/dev/null 2>&1
rm -f "$T/beat.rc"
env HARNESS_TEST_SANDBOX=1 ARCHIE_NOW="$NOW" ARCHIE_FIXTURE="$T/fx.sh" LANE_GATE_DISABLE=1 bash "$H/bin/archie-x2.sh" tick >/dev/null 2>&1
check "X2 mutant calls the model twice (so T8 is a real guard)" '[ "$(calls)" = 2 ]'
# X3: without the attempt written before the call, T13's ticks would pay twice.
sed 's/^\( *\)if ! post_check "\$id" "\$due" model_failed "\$v" "\$((att + 1))" 0 attempt; then$/\1if false; then/' "$DIR/bin/archie.sh" > "$H/bin/archie-x3.sh"
check "X3 the attempt-write line exists" '! cmp -s "$H/bin/archie-x3.sh" "$DIR/bin/archie.sh"'
reset "$(row 42 "$DUE" always)"; : > "$T/check.down"
for _ in 1 2; do
  env HARNESS_TEST_SANDBOX=1 ARCHIE_NOW="$NOW" ARCHIE_FIXTURE="$T/fx.sh" LANE_GATE_DISABLE=1 bash "$H/bin/archie-x3.sh" tick >/dev/null 2>&1
done
check "X3 mutant calls the model twice (so T13 is a real guard)" '[ "$(calls)" = 2 ]'
rm -f "$H/bin/archie-x1.sh" "$H/bin/archie-x2.sh" "$H/bin/archie-x3.sh"

# ═════ the worker half, for real ═════════════════════════════════════════════
if ! command -v node >/dev/null 2>&1; then
  echo "archie-initiative-tracer: node suite SKIPPED — node is not installed on this box"
elif [ ! -f "$DIR/catalog/lanes.json" ]; then
  echo "archie-initiative-tracer: node suite SKIPPED — catalog/lanes.json is not composed (bin/lanes-build.sh --write)"
elif NOUT=$(cd "$DIR/worker/jobs" && node --test test/initiatives.bh-4062.test.js 2>&1); then ok
else bad "node suite worker/jobs/test/initiatives.bh-4062.test.js failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error|expected|actual' | head -30
fi

echo "archie-initiative-tracer: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
