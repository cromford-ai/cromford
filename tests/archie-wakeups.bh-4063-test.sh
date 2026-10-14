#!/bin/bash
# tests/archie-wakeups.bh-4063-test.sh — BH-4063 (BH-3966.2): Archie's
# proactive wake-ups, driven through the SHIPPED bin/archie.sh tick and the
# shipped bin/archie-followup.sh, with bin/lib/archie-wake.sh sourced by them.
#
# WHAT IS STUBBED. The lane runs from a scratch harness ($H: a symlink tree of
# the repo's bin/, a copy of catalog/lanes.d and the prompt files) with:
#   bin/agent-call.sh  counts calls, keeps the prompt, answers $T/ac.text;
#   bin/beat.sh        appends its payload to $T/beats.jsonl, exits $T/beat.rc;
#   bin/alert-line.sh  appends to $T/alerts.log (never $H/logs/ALERTS.log).
# ARCHIE_FIXTURE=$T/fx.sh replaces _jobs_req with a jq model over $T/db.json
# of the routes this lane reaches: /api/initiatives (list, create, check,
# events), /api/ledger (get, list with the before/before_key cursor, put with
# the worker's detail COALESCE) and /api/verdict. The REAL job_ledger_get /
# job_ledger_put / job_ledger_list / ledger_page / job_pr_facts run on top of
# it. $T/wakeget.down makes a GET of an archie_wake key an outage (rc 1).
# The clock is ARCHIE_NOW, a fixed instant (no wall-clock read).
#
# Cases A1-A13 are the plan's acceptance tests; X1-X3 mutate the shipped lib
# and prove A6 / A9 / A11 go red without the behaviour they pin (D1).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-wakeups.bh-4063-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "archie-wakeups: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

# The product paths this ticket ships (D41).
for f in "$DIR/bin/lib/archie-wake.sh" "$DIR/bin/archie-followup.sh" "$DIR/bin/archie.sh" \
         "$DIR/catalog/switches.d/archie-wake-off.json" "$DIR/env-templates/lanes/377-archie-wake.env.example"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
if [ ! -f "$DIR/bin/lib/archie-wake.sh" ] || [ ! -f "$DIR/bin/archie-followup.sh" ]; then
  echo "archie-wakeups: $PASS passed, $FAIL failed"; exit 1
fi

# ═════ L: the link parser, sourced from the repo ═════════════════════════════
# shellcheck source=../bin/lib/archie-wake.sh
. "$DIR/bin/lib/archie-wake.sh" || { echo "FAIL: cannot source bin/lib/archie-wake.sh"; exit 1; }
lk() { archie_links "$1" | tr '\n' ' '; }
eq "L1 en-dash range"      "$(lk 'Tracer-first slicing (#3954–#3956)')" "3954 3955 3956 "
eq "L1 hyphen range"       "$(lk 'cuts #10-#12 rework')" "10 11 12 "
eq "L1 bare BH and #"      "$(lk 'see BH-77 and #78, bh-79')" "77 78 79 "
eq "L1 issue/pull urls"    "$(lk 'https://github.com/x/y/issues/5 https://github.com/x/y/pull/6')" "5 6 "
eq "L1 range capped at 50" "$(archie_links '#1–#500' | wc -l | tr -d ' ')" 50
eq "L1 nothing"            "$(lk 'no tickets 2026-10-03 here')" ""

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/catalog/prompts" "$H/prompts" "$H/env" "$H/logs" "$T/fakebin"
cp -rs "$DIR/bin" "$H/bin"
cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
[ -d "$DIR/catalog/switches.d" ] && cp -r "$DIR/catalog/switches.d" "$H/catalog/"
cp -r "$DIR/prompts/archie-soul.d" "$H/prompts/"
cp "$DIR/catalog/prompts/archie-check.md" "$H/catalog/prompts/"
: > "$H/env/global.env"
rm -f "$H/bin/agent-call.sh" "$H/bin/beat.sh" "$H/bin/archie-tg-send.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s|%s\n' "$*" "${AGENT_CALL_FP:-}" >> "$FXT/agentcalls"
case "${6:-}" in @*) cp "${6#@}" "$FXT/prompt.last"; cat "${6#@}" >> "$FXT/prompts.all" ;; esac
cat "$FXT/ac.text" > "$5"
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
# BH-4779: Archie's Telegram transport, captured where the beats were.
cat > "$H/bin/archie-tg-send.sh" <<'SH'
#!/bin/bash
jq -nc --arg a "$1" --arg l "$2" '{akey: $a, line: $l}' >> "$FXT/beats.jsonl"
exit "$(cat "$FXT/beat.rc" 2>/dev/null || echo 0)"
SH
chmod +x "$H/bin/agent-call.sh" "$H/bin/beat.sh" "$H/bin/archie-tg-send.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
for c in curl gh; do
  printf '#!/bin/bash\nprintf "%%s %%s\\n" %s "$*" >> "$FXT/net.log"\nexit 7\n' "$c" > "$T/fakebin/$c"
  chmod +x "$T/fakebin/$c"
