#!/bin/bash
# tests/archie-fm-report-short.bh-9449-test.sh — BH-9449: the daily factory
# report as a short Telegram text, per-build spend keys rolled into their
# project, the spend filter knobs and one "partial" total line. Driven through
# the SHIPPED bin/archie-fm-report.sh (tick and `render <day> [--telegram]`).
#
# THE FIXTURE. tests/fixtures/archie-fm-report-short.bh-9449/day-2026-11-09.json
# source: assumed, synthesized from the BH-9449 body (this box has no jobs API
# credential, so the live route answer for 2026-11-09 could not be read): 67
# spend keys (43 of the form cromford.<n>.<12 hex>), 29 merges over 7
# projects, one_thing.kind none, unknown $16.24 over 41 calls, 3 unpriced
# calls. Its shape is the route's (worker/jobs/src/routes/archie-factory.js
# spendSection: rows sorted by usd desc, null last). The BH-4588 fixtures
# (tests/fixtures/archie-fm-report.bh-4588/) are the needs-you and empty days.
#
# WHAT IS STUBBED, and only this (the BH-4588 world, copied, not sourced).
# ARCHIE_FMR_FIXTURE=$T/fx.sh (sandbox-only): _jobs_req, a jq model over
# $T/db.json of GET /api/settings/<key>, GET /api/archie/factory-report, GET
# /api/ledger and GET /api/alerts. $H/bin/archie-tg-send.sh logs each send to
# $T/tg.jsonl. PATH stubs curl, gh, git and wrangler log to $T/net.log and fail.
# No test calls Telegram or a model.
#
# Cases: A1-A13 (the ticket's acceptance list), B1-B7 (the other branches),
# X1-X3 (mutations, D1).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-fm-report-short.bh-9449-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "archie-fm-report-short: jq is required"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "archie-fm-report-short: flock is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }

for f in "$DIR/bin/archie-fm-report.sh" "$DIR/bin/lib/archie-fm-report/render.sh" \
         "$DIR/worker/jobs/schema.d/202611110543-bh-9449-report-short-settings.sql" \
         "$DIR/tests/fixtures/archie-fm-report-short.bh-9449/day-2026-11-09.json"; do
  if [ -f "$f" ]; then ok; else bad "missing $f"; fi
done
FIX="$DIR/tests/fixtures/archie-fm-report-short.bh-9449/day-2026-11-09.json"
FIX4588="$DIR/tests/fixtures/archie-fm-report.bh-4588"
SEED="$DIR/worker/jobs/schema.d/202611110543-bh-9449-report-short-settings.sql"

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"
mkdir -p "$H/logs" "$H/locks" "$H/env" "$H/catalog" "$T/fakebin"
scratch_install_closure bin/archie-fm-report.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || exit 1
cp "$DIR/catalog/archie-stop-the-line.tsv" "$H/catalog/"
: > "$H/env/global.env"
cat > "$H/bin/archie-tg-send.sh" <<'SH'
#!/bin/bash
jq -nc --arg a "$1" --arg t "$2" '{akey: $a, text: $t}' >> "$FXT/tg.jsonl"
jq --arg a "$1" '.tg[$a] = "sent"' "$FXT/db.json" > "$FXT/db.tmp" && mv "$FXT/db.tmp" "$FXT/db.json"
exit 0
SH
chmod +x "$H/bin/archie-tg-send.sh"
for s in curl gh git wrangler; do
  printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >> "$FXT/net.log"\nexit 1\n' "$s" > "$T/fakebin/$s"
done
chmod +x "$T/fakebin/"*

