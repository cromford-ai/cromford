#!/bin/bash
# tests/archie-check-retry.bh-4609-test.sh — BH-4609: Archie's self-caused
# failures, driven through the SHIPPED bin/archie.sh tick.
#
#   R1       the registry's ARCHIE_LLM_MAX_USD default is 0.6 and an unset knob
#            reaches agent-call as AGENT_CALL_BUDGET_USD_ARCHIE=0.60
#   R2-R6    a BUDGET STOP stays open, backs off ARCHIE_RETRY_BACKOFF_MIN (60m),
#            retries within the hour, ONE knob alert per slot, closes after
#            ARCHIE_RETRY_MAX attempts with one close line
#   R7       an ordinary billed failure still closes at ARCHIE_MAX_ATTEMPTS
#   R8       no route / ARCHIE_LLM_MAX_USD=0 / rc 77 count no attempt
#   R9-R11   an unreadable metric re-checks after min(ARCHIE_UNREADABLE_RECHECK_H,
#            cadence) hours, the repair arm too
#   R12      knob junk is one warn line and the default
#   R13      agent-call's sidecars ($raw.json, $raw.err) are cleaned
#   R14      archie_fail_class / archie_budget_stop, unit
#
# The worker fixture is the jq model from tests/archie-initiative-tracer-test.sh
# (same answers, same rc contract). The agent-call stub records its argv and
# AGENT_CALL_BUDGET_USD_ARCHIE; with $T/ac.budget present it writes that file
# as "$5.json" (the CLI's budget-stop envelope) and exits 1. Nothing here may
# reach the network: curl and gh on PATH log and fail.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-check-retry.bh-4609-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "archie-check-retry: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

# ═════ R14: the helpers, sourced from the repo ═══════════════════════════════
# shellcheck source=../bin/lib/archie.sh
. "$DIR/bin/lib/archie.sh" || { echo "FAIL: cannot source bin/lib/archie.sh"; exit 1; }
fc() { archie_fail_class "$1" 2>/dev/null; echo "rc=$?"; }
eq "R14 fail_class attempt" "$(fc attempt)" $'attempt\nrc=0'
eq "R14 fail_class empty"   "$(fc '')" $'attempt\nrc=0'
eq "R14 fail_class junk"    "$(fc 'budget_stop soon usd=1')" $'attempt\nrc=0'
eq "R14 fail_class budget"  "$(fc 'budget_stop 2026-10-05T08:15:00Z usd=0.60 cost=0.43')" $'budget_stop\t2026-10-05T08:15:00Z\nrc=0'
eq "R14 fail_class bare budget" "$(fc 'budget_stop 2026-10-05T08:15:00Z')" $'budget_stop\t2026-10-05T08:15:00Z\nrc=0'
eq "R14 fail_class glued junk" "$(fc 'budget_stop 2026-10-05T08:15:00Zx')" $'attempt\nrc=0'
mkdir -p "$T/u"
bs() { archie_budget_stop "$1" 2>/dev/null; echo "rc=$?"; }
eq "R14 budget_stop missing file" "$(bs "$T/u/nope.json")" "rc=1"
printf 'not json {' > "$T/u/junk.json"
eq "R14 budget_stop non-JSON" "$(bs "$T/u/junk.json")" "rc=1"
printf '{"type":"result","subtype":"success","total_cost_usd":0.2}' > "$T/u/ok.json"
eq "R14 budget_stop success envelope" "$(bs "$T/u/ok.json")" "rc=1"
printf '{"type":"result","subtype":"error_max_budget_usd","total_cost_usd":0.43}' > "$T/u/b.json"
eq "R14 budget_stop with cost" "$(bs "$T/u/b.json")" $'0.43\nrc=0'
printf '{"type":"result","subtype":"error_max_budget_usd"}' > "$T/u/bn.json"
eq "R14 budget_stop without cost" "$(bs "$T/u/bn.json")" $'?\nrc=0'
printf '{"type":"result","terminal_reason":"Budget exceeded","total_cost_usd":null}' > "$T/u/bt.json"
eq "R14 budget_stop terminal_reason, null cost" "$(bs "$T/u/bt.json")" $'?\nrc=0'