done

# The worker, modelled in jq over $T/db.json. _jobs_req's rc contract
# (bin/lib/jobs/req.sh): 0 on a 2xx, 9 on 409, 2 on 404, 1 on anything else.
cat > "$T/fx.sh" <<'SH'
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" out code=200 id k t
  JOBS_HTTP=""; JOBS_BODY=""
  case "$p" in /api/settings*|/api/flags*|/api/lanes*)
    [ "$p" = /api/settings ] && { printf '{"settings":[]}'; JOBS_HTTP=200; return 0; }
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
    "POST /api/initiatives")
      out=$(jq -c --argjson b "$b" '($b.goal | ascii_downcase | gsub("[^a-z0-9]+"; "-") | gsub("^-+|-+$"; "")) as $s
        | (.initiatives[] | select(.slug == $s)) // empty | {ok: true, existing: true, initiative: .}' "$db")
      if [ -z "$out" ]; then
        jq --argjson b "$b" '($b.goal | ascii_downcase | gsub("[^a-z0-9]+"; "-") | gsub("^-+|-+$"; "")) as $s
          | .initiatives += [$b + {id: ((([.initiatives[].id] | max) // 0) + 1), slug: $s, status: "active",
                                  links: ($b.links // []), last_value: null}]' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
        out=$(jq -c '{ok: true, created: true, initiative: .initiatives[-1]}' "$db"); code=201
      fi ;;
    "GET /api/initiatives/events")
      out=$(jq -c --arg k "$(qp key)" '.events[$k] // empty | {event: .}' "$db")
      [ -n "$out" ] || { JOBS_HTTP=404; return 2; } ;;
    "POST /api/initiatives/check")
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
      out='{"ok":true}' ;;
    "GET /api/ledger")
      k=$(qp kind)
      if grep -q '[?&]key=' <<<"$p"; then
        [ "$k" = archie_wake ] && [ -f "$FXT/wakeget.down" ] && { JOBS_HTTP=503; return 1; }
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
    "GET /api/verdict")
      out=$(jq -c --arg u "$(qp pr)" '.verdicts[$u] // empty | {job_id: "j1", job: {project: "cromford", ticket_id: .}}' "$db")
      [ -n "$out" ] || { JOBS_HTTP=404; return 2; } ;;
    *) JOBS_HTTP=404; return 2 ;;
  esac
  JOBS_HTTP=$code; JOBS_BODY="$out"; printf '%s' "$out"; return 0
}
lane_role_model() { [ -f "$FXT/noroute" ] && return 75; [ "$1" = stage.archie ] || return 75; echo test-model; }
SH

export HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.invalid HARNESS_SECRET=test
unset ARCHIE_ENABLED ARCHIE_MAX_PER_TICK ARCHIE_NOW ARCHIE_FIXTURE ARCHIE_TIMED BEAT_STRICT \
  ARCHIE_BEAT_CAP_DAY ARCHIE_QUIET_FROM_H ARCHIE_QUIET_TO_H ARCHIE_WAKE_ALERT_SCOPE 2>/dev/null || true

NOW=1791184500                       # 2026-10-05T07:15:00Z, fixed: no wall-clock read
D0=1791158400                        # 2026-10-05T00:00:00Z
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
NOWISO=$(iso "$NOW")
DUE=$(iso $((NOW - 900)))
FUTURE=$(iso $((NOW + 3600)))
DAY=2026-10-05
PR1=https://github.com/example-org/cromford/pull/4200
PR0=https://github.com/example-org/cromford/pull/4100
PR3=https://github.com/example-org/cromford/pull/4300
REC='Rework is moving, so look at the slicing numbers this week.'
METRIC='csv:logs/rework.csv#decomposed_rate@project=cromford'
cat > "$H/logs/rework.csv" <<'EOF'
week,project,merged,reworked,rate,decomposed_merged,decomposed_reworked,decomposed_rate,sibling_reworked,source
2026-W40,cromford,9,1,11.1,4,0,9.0,0,x
EOF