cat > "$T/fx.sh" <<'SH'
_jobs_req() {
  local m="$1" p="$2" out db="$FXT/db.json" key d
  JOBS_HTTP=""; JOBS_BODY=""
  [ "$p" = /api/settings ] && { printf '{"settings":[]}'; JOBS_HTTP=200; return 0; }
  printf '%s %s\n' "$m" "$p" >> "$FXT/reqlog"
  qp() { printf '%s' "$p" | sed -n "s/.*[?&]$1=\([^&]*\).*/\1/p"; }
  [ "$m" = GET ] || { JOBS_HTTP=404; printf '{"error":"unknown endpoint"}'; return 2; }
  case "${p%%\?*}" in
    /api/settings/*)
      key=${p#/api/settings/}
      [ -f "$FXT/settings.down.$key" ] && { JOBS_HTTP=503; return 1; }
      out=$(jq -c --arg k "$key" 'select(.settings | has($k)) | {setting: {key: $k, value: .settings[$k]}}' "$db")
      [ -n "$out" ] || { JOBS_HTTP=404; printf '{"error":"no such setting"}'; return 2; } ;;
    /api/archie/factory-report)
      d=$(qp day)
      [ -f "$FXT/report.$d.json" ] || { JOBS_HTTP=404; return 2; }
      out=$(cat "$FXT/report.$d.json") ;;
    /api/ledger)
      key=$(printf '%b' "$(qp key | sed 's/%/\\x/g')")
      out=$(jq -c --arg k "$key" '.tg[$k] // empty | {ledger: {kind: "archie_tg", key: $k, status: .}}' "$db")
      [ -n "$out" ] || { JOBS_HTTP=404; printf '{"error":"no ledger row"}'; return 2; } ;;
    /api/alerts)
      out=$(jq -c --arg s "$(qp state)" '{alerts: [.alerts[] | select(.state == $s)], truncated: false}' "$db") ;;
    *) JOBS_HTTP=404; printf '{"error":"unknown endpoint"}'; return 2 ;;
  esac
  JOBS_HTTP=200; JOBS_BODY="$out"; printf '%s' "$out"; return 0
}
:
SH

# A trailing slash on purpose: console_pages_url strips it.
export HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.invalid HARNESS_SECRET=test-fixture \
  JOBS_SETTINGS_CACHE_S=0 LANE_GATE_DISABLE=1 CONSOLE_PAGES_URL=https://mc.example.invalid/
unset ARCHIE_FMR_ENABLED ARCHIE_FMR_TIMED ARCHIE_FMR_NOW ARCHIE_FMR_FIXTURE ARCHIE_QUIET_FROM_H ARCHIE_QUIET_TO_H 2>/dev/null || true

T0=$(date -u -d 2026-11-10T07:05:00Z +%s)   # after the 07 send hour; yesterday is 2026-11-09
DAY=2026-11-09
MC="https://mc.example.invalid/factory?day=$DAY"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
# reset <mode> [report-file]: settings as seeded by BH-4588 (no report.spend_* row:
# the code fallbacks apply), no alert, no ledger row, the day's report.
reset() {
  local p
  for p in reqlog tg.jsonl out; do scratch_rm "$T/$p" || exit 1; done
  rm -f "$T"/settings.down.* "$T"/report.*.json
  scratch_rm "$H/logs/archie-fm-report.log" || exit 1
  jq --arg d "$DAY" '.day = $d' "${2:-$FIX}" > "$T/report.$DAY.json"
  jq -nc --arg m "${1:-on}" '{settings: {"archie.manage": $m, "archie.report.send_hour_utc": "7",
      "archie.stl.main_red_min": "60", "archie.stl.queue_stall_min": "60", "archie.stl.box_down_min": "15",
      "archie.stl.spend_spike_min": "0", "archie.stl.beats_per_tick": "3"}, tg: {}, alerts: []}' > "$T/db.json"
}
setting() { jq --arg k "$1" --arg v "$2" '.settings[$k] = $v' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"; }
# report_with <jq-filter> [base]: the day's report edited by the filter.
report_with() { jq --arg d "$DAY" ".day = \$d | $1" "${2:-$FIX}" > "$T/report.$DAY.json"; }
# ARCHIE_FMR_TIMED=1 skips the timeout re-exec (its lane_knob read runs before
# the fixture seam; BH-4588 K1 pins that path), so net.log stays empty.
tick() {
  env HARNESS_TEST_SANDBOX=1 ARCHIE_FMR_TIMED=1 ARCHIE_FMR_NOW="${1:-$T0}" ARCHIE_FMR_FIXTURE="$T/fx.sh" \
    bash "$H/bin/archie-fm-report.sh" tick > "$T/out" 2>&1
  echo $? > "$T/rc"
}
render() { env HARNESS_TEST_SANDBOX=1 ARCHIE_FMR_NOW="$T0" ARCHIE_FMR_FIXTURE="$T/fx.sh" bash "$H/bin/archie-fm-report.sh" render "$DAY" "$@"; }
n()     { local c; c=$(wc -l 2>/dev/null < "$1"); printf '%s' "${c:-0}" | tr -d ' '; }
sends() { n "$T/tg.jsonl"; }
tg_text() { jq -r 'select(.akey | startswith("fm-report:")) | .text' "$T/tg.jsonl" 2>/dev/null; }
logl()  { cat "$H/logs/archie-fm-report.log" 2>/dev/null; }
lines() { local c; c=$(printf '%s\n' "$1" | wc -l); printf '%s' "$c" | tr -d ' '; }
money() { jq -rn --argjson v "$1" '"$" + ((($v * 100 | round) / 100) | tostring | if test("\\.") then (if test("\\.[0-9]$") then . + "0" else . end) else . + ".00" end)'; }
PERBUILD='cromford\.[0-9]+\.[0-9a-f]{12}'

# ═════ A: the ticket's acceptance list ════════════════════════════════════════
# A1: the 2026-11-09 day, mode on: one send, <= 6 lines, < 700 characters.
reset on
tick
eq "A1 rc 0" "$(cat "$T/rc")" 0
eq "A1 exactly one send" "$(sends)" 1
eq "A1 the akey" "$(jq -r .akey "$T/tg.jsonl" 2>/dev/null)" "fm-report:$DAY"
TG=$(tg_text)
check "A1 6 lines or fewer (got $(lines "$TG"))" '[ "$(lines "$TG")" -le 6 ]'
check "A1 under 700 characters (got ${#TG})" '[ "${#TG}" -lt 700 ]'
eq "A1 line 1" "$(sed -n 1p <<<"$TG")" "Nothing needs you from $DAY."
eq "A1 line 2 is the mode" "$(sed -n 2p <<<"$TG")" "Mode: on."
eq "A1 the last line links the full report on Mission Control" "$(tail -n 1 <<<"$TG")" "Full report: $MC"
check "A1 the log says sent" 'grep -q "sent fm-report:$DAY (mode on)" <<<"$(logl)"'
# A1b: merges as counts, no PR links.
check "A1b no pull link in the Telegram text" '! grep -qE "https://github.com/.*/pull/" <<<"$TG"'
eq "A1b the merges line" "$(grep '^Merges:' <<<"$TG")" \
  "Merges: 29 across 7 projects (cromford 19, project-4 4, project-3 2, project-2 1, project-1 1, project-5 1, project-4-site 1)."
eq "A1b the fixture has 29 merges and 67 spend keys" "$(jq -c '[.merges.total, (.spend.by_project | length)]' "$FIX")" "[29,67]"
# The render verb prints the same short text with --telegram, and sends nothing.
eq "A1 render --telegram equals the sent text" "$(render --telegram)" "$TG"
eq "A1 render sends nothing" "$(sends)" 1

# A3: no per-build key in either text.
FULL=$(render)
eq "A3 the fixture holds 43 per-build keys" "$(jq --arg r "^$PERBUILD\$" '[.spend.by_project[] | select(.project | test($r))] | length' "$FIX")" 43
check "A3 no per-build key in the Telegram text" '! grep -qE "$PERBUILD" <<<"$TG"'
check "A3 no per-build key in the full text" '! grep -qE "$PERBUILD" <<<"$FULL"'
check "A3 the full text is the full report" 'grep -q "^Stuck items:" <<<"$FULL" && grep -q "^Spend vs caps: 24 projects\.$" <<<"$FULL"'

# A4: the cromford sum, and every merged PR link in the full report.
BH_SUM=$(jq '[.spend.by_project[] | select(.project == "cromford" or (.project | test("^cromford\\.[0-9]+\\.[0-9a-f]+$"))) | .usd // 0] | add' "$FIX")
BH_M=$(money "$BH_SUM")
eq "A4 the full text shows the cromford sum ($BH_M)" "$(grep '^- cromford: \$' <<<"$FULL")" "- cromford: $BH_M of a \$11323.76 day cap."
check "A4 the Telegram text lists cromford at the sum" 'grep -qF "cromford $BH_M of \$11323.76" <<<"$TG"'
check "A4 the sum is more than the parent row alone" '[ "$BH_M" != "$(money "$(jq "[.spend.by_project[] | select(.project == \"cromford\")][0].usd" "$FIX")")" ]'
MISSING=0
while IFS= read -r u; do grep -qF "$u" <<<"$FULL" || MISSING=$((MISSING+1)); done < <(jq -r '.merges.by_project[].prs[].url' "$FIX")
eq "A4 every merged PR link is in the full report (29)" "$(jq '[.merges.by_project[].prs[]] | length' "$FIX"):$MISSING" "29:0"

# A7: unknown over $1 with its call count.
check "A7 unknown is listed with its calls" 'grep -qF "unknown \$16.24 (41 calls)" <<<"$TG"'
check "A7 unknown is never in other" 'grep -qE "^18 other projects: " <<<"$TG"'

# A9: one partial total line in each text.
U=$(jq '[.spend.by_project[].unpriced_calls] | add' "$FIX"); C=$(jq '[.spend.by_project[].calls] | add' "$FIX")
eq "A9 one partial in the Telegram text" "$(grep -o partial <<<"$TG" | wc -l | tr -d ' ')" 1
eq "A9 one partial in the full text" "$(grep -o partial <<<"$FULL" | wc -l | tr -d ' ')" 1
check "A9 the Telegram text states the sums" 'grep -qF "(partial: $U of $C calls unpriced)" <<<"$TG"'
eq "A9 the full text states the sums" "$(grep partial <<<"$FULL")" "Spend partial: $U of $C calls unpriced."

# A2: one needs-you item (a failed action with a PR): it is line 1 with its link.
reset on
report_with '.stuck.items[0].outcome = "done" | .stuck.open = 0 | .stuck.cleared = 3' "$FIX4588/report.json"
tick
TG=$(tg_text)
eq "A2 line 1 is the failed action with its pull link" "$(sed -n 1p <<<"$TG")" \
  "Failed: queue-culprit on example-org/cromford#102: solo run could not start. https://github.com/example-org/cromford/pull/102"
eq "A2 line 2 is the mode (one item only)" "$(sed -n 2p <<<"$TG")" "Mode: on."
check "A2 no Nothing needs you" '! grep -q "Nothing needs you" <<<"$TG"'

# A3b: the roll-up decision table through both renders.
reset on
report_with '.spend.by_project = [
  {project: "cromford", usd: 1, calls: 1, unpriced_calls: 0, cap_usd: 11323.76, over: false},
  {project: "cromford.9317.2a7f0fd23c7e", usd: 1, calls: 1, unpriced_calls: 0, cap_usd: 7068.03, over: false},
  {project: "project-4.12.abc123", usd: 1, calls: 1, unpriced_calls: 0, cap_usd: 4970.21, over: false},
  {project: "project-3.1.0", usd: 1, calls: 1, unpriced_calls: 0, cap_usd: 7068.03, over: false},
  {project: "orphan.5.ab", usd: 1, calls: 1, unpriced_calls: 0, cap_usd: 9.99, over: false},
  {project: "cromford.9317", usd: 1, calls: 1, unpriced_calls: 0, cap_usd: 7068.03, over: false},
  {project: "cromford.9317.2A7F0FD23C7E", usd: 1, calls: 1, unpriced_calls: 0, cap_usd: 7068.03, over: false},
  {project: "cromford.abc.2a7f0fd23c7e", usd: 1, calls: 1, unpriced_calls: 0, cap_usd: 7068.03, over: false},
  {project: "cromford.9317.2a7f0fd23c7g", usd: 1, calls: 1, unpriced_calls: 0, cap_usd: 7068.03, over: false},
  {project: "unknown", usd: 2, calls: 3, unpriced_calls: 0, cap_usd: 7068.03, over: false}]'