# ═════ the scratch harness (the tracer suite's, copied) ══════════════════════
H="$T/h"
mkdir -p "$H/catalog/prompts" "$H/prompts" "$H/env" "$H/logs" "$T/fakebin" "$T/tmp"
cp -rs "$DIR/bin" "$H/bin"
cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
[ -d "$DIR/catalog/switches.d" ] && cp -r "$DIR/catalog/switches.d" "$H/catalog/"
cp -r "$DIR/prompts/archie-soul.d" "$H/prompts/" 2>/dev/null
cp "$DIR/catalog/prompts/archie-check.md" "$H/catalog/prompts/" 2>/dev/null
: > "$H/env/global.env"
rm -f "$H/bin/agent-call.sh" "$H/bin/beat.sh" "$H/bin/archie-tg-send.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s|%s|%s|%s\n' "$*" "${AGENT_CALL_LANE:-}" "${AGENT_CALL_FP:-}" "${AGENT_CALL_BUDGET_USD_ARCHIE:-}" >> "$FXT/agentcalls"
: > "$5.err"
if [ -f "$FXT/ac.budget" ]; then cp "$FXT/ac.budget" "$5.json"; printf 'partial\n' > "$5"; exit 1; fi
rc=$(cat "$FXT/ac.rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] || exit "$rc"
printf '{"type":"result","subtype":"success","total_cost_usd":0.2}' > "$5.json"
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

# The worker, the tracer suite's jq model over $T/db.json.
cat > "$T/fx.sh" <<'SH'
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" out code=200 key id
  JOBS_HTTP=""; JOBS_BODY=""
  case "$p" in /api/settings*|/api/flags*|/api/lanes*)
    [ "$p" = /api/settings ] && { printf '{"settings":[]}'; JOBS_HTTP=200; return 0; }
    JOBS_HTTP=404; return 2 ;;
  esac
  printf '%s %s %s\n' "$m" "$p" "$b" >> "$FXT/reqlog"
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
      key=$(qp key)
      out=$(jq -c --arg k "$key" '.events[$k] // empty | {event: .}' "$db")
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
      out=$(jq -c --argjson b "$b" '{ok: true, advanced: ($b.advance_to != null)}' <<<'{}') ;;
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
  ARCHIE_LLM_MAX_USD ARCHIE_RETRY_MAX ARCHIE_RETRY_BACKOFF_MIN ARCHIE_UNREADABLE_RECHECK_H \
  ARCHIE_NOW ARCHIE_FIXTURE ARCHIE_CMD_ID ARCHIE_TIMED BEAT_STRICT 2>/dev/null || true

NOW=1791184500                       # 2026-10-05T07:15:00Z
DUE=2026-10-05T07:00:00Z             # due 15 minutes ago
isoat() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
iso_plus_h() { isoat $((NOW + $1 * 3600)); }
cat > "$H/logs/rework.csv" <<'CSV'
week,project,merged,reworked,rate,decomposed_merged,decomposed_reworked,decomposed_rate,sibling_reworked,source
2026-W40,cromford,9,1,11.1,4,0,9.0,0,x
2026-W40,project-3,9,1,11.1,0,0,-,0,x
CSV
METRIC='csv:logs/rework.csv#decomposed_rate@project=cromford'
UNREAD='csv:logs/rework.csv#decomposed_rate@project=project-3'
BUDGET='{"type":"result","subtype":"error_max_budget_usd","total_cost_usd":0.43}'

