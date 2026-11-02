#!/bin/bash
# tests/stuck-work.bh-3781-test.sh — BH-3793 (BH-3781.4): the stuck-work lane
# body, driven through the SHIPPED bin/stuck-work.sh, and the digest's
# "Open work past SLA" line through the real dd_render.
#
# WHAT IS STUBBED. The lane runs from a scratch harness ($H: a symlink tree of
# the repo's bin/ and catalog/, a built lanes.json) with two shims:
# bin/beat.sh appends `BEAT <line>` to $T/seq (alert-line.sh calls it before it
# appends ALERTS.log), and bin/lane-alert.sh records every call to
# $T/lane-alerts. Everything else is real: the gate, lane_env_apply, the
# switch, jobs-client and its ledger verbs, alert-line.sh and the classifier.
# A fake `curl` first in PATH is the jobs worker at $JOBS_URL:
#   - /api/settings answers $T/settings.json;
#   - /api/ledger GET/PUT keeps rows in $T/ledger.json, appends
#     `PUT <kind> <key> <status>` to $T/seq; $T/get.code / $T/put.code force
#     that status for that method.
# The FACTS come from tests/fixtures/stuck-work/scenario-*.txt through
# STUCK_WORK_FIXTURE, and the clock is STUCK_WORK_NOW (both sandbox-only).
#
#   L1  scenario-mixed: items= and states= in the log line
#   L2  every pageable state past SLA: one ALERTS line each, PUT before line,
#       waiting-on-human 0 lines, snapshot by_state/total
#   L3  the next tick (+5m): 0 lines, 0 PUTs
#   L4  4 x SLA: exactly 1 repage, row repaged;  L5 later ticks: 0
#   L6  within SLA: 0 lines, 0 stuck_work PUTs
#   L7  the settings row stuck_work_sla_ready_min=5 pages an 8-min READY PR
#   L8  ledger PUT 500: 0 item lines, ONE outage line, 0 on the next tick
#   L8b ledger GET 500: the same
#   L9  the 2026-09-30 scenario: 10 lines ready/conductor; 14 min 0, 15 min 10
#   L10 the adversarial negatives: 0 lines
#   L11 flags/stuck-work-off: 0 lines, `off`
#   L12 the lock held: `busy`, 0 lines
#   L13 live readers (scratch-only doubles): rc 3 -> incomplete=1, the ticket
#       reader gets the PR items as a file
#   L14 no App token: `no-token`, one lane-alert, 0 more the same day
#   L15 STUCK_WORK_MAX_ITEMS=3: 3 items looked at, incomplete=1
#   R1-R3 the digest line
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/stuck-work.bh-3781-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "stuck-work: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

FX="$DIR/tests/fixtures/stuck-work"
for f in "$DIR/bin/stuck-work.sh" "$DIR/bin/lib/daily-digest-render.sh" "$FX/scenario-mixed.txt" \
         "$FX/scenario-within-sla.txt" "$FX/scenario-ready-8m.txt" "$FX/scenario-2026-09-30.txt" \
         "$FX/scenario-negatives.txt"; do
  [ -f "$f" ] || { echo "FAIL: $f is missing"; echo "stuck-work: 0 passed, 1 failed"; exit 1; }
done

H="$T/h"
mkdir -p "$H/env" "$T/fakebin"
cp -rs "$DIR/bin" "$H/bin"
cp -rs "$DIR/catalog" "$H/catalog"
rm -f "$H/catalog/lanes.json"
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" > "$H/catalog/lanes.json" 2> "$T/build.err" \
  || bad "setup: bin/lanes-build.sh failed: $(cat "$T/build.err")"
: > "$H/env/global.env"
rm -f "$H/bin/lane-alert.sh" "$H/bin/beat.sh"
cat > "$H/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/lane-alerts"
exit 0
SH
cat > "$H/bin/beat.sh" <<'SH'
#!/bin/bash
printf 'BEAT %s\n' "$(printf '%s' "$1" | jq -r .line)" >> "$FXT/seq"
exit 0
SH
chmod +x "$H/bin/lane-alert.sh" "$H/bin/beat.sh"
LANE="$H/bin/stuck-work.sh"

cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
m=GET; body=""; prev=""; wfmt=0
for a in "$@"; do
  case "$prev" in
    -X) m="$a" ;;
    --data-binary|-d) body="$a" ;;
    -w) wfmt=1 ;;
  esac
  prev="$a"
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
url="${!#}"
case "$url" in "$JOBS_URL"*) ;; *) echo "$url" >> "$FXT/other-urls"; exit 7 ;; esac
path="${url#"$JOBS_URL"}"
dec() { local s=${1//+/ }; printf '%b' "${s//%/\\x}"; }
code=200; out='{"ok":true}'
case "$m $path" in
  "GET /api/settings"*)
    out=$(jq -c '{settings: .}' "$FXT/settings.json" 2>/dev/null || echo '{"settings":[]}') ;;
  "GET /api/ledger"*)
    if [ -f "$FXT/get.code" ]; then code=$(cat "$FXT/get.code"); out='{"error":"down"}'
    else
      k=$(dec "$(printf '%s' "$path" | sed -n 's/.*[?&]kind=\([^&]*\).*/\1/p')")
      v=$(dec "$(printf '%s' "$path" | sed -n 's/.*[?&]key=\([^&]*\).*/\1/p')")
      row=$(jq -c --arg i "$k/$v" '.[$i] // empty' "$FXT/ledger.json")
      if [ -n "$row" ]; then out=$(jq -nc --argjson r "$row" '{ledger: $r}'); else code=404; out='{"error":"not found"}'; fi
    fi ;;
  "PUT /api/ledger"*)
    if [ -f "$FXT/put.code" ]; then code=$(cat "$FXT/put.code"); out='{"error":"down"}'
    else
      printf 'PUT %s\n' "$(jq -r '"\(.kind) \(.key) \(.status)"' <<<"$body")" >> "$FXT/seq"
      jq --argjson b "$body" '.[$b.kind + "/" + $b.key] = {status: $b.status, detail: ($b.detail // "")}' \
        "$FXT/ledger.json" > "$FXT/ledger.tmp" && mv "$FXT/ledger.tmp" "$FXT/ledger.json"
    fi ;;
  "GET "*) code=404; out='{"error":"not found"}' ;;
esac
printf '%s' "$out"
[ "$wfmt" = 1 ] && printf '\n%s' "$code"
exit 0
SH
chmod +x "$T/fakebin/curl"

export HARNESS="$H" FXT="$T" JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 HARNESS_SECRET=test JOBS_BOX=hub \
  PATH="$T/fakebin:$PATH"
unset GH_TOKEN GITHUB_TOKEN STUCK_WORK_ENABLED STUCK_WORK_MAX_ITEMS STUCK_WORK_REPAGE_FACTOR STUCK_WORK_REPO \
  STUCK_WORK_SLA_BLOCKED_MIN STUCK_WORK_SLA_BUILD_STAGES STUCK_WORK_SLA_DEQUEUED_MIN STUCK_WORK_SLA_HUMAN_MIN \
  STUCK_WORK_SLA_LEAD_REVIEW_MIN STUCK_WORK_SLA_QUEUED_MIN STUCK_WORK_SLA_READY_MIN STUCK_WORK_SLA_UNLAUNCHED_MIN \
  STUCK_WORK_NOW STUCK_WORK_FIXTURE LANE_GATE_DISABLE HARNESS_ENV_DIR 2>/dev/null || true

N=1790000000            # 2026-09-21T14:13:20Z, the anchor every fixture is written against
LOG="$H/logs/stuck-work.log"