setting report.spend_min_usd 0
FULL=$(render); TG=$(render --telegram)
for want in "- cromford: \$2.00 of a \$11323.76 day cap." "- project-4: \$1.00 of a \$4970.21 day cap." \
            "- project-3: \$1.00 of a \$7068.03 day cap." "- orphan: \$1.00 of a \$9.99 day cap." \
            "- cromford.9317: \$1.00 of a \$7068.03 day cap." "- cromford.9317.2A7F0FD23C7E: \$1.00 of a \$7068.03 day cap." \
            "- cromford.abc.2a7f0fd23c7e: \$1.00 of a \$7068.03 day cap." "- cromford.9317.2a7f0fd23c7g: \$1.00 of a \$7068.03 day cap." \
            "- unknown: \$2.00 of a \$7068.03 day cap."; do
  check "A3b full: [$want]" 'grep -qxF -- "$want" <<<"$FULL"'
done
check "A3b full: the rolled keys are gone" '! grep -qE "^- (cromford\.9317\.2a7f0fd23c7e|project-4\.12\.abc123|project-3\.1\.0|orphan\.5\.ab):" <<<"$FULL"'
eq "A3b full: 9 rows" "$(grep '^Spend vs caps:' <<<"$FULL")" "Spend vs caps: 9 projects."
for want in "cromford \$2.00 of \$11323.76" "project-4 \$1.00 of \$4970.21" "project-3 \$1.00 of \$7068.03" "orphan \$1.00 of \$9.99" \
            "cromford.9317 \$1.00" "cromford.9317.2A7F0FD23C7E \$1.00" "cromford.abc.2a7f0fd23c7e \$1.00" \
            "cromford.9317.2a7f0fd23c7g \$1.00" "unknown \$2.00 (3 calls)"; do
  check "A3b Telegram: [$want]" 'grep -qF -- "$want" <<<"$TG"'