# row <id> <next_check_at> [metric] [cadence_hours]
row() {
  jq -nc --argjson i "$1" --arg n "$2" --arg m "${3:-$METRIC}" --argjson c "${4:-168}" \
    '{id: $i, slug: "init-\($i)", goal: "Rework under 10%", metric_query: $m, cadence_hours: $c,
      escalation_rule: "always", status: "active", next_check_at: $n,
      links: ["https://github.com/example-org/cromford/issues/4609"], last_value: null, last_check_status: null}'
}
reset() {
  local p
  for p in reqlog beats.jsonl agentcalls alerts.log ac.rc ac.budget noroute net.log out rc; do
    scratch_rm "$T/$p" || exit 1
  done
  scratch_rm "$H/locks" || exit 1; scratch_rm "$H/logs/archie.log" || exit 1
  scratch_rm "$T/tmp" || exit 1; mkdir -p "$T/tmp"
  printf 'Raise the cap and keep going.\n' > "$T/ac.text"
  jq -nc '{initiatives: $ARGS.positional, events: {}}' --jsonargs "$@" > "$T/db.json"
  : > "$T/reqlog"
}
# at <epoch> [VAR=val ...]: one tick at that now
at() {
  local when="$1"; shift
  env HARNESS_TEST_SANDBOX=1 ARCHIE_NOW="$when" ARCHIE_FIXTURE="$T/fx.sh" LANE_GATE_DISABLE=1 TMPDIR="$T/tmp" "$@" \
    bash "$H/bin/archie.sh" tick > "$T/out" 2>&1
  echo $? > "$T/rc"
}
n()     { local c; c=$(wc -l 2>/dev/null < "$1"); printf '%s' "${c:-0}" | tr -d ' '; }
calls() { n "$T/agentcalls"; }
beats() { n "$T/beats.jsonl"; }
alerts() { n "$T/alerts.log"; }
posts() { grep -c '^POST /api/initiatives/check ' "$T/reqlog"; }
ev()    { jq -r --arg k "check:$1:$2" '.events[$k].status // "none"' "$T/db.json"; }
evf()   { jq -r --arg k "check:$1:$2" --arg f "$3" '.events[$k][$f] // "none"' "$T/db.json"; }
fld()   { jq -r --argjson i "$1" --arg f "$2" '.initiatives[] | select(.id == $i) | .[$f] // "null"' "$T/db.json"; }

# ── R1: the default USD is 0.60, from the registry to agent-call ────────────
eq "R1 registry default" "$(jq '.knobs[] | select(.env=="ARCHIE_LLM_MAX_USD") | .default' "$DIR/catalog/lanes.d/archie.json")" 0.6
reset "$(row 1 "$DUE")"
at "$NOW"
eq "R1 one call" "$(calls)" 1
eq "R1 AGENT_CALL_BUDGET_USD_ARCHIE with the knob unset" "$(cut -d'|' -f4 "$T/agentcalls")" 0.60
eq "R1 a success still sends" "$(ev 1 "$DUE")" sent

# ── R2: a budget stop on attempt 1 stays open, with a 60m retry_after ───────
reset "$(row 2 "$DUE")"; printf '%s' "$BUDGET" > "$T/ac.budget"
at "$NOW"
eq "R2 one call" "$(calls)" 1
eq "R2 event model_failed" "$(ev 2 "$DUE")" model_failed
eq "R2 attempts 1" "$(evf 2 "$DUE" attempts)" 1
eq "R2 body" "$(evf 2 "$DUE" body)" "budget_stop $(isoat $((NOW + 3600))) usd=0.60 cost=0.43"
eq "R2 not advanced" "$(fld 2 next_check_at)" "$DUE"
eq "R2 no beat" "$(beats)" 0

# ── R3: no call inside the backoff, exactly one at +60m ─────────────────────
: > "$T/reqlog"
at $((NOW + 900))
eq "R3 +15m: no call" "$(calls)" 1
eq "R3 +15m: no POST" "$(posts)" 0
check "R3 +15m: logged backing off ($(tail -2 "$H/logs/archie.log"))" \
  'grep -qF "initiative 2: backing off after a budget stop until $(isoat $((NOW + 3600))); no call" "$H/logs/archie.log"'
at $((NOW + 3600))
eq "R3 +60m: exactly one more call (within the hour, not a cadence)" "$(calls)" 2
eq "R3 +60m: attempts 2" "$(evf 2 "$DUE" attempts)" 2
eq "R3 +60m: the body moved to the next backoff" "$(evf 2 "$DUE" body)" "budget_stop $(isoat $((NOW + 7200))) usd=0.60 cost=0.43"

# ── R4: ONE knob alert over repeated stops ──────────────────────────────────
at $((NOW + 7200))
eq "R4 three calls" "$(calls)" 3
eq "R4 exactly one ALERTS line" "$(alerts)" 1
check "R4 the line names the cap, the cost and the settings row ($(cat "$T/alerts.log" 2>/dev/null))" \
  'grep -qF "ARCHIE_LLM_MAX_USD=0.60" "$T/alerts.log" && grep -qF "cost 0.43" "$T/alerts.log" && grep -qF "lane.archie.archie_llm_max_usd" "$T/alerts.log"'
