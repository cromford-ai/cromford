#!/bin/bash
# tests/archie-unreadable-told.bh-4765-test.sh — BH-4765 (BH-4760.1): an
# unreadable metric on a metric-backed initiative reaches the operator ONCE per
# unreadable stretch, driven through the SHIPPED bin/archie.sh tick.
#
#   U1  no marker: one told check (call, prompt flag true, beat
#       "Metric: unreadable (<rule>)"), `sent` at +24h, marker written
#   U2  marker present: event `unreadable`, no call, no beat, +24h
#   U3  a readable metric clears the marker; unreadable again tells again
#   U4  a blank or no-action answer gets the fallback sentence, class ticket-file
#   U5  ARCHIE_LLM_MAX_USD=0 / no stage.archie route: no call, no attempt,
#       the fallback beat, marker written
#   U6  a failed beat writes no marker; the composed body is resent with no
#       second call, then the marker
#   U7  metric: none is not told (prompt flag false, no marker)
#   U8  a mutant with the marker check removed tells again (U2 goes red)
#
# The fixture is tests/archie-check-retry.bh-4609-test.sh's (jq model of the
# worker over $T/db.json); the agent-call stub also keeps the last prompt.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-unreadable-told.bh-4765-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "archie-unreadable-told: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

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
printf '%s|%s|%s\n' "$*" "${AGENT_CALL_LANE:-}" "${AGENT_CALL_FP:-}" >> "$FXT/agentcalls"
cp "${6#@}" "$FXT/prompt.last" 2>/dev/null
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
cat > "$H/bin/archie-tg-send.sh" <<'SH'
#!/bin/bash
rc=$(cat "$FXT/beat.rc" 2>/dev/null || echo 0)
[ "$rc" = 0 ] || exit "$rc"
jq -nc --arg a "$1" --arg l "$2" '{akey: $a, line: $l}' >> "$FXT/beats.jsonl"
SH
chmod +x "$H/bin/agent-call.sh" "$H/bin/beat.sh" "$H/bin/archie-tg-send.sh" "$H/bin/alert-line.sh" "$H/bin/lane-alert.sh"
for c in curl gh; do
  printf '#!/bin/bash\nprintf "%%s %%s\\n" %s "$*" >> "$FXT/net.log"\nexit 7\n' "$c" > "$T/fakebin/$c"
  chmod +x "$T/fakebin/$c"
done

# The worker, the bh-4609 suite's jq model over $T/db.json.
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
csv_unreadable() {
  cat > "$H/logs/rework.csv" <<'CSV'
week,project,merged,reworked,rate,decomposed_merged,decomposed_reworked,decomposed_rate,sibling_reworked,source
2026-W40,project-3,9,1,11.1,0,0,-,0,x
CSV
}
csv_readable() {
  cat > "$H/logs/rework.csv" <<'CSV'
week,project,merged,reworked,rate,decomposed_merged,decomposed_reworked,decomposed_rate,sibling_reworked,source
2026-W40,project-3,9,1,11.1,4,0,9.0,0,x
CSV
}
METRIC='csv:logs/rework.csv#decomposed_rate@project=project-3'
TOLD="$H/state/archie/unreadable-told"
ANSWER=$'CLASS: ticket-file\nThe project-3 decomposed_rate column is blank, so file a ticket to fix the rework CSV.'