done
check "A3b Telegram: the rolled keys are gone" '! grep -qE "(cromford\.9317\.2a7f0fd23c7e|project-4\.12\.abc123|project-3\.1\.0|orphan\.5\.ab) " <<<"$TG"'

# A5: no single cromford key is over its cap, the rolled sum is: line 1.
reset on
report_with '.spend.by_project |= map(if .project == "cromford" then .usd = 6000
  elif .project == "cromford.9200.\(.project | split(".")[2])" then .usd = 5400 else . end)'
check "A5 premise: no single key is over" '[ "$(jq "[.spend.by_project[] | select(.usd != null and .usd > .cap_usd)] | length" "$T/report.$DAY.json")" = 0 ]'
tick
TG=$(tg_text)
SUM=$(money "$(jq '[.spend.by_project[] | select(.project | test("^cromford(\\.[0-9]+\\.[0-9a-f]+)?$")) | .usd // 0] | add' "$T/report.$DAY.json")")
eq "A5 the over-cap item is line 1" "$(sed -n 1p <<<"$TG")" "cromford spent $SUM, over its \$11323.76 day cap. $MC"
check "A5 the full text says OVER the cap on the rolled row" 'grep -qF "cromford: $SUM of a \$11323.76 day cap, OVER the cap." <<<"$(render)"'

