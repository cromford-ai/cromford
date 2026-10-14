#!/bin/bash
# tests/cost-readout.bh-2550-test.sh — bin/cost-readout.sh renders the
# summary.json headline table with no model (BH-2550).
#
# Runs the REAL script copied into a scratch HARNESS, with stubs for beat.sh,
# agent-call.sh, ssh and crontab that log any call. The fixture summary.json
# carries the keys bin/cost-rollup.sh writes (project_row + the fleet totals).
#
#   a. rc 0, logs/cost-readout-<YYYYMMDD>.md with one row per project sorted by
#      name, exact dollar figures, null cells rendered `unknown`, the fleet line
#      carrying fleet_cash_7d_total and cash_note verbatim.
#   b. no agent-call, no ssh, no crontab call.
#   c. one beat: kind cost_readout, project fleet, akey cost-readout:<stamp>,
#      detail holding the table.
#   d. missing / unparseable summary.json: rc 2, a reason on stderr, no .md,
#      no beat.
#   e. generated_at older than 26h: rc 0 and a STALE caveat naming it; an
#      empty generated_at is STALE too (GNU date -d "" reads it as today 00:00Z).
#   f. two runs over one fixture give byte-identical output.
#   g. source ratchet: no agent-call / review_model / ssh / crontab in the
#      script, and no cost-readout site in catalog/llm-sites.json.
# Run from anywhere: tests/cost-readout.bh-2550-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

SCRIPT="$DIR/bin/cost-readout.sh"
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state/cost" "$H/env" "$T/stubbin"
cp "$SCRIPT" "$H/bin/cost-readout.sh"
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/env-path.sh"
CALLS="$T/calls.log"; BEATS="$T/beats.log"
: > "$CALLS"; : > "$BEATS"
cat > "$H/bin/beat.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$1" >> "$BEATS"
EOF
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
echo "agent-call \$*" >> "$CALLS"; exit 0
EOF
for c in ssh crontab; do
  printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$c" "$CALLS" > "$T/stubbin/$c"
done
chmod +x "$H/bin/beat.sh" "$H/bin/agent-call.sh" "$T/stubbin/"*

# The pre-BH-2550 script pinned HARNESS=/root/harness, so running it here would
# have read the live harness and bought a model turn. Refuse to run a script
# that ignores the scratch HARNESS; that is itself a failure of this suite.
SAFE=1
if grep -qE '^HARNESS=/root/harness' "$SCRIPT"; then
  SAFE=0; bad "script pins HARNESS=/root/harness — refusing to run it outside the scratch tree"
fi

run() { HARNESS="$H" PATH="$T/stubbin:$PATH" bash "$H/bin/cost-readout.sh" 2>"$T/err"; }
STAMP=$(date -u +%Y%m%d)
OUT="$H/logs/cost-readout-$STAMP.md"
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%S.123456Z)
OLD_ISO=$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%S.000001Z)

fixture() {   # $1 = generated_at
  jq -n --arg g "$1" '{
    generated_at: $g, prices_updated: null,
    projects: {
      "zeta-os": {cost_24h: 3.5, unpriced_calls_24h: 0, cost_7d: 41.25, cost_30d: 90.1,
        product_7d: 0, triage_share_7d: null, merged_prs_7d: 0, cost_per_merged_pr_7d: null,
        stages_7d: {execute: 41.25}, unpriced_calls_7d: 0, build_per_merged_pr_7d: null,
        reopens_14d: 0, cash_cost_24h: 0, cash_cost_7d: 0, unknown_billing_calls_7d: 0,
        unknown_billing_calls_24h: 0, delivery_cost_24h: 3.5, stages_24h: {execute: 3.5},
        merged_prs_24h: 0, cost_per_merged_pr_24h: null, merged_prs_token: "default",
        merged_prs_status: "ok"},
      "alpha-os": {cost_24h: 12.4, unpriced_calls_24h: 2, cost_7d: 88.07, cost_30d: 300,
        product_7d: 1, triage_share_7d: 0.12, merged_prs_7d: 9, cost_per_merged_pr_7d: 9.67,
        stages_7d: {execute: 60, triage: 10}, unpriced_calls_7d: 3, build_per_merged_pr_7d: 6.1,
        reopens_14d: 1, cash_cost_24h: 1.2, cash_cost_7d: 7.5, unknown_billing_calls_7d: 0,
        unknown_billing_calls_24h: 0, delivery_cost_24h: 12.4, stages_24h: {execute: 12.4},
        merged_prs_24h: 2, cost_per_merged_pr_24h: 6.2, merged_prs_token: "default",
        merged_prs_status: "ok"}
    },
    fleet_notional_7d: 129.32, fleet_cash_7d: 7.5, fleet_cash_7d_total: null,
    fleet_unknown_billing_calls_7d: 0, fleet_unknown_billing_calls_24h: 0,
    fleet_unpriced_calls_24h: 2, fleet_unpriced_pairs_24h: [],
    cash_note: "UNKNOWN: no extra-usage meter on this box, so account overage could not be read",
    fleet_cash_7d_total_note: "UNKNOWN: no extra-usage meter on this box, so account overage could not be read"
  }' > "$H/state/cost/summary.json"
}