# row <id> <goal> <rule> [metric] [next_check_at] [status]: last_value is the
# metric's current 9.0, so a `change` rule alone would stay silent.
row() {
  jq -nc --argjson i "$1" --arg g "$2" --arg r "$3" --arg m "${4:-none}" --arg n "${5:-$FUTURE}" --arg s "${6:-active}" \
    '{id: $i, slug: "init-\($i)", goal: $g, metric_query: $m, cadence_hours: 168, escalation_rule: $r,
      status: $s, next_check_at: $n, links: [], last_value: (if $m == "none" then null else "9.0" end),
      last_check_status: null}'
}
I1=$(row 1 'Tracer-first slicing cuts rework (#3954–#3956)' change "$METRIC")
I2=$(row 2 'Ship the dashboard (BH-5000)' always)
reset() {
  local p
  for p in reqlog beats.jsonl agentcalls alerts.log prompt.last prompts.all beat.rc noroute jobs.down wakeget.down net.log out rc; do
    scratch_rm "$T/$p" || exit 1
  done
  scratch_rm "$H/state" || exit 1; scratch_rm "$H/locks" || exit 1; scratch_rm "$H/flags" || exit 1
  for p in archie.log ALERTS.log decisions.log outcome-metrics.csv; do scratch_rm "$H/logs/$p" || exit 1; done
  printf '%s\n' "$REC" > "$T/ac.text"
  jq -nc '{initiatives: $ARGS.positional, events: {}, ledger: {}, verdicts: {}}' --jsonargs "$@" > "$T/db.json"
  : > "$T/reqlog"
  CLOCK=$NOW
}
tick() {
  env HARNESS_TEST_SANDBOX=1 ARCHIE_NOW="$CLOCK" ARCHIE_FIXTURE="$T/fx.sh" LANE_GATE_DISABLE=1 "$@" \
    bash "$H/bin/archie.sh" tick > "$T/out" 2>&1
  echo $? > "$T/rc"
}
n()     { local c; c=$(wc -l 2>/dev/null < "$1"); printf '%s' "${c:-0}" | tr -d ' '; }
calls() { n "$T/agentcalls"; }
beats() { n "$T/beats.jsonl"; }
lg()    { jq -r --arg k "$1|$2" '.ledger[$k].status // "none"' "$T/db.json"; }
lgd()   { jq -r --arg k "$1|$2" '.ledger[$k].detail // "none"' "$T/db.json"; }
lcount() { jq -r --arg k "$1" --arg s "${2:-}" '[.ledger[] | select(.kind == $k and ($s == "" or .status == $s))] | length' "$T/db.json"; }
fld()   { jq -r --argjson i "$1" --arg f "$2" '.initiatives[] | select(.id == $i) | .[$f] // "null"' "$T/db.json"; }
fwid()  { jq -r '.initiatives[] | select(.slug == "factory-watch") | .id' "$T/db.json"; }
merge_row() { # merge_row <url> <updated_at> <ticket>
  jq --arg u "$1" --arg t "$2" --arg k "$3" '.ledger["merge|" + $u] = {kind: "merge", key: $u, status: "merged", updated_at: $t}
    | .verdicts[$u] = $k' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
}
alert() { printf '%s %s\n' "${2:-2026-10-05 07:01:00Z}" "$1" >> "$H/logs/ALERTS.log"; }
writes() { grep -cE '^(POST|PUT) ' "$T/reqlog"; }