# A5b: the negative list gives Nothing needs you.
reset on
report_with '.actions.rows |= map(.outcome = "done") | .totals.by_outcome = {done: 7, requested: 1}
  | .stuck.items[0].outcome = "done" | .stuck.items[1].outcome = "would" | .stuck.open = 0 | .stuck.would = 1
  | .spend = {ok: false, error: "D1_ERROR: fixture cost read down"}
  | .one_thing = {kind: "none", text: "Nothing needs you from 2026-11-09."}' "$FIX4588/report.json"
tick
TG=$(tg_text)
eq "A5b done + would + an unread spend: Nothing needs you" "$(sed -n 1p <<<"$TG")" "Nothing needs you from $DAY."
eq "A5b the unread spend keeps one not measured line" "$(grep '^Spend' <<<"$TG")" "Spend: not measured: D1_ERROR: fixture cost read down."
check "A5b an unread spend is never over a cap" '! grep -qi "over its" <<<"$TG"'
reset on
report_with '.spend.by_project = [{project: "project-4", usd: 3000, calls: 9, unpriced_calls: 0, cap_usd: 4970.21, over: false}]'
tick
TG=$(tg_text)
eq "A5b 60% of the cap, under it: Nothing needs you" "$(sed -n 1p <<<"$TG")" "Nothing needs you from $DAY."
check "A5b and it is listed (over report.spend_cap_pct)" 'grep -qF "Listed: project-4 \$3000.00 of \$4970.21." <<<"$TG"'

# A6: the listed / other table (fallbacks 5.00, 50, 1.00).
SMALL='.spend.by_project = [
  {project: "p-a", usd: 5.01, calls: 1, unpriced_calls: 0, cap_usd: 10000, over: false},
  {project: "p-c", usd: 5.00, calls: 1, unpriced_calls: 0, cap_usd: 10000, over: false},
  {project: "p-d", usd: 4.99, calls: 1, unpriced_calls: 0, cap_usd: 11323.76, over: false},
  {project: "p-f", usd: 3, calls: 1, unpriced_calls: 0, cap_usd: null, over: false},
  {project: "p-b", usd: 1, calls: 1, unpriced_calls: 0, cap_usd: 1.5, over: false},
  {project: "p-e", usd: null, calls: 2, unpriced_calls: 2, cap_usd: 100, over: false},
  {project: "unknown", usd: UNK, calls: 4, unpriced_calls: 0, cap_usd: 7068.03, over: false}]'