if [ "$SAFE" = 1 ]; then
  # --- a/b/c: the fresh fixture ----------------------------------------------
  fixture "$NOW_ISO"
  run; rc=$?
  [ "$rc" = 0 ] && ok || { bad "a: rc=$rc (want 0): $(cat "$T/err")"; }
  if [ -f "$OUT" ]; then
    ok
    ROWS=$(grep -E '^\| (alpha|zeta)-os ' "$OUT")
    [ "$(printf '%s\n' "$ROWS" | awk '{print $2}' | tr '\n' ' ')" = "alpha-os zeta-os " ] && ok \
      || bad "a: rows not one per project sorted by name: $ROWS"
    grep -qxF '| alpha-os | $12.40 | $88.07 | $7.50 | 9 | $9.67 | 12% |' "$OUT" && ok \
      || bad "a: alpha-os row wrong: $(grep alpha-os "$OUT")"
    grep -qxF '| zeta-os | $3.50 | $41.25 | $0.00 | 0 | unknown | unknown |' "$OUT" && ok \
      || bad "a: zeta-os row wrong (null must read unknown): $(grep zeta-os "$OUT")"
    grep -qF 'cash 7d total unknown' "$OUT" && ok || bad "a: null fleet_cash_7d_total not rendered unknown"
    grep -qF 'notional 7d $129.32' "$OUT" && ok || bad "a: fleet notional missing"
    grep -qF 'cash 7d $7.50' "$OUT" && ok || bad "a: fleet cash missing"
    grep -qF 'unpriced calls 24h 2' "$OUT" && ok || bad "a: unpriced calls missing"
    grep -qF 'cash note: UNKNOWN: no extra-usage meter on this box, so account overage could not be read' "$OUT" && ok \
      || bad "a: cash_note not verbatim"
    grep -qF "summary generated_at $NOW_ISO" "$OUT" && ok || bad "a: generated_at not named"
    grep -q STALE "$OUT" && bad "a: fresh summary flagged STALE" || ok
  else
    bad "a: $OUT not written"
  fi
  [ -s "$CALLS" ] && bad "b: model/ssh/crontab touched: $(cat "$CALLS")" || ok
  NB=$(wc -l < "$BEATS")
  [ "$NB" = 1 ] && ok || bad "c: beats=$NB (want 1)"
  if [ "$NB" -ge 1 ]; then
    B=$(head -1 "$BEATS")
    [ "$(jq -r '.kind' <<<"$B")" = cost_readout ] && ok || bad "c: kind: $B"
    [ "$(jq -r '.project' <<<"$B")" = fleet ] && ok || bad "c: project: $B"
    [ "$(jq -r '.akey' <<<"$B")" = "cost-readout:$STAMP" ] && ok || bad "c: akey: $B"
    jq -r '.detail' <<<"$B" | grep -qxF '| alpha-os | $12.40 | $88.07 | $7.50 | 9 | $9.67 | 12% |' && ok \
      || bad "c: detail does not hold the table"
  fi

  # --- f: determinism ----------------------------------------------------------
  cp "$OUT" "$T/first.md" 2>/dev/null
  run; rc=$?
  [ "$rc" = 0 ] && cmp -s "$T/first.md" "$OUT" && ok || bad "f: second run differs (rc=$rc)"

  # --- e: stale summary ------------------------------------------------------------
  fixture "$OLD_ISO"
  run; rc=$?
  [ "$rc" = 0 ] && ok || bad "e: rc=$rc (want 0)"
  grep -E '^STALE' "$OUT" 2>/dev/null | grep -F "$OLD_ISO" >/dev/null && ok || bad "e: no STALE caveat naming $OLD_ISO"
  fixture ""
  run; rc=$?
  [ "$rc" = 0 ] && ok || bad "e/empty: rc=$rc (want 0)"
  grep -qE '^STALE: .*could not be read' "$OUT" && ok || bad "e/empty: empty generated_at not flagged STALE"

  # --- d: missing / unparseable input ----------------------------------------------
  for mode in missing garbage empty; do
    rm -f "$OUT"; : > "$BEATS"
    case $mode in
      missing) rm -f "$H/state/cost/summary.json" ;;
      garbage) echo 'not json' > "$H/state/cost/summary.json" ;;
      empty)   : > "$H/state/cost/summary.json" ;;
    esac
    run; rc=$?
    [ "$rc" = 2 ] && ok || bad "d/$mode: rc=$rc (want 2)"
    [ -s "$T/err" ] && ok || bad "d/$mode: no stderr reason"
    [ -e "$OUT" ] && bad "d/$mode: .md written" || ok
    [ -s "$BEATS" ] && bad "d/$mode: beat posted" || ok
  done

  # --- empty projects map: header + a no-rows line, rc 0 ----------------------------
  jq -n --arg g "$NOW_ISO" '{generated_at:$g, projects:{}, fleet_notional_7d:0, fleet_cash_7d:0,
    fleet_cash_7d_total:0, fleet_unpriced_calls_24h:0, cash_note:"n"}' > "$H/state/cost/summary.json"
  run; rc=$?
  [ "$rc" = 0 ] && grep -qF 'no project rows' "$OUT" && ok || bad "empty projects: rc=$rc or no 'no project rows' line"
  [ -s "$CALLS" ] && bad "b: model/ssh/crontab touched over all runs: $(cat "$CALLS")" || ok
fi

# --- g: source ratchet (guarded: the script must exist to pass) --------------------
if [ -f "$SCRIPT" ]; then
  for pat in 'agent-call' 'review_model' 'ssh ' 'crontab'; do
    grep -qF -- "$pat" "$SCRIPT" && bad "g: bin/cost-readout.sh still contains '$pat'" || ok
  done
else
  bad "g: $SCRIPT missing"
fi
SITE=$(jq -c '.sites[]|select(.id=="cost-readout")' "$DIR/catalog/llm-sites.json" 2>&1)
[ -z "$SITE" ] && ok || bad "g: catalog/llm-sites.json still lists cost-readout"

echo "cost-readout.bh-2550: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