check "R4 the line names the slot" 'grep -qF "archie: initiative 2 check $DUE hit its dollar cap" "$T/alerts.log"'

# ── R5: ARCHIE_RETRY_MAX=3 closes after 3 attempts with one close line ──────
reset "$(row 5 "$DUE")"; printf '%s' "$BUDGET" > "$T/ac.budget"
for k in 0 1 2; do at $((NOW + k * 3600)) ARCHIE_RETRY_MAX=3; done
eq "R5 three calls" "$(calls)" 3
eq "R5 attempts 3" "$(evf 5 "$DUE" attempts)" 3
eq "R5 status model_failed" "$(ev 5 "$DUE")" model_failed
eq "R5 advanced a cadence from the closing tick" "$(fld 5 next_check_at)" "$(isoat $((NOW + 7200 + 168 * 3600)))"
eq "R5 ALERTS: the knob line and the close" "$(alerts)" 2
eq "R5 exactly one close line" "$(grep -c 'hit its dollar cap 3 times (ARCHIE_LLM_MAX_USD=0.60); skipped to the next cadence' "$T/alerts.log")" 1
at $((NOW + 3 * 3600)) ARCHIE_RETRY_MAX=3
eq "R5 a fourth tick makes no call" "$(calls)" 3
# A lowered knob below the attempts a slot holds closes it with no call.
reset "$(row 15 "$DUE")"; printf '%s' "$BUDGET" > "$T/ac.budget"
at "$NOW"; at $((NOW + 3600)) ARCHIE_RETRY_MAX=1
eq "R5 lowered RETRY_MAX: no second call" "$(calls)" 1
check "R5 lowered RETRY_MAX: closed, advanced" '[ "$(fld 15 next_check_at)" = "$(isoat $((NOW + 3600 + 168 * 3600)))" ] && grep -qF "hit its dollar cap 1 times" "$T/alerts.log"'

# ── R6: a budget stop, then a success on the retry ──────────────────────────
reset "$(row 6 "$DUE")"; printf '%s' "$BUDGET" > "$T/ac.budget"
at "$NOW"
rm -f "$T/ac.budget"
at $((NOW + 3600))
eq "R6 sent" "$(ev 6 "$DUE")" sent
eq "R6 advanced a cadence" "$(fld 6 next_check_at)" "$(isoat $((NOW + 3600 + 168 * 3600)))"
eq "R6 one beat" "$(beats)" 1

# ── R7: an ordinary failure still closes at ARCHIE_MAX_ATTEMPTS, no backoff ─
reset "$(row 7 "$DUE")"; echo 1 > "$T/ac.rc"
at "$NOW"
check "R7 first failure: attempts 1, no backoff body" '[ "$(evf 7 "$DUE" attempts)" = 1 ] && [ "$(evf 7 "$DUE" body)" = attempt ]'
at $((NOW + 900))
eq "R7 retried 15m later (no backoff)" "$(calls)" 2
eq "R7 closed at MAX_ATTEMPTS=2" "$(fld 7 next_check_at)" "$(isoat $((NOW + 900 + 168 * 3600)))"
eq "R7 one ALERTS line" "$(alerts)" 1
check "R7 the ordinary close line" 'grep -qF "archie: initiative 7 check $DUE failed 2 times" "$T/alerts.log"'

# ── R8: no route, USD=0 and rc 77 count no attempt ──────────────────────────
reset "$(row 8 "$DUE")"; : > "$T/noroute"
at "$NOW"
check "R8 no route: no call, no attempt, still due" '[ "$(calls)" = 0 ] && [ "$(evf 8 "$DUE" attempts)" = none ] && [ "$(fld 8 next_check_at)" = "$DUE" ]'
rm -f "$T/noroute"; at $((NOW + 900))
eq "R8 no route: retried next tick" "$(calls)" 1
reset "$(row 9 "$DUE")"
at "$NOW" ARCHIE_LLM_MAX_USD=0
check "R8 USD=0: no call, no attempt, still due" '[ "$(calls)" = 0 ] && [ "$(evf 9 "$DUE" attempts)" = none ] && [ "$(fld 9 next_check_at)" = "$DUE" ]'
at $((NOW + 900))
eq "R8 USD=0: retried next tick" "$(calls)" 1
reset "$(row 10 "$DUE")"; echo 77 > "$T/ac.rc"
at "$NOW"
check "R8 rc 77: attempt handed back, still due" '[ "$(evf 10 "$DUE" attempts)" = 0 ] && [ "$(fld 10 next_check_at)" = "$DUE" ]'
rm -f "$T/ac.rc"; at $((NOW + 900))
check "R8 rc 77: retried next tick and sent" '[ "$(calls)" = 2 ] && [ "$(ev 10 "$DUE")" = sent ]'