reset on
report_with "${SMALL/UNK/16.24}"
tick
TG=$(tg_text)
SP=$(grep '^Spend:' <<<"$TG")
check "A6 listed: p-a 5.01 over 5.00" 'grep -qF "p-a \$5.01 of \$10000.00" <<<"$SP"'
check "A6 listed: p-b 1 of 1.5 (66% over 50%)" 'grep -qF "p-b \$1.00 of \$1.50" <<<"$SP"'
check "A6 listed: unknown 16.24" 'grep -qF "unknown \$16.24 (4 calls)" <<<"$SP"'
for p in p-c p-d p-e p-f; do check "A6 not listed: $p" '! grep -qF "$p " <<<"$SP"'; done
eq "A6 the other line: 4 projects, a null adds 0" "$(grep 'other project' <<<"$TG")" "4 other projects: \$12.99 in total."
check "A6 the null row is in the partial total" 'grep -qF "(partial: 2 of 11 calls unpriced)" <<<"$SP"'
reset on
report_with "${SMALL/UNK/0.99}"
tick
TG=$(tg_text)
check "A6 unknown 0.99 is not shown" '! grep -q unknown <<<"$TG"'
eq "A6 unknown is never in other" "$(grep 'other project' <<<"$TG")" "4 other projects: \$12.99 in total."

# A8: the settings row report.spend_min_usd = 100 is read.
MID='.spend.by_project = [
  {project: "p-150", usd: 150, calls: 1, unpriced_calls: 0, cap_usd: 100000, over: false},
  {project: "p-99", usd: 99, calls: 1, unpriced_calls: 0, cap_usd: 100000, over: false}]'
reset on
report_with "$MID"
tick
TG=$(tg_text)
check "A8 no row (fallback 5.00): p-99 is listed" 'grep -qF "p-99 \$99.00" <<<"$TG"'
reset on
report_with "$MID"
setting report.spend_min_usd 100
tick
TG=$(tg_text)
check "A8 row 100: p-150 stays listed" 'grep -qF "Listed: p-150 \$150.00 of \$100000.00." <<<"$TG"'
check "A8 row 100: p-99 is not listed" '! grep -qF "p-99" <<<"$TG"'
eq "A8 row 100: p-99 is in other" "$(grep 'other project' <<<"$TG")" "1 other project: \$99.00 in total."
check "A8 the row was read" 'grep -q "GET /api/settings/report.spend_min_usd" "$T/reqlog"'
reset on
report_with "$MID"
setting report.spend_cap_pct 0.05
tick
check "A8 report.spend_cap_pct is read too: 0.099% > 0.05% lists p-99" 'grep -qF "p-99 \$99.00" <<<"$(tg_text)"'

# A10: an empty day: no section says none.
reset on
report_with '.' "$FIX4588/empty.json"
tick
TG=$(tg_text)
check "A10 no none in the Telegram text" '! grep -qiw none <<<"$TG"'
eq "A10 three lines: nothing, mode, link" "$(lines "$TG")" 3
eq "A10 line 1 is the route's one thing" "$(sed -n 1p <<<"$TG")" "$(jq -r .one_thing.text "$FIX4588/empty.json")"

# A11: a bad row value: the fallback, one warn line, the report still sends once.
reset on
setting report.spend_min_usd abc
tick
TG=$(tg_text)
eq "A11 one send" "$(sends)" 1
eq "A11 one warn line" "$(logl | grep -c "warn: report.spend_min_usd='abc' is not a number; using the fallback 5.00")" 1
check "A11 the fallback 5.00 applies: project-2 6.50 listed, project-1 4.99 not" \
  'grep -qF "project-2 \$6.50" <<<"$(grep "^Spend:" <<<"$TG")" && ! grep -qF "project-1" <<<"$(grep "^Spend:" <<<"$TG")"'
reset on
: > "$T/settings.down.report.spend_cap_pct"
tick
eq "A11 an unreadable row: still one send" "$(sends)" 1
eq "A11 an unreadable row: one warn line" "$(logl | grep -c "warn: report.spend_cap_pct could not be read (rc=1); using the fallback 50")" 1