# reset: a fresh world — no ledger rows, no settings rows, no flags/state/logs.
reset() {
  local p
  for p in "$T/seq" "$T/lane-alerts" "$T/ledger.json" "$T/get.code" "$T/put.code" "$T/settings.json" \
    "$T/other-urls" "$T/tk-args" "$T/pr-args" "$H/state" "$H/logs" "$H/locks" "$H/flags"; do
    scratch_rm "$p" || exit 1
  done
  echo '{}' > "$T/ledger.json"; echo '[]' > "$T/settings.json"; : > "$T/seq"
}
# run <now> <fixture|-> [VAR=value ...]: one tick of the shipped lane.
run() {
  local now=$1 fx=$2; shift 2
  [ "$fx" = - ] && fx="" || fx="$FX/$fx"
  env HARNESS_TEST_SANDBOX=1 STUCK_WORK_NOW="$now" STUCK_WORK_FIXTURE="$fx" "$@" bash "$LANE" > "$T/out" 2>&1
  echo $? > "$T/rc"
}
cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }
pages() { cnt 'STUCK-WORK example-org/' "$H/logs/ALERTS.log"; }
outage() { cnt 'STUCK-WORK ledger unreachable' "$H/logs/ALERTS.log"; }
puts() { cnt '^PUT stuck_work ' "$T/seq"; }
last() { tail -n 1 "$LOG" 2>/dev/null; }
row() { jq -r --arg i "stuck_work/$1" '.[$i].status // "none"' "$T/ledger.json"; }
snap() { jq -r '.["stuck_work_snapshot/latest"].detail // "{}"' "$T/ledger.json"; }

# ── L1/L2: the mixed scenario, every state at 1.5 x its SLA ─────────────────
reset; run "$N" scenario-mixed.txt
check "L1 rc 0 ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
check "L1 log line: $(last)" \
  'last | grep -qxE "[0-9T:Z-]+ items=10 states=awaiting-lead-review:1,blocked:1,building:execute:1,dequeued:1,excluded:1,queued:1,ready:1,unclassified:1,unlaunched:1,waiting-on-human:1 past_sla=9 paged=8 repaged=0 incomplete=0"'
check "L2 exactly 8 page lines ($(pages))" '[ "$(pages)" = 8 ]'
for want in "#101 awaiting-lead-review owner=lead lane age=90m sla=60m — https://github.com/example-org/cromford/pull/101" \
            "#102 ready owner=conductor age=22m sla=15m — https://github.com/example-org/cromford/pull/102" \
            "#103 queued owner=Mergify age=135m sla=90m — https://github.com/example-org/cromford/pull/103" \
            "#104 dequeued owner=dequeue-watch age=45m sla=30m — https://github.com/example-org/cromford/pull/104" \
            "#105 blocked owner=fix round age=90m sla=60m — https://github.com/example-org/cromford/pull/105" \
            "#106 building:execute owner=builder age=180m sla=120m — https://github.com/example-org/cromford/issues/106" \
            "#107 unlaunched owner=triage / dispatch age=90m sla=60m — https://github.com/example-org/cromford/issues/107" \
            "#108 unclassified owner=stuck-work age=10m sla=0m — https://github.com/example-org/cromford/pull/108"; do
  check "L2 one ALERTS line '$want'" '[ "$(grep -cF -- "STUCK-WORK example-org/cromford$want" "$H/logs/ALERTS.log")" = 1 ]'
done
check "L2 waiting-on-human and the draft page nothing" '! grep -qE "#109 |#110 " "$H/logs/ALERTS.log"'
check "L2 8 stuck_work PUTs, all paged ($(puts))" '[ "$(puts)" = 8 ] && [ "$(grep "^PUT stuck_work " "$T/seq" | grep -vc " paged$")" = 0 ]'
check "L2 the row for #102 is paged ($(row 'example-org/cromford#102|ready|1789998650'))" \
  '[ "$(row "example-org/cromford#102|ready|1789998650")" = paged ]'
check "L2 the page detail" \
  'jq -r ".[\"stuck_work/example-org/cromford#102|ready|1789998650\"].detail" "$T/ledger.json" | jq -e ".owner == \"conductor\" and .sla_s == 900 and .paged_at == $N and .repaged_at == null" >/dev/null'