# ── A1: an initiative-linked PR merge wakes it once ──────────────────────────
reset "$I1" "$I2"
merge_row "$PR0" 2026-10-04T10:00:00Z BH-3954     # history: the baseline swallows it
tick
eq "A1 baseline: no call" "$(calls)" 0
check "A1 baseline cursor written" '[ -s "$H/state/archie/cursors/merge" ]'
merge_row "$PR1" 2026-10-05T07:10:00Z BH-3955
tick
check "A1 rc 0 ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
eq "A1 one model call" "$(calls)" 1
eq "A1 ledger archie_wake merge:<url>" "$(lg archie_wake "merge:$PR1")" woken
eq "A1 the woken row names I1" "$(lgd archie_wake "merge:$PR1")" 1
eq "A1 history was not woken" "$(lg archie_wake "merge:$PR0")" none
eq "A1 the superseded slot closed silent (the mark-due)" "$(jq -r --arg k "check:1:$FUTURE" '.events[$k].status' "$T/db.json")" silent
eq "A1 the woken slot was checked and sent" "$(jq -r --arg k "check:1:$NOWISO" '.events[$k].status' "$T/db.json")" sent
eq "A1 advanced to now + cadence" "$(fld 1 next_check_at)" "$(iso $((NOW + 168 * 3600)))"
check "A1 the prompt names the merge" 'grep -qF "$PR1" "$T/prompt.last" && grep -qF "Events this check is answering" "$T/prompt.last"'
eq "A1 one beat" "$(beats)" 1
check "A1 I2 was not woken" '[ "$(fld 2 next_check_at)" = "$FUTURE" ]'
check "A1 wake context consumed" '[ ! -e "$H/state/archie/wake-context/1.txt" ]'
check "A1 no network" '[ ! -s "$T/net.log" ]'

# ── A2: replan-escalate with no linked initiative -> factory-watch ───────────
reset "$I1"
tick
printf '%s\n' '2026-10-05 07:05:00Z [cromford] gate=replan scope=child BH-9001 :: replan-escalate :: pick A or B' >> "$H/logs/decisions.log"
: > "$T/noroute"            # no model route: the row stays due and the context stays
tick
FW=$(fwid)
check "A2 factory-watch created through POST /api/initiatives ($(grep '^POST /api/initiatives ' "$T/reqlog"))" '[ -n "$FW" ]'
check "A2 the wake-context file holds the decision" 'grep -qF "pick A or B" "$H/state/archie/wake-context/$FW.txt"'
WFP=$(jq -r '.ledger | keys[] | select(startswith("archie_wake|replan:BH-9001:"))' "$T/db.json" | sed 's/^archie_wake|//')
check "A2 fingerprint replan:BH-9001:<cksum> ($WFP)" '[[ $WFP =~ ^replan:BH-9001:[0-9]+$ ]]'
eq "A2 woken" "$(lg archie_wake "$WFP")" woken
rm -f "$T/noroute"
tick
eq "A2 one check" "$(calls)" 1
check "A2 the prompt carries the decision" 'grep -qF "pick A or B" "$T/prompt.last"'
check "A2 I1 untouched" '[ "$(fld 1 next_check_at)" = "$FUTURE" ]'
tick
eq "A2 no second check" "$(calls)" 1

# ── A3: an outcome row (reworked) wakes the rework initiative once ───────────
reset "$I1" "$I2"
printf '%s\n' 'date,repo,pr,outcome,evidence,repairs' "2026-10-04,example-org/cromford,$PR0,reworked,old,1" > "$H/logs/outcome-metrics.csv"
tick
printf '%s\n' "2026-10-05,example-org/cromford,$PR3,reworked,\"follow-up fix, same file\",2" >> "$H/logs/outcome-metrics.csv"
tick
eq "A3 one check" "$(calls)" 1
eq "A3 outcome:<pr>:reworked woken" "$(lg archie_wake "outcome:$PR3:reworked")" woken
eq "A3 woke I1 only" "$(lgd archie_wake "outcome:$PR3:reworked")" 1
eq "A3 history row not woken" "$(lg archie_wake "outcome:$PR0:reworked")" none
check "A3 I2 untouched" '[ "$(fld 2 next_check_at)" = "$FUTURE" ]'