# A13: the seeds equal the code fallbacks.
seed() { sed -n "s/.*('$1','\([^']*\)'.*/\1/p" "$SEED"; }
fallback() { sed -n "s/.*afr_knob $1 \([0-9.]*\)).*/\1/p" "$DIR/bin/archie-fm-report.sh"; }
eq "A13 report.spend_min_usd seed" "$(seed report.spend_min_usd)" 5.00
eq "A13 report.spend_cap_pct seed" "$(seed report.spend_cap_pct)" 50
eq "A13 report.spend_unknown_min_usd seed" "$(seed report.spend_unknown_min_usd)" 1.00
for k in report.spend_min_usd report.spend_cap_pct report.spend_unknown_min_usd; do
  eq "A13 $k: seed = code fallback" "$(fallback "$k")" "$(seed "$k")"
done

# ═════ B: the other branches ══════════════════════════════════════════════════
# B1: needs-you order: stop the line, failed, open stuck, then the more line.
reset on
report_with '.totals.by_outcome.failed = 3' "$FIX4588/report.json"
FS=$(( T0 - 7200 ))
jq --arg fs "$(iso "$FS")" '.alerts += [{id: "main-red-cromford", family: "fixture", box: "hub", project: "cromford",
  state: "new", count: 1, first_seen: $fs, last_seen: $fs, claimed_by: null, claimed_at: null, notified_at: null,
  severity: "warn", line: "[orchestrator/main-red] example-org/cromford main is RED"}]' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
tick
TG=$(tg_text)
eq "B1 line 1: the stop-the-line incident" "$(sed -n 1p <<<"$TG")" "Stop the line: main-red, open 120 min, alert main-red-cromford."
check "B1 line 2: the failed action" 'sed -n 2p <<<"$TG" | grep -q "^Failed: queue-culprit on example-org/cromford#102: "'
eq "B1 line 3: the open stuck item, with the MC link (no url)" "$(sed -n 3p <<<"$TG")" \
  "Open: watch-main-red on example-org/cromford, kick_lane: main red 70 min; kicked main-red-bisect. $MC"
eq "B1 line 4: 2 more failed than listed" "$(sed -n 4p <<<"$TG")" "2 more on Mission Control: $MC"
eq "B1 line 5: the mode" "$(sed -n 5p <<<"$TG")" "Mode: on."
# B2: the modes.
for m in observe off; do
  reset "$m"; tick
  case $m in observe) want="Mode: observe (Archie acted on nothing).";; off) want="Mode: off (Archie took no action).";; esac
  eq "B2 mode $m" "$(sed -n 2p <<<"$(tg_text)")" "$want"
done
eq "B2 the full text still says off on line 1" "$(render | sed -n 1p)" "Archie is off (archie.manage=off) and took no action."
# B3: an unread merges section keeps one line.
reset on
report_with '.merges = {ok: false, error: "D1_ERROR: fixture merges down"}'
tick
eq "B3 merges not measured" "$(grep '^Merges' <<<"$(tg_text)")" "Merges: not measured: D1_ERROR: fixture merges down."
# B4: one_thing says something but no item is derived: one line with the MC link.
reset on
report_with '.actions = {ok: false, error: "D1_ERROR: fixture rows down"} | .stuck.ok = false | .stuck.error = "x" | .totals.ok = false | .totals.error = "x"' "$FIX4588/report.json"
tick
eq "B4 the one thing with the MC link" "$(sed -n 1p <<<"$(tg_text)")" "$(jq -r .one_thing.text "$FIX4588/report.json") $MC"
eq "B4 line 2: the unread actions with the MC link" "$(sed -n 2p <<<"$(tg_text)")" "Not measured: Archie actions (D1_ERROR: fixture rows down). $MC"
eq "B4 line 3: the unread stuck items with the MC link" "$(sed -n 3p <<<"$(tg_text)")" "Not measured: stuck items (x). $MC"
# B7: an unread agg read and one_thing.kind none: never "Nothing needs you" (D12).
reset on
report_with '.totals = {ok: false, error: "D1_ERROR: overloaded"} | .stuck = {ok: false, error: "D1_ERROR: overloaded"}
  | .queue = {ok: false, error: "D1_ERROR: overloaded"} | .tickets = {ok: false, error: "D1_ERROR: overloaded"}
  | .actions = {ok: false, error: "D1_ERROR: overloaded"}
  | .one_thing = {kind: "none", text: "Nothing needs you from 2026-10-22."}' "$FIX4588/report.json"