# row <id> <next_check_at> [metric] [rule]
row() {
  jq -nc --argjson i "$1" --arg n "$2" --arg m "${3:-$METRIC}" --arg r "${4:-> 999}" \
    '{id: $i, slug: "init-\($i)", goal: "project-3 rework under 10%", metric_query: $m, cadence_hours: 168,
      escalation_rule: $r, status: "active", next_check_at: $n,
      links: ["https://github.com/example-org/cromford/issues/4765"], last_value: null, last_check_status: null}'
}
reset() {
  local p
  for p in reqlog beats.jsonl agentcalls alerts.log beat.rc noroute net.log out rc prompt.last; do
    scratch_rm "$T/$p" || exit 1
  done
  scratch_rm "$H/locks" || exit 1; scratch_rm "$H/logs/archie.log" || exit 1
  scratch_rm "$H/state" || exit 1
  scratch_rm "$T/tmp" || exit 1; mkdir -p "$T/tmp"
  csv_unreadable
  printf '%s\n' "$ANSWER" > "$T/ac.text"
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
lastbeat() { tail -1 "$T/beats.jsonl" 2>/dev/null | jq -r .line; }
ev()    { jq -r --arg k "check:$1:$2" '.events[$k].status // "none"' "$T/db.json"; }
evf()   { jq -r --arg k "check:$1:$2" --arg f "$3" '.events[$k][$f] // "none"' "$T/db.json"; }
fld()   { jq -r --argjson i "$1" --arg f "$2" '.initiatives[] | select(.id == $i) | .[$f] // "null"' "$T/db.json"; }
attempts_written() { grep -c '"status":"model_failed"' "$T/reqlog"; }
dclass() { grep '^POST /api/archie/decisions ' "$T/reqlog" | tail -1 | sed 's/^POST \/api\/archie\/decisions //' | jq -r .class; }

# ── U1: unreadable, no marker: one told check ───────────────────────────────
reset "$(row 1 "$DUE")"
at "$NOW"
eq "U1 tick rc" "$(cat "$T/rc")" 0
eq "U1 one call" "$(calls)" 1
check "U1 prompt carries metric_unreadable true" 'grep -qF "\"metric_unreadable\":true" "$T/prompt.last"'
eq "U1 one beat" "$(beats)" 1
check "U1 beat reads Metric: unreadable (> 999) ($(lastbeat))" 'lastbeat | grep -qF "Metric: unreadable (> 999)"'
check "U1 beat carries the answer" 'lastbeat | grep -qF "file a ticket to fix the rework CSV"'
eq "U1 event sent" "$(ev 1 "$DUE")" sent
eq "U1 next check NOW+24h" "$(fld 1 next_check_at)" "$(iso_plus_h 24)"
check "U1 marker written" '[ -f "$TOLD/1" ]'
eq "U1 last_value stays null" "$(fld 1 last_value)" null
eq "U1 event value null" "$(evf 1 "$DUE" value)" none

# ── U2: the next day, marker present: today's quiet path ────────────────────
at $((NOW + 24 * 3600))
eq "U2 event unreadable" "$(ev 1 "$(iso_plus_h 24)")" unreadable
eq "U2 no second call" "$(calls)" 1
eq "U2 no second beat" "$(beats)" 1
eq "U2 next check NOW+48h" "$(fld 1 next_check_at)" "$(iso_plus_h 48)"
check "U2 marker still there" '[ -f "$TOLD/1" ]'

# ── U3: readable clears the marker; unreadable again tells again ────────────
csv_readable
at $((NOW + 48 * 3600))
check "U3 readable: marker removed" '[ ! -e "$TOLD/1" ]'
eq "U3 readable, rule > 999 not met: silent" "$(ev 1 "$(iso_plus_h 48)")" silent
eq "U3 readable: no call" "$(calls)" 1
csv_unreadable
at $(((48 + 168) * 3600 + NOW))
eq "U3 unreadable again: a second call" "$(calls)" 2
eq "U3 unreadable again: a second beat" "$(beats)" 2
check "U3 unreadable again: marker back" '[ -f "$TOLD/1" ]'
eq "U3 unreadable again: event sent" "$(ev 1 "$(iso_plus_h $((48 + 168)))")" sent

# ── U4: a blank answer gets the fallback, class ticket-file ─────────────────
reset "$(row 4 "$DUE")"
printf 'CLASS: watch-continue\n\n' > "$T/ac.text"
at "$NOW"
eq "U4 one call" "$(calls)" 1
eq "U4 one beat" "$(beats)" 1
check "U4 fallback sentence ($(lastbeat))" 'lastbeat | grep -qF "I can'"'"'t read the metric for I4 ($METRIC)"'
eq "U4 decision class ticket-file" "$(dclass)" ticket-file
eq "U4 event sent" "$(ev 4 "$DUE")" sent
check "U4 marker written" '[ -f "$TOLD/4" ]'
# A no-action sentence is no usable answer either: the fallback, not `empty`.
reset "$(row 14 "$DUE")"
printf "CLASS: watch-continue\nThere's nothing for you to do here, I'll keep watching.\n" > "$T/ac.text"
at "$NOW"
check "U4 no-action answer: fallback beat ($(lastbeat))" 'lastbeat | grep -qF "I can'"'"'t read the metric for I14"'
eq "U4 no-action answer: decision class ticket-file" "$(dclass)" ticket-file
check "U4 no-action answer: sent, marker" '[ "$(ev 14 "$DUE")" = sent ] && [ -f "$TOLD/14" ]'

# ── U5: no call when calls are off or unrouted, the fallback still tells ────
reset "$(row 5 "$DUE")"
at "$NOW" ARCHIE_LLM_MAX_USD=0
eq "U5a USD=0: no call" "$(calls)" 0
eq "U5a USD=0: no attempt written" "$(attempts_written)" 0
eq "U5a USD=0: one beat" "$(beats)" 1
check "U5a USD=0: fallback sentence ($(lastbeat))" 'lastbeat | grep -qF "I can'"'"'t read the metric for I5"'
eq "U5a USD=0: decision class ticket-file" "$(dclass)" ticket-file
eq "U5a USD=0: event sent" "$(ev 5 "$DUE")" sent
eq "U5a USD=0: next check NOW+24h" "$(fld 5 next_check_at)" "$(iso_plus_h 24)"
check "U5a USD=0: marker written" '[ -f "$TOLD/5" ]'
reset "$(row 6 "$DUE")"; : > "$T/noroute"
at "$NOW"
eq "U5b no route: no call" "$(calls)" 0
eq "U5b no route: no attempt written" "$(attempts_written)" 0
eq "U5b no route: one beat" "$(beats)" 1
check "U5b no route: fallback sentence ($(lastbeat))" 'lastbeat | grep -qF "I can'"'"'t read the metric for I6"'
eq "U5b no route: event sent" "$(ev 6 "$DUE")" sent
check "U5b no route: marker written" '[ -f "$TOLD/6" ]'

# ── U6: a failed beat writes no marker; the resend needs no second call ─────
reset "$(row 7 "$DUE")"; echo 1 > "$T/beat.rc"
at "$NOW"
eq "U6 one call" "$(calls)" 1
eq "U6 nothing delivered" "$(beats)" 0
eq "U6 event composed" "$(ev 7 "$DUE")" composed
check "U6 no marker after a failed beat" '[ ! -e "$TOLD/7" ]'
eq "U6 not advanced" "$(fld 7 next_check_at)" "$DUE"
STORED=$(evf 7 "$DUE" body)
rm -f "$T/beat.rc"
at "$NOW"
eq "U6 resend: no second call" "$(calls)" 1
eq "U6 resend: one beat" "$(beats)" 1
eq "U6 resend: the stored body" "$(lastbeat)" "$STORED"
eq "U6 resend: event sent" "$(ev 7 "$DUE")" sent
eq "U6 resend: next check NOW+24h" "$(fld 7 next_check_at)" "$(iso_plus_h 24)"
check "U6 resend: marker written" '[ -f "$TOLD/7" ]'

# ── U7: metric: none is not told ────────────────────────────────────────────
reset "$(row 8 "$DUE" none always)"
printf 'CLASS: watch-cadence\nCheck this weekly instead of daily.\n' > "$T/ac.text"
at "$NOW"
eq "U7 one call" "$(calls)" 1
check "U7 prompt carries metric_unreadable false" 'grep -qF "\"metric_unreadable\":false" "$T/prompt.last"'
check "U7 beat reads Metric: not measured (always) ($(lastbeat))" 'lastbeat | grep -qF "Metric: not measured (always)"'
check "U7 no marker" '[ ! -e "$TOLD/8" ]'
eq "U7 next check a full cadence" "$(fld 8 next_check_at)" "$(iso_plus_h 168)"

# ── U8: mutant, the marker check removed: U2's scenario tells again ─────────
cnt=$(grep -c 'elif \[ -e "\$TOLD_DIR/\$id" \]; then' "$DIR/bin/archie.sh")
eq "U8 the marker check is in bin/archie.sh once" "$cnt" 1
rm -f "$H/bin/archie.sh"
sed 's/elif \[ -e "\$TOLD_DIR\/\$id" \]; then/elif false; then/' "$DIR/bin/archie.sh" > "$H/bin/archie.sh"
check "U8 the mutant differs" '! cmp -s "$DIR/bin/archie.sh" "$H/bin/archie.sh"'
reset "$(row 9 "$DUE")"
mkdir -p "$TOLD" && : > "$TOLD/9"
at "$NOW"
check "U8 mutant: the told path runs again (a call and a beat)" '[ "$(calls)" = 1 ] && [ "$(beats)" = 1 ]'
rm -f "$H/bin/archie.sh"; ln -s "$DIR/bin/archie.sh" "$H/bin/archie.sh"
reset "$(row 9 "$DUE")"
mkdir -p "$TOLD" && : > "$TOLD/9"
at "$NOW"
check "U8 shipped: the marker holds (no call, no beat)" '[ "$(calls)" = 0 ] && [ "$(beats)" = 0 ] && [ "$(ev 9 "$DUE")" = unreadable ]'

check "no network ($(cat "$T/net.log" 2>/dev/null))" '[ ! -s "$T/net.log" ]'
echo "archie-unreadable-told: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