# ── A4: alerts ────────────────────────────────────────────────────────────────
reset "$I1" "$I2"
tick
alert 'build of BH-3954 failed twice on the hub'
tick
eq "A4 a linked alert: one check" "$(calls)" 1
eq "A4 woken" "$(lcount archie_wake woken)" 1
reset "$I1" "$I2"
tick
alert 'disk at 91% on project-3'
tick
eq "A4 unlinked alert at the default 1: no check" "$(calls)" 0
eq "A4 no wake row" "$(lcount archie_wake)" 0
check "A4 no factory-watch" '[ -z "$(fwid)" ]'
reset "$I1" "$I2"
tick ARCHIE_WAKE_ALERT_SCOPE=2
alert 'disk at 91% on project-3'
tick ARCHIE_WAKE_ALERT_SCOPE=2
check "A4 =2: factory-watch woken" '[ -n "$(fwid)" ] && [ "$(lcount archie_wake woken)" = 1 ] && [ "$(calls)" = 1 ]'
check "A4 =2 fingerprint alert:<cksum>:<day>" 'jq -e --arg d "$DAY" "[.ledger | keys[] | select(test(\"^archie_wake\\\\|alert:[0-9]+:\" + \$d + \"\$\"))] | length == 1" "$T/db.json" >/dev/null'
reset "$I1"
tick ARCHIE_WAKE_ALERT_SCOPE=0
alert 'build of BH-3954 failed twice on the hub'
tick ARCHIE_WAKE_ALERT_SCOPE=0
eq "A4 =0: off" "$(calls)" 0
# Archie's own ALERTS lines never wake Archie.
reset "$I1"
tick ARCHIE_WAKE_ALERT_SCOPE=2
alert 'archie: initiative 1 check 2026-10-05T07:00:00Z failed 2 times; skipped to the next cadence'
tick ARCHIE_WAKE_ALERT_SCOPE=2
eq "A4 Archie's own alert: no wake" "$(lcount archie_wake)" 0

# ── A5: a lane over its daily budget wakes factory-watch ─────────────────────
reset "$I1"
tick
alert '[alert-triage] DAILY SPEND CAP: $41 spent today against a $40/day cap — this lane is STOPPED until 00:00Z'
tick
FW=$(fwid)
eq "A5 budget:<lane>:<day> woken" "$(lg archie_wake "budget:alert-triage:$DAY")" woken
eq "A5 on factory-watch" "$(lgd archie_wake "budget:alert-triage:$DAY")" "$FW"
eq "A5 one check" "$(calls)" 1
eq "A5 not also an alert: row" "$(lcount archie_wake)" 1

