#!/bin/bash
# tests/ph-retract-closes-row.bh-4054-test.sh — a pipeline-health retraction
# closes the console row its alert opened (BH-4054), and a skipped check never
# reads as cleared.
#
# Extracted VERBATIM from bin/pipeline-health.sh by their markers: the
# `# >>> alert emit cap` block, the real alert(), the `# >>> stalepr detector`
# block and the `# ── Retraction epilogue`, with the real RETRACT_NS line. They
# run against the REAL bin/alert-line.sh, bin/beat.sh and bin/lib/alert-state.sh.
# The only fakes are gh (a REST stub serving $T/prs-r.json; $T/listfail fails the
# list), curl (records each console POST body to sent.jsonl) and
# bin/jobs-client.sh (alert_note / alert_resolve against a tiny id ledger, the
# worker's contract: resolve answers 1 only for an id that is open).
#
#   R1  open, then a clean pass -> one resolve POST for alert:ph-stalepr_ts,
#       and no POST carries any other akey
#   R2  the resolve writes no jobs row: no alert_note on the clean pass, no
#       pipeline-health-resolved-* or auto-* state file
#   R2b a second clean pass sends nothing (resolve exactly once)
#   R3  a gh_budget_low pass emits no resolve, keeps stalepr:ts in
#       health-active.txt and keeps its DEDUP stamp
#   R3b the next healthy pass inside the TTL does not re-alert
#   R4  a failed PR list (skipped repo) carries the key the same way
#   R5  ALERTS.log and pipeline-health.log still carry the RESOLVED audit line
#   R6  the unstructured RESOLVED text copy opens nothing
#   R6b lines that merely look like it are still noted
#   R7  a retraction of a never-opened id is silent
#
# Run from anywhere: tests/ph-retract-closes-row.bh-4054-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

PH="$DIR/bin/pipeline-health.sh"
awk '/^# >>> alert emit cap/{f=1;next} /^# <<< alert emit cap/{exit} f' "$PH" > "$T/p0.sh"
awk '/^alert\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$PH" > "$T/p1.sh"
awk '/^# >>> stalepr detector/{f=1;next} /^# <<< stalepr detector/{exit} f' "$PH" > "$T/p2.sh"
sed -n '/^# ── Retraction epilogue/,/^rm -f "\$FIRED"$/p' "$PH" > "$T/p3.sh"
grep -m1 '^RETRACT_NS=' "$PH" > "$T/pns.sh"
[ -s "$T/p0.sh" ] && [ -s "$T/p1.sh" ] && [ -s "$T/p2.sh" ] && [ -s "$T/p3.sh" ] && [ -s "$T/pns.sh" ] \
  && ok || bad "could not extract the emit cap / alert() / stalepr / epilogue / RETRACT_NS"
BLK="$T/block.sh"
cat "$T/pns.sh" "$T/p0.sh" "$T/p1.sh" "$T/p2.sh" "$T/p3.sh" > "$BLK"
bash -n "$T/block.sh" && ok || bad "the extracted block is not valid bash"

mktree() { # mktree <dir>
  local d="$1" s
  mkdir -p "$d/bin/lib" "$d/logs" "$d/state" "$d/flags" "$d/fakebin" "$d/env"
  for s in alert-line.sh beat.sh alert_family.py project-of.sh fleet-conf.sh box-for.sh; do
    ln -sf "$DIR/bin/$s" "$d/bin/$s"
  done
  for s in alert-state.sh conf-row.sh env-path.sh gh-repo-token.sh gh-budget.sh gh-pr-list.sh gh-rest.sh gh-rest-var.sh; do
    ln -sf "$DIR/bin/lib/$s" "$d/bin/lib/$s"
  done
  # The worker's contract, in miniature: note opens or counts an id; resolve
  # closes an open id and answers how many rows it closed.
  cat > "$d/bin/jobs-client.sh" <<'EOF'
alert_note() {
  printf '%s\n' "$1" >> "$_AS_H/note.log"
  if grep -qxF "$1" "$_AS_H/open.ids" 2>/dev/null; then echo "suppress 2"
  else printf '%s\n' "$1" >> "$_AS_H/open.ids"; echo "fire 1"; fi
}
alert_resolve() {
  printf '%s\n' "$1" >> "$_AS_H/resolve.log"
  if grep -qxF "$1" "$_AS_H/open.ids" 2>/dev/null; then
    grep -vxF "$1" "$_AS_H/open.ids" > "$_AS_H/open.ids.tmp"; mv -f "$_AS_H/open.ids.tmp" "$_AS_H/open.ids"
    echo 1
  else echo 0; fi
}
# BH-7802: alert_state_resolve reads through alert_resolve_rows. This miniature
# answers the shape of a worker with no `rows` key, so count and severity still
# come from the state file, as they did before.
alert_resolve_rows() {
  local n; n=$(alert_resolve "$1") || return 1
  printf '#norows\nresolved %s\n' "$n"
}
EOF
  cat > "$d/fakebin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  "api repos/"*" -q .id") exit 0 ;;
  *"repos/o/"*"/pulls?state="*)
    [ -f "$T/listfail" ] && exit 1
    printf 'HTTP/2.0 200\r\n\r\n'; cat "$T/prs-r.json" 2>/dev/null || echo '[]' ;;
  *"api rate_limit"*)
    now=$(date +%s)
    printf '{"resources":{"core":{"remaining":%s,"limit":5000,"reset":%s},"graphql":{"remaining":5000,"limit":5000,"reset":%s}}}' "${GH_BUDGET_CORE_REMAINING:-4000}" "$((now+3600))" "$((now+3600))" ;;
  *) exit 1 ;;