# every PUT lands before its own beat (alert-line.sh beats, then appends ALERTS.log)
order_ok() {
  awk '/^PUT stuck_work /{split($3,a,"|"); put[a[1]]=NR}
       /^BEAT /{ if (match($0, /example-org\/cromford#[0-9]+/)) { k=substr($0,RSTART,RLENGTH); if (!(k in put) || put[k] > NR) bad=1; n++ } }
       END { exit (bad || n != 8) }' "$T/seq"
}
check "L2 every stuck_work PUT precedes its alert ($(tr '\n' '|' < "$T/seq" | cut -c1-300))" 'order_ok'
check "L2 snapshot by_state/total ($(snap))" \
  '[ "$(snap | jq -c "[.total, .complete, .at, (.by_state | to_entries | map(\"\(.key):\(.value)\") | join(\",\"))]")" = "[9,true,$N,\"awaiting-lead-review:1,blocked:1,building:execute:1,dequeued:1,queued:1,ready:1,unclassified:1,unlaunched:1,waiting-on-human:1\"]" ]'
check "L2 no lane-alert" '[ ! -s "$T/lane-alerts" ]'

# ── L3: the next tick, 5 minutes on ─────────────────────────────────────────
: > "$T/seq"; P0=$(pages)
run $((N + 300)) scenario-mixed.txt
check "L3 0 new lines ($(( $(pages) - P0 )))" '[ "$(pages)" = "$P0" ]'
check "L3 0 new stuck_work PUTs ($(puts))" '[ "$(puts)" = 0 ]'
check "L3 log: $(last)" 'last | grep -qE " past_sla=9 paged=0 repaged=0 incomplete=0$"'

# ── L4/L5: one READY PR (8 min old at N), page at 15 min, repage at 4 x 15 ───
E=1789999520; K="example-org/cromford#120|ready|$E"
reset; run $((E + 900)) scenario-ready-8m.txt
check "L4 setup: one page at 15 min ($(pages))" '[ "$(pages)" = 1 ] && [ "$(row "$K")" = paged ]'
run $((E + 3599)) scenario-ready-8m.txt
check "L4 just under 4 x SLA: still one line ($(pages))" '[ "$(pages)" = 1 ]'
run $((E + 3600)) scenario-ready-8m.txt
check "L4 4 x SLA: exactly one new line ($(pages))" '[ "$(pages)" = 2 ]'
check "L4 row repaged ($(row "$K"))" '[ "$(row "$K")" = repaged ]'
check "L4 the repage keeps paged_at and stamps repaged_at" \
  'jq -r --arg i "stuck_work/$K" ".[\$i].detail" "$T/ledger.json" | jq -e ".paged_at == $((E + 900)) and .repaged_at == $((E + 3600))" >/dev/null'
check "L4 log: $(last)" 'last | grep -qE " items=1 states=ready:1 past_sla=1 paged=0 repaged=1 incomplete=0$"'
run $((E + 4500)) scenario-ready-8m.txt
run $((E + 45000)) scenario-ready-8m.txt
check "L5 5 x and 50 x SLA: 0 new lines ($(pages))" '[ "$(pages)" = 2 ]'

# ── L6: within SLA ──────────────────────────────────────────────────────────
reset; run "$N" scenario-within-sla.txt
check "L6 0 lines ($(pages))" '[ "$(pages)" = 0 ]'
check "L6 0 stuck_work PUTs ($(puts))" '[ "$(puts)" = 0 ]'
check "L6 log: $(last)" 'last | grep -qE " items=9 states=[^ ]+ past_sla=0 paged=0 repaged=0 incomplete=0$"'
check "L6 snapshot total 0 ($(snap))" '[ "$(snap | jq -c "[.total, .by_state]")" = "[0,{}]" ]'

# ── L7: the READY SLA is a settings row ─────────────────────────────────────
reset; run "$N" scenario-ready-8m.txt
check "L7 no row: an 8-min READY PR is within the 15-min default ($(pages))" '[ "$(pages)" = 0 ]'
reset; echo '[{"key":"lane.stuck-work.stuck_work_sla_ready_min","value":"5","actor":"operator"}]' > "$T/settings.json"
run "$N" scenario-ready-8m.txt
check "L7 row 5: one line ($(pages))" '[ "$(pages)" = 1 ]'
check "L7 the line says sla=5m" 'grep -q "#120 ready owner=conductor age=8m sla=5m" "$H/logs/ALERTS.log"'

# ── L8/L8b: the ledger is down ──────────────────────────────────────────────
for v in put get; do
  reset; echo 500 > "$T/$v.code"
  run "$N" scenario-mixed.txt
  check "L8 ($v 500) rc 0" '[ "$(cat "$T/rc")" = 0 ]'
  check "L8 ($v 500) 0 per-item lines ($(pages))" '[ "$(pages)" = 0 ]'
  check "L8 ($v 500) exactly one outage line ($(outage))" '[ "$(outage)" = 1 ]'
  if [ "$v" = put ]; then
    check "L8 put 500: the outage line counts 8" \
      'grep -q "STUCK-WORK ledger unreachable — 8 items past SLA unpaged$" "$H/logs/ALERTS.log"'
  else
    check "L8 get 500: the outage line says 8 is an upper bound" \
      'grep -q "STUCK-WORK ledger unreachable — up to 8 items past SLA unpaged (8 could not be read, so may already be paged)$" "$H/logs/ALERTS.log"'
  fi
  check "L8 ($v 500) log: $(last)" 'last | grep -qE " paged=0 repaged=0 incomplete=0 unpaged=8"'
  if [ "$v" = put ]; then
    check "L8 put 500: the snapshot write failed too: $(last)" 'last | grep -qE " unpaged=8 snap=fail$"'
  else
    check "L8 get 500: the snapshot still landed: $(last)" 'last | grep -qE " unpaged=8$" && [ "$(snap | jq -c .total)" = 9 ]'
  fi
  run $((N + 600)) scenario-mixed.txt
  check "L8 ($v 500) same hour: 0 more outage lines ($(outage))" '[ "$(outage)" = 1 ]'
  check "L8 ($v 500) same hour: 0 per-item lines ($(pages))" '[ "$(pages)" = 0 ]'
done

# ── L9: 2026-09-30, ten READY PRs nobody queued ─────────────────────────────
reset; run "$N" scenario-2026-09-30.txt
check "L9 10 lines ($(pages))" '[ "$(pages)" = 10 ]'
check "L9 every line is ready / owner=conductor" \
  '[ "$(grep -c "STUCK-WORK example-org/cromford#37[0-9]* ready owner=conductor age=" "$H/logs/ALERTS.log")" = 10 ]'
check "L9 ages 2h..18h" 'grep -q "#3760 ready owner=conductor age=120m" "$H/logs/ALERTS.log" && grep -q "#3769 ready owner=conductor age=1080m" "$H/logs/ALERTS.log"'
# The same ten entered READY at one instant (a derived copy; the fixture is untouched).
A=1789990000
awk -F'\t' -v OFS='\t' -v a="$A" '{ $7 = a; $10 = a; $22 = a; print }' "$FX/scenario-2026-09-30.txt" > "$T/same-anchor.facts"
reset; env HARNESS_TEST_SANDBOX=1 STUCK_WORK_NOW=$((A + 840)) STUCK_WORK_FIXTURE="$T/same-anchor.facts" bash "$LANE" > "$T/out" 2>&1
check "L9 at 14 min: 0 lines ($(pages))" '[ "$(pages)" = 0 ]'
env HARNESS_TEST_SANDBOX=1 STUCK_WORK_NOW=$((A + 900)) STUCK_WORK_FIXTURE="$T/same-anchor.facts" bash "$LANE" > "$T/out" 2>&1
check "L9 at 15 min: 10 lines ($(pages))" '[ "$(pages)" = 10 ]'

# ── L10: the adversarial negatives ──────────────────────────────────────────
reset; run "$N" scenario-negatives.txt
check "L10 0 lines ($(pages); $(grep STUCK-WORK "$H/logs/ALERTS.log" 2>/dev/null | head -3))" '[ "$(pages)" = 0 ]'
check "L10 0 stuck_work PUTs" '[ "$(puts)" = 0 ]'
check "L10 waiting-on-human 30h is counted, never paged: $(last)" \
  'last | grep -qE " items=6 states=[^ ]+ past_sla=1 paged=0 repaged=0 incomplete=0$"'

# ── L11: the switch ─────────────────────────────────────────────────────────
reset; mkdir -p "$H/flags"; touch "$H/flags/stuck-work-off"
run "$N" scenario-mixed.txt
check "L11 0 lines" '[ "$(pages)" = 0 ] && [ "$(puts)" = 0 ]'
check "L11 log off ($(last))" 'last | grep -qxE "[0-9T:Z-]+ off"'

# ── L12: the lock is held: dedupe, never a wait ─────────────────────────────
reset; mkdir -p "$H/locks"
exec 8>"$H/locks/stuck-work.lock"
flock -n 8 || bad "L12 setup: could not take the lock"
run "$N" scenario-mixed.txt
exec 8>&-
check "L12 rc 0" '[ "$(cat "$T/rc")" = 0 ]'
check "L12 log busy ($(last))" 'last | grep -qxE "[0-9T:Z-]+ busy"'
check "L12 0 lines" '[ "$(pages)" = 0 ] && [ "$(puts)" = 0 ]'

# ── L15: STUCK_WORK_MAX_ITEMS caps the items looked at, and says so ─────────
reset; run "$N" scenario-mixed.txt STUCK_WORK_MAX_ITEMS=3
check "L15 3 of 10 items, incomplete=1 ($(last))" \
  'last | grep -qE " items=3 states=awaiting-lead-review:1,queued:1,ready:1 past_sla=3 paged=3 repaged=0 incomplete=1$"'
check "L15 snapshot complete:false" '[ "$(snap | jq -c .complete)" = false ]'

# ── L13: live readers, rc 3 from the PR reader ──────────────────────────────
# The two reader libs are replaced in the SCRATCH tree only.
rm -f "$H/bin/lib/stuck-work/facts-pr.sh" "$H/bin/lib/stuck-work/facts-ticket.sh"
cat > "$H/bin/lib/stuck-work/facts-pr.sh" <<'SH'
swf_pr_facts() { echo "$1" > "$FXT/pr-args"; cat "$FXT/pr-lines"; return "$(cat "$FXT/pr-rc")"; }
SH
cat > "$H/bin/lib/stuck-work/facts-ticket.sh" <<'SH'
swf_ticket_facts() { printf '%s\n' "$1" > "$FXT/tk-args"; cat "$2" > "$FXT/tk-items"; return "$(cat "$FXT/tk-rc")"; }
SH
# TEST-CHANGE (BH-8736): the ticket reader is retired by default
# (STUCK_WORK_TICKET_FACTS=0); L13 pins the reader's wiring, so each run turns it on.
cp "$FX/scenario-ready-8m.txt" "$T/pr-lines"; echo 3 > "$T/pr-rc"; echo 0 > "$T/tk-rc"
reset; run "$N" - GH_TOKEN=test-token STUCK_WORK_SLA_READY_MIN=5 STUCK_WORK_TICKET_FACTS=1
check "L13 rc 0 ($(cat "$T/out"))" '[ "$(cat "$T/rc")" = 0 ]'
check "L13 the PR reader was asked for the repo ($(cat "$T/pr-args" 2>/dev/null))" '[ "$(cat "$T/pr-args" 2>/dev/null)" = example-org/cromford ]'
check "L13 the 1 item it printed is processed ($(pages))" '[ "$(pages)" = 1 ]'
check "L13 incomplete=1 ($(last))" 'last | grep -qE " items=1 states=ready:1 past_sla=1 paged=1 repaged=0 incomplete=1$"'
check "L13 the ticket reader got the repo and a file of PR items ($(cat "$T/tk-items" 2>/dev/null))" \
  '[ "$(cat "$T/tk-args" 2>/dev/null)" = example-org/cromford ] && [ "$(cat "$T/tk-items" 2>/dev/null)" = "example-org/cromford#120" ]'
check "L13 snapshot complete:false" '[ "$(snap | jq -c .complete)" = false ]'
echo 0 > "$T/pr-rc"; echo 1 > "$T/tk-rc"
reset; run "$N" - GH_TOKEN=test-token STUCK_WORK_TICKET_FACTS=1
check "L13 ticket reader rc 1 (the stub): incomplete=1 ($(last))" 'last | grep -qE " incomplete=1$"'
echo 0 > "$T/tk-rc"
reset; run "$N" - GH_TOKEN=test-token STUCK_WORK_TICKET_FACTS=1
check "L13 both readers rc 0: incomplete=0 ($(last))" 'last | grep -qE " incomplete=0$"'
check "L13 no request left the fake worker ($(cat "$T/other-urls" 2>/dev/null | head -2))" '[ ! -s "$T/other-urls" ]'

# ── L14: no App token ───────────────────────────────────────────────────────
reset; run "$N" -
check "L14 rc 0" '[ "$(cat "$T/rc")" = 0 ]'
check "L14 log no-token ($(last))" 'last | grep -qxE "[0-9T:Z-]+ no-token"'
check "L14 one lane-alert ($(cat "$T/lane-alerts" 2>/dev/null))" \
  '[ "$(cnt "" "$T/lane-alerts")" = 1 ] && grep -qx -- "--id stuck-work-no-token --severity warn stuck-work STUCK-WORK no GitHub App token for example-org/cromford; no open work is being watched" "$T/lane-alerts"'
check "L14 the PR reader was never asked" '[ ! -e "$T/pr-args" ]'
run $((N + 3600)) -
check "L14 same day: 0 more lane-alerts" '[ "$(cnt "" "$T/lane-alerts")" = 1 ]'
run $((N + 86400)) -
check "L14 next day: one more" '[ "$(cnt "" "$T/lane-alerts")" = 2 ]'

# ── R1-R3: the digest line, through the real renderer ───────────────────────
# shellcheck source=bin/lib/daily-digest-render.sh
. "$DIR/bin/lib/daily-digest-render.sh" || { bad "R setup: the renderer did not source"; echo "stuck-work: $PASS passed, $FAIL failed"; exit 1; }
DD="$DIR/tests/fixtures/daily-digest"
R1=$(dd_render "$DD/fixture-day.json" https://console.test - 0 5 -)
check "R1 fixture-day: $(grep 'past SLA' <<<"$R1")" \
  'grep -qxF "Open work past SLA: 4 (ready 3, blocked 1) https://console.test/alerts" <<<"$R1"'
check "R1 the line sits right after the Holds block" \
  '[ "$(grep -n "^Open work past SLA" <<<"$R1" | cut -d: -f1)" -gt "$(grep -n "^Holds:" <<<"$R1" | cut -d: -f1)" ] && [ "$(grep -n "^Open work past SLA" <<<"$R1" | cut -d: -f1)" -lt "$(grep -n "^PRs awaiting" <<<"$R1" | cut -d: -f1)" ]'
R2=$(dd_render "$DD/empty-day.json" https://console.test - 0 5 -)
check "R2 empty-day: $(grep 'past SLA' <<<"$R2")" 'grep -qxF "Open work past SLA: 0 https://console.test/alerts" <<<"$R2"'
jq '.past_sla.stale = true' "$DD/fixture-day.json" > "$T/stale.json"
R3=$(dd_render "$T/stale.json" https://console.test - 0 5 -)
check "R3 stale: $(grep 'past SLA' <<<"$R3")" \
  'grep -qxF "Open work past SLA: 4 (ready 3, blocked 1) (as of 23:55Z, stale) https://console.test/alerts" <<<"$R3"'
jq '.past_sla = {ok: false, error: "no stuck-work snapshot"}' "$DD/fixture-day.json" > "$T/fail.json"
R3=$(dd_render "$T/fail.json" https://console.test - 0 5 -)
check "R3 ok:false: $(grep 'past SLA' <<<"$R3")" \
  'grep -qxF "Open work past SLA: unreadable (no stuck-work snapshot) https://console.test/alerts" <<<"$R3"'
check "R3 ok:false never prints a 0" '! grep -q "Open work past SLA: 0" <<<"$R3"'

echo "stuck-work: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