# ── A6: a duplicate event gives no second wake ───────────────────────────────
reset "$I1" "$I2"
tick
merge_row "$PR1" 2026-10-05T07:10:00Z BH-3955
alert 'build of BH-5000 failed twice on the hub'
alert 'build of BH-5000 failed twice on the hub'      # identical, same tick
printf '%s\n' '2026-10-05 07:05:00Z [cromford] gate=replan scope=child BH-3956 :: replan-escalate :: split it' >> "$H/logs/decisions.log"
tick
C1=$(calls); W1=$(lcount archie_wake)
eq "A6 two initiatives woken, one check each" "$C1" 2
eq "A6 identical alert lines: one row (merge + alert + replan)" "$W1" 3
for c in "$H"/state/archie/cursors/*; do echo 0 > "$c"; done
: > "$T/reqlog"
# A later tick: at the same instant a re-woken slot would collide with the one
# already sent and be repaired without a call, which would hide a missing dedup.
CLOCK=$((NOW + 900)); tick
eq "A6 cursors reset: no new model call" "$(calls)" "$C1"
eq "A6 cursors reset: no new wake row" "$(lcount archie_wake)" "$W1"
eq "A6 cursors reset: no write at all" "$(writes)" 0
# #3995 re-recording the same escalate is the same fingerprint.
printf '%s\n' '2026-10-05 07:20:00Z [cromford] gate=replan scope=child BH-3956 :: replan-escalate :: split it' >> "$H/logs/decisions.log"
CLOCK=$((NOW + 1800)); tick
eq "A6 re-recorded escalate: no wake" "$(calls)" "$C1"
printf '%s\n' '2026-10-05 07:21:00Z [cromford] gate=replan scope=child BH-3956 :: replan-escalate :: split it in three' >> "$H/logs/decisions.log"
CLOCK=$((NOW + 2700)); tick
eq "A6 a changed decision wakes once more" "$(calls)" $((C1 + 1))

# ── A7: two events for one initiative in one tick -> two rows, one check ─────
reset "$I1"
tick
merge_row "$PR1" 2026-10-05T07:10:00Z BH-3955
alert 'review of BH-3956 blocked on a missing test'
tick
eq "A7 two wake rows" "$(lcount archie_wake woken)" 2
eq "A7 one check" "$(calls)" 1
check "A7 the one prompt carries both events" 'grep -qF "$PR1" "$T/prompt.last" && grep -qF "missing test" "$T/prompt.last"'

# ── A8: follow-ups fire on their date ────────────────────────────────────────
reset "$I1"
fu() { env HARNESS_TEST_SANDBOX=1 ARCHIE_NOW="$CLOCK" ARCHIE_FIXTURE="$T/fx.sh" LANE_GATE_DISABLE=1 bash "$H/bin/archie-followup.sh" "$@"; }
OUT=$(fu add 3d "re-check rework" --initiative I1); RC=$?
eq "A8 add rc 0 ($OUT)" "$RC" 0
eq "A8 one pending row" "$(lcount archie_followup pending)" 1
FK=$(jq -r '.ledger[] | select(.kind == "archie_followup") | .key' "$T/db.json")
check "A8 key fu-<sha8> ($FK)" '[[ $FK =~ ^fu-[0-9a-f]{8}$ ]]'
check "A8 detail {due_at, initiative_id, note}" 'lgd archie_followup "$FK" | jq -e --arg d "$(iso $((NOW + 3 * 86400)))" ".due_at == \$d and .initiative_id == 1 and .note == \"re-check rework\"" >/dev/null'
fu add 3d "re-check rework" --initiative I1 >/dev/null
eq "A8 asking twice writes one row" "$(lcount archie_followup)" 1
OUT=$(fu add someday "x" 2>&1); RC=$?
eq "A8 a bad date is refused rc 2 ($OUT)" "$RC" 2
eq "A8 no row for it" "$(lcount archie_followup)" 1
check "A8 list shows it" 'fu list | grep -qF "re-check rework"'
CLOCK=$((NOW + 2 * 86400)); tick
eq "A8 NOW+2d: no wake" "$(calls)" 0
eq "A8 NOW+2d: still pending" "$(lg archie_followup "$FK")" pending
CLOCK=$((NOW + 3 * 86400)); tick
eq "A8 NOW+3d: one check" "$(calls)" 1
eq "A8 NOW+3d: fired" "$(lg archie_followup "$FK")" fired
eq "A8 followup:<key> woken" "$(lg archie_wake "followup:$FK")" woken
check "A8 the note reached the prompt" 'grep -qF "re-check rework" "$T/prompt.last"'
CLOCK=$((NOW + 4 * 86400)); tick
eq "A8 NOW+4d: no second wake" "$(calls)" 1
# A FOLLOWUP: line in a check's answer writes a row, and never reaches the operator.
reset "$I2"
printf '%s\n' "$REC" 'FOLLOWUP: 2026-10-10 :: x' > "$T/ac.text"
CLOCK=$NOW
jq --arg d "$DUE" '.initiatives[0].next_check_at = $d' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
tick
eq "A8 FOLLOWUP line: one row" "$(lcount archie_followup pending)" 1
check "A8 FOLLOWUP row due 2026-10-10 on I2" 'jq -e "[.ledger[] | select(.kind == \"archie_followup\") | .detail | fromjson
  | select(.due_at == \"2026-10-10T00:00:00Z\" and .initiative_id == 2 and .note == \"x\")] | length == 1" "$T/db.json" >/dev/null'
check "A8 the beat carries no FOLLOWUP line" '[ "$(beats)" = 1 ] && ! grep -q FOLLOWUP "$T/beats.jsonl"'

# ── A9: the daily beat cap holds the rest for one digest ─────────────────────
cap_world() {
  reset "$(row 1 'Watch #101' always)" "$(row 2 'Watch #102' always)" "$(row 3 'Watch #103' always)" "$(row 4 'Watch #104' always)"
  tick ARCHIE_BEAT_CAP_DAY=2 ARCHIE_MAX_PER_TICK=10
  for i in 1 2 3 4; do alert "deploy of BH-10$i needs a look"; done
  tick ARCHIE_BEAT_CAP_DAY=2 ARCHIE_MAX_PER_TICK=10
}
cap_world
eq "A9 four checks" "$(calls)" 4
eq "A9 two individual beats" "$(beats)" 2
eq "A9 two held" "$(lcount archie_digest queued)" 2
eq "A9 today's count" "$(lg archie_beatday "$DAY")" 2
CLOCK=$((NOW + 86400)); tick ARCHIE_BEAT_CAP_DAY=2 ARCHIE_MAX_PER_TICK=10
eq "A9 next day: exactly one more beat" "$(beats)" 3
DG=$(sed -n 3p "$T/beats.jsonl" | jq -r .line)
check "A9 the digest holds both held texts ($DG)" 'grep -qF "Archie approve I3" <<<"$DG" && grep -qF "Archie approve I4" <<<"$DG"'
check "A9 the digest header" 'head -1 <<<"$DG" | grep -qF "Held 2 updates"'
eq "A9 signed once" "$(grep -cx Archie <<<"$DG")" 1
eq "A9 both rows sent" "$(lcount archie_digest sent)" 2
eq "A9 the digest counts as one" "$(lg archie_beatday 2026-10-06)" 1
tick ARCHIE_BEAT_CAP_DAY=2 ARCHIE_MAX_PER_TICK=10
eq "A9 no second digest" "$(beats)" 3
cap_world
echo 1 > "$T/beat.rc"
CLOCK=$((NOW + 86400)); tick ARCHIE_BEAT_CAP_DAY=2 ARCHIE_MAX_PER_TICK=10
eq "A9 a failed digest send leaves both queued" "$(lcount archie_digest queued)" 2
eq "A9 and counts nothing" "$(lg archie_beatday 2026-10-06)" none
rm -f "$T/beat.rc"
tick ARCHIE_BEAT_CAP_DAY=2 ARCHIE_MAX_PER_TICK=10
eq "A9 retried next tick: sent" "$(lcount archie_digest sent)" 2
# Cap 0: every beat is held; the digest still goes out once a day.
reset "$I2"
jq --arg d "$DUE" '.initiatives[0].next_check_at = $d' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
tick ARCHIE_BEAT_CAP_DAY=0
eq "A9 cap 0: held, not sent" "$(lcount archie_digest queued)" 1
CLOCK=$((NOW + 900)); tick ARCHIE_BEAT_CAP_DAY=0
eq "A9 cap 0: the digest goes out" "$(beats)" 1
eq "A9 cap 0: sent" "$(lcount archie_digest sent)" 1

# ── A10: quiet hours ──────────────────────────────────────────────────────────
QH=(ARCHIE_QUIET_FROM_H=22 ARCHIE_QUIET_TO_H=6)
reset "$I2"
CLOCK=$((D0 + 23 * 3600))
jq --arg d "$(iso $((CLOCK - 60)))" '.initiatives[0].next_check_at = $d' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
tick "${QH[@]}"
eq "A10 23:00Z: checked" "$(calls)" 1
eq "A10 23:00Z: not sent" "$(beats)" 0
eq "A10 23:00Z: queued" "$(lcount archie_digest queued)" 1
CLOCK=$((D0 + 86400 + 5 * 3600)); tick "${QH[@]}"
eq "A10 05:00Z: still quiet" "$(beats)" 0
CLOCK=$((D0 + 86400 + 6 * 3600 + 300)); tick "${QH[@]}"
eq "A10 06:05Z: one digest" "$(beats)" 1
check "A10 the digest is the held beat" 'jq -r .line "$T/beats.jsonl" | grep -qF "Archie approve I2"'

# ── A11: fail closed on a ledger outage ──────────────────────────────────────
reset "$I1"
tick
alert 'build of BH-3954 failed twice on the hub'
CUR=$(cat "$H/state/archie/cursors/alerts")
: > "$T/wakeget.down"
tick
eq "A11 outage: no call" "$(calls)" 0
eq "A11 outage: no wake row" "$(lcount archie_wake)" 0
eq "A11 outage: cursor unchanged" "$(cat "$H/state/archie/cursors/alerts")" "$CUR"
check "A11 outage: I1 not marked due" '[ "$(fld 1 next_check_at)" = "$FUTURE" ]'
rm -f "$T/wakeget.down"
tick
eq "A11 healthy: woken once" "$(lcount archie_wake woken)" 1
eq "A11 healthy: one call" "$(calls)" 1

# ── A12: the first run is a baseline; the kill switch ────────────────────────
reset "$I1" "$I2"
merge_row "$PR1" 2026-10-05T07:10:00Z BH-3955
alert 'build of BH-3954 failed twice on the hub'
printf '%s\n' '2026-10-05 07:05:00Z [cromford] gate=replan scope=child BH-3955 :: replan-escalate :: pick' >> "$H/logs/decisions.log"
printf '%s\n' 'date,repo,pr,outcome,evidence,repairs' "2026-10-05,example-org/cromford,$PR3,reworked,x,1" > "$H/logs/outcome-metrics.csv"
tick
eq "A12 baseline: no wake" "$(lcount archie_wake)" 0
eq "A12 baseline: no call" "$(calls)" 0
for s in merge replan outcome alerts; do
  check "A12 cursor $s written" '[ -s "$H/state/archie/cursors/$s" ]'
done
eq "A12 baseline cursor at EOF" "$(cat "$H/state/archie/cursors/alerts")" "$(wc -c < "$H/logs/ALERTS.log" | tr -d ' ')"
reset "$I1" "$(row 2 'Ship the dashboard (BH-5000)' always none "$DUE")"
tick
mkdir -p "$H/flags"; : > "$H/flags/archie-wake-off"
alert 'build of BH-3954 failed twice on the hub'
CUR=$(cat "$H/state/archie/cursors/alerts")
tick
eq "A12 switch: no wake row" "$(lcount archie_wake)" 0
eq "A12 switch: cursor unchanged" "$(cat "$H/state/archie/cursors/alerts")" "$CUR"
eq "A12 switch: the scheduled check still ran" "$(calls)" 1
eq "A12 switch: and its beat went" "$(beats)" 1
rm -f "$H/flags/archie-wake-off"
tick
eq "A12 switch off again: the held event wakes" "$(lcount archie_wake woken)" 1

# ── A13: a no-op tick costs nothing ──────────────────────────────────────────
reset "$I1" "$I2"
tick
: > "$T/reqlog"
tick
eq "A13 no model call" "$(calls)" 0
eq "A13 no beat" "$(beats)" 0
eq "A13 no write" "$(writes)" 0
check "A13 the active list is not read with no event ($(cat "$T/reqlog"))" '! grep -q "^GET /api/initiatives?status=active&limit=" "$T/reqlog"'

# A shrunk (rotated) file resets its cursor to 0.
reset "$I1"
alert 'old line one'; alert 'old line two'
tick
: > "$H/logs/ALERTS.log"
alert 'build of BH-3954 failed twice on the hub'
tick
eq "R1 a rotated ALERTS.log is read from 0" "$(lcount archie_wake woken)" 1

# ═════ X: mutations of the shipped lib (D1) ══════════════════════════════════
LIB="$H/bin/lib/archie-wake.sh"
mutate() { rm -f "$LIB"; sed "$1" "$DIR/bin/lib/archie-wake.sh" > "$LIB"; }
restore() { rm -f "$LIB"; ln -s "$DIR/bin/lib/archie-wake.sh" "$LIB"; }
# X1: without the dedup read, A6's cursor reset wakes everything again.
mutate '/^  # >>> wake dedup/,/^  # <<< wake dedup/d'
check "X1 the dedup markers exist" '! cmp -s "$LIB" "$DIR/bin/lib/archie-wake.sh"'
reset "$I1"
tick
alert 'build of BH-3954 failed twice on the hub'
tick
for c in "$H"/state/archie/cursors/*; do echo 0 > "$c"; done
CLOCK=$((NOW + 900)); tick
check "X1 mutant wakes the duplicate (so A6 is a real guard): calls=$(calls)" '[ "$(calls)" = 2 ]'
restore
# X2: a direct send in place of the gate breaks the cap (A9).
mutate 's/^  if _aw_beat_allowed; then$/  if true; then/'
check "X2 the gate line exists" '! cmp -s "$LIB" "$DIR/bin/lib/archie-wake.sh"'
cap_world
check "X2 mutant sends all four (so A9 is a real guard): beats=$(beats)" '[ "$(beats)" = 4 ]'
restore
# X3: treating an outage as a miss wakes on A11's outage.
mutate 's/^    1) _aw_down "archie_wake read"; return 1 ;;$/    1) ;;/'
check "X3 the outage line exists" '! cmp -s "$LIB" "$DIR/bin/lib/archie-wake.sh"'
reset "$I1"
tick
alert 'build of BH-3954 failed twice on the hub'
: > "$T/wakeget.down"
tick
check "X3 mutant wakes during the outage (so A11 is a real guard): calls=$(calls)" '[ "$(calls)" = 1 ]'
restore

echo "archie-wakeups: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