esac
EOF
  cat > "$d/fakebin/curl" <<'EOF'
#!/bin/bash
prev=""
for a in "$@"; do
  [ "$prev" = "-d" ] && { printf '%s\n' "$a" >> "$T/sent.jsonl"; break; }
  prev="$a"
done
printf '200'
EOF
  chmod +x "$d/fakebin/gh" "$d/fakebin/curl"
  printf 'ts\to/r\n' > "$d/fleet.conf"
  printf 'CONSOLE_URL=https://console.invalid\nHARNESS_SECRET=testsecret\n' > "$d/env/global.env"
  touch "$d/flags/alerts-db" "$d/flags/remediation-disabled"
  : > "$d/alerts.conf"
  echo '{}' > "$d/state/health-alerted.json"
  : > "$d/state/health-active.txt"
}
pr() { # pr <n> — one REST pull, opened long before the 12h cutoff
  printf '{"number":%s,"created_at":"2026-09-10T00:00:00Z","updated_at":"2026-09-10T00:00:00Z","title":"TK-%s","draft":false,"state":"open","merged_at":null,"closed_at":null,"body":"","labels":[],"html_url":"https://github.com/o/r/pull/%s","head":{"ref":"b","sha":"s%s"},"base":{"ref":"main"},"user":{"login":"operator","type":"User"}}' "$1" "$1" "$1" "$1"
}
stale() { printf '[%s]\n' "$(pr 50)" > "$1/prs-r.json"; }
clean() { echo '[]' > "$1/prs-r.json"; }
tick() { # tick <dir> <now> [env...] — one pipeline-health pass of the blocks
  local d="$1" now="$2"; shift 2
  ( export PATH="$d/fakebin:$PATH" HARNESS="$d" T="$d" GH_BUDGET_TTL_S=0 GH_BUDGET_CORE_REMAINING=4000 \
      ALERTS_CONF="$d/alerts.conf" FLEET_CONF="$d/fleet.conf" LANE_GATE_DISABLE=1 HARNESS_ENV_DIR="$d/env"
    unset GH_TOKEN
    env "$@" bash -c '
      set -uo pipefail
      H="$T"; NOW='"$now"'; PROJECTS="ts"; DEDUP="$T/state/health-alerted.json"
      FIRED="$T/state/health-fired.$$"; : > "$FIRED"
      ACTIVE="$T/state/health-active.txt"; touch "$ACTIVE"
      STAMP() { echo "2026-10-03 10:00:00Z"; }
      . "$T/bin/lib/gh-repo-token.sh"
      . "$T/bin/lib/gh-pr-list.sh"
      . "$T/bin/lib/gh-budget.sh"
      . "$0"' "$BLK" >/dev/null 2>"$d/err.txt" )
}
posts()   { [ -s "$1/sent.jsonl" ] && grep -c . "$1/sent.jsonl" || echo 0; }
resolves() { jq -c 'select(.resolved==true)' "$1/sent.jsonl" 2>/dev/null | grep -c . || true; }
notes()   { [ -s "$1/note.log" ] && grep -c . "$1/note.log" || echo 0; }
beatd()   { ( export PATH="$1/fakebin:$PATH" HARNESS="$1" T="$1" ALERTS_CONF="$1/alerts.conf" \
                LANE_GATE_DISABLE=1 HARNESS_ENV_DIR="$1/env"; "$DIR/bin/beat.sh" "$2" ) >/dev/null 2>&1; }

NOW=$(date +%s)
echo "--- R1: a clean pass resolves the open row, on its own akey"
D="$T/r1"; mktree "$D"
stale "$D"; tick "$D" "$NOW"
[ "$(posts "$D")" = 1 ] && ok || bad "R1: tick 1 want 1 open POST, got $(posts "$D"): $(cat "$D/sent.jsonl" 2>/dev/null) err=$(cat "$D/err.txt")"
[ "$(jq -r '.akey' "$D/sent.jsonl" 2>/dev/null | head -1)" = alert:ph-stalepr_ts ] \
  && ok || bad "R1: the open POST akey is $(jq -r '.akey' "$D/sent.jsonl" 2>/dev/null | head -1)"
grep -qxF stalepr:ts "$D/state/health-active.txt" && ok || bad "R1: tick 1 did not record stalepr:ts as active"
N1=$(notes "$D")
clean "$D"; tick "$D" "$((NOW + 60))"
[ "$(posts "$D")" = 2 ] && ok || bad "R1: tick 2 want exactly 1 more POST, total $(posts "$D"): $(cat "$D/sent.jsonl" 2>/dev/null)"
[ "$(resolves "$D")" = 1 ] && ok || bad "R1: want 1 resolved:true POST, got $(resolves "$D")"
[ "$(jq -r 'select(.resolved==true)|.akey' "$D/sent.jsonl" 2>/dev/null)" = alert:ph-stalepr_ts ] \
  && ok || bad "R1: the resolve POST akey is '$(jq -r 'select(.resolved==true)|.akey' "$D/sent.jsonl" 2>/dev/null)', want alert:ph-stalepr_ts"
[ "$(jq -r '.akey' "$D/sent.jsonl" 2>/dev/null | sort -u)" = alert:ph-stalepr_ts ] \
  && ok || bad "R1: a POST carried another akey: $(jq -r '.akey' "$D/sent.jsonl" | sort -u | tr '\n' ' ')"
[ "$(jq -r 'select(.resolved==true)|.alertstate' "$D/sent.jsonl" 2>/dev/null)" = resolve ] \
  && ok || bad "R1: the resolve POST does not carry alertstate=resolve"
grep -q 'resolve id=ph-stalepr_ts ' "$D/logs/alerts-state.log" 2>/dev/null \
  && ok || bad "R1: alerts-state.log has no 'resolve id=ph-stalepr_ts': $(cat "$D/logs/alerts-state.log" 2>/dev/null)"
grep -qxF stalepr:ts "$D/state/health-active.txt" && bad "R1: stalepr:ts still active after a clean pass" || ok
[ ! -s "$D/err.txt" ] && ok || bad "R1: stderr: $(cat "$D/err.txt")"

echo "--- R2: the resolve writes no jobs row and no state file for a new id"
[ "$(notes "$D")" = "$N1" ] && ok || bad "R2: the clean pass called alert_note: $(tail -n +$((N1 + 1)) "$D/note.log" | tr '\n' ' ')"
[ "$(sort -u "$D/note.log" 2>/dev/null)" = ph-stalepr_ts ] \
  && ok || bad "R2: alert_note ids: $(sort -u "$D/note.log" 2>/dev/null | tr '\n' ' ')"
grep -qxF ph-stalepr_ts "$D/resolve.log" 2>/dev/null && ok || bad "R2: alert_resolve was never asked for ph-stalepr_ts"
grep -qE '^(pipeline-health-resolved-|auto-).*\.json$' <<<"$(ls "$D/state/alerts/" 2>/dev/null)" \
  && bad "R2: a state file for a new id: $(ls "$D/state/alerts/" | tr '\n' ' ')" || ok
[ "$(jq -r '.resolved_at // 0' "$D/state/alerts/ph-stalepr_ts.json" 2>/dev/null)" != 0 ] \
  && ok || bad "R2: the ph-stalepr_ts state file was not marked resolved"

echo "--- R2b: a second clean pass sends nothing"
P2=$(posts "$D")
tick "$D" "$((NOW + 120))"
[ "$(posts "$D")" = "$P2" ] && ok || bad "R2b: a second clean pass POSTed: $(tail -n +$((P2 + 1)) "$D/sent.jsonl")"

echo "--- R5: the RESOLVED audit lines are still written"
grep -qF 'RESOLVED stalepr:ts — condition no longer holds' "$D/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "R5: ALERTS.log has no RESOLVED line: $(cat "$D/logs/ALERTS.log" 2>/dev/null)"
grep -qF 'RESOLVED stalepr:ts — condition no longer holds' "$D/logs/pipeline-health.log" 2>/dev/null \
  && ok || bad "R5: pipeline-health.log has no RESOLVED line"

echo "--- R3: a budget-low pass carries the key, retracts nothing"
D="$T/r3"; mktree "$D"
stale "$D"; tick "$D" "$NOW"
clean "$D"; tick "$D" "$((NOW + 60))" GH_BUDGET_CORE_REMAINING=100
[ "$(resolves "$D")" = 0 ] && ok || bad "R3: a budget-low pass sent a resolve: $(cat "$D/sent.jsonl")"
grep -qxF stalepr:ts "$D/state/health-active.txt" \
  && ok || bad "R3: stalepr:ts dropped from health-active.txt: $(cat "$D/state/health-active.txt")"
[ "$(jq -r '.["stalepr:ts"] // 0' "$D/state/health-alerted.json")" = "$NOW" ] \
  && ok || bad "R3: the DEDUP stamp was not kept: $(cat "$D/state/health-alerted.json")"
grep -qF 'RESOLVED stalepr:ts' "$D/logs/ALERTS.log" 2>/dev/null && bad "R3: a RESOLVED line was written on a skipped pass" || ok
[ ! -s "$D/err.txt" ] && ok || bad "R3: stderr: $(cat "$D/err.txt")"

echo "--- R3b: the next healthy pass inside the TTL does not re-alert"
P3=$(posts "$D")
stale "$D"; tick "$D" "$((NOW + 120))"
[ "$(posts "$D")" = "$P3" ] && ok || bad "R3b: re-alerted after a skipped pass: $(tail -n +$((P3 + 1)) "$D/sent.jsonl")"

echo "--- R4: a failed PR list carries the key"
D="$T/r4"; mktree "$D"
stale "$D"; tick "$D" "$NOW"
touch "$D/listfail"; tick "$D" "$((NOW + 60))"
[ "$(resolves "$D")" = 0 ] && ok || bad "R4: a failed list sent a resolve: $(cat "$D/sent.jsonl")"
grep -qxF stalepr:ts "$D/state/health-active.txt" \
  && ok || bad "R4: stalepr:ts dropped from health-active.txt: $(cat "$D/state/health-active.txt")"
# The carry is exact-line: a sibling key with a longer name is not carried.
D="$T/r4b"; mktree "$D"
printf 'stalepr:tsx\n' > "$D/state/health-active.txt"
touch "$D/listfail"; tick "$D" "$NOW"
grep -qxF stalepr:tsx "$D/state/health-active.txt" && bad "R4: stalepr:tsx was carried by the ts skip" || ok

echo "--- R6: the unstructured RESOLVED text opens nothing"
D="$T/r6"; mktree "$D"
beatd "$D" '{"kind":"alert","akey":"alert:x","line":"[pipeline-health] RESOLVED stalepr:ts — condition no longer holds"}'
[ "$(posts "$D")" = 0 ] && ok || bad "R6: the text copy POSTed: $(cat "$D/sent.jsonl")"
[ "$(notes "$D")" = 0 ] && ok || bad "R6: the text copy called alert_note: $(cat "$D/note.log")"
ls "$D/state/alerts/"*.json >/dev/null 2>&1 && bad "R6: a state file was written: $(ls "$D/state/alerts/")" || ok

echo "--- R6b: lines that only look like it are still noted"
for L in '[pipeline-health] ts: harness PR(s) #50 open >12h awaiting merge' \
         '[orchestrator/x] RESOLVED: the widget recovered' \
         '[pipeline-health] RESOLVED: the widget lane recovered' \
         '[orchestrator/main-red] o/r main is RED'; do
  D="$T/r6b-$(printf '%s' "$L" | md5sum | cut -c1-8)"; mktree "$D"
  beatd "$D" "$(jq -nc --arg l "$L" '{kind:"alert",akey:"alert:y",line:$l}')"
  [ "$(notes "$D")" -ge 1 ] && ok || bad "R6b: '$L' was swallowed (no alert_note)"
done

echo "--- R7: a retraction of a never-opened id is silent"
D="$T/r7"; mktree "$D"
beatd "$D" '{"kind":"alert","project":"fleet","akey":"alert:ph-never","alertid":"ph-never","resolved":true,"line":"[pipeline-health] RESOLVED never:x — condition no longer holds"}'
[ "$(posts "$D")" = 0 ] && ok || bad "R7: a resolve of nothing POSTed: $(cat "$D/sent.jsonl")"
[ "$(notes "$D")" = 0 ] && ok || bad "R7: a resolve of nothing called alert_note"
grep -q 'resolve-silent id=ph-never' "$D/logs/alerts-state.log" 2>/dev/null \
  && ok || bad "R7: no resolve-silent record: $(cat "$D/logs/alerts-state.log" 2>/dev/null)"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