# ── R9: unreadable re-checks within 24h, one event per day ──────────────────
# BH-4765: R9, R10 and R12 pin the already-told path, so each seeds the told
# marker (tests/archie-unreadable-told.bh-4765-test.sh pins the first telling).
told() { mkdir -p "$H/state/archie/unreadable-told" && : > "$H/state/archie/unreadable-told/$1"; }
reset "$(row 11 "$DUE" "$UNREAD")"; told 11
at "$NOW"
eq "R9 event unreadable" "$(ev 11 "$DUE")" unreadable
eq "R9 next check NOW+24h, not +168h" "$(fld 11 next_check_at)" "$(iso_plus_h 24)"
eq "R9 no call" "$(calls)" 0
at $((NOW + 24 * 3600))
eq "R9 the next day's slot is its own event" "$(ev 11 "$(iso_plus_h 24)")" unreadable
eq "R9 and it advances another 24h" "$(fld 11 next_check_at)" "$(iso_plus_h 48)"

# ── R10: unreadable at a 6h cadence re-checks in 6h ─────────────────────────
reset "$(row 12 "$DUE" "$UNREAD" 6)"; told 12
at "$NOW"
eq "R10 6h cadence: NOW+6h" "$(fld 12 next_check_at)" "$(iso_plus_h 6)"

# ── R11: the unreadable repair arm uses the same rule ───────────────────────
reset "$(row 13 "$DUE" "$UNREAD")"
jq --arg k "check:13:$DUE" '.events[$k] = {status: "unreadable", value: null, body: null, attempts: 0}' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
at "$NOW"
eq "R11 repair arm: +24h, not +168h" "$(fld 13 next_check_at)" "$(iso_plus_h 24)"

# ── R12: knob junk is one warn line and the default ─────────────────────────
reset "$(row 14 "$DUE")" "$(row 16 "$DUE" "$UNREAD")"; printf '%s' "$BUDGET" > "$T/ac.budget"; told 16
at "$NOW" ARCHIE_RETRY_MAX=0 ARCHIE_RETRY_BACKOFF_MIN=5 ARCHIE_UNREADABLE_RECHECK_H=0
for k in ARCHIE_RETRY_MAX=0 ARCHIE_RETRY_BACKOFF_MIN=5 ARCHIE_UNREADABLE_RECHECK_H=0; do
  eq "R12 one warn line for $k" "$(grep -c "warn: $k is outside" "$H/logs/archie.log")" 1
done
eq "R12 RETRY_MAX default 6: the first stop stays open" "$(fld 14 next_check_at)" "$DUE"
eq "R12 BACKOFF default 60m" "$(evf 14 "$DUE" body)" "budget_stop $(isoat $((NOW + 3600))) usd=0.60 cost=0.43"
eq "R12 RECHECK default 24h" "$(fld 16 next_check_at)" "$(iso_plus_h 24)"

# ── R13: agent-call's sidecars do not leak in TMPDIR ────────────────────────
archie_tmp() { find "$T/tmp" -maxdepth 1 -name 'archie-*' | wc -l | tr -d ' '; }
check "R13 after a budget stop: no archie-* files ($(ls "$T/tmp"))" '[ "$(archie_tmp)" = 0 ]'
reset "$(row 17 "$DUE")"
at "$NOW"
check "R13 after a success: no archie-* files ($(ls "$T/tmp"))" '[ "$(calls)" = 1 ] && [ "$(archie_tmp)" = 0 ]'

check "no network ($(cat "$T/net.log" 2>/dev/null))" '[ ! -s "$T/net.log" ]'
echo "archie-check-retry: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