tick
TG=$(tg_text)
check "B7 no Nothing needs you" '! grep -q "Nothing needs you" <<<"$TG"'
eq "B7 line 1: the unread actions" "$(sed -n 1p <<<"$TG")" "Not measured: Archie actions (D1_ERROR: overloaded). $MC"
eq "B7 line 2: the unread stuck items" "$(sed -n 2p <<<"$TG")" "Not measured: stuck items (D1_ERROR: overloaded). $MC"
# B7b: only the totals read failed (the rows were read): still a line, not an all-clear.
reset on
report_with '.actions.rows |= map(.outcome = "done") | .totals = {ok: false, error: "D1_ERROR: totals down"}
  | .stuck.items |= map(.outcome = "done") | .stuck.open = 0
  | .one_thing = {kind: "none", text: "Nothing needs you from 2026-10-22."}' "$FIX4588/report.json"
tick
TG=$(tg_text)
check "B7b no Nothing needs you" '! grep -q "Nothing needs you" <<<"$TG"'
eq "B7b line 1: the unread totals" "$(sed -n 1p <<<"$TG")" "Not measured: Archie actions (D1_ERROR: totals down). $MC"
# B5: render usage.
render "$DAY" >/dev/null 2>&1; eq "B5 render <day> <day>: usage rc 2" "$?" 2
env HARNESS_TEST_SANDBOX=1 ARCHIE_FMR_FIXTURE="$T/fx.sh" bash "$H/bin/archie-fm-report.sh" render >/dev/null 2>&1
eq "B5 render with no day: rc 2" "$?" 2
# B6: no em or en dash in the short text.
reset on
report_with '.stuck.items[0].why = "kicked the lane — twice – today"' "$FIX4588/report.json"
tick
check "B6 no em or en dash" '! grep -q "[—–]" <<<"$(tg_text)"'

# ═════ X: mutations (D1) ══════════════════════════════════════════════════════
RS="$H/bin/lib/archie-fm-report/render.sh"
restore() { scratch_rm "$RS" || exit 1; scratch_rm "$H/bin/archie-fm-report.sh" || exit 1
  scratch_install_closure bin/archie-fm-report.sh "$H" >/dev/null || exit 1; }
# X1: the roll-up regex broken -> A3 goes red.
sed -i 's/def parentof: (capture/def parentof: (capture("^NEVER$").p) \/\/ .; def parentof_x: (capture/' "$RS"
check "X1 the mutant differs" '! cmp -s "$RS" "$DIR/bin/lib/archie-fm-report/render.sh"'
reset on; tick
check "X1 without the roll-up a per-build key is printed (A3 is a real guard)" 'grep -qE "$PERBUILD" <<<"$(render)"'
restore
# X2: the lane sends the full text -> A1's line count goes red.
sed -i 's/TEXT=$(afr_short /TEXT=$(afr_render /' "$H/bin/archie-fm-report.sh"
check "X2 the mutant differs" '! cmp -s "$H/bin/archie-fm-report.sh" "$DIR/bin/archie-fm-report.sh"'
reset on; tick
check "X2 the full text is over 6 lines (A1 is a real guard)" '[ "$(lines "$(tg_text)")" -gt 6 ]'
restore
# X3: the min knob ignored -> A8 goes red.
sed -i 's/(.usd > \$min$/(.usd > 5/' "$RS"
check "X3 the mutant differs" '! cmp -s "$RS" "$DIR/bin/lib/archie-fm-report/render.sh"'
reset on; report_with "$MID"; setting report.spend_min_usd 100; tick
check "X3 without the knob p-99 stays listed (A8 is a real guard)" 'grep -qF "p-99 \$99.00 of" <<<"$(tg_text)"'
restore
check "X the closure is restored" 'cmp -s "$RS" "$DIR/bin/lib/archie-fm-report/render.sh" && cmp -s "$H/bin/archie-fm-report.sh" "$DIR/bin/archie-fm-report.sh"'

# A12: no network, no git, no GitHub; every send went to the stub.
check "A12 the fakebin network log is empty" '[ ! -s "$T/net.log" ]'

echo "archie-fm-report-short: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
